local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions' })
local sharedVehicles = exports['pfm-core']:GetShared('Vehicles')

-- Functions

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

-- The sale lots are large polyzones; 150m around the configured spots covers them
local function isAtSaleLot(src)
    local playerCoords = GetEntityCoords(GetPlayerPed(src))
    for _, zone in pairs(Config.Zones) do
        if #(playerCoords - vector3(zone.SellVehicle.x, zone.SellVehicle.y, zone.SellVehicle.z)) <= 150.0 then return true end
        if #(playerCoords - vector3(zone.BuyVehicle.x, zone.BuyVehicle.y, zone.BuyVehicle.z)) <= 150.0 then return true end
    end
    return false
end

local function generateOID()
    local num = math.random(1, 10) .. math.random(111, 999)

    return 'OC' .. num
end

-- Callbacks

QBCore.Functions.CreateCallback('qb-occasions:server:getVehicles', function(_, cb)
    local result = MySQL.query.await('SELECT * FROM occasion_vehicles', {})
    if result[1] then
        cb(result)
    else
        cb(nil)
    end
end)

QBCore.Functions.CreateCallback('qb-occasions:server:checkVehicleOwner', function(source, cb, plate)
    local pData = exports['pfm-core']:GetPlayer(source)
    MySQL.query('SELECT balance FROM player_vehicles WHERE plate = ? AND citizenid = ?', { plate, pData.PlayerData.citizenid }, function(result)
        if result[1] then
            cb(true, result[1].balance)
        else
            cb(false)
        end
    end)
end)

QBCore.Functions.CreateCallback('qb-occasions:server:getSellerInformation', function(_, cb, citizenid)
    MySQL.query('SELECT * FROM players WHERE citizenid = ?', { citizenid }, function(result)
        if result[1] then
            cb(result[1])
        else
            cb(nil)
        end
    end)
end)

QBCore.Functions.CreateCallback('qb-vehiclesales:server:CheckModelName', function(_, cb, plate)
    if plate then
        local ReturnData = MySQL.scalar.await('SELECT vehicle FROM player_vehicles WHERE plate = ?', { plate })
        cb(ReturnData)
    end
end)

-- Events

RegisterNetEvent('qb-occasions:server:ReturnVehicle', function(vehicleData)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or type(vehicleData) ~= 'table' then return end
    if onCooldown(src, 'occasion', 3000) then return end
    if not isAtSaleLot(src) then return end
    local result = MySQL.query.await('SELECT * FROM occasion_vehicles WHERE plate = ? AND occasionid = ?', { vehicleData['plate'], vehicleData['oid'] })
    if result[1] then
        if result[1].seller == Player.PlayerData.citizenid then
            MySQL.insert('INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, state) VALUES (?, ?, ?, ?, ?, ?, ?)', { Player.PlayerData.license, Player.PlayerData.citizenid, vehicleData['model'], joaat(vehicleData['model']), vehicleData['mods'], vehicleData['plate'], 0 })
            MySQL.query('DELETE FROM occasion_vehicles WHERE occasionid = ? AND plate = ?', { vehicleData['oid'], vehicleData['plate'] })
            TriggerClientEvent('qb-occasions:client:ReturnOwnedVehicle', src, result[1])
            TriggerClientEvent('qb-occasion:client:refreshVehicles', -1)
        else
            TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_your_vehicle'), 'error', 3500)
        end
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.vehicle_does_not_exist'), 'error', 3500)
    end
end)

RegisterNetEvent('qb-occasions:server:sellVehicle', function(vehiclePrice, vehicleData)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or type(vehicleData) ~= 'table' then return end
    if onCooldown(src, 'occasion', 3000) then return end
    if not isAtSaleLot(src) then return end
    -- the asking price is player-chosen, but keep it a sane positive integer
    vehiclePrice = math.floor(tonumber(vehiclePrice) or 0)
    if vehiclePrice < 1 or vehiclePrice > 50000000 then return end
    local desc = tostring(vehicleData.desc or ''):sub(1, 250)
    local ownsVehicle = MySQL.query.await('DELETE FROM player_vehicles WHERE plate = ? AND citizenid = ? and vehicle = ?', { vehicleData.plate, Player.PlayerData.citizenid, vehicleData.model })
    if ownsVehicle.affectedRows > 0 then
        MySQL.insert('INSERT INTO occasion_vehicles (seller, price, description, plate, model, mods, occasionid) VALUES (?, ?, ?, ?, ?, ?, ?)', { Player.PlayerData.citizenid, vehiclePrice, desc, vehicleData.plate, vehicleData.model, json.encode(vehicleData.mods), generateOID() })
        TriggerEvent('qb-log:server:CreateLog', 'vehicleshop', 'Vehicle for Sale', 'red', '**' .. GetPlayerName(src) .. '** has a ' .. vehicleData.model .. ' priced at ' .. vehiclePrice)
        TriggerClientEvent('qb-occasion:client:refreshVehicles', -1)
        TriggerClientEvent('QBCore:Notify', src, Lang:t('success.vehicle_listed'), 'success', 5500)
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_your_vehicle'), 'error', 3500)
    end
end)

