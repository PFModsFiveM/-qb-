-- pfm-prison <-> pf-justice (batch 16C; PF_ARCHITECTURE 4.7.2, 4.8, 5.5).
--
-- pf-justice owns every sentence and its one clock. pfm-prison owns the prison itself:
--   * IsInside(src): the presence provider of pf-justice's facility 'bolingbroke' (the clock counts a
--     tick only when this says the inmate is inside the walls; an escapee is never inside);
--   * intake: an active incarceration order at Bolingbroke (pf-justice:server:orderCreated, a login,
--     a resume) takes the citizen in: whatever they carry goes into a pf-justice property locker
--     (SeizeProperty, key pfm-prison:intake:<orderId>), they keep the job but go off duty (D1), get
--     the jail money once per order, a row in pf_prison_inmates, a cell and a work spot;
--   * release: when pf-justice has no open order for them here any more (releaseOrdered, also an
--     offline completion that pf-justice finishes at their next login), they are let out of the
--     gate once and their locker is given back (ReturnProperty);
--   * work: a finished job is a time credit on the order (AdjustOrder credit, key
--     pfm-prison:credit:<orderId>:<ticket>, capped by pf-justice Config.Credits);
--   * escape (D12): the order is suspended (AdjustOrder suspend; never SetOrderState, an escape is
--     not a completion) and the property stays in the locker. An escapee who is brought back inside
--     the walls, or who gets a new sentence, serves on (AdjustOrder resume) and is taken in again.
--   * transport intake (pf-justice Config.Prison.Intake = 'transport'): a pending order starts
--     (SetOrderState 'active') when the prisoner is brought to Config.Justice.Intake.
--
-- pf-justice's events are hints only: any server resource can raise an event, so each one just
-- queues the citizen and Reconcile reads the orders back from pf-justice (GetOrders) before anything
-- moves. The queue is worked off a moment later (Pump), never inside pf-justice's own event call,
-- which still holds that citizen's lock.
--
-- While pf-justice still lists the old runtime (Config.Compat.LegacyRuntimes.prison ~= false; read
-- from its config file, or forced by Config.Justice.Runtime) the old metadata jail in main.lua keeps
-- every sentence it gives, and the orders pf-justice imported from it (legacy_ref 'meta_...') are
-- its shadows, not ours. Orders pf-justice creates itself are taken in either way.

PFPrison = PFPrison or {}
PFPrison.Bridge = PFPrison.Bridge or {}
local B = PFPrison.Bridge
local I = PFPrison.Internal
local JC = Config.Justice or {}
local FAC = JC.Facility or 'bolingbroke'
local INCARCERATION = { jail = true, prison = true, remand = true }
local EVENT_KINDS = { intake = true, release = true, work = true, credit = true, escape = true, recapture = true,
    sendback = true, anomaly = true, lockdown = true, count = true, search = true }

B.rows = B.rows or {}       -- [cid] = pf_prison_inmates row (every row, online or not; loaded at start)
B.queue = B.queue or {}     -- [cid] = true: look at this citizen's orders again
B.actions = B.actions or {} -- [cid] = { kind = 'suspend' | 'resume', orderId, key, reason, attempts }
B.credits = B.credits or {} -- [key] = { cid, action }: a work credit that found pf-justice busy (same key again)
B.pending = B.pending or {} -- [src] = orderId waiting for transport intake
B.escapees = B.escapees or {} -- [src] = cid: online escapees (watched for a return inside the walls)
B.busy = B.busy or {}       -- [cid] = true while a reconcile of that citizen runs
B.needSeize = B.needSeize or {} -- [cid] = orderId: an intake whose property could not be taken yet
B.loadAt = B.loadAt or {}   -- [src] = os.time() when the check after a login is due

local function num(v, default) return tonumber(v) or default end
local function validCid(cid) return type(cid) == 'string' and #cid >= 1 and #cid <= 64 and cid:match('^[%w_%-]+$') ~= nil end
local function validKey(k) return type(k) == 'string' and #k >= 1 and #k <= 128 and k:match('^[%w%-_:%.]+$') ~= nil end

local function playerByCid(cid)
    local ok, P = pcall(function() return exports['pfm-core']:GetPlayerByCitizenId(cid) end)
    if ok and type(P) == 'table' and P.PlayerData then return P end
    return nil
end

local function cidOf(src)
    local P = I.getPlayer(src)
    return P and P.PlayerData.citizenid or nil
end

-- ── which runtime owns the sentences ────────────────────────────────────────────────────────────

local justiceFile -- nil = not read yet; false = unreadable; table = { live = Config.Compat.LegacyRuntimes }

--- pf-justice's Config.Compat.LegacyRuntimes as its config file says (nil when it cannot be read).
--- The file only assigns Config.*; it runs with nothing else in reach.
function B.JusticeFlags()
    if justiceFile ~= nil then return justiceFile and justiceFile.live or nil end
    justiceFile = false
    if LoadResourceFile == nil or load == nil then return nil end
    local okRead, text = pcall(LoadResourceFile, 'pf-justice', 'config.lua')
    if not okRead or type(text) ~= 'string' or text == '' then return nil end
    local env = { vector3 = vector3, vector4 = vector4, vector2 = vector2, vec3 = vec3 }
    local chunk = load(text, '@pf-justice/config.lua', 't', env)
    if not chunk or not pcall(chunk) or type(env.Config) ~= 'table' then return nil end
    local compat = type(env.Config.Compat) == 'table' and env.Config.Compat or {}
    justiceFile = { live = type(compat.LegacyRuntimes) == 'table' and compat.LegacyRuntimes or {} }
    return justiceFile.live
