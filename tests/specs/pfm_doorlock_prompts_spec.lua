-- pfm-doorlock with pfm-prompts: every door shows a prompt on itself, "Unlock"/"Lock" beside
-- "Locked"/"Unlocked" for a player who may toggle it, only the state for one who may not; the key goes
-- through the same server path (qb-doorlock:server:updateState) as before; the old toggle binding
-- stands down while prompts run and works as before without them. Both client scripts run for real
-- in their own environments, wired through a mocked export boundary (functions become funcrefs).
load_resource('tests/lua/fivem_mocks.lua')

local function baseEnv(w)
    local env = {}
    env.CreateThread = function(fn)
        local co = coroutine.create(fn)
        local ok, err = coroutine.resume(co)
        if not ok then error(err, 2) end
    end
    env.Wait = function() coroutine.yield() end
    env.SetTimeout = function() end
    env.GetGameTimer = function() return w.now end
    env.PlayerPedId = function() return 1 end
    env.GetEntityCoords = function(ent) if ent == 1 then return w.player end return vector3(0.0, 0.0, 0.0) end
    env.GetResourceState = function(res) return w.resources[res] or 'missing' end
    env.IsPauseMenuActive = function() return false end
    return env
end

local function finish(env)
    return setmetatable(env, { __index = function(_, k)
        local g = _G[k]
        if g ~= nil then return g end
        if type(k) == 'string' and (k:match('^Is') or k:match('^Has') or k:match('^Does') or k:match('^NetworkIs')) then
            return function() return false end
        end
        return function() return 0 end
    end })
end

local function loadInto(env, path) assert(load(__readfile(path), '@' .. path, 't', env))() end

--- pfm-prompts' client, with the natives it reads answered from `w`.
local function promptsEnv(w)
    local env = baseEnv(w)
    env.GetFinalRenderedCamCoord = function() return w.player end
    env.GetFinalRenderedCamRot = function() return w.rot end
    env.GetGameplayCamFov = function() return 50.0 end
    env.GetFrameTime = function() return 0.016 end
    env.GetInvokingResource = function() return w.invoker end
    env.GetCurrentResourceName = function() return 'pfm-prompts' end
    env.IsUsingKeyboard = function() return true end
    env.GetControlInstructionalButton = function() return 't_E' end
    env.IsControlJustPressed = function(_, c) return w.pressed[c] == true end
    env.IsDisabledControlJustPressed = function(_, c) return w.pressed[c] == true end
    env.RegisterCommand = function() end
    env.AddEventHandler = function(name, fn) w.promptEvents[name] = fn end
    env.GetConvar = function() return 'screen' end   -- the fallback renderer: no DUI needed here
    env.DrawRect = function() end
    env.exports = setmetatable({}, { __call = function(_, name, fn) w.promptExports[name] = fn end })
    finish(env)
    for _, f in ipairs({ 'pfm-prompts/config.lua', 'pfm-prompts/client/world_quad.lua', 'pfm-prompts/client/dui_page.lua',
        'pfm-prompts/client/style.lua', 'pfm-prompts/client/keys.lua', 'pfm-prompts/client/registry.lua',
        'pfm-prompts/client/render_world.lua', 'pfm-prompts/client/render_screen.lua', 'pfm-prompts/client/main.lua' }) do
        loadInto(env, f)
    end
    return env
end

