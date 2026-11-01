-- pfm-fuel on the real database: a car with no shared fuel level gets its first one from
-- player_vehicles.fuel by the plate the server sees (trimmed, as the table keeps it); a plate with
-- no row, or a row with no level, gets Config.DefaultFuel. The driver's report is never the level.
-- A row named by the spawner (UseStoredFuel) is used whatever plate the car shows.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
RealDB.exec('pfm-garages/player_vehicles.sql')

local states = {}
local stateMeta = { __index = { set = function(self, k, v) rawset(self, k, v) end } }
function Entity(e)
    states[e] = states[e] or { state = setmetatable({}, stateMeta) }
    return states[e]
end
function GetEntityType(e) return (e >= 500 and e < 600) and 2 or 1 end
function DoesEntityExist() return true end
PFPayout = { NewId = function() return '1' end, Charge = function() return false end }
function CreateThread(fn) fn() end

Config = nil
load_resource('pfm-fuel/Config.lua')
load_resource('pfm-fuel/server/main.lua')
load_resource('pfm-fuel/server/pricing.lua')

local DRIVER = 1
local function fuel(veh) return Entity(veh).state['qb-fuel'] end
local function firstReport(veh, plate, reported)
    Mock.plates[veh] = plate
    Mock.vehicleOf[DRIVER] = veh
    Mock.gameTimer = Mock.gameTimer + 100000 -- a fresh report window
    Mock.fireNet('qb-fuel:server:syncFuel', DRIVER, veh, reported)
    return fuel(veh)
end

MySQL.insert.await("INSERT INTO player_vehicles (citizenid, vehicle, plate, fuel) VALUES ('CID1', 'sultan', 'OWN23', 23), ('CID2', 'adder', 'NOFUEL1', NULL)")
MySQL.insert.await("INSERT INTO player_vehicles (citizenid, vehicle, plate) VALUES ('CID3', 'blista', 'NEWCAR1')")

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.vehicleOf, Mock.plates = {}, {}, {}
    Mock.newPlayer(DRIVER)
    Config.SyncFuelBetweenPlayers = true
    Config.DefaultFuel = 100
end

describe('fix13b fuel: the first level from player_vehicles (real database)', function()
    it('an owned car starts at its stored level, found by the padded plate the game shows', function()
        assert_eq(firstReport(501, 'OWN23   ', 100), 23.0)
    end)

    it('a car bought new starts at the column default (a full tank)', function()
        assert_eq(firstReport(502, 'NEWCAR1', 5), 100.0)
    end)

    it('a plate with no row, or a row with no level: Config.DefaultFuel', function()
        Config.DefaultFuel = 80
        assert_eq(firstReport(503, 'TAXI4242', 100), 80.0, 'no row')
        assert_eq(firstReport(504, 'NOFUEL1', 100), 80.0, 'NULL level')
    end)

    it('a garage car named by its row starts at that row\'s level though its client shows another plate', function()
        Mock.plates[507] = 'ZZFAKE1'
        assert_eq(Mock.exportsByResource['__self'].UseStoredFuel(507, 'OWN23'), true)
        assert_eq(fuel(507), 23.0)
        assert_eq(Mock.exportsByResource['__self'].GetVehicleFuel(507, 'OWN23'), 23.0)
        assert_eq(firstReport(507, 'ZZFAKE1', 100), 23.0, 'the report changes nothing')
    end)

    it('a plate the database cannot hold (too long) or an empty one is not looked up', function()
        assert_eq(firstReport(505, 'WAYTOOLONGPLATE', 100), 100.0)
        assert_eq(firstReport(506, '        ', 100), 100.0)
    end)
end)
