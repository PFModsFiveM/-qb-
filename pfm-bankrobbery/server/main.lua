local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions' })
local sharedItems = exports['pfm-core']:GetShared('Items')
local robberyBusy = false
local timeOut = false

-- PF hardening: server-side loot + action tracking
local lootedLockers = {}     -- [type .. bankId .. lockerId] = true (one claim per locker per robbery)
local stationCooldowns = {}  -- [src] = os.time()
local copsCallCooldown = {}  -- [src] = os.time()

-- Every step that leads to loot is recorded here when the server sees it happen; the next step
-- requires it. (These used to be separate client events: a cheater skipped the items, hacks,
-- drills and police minimums and sent only the final "open" / "opened" events.)
local hackAttempts = {}      -- [src] = { bank = bankId, at = os.time() }  electronic kit + trojan used at a panel
local pacificDoorOpened = false -- security card 02 used at the Pacific door this robbery
local lockerJobs = {}        -- [src] = { bank, locker, at }   drilling / cracking started
local thermiteUsed = {}      -- [src] = { station = key or nil, at }
local alarmRaised = {}       -- [bankId] = os.time() of the last alarm

local HACK_MIN_SECONDS, HACK_MAX_SECONDS = 2, 120
local LOCKER_MIN_SECONDS = { small = 25, big = 16 } -- the progress bars run 27-37 s and 18-30 s
local LOCKER_MAX_SECONDS = 180
local THERMITE_MAX_SECONDS = 60

local function GetCopCount()
    local amount = 0
    local players = QBCore.Functions.GetQBPlayers()
    for _, v in pairs(players) do
        if v and v.PlayerData.job.type == 'leo' and v.PlayerData.job.onduty then
            amount += 1
        end
    end
    return amount
end

-- more police online = bigger payouts, same curve as the store robberies
local function CopLootMultiplier()
    local cfg = Config.CopsLootScaling or {}
    local extra = math.max(0, GetCopCount() - (cfg.BaselineCops or 0))
    return math.min(1.0 + extra * (cfg.PerExtraCop or 0.0), cfg.MaxMultiplier or 1.0)
end

local function ScaledWorth(minW, maxW)
    return math.floor(math.random(minW, maxW) * CopLootMultiplier())
end

local function ClearLootedForPrefix(prefix)
    for k in pairs(lootedLockers) do
        if k:sub(1, #prefix) == prefix then
            lootedLockers[k] = nil
        end
    end
end

AddEventHandler('playerDropped', function()
    stationCooldowns[source] = nil
    copsCallCooldown[source] = nil
    hackAttempts[source] = nil
    lockerJobs[source] = nil
    thermiteUsed[source] = nil
end)

local function PlayerCoords(src)
    return GetEntityCoords(GetPlayerPed(src))
end

local function HasItem(src, item)
    return exports['pfm-inventory']:GetItemByName(src, item) ~= nil
end

local function BankPanelCoords(bankId)
    if bankId == 'paleto' then return Config.BigBanks['paleto']['coords'] end
    if bankId == 'pacific' then return Config.BigBanks['pacific']['coords'][2] end
    return Config.SmallBanks[bankId] and Config.SmallBanks[bankId]['coords'] or nil
end

-- The bank whose hacking panel the player stands at (Fleeca banks and the Pacific vault panel).
local function BankAtPanel(src)
    local pos = PlayerCoords(src)
    for bankId in pairs(Config.SmallBanks) do
        if #(pos - Config.SmallBanks[bankId]['coords']) <= 2.5 then return bankId end
    end
    if #(pos - Config.BigBanks['pacific']['coords'][2]) <= 2.5 then return 'pacific' end
    return nil
end

local function MinimumPolice(bankId)
    if bankId == 'paleto' then return Config.MinimumPaletoPolice or 0 end
    if bankId == 'pacific' then return Config.MinimumPacificPolice or 0 end
    return Config.MinimumFleecaPolice or 0
end

-- Alerts police from the server when a bank opens, unless the robber's client already did (alarmed
-- banks only). A cheater who skips the client alert no longer robs in silence.
local function RaiseAlarm(bankId)
    local typ = (bankId == 'paleto' or bankId == 'pacific') and bankId or 'small'
    local bank = typ == 'small' and Config.SmallBanks[bankId] or Config.BigBanks[bankId]
    if not bank or not bank['alarm'] then return end
    local now = os.time()
    if alarmRaised[bankId] and now - alarmRaised[bankId] < 120 then return end
    alarmRaised[bankId] = now
    local c = BankPanelCoords(bankId)
    TriggerClientEvent('qb-bankrobbery:client:robberyCall', -1, typ, vector3(c.x, c.y, c.z))
