local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions' })
local sharedItems = exports['pfm-core']:GetShared('Items')
local timeOut = false


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

-- Callback

QBCore.Functions.CreateCallback('qb-jewellery:server:getCops', function(source, cb)
    local amount = 0
    for _, v in pairs(QBCore.Functions.GetQBPlayers()) do
        if (v.PlayerData.job.name == 'police' or v.PlayerData.job.type == 'leo') and v.PlayerData.job.onduty then
            amount = amount + 1
        end
    end
    cb(amount)
end)

QBCore.Functions.CreateCallback('qb-jewellery:server:getVitrineState', function(_, cb)
    cb(Config.Locations)
end)

-- Functions

local function getRewardBasedOnProbability(table)
    local random, probability = math.random(), 0

    for k, v in pairs(table) do
        probability = probability + v.probability
        if random <= probability then
            return k
        end
    end

    return math.random(#table)
end

-- Events

-- Smashes in progress: [src] = { vitrine, at, seconds }. The server starts a smash (case free, player
-- next to it with a whitelisted weapon, enough police on duty right now) and pays only for that case,
-- after the smash time. The client used to pick the case and report the reward on its own, and the
-- police count came from a callback it could skip or replay.
local smashes = {}
local SMASH_RANGE = 3.0
local SMASH_GRACE = 60 -- seconds after the smash time the reward can still be claimed

local function onDutyCops()
    local amount = 0
    for _, v in pairs(QBCore.Functions.GetQBPlayers()) do
        if (v.PlayerData.job.name == 'police' or v.PlayerData.job.type == 'leo') and v.PlayerData.job.onduty then
            amount = amount + 1
        end
    end
    return amount
end

local function weaponSmashTime(src)
    local weapon = GetSelectedPedWeapon(GetPlayerPed(src))
    if not weapon then return nil end
    for hash, data in pairs(Config.WhitelistedWeapons) do
        if (hash & 0xFFFFFFFF) == (weapon & 0xFFFFFFFF) then return data.timeOut end
    end
end

local function setVitrine(k, key, value)
    Config.Locations[k][key] = value
    TriggerClientEvent('qb-jewellery:client:setVitrineState', -1, key, value, k)
end

-- The store resets Config.Timeout after the first case is smashed. Started here only (it was a net
-- event any client could fire).
local function startTimeout()
    if timeOut then return end
    timeOut = true
    TriggerEvent('qb-scoreboard:server:SetActivityBusy', 'jewellery', true)
    Citizen.CreateThread(function()
        Citizen.Wait(Config.Timeout)
        for k, _ in pairs(Config.Locations) do
            Config.Locations[k]['isOpened'] = false
            TriggerClientEvent('qb-jewellery:client:setVitrineState', -1, 'isOpened', false, k)
        end
        TriggerClientEvent('qb-jewellery:client:setAlertState', -1, false)
        TriggerEvent('qb-scoreboard:server:SetActivityBusy', 'jewellery', false)
        timeOut = false
    end)
end

RegisterNetEvent('qb-jewellery:server:setVitrineState', function(stateType, state, k)
    local src = source
    if onCooldown(src, 'vitrineState', 500) then return end
    if stateType ~= 'isBusy' or type(state) ~= 'boolean' then return end
    local vitrine = Config.Locations[k]
    if not vitrine then return end
    if not state then
        -- only the player smashing this case can cancel it
        if smashes[src] and smashes[src].vitrine == k then
            smashes[src] = nil
            setVitrine(k, 'isBusy', false)
        end
        return
    end
    if smashes[src] or vitrine.isOpened or vitrine.isBusy then return end
    if not exports['pfm-core']:GetPlayer(src) then return end
    if #(GetEntityCoords(GetPlayerPed(src)) - vitrine.coords) > SMASH_RANGE then return end
    local smashTime = weaponSmashTime(src)
    if not smashTime then return end
    if onDutyCops() < Config.RequiredCops then return end
    smashes[src] = { vitrine = k, at = os.time(), seconds = math.floor(smashTime / 1000) }
    setVitrine(k, 'isBusy', true)
end)

RegisterNetEvent('qb-jewellery:server:vitrineReward', function(vitrineIndex)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if onCooldown(src, 'vitrineReward', 3000) then return end
    local smash = smashes[src]
    -- No ban here: a case opened by someone else a moment earlier, or a lagging client, lands here too.
    if not smash or smash.vitrine ~= vitrineIndex then return end
    local vitrine = Config.Locations[vitrineIndex]
    local elapsed = os.time() - smash.at
    if elapsed < smash.seconds - 1 then return end -- too early: the smash keeps going
    smashes[src] = nil
    if elapsed > smash.seconds + SMASH_GRACE or vitrine.isOpened then
        setVitrine(vitrineIndex, 'isBusy', false)
        return
    end
    if #(GetEntityCoords(GetPlayerPed(src)) - vitrine.coords) > SMASH_RANGE + 2.0 then
        setVitrine(vitrineIndex, 'isBusy', false)
        return
    end
    setVitrine(vitrineIndex, 'isOpened', true)
    setVitrine(vitrineIndex, 'isBusy', false)
    startTimeout()
    local item = getRewardBasedOnProbability(Config.VitrineRewards)
    local amount = math.random(Config.VitrineRewards[item]['amount']['min'], Config.VitrineRewards[item]['amount']['max'])
    if exports['pfm-inventory']:AddItem(src, Config.VitrineRewards[item]['item'], amount, false, false, 'qb-jewellery:server:vitrineReward') then
        TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems[Config.VitrineRewards[item]['item']], 'add')
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.to_much'), 'error')
    end
end)

-- Kept so older clients don't error; the timeout now starts on the first paid smash (startTimeout).
RegisterNetEvent('qb-jewellery:server:setTimeout', function() end)

AddEventHandler('playerDropped', function()
    local smash = smashes[source]
    smashes[source] = nil
    if smash and Config.Locations[smash.vitrine] then setVitrine(smash.vitrine, 'isBusy', false) end
end)
