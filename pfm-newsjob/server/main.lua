-- Weazel News field work: the news van and helicopter, the camera / mic / boom mic, the duty point
-- at the office. Connected to the newsroom (pf-news): reporters go on duty here to claim leads, and
-- the newsroom shows who is out with a news vehicle (GetFieldStatus).
--
-- Nothing a client sends is trusted: the job, duty and grade come from the server player. The
-- server spawns the news vehicle itself, for a model that grade may take at that garage while the
-- reporter stands at it, sets the plate, and stocks the van's trunk right then (once per issued van).
-- The camera and mics are issued per reporter, not per van: player metadata 'newsgear' records what
-- was handed out and when, a van's trunk only gets the pieces that reporter has not been issued and
-- does not carry, and storing the van, going off duty or leaving the job hands the gear back (taken
-- from the trunk and the reporter). Gear not handed back blocks a new issue for Config.GearResetHours.
-- The 'one vehicle at a time' lock follows the server entity: it is freed when the server deletes
-- the vehicle at its garage (the client only asks), when the entity is gone (cleaned up, despawned),
-- when it is a wreck (the server deletes the wreck on the next request), or when the spawn fails.

local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions', 'Commands' })

NewsJob = NewsJob or {}
local Issued = {}        -- src -> { plate, model, label, location, citizenid, at, entity, pending, stocked }
local StockedTrunks = {} -- plate -> true (the trunk of an issued van is stocked once)
local LastRequest = {}   -- src -> os.time()
local LastDuty = {}      -- src -> os.time()

local function reporter(src)
    local Player = QBCore.Functions.GetPlayer(src)
    local job = Player and Player.PlayerData and Player.PlayerData.job
    if not job or job.name ~= Config.Job then return nil end
    return Player, job
end

local function onDutyReporter(src)
    local Player, job = reporter(src)
    if not Player or not job.onduty then return nil end
    return Player, job
end

local function gradeOf(job)
    return tonumber(type(job.grade) == 'table' and job.grade.level or job.grade) or 0
end

local function near(src, coords, range)
    local p = GetEntityCoords(GetPlayerPed(src))
    return #(vector3(p.x, p.y, p.z) - vector3(coords.x, coords.y, coords.z)) <= range
end

--- The vehicle a grade may take at a garage: its definition, or nil.
function NewsJob.VehicleFor(location, grade, model)
    local garage = type(location) == 'string' and Config.Locations[location] or nil
    if not garage or not garage.vehicles or type(model) ~= 'string' then return nil end
    -- the highest configured grade at or below the player's grade
    local best
    for g in pairs(garage.vehicles) do
        local n = tonumber(g)
        if n and n <= grade and (not best or n > best) then best = n end
    end
    local list = best and garage.vehicles[best] or nil
    return list and list[model] or nil
end

local function newPlate()
    for _ = 1, 20 do
        local plate = ('WZNW%04d'):format(math.random(0, 9999))
        local taken = false
        for _, v in pairs(Issued) do if v.plate == plate then taken = true break end end
        if not taken then return plate end
    end
    return ('WZ%06d'):format(os.time() % 1000000)
end

local function dist(a, b)
    return #(vector3(a.x, a.y, a.z) - vector3(b.x, b.y, b.z))
end

--- True when the issued vehicle no longer exists on the server (destroyed and cleaned up, despawned).
local function vehicleGone(rec)
    if rec.pending then return false end
    return not rec.entity or rec.entity == 0 or not DoesEntityExist(rec.entity)
end

--- True when the issued vehicle still exists but is a wreck (blown up / burnt out). The server spawns
--- it as a script entity, so the game does not clean the wreck up, and nobody can sit in it to store it.
--- An exploded vehicle has its engine health set to -4000 (synced from the owner to the server).
local function vehicleWrecked(rec)
    if rec.pending or vehicleGone(rec) or type(GetVehicleEngineHealth) ~= 'function' then return false end
    local ok, health = pcall(GetVehicleEngineHealth, rec.entity)
    return ok and type(health) == 'number' and health <= (Config.WreckedEngineHealth or -3999.0)
end

-- ── field gear (camera, mic, boom mic) ──────────────────────────────
local GEAR_REASON = 'pfm-newsjob:gear'

local function gearReset() return (tonumber(Config.GearResetHours) or 24) * 3600 end

--- The gear issued to a reporter: { [item] = os.time() it was issued }.
local function gearOf(Player)
    local g = Player and Player.PlayerData.metadata and Player.PlayerData.metadata.newsgear
    local out = {}
    if type(g) == 'table' then
        for name, at in pairs(g) do if type(name) == 'string' and tonumber(at) then out[name] = tonumber(at) end end
    end
    return out
