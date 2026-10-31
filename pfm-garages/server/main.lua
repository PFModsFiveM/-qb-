local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions' })
local sharedVehicles = exports['pfm-core']:GetShared('Vehicles')
local OutsideVehicles = {}

-- Shared with server/apps.lua (the Garages app on the tablet and the computer).
PFGarages = PFGarages or {}
PFGarages.dbReady = false   -- true once this resource's own tables exist (migrations ran)

PFGarages.Migrations = {
    { version = 1, name = 'impound releases paid in advance', up = {
        [[CREATE TABLE IF NOT EXISTS `pfm_garage_depot_releases` (
            `id` INT NOT NULL AUTO_INCREMENT,
            `plate` VARCHAR(16) NOT NULL,
            `citizenid` VARCHAR(50) NOT NULL,
            `fee` INT NOT NULL DEFAULT 0,
            `paid` INT NOT NULL DEFAULT 0,
            `attempt` INT NOT NULL DEFAULT 1,
            `state` VARCHAR(12) NOT NULL DEFAULT 'open',
            `ledger_key` VARCHAR(128) DEFAULT NULL,
            `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `paid_at` TIMESTAMP NULL DEFAULT NULL,
            `used_at` TIMESTAMP NULL DEFAULT NULL,
            PRIMARY KEY (`id`),
            KEY `plate_state` (`plate`, `state`),
            KEY `citizenid` (`citizenid`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
    } },
}

function PFGarages.Start()
    local ok, done, err = pcall(function() return exports['pfm-core']:RunMigrations(GetCurrentResourceName(), PFGarages.Migrations) end)
    PFGarages.dbReady = ok and done == true
    if not PFGarages.dbReady then
        print('^1[pfm-garages]^7 migrations failed, impound fees paid ahead are kept in memory only: ' .. tostring(ok and err or done))
    end
    if Config['AutoRespawn'] then
        MySQL.update('UPDATE player_vehicles SET state = 1 WHERE state = 0', {})
    else
        MySQL.update('UPDATE player_vehicles SET depotprice = ? WHERE state = 0', { Config.DepotPrice or 500 })
    end
    if PFGarages.RegisterApps then PFGarages.RegisterApps() end
end

-- Handler

AddEventHandler('onResourceStart', function(resource)
    if resource == 'pf-devices' then
        if PFGarages.RegisterApps then PFGarages.RegisterApps() end
        return
    end
    if resource == GetCurrentResourceName() then
        Wait(100)
        PFGarages.Start()
    end
end)

-- Functions

local vehicleClasses = {
    compacts = 0,
    sedans = 1,
    suvs = 2,
    coupes = 3,
    muscle = 4,
    sportsclassics = 5,
    sports = 6,
    super = 7,
    motorcycles = 8,
    offroad = 9,
    industrial = 10,
    utility = 11,
    vans = 12,
    cycles = 13,
    boats = 14,
    helicopters = 15,
    planes = 16,
    service = 17,
    emergency = 18,
    military = 19,
    commercial = 20,
    trains = 21,
    openwheel = 22,
}

-- Returns the owning citizenid for a plate, or nil
local function GetPlateOwner(plate)
    if type(plate) ~= 'string' or plate == '' then return nil end
    return MySQL.scalar.await('SELECT citizenid FROM player_vehicles WHERE plate = ? LIMIT 1', { plate })
end

-- True when the player owns the plate
local function IsPlateOwnedBy(Player, plate)
    if not Player then return false end
    local owner = GetPlateOwner(plate)
    return owner ~= nil and owner == Player.PlayerData.citizenid
end

local function clampNumber(value, min, max, default)
    value = tonumber(value)
    if not value then return default end
    if value < min then return min end
    if value > max then return max end
    return value
end

local function arrayToSet(array)
    local set = {}
    for _, item in ipairs(array) do
        set[item] = true
    end
    return set
end

local function filterVehiclesByCategory(vehicles, category)
    local filtered = {}
    local categorySet = arrayToSet(category)

    for _, vehicle in pairs(vehicles) do
        local vehicleData = sharedVehicles[vehicle.vehicle]
        local vehicleCategoryString = vehicleData and vehicleData.category or 'compacts'
        local vehicleCategoryNumber = vehicleClasses[vehicleCategoryString]

        if vehicleCategoryNumber and categorySet[vehicleCategoryNumber] then
            filtered[#filtered + 1] = vehicle
        end
    end

    return filtered
end

-- Job fleet cars (pf-jobgarages job_garage_vehicles, active) come out of their job garage only:
-- the owner's personal garages and impound neither list nor spawn them. Taking a car out of the
-- fleet (active = 0) gives it back to the personal garage.
local fleetTableKnown = nil
local function fleetTableExists()
    if fleetTableKnown == nil then
        fleetTableKnown = (tonumber(MySQL.scalar.await(
            "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'job_garage_vehicles'")) or 0) > 0
        if not fleetTableKnown then SetTimeout(300000, function() fleetTableKnown = nil end) end
    end
    return fleetTableKnown
end

local function fleetPlateSet(plates)
    local set = {}
    if #plates == 0 or not fleetTableExists() then return set end
    local marks = string.rep('?,', #plates):sub(1, -2)
    local ok, rows = pcall(function()
        return MySQL.query.await('SELECT plate FROM job_garage_vehicles WHERE active = 1 AND plate IN (' .. marks .. ')', plates)
    end)
    for _, r in ipairs(ok and rows or {}) do set[r.plate] = true end
    return set
end

local function isFleetPlate(plate) return fleetPlateSet({ plate })[plate] == true end

local function withoutFleet(vehicles)
    local plates = {}
    for _, v in pairs(vehicles) do if v.plate then plates[#plates + 1] = v.plate end end
    local fleet = fleetPlateSet(plates)
    if not next(fleet) then return vehicles end
    local out = {}
    for _, v in pairs(vehicles) do if not fleet[v.plate] then out[#out + 1] = v end end
    return out
end

PFGarages.FleetPlateSet = fleetPlateSet
PFGarages.IsFleetPlate = isFleetPlate
PFGarages.VehicleClasses = vehicleClasses

-- ── impound release fee ─────────────────────────────────────────────────────────────────────────
-- One payment path for the depot NUI and the Garages app. The fee is read from the player's own
-- car row; it is charged through the pfm-banking ledger (cash, then bank) under keys derived from
-- the release record, so a retried or interrupted payment never charges twice. A paid release is
-- stored (pfm_garage_depot_releases) and lets the owner take the car out at a depot later, also
-- after a restart; taking the car out uses it up.

-- Impound fees paid and not yet used to take the car out: [plate] = citizenid (also in the table)
local paidRelease = {}
local payingDepot = {}   -- [plate] = true while a fee for that car is being paid

--- Charges `amount` from the player's accounts in order under keys base:<n>:<account>, starting at
--- attempt `first`. A key the ledger already closed without moving money (not enough money that
--- time) is skipped, so the player can pay later; a key that completed counts as paid, so a retry
--- after a crash never pays twice; a key still in flight stops the attempt.
--- @return string|false account, string key, table result, number nextAttempt
local function stableCharge(cid, accounts, amount, base, opts, first)
    local attempt = math.max(1, math.floor(tonumber(first) or 1))
    for _ = 1, 50 do
        local key = base .. ':' .. attempt
        local spent, last = 0, nil
        for _, account in ipairs(accounts) do
            local res = PFPayout.Transfer({
                from = ('player:%s:%s'):format(cid, account), to = PFPayout.SYSTEM, amount = amount,
                key = key .. ':' .. account, kind = opts.kind or 'fee', reason = opts.reason, actor = cid,
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

local function releaseRow(plate)
    return MySQL.single.await("SELECT id, citizenid, fee, paid, attempt, state FROM pfm_garage_depot_releases WHERE plate = ? AND state IN ('open', 'paid') ORDER BY id DESC LIMIT 1", { plate })
end

-- The open release of this car for this owner, created when there is none. A release left by a
-- previous owner is voided.
local function openRelease(plate, cid, fee)
    local row = releaseRow(plate)
    if row and row.citizenid ~= cid then
        MySQL.update.await("UPDATE pfm_garage_depot_releases SET state = 'void' WHERE id = ?", { row.id })
        row = nil
    end
    if row then return row end
    local id = MySQL.insert.await('INSERT INTO pfm_garage_depot_releases (plate, citizenid, fee) VALUES (?, ?, ?)', { plate, cid, fee })
    if not id then return nil end
    return { id = id, citizenid = cid, fee = fee, paid = 0, attempt = 1, state = 'open' }
end

--- True when this owner already paid the current fee of this car.
function PFGarages.ReleasePaid(plate, cid, fee)
    if paidRelease[plate] == cid then return true end
    if not PFGarages.dbReady then return false end
    local row = releaseRow(plate)
    return row ~= nil and row.state == 'paid' and row.citizenid == cid and (tonumber(row.paid) or 0) >= (tonumber(fee) or 0)
end

--- The car left the depot: its paid release is used up.
function PFGarages.ConsumeRelease(plate)
    paidRelease[plate] = nil
    if PFGarages.dbReady then
        MySQL.update.await("UPDATE pfm_garage_depot_releases SET state = 'used', used_at = NOW() WHERE plate = ? AND state IN ('open', 'paid')", { plate })
    end
end

--- Paid releases of this owner's cars: [plate] = amount paid.
function PFGarages.PaidReleases(cid)
    local out = {}
    for plate, owner in pairs(paidRelease) do if owner == cid then out[plate] = true end end
    if PFGarages.dbReady then
        for _, r in ipairs(MySQL.query.await("SELECT plate, paid FROM pfm_garage_depot_releases WHERE citizenid = ? AND state = 'paid'", { cid }) or {}) do
            out[r.plate] = tonumber(r.paid) or true
        end
    end
    return out
end

--- A paid release whose car no longer has a fee (released another way) must not pay for a later impound.
function PFGarages.VoidStaleRelease(plate)
    paidRelease[plate] = nil
    if PFGarages.dbReady then
        MySQL.update.await("UPDATE pfm_garage_depot_releases SET state = 'void' WHERE plate = ? AND state IN ('open', 'paid')", { plate })
    end
end

local function payDepotLocked(Player, plate, fee)
    local cid = Player.PlayerData.citizenid
    local release, base, first, paidBefore = nil, nil, 1, 0
    if PFGarages.dbReady then
        release = openRelease(plate, cid, fee)
        if not release then return { ok = false, error = 'server_error' } end
        paidBefore = tonumber(release.paid) or 0
        if paidBefore >= fee then
            paidRelease[plate] = cid
            return { ok = true, already = true, paid = 0, fee = fee }
        end
        base = ('pfm-garages:depot:%d:%d:%d'):format(tonumber(release.id), paidBefore, fee - paidBefore)
        first = tonumber(release.attempt) or 1
    else
        -- without the table the release is remembered until a restart, as before
        base = ('pfm-garages:depot:%s:%s'):format(plate, PFPayout.NewId())
    end
    local due = fee - paidBefore
    local account, key, res, nextAttempt = stableCharge(cid, { 'cash', 'bank' }, due, base, { kind = 'fee', reason = 'Impound release ' .. plate }, first)
    if not account then
        if release then MySQL.update.await('UPDATE pfm_garage_depot_releases SET attempt = ? WHERE id = ?', { nextAttempt, release.id }) end
        local err = res and res.error or 'payment_failed'
        if err == 'failed' then err = 'insufficient_funds' end
        return { ok = false, error = err }
    end
    if release then
        MySQL.update.await("UPDATE pfm_garage_depot_releases SET paid = paid + ?, fee = ?, state = 'paid', attempt = 1, ledger_key = ?, paid_at = NOW() WHERE id = ?",
            { due, fee, key, release.id })
    end
    paidRelease[plate] = cid
    -- the city treasury is credited only for a fee that was paid, once per payment key
    if GetResourceState('pf-government') == 'started' then
        pcall(function()
            exports['pf-government']:DepositToTreasury(due, 'impound', ('Impound release fee (%s)'):format(plate), cid, key .. ':treasury')
        end)
    end
    return { ok = true, paid = due, fee = fee, account = account }
end

--- Pays the impound release fee of the player's own car. Returns { ok, paid, fee, already } or
--- { ok = false, error }: bad_plate, not_owned, fleet, seized, nothing_due, in_progress,
--- insufficient_funds, bank_unavailable.
function PFGarages.PayDepot(src, plate)
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return { ok = false, error = 'no_player' } end
    if type(plate) ~= 'string' or plate == '' or #plate > 16 then return { ok = false, error = 'bad_plate' } end
    -- a fleet car could not be taken out after paying
    if isFleetPlate(plate) then return { ok = false, error = 'fleet' } end
    local cid = Player.PlayerData.citizenid
    -- the fee is read from the player's own car; nothing the client sends is used
    local row = MySQL.single.await('SELECT vehicle, mods, state, depotprice FROM player_vehicles WHERE plate = ? AND citizenid = ? LIMIT 1', { plate, cid })
    if not row then return { ok = false, error = 'not_owned' } end
    if tonumber(row.state) == 2 then return { ok = false, error = 'seized' } end
    local fee = math.floor(tonumber(row.depotprice) or 0)
    if fee <= 0 then return { ok = false, error = 'nothing_due' } end
    if payingDepot[plate] then return { ok = false, error = 'in_progress' } end
    payingDepot[plate] = true
    local ok, res = pcall(payDepotLocked, Player, plate, fee)
    payingDepot[plate] = nil
    if not ok then
        print(('^1[pfm-garages]^7 impound fee for %s failed: %s'):format(plate, tostring(res)))
        return { ok = false, error = 'server_error' }
    end
    return res
end

-- Callbacks

QBCore.Functions.CreateCallback('qb-garages:server:getHouseGarage', function(_, cb, house)
    local houseInfo = MySQL.single.await('SELECT * FROM houselocations WHERE name = ?', { house })
    cb(houseInfo)
end)

-- Collects the citizenids of online players in the given job/gang (including the requester)
local function GetGroupMemberCitizenIds(groupKind, groupName)
    local members = {}
    local players = QBCore.Functions.GetQBPlayers()
    for _, p in pairs(players) do
        local data = p and p.PlayerData
        if data then
            local group = groupKind == 'gang' and data.gang or data.job
            if group and group.name == groupName then
                members[#members + 1] = data.citizenid
            end
        end
    end
    return members
end

QBCore.Functions.CreateCallback('qb-garages:server:GetGarageVehicles', function(source, cb, garage, type, category)
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player then return end
    local citizenId = Player.PlayerData.citizenid

    local vehicles
    local garageConfig = Config.Garages[garage]
    local garageType = garageConfig and garageConfig.type or type

    if garageType == 'depot' or type == 'depot' then
        vehicles = MySQL.rawExecute.await('SELECT * FROM player_vehicles WHERE citizenid = ? AND depotprice > 0', { citizenId })
    elseif Config.SharedGarages and garageConfig and (garageType == 'job' or garageType == 'gang') and garageConfig.job then
        -- Shared job/gang garage: list vehicles of every member currently in the job/gang (read-only
        -- for non-owned entries - spawning still requires ownership server-side)
        local playerGroup = garageType == 'gang' and Player.PlayerData.gang or Player.PlayerData.job
        if not playerGroup or playerGroup.name ~= garageConfig.job then
            cb(nil)
            return
        end
        local members = GetGroupMemberCitizenIds(garageType, garageConfig.job)
        local placeholders = {}
        for i = 1, #members do placeholders[i] = '?' end
        vehicles = MySQL.rawExecute.await('SELECT * FROM player_vehicles WHERE citizenid IN (' .. table.concat(placeholders, ',') .. ')', members)
        if vehicles then
            for _, v in pairs(vehicles) do
                v.shared = v.citizenid ~= citizenId
            end
        end
    elseif Config.SharedGarages then
        vehicles = MySQL.rawExecute.await('SELECT * FROM player_vehicles WHERE citizenid = ?', { citizenId })
    else
        vehicles = MySQL.rawExecute.await('SELECT * FROM player_vehicles WHERE citizenid = ? AND garage = ?', { citizenId, garage })
    end
    if not vehicles then
        cb(nil)
        return
    end
    vehicles = withoutFleet(vehicles)
    if #vehicles == 0 then
        cb(nil)
        return
    end
    if garageType == 'depot' or type == 'depot' then
        -- a fee paid ahead in the Garages app shows as paid; the spawn checks it again
        local paid = PFGarages.PaidReleases(citizenId)
        for _, v in pairs(vehicles) do
            local amount = paid[v.plate]
            if amount and (amount == true or amount >= (tonumber(v.depotprice) or 0)) then
                v.depotprice = 0
                v.depotPaid = true
            end
        end
    end
    if Config.ClassSystem then
        local filteredVehicles = filterVehiclesByCategory(vehicles, category)
        cb(filteredVehicles)
    else
        cb(vehicles)
    end
end)

-- Backwards Compat
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
-- Backwards Compat

local function isOutside(plate)
    local out = OutsideVehicles[plate]
    return out ~= nil and out.entity ~= nil and DoesEntityExist(out.entity)
end

PFGarages.IsOutside = isOutside

--- The car with this plate in the world (the one this resource spawned, else any with that plate).
function PFGarages.FindVehicle(plate)
    if isOutside(plate) then return OutsideVehicles[plate].entity end
    local want = tostring(plate):gsub('^%s+', ''):gsub('%s+$', ''):upper()
    for _, veh in ipairs(GetAllVehicles and GetAllVehicles() or {}) do
        local text = GetVehicleNumberPlateText(veh)
        if text and tostring(text):gsub('^%s+', ''):gsub('%s+$', ''):upper() == want then return veh end
    end
    return nil
end

--- Forgets a car this resource tracked as out (it was parked by a tow).
function PFGarages.ForgetOutside(plate) OutsideVehicles[plate] = nil end

-- Spawns a vehicle and returns its network ID and properties.
-- Only a car that is in the garage (state 1, no impound fee), or whose impound fee was just paid, and
-- that is not already out; next to the player. (Any owned car could be spawned any number of times,
-- from the impound without paying, anywhere.)
QBCore.Functions.CreateCallback('qb-garages:server:spawnvehicle', function(source, cb, plate, _, coords)
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player or type(plate) ~= 'string' or type(coords) ~= 'table' or not tonumber(coords.x) or not tonumber(coords.y) or not tonumber(coords.z) then
        cb(nil, nil, nil)
        return
    end
    local cid = Player.PlayerData.citizenid
    local ownedVehicle = MySQL.single.await('SELECT vehicle, mods, state, depotprice FROM player_vehicles WHERE plate = ? AND citizenid = ? LIMIT 1', { plate, cid })
    if not ownedVehicle or isOutside(plate) then
        cb(nil, nil, nil)
        return
    end
    if isFleetPlate(plate) then
        TriggerClientEvent('QBCore:Notify', source, 'This vehicle is in a job fleet. Take it from the job garage.', 'error')
        cb(nil, nil, nil)
        return
    end
    if #(GetEntityCoords(GetPlayerPed(source)) - vector3(tonumber(coords.x), tonumber(coords.y), tonumber(coords.z))) > 100.0 then
        cb(nil, nil, nil)
        return
    end
    local fee = tonumber(ownedVehicle.depotprice) or 0
    if fee > 0 then
        if not PFGarages.ReleasePaid(plate, cid, fee) then
            cb(nil, nil, nil)
            return
        end
        PFGarages.ConsumeRelease(plate)
        MySQL.update('UPDATE player_vehicles SET depotprice = 0 WHERE plate = ? AND citizenid = ?', { plate, cid })
    elseif tonumber(ownedVehicle.state) ~= 1 then
        cb(nil, nil, nil)
        return
    end
    MySQL.update('UPDATE player_vehicles SET state = 0 WHERE plate = ? AND citizenid = ?', { plate, cid })
    local vehType = sharedVehicles[ownedVehicle.vehicle] and sharedVehicles[ownedVehicle.vehicle].type or GetVehicleTypeByModel(ownedVehicle.vehicle)
    local hash = type(ownedVehicle.vehicle) == 'number' and ownedVehicle.vehicle or type(ownedVehicle.vehicle) == 'string' and GetHashKey(ownedVehicle.vehicle) or nil
    if not hash then
        cb(nil, nil, nil)
        return
    end
    local veh = CreateVehicleServerSetter(hash, vehType, coords.x, coords.y, coords.z, coords.w)
    local netId = NetworkGetNetworkIdFromEntity(veh)
    SetVehicleNumberPlateText(veh, plate)
    local vehProps = {}
    if ownedVehicle.mods then vehProps = json.decode(ownedVehicle.mods) end
    OutsideVehicles[plate] = { netID = netId, entity = veh }
    cb(netId, vehProps, plate)
end)

-- Checks if a vehicle can be spawned based on its type and location.
QBCore.Functions.CreateCallback('qb-garages:server:IsSpawnOk', function(_, cb, plate, type)
    if OutsideVehicles[plate] and DoesEntityExist(OutsideVehicles[plate].entity) then
        cb(false)
        return
    end
    cb(true)
end)

QBCore.Functions.CreateCallback('qb-garages:server:canDeposit', function(source, cb, plate, type, garage, state)
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player then
        cb(false)
        return
    end
    local isOwned = GetPlateOwner(plate)
    if isOwned ~= Player.PlayerData.citizenid then
        cb(false)
        return
    end
    if type == 'house' and not Config.Garages[garage] then
        cb(false)
        return
    end
    if type == 'house' and not exports['pfm-houses']:hasKey(Player.PlayerData.license, Player.PlayerData.citizenid, Config.Garages[garage].houseName) then
        cb(false)
        return
    end
    if state == 1 then
        MySQL.update('UPDATE player_vehicles SET state = ?, garage = ? WHERE plate = ?', { state, garage, plate })
        cb(true)
    else
        cb(false)
    end
end)

-- Events

-- Saves a parked car's mods. This used to go to pfm-mechanicjob ('qb-mechanicjob:server:SaveVehicleProps'),
-- which is no longer installed (pf-mechanicjob is the mechanic job). Only the car's owner can save,
-- and only to their own car's row.
RegisterNetEvent('qb-garages:server:SaveVehicleProps', function(vehicleProps)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or type(vehicleProps) ~= 'table' or type(vehicleProps.plate) ~= 'string' then return end
    local encoded = json.encode(vehicleProps)
    if #encoded > 65535 then return end
    MySQL.update('UPDATE player_vehicles SET mods = ? WHERE plate = ? AND citizenid = ?', { encoded, vehicleProps.plate, Player.PlayerData.citizenid })
end)

RegisterNetEvent('qb-garages:server:updateVehicleStats', function(plate, fuel, engine, body)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if type(plate) ~= 'string' then return end
    fuel = clampNumber(fuel, 0, 100, 100)
    engine = clampNumber(engine, 0, 1000, 1000)
    body = clampNumber(body, 0, 1000, 1000)
    MySQL.update('UPDATE player_vehicles SET fuel = ?, engine = ?, body = ? WHERE plate = ? AND citizenid = ?', { fuel, engine, body, plate, Player.PlayerData.citizenid })
end)

-- The client reports a car it took out (state 0). Parking (state 1) is set by canDeposit, and the
-- impound fee is cleared by the spawn once paid: this event used to accept any state and clear the
-- fee, so a car could be marked parked while still out (and spawned again) or released unpaid.
RegisterNetEvent('qb-garages:server:updateVehicleState', function(state, plate)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    state = tonumber(state)
    if state ~= 0 or type(plate) ~= 'string' then return end
    MySQL.update('UPDATE player_vehicles SET state = ? WHERE plate = ? AND citizenid = ?', { 0, plate, Player.PlayerData.citizenid })
end)

RegisterNetEvent('qb-garages:server:UpdateOutsideVehicle', function(plate, vehicleNetID)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or not IsPlateOwnedBy(Player, plate) then return end
    if vehicleNetID then
        OutsideVehicles[plate] = {
            netID = vehicleNetID,
            entity = NetworkGetEntityFromNetworkId(vehicleNetID)
        }
    elseif not isOutside(plate) then
        -- forgotten only once the car is really gone (else the spawn could run again while it exists)
        OutsideVehicles[plate] = nil
    end
end)

RegisterNetEvent('qb-garages:server:trackVehicle', function(plate)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or not IsPlateOwnedBy(Player, plate) then return end
    local vehicleData = OutsideVehicles[plate]
    if vehicleData and DoesEntityExist(vehicleData.entity) then
        TriggerClientEvent('qb-garages:client:trackVehicle', src, GetEntityCoords(vehicleData.entity))
        TriggerClientEvent('QBCore:Notify', src, Lang:t('success.vehicle_tracked'), 'success')
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.vehicle_not_tracked'), 'error')
    end
end)

local DEPOT_ERRORS = {
    fleet = 'This vehicle is in a job fleet. Take it from the job garage.',
    seized = 'This vehicle was seized. Only the police can release it.',
    insufficient_funds = 'not_enough',
    bank_unavailable = 'The bank did not respond. Nothing was charged.',
    ledger_unavailable = 'The bank did not respond. Nothing was charged.',
    in_progress = 'That payment is already being processed',
}

-- The depot NUI: pay the release fee (or use one paid ahead in the Garages app), then take the car out.
RegisterNetEvent('qb-garages:server:PayDepotPrice', function(data)
    local src = source
    if type(data) ~= 'table' or type(data.plate) ~= 'string' then return end
    local res = PFGarages.PayDepot(src, data.plate)
    if res.ok or res.error == 'nothing_due' then
        TriggerClientEvent('qb-garages:client:takeOutGarage', src, data)
        if res.ok and PFGarages.PushChanged then PFGarages.PushChanged(src) end
        return
    end
    local msg = DEPOT_ERRORS[res.error]
    if msg == 'not_enough' or msg == nil then msg = Lang:t('error.not_enough') end
    if res.error ~= 'not_owned' and res.error ~= 'bad_plate' then
        TriggerClientEvent('QBCore:Notify', src, msg, 'error')
    end
end)

-- House Garages

RegisterNetEvent('qb-garages:server:syncGarage', function(updatedGarages)
    if type(updatedGarages) ~= 'table' then return end
    -- Only accept new house-garage entries from clients; never let a client overwrite
    -- or remove the static config garages (public/job/gang/depot)
    for name, garage in pairs(updatedGarages) do
        if type(garage) == 'table' and garage.type == 'house' and (not Config.Garages[name] or Config.Garages[name].type == 'house') then
            Config.Garages[name] = garage
        end
    end
end)

--Call from qb-phone

QBCore.Functions.CreateCallback('qb-garages:server:GetPlayerVehicles', function(source, cb)
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player then return cb(nil) end
    local Vehicles = {}

    MySQL.rawExecute('SELECT * FROM player_vehicles WHERE citizenid = ?', { Player.PlayerData.citizenid }, function(result)
        if result[1] then
            for _, v in pairs(result) do
                local VehicleData = sharedVehicles[v.vehicle]

                local VehicleGarage = Lang:t('error.no_garage')
                if v.garage ~= nil then
                    if Config.Garages[v.garage] ~= nil then
                        VehicleGarage = Config.Garages[v.garage].label
                    else
                        VehicleGarage = Lang:t('info.house')
                    end
                end

                local stateTranslation
                if v.state == 0 then
                    stateTranslation = Lang:t('status.out')
                elseif v.state == 1 then
                    stateTranslation = Lang:t('status.garaged')
                elseif v.state == 2 then
                    stateTranslation = Lang:t('status.impound')
                end

                local fullname
                if VehicleData and VehicleData['brand'] then
                    fullname = VehicleData['brand'] .. ' ' .. VehicleData['name']
                else
                    fullname = VehicleData and VehicleData['name'] or 'Unknown Vehicle'
                end

                Vehicles[#Vehicles + 1] = {
                    fullname = fullname,
                    brand = VehicleData and VehicleData['brand'] or '',
                    model = VehicleData and VehicleData['name'] or '',
                    plate = v.plate,
                    garage = VehicleGarage,
                    state = stateTranslation,
                    fuel = v.fuel,
                    engine = v.engine,
                    body = v.body
                }
            end
            cb(Vehicles)
        else
            cb(nil)
        end
    end)
end)

local function getAllGarages()
    local garages = {}
    for k, v in pairs(Config.Garages) do
        garages[#garages + 1] = {
            name = k,
            label = v.label,
            type = v.type,
            takeVehicle = v.takeVehicle,
            putVehicle = v.putVehicle,
            spawnPoint = v.spawnPoint,
            showBlip = v.showBlip,
            blipName = v.blipName,
            blipNumber = v.blipNumber,
            blipColor = v.blipColor,
            vehicle = v.vehicle
        }
    end
    return garages
end

exports('getAllGarages', getAllGarages)