end

-- Functions

--- This will convert a table's keys into an array
--- @param tbl table
--- @return array
local function TableKeysToArray(tbl)
    local array = {}
    for k in pairs(tbl) do
        array[#array + 1] = k
    end
    return array
end

--- This will loop over the given table to check if the power stations in the table have been hit
--- @param toLoop table
--- @return boolean
local function TableLoopStations(toLoop)
    local hits = 0
    for _, station in pairs(toLoop) do
        if type(station) == 'table' then
            local hits2 = 0
            for _, station2 in pairs(station) do
                if Config.PowerStations[station2].hit then hits2 += 1 end
                if hits2 == #station then return true end
            end
        else
            if Config.PowerStations[station].hit then hits += 1 end
            if hits == #toLoop then return true end
        end
    end
    return false
end

--- This will check what stations have been hit and update them accordingly
--- @return nil
local function CheckStationHits()
    local policeHits = {}
    local bankHits = {}

    for k, v in pairs(Config.CameraHits) do
        local allStationsHitPolice = false
        local allStationsHitBank = false
        if type(v.type) == 'table' then
            for _, cameraType in pairs(v.type) do
                if cameraType == 'police' then
                    if type(v.stationsToHitPolice) == 'table' then
                        allStationsHitPolice = TableLoopStations(v.stationsToHitPolice)
                    else
                        allStationsHitPolice = Config.PowerStations[v.stationsToHitPolice].hit
                    end
                elseif cameraType == 'bank' then
                    if type(v.stationsToHitBank) == 'table' then
                        allStationsHitBank = TableLoopStations(v.stationsToHitBank)
                    else
                        allStationsHitBank = Config.PowerStations[v.stationsToHitBank].hit
                    end
                end
            end
        else
            if v.type == 'police' then
                if type(v.stationsToHitPolice) == 'table' then
                    allStationsHitPolice = TableLoopStations(v.stationsToHitPolice)
                else
                    allStationsHitPolice = Config.PowerStations[v.stationsToHitPolice].hit
                end
            elseif v.type == 'bank' then
                if type(v.stationsToHitBank) == 'table' then
                    allStationsHitBank = TableLoopStations(v.stationsToHitBank)
                else
                    allStationsHitBank = Config.PowerStations[v.stationsToHitBank].hit
                end
            end
        end

        if allStationsHitPolice then
            policeHits[k] = true
        end

        if allStationsHitBank then
            bankHits[k] = true
        end
    end

    policeHits = TableKeysToArray(policeHits)
    bankHits = TableKeysToArray(bankHits)

    -- table.type checks if it's empty as well, if it's empty it will return the type 'empty' instead of 'array'
    if table.type(policeHits) == 'array' then Config.OnPoliceCameraHit(policeHits) end
    if table.type(bankHits) == 'array' then TriggerClientEvent('qb-bankrobbery:client:BankSecurity', -1, bankHits, false) end
end

--- This will do a quick check to see if all stations have been hit
--- @return boolean
local function AllStationsHit()
    local hit = 0
    for k in pairs(Config.PowerStations) do
        if Config.PowerStations[k].hit then
            hit += 1
        end
    end
    return hit >= Config.HitsNeeded
end

--- This will check if the given coords are in the area of the given distance of a powerstation
--- @param coords vector3
--- @param dist number
--- @return boolean
local function IsNearPowerStation(coords, dist)
    for _, v in pairs(Config.PowerStations) do
        if #(coords - v.coords) < dist then
            return true
        end
    end
    return false
end

-- Events

RegisterNetEvent('qb-bankrobbery:server:setBankState', function(bankId)
    local src = source
    if robberyBusy then return end
    local panel = BankPanelCoords(bankId)
    if not panel then return end
    local bank = (bankId == 'paleto' or bankId == 'pacific') and Config.BigBanks[bankId] or Config.SmallBanks[bankId]
    if bank['isOpened'] or #(PlayerCoords(src) - panel) > 2.5 then
        return error(Lang:t('error.event_trigger_wrong', { event = 'qb-bankrobbery:server:setBankState', extraInfo = ' (' .. tostring(bankId) .. ') ', source = src }))
    end
    if GetCopCount() < MinimumPolice(bankId) then return end

    if bankId == 'paleto' then
        -- the keycard is used here, on the server (it used to be removed by a later client event)
        if not exports['pfm-inventory']:RemoveItem(src, 'security_card_01', 1, false, 'qb-bankrobbery:server:setBankState') then return end
        TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems['security_card_01'], 'remove')
    else
        -- Fleeca and the Pacific vault open only after a hack this player started at this panel
        local hack = hackAttempts[src]
        hackAttempts[src] = nil -- single use
        if not hack or hack.bank ~= bankId then return end
        local elapsed = os.time() - hack.at
        if elapsed < HACK_MIN_SECONDS or elapsed > HACK_MAX_SECONDS then return end
        if bankId == 'pacific' and not pacificDoorOpened then return end
    end

    bank['isOpened'] = true
    if bankId == 'paleto' or bankId == 'pacific' then
        TriggerEvent('qb-bankrobbery:server:setTimeout')
    else
        TriggerEvent('qb-bankrobbery:server:SetSmallBankTimeout', bankId)
    end
    TriggerClientEvent('qb-bankrobbery:client:setBankState', -1, bankId)
    robberyBusy = true
    RaiseAlarm(bankId)
    Config.OnRobberyStart(bankId)
end)

