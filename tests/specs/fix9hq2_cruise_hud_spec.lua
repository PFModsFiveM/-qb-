-- Cruise control indicator: pfm-smallresources/client/cruise.lua raises the local event
-- 'seatbelt:client:ToggleCruise' (true when it starts holding the speed, false when it stops for
-- any reason). Its only handler was in the deleted pfm-hud; pf-hud now keeps the state and sends it
-- as `cruise` in its 'vehicle' NUI message (html/app.js shows the icon; tests/js/pfhud_cruise_spec.js).
load_resource('tests/lua/fivem_mocks.lua')

-- Client scripts run in their own environment: threads are coroutines that a test steps frame by
-- frame (Wait yields), event handlers are kept by kind, and any native not listed answers false
-- (Is*/Has*/Does*) or 0.
local function clientEnv(overrides)
    local env = { threads = {}, net = {}, events = {}, nui = {}, commands = {} }
    env.CreateThread = function(fn)
        local co = coroutine.create(fn)
        env.threads[#env.threads + 1] = co
        local ok, err = coroutine.resume(co)
        if not ok then error(err, 2) end
    end
    env.Wait = function() coroutine.yield() end
    env.RegisterNetEvent = function(name, fn) env.net[name] = fn end
    env.AddEventHandler = function(name, fn) env.events[name] = fn end
    env.SendNUIMessage = function(msg) env.nui[#env.nui + 1] = msg end
    env.RegisterCommand = function(name, fn) env.commands[name] = fn end
    for k, v in pairs(overrides or {}) do env[k] = v end
    return setmetatable(env, { __index = function(_, k)
        local g = _G[k]
        if g ~= nil then return g end
        if type(k) == 'string' and (k:match('^Is') or k:match('^Has') or k:match('^Does') or k:match('^NetworkIs')) then
            return function() return false end
        end
        return function() return 0 end
    end })
end

--- runs every live thread one frame
local function tick(env, frames)
    for _ = 1, frames or 1 do
        local live = {}
        for _, co in ipairs(env.threads) do
            if coroutine.status(co) == 'suspended' then
                local ok, err = coroutine.resume(co)
                if not ok then error(err, 2) end
            end
            if coroutine.status(co) ~= 'dead' then live[#live + 1] = co end
        end
        env.threads = live
    end
end

local function loadInto(env, path)
    assert(load(__readfile(path), '@' .. path, 't', env))()
end

describe('pf-hud shows the cruise control state', function()
    local ME, VEH = 7, 900
    local inCar = false
    local env = clientEnv({
        LocalPlayer = { state = { isLoggedIn = false } },
        PlayerPedId = function() return ME end,
        IsPedInAnyVehicle = function() return inCar end,
        GetVehiclePedIsIn = function() return inCar and VEH or 0 end,
        GetActiveScreenResolution = function() return 1920, 1080 end,
        GetAspectRatio = function() return 16 / 9 end,
        GetSafeZoneSize = function() return 1.0 end,
        HasStreamedTextureDictLoaded = function() return true end,
        GetEntityHealth = function() return 200 end,
        GetVehicleEngineHealth = function() return 1000.0 end,
        GetVehicleFuelLevel = function() return 50.0 end,
        GetResourceState = function() return 'missing' end,
        GetStreetNameFromHashKey = function() return '' end,
        GetStreetNameAtCoord = function() return 0, 0 end,
        GetEntityCoords = function() return vector3(0, 0, 0) end,
    })
    local core = { Functions = { GetPlayerData = function() return { metadata = {} } end } }
    env.exports = setmetatable({ ['pfm-core'] = { GetCoreObject = function() return core end } }, { __call = function() end })
    loadInto(env, '[pfscripts]/pf-hud/config.lua')
    loadInto(env, '[pfscripts]/pf-hud/client.lua')
    env.CreateThread(function() env.net['QBCore:Client:OnPlayerLoaded']() end)

    local function lastVehicleMessage()
        for i = #env.nui, 1, -1 do
            local m = env.nui[i]
            if m.action == 'vehicle' and m.show ~= false then return m end
        end
    end
    local function toggle(state) env.events['seatbelt:client:ToggleCruise'](state) end

    it('the cruise event is a local event, not one the network can raise', function()
        assert_true(env.events['seatbelt:client:ToggleCruise'] ~= nil, 'handled')
        assert_eq(env.net['seatbelt:client:ToggleCruise'], nil)
    end)

    it('the vehicle message carries cruise = false until cruise control turns on', function()
        inCar = true
        tick(env, 3)
        local m = lastVehicleMessage()
        assert_true(m ~= nil, 'a vehicle message while driving')
        assert_eq(m.cruise, false)
    end)

    it('on, then off', function()
        toggle(true)
        tick(env, 2)
        assert_eq(lastVehicleMessage().cruise, true)
        toggle(false)
        tick(env, 2)
        assert_eq(lastVehicleMessage().cruise, false)
    end)

    it('leaving the car clears it, so the next car does not start with the icon on', function()
        toggle(true)
        tick(env, 2)
        assert_eq(lastVehicleMessage().cruise, true)
        inCar = false
        tick(env, 3)
        inCar = true
        tick(env, 3)
        assert_eq(lastVehicleMessage().cruise, false)
    end)

    it('anything but true counts as off', function()
        toggle('yes')
        tick(env, 2)
        assert_eq(lastVehicleMessage().cruise, false)
    end)
end)

describe('pfm-smallresources cruise control tells the HUD when it starts and stops', function()
    local ME, VEH = 7, 900
    local seat, speed, fuel = ME, 20.0, 50
    local pressed, justPressed = {}, {}
    local sent, notes = {}, {}
    local env = clientEnv({
        PlayerPedId = function() return ME end,
        GetVehiclePedIsIn = function() return VEH end,
        GetPedInVehicleSeat = function(_, s) return s == -1 and seat or 0 end,
        GetVehicleClass = function() return 0 end,
        IsPedInAnyVehicle = function() return seat == ME end,
        GetEntitySpeed = function() return speed end,
        GetVehicleCurrentGear = function() return 3 end,
        IsControlPressed = function(_, c) return pressed[c] == true end,
        IsControlJustPressed = function(_, c) return justPressed[c] == true end,
        IsVehicleOnAllWheels = function() return true end,
        DoesEntityExist = function() return true end,
        GetResourceState = function(res) return res == 'pfm-fuel' and 'started' or 'missing' end,
        TriggerEvent = function(name, ...) sent[#sent + 1] = { name = name, args = { ... } } end,
        RegisterKeyMapping = function() end,
        QBCore = { Functions = { Notify = function(msg, kind) notes[#notes + 1] = { msg = msg, kind = kind } end } },
        Lang = { t = function(_, key) return key end },
    })
    env.exports = { ['pfm-fuel'] = { GetFuel = function() return fuel end } }
    loadInto(env, 'pfm-smallresources/client/cruise.lua')

    local function cruiseEvents()
        local out = {}
        for _, e in ipairs(sent) do
            if e.name == 'seatbelt:client:ToggleCruise' then out[#out + 1] = e.args[1] end
        end
        return out
    end
    local function press() env.commands['togglecruise']() end

    BeforeEach = function()
        seat, speed, fuel = ME, 20.0, 50
        pressed, justPressed, sent, notes = {}, {}, {}, {}
    end

    it('turning it on sends true once; pressing again while it runs starts no second loop', function()
        press()
        tick(env, 2)
        press()
        tick(env, 2)
        assert_eq(#env.threads, 1)
        local ev = cruiseEvents()
        assert_eq(#ev, 1)
        assert_eq(ev[1], true)
        justPressed[72] = true -- brake: back to a clean state for the next test
        tick(env, 1)
    end)

    it('braking sends false and tells the player', function()
        press()
        tick(env, 2)
        justPressed[72] = true
        tick(env, 1)
        local ev = cruiseEvents()
        assert_eq(#ev, 2)
        assert_eq(ev[2], false)
        assert_eq(notes[#notes].msg, 'cruise.deactivated')
        assert_eq(#env.threads, 0)
    end)

    it('leaving the driver\'s seat sends false too (it used to leave the HUD showing cruise on)', function()
        press()
        tick(env, 2)
        seat = 0
        tick(env, 1)
        local ev = cruiseEvents()
        assert_eq(#ev, 2)
        assert_eq(ev[2], false)
        assert_eq(#env.threads, 0)
        seat = ME
        press()
        assert_eq(cruiseEvents()[3], true, 'and it can be turned on again')
        justPressed[72] = true
        tick(env, 1)
    end)

    it('slowing down while steering keeps it on; slower once straight turns it off', function()
        press()
        tick(env, 1)
        pressed[63] = true
        speed = 15.0
        tick(env, 3)
        assert_eq(#cruiseEvents(), 1, 'still on while steering')
        pressed[63] = nil
        tick(env, 1)
        local ev = cruiseEvents()
        assert_eq(#ev, 2)
        assert_eq(ev[2], false)
    end)

    it('too little fuel: it never turns on', function()
        fuel = 5
        press()
        tick(env, 2)
        assert_eq(#cruiseEvents(), 0)
        assert_eq(notes[#notes].msg, 'cruise.not_Enough_Fuel')
    end)
end)
