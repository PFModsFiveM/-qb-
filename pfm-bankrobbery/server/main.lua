local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions' })
local sharedItems = exports['pfm-core']:GetShared('Items')
local robberyBusy = false
local timeOut = false

-- PF hardening: server-side loot + action tracking
local lootedLockers = {}     -- [type .. bankId .. lockerId] = true (one claim per locker per robbery)
local stationCooldowns = {}  -- [src] = os.time()
local copsCallCooldown = {}  -- [src] = os.time()

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
end)

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
    if robberyBusy then return end
    if bankId == 'paleto' then
        if Config.BigBanks['paleto']['isOpened'] or #(GetEntityCoords(GetPlayerPed(source)) - Config.BigBanks['paleto']['coords']) > 2.5 then
            return error(Lang:t('error.event_trigger_wrong', { event = 'qb-bankrobbery:server:setBankState', extraInfo = ' (paleto) ', source = source }))
        end
        Config.BigBanks['paleto']['isOpened'] = true
        TriggerEvent('qb-bankrobbery:server:setTimeout')
    elseif bankId == 'pacific' then
        if Config.BigBanks['pacific']['isOpened'] or #(GetEntityCoords(GetPlayerPed(source)) - Config.BigBanks['pacific']['coords'][2]) > 2.5 then
            return error(Lang:t('error.event_trigger_wrong', { event = 'qb-bankrobbery:server:setBankState', extraInfo = ' (pacific) ', source = source }))
        end
        Config.BigBanks['pacific']['isOpened'] = true
        TriggerEvent('qb-bankrobbery:server:setTimeout')
    else
        if not Config.SmallBanks[bankId] then return end
        if Config.SmallBanks[bankId]['isOpened'] or #(GetEntityCoords(GetPlayerPed(source)) - Config.SmallBanks[bankId]['coords']) > 2.5 then
            return error(Lang:t('error.event_trigger_wrong', { event = 'qb-bankrobbery:server:setBankState', extraInfo = ' (smallbank ' .. tostring(bankId) .. ') ', source = source }))
        end
        Config.SmallBanks[bankId]['isOpened'] = true
        TriggerEvent('qb-bankrobbery:server:SetSmallBankTimeout', bankId)
    end
    TriggerClientEvent('qb-bankrobbery:client:setBankState', -1, bankId)
    robberyBusy = true
    Config.OnRobberyStart(bankId)
end)

RegisterNetEvent('qb-bankrobbery:server:setLockerState', function(bankId, lockerId, state, bool)
    -- whitelist: clients may only flip the two flow flags on a real locker of an opened bank
    if state ~= 'isBusy' and state ~= 'isOpened' then return end
    if type(bool) ~= 'boolean' then return end
    local bankType = Config.BigBanks[bankId] and 'BigBanks' or 'SmallBanks'
    local bank = Config[bankType][bankId]
    if not bank or not bank['lockers'] or not bank['lockers'][lockerId] then return end
    if not bank['isOpened'] then return end
    local extraInfo = (' (%s' .. tostring(bankId) .. ') '):format(bankType == 'SmallBanks' and 'smallbank' or '')
    if #(GetEntityCoords(GetPlayerPed(source)) - bank['lockers'][lockerId]['coords']) > 2.5 then
        return error(Lang:t('error.event_trigger_wrong', { event = 'qb-bankrobbery:server:setLockerState', extraInfo = extraInfo, source = source }))
    end
    bank['lockers'][lockerId][state] = bool
    TriggerClientEvent('qb-bankrobbery:client:setLockerState', -1, bankId, lockerId, state, bool)
end)

-- one validated claim per locker per robbery: the bank must be open, the locker
-- must have been drilled open, and nobody may have emptied it already
local function ClaimLocker(src, lootType, bankId, lockerId)
    if lootType == 'paleto' and bankId ~= 'paleto' then return false end
    if lootType == 'pacific' and bankId ~= 'pacific' then return false end
    local bankType = (lootType == 'small') and 'SmallBanks' or 'BigBanks'
    local bank = Config[bankType][bankId]
    if not bank or not bank['lockers'] or not bank['lockers'][lockerId] then return false end
    if not bank['isOpened'] then return false end
    if not bank['lockers'][lockerId]['isOpened'] then return false end
    local key = lootType .. ':' .. tostring(bankId) .. ':' .. tostring(lockerId)
    if lootedLockers[key] then return false end
    if #(GetEntityCoords(GetPlayerPed(src)) - bank['lockers'][lockerId]['coords']) > 2.5 then return false end
    lootedLockers[key] = true
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
        if tierChance < 10 then tier = 1 elseif tierChance >= 25 and tierChance < 50 then tier = 2 elseif tierChance >= 50 and tierChance < 95 then tier = 3 else tier = 4 end
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
    if type(isHit) ~= 'boolean' then return end
    if not Config.PowerStations[key] then return end
    -- must actually be standing at that power station, and no spamming
    if #(GetEntityCoords(GetPlayerPed(src)) - Config.PowerStations[key].coords) > 15.0 then return end
    local now = os.time()
    if stationCooldowns[src] and now - stationCooldowns[src] < 10 then return end
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

RegisterNetEvent('qb-bankrobbery:server:removeElectronicKit', function()
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    exports['pfm-inventory']:RemoveItem(src, 'electronickit', 1, false, 'qb-bankrobbery:server:removeElectronicKit')
    TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems['electronickit'], 'remove')
    exports['pfm-inventory']:RemoveItem(src, 'trojan_usb', 1, false, 'qb-bankrobbery:server:removeElectronicKit')
    TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems['trojan_usb'], 'remove')
end)

RegisterNetEvent('qb-bankrobbery:server:removeBankCard', function(number)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if number ~= '01' and number ~= '02' then return end
    exports['pfm-inventory']:RemoveItem(src, 'security_card_' .. number, 1, false, 'qb-bankrobbery:server:removeBankCard')
    TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems['security_card_' .. number], 'remove')
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

RegisterNetEvent('thermite:StopFires', function()
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
