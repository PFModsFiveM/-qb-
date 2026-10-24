local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions' })

QBCore.Functions.CreateCallback('qb-weed:server:getBuildingPlants', function(_, cb, building)
    local buildingPlants = {}

    MySQL.query('SELECT * FROM house_plants WHERE building = ?', { building }, function(plants)
        for i = 1, #plants, 1 do
            buildingPlants[#buildingPlants + 1] = plants[i]
        end

        cb(buildingPlants)
    end)
end)

-- Every plant action is checked on the server against the plant's own record: the player must be at
-- the plant, items are used up before anything is given, and harvest/feed amounts are decided here.
-- (These events used to take the strain, seed count, food amount and house from the client and did
-- not need the seed at all, so a plant could be placed anywhere for free and harvested at once.)
local PLANT_RANGE = 3.0

local function decodeCoords(raw)
    local ok, c = pcall(json.decode, raw)
    if not ok or type(c) ~= 'table' then return nil end
    local x, y, z = tonumber(c.x), tonumber(c.y), tonumber(c.z)
    if not (x and y and z) or x ~= x or y ~= y or z ~= z then return nil end
    return vector3(x, y, z)
end

local function nearCoords(src, coords)
    if not coords then return false end
    local p = GetEntityCoords(GetPlayerPed(src))
    return #(vector3(p.x, p.y, p.z) - coords) <= PLANT_RANGE
end

local function loadPlant(house, plantId)
    if type(house) ~= 'string' and type(house) ~= 'number' then return nil end
    local rows = MySQL.query.await('SELECT * FROM house_plants WHERE plantid = ? AND building = ?', { plantId, house })
    return rows and rows[1] or nil
end

RegisterNetEvent('qb-weed:server:placePlant', function(coords, sort, currentHouse)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or not QBWeed.Plants[sort] then return end
    if type(currentHouse) ~= 'string' or #currentHouse > 64 then return end
    local plantCoords = decodeCoords(coords)
    if not nearCoords(src, plantCoords) then return end
    -- grow only in a house you hold keys for
    if GetResourceState('pfm-houses') == 'started' then
        local ok, allowed = pcall(function()
            return exports['pfm-houses']:hasKey(Player.PlayerData.license, Player.PlayerData.citizenid, currentHouse)
        end)
        if ok and not allowed then return end
    end
    -- the seed is used up here, in the same step
    if not exports['pfm-inventory']:RemoveItem(src, 'weed_' .. sort .. '_seed', 1, false, 'qb-weed:server:placePlant') then return end

    local gender = (math.random(1, 2) == 1) and 'man' or 'woman'
    MySQL.insert('INSERT INTO house_plants (building, coords, gender, sort, plantid) VALUES (?, ?, ?, ?, ?)',
        { currentHouse, json.encode({ x = plantCoords.x, y = plantCoords.y, z = plantCoords.z }), gender, sort, math.random(111111, 999999) })
    TriggerClientEvent('qb-weed:client:refreshHousePlants', -1, currentHouse)
end)

-- Clears a dead plant (anyone standing at it).
RegisterNetEvent('qb-weed:server:removeDeathPlant', function(building, plantId)
    local src = source
    local plant = loadPlant(building, plantId)
    if not plant or (tonumber(plant.health) or 0) > 0 then return end
    if not nearCoords(src, decodeCoords(plant.coords)) then return end
    MySQL.query('DELETE FROM house_plants WHERE plantid = ? AND building = ?', { plantId, building })
    TriggerClientEvent('qb-weed:client:refreshHousePlants', -1, building)
end)

-- Kept for older clients: the seed is now used up by placePlant itself.
RegisterServerEvent('qb-weed:server:removeSeed', function() end)

RegisterNetEvent('qb-weed:server:harvestPlant', function(house, _, _, plantId)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if house == nil then
        return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.house_not_found'), 'error', 3500)
    end
    local plant = loadPlant(house, plantId)
    local strain = plant and QBWeed.Plants[plant.sort]
    if not plant or not strain then
        return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.this_plant_no_longer_exists'), 'error', 3500)
    end
    -- only a grown, living plant, harvested by someone standing at it
    if tonumber(plant.stage) ~= strain.highestStage or (tonumber(plant.health) or 0) <= 0 then return end
    if not nearCoords(src, decodeCoords(plant.coords)) then return end

    local sndAmount = math.random(12, 16)
    local weedBag = Player.GetItemByName('empty_weed_bag')
    if not weedBag or weedBag.amount < sndAmount then
        return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.you_dont_have_enough_resealable_bags'), 'error', 3500)
    end
    -- claim the plant first: only one harvest can delete it
    local deleted = MySQL.update.await('DELETE FROM house_plants WHERE plantid = ? AND building = ?', { plantId, house })
    if (tonumber(deleted) or 0) < 1 then return end
    if not exports['pfm-inventory']:RemoveItem(src, 'empty_weed_bag', sndAmount, false, 'qb-weed:server:harvestPlant') then return end

    local seeds = math.random(1, (plant.gender == 'man') and 2 or 6)
    exports['pfm-inventory']:AddItem(src, 'weed_' .. plant.sort .. '_seed', seeds, false, false, 'qb-weed:server:harvestPlant')
    exports['pfm-inventory']:AddItem(src, 'weed_' .. plant.sort, sndAmount, false, false, 'qb-weed:server:harvestPlant')
    TriggerClientEvent('QBCore:Notify', src, Lang:t('text.the_plant_has_been_harvested'), 'success', 3500)
    TriggerClientEvent('qb-weed:client:refreshHousePlants', -1, house)
end)

RegisterNetEvent('qb-weed:server:foodPlant', function(house, _, _, plantId)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    local plant = loadPlant(house, plantId)
    if not plant or not QBWeed.Plants[plant.sort] then return end
    if not nearCoords(src, decodeCoords(plant.coords)) then return end
    if not exports['pfm-inventory']:RemoveItem(src, 'weed_nutrition', 1, false, 'qb-weed:server:foodPlant') then return end
    local food = tonumber(plant.food) or 0
    local updatedFood = math.min(100, food + math.random(40, 60))
    TriggerClientEvent('QBCore:Notify', src, QBWeed.Plants[plant.sort]['label'] .. ' | Nutrition: ' .. food .. '% + ' .. updatedFood - food .. '% (' .. updatedFood .. '%)', 'success', 3500)
    MySQL.update('UPDATE house_plants SET food = ? WHERE building = ? AND plantid = ?', { updatedFood, house, plantId })
    TriggerClientEvent('qb-weed:client:refreshHousePlants', -1, house)
end)

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    for plantName, _ in pairs(QBWeed.Plants) do
        QBCore.Functions.CreateUseableItem('weed_' .. plantName .. '_seed', function(source, item)
            TriggerClientEvent('qb-weed:client:placePlant', source, plantName, item)
        end)
    end
    QBCore.Functions.CreateUseableItem('weed_nutrition', function(source, item)
        TriggerClientEvent('qb-weed:client:foodPlant', source, item)
    end)
end)

