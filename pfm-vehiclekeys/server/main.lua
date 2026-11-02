-----------------------
----   Variables   ----
-----------------------
local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions', 'Commands' })
local sharedItems = exports['pfm-core']:GetShared('Items')

local function Trim(value)
    return value and value:match('^%s*(.-)%s*$') or value
end

local VehicleList = {}
local acquireCooldowns = {} -- per-source cooldown for lockpick/hotwire key acquisition
local tempKeyTokens = {}    -- tracks active temporary key grants so expiry can be cancelled
local pickAttempts = {}     -- [src] = the open lockpick / hotwire attempt (startPick / finishPick)
local lastPickStart = {}    -- [src] = GetGameTimer() of the last attempt started
local lastAlert = {}        -- [src] = GetGameTimer() of the last police alert this player caused

local SEAT_SYNC_MS = 2000   -- a seat or plate a client just set reaches the server a moment later

local function IsOnAcquireCooldown(src)
    local cooldown = Config.AcquireKeysCooldown or 2000
    if cooldown <= 0 then return false end
    local now = GetGameTimer()
    local last = acquireCooldowns[src]
    if last and (now - last) < cooldown then return true end
    acquireCooldowns[src] = now
    return false
end

AddEventHandler('playerDropped', function()
    acquireCooldowns[source] = nil
    pickAttempts[source] = nil
    lastPickStart[source] = nil
    lastAlert[source] = nil
end)

-----------------------
----   Helpers     ----
-----------------------

-- The citizen id owning this plate in player_vehicles, or nil (job, rental and NPC cars).
local function PlateOwner(plate)
    if type(plate) ~= 'string' or plate == '' then return nil end
    return MySQL.scalar.await('SELECT citizenid FROM player_vehicles WHERE plate = ? LIMIT 1', { plate })
end

local function CitizenId(src)
    local Player = exports['pfm-core']:GetPlayer(src)
    return Player and Player.PlayerData.citizenid or nil
end

local function Holds(src, name)
    if not name then return false end
    local ok, item = pcall(function() return exports['pfm-inventory']:GetItemByName(src, name) end)
    return ok and item ~= nil
end

local function IsDriver(src, vehicle)
    return GetPedInVehicleSeat(vehicle, -1) == GetPlayerPed(src)
end

local function NpcDriver(vehicle)
    local driver = GetPedInVehicleSeat(vehicle, -1)
    return driver ~= 0 and not IsPedAPlayer(driver)
end

--- Polls `fn` for up to `ms`: a seat or plate a client has just set reaches the server a little later.
local function WaitFor(fn, ms)
    local waited = 0
    while not fn() do
        if waited >= ms then return false end
        Wait(100)
        waited = waited + 100
    end
    return true
end

local function SameModel(vehicle, name)
    return (GetEntityModel(vehicle) & 0xFFFFFFFF) == (joaat(name) & 0xFFFFFFFF)
end

--- Config.SharedKeys checked on the server: this player's job shares keys to this vehicle's model.
local function JobSharesKeys(src, vehicle)
    local Player = exports['pfm-core']:GetPlayer(src)
    local job = Player and Player.PlayerData.job
    local rule = job and Config.SharedKeys[job.name]
    if not rule or (rule.requireOnduty and not job.onduty) then return false end
    for _, model in pairs(rule.vehicles or {}) do
        if SameModel(vehicle, model) then return true end
    end
    return false
end

local function IsOnDutyPolice(src)
    local Player = exports['pfm-core']:GetPlayer(src)
    local job = Player and Player.PlayerData.job
    return job ~= nil and job.type == 'leo' and job.onduty == true
end