RegisterNetEvent('qb-occasions:server:sellVehicleBack', function(vehData)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or type(vehData) ~= 'table' then return end
    if onCooldown(src, 'occasion', 3000) then return end
    if not isAtSaleLot(src) then return end
    local price = 0
    local plate = vehData.plate
    for _, v in pairs(sharedVehicles) do
        if v['hash'] == vehData.model then
            price = tonumber(v['price'])
            break
        end
    end
    local ownsVehicle = MySQL.query.await('DELETE FROM player_vehicles WHERE plate = ? AND citizenid = ? and hash = ?', { plate, Player.PlayerData.citizenid, vehData.model })
    if ownsVehicle.affectedRows > 0 then
        local payout = math.floor(tonumber(price * 0.5))
        Player.AddMoney('bank', payout, 'sold vehicle back')
        TriggerClientEvent('QBCore:Notify', src, Lang:t('success.sold_car_for_price', { value = payout }), 'success', 5500)
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_your_vehicle'), 'error', 3500)
    end
end)

RegisterNetEvent('qb-occasions:server:buyVehicle', function(vehicleData)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or type(vehicleData) ~= 'table' then return end
    if onCooldown(src, 'occasionBuy', 3000) then return end
    if not isAtSaleLot(src) then return end
    local result = MySQL.query.await('SELECT * FROM occasion_vehicles WHERE plate = ? AND occasionid = ?', { vehicleData['plate'], vehicleData['oid'] })
    if result[1] and next(result[1]) then
        local subtotal = tonumber(result[1].price) or 0
        local taxAmount = 0

        if subtotal > 0 and GetResourceState('pf-government') == 'started' then
            local okTax, calcTax = pcall(function()
                return exports['pf-government']:CalculateTax(subtotal, 'vehicle_purchase')
            end)
            if okTax then
                taxAmount = tonumber(calcTax) or 0
            end
        end

        local total = math.floor(((subtotal + taxAmount) * 100) + 0.5) / 100

        if Player.PlayerData.money.bank >= total then
            local SellerCitizenId = result[1].seller
            local SellerData = QBCore.Functions.GetPlayerByCitizenId(SellerCitizenId)
            local NewPrice = math.ceil((subtotal / 100) * 77)
            Player.RemoveMoney('bank', total, 'bought vehicle used lot')
            MySQL.insert(
                'INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, state) VALUES (?, ?, ?, ?, ?, ?, ?)', {
                    Player.PlayerData.license,
                    Player.PlayerData.citizenid, result[1]['model'],
                    GetHashKey(result[1]['model']),
                    result[1]['mods'],
                    result[1]['plate'],
                    0
                })
            if SellerData then
                SellerData.Functions.AddMoney('bank', NewPrice, 'sold vehicle used lot')
            else
                local BuyerData = MySQL.query.await('SELECT * FROM players WHERE citizenid = ?', { SellerCitizenId })
                if BuyerData[1] then
                    local BuyerMoney = json.decode(BuyerData[1].money)
                    BuyerMoney.bank = BuyerMoney.bank + NewPrice
                    MySQL.update('UPDATE players SET money = ? WHERE citizenid = ?', { json.encode(BuyerMoney), SellerCitizenId })
                end
            end
            TriggerEvent('qb-log:server:CreateLog', 'vehicleshop', 'bought', 'green', '**' .. GetPlayerName(src) .. '** has bought for ' .. result[1].price .. ' (' .. result[1].plate .. ') from **' .. SellerCitizenId .. '**')

            if taxAmount > 0 and GetResourceState('pf-government') == 'started' then
                pcall(function()
                    exports['pf-government']:CollectTax(subtotal, 'vehicle_purchase', 'citizen', Player.PlayerData.citizenid, 'vehicle_used_lot')
                end)
            end

            TriggerClientEvent('qb-occasions:client:BuyFinished', src, result[1])
            TriggerClientEvent('qb-occasion:client:refreshVehicles', -1)
            MySQL.query('DELETE FROM occasion_vehicles WHERE plate = ? AND occasionid = ?', { result[1].plate, result[1].occasionid })
            TriggerClientEvent('QBCore:Notify', src, ('Vehicle purchase complete. Subtotal: $%.2f | Tax: $%.2f | Total: $%.2f'):format(subtotal, taxAmount, total), 'success')
            exports['pfm-phone']:sendNewMailToOffline(SellerCitizenId, {
                sender = Lang:t('mail.sender'),
                subject = Lang:t('mail.subject'),
                message = Lang:t('mail.message', { value = NewPrice, value2 = sharedVehicles[result[1].model].name })
            })
        else
            TriggerClientEvent('QBCore:Notify', src, ('Not enough money. Subtotal: $%.2f | Tax: $%.2f | Total: $%.2f'):format(subtotal, taxAmount, total), 'error', 3500)
        end
    end
end)
