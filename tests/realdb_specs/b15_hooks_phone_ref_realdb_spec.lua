-- Batch 15H platform hooks, pfm-phone on a real database: CreateInvoice takes the caller's
-- idempotency reference data.ref (pf-justice 'pf-justice:order:<id>', pf-ambulancejob
-- 'pf-ambulancejob:bill:<id>'). The ref column and its unique index are added by the file's own
-- EnsureInvoiceColumns check to a table from before them (once; a restart adds nothing) and come with
-- qb-phone.sql on a fresh install. A second call with the same ref returns the first invoice's id and
-- 'duplicate' (also when another call inserts it in between: the unique index decides), the same ref
-- for another citizen, society or amount is 'key_reused', and pfm-phone:server:invoiceSettled
-- carries the ref back. Without the column a ref'd invoice is refused; plain invoices are unchanged.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
function GetResourceState() return 'started' end

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')

-- a fresh install: qb-phone.sql alone creates the column and the unique index
RealDB.exec('pfm-phone/qb-phone.sql')
local function refColumn()
    return MySQL.single.await([[SELECT IS_NULLABLE AS nullable, CHARACTER_MAXIMUM_LENGTH AS len FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'phone_invoices' AND COLUMN_NAME = 'ref']])
end
local function refIndexUnique()
    return tonumber(MySQL.scalar.await([[SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = DATABASE()
        AND TABLE_NAME = 'phone_invoices' AND INDEX_NAME = 'uq_phone_invoices_ref' AND NON_UNIQUE = 0]])) or 0
end
local FRESH_COLUMN, FRESH_INDEX = refColumn(), refIndexUnique()

-- then phone_invoices as servers have it before 15H (token and pay state, no ref), with rows in it
MySQL.query.await('DROP TABLE phone_invoices')
MySQL.query.await([[CREATE TABLE `phone_invoices` (`id` int(10) NOT NULL AUTO_INCREMENT, `citizenid` varchar(50) DEFAULT NULL,
    `amount` int(11) NOT NULL DEFAULT 0, `society` tinytext DEFAULT NULL, `sender` varchar(50) DEFAULT NULL,
    `sendercitizenid` varchar(50) DEFAULT NULL, `candecline` int(1) not null default 1, `reason` varchar(256) default null,
    `ledger_token` varchar(40) default (uuid()), `pay_state` varchar(16) default null,
    PRIMARY KEY (`id`), KEY `citizenid` (`citizenid`)) ENGINE=InnoDB AUTO_INCREMENT=1 DEFAULT CHARSET=utf8mb4]])
MySQL.insert.await("INSERT INTO phone_invoices (id, citizenid, amount, society, sender) VALUES (700, 'CID1', 50, 'police', 'Old')")
MySQL.insert.await("INSERT INTO phone_invoices (id, citizenid, amount, society, sender) VALUES (701, 'CID1', 60, 'police', 'Old')")

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
for _, soc in ipairs({ 'police', 'doj' }) do
    MySQL.query.await("INSERT INTO bank_accounts (account_name, account_balance, account_type, users) VALUES (?, 0, 'job', '[]') ON DUPLICATE KEY UPDATE account_balance = 0", { soc })
    MySQL.query.await('INSERT IGNORE INTO pf_ledger_baselines (account, balance) VALUES (?, 0)', { 'society:' .. soc })
end

