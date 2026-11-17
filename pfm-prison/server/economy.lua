-- Inmate trust accounts, commissary and restitution (batch 19E; PF_ARCHITECTURE 4.8).
--
-- Every inmate's money sits in one ledger account, system:pfm-prison-trust. pf_prison_account_tx is
-- the inmate's side of it: one row per move, each row backed by one keyed ledger Transfer, so an
-- inmate's balance is the SUM(amount) of their settled rows and never comes from an UPDATE of a
-- number. The row is written (ledger_state 'pending') before its Transfer, so a crash leaves a key
-- to look up. Ledger rule: a clearly refused key stays failed and a retry uses a new numbered key;
-- an unclear result (pending, debited, interrupted) stays 'pending' and is settled from the
-- ledger's own record (GetTransaction), never paid again under another key.
--
--   deposit         player:<cid>:bank      -> trust            key pfm-prison:trust:<cid>:d<id>
--   earning         society:corrections    -> trust            key pfm-prison:trust:<cid>:e<order>.<ticket>.<n>
--   purchase        trust -> society:corrections (goods given only once the move completed)
--                                                              key pfm-prison:trust:<cid>:b<id>
--   restitution     trust -> player:<victim>:bank              key pf-justice:restitution:<orderId>:<n>
--   release_payout  trust -> player:<cid>:bank                 key pfm-prison:trust:<cid>:r<n>
--
-- Available balance = settled rows + outgoing moves still pending (an unclear purchase is not spent
-- twice); incoming pending money counts only once it settled. Every money action of one inmate
-- runs under that inmate's lock, taken before the first database wait.

PFPrison = PFPrison or {}
PFPrison.Economy = PFPrison.Economy or {}
local E = PFPrison.Economy
local EC = Config.Economy or {}
local TRUST = EC.TrustAccount or 'system:pfm-prison-trust'
local SYSTEM = { kind = 'system', label = 'pfm-prison economy' }

local function num(v, d) return tonumber(v) or d end
local function int(v, lo, hi)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge then return nil end
    v = math.floor(v)
    if v < lo or v > hi then return nil end
    return v
end
local function validCid(cid) return type(cid) == 'string' and #cid >= 1 and #cid <= 64 and cid:match('^[%w_%-]+$') ~= nil end
local function dayStart(t) return t - (t % 86400) end
E.DayStart = dayStart

