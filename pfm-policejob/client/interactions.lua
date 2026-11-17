-- Variables
local isEscorting = false

-- Functions
exports('IsHandcuffed', function()
    return isHandcuffed
end)

local function loadAnimDict(dict) -- interactions, job,
    while (not HasAnimDictLoaded(dict)) do
        RequestAnimDict(dict)
        Wait(10)
    end
end

local function IsTargetDead(playerId)
    local retval = false
    local hasReturned = false
    QBCore.Functions.TriggerCallback('police:server:isPlayerDead', function(result)
        retval = result
        hasReturned = true
    end, playerId)
    while not hasReturned do
        Wait(10)
    end
    return retval
end

local function HandCuffAnimation(cuffing)
    local ped = PlayerPedId()
    if cuffing then
        TriggerServerEvent('InteractSound_SV:PlayOnSource', 'Cuff', 0.2)
    else
        TriggerServerEvent('InteractSound_SV:PlayOnSource', 'Uncuff', 0.2)
    end

    loadAnimDict('mp_arrest_paired')
    Wait(100)
    TaskPlayAnim(ped, 'mp_arrest_paired', 'cop_p2_back_right', 3.0, 3.0, -1, 48, 0, 0, 0, 0)
    Wait(3500)
    TaskPlayAnim(ped, 'mp_arrest_paired', 'exit', 3.0, 3.0, -1, 48, 0, 0, 0, 0)
end

local function GetCuffedAnimation(playerId)
    local ped = PlayerPedId()
    TriggerServerEvent('InteractSound_SV:PlayOnSource', 'Cuff', 0.2)
    local player = playerId and playerId > 0 and GetPlayerFromServerId(playerId) or -1
    local cuffer = player ~= -1 and GetPlayerPed(player) or 0
    if cuffer == 0 or not DoesEntityExist(cuffer) then return end -- cuffed again after a relog: no partner
    local heading = GetEntityHeading(cuffer)
    loadAnimDict('mp_arrest_paired')
    SetEntityCoords(ped, GetOffsetFromEntityInWorldCoords(cuffer, 0.0, 0.45, 0.0))

    Wait(100)
    SetEntityHeading(ped, heading)
    TaskPlayAnim(ped, 'mp_arrest_paired', 'crook_p2_back_right', 3.0, 3.0, -1, 32, 0, 0, 0, 0, true, true, true)
    Wait(2500)
end

-- Events
RegisterNetEvent('police:client:CuffAnimation', function(cuffing)
    HandCuffAnimation(cuffing == true)
end)

RegisterNetEvent('police:client:SetOutVehicle', function()
    local ped = PlayerPedId()
    if IsPedInAnyVehicle(ped, false) then
        local vehicle = GetVehiclePedIsIn(ped, false)
        TaskLeaveVehicle(ped, vehicle, 16)
    end
end)

-- The server chose the vehicle and the seat (server/custody_field.lua); this client lets go of the
-- escort and sits there. The server checks afterwards that it worked and tries the next seat if not.
RegisterNetEvent('police:client:PutInVehicle', function(netId, seat)
    local ped = PlayerPedId()
    netId, seat = tonumber(netId), tonumber(seat)
    if not netId or not seat or not NetworkDoesNetworkIdExist(netId) then return end
    local vehicle = NetToVeh(netId)
    if not DoesEntityExist(vehicle) or not IsVehicleSeatFree(vehicle, seat) then return end
    isEscorted = false
    TriggerEvent('hospital:client:isEscorted', isEscorted)
    ClearPedTasks(ped)
    DetachEntity(ped, true, false)
    Wait(100)
    SetPedIntoVehicle(ped, vehicle, seat)
end)

RegisterNetEvent('police:client:SeizeCash', function()
    local player, distance = QBCore.Functions.GetClosestPlayer()
    if player ~= -1 and distance < 2.5 then
        local playerId = GetPlayerServerId(player)
        TriggerServerEvent('police:server:SeizeCash', playerId)
    else
        QBCore.Functions.Notify(Lang:t('error.none_nearby'), 'error')
    end
end)

RegisterNetEvent('police:client:SeizeDriverLicense', function()
    local player, distance = QBCore.Functions.GetClosestPlayer()
    if player ~= -1 and distance < 2.5 then
        local playerId = GetPlayerServerId(player)
        TriggerServerEvent('police:server:SeizeDriverLicense', playerId)
    else
        QBCore.Functions.Notify(Lang:t('error.none_nearby'), 'error')
    end
end)

