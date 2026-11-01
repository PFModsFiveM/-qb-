-- pf-mechanicjob saved car state (server/garage_sync.lua). Wear, mileage and NOS are state bags only
-- the server writes. They are saved from the server's own state of the car the sender is in or
-- beside, never from the props a client sends, and a spawned car gets back only what the server
-- saved (NOS from vehicle_diagnostics, never from player_vehicles.mods, which the owner's client
-- writes). With no car spawned nothing is written to vehicle_diagnostics.
load_resource('tests/lua/fivem_mocks.lua')
QBCore = QBCoreMock

local states = {}
local stateMeta = { __index = { set = function(self, k, v) rawset(self, k, v) end } }
function Entity(e)
    states[e] = states[e] or { state = setmetatable({}, stateMeta) }
    return states[e]
end
local existing, allVehicles = {}, {}
function DoesEntityExist(e) return existing[e] == true end
function GetAllVehicles() return allVehicles end

-- a small database: player_vehicles and vehicle_diagnostics rows by plate
local db
local function resetDb()
    db = { veh = {}, diag = {}, diagWrites = 0, nosWrites = 0, modsWrites = 0 }
end
resetDb()
MySQL.single = { await = function(q, p)
    if q:find('FROM vehicle_diagnostics', 1, true) then return db.diag[p[1]] end
    if q:find('FROM player_vehicles', 1, true) then return db.veh[p[1]] end
end }
MySQL.insert = { await = function(q, p)
    if q:find('INSERT INTO vehicle_diagnostics', 1, true) then
        -- an upsert: the columns it names replace those of the row (ON DUPLICATE KEY UPDATE)
        local row, i, named = db.diag[p[1]] or {}, 0, {}
        for col in q:match('%((.-)%)%s*VALUES'):gmatch('[^,%s`]+') do
            i = i + 1
            row[col] = p[i]
            named[col] = true
        end
        db.diag[p[1]] = row
        if named.brakes then db.diagWrites = db.diagWrites + 1 end   -- wear, mileage and health
        if named.nos_has then db.nosWrites = db.nosWrites + 1 end    -- the NOS columns
        return 1
    end
end }
MySQL.update = { await = function(q, p)
    if q:find('UPDATE player_vehicles SET mods', 1, true) and db.veh[p[2]] then
        db.veh[p[2]].mods = p[1]
        db.modsWrites = db.modsWrites + 1
        return 1
    end
    return 0
end }

Config = nil
load_resource('[pfscripts]/pf-mechanicjob/config.lua')
load_resource('[pfscripts]/pf-mechanicjob/shared/debug.lua')
Config.Debug = false
Config.NOS = Config.NOS or {}
Config.NOS.capacity = 100
load_resource('[pfscripts]/pf-mechanicjob/server/garage_sync.lua')
-- the NOS columns are added by a migration (real database: mechanic_saved_state_realdb_spec)
function RunMigrations() return true end
if PFMech.GarageSyncSchema then PFMech.GarageSyncSchema() end

local OWNER, FRIEND, STRANGER = 1, 2, 3
local CAR, OTHER_CAR, NEW_CAR, FAKE_CAR = 500, 501, 600, 700
local HERE = vector3(200.0, 200.0, 30.0)
local forged = { plate = 'OWNED1', partDamage = { brakes = 0, oil = 0, engine_part = 0 }, mileage = 0,
    nos = { has = true, level = 100, color = '#00FF00' }, modEngine = 4, engineHealth = 950 }