E.SQL = {
    insert = 'INSERT INTO pf_prison_account_tx (citizenid, kind, amount, ledger_key, ledger_state, ref, at) VALUES (?, ?, ?, ?, ?, ?, ?)',
    setState = 'UPDATE pf_prison_account_tx SET ledger_state = ? WHERE id = ? AND ledger_state = ?',
    setRef = 'UPDATE pf_prison_account_tx SET ref = ? WHERE id = ? AND ref = ?',
    balance = [[SELECT
        COALESCE(SUM(CASE WHEN ledger_state IN ('completed', 'internal') THEN amount ELSE 0 END), 0) AS settled,
        COALESCE(SUM(CASE WHEN ledger_state = 'pending' AND amount < 0 THEN amount ELSE 0 END), 0) AS out_pending,
        COALESCE(SUM(CASE WHEN ledger_state = 'pending' AND amount > 0 THEN amount ELSE 0 END), 0) AS in_pending
        FROM pf_prison_account_tx WHERE citizenid = ?]],
    sumKindSince = [[SELECT COALESCE(SUM(amount), 0) FROM pf_prison_account_tx
        WHERE citizenid = ? AND kind = ? AND at >= ? AND ledger_state <> 'failed']],
    refsSince = [[SELECT ref FROM pf_prison_account_tx
        WHERE citizenid = ? AND kind = 'purchase' AND at >= ? AND ledger_state <> 'failed' AND ref LIKE ?]],
    countRef = 'SELECT COUNT(*) FROM pf_prison_account_tx WHERE ref LIKE ?',
    countKind = 'SELECT COUNT(*) FROM pf_prison_account_tx WHERE citizenid = ? AND kind = ?',
    lastKindAt = 'SELECT MAX(at) FROM pf_prison_account_tx WHERE citizenid = ? AND kind = ?',
    heldRestitution = [[SELECT COALESCE(SUM(-amount), 0) FROM pf_prison_account_tx
        WHERE kind = 'restitution' AND ref = ? AND ledger_state IN ('pending', 'completed')]],
    pending = "SELECT * FROM pf_prison_account_tx WHERE ledger_state = 'pending' AND at <= ? ORDER BY id LIMIT 100",
    undelivered = [[SELECT * FROM pf_prison_account_tx WHERE citizenid = ? AND kind = 'purchase'
        AND ledger_state = 'completed' AND ref LIKE '%:due' ORDER BY id LIMIT 20]],
    unrecorded = [[SELECT * FROM pf_prison_account_tx WHERE kind = 'restitution' AND ledger_state = 'completed'
        AND ref LIKE '%:due' ORDER BY id LIMIT 50]],
    -- wages whose every attempt was clearly refused (nothing pending or paid under that ticket)
    failedEarnings = [[SELECT ref, citizenid, MIN(amount) AS amount, COUNT(*) AS n, MAX(at) AS last FROM pf_prison_account_tx
        WHERE kind = 'earning' GROUP BY ref, citizenid
        HAVING SUM(ledger_state IN ('completed', 'pending')) = 0 AND COUNT(*) < ? AND MAX(at) <= ? LIMIT 50]],
    positive = [[SELECT citizenid, SUM(amount) AS bal FROM pf_prison_account_tx
        WHERE ledger_state IN ('completed', 'internal') AND citizenid <> 'deleted'
        GROUP BY citizenid HAVING bal > 0 ORDER BY citizenid LIMIT 100]],
    recent = 'SELECT kind, amount, ledger_state, at FROM pf_prison_account_tx WHERE citizenid = ? ORDER BY id DESC LIMIT 10',
    revoked = "SELECT 1 FROM pf_prison_privileges WHERE citizenid = ? AND kind IN (?, 'solitary') AND until_at > ? LIMIT 1",
    rowsTotal = "SELECT COALESCE(SUM(amount), 0) FROM pf_prison_account_tx WHERE ledger_state = 'completed'",
    ledgerNet = [[SELECT COALESCE(SUM(CASE WHEN to_account = ? THEN amount ELSE -amount END), 0) FROM pf_transactions
        WHERE state = 'completed' AND (to_account = ? OR from_account = ?)]],
    event = 'INSERT INTO pf_prison_events (citizenid, facility, kind, detail, actor_cid, at) VALUES (?, ?, ?, ?, NULL, ?)',
    anonymize = "UPDATE pf_prison_account_tx SET citizenid = 'deleted' WHERE citizenid = ?",
}

local function dbReady() return PFPrisonSchema ~= nil and PFPrisonSchema.Ready() end

--- One query; nil, false when the tables are not usable or the query broke.
local function db(kind, sql, params)
    if not dbReady() then return nil, false end
    local ok, res = pcall(MySQL[kind].await, sql, params or {})
    if not ok then
        print(('^1[pfm-prison]^7 economy database error: %s'):format(tostring(res)))
        return nil, false
    end
    return res, true
end
E.db = db

local function encode(v)
    local ok, s = pcall(json.encode, v)
    return ok and s or nil
end

--- A pf_prison_events row (kinds 'work', 'credit', 'trust'); detail clipped to 4 KB.
function E.Event(cid, kind, detail)
    local s = detail ~= nil and encode(detail) or nil
    if s and #s > 4096 then s = encode({ truncated = true }) end
    local fac = (Config.Justice and Config.Justice.Facility) or 'bolingbroke'
    db('insert', E.SQL.event, { validCid(cid) and cid or nil, fac, kind, s, os.time() })
end

local function notify(src, text, kind)
    if src then TriggerClientEvent('QBCore:Notify', src, text, kind or 'primary') end
end

local function playerByCid(cid)
    local ok, P = pcall(function() return exports['pfm-core']:GetPlayerByCitizenId(cid) end)
    if ok and type(P) == 'table' and P.PlayerData then return P end
    return nil
end

local function srcOf(cid)
    local P = playerByCid(cid)
    return P and tonumber(P.PlayerData.source) or nil
