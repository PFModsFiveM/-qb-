-- In-memory stand-in for oxmysql that implements the statements pfm-banking and the ledger issue.
-- Ledger statements are matched by their exact text (PFLedger.SQL), so a changed statement fails
-- loudly instead of silently passing. Supports failure injection to simulate crashes mid-transfer.
FakeDB = {
    bank_accounts = {},        -- [name] = { account_name, account_balance, account_type, citizenid, users }
    players = {},              -- [citizenid] = { money = { bank, cash } }
    transactions = {},         -- array of rows
    byKey = {}, byTxId = {},
    baselines = {},            -- [account] = balance
    statements = {},
    migrations = {},           -- ['resource:version'] = true
    failNext = {},             -- [statement name] = true -> next execution raises an error
    log = {},
}

local function round2(n) return math.floor(n * 100 + 0.5) / 100 end

function FakeDB.reset()
    FakeDB.bank_accounts, FakeDB.players, FakeDB.transactions = {}, {}, {}
    FakeDB.byKey, FakeDB.byTxId, FakeDB.baselines, FakeDB.statements = {}, {}, {}, {}
    FakeDB.failNext, FakeDB.log = {}, {}
    -- server_accounts.lua / server_finance.lua tables
    FakeDB.v2, FakeDB.members, FakeDB.personalIban, FakeDB.bankTx = {}, {}, {}, {}
    FakeDB.loans, FakeDB.cards, FakeDB.credit = {}, {}, {}
    FakeDB.failInsertV2 = false
end
FakeDB.reset()

