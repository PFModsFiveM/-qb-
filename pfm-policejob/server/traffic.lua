-- Traffic enforcement (batch 18B, architecture 4.10): radar, ALPR with a read log, speed cameras,
-- breathalyzer, plate checks (RunPlate), citations through pf-justice and traffic incident records.
--
-- Server truth: speeds come from GetEntitySpeed, plates from GetVehicleNumberPlateText, positions
-- and headings from the server's entity natives. A client only names the vehicle it points at
-- (radar) or the person it means (breath test, citation); everything else is read or checked here.
--
-- Plate flags come from pf-policemdt-DEV GetPlateFlags, cached per plate and refreshed at once by
-- the server event pf_mdt:server:plateFlagsChanged; /flagplate field flags (server/vehicle.lua) are
-- merged in as 'FIELD'.
--
-- Citations: one pf_police_citations row per citation uid, written before pf-justice is asked, and
-- the pf-justice key is 'pfm-policejob:citation:<uid>'. A citation pf-justice could not take yet
-- (not started, busy, database) stays 'pending' and is retried with the same key, so a citizen
-- gets one order per uid however often it is retried.
--
-- Exports: RunPlate(plate, opts), ListTrafficIncidents(filter). Net events (client -> server):
-- police:server:RadarMeasure(netId), police:server:AlprToggle(on), police:server:Breathalyze(target),
-- police:server:IssueCitation(target, code, speedEventId), police:server:LogTrafficIncident(data).
-- Callback police:server:runPlate(plate).

PFTraffic = PFTraffic or {}
local T = PFTraffic
local QB = QBCore or exports['pfm-core']:GetCoreObject({ 'Functions', 'Commands' })

T.FieldFlags = T.FieldFlags or {}
T.Readers = {}        -- [src] = { veh, since }: ALPR units switched on by an officer in a police car
T.FlagCache = {}      -- [PLATE] = { flags = {...}, boloIds = {...}, at, unknown }
T.Seen = {}           -- [readerKey|PLATE] = at: last logged read (dedupe)
T.Alerted = {}        -- [readerKey|PLATE] = at: last alert from a fixed reader
T.CamSeen = {}        -- [cam:id|PLATE] = at
T.ReadQueue = {}      -- reads waiting for the batched insert
T.Rate = {}           -- [src] = { [action] = game timer }
T.Submitting = {}     -- [uid] = true while pf-justice is asked
T.CiteLocks = {}      -- [speedEventId] = true while a citation for it is being written
T.Stats = { checks = 0, reads = 0, lookups = 0, ticks = 0 }

local function Cfg() return Config.Traffic or {} end
local function Sub(name) return Cfg()[name] or {} end
local function Now() return os.time() end

local function Notify(src, msg, kind) TriggerClientEvent('QBCore:Notify', src, msg, kind or 'primary') end

local function DbReady()
    return PFPoliceSchema ~= nil and PFPoliceSchema.Ready ~= nil and PFPoliceSchema.Ready() == true
end

local function Started(res) return GetResourceState(res) == 'started' end

local function GetPlayer(src) return exports['pfm-core']:GetPlayer(src) end

local function IsLeo(P)
    local job = P and P.PlayerData and P.PlayerData.job
    return job ~= nil and (Cfg().LeoJobTypes or { leo = true })[job.type] == true and job.onduty == true
end
T.IsLeo = IsLeo

local function Officer(src)
    local P = GetPlayer(src)
    if IsLeo(P) then return P end
    return nil
end

local function ValidSrc(src)
    src = math.tointeger(tonumber(src))
    if not src or src <= 0 then return nil end
    return src
end

local function RateOk(src, action, ms)
    local now = GetGameTimer()
    local r = T.Rate[src]
    if not r then r = {} T.Rate[src] = r end
    if r[action] and now - r[action] < (ms or 1000) then return false end
    r[action] = now
    return true
end