end

-- ── locks (per inmate, taken before the first database wait) ──────────────────────────────────

E.locks = E.locks or {}

--- Runs fn while holding the inmate's money lock. Returns fn's result, or { ok = false, error = 'busy' }.
function E.WithLock(cid, fn)
    if E.locks[cid] then return { ok = false, error = 'busy', message = 'Your last request is still being processed' } end
    E.locks[cid] = true
    local ok, res = pcall(fn)
    E.locks[cid] = nil
    if not ok then
        print(('^1[pfm-prison]^7 trust action for %s failed: %s'):format(tostring(cid), tostring(res)))
        return { ok = false, error = 'db_unavailable', message = 'The trust office is unavailable right now' }
    end
    return res
end

-- ── balance ──────────────────────────────────────────────────────────────────────────────────

--- { settled, outPending, inPending, available } of one inmate; nil when the table cannot be read.
function E.Balance(cid)
    local row, ok = db('single', E.SQL.balance, { cid })
    if not ok then return nil end
    row = row or {}
    local settled, outP, inP = num(row.settled, 0), num(row.out_pending, 0), num(row.in_pending, 0)
    return { settled = settled, outPending = -outP, inPending = inP, available = settled + outP }
end

--- Whether a privilege (commissary, work, ...) is revoked now, or the inmate is in solitary, which
--- suspends them all (pf_prison_privileges, 19D discipline). A table
--- that cannot be read counts as revoked: nothing is sold or worked on an unknown sanction.
function E.Revoked(cid, kind)
    local row, ok = db('single', E.SQL.revoked, { cid, kind, os.time() })
    if not ok then return true end
    return row ~= nil
end

-- ── one keyed move ───────────────────────────────────────────────────────────────────────────

local function setState(id, to, from) local n = db('update', E.SQL.setState, { to, id, from }) return num(n, 0) == 1 end
local function setRef(id, to, from) local n = db('update', E.SQL.setRef, { to, id, from }) return num(n, 0) == 1 end
E.setState, E.setRef = setState, setRef

function E.TrustKey(cid, txId) return ('pfm-prison:trust:%s:%s'):format(cid, txId) end

--- Writes the row (pending), then moves the money under the row's key. Returns
--- { ok, id, state = 'completed' | 'failed' | 'pending', error }.
function E.Move(spec)
    local now = os.time()
    local id, ok = db('insert', E.SQL.insert, { spec.cid, spec.kind, spec.amount, spec.key, 'pending', spec.ref, now })
    id = math.tointeger(tonumber(id))
    if not ok or not id then return { ok = false, state = 'failed', error = 'db_unavailable' } end
    local res = PFPayout.Transfer({
        from = spec.from, to = spec.to, amount = math.abs(spec.amount), key = spec.key, kind = spec.ledgerKind,
        reason = spec.reason, actor = spec.cid, metadata = { prisonTx = id, ref = spec.ref },
    })
    res = type(res) == 'table' and res or { ok = false, error = 'bank_unavailable' }
    if res.ok then
        setState(id, 'completed', 'pending')
        return { ok = true, id = id, state = 'completed' }
    end
    if PFPayout.IsClearFailure(res) then
        setState(id, 'failed', 'pending')
        return { ok = false, id = id, state = 'failed', error = res.error or 'failed' }
    end
    print(('^3[pfm-prison]^7 trust move %s is unclear (%s); it is settled from the ledger'):format(spec.key, tostring(res.error or res.state)))
    return { ok = false, id = id, state = 'pending', error = 'payment_unclear' }
end

-- ── pf-justice ───────────────────────────────────────────────────────────────────────────────

local function J(name, ...)
    local B = PFPrison.Bridge
    if B and B.Justice then return B.Justice(name, ...) end
    return nil
end

