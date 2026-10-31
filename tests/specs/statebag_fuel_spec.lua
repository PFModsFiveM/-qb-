-- pfm-fuel, sv_stateBagStrictMode: the fuel level other players see ('qb-fuel' on the vehicle) is
-- set by the server only ('qb-fuel:server:syncFuel'). The driver (or the client simulating an
-- empty car) may report any level; a player beside the car may only top it up; anyone else, a bad
-- value or a flood changes nothing. The client exports report instead of writing the state bag,
-- and the nozzle flags are local state values.
load_resource('tests/lua/fivem_mocks.lua')

local states = {}
local stateMeta = { __index = { set = function(self, k, v) rawset(self, k, v) end } }
function Entity(e)
    states[e] = states[e] or { state = setmetatable({}, stateMeta) }
    return states[e]
end
local entityType, owners = {}, {}
function GetEntityType(e) return entityType[e] or 0 end
function NetworkGetEntityOwner(e) return owners[e] end
local missing = {}
function DoesEntityExist(e) return not missing[e] end

Config = nil
load_resource('pfm-fuel/Config.lua')
load_resource('pfm-fuel/server/main.lua')
load_resource('pfm-fuel/server/pricing.lua')

local DRIVER, PASSERBY, FARAWAY = 1, 2, 3
local CAR, PED_ENTITY = 500, 600
local HERE = vector3(100.0, 100.0, 30.0)

local function fuel(veh) return Entity(veh).state['qb-fuel'] end
local function sync(src, netId, level) Mock.fireNet('qb-fuel:server:syncFuel', src, netId, level) end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.vehicleOf, Mock.coords = {}, {}, {}
    Mock.gameTimer = Mock.gameTimer + 100000            -- a fresh rate window
    states, owners, missing = {}, {}, {}
    entityType = { [CAR] = 2, [PED_ENTITY] = 1 }
    for _, src in ipairs({ DRIVER, PASSERBY, FARAWAY }) do Mock.newPlayer(src) end
    Mock.coords[DRIVER], Mock.coords[PASSERBY], Mock.coords[CAR] = HERE, HERE + vector3(3.0, 0, 0), HERE
    Mock.coords[FARAWAY] = vector3(900.0, 900.0, 30.0)
    Mock.vehicleOf[DRIVER] = CAR
    Config.SyncFuelBetweenPlayers = true
end

