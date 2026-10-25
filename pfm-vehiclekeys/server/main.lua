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
end)

-----------------------
----   Threads     ----
-----------------------

-----------------------
---- Server Events ----
-----------------------

-- The citizen id owning this plate in player_vehicles, or nil (job, rental and NPC cars).
local function PlateOwner(plate)
    if type(plate) ~= 'string' or plate == '' then return nil end
    return MySQL.scalar.await('SELECT citizenid FROM player_vehicles WHERE plate = ? LIMIT 1', { plate })
end

--- True when `plate` is a player-owned car that belongs to someone other than this player.
local function IsSomeoneElsesCar(src, plate)
    local owner = PlateOwner(plate)
    if not owner then return false end
    local Player = exports['pfm-core']:GetPlayer(src)
    return not Player or Player.PlayerData.citizenid ~= owner
end

local function HasLockpick(src)
    for _, name in ipairs({ 'lockpick', 'advancedlockpick' }) do
        local ok, item = pcall(function() return exports['pfm-inventory']:GetItemByName(src, name) end)
        if ok and item then return true end
    end
    return false
end

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

RegisterNetEvent('qb-vehiclekeys:server:AcquireVehicleKeys', function(vehicleNetId)
    local src = source

    if IsOnAcquireCooldown(src) then return end

    -- Local compatibility: older scripts still send a plate string instead of a vehicle network id
    if type(vehicleNetId) == 'string' then
        local plate = Trim(vehicleNetId)
        if not plate or plate == '' then return end
        local Player = exports['pfm-core']:GetPlayer(src)
        if not Player then return end
        -- Plate strings are only honored when the player owns the vehicle or is sitting in a
        -- vehicle carrying that plate - otherwise any plate could be claimed remotely
        local owner = MySQL.scalar.await('SELECT citizenid FROM player_vehicles WHERE plate = ? LIMIT 1', { plate })
        if owner ~= Player.PlayerData.citizenid then
            local ped = GetPlayerPed(src)
            local pedVehicle = GetVehiclePedIsIn(ped, false)
            if pedVehicle == 0 or Trim(GetVehicleNumberPlateText(pedVehicle)) ~= plate then return end
        end
        GiveKeys(src, plate)
        return
    end

    if type(vehicleNetId) ~= 'number' then
        print('AcquireVehicleKeys: expected a vehicle network id. Server side grants should use the GiveKeys export.')
        return
    end

    local vehicle = NetworkGetEntityFromNetworkId(vehicleNetId)
    if not DoesEntityExist(vehicle) or GetEntityType(vehicle) ~= 2 then return end
    if #(GetEntityCoords(GetPlayerPed(src)) - GetEntityCoords(vehicle)) > 7.5 then return end

    local plate = Trim(GetVehicleNumberPlateText(vehicle))
    -- Another player's own car: only from its driver's seat (lockpicked from inside, or hotwired).
    -- (Standing next to any parked player car was enough to get its keys.)
    if IsSomeoneElsesCar(src, plate) and GetPedInVehicleSeat(vehicle, -1) ~= GetPlayerPed(src) then return end

    GiveKeys(src, plate)
end)

RegisterNetEvent('qb-vehiclekeys:server:RemoveVehicleKeys', function(plate)
    local src = source
    local hasKey = HasKeys(src, plate)
    if not hasKey then return end

    RemoveKeys(src, plate)
end)

RegisterNetEvent('qb-vehiclekeys:server:breakLockpick', function(itemName)
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player then return end
    if not (itemName == 'lockpick' or itemName == 'advancedlockpick') then return end
    if exports['pfm-inventory']:RemoveItem(source, itemName, 1, false, 'qb-vehiclekeys:server:breakLockpick') then
        TriggerClientEvent('qb-inventory:client:ItemBox', source, sharedItems[itemName], 'remove')
    end
end)

RegisterNetEvent('qb-vehiclekeys:server:setVehLockState', function(vehNetId, state)
    local src = source
    if type(vehNetId) ~= 'number' then return end
    state = tonumber(state)
    if state ~= 1 and state ~= 2 then return end
    local vehicle = NetworkGetEntityFromNetworkId(vehNetId)
    if not DoesEntityExist(vehicle) or GetEntityType(vehicle) ~= 2 then return end
    if #(GetEntityCoords(GetPlayerPed(src)) - GetEntityCoords(vehicle)) > 20.0 then return end
    -- Another player's own car: its keys, or (to unlock) a lockpick. (Anyone could lock or unlock any
    -- player's car from 20m.)
    local plate = Trim(GetVehicleNumberPlateText(vehicle))
    if not HasKeys(src, plate) and IsSomeoneElsesCar(src, plate) then
        if state ~= 1 or not HasLockpick(src) then return end
    end
    SetVehicleDoorsLocked(vehicle, state)
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

function GiveKeys(id, plate)
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

    local oldKeys = Player.PlayerData.metadata['vehicleKeys'] or {}
    oldKeys[plate] = true
    Player.SetMetaData('vehicleKeys', oldKeys)

    TriggerClientEvent('QBCore:Notify', id, Lang:t('notify.vgetkeys'))
    TriggerClientEvent('qb-vehiclekeys:client:AddKeys', id, plate)
end

exports('GiveKeys', GiveKeys)

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