local function LockerOf(bankId, lockerId)
    local bankType = Config.BigBanks[bankId] and 'BigBanks' or 'SmallBanks'
    local bank = Config[bankType][bankId]
    if not bank or not bank['lockers'] or not bank['lockers'][lockerId] then return nil end
    return bank, bank['lockers'][lockerId], bankType == 'BigBanks'
end

RegisterNetEvent('qb-bankrobbery:server:setLockerState', function(bankId, lockerId, state, bool)
    local src = source
    -- Clients may only mark a locker busy / not busy. Opening it is decided by the server when the
    -- drilling or cracking it started has had time to finish (recieveItem).
    if state ~= 'isBusy' or type(bool) ~= 'boolean' then return end
    local bank, locker, isBig = LockerOf(bankId, lockerId)
    if not bank or not bank['isOpened'] or locker['isOpened'] then return end
    if #(PlayerCoords(src) - locker['coords']) > 2.5 then
        return error(Lang:t('error.event_trigger_wrong', { event = 'qb-bankrobbery:server:setLockerState', extraInfo = ' (' .. tostring(bankId) .. ') ', source = src }))
    end
    if bool then
        if locker['isBusy'] then return end
        if isBig and not HasItem(src, 'drill') then return end
        lockerJobs[src] = { bank = bankId, locker = lockerId, at = os.time() }
    end
    locker['isBusy'] = bool
    TriggerClientEvent('qb-bankrobbery:client:setLockerState', -1, bankId, lockerId, 'isBusy', bool)
end)

-- one validated claim per locker per robbery: the bank must be open, this player must have worked on
-- the locker long enough, and nobody may have emptied it already
local function ClaimLocker(src, lootType, bankId, lockerId)
    if lootType == 'paleto' and bankId ~= 'paleto' then return false end
    if lootType == 'pacific' and bankId ~= 'pacific' then return false end
    if lootType == 'small' and (bankId == 'paleto' or bankId == 'pacific') then return false end
    local bank, locker, isBig = LockerOf(bankId, lockerId)
    if not bank or not bank['isOpened'] then return false end
    local job = lockerJobs[src]
    if not job or job.bank ~= bankId or job.locker ~= lockerId then return false end
    local elapsed = os.time() - job.at
    if elapsed < (isBig and LOCKER_MIN_SECONDS.big or LOCKER_MIN_SECONDS.small) or elapsed > LOCKER_MAX_SECONDS then return false end
    local key = lootType .. ':' .. tostring(bankId) .. ':' .. tostring(lockerId)
    if lootedLockers[key] then return false end
    if #(PlayerCoords(src) - locker['coords']) > 2.5 then return false end
    lockerJobs[src] = nil
    lootedLockers[key] = true
    locker['isOpened'] = true
    locker['isBusy'] = false
    TriggerClientEvent('qb-bankrobbery:client:setLockerState', -1, bankId, lockerId, 'isOpened', true)
    TriggerClientEvent('qb-bankrobbery:client:setLockerState', -1, bankId, lockerId, 'isBusy', false)
    return true
