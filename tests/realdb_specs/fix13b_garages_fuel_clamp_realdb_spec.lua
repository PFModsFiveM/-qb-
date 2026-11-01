-- pfm-garages 'qb-garages:server:updateVehicleStats' on the real database: with pfm-fuel syncing
-- and no car whose server level was given for this plate, the client's fuel can only lower the
-- stored level (UPDATE ... SET fuel = LEAST(COALESCE(fuel, ?), ?)); a car with a server level is
-- saved up to it; pfm-fuel stopped or not syncing saves the client's level. Only the owner's row.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
local fuelState, synced = 'started', true
local states = { ['pf-government'] = 'missing', ['pf-services'] = 'missing', ['pfm-banking'] = 'missing' }
function GetResourceState(name) if name == 'pfm-fuel' then return fuelState end return states[name] or 'missing' end
vec3 = vec3 or vector3
vec4 = vec4 or vector4
RealDB.exec('pfm-garages/player_vehicles.sql')

local levels, levelFor = {}, {}
Mock.exportsByResource['pfm-fuel'] = {
    IsFuelSynced = function() return synced end,
    GetVehicleFuel = function(_, veh, plate)
        if plate ~= nil and levelFor[veh] ~= plate then return nil end
        return levels[veh]
    end,
}
Mock.exportsByResource['pf-devices'] = { RegisterApp = function() return true end, RegisterAppHandlers = function() return true end, Push = function() return true end }
function GetCurrentResourceName() return 'pfm-garages' end
Config = nil
load_resource('pfm-banking/payouts.lua')
load_resource('pfm-garages/config.lua')
load_resource('pfm-garages/server/main.lua')

local world, plateOf = {}, {}
function GetAllVehicles() return world end
function GetVehicleNumberPlateText(veh) return plateOf[veh] end
function DoesEntityExist(e) return plateOf[e] ~= nil end

local P = 1
local function park(plate, fuel) Mock.fireNet('qb-garages:server:updateVehicleStats', P, plate, fuel, 900, 800) end
local function row(plate) return MySQL.single.await('SELECT fuel, engine, body FROM player_vehicles WHERE plate = ?', { plate }) end

MySQL.insert.await([[INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, garage, state, fuel)
    VALUES ('l', 'CID1', 'sultan', '1', '{}', 'RDB12', 'motelgarage', 1, 12),
           ('l', 'CID1', 'sultan', '1', '{}', 'RDBNULL', 'motelgarage', 1, NULL),
           ('l', 'CID2', 'sultan', '1', '{}', 'RDBOTHER', 'motelgarage', 1, 30)]])

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    Mock.newPlayer(P, 'CID1')
    fuelState, synced = 'started', true
    world, plateOf, levels, levelFor = {}, {}, {}, {}
end

describe('fix13b garages: the fuel saved when parking (real database)', function()
    it('no car with a level for this plate: a higher client level leaves the stored one, a lower one is saved', function()
        park('RDB12', 100)
        local r = row('RDB12')
        assert_eq(tonumber(r.fuel), 12)
        assert_eq(tonumber(r.engine), 900, 'the rest is saved')
        park('RDB12', 7.8)
        assert_eq(tonumber(row('RDB12').fuel), 7)
    end)

    it('nothing stored (NULL): the client\'s level', function()
        park('RDBNULL', 64)
        assert_eq(tonumber(row('RDBNULL').fuel), 64)
    end)

    it('a car in the world whose level was given for this plate: saved up to it', function()
        world, plateOf[950] = { 950 }, 'RDB12'
        levels[950], levelFor[950] = 55.5, 'RDB12'
        park('RDB12', 100)
        assert_eq(tonumber(row('RDB12').fuel), 55)
    end)

    it('pfm-fuel not syncing or stopped: the client\'s level, as before', function()
        synced = false
        park('RDB12', 90)
        assert_eq(tonumber(row('RDB12').fuel), 90)
        fuelState = 'stopped'
        park('RDB12', 91)
        assert_eq(tonumber(row('RDB12').fuel), 91)
    end)

    it('another citizen\'s row is never written', function()
        park('RDBOTHER', 1)
        assert_eq(tonumber(row('RDBOTHER').fuel), 30)
    end)
end)
