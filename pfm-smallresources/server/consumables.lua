----------- / anti-exploit helpers

local useCooldowns = {} -- [src] = { [key] = lastUse }

-- Per-player, per-item/event cooldown. Returns true when the use is still on cooldown.
local function IsOnUseCooldown(src, key, cooldownMs)
    local cooldown = cooldownMs or Config.ConsumableCooldown or 1000
    if cooldown <= 0 then return false end
    local now = GetGameTimer()
    useCooldowns[src] = useCooldowns[src] or {}
    local last = useCooldowns[src][key]
    if last and (now - last) < cooldown then return true end
    useCooldowns[src][key] = now
    return false
end

AddEventHandler('playerDropped', function()
    useCooldowns[source] = nil
end)

-- Largest configured single-use replenish value; used to cap client-reported hunger/thirst totals
local function getMaxReplenish()
    local maxValue = 0
    for _, group in pairs({ Config.Consumables.eat, Config.Consumables.drink, Config.Consumables.alcohol }) do
        for _, value in pairs(group) do
            if type(value) == 'number' and value > maxValue then maxValue = value end
        end
    end
    for _, data in pairs(Config.Consumables.custom) do
        local r = type(data) == 'table' and data.replenish and tonumber(data.replenish.replenish)
        if r and r > maxValue then maxValue = r end
    end
    return maxValue
end

----------- / server-issued consumption grants
-- Hunger and thirst only rise after the server itself consumed a real item for this player.
-- The client's reported total is ignored; the gain comes from config, scaled by freshness.

local needGrants = {}          -- [src] = { hunger = grant, thirst = grant, alcohol = { item, expires, grant } }
local GRANT_SECONDS = 30       -- the client progress bars take at most ~6s

AddEventHandler('playerDropped', function()
    needGrants[source] = nil
end)

local NO_EFFECT = { benefit = 1.0, illness = 0 }

local function foodEffects(item)
    if type(item) ~= 'table' or GetResourceState('pfm-inventory') ~= 'started' then return NO_EFFECT end
    local ok, fx = pcall(function() return exports['pfm-inventory']:GetFreshness(item.name, item.info) end)
    if ok and type(fx) == 'table' then return fx end
    return NO_EFFECT
end

local function buildGrant(src, base, item)
    local fx = foodEffects(item)
    local cap = Config.MaxReplenish or getMaxReplenish()
    local amount = math.floor((tonumber(base) or 0) * (tonumber(fx.benefit) or 1.0) + 0.5)
    if amount > cap then amount = cap end
    if amount < 0 then amount = 0 end
    local illness = tonumber(fx.illness) or 0
    if fx.state == 'stale' or fx.state == 'spoiled' then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('consumables.tastes_off'), 'error')
    end
    return { amount = amount, expires = os.time() + GRANT_SECONDS, ill = illness > 0 and math.random(100) <= illness }
end

local function issueGrant(src, need, grant)
    needGrants[src] = needGrants[src] or {}
    needGrants[src][need] = grant
end

--- Applies and consumes a pending grant. Returns the new value, or nil when there is none.
local function applyGrant(src, Player, need)
    local grants = needGrants[src]
    local grant = grants and grants[need]
    if not grant then return nil end
    grants[need] = nil
    if os.time() > grant.expires then return nil end
    local current = tonumber(Player.PlayerData.metadata[need]) or 0
    local value = current + grant.amount
    if value > 100 then value = 100 end
    Player.SetMetaData(need, value)
    if grant.ill then TriggerClientEvent('consumables:client:FoodPoisoning', src) end
    return value
end

----------- / alcohol

for k, _ in pairs(Config.Consumables.alcohol) do
    QBCore.Functions.CreateUseableItem(k, function(source, item)
        -- the bottle is removed when the client finishes drinking (drinkAlcohol); the thirst
        -- grant only becomes valid once that removal succeeds
        needGrants[source] = needGrants[source] or {}
        needGrants[source].alcohol = { item = item.name, expires = os.time() + GRANT_SECONDS, grant = buildGrant(source, Config.Consumables.alcohol[item.name], item) }
        TriggerClientEvent('consumables:client:DrinkAlcohol', source, item.name)
    end)
