-- PF gameplay pack (server): tackle, gunshot residue, panic button, K9 sniff search, drone

local function IsOnDutyLeo(Player)
    return Player and Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty
end

local function Eq() return Config.Equipment or {} end
local function Text(key) return (Eq().Text or {})[key] or key end
local function Notify(src, key, kind) TriggerClientEvent('QBCore:Notify', src, Text(key), kind or 'error') end
local function Mark(who, kind, data, opts)
    if PFTelemetry then return PFTelemetry.Mark(who, kind, data, opts) end
end
local function u32(h)
    h = tonumber(h)
    if not h then return nil end
    return math.floor(h) % 4294967296
end

PFGameplay = PFGameplay or {}
local G = PFGameplay

-- ══ Tackle ═══════════════════════════════════════════════════════
local tackleCooldowns = {}

RegisterNetEvent('police:server:Tackle', function(targetId)
    local src = source
    local cfg = Config.Gameplay and Config.Gameplay.Tackle
    if not cfg or not cfg.Enabled then return end
    targetId = tonumber(targetId)
    if not targetId or targetId == src then return end

    local Player = exports['pfm-core']:GetPlayer(src)
    local Target = exports['pfm-core']:GetPlayer(targetId)
    if not Player or not Target then return end
    if not IsOnDutyLeo(Player) then return end

    local now = GetGameTimer()
    if tackleCooldowns[src] and now - tackleCooldowns[src] < (cfg.Cooldown or 15000) then return end

    local playerPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(targetId)
    if #(GetEntityCoords(playerPed) - GetEntityCoords(targetPed)) > 3.5 then return end

    tackleCooldowns[src] = now
    TriggerClientEvent('police:client:TackleDive', src)
    TriggerClientEvent('police:client:TackleTarget', Target.PlayerData.source, src)
    Mark(src, 'use_of_force', { action = 'tackle', subject = Target.PlayerData.citizenid })
end)

-- ══ GSR ═══════════════════════════════════════════════════════════
-- Residue comes from what the server sees: the attacker of a weaponDamageEvent with a firearm, and
-- the shooter's own casing reports (evidence:server:CreateCasing, which also leaves evidence on the
-- ground). The shooter's client used to report it (police:server:MarkGSR), so a modified client
-- simply never tested positive.
local gsrAt = {}       -- [src] = os.time() of the last shot the server knows of
local gsrWritten = {}  -- [src] = os.time() metadata.gsr was last written

local sharedWeapons
local function WeaponDef(hash)
    sharedWeapons = sharedWeapons or exports['pfm-core']:GetShared('Weapons') or {}
    local def = sharedWeapons[hash]
    if def then return def end
    local h = u32(hash)
    if not h then return nil end
    for k, v in pairs(sharedWeapons) do
        if u32(k) == h then return v end
    end
    return nil
end
G.WeaponDef = WeaponDef

--- True for a weapon that leaves gunshot residue (Config.Equipment.GSR.Ammo).
function G.IsFirearm(hash)
    local def = WeaponDef(hash)
    local ammo = (Eq().GSR or {}).Ammo or {}
    return def ~= nil and def.ammotype ~= nil and ammo[def.ammotype] == true
end

local function IsTaser(hash)
    local def = WeaponDef(hash)
    return def ~= nil and def.ammotype == 'AMMO_STUNGUN'
end

--- Records that `src` fired a firearm now (memory always; metadata at most every MetaWriteSeconds,
--- so the result survives a relog).
function G.MarkResidue(src)
    src = tonumber(src)
    local cfg = Config.Gameplay and Config.Gameplay.GSR
    if not src or not cfg or not cfg.Enabled then return false end
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return false end
    local now = os.time()
    gsrAt[src] = now
    local every = tonumber((Eq().GSR or {}).MetaWriteSeconds) or 30
    if not gsrWritten[src] or now - gsrWritten[src] >= every then
        gsrWritten[src] = now
        Player.Functions.SetMetaData('gsr', now)
    end
    return true
end

-- The server-seen shot: the sender of weaponDamageEvent is the shooter.
function G.OnWeaponDamage(sender, data)
    local src = tonumber(sender)
    if not src or src <= 0 or type(data) ~= 'table' then return end
    local weapon = data.weaponType
    if G.IsFirearm(weapon) then
        G.MarkResidue(src)
        if PFTelemetry and PFTelemetry.DeviceOf(src) then
            Mark(src, 'shot_hit', { weapon = (WeaponDef(weapon) or {}).name })
        end
    elseif IsTaser(weapon) and PFTelemetry and PFTelemetry.DeviceOf(src) then
        Mark(src, 'taser', {})
    end
