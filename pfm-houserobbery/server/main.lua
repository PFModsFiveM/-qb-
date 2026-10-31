local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions' })
local sharedItems = exports['pfm-core']:GetShared('Items')

-- Break-ins are tracked server-side. A player gets into a house only after the server saw them
-- start picking that door (at the door, holding a lockpick, enough police on duty) and the
-- lockpick minigame had time to run; only players who got in may search it. This used to be a
-- single client event that opened any house from 45 m away with no lockpick at all.
local DOOR_RANGE = 3.0
local MIN_PICK_SECONDS = 3      -- the skillbar cannot be beaten faster than this
local MAX_PICK_SECONDS = 60
local SEARCH_COOLDOWN = 4       -- seconds between two furniture searches by one player

local pickAttempts = {}   -- [src] = { house, at }
local enteredBy = {}      -- [house] = { [src] = true }
local lastSearch = {}     -- [src] = os.time()

-- Functions

local function ValidHouse(house)
    -- houses are keyed by name in config.lua (e.g. 'perfectdrive1')
    return (type(house) == 'string' or type(house) == 'number') and Config.Houses[house] ~= nil
end

local function ValidCabin(house, cabin)
    return ValidHouse(house) and type(cabin) == 'number' and Config.Houses[house].furniture[cabin] ~= nil
end

local function DistanceToDoor(src, house)
    local c = Config.Houses[house].coords
    local p = GetEntityCoords(GetPlayerPed(src))
    return #(vector3(p.x, p.y, p.z) - vector3(c.x, c.y, c.z))
end

local function GetCopCount()
    local amount = 0
    for _, v in pairs(QBCore.Functions.GetQBPlayers()) do
        if v and v.PlayerData.job and v.PlayerData.job.type == 'leo' and v.PlayerData.job.onduty then
            amount = amount + 1
        end
    end
    return amount
end

-- The player must hold the tools the client minigame asks for.
local function HasBreakInTools(src)
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return false end
    if Player.Functions.GetItemByName('advancedlockpick') then return true end
    if not Player.Functions.GetItemByName('lockpick') then return false end
    return not Config.RequireScrewdriver or Player.Functions.GetItemByName('screwdriverset') ~= nil
end

local function ResetHouseStateTimer(house)
    CreateThread(function()
        Wait(Config.TimeToCloseDoors * 60000)
        Config.Houses[house]['opened'] = false
        enteredBy[house] = nil
        for _, v in pairs(Config.Houses[house]['furniture']) do
            v['searched'] = false
            v['isBusy'] = false
        end
        TriggerClientEvent('qb-houserobbery:client:ResetHouseState', -1, house)
    end)
end

-- Burglar alarm: rolled here when a lock pick starts at a door (Config.ChanceToAlertPolice), at most
-- once per house per Config.AlarmCooldown. Police get the usual alert at the door, and the city
-- timeline gets one 'crime.robbery.house' event (news lead + police dispatch request).
local alarmAt = {}        -- [house] = os.time()

local function CityEvent(kind, data, opts)
    if GetResourceState('pf-services') ~= 'started' then return nil end
    local svc = exports['pf-services']
    if not svc then return nil end
    local ok, id = pcall(function() return svc:Emit(kind, data, opts) end)
    return ok and id or nil
end

local function HouseArea(house)
    local prefix = tostring(house):gsub('%d+$', '')
    return (Config.HouseAreas and Config.HouseAreas[prefix]) or nil
end

local function RaiseBurglarAlarm(house)
    local now = os.time()
    if alarmAt[house] and now - alarmAt[house] < (Config.AlarmCooldown or 600) then return end
    if math.random(1, 100) >= (Config.ChanceToAlertPolice or 0) then return end
    alarmAt[house] = now
    local c = Config.Houses[house].coords
    local coords = vector3(c.x, c.y, c.z)
    local text = Lang:t('info.palert')
    for _, v in pairs(QBCore.Functions.GetQBPlayers()) do
        if v and v.PlayerData.job and v.PlayerData.job.type == 'leo' and v.PlayerData.job.onduty then
            TriggerClientEvent('qb-phone:client:addPoliceAlert', v.PlayerData.source, { title = 'Burglar alarm', coords = { x = c.x, y = c.y, z = c.z }, description = text })
            TriggerClientEvent('police:client:policeAlert', v.PlayerData.source, coords, text)
        end
    end
    local area = HouseArea(house)
    local place = area and ('a home on ' .. area) or 'a home'
    CityEvent('crime.robbery.house', { area = area, location = place, place = place, ref = 'robbery:house:' .. tostring(house), details = 'Burglar alarm at ' .. place }, {
        title = 'Burglar alarm at ' .. place, coords = coords, dedupe = 'house:' .. tostring(house),
    })
end

-- Callbacks

QBCore.Functions.CreateCallback('qb-houserobbery:server:GetHouseConfig', function(_, cb)
    cb(Config.Houses)
end)

-- Events