-- the ref steps pfm-phone runs (a restart must run none)
local refSteps = {}
local failRefSteps = false
local query = MySQL.query
MySQL.query = setmetatable({ await = function(q, p)
    if type(q) == 'string' and (q:find('ADD COLUMN ref', 1, true) or q:find('uq_phone_invoices_ref ON', 1, true)) then
        refSteps[#refSteps + 1] = q
        if failRefSteps then error('ALTER command denied') end
    end
    return query.await(q, p)
end }, { __call = function(_, ...) return query(...) end })

local phone
local function startPhone()
    function GetCurrentResourceName() return 'pfm-phone' end
    Config = nil
    local add = QBCoreMock.Commands.Add
    QBCoreMock.Commands.Add = function() end
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
local function invoice(ref, overrides)
    local data = { citizenid = 'CID1', amount = 250, society = 'doj', sender = 'Court Clerk', candecline = 0, reason = 'Fine #12', ref = ref }
    for k, v in pairs(overrides or {}) do data[k] = v end
    return phone.CreateInvoice(data)
end
local function rows(ref) return tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM phone_invoices WHERE ref = ?', { ref })) or 0 end
local function total() return tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM phone_invoices')) or 0 end
local function settled(outcome)
    local out = {}
    for _, e in ipairs(Mock.serverEvents) do
        if e.name == 'pfm-phone:server:invoiceSettled' and (outcome == nil or e.args[2] == outcome) then out[#out + 1] = e.args[1] end
    end
    return out
end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    Mock.gameTimer = Mock.gameTimer + 120000
    local p = Mock.newPlayer(A, 'CID1')
    p.PlayerData.money = { cash = 0, bank = 5000 }
    failRefSteps = false
end

describe('the ref column and its unique index', function()
    it('come with qb-phone.sql on a fresh install', function()
        assert_true(FRESH_COLUMN ~= nil)
        assert_eq(FRESH_COLUMN.nullable, 'YES')
        assert_eq(tonumber(FRESH_COLUMN.len), 128)
        assert_eq(FRESH_INDEX, 1)
    end)
    it('are added once to a table from before them; the rows there keep NULL; a restart adds nothing', function()
        local id = invoice('pf-justice:order:1')
        assert_true(id ~= nil)
        local col = refColumn()
        assert_eq(col.nullable, 'YES')
        assert_eq(tonumber(col.len), 128)
        assert_eq(refIndexUnique(), 1)
        assert_eq(#refSteps, 2, 'ADD COLUMN and CREATE UNIQUE INDEX')
        assert_eq(MySQL.scalar.await('SELECT ref FROM phone_invoices WHERE id = 700'), nil)
        assert_eq(MySQL.scalar.await('SELECT ref FROM phone_invoices WHERE id = 701'), nil, 'NULLs never collide')
        refSteps = {}
        startPhone()
        assert_true(invoice('pf-justice:order:2') ~= nil)
        assert_eq(#refSteps, 0)
    end)
end)

describe('CreateInvoice with a ref', function()
    it('a duplicate ref returns the first id and duplicate; one row only', function()
        local id, err = invoice('pf-justice:order:10')
        assert_true(type(id) == 'number')
        assert_eq(err, nil)
        local again, why = invoice('pf-justice:order:10')
        assert_eq(again, id)
        assert_eq(why, 'duplicate')
        assert_eq(rows('pf-justice:order:10'), 1)
        assert_eq(MySQL.scalar.await('SELECT ref FROM phone_invoices WHERE id = ?', { id }), 'pf-justice:order:10')
    end)
    it('the same ref for another citizen, society or amount is key_reused and creates nothing', function()
        local id = invoice('pf-ambulancejob:bill:5')
        local before = total()
        for _, o in ipairs({ { amount = 251 }, { citizenid = 'CID9' }, { society = 'police' } }) do
            local again, why = invoice('pf-ambulancejob:bill:5', o)
            assert_eq(again, nil)
            assert_eq(why, 'key_reused')
        end
        assert_eq(total(), before)
        assert_eq(select(1, invoice('pf-ambulancejob:bill:5')), id)
    end)
    it('a ref inserted by another call in between (the race) is answered from the database', function()
        local realInsert = MySQL.insert
        local raced = false
        MySQL.insert = setmetatable({ await = function(q, p)
            if not raced and type(q) == 'string' and q:find('INSERT INTO phone_invoices', 1, true) then
                raced = true
                realInsert.await("INSERT INTO phone_invoices (citizenid, amount, society, sender, candecline, ref) VALUES ('CID1', 250, 'doj', 'Court Clerk', 0, 'pf-justice:order:20')")
            end
            return realInsert.await(q, p)
        end }, { __call = function(_, ...) return realInsert(...) end })
        local id, why = invoice('pf-justice:order:20')
        MySQL.insert = realInsert
        assert_true(raced)
        assert_eq(why, 'duplicate')
        assert_eq(id, tonumber(MySQL.scalar.await("SELECT id FROM phone_invoices WHERE ref = 'pf-justice:order:20'")))
        assert_eq(rows('pf-justice:order:20'), 1)
    end)
    it('refuses a malformed ref and creates nothing', function()
        local before = total()
        for _, bad in ipairs({ '', string.rep('a', 129), 'has space', "quote'd", 'semi;colon', 12, true, {} }) do
            local id, why = invoice(bad)
            assert_eq(id, nil, tostring(bad))
            assert_eq(why, 'bad_request')
        end
        assert_eq(total(), before)
        assert_true(invoice(string.rep('a', 128)) ~= nil, '128 characters are fine')
    end)
    it('invoices without a ref work as before, any number of them', function()
        local a = phone.CreateInvoice({ citizenid = 'CID1', amount = 75, society = 'police', sender = 'Officer', sendercitizenid = 'CID2' })
        local b = phone.CreateInvoice({ citizenid = 'CID1', amount = 75, society = 'police', sender = 'Officer', sendercitizenid = 'CID2' })
        assert_true(a ~= nil and b ~= nil and a ~= b)
        assert_eq(MySQL.scalar.await('SELECT ref FROM phone_invoices WHERE id = ?', { a }), nil)
        assert_true(type(MySQL.scalar.await('SELECT ledger_token FROM phone_invoices WHERE id = ?', { a })) == 'string')
    end)
end)

describe('settling an invoice with a ref', function()
    it('paid: invoiceSettled carries the ref, the money moved once; afterwards the ref is free again', function()
        local id = invoice('pf-justice:order:30', { amount = 300 })
        assert_eq(phone.PayInvoice(A, id), true)
        assert_eq(Mock.players[A].PlayerData.money.bank, 4700)
        local paid = settled('paid')
        assert_eq(#paid, 1)
        assert_eq(paid[1].ref, 'pf-justice:order:30')
        assert_eq(paid[1].id, id)
        assert_eq(paid[1].ledger_token, nil, 'bookkeeping stays inside')
        assert_eq(rows('pf-justice:order:30'), 0)
        -- the documented limit: a deleted (settled) invoice no longer holds its ref
        local again, why = invoice('pf-justice:order:30', { amount = 300 })
        assert_true(again ~= nil and again ~= id)
        assert_eq(why, nil)
    end)
    it('declined: invoiceSettled carries the ref', function()
        local id = invoice('pf-ambulancejob:bill:31', { candecline = 1, society = 'police' })
        assert_eq(phone.DeclineInvoice(A, id), true)
        local declined = settled('declined')
        assert_eq(#declined, 1)
        assert_eq(declined[1].ref, 'pf-ambulancejob:bill:31')
    end)
    it("the phone's invoice list does not send the ref to the client", function()
        invoice('pf-justice:order:32')
        local list = Mock.callCallback('qb-phone:server:GetInvoices', A)
        assert_true(type(list) == 'table' and #list > 0)
        for _, v in ipairs(list) do
            assert_eq(v.ref, nil)
            assert_eq(v.ledger_token, nil)
        end
    end)
end)

describe('without the column', function()
    it('an invoice asked for with a ref is refused (db_unavailable); a plain one still works', function()
        MySQL.query.await('DROP INDEX uq_phone_invoices_ref ON phone_invoices')
        MySQL.query.await('ALTER TABLE phone_invoices DROP COLUMN ref')
        failRefSteps = true
        startPhone()
        local before = total()
        local id, why = invoice('pf-justice:order:40')
        assert_eq(id, nil)
        assert_eq(why, 'db_unavailable')
        assert_eq(total(), before)
        assert_true(phone.CreateInvoice({ citizenid = 'CID1', amount = 10, society = 'police', sender = 'Officer' }) ~= nil)
        failRefSteps = false
    end)
end)
