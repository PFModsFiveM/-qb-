-- pf-jobs Gruppe 6 client (client/gruppe6.lua): 'pf-jobs:gruppe6:returnVehicle' was registered
-- twice. Pressing E in the return area triggers that event, so an old "no bags collected" handler
-- ran next to the real one and showed 'No bags collected. Return the vehicle.' on every return.
-- One handler is left: the truck is returned, and no misleading error is shown. It also removes the
-- truck's storage target, before deleting the truck: pfm-target keeps a networked entity's options
-- under its net id (pfm-target/client.lua AddTargetEntity / RemoveTargetEntity), and a deleted
-- vehicle is no longer networked, so a removal after the delete looked under the handle and the
-- target stayed. The target mock below keys entities the same way. A contract the server ended with
-- no bags collected reaches the handler through 'pf-jobs:gruppe6:returnWithoutBags'. A party member
-- taken off the leader's contract ('pf-jobs:gruppe6:leftContract') drops the job but not the truck.
load_resource('tests/lua/fivem_mocks.lua')

local CLIENT = '[pfscripts]/pf-jobs/client/gruppe6.lua'
local EVENT = 'pf-jobs:gruppe6:returnVehicle'

local toServer, notes, bars, threads
-- vehicles: net id N is entity N + 1000; a deleted vehicle no longer exists and is not networked
local VEH_BASE = 1000
local deletedVehs, deletedList = {}, {}
local function isNetworked(e) return type(e) == 'number' and e > VEH_BASE and not deletedVehs[e] end
local function netIdOf(e) return e - VEH_BASE end
-- pfm-target's entity table, keyed as pfm-target keys it: a networked entity by its net id
local targets
local function targetKey(e) if isNetworked(e) then return netIdOf(e) end return e end
local function targetCount() local n = 0 for _ in pairs(targets) do n = n + 1 end return n end
local function sentToServer(name)
    local n = 0
    for _, e in ipairs(toServer) do if e.name == name then n = n + 1 end end
    return n
end
local function noted(fragment)
    for _, m in ipairs(notes) do if tostring(m):find(fragment, 1, true) then return true end end
    return false
end
local function barsNamed(name)
    local n = 0
    for _, b in ipairs(bars) do if b.name == name then n = n + 1 end end
    return n
end

local NOT_NATIVES = { Config = true, VehicleSpawnInProgress = true, VaultDoorStates = true, VaultPanelTargets = true,
    CurrentContract = true, CurrentVehicle = true }
local function noop() return nil end

