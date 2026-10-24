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

AddEventHandler('playerDropped', function()
    refuelCooldowns[source] = nil
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

    if Player.PlayerData.money[Config.MoneyType] >= finalPrice then
        local paid = Player.RemoveMoney(Config.MoneyType, finalPrice, 'refuel-vehicle')
        if paid and taxRate > 0 then
            CollectFuelTax(subtotal, Player.PlayerData.citizenid)
        end
        cb(paid)
    else
        cb(false)
    end
end)

RegisterServerEvent('qb-fuel:server:buyJerryCan', function()
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end

    if Player.RemoveMoney(Config.MoneyType, Config.JerryCanCost, 'buy-jerry-can') then
        Player.AddItem('weapon_petrolcan', 1, nil, { fuel = Config.JerryCanLitre, ammo = Config.JerryCanLitre })
    end
end)

RegisterServerEvent('qb-fuel:server:refillJerryCan', function()
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end

    local jerryCan = Player.GetItemByName('weapon_petrolcan')
    if not jerryCan then return Player.Notify(Lang:t('error.no_jerrycan'), 'error') end

    if Player.RemoveMoney(Config.MoneyType, Config.JerryCanRefillCost, 'refill-jerry-can') then
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
