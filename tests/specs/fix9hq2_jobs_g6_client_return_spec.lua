-- pf-jobs Gruppe 6 client (client/gruppe6.lua): 'pf-jobs:gruppe6:returnVehicle' was registered
-- twice. Pressing E in the return area triggers that event, so an old "no bags collected" handler
-- ran next to the real one and showed 'No bags collected. Return the vehicle.' on every return.
-- One handler is left: the truck is returned, and no misleading error is shown.
load_resource('tests/lua/fivem_mocks.lua')

local CLIENT = '[pfscripts]/pf-jobs/client/gruppe6.lua'
local EVENT = 'pf-jobs:gruppe6:returnVehicle'

local toServer, notes, bars, threads
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
    toServer, notes, bars, threads = {}, {}, {}, {}
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
    QBCoreMock.Functions.DeleteVehicle = function() end
    Mock.exportsByResource['pfm-target'] = {
        AddBoxZone = function() end, RemoveZone = function() end,
        AddTargetEntity = function() end, RemoveTargetEntity = function() end,
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
        NetToVeh = function(netId) return netId end,
        PlayerPedId = function() return 1 end,
        PlayerId = function() return 0 end,
        GetPlayerServerId = function() return 7 end,
        GetEntityCoords = function(e) if e == 1 then return pedCoords end return vector3(0, 0, 0) end,
        IsPedInVehicle = function() return inVehicle end,
        IsControlJustReleased = function() return pressedE end,
        DoesEntityExist = function() return true end,
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
local function startContractWithTruck()
    fire('pf-jobs:gruppe6:startContract', {
        vehicle = 'stockade', plate = 'G6TEST', spawnCoords = { x = 1.0, y = 2.0, z = 3.0, w = 0.0 },
        pickupSequence = { 1, 2 }, locationBags = { 2, 2 }, spawnOwner = 7,
    })
    fire('pf-jobs:gruppe6:vehicleSpawned', 55, 'G6TEST', 7, { x = 1.0, y = 2.0, z = 3.0 })
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
        bars[#bars].finish()
        assert_eq(sentToServer('pf-jobs:gruppe6:vehicleReturned'), 1)
        assert_true(noted('Vehicle returned successfully'), 'returned')
    end)

    it('without a truck the return is refused with the right message', function()
        fire(EVENT)
        assert_false(noted('No bags collected'))
        assert_true(noted('not in a Gruppe6 vehicle'))
        assert_eq(#bars, 0)
    end)
end)