end

--- Decides once which runtime owns this prison's sentences (a change needs a restart of both).
function B.ResolveMode()
    local forced = tostring(JC.Runtime or 'auto'):lower()
    local how
    if forced == 'justice' or forced == 'legacy' then
        B.mode, how = forced, 'Config.Justice.Runtime'
    else
        local live = B.JusticeFlags()
        if live == nil then
            B.mode = 'legacy'
            how = GetResourceState('pf-justice') == 'missing' and 'pf-justice is not installed' or 'pf-justice config.lua could not be read'
        else
            -- pf-justice's own rule: a runtime is live unless its flag is exactly false
            B.mode, how = live.prison == false and 'justice' or 'legacy', 'pf-justice Config.Compat.LegacyRuntimes.prison'
        end
    end
    B.modeHow = how
    print(('^2[pfm-prison]^7 sentences: %s (%s)'):format(B.mode == 'justice' and 'pf-justice orders' or 'old metadata jail', how))
    return B.mode
end

--- Forgets the decision (specs; a restart does the same).
function B.ResetMode() justiceFile, B.mode = nil, nil end

function B.LegacyRuntime()
    if B.mode == nil then B.ResolveMode() end
    return B.mode ~= 'justice'
end

-- Imported MDT jails stay the MDT's while pf-justice lists the MDT jail as running.
local function legacyLive(name)
    if name == 'prison' then return B.LegacyRuntime() end
    local live = B.JusticeFlags()
    return not (type(live) == 'table' and live[name] == false)
end

-- ── pf-justice calls ────────────────────────────────────────────────────────────────────────────

--- One pf-justice export call; nil when pf-justice is not running or the call broke off.
local function ju(name, ...)
    if GetResourceState('pf-justice') ~= 'started' then return nil end
    local n, args = select('#', ...), { ... }
    local ok, a, b = pcall(function()
        local e = exports['pf-justice']
        return e[name](e, table.unpack(args, 1, n))
    end)
    if not ok then
        print(('^1[pfm-prison]^7 pf-justice %s failed: %s'):format(name, tostring(a)))
        return nil
    end
    return a, b
end
B.Justice = ju

local SYSTEM = { kind = 'system', label = 'pfm-prison' }

-- An order pf-justice imported from an old jail that still runs is that jail's (a shadow).
local function isShadow(o)
    local ref = o.legacyRef
    if type(ref) ~= 'string' or ref == '' then return false end
    if ref:sub(1, 4) == 'mdt_' then return legacyLive('mdt') end
    if ref:sub(1, 5) == 'meta_' then return legacyLive('prison') end
    return false
end

--- The citizen's open incarceration orders (shadows left out), oldest first; nil when pf-justice
--- cannot answer.
function B.OpenOrders(cid)
    local res = ju('GetOrders', cid, { kinds = { 'jail', 'prison', 'remand' }, states = { 'pending', 'active', 'suspended' }, limit = 100 })
    if type(res) ~= 'table' or res.ok ~= true or type(res.list) ~= 'table' then return nil end
    local out = {}
    for _, o in ipairs(res.list) do
        if type(o) == 'table' and INCARCERATION[o.kind] and tonumber(o.id) and not isShadow(o) then out[#out + 1] = o end
    end
    table.sort(out, function(a, b) return tonumber(a.id) < tonumber(b.id) end)
    return out
end

--- Minutes left on the citizen's sentence (pf-justice's clock).
function B.Minutes(src)
    local v = ju('GetJailMinutes', tonumber(src))
    return math.max(0, math.floor(num(v, 0)))
end
B.JailMinutes = B.Minutes

-- ── storage ─────────────────────────────────────────────────────────────────────────────────────

B.SQL = {
    upsert = [[INSERT INTO pf_prison_inmates (citizenid, order_id, facility, status, cell_id, classification, admitted_at, status_at,
        job_ticket, receipt_ids) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE order_id = VALUES(order_id), facility = VALUES(facility), status = VALUES(status),
        cell_id = VALUES(cell_id), classification = VALUES(classification), admitted_at = VALUES(admitted_at),
        status_at = VALUES(status_at), job_ticket = VALUES(job_ticket), receipt_ids = VALUES(receipt_ids)]],
    delete = 'DELETE FROM pf_prison_inmates WHERE citizenid = ?',
    all = 'SELECT * FROM pf_prison_inmates',
    event = 'INSERT INTO pf_prison_events (citizenid, facility, kind, detail, actor_cid, at) VALUES (?, ?, ?, ?, ?, ?)',
    sweep = 'DELETE FROM pf_prison_events WHERE at < ? LIMIT 500',
    anonEvents = 'UPDATE pf_prison_events SET citizenid = NULL WHERE citizenid = ?',
    anonActor = 'UPDATE pf_prison_events SET actor_cid = NULL WHERE actor_cid = ?',
}

