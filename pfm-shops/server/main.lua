local Bail = {}

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

-- Functions

local function usesStock(shop)
    local loc = Config.Locations[shop]
    return loc and (loc.useStock or Config.DynamicStock) or false
end

local function checkTable(inputValue, requiredValue)
    if type(inputValue) == 'table' and type(requiredValue) == 'table' then
        for _, v in ipairs(requiredValue) do
            if inputValue[v] then return true end
        end
    elseif type(requiredValue) == 'table' then
        for _, v in ipairs(requiredValue) do
            if v == inputValue then return true end
        end
    elseif type(inputValue) == 'string' and type(requiredValue) == 'string' then
        return inputValue == requiredValue
    elseif type(inputValue) == 'table' and type(requiredValue) == 'string' then
        return inputValue[requiredValue] == true
    elseif type(inputValue) == 'string' and type(requiredValue) == 'table' then
        for _, v in ipairs(requiredValue) do
            if v == inputValue then return true end
        end
    end

    return false
end

local function saveShopInv(shop, products)
    -- merge with existing file instead of overwriting it, so multiple stock shops persist
    local shopinv = json.decode(LoadResourceFile(GetCurrentResourceName(), Config.ShopsInvJsonFile) or '{}') or {}
    shopinv[shop] = {}
    shopinv[shop].products = products
    SaveResourceFile(GetCurrentResourceName(), Config.ShopsInvJsonFile, json.encode(shopinv), -1)
end

-- Deliveries counted by the server for each driver's payslip: [citizenid] = { id, drops }
DeliveryRounds = {}

local function deliveryPay(source, shop)
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player then return end
    local playerPed = GetPlayerPed(source)
    local playerCoords = GetEntityCoords(playerPed)
    local deliverCoords = Config.Locations[shop].delivery
    local distance = #(playerCoords - vector3(deliverCoords.x, deliverCoords.y, deliverCoords.z))
    if distance > 10 then return end
    local key = ('pfm-shops:delivery:%s:%s'):format(Player.PlayerData.citizenid, PFPayout.NewId())
    if not PFPayout.Pay(Player, 'bank', Config.DeliveryPrice, { key = key, reason = 'qb-shops:deliveryPay' }) then return false end
    -- counted for the round's payslip (the payslip used to take the drop count from the client)
    local cid = Player.PlayerData.citizenid
    DeliveryRounds[cid] = DeliveryRounds[cid] or { id = PFPayout.NewId(), drops = 0 }
    DeliveryRounds[cid].drops = DeliveryRounds[cid].drops + 1
    if math.random(100) <= 10 then exports['pfm-inventory']:AddItem(source, Config.RewardItem, 1, false, false, 'qb-shops:deliveryPay') end
end

-- Events

-- Deliveries

RegisterNetEvent('qb-shops:server:RestockShopItems', function(shop)
    local src = source
    if not shop then return end
    if not Config.Locations[shop] then return end
    if onCooldown(src, 'restock', 30000) then return end -- a delivery run takes far longer than 30s
    local deliverCoords = Config.Locations[shop].delivery
    if not deliverCoords then return end
    if #(GetEntityCoords(GetPlayerPed(src)) - vector3(deliverCoords.x, deliverCoords.y, deliverCoords.z)) > 10 then return end
    deliveryPay(src, shop)
    if not usesStock(shop) then return end
    local randAmount = math.random(10, 50)
    for k in pairs(Config.Locations[shop].products) do Config.Locations[shop].products[k].amount += randAmount end
    saveShopInv(shop, Config.Locations[shop].products)
    TriggerClientEvent('qb-shops:client:SetShopItems', -1, shop, Config.Locations[shop].products)
end)

RegisterNetEvent('qb-shops:server:UpdateShopItems', function(shop, itemData, amount) -- called from inventory
    if not shop or type(itemData) ~= 'table' or not amount then return end
    if not Config.Locations[shop] then return end
    if not usesStock(shop) then return end
    amount = math.floor(tonumber(amount) or 0)
    if amount < 1 then return end
    if not Config.Locations[shop].products[itemData.slot] then return end
    Config.Locations[shop].products[itemData.slot].amount -= amount
    if Config.Locations[shop].products[itemData.slot].amount < 0 then
        Config.Locations[shop].products[itemData.slot].amount = 0
    end
    saveShopInv(shop, Config.Locations[shop].products)
    TriggerClientEvent('qb-shops:client:SetShopItems', -1, shop, Config.Locations[shop].products)
end)

