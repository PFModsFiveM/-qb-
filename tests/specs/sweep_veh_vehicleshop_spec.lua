-- pfm-vehicleshop: a bought car is spawned once, at the shop; test drives spawn at the shop; finance
-- play time is counted for the sender's own character; showroom swaps and test-drive offers are checked.
load_resource('tests/lua/ledger_env.lua')
QBCoreMock.Commands.Add = function() end
QBCoreMock.Functions.GetIdentifier = function(src) return 'license:' .. tostring(src) end
QBCoreMock.Shared = QBCoreMock.Shared or {}
QBCoreMock.Shared.Vehicles = {
    blista = { name = 'Blista', price = 10000, shop = 'pdm', category = 'compacts' },
    cognoscenti = { name = 'Cognoscenti', price = 100000, shop = 'luxury', category = 'sedans' },
}

local spawned = {}
function CreateVehicleServerSetter(hash, _, x, y, z) spawned[#spawned + 1] = { hash = hash, x = x, y = y, z = z }; return 500 + #spawned end
function SetVehicleNumberPlateText() end

local vehicles = {}
local financeUpdates = {}
FakeDB.extraPatterns = {
    { 'SELECT plate FROM player_vehicles WHERE plate = ?', function(p) return vehicles[p[1]] and p[1] or nil end },
    { 'INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, garage, state)', function(p)
        vehicles[p[6]] = { citizenid = p[2], vehicle = p[3], plate = p[6], balance = 0, mods = '{}' }
        return 1
    end },
    { 'SELECT mods, vehicle FROM player_vehicles WHERE plate = ? AND citizenid = ?', function(p)
        local v = vehicles[p[1]]
        return (v and v.citizenid == p[2]) and { v } or {}
    end },
    { 'SELECT * FROM player_vehicles WHERE citizenid = ?', function(p)
        local out = {}
        for _, v in pairs(vehicles) do if v.citizenid == p[1] then out[#out + 1] = v end end
        return out
    end },
    { 'UPDATE player_vehicles SET financetime = ? WHERE plate = ?', function(p) financeUpdates[#financeUpdates + 1] = p; return 1 end },
}

LedgerEnv.load('pfm-vehicleshop', { 'pfm-vehicleshop/config.lua', 'pfm-vehicleshop/server.lua' })

local BUYER, DEALER, STRANGER = 1, 2, 3
local PDM = Config.Shops.pdm.Location
local FAR = vector3(3000, 3000, 30)

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.clock = Mock.clock + 1000
    Mock.players, Mock.coords = {}, {}
    vehicles, spawned, financeUpdates = {}, {}, {}
    for _, src in ipairs({ BUYER, DEALER, STRANGER }) do
        local p = Mock.newPlayer(src)
        p.PlayerData.money = { cash = 0, bank = 200000 }
        p.PlayerData.license = 'license:' .. src
        Mock.coords[src] = vector3(PDM.x, PDM.y, PDM.z)
    end
    Mock.players[DEALER].PlayerData.job = { name = 'cardealer', onduty = true }
end

local function buy()
    Mock.fireNet('qb-vehicleshop:server:buyShowroomVehicle', BUYER, { buyVehicle = 'blista' })
    local ev = Mock.clientEventsNamed('qb-vehicleshop:client:buyShowroomVehicle')
    return ev[#ev].args[2]
end

describe('spawning a bought car', function()
    it('spawns once, at the shop, whatever coords the client sends', function()
        local plate = buy()
        local netId = Mock.callCallback('qb-vehicleshop:server:spawnvehicle', BUYER, plate, 'blista', vector4(0, 0, 0, 0))
        assert_true(netId ~= nil)
        assert_eq(#spawned, 1)
        assert_eq(spawned[1].x, Config.Shops.pdm.VehicleSpawn.x)
        assert_eq(Mock.callCallback('qb-vehicleshop:server:spawnvehicle', BUYER, plate, 'blista', vector4(0, 0, 0, 0)), nil)
        assert_eq(#spawned, 1)
    end)
    it('an owned car that was not just bought is not spawned', function()
        vehicles.OLDCAR1 = { citizenid = 'CID' .. BUYER, vehicle = 'blista', plate = 'OLDCAR1', mods = '{}' }
        assert_eq(Mock.callCallback('qb-vehicleshop:server:spawnvehicle', BUYER, 'OLDCAR1', 'blista', vector4(0, 0, 0, 0)), nil)
        assert_eq(#spawned, 0)
    end)
    it('a test drive spawns at the shop, not from across the map, with a cooldown', function()
        Mock.coords[STRANGER] = FAR
        assert_eq(Mock.callCallback('qb-vehicleshop:server:spawnvehicle', STRANGER, 'TESTDRIVE', 'blista', vector4(0, 0, 0, 0)), nil)
        local netId = Mock.callCallback('qb-vehicleshop:server:spawnvehicle', BUYER, 'TESTDRIVE', 'blista', vector4(0, 0, 0, 0))
        assert_true(netId ~= nil)
        assert_eq(spawned[1].x, Config.Shops.pdm.TestDriveSpawn.x)
        assert_eq(Mock.callCallback('qb-vehicleshop:server:spawnvehicle', BUYER, 'TESTDRIVE', 'blista', vector4(0, 0, 0, 0)), nil)
    end)
end)

describe('finance play time', function()
    it("another player's finance timer cannot be run down", function()
        vehicles.FIN1 = { citizenid = 'CID' .. STRANGER, vehicle = 'blista', plate = 'FIN1', balance = 5000, financetime = 600 }
        Mock.fireNet('qb-vehicleshop:server:addPlayer', BUYER, 'CID' .. STRANGER)
        Mock.clock = Mock.clock + 6000
        Mock.fireNet('qb-vehicleshop:server:removePlayer', BUYER, 'CID' .. STRANGER)
        assert_eq(#financeUpdates, 0)
    end)
end)

describe('showroom and test-drive offers', function()
    it('only a car the shop sells, by someone in the shop', function()
        Mock.fireNet('qb-vehicleshop:server:swapVehicle', BUYER, { toVehicle = 'cognoscenti', ClosestVehicle = 1, ClosestShop = 'pdm' })
        Mock.coords[STRANGER] = FAR
        Mock.fireNet('qb-vehicleshop:server:swapVehicle', STRANGER, { toVehicle = 'blista', ClosestVehicle = 1, ClosestShop = 'pdm' })
        assert_eq(#Mock.clientEventsNamed('qb-vehicleshop:client:swapVehicle'), 0)
        Mock.fireNet('qb-vehicleshop:server:swapVehicle', BUYER, { toVehicle = 'blista', ClosestVehicle = 1, ClosestShop = 'pdm' })
        assert_eq(#Mock.clientEventsNamed('qb-vehicleshop:client:swapVehicle'), 1)
    end)
    it('a test drive is offered by a dealer at work only', function()
        local LUX = Config.Shops.luxury.Location
        Mock.fireNet('qb-vehicleshop:server:customTestDrive', STRANGER, 'cognoscenti', BUYER)
        assert_eq(#Mock.clientEventsNamed('qb-vehicleshop:client:customTestDrive'), 0)
        Mock.coords[DEALER] = vector3(LUX.x, LUX.y, LUX.z)
        Mock.coords[BUYER] = vector3(LUX.x, LUX.y, LUX.z)
        Mock.fireNet('qb-vehicleshop:server:customTestDrive', DEALER, 'cognoscenti', BUYER)
        assert_eq(#Mock.clientEventsNamed('qb-vehicleshop:client:customTestDrive'), 1)
    end)
end)
