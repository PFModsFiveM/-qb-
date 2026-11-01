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
    -- money a sale still owes (retried until paid) and sales whose charge the bank has not
    -- confirmed yet (settlements.lua)
    { version = 2, name = 'owed payments and held sales', up = PFSettle.MigrationSteps('pfm_vehicleshop') },
}
PFSettle.Init('pfm_vehicleshop')
PFSettle.MailSender = 'Vehicle dealership'

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
-- payment never checked). A showroom purchase is paid to the shop (system:pfm-vehicleshop). A
-- dealer sale splits the price: the salesperson's commission comes out of it and the dealership's
-- account gets the rest (the commission used to be paid on top of the full price, which created
-- money). For a financed car the shop, acting as the lender, pays out the part not yet paid, and
-- later finance payments go back to the shop.
-- Dealer sales and paid /transfervehicle need the customer to accept the offer on their own screen
-- (a nearby player used to be charged without being asked). A paid transfer goes through the shop's
-- account: the buyer pays in, the car changes hands, then the seller is paid (or the buyer refunded).

local OFFER_SECONDS = 60
local pendingOffers = {}  -- [customer source] = offer
local financeBusy = {}    -- [plate] = true while a finance payment is processed

-- Job fleet cars (pf-jobgarages job_garage_vehicles, active) belong to their job garage: pfm-garages
-- never gives them out of a personal garage, so they cannot be given or sold to another player
-- (the buyer would pay for a car they can never take out). The table may not exist.
-- A failed lookup is not cached and not taken as "no table" (that would let a fleet car through
-- for 5 minutes): callers refuse while it cannot be told.
local fleetTableKnown = nil
--- true / false, or nil when the lookup failed.
local function fleetTableExists()
    if fleetTableKnown == nil then
        local ok, n = pcall(MySQL.scalar.await,
            "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'job_garage_vehicles'")
        n = ok and tonumber(n) or nil
        if n == nil then return nil end
        -- "no table" is asked again after 5 minutes (the resource may be installed meanwhile)
        local exists = n > 0
        fleetTableKnown = exists
        if not exists then SetTimeout(300000, function() fleetTableKnown = nil end) end
        return exists
    end
    return fleetTableKnown
end

--- true when the plate is an active fleet car; also true when that cannot be told (refused then).
local function isFleetPlate(plate)
    local ok, fleet = pcall(function()
        local exists = fleetTableExists()
        if exists == nil then error('fleet table lookup failed') end
        if not exists then return false end
        return MySQL.scalar.await('SELECT id FROM job_garage_vehicles WHERE plate = ? AND active = 1 LIMIT 1', { plate }) ~= nil
    end)
    if not ok then return true end
    return fleet
end

--- The condition an ownership change adds, so a car put in a fleet after the check does not change
--- hands in the same moment (one statement). Returns sql, params; nil when it cannot be told.
local function notInFleet(plate)
    local exists = fleetTableExists()
    if exists == nil then return nil end
    if exists then
        return ' AND NOT EXISTS (SELECT 1 FROM job_garage_vehicles WHERE plate = ? AND active = 1)', { plate }
    end
    return '', {}
end

-- [plate] = true while the car is changing hands (/transfervehicle gift, an accepted paid transfer):
-- the ownership check and the change are separated by database and ledger waits.
local plateBusy = {}

--- Why the car cannot go from `sellerCid` to another player now, or nil: not theirs any more,
--- financed (when Config.PreventFinanceSelling), owing more than the buyer was shown, or a fleet car.
local function transferRefusal(plate, sellerCid, loanShown)
    local row = MySQL.single.await('SELECT citizenid, balance FROM player_vehicles WHERE plate = ?', { plate })
    if not row or row.citizenid ~= sellerCid then return 'not_owned' end
    local balance = tonumber(row.balance) or 0
    if balance > 0 and Config.PreventFinanceSelling then return 'financed' end
    -- a loan comes with the car: the buyer accepts the balance their offer showed, not a larger one
    if loanShown and balance > loanShown then return 'vehicle_changed' end
    if isFleetPlate(plate) then return 'fleet_vehicle' end
    return nil
end

--- Moves the car to the new owner only in the state that was checked: still the seller's, the loan
--- not above what the buyer saw, not in a fleet. Returns true when it moved.
local function claimTransfer(plate, sellerCid, buyerCid, buyerLicense, loanShown)
    local fleetSql, fleetParams = notInFleet(plate)
    if not fleetSql then return false end
    local maxBalance = Config.PreventFinanceSelling and 0 or (loanShown or 0)
    local n = MySQL.update.await('UPDATE player_vehicles SET citizenid = ?, license = ? WHERE plate = ? AND citizenid = ? AND balance <= ?' .. fleetSql,
        { buyerCid, buyerLicense, plate, sellerCid, maxBalance, table.unpack(fleetParams) })
    return (tonumber(n) or 0) > 0
end

local TRANSFER_TEXT = {
    not_owned = 'error.notown', financed = 'error.financed', fleet_vehicle = 'error.fleet_vehicle', vehicle_changed = 'error.transfer_changed',
}

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

-- Where a car whose payment cleared later is parked (the buyer may be anywhere, or offline).
local function deliveryGarage() return type(Config.DeliveryGarage) == 'string' and Config.DeliveryGarage or 'pillboxgarage' end

