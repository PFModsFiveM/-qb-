-- Backpack: a wearable container. When the player carries the configured backpack
-- item, their inventory UI gains a third section backed by a persistent stash
-- ('backpack-<identifier>'), reusing the normal inventory open/close/save flow.

local function findBackpack(Player)
    for _, item in pairs(Player.PlayerData.items or {}) do
        if item and item.name == Config.Backpack.Item then
            return item
        end
    end
    return nil
end

QBCore.Functions.CreateCallback('qb-inventory:server:getBackpack', function(source, cb)
    if not Config.Backpack or not Config.Backpack.Enabled then return cb(nil) end
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return cb(nil) end

    local backpack = findBackpack(Player)
    if not backpack then return cb(nil) end

    -- every backpack gets a stable identifier stored on the item itself
    local info = backpack.info or {}
    if not info.identifier then
        info.identifier = ('%s%s'):format(Player.PlayerData.citizenid, os.time())
        Player.PlayerData.items[backpack.slot].info = info
        Player.Functions.SetPlayerData('items', Player.PlayerData.items)
    end

    local id = 'backpack-' .. info.identifier
    local existing = Inventories[id]
    if existing and existing.isOpen and existing.isOpen ~= source then
        return cb(nil) -- someone else is in this backpack right now
    end

    CreateInventory(id, {
        label = Config.Backpack.Label,
        maxweight = Config.Backpack.MaxWeight,
        slots = Config.Backpack.Slots,
    })
    local inv = Inventories[id]
    inv.isOpen = source

    cb({
        name = id,
        label = Config.Backpack.Label,
        maxweight = inv.maxweight,
        slots = inv.slots,
        inventory = inv.items,
    })
end)

-- a backpack (or any container item) can never go inside a backpack
local function blockNestedContainers(moveType, hookData)
    if not hookData or type(hookData.toId) ~= 'string' then return end
    if not hookData.toId:find('^backpack%-') then return end
    local fromItems = hookData.fromInventory and hookData.fromInventory.items
    if not fromItems then return end
    for _, item in pairs(fromItems) do
        if item and item.slot == hookData.fromSlot then
            if item.name == Config.Backpack.Item or (Config.Backpack.BlockedItems and Config.Backpack.BlockedItems[item.name]) then
                return false
            end
            return
        end
    end
end

Events.ItemMoved.hooks[#Events.ItemMoved.hooks + 1] = {
    fn = blockNestedContainers,
    resource = GetCurrentResourceName(),
}