local function st(veh) return Entity(veh).state end
local function mods() return json.decode(db.veh.OWNED1.mods or 'null') end
local function stored() return db.diag.OWNED1 end
local function car(veh, plate, model, coords)
    existing[veh] = true
    allVehicles[#allVehicles + 1] = veh
    Mock.plates[veh] = plate
    Mock.models[veh] = GetHashKey(model)
    Mock.coords[veh] = coords or HERE
end

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 1000
    for _, veh in ipairs(allVehicles) do Mock.fireEvent('entityRemoved', nil, veh) end
    Mock.players, Mock.coords, Mock.vehicleOf, Mock.plates, Mock.models = {}, {}, {}, {}, {}
    states, existing, allVehicles = {}, {}, {}
    resetDb()
    Mock.newPlayer(OWNER, 'CID1')
    Mock.newPlayer(FRIEND, 'CID2')
    Mock.newPlayer(STRANGER, 'CID3')
    Mock.coords[OWNER], Mock.coords[FRIEND], Mock.coords[STRANGER] = HERE, HERE, vector3(900.0, 900.0, 30.0)
    db.veh.OWNED1 = { citizenid = 'CID1', vehicle = 'sultan', mods = '{}' }
    db.veh.OTHER1 = { citizenid = 'CID2', vehicle = 'futo', mods = '{}' }
    -- what the server saved when the car was last stored
    db.diag.OWNED1 = { plate = 'OWNED1', citizenid = 'CID1', brakes = 50, oil = 20, mileage = 4000, nos_has = 0, nos_level = 0 }
    car(CAR, ' OWNED1 ', 'sultan')
    car(OTHER_CAR, 'OTHER1', 'futo')
    -- the car's live state on the server (wear only goes up while it is out)
    st(CAR).partDamage = { brakes = 60, oil = 40 }
    st(CAR).mileage = 5000
    st(CAR).nos = { has = true, level = 30, color = '#FF0000' }
end

describe('saving a car', function()
    it("the owner's save from inside the car stores the car's server state, not the props", function()
        Mock.vehicleOf[OWNER] = CAR
        Mock.fireNet('pf_mech:saveFullDiagnostics', OWNER, 'OWNED1', forged, CAR)
        local row = stored()
        assert_eq(row.brakes, 60)
        assert_eq(row.oil, 40)
        assert_eq(row.engine_part, 0)
        assert_eq(row.mileage, 5000)
        assert_eq(tonumber(row.nos_has), 1)
        assert_eq(row.nos_level, 30)
        assert_eq(row.nos_color, '#FF0000')
        assert_eq(row.engineHealth, 950, 'health still comes from the car props')
        local m = mods()
        assert_eq(m.modEngine, 4)
        assert_eq(m.partDamage, nil, 'wear is not kept in mods')
        assert_eq(m.mileage, nil)
        assert_eq(m.nos, nil, 'NOS is not kept in mods')
    end)

    it('a call with no car spawned, or from far from it, never touches vehicle_diagnostics', function()
        Mock.coords[OWNER] = vector3(260.0, 200.0, 30.0)                                -- 60 m from the car
        Mock.fireNet('pf_mech:saveFullDiagnostics', OWNER, 'OWNED1', forged)
        Mock.fireNet('pf_mech:saveFullDiagnostics', OWNER, 'OWNED1', forged, CAR)
        Mock.fireNet('pf_mech:sync:cacheVehicleState', OWNER, { plate = 'OWNED1', netId = CAR, props = forged })
        existing[CAR] = nil                                                              -- stored / deleted
        Mock.coords[OWNER] = HERE
        Mock.fireNet('pf_mech:saveFullDiagnostics', OWNER, 'OWNED1', forged, CAR)
        Mock.fireNet('pf_mech:sync:forceSave', OWNER, 'OWNED1', CAR)
        Mock.fireNet('qb-garages:server:updateVehicleStats', OWNER, 'OWNED1', 100, 1000, 1000)
        assert_eq(db.diagWrites, 0)
        assert_eq(db.nosWrites, 0)
        assert_eq(stored().brakes, 50, 'the saved wear is untouched')
        assert_eq(mods().nos, nil, 'the props are still kept, without NOS')
        assert_eq(mods().modEngine, 4)
    end)

    it('from beside the car only with its net id, and only when that car has the plate', function()
        Mock.coords[OWNER] = vector3(203.0, 200.0, 30.0)
        Mock.fireNet('pf_mech:saveFullDiagnostics', OWNER, 'OWNED1', forged, OTHER_CAR)  -- another plate
        assert_eq(db.diagWrites, 0)
        Mock.fireNet('pf_mech:saveFullDiagnostics', OWNER, 'OWNED1', forged, 'x')
        Mock.fireNet('pf_mech:saveFullDiagnostics', OWNER, 'OWNED1', forged, -5)
        assert_eq(db.diagWrites, 0)
        Mock.fireNet('pf_mech:saveFullDiagnostics', OWNER, 'OWNED1', forged, CAR)
        assert_eq(db.diagWrites, 1)
        assert_eq(stored().brakes, 60)
    end)

    it('the driving sync and the garage store save the server state of the car', function()
        Mock.vehicleOf[FRIEND] = CAR                                -- a friend drives the owner's car
        Mock.fireNet('pf_mech:sync:cacheVehicleState', FRIEND, { plate = 'OWNED1', netId = CAR, props = forged })
        assert_eq(stored().brakes, 60, 'the sync saves the server state')
        assert_eq(stored().citizenid, 'CID1', 'under the owner')
        assert_eq(db.nosWrites, 0, 'the driving sync leaves NOS to the NOS handlers')
        assert_eq(tonumber(stored().nos_has), 0)
        st(CAR).partDamage.brakes = 75
        st(CAR).nos = { has = false, level = 0 }
        Mock.fireNet('qb-garages:server:updateVehicleStats', FRIEND, 'OWNED1', 100, 900, 800)
        local row = stored()
        assert_eq(row.brakes, 75)
        assert_eq(row.mileage, 5000)
        assert_eq(tonumber(row.nos_has), 0)
        assert_eq(db.nosWrites, 1, 'the store saves NOS through the NOS writer')
        assert_eq(row.engineHealth, 900)
        assert_eq(row.bodyHealth, 800)
        assert_eq(mods().modEngine, 4)
        assert_eq(mods().partDamage, nil)
    end)

    it('the driving sync saves at most every 30 s; the store always saves', function()
        Mock.vehicleOf[OWNER] = CAR
        Mock.fireNet('pf_mech:sync:cacheVehicleState', OWNER, { plate = 'OWNED1', netId = CAR, props = forged })
        Mock.fireNet('pf_mech:sync:cacheVehicleState', OWNER, { plate = 'OWNED1', netId = CAR, props = forged })
        assert_eq(db.diagWrites, 1)
        Mock.clock = Mock.clock + 31
        Mock.fireNet('pf_mech:sync:cacheVehicleState', OWNER, { plate = 'OWNED1', netId = CAR, props = forged })
        assert_eq(db.diagWrites, 2)
        Mock.fireNet('pf_mech:sync:forceSave', OWNER, 'OWNED1', CAR)
        assert_eq(db.diagWrites, 3)
    end)

    it('a stranger far away, or in another car, saves nothing', function()
        Mock.fireNet('pf_mech:saveFullDiagnostics', STRANGER, 'OWNED1', forged, CAR)
        Mock.fireNet('pf_mech:sync:cacheVehicleState', STRANGER, { plate = 'OWNED1', netId = CAR, props = forged })
        Mock.vehicleOf[STRANGER] = OTHER_CAR
        Mock.fireNet('pf_mech:sync:forceSave', STRANGER, 'OWNED1', CAR)
        Mock.fireNet('qb-garages:server:updateVehicleStats', STRANGER, 'OWNED1', 100, 1000, 1000)
        assert_eq(db.diagWrites, 0)
        assert_eq(db.nosWrites, 0)
        assert_eq(db.modsWrites, 0)
    end)
end)

describe('a car taken out again', function()
    local function restore(src, veh) Mock.fireNet('pf_mech:server:restoreVehicleState', src, veh) end

    it('a forged save cannot hand the next spawn free NOS, new parts or a lower odometer', function()
        -- the owner, far from the car, sends a forged save; mods also carries a forged bottle
        Mock.coords[OWNER] = vector3(900.0, 0.0, 30.0)
        Mock.fireNet('pf_mech:saveFullDiagnostics', OWNER, 'OWNED1', forged)
        db.veh.OWNED1.mods = '{"nos":{"has":true,"level":100}}'
        -- the car is taken out: a new entity with the plate
        car(NEW_CAR, 'OWNED1', 'sultan', vector3(900.0, 2.0, 30.0))
        restore(OWNER, NEW_CAR)
        local s = st(NEW_CAR)
        assert_eq(s.partDamage.brakes, 50, 'the wear the server saved')
        assert_eq(s.partDamage.oil, 20)
        assert_eq(s.mileage, 4000)
        assert_eq(s.nos, nil, 'no NOS from mods')
    end)

    it('NOS comes back only from what the server saved, capped at the bottle', function()
        db.diag.OWNED1.nos_has, db.diag.OWNED1.nos_level, db.diag.OWNED1.nos_color = 1, 250, '#00FF00'
        car(NEW_CAR, 'OWNED1', 'sultan')
        restore(OWNER, NEW_CAR)
        assert_eq(st(NEW_CAR).nos.has, true)
        assert_eq(st(NEW_CAR).nos.level, 100)
        assert_eq(st(NEW_CAR).nos.color, '#00FF00')
    end)

    it('the garage take-out loads the saved state straight away', function()
        existing[CAR] = nil
        car(NEW_CAR, 'OWNED1', 'sultan', vector3(205.0, 200.0, 30.0))
        Mock.fireNet('qb-garages:server:updateVehicleState', OWNER, 0, 'OWNED1')
        assert_eq(st(NEW_CAR).partDamage.brakes, 50)
        assert_eq(st(NEW_CAR).mileage, 4000)
    end)

    it('a car that never got its saved state is given it before a save, so the stored wear is kept', function()
        car(NEW_CAR, 'OWNED1', 'sultan')
        existing[CAR] = nil
        st(NEW_CAR).partDamage = { brakes = 1, oil = 30 }           -- a minute of driving from zero
        st(NEW_CAR).mileage = 0.4
        Mock.vehicleOf[OWNER] = NEW_CAR
        Mock.fireNet('qb-garages:server:updateVehicleStats', OWNER, 'OWNED1', 100, 1000, 1000)
        assert_eq(stored().brakes, 50, 'not rolled back to the fresh spawn')
        assert_eq(stored().oil, 30, 'wear added since is kept')
        assert_eq(stored().mileage, 4000)
    end)

    it('a car of another model with the plate gets nothing and cannot save over it', function()
        car(FAKE_CAR, 'OWNED1', 'adder')
        existing[CAR] = nil
        restore(OWNER, FAKE_CAR)
        assert_eq(st(FAKE_CAR).mileage, nil)
        st(FAKE_CAR).partDamage = { brakes = 100 }
        Mock.vehicleOf[STRANGER] = FAKE_CAR
        Mock.coords[FAKE_CAR] = Mock.coords[STRANGER]
        Mock.fireNet('qb-garages:server:updateVehicleStats', STRANGER, 'OWNED1', 100, 1000, 1000)
        assert_eq(db.diagWrites, 0)
        assert_eq(db.nosWrites, 0)
        assert_eq(stored().brakes, 50)
    end)

    it('only one live car carries a plate: a copy gets nothing until the first is gone', function()
        restore(OWNER, CAR)
        car(NEW_CAR, 'OWNED1', 'sultan')
        db.diag.OWNED1.nos_has, db.diag.OWNED1.nos_level = 1, 100
        restore(OWNER, NEW_CAR)
        assert_eq(st(NEW_CAR).nos, nil)
        assert_eq(st(NEW_CAR).mileage, nil)
        Mock.fireEvent('entityRemoved', nil, CAR)
        existing[CAR] = nil
        restore(OWNER, NEW_CAR)
        assert_eq(st(NEW_CAR).nos.level, 100)
    end)
end)

describe('a car keeps the plate it was loaded as', function()
    it('changing the plate text does not carry its bottle or wear into another car\'s record', function()
        db.veh.OWNED2 = { citizenid = 'CID1', vehicle = 'sultan', mods = '{}' }
        db.diag.OWNED2 = { plate = 'OWNED2', citizenid = 'CID1', brakes = 5, oil = 5, mileage = 10, nos_has = 0, nos_level = 0 }
        Mock.vehicleOf[OWNER] = CAR
        Mock.fireNet('pf_mech:server:restoreVehicleState', OWNER, CAR)       -- the car is OWNED1, with its bottle
        assert_true(st(CAR).nos.has)
        Mock.plates[CAR] = 'OWNED2'                                           -- plate text changed on the client
        Mock.fireNet('pf_mech:saveFullDiagnostics', OWNER, 'OWNED2', { plate = 'OWNED2' }, CAR)
        Mock.fireNet('qb-garages:server:updateVehicleStats', OWNER, 'OWNED2', 100, 1000, 1000)
        assert_eq(tonumber(db.diag.OWNED2.nos_has), 0, "OWNED1's bottle does not move to OWNED2")
        assert_eq(db.diag.OWNED2.brakes, 5, "OWNED2's saved wear is untouched")
    end)
end)