-- A pf-jobgarages fleet car is a manager's own car that an employee signed out: lent to them.
local fleetTable = nil -- true / false once looked up
local function FleetCarSignedOutTo(citizenid, plate)
    if not citizenid or fleetTable == false then return false end
    local ok, lent = pcall(function()
        if fleetTable == nil then
            local n = MySQL.scalar.await("SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'job_garage_vehicles'")
            if n == nil then return false end
            fleetTable = (tonumber(n) or 0) > 0
            -- "no table" is asked again later (the resource may be installed meanwhile)
            if not fleetTable then SetTimeout(300000, function() fleetTable = nil end) end
        end
        if not fleetTable then return false end
        return MySQL.scalar.await('SELECT 1 FROM job_garage_vehicles WHERE plate = ? AND active = 1 AND `out` = 1 AND out_citizenid = ? LIMIT 1', { plate, citizenid }) ~= nil
    end)
    return ok and lent == true
end

-- Vehicles nobody locks: bicycles, Config.NoLockVehicles and vehicles a script marked ignoreLocks.
local BICYCLES = { 'bmx', 'cruiser', 'fixter', 'scorcher', 'tribike', 'tribike2', 'tribike3', 'inductor', 'inductor2' }
local function IsNoLockVehicle(vehicle)
    for _, list in ipairs({ BICYCLES, Config.NoLockVehicles or {} }) do
        for _, model in pairs(list) do
            if SameModel(vehicle, model) then return true end
        end
    end
    local ok, ignore = pcall(function() return Entity(vehicle).state.ignoreLocks end)
    return ok and ignore == true
end

--- True when another character holds keys to this plate this session (someone's job or rental car).
local function KeysHeldByOthers(citizenid, plate)
    for holder in pairs(VehicleList[plate] or {}) do
        if holder ~= citizenid then return true end
    end
    return false
end

--- The vehicle behind a client's network id, with its plate as the server sees it.
local function VehicleFromNet(netId)
    if type(netId) ~= 'number' then return nil end
    local vehicle = NetworkGetEntityFromNetworkId(netId)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) or GetEntityType(vehicle) ~= 2 then return nil end
    return vehicle, Trim(GetVehicleNumberPlateText(vehicle))
end

local function DistanceTo(src, vehicle)
    return #(GetEntityCoords(GetPlayerPed(src)) - GetEntityCoords(vehicle))
end

-----------------------
---- Server Events ----
-----------------------

-- Event to give keys. receiver can either be a single id, or a table of ids.
-- Must already have keys to the vehicle, or trigger the event from the server (pf-jobs and
-- pf-mechanicjob do: those grants were refused, as the server is not a player with keys).
-- A player gives keys to people next to them.
RegisterNetEvent('qb-vehiclekeys:server:GiveVehicleKeys', function(receiver, plate)
    local giver = source

    if type(plate) ~= 'string' then return end

    local fromServer = type(giver) ~= 'number' or giver <= 0
    if fromServer then
        if type(receiver) == 'table' then
            for _, r in ipairs(receiver) do GiveKeys(tonumber(r), plate) end
        else
            GiveKeys(tonumber(receiver), plate)
        end
        return
    end

    if HasKeys(giver, plate) then
        local giverCoords = GetEntityCoords(GetPlayerPed(giver))
        local function giveNear(r)
            r = tonumber(r)
            if not r or not exports['pfm-core']:GetPlayer(r) then return end
            if #(giverCoords - GetEntityCoords(GetPlayerPed(r))) > 10.0 then return end
            GiveKeys(r, plate)
        end
        TriggerClientEvent('QBCore:Notify', giver, Lang:t('notify.vgkeys'), 'success')
        if type(receiver) == 'table' then
            for i, r in ipairs(receiver) do
                if i > 16 then break end
                giveNear(r)
            end
        else
            giveNear(receiver)
        end
    else
        TriggerClientEvent('QBCore:Notify', giver, Lang:t('notify.ydhk'), 'error')
    end
end)

