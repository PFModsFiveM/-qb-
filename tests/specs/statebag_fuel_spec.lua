-- pfm-fuel, sv_stateBagStrictMode: the fuel level other players see ('qb-fuel' on the vehicle) is
-- set by the server only. The driver reports ('qb-fuel:server:syncFuel'): a new car takes that
-- level, after that a report can only lower it (fix9hq2_vehiclefx_fuel_sync_spec has the burn-rate
-- cap and the refuel paths that raise it); anyone else, a bad value or a flood changes nothing.
-- The client exports report instead of writing the state bag; the client applies the shared level
-- except a capped answer to its own report on the car it drives; the refuel flows send no client
-- level; the nozzle flags are local state values.
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
    local function later(seconds) Mock.gameTimer = Mock.gameTimer + seconds * 1000 end

    it('the driver gives a new car its level, then lowers it as fuel is used', function()
        sync(DRIVER, CAR, 64.5)
        assert_eq(fuel(CAR), 64.5)
        later(10)
        sync(DRIVER, CAR, 62.25)
        assert_eq(fuel(CAR), 62.25)
        later(10)
        sync(DRIVER, CAR, 80)
        assert_eq(fuel(CAR), 62.25, 'a report never raises it: refuelling does, on the server')
    end)

    it("another player's car: from far away or beside it, nothing", function()
        sync(DRIVER, CAR, 50)
        later(10)
        for _, src in ipairs({ FARAWAY, PASSERBY }) do
            sync(src, CAR, 0)
            sync(src, CAR, 100)
        end
        assert_eq(fuel(CAR), 50.0)
    end)

    it('bad values, unknown entities and non-vehicles change nothing', function()
        sync(DRIVER, CAR, 250)
        assert_eq(fuel(CAR), 100.0, 'clamped to a full tank')
        later(10)
        for _, bad in ipairs({ 'lots', {}, 0 / 0, math.huge, -math.huge }) do sync(DRIVER, CAR, bad) end
        assert_eq(fuel(CAR), 100.0)
        sync(DRIVER, CAR, -10)
        assert_eq(fuel(CAR), 95.0, 'clamped to empty, then to what 10 s of driving burns')
        later(10)
        missing[CAR] = true
        sync(DRIVER, CAR, 40)
        missing[CAR] = nil
        sync(DRIVER, PED_ENTITY, 40)
        sync(DRIVER, 'abc', 40)
        sync(DRIVER, 1.5, 40)
        assert_eq(fuel(CAR), 95.0)
        assert_eq(Entity(PED_ENTITY).state['qb-fuel'], nil)
    end)

    it('at most 20 reports per player in 10 seconds', function()
        for i = 1, 20 do
            sync(DRIVER, CAR, 100 - i)
            later(0.4)
        end
        local after20 = fuel(CAR)
        assert_true(after20 < 100 and after20 > 80, tostring(after20))
        later(1)
        sync(DRIVER, CAR, 0)
        assert_eq(fuel(CAR), after20, 'over the limit')
        Mock.gameTimer = Mock.gameTimer + 10001
        sync(DRIVER, CAR, 0)
        assert_true(fuel(CAR) < after20, 'a new window')
    end)

    it('nothing is synced when fuel sync is off', function()
        Config.SyncFuelBetweenPlayers = false
        sync(DRIVER, CAR, 33)
        assert_eq(fuel(CAR), nil)
    end)
end)

