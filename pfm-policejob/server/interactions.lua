local sharedItems = exports['pfm-core']:GetShared('Items')

local function IsOnDutyLeo(Player)
    return Player and Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty
end

RegisterNetEvent('police:server:SearchPlayer', function()
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if not IsOnDutyLeo(Player) then return end
    local player, distance = QBCore.Functions.GetClosestPlayer(src)
    if player ~= -1 and distance < 2.5 then
        local SearchedPlayer = exports['pfm-core']:GetPlayer(tonumber(player))
        if not SearchedPlayer then return end
        exports['pfm-inventory']:OpenInventoryById(src, tonumber(player))
        TriggerClientEvent('QBCore:Notify', src, Lang:t('info.cash_found', { cash = SearchedPlayer.PlayerData.money['cash'] }))
        TriggerClientEvent('QBCore:Notify', player, Lang:t('info.being_searched'))
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.none_nearby'), 'error')
    end
end)

-- Cuffing: hardcuffing a standing suspect gives them a short mash-to-resist window
local pendingCuffs = {}   -- [targetSrc] = { officer = src, soft = bool }
local resistCooldowns = {} -- [officerSrc] = GetGameTimer() of last failed attempt

local function ApplyCuff(officerSrc, targetSrc, isSoftcuff)
    TriggerClientEvent('police:client:GetCuffed', targetSrc, officerSrc, isSoftcuff)
    TriggerClientEvent('police:client:CuffAnimation', officerSrc)
end

RegisterNetEvent('police:server:CuffPlayer', function(playerId, isSoftcuff)
    local src = source
    local playerPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(playerId)
    local playerCoords = GetEntityCoords(playerPed)
    local targetCoords = GetEntityCoords(targetPed)
    if #(playerCoords - targetCoords) > 2.5 then return DropPlayer(src, 'Attempted exploit abuse') end

    local Player = exports['pfm-core']:GetPlayer(src)
    local CuffedPlayer = exports['pfm-core']:GetPlayer(playerId)
    if not Player or not CuffedPlayer then return end
    if not IsOnDutyLeo(Player) and not Player.GetItemByName('handcuffs') then return end

    local target = CuffedPlayer.PlayerData.source
    local resistCfg = Config.Gameplay and Config.Gameplay.ResistCuff
    local meta = CuffedPlayer.PlayerData.metadata
    local canResist = resistCfg and resistCfg.Enabled
        and not isSoftcuff
        and not meta['ishandcuffed']            -- uncuffing is never resisted
        and not meta['isdead'] and not meta['inlaststand']

    if not canResist then
        ApplyCuff(src, target, isSoftcuff)
        return
    end

    local now = GetGameTimer()
    if resistCooldowns[src] and now - resistCooldowns[src] < (resistCfg.OfficerCooldown or 4000) then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.resist_cooldown'), 'error')
        return
    end
    if pendingCuffs[target] then return end

    pendingCuffs[target] = { officer = src, soft = isSoftcuff }
    TriggerClientEvent('police:client:ResistCuff', target, src, resistCfg.Window or 3000, resistCfg.PressesNeeded or 10)
    -- safety net: if the suspect's client never answers, the cuff lands anyway
    SetTimeout((resistCfg.Window or 3000) + 2000, function()
        local pending = pendingCuffs[target]
        if pending and pending.officer == src then
            pendingCuffs[target] = nil
            ApplyCuff(src, target, isSoftcuff)
        end
    end)
end)

RegisterNetEvent('police:server:ResistResult', function(resisted)
    local src = source
    local pending = pendingCuffs[src]
    if not pending then return end
    pendingCuffs[src] = nil

    local officer = pending.officer
    local officerPed = GetPlayerPed(officer)
    local targetPed = GetPlayerPed(src)
    if not officerPed or not targetPed then return end
    local stillClose = #(GetEntityCoords(officerPed) - GetEntityCoords(targetPed)) <= 5.0

    if resisted and stillClose then
        resistCooldowns[officer] = GetGameTimer()
        TriggerClientEvent('QBCore:Notify', officer, Lang:t('error.suspect_resisted'), 'error')
        TriggerClientEvent('QBCore:Notify', src, Lang:t('success.resisted_cuff'), 'success')
    else
        ApplyCuff(officer, src, pending.soft)
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    pendingCuffs[src] = nil
    resistCooldowns[src] = nil
end)