-- Keys a client asks for itself (vehiclekeys:client:SetOwner from spawning scripts, an NPC car
-- jacked or taken from a dead driver, job-shared cars). Given for:
--   * the player's own car (player_vehicles), or a fleet car signed out to them;
--   * a job vehicle their job shares (Config.SharedKeys);
--   * a car without an owner (job, rental, NPC car) from its driver's seat, or while an NPC still
--     sits at its wheel (carjacked, dead driver).
-- Never for another player's car (only a finished lockpick or hotwire below, or keys handed over),
-- except on-duty police at its wheel (Config.PoliceTakeKeys: impound releases). (Standing next to
-- any car gave its keys, and a plate string gave keys from any seat of a car with that plate.)
RegisterNetEvent('qb-vehiclekeys:server:AcquireVehicleKeys', function(vehicleNetId, expectedPlate)
    local src = source

    if IsOnAcquireCooldown(src) then return end
    local cid = CitizenId(src)
    if not cid then return end

    -- Local compatibility: older scripts still send a plate string instead of a vehicle network id
    if type(vehicleNetId) == 'string' then
        local plate = Trim(vehicleNetId)
        if not plate or plate == '' or #plate > 16 then return end
        local owner = PlateOwner(plate)
        if owner == cid or FleetCarSignedOutTo(cid, plate) then
            GiveKeys(src, plate)
            return
        end
        if owner then return end -- someone else's car
        -- no owner: only the driver of a car carrying that plate
        local pedVehicle = GetVehiclePedIsIn(GetPlayerPed(src), false)
        if pedVehicle == 0 or Trim(GetVehicleNumberPlateText(pedVehicle)) ~= plate or not IsDriver(src, pedVehicle) then return end
        GiveKeys(src, plate)
        return
    end

    if type(vehicleNetId) ~= 'number' then
        print('AcquireVehicleKeys: expected a vehicle network id. Server side grants should use the GiveKeys export.')
        return
    end

    local vehicle = VehicleFromNet(vehicleNetId)
    -- a car the client has just spawned may not have reached the server yet
    if not vehicle and not WaitFor(function() vehicle = VehicleFromNet(vehicleNetId) return vehicle ~= nil end, SEAT_SYNC_MS) then return end
    -- the client may have just set the plate: wait for the server to see it (the server's own
    -- reading is what counts; the client's text only says what to wait for)
    if type(expectedPlate) == 'string' and #expectedPlate <= 16 then
        local want = Trim(expectedPlate)
        WaitFor(function() return Trim(GetVehicleNumberPlateText(vehicle)) == want end, SEAT_SYNC_MS)
    end
    local plate = Trim(GetVehicleNumberPlateText(vehicle))
    if not plate or plate == '' then return end

    local owner = PlateOwner(plate)
    if owner == cid or FleetCarSignedOutTo(cid, plate) then
        GiveKeys(src, plate)
        return
    end
    if DistanceTo(src, vehicle) > 7.5 then return end
    if owner then
        if Config.PoliceTakeKeys and IsOnDutyPolice(src) and WaitFor(function() return IsDriver(src, vehicle) end, SEAT_SYNC_MS) then
            GiveKeys(src, plate)
        end
        return
    end
    if JobSharesKeys(src, vehicle) or NpcDriver(vehicle) or WaitFor(function() return IsDriver(src, vehicle) end, SEAT_SYNC_MS) then
        GiveKeys(src, plate)
    end
end)

RegisterNetEvent('qb-vehiclekeys:server:RemoveVehicleKeys', function(plate)
    local src = source
    local hasKey = HasKeys(src, plate)
    if not hasKey then return end

    RemoveKeys(src, plate)
end)

-- Kept for old clients and does nothing: lockpicks break on the server at the end of each attempt.
-- (A client that never sent this kept its lockpick forever.)
RegisterNetEvent('qb-vehiclekeys:server:breakLockpick', function() end)

-- Locks a player may change without the keys: their own car; an ownerless car nobody else holds
-- keys to, as Config.LockNPC* sets NPC cars (the client locks them as it approaches); an NPC-driven
-- car being jacked (unlock); vehicles that never lock (unlock). Never another player's car.
local function MayChangeLocksWithoutKeys(src, vehicle, plate, state)
    local cid = CitizenId(src)
    local owner = PlateOwner(plate)
    if owner then return owner == cid end
    if JobSharesKeys(src, vehicle) or FleetCarSignedOutTo(cid, plate) then return true end
    if IsNoLockVehicle(vehicle) then return state == 1 end
    if KeysHeldByOthers(cid, plate) then return false end
    local driver = GetPedInVehicleSeat(vehicle, -1)
    if driver ~= 0 then
        if IsPedAPlayer(driver) then return false end
        return state == 1 or Config.LockNPCDrivingCars == true
    end
    if state == 2 then return Config.LockNPCParkedCars == true end
    return Config.LockNPCParkedCars ~= true
end

RegisterNetEvent('qb-vehiclekeys:server:setVehLockState', function(vehNetId, state)
    local src = source
    state = tonumber(state)
    if state ~= 1 and state ~= 2 then return end
    local vehicle, plate = VehicleFromNet(vehNetId)
    if not vehicle then return end
    if DistanceTo(src, vehicle) > 20.0 then return end
    -- (Anyone could lock or unlock any player's car from 20m, and holding a lockpick unlocked it.)
    if not HasKeys(src, plate) and not MayChangeLocksWithoutKeys(src, vehicle, plate, state) then return end
    SetVehicleDoorsLocked(vehicle, state)
end)

-----------------------
---- Lockpick / hotwire attempts
-----------------------
-- Lockpick: startPick checks the player is next to the car with a lockpick and hands the client a
-- skillbar challenge (pfm-minigames). finishPick unlocks the car (or, from the driver's seat, gives
-- its keys) only when that challenge passed in time; the pick may break either way (rolled here).
-- Hotwire: startPick checks the player sits at the wheel and sets the time it takes; finishPick
-- after that time rolls Config.HotwireChance here. Police alerts are raised here too.
-- (The client decided all of it: success, the hotwire chance, whether the pick broke and whether
-- police heard of it.)

local function Notify(src, text, kind)
    TriggerClientEvent('QBCore:Notify', src, text, kind)
end

local function PickItem(src, wantAdvanced)
    if wantAdvanced and Holds(src, 'advancedlockpick') then return 'advancedlockpick' end
    if Holds(src, 'lockpick') then return 'lockpick' end
    if Holds(src, 'advancedlockpick') then return 'advancedlockpick' end
    return nil
end

local function IsNight()
    local ok, hour = pcall(function() return exports['pfm-weathersync']:getTime() end)
    hour = ok and tonumber(hour) or nil
    return hour ~= nil and hour >= 1 and hour <= 6
end

--- A police alert at the thief's position (chance and cooldown from config), sent from the server.
local function PoliceAlert(src, kind)
    local now = GetGameTimer()
    if lastAlert[src] and now - lastAlert[src] < (Config.AlertCooldown or 10000) then return end
    lastAlert[src] = now
    local chance = IsNight() and Config.PoliceNightAlertChance or Config.PoliceAlertChance
    if math.random() > (chance or 0) then return end
    local coords = GetEntityCoords(GetPlayerPed(src))
    local text = Lang:t('info.palert') .. kind
    for _, Player in pairs(QBCore.Functions.GetQBPlayers()) do
        local job = Player and Player.PlayerData.job
        if job and job.type == 'leo' and job.onduty then
            local target = Player.PlayerData.source
            TriggerClientEvent('qb-phone:client:addPoliceAlert', target, { title = text, coords = { x = coords.x, y = coords.y, z = coords.z }, description = text })
            TriggerClientEvent('police:client:policeAlert', target, coords, text)
        end
    end
end

local function BreakChance(item)
    return item == 'advancedlockpick' and Config.RemoveLockpickAdvanced or Config.RemoveLockpickNormal
end

--- The pick may break at the end of every attempt, passed or not (as before), removed here.
local function RollBreak(src, item)
    if not Holds(src, item) or math.random() > (BreakChance(item) or 0) then return end
    if exports['pfm-inventory']:RemoveItem(src, item, 1, false, 'qb-vehiclekeys:lockpick') then
        TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems[item], 'remove')
    end
end

--- Keys won by lockpick or hotwire. Another player's car: kept until restart only, unless
--- Config.PersistStolenKeys (the thief used to keep keys to the victim's car forever).
local function GiveStolenKeys(src, plate)
    local owner = PlateOwner(plate)
    if owner and owner ~= CitizenId(src) and not Config.PersistStolenKeys then
        GiveKeys(src, plate, false)
    else
        GiveKeys(src, plate)
    end
end

local function LockpickMaxMs() return Config.LockpickMaxTime or 60000 end
local function HotwireMaxMs(attempt) return attempt.duration + 20000 end

local function CancelChallenge(src, attempt)
    if not attempt.challengeId then return end
    pcall(function() exports['pfm-minigames']:Cancel(src, attempt.challengeId) end)
end

--- An attempt that ends without a passed finish (replaced by a new one or never finished).
local function AbandonAttempt(src, attempt)
    CancelChallenge(src, attempt)
    if attempt.kind == 'lockpick' then
        RollBreak(src, attempt.item)
        PoliceAlert(src, 'steal')
    end
end

RegisterNetEvent('qb-vehiclekeys:server:startPick', function(vehNetId, kind, wantAdvanced)
    local src = source
    if kind ~= 'lockpick' and kind ~= 'hotwire' then return end
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    local meta = Player.PlayerData.metadata or {}
    if meta.isdead or meta.inlaststand or meta.ishandcuffed then return end
    local now = GetGameTimer()
    if lastPickStart[src] and now - lastPickStart[src] < (Config.PickStartCooldown or 2000) then return end
    local vehicle, plate = VehicleFromNet(vehNetId)
    if not vehicle or not plate or plate == '' or HasKeys(src, plate) then return end

    local attempt = { netId = vehNetId, vehicle = vehicle, plate = plate, kind = kind, at = now }
    if kind == 'lockpick' then
        if DistanceTo(src, vehicle) > (Config.LockpickDistance or 3.0) then return end
        attempt.item = PickItem(src, wantAdvanced == true)
        if not attempt.item then return end
    else
        if not IsDriver(src, vehicle) then return end
        local lo = math.floor(Config.minHotwireTime or 20000)
        attempt.duration = math.random(lo, math.max(lo, math.floor(Config.maxHotwireTime or lo)))
    end
    lastPickStart[src] = now

    -- a new attempt ends the open one (a lockpick cannot be restarted to dodge the breakage)
    local open = pickAttempts[src]
    if open then
        pickAttempts[src] = nil
        AbandonAttempt(src, open)
    end

    local data = { duration = attempt.duration }
    if kind == 'lockpick' then
        local ok, challenge = pcall(function()
            return exports['pfm-minigames']:IssueChallenge(src, 'skillbar', {
                difficulty = attempt.item == 'advancedlockpick' and 'easy' or 'medium', tag = 'vehiclekeys:' .. plate,
            })
        end)
        if not ok or type(challenge) ~= 'table' or type(challenge.id) ~= 'string' then return end
        attempt.challengeId = challenge.id
        data.challenge = challenge
    end
    pickAttempts[src] = attempt

    local maxMs = kind == 'lockpick' and LockpickMaxMs() or HotwireMaxMs(attempt)
    SetTimeout(maxMs + 1000, function()
        if pickAttempts[src] ~= attempt then return end
        pickAttempts[src] = nil
        AbandonAttempt(src, attempt)
    end)
    -- as before: police may hear of a hotwire 10 s in, whatever its outcome
    if kind == 'hotwire' then SetTimeout(10000, function() PoliceAlert(src, 'steal') end) end
    TriggerClientEvent('qb-vehiclekeys:client:pickStarted', src, vehNetId, kind, data)
end)

RegisterNetEvent('qb-vehiclekeys:server:finishPick', function(vehNetId)
    local src = source
    local attempt = pickAttempts[src]
    if not attempt or attempt.netId ~= vehNetId then return end
    pickAttempts[src] = nil -- one finish per attempt

    local elapsed = GetGameTimer() - attempt.at
    local vehicle, plate = VehicleFromNet(vehNetId)
    local same = vehicle == attempt.vehicle and plate == attempt.plate

    if attempt.kind == 'lockpick' then
        local ok, passed = pcall(function() return exports['pfm-minigames']:Verify(src, attempt.challengeId) end)
        passed = ok and passed == true
        local inTime = elapsed >= (Config.LockpickMinTime or 2000) and elapsed <= LockpickMaxMs()
        if passed and inTime and same and DistanceTo(src, vehicle) <= (Config.LockpickDistance or 3.0) + 1.0 and Holds(src, attempt.item) then
            if IsDriver(src, vehicle) then
                GiveStolenKeys(src, plate)
            else
                SetVehicleDoorsLocked(vehicle, 1)
                Notify(src, Lang:t('notify.vlockpick'), 'success')
            end
        else
            PoliceAlert(src, 'steal')
        end
        RollBreak(src, attempt.item)
        return
    end

    -- hotwire: the full time at the wheel, then the chance
    local inTime = elapsed >= attempt.duration - 500 and elapsed <= HotwireMaxMs(attempt)
    if inTime and same and IsDriver(src, vehicle) and math.random() <= (Config.HotwireChance or 0) then
        GiveStolenKeys(src, plate)
    else
        Notify(src, Lang:t('notify.fvlockpick'), 'error')
    end
end)

-- A hotwire may be stopped at no cost (as before). A lockpick attempt cannot be cancelled: left
-- open it fails at its deadline and the pick may break.
RegisterNetEvent('qb-vehiclekeys:server:cancelPick', function()
    local src = source
    local attempt = pickAttempts[src]
    if attempt and attempt.kind == 'hotwire' then pickAttempts[src] = nil end
end)

QBCore.Functions.CreateCallback('qb-vehiclekeys:server:GetVehicleKeys', function(source, cb)
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player then return cb({}) end
    local citizenid = Player.PlayerData.citizenid
    local keysList = {}
    for plate, citizenids in pairs(VehicleList) do
        if citizenids[citizenid] then
            keysList[plate] = true
        end
    end
    if Player.PlayerData.metadata['vehicleKeys'] and Config.PersistentKeys then
        for plate in pairs(Player.PlayerData.metadata['vehicleKeys']) do
            keysList[plate] = true
        end
    end
    cb(keysList)
end)

QBCore.Functions.CreateCallback('qb-vehiclekeys:server:checkPlayerOwned', function(_, cb, plate)
    local playerOwned = false
    if VehicleList[plate] then
        playerOwned = true
    end
    cb(playerOwned)
end)

-----------------------
----   Functions   ----
-----------------------

--- Gives `id` keys to `plate`. persist = false keeps them for this session only (not saved in
--- the character's metadata).
function GiveKeys(id, plate, persist)
    local Player = exports['pfm-core']:GetPlayer(id)
    if not Player then return end
    local citizenid = Player.PlayerData.citizenid

    if not plate then
        if GetVehiclePedIsIn(GetPlayerPed(id), false) ~= 0 then
            plate = Trim(GetVehicleNumberPlateText(GetVehiclePedIsIn(GetPlayerPed(id), false)))
        else
            return
        end
    end

    if not VehicleList[plate] then VehicleList[plate] = {} end
    VehicleList[plate][citizenid] = true

    -- A full (permanent) grant cancels any pending temporary-key expiry for this player/plate
    tempKeyTokens[citizenid .. ':' .. plate] = nil

    if persist ~= false then
        local oldKeys = Player.PlayerData.metadata['vehicleKeys'] or {}
        oldKeys[plate] = true
        Player.SetMetaData('vehicleKeys', oldKeys)
    end

    TriggerClientEvent('QBCore:Notify', id, Lang:t('notify.vgetkeys'))
    TriggerClientEvent('qb-vehiclekeys:client:AddKeys', id, plate)
end

exports('GiveKeys', function(id, plate) return GiveKeys(id, plate) end)

function RemoveKeys(id, plate)
    local Player = exports['pfm-core']:GetPlayer(id)
    if not Player then return end
    local citizenid = Player.PlayerData.citizenid

    if VehicleList[plate] and VehicleList[plate][citizenid] then
        VehicleList[plate][citizenid] = nil
    end

    local oldKeys = Player.PlayerData.metadata['vehicleKeys'] or {}
    oldKeys[plate] = nil
    Player.SetMetaData('vehicleKeys', oldKeys)

    TriggerClientEvent('qb-vehiclekeys:client:RemoveKeys', id, plate)
end

exports('RemoveKeys', RemoveKeys)

function HasKeys(id, plate)
    local Player = exports['pfm-core']:GetPlayer(id)
    if not Player then return false end
    local citizenid = Player.PlayerData.citizenid

    if VehicleList[plate] and VehicleList[plate][citizenid] then
        return true
    end

    if Player.PlayerData.metadata['vehicleKeys'] and Config.PersistentKeys and Player.PlayerData.metadata['vehicleKeys'][plate] then
        return true
    end

    return false
end

exports('HasKeys', HasKeys)

-- Gives keys that automatically expire after durationMs (falls back to
-- Config.TemporaryKeysDuration; 0 = feature disabled). Returns true when keys were given.
function GiveTemporaryKeys(src, plate, durationMs)
    local duration = tonumber(durationMs) or Config.TemporaryKeysDuration or 0
    if duration <= 0 then return false end
    if type(plate) ~= 'string' or plate == '' then return false end

    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return false end
    local citizenid = Player.PlayerData.citizenid
    plate = Trim(plate)

    GiveKeys(src, plate)

    local tokenKey = citizenid .. ':' .. plate
    local token = {}
    tempKeyTokens[tokenKey] = token

    SetTimeout(math.floor(duration), function()
        -- Only expire if this grant is still the active one (not cancelled or replaced)
        if tempKeyTokens[tokenKey] ~= token then return end
        tempKeyTokens[tokenKey] = nil
        local CurrentPlayer = exports['pfm-core']:GetPlayerByCitizenId(citizenid)
        if CurrentPlayer then
            RemoveKeys(CurrentPlayer.PlayerData.source, plate)
        elseif VehicleList[plate] then
            VehicleList[plate][citizenid] = nil
        end
    end)

    return true
end

exports('GiveTemporaryKeys', GiveTemporaryKeys)

QBCore.Commands.Add('givekeys', Lang:t('addcom.givekeys'), { { name = Lang:t('addcom.givekeys_id'), help = Lang:t('addcom.givekeys_id_help') } }, false, function(source, args)
    local src = source
    TriggerClientEvent('qb-vehiclekeys:client:GiveKeys', src, tonumber(args[1]))
end)

QBCore.Commands.Add('addkeys', Lang:t('addcom.addkeys'), { { name = Lang:t('addcom.addkeys_id'), help = Lang:t('addcom.addkeys_id_help') }, { name = Lang:t('addcom.addkeys_plate'), help = Lang:t('addcom.addkeys_plate_help') } }, true, function(source, args)
    local src = source
    if not args[1] or not args[2] then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('notify.fpid'))
        return
    end
    GiveKeys(tonumber(args[1]), args[2])
end, 'admin')

QBCore.Commands.Add('removekeys', Lang:t('addcom.rkeys'), { { name = Lang:t('addcom.rkeys_id'), help = Lang:t('addcom.rkeys_id_help') }, { name = Lang:t('addcom.rkeys_plate'), help = Lang:t('addcom.rkeys_plate_help') } }, true, function(source, args)
    local src = source
    if not args[1] or not args[2] then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('notify.fpid'))
        return
    end
    RemoveKeys(tonumber(args[1]), args[2])
end, 'admin')
