local lockpick

RegisterNuiCallback('lockpickExit', function(data, cb)
    if not lockpick then return cb('ok') end
    SetNuiFocus(false, false)
    local d = type(data) == 'table' and data or {}
    lockpick:resolve({ success = false, quit = true, broken = d.broken })
    lockpick = nil
    cb('ok')
end)

RegisterNuiCallback('lockpickFinish', function(data, cb)
    if not lockpick then return cb('ok') end
    SetNuiFocus(false, false)
    lockpick:resolve(type(data) == 'table' and data or {})
    lockpick = nil
    cb('ok')
end)

local function run(message)
    lockpick = promise.new()
    SetNuiFocus(true, true)
    SetCursorLocation(0.5, 0.5)
    SendNUIMessage(message)
    return Citizen.Await(lockpick)
end

-- Old export: the result is only this client's word (see server/challenge.lua for a checked one).
local function Lockpick(pins)
    return run({ action = 'startLockpick', pins = pins }).success
end
exports('Lockpick', Lockpick)

PFMinigames = PFMinigames or {}
PFMinigames.Runners = PFMinigames.Runners or {}
PFMinigames.Runners.lockpick = function(puzzle)
    local r = run({ action = 'startLockpick', pins = puzzle.pins, challenge = puzzle })
    return { success = r.success == true, quit = r.quit == true, a = r.a, ms = r.ms, broken = r.broken }
end