end

----------- / Eat

for k, _ in pairs(Config.Consumables.eat) do
    QBCore.Functions.CreateUseableItem(k, function(source, item)
        local grant = buildGrant(source, Config.Consumables.eat[item.name], item)
        if not exports['pfm-inventory']:RemoveItem(source, item.name, 1, item.slot, 'qb-smallresources:consumables:eat') then return end
        issueGrant(source, 'hunger', grant)
        TriggerClientEvent('consumables:client:Eat', source, item.name)
    end)
end

----------- / Drink
for k, _ in pairs(Config.Consumables.drink) do
    QBCore.Functions.CreateUseableItem(k, function(source, item)
        local grant = buildGrant(source, Config.Consumables.drink[item.name], item)
        if not exports['pfm-inventory']:RemoveItem(source, item.name, 1, item.slot, 'qb-smallresources:consumables:drink') then return end
        issueGrant(source, 'thirst', grant)
        TriggerClientEvent('consumables:client:Drink', source, item.name)
    end)
end

----------- / Custom
for k, _ in pairs(Config.Consumables.custom) do
    QBCore.Functions.CreateUseableItem(k, function(source, item)
        if not exports['pfm-inventory']:RemoveItem(source, item.name, 1, item.slot, 'qb-smallresources:consumables:custom') then return end
        TriggerClientEvent('consumables:client:Custom', source, item.name)
    end)
end

local function createItem(name, type)
    QBCore.Functions.CreateUseableItem(name, function(source, item)
        if not exports['pfm-inventory']:RemoveItem(source, item.name, 1, item.slot, 'qb-smallresources:consumables:createItem') then return end
        TriggerClientEvent('consumables:client:' .. type, source, item.name)
    end)
end
----------- / Drug

QBCore.Functions.CreateUseableItem('joint', function(source, item)
    if not exports['pfm-inventory']:RemoveItem(source, item.name, 1, item.slot, 'qb-smallresources:joint') then return end
    TriggerClientEvent('consumables:client:UseJoint', source)
end)

QBCore.Functions.CreateUseableItem('cokebaggy', function(source)
    TriggerClientEvent('consumables:client:Cokebaggy', source)
end)

QBCore.Functions.CreateUseableItem('crack_baggy', function(source)
    TriggerClientEvent('consumables:client:Crackbaggy', source)
end)

QBCore.Functions.CreateUseableItem('xtcbaggy', function(source)
    TriggerClientEvent('consumables:client:EcstasyBaggy', source)
end)

QBCore.Functions.CreateUseableItem('oxy', function(source)
    TriggerClientEvent('consumables:client:oxy', source)
end)

QBCore.Functions.CreateUseableItem('meth', function(source)
    TriggerClientEvent('consumables:client:meth', source)
end)

----------- / Tools

QBCore.Functions.CreateUseableItem('armor', function(source)
    TriggerClientEvent('consumables:client:UseArmor', source)
end)

QBCore.Functions.CreateUseableItem('heavyarmor', function(source)
    TriggerClientEvent('consumables:client:UseHeavyArmor', source)
end)

QBCore.Commands.Add('resetarmor', 'Resets Vest (Police Only)', {}, false, function(source)
    local Player = exports['pfm-core']:GetPlayer(source)
    if Player.PlayerData.job.name == 'police' then
        TriggerClientEvent('consumables:client:ResetArmor', source)
    else
        TriggerClientEvent('QBCore:Notify', source, 'For Police Officer Only', 'error')
    end
end)

QBCore.Functions.CreateUseableItem('binoculars', function(source)
    TriggerClientEvent('binoculars:Toggle', source)
end)

QBCore.Functions.CreateUseableItem('parachute', function(source, item)
    if not exports['pfm-inventory']:RemoveItem(source, item.name, 1, item.slot, 'qb-smallresources:parachute') then return end
    TriggerClientEvent('consumables:client:UseParachute', source)
end)

