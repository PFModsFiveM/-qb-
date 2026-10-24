local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions' })
local sharedItems = exports['pfm-core']:GetShared('Items')

-- Per-source event cooldowns (anti-spam); cleared on disconnect
local eventCooldowns = {}
local function onCooldown(src, key, ms)
    local now = GetGameTimer()
    local t = eventCooldowns[src]
    if not t then
        t = {}
        eventCooldowns[src] = t
    end
    if t[key] and (now - t[key]) < ms then return true end
    t[key] = now
    return false
end
AddEventHandler('playerDropped', function()
    eventCooldowns[source] = nil
end)

local function isAtScrapyard(coords)
    for i = 1, #Config.Locations do
        local deliver = Config.Locations[i].deliver
        if deliver and #(coords - deliver.coords) <= 25.0 then return true end
    end
    return false
end

CreateThread(function()
    while true do
        Wait(1000)
        GenerateVehicleList()
        Wait((1000 * 60) * 60)
    end
end)

RegisterNetEvent('qb-scrapyard:server:LoadVehicleList', function()
    local src = source
    TriggerClientEvent('qb-scapyard:client:setNewVehicles', src, Config.CurrentVehicles)
end)


QBCore.Functions.CreateCallback('qb-scrapyard:checkOwnerVehicle', function(_, cb, plate)
    local result = MySQL.scalar.await('SELECT `plate` FROM `player_vehicles` WHERE `plate` = ?', { plate })
    if result then
        cb(false)
    else
        cb(true)
    end
end)


RegisterNetEvent('qb-scrapyard:server:ScrapVehicle', function(listKey)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local ped = GetPlayerPed(src)
    if ped <= 0 then return end

    -- scrapping animation takes ~30s client-side; also require being at the yard
    if onCooldown(src, 'scrap', 20000) then return end
    if not isAtScrapyard(GetEntityCoords(ped)) then return end

    local vehicle = GetVehiclePedIsIn(ped, false)
    if vehicle <= 0 then return end

    if GetPedInVehicleSeat(vehicle, -1) ~= ped then return end

    local model = GetEntityModel(vehicle)
    if model == 0 then return end

    local vehicleKey = tonumber(listKey)
    if not vehicleKey then return end

    local currentVehicle = Config.CurrentVehicles[vehicleKey]
    if currentVehicle ~= nil and GetHashKey(currentVehicle) == model then
        for _ = 1, math.random(2, 4), 1 do
            local item = Config.Items[math.random(1, #Config.Items)]
            exports['pfm-inventory']:AddItem(src, item, math.random(25, 45), false, false, 'qb-scrapyard:server:ScrapVehicle')
            TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems[item], 'add')
            Wait(500)
        end
        local Luck = math.random(1, 8)
        local Odd = math.random(1, 8)
        if Luck == Odd then
            local random = math.random(10, 20)
            exports['pfm-inventory']:AddItem(src, 'rubber', random, false, false, 'qb-scrapyard:server:ScrapVehicle')
            TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems['rubber'], 'add')
        end
        Config.CurrentVehicles[vehicleKey] = nil
        TriggerClientEvent('qb-scapyard:client:setNewVehicles', -1, Config.CurrentVehicles)
    end
end)

function GenerateVehicleList()
    Config.CurrentVehicles = {}
    for i = 1, Config.VehicleCount, 1 do
        local randVehicle = Config.Vehicles[math.random(1, #Config.Vehicles)]
        if not IsInList(randVehicle) then
            Config.CurrentVehicles[i] = randVehicle
        end
    end
    TriggerClientEvent('qb-scapyard:client:setNewVehicles', -1, Config.CurrentVehicles)
end

function IsInList(name)
    local retval = false
    if Config.CurrentVehicles ~= nil and next(Config.CurrentVehicles) ~= nil then
        for k in pairs(Config.CurrentVehicles) do
            if Config.CurrentVehicles[k] == name then
                retval = true
            end
        end
    end
    return retval
end
