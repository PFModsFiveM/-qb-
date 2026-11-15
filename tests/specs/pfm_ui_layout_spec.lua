-- pfm-ui in the world (client/pad_state.lua and client/pad_layout.lua, ported from WHIP's
-- controller.lua and pad.lua): the settled device and its broadcast, the button layout (only the
-- player's differences saved), and the buttons running their commands only while a pad is the
-- device and no page has focus. Hold LB is the target key: '+playerTarget' on press, '-' on release.
load_resource('tests/lua/fivem_mocks.lua')

local S, env

local function client(opts)
    opts = opts or {}
    S = {
        clock = 0, down = {}, prev = {}, pad = true, focused = false, paused = false,
        kvp = opts.kvp or {}, events = {}, ran = {}, exported = {}, commands = {}, disabled = {},
        handlers = {},
    }
    local registered = opts.commands or { 'radialmenu', 'openInv', '+playerTarget', '-playerTarget', 'phone', 'playerfocus' }
    env = setmetatable({}, { __index = _G })
    env.GetGameTimer = function() return S.clock end
    env.GetResourceKvpString = function(k) return S.kvp[k] end
    env.SetResourceKvp = function(k, v) S.kvp[k] = v end
    env.DeleteResourceKvp = function(k) S.kvp[k] = nil end
    env.GetConvar = function(_, d) return d end
    env.TriggerEvent = function(name, ...) S.events[#S.events + 1] = { name = name, args = { ... } } end
    env.exports = setmetatable({}, { __call = function(_, name, fn) S.exported[name] = fn end })
    env.CreateThread = function() end
    env.Wait = function() end
    env.print = function() end
    env.RegisterCommand = function(name, fn) S.commands[name] = fn end
    env.AddEventHandler = function(name, fn) S.handlers[name] = fn end
    env.GetRegisteredCommands = function()
        local out = {}
        for _, n in ipairs(registered) do out[#out + 1] = { name = n } end
        return out
    end
    env.ExecuteCommand = function(cmd) S.ran[#S.ran + 1] = cmd end
    env.IsUsingKeyboard = function() return not S.pad end
    env.IsNuiFocused = function() return S.focused end
    env.IsPauseMenuActive = function() return S.paused end
    env.IsDisabledControlPressed = function(_, c) return S.down[c] == true end
    env.IsDisabledControlJustPressed = function(_, c) return S.down[c] == true and not S.prev[c] end
    env.IsDisabledControlJustReleased = function(_, c) return not S.down[c] and S.prev[c] == true end
    env.DisableControlAction = function(_, c) S.disabled[c] = true end
    env.GetCurrentResourceName = function() return 'pfm-ui' end
    env.GetInvokingResource = function() return opts.caller end
    for _, f in ipairs({ 'pfm-ui/config.lua', 'pfm-ui/client/prefs.lua', 'pfm-ui/client/pad_state.lua', 'pfm-ui/client/pad_layout.lua' }) do
        assert(load(__readfile(f), '@' .. f, 't', env))()
    end
    return env
end

local function frame(ms)
    S.clock = S.clock + (ms or 16)
    S.disabled = {}
    env.PadLayout.frame()
    S.prev = {}
    for c, v in pairs(S.down) do S.prev[c] = v end
end

local function tap(control)
    S.down[control] = true
    frame()
    S.down[control] = nil
    frame()
end

local function ran() return table.concat(S.ran, ' ') end

describe('pfm-ui pad state', function()
    it('settles before it broadcasts, and the export answers the settled value', function()
        client()
        S.pad = false
        env.PfmPad.tick(0)
        assert_eq(S.exported.IsPadActive(), false)
        S.pad = true
        env.PfmPad.tick(100)
        env.PfmPad.tick(300)
        assert_eq(S.exported.IsPadActive(), false, 'still settling (300 ms)')
        assert_eq(S.exported.IsPadActiveNow(), true, 'the unsettled reading is immediate')
        env.PfmPad.tick(400)
        assert_eq(S.exported.IsPadActive(), true)
        local e = S.events[#S.events]
        assert_eq(e.name, 'pfm-ui:padChanged')
        assert_eq(e.args[1], true)
    end)

    it('a flapping device does not broadcast', function()
        client()
        S.pad = true
        env.PfmPad.tick(0)
        S.pad = false
        env.PfmPad.tick(100)
        assert_eq(#S.events, 0)
    end)

    it('controller support switched off: never a pad, broadcast at once', function()
        client()
        env.PfmPad.tick(0); env.PfmPad.tick(500)
        assert_eq(S.exported.IsPadActive(), true)
        env.PfmPrefs.set('pad.enabled', false)
        assert_eq(S.exported.IsPadActive(), false)
    end)
end)

describe('pfm-ui layout', function()
    it('the default comes from Config.Pad.Layout', function()
        client()
        local l = env.PadLayout.get()
        assert_eq(l.dpad_up, 'phone')
        assert_eq(l.dpad_down, 'radial')
        assert_eq(l.dpad_left, 'menufocus')
        assert_eq(l.dpad_right, 'inventory')
        assert_eq(l.lb, 'target')
        assert_eq(l.lb_y, 'emotes')
        assert_eq(l.lb_a, false)
        assert_eq(S.kvp['pfm-ui:layout'], nil)
    end)

    it('binding an action swaps it, and only the differences are saved', function()
        client()
        assert_true(env.PadLayout.setSlot('dpad_left', 'emotes'))
        local l = env.PadLayout.get()
        assert_eq(l.dpad_left, 'emotes')
        assert_eq(l.lb_y, 'menufocus', 'the old action went to the button the new one left')
        local saved = json.decode(S.kvp['pfm-ui:layout']).layout
        assert_eq(saved.dpad_left, 'emotes')
        assert_eq(saved.lb_y, 'menufocus')
        assert_eq(saved.dpad_up, nil, 'unchanged buttons are not saved')
        -- swapping back is the default again: nothing kept
        assert_true(env.PadLayout.setSlot('dpad_left', 'menufocus'))
        assert_eq(S.kvp['pfm-ui:layout'], nil)
    end)

    it('the saved layout is read back, and follows the server default elsewhere', function()
        client()
        env.PadLayout.setSlot('lb_x', 'phone')
        local kvp = S.kvp
        client({ kvp = kvp })
        local l = env.PadLayout.get()
        assert_eq(l.lb_x, 'phone')
        assert_eq(l.dpad_up, false, 'phone moved off D-up')
        assert_eq(l.dpad_down, 'radial')
    end)

    it('refuses unknown buttons and actions; reset clears it', function()
        client()
        assert_false(env.PadLayout.setSlot('rb', 'radial'))
        assert_false(env.PadLayout.setSlot('dpad_up', 'fly'))
        env.PadLayout.setSlot('dpad_up', false)
        assert_eq(env.PadLayout.get().dpad_up, false)
        env.PadLayout.reset()
        assert_eq(env.PadLayout.get().dpad_up, 'phone')
        assert_eq(S.kvp['pfm-ui:layout'], nil)
    end)

    it('/padbind and /padreset', function()
        client()
        S.commands.padbind(0, { 'dpad_right', 'none' })
        assert_eq(env.PadLayout.get().dpad_right, false)
        S.commands.padreset(0, {})
        assert_eq(env.PadLayout.get().dpad_right, 'inventory')
    end)
end)

describe('pfm-ui world buttons', function()
    it('a D-pad press runs its command while a pad is the device and no page has focus', function()
        client()
        tap(187)
        assert_eq(ran(), 'radialmenu')
        tap(190)
        assert_eq(ran(), 'radialmenu openInv')
    end)

    it('nothing while a page has focus, the pause menu is open, or the input is a keyboard', function()
        client()
        S.focused = true
        tap(187)
        S.focused, S.paused = false, true
        tap(187)
        S.paused, S.pad = false, false
        tap(187)
        assert_eq(ran(), '')
    end)

    it('an action whose command is not registered does nothing', function()
        client()
        tap(188)                 -- phone is registered
        tap(204)                 -- Y alone has nothing
        S.down[205] = true
        frame()
        tap(204)                 -- LB+Y: emotes, but no 'emotemenu' command
        assert_eq(ran(), 'phone +playerTarget')
    end)

    it('hold LB targets: + on press, - on release; the weapon wheel is held off meanwhile', function()
        client()
        S.down[205] = true
        frame()
        assert_eq(ran(), '+playerTarget')
        frame()
        assert_true(S.disabled[37], 'weapon wheel held off')
        tap(187)                 -- D-pad down with LB held: LB's layer, not the radial
        tap(201)                 -- A with LB held: left to pfm-target (lb_a is free)
        assert_eq(ran(), '+playerTarget')
        S.focused = true         -- the target menu took focus; letting go must still release
        S.down[205] = nil
        frame()
        assert_eq(ran(), '+playerTarget -playerTarget')
    end)

    it('pfm-target in toggle mode: the plain command, nothing on release', function()
        client({ commands = { 'playerTarget' } })
        S.down[205] = true
        frame()
        S.down[205] = nil
        frame()
        assert_eq(ran(), 'playerTarget')
    end)

    it('an LB combo with an action ends the LB hold action first', function()
        client({ commands = { '+playerTarget', 'emotemenu' } })
        S.down[205] = true
        frame()
        tap(204)
        assert_eq(ran(), '+playerTarget -playerTarget emotemenu')
    end)
end)

describe('pfm-ui actions from other resources', function()
    it('RegisterPadAction puts it on the free button it asks for; it goes when its resource stops', function()
        client({ caller = 'pfm-vehiclekeys', commands = { 'engine' } })
        local ok = S.exported.RegisterPadAction('engine', { label = 'Engine', command = 'engine', slot = 'lb_x' })
        assert_true(ok)
        assert_eq(env.PadLayout.get().lb_x, 'engine')
        local slot, name, glyphs = S.exported.GetPadActionButton('engine')
        assert_eq(slot, 'lb_x')
        assert_eq(name, 'LB+X')
        assert_eq(table.concat(glyphs, ','), 'lb,x')
        S.handlers.onResourceStop('pfm-vehiclekeys')
        assert_eq(env.PadLayout.get().lb_x, false)
    end)

    it('a button the default already uses is not taken', function()
        client({ caller = 'x' })
        S.exported.RegisterPadAction('horn', { label = 'Horn', command = 'horn', slot = 'dpad_up' })
        assert_eq(env.PadLayout.get().dpad_up, 'phone')
    end)

    it('bad definitions are refused', function()
        client({ caller = 'x' })
        assert_false(S.exported.RegisterPadAction('radial', { label = 'R', command = 'r' }))
        assert_false(S.exported.RegisterPadAction('a b', { label = 'R', command = 'r' }))
        assert_false(S.exported.RegisterPadAction('ok', { label = 'R' }))
        assert_false(S.exported.RegisterPadAction('ok', { label = 'R', command = 'r', slot = 'zz' }))
    end)
end)
