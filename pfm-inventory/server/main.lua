QBCore = exports['pfm-core']:GetCoreObject()
Inventories = {}
Drops = {}
InventoryViewers = {}
RegisteredShops = {}
Events = {
    ItemMoved = { hooks = {}, listeners = {} },
    ItemDropped = { hooks = {}, listeners = {} },
    ItemUsed = { hooks = {}, listeners = {} },
    ItemBought = { hooks = {}, listeners = {} },
    ItemAdded = { hooks = {}, listeners = {} },
    ItemRemoved = { hooks = {}, listeners = {} },
    InventoryOpened = { hooks = {}, listeners = {} },
    ShopOpened = { hooks = {}, listeners = {} },
}

--- JSON round-trips turn sparse slot tables into string keys ("5") or re-index them. Rebuilds the
--- table keyed by each item's own slot number; an item whose slot collides goes to a free slot.
function NormalizeSlots(items)
    local out, leftovers = {}, {}
    if type(items) ~= 'table' then return out end
    for key, item in pairs(items) do
        if type(item) == 'table' and type(item.name) == 'string' then
            local slot = tonumber(item.slot) or tonumber(key)
            if slot and out[slot] == nil then
                item.slot = slot
                out[slot] = item
            else
                leftovers[#leftovers + 1] = item
            end
        end
    end
    local nextSlot = 1
    for _, item in ipairs(leftovers) do
        while out[nextSlot] do nextSlot = nextSlot + 1 end
        item.slot = nextSlot
        out[nextSlot] = item
    end
    return out
end

CreateThread(function()
    MySQL.query('SELECT * FROM inventories', {}, function(result)
        if result and #result > 0 then
            for i = 1, #result do
                local inventory = result[i]
                local cacheKey = inventory.identifier
                Inventories[cacheKey] = {
                    items = NormalizeSlots(json.decode(inventory.items) or {}),
                    isOpen = false
                }
            end
            print(#result .. ' inventories successfully loaded')
        end
    end)
end)

CreateThread(function()
    while true do
        for k, v in pairs(Drops) do
            if v and (v.createdTime + (Config.CleanupDropTime * 60) < os.time()) and not Drops[k].isOpen then
                local entity = NetworkGetEntityFromNetworkId(v.entityId)
                if DoesEntityExist(entity) then DeleteEntity(entity) end
                Drops[k] = nil
            end
        end
        Wait(Config.CleanupDropInterval * 60000)
    end
end)

-- Players may pick a drop bag up and carry it. The server records who holds which bag, so a
-- drop can only be re-positioned by the player carrying it, to where that player really is.
DropHolders = {}
local DROP_REACH = 3.0

-- Handlers

AddEventHandler('playerDropped', function()
    local src = source
    for _, inv in pairs(Inventories) do
        if inv.isOpen == src then
            inv.isOpen = false
        end
    end
    for _, drop in pairs(Drops) do
        if drop.isOpen == src then
            drop.isOpen = false
        end
    end
    InventoryViewers[src] = nil
    for dropId, holder in pairs(DropHolders or {}) do
        if holder == src then DropHolders[dropId] = nil end
    end
    for targetId, viewer in pairs(InventoryViewers) do
        if viewer == src then
            InventoryViewers[targetId] = nil
        end
    end
end)

AddEventHandler('txAdmin:events:serverShuttingDown', function()
    for inventory, data in pairs(Inventories) do
        if data.isOpen then
            SaveInventoryItems(inventory)
        end
    end
end)

RegisterNetEvent('QBCore:Server:UpdateObject', function()
    if source ~= '' then return end
    QBCore = exports['pfm-core']:GetCoreObject()
end)

AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    QBCore.Functions.AddPlayerMethod(Player.PlayerData.source, 'AddItem', function(item, amount, slot, info, reason)
        return AddItem(Player.PlayerData.source, item, amount, slot, info, reason)
    end)

    QBCore.Functions.AddPlayerMethod(Player.PlayerData.source, 'RemoveItem', function(item, amount, slot, reason)
        return RemoveItem(Player.PlayerData.source, item, amount, slot, reason)
    end)

    QBCore.Functions.AddPlayerMethod(Player.PlayerData.source, 'GetItemBySlot', function(slot)
        return GetItemBySlot(Player.PlayerData.source, slot)
    end)

    QBCore.Functions.AddPlayerMethod(Player.PlayerData.source, 'GetItemByName', function(item)
        return GetItemByName(Player.PlayerData.source, item)
    end)

    QBCore.Functions.AddPlayerMethod(Player.PlayerData.source, 'GetItemsByName', function(item)
        return GetItemsByName(Player.PlayerData.source, item)
    end)

    QBCore.Functions.AddPlayerMethod(Player.PlayerData.source, 'ClearInventory', function(filterItems)
        ClearInventory(Player.PlayerData.source, filterItems)
    end)

    QBCore.Functions.AddPlayerMethod(Player.PlayerData.source, 'SetInventory', function(items)
        SetInventory(Player.PlayerData.source, items)
    end)
end)

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    local Players = QBCore.Functions.GetQBPlayers()
    for k in pairs(Players) do
        QBCore.Functions.AddPlayerMethod(k, 'AddItem', function(item, amount, slot, info, reason)
            return AddItem(k, item, amount, slot, info, reason)
        end)

        QBCore.Functions.AddPlayerMethod(k, 'RemoveItem', function(item, amount, slot, reason)
            return RemoveItem(k, item, amount, slot, reason)
        end)

        QBCore.Functions.AddPlayerMethod(k, 'GetItemBySlot', function(slot)
            return GetItemBySlot(k, slot)
        end)

        QBCore.Functions.AddPlayerMethod(k, 'GetItemByName', function(item)
            return GetItemByName(k, item)
        end)

        QBCore.Functions.AddPlayerMethod(k, 'GetItemsByName', function(item)
            return GetItemsByName(k, item)
        end)

        QBCore.Functions.AddPlayerMethod(k, 'ClearInventory', function(filterItems)
            ClearInventory(k, filterItems)
        end)

        QBCore.Functions.AddPlayerMethod(k, 'SetInventory', function(items)
            SetInventory(k, items)
        end)

        Player(k).state.inv_busy = false
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        for inventory, data in pairs(Inventories) do
            if data.isOpen then
                SaveInventoryItems(inventory)
            end
        end
    end

    for _, eventData in pairs(Events) do
        for i = 1, #eventData.hooks do
            if eventData.hooks[i] and eventData.hooks[i].resource == resourceName then
                eventData.hooks[i] = false
            end
        end

        for i = 1, #eventData.listeners do
            if eventData.listeners[i] and eventData.listeners[i].resource == resourceName then
                eventData.listeners[i]= false
            end
        end
    end
end)

