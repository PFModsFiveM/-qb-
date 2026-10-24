-- PF gameplay pack: bystander CPR
-- Anyone can perform CPR on a downed player: buys bleed-out time in last stand,
-- and has a small chance to pull a fully dead player back into last stand.

local performingCpr = false

local function GetClosestPlayerLocal()
    local closestPlayers = QBCore.Functions.GetPlayersFromCoords()
    local closestDistance = -1
    local closestPlayer = -1
    local coords = GetEntityCoords(PlayerPedId())
    for i = 1, #closestPlayers, 1 do
        if closestPlayers[i] ~= PlayerId() then
            local pos = GetEntityCoords(GetPlayerPed(closestPlayers[i]))
            local distance = #(pos - coords)
            if closestDistance == -1 or closestDistance > distance then
                closestPlayer = closestPlayers[i]
                closestDistance = distance
            end
        end
    end
    return closestPlayer, closestDistance
end

RegisterCommand('cpr', function()
    local cfg = Config.Gameplay and Config.Gameplay.CPR
    if not cfg or not cfg.Enabled then return end
    if performingCpr or isDead or InLaststand then return end
    local player, distance = GetClosestPlayerLocal()
    if player == -1 or distance > 1.8 then
        QBCore.Functions.Notify(Lang:t('error.cpr_nobody'), 'error')
        return
    end
    TriggerServerEvent('hospital:server:RequestCPR', GetPlayerServerId(player))
end, false)

RegisterNetEvent('hospital:client:StartCPR', function(targetId)
    local cfg = Config.Gameplay and Config.Gameplay.CPR
    if not cfg or performingCpr then return end
    performingCpr = true
    local ped = PlayerPedId()
    QBCore.Functions.Progressbar('bystander_cpr', Lang:t('progress.cpr'), cfg.Duration or 15000, false, true, {
        disableMovement = true,
        disableCarMovement = true,
        disableMouse = false,
        disableCombat = true,
    }, {
        animDict = 'mini@cpr@char_a@cpr_str',
        anim = 'cpr_pumpchest',
        flags = 1,
    }, {}, {}, function() -- done
        performingCpr = false
        ClearPedTasks(ped)
        local targetPed = GetPlayerPed(GetPlayerFromServerId(targetId))
        if DoesEntityExist(targetPed) and #(GetEntityCoords(PlayerPedId()) - GetEntityCoords(targetPed)) < 3.0 then
            TriggerServerEvent('hospital:server:FinishCPR', targetId)
        end
    end, function() -- cancel
        performingCpr = false
        ClearPedTasks(ped)
        QBCore.Functions.Notify(Lang:t('error.canceled'), 'error')
    end)
end)

RegisterNetEvent('hospital:client:ReceiveCPR', function(addSeconds)
    if InLaststand then
        LaststandTime = math.min(LaststandTime + (addSeconds or 90), Config.ReviveInterval)
        QBCore.Functions.Notify(Lang:t('info.cpr_received', { seconds = addSeconds or 90 }), 'success')
    end
end)

RegisterNetEvent('hospital:client:CPRMiracle', function(laststandSeconds)
    if not isDead then return end
    local ped = PlayerPedId()
    isDead = false
    deathTime = 0
    TriggerServerEvent('hospital:server:SetDeathStatus', false)
    SetEntityInvincible(ped, false)
    StopAnimTask(ped, 'dead', 'dead_a', 3)
    QBCore.Functions.Notify(Lang:t('info.cpr_miracle'), 'success', 7500)
    SetLaststand(true)
    SetTimeout(1500, function()
        LaststandTime = math.min(laststandSeconds or 120, Config.ReviveInterval)
    end)
end)
