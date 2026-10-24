local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions' })
local sharedItems = exports['pfm-core']:GetShared('Items')

local Recieve = {
    { item = 'metalscrap', min = 1, max = 5 },
    { item = 'plastic',    min = 1, max = 5 },
    { item = 'copper',     min = 1, max = 5 },
    { item = 'rubber',     min = 1, max = 5 },
    { item = 'iron',       min = 1, max = 5 },
    { item = 'aluminum',   min = 1, max = 5 },
    { item = 'steel',      min = 1, max = 5 },
    { item = 'glass',      min = 1, max = 5 },
}
local luckyItem = 'cryptostick' -- Item to be given as a lucky item
local maxRecieved = 5           -- Max items to be received
local dropLocation = Config.DropLocation
local LuckyItemChance = 20      -- 20% chance to get a lucky item
local uhohs = {}
local Sales, Stock, salesLoc = {}, {}, Config.SellPed

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
-- Packages being carried: [src] = time picked up. A hand-in needs one (it used to need only standing
-- at the drop point, so the reward event could be fired every 5 seconds without working).
local carrying = {}
local PICKUP_RANGE = 4.0
local MIN_CARRY_SECONDS = 4      -- the walk plus the unpacking bar take longer than this
local MAX_CARRY_SECONDS = 600

AddEventHandler('playerDropped', function()
    eventCooldowns[source] = nil
    carrying[source] = nil
end)

RegisterNetEvent('qb-recyclejob:server:pickupPackage', function(index)
    local src = source
    if not exports['pfm-core']:GetPlayer(src) then return end
    local spot = Config.PickupLocations[tonumber(index) or 0]
    if not spot or carrying[src] then return end
    local coords = GetEntityCoords(GetPlayerPed(src))
    if #(coords - vector3(spot.loc.x, spot.loc.y, spot.loc.z)) > PICKUP_RANGE then return end
    carrying[src] = os.time()
end)


if Config.SellMaterials then
    Sales = { -- key is item, value is price
        metalscrap = 2,
        plastic = 2,
        copper = 2,
        rubber = 2,
        iron = 2,
        aluminum = 2,
        steel = 2,
        glass = 2,
    }
end
if Config.LimitedMaterials then
    Stock = { -- key is item, value is stock at restart
        metalscrap = 3000,
        plastic = 3000,
        copper = 3000,
        rubber = 3000,
        iron = 3000,
        aluminum = 3000,
        steel = 3000,
        glass = 3000,
    }
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
            'qb-recyclejob'
        })
    TriggerEvent('qb-log:server:CreateLog', 'recyclejob', 'Player Banned', 'red',
        string.format('%s was banned by %s for %s', GetPlayerName(id), 'qb-recyclejob', reason), true)
    DropPlayer(id, 'You were permanently banned by the server for: Exploiting')
end

local function isClose(source, loc)
    local playerPed = GetPlayerPed(source)
    local Player = exports['pfm-core']:GetPlayer(source)
    local cid = Player.PlayerData.citizenid
    local playerCoords = GetEntityCoords(playerPed)
    local distance = nil

    if loc == 'turnIn' then
        distance = #(playerCoords - vector3(dropLocation.x, dropLocation.y, dropLocation.z))
    elseif loc == 'sell' then
        distance = #(playerCoords - vector3(salesLoc.x, salesLoc.y, salesLoc.z))
    else
        return false
    end

    if distance < 5.0 then
        return true
    else
        uhohs[cid] = (uhohs[cid] or 0) + 1 -- was `uhohs[cid] + 1 or 0`, which errored on first offense
        if uhohs[cid] >= 3 then
            exploitBan(source, 'Exploiting distance on qb-recyclejob')
        end
        return false
    end
end

QBCore.Functions.CreateCallback('qb-recyclejob:server:getPriceList', function(source, cb)
    local src = source
    if not isClose(src, 'sell') then return cb({}) end
    cb(Sales)
end)