-- Functions

--- Writes an inventory's items to the database.
--- @param identifier string The identifier of the inventory.
function SaveInventoryItems(identifier)
    local inventory = Inventories[identifier]
    if not inventory then return end
    local items = json.encode(inventory.items)
    MySQL.prepare('INSERT INTO inventories (identifier, items) VALUES (?, ?) ON DUPLICATE KEY UPDATE items = ?', { identifier, items, items })
end

function checkWeapon(source, item)
    local currentWeapon = item
    local ped = GetPlayerPed(source)
    local weapon = GetSelectedPedWeapon(ped)
    local weaponInfo = QBCore.Shared.Weapons[weapon]
    local info = {}

    if type(item) == 'table' then
        currentWeapon = item.name
        info = item.info or {}
    end

    if weaponInfo and weaponInfo.name == currentWeapon then
        RemoveWeaponFromPed(ped, weapon)
        TriggerClientEvent('qb-weapons:client:UseWeapon', source, { name = currentWeapon, info = info }, false)
    end
end

-- Events

RegisterNetEvent('qb-inventory:server:openVending', function(data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    CreateShop({
        name = 'vending',
        label = 'Vending Machine',
        coords = data.coords,
        slots = #Config.VendingItems,
        items = Config.VendingItems
    })
    OpenShop(src, 'vending')
end)

-- Only the player who has a container open can close it. (Any client could close any drop, stash
-- or searched player before, so another player could open a container someone else was using.)
RegisterNetEvent('qb-inventory:server:closeInventory', function(inventory)
    local src = source
    local QBPlayer = QBCore.Functions.GetPlayer(src)
    if not QBPlayer then return end
    Player(source).state.inv_busy = false
    if type(inventory) ~= 'string' then return end
    if inventory:find('shop%-') then return end
    if inventory:find('^otherplayer%-') then
        local targetId = tonumber(inventory:match('^otherplayer%-(.+)'))
        if not targetId or InventoryViewers[targetId] ~= src then return end
        InventoryViewers[targetId] = nil
        Player(targetId).state.inv_busy = false
        return
    end
    if Drops[inventory] then
        if Drops[inventory].isOpen ~= src then return end
        Drops[inventory].isOpen = false
        if #Drops[inventory].items == 0 and not Drops[inventory].isOpen then -- if no listeed items in the drop on close
            TriggerClientEvent('qb-inventory:client:removeDropTarget', -1, Drops[inventory].entityId)
            Wait(500)
            local entity = NetworkGetEntityFromNetworkId(Drops[inventory].entityId)
            if DoesEntityExist(entity) then DeleteEntity(entity) end
            Drops[inventory] = nil
        end
        return
    end
    if not Inventories[inventory] or Inventories[inventory].isOpen ~= src then return end
    Inventories[inventory].isOpen = false
    SaveInventoryItems(inventory)
end)

RegisterNetEvent('qb-inventory:server:useItem', function(item)
    local src = source
    if type(item) ~= 'table' then return end
    local itemData = GetItemBySlot(src, tonumber(item.slot))
    if not itemData then return end
    local itemInfo = QBCore.Shared.Items[itemData.name]
    if itemData.type == 'weapon' then
        local hookData = buildHookData('ItemUsed', source, exports['pfm-core']:GetPlayer(source), itemData)
        if TriggerHook('ItemUsed', itemData.type, hookData) == false then return end
        TriggerClientEvent('qb-weapons:client:UseWeapon', src, itemData, itemData.info.quality and itemData.info.quality > 0)
        TriggerClientEvent('qb-inventory:client:ItemBox', src, itemInfo, 'use')
        TriggerListener('ItemUsed', itemData.type, hookData)
    elseif itemData.name == 'id_card' then
        if UseItem(itemData.name, src, itemData) == false then return end
        TriggerClientEvent('qb-inventory:client:ItemBox', source, itemInfo, 'use')
        local playerPed = GetPlayerPed(src)
        local playerCoords = GetEntityCoords(playerPed)
        local players = QBCore.Functions.GetPlayers()
        local info = itemData.info or {}
        local gender = info.gender == 0 and 'Male' or 'Female'
        for _, v in pairs(players) do
            local targetPed = GetPlayerPed(v)
            local dist = #(playerCoords - GetEntityCoords(targetPed))
            if dist < 3.0 then
                TriggerClientEvent('chat:addMessage', v, {
                    template = '<div class="chat-message advert" style="background: linear-gradient(to right, rgba(5, 5, 5, 0.6), #74807c); display: flex;"><div style="margin-right: 10px;"><i class="far fa-id-card" style="height: 100%;"></i><strong> {0}</strong><br> <strong>Civ ID:</strong> {1} <br><strong>First Name:</strong> {2} <br><strong>Last Name:</strong> {3} <br><strong>Birthdate:</strong> {4} <br><strong>Gender:</strong> {5} <br><strong>Nationality:</strong> {6}</div></div>',
                    args = {
                        'ID Card',
                        info.citizenid,
                        info.firstname,
                        info.lastname,
                        info.birthdate,
                        gender,
                        info.nationality
                    }
                })
            end
        end
    elseif itemData.name == 'driver_license' then
        if UseItem(itemData.name, src, itemData) == false then return end
        TriggerClientEvent('qb-inventory:client:ItemBox', src, itemInfo, 'use')
        local playerPed = GetPlayerPed(src)
        local playerCoords = GetEntityCoords(playerPed)
        local players = QBCore.Functions.GetPlayers()
        local info = itemData.info or {}
        for _, v in pairs(players) do
            local targetPed = GetPlayerPed(v)
            local dist = #(playerCoords - GetEntityCoords(targetPed))
            if dist < 3.0 then
                TriggerClientEvent('chat:addMessage', v, {
                    template = '<div class="chat-message advert" style="background: linear-gradient(to right, rgba(5, 5, 5, 0.6), #657175); display: flex;"><div style="margin-right: 10px;"><i class="far fa-id-card" style="height: 100%;"></i><strong> {0}</strong><br> <strong>First Name:</strong> {1} <br><strong>Last Name:</strong> {2} <br><strong>Birth Date:</strong> {3} <br><strong>Licenses:</strong> {4}</div></div>',
                    args = {
                        'Drivers License',
                        info.firstname,
                        info.lastname,
                        info.birthdate,
                        info.type
                    }
                }
                )
            end
        end
    else
        if UseItem(itemData.name, src, itemData) == false then return end
        TriggerClientEvent('qb-inventory:client:ItemBox', src, itemInfo, 'use')
    end
end)

RegisterNetEvent('qb-inventory:server:openDrop', function(dropId)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local playerPed = GetPlayerPed(src)
    local playerCoords = GetEntityCoords(playerPed)
    if type(dropId) ~= 'string' then return end
    local drop = Drops[dropId]
    if not drop then return end
    if drop.isOpen then return end
    if DropHolders[dropId] then return end -- being carried: its stored position is stale
    local distance = #(playerCoords - drop.coords)
    if distance > 2.5 then return end
    local formattedInventory = {
        name = dropId,
        label = dropId,
        maxweight = drop.maxweight,
        slots = drop.slots,
        inventory = ItemsForClient(dropId, drop.items)
    }
    drop.isOpen = src
    TriggerClientEvent('qb-inventory:client:openInventory', source, ItemsForClient(src, Player.PlayerData.items, Player), formattedInventory)
end)

-- (DropHolders and DROP_REACH are declared near the top of this file.)

RegisterNetEvent('qb-inventory:server:holdDrop', function(dropId)
    local src = source
    local drop = type(dropId) == 'string' and Drops[dropId]
    if not drop then return end
    if DropHolders[dropId] and DropHolders[dropId] ~= src then return end
    if drop.isOpen then return end -- someone is looking inside it
    for id, holder in pairs(DropHolders) do
        if holder == src and id ~= dropId then return end -- one bag at a time
    end
    local playerCoords = GetEntityCoords(GetPlayerPed(src))
    if #(playerCoords - drop.coords) > DROP_REACH then return end
    DropHolders[dropId] = src
end)

RegisterNetEvent('qb-inventory:server:updateDrop', function(dropId)
    local src = source
    local drop = type(dropId) == 'string' and Drops[dropId]
    if not drop or DropHolders[dropId] ~= src then return end
    DropHolders[dropId] = nil
    -- the client's coordinates are ignored: the bag lands where the server sees the carrier
    drop.coords = GetEntityCoords(GetPlayerPed(src))
    local entity = NetworkGetEntityFromNetworkId(drop.entityId)
    if DoesEntityExist(entity) then
        SetEntityRoutingBucket(entity, GetPlayerRoutingBucket(src))
    end
end)

-- Only 'remove' is used (pfm-weapons, when a snowball is thrown). The 'add' branch was reachable only
-- by a modified client and created snowball weapons from nothing.
RegisterNetEvent('qb-inventory:server:snowball', function(action)
    if action == 'remove' then
        RemoveItem(source, 'weapon_snowball', 1, false, 'qb-inventory:server:snowball')
    end
end)

-- Callbacks

-- Clients only need each drop's bag entity to put an "open bag" prompt on it. The full drop table
-- (every item, its metadata and who is holding it, across the whole map) used to be sent instead.
QBCore.Functions.CreateCallback('qb-inventory:server:GetCurrentDrops', function(_, cb)
    local out = {}
    for id, drop in pairs(Drops) do
        out[id] = { entityId = drop.entityId }
    end
    cb(out)
end)

QBCore.Functions.CreateCallback('qb-inventory:server:createDrop', function(source, cb, item)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then
        cb(false)
        return
    end
    if type(item) ~= 'table' then cb(false) return end
    local fromSlot = tonumber(item.fromSlot)
    local amount = tonumber(item.amount)
    if not fromSlot or not amount or amount ~= amount or amount < 1 then cb(false) return end
    amount = math.floor(amount)

    -- The dropped item is rebuilt from the server's own copy. The client only chooses the slot
    -- and amount; its name, info, weight and label are never trusted.
    local serverItem
    for _, invItem in pairs(Player.PlayerData.items) do
        if type(invItem) == 'table' and invItem.slot == fromSlot then serverItem = invItem break end
    end
    if not serverItem or serverItem.amount < amount then cb(false) return end

    local playerPed = GetPlayerPed(src)
    local playerCoords = GetEntityCoords(playerPed)
    local hookData = buildHookData('ItemDropped', src, Player, playerCoords, fromSlot, amount)
    if not hookData.item then cb(false) return end
    if TriggerHook('ItemDropped', hookData.item.type, hookData) == false then cb(false) return end

    local droppedInfo = PFFreshness.CopyInfo(type(serverItem.info) == 'table' and serverItem.info or {})
    item = {
        name = serverItem.name,
        label = serverItem.label,
        amount = amount,
        info = droppedInfo,
        weight = serverItem.weight,
        type = serverItem.type,
        unique = serverItem.unique,
        useable = serverItem.useable,
        image = serverItem.image,
        shouldClose = serverItem.shouldClose,
        combinable = serverItem.combinable,
        description = serverItem.description,
        slot = 1,
    }

    if RemoveItem(src, item.name, amount, fromSlot, 'dropped item') then
        if item.type == 'weapon' then checkWeapon(src, item) end
        TaskPlayAnim(playerPed, 'pickup_object', 'pickup_low', 8.0, -8.0, 2000, 0, 0, false, false, false)
        local bag = CreateObjectNoOffset(Config.ItemDropObject, playerCoords.x + 0.5, playerCoords.y + 0.5, playerCoords.z, true, true, false)
        SetEntityRoutingBucket(bag, GetPlayerRoutingBucket(src))
        local dropId = NetworkGetNetworkIdFromEntity(bag)
        local newDropId = 'drop-' .. dropId
        if PFFreshness.IsPerishable(item.name) then
            item.info = PFFreshness.Prepare(item.name, item.info, PFFreshness.StorageFor(newDropId), PFFreshness.now())
        end
        local itemsTable = setmetatable({ item }, {
            __len = function(t)
                local length = 0
                for _ in pairs(t) do length += 1 end
                return length
            end
        })
        hookData.dropId = newDropId
        hookData.netId = dropId
        if not Drops[newDropId] then
            Drops[newDropId] = {
                name = newDropId,
                label = 'Drop',
                items = itemsTable,
                entityId = dropId,
                createdTime = os.time(),
                coords = playerCoords,
                maxweight = Config.DropSize.maxweight,
                slots = Config.DropSize.slots,
                isOpen = src
            }
            TriggerClientEvent('qb-inventory:client:setupDropTarget', -1, dropId)
        else
            -- a reused network id: put the item in the first free slot of that drop
            local used = {}
            for _, existing in pairs(Drops[newDropId].items) do used[existing.slot] = true end
            local slot = 1
            while used[slot] do slot = slot + 1 end
            item.slot = slot
            Drops[newDropId].items[slot] = item
        end
        RefreshInventorySnapshot(hookData, 'sourceInventory', src)
        TriggerListener('ItemDropped', hookData.item.type, hookData)
        cb(dropId)
    else
        cb(false)
    end
end)

-- [PF custom] pf-government sales tax integration -------------------------
local function roundCurrency(value)
    value = tonumber(value) or 0
    return math.floor((value * 100) + 0.5) / 100
end

local function getSalesTaxBreakdown(subtotal)
    local safeSubtotal = roundCurrency(math.max(0, tonumber(subtotal) or 0))
    local fallback = {
        subtotal = safeSubtotal,
        tax = 0,
        total = safeSubtotal,
        rate = 0
    }

    if GetResourceState('pf-government') ~= 'started' then
        return fallback
    end

    local ok, result = pcall(function()
        return exports['pf-government']:GetSalesTaxBreakdown(safeSubtotal)
    end)

    if ok and type(result) == 'table' and result.total ~= nil and result.tax ~= nil then
        local tax = roundCurrency(result.tax)
        local total = roundCurrency(result.total)

        return {
            subtotal = safeSubtotal,
            tax = tax,
            total = total,
            rate = tonumber(result.rate) or 0
        }
    end

    -- Backward/compat fallback for older pf-government versions.
    local okRate, decimalRate = pcall(function()
        return exports['pf-government']:GetSalesTaxRate()
    end)

    if not okRate then
        return fallback
    end

    local normalizedRate = tonumber(decimalRate) or 0
    local tax = roundCurrency(safeSubtotal * normalizedRate)
    local total = roundCurrency(safeSubtotal + tax)

    return {
        subtotal = safeSubtotal,
        tax = tax,
        total = total,
        rate = normalizedRate * 100
    }
end

--- Hands the sales tax the buyer already paid (inside the total) to pf-government, keyed by the
--- purchase; whatever the government does not take goes back to the buyer.
local function collectSalesTax(citizenid, shop, subtotal, tax, key)
    local collected = 0
    if tax > 0 and GetResourceState('pf-government') == 'started' then
        local ok, value = pcall(function()
            return exports['pf-government']:CollectTaxAmount(tax, 'sales', 'citizen', citizenid, ('shop:%s'):format(tostring(shop or 'unknown')), key .. ':tax', subtotal)
        end)
        collected = ok and (tonumber(value) or 0) or 0
    end
    local uncollected = roundCurrency(tax - collected)
    if uncollected > 0 then
        PFPayout.Pay(citizenid, 'cash', uncollected, { key = key .. ':tax-refund', kind = 'refund', reason = 'Uncollected sales tax', quiet = true })
    end
    return collected
end
-- [PF custom] end ----------------------------------------------------------

QBCore.Functions.CreateCallback('qb-inventory:server:attemptPurchase', function(source, cb, data)
    if type(data) ~= 'table' or type(data.item) ~= 'table' or type(data.shop) ~= 'string' then cb(false) return end
    local itemInfo = data.item
    local amount = tonumber(data.amount) or 0
    local shop = string.gsub(data.shop, 'shop%-', '')
    local Player = QBCore.Functions.GetPlayer(source)

    if amount ~= amount or amount < 1 then cb(false) return end
    amount = math.floor(amount)

    if not Player then
        cb(false)
        return
    end

    local shopInfo = RegisteredShops[shop]
    if not shopInfo then
        cb(false)
        return
    end

    local playerPed = GetPlayerPed(source)
    local playerCoords = GetEntityCoords(playerPed)
    if shopInfo.coords then
        local shopCoords = vector3(shopInfo.coords.x, shopInfo.coords.y, shopInfo.coords.z)
        if #(playerCoords - shopCoords) > 10 then
            cb(false)
            return
        end
    end

    local shopSlot = tonumber(itemInfo.slot)
    local shopItem = shopSlot and shopInfo.items[shopSlot]
    if not shopItem or shopItem.name ~= itemInfo.name then -- Check if item name passed is the same as the item in that slot
        cb(false)
        return
    end
    -- From here on only the shop's own server-side record is used; the client's item table
    -- (including its info) is never trusted.
    itemInfo = { name = shopItem.name, slot = shopSlot, info = shopItem.info }

    if amount > shopInfo.items[itemInfo.slot].amount or shopInfo.items[itemInfo.slot].amount <= 0 then
        TriggerClientEvent('QBCore:Notify', source, Lang:t('notify.notenoughstock'), 'error')
        cb(false)
        return
    end

    if not CanAddItem(source, itemInfo.name, amount) then
        TriggerClientEvent('QBCore:Notify', source, Lang:t('notify.canthold'), 'error')
        cb(false)
        return
    end

    -- [PF custom] sales tax applied to shop purchases
    local unitPrice = tonumber(shopInfo.items[itemInfo.slot].price) or 0
    if unitPrice < 0 then
        cb(false)
        return
    end

    local subtotal = roundCurrency(unitPrice * amount)
    local taxData = getSalesTaxBreakdown(subtotal)
    local tax = roundCurrency(taxData.tax)
    local total = roundCurrency(taxData.total)

    if subtotal > 0 and tax <= 0 and GetResourceState('pf-government') == 'started' then
        print(('[qb-inventory] Sales tax resolved to 0. subtotal=%.2f rate=%.4f'):format(subtotal, tonumber(taxData.rate) or 0))
    end

    if (Player.PlayerData.money.cash or 0) < total then
        TriggerClientEvent('QBCore:Notify', source,
            ('Not enough cash. Subtotal: $%.2f | Tax: $%.2f | Total: $%.2f'):format(subtotal, tax, total),
            'error')
        cb(false)
        return
    end

    local shopType = GetInventoryType(shop)
    local hookData = buildHookData('ItemBought', shopType, shop, itemInfo.slot, amount, source)
    if TriggerHook('ItemBought', shopType, hookData) == false then cb(false) return end

    -- The stock is reserved before the payment (the payment waits on the bank, and two purchases at
    -- once could both pass the stock check above), and given back if the purchase does not complete.
    -- The cash is paid through the pfm-banking ledger into system:pfm-inventory under a fixed key.
    local stock = shopInfo.items[itemInfo.slot]
    stock.amount -= amount
    local cid = Player.PlayerData.citizenid
    local key = ('pfm-inventory:shop:%s:%s:%s'):format(shop, cid, PFPayout.NewId())
    if total > 0 and not PFPayout.Charge(source, 'cash', total, { key = key, kind = 'purchase', reason = 'Shop purchase: ' .. itemInfo.name }) then
        stock.amount += amount
        TriggerClientEvent('QBCore:Notify', source, 'Payment failed.', 'error')
        cb(false)
        return
    end

    local added = AddItem(source, itemInfo.name, amount, nil, itemInfo.info, 'shop-purchase')
    if not added then
        stock.amount += amount
        if total > 0 then PFPayout.Pay(cid, 'cash', total, { key = key .. ':refund', kind = 'refund', reason = 'Shop purchase refunded' }) end
        TriggerClientEvent('QBCore:Notify', source, 'Could not add item. Payment refunded.', 'error')
        cb(false)
        return
    end

    collectSalesTax(cid, shop, subtotal, tax, key)
    TriggerEvent('qb-shops:server:UpdateShopItems', shop, itemInfo, amount)
    TriggerListener('ItemBought', shopType, hookData)

    TriggerClientEvent('QBCore:Notify', source,
        ('Purchase complete. Subtotal: $%.2f | Tax: $%.2f | Total: $%.2f'):format(subtotal, tax, total),
        'success')

    cb(true)
end)

QBCore.Functions.CreateCallback('qb-inventory:server:giveItem', function(source, cb, target, item, amount, slot, info)
    local player = QBCore.Functions.GetPlayer(source)
    if not player or player.PlayerData.metadata['isdead'] or player.PlayerData.metadata['inlaststand'] or player.PlayerData.metadata['ishandcuffed'] then
        cb(false)
        return
    end
    local playerPed = GetPlayerPed(source)

    local Target = QBCore.Functions.GetPlayer(target)
    if not Target or Target.PlayerData.metadata['isdead'] or Target.PlayerData.metadata['inlaststand'] or Target.PlayerData.metadata['ishandcuffed'] then
        cb(false)
        return
    end
    local targetPed = GetPlayerPed(target)

    local pCoords = GetEntityCoords(playerPed)
    local tCoords = GetEntityCoords(targetPed)
    if #(pCoords - tCoords) > 5 then
        cb(false)
        return
    end

    if type(item) ~= 'string' then cb(false) return end
    item = item:lower()
    local itemInfo = QBCore.Shared.Items[item]
    if not itemInfo then
        cb(false)
        return
    end

    -- The given stack is the server's own: the client names the slot, and the item's info (serials,
    -- worth, attachments, freshness) is copied from that slot. The client's `info` used to be handed
    -- to the receiver as-is.
    slot = tonumber(slot)
    local serverItem = slot and GetItemBySlot(source, slot) or GetItemByName(source, item)
    if type(serverItem) ~= 'table' or type(serverItem.name) ~= 'string' or serverItem.name:lower() ~= item then
        cb(false)
        return
    end
    slot = serverItem.slot

    local itemAmount = tonumber(serverItem.amount) or 0
    local giveAmount = tonumber(amount)
    if not giveAmount or giveAmount ~= giveAmount or giveAmount < 1 or itemAmount <= 0 then
        cb(false)
        return
    end
    giveAmount = math.floor(giveAmount)
    if giveAmount > itemAmount then
        cb(false)
        return
    end
    info = PFFreshness.CopyInfo(type(serverItem.info) == 'table' and serverItem.info or {})

    local hookData = buildHookData('ItemMoved', 'player', 'player', source, target, slot, nil, giveAmount, player, Target)
    if TriggerHook('ItemMoved', 'given', hookData) == false then cb(false) return end

    local removeItem = RemoveItem(source, item, giveAmount, slot, 'Item given to ID #' .. target)
    if not removeItem then
        cb(false)
        return
    end

    local giveItem = AddItem(target, item, giveAmount, false, info, 'Item given from ID #' .. source)
    if not giveItem then
        cb(false)
        return
    end

    if itemInfo.type == 'weapon' then checkWeapon(source, item) end
    TriggerClientEvent('qb-inventory:client:giveAnim', source)
    TriggerClientEvent('qb-inventory:client:ItemBox', source, itemInfo, 'remove', giveAmount)
    TriggerClientEvent('qb-inventory:client:giveAnim', target)
    TriggerClientEvent('qb-inventory:client:ItemBox', target, itemInfo, 'add', giveAmount)
    if Player(target).state.inv_busy then TriggerClientEvent('qb-inventory:client:updateInventory', target) end
    RefreshInventorySnapshot(hookData, 'fromInventory', source)
    RefreshInventorySnapshot(hookData, 'toInventory', target)
    TriggerListener('ItemMoved', 'given', hookData)
    cb(true)
end)

-- Item move logic

local function getItem(inventoryId, src, slot)
    local items = {}
    if inventoryId == 'player' then
        local Player = QBCore.Functions.GetPlayer(src)
        if Player and Player.PlayerData.items then
            items = Player.PlayerData.items
        end
    elseif inventoryId:find('^otherplayer%-') then
        local targetId = tonumber(inventoryId:match('^otherplayer%-(.+)'))
        local targetPlayer = QBCore.Functions.GetPlayer(targetId)
        if targetPlayer and targetPlayer.PlayerData.items then
            items = targetPlayer.PlayerData.items
        end
    elseif inventoryId:find('^drop%-') then
        if Drops[inventoryId] and Drops[inventoryId]['items'] then
            items = Drops[inventoryId]['items']
        end
    else
        if Inventories[inventoryId] and Inventories[inventoryId]['items'] then
            items = Inventories[inventoryId]['items']
        end
    end

    for _, item in pairs(items) do
        if item.slot == slot then
            return item
        end
    end
    return nil
end

--- @param inventoryId string The inventory the client named.
--- @param src number The player's server ID.
--- @return boolean
local function isOpenFor(inventoryId, src)
    if inventoryId == 'player' then
        return true
    elseif inventoryId:find('^otherplayer%-') then
        local targetId = tonumber(inventoryId:match('^otherplayer%-(.+)'))
        return targetId ~= nil and InventoryViewers[targetId] == src
    elseif inventoryId:find('^drop%-') then
        return Drops[inventoryId] ~= nil and Drops[inventoryId].isOpen == src
    else
        return Inventories[inventoryId] ~= nil and Inventories[inventoryId].isOpen == src
    end
end

local function getIdentifier(inventoryId, src)
    if inventoryId == 'player' then
        return src
    elseif inventoryId:find('^otherplayer%-') then
        return tonumber(inventoryId:match('^otherplayer%-(.+)'))
    else
        return inventoryId
    end
end

-- Two stacks merge only when the result keeps every item's state: same item, neither unique,
-- and (for perishables) the same batch at matching freshness.
local function canMerge(fromItem, toItem)
    if fromItem.name ~= toItem.name then return false end
    if fromItem.unique or toItem.unique then return false end
    local shared = QBCore.Shared.Items[fromItem.name:lower()]
    if shared and shared.unique then return false end
    return PFFreshness.CanStack(fromItem.name, fromItem.info, toItem.info, PFFreshness.now())
end

-- Puts items back after a move step failed part-way, preferring their original slot.
local function restoreItem(identifier, name, amount, slot, info)
    if AddItem(identifier, name, amount, slot, info, 'move rollback', true) then return true end
    if AddItem(identifier, name, amount, nil, info, 'move rollback', true) then return true end
    print(('[pfm-inventory] CRITICAL: could not restore %dx %s to %s after a failed move'):format(amount, name, tostring(identifier)))
    TriggerEvent('qb-log:server:CreateLog', 'playerinventory', 'Move rollback failed', 'red',
        ('**Inventory:** %s\n**Item:** %s\n**Amount:** %d'):format(tostring(identifier), name, amount))
    return false
end

RegisterNetEvent('qb-inventory:server:SetInventoryData', function(fromInventory, toInventory, fromSlot, toSlot, fromAmount, toAmount)
    if type(fromInventory) ~= 'string' or type(toInventory) ~= 'string' then return end
    if toInventory:find('shop%-') then return end
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    fromSlot, toSlot, fromAmount, toAmount = tonumber(fromSlot), tonumber(toSlot), tonumber(fromAmount), tonumber(toAmount)
    if not fromSlot or not toSlot or not fromAmount or not toAmount or fromAmount < 0 or toAmount < 0 then return end
    -- whole numbers only (NaN and fractions used to pass these checks)
    if toAmount ~= math.floor(toAmount) or fromAmount ~= math.floor(fromAmount) or toAmount < 1 then return end
    if fromSlot ~= math.floor(fromSlot) or toSlot ~= math.floor(toSlot) then return end
    if not isOpenFor(fromInventory, src) or not isOpenFor(toInventory, src) then return end
    -- an open drop can only be used from beside it
    for _, inv in ipairs({ fromInventory, toInventory }) do
        local drop = inv:find('^drop%-') and Drops[inv]
        if drop then
            if DropHolders[inv] then return end
            if #(GetEntityCoords(GetPlayerPed(src)) - drop.coords) > DROP_REACH + 1.0 then return end
        end
    end

    local fromItem = getItem(fromInventory, src, fromSlot)
    local toItem = getItem(toInventory, src, toSlot)

    if fromItem then
        if not toItem and toAmount > fromItem.amount then return end
        if fromInventory == 'player' and toInventory ~= 'player' then checkWeapon(src, fromItem) end

        local fromId = getIdentifier(fromInventory, src)
        local toId = getIdentifier(toInventory, src)

        local hookData = buildHookData('ItemMoved', fromInventory, toInventory, fromId, toId, fromSlot, toSlot, toAmount, Player)
        local moveType, succeeded
        local function resync()
            TriggerClientEvent('qb-inventory:client:updateInventory', src, fromInventory, toInventory, hookData.fromInventory?.items, hookData.toInventory?.items, fromSlot)
        end

        -- Every step removes before it adds; whenever an add fails, the removed items are put back.
        local fromName, fromInfo = fromItem.name, PFFreshness.CopyInfo(fromItem.info)

        if toItem and canMerge(fromItem, toItem) then
            moveType = 'stacked'
            if TriggerHook('ItemMoved', moveType, hookData) == false then resync() return end

            if RemoveItem(fromId, fromName, toAmount, fromSlot, 'stacked item', true) then
                succeeded = AddItem(toId, fromName, toAmount, toSlot, fromInfo, 'stacked item', true)
                if not succeeded then restoreItem(fromId, fromName, toAmount, fromSlot, fromInfo) end
            end
        elseif not toItem and toAmount < fromAmount then
            moveType = 'split'
            if TriggerHook('ItemMoved', moveType, hookData) == false then resync() return end

            if RemoveItem(fromId, fromName, toAmount, fromSlot, 'split item', true) then
                succeeded = AddItem(toId, fromName, toAmount, toSlot, fromInfo, 'split item', true)
                if not succeeded then restoreItem(fromId, fromName, toAmount, fromSlot, fromInfo) end
            end
        else
            if toItem then
                moveType = 'swapped'
                local fromItemAmount = fromItem.amount
                local toItemAmount = toItem.amount
                local toName, toInfo = toItem.name, PFFreshness.CopyInfo(toItem.info)
                if TriggerHook('ItemMoved', moveType, hookData) == false then resync() return end

                local removedFrom = RemoveItem(fromId, fromName, fromItemAmount, fromSlot, 'swapped item', true)
                local removedTo = removedFrom and RemoveItem(toId, toName, toItemAmount, toSlot, 'swapped item', true)
                if removedFrom and removedTo then
                    local fromAdded = AddItem(toId, fromName, fromItemAmount, toSlot, fromInfo, 'swapped item', true)
                    local toAdded = AddItem(fromId, toName, toItemAmount, fromSlot, toInfo, 'swapped item', true)
                    succeeded = fromAdded and toAdded
                    if not succeeded then
                        if fromAdded then RemoveItem(toId, fromName, fromItemAmount, toSlot, 'swap rollback', true) end
                        if toAdded then RemoveItem(fromId, toName, toItemAmount, fromSlot, 'swap rollback', true) end
                        restoreItem(fromId, fromName, fromItemAmount, fromSlot, fromInfo)
                        restoreItem(toId, toName, toItemAmount, toSlot, toInfo)
                    end
                elseif removedFrom then
                    restoreItem(fromId, fromName, fromItemAmount, fromSlot, fromInfo)
                end
            else
                moveType = 'moved'
                if TriggerHook('ItemMoved', moveType, hookData) == false then resync() return end

                if RemoveItem(fromId, fromName, toAmount, fromSlot, 'moved item', true) then
                    succeeded = AddItem(toId, fromName, toAmount, toSlot, fromInfo, 'moved item', true)
                    if not succeeded then restoreItem(fromId, fromName, toAmount, fromSlot, fromInfo) end
                end
            end
        end

        RefreshInventorySnapshot(hookData, 'fromInventory', fromId)
        RefreshInventorySnapshot(hookData, 'toInventory', toId)
        if succeeded then
            TriggerListener('ItemMoved', moveType, hookData)
        else
            resync()
        end
    end
end)
