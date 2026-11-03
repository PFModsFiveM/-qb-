local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions' })
local sharedItems = exports['pfm-core']:GetShared('Items')
local robberyBusy = false
local timeOut = false
local typeOf = type -- some handlers below take a parameter named `type`

-- PF hardening: server-side loot + action tracking
local lootedLockers = {}     -- [type .. bankId .. lockerId] = true (one claim per locker per robbery)
local stationCooldowns = {}  -- [src] = os.time()
local copsCallCooldown = {}  -- [src] = os.time()

-- Every step that leads to loot is recorded here when the server sees it happen; the next step
-- requires it. (These used to be separate client events: a cheater skipped the items, hacks,
-- drills and police minimums and sent only the final "open" / "opened" events.)
-- The hacks and thermite charges are pfm-minigames challenges: the server issues the puzzle and judges
-- the answer, so a client's own "I passed" opens nothing.
local hackAttempts = {}      -- [src] = { bank = bankId, at = os.time(), challengeId }  kit + trojan used at a panel
local pacificDoorOpened = false -- security card 02 used at the Pacific door this robbery
local lockerJobs = {}        -- [src] = { bank, locker, at }   drilling / cracking started
local thermiteUsed = {}      -- [src] = { station = key | nil, bank, gate, at, challengeId }  charge placed
local alarmRaised = {}       -- [bankId] = os.time() of the last alarm

local HACK_MIN_SECONDS, HACK_MAX_SECONDS = 2, 120
local LOCKER_MIN_SECONDS = { small = 25, big = 16 } -- the progress bars run 27-37 s and 18-30 s
local LOCKER_MAX_SECONDS = 180
local THERMITE_MAX_SECONDS = 60
local THERMITE_STATION_RANGE = 3.0 -- the client offers the charge within 1.5 m of the station
local THERMITE_GATE_RANGE = 2.0    -- the gate zones are 1 m boxes
local THERMITE_FUSE_MS = 3000      -- the client counts 3 s down before a placed charge goes off
local FIRE_MIN_MS, FIRE_MAX_MS = 10000, 15000
local FIRE_MAX_COUNT = 7

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

-- ── bank doors (pfm-doorlock) ────────────────────────────────────
-- Opened and locked only here, through pfm-doorlock's server path, when the server has seen the step
-- that opens them (a client may not unlock these doors itself). sentSource names the player the
-- door change is for; it must be a loaded player.
local function SetBankDoor(src, doorId, locked)
    if not doorId or not src then return end
    TriggerEvent('qb-doorlock:server:updateState', doorId, locked, false, false, true, false, false, src)
end