end

RegisterNetEvent('qb-bankrobbery:server:recieveItem', function(type, bankId, lockerId)
    local src = source
    local ply = exports['pfm-core']:GetPlayer(src)
    if not ply then return end
    if not ClaimLocker(src, type, bankId, lockerId) then return end
    if type == 'small' then
        local itemType = math.random(#Config.RewardTypes)
        local WeaponChance = math.random(1, 50)
        local odd1 = math.random(1, 50)
        local tierChance = math.random(1, 100)
        local tier
        if tierChance < 50 then tier = 1 elseif tierChance >= 50 and tierChance < 80 then tier = 2 elseif tierChance >= 80 and tierChance < 95 then tier = 3 else tier = 4 end
        if WeaponChance ~= odd1 then
            if tier ~= 4 then
                if Config.RewardTypes[itemType].type == 'item' then
                    local item = Config.LockerRewards['tier' .. tier][math.random(#Config.LockerRewards['tier' .. tier])]
                    local itemAmount = math.random(item.minAmount, item.maxAmount)
                    exports['pfm-inventory']:AddItem(src, item.item, itemAmount, false, false, 'qb-bankrobbery:server:recieveItem')
                    TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems[item.item], 'add')
                elseif Config.RewardTypes[itemType].type == 'money' then
                    local info = {
                        worth = ScaledWorth(2300, 3200)
                    }
                    exports['pfm-inventory']:AddItem(src, 'markedbills', math.random(2, 3), false, info, 'qb-bankrobbery:server:recieveItem')
                    TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems['markedbills'], 'add')
                end
            else
                exports['pfm-inventory']:AddItem(src, 'security_card_01', 1, false, false, 'qb-bankrobbery:server:recieveItem')
                TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems['security_card_01'], 'add')
            end
        else
            exports['pfm-inventory']:AddItem(src, 'weapon_stungun', 1, false, false, 'qb-bankrobbery:server:recieveItem')
            TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems['weapon_stungun'], 'add')
        end
    elseif type == 'paleto' then
        local itemType = math.random(#Config.RewardTypes)
        local tierChance = math.random(1, 100)
        local WeaponChance = math.random(1, 10)
        local odd1 = math.random(1, 10)
        local tier
        if tierChance < 25 then tier = 1 elseif tierChance >= 25 and tierChance < 70 then tier = 2 elseif tierChance >= 70 and tierChance < 95 then tier = 3 else tier = 4 end
        if WeaponChance ~= odd1 then
            if tier ~= 4 then
                if Config.RewardTypes[itemType].type == 'item' then
                    local item = Config.LockerRewardsPaleto['tier' .. tier][math.random(#Config.LockerRewardsPaleto['tier' .. tier])]
                    local itemAmount = math.random(item.minAmount, item.maxAmount)
                    exports['pfm-inventory']:AddItem(src, item.item, itemAmount, false, false, 'qb-bankrobbery:server:recieveItem')
                    TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems[item.item], 'add')
                elseif Config.RewardTypes[itemType].type == 'money' then
                    local info = {
                        worth = ScaledWorth(4000, 6000)
                    }
                    exports['pfm-inventory']:AddItem(src, 'markedbills', math.random(1, 4), false, info, 'qb-bankrobbery:server:recieveItem')
                    TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems['markedbills'], 'add')
                end
            else
                exports['pfm-inventory']:AddItem(src, 'security_card_02', 1, false, false, 'qb-bankrobbery:server:recieveItem')
                TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems['security_card_02'], 'add')
            end
        else
            exports['pfm-inventory']:AddItem(src, 'weapon_vintagepistol', 1, false, false, 'qb-bankrobbery:server:recieveItem')
            TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems['weapon_vintagepistol'], 'add')
        end
    elseif type == 'pacific' then
        local itemType = math.random(#Config.RewardTypes)
        local WeaponChance = math.random(1, 100)
        local odd1 = math.random(1, 100)
        local odd2 = math.random(1, 100)
        local tierChance = math.random(1, 100)
        local tier
        -- (rolls of 10-24 used to fall through every branch, erroring after the locker was claimed)
        if tierChance < 25 then tier = 1 elseif tierChance < 50 then tier = 2 elseif tierChance < 95 then tier = 3 else tier = 4 end
        if WeaponChance ~= odd1 or WeaponChance ~= odd2 then
            if tier ~= 4 then
                if Config.RewardTypes[itemType].type == 'item' then
                    local item = Config.LockerRewardsPacific['tier' .. tier][math.random(#Config.LockerRewardsPacific['tier' .. tier])]
                    local maxAmount
                    if tier == 3 then maxAmount = 7 elseif tier == 2 then maxAmount = 18 else maxAmount = 25 end
                    local itemAmount = math.random(maxAmount)
                    exports['pfm-inventory']:AddItem(src, item.item, itemAmount, false, false, 'qb-bankrobbery:server:recieveItem')
                    TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems[item.item], 'add')
                elseif Config.RewardTypes[itemType].type == 'money' then
                    local info = {
                        worth = ScaledWorth(19000, 21000)
                    }
                    exports['pfm-inventory']:AddItem(src, 'markedbills', math.random(1, 4), false, info, 'qb-bankrobbery:server:recieveItem')
                    TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems['markedbills'], 'add')
                end
            else
                local info = {
                    worth = ScaledWorth(19000, 21000)
                }
                exports['pfm-inventory']:AddItem(src, 'markedbills', math.random(1, 4), false, info, 'qb-bankrobbery:server:recieveItem')
                TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems['markedbills'], 'add')
                info = {
                    crypto = math.random(1, 3)
                }
                exports['pfm-inventory']:AddItem(src, 'cryptostick', 1, false, info, 'qb-bankrobbery:server:recieveItem')
                TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems['cryptostick'], 'add')
            end
        else
            local chance = math.random(1, 2)
            local odd = math.random(1, 2)
            if chance == odd then
                exports['pfm-inventory']:AddItem(src, 'weapon_microsmg', 1, false, false, 'qb-bankrobbery:server:recieveItem')
                TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems['weapon_microsmg'], 'add')
            else
                exports['pfm-inventory']:AddItem(src, 'weapon_minismg', 1, false, false, 'qb-bankrobbery:server:recieveItem')
                TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems['weapon_minismg'], 'add')
            end
        end
    end
