-- Police equipment props (server). Every prop is spawned by the server at the officer's own
-- position and kept in a server list with per-officer, per-kind and server-wide caps. A client used
-- to spawn the prop itself (the server only issued an id), with no cap, so one client could fill an
-- area with props or delete any id for everyone.

local function IsOnDutyLeo(src)
    local Player = exports['pfm-core']:GetPlayer(src)
    return Player and Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty
end

local function Eq() return Config.Equipment or {} end
local function Text(key) return (Eq().Text or {})[key] or key end
local function Notify(src, key) TriggerClientEvent('QBCore:Notify', src, Text(key), 'error') end

-- ── Scene props ───────────────────────────────────────────────────
local Props = {}      -- [id] = { id, kind, entity, netid, owner = src, coords = vector3, at = os.time() }
local propSeq = 0
local lastPropAt = {} -- [src] = GetGameTimer() of the last placement

local function PropCfg() return Eq().Props or {} end

--- The prop kinds: Config.Equipment.Props.Kinds, or the legacy Config.Objects when that is missing.
local function PropKinds()
    local kinds = PropCfg().Kinds
    if kinds then return kinds end
    return Config.Objects or {}
end

local function DeleteProp(id)
    local p = Props[id]
    if not p then return end
    Props[id] = nil
    if p.entity and DoesEntityExist(p.entity) then DeleteEntity(p.entity) end
end

local function PropCounts(src, kind)
    local mine, mineKind, all = 0, 0, 0
    for _, p in pairs(Props) do
        all = all + 1
        if p.owner == src then
            mine = mine + 1
            if p.kind == kind then mineKind = mineKind + 1 end
        end
    end
    return mine, mineKind, all
end

--- Places a prop of `kind` in front of an on-duty officer.
--- @return boolean ok, string|nil reason (a Config.Equipment.Text key)
function PolicePlaceProp(src, kind)
    src = tonumber(src)
    if not src or not IsOnDutyLeo(src) then return false, 'on_duty_police_only' end
    local kinds = PropKinds()
    local def = type(kind) == 'string' and kinds[kind]
    if not def or not def.model then return false, nil end
    local cfg = PropCfg()
    local now = GetGameTimer()
    if lastPropAt[src] and now - lastPropAt[src] < (tonumber(cfg.RateMs) or 750) then return false, nil end
    local mine, mineKind, all = PropCounts(src, kind)
    if mine >= (tonumber(cfg.PerOfficer) or 12) then return false, 'prop_limit' end
    if mineKind >= (tonumber(def.max) or 12) then return false, 'prop_type_limit' end
    if all >= (tonumber(cfg.Total) or 150) then return false, 'prop_server_limit' end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 or GetVehiclePedIsIn(ped, false) ~= 0 then return false, nil end
    lastPropAt[src] = now
    local pos = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped) or 0.0
    local r = math.rad(heading)
    local d = tonumber(cfg.PlaceDistance) or 1.0
    -- GTA headings turn counter-clockwise from north: forward is (-sin, cos)
    local x, y, z = pos.x - math.sin(r) * d, pos.y + math.cos(r) * d, pos.z - 0.95
    local obj = CreateObjectNoOffset(def.model, x, y, z, true, true, false)
    if not obj or obj == 0 then return false, nil end
    SetEntityHeading(obj, heading)
    if def.freeze then FreezeEntityPosition(obj, true) end
    propSeq = propSeq + 1
    Props[propSeq] = { id = propSeq, kind = kind, entity = obj, netid = NetworkGetNetworkIdFromEntity(obj), owner = src, coords = vector3(x, y, z), at = os.time() }
    -- the officer's client sets it on the ground (cosmetic)
    TriggerClientEvent('police:client:PropPlaced', src, Props[propSeq].netid)
    return true
end

--- Takes up the police prop nearest to an on-duty officer (within RemoveRange of the officer's
--- server position; any officer may take up any police prop).
function PoliceRemoveNearestProp(src)
    src = tonumber(src)
    if not src or not IsOnDutyLeo(src) then return false, 'on_duty_police_only' end
    local pos = GetEntityCoords(GetPlayerPed(src))
    local best, bestDist = nil, tonumber(PropCfg().RemoveRange) or 3.0
    for id, p in pairs(Props) do
        local at = (p.entity and DoesEntityExist(p.entity)) and GetEntityCoords(p.entity) or p.coords
        local dist = #(pos - at)
        if dist <= bestDist then best, bestDist = id, dist end
    end
    if not best then return false, 'prop_none' end
    DeleteProp(best)
    return true
end

