-- ====================|| VARIABLES || ==================== --

QBCore = exports['pfm-core']:GetCoreObject({ 'Functions' })

local refuelCooldowns = {} -- per-source cooldown for refuel transactions

local function IsOnRefuelCooldown(src)
    local cooldown = Config.RefuelCooldown or 2000
    if cooldown <= 0 then return false end
    local now = GetGameTimer()
    local last = refuelCooldowns[src]
    if last and (now - last) < cooldown then return true end
    refuelCooldowns[src] = now
    return false
end

-- ====================|| SHARED VEHICLE STATE || ==================== --
-- The fuel level other players see ('qb-fuel' on the vehicle) is a state bag only the server
-- writes (sv_stateBagStrictMode). A car's first level comes from the server: what its owner's
-- record stored (player_vehicles.fuel), else Config.DefaultFuel. After that only the car's driver
-- reports its level, and a report can only lower it, by no more than driving can burn in the time
-- since the last accepted level. Raises come only from the server's own refuel paths (a paid pump
-- refill, a jerry can the player owns) and from server code through the SetVehicleFuel export.
-- (Any client once could set any car's fuel; then the network owner of any empty car could, from
-- any distance, so a modded client near parked cars could drain them all; then a car with no level
-- took its driver's first report, so a modded driver could fill any car it had just got into.)
local FUEL_REACH = 10.0         -- metres: refuelling from outside the car (pump, jerry can)
local SYNC_WINDOW_MS, SYNC_MAX = 10000, 20
local syncRate = {}             -- [src] = { start, count }
local lastLevelAt = {}          -- [vehicle entity] = GetGameTimer() of the last level written

-- most fuel (0-100 scale) driving can burn per second (Config.MaxFuelBurnPerSecond)
local function maxBurnPerSecond()
    local v = tonumber(Config.MaxFuelBurnPerSecond)
    if not v or v ~= v or v <= 0 then return 0.5 end
    return v
end
-- the burn allowance stops growing after this long without a write, so a car parked for an hour
-- cannot be emptied by one report (the driver's client reports every Config.FuelSyncTime seconds
-- while the engine runs)
local function maxBurnWindowMs() return math.max(30, 3 * (tonumber(Config.FuelSyncTime) or 10)) * 1000.0 end

local function syncRateOk(src)
    local now = GetGameTimer()
    local r = syncRate[src]
    if not r or now - r.start >= SYNC_WINDOW_MS then
        r = { start = now, count = 0 }
        syncRate[src] = r
    end
    r.count = r.count + 1
    return r.count <= SYNC_MAX
end

local function vehicleFromNetId(netId)
    netId = tonumber(netId)
    if not netId or netId ~= math.floor(netId) or netId <= 0 then return nil end
    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return nil end
    if GetEntityType(veh) ~= 2 then return nil end
    return veh
end

local function distanceToVehicle(src, veh)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return math.huge end
    return #(GetEntityCoords(ped) - GetEntityCoords(veh))
end

local function roundLevel(level)
    return math.floor(math.max(0.0, math.min(100.0, level)) * 100 + 0.5) / 100
end

local function finiteNumber(v)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge then return nil end
    return v
end

local function sharedLevel(veh)
    return finiteNumber(Entity(veh).state['qb-fuel'])
end

local function writeVehicleFuel(veh, level)
    lastLevelAt[veh] = GetGameTimer()
    Entity(veh).state:set('qb-fuel', level + 0.0, true)
end

-- One server change per car at a time when it waits on the database: the first-level lookup and
-- the refuels (the pump works out how much fits before the payment, so a second refuel landing in
-- that wait would make the first pay for fuel that no longer fits).
local carBusy = {} -- [vehicle entity] = 'lookup' (its first level is being looked up) or 'refuel'

--- Runs fn(...) holding locks[id] (set to `kind`); false when it is already held.
local function withLock(locks, id, kind, fn, ...)
    if locks[id] then return false end
    locks[id] = kind
    local results = table.pack(pcall(fn, ...))
    locks[id] = nil
    if not results[1] then error(results[2], 0) end
    return true, table.unpack(results, 2, results.n)
end

--- Runs fn(...) holding `veh`'s lock; false when another change holds it.
local function withCarLock(veh, kind, fn, ...) return withLock(carBusy, veh, kind, fn, ...) end

-- ====================|| FIRST LEVEL || ==================== --
-- A plate set on its owner's client (a car spawned on the server and given its plate there) reaches
-- the server a moment later: an unknown plate is looked up once more after this long.
local PLATE_SETTLE_MS = 2000
-- a refuel landing while the first level is looked up waits this long for it (the settle wait plus
-- the database) instead of being told someone else is refuelling
local LOOKUP_WAIT_MS, LOOKUP_POLL_MS = PLATE_SETTLE_MS + 3000, 100

local function waitForLookup(veh)
    local waited = 0
    while carBusy[veh] == 'lookup' and waited < LOOKUP_WAIT_MS do
        Wait(LOOKUP_POLL_MS)
        waited = waited + LOOKUP_POLL_MS
    end
end

-- Which owned car a level belongs to. A car's own plate is what its owner's client shows, so it can
-- be changed: server code that spawns an owned car names its row (UseStoredFuel), and each first
-- level remembers the plate it was given for. pfm-garages saves a parked car's fuel only up to the
-- level of a car whose level was given for that car's plate (GetVehicleFuel(veh, plate)).
local namedPlate = {}  -- [vehicle entity] = the plate of the owned row server code spawned it as
local levelPlate = {}  -- [vehicle entity] = the plate (upper case) its level was given for

--- `text` trimmed (the database keeps plates trimmed), or nil when empty or longer than a plate.
local function cleanPlate(text)
    if type(text) ~= 'string' then return nil end
    text = text:gsub('^%s+', ''):gsub('%s+$', '')
    if text == '' or #text > 8 then return nil end
    return text
end

--- The plate the server sees on `veh`, trimmed, or nil.
local function serverPlate(veh) return cleanPlate(GetVehicleNumberPlateText(veh)) end

--- The level stored for the owned car with this plate (when it was last parked), or nil; the
--- second value is true when the database could not be read.
local function storedFuel(plate)
    if not plate then return nil, false end
    local ok, value = pcall(MySQL.scalar.await, 'SELECT fuel FROM player_vehicles WHERE plate = ? LIMIT 1', { plate })
    if not ok then return nil, true end
    return finiteNumber(value), false
end

-- the first level of a car nobody stored a level for (Config.DefaultFuel: a new, job, rented or
-- stolen car)
local function defaultFuel()
    local v = finiteNumber(Config.DefaultFuel)
    if not v then return 100.0 end
    return roundLevel(v)
end

--- The car's shared level, giving it its first one when it has none. Call it holding the car's
--- lock: the lookup waits on the database. nil when fuel sync is off, the car is gone or the
--- database could not be read (the car then stays without a level and the next report or refuel
--- looks again: a failed read must not hand out Config.DefaultFuel).
local function ensureLevel(veh)
    local current = sharedLevel(veh)
    if current or not Config.SyncFuelBetweenPlayers then return current end
    -- the row server code named (the plate it set reaches the server only through the owner's
    -- client, which could show another), else the plate the server sees
    local named = namedPlate[veh]
    local plate = named or serverPlate(veh)
    local level, failed = storedFuel(plate)
    if failed then return nil end
    if level == nil and not named then
        Wait(PLATE_SETTLE_MS)
        if not DoesEntityExist(veh) then return nil end
        local now = namedPlate[veh] or serverPlate(veh)
        if now and now ~= plate then
            plate = now
            level, failed = storedFuel(now)
            if failed then return nil end
        end
    end
    if not DoesEntityExist(veh) then return nil end
    -- server code (SetVehicleFuel) may have set it during the wait: that value stands
    current = sharedLevel(veh)
    if current then return current end
    level = level ~= nil and roundLevel(level) or defaultFuel()
    levelPlate[veh] = plate and plate:upper() or nil
    writeVehicleFuel(veh, level)
    return level
end

local function isDriver(src, veh)
    local ped = GetPlayerPed(src)
    return ped ~= nil and ped ~= 0 and GetPedInVehicleSeat(veh, -1) == ped
end

--- The level a report of `level` (0-100) from the driver leaves this car at, or nil to change
--- nothing: it only goes down, by at most what driving burns in the time since the last level
--- written.
local function acceptedDriverLevel(veh, level)
    local current = sharedLevel(veh)
    if current == nil or level >= current then return nil end
    local window = maxBurnWindowMs()
    local last = lastLevelAt[veh]
    local elapsed = last and math.min(GetGameTimer() - last, window) or window
    local allowed = maxBurnPerSecond() * math.max(elapsed, 0) / 1000.0
    if allowed <= 0 then return nil end
    return roundLevel(math.max(level, current - allowed))
end

RegisterNetEvent('qb-fuel:server:syncFuel', function(netId, level)
    local src = source
    if not Config.SyncFuelBetweenPlayers then return end
    level = finiteNumber(level)
    if not level then return end
    level = roundLevel(level)
    if not syncRateOk(src) then return end
    local veh = vehicleFromNetId(netId)
    if not veh or not isDriver(src, veh) then return end
    if sharedLevel(veh) == nil then
        -- the server gives a new car its first level; this report is not taken as it (a report
        -- landing while the lookup runs finds the car busy and is dropped)
        withCarLock(veh, 'lookup', ensureLevel, veh)
        return
    end
    local accepted = acceptedDriverLevel(veh, level)
    if accepted and accepted ~= sharedLevel(veh) then writeVehicleFuel(veh, accepted) end
end)

--- The car (by network id) a refuel by `src` goes into: it must exist and be within reach.
local function refuelTarget(src, netId)
    local veh = vehicleFromNetId(netId)
    if not veh or distanceToVehicle(src, veh) > FUEL_REACH then return nil end
    return veh
end

--- The server's refuel paths raise the shared level by `litres` (already paid for at the pump, or
--- poured from the player's own jerry can), under the car's lock after ensureLevel. Returns the
--- new level, or nil when fuel sync is off (or the car has no level: it was gone).
local function addVehicleFuel(veh, litres)
    if not Config.SyncFuelBetweenPlayers or not veh then return nil end
    local current = sharedLevel(veh)
    if current == nil or litres <= 0 then return current end
    local level = roundLevel(current + litres)
    writeVehicleFuel(veh, level)
    return level
end

-- Server code (a garage or job spawning a car) sets a car's level directly: the first value a new
-- car gets, or any change the server itself decided. `vehicle` is a server entity handle (what
-- CreateVehicleServerSetter returns; NetworkGetEntityFromNetworkId for a network id).
local function serverVehicle(vehicle)
    vehicle = tonumber(vehicle)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) or GetEntityType(vehicle) ~= 2 then return nil end
    return vehicle