local function BankDoorIds()
    local ids, seen = {}, {}
    local function add(id) if id and not seen[id] then seen[id] = true; ids[#ids + 1] = id end end
    add((Config.BankDoors or {}).pacificFront)
    add((Config.BankDoors or {}).paletoVault)
    for _, bankId in ipairs({ 'pacific', 'paleto' }) do
        for _, gate in ipairs(Config.BigBanks[bankId]['thermite'] or {}) do add(gate['doorId']) end
    end
    return ids
end

-- Locks every big-bank door again. pfm-doorlock wants a loaded player for the change; with nobody
-- online it is retried until someone is.
local function RelockBankDoors(ids)
    ids = ids or BankDoorIds()
    local players = QBCore.Functions.GetPlayers() or {}
    local src = tonumber(players[1])
    if not src then
        SetTimeout(30000, function() RelockBankDoors(ids) end)
        return
    end
    for _, id in ipairs(ids) do SetBankDoor(src, id, true) end
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

-- City events (pf-services): the timeline the news desk and police dispatch read. Optional: nothing
-- happens when pf-services is not running.
local function CityEvent(kind, data, opts)
    if GetResourceState('pf-services') ~= 'started' then return nil end
    local svc = exports['pf-services']
    if not svc then return nil end
    local ok, id = pcall(function() return svc:Emit(kind, data, opts) end)
    return ok and id or nil
end

local function PublicBankName(bankId)
    if bankId == 'paleto' or bankId == 'pacific' then
        return Config.BigBanks[bankId] and Config.BigBanks[bankId]['label'] or tostring(bankId)
    end
    local bank = Config.SmallBanks[bankId]
    return 'Fleeca Bank ' .. (bank and bank['label'] or tostring(bankId))
end

-- One robbery, one event: raised when the server opened the vault (setBankState passed every check),
-- at the bank's own coordinates. The event (police = true) also puts a police dispatch request on the
-- map; news gets a short bulletin.
local function ReportBankRobbery(bankId)
    local name = PublicBankName(bankId)
    local c = BankPanelCoords(bankId)
    CityEvent('crime.robbery.bank', { bank = name, bankId = tostring(bankId), location = name, place = name, ref = 'robbery:bank:' .. tostring(bankId),
        details = 'Vault alarm at ' .. name }, {
        title = 'Bank robbery at ' .. name, coords = c and vector3(c.x, c.y, c.z) or nil, dedupe = 'bank:' .. tostring(bankId),
    })
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
        -- Fleeca and the Pacific vault open only after a hack this player started at this panel, and
        -- only when pfm-minigames judged that hack passed
        local hack = hackAttempts[src]
        hackAttempts[src] = nil -- single use
        if not hack or hack.bank ~= bankId then return end
        local elapsed = os.time() - hack.at
        if elapsed < HACK_MIN_SECONDS or elapsed > HACK_MAX_SECONDS then return end
        if bankId == 'pacific' and not pacificDoorOpened then return end
        if not ChallengePassed(src, hack.challengeId) then return end
    end

    bank['isOpened'] = true
    if bankId == 'paleto' then SetBankDoor(src, (Config.BankDoors or {}).paletoVault, false) end
    if bankId == 'paleto' or bankId == 'pacific' then
        TriggerEvent('qb-bankrobbery:server:setTimeout')
    else
        TriggerEvent('qb-bankrobbery:server:SetSmallBankTimeout', bankId)
    end
    TriggerClientEvent('qb-bankrobbery:client:setBankState', -1, bankId)
    robberyBusy = true
    RaiseAlarm(bankId)
    ReportBankRobbery(bankId)
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
            for _, bankId in ipairs({ 'pacific', 'paleto' }) do
                for i, gate in ipairs(Config.BigBanks[bankId]['thermite'] or {}) do
                    if gate['isOpened'] then
                        gate['isOpened'] = false
                        TriggerClientEvent('qb-bankrobbery:client:setThermiteGate', -1, bankId, i, false)
                    end
                end
            end
            TriggerClientEvent('qb-bankrobbery:client:ClearTimeoutDoors', -1)
            Config.BigBanks['paleto']['isOpened'] = false
            Config.BigBanks['pacific']['isOpened'] = false
            pacificDoorOpened = false
            RelockBankDoors()
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
    -- the alert must come from where the player actually is, at the bank it names (it used to accept
    -- any spot and any type, and an unknown Fleeca id errored)
    if typeOf(coords) ~= 'table' and typeOf(coords) ~= 'vector3' then return end
    local cx, cy, cz = tonumber(coords.x), tonumber(coords.y), tonumber(coords.z)
    if not (cx and cy and cz) then return end
    local playerCoords = PlayerCoords(src)
    if #(playerCoords - vector3(cx, cy, cz)) > 100.0 then return end
    local bankCoords
    if type == 'small' then
        bankCoords = Config.SmallBanks[bank] and Config.SmallBanks[bank]['coords']
    elseif type == 'paleto' then
        bankCoords = BankPanelCoords('paleto')
    elseif type == 'pacific' then
        bankCoords = Config.BigBanks['pacific']['coords'][1]
    end
    if not bankCoords or #(playerCoords - bankCoords) > 60.0 then return end
    coords = vector3(cx, cy, cz)
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

-- A power station blows only when the server saw a thermite charge pass there (thermiteFinish below).
-- (There used to be a client event that blew a station, also after a failed charge.)
local function BlowStation(src, key)
    if not Config.PowerStations[key] or Config.PowerStations[key].hit then return end
    local now = os.time()
    if stationCooldowns[src] and now - stationCooldowns[src] < 10 then return end
    stationCooldowns[src] = now
    Config.PowerStations[key].hit = true
    TriggerClientEvent('qb-bankrobbery:client:SetStationStatus', -1, key, true)
    if AllStationsHit() then
        exports['pfm-weathersync']:setBlackout(true)
        -- a city-wide blackout is public news (kind registered here: it is not in the shared catalog)
        if GetResourceState('pf-services') == 'started' then
            pcall(function()
                exports['pf-services']:RegisterEventKind('crime.blackout', { label = 'City-wide blackout', news = 'auto', category = 'crime', bulletin = true })
            end)
        end
        CityEvent('crime.blackout', { minutes = Config.BlackoutTimer, stations = Config.HitsNeeded }, {
            title = 'Blackout across the city after power stations were sabotaged',
            coords = Config.PowerStations[key].coords, dedupe = 'blackout',
        })
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
end

-- The client plugs the electronic kit + trojan USB into a bank panel. Both are used up here, and the
-- server hands that player a hacking challenge; setBankState opens the bank only if it was passed.
QBCore.Functions.CreateCallback('qb-bankrobbery:server:startHack', function(src, cb)
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return cb(false) end
    local bankId = BankAtPanel(src)
    if not bankId or robberyBusy then return cb(false) end
    local bank = bankId == 'pacific' and Config.BigBanks['pacific'] or Config.SmallBanks[bankId]
    if bank['isOpened'] or GetCopCount() < MinimumPolice(bankId) then return cb(false) end
    -- the Pacific vault panel is behind the front gate: no kit is used up before the card opened it
    if bankId == 'pacific' and not pacificDoorOpened then return cb(false) end
    if not HasItem(src, 'electronickit') or not HasItem(src, 'trojan_usb') then return cb(false) end
    local ch = IssueChallenge(src, 'hacking', {
        size = (Config.HackChallenge or {}).size or 5, seconds = (Config.HackChallenge or {}).seconds or 30,
        tag = 'bankrobbery:hack:' .. tostring(bankId),
    })
    if not ch then return cb(false) end
    if not exports['pfm-inventory']:RemoveItem(src, 'electronickit', 1, false, 'qb-bankrobbery:server:startHack')
        or not exports['pfm-inventory']:RemoveItem(src, 'trojan_usb', 1, false, 'qb-bankrobbery:server:startHack') then
        CancelChallenge(src, ch.id)
        return cb(false)
    end
    TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems['electronickit'], 'remove')
    TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems['trojan_usb'], 'remove')
    if hackAttempts[src] then CancelChallenge(src, hackAttempts[src].challengeId) end
    hackAttempts[src] = { bank = bankId, at = os.time(), challengeId = ch.id }
    cb(ch)