local function adjustStock(item, change, amount)
    if not Config.LimitedMaterials then return end
    if change == 'add' then
        Stock[item] = Stock[item] + amount
    elseif change == 'remove' then
        Stock[item] = Stock[item] - amount
    end
end

local function checkStock(source, item, amount)
    if not Config.LimitedMaterials then return true end
    if Stock[item] >= amount then
        return true
    else
        TriggerClientEvent('QBCore:Notify', source, Lang:t('error.out_of_stock', { item = item }), 'error')
        return false
    end
end

local function sellMaterials(src, item, amount)
    local Player = exports['pfm-core']:GetPlayer(src)
    local price = Sales[item] * amount
    local has = Player.GetItemByName(item)
    if has and has.amount < amount then
        amount = has.amount
        price = Sales[item] * amount
    end
    if Player.RemoveItem(item, amount) then
        -- paid through the bank ledger; if the bank is down the materials are handed back
        local key = ('pfm-recyclejob:sell:%s:%s'):format(Player.PlayerData.citizenid, PFPayout.NewId())
        if not PFPayout.Pay(Player, 'cash', price, { key = key, reason = 'recycle-materials-sold', kind = 'sale' }) then
            Player.AddItem(item, amount)
            return
        end
        TriggerClientEvent('QBCore:Notify', src, Lang:t('success.sold', { amount = amount, item = sharedItems[item].label, price = price }), 'success')
        adjustStock(item, 'add', amount)
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.nothing_to_sell'), 'error')
        return
    end
end

local function getItem(source, item, amount)
    local Player = exports['pfm-core']:GetPlayer(source)
    if Config.LimitedMaterials then
        if not checkStock(source, item, amount) then return end
        Player.AddItem(item, amount)
        TriggerClientEvent('qb-inventory:client:ItemBox', source, sharedItems[item], 'add', amount)
        adjustStock(item, 'remove', amount)
    else
        Player.AddItem(item, amount)
        TriggerClientEvent('qb-inventory:client:ItemBox', source, sharedItems[item], 'add', amount)
    end
end

RegisterNetEvent('qb-recyclejob:server:getItem', function()
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    -- carrying a package to the drop takes well over 5s; blocks macro spam of the reward event
    if onCooldown(src, 'getItem', 5000) then return end
    if not isClose(src, 'turnIn') then
        if not uhohs[src] then
            uhohs[src] = 1
            return
        end
        uhohs[src] = (uhohs[src] or 0) + 1
        if uhohs[src] >= 3 then
            exploitBan(src, 'Exploiting distance on qb-recyclejob')
        end
        return
    end
    local pickedAt = carrying[src]
    local held = pickedAt and (os.time() - pickedAt) or -1
    if held < MIN_CARRY_SECONDS or held > MAX_CARRY_SECONDS then
        if held > MAX_CARRY_SECONDS then carrying[src] = nil end
        return
    end
    carrying[src] = nil -- one reward per package
    local itemAmountRecieved = math.random(1, maxRecieved)

    repeat
        Wait(1)
        local item = Recieve[math.random(1, #Recieve)]
        local itemAmount = math.random(item.min, item.max)
        itemAmountRecieved = itemAmountRecieved - 1
        getItem(src, item.item, itemAmount)
    until itemAmountRecieved == 0

    local luckyChance = math.random(1, 100)
    if luckyChance <= LuckyItemChance then
        Player.AddItem(luckyItem, 1)
        TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems[luckyItem], 'add', 1)
    end
end)

RegisterNetEvent('qb-recyclejob:server:sellItem', function(item, amount)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if onCooldown(src, 'sellItem', 2000) then return end
    if not isClose(src, 'sell') then return end
    if not Sales[item] then return end
    amount = math.floor(tonumber(amount) or 0)
    if amount < 1 or amount > 1000 then return end
    if Config.SellMaterials then
        sellMaterials(src, item, amount)
    end
end)