-- pf-justice records a restitution payment it did not take itself only through RecordRestitution
-- (requested from pf-justice; see the batch 19 report). Without it a share paid here would not
-- lower what the order says is owed, so the inmate could pay it twice: no share is taken then.
E.restProbe = E.restProbe or { at = -math.huge, ok = false }
function E.RestitutionAvailable(now)
    now = now or os.time()
    if now - E.restProbe.at < 300 then return E.restProbe.ok end
    local ok, res = false, nil
    if GetResourceState('pf-justice') == 'started' then
        ok, res = pcall(function() return exports['pf-justice']:RecordRestitution(0, {}, { key = 'pfm-prison:probe' }) end)
    end
    E.restProbe = { at = now, ok = ok and type(res) == 'table' }
    return E.restProbe.ok
end

local OPEN_RESTITUTION = { 'issued', 'overdue', 'upheld', 'referred' }

local function recordRestitution(row, orderId)
    local amount = -num(row.amount, 0)
    local res = J('RecordRestitution', orderId, { amount = amount, ledgerKey = row.ledger_key, from = TRUST },
        { key = row.ledger_key, actor = SYSTEM })
    if type(res) == 'table' and res.ok == true then
        setRef(row.id, ('rest:%d:rec'):format(orderId), ('rest:%d:due'):format(orderId))
        return true
    end
    return false
end

--- A share of one wage pays the victim of the inmate's oldest open restitution order. Caller holds
--- the inmate's lock. Returns the amount paid (0 when none).
local function restituteLocked(cid, earned)
    local share = math.floor(num(earned, 0) * num(EC.RestitutionShare, 0))
    if share < 1 or not E.RestitutionAvailable() then return 0 end
    local res = J('GetOrders', cid, { kinds = { 'restitution' }, states = OPEN_RESTITUTION, limit = 10 })
    if type(res) ~= 'table' or res.ok ~= true or type(res.list) ~= 'table' then return 0 end
    table.sort(res.list, function(a, b) return num(a.id, 0) < num(b.id, 0) end)
    for _, o in ipairs(res.list) do
        local orderId = math.tointeger(tonumber(o.id))
        if orderId and o.kind == 'restitution' and validCid(o.victimCid) and o.victimCid ~= cid then
            local held = num(db('scalar', E.SQL.heldRestitution, { ('rest:%d:due'):format(orderId) }), 0)
            local due = num(o.amount, 0) - num(o.paidAmount, 0) - held
            local bal = E.Balance(cid)
            local amount = math.min(share, due, bal and bal.available or 0)
            if amount >= 1 then
                local n = num(db('scalar', E.SQL.countRef, { ('rest:%d:%%'):format(orderId) }), 0) + 1
                local key = ('pf-justice:restitution:%d:%d'):format(orderId, n)
                local r = E.Move({ cid = cid, kind = 'restitution', amount = -amount, key = key, ref = ('rest:%d:due'):format(orderId),
                    from = TRUST, to = ('player:%s:bank'):format(o.victimCid), ledgerKind = 'restitution',
                    reason = ('Restitution, order #%d (inmate wage)'):format(orderId) })
                if r.ok then
                    recordRestitution({ id = r.id, amount = -amount, ledger_key = key }, orderId)
                    E.Event(cid, 'trust', { what = 'restitution', orderId = orderId, amount = amount, key = key })
                    return amount
                end
                return 0
            end
        end
    end
    return 0
end
E.RestituteLocked = restituteLocked

-- ── earnings (from server/work.lua) ──────────────────────────────────────────────────────────

local function earnLocked(cid, orderId, ticket, wage, attempt)
    local key = E.TrustKey(cid, ('e%d.%d.%d'):format(orderId, ticket, attempt))
    local r = E.Move({ cid = cid, kind = 'earning', amount = wage, key = key, ref = ('wl:%d:%d'):format(orderId, ticket),
        from = EC.WageAccount or 'society:corrections', to = TRUST, ledgerKind = 'wage',
        reason = ('Inmate wage, work ticket %d'):format(ticket) })
    if r.ok then r.restitution = restituteLocked(cid, wage) end
    return r
end

--- Pays one shift's wage into the trust. A clear refusal (an empty corrections budget) is tried again
--- later under the next numbered key (RetryTick); an unclear one is settled from the ledger.
function E.Earn(cid, orderId, ticket, wage)
    orderId, ticket, wage = int(orderId, 1, 2147483647), int(ticket, 1, 2147483647), int(wage, 1, 100000)
    if not validCid(cid) or not orderId or not ticket or not wage then return { ok = false, error = 'bad_args' } end
    return E.WithLock(cid, function() return earnLocked(cid, orderId, ticket, wage, 1) end)