end)

-- Security card 02 opens the Pacific front door (step one of the Pacific robbery): the card is used up
-- here and the server opens the gate. Card 01 (Paleto) is used inside setBankState.
RegisterNetEvent('qb-bankrobbery:server:removeBankCard', function(number)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if number ~= '02' then return end
    if robberyBusy or pacificDoorOpened or #(PlayerCoords(src) - Config.BigBanks['pacific']['coords'][1]) > 3.0 then return end
    if GetCopCount() < (Config.MinimumPacificPolice or 0) then return end
    if not exports['pfm-inventory']:RemoveItem(src, 'security_card_02', 1, false, 'qb-bankrobbery:server:removeBankCard') then return end
    TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems['security_card_02'], 'remove')
    pacificDoorOpened = true
    SetBankDoor(src, (Config.BankDoors or {}).pacificFront, false)
    -- a crew that never gets the vault open does not leave the gate open for the next one
    SetTimeout(60000 * (Config.PacificFrontDoorMinutes or 15), function()
        if Config.BigBanks['pacific']['isOpened'] or not pacificDoorOpened then return end
        pacificDoorOpened = false
        RelockBankDoors({ (Config.BankDoors or {}).pacificFront })
    end)
end)

-- ── thermite ─────────────────────────────────────────────────────
-- What a charge is placed on, from the server's position of the player: a power station that is not
-- blown yet, or a thermite gate whose earlier step is done (the bank's vault for the first gate, the
-- gate before it for the next).
local function ThermiteTarget(src)
    local pos = PlayerCoords(src)
    for key, station in pairs(Config.PowerStations) do
        if #(pos - station.coords) <= THERMITE_STATION_RANGE then
            if station.hit then return nil end
            return { station = key }
        end
    end
    for _, bankId in ipairs({ 'pacific', 'paleto' }) do
        local bank = Config.BigBanks[bankId]
        for i, gate in ipairs(bank['thermite'] or {}) do
            if gate['coords'] and #(pos - gate['coords']) <= THERMITE_GATE_RANGE then
                if gate['isOpened'] then return nil end
                local before
                if i == 1 then before = bank['isOpened'] else before = bank['thermite'][i - 1]['isOpened'] end
                if not before then return nil end
                return { bank = bankId, gate = i }
            end
        end
    end
    return nil
