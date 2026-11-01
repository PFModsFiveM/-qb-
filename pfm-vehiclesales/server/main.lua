local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions' })
local sharedVehicles = exports['pfm-core']:GetShared('Vehicles')

PFUsedCars = PFUsedCars or {}
PFUsedCars.dbReady = false   -- true once occasion_vehicles has the vehicle_state column (migrations ran)

-- occasion_vehicles came from qb-vehiclesales.sql; the migration also creates it, so a server that
-- never imported the file works, and adds the column that keeps the listed car's own record.
PFUsedCars.Migrations = {
    { version = 1, name = 'listings keep the car record (loan, condition, odometer)', up = {
        [[CREATE TABLE IF NOT EXISTS `occasion_vehicles` (
            `id` int(11) NOT NULL AUTO_INCREMENT,
            `seller` varchar(50) DEFAULT NULL,
            `price` int(11) DEFAULT NULL,
            `description` longtext DEFAULT NULL,
            `plate` varchar(50) DEFAULT NULL,
            `model` varchar(50) DEFAULT NULL,
            `mods` text DEFAULT NULL,
            `occasionid` varchar(50) DEFAULT NULL,
            PRIMARY KEY (`id`),
            KEY `occasionId` (`occasionid`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
        'ALTER TABLE `occasion_vehicles` ADD COLUMN IF NOT EXISTS `vehicle_state` TEXT NULL DEFAULT NULL',
    } },
}

function PFUsedCars.Start()
    local ok, done, err = pcall(function() return exports['pfm-core']:RunMigrations(GetCurrentResourceName(), PFUsedCars.Migrations) end)
    PFUsedCars.dbReady = ok and done == true
    if not PFUsedCars.dbReady then
        print('^1[pfm-vehiclesales]^7 migrations failed, listings do not keep the car record: ' .. tostring(ok and err or done))
    end
end

AddEventHandler('onResourceStart', function(resource)
    if resource == GetCurrentResourceName() then PFUsedCars.Start() end
end)

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

-- Job fleet cars (pf-jobgarages job_garage_vehicles, active) belong to their job garage: pfm-garages
-- never gives them out of a personal garage, so a buyer would pay for a car they can never take out.
-- They are not listed or sold back. The table may not exist (pf-jobgarages not installed).
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

--- The condition a DELETE that hands a car over adds, so a car put in a fleet after the check is not
--- taken in the same moment (the check and the delete are one statement). Returns sql, params.
local function notInFleet(plate)
    local ok, exists = pcall(fleetTableExists)
    if ok and exists then
        return ' AND NOT EXISTS (SELECT 1 FROM job_garage_vehicles WHERE plate = ? AND active = 1)', { plate }
    end
    return '', {}
end

local function trimPlate(plate)
    if type(plate) ~= 'string' then return nil end
    plate = plate:gsub('^%s+', ''):gsub('%s+$', '')
    if plate == '' or #plate > 16 then return nil end
    return plate
end

--- The car the player sits in, read on the server: its plate (trimmed, upper case) and entity.
--- Listing and selling back act on that car only: the client removes the car it sits in, so any
--- other plate would leave that car in the world while it was listed (and come back a second time),
--- or take a car out of the impound without its fee.
local function seatedVehicle(src)
    local veh = GetVehiclePedIsIn(GetPlayerPed(src), false)
    if not veh or veh == 0 then return nil end
    local plate = trimPlate(GetVehicleNumberPlateText(veh))
    if not plate then return nil end
    return plate:upper(), veh
end

--- Why the player's car row cannot go to the lot (financed, impounded, a fleet car), or nil.
local function cannotSell(row, plate)
    if not row then return Lang:t('error.not_your_vehicle') end
    -- a financed car keeps its loan: the row (and with it the balance) would leave the player's hands
    if (tonumber(row.balance) or 0) > 0 then return Lang:t('error.finish_payments') end
    if (tonumber(row.depotprice) or 0) > 0 then return Lang:t('error.impounded') end
    if isFleetPlate(plate) then return Lang:t('error.fleet_vehicle') end
    return nil
end

-- What a listing keeps of the car's own record (player_vehicles) so the car comes back exactly as
-- it was: the loan columns (taking a car back never clears or resets a finance plan) and its
-- condition and odometer. A buyer gets the condition and odometer, never the seller's loan.
local KEPT = { 'balance', 'paymentamount', 'paymentsleft', 'financetime', 'fuel', 'engine', 'body', 'drivingdistance' }
local SOLD_WITH = { fuel = true, engine = true, body = true, drivingdistance = true }

local function keptState(row)
    local out = {}
    for _, col in ipairs(KEPT) do
        local v = tonumber(row[col])
        if v ~= nil then out[col] = v end
    end
    return out
end

local function decodeState(text)
    if type(text) ~= 'string' or text == '' then return {} end
    local ok, t = pcall(json.decode, text)
    return ok and type(t) == 'table' and t or {}
end

--- Puts a car into a player's garage record: the listing's model, mods and plate, plus the kept
--- columns (only those in `allowed`, when given). Returns the insert id or nil.
local function insertOwned(Player, listing, allowed)
    local cols = { 'license', 'citizenid', 'vehicle', 'hash', 'mods', 'plate', 'state' }
    local vals = { Player.PlayerData.license, Player.PlayerData.citizenid, listing.model, GetHashKey(listing.model), listing.mods, listing.plate, 0 }
    local state = decodeState(listing.vehicle_state)
    for _, col in ipairs(KEPT) do
        local v = tonumber(state[col])
        if v ~= nil and (not allowed or allowed[col]) then
            cols[#cols + 1] = col
            vals[#vals + 1] = v
        end
    end
    local ok, id = pcall(function()
        return MySQL.insert.await(('INSERT INTO player_vehicles (%s) VALUES (%s)'):format(table.concat(cols, ', '), string.rep('?, ', #cols):sub(1, -3)), vals)
    end)
    return ok and id or nil
end

--- Writes a player_vehicles row back as it was read (SELECT *), after the step that should have
--- followed its removal failed. Column names come from the table itself.
local function restoreRow(row)
    local cols, vals = {}, {}
    for k, v in pairs(row) do
        if k ~= 'id' and type(k) == 'string' and k:match('^[%w_]+$') then
            cols[#cols + 1] = '`' .. k .. '`'
            vals[#vals + 1] = v
        end
    end
    local ok, id = pcall(function()
        return MySQL.insert.await(('INSERT INTO player_vehicles (%s) VALUES (%s)'):format(table.concat(cols, ', '), string.rep('?, ', #cols):sub(1, -3)), vals)
    end)
    if not ok or not id then
        print(('^1[pfm-vehiclesales]^7 could not restore vehicle %s of %s: %s'):format(tostring(row.plate), tostring(row.citizenid), tostring(id)))
    end
    return ok and id ~= nil
end

-- The lot shows every listing on its spots (the client places listing i on spot i), so it takes no
-- more listings than the smallest lot has spots.
local function lotCapacity()
    local n
    for _, zone in pairs(Config.Zones) do
        local spots = #(zone.VehicleSpots or {})
        n = n and math.min(n, spots) or spots
    end
    return n or 0
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

-- Whether the player owns the car, its loan balance, and why it cannot go to the lot (impounded, a
-- fleet car), so the menu says so before the contract opens. The server checks all of it again.
QBCore.Functions.CreateCallback('qb-occasions:server:checkVehicleOwner', function(source, cb, plate)
    local pData = exports['pfm-core']:GetPlayer(source)
    plate = trimPlate(plate)
    if not pData or not plate then return cb(false) end
    local row = MySQL.single.await('SELECT balance, depotprice FROM player_vehicles WHERE plate = ? AND citizenid = ?', { plate, pData.PlayerData.citizenid })
    if not row then return cb(false) end
    local balance = tonumber(row.balance) or 0
    local blocked = balance <= 0 and cannotSell(row, plate) or nil
    cb(true, balance, blocked)
end)

-- The seller's name and contact details shown on a listing. (The whole players row went to any client
-- for any citizen id: license, money, inventory, metadata.)
QBCore.Functions.CreateCallback('qb-occasions:server:getSellerInformation', function(_, cb, citizenid)
    if type(citizenid) ~= 'string' then return cb(nil) end
    MySQL.query('SELECT charinfo FROM players WHERE citizenid = ?', { citizenid }, function(result)
        local ok, info = pcall(json.decode, result and result[1] and result[1].charinfo or '')
        if ok and type(info) == 'table' then
            cb({ charinfo = json.encode({ firstname = info.firstname, lastname = info.lastname, phone = info.phone, account = info.account }) })
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

--- Puts a claimed listing back on the lot when the step after the claim failed.
local function relist(listing)
    local withState = listing.vehicle_state ~= nil
    local ok, err = pcall(function()
        return MySQL.insert.await('INSERT INTO occasion_vehicles (seller, price, description, plate, model, mods, occasionid' .. (withState and ', vehicle_state' or '') .. ') VALUES (?, ?, ?, ?, ?, ?, ?' .. (withState and ', ?' or '') .. ')',
            { listing.seller, listing.price, listing.description, listing.plate, listing.model, listing.mods, listing.occasionid, listing.vehicle_state })
    end)
    if not ok or not err then print(('^1[pfm-vehiclesales]^7 could not put listing %s (%s) back: %s'):format(tostring(listing.occasionid), tostring(listing.plate), tostring(err))) end
end

RegisterNetEvent('qb-occasions:server:ReturnVehicle', function(vehicleData)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or type(vehicleData) ~= 'table' then return end
    if onCooldown(src, 'occasion', 3000) then return end
    if not isAtSaleLot(src) then return end
    local result = MySQL.query.await('SELECT * FROM occasion_vehicles WHERE plate = ? AND occasionid = ?', { vehicleData['plate'], vehicleData['oid'] })
    if result[1] then
        if result[1].seller == Player.PlayerData.citizenid then
            -- the car that was listed comes back (model and mods came from the client, so a cheap
            -- listing could be taken back as any car), and only once: the listing is claimed first
            local listing = result[1]
            local claimed = MySQL.query.await('DELETE FROM occasion_vehicles WHERE occasionid = ? AND plate = ?', { listing.occasionid, listing.plate })
            if not claimed or (claimed.affectedRows or 0) < 1 then return end
            -- with the record it was listed with: a finance plan, the condition and the odometer
            -- come back unchanged (the row used to be written fresh, with every one reset)
            if not insertOwned(Player, listing) then
                -- the listing goes back up rather than the car being lost
                relist(listing)
                TriggerClientEvent('QBCore:Notify', src, Lang:t('error.lot_unavailable'), 'error', 3500)
                return
            end
            exports['pfm-core']:GrantVehicleSpawn(src, listing.model)
            TriggerClientEvent('qb-occasions:client:ReturnOwnedVehicle', src, listing)
            TriggerClientEvent('qb-occasion:client:refreshVehicles', -1)
            if PFUsedCars and PFUsedCars.Changed then PFUsedCars.Changed() end
        else
            TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_your_vehicle'), 'error', 3500)
        end
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.vehicle_does_not_exist'), 'error', 3500)
    end
end)

-- One listing at a time: the free-spot count and the listing it allows are separated by database
-- waits (two sellers at once could fill one spot twice).
local listingBusy = false

local function listVehicle(src, Player, price, desc, mods)
    local cid = Player.PlayerData.citizenid
    local plate, veh = seatedVehicle(src)
    if not plate then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_in_veh'), 'error', 3500) end
    local row = MySQL.single.await('SELECT * FROM player_vehicles WHERE plate = ? AND citizenid = ?', { plate, cid })
    -- not a financed car (listing removed the row, so taking it back erased the loan), not an
    -- impounded one and not a job fleet car; the client checks the balance too, but that is not enough
    local refused = cannotSell(row, plate)
    if refused then return TriggerClientEvent('QBCore:Notify', src, refused, 'error', 3500) end
    local listed = tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM occasion_vehicles', {})) or 0
    if listed >= lotCapacity() then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.no_space_on_lot'), 'error', 3500) end
    -- the car leaves the owner's garage only in the state that was checked (one statement)
    local fleetSql, fleetParams = notInFleet(plate)
    local claimed = MySQL.query.await('DELETE FROM player_vehicles WHERE plate = ? AND citizenid = ? AND balance <= 0 AND depotprice <= 0' .. fleetSql,
        { plate, cid, table.unpack(fleetParams) })
    if not claimed or (claimed.affectedRows or 0) < 1 then
        return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_your_vehicle'), 'error', 3500)
    end
    local values = { cid, price, desc, row.plate, row.vehicle, mods, generateOID() }
    local ok, id = pcall(function()
        if PFUsedCars.dbReady then
            values[#values + 1] = json.encode(keptState(row))
            return MySQL.insert.await('INSERT INTO occasion_vehicles (seller, price, description, plate, model, mods, occasionid, vehicle_state) VALUES (?, ?, ?, ?, ?, ?, ?, ?)', values)
        end
        return MySQL.insert.await('INSERT INTO occasion_vehicles (seller, price, description, plate, model, mods, occasionid) VALUES (?, ?, ?, ?, ?, ?, ?)', values)
    end)
    if not ok or not id then
        -- the listing was not written: the car goes back to the owner as it was
        restoreRow(row)
        return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.lot_unavailable'), 'error', 3500)
    end
    -- the listed car leaves the world here, not only on the seller's screen
    if DoesEntityExist(veh) then DeleteEntity(veh) end
    TriggerEvent('qb-log:server:CreateLog', 'vehicleshop', 'Vehicle for Sale', 'red', '**' .. GetPlayerName(src) .. '** has a ' .. tostring(row.vehicle) .. ' priced at ' .. price)
    TriggerClientEvent('qb-occasions:client:vehicleListed', src, price)
    TriggerClientEvent('qb-occasion:client:refreshVehicles', -1)
    if PFUsedCars and PFUsedCars.Changed then PFUsedCars.Changed() end
    TriggerClientEvent('QBCore:Notify', src, Lang:t('success.vehicle_listed'), 'success', 5500)
end

-- Put the car the player sits in on the lot. The car is identified by the server (the seat), its
-- model comes from the owner's record; the price, description and look come from the contract.
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
    local mods = type(vehicleData.mods) == 'table' and json.encode(vehicleData.mods) or '{}'
    if #mods > 20000 then return end
    if listingBusy then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.lot_busy'), 'error', 3500) end
    listingBusy = true
    local ok, err = pcall(listVehicle, src, Player, vehiclePrice, desc, mods)
    listingBusy = false
    if not ok then print('^1[pfm-vehiclesales]^7 listing failed: ' .. tostring(err)) end
end)

-- Sell the car the player sits in straight to the lot for half its catalogue price.
RegisterNetEvent('qb-occasions:server:sellVehicleBack', function(vehData)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or type(vehData) ~= 'table' then return end
    if onCooldown(src, 'occasion', 3000) then return end
    if not isAtSaleLot(src) then return end
    -- the car is only given up while the bank can pay for it
    if GetResourceState('pfm-banking') ~= 'started' then
        TriggerClientEvent('QBCore:Notify', src, 'The bank is not available right now', 'error')
        return
    end
    local plate, veh = seatedVehicle(src)
    if not plate then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_in_veh'), 'error', 3500) end
    local cid = Player.PlayerData.citizenid
    local row = MySQL.single.await('SELECT * FROM player_vehicles WHERE plate = ? AND citizenid = ?', { plate, cid })
    -- a financed car is not bought back (the loan went with the row), nor an impounded or fleet car
    local refused = cannotSell(row, plate)
    if refused then return TriggerClientEvent('QBCore:Notify', src, refused, 'error', 3500) end
    -- the price is the catalogue price of the car on record (the client named a model hash)
    local shared = sharedVehicles[row.vehicle]
    local payout = math.floor((tonumber(shared and shared.price) or 0) * 0.5)
    if payout < 1 then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_for_sale'), 'error', 3500) end
    local fleetSql, fleetParams = notInFleet(plate)
    local ownsVehicle = MySQL.query.await('DELETE FROM player_vehicles WHERE plate = ? AND citizenid = ? AND balance <= 0 AND depotprice <= 0' .. fleetSql,
        { plate, cid, table.unpack(fleetParams) })
    if not ownsVehicle or (ownsVehicle.affectedRows or 0) < 1 then
        return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_your_vehicle'), 'error', 3500)
    end
    local paid, res = PFPayout.Pay(src, 'bank', payout, {
        key = ('pfm-vehiclesales:sellback:%s:%s:%s'):format(tostring(plate), cid, PFPayout.NewId()),
        kind = 'sale', reason = 'Vehicle sold back',
    })
    if not paid then
        -- not paid: the car stays the player's, unless the bank may still complete the payment
        -- (the ledger's recovery settles that one; giving the car back too would pay twice)
        res = res or {}
        if not (res.state == 'pending' or res.state == 'debited' or res.error == 'in_progress' or res.error == 'internal_error') then
            restoreRow(row)
        end
        return
    end
    if DoesEntityExist(veh) then DeleteEntity(veh) end
    TriggerClientEvent('qb-occasions:client:soldBack', src, payout)
    TriggerClientEvent('QBCore:Notify', src, Lang:t('success.sold_car_for_price', { value = payout }), 'success', 5500)
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
        -- the buyer pays the price their contract showed: a seller can reprice a listing from the
        -- Used Cars app, so a price changed while the contract was open is refused, not charged
        local accepted = tonumber(vehicleData.price)
        if not accepted or math.abs(accepted - subtotal) > 0.005 then
            TriggerClientEvent('QBCore:Notify', src, 'The price of this car changed. Open the contract again to see the new price.', 'error', 5000)
            TriggerClientEvent('qb-occasion:client:refreshVehicles', -1)
            return
        end
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
            -- the claim also needs the price unchanged (a reprice between the read above and here)
            local claimed = MySQL.query.await('DELETE FROM occasion_vehicles WHERE plate = ? AND occasionid = ? AND price = ?', { listing.plate, listing.occasionid, listing.price })
            if not claimed or (claimed.affectedRows or 0) < 1 then
                PFPayout.Pay(buyerCid, 'bank', total, { key = key .. ':refund', kind = 'refund', reason = 'Vehicle already sold' })
                TriggerClientEvent('QBCore:Notify', src, Lang:t('error.vehicle_does_not_exist'), 'error', 3500)
                return
            end
            -- the car as listed: its condition and odometer, never the seller's loan
            if not insertOwned(Player, listing, SOLD_WITH) then
                -- the car could not be written: the buyer gets the money back and the car stays listed
                relist(listing)
                PFPayout.Pay(buyerCid, 'bank', total, { key = key .. ':refund', kind = 'refund', reason = 'Vehicle purchase failed' })
                TriggerClientEvent('QBCore:Notify', src, Lang:t('error.lot_unavailable'), 'error', 3500)
                return
            end
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
            if PFUsedCars and PFUsedCars.Changed then PFUsedCars.Changed() end
            TriggerClientEvent('QBCore:Notify', src, ('Vehicle purchase complete. Subtotal: $%.2f | Tax: $%.2f | Total: $%.2f'):format(subtotal, taxAmount, total), 'success')
            -- the seller is told by mail (pf-citizen, the same mailbox on the phone, tablet and
            -- computer; the old phone resource if that is what runs). The sale is done either way.
            local shared = sharedVehicles[listing.model]
            local mail = {
                sender = Lang:t('mail.sender'),
                subject = Lang:t('mail.subject'),
                message = Lang:t('mail.message', { value = NewPrice, value2 = shared and shared.name or listing.model }),
            }
            local mailed = GetResourceState('pf-citizen') == 'started' and pcall(function() return exports['pf-citizen']:SendMail(SellerCitizenId, mail) end)
            if not mailed and GetResourceState('pfm-phone') == 'started' then
                pcall(function() exports['pfm-phone']:sendNewMailToOffline(SellerCitizenId, mail) end)
            end
        else
            TriggerClientEvent('QBCore:Notify', src, ('Not enough money. Subtotal: $%.2f | Tax: $%.2f | Total: $%.2f'):format(subtotal, taxAmount, total), 'error', 3500)
        end
    end
end)
