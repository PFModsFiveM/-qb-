-- PF Ledger: the authoritative money-transfer service for the PF framework.
--
-- Account references
--   society:<name>             a bank_accounts row (job, gang and shared accounts, the city treasury)
--   player:<citizenid>:bank    a player's bank balance (online: pfm-core memory, offline: players.money)
--   player:<citizenid>:cash    a player's cash
--   acct:<id>                  a bank_accounts_v2 row (player-owned shared/business accounts with IBANs)
--   system:<label>             money entering or leaving the economy (NPC sales, state wages, fines)
--
-- Every transfer is one pf_transactions row with a stable tx_id and a unique idempotency key:
--   pending -> debited -> completed            normal path
--   pending -> failed                          source could not be debited
--   debited -> compensated                     destination refused; source refunded
-- For balances held in the database, the balance change and the state transition are one multi-table
-- UPDATE, so no step can move money without its record. Online player money lives in pfm-core memory;
-- debits there happen before the state change and credits after it, so a crash can never pay twice.

PFLedger = PFLedger or {}
local L = PFLedger

local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions', 'Shared', 'Commands' }) -- Commands: /ledgerreconcile

L.STALE_PENDING_SECONDS = 60
L.STALE_DEBITED_SECONDS = 30
L.MAX_AMOUNT = 1000000000000

L.SQL = {
    insertTx = [[INSERT INTO pf_transactions (tx_id, idempotency_key, kind, from_account, to_account, amount, state, reason, actor, metadata)
        VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?)]],
    selectByKey = 'SELECT * FROM pf_transactions WHERE idempotency_key = ? LIMIT 1',
    selectByTxId = 'SELECT * FROM pf_transactions WHERE tx_id = ? LIMIT 1',
    setState = 'UPDATE pf_transactions SET state = ?, error = ? WHERE tx_id = ? AND state = ?',

    debitSociety = [[UPDATE pf_transactions t, bank_accounts a
        SET a.account_balance = a.account_balance - ?, t.state = 'debited'
        WHERE t.tx_id = ? AND t.state = 'pending' AND a.account_name = ? AND a.account_balance >= ?]],
    creditSociety = [[UPDATE pf_transactions t, bank_accounts a
        SET a.account_balance = a.account_balance + ?, t.state = 'completed'
        WHERE t.tx_id = ? AND t.state = 'debited' AND a.account_name = ?]],
    refundSociety = [[UPDATE pf_transactions t, bank_accounts a
        SET a.account_balance = a.account_balance + ?, t.state = 'compensated', t.error = ?
        WHERE t.tx_id = ? AND t.state = 'debited' AND a.account_name = ?]],

    debitOfflinePlayer = [[UPDATE pf_transactions t, players p
        SET p.money = JSON_SET(p.money, CONCAT('$.', ?), ROUND(CAST(JSON_UNQUOTE(JSON_EXTRACT(p.money, CONCAT('$.', ?))) AS DECIMAL(16,2)) - ?, 2)),
            t.state = 'debited'
        WHERE t.tx_id = ? AND t.state = 'pending' AND p.citizenid = ?
          AND CAST(JSON_UNQUOTE(JSON_EXTRACT(p.money, CONCAT('$.', ?))) AS DECIMAL(16,2)) >= ?]],
    creditOfflinePlayer = [[UPDATE pf_transactions t, players p
        SET p.money = JSON_SET(p.money, CONCAT('$.', ?), ROUND(COALESCE(CAST(JSON_UNQUOTE(JSON_EXTRACT(p.money, CONCAT('$.', ?))) AS DECIMAL(16,2)), 0) + ?, 2)),
            t.state = ?
        WHERE t.tx_id = ? AND t.state = 'debited' AND p.citizenid = ?]],

    debitAcct = [[UPDATE pf_transactions t, bank_accounts_v2 a
        SET a.balance = a.balance - ?, t.state = 'debited'
        WHERE t.tx_id = ? AND t.state = 'pending' AND a.id = ? AND a.balance >= ?]],
    creditAcct = [[UPDATE pf_transactions t, bank_accounts_v2 a
        SET a.balance = a.balance + ?, t.state = 'completed'
        WHERE t.tx_id = ? AND t.state = 'debited' AND a.id = ?]],
    refundAcct = [[UPDATE pf_transactions t, bank_accounts_v2 a
        SET a.balance = a.balance + ?, t.state = 'compensated', t.error = ?
        WHERE t.tx_id = ? AND t.state = 'debited' AND a.id = ?]],
    acctExists = 'SELECT 1 FROM bank_accounts_v2 WHERE id = ? LIMIT 1',

    societyBalance = 'SELECT account_balance FROM bank_accounts WHERE account_name = ? LIMIT 1',
    ensureSociety = "INSERT IGNORE INTO bank_accounts (account_name, account_balance, account_type) VALUES (?, 0, ?)",
    ensureBaseline = 'INSERT IGNORE INTO pf_ledger_baselines (account, balance) VALUES (?, ?)',
    playerExists = 'SELECT 1 FROM players WHERE citizenid = ? LIMIT 1',
    staleTx = [[SELECT * FROM pf_transactions
        WHERE (state = 'pending' AND updated_at < (NOW() - INTERVAL ? SECOND))
           OR (state = 'debited' AND updated_at < (NOW() - INTERVAL ? SECOND))
        ORDER BY id ASC LIMIT 200]],
}

