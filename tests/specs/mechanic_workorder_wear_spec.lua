-- pf-mechanicjob part wear from someone who is not driving ('pf_mech:server:setState' in
-- server/advanced_systems.lua). Only the job wear of a work-order car is set from outside: the car an
-- on-duty mechanic's client spawned for the order he accepted, which the server checked and
-- remembers (server/work_orders.lua 'pf_mech:workorders:registerVehicle'). Any other car only takes
-- wear from its driver, so a player can no longer wear out someone's parked car from beside it.
load_resource('tests/lua/ledger_env.lua')

MySQL.Sync = { fetchAll = function(q, p) return MySQL.query.await(q, p) end }
MySQL.Async = {
    insert = function(q, p) return MySQL.insert.await(q, p) end,
    execute = function(q, p, cb) local r = MySQL.update.await(q, p); if cb then cb(r) end; return r end,
}
local owned = { OWNED1 = true }
FakeDB.extraPatterns = {
    { 'pf_mechanic_progress', function() return {} end },
    { 'pf_mech_profiles', function() return {} end },
    { 'INSERT INTO pf_work_orders', function() return 1 end },
    { 'FROM player_vehicles WHERE plate', function(p) return owned[p[1]] and 1 or nil end },
}
-- the order search thread runs one round: Wait lets `waitBudget` calls through, then stops it
local waitBudget = 0
Wait = function() if waitBudget <= 0 then error('stop thread') end; waitBudget = waitBudget - 1 end
CreateThread = function(fn) pcall(fn) end

local states = {}
local stateMeta = { __index = { set = function(self, k, v) rawset(self, k, v) end } }
function Entity(e)
    states[e] = states[e] or { state = setmetatable({}, stateMeta) }
    return states[e]
end
local existing = {}
function DoesEntityExist(e) return existing[e] == true end

LedgerEnv.load('pf-mechanicjob', {
    '[pfscripts]/pf-mechanicjob/config.lua',
    '[pfscripts]/pf-mechanicjob/shared/debug.lua',
})
Config.Debug = false
load_resource('[pfscripts]/pf-mechanicjob/shared/performance_parts.lua')
load_resource('[pfscripts]/pf-mechanicjob/server/main.lua')
load_resource('[pfscripts]/pf-mechanicjob/server/work_orders.lua')
load_resource('[pfscripts]/pf-mechanicjob/server/advanced_systems.lua')

local MECH, CIV, MECH2 = 1, 2, 3
local PARKED, WORKCAR, OTHERCAR = 800, 801, 802
local SHOP = vector3(-350.0, -130.0, 39.0)
local SPAWN = Config.WorkOrderSystem.vehicleSpawnLocations[1]
local AT_SPAWN = vector3(SPAWN.x + 2.0, SPAWN.y, SPAWN.z)
local cidSeq = 0

local function st(veh) return Entity(veh).state end
local function wear(src, veh, value) Mock.fireNet('pf_mech:server:setState', src, veh, 'partDamage', value) end
local function register(src, orderId, veh) return Mock.callCallback('pf_mech:workorders:registerVehicle', src, orderId, veh) end
local function takeOrder(src)
    waitBudget = 1
    Mock.callCallback('pf_mech:workorders:startSearch', src)
    local offer = Mock.callCallback('pf_mech:workorders:getData', src).availableOrders[1]
    assert_true(offer ~= nil)
    local res = Mock.callCallback('pf_mech:workorders:accept', src, offer.id)
    assert_true(res.success)
    return res.order
end
-- the customer car the client spawned for the order
local function spawnFor(order, veh, coords)
    existing[veh] = true
    Mock.plates[veh] = '12ABC345'
    Mock.models[veh] = GetHashKey(order.vehicle)
    Mock.coords[veh] = coords or AT_SPAWN
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.clock = Mock.clock + 100000
    Mock.players, Mock.coords, Mock.vehicleOf, Mock.plates, Mock.models = {}, {}, {}, {}, {}
    states, existing = {}, { [PARKED] = true }
    cidSeq = cidSeq + 1
    Mock.newPlayer(MECH, 'MECH' .. cidSeq).PlayerData.job = { name = 'mechanic', onduty = true, grade = { level = 0 } }
    Mock.newPlayer(CIV, 'CIV' .. cidSeq).PlayerData.job = { name = 'unemployed' }
    Mock.newPlayer(MECH2, 'MECHB' .. cidSeq).PlayerData.job = { name = 'mechanic', onduty = true, grade = { level = 0 } }
    Mock.coords[MECH], Mock.coords[CIV], Mock.coords[MECH2] = SHOP, SHOP, SHOP
    -- someone's car parked at the shop
    Mock.plates[PARKED] = 'OWNED1'
    Mock.models[PARKED] = GetHashKey('sultan')
    Mock.coords[PARKED] = vector3(SHOP.x + 2.0, SHOP.y, SHOP.z)
    st(PARKED).partDamage = { brakes = 10 }
end