describe('pfm-fuel client', function()
    local toServer, localWrites, bagHandler = {}, {}, nil
    local level, driverOf, ME, pending = {}, {}, 77, {}
    local env = setmetatable({
        TriggerServerEvent = function(name, ...) toServer[#toServer + 1] = { name = name, args = { ... } } end,
        AddEventHandler = function() end,
        AddStateBagChangeHandler = function(key, _, fn) if key == 'qb-fuel' then bagHandler = fn end end,
        GetEntityFromStateBagName = function(bag) return tonumber(bag:match('entity:(%d+)')) or 0 end,
        DoesEntityExist = function() return true end,
        IsEntityAVehicle = function() return true end,
        NetworkRequestControlOfEntity = function() end,
        SetVehicleFuelLevel = function(veh, v) level[veh] = v end,
        GetVehicleFuelLevel = function(veh) return level[veh] or 41.0 end,
        PlayerPedId = function() return ME end,
        GetPedInVehicleSeat = function(veh, seat) return seat == -1 and driverOf[veh] or 0 end,
        NetworkGetEntityIsNetworked = function() return true end,
        NetworkGetNetworkIdFromEntity = function(e) return e + 1000 end,
        SetTimeout = function(_, fn) pending[#pending + 1] = fn end,
        Entity = function() return { state = setmetatable({}, { __index = { set = function(_, k, v, r) localWrites[#localWrites + 1] = { k, v, r } end } }) } end,
    }, { __index = _G })
    Config.SyncFuelBetweenPlayers = true
    assert(load(__readfile('pfm-fuel/client/exports.lua'), '@pfm-fuel/client/exports.lua', 't', env))()
    local function bag(veh, value) bagHandler(('entity:%d'):format(veh), 'qb-fuel', value) end

    it('SetFuel reports to the server (now and once more shortly) and writes no state bag', function()
        local SetFuel = Mock.exportsByResource['__self'].SetFuel
        SetFuel(CAR, 120)
        assert_eq(level[CAR], 100.0)
        level[CAR] = 41.0
        for _, fn in ipairs(pending) do fn() end
        assert_eq(#toServer, 2)
        assert_eq(toServer[1].name, 'qb-fuel:server:syncFuel')
        assert_eq(toServer[1].args[1], CAR + 1000)
        assert_eq(toServer[1].args[2], 100.0, 'clamped before it is sent')
        assert_eq(toServer[2].args[2], 41.0, 'the repeat sends the current level')
        assert_eq(#localWrites, 0)
    end)

    it('the shared level is applied to cars this client does not drive', function()
        assert_true(bagHandler ~= nil, 'a qb-fuel state bag handler')
        level[701] = 20.0
        bag(701, 64.5)
        assert_eq(level[701], 64.5)
        bag(701, 30)
        assert_eq(level[701], 30.0)
    end)

    it('the car this client drives keeps its own lower level when the server caps a drop', function()
        driverOf[702] = ME
        level[702] = 80.0
        bag(702, 80)                 -- its first value
        level[702] = 68.0            -- 10 s of hard driving burned 12
        bag(702, 75)                 -- the server took only 5 off
        assert_eq(level[702], 68.0, 'not raised back by the capped answer')
        bag(702, 70)                 -- the next report catches up
        assert_eq(level[702], 68.0)
        bag(702, 95)                 -- someone refuels it while it is driven
        assert_eq(level[702], 95.0, 'a raise is a refuel and is applied')
        level[702] = 60.0
        bag(702, 50)                 -- a lower shared level than ours is applied too
        assert_eq(level[702], 50.0)
        bag(702, 'lots')
        assert_eq(level[702], 50.0, 'a non-number is ignored')
    end)

    it('the refuel flows send no client level and take the server\'s answer', function()
        local src = __readfile('pfm-fuel/client/main.lua')
        assert_true(src:find("TriggerServerEvent%('qb%-fuel:server:setCanFuel', canLiter %- liter, NetworkGetEntityIsNetworked%(veh%) and NetworkGetNetworkIdFromEntity%(veh%) or nil%)") ~= nil, 'jerry can: can level and car only')
        assert_true(src:find("TriggerCallback%('qb%-fuel:server:refillVehicle', function%(success, level, reason%)") ~= nil, 'pump: async, with the new level')
        assert_true(src:find("end, liter, netId%)") ~= nil, 'pump: litres and car only')
        assert_true(src:find("SetFuel%(veh, tonumber%(level%) or") ~= nil, 'pump: the server\'s level is set locally')
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
