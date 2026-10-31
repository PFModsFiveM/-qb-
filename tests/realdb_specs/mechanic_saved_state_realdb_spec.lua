-- pf-mechanicjob saved car state on a real database (server/garage_sync.lua). The migration adds the
-- NOS columns to vehicle_diagnostics (on a table from the old SQL import, or creating it), rerun-safe.
-- A save writes the car's server state through the real upsert, not the props a client sends; NOS
-- goes through those columns and never through player_vehicles.mods; and a call with no car
-- spawned leaves vehicle_diagnostics alone.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
QBCore = QBCoreMock
function GetResourceState() return 'started' end

local states = {}
local stateMeta = { __index = { set = function(self, k, v) rawset(self, k, v) end } }
function Entity(e)
    states[e] = states[e] or { state = setmetatable({}, stateMeta) }
    return states[e]
end
local existing = {}
function DoesEntityExist(e) return existing[e] == true end
function GetAllVehicles() local out = {} for e in pairs(existing) do out[#out + 1] = e end return out end

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-garages/player_vehicles.sql')
-- an existing install: vehicle_diagnostics made by the SQL auto-import, without the NOS columns
RealDB.exec('[pfscripts]/pf-mechanicjob/pf_mechanic.sql')
load_resource('pfm-core/server/migrations.lua')
Config = nil
load_resource('[pfscripts]/pf-mechanicjob/config.lua')
load_resource('[pfscripts]/pf-mechanicjob/shared/debug.lua')
Config.Debug = false
load_resource('[pfscripts]/pf-mechanicjob/server/garage_sync.lua')
assert(PFMech.GarageSyncSchema(), 'garage sync migration')

local OWNER = 1
local CAR, NEXT_CAR, LAST_CAR = 500, 600, 700
local HERE = vector3(100.0, 100.0, 30.0)
local forged = { plate = 'OWNED1', partDamage = { brakes = 0, oil = 0 }, mileage = 0,
    nos = { has = true, level = 100, color = '#00FF00' }, modEngine = 4, engineHealth = 950 }

local function row() return MySQL.single.await('SELECT * FROM vehicle_diagnostics WHERE plate = ?', { 'OWNED1' }) end
local function mods() return json.decode(MySQL.scalar.await('SELECT mods FROM player_vehicles WHERE plate = ?', { 'OWNED1' })) end
local function column(name)
    return tonumber(MySQL.scalar.await([[SELECT COUNT(*) FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'vehicle_diagnostics' AND COLUMN_NAME = ?]], { name }))
end
local function spawn(veh, coords)
    existing[veh] = true
    Mock.plates[veh] = 'OWNED1  '
    Mock.models[veh] = GetHashKey('sultan')
    Mock.coords[veh] = coords or HERE
end
local function gone(veh)
    existing[veh] = nil
    Mock.fireEvent('entityRemoved', nil, veh)
    if Mock.vehicleOf[OWNER] == veh then Mock.vehicleOf[OWNER] = nil end
end

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 1000
    for veh in pairs(existing) do gone(veh) end
    Mock.players, Mock.coords, Mock.vehicleOf, Mock.plates, Mock.models = {}, {}, {}, {}, {}
    states = {}
    Mock.newPlayer(OWNER, 'CID1')
    Mock.coords[OWNER] = HERE
    MySQL.query.await('DELETE FROM player_vehicles')
    MySQL.query.await('DELETE FROM vehicle_diagnostics')
    MySQL.insert.await("INSERT INTO player_vehicles (citizenid, vehicle, hash, mods, plate, state) VALUES ('CID1', 'sultan', '0', '{}', 'OWNED1', 0)")
    MySQL.insert.await("INSERT INTO vehicle_diagnostics (plate, citizenid, brakes, oil, mileage) VALUES ('OWNED1', 'CID1', 50, 20, 4000)")
end

describe('vehicle_diagnostics NOS columns', function()
    it('are added to the existing table, and the migration can run again', function()
        for _, c in ipairs({ 'nos_has', 'nos_level', 'nos_color' }) do assert_eq(column(c), 1, c) end
        assert_true(PFMech.GarageSyncSchema())
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = 'pf-mechanicjob:garage_sync'")), 1)
    end)
    it('create the table when the SQL import never ran, and rerunning the step is safe', function()
        MySQL.query.await('DROP TABLE vehicle_diagnostics')
        MySQL.query.await("DELETE FROM pf_schema_migrations WHERE resource = 'pf-mechanicjob:garage_sync'")
        assert_true(PFMech.GarageSyncSchema())
        assert_eq(column('nos_level'), 1)
        assert_eq(column('brakes'), 1)
        MySQL.query.await("DELETE FROM pf_schema_migrations WHERE resource = 'pf-mechanicjob:garage_sync'")
        assert_true(PFMech.GarageSyncSchema(), 'the steps themselves rerun')
        MySQL.insert.await("INSERT INTO vehicle_diagnostics (plate, citizenid, brakes, oil, mileage) VALUES ('OWNED1', 'CID1', 50, 20, 4000)")
    end)
end)

describe('saving and taking out a car on the real database', function()
    it("a forged save stores the car's server state; NOS comes back from the columns, never from mods", function()
        spawn(CAR)
        Mock.vehicleOf[OWNER] = CAR
        Entity(CAR).state.partDamage = { brakes = 60, oil = 40 }
        Entity(CAR).state.mileage = 5000
        Entity(CAR).state.nos = { has = true, level = 30, color = '#FF0000' }
        Mock.fireNet('pf_mech:saveFullDiagnostics', OWNER, 'OWNED1', forged, CAR)
        local r = row()
        assert_eq(tonumber(r.brakes), 60)
        assert_eq(tonumber(r.oil), 40)
        assert_eq(tonumber(r.mileage), 5000)
        assert_eq(tonumber(r.nos_has), 1)
        assert_eq(tonumber(r.nos_level), 30)
        assert_eq(r.nos_color, '#FF0000')
        assert_eq(tonumber(r.engineHealth), 950)
        local m = mods()
        assert_eq(m.modEngine, 4)
        assert_eq(m.nos, nil)
        assert_eq(m.partDamage, nil)
        assert_eq(m.mileage, nil)

        -- stored; the owner's client writes a full bottle into mods; taken out again
        gone(CAR)
        MySQL.update.await([[UPDATE player_vehicles SET mods = '{"nos":{"has":true,"level":100}}' WHERE plate = 'OWNED1']])
        spawn(NEXT_CAR, vector3(103.0, 100.0, 30.0))
        Mock.fireNet('qb-garages:server:updateVehicleState', OWNER, 0, 'OWNED1')
        local s = Entity(NEXT_CAR).state
        assert_eq(s.partDamage.brakes, 60)
        assert_eq(s.mileage, 5000)
        assert_eq(s.nos.level, 30, 'the level the server saved, not the full bottle in mods')

        -- the bottle runs dry and the car is stored from the driver seat
        s.nos = { has = false, level = 0, color = '#FF0000' }
        s.partDamage.brakes = 62
        Mock.vehicleOf[OWNER] = NEXT_CAR
        Mock.fireNet('qb-garages:server:updateVehicleStats', OWNER, 'OWNED1', 100, 900, 1000)
        assert_eq(tonumber(row().nos_has), 0)
        assert_eq(tonumber(row().brakes), 62)
        gone(NEXT_CAR)
        spawn(LAST_CAR)
        Mock.fireNet('pf_mech:server:restoreVehicleState', OWNER, LAST_CAR)
        assert_eq(Entity(LAST_CAR).state.nos, nil)
        assert_eq(Entity(LAST_CAR).state.partDamage.brakes, 62)
    end)

    it('a save with no car spawned leaves vehicle_diagnostics alone', function()
        Mock.fireNet('pf_mech:saveFullDiagnostics', OWNER, 'OWNED1', forged)
        Mock.fireNet('pf_mech:sync:forceSave', OWNER, 'OWNED1', CAR)
        Mock.fireNet('qb-garages:server:updateVehicleStats', OWNER, 'OWNED1', 100, 1000, 1000)
        local r = row()
        assert_eq(tonumber(r.brakes), 50)
        assert_eq(tonumber(r.mileage), 4000)
        assert_eq(tonumber(r.nos_has), 0)
        assert_eq(mods().modEngine, 4, 'the props are kept')
        assert_eq(mods().nos, nil)
    end)

    it('the first save of a car with no row inserts one under its owner', function()
        MySQL.query.await('DELETE FROM vehicle_diagnostics')
        spawn(CAR)
        Mock.vehicleOf[OWNER] = CAR
        Entity(CAR).state.partDamage = { brakes = 5 }
        Entity(CAR).state.mileage = 12.5
        Mock.fireNet('pf_mech:sync:cacheVehicleState', OWNER, { plate = 'OWNED1', netId = CAR, props = forged })
        local r = row()
        assert_eq(r.citizenid, 'CID1')
        assert_eq(tonumber(r.brakes), 5)
        assert_eq(tonumber(r.mileage), 12.5)
        assert_eq(tonumber(r.nos_has), 0)
    end)
end)