end

exports('SetVehicleFuel', function(vehicle, level)
    local veh = serverVehicle(vehicle)
    level = finiteNumber(level)
    if not veh or not level then return false end
    local plate = namedPlate[veh] or serverPlate(veh)
    levelPlate[veh] = plate and plate:upper() or nil
    writeVehicleFuel(veh, roundLevel(level))
    return true
end)

-- Server code that spawns an owned car names the row it is (`plate` as player_vehicles keeps it):
-- the car's first level is what that row stored, whatever plate the car shows later. A garage
-- calls it right after it creates the car and sets the plate.
exports('UseStoredFuel', function(vehicle, plate)
    local veh = serverVehicle(vehicle)
    plate = cleanPlate(plate)
    if not veh or not plate then return false end
    namedPlate[veh] = plate
    if Config.SyncFuelBetweenPlayers and sharedLevel(veh) == nil then
        -- looked up now, before the owner's client could show the server another plate
        CreateThread(function() withCarLock(veh, 'lookup', ensureLevel, veh) end)
    end
    return true
end)

-- The car's shared level, or nil. With `plate`: only when the level was given for the car with
-- that plate (a car showing another car's plate does not answer for it).
exports('GetVehicleFuel', function(vehicle, plate)
    local veh = serverVehicle(vehicle)
    if not veh then return nil end
    if plate ~= nil then
        plate = cleanPlate(plate)
        if not plate or levelPlate[veh] ~= plate:upper() then return nil end
    end
    return sharedLevel(veh)
end)

-- Whether this server keeps fuel levels (Config.SyncFuelBetweenPlayers); when not, the client's
-- level is all there is.
exports('IsFuelSynced', function() return Config.SyncFuelBetweenPlayers == true end)

AddEventHandler('entityRemoved', function(entity)
    lastLevelAt[entity] = nil
    namedPlate[entity] = nil
    levelPlate[entity] = nil
end)

-- After a restart of this resource the cars already out keep their levels (state bags): the plates
-- they show now are taken as the plates those levels were given for.
for _, veh in ipairs(GetAllVehicles and GetAllVehicles() or {}) do
    local plate = sharedLevel(veh) and serverPlate(veh)
    if plate then levelPlate[veh] = plate:upper() end
end

AddEventHandler('playerDropped', function()
    local src = source
    refuelCooldowns[src] = nil
    syncRate[src] = nil
end)

-- ====================|| PURCHASES || ==================== --
-- Every sale is one ledger charge under its own key. A charge whose outcome the bank did not know
-- yet (result.unclear: pending, debited, interrupted) is never charged again under a new key: it is
-- kept, and this player's next purchase of the same kind first asks the bank again under that
-- charge's own key and amount, and hands over what it paid for once it went through. A paid sale
-- whose goods cannot be handed over is refunded under the charge's key plus ':refund'; a refund
-- the bank did not take is kept the same way and paid before that player's next purchase of the
-- kind. (Kept in memory: a restart forgets them, and the ledger's recovery settles the charges.)
local unsettled = {}  -- [citizenid .. ':' .. kind] = a charge { key, amount, ... } or a refund owed
local purchasing = {} -- [citizenid] = true while one of this player's purchases runs

local function notify(Player, key)
    TriggerClientEvent('QBCore:Notify', Player.PlayerData.source, Lang:t(key), 'error')
end

--- Pays `charge` back to `account`; false when the bank did not take it (then kept as owed).
local function refund(Player, kind, account, charge)
    local slot = Player.PlayerData.citizenid .. ':' .. kind
    local ok = PFPayout.Pay(Player, account, charge.amount, { key = charge.key .. ':refund', kind = 'refund', reason = 'Fuel refund', quiet = true })
    unsettled[slot] = not ok and { refund = true, account = account, key = charge.key, amount = charge.amount } or nil
    return ok == true
end

--- Charges this player for a purchase of `kind`. Returns the account paid from (false when not
--- paid), the ledger result and the charge: this player's unsettled one of this kind (its own key,
--- amount and fields) or a new one (key from `keyPrefix`, `amount`, the fields of `extra`).
local function chargeOnce(Player, kind, keyPrefix, amount, reason, extra)
    local cid = Player.PlayerData.citizenid
    local charge = unsettled[cid .. ':' .. kind]
    if charge and charge.refund then
        if not refund(Player, kind, charge.account, charge) then
            return false, { ok = false, error = 'refund_unpaid' }, nil
        end
        charge = nil
    end
    if not charge then
        charge = extra or {}
        charge.key = ('%s:%s:%s'):format(keyPrefix, cid, PFPayout.NewId())
        charge.amount = amount
    end
    local account, res = PFPayout.Charge(Player, Config.MoneyType, charge.amount, { key = charge.key, kind = 'purchase', reason = reason })
    unsettled[cid .. ':' .. kind] = (not account and type(res) == 'table' and res.unclear == true) and charge or nil
    return account, res, charge
end

--- Why a charge was not paid: nil for not enough money (the caller says so), else 'payment', with
--- the player told why when the payout module did not tell them (it tells about a bank that is
--- not running and a charge it could not settle, not about a clear refusal).
local function paymentRefused(Player, res)
    if type(res) ~= 'table' then return nil end
    if res.error == 'refund_unpaid' then
        notify(Player, 'error.refund_pending')
        return 'payment'
    end
    local told = res.unclear ~= nil or res.error == 'bank_unavailable' or res.error == 'ledger_unavailable'
    if told then return 'payment' end
    if res.error == 'insufficient_funds' then return nil end
    notify(Player, 'error.payment_declined')
    return 'payment'
end

--- Runs fn(...) as this player's only purchase in progress; false when another one runs.
local function asOnlyPurchase(Player, fn, ...)
    return withLock(purchasing, Player.PlayerData.citizenid, true, fn, ...)
end

--- A paid refill goes into `veh` (all its litres: the room was checked before the charge) and its
--- tax to the city. When the car is gone or the litres no longer fit (a refill the bank only now
--- confirms, or a car removed during the payment), it is refunded instead: nothing poured, no tax.
local function pourPaidRefill(Player, veh, account, charge)
    local exists = DoesEntityExist(veh)
    local current = exists and sharedLevel(veh) or nil
    local gone = not exists or (Config.SyncFuelBetweenPlayers and current == nil)
    if gone or (current and current + charge.litres > 100.0) then
        notify(Player, refund(Player, 'pump', account, charge) and 'error.refunded' or 'error.refund_pending')
        return false, current or false, 'payment'
    end
    local level = addVehicleFuel(veh, charge.litres)
    if (charge.taxRate or 0) > 0 then
        CollectFuelTax(charge.subtotal, Player.PlayerData.citizenid, charge.amount - charge.subtotal, charge.key)
    end
    return true, level
end

--- Pays for and pours a pump refill (runs under the car's lock); returns paid, level, reason.
local function pumpRefill(src, Player, veh, litres, stationIndex)
    -- Clamp to tank capacity and to the room left in the tank; price always computed from config,
    -- never trusted from the client. A car with no level yet gets its first one here, so only what
    -- the server knows fits is charged.
    local maxLitres = Config.MaxTankLitres or 100
    litres = math.min(math.floor(litres), maxLitres)
    local current = ensureLevel(veh)
    -- (no level: the car is gone, or its first level could not be read; nothing is charged)
    if Config.SyncFuelBetweenPlayers and current == nil then return false, false, 'no_vehicle' end
    if distanceToVehicle(src, veh) > FUEL_REACH then return false, current or false, 'no_vehicle' end
    if current then litres = math.min(litres, math.floor(100 - current)) end
    if litres <= 0 then return false, current, current and 'full' or nil end

    -- station-local price (dynamic pricing) + city sales tax, both resolved server-side
    local perLitre = GetStationFuelPrice and GetStationFuelPrice(stationIndex) or Config.FuelPrice
    local subtotal = math.floor(litres * perLitre * 100 + 0.5) / 100
    local taxRate = GetFuelTaxRate and GetFuelTaxRate() or 0
    local finalPrice = math.floor(subtotal * (1 + taxRate) + 0.5)
    if finalPrice <= 0 then return false end

    -- paid through the pfm-banking ledger (a refill the bank had not settled goes first, with its
    -- own litres and price); the tax inside the price goes to pf-government by its exact amount
    -- under the same key
    local account, res, charge = chargeOnce(Player, 'pump', 'pfm-fuel:refuel', finalPrice, 'Fuel',
        { litres = litres, subtotal = subtotal, taxRate = taxRate })
    if not account then return false, current or false, paymentRefused(Player, res) end
    return pourPaidRefill(Player, veh, account, charge)
end

--- The pump refill under the player's purchase lock, then the car's lock.
local function pumpForPlayer(src, Player, veh, litres, stationIndex)
    -- a car whose first level is being looked up is waited for, not reported busy
    waitForLookup(veh)
    return withCarLock(veh, 'refuel', pumpRefill, src, Player, veh, litres, stationIndex)
end

--- A pump refill of `litres` into the car with network id `netId` (the one the nozzle is in).
--- Answers (paid, newLevel, reason): newLevel is the car's shared level after the refill (false on
--- a failure; nil only with fuel sync off); reason is 'no_station' (the player is not at a fuel
--- station), 'full' (nothing fits), 'busy' (someone else is refuelling it), 'no_vehicle' (no
--- such car beside the player) or 'payment' (the bank did not take it, or an earlier refill was
--- settled or refunded instead; the player was told); nil when the player has not enough money.
QBCore.Functions.CreateCallback('qb-fuel:server:refillVehicle', function(src, cb, litres, netId)
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return cb(false) end
    if IsOnRefuelCooldown(src) then return cb(false) end
    litres = finiteNumber(litres)
    if not litres or litres <= 0 then return cb(false) end
    -- (no nil before a reason: an event's argument list must not have holes)
    -- the server cannot see pump props: a pump sells only at a station it knows (pricing.lua)
    local atStation, stationIndex = StationForPlayer(src)
    if not atStation then return cb(false, false, 'no_station') end
    -- the fuel goes into a real car beside the player, so it is paid for only if that car is there
    local veh = refuelTarget(src, netId)
    if not veh then return cb(false, false, 'no_vehicle') end
    local onlyOne, free, paid, level, reason = asOnlyPurchase(Player, pumpForPlayer, src, Player, veh, litres, stationIndex)
    if not onlyOne or not free then return cb(false, sharedLevel(veh) or false, 'busy') end
    if paid then return cb(true, level) end
    cb(false, level or false, reason)
end)

-- Buying or filling a can happens at a pump, so only at a station the server knows (a can filled
-- anywhere would be a pump anywhere). Pouring a can into a car works anywhere.
local function buyJerryCan(Player)
    local account, res = chargeOnce(Player, 'jerrycan', 'pfm-fuel:jerrycan', Config.JerryCanCost, 'Jerry can')
    if not account then
        if not paymentRefused(Player, res) then notify(Player, 'error.no_money') end
        return
    end
    Player.AddItem('weapon_petrolcan', 1, nil, { fuel = Config.JerryCanLitre, ammo = Config.JerryCanLitre })
end

RegisterServerEvent('qb-fuel:server:buyJerryCan', function()
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if not StationForPlayer(src) then return Player.Notify(Lang:t('error.no_station'), 'error') end
    asOnlyPurchase(Player, buyJerryCan, Player)
end)

local function refillJerryCan(Player)
    local jerryCan = Player.GetItemByName('weapon_petrolcan')
    if not jerryCan then return Player.Notify(Lang:t('error.no_jerrycan'), 'error') end
    local account, res = chargeOnce(Player, 'canrefill', 'pfm-fuel:refill', Config.JerryCanRefillCost, 'Jerry can refill')
    if not account then
        if not paymentRefused(Player, res) then notify(Player, 'error.no_money') end
        return
    end
    jerryCan.info.fuel = Config.JerryCanLitre
    jerryCan.info.ammo = Config.JerryCanLitre
    Player.RemoveItem('weapon_petrolcan', 1, jerryCan.slot)
    Player.AddItem('weapon_petrolcan', 1, nil, jerryCan.info)
end

RegisterServerEvent('qb-fuel:server:refillJerryCan', function()
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if not StationForPlayer(src) then return Player.Notify(Lang:t('error.no_station'), 'error') end
    asOnlyPurchase(Player, refillJerryCan, Player)
end)

-- `netId` is the car being filled from the can (within reach). What leaves the can (it can only
-- go down) goes into the car, up to the room the server knows is left; the rest stays in the can.
local pouring = {} -- [src] = true while a can update runs (the inventory calls can yield)

--- Under the car's lock: pours from the player's can down to `fuel` litres.
local function pourIntoCar(src, veh, fuel)
    local level = ensureLevel(veh)
    if Config.SyncFuelBetweenPlayers and level == nil then return end -- gone, or the read failed
    if distanceToVehicle(src, veh) > FUEL_REACH then return end
    -- the can is read after the lookup's wait, right before the swap, so a can moved or swapped
    -- during that wait is not what gets rewritten
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    local jerryCan = Player.GetItemByName('weapon_petrolcan')
    if not jerryCan then return Player.Notify(Lang:t('error.no_jerrycan'), 'error') end
    local currentFuel = math.min(tonumber(jerryCan.info and jerryCan.info.fuel) or 0, Config.JerryCanLitre)
    local poured = currentFuel - math.max(0, math.min(fuel, currentFuel))
    if poured <= 0 then return end
    if level then poured = math.min(poured, math.floor(100 - level)) end
    if poured <= 0 then return Player.Notify(Lang:t('error.vehicle_full'), 'error') end
    -- a copy: the inventory's own item table stays as it was if the swap below fails
    local info = {}
    for k, v in pairs(jerryCan.info or {}) do info[k] = v end
    info.fuel, info.ammo = currentFuel - poured, currentFuel - poured
    if Player.RemoveItem('weapon_petrolcan', 1, jerryCan.slot) == false then return end
    Player.AddItem('weapon_petrolcan', 1, nil, info)
    addVehicleFuel(veh, poured)
end

local function pourCan(src, fuel, netId)
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if not Player.GetItemByName('weapon_petrolcan') then return Player.Notify(Lang:t('error.no_jerrycan'), 'error') end

    -- Pouring can only lower the can's contents (clamped to 0..capacity when the can is read)
    fuel = finiteNumber(fuel)
    if not fuel then return end
    -- the can is emptied only into a car beside the player
    local veh = refuelTarget(src, netId)
    if not veh then return end

    waitForLookup(veh)
    local free = withCarLock(veh, 'refuel', pourIntoCar, src, veh, math.floor(fuel))
    if not free then Player.Notify(Lang:t('error.vehicle_busy'), 'error') end
end

RegisterServerEvent('qb-fuel:server:setCanFuel', function(fuel, netId)
    local src = source
    if pouring[src] then return end
    pouring[src] = true
    local ok, err = pcall(pourCan, src, fuel, netId)
    pouring[src] = nil
    if not ok then error(err, 0) end
end)