--- Writes a bought car to the buyer's garage record. owner = { license, citizenid }. A car handed
--- over at the shop is out (state 0, it spawns there); a parked one waits in the delivery garage.
--- Returns the insert id or nil.
local function insertVehicle(owner, model, plate, terms, parked)
    local garage, state = parked and deliveryGarage() or 'pillboxgarage', parked and 1 or 0
    local ok, id = pcall(function()
        if terms then
            return MySQL.insert.await('INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, garage, state, balance, paymentamount, paymentsleft, financetime) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)', {
                owner.license, owner.citizenid, model, GetHashKey(model), '{}', plate, garage, state,
                terms.balance, terms.perPayment, terms.payments, Config.PaymentInterval * 60,
            })
        end
        return MySQL.insert.await('INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, garage, state) VALUES (?, ?, ?, ?, ?, ?, ?, ?)', {
            owner.license, owner.citizenid, model, GetHashKey(model), '{}', plate, garage, state,
        })
    end)
    if not ok then print(('^1[pfm-vehicleshop]^7 could not write vehicle %s: %s'):format(tostring(plate), tostring(id))) end
    return ok and id or nil
end

local function ownerOf(Player) return { license = Player.PlayerData.license, citizenid = Player.PlayerData.citizenid } end

-- Cars bought and not yet driven out: [source][plate] = model. The spawn callback hands out each
-- bought car once, at the shop. (It spawned any owned car, any number of times, wherever the client
-- asked; and refused test drives, which use the plate 'TESTDRIVE'.)
local pendingDelivery = {}
local lastTestDrive = {}
local TESTDRIVE_COOLDOWN = 20

-- A new car is registered with the city: pf-government bills the registration fee (Bills app).
local function registerVehicle(cid, model, plate, src)
    if GetResourceState('pf-government') ~= 'started' then return 0 end
    local v = sharedVehicles[model] or {}
    local ok, done, fee = pcall(function()
        return exports['pf-government']:ChargeVehicleRegistration(cid, { model = v.name or model, plate = plate })
    end)
    fee = ok and done and tonumber(fee) or 0
    if fee > 0 and src then
        TriggerClientEvent('QBCore:Notify', src, ('Registration: the DMV billed you $%s (see your bills)'):format(comma_value(math.floor(fee))), 'primary')
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
    registerVehicle(Player.PlayerData.citizenid, model, plate, src)
end

--- The salesperson's commission on a dealer sale (Config.Commission, or Config.FinanceCommission for
--- a financed one). It is taken out of the price: the dealership gets the price less this.
local function commissionFor(price, financed)
    local rate = tonumber(financed and (Config.FinanceCommission or Config.Commission) or Config.Commission) or 0
    return math.max(0, math.min(price, round(price * rate)))
end
PFShop.CommissionFor = commissionFor

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

-- Errors the ledger returns before it writes anything (nothing moved), as in payouts.lua.
local REFUSED_BEFORE_WRITE = {
    insufficient_funds = true, invalid_request = true, invalid_account = true, same_account = true,
    invalid_amount = true, invalid_key = true,
}

--- Whether a charge attempt clearly took nothing: failed (not interrupted during the debit, where
--- the money may have left), compensated (given back), or refused before anything was written.
local function closedWithoutMoney(res)
    if res.state == 'compensated' then return true end
    if res.state == 'failed' then return res.error ~= 'interrupted_unverified' end
    return res.state == nil and res.txId == nil and REFUSED_BEFORE_WRITE[res.error] == true
end

--- Charges `amount` from the player's accounts in order under keys base:<n>:<account>, starting at
--- attempt `first`. A key the ledger already closed without moving money (not enough money that
--- time) is skipped, so a later attempt can still pay; a key that completed counts as paid, so a
--- retry after a crash never pays twice. Any outcome that is not known yet (in flight, written but
--- not settled, interrupted during the debit) stops there with result.unclear: nothing is taken from
--- the next account and no later attempt key is used (it could pay a second time once the first
--- settles).
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
            if res.error == 'bank_unavailable' or res.error == 'ledger_unavailable' then
                return false, key, res, attempt
            end
            if not closedWithoutMoney(res) then
                res.unclear = true
                return false, key, res, attempt
            end
            if res.duplicate then spent = spent + 1 end
        end
        if spent < #accounts then return false, key, last, attempt + 1 end
        attempt = attempt + 1
    end
    return false, nil, { ok = false, error = 'too_many_attempts' }, attempt
end

-- The next attempt of a finance payment key (keys are stable per payment; a failed attempt moves on)
local paymentAttempt = {}   -- [base key] = attempt

local FINANCE_ACCOUNTS = { 'cash', 'bank' }

local function financeCharge(src, cid, amount, base, reason)
    local account, key, res, nextAttempt = stableCharge(cid, FINANCE_ACCOUNTS, amount, base, { kind = 'loan_payment', reason = reason }, paymentAttempt[base])
    paymentAttempt[base] = nextAttempt
    if account then paymentAttempt[base] = nil end
    return account, key, res
end

--- When a charge's outcome is not known yet (res.unclear), stores the sale as held (settlements.lua)
--- and tells the buyer; returns the hold then, nil otherwise. The caller hands nothing over: the
--- held sale is finished, or released, when the ledger settles that charge.
local function holdIfUnclear(res, opts)
    if type(res) ~= 'table' or not res.unclear then return nil end
    local hold = PFSettle.Hold({
        flow = opts.flow, key = opts.key, accounts = opts.accounts, citizenid = opts.cid, amount = opts.amount,
        plate = opts.plate, txId = res.txId, data = opts.data,
    })
    PFSettle.Tell(opts.cid, Lang:t(opts.message or 'general.payment_held', { vehicle = opts.label or '', garage = deliveryGarage(), ref = hold.ref }), 'primary')
    return hold
