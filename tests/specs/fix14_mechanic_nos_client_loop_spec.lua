-- pf-mechanicjob NOS (MECH-11), the honest flow end to end: the real client loop (client/nos.lua)
-- runs frame by frame against the real server (server/nos.lua). Every TriggerServerEvent goes to
-- the server handler, the client reads the server's state bag, and the server drain ticks once per
-- second of game time. The empty bottle must come back to the driver with no request from the
-- client, at any frame rate, and the car must never be left with a bottle it cannot use.
-- (Before this, the server's drain cleared the bottle so the client never asked for the empty, or
-- the client's 60-fps prediction reached 0 first, asked too early, and was refused: the HUD stayed
-- at 0, the car could not boost and no new bottle could be fitted.)
load_resource('tests/lua/fivem_mocks.lua')
QBCore = QBCoreMock

-- server side ---------------------------------------------------------------------------------
local states = {}
local stateMeta = { __index = { set = function(self, k, v) rawset(self, k, v) end } }
function Entity(e)
    states[e] = states[e] or { state = setmetatable({}, stateMeta) }
    return states[e]
end
local existing, drivers = {}, {}
function DoesEntityExist(e) return existing[e] == true end
function GetIsVehicleEngineRunning() return false end
function GetPedInVehicleSeat(veh, seat) if seat == -1 then return drivers[veh] or 0 end return 0 end

Config = nil
load_resource('[pfscripts]/pf-mechanicjob/config.lua')
Config.Debug = false
QBCoreMock.Shared.Items.emptynos = { name = 'emptynos', label = 'Empty NOS' }
QBCoreMock.Shared.Items.nos = { name = 'nos', label = 'NOS' }
PFMech = { SaveNos = function() end }
load_resource('[pfscripts]/pf-mechanicjob/server/nos.lua')

local DRIVER, CAR = 1, 500
local L1 = Config.NOS.levels[1].drainPerSec
local full = false
local function inv() return Mock.players[DRIVER].inv end
local function nos() return Entity(CAR).state.nos end

-- client side ---------------------------------------------------------------------------------
local toServer, writes, hud = {}, {}, {}
local dropStarts = 0                  -- boost starts the "network" loses
local frame, budget, gameMs, frameMs = 0, 0, 0, 7
local useFrameTime = true
local pressed = function() return false end
local onFrame = nil                   -- optional per-frame check inside one run of the loop
local loops, clientNet = {}, {}

local function serverTick()
    Mock.clock = Mock.clock + 1
    PFMech.NosDrainTick()
end