end

AddEventHandler('weaponDamageEvent', function(sender, data)
    G.OnWeaponDamage(sender, data)
end)

-- A casing report (the net event's evidence handler lives in server/evidence.lua; this handler
-- runs as well). The weapon must be a firearm, and the one the server sees in hand when it can tell.
function G.OnCasingReport(src, weapon)
    src = tonumber(src)
    if not src or src <= 0 or not G.IsFirearm(weapon) then return false end
    local seen = u32(GetSelectedPedWeapon(GetPlayerPed(src))) or 0
    if seen ~= 0 and seen ~= u32(weapon) then return false end
    local last = gsrAt[src]
    G.MarkResidue(src)
    -- one 'shot reported' row per burst in the shooter's timeline (client-reported)
    if PFTelemetry and PFTelemetry.DeviceOf(src) and (not last or os.time() - last >= 2) then
        Mark(src, 'shot_reported', { weapon = (WeaponDef(weapon) or {}).name }, { clientReported = true })
    end
    return true
end

AddEventHandler('evidence:server:CreateCasing', function(weapon)
    G.OnCasingReport(source, weapon)
end)

-- Old clients still send this; the self-report is ignored.
RegisterNetEvent('police:server:MarkGSR', function() end)

--- Whether the player tests positive now (memory or the stored metadata).
function G.ResiduePositive(Target)
    local cfg = Config.Gameplay and Config.Gameplay.GSR or {}
    local src = Target.PlayerData.source
    local firedAt = math.max(tonumber(gsrAt[src]) or 0, tonumber(Target.PlayerData.metadata['gsr']) or 0)
    return firedAt > 0 and (os.time() - firedAt) < (cfg.PositiveSeconds or 2700)
end

RegisterNetEvent('police:server:GsrTest', function(targetId)
    local src = source
    local cfg = Config.Gameplay and Config.Gameplay.GSR
    if not cfg or not cfg.Enabled then return end
    targetId = tonumber(targetId)
    if not targetId then return end

    local Player = exports['pfm-core']:GetPlayer(src)
    local Target = exports['pfm-core']:GetPlayer(targetId)
    if not Player or not Target then return end
    if not IsOnDutyLeo(Player) then return end

    local playerPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(targetId)
    if #(GetEntityCoords(playerPed) - GetEntityCoords(targetPed)) > 5.0 then return end

    local positive = G.ResiduePositive(Target)
    local name = ('%s %s'):format(Target.PlayerData.charinfo.firstname, Target.PlayerData.charinfo.lastname)
    if positive then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('info.gsr_positive', { player = name }), 'error', 7500)
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('info.gsr_negative', { player = name }), 'success', 7500)
    end
    TriggerClientEvent('QBCore:Notify', Target.PlayerData.source, Lang:t('info.gsr_swabbed'))
    Mark(src, 'search', { test = 'gsr', subject = Target.PlayerData.citizenid, positive = positive })
end)

QBCore.Commands.Add('gsr', Lang:t('commands.gsr'), {}, false, function(source)
    local Player = exports['pfm-core']:GetPlayer(source)
    if not IsOnDutyLeo(Player) then
        TriggerClientEvent('QBCore:Notify', source, Lang:t('error.on_duty_police_only'), 'error')
        return
    end
    TriggerClientEvent('police:client:DoGSR', source)
end)

-- ══ Panic button ═════════════════════════════════════════════════
local panicCooldowns = {}

RegisterNetEvent('police:server:Panic', function()
    local src = source
    local cfg = Config.Gameplay and Config.Gameplay.Panic
    if not cfg or not cfg.Enabled then return end

    local Player = exports['pfm-core']:GetPlayer(src)
    if not IsOnDutyLeo(Player) then return end

    local now = GetGameTimer()
    if panicCooldowns[src] and now - panicCooldowns[src] < (cfg.Cooldown or 60000) then return end
    panicCooldowns[src] = now

    local coords = GetEntityCoords(GetPlayerPed(src))
    local callsign = Player.PlayerData.metadata['callsign'] or 'UNKNOWN'
    local players = QBCore.Functions.GetQBPlayers()
    for _, v in pairs(players) do
        if v and v.PlayerData.job.type == 'leo' and v.PlayerData.job.onduty then
            TriggerClientEvent('police:client:PanicAlert', v.PlayerData.source, { x = coords.x, y = coords.y, z = coords.z }, callsign)
        end
    end
    if PoliceMdtDispatch then PoliceMdtDispatch('panic', src, coords, callsign) end
    Mark(src, 'note', { event = 'panic_button' })
end)

