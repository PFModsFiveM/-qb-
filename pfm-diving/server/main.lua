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

-- A diver taking coral may tip off the police. The alert is placed where the diver really is, only
-- at the current dive area, at most once a minute per diver, and the phone alert goes to the officers
-- only. (It used to send any client-chosen spot to every player, once per officer on duty.)
local CallCopsCooldown = {}
local CALL_COPS_SECONDS = 60
local CALL_COPS_RANGE = 100.0

local function nearCurrentDiveArea(pos)
    local areaData = Config.CoralLocations[currentDivingArea]
    if not areaData then return false end
    for _, c in pairs(areaData.coords.Coral) do
        if #(pos - c.coords) <= CALL_COPS_RANGE then return true end
    end
    return false
end

RegisterNetEvent('qb-diving:server:CallCops', function()
    local src = source
    if not exports['pfm-core']:GetPlayer(src) then return end
    local now = os.time()
    if CallCopsCooldown[src] and now - CallCopsCooldown[src] < CALL_COPS_SECONDS then return end
    local pos = GetEntityCoords(GetPlayerPed(src))
    if not nearCurrentDiveArea(pos) then return end
    CallCopsCooldown[src] = now
    local coords = vector3(pos.x, pos.y, pos.z)
    local msg = Lang:t('info.cop_msg')
    for _, Player in pairs(QBCore.Functions.GetQBPlayers()) do
        if Player and Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
            TriggerClientEvent('qb-diving:client:CallCops', Player.PlayerData.source, coords, msg)
            TriggerClientEvent('qb-phone:client:addPoliceAlert', Player.PlayerData.source, {
                title = Lang:t('info.cop_title'),
                coords = coords,
                description = msg
            })
        end
    end
end)

RegisterNetEvent('qb-diving:server:SellCorals', function()
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    -- sold only at a coral buyer (it used to work from anywhere), and paid only for what was removed
    local pCoords = GetEntityCoords(GetPlayerPed(src))
    local atBuyer = false
    for _, loc in pairs(Config.SellLocations) do
        if #(pCoords - loc.coords.xyz) <= 5.0 then atBuyer = true break end
    end
    if not atBuyer then return end
    local availableCorals = hasCoral(src)
    if availableCorals then
        local saleId = PFPayout.NewId()
        for _, v in pairs(availableCorals) do
            local item = Player.GetItemByName(v.item)
            local price = item.amount * v.price
            local reward = getItemPrice(item.amount, price)
            if not exports['pfm-inventory']:RemoveItem(src, item.name, item.amount, false, 'qb-diving:server:SellCorals') then
                return
            end
            -- paid through the bank ledger; if the bank is down the coral is handed back
            local key = ('pfm-diving:coral:%s:%s:%s'):format(Player.PlayerData.citizenid, saleId, item.name)
            if not PFPayout.Pay(Player, 'cash', reward, { key = key, reason = 'qb-diving:server:SellCorals', kind = 'sale' }) then
                exports['pfm-inventory']:AddItem(src, item.name, item.amount, false, item.info, 'qb-diving:sale-refund')
                return
            end
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

    -- Claim the coral before handing anything out: the grant loop below waits between items, and a
    -- second request for the same coral used to get past the PickedUp check meanwhile.
    coralData.PickedUp = true
    areaData.TotalCoral = areaData.TotalCoral - 1
    TriggerClientEvent('qb-diving:client:UpdateCoral', -1, area, coral, true)

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

    -- the last coral of the area moves the dive to a new area (once: only the request that took it)
    if areaData.TotalCoral <= 0 and area == currentDivingArea then
        for _, v in pairs(areaData.coords.Coral) do
            v.PickedUp = false
        end

        areaData.TotalCoral = areaData.DefaultCoral
        local newLocation = math.random(1, #Config.CoralLocations)
        while newLocation == currentDivingArea and #Config.CoralLocations > 1 do
            Wait(0)
            newLocation = math.random(1, #Config.CoralLocations)
        end
        currentDivingArea = newLocation
        TriggerClientEvent('qb-diving:client:NewLocations', -1)
    end
end)

AddEventHandler('playerDropped', function()
    LastPickup[source] = nil
    CallCopsCooldown[source] = nil
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