RegisterNetEvent('police:client:RobPlayer', function()
    local player, distance = QBCore.Functions.GetClosestPlayer()
    local ped = PlayerPedId()
    if player ~= -1 and distance < 2.5 then
        local playerPed = GetPlayerPed(player)
        local playerId = GetPlayerServerId(player)
        if IsEntityPlayingAnim(playerPed, 'missminuteman_1ig_2', 'handsup_base', 3) or IsEntityPlayingAnim(playerPed, 'mp_arresting', 'idle', 3) or IsTargetDead(playerId) then
            QBCore.Functions.Progressbar('robbing_player', Lang:t('progressbar.robbing'), math.random(5000, 7000), false, true, {
                disableMovement = true,
                disableCarMovement = true,
                disableMouse = false,
                disableCombat = true,
            }, {
                animDict = 'random@shop_robbery',
                anim = 'robbery_action_b',
                flags = 16,
            }, {}, {}, function()
                local plyCoords = GetEntityCoords(playerPed)
                local pos = GetEntityCoords(ped)
                if #(pos - plyCoords) < 2.5 then
                    TriggerServerEvent('police:server:RobPlayer', playerId)
                else
                    QBCore.Functions.Notify(Lang:t('error.none_nearby'), 'error')
                end
            end)
        end
    else
        QBCore.Functions.Notify(Lang:t('error.none_nearby'), 'error')
    end
end)

RegisterNetEvent('police:client:JailPlayer', function()
    local player, distance = QBCore.Functions.GetClosestPlayer()
    if player ~= -1 and distance < 2.5 then
        local playerId = GetPlayerServerId(player)
        local dialog = exports['pfm-input']:ShowInput({
            header = Lang:t('info.jail_time_input'),
            submitText = Lang:t('info.submit'),
            inputs = {
                {
                    text = Lang:t('info.time_months'),
                    name = 'jailtime',
                    type = 'number',
                    isRequired = true
                }
            }
        })
        -- a closed dialog returns nothing; the server checks the time, custody and reach again
        if not dialog then return end
        local minutes = tonumber(dialog['jailtime'])
        if minutes and minutes > 0 then
            TriggerServerEvent('police:server:JailPlayer', playerId, math.floor(minutes))
        else
            QBCore.Functions.Notify(Lang:t('error.time_higher'), 'error')
        end
    else
        QBCore.Functions.Notify(Lang:t('error.none_nearby'), 'error')
    end
end)

RegisterNetEvent('police:client:BillPlayer', function()
    local player, distance = QBCore.Functions.GetClosestPlayer()
    if player ~= -1 and distance < 2.5 then
        local playerId = GetPlayerServerId(player)
        local dialog = exports['pfm-input']:ShowInput({
            header = Lang:t('info.bill'),
            submitText = Lang:t('info.submit'),
            inputs = {
                {
                    text = Lang:t('info.amount'),
                    name = 'bill',
                    type = 'number',
                    isRequired = true
                }
            }
        })
        -- a closed dialog returns nothing
        if dialog and (tonumber(dialog['bill']) or 0) > 0 then
            TriggerServerEvent('police:server:BillPlayer', playerId, tonumber(dialog['bill']))
        else
            QBCore.Functions.Notify(Lang:t('error.amount_higher'), 'error')
        end
    else
        QBCore.Functions.Notify(Lang:t('error.none_nearby'), 'error')
    end
end)

RegisterNetEvent('police:client:PutPlayerInVehicle', function()
    local player, distance = QBCore.Functions.GetClosestPlayer()
    if player ~= -1 and distance < 2.5 then
        local playerId = GetPlayerServerId(player)
        if not isHandcuffed and not isEscorted then
            -- the nearest vehicle is only a hint: the server checks it is next to both of you
            local vehicle = QBCore.Functions.GetClosestVehicle()
            local netId = (vehicle and vehicle ~= 0 and DoesEntityExist(vehicle)) and VehToNet(vehicle) or nil
            TriggerServerEvent('police:server:PutPlayerInVehicle', playerId, netId)
        end
    else
        QBCore.Functions.Notify(Lang:t('error.none_nearby'), 'error')
    end
end)

RegisterNetEvent('police:client:SetPlayerOutVehicle', function()
    local player, distance = QBCore.Functions.GetClosestPlayer()
    if player ~= -1 and distance < 2.5 then
        local playerId = GetPlayerServerId(player)
        if not isHandcuffed and not isEscorted then
            TriggerServerEvent('police:server:SetPlayerOutVehicle', playerId)
        end
    else
        QBCore.Functions.Notify(Lang:t('error.none_nearby'), 'error')
    end
end)

