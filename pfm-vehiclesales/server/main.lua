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
            exports['pfm-core']:GrantVehicleSpawn(src, result[1].model)
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
    -- the car is only given up while the bank can pay for it
    if GetResourceState('pfm-banking') ~= 'started' then
        TriggerClientEvent('QBCore:Notify', src, 'The bank is not available right now', 'error')
        return
    end
    local ownsVehicle = MySQL.query.await('DELETE FROM player_vehicles WHERE plate = ? AND citizenid = ? and hash = ?', { plate, Player.PlayerData.citizenid, vehData.model })
    if ownsVehicle.affectedRows > 0 then
        local payout = math.floor(tonumber(price * 0.5))
        PFPayout.Pay(src, 'bank', payout, {
            key = ('pfm-vehiclesales:sellback:%s:%s:%s'):format(tostring(plate), Player.PlayerData.citizenid, PFPayout.NewId()),
            kind = 'sale', reason = 'Vehicle sold back',
        })
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
            local listing = result[1]
            local SellerCitizenId = listing.seller
            local buyerCid = Player.PlayerData.citizenid
            if SellerCitizenId == buyerCid then return end -- your own listing: take it back instead
            local NewPrice = math.ceil((subtotal / 100) * 77)
            -- 1) the buyer pays (keyed), 2) the listing is claimed by one DELETE, so of two buyers at
            -- the same moment only one gets the car and the other is refunded, 3) the seller (online
            -- or offline) and the tax are paid through the ledger. (RemoveMoney was not checked, both
            -- buyers could get the car, and an offline seller's money record was rewritten.)
            local key = ('pfm-vehiclesales:buy:%s:%s:%s'):format(tostring(listing.occasionid), tostring(listing.plate), PFPayout.NewId())
            if not PFPayout.Charge(src, 'bank', total, { key = key, kind = 'purchase', reason = 'Used vehicle ' .. tostring(listing.plate) }) then
                TriggerClientEvent('QBCore:Notify', src, ('Not enough money. Subtotal: $%.2f | Tax: $%.2f | Total: $%.2f'):format(subtotal, taxAmount, total), 'error', 3500)
                return
            end
            local claimed = MySQL.query.await('DELETE FROM occasion_vehicles WHERE plate = ? AND occasionid = ?', { listing.plate, listing.occasionid })
            if not claimed or (claimed.affectedRows or 0) < 1 then
                PFPayout.Pay(buyerCid, 'bank', total, { key = key .. ':refund', kind = 'refund', reason = 'Vehicle already sold' })
                TriggerClientEvent('QBCore:Notify', src, Lang:t('error.vehicle_does_not_exist'), 'error', 3500)
                return
            end
            MySQL.insert(
                'INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, state) VALUES (?, ?, ?, ?, ?, ?, ?)', {
                    Player.PlayerData.license,
                    buyerCid, listing['model'],
                    GetHashKey(listing['model']),
                    listing['mods'],
                    listing['plate'],
                    0
                })
            PFPayout.Pay(SellerCitizenId, 'bank', NewPrice, { key = key .. ':seller', kind = 'sale', reason = 'Vehicle sold on the used lot', quiet = true })
            TriggerEvent('qb-log:server:CreateLog', 'vehicleshop', 'bought', 'green', '**' .. GetPlayerName(src) .. '** has bought for ' .. listing.price .. ' (' .. listing.plate .. ') from **' .. SellerCitizenId .. '**')

            -- the tax was paid with the car; whatever the government does not take goes back to the buyer
            local collected = 0
            if taxAmount > 0 and GetResourceState('pf-government') == 'started' then
                local ok, value = pcall(function()
                    return exports['pf-government']:CollectTaxAmount(taxAmount, 'vehicle_purchase', 'citizen', buyerCid, 'vehicle_used_lot', key .. ':tax', subtotal)
                end)
                collected = ok and (tonumber(value) or 0) or 0
            end
            local uncollected = math.floor((taxAmount - collected) * 100 + 0.5) / 100
            if uncollected > 0 then
                PFPayout.Pay(buyerCid, 'bank', uncollected, { key = key .. ':tax-refund', kind = 'refund', reason = 'Uncollected vehicle tax', quiet = true })
            end

            exports['pfm-core']:GrantVehicleSpawn(src, listing.model)
            TriggerClientEvent('qb-occasions:client:BuyFinished', src, listing)
            TriggerClientEvent('qb-occasion:client:refreshVehicles', -1)
            TriggerClientEvent('QBCore:Notify', src, ('Vehicle purchase complete. Subtotal: $%.2f | Tax: $%.2f | Total: $%.2f'):format(subtotal, taxAmount, total), 'success')
            local shared = sharedVehicles[listing.model]
            exports['pfm-phone']:sendNewMailToOffline(SellerCitizenId, {
                sender = Lang:t('mail.sender'),
                subject = Lang:t('mail.subject'),
                message = Lang:t('mail.message', { value = NewPrice, value2 = shared and shared.name or listing.model })
            })
        else
            TriggerClientEvent('QBCore:Notify', src, ('Not enough money. Subtotal: $%.2f | Tax: $%.2f | Total: $%.2f'):format(subtotal, taxAmount, total), 'error', 3500)
        end
    end
end)
