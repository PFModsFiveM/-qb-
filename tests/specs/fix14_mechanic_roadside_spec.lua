-- pf-mechanicjob roadside service (MECH-X1, server/advanced_systems.lua + server/main.lua): the
-- server spawns the broken-down car itself on a road spot 50-150 m from an on-duty mechanic, marks
-- its engine and body worn out, and pays once (per call id) only after this mechanic repaired both
-- with parts on that car (pf_mech:server:attemptRepair), beside it, after the minimum time; the car
-- is then removed. A car the client names (its own healthy car) is never a call, and health values
-- a client controls never pay.
load_resource('tests/lua/ledger_env.lua')
FakeDB.extraPatterns = {
    { 'UPDATE pf_mechanic_progress SET xp', function() return 1 end },
}

local states = {}
local stateMeta = { __index = { set = function(self, k, v) rawset(self, k, v) end } }
function Entity(e)
    states[e] = states[e] or { state = setmetatable({}, stateMeta) }
    return states[e]
end
local alive, nextCar = {}, 900
function DoesEntityExist(e) return alive[e] == true end
function GetAllVehicles() local out = {} for e in pairs(alive) do out[#out + 1] = e end return out end
function GetVehicleEngineHealth() return 1000.0 end     -- what a client could make the car report
function GetVehicleBodyHealth() return 1000.0 end
function SetVehicleNumberPlateText(veh, plate) Mock.plates[veh] = plate end
local spawned = {}
function CreateVehicleServerSetter(model, kind, x, y, z, h)
    nextCar = nextCar + 1
    alive[nextCar] = true
    Mock.coords[nextCar] = vector3(x, y, z)
    spawned[#spawned + 1] = { veh = nextCar, model = model, kind = kind, h = h }
    return nextCar
end
function DeleteEntity(e) alive[e] = nil end

LedgerEnv.load('pf-mechanicjob', { '[pfscripts]/pf-mechanicjob/config.lua' })
Config.AdvancedSystems.Enabled = true
Config.AdvancedSystems.RoadsideService.Enabled = true
load_resource('[pfscripts]/pf-mechanicjob/shared/performance_parts.lua')
load_resource('[pfscripts]/pf-mechanicjob/server/main.lua')
load_resource('[pfscripts]/pf-mechanicjob/server/advanced_systems.lua')

local MECH, MECH2, CIV = 1, 2, 3
local OWN_CAR = 500
local HERE = vector3(200.0, 200.0, 30.0)
local SPOT = { x = 290.0, y = 200.0, z = 31.0, h = 90.0 }     -- 90 m down the road
local MIN = Config.AdvancedSystems.RoadsideService.MinRepairSeconds

local function bank(src) return Mock.players[src].PlayerData.money.bank end
local function withParts(p)
    p.inv = { engine_part = 5, body_part = 5 }
    p.Functions.GetItemByName = function(name)
        local n = p.inv[name]
        if n and n > 0 then return { name = name, amount = n, label = name } end
    end
    p.Functions.RemoveItem = function(name, n)
        n = n or 1
        if (p.inv[name] or 0) < n then return false end
        p.inv[name] = p.inv[name] - n
        return true
    end
    return p
end
local function start(src, spot) Mock.fireNet('pf-mechanicjob:server:advanced:startRoadside', src, spot) end
local function complete(src) Mock.fireNet('pf-mechanicjob:server:advanced:completeRoadside', src, { plate = 'ANY', engine = 1000, body = 1000 }) end
local function repair(src, veh, part) return Mock.callCallback('pf_mech:server:attemptRepair', src, veh, part, 1) end
local function callCar() return spawned[#spawned] and spawned[#spawned].veh end
local function goTo(src, veh) Mock.coords[src] = Mock.coords[veh] end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.clock = Mock.clock + 10000
    Mock.players, Mock.coords, Mock.plates = {}, {}, {}
    states, alive, spawned = {}, { [OWN_CAR] = true }, {}
    withParts(Mock.newPlayer(MECH, 'MECH1')).PlayerData.job = { name = 'mechanic', onduty = true }
    withParts(Mock.newPlayer(MECH2, 'MECH2')).PlayerData.job = { name = 'mechanic', onduty = true }
    withParts(Mock.newPlayer(CIV, 'CIV1')).PlayerData.job = { name = 'unemployed', onduty = false }
    for _, src in ipairs({ MECH, MECH2, CIV }) do Mock.coords[src] = HERE end
    Mock.coords[OWN_CAR], Mock.plates[OWN_CAR] = HERE, 'MYCAR1'
    for _, src in ipairs({ MECH, MECH2, CIV }) do Mock.fireEvent('playerDropped', src) end
end

describe('roadside: the server makes the call', function()
    it("the mechanic's own healthy car never becomes a call or pays (the old exploit)", function()
        start(MECH, OWN_CAR)                                  -- a net id, as the old client sent
        Mock.clock = Mock.clock + 60
        complete(MECH)
        assert_eq(#spawned, 0)
        assert_eq(bank(MECH), 0)
        assert_eq(#LedgerEnv.paid('pf-mechanicjob:roadside:'), 0)
    end)

    it('spawns its own broken car on the road spot, 50-150 m away, for on-duty mechanics only', function()
        start(CIV, SPOT)
        Mock.players[MECH].PlayerData.job.onduty = false
        start(MECH, SPOT)
        start(MECH2, { x = 210.0, y = 200.0, z = 30.0 })      -- 10 m: too close
        start(MECH2, { x = 600.0, y = 200.0, z = 30.0 })      -- 400 m: too far
        start(MECH2, { x = 290.0, y = 200.0, z = 200.0 })     -- in the air
        start(MECH2, { x = 0 / 0, y = 200.0, z = 30.0 })
        assert_eq(#spawned, 0)
        start(MECH2, SPOT)
        assert_eq(#spawned, 1)
        local veh = callCar()
        assert_eq(spawned[1].kind, 'automobile')
        assert_eq(Entity(veh).state.partDamage.engine_part, 100)
        assert_eq(Entity(veh).state.partDamage.body_part, 100)
        assert_eq(Entity(veh).state.pfRoadside.mechanic, MECH2)
        local started = Mock.clientEventsNamed('pf-mechanicjob:client:advanced:roadsideStarted')
        assert_eq(#started, 1)
        assert_eq(started[1].target, MECH2)
        assert_eq(started[1].args[1].netId, veh)
    end)

    it('one live call at a time, and a cooldown between calls', function()
        start(MECH, SPOT)
        start(MECH, SPOT)
        assert_eq(#spawned, 1)
        alive[callCar()] = nil                                -- the car is gone: the call can be replaced...
        start(MECH, SPOT)
        assert_eq(#spawned, 1, '...but not before the cooldown')
        Mock.clock = Mock.clock + Config.AdvancedSystems.RoadsideService.CooldownSeconds
        start(MECH, SPOT)
        assert_eq(#spawned, 2)
    end)
end)

describe('roadside: paid for a real repair of that car', function()
    it('pays once, after both parts were repaired with parts by this mechanic, beside the car, not too soon', function()
        start(MECH, SPOT)
        local veh = callCar()
        Mock.clock = Mock.clock + MIN + 1
        goTo(MECH, veh)
        complete(MECH)                                        -- nothing repaired (whatever health the client claims)
        assert_eq(bank(MECH), 0)
        assert_true(repair(MECH, veh, 'engine_part'))
        complete(MECH)                                        -- body still broken
        assert_eq(bank(MECH), 0)
        assert_true(repair(MECH, veh, 'body_part'))
        Mock.coords[MECH] = vector3(800.0, 800.0, 30.0)
        complete(MECH)                                        -- not beside the car
        assert_eq(bank(MECH), 0)
        goTo(MECH, veh)
        complete(MECH)
        local paid = bank(MECH)
        assert_true(paid >= Config.AdvancedSystems.RoadsideService.RewardMin and paid <= Config.AdvancedSystems.RoadsideService.RewardMax)
        assert_eq(alive[veh], nil, 'the call car is removed')
        complete(MECH)
        assert_eq(bank(MECH), paid)
        assert_eq(#LedgerEnv.paid('pf-mechanicjob:roadside:'), 1)
        assert_eq(Mock.players[MECH].inv.engine_part, 4, 'the repair used the parts')
    end)

    it('repairs by another mechanic, or before the call started, do not count', function()
        start(MECH, SPOT)
        local veh = callCar()
        goTo(MECH, veh); goTo(MECH2, veh)
        assert_true(repair(MECH2, veh, 'engine_part'))
        assert_true(repair(MECH2, veh, 'body_part'))
        Mock.clock = Mock.clock + MIN + 1
        complete(MECH)
        assert_eq(bank(MECH), 0, 'MECH2 did the work')
        complete(MECH2)
        assert_eq(bank(MECH2), 0, 'MECH2 has no call')
    end)

    it('a repair finished before the minimum time is paid once the time has passed', function()
        start(MECH, SPOT)
        local veh = callCar()
        goTo(MECH, veh)
        repair(MECH, veh, 'engine_part')
        repair(MECH, veh, 'body_part')
        complete(MECH)
        assert_eq(bank(MECH), 0)
        Mock.clock = Mock.clock + MIN + 1
        complete(MECH)
        assert_true(bank(MECH) > 0)
    end)

    it('a mechanic who leaves loses the call and its car', function()
        start(MECH, SPOT)
        local veh = callCar()
        Mock.fireEvent('playerDropped', MECH)
        assert_eq(alive[veh], nil)
    end)
end)