local function clientState()
    return setmetatable({}, {
        __index = function(_, k)
            if k == 'set' then return function(_, key, v) writes[#writes + 1] = { key, v } end end
            return Entity(CAR).state[k]
        end,
    })
end

local env = setmetatable({
    TriggerServerEvent = function(name, ...)
        toServer[#toServer + 1] = { name = name, args = { ... } }
        local a = { ... }
        if name == 'pf_mech:nos:boost' and a[2] == true and dropStarts > 0 then
            dropStarts = dropStarts - 1
            return
        end
        if Mock.netHandlers[name] then Mock.fireNet(name, DRIVER, ...) end
    end,
    TriggerEvent = function(name, ...)
        if name == 'hud:client:UpdateNitrous' then
            local a = { ... }
            local srv = nos()
            hud[#hud + 1] = { on = a[1], level = a[2], server = srv and srv.has and srv.level or 0, at = gameMs }
        end
    end,
    RegisterNetEvent = function(name, fn) clientNet[name] = fn end,
    AddEventHandler = function() end,
    CreateThread = function(fn) loops[#loops + 1] = fn end,
    Wait = function(ms)
        frame = frame + 1
        local before = gameMs
        gameMs = gameMs + frameMs
        for _ = 1, math.floor(gameMs / 1000) - math.floor(before / 1000) do serverTick() end
        if onFrame then onFrame() end
        if frame > budget then error('stop frames') end
    end,
    GetGameTimer = function() return gameMs end,
    GetFrameTime = function() if useFrameTime then return frameMs / 1000 end end,
    Entity = function() return { state = clientState() } end,
    PlayerPedId = function() return DRIVER end,
    IsPedInAnyVehicle = function() return true end,
    GetVehiclePedIsIn = function() return CAR end,
    GetPedInVehicleSeat = function(veh, seat) return GetPedInVehicleSeat(veh, seat) end,
    GetIsVehicleEngineRunning = function() return false end,
    IsControlPressed = function(_, key) return pressed(key) end,
    IsControlJustPressed = function() return false end,
    GetEntitySpeed = function() return 30.0 end,                       -- about 67 mph
    GetEntityBoneIndexByName = function() return -1 end,
    GetEntityForwardVector = function() return vector3(0.0, 1.0, 0.0) end,
    GetVehicleNumberPlateText = function() return 'MYCAR001' end,
    GetVehicleCurrentGear = function() return 3 end,
    GetVehicleEngineTemperature = function() return 90.0 end,
    GetVehicleEngineHealth = function() return 1000.0 end,
    HasNamedPtfxAssetLoaded = function() return true end,
    HasAnimDictLoaded = function() return true end,
    NetworkHasControlOfEntity = function() return true end,
    NetworkGetNetworkIdFromEntity = function(e) return e end,
    DoesParticleFxLoopedExist = function() return false end,
}, { __index = function(_, k)
    local v = _G[k]
    if v ~= nil then return v end
    if type(k) == 'string' and k:match('^%u%l') then return function() return nil end end
end })
QBCoreMock.Functions.Notify = function() end
QBCoreMock.Functions.Progressbar = function(_, _, _, _, _, _, _, _, _, onFinish) onFinish() end
for _, f in ipairs({ '[pfscripts]/pf-mechanicjob/config.lua', '[pfscripts]/pf-mechanicjob/client/nos.lua' }) do
    assert(load(__readfile(f), '@' .. f, 't', env))()
    if env.Config then env.Config.HasTurbo = function() return true end; env.Config.Debug = false end
end
local BOOST = (env.Config.NOS.keys or {}).boost or 21
local boostLoop = loops[#loops]

local function run(seconds)
    budget = frame + math.ceil(seconds * 1000 / frameMs)
    local ok, err = pcall(boostLoop)
    assert(not ok and tostring(err):find('stop frames', 1, true), tostring(err))
end
local function sent(name, on)
    local out = {}
    for _, e in ipairs(toServer) do
        if e.name == name and (on == nil or e.args[2] == on) then out[#out + 1] = e end
    end
    return out
end
local function fitBottle()
    inv().nos = (inv().nos or 0) + 1
    Mock.useables.nos(DRIVER, { name = 'nos' })
    Mock.clock = Mock.clock + 5
    budget = frame + 1000
    clientNet['pf_mech:nos:install']()
end
-- The HUD never shows more than one second of drain below the server's level.
local function hudFollowsServer()
    for _, h in ipairs(hud) do
        if h.on and h.level < h.server - L1 - 0.001 then return false, h end
    end
    return true
end

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 1000
    Mock.players, Mock.coords, Mock.vehicleOf = {}, {}, {}
    states, toServer, writes, hud = {}, {}, {}, {}
    existing, drivers = { [CAR] = true }, { [CAR] = DRIVER }
    full, dropStarts, useFrameTime, frameMs = false, 0, true, 7
    pressed, onFrame = function() return false end, nil
    local p = Mock.newPlayer(DRIVER, 'CID1')
    p.inv = {}
    p.Functions.GetItemByName = function(name)
        local n = p.inv[name]
        if n and n > 0 then return { name = name, amount = n } end
    end
    p.Functions.RemoveItem = function(name, n)
        n = n or 1
        if (p.inv[name] or 0) < n then return false end
        p.inv[name] = p.inv[name] - n
        return true
    end
    p.Functions.AddItem = function(name, n)
        if full then return false end
        p.inv[name] = (p.inv[name] or 0) + (n or 1)
        return true
    end
    Mock.vehicleOf[DRIVER] = CAR
    Mock.fireEvent('playerDropped', DRIVER)
end

describe('MECH-11 honest NOS loop: fit, boost to empty, get the empty back', function()
    local function boostToEmpty()
        fitBottle()
        assert_eq(nos().has, true)
        assert_eq(nos().level, Config.NOS.capacity)
        assert_eq(inv().nos, 0)
        pressed = function(key) return key == BOOST end
        run(15)
        assert_eq(nos().has, false, 'the server drained the bottle')
        assert_eq(inv().emptynos, 1, 'the driver got the empty back')
        assert_eq(#sent('pf_mech:nos:giveEmpty'), 0, 'nothing asked for')
        assert_eq(#sent('pf_mech:nos:boost', true), 1, 'one boost start')
        assert_eq(hud[#hud].on, false, 'HUD off once the bottle is gone')
        assert_true(hudFollowsServer())
        assert_eq(#writes, 0, 'the client writes no state bag')
        -- the car takes a new bottle straight away
        pressed = function() return false end
        fitBottle()
        assert_eq(nos().has, true)
        assert_eq(nos().level, Config.NOS.capacity)
        run(1)
        assert_eq(hud[#hud].level, Config.NOS.capacity, 'the HUD shows the new bottle')
    end

    it('at 144 fps', function()
        frameMs = 7
        boostToEmpty()
    end)

    it('at 30 fps', function()
        frameMs = 33
        boostToEmpty()
    end)

    it('at 144 fps without a frame time (the old 60-fps prediction runs ahead): never stuck', function()
        frameMs, useFrameTime = 7, false
        boostToEmpty()
    end)

    -- (one run of the client loop per scenario: a new run would forget it was boosting)
    it('let go half-way: the HUD shows the server\'s level, the next boost works and empties it', function()
        fitBottle()
        local t0 = gameMs
        pressed = function(key) return key == BOOST and (gameMs < t0 + 3000 or gameMs >= t0 + 15000) end
        local mid
        onFrame = function()
            if not mid and gameMs >= t0 + 14900 then
                mid = { level = nos().level, hud = hud[#hud].level, empties = inv().emptynos }
            end
        end
        run(30)
        assert_true(mid.level > 0 and mid.level < Config.NOS.capacity, 'part used, then let go')
        assert_eq(mid.hud, mid.level, 'the HUD shows the server\'s level, not a prediction')
        assert_eq(mid.empties, nil)
        assert_eq(nos().has, false)
        assert_eq(inv().emptynos, 1)
        assert_eq(#sent('pf_mech:nos:boost', true), 2)
        assert_true(hudFollowsServer())
    end)

    it('a boost start the server never got: the client stops it and boosts again', function()
        fitBottle()
        dropStarts = 1
        local t0 = gameMs
        local at35
        onFrame = function()
            if not at35 and gameMs >= t0 + 3500 then
                at35 = { starts = #sent('pf_mech:nos:boost', true), stops = #sent('pf_mech:nos:boost', false) }
            end
        end
        pressed = function(key) return key == BOOST end
        run(16)
        assert_eq(at35.starts, 2, 'ended after 3 s of silence, then started again')
        assert_true(at35.stops >= 1)
        assert_eq(nos().has, false, 'the second start drains it')
        assert_eq(inv().emptynos, 1)
    end)

    it('inventory full: the empty is kept and handed over once there is room, once', function()
        fitBottle()
        full = true
        pressed = function(key) return key == BOOST end
        run(15)
        assert_eq(nos().has, false)
        assert_eq(inv().emptynos, nil)
        PFMech.NosFlushEmpties('CID1')
        assert_eq(inv().emptynos, nil, 'still full')
        full = false
        PFMech.NosFlushEmpties('CID1')
        PFMech.NosFlushEmpties('CID1')
        assert_eq(inv().emptynos, 1)
    end)
end)