describe('qb-fuel:server:syncFuel', function()
    it('the driver sets the level (down as fuel is used, up after a refill)', function()
        sync(DRIVER, CAR, 64.5)
        assert_eq(fuel(CAR), 64.5)
        sync(DRIVER, CAR, 12.25)
        assert_eq(fuel(CAR), 12.25)
        sync(DRIVER, CAR, 80)
        assert_eq(fuel(CAR), 80.0)
    end)

    it("another player's car: from far away nothing, from beside it only a top-up", function()
        sync(DRIVER, CAR, 50)
        sync(FARAWAY, CAR, 0)
        sync(FARAWAY, CAR, 100)
        assert_eq(fuel(CAR), 50.0, 'far away')
        sync(PASSERBY, CAR, 5)
        assert_eq(fuel(CAR), 50.0, 'beside it, but draining it')
        sync(PASSERBY, CAR, 70)
        assert_eq(fuel(CAR), 70.0, 'refuelling from the pump or a jerry can')
    end)

    it('a newly spawned car takes its first level from a player beside it', function()
        Mock.vehicleOf[DRIVER] = nil
        sync(PASSERBY, CAR, 30)
        assert_eq(fuel(CAR), 30.0)
    end)

    it('the client simulating an empty car may set any level, even from afar', function()
        Mock.vehicleOf[DRIVER] = nil
        sync(DRIVER, CAR, 90)
        owners[CAR] = FARAWAY
        sync(FARAWAY, CAR, 0)
        assert_eq(fuel(CAR), 0.0, 'e.g. a tow job car spawned with an empty tank')
        Mock.vehicleOf[DRIVER] = CAR
        sync(FARAWAY, CAR, 0)
        sync(FARAWAY, CAR, 40)
        assert_eq(fuel(CAR), 0.0, 'not once someone else drives it')
    end)

    it('bad values, unknown entities and non-vehicles change nothing', function()
        sync(DRIVER, CAR, 50)
        for _, bad in ipairs({ 'lots', {}, 0 / 0, math.huge, -math.huge }) do sync(DRIVER, CAR, bad) end
        assert_eq(fuel(CAR), 50.0)
        sync(DRIVER, CAR, 250)
        assert_eq(fuel(CAR), 100.0, 'clamped to a full tank')
        sync(DRIVER, CAR, -10)
        assert_eq(fuel(CAR), 0.0, 'clamped to empty')
        missing[CAR] = true
        sync(DRIVER, CAR, 40)
        missing[CAR] = nil
        sync(DRIVER, PED_ENTITY, 40)
        sync(DRIVER, 'abc', 40)
        sync(DRIVER, 1.5, 40)
        assert_eq(fuel(CAR), 0.0)
        assert_eq(Entity(PED_ENTITY).state['qb-fuel'], nil)
    end)

    it('at most 20 reports per player in 10 seconds', function()
        for i = 1, 20 do sync(DRIVER, CAR, i) end
        assert_eq(fuel(CAR), 20.0)
        sync(DRIVER, CAR, 99)
        assert_eq(fuel(CAR), 20.0, 'over the limit')
        Mock.gameTimer = Mock.gameTimer + 10001
        sync(DRIVER, CAR, 99)
        assert_eq(fuel(CAR), 99.0)
    end)

    it('nothing is synced when fuel sync is off', function()
        Config.SyncFuelBetweenPlayers = false
        sync(DRIVER, CAR, 33)
        assert_eq(fuel(CAR), nil)
    end)
end)

describe('pfm-fuel client', function()
    local toServer, localWrites = {}, {}
    local env = setmetatable({
        TriggerServerEvent = function(name, ...) toServer[#toServer + 1] = { name = name, args = { ... } } end,
        AddEventHandler = function() end,
        AddStateBagChangeHandler = function() end,
        DoesEntityExist = function() return true end,
        IsEntityAVehicle = function() return true end,
        NetworkRequestControlOfEntity = function() end,
        SetVehicleFuelLevel = function() end,
        GetVehicleFuelLevel = function() return 41.0 end,
        NetworkGetEntityIsNetworked = function() return true end,
        NetworkGetNetworkIdFromEntity = function(e) return e + 1000 end,
        SetTimeout = function(_, fn) fn() end,
        Entity = function() return { state = setmetatable({}, { __index = { set = function(_, k, v, r) localWrites[#localWrites + 1] = { k, v, r } end } }) } end,
    }, { __index = _G })
    assert(load(__readfile('pfm-fuel/client/exports.lua'), '@pfm-fuel/client/exports.lua', 't', env))()

    it('SetFuel reports to the server (now and once more shortly) and writes no state bag', function()
        local SetFuel = Mock.exportsByResource['__self'].SetFuel
        SetFuel(CAR, 120)
        assert_eq(#toServer, 2)
        assert_eq(toServer[1].name, 'qb-fuel:server:syncFuel')
        assert_eq(toServer[1].args[1], CAR + 1000)
        assert_eq(toServer[1].args[2], 100.0, 'clamped before it is sent')
        assert_eq(toServer[2].args[2], 41.0, 'the repeat sends the current level')
        assert_eq(#localWrites, 0)
    end)

    it('the nozzle flags are local state values, written with replicate = false', function()
        local src = __readfile('pfm-fuel/client/main.lua')
        local n = 0
        for key, rep in src:gmatch(":set%('([%w_]+)',[^\n]-,%s*([%w]+)%)") do
            n = n + 1
            assert_true(key == 'hasNozzle' or key == 'nozzleAttached', key)
            assert_eq(rep, 'false', key)
        end
        assert_eq(n, 4)
    end)
end)
