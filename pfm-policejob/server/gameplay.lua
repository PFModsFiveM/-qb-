-- PF gameplay pack (server): tackle, GSR, panic button

local function IsOnDutyLeo(Player)
    return Player and Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty
end

-- ══ Tackle ═══════════════════════════════════════════════════════
local tackleCooldowns = {}

RegisterNetEvent('police:server:Tackle', function(targetId)
    local src = source
    local cfg = Config.Gameplay and Config.Gameplay.Tackle
    if not cfg or not cfg.Enabled then return end

    local Player = exports['pfm-core']:GetPlayer(src)
    local Target = exports['pfm-core']:GetPlayer(targetId)
    if not Player or not Target then return end
    if not IsOnDutyLeo(Player) then return end

    local now = GetGameTimer()
    if tackleCooldowns[src] and now - tackleCooldowns[src] < (cfg.Cooldown or 15000) then return end

    local playerPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(targetId)
    if #(GetEntityCoords(playerPed) - GetEntityCoords(targetPed)) > 3.5 then return end

    tackleCooldowns[src] = now
    TriggerClientEvent('police:client:TackleDive', src)
    TriggerClientEvent('police:client:TackleTarget', Target.PlayerData.source, src)
end)

-- ══ GSR ═══════════════════════════════════════════════════════════
local gsrReports = {}

RegisterNetEvent('police:server:MarkGSR', function()
    local src = source
    local cfg = Config.Gameplay and Config.Gameplay.GSR
    if not cfg or not cfg.Enabled then return end
    local now = os.time()
    if gsrReports[src] and now - gsrReports[src] < 5 then return end
    gsrReports[src] = now
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    Player.Functions.SetMetaData('gsr', now)
end)

RegisterNetEvent('police:server:GsrTest', function(targetId)
    local src = source
    local cfg = Config.Gameplay and Config.Gameplay.GSR
    if not cfg or not cfg.Enabled then return end

    local Player = exports['pfm-core']:GetPlayer(src)
    local Target = exports['pfm-core']:GetPlayer(targetId)
    if not Player or not Target then return end
    if not IsOnDutyLeo(Player) then return end

    local playerPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(targetId)
    if #(GetEntityCoords(playerPed) - GetEntityCoords(targetPed)) > 5.0 then return end

    local firedAt = tonumber(Target.PlayerData.metadata['gsr']) or 0
    local positive = firedAt > 0 and (os.time() - firedAt) < (cfg.PositiveSeconds or 2700)
    local name = ('%s %s'):format(Target.PlayerData.charinfo.firstname, Target.PlayerData.charinfo.lastname)
    if positive then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('info.gsr_positive', { player = name }), 'error', 7500)
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('info.gsr_negative', { player = name }), 'success', 7500)
    end
    TriggerClientEvent('QBCore:Notify', Target.PlayerData.source, Lang:t('info.gsr_swabbed'))
end)

QBCore.Commands.Add('gsr', Lang:t('commands.gsr'), {}, false, function(source)
    local Player = exports['pfm-core']:GetPlayer(source)
    if not IsOnDutyLeo(Player) then
        TriggerClientEvent('QBCore:Notify', source, Lang:t('error.on_duty_police_only'), 'error')
        return
    end
    TriggerClientEvent('police:client:DoGSR', source)
end)

-- ══ Panic button ═════════════════════════════════════════════════
local panicCooldowns = {}

RegisterNetEvent('police:server:Panic', function()
    local src = source
    local cfg = Config.Gameplay and Config.Gameplay.Panic
    if not cfg or not cfg.Enabled then return end

    local Player = exports['pfm-core']:GetPlayer(src)
    if not IsOnDutyLeo(Player) then return end

    local now = GetGameTimer()
    if panicCooldowns[src] and now - panicCooldowns[src] < (cfg.Cooldown or 60000) then return end
    panicCooldowns[src] = now

    local coords = GetEntityCoords(GetPlayerPed(src))
    local callsign = Player.PlayerData.metadata['callsign'] or 'UNKNOWN'
    local players = QBCore.Functions.GetQBPlayers()
    for _, v in pairs(players) do
        if v and v.PlayerData.job.type == 'leo' and v.PlayerData.job.onduty then
            TriggerClientEvent('police:client:PanicAlert', v.PlayerData.source, { x = coords.x, y = coords.y, z = coords.z }, callsign)
        end
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    tackleCooldowns[src] = nil
    gsrReports[src] = nil
    panicCooldowns[src] = nil
end)