RegisterNetEvent('police:client:EscortPlayer', function()
    local player, distance = QBCore.Functions.GetClosestPlayer()
    if player ~= -1 and distance < 2.5 then
        local playerId = GetPlayerServerId(player)
        if not isHandcuffed and not isEscorted then
            TriggerServerEvent('police:server:EscortPlayer', playerId)
        end
    else
        QBCore.Functions.Notify(Lang:t('error.none_nearby'), 'error')
    end
end)

RegisterNetEvent('police:client:KidnapPlayer', function()
    local player, distance = QBCore.Functions.GetClosestPlayer()
    if player ~= -1 and distance < 2.5 then
        local playerId = GetPlayerServerId(player)
        if not IsPedInAnyVehicle(GetPlayerPed(player)) then
            if not isHandcuffed and not isEscorted then
                TriggerServerEvent('police:server:KidnapPlayer', playerId)
            end
        end
    else
        QBCore.Functions.Notify(Lang:t('error.none_nearby'), 'error')
    end
end)

RegisterNetEvent('police:client:CuffPlayerSoft', function()
    if not IsPedRagdoll(PlayerPedId()) then
        local player, distance = QBCore.Functions.GetClosestPlayer()
        if player ~= -1 and distance < 1.5 then
            local playerId = GetPlayerServerId(player)
            if not IsPedInAnyVehicle(GetPlayerPed(player)) and not IsPedInAnyVehicle(PlayerPedId()) then
                TriggerServerEvent('police:server:CuffPlayer', playerId, true)
            else
                QBCore.Functions.Notify(Lang:t('error.vehicle_cuff'), 'error')
            end
        else
            QBCore.Functions.Notify(Lang:t('error.none_nearby'), 'error')
        end
    else
        Wait(2000)
    end
end)

RegisterNetEvent('police:client:CuffPlayer', function()
    if not IsPedRagdoll(PlayerPedId()) then
        local player, distance = QBCore.Functions.GetClosestPlayer()
        if player ~= -1 and distance < 1.5 then
            local result = QBCore.Functions.HasItem(Config.HandCuffItem)
            if result then
                local playerId = GetPlayerServerId(player)
                if not IsPedInAnyVehicle(GetPlayerPed(player)) and not IsPedInAnyVehicle(PlayerPedId()) then
                    TriggerServerEvent('police:server:CuffPlayer', playerId, false)
                else
                    QBCore.Functions.Notify(Lang:t('error.vehicle_cuff'), 'error')
                end
            else
                QBCore.Functions.Notify(Lang:t('error.no_cuff'), 'error')
            end
        else
            QBCore.Functions.Notify(Lang:t('error.none_nearby'), 'error')
        end
    else
        Wait(2000)
    end
end)

-- Being escorted or carried is set by the server (police:client:SetEscorted in
-- client/custody_field.lua); the old toggles (GetEscorted, GetKidnappedTarget) are gone, so the
-- attachment can no longer drift from the server's record.

-- pf-ambulancejob lets go of the escort locally (hospital bed); the server record ends with the next
-- action of the escorting player or when either of them drops.
RegisterNetEvent('police:client:DeEscort', function()
    isEscorted = false
    TriggerEvent('hospital:client:isEscorted', isEscorted)
    DetachEntity(PlayerPedId(), true, false)
end)

-- The carrying player: the server started a carry (police:server:KidnapPlayer) ...
RegisterNetEvent('police:client:GetKidnappedDragger', function()
    local dragger = PlayerPedId()
    RequestAnimDict('missfinale_c2mcs_1')
    while not HasAnimDictLoaded('missfinale_c2mcs_1') do
        Wait(10)
    end
    TaskPlayAnim(dragger, 'missfinale_c2mcs_1', 'fin_c2_mcs_1_camman', 8.0, -8.0, 100000, 49, 0, false, false, false)
    isEscorting = true
    TriggerEvent('hospital:client:SetEscortingState', isEscorting)
    TriggerEvent('qb-kidnapping:client:SetKidnapping', isEscorting)
end)

-- ... and ended it (let go, the target dropped or was put in a car).
RegisterNetEvent('police:client:EscortEnded', function(_target, kind)
    if kind ~= 'carry' or not isEscorting then return end
    local dragger = PlayerPedId()
    ClearPedSecondaryTask(dragger)
    ClearPedTasksImmediately(dragger)
    isEscorting = false
    TriggerEvent('hospital:client:SetEscortingState', isEscorting)
    TriggerEvent('qb-kidnapping:client:SetKidnapping', isEscorting)
end)