end)

AddEventHandler('qb-bankrobbery:server:setTimeout', function()
    if robberyBusy or timeOut then return end
    timeOut = true
    CreateThread(function()
        SetTimeout(60000 * 90, function()
            for k in pairs(Config.BigBanks['pacific']['lockers']) do
                Config.BigBanks['pacific']['lockers'][k]['isBusy'] = false
                Config.BigBanks['pacific']['lockers'][k]['isOpened'] = false
            end
            for k in pairs(Config.BigBanks['paleto']['lockers']) do
                Config.BigBanks['paleto']['lockers'][k]['isBusy'] = false
                Config.BigBanks['paleto']['lockers'][k]['isOpened'] = false
            end
            TriggerClientEvent('qb-bankrobbery:client:ClearTimeoutDoors', -1)
            Config.BigBanks['paleto']['isOpened'] = false
            Config.BigBanks['pacific']['isOpened'] = false
            pacificDoorOpened = false
            ClearLootedForPrefix('paleto:')
            ClearLootedForPrefix('pacific:')
            timeOut = false
            robberyBusy = false
            Config.OnRobberyTimeoutEnd('paleto')
            Config.OnRobberyTimeoutEnd('pacific')
        end)
    end)
end)

AddEventHandler('qb-bankrobbery:server:SetSmallBankTimeout', function(bankId)
    if robberyBusy or timeOut then return end
    timeOut = true
    CreateThread(function()
        SetTimeout(60000 * 30, function()
            for k in pairs(Config.SmallBanks[bankId]['lockers']) do
                Config.SmallBanks[bankId]['lockers'][k]['isOpened'] = false
                Config.SmallBanks[bankId]['lockers'][k]['isBusy'] = false
            end
            TriggerClientEvent('qb-bankrobbery:client:ResetFleecaLockers', -1, bankId)
            Config.SmallBanks[bankId]['isOpened'] = false
            ClearLootedForPrefix('small:' .. tostring(bankId) .. ':')
            timeOut = false
            robberyBusy = false
            Config.OnRobberyTimeoutEnd(bankId)
        end)
    end)
end)