RegisterNetEvent('police:server:EscortPlayer', function(playerId)
    local src = source
    local playerPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(playerId)
    local playerCoords = GetEntityCoords(playerPed)
    local targetCoords = GetEntityCoords(targetPed)
    if #(playerCoords - targetCoords) > 2.5 then return DropPlayer(src, 'Attempted exploit abuse') end

    local Player = exports['pfm-core']:GetPlayer(source)
    local EscortPlayer = exports['pfm-core']:GetPlayer(playerId)
    if not Player or not EscortPlayer then return end

    if ((Player.PlayerData.job.type == 'leo' or Player.PlayerData.job.name == 'ambulance') and Player.PlayerData.job.onduty) or (EscortPlayer.PlayerData.metadata['ishandcuffed'] or EscortPlayer.PlayerData.metadata['isdead'] or EscortPlayer.PlayerData.metadata['inlaststand']) then
        TriggerClientEvent('police:client:GetEscorted', EscortPlayer.PlayerData.source, Player.PlayerData.source)
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_cuffed_dead'), 'error')
    end
end)

RegisterNetEvent('police:server:KidnapPlayer', function(playerId)
    local src = source
    local playerPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(playerId)
    local playerCoords = GetEntityCoords(playerPed)
    local targetCoords = GetEntityCoords(targetPed)
    if #(playerCoords - targetCoords) > 2.5 then return DropPlayer(src, 'Attempted exploit abuse') end

    local Player = exports['pfm-core']:GetPlayer(source)
    local EscortPlayer = exports['pfm-core']:GetPlayer(playerId)
    if not Player or not EscortPlayer then return end

    if EscortPlayer.PlayerData.metadata['ishandcuffed'] or EscortPlayer.PlayerData.metadata['isdead'] or EscortPlayer.PlayerData.metadata['inlaststand'] then
        TriggerClientEvent('police:client:GetKidnappedTarget', EscortPlayer.PlayerData.source, Player.PlayerData.source)
        TriggerClientEvent('police:client:GetKidnappedDragger', Player.PlayerData.source, EscortPlayer.PlayerData.source)
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_cuffed_dead'), 'error')
    end
end)

RegisterNetEvent('police:server:SetPlayerOutVehicle', function(playerId)
    local src = source
    local playerPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(playerId)
    local playerCoords = GetEntityCoords(playerPed)
    local targetCoords = GetEntityCoords(targetPed)
    if #(playerCoords - targetCoords) > 2.5 then return DropPlayer(src, 'Attempted exploit abuse') end

    local EscortPlayer = exports['pfm-core']:GetPlayer(playerId)
    if not exports['pfm-core']:GetPlayer(src) or not EscortPlayer then return end

    if EscortPlayer.PlayerData.metadata['ishandcuffed'] or EscortPlayer.PlayerData.metadata['isdead'] then
        TriggerClientEvent('police:client:SetOutVehicle', EscortPlayer.PlayerData.source)
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_cuffed_dead'), 'error')
    end
end)

RegisterNetEvent('police:server:PutPlayerInVehicle', function(playerId)
    local src = source
    local playerPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(playerId)
    local playerCoords = GetEntityCoords(playerPed)
    local targetCoords = GetEntityCoords(targetPed)
    if #(playerCoords - targetCoords) > 2.5 then return DropPlayer(src, 'Attempted exploit abuse') end

    local EscortPlayer = exports['pfm-core']:GetPlayer(playerId)
    if not exports['pfm-core']:GetPlayer(src) or not EscortPlayer then return end

    if EscortPlayer.PlayerData.metadata['ishandcuffed'] or EscortPlayer.PlayerData.metadata['isdead'] then
        TriggerClientEvent('police:client:PutInVehicle', EscortPlayer.PlayerData.source)
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_cuffed_dead'), 'error')
    end
end)

RegisterNetEvent('police:server:BillPlayer', function(playerId, price)
    local src = source
    local playerPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(playerId)
    local playerCoords = GetEntityCoords(playerPed)
    local targetCoords = GetEntityCoords(targetPed)
    if #(playerCoords - targetCoords) > 2.5 then return DropPlayer(src, 'Attempted exploit abuse') end

    local Player = exports['pfm-core']:GetPlayer(src)
    local OtherPlayer = exports['pfm-core']:GetPlayer(playerId)
    if not Player or not OtherPlayer or not IsOnDutyLeo(Player) then return end

    price = tonumber(price)
    if not price or price <= 0 or price ~= price or price == math.huge then return end
    price = math.floor(price)

    OtherPlayer.Functions.RemoveMoney('bank', price, 'paid-bills')
    exports['pfm-banking']:AddMoney('police', price, 'Fine paid')
    TriggerClientEvent('QBCore:Notify', OtherPlayer.PlayerData.source, Lang:t('info.fine_received', { fine = price }))
end)