-- ── helpers ───────────────────────────────────────────────────────────────

local inFlight = {}     -- [tx_id] = true while this server is processing it
local keyLocks = {}     -- [idempotency_key] = true while a Transfer with that key runs

local function round2(n)
    return math.floor(n * 100 + 0.5) / 100
end

--- A valid transfer amount (positive, finite, at most 2 decimals), or nil.
function L.Amount(value)
    local n = tonumber(value)
    if not n or n ~= n or n == math.huge or n <= 0 or n > L.MAX_AMOUNT then return nil end
    n = round2(n)
    if n <= 0 then return nil end
    return n
end

function L.ParseRef(ref)
    if type(ref) ~= 'string' or #ref > 96 then return nil end
    local kind, rest = ref:match('^(%a+):(.+)$')
    if kind == 'society' then
        if #rest <= 50 and rest:match('^[%w_%-%.]+$') then return { kind = 'society', name = rest, ref = ref } end
    elseif kind == 'player' then
        local cid, moneytype = rest:match('^([%w]+):(%a+)$')
        if cid and (moneytype == 'bank' or moneytype == 'cash') then
            return { kind = 'player', citizenid = cid, moneytype = moneytype, ref = ref }
        end
    elseif kind == 'acct' then
        local id = rest:match('^(%d+)$')
        if id and #id <= 12 then return { kind = 'acct', id = tonumber(id), ref = ref } end
    elseif kind == 'system' then
        if #rest <= 64 and rest:match('^[%w_%-%.:]+$') then return { kind = 'system', name = rest, ref = ref } end
    end
    return nil
end

