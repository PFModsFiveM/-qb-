-- pf-mechanicjob under sv_stateBagStrictMode: a replaced tyre and a car's saved wear, mileage and
-- NOS are set by the server only (server/consumables.lua 'pf_mech:server:tireReplaced',
-- server/garage_sync.lua 'pf_mech:server:restoreVehicleState'). The saved state is what the server
-- wrote to vehicle_diagnostics; NOS is never taken from player_vehicles.mods (the owner's client
-- writes that). Saving: mechanic_saved_state_spec.lua.
load_resource('tests/lua/fivem_mocks.lua')
QBCore = QBCoreMock

local states = {}
local stateMeta = { __index = { set = function(self, k, v) rawset(self, k, v) end } }
function Entity(e)
    states[e] = states[e] or { state = setmetatable({}, stateMeta) }
    return states[e]
end
local existing = {}
function DoesEntityExist(e) return existing[e] == true end

Config = { NOS = { capacity = 100, defaultColor = '#55CCFF' } }
local rows = {}
MySQL.single = { await = function(q, p)
    if q:find('FROM vehicle_diagnostics', 1, true) then return rows.diag[p[1]] end
    if q:find('FROM player_vehicles', 1, true) then return rows.veh[p[1]] end
end }
load_resource('[pfscripts]/pf-mechanicjob/server/consumables.lua')
load_resource('[pfscripts]/pf-mechanicjob/server/garage_sync.lua')

local MECH, VEH = 1, 900
local function give(p, name, n)
    p.inv = p.inv or {}
    p.inv[name] = (p.inv[name] or 0) + n
    p.Functions.GetItemByName = function(item) if (p.inv[item] or 0) > 0 then return { name = item, amount = p.inv[item] } end end
    p.Functions.RemoveItem = function(item, k) if (p.inv[item] or 0) < (k or 1) then return false end p.inv[item] = p.inv[item] - (k or 1) return true end
end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords, Mock.vehicleOf, Mock.plates = {}, {}, {}, {}
    states, existing = {}, { [VEH] = true }
    Mock.clock = 1700000000
    local p = Mock.newPlayer(MECH, 'MECH1')
    give(p, 'tire_new', 2)
    Mock.coords[MECH] = vector3(0.0, 0.0, 0.0)
    Mock.coords[VEH] = vector3(2.0, 0.0, 0.0)
    Mock.plates[VEH] = ' AB12CD '
    Mock.models = { [VEH] = GetHashKey('sultan') }
    rows = { diag = {}, veh = {} }
    Mock.fireEvent('entityRemoved', nil, VEH)       -- each test starts with a car not loaded yet
end

describe('a replaced tyre', function()
    it('is marked new only after a tyre was really taken, the bar ran, and the car is beside the mechanic', function()
        Mock.fireNet('pf_mech:server:tireReplaced', MECH, VEH, 0)
        assert_eq(Entity(VEH).state.partDamage, nil, 'no tyre taken: nothing')
        local ok = Mock.callCallback('pf-mechanicjob:server:consumeItem', MECH, 'tire_new')
        assert_true(ok)
        Mock.clock = Mock.clock + 1
        Mock.fireNet('pf_mech:server:tireReplaced', MECH, VEH, 0)
        assert_eq(Entity(VEH).state.partDamage, nil, 'too soon')
        Mock.clock = Mock.clock + 4
        Mock.coords[VEH] = vector3(20.0, 0.0, 0.0)
        Mock.fireNet('pf_mech:server:tireReplaced', MECH, VEH, 0)
        assert_eq(Entity(VEH).state.partDamage, nil, 'too far')
        Mock.coords[VEH] = vector3(2.0, 0.0, 0.0)
        Mock.fireNet('pf_mech:server:tireReplaced', MECH, VEH, 9)
        assert_eq(Entity(VEH).state.partDamage, nil, 'no such wheel')
        Entity(VEH).state:set('partDamage', { brakes = 40, tires = { lf = 70, rf = 50 } }, true)
        Mock.fireNet('pf_mech:server:tireReplaced', MECH, VEH, 0)
        assert_eq(Entity(VEH).state.partDamage.tires.lf, 0)
        assert_eq(Entity(VEH).state.partDamage.tires.rf, 50, 'other tyres untouched')
        assert_eq(Entity(VEH).state.partDamage.brakes, 40)
        Mock.fireNet('pf_mech:server:tireReplaced', MECH, VEH, 1)
        assert_eq(Entity(VEH).state.partDamage.tires.rf, 50, 'one tyre per tyre taken')
    end)
end)

describe('a car taken out of a garage', function()
    it('gets its saved wear, mileage and NOS from the database, once, for a player in or near it', function()
        rows.diag.AB12CD = { oil = 35, brakes = 20, mileage = 1234.5, nos_has = 1, nos_level = 250, nos_color = '#FF0000' }
        rows.veh.AB12CD = { vehicle = 'sultan', mods = '{}' }
        Mock.coords[MECH] = vector3(500.0, 0.0, 0.0)
        Mock.fireNet('pf_mech:server:restoreVehicleState', MECH, VEH)
        assert_eq(Entity(VEH).state.mileage, nil, 'a player far away cannot trigger it')
        Mock.vehicleOf[MECH] = VEH
        Mock.fireNet('pf_mech:server:restoreVehicleState', MECH, VEH)
        local st = Entity(VEH).state
        assert_eq(st.partDamage.oil, 35)
        assert_eq(st.partDamage.brakes, 20)
        assert_eq(st.partDamage.radiator, 0)
        assert_eq(st.mileage, 1234.5)
        assert_true(st.nos.has)
        assert_eq(st.nos.level, 100, 'capped at the bottle capacity')
        assert_eq(st.nos.color, '#FF0000')
        -- driven on: a second restore cannot wind the car back to its stored wear
        st:set('mileage', 1300, true)
        Mock.fireNet('pf_mech:server:restoreVehicleState', MECH, VEH)
        assert_eq(st.mileage, 1300)
        -- once the car is gone a new car with the same id restores again
        Mock.fireEvent('entityRemoved', nil, VEH)
        states[VEH] = nil
        Mock.fireNet('pf_mech:server:restoreVehicleState', MECH, VEH)
        assert_eq(Entity(VEH).state.mileage, 1234.5)
    end)
    it('never takes NOS from player_vehicles.mods', function()
        rows.diag.AB12CD = { oil = 35, mileage = 10 }
        rows.veh.AB12CD = { vehicle = 'sultan', mods = '{"nos":{"has":true,"level":100}}' }
        Mock.vehicleOf[MECH] = VEH
        Mock.fireNet('pf_mech:server:restoreVehicleState', MECH, VEH)
        assert_eq(Entity(VEH).state.mileage, 10)
        assert_eq(Entity(VEH).state.nos, nil)
    end)
    it('ignores cars that do not exist and odd plates', function()
        existing[VEH] = nil
        Mock.vehicleOf[MECH] = VEH
        Mock.fireNet('pf_mech:server:restoreVehicleState', MECH, VEH)
        assert_eq(Entity(VEH).state.mileage, nil)
        existing[VEH] = true
        Mock.plates[VEH] = ''
        Mock.fireNet('pf_mech:server:restoreVehicleState', MECH, VEH)
        assert_eq(Entity(VEH).state.mileage, nil)
    end)
end)
