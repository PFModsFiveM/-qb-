-- pfm-phone invoice ledger tokens on a real database: the column and its UUID() default are added
-- once to a table created before them (older rows keep NULL and their id keys), every invoice gets
-- a unique token (also one another resource inserts directly), and paying moves money exactly once
-- on the real ledger: a reused id is charged, a pending or debited attempt is waited for, failed
-- attempts move to the next key without a cap, and a crash before the delete is finished safely.
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
        assert_eq(#alters, 2)
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
    it('a pending attempt is waited for; once recovery fails it the next key charges once', function()
        local id = create(250)
        local base = 'pfm-phone:invoice:tok:' .. token(id)
        -- the attempt was stored, then the server stopped before the debit
        MySQL.insert.await([[INSERT INTO pf_transactions (tx_id, idempotency_key, kind, from_account, to_account, amount, state)
            VALUES ('txcrash1', ?, 'purchase', 'player:CID1:bank', 'system:pfm-phone', 250, 'pending')]], { base .. ':bank' })
        local ok, err = phone.PayInvoice(A, id)
        assert_eq(err, 'in_progress')
        assert_eq(bank(), 5000)
        recover()
        assert_eq(state(base .. ':bank'), 'failed')
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