local randomSeeded = false
function L.NewTxId()
    if not randomSeeded then
        math.randomseed(os.time() + math.floor((GetGameTimer() or 0)))
        randomSeeded = true
    end
    local chars = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'
    local out = { 'TX' }
    for i = 1, 22 do
        local r = math.random(1, #chars)
        out[#out + 1] = chars:sub(r, r)
    end
    return table.concat(out)
end

local function onlinePlayer(citizenid)
    return exports['pfm-core']:GetPlayerByCitizenId(citizenid)
end

-- Refresh pfm-banking's in-memory account cache from the database after a balance change.
local function refreshSocietyCache(name, accountType)
    local balance = tonumber(MySQL.scalar.await(L.SQL.societyBalance, { name }))
    if balance == nil then return end
    if BankingAccounts then
        if BankingAccounts[name] then
            BankingAccounts[name].account_balance = balance
        else
            BankingAccounts[name] = { account_name = name, account_balance = balance, account_type = accountType or 'job' }
        end
    end
end

local function societyExists(name)
    return MySQL.scalar.await(L.SQL.societyBalance, { name }) ~= nil
end

--- Creates a society account for a known job or gang (never for arbitrary names) and records its
--- reconciliation baseline. Returns true when the account exists afterwards.
function L.EnsureSociety(name, accountType)
    if societyExists(name) then return true end
    local isJob = QBCore.Shared.Jobs and QBCore.Shared.Jobs[name]
    local isGang = QBCore.Shared.Gangs and QBCore.Shared.Gangs[name]
    if not accountType then
        if isJob then accountType = 'job' elseif isGang then accountType = 'gang' else return false end
    end
    MySQL.insert.await(L.SQL.ensureSociety, { name, accountType })
    MySQL.insert.await(L.SQL.ensureBaseline, { 'society:' .. name, 0 })
    refreshSocietyCache(name, accountType)
    return societyExists(name)
end

local function setState(txId, toState, fromState, err)
    return (tonumber(MySQL.update.await(L.SQL.setState, { toState, err, txId, fromState })) or 0) == 1
end

-- ── adapters ──────────────────────────────────────────────────────────────
-- debit(tx, acct)  : pending -> debited, removing money from acct
-- credit(tx, acct) : debited -> completed, adding money to acct
-- refund(tx, acct) : debited -> compensated, returning money to acct (the source)
-- Each returns true on success, or false plus an error code.

local adapters = {}

adapters.system = {
    debit = function(tx) return setState(tx.tx_id, 'debited', 'pending', nil) or false, 'state_conflict' end,
    credit = function(tx) return setState(tx.tx_id, 'completed', 'debited', nil) or false, 'state_conflict' end,
    refund = function(tx, _, reason) return setState(tx.tx_id, 'compensated', 'debited', reason) or false, 'state_conflict' end,
}

adapters.society = {
    debit = function(tx, acct)
        local n = tonumber(MySQL.update.await(L.SQL.debitSociety, { tx.amount, tx.tx_id, acct.name, tx.amount })) or 0
        if n < 2 then
            if not societyExists(acct.name) then return false, 'unknown_account' end
            return false, 'insufficient_funds'
        end
        refreshSocietyCache(acct.name)
        return true
    end,
    credit = function(tx, acct)
        if not L.EnsureSociety(acct.name) then return false, 'unknown_account' end
        local n = tonumber(MySQL.update.await(L.SQL.creditSociety, { tx.amount, tx.tx_id, acct.name })) or 0
        if n < 2 then return false, 'state_conflict' end
        refreshSocietyCache(acct.name)
        return true
    end,
    refund = function(tx, acct, reason)
        local n = tonumber(MySQL.update.await(L.SQL.refundSociety, { tx.amount, reason, tx.tx_id, acct.name })) or 0
        if n < 2 then return false, 'state_conflict' end
        refreshSocietyCache(acct.name)
        return true
    end,
}

adapters.acct = {
    debit = function(tx, acct)
        local n = tonumber(MySQL.update.await(L.SQL.debitAcct, { tx.amount, tx.tx_id, acct.id, tx.amount })) or 0
        if n < 2 then
            if not MySQL.scalar.await(L.SQL.acctExists, { acct.id }) then return false, 'unknown_account' end
            return false, 'insufficient_funds'
        end
        return true
    end,
    credit = function(tx, acct)
        local n = tonumber(MySQL.update.await(L.SQL.creditAcct, { tx.amount, tx.tx_id, acct.id })) or 0
        if n < 2 then
            -- a closed account cannot take money: the caller's source gets refunded
            if not MySQL.scalar.await(L.SQL.acctExists, { acct.id }) then return false, 'unknown_account' end
            return false, 'state_conflict'
        end
        return true
    end,
    refund = function(tx, acct, reason)
        local n = tonumber(MySQL.update.await(L.SQL.refundAcct, { tx.amount, reason, tx.tx_id, acct.id })) or 0
        if n < 2 then return false, 'state_conflict' end
        return true
    end,
}

adapters.player = {
    debit = function(tx, acct)
        local P = onlinePlayer(acct.citizenid)
        if P then
            -- memory first: if the state change then fails, the money is put straight back
            if not P.Functions.RemoveMoney(acct.moneytype, tx.amount, tx.reason or 'ledger') then
                return false, 'insufficient_funds'
            end
            if not setState(tx.tx_id, 'debited', 'pending', nil) then
                P.Functions.AddMoney(acct.moneytype, tx.amount, 'ledger rollback')
                return false, 'state_conflict'
            end
            return true
        end
        local n = tonumber(MySQL.update.await(L.SQL.debitOfflinePlayer, {
            acct.moneytype, acct.moneytype, tx.amount, tx.tx_id, acct.citizenid, acct.moneytype, tx.amount,
        })) or 0
        if n < 2 then
            if not MySQL.scalar.await(L.SQL.playerExists, { acct.citizenid }) then return false, 'unknown_account' end
            return false, 'insufficient_funds'
        end
        return true
    end,
    credit = function(tx, acct)
        return adapters.player._add(tx, acct, 'completed')
    end,
    refund = function(tx, acct, reason)
        return adapters.player._add(tx, acct, 'compensated', reason)
    end,
    -- state first, then memory: a crash in between can lose a credit but never pays it twice
    _add = function(tx, acct, toState, reason)
        local P = onlinePlayer(acct.citizenid)
        if P then
            if not setState(tx.tx_id, toState, 'debited', reason) then return false, 'state_conflict' end
            if not P.Functions.AddMoney(acct.moneytype, tx.amount, tx.reason or 'ledger') then
                setState(tx.tx_id, 'debited', toState, 'player_credit_failed')
                return false, 'credit_failed'
            end
            return true
        end
        if not MySQL.scalar.await(L.SQL.playerExists, { acct.citizenid }) then return false, 'unknown_account' end
        local n = tonumber(MySQL.update.await(L.SQL.creditOfflinePlayer, {
            acct.moneytype, acct.moneytype, tx.amount, toState, tx.tx_id, acct.citizenid,
        })) or 0
        if n < 2 then return false, 'state_conflict' end
        if reason then MySQL.update.await('UPDATE pf_transactions SET error = ? WHERE tx_id = ?', { reason, tx.tx_id }) end
        return true
    end,
}

-- ── core ──────────────────────────────────────────────────────────────────

local function result(tx, ok, err, duplicate)
    return {
        ok = ok,
        txId = tx and tx.tx_id or nil,
        state = tx and tx.state or nil,
        error = err,
        duplicate = duplicate or false,
    }
end

local function loadTx(txId)
    return MySQL.single.await(L.SQL.selectByTxId, { txId })
end

-- Moves a transaction that is already 'debited' to completed, refunding the source if the
-- destination cannot accept it.
local function finish(tx)
    local to, from = L.ParseRef(tx.to_account), L.ParseRef(tx.from_account)
    local ok, err = adapters[to.kind].credit(tx, to)
    if ok then
        tx.state = 'completed'
        return true
    end
    if err == 'state_conflict' then
        local fresh = loadTx(tx.tx_id)
        if fresh and fresh.state == 'completed' then tx.state = 'completed' return true end
    end
    local refunded = adapters[from.kind].refund(tx, from, err)
    tx.state = refunded and 'compensated' or 'debited'
    tx.error = err
    if not refunded then
        print(('^1[pfm-banking ledger]^7 %s: credit failed (%s) and refund failed; left in debited for recovery'):format(tx.tx_id, tostring(err)))
    end
    return false, err
end

--- Moves money between two accounts. Idempotent per `key`: repeating a call with the same key
--- returns the original result instead of moving money again.
--- @param opts table { from, to, amount, key, kind?, reason?, actor?, metadata? }
--- @return table { ok, txId, state, error, duplicate }
function L.Transfer(opts)
    if type(opts) ~= 'table' then return result(nil, false, 'invalid_request') end
    local from, to = L.ParseRef(opts.from), L.ParseRef(opts.to)
    if not from or not to then return result(nil, false, 'invalid_account') end
    if from.ref == to.ref then return result(nil, false, 'same_account') end
    if from.kind == 'system' and to.kind == 'system' then return result(nil, false, 'invalid_account') end
    local amount = L.Amount(opts.amount)
    if not amount then return result(nil, false, 'invalid_amount') end
    local key = opts.key
    if type(key) ~= 'string' or key == '' or #key > 128 then return result(nil, false, 'invalid_key') end
    if not L.ready then return result(nil, false, 'ledger_unavailable') end

    if keyLocks[key] then return result(nil, false, 'in_progress') end
    keyLocks[key] = true
    local activeTxId -- cleared after the call even if a database error interrupts it

    local ok, res = pcall(function()
        local existing = MySQL.single.await(L.SQL.selectByKey, { key })
        if existing then
            local done = existing.state == 'completed'
            return result(existing, done, done and nil or (existing.error or existing.state), true)
        end

        local tx = {
            tx_id = L.NewTxId(),
            idempotency_key = key,
            kind = tostring(opts.kind or 'transfer'):sub(1, 32),
            from_account = from.ref,
            to_account = to.ref,
            amount = amount,
            reason = opts.reason and tostring(opts.reason):sub(1, 255) or nil,
            actor = opts.actor and tostring(opts.actor):sub(1, 64) or nil,
            state = 'pending',
        }
        local metadata = (type(opts.metadata) == 'table') and json.encode(opts.metadata) or nil
        local insertOk, inserted = pcall(MySQL.insert.await, L.SQL.insertTx, {
            tx.tx_id, key, tx.kind, tx.from_account, tx.to_account, tx.amount, tx.reason, tx.actor, metadata,
        })
        if not insertOk or not inserted then
            -- a concurrent server or a retry already claimed the key
            local raced = MySQL.single.await(L.SQL.selectByKey, { key })
            if raced then return result(raced, raced.state == 'completed', raced.state ~= 'completed' and raced.state or nil, true) end
            return result(nil, false, 'ledger_write_failed')
        end

        activeTxId = tx.tx_id
        inFlight[tx.tx_id] = true
        local debited, err = adapters[from.kind].debit(tx, from)
        if not debited then
            setState(tx.tx_id, 'failed', 'pending', err)
            tx.state = 'failed'
            return result(tx, false, err)
        end
        tx.state = 'debited'
        local finished, ferr = finish(tx)
        return result(tx, finished, ferr)
    end)

    if activeTxId then inFlight[activeTxId] = nil end
    keyLocks[key] = nil
    if not ok then
        print(('^1[pfm-banking ledger]^7 Transfer error: %s'):format(tostring(res)))
        return result(nil, false, 'internal_error')
    end
    return res
end

local actionLocks = {}

--- Runs fn while holding a named lock (e.g. one per player), so a double-click or two windows cannot
--- run the same money action twice at once. Returns 'ok', 'busy' (someone holds the lock) or 'error'.
function L.WithLock(name, fn)
    if actionLocks[name] then return 'busy' end
    actionLocks[name] = true
    local ok, err = pcall(fn)
    actionLocks[name] = nil
    if not ok then
        print(('^1[pfm-banking]^7 %s failed: %s'):format(tostring(name), tostring(err)))
        return 'error'
    end
    return 'ok'
end

local ERROR_MESSAGES = {
    insufficient_funds = 'Insufficient balance',
    unknown_account = 'Account not found',
    invalid_amount = 'Invalid amount',
    same_account = 'That is the same account',
    ledger_unavailable = 'Banking is temporarily unavailable',
    in_progress = 'That transaction is already being processed',
}

--- A player-facing message for a Transfer error code.
function L.Message(err)
    return ERROR_MESSAGES[err] or 'Transaction failed'
end

--- A unique key for one-off operations that have no natural idempotency key.
function L.AutoKey(prefix)
    return ('%s:%s'):format(prefix or 'auto', L.NewTxId())
end

function L.GetTransaction(idOrKey)
    if type(idOrKey) ~= 'string' then return nil end
    return MySQL.single.await(L.SQL.selectByTxId, { idOrKey }) or MySQL.single.await(L.SQL.selectByKey, { idOrKey })
end

-- ── recovery ──────────────────────────────────────────────────────────────

--- Settles transactions interrupted by a crash, restart or failed credit.
--- pending  -> failed     (a database-held source was not debited: the debit is atomic with the state;
---                         an online-player source is marked unverified for reconciliation)
--- debited  -> completed, or compensated when the destination cannot take it
function L.Recover()
    local rows = MySQL.query.await(L.SQL.staleTx, { L.STALE_PENDING_SECONDS, L.STALE_DEBITED_SECONDS }) or {}
    local settled = 0
    for _, tx in ipairs(rows) do
        if not inFlight[tx.tx_id] then
            inFlight[tx.tx_id] = true
            -- one bad row must not stop the rest; it stays in its state and is retried next pass
            local ok, err = pcall(function()
                tx.amount = tonumber(tx.amount)
                if tx.state == 'pending' then
                    local from = L.ParseRef(tx.from_account)
                    local note = (from and from.kind == 'player') and 'interrupted_unverified' or 'interrupted'
                    if setState(tx.tx_id, 'failed', 'pending', note) then settled = settled + 1 end
                elseif tx.state == 'debited' then
                    finish(tx)
                    if tx.state ~= 'debited' then settled = settled + 1 end
                end
            end)
            if not ok then print(('^1[pfm-banking ledger]^7 recovery of %s failed: %s'):format(tx.tx_id, tostring(err))) end
            inFlight[tx.tx_id] = nil
        end
    end
    return settled
end

-- ── reconciliation ────────────────────────────────────────────────────────

L.SQL.reconcile = [[
SELECT a.account_name, a.account_balance AS actual, b.balance AS baseline,
  COALESCE((SELECT SUM(amount) FROM pf_transactions WHERE to_account = CONCAT('society:', a.account_name) AND state = 'completed'), 0) AS credits,
  COALESCE((SELECT SUM(amount) FROM pf_transactions WHERE from_account = CONCAT('society:', a.account_name) AND state IN ('debited', 'completed')), 0) AS debits
FROM bank_accounts a
LEFT JOIN pf_ledger_baselines b ON b.account = CONCAT('society:', a.account_name)
]]
L.SQL.reconcileAcct = [[
SELECT CONCAT('acct:', a.id) AS account_name, a.balance AS actual, b.balance AS baseline,
  COALESCE((SELECT SUM(amount) FROM pf_transactions WHERE to_account = CONCAT('acct:', a.id) AND state = 'completed'), 0) AS credits,
  COALESCE((SELECT SUM(amount) FROM pf_transactions WHERE from_account = CONCAT('acct:', a.id) AND state IN ('debited', 'completed')), 0) AS debits
FROM bank_accounts_v2 a
LEFT JOIN pf_ledger_baselines b ON b.account = CONCAT('acct:', a.id)
]]
L.SQL.problemTx =[[SELECT tx_id, state, error, from_account, to_account, amount, updated_at FROM pf_transactions
    WHERE (state IN ('pending', 'debited') AND updated_at < (NOW() - INTERVAL 300 SECOND))
       OR (state = 'failed' AND error = 'interrupted_unverified')
    ORDER BY id DESC LIMIT 100]]

--- Compares every society balance with baseline + ledger history and lists stuck transactions.
--- A mismatch means money moved outside the ledger (a script writing bank_accounts directly).
function L.Reconcile()
    local report = { mismatches = {}, missingBaseline = {}, stuck = {}, checked = 0 }
    local rows = {}
    for _, row in ipairs(MySQL.query.await(L.SQL.reconcile) or {}) do rows[#rows + 1] = row end
    for _, row in ipairs(MySQL.query.await(L.SQL.reconcileAcct) or {}) do rows[#rows + 1] = row end
    for _, row in ipairs(rows) do
        report.checked = report.checked + 1
        if row.baseline == nil then
            report.missingBaseline[#report.missingBaseline + 1] = row.account_name
        else
            local expected = round2(tonumber(row.baseline) + tonumber(row.credits) - tonumber(row.debits))
            local actual = round2(tonumber(row.actual))
            if math.abs(expected - actual) >= 0.01 then
                report.mismatches[#report.mismatches + 1] = { account = row.account_name, expected = expected, actual = actual, difference = round2(actual - expected) }
            end
        end
    end
    report.stuck = MySQL.query.await(L.SQL.problemTx) or {}
    return report
end

-- ── startup ───────────────────────────────────────────────────────────────

L.ready = false

L.Migrations = {
    {
        version = 1,
        name = 'ledger tables, decimal balances, reconciliation baselines',
        up = function()
            MySQL.query.await([[
                CREATE TABLE IF NOT EXISTS `pf_transactions` (
                  `id` BIGINT NOT NULL AUTO_INCREMENT,
                  `tx_id` VARCHAR(32) NOT NULL,
                  `idempotency_key` VARCHAR(128) NOT NULL,
                  `kind` VARCHAR(32) NOT NULL,
                  `from_account` VARCHAR(96) NOT NULL,
                  `to_account` VARCHAR(96) NOT NULL,
                  `amount` DECIMAL(16,2) NOT NULL,
                  `state` ENUM('pending','debited','completed','failed','compensated') NOT NULL,
                  `reason` VARCHAR(255) NULL,
                  `actor` VARCHAR(64) NULL,
                  `metadata` LONGTEXT NULL,
                  `error` VARCHAR(64) NULL,
                  `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                  `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                  PRIMARY KEY (`id`),
                  UNIQUE KEY `uq_tx_id` (`tx_id`),
                  UNIQUE KEY `uq_idempotency_key` (`idempotency_key`),
                  KEY `idx_state_updated` (`state`, `updated_at`),
                  KEY `idx_from` (`from_account`),
                  KEY `idx_to` (`to_account`)
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
            ]])
            MySQL.query.await([[
                CREATE TABLE IF NOT EXISTS `pf_ledger_baselines` (
                  `account` VARCHAR(96) NOT NULL,
                  `balance` DECIMAL(16,2) NOT NULL,
                  `taken_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                  PRIMARY KEY (`account`)
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
            ]])
            -- widening INT to DECIMAL keeps every existing value; cents were being rounded away
            MySQL.query.await('ALTER TABLE `bank_accounts` MODIFY `account_balance` DECIMAL(16,2) NOT NULL DEFAULT 0')
            MySQL.query.await('ALTER TABLE `bank_statements` MODIFY `amount` DECIMAL(16,2) NULL')
            -- every existing account starts reconciliation from its balance at migration time
            MySQL.query.await([[INSERT IGNORE INTO pf_ledger_baselines (account, balance)
                SELECT CONCAT('society:', account_name), account_balance FROM bank_accounts WHERE account_name IS NOT NULL]])
        end,
    },
    {
        version = 2,
        name = 'IBAN accounts on the ledger: schema moved here, decimal balances, baselines',
        up = function()
            -- These tables were created by server_accounts.lua at start; the definitions now live here
            -- so the ledger can rely on them. IF NOT EXISTS keeps existing data.
            MySQL.query.await([[CREATE TABLE IF NOT EXISTS bank_accounts_v2 (
                id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
                iban VARCHAR(24) NOT NULL UNIQUE,
                label VARCHAR(50) NOT NULL,
                type ENUM('shared','business') NOT NULL,
                owner VARCHAR(50) NOT NULL,
                balance DECIMAL(16,2) NOT NULL DEFAULT 0,
                color VARCHAR(16) NULL,
                created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                INDEX idx_owner (owner)
            )]])
            MySQL.query.await([[CREATE TABLE IF NOT EXISTS bank_account_members (
                account_id INT NOT NULL,
                citizenid VARCHAR(50) NOT NULL,
                name VARCHAR(80) NOT NULL DEFAULT '',
                can_withdraw TINYINT NOT NULL DEFAULT 0,
                can_deposit TINYINT NOT NULL DEFAULT 1,
                can_cards TINYINT NOT NULL DEFAULT 0,
                can_manage TINYINT NOT NULL DEFAULT 0,
                PRIMARY KEY (account_id, citizenid)
            )]])
            MySQL.query.await([[CREATE TABLE IF NOT EXISTS bank_account_cards (
                id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
                account_id INT NULL,
                citizenid VARCHAR(50) NOT NULL,
                holder_name VARCHAR(80) NOT NULL DEFAULT '',
                number VARCHAR(20) NOT NULL,
                cvv VARCHAR(4) NOT NULL,
                exp VARCHAR(5) NOT NULL,
                design VARCHAR(16) NOT NULL DEFAULT 'classic',
                locked TINYINT NOT NULL DEFAULT 0,
                cancelled TINYINT NOT NULL DEFAULT 0,
                created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                INDEX idx_holder (citizenid),
                INDEX idx_account (account_id)
            )]])
            MySQL.query.await([[CREATE TABLE IF NOT EXISTS bank_transactions (
                id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
                account_ref VARCHAR(32) NOT NULL,
                actor VARCHAR(50) NOT NULL,
                actor_name VARCHAR(80) NOT NULL DEFAULT '',
                type ENUM('deposit','withdraw','transfer_in','transfer_out','fee') NOT NULL,
                amount DECIMAL(16,2) NOT NULL,
                note VARCHAR(120) NULL,
                created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                INDEX idx_ref (account_ref, id)
            )]])
            MySQL.query.await([[CREATE TABLE IF NOT EXISTS bank_personal_iban (
                citizenid VARCHAR(50) NOT NULL PRIMARY KEY,
                iban VARCHAR(24) NOT NULL UNIQUE
            )]])
            -- older installs created these as BIGINT
            MySQL.query.await('ALTER TABLE `bank_accounts_v2` MODIFY `balance` DECIMAL(16,2) NOT NULL DEFAULT 0')
            MySQL.query.await('ALTER TABLE `bank_transactions` MODIFY `amount` DECIMAL(16,2) NOT NULL')
            MySQL.query.await([[INSERT IGNORE INTO pf_ledger_baselines (account, balance)
                SELECT CONCAT('acct:', id), balance FROM bank_accounts_v2]])
        end,
    },
    {
        version = 3,
        name = "business society accounts (resource-owned balances such as player stores)",
        up = function()
            -- 'business' accounts belong to a resource (e.g. pf-stores' store_<id>). The bank UI does not
            -- list or open them for players; the owning resource moves their money through Transfer.
            MySQL.query.await("ALTER TABLE `bank_accounts` MODIFY `account_type` ENUM('shared','job','gang','business') NOT NULL")
        end,
    },
    {
        version = 4,
        name = 'ledger tables use the same collation as bank_accounts',
        up = function()
            -- The ledger tables were created with the server's default collation. Reconciliation joins
            -- them to bank_accounts, which ships as utf8mb4_unicode_ci; on servers whose default is
            -- different (MariaDB defaults to utf8mb4_general_ci) every reconcile failed with
            -- "Illegal mix of collations". Found by running the ledger against a real MariaDB.
            local target = MySQL.scalar.await([[SELECT TABLE_COLLATION FROM information_schema.TABLES
                WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'bank_accounts']])
            if type(target) ~= 'string' or not target:match('^utf8mb4_[%w_]+$') then return end
            for _, tableName in ipairs({ 'pf_transactions', 'pf_ledger_baselines' }) do
                local current = MySQL.scalar.await([[SELECT TABLE_COLLATION FROM information_schema.TABLES
                    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?]], { tableName })
                if current and current ~= target then
                    MySQL.query.await(('ALTER TABLE `%s` CONVERT TO CHARACTER SET utf8mb4 COLLATE %s'):format(tableName, target))
                end
            end
        end,
    },
    {
        version = 5,
        name = 'record of legacy shared accounts moved to IBAN accounts',
        up = {
            [[CREATE TABLE IF NOT EXISTS `pf_shared_account_migration` (
                `legacy_name` VARCHAR(50) NOT NULL,
                `account_id` INT NOT NULL,
                `migrated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (`legacy_name`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
        },
    },
}

function L.Start()
    local ok, err = RunMigrations('pfm-banking', L.Migrations)
    if not ok then
        L.failed = true
        print(('^1[pfm-banking ledger]^7 migrations failed, money transfers disabled: %s'):format(tostring(err)))
        return false
    end
    L.ready = true
    local settled = L.Recover()
    if settled > 0 then print(('^3[pfm-banking ledger]^7 recovered %d interrupted transaction(s)'):format(settled)) end
    return true
end

CreateThread(function()
    if not L.Start() then return end
    while true do
        Wait(60000)
        local ok, err = pcall(L.Recover)
        if not ok then print(('^1[pfm-banking ledger]^7 recovery error: %s'):format(tostring(err))) end
    end
end)

-- ── exports ───────────────────────────────────────────────────────────────

exports('Transfer', function(opts) return L.Transfer(opts) end)
exports('GetTransaction', function(idOrKey) return L.GetTransaction(idOrKey) end)
exports('EnsureSocietyAccount', function(name, accountType) return L.EnsureSociety(name, accountType) end)
exports('ReconcileLedger', function() return L.Reconcile() end)
exports('LedgerAutoKey', function(prefix) return L.AutoKey(prefix) end)
--- true once migrations ran and transfers are accepted; false while starting; nil if they failed
exports('IsLedgerReady', function()
    if L.failed then return nil end
    return L.ready == true
end)

QBCore.Commands.Add('ledgerreconcile', 'Check society balances against the money ledger (admin)', {}, false, function(source)
    local report = L.Reconcile()
    local lines = {
        ('Ledger: %d accounts checked, %d mismatches, %d without baseline, %d stuck/unverified transactions'):format(
            report.checked, #report.mismatches, #report.missingBaseline, #report.stuck),
    }
    for _, m in ipairs(report.mismatches) do
        lines[#lines + 1] = ('  %s expected %.2f actual %.2f (difference %.2f)'):format(m.account, m.expected, m.actual, m.difference)
    end
    for _, line in ipairs(lines) do
        if source and source > 0 then TriggerClientEvent('chat:addMessage', source, { args = { 'Ledger', line } }) else print(line) end
    end
end, 'god')
