local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions' })
local sharedItems = exports['pfm-core']:GetShared('Items')
local GotItems = {}
local AlarmActivated = false

local JailResourceAllowlist = Config.JailResourceAllowlist or {
    ['pfm-policejob'] = true,
    ['pfm-adminmenu'] = true,
}
local MaxJailTime = Config.MaxJailTime or 1440

RegisterNetEvent('prison:server:SetJailStatus', function(jailTime)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end

    jailTime = tonumber(jailTime)
    if not jailTime or jailTime ~= jailTime or jailTime == math.huge then return end
    jailTime = math.floor(jailTime)
    if jailTime < 0 then jailTime = 0 end
    if jailTime > MaxJailTime then jailTime = MaxJailTime end

    local invoker = GetInvokingResource()
    local allowed = invoker ~= nil and JailResourceAllowlist[invoker] == true
    local current = Player.PlayerData.metadata['injail'] or 0

    if not allowed then
        -- clients may only count their own sentence down, never raise it
        if jailTime > current then jailTime = current end
        -- an early jump to 0 from the client is only valid as an escape (far outside the prison);
        -- legitimate releases (unjail/time served) have injail set to <= 1 server-side first
        if jailTime == 0 and current > 1 then
            local coords = GetEntityCoords(GetPlayerPed(src))
            local middle = vec2(Config.Locations['middle'].x, Config.Locations['middle'].y)
            if #(coords.xy - middle) <= 195.0 then return end
        end
    end

    Player.SetMetaData('injail', jailTime)
    if jailTime > 0 then
        if Player.PlayerData.job.name ~= 'unemployed' then
            Player.SetJob('unemployed')
            TriggerClientEvent('QBCore:Notify', src, Lang:t('info.lost_job'))
        end
    else
        GotItems[source] = nil
    end
end)

RegisterNetEvent('prison:server:SaveJailItems', function()
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if (Player.PlayerData.metadata.injail or 0) <= 0 then return end
    if not Player.PlayerData.metadata['jailitems'] or table.type(Player.PlayerData.metadata['jailitems']) == 'empty' then
        Player.SetMetaData('jailitems', Player.PlayerData.items)
        Player.AddMoney('cash', 80, 'jail money')
        Wait(2000)
        Player.ClearInventory()
    end
end)

RegisterNetEvent('prison:server:GiveJailItems', function(escaped)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    -- items only come back once actually released, and only if some were stored
    if (Player.PlayerData.metadata.injail or 0) > 0 then return end
    local jailItems = Player.PlayerData.metadata['jailitems']
    if not jailItems or table.type(jailItems) == 'empty' then return end
    if escaped then
        Player.SetMetaData('jailitems', {})
        return
    end
    for _, v in pairs(jailItems) do
        exports['pfm-inventory']:AddItem(src, v.name, v.amount, false, v.info, 'prison:server:GiveJailItems')
    end
    Player.SetMetaData('jailitems', {})
end)

RegisterNetEvent('prison:server:ResetJailItems', function()
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    Player.SetMetaData('jailitems', {})
end)

RegisterNetEvent('prison:server:SecurityLockdown', function()
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or (Player.PlayerData.metadata['injail'] or 0) <= 0 then return end
    TriggerClientEvent('prison:client:SetLockDown', -1, true)
    for _, v in pairs(QBCore.Functions.GetPlayers()) do
        local Player = exports['pfm-core']:GetPlayer(v)
        if Player then
            if Player.PlayerData.job.name == 'police' and Player.PlayerData.job.onduty then
                TriggerClientEvent('prison:client:PrisonBreakAlert', v)
            end
        end
    end
end)

RegisterNetEvent('prison:server:SetGateHit', function(key)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or (Player.PlayerData.metadata['injail'] or 0) <= 0 then return end
    if type(key) ~= 'string' and type(key) ~= 'number' then return end
    TriggerClientEvent('prison:client:SetGateHit', -1, key, true)
    if math.random(1, 100) <= 50 then
        for _, v in pairs(QBCore.Functions.GetPlayers()) do
            local Player = exports['pfm-core']:GetPlayer(v)
            if Player then
                if Player.PlayerData.job.name == 'police' and Player.PlayerData.job.onduty then
                    TriggerClientEvent('prison:client:PrisonBreakAlert', v)
                end
            end
        end
    end
end)

RegisterNetEvent('prison:server:CheckRecordStatus', function()
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    local CriminalRecord = Player.PlayerData.metadata['criminalrecord']
    local currentDate = os.date('*t')

    if (CriminalRecord['date'].month + 1) == 13 then
        CriminalRecord['date'].month = 0
    end

    if CriminalRecord['hasRecord'] then
        if currentDate.month == (CriminalRecord['date'].month + 1) or currentDate.day == (CriminalRecord['date'].day - 1) then
            CriminalRecord['hasRecord'] = false
            CriminalRecord['date'] = nil
        end
    end
end)

RegisterNetEvent('prison:server:JailAlarm', function()
    if AlarmActivated then return end
    local playerPed = GetPlayerPed(source)
    local coords = GetEntityCoords(playerPed)
    local middle = vec2(Config.Locations['middle'].x, Config.Locations['middle'].y)
    if #(coords.xy - middle) < 200 then return error('"prison:server:JailAlarm" triggered whilst the player was too close to the prison, cancelled event') end
    TriggerClientEvent('prison:client:JailAlarm', -1, true)
    SetTimeout(5 * 60000, function()
        TriggerClientEvent('prison:client:JailAlarm', -1, false)
    end)
end)

RegisterNetEvent('prison:server:CheckChance', function()
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or Player.PlayerData.metadata.injail == 0 or GotItems[src] then return end
    local chance = math.random(100)
    local odd = math.random(100)
    if chance ~= odd then return end
    if not exports['pfm-inventory']:AddItem(src, 'phone', 1, false, false, 'prison:server:CheckChance') then return end
    TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems['phone'], 'add')
    TriggerClientEvent('QBCore:Notify', src, Lang:t('success.found_phone'), 'success')
    GotItems[src] = true
end)

QBCore.Functions.CreateCallback('prison:server:IsAlarmActive', function(_, cb)
    cb(AlarmActivated)
end)