end

-- ── deposits ─────────────────────────────────────────────────────────────────────────────────

local function depositLocked(src, cid, amount)
    local today = num(db('scalar', E.SQL.sumKindSince, { cid, 'deposit', dayStart(os.time()) }), 0)
    if today + amount > num(EC.MaxDepositPerDay, 5000) then
        return { ok = false, error = 'bad_args', message = ('You can deposit $%d more today'):format(math.max(0, num(EC.MaxDepositPerDay, 5000) - today)) }
    end
    local r = E.Move({ cid = cid, kind = 'deposit', amount = amount, key = E.TrustKey(cid, 'd' .. PFPayout.NewId()), ref = 'dep',
        from = ('player:%s:bank'):format(cid), to = TRUST, ledgerKind = 'deposit', reason = 'Deposit to inmate trust' })
    if r.ok then E.Event(cid, 'trust', { what = 'deposit', amount = amount }) end
    return r
end

-- ── commissary ───────────────────────────────────────────────────────────────────────────────

--- Gives the goods of one completed purchase once: the row is marked given first, so a second call
--- finds nothing; goods that do not fit stay owed and come at the next look.
function E.Deliver(src, row)
    local item, qty = tostring(row.ref or ''):match('^buy:([%w_]+):(%d+):due$')
    qty = tonumber(qty)
    if not item or not qty then return false end
    local due, given = ('buy:%s:%d:due'):format(item, qty), ('buy:%s:%d:given'):format(item, qty)
    if not setRef(row.id, given, due) then return false end
    local ok, added = pcall(function() return exports['pfm-inventory']:AddItem(src, item, qty, false, false, 'pfm-prison:commissary') end)
    if ok and added then
        TriggerClientEvent('qb-inventory:client:ItemBox', src, exports['pfm-core']:GetShared('Items')[item], 'add')
        return true
    end
    setRef(row.id, due, given)
    notify(src, 'Your commissary order is kept at the window until you have room', 'error')
    return false
end

local function boughtToday(cid, item)
    local rows = db('query', E.SQL.refsSince, { cid, dayStart(os.time()), ('buy:%s:%%'):format(item) }) or {}
    local n = 0
    for _, r in ipairs(rows) do n = n + num(tostring(r.ref):match('^buy:[%w_]+:(%d+):'), 0) end
    return n
end

local function buyLocked(src, cid, entry, qty)
    local total = entry.price * qty
    if boughtToday(cid, entry.item) + qty > num(entry.maxPerDay, 99) then
        return { ok = false, error = 'bad_args', message = 'That is more than you may buy of it today' }
    end
    local spent = -num(db('scalar', E.SQL.sumKindSince, { cid, 'purchase', dayStart(os.time()) }), 0)
    if spent + total > num(EC.MaxSpendPerDay, 400) then
        return { ok = false, error = 'bad_args', message = 'You reached today\'s commissary limit' }
    end
    local bal = E.Balance(cid)
    if not bal then return { ok = false, error = 'db_unavailable', message = 'The trust office is unavailable right now' } end
    if bal.available < total then return { ok = false, error = 'insufficient_funds', message = 'Not enough money in your trust account' } end
    local okFit, fits = pcall(function() return exports['pfm-inventory']:CanAddItem(src, entry.item, qty) end)
    if not okFit or not fits then return { ok = false, error = 'bad_args', message = 'You have no room for that' } end
    local ref = ('buy:%s:%d:due'):format(entry.item, qty)
    local r = E.Move({ cid = cid, kind = 'purchase', amount = -total, key = E.TrustKey(cid, 'b' .. PFPayout.NewId()), ref = ref,
        from = TRUST, to = EC.CommissaryAccount or 'society:corrections', ledgerKind = 'commissary',
        reason = ('Commissary: %d x %s'):format(qty, entry.item) })
    if r.ok then
        E.Deliver(src, { id = r.id, ref = ref })
        E.Event(cid, 'trust', { what = 'purchase', item = entry.item, qty = qty, amount = total })
    end
    return r
