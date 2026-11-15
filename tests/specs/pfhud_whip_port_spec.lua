-- pf-hud's WHIP port (client side): the settings as pfm-ui prefs (group HUD) or pf-hud's own KVP, the dial's data read
-- from pfm-media-map (and working without it), the radar tuner's clamps and saves, and the dark radar tiles swapped in
-- only while pfm-media-map is started. The page is tests/js/pfhud_whip_hud_spec.js.
load_resource('tests/lua/fivem_mocks.lua')

-- A client environment: threads are coroutines a test steps (Wait yields), handlers kept by name, KVP in memory, and
-- any native not listed answers false (Is*/Has*/Does*) or 0.
local function clientEnv(overrides)
    local env = { threads = {}, net = {}, events = {}, nui = {}, commands = {}, callbacks = {}, kvp = {}, calls = {} }
    env.CreateThread = function(fn)
        local co = coroutine.create(fn)
        env.threads[#env.threads + 1] = co
        local ok, err = coroutine.resume(co)
        if not ok then error(err, 2) end
    end
    env.Wait = function() coroutine.yield() end
    env.RegisterNetEvent = function(name, fn) env.net[name] = fn end
    env.AddEventHandler = function(name, fn)
        env.events[name] = env.events[name] or {}
        table.insert(env.events[name], fn)
    end
    env.SendNUIMessage = function(msg) env.nui[#env.nui + 1] = msg end
    env.RegisterNUICallback = function(name, fn) env.callbacks[name] = fn end
    env.RegisterCommand = function(name, fn) env.commands[name] = fn end
    env.GetResourceKvpString = function(k) local v = env.kvp[k]; return type(v) == 'string' and v or nil end
    env.SetResourceKvp = function(k, v) env.kvp[k] = v end
    env.GetResourceKvpInt = function(k) return tonumber(env.kvp[k]) or 0 end
    env.SetResourceKvpInt = function(k, v) env.kvp[k] = v end
    env.DeleteResourceKvp = function(k) env.kvp[k] = nil end
    env.GetGameTimer = function() return 0 end
    env.GetActiveScreenResolution = function() return 1920, 1080 end
    env.GetSafeZoneSize = function() return 1.0 end
    env.HasStreamedTextureDictLoaded = function() return true end
    env.PadBridge = false
    env.Citizen = { InvokeNative = function() return false end, ReturnResultAnyway = function() end, ResultAsInteger = function() end }
    for _, name in ipairs({ 'AddReplaceTexture', 'RemoveReplaceTexture', 'ReplaceHudColourWithRgba', 'SetMinimapComponentPosition',
        'SetMinimapClipType', 'SetNuiFocus', 'DisplayRadar' }) do
        env[name] = function(...) env.calls[#env.calls + 1] = { name = name, args = { ... } } end
    end
    env.GetHudColour = function() return 164, 76, 242, 255 end
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

local function fire(env, name, ...)
    for _, fn in ipairs(env.events[name] or {}) do fn(...) end
end

local function callsTo(env, name)
    local out = {}
    for _, c in ipairs(env.calls) do if c.name == name then out[#out + 1] = c.args end end
    return out
end

local HUD = '[pfscripts]/pf-hud/'

-- a fake pfm-ui: DefinePref / GetPref / SetPref over a table
local function fakeUi()
    local ui = { defs = {}, values = {}, sets = {} }
    ui.DefinePref = function(_, def)
        if type(def.default) == 'table' then return false end
        ui.defs[def.key] = def
        return true
    end
    ui.GetPref = function(_, key)
        local v = ui.values[key]
        if v == nil and ui.defs[key] then v = ui.defs[key].default end
        return v
    end
    ui.SetPref = function(_, key, value)
        ui.sets[#ui.sets + 1] = { key = key, value = value }
        ui.values[key] = value
        return true
    end
    return ui
end

local function prefsEnv(uiStarted, kvp)
    local ui = fakeUi()
    local env = clientEnv({
        GetResourceState = function(res) return (res == 'pfm-ui' and uiStarted) and 'started' or 'missing' end,
    })
    env.exports = { ['pfm-ui'] = ui }
    for k, v in pairs(kvp or {}) do env.kvp[k] = v end
    loadInto(env, HUD .. 'config.lua')
    loadInto(env, HUD .. 'client/prefs.lua')
    return env, ui
end

describe('pf-hud settings with pfm-ui started: prefs in the group HUD', function()
    it('declares every simple setting with pfm-ui, group HUD, a plain default', function()
        local env, ui = prefsEnv(true)
        local n = env.HudPrefs.define()
        assert_eq(n, #env.HudPrefs.DEFS)
        assert_true(n >= 15, 'the HUD has its settings in the pause menu')
        for key, def in pairs(ui.defs) do
            assert_eq(def.group, 'HUD', key)
            assert_true(key:match('^hud%.') ~= nil, key .. ' is namespaced')
            assert_true(type(def.default) ~= 'table' and def.default ~= nil, key .. ' has a plain default')
        end
        assert_eq(ui.defs['hud.scale'].default, 100, 'the size is a whole percentage there')
        assert_eq(ui.defs['hud.dial'].type, 'choice')
        assert_eq(ui.defs['hud.mapStyle'].default, 'frame', 'the framed WHIP map by default')
        assert_eq(ui.defs['hud.dial'].default, 'custom')
    end)

    it('reads the prefs over its own defaults (the size back as a factor)', function()
        local env, ui = prefsEnv(true)
        env.HudPrefs.define()
        ui.values['hud.style'] = 'classic'
        ui.values['hud.scale'] = 120
        ui.values['hud.mapOnFoot'] = true
        local s = env.HudPrefs.load()
        assert_eq(s.hudStyle, 'classic')
        assert_near(s.scale, 1.2, 1e-9)
        assert_eq(s.minimapOnFoot, true)
        assert_eq(type(s.theme), 'table', 'the theme is still its own')
    end)

    it('saving: prefs through pfm-ui (only what changed), the theme and layout in its KVP', function()
        local env, ui = prefsEnv(true)
        env.HudPrefs.define()
        local s = env.HudPrefs.load()
        s.minimapShape = 'square'
        s.theme.accent = '#ff0000'
        s.layout.status = { x = 10, y = 80, scale = 1 }
        env.HudPrefs.save(s)
        assert_eq(#ui.sets, 1, 'one pref changed')
        assert_eq(ui.sets[1].key, 'hud.mapShape')
        assert_eq(ui.sets[1].value, 'square')
        local saved = json.decode(env.kvp['pf-hud:settings'])
        assert_eq(saved.theme.accent, '#ff0000')
        assert_eq(saved.layout.status.x, 10)
        assert_eq(saved.minimapShape, nil, 'a pref is not kept twice')
        assert_eq(saved.hudStyle, nil)
    end)

    it('a change in the pause menu reaches the HUD in its own terms', function()
        local env = prefsEnv(true)
        local got = {}
        env.HudPrefs.onChange(function(name, value) got[#got + 1] = { name, value } end)
        fire(env, 'pfm-ui:prefChanged', 'hud.scale', 90)
        fire(env, 'pfm-ui:prefChanged', 'pad.enabled', false)   -- not the HUD's
        assert_eq(#got, 1)
        assert_eq(got[1][1], 'scale')
        assert_near(got[1][2], 0.9, 1e-9)
    end)

    it('the first run with pfm-ui carries a player\'s old choices over, once', function()
        local env, ui = prefsEnv(true, { ['pf-hud:settings'] = json.encode({ minimapShape = 'square', hudStyle = 'bars' }) })
        env.HudPrefs.define()
        local s = env.HudPrefs.load()
        assert_eq(s.minimapShape, 'square')
        assert_eq(s.hudStyle, 'classic', 'the old bars style is the classic gauges now')
        assert_eq(env.kvp['pf-hud:prefsMigrated'], 1)
        local count = #ui.sets
        env.HudPrefs.load()
        assert_eq(#ui.sets, count, 'not again')
    end)
end)

describe('pf-hud settings without pfm-ui: its own KVP', function()
    it('declares nothing and keeps every setting itself', function()
        local env, ui = prefsEnv(false, { ['pf-hud:settings'] = json.encode({ hudStyle = 'rings', minimapOnFoot = true,
            layout = { speedo = { x = 1, y = 2 }, compass = { x = 40, y = 2, scale = 1 } } }) })
        assert_eq(env.HudPrefs.define(), 0)
        assert_eq(next(ui.defs), nil)
        local s = env.HudPrefs.load()
        assert_eq(s.hudStyle, 'black', 'the old rings style is the black gauges')
        assert_eq(s.minimapOnFoot, true)
        assert_eq(s.layout.speedo, nil, 'the old speedometer spot is dropped')
        assert_eq(s.layout.compass.x, 40)
        s.dialStyle = 'simple'
        env.HudPrefs.save(s)
        local saved = json.decode(env.kvp['pf-hud:settings'])
        assert_eq(saved.dialStyle, 'simple')
        assert_eq(saved.hudStyle, 'black')
        assert_eq(#ui.sets, 0)
    end)
end)

describe('pf-hud settings saved before the WHIP look', function()
    it('the old box behind the gauges and the map logo go back to the new defaults once', function()
        local env = prefsEnv(false, { ['pf-hud:settings'] = json.encode({ showLogo = true, boxes = { status = true, compass = false } }) })
        local s = env.HudPrefs.load()
        assert_eq(s.boxes.status, false)
        assert_eq(s.showLogo, false)
        assert_eq(s.boxes.compass, false, 'the rest of the choices stay')
        s.showLogo = true
        env.HudPrefs.save(s)
        assert_eq(env.HudPrefs.load().showLogo, true, 'turned on again, it stays on')
    end)
end)

-- ── the dial's data ──────────────────────────────────────────────────

local ADDER = GetHashKey('adder')

local function dialEnv(mediaState, files, noClassTops)
    local env = clientEnv({
        GetResourceState = function(res) return res == 'pfm-media-map' and mediaState or 'missing' end,
        LoadResourceFile = function(res, file)
            if res ~= 'pfm-media-map' then return nil end
            if files then return files[file] end
            local ok, src = pcall(__readfile, 'pfm-media-map/' .. file)
            return ok and src or nil
        end,
        GetEntityModel = function() return ADDER end,
        GetVehicleClass = function() return 7 end,   -- super
    })
    loadInto(env, HUD .. 'config.lua')
    if noClassTops then env.Config.VehicleHud.rpmByClass = {} end
    loadInto(env, HUD .. 'client/dial.lua')
    return env
end

describe('pf-hud\'s dial reads its GTA-derived data from pfm-media-map', function()
    it('with pfm-media-map started: the dashboard looks and the measured ranges', function()
        local env = dialEnv('started')
        assert_true(env.HudDial.hasData())
        assert_eq(env.HudDial.skinOf(ADDER), 'supergt_detail_pack')
        local m = env.HudDial.measured(ADDER)
        assert_near(m[1], 0.90, 1e-9)
        assert_near(m[2], 8.18, 1e-9)
        assert_near(env.HudDial.measuredClass('super'), 8.5, 1e-9)
    end)

    it('a class with no top in config.lua takes the measured one', function()
        local env = dialEnv('started', nil, true)
        local max, redline, idle = env.HudDial.revRange(900)
        assert_near(max, 8.5, 1e-9)
        assert_near(redline, 8.5 * 0.87, 1e-9)
        assert_near(idle, 0.8, 1e-9, 'config.lua\'s idle')
    end)

    it('the car\'s dashboard look goes to the page on getting in', function()
        local env = dialEnv('started')
        env.HudDial.configure({ dialStyle = 'custom', speedUnit = 'kmh', dialHorizon = 'flat' })
        local cfg, range
        for _, m in ipairs(env.nui) do
            if m.action == 'vehicleHudConfig' then cfg = m end
        end
        assert_eq(cfg.media, 'https://cfx-nui-pfm-media-map/')
        assert_eq(cfg.units, 'kmh')
        assert_eq(cfg.attitude, 'flat')
        assert_eq(cfg.skins, true)
        env.GetVehiclePedIsIn = function() return 900 end
        env.DoesEntityExist = function() return true end
        env.HudDial.configure({ dialStyle = 'custom' })
        for _, m in ipairs(env.nui) do if m.action == 'vehicleDialRange' then range = m end end
        assert_eq(range.skin, 'supergt_detail_pack')
        assert_eq(range.kind, 'car')
    end)

    it('without pfm-media-map: no data, the config\'s ranges, no skin, and no error', function()
        local env = dialEnv('missing')
        assert_false(env.HudDial.hasData())
        assert_eq(env.HudDial.skinOf(ADDER), nil)
        local max, _, idle = env.HudDial.revRange(900)
        assert_near(max, 9, 1e-9, 'config.lua\'s super top')
        assert_near(idle, 0.8, 1e-9)
        env.GetVehiclePedIsIn = function() return 900 end
        env.DoesEntityExist = function() return true end
        env.HudDial.configure({ dialStyle = 'custom' })
        local cfg, range
        for _, m in ipairs(env.nui) do
            if m.action == 'vehicleHudConfig' then cfg = m end
            if m.action == 'vehicleDialRange' then range = m end
        end
        assert_eq(cfg.media, false)
        assert_eq(range.skin, false)
    end)

    it('started but a file missing or broken: treated as absent', function()
        local env = dialEnv('started', { ['data/rpm_by_model.lua'] = 'return {', ['data/dash_skins.lua'] = nil })
        assert_false(env.HudDial.hasData())
        assert_eq(env.HudDial.skinOf(ADDER), nil)
    end)

    it('pfm-media-map starting later brings the data in', function()
        local state = 'missing'
        local env = clientEnv({
            GetResourceState = function(res) return res == 'pfm-media-map' and state or 'missing' end,
            LoadResourceFile = function(res, file) return __readfile('pfm-media-map/' .. file) end,
        })
        loadInto(env, HUD .. 'config.lua')
        loadInto(env, HUD .. 'client/dial.lua')
        assert_false(env.HudDial.hasData())
        state = 'started'
        fire(env, 'onClientResourceStart', 'pfm-media-map')
        assert_true(env.HudDial.hasData())
    end)

    it('reads fifteen times a second and sends only what moved, in one reused message', function()
        local env = dialEnv('started')
        local waits = {}
        env.Wait = function(ms) waits[#waits + 1] = ms; coroutine.yield() end
        local speed = 20.0
        env.PlayerPedId = function() return 7 end
        env.GetVehiclePedIsIn = function() return 900 end
        env.DoesEntityExist = function() return true end
        env.GetEntitySpeed = function() return speed end
        env.GetEntitySpeedVector = function() return vector3(0, 10, 0) end
        env.GetIsVehicleEngineRunning = function() return 1 end
        env.GetVehicleCurrentRpm = function() return 0.5 end
        env.GetVehicleCurrentGear = function() return 3 end
        env.GetVehicleEngineHealth = function() return 1000.0 end
        env.GetVehicleLightsState = function() return 1, 0, 0 end
        env.HudDial.configure({ dialStyle = 'pf' })
        env.HudDial.start()
        tick(env, 3)
        local dials = {}
        for _, m in ipairs(env.nui) do if m.action == 'updateVehicleDials' then dials[#dials + 1] = m end end
        assert_eq(#dials, 1, 'parked: one message, then nothing')
        assert_eq(dials[1].speed, 72)
        assert_eq(dials[1].gear, 3)
        assert_eq(waits[#waits], 66, 'fifteen reads a second')
        speed = 30.0
        tick(env, 1)
        local again = {}
        for _, m in ipairs(env.nui) do if m.action == 'updateVehicleDials' then again[#again + 1] = m end end
        assert_eq(#again, 2)
        assert_true(again[1] == again[2], 'the same table, refilled (no allocation per read)')
        assert_eq(again[2].speed, 108)
    end)

    it('the dial style "none" reads nothing; "simple" and "pf" wear no dashboard look', function()
        local env = dialEnv('started')
        env.GetVehiclePedIsIn = function() return 900 end
        env.DoesEntityExist = function() return true end
        env.HudDial.configure({ dialStyle = 'pf' })
        local range
        for _, m in ipairs(env.nui) do if m.action == 'vehicleDialRange' then range = m end end
        assert_eq(range.skin, false)
        assert_eq(range.dial, true)
        env.HudDial.configure({ dialStyle = 'none' })
        for _, m in ipairs(env.nui) do if m.action == 'vehicleDialRange' then range = m end end
        assert_eq(range.dial, false)
    end)
end)

-- ── the radar tuner ──────────────────────────────────────────────────

local function tunerEnv(kvp)
    local env = clientEnv({ GetResourceState = function() return 'missing' end })
    for k, v in pairs(kvp or {}) do env.kvp[k] = v end
    loadInto(env, HUD .. 'config.lua')
    loadInto(env, HUD .. 'client/radar.lua')
    loadInto(env, HUD .. 'client/skin.lua')
    loadInto(env, HUD .. 'client/radar_tuner.lua')
    return env
end

describe('pf-hud\'s radar tuner (/radartuner)', function()
    it('opens only on the server\'s word (a net event, the admin command), with the panel and focus', function()
        local env = tunerEnv()
        assert_eq(env.commands.radartuner, nil, 'no client command anyone could run')
        env.net['pf-hud:client:radarTuner']()
        assert_true(env.HudTuner.open)
        local opened
        for _, m in ipairs(env.nui) do if m.action == 'radarTunerOpen' then opened = m end end
        assert_true(opened ~= nil)
        assert_eq(#opened.data.components, 8)
        assert_eq(#callsTo(env, 'SetNuiFocus'), 1)
        env.net['pf-hud:client:radarTuner']()
        assert_false(env.HudTuner.open, 'the same command closes it')
    end)

    it('clamps every value it is sent; a size never reaches zero', function()
        local env = tunerEnv()
        env.net['pf-hud:client:radarTuner']()
        env.HudTuner.set({ key = 'minimap_blur', posX = -9, posY = 4, sizeX = 0, sizeY = 99, rebuild = false })
        local r = env.HudTuner.rect('minimap_blur')
        assert_eq(r[1], -1.0)
        assert_eq(r[2], 1.0)
        assert_eq(r[3], 0.01)
        assert_eq(r[4], 1.5)
        env.HudTuner.set({ key = 'minimap', posX = 'nope', rebuild = false })
        assert_eq(env.HudTuner.rect('minimap')[1], 0.0, 'a value that is not a number is ignored')
        env.HudTuner.set({ key = 'frame', corner = 7, rebuild = false })
        assert_eq(env.HudTuner.rect('frame')[7], 3.0)
        env.HudTuner.set({ key = 'minimap', alignX = 'Q', rebuild = false })
        assert_eq(env.HudTuner.rect('minimap')[5], 'L', 'an anchor the game has not got is ignored')
        assert_false(env.HudTuner.set({ key = 'nothing' }))
        -- live on the game, and on the radar's own table
        assert_eq(env.HudRadar.getRect('minimap_blur')[3], 0.01)
    end)

    it('options are clamped too (clip type 0-3, -1 to leave it)', function()
        local env = tunerEnv()
        env.net['pf-hud:client:radarTuner']()
        env.callbacks.radarTunerOpt({ name = 'clipType', value = 99 }, function() end)
        assert_eq(env.HudRadar.getClip(), 3)
        env.callbacks.radarTunerOpt({ name = 'radarZoom', value = -50 }, function() end)
        env.callbacks.radarTunerOpt({ name = 'evil', value = 1 }, function() end)   -- not an option: ignored
    end)

    it('Save keeps this player\'s tuning, and the next start uses it', function()
        local env = tunerEnv()
        env.net['pf-hud:client:radarTuner']()
        env.HudTuner.set({ key = 'minimap', posX = 0.02, posY = -0.04, sizeX = 0.19, sizeY = 0.21, rebuild = false })
        env.HudTuner.set({ key = 'frame', posX = 0.01, posY = 0.08, sizeX = 0.18, sizeY = 0.17, corner = 1.5, rebuild = false })
        env.callbacks.radarTunerSave({}, function() end)
        local saved = json.decode(env.kvp['pf-hud:radar'])
        assert_near(saved.rects.minimap[1], 0.02, 1e-9)
        assert_near(saved.frame[5], 1.5, 1e-9)

        local again = tunerEnv({ ['pf-hud:radar'] = env.kvp['pf-hud:radar'] })
        local r = again.HudRadar.getRect('minimap')
        assert_near(r[1], 0.02, 1e-9)
        assert_near(r[4], 0.21, 1e-9)
        local f = again.HudSkin.getFrame()
        assert_near(f[1], 0.01, 1e-9)
        assert_near(f[5], 1.5, 1e-9)
    end)

    it('Reset forgets the saved tuning and goes back to the shipped values', function()
        local env = tunerEnv({ ['pf-hud:radar'] = json.encode({ rects = { minimap = { 0.5, 0.5, 0.5, 0.5 } }, clip = 1 }) })
        assert_near(env.HudRadar.getRect('minimap')[1], 0.5, 1e-9)
        env.net['pf-hud:client:radarTuner']()
        env.callbacks.radarTunerReset({ mode = 'forget' }, function() end)
        assert_eq(env.kvp['pf-hud:radar'], nil)
        assert_near(env.HudRadar.getRect('minimap')[1], 0.0, 1e-9)
        assert_eq(env.HudRadar.getClip(), 0)
    end)
end)

-- ── the minimap's look: the dark tiles only with pfm-media-map ───────

local function skinEnv(mediaState)
    local env = clientEnv({ GetResourceState = function(res) return res == 'pfm-media-map' and mediaState or 'missing' end })
    loadInto(env, HUD .. 'config.lua')
    loadInto(env, HUD .. 'client/radar.lua')
    loadInto(env, HUD .. 'client/skin.lua')
    return env
end

local FRAMED = { minimapStyle = 'frame', minimapShape = 'rounded', mapBackground = 100 }

local function tileSwaps(env)
    local out = {}
    for _, a in ipairs(callsTo(env, 'AddReplaceTexture')) do
        if tostring(a[1]):match('^minimap_sea_') then out[#out + 1] = a end
    end
    return out
end

describe('pf-hud swaps GTA\'s radar tiles for the dark map only while pfm-media-map is started', function()
    it('not started: GTA\'s tiles and GTA\'s route colour stay', function()
        local env = skinEnv('missing')
        env.HudSkin.apply(FRAMED, true)
        tick(env, 5)
        assert_eq(#tileSwaps(env), 0)
        assert_eq(#callsTo(env, 'ReplaceHudColourWithRgba'), 0)
        assert_false(env.HudSkin.mapSwapped())
    end)

    it('started: the six tiles (the textures inside keep WHIP\'s names) and the blue route', function()
        local env = skinEnv('started')
        env.HudSkin.apply(FRAMED, true)
        tick(env, 5)
        local swaps = tileSwaps(env)
        assert_eq(#swaps, 6)
        for _, a in ipairs(swaps) do
            local t = a[1]:match('^minimap_sea_(%d_%d)$')
            assert_true(t ~= nil, a[1])
            assert_eq(a[2], a[1])
            assert_eq(a[3], 'pfmap_' .. t)
            assert_eq(a[4], 'whipmap_' .. t)
        end
        local route = callsTo(env, 'ReplaceHudColourWithRgba')
        assert_eq(route[1][1], 142)
        assert_eq(route[1][2], 96)
        assert_eq(route[1][4], 250)
    end)

    it('GTA\'s own look: no swap even with pfm-media-map; switching to it gives the tiles back', function()
        local env = skinEnv('started')
        env.HudSkin.apply({ minimapStyle = 'native', minimapShape = 'rounded' }, true)
        tick(env, 5)
        assert_eq(#tileSwaps(env), 0)
        env.HudSkin.apply(FRAMED, true)
        tick(env, 5)
        assert_eq(#tileSwaps(env), 6)
        env.HudSkin.apply({ minimapStyle = 'native', minimapShape = 'rounded' }, true)
        tick(env, 5)
        local back = 0
        for _, a in ipairs(callsTo(env, 'RemoveReplaceTexture')) do
            if tostring(a[1]):match('^minimap_sea_') then back = back + 1 end
        end
        assert_eq(back, 6)
    end)

    it('not logged in: nothing swapped', function()
        local env = skinEnv('started')
        env.HudSkin.apply(FRAMED, false)
        tick(env, 5)
        assert_eq(#tileSwaps(env), 0)
    end)

    it('the mask is WHIP\'s art (in pf-hud itself) and the frame box goes to the page', function()
        local env = skinEnv('missing')
        env.HudRadar.applyMask('square')
        local mask = callsTo(env, 'AddReplaceTexture')[1]
        assert_eq(mask[1], 'platform:/textures/graphics')
        assert_eq(mask[2], 'radarmasksm')
        assert_eq(mask[3], 'pfmask_square')
        assert_eq(mask[4], 'radarmasksm')
        env.HudSkin.apply(FRAMED, true)
        env.HudSkin.drawFrame()
        local box
        for _, m in ipairs(env.nui) do if m.action == 'hudFrameBox' then box = m end end
        assert_true(box ~= nil, 'the page is told where the frame is')
        local outer = 0.0012 + 0.0034 + 0.0018
        assert_near(box.left, 0.0060 - outer / (16 / 9), 1e-6)
        assert_near(box.bottom, 1 - 0.0700 + outer, 1e-6)
    end)
end)
