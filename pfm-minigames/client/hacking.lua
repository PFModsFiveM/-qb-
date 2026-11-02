local hacking

local function finish(success, data)
    if not hacking then return end
    SetNuiFocus(false, false)
    local d = type(data) == 'table' and data or {}
    hacking:resolve({ success = success, submits = d.submits, quit = d.userCancelled == true })
    hacking = nil
end

RegisterNuiCallback('hackSuccess', function(data, cb)
    finish(true, data)
    cb('ok')
end)

RegisterNuiCallback('hackFail', function(data, cb)
    finish(false, data)
    cb('ok')
end)

RegisterNuiCallback('hackClosed', function(data, cb)
    finish(false, data)
    cb('ok')
end)

local function run(message)
    hacking = promise.new()
    SetNuiFocus(true, false)
    SendNUIMessage(message)
    return Citizen.Await(hacking)
end

-- Old export: the result is only this client's word (see server/challenge.lua for a checked one).
local function Hacking(solutionsize, timeout)
    return run({ action = 'startHack', solutionsize = solutionsize, timeout = timeout }).success
end
exports('Hacking', Hacking)

PFMinigames = PFMinigames or {}
PFMinigames.Runners = PFMinigames.Runners or {}
PFMinigames.Runners.hacking = function(puzzle)
    local result = run({ action = 'startHack', solutionsize = puzzle.size, timeout = puzzle.seconds, challenge = puzzle })
    return { submits = result.submits, quit = result.quit }
end
