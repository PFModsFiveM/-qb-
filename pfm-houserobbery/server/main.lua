local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions' })
local sharedItems = exports['pfm-core']:GetShared('Items')

-- Break-ins are tracked server-side. A player gets into a house only after the server saw them
-- start picking that door (at the door, holding a lockpick, enough police on duty) and pfm-minigames
-- judged the skillbar it sent passed; only players who got in may search it, and each search is a
-- skillbar the server judges too. This used to be a single client event that opened any house from
-- 45 m away with no lockpick at all; later the client's own skillbar result still decided.
local DOOR_RANGE = 3.0
local MIN_PICK_MS = 2000        -- an easy skillbar (3 rounds) cannot be played much faster
local MAX_PICK_MS = 60000
local MIN_SEARCH_MS = 1500
local MAX_SEARCH_MS = 60000
local SEARCH_COOLDOWN = 4       -- seconds between two furniture searches by one player
local PICK_COOLDOWN_MS = 2000

local pickAttempts = {}   -- [src] = { house, at (ms), challengeId, item }
local searchAttempts = {} -- [src] = { house, cabin, at (ms), challengeId }
local enteredBy = {}      -- [house] = { [src] = true }
local lastSearch = {}     -- [src] = os.time()
local lastPickStart = {}  -- [src] = GetGameTimer()

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

-- The pick this attempt uses: an advanced lockpick, or a lockpick (with a screwdriver set when the
-- config asks for one). nil when the player lacks the tools.
local function BreakInTool(src, wantAdvanced)
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return nil end
    local hasAdvanced = Player.Functions.GetItemByName('advancedlockpick') ~= nil
    local hasBasic = Player.Functions.GetItemByName('lockpick') ~= nil
        and (not Config.RequireScrewdriver or Player.Functions.GetItemByName('screwdriverset') ~= nil)
    if wantAdvanced and hasAdvanced then return 'advancedlockpick' end
    if hasBasic then return 'lockpick' end
    if hasAdvanced then return 'advancedlockpick' end
    return nil
end

local function Holds(src, item)
    local Player = exports['pfm-core']:GetPlayer(src)
    return Player ~= nil and item ~= nil and Player.Functions.GetItemByName(item) ~= nil
end

-- ── server-judged minigames (pfm-minigames) ──────────────────────
local function IssueChallenge(src, kind, opts)
    local ok, ch = pcall(function() return exports['pfm-minigames']:IssueChallenge(src, kind, opts) end)
    if ok and type(ch) == 'table' and type(ch.id) == 'string' then return ch end
    return nil
end

local function ChallengePassed(src, id)
    if type(id) ~= 'string' then return false end
    local ok, passed = pcall(function() return exports['pfm-minigames']:Verify(src, id) end)
    return ok and passed == true
end

local function CancelChallenge(src, id)
    if type(id) ~= 'string' then return end
    pcall(function() exports['pfm-minigames']:Cancel(src, id) end)
end

-- A failed, restarted or abandoned pick may break the pick (Config.ChanceToBreak*), on the server.
-- (It used to break only when the burglar's client asked for it.)
local function FailPick(src, attempt)
    CancelChallenge(src, attempt.challengeId)
    TriggerClientEvent('qb-houserobbery:client:pickResult', src, attempt.house, false)
    if not Holds(src, attempt.item) then return end
    local chance = attempt.item == 'advancedlockpick' and (Config.ChanceToBreakAdvancedLockPick or 0) or (Config.ChanceToBreakLockPick or 0)
    if math.random(1, 100) > chance then return end
    if exports['pfm-inventory']:RemoveItem(src, attempt.item, 1, false, 'qb-houserobbery:lockpickBroke') then
        TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems[attempt.item], 'remove')
    end
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

-- The client starts picking a door: the server checks the burglar, the door and the tools and sends a
-- skillbar challenge (easy with an advanced lockpick, medium otherwise). Nothing is unlocked yet.
RegisterNetEvent('qb-houserobbery:server:startLockpick', function(house, wantAdvanced)
    local src = source
    if not ValidHouse(house) or Config.Houses[house]['opened'] then return end
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    local meta = Player.PlayerData.metadata or {}
    if meta.isdead or meta.inlaststand or meta.ishandcuffed then return end
    if DistanceToDoor(src, house) > DOOR_RANGE then return end
    if GetCopCount() < (Config.PoliceOnDutyRequired or 0) then return end
    local now = GetGameTimer()
    if lastPickStart[src] and now - lastPickStart[src] < PICK_COOLDOWN_MS then return end
    local item = BreakInTool(src, wantAdvanced == true)
    if not item then return end
    lastPickStart[src] = now

    -- a new attempt ends the open one as failed (a restart does not dodge the breakage)
    if pickAttempts[src] then
        local old = pickAttempts[src]
        pickAttempts[src] = nil
        FailPick(src, old)
    end

    local ch = IssueChallenge(src, 'skillbar', {
        difficulty = item == 'advancedlockpick' and 'easy' or 'medium', tag = 'houserobbery:door:' .. tostring(house),
    })
    if not ch then return end
    local attempt = { house = house, at = now, challengeId = ch.id, item = item }
    pickAttempts[src] = attempt
    SetTimeout(MAX_PICK_MS + 1000, function()
        if pickAttempts[src] ~= attempt then return end
        pickAttempts[src] = nil
        FailPick(src, attempt)
    end)
    RaiseBurglarAlarm(house)
    TriggerClientEvent('qb-houserobbery:client:pickChallenge', src, house, ch)
end)

