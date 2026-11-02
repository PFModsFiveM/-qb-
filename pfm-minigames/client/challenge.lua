-- Plays a challenge the server issued (server/challenge.lua) and hands the answer back to it.
-- Each game file registers a runner in PFMinigames.Runners[kind]: it plays the puzzle in the NUI
-- and returns the raw answer (key presses, submits, angles with their timings). The server judges
-- it; this file only waits for that verdict.

PFMinigames = PFMinigames or {}
PFMinigames.Runners = PFMinigames.Runners or {}

local VERDICT_WAIT_MS = 5000
local verdicts = {} -- [id] = promise
local playing = false -- one challenge at a time: the games share the NUI

RegisterNetEvent('pfm-minigames:client:verdict', function(id, passed, faults)
    local p = type(id) == 'string' and verdicts[id]
    if not p then return end
    verdicts[id] = nil
    p:resolve({ passed = passed == true, faults = tonumber(faults) or 0 })
end)

--- Plays `challenge` ({ id, kind, puzzle } from IssueChallenge) and returns passed, faults as the
--- server judged them (false when no verdict arrives).
local function PlayChallenge(challenge)
    if type(challenge) ~= 'table' or type(challenge.id) ~= 'string' or type(challenge.puzzle) ~= 'table' then
        return false, 0
    end
    local runner = PFMinigames.Runners[challenge.kind]
    if not runner or playing then return false, 0 end

    playing = true
    local ok, answer = pcall(runner, challenge.puzzle)
    playing = false
    answer = ok and type(answer) == 'table' and answer or {}
    local p = promise.new()
    verdicts[challenge.id] = p
    TriggerServerEvent('pfm-minigames:server:answer', challenge.id, answer)
    SetTimeout(VERDICT_WAIT_MS, function()
        if verdicts[challenge.id] ~= p then return end
        verdicts[challenge.id] = nil
        p:resolve({ passed = false, faults = 0 })
    end)
    local verdict = Citizen.Await(p)
    return verdict.passed, verdict.faults
end
exports('PlayChallenge', PlayChallenge)