-- The server sets the cuff state (it owns it); this client only shows it and never reports it.
RegisterNetEvent('police:client:SetCuffed', function(cuffed, isSoftcuff, playerId)
    local ped = PlayerPedId()
    if cuffed then
        local wasCuffed = isHandcuffed
        isHandcuffed = true
        cuffType = isSoftcuff and 49 or 16
        if wasCuffed then return end
        ClearPedTasksImmediately(ped)
        if GetSelectedPedWeapon(ped) ~= `WEAPON_UNARMED` then
            SetCurrentPedWeapon(ped, `WEAPON_UNARMED`, true)
        end
        GetCuffedAnimation(tonumber(playerId))
        QBCore.Functions.Notify(isSoftcuff and Lang:t('info.cuffed_walk') or Lang:t('info.cuff'), 'primary')
    else
        if not isHandcuffed then return end
        isHandcuffed = false
        isEscorted = false
        TriggerEvent('hospital:client:isEscorted', isEscorted)
        DetachEntity(ped, true, false)
        ClearPedTasksImmediately(ped)
        TriggerServerEvent('InteractSound_SV:PlayOnSource', 'Uncuff', 0.2)
        QBCore.Functions.Notify(Lang:t('success.uncuffed'), 'success')
    end
end)

-- Threads
CreateThread(function()
    while true do
        Wait(1)
        if isEscorted then
            DisableAllControlActions(0)
            EnableControlAction(0, 1, true)
            EnableControlAction(0, 2, true)
            EnableControlAction(0, 245, true)
            EnableControlAction(0, 38, true)
            EnableControlAction(0, 322, true)
            EnableControlAction(0, 249, true)
            EnableControlAction(0, 46, true)
        end

        if isHandcuffed then
            DisableControlAction(0, 24, true)  -- Attack
            DisableControlAction(0, 257, true) -- Attack 2
            DisableControlAction(0, 25, true)  -- Aim
            DisableControlAction(0, 263, true) -- Melee Attack 1

            DisableControlAction(0, 45, true)  -- Reload
            DisableControlAction(0, 22, true)  -- Jump
            DisableControlAction(0, 44, true)  -- Cover
            DisableControlAction(0, 37, true)  -- Select Weapon
            DisableControlAction(0, 23, true)  -- Also 'enter'?

            DisableControlAction(0, 288, true) -- Disable phone
            DisableControlAction(0, 289, true) -- Inventory
            DisableControlAction(0, 170, true) -- Animations
            DisableControlAction(0, 167, true) -- Job

            DisableControlAction(0, 26, true)  -- Disable looking behind
            DisableControlAction(0, 73, true)  -- Disable clearing animation
            DisableControlAction(2, 199, true) -- Disable pause screen

            DisableControlAction(0, 59, true)  -- Disable steering in vehicle
            DisableControlAction(0, 71, true)  -- Disable driving forward in vehicle
            DisableControlAction(0, 72, true)  -- Disable reversing in vehicle

            DisableControlAction(2, 36, true)  -- Disable going stealth

            DisableControlAction(0, 264, true) -- Disable melee
            DisableControlAction(0, 257, true) -- Disable melee
            DisableControlAction(0, 140, true) -- Disable melee
            DisableControlAction(0, 141, true) -- Disable melee
            DisableControlAction(0, 142, true) -- Disable melee
            DisableControlAction(0, 143, true) -- Disable melee
            DisableControlAction(0, 75, true)  -- Disable exit vehicle
            DisableControlAction(27, 75, true) -- Disable exit vehicle
            EnableControlAction(0, 249, true)  -- Added for talking while cuffed
            EnableControlAction(0, 46, true)   -- Added for talking while cuffed

            if (not IsEntityPlayingAnim(PlayerPedId(), 'mp_arresting', 'idle', 3) and not IsEntityPlayingAnim(PlayerPedId(), 'mp_arrest_paired', 'crook_p2_back_right', 3)) and not QBCore.Functions.GetPlayerData().metadata['isdead'] then
                loadAnimDict('mp_arresting')
                TaskPlayAnim(PlayerPedId(), 'mp_arresting', 'idle', 8.0, -8, -1, cuffType, 0, 0, 0, 0)
            end
        end
        if not isHandcuffed and not isEscorted then
            Wait(2000)
        end
    end
end)