end

--- The message for a charge that clearly took nothing: the bank not running, or not enough money.
local function refusedText(res)
    local err = type(res) == 'table' and res.error
    if err == 'bank_unavailable' or err == 'ledger_unavailable' then return 'error.bank_unavailable' end
    return 'error.notenoughmoney'
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
    -- an earlier payment on this car still waits on the bank: it is applied (or not) first
    if PFSettle.PlateHeld(plate) then return { ok = false, error = 'payment_waiting' } end

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
    local ok, account, key, res = pcall(financeCharge, src, citizenid, paymentAmount, base, 'Vehicle finance payment ' .. plate)
    local result
    local change = { plate = plate, balance = balance, newBalance = newBalance, newPayment = newPayment, paymentsLeft = paymentsLeft, amount = paymentAmount }
    if not ok then
        print(('^1[pfm-vehicleshop]^7 finance payment for %s failed: %s'):format(plate, tostring(account)))
        result = { ok = false, error = 'server_error' }
    elseif not account then
        local hold = holdIfUnclear(res, { flow = 'payment', key = key, accounts = FINANCE_ACCOUNTS, cid = citizenid, amount = paymentAmount,
            plate = plate, data = change, message = 'general.finance_payment_held' })
        result = hold and { ok = false, error = 'payment_held', ref = hold.ref } or { ok = false, error = 'notenoughmoney' }
    else
        result = PFShop.ApplyFinancePayment(citizenid, account, key, change)
    end
    financeBusy[plate] = nil
    return result
end

--- Applies a paid finance payment (or pay-off) to the car, only in the state it was paid for; if the
--- car changed meanwhile (paid off, repossessed) the payment goes back. Rerun-safe: a change that is
--- already on the car is not refunded.
function PFShop.ApplyFinancePayment(citizenid, account, key, c)
    local interval = c.newBalance > 0 and Config.PaymentInterval * 60 or 0
    local n = MySQL.update.await('UPDATE player_vehicles SET balance = ?, paymentamount = ?, paymentsleft = ?, financetime = ? WHERE plate = ? AND citizenid = ? AND balance = ?',
        { c.newBalance, c.newPayment, c.paymentsLeft, interval, c.plate, citizenid, c.balance })
    if (tonumber(n) or 0) >= 1 then
        return { ok = true, paid = c.amount, balance = c.newBalance, paymentsLeft = c.paymentsLeft, nextPayment = c.newPayment }
    end
    local now = MySQL.single.await('SELECT balance, paymentsleft FROM player_vehicles WHERE plate = ? AND citizenid = ?', { c.plate, citizenid })
    if now and tonumber(now.balance) == c.newBalance and tonumber(now.paymentsleft) == c.paymentsLeft then
        return { ok = true, paid = c.amount, balance = c.newBalance, paymentsLeft = c.paymentsLeft, nextPayment = c.newPayment }
    end
    PFSettle.Owe({ key = key .. ':refund', to = citizenid, account = account, amount = c.amount, kind = 'refund',
        reason = 'Vehicle finance payment returned ' .. c.plate, label = 'a returned finance payment' })
    return { ok = false, error = 'changed' }
end

--- Pays off the player's own financed car in full.
function PFShop.PayOff(src, plate)
    local player = exports['pfm-core']:GetPlayer(src)
    if not player then return { ok = false, error = 'no_player' } end
    if type(plate) ~= 'string' or plate == '' or #plate > 16 then return { ok = false, error = 'bad_plate' } end
    if financeBusy[plate] then return { ok = false, error = 'in_progress' } end
    if PFSettle.PlateHeld(plate) then return { ok = false, error = 'payment_waiting' } end
    local citizenid = player.PlayerData.citizenid
    local dbRow = MySQL.query.await('SELECT balance FROM player_vehicles WHERE plate = ? AND citizenid = ?', { plate, citizenid })
    if not dbRow or not dbRow[1] then return { ok = false, error = 'not_owned' } end
    local vehBalance = tonumber(dbRow[1].balance)
    if not vehBalance or vehBalance <= 0 then return { ok = false, error = 'alreadypaid' } end

    financeBusy[plate] = true
    local base = ('pfm-vehicleshop:payoff:%s:%s:%d'):format(citizenid, plate, vehBalance)
    local ok, account, key, res = pcall(financeCharge, src, citizenid, vehBalance, base, 'Vehicle paid off ' .. plate)
    local result
    local change = { plate = plate, balance = vehBalance, newBalance = 0, newPayment = 0, paymentsLeft = 0, amount = vehBalance }
    if not ok then
        print(('^1[pfm-vehicleshop]^7 pay-off for %s failed: %s'):format(plate, tostring(account)))
        result = { ok = false, error = 'server_error' }
    elseif not account then
        local hold = holdIfUnclear(res, { flow = 'payment', key = key, accounts = FINANCE_ACCOUNTS, cid = citizenid, amount = vehBalance,
            plate = plate, data = change, message = 'general.finance_payment_held' })
        result = hold and { ok = false, error = 'payment_held', ref = hold.ref } or { ok = false, error = 'notenoughmoney' }
    else
        result = PFShop.ApplyFinancePayment(citizenid, account, key, change)
        if result.ok then result = { ok = true, paid = vehBalance } end
    end
    financeBusy[plate] = nil
    return result
end