QBCore.Commands.Add('resetparachute', 'Resets Parachute', {}, false, function(source)
    TriggerClientEvent('consumables:client:ResetParachute', source)
end)

----------- / Firework

for _, v in pairs(Config.Fireworks.items) do
    QBCore.Functions.CreateUseableItem(v, function(source, item)
        local src = source
        TriggerClientEvent('fireworks:client:UseFirework', src, item.name, 'proj_indep_firework')
    end)
end

----------- / Lockpicking

QBCore.Functions.CreateUseableItem('lockpick', function(source)
    TriggerClientEvent('lockpicks:UseLockpick', source, false)
end)

QBCore.Functions.CreateUseableItem('advancedlockpick', function(source)
    TriggerClientEvent('lockpicks:UseLockpick', source, true)
end)

-- Events for adding and removing specific items to fix some exploits

RegisterNetEvent('consumables:server:AddParachute', function()
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player then return end
    if IsOnUseCooldown(source, 'AddParachute') then return end
    if exports['pfm-inventory']:GetItemByName(source, 'parachute') then return end
    exports['pfm-inventory']:AddItem(source, 'parachute', 1, false, false, 'consumables:server:AddParachute')
end)

RegisterNetEvent('consumables:server:resetArmor', function()
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player then return end
    if IsOnUseCooldown(source, 'resetArmor') then return end
    if exports['pfm-inventory']:GetItemByName(source, 'heavyarmor') then return end
    exports['pfm-inventory']:AddItem(source, 'heavyarmor', 1, false, false, 'consumables:server:resetArmor')
end)

RegisterNetEvent('consumables:server:useHeavyArmor', function()
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if IsOnUseCooldown(src, 'useHeavyArmor') then return end
    if not exports['pfm-inventory']:RemoveItem(src, 'heavyarmor', 1, false, 'consumables:server:useHeavyArmor') then return end
    local armorValue = (Config.ArmorValues and Config.ArmorValues.heavyarmor) or 100
    TriggerClientEvent('qb-inventory:client:ItemBox', src, QBCore.Shared.Items['heavyarmor'], 'remove')
    TriggerClientEvent('hospital:server:SetArmor', src, armorValue)
    SetPedArmour(GetPlayerPed(src), armorValue)
end)

RegisterNetEvent('consumables:server:useArmor', function()
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if IsOnUseCooldown(src, 'useArmor') then return end
    if not exports['pfm-inventory']:RemoveItem(src, 'armor', 1, false, 'consumables:server:useArmor') then return end
    local armorValue = (Config.ArmorValues and Config.ArmorValues.armor) or 75
    TriggerClientEvent('qb-inventory:client:ItemBox', src, QBCore.Shared.Items['armor'], 'remove')
    TriggerClientEvent('hospital:server:SetArmor', src, armorValue)
    SetPedArmour(GetPlayerPed(src), armorValue)
end)

RegisterNetEvent('consumables:server:useMeth', function()
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player then return end
    if IsOnUseCooldown(source, 'useMeth') then return end
    exports['pfm-inventory']:RemoveItem(source, 'meth', 1, false, 'consumables:server:useMeth')
end)

RegisterNetEvent('consumables:server:useOxy', function()
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player then return end
    if IsOnUseCooldown(source, 'useOxy') then return end
    exports['pfm-inventory']:RemoveItem(source, 'oxy', 1, false, 'consumables:server:useOxy')
end)

RegisterNetEvent('consumables:server:useXTCBaggy', function()
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player then return end
    if IsOnUseCooldown(source, 'useXTCBaggy') then return end
    exports['pfm-inventory']:RemoveItem(source, 'xtcbaggy', 1, false, 'consumables:server:useXTCBaggy')
end)

RegisterNetEvent('consumables:server:useCrackBaggy', function()
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player then return end
    if IsOnUseCooldown(source, 'useCrackBaggy') then return end
    exports['pfm-inventory']:RemoveItem(source, 'crack_baggy', 1, false, 'consumables:server:useCrackBaggy')
end)