--- The server's prop list (tests and admin tools).
function PoliceProps()
    local out = {}
    for id, p in pairs(Props) do out[#out + 1] = { id = id, kind = p.kind, owner = p.owner, netid = p.netid, coords = p.coords } end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

RegisterNetEvent('police:server:spawnObject', function(kind)
    local src = source
    local ok, why = PolicePlaceProp(src, kind)
    if not ok and why then Notify(src, why) end
end)

-- The argument (an id the client used to choose) is ignored: the server takes up the nearest prop.
RegisterNetEvent('police:server:deleteObject', function()
    local src = source
    local ok, why = PoliceRemoveNearestProp(src)
    if not ok and why then Notify(src, why) end
end)

-- ── Riot shield ───────────────────────────────────────────────────
-- Using the item spawns a shield on the server for an on-duty officer (one each); the owner's client
-- holds it. Using it again, losing the item, going off duty or leaving takes it away.
local Shields = {} -- [src] = { entity, netid }

local function ShieldCfg() return Eq().RiotShield or {} end

local function HasItem(src, item)
    local ok, has = pcall(function() return exports['pfm-inventory']:HasItem(src, item, 1) end)
    return ok and has == true
end

function PoliceDropShield(src)
    src = tonumber(src)
    local s = src and Shields[src]
    if not s then return false end
    Shields[src] = nil
    if s.entity and DoesEntityExist(s.entity) then DeleteEntity(s.entity) end
    TriggerClientEvent('police:client:ShieldRemoved', src)
    return true
end

function PoliceToggleShield(src)
    src = tonumber(src)
    if not src then return false end
    if Shields[src] then return PoliceDropShield(src), nil end
    if not IsOnDutyLeo(src) then return false, 'on_duty_police_only' end
    local cfg = ShieldCfg()
    if not HasItem(src, cfg.Item or 'riot_shield') then return false, 'no_item' end
    local n = 0
    for _ in pairs(Shields) do n = n + 1 end
    if n >= (tonumber(cfg.Total) or 40) then return false, 'shield_limit' end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 or GetVehiclePedIsIn(ped, false) ~= 0 then return false, nil end
    local pos = GetEntityCoords(ped)
    local obj = CreateObjectNoOffset(cfg.Model or `prop_ballistic_shield`, pos.x, pos.y, pos.z, true, true, false)
    if not obj or obj == 0 then return false, nil end
    Shields[src] = { entity = obj, netid = NetworkGetNetworkIdFromEntity(obj) }
    TriggerClientEvent('police:client:AttachShield', src, Shields[src].netid)
    return true
end

function PoliceShieldOf(src) return Shields[tonumber(src)] end

QBCore.Functions.CreateUseableItem((Eq().RiotShield or {}).Item or 'riot_shield', function(source)
    local ok, why = PoliceToggleShield(source)
    if not ok and why then Notify(source, why) end
end)

--- Takes up props older than LifetimeSeconds or whose entity is gone, and shields whose holder no
--- longer carries the item or is off duty (every 30 s).
function PolicePropSweep()
    local now = os.time()
    local lifetime = tonumber(PropCfg().LifetimeSeconds) or 3600
    for id, p in pairs(Props) do
        if now - p.at >= lifetime or not DoesEntityExist(p.entity) then DeleteProp(id) end
    end
    local item = ShieldCfg().Item or 'riot_shield'
    for src, s in pairs(Shields) do
        if not IsOnDutyLeo(src) or not HasItem(src, item) or not DoesEntityExist(s.entity) then PoliceDropShield(src) end
    end
end

local function ClearOwnerProps(src)
    for id, p in pairs(Props) do
        if p.owner == src then DeleteProp(id) end
    end
    PoliceDropShield(src)
end

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
        PolicePropSweep()
    end
end)

AddEventHandler('QBCore:Server:SetDuty', function(src, onDuty)
    if not onDuty then
        ClearOwnerSpikes(tonumber(src))
        ClearOwnerProps(tonumber(src))
    end
end)

AddEventHandler('QBCore:Server:OnJobUpdate', function(src, job)
    if type(job) ~= 'table' or job.type ~= 'leo' or not job.onduty then
        ClearOwnerSpikes(tonumber(src))
        ClearOwnerProps(tonumber(src))
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    for id in pairs(Spikes) do DeleteSpike(id) end
    for id in pairs(Props) do DeleteProp(id) end
    for src in pairs(Shields) do PoliceDropShield(src) end
end)

AddEventHandler('playerDropped', function()
    local src = source
    lastSpikeAt[src], lastSpikeList[src], lastPropAt[src] = nil, nil, nil
    ClearOwnerSpikes(src)
    ClearOwnerProps(src)
end)
