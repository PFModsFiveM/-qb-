-- pfm-ui's pad bridge (lib/pad_bridge.lua, ported from WHIP's controller.lua), loaded as a resource
-- includes it. While its page has focus and a pad is the device it keeps input on, holds gameplay
-- controls off and posts intents to its own page; held directions repeat; presses carried in from
-- before the page opened are ignored; on detach (or lost focus, or a keyboard) it gives back
-- SetNuiFocusKeepInput as the resource had it.
load_resource('tests/lua/fivem_mocks.lua')

local S   -- the client's state, reset per test

local function newClient(uiState, uiPrefs)
    S = {
        clock = 0, down = {}, prev = {}, axes = {}, pad = true, focused = true,
        msgs = {}, keep = {}, keepNow = false, disabledAll = 0, enabled = {},
        handlers = {}, threads = 0,
    }
    local env = setmetatable({}, { __index = _G })
    env.GetGameTimer = function() return S.clock end
    env.IsUsingKeyboard = function(i) assert(i == 2) return not S.pad end
    env.IsNuiFocused = function() return S.focused end
    env.IsDisabledControlPressed = function(_, c) return S.down[c] == true end
    env.IsDisabledControlJustPressed = function(_, c) return S.down[c] == true and not S.prev[c] end
    env.GetDisabledControlNormal = function(_, c) return S.axes[c] or 0.0 end
    env.SetNuiFocusKeepInput = function(on) S.keep[#S.keep + 1] = on; S.keepNow = on end
    env.SendNUIMessage = function(m) S.msgs[#S.msgs + 1] = m end
    env.DisableAllControlActions = function() S.disabledAll = S.disabledAll + 1 end
    env.EnableControlAction = function(_, c) S.enabled[c] = true end
    env.CreateThread = function() S.threads = S.threads + 1 end   -- frames are driven by the spec
    env.Wait = function() end
    env.AddEventHandler = function(name, fn) S.handlers[name] = fn end
    env.GetCurrentResourceName = function() return 'pfm-menu' end
    env.GetResourceState = function(name) return name == 'pfm-ui' and (uiState or 'missing') or 'missing' end
    env.exports = setmetatable({}, { __index = function(_, res)
        if res ~= 'pfm-ui' then return nil end
        return { GetPref = function(_, key) return uiPrefs and uiPrefs[key] end }
    end })
    assert(load(__readfile('pfm-ui/lib/pad_bridge.lua'), '@pfm-ui/lib/pad_bridge.lua', 't', env))()
    return env.PadBridge
end

--- One frame after `ms` milliseconds.
local function frame(bridge, ms)
    S.clock = S.clock + (ms or 16)
    bridge._frame()
    S.prev = {}
    for c, v in pairs(S.down) do S.prev[c] = v end
end

local function intents()
    local out = {}
    for _, m in ipairs(S.msgs) do
        if m.action == 'pfm-ui:pad' then out[#out + 1] = m.intent .. (m['repeat'] and '+' or '') end
    end
    return table.concat(out, ' ')
end

local function clearMsgs() S.msgs = {} end

describe('pfm-ui bridge: when it sends', function()
    it('sends nothing for a keyboard player, and never touches keep-input', function()
        local b = newClient()
        S.pad = false
        b.attach()
        S.down[187] = true
        frame(b); frame(b)
        S.down[201] = true
        frame(b)
        assert_eq(intents(), '')
        assert_eq(#S.keep, 0)
        assert_eq(S.disabledAll, 0, 'gameplay controls are left alone for a keyboard')
    end)

    it('tells the page the device on the first frame', function()
        local b = newClient()
        b.attach()
        frame(b)
        assert_eq(S.msgs[1].action, 'pfm-ui:device')
        assert_eq(S.msgs[1].pad, true)
    end)

    it('with a pad and focus: keeps input on, blocks gameplay controls, sends presses', function()
        local b = newClient()
        b.attach()
        frame(b)
        assert_eq(S.keepNow, true)
        assert_true(S.disabledAll > 0)
        S.down[201] = true
        frame(b)
        S.down[201] = nil
        frame(b)
        S.down[202] = true
        frame(b)
        S.down[202] = nil
        S.down[203] = true
        frame(b)
        assert_eq(intents(), 'select back buttonX')
    end)

    it('a press held when the page opened is not a press for it', function()
        local b = newClient()
        S.down[201] = true          -- the A that opened it (pfm-target opens on A held)
        S.down[187] = true          -- the D-pad down that opened the radial
        b.attach()
        frame(b); frame(b); frame(b, 1000)
        assert_eq(intents(), '')
        S.down[201] = nil; S.down[187] = nil
        frame(b)
        S.down[201] = true
        frame(b)
        assert_eq(intents(), 'select', 'after it is let go it works as any press')
    end)

    it('sends nothing without NUI focus, and detaches when focus stays gone', function()
        local b = newClient()
        b.attach()
        frame(b)
        S.focused = false
        S.down[201] = true
        for _ = 1, 5 do frame(b) end
        assert_eq(intents(), '')
        assert_true(b.isAttached(), 'a few frames without focus are allowed')
        for _ = 1, 10 do frame(b) end
        assert_false(b.isAttached())
        assert_eq(S.keepNow, false, 'keep-input given back')
    end)

    it('the stick navigates as well as the D-pad (up is negative on the axis)', function()
        local b = newClient()
        b.attach()
        frame(b)
        S.axes[196] = -0.9
        frame(b)
        S.axes[196] = 0.0
        frame(b)
        S.axes[195] = 0.95
        frame(b)
        assert_eq(intents(), 'up right')
    end)

    it('stick = false (walking in the radial) leaves the stick out of it and keeps walking on', function()
        local b = newClient()
        b.attach({ stick = false, enable = { 30, 31 } })
        frame(b)
        S.axes[196] = -0.9
        frame(b)
        assert_eq(intents(), '')
        assert_true(S.enabled[30] and S.enabled[31])
    end)

    it('onIntent can keep an intent from the page', function()
        local b = newClient()
        local seen = {}
        b.attach({ onIntent = function(i) seen[#seen + 1] = i return i == 'back' end })
        frame(b)
        S.down[202] = true
        frame(b)
        S.down[202] = nil
        S.down[201] = true
        frame(b)
        assert_eq(intents(), 'select')
        assert_eq(table.concat(seen, ' '), 'back select')
    end)
end)

describe('pfm-ui bridge: held directions repeat', function()
    it('fires at once, waits the delay, then repeats at the rate; stops on release', function()
        local b = newClient()
        b.attach()
        frame(b)
        S.down[187] = true
        frame(b, 16)                 -- t=32: press
        frame(b, 200)                -- t=232: inside the delay
        frame(b, 179)                -- t=411: 379 ms down, still inside
        assert_eq(intents(), 'down')
        frame(b, 1)                  -- t=412: 380 ms -> first repeat
        frame(b, 50)                 -- too soon for the next
        frame(b, 60)                 -- 110 ms after the last -> repeat
        assert_eq(intents(), 'down down+ down+')
        local last = S.msgs[#S.msgs]
        assert_eq(last.held, 490, 'held: ms down so far')
        S.down[187] = nil
        frame(b, 500)
        S.down[187] = true
        frame(b)
        assert_eq(intents(), 'down down+ down+ down', 'a new press starts again')
    end)

    it('uses the player settings from pfm-ui when it runs', function()
        local b = newClient('started', { ['pad.repeatDelay'] = 200, ['pad.repeatRate'] = 50 })
        b.attach()
        frame(b)
        S.down[188] = true
        frame(b)
        frame(b, 200)
        frame(b, 50)
        assert_eq(intents(), 'up up+ up+')
    end)

    it('a setting changed while open is heard (pfm-ui:prefChanged)', function()
        local b = newClient()
        b.attach()
        S.handlers['pfm-ui:prefChanged']('pad.repeatDelay', 100)
        frame(b)
        S.down[189] = true
        frame(b)
        frame(b, 100)              -- past the new delay, but not yet the rate (110) since the press
        frame(b, 10)
        assert_eq(intents(), 'left left+')
    end)
end)

describe('pfm-ui bridge: giving input back', function()
    it('detach turns keep-input off again when the bridge turned it on', function()
        local b = newClient()
        b.attach()
        frame(b)
        assert_eq(S.keepNow, true)
        b.detach()
        assert_eq(S.keepNow, false)
        assert_false(b.isAttached())
        clearMsgs()
        S.down[201] = true
        frame(b)
        assert_eq(intents(), '', 'nothing after detach')
    end)

    it('keepInput = true (the resource holds it itself): the bridge never calls it', function()
        local b = newClient()
        b.attach({ keepInput = true })
        frame(b); frame(b)
        b.detach()
        assert_eq(#S.keep, 0)
    end)

    it('the player putting the pad down gives keep-input back and tells the page', function()
        local b = newClient()
        b.attach()
        frame(b)
        S.pad = false
        clearMsgs()
        frame(b)
        assert_eq(S.keepNow, false)
        assert_eq(S.msgs[1].action, 'pfm-ui:device')
        assert_eq(S.msgs[1].pad, false)
        S.down[201] = true
        frame(b)
        assert_eq(intents(), '')
    end)

    it('active() answering false ends it', function()
        local b = newClient()
        local open = true
        b.attach({ active = function() return open end })
        frame(b)
        open = false
        frame(b)
        assert_false(b.isAttached())
        assert_eq(S.keepNow, false)
    end)

    it('controller support switched off (pad.enabled) means no pad at all', function()
        local b = newClient('started', { ['pad.enabled'] = false })
        assert_false(b.padNow())
        b.attach()
        S.down[201] = true
        frame(b)
        assert_eq(intents(), '')
        S.handlers['pfm-ui:prefChanged']('pad.enabled', true)
        assert_true(b.padNow())
    end)

    it('works without pfm-ui running (defaults, the native for the device)', function()
        local b = newClient('missing')
        assert_true(b.padNow())
        S.pad = false
        assert_false(b.padNow())
    end)
end)