local env, pedCoords, inVehicle, pressedE
local function loadClient()
    toServer, notes, bars, threads, targets = {}, {}, {}, {}, {}
    deletedVehs, deletedList = {}, {}
    pedCoords, inVehicle, pressedE = vector3(0, 0, 0), false, false
    -- a fresh client: only the handlers this load registers
    Mock.netHandlers, Mock.netHandlerList = {}, {}
    _G.__PF_G6_CLIENT_LOADED = nil
    QBCoreMock.Functions.Notify = function(msg) notes[#notes + 1] = msg end
    QBCoreMock.Functions.Progressbar = function(name, _, _, _, _, _, _, _, _, onFinish, onCancel)
        bars[#bars + 1] = { name = name, finish = onFinish, cancel = onCancel }
    end
    QBCoreMock.Functions.GetPlayerData = function() return { job = { name = 'unemployed', onduty = true } } end
    QBCoreMock.Functions.TriggerCallback = function() end
    QBCoreMock.Functions.DeleteVehicle = function(veh)
        deletedVehs[veh] = true
        deletedList[#deletedList + 1] = veh
    end
    Mock.exportsByResource['pfm-target'] = {
        AddBoxZone = function() end, RemoveZone = function() end,
        AddTargetEntity = function(_, entity, params) targets[targetKey(entity)] = params end,
        RemoveTargetEntity = function(_, entity) targets[targetKey(entity)] = nil end,
    }
    local own = {
        TriggerServerEvent = function(name, ...) toServer[#toServer + 1] = { name = name, args = { ... } } end,
        -- as in FiveM, a client TriggerEvent reaches every handler registered for the name
        TriggerEvent = function(name, ...)
            for _, fn in ipairs(Mock.netHandlerList[name] or {}) do fn(...) end
            local h = Mock.eventHandlers[name]
            if h then h(...) end
        end,
        ExecuteCommand = noop,
        CreateThread = function(fn) threads[#threads + 1] = fn end,
        Citizen = { SetTimeout = noop, CreateThread = function(fn) threads[#threads + 1] = fn end, Wait = noop },
        HasAnimDictLoaded = function() return true end,
        NetworkDoesNetworkIdExist = function() return true end,
        NetToVeh = function(netId) return netId + VEH_BASE end,
        NetworkGetEntityFromNetworkId = function(netId) return netId + VEH_BASE end,
        NetworkGetEntityIsNetworked = isNetworked,
        NetworkGetNetworkIdFromEntity = netIdOf,
        PlayerPedId = function() return 1 end,
        PlayerId = function() return 0 end,
        GetPlayerServerId = function() return 7 end,
        GetEntityCoords = function(e) if e == 1 then return pedCoords end return vector3(0, 0, 0) end,
        IsPedInVehicle = function() return inVehicle end,
        IsControlJustReleased = function() return pressedE end,
        DoesEntityExist = function(e) return not deletedVehs[e] end,
    }
    env = setmetatable(own, { __index = function(_, k)
        local v = _G[k]
        if v ~= nil then return v end
        if type(k) == 'string' and not NOT_NATIVES[k] and k:match('^%u') then return noop end
    end })
    assert(load(__readfile('[pfscripts]/pf-jobs/config.lua'), '@config.lua', 't', env))()
    assert(load(__readfile(CLIENT), '@' .. CLIENT, 't', env))()
    local started = threads
    threads = {}
    for _, fn in ipairs(started) do fn() end
end

local function fire(name, ...) Mock.fireNetAll(name, 7, ...) end
local function startContractWithTruck(netId, owner)
    fire('pf-jobs:gruppe6:startContract', {
        vehicle = 'stockade', plate = 'G6TEST', spawnCoords = { x = 1.0, y = 2.0, z = 3.0, w = 0.0 },
        pickupSequence = { 1, 2 }, locationBags = { 2, 2 }, spawnOwner = owner or 7,
    })
    fire('pf-jobs:gruppe6:vehicleSpawned', netId or 55, 'G6TEST', owner or 7, { x = 1.0, y = 2.0, z = 3.0 })
end
local function returnAtHq()
    threads = {}
    fire('pf-jobs:gruppe6:returnWithoutBags')
    pedCoords, inVehicle, pressedE = vector3(-20.0, -703.57, 32.34), true, true
    threads[1]()
    bars[#bars].finish()
end

BeforeEach = function()
    Mock.reset()
    loadClient()
end

describe('Gruppe 6 client: returning the truck', function()
    it("one handler is registered for 'pf-jobs:gruppe6:returnVehicle'", function()
        assert_eq(#(Mock.netHandlerList[EVENT] or {}), 1)
    end)

    it("pressing E in the return area returns the truck with no 'No bags collected' error", function()
        startContractWithTruck()
        -- every bag deposited with the vault already closed: off to the return area
        fire('pf-jobs:gruppe6:goToDeposit', env.Config.Gruppe6.DepositLocation)
        threads = {} -- the contract's own threads (truck, pickups) are not under test here
        fire('pf-jobs:gruppe6:depositProgress', 4, 4)
        assert_eq(#threads, 1, 'the return-area watcher started')
        pedCoords, inVehicle, pressedE = vector3(-20.0, -703.57, 32.34), true, true
        threads[1]()
        assert_false(noted('No bags collected'), 'no misleading error')
        assert_eq(barsNamed('return_vehicle'), 1, 'one return progress bar')
        assert_true(targets[55] ~= nil, "the truck's storage target, under its net id")
        bars[#bars].finish()
        assert_eq(sentToServer('pf-jobs:gruppe6:vehicleReturned'), 1)
        assert_true(noted('Vehicle returned successfully'), 'returned')
        assert_eq(deletedList[1], 1055, 'the truck is deleted')
        -- the truck's "Open Storage" target goes with it: removed while the truck was still
        -- networked (after the delete it was looked up under the handle and stayed)
        assert_eq(targets[55], nil, 'no storage target left under the net id')
        assert_eq(targetCount(), 0)
        assert_eq(sentToServer('pf-jobs:gruppe6:startSearch'), 1, 'looks for the next contract')
    end)

    it("the next contract's truck gets its own storage target again", function()
        startContractWithTruck(55)
        returnAtHq()
        assert_eq(targetCount(), 0)
        startContractWithTruck(56)
        assert_true(targets[56] ~= nil, 'storage on the new truck')
        assert_eq(targetCount(), 1)
    end)

    it("a party member taken off the leader's contract drops the job, not the leader's truck", function()
        startContractWithTruck(57, 3) -- the leader (server id 3) spawned the truck
        assert_eq(targetCount(), 0, 'a member has no storage target')
        threads = {}
        fire('pf-jobs:gruppe6:leftContract')
        assert_eq(#deletedList, 0, 'the truck stays')
        -- no return area and no job left on this client
        fire('pf-jobs:gruppe6:returnWithoutBags')
        assert_eq(#threads, 0)
        fire(EVENT)
        assert_true(noted('not in a Gruppe6 vehicle'))
        assert_eq(#bars, 0)
    end)

    it('a contract ended with no bags goes straight to the return area, and the truck is returned', function()
        startContractWithTruck()
        threads = {}
        -- the server ended the contract (nothing collected): no vault step
        fire('pf-jobs:gruppe6:returnWithoutBags')
        assert_eq(#threads, 1, 'the return-area watcher started')
        pedCoords, inVehicle, pressedE = vector3(-20.0, -703.57, 32.34), true, true
        threads[1]()
        assert_false(noted('No bags collected'))
        assert_eq(barsNamed('return_vehicle'), 1)
        bars[#bars].finish()
        assert_eq(sentToServer('pf-jobs:gruppe6:vehicleReturned'), 1)
        assert_eq(sentToServer('pf-jobs:gruppe6:depositComplete'), 0, 'no deposit asked for')
    end)

    it('without a truck the return is refused with the right message', function()
        fire(EVENT)
        assert_false(noted('No bags collected'))
        assert_true(noted('not in a Gruppe6 vehicle'))
        assert_eq(#bars, 0)
    end)
end)
