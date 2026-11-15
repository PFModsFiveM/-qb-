-- Copyright (c) 2026 Whippy, from WHIP, LGPL-3.0; modified for PF.
-- Device detection ported from whip_core/client/controller.lua. Free software under the GNU Lesser
-- General Public License 3.0 (see COPYING.LESSER and COPYING in this resource).
--
-- The one answer to "is the player using a gamepad": exports['pfm-ui']:IsPadActive(), and the
-- local event 'pfm-ui:padChanged' (pad: boolean) when it changes. The answer is settled for
-- Config.Pad.SettleMs before it is broadcast; IsPadActiveNow() is the unsettled reading, for a
-- press that has to know what it means right now.

PfmPad = PfmPad or {}

--- True when the last input came from a gamepad, and controller support is on.
--- The native has two names; index 2 asks about the last input method.
function PfmPad.now()
    if PfmPrefs and PfmPrefs.get('pad.enabled') == false then return false end
    if IsUsingKeyboard then return not IsUsingKeyboard(2) end
    if IsInputDisabled then return not IsInputDisabled(2) end
    return false
end

local settled = false
local disagreeingSince = nil

local function settleMs()
    return (Config.Pad and tonumber(Config.Pad.SettleMs)) or 300
end

local function publish(value)
    settled = value
    disagreeingSince = nil
    TriggerEvent('pfm-ui:padChanged', value)
end

--- One look at the device. `force` publishes a change at once (a setting changed).
function PfmPad.tick(now, force)
    local reading = PfmPad.now()
    if reading == settled then
        disagreeingSince = nil
        return settled
    end
    if force then publish(reading) return settled end
    if not disagreeingSince then
        disagreeingSince = now
        return settled
    end
    if now - disagreeingSince >= settleMs() then publish(reading) end
    return settled
end

function PfmPad.isActive()
    return settled
end

exports('IsPadActive', function() return settled end)
exports('IsPadActiveNow', function() return PfmPad.now() end)

if PfmPrefs then
    PfmPrefs.onChange('pad.enabled', function() PfmPad.tick(GetGameTimer(), true) end)
end

CreateThread(function()
    while true do
        PfmPad.tick(GetGameTimer())
        Wait(100)
    end
end)
