-- pfm-scrapyard: owned cars can't be scrapped, and the server removes the scrapped car.
load_resource('tests/lua/fivem_mocks.lua')
Inv = {}
Mock.exportsByResource['pfm-inventory'] = { AddItem = function(_, src, item, n) Inv[item] = (Inv[item] or 0) + (n or 1) return true end }
setmetatable(QBCoreMock.Shared.Items, { __index = function(_, k) return { name = k, label = k } end })
local owned = {}
MySQL.scalar = { await = function(_, params) return owned[params[1]] end }
load_resource('pfm-scrapyard/config.lua')
load_resource('pfm-scrapyard/server.lua')

local W, CAR = 1, 700
local function loot() local n = 0 for _, k in pairs(Inv) do n = n + k end return n end

BeforeEach = function()
    Mock.reset()
    Mock.gameTimer = Mock.gameTimer + 60000
    Mock.players, Mock.coords, Inv, Mock.deleted, owned = {}, {}, {}, {}, {}
    Mock.newPlayer(W)
    Mock.coords[W] = Config.Locations[1].deliver.coords
    Config.CurrentVehicles = { [1] = Config.Vehicles[1] }
    Mock.models[CAR] = GetHashKey(Config.Vehicles[1])
    Mock.vehicleOf[W] = CAR
    Mock.plates[CAR] = ' ABC123 '
end

describe('scrapyard', function()
    it('an owned car is refused and stays', function()
        owned['ABC123'] = 'ABC123'
        Mock.fireNet('qb-scrapyard:server:ScrapVehicle', W, 1)
        assert_eq(loot(), 0)
        assert_eq(#Mock.deleted, 0)
        assert_true(Config.CurrentVehicles[1] ~= nil)
    end)
    it('a street car is scrapped once and removed by the server', function()
        Mock.fireNet('qb-scrapyard:server:ScrapVehicle', W, 1)
        assert_true(loot() > 0)
        assert_eq(Mock.deleted[1], CAR)
        local got = loot()
        Mock.gameTimer = Mock.gameTimer + 60000
        Mock.fireNet('qb-scrapyard:server:ScrapVehicle', W, 1)
        assert_eq(loot(), got)
    end)
end)