RegisterNetEvent('consumables:server:useCokeBaggy', function()
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player then return end
    if IsOnUseCooldown(source, 'useCokeBaggy') then return end
    exports['pfm-inventory']:RemoveItem(source, 'cokebaggy', 1, false, 'consumables:server:useCokeBaggy')
end)

RegisterNetEvent('consumables:server:drinkAlcohol', function(item)
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player then return end
    if IsOnUseCooldown(source, 'drinkAlcohol') then return end
    local foundItem = nil

    for k in pairs(Config.Consumables.alcohol) do
        if k == item then
            foundItem = k
            break
        end
    end

    if not foundItem then return end
    local pending = needGrants[source] and needGrants[source].alcohol
    if not pending or pending.item ~= foundItem or os.time() > pending.expires then return end
    needGrants[source].alcohol = nil
    if exports['pfm-inventory']:RemoveItem(source, foundItem, 1, false, 'consumables:server:drinkAlcohol') then
        issueGrant(source, 'thirst', pending.grant)
    end
end)

RegisterNetEvent('consumables:server:UseFirework', function(item)
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player then return end
    if IsOnUseCooldown(source, 'UseFirework') then return end
    local foundItem = nil

    for i = 1, #Config.Fireworks.items do
        if Config.Fireworks.items[i] == item then
            foundItem = Config.Fireworks.items[i]
            break
        end
    end

    if not foundItem then return end
    exports['pfm-inventory']:RemoveItem(source, foundItem, 1, false, 'consumables:server:UseFirework')
end)

-- The client still sends its computed total for compatibility; it is ignored.
RegisterNetEvent('consumables:server:addThirst', function()
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    local value = applyGrant(src, Player, 'thirst')
    if not value then return end
    TriggerClientEvent('hud:client:UpdateNeeds', src, Player.PlayerData.metadata.hunger, value)
end)

RegisterNetEvent('consumables:server:addHunger', function()
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    local value = applyGrant(src, Player, 'hunger')
    if not value then return end
    TriggerClientEvent('hud:client:UpdateNeeds', src, value, Player.PlayerData.metadata.thirst)
end)

QBCore.Functions.CreateCallback('consumables:itemdata', function(_, cb, itemName)
    cb(Config.Consumables.custom[itemName])
end)

---Checks if item already exists in the table. If not, it creates it.
---@param drinkName string name of item
---@param replenish number amount it replenishes
---@return boolean, string
local function addDrink(drinkName, replenish)
    if Config.Consumables.drink[drinkName] ~= nil then
        return false, 'already added'
    else
        Config.Consumables.drink[drinkName] = replenish
        createItem(drinkName, 'Drink')
        return true, 'success'
    end
end

exports('AddDrink', addDrink)

---Checks if item already exists in the table. If not, it creates it.
---@param foodName string name of item
---@param replenish number amount it replenishes
---@return boolean, string
local function addFood(foodName, replenish)
    if Config.Consumables.eat[foodName] ~= nil then
        return false, 'already added'
    else
        Config.Consumables.eat[foodName] = replenish
        createItem(foodName, 'Eat')
        return true, 'success'
    end
end

exports('AddFood', addFood)

---Checks if item already exists in the table. If not, it creates it.
---@param alcoholName string name of item
---@param replenish number amount it replenishes
---@return boolean, string
local function addAlcohol(alcoholName, replenish)
    if Config.Consumables.alcohol[alcoholName] ~= nil then
        return false, 'already added'
    else
        Config.Consumables.alcohol[alcoholName] = replenish
        createItem(alcoholName, 'DrinkAlcohol')
        return true, 'success'
    end
end

exports('AddAlcohol', addAlcohol)

---Checks if item already exists in the table. If not, it creates it.
---@param itemName string name of item
---@param data number amount it replenishes
---@return boolean, string
local function addCustom(itemName, data)
    if Config.Consumables.custom[itemName] ~= nil then
        return false, 'already added'
    else
        Config.Consumables.custom[itemName] = data
        createItem(itemName, 'Custom')
        return true, 'success'
    end
end

exports('AddCustom', addCustom)