--- pfm-doorlock's client, as a player with `job`, its pfm-prompts exports crossing to promptsEnv.
local function doorlockEnv(w, job, doors)
    local env = baseEnv(w)
    env.LocalPlayer = { state = { isLoggedIn = true } }
    env.GetCurrentResourceName = function() return 'pfm-doorlock' end
    env.RegisterNetEvent = function(name, fn) w.net[name] = fn end
    env.AddEventHandler = function(name, fn) w.doorEvents[name] = fn end
    env.RegisterCommand = function(name, fn) w.commands[name] = fn end
    env.SendNUIMessage = function(msg) w.nui[#w.nui + 1] = msg end
    env.TriggerServerEvent = function(name, ...) w.server[#w.server + 1] = { name = name, args = { ... } } end
    env.TriggerEvent = function() end
    env.GetVehiclePedIsIn = function() return 0 end
    -- Doors within 30 m stream in (the proximity loop registers them with the door system).
    env.GetClosestObjectOfType = function() return 123 end
    env.DoesEntityExist = function(ent) return ent == 123 end
    local playerData = {
        source = 7, citizenid = 'CID1', job = { name = job, grade = { level = 0 } }, gang = { name = 'none', grade = { level = 0 } },
        metadata = { isdead = false, inlaststand = false, ishandcuffed = false },
    }
    local core = { Functions = {
        GetPlayerData = function() return playerData end,
        TriggerCallback = function(name, cb, ...) w.callbacks[#w.callbacks + 1] = { name = name, cb = cb, args = { ... } } end,
        Notify = function() end,
    }, Shared = { Round = function(v) return math.floor(v + 0.5) end } }
    local prompts = setmetatable({}, { __index = function(_, fnName)
        return function(_, ...)
            w.promptCalls[#w.promptCalls + 1] = { fn = fnName, args = { ... } }
            w.invoker = 'pfm-doorlock'
            local out = table.pack(Mock.cross(w.promptExports[fnName], ...))
            w.invoker = nil
            return table.unpack(out, 1, out.n)
        end
    end })
    local quiet = setmetatable({}, { __index = function() return function() end end })
    env.exports = setmetatable({}, {
        __call = function() end,
        __index = function(_, res)
            if res == 'pfm-core' then return { GetCoreObject = function() return core end } end
            if res == 'pfm-prompts' then
                if w.resources['pfm-prompts'] ~= 'started' then error('No such export in resource pfm-prompts') end
                return prompts
            end
            return quiet
        end,
    })
    finish(env)
    loadInto(env, 'pfm-core/shared/locale.lua')
    loadInto(env, 'pfm-doorlock/config.lua')
    loadInto(env, 'pfm-doorlock/locales/en.lua')
    env.Config.DoorList = doors
    loadInto(env, 'pfm-doorlock/client/main.lua')
    return env, playerData
end

local function newWorld(promptsStarted)
    return {
        now = 5000, player = vector3(0.0, 0.0, 0.0), rot = vector3(0.0, 0.0, 0.0), pressed = {},
        resources = { ['pfm-prompts'] = promptsStarted and 'started' or 'stopped' },
        net = {}, doorEvents = {}, promptEvents = {}, commands = {}, nui = {}, server = {}, callbacks = {},
        promptExports = {}, promptCalls = {}, invoker = nil,
    }
end

local function doors()
    return {
        ['mrpd-front'] = { objCoords = vector3(0.2, 1.6, 0.0), textCoords = vector3(0.0, 1.5, 0.0), setText = true,
            authorizedJobs = { police = 0 }, locked = true, distance = 2.0 },
        ['vault'] = { objCoords = vector3(40.0, 0.0, 0.0), authorizedJobs = { police = 0 }, locked = true,
            cantUnlock = true, distance = 2.0 },
    }
end

local function score(pEnv, w)
    pEnv.PfmPrompts.scoreSoon()
    w.now = w.now + 100
    pEnv.PfmPrompts.score(w.now)
end

local function entry(pEnv, id)
    return pEnv.PfmPrompts._state().visible['pfm-doorlock:door:' .. id]
end

local function lastAdd(w, id)
    for i = #w.promptCalls, 1, -1 do
        local c = w.promptCalls[i]
        if c.fn == 'Add' and c.args[1] == 'door:' .. id then return c.args[2] end
    end
end

describe('pfm-doorlock door prompts: an authorised player', function()
    local w = newWorld(true)
    local pEnv = promptsEnv(w)
    local dEnv = doorlockEnv(w, 'police', doors())

    it('every configured door gets a prompt at its text coords (else its door coords)', function()
        local def = lastAdd(w, 'mrpd-front')
        assert_true(def ~= nil, 'mrpd-front prompt added')
        assert_near(def.coords.y, 1.5, 1e-6)
        assert_eq(def.label, 'Unlock')
        assert_eq(def.sublabel, 'Locked')
        assert_eq(def.key, 'E')
        assert_eq(def.control, 38)
        assert_eq(def.distance, 2.0)
        local vault = lastAdd(w, 'vault')
        assert_near(vault.coords.x, 40.0, 1e-6, 'no text coords: the door coords')
    end)
    it('the old NUI text box is not shown while prompts run (the door is still tracked for lockpicks)', function()
        for _, m in ipairs(w.nui) do
            assert_false(m.type == 'setDoorText' and m.enable == true, 'no NUI door text')
        end
        assert_eq(dEnv.exports ~= nil, true)
    end)
    it('in reach and looked at: the key with Unlock beside Locked, focused', function()
        score(pEnv, w)
        local e = entry(pEnv, 'mrpd-front')
        assert_true(e ~= nil)
        assert_true(e.actionable)
        assert_true(e.focused)
        assert_eq(e.label, 'Unlock')
        assert_eq(e.sublabel, 'Locked')
        assert_eq(e.glyph, 'E')
    end)
    it('the key sends the server path (updateState) to unlock, as the old binding did', function()
        w.server = {}
        w.pressed[38] = true
        pEnv.PfmPrompts.keys(w.now)
        w.pressed[38] = nil
        assert_eq(#w.server, 1)
        local ev = w.server[1]
        assert_eq(ev.name, 'qb-doorlock:server:updateState')
        assert_eq(ev.args[1], 'mrpd-front')
        assert_eq(ev.args[2], false, 'asks to unlock')
        assert_eq(ev.args[4], false, 'no lockpick claim')
        assert_eq(ev.args[5], false, 'no unlockAnyway claim')
    end)
    it('the old toggle binding stands down while prompts run (no second toggle)', function()
        w.server = {}
        w.commands.toggledoorlock()
        assert_eq(#w.server, 0)
    end)
    it('when the server says unlocked, the prompt turns to Lock beside Unlocked', function()
        w.net['qb-doorlock:client:setState'](99, 'mrpd-front', false, false, false, false)
        local def = lastAdd(w, 'mrpd-front')
        assert_eq(def.label, 'Lock')
        assert_eq(def.sublabel, 'Unlocked')
        assert_eq(def.icon, 'unlock')
        score(pEnv, w)
        assert_eq(entry(pEnv, 'mrpd-front').label, 'Lock')
        w.server = {}
        w.pressed[38] = true
        pEnv.PfmPrompts.keys(w.now)
        w.pressed[38] = nil
        assert_eq(w.server[1].args[2], true, 'asks to lock')
    end)
    it('an unchanged door is not sent again', function()
        local n = #w.promptCalls
        w.net['qb-doorlock:client:setState'](99, 'mrpd-front', false, false, false, false)
        assert_eq(#w.promptCalls, n)
    end)
    it('a door that cannot be unlocked (cantUnlock) shows its state without an action', function()
        w.player = vector3(40.0, -1.5, 0.0)
        score(pEnv, w)
        local e = entry(pEnv, 'vault')
        assert_true(e ~= nil)
        assert_false(e.actionable)
        assert_eq(e.sublabel, 'Locked')
        w.player = vector3(0.0, 0.0, 0.0)
    end)
end)

describe('pfm-doorlock door prompts: an unauthorised player', function()
    local w = newWorld(true)
    local pEnv = promptsEnv(w)
    local dEnv, pd = doorlockEnv(w, 'unemployed', doors())

    it('sees "Locked" without an action, and the key sends nothing', function()
        score(pEnv, w)
        local e = entry(pEnv, 'mrpd-front')
        assert_true(e ~= nil)
        assert_false(e.actionable)
        assert_false(e.focused)
        assert_eq(e.label, '')
        assert_eq(e.sublabel, 'Locked')
        assert_eq(e.glyph, 'lock')
        w.server = {}
        w.pressed[38] = true
        pEnv.PfmPrompts.keys(w.now)
        w.pressed[38] = nil
        assert_eq(#w.server, 0)
    end)
    it('an item door asks the server (read-only checkItems) without waiting, and shows the action once it answers', function()
        dEnv.Config.DoorList['mrpd-front'].items = { keycard = 1 }
        w.callbacks = {}
        score(pEnv, w)
        assert_false(entry(pEnv, 'mrpd-front').actionable, 'no answer yet')
        assert_eq(w.callbacks[1].name, 'qb-doorlock:server:checkItems')
        w.callbacks[1].cb(true)
        score(pEnv, w)
        assert_true(entry(pEnv, 'mrpd-front').actionable)
        assert_eq(#w.callbacks, 1, 'asked once, not every score frame')
    end)
    it('a downed player gets no action even when authorised', function()
        pd.metadata.isdead = true
        score(pEnv, w)
        assert_false(entry(pEnv, 'mrpd-front').actionable)
        pd.metadata.isdead = false
    end)
end)

describe('pfm-doorlock without pfm-prompts', function()
    local w = newWorld(false)
    local dEnv = doorlockEnv(w, 'police', doors())

    it('adds no prompts', function()
        assert_eq(#w.promptCalls, 0)
    end)
    it('the old NUI text box shows at the nearest door, as before', function()
        local shown
        for _, m in ipairs(w.nui) do if m.type == 'setDoorText' and m.enable == true then shown = m.text end end
        assert_eq(shown, '[E] - Locked')
    end)
    it('the toggle binding works as before through the server path', function()
        w.server = {}
        w.commands.toggledoorlock()
        assert_eq(#w.server, 1)
        assert_eq(w.server[1].name, 'qb-doorlock:server:updateState')
        assert_eq(w.server[1].args[1], 'mrpd-front')
        assert_eq(w.server[1].args[2], false)
    end)
    it('pfm-prompts starting later takes over (prompts added, the old text box hidden)', function()
        w.resources['pfm-prompts'] = 'started'
        promptsEnv(w)
        w.nui = {}
        -- (an event handler runs in a thread in FiveM, so it may wait)
        local co = coroutine.create(function() w.doorEvents.onClientResourceStart('pfm-prompts') end)
        for _ = 1, 20 do
            assert(coroutine.resume(co))
            if coroutine.status(co) == 'dead' then break end
        end
        assert_true(lastAdd(w, 'mrpd-front') ~= nil)
        local hid = false
        for _, m in ipairs(w.nui) do if m.type == 'setDoorText' and m.enable == false then hid = true end end
        assert_true(hid)
    end)
end)