RegisterNetEvent('qb-houserobbery:server:enterHouse', function(house)
    local src = source
    if not ValidHouse(house) then return end

    -- someone already broke in: anyone at the door may follow them inside (as before)
    if not Config.Houses[house]['opened'] then
        local attempt = pickAttempts[src]
        if not attempt or attempt.house ~= house then return end
        pickAttempts[src] = nil -- single use
        local passed = ChallengePassed(src, attempt.challengeId)
        local elapsed = GetGameTimer() - attempt.at
        if not passed or elapsed < MIN_PICK_MS or elapsed > MAX_PICK_MS
            or DistanceToDoor(src, house) > DOOR_RANGE or not Holds(src, attempt.item) then
            FailPick(src, attempt)
            return
        end

        Config.Houses[house]['opened'] = true
        ResetHouseStateTimer(house)
        TriggerClientEvent('qb-houserobbery:client:setHouseState', -1, house, true)
        TriggerClientEvent('qb-houserobbery:client:pickResult', src, house, true)
    elseif DistanceToDoor(src, house) > DOOR_RANGE then
        return
    end

    enteredBy[house] = enteredBy[house] or {}
    enteredBy[house][src] = true
    TriggerClientEvent('qb-houserobbery:client:enterHouse', src, house)
end)

local function SetCabinBusy(house, cabin, bool)
    Config.Houses[house]['furniture'][cabin]['isBusy'] = bool
    TriggerClientEvent('qb-houserobbery:client:SetBusyState', -1, cabin, house, bool)
end

local function EndSearch(src, attempt)
    if searchAttempts[src] == attempt then searchAttempts[src] = nil end
    CancelChallenge(src, attempt.challengeId)
    SetCabinBusy(attempt.house, attempt.cabin, false)
end

-- A burglar inside starts searching a piece of furniture: the server marks it busy and sends a
-- skillbar; searchFurniture rolls loot only for that piece and only when the skillbar was passed.
RegisterNetEvent('qb-houserobbery:server:startSearch', function(cabin, house)
    local src = source
    if not ValidCabin(house, cabin) or not Config.Houses[house]['opened'] then return end
    if not (enteredBy[house] and enteredBy[house][src]) then return end
    local piece = Config.Houses[house]['furniture'][cabin]
    if piece['searched'] or piece['isBusy'] then return end
    local now = os.time()
    if lastSearch[src] and now - lastSearch[src] < SEARCH_COOLDOWN then return end
    local houseCoords = Config.Houses[house]['coords']
    local p = GetEntityCoords(GetPlayerPed(src))
    if #(vector3(p.x, p.y, p.z) - vector3(houseCoords.x, houseCoords.y, houseCoords.z)) > Config.MinZOffset + 10.0 then return end
    if searchAttempts[src] then EndSearch(src, searchAttempts[src]) end

    local ch = IssueChallenge(src, 'skillbar', { difficulty = 'easy', tag = 'houserobbery:search:' .. tostring(house) })
    if not ch then return end
    lastSearch[src] = now
    local attempt = { house = house, cabin = cabin, at = GetGameTimer(), challengeId = ch.id }
    searchAttempts[src] = attempt
    SetCabinBusy(house, cabin, true)
    SetTimeout(MAX_SEARCH_MS + 1000, function()
        if searchAttempts[src] == attempt then EndSearch(src, attempt) end
    end)
    TriggerClientEvent('qb-houserobbery:client:searchChallenge', src, house, cabin, ch)
end)

RegisterNetEvent('qb-houserobbery:server:searchFurniture', function(cabin, house)
    local src = source

    -- Validate house and cabin exist
    if not ValidCabin(house, cabin) then return end
    local attempt = searchAttempts[src]
    if not attempt or attempt.house ~= house or attempt.cabin ~= cabin then return end
    local passed = ChallengePassed(src, attempt.challengeId)
    EndSearch(src, attempt) -- one result per search, passed or not
    local elapsed = GetGameTimer() - attempt.at
    if not passed or elapsed < MIN_SEARCH_MS or elapsed > MAX_SEARCH_MS then return end

    -- Only players who got in may search, once per piece
    if not Config.Houses[house]['opened'] then return end
    if not (enteredBy[house] and enteredBy[house][src]) then return end
    if Config.Houses[house]['furniture'][cabin]['searched'] then return end

    -- Proximity check: player must be near the house coords
    local houseCoords = Config.Houses[house]['coords']
    local playerCoords = GetEntityCoords(GetPlayerPed(src))
    if #(vector3(playerCoords.x, playerCoords.y, playerCoords.z) - vector3(houseCoords.x, houseCoords.y, houseCoords.z)) > Config.MinZOffset + 10.0 then return end

    -- Claim the piece before any reward (the grant loop yields; a burst of requests used to
    -- slip past the `searched` check and each roll their own loot)
    Config.Houses[house]['furniture'][cabin]['searched'] = true
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
    lastPickStart[src] = nil
    lastSearch[src] = nil
    local search = searchAttempts[src]
    if search then
        searchAttempts[src] = nil
        SetCabinBusy(search.house, search.cabin, false)
    end
    for _, players in pairs(enteredBy) do players[src] = nil end
end)

-- Kept as no-ops for old clients: a lockpick breaks only on the server, when an attempt fails.
RegisterNetEvent('qb-houserobbery:server:removeAdvancedLockpick', function() end)
RegisterNetEvent('qb-houserobbery:server:removeLockpick', function() end)
-- Busy flags are set by the server while a search runs (startSearch / searchFurniture).
RegisterNetEvent('qb-houserobbery:server:SetBusyState', function() end)
