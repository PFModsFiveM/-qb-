-- Copyright (c) 2026 Whippy, from WHIP, LGPL-3.0; modified for PF.
-- Port of whip_core/client/controller.lua (the NUI pad driver). Free software under the GNU Lesser
-- General Public License 3.0 (see COPYING.LESSER and COPYING in the pfm-ui resource).
--
-- A client library: a resource includes it with '@pfm-ui/lib/pad_bridge.lua' in client_scripts.
-- A NUI page cannot read a gamepad (no Gamepad API in FiveM's frames) and SendNUIMessage only reaches
-- the calling resource's own page, so each resource reads the pad for its own page:
--
--     SetNuiFocus(true, true)
--     PadBridge.attach({ active = function() return menuOpen end })
--     ...
--     SetNuiFocus(false, false)
--     PadBridge.detach()
--
-- While attached, the page has focus and the last input is a pad, this keeps game input flowing
-- (SetNuiFocusKeepInput), holds gameplay controls off, reads the frontend controls through the
-- Disabled readers and posts { action = 'pfm-ui:pad', intent, repeat, held } to the page.
-- A keyboard player gets nothing from it: their keys already reach the page.
--
-- attach options:
--   active     function: false ends the bridge (checked every frame)
--   keepInput  true when the resource already keeps input on itself (the bridge then never touches it)
--   block      false: do not hold gameplay controls off (default true: all of them)
--   enable     control ids to leave on while blocking (walking: { 30, 31 })
--   stick      false: the left stick does not navigate (default: the player's setting)
--   onIntent   function(intent, isRepeat): return true to keep an intent from the page
-- Works without pfm-ui running (defaults, and the native for the device).

PadBridge = PadBridge or {}

--- Directions repeat while held; everything else fires once per press.
local NAV_HELD = {
    { nav = 'up',    control = 188 },
    { nav = 'down',  control = 187 },
    { nav = 'left',  control = 189 },
    { nav = 'right', control = 190 },
}
local NAV_PRESS = {
    { nav = 'select',       control = 201 },  -- A
    { nav = 'back',         control = 202 },  -- B
    { nav = 'buttonX',      control = 203 },  -- X
    { nav = 'buttonY',      control = 204 },  -- Y
    { nav = 'tabPrev',      control = 205 },  -- LB
    { nav = 'tabNext',      control = 206 },  -- RB
    { nav = 'triggerLeft',  control = 207 },  -- LT
    { nav = 'triggerRight', control = 208 },  -- RT
}

local AXIS_X, AXIS_Y = 195, 196
local STICK_DEADZONE = 0.6
local STICK_UP_SIGN = -1     -- GTA reports stick-up as negative

local DEFAULT_DELAY, DEFAULT_RATE = 380, 110
local UNFOCUSED_FRAMES = 10  -- this many frames without NUI focus ends the bridge

local attached, looping = false, false
local opts = {}
local holding = false        -- this bridge turned SetNuiFocusKeepInput on
local first = false          -- the next frame is the panel's first: what is down then is carried
local padWas = nil           -- what the page was last told about the device
local unfocused = 0
local delay, rate, stickNav = DEFAULT_DELAY, DEFAULT_RATE, true
local heldSince, lastFired, carried, carriedPress = {}, {}, {}, {}

local enabled = nil          -- pfm-ui's pad.enabled, read lazily

local function uiRunning()
    return GetResourceState ~= nil and GetResourceState('pfm-ui') == 'started'
end

local function pref(key, default)
    if not uiRunning() then return default end
    local ok, v = pcall(function() return exports['pfm-ui']:GetPref(key) end)
    if ok and v ~= nil then return v end
    return default
end

AddEventHandler('pfm-ui:prefChanged', function(key, value)
    if key == 'pad.enabled' then enabled = value ~= false
    elseif key == 'pad.repeatDelay' then delay = tonumber(value) or DEFAULT_DELAY
    elseif key == 'pad.repeatRate' then rate = tonumber(value) or DEFAULT_RATE
    elseif key == 'pad.stickNav' then stickNav = value ~= false end
end)

--- Is the last input a pad right now (and controller support on)? Asked at the press, not settled.
function PadBridge.padNow()
    if enabled == nil then enabled = pref('pad.enabled', true) ~= false end
    if not enabled then return false end
    if IsUsingKeyboard then return not IsUsingKeyboard(2) end
    if IsInputDisabled then return not IsInputDisabled(2) end
    return false
end

local function resetRepeats()
    for i = 1, #NAV_HELD do
        local n = NAV_HELD[i].nav
        heldSince[n], lastFired[n], carried[n] = nil, nil, nil
    end
    for i = 1, #NAV_PRESS do carriedPress[NAV_PRESS[i].control] = nil end
end

--- Give back SetNuiFocusKeepInput as the resource had it.
local function release()
    if not holding then return end
    holding = false
    if not opts.keepInput then SetNuiFocusKeepInput(false) end
end

local function send(intent, isRepeat, held)
    if opts.onIntent then
        local ok, swallow = pcall(opts.onIntent, intent, isRepeat)
        if ok and swallow == true then return end
    end
    SendNUIMessage({ action = 'pfm-ui:pad', intent = intent, ['repeat'] = isRepeat == true, held = held or 0 })
end

local function directionHeld(nav, control, x, y)
    if IsDisabledControlPressed(0, control) then return true end
    if nav == 'left' then return x < -STICK_DEADZONE end
    if nav == 'right' then return x > STICK_DEADZONE end
    if nav == 'up' then return y > STICK_DEADZONE end
    return y < -STICK_DEADZONE
end

--- One frame. The loop calls it while attached; specs call it directly.
function PadBridge._frame()
    if not attached then return end
    if opts.active then
        local ok, still = pcall(opts.active)
        if not ok or not still then return PadBridge.detach() end
    end
    if IsNuiFocused then
        if IsNuiFocused() then unfocused = 0
        else
            unfocused = unfocused + 1
            if unfocused > UNFOCUSED_FRAMES then return PadBridge.detach() end
            return
        end
    end

    local pad = PadBridge.padNow()
    if pad ~= padWas then
        padWas = pad
        SendNUIMessage({ action = 'pfm-ui:device', pad = pad })
    end

    local fresh = first
    first = false

    if not pad then
        release()
        resetRepeats()
        return
    end

    if not holding then
        holding = true
        if not opts.keepInput then SetNuiFocusKeepInput(true) end
    end

    if opts.block then
        DisableAllControlActions(0)
        if opts.enable then
            for i = 1, #opts.enable do EnableControlAction(0, opts.enable[i], true) end
        end
    end

    local now = GetGameTimer()
    local sx, sy = 0.0, 0.0
    if opts.stick and stickNav then
        sx = GetDisabledControlNormal(0, AXIS_X) or 0.0
        sy = (GetDisabledControlNormal(0, AXIS_Y) or 0.0) * STICK_UP_SIGN
    end

    for i = 1, #NAV_HELD do
        local d = NAV_HELD[i]
        local down = directionHeld(d.nav, d.control, sx, sy)
        if fresh and down then carried[d.nav] = true end
        if carried[d.nav] then
            -- down since before the panel opened: nothing until it is let go
            if not down then carried[d.nav] = nil end
        elseif down then
            local since = heldSince[d.nav]
            if not since then
                heldSince[d.nav], lastFired[d.nav] = now, now
                send(d.nav, false, 0)
            elseif now - since >= delay and now - (lastFired[d.nav] or 0) >= rate then
                lastFired[d.nav] = now
                send(d.nav, true, now - since)
            end
        else
            heldSince[d.nav], lastFired[d.nav] = nil, nil
        end
    end

    for i = 1, #NAV_PRESS do
        local b = NAV_PRESS[i]
        if fresh and IsDisabledControlPressed(0, b.control) then carriedPress[b.control] = true end
        if carriedPress[b.control] then
            if not IsDisabledControlPressed(0, b.control) then carriedPress[b.control] = nil end
        elseif IsDisabledControlJustPressed(0, b.control) then
            send(b.nav, false, 0)
        end
    end
end

--- Start reading the pad for this resource's page. Calling it again while attached updates the options.
function PadBridge.attach(o)
    o = type(o) == 'table' and o or {}
    local wasAttached = attached
    -- the resource's own keep-input setting changed: the next frame takes it from there
    if wasAttached and opts.keepInput ~= (o.keepInput == true) then holding = false end
    opts = {
        active = o.active,
        keepInput = o.keepInput == true,
        block = o.block ~= false,
        enable = type(o.enable) == 'table' and o.enable or nil,
        stick = o.stick ~= false,
        onIntent = o.onIntent,
    }
    enabled = pref('pad.enabled', true) ~= false
    delay = tonumber(pref('pad.repeatDelay', DEFAULT_DELAY)) or DEFAULT_DELAY
    rate = tonumber(pref('pad.repeatRate', DEFAULT_RATE)) or DEFAULT_RATE
    stickNav = pref('pad.stickNav', true) ~= false
    attached = true
    unfocused = 0
    if not wasAttached then
        first = true
        padWas = nil
        resetRepeats()
    end
    if not looping then
        looping = true
        CreateThread(function()
            while attached do
                PadBridge._frame()
                Wait(0)
            end
            looping = false
        end)
    end
end

--- Stop: give back the input setting and forget held buttons.
function PadBridge.detach()
    if not attached then return end
    attached = false
    release()
    resetRepeats()
end

function PadBridge.isAttached()
    return attached
end

--- The resource changed SetNuiFocusKeepInput itself while attached.
function PadBridge.setKeepInput(on)
    on = on == true
    if opts.keepInput == on then return end
    opts.keepInput = on
    -- on: the resource holds it now; off: the next pad frame turns it on again for the bridge
    holding = false
end

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then PadBridge.detach() end
end)