end

-- ── release payout ───────────────────────────────────────────────────────────────────────────

--- Whether the citizen is out of this prison for good: no row here (or a release under way) and
--- pf-justice has no open incarceration order for them. nil when pf-justice cannot answer.
function E.Released(cid)
    local B = PFPrison.Bridge or {}
    local row = B.rows and B.rows[cid]
    if row and row.status ~= 'releasing' then return false end
    if not B.OpenOrders then return nil end
    local list = B.OpenOrders(cid)
    if list == nil then return nil end
    return #list == 0
end

local function payoutLocked(cid, now)
    if E.Released(cid) ~= true then return nil end
    local bal = E.Balance(cid)
    if not bal or bal.available < 1 then return nil end
    local last = num(db('scalar', E.SQL.lastKindAt, { cid, 'release_payout' }), nil)
    local n = num(db('scalar', E.SQL.countKind, { cid, 'release_payout' }), 0)
    if n > 0 and last and now - last < num(EC.PayoutRetrySeconds, 120) then return nil end
    local r = E.Move({ cid = cid, kind = 'release_payout', amount = -bal.available, key = E.TrustKey(cid, 'r' .. (n + 1)), ref = 'rel',
        from = TRUST, to = ('player:%s:bank'):format(cid), ledgerKind = 'payout', reason = 'Inmate trust paid out at release' })
    if r.ok then
        E.Event(cid, 'trust', { what = 'release_payout', amount = bal.available })
        notify(srcOf(cid), ('Your inmate trust balance of $%d was paid to your bank'):format(bal.available), 'success')
    end
    return r
end

-- ── settling and retries (E.Tick) ────────────────────────────────────────────────────────────

local function lookup(key)
    if GetResourceState('pfm-banking') ~= 'started' then return false end
    local ok, tx = pcall(function() return exports['pfm-banking']:GetTransaction(key) end)
    if not ok then return false end
    return true, tx
end

local function afterCompleted(row)
    local cid = row.citizenid
    if row.kind == 'purchase' then
        local src = srcOf(cid)
        if src then E.Deliver(src, row) end
    elseif row.kind == 'earning' then
        restituteLocked(cid, num(row.amount, 0))
    elseif row.kind == 'restitution' then
        local orderId = tonumber(tostring(row.ref):match('^rest:(%d+):due$'))
        if orderId then recordRestitution(row, orderId) end
    end
end

--- Pending rows: the ledger's own record decides (completed / clearly failed). A key the ledger never
--- saw (the server stopped between the row and the Transfer) fails after NotWrittenGraceSeconds.
function E.SettleTick(now)
    now = now or os.time()
    local rows = db('query', E.SQL.pending, { now - num(EC.SettleAfterSeconds, 60) }) or {}
    local settled = 0
    for _, row in ipairs(rows) do
        local okLook, tx = lookup(row.ledger_key)
        if okLook then
            local to
            if tx ~= nil and tx.state == 'completed' then
                to = 'completed'
            elseif tx == nil then
                if num(row.at, now) <= now - num(EC.NotWrittenGraceSeconds, 300) then to = 'failed' end
            elseif PFPayout.IsClearFailure({ ok = false, state = tx.state, error = tx.error, txId = tx.tx_id }) then
                to = 'failed'
            end
            if to then
                E.WithLock(row.citizenid, function()
                    if setState(row.id, to, 'pending') then
                        settled = settled + 1
                        if to == 'completed' then afterCompleted(row) end
                    end
                end)
            end
        end
    end
    return settled
end

--- Wages the corrections budget clearly refused: the next numbered key, after EarningRetrySeconds,
--- at most MaxEarningAttempts in all (then left for an admin, with an anomaly row).
function E.RetryTick(now)
    now = now or os.time()
    local maxN = num(EC.MaxEarningAttempts, 10)
    local rows = db('query', E.SQL.failedEarnings, { maxN, now - num(EC.EarningRetrySeconds, 300) }) or {}
    local n = 0
    for _, r in ipairs(rows) do
        local orderId, ticket = tostring(r.ref):match('^wl:(%d+):(%d+)$')
        orderId, ticket = tonumber(orderId), tonumber(ticket)
        if orderId and ticket then
            local attempt = num(r.n, 0) + 1
            E.WithLock(r.citizenid, function()
                local res = earnLocked(r.citizenid, orderId, ticket, num(r.amount, 0), attempt)
                n = n + 1
                if not res.ok and res.state == 'failed' and attempt >= maxN then
                    E.Event(r.citizenid, 'anomaly', { what = 'wage_refused', orderId = orderId, ticket = ticket, attempts = attempt })
                end
            end)
        end
    end
    return n
