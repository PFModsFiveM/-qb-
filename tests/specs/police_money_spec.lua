-- pfm-policejob fines, bills, cash seizure, evidence bags and robbery on the ledger.
load_resource('tests/lua/ledger_env.lua')
Commands = {}
QBCoreMock.Commands.Add = function(name, _, _, _, fn) Commands[name] = fn end
QBCore = QBCoreMock
QBCoreMock.Shared = QBCoreMock.Shared or {}
QBCoreMock.Shared.Items = QBCoreMock.Shared.Items or {}

local bags = {}           -- moneybags handed out: { src, info }
local inventoryFull = false
Mock.exportsByResource['pfm-inventory'] = {
    AddItem = function(_, src, name, amount, slot, info)
        if inventoryFull then return false end
        if name == 'moneybag' then bags[#bags + 1] = { src = src, info = info } end
        return true
    end,
    RemoveItem = function() return true end,
    OpenInventoryById = function() end,
}
FakeDB.extraPatterns = { { 'INSERT INTO phone_invoices', function() return 1 end } }

LedgerEnv.load('pfm-policejob', { 'pfm-policejob/config.lua', 'pfm-policejob/server/main.lua', 'pfm-policejob/server/commands.lua', 'pfm-policejob/server/interactions.lua' })

local COP, SUSPECT, ROBBER = 1, 2, 3
local function money(src) return Mock.players[src].PlayerData.money end
local function police() return FakeDB.bank_accounts.police.account_balance end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players, Mock.coords = {}, {}
    bags, inventoryFull = {}, false
    FakeDB.society('police', 0)
    local cop = Mock.newPlayer(COP)
    cop.PlayerData.job = { name = 'police', type = 'leo', onduty = true }
    cop.GetItemByName = function() return { name = 'moneybag' } end
    Mock.newPlayer(SUSPECT).PlayerData.money = { cash = 300, bank = 1000 }
    Mock.newPlayer(ROBBER).PlayerData.money = { cash = 0, bank = 0 }
end

describe('/fine', function()
    it('takes the fine once and credits the department', function()
        Commands.fine(COP, { tostring(SUSPECT), '400' })
        assert_eq(money(SUSPECT).bank, 600)
        assert_eq(police(), 400)
    end)
    it('falls back to cash, then to an invoice', function()
        Mock.players[SUSPECT].PlayerData.money = { cash = 500, bank = 10 }
        Commands.fine(COP, { tostring(SUSPECT), '400' })
        assert_eq(money(SUSPECT).cash, 100)
        Commands.fine(COP, { tostring(SUSPECT), '400' })   -- cannot pay: invoice, nothing taken
        assert_eq(money(SUSPECT).cash, 100)
        assert_eq(police(), 400)
    end)
    it('refuses missing, oversized and off-duty fines', function()
        Commands.fine(COP, { tostring(SUSPECT) })
        Commands.fine(COP, { tostring(SUSPECT), tostring(Config.MaxFine + 1) })
        Mock.players[COP].PlayerData.job.onduty = false
        Commands.fine(COP, { tostring(SUSPECT), '100' })
        assert_eq(money(SUSPECT).bank, 1000)
        assert_eq(police(), 0)
    end)
end)

describe('the bill menu', function()
    it('credits the police only when the bill was paid', function()
        Mock.players[SUSPECT].PlayerData.money.bank = 50
        Mock.fireNet('police:server:BillPlayer', COP, SUSPECT, 500)
        assert_eq(police(), 0)
        assert_eq(money(SUSPECT).bank, 50)
        Mock.fireNet('police:server:BillPlayer', COP, SUSPECT, 40)
        assert_eq(police(), 40)
        assert_eq(money(SUSPECT).bank, 10)
    end)
end)

describe('seized cash', function()
    it('goes into an evidence bag that pays out once', function()
        Mock.fireNet('police:server:SeizeCash', COP, SUSPECT)
        assert_eq(money(SUSPECT).cash, 0)
        assert_eq(#bags, 1)
        local bag = bags[1].info
        Mock.useables['moneybag'](COP, { info = bag, slot = 1 })
        Mock.useables['moneybag'](COP, { info = bag, slot = 2 }) -- a duplicated bag
        assert_eq(money(COP).cash, 300)
    end)
    it('is given back when the officer cannot carry the bag', function()
        inventoryFull = true
        Mock.fireNet('police:server:SeizeCash', COP, SUSPECT)
        assert_eq(money(SUSPECT).cash, 300)
    end)
    it('nothing to seize makes no bag', function()
        Mock.players[SUSPECT].PlayerData.money.cash = 0
        Mock.fireNet('police:server:SeizeCash', COP, SUSPECT)
        assert_eq(#bags, 0)
    end)
end)

describe('robbing a cuffed player', function()
    it('moves the cash once, from the victim to the robber', function()
        Mock.players[SUSPECT].PlayerData.metadata.ishandcuffed = true
        Mock.fireNet('police:server:RobPlayer', ROBBER, SUSPECT)
        Mock.fireNet('police:server:RobPlayer', ROBBER, SUSPECT)
        assert_eq(money(ROBBER).cash, 300)
        assert_eq(money(SUSPECT).cash, 0)
    end)
end)
