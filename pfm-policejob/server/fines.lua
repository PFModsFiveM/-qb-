-- Police fines (/fine) as stored records.
--
-- A fine is a row in pfm_police_fines before any money moves. The charge is one ledger transfer from
-- the fined player (bank, then cash) straight to the officer's department account, under a key made
-- from the row: pfm-policejob:fine:<id>:a<attempt> (PFPayout.Charge adds :bank / :cash). The money
-- used to go into this resource's account first and on to the department in a second step that
-- nothing checked or retried, so a ledger fault left it there for good.
--
-- States
--   charging  the row is written and the charge is on its way (a crash here is picked up by the sweep)
--   pending   the bank has not settled the charge (unclear), or was not running: the sweep asks again
--             under the SAME key; an unclear charge is never charged again under a new key
--   paid      the department has the money (final)
--   invoiced  nothing was taken (they could not pay): the fine is a pfm-phone invoice now (final)
--   retry     nothing was taken and pfm-phone could not take the invoice: the sweep charges again
--             later under the next numbered key (a failed key stays failed), then invoices again
--   failed    the fine cannot be collected (the department cannot hold money, or too many attempts)
--
-- The command and the sweep share one lock per fine id, taken before the first database wait.

PFPoliceFines = PFPoliceFines or {}
local F = PFPoliceFines

F.SWEEP_INTERVAL_MS = 120000
F.HOLD_SECONDS = 120          -- a new row is left to the command for this long before the sweep looks
F.MAX_ATTEMPTS = 10           -- numbered charge attempts of one fine
F.REASON = 'Police fine'

