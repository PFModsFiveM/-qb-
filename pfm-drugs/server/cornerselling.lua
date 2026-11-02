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

-- Corner sales whose pay the bank had not settled: [citizenid] = { { key, price, item, amount } }.
-- The drugs stay sold and the pay is asked again under the same key until the ledger settles it;
-- only a clear failure hands the drugs back (an unclear one may still be paid by the ledger's recovery).
local PendingSales = {}
local SALE_RETRY_MS, SALE_RETRIES = 30000, 20

local function payCornerSale(src, sale, retry)
    local ok, res = PFPayout.Pay(src, 'cash', sale.price, { key = sale.key, reason = 'qb-drugs:server:sellCornerDrugs', kind = 'sale', quiet = true })
    if ok then return 'paid' end
    -- on a retry a bank that does not answer says nothing about the key that came back unclear
    if retry and (res.error == 'bank_unavailable' or res.error == 'ledger_unavailable') then return 'pending' end
    if PFPayout.IsClearFailure(res) then return 'failed' end
    return 'pending'
end

-- Asks again for every waiting sale of src's character; a failed one gives the drugs back.
local function settleCornerSales(src)
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    local cid = Player.PlayerData.citizenid
    local list = PendingSales[cid]
    if not list then return end
    local keep = {}
    for _, sale in ipairs(list) do
        local res = payCornerSale(src, sale, true)
        if res == 'failed' then
            exports['pfm-inventory']:AddItem(src, sale.item, sale.amount, false, false, 'qb-drugs:corner-refund')
            TriggerClientEvent('QBCore:Notify', src, 'A buyer\'s payment did not go through. You got the product back.', 'error')
        elseif res == 'pending' then
            keep[#keep + 1] = sale
        end
    end
    PendingSales[cid] = #keep > 0 and keep or nil
end

local function retryCornerSales(src, cid, left)
    SetTimeout(SALE_RETRY_MS, function()
        local P = exports['pfm-core']:GetPlayer(src)
        if not P or P.PlayerData.citizenid ~= cid or not PendingSales[cid] then return end
        settleCornerSales(src)
        if PendingSales[cid] and left > 1 then retryCornerSales(src, cid, left - 1) end
    end)
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
    settleCornerSales(src)
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
        -- paid through the bank ledger: a clear failure (the bank down, a refusal) hands the drugs
        -- back; an unclear one keeps the sale and asks again under the same key
        local cid = Player.PlayerData.citizenid
        local sale = { key = ('pfm-drugs:corner:%s:%s'):format(cid, PFPayout.NewId()), price = price, item = item, amount = amount }
        local res = payCornerSale(src, sale)
        if res == 'failed' then
            exports['pfm-inventory']:AddItem(src, item, amount, false, false, 'qb-drugs:corner-refund')
            TriggerClientEvent('QBCore:Notify', src, 'The buyer\'s money did not come through. You kept the product.', 'error')
            return
        end
        local netId = tonumber(customerNetId)
        if netId then servedCustomers[netId] = os.time() end
        if res == 'pending' then
            PendingSales[cid] = PendingSales[cid] or {}
            table.insert(PendingSales[cid], sale)
            retryCornerSales(src, cid, SALE_RETRIES)
            TriggerClientEvent('QBCore:Notify', src, 'The buyer\'s payment is still being settled.', 'primary')
        else
            TriggerClientEvent('QBCore:Notify', src, Lang:t('success.offer_accepted'), 'success')
        end
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
