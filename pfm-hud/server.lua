local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions', 'Commands' })
local ResetStress = false

QBCore.Commands.Add('cash', 'Check Cash Balance', {}, false, function(source, _)
    local Player = exports['pfm-core']:GetPlayer(source)
    local cashamount = Player.PlayerData.money.cash
    TriggerClientEvent('hud:client:ShowAccounts', source, 'cash', cashamount)
end)

QBCore.Commands.Add('bank', 'Check Bank Balance', {}, false, function(source, _)
    local Player = exports['pfm-core']:GetPlayer(source)
    local bankamount = Player.PlayerData.money.bank
    TriggerClientEvent('hud:client:ShowAccounts', source, 'bank', bankamount)
end)

QBCore.Commands.Add('dev', 'Enable/Disable developer Mode', {}, false, function(source, _)
    TriggerClientEvent('qb-admin:client:ToggleDevmode', source)
end, 'admin')

-- pf-hud is the active HUD and handles these same two events itself (validated); with both started,
-- every stress change was applied twice. pfm-hud only handles stress when pf-hud is not running.
local function pfHudHandlesStress()
    return GetResourceState('pf-hud') == 'started'
end

RegisterNetEvent('hud:server:GainStress', function(amount)
    if Config.DisableStress or pfHudHandlesStress() then return end
    local src = source
    -- a whole gain of 1 to 10, as pf-hud allows (any number was accepted: a negative one cleared
    -- stress, a missing one raised an error)
    amount = math.floor(tonumber(amount) or 0)
    if amount < 1 then return end
    if amount > 10 then amount = 10 end
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    local Job = Player.PlayerData.job.name
    local JobType = Player.PlayerData.job.type
    local newStress
    if Config.WhitelistedJobs[JobType] or Config.WhitelistedJobs[Job] then return end
    if not ResetStress then
        if not Player.PlayerData.metadata['stress'] then
            Player.PlayerData.metadata['stress'] = 0
        end
        newStress = Player.PlayerData.metadata['stress'] + amount
        if newStress <= 0 then newStress = 0 end
    else
        newStress = 0
    end
    if newStress > 100 then
        newStress = 100
    end
    Player.SetMetaData('stress', newStress)
    TriggerClientEvent('hud:client:UpdateStress', src, newStress)
    TriggerClientEvent('QBCore:Notify', src, Lang:t('notify.stress_gain'), 'error', 1500)
end)

RegisterNetEvent('hud:server:RelieveStress', function(amount)
    if Config.DisableStress or pfHudHandlesStress() then return end
    local src = source
    if type(amount) ~= 'number' then return end
    amount = math.floor(amount)
    if amount <= 0 or amount > 100 then return end
    local Player = exports['pfm-core']:GetPlayer(src)
    local newStress
    if not Player then return end
    if not ResetStress then
        if not Player.PlayerData.metadata['stress'] then
            Player.PlayerData.metadata['stress'] = 0
        end
        newStress = Player.PlayerData.metadata['stress'] - amount
        if newStress <= 0 then newStress = 0 end
    else
        newStress = 0
    end
    if newStress > 100 then
        newStress = 100
    end
    Player.SetMetaData('stress', newStress)
    TriggerClientEvent('hud:client:UpdateStress', src, newStress)
    TriggerClientEvent('QBCore:Notify', src, Lang:t('notify.stress_removed'))
end)

QBCore.Functions.CreateCallback('hud:server:getMenu', function(_, cb)
    cb(Config.Menu)
end)
