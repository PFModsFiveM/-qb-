local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions' })
local sharedItems = exports['pfm-core']:GetShared('Items')
local pendingMelts = {} -- [citizenid] = { item, amount, readyAt } (server-authoritative melt timer)

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

local function isNearPawnshop(src)
    local playerCoords = GetEntityCoords(GetPlayerPed(src))
    for _, value in pairs(Config.PawnLocation) do
        if #(playerCoords - value.coords) <= 5.0 then return true end
    end
    return false
end

-- Server-authoritative pawn price (never trust the client-sent price)
local function getPawnPrice(itemName)
    for _, v in pairs(Config.PawnItems) do
        if v.item == itemName then
            local price = v.price
            if Config.FluctuatingPrices then
                -- deterministic daily variance: same multiplier for everyone all day
                local seed = tonumber(os.date('%Y%m%d')) or 0
                for i = 1, #itemName do seed = seed + string.byte(itemName, i) * i end
                local range = Config.FluctuationRange or 0.15
                local multiplier = 1.0 - range + ((seed * 2654435761) % 1000) / 1000 * range * 2
                price = math.max(1, math.floor(price * multiplier))
            end
            return price
        end
    end
    return nil
end

local function getMeltConfig(itemName)
    for _, v in pairs(Config.MeltingItems) do
        if v.item == itemName then return v end
    end
    return nil
end

local function exploitBan(id, reason)
    MySQL.insert('INSERT INTO bans (name, license, discord, ip, reason, expire, bannedby) VALUES (?, ?, ?, ?, ?, ?, ?)',
        {
            GetPlayerName(id),
            QBCore.Functions.GetIdentifier(id, 'license'),
            QBCore.Functions.GetIdentifier(id, 'discord'),
            QBCore.Functions.GetIdentifier(id, 'ip'),
            reason,
            2147483647,
            'qb-pawnshop'
        })
    TriggerEvent('qb-log:server:CreateLog', 'pawnshop', 'Player Banned', 'red',
        string.format('%s was banned by %s for %s', GetPlayerName(id), 'qb-pawnshop', reason), true)
    DropPlayer(id, 'You were permanently banned by the server for: Exploiting')
end

RegisterNetEvent('qb-pawnshop:server:sellPawnItems', function(itemName, itemAmount, itemPrice)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if onCooldown(src, 'sellPawn', 1500) then return end
    if not isNearPawnshop(src) then
        exploitBan(src, 'sellPawnItems Exploiting')
        return
    end
    -- recompute the price server-side; the client-sent itemPrice is ignored
    local unitPrice = getPawnPrice(itemName)
    if not unitPrice then return end -- item is not pawnable
    itemAmount = math.floor(tonumber(itemAmount) or 0)
    if itemAmount < 1 or itemAmount > 1000 then return end
    local totalPrice = itemAmount * unitPrice
    if exports['pfm-inventory']:RemoveItem(src, itemName, tonumber(itemAmount), false, 'qb-pawnshop:server:sellPawnItems') then
        if Config.BankMoney then
            Player.AddMoney('bank', totalPrice, 'qb-pawnshop:server:sellPawnItems')
        else
            Player.AddMoney('cash', totalPrice, 'qb-pawnshop:server:sellPawnItems')
        end
        TriggerClientEvent('QBCore:Notify', src, Lang:t('success.sold', { value = tonumber(itemAmount), value2 = sharedItems[itemName].label, value3 = totalPrice }), 'success')
        TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems[itemName], 'remove')
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.no_items'), 'error')
    end
    TriggerClientEvent('qb-pawnshop:client:openMenu', src)
end)

RegisterNetEvent('qb-pawnshop:server:meltItemRemove', function(itemName, itemAmount, item)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if onCooldown(src, 'melt', 1500) then return end
    if not isNearPawnshop(src) then return end
    -- only melt items listed in config; client-sent melt time/rewards are ignored
    local meltCfg = getMeltConfig(itemName)
    if not meltCfg then return end
    itemAmount = math.floor(tonumber(itemAmount) or 0)
    if itemAmount < 1 or itemAmount > 1000 then return end
    local cid = Player.PlayerData.citizenid
    -- one melt at a time; an unclaimed melt can be replaced (forfeited) 2h after it finished,
    -- so a relog mid-melt can't lock the player out forever
    if pendingMelts[cid] and os.time() < pendingMelts[cid].readyAt + 7200 then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.no_items'), 'error')
        return
    end
    if exports['pfm-inventory']:RemoveItem(src, itemName, itemAmount, false, 'qb-pawnshop:server:meltItemRemove') then
        TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems[itemName], 'remove')
        local meltTime = (itemAmount * meltCfg.meltTime)
        -- server-authoritative pickup timer; the client timer is cosmetic
        pendingMelts[cid] = { item = itemName, amount = itemAmount, readyAt = os.time() + math.floor(meltTime * 60) }
        TriggerClientEvent('qb-pawnshop:client:startMelting', src, item, itemAmount, (meltTime * 60000 / 1000))
        TriggerClientEvent('QBCore:Notify', src, Lang:t('info.melt_wait', { value = meltTime }), 'primary')
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.no_items'), 'error')
    end
end)

RegisterNetEvent('qb-pawnshop:server:pickupMelted', function(item)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if onCooldown(src, 'pickupMelt', 1500) then return end
    if not isNearPawnshop(src) then
        exploitBan(src, 'pickupMelted Exploiting')
        return
    end
    -- rewards come from the server-side melt ledger + config, never from the client-sent table
    local cid = Player.PlayerData.citizenid
    local melt = pendingMelts[cid]
    if not melt then return end
    if os.time() < melt.readyAt then return end -- melt not finished yet
    local meltCfg = getMeltConfig(melt.item)
    if not meltCfg then
        pendingMelts[cid] = nil
        return
    end
    pendingMelts[cid] = nil
    for _, m in pairs(meltCfg.rewards) do
        local rewardAmount = melt.amount * m.amount
        if exports['pfm-inventory']:AddItem(src, m.item, rewardAmount, false, false, 'qb-pawnshop:server:pickupMelted') then
            TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems[m.item], 'add')
            TriggerClientEvent('QBCore:Notify', src, Lang:t('success.items_received', { value = rewardAmount, value2 = sharedItems[m.item].label }), 'success')
            TriggerClientEvent('qb-pawnshop:client:resetPickup', src)
        else
            TriggerClientEvent('QBCore:Notify', src, Lang:t('error.inventory_full', { value = sharedItems[m.item].label }), 'warning', 7500)
        end
    end
    TriggerClientEvent('qb-pawnshop:client:openMenu', src)
end)

QBCore.Functions.CreateCallback('qb-pawnshop:server:getInv', function(source, cb)
    local Player = exports['pfm-core']:GetPlayer(source)
    local inventory = Player.PlayerData.items
    return cb(inventory)
end)
