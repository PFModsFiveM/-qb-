-- pfm-prompts: the in-world prompt registry (add / update / remove, per-resource cleanup), focus
-- (looked-at beats nearest, out of reach is never focused), canInteract hiding the action, the key
-- reaching only the focused prompt (press, hold, cycling options), pad glyphs, and both renderers
-- drawing a frame. DUI and draw natives are stubbed here; nothing in the shared mocks changes.
load_resource('tests/lua/fivem_mocks.lua')

-- A client environment for pfm-prompts: the natives it reads, answered from `w` (the world).
local function promptsEnv()
    local w = {
        now = 1000, player = vector3(0.0, 0.0, 0.0), cam = vector3(0.0, 0.0, 0.0), rot = vector3(0.0, 0.0, 0.0),
        pressed = {}, held = {}, keyboard = true, instructional = {}, resources = {}, invoker = nil,
        server = {}, client = {}, polys = 0, rects = 0, texts = {}, duis = 0, commands = {}, events = {},
        exportsOf = {}, padExport = nil, disabled = {},
    }
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
    env.GetFinalRenderedCamCoord = function() return w.cam end
    env.GetFinalRenderedCamRot = function() return w.rot end
    env.GetGameplayCamFov = function() return 50.0 end
    env.GetFrameTime = function() return 0.016 end
    env.IsPauseMenuActive = function() return false end
    env.GetInvokingResource = function() return w.invoker end
    env.GetCurrentResourceName = function() return 'pfm-prompts' end
    env.GetResourceState = function(res) return w.resources[res] or 'missing' end
    env.IsUsingKeyboard = function() return w.keyboard end
    env.GetControlInstructionalButton = function(_, control) return w.instructional[control] or 't_E' end
    env.IsControlJustPressed = function(_, c) return w.pressed[c] == true end
    env.IsDisabledControlJustPressed = function(_, c) return w.pressed[c] == true end
    env.IsControlPressed = function(_, c) return w.held[c] == true end
    env.IsDisabledControlPressed = function(_, c) return w.held[c] == true end
    env.DisableControlAction = function(_, c) w.disabled[c] = true end
    env.TriggerServerEvent = function(name, ...) w.server[#w.server + 1] = { name = name, args = { ... } } end
    env.TriggerEvent = function(name, ...) w.client[#w.client + 1] = { name = name, args = { ... } } end
    env.RegisterCommand = function(name, fn) w.commands[name] = fn end
    env.AddEventHandler = function(name, fn) w.events[name] = fn end
    env.DoesEntityExist = function(ent) return ent ~= nil and ent ~= 0 end
    env.NetworkDoesNetworkIdExist = function() return false end
    env.GetGamePool = function() return {} end
    -- DUI and drawing
    env.CreateDui = function() w.duis = w.duis + 1; return w.duis end
    env.IsDuiAvailable = function() return true end
    env.GetDuiHandle = function() return 'h' end
    env.CreateRuntimeTxd = function(n) return n end
    env.CreateRuntimeTextureFromDuiHandle = function() end
    env.SendDuiMessage = function() end
    env.DestroyDui = function() end
    env.DrawTexturedPoly = function() w.polys = w.polys + 1 end
    env.DrawRect = function() w.rects = w.rects + 1 end
    env.AddTextComponentSubstringPlayerName = function(s) w.texts[#w.texts + 1] = s end
    env.exports = setmetatable({}, {
        __call = function(_, name, fn) w.exportsOf[name] = fn end,
        __index = function(_, res)
            if res == 'pfm-ui' then return { IsPadActive = function() return w.padExport end } end
            return nil
        end,
    })
    setmetatable(env, { __index = function(_, k)
        local g = _G[k]
        if g ~= nil then return g end
        if type(k) == 'string' and (k:match('^Is') or k:match('^Has') or k:match('^Does')) then
            return function() return false end
        end
        return function() return 0 end
    end })
    for _, f in ipairs({ 'pfm-prompts/config.lua', 'pfm-prompts/client/world_quad.lua', 'pfm-prompts/client/dui_page.lua',
        'pfm-prompts/client/style.lua', 'pfm-prompts/client/keys.lua', 'pfm-prompts/client/registry.lua',
        'pfm-prompts/client/render_world.lua', 'pfm-prompts/client/render_screen.lua', 'pfm-prompts/client/main.lua' }) do
        assert(load(__readfile(f), '@' .. f, 't', env))()
    end
    return env, w
end

-- The camera at `w.cam` looking at a point (GTA's rotation: z = yaw from +y anticlockwise, x = pitch).
local function lookAt(w, x, y, z)
    local dx, dy, dz = x - w.cam.x, y - w.cam.y, z - w.cam.z
    local len = math.sqrt(dx * dx + dy * dy + dz * dz)
    w.rot = vector3(math.deg(math.asin(dz / len)), 0.0, math.deg(math.atan(-dx, dy)))
end

--- Call an export as another resource does: functions in the definition arrive as funcrefs.
local function call(w, env, res, name, ...)
    w.invoker = res
    local out = table.pack(Mock.cross(w.exportsOf[name], ...))
    w.invoker = nil
    return table.unpack(out, 1, out.n)
end

local function score(env, w)
    env.PfmPrompts.scoreSoon()
    env.PromptKeys.reset()
    w.now = w.now + 100
    return env.PfmPrompts.score(w.now)
end

local function visibleBy(env, owner, id)
    return env.PfmPrompts._state().visible[owner .. ':' .. id]
end

describe('pfm-prompts registry', function()
    local env, w = promptsEnv()
    it('exports the API', function()
        for _, n in ipairs({ 'Add', 'Update', 'Remove', 'RemoveAllFor', 'Exists', 'Flash', 'GetFocused' }) do
            assert_true(w.exportsOf[n] ~= nil, n)
        end
    end)
    it('adds a prompt under the calling resource, so two resources may use one id', function()
        assert_true(call(w, env, 'res-a', 'Add', 'door1', { coords = vector3(0.0, 1.5, 0.0), label = 'Unlock' }))
        assert_true(call(w, env, 'res-b', 'Add', 'door1', { coords = vector3(5.0, 1.5, 0.0), label = 'Open' }))
        local reg = env.PfmPrompts._state().registry
        assert_eq(reg['res-a:door1'].options[1].label, 'Unlock')
        assert_eq(reg['res-b:door1'].options[1].label, 'Open')
        assert_true(call(w, env, 'res-a', 'Exists', 'door1'))
        assert_false(call(w, env, 'res-c', 'Exists', 'door1'))
    end)
    it('refuses a definition with nothing to stand on', function()
        local ok = call(w, env, 'res-a', 'Add', 'nowhere', { label = 'x' })
        assert_false(ok)
        assert_eq(env.PfmPrompts._state().registry['res-a:nowhere'], nil)
    end)
    it('updates a prompt: words change, the anchor stays unless the patch moves it', function()
        assert_true(call(w, env, 'res-a', 'Update', 'door1', { label = 'Lock', sublabel = 'Unlocked' }))
        local P = env.PfmPrompts._state().registry['res-a:door1']
        assert_eq(P.options[1].label, 'Lock')
        assert_eq(P.options[1].sublabel, 'Unlocked')
        assert_near(P.y, 1.5, 1e-6)
        assert_true(call(w, env, 'res-a', 'Update', 'door1', { coords = vector3(30.0, 0.0, 0.0) }))
        P = env.PfmPrompts._state().registry['res-a:door1']
        assert_near(P.x, 30.0, 1e-6)
        assert_eq(P.options[1].label, 'Lock', 'words kept')
        assert_eq(P._cell, '1_0', 'moved to its new grid cell')
        assert_false(call(w, env, 'res-c', 'Update', 'door1', { label = 'hijack' }), 'another resource cannot update it')
    end)
    it('removes a prompt (only the owner can)', function()
        assert_false(call(w, env, 'res-b', 'Remove', 'nothere'))
        assert_true(call(w, env, 'res-b', 'Remove', 'door1'))
        assert_eq(env.PfmPrompts._state().registry['res-b:door1'], nil)
        assert_true(env.PfmPrompts._state().registry['res-a:door1'] ~= nil)
    end)
    it("a stopping resource's prompts go with it", function()
        call(w, env, 'res-a', 'Add', 'p2', { coords = vector3(1.0, 1.0, 0.0), label = 'x', onPress = function() end })
        call(w, env, 'res-b', 'Add', 'keep', { coords = vector3(1.0, 1.0, 0.0), label = 'y', onPress = function() end })
        w.events.onResourceStop('res-a')
        local reg = env.PfmPrompts._state().registry
        assert_eq(reg['res-a:door1'], nil)
        assert_eq(reg['res-a:p2'], nil)
        assert_true(reg['res-b:keep'] ~= nil)
        assert_eq(call(w, env, 'res-b', 'RemoveAllFor', 'res-b'), 1)
        assert_eq(next(env.PfmPrompts._state().registry), nil)
        -- the grid is empty again too
        assert_eq(next(env.PfmPrompts._state().grid), nil)
    end)
end)

describe('pfm-prompts focus', function()
    local env, w = promptsEnv()
    local function add(id, x, y, extra)
        local def = { coords = vector3(x, y, 0.0), label = id, distance = 2.0, showDistance = 6.0, onPress = function() end }
        for k, v in pairs(extra or {}) do def[k] = v end
        return call(w, env, 'res', 'Add', id, def)
    end

    it('the prompt looked at beats a nearer one', function()
        add('ahead', 0.0, 1.8)        -- 1.8 m, dead ahead
        add('near', 1.0, 0.5)         -- 1.1 m, 63 degrees off
        lookAt(w, 0.0, 1.8, 0.0)
        score(env, w)
        assert_true(visibleBy(env, 'res', 'ahead').focused)
        assert_false(visibleBy(env, 'res', 'near').focused)
        assert_eq(call(w, env, 'other', 'GetFocused'), 'ahead')
    end)
    it('with nothing in the aim cone, the nearest in reach wins', function()
        call(w, env, 'res', 'Remove', 'ahead'); call(w, env, 'res', 'Remove', 'near')
        add('right', 1.6, 0.9)        -- 1.84 m, 60 degrees off
        add('left', -1.0, 0.6)        -- 1.17 m, 59 degrees off
        lookAt(w, 0.0, 5.0, 0.0)
        score(env, w)
        assert_true(visibleBy(env, 'res', 'left').focused)
        assert_false(visibleBy(env, 'res', 'right').focused)
    end)
    it('out of reach is drawn (idle) but never focused, even dead centre', function()
        call(w, env, 'res', 'Remove', 'right'); call(w, env, 'res', 'Remove', 'left')
        add('far', 0.0, 3.0)
        lookAt(w, 0.0, 3.0, 0.0)
        score(env, w)
        local e = visibleBy(env, 'res', 'far')
        assert_true(e ~= nil, 'drawn')
        assert_false(e.active)
        assert_false(e.focused)
        assert_eq(call(w, env, 'other', 'GetFocused'), nil)
    end)
    it('beyond showDistance or behind the camera is not drawn at all', function()
        add('away', 0.0, 10.0)
        add('behind', 0.0, -1.5)
        lookAt(w, 0.0, 3.0, 0.0)
        score(env, w)
        assert_eq(visibleBy(env, 'res', 'away'), nil)
        assert_eq(visibleBy(env, 'res', 'behind'), nil)
    end)
    it('entity prompts follow their entity', function()
        env.GetEntityCoords = function(ent)
            if ent == 1 then return w.player end
            if ent == 77 then return vector3(0.0, 1.2, 0.5) end
            return vector3(0.0, 0.0, 0.0)
        end
        call(w, env, 'res', 'Add', 'ped', { entity = 77, label = 'Talk', onPress = function() end })
        lookAt(w, 0.0, 1.2, 0.5)
        score(env, w)
        local e = visibleBy(env, 'res', 'ped')
        assert_true(e ~= nil and e.focused)
        assert_near(e.z, 0.5, 1e-6)
    end)
end)

describe('pfm-prompts canInteract and keys', function()
    local env, w = promptsEnv()
    local pressed = {}
    local allow = false
    call(w, env, 'res', 'Add', 'door', {
        coords = vector3(0.0, 1.5, 0.0), label = 'Unlock', sublabel = 'Locked', icon = 'lock',
        canInteract = function() return allow end,
        onPress = function(id) pressed[#pressed + 1] = id end,
    })
    lookAt(w, 0.0, 1.5, 0.0)

    it('canInteract false hides the action: the sublabel stays, no key, not focusable', function()
        allow = false
        score(env, w)
        local e = visibleBy(env, 'res', 'door')
        assert_true(e ~= nil)
        assert_false(e.actionable)
        assert_false(e.focused)
        assert_eq(e.label, '')
        assert_eq(e.sublabel, 'Locked')
        assert_eq(e.glyph, 'lock', 'the badge shows the icon, not a key')
        assert_true(e.wantLabel, 'its words show in reach')
        w.pressed[38] = true
        env.PfmPrompts.keys(w.now)
        w.pressed[38] = nil
        assert_eq(#pressed, 0)
    end)
    it('a prompt with nothing to press and nothing to say is not drawn', function()
        call(w, env, 'res', 'Add', 'mute', { coords = vector3(0.5, 1.5, 0.0), label = 'Search',
            canInteract = function() return false end, onPress = function() end })
        score(env, w)
        assert_eq(visibleBy(env, 'res', 'mute'), nil)
        call(w, env, 'res', 'Remove', 'mute')
    end)
    it('canInteract true shows the key and the action', function()
        allow = true
        score(env, w)
        local e = visibleBy(env, 'res', 'door')
        assert_true(e.actionable)
        assert_true(e.focused)
        assert_eq(e.label, 'Unlock')
        assert_eq(e.glyph, 'E')
    end)
    it('the key fires onPress for the focused prompt only', function()
        local other = 0
        call(w, env, 'res', 'Add', 'side', { coords = vector3(1.2, 0.8, 0.0), label = 'Other',
            onPress = function() other = other + 1 end })
        score(env, w)
        assert_true(visibleBy(env, 'res', 'side').active)
        assert_false(visibleBy(env, 'res', 'side').focused)
        w.pressed[38] = true
        env.PfmPrompts.keys(w.now)
        w.pressed[38] = nil
        assert_eq(#pressed, 1)
        assert_eq(pressed[1], 'door')
        assert_eq(other, 0)
        call(w, env, 'res', 'Remove', 'side')
    end)
    it('a different control than the prompt asks for does nothing', function()
        w.pressed[51] = true
        env.PfmPrompts.keys(w.now)
        w.pressed[51] = nil
        assert_eq(#pressed, 1)
    end)
    it('canInteract is asked again at the press', function()
        score(env, w)
        allow = false
        w.pressed[38] = true
        env.PfmPrompts.keys(w.now)
        w.pressed[38] = nil
        assert_eq(#pressed, 1)
        allow = true
    end)
    it('a server event name is triggered with its args', function()
        call(w, env, 'res', 'Update', 'door', { onPress = 'my:server:open', args = { 'a', 2 } })
        score(env, w)
        w.pressed[38] = true
        env.PfmPrompts.keys(w.now)
        w.pressed[38] = nil
        local last = w.server[#w.server]
        assert_eq(last.name, 'my:server:open')
        assert_eq(last.args[1], 'a')
        assert_eq(last.args[2], 2)
    end)
    it('a hold fires only once the key was held long enough', function()
        local fired = 0
        call(w, env, 'res', 'Update', 'door', { onPress = function() fired = fired + 1 end, holdMs = 500 })
        score(env, w)
        w.pressed[38] = true; w.held[38] = true
        env.PfmPrompts.keys(w.now)
        w.pressed[38] = nil
        assert_eq(fired, 0)
        w.now = w.now + 200
        env.PfmPrompts.keys(w.now)
        assert_eq(fired, 0)
        assert_true(visibleBy(env, 'res', 'door').holdP > 0.3)
        w.now = w.now + 400
        env.PfmPrompts.keys(w.now)
        assert_eq(fired, 1)
        -- let go early: nothing
        w.pressed[38] = true
        env.PfmPrompts.keys(w.now)
        w.pressed[38] = nil; w.held[38] = nil
        w.now = w.now + 600
        env.PfmPrompts.keys(w.now)
        assert_eq(fired, 1)
    end)
    it('options cycle with the wheel (16 next, 17 previous) and the key acts on the selected one', function()
        local got = {}
        call(w, env, 'res', 'Update', 'door', { holdMs = false, options = {
            { label = 'Lock', onPress = function() got[#got + 1] = 'lock' end },
            { label = 'Lockpick', key = 'G', control = 47, onPress = function() got[#got + 1] = 'pick' end },
        } })
        score(env, w)
        local e = visibleBy(env, 'res', 'door')
        assert_eq(e.availN, 2)
        assert_eq(e.label, 'Lock')
        w.pressed[16] = true
        env.PfmPrompts.keys(w.now)
        w.pressed[16] = nil
        assert_true(w.disabled[16] and w.disabled[17], 'the weapon wheel is held off while cycling')
        score(env, w)
        e = visibleBy(env, 'res', 'door')
        assert_eq(e.sel, 2)
        assert_eq(e.label, 'Lockpick')
        w.instructional[47] = 't_G'
        env.PromptKeys.reset()
        score(env, w)
        assert_eq(visibleBy(env, 'res', 'door').glyph, 'G')
        w.pressed[38] = true
        env.PfmPrompts.keys(w.now)
        w.pressed[38] = nil
        assert_eq(#got, 0, 'E does not fire the G option')
        w.pressed[47] = true
        env.PfmPrompts.keys(w.now)
        w.pressed[47] = nil
        assert_eq(got[1], 'pick')
        w.pressed[17] = true
        env.PfmPrompts.keys(w.now)
        w.pressed[17] = nil
        score(env, w)
        assert_eq(visibleBy(env, 'res', 'door').label, 'Lock')
    end)
    it('a throwing callback counts as "no" and does not stop the loop', function()
        call(w, env, 'res', 'Add', 'bad', { coords = vector3(0.3, 1.5, 0.0), label = 'Bad', sublabel = 'x',
            canInteract = function() error('boom') end, onPress = function() end })
        score(env, w)
        assert_false(visibleBy(env, 'res', 'bad').actionable)
        call(w, env, 'res', 'Remove', 'bad')
    end)
end)

describe('pfm-prompts pad glyphs', function()
    local env, w = promptsEnv()
    call(w, env, 'res', 'Add', 'p', { coords = vector3(0.0, 1.5, 0.0), label = 'Use', onPress = function() end })
    lookAt(w, 0.0, 1.5, 0.0)
    it('keyboard: the key the game reports', function()
        w.instructional[38] = 't_E'
        score(env, w)
        assert_eq(visibleBy(env, 'res', 'p').glyph, 'E')
    end)
    it('pad (IsUsingKeyboard false, pfm-ui not started): the default pad button for control 38', function()
        w.keyboard = false
        w.instructional[38] = 'b_1001'
        score(env, w)
        assert_eq(visibleBy(env, 'res', 'p').glyph, 'pad_lb')
    end)
    it('pfm-ui decides when it is started, and Config.PadButtonIds overrides by button id', function()
        w.keyboard = false
        w.resources['pfm-ui'] = 'started'
        w.padExport = false
        score(env, w)
        assert_eq(visibleBy(env, 'res', 'p').glyph, 'E', 'pfm-ui says keyboard')
        w.padExport = true
        env.Config.PadButtonIds['b_1001'] = 'pad_rb'
        score(env, w)
        assert_eq(visibleBy(env, 'res', 'p').glyph, 'pad_rb')
        env.Config.PadButtonIds['b_1001'] = nil
    end)
    it('context (51) is the D-pad right on a pad', function()
        assert_eq(env.PromptKeys.padDefault(51), 'pad_right')
    end)
end)

describe('pfm-prompts renderers', function()
    local env, w = promptsEnv()
    call(w, env, 'res', 'Add', 'a', { coords = vector3(0.0, 1.5, 0.0), label = 'Open', sublabel = 'Closed', onPress = function() end })
    call(w, env, 'res', 'Add', 'b', { coords = vector3(0.0, 4.5, 0.0), label = 'Far', onPress = function() end })
    lookAt(w, 0.0, 1.5, 0.0)

    it('the world renderer is chosen and makes at most three browsers', function()
        assert_eq(env.PfmPrompts.renderer.name, 'world')
        assert_true(w.duis <= 3)
    end)
    it('draws textured quads for every visible prompt and a label for the focused one', function()
        env.PfmPrompts.scoreSoon()
        for _ = 1, 30 do
            w.now = w.now + 16
            env.PfmPrompts.tick(w.now)
        end
        assert_true(w.polys > 0)
        local st = env.PromptRenderers.world._state()
        assert_true(st.fx['res:a'] ~= nil and st.fx['res:b'] ~= nil)
        assert_true(st.fx['res:a']._row ~= nil, 'the focused prompt holds a label row')
        assert_eq(st.fx['res:b']._row, nil, 'the distant one does not')
        assert_true(st.keyCols.E ~= nil)
    end)
    it('everything removed: the prompts fade and the rows go back', function()
        call(w, env, 'res', 'RemoveAllFor', 'res')
        for _ = 1, 60 do
            w.now = w.now + 16
            env.PfmPrompts.tick(w.now)
        end
        local st = env.PromptRenderers.world._state()
        assert_eq(next(st.fx), nil)
        for i = 1, #st.rows do assert_eq(st.rows[i].id, nil) end
    end)
    it('the screen fallback draws text at the prompt', function()
        w.commands.pfmprompts_renderer(0, { 'screen' })
        assert_eq(env.PfmPrompts.renderer.name, 'screen')
        call(w, env, 'res', 'Add', 'a', { coords = vector3(0.0, 1.5, 0.0), label = 'Open', sublabel = 'Closed', onPress = function() end })
        w.texts = {}
        for _ = 1, 10 do
            w.now = w.now + 16
            env.PfmPrompts.tick(w.now)
        end
        local saw = {}
        for _, t in ipairs(w.texts) do saw[t] = true end
        assert_true(saw.Open and saw.Closed and saw.E, 'label, sublabel and key drawn')
    end)
    it('the game refusing the badge texture falls back to the screen renderer', function()
        local env2, w2 = promptsEnv()
        assert_eq(env2.PfmPrompts.renderer.name, 'world')
        env2.CreateDui = function() error('Invalid Width [1, 8]') end
        env2.PromptRenderers.world.detach()
        w2.commands.pfmprompts_renderer(0, { 'world' })
        assert_eq(env2.PfmPrompts.renderer.name, 'screen')
    end)
end)