F.Migrations = {
    {
        version = 1,
        name = 'police fine records',
        up = {
            [[CREATE TABLE IF NOT EXISTS `pfm_police_fines` (
                `id` INT UNSIGNED NOT NULL AUTO_INCREMENT,
                `citizenid` VARCHAR(50) NOT NULL,
                `society` VARCHAR(50) NOT NULL,
                `amount` INT UNSIGNED NOT NULL,
                `officer_citizenid` VARCHAR(50) NULL,
                `officer_name` VARCHAR(100) NULL,
                `reason` VARCHAR(128) NOT NULL DEFAULT 'Police fine',
                `state` VARCHAR(16) NOT NULL DEFAULT 'charging',
                `attempt` INT UNSIGNED NOT NULL DEFAULT 1,
                `checks` INT UNSIGNED NOT NULL DEFAULT 0,
                `paid_from` VARCHAR(8) NULL,
                `invoice_id` INT NULL,
                `last_error` VARCHAR(64) NULL,
                `next_at` INT UNSIGNED NOT NULL DEFAULT 0,
                `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                PRIMARY KEY (`id`),
                KEY `idx_due` (`state`, `next_at`),
                KEY `idx_citizen` (`citizenid`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
        },
    },
}

F.SQL = {
    insert = [[INSERT INTO pfm_police_fines (citizenid, society, amount, officer_citizenid, officer_name, reason, state, attempt, next_at)
        VALUES (?, ?, ?, ?, ?, ?, 'charging', 1, ?)]],
    -- moves a row on from the state it was read in (a second worker finds it changed and stops)
    move = [[UPDATE pfm_police_fines SET state = ?, paid_from = ?, invoice_id = ?, last_error = ?, next_at = ?, checks = checks + ?
        WHERE id = ? AND state = ? AND attempt = ?]],
    -- the next numbered attempt of a 'retry' row
    nextAttempt = [[UPDATE pfm_police_fines SET state = 'charging', attempt = attempt + 1, next_at = ?
        WHERE id = ? AND state = 'retry' AND attempt = ?]],
    due = [[SELECT id, citizenid, society, amount, officer_citizenid, officer_name, reason, state, attempt, checks
        FROM pfm_police_fines WHERE state IN ('charging', 'pending', 'retry') AND next_at <= ? ORDER BY next_at, id LIMIT 50]],
    byId = 'SELECT * FROM pfm_police_fines WHERE id = ? LIMIT 1',
}

local busy = {}   -- [fine id] = true while the command or the sweep works on it
local warned = {} -- [fine id] = true once the console was told about an unverified charge

local function affected(res)
    if type(res) == 'number' then return res end
    if type(res) == 'table' then return tonumber(res.affectedRows) or 0 end
    return 0
end

function F.Key(row) return ('pfm-policejob:fine:%d:a%d'):format(row.id, row.attempt) end

-- Waits for an unclear or unreachable charge back off from 2 minutes up to 30.
local function pendingDelay(checks)
    local d = 120 * (2 ^ math.min(tonumber(checks) or 0, 4))
    return math.floor(math.min(d, 1800))
end

local function retryDelay(attempt)
    return math.floor(math.min(300 * (tonumber(attempt) or 1), 3600))
end

--- Moves `row` from the state it is in; false when another worker moved it first.
local function move(row, state, fields)
    fields = fields or {}
    local ok, res = pcall(MySQL.update.await, F.SQL.move, {
        state, fields.paid_from, fields.invoice_id, fields.last_error and tostring(fields.last_error):sub(1, 64) or nil,
        fields.next_at or 0, fields.check and 1 or 0, row.id, row.state, row.attempt,
    })
    if not ok or affected(res) ~= 1 then return false end
    row.state = state
    return true
end

local function createInvoice(row)
    if GetResourceState('pfm-phone') ~= 'started' then return nil, 'phone_unavailable' end
    local ok, id, err = pcall(function()
        return exports['pfm-phone']:CreateInvoice({
            citizenid = row.citizenid, amount = row.amount, society = row.society,
            sender = row.officer_name, sendercitizenid = row.officer_citizenid, reason = row.reason or F.REASON,
        })
    end)
    if not ok then return nil, 'phone_error' end
    if not id then return nil, err or 'phone_refused' end
    return tonumber(id) or id, nil
end

--- One charge attempt of `row` under its attempt key (the caller holds busy[row.id]). Returns
--- 'paid' (account), 'unclear', 'bank_down', 'invoiced' (invoice id), 'retry' or 'failed' (error),
--- or 'busy' when another worker moved the row meanwhile.
function F.Attempt(row, payer)
    local paidFrom, res = PFPayout.Charge(payer or row.citizenid, { 'bank', 'cash' }, row.amount, {
        key = F.Key(row), to = 'society:' .. row.society, kind = 'fine', reason = row.reason or F.REASON,
        quiet = true, metadata = { fine = row.id },
    })
    res = type(res) == 'table' and res or {}
    local now = os.time()
    if paidFrom then
        if not move(row, 'paid', { paid_from = paidFrom }) then return 'busy' end
        return 'paid', paidFrom
    end
    if res.unclear or res.error == 'bank_unavailable' or res.error == 'ledger_unavailable' then
        -- unclear: the money may have left, the ledger settles it under this key; bank down: the key
        -- never reached the ledger. Either way the same key is asked again, never a new one.
        if res.unclear and res.error == 'interrupted_unverified' and not warned[row.id] then
            warned[row.id] = true
            print(('^3[pfm-policejob]^7 fine %d: charge %s is unverified after a crash; check it with /ledgerreconcile'):format(row.id, F.Key(row)))
        end
        if not move(row, 'pending', { next_at = now + pendingDelay(row.checks), last_error = res.error, check = true }) then return 'busy' end
        return res.unclear and 'unclear' or 'bank_down'
    end
    -- clearly refused (insufficient funds, refunded): nothing was taken; the fine becomes an invoice
    local invoiceId, invErr = createInvoice(row)
    if invoiceId then
        if not move(row, 'invoiced', { invoice_id = tonumber(invoiceId), last_error = res.error }) then return 'busy' end
        return 'invoiced', invoiceId
    end
    if invErr == 'unknown_society' or invErr == 'bad_request' or row.attempt >= F.MAX_ATTEMPTS then
        if not move(row, 'failed', { last_error = invErr }) then return 'busy' end
        print(('^3[pfm-policejob]^7 fine %d (%s, $%d) could not be collected: %s'):format(row.id, row.citizenid, row.amount, tostring(invErr)))
        return 'failed', invErr
    end
    if not move(row, 'retry', { next_at = now + retryDelay(row.attempt), last_error = invErr }) then return 'busy' end
    return 'retry', invErr
end

--- Issues a fine from an on-duty officer (biller) to an online player (billed). Returns the
--- outcome of F.Attempt, 'db_error' when the record could not be written (nothing was charged),
--- and the fine id.
function F.Issue(biller, billed, amount)
    local ci = biller.PlayerData.charinfo or {}
    local officerName = tostring(ci.firstname or ''):sub(1, 50)
    local row = {
        citizenid = billed.PlayerData.citizenid, society = biller.PlayerData.job.name, amount = amount,
        officer_citizenid = biller.PlayerData.citizenid, officer_name = officerName, reason = F.REASON,
        state = 'charging', attempt = 1, checks = 0,
    }
    local ok, id = pcall(MySQL.insert.await, F.SQL.insert, {
        row.citizenid, row.society, row.amount, row.officer_citizenid, row.officer_name, row.reason, os.time() + F.HOLD_SECONDS,
    })
    id = ok and tonumber(id) or nil
    if not id or id < 1 then return 'db_error' end
    row.id = id
    busy[id] = true
    local results = table.pack(pcall(F.Attempt, row, billed))
    busy[id] = nil
    if not results[1] then
        print(('^1[pfm-policejob]^7 fine %d: %s'):format(id, tostring(results[2])))
        return 'pending', nil, id -- the sweep finishes it from the record
    end
    return results[2], results[3], id
end

local function notifyCitizen(cid, text, kind)
    local P = exports['pfm-core']:GetPlayerByCitizenId(cid)
    if P then TriggerClientEvent('QBCore:Notify', P.PlayerData.source, text, kind) end
    return P
end

--- Finishes one due row (the caller holds busy[row.id]).
function F.SweepOne(row)
    row.id, row.attempt, row.amount = tonumber(row.id), tonumber(row.attempt) or 1, tonumber(row.amount)
    row.checks = tonumber(row.checks) or 0
    if row.state == 'retry' then
        local ok, res = pcall(MySQL.update.await, F.SQL.nextAttempt, { os.time() + F.HOLD_SECONDS, row.id, row.attempt })
        if not ok or affected(res) ~= 1 then return 'busy' end
        row.attempt, row.state = row.attempt + 1, 'charging'
    end
    local outcome, info = F.Attempt(row)
    if outcome == 'paid' then
        notifyCitizen(row.citizenid, ('Your police fine of $%d was paid'):format(row.amount), 'primary')
    elseif outcome == 'invoiced' then
        local P = notifyCitizen(row.citizenid, ('Your police fine of $%d was sent to your phone as an invoice'):format(row.amount), 'primary')
        if P then TriggerClientEvent('qb-phone:RefreshPhone', P.PlayerData.source) end
    end
    return outcome, info
end

--- One pass over the due rows (every SWEEP_INTERVAL_MS once the ledger is ready; also used by tests).
function F.Sweep()
    local ok, rows = pcall(MySQL.query.await, F.SQL.due, { os.time() })
    if not ok or type(rows) ~= 'table' then return 0 end
    local done = 0
    for _, row in ipairs(rows) do
        local id = tonumber(row.id)
        if id and not busy[id] then
            busy[id] = true
            local okOne, err = pcall(F.SweepOne, row)
            busy[id] = nil
            if not okOne then print(('^1[pfm-policejob]^7 fine sweep %d: %s'):format(id, tostring(err))) end
            done = done + 1
        end
    end
    return done
end

function F.Migrate()
    local ok, res, err = pcall(function() return exports['pfm-core']:RunMigrations(GetCurrentResourceName(), F.Migrations) end)
    if not ok or res == false then
        print(('^1[pfm-policejob]^7 fine table migration failed: %s'):format(tostring(ok and err or res)))
        return false
    end
    return true
end

CreateThread(function()
    if not F.Migrate() then return end
    -- the ledger recovers interrupted transfers when it starts: wait for it (at most ~5 minutes)
    for _ = 1, 60 do
        local ok, ready = pcall(function() return exports['pfm-banking']:IsLedgerReady() end)
        if ok and ready == true then break end
        Wait(5000)
    end
    while true do
        local ok, err = pcall(F.Sweep)
        if not ok then print(('^1[pfm-policejob]^7 fine sweep failed: %s'):format(tostring(err))) end
        Wait(F.SWEEP_INTERVAL_MS)
    end
end)
