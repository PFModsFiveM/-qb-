local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions' })
local sharedItems = exports['pfm-core']:GetShared('Items')

-- Functions

local function IncreasePlayerXP(source, xpGain, xpType)
    local Player = exports['pfm-core']:GetPlayer(source)
    if Player then
        -- AddRep adds to the current value (it used to be handed the new total, so XP snowballed)
        Player.AddRep(xpType, xpGain)
        TriggerClientEvent('QBCore:Notify', source, string.format(Lang:t('notifications.xpGain'), xpGain, xpType), 'success')
    end
end

-- Benches are placed and picked up through the server: a player gets a bench item back only for
-- the bench they placed, where they placed it, and crafts only at that bench. (Picking up used to
-- hand back any item name the client sent - weapons, gold, marked bills - with no limit.)
local placedBenches = {}   -- [src] = { type, coords }
local BENCH_RANGE = 4.0
local MAX_CRAFT_AMOUNT = 50

local function isBenchType(benchType)
    return type(benchType) == 'string' and type(Config[benchType]) == 'table' and Config[benchType].object ~= nil
end

local function nearBench(src, bench)
    local p = GetEntityCoords(GetPlayerPed(src))
    return #(vector3(p.x, p.y, p.z) - bench.coords) <= BENCH_RANGE
end

AddEventHandler('playerDropped', function()
    placedBenches[source] = nil
end)

-- Callbacks

QBCore.Functions.CreateCallback('crafting:getPlayerInventory', function(source, cb)
    local player = exports['pfm-core']:GetPlayer(source)
    if player then
        cb(player.PlayerData.items)
    else
        cb({})
    end
end)

-- Events
RegisterServerEvent('qb-crafting:server:removeMaterials', function(itemName, amount)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if Player then
        exports['pfm-inventory']:RemoveItem(src, itemName, amount, false, 'qb-crafting:server:removeMaterials')
        TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems[itemName], 'remove')
    end
end)

-- The player sets a bench down: the bench item is used up and the spot is remembered.
RegisterNetEvent('qb-crafting:server:removeCraftingTable', function(benchType)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or not isBenchType(benchType) then return end
    if placedBenches[src] then return end -- one bench out at a time
    if not exports['pfm-inventory']:RemoveItem(src, benchType, 1, false, 'qb-crafting:server:removeCraftingTable') then return end
    local p = GetEntityCoords(GetPlayerPed(src))
    placedBenches[src] = { type = benchType, coords = vector3(p.x, p.y, p.z) }
    TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems[benchType], 'remove')
    TriggerClientEvent('QBCore:Notify', src, Lang:t('notifications.tablePlace'), 'success')
end)

-- The player picks their bench back up.
RegisterNetEvent('qb-crafting:server:addCraftingTable', function(benchType)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    local bench = placedBenches[src]
    if not bench or bench.type ~= benchType or not nearBench(src, bench) then return end
    placedBenches[src] = nil
    if not exports['pfm-inventory']:AddItem(src, benchType, 1, false, false, 'qb-crafting:server:addCraftingTable') then return end
    TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems[benchType], 'add')
end)

RegisterNetEvent('qb-crafting:server:receiveItem', function(benchType, craftedItem, amountToCraft)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end

    local benchConfig = Config[benchType]
    if not benchConfig or type(benchConfig.recipes) ~= 'table' then return end
    -- crafting happens at the player's own bench
    local bench = placedBenches[src]
    if not bench or bench.type ~= benchType or not nearBench(src, bench) then return end

    amountToCraft = math.floor(tonumber(amountToCraft) or 0)
    if amountToCraft <= 0 or amountToCraft > MAX_CRAFT_AMOUNT then return end

    local recipe
    for _, configuredRecipe in pairs(benchConfig.recipes) do
        if configuredRecipe.item == craftedItem then
            recipe = configuredRecipe
            break
        end
    end
    if not recipe then return end

    local xpType = benchConfig.xpType or 'craftingrep'
    -- XP is kept under metadata.rep (it used to read metadata[xpType], which is always empty, so every
    -- recipe that needs XP was uncraftable)
    local currentXP = Player.GetRep(xpType) or 0
    if (recipe.xpRequired or 0) > currentXP then return end

    -- every material is checked before any is taken (a missing second material used to leave the
    -- first one already removed)
    for _, requiredItem in ipairs(recipe.requiredItems or {}) do
        if not exports['pfm-inventory']:HasItem(src, requiredItem.item, requiredItem.amount * amountToCraft) then return end
    end

    for _, requiredItem in ipairs(recipe.requiredItems or {}) do
        local totalRequiredAmount = requiredItem.amount * amountToCraft
        if not exports['pfm-inventory']:RemoveItem(src, requiredItem.item, totalRequiredAmount, false, 'qb-crafting:server:receiveItem') then
            return
        end
        TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems[requiredItem.item], 'remove')
    end

    if not exports['pfm-inventory']:AddItem(src, craftedItem, amountToCraft, false, false, 'qb-crafting:server:receiveItem') then return end

    TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems[craftedItem], 'add')
    TriggerClientEvent('QBCore:Notify', src, string.format(Lang:t('notifications.craftMessage'), sharedItems[craftedItem].label), 'success')
    IncreasePlayerXP(src, (recipe.xpGain or 0) * amountToCraft, xpType)
end)

-- Items

for benchType, v in pairs(Config) do
    if type(v) == 'table' then
        QBCore.Functions.CreateUseableItem(benchType, function(source)
            TriggerClientEvent('qb-crafting:client:useCraftingTable', source, benchType)
        end)
    end
end
