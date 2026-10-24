-- PF gameplay pack (server): bystander CPR

local cprCooldowns = {} -- [targetCitizenid] = os.time() of last completed CPR

local function CprConfig()
    return Config.Gameplay and Config.Gameplay.CPR
end

RegisterNetEvent('hospital:server:RequestCPR', function(targetId)
    local src = source
    local cfg = CprConfig()
    if not cfg or not cfg.Enabled then return end

    local Rescuer = exports['pfm-core']:GetPlayer(src)
    local Target = exports['pfm-core']:GetPlayer(targetId)
    if not Rescuer or not Target then return end

    local rMeta = Rescuer.PlayerData.metadata
    if rMeta['isdead'] or rMeta['inlaststand'] then return end

    local tMeta = Target.PlayerData.metadata
    if not tMeta['isdead'] and not tMeta['inlaststand'] then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.cpr_not_down'), 'error')
        return
    end

    local rescuerPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(targetId)
    if #(GetEntityCoords(rescuerPed) - GetEntityCoords(targetPed)) > 3.0 then return end

    local cid = Target.PlayerData.citizenid
    if cprCooldowns[cid] and os.time() - cprCooldowns[cid] < (cfg.TargetCooldown or 60) then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.cpr_exhausted'), 'error')
        return
    end

    TriggerClientEvent('QBCore:Notify', targetId, Lang:t('info.cpr_being_performed'))
    TriggerClientEvent('hospital:client:StartCPR', src, targetId)
end)

RegisterNetEvent('hospital:server:FinishCPR', function(targetId)
    local src = source
    local cfg = CprConfig()
    if not cfg or not cfg.Enabled then return end

    local Rescuer = exports['pfm-core']:GetPlayer(src)
    local Target = exports['pfm-core']:GetPlayer(targetId)
    if not Rescuer or not Target then return end

    local rescuerPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(targetId)
    if #(GetEntityCoords(rescuerPed) - GetEntityCoords(targetPed)) > 4.0 then return end

    local tMeta = Target.PlayerData.metadata
    local cid = Target.PlayerData.citizenid
    if cprCooldowns[cid] and os.time() - cprCooldowns[cid] < (cfg.TargetCooldown or 60) then return end

    if tMeta['inlaststand'] then
        cprCooldowns[cid] = os.time()
        TriggerClientEvent('hospital:client:ReceiveCPR', Target.PlayerData.source, cfg.AddSeconds or 90)
        TriggerClientEvent('QBCore:Notify', src, Lang:t('success.cpr_stabilized'), 'success')
    elseif tMeta['isdead'] then
        cprCooldowns[cid] = os.time()
        if math.random(100) <= (cfg.MiracleChance or 15) then
            TriggerClientEvent('hospital:client:CPRMiracle', Target.PlayerData.source, cfg.MiracleLaststandTime or 120)
            TriggerClientEvent('QBCore:Notify', src, Lang:t('success.cpr_miracle'), 'success', 7500)
        else
            TriggerClientEvent('QBCore:Notify', src, Lang:t('info.cpr_no_response'), 'error')
        end
    else
        return
    end

    -- let on-duty EMS know someone is working on a patient out there
    if cfg.NotifyEMS then
        local coords = GetEntityCoords(targetPed)
        local players = QBCore.Functions.GetQBPlayers()
        for _, v in pairs(players) do
            if v and v.PlayerData.job.name == 'ambulance' and v.PlayerData.job.onduty then
                TriggerClientEvent('hospital:client:ambulanceAlert', v.PlayerData.source, coords, Lang:t('info.cpr_ems_alert'))
            end
        end
    end
end)

AddEventHandler('playerDropped', function() end)
