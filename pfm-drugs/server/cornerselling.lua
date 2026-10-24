local StolenDrugs = {}

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

-- Customers who already bought: [netId] = os.time(). A ped buys once (for a while), so one ped
-- cannot be sold to over and over.
local servedCustomers = {}
local CUSTOMER_MEMORY = 30 * 60

-- Validate the client-reported customer ped: it must exist server-side, be an NPC (not the seller or
-- another player) and be near the seller
local function validCustomer(src, customerNetId)
    if not Config.ValidateCustomerPed then return true end
    local netId = tonumber(customerNetId)
    if not netId or netId == 0 then return false end
    local pedEntity = NetworkGetEntityFromNetworkId(netId)
    if not pedEntity or pedEntity == 0 or not DoesEntityExist(pedEntity) then return false end
    if pedEntity == GetPlayerPed(src) or (IsPedAPlayer and IsPedAPlayer(pedEntity)) then return false end
    local served = servedCustomers[netId]
    if served and os.time() - served < CUSTOMER_MEMORY then return false end
    local dist = #(GetEntityCoords(GetPlayerPed(src)) - GetEntityCoords(pedEntity))
    return dist <= (Config.MaxCustomerDistance or 10.0)
end

local function getAvailableDrugs(source)
    local AvailableDrugs = {}
    local Player = exports['pfm-core']:GetPlayer(source)

    if not Player then return nil end

    for k in pairs(Config.DrugsPrice) do
        local item = Player.GetItemByName(k)

        if item then
            AvailableDrugs[#AvailableDrugs + 1] = {
                item = item.name,
                amount = item.amount,
                label = sharedItems[item.name]['label']
            }
        end
    end
    return table.type(AvailableDrugs) ~= 'empty' and AvailableDrugs or nil
end

QBCore.Functions.CreateCallback('qb-drugs:server:cornerselling:getAvailableDrugs', function(source, cb)
    cb(getAvailableDrugs(source))
end)

RegisterNetEvent('qb-drugs:server:giveStealItems', function(drugType, amount)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if onCooldown(src, 'stealPickup', 2000) then return end
    for k, v in pairs(StolenDrugs) do
        -- only the robbed player can recover their own stash
        if drugType == v.item and amount == v.amount and v.owner == Player.PlayerData.citizenid then
            exports['pfm-inventory']:AddItem(src, drugType, amount, false, false, 'qb-drugs:server:giveStealItems')
            table.remove(StolenDrugs, k)
            break
        end
    end
end)

RegisterNetEvent('qb-drugs:server:sellCornerDrugs', function(drugType, amount, price, customerNetId)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    local availableDrugs = getAvailableDrugs(src)
    if not availableDrugs or not Player then return end
    -- the whole sale flow (approach + progressbar) takes well over 5s client-side
    if onCooldown(src, 'cornerSell', 5000) then return end
    local entry = availableDrugs[tonumber(drugType) or 0]
    if not entry then return end
    local item = entry.item
    amount = math.floor(tonumber(amount) or 0)
    if amount < 1 or amount > 15 then return end -- client never offers more than 15 bags
    if not validCustomer(src, customerNetId) then return end
    if QBCore.Functions.GetDutyCount('police') < (Config.MinimumDrugSalePolice or 0) then return end
    local ddata = Config.DrugsPrice[item]
    if not ddata then return end
    -- the client's offer can only lower the price; the server rolls what this customer pays
    local offered = math.floor(tonumber(price) or 0)
    if offered < 1 then return end
    price = math.min(offered, math.random(ddata.min or 1, ddata.max) * amount)
    local hasItem = Player.GetItemByName(item)
    if hasItem and hasItem.amount >= amount then
        if not exports['pfm-inventory']:RemoveItem(src, item, amount, false, 'qb-drugs:server:sellCornerDrugs') then return end
        local netId = tonumber(customerNetId)
        if netId then servedCustomers[netId] = os.time() end
        TriggerClientEvent('QBCore:Notify', src, Lang:t('success.offer_accepted'), 'success')
        Player.AddMoney('cash', price, 'qb-drugs:server:sellCornerDrugs')
        TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems[item], 'remove')
        TriggerClientEvent('qb-drugs:client:refreshAvailableDrugs', src, getAvailableDrugs(src))
        -- optional server-side police alert; can't be skipped by a modified client
        if (Config.ServerPoliceCallChance or 0) > 0 and math.random(1, 100) <= Config.ServerPoliceCallChance then
            TriggerEvent('police:server:policeAlert', 'Drug sale in progress') -- source is preserved through same-side TriggerEvent
        end
    else
        TriggerClientEvent('qb-drugs:client:cornerselling', src)
    end
end)

RegisterNetEvent('qb-drugs:server:robCornerDrugs', function(drugType, amount)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    local availableDrugs = getAvailableDrugs(src)
    if not availableDrugs or not Player then return end
    if onCooldown(src, 'cornerRob', 5000) then return end
    local entry = availableDrugs[tonumber(drugType) or 0]
    if not entry then return end
    local item = entry.item
    amount = math.floor(tonumber(amount) or 0)
    if amount < 1 or amount > 15 then return end
    if not exports['pfm-inventory']:RemoveItem(src, item, amount, false, 'qb-drugs:server:robCornerDrugs') then return end
    table.insert(StolenDrugs, { item = item, amount = amount, owner = Player.PlayerData.citizenid })
    TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems[item], 'remove')
    TriggerClientEvent('qb-drugs:client:refreshAvailableDrugs', src, getAvailableDrugs(src))
end)
