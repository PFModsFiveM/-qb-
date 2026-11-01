-- pfm-phone invoice ledger keys come from a per-invoice token, not from the invoice id: an invoice
-- under a reused id (truncated table, MySQL < 8.0 AUTO_INCREMENT reset) is charged, rows from before
-- the token keep their id key, and every new invoice gets its own token (the column is added once).
load_resource('tests/lua/ledger_env.lua')

local invoices = {}       -- [id] = row
local inserts = {}        -- params of every INSERT INTO phone_invoices
local hasColumn = true    -- phone_invoices.ledger_token exists
local alters = 0
local nextId = 1

FakeDB.extraPatterns = {
    { 'INSERT INTO player_mails', function() return 1 end },
    { 'information_schema.COLUMNS', function(p)
        return hasColumn and 1 or 0
    end },
    { 'ALTER TABLE `phone_invoices` ADD COLUMN `ledger_token`', function()
        if hasColumn then error("Duplicate column name 'ledger_token'") end
        alters = alters + 1
        hasColumn = true
        return {}
    end },
    { 'INSERT INTO phone_invoices', function(p, q)
        inserts[#inserts + 1] = p
        local id = nextId
        nextId = nextId + 1
        invoices[id] = { id = id, citizenid = p[1], amount = p[2], society = p[3], sender = p[4], sendercitizenid = p[5],
            candecline = p[6], reason = p[7], ledger_token = p[8] }
        return id
    end },
    { 'SELECT * FROM phone_invoices WHERE id = ? AND citizenid = ?', function(p)
        local row = invoices[tonumber(p[1])]
        return (row and row.citizenid == p[2]) and { row } or {}
    end },
    { 'DELETE FROM phone_invoices WHERE id = ? AND citizenid = ?', function(p)
        local row = invoices[tonumber(p[1])]
        if row and row.citizenid == p[2] then invoices[tonumber(p[1])] = nil return { affectedRows = 1 } end
        return { affectedRows = 0 }
    end },
}

local FILES = { 'pfm-phone/config.lua', 'pfm-phone/server/main.lua' }

-- the /bill command, captured while the resource loads (the shared mock drops commands)
local commands = {}
local function load()
    local add = QBCoreMock.Commands.Add
    QBCoreMock.Commands.Add = function(name, _, _, _, fn) commands[name] = fn end
    local ok, err = pcall(LedgerEnv.load, 'pfm-phone', FILES)
    QBCoreMock.Commands.Add = add
    assert(ok, err)
    Mock.exportsByResource['pfm-phone'] = { sendNewMailToOffline = function() end }
    Config.BillingCommissions = {}
end
load()

local A, BILLER = 1, 2
local function bank() return Mock.players[A].PlayerData.money.bank end
local function pay(id) return Mock.selfExport('PayInvoice')(A, id) end
local function police() return FakeDB.bank_accounts['police'].account_balance end
local function create(amount)
    return Mock.selfExport('CreateInvoice')({ citizenid = 'CID1', amount = amount or 500, society = 'police', sender = 'Officer', sendercitizenid = 'CID2' })
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    hasColumn, alters, nextId = true, 0, 1
    invoices, inserts = {}, {}
    load()
    Mock.clock = Mock.clock + 1000
    Mock.players = {}
    local p = Mock.newPlayer(A)
    p.PlayerData.money = { cash = 0, bank = 2000 }
    local b = Mock.newPlayer(BILLER)
    b.PlayerData.job = { name = 'police' }
    FakeDB.society('police', 0)
end

describe('a reused invoice id', function()
    it('rows with different tokens under one id are each charged', function()
        invoices[7] = { id = 7, citizenid = 'CID1', amount = 500, society = 'police', sendercitizenid = '', candecline = 1, ledger_token = '1700000000-1-111111' }
        assert_eq(pay(7), true)
        assert_eq(bank(), 1500)
        invoices[7] = { id = 7, citizenid = 'CID1', amount = 500, society = 'police', sendercitizenid = '', candecline = 1, ledger_token = '1800000000-1-222222' }
        assert_eq(pay(7), true)
        assert_eq(bank(), 1000)               -- the new invoice under id 7 is not free
        assert_eq(police(), 1000)
    end)
    it('a malformed token falls back to the id key', function()
        invoices[8] = { id = 8, citizenid = 'CID1', amount = 100, society = 'police', sendercitizenid = '', candecline = 1, ledger_token = 'bad token:with:colons' }
        assert_eq(pay(8), true)
        assert_true(FakeDB.byKey['pfm-phone:invoice:8:bank'].state == 'completed')
    end)
    it('is charged again: the new invoice does not find the old invoice paid', function()
        local id = create()
        assert_eq(id, 1)
        assert_eq(pay(id), true)
        assert_eq(bank(), 1500)
        assert_eq(police(), 500)
        -- the table is truncated (or AUTO_INCREMENT resets): the next invoice gets id 1 again
        nextId = 1
        assert_eq(create(), 1)
        assert_eq(pay(1), true)
        assert_eq(bank(), 1000)               -- charged for the new invoice
        assert_eq(police(), 1000)             -- and the business is paid for it
        assert_eq(invoices[1], nil)
    end)
    it('the society credit of the new invoice is not taken for the old one either', function()
        assert_eq(pay(create()), true)
        nextId = 1
        local id = create()
        local token = invoices[id].ledger_token
        assert_eq(pay(id), true)
        assert_true(FakeDB.byKey['pfm-phone:invoice:tok:' .. token .. ':bank'].state == 'completed')
        assert_true(FakeDB.byKey['pfm-phone:invoice:tok:' .. token .. ':society'].state == 'completed')
    end)
end)

describe('an invoice from before the token', function()
    it('keeps its id key, so a charge it already made still counts as paid', function()
        -- charged before the change (crash between charge and delete), stored without a token
        local res = PFLedger.Transfer({ from = 'player:CID1:bank', to = 'system:pfm-phone', amount = 500, key = 'pfm-phone:invoice:42:bank', kind = 'purchase' })
        assert_eq(res.ok, true)
        assert_eq(bank(), 1500)
        invoices[42] = { id = 42, citizenid = 'CID1', amount = 500, society = 'police', sendercitizenid = '', candecline = 1 }
        assert_eq(pay(42), true)
        assert_eq(bank(), 1500)               -- not charged a second time
        assert_eq(police(), 500)
        assert_eq(invoices[42], nil)
    end)
    it('without a charge yet is charged on its id key', function()
        invoices[43] = { id = 43, citizenid = 'CID1', amount = 300, society = 'police', sendercitizenid = '', candecline = 1 }
        assert_eq(pay(43), true)
        assert_eq(bank(), 1700)
        assert_true(FakeDB.byKey['pfm-phone:invoice:43:bank'].state == 'completed')
    end)
end)

describe('creating invoices', function()
    it('stores a distinct ledger token with every invoice', function()
        create()
        create()
        assert_eq(#inserts, 2)
        local t1, t2 = inserts[1][8], inserts[2][8]
        assert_true(type(t1) == 'string' and t1 ~= '' and #t1 <= 40)
        assert_true(type(t2) == 'string' and t2 ~= '' and #t2 <= 40)
        assert_true(t1 ~= t2)
    end)
    it('the /bill command stores a token too', function()
        assert_true(commands.bill ~= nil)
        commands.bill(BILLER, { tostring(A), '250' })
        assert_eq(#inserts, 1)
        assert_true(type(inserts[1][8]) == 'string' and inserts[1][8] ~= '')
        assert_eq(invoices[1].amount, 250)
        assert_eq(invoices[1].society, 'police')
    end)
    it('refuses a bad amount', function()
        assert_eq(create(0), nil)
        assert_eq(create(0.5), nil)
        assert_eq(create(-5), nil)
        assert_eq(#inserts, 0)
    end)
end)

describe('the ledger_token column', function()
    it('is added once when missing, and not touched when present', function()
        hasColumn = false
        load()
        create()
        assert_eq(alters, 1)
        assert_true(type(inserts[1][8]) == 'string')
        create()
        assert_eq(alters, 1)
        load() -- a restart finds the column and leaves it
        create()
        assert_eq(alters, 1)
    end)
    it('when it cannot be added, invoices are still created (id keys, as before)', function()
        hasColumn = false
        FakeDB.extraPatterns[3] = { 'ALTER TABLE `phone_invoices` ADD COLUMN `ledger_token`', function() error('ALTER command denied') end }
        load()
        local id = create()
        assert_true(id ~= nil)
        assert_eq(inserts[1][8], nil)
        assert_eq(pay(id), true)
        assert_true(FakeDB.byKey['pfm-phone:invoice:' .. id .. ':bank'].state == 'completed')
        FakeDB.extraPatterns[3] = { 'ALTER TABLE `phone_invoices` ADD COLUMN `ledger_token`', function()
            if hasColumn then error("Duplicate column name 'ledger_token'") end
            alters = alters + 1
            hasColumn = true
            return {}
        end }
    end)
end)