local function CleanText(v, max)
    if type(v) ~= 'string' then return nil end
    v = v:gsub('%c', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    if v == '' then return nil end
    return v:sub(1, max)
end

--- A plate as GTA shows it: upper case, outer spaces trimmed, letters/digits/inner spaces, 1-8 chars.
function T.Plate(p)
    if type(p) ~= 'string' and type(p) ~= 'number' then return nil end
    local s = tostring(p):upper():gsub('^%s+', ''):gsub('%s+$', '')
    if s == '' or #s > 8 or not s:match('^[%w ]+$') then return nil end
    return s
end

local function Dist(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function Round(n) return math.floor((tonumber(n) or 0) + 0.5) end

local function Affected(res)
    if type(res) == 'table' then return tonumber(res.affectedRows) or tonumber(res.changedRows) or 0 end
    return tonumber(res) or 0
end

local function Q(kind, sql, params)
    local ok, res = pcall(MySQL[kind].await, sql, params)
    if not ok then
        print(('^1[pfm-policejob]^7 traffic query failed: %s'):format(tostring(res)))
        return nil, false
    end
    return res, true
end

local function Fail(code, message) return { ok = false, error = code, message = message } end

local function HasItem(P, name)
    if not name then return true end
    for _, item in pairs(P and P.PlayerData and P.PlayerData.items or {}) do
        if type(item) == 'table' and item.name == name and (tonumber(item.amount) or 1) > 0 then return true end
    end
    return false
end

local function PedCoords(src) return GetEntityCoords(GetPlayerPed(src)) end

local function NameOf(P)
    local ci = P and P.PlayerData and P.PlayerData.charinfo or {}
    return (('%s %s'):format(tostring(ci.firstname or ''), tostring(ci.lastname or '')):gsub('^%s+', ''):gsub('%s+$', ''))
end

local function OnDutyLeoSources()
    local out = {}
    for _, P in pairs(QB.Functions.GetQBPlayers() or {}) do
        if IsLeo(P) then out[#out + 1] = P.PlayerData.source end
    end
    return out
end

-- ── police vehicles, limits ─────────────────────────────────────────────────────────────────────

local function NormHash(h)
    h = math.tointeger(tonumber(h)) or 0
    if h < 0 then h = h + 4294967296 end
    return h
end

local policeModels
function T.IsPoliceVehicle(veh)
    if not veh or veh == 0 then return false end
    if not policeModels then
        policeModels = {}
        for _, list in pairs(Config.AuthorizedVehicles or {}) do
            for model in pairs(list) do policeModels[NormHash(GetHashKey(model))] = true end
        end
        for _, model in ipairs(Cfg().PoliceModels or {}) do policeModels[NormHash(GetHashKey(model))] = true end
    end
    return policeModels[NormHash(GetEntityModel(veh))] == true
end

--- The speed limit (km/h) at a position: the first configured zone that contains it, else the default.
function T.LimitAt(pos)
    local cfg = Sub('SpeedLimits')
    for _, z in ipairs(cfg.Zones or {}) do
        if z.coords and Dist(pos, z.coords) <= (tonumber(z.radius) or 0) then return math.floor(tonumber(z.kmh) or cfg.DefaultKmh or 80) end
    end
    return math.floor(tonumber(cfg.DefaultKmh) or 80)
end

-- ── plate flags (pf-policemdt-DEV GetPlateFlags, cached) ─────────────────────────────────────────

local function NormalizeFlags(res)
    if type(res) ~= 'table' or res.ok == false then return nil end
    local list = type(res.flags) == 'table' and res.flags or (#res > 0 and res or {})
    local flags, boloIds = {}, {}
    for _, f in ipairs(list) do
        if type(f) == 'string' and #flags < 16 then
            local s = f:upper():gsub('[^%w_]', '')
            if s ~= '' then flags[#flags + 1] = s:sub(1, 16) end
        end
    end
    for _, id in ipairs(type(res.boloIds) == 'table' and res.boloIds or {}) do
        local n = math.tointeger(tonumber(id))
        if n and #boloIds < 32 then boloIds[#boloIds + 1] = n end
    end
    return { flags = flags, boloIds = boloIds }
end

function T.LookupMdt(plate)
    if not Started('pf-policemdt-DEV') then return nil end
    T.Stats.lookups = T.Stats.lookups + 1
    local ok, res = pcall(function() return exports['pf-policemdt-DEV']:GetPlateFlags(plate) end)
    if not ok then return nil end
    return NormalizeFlags(res)
end

local function FieldFlagOf(plate)
    local f = T.FieldFlags[plate]
    if not f or not f.isflagged then return nil end
    local hours = tonumber(Sub('Alpr').FieldFlagHours) or 12
    if f.at and Now() - f.at > hours * 3600 then T.FieldFlags[plate] = nil return nil end
    return f
end

--- Flags of a plate: { flags = {...}, boloIds = {...}, field = reason?, unknown = bool }.
--- opts.budget = { n }: a cache miss costs one lookup; with none left, nil (look again next tick).
--- opts.fresh: ask the MDT even when cached.
function T.FlagsFor(plate, opts)
    plate = T.Plate(plate)
    if not plate then return nil end
    opts = opts or {}
    local now = Now()
    local ttl = tonumber(Sub('Alpr').FlagCacheSeconds) or 300
    local e = T.FlagCache[plate]
    if opts.fresh or not e or now - (e.at or 0) > ttl then
        if opts.budget then
            if opts.budget.n <= 0 then return nil end
            opts.budget.n = opts.budget.n - 1
        end
        local looked = T.LookupMdt(plate)
        if looked then
            e = { flags = looked.flags, boloIds = looked.boloIds, at = now }
        elseif e then
            -- the MDT did not answer: keep the last answer a little longer
            e.at, e.unknown = now, true
        else
            e = { flags = {}, boloIds = {}, at = now, unknown = true }
        end
        T.FlagCache[plate] = e
    end
    local out = { flags = {}, boloIds = e.boloIds or {}, unknown = e.unknown == true }
    for _, f in ipairs(e.flags or {}) do out.flags[#out.flags + 1] = f end
    local field = FieldFlagOf(plate)
    if field then
        out.flags[#out.flags + 1] = 'FIELD'
        out.field = field.reason
    end
    return out
end

-- The MDT changed a plate's flags or BOLOs: the cached answer is replaced at once.
AddEventHandler('pf_mdt:server:plateFlagsChanged', function(plate, flags)
    plate = T.Plate(plate)
    if not plate then return end
    local n = NormalizeFlags(flags)
    if n then
        T.FlagCache[plate] = { flags = n.flags, boloIds = n.boloIds, at = Now() }
    else
        T.FlagCache[plate] = nil
    end
end)

-- ── spatial buckets ─────────────────────────────────────────────────────────────────────────────

--- Sorts every vehicle into square cells of `size` metres: { ['cx:cy'] = { { veh, pos } } }.
function T.BuildGrid(size)
    local grid, count = {}, 0
    for _, veh in ipairs(GetAllVehicles() or {}) do
        local p = GetEntityCoords(veh)
        if p then
            local k = math.floor(p.x / size) .. ':' .. math.floor(p.y / size)
            local cell = grid[k]
            if not cell then cell = {} grid[k] = cell end
            cell[#cell + 1] = { veh = veh, pos = p }
            count = count + 1
        end
    end
    return grid, count
end

--- Calls fn(entry) for every vehicle within `range` of pos, looking only at the cells that can hold one.
function T.ForEachNear(grid, size, pos, range, fn)
    local cx, cy = math.floor(pos.x / size), math.floor(pos.y / size)
    local span = math.max(1, math.ceil(range / size))
    for dx = -span, span do
        for dy = -span, span do
            local cell = grid[(cx + dx) .. ':' .. (cy + dy)]
            if cell then
                for _, e in ipairs(cell) do
                    T.Stats.checks = T.Stats.checks + 1
                    if Dist(e.pos, pos) <= range then fn(e) end
                end
            end
        end
    end
end

-- ── ALPR ────────────────────────────────────────────────────────────────────────────────────────

function T.QueueRead(row)
    local max = tonumber(Sub('Alpr').MaxQueuedReads) or 2000
    if #T.ReadQueue >= max then table.remove(T.ReadQueue, 1) end
    T.ReadQueue[#T.ReadQueue + 1] = row
    T.Stats.reads = T.Stats.reads + 1
end

--- Writes the queued reads in multi-row inserts (200 rows per statement).
function T.FlushReads()
    if #T.ReadQueue == 0 or not DbReady() then return 0 end
    local batch = T.ReadQueue
    T.ReadQueue = {}
    local written = 0
    for i = 1, #batch, 200 do
        local marks, params, n = {}, {}, 0
        for j = i, math.min(i + 199, #batch) do
            local r = batch[j]
            marks[#marks + 1] = '(?, ?, ?, ?, ?, ?, ?)'
            -- explicit positions: hit and speed may be nil and must keep their slot
            params[n + 1], params[n + 2], params[n + 3], params[n + 4] = r.plate, r.reader, r.x, r.y
            params[n + 5], params[n + 6], params[n + 7] = r.speed, r.hit, r.at
            n = n + 7
        end
        local _, ok = Q('insert', 'INSERT INTO pf_police_alpr_reads (plate, reader, x, y, speed_kmh, hit, at) VALUES ' .. table.concat(marks, ', '), params)
        if ok then written = written + #marks end
    end
    return written
end

local function FixedReaders()
    local cfg = Sub('Alpr')
    local out = {}
    for i, p in ipairs(cfg.FixedReaders or Config.Radars or {}) do
        local coords = p.coords or p
        if type(coords) == 'table' or type(coords) == 'vector3' then
            out[#out + 1] = { key = 'fixed:' .. i, kind = 'fixed', pos = coords, range = tonumber(p.radius) or tonumber(cfg.FixedRange) or 40.0, label = p.label or ('ALPR #' .. i) }
        end
    end
    return out
end

--- The readers that work this tick. A unit whose officer left the car or went off duty is switched off.
function T.ActiveReaders()
    local out = {}
    local range = tonumber(Sub('Alpr').Range) or 60.0
    for src, r in pairs(T.Readers) do
        local ped = GetPlayerPed(src)
        if not IsLeo(GetPlayer(src)) or not ped or ped == 0 or GetVehiclePedIsIn(ped, false) ~= r.veh or not DoesEntityExist(r.veh) then
            T.Readers[src] = nil
            TriggerClientEvent('police:client:AlprState', src, false)
        else
            local unit = T.Plate(GetVehicleNumberPlateText(r.veh)) or tostring(r.veh)
            out[#out + 1] = { key = ('unit:' .. unit):sub(1, 32), kind = 'unit', src = src, veh = r.veh, pos = GetEntityCoords(r.veh), range = range }
        end
    end
    for _, f in ipairs(FixedReaders()) do out[#out + 1] = f end
    return out
end

--- A fixed reader's alert for a plate within the dedupe window was already sent (shared with the
--- legacy police:server:FlaggedPlateTriggered report). Marks it sent otherwise.
function T.FixedAlertSeen(key, plate)
    local k = key .. '|' .. plate
    local now = Now()
    local window = tonumber(Sub('Alpr').DedupeSeconds) or 60
    if T.Alerted[k] and now - T.Alerted[k] < window then return true end
    T.Alerted[k] = now
    return false
end

local function PlateActivity(plate, spec)
    if not Started('pf-policemdt-DEV') then return end
    pcall(function() exports['pf-policemdt-DEV']:RecordPlateActivity(plate, spec) end)
end

function T.Alert(reader, plate, flags, pos, speed)
    local coords = { x = pos.x, y = pos.y, z = pos.z }
    local list = table.concat(flags.flags, ', ')
    if reader.kind == 'unit' then
        -- a unit's hit goes to the officer running it (architecture 7: owner only)
        TriggerClientEvent('police:client:AlprHit', reader.src, {
            plate = plate, flags = flags.flags, boloIds = flags.boloIds, field = flags.field, speed = speed, coords = coords,
        })
    else
        if T.FixedAlertSeen(reader.key, plate) then return end
        local message = ('ALPR %s: %s [%s]'):format(reader.label or reader.key, plate, list)
        -- a fixed reader alerts every on-duty police job (sheriff, state police...), not only 'police'
        for _, s in ipairs(OnDutyLeoSources()) do
            TriggerClientEvent('police:client:policeAlert', s, reader.pos, message)
        end
    end
    PlateActivity(plate, { type = 'alpr_hit', location = ('%.0f, %.0f'):format(pos.x, pos.y), referenceId = list:sub(1, 64) })
end

local function PruneMap(map, window, now)
    for k, at in pairs(map) do
        if now - at >= window then map[k] = nil end
    end
end

--- One ALPR pass (every Config.Traffic.Alpr.IntervalMs). Returns the number of hits.
function T.AlprTick(now)
    local cfg = Sub('Alpr')
    if cfg.Enabled == false then return 0 end
    now = now or Now()
    T.Stats.ticks = T.Stats.ticks + 1
    local readers = T.ActiveReaders()
    if #readers == 0 then return 0 end
    local size = tonumber(cfg.CellSize) or 60.0
    local window = tonumber(cfg.DedupeSeconds) or 60
    local grid = T.BuildGrid(size)
    local budget = { n = tonumber(cfg.MaxLookupsPerTick) or 25 }
    local hits = 0
    for _, r in ipairs(readers) do
        T.ForEachNear(grid, size, r.pos, r.range, function(e)
            if e.veh == r.veh then return end
            local plate = T.Plate(GetVehicleNumberPlateText(e.veh))
            if not plate then return end
            local seenKey = r.key .. '|' .. plate
            if T.Seen[seenKey] and now - T.Seen[seenKey] < window then return end
            local flags = T.FlagsFor(plate, { budget = budget })
            if not flags then return end -- lookup budget spent: read again next tick
            T.Seen[seenKey] = now
            local speed = Round((GetEntitySpeed(e.veh) or 0) * 3.6)
            local hit = #flags.flags > 0 and table.concat(flags.flags, ','):sub(1, 32) or nil
            T.QueueRead({ plate = plate, reader = r.key, x = e.pos.x, y = e.pos.y, speed = math.min(speed, 999), hit = hit, at = now })
            if hit then
                hits = hits + 1
                T.Alert(r, plate, flags, e.pos, speed)
            end
        end)
    end
    T.FlushReads()
    if T.Stats.ticks % 15 == 0 then
        PruneMap(T.Seen, window, now)
        PruneMap(T.Alerted, window, now)
        local ttl = tonumber(cfg.FlagCacheSeconds) or 300
        for p, e in pairs(T.FlagCache) do if now - (e.at or 0) > ttl then T.FlagCache[p] = nil end end
    end
    return hits
end

--- Switches the ALPR unit of the police car the officer sits in on or off.
function T.SetReader(src, on)
    if not on then
        T.Readers[src] = nil
        TriggerClientEvent('police:client:AlprState', src, false)
        return true
    end
    local ped = GetPlayerPed(src)
    local veh = ped and GetVehiclePedIsIn(ped, false) or 0
    if not veh or veh == 0 or not T.IsPoliceVehicle(veh) then
        Notify(src, 'The ALPR unit is in police vehicles only', 'error')
        return false
    end
    T.Readers[src] = { veh = veh, since = Now() }
    TriggerClientEvent('police:client:AlprState', src, true)
    return true
end

RegisterNetEvent('police:server:AlprToggle', function(on)
    local src = ValidSrc(source)
    if not src or not Officer(src) then return end
    if not RateOk(src, 'alpr', 1000) then return end
    T.SetReader(src, on == true)
end)

-- ── speed events, radar, cameras ────────────────────────────────────────────────────────────────

--- One pf_police_speed_events row; returns its id (nil without the database).
function T.RecordSpeedEvent(e)
    if not DbReady() then return nil end
    local id = Q('insert', 'INSERT INTO pf_police_speed_events (plate, source, officer_cid, speed_kmh, limit_kmh, x, y, at, driver_cid) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        { e.plate, e.source, e.officerCid, math.min(e.speed, 999), e.limit, e.x, e.y, e.at or Now(), e.driverCid })
    return tonumber(id)
end

-- GTA heading: degrees, 0 = north (+y), counter-clockwise; the bearing of (dx, dy) in that frame
local function Bearing(dx, dy) return math.deg(math.atan(-dx, dy)) % 360 end
local function AngleDiff(a, b)
    local d = math.abs((a - b) % 360)
    return d > 180 and 360 - d or d
end

--- Measures the vehicle with network id netId for the officer src. Returns a result table.
function T.RadarMeasure(src, netId)
    local P = Officer(src)
    if not P then return Fail('no_permission', 'On-duty police only') end
    local cfg = Sub('Radar')
    netId = math.tointeger(tonumber(netId))
    if not netId or netId <= 0 or netId > 2147483647 then return Fail('bad_args') end
    local target = NetworkGetEntityFromNetworkId(netId)
    if not target or target == 0 or not DoesEntityExist(target) or GetEntityType(target) ~= 2 then return Fail('not_found', 'No vehicle there') end
    local ped = GetPlayerPed(src)
    local own = GetVehiclePedIsIn(ped, false)
    local origin, heading, device
    if own and own ~= 0 and T.IsPoliceVehicle(own) then
        origin, heading, device = GetEntityCoords(own), GetEntityHeading(own), 'vehicle'
    else
        if not HasItem(P, cfg.Item) then return Fail('no_permission', 'You need a radar gun') end
        origin, heading, device = GetEntityCoords(ped), GetEntityHeading(ped), 'handheld'
    end
    if target == own then return Fail('bad_args') end
    local tpos = GetEntityCoords(target)
    if Dist(tpos, origin) > (tonumber(cfg.Range) or 150.0) then return Fail('too_far', 'Out of radar range') end
    local half = (tonumber(cfg.ConeDegrees) or 12.0) / 2
    local bearing = Bearing(tpos.x - origin.x, tpos.y - origin.y)
    local inCone = AngleDiff(bearing, heading) <= half
    if not inCone and device == 'vehicle' and cfg.RearAntenna then inCone = AngleDiff(bearing, (heading + 180) % 360) <= half end
    if not inCone then return Fail('too_far', 'The vehicle is not in the radar beam') end
    local speed = Round((GetEntitySpeed(target) or 0) * 3.6)
    local limit = T.LimitAt(tpos)
    local plate = T.Plate(GetVehicleNumberPlateText(target))
    local eventId
    if plate and speed > limit then
        -- the driver as the server sees it now: only this player (or the plate's owner) can be cited
        local driver = T.DriverOf(target)
        local DP = driver and GetPlayer(driver)
        eventId = T.RecordSpeedEvent({ plate = plate, source = 'radar', officerCid = P.PlayerData.citizenid, speed = speed, limit = limit,
            x = tpos.x, y = tpos.y, driverCid = DP and DP.PlayerData.citizenid or nil })
    end
    return { ok = true, plate = plate, speed = speed, limit = limit, device = device, eventId = eventId }
end

RegisterNetEvent('police:server:RadarMeasure', function(netId)
    local src = ValidSrc(source)
    if not src then return end
    if not RateOk(src, 'radar', tonumber(Sub('Radar').MinIntervalMs) or 500) then return end
    local res = T.RadarMeasure(src, netId)
    if res.ok then
        TriggerClientEvent('police:client:RadarReading', src, res)
    elseif res.message then
        Notify(src, res.message, 'error')
    end
end)

--- The player driving `veh`, or nil.
function T.DriverOf(veh)
    local ped = GetPedInVehicleSeat(veh, -1)
    if not ped or ped == 0 then return nil end
    for _, P in pairs(QB.Functions.GetQBPlayers() or {}) do
        local s = P.PlayerData and P.PlayerData.source
        if s and GetPlayerPed(s) == ped then return s end
    end
    return nil
end

local function SpeedingAmount(speed, limit)
    local s = Sub('Citations').Speeding or {}
    local over = math.max(0, speed - limit)
    return math.floor(math.min(tonumber(s.Max) or 2500, (tonumber(s.Base) or 150) + over * (tonumber(s.PerKmh) or 10)))
end

--- One speed-camera pass (every Config.Traffic.SpeedCameras.IntervalMs). Returns the speed events written.
function T.CameraTick(now)
    local cfg = Sub('SpeedCameras')
    local list = cfg.List or {}
    if cfg.Enabled == false or #list == 0 then return 0 end
    now = now or Now()
    local size = tonumber(Sub('Alpr').CellSize) or 60.0
    local grid = T.BuildGrid(size)
    local window = tonumber(cfg.DedupeSeconds) or 120
    local events = 0
    for i = 1, math.min(#list, tonumber(cfg.Max) or 24) do
        local cam = list[i]
        local limit = math.floor(tonumber(cam.kmh) or T.LimitAt(cam.coords))
        T.ForEachNear(grid, size, cam.coords, tonumber(cam.radius) or 30.0, function(e)
            local speed = Round((GetEntitySpeed(e.veh) or 0) * 3.6)
            if speed <= limit + (tonumber(cfg.ToleranceKmh) or 10) then return end
            local plate = T.Plate(GetVehicleNumberPlateText(e.veh))
            if not plate then return end
            local key = 'cam:' .. tostring(cam.id or i) .. '|' .. plate
            if T.CamSeen[key] and now - T.CamSeen[key] < window then return end
            T.CamSeen[key] = now
            local driver = T.DriverOf(e.veh)
            local DP = driver and GetPlayer(driver)
            local id = T.RecordSpeedEvent({ plate = plate, source = 'camera', speed = speed, limit = limit, x = e.pos.x, y = e.pos.y, at = now,
                driverCid = DP and DP.PlayerData.citizenid or nil })
            T.QueueRead({ plate = plate, reader = ('cam:' .. tostring(cam.id or i)):sub(1, 32), x = e.pos.x, y = e.pos.y, speed = math.min(speed, 999), at = now })
            if not id then return end
            events = events + 1
            if not cfg.AutoCite then DP = nil end
            -- on-duty police and EMS drivers are logged, never cited (responding to calls)
            local job = DP and DP.PlayerData.job or {}
            local exempt = job.onduty == true and (cfg.ExemptJobTypes or { leo = true, ems = true })[job.type] == true
            if DP and not exempt then
                local res = T.CreateCitation({
                    uid = 'SE' .. id, cid = DP.PlayerData.citizenid, code = 'speeding', violation = 'Speeding (camera ' .. tostring(cam.label or cam.id or i) .. ')',
                    amount = SpeedingAmount(speed, limit), plate = plate, speedEventId = id, speed = speed, limit = limit, x = cam.coords.x, y = cam.coords.y,
                })
                if res.ok or res.pending then
                    Notify(driver, ('Speed camera: %d km/h in a %d zone. A citation was issued.'):format(speed, limit), 'error')
                end
            end
        end)
    end
    T.FlushReads()
    PruneMap(T.CamSeen, window, now)
    return events
end

-- ── breathalyzer ────────────────────────────────────────────────────────────────────────────────

--- BAC of a player from pf-ambulancejob (the engine's ethanol level), or nil when it cannot answer.
function T.ReadBac(target)
    if not Started('pf-ambulancejob') then return nil, 'unavailable' end
    local ok, res = pcall(function() return exports['pf-ambulancejob']:GetBreathAlcohol(target) end)
    if not ok or type(res) ~= 'table' or res.ok ~= true then return nil, type(res) == 'table' and res.error or 'unavailable' end
    local bac = tonumber(res.bac)
    if not bac or bac ~= bac or bac < 0 then return nil, 'bad_result' end
    return math.floor(math.min(bac, 0.999) * 1000 + 0.5) / 1000
end

function T.Breathalyze(src, target)
    local P = Officer(src)
    if not P then return Fail('no_permission', 'On-duty police only') end
    local cfg = Sub('Breath')
    target = ValidSrc(target)
    if not target or target == src then return Fail('bad_args') end
    local TP = GetPlayer(target)
    if not TP then return Fail('offline', 'Nobody there') end
    if not HasItem(P, cfg.Item) then return Fail('no_permission', 'You need a breathalyzer') end
    if Dist(PedCoords(src), PedCoords(target)) > (tonumber(cfg.Distance) or 2.5) then return Fail('too_far', 'Too far away') end
    local bac = T.ReadBac(target)
    if not bac then return Fail('db_unavailable', 'The breathalyzer cannot read a result right now') end
    local id
    if DbReady() then
        id = tonumber((Q('insert', 'INSERT INTO pf_police_breath_tests (citizenid, officer_cid, bac, device, at) VALUES (?, ?, ?, ?, ?)',
            { TP.PlayerData.citizenid, P.PlayerData.citizenid, bac, tostring(cfg.Item or 'breathalyzer'):sub(1, 16), Now() })))
    end
    local limit = tonumber(cfg.LegalLimit) or 0.08
    return { ok = true, bac = bac, limit = limit, over = bac >= limit, testId = id, target = target }
end

RegisterNetEvent('police:server:Breathalyze', function(target)
    local src = ValidSrc(source)
    if not src then return end
    if not RateOk(src, 'breath', tonumber(Sub('Breath').MinIntervalMs) or 5000) then return end
    local res = T.Breathalyze(src, target)
    if not res.ok then
        if res.message then Notify(src, res.message, 'error') end
        return
    end
    local text = ('BAC %.3f (%s the %.2f limit)'):format(res.bac, res.over and 'over' or 'under', res.limit)
    TriggerClientEvent('police:client:BreathResult', src, { bac = res.bac, limit = res.limit, over = res.over, testId = res.testId })
    Notify(src, text, res.over and 'error' or 'success')
    Notify(res.target, 'Breath test: ' .. text, 'primary')
end)

-- ── citations ───────────────────────────────────────────────────────────────────────────────────

T.SQL = {
    citeInsert = 'INSERT INTO pf_police_citations (uid, citizenid, officer_cid, code, violation, amount, plate, speed_event_id, speed_kmh, limit_kmh, x, y, state, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    citeByUid = 'SELECT * FROM pf_police_citations WHERE uid = ? LIMIT 1',
    citeBySpeed = 'SELECT * FROM pf_police_citations WHERE speed_event_id = ? LIMIT 1',
    citeIssued = "UPDATE pf_police_citations SET state = 'issued', order_id = ?, citation_id = ?, error = NULL, updated_at = ? WHERE id = ? AND state = 'pending'",
    citeRetry = "UPDATE pf_police_citations SET attempts = attempts + 1, next_at = ?, error = ?, updated_at = ? WHERE id = ? AND state = 'pending'",
    citeFailed = "UPDATE pf_police_citations SET state = 'failed', attempts = attempts + 1, error = ?, updated_at = ? WHERE id = ? AND state = 'pending'",
    citeDue = "SELECT * FROM pf_police_citations WHERE state = 'pending' AND next_at <= ? ORDER BY id LIMIT 20",
    speedEvent = 'SELECT id, plate, officer_cid, speed_kmh, limit_kmh, citation_order_id, at, driver_cid FROM pf_police_speed_events WHERE id = ? LIMIT 1',
    plateOwner = 'SELECT citizenid FROM player_vehicles WHERE plate = ? LIMIT 1',
    speedLink = 'UPDATE pf_police_speed_events SET citation_order_id = ? WHERE id = ? AND citation_order_id IS NULL',
}

-- pf-justice answers that mean "not now": the citation stays pending and is retried with the same key
local RETRY = { db_unavailable = true, busy = true, offline = true }

local function NewUid() return ('PJ%X%04X'):format(Now(), math.random(0, 0xFFFF)) end

local function CitationKey(uid) return 'pfm-policejob:citation:' .. uid end

local function CallJustice(row, officerSrc)
    if not Started('pf-justice') then return Fail('db_unavailable', 'pf-justice is not running') end
    local spec = {
        cid = row.citizenid, amount = tonumber(row.amount), violation = row.violation, plate = row.plate,
        speed = tonumber(row.speed_kmh), limit = tonumber(row.limit_kmh),
    }
    local actor
    if officerSrc then
        -- pf-justice re-reads the officer's job, duty and position from the source
        spec.officerSrc, actor = officerSrc, { src = officerSrc }
    else
        spec.location = { x = tonumber(row.x), y = tonumber(row.y) }
        actor = { kind = 'system', label = row.officer_cid and 'pfm-policejob citation' or 'pfm-policejob speed camera' }
    end
    local ok, res = pcall(function() return exports['pf-justice']:IssueCitation(spec, { key = CitationKey(row.uid), actor = actor }) end)
    if not ok or type(res) ~= 'table' then return Fail('db_unavailable', 'pf-justice did not answer') end
    return res
end

local function CitationDocument(row, res)
    if Sub('Citations').Document == false or not Started('pf-citizen') then return end
    local lines = {
        ('Citation %s'):format(row.uid),
        ('Violation: %s'):format(row.violation),
        ('Amount: $%d'):format(tonumber(row.amount) or 0),
    }
    if row.plate then lines[#lines + 1] = ('Vehicle: %s'):format(row.plate) end
    if tonumber(row.speed_kmh) then lines[#lines + 1] = ('Speed: %d km/h in a %d km/h zone'):format(tonumber(row.speed_kmh), tonumber(row.limit_kmh) or 0) end
    lines[#lines + 1] = ('Issued: %s'):format(os.date('%Y-%m-%d %H:%M', Now()))
    lines[#lines + 1] = ('Justice order #%s'):format(tostring(res.orderId))
    pcall(function() exports['pf-citizen']:CreateDocument(row.citizenid, { title = ('Traffic citation %s'):format(row.uid), body = table.concat(lines, '\n') }) end)
end

--- Asks pf-justice for the order of one pending citation row. Returns { ok, orderId } or a failure;
--- `pending = true` when it stays pending for a retry with the same key.
function T.SubmitCitation(row, officerSrc)
    if T.Submitting[row.uid] then return { ok = false, error = 'busy', pending = true } end
    T.Submitting[row.uid] = true
    local now = Now()
    local res = CallJustice(row, officerSrc)
    local out
    if res.ok then
        local first = Affected(Q('update', T.SQL.citeIssued, { tonumber(res.orderId), tonumber(res.citationId), now, row.id })) == 1
        if first then
            if tonumber(row.speed_event_id) then Q('update', T.SQL.speedLink, { tonumber(res.orderId), tonumber(row.speed_event_id) }) end
            CitationDocument(row, res)
            if row.plate then PlateActivity(row.plate, { type = 'citation', officerCid = row.officer_cid, referenceId = tostring(res.orderId) }) end
            local TP = exports['pfm-core']:GetPlayerByCitizenId(row.citizenid)
            if TP then Notify(TP.PlayerData.source, ('You received a traffic citation: %s, $%d'):format(row.violation, tonumber(row.amount) or 0), 'error') end
        end
        out = { ok = true, orderId = tonumber(res.orderId), citationId = tonumber(res.citationId), uid = row.uid, duplicate = res.duplicate }
    elseif RETRY[res.error] then
        local attempts = (tonumber(row.attempts) or 0) + 1
        if attempts >= (tonumber(Sub('Citations').MaxAttempts) or 30) then
            Q('update', T.SQL.citeFailed, { tostring(res.error):sub(1, 32), now, row.id })
            out = { ok = false, error = res.error, message = res.message }
        else
            Q('update', T.SQL.citeRetry, { now + (tonumber(Sub('Citations').RetrySeconds) or 60), tostring(res.error):sub(1, 32), now, row.id })
            out = { ok = false, error = res.error, pending = true, uid = row.uid, message = res.message }
        end
    else
        Q('update', T.SQL.citeFailed, { tostring(res.error or 'failed'):sub(1, 32), now, row.id })
        out = { ok = false, error = res.error or 'failed', message = res.message }
    end
    T.Submitting[row.uid] = nil
    return out
end

--- Writes the citation row, then asks pf-justice. spec = { uid?, cid, officerCid?, officerSrc?, code,
--- violation, amount, plate?, speedEventId?, speed?, limit?, x?, y? }.
function T.CreateCitation(spec)
    if not DbReady() then return Fail('db_unavailable', 'Citations are not available yet') end
    local amount = math.tointeger(tonumber(spec.amount))
    if type(spec.cid) ~= 'string' or spec.cid == '' or not amount or amount <= 0 then return Fail('bad_args') end
    local now = Now()
    local uid = spec.uid or NewUid()
    local params = {
        uid, spec.cid, spec.officerCid, tostring(spec.code):sub(1, 24), CleanText(spec.violation, 48) or 'Traffic violation', amount,
        spec.plate, spec.speedEventId, spec.speed, spec.limit, spec.x, spec.y, 'pending', now, now,
    }
    local id = tonumber((Q('insert', T.SQL.citeInsert, params)))
    if not id then
        -- the reading was cited before (unique speed_event_id), or the same uid is already stored
        local row = spec.speedEventId and Q('single', T.SQL.citeBySpeed, { spec.speedEventId }) or Q('single', T.SQL.citeByUid, { uid })
        if type(row) == 'table' and row.id then
            if row.uid == uid and row.state == 'pending' then return T.SubmitCitation(row, spec.officerSrc) end
            return { ok = false, error = 'conflict', message = 'This was cited already', uid = row.uid, orderId = tonumber(row.order_id) }
        end
        return Fail('db_unavailable', 'The citation could not be saved')
    end
    local row = {
        id = id, uid = uid, citizenid = spec.cid, officer_cid = spec.officerCid, code = spec.code, violation = params[5],
        amount = amount, plate = spec.plate, speed_event_id = spec.speedEventId, speed_kmh = spec.speed, limit_kmh = spec.limit,
        x = spec.x, y = spec.y, attempts = 0, state = 'pending',
    }
    return T.SubmitCitation(row, spec.officerSrc)
end

--- An officer cites the player `target` for violation `code` (speeding needs the officer's own radar reading).
function T.IssueCitation(src, target, code, speedEventId)
    local P = Officer(src)
    if not P then return Fail('no_permission', 'On-duty police only') end
    local cfg = Sub('Citations')
    target = ValidSrc(target)
    if not target or target == src then return Fail('bad_args') end
    local TP = GetPlayer(target)
    if not TP then return Fail('offline', 'Nobody there') end
    if type(code) ~= 'string' or not (cfg.Violations or {})[code] then return Fail('bad_args', 'Unknown violation') end
    local v = cfg.Violations[code]
    local opos, tpos = PedCoords(src), PedCoords(target)
    if Dist(opos, tpos) > (tonumber(cfg.Distance) or 5.0) then return Fail('too_far', 'Too far away') end
    local spec = { cid = TP.PlayerData.citizenid, officerCid = P.PlayerData.citizenid, officerSrc = src, code = code, violation = v.label or code, x = opos.x, y = opos.y }
    if v.speed then
        local evId = math.tointeger(tonumber(speedEventId))
        if not evId or evId <= 0 then return Fail('bad_args', 'Measure the speed with the radar first') end
        if T.CiteLocks[evId] then return Fail('busy', 'This reading is being cited') end
        -- held from before the first database wait until the citation row exists
        T.CiteLocks[evId] = true
        local ev = Q('single', T.SQL.speedEvent, { evId })
        local maxAge = tonumber(cfg.SpeedEventMaxAgeSeconds) or 900
        local bad
        if type(ev) ~= 'table' or not ev.id then bad = Fail('not_found', 'No such radar reading')
        elseif ev.officer_cid ~= P.PlayerData.citizenid then bad = Fail('no_permission', 'Only the officer who measured can cite this reading')
        elseif Now() - (tonumber(ev.at) or 0) > maxAge then bad = Fail('invalid_state', 'This reading is too old')
        elseif ev.citation_order_id ~= nil then bad = Fail('conflict', 'This reading was cited already')
        elseif (tonumber(ev.speed_kmh) or 0) <= (tonumber(ev.limit_kmh) or 0) then bad = Fail('invalid_state', 'No speeding in this reading')
        elseif ev.driver_cid ~= spec.cid then
            -- the reading is tied to its vehicle: the cited player drove it when it was measured, or owns it
            local owner = Q('scalar', T.SQL.plateOwner, { ev.plate })
            if type(owner) ~= 'string' or owner ~= spec.cid then
                bad = Fail('no_permission', 'This person was not driving the measured vehicle and does not own it')
            end
        end
        if bad then T.CiteLocks[evId] = nil return bad end
        spec.speedEventId, spec.plate = evId, ev.plate
        spec.speed, spec.limit = tonumber(ev.speed_kmh), tonumber(ev.limit_kmh)
        spec.amount = SpeedingAmount(spec.speed, spec.limit)
        local res = T.CreateCitation(spec)
        T.CiteLocks[evId] = nil
        return res
    end
    spec.amount = math.floor(tonumber(v.amount) or 0)
    local veh = GetVehiclePedIsIn(GetPlayerPed(target), false)
    if veh and veh ~= 0 then spec.plate = T.Plate(GetVehicleNumberPlateText(veh)) end
    return T.CreateCitation(spec)
end

RegisterNetEvent('police:server:IssueCitation', function(target, code, speedEventId)
    local src = ValidSrc(source)
    if not src then return end
    if not RateOk(src, 'cite', tonumber(Sub('Citations').MinIntervalMs) or 1000) then return end
    local res = T.IssueCitation(src, target, code, speedEventId)
    if res.ok then
        Notify(src, ('Citation issued (order #%s)'):format(tostring(res.orderId)), 'success')
    elseif res.pending then
        Notify(src, 'Citation saved: it is filed as soon as the justice system answers', 'primary')
    else
        Notify(src, res.message or ('Citation refused: %s'):format(tostring(res.error)), 'error')
    end
end)

local function OnlineOfficerByCid(cid)
    if not cid then return nil end
    local P = exports['pfm-core']:GetPlayerByCitizenId(cid)
    if P and IsLeo(P) then return P.PlayerData.source end
    return nil
end

--- Retries pending citations whose time has come (same uid, same pf-justice key).
function T.CitationSweep(now)
    if not DbReady() then return 0 end
    local rows = Q('query', T.SQL.citeDue, { now or Now() })
    local n = 0
    for _, row in ipairs(type(rows) == 'table' and rows or {}) do
        if row.uid and not T.Submitting[row.uid] then
            T.SubmitCitation(row, OnlineOfficerByCid(row.officer_cid))
            n = n + 1
        end
    end
    return n
end

-- ── traffic incidents ───────────────────────────────────────────────────────────────────────────

function T.LogIncident(src, data)
    local P = Officer(src)
    if not P then return Fail('no_permission', 'On-duty police only') end
    if not DbReady() then return Fail('db_unavailable', 'Records are not available yet') end
    local cfg = Sub('Incidents')
    if type(data) ~= 'table' or type(data.kind) ~= 'string' or not (cfg.Kinds or {})[data.kind] then return Fail('bad_args', 'Unknown incident kind') end
    local pos = PedCoords(src)
    local radius = tonumber(cfg.Radius) or 30.0
    -- plates: only vehicles the server sees near the officer
    local plates, wanted = {}, {}
    for i, p in ipairs(type(data.plates) == 'table' and data.plates or {}) do
        if i > (tonumber(cfg.MaxPlates) or 6) then break end
        local plate = T.Plate(p)
        if plate then wanted[plate] = true end
    end
    if next(wanted) then
        for _, veh in ipairs(GetAllVehicles() or {}) do
            local plate = T.Plate(GetVehicleNumberPlateText(veh))
            if plate and wanted[plate] and Dist(GetEntityCoords(veh), pos) <= radius then
                wanted[plate] = nil
                plates[#plates + 1] = plate
            end
        end
    end
    -- people: online players near the officer, stored by citizenid
    local people, seen = {}, {}
    for i, id in ipairs(type(data.people) == 'table' and data.people or {}) do
        if i > (tonumber(cfg.MaxPeople) or 8) then break end
        local s = ValidSrc(id)
        local TP = s and not seen[s] and GetPlayer(s)
        if TP and Dist(PedCoords(s), pos) <= radius then
            seen[s] = true
            people[#people + 1] = { cid = TP.PlayerData.citizenid, name = NameOf(TP) }
        end
    end
    local mdt = CleanText(data.mdtIncidentId, 32)
    if mdt and not mdt:match('^[%w%-_:#]+$') then mdt = nil end
    table.sort(plates)
    local id = tonumber((Q('insert', 'INSERT INTO pf_police_traffic_incidents (kind, x, y, plates, people, officer_cid, summary, mdt_incident_id, at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        { data.kind, pos.x, pos.y, json.encode(plates), json.encode(people), P.PlayerData.citizenid, CleanText(data.summary, 500), mdt, Now() })))
    if not id then return Fail('db_unavailable', 'The incident could not be saved') end
    if data.kind == 'stop' then
        for _, plate in ipairs(plates) do PlateActivity(plate, { type = 'traffic_stop', officerCid = P.PlayerData.citizenid, officerName = NameOf(P), referenceId = tostring(id) }) end
    end
    return { ok = true, id = id, plates = plates, people = people }
end

RegisterNetEvent('police:server:LogTrafficIncident', function(data)
    local src = ValidSrc(source)
    if not src then return end
    if not RateOk(src, 'incident', tonumber(Sub('Incidents').MinIntervalMs) or 5000) then return end
    local res = T.LogIncident(src, data)
    if res.ok then
        Notify(src, ('Traffic incident #%d logged (%d vehicles, %d people)'):format(res.id, #res.plates, #res.people), 'success')
    elseif res.message then
        Notify(src, res.message, 'error')
    end
end)

--- Traffic incident records, newest first. filter = { plate?, officerCid?, since?, limit <= 100 }.
function T.ListIncidents(filter)
    if not DbReady() then return Fail('db_unavailable') end
    filter = type(filter) == 'table' and filter or {}
    local where, params = { '1 = 1' }, {}
    local plate = filter.plate ~= nil and T.Plate(filter.plate) or nil
    if filter.plate ~= nil and not plate then return Fail('bad_args') end
    if plate then where[#where + 1] = 'plates LIKE ?'; params[#params + 1] = '%"' .. plate .. '"%' end
    if type(filter.officerCid) == 'string' and #filter.officerCid <= 64 then where[#where + 1] = 'officer_cid = ?'; params[#params + 1] = filter.officerCid end
    local since = math.tointeger(tonumber(filter.since))
    if since then where[#where + 1] = 'at >= ?'; params[#params + 1] = since end
    local limit = math.max(1, math.min(100, math.tointeger(tonumber(filter.limit)) or 50))
    local rows, ok = Q('query', ('SELECT id, kind, x, y, plates, people, officer_cid, summary, mdt_incident_id, at FROM pf_police_traffic_incidents WHERE %s ORDER BY id DESC LIMIT %d'):format(table.concat(where, ' AND '), limit), params)
    if not ok then return Fail('db_unavailable') end
    local list = {}
    for _, r in ipairs(type(rows) == 'table' and rows or {}) do
        list[#list + 1] = {
            id = tonumber(r.id), kind = r.kind, x = tonumber(r.x), y = tonumber(r.y), plates = json.decode(r.plates or '[]') or {},
            people = json.decode(r.people or '[]') or {}, officerCid = r.officer_cid, summary = r.summary, mdtIncidentId = r.mdt_incident_id, at = tonumber(r.at),
        }
    end
    return { ok = true, list = list }
end

-- ── RunPlate ────────────────────────────────────────────────────────────────────────────────────

local function Decode(v)
    if type(v) == 'table' then return v end
    if type(v) ~= 'string' then return {} end
    return json.decode(v) or {}
end

--- RunPlate (architecture 4.10): owner, licence, MDT flags and BOLOs, impound. Registration and
--- insurance are 'unknown': nothing in the city keeps a per-plate registration or an insurer.
function T.RunPlate(plate)
    plate = T.Plate(plate)
    if not plate then return Fail('bad_args', 'Invalid plate') end
    local row, ok = Q('single', 'SELECT pv.citizenid, pv.vehicle, pv.state, p.charinfo, p.metadata FROM player_vehicles pv LEFT JOIN players p ON p.citizenid = pv.citizenid WHERE pv.plate = ? LIMIT 1', { plate })
    if not ok then return Fail('db_unavailable', 'The vehicle register did not answer') end
    local out = { ok = true, plate = plate, registration = 'unknown', insurance = 'unknown' }
    if type(row) == 'table' and row.citizenid then
        local ci, md = Decode(row.charinfo), Decode(row.metadata)
        local lic = type(md.licences) == 'table' and md.licences or {}
        out.model = row.vehicle
        out.owner = {
            citizenid = row.citizenid,
            name = (('%s %s'):format(tostring(ci.firstname or ''), tostring(ci.lastname or '')):gsub('^%s+', ''):gsub('%s+$', '')),
            licence = { driver = lic.driver == true and 'valid' or (lic.driver == false and 'revoked' or 'none') },
        }
        if Started('pf-government') then
            local okG, has = pcall(function() return exports['pf-government']:HasLicense(row.citizenid, Sub('RunPlate').GovDriverLicense or 'drivers_license') end)
            if okG then out.owner.licence.government = has == true end
        end
    else
        out.owner = nil
    end
    local f = T.FlagsFor(plate, { fresh = true })
    out.flags, out.bolos, out.fieldFlag, out.flagsUnavailable = f.flags, f.boloIds, f.field, f.unknown or nil
    if PFImpound and PFImpound.Get then
        local imp = PFImpound.Get(plate)
        if imp.ok then out.impound = imp.impound end
    end
    return out
end

local function CallerAllowed(name)
    local invoker = GetInvokingResource()
    if invoker == nil or invoker == GetCurrentResourceName() then return true end
    local list = (Cfg().Callers or {})[name]
    return list == '*' or (type(list) == 'table' and list[invoker] == true)
end

exports('RunPlate', function(plate, opts)
    if not CallerAllowed('RunPlate') then return Fail('not_allowed') end
    -- a player viewer (an MDT page) must be on-duty police
    if type(opts) == 'table' and opts.viewer ~= nil then
        local v = ValidSrc(opts.viewer)
        if not v or not Officer(v) then return Fail('no_permission') end
    end
    return T.RunPlate(plate)
end)

exports('ListTrafficIncidents', function(filter)
    if not CallerAllowed('ListTrafficIncidents') then return Fail('not_allowed') end
    return T.ListIncidents(filter)
end)

QB.Functions.CreateCallback('police:server:runPlate', function(source, cb, plate)
    local src = ValidSrc(source)
    if not src or not Officer(src) or not RateOk(src, 'runplate', 1000) then return cb(Fail('no_permission')) end
    cb(T.RunPlate(plate))
end)

--- /plateinfo: the plate check as notifications for the officer.
function T.RunPlateFor(src, plate)
    local r = T.RunPlate(plate)
    if not r.ok then return Notify(src, r.message or 'Plate check failed', 'error') end
    local owner = r.owner and ('%s (%s), licence %s'):format(r.owner.name ~= '' and r.owner.name or 'unknown', r.owner.citizenid, r.owner.licence.driver) or 'no registered owner'
    Notify(src, ('%s: %s'):format(r.plate, owner), 'primary')
    if #r.flags > 0 then
        Notify(src, ('Flags: %s%s'):format(table.concat(r.flags, ', '), r.fieldFlag and (' (field: ' .. r.fieldFlag .. ')') or ''), 'error')
    elseif r.flagsUnavailable then
        Notify(src, 'MDT flags unavailable right now', 'error')
    else
        Notify(src, 'No flags', 'success')
    end
    if r.impound then
        Notify(src, ('Impound: %s, %s%s'):format(r.impound.kind, r.impound.reason, r.impound.holdUntil and (' (held until ' .. os.date('%Y-%m-%d %H:%M', r.impound.holdUntil) .. ')') or ''), 'primary')
    end
end

-- ── commands, cleanup, loops ────────────────────────────────────────────────────────────────────

QB.Commands.Add('alpr', 'Switch the ALPR unit of your police vehicle on or off (Police Only)', {}, false, function(source)
    local src = ValidSrc(source)
    if not src then return end
    if not Officer(src) then return Notify(src, 'On-duty police only', 'error') end
    T.SetReader(src, T.Readers[src] == nil)
end)

AddEventHandler('playerDropped', function()
    local src = ValidSrc(source)
    if not src then return end
    T.Readers[src] = nil
    T.Rate[src] = nil
end)

-- Per-citizen rows of this module when a character is deleted (impound records keep the plate
-- history without the owner).
AddEventHandler('pfm-core:server:characterDeleted', function(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' or not DbReady() then return end
    Q('update', 'DELETE FROM pf_police_breath_tests WHERE citizenid = ?', { citizenid })
    Q('update', 'DELETE FROM pf_police_citations WHERE citizenid = ?', { citizenid })
    Q('update', 'UPDATE pf_police_impounds SET owner_cid = NULL WHERE owner_cid = ?', { citizenid })
end)

--- Deletes ALPR reads older than the retention, 500 at a time.
function T.RetentionSweep(now)
    if not DbReady() then return 0 end
    local cutoff = (now or Now()) - (tonumber(Sub('Alpr').RetentionDays) or 14) * 86400
    local total = 0
    for _ = 1, 20 do
        local n = Affected(Q('update', 'DELETE FROM pf_police_alpr_reads WHERE at < ? LIMIT 500', { cutoff }))
        total = total + n
        if n < 500 then break end
    end
    return total
end

CreateThread(function()
    if PFPoliceSchema and PFPoliceSchema.WaitReady then PFPoliceSchema.WaitReady() end
    while true do
        Wait(tonumber(Sub('Alpr').IntervalMs) or 2000)
        local ok, err = pcall(T.AlprTick)
        if not ok then print(('^1[pfm-policejob]^7 ALPR tick failed: %s'):format(tostring(err))) end
    end
end)

CreateThread(function()
    if PFPoliceSchema and PFPoliceSchema.WaitReady then PFPoliceSchema.WaitReady() end
    while true do
        Wait(tonumber(Sub('SpeedCameras').IntervalMs) or 1000)
        local ok, err = pcall(T.CameraTick)
        if not ok then print(('^1[pfm-policejob]^7 speed camera tick failed: %s'):format(tostring(err))) end
    end
end)

CreateThread(function()
    if PFPoliceSchema and PFPoliceSchema.WaitReady then PFPoliceSchema.WaitReady() end
    local lastRetention = 0
    while true do
        pcall(T.CitationSweep)
        if Now() - lastRetention >= 86400 then
            lastRetention = Now()
            pcall(T.RetentionSweep)
        end
        Wait(60000)
    end
end)
