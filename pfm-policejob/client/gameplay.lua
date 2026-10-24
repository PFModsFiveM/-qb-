-- PF gameplay pack: cuff resistance, tackle, GSR, panic button

local resisting = false

-- ══ Cuff resistance (suspect side) ═══════════════════════════════
RegisterNetEvent('police:client:ResistCuff', function(_, window, pressesNeeded)
    if resisting then return end
    local ped = PlayerPedId()

    -- a surrendered / downed suspect can't fight the cuffs
    local surrendered = IsEntityPlayingAnim(ped, 'missminuteman_1ig_2', 'handsup_base', 3)
        or IsEntityPlayingAnim(ped, 'random@arrests@busted', 'idle_a', 3)
        or IsPedRagdoll(ped)
        or IsPedInAnyVehicle(ped, false)
    if surrendered then
        TriggerServerEvent('police:server:ResistResult', false)
        return
    end

    resisting = true
    local presses = 0
    local deadline = GetGameTimer() + (window or 3000)

    CreateThread(function()
        while GetGameTimer() < deadline and presses < pressesNeeded do
            Wait(0)
            DisableControlAction(0, 38, true) -- keep E from triggering other interactions
            exports['pfm-core']:DrawText(('~r~RESIST!~w~ Mash ~y~E~w~  (%d/%d)'):format(presses, pressesNeeded), 'left')
            if IsDisabledControlJustPressed(0, 38) then
                presses += 1
            end
        end
        exports['pfm-core']:HideText()
        resisting = false
        local success = presses >= pressesNeeded
        if success then
            -- shake loose
            local myPed = PlayerPedId()
            SetPedToRagdoll(myPed, 750, 750, 0, false, false, false)
        end
        TriggerServerEvent('police:server:ResistResult', success)
    end)
end)

-- ══ Tackle ═══════════════════════════════════════════════════════
local lastTackle = 0

local function TryTackle()
    local cfg = Config.Gameplay and Config.Gameplay.Tackle
    if not cfg or not cfg.Enabled then return end
    local PlayerData = QBCore.Functions.GetPlayerData()
    if not PlayerData.job or PlayerData.job.type ~= 'leo' or not PlayerData.job.onduty then return end

    local now = GetGameTimer()
    if now - lastTackle < (cfg.Cooldown or 15000) then
        QBCore.Functions.Notify(Lang:t('error.tackle_cooldown'), 'error')
        return
    end

    local ped = PlayerPedId()
    if IsPedInAnyVehicle(ped, false) or IsPedRagdoll(ped) then return end
    if not IsPedSprinting(ped) and not IsPedRunning(ped) then return end

    local player, distance = QBCore.Functions.GetClosestPlayer()
    if player == -1 or distance > (cfg.MaxDistance or 1.8) then return end
    local targetPed = GetPlayerPed(player)
    if IsPedInAnyVehicle(targetPed, false) then return end
    local speed = GetEntitySpeed(targetPed)
    if speed < (cfg.MinTargetSpeed or 2.5) then
        QBCore.Functions.Notify(Lang:t('error.tackle_not_fleeing'), 'error')
        return
    end

    lastTackle = now
    TriggerServerEvent('police:server:Tackle', GetPlayerServerId(player))
end

RegisterCommand('policetackle', TryTackle, false)
RegisterKeyMapping('policetackle', 'Police: tackle a fleeing suspect', 'keyboard', 'G')

RegisterNetEvent('police:client:TackleDive', function()
    local ped = PlayerPedId()
    RequestAnimDict('move_jump')
    while not HasAnimDictLoaded('move_jump') do Wait(10) end
    TaskPlayAnim(ped, 'move_jump', 'dive_start_run', 8.0, -8.0, -1, 0, 0, false, false, false)
    Wait(600)
    SetPedToRagdoll(ped, 1500, 1500, 0, false, false, false)
end)

