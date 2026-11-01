-- Settlements: money a vehicle sale still owes, and sales waiting on the bank. Loaded by
-- pfm-vehicleshop ('settlements.lua') and pfm-vehiclesales ('@pfm-vehicleshop/settlements.lua'),
-- after '@pfm-banking/payouts.lua'. Each resource keeps its own two tables (<prefix>_owed,
-- <prefix>_held, created by its migrations) and pays from its own system:<resource> account.
--
-- Owed payments (PFSettle.Owe): a payout that must happen after a buyer was charged (the seller's
-- money, a refund, the dealership's share). When the first try does not complete, the payment is
-- stored and the sweep retries it until it does. A ledger key whose transfer failed or was
-- compensated can never pay, so the next try uses the next numbered key (<key>:r2, :r3, ...); a key
-- still in flight is asked again and never replaced, so the payment is made once. Until then the
-- money stays in system:<resource>.
--
-- Held sales (PFSettle.Hold): a buyer charge the bank could not confirm (PFPayout.Charge returned
-- res.unclear). The buyer gets no car yet and is never charged again for it; the sale is stored with
-- its charge key and the sweep reads that key in the ledger until it settles. Then the flow's
-- handler finishes the sale (the money arrived) or releases what the sale reserved (nothing was
-- taken). A charge the ledger marked 'interrupted_unverified' (a crash during the debit: the money
-- may or may not have left) is not decided here: no car and no refund, the hold is kept as 'review'
-- and the buyer is told to ask staff, who see the transfer in /ledgerreconcile.

PFSettle = PFSettle or {}
local S = PFSettle

S.SWEEP_MS = 60000
S.MISSING_GRACE = 600   -- seconds: a held charge with no ledger row after this long never started
S.MAX_ATTEMPTS = 20     -- numbered keys per owed payment before it is left to staff ('stuck')
S.handlers = S.handlers or {}   -- [flow] = { charged = fn(hold, account), none = fn(hold), review = fn(hold) }

local OWED, HELD = nil, nil
local heldPlates, heldBuyers = {}, {}   -- [plate] / [citizenid] = number of holds still waiting
local unsavedOwed, unsavedHolds = {}, {} -- rows the database did not take; written again by the sweep

local function log(msg) print('^3[' .. GetCurrentResourceName() .. ' settlements]^7 ' .. msg) end

--- The two tables of a resource (rerun-safe migration steps).
function S.MigrationSteps(prefix)
    return {
        ([[CREATE TABLE IF NOT EXISTS `%s_owed` (
            `id` INT NOT NULL AUTO_INCREMENT,
            `ledger_key` VARCHAR(128) NOT NULL,
            `attempt` INT NOT NULL DEFAULT 1,
            `to_kind` VARCHAR(16) NOT NULL,
            `to_id` VARCHAR(64) NOT NULL,
            `account` VARCHAR(8) NOT NULL DEFAULT 'bank',
            `amount` DECIMAL(14,2) NOT NULL,
            `kind` VARCHAR(32) NOT NULL DEFAULT 'refund',
            `reason` VARCHAR(255) DEFAULT NULL,
            `state` VARCHAR(12) NOT NULL DEFAULT 'open',
            `last_error` VARCHAR(64) DEFAULT NULL,
            `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`),
            UNIQUE KEY `ledger_key` (`ledger_key`),
            KEY `state` (`state`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]]):format(prefix),
        ([[CREATE TABLE IF NOT EXISTS `%s_held` (
            `id` INT NOT NULL AUTO_INCREMENT,
            `flow` VARCHAR(24) NOT NULL,
            `charge_key` VARCHAR(128) NOT NULL,
            `accounts` VARCHAR(32) NOT NULL,
            `tx_id` VARCHAR(64) DEFAULT NULL,
            `citizenid` VARCHAR(64) NOT NULL,
            `plate` VARCHAR(32) DEFAULT NULL,
            `amount` DECIMAL(14,2) NOT NULL,
            `data` LONGTEXT NOT NULL,
            `state` VARCHAR(12) NOT NULL DEFAULT 'waiting',
            `outcome` VARCHAR(32) DEFAULT NULL,
            `created` INT NOT NULL DEFAULT 0,
            `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`),
            UNIQUE KEY `charge_key` (`charge_key`),
            KEY `state` (`state`),
            KEY `plate` (`plate`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]]):format(prefix),
    }
end

local function sql(text) return (text:gsub('{OWED}', OWED):gsub('{HELD}', HELD)) end

S.SQL = {
    insertOwed = [[INSERT IGNORE INTO {OWED} (ledger_key, attempt, to_kind, to_id, account, amount, kind, reason, state, last_error)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]],
    openOwed = "SELECT * FROM {OWED} WHERE state = 'open' ORDER BY id LIMIT 100",
    updateOwed = 'UPDATE {OWED} SET attempt = ?, state = ?, last_error = ? WHERE id = ?',
    -- a charge key held before (a finance payment retried under the same key after the bank did
    -- not take it) reuses its row
    insertHeld = [[INSERT INTO {HELD} (flow, charge_key, accounts, tx_id, citizenid, plate, amount, data, state, created)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'waiting', ?)
        ON DUPLICATE KEY UPDATE id = LAST_INSERT_ID(id), flow = VALUES(flow), accounts = VALUES(accounts), tx_id = VALUES(tx_id),
            citizenid = VALUES(citizenid), plate = VALUES(plate), amount = VALUES(amount), data = VALUES(data), state = 'waiting',
            outcome = NULL, created = VALUES(created)]],
    openHeld = "SELECT * FROM {HELD} WHERE state IN ('waiting', 'finishing') ORDER BY id LIMIT 100",
    markHeld = 'UPDATE {HELD} SET state = ?, outcome = ? WHERE id = ? AND state = ?',
    saveHeld = 'UPDATE {HELD} SET data = ? WHERE id = ?',
}

local function db(kind, name, params)
    local ok, res = pcall(MySQL[kind].await, sql(S.SQL[name]), params or {})
    if not ok then
        log(('%s failed: %s'):format(name, tostring(res)))
        return nil
    end
    return res
end

function S.Init(prefix)
    OWED, HELD = prefix .. '_owed', prefix .. '_held'
end

-- ── telling people ─────────────────────────────────────────────────────────────────────────────

local function sourceOf(cid)
    local ok, P = pcall(function() return exports['pfm-core']:GetPlayerByCitizenId(cid) end)
    return ok and P and P.PlayerData and P.PlayerData.source or nil
end
S.SourceOf = sourceOf

--- Tells a citizen about their sale: a notification when they are online and, when `subject` is
--- given (an outcome that arrives later), a mail too (pf-citizen; read on phone, tablet, computer).
function S.Tell(cid, text, kind, subject)
    local src = sourceOf(cid)
    if src then TriggerClientEvent('QBCore:Notify', src, text, kind or 'primary', 8000) end
    if subject and GetResourceState('pf-citizen') == 'started' then
        pcall(function() exports['pf-citizen']:SendMail(cid, { sender = S.MailSender or 'Vehicle sales', subject = subject, message = text }) end)
    end
end

local function money(n)
    local cents = math.floor((tonumber(n) or 0) * 100 + 0.5)
    if cents % 100 == 0 then return ('$%d'):format(cents // 100) end
    return ('$%.2f'):format(cents / 100)
end
S.Money = money

-- ── owed payments ──────────────────────────────────────────────────────────────────────────────

local function attemptKey(base, n) return n <= 1 and base or ('%s:r%d'):format(base, n) end
S.AttemptKey = attemptKey

local function payOnce(row, key)
    if row.to_kind == 'society' then
        local _, res = PFPayout.PaySociety(row.to_id, row.amount, { key = key, reason = row.reason })
        return type(res) == 'table' and res or { ok = false, error = 'bank_unavailable' }
    end
    local _, res = PFPayout.Pay(row.to_id, row.account, row.amount, { key = key, kind = row.kind, reason = row.reason, quiet = true })
    return type(res) == 'table' and res or { ok = false, error = 'bank_unavailable' }
end

-- A key that can never pay: its transfer failed (nothing moved) or was compensated (refunded).
local function dead(res) return res.state == 'failed' or res.state == 'compensated' end

-- A payment that can never be made by trying again: the recipient does not exist (a deleted
-- character or society) or the request itself is invalid. The money stays in the system account.
local HOPELESS = { unknown_account = true, invalid_request = true, invalid_account = true, invalid_amount = true, same_account = true, invalid_key = true }
local function hopeless(res) return not res.duplicate and HOPELESS[res.error] == true end

--- Tries the row's current key, moving past keys that are dead. Returns the new state
--- ('paid', 'open', 'forfeit', 'stuck') and the last error.
local function settleOwed(row)
    for _ = 1, 3 do
        if row.attempt > S.MAX_ATTEMPTS then return 'stuck', 'too_many_attempts' end
        local res = payOnce(row, attemptKey(row.ledger_key, row.attempt))
        if res.ok then return 'paid' end
        if hopeless(res) then return 'forfeit', res.error end
        -- in flight, the bank not running, a write that failed: the same key next time
        if not dead(res) then return 'open', tostring(res.error or res.state or 'unknown'):sub(1, 64) end
        row.attempt = row.attempt + 1
    end
    return 'open', 'retry'
end

local function saveOwed(row)
    local id = OWED and db('insert', 'insertOwed', { row.ledger_key, row.attempt, row.to_kind, row.to_id, row.account, row.amount, row.kind,
        row.reason and tostring(row.reason):sub(1, 255) or nil, row.state, row.last_error })
    if id == nil then unsavedOwed[#unsavedOwed + 1] = row end
end

--- Pays `amount` from system:<resource> and makes sure it gets paid: when this try does not
--- complete, the payment is stored and the sweep retries it. opts: key (the flow's stable key),
--- to (a citizenid, or 'society:<name>'), account ('bank' | 'cash', players), amount, kind, reason,
--- label (what the payment is for, told to the recipient when it is late).
--- @return boolean paid now
function S.Owe(opts)
    local amount = math.floor((tonumber(opts.amount) or 0) * 100 + 0.5) / 100
    if amount <= 0 then return true end
    local society = type(opts.to) == 'string' and opts.to:match('^society:(.+)$')
    local row = {
        ledger_key = opts.key, attempt = 1, to_kind = society and 'society' or 'player', to_id = society or opts.to,
        account = opts.account == 'cash' and 'cash' or 'bank', amount = amount, kind = opts.kind or 'refund', reason = opts.reason,
    }
    local state, err = settleOwed(row)
    if state == 'paid' then return true end
    row.state, row.last_error = state, err
    saveOwed(row)
    log(('%s of %s to %s %s not completed (%s), %s'):format(row.kind, money(amount), row.to_kind, row.to_id, tostring(err),
        state == 'open' and 'retried by the sweep' or 'left for staff'))
    if row.to_kind == 'player' and state == 'open' then
        S.Tell(row.to_id, ('The bank has not completed a payment of %s to you yet (%s). It is retried automatically.'):format(money(amount), opts.label or row.reason or row.kind), 'primary')
    end
    return false
end

local function sweepOwed()
    local pending = unsavedOwed
    unsavedOwed = {}
    for _, row in ipairs(pending) do
        local state, err = settleOwed(row)
        row.state, row.last_error = state, err
        if state ~= 'paid' then saveOwed(row) end
    end
    for _, row in ipairs(db('query', 'openOwed') or {}) do
        row.amount, row.attempt = tonumber(row.amount), tonumber(row.attempt) or 1
        local state, err = settleOwed(row)
        db('update', 'updateOwed', { row.attempt, state, err, row.id })
        if state == 'paid' and row.to_kind == 'player' then
            S.Tell(row.to_id, ('A delayed payment of %s reached your %s account (%s).'):format(money(row.amount), row.account, row.reason or row.kind), 'success')
        elseif state ~= 'open' then
            log(('owed payment %s (%s) is %s: %s'):format(tostring(row.id), row.ledger_key, state, tostring(err)))
        end
    end
end

-- ── held sales ─────────────────────────────────────────────────────────────────────────────────

local function count(set, key, delta)
    if not key then return end
    local n = (set[key] or 0) + delta
    set[key] = n > 0 and n or nil
end

local function track(hold, delta)
    count(heldPlates, hold.plate, delta)
    count(heldBuyers, hold.citizenid, delta)
end

--- True while a held sale of this car waits on the bank.
function S.PlateHeld(plate) return plate ~= nil and heldPlates[plate] ~= nil end
--- True while one of this citizen's sales waits on the bank.
function S.BuyerWaiting(cid) return cid ~= nil and heldBuyers[cid] ~= nil end

local function decode(text)
    if type(text) == 'table' then return text end
    local ok, t = pcall(json.decode, text or '')
    return ok and type(t) == 'table' and t or {}
end

--- Stores a sale whose charge the bank has not confirmed. opts: flow, key (the key given to
--- PFPayout.Charge), accounts (the list given to it), citizenid, amount, plate, txId (res.txId),
--- data (what the flow's handler needs to finish or release it). Returns the hold; hold.ref is
--- the reference told to the buyer.
function S.Hold(opts)
    local hold = {
        flow = opts.flow, charge_key = opts.key, accounts = table.concat(opts.accounts, ','), tx_id = opts.txId,
        citizenid = opts.citizenid, plate = opts.plate, amount = tonumber(opts.amount) or 0, data = opts.data or {},
        state = 'waiting', created = os.time(),
    }
    local id = HELD and db('insert', 'insertHeld', { hold.flow, hold.charge_key, hold.accounts, hold.tx_id, hold.citizenid, hold.plate,
        hold.amount, json.encode(hold.data), hold.created })
    if id then hold.id = id else unsavedHolds[#unsavedHolds + 1] = hold end
    hold.ref = hold.id and ('#' .. tostring(hold.id)) or hold.charge_key
    track(hold, 1)
    log(('held (%s) for %s: the bank has not confirmed charge %s (%s)'):format(hold.flow, hold.citizenid, hold.charge_key, money(hold.amount)))
    return hold
end

--- Stores changes a handler made to hold.data (so a re-run after a crash sees them).
function S.SaveData(hold)
    if hold.id then db('update', 'saveHeld', { json.encode(hold.data), hold.id }) end
end

local function ledgerRow(key)
    local ok, tx = pcall(function() return exports['pfm-banking']:GetTransaction(key) end)
    if not ok then return nil, true end
    return type(tx) == 'table' and tx or nil, false
end

--- What the ledger says about a held charge now: 'charged' (with the account), 'none' (nothing
--- was taken), 'waiting', or 'review' (interrupted during the debit; not decided here). The
--- accounts are read in the order PFPayout.Charge tried them: it went on only after a clear refusal.
function S.ChargeOutcome(hold)
    if GetResourceState('pfm-banking') ~= 'started' then return 'waiting' end
    local function judge(tx)
        if tx.state == 'completed' then return 'charged' end
        if tx.state == 'pending' or tx.state == 'debited' then return 'waiting' end
        if tx.state == 'failed' and tx.error == 'interrupted_unverified' then return 'review' end
        if tx.state == 'compensated' then return 'none' end
        if tx.state == 'failed' then return 'next' end
        return 'waiting'
    end
    if hold.tx_id then
        -- the bank named the transfer: its state decides (a missing row is a failed read)
        local tx, broken = ledgerRow(hold.tx_id)
        if broken or not tx then return 'waiting' end
        local verdict = judge(tx)
        if verdict == 'charged' then return 'charged', (tostring(tx.from_account):match(':(%a+)$')) end
        if verdict ~= 'next' then return verdict end
    end
    for account in tostring(hold.accounts):gmatch('[^,]+') do
        local tx, broken = ledgerRow(hold.charge_key .. ':' .. account)
        if broken then return 'waiting' end
        if not tx then
            -- the charge stopped here without a ledger row: its write failed, so nothing moved, but
            -- only once a late row cannot appear any more
            if (os.time() - (tonumber(hold.created) or 0)) < S.MISSING_GRACE then return 'waiting' end
            return 'none'
        end
        local verdict = judge(tx)
        if verdict == 'charged' then return 'charged', account end
        if verdict ~= 'next' then return verdict end
    end
    return 'none'
end

local function mark(hold, state, outcome, from)
    if hold.id then
        local n = db('update', 'markHeld', { state, outcome, hold.id, from })
        if (tonumber(n) or 0) < 1 then return false end
    end
    hold.state, hold.outcome = state, outcome
    return true
end

--- Settles one hold when its charge has settled. The outcome is stored ('finishing') before the
--- handler runs, so a crash in the middle re-runs the same outcome (handlers are rerun-safe).
function S.SettleHold(hold)
    local handler = S.handlers[hold.flow]
    if not handler then return false end
    hold.data = decode(hold.data)
    local outcome, account
    if hold.state == 'finishing' then
        outcome, account = tostring(hold.outcome):match('^(%a+):?(%a*)$')
        if account == '' then account = nil end
    else
        outcome, account = S.ChargeOutcome(hold)
        if outcome == 'waiting' then return false end
        if not mark(hold, 'finishing', outcome .. (account and (':' .. account) or ''), 'waiting') then return false end
    end
    local fn = handler[outcome]
    if not fn then return false end
    local ok, err = pcall(fn, hold, account)
    if not ok then
        log(('%s hold %s (%s) failed, retried next sweep: %s'):format(hold.flow, tostring(hold.id), outcome, tostring(err)))
        return false
    end
    mark(hold, outcome == 'review' and 'review' or 'done', hold.outcome, 'finishing')
    track(hold, -1)
    if outcome == 'review' then
        log(('%s hold %s: charge %s was interrupted during the debit; staff must check it (see /ledgerreconcile)'):format(hold.flow, tostring(hold.id), hold.charge_key))
    end
    return true
end

local function sweepHolds()
    local memory = unsavedHolds
    unsavedHolds = {}
    for _, hold in ipairs(memory) do
        local id = HELD and db('insert', 'insertHeld', { hold.flow, hold.charge_key, hold.accounts, hold.tx_id, hold.citizenid, hold.plate,
            hold.amount, json.encode(hold.data), hold.created })
        if id then hold.id = id end
        -- a hold the database still does not take is settled from memory
        if not S.SettleHold(hold) and hold.state ~= 'done' and hold.state ~= 'review' and not hold.id then
            unsavedHolds[#unsavedHolds + 1] = hold
        end
    end
    for _, hold in ipairs(db('query', 'openHeld') or {}) do
        hold.amount = tonumber(hold.amount) or 0
        S.SettleHold(hold)
    end
end

local sweeping = false
--- One pass: owed payments first, then held sales (which may owe new payments).
function S.Sweep()
    if sweeping or not OWED then return end
    sweeping = true
    local ok, err = pcall(function()
        sweepOwed()
        sweepHolds()
    end)
    sweeping = false
    if not ok then log('sweep failed: ' .. tostring(err)) end
end

local started = false
--- Loads the holds that still wait (for PlateHeld/BuyerWaiting) and starts the sweep loop.
function S.Start()
    if not OWED then return end
    heldPlates, heldBuyers = {}, {}
    for _, hold in ipairs(db('query', 'openHeld') or {}) do track(hold, 1) end
    for _, hold in ipairs(unsavedHolds) do track(hold, 1) end
    if started then return end
    started = true
    CreateThread(function()
        while true do
            Wait(S.SWEEP_MS)
            S.Sweep()
        end
    end)
end
