-- pfm-garages 'qb-garages:server:updateVehicleStats' (parking a car) saved whatever fuel level the
-- client sent, so a modded client could park any car with a full tank, and the next spawn starts
-- from what is stored. Now, with pfm-fuel syncing, it saves the client's level only up to the level
-- pfm-fuel keeps for that car, and only when that level was given for this plate
-- (GetVehicleFuel(veh, plate)). With no such car (deleted, never out, or a car showing another
-- car's plate) the client can only lower the stored level. pfm-fuel stopped or not syncing: the
-- client's level, as before. The spawn names the row to pfm-fuel (UseStoredFuel), so the car's
-- first level is the stored one whatever plate the owner's client later shows.
load_resource('tests/lua/ledger_env.lua')
QBCoreMock.Shared.Vehicles = { sultan = { name = 'Sultan', price = 1000, category = 'sports' } }

local cars = {}     -- player_vehicles: [plate] = row (row.fuel is the stored level)
local saved = {}    -- [plate] = { fuel, engine, body, sql } from the stats update
local function owns(p, plateAt, cidAt) return cars[p[plateAt]] and cars[p[plateAt]].citizenid == p[cidAt] end
FakeDB.extraPatterns = {
    { "AND TABLE_NAME = 'job_garage_vehicles'", function() return 1 end },
    { 'SELECT plate FROM job_garage_vehicles WHERE active = 1 AND plate IN', function() return {} end },
    { 'SELECT vehicle, mods, state, depotprice, garage FROM player_vehicles WHERE plate = ? AND citizenid = ?', function(p)
        local c = cars[p[1]]
        return (c and c.citizenid == p[2]) and { c } or {}
    end },
    { 'UPDATE player_vehicles SET state = 0, depotprice = 0 WHERE plate = ? AND citizenid = ? AND state = ? AND depotprice = ?', function(p)
        local c = cars[p[1]]
        if not c or c.citizenid ~= p[2] or c.state ~= p[3] or (c.depotprice or 0) ~= p[4] then return 0 end
        c.state = 0
        return 1
    end },
    { 'UPDATE player_vehicles SET fuel = ?, engine = ?, body = ? WHERE plate = ? AND citizenid = ?', function(p)
        if owns(p, 4, 5) then
            cars[p[4]].fuel = p[1]
            saved[p[4]] = { fuel = p[1], engine = p[2], body = p[3], sql = 'set' }
        end
        return 1
    end },
    -- LEAST(COALESCE(fuel, ?), ?): the client's level only when it is lower (or nothing is stored)
    { 'UPDATE player_vehicles SET fuel = LEAST(COALESCE(fuel, ?), ?), engine = ?, body = ? WHERE plate = ? AND citizenid = ?', function(p)
        if owns(p, 5, 6) then
            local c = cars[p[5]]
            local before = c.fuel == nil and p[1] or c.fuel
            c.fuel = math.min(before, p[2])
            saved[p[5]] = { fuel = c.fuel, engine = p[3], body = p[4], sql = 'least' }
        end
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

-- pfm-fuel: the server level per car (nil: none yet) and the plate it was given for
local fuelLevel, levelFor, named, fuelState, fuelBroken, synced = {}, {}, {}, 'started', false, true
Mock.exportsByResource['pfm-fuel'] = {
    IsFuelSynced = function()
        if fuelBroken then error('pfm-fuel export failed') end
        return synced
    end,
    GetVehicleFuel = function(_, veh, plate)
        if fuelBroken then error('pfm-fuel export failed') end
        if plate ~= nil and levelFor[veh] ~= plate then return nil end
        return fuelLevel[veh]
    end,
    UseStoredFuel = function(_, veh, plate)
        if fuelBroken then error('pfm-fuel export failed') end
        named[#named + 1] = { veh = veh, plate = plate }
        return true
    end,
}
local otherState = GetResourceState
function GetResourceState(name) if name == 'pfm-fuel' then return fuelState end return otherState(name) end

local P = 1
local MOTEL = Config.Garages.motelgarage.takeVehicle
local HERE = vector3(MOTEL.x, MOTEL.y, MOTEL.z)
local function takeOut(plate) return Mock.callCallback('qb-garages:server:spawnvehicle', P, plate, 'motelgarage', 1) end
local function park(plate, fuel) Mock.fireNet('qb-garages:server:updateVehicleStats', P, plate, fuel, 900, 800) end
--- pfm-fuel's level for `veh`, given for `plate`
local function level(veh, value, plate) fuelLevel[veh], levelFor[veh] = value, plate end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players, Mock.coords = {}, {}
    existing, plateOf, world, fuelLevel, levelFor, named, saved = {}, {}, {}, {}, {}, {}, {}
    fuelState, fuelBroken, synced = 'started', false, true
    Mock.newPlayer(P).PlayerData.money = { cash = 0, bank = 5000 }
    Mock.coords[P] = HERE
    cars = {
        OWN1 = { citizenid = 'CID1', vehicle = 'sultan', mods = '{}', state = 1, depotprice = 0, fuel = 12, garage = 'motelgarage' },
        OWN2 = { citizenid = 'CID1', vehicle = 'sultan', mods = '{}', state = 1, depotprice = 0, fuel = 40, garage = 'motelgarage' },
        OWN3 = { citizenid = 'CID1', vehicle = 'sultan', mods = '{}', state = 1, depotprice = 0, fuel = nil, garage = 'motelgarage' },
    }
end

describe('fix13b garages: the fuel saved when parking', function()
    it('a full tank from the client is cut to the server\'s level for that car', function()
        local netId = takeOut('OWN1')
        assert_true(netId ~= nil)
        level(netId, 37.6, 'OWN1')
        park('OWN1', 100)
        assert_eq(saved.OWN1.fuel, 37, 'never above the server\'s level')
        assert_eq(saved.OWN1.engine, 900, 'the rest is saved as before')
        assert_eq(saved.OWN1.body, 800)
    end)

    it('a client level below the server\'s is kept, as whole litres (the server lowers it no faster than driving burns)', function()
        local netId = takeOut('OWN1')
        level(netId, 60, 'OWN1')
        park('OWN1', 44.5)
        assert_eq(saved.OWN1.fuel, 44)
    end)

    it('a car with that plate this resource did not spawn is found in the world', function()
        world = { 950 }
        existing[950], plateOf[950] = true, 'OWN2    '
        level(950, 12, 'OWN2')
        park('OWN2', 90)
        assert_eq(saved.OWN2.fuel, 12)
    end)

    it('the event again once the car is gone cannot raise what was saved (it can only lower it)', function()
        local netId = takeOut('OWN1')
        level(netId, 12, 'OWN1')
        park('OWN1', 100)
        assert_eq(saved.OWN1.fuel, 12, 'the honest save, while the car exists')
        existing[netId] = nil -- the client deletes the car 1.5 s later
        park('OWN1', 100)
        assert_eq(cars.OWN1.fuel, 12, 'the resend changes nothing')
        assert_eq(saved.OWN1.sql, 'least')
        park('OWN1', 5)
        assert_eq(cars.OWN1.fuel, 5, 'a lower level is saved')
    end)

    it('a parked car with no car in the world: the client can only lower the stored level', function()
        park('OWN2', 70)
        assert_eq(cars.OWN2.fuel, 40)
        park('OWN2', 33.9)
        assert_eq(cars.OWN2.fuel, 33)
        park('OWN3', 70)
        assert_eq(cars.OWN3.fuel, 70, 'nothing stored: the client\'s level')
    end)

    it('a car showing this plate whose level was given for another plate does not answer for it', function()
        -- a modded client spawned a car (it got a full tank for its own plate) and showed OWN2 on it
        world = { 960 }
        existing[960], plateOf[960] = true, 'OWN2'
        level(960, 100, 'ZZFAKE1')
        park('OWN2', 100)
        assert_eq(cars.OWN2.fuel, 40, 'the stored level, not the impostor\'s full tank')
    end)

    it('a car with no server level yet: only lower', function()
        takeOut('OWN1')
        park('OWN1', 80)
        assert_eq(cars.OWN1.fuel, 12)
    end)

    it('pfm-fuel stopped or not syncing: the client\'s level, as before; pfm-fuel failing: only lower', function()
        local netId = takeOut('OWN1')
        level(netId, 10, 'OWN1')
        fuelState = 'stopped'
        park('OWN1', 81)
        assert_eq(cars.OWN1.fuel, 81, 'pfm-fuel stopped')
        fuelState, synced = 'started', false
        park('OWN1', 82)
        assert_eq(cars.OWN1.fuel, 82, 'fuel sync off: the client\'s level is all there is')
        synced, fuelBroken = true, true
        park('OWN1', 90)
        assert_eq(cars.OWN1.fuel, 82, 'the export failing does not stop the save, but cannot raise it')
        assert_eq(saved.OWN1.engine, 900)
        fuelBroken = false
        park('OWN1', 'lots')
        assert_eq(cars.OWN1.fuel, 10, 'a bad client value (read as full) is cut too')
        park('OWN1', 0 / 0)
        assert_eq(cars.OWN1.fuel, 10, 'and NaN')
    end)

    it('the spawn names the row to pfm-fuel (its first level is the stored one, whatever plate the client shows)', function()
        local netId = takeOut('OWN1')
        assert_eq(#named, 1)
        assert_eq(named[1].veh, netId)
        assert_eq(named[1].plate, 'OWN1')
        fuelState = 'stopped'
        cars.OWN2.state = 1
        assert_true(takeOut('OWN2') ~= nil, 'pfm-fuel stopped: the spawn works without it')
        assert_eq(#named, 1)
        fuelState, fuelBroken = 'started', true
        cars.OWN3.state = 1
        assert_true(takeOut('OWN3') ~= nil, 'pfm-fuel failing does not stop the spawn')
    end)
end)