RegisterNetEvent('qb-bankrobbery:server:callCops', function(type, bank, coords)
    local src = source
    local now = os.time()
    if copsCallCooldown[src] and now - copsCallCooldown[src] < 30 then return end
    copsCallCooldown[src] = now
    -- the alert must come from where the player actually is
    if not coords or not coords.x then return end
    local playerCoords = GetEntityCoords(GetPlayerPed(src))
    if #(playerCoords - vector3(coords.x + 0.0, coords.y + 0.0, coords.z + 0.0)) > 100.0 then return end
    if type == 'small' then
        if not Config.SmallBanks[bank]['alarm'] then
            return error(Lang:t('error.event_trigger_wrong', { event = 'qb-bankrobbery:server:callCops', extraInfo = ' (smallbank ' .. bank .. ') ', source = source }))
        end
    elseif type == 'paleto' then
        if not Config.BigBanks['paleto']['alarm'] then
            return error(Lang:t('error.event_trigger_wrong', { event = 'qb-bankrobbery:server:callCops', extraInfo = ' (paleto) ', source = source }))
        end
    elseif type == 'pacific' then
        if not Config.BigBanks['pacific']['alarm'] then
            return error(Lang:t('error.event_trigger_wrong', { event = 'qb-bankrobbery:server:callCops', extraInfo = ' (pacific) ', source = source }))
        end
    end
    TriggerClientEvent('qb-bankrobbery:client:robberyCall', -1, type, coords)
end)

RegisterNetEvent('qb-bankrobbery:server:SetStationStatus', function(key, isHit)
    local src = source
    -- players can only blow a station; restoring power is the server's job (blackout timer)
    if isHit ~= true then return end
    if not Config.PowerStations[key] or Config.PowerStations[key].hit then return end
    -- must actually be standing at that power station, and no spamming
    if #(GetEntityCoords(GetPlayerPed(src)) - Config.PowerStations[key].coords) > 15.0 then return end
    local now = os.time()
    if stationCooldowns[src] and now - stationCooldowns[src] < 10 then return end
    -- a thermite charge must just have been used at this station by this player
    local used = thermiteUsed[src]
    thermiteUsed[src] = nil
    if not used or used.station ~= key or now - used.at > THERMITE_MAX_SECONDS then return end
    if GetCopCount() < (Config.MinimumThermitePolice or 0) then return end
    stationCooldowns[src] = now
    Config.PowerStations[key].hit = isHit
    TriggerClientEvent('qb-bankrobbery:client:SetStationStatus', -1, key, isHit)
    if AllStationsHit() then
        exports['pfm-weathersync']:setBlackout(true)
        TriggerClientEvent('qb-bankrobbery:client:disableAllBankSecurity', -1)
        Config.OnBlackout(true)
        CreateThread(function()
            SetTimeout(60000 * Config.BlackoutTimer, function()
                exports['pfm-weathersync']:setBlackout(false)
                TriggerClientEvent('qb-bankrobbery:client:enableAllBankSecurity', -1)
                Config.OnBlackout(false)
            end)
        end)
    else
        CheckStationHits()
    end
end)

-- The client plugs the electronic kit + trojan USB into a bank panel. Both are used up here, and
-- the hack this starts is what lets setBankState open that bank.
RegisterNetEvent('qb-bankrobbery:server:removeElectronicKit', function()
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    local bankId = BankAtPanel(src)
    if not bankId or robberyBusy then return end
    if not HasItem(src, 'electronickit') or not HasItem(src, 'trojan_usb') then return end
    if not exports['pfm-inventory']:RemoveItem(src, 'electronickit', 1, false, 'qb-bankrobbery:server:removeElectronicKit') then return end
    if not exports['pfm-inventory']:RemoveItem(src, 'trojan_usb', 1, false, 'qb-bankrobbery:server:removeElectronicKit') then return end
    TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems['electronickit'], 'remove')
    TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems['trojan_usb'], 'remove')
    hackAttempts[src] = { bank = bankId, at = os.time() }
end)