-- ══ K9 sniff search ═══════════════════════════════════════════════
-- A certified handler (pf-government qualification `k9`) lets the dog sniff a person or a vehicle.
-- The dog alerts exactly when the server finds one of Config.Equipment.K9.DrugItems in that
-- person's inventory or the vehicle's trunk/glovebox. The dog itself is a client presentation.
local k9At = {}

local function HasQualification(cid, qual)
    if GetResourceState('pf-government') ~= 'started' then return false end
    local ok, has = pcall(function() return exports['pf-government']:HasQualification(cid, qual) end)
    return ok and has == true
end

local function ItemsHaveDrugs(items, drugs)
    if type(items) ~= 'table' then return false end
    for _, it in pairs(items) do
        if type(it) == 'table' and drugs[it.name] and (tonumber(it.amount) or 0) > 0 then return true end
    end
    return false
end

local function TrimPlate(p) return (tostring(p or ''):gsub('^%s+', ''):gsub('%s+$', '')) end

local function VehicleHasDrugs(plate, drugs)
    local ids, seen = {}, {}
    for _, p in ipairs({ plate, TrimPlate(plate) }) do
        for _, kind in ipairs({ 'trunk-', 'glovebox-' }) do
            local id = kind .. p
            if not seen[id] then seen[id] = true ids[#ids + 1] = id end
        end
    end
    for _, id in ipairs(ids) do
        local ok, inv = pcall(function() return exports['pfm-inventory']:GetInventory(id) end)
        if ok and type(inv) == 'table' and ItemsHaveDrugs(inv.items, drugs) then return true end
    end
    return false
end

--- One sniff. kind = 'player' (target = server id) or 'vehicle' (target = network id).
--- @return table { ok, alert } or { ok = false, error }
function G.K9Sniff(src, kind, target)
    src = tonumber(src)
    local cfg = Eq().K9 or {}
    local Player = src and exports['pfm-core']:GetPlayer(src)
    if not IsOnDutyLeo(Player) then return { ok = false, error = 'on_duty_police_only' } end
    if not HasQualification(Player.PlayerData.citizenid, cfg.Qualification or 'k9') then return { ok = false, error = 'k9_no_qual' } end
    local now = os.time()
    if k9At[src] and now - k9At[src] < (tonumber(cfg.CooldownSeconds) or 15) then return { ok = false, error = 'k9_cooldown' } end
    local myPos = GetEntityCoords(GetPlayerPed(src))
    local drugs = cfg.DrugItems or {}
    local alert, subject
    if kind == 'player' then
        local tid = tonumber(target)
        local Target = tid and tid ~= src and exports['pfm-core']:GetPlayer(tid)
        if not Target then return { ok = false, error = 'bad_args' } end
        if #(myPos - GetEntityCoords(GetPlayerPed(tid))) > (tonumber(cfg.PlayerRange) or 3.0) then return { ok = false, error = 'k9_too_far' } end
        alert = ItemsHaveDrugs(Target.PlayerData.items, drugs)
        subject = Target.PlayerData.citizenid
    elseif kind == 'vehicle' then
        local netId = tonumber(target)
        local veh = netId and NetworkGetEntityFromNetworkId(math.floor(netId))
        if not veh or veh == 0 or not DoesEntityExist(veh) then return { ok = false, error = 'bad_args' } end
        if #(myPos - GetEntityCoords(veh)) > (tonumber(cfg.VehicleRange) or 5.0) then return { ok = false, error = 'k9_too_far' } end
        local plate = GetVehicleNumberPlateText(veh)
        if type(plate) ~= 'string' or plate == '' then return { ok = false, error = 'bad_args' } end
        alert = VehicleHasDrugs(plate, drugs)
        subject = TrimPlate(plate)
    else
        return { ok = false, error = 'bad_args' }
    end
    k9At[src] = now
    Mark(src, 'k9', { subject = subject, target = kind, alert = alert })
    return { ok = true, alert = alert }
end

RegisterNetEvent('police:server:K9Sniff', function(kind, target)
    local src = source
    if type(kind) ~= 'string' then return end
    local res = G.K9Sniff(src, kind, target)
    if not res.ok then
        if res.error ~= 'bad_args' then Notify(src, res.error, 'error') end
        return
    end
    Notify(src, res.alert and 'k9_alert' or 'k9_clear', res.alert and 'error' or 'success')
end)

-- ══ Drone ═════════════════════════════════════════════════════════
-- The drone is a camera on the operator's client. The server opens a session (on-duty officer with
-- the item), takes position hints, ends the session when a hint is out of Radius of the operator's
-- server position or the time is up, and logs start, positions and end in the operator's timeline.
local drones = {}     -- [src] = { started, origin, lastLog, lastHint }
local droneEnded = {} -- [src] = os.time() of the last landing