RegisterNetEvent('qb-houserobbery:server:SetBusyState', function(cabin, house, bool)
    local src = source
    if not ValidCabin(house, cabin) or type(bool) ~= 'boolean' then return end
    if not (enteredBy[house] and enteredBy[house][src]) then return end
    Config.Houses[house]['furniture'][cabin]['isBusy'] = bool
    TriggerClientEvent('qb-houserobbery:client:SetBusyState', -1, cabin, house, bool)
end)

-- The client starts the lockpick minigame at a door. Nothing is unlocked yet.
RegisterNetEvent('qb-houserobbery:server:startLockpick', function(house)
    local src = source
    if not ValidHouse(house) then return end
    if DistanceToDoor(src, house) > DOOR_RANGE then return end
    if GetCopCount() < (Config.PoliceOnDutyRequired or 0) then return end
    if not HasBreakInTools(src) then return end
    pickAttempts[src] = { house = house, at = os.time() }
    if not Config.Houses[house]['opened'] then RaiseBurglarAlarm(house) end
end)

RegisterNetEvent('qb-houserobbery:server:enterHouse', function(house)
    local src = source
    if not ValidHouse(house) then return end

    -- someone already broke in: anyone at the door may follow them inside (as before)
    if not Config.Houses[house]['opened'] then
        local attempt = pickAttempts[src]
        pickAttempts[src] = nil -- single use
        if not attempt or attempt.house ~= house then return end
        local elapsed = os.time() - attempt.at
        if elapsed < MIN_PICK_SECONDS or elapsed > MAX_PICK_SECONDS then return end
        if DistanceToDoor(src, house) > DOOR_RANGE then return end
        if not HasBreakInTools(src) then return end

        Config.Houses[house]['opened'] = true
        ResetHouseStateTimer(house)
        TriggerClientEvent('qb-houserobbery:client:setHouseState', -1, house, true)
    elseif DistanceToDoor(src, house) > DOOR_RANGE then
        return
    end

    enteredBy[house] = enteredBy[house] or {}
    enteredBy[house][src] = true
    TriggerClientEvent('qb-houserobbery:client:enterHouse', src, house)
end)

RegisterNetEvent('qb-houserobbery:server:searchFurniture', function(cabin, house)
    local src = source

    -- Validate house and cabin exist
    if not ValidCabin(house, cabin) then return end

    -- Only players who got in may search, once per piece, and not faster than a real search
    if not Config.Houses[house]['opened'] then return end
    if not (enteredBy[house] and enteredBy[house][src]) then return end
    if Config.Houses[house]['furniture'][cabin]['searched'] then return end
    local now = os.time()
    if lastSearch[src] and now - lastSearch[src] < SEARCH_COOLDOWN then return end

    -- Proximity check: player must be near the house coords
    local houseCoords = Config.Houses[house]['coords']
    local playerCoords = GetEntityCoords(GetPlayerPed(src))
    if #(vector3(playerCoords.x, playerCoords.y, playerCoords.z) - vector3(houseCoords.x, houseCoords.y, houseCoords.z)) > Config.MinZOffset then return end

    -- Claim the piece before any reward (the grant loop yields; a burst of requests used to
    -- slip past the `searched` check and each roll their own loot)
    Config.Houses[house]['furniture'][cabin]['searched'] = true
    lastSearch[src] = now
    TriggerClientEvent('qb-houserobbery:client:setCabinState', -1, house, cabin, true)

    local tier = Config.Houses[house].tier
    local availableItems = Config.Rewards[tier][Config.Houses[house].furniture[cabin].type]
    local itemCount = math.random(0, 3)
    if itemCount > 0 then
        for _ = 1, itemCount do
            local selectedItem = availableItems[math.random(1, #availableItems)]
            local itemInfo = sharedItems[selectedItem.item]

            if not itemInfo.unique then
                local amount = math.random(selectedItem.min, selectedItem.max)
                exports['pfm-inventory']:AddItem(src, selectedItem.item, amount, false, false, 'qb-houserobbery:server:searchFurniture')
            else
                exports['pfm-inventory']:AddItem(src, selectedItem.item, 1, false, false, 'qb-houserobbery:server:searchFurniture')
            end
            TriggerClientEvent('qb-inventory:client:ItemBox', src, itemInfo, 'add')
            Wait(500)
        end
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.emty_box'), 'error')
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    pickAttempts[src] = nil
    lastSearch[src] = nil
    for _, players in pairs(enteredBy) do players[src] = nil end
end)

RegisterNetEvent('qb-houserobbery:server:removeAdvancedLockpick', function()
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player then return end
    exports['pfm-inventory']:RemoveItem(source, 'advancedlockpick', 1, false, 'qb-houserobbery:server:removeAdvancedLockpick')
end)

RegisterNetEvent('qb-houserobbery:server:removeLockpick', function()
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player then return end
    exports['pfm-inventory']:RemoveItem(source, 'lockpick', 1, false, 'qb-houserobbery:server:removeLockpick')
end)