-- Security card 02 opens the Pacific front door (step one of the Pacific robbery). Card 01 (Paleto)
-- is used inside setBankState.
RegisterNetEvent('qb-bankrobbery:server:removeBankCard', function(number)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if number ~= '02' then return end
    if robberyBusy or #(PlayerCoords(src) - Config.BigBanks['pacific']['coords'][1]) > 3.0 then return end
    if GetCopCount() < (Config.MinimumPacificPolice or 0) then return end
    if not exports['pfm-inventory']:RemoveItem(src, 'security_card_02', 1, false, 'qb-bankrobbery:server:removeBankCard') then return end
    TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems['security_card_02'], 'remove')
    pacificDoorOpened = true
end)

RegisterNetEvent('thermite:StartServerFire', function(coords, maxChildren, isGasFire)
    local src = source
    local ped = GetPlayerPed(src)
    local coords2 = GetEntityCoords(ped)
    maxChildren = math.min(math.max(tonumber(maxChildren) or 1, 1), 25)
    isGasFire = isGasFire == true
    if not coords or not coords.x or #(coords2 - vector3(coords.x + 0.0, coords.y + 0.0, coords.z + 0.0)) > 15.0 then return end
    local thermiteCoords = Config.BigBanks['pacific'].thermite[1].coords
    local thermite2Coords = Config.BigBanks['pacific'].thermite[2].coords
    local thermite3Coords = Config.BigBanks['paleto'].thermite[1].coords
    if #(coords2 - thermiteCoords) < 10 or #(coords2 - thermite2Coords) < 10 or #(coords2 - thermite3Coords) < 10 or IsNearPowerStation(coords2, 10) then
        TriggerClientEvent('thermite:StartFire', -1, coords, maxChildren, isGasFire)
    end
end)

-- Clears thermite fires for everyone; rate-limited, since it used to be a free griefing tool.
local lastStopFires = 0
RegisterNetEvent('thermite:StopFires', function()
    local now = os.time()
    if now - lastStopFires < 30 then return end
    lastStopFires = now
    TriggerClientEvent('thermite:StopFires', -1)
end)

-- Callbacks

QBCore.Functions.CreateCallback('qb-bankrobbery:server:isRobberyActive', function(_, cb)
    cb(robberyBusy)
end)

QBCore.Functions.CreateCallback('qb-bankrobbery:server:GetConfig', function(_, cb)
    cb(Config.PowerStations, Config.BigBanks, Config.SmallBanks)
end)

QBCore.Functions.CreateCallback('thermite:server:check', function(source, cb)
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player then return cb(false) end
    if exports['pfm-inventory']:RemoveItem(source, 'thermite', 1, false, 'thermite:server:check') then
        TriggerClientEvent('qb-inventory:client:ItemBox', source, sharedItems['thermite'], 'remove')
        -- remember where the charge was used: a power station counts as blown only right after this
        local pos, station = PlayerCoords(source), nil
        for key, v in pairs(Config.PowerStations) do
            if #(pos - v.coords) <= 15.0 then station = key break end
        end
        thermiteUsed[source] = { station = station, at = os.time() }
        cb(true)
    else
        cb(false)
    end
end)

-- Items

QBCore.Functions.CreateUseableItem('thermite', function(source)
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player or not exports['pfm-inventory']:GetItemByName(source, 'thermite') then return end
    if exports['pfm-inventory']:GetItemByName(source, 'lighter') then
        TriggerClientEvent('thermite:UseThermite', source)
    else
        TriggerClientEvent('QBCore:Notify', source, Lang:t('error.missing_ignition_source'), 'error')
    end
end)

QBCore.Functions.CreateUseableItem('security_card_01', function(source)
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player or not exports['pfm-inventory']:GetItemByName(source, 'security_card_01') then return end
    TriggerClientEvent('qb-bankrobbery:UseBankcardA', source)
end)

QBCore.Functions.CreateUseableItem('security_card_02', function(source)
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player or not exports['pfm-inventory']:GetItemByName(source, 'security_card_02') then return end
    TriggerClientEvent('qb-bankrobbery:UseBankcardB', source)
end)

QBCore.Functions.CreateUseableItem('electronickit', function(source)
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player or not exports['pfm-inventory']:GetItemByName(source, 'electronickit') then return end
    TriggerClientEvent('electronickit:UseElectronickit', source)
end)
