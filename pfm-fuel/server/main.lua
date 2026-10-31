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
-- writes (sv_stateBagStrictMode). Clients report a level and the server checks who is asking:
-- any client used to be able to set any car's fuel.
local FUEL_REACH = 10.0         -- metres: refuelling from outside the car (pump, jerry can)
local SYNC_WINDOW_MS, SYNC_MAX = 10000, 20
local syncRate = {}             -- [src] = { start, count }

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

--- Who may set this car's shared fuel level to `level` (0-100):
---  * its driver, or the client simulating an empty car (network owner): any level, as fuel use
---    is simulated by that client;
---  * anyone standing beside it: only a higher level (refuelling), or the first level a newly
---    spawned car gets.
local function canSetVehicleFuel(src, veh, level)
    local ped = GetPlayerPed(src)
    local driver = GetPedInVehicleSeat(veh, -1)
    if ped and ped ~= 0 and driver == ped then return true end
    local empty = not driver or driver == 0
    if empty and NetworkGetEntityOwner(veh) == src then return true end
    if distanceToVehicle(src, veh) > FUEL_REACH then return false end
    local current = tonumber(Entity(veh).state['qb-fuel'])
    return current == nil or level >= current
end

RegisterNetEvent('qb-fuel:server:syncFuel', function(netId, level)
    local src = source
    if not Config.SyncFuelBetweenPlayers then return end
    level = tonumber(level)
    if not level or level ~= level or level == math.huge or level == -math.huge then return end
    level = math.floor(math.max(0.0, math.min(100.0, level)) * 100 + 0.5) / 100
    if not syncRateOk(src) then return end
    local veh = vehicleFromNetId(netId)
    if not veh or not canSetVehicleFuel(src, veh, level) then return end
    Entity(veh).state:set('qb-fuel', level + 0.0, true)
end)

AddEventHandler('playerDropped', function()
    local src = source
    refuelCooldowns[src] = nil
    syncRate[src] = nil
end)

-- ====================|| EVENTS || ==================== --

QBCore.Functions.CreateCallback('qb-fuel:server:refillVehicle', function(src, cb, litres)
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

RegisterServerEvent('qb-fuel:server:setCanFuel', function(fuel)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end

    local jerryCan = Player.GetItemByName('weapon_petrolcan')
    if not jerryCan then return Player.Notify(Lang:t('error.no_jerrycan'), 'error') end

    -- Pouring can only lower the can's contents; clamp within 0..capacity
    fuel = tonumber(fuel)
    if not fuel then return end
    local currentFuel = tonumber(jerryCan.info and jerryCan.info.fuel) or 0
    fuel = math.max(0, math.min(math.floor(fuel), currentFuel, Config.JerryCanLitre))

    jerryCan.info.fuel = fuel
    jerryCan.info.ammo = fuel
    Player.RemoveItem('weapon_petrolcan', 1, jerryCan.slot)
    Player.AddItem('weapon_petrolcan', 1, nil, jerryCan.info)
end)
