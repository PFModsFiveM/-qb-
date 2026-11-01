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
-- writes (sv_stateBagStrictMode). Only the car's driver reports its level, and a report can only
-- lower it, by no more than driving can burn in the time since the last accepted level. Raises
-- come from the server's own refuel paths (a paid pump refill, a jerry can the player owns).
-- (Any client once could set any car's fuel; then the network owner of any empty car could, from
-- any distance, so a modded client near parked cars could drain them all.)
local FUEL_REACH = 10.0         -- metres: refuelling from outside the car (pump, jerry can)
local SYNC_WINDOW_MS, SYNC_MAX = 10000, 20
local syncRate = {}             -- [src] = { start, count }
local lastLevelAt = {}          -- [vehicle entity] = GetGameTimer() of the last level written

-- most fuel (0-100 scale) driving can burn per second: generous, as handling files differ; a
-- legitimate drop above it is still applied, over the next reports
local function maxBurnPerSecond() return tonumber(Config.MaxFuelBurnPerSecond) or 0.5 end
-- the burn allowance stops growing after this long without a report (the driver's client reports
-- every Config.FuelSyncTime seconds while the engine runs)
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

local function writeVehicleFuel(veh, level)
    lastLevelAt[veh] = GetGameTimer()
    Entity(veh).state:set('qb-fuel', level + 0.0, true)
end

--- The level a report of `level` (0-100) from `src` leaves this car at, or nil to change nothing.
--- Only the driver reports. A car with no shared level yet takes the driver's (a car just taken
--- out of a garage or spawned for a job); otherwise the level only goes down, by at most what
--- driving burns in the time since the last level written.
local function acceptedDriverLevel(src, veh, level)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 or GetPedInVehicleSeat(veh, -1) ~= ped then return nil end
    local current = tonumber(Entity(veh).state['qb-fuel'])
    if current == nil then return level end
    if level >= current then return nil end
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
    if not veh then return end
    local accepted = acceptedDriverLevel(src, veh, level)
    if accepted and accepted ~= tonumber(Entity(veh).state['qb-fuel']) then writeVehicleFuel(veh, accepted) end
end)

--- The server's refuel paths raise the shared level: `litres` already paid for at the pump, or
--- poured from the player's own jerry can, go into the car beside the player. `clientLevel` is
--- only used for a car that has no shared level yet.
local function addVehicleFuel(src, netId, litres, clientLevel)
    if not Config.SyncFuelBetweenPlayers then return end
    litres = finiteNumber(litres)
    if not litres or litres <= 0 then return end
    local veh = vehicleFromNetId(netId)
    if not veh or distanceToVehicle(src, veh) > FUEL_REACH then return end
    local current = tonumber(Entity(veh).state['qb-fuel'])
    if current == nil then current = roundLevel(finiteNumber(clientLevel) or 0) end
    writeVehicleFuel(veh, roundLevel(current + litres))
end

AddEventHandler('entityRemoved', function(entity)
    lastLevelAt[entity] = nil
end)

AddEventHandler('playerDropped', function()
    local src = source
    refuelCooldowns[src] = nil
    syncRate[src] = nil
end)

-- ====================|| EVENTS || ==================== --

