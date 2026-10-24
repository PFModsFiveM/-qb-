local QBCore = exports['pfm-core']:GetCoreObject()
local PaymentTax = 15
local Bail = {}
local Sessions = {}

local function applyStreakBonus(streak, amount)
    local sb = Config.StreakBonus
    if not sb or not sb.enabled or streak <= 0 then return amount end
    local mult = math.min(streak * (sb.perDelivery or 0.02), sb.cap or 0.25)
    return math.floor(amount * (1.0 + mult) + 0.5)
end

AddEventHandler('playerDropped', function()
    Sessions[source] = nil
end)

RegisterNetEvent('qb-tow:server:DoBail', function(bool, vehInfo)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if bool then
        if Player.PlayerData.money.cash >= Config.BailPrice then
            Bail[Player.PlayerData.citizenid] = Config.BailPrice
            Player.Functions.RemoveMoney('cash', Config.BailPrice, 'tow-paid-bail')
            TriggerClientEvent('QBCore:Notify', src, Lang:t('success.paid_with_cash', { value = Config.BailPrice }), 'success')
            TriggerClientEvent('qb-tow:client:SpawnVehicle', src, vehInfo)
        elseif Player.PlayerData.money.bank >= Config.BailPrice then
            Bail[Player.PlayerData.citizenid] = Config.BailPrice
            Player.Functions.RemoveMoney('bank', Config.BailPrice, 'tow-paid-bail')
            TriggerClientEvent('QBCore:Notify', src, Lang:t('success.paid_with_bank', { value = Config.BailPrice }), 'success')
            TriggerClientEvent('qb-tow:client:SpawnVehicle', src, vehInfo)
        else
            TriggerClientEvent('QBCore:Notify', src, Lang:t('error.no_deposit', { value = Config.BailPrice }), 'error')
        end
    else
        if Bail[Player.PlayerData.citizenid] ~= nil then
            Player.Functions.AddMoney('bank', Bail[Player.PlayerData.citizenid], 'tow-bail-paid')
            Bail[Player.PlayerData.citizenid] = nil
            TriggerClientEvent('QBCore:Notify', src, Lang:t('success.refund_to_cash', { value = Config.BailPrice }), 'success')
        end
    end
end)

RegisterNetEvent('qb-tow:server:nano', function(vehNetID)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    local targetVehicle = NetworkGetEntityFromNetworkId(vehNetID)
    if not Player then return end
    local playerPed = GetPlayerPed(src)
    local playerVehicle = GetVehiclePedIsIn(playerPed, true)
    local playerVehicleCoords = GetEntityCoords(playerVehicle)
    local targetVehicleCoords = GetEntityCoords(targetVehicle)
    local dist = #(playerVehicleCoords - targetVehicleCoords)
    if Player.PlayerData.job.name ~= 'tow' or dist > 11.0 then
        return DropPlayer(src, Lang:t('info.skick'))
    end
    -- Job session: hooking a mission vehicle registers it; the drop is credited server-side on delivery
    Sessions[src] = Sessions[src] or { drops = 0 }
    Sessions[src].pendingHook = vehNetID
    Sessions[src].hookTime = os.time()
    local chance = math.random(1, 100)
    if chance < 26 then
        exports['pfm-inventory']:AddItem(src, 'cryptostick', 1, false, false, 'qb-tow:server:nano')
        TriggerClientEvent('qb-inventory:client:ItemBox', src, QBCore.Shared.Items['cryptostick'], 'add')
    end
end)

-- Drop-off confirmation: credited server-side with proximity and timing checks
RegisterNetEvent('qb-tow:server:vehicleDropped', function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or Player.PlayerData.job.name ~= 'tow' then return end
    local session = Sessions[src]
    if not session or not session.pendingHook then return end
    local playerCoords = GetEntityCoords(GetPlayerPed(src))
    local dropoff = Config.Locations['dropoff'].coords
    if #(playerCoords - vector3(dropoff.x, dropoff.y, dropoff.z)) > 30.0 then return end
    if (os.time() - (session.hookTime or 0)) < (Config.MinDeliverySeconds or 15) then return end
    session.pendingHook = nil
    if session.drops < (Config.MaxDropsPerSession or 50) then
        session.drops = session.drops + 1
    end
end)

RegisterNetEvent('qb-tow:server:11101110', function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local playerPed = GetPlayerPed(src)
    local playerCoords = GetEntityCoords(playerPed)
    if Player.PlayerData.job.name ~= 'tow' or #(playerCoords - vector3(Config.Locations['main'].coords.x, Config.Locations['main'].coords.y, Config.Locations['main'].coords.z)) > 6.0 then
        return DropPlayer(src, Lang:t('info.skick'))
    end
    -- Server-tracked drop count only; the client-sent value is ignored
    local session = Sessions[src]
    local drops = session and session.drops or 0
    if drops <= 0 then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.no_work_done'), 'error')
        return
    end
    local price = 0
    for i = 1, drops do
        price = price + applyStreakBonus(i - 1, math.random(150, 170))
    end
    local bonus = 0
    local DropPrice = math.random(150, 170)
    if drops > 20 then
        bonus = math.ceil((DropPrice / 10) * 12)
    elseif drops > 15 then
        bonus = math.ceil((DropPrice / 10) * 10)
    elseif drops > 10 then
        bonus = math.ceil((DropPrice / 10) * 7)
    elseif drops > 5 then
        bonus = math.ceil((DropPrice / 10) * 5)
    end
    price = price + bonus
    local taxAmount = math.ceil((price / 100) * PaymentTax)
    local payment = price - taxAmount
    Sessions[src] = nil
    Player.Functions.AddMoney('bank', payment, 'tow-salary')
    TriggerClientEvent('QBCore:Notify', src, Lang:t('success.you_earned', { value = payment }), 'success')
end)

QBCore.Commands.Add('npc', Lang:t('info.toggle_npc'), {}, false, function(source)
    TriggerClientEvent('jobs:client:ToggleNpc', source)
end)

QBCore.Commands.Add('tow', Lang:t('info.tow'), {}, false, function(source)
    local Player = QBCore.Functions.GetPlayer(source)
    if Player.PlayerData.job.name == 'tow' or Player.PlayerData.job.name == 'mechanic' then
        TriggerClientEvent('qb-tow:client:TowVehicle', source)
    end
end)