CreateThread(function()
    local healthTick = false
    while true do
        local housePlants = MySQL.query.await('SELECT * FROM house_plants', {})
        for k, plant in pairs(housePlants) do
            if housePlants[k].health > 50 then
                local Grow = math.random(QBWeed.Progress.min, QBWeed.Progress.max)
                if housePlants[k].progress + Grow < 100 then
                    MySQL.update('UPDATE house_plants SET progress = ? WHERE plantid = ?',
                        { (housePlants[k].progress + Grow), housePlants[k].plantid })
                elseif housePlants[k].progress + Grow >= 100 then
                    -- (an unknown strain in the table used to crash this loop and stop all growth)
                    local strain = QBWeed.Plants[housePlants[k].sort]
                    if strain and housePlants[k].stage ~= strain['highestStage'] then
                        MySQL.update('UPDATE house_plants SET stage = ?, progress = 0 WHERE plantid = ?',
                            { housePlants[k].stage + 1, housePlants[k].plantid })
                    end
                end
            end
            if healthTick then
                local plantFood = math.max(0, plant.food - QBWeed.FoodUsage)
                local plantHealth = (plantFood >= 50) and math.min(100, plant.health + 1) or math.max(0, plant.health - 1)

                MySQL.update('UPDATE house_plants SET food = ?, health = ? WHERE plantid = ?',
                    { plantFood, plantHealth, plant.plantid })
            end
        end

        TriggerClientEvent('qb-weed:client:refreshHousePlants', -1)
        healthTick = not healthTick
        Wait((60 * 1000) * QBWeed.GrowthTick)
    end
end)
