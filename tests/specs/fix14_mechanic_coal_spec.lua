-- pf-mechanicjob rolling coal (MECH-9, server/main.lua + client/rolling_coal.lua): the smoke is
-- switched on and off by the driver of a car whose DPF is removed, at most one start per second,
-- and kept in the car's 'pfCoal' state bag (set by the server), which only clients that have the car
-- draw. The client's net id used to be relayed to every player, three times per request, for any car.
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
function GetAllVehicles() local out = {} for e in pairs(existing) do out[#out + 1] = e end return out end
local drivers = {}
function GetPedInVehicleSeat(veh, seat) if seat == -1 then return drivers[veh] or 0 end return 0 end

Config = nil
load_resource('[pfscripts]/pf-mechanicjob/config.lua')
load_resource('[pfscripts]/pf-mechanicjob/shared/debug.lua')
Config.Debug = false
Config.RollingCoal.enabled = true
load_resource('[pfscripts]/pf-mechanicjob/shared/performance_parts.lua')
load_resource('[pfscripts]/pf-mechanicjob/server/main.lua')

local MECH, DRIVER, OTHER = 1, 2, 3
local DIESEL, COP_CAR = 500, 501
local HERE = vector3(10.0, 10.0, 10.0)

local function coal(veh) return Entity(veh).state.pfCoal end
local function start(src, veh) Mock.fireNet('pf_mech:coal:syncStart', src, veh) end
local function stop(src, veh) Mock.fireNet('pf_mech:coal:syncStop', src, veh) end
local function removeDpf(plate)
    Mock.players[MECH].Functions.AddItem = function() return true end
    Mock.fireNet('pf_mech:dpf:remove', MECH, plate or 'DIESEL01')
end

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 100
    Mock.players, Mock.coords, Mock.plates = {}, {}, {}
    states, drivers = {}, {}
    existing = { [DIESEL] = true, [COP_CAR] = true }
    Mock.newPlayer(MECH).PlayerData.job = { name = 'mechanic', onduty = true }
    Mock.newPlayer(DRIVER)
    Mock.newPlayer(OTHER)
    for _, e in ipairs({ MECH, DRIVER, OTHER, DIESEL, COP_CAR }) do Mock.coords[e] = HERE end
    Mock.plates[DIESEL], Mock.plates[COP_CAR] = 'DIESEL01', 'POLICE01'
    drivers[DIESEL], drivers[COP_CAR] = DRIVER, OTHER
    for _, src in ipairs({ MECH, DRIVER, OTHER }) do Mock.fireEvent('playerDropped', src) end
end

describe('MECH-9 rolling coal on the server', function()
    it('one handler each, the Smoke:* relays are gone, and nothing is broadcast to every player', function()
        assert_eq(#Mock.netHandlerList['pf_mech:coal:syncStart'], 1)
        assert_eq(#Mock.netHandlerList['pf_mech:coal:syncStop'], 1)
        assert_eq(Mock.netHandlers['Smoke:SyncStartParticles'], nil)
        assert_eq(Mock.netHandlers['Smoke:SyncStopParticles'], nil)
        removeDpf()
        start(DRIVER, DIESEL)
        assert_eq(#Mock.clientEventsNamed('pf_mech:coal:startParticles'), 0)
        assert_eq(coal(DIESEL), true)
    end)

    it('a griefer cannot smoke out someone else\'s car or a car with its DPF', function()
        removeDpf()
        start(OTHER, DIESEL)                  -- not the driver
        start(DRIVER, COP_CAR)                -- not their car
        start(OTHER, COP_CAR)                 -- driver, but the DPF is fitted
        assert_true(coal(DIESEL) ~= true)
        assert_true(coal(COP_CAR) ~= true)
    end)

    it('at most one start per second per player; only the starter stops it', function()
        removeDpf()
        start(DRIVER, DIESEL)
        stop(OTHER, DIESEL)
        assert_eq(coal(DIESEL), true)
        stop(DRIVER, DIESEL)
        assert_eq(coal(DIESEL), false)
        start(DRIVER, DIESEL)                 -- same second
        assert_eq(coal(DIESEL), false)
        Mock.clock = Mock.clock + 1
        start(DRIVER, DIESEL)
        assert_eq(coal(DIESEL), true)
    end)

    it('the smoke ends when the driver leaves the seat or the server', function()
        removeDpf()
        start(DRIVER, DIESEL)
        drivers[DIESEL] = nil
        PFMech.CoalSweep()
        assert_eq(coal(DIESEL), false)
        drivers[DIESEL] = DRIVER
        Mock.clock = Mock.clock + 1
        start(DRIVER, DIESEL)
        Mock.fireEvent('playerDropped', DRIVER)
        assert_eq(coal(DIESEL), false)
    end)

    it('the DPF state is the server\'s: getCoalState answers from it', function()
        Mock.plates[DIESEL] = 'DIESEL09'
        assert_eq(Mock.callCallback('pf_mech:getCoalState', OTHER, 'DIESEL09'), false)
        removeDpf('DIESEL09')
        assert_eq(Mock.callCallback('pf_mech:getCoalState', OTHER, 'DIESEL09'), true)
    end)
end)

describe('MECH-9 rolling coal on the client', function()
    local handlers, started, stopped, registered, threads = {}, {}, {}, {}, {}
    local env = setmetatable({
        AddStateBagChangeHandler = function(key, _, fn) handlers[key] = fn end,
        GetEntityFromStateBagName = function(name) return tonumber(name:match('(%d+)$')) or 0 end,
        CreateThread = function(fn) threads[#threads + 1] = fn end,
        Wait = function() end,
        RegisterNetEvent = function(name) registered[#registered + 1] = name end,
        DoesEntityExist = function() return true end,
        RequestNamedPtfxAsset = function() end,
        HasNamedPtfxAssetLoaded = function() return true end,
        UseParticleFxAssetNextCall = function() end,
        GetEntityBoneIndexByName = function() return -1 end,
        StartParticleFxLoopedOnEntity = function(_, veh) started[#started + 1] = veh return #started end,
        StopParticleFxLooped = function(fx) stopped[#stopped + 1] = fx end,
        exports = setmetatable({}, { __call = function() end, __index = function()
            return setmetatable({}, { __index = function() return function() return {} end end })
        end }),
    }, { __index = _G })
    env._G = env
    assert(load(__readfile('[pfscripts]/pf-mechanicjob/client/rolling_coal.lua'), '@rolling_coal.lua', 't', env))()

    it('draws the smoke from the car\'s state bag, and no relayed net id is listened to', function()
        for _, name in ipairs(registered) do
            assert_true(name ~= 'pf_mech:coal:startParticles' and name ~= 'pf_mech:coal:stopParticles', name)
        end
        assert_true(handlers.pfCoal ~= nil)
        handlers.pfCoal('entity:777', 'pfCoal', true)
        table.remove(threads)()                      -- the handler's own thread
        assert_true(#started > 0)
        assert_eq(started[1], 777)
        handlers.pfCoal('entity:777', 'pfCoal', false)
        table.remove(threads)()
        assert_eq(#stopped, #started)
    end)
end)