RegisterNetEvent('police:client:TackleTarget', function(tacklerId)
    local ped = PlayerPedId()
    local tackler = GetPlayerPed(GetPlayerFromServerId(tacklerId))
    if DoesEntityExist(tackler) then
        local push = GetEntityForwardVector(tackler)
        SetPedToRagdoll(ped, 5000, 5000, 0, false, false, false)
        SetEntityVelocity(ped, push.x * 4.0, push.y * 4.0, 0.1)
    else
        SetPedToRagdoll(ped, 5000, 5000, 0, false, false, false)
    end
    QBCore.Functions.Notify(Lang:t('info.got_tackled'), 'error')
end)

-- ══ GSR tracking (everyone) ═══════════════════════════════════════
local lastGsrReport = 0

CreateThread(function()
    while true do
        local ped = PlayerPedId()
        local weapon = GetSelectedPedWeapon(ped)
        if weapon ~= `WEAPON_UNARMED` then
            Wait(100)
            if IsPedShooting(ped) then
                local group = GetWeapontypeGroup(weapon)
                if group ~= `GROUP_MELEE` and group ~= `GROUP_THROWN` and group ~= `GROUP_STUNGUN` and group ~= `GROUP_FIREEXTINGUISHER` then
                    local now = GetGameTimer()
                    if now - lastGsrReport > 10000 then
                        lastGsrReport = now
                        TriggerServerEvent('police:server:MarkGSR')
                    end
                end
            end
        else
            Wait(1000)
        end
    end
end)

-- ══ GSR swab (officer side) ═══════════════════════════════════════
RegisterNetEvent('police:client:DoGSR', function()
    local player, distance = QBCore.Functions.GetClosestPlayer()
    if player == -1 or distance > 2.5 then
        QBCore.Functions.Notify(Lang:t('error.none_nearby'), 'error')
        return
    end
    local playerId = GetPlayerServerId(player)
    QBCore.Functions.Progressbar('gsr_swab', Lang:t('progressbar.gsr'), 5000, false, true, {
        disableMovement = true,
        disableCarMovement = true,
        disableMouse = false,
        disableCombat = true,
    }, {
        animDict = 'mp_arresting',
        anim = 'a_uncuff',
        flags = 48,
    }, {}, {}, function()
        local targetPed = GetPlayerPed(GetPlayerFromServerId(playerId))
        if DoesEntityExist(targetPed) and #(GetEntityCoords(PlayerPedId()) - GetEntityCoords(targetPed)) < 3.0 then
            TriggerServerEvent('police:server:GsrTest', playerId)
        end
    end)
end)

-- ══ Panic button ═════════════════════════════════════════════════
local function SendPanic()
    local PlayerData = QBCore.Functions.GetPlayerData()
    if not PlayerData.job or PlayerData.job.type ~= 'leo' or not PlayerData.job.onduty then return end
    TriggerServerEvent('police:server:Panic')
end

RegisterCommand('panic', SendPanic, false)
RegisterKeyMapping('panic', 'Police: panic button', 'keyboard', '')

RegisterNetEvent('police:client:PanicAlert', function(coords, callsign)
    local cfg = Config.Gameplay and Config.Gameplay.Panic or {}
    PlaySoundFrontend(-1, 'Event_Start_Text', 'GTAO_FM_Events_Soundset', false)
    QBCore.Functions.Notify(Lang:t('info.panic_alert', { callsign = callsign or 'UNKNOWN' }), 'error', 7500)
    local blip = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(blip, 161)
    SetBlipScale(blip, 1.3)
    SetBlipColour(blip, 1)
    SetBlipFlashes(blip, true)
    SetBlipRoute(blip, true)
    SetBlipRouteColour(blip, 1)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(Lang:t('info.panic_blip'))
    EndTextCommandSetBlipName(blip)
    SetTimeout((cfg.BlipSeconds or 60) * 1000, function()
        if DoesBlipExist(blip) then RemoveBlip(blip) end
    end)
end)