end

--- Restitution paid to a victim that pf-justice has not recorded yet (it was busy or stopped).
function E.RecordTick()
    if not E.RestitutionAvailable() then return 0 end
    local n = 0
    for _, row in ipairs(db('query', E.SQL.unrecorded, {}) or {}) do
        local orderId = tonumber(tostring(row.ref):match('^rest:(%d+):due$'))
        if orderId and recordRestitution(row, orderId) then n = n + 1 end
    end
    return n
end

--- Goods of completed purchases that are still owed, for one online inmate.
function E.DeliverOwed(src, cid)
    local n = 0
    for _, row in ipairs(db('query', E.SQL.undelivered, { cid }) or {}) do
        if E.Deliver(src, row) then n = n + 1 end
    end
    return n
end

--- Positive balances of citizens who left the prison are paid to their bank.
function E.PayoutTick(now)
    now = now or os.time()
    local n = 0
    for _, r in ipairs(db('query', E.SQL.positive, {}) or {}) do
        if validCid(r.citizenid) then
            local res = E.WithLock(r.citizenid, function() return payoutLocked(r.citizenid, now) end)
            if type(res) == 'table' and res.ok then n = n + 1 end
        end
    end
    return n
end

function E.Tick(now)
    now = now or os.time()
    if not dbReady() then return end
    E.SettleTick(now)
    E.RetryTick(now)
    E.RecordTick()
    E.PayoutTick(now)
end

--- The trust reconciles with the ledger: the completed rows of every inmate sum to the net of
--- every completed ledger transfer into and out of the trust account.
function E.Reconcile()
    local rows = num(db('scalar', E.SQL.rowsTotal, {}), nil)
    local ledger = num(db('scalar', E.SQL.ledgerNet, { TRUST, TRUST, TRUST }), nil)
    if rows == nil or ledger == nil then return { ok = false, error = 'db_unavailable' } end
    return { ok = math.abs(rows - ledger) < 0.005, rows = rows, ledger = ledger }
end

CreateThread(function()
    Wait(5000)
    local reconcileAt = os.time() + 600
    while true do
        Wait(math.max(10, num(EC.TickSeconds, 60)) * 1000)
        local ok, err = pcall(E.Tick)
        if not ok then print(('^1[pfm-prison]^7 trust tick failed: %s'):format(tostring(err))) end
        if os.time() >= reconcileAt then
            reconcileAt = os.time() + 86400
            local r = E.Reconcile()
            if r.ok == false and r.rows then
                print(('^1[pfm-prison]^7 inmate trust does not reconcile: rows $%s, ledger $%s'):format(tostring(r.rows), tostring(r.ledger)))
            end
        end
    end
end)

-- ── net events and callbacks (inmates) ───────────────────────────────────────────────────────

local lastAsk = {}
local function rate(src, what, seconds)
    local k, now = what .. ':' .. tostring(src), os.time()
    if lastAsk[k] and now - lastAsk[k] < seconds then return false end
    lastAsk[k] = now
    return true
end

--- The inmate at the trust window: admitted here, inside, within KioskReach (server position).
local function atKiosk(src)
    local inmate = PFPrison.Inmate and PFPrison.Inmate(src)
    if not inmate then return nil, 'Only inmates can use the trust window' end
    local pos = PFPrison.Internal and PFPrison.Internal.pedPos(src)
    if not pos or not EC.Kiosk or #(vector3(pos.x, pos.y, pos.z) - EC.Kiosk) > num(EC.KioskReach, 3.0) then
        return nil, 'Go to the trust window'
    end
    return inmate
end