local FINANCE_MESSAGES = {
    not_owned = 'error.notown', notenoughmoney = 'error.notenoughmoney', overpaid = 'error.overpaid', alreadypaid = 'error.alreadypaid',
    payment_waiting = 'error.payment_waiting',
}

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
    local cid = pData.PlayerData.citizenid
    -- a purchase of theirs still waits on the bank: a second click would buy a second car
    if PFSettle.BuyerWaiting(cid) then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.payment_waiting'), 'error') end
    local price = tonumber(veh.price)
    local plate = GeneratePlate()
    local key = ('pfm-vehicleshop:buy:%s:%s'):format(cid, PFPayout.NewId())
    local accounts = { 'cash', 'bank' }
    local account, res = PFPayout.Charge(src, accounts, price, { key = key, kind = 'purchase', reason = 'Vehicle ' .. model, quiet = true })
    if not account then
        if holdIfUnclear(res, { flow = 'showroom', key = key, accounts = accounts, cid = cid, amount = price, plate = plate, label = veh.name or model,
            data = { model = model, plate = plate, license = pData.PlayerData.license } }) then return end
        TriggerClientEvent('QBCore:Notify', src, Lang:t(refusedText(res)), 'error')
        return
    end
    if not insertVehicle(ownerOf(pData), model, plate) then
        -- paid but the car could not be written: the money goes back
        PFSettle.Owe({ key = key .. ':refund', to = cid, account = account, amount = price, kind = 'refund', reason = 'Vehicle purchase failed ' .. model, label = 'a vehicle purchase that failed' })
        return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.purchase_failed'), 'error')
    end
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
    local cid = pData.PlayerData.citizenid
    if PFSettle.BuyerWaiting(cid) then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.payment_waiting'), 'error') end
    local plate = GeneratePlate()
    local key = ('pfm-vehicleshop:finance-down:%s:%s'):format(cid, PFPayout.NewId())
    local accounts = { 'cash', 'bank' }
    local account, res = PFPayout.Charge(src, accounts, terms.down, { key = key, kind = 'purchase', reason = 'Vehicle down payment ' .. vehicle, quiet = true })
    if not account then
        if holdIfUnclear(res, { flow = 'showroom', key = key, accounts = accounts, cid = cid, amount = terms.down, plate = plate, label = veh.name or vehicle,
            data = { model = vehicle, plate = plate, license = pData.PlayerData.license, terms = terms } }) then return end
        TriggerClientEvent('QBCore:Notify', src, Lang:t(refusedText(res)), 'error')
        return
    end
    if not insertVehicle(ownerOf(pData), vehicle, plate, terms) then
        PFSettle.Owe({ key = key .. ':refund', to = cid, account = account, amount = terms.down, kind = 'refund', reason = 'Vehicle purchase failed ' .. vehicle, label = 'a vehicle purchase that failed' })
        return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.purchase_failed'), 'error')
    end
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
        loan = (o.loan or 0) > 0 and o.loan or nil,
        seller = o.sellerName, buyer = o.buyerName, expiresIn = math.max(0, (o.expires or 0) - os.time()),
    }
end
PFShop.OfferView = offerView

--- What a held dealer sale keeps of its offer (stored as JSON until the payment clears).
local function saleOf(o)
    return {
        kind = o.kind, model = o.model, label = o.label, price = o.price, terms = o.terms, amount = o.amount, tax = o.tax or 0,
        job = o.job, shop = o.shop, shopLabel = o.shopLabel, sellerCid = o.sellerCid, sellerName = o.sellerName, commission = o.commission or 0,
    }
