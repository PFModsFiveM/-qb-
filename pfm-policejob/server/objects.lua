local Objects = {}

local function CreateObjectId()
    if Objects then
        local objectId = math.random(10000, 99999)
        while Objects[objectId] do
            objectId = math.random(10000, 99999)
        end
        return objectId
    else
        local objectId = math.random(10000, 99999)
        return objectId
    end
end

local function IsOnDutyLeo(src)
    local Player = exports['pfm-core']:GetPlayer(src)
    return Player and Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty
end

RegisterNetEvent('police:server:spawnObject', function(type)
    local src = source
    if not IsOnDutyLeo(src) then return end
    if not Config.Objects[type] then return end
    local objectId = CreateObjectId()
    Objects[objectId] = type
    TriggerClientEvent('police:client:spawnObject', src, objectId, type, src)
end)

RegisterNetEvent('police:server:deleteObject', function(objectId)
    local src = source
    if not IsOnDutyLeo(src) then return end
    if not Objects[objectId] then return end
    Objects[objectId] = nil
    TriggerClientEvent('police:client:removeObject', -1, objectId)
end)

-- ── Spike strips ──────────────────────────────────────────────────
-- The list of spike strips lives here. The server places the prop itself, at the officer's own
-- position, and sends every client its list. A client used to send its whole list to everyone
-- (police:server:SyncSpikes), so one client could empty every officer's spikes, crash every
-- client's spike loop with bad coordinates, or list another car's network id as a "spike" for the
-- next officer pressing E to delete.
local SPIKE_MODEL = `P_ld_stinger_s`
local Spikes = {}      -- [id] = { id, coords = vector3, netid, entity, owner = src, at = os.time() }
local spikeSeq = 0
local lastSpikeAt = {} -- [src] = GetGameTimer() of the last placement
local lastSpikeList = {} -- [src] = os.time() of the last list request

local function SpikeList()
    local out = {}
    for id, s in pairs(Spikes) do out[#out + 1] = { id = id, coords = s.coords, netid = s.netid } end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

local function BroadcastSpikes(target)
    TriggerClientEvent('police:client:SyncSpikes', target or -1, SpikeList())
end

local function DeleteSpike(id)
    local s = Spikes[id]
    if not s then return end
    Spikes[id] = nil
    if s.entity and DoesEntityExist(s.entity) then DeleteEntity(s.entity) end
end

local function SpikeCounts(src)
    local mine, all = 0, 0
    for _, s in pairs(Spikes) do
        all = all + 1
        if s.owner == src then mine = mine + 1 end
    end
    return mine, all
end

--- Places a spike strip 2 m in front of an on-duty officer (also used by /spikestrip).
--- @return boolean ok, string|nil message for the officer
function PolicePlaceSpike(src)
    src = tonumber(src)
    if not src or not IsOnDutyLeo(src) then return false, Lang:t('error.on_duty_police_only') end
    local now = GetGameTimer()
    if lastSpikeAt[src] and now - lastSpikeAt[src] < 1500 then return false, nil end
    local mine, all = SpikeCounts(src)
    if mine >= (Config.MaxSpikes or 5) or all >= (Config.MaxSpikesTotal or 30) then
        return false, Lang:t('error.no_spikestripe')
    end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false, nil end
    if GetVehiclePedIsIn(ped, false) ~= 0 then return false, nil end
    lastSpikeAt[src] = now
    local pos = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped) or 0.0
    local r = math.rad(heading)
    -- GTA headings turn counter-clockwise from north: forward is (-sin, cos)
    local x, y, z = pos.x - math.sin(r) * 2.0, pos.y + math.cos(r) * 2.0, pos.z - 0.95
    local obj = CreateObjectNoOffset(SPIKE_MODEL, x, y, z, true, true, false)
    if not obj or obj == 0 then return false, nil end
    SetEntityHeading(obj, heading)
    FreezeEntityPosition(obj, true)
    spikeSeq = spikeSeq + 1
    Spikes[spikeSeq] = { id = spikeSeq, coords = vector3(x, y, z), netid = NetworkGetNetworkIdFromEntity(obj), entity = obj, owner = src, at = os.time() }
    BroadcastSpikes()
    -- the officer's client sets it flat on the ground (cosmetic)
    TriggerClientEvent('police:client:SpikePlaced', src, Spikes[spikeSeq].netid)
    return true
end

RegisterNetEvent('police:server:PlaceSpike', function()
    local src = source
    local ok, err = PolicePlaceSpike(src)
    if not ok and err then TriggerClientEvent('QBCore:Notify', src, err, 'error') end
end)

-- An on-duty officer picks a spike strip up from beside it (the server deletes the prop).
RegisterNetEvent('police:server:RemoveSpike', function(id)
    local src = source
    id = math.tointeger(tonumber(id))
    local s = id and Spikes[id]
    if not s or not IsOnDutyLeo(src) then return end
    if #(GetEntityCoords(GetPlayerPed(src)) - s.coords) > 5.0 then return end
    DeleteSpike(id)
    BroadcastSpikes()
end)

-- A client that just loaded asks for the list (at most every 5 s).
RegisterNetEvent('police:server:RequestSpikes', function()
    local src = source
    local now = os.time()
    if lastSpikeList[src] and now - lastSpikeList[src] < 5 then return end
    lastSpikeList[src] = now
    BroadcastSpikes(src)
end)

--- Takes up every spike of an officer who left, went off duty or left the police.
local function ClearOwnerSpikes(src)
    local changed = false
    for id, s in pairs(Spikes) do
        if s.owner == src then DeleteSpike(id) changed = true end
    end
    if changed then BroadcastSpikes() end
end

--- Takes up spikes older than Config.SpikeLifetime seconds and spikes whose prop is gone
--- (called every 30 s; also used by tests).
function PoliceSpikeSweep()
    local now, changed = os.time(), false
    local lifetime = tonumber(Config.SpikeLifetime) or 600
    for id, s in pairs(Spikes) do
        if now - s.at >= lifetime or not DoesEntityExist(s.entity) then DeleteSpike(id) changed = true end
    end
    if changed then BroadcastSpikes() end
end

CreateThread(function()
    while true do
        Wait(30000)
        PoliceSpikeSweep()
    end
end)

AddEventHandler('QBCore:Server:SetDuty', function(src, onDuty)
    if not onDuty then ClearOwnerSpikes(tonumber(src)) end
end)

AddEventHandler('QBCore:Server:OnJobUpdate', function(src, job)
    if type(job) ~= 'table' or job.type ~= 'leo' or not job.onduty then ClearOwnerSpikes(tonumber(src)) end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    for id in pairs(Spikes) do DeleteSpike(id) end
end)

AddEventHandler('playerDropped', function()
    local src = source
    lastSpikeAt[src], lastSpikeList[src] = nil, nil
    ClearOwnerSpikes(src)
end)
