-- pfm-phone invoice ledger tokens on a real database: the columns (ledger_token with its UUID()
-- default, pay_state) are added once to a table created before them (older rows keep NULL and are
-- checked against their id keys), every invoice gets a unique token (also one another resource
-- inserts directly), and paying moves money exactly once on the real ledger: a reused id is charged,
-- a pending, debited or interrupted_unverified attempt is waited for, failed attempts move to the
-- next key without a cap, a charged invoice is never declined, and a half-paid one (the business
-- credit cut off) is finished by the sweep on the next key.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
function GetResourceState() return 'started' end

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
-- phone_invoices as qb-phone.sql created it before the token, with an invoice already in it
MySQL.query.await([[CREATE TABLE IF NOT EXISTS `phone_invoices` (`id` int(10) NOT NULL AUTO_INCREMENT, `citizenid` varchar(50) DEFAULT NULL,
    `amount` int(11) NOT NULL DEFAULT 0, `society` tinytext DEFAULT NULL, `sender` varchar(50) DEFAULT NULL,
    `sendercitizenid` varchar(50) DEFAULT NULL, `candecline` int(1) not null default 1, `reason` varchar(256) default null,
    PRIMARY KEY (`id`), KEY `citizenid` (`citizenid`)) ENGINE=InnoDB AUTO_INCREMENT=1 DEFAULT CHARSET=utf8mb4]])
MySQL.insert.await("INSERT INTO phone_invoices (id, citizenid, amount, society, sender) VALUES (900, 'CID1', 120, 'mechanic', 'Old')")
-- re-importing the current qb-phone.sql leaves that table as it is (and adds the other phone tables)
RealDB.exec('pfm-phone/qb-phone.sql')

function GetCurrentResourceName() return 'pfm-banking' end
Config = nil
load_resource('pfm-banking/config.lua')
load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')
local bankingConfig = Config
Mock.exportsByResource['pfm-banking'] = Mock.exportsByResource['__self']
Mock.exportsByResource['__self'] = nil
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end
assert(PFLedger.Start(), 'ledger start')
MySQL.query.await("INSERT INTO bank_accounts (account_name, account_balance, account_type, users) VALUES ('mechanic', 0, 'business', '[]') ON DUPLICATE KEY UPDATE account_balance = 0")
MySQL.query.await("INSERT IGNORE INTO pf_ledger_baselines (account, balance) VALUES ('society:mechanic', 0)")