end

local function setGear(src, gear)
    local Player = QBCore.Functions.GetPlayer(src)
    if Player then Player.Functions.SetMetaData('newsgear', gear) end
end

-- How many of `name` src carries; nil when the inventory cannot be asked (nothing is issued then).
local function carried(src, name)
    local ok, n = pcall(function() return exports['pfm-inventory']:GetItemCount(src, name) end)
    if not ok then return nil end
    return tonumber(n) or 0
end

--- Hands the issued gear back: what is still in the van's trunk goes back with the van, and with
--- takeCarried what the reporter carries is taken from them. Only issued pieces are touched.
local function returnGear(src, rec, takeCarried)
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local gear = gearOf(Player)
    local changed = false
    if rec and rec.stocked then
        local ok, inv = pcall(function() return exports['pfm-inventory']:GetInventory('trunk-' .. rec.plate) end)
        for _, it in pairs(ok and type(inv) == 'table' and type(inv.items) == 'table' and inv.items or {}) do
            if type(it) == 'table' and gear[it.name] then gear[it.name], changed = nil, true end
        end
    end
    if takeCarried then
        for _, item in pairs(Config.VehicleItems) do
            if gear[item.name] then
                local n = carried(src, item.name) or 0
                local back = 0
                for _ = 1, n do
                    local ok, removed = pcall(function() return exports['pfm-inventory']:RemoveItem(src, item.name, 1, false, GEAR_REASON) end)
                    if ok and removed then back = back + 1 end
                end
                if n > 0 and back == n then gear[item.name], changed = nil, true end
            end
        end
    end
    if changed then setGear(src, gear) end
end

--- Ends the field assignment of `src`: frees the lock and drops the issued van's trunk (the gear
--- still in it goes back with it). With takeCarried the reporter hands in the gear they carry too.
local function release(src, takeCarried)
    local rec = Issued[src]
    Issued[src] = nil
    if rec and rec.stocked then
        returnGear(src, rec, false)
        StockedTrunks[rec.plate] = nil
        pcall(function() exports['pfm-inventory']:RemoveInventory('trunk-' .. rec.plate) end)
    end
    if takeCarried then returnGear(src, nil, true) end
end

--- True when the issued vehicle still exists but the reporter left it far away (stolen, sunk,
--- stuck, flipped): they are not in it and it is more than Config.AbandonRange from them.
local function vehicleAbandoned(src, rec)
    if rec.pending or vehicleGone(rec) then return false end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    if GetVehiclePedIsIn(ped, false) == rec.entity then return false end
    local ok, far = pcall(function() return dist(GetEntityCoords(ped), GetEntityCoords(rec.entity)) > (Config.AbandonRange or 50.0) end)
    return ok and far == true
end

--- Frees the lock of `src` when the issued vehicle is gone, or is a wreck (the server deletes the
--- wreck and tells the client to drop its keys). With `requesting` (a new vehicle is asked for at the
--- garage), a vehicle left far away is retired the same way, so a stolen or sunk van cannot lock the
--- reporter out. Returns true when the lock was freed.
local function retireLostVehicle(src, requesting)
    local rec = Issued[src]
    if not rec or rec.pending then return false end
    if vehicleGone(rec) then
        release(src)
        return true
    end
    if vehicleWrecked(rec) or (requesting and vehicleAbandoned(src, rec)) then
        release(src)
        DeleteEntity(rec.entity)
        TriggerClientEvent('pfm-newsjob:client:vehicleStored', src, rec.plate)
        return true
    end
    return false
end