--- Adds a bank_accounts_v2 row (shared/business IBAN account) and returns its id.
function FakeDB.ibanAccount(owner, balance, label)
    local id = #FakeDB.v2 + 1
    FakeDB.v2[id] = { id = id, iban = ('PF%08d'):format(90000000 + id), label = label or ('Account ' .. id), type = 'shared', owner = owner, balance = balance or 0 }
    FakeDB.members[#FakeDB.members + 1] = { account_id = id, citizenid = owner, name = owner, can_withdraw = 1, can_deposit = 1, can_cards = 1, can_manage = 1 }
    return id
end

function FakeDB.member(accountId, citizenid, perms)
    perms = perms or {}
    FakeDB.members[#FakeDB.members + 1] = { account_id = accountId, citizenid = citizenid, name = citizenid,
        can_withdraw = perms.w or 0, can_deposit = perms.d or 0, can_cards = 0, can_manage = 0 }
end

local function findMember(accountId, citizenid)
    for i, m in ipairs(FakeDB.members) do
        if m.account_id == accountId and m.citizenid == citizenid then return m, i end
    end
end

function FakeDB.society(name, balance, accountType, citizenid, users)
    FakeDB.bank_accounts[name] = { account_name = name, account_balance = balance or 0, account_type = accountType or 'job', citizenid = citizenid, users = users or '[]' }
end

local function now() return Mock.clock end

local function touch(tx) tx.updated_at = now() end

local function maybeFail(name)
    if FakeDB.failNext[name] then
        FakeDB.failNext[name] = nil
        error('injected failure: ' .. name)
    end
end

local function stateTxn(txId, fromState)
    local tx = FakeDB.byTxId[txId]
    if tx and tx.state == fromState then return tx end
end

local S -- PFLedger.SQL, bound lazily (the ledger may load after this file)

local function ledgerHandlers()
    S = PFLedger.SQL
    return {
        [S.insertTx] = function(p)
            maybeFail('insertTx')
            if FakeDB.byKey[p[2]] or FakeDB.byTxId[p[1]] then error('Duplicate entry for key uq_idempotency_key') end
            local tx = { id = #FakeDB.transactions + 1, tx_id = p[1], idempotency_key = p[2], kind = p[3], from_account = p[4], to_account = p[5],
                amount = p[6], state = 'pending', reason = p[7], actor = p[8], metadata = p[9], created_at = now(), updated_at = now() }
            FakeDB.transactions[#FakeDB.transactions + 1] = tx
            FakeDB.byKey[tx.idempotency_key], FakeDB.byTxId[tx.tx_id] = tx, tx
            return tx.id
        end,
        [S.selectByKey] = function(p) return FakeDB.byKey[p[1]] end,
        [S.selectByTxId] = function(p) return FakeDB.byTxId[p[1]] end,
        [S.setState] = function(p)
            maybeFail('setState')
            local tx = stateTxn(p[3], p[4])
            if not tx then return 0 end
            tx.state, tx.error = p[1], p[2]
            touch(tx)
            return 1
        end,
        [S.debitSociety] = function(p)
            maybeFail('debitSociety')
            local amount, txId, name, minimum = p[1], p[2], p[3], p[4]
            local tx, acc = stateTxn(txId, 'pending'), FakeDB.bank_accounts[name]
            if not tx or not acc or acc.account_balance < minimum then return 0 end
            acc.account_balance = round2(acc.account_balance - amount)
            tx.state = 'debited'
            touch(tx)
            return 2
        end,
        [S.creditSociety] = function(p)
            maybeFail('creditSociety')
            local tx, acc = stateTxn(p[2], 'debited'), FakeDB.bank_accounts[p[3]]
            if not tx or not acc then return 0 end
            acc.account_balance = round2(acc.account_balance + p[1])
            tx.state = 'completed'
            touch(tx)
            return 2
        end,
        [S.refundSociety] = function(p)
            maybeFail('refundSociety')
            local tx, acc = stateTxn(p[3], 'debited'), FakeDB.bank_accounts[p[4]]
            if not tx or not acc then return 0 end
            acc.account_balance = round2(acc.account_balance + p[1])
            tx.state, tx.error = 'compensated', p[2]
            touch(tx)
            return 2
        end,
        [S.debitOfflinePlayer] = function(p)
            maybeFail('debitOfflinePlayer')
            local moneytype, amount, txId, cid, minimum = p[1], p[3], p[4], p[5], p[7]
            local tx, pl = stateTxn(txId, 'pending'), FakeDB.players[cid]
            if not tx or not pl or (pl.money[moneytype] or 0) < minimum then return 0 end
            pl.money[moneytype] = round2(pl.money[moneytype] - amount)
            tx.state = 'debited'
            touch(tx)
            return 2
        end,
        [S.creditOfflinePlayer] = function(p)
            maybeFail('creditOfflinePlayer')
            local moneytype, amount, toState, txId, cid = p[1], p[3], p[4], p[5], p[6]
            local tx, pl = stateTxn(txId, 'debited'), FakeDB.players[cid]
            if not tx or not pl then return 0 end
            pl.money[moneytype] = round2((pl.money[moneytype] or 0) + amount)
            tx.state = toState
            touch(tx)
            return 2
        end,
        [S.debitAcct] = function(p)
            maybeFail('debitAcct')
            local tx, acc = stateTxn(p[2], 'pending'), FakeDB.v2[p[3]]
            if not tx or not acc or acc.balance < p[4] then return 0 end
            acc.balance = round2(acc.balance - p[1])
            tx.state = 'debited'
            touch(tx)
            return 2
        end,
        [S.creditAcct] = function(p)
            maybeFail('creditAcct')
            local tx, acc = stateTxn(p[2], 'debited'), FakeDB.v2[p[3]]
            if not tx or not acc then return 0 end
            acc.balance = round2(acc.balance + p[1])
            tx.state = 'completed'
            touch(tx)
            return 2
        end,
        [S.refundAcct] = function(p)
            local tx, acc = stateTxn(p[3], 'debited'), FakeDB.v2[p[4]]
            if not tx or not acc then return 0 end
            acc.balance = round2(acc.balance + p[1])
            tx.state, tx.error = 'compensated', p[2]
            touch(tx)
            return 2
        end,
        [S.acctExists] = function(p) return FakeDB.v2[p[1]] and 1 or nil end,
        [S.reconcileAcct] = function()
            local out = {}
            for id, acc in pairs(FakeDB.v2) do
                local ref = 'acct:' .. id
                local credits, debits = 0, 0
                for _, tx in ipairs(FakeDB.transactions) do
                    if tx.to_account == ref and tx.state == 'completed' then credits = credits + tx.amount end
                    if tx.from_account == ref and (tx.state == 'debited' or tx.state == 'completed') then debits = debits + tx.amount end
                end
                out[#out + 1] = { account_name = ref, actual = acc.balance, baseline = FakeDB.baselines[ref], credits = credits, debits = debits }
            end
            return out
        end,
        [S.societyBalance] = function(p) local a = FakeDB.bank_accounts[p[1]]; return a and a.account_balance end,
        [S.ensureSociety] = function(p)
            if FakeDB.bank_accounts[p[1]] then return 0 end
            FakeDB.society(p[1], 0, p[2])
            return 1
        end,
        [S.ensureBaseline] = function(p)
            if FakeDB.baselines[p[1]] == nil then FakeDB.baselines[p[1]] = p[2] end
            return 1
        end,
        [S.playerExists] = function(p) return FakeDB.players[p[1]] and 1 or nil end,
        [S.staleTx] = function(p)
            local out = {}
            for _, tx in ipairs(FakeDB.transactions) do
                local age = now() - tx.updated_at
                if (tx.state == 'pending' and age > p[1]) or (tx.state == 'debited' and age > p[2]) then
                    local copy = {}
                    for k, v in pairs(tx) do copy[k] = v end
                    out[#out + 1] = copy
                end
            end
            return out
        end,
        [S.reconcile] = function()
            local out = {}
            for name, acc in pairs(FakeDB.bank_accounts) do
                local ref = 'society:' .. name
                local credits, debits = 0, 0
                for _, tx in ipairs(FakeDB.transactions) do
                    if tx.to_account == ref and tx.state == 'completed' then credits = credits + tx.amount end
                    if tx.from_account == ref and (tx.state == 'debited' or tx.state == 'completed') then debits = debits + tx.amount end
                end
                out[#out + 1] = { account_name = name, actual = acc.account_balance, baseline = FakeDB.baselines[ref], credits = credits, debits = debits }
            end
            return out
        end,
        [S.problemTx] = function()
            local out = {}
            for _, tx in ipairs(FakeDB.transactions) do
                if ((tx.state == 'pending' or tx.state == 'debited') and now() - tx.updated_at > 300)
                    or (tx.state == 'failed' and tx.error == 'interrupted_unverified') then
                    out[#out + 1] = tx
                end
            end
            return out
        end,
    }
end

local handlers

local function loanById(id) for _, l in ipairs(FakeDB.loans) do if l.id == id then return l end end end
local function cardById(id) for _, c in ipairs(FakeDB.cards) do if c.id == id then return c end end end

-- server_accounts.lua / server_finance.lua statements. Checked before `patterns` because
-- 'SELECT * FROM bank_accounts' is a prefix of the v2 queries. Longer fragments come first.
local v2patterns = {
    { "SELECT CONCAT('acct:', id), balance FROM bank_accounts_v2", function()
        for id, acc in pairs(FakeDB.v2) do
            if FakeDB.baselines['acct:' .. id] == nil then FakeDB.baselines['acct:' .. id] = acc.balance end
        end
        return 1
    end },
    { 'SELECT * FROM bank_accounts_v2 WHERE id = ?', function(p) return FakeDB.v2[tonumber(p[1])] end },
    { 'SELECT * FROM bank_account_members WHERE account_id = ? AND citizenid = ?', function(p)
        return (findMember(p[1], p[2]))
    end },
    { 'SELECT COUNT(*) FROM bank_accounts_v2 WHERE owner = ?', function(p)
        local n = 0
        for _, a in pairs(FakeDB.v2) do if a.owner == p[1] then n = n + 1 end end
        return n
    end },
    { 'SELECT 1 FROM bank_accounts_v2 WHERE iban = ?', function(p)
        for _, a in pairs(FakeDB.v2) do if a.iban == p[1] then return 1 end end
    end },
    { 'SELECT 1 FROM bank_personal_iban WHERE iban = ?', function(p)
        for _, iban in pairs(FakeDB.personalIban) do if iban == p[1] then return 1 end end
    end },
    { 'SELECT citizenid FROM bank_personal_iban WHERE iban = ?', function(p)
        for cid, iban in pairs(FakeDB.personalIban) do if iban == p[1] then return cid end end
    end },
    { 'SELECT id, label, iban FROM bank_accounts_v2 WHERE iban = ?', function(p)
        for _, a in pairs(FakeDB.v2) do if a.iban == p[1] then return a end end
    end },
    { 'INSERT INTO bank_accounts_v2 (iban, label, type, owner)', function(p)
        if FakeDB.failInsertV2 then return nil end
        local id = #FakeDB.v2 + 1
        FakeDB.v2[id] = { id = id, iban = p[1], label = p[2], type = p[3], owner = p[4], balance = 0 }
        return id
    end },
    { 'INSERT INTO bank_account_members', function(p)
        FakeDB.members[#FakeDB.members + 1] = { account_id = p[1], citizenid = p[2], name = p[3], can_withdraw = 1, can_deposit = 1, can_cards = 1, can_manage = 1 }
        return 1
    end },
    { 'DELETE FROM bank_accounts_v2 WHERE id = ? AND balance = 0', function(p)
        local acc = FakeDB.v2[p[1]]
        if acc and acc.balance == 0 then FakeDB.v2[p[1]] = nil; return 1 end
        return 0
    end },
    { 'UPDATE bank_account_cards SET cancelled = 1 WHERE account_id = ?', function() return 0 end },
    { 'DELETE FROM bank_account_members WHERE account_id = ?', function(p)
        for i = #FakeDB.members, 1, -1 do if FakeDB.members[i].account_id == p[1] then table.remove(FakeDB.members, i) end end
        return 1
    end },
    { 'INSERT INTO bank_transactions', function(p) FakeDB.bankTx[#FakeDB.bankTx + 1] = p; return #FakeDB.bankTx end },

    -- credit score
    { 'SELECT score FROM bank_credit WHERE citizenid = ?', function(p) return FakeDB.credit[p[1]] end },
    { 'INSERT INTO bank_credit', function(p) FakeDB.credit[p[1]] = p[2]; return 1 end },
    { 'UPDATE bank_credit SET score = ?', function(p) FakeDB.credit[p[2]] = p[1]; return 1 end },

    -- loans
    { 'SELECT * FROM bank_loans WHERE citizenid = ? AND status = "active"', function(p)
        local out = {}
        for _, l in ipairs(FakeDB.loans) do if l.citizenid == p[1] and l.status == 'active' then out[#out + 1] = l end end
        return out
    end },
    { 'SELECT * FROM bank_loans WHERE id = ? AND citizenid = ? AND status = "active"', function(p)
        local l = loanById(p[1])
        if l and l.citizenid == p[2] and l.status == 'active' then
            local copy = {}
            for k, v in pairs(l) do copy[k] = v end
            return copy
        end
    end },
    { 'SELECT * FROM bank_loans WHERE status = "active" AND next_payment <= ?', function(p)
        local out = {}
        for _, l in ipairs(FakeDB.loans) do
            if l.status == 'active' and l.next_payment <= p[1] then
                local copy = {}
                for k, v in pairs(l) do copy[k] = v end
                out[#out + 1] = copy
            end
        end
        return out
    end },
    { 'INSERT INTO bank_loans', function(p)
        local id = #FakeDB.loans + 1
        FakeDB.loans[id] = { id = id, citizenid = p[1], tier = p[2], principal = p[3], balance = p[4], apr = p[5], payment_amount = p[6],
            payments_total = p[7], payments_made = 0, missed_payments = 0, next_payment = p[8], status = 'active' }
        return id
    end },
    { 'UPDATE bank_loans SET status = "void"', function(p)
        local l = loanById(p[1])
        if l and l.payments_made == 0 then l.status = 'void'; return 1 end
        return 0
    end },
    { 'UPDATE bank_loans SET balance = 0, payments_made = payments_made + 1, status = "paid"', function(p)
        local l = loanById(p[1])
        if not l or l.status ~= 'active' or l.payments_made ~= p[2] or l.balance ~= p[3] then return 0 end
        l.balance, l.payments_made, l.status = 0, l.payments_made + 1, 'paid'
        return 1
    end },
    { 'UPDATE bank_loans SET balance = ?, payments_made = payments_made + 1, next_payment = ?', function(p)
        local l = loanById(p[3])
        if not l or l.status ~= 'active' or l.payments_made ~= p[4] or l.balance ~= p[5] then return 0 end
        l.balance, l.payments_made, l.next_payment = p[1], l.payments_made + 1, p[2]
        return 1
    end },
    { 'UPDATE bank_loans SET balance = balance + ?, missed_payments', function(p)
        local l = loanById(p[3])
        if not l or l.status ~= 'active' or l.next_payment ~= p[4] then return 0 end
        l.balance, l.missed_payments, l.next_payment = l.balance + p[1], l.missed_payments + 1, p[2]
        return 1
    end },

    -- credit cards
    { 'SELECT * FROM bank_cards WHERE citizenid = ? AND status = "active"', function(p)
        local out = {}
        for _, c in ipairs(FakeDB.cards) do if c.citizenid == p[1] and c.status == 'active' then out[#out + 1] = c end end
        return out
    end },
    { 'SELECT * FROM bank_cards WHERE id = ? AND citizenid = ?', function(p)
        local c = cardById(p[1])
        if c and c.citizenid == p[2] and c.status == 'active' then
            local copy = {}
            for k, v in pairs(c) do copy[k] = v end
            return copy
        end
    end },
    { 'UPDATE bank_cards SET balance = balance + ? WHERE id = ? AND status = "active" AND balance + ? <= credit_limit', function(p)
        local c = cardById(p[2])
        if not c or c.status ~= 'active' or c.balance + p[3] > c.credit_limit then return 0 end
        c.balance = c.balance + p[1]
        return 1
    end },
    { 'UPDATE bank_cards SET balance = balance - ? WHERE id = ? AND balance >= ?', function(p)
        local c = cardById(p[2])
        if not c or c.balance < p[3] then return 0 end
        c.balance = c.balance - p[1]
        return 1
    end },
    { 'UPDATE bank_cards SET balance = balance - ? WHERE id = ?', function(p)
        local c = cardById(p[2])
        if not c then return 0 end
        c.balance = c.balance - p[1]
        return 1
    end },
}

-- Statements outside the ledger, matched by a distinctive fragment.
local patterns = {
    { 'CREATE TABLE IF NOT EXISTS', function() return 0 end },
    { 'ALTER TABLE', function() return 0 end },
    { 'SELECT TABLE_COLLATION FROM information_schema.TABLES', function() return nil end },
    { 'SELECT version FROM pf_schema_migrations', function(p)
        local out = {}
        for key in pairs(FakeDB.migrations) do
            local res, v = key:match('^(.-):(%d+)$')
            if res == p[1] then out[#out + 1] = { version = tonumber(v) } end
        end
        return out
    end },
    { 'INSERT INTO pf_schema_migrations', function(p) FakeDB.migrations[p[1] .. ':' .. p[2]] = true; return 1 end },
    { "SELECT CONCAT('society:', account_name), account_balance FROM bank_accounts WHERE account_name IS NOT NULL", function()
        for name, acc in pairs(FakeDB.bank_accounts) do
            local ref = 'society:' .. name
            if FakeDB.baselines[ref] == nil then FakeDB.baselines[ref] = acc.account_balance end
        end
        return 1
    end },
    { 'INSERT IGNORE INTO pf_ledger_baselines (account, balance) VALUES (?, 0)', function(p)
        if FakeDB.baselines[p[1]] == nil then FakeDB.baselines[p[1]] = 0 end
        return 1
    end },
    { 'INSERT IGNORE INTO pf_ledger_baselines (account, balance) VALUES (?, ?)', function(p)
        if FakeDB.baselines[p[1]] == nil then FakeDB.baselines[p[1]] = p[2] end
        return 1
    end },
    { 'DELETE FROM pf_ledger_baselines WHERE account = ?', function(p) FakeDB.baselines[p[1]] = nil; return 1 end },
    { 'REPLACE INTO pf_ledger_baselines', function(p)
        local acc = FakeDB.bank_accounts[p[1]]
        if acc then FakeDB.baselines['society:' .. p[1]] = acc.account_balance end
        return 1
    end },
    { 'INSERT IGNORE INTO bank_accounts (account_name, account_balance, account_type) VALUES (?, ?, ?)', function(p)
        if FakeDB.bank_accounts[p[1]] then return 0 end
        FakeDB.society(p[1], p[2], p[3])
        return 1
    end },
    { 'INSERT INTO bank_accounts (citizenid, account_name, account_balance, account_type, users)', function(p)
        if FakeDB.bank_accounts[p[2]] then error('Duplicate entry for key account_name') end
        FakeDB.society(p[2], p[3], p[4], p[1], p[5])
        return 1
    end },
    { 'DELETE FROM bank_accounts WHERE account_name = ? AND citizenid = ? AND account_balance = 0', function(p)
        local acc = FakeDB.bank_accounts[p[1]]
        if acc and acc.citizenid == p[2] and acc.account_balance == 0 then FakeDB.bank_accounts[p[1]] = nil; return { affectedRows = 1 } end
        return { affectedRows = 0 }
    end },
    { 'UPDATE bank_accounts SET account_name = ?', function(p)
        local acc = FakeDB.bank_accounts[p[2]]
        if not acc or acc.citizenid ~= p[3] or FakeDB.bank_accounts[p[1]] then return 0 end
        FakeDB.bank_accounts[p[2]] = nil
        acc.account_name = p[1]
        FakeDB.bank_accounts[p[1]] = acc
        return 1
    end },
    { 'INSERT INTO bank_statements', function(p) FakeDB.statements[#FakeDB.statements + 1] = p; return #FakeDB.statements end },
    { 'UPDATE pf_transactions SET error = ? WHERE tx_id = ?', function(p) local tx = FakeDB.byTxId[p[2]]; if tx then tx.error = p[1] end; return 1 end },
    { 'SELECT * FROM bank_accounts', function()
        local out = {}
        for _, acc in pairs(FakeDB.bank_accounts) do out[#out + 1] = acc end
        return out
    end },
    { 'SELECT * FROM bank_statements', function() return {} end },
    -- pf-government treasury mirror (a display copy; the society account is authoritative)
    { 'UPDATE pf_gov_treasury SET balance = ?', function(p) FakeDB.treasuryMirror = p[1]; return 1 end },
    { 'INSERT INTO pf_gov_transactions', function(p)
        FakeDB.govTransactions = FakeDB.govTransactions or {}
        FakeDB.govTransactions[#FakeDB.govTransactions + 1] = p
        return #FakeDB.govTransactions
    end },
}

local function run(kind, query, params)
    handlers = handlers or (PFLedger and PFLedger.SQL and ledgerHandlers())
    params = params or {}
    FakeDB.log[#FakeDB.log + 1] = query
    if handlers and handlers[query] then return handlers[query](params) end
    -- statements a spec adds for the resource it tests (checked first)
    for _, entry in ipairs(FakeDB.extraPatterns or {}) do
        if query:find(entry[1], 1, true) then return entry[2](params) end
    end
    for _, entry in ipairs(v2patterns) do
        if query:find(entry[1], 1, true) then return entry[2](params) end
    end
    for _, entry in ipairs(patterns) do
        if query:find(entry[1], 1, true) then return entry[2](params) end
    end
    error('FakeDB: unhandled ' .. kind .. ' statement: ' .. tostring(query):sub(1, 120))
end

local function op(kind, shape)
    local function call(query, params, cb)
        if type(params) == 'function' then cb, params = params, nil end
        local out = run(kind, query, params)
        if kind == 'single' and type(out) == 'table' and out[1] then out = out[1] end
        if kind == 'update' or kind == 'rawExecute' then
            if type(out) == 'table' and out.affectedRows then out = (kind == 'update') and out.affectedRows or out end
        end
        if cb then cb(out) end
        return out
    end
    return setmetatable({ await = function(q, p) return call(q, p) end }, { __call = function(_, q, p, cb) return call(q, p, cb) end })
end

MySQL = {
    query = op('query'), insert = op('insert'), update = op('update'), prepare = op('prepare'),
    scalar = op('scalar'), single = op('single'), rawExecute = op('rawExecute'),
    ready = function(fn) fn() end,
}