describe('wear on a car nobody is driving', function()
    it("a player beside someone's parked car cannot wear it out", function()
        wear(CIV, PARKED, { brakes = 100, engine_part = 100, oil = 100 })
        assert_eq(st(PARKED).partDamage.brakes, 10)
        assert_eq(st(PARKED).partDamage.engine_part, nil)
    end)

    it("nor can an on-duty mechanic with an accepted order, if it is not his order's car", function()
        takeOrder(MECH)
        wear(MECH, PARKED, { brakes = 100 })
        assert_eq(st(PARKED).partDamage.brakes, 10)
    end)

    it("the order's car, once the server knows it, takes the job wear from its mechanic wherever he is", function()
        local order = takeOrder(MECH)
        spawnFor(order, WORKCAR)
        assert_true(register(MECH, order.id, WORKCAR))
        wear(MECH, WORKCAR, { brakes = 55 })
        assert_eq(st(WORKCAR).partDamage.brakes, 55)
        wear(CIV, WORKCAR, { brakes = 90 })
        wear(MECH2, WORKCAR, { brakes = 90 })
        assert_eq(st(WORKCAR).partDamage.brakes, 55, 'nobody else')
        Mock.vehicleOf[CIV] = WORKCAR                                    -- someone drives off in it
        wear(MECH, WORKCAR, { brakes = 70 })
        assert_eq(st(WORKCAR).partDamage.brakes, 55, 'not while someone drives it')
    end)

    it('registration checks the mechanic, the order and the car', function()
        local order = takeOrder(MECH)
        spawnFor(order, WORKCAR)
        assert_false(register(CIV, order.id, WORKCAR), 'not a mechanic')
        assert_false(register(MECH2, order.id, WORKCAR), 'not his order')
        assert_false(register(MECH, order.id + 1000, WORKCAR), 'no such accepted order')
        assert_false(register(MECH, order.id, 'x'))
        assert_false(register(MECH, order.id, PARKED), "a player's car")
        Mock.players[MECH].PlayerData.job.onduty = false
        assert_false(register(MECH, order.id, WORKCAR), 'off duty')
        Mock.players[MECH].PlayerData.job.onduty = true
        spawnFor(order, OTHERCAR)
        Mock.models[OTHERCAR] = GetHashKey('t20') == Mock.models[WORKCAR] and GetHashKey('adder') or GetHashKey('t20')
        assert_false(register(MECH, order.id, OTHERCAR), 'another model')
        spawnFor(order, OTHERCAR, SHOP)
        assert_false(register(MECH, order.id, OTHERCAR), 'not at a work-order spawn point')
        existing[OTHERCAR] = nil
        waitBudget = 50                         -- the server waits a moment for a car it does not know yet
        assert_false(register(MECH, order.id, OTHERCAR), 'no such car')
        assert_true(register(MECH, order.id, WORKCAR))
        spawnFor(order, OTHERCAR)
        assert_false(register(MECH, order.id, OTHERCAR), 'one car per order')
        wear(MECH, OTHERCAR, { brakes = 80 })
        assert_eq(st(OTHERCAR).partDamage, nil)
    end)

    it('an off-duty mechanic, or one whose order was cancelled, sets no more wear from outside', function()
        local order = takeOrder(MECH)
        spawnFor(order, WORKCAR)
        assert_true(register(MECH, order.id, WORKCAR))
        Mock.players[MECH].PlayerData.job.onduty = false
        wear(MECH, WORKCAR, { brakes = 40 })
        assert_eq(st(WORKCAR).partDamage, nil)
        Mock.players[MECH].PlayerData.job.onduty = true
        local res = Mock.callCallback('pf_mech:workorders:cancel', MECH, order.id)
        assert_true(res.success)
        wear(MECH, WORKCAR, { brakes = 40 })
        assert_eq(st(WORKCAR).partDamage, nil)
    end)

    it('the driver of any car still adds wear to it', function()
        Mock.vehicleOf[CIV] = PARKED
        wear(CIV, PARKED, { brakes = 12 })
        assert_eq(st(PARKED).partDamage.brakes, 12)
    end)
end)

describe('a work-order car that is gone', function()
    it('stops counting, even if its handle is reused by someone else\'s car', function()
        local order = takeOrder(MECH)
        spawnFor(order, WORKCAR)
        assert_true(register(MECH, order.id, WORKCAR))
        -- the mechanic deletes the car; the freed handle is reused by a player's parked sultan
        Mock.fireEvent('entityRemoved', nil, WORKCAR)
        Mock.plates[WORKCAR], Mock.models[WORKCAR] = 'OWNED1', GetHashKey('sultan')
        st(WORKCAR).partDamage = { brakes = 10 }
        wear(MECH, WORKCAR, { brakes = 100 })
        assert_eq(st(WORKCAR).partDamage.brakes, 10)
    end)
    it('and a handle reused without the removal event is caught by its plate and model', function()
        local order = takeOrder(MECH)
        spawnFor(order, WORKCAR)
        assert_true(register(MECH, order.id, WORKCAR))
        Mock.plates[WORKCAR], Mock.models[WORKCAR] = 'OWNED1', GetHashKey('sultan')
        st(WORKCAR).partDamage = { brakes = 10 }
        wear(MECH, WORKCAR, { brakes = 100 })
        assert_eq(st(WORKCAR).partDamage.brakes, 10)
    end)
end)
