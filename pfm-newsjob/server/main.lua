-- Weazel News field work: the news van and helicopter, the camera / mic / boom mic, the duty point
-- at the office. Connected to the newsroom (pf-news): reporters go on duty here to claim leads, and
-- the newsroom shows who is out with a news vehicle (GetFieldStatus).
--
-- Nothing a client sends is trusted: the job, duty and grade come from the server player, vehicles
-- are spawned only with a one-time ticket the server grants for a model that grade may take at that
-- garage while standing at it, the plate is chosen here, and the trunk is stocked once per issued plate.

local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions', 'Commands' })

NewsJob = NewsJob or {}
local Issued = {}        -- src -> { plate, model, label, location, citizenid, at }
local StockedTrunks = {} -- plate -> true
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

local function trim(s) return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', '')) end

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

--- A reporter on duty at a garage asks for a vehicle. Returns ok, err (also used by tests).
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
    if Issued[src] then return false, 'vehicle_out' end
    LastRequest[src] = now
    local plate = newPlate()
    if not exports['pfm-core']:GrantVehicleSpawn(src, model) then return false, 'spawn_refused' end
    Issued[src] = { plate = plate, model = model, label = def.label or model, location = location, citizenid = Player.PlayerData.citizenid, at = now }
    TriggerClientEvent('pfm-newsjob:client:spawnVehicle', src, location, model, plate, def.modLivery)
    return true
end

RegisterNetEvent('pfm-newsjob:server:requestVehicle', function(location, model)
    local src = source
    local ok, err = NewsJob.RequestVehicle(src, location, model)
    if not ok and err ~= 'bad_request' then
        local msg = ({ not_on_duty = 'Go on duty first.', not_allowed = 'Your grade cannot take that vehicle.', too_far = 'Stand at the garage.',
            cooldown = 'Wait a moment.', vehicle_out = 'Return your current news vehicle first.' })[err] or 'You cannot take a vehicle now.'
        TriggerClientEvent('QBCore:Notify', src, msg, 'error')
    end
end)

--- The issued vehicle is back (or gone): the reporter may take another.
RegisterNetEvent('pfm-newsjob:server:vehicleStored', function()
    Issued[source] = nil
end)

--- Stocks the news van's trunk with the camera and mics, once per issued plate. The player must be
--- the reporter on duty the plate was issued to, sitting in that van near the garage, with its keys.
function NewsJob.StockTrunk(src, plate)
    if not Config.UseableItems then return false, 'disabled' end
    local Player = onDutyReporter(src)
    if not Player then return false, 'not_on_duty' end
    if type(plate) ~= 'string' or #plate > 8 then return false, 'bad_request' end
    plate = trim(plate)
    local issued = Issued[src]
    if not issued or issued.plate ~= plate or issued.location ~= 'vehicle' then return false, 'not_issued' end
    if StockedTrunks[plate] then return false, 'already_stocked' end
    local veh = GetVehiclePedIsIn(GetPlayerPed(src), false)
    if not veh or veh == 0 or trim(GetVehicleNumberPlateText(veh)) ~= plate then return false, 'not_in_vehicle' end
    if not near(src, Config.Locations['vehicle'].coords, 30.0) then return false, 'too_far' end
    local okKeys, hasKeys = pcall(function() return exports['pfm-vehiclekeys']:HasKeys(src, plate) end)
    if not okKeys or not hasKeys then return false, 'no_keys' end
    StockedTrunks[plate] = true
    exports['pfm-inventory']:CreateInventory('trunk-' .. plate)
    for slot, item in pairs(Config.VehicleItems) do
        exports['pfm-inventory']:AddItem('trunk-' .. plate, item.name, item.amount, slot, item.info, 'pfm-newsjob:vehicleItems')
    end
    return true
end

-- the client name is kept from qb-newsjob so the van spawner keeps working
RegisterNetEvent('qb-newsjob:server:addVehicleItems', function(plate)
    NewsJob.StockTrunk(source, plate)
end)

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
    Issued[src], LastRequest[src], LastDuty[src] = nil, nil, nil
end)

-- leaving the job ends the field assignment
AddEventHandler('QBCore:Server:OnJobUpdate', function(src, job)
    src = tonumber(src)
    if src and (type(job) ~= 'table' or job.name ~= Config.Job) then Issued[src] = nil end
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
        out[v.citizenid] = { model = v.model, label = v.label, location = v.location, since = v.at }
    end
    return out
end)

exports('IsOnDuty', function(src)
    return onDutyReporter(tonumber(src)) ~= nil
end)

function NewsJob.__reset() Issued, StockedTrunks, LastRequest, LastDuty = {}, {}, {}, {} end