--- Stocks the trunk of a van the server has just spawned for `rec` (once per issued van) with the
--- gear its reporter has not been issued and does not carry. Returns the items put in.
local function stockTrunk(rec, src)
    if rec.stocked or StockedTrunks[rec.plate] then return nil end
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return nil end
    rec.stocked = true
    StockedTrunks[rec.plate] = true
    exports['pfm-inventory']:CreateInventory('trunk-' .. rec.plate)
    local gear, now, put = gearOf(Player), os.time(), {}
    for slot, item in pairs(Config.VehicleItems) do
        local since = gear[item.name]
        local out = since ~= nil and now - since < gearReset() -- issued and not handed back yet
        if not out and carried(src, item.name) == 0 then
            local ok, added = pcall(function()
                return exports['pfm-inventory']:AddItem('trunk-' .. rec.plate, item.name, item.amount, slot, item.info, 'pfm-newsjob:vehicleItems')
            end)
            if ok and added then
                gear[item.name] = now
                put[#put + 1] = item.name
            end
        end
    end
    if #put > 0 then setGear(src, gear) end
    return put
end

--- A reporter on duty at a garage asks for a vehicle; the server spawns it. Returns ok, err (also used by tests).
function NewsJob.RequestVehicle(src, location, model)
    local Player, job = onDutyReporter(src)
    if not Player then return false, 'not_on_duty' end
    if type(location) ~= 'string' or type(model) ~= 'string' or #model > 32 then return false, 'bad_request' end
    local garage = Config.Locations[location]
    local def = NewsJob.VehicleFor(location, gradeOf(job), model)
    if not garage or not def then return false, 'not_allowed' end
    if not near(src, garage.coords, Config.GarageRange) then return false, 'too_far' end
    local now = os.time()
    if LastRequest[src] and now - LastRequest[src] < Config.SpawnCooldown then return false, 'cooldown' end
    -- a vehicle that was destroyed (a wreck, or cleaned up) or despawned no longer holds the lock
    retireLostVehicle(src, true)
    if Issued[src] then return false, 'vehicle_out' end
    LastRequest[src] = now
    -- the lock is taken before the spawn yields, so a second request cannot bring out a second vehicle
    local rec = { plate = newPlate(), model = model, label = def.label or model, location = location,
        citizenid = Player.PlayerData.citizenid, at = now, pending = true }
    Issued[src] = rec
    local ok, veh = pcall(QBCore.Functions.SpawnVehicle, src, model, garage.coords, true)
    local exists = ok and veh ~= nil and veh ~= 0 and DoesEntityExist(veh)
    if Issued[src] ~= rec then
        -- dropped or left the job while the vehicle was spawning
        if exists then DeleteEntity(veh) end
        return false, 'cancelled'
    end
    if not exists then
        Issued[src] = nil
        return false, 'spawn_failed'
    end
    rec.entity, rec.pending = veh, nil
    SetVehicleNumberPlateText(veh, rec.plate)
    if Config.UseableItems and location == 'vehicle' then stockTrunk(rec, src) end
    TriggerClientEvent('pfm-newsjob:client:spawnVehicle', src, location, model, rec.plate, def.modLivery, NetworkGetNetworkIdFromEntity(veh))
    return true
end

RegisterNetEvent('pfm-newsjob:server:requestVehicle', function(location, model)
    local src = source
    local ok, err = NewsJob.RequestVehicle(src, location, model)
    if not ok and err ~= 'bad_request' and err ~= 'cancelled' then
        local msg = ({ not_on_duty = 'Go on duty first.', not_allowed = 'Your grade cannot take that vehicle.', too_far = 'Stand at the garage.',
            cooldown = 'Wait a moment.', vehicle_out = 'Return your current news vehicle first.',
            spawn_failed = 'The vehicle could not be brought out. Try again.' })[err] or 'You cannot take a vehicle now.'
        TriggerClientEvent('QBCore:Notify', src, msg, 'error')
    end
end)

--- The reporter asks to put the issued vehicle away. The server decides: the vehicle must exist and
--- be at its garage point, with the reporter in it or next to it; the server deletes it and frees the
--- lock. A vehicle that no longer exists just frees the lock. Returns ok, err (also used by tests).
function NewsJob.StoreVehicle(src)
    local rec = Issued[src]
    if not rec then return false, 'no_vehicle' end
    if rec.pending then return false, 'pending' end
    if retireLostVehicle(src) then return true, 'gone' end
    local garage = Config.Locations[rec.location]
    local vehCoords = GetEntityCoords(rec.entity)
    if not garage or dist(vehCoords, garage.coords) > (Config.StoreRange or 10.0) then return false, 'not_at_garage' end
    local ped = GetPlayerPed(src)
    if GetVehiclePedIsIn(ped, false) ~= rec.entity and dist(GetEntityCoords(ped), vehCoords) > (Config.StorePlayerRange or 6.0) then
        return false, 'too_far'
    end
    local plate = rec.plate
    release(src, true) -- the gear goes back with the van
    DeleteEntity(rec.entity)
    TriggerClientEvent('pfm-newsjob:client:vehicleStored', src, plate)
    return true
end

-- the client only asks; nothing is freed unless the server put the vehicle away (or it is gone)
RegisterNetEvent('pfm-newsjob:server:vehicleStored', function()
    local src = source
    local ok, err = NewsJob.StoreVehicle(src)
    if not ok and err ~= 'no_vehicle' then
        local msg = ({ pending = 'Your vehicle is still being brought out.', not_at_garage = 'Bring the vehicle to its garage point.',
            too_far = 'Stand at your vehicle.' })[err] or 'You cannot store that vehicle.'
        TriggerClientEvent('QBCore:Notify', src, msg, 'error')
    end
end)

-- a news vehicle deleted anywhere (cleanup, despawn) frees its reporter's lock
AddEventHandler('entityRemoved', function(entity)
    for src, rec in pairs(Issued) do
        if rec.entity ~= nil and rec.entity == entity then release(src) end
    end
end)

-- The van's trunk is stocked by the server when it spawns the van (stockTrunk above). The old
-- client event 'qb-newsjob:server:addVehicleItems' is not handled: no client request stocks a trunk.

--- Duty at the office (on/off), only for reporters standing at the duty point.
function NewsJob.ToggleDuty(src)
    local Player, job = reporter(src)
    if not Player then return false, 'not_reporter' end
    if not near(src, Config.Locations['duty'].coords, Config.DutyRange) then return false, 'too_far' end
    local now = os.time()
    if LastDuty[src] and now - LastDuty[src] < 3 then return false, 'cooldown' end
    LastDuty[src] = now
    local onduty = not job.onduty
    Player.Functions.SetJobDuty(onduty)
    -- off duty, the reporter hands in the gear they carry (a van still out keeps its trunk)
    if not onduty then returnGear(src, nil, true) end
    TriggerEvent('QBCore:Server:SetDuty', src, onduty)
    TriggerClientEvent('QBCore:Client:SetDuty', src, onduty)
    TriggerClientEvent('QBCore:Notify', src, onduty and 'You are on duty for Weazel News.' or 'You are off duty.', onduty and 'success' or 'primary')
    return true, onduty
end

RegisterNetEvent('pfm-newsjob:server:toggleDuty', function()
    NewsJob.ToggleDuty(source)
end)

AddEventHandler('playerDropped', function()
    local src = source
    release(src)
    LastRequest[src], LastDuty[src] = nil, nil
end)

-- leaving the job ends the field assignment
AddEventHandler('QBCore:Server:OnJobUpdate', function(src, job)
    src = tonumber(src)
    if src and (type(job) ~= 'table' or job.name ~= Config.Job) then release(src, true) end
end)

-- ── equipment ───────────────────────────────────────────────────────
local function useEquipment(source, clientEvent)
    if not onDutyReporter(source) then
        TriggerClientEvent('QBCore:Notify', source, 'Only Weazel News staff on duty can use this.', 'error')
        return
    end
    TriggerClientEvent(clientEvent, source)
end
NewsJob.UseEquipment = useEquipment

local equipment = { newscam = 'Cam:ToggleCam', newsmic = 'Mic:ToggleMic', newsbmic = 'Mic:ToggleBMic' }
if Config.UseableItems then
    for item, ev in pairs(equipment) do
        QBCore.Functions.CreateUseableItem(item, function(source) useEquipment(source, ev) end)
    end
else
    QBCore.Commands.Add('newscam', 'Grab a news camera', {}, false, function(source) useEquipment(source, 'Cam:ToggleCam') end)
    QBCore.Commands.Add('newsmic', 'Grab a news microphone', {}, false, function(source) useEquipment(source, 'Mic:ToggleMic') end)
    QBCore.Commands.Add('newsbmic', 'Grab a Boom microphone', {}, false, function(source) useEquipment(source, 'Mic:ToggleBMic') end)
end

-- ── for the newsroom (pf-news) ──────────────────────────────────────
--- Who is out with a news vehicle: { [citizenid] = { model, label, location, since } }.
exports('GetFieldStatus', function()
    local out = {}
    for _, v in pairs(Issued) do
        if not vehicleGone(v) and not vehicleWrecked(v) then
            out[v.citizenid] = { model = v.model, label = v.label, location = v.location, since = v.at }
        end
    end
    return out
end)

exports('IsOnDuty', function(src)
    return onDutyReporter(tonumber(src)) ~= nil
end)

--- Clears the gear record of an online reporter (the newsroom boss, after lost gear was replaced):
--- the next van is stocked with every piece they do not carry.
function NewsJob.ResetGear(src)
    src = tonumber(src)
    local Player = src and QBCore.Functions.GetPlayer(src)
    if not Player then return false end
    Player.Functions.SetMetaData('newsgear', {})
    return true
end
exports('ResetReporterGear', function(src) return NewsJob.ResetGear(src) end)

function NewsJob.__reset() Issued, StockedTrunks, LastRequest, LastDuty = {}, {}, {}, {} end