end

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
        payments = offer.terms and offer.terms.payments, perPayment = offer.terms and offer.terms.perPayment, loan = view.loan,
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
    local view = sendOffer(src, target, {
        kind = terms and 'finance' or 'dealer', model = model, label = veh.name or model, price = price, terms = terms,
        amount = terms and terms.down or price, tax = purchaseTax(price), job = shop.Job, shop = shopName, shopLabel = shop.ShopLabel,
        sellerCid = player.PlayerData.citizenid, sellerName = nameOf(player),
        commission = commissionFor(price, terms ~= nil),
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

local function recordSale(o, plate, buyerCid, buyerName, key)
    if not PFShop.dbReady then return end
    MySQL.insert.await([[INSERT IGNORE INTO pfm_vehicleshop_sales (shop, model, plate, price, tax, paid_now, financed, buyer_cid, buyer_name,
        seller_cid, seller_name, commission, ledger_key) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]], {
        o.shop or '', o.model, plate, o.price, o.tax or 0, o.amount + (o.tax or 0), o.terms and 1 or 0,
        buyerCid, buyerName, o.sellerCid, o.sellerName, o.commission or 0, key,
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
        PFSettle.Owe({ key = key .. ':tax-refund', to = cid, account = 'bank', amount = uncollected, kind = 'refund', reason = 'Uncollected vehicle tax', label = 'uncollected vehicle tax' })
    end
    return collected
end

--- The money of a paid dealer sale: the price is split, the salesperson's commission out of it and
--- the rest to the dealership (for a financed car the shop pays out the part the buyer still owes
--- it). Each part once, by key, and kept until it is paid. Returns the commission.
local function payDealerSale(o, key)
    local commission = math.max(0, math.min(o.price, tonumber(o.commission) or 0))
    if o.price - commission > 0 then
        PFSettle.Owe({ key = key .. ':dealership', to = 'society:' .. tostring(o.job), amount = o.price - commission, kind = 'deposit', reason = 'Vehicle sale' })
    end
    if commission > 0 then
        PFSettle.Owe({ key = key .. ':commission', to = o.sellerCid, account = 'bank', amount = commission, kind = 'wage', reason = 'Vehicle sale commission', label = 'your sale commission' })
    end
    return commission
end

--- An accepted paid transfer (/transfervehicle with a price). The buyer pays into the shop's
--- account (cash, then bank), the car changes hands only if it is still the seller's, not in a
--- fleet and not owing more than the buyer was shown, and then the seller is paid in the same kind
--- of money; if the car could not change hands the buyer is refunded. One key per offer. (The
--- buyer used to pay the seller directly, and the car was then moved from whoever had it by then.)
function PFShop.AcceptTransfer(src, offer, customer, key)
    local cid = customer.PlayerData.citizenid
    local refused = transferRefusal(offer.plate, offer.sellerCid, offer.loan or 0)
    if refused then
        local text = Lang:t(TRANSFER_TEXT[refused] or 'error.notown')
        TriggerClientEvent('QBCore:Notify', src, text, 'error')
        TriggerClientEvent('QBCore:Notify', offer.sellerSrc, text, 'error')
        return { ok = false, error = refused }
    end
    local accounts = { 'cash', 'bank' }
    local license = QBCore.Functions.GetIdentifier(src, 'license')
    local account, res = PFPayout.Charge(src, accounts, offer.amount, { key = key .. ':charge', kind = 'purchase', reason = 'Vehicle ' .. offer.plate, quiet = true })
    if not account then
        -- not known yet: the car stays the seller's until the payment clears, then it moves (or the
        -- buyer is refunded if it can no longer move); nothing is charged again
        local hold = holdIfUnclear(res, { flow = 'transfer', key = key .. ':charge', accounts = accounts, cid = cid, amount = offer.amount,
            plate = offer.plate, label = offer.label, message = 'general.transfer_held',
            data = { base = key, plate = offer.plate, sellerCid = offer.sellerCid, loan = offer.loan or 0, license = license, label = offer.label, amount = offer.amount } })
        if hold then
            TriggerClientEvent('QBCore:Notify', offer.sellerSrc, Lang:t('general.transfer_held_seller', { ref = hold.ref }), 'primary')
            return { ok = false, error = 'payment_held', ref = hold.ref }
        end
        TriggerClientEvent('QBCore:Notify', offer.sellerSrc, Lang:t(refusedText(res) == 'error.notenoughmoney' and 'error.buyertoopoor' or refusedText(res)), 'error')
        TriggerClientEvent('QBCore:Notify', src, Lang:t(refusedText(res)), 'error')
        return { ok = false, error = 'insufficient_funds' }
    end
    if not claimTransfer(offer.plate, offer.sellerCid, cid, license, offer.loan or 0) then
        PFSettle.Owe({ key = key .. ':refund', to = cid, account = account, amount = offer.amount, kind = 'refund',
            reason = 'Vehicle sale did not go through ' .. offer.plate, label = 'a vehicle sale that did not go through' })
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.transfer_changed'), 'error')
        TriggerClientEvent('QBCore:Notify', offer.sellerSrc, Lang:t('error.transfer_changed'), 'error')
        return { ok = false, error = 'vehicle_changed' }
    end
    -- kept and retried until paid (the money stays in the shop's account until then)
    PFSettle.Owe({ key = key .. ':seller', to = offer.sellerCid, account = account, amount = offer.amount, kind = 'sale',
        reason = 'Vehicle sold ' .. offer.plate, label = 'the sale of ' .. tostring(offer.label or offer.plate) })
    TriggerClientEvent('QBCore:Notify', offer.sellerSrc, Lang:t('success.soldfor') .. comma_value(offer.amount), 'success')
    TriggerClientEvent('vehiclekeys:client:SetOwner', src, offer.plate)
    TriggerClientEvent('QBCore:Notify', src, Lang:t('success.boughtfor') .. comma_value(offer.amount), 'success')
    return { ok = true, plate = offer.plate }
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
    -- the car is changing hands in another call (a gift, another buyer, a sale waiting on the
    -- bank): this offer stays open
    if offer.kind == 'transfer' and (plateBusy[offer.plate] or PFSettle.PlateHeld(offer.plate)) then return { ok = false, error = 'in_progress' } end
    -- a purchase of the customer's still waits on the bank: accepting would charge them a second time
    local answering = exports['pfm-core']:GetPlayer(src)
    if accepted == true and answering and PFSettle.BuyerWaiting(answering.PlayerData.citizenid) then return { ok = false, error = 'payment_waiting' } end
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
        -- the car is locked before the first wait: the ownership check and the change it allows
        -- are separated by the database and the ledger
        plateBusy[offer.plate] = true
        local ok, res = pcall(PFShop.AcceptTransfer, src, offer, customer, key)
        plateBusy[offer.plate] = nil
        if not ok then
            print(('^1[pfm-vehicleshop]^7 transfer of %s failed: %s'):format(tostring(offer.plate), tostring(res)))
            return { ok = false, error = 'server_error' }
        end
        return res
    end

    -- dealer sale or dealer finance: still at the dealership, still working there, still in stock
    if not shopFor(offer.sellerSrc, 'managed', offer.model, seller.PlayerData.job.name) then return { ok = false, error = 'seller_unavailable' } end
    if not PFShop.TakeStock(offer.shop, offer.model) then
        TriggerClientEvent('QBCore:Notify', src, 'This model is out of stock', 'error')
        TriggerClientEvent('QBCore:Notify', offer.sellerSrc, 'This model is out of stock', 'error')
        return { ok = false, error = 'out_of_stock' }
    end
    local total = offer.amount + (offer.tax or 0)
    local accounts = { 'cash', 'bank' }
    local account, res = PFPayout.Charge(src, accounts, total, { key = key .. ':charge', kind = 'purchase', reason = 'Vehicle ' .. offer.model, quiet = true })
    if not account then
        -- not known yet: the car stays reserved (stock taken) until the payment clears; the sale
        -- then finishes on its own, the car parked in the delivery garage
        local hold = holdIfUnclear(res, { flow = 'dealer', key = key .. ':charge', accounts = accounts, cid = cid, amount = total, label = offer.label,
            data = { base = key, offer = saleOf(offer), model = offer.model, plate = GeneratePlate(), license = customer.PlayerData.license, buyerName = nameOf(customer) } })
        if hold then
            TriggerClientEvent('QBCore:Notify', offer.sellerSrc, Lang:t('general.sale_held_seller', { ref = hold.ref }), 'primary')
            pushApp(src, 'cardealer', 'changed')
            return { ok = false, error = 'payment_held', ref = hold.ref }
        end
        PFShop.ReturnStock(offer.shop, offer.model)
        TriggerClientEvent('QBCore:Notify', src, Lang:t(refusedText(res)), 'error')
        TriggerClientEvent('QBCore:Notify', offer.sellerSrc, Lang:t(refusedText(res)), 'error')
        return { ok = false, error = 'insufficient_funds' }
    end
    -- the car first: if it cannot be written, nothing else was paid and the buyer gets it all back
    local plate = GeneratePlate()
    if not insertVehicle(ownerOf(customer), offer.model, plate, offer.terms) then
        PFShop.ReturnStock(offer.shop, offer.model)
        PFSettle.Owe({ key = key .. ':refund', to = cid, account = account, amount = total, kind = 'refund', reason = 'Vehicle purchase failed ' .. offer.model, label = 'a vehicle purchase that failed' })
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.purchase_failed'), 'error')
        TriggerClientEvent('QBCore:Notify', offer.sellerSrc, Lang:t('error.purchase_failed'), 'error')
        return { ok = false, error = 'server_error' }
    end
    settleTax(offer, cid, key)
    local commission = payDealerSale(offer, key)
    recordSale(offer, plate, cid, nameOf(customer), key)
    if commission > 0 then
        TriggerClientEvent('QBCore:Notify', offer.sellerSrc, Lang:t('success.earned_commission', { amount = comma_value(commission) }), 'success')
    end
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
    elseif res.error == 'payment_waiting' then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.payment_waiting'), 'error')
    end
end)

AddEventHandler('playerDropped', function()
    pendingOffers[source] = nil
    pendingDelivery[source] = nil
    lastTestDrive[source] = nil
end)

--- Repossesses a car whose payment is overdue: only the owner's car, still owing and still overdue
--- in the same statement (a payment made during the warning keeps it), and not while one of its
--- payments is being processed or waits on the bank. A job fleet built on the car loses it too
--- (pf-jobgarages deactivates the fleet entry and takes the car off the road), so the job cannot
--- keep spawning a repossessed car. Returns true when it was taken.
function PFShop.Repossess(citizenid, plate)
    if financeBusy[plate] or PFSettle.PlateHeld(plate) then return false end
    local res = MySQL.query.await('DELETE FROM player_vehicles WHERE plate = ? AND citizenid = ? AND balance > 0 AND financetime < 1', { plate, citizenid })
    if not res or (tonumber(res.affectedRows) or 0) < 1 then return false end
    TriggerEvent('pfm-vehicleshop:server:vehicleRepossessed', plate, citizenid)
    -- pf-jobgarages not running: its fleet entry is closed here so it cannot come back later
    if GetResourceState('pf-jobgarages') ~= 'started' and fleetTableExists() then
        pcall(MySQL.update.await, 'UPDATE job_garage_vehicles SET active = 0, `out` = 0 WHERE plate = ? AND active = 1', { plate })
    end
    return true
end

-- Check if payment is due
RegisterNetEvent('qb-vehicleshop:server:checkFinance', function()
    local src = source
    local player = exports['pfm-core']:GetPlayer(src)
    if not player then return end
    local citizenid = player.PlayerData.citizenid
    local query = 'SELECT * FROM player_vehicles WHERE citizenid = ? AND balance > 0 AND financetime < 1'
    local result = MySQL.query.await(query, { citizenid })
    if result[1] then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('general.paymentduein', { time = Config.PaymentWarning }))
        Wait(Config.PaymentWarning * 60000)
        local vehicles = MySQL.query.await(query, { citizenid })
        for _, v in pairs(vehicles) do
            if PFShop.Repossess(citizenid, v.plate) then
                TriggerClientEvent('QBCore:Notify', src, Lang:t('error.repossessed', { plate = v.plate }), 'error')
            end
        end
    end
end)

-- Transfer vehicle to player in passenger seat
QBCore.Commands.Add('transfervehicle', Lang:t('general.command_transfervehicle'), { { name = 'ID', help = Lang:t('general.command_transfervehicle_help') }, { name = 'amount', help = Lang:t('general.command_transfervehicle_amount') } }, false, function(source, args)
    local src = source
    local buyerId = tonumber(args[1])
    local sellAmount = tonumber(args[2])
    if not buyerId or buyerId == 0 or buyerId == src then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.Invalid_ID'), 'error') end
    -- an amount that is not a number is refused, not taken as a gift
    if args[2] ~= nil and args[2] ~= '' and not sellAmount then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.buyertoopoor'), 'error') end
    local ped = GetPlayerPed(src)
    local targetPed = GetPlayerPed(buyerId)
    if targetPed == 0 then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.buyerinfo'), 'error') end
    local vehicle = GetVehiclePedIsIn(ped, false)
    if vehicle == 0 then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.notinveh'), 'error') end
    local plate = Trim(GetVehicleNumberPlateText(vehicle))
    if not plate then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.vehinfo'), 'error') end
    local player = exports['pfm-core']:GetPlayer(src)
    local target = exports['pfm-core']:GetPlayer(buyerId)
    if not player then return end
    -- a sale of this car waits on the bank (it moves when that payment clears)
    if plateBusy[plate] or PFSettle.PlateHeld(plate) then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.transfer_busy'), 'error') end
    if #(GetEntityCoords(ped) - GetEntityCoords(targetPed)) > 5.0 then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.playertoofar'), 'error') end
    if not target then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.buyerinfo'), 'error') end
    local targetcid = target.PlayerData.citizenid
    if targetcid == player.PlayerData.citizenid then return end
    -- the car is locked before the first wait (the checks below and the change are separated by
    -- database waits)
    plateBusy[plate] = true
    local ok, err = pcall(function()
        local row = MySQL.single.await('SELECT citizenid, vehicle, balance FROM player_vehicles WHERE plate = ?', { plate })
        if not row or row.citizenid ~= player.PlayerData.citizenid then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.notown'), 'error') end
        local loan = tonumber(row.balance) or 0
        if Config.PreventFinanceSelling and loan > 0 then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.financed'), 'error') end
        -- a job fleet car stays the owner's (it comes back to them when it leaves the fleet)
        if isFleetPlate(plate) then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.fleet_vehicle'), 'error') end
        if not sellAmount then
            -- a gift: the car moves now, in the state just checked (a loan comes with it)
            local targetlicense = QBCore.Functions.GetIdentifier(target.PlayerData.source, 'license')
            if not claimTransfer(plate, player.PlayerData.citizenid, targetcid, targetlicense, loan) then
                return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.transfer_changed'), 'error')
            end
            TriggerClientEvent('QBCore:Notify', src, Lang:t('success.gifted'), 'success')
            TriggerClientEvent('vehiclekeys:client:SetOwner', buyerId, plate)
            TriggerClientEvent('QBCore:Notify', buyerId, Lang:t('success.received_gift'), 'success')
            if loan > 0 then TriggerClientEvent('QBCore:Notify', buyerId, Lang:t('general.loan_came_with', { amount = comma_value(loan) }), 'primary') end
            return
        end
        -- a sale: the buyer accepts the price (and any loan that comes with the car) on their
        -- screen, then pays through the ledger (the buyer used to be charged whatever the seller
        -- typed, without being asked)
        sellAmount = math.floor(sellAmount)
        if sellAmount <= 0 or sellAmount > 100000000 then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.buyertoopoor'), 'error') end
        -- a customer answering someone else's offer is not handed another one (it would replace it)
        local waiting = pendingOffers[target.PlayerData.source]
        if waiting and os.time() <= waiting.expires and waiting.sellerSrc ~= src then
            return TriggerClientEvent('QBCore:Notify', src, 'That player is answering another offer', 'error')
        end
        local veh = sharedVehicles[row.vehicle]
        sendOffer(src, target, {
            kind = 'transfer', plate = plate, label = (veh and veh.name or tostring(row.vehicle)) .. ' (' .. plate .. ')', amount = sellAmount,
            loan = loan > 0 and loan or nil,
            sellerCid = player.PlayerData.citizenid,
            sellerName = ('%s %s'):format(player.PlayerData.charinfo.firstname, player.PlayerData.charinfo.lastname),
        })
    end)
    plateBusy[plate] = nil
    if not ok then print(('^1[pfm-vehicleshop]^7 /transfervehicle %s failed: %s'):format(tostring(plate), tostring(err))) end
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

-- ── sales that waited on the bank (settlements.lua) ─────────────────────────────────────────────
-- Each handler runs once the held charge settled: `charged` (the money is in the shop's account)
-- finishes the sale, `none` (nothing was taken) releases what it reserved, `review` (interrupted
-- during the debit) releases it too and sends the buyer to staff. They are rerun-safe: a crash in
-- the middle runs the same handler again (keyed payments, a car found by its plate).

local function heldTell(cid, key, subs, kind) PFSettle.Tell(cid, Lang:t(key, subs), kind or 'primary', Lang:t('general.held_subject')) end

--- Writes the car of a held sale once (a re-run finds it by its plate; a plate taken meanwhile is
--- replaced and stored first). The car waits in the delivery garage. Returns the plate.
local function writeHeldCar(hold, d, terms)
    local owner = MySQL.scalar.await('SELECT citizenid FROM player_vehicles WHERE plate = ?', { d.plate })
    if owner == hold.citizenid then return d.plate end
    if owner ~= nil then
        d.plate = GeneratePlate()
        PFSettle.SaveData(hold)
    end
    if not insertVehicle({ license = d.license, citizenid = hold.citizenid }, d.model, d.plate, terms, true) then error('the vehicle could not be written') end
    return d.plate
end

--- The registration bill and the purchase event, once per held sale.
local function announceHeldCar(hold, d, model, plate)
    if d.announced then return end
    d.announced = true
    PFSettle.SaveData(hold)
    TriggerEvent('qb-vehicleshop:server:onVehiclePurchased', hold.citizenid, model, plate)
    registerVehicle(hold.citizenid, model, plate, PFSettle.SourceOf(hold.citizenid))
end

local function labelOf(model) local v = sharedVehicles[model] return v and v.name or tostring(model) end

local function releasedText(outcome) return outcome == 'review' and 'general.held_review' or 'general.held_cancelled' end

PFSettle.handlers.showroom = {
    charged = function(hold)
        local d = hold.data
        local plate = writeHeldCar(hold, d, d.terms)
        announceHeldCar(hold, d, d.model, plate)
        heldTell(hold.citizenid, 'general.held_delivered', { vehicle = labelOf(d.model), plate = plate, garage = deliveryGarage() }, 'success')
    end,
    none = function(hold) heldTell(hold.citizenid, 'general.held_cancelled', { vehicle = labelOf(hold.data.model), ref = hold.ref or hold.id }) end,
    review = function(hold) heldTell(hold.citizenid, 'general.held_review', { vehicle = labelOf(hold.data.model), ref = '#' .. tostring(hold.id) }, 'error') end,
}

local function releaseDealer(hold, outcome)
    local d = hold.data
    local o = d.offer or {}
    if not d.stockReturned then
        d.stockReturned = true
        PFSettle.SaveData(hold)
        PFShop.ReturnStock(o.shop, o.model)
    end
    heldTell(hold.citizenid, releasedText(outcome), { vehicle = o.label or labelOf(o.model), ref = '#' .. tostring(hold.id) }, outcome == 'review' and 'error' or 'primary')
    PFSettle.Tell(o.sellerCid, Lang:t('general.held_sale_cancelled', { vehicle = o.label or labelOf(o.model) }), 'error')
end

PFSettle.handlers.dealer = {
    charged = function(hold)
        local d = hold.data
        local o = d.offer
        local plate = writeHeldCar(hold, d, o.terms)
        settleTax(o, hold.citizenid, d.base)
        local commission = payDealerSale(o, d.base)
        recordSale(o, plate, hold.citizenid, d.buyerName, d.base)
        announceHeldCar(hold, d, o.model, plate)
        heldTell(hold.citizenid, 'general.held_delivered', { vehicle = o.label, plate = plate, garage = deliveryGarage() }, 'success')
        PFSettle.Tell(o.sellerCid, Lang:t('general.held_sale_done', { vehicle = o.label }), 'success')
        if commission > 0 then PFSettle.Tell(o.sellerCid, Lang:t('success.earned_commission', { amount = comma_value(commission) }), 'success') end
    end,
    none = function(hold) releaseDealer(hold, 'none') end,
    review = function(hold) releaseDealer(hold, 'review') end,
}

PFSettle.handlers.transfer = {
    charged = function(hold, account)
        local d = hold.data
        -- moved by an earlier run of this handler, or now (only in the state the buyer accepted)
        local moved = MySQL.scalar.await('SELECT citizenid FROM player_vehicles WHERE plate = ?', { d.plate }) == hold.citizenid
        if not moved then
            if not notInFleet(d.plate) then error('the fleet check is not available') end
            moved = claimTransfer(d.plate, d.sellerCid, hold.citizenid, d.license, d.loan or 0)
        end
        if moved then
            PFSettle.Owe({ key = d.base .. ':seller', to = d.sellerCid, account = account, amount = d.amount, kind = 'sale',
                reason = 'Vehicle sold ' .. d.plate, label = 'the sale of ' .. tostring(d.label or d.plate) })
            heldTell(hold.citizenid, 'general.held_transfer_done', { vehicle = d.label or d.plate }, 'success')
            PFSettle.Tell(d.sellerCid, Lang:t('general.held_transfer_paid', { vehicle = d.label or d.plate, amount = comma_value(d.amount) }), 'success')
            local src = PFSettle.SourceOf(hold.citizenid)
            if src then TriggerClientEvent('vehiclekeys:client:SetOwner', src, d.plate) end
        else
            PFSettle.Owe({ key = d.base .. ':refund', to = hold.citizenid, account = account, amount = d.amount, kind = 'refund',
                reason = 'Vehicle sale did not go through ' .. d.plate, label = 'a vehicle sale that did not go through' })
            heldTell(hold.citizenid, 'general.held_refunded', { vehicle = d.label or d.plate, amount = comma_value(d.amount) })
            PFSettle.Tell(d.sellerCid, Lang:t('error.transfer_changed'), 'error')
        end
    end,
    none = function(hold)
        heldTell(hold.citizenid, 'general.held_cancelled', { vehicle = hold.data.label or hold.data.plate })
        PFSettle.Tell(hold.data.sellerCid, Lang:t('general.held_sale_cancelled', { vehicle = hold.data.label or hold.data.plate }), 'error')
    end,
    review = function(hold)
        heldTell(hold.citizenid, 'general.held_review', { vehicle = hold.data.label or hold.data.plate, ref = '#' .. tostring(hold.id) }, 'error')
        PFSettle.Tell(hold.data.sellerCid, Lang:t('general.held_sale_cancelled', { vehicle = hold.data.label or hold.data.plate }), 'error')
    end,
}

PFSettle.handlers.payment = {
    charged = function(hold, account)
        local c = hold.data
        local res = PFShop.ApplyFinancePayment(hold.citizenid, account, hold.charge_key, c)
        if res.ok then
            heldTell(hold.citizenid, 'general.held_payment_applied', { amount = comma_value(c.amount), plate = c.plate }, 'success')
        else
            heldTell(hold.citizenid, 'general.held_payment_returned', { amount = comma_value(c.amount), plate = c.plate })
        end
    end,
    none = function(hold) heldTell(hold.citizenid, 'general.held_payment_none', { plate = hold.data.plate }) end,
    review = function(hold) heldTell(hold.citizenid, 'general.held_review', { vehicle = hold.data.plate, ref = '#' .. tostring(hold.id) }, 'error') end,
}

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