-- counts the ALTER statements pfm-phone runs (a restart must run none)
local alters = {}
local query = MySQL.query
MySQL.query = setmetatable({ await = function(q, p)
    if type(q) == 'string' and q:find('ALTER TABLE `phone_invoices`', 1, true) then alters[#alters + 1] = q end
    return query.await(q, p)
end }, { __call = function(_, ...) return query(...) end })

local phone
local commands = {}
local function startPhone()
    function GetCurrentResourceName() return 'pfm-phone' end
    Config = nil
    local add = QBCoreMock.Commands.Add
    QBCoreMock.Commands.Add = function(name, _, _, _, fn) commands[name] = fn end
    load_resource('pfm-banking/payouts.lua')
    load_resource('pfm-phone/config.lua')
    load_resource('pfm-phone/server/main.lua')
    QBCoreMock.Commands.Add = add
    for k, v in pairs(bankingConfig) do if Config[k] == nil then Config[k] = v end end
    Config.BillingCommissions = {}
    phone = Mock.exportsByResource['__self']
    Mock.exportsByResource['pfm-phone'] = phone
    Mock.exportsByResource['__self'] = nil
end
startPhone()

local A = 1
local function bank() return Mock.players[A].PlayerData.money.bank end
local function society() return tonumber(MySQL.scalar.await("SELECT account_balance FROM bank_accounts WHERE account_name = 'mechanic'")) or 0 end
local function create(amount)
    return phone.CreateInvoice({ citizenid = 'CID1', amount = amount or 300, society = 'mechanic', sender = 'Bob', sendercitizenid = 'CID2' })
end
local function token(id) return MySQL.scalar.await('SELECT ledger_token FROM phone_invoices WHERE id = ?', { id }) end
local function state(key) return MySQL.scalar.await('SELECT state FROM pf_transactions WHERE idempotency_key = ?', { key }) end
local function charges(base)
    return tonumber(MySQL.scalar.await([[SELECT COUNT(*) FROM pf_transactions WHERE state = 'completed'
        AND idempotency_key LIKE CONCAT(?, '%') AND idempotency_key LIKE '%:bank']], { base })) or 0
end
local function rowCount(id) return tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM phone_invoices WHERE id = ?', { id })) end
local function recover()
    local p, d = PFLedger.STALE_PENDING_SECONDS, PFLedger.STALE_DEBITED_SECONDS
    PFLedger.STALE_PENDING_SECONDS, PFLedger.STALE_DEBITED_SECONDS = -1, -1
    PFLedger.Recover()
    PFLedger.STALE_PENDING_SECONDS, PFLedger.STALE_DEBITED_SECONDS = p, d
end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    local p = Mock.newPlayer(A)
    p.PlayerData.money = { cash = 0, bank = 5000 }
    local b = Mock.newPlayer(2)
    b.PlayerData.job = { name = 'mechanic', onduty = true }
    MySQL.update.await("UPDATE bank_accounts SET account_balance = 0 WHERE account_name = 'mechanic'")
    MySQL.update.await("REPLACE INTO pf_ledger_baselines (account, balance) VALUES ('society:mechanic', 0)")
end

describe('the ledger_token column on a table from before it', function()
    it('is added once, nullable, with a UUID() default; older rows keep NULL', function()
        local id = create()
        assert_true(id ~= nil)
        local col = MySQL.single.await([[SELECT IS_NULLABLE AS nullable, COLUMN_DEFAULT AS def FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'phone_invoices' AND COLUMN_NAME = 'ledger_token']])
        assert_eq(col.nullable, 'YES')
        assert_true(tostring(col.def):lower():find('uuid', 1, true) ~= nil, tostring(col.def))
        local ps = MySQL.single.await([[SELECT IS_NULLABLE AS nullable, COLUMN_DEFAULT AS def FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'phone_invoices' AND COLUMN_NAME = 'pay_state']])
        assert_eq(ps.nullable, 'YES')
        assert_eq(#alters, 3)                          -- ledger_token, pay_state, the UUID() default
        assert_eq(token(900), nil)
        assert_true(type(token(id)) == 'string' and #token(id) > 0)
        -- a restart finds both and runs no ALTER
        alters = {}
        startPhone()
        create()
        assert_eq(#alters, 0)
    end)
    it('gives every invoice its own token, also one another resource inserts directly', function()
        local a, b = create(), create()
        assert_true(token(a) ~= token(b))
        -- pfm-policejob's /bill inserts without the column
        local c = MySQL.insert.await('INSERT INTO phone_invoices (citizenid, amount, society, sender, sendercitizenid) VALUES (?, ?, ?, ?, ?)',
            { 'CID1', 75, 'mechanic', 'Cop', 'CID2' })
        local t = token(c)
        assert_true(type(t) == 'string' and #t == 36, tostring(t))
        assert_true(t ~= token(a) and t ~= token(b))
        assert_eq(phone.PayInvoice(A, c), true)
        assert_eq(state('pfm-phone:invoice:tok:' .. t .. ':bank'), 'completed')
        assert_eq(state('pfm-phone:invoice:' .. c .. ':bank'), nil)
    end)
end)

describe('paying an invoice on the real ledger', function()
    it('moves money once; a new invoice under a reused id is charged again', function()
        local id = create(300)
        assert_eq(phone.PayInvoice(A, id), true)
        assert_eq(bank(), 4700)
        assert_eq(society(), 300)
        assert_eq(rowCount(id), 0)
        local ok, err = phone.PayInvoice(A, id)
        assert_eq(ok, false)
        assert_eq(err, 'not_found')
        -- the id comes back (truncated table, AUTO_INCREMENT reset): a different invoice
        MySQL.insert.await("INSERT INTO phone_invoices (id, citizenid, amount, society, sender) VALUES (?, 'CID1', 300, 'mechanic', 'Bob')", { id })
        assert_eq(phone.PayInvoice(A, id), true)
        assert_eq(bank(), 4400)
        assert_eq(society(), 600)
    end)
    it('a row from before the token keeps its id key, so its earlier charge counts', function()
        -- charged before the token existed, and the server stopped before the row was deleted
        assert_eq(PFLedger.Transfer({ from = 'player:CID1:bank', to = 'system:pfm-phone', amount = 120, key = 'pfm-phone:invoice:900:bank', kind = 'purchase' }).ok, true)
        assert_eq(bank(), 4880)
        assert_eq(phone.PayInvoice(A, 900), true)
        assert_eq(bank(), 4880)
        assert_eq(society(), 120)
        assert_eq(state('pfm-phone:invoice:900:society'), 'completed')
        assert_eq(rowCount(900), 0)
    end)
    it('a debited attempt is waited for, then counts as the payment once recovery completes it', function()
        local id = create(400)
        local base = 'pfm-phone:invoice:tok:' .. token(id)
        assert_eq(PFLedger.Transfer({ from = 'player:CID1:bank', to = 'system:pfm-phone', amount = 400, key = base .. ':bank', kind = 'purchase' }).ok, true)
        MySQL.update.await("UPDATE pf_transactions SET state = 'debited' WHERE idempotency_key = ?", { base .. ':bank' })
        local ok, err = phone.PayInvoice(A, id)
        assert_eq(ok, false)
        assert_eq(err, 'in_progress')
        assert_eq(state(base .. ':retry2:bank'), nil)
        assert_eq(bank(), 4600)
        recover()
        assert_eq(state(base .. ':bank'), 'completed')
        assert_eq(phone.PayInvoice(A, id), true)
        assert_eq(bank(), 4600)
        assert_eq(society(), 400)
        assert_eq(charges(base), 1)
    end)
    it('a pending attempt is waited for, also once recovery marks it interrupted_unverified; reconciled, the next key charges once', function()
        local id = create(250)
        local base = 'pfm-phone:invoice:tok:' .. token(id)
        -- the attempt was stored, then the server stopped (an online payer: the debit cannot be verified)
        MySQL.insert.await([[INSERT INTO pf_transactions (tx_id, idempotency_key, kind, from_account, to_account, amount, state)
            VALUES ('txcrash1', ?, 'purchase', 'player:CID1:bank', 'system:pfm-phone', 250, 'pending')]], { base .. ':bank' })
        local ok, err = phone.PayInvoice(A, id)
        assert_eq(err, 'in_progress')
        assert_eq(bank(), 5000)
        recover()
        assert_eq(state(base .. ':bank'), 'failed')
        assert_eq(MySQL.scalar.await('SELECT error FROM pf_transactions WHERE idempotency_key = ?', { base .. ':bank' }), 'interrupted_unverified')
        ok, err = phone.PayInvoice(A, id)
        assert_eq(ok, false)
        assert_eq(err, 'in_progress')
        assert_eq(state(base .. ':retry2:bank'), nil)
        assert_eq(MySQL.scalar.await('SELECT pay_state FROM phone_invoices WHERE id = ?', { id }), 'paying')
        assert_eq(select(2, phone.DeclineInvoice(A, id)), 'in_progress')
        -- an admin reconciles it: the money never left
        MySQL.update.await("UPDATE pf_transactions SET error = 'checked_not_taken' WHERE idempotency_key = ?", { base .. ':bank' })
        assert_eq(PFPhoneInvoices.Sweep(), 1)
        assert_eq(MySQL.scalar.await('SELECT pay_state FROM phone_invoices WHERE id = ?', { id }), nil)
        assert_eq(phone.PayInvoice(A, id), true)
        assert_eq(bank(), 4750)
        assert_eq(state(base .. ':retry2:bank'), 'completed')
        assert_eq(charges(base), 1)
    end)
    it('failed attempts never lock it out, also after a restart', function()
        local id = create(800)
        local base = 'pfm-phone:invoice:tok:' .. token(id)
        Mock.players[A].PlayerData.money.bank = 100
        for i = 1, 22 do
            local ok, err = phone.PayInvoice(A, id)
            assert_eq(err, 'insufficient_funds', 'attempt ' .. i)
        end
        assert_eq(state(base .. ':retry22:bank'), 'failed')
        Mock.players[A].PlayerData.money.bank = 1000
        startPhone()
        assert_eq(phone.PayInvoice(A, id), true)
        assert_eq(bank(), 200)
        assert_eq(state(base .. ':retry23:bank'), 'completed')
        assert_eq(charges(base), 1)
        assert_eq(society(), 800)
    end)
    it('a crash after the business was credited: paying again moves no money and removes the invoice', function()
        local id = create(150)
        local base = 'pfm-phone:invoice:tok:' .. token(id)
        assert_eq(PFLedger.Transfer({ from = 'player:CID1:bank', to = 'system:pfm-phone', amount = 150, key = base .. ':bank', kind = 'purchase' }).ok, true)
        assert_eq(PFPayout.PaySociety('mechanic', 150, { key = base .. ':society' }), true)
        assert_eq(phone.PayInvoice(A, id), true)
        assert_eq(bank(), 4850)
        assert_eq(society(), 150)
        assert_eq(rowCount(id), 0)
    end)
end)

describe('settling a half-paid invoice on the real database', function()
    it('a charged invoice is not declined: the payment is finished and the business paid', function()
        local id = create(200)
        local base = 'pfm-phone:invoice:tok:' .. token(id)
        assert_eq(PFLedger.Transfer({ from = 'player:CID1:bank', to = 'system:pfm-phone', amount = 200, key = base .. ':bank', kind = 'purchase' }).ok, true)
        local ok, err = phone.DeclineInvoice(A, id)
        assert_eq(ok, false)
        assert_eq(err, 'not_open')
        assert_eq(rowCount(id), 0)
        assert_eq(society(), 200)
        assert_eq(bank(), 4800)
    end)
    it('a business credit cut off by a crash: paying is not reported done; the sweep pays it once on the next key', function()
        local id = create(350)
        local base = 'pfm-phone:invoice:tok:' .. token(id)
        assert_eq(PFLedger.Transfer({ from = 'player:CID1:bank', to = 'system:pfm-phone', amount = 350, key = base .. ':bank', kind = 'purchase' }).ok, true)
        MySQL.insert.await([[INSERT INTO pf_transactions (tx_id, idempotency_key, kind, from_account, to_account, amount, state)
            VALUES ('txcrash2', ?, 'deposit', 'system:pfm-phone', 'society:mechanic', 350, 'pending')]], { base .. ':society' })
        local ok, err = phone.PayInvoice(A, id)
        assert_eq(ok, false)
        assert_eq(err, 'in_progress')
        assert_eq(rowCount(id), 1)
        assert_eq(MySQL.scalar.await('SELECT pay_state FROM phone_invoices WHERE id = ?', { id }), 'paying')
        assert_eq(society(), 0)
        recover() -- a system source: failed / interrupted, nothing moved
        assert_eq(state(base .. ':society'), 'failed')
        assert_eq(PFPhoneInvoices.Sweep(), 1)
        assert_eq(state(base .. ':society:retry2'), 'completed')
        assert_eq(society(), 350)
        assert_eq(rowCount(id), 0)
        assert_eq(bank(), 4650)
        assert_eq(charges(base), 1)
    end)
    it('a row without a token: a pending charge on its id key waits; with none it gets a token first', function()
        MySQL.insert.await("INSERT INTO phone_invoices (id, citizenid, amount, society, sender, ledger_token) VALUES (9901, 'CID1', 90, 'mechanic', 'Old', NULL)")
        MySQL.insert.await([[INSERT INTO pf_transactions (tx_id, idempotency_key, kind, from_account, to_account, amount, state)
            VALUES ('txcrash3', 'pfm-phone:invoice:9901:bank', 'purchase', 'player:CID1:bank', 'system:pfm-phone', 90, 'pending')]])
        assert_eq(select(2, phone.PayInvoice(A, 9901)), 'in_progress')
        assert_eq(token(9901), nil)
        assert_eq(state('pfm-phone:invoice:9901:retry2:bank'), nil)
        MySQL.insert.await("INSERT INTO phone_invoices (id, citizenid, amount, society, sender, ledger_token) VALUES (9902, 'CID1', 60, 'mechanic', 'Old', NULL)")
        assert_eq(phone.PayInvoice(A, 9902), true)
        assert_eq(bank(), 4940)
        assert_eq(state('pfm-phone:invoice:9902:bank'), nil)
        assert_eq(tonumber(MySQL.scalar.await([[SELECT COUNT(*) FROM pf_transactions WHERE state = 'completed'
            AND idempotency_key LIKE 'pfm-phone:invoice:tok:%:bank' AND amount = 60]])), 1)
        assert_eq(society(), 60)
    end)
end)

describe('second round on the real database', function()
    it('the sweep pages past invoices that wait for good and still finishes a later half-paid one', function()
        -- 60 invoices whose charge was recovered as interrupted_unverified: they wait for an admin
        for i = 0, 59 do
            local id = 9500 + i
            MySQL.insert.await("INSERT INTO phone_invoices (id, citizenid, amount, society, sender, ledger_token, pay_state) VALUES (?, 'CID1', 10, 'mechanic', 'Old', ?, 'paying')",
                { id, 'stuck' .. id })
            MySQL.insert.await([[INSERT INTO pf_transactions (tx_id, idempotency_key, kind, from_account, to_account, amount, state, error)
                VALUES (?, ?, 'purchase', 'player:CID1:bank', 'system:pfm-phone', 10, 'failed', 'interrupted_unverified')]],
                { 'txstuck' .. id, 'pfm-phone:invoice:tok:stuck' .. id .. ':bank' })
        end
        -- behind them, an invoice charged before a crash, its business not credited yet
        MySQL.insert.await("INSERT INTO phone_invoices (id, citizenid, amount, society, sender, ledger_token, pay_state) VALUES (9700, 'CID1', 120, 'mechanic', 'Bob', 'late9700', 'paying')")
        assert_eq(PFLedger.Transfer({ from = 'player:CID1:bank', to = 'system:pfm-phone', amount = 120, key = 'pfm-phone:invoice:tok:late9700:bank', kind = 'purchase' }).ok, true)
        startPhone() -- a restart: the sweep starts from the first row
        local realPrint = print
        print = function() end -- one admin warning per stuck invoice
        local ok, err = pcall(function()
            for _ = 1, 3 do PFPhoneInvoices.Sweep() end
        end)
        print = realPrint
        assert_true(ok, tostring(err))
        assert_eq(rowCount(9700), 0)
        assert_eq(society(), 120)
        assert_eq(bank(), 4880)
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM phone_invoices WHERE id BETWEEN 9500 AND 9559 AND pay_state = 'paying'")), 60)
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_transactions WHERE idempotency_key LIKE 'pfm-phone:invoice:tok:stuck%:retry2:bank'")), 0)
        MySQL.update.await('DELETE FROM phone_invoices WHERE id BETWEEN 9500 AND 9559')
    end)
    it("a row keyed by id: an older invoice's business credit under the same id does not count for this one", function()
        -- invoice 9910 of another payer was paid in full on the id keys, then the id came back
        MySQL.insert.await([[INSERT INTO pf_transactions (tx_id, idempotency_key, kind, from_account, to_account, amount, state)
            VALUES ('txold9910a', 'pfm-phone:invoice:9910:bank', 'purchase', 'player:CIDX:bank', 'system:pfm-phone', 500, 'completed')]])
        MySQL.insert.await([[INSERT INTO pf_transactions (tx_id, idempotency_key, kind, from_account, to_account, amount, state)
            VALUES ('txold9910b', 'pfm-phone:invoice:9910:society', 'deposit', 'system:pfm-phone', 'society:mechanic', 500, 'completed')]])
        -- the new invoice 9910 (no token) was charged on its next id key, then the server stopped
        MySQL.insert.await("INSERT INTO phone_invoices (id, citizenid, amount, society, sender, ledger_token) VALUES (9910, 'CID1', 500, 'mechanic', 'Bob', NULL)")
        assert_eq(PFLedger.Transfer({ from = 'player:CID1:bank', to = 'system:pfm-phone', amount = 500, key = 'pfm-phone:invoice:9910:retry2:bank', kind = 'purchase' }).ok, true)
        assert_eq(phone.PayInvoice(A, 9910), true)
        assert_eq(bank(), 4500)                       -- charged once
        assert_eq(society(), 500)                     -- and the business paid for this invoice
        assert_eq(state('pfm-phone:invoice:9910:society:retry2'), 'completed')
        assert_eq(rowCount(9910), 0)
        assert_eq(token(9910), nil)
    end)
end)
