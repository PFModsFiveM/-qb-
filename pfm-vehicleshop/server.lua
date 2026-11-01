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

-- Shared with server_apps.lua (the Car Dealer apps on the tablet and the computer).
PFShop = PFShop or {}
PFShop.dbReady = false   -- true once this resource's own tables exist (migrations ran)
PFShop.Migrations = {
    { version = 1, name = 'dealership stock and sales record', up = {
        [[CREATE TABLE IF NOT EXISTS `pfm_vehicleshop_stock` (
            `shop` VARCHAR(32) NOT NULL,
            `model` VARCHAR(64) NOT NULL,
            `stock` INT NOT NULL DEFAULT 0,
            `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (`shop`, `model`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
        [[CREATE TABLE IF NOT EXISTS `pfm_vehicleshop_sales` (
            `id` INT NOT NULL AUTO_INCREMENT,
            `shop` VARCHAR(32) NOT NULL,
            `model` VARCHAR(64) NOT NULL,
            `plate` VARCHAR(16) NOT NULL,
            `price` INT NOT NULL DEFAULT 0,
            `tax` DECIMAL(12,2) NOT NULL DEFAULT 0,
            `paid_now` DECIMAL(12,2) NOT NULL DEFAULT 0,
            `financed` TINYINT NOT NULL DEFAULT 0,
            `buyer_cid` VARCHAR(50) DEFAULT NULL,
            `buyer_name` VARCHAR(100) DEFAULT NULL,
            `seller_cid` VARCHAR(50) DEFAULT NULL,
            `seller_name` VARCHAR(100) DEFAULT NULL,
            `commission` INT NOT NULL DEFAULT 0,
            `ledger_key` VARCHAR(100) NOT NULL,
            `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`),
            UNIQUE KEY `ledger_key` (`ledger_key`),
            KEY `shop_created` (`shop`, `created_at`),
            KEY `plate` (`plate`),
            KEY `seller_cid` (`seller_cid`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
    } },
}

--- When this player's play time started being counted for finance (os.time()), if online.
function PFShop.SessionStart(citizenid) return financetimer[citizenid] end

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

--- A dealership employee, in their dealership, sends the customer next to them on a test drive of
--- a car that dealership sells (the customer's client spawns it at the shop's test drive spot,
--- through the checked spawn callback). Returns { ok } or { ok = false, error }.
function PFShop.OfferTestDrive(src, playerid, vehicle)
    local target = tonumber(playerid)
    local seller = exports['pfm-core']:GetPlayer(src)
    if not seller then return { ok = false, error = 'no_player' } end
    local atWork
    for name, shop in pairs(Config.Shops) do
        if shop.Type == 'managed' and shop.Job == seller.PlayerData.job.name and nearShop(src, name) then atWork = name end
    end
    if not atWork then return { ok = false, error = 'not_at_dealership' } end
    if type(vehicle) ~= 'string' or not sellsModel(vehicle, atWork) then return { ok = false, error = 'bad_model' } end
    if not target or not exports['pfm-core']:GetPlayer(target) or target == src then return { ok = false, error = 'Invalid_ID' } end
    if #(GetEntityCoords(GetPlayerPed(src)) - GetEntityCoords(GetPlayerPed(target))) >= 3 then return { ok = false, error = 'playertoofar' } end
    TriggerClientEvent('qb-vehicleshop:client:customTestDrive', target, vehicle)
    return { ok = true }
end

-- Send customer for test drive (a dealership employee, in their dealership)
RegisterNetEvent('qb-vehicleshop:server:customTestDrive', function(vehicle, playerid)
    local src = source
    local res = PFShop.OfferTestDrive(src, playerid, vehicle)
    if res.error == 'Invalid_ID' or res.error == 'playertoofar' then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.' .. res.error), 'error')
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

-- Job fleet cars (pf-jobgarages job_garage_vehicles, active) belong to their job garage: pfm-garages
-- never gives them out of a personal garage, so they cannot be given or sold to another player
-- (the buyer would pay for a car they can never take out). The table may not exist.
local fleetTableKnown = nil
local function fleetTableExists()
    if fleetTableKnown == nil then
        fleetTableKnown = (tonumber(MySQL.scalar.await(
            "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'job_garage_vehicles'")) or 0) > 0
        if not fleetTableKnown then SetTimeout(300000, function() fleetTableKnown = nil end) end
    end
    return fleetTableKnown
end

--- true when the plate is an active fleet car; also true when that cannot be told (refused then).
local function isFleetPlate(plate)
    local ok, fleet = pcall(function()
        if not fleetTableExists() then return false end
        return MySQL.scalar.await('SELECT id FROM job_garage_vehicles WHERE plate = ? AND active = 1 LIMIT 1', { plate }) ~= nil
    end)
    if not ok then return true end
    return fleet
end

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

-- A new car is registered with the city: pf-government bills the registration fee (Bills app).
local function registerVehicle(Player, model, plate)
    if GetResourceState('pf-government') ~= 'started' then return 0 end
    local v = sharedVehicles[model] or {}
    local ok, done, fee = pcall(function()
        return exports['pf-government']:ChargeVehicleRegistration(Player.PlayerData.citizenid, { model = v.name or model, plate = plate })
    end)
    fee = ok and done and tonumber(fee) or 0
    if fee > 0 then
        TriggerClientEvent('QBCore:Notify', Player.PlayerData.source, ('Registration: the DMV billed you $%s (see your bills)'):format(comma_value(math.floor(fee))), 'primary')
    end
    return fee
end

local function deliver(Player, model, plate)
    local src = Player.PlayerData.source
    pendingDelivery[src] = pendingDelivery[src] or {}
    pendingDelivery[src][plate] = model
    TriggerClientEvent('QBCore:Notify', src, Lang:t('success.purchased'), 'success')
    TriggerClientEvent('qb-vehicleshop:client:buyShowroomVehicle', src, model, plate)
    TriggerEvent('qb-vehicleshop:server:onVehiclePurchased', Player.PlayerData.citizenid, model, plate)
    registerVehicle(Player, model, plate)
end

PFShop.ValidModel = function(model) return validModel(model) end
PFShop.SoldAt = soldAt
PFShop.FinanceTerms = financeTerms
PFShop.ShopFor = shopFor

-- ── dealership stock (managed shops; tracked once this resource's table exists) ───────────────────
local function stockTracked(shopName)
    local shop = Config.Shops[shopName]
    return PFShop.dbReady and (Config.Stock or {}).Enabled ~= false and shop ~= nil and shop.Type == 'managed'
end

--- Cars of `model` in stock at the shop, or nil when the shop's stock is not tracked (unlimited).
function PFShop.StockOf(shopName, model)
    if not stockTracked(shopName) then return nil end
    local n = MySQL.scalar.await('SELECT stock FROM pfm_vehicleshop_stock WHERE shop = ? AND model = ?', { shopName, model })
    if n == nil then
        -- a model never stocked yet starts with the configured number of cars
        local initial = math.max(0, math.floor(tonumber((Config.Stock or {}).Initial) or 0))
        MySQL.insert.await('INSERT IGNORE INTO pfm_vehicleshop_stock (shop, model, stock) VALUES (?, ?, ?)', { shopName, model, initial })
        n = MySQL.scalar.await('SELECT stock FROM pfm_vehicleshop_stock WHERE shop = ? AND model = ?', { shopName, model })
    end
    return math.max(0, math.floor(tonumber(n) or 0))
end

--- Stock of every model of a shop: [model] = count (only tracked shops).
function PFShop.ShopStock(shopName)
    local out = {}
    if not stockTracked(shopName) then return out end
    for _, r in ipairs(MySQL.query.await('SELECT model, stock FROM pfm_vehicleshop_stock WHERE shop = ?', { shopName }) or {}) do
        out[r.model] = math.max(0, math.floor(tonumber(r.stock) or 0))
    end
    return out
end

--- Takes one car out of stock for a sale (atomic). True when the shop's stock is not tracked.
function PFShop.TakeStock(shopName, model)
    if not stockTracked(shopName) then return true end
    if PFShop.StockOf(shopName, model) == nil then return true end
    local n = MySQL.update.await('UPDATE pfm_vehicleshop_stock SET stock = stock - 1 WHERE shop = ? AND model = ? AND stock > 0', { shopName, model })
    return (tonumber(n) or 0) == 1
end

function PFShop.ReturnStock(shopName, model)
    if not stockTracked(shopName) then return end
    MySQL.update.await('UPDATE pfm_vehicleshop_stock SET stock = stock + 1 WHERE shop = ? AND model = ?', { shopName, model })
end

function PFShop.AddStock(shopName, model, qty)
    if not stockTracked(shopName) then return false end
    MySQL.insert.await('INSERT INTO pfm_vehicleshop_stock (shop, model, stock) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE stock = stock + ?', { shopName, model, qty, qty })
    return true
end

-- The city's vehicle purchase tax on a dealer sale (0 when pf-government does not answer).
local function purchaseTax(price)
    if GetResourceState('pf-government') ~= 'started' then return 0 end
    local ok, v = pcall(function() return exports['pf-government']:CalculateTax(price, 'vehicle_purchase') end)
    return ok and math.floor((tonumber(v) or 0) * 100 + 0.5) / 100 or 0
end
PFShop.PurchaseTax = purchaseTax

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

--- Charges `amount` from the player's accounts in order under keys base:<n>:<account>, starting at
--- attempt `first`. A key the ledger already closed without moving money (not enough money that
--- time) is skipped, so a later attempt can still pay; a key that completed counts as paid, so a
--- retry after a crash never pays twice; a key still in flight stops the attempt.
--- @return string|false account, string key, table result, number nextAttempt
local function stableCharge(cid, accounts, amount, base, opts, first)
    local attempt = math.max(1, math.floor(tonumber(first) or 1))
    for _ = 1, 50 do
        local key = base .. ':' .. attempt
        local spent, last = 0, nil
        for _, account in ipairs(accounts) do
            local res = PFPayout.Transfer({
                from = ('player:%s:%s'):format(cid, account), to = PFPayout.SYSTEM, amount = amount,
                key = key .. ':' .. account, kind = opts.kind or 'loan_payment', reason = opts.reason, actor = cid,
            })
            if res.ok then return account, key, res, attempt + 1 end
            last = res
            if res.error == 'bank_unavailable' or res.error == 'ledger_unavailable' or res.error == 'in_progress' then
                return false, key, res, attempt
            end
            if res.duplicate then
                if res.state ~= 'failed' and res.state ~= 'compensated' then return false, key, res, attempt end
                spent = spent + 1
            end
        end
        if spent < #accounts then return false, key, last, attempt + 1 end
        attempt = attempt + 1
    end
    return false, nil, { ok = false, error = 'too_many_attempts' }, attempt
end

-- The next attempt of a finance payment key (keys are stable per payment; a failed attempt moves on)
local paymentAttempt = {}   -- [base key] = attempt

local function financeCharge(src, cid, amount, base, reason)
    local account, key, res, nextAttempt = stableCharge(cid, { 'cash', 'bank' }, amount, base, { kind = 'loan_payment', reason = reason }, paymentAttempt[base])
    paymentAttempt[base] = nextAttempt
    if account then paymentAttempt[base] = nil end
    return account, key, res
end

--- One finance payment of at least the instalment on the player's own financed car. The key is
--- fixed by the car's state (plate, payments left, balance, amount), so the same payment retried
--- never charges twice, and the balance update only applies to the state that was paid for.
--- Returns { ok, paid, balance, paymentsLeft } or { ok = false, error, minimum }.
function PFShop.FinancePayment(src, plate, paymentAmount)
    local player = exports['pfm-core']:GetPlayer(src)
    if not player then return { ok = false, error = 'no_player' } end
    paymentAmount = math.floor(tonumber(paymentAmount) or 0)
    if paymentAmount <= 0 or paymentAmount > 100000000 then return { ok = false, error = 'bad_amount' } end
    if type(plate) ~= 'string' or plate == '' or #plate > 16 then return { ok = false, error = 'bad_plate' } end
    if financeBusy[plate] then return { ok = false, error = 'in_progress' } end

    local citizenid = player.PlayerData.citizenid
    local dbRow = MySQL.query.await('SELECT balance, paymentamount, paymentsleft, financetime FROM player_vehicles WHERE plate = ? AND citizenid = ?', { plate, citizenid })
    if not dbRow or not dbRow[1] then return { ok = false, error = 'not_owned' } end
    local row = dbRow[1]
    local balance, minPayment = tonumber(row.balance) or 0, tonumber(row.paymentamount) or 0
    if balance <= 0 then return { ok = false, error = 'alreadypaid' } end
    if paymentAmount < minPayment then return { ok = false, error = 'minimumallowed', minimum = minPayment } end
    local newBalance = balance - paymentAmount
    if newBalance <= 0 then return { ok = false, error = 'overpaid' } end
    local left = tonumber(row.paymentsleft) or 1
    local paymentsLeft = math.max(left - 1, 1)
    local newPayment = round(newBalance / paymentsLeft)

    financeBusy[plate] = true
    local base = ('pfm-vehicleshop:finance:%s:%s:%d:%d:%d'):format(citizenid, plate, left, balance, paymentAmount)
    local ok, account, key = pcall(financeCharge, src, citizenid, paymentAmount, base, 'Vehicle finance payment ' .. plate)
    local result
    if not ok then
        print(('^1[pfm-vehicleshop]^7 finance payment for %s failed: %s'):format(plate, tostring(account)))
        result = { ok = false, error = 'server_error' }
    elseif not account then
        result = { ok = false, error = 'notenoughmoney' }
    else
        local n = MySQL.update.await('UPDATE player_vehicles SET balance = ?, paymentamount = ?, paymentsleft = ?, financetime = ? WHERE plate = ? AND citizenid = ? AND balance = ?',
            { newBalance, newPayment, paymentsLeft, Config.PaymentInterval * 60, plate, citizenid, balance })
        if (tonumber(n) or 0) < 1 then
            -- the car changed meanwhile (paid off, repossessed): the payment goes back
            PFPayout.Pay(citizenid, account, paymentAmount, { key = key .. ':refund', kind = 'refund', reason = 'Vehicle finance payment returned ' .. plate })
            result = { ok = false, error = 'changed' }
        else
            result = { ok = true, paid = paymentAmount, balance = newBalance, paymentsLeft = paymentsLeft, nextPayment = newPayment }
        end
    end
    financeBusy[plate] = nil
    return result
end

--- Pays off the player's own financed car in full.
function PFShop.PayOff(src, plate)
    local player = exports['pfm-core']:GetPlayer(src)
    if not player then return { ok = false, error = 'no_player' } end
    if type(plate) ~= 'string' or plate == '' or #plate > 16 then return { ok = false, error = 'bad_plate' } end
    if financeBusy[plate] then return { ok = false, error = 'in_progress' } end
    local citizenid = player.PlayerData.citizenid
    local dbRow = MySQL.query.await('SELECT balance FROM player_vehicles WHERE plate = ? AND citizenid = ?', { plate, citizenid })
    if not dbRow or not dbRow[1] then return { ok = false, error = 'not_owned' } end
    local vehBalance = tonumber(dbRow[1].balance)
    if not vehBalance or vehBalance <= 0 then return { ok = false, error = 'alreadypaid' } end

    financeBusy[plate] = true
    local base = ('pfm-vehicleshop:payoff:%s:%s:%d'):format(citizenid, plate, vehBalance)
    local ok, account, key = pcall(financeCharge, src, citizenid, vehBalance, base, 'Vehicle paid off ' .. plate)
    local result
    if not ok then
        print(('^1[pfm-vehicleshop]^7 pay-off for %s failed: %s'):format(plate, tostring(account)))
        result = { ok = false, error = 'server_error' }
    elseif not account then
        result = { ok = false, error = 'notenoughmoney' }
    else
        local n = MySQL.update.await('UPDATE player_vehicles SET balance = ?, paymentamount = ?, paymentsleft = ?, financetime = ? WHERE plate = ? AND citizenid = ? AND balance = ?', { 0, 0, 0, 0, plate, citizenid, vehBalance })
        if (tonumber(n) or 0) < 1 then
            PFPayout.Pay(citizenid, account, vehBalance, { key = key .. ':refund', kind = 'refund', reason = 'Vehicle pay-off returned ' .. plate })
            result = { ok = false, error = 'changed' }
        else
            result = { ok = true, paid = vehBalance }
        end
    end
    financeBusy[plate] = nil
    return result
end

local FINANCE_MESSAGES = { not_owned = 'error.notown', notenoughmoney = 'error.notenoughmoney', overpaid = 'error.overpaid', alreadypaid = 'error.alreadypaid' }

-- Make a finance payment
RegisterNetEvent('qb-vehicleshop:server:financePayment', function(paymentAmount, vehData)
    local src = source
    if type(vehData) ~= 'table' then return end
    local res = PFShop.FinancePayment(src, vehData.vehiclePlate, paymentAmount)
    if res.ok then
        if PFShop.PushFinance then PFShop.PushFinance(src) end
    elseif res.error == 'minimumallowed' then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.minimumallowed') .. comma_value(res.minimum), 'error')
    elseif FINANCE_MESSAGES[res.error] then
        TriggerClientEvent('QBCore:Notify', src, Lang:t(FINANCE_MESSAGES[res.error]), 'error')
    end
end)

-- Pay off vehicle in full
RegisterNetEvent('qb-vehicleshop:server:financePaymentFull', function(data)
    local src = source
    if type(data) ~= 'table' then return end
    local res = PFShop.PayOff(src, data.vehPlate)
    if res.ok then
        if PFShop.PushFinance then PFShop.PushFinance(src) end
    elseif FINANCE_MESSAGES[res.error] then
        TriggerClientEvent('QBCore:Notify', src, Lang:t(FINANCE_MESSAGES[res.error]), 'error')
    end
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

local function nameOf(Player)
    local ci = Player and Player.PlayerData.charinfo or {}
    return (('%s %s'):format(ci.firstname or '', ci.lastname or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

local function pushApp(src, app, event, payload)
    if GetResourceState('pf-devices') ~= 'started' then return end
    pcall(function() exports['pf-devices']:Push(src, app, event, payload or {}) end)
end

--- What the customer is shown (in the prompt and in the Car Dealer app).
local function offerView(o)
    local tax = o.tax or 0
    return {
        id = o.id, kind = o.kind, label = o.label, model = o.model, plate = o.plate, shop = o.shopLabel,
        price = o.price, amount = o.amount, tax = tax, total = math.floor((o.amount + tax) * 100 + 0.5) / 100,
        payments = o.terms and o.terms.payments, perPayment = o.terms and o.terms.perPayment, balance = o.terms and o.terms.balance,
        seller = o.sellerName, buyer = o.buyerName, expiresIn = math.max(0, (o.expires or 0) - os.time()),
    }
end
PFShop.OfferView = offerView

function PFShop.PendingOfferFor(src)
    local o = pendingOffers[src]
    if not o or os.time() > o.expires then return nil end
    return offerView(o)
end

--- The offers a seller is waiting on: list of views.
function PFShop.OffersBy(src)
    local out = {}
    for _, o in pairs(pendingOffers) do
        if o.sellerSrc == src and os.time() <= o.expires then out[#out + 1] = offerView(o) end
    end
    return out
end

function PFShop.CancelOffersBy(src)
    local n = 0
    for buyer, o in pairs(pendingOffers) do
        if o.sellerSrc == src then
            pendingOffers[buyer] = nil
            n = n + 1
            TriggerClientEvent('QBCore:Notify', buyer, 'The seller withdrew the offer', 'error')
            pushApp(buyer, 'cardealer', 'offerClosed', { id = o.id })
        end
    end
    return n
end

local function sendOffer(src, target, offer)
    offer.id = PFPayout.NewId()
    offer.sellerSrc = src
    offer.expires = os.time() + OFFER_SECONDS
    offer.buyerName = nameOf(target)
    pendingOffers[target.PlayerData.source] = offer
    local view = offerView(offer)
    -- the prompt answers this offer only (its id): a replaced offer is a new id and a new prompt
    TriggerClientEvent('qb-vehicleshop:client:confirmPurchase', target.PlayerData.source, {
        id = offer.id, label = offer.label, amount = view.total, tax = view.tax, seller = offer.sellerName, kind = offer.kind,
        payments = offer.terms and offer.terms.payments, perPayment = offer.terms and offer.terms.perPayment,
    })
    pushApp(target.PlayerData.source, 'cardealer', 'offer', view)
    TriggerClientEvent('QBCore:Notify', src, 'Offer sent, waiting for the customer', 'primary')
    return view
end

local function saleDistance() return tonumber(Config.SaleDistance) or 3.0 end

--- A dealership employee offers a car (full price, or financed) to the customer next to them.
--- The customer accepts on their own screen; nothing is charged before. Returns { ok, offer } or
--- { ok = false, error }.
function PFShop.DealerOffer(src, playerid, model, downPayment, payments)
    local player = exports['pfm-core']:GetPlayer(src)
    if not player then return { ok = false, error = 'no_player' } end
    local target = exports['pfm-core']:GetPlayer(tonumber(playerid))
    if not target or target.PlayerData.source == src then return { ok = false, error = 'Invalid_ID' } end
    local veh = validModel(model)
    if not veh then return { ok = false, error = 'bad_model' } end
    -- the seller must work at a managed dealership that sells this car, and stand in it
    local shopName, shop = shopFor(src, 'managed', model, player.PlayerData.job.name)
    if not shopName then return { ok = false, error = 'not_at_dealership' } end
    if #(GetEntityCoords(GetPlayerPed(src)) - GetEntityCoords(GetPlayerPed(target.PlayerData.source))) >= saleDistance() then
        return { ok = false, error = 'playertoofar' }
    end
    local price = tonumber(veh.price)
    local terms
    if downPayment ~= nil then
        local err
        terms, err = financeTerms(price, downPayment, payments)
        if not terms then return { ok = false, error = err } end
    end
    local stock = PFShop.StockOf(shopName, model)
    if stock ~= nil and stock < 1 then return { ok = false, error = 'out_of_stock' } end
    local waiting = pendingOffers[target.PlayerData.source]
    if waiting and os.time() <= waiting.expires and waiting.sellerSrc ~= src then return { ok = false, error = 'buyer_busy' } end
    local rate = terms and (Config.FinanceCommission or Config.Commission) or Config.Commission
    local view = sendOffer(src, target, {
        kind = terms and 'finance' or 'dealer', model = model, label = veh.name or model, price = price, terms = terms,
        amount = terms and terms.down or price, tax = purchaseTax(price), job = shop.Job, shop = shopName, shopLabel = shop.ShopLabel,
        sellerCid = player.PlayerData.citizenid, sellerName = nameOf(player),
        commission = round(price * rate),
    })
    return { ok = true, offer = view }
end

local OFFER_MESSAGES = {
    Invalid_ID = 'error.Invalid_ID', playertoofar = 'error.playertoofar', notworth = 'error.notworth',
    downtoosmall = 'error.downtoosmall', exceededmax = 'error.exceededmax',
}
local OFFER_TEXT = { out_of_stock = 'This model is out of stock', buyer_busy = 'That customer is answering another offer' }

local function dealerOffer(src, playerid, model, downPayment, payments)
    local res = PFShop.DealerOffer(src, playerid, model, downPayment, payments)
    if res.ok then return end
    if OFFER_MESSAGES[res.error] then
        TriggerClientEvent('QBCore:Notify', src, Lang:t(OFFER_MESSAGES[res.error]), 'error')
    elseif OFFER_TEXT[res.error] then
        TriggerClientEvent('QBCore:Notify', src, OFFER_TEXT[res.error], 'error')
    end
end

-- Sell a vehicle to a customer (managed dealership)
RegisterNetEvent('qb-vehicleshop:server:sellShowroomVehicle', function(data, playerid)
    dealerOffer(source, playerid, data)
end)

-- Finance a vehicle to a customer (managed dealership)
RegisterNetEvent('qb-vehicleshop:server:sellfinanceVehicle', function(downPayment, paymentAmount, vehicle, playerid)
    dealerOffer(source, playerid, vehicle, downPayment == nil and -1 or downPayment, paymentAmount)
end)

local function recordSale(o, plate, buyer, key)
    if not PFShop.dbReady then return end
    MySQL.insert.await([[INSERT IGNORE INTO pfm_vehicleshop_sales (shop, model, plate, price, tax, paid_now, financed, buyer_cid, buyer_name,
        seller_cid, seller_name, commission, ledger_key) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]], {
        o.shop or '', o.model, plate, o.price, o.tax or 0, o.amount + (o.tax or 0), o.terms and 1 or 0,
        buyer.PlayerData.citizenid, nameOf(buyer), o.sellerCid, o.sellerName, o.commission or 0, key,
    })
end

-- The purchase tax was paid with the car; whatever the government does not take goes back.
local function settleTax(o, cid, key)
    local tax = tonumber(o.tax) or 0
    if tax <= 0 then return 0 end
    local collected = 0
    if GetResourceState('pf-government') == 'started' then
        local ok, value = pcall(function()
            return exports['pf-government']:CollectTaxAmount(tax, 'vehicle_purchase', 'citizen', cid, 'pfm-vehicleshop', key .. ':tax', o.price)
        end)
        collected = ok and (tonumber(value) or 0) or 0
    end
    local uncollected = math.floor((tax - collected) * 100 + 0.5) / 100
    if uncollected > 0 then
        PFPayout.Pay(cid, 'bank', uncollected, { key = key .. ':tax-refund', kind = 'refund', reason = 'Uncollected vehicle tax', quiet = true })
    end
    return collected
end

--- The customer's answer to a dealer sale or a paid vehicle transfer (the prompt, or the Car Dealer
--- app with the offer id). Single use. Returns { ok, ... } or { ok = false, error }.
--- The answer names the offer it was given for: a seller can replace an offer (a higher price) while
--- the customer's click is on its way, and that click must not accept the new one. (Without an id
--- the prompt accepted whatever was pending.) An offer is never changed once sent, so the id also
--- fixes the price that is charged.
function PFShop.AnswerOffer(src, accepted, id)
    local offer = pendingOffers[src]
    if not offer or type(id) ~= 'string' or offer.id ~= id then return { ok = false, error = 'not_found' } end
    pendingOffers[src] = nil
    pushApp(offer.sellerSrc, 'cardealer-sales', 'changed')
    if os.time() > offer.expires then return { ok = false, error = 'expired' } end
    local customer = exports['pfm-core']:GetPlayer(src)
    local seller = exports['pfm-core']:GetPlayer(offer.sellerSrc)
    if not customer or not seller or seller.PlayerData.citizenid ~= offer.sellerCid then return { ok = false, error = 'seller_left' } end
    if accepted ~= true then
        TriggerClientEvent('QBCore:Notify', offer.sellerSrc, 'The customer declined', 'error')
        return { ok = true, declined = true }
    end
    if #(GetEntityCoords(GetPlayerPed(src)) - GetEntityCoords(GetPlayerPed(offer.sellerSrc))) > 5.0 then return { ok = false, error = 'too_far' } end
    local key = ('pfm-vehicleshop:%s:%s'):format(offer.kind, offer.id)
    local cid = customer.PlayerData.citizenid

    if offer.kind == 'transfer' then
        -- the seller must still own the car (and it must not have been financed meanwhile, if that is not allowed)
        local row = MySQL.single.await('SELECT citizenid, balance FROM player_vehicles WHERE plate = ?', { offer.plate })
        if not row or row.citizenid ~= offer.sellerCid or (Config.PreventFinanceSelling and (tonumber(row.balance) or 0) > 0) then return { ok = false, error = 'not_owned' } end
        -- nor put in a job fleet while the offer was open
        if isFleetPlate(offer.plate) then
            TriggerClientEvent('QBCore:Notify', src, 'This vehicle belongs to a job fleet and cannot be sold', 'error')
            TriggerClientEvent('QBCore:Notify', offer.sellerSrc, 'This vehicle belongs to a job fleet and cannot be sold', 'error')
            return { ok = false, error = 'fleet_vehicle' }
        end
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
            return { ok = false, error = 'insufficient_funds' }
        end
        MySQL.update.await('UPDATE player_vehicles SET citizenid = ?, license = ? WHERE plate = ?', { cid, QBCore.Functions.GetIdentifier(src, 'license'), offer.plate })
        TriggerClientEvent('QBCore:Notify', offer.sellerSrc, Lang:t('success.soldfor') .. comma_value(offer.amount), 'success')
        TriggerClientEvent('vehiclekeys:client:SetOwner', src, offer.plate)
        TriggerClientEvent('QBCore:Notify', src, Lang:t('success.boughtfor') .. comma_value(offer.amount), 'success')
        return { ok = true, plate = offer.plate }
    end

    -- dealer sale or dealer finance: still at the dealership, still working there, still in stock
    if not shopFor(offer.sellerSrc, 'managed', offer.model, seller.PlayerData.job.name) then return { ok = false, error = 'seller_unavailable' } end
    if not PFShop.TakeStock(offer.shop, offer.model) then
        TriggerClientEvent('QBCore:Notify', src, 'This model is out of stock', 'error')
        TriggerClientEvent('QBCore:Notify', offer.sellerSrc, 'This model is out of stock', 'error')
        return { ok = false, error = 'out_of_stock' }
    end
    local total = offer.amount + (offer.tax or 0)
    if not PFPayout.Charge(src, { 'cash', 'bank' }, total, { key = key .. ':charge', kind = 'purchase', reason = 'Vehicle ' .. offer.model }) then
        PFShop.ReturnStock(offer.shop, offer.model)
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.notenoughmoney'), 'error')
        TriggerClientEvent('QBCore:Notify', offer.sellerSrc, Lang:t('error.notenoughmoney'), 'error')
        return { ok = false, error = 'insufficient_funds' }
    end
    settleTax(offer, cid, key)
    local plate = GeneratePlate()
    insertVehicle(customer, offer.model, plate, offer.terms)
    PFPayout.PaySociety(offer.job, offer.price, { key = key .. ':dealership', reason = 'Vehicle sale' })
    PFPayout.Pay(offer.sellerCid, 'bank', offer.commission, { key = key .. ':commission', kind = 'wage', reason = 'Vehicle sale commission', quiet = true })
    recordSale(offer, plate, customer, key)
    TriggerClientEvent('QBCore:Notify', offer.sellerSrc, Lang:t('success.earned_commission', { amount = comma_value(offer.commission) }), 'success')
    deliver(customer, offer.model, plate)
    pushApp(src, 'cardealer', 'changed')
    return { ok = true, plate = plate, total = total }
end

-- The customer's answer to a dealer sale or a paid vehicle transfer
-- The prompt sends { accept = bool, id = offer id } (the id came with the prompt); an answer for an
-- offer that is no longer the pending one is refused.
RegisterNetEvent('qb-vehicleshop:server:answerPurchase', function(answer, id)
    local src = source
    local accepted = answer == true
    if type(answer) == 'table' then accepted, id = answer.accept == true, answer.id end
    if type(id) ~= 'string' or #id > 48 then id = nil end
    local res = PFShop.AnswerOffer(src, accepted, id)
    if not res.ok and res.error == 'not_found' and accepted and pendingOffers[src] then
        TriggerClientEvent('QBCore:Notify', src, 'The offer changed. Check the new offer before accepting.', 'error')
    end
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
    -- a job fleet car stays the owner's (it comes back to them when it leaves the fleet)
    if isFleetPlate(plate) then return TriggerClientEvent('QBCore:Notify', src, 'This vehicle belongs to a job fleet. Take it out of the fleet first.', 'error') end
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

-- A deleted character: their cars (and with them their finance) are gone with player_vehicles. The
-- dealership's sales record keeps the sale without their citizen id; open offers and play-time
-- counters of that character are dropped.
AddEventHandler('pfm-core:server:characterDeleted', function(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' or #citizenid > 50 then return end
    financetimer[citizenid] = nil
    for src, cid in pairs(sessionCid) do if cid == citizenid then sessionCid[src] = nil end end
    for buyer, o in pairs(pendingOffers) do
        if o.sellerCid == citizenid then pendingOffers[buyer] = nil end
    end
    if PFShop.dbReady then
        MySQL.update('UPDATE pfm_vehicleshop_sales SET buyer_cid = NULL WHERE buyer_cid = ?', { citizenid })
        MySQL.update('UPDATE pfm_vehicleshop_sales SET seller_cid = NULL WHERE seller_cid = ?', { citizenid })
    end
end)
