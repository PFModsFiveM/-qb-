-- Variables
local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions', 'Commands' })
local sharedVehicles = exports['pfm-core']:GetShared('Vehicles')

local StringCharset = {}
local NumberCharset = {}
for i = 48, 57 do NumberCharset[#NumberCharset + 1] = string.char(i) end
for i = 65, 90 do StringCharset[#StringCharset + 1] = string.char(i) end
for i = 97, 122 do StringCharset[#StringCharset + 1] = string.char(i) end

local function RandomStr(length)
    if length <= 0 then return '' end
    return RandomStr(length - 1) .. StringCharset[math.random(1, #StringCharset)]
end

local function RandomInt(length)
    if length <= 0 then return '' end
    return RandomInt(length - 1) .. NumberCharset[math.random(1, #NumberCharset)]
end

local function Trim(value)
    if not value then return nil end
    return (string.gsub(value, '^%s*(.-)%s*$', '%1'))
end

local financetimer = {}

local vehicleTypes = { -- https://docs.fivem.net/natives/?_0xA273060E
    motorcycles = 'bike',
    boats = 'boat',
    helicopters = 'heli',
    planes = 'plane',
    submarines = 'submarine',
    trailer = 'trailer',
    train = 'train'
}

local function GetVehicleTypeByModel(model)
    local vehicleData = sharedVehicles[model]
    if not vehicleData then return 'automobile' end
    local category = vehicleData.category
    local vehicleType = vehicleTypes[category]
    return vehicleType or 'automobile'
end

-- Handlers

-- Update server-side cached variables when QBCore objects are updated dynamically
AddEventHandler('QBCore:Server:UpdateObject', function()
    QBCore = exports['pfm-core']:GetCoreObject({ 'Functions', 'Commands' })
    sharedVehicles = exports['pfm-core']:GetShared('Vehicles')
end)

-- Finance play-time is counted for the sender's own character. (The citizen id came from the client,
-- so anyone could run down another player's finance timer and get their car repossessed, or keep
-- restarting their own timer so a payment never came due.)
local sessionCid = {} -- [source] = citizenid whose play time is being counted

-- Store game time for player when they load
RegisterNetEvent('qb-vehicleshop:server:addPlayer', function()
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    local citizenid = Player.PlayerData.citizenid
    sessionCid[src] = citizenid
    financetimer[citizenid] = financetimer[citizenid] or os.time()
end)

-- Deduct stored game time from player on logout
RegisterNetEvent('qb-vehicleshop:server:removePlayer', function()
    local src = source
    local citizenid = sessionCid[src]
    sessionCid[src] = nil
    if citizenid and financetimer[citizenid] then
        local playTime = financetimer[citizenid]
        local financetime = MySQL.query.await('SELECT * FROM player_vehicles WHERE citizenid = ?', { citizenid })
        for _, v in pairs(financetime) do
            if v.balance >= 1 then
                local newTime = (v.financetime - ((os.time() - playTime) / 60))
                if newTime < 0 then newTime = 0 end
                MySQL.update('UPDATE player_vehicles SET financetime = ? WHERE plate = ?', { math.ceil(newTime), v.plate })
            end
        end
    end
    financetimer[citizenid] = nil
end)

-- Deduct stored game time from player on quit because we can't get citizenid
AddEventHandler('playerDropped', function()
    local src = source
    sessionCid[src] = nil
    local license
    for _, v in pairs(GetPlayerIdentifiers(src)) do
        if string.sub(v, 1, string.len('license:')) == 'license:' then
            license = v
        end
    end
    if license then
        local vehicles = MySQL.query.await('SELECT * FROM player_vehicles WHERE license = ?', { license })
        if vehicles then
            for _, v in pairs(vehicles) do
                local playTime = financetimer[v.citizenid]
                if v.balance >= 1 and playTime then
                    local newTime = (v.financetime - ((os.time() - playTime) / 60))
                    if newTime < 0 then newTime = 0 end
                    MySQL.update('UPDATE player_vehicles SET financetime = ? WHERE plate = ?', { math.ceil(newTime), v.plate })
                end
            end
            if vehicles[1] and financetimer[vehicles[1].citizenid] then financetimer[vehicles[1].citizenid] = nil end
        end
    end
end)

-- Functions
local function round(x)
    return x >= 0 and math.floor(x + 0.5) or math.ceil(x - 0.5)
end

local function calculateFinance(vehiclePrice, downPayment, paymentamount)
    local balance = vehiclePrice - downPayment
    local vehPaymentAmount = balance / paymentamount
    return round(balance), round(vehPaymentAmount)
end


local function GeneratePlate()
    local plate = RandomInt(1) .. RandomStr(2) .. RandomInt(3) .. RandomStr(2)
    local result = MySQL.scalar.await('SELECT plate FROM player_vehicles WHERE plate = ?', { plate })
    if result then
        return GeneratePlate()
    else
        return plate:upper()
    end
end

local function comma_value(amount)
    local formatted = amount
    local k
    while true do
        formatted, k = string.gsub(formatted, '^(-?%d+)(%d%d%d)', '%1,%2')
        if (k == 0) then
            break
        end
    end
    return formatted
end

-- Callbacks
QBCore.Functions.CreateCallback('qb-vehicleshop:server:getVehicles', function(source, cb)
    local src = source
    local player = exports['pfm-core']:GetPlayer(src)
    if player then
        local vehicles = MySQL.query.await('SELECT * FROM player_vehicles WHERE citizenid = ?', { player.PlayerData.citizenid })
        if vehicles[1] then
            cb(vehicles)
        end
    end
end)

-- Events

-- Brute force vehicle deletion
RegisterNetEvent('qb-vehicleshop:server:deleteVehicle', function(netId)
    local src = source
    local player = exports['pfm-core']:GetPlayer(src)
    if not player then return end
    -- Only allow deletion of entities whose network owner is the requesting player
    local vehicle = NetworkGetEntityFromNetworkId(netId)
    if not DoesEntityExist(vehicle) then return end
    if NetworkGetEntityOwner(vehicle) ~= src then return end
    DeleteEntity(vehicle)
end)

local function nearShop(src, shopName, maxDist)
    local shop = Config.Shops[shopName]
    if not shop or not shop.Location then return false end
    local l = shop.Location
    return #(GetEntityCoords(GetPlayerPed(src)) - vector3(l.x, l.y, l.z)) <= (maxDist or 60.0)
end

local function sellsModel(model, shopName)
    local v = type(model) == 'string' and sharedVehicles[model]
    if not v then return false end
    if type(v.shop) == 'table' then
        for _, s in pairs(v.shop) do if s == shopName then return true end end
        return false
    end
    return v.shop == shopName
end

-- Sync vehicle for other players: a car the shop sells, on one of its showroom spots, by someone in
-- the shop (any client could put any model on any showroom spot for everyone).
RegisterNetEvent('qb-vehicleshop:server:swapVehicle', function(data)
    local src = source
    if type(data) ~= 'table' or type(data.ClosestShop) ~= 'string' then return end
    local shop = Config.Shops[data.ClosestShop]
    local spot = shop and shop.ShowroomVehicles and shop.ShowroomVehicles[tonumber(data.ClosestVehicle)]
    if not spot or not sellsModel(data.toVehicle, data.ClosestShop) or not nearShop(src, data.ClosestShop) then return end
    TriggerClientEvent('qb-vehicleshop:client:swapVehicle', -1, { toVehicle = data.toVehicle, ClosestVehicle = tonumber(data.ClosestVehicle), ClosestShop = data.ClosestShop })
    Wait(1500)                                                -- let new car spawn
    TriggerClientEvent('qb-vehicleshop:client:homeMenu', src) -- reopen main menu
end)

-- Send customer for test drive (a dealership employee, in their dealership)
RegisterNetEvent('qb-vehicleshop:server:customTestDrive', function(vehicle, playerid)
    local src = source
    local target = tonumber(playerid)
    local seller = exports['pfm-core']:GetPlayer(src)
    if not seller then return end
    local atWork = false
    for name, shop in pairs(Config.Shops) do
        if shop.Type == 'managed' and shop.Job == seller.PlayerData.job.name and nearShop(src, name) then atWork = true end
    end
    if not atWork then return end
    if not exports['pfm-core']:GetPlayer(target) or target == src then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.Invalid_ID'), 'error')
        return
    end
    if #(GetEntityCoords(GetPlayerPed(src)) - GetEntityCoords(GetPlayerPed(target))) < 3 then
        TriggerClientEvent('qb-vehicleshop:client:customTestDrive', target, vehicle)
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.playertoofar'), 'error')
    end
end)

-- ── Money ───────────────────────────────────────────────────────────────────────────────────────
-- Every payment goes through the pfm-banking ledger (PFPayout, '@pfm-banking/payouts.lua') under a
-- fixed key, and is taken BEFORE the car is handed over (the car used to be written first and the
-- payment never checked). The amounts are as before: a showroom purchase is paid to the shop
-- (system:pfm-vehicleshop); a dealer sale pays the dealership's account the full price and the
-- salesperson a commission; for a financed car the shop (acting as the lender) pays the dealership
-- the part not yet paid, and later finance payments go back to the shop.
-- Dealer sales and paid /transfervehicle need the customer to accept the offer on their own screen
-- (a nearby player used to be charged without being asked).

local OFFER_SECONDS = 60
local pendingOffers = {}  -- [customer source] = offer
local financeBusy = {}    -- [plate] = true while a finance payment is processed

local function validModel(model)
    local v = type(model) == 'string' and sharedVehicles[model]
    return v and tonumber(v.price) and tonumber(v.price) > 0 and v or nil
end

local function soldAt(model, shopName)
    local v = sharedVehicles[model]
    if not v then return false end
    if type(v.shop) == 'table' then
        for _, s in pairs(v.shop) do if s == shopName then return true end end
        return false
    end
    return v.shop == shopName
end

--- The shop of the given type next to the player that sells `model` (and, for a managed shop, whose
--- job the player has). Returns its name and config.
local function shopFor(src, shopType, model, job)
    local coords = GetEntityCoords(GetPlayerPed(src))
    for name, shop in pairs(Config.Shops) do
        if shop.Type == shopType and soldAt(model, name) and (not job or shop.Job == job)
            and shop.Location and #(coords - vector3(shop.Location.x, shop.Location.y, shop.Location.z)) <= 60.0 then
            return name, shop
        end
    end
end

--- Whole-number finance terms checked against the price; returns balance, per payment or nil, error.
local function financeTerms(price, downPayment, payments)
    downPayment, payments = math.floor(tonumber(downPayment) or -1), math.floor(tonumber(payments) or 0)
    local minDown = tonumber(round((Config.MinimumDown / 100) * price))
    if downPayment > price then return nil, 'notworth' end
    if downPayment < minDown then return nil, 'downtoosmall' end
    if payments < 1 or payments > Config.MaximumPayments then return nil, 'exceededmax' end
    local balance, perPayment = calculateFinance(price, downPayment, payments)
    return { down = downPayment, payments = payments, balance = balance, perPayment = perPayment }
end

local function insertVehicle(Player, model, plate, terms)
    if terms then
        MySQL.insert('INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, garage, state, balance, paymentamount, paymentsleft, financetime) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)', {
            Player.PlayerData.license, Player.PlayerData.citizenid, model, GetHashKey(model), '{}', plate, 'pillboxgarage', 0,
            terms.balance, terms.perPayment, terms.payments, Config.PaymentInterval * 60,
        })
    else
        MySQL.insert('INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, garage, state) VALUES (?, ?, ?, ?, ?, ?, ?, ?)', {
            Player.PlayerData.license, Player.PlayerData.citizenid, model, GetHashKey(model), '{}', plate, 'pillboxgarage', 0,
        })
    end
end

-- Cars bought and not yet driven out: [source][plate] = model. The spawn callback hands out each
-- bought car once, at the shop. (It spawned any owned car, any number of times, wherever the client
-- asked; and refused test drives, which use the plate 'TESTDRIVE'.)
local pendingDelivery = {}
local lastTestDrive = {}
local TESTDRIVE_COOLDOWN = 20

local function deliver(Player, model, plate)
    local src = Player.PlayerData.source
    pendingDelivery[src] = pendingDelivery[src] or {}
    pendingDelivery[src][plate] = model
    TriggerClientEvent('QBCore:Notify', src, Lang:t('success.purchased'), 'success')
    TriggerClientEvent('qb-vehicleshop:client:buyShowroomVehicle', src, model, plate)
    TriggerEvent('qb-vehicleshop:server:onVehiclePurchased', Player.PlayerData.citizenid, model, plate)
end

--- The shop the player stands in (any type) whose cars include `model`, or any shop they stand in.
local function shopAt(src, model)
    local fallback
    for name, shop in pairs(Config.Shops) do
        if nearShop(src, name) then
            if soldAt(model, name) then return name, shop end
            fallback = fallback or name
        end
    end
    if fallback then return fallback, Config.Shops[fallback] end
end

QBCore.Functions.CreateCallback('qb-vehicleshop:server:spawnvehicle', function(source, cb, plate, vehicle, _)
    local src = source
    local player = exports['pfm-core']:GetPlayer(src)
    if not player or type(plate) ~= 'string' or not validModel(vehicle) then cb(nil) return end

    local spawnAt, vehProps = nil, {}
    if plate == 'TESTDRIVE' then
        local _, shop = shopAt(src, vehicle)
        if not shop or not shop.TestDriveSpawn then cb(nil) return end
        if lastTestDrive[src] and os.time() - lastTestDrive[src] < TESTDRIVE_COOLDOWN then cb(nil) return end
        lastTestDrive[src] = os.time()
        spawnAt = shop.TestDriveSpawn
    else
        if not (pendingDelivery[src] and pendingDelivery[src][plate] == vehicle) then
            TriggerClientEvent('QBCore:Notify', src, Lang:t('error.notown'), 'error')
            cb(nil)
            return
        end
        -- Verify the plate belongs to this player and the vehicle model matches
        local row = MySQL.query.await('SELECT mods, vehicle FROM player_vehicles WHERE plate = ? AND citizenid = ?', { plate, player.PlayerData.citizenid })
        if not row or not row[1] or row[1].vehicle ~= vehicle then
            TriggerClientEvent('QBCore:Notify', src, Lang:t('error.notown'), 'error')
            cb(nil)
            return
        end
        local _, shop = shopAt(src, vehicle)
        if not shop or not shop.VehicleSpawn then cb(nil) return end
        pendingDelivery[src][plate] = nil
        spawnAt = shop.VehicleSpawn
        vehProps = row[1].mods and json.decode(row[1].mods) or {}
    end

    local vehType = sharedVehicles[vehicle] and sharedVehicles[vehicle].type or GetVehicleTypeByModel(vehicle)
    local veh = CreateVehicleServerSetter(GetHashKey(vehicle), vehType, spawnAt.x, spawnAt.y, spawnAt.z, spawnAt.w or 0.0)
    local netId = NetworkGetNetworkIdFromEntity(veh)
    SetVehicleNumberPlateText(veh, plate)
    cb(netId, vehProps, plate)
end)

-- Make a finance payment
RegisterNetEvent('qb-vehicleshop:server:financePayment', function(paymentAmount, vehData)
    local src = source
    local player = exports['pfm-core']:GetPlayer(src)
    if not player or type(vehData) ~= 'table' then return end
    local plate = vehData.vehiclePlate
    paymentAmount = math.floor(tonumber(paymentAmount) or 0)
    if paymentAmount <= 0 or type(plate) ~= 'string' or financeBusy[plate] then return end

    local citizenid = player.PlayerData.citizenid
    local dbRow = MySQL.query.await('SELECT balance, paymentamount, paymentsleft, financetime FROM player_vehicles WHERE plate = ? AND citizenid = ?', { plate, citizenid })
    if not dbRow or not dbRow[1] then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.notown'), 'error')
        return
    end
    local row = dbRow[1]
    local balance, minPayment = tonumber(row.balance) or 0, tonumber(row.paymentamount) or 0
    if paymentAmount < minPayment then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.minimumallowed') .. comma_value(minPayment), 'error')
        return
    end
    local newBalance = balance - paymentAmount
    if newBalance <= 0 then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.overpaid'), 'error')
        return
    end
    local paymentsLeft = math.max((tonumber(row.paymentsleft) or 1) - 1, 1)
    local newPayment = round(newBalance / paymentsLeft)

    financeBusy[plate] = true
    local paid = PFPayout.Charge(src, { 'cash', 'bank' }, paymentAmount, {
        key = ('pfm-vehicleshop:finance:%s:%s'):format(plate, PFPayout.NewId()), kind = 'loan_payment', reason = 'Vehicle finance payment ' .. plate,
    })
    if paid then
        MySQL.update.await('UPDATE player_vehicles SET balance = ?, paymentamount = ?, paymentsleft = ?, financetime = ? WHERE plate = ? AND citizenid = ?',
            { newBalance, newPayment, paymentsLeft, Config.PaymentInterval * 60, plate, citizenid })
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.notenoughmoney'), 'error')
    end
    financeBusy[plate] = nil
end)

-- Pay off vehicle in full
RegisterNetEvent('qb-vehicleshop:server:financePaymentFull', function(data)
    local src = source
    local player = exports['pfm-core']:GetPlayer(src)
    if not player or type(data) ~= 'table' then return end
    local vehPlate = data.vehPlate
    if type(vehPlate) ~= 'string' or financeBusy[vehPlate] then return end

    local citizenid = player.PlayerData.citizenid
    local dbRow = MySQL.query.await('SELECT balance FROM player_vehicles WHERE plate = ? AND citizenid = ?', { vehPlate, citizenid })
    if not dbRow or not dbRow[1] then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.notown'), 'error')
        return
    end
    local vehBalance = tonumber(dbRow[1].balance)
    if not vehBalance or vehBalance <= 0 then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.alreadypaid'), 'error')
        return
    end
    financeBusy[vehPlate] = true
    local paid = PFPayout.Charge(src, { 'cash', 'bank' }, vehBalance, {
        key = ('pfm-vehicleshop:payoff:%s:%s'):format(vehPlate, PFPayout.NewId()), kind = 'loan_payment', reason = 'Vehicle paid off ' .. vehPlate,
    })
    if paid then
        MySQL.update.await('UPDATE player_vehicles SET balance = ?, paymentamount = ?, paymentsleft = ?, financetime = ? WHERE plate = ? AND citizenid = ?', { 0, 0, 0, 0, vehPlate, citizenid })
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.notenoughmoney'), 'error')
    end
    financeBusy[vehPlate] = nil
end)

-- Buy a vehicle outright at a free-use shop
RegisterNetEvent('qb-vehicleshop:server:buyShowroomVehicle', function(vehicle)
    local src = source
    local pData = exports['pfm-core']:GetPlayer(src)
    if not pData or type(vehicle) ~= 'table' then return end
    local model = vehicle.buyVehicle
    local veh = validModel(model)
    if not veh or not shopFor(src, 'free-use', model) then return end
    local price = tonumber(veh.price)
    local plate = GeneratePlate()
    if not PFPayout.Charge(src, { 'cash', 'bank' }, price, {
        key = ('pfm-vehicleshop:buy:%s:%s'):format(pData.PlayerData.citizenid, PFPayout.NewId()), kind = 'purchase', reason = 'Vehicle ' .. model,
    }) then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.notenoughmoney'), 'error')
        return
    end
    insertVehicle(pData, model, plate)
    deliver(pData, model, plate)
end)

-- Finance a vehicle at a free-use shop
RegisterNetEvent('qb-vehicleshop:server:financeVehicle', function(downPayment, paymentAmount, vehicle)
    local src = source
    local pData = exports['pfm-core']:GetPlayer(src)
    local veh = validModel(vehicle)
    if not pData or not veh or not shopFor(src, 'free-use', vehicle) then return end
    local terms, err = financeTerms(tonumber(veh.price), downPayment, paymentAmount)
    if not terms then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.' .. err), 'error') end
    local plate = GeneratePlate()
    if not PFPayout.Charge(src, { 'cash', 'bank' }, terms.down, {
        key = ('pfm-vehicleshop:finance-down:%s:%s'):format(pData.PlayerData.citizenid, PFPayout.NewId()), kind = 'purchase', reason = 'Vehicle down payment ' .. vehicle,
    }) then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.notenoughmoney'), 'error')
        return
    end
    insertVehicle(pData, vehicle, plate, terms)
    deliver(pData, vehicle, plate)
end)

local function sendOffer(src, target, offer)
    offer.id = PFPayout.NewId()
    offer.sellerSrc = src
    offer.expires = os.time() + OFFER_SECONDS
    pendingOffers[target.PlayerData.source] = offer
    TriggerClientEvent('qb-vehicleshop:client:confirmPurchase', target.PlayerData.source, {
        label = offer.label, amount = offer.amount, seller = offer.sellerName, kind = offer.kind,
        payments = offer.terms and offer.terms.payments, perPayment = offer.terms and offer.terms.perPayment,
    })
    TriggerClientEvent('QBCore:Notify', src, 'Offer sent, waiting for the customer', 'primary')
end

local function dealerOffer(src, playerid, model, downPayment, payments)
    local player = exports['pfm-core']:GetPlayer(src)
    local target = exports['pfm-core']:GetPlayer(tonumber(playerid))
    if not player then return end
    if not target or target.PlayerData.source == src then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.Invalid_ID'), 'error')
        return
    end
    local veh = validModel(model)
    if not veh then return end
    -- the seller must work at a managed dealership that sells this car, and stand in it
    local shopName, shop = shopFor(src, 'managed', model, player.PlayerData.job.name)
    if not shopName then return end
    if #(GetEntityCoords(GetPlayerPed(src)) - GetEntityCoords(GetPlayerPed(target.PlayerData.source))) >= 3 then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.playertoofar'), 'error')
        return
    end
    local price = tonumber(veh.price)
    local terms
    if downPayment ~= nil then
        local err
        terms, err = financeTerms(price, downPayment, payments)
        if not terms then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.' .. err), 'error') end
    end
    sendOffer(src, target, {
        kind = terms and 'finance' or 'dealer', model = model, label = veh.name or model, price = price, terms = terms,
        amount = terms and terms.down or price, job = shop.Job, sellerCid = player.PlayerData.citizenid,
        sellerName = ('%s %s'):format(player.PlayerData.charinfo.firstname, player.PlayerData.charinfo.lastname),
        commission = round(price * Config.Commission),
    })
end

-- Sell a vehicle to a customer (managed dealership)
RegisterNetEvent('qb-vehicleshop:server:sellShowroomVehicle', function(data, playerid)
    dealerOffer(source, playerid, data)
end)

-- Finance a vehicle to a customer (managed dealership)
RegisterNetEvent('qb-vehicleshop:server:sellfinanceVehicle', function(downPayment, paymentAmount, vehicle, playerid)
    dealerOffer(source, playerid, vehicle, downPayment == nil and -1 or downPayment, paymentAmount)
end)

-- The customer's answer to a dealer sale or a paid vehicle transfer
RegisterNetEvent('qb-vehicleshop:server:answerPurchase', function(accepted)
    local src = source
    local offer = pendingOffers[src]
    pendingOffers[src] = nil
    if not offer or os.time() > offer.expires then return end
    local customer = exports['pfm-core']:GetPlayer(src)
    local seller = exports['pfm-core']:GetPlayer(offer.sellerSrc)
    if not customer or not seller or seller.PlayerData.citizenid ~= offer.sellerCid then return end
    if accepted ~= true then
        TriggerClientEvent('QBCore:Notify', offer.sellerSrc, 'The customer declined', 'error')
        return
    end
    if #(GetEntityCoords(GetPlayerPed(src)) - GetEntityCoords(GetPlayerPed(offer.sellerSrc))) > 5.0 then return end
    local key = ('pfm-vehicleshop:%s:%s'):format(offer.kind, offer.id)
    local cid = customer.PlayerData.citizenid

    if offer.kind == 'transfer' then
        -- the seller must still own the car (and it must not have been financed meanwhile, if that is not allowed)
        local row = MySQL.single.await('SELECT citizenid, balance FROM player_vehicles WHERE plate = ?', { offer.plate })
        if not row or row.citizenid ~= offer.sellerCid or (Config.PreventFinanceSelling and (tonumber(row.balance) or 0) > 0) then return end
        local paid
        for _, account in ipairs({ 'cash', 'bank' }) do
            local res = PFPayout.Transfer({
                from = ('player:%s:%s'):format(cid, account), to = ('player:%s:%s'):format(offer.sellerCid, account), amount = offer.amount,
                key = key .. ':' .. account, kind = 'sale', reason = 'Vehicle ' .. offer.plate, actor = cid,
            })
            if res.ok then paid = true break end
            if res.error == 'bank_unavailable' or res.error == 'ledger_unavailable' then break end
        end
        if not paid then
            TriggerClientEvent('QBCore:Notify', offer.sellerSrc, Lang:t('error.buyertoopoor'), 'error')
            TriggerClientEvent('QBCore:Notify', src, Lang:t('error.notenoughmoney'), 'error')
            return
        end
        MySQL.update.await('UPDATE player_vehicles SET citizenid = ?, license = ? WHERE plate = ?', { cid, QBCore.Functions.GetIdentifier(src, 'license'), offer.plate })
        TriggerClientEvent('QBCore:Notify', offer.sellerSrc, Lang:t('success.soldfor') .. comma_value(offer.amount), 'success')
        TriggerClientEvent('vehiclekeys:client:SetOwner', src, offer.plate)
        TriggerClientEvent('QBCore:Notify', src, Lang:t('success.boughtfor') .. comma_value(offer.amount), 'success')
        return
    end

    -- dealer sale or dealer finance: still at the dealership, still working there
    if not shopFor(offer.sellerSrc, 'managed', offer.model, seller.PlayerData.job.name) then return end
    if not PFPayout.Charge(src, { 'cash', 'bank' }, offer.amount, { key = key .. ':charge', kind = 'purchase', reason = 'Vehicle ' .. offer.model }) then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.notenoughmoney'), 'error')
        TriggerClientEvent('QBCore:Notify', offer.sellerSrc, Lang:t('error.notenoughmoney'), 'error')
        return
    end
    local plate = GeneratePlate()
    insertVehicle(customer, offer.model, plate, offer.terms)
    PFPayout.PaySociety(offer.job, offer.price, { key = key .. ':dealership', reason = 'Vehicle sale' })
    PFPayout.Pay(offer.sellerCid, 'bank', offer.commission, { key = key .. ':commission', kind = 'wage', reason = 'Vehicle sale commission', quiet = true })
    TriggerClientEvent('QBCore:Notify', offer.sellerSrc, Lang:t('success.earned_commission', { amount = comma_value(offer.commission) }), 'success')
    deliver(customer, offer.model, plate)
end)

AddEventHandler('playerDropped', function()
    pendingOffers[source] = nil
    pendingDelivery[source] = nil
    lastTestDrive[source] = nil
end)

-- Check if payment is due
RegisterNetEvent('qb-vehicleshop:server:checkFinance', function()
    local src = source
    local player = exports['pfm-core']:GetPlayer(src)
    if not player then return end
    local query = 'SELECT * FROM player_vehicles WHERE citizenid = ? AND balance > 0 AND financetime < 1'
    local result = MySQL.query.await(query, { player.PlayerData.citizenid })
    if result[1] then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('general.paymentduein', { time = Config.PaymentWarning }))
        Wait(Config.PaymentWarning * 60000)
        local vehicles = MySQL.query.await(query, { player.PlayerData.citizenid })
        for _, v in pairs(vehicles) do
            local plate = v.plate
            MySQL.query('DELETE FROM player_vehicles WHERE plate = @plate', { ['@plate'] = plate })
            --MySQL.update('UPDATE player_vehicles SET citizenid = ? WHERE plate = ?', {'REPO-'..v.citizenid, plate}) -- Use this if you don't want them to be deleted
            TriggerClientEvent('QBCore:Notify', src, Lang:t('error.repossessed', { plate = plate }), 'error')
        end
    end
end)

-- Transfer vehicle to player in passenger seat
QBCore.Commands.Add('transfervehicle', Lang:t('general.command_transfervehicle'), { { name = 'ID', help = Lang:t('general.command_transfervehicle_help') }, { name = 'amount', help = Lang:t('general.command_transfervehicle_amount') } }, false, function(source, args)
    local src = source
    local buyerId = tonumber(args[1])
    local sellAmount = tonumber(args[2])
    if buyerId == 0 then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.Invalid_ID'), 'error') end
    local ped = GetPlayerPed(src)
    local targetPed = GetPlayerPed(buyerId)
    if targetPed == 0 then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.buyerinfo'), 'error') end
    local vehicle = GetVehiclePedIsIn(ped, false)
    if vehicle == 0 then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.notinveh'), 'error') end
    local plate = Trim(GetVehicleNumberPlateText(vehicle))
    if not plate then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.vehinfo'), 'error') end
    local player = exports['pfm-core']:GetPlayer(src)
    local target = exports['pfm-core']:GetPlayer(buyerId)
    local row = MySQL.single.await('SELECT * FROM player_vehicles WHERE plate = ?', { plate })
    if not row or not player then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.notown'), 'error') end
    if Config.PreventFinanceSelling then
        if row.balance > 0 then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.financed'), 'error') end
    end
    if row.citizenid ~= player.PlayerData.citizenid then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.notown'), 'error') end
    if #(GetEntityCoords(ped) - GetEntityCoords(targetPed)) > 5.0 then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.playertoofar'), 'error') end
    if not target then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.buyerinfo'), 'error') end
    local targetcid = target.PlayerData.citizenid
    if targetcid == player.PlayerData.citizenid then return end
    if not sellAmount then
        local targetlicense = QBCore.Functions.GetIdentifier(target.PlayerData.source, 'license')
        MySQL.update('UPDATE player_vehicles SET citizenid = ?, license = ? WHERE plate = ?', { targetcid, targetlicense, plate })
        TriggerClientEvent('QBCore:Notify', src, Lang:t('success.gifted'), 'success')
        TriggerClientEvent('vehiclekeys:client:SetOwner', buyerId, plate)
        TriggerClientEvent('QBCore:Notify', buyerId, Lang:t('success.received_gift'), 'success')
        return
    end
    -- a sale: the buyer accepts the price on their screen, then pays through the ledger
    -- (the buyer used to be charged whatever the seller typed, without being asked)
    sellAmount = math.floor(sellAmount)
    if sellAmount <= 0 then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.buyertoopoor'), 'error') end
    local veh = sharedVehicles[row.vehicle]
    sendOffer(src, target, {
        kind = 'transfer', plate = plate, label = (veh and veh.name or row.vehicle) .. ' (' .. plate .. ')', amount = sellAmount,
        sellerCid = player.PlayerData.citizenid,
        sellerName = ('%s %s'):format(player.PlayerData.charinfo.firstname, player.PlayerData.charinfo.lastname),
    })
end)

-- Dynamically update showrooms if a vehicle gets removed from QBCore.Shared.Vehicles (Server-Side Only for Security)
AddEventHandler('qb-vehicleshop:server:UpdateShowroomAfterDeletion', function(deletedModel, deletedCategory)
    local currentVehicles = exports['pfm-core']:GetShared('Vehicles')
    local shopPools = {}

    -- Pre-index pools for performance (O(N) instead of O(N^2))
    for shopName in pairs(Config.Shops) do
        shopPools[shopName] = { fallbackPool = {}, categoryPools = {} }
    end

    for model, vehicle in pairs(currentVehicles) do
        if model ~= deletedModel then
            local shops = type(vehicle.shop) == 'table' and vehicle.shop or { vehicle.shop }
            
            for _, shopName in ipairs(shops) do
                local pool = shopPools[shopName]
                if pool then
                    pool.fallbackPool[#pool.fallbackPool + 1] = model
                    local category = vehicle.category
                    if not pool.categoryPools[category] then pool.categoryPools[category] = {} end
                    pool.categoryPools[category][#pool.categoryPools[category] + 1] = model
                end
            end
        end
    end

    for shopName in pairs(Config.Shops) do
        local replacement = nil
        local pool = shopPools[shopName]
        local sameCatPool = pool.categoryPools[deletedCategory] or {}
        local fallbackPool = pool.fallbackPool
        
        -- Prioritize same category, fallback to any vehicle in the shop
        if #sameCatPool > 0 then
            replacement = sameCatPool[math.random(1, #sameCatPool)]
        elseif #fallbackPool > 0 then
            replacement = fallbackPool[math.random(1, #fallbackPool)]
        end
        
        if replacement then
            TriggerClientEvent('qb-vehicleshop:client:ReplaceDeletedVehicle', -1, shopName, deletedModel, replacement)
        end
    end
end)
