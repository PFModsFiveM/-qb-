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
    -- money a sale still owes (retried until paid) and purchases whose charge the bank has not
    -- confirmed yet (@pfm-vehicleshop/settlements.lua)
    { version = 2, name = 'owed payments and held purchases', up = PFSettle.MigrationSteps('pfm_vehiclesales') },
}
PFSettle.Init('pfm_vehiclesales')

function PFUsedCars.Start()
    local ok, done, err = pcall(function() return exports['pfm-core']:RunMigrations(GetCurrentResourceName(), PFUsedCars.Migrations) end)
    PFUsedCars.dbReady = ok and done == true
    if not PFUsedCars.dbReady then
        print('^1[pfm-vehiclesales]^7 migrations failed, listings do not keep the car record: ' .. tostring(ok and err or done))
    end
    PFSettle.MailSender = Lang:t('mail.sender')
    -- owed payments and held purchases from before a restart are picked up again by the sweep
    PFSettle.Start()
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

--- The condition a DELETE that hands a car over adds, so a car put in a fleet after the check is not
--- taken in the same moment (the check and the delete are one statement). Returns sql, params; nil
--- when it cannot be told (the caller refuses).
local function notInFleet(plate)
    local exists = fleetTableExists()
    if exists == nil then return nil end
    if exists then
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
--- columns (only those in `allowed`, when given). owner = { license, citizenid }. A car handed over
--- at the lot is out (state 0, it spawns there); a parked one waits in the delivery garage.
--- Returns the insert id or nil.
local function insertOwned(owner, listing, allowed, parked)
    local cols = { 'license', 'citizenid', 'vehicle', 'hash', 'mods', 'plate', 'state' }
    local vals = { owner.license, owner.citizenid, listing.model, GetHashKey(listing.model), listing.mods, listing.plate, parked and 1 or 0 }
    if parked then
        cols[#cols + 1] = 'garage'
        vals[#vals + 1] = type(Config.DeliveryGarage) == 'string' and Config.DeliveryGarage or 'pillboxgarage'
    end
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

local function ownerOf(Player) return { license = Player.PlayerData.license, citizenid = Player.PlayerData.citizenid } end

local function generateOID()
    local num = math.random(1, 10) .. math.random(111, 999)

    return 'OC' .. num
end

-- Callbacks

-- What the lot shows (spots, contract, take-back): only those columns. The listing's vehicle_state
-- (the seller's loan and the car's condition) stays on the server.
QBCore.Functions.CreateCallback('qb-occasions:server:getVehicles', function(_, cb)
    local result = MySQL.query.await('SELECT seller, price, description, plate, model, mods, occasionid FROM occasion_vehicles ORDER BY id', {}) or {}
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
            if not insertOwned(ownerOf(Player), listing) then
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
    if not fleetSql then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.lot_unavailable'), 'error', 3500) end
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

-- Errors the ledger returns before it writes anything (nothing moved), as in payouts.lua.
local REFUSED_BEFORE_WRITE = {
    insufficient_funds = true, invalid_request = true, invalid_account = true, same_account = true,
    invalid_amount = true, invalid_key = true, bank_unavailable = true, ledger_unavailable = true, ledger_write_failed = true,
}

--- Whether a payment from the lot clearly paid nothing: failed or compensated, or refused before
--- anything was written (also: the bank not running, the ledger row not written).
local function clearlyUnpaid(res)
    if res.state == 'failed' or res.state == 'compensated' then return true end
    return res.state == nil and res.txId == nil and REFUSED_BEFORE_WRITE[res.error] == true
end

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
    if not fleetSql then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.lot_unavailable'), 'error', 3500) end
    local ownsVehicle = MySQL.query.await('DELETE FROM player_vehicles WHERE plate = ? AND citizenid = ? AND balance <= 0 AND depotprice <= 0' .. fleetSql,
        { plate, cid, table.unpack(fleetParams) })
    if not ownsVehicle or (ownsVehicle.affectedRows or 0) < 1 then
        return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_your_vehicle'), 'error', 3500)
    end
    local key = ('pfm-vehiclesales:sellback:%s:%s:%s'):format(tostring(plate), cid, PFPayout.NewId())
    local paid, res = PFPayout.Pay(src, 'bank', payout, { key = key, kind = 'sale', reason = 'Vehicle sold back', quiet = true })
    if not paid then
        res = res or {}
        if clearlyUnpaid(res) then
            -- nothing was paid: the car stays the player's
            restoreRow(row)
            return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.sellback_unpaid'), 'error', 5000)
        end
        -- the bank may still complete it: the car is the lot's and the payment is kept and retried
        -- until it is paid (the same key first, so it is never paid twice)
        PFSettle.Owe({ key = key, to = cid, account = 'bank', amount = payout, kind = 'sale', reason = 'Vehicle sold back', label = 'the car you sold back' })
    end
    if DoesEntityExist(veh) then DeleteEntity(veh) end
    TriggerClientEvent('qb-occasions:client:soldBack', src, payout)
    TriggerClientEvent('QBCore:Notify', src, Lang:t(paid and 'success.sold_car_for_price' or 'info.sold_back_pending', { value = payout }), paid and 'success' or 'primary', 5500)
end)

--- The money of a claimed listing once the buyer's money is in and the car is written: the seller's
--- share and the tax. The payments are keyed and kept until paid, so a re-run pays nothing twice.
local function payForSale(listing, buyer, sale)
    PFSettle.Owe({ key = sale.key .. ':seller', to = listing.seller, account = 'bank', amount = sale.sellerAmount, kind = 'sale',
        reason = 'Vehicle sold on the used lot', label = 'your car sold on the used lot' })
    -- the tax was paid with the car; whatever the government does not take goes back to the buyer
    local collected = 0
    if sale.tax > 0 and GetResourceState('pf-government') == 'started' then
        local ok, value = pcall(function()
            return exports['pf-government']:CollectTaxAmount(sale.tax, 'vehicle_purchase', 'citizen', buyer.citizenid, 'vehicle_used_lot', sale.key .. ':tax', sale.subtotal)
        end)
        collected = ok and (tonumber(value) or 0) or 0
    end
    local uncollected = math.floor((sale.tax - collected) * 100 + 0.5) / 100
    if uncollected > 0 then
        PFSettle.Owe({ key = sale.key .. ':tax-refund', to = buyer.citizenid, account = 'bank', amount = uncollected, kind = 'refund', reason = 'Uncollected vehicle tax', label = 'uncollected vehicle tax' })
    end
    TriggerEvent('qb-log:server:CreateLog', 'vehicleshop', 'bought', 'green', '**' .. tostring(buyer.citizenid) .. '** has bought for ' .. tostring(listing.price) .. ' (' .. tostring(listing.plate) .. ') from **' .. tostring(listing.seller) .. '**')
    -- the seller is told by mail (pf-citizen, the same mailbox on the phone, tablet and
    -- computer; the old phone resource if that is what runs). The sale is done either way.
    local shared = sharedVehicles[listing.model]
    local mail = {
        sender = Lang:t('mail.sender'),
        subject = Lang:t('mail.subject'),
        message = Lang:t('mail.message', { value = sale.sellerAmount, value2 = shared and shared.name or listing.model }),
    }
    local mailed = GetResourceState('pf-citizen') == 'started' and pcall(function() return exports['pf-citizen']:SendMail(listing.seller, mail) end)
    if not mailed and GetResourceState('pfm-phone') == 'started' then
        pcall(function() exports['pfm-phone']:sendNewMailToOffline(listing.seller, mail) end)
    end
    TriggerClientEvent('qb-occasion:client:refreshVehicles', -1)
    if PFUsedCars and PFUsedCars.Changed then PFUsedCars.Changed() end
end

local function notEnough(src, subtotal, taxAmount, total)
    TriggerClientEvent('QBCore:Notify', src, ('Not enough money. Subtotal: $%.2f | Tax: $%.2f | Total: $%.2f'):format(subtotal, taxAmount, total), 'error', 3500)
end

RegisterNetEvent('qb-occasions:server:buyVehicle', function(vehicleData)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or type(vehicleData) ~= 'table' then return end
    if onCooldown(src, 'occasionBuy', 3000) then return end
    if not isAtSaleLot(src) then return end
    local result = MySQL.query.await('SELECT * FROM occasion_vehicles WHERE plate = ? AND occasionid = ?', { vehicleData['plate'], vehicleData['oid'] })
    local listing = result and result[1]
    if not listing or not next(listing) then return end
    local subtotal = tonumber(listing.price) or 0
    -- the buyer pays the price their contract showed: a seller can reprice a listing from the
    -- Used Cars app, so a price changed while the contract was open is refused, not charged
    local accepted = tonumber(vehicleData.price)
    if not accepted or math.abs(accepted - subtotal) > 0.005 then
        TriggerClientEvent('QBCore:Notify', src, 'The price of this car changed. Open the contract again to see the new price.', 'error', 5000)
        TriggerClientEvent('qb-occasion:client:refreshVehicles', -1)
        return
    end
    local buyerCid = Player.PlayerData.citizenid
    if listing.seller == buyerCid then return end -- your own listing: take it back instead
    -- an earlier purchase of theirs still waits on the bank: this click would charge them again
    if PFSettle.BuyerWaiting(buyerCid) then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.payment_waiting'), 'error', 5000) end
    -- a job fleet car is not sold (the buyer would pay for a car they can never take out); the
    -- claim below repeats this in the same statement, so a car put in a fleet meanwhile is not sold
    local fleetSql, fleetParams = notInFleet(listing.plate)
    if not fleetSql or isFleetPlate(listing.plate) then
        return TriggerClientEvent('QBCore:Notify', src, Lang:t(fleetSql and 'error.fleet_vehicle' or 'error.lot_unavailable'), 'error', 3500)
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
    if Player.PlayerData.money.bank < total then return notEnough(src, subtotal, taxAmount, total) end

    -- 1) the buyer pays (keyed), 2) the listing is claimed by one DELETE, so of two buyers at the
    -- same moment only one gets the car and the other is refunded, 3) the seller (online or
    -- offline) and the tax are paid through the ledger, each kept until it is paid.
    local key = ('pfm-vehiclesales:buy:%s:%s:%s'):format(tostring(listing.occasionid), tostring(listing.plate), PFPayout.NewId())
    local sale = { key = key, subtotal = subtotal, tax = taxAmount, total = total, sellerAmount = math.ceil((subtotal / 100) * 77) }
    local buyer = ownerOf(Player)
    local claimSql = 'DELETE FROM occasion_vehicles WHERE plate = ? AND occasionid = ? AND price = ?' .. fleetSql
    local claimParams = { listing.plate, listing.occasionid, listing.price, table.unpack(fleetParams) }
    local account, res = PFPayout.Charge(src, 'bank', total, { key = key, kind = 'purchase', reason = 'Used vehicle ' .. tostring(listing.plate), quiet = true })
    if not account then
        if type(res) == 'table' and res.unclear then
            -- the bank has not confirmed the charge: no car now and no second charge. The listing
            -- is claimed for this buyer so no one else buys it meanwhile; the sweep finishes the
            -- sale when the money arrives (the car parked for them) or puts it back on the lot.
            local claimed = MySQL.query.await(claimSql, claimParams)
            claimed = claimed ~= nil and (claimed.affectedRows or 0) > 0
            local hold = PFSettle.Hold({ flow = 'usedlot', key = key, accounts = { 'bank' }, citizenid = buyerCid, amount = total, plate = listing.plate,
                txId = res.txId, data = { listing = listing, claimed = claimed, sale = sale, license = buyer.license } })
            local garage = type(Config.DeliveryGarage) == 'string' and Config.DeliveryGarage or 'pillboxgarage'
            TriggerClientEvent('QBCore:Notify', src, Lang:t(claimed and 'info.payment_held' or 'info.payment_held_gone', { garage = garage, ref = hold.ref }), 'primary', 10000)
            TriggerClientEvent('qb-occasion:client:refreshVehicles', -1)
            if PFUsedCars and PFUsedCars.Changed then PFUsedCars.Changed() end
            return
        end
        if type(res) == 'table' and (res.error == 'bank_unavailable' or res.error == 'ledger_unavailable') then
            return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.bank_unavailable'), 'error', 3500)
        end
        return notEnough(src, subtotal, taxAmount, total)
    end
    -- the claim also needs the price unchanged (a reprice between the read above) and the car not in
    -- a job fleet
    local claimed = MySQL.query.await(claimSql, claimParams)
    if not claimed or (claimed.affectedRows or 0) < 1 then
        PFSettle.Owe({ key = key .. ':refund', to = buyerCid, account = 'bank', amount = total, kind = 'refund', reason = 'Vehicle already sold', label = 'a used car that was already sold' })
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.vehicle_does_not_exist'), 'error', 3500)
        return
    end
    -- the car as listed: its condition and odometer, never the seller's loan
    if not insertOwned(buyer, listing, SOLD_WITH) then
        -- the car could not be written: the buyer gets the money back and the car stays listed
        relist(listing)
        PFSettle.Owe({ key = key .. ':refund', to = buyerCid, account = 'bank', amount = total, kind = 'refund', reason = 'Vehicle purchase failed', label = 'a used car purchase that failed' })
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.lot_unavailable'), 'error', 3500)
        return
    end
    payForSale(listing, buyer, sale)
    exports['pfm-core']:GrantVehicleSpawn(src, listing.model)
    -- what the client spawns, not the listing's record (it holds the seller's loan columns)
    TriggerClientEvent('qb-occasions:client:BuyFinished', src, { model = listing.model, plate = listing.plate, mods = listing.mods })
    TriggerClientEvent('QBCore:Notify', src, ('Vehicle purchase complete. Subtotal: $%.2f | Tax: $%.2f | Total: $%.2f'):format(subtotal, taxAmount, total), 'success')