end

local function OpenThermiteGate(src, bankId, i)
    local gate = Config.BigBanks[bankId] and Config.BigBanks[bankId]['thermite'][i]
    if not gate or gate['isOpened'] then return end
    gate['isOpened'] = true
    TriggerClientEvent('qb-bankrobbery:client:setThermiteGate', -1, bankId, i, true)
    SetBankDoor(src, gate['doorId'], false)
end

-- Thermite fires belong to the server: it lights them at the player's position (server side) when a
-- charge goes off, passed or failed, and puts out exactly those fires 10-15 s later. Clients keep
-- each session's fires apart, so one robbery's stop never touches another's fires. (Clients used to
-- start fires at any spot near a station or vault and put out everyone's fires at will.)
local fireCounter = 0
local function StartFireSession(pos, delayMs)
    fireCounter = fireCounter + 1
    local id = fireCounter
    local at = vector3(pos.x, pos.y, pos.z)
    SetTimeout(delayMs, function()
        TriggerClientEvent('thermite:StartFire', -1, id, at, 24, false, math.random(1, FIRE_MAX_COUNT))
        SetTimeout(math.random(FIRE_MIN_MS, FIRE_MAX_MS), function()
            TriggerClientEvent('thermite:StopFires', -1, id)
        end)
    end)
    return id
end

-- The client played the thermite challenge it got from thermite:server:check. Passed: the charge
-- burns through after the fuse and the station or gate goes; failed: it flares up at the player.
RegisterNetEvent('qb-bankrobbery:server:thermiteFinish', function()
    local src = source
    local used = thermiteUsed[src]
    thermiteUsed[src] = nil -- one finish per charge
    if not used then return end
    local passed = ChallengePassed(src, used.challengeId)
    if os.time() - used.at > THERMITE_MAX_SECONDS then passed = false end
    local pos = PlayerCoords(src)
    if used.station then
        if #(pos - Config.PowerStations[used.station].coords) > THERMITE_STATION_RANGE + 2.0 then passed = false end
    else
        local gate = Config.BigBanks[used.bank]['thermite'][used.gate]
        if #(pos - gate['coords']) > THERMITE_GATE_RANGE + 2.0 then passed = false end
    end
    StartFireSession(pos, passed and THERMITE_FUSE_MS or 0)
    TriggerClientEvent('qb-bankrobbery:client:thermiteResult', src, passed)
    if not passed then return end
    SetTimeout(THERMITE_FUSE_MS, function()
        if used.station then
            if GetCopCount() < (Config.MinimumThermitePolice or 0) then return end
            BlowStation(src, used.station)
        else
            OpenThermiteGate(src, used.bank, used.gate)
        end
    end)
end)

-- Callbacks

QBCore.Functions.CreateCallback('qb-bankrobbery:server:isRobberyActive', function(_, cb)
    cb(robberyBusy)
end)

QBCore.Functions.CreateCallback('qb-bankrobbery:server:GetConfig', function(_, cb)
    cb(Config.PowerStations, Config.BigBanks, Config.SmallBanks)
end)

-- A thermite charge is placed: the server finds what it is on (a station or a gate, from the player's
-- position), uses up the charge and hands out the challenge; thermiteFinish judges it. Returns the
-- challenge, or false when nothing can be burnt here.
QBCore.Functions.CreateCallback('thermite:server:check', function(source, cb)
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player then return cb(false) end
    local target = ThermiteTarget(source)
    if not target or GetCopCount() < (Config.MinimumThermitePolice or 0) then return cb(false) end
    if not HasItem(source, 'thermite') then return cb(false) end
    local ch = IssueChallenge(source, 'skillbar', {
        difficulty = (Config.ThermiteChallenge or {}).difficulty or 'medium', tag = 'bankrobbery:thermite',
    })
    if not ch then return cb(false) end
    if not exports['pfm-inventory']:RemoveItem(source, 'thermite', 1, false, 'thermite:server:check') then
        CancelChallenge(source, ch.id)
        return cb(false)
    end
    TriggerClientEvent('qb-inventory:client:ItemBox', source, sharedItems['thermite'], 'remove')
    if thermiteUsed[source] then CancelChallenge(source, thermiteUsed[source].challengeId) end
    thermiteUsed[source] = { station = target.station, bank = target.bank, gate = target.gate, at = os.time(), challengeId = ch.id }
    cb(ch)
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
