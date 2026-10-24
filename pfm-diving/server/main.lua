local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions' })
local sharedItems = exports['pfm-core']:GetShared('Items')
local currentDivingArea = math.random(1, #Config.CoralLocations)
local LastPickup = {}

-- Functions

local function getItemPrice(amount, price)
    for k, v in pairs(Config.BonusTiers) do
        local modifier = #Config.BonusTiers == k and amount >= v.minAmount or amount >= v.minAmount and amount <= v.maxAmount
        if modifier then
            local percent = math.random(v.minBonus, v.maxBonus) / 100
            local bonus = price * percent
            price = price + bonus
            price = math.ceil(price)
        end
    end
    return price
end

local function hasCoral(src)
    local Player = exports['pfm-core']:GetPlayer(src)
    local availableCorals = {}
    for _, v in pairs(Config.CoralTypes) do
        local item = Player.GetItemByName(v.item)
        if item then availableCorals[#availableCorals + 1] = v end
    end
    if not next(availableCorals) then return nil end
    return availableCorals
end

-- Rolls the configured rarity table; falls back to the default random coral when disabled or no roll hits
local function rollReward()
    local rt = Config.RarityTable
    if rt and rt.enabled and rt.finds then
        for _, find in ipairs(rt.finds) do
            if math.random(100) <= (find.chance or 0) then
                local minA = (find.amount and find.amount.min) or 1
                local maxA = (find.amount and find.amount.max) or minA
                return find.item, math.random(minA, maxA)
            end
        end
    end
    local coralType = math.random(1, #Config.CoralTypes)
    local amount = math.random(1, Config.CoralTypes[coralType].maxAmount)
    return Config.CoralTypes[coralType].item, amount
end

-- Events

RegisterNetEvent('qb-diving:server:CallCops', function(coords)
    for _, Player in pairs(QBCore.Functions.GetQBPlayers()) do
        if Player then
            if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
                local msg = Lang:t('info.cop_msg')
                TriggerClientEvent('qb-diving:client:CallCops', Player.PlayerData.source, coords, msg)
                local alertData = {
                    title = Lang:t('info.cop_title'),
                    coords = coords,
                    description = msg
                }
                TriggerClientEvent('qb-phone:client:addPoliceAlert', -1, alertData)
            end
        end
    end
end)

RegisterNetEvent('qb-diving:server:SellCorals', function()
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    local availableCorals = hasCoral(src)
    if availableCorals then
        for _, v in pairs(availableCorals) do
            local item = Player.GetItemByName(v.item)
            local price = item.amount * v.price
            local reward = getItemPrice(item.amount, price)
            exports['pfm-inventory']:RemoveItem(src, item.name, item.amount, false, 'qb-diving:server:SellCorals')
            Player.AddMoney('cash', reward, 'qb-diving:server:SellCorals')
            TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems[item.name], 'remove')
        end
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.no_coral'), 'error')
    end
end)

RegisterNetEvent('qb-diving:server:TakeCoral', function(area, coral, _)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end

    -- Validate the claimed coral against server state
    if area ~= currentDivingArea then return end
    local areaData = Config.CoralLocations[area]
    if not areaData then return end
    local coralData = areaData.coords.Coral[coral]
    if not coralData or coralData.PickedUp then return end

    -- Server-side proximity check to the coral itself
    local pCoords = GetEntityCoords(GetPlayerPed(src))
    if #(pCoords - coralData.coords) > 10.0 then return end

    -- Per-player pickup cooldown (collecting takes at least ~2s client-side)
    local now = os.time()
    if LastPickup[src] and (now - LastPickup[src]) < (Config.PickupCooldown or 2) then return end
    LastPickup[src] = now

    local rewardItem, amount = rollReward()
    local ItemData = sharedItems[rewardItem]
    if not ItemData then return end

    if amount > 1 then
        for _ = 1, amount, 1 do
            exports['pfm-inventory']:AddItem(src, ItemData['name'], 1, false, false, 'qb-diving:server:TakeCoral')
            TriggerClientEvent('qb-inventory:client:ItemBox', src, ItemData, 'add')
            Wait(250)
        end
    else
        exports['pfm-inventory']:AddItem(src, ItemData['name'], amount, false, false, 'qb-diving:server:TakeCoral')
        TriggerClientEvent('qb-inventory:client:ItemBox', src, ItemData, 'add')
    end

    if (Config.CoralLocations[area].TotalCoral - 1) == 0 then
        for _, v in pairs(Config.CoralLocations[currentDivingArea].coords.Coral) do
            v.PickedUp = false
        end

        Config.CoralLocations[currentDivingArea].TotalCoral = Config.CoralLocations[currentDivingArea].DefaultCoral
        local newLocation = math.random(1, #Config.CoralLocations)
        while newLocation == currentDivingArea do
            Wait(0)
            newLocation = math.random(1, #Config.CoralLocations)
        end
        currentDivingArea = newLocation
        TriggerClientEvent('qb-diving:client:NewLocations', -1)
    else
        Config.CoralLocations[area].coords.Coral[coral].PickedUp = true
        Config.CoralLocations[area].TotalCoral = Config.CoralLocations[area].TotalCoral - 1
    end
    TriggerClientEvent('qb-diving:client:UpdateCoral', -1, area, coral, true)
end)

AddEventHandler('playerDropped', function()
    LastPickup[source] = nil
end)

RegisterNetEvent('qb-diving:server:removeItemAfterFill', function()
    local src = source
    exports['pfm-inventory']:RemoveItem(src, 'diving_fill', 1, false, 'qb-diving:server:removeItemAfterFill')
    TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems['diving_fill'], 'remove')
end)

-- Callbacks

QBCore.Functions.CreateCallback('qb-diving:server:GetDivingConfig', function(_, cb)
    cb(Config.CoralLocations, currentDivingArea)
end)

-- Items

QBCore.Functions.CreateUseableItem('diving_gear', function(source)
    TriggerClientEvent('qb-diving:client:UseGear', source)
end)

QBCore.Functions.CreateUseableItem('diving_fill', function(source)
    TriggerClientEvent('qb-diving:client:SetOxygenLevel', source)
end)