end)

-- ── purchases that waited on the bank (settlements.lua) ────────────────────────────────────────
-- The sweep runs one of these once a held charge settled. Rerun-safe: a car already written is
-- found by its plate, a listing already back on the lot is not put back twice, payments are keyed.

local function heldTell(cid, key, subs, kind) PFSettle.Tell(cid, Lang:t(key, subs), kind or 'primary', Lang:t('info.held_subject')) end

local function labelOf(listing)
    local v = sharedVehicles[listing.model]
    return v and v.name or tostring(listing.model)
end

--- Puts a held listing back on the lot (once).
local function releaseListing(hold)
    local d = hold.data
    if not d.claimed then return end
    local l = d.listing
    local there = MySQL.scalar.await('SELECT id FROM occasion_vehicles WHERE occasionid = ? AND plate = ?', { l.occasionid, l.plate })
    if not there then relist(l) end
    TriggerClientEvent('qb-occasion:client:refreshVehicles', -1)
    if PFUsedCars and PFUsedCars.Changed then PFUsedCars.Changed() end
end

PFSettle.handlers.usedlot = {
    charged = function(hold)
        local d = hold.data
        local l, sale = d.listing, d.sale
        local buyer = { license = d.license, citizenid = hold.citizenid }
        local owner = MySQL.scalar.await('SELECT citizenid FROM player_vehicles WHERE plate = ?', { l.plate })
        if d.claimed and (owner == nil or owner == hold.citizenid) then
            -- the car is written now (parked for the buyer), or was by an earlier run of this handler
            if owner == nil and not insertOwned(buyer, l, SOLD_WITH, true) then error('the vehicle could not be written') end
            payForSale(l, buyer, sale)
            heldTell(hold.citizenid, 'info.held_delivered', { vehicle = labelOf(l), plate = l.plate,
                garage = type(Config.DeliveryGarage) == 'string' and Config.DeliveryGarage or 'pillboxgarage' }, 'success')
            return
        end
        -- the listing was gone before the money arrived (sold, repriced, a fleet car): the money goes back
        PFSettle.Owe({ key = sale.key .. ':refund', to = hold.citizenid, account = 'bank', amount = sale.total, kind = 'refund',
            reason = 'Vehicle already sold', label = 'a used car that was no longer for sale' })
        if d.claimed then releaseListing(hold) end
        heldTell(hold.citizenid, 'info.held_refunded', { vehicle = labelOf(l), amount = sale.total })
    end,
    none = function(hold)
        releaseListing(hold)
        heldTell(hold.citizenid, 'info.held_cancelled', { vehicle = labelOf(hold.data.listing) })
    end,
    review = function(hold)
        releaseListing(hold)
        heldTell(hold.citizenid, 'info.held_review', { vehicle = labelOf(hold.data.listing), ref = '#' .. tostring(hold.id) }, 'error')
    end,
}
