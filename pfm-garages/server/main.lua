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
    PFGarages.LoadHouseGarages()
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

local function trimPlate(plate)
    return (tostring(plate or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

local function samePlate(a, b) return trimPlate(a):upper() == trimPlate(b):upper() end

--- Rows changed by an update (oxmysql returns a number; some wrappers a table).
local function affected(res)
    if type(res) == 'table' then return tonumber(res.affectedRows) or 0 end
    return tonumber(res) or 0
end

local function finite(n)
    n = tonumber(n)
    if not n or n ~= n or n == math.huge or n == -math.huge then return nil end
    return n
end

-- ── house garages ───────────────────────────────────────────────────────────────────────────────
-- Built only on the server: from houselocations when the resource starts and from pfm-houses when a
-- real estate agent places one (exports SetHouseGarage). Every client used to send its whole garage
-- list (qb-garages:server:syncGarage), so anyone could point another house's garage at their own
-- house, move it, give it a label that broke the Garages app, or add any number of entries.

--- The id of a house's garage everywhere: Config.Garages key, player_vehicles.garage, client zones.
local function houseGarageId(house)
    return (house:lower():gsub(' ', ''))
end
PFGarages.HouseGarageId = houseGarageId

--- x, y, z, heading of a point given as a table, a vector or the JSON text houselocations keeps.
local function readPoint(v)
    if type(v) == 'string' then
        local ok, decoded = pcall(json.decode, v)
        v = ok and decoded or nil
    end
    local t = type(v)
    if t ~= 'table' and t ~= 'vector3' and t ~= 'vector4' then return nil end
    local ok, x, y, z, w = pcall(function() return finite(v.x), finite(v.y), finite(v.z), finite(v.w or v.h) end)
    if not ok or not x or not y or not z then return nil end
    return x, y, z, w or 0.0
end

local function houseGarageEntry(house, label, coords)
    if type(house) ~= 'string' or house == '' or #house > 128 then return nil end
    local x, y, z, w = readPoint(coords)
    -- houselocations stores 0,0,0 for a house without a garage
    if not x or (x == 0 and y == 0 and z == 0) then return nil end
    label = type(label) == 'string' and label:gsub('%c', '') or ''
    if label == '' then label = house end
    return {
        houseName = house,
        label = label:sub(1, 100),
        takeVehicle = vector3(x, y, z),
        spawnPoint = { vector4(x, y, z, w) },
        type = 'house',
        category = Config.VehicleClass and Config.VehicleClass['all'] or nil,
        showBlip = false,
    }
end

--- Adds or moves the garage of a house. A configured garage (public, job, gang, depot) is never
--- replaced, and an id already used by another house keeps that house's garage.
function PFGarages.SetHouseGarage(house, label, coords)
    local entry = houseGarageEntry(house, label, coords)
    if not entry then return false end
    local id = houseGarageId(house)
    local current = Config.Garages[id]
    if current and (current.type ~= 'house' or current.houseName ~= house) then return false end
    Config.Garages[id] = entry
    return true
end

exports('SetHouseGarage', function(house, label, coords) return PFGarages.SetHouseGarage(house, label, coords) end)

--- Reads every house garage from the houses table (pfm-houses may not be installed: then none).
function PFGarages.LoadHouseGarages()
    local ok, rows = pcall(MySQL.query.await, 'SELECT name, label, garage FROM houselocations', {})
    if not ok or type(rows) ~= 'table' then return 0 end
    local n = 0
    for _, r in ipairs(rows) do
        if PFGarages.SetHouseGarage(r.name, r.label, r.garage) then n = n + 1 end
    end
    return n
end

-- ── who may use a garage, and from where ────────────────────────────────────────────────────────

local GARAGE_REACH = 15.0   -- the garage zone is 10 m (5 m for a house); a car's length and lag on top
local DEPOSIT_REACH = 10.0  -- the parked car: the one the player sits in, else one this close

--- The garage's own rules (the client only shows zones it may use; the server used to trust the
--- type the client named).
local function mayUseGarage(Player, garage)
    local kind, data = garage.type, Player.PlayerData
    if kind == 'public' or kind == 'depot' then return true end
    if kind == 'job' then
        local job = data.job or {}
        return (garage.job ~= nil and job.name == garage.job) or (garage.jobType ~= nil and job.type == garage.jobType)
    end
    if kind == 'gang' then return garage.job ~= nil and (data.gang or {}).name == garage.job end
    if kind == 'house' then
        if not garage.houseName or GetResourceState('pfm-houses') ~= 'started' then return false end
        local ok, has = pcall(function() return exports['pfm-houses']:hasKey(data.license, data.citizenid, garage.houseName) end)
        return ok and has == true
    end
    return false
end

--- The player stands at the garage (server position).
local function atGarage(src, garage)
    local p = garage.takeVehicle
    if not p then return false end
    local pos = GetEntityCoords(GetPlayerPed(src))
    return #(vector3(pos.x, pos.y, pos.z) - vector3(p.x, p.y, p.z)) <= GARAGE_REACH
end

--- The garage takes this model (Config.ClassSystem), by the same rule its list uses.
local function classAllowed(garage, model)
    if not Config.ClassSystem or type(garage.category) ~= 'table' then return true end
    local vehicleData = sharedVehicles[model]
    local class = vehicleClasses[vehicleData and vehicleData.category or 'compacts']
    for _, c in ipairs(garage.category) do
        if c == class then return true end
    end
    return false
end

PFGarages.MayUseGarage = mayUseGarage

-- One take-out or parking per car at a time: the checks and the update are separated by database
-- waits (two spawns at once both read "parked" and made two cars).
local plateBusy = {}

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
    local fee = MySQL.scalar.await('SELECT depotprice FROM player_vehicles WHERE plate = ? AND citizenid = ?', { plate, cid })
    if fee == nil then return { ok = false, error = 'not_owned' } end
    fee = math.floor(tonumber(fee) or 0)
    if fee <= 0 then return { ok = false, error = 'nothing_due' } end
    if PFGarages.dbReady then
        -- a seized car is released by the police, not by paying (the spawn refuses it as well)
        local state = MySQL.scalar.await('SELECT state FROM player_vehicles WHERE plate = ? AND citizenid = ?', { plate, cid })
        if tonumber(state) == 2 then return { ok = false, error = 'seized' } end
    end
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

-- The garage of a house as the server has it, for a client that has not heard of it yet. (This sent
-- the whole houselocations row.)
QBCore.Functions.CreateCallback('qb-garages:server:getHouseGarage', function(_, cb, house)
    if type(house) ~= 'string' or house == '' or #house > 128 then return cb(nil) end
    local g = Config.Garages[houseGarageId(house)]
    if not g or g.type ~= 'house' or g.houseName ~= house then return cb(nil) end
    local p = g.takeVehicle
    cb({ label = g.label, coords = { x = p.x, y = p.y, z = p.z, w = g.spawnPoint[1].w or 0.0 } })
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

--- A free spawn point of the garage: the one the client picked (it checks which are free), else the
--- first one no car stands on, else the first. Positions always come from the garage config.
local function spawnPointOf(garage, index)
    local points = garage.spawnPoint
    index = math.tointeger(tonumber(index))
    if index and points[index] then return points[index] end
    local cars = GetAllVehicles and GetAllVehicles() or {}
    for _, p in ipairs(points) do
        local taken = false
        for _, veh in ipairs(cars) do
            local pos = GetEntityCoords(veh)
            if #(vector3(pos.x, pos.y, pos.z) - vector3(p.x, p.y, p.z)) < 3.0 then taken = true break end
        end
        if not taken then return p end
    end
    return points[1]
end

local function refuseSpawn(src, message)
    if message then TriggerClientEvent('QBCore:Notify', src, message, 'error') end
    return nil
end

--- Takes the car out, while the caller holds the car's lock. Returns netId, props, plate or nil.
local function spawnLocked(src, Player, plate, garageId, garage, spawnIndex)
    local cid = Player.PlayerData.citizenid
    local row = MySQL.single.await('SELECT vehicle, mods, state, depotprice, garage FROM player_vehicles WHERE plate = ? AND citizenid = ? LIMIT 1', { plate, cid })
    if not row then return nil end
    -- never a second copy: not while this resource has it out, nor while any car shows its plate
    if PFGarages.FindVehicle(plate) then return refuseSpawn(src, 'This vehicle is still out in the city.') end
    if isFleetPlate(plate) then return refuseSpawn(src, 'This vehicle is in a job fleet. Take it from the job garage.') end
    local state, fee = tonumber(row.state), math.floor(tonumber(row.depotprice) or 0)
    if state == 2 then return nil end   -- seized: only the police release it
    if fee > 0 then
        -- an impounded car leaves from a depot, once its fee is paid
        if garage.type ~= 'depot' or not PFGarages.ReleasePaid(plate, cid, fee) then return nil end
    else
        -- a parked car leaves from the garage it is parked in (Config.SharedGarages: any garage of
        -- the player's); the client's spawn position and garage used to be taken as they came
        if state ~= 1 or garage.type == 'depot' then return nil end
        if not Config.SharedGarages and row.garage ~= garageId then return nil end
    end
    if not classAllowed(garage, row.vehicle) then return nil end
    local hash = type(row.vehicle) == 'number' and row.vehicle or type(row.vehicle) == 'string' and GetHashKey(row.vehicle) or nil
    if not hash then return nil end
    local vehType = sharedVehicles[row.vehicle] and sharedVehicles[row.vehicle].type or GetVehicleTypeByModel(row.vehicle)
    local point = spawnPointOf(garage, spawnIndex)
    local veh = CreateVehicleServerSetter(hash, vehType, point.x, point.y, point.z, point.w or 0.0)
    if not veh or veh == 0 then return nil end
    -- the row leaves the garage (or depot) only in the state checked above
    local ok, res = pcall(MySQL.update.await, 'UPDATE player_vehicles SET state = 0, depotprice = 0 WHERE plate = ? AND citizenid = ? AND state = ? AND depotprice = ?', { plate, cid, state, fee })
    if not ok or affected(res) < 1 then
        DeleteEntity(veh)
        return nil
    end
    if fee > 0 then PFGarages.ConsumeRelease(plate) end
    local netId = NetworkGetNetworkIdFromEntity(veh)
    SetVehicleNumberPlateText(veh, plate)
    -- pfm-fuel gives the car the fuel stored in this row (the plate set above reaches the server only through the owner's client)
    if GetResourceState('pfm-fuel') == 'started' then pcall(function() exports['pfm-fuel']:UseStoredFuel(veh, plate) end) end
    OutsideVehicles[plate] = { netID = netId, entity = veh }
    local decoded, props = pcall(json.decode, type(row.mods) == 'string' and row.mods or '')
    return netId, decoded and type(props) == 'table' and props or {}, plate
end

-- Spawns a car of the player's at the garage they stand at, on one of its spawn points, and returns
-- its network ID and properties: a parked car (state 1) from the garage it is parked in, an impounded
-- one from a depot once its fee is paid; never one that is already out. The client names the plate,
-- the garage and a spawn point number. (Any owned car came out anywhere within 100 m of the client's
-- position, from any garage.)
QBCore.Functions.CreateCallback('qb-garages:server:spawnvehicle', function(source, cb, plate, garageId, spawnIndex)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or type(plate) ~= 'string' or plate == '' or #plate > 16 or type(garageId) ~= 'string' or #garageId > 128 then
        return cb(nil, nil, nil)
    end
    local garage = Config.Garages[garageId]
    if not garage or type(garage.spawnPoint) ~= 'table' or not garage.spawnPoint[1] then return cb(nil, nil, nil) end
    if not mayUseGarage(Player, garage) or not atGarage(src, garage) then return cb(nil, nil, nil) end
    if plateBusy[plate] then return cb(nil, nil, nil) end
    plateBusy[plate] = true
    local ok, netId, props, vehPlate = pcall(spawnLocked, src, Player, plate, garageId, garage, spawnIndex)
    plateBusy[plate] = nil
    if not ok then
        print(('^1[pfm-garages]^7 taking out %s failed: %s'):format(plate, tostring(netId)))
        return cb(nil, nil, nil)
    end
    cb(netId, props, vehPlate)
end)

-- Checks if a vehicle can be spawned based on its type and location.
QBCore.Functions.CreateCallback('qb-garages:server:IsSpawnOk', function(_, cb, plate, type)
    if OutsideVehicles[plate] and DoesEntityExist(OutsideVehicles[plate].entity) then
        cb(false)
        return
    end
    cb(true)
end)

local PARK_REMOVE_MS = 4000   -- the owner's client gets everyone out and deletes the car in ~1.5 s

--- The car with this plate the player sits in, else the nearest one with it within reach.
local function carToPark(src, plate)
    local ped = GetPlayerPed(src)
    local veh = GetVehiclePedIsIn(ped, false)
    if veh and veh ~= 0 and samePlate(GetVehicleNumberPlateText(veh), plate) then return veh end
    local pos = GetEntityCoords(ped)
    local best, bestDist
    for _, v in ipairs(GetAllVehicles and GetAllVehicles() or {}) do
        if samePlate(GetVehicleNumberPlateText(v), plate) then
            local p = GetEntityCoords(v)
            local d = #(vector3(p.x, p.y, p.z) - vector3(pos.x, pos.y, pos.z))
            if d <= DEPOSIT_REACH and (not bestDist or d < bestDist) then best, bestDist = v, d end
        end
    end
    return best
end

--- A parked car leaves the world. The owner's client still saves its look and condition and deletes
--- it (everyone gets out first); the server removes it if that did not happen. Until it is gone it
--- counts as out, so it cannot be taken out a second time.
local function removeParked(plate, veh)
    local model = GetEntityModel(veh)
    OutsideVehicles[plate] = { netID = NetworkGetNetworkIdFromEntity(veh), entity = veh }
    SetTimeout(PARK_REMOVE_MS, function()
        if DoesEntityExist(veh) and GetEntityModel(veh) == model then DeleteEntity(veh) end
        local out = OutsideVehicles[plate]
        if out and out.entity == veh then OutsideVehicles[plate] = nil end
    end)
end

local function depositLocked(src, Player, plate, garageId, garage)
    local cid = Player.PlayerData.citizenid
    local row = MySQL.single.await('SELECT vehicle, state FROM player_vehicles WHERE plate = ? AND citizenid = ? LIMIT 1', { plate, cid })
    if not row or tonumber(row.state) == 2 then return false end
    if isFleetPlate(plate) then
        TriggerClientEvent('QBCore:Notify', src, 'This vehicle is in a job fleet. Park it at the job garage.', 'error')
        return false
    end
    if not classAllowed(garage, row.vehicle) then return false end
    -- the car itself, as the server sees it: parking only changed the row, so the car stayed in the
    -- world and the garage handed out a second copy
    local veh = carToPark(src, plate)
    if not veh then return false end
    local ok, res = pcall(MySQL.update.await, 'UPDATE player_vehicles SET state = 1, garage = ? WHERE plate = ? AND citizenid = ? AND state IN (0, 1)', { garageId, plate, cid })
    if not ok or affected(res) < 1 then return false end
    removeParked(plate, veh)
    return true
end

-- Parks the player's car at the garage they stand at. The garage, its type and who may use it are
-- the server's (a house garage needs a key); the car must be the one the player sits in (or right
-- beside them) with that plate. The client used to name the garage type and any plate from anywhere.
QBCore.Functions.CreateCallback('qb-garages:server:canDeposit', function(source, cb, plate, _, garageId, state)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or type(plate) ~= 'string' or #plate > 16 or type(garageId) ~= 'string' or #garageId > 128 or tonumber(state) ~= 1 then
        return cb(false)
    end
    plate = trimPlate(plate)
    local garage = Config.Garages[garageId]
    if plate == '' or not garage or garage.type == 'depot' then return cb(false) end
    if not mayUseGarage(Player, garage) or not atGarage(src, garage) then return cb(false) end
    if plateBusy[plate] then return cb(false) end
    plateBusy[plate] = true
    local ok, parked = pcall(depositLocked, src, Player, plate, garageId, garage)
    plateBusy[plate] = nil
    if not ok then print(('^1[pfm-garages]^7 parking %s failed: %s'):format(plate, tostring(parked))) end
    cb(ok and parked == true)
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
    if fuel ~= fuel then fuel = 100 end   -- NaN passes every comparison (read as full, then cut)
    fuel = math.floor(fuel)               -- (the column holds whole litres)
    -- With pfm-fuel keeping levels on the server (fuel sync on), the client's level is saved only
    -- up to the server's level for this car (it may be lower: the server lowers it no faster than
    -- driving burns). With no car in the world whose server level was given for this plate (it was
    -- deleted, the event came for a parked car, or the car showing the plate is another one) the
    -- client can only lower the stored level: the next spawn starts from it, so a modded client
    -- could otherwise park any car with a full tank. pfm-fuel stopped or not syncing: the
    -- client's level, as before.
    local onlyLower = false
    if GetResourceState('pfm-fuel') == 'started' then
        local ok, synced, level = pcall(function()
            if not exports['pfm-fuel']:IsFuelSynced() then return false end
            local veh = PFGarages.FindVehicle(plate)
            return true, veh and exports['pfm-fuel']:GetVehicleFuel(veh, plate) or nil
        end)
        level = ok and synced and tonumber(level) or nil
        if level then
            fuel = math.min(fuel, math.max(0, math.floor(level)))
        else
            -- (pfm-fuel failing counts as syncing: the stored level is the safe side)
            onlyLower = not ok or synced == true
        end
    end
    engine = clampNumber(engine, 0, 1000, 1000)
    body = clampNumber(body, 0, 1000, 1000)
    if onlyLower then
        MySQL.update('UPDATE player_vehicles SET fuel = LEAST(COALESCE(fuel, ?), ?), engine = ?, body = ? WHERE plate = ? AND citizenid = ?', { fuel, fuel, engine, body, plate, Player.PlayerData.citizenid })
    else
        MySQL.update('UPDATE player_vehicles SET fuel = ?, engine = ?, body = ? WHERE plate = ? AND citizenid = ?', { fuel, engine, body, plate, Player.PlayerData.citizenid })
    end
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
        -- a car this resource tracks (out, or being parked) is not replaced by another one
        if type(vehicleNetID) ~= 'number' or isOutside(plate) then return end
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

-- A deleted character's cars are gone (pfm-core deletes player_vehicles); so are their paid releases.
AddEventHandler('pfm-core:server:characterDeleted', function(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' or #citizenid > 50 then return end
    for plate, owner in pairs(paidRelease) do
        if owner == citizenid then paidRelease[plate] = nil end
    end
    if PFGarages.dbReady then
        MySQL.query.await('DELETE FROM pfm_garage_depot_releases WHERE citizenid = ?', { citizenid })
    end
end)