-- `netId` is the car the nozzle is in; `clientLevel` its level, used only if it has no shared one
QBCore.Functions.CreateCallback('qb-fuel:server:refillVehicle', function(src, cb, litres, netId, clientLevel)
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if IsOnRefuelCooldown(src) then
        cb(false)
        return
    end
    litres = tonumber(litres)
    if not litres or litres <= 0 then
        cb(false)
        return
    end
    -- Clamp to tank capacity; price always computed from config, never trusted from the client
    local maxLitres = Config.MaxTankLitres or 100
    litres = math.min(math.floor(litres), maxLitres)
    if litres <= 0 then
        cb(false)
        return
    end

    -- station-local price (dynamic pricing) + city sales tax, both resolved server-side
    local coords = GetEntityCoords(GetPlayerPed(src))
    local stationIndex = GetStationIndexForCoords and GetStationIndexForCoords(coords) or nil
    local perLitre = GetStationFuelPrice and GetStationFuelPrice(stationIndex) or Config.FuelPrice
    local subtotal = math.floor(litres * perLitre * 100 + 0.5) / 100
    local taxRate = GetFuelTaxRate and GetFuelTaxRate() or 0
    local finalPrice = math.floor(subtotal * (1 + taxRate) + 0.5)

    -- paid through the pfm-banking ledger; the tax inside the price goes to pf-government by its
    -- exact amount under the same key
    local key = ('pfm-fuel:refuel:%s:%s'):format(Player.PlayerData.citizenid, PFPayout.NewId())
    local paid = finalPrice > 0 and PFPayout.Charge(Player, Config.MoneyType, finalPrice, { key = key, kind = 'purchase', reason = 'Fuel' }) and true or false
    if paid and taxRate > 0 then
        CollectFuelTax(subtotal, Player.PlayerData.citizenid, finalPrice - subtotal, key)
    end
    if paid then addVehicleFuel(src, netId, litres, clientLevel) end
    cb(paid)
end)

RegisterServerEvent('qb-fuel:server:buyJerryCan', function()
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end

    if PFPayout.Charge(Player, Config.MoneyType, Config.JerryCanCost, { key = ('pfm-fuel:jerrycan:%s:%s'):format(Player.PlayerData.citizenid, PFPayout.NewId()), kind = 'purchase', reason = 'Jerry can' }) then
        Player.AddItem('weapon_petrolcan', 1, nil, { fuel = Config.JerryCanLitre, ammo = Config.JerryCanLitre })
    end
end)

RegisterServerEvent('qb-fuel:server:refillJerryCan', function()
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end

    local jerryCan = Player.GetItemByName('weapon_petrolcan')
    if not jerryCan then return Player.Notify(Lang:t('error.no_jerrycan'), 'error') end

    if PFPayout.Charge(Player, Config.MoneyType, Config.JerryCanRefillCost, { key = ('pfm-fuel:refill:%s:%s'):format(Player.PlayerData.citizenid, PFPayout.NewId()), kind = 'purchase', reason = 'Jerry can refill' }) then
        jerryCan.info.fuel = Config.JerryCanLitre
        jerryCan.info.ammo = Config.JerryCanLitre
        Player.RemoveItem('weapon_petrolcan', 1, jerryCan.slot)
        Player.AddItem('weapon_petrolcan', 1, nil, jerryCan.info)
    end
end)

-- `netId` is the car being filled from the can; `vehLevel` its level, used only if it has no
-- shared one. What leaves the can (it can only go down) is what goes into the car.
local pouring = {} -- [src] = true while a can update runs (the inventory calls can yield)
local function pourCan(src, fuel, netId, vehLevel)
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end

    local jerryCan = Player.GetItemByName('weapon_petrolcan')
    if not jerryCan then return Player.Notify(Lang:t('error.no_jerrycan'), 'error') end

    -- Pouring can only lower the can's contents; clamp within 0..capacity
    fuel = finiteNumber(fuel)
    if not fuel then return end
    local currentFuel = math.min(tonumber(jerryCan.info and jerryCan.info.fuel) or 0, Config.JerryCanLitre)
    fuel = math.max(0, math.min(math.floor(fuel), currentFuel))
    local poured = currentFuel - fuel

    jerryCan.info.fuel = fuel
    jerryCan.info.ammo = fuel
    if Player.RemoveItem('weapon_petrolcan', 1, jerryCan.slot) == false then return end
    Player.AddItem('weapon_petrolcan', 1, nil, jerryCan.info)
    if poured > 0 and netId ~= nil then addVehicleFuel(src, netId, poured, vehLevel) end
end

RegisterServerEvent('qb-fuel:server:setCanFuel', function(fuel, netId, vehLevel)
    local src = source
    if pouring[src] then return end
    pouring[src] = true
    local ok, err = pcall(pourCan, src, fuel, netId, vehLevel)
    pouring[src] = nil
    if not ok then error(err, 0) end
end)