local function DroneCfg() return Eq().Drone or {} end

local function HasItem(src, item)
    local ok, has = pcall(function() return exports['pfm-inventory']:HasItem(src, item, 1) end)
    return ok and has == true
end

function G.DroneStart(src)
    src = tonumber(src)
    local cfg = DroneCfg()
    local Player = src and exports['pfm-core']:GetPlayer(src)
    if not IsOnDutyLeo(Player) then return { ok = false, error = 'on_duty_police_only' } end
    if drones[src] then return { ok = false, error = 'drone_busy' } end
    local now = os.time()
    if droneEnded[src] and now - droneEnded[src] < (tonumber(cfg.CooldownSeconds) or 30) then return { ok = false, error = 'drone_busy' } end
    if not HasItem(src, cfg.Item or 'police_drone') then return { ok = false, error = 'no_item' } end
    local pos = GetEntityCoords(GetPlayerPed(src))
    drones[src] = { started = now, lastLog = 0 }
    Mark(src, 'drone', { event = 'start' })
    TriggerClientEvent('police:client:DroneStart', src, { x = pos.x, y = pos.y, z = pos.z }, tonumber(cfg.Radius) or 250.0, tonumber(cfg.MaxSeconds) or 600)
    return { ok = true }
end

function G.DroneStop(src, reason)
    src = tonumber(src)
    local d = src and drones[src]
    if not d then return false end
    drones[src] = nil
    droneEnded[src] = os.time()
    Mark(src, 'drone', { event = 'end', reason = reason or 'landed', seconds = os.time() - d.started })
    TriggerClientEvent('police:client:DroneStop', src, reason or 'landed')
    return true
end

--- A position hint from the operator's client. Out of range ends the flight.
function G.DroneHint(src, x, y, z)
    src = tonumber(src)
    local d = src and drones[src]
    if not d then return false end
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if not x or not y or not z or x ~= x or y ~= y or z ~= z then return false end
    local cfg = DroneCfg()
    local t = GetGameTimer()
    if d.lastHint and t - d.lastHint < 500 then return false end
    d.lastHint = t
    local op = GetEntityCoords(GetPlayerPed(src))
    local dx, dy = x - op.x, y - op.y
    local limit = (tonumber(cfg.Radius) or 250.0) + (tonumber(cfg.HintSlackMeters) or 15.0)
    if math.sqrt(dx * dx + dy * dy) > limit then
        G.DroneStop(src, 'range')
        return false
    end
    local now = os.time()
    if now - d.lastLog >= (tonumber(cfg.LogEverySeconds) or 15) then
        d.lastLog = now
        Mark(src, 'drone', { event = 'position', x = math.floor(x), y = math.floor(y), z = math.floor(z) }, { clientReported = true })
    end
    return true
end

--- Ends flights past MaxSeconds and of operators who went off duty (every 5 s).
function G.DroneTick()
    local now = os.time()
    local max = tonumber(DroneCfg().MaxSeconds) or 600
    for src, d in pairs(drones) do
        local Player = exports['pfm-core']:GetPlayer(src)
        if not IsOnDutyLeo(Player) then
            G.DroneStop(src, 'off_duty')
        elseif now - d.started >= max then
            G.DroneStop(src, 'time')
        end
    end
end

QBCore.Functions.CreateUseableItem((Eq().Drone or {}).Item or 'police_drone', function(source)
    local src = source
    if drones[src] then G.DroneStop(src, 'landed') return end
    local res = G.DroneStart(src)
    if not res.ok then return Notify(src, res.error, 'error') end
    Notify(src, 'drone_started', 'success')
end)

RegisterNetEvent('police:server:DronePosition', function(x, y, z)
    G.DroneHint(source, x, y, z)
end)

RegisterNetEvent('police:server:DroneStop', function()
    G.DroneStop(source, 'landed')
end)

CreateThread(function()
    while true do
        Wait(5000)
        G.DroneTick()
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    tackleCooldowns[src] = nil
    gsrAt[src], gsrWritten[src] = nil, nil
    panicCooldowns[src] = nil
    k9At[src] = nil
    if drones[src] then drones[src] = nil end
    droneEnded[src] = nil
end)
