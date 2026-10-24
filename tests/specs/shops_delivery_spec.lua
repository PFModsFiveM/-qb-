-- pfm-shops deliveries on the ledger: each drop is paid once, and the payslip only covers drops the
-- server counted (it used to take the count from the client).
load_resource('tests/lua/ledger_env.lua')
Mock.exportsByResource['pfm-inventory'] = { AddItem = function() return true end }
function LoadResourceFile() return '{}' end
function SaveResourceFile() end
LedgerEnv.load('pfm-shops', { 'pfm-shops/config.lua', 'pfm-shops/server/main.lua' })

local D = 1
local function bank() return Mock.players[D].PlayerData.money.bank end
local function cash() return Mock.players[D].PlayerData.money.cash end
local function at(c) Mock.coords[D] = vector3(c.x, c.y, c.z) end
local SHOP
for name, loc in pairs(Config.Locations) do if loc.delivery then SHOP = name break end end
Config.Locations[SHOP].useStock = false -- stock restocking is not under test here

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.gameTimer = Mock.gameTimer + 120000
    Mock.players, Mock.coords = {}, {}
    local p = Mock.newPlayer(D)
    p.PlayerData.money = { cash = 1000, bank = 0 }
    p.AddRep = function() end
    DeliveryRounds = {}
end

describe('shop deliveries', function()
    it('a payslip with no counted drops pays nothing, whatever the client claims', function()
        at(Config.DeliveryLocations['main'].coords)
        Mock.fireNet('qb-shops:server:PaySlip', D, 20)
        assert_eq(bank(), 0)
    end)
    it('a drop pays once, and the payslip covers only counted drops', function()
        at(Config.Locations[SHOP].delivery)
        Mock.fireNet('qb-shops:server:RestockShopItems', D, SHOP)
        assert_eq(bank(), Config.DeliveryPrice)
        at(Config.DeliveryLocations['main'].coords)
        Mock.fireNet('qb-shops:server:PaySlip', D, 20)                -- claims 20, did 1
        assert_eq(bank(), Config.DeliveryPrice * 2)
        Mock.gameTimer = Mock.gameTimer + 120000
        Mock.fireNet('qb-shops:server:PaySlip', D, 20)                -- round already paid
        assert_eq(bank(), Config.DeliveryPrice * 2)
        assert_eq(#LedgerEnv.paid('pfm-shops:'), 2)
    end)
    it('the truck deposit is charged and refunded once through the ledger', function()
        Mock.fireNet('qb-shops:server:DoBail', D, true)
        assert_eq(cash(), 1000 - Config.TruckDeposit)
        Mock.gameTimer = Mock.gameTimer + 120000
        Mock.fireNet('qb-shops:server:DoBail', D, false)
        assert_eq(cash(), 1000)
        Mock.gameTimer = Mock.gameTimer + 120000
        Mock.fireNet('qb-shops:server:DoBail', D, false)
        assert_eq(cash(), 1000)
    end)
end)