RegisterNetEvent('police:server:JailPlayer', function(playerId, time)
    local src = source
    local playerPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(playerId)
    local playerCoords = GetEntityCoords(playerPed)
    local targetCoords = GetEntityCoords(targetPed)
    if #(playerCoords - targetCoords) > 2.5 then return DropPlayer(src, 'Attempted exploit abuse') end

    local Player = exports['pfm-core']:GetPlayer(src)
    local OtherPlayer = exports['pfm-core']:GetPlayer(playerId)
    if not Player or not OtherPlayer or not IsOnDutyLeo(Player) then return end

    time = tonumber(time)
    if not time or time <= 0 or time ~= time or time == math.huge then return end
    time = math.floor(time)

    local currentDate = os.date('*t')
    if currentDate.day == 31 then
        currentDate.day = 30
    end

    OtherPlayer.Functions.SetMetaData('injail', time)
    OtherPlayer.Functions.SetMetaData('criminalrecord', {
        ['hasRecord'] = true,
        ['date'] = currentDate
    })
    TriggerClientEvent('police:client:SendToJail', OtherPlayer.PlayerData.source, time)
    TriggerClientEvent('QBCore:Notify', src, Lang:t('info.sent_jail_for', { time = time }))
end)

RegisterNetEvent('police:server:SeizeCash', function(playerId)
    local src = source
    local playerPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(playerId)
    local playerCoords = GetEntityCoords(playerPed)
    local targetCoords = GetEntityCoords(targetPed)
    if #(playerCoords - targetCoords) > 2.5 then return DropPlayer(src, 'Attempted exploit abuse') end
    local Player = exports['pfm-core']:GetPlayer(src)
    local SearchedPlayer = exports['pfm-core']:GetPlayer(playerId)
    if not Player or not SearchedPlayer then return end
    if not IsOnDutyLeo(Player) then return end
    local moneyAmount = SearchedPlayer.PlayerData.money['cash']
    local info = { cash = moneyAmount }
    SearchedPlayer.Functions.RemoveMoney('cash', moneyAmount, 'police-cash-seized')
    exports['pfm-inventory']:AddItem(src, 'moneybag', 1, false, info, 'police:server:SeizeCash')
    TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems['moneybag'], 'add')
    TriggerClientEvent('QBCore:Notify', SearchedPlayer.PlayerData.source, Lang:t('info.cash_confiscated'))
end)

RegisterNetEvent('police:server:SeizeDriverLicense', function(playerId)
    local src = source
    local playerPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(playerId)
    local playerCoords = GetEntityCoords(playerPed)
    local targetCoords = GetEntityCoords(targetPed)
    if #(playerCoords - targetCoords) > 2.5 then return DropPlayer(src, 'Attempted exploit abuse') end

    local Player = exports['pfm-core']:GetPlayer(src)
    local SearchedPlayer = exports['pfm-core']:GetPlayer(playerId)
    if not Player or not SearchedPlayer then return end
    if not IsOnDutyLeo(Player) then return end

    local driverLicense = SearchedPlayer.PlayerData.metadata['licences']['driver']
    if driverLicense then
        local licenses = { ['driver'] = false, ['business'] = SearchedPlayer.PlayerData.metadata['licences']['business'] }
        SearchedPlayer.Functions.SetMetaData('licences', licenses)
        TriggerClientEvent('QBCore:Notify', SearchedPlayer.PlayerData.source, Lang:t('info.driving_license_confiscated'))
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.no_driver_license'), 'error')
    end
end)

RegisterNetEvent('police:server:RobPlayer', function(playerId)
    local src = source
    local playerPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(playerId)
    local playerCoords = GetEntityCoords(playerPed)
    local targetCoords = GetEntityCoords(targetPed)
    if #(playerCoords - targetCoords) > 2.5 then return DropPlayer(src, 'Attempted exploit abuse') end

    local Player = exports['pfm-core']:GetPlayer(src)
    local SearchedPlayer = exports['pfm-core']:GetPlayer(playerId)
    if not Player or not SearchedPlayer then return end
    if not (SearchedPlayer.PlayerData.metadata['ishandcuffed'] or SearchedPlayer.PlayerData.metadata['isdead'] or SearchedPlayer.PlayerData.metadata['inlaststand']) then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_cuffed_dead'), 'error')
        return
    end

    local money = SearchedPlayer.PlayerData.money['cash']
    Player.AddMoney('cash', money, 'police-player-robbed')
    SearchedPlayer.Functions.RemoveMoney('cash', money, 'police-player-robbed')
    exports['pfm-inventory']:OpenInventoryById(src, playerId)
    TriggerClientEvent('QBCore:Notify', SearchedPlayer.PlayerData.source, Lang:t('info.cash_robbed', { money = money }))
    TriggerClientEvent('QBCore:Notify', Player.PlayerData.source, Lang:t('info.stolen_money', { stolen = money }))
end)