local function tell(src, res, okText)
    if res.ok then return notify(src, okText, 'success') end
    if res.error == 'payment_unclear' then return notify(src, 'The bank is still processing this. Nothing more was taken.', 'primary') end
    notify(src, res.message or (res.error == 'insufficient_funds' and 'Not enough money' or 'That did not go through; nothing was taken'), 'error')
end

RegisterNetEvent('pfm-prison:server:TrustDeposit', function(amount)
    local src = source
    if not rate(src, 'deposit', 3) then return end
    amount = int(amount, 1, num(EC.MaxDeposit, 2000))
    if not amount then return notify(src, 'Enter an amount of 1 to ' .. num(EC.MaxDeposit, 2000), 'error') end
    local inmate, why = atKiosk(src)
    if not inmate then return notify(src, why, 'error') end
    local res = E.WithLock(inmate.cid, function() return depositLocked(src, inmate.cid, amount) end)
    tell(src, res, ('$%d deposited to your trust account'):format(amount))
end)

RegisterNetEvent('pfm-prison:server:CommissaryBuy', function(index, qty)
    local src = source
    if not rate(src, 'buy', 2) then return end
    local catalog = EC.Commissary or {}
    index, qty = int(index, 1, #catalog), int(qty, 1, 10)
    local entry = index and catalog[index]
    if not entry or not qty then return end
    local inmate, why = atKiosk(src)
    if not inmate then return notify(src, why, 'error') end
    if E.Revoked(inmate.cid, 'commissary') then return notify(src, 'Your commissary privilege is suspended', 'error') end
    local res = E.WithLock(inmate.cid, function() return buyLocked(src, inmate.cid, entry, qty) end)
    tell(src, res, ('Bought %d x %s'):format(qty, entry.label or entry.item))
end)

-- What the trust window shows: the balance, today's limits, the catalog and the last moves.
-- Goods still owed from an earlier purchase are handed over at the same time.
local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions' })
QBCore.Functions.CreateCallback('pfm-prison:server:trustState', function(src, cb)
    local inmate = PFPrison.Inmate and PFPrison.Inmate(src)
    if not inmate or not rate(src, 'state', 1) then return cb(nil) end
    local cid = inmate.cid
    local bal = E.Balance(cid)
    if not bal then return cb({ ok = false, message = 'The trust office is unavailable right now' }) end
    if atKiosk(src) and not E.locks[cid] then E.WithLock(cid, function() E.DeliverOwed(src, cid) end) end
    local spent = -num(db('scalar', E.SQL.sumKindSince, { cid, 'purchase', dayStart(os.time()) }), 0)
    local deposited = num(db('scalar', E.SQL.sumKindSince, { cid, 'deposit', dayStart(os.time()) }), 0)
    local catalog = {}
    for i, entry in ipairs(EC.Commissary or {}) do
        catalog[i] = { index = i, label = entry.label or entry.item, price = entry.price,
            left = math.max(0, num(entry.maxPerDay, 99) - boughtToday(cid, entry.item)) }
    end
    local recent = {}
    for _, r in ipairs(db('query', E.SQL.recent, { cid }) or {}) do
        recent[#recent + 1] = { kind = r.kind, amount = num(r.amount, 0), state = r.ledger_state, at = num(r.at, 0) }
    end
    cb({ ok = true, balance = bal.available, incoming = bal.inPending,
        spendLeft = math.max(0, num(EC.MaxSpendPerDay, 400) - spent), depositLeft = math.max(0, num(EC.MaxDepositPerDay, 5000) - deposited),
        maxDeposit = num(EC.MaxDeposit, 2000), revoked = E.Revoked(cid, 'commissary'), catalog = catalog, recent = recent })
end)

-- A deleted character: the trust rows stay (the ledger still holds their moves, so the trust must
-- keep reconciling) but no longer name the citizen.
AddEventHandler('pfm-core:server:characterDeleted', function(cid)
    local s = tonumber(source)
    if (s and s > 0) or not validCid(cid) then return end
    db('update', E.SQL.anonymize, { cid })
    db('update', 'DELETE FROM pf_prison_work_log WHERE citizenid = ?', { cid })
end)