RegisterNetEvent('qb-shops:server:DoBail', function(bool)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if onCooldown(src, 'bail', 5000) then return end
    if bool then
        if Bail[Player.PlayerData.citizenid] then return end -- one truck at a time
        -- the deposit goes through the bank ledger; its refund uses the same bail id
        local bailId = PFPayout.NewId()
        local paidFrom = PFPayout.Charge(Player, { 'cash', 'bank' }, Config.TruckDeposit,
            { key = ('pfm-shops:bail:%s'):format(bailId), reason = 'tow-received-bail' })
        if paidFrom then
            Bail[Player.PlayerData.citizenid] = { amount = Config.TruckDeposit, id = bailId }
            TriggerClientEvent('QBCore:Notify', src, Lang:t(paidFrom == 'cash' and 'success.paid_with_cash' or 'success.paid_with_bank', { value = Config.TruckDeposit }), 'success')
            TriggerClientEvent('qb-shops:client:SpawnVehicle', src)
        else
            TriggerClientEvent('QBCore:Notify', src, Lang:t('error.no_deposit', { value = Config.TruckDeposit }), 'error')
        end
    else
        local bail = Bail[Player.PlayerData.citizenid]
        if bail then
            if not PFPayout.Pay(Player, 'cash', bail.amount, { key = ('pfm-shops:bail:%s:refund'):format(bail.id), reason = 'trucker-bail-paid', kind = 'refund' }) then return end
            Bail[Player.PlayerData.citizenid] = nil
            TriggerClientEvent('QBCore:Notify', src, Lang:t('success.refund_to_cash', { value = Config.TruckDeposit }), 'success')
        end
    end
end)

RegisterNetEvent('qb-shops:server:PaySlip', function(drops)
    local src = source
    local playerPed = GetPlayerPed(src)
    local playerCoords = GetEntityCoords(playerPed)
    local coords = Config.DeliveryLocations['main'].coords
    local distance = #(playerCoords - vector3(coords.x, coords.y, coords.z))
    if distance > 10 then return end
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if onCooldown(src, 'payslip', 60000) then return end -- a delivery round takes minutes
    -- only drops the server counted in deliveryPay are paid; the client's number can only lower it
    local round = DeliveryRounds[Player.PlayerData.citizenid]
    if not round or round.drops < 1 then return end
    local completedDrops = math.min(round.drops, math.floor(tonumber(drops) or round.drops), Config.MaxDeliveries)
    if completedDrops < 1 then return end
    local payment = Config.DeliveryPrice * completedDrops
    if not PFPayout.Pay(Player, 'bank', payment, { key = ('pfm-shops:payslip:%s'):format(round.id), reason = 'trucker-salary' }) then return end
    DeliveryRounds[Player.PlayerData.citizenid] = nil
    Player.AddRep('delivery', completedDrops)
    TriggerClientEvent('QBCore:Notify', src, Lang:t('success.you_earned', { value = payment }), 'success')
end)

-- Opening shops

RegisterNetEvent('qb-shops:server:openShop', function(data)
    local src = source
    if type(data) ~= 'table' then return end
    local shopName = data.shop
    local shopData = Config.Locations[shopName]
    if not shopData then return end
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if #(GetEntityCoords(GetPlayerPed(src)) - vector3(shopData.coords.x, shopData.coords.y, shopData.coords.z)) > 10.0 then return end
    local playerData = Player.PlayerData
    local products = shopData.products
    local items = {}

    if usesStock(shopName) then
        local shopInvJson = json.decode(LoadResourceFile(GetCurrentResourceName(), Config.ShopsInvJsonFile) or '{}') or {}
        if shopInvJson[shopName] then
            for k, v in pairs(shopInvJson[shopName].products) do
                if products[k] then
                    products[k].amount = v.amount
                end
            end
        end
    end

    for i = 1, #products do
        local curProduct = products[i]
        local addProduct = true

        if curProduct.requiredGrade and playerData.job.grade.level < curProduct.requiredGrade then
            addProduct = false
        end

        if addProduct and curProduct.requiredJob and not checkTable(playerData.job.name, curProduct.requiredJob) then
            addProduct = false
        end

        if addProduct and curProduct.requiredGang and not checkTable(playerData.gang.name, curProduct.requiredGang) then
            addProduct = false
        end

        if addProduct and curProduct.requiredLicense and not checkTable(playerData.metadata['licences'], curProduct.requiredLicense) then
            addProduct = false
        end

        if addProduct then
            curProduct.slot = #items + 1
            items[#items + 1] = curProduct
        end
    end

    exports['pfm-inventory']:CreateShop({
        name = shopName,
        label = shopData.label,
        slots = shopData.slots,
        coords = shopData.coords,
        items = items,
    })
    exports['pfm-inventory']:OpenShop(src, shopName)
end)

-- Dynamic stock: periodic restock up to the amounts configured at startup
if Config.DynamicStock then
    local maxStock = {} -- [productsTable][slot] = configured amount at startup
    for _, loc in pairs(Config.Locations) do
        if loc.products and not maxStock[loc.products] then
            local caps = {}
            for slot, product in pairs(loc.products) do
                caps[slot] = product.amount
            end
            maxStock[loc.products] = caps
        end
    end

    CreateThread(function()
        local interval = math.max(1, tonumber(Config.RestockInterval) or 30)
        while true do
            Wait(interval * 60000)
            local restocked = {} -- product tables are shared between shops; restock each table once
            for shopName, loc in pairs(Config.Locations) do
                if loc.products then
                    if not restocked[loc.products] then
                        restocked[loc.products] = true
                        local caps = maxStock[loc.products]
                        for slot, product in pairs(loc.products) do
                            local cap = caps and caps[slot] or product.amount
                            if product.amount < cap then
                                product.amount = math.min(product.amount + Config.RestockAmount, cap)
                            end
                        end
                    end
                    saveShopInv(shopName, loc.products)
                    TriggerClientEvent('qb-shops:client:SetShopItems', -1, shopName, loc.products)
                end
            end
        end
    end)
end
