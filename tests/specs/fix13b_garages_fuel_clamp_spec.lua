-- pfm-garages 'qb-garages:server:updateVehicleStats' (parking a car) saved whatever fuel level the
-- client sent, so a modded client could park any car with a full tank. Now it saves the client's
-- level only up to the level pfm-fuel keeps for that car on the server (GetVehicleFuel); with no
-- car, no server level or pfm-fuel stopped it keeps the client's, as before.
load_resource('tests/lua/ledger_env.lua')
QBCoreMock.Shared.Vehicles = { sultan = { name = 'Sultan', price = 1000, category = 'sports' } }

local cars = {}     -- player_vehicles: [plate] = row
local saved = {}    -- [plate] = { fuel, engine, body } from the stats update
FakeDB.extraPatterns = {
    { "AND TABLE_NAME = 'job_garage_vehicles'", function() return 1 end },
    { 'SELECT plate FROM job_garage_vehicles WHERE active = 1 AND plate IN', function() return {} end },
    { 'SELECT vehicle, mods, state, depotprice FROM player_vehicles WHERE plate = ? AND citizenid = ?', function(p)
        local c = cars[p[1]]
        return (c and c.citizenid == p[2]) and { c } or {}
    end },
    { 'UPDATE player_vehicles SET state = 0', function(p) if cars[p[1]] then cars[p[1]].state = 0 end return 1 end },
    { 'UPDATE player_vehicles SET fuel = ?, engine = ?, body = ? WHERE plate = ? AND citizenid = ?', function(p)
        if cars[p[4]] and cars[p[4]].citizenid == p[5] then saved[p[4]] = { fuel = p[1], engine = p[2], body = p[3] } end
        return 1
    end },
}
LedgerEnv.load('pfm-garages', { 'pfm-garages/config.lua', 'pfm-garages/server/main.lua' })

local existing, plateOf, nextEntity = {}, {}, 900
function CreateVehicleServerSetter() nextEntity = nextEntity + 1 existing[nextEntity] = true return nextEntity end
function SetVehicleNumberPlateText(veh, plate) plateOf[veh] = plate end
function DoesEntityExist(e) return existing[e] == true end
function GetVehicleNumberPlateText(veh) return plateOf[veh] end
local world = {} -- cars in the world that this resource did not spawn
function GetAllVehicles() return world end

-- pfm-fuel's server level per car (nil: none yet)
local fuelLevel, fuelState, fuelBroken = {}, 'started', false
Mock.exportsByResource['pfm-fuel'] = {
    GetVehicleFuel = function(_, veh)
        if fuelBroken then error('pfm-fuel export failed') end
        return fuelLevel[veh]
    end,
}
local otherState = GetResourceState
function GetResourceState(name) if name == 'pfm-fuel' then return fuelState end return otherState(name) end

local P = 1
local HERE = vector3(10, 10, 10)
local function takeOut(plate) return Mock.callCallback('qb-garages:server:spawnvehicle', P, plate, 'sultan', vector4(12, 10, 10, 0)) end
local function park(plate, fuel) Mock.fireNet('qb-garages:server:updateVehicleStats', P, plate, fuel, 900, 800) end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players, Mock.coords = {}, {}
    existing, plateOf, world, fuelLevel, saved = {}, {}, {}, {}, {}
    fuelState, fuelBroken = 'started', false
    Mock.newPlayer(P).PlayerData.money = { cash = 0, bank = 5000 }
    Mock.coords[P] = HERE
    cars = {
        OWN1 = { citizenid = 'CID1', vehicle = 'sultan', mods = '{}', state = 1, depotprice = 0 },
        OWN2 = { citizenid = 'CID1', vehicle = 'sultan', mods = '{}', state = 1, depotprice = 0 },
    }
end

describe('fix13b garages: the fuel saved when parking', function()
    it('a full tank from the client is cut to the server\'s level for that car', function()
        local netId = takeOut('OWN1')
        assert_true(netId ~= nil)
        fuelLevel[netId] = 37.6
        park('OWN1', 100)
        assert_eq(saved.OWN1.fuel, 37, 'never above the server\'s level')
        assert_eq(saved.OWN1.engine, 900, 'the rest is saved as before')
        assert_eq(saved.OWN1.body, 800)
    end)

    it('a client level below the server\'s is kept (the server lowers it no faster than driving burns)', function()
        local netId = takeOut('OWN1')
        fuelLevel[netId] = 60
        park('OWN1', 44.5)
        assert_eq(saved.OWN1.fuel, 44.5)
    end)

    it('a car with that plate this resource did not spawn is found in the world', function()
        world = { 950 }
        existing[950], plateOf[950], fuelLevel[950] = true, 'OWN2    ', 12
        park('OWN2', 90)
        assert_eq(saved.OWN2.fuel, 12)
    end)

    it('no car, no server level, pfm-fuel stopped or failing: the client\'s level, as before', function()
        park('OWN2', 70)
        assert_eq(saved.OWN2.fuel, 70, 'no car')
        local netId = takeOut('OWN1')
        park('OWN1', 80)
        assert_eq(saved.OWN1.fuel, 80, 'no server level yet')
        fuelLevel[netId] = 10
        fuelState = 'stopped'
        park('OWN1', 81)
        assert_eq(saved.OWN1.fuel, 81, 'pfm-fuel stopped')
        fuelState, fuelBroken = 'started', true
        park('OWN1', 82)
        assert_eq(saved.OWN1.fuel, 82, 'the export failing does not stop the save')
        fuelBroken = false
        park('OWN1', 'lots')
        assert_eq(saved.OWN1.fuel, 10, 'a bad client value (read as full) is cut too')
    end)
end)
