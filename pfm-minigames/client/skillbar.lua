local skillbar

RegisterNUICallback('skillbarFinish', function(data, cb)
    if not skillbar then return cb('ok') end
    SetNuiFocus(false, false)
    skillbar:resolve(type(data) == 'table' and data or {})
    skillbar = nil
    cb('ok')
end)

local function run(message)
    skillbar = promise.new()
    SetNuiFocus(true, false)
    SendNUIMessage(message)
    return Citizen.Await(skillbar)
end

-- Old export: the result is only this client's word (see server/challenge.lua for a checked one).
local function Skillbar(difficulty, validKeys)
    local data = run({
        action = 'openSkillbar',
        difficulty = difficulty or 'easy',
        validKeys = validKeys or '1234'
    })
    return data.success
end
exports('Skillbar', Skillbar)

PFMinigames = PFMinigames or {}
PFMinigames.Runners = PFMinigames.Runners or {}
PFMinigames.Runners.skillbar = function(puzzle)
    local data = run({ action = 'openSkillbar', challenge = puzzle })
    return { presses = data.presses }
end
