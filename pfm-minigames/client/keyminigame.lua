local keyminigame

RegisterNuiCallback('keyminigameExit', function(data, cb)
    if not keyminigame then return cb('ok') end
    SetNuiFocus(false, false)
    local d = type(data) == 'table' and data or {}
    keyminigame:resolve({ quit = true, faults = 0, presses = d.presses })
    keyminigame = nil
    cb('ok')
end)

RegisterNuiCallback('keyminigameFinish', function(data, cb)
    if not keyminigame then return cb('ok') end
    SetNuiFocus(false, false)
    local d = type(data) == 'table' and data or {}
    keyminigame:resolve({ quit = false, faults = d.faults, presses = d.presses })
    keyminigame = nil
    cb('ok')
end)

local function run(message)
    keyminigame = promise.new()
    SetNuiFocus(true, false)
    SendNUIMessage(message)
    return Citizen.Await(keyminigame)
end

-- Old export: the result is only this client's word (see server/challenge.lua for a checked one).
local function KeyMinigame(amount)
    local result = run({ action = 'startKeygame', amount = amount })
    return { quit = result.quit, faults = result.faults }
end
exports('KeyMinigame', KeyMinigame)

PFMinigames = PFMinigames or {}
PFMinigames.Runners = PFMinigames.Runners or {}
PFMinigames.Runners.keys = function(puzzle)
    local result = run({ action = 'startKeygame', amount = puzzle.amount, challenge = puzzle })
    return { quit = result.quit, presses = result.presses }
end