local function dbReady() return PFPrisonSchema ~= nil and PFPrisonSchema.Ready() end

local function db(kind, sql, params)
    if not dbReady() then return nil, false end
    local ok, res = pcall(MySQL[kind].await, sql, params or {})
    if not ok then
        print(('^1[pfm-prison]^7 database error: %s'):format(tostring(res)))
        return nil, false
    end
    return res, true
end

local function encode(v)
    local ok, s = pcall(json.encode, v)
    return ok and s or nil
end

local function decodeIds(s)
    local out = {}
    if type(s) ~= 'string' or s == '' then return out end
    local ok, v = pcall(json.decode, s)
    for _, id in ipairs(ok and type(v) == 'table' and v or {}) do
        id = math.tointeger(tonumber(id))
        if id and id > 0 then out[#out + 1] = id end
    end
    return out
end

--- Writes the row (memory is the truth while the server runs; the table makes it survive a restart).
function B.SaveRow(row)
    local ids = {}
    for i, id in ipairs(row.receipt_ids or {}) do if i <= 20 then ids[i] = id end end
    db('update', B.SQL.upsert, { row.citizenid, row.order_id, row.facility or FAC, row.status, row.cell_id, row.classification or 'medium',
        row.admitted_at, row.status_at, row.job_ticket or 0, #ids > 0 and encode(ids) or nil })
end

function B.DeleteRow(cid) db('update', B.SQL.delete, { cid }) end

--- One pf_prison_events row (architecture 3.8). detail is clipped to 4 KB.
function B.Event(cid, kind, detail, actorCid)
    if not EVENT_KINDS[kind] then return false end
    local s = detail ~= nil and encode(detail) or nil
    if s and #s > 4096 then s = encode({ truncated = true }) end
    local _, ok = db('insert', B.SQL.event, { validCid(cid) and cid or nil, FAC, kind, s, validCid(actorCid) and actorCid or nil, os.time() })
    return ok
end

local function normRow(r)
    if type(r) ~= 'table' or not validCid(r.citizenid) then return nil end
    return {
        citizenid = r.citizenid, order_id = math.tointeger(tonumber(r.order_id)), facility = r.facility or FAC,
        status = r.status, cell_id = r.cell_id, classification = r.classification or 'medium',
        admitted_at = tonumber(r.admitted_at), status_at = tonumber(r.status_at), job_ticket = tonumber(r.job_ticket) or 0,
        receipt_ids = type(r.receipt_ids) == 'table' and r.receipt_ids or decodeIds(r.receipt_ids),
    }
end

--- Loads every stored row (rows already in memory win: they are newer).
function B.LoadRows()
    local rows, ok = db('query', B.SQL.all, {})
    if not ok then return false end
    for _, r in ipairs(type(rows) == 'table' and rows or {}) do
        local row = normRow(r)
        if row and not B.rows[row.citizenid] then B.rows[row.citizenid] = row end
    end
    -- rows made while the table was not usable
    for _, row in pairs(B.rows) do B.SaveRow(row) end
    return true
end

-- ── queue ───────────────────────────────────────────────────────────────────────────────────────

--- Asks for the citizen's orders to be looked at again soon.
function B.Touch(cid)
    if not validCid(cid) then return end
    B.queue[cid] = true
    B.Kick()
end

--- Works the queue off on the next scheduler tick (after pf-justice's own event call returned).
function B.Kick()
    if B.kickPending then return end
    B.kickPending = true
    CreateThread(function()
        B.kickPending = false
        B.Pump()
    end)
end

function B.QueueAction(cid, action)
    action.attempts = action.attempts or 0
    B.actions[cid] = action
    return action
end

local PERMANENT = { invalid_state = true, not_found = true, bad_args = true, no_permission = true, not_allowed = true, key_reused = true }

--- Runs a queued AdjustOrder (suspend, resume or a credit that found pf-justice busy).
--- Returns true when it is settled (done or given up), false to retry.
function B.RunAction(cid, a)
    local change = { kind = a.kind, reason = a.reason }
    if a.kind == 'credit' then change.seconds = a.seconds end
    local res = ju('AdjustOrder', a.orderId, change, { key = a.key, actor = SYSTEM })
    if type(res) == 'table' and res.ok == true then
        if B.actions[cid] == a then B.actions[cid] = nil end
        B.queue[cid] = true
        return true, res
    end
    local err = type(res) == 'table' and res.error or 'justice_unavailable'
    a.attempts = a.attempts + 1
    if PERMANENT[err] or a.attempts >= num(JC.MaxActionAttempts, 10) then
        if B.actions[cid] == a then B.actions[cid] = nil end
        B.Event(cid, 'anomaly', { what = a.kind .. '_refused', orderId = a.orderId, error = err, attempts = a.attempts })
        B.queue[cid] = true
        return true, res
    end
    return false, res
end

-- ── intake ──────────────────────────────────────────────────────────────────────────────────────

local function hasItems(P)
    for _, it in pairs(P.PlayerData.items or {}) do
        if type(it) == 'table' and type(it.name) == 'string' and num(it.amount, 0) > 0 then return true end
    end
    return false
end

local function addReceipt(row, id)
    id = math.tointeger(tonumber(id))
    if not id then return end
    row.receipt_ids = row.receipt_ids or {}
    for _, have in ipairs(row.receipt_ids) do if have == id then return end end
    if #row.receipt_ids < 20 then row.receipt_ids[#row.receipt_ids + 1] = id end
end

--- Everything the inmate carries goes into a pf-justice property locker. Returns the receipt id,
--- or nil, error (nothing was taken then: pf-justice rolls a failed seizure back).
local function seize(src, orderId, key)
    local res = ju('SeizeProperty', src, { orderId = orderId, items = 'all', reason = 'Bolingbroke intake', key = key, actor = SYSTEM })
    if type(res) == 'table' and res.ok == true then return math.tointeger(tonumber(res.receiptId)), res.duplicate == true end
    return nil, type(res) == 'table' and res.error or 'justice_unavailable'
end

--- Takes the property of an admitted inmate (intake, a retry, a return after an escape).
function B.TakeProperty(src, row, how)
    local P = I.getPlayer(src)
    if not P or not hasItems(P) then
        B.needSeize[row.citizenid] = nil
        return true
    end
    local key = how == 'intake' and ('pfm-prison:intake:%d'):format(row.order_id)
        or ('pfm-prison:readmit:%d:%d'):format(row.order_id, os.time())
    local id, dup = seize(src, row.order_id, key)
    if id and dup then
        -- this intake's receipt exists from before (a restart lost the row): take what they hold now
        P = I.getPlayer(src)
        if P and hasItems(P) then id = seize(src, row.order_id, ('pfm-prison:readmit:%d:%d'):format(row.order_id, os.time())) or id end
    end
    if not id then
        -- logged once; the pump tries again while they are inside
        if not B.needSeize[row.citizenid] then
            B.Event(row.citizenid, 'anomaly', { what = 'seizure_failed', orderId = row.order_id, error = tostring(dup) })
        end
        B.needSeize[row.citizenid] = row.order_id
        return false
    end
    addReceipt(row, id)
    B.needSeize[row.citizenid] = nil
    return true
end

--- Takes an online citizen in for an active order at this prison. how = 'intake' (a new order) or
--- 'readmit' (an escapee brought back). The caller holds the citizen's reconcile lock.
function B.Admit(src, order, how)
    local P = I.getPlayer(src)
    if not P then return 'offline' end
    local cid = P.PlayerData.citizenid
    local now = os.time()
    local orderId = math.tointeger(tonumber(order.id))
    local row = B.rows[cid]
    local fresh = row == nil or row.status == 'releasing' or row.status == 'intake'
    if fresh then
        -- a stay that ended while they were offline (its lockers were handed back then) or a first one
        row = { citizenid = cid, classification = 'medium', receipt_ids = {}, job_ticket = 0, admitted_at = now }
        how = 'intake'
    end
    row.order_id, row.facility, row.status, row.status_at = orderId, FAC, 'in_cell', now
    B.rows[cid] = row
    -- the property first: nothing they carry comes into the yard (a failure is retried by the pump)
    B.TakeProperty(src, row, how)
    PFPrison.ApplyJobRule(src)
    if how == 'intake' then
        I.gotPhone[cid] = nil
        local money = math.floor(num(Config.Prison and Config.Prison.JailMoney, 80))
        if money > 0 and PFPayout then
            PFPayout.Pay(cid, 'cash', money, { key = ('pfm-prison:jailmoney:%s:%d'):format(cid, orderId), reason = 'jail money', quiet = true })
        end
    end
    B.SaveRow(row)
    B.Event(cid, how == 'readmit' and 'recapture' or 'intake', { orderId = orderId, kind = order.kind, receipts = #(row.receipt_ids or {}) })
    B.escapees[src], B.pending[src] = nil, nil
    I.startTracking(src, 'justice')
    local job = I.assignJob(src)
    TriggerClientEvent('prison:client:Enter', src, B.Minutes(src), job and job.name, job and job.location, how == 'readmit', true)
    TriggerEvent('pfm-prison:server:inmateStatus', cid, 'in_cell')
    return 'admitted'
end

-- ── release ─────────────────────────────────────────────────────────────────────────────────────

local function returnReceipts(row, src)
    for _, id in ipairs(row.receipt_ids or {}) do
        -- pf-justice also returns the receipts of the last order; a second return is a no-op there
        ju('ReturnProperty', id, { toSrc = src, key = ('pfm-prison:return:%d'):format(id), actor = SYSTEM })
    end
end

--- Lets an online citizen out (once: the row goes first) and gives their locker back.
function B.Release(src, row, why)
    local cid = row.citizenid
    if B.rows[cid] ~= row then return 'gone' end
    B.rows[cid] = nil
    B.DeleteRow(cid)
    B.needSeize[cid] = nil
    if B.actions[cid] and B.actions[cid].kind ~= 'credit' then B.actions[cid] = nil end
    I.forget(src)
    B.escapees[src], B.pending[src] = nil, nil
    I.gotPhone[cid] = nil
    returnReceipts(row, src)
    B.Event(cid, 'release', { orderId = row.order_id, reason = why, status = row.status })
    TriggerClientEvent('prison:client:Released', src, why)
    TriggerEvent('pfm-prison:server:inmateStatus', cid, 'released')
    return 'released'
end

-- ── reconcile ───────────────────────────────────────────────────────────────────────────────────

local function sendState(src, enter)
    local job = I.jobs[src] or I.assignJob(src)
    if enter then
        TriggerClientEvent('prison:client:Enter', src, B.Minutes(src), job and job.name, job and job.location, false, true)
    else
        TriggerClientEvent('prison:client:SetJob', src, job and job.name, job and job.location, B.Minutes(src))
    end
end

-- An offline citizen: nothing moves physically; a finished stay is marked so the next login lets
-- them out, and the locker is handed back (pf-justice delivers it at that login).
local function reconcileOffline(cid, row)
    if not row then return 'none' end
    local list = B.OpenOrders(cid)
    if not list then return 'retry' end
    for _, o in ipairs(list) do
        if o.facility == FAC and (o.state == 'active' or o.state == 'suspended') then return 'offline' end
    end
    if row.status == 'releasing' then return 'releasing' end
    returnReceipts(row, nil)
    if row.status == 'escaped' then
        -- not inside: nothing to let out at the next login
        B.rows[cid] = nil
        B.DeleteRow(cid)
        B.Event(cid, 'release', { orderId = row.order_id, reason = 'order ended while escaped', status = row.status })
        TriggerEvent('pfm-prison:server:inmateStatus', cid, 'released')
        return 'released'
    end
    row.status, row.status_at = 'releasing', os.time()
    B.SaveRow(row)
    return 'releasing'
end

local function reconcileLocked(cid, opts)
    local P = playerByCid(cid)
    local row = B.rows[cid]
    if not P then return reconcileOffline(cid, row) end
    local src = tonumber(P.PlayerData.source)
    if not src then return 'none' end
    -- held by the old runtime: a pf-justice order waits until that sentence ends
    if I.inmates[src] == 'legacy' then return 'legacy' end
    local list = B.OpenOrders(cid)
    if not list then return 'retry' end
    local active, suspended, intake
    for _, o in ipairs(list) do
        if o.state == 'active' then active = o
        elseif o.state == 'suspended' then suspended = suspended or o
        elseif o.state == 'pending' and not o.parentOrderId then intake = intake or o end
    end

    if active then
        if active.facility ~= FAC then
            -- serving somewhere else now (a station holding cell): out of this prison
            if row then return B.Release(src, row, 'transferred') end
            return 'elsewhere'
        end
        B.pending[src] = nil
        if not row or row.status == 'releasing' or row.status == 'intake' then return B.Admit(src, active, 'intake') end
        if row.status == 'escaped' then
            -- the escape is still being suspended; otherwise the order runs again (resumed)
            if B.actions[cid] and B.actions[cid].kind == 'suspend' then return 'escaping' end
            return B.Admit(src, active, 'readmit')
        end
        -- serving: the chain may have moved on to its next order
        if row.order_id ~= math.tointeger(tonumber(active.id)) then
            row.order_id = math.tointeger(tonumber(active.id))
            B.SaveRow(row)
        end
        if B.needSeize[cid] then B.TakeProperty(src, row, 'readmit') end
        if I.inmates[src] ~= 'justice' then I.startTracking(src, 'justice') end
        if opts.enter or opts.state then sendState(src, opts.enter) end
        return 'serving'
    end

    if suspended then
        if row and row.status == 'escaped' then
            B.escapees[src] = cid
            -- caught and sentenced again since the escape: the old order serves on with the new one
            for _, o in ipairs(list) do
                if o.id ~= suspended.id and num(o.createdAt, 0) >= num(row.status_at, 0) and not B.actions[cid] then
                    B.QueueAction(cid, { kind = 'resume', orderId = math.tointeger(tonumber(suspended.id)),
                        key = ('pfm-prison:resume:%d:%d'):format(suspended.id, os.time()), reason = 'recaptured: new sentence' })
                    return 'recapture'
                end
            end
            return 'escaped'
        end
        if row then
            -- suspended while inside (a court stay, an admin): they stay; pf-justice's clock is stopped
            if I.inmates[src] ~= 'justice' and row.status == 'in_cell' then I.startTracking(src, 'justice') end
            if opts.enter or opts.state then sendState(src, opts.enter) end
            return 'held'
        end
        return 'suspended'
    end

    if intake and intake.facility == FAC then
        B.pending[src] = math.tointeger(tonumber(intake.id))
        return 'awaiting_intake'
    end

    if row then return B.Release(src, row, row.status == 'escaped' and 'order ended' or 'released') end
    B.pending[src] = nil
    return 'none'
end

--- Looks at the citizen's pf-justice orders and brings this prison in line: takes them in, lets
--- them out, follows an escape or a recapture. opts = { enter = send the cell, state = send the time }.
function B.Reconcile(cid, opts)
    if not validCid(cid) then return 'none' end
    if B.busy[cid] then
        B.queue[cid] = true
        return 'busy'
    end
    B.busy[cid] = true
    local ok, res = pcall(reconcileLocked, cid, opts or {})
    B.busy[cid] = nil
    if not ok then
        print(('^1[pfm-prison]^7 reconcile of %s failed: %s'):format(cid, tostring(res)))
        B.queue[cid] = true
        return 'error'
    end
    if res == 'retry' then B.queue[cid] = true end
    return res
end

-- ── the pump ────────────────────────────────────────────────────────────────────────────────────

local function keys(t)
    local out = {}
    for k in pairs(t) do out[#out + 1] = k end
    return out
end

--- A transport intake: the prisoner of a pending order was brought to the intake point.
function B.IntakeTick()
    local zone = JC.Intake
    if type(zone) ~= 'table' or not zone.coords then return 0 end
    local n = 0
    for _, src in ipairs(keys(B.pending)) do
        local orderId = B.pending[src]
        local pos = I.pedPos(src)
        if pos and #(vector3(pos.x, pos.y, pos.z) - zone.coords) <= num(zone.radius, 15.0) then
            local res = ju('SetOrderState', orderId, 'active', { reason = 'Bolingbroke intake', actor = SYSTEM })
            if type(res) == 'table' and res.ok == true then
                B.pending[src] = nil
                n = n + 1
                local cid = cidOf(src)
                if cid then B.queue[cid] = true end
            end
        end
    end
    return n
end

--- Works off everything queued (every PumpSeconds, and right after a pf-justice event).
function B.Pump(now)
    if B.pumping then return end
    B.pumping = true
    local ok, err = pcall(function()
        now = now or os.time()
        for _, cid in ipairs(keys(B.actions)) do
            local a = B.actions[cid]
            if a then B.RunAction(cid, a) end
        end
        for _, key in ipairs(keys(B.credits)) do
            local c = B.credits[key]
            local done, res = B.RunAction(c.cid, c.action)
            if done then
                B.credits[key] = nil
                if type(res) == 'table' and res.ok == true then
                    B.Event(c.cid, 'credit', { orderId = c.action.orderId, seconds = c.action.seconds, applied = tonumber(res.applied) or 0, retried = true })
                end
            end
        end
        for _, src in ipairs(keys(B.loadAt)) do
            if now >= B.loadAt[src] then
                B.loadAt[src] = nil
                local cid = cidOf(src)
                if cid then B.queue[cid] = true end
            end
        end
        for _, cid in ipairs(keys(B.needSeize)) do B.queue[cid] = true end
        local list = B.queue
        B.queue = {}
        for cid in pairs(list) do B.Reconcile(cid) end
        B.IntakeTick()
    end)
    B.pumping = false
    if not ok then print(('^1[pfm-prison]^7 pump failed: %s'):format(tostring(err))) end
end

-- ── what main.lua asks ──────────────────────────────────────────────────────────────────────────

--- A citizen this prison holds for a pf-justice order and who is inside (not escaped).
function B.IsAdmitted(src)
    local cid = cidOf(src)
    local row = cid and B.rows[cid]
    return row ~= nil and row.status == 'in_cell'
end

--- Work: a time credit on the order. Returns the minutes left afterwards (pf-justice's clock).
function B.Credit(src, job, seconds)
    local cid = cidOf(src)
    local row = cid and B.rows[cid]
    if not row or not row.order_id then return nil end
    local a = { kind = 'credit', orderId = row.order_id, seconds = math.floor(seconds),
        key = ('pfm-prison:credit:%d:%s'):format(row.order_id, tostring(job.ticket)), reason = 'prison work', attempts = 0 }
    local done, res = B.RunAction(cid, a)
    if type(res) == 'table' and res.ok == true then
        local applied = tonumber(res.applied) or 0
        row.job_ticket = (row.job_ticket or 0) + 1
        B.SaveRow(row)
        B.Event(cid, 'credit', { orderId = row.order_id, seconds = a.seconds, applied = applied, ticket = tostring(job.ticket) })
        I.notify(src, Lang:t(applied > 0 and 'success.time_cut' or 'info.no_more_credit'), applied > 0 and 'success' or 'primary')
    elseif not done then
        -- pf-justice was busy: the same key is tried again (it never credits twice)
        B.credits[a.key] = { cid = cid, action = a }
    end
    return B.Minutes(src)
end

--- A confirmed escape of a pf-justice inmate (main.lua already stopped tracking and raises the
--- alarm): the order is suspended, the property stays in the locker (D12).
function B.OnEscape(src, pos)
    local cid = cidOf(src)
    local row = cid and B.rows[cid]
    if not row then return end
    local now = os.time()
    row.status, row.status_at = 'escaped', now
    B.SaveRow(row)
    B.escapees[src] = cid
    B.Event(cid, 'escape', { orderId = row.order_id, x = pos and math.floor(pos.x) or nil, y = pos and math.floor(pos.y) or nil })
    local a = B.QueueAction(cid, { kind = 'suspend', orderId = row.order_id,
        key = ('pfm-prison:escape:%d:%d'):format(row.order_id, now), reason = 'escaped from ' .. FAC })
    TriggerEvent('pfm-prison:server:escape', cid, { orderId = row.order_id, facility = FAC, at = now,
        coords = pos and { x = pos.x, y = pos.y, z = pos.z } or nil })
    TriggerEvent('pfm-prison:server:inmateStatus', cid, 'escaped')
    B.RunAction(cid, a)
end

--- Online escapees seen back inside the walls serve on (every sample tick).
function B.WatchEscapees(now)
    if JC.RecaptureInside == false then return end
    for _, src in ipairs(keys(B.escapees)) do
        local cid = B.escapees[src]
        local row = B.rows[cid]
        if not row or row.status ~= 'escaped' or cidOf(src) ~= cid then
            B.escapees[src] = nil
        elseif I.insidePrison(I.pedPos(src)) then
            B.escapees[src] = nil
            local a = B.actions[cid]
            if a and a.kind == 'suspend' then
                -- back before the suspension went through: nothing to resume
                B.actions[cid] = nil
            elseif not a then
                B.QueueAction(cid, { kind = 'resume', orderId = row.order_id,
                    key = ('pfm-prison:resume:%d:%d'):format(row.order_id, now or os.time()), reason = 'back inside the walls' })
            end
            B.queue[cid] = true
            B.Kick()
        end
    end
end

--- prison:server:RequestState for anyone this bridge holds (or a pf-justice order of theirs). True
--- when it answered; false lets the old runtime answer.
function B.RequestState(src, wantEnter)
    local cid = cidOf(src)
    if not cid then return false end
    local res = B.Reconcile(cid, { enter = wantEnter, state = true })
    return res == 'serving' or res == 'admitted' or res == 'held' or res == 'escaped' or res == 'escaping'
        or res == 'recapture' or res == 'awaiting_intake' or res == 'released' or res == 'busy'
end

function B.OnPlayerLoaded(src)
    -- after pf-justice's own login work (its legacy import, its clock): then look at the orders
    B.loadAt[src] = os.time() + num(JC.LoadDelaySeconds, 3)
end

function B.OnDropped(src)
    B.pending[src], B.escapees[src], B.loadAt[src] = nil, nil, nil
end

function B.OnLegacyReleased(src)
    local cid = cidOf(src)
    if cid then B.Touch(cid) end
end

-- ── forwarders (legacy exports) ─────────────────────────────────────────────────────────────────

local SOURCE_TYPES = { ['pfm-policejob'] = 'field', ['pfm-adminmenu'] = 'admin', ['pf-policemdt-DEV'] = 'mdt_sentence' }

--- JailPlayer(src, minutes, opts) -> pf-justice CreateOrder (kind 'prison' at this prison).
function B.ForwardJail(src, minutes, opts, invoker)
    src = tonumber(src)
    local P = src and I.getPlayer(src)
    if not P then return false, 'no_player' end
    minutes = tonumber(minutes)
    if not minutes or minutes ~= minutes or minutes == math.huge then return false, 'bad_time' end
    minutes = math.floor(minutes)
    if minutes < 1 then return false, 'bad_time' end
    minutes = math.min(minutes, math.floor(num(Config.MaxJailTime, 1440)), 1440)
    local cid = P.PlayerData.citizenid
    local key = validKey(opts.key) and opts.key or ('pfm-prison:jail:%s:%s'):format(cid, PFPayout.NewId())
    local actor = SYSTEM
    local officer = tonumber(opts.officer)
    if officer and I.getPlayer(officer) then actor = { src = officer } end
    local res = ju('CreateOrder', {
        cid = cid, kind = 'prison', minutes = minutes, facility = FAC,
        sourceRef = { type = SOURCE_TYPES[invoker or ''] or 'legacy' },
    }, { key = key, actor = actor })
    if res == nil then return false, 'justice_unavailable' end
    if type(res) ~= 'table' or res.ok ~= true then return false, type(res) == 'table' and res.error or 'refused' end
    B.Touch(cid)
    return true
end

--- ReleasePlayer(src, reason) -> pf-justice ReleaseNow (every open incarceration order).
function B.ForwardRelease(src, reason, invoker)
    src = tonumber(src)
    local P = src and I.getPlayer(src)
    if not P then return false, 'no_player' end
    local res = ju('ReleaseNow', src, reason, { actor = { kind = 'system', label = 'pfm-prison ReleasePlayer ' .. tostring(invoker or '') } })
    if res == nil then return false, 'justice_unavailable' end
    if type(res) ~= 'table' or res.ok ~= true then return false, type(res) == 'table' and res.error or 'refused' end
    B.Touch(P.PlayerData.citizenid)
    if (tonumber(res.released) or 0) < 1 then return false, 'not_jailed' end
    return true
end

-- ── exports ─────────────────────────────────────────────────────────────────────────────────────

-- pf-justice's presence provider for 'bolingbroke': the server's own position against the walls
-- (the same test the escape sampler uses); an escapee is never inside.
exports('IsInside', function(src)
    src = math.tointeger(tonumber(src))
    if not src or src < 1 then return false end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    local cid = cidOf(src)
    local row = cid and B.rows[cid]
    if row and row.status == 'escaped' then return false end
    return I.insidePrison(I.pedPos(src)) == true
end)

--- GetInmate(who): who = server id or citizenid. { ok, inmate? = { cid, orderId, cellId,
--- classification, status, since, admittedAt } }. Cells and classification come with batch 19.
exports('GetInmate', function(who)
    local cid, P
    if type(who) == 'number' then
        P = I.getPlayer(who)
        cid = P and P.PlayerData.citizenid
    elseif validCid(who) then
        cid = who
    end
    if not cid then return { ok = false, error = 'bad_args', message = 'Unknown player or citizen id' } end
    local row = B.rows[cid]
    if row then
        return { ok = true, inmate = { cid = cid, orderId = row.order_id, cellId = row.cell_id, classification = row.classification,
            status = row.status, since = row.status_at, admittedAt = row.admitted_at } }
    end
    if B.LegacyRuntime() then
        P = P or playerByCid(cid)
        if P and I.sentenceOf(P) > 0 then
            return { ok = true, inmate = { cid = cid, status = 'in_cell', classification = 'medium', legacy = true } }
        end
    end
    return { ok = true }
end)

--- GetFacilityStatus(facility): population (held here, escapees not counted), who is online,
--- lockdown and alarm. Head counts and cells are batch 19 (not shown until they exist).
exports('GetFacilityStatus', function(facility)
    facility = facility or FAC
    if facility ~= FAC then return { ok = false, error = 'not_found', message = 'No such facility' } end
    local population, escaped = 0, 0
    for _, row in pairs(B.rows) do
        if row.status == 'escaped' then escaped = escaped + 1
        elseif row.status ~= 'releasing' then population = population + 1 end
    end
    local online, legacy = 0, 0
    for _, regime in pairs(I.inmates) do
        online = online + 1
        if regime == 'legacy' then legacy = legacy + 1 end
    end
    local gates = 0
    for _ in pairs(I.gateOpen) do gates = gates + 1 end
    local now = os.time()
    local lockUntil = I.lockdownUntil()
    return { ok = true, facility = FAC, population = population + legacy, online = online, escaped = escaped,
        lockdown = lockUntil > now, lockdownUntil = lockUntil > now and lockUntil or nil,
        alarms = { alarm = I.alarmActive() == true, gatesOpen = gates } }
end)

-- ── pf-justice events (hints: the orders are read back before anything moves) ───────────────────

local function fromServer()
    local s = tonumber(source)
    return not (s and s > 0)
end

local function hint(order)
    if not fromServer() or type(order) ~= 'table' then return end
    local cid = order.cid or order.citizenid
    if validCid(cid) then B.Touch(cid) end
end

AddEventHandler('pf-justice:server:orderCreated', function(order) hint(order) end)
AddEventHandler('pf-justice:server:orderChanged', function(order) hint(order) end)
AddEventHandler('pf-justice:server:releaseOrdered', function(cid) hint({ cid = cid }) end)
AddEventHandler('pf-justice:server:legacyImported', function(cid) hint({ cid = cid }) end)

AddEventHandler('pfm-core:server:characterDeleted', function(cid)
    if not fromServer() or not validCid(cid) then return end
    B.rows[cid], B.needSeize[cid], B.actions[cid], B.queue[cid] = nil, nil, nil, nil
    B.DeleteRow(cid)
    db('update', B.SQL.anonEvents, { cid })
    db('update', B.SQL.anonActor, { cid })
end)

-- ── start ───────────────────────────────────────────────────────────────────────────────────────

--- Deletes event rows older than Config.Justice.EventRetentionDays (500 per call).
function B.SweepEvents(now)
    local cutoff = (now or os.time()) - num(JC.EventRetentionDays, 180) * 86400
    local res = db('update', B.SQL.sweep, { cutoff })
    return tonumber(res) or 0
end

--- Start: the runtime decision, the tables, the stored rows, and a look at everyone online.
--- Returns true when the tables are usable (CreateThread does nothing in specs: they call it).
function B.Boot()
    if B.mode == nil then B.ResolveMode() end
    local ready = PFPrisonSchema and PFPrisonSchema.Run()
    if ready then B.LoadRows() end
    for _, src in ipairs(I.players()) do
        local cid = cidOf(src)
        if cid then B.queue[cid] = true end
    end
    return ready == true
end

CreateThread(function()
    Wait(1500) -- pfm-core's migration runner and pf-justice start first
    local ready = B.Boot()
    B.Pump()
    local schemaWait, sweepAt = 0, os.time() + 3600
    while true do
        Wait(math.max(1, num(JC.PumpSeconds, 2)) * 1000)
        if not ready then
            schemaWait = schemaWait + num(JC.PumpSeconds, 2)
            if schemaWait >= 30 then
                schemaWait = 0
                ready = PFPrisonSchema.Run()
                if ready then B.LoadRows() end
            end
        end
        B.Pump()
        if os.time() >= sweepAt then
            sweepAt = os.time() + 86400
            pcall(B.SweepEvents)
        end
    end
end)
