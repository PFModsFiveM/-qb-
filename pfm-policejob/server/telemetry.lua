-- Officer telemetry ("bodycam" / "dashcam"), batch 18 unit 18C.
--
-- FiveM has no server-side video, so this is not a recording of pictures. It is a timeline of what
-- the server itself knows about a recording officer: positions, the weapon in hand (when the server
-- can read it), vehicle entry/exit, radio channel (pma-voice state bag), and server-seen actions that
-- other modules mark (cuff, frisk, search, taser, shots seen by weaponDamageEvent...). Rows a client
-- reported (casings, drone positions) carry client_reported = 1.
--
-- Recording: body = the officer used the `bodycam` item and still carries it; dash = the officer
-- sits in a police rig (a fleet model). Only on-duty LEO record. Samples are taken every
-- SampleSeconds and written in batches every FlushSeconds; the in-memory buffer is bounded.
--
-- Exports (architecture 4.10):
--   MarkTimeline(who, kind, data, opts) -> { ok, recorded, device }       who = server id or citizenid
--   GetTimeline(cid, from, to, opts)    -> { ok, events, next, note }     opts = { viewer, courtOrderId, after, limit }
--   HoldTimeline(cid, from, to, caseRef, opts) -> { ok, holdId, duplicate } keeps a window past retention
-- Tables (created by server/schema.lua, unit 18B): pf_police_telemetry, pf_police_telemetry_holds.

PFTelemetry = PFTelemetry or {}
local T = PFTelemetry

T.recording = T.recording or {} -- [src] = { cid, body, device, last = {...}, lastPosAt, lastPos }
T.buffer = T.buffer or {}       -- rows waiting for the batched insert
T.dropped = T.dropped or 0      -- rows dropped because the buffer was full

-- Kinds the timeline accepts (the DDL lists the core set; field actions of 18A are added).
T.Kinds = {
    pos = true, weapon_out = true, weapon_in = true, shot_hit = true, shot_reported = true, cuff = true,
    search = true, frisk = true, taser = true, vehicle_in = true, vehicle_out = true, radio = true,
    note = true, anomaly = true, detain = true, escort = true, arrest = true, ziptie = true, release = true,
    use_of_force = true, k9 = true, drone = true,
}


local function cfg() return (Config.Equipment or {}).Telemetry or {} end
local function num(v, default) return tonumber(v) or default end
local function now() return os.time() end

local function getPlayer(src) return exports['pfm-core']:GetPlayer(src) end

local function isOnDutyLeo(P)
    return P ~= nil and P.PlayerData.job ~= nil and P.PlayerData.job.type == 'leo' and P.PlayerData.job.onduty == true
end

local function u32(h)
    h = tonumber(h)
    if not h then return nil end
    return math.floor(h) % 4294967296
end

local function hashOf(v)
    if type(v) == 'number' then return u32(v) end
    if type(v) == 'string' and v ~= '' then return u32(GetHashKey(v)) end
    return nil
end

local function notify(src, key, kind)
    local text = ((Config.Equipment or {}).Text or {})[key] or key
    TriggerClientEvent('QBCore:Notify', src, text, kind or 'primary')
end

local function round2(v) return math.floor((tonumber(v) or 0) * 100 + 0.5) / 100 end

-- ── query helper (copied pattern: a failed query never throws into the caller) ───────────────
local function q(kind, sql, params)
    local ok, res = pcall(MySQL[kind].await, sql, params)
    if not ok then
        print(('^1[pfm-policejob]^7 telemetry query failed: %s'):format(tostring(res)))
        return nil, false
    end
    return res, true
end
T.Query = q

local function dbReady() return PFPoliceSchema ~= nil and PFPoliceSchema.Ready() end

-- ── rate limit (token bucket per key) ─────────────────────────────────────────────────────────
local buckets = {}
local function rate(key, perSecond, burst)
    local t = GetGameTimer()
    local b = buckets[key]
    if not b then
        b = { tokens = burst, at = t }
        buckets[key] = b
    else
        b.tokens = math.min(burst, b.tokens + (t - b.at) / 1000 * perSecond)
        b.at = t
    end
    if b.tokens < 1 then return false end
    b.tokens = b.tokens - 1
    return true
end

-- ── caller allowlist (architecture 3.4) ───────────────────────────────────────────────────────
local deniedAt = {}
function T.Allowed(exportName)
    local invoker = GetInvokingResource()
    if invoker == nil or invoker == GetCurrentResourceName() then return true end
    local list = (cfg().Callers or {})[exportName]
    if list == '*' or (type(list) == 'table' and list[invoker]) then return true end
    local key = invoker .. ':' .. exportName
    if not deniedAt[key] or now() - deniedAt[key] >= 60 then
        deniedAt[key] = now()
        print(('^3[pfm-policejob]^7 %s is not allowed to call %s'):format(invoker, exportName))
    end
    return false
end

local function err(code, message) return { ok = false, error = code, message = message or code } end

-- ── data column: short scalar values only, never more than DataMaxChars ───────────────────────
local function cleanData(data)
    if data == nil then return nil end
    if type(data) ~= 'table' then data = { value = data } end
    local out, keys = {}, {}
    for k, v in pairs(data) do
        if type(k) == 'string' and #k <= 24 then keys[#keys + 1] = k end
    end
    table.sort(keys)
    local n = 0
    for _, k in ipairs(keys) do
        local v = data[k]
        local tv = type(v)
        if tv == 'string' then
            v = v:gsub('%c', ' '):sub(1, 64)
        elseif tv == 'number' then
            if v ~= v or v == math.huge or v == -math.huge then v = nil end
        elseif tv ~= 'boolean' then
            v = nil
        end
        if v ~= nil then
            out[k] = v
            n = n + 1
            if n >= 12 then break end
        end
    end
    if n == 0 then return nil end
    local max = num(cfg().DataMaxChars, 500)
    local s = json.encode(out)
    -- drop keys (last first) until it fits; a cut JSON string would be unreadable
    while #s > max and n > 0 do
        out[keys[n]] = nil
        n = n - 1
        s = n > 0 and json.encode(out) or nil
        if not s then return nil end
    end
    return s
end
T.CleanData = cleanData

-- ── buffer ────────────────────────────────────────────────────────────────────────────────────
--- Queues one row. When the buffer is full the oldest position sample (or else the oldest row) goes.
local function evictOne()
    local victim = 1
    for i, r in ipairs(T.buffer) do
        if r.kind == 'pos' then victim = i break end
    end
    table.remove(T.buffer, victim)
    T.dropped = T.dropped + 1
end

function T.Push(row)
    local max = num(cfg().MaxBuffer, 5000)
    while #T.buffer >= max and #T.buffer > 0 do evictOne() end
    T.buffer[#T.buffer + 1] = row
end

local function rowFor(cid, device, kind, pos, data, clientReported)
    return {
        cid = cid, device = device, kind = kind,
        x = pos and round2(pos.x) or nil, y = pos and round2(pos.y) or nil, z = pos and round2(pos.z) or nil,
        data = cleanData(data), clientReported = clientReported and 1 or 0, at = now(),
    }
end

-- ── rigs (dashcam) ────────────────────────────────────────────────────────────────────────────
local rigModels
local function rigs()
    if rigModels then return rigModels end
    rigModels = {}
    local function add(m)
        local h = hashOf(m)
        if h then rigModels[h] = true end
    end
    add(Config.PoliceHelicopter)
    for _, grade in pairs(Config.AuthorizedVehicles or {}) do
        if type(grade) == 'table' then for model in pairs(grade) do add(model) end end
    end
    for model in pairs(Config.WhitelistedVehicles or {}) do add(model) end
    for _, model in pairs(cfg().DashcamModels or {}) do add(model) end
    return rigModels
end
function T.ResetRigs() rigModels = nil end

--- The police rig the officer sits in (any seat), or 0.
function T.RigOf(src)
    local veh = GetVehiclePedIsIn(GetPlayerPed(src), false)
    if not veh or veh == 0 then return 0 end
    if rigs()[u32(GetEntityModel(veh))] then return veh end
    return 0
end

local function hasBodycam(src)
    local item = cfg().BodycamItem or 'bodycam'
    local ok, has = pcall(function() return exports['pfm-inventory']:HasItem(src, item, 1) end)
    return ok and has == true
end

local function deviceOf(rec)
    if not rec then return nil end
    if rec.body then return 'body' end
    if rec.dash then return 'dash' end
    return nil
end

--- The device recording this officer right now ('body', 'dash') or nil.
function T.DeviceOf(src)
    return deviceOf(T.recording[tonumber(src)])
end

local function recFor(src, P)
    local rec = T.recording[src]
    if not rec then
        rec = { cid = P.PlayerData.citizenid, body = false, dash = false, last = {} }
        T.recording[src] = rec
    end
    rec.cid = P.PlayerData.citizenid
    return rec
end

local function tellState(src, rec, before)
    local after = deviceOf(rec)
    if after == before then return end
    TriggerClientEvent('police:client:TelemetryState', src, after)
    local pos = GetEntityCoords(GetPlayerPed(src))
    if after then
        T.Push(rowFor(rec.cid, after, 'note', pos, { event = 'recording_started' }))
        rec.last = {}
        rec.lastPosAt, rec.lastPos = nil, nil
    elseif before then
        T.Push(rowFor(rec.cid, before, 'note', pos, { event = 'recording_stopped' }))
    end
end

--- Turns body recording on or off for an on-duty officer who carries the camera.
--- @return boolean ok, string|nil reason
function T.SetBodycam(src, on)
    src = tonumber(src)
    local P = src and getPlayer(src)
    if not isOnDutyLeo(P) then return false, 'on_duty_police_only' end
    if on and not hasBodycam(src) then return false, 'no_item' end
    local rec = recFor(src, P)
    local before = deviceOf(rec)
    rec.body = on and true or false
    tellState(src, rec, before)
    return true
end

--- Stops everything for a player (duty off, drop, job change).
function T.Stop(src, reason)
    src = tonumber(src)
    local rec = src and T.recording[src]
    if not rec then return end
    local before = deviceOf(rec)
    if before then
        T.Push(rowFor(rec.cid, before, 'note', GetEntityCoords(GetPlayerPed(src)), { event = 'recording_stopped', reason = reason }))
    end
    T.recording[src] = nil
end

-- ── marks ─────────────────────────────────────────────────────────────────────────────────────
local function resolve(who)
    if type(who) == 'number' or (type(who) == 'string' and who:match('^%d+$') and #who <= 6) then
        local src = tonumber(who)
        local P = src and getPlayer(src)
        if P then return src, P.PlayerData.citizenid end
        return nil, nil
    end
    if type(who) == 'string' and #who >= 1 and #who <= 64 and who:match('^[%w_%-]+$') then
        local ok, P = pcall(function() return exports['pfm-core']:GetPlayerByCitizenId(who) end)
        if ok and P then return P.PlayerData.source, who end
        return nil, who
    end
    return nil, nil
end

--- Adds a server-known action to an officer's timeline. It is written only while that officer is
--- recording; 'anomaly' rows (server plausibility log) are always written.
--- opts.clientReported marks a row that rests on a client report.
function T.Mark(who, kind, data, opts)
    if cfg().Enabled == false then return { ok = true, recorded = false } end
    if type(kind) ~= 'string' or not T.Kinds[kind] then return err('bad_args', 'unknown kind') end
    local src, cid = resolve(who)
    if not cid then return err('bad_args', 'unknown officer') end
    local mr = cfg().MarkRate or {}
    if not rate('mark:' .. cid, num(mr.PerSecond, 5), num(mr.Burst, 20)) then return err('rate_limited') end
    local rec = src and T.recording[src]
    local device = deviceOf(rec)
    if not device then
        if kind ~= 'anomaly' then return { ok = true, recorded = false } end
        device = 'srv'
    end
    local pos = src and GetEntityCoords(GetPlayerPed(src)) or nil
    T.Push(rowFor(cid, device, kind, pos, data, type(opts) == 'table' and opts.clientReported))
    return { ok = true, recorded = true, device = device }
end

-- ── sampling (every SampleSeconds) ────────────────────────────────────────────────────────────
local sharedWeapons
local function weaponName(hash)
    sharedWeapons = sharedWeapons or exports['pfm-core']:GetShared('Weapons') or {}
    local def = sharedWeapons[hash]
    if not def then
        local h = u32(hash)
        for k, v in pairs(sharedWeapons) do
            if u32(k) == h then def = v break end
        end
    end
    return def and def.name or nil
end
T.WeaponName = weaponName

local UNARMED = u32(0xA2719263) -- WEAPON_UNARMED (normalised like every hash compared here)
local function armed(h) return h ~= nil and h ~= 0 and h ~= UNARMED end

--- One sample of a recording officer: position (when moved or after PosEverySeconds), weapon
--- drawn/holstered, vehicle in/out and radio channel changes.
function T.Sample(src, rec, t)
    local device = deviceOf(rec)
    if not device then return end
    local ped = GetPlayerPed(src)
    local pos = GetEntityCoords(ped)
    local c = cfg()
    local moved = not rec.lastPos or #(pos - rec.lastPos) >= num(c.MinMoveMeters, 2.0)
    if moved or not rec.lastPosAt or t - rec.lastPosAt >= num(c.PosEverySeconds, 30) then
        T.Push(rowFor(rec.cid, device, 'pos', pos, nil))
        rec.lastPos, rec.lastPosAt = pos, t
    end
    local last = rec.last
    local w = u32(GetSelectedPedWeapon(ped)) or 0
    if last.weapon ~= nil and w ~= last.weapon then
        if armed(w) then
            T.Push(rowFor(rec.cid, device, 'weapon_out', pos, { weapon = weaponName(w) or tostring(w) }))
        elseif armed(last.weapon) then
            T.Push(rowFor(rec.cid, device, 'weapon_in', pos, { weapon = weaponName(last.weapon) or tostring(last.weapon) }))
        end
    end
    last.weapon = w
    local veh = GetVehiclePedIsIn(ped, false) or 0
    if last.veh ~= nil and veh ~= last.veh then
        if veh ~= 0 then
            T.Push(rowFor(rec.cid, device, 'vehicle_in', pos, { plate = GetVehicleNumberPlateText(veh) }))
        else
            T.Push(rowFor(rec.cid, device, 'vehicle_out', pos, { plate = last.plate }))
        end
    end
    last.veh = veh
    last.plate = veh ~= 0 and GetVehicleNumberPlateText(veh) or nil
    local state = Player(src).state
    local radio = state and tonumber(state.radioChannel) or 0
    if last.radio ~= nil and radio ~= last.radio then
        T.Push(rowFor(rec.cid, device, 'radio', pos, { channel = radio }))
    end
    last.radio = radio
end

--- The sampler: finds who records (body camera still carried, sitting in a rig) and samples them.
function T.Tick()
    if cfg().Enabled == false then return end
    local t = now()
    local seen = {}
    for _, P in pairs(QBCore.Functions.GetQBPlayers()) do
        local src = P and P.PlayerData and P.PlayerData.source
        if src and isOnDutyLeo(P) then
            seen[src] = true
            local rec = T.recording[src]
            local inRig = T.RigOf(src) ~= 0
            if rec or inRig then
                rec = recFor(src, P)
                local before = deviceOf(rec)
                if rec.body and not hasBodycam(src) then
                    rec.body = false
                    notify(src, 'bodycam_lost', 'error')
                end
                rec.dash = inRig
                tellState(src, rec, before)
                T.Sample(src, rec, t)
                if not deviceOf(rec) then T.recording[src] = nil end
            end
        end
    end
    for src in pairs(T.recording) do
        if not seen[src] then T.Stop(src, 'off_duty') end
    end
end

-- ── batched insert ────────────────────────────────────────────────────────────────────────────
local INSERT_HEAD = 'INSERT INTO pf_police_telemetry (citizenid, device, kind, x, y, z, data, client_reported, at) VALUES '

--- Writes the buffer (InsertBatch rows per statement). Rows stay queued when the database is not
--- ready or a statement fails. Returns how many rows were written.
function T.Flush()
    if #T.buffer == 0 or not dbReady() then return 0 end
    local written, per = 0, math.max(1, math.floor(num(cfg().InsertBatch, 200)))
    while #T.buffer > 0 do
        -- the batch leaves the buffer before the insert waits: a second flush (the GetTimeline
        -- flush next to the 30 s thread) or an eviction during the wait can then never write a row
        -- twice or drop one that was not written
        local n = math.min(per, #T.buffer)
        local batch = {}
        for i = 1, n do batch[i] = T.buffer[i] end
        local rest = {}
        for i = n + 1, #T.buffer do rest[#rest + 1] = T.buffer[i] end
        T.buffer = rest
        local values, params = {}, {}
        for i = 1, n do
            local r = batch[i]
            -- a missing value is written as a literal NULL so the parameter list never has holes
            local cols = {}
            local p = { r.cid, r.device, r.kind, r.x, r.y, r.z, r.data, r.clientReported or 0, r.at }
            for j = 1, 9 do
                if p[j] == nil then
                    cols[j] = 'NULL'
                else
                    cols[j] = '?'
                    params[#params + 1] = p[j]
                end
            end
            values[i] = '(' .. table.concat(cols, ', ') .. ')'
        end
        local _, ok = q('query', INSERT_HEAD .. table.concat(values, ', '), params)
        if not ok then
            -- back at the front (oldest first) for the next flush, still within MaxBuffer
            local back = {}
            for i = 1, n do back[i] = batch[i] end
            for _, r in ipairs(T.buffer) do back[#back + 1] = r end
            T.buffer = back
            local max = num(cfg().MaxBuffer, 5000)
            while #T.buffer > max do evictOne() end
            break
        end
        written = written + n
    end
    return written
end

--- Deletes rows past RetentionDays that no hold covers (SweepBatch rows per call).
function T.Sweep(t)
    if not dbReady() then return 0 end
    local c = cfg()
    local cutoff = (t or now()) - num(c.RetentionDays, 30) * 86400
    local res = q('query', [[DELETE FROM pf_police_telemetry WHERE at < ? AND NOT EXISTS (
        SELECT 1 FROM pf_police_telemetry_holds h WHERE h.citizenid = pf_police_telemetry.citizenid
        AND pf_police_telemetry.at BETWEEN h.from_at AND h.to_at) LIMIT ]] .. math.floor(num(c.SweepBatch, 500)), { cutoff })
    if type(res) == 'table' then return tonumber(res.affectedRows) or 0 end
    return tonumber(res) or 0
end

-- ── reading ───────────────────────────────────────────────────────────────────────────────────
local function int(v, min, max)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge then return nil end
    v = math.floor(v)
    if (min and v < min) or (max and v > max) then return nil end
    return v
end

local function validCid(cid) return type(cid) == 'string' and #cid >= 1 and #cid <= 64 and cid:match('^[%w_%-]+$') ~= nil end

local function courtOrderValid(ref, cid)
    if type(ref) ~= 'string' or #ref < 1 or #ref > 64 then return false end
    if GetResourceState('pf-justice') ~= 'started' then return false end
    -- fails closed until pf-justice provides IsCourtOrderValid (batch 19A)
    local ok, valid = pcall(function() return exports['pf-justice']:IsCourtOrderValid(ref, 'telemetry', cid) end)
    return ok and valid == true
end

--- Who may read: the own resource without a viewer (system read), an on-duty officer reading their
--- own timeline, an on-duty LEO supervisor (grade >= SupervisorGrade), or a court with a valid order.
local function mayRead(cid, opts)
    if opts.courtOrderId ~= nil then
        if courtOrderValid(opts.courtOrderId, cid) then return true end
        return false, 'no_permission'
    end
    if opts.viewer == nil then
        local invoker = GetInvokingResource()
        if invoker == nil or invoker == GetCurrentResourceName() then return true end
        return false, 'no_permission'
    end
    local viewer = int(opts.viewer, 1)
    local P = viewer and getPlayer(viewer)
    if not P then return false, 'offline' end
    if not isOnDutyLeo(P) then return false, 'no_permission' end
    if P.PlayerData.citizenid == cid then return true end
    local grade = tonumber(P.PlayerData.job.grade and P.PlayerData.job.grade.level) or 0
    if grade >= num(cfg().SupervisorGrade, 2) then return true end
    return false, 'no_permission'
end

local function rowOut(r)
    return {
        id = tonumber(r.id), device = r.device, kind = r.kind,
        coords = r.x and { x = tonumber(r.x), y = tonumber(r.y), z = tonumber(r.z) } or nil,
        data = r.data and json.decode(r.data) or nil,
        clientReported = tonumber(r.client_reported) == 1 or r.client_reported == true,
        at = tonumber(r.at),
    }
end

--- An officer's timeline between two unix times. Pages of at most PageLimit rows (opts.after = the
--- `next` of the page before).
function T.GetTimeline(cid, from, to, opts)
    if not T.Allowed('GetTimeline') then return err('not_allowed') end
    opts = type(opts) == 'table' and opts or {}
    if not validCid(cid) then return err('bad_args', 'citizenid') end
    from, to = int(from, 0), int(to, 0)
    if not from or not to or to < from then return err('bad_args', 'window') end
    if to - from > num(cfg().MaxWindowSeconds, 21600) then return err('bad_args', 'window too long') end
    local okRead, why = mayRead(cid, opts)
    if not okRead then return err(why) end
    local limit = int(opts.limit, 1, num(cfg().PageLimit, 100)) or num(cfg().PageLimit, 100)
    local after = int(opts.after, 0) or 0
    if not dbReady() then return err('db_unavailable') end
    T.Flush()
    local rows, ok = q('query', [[SELECT id, device, kind, x, y, z, data, client_reported, at FROM pf_police_telemetry
        WHERE citizenid = ? AND at BETWEEN ? AND ? AND id > ? ORDER BY id LIMIT ?]], { cid, from, to, after, limit + 1 })
    if not ok then return err('db_unavailable') end
    local events, nextCursor = {}, nil
    for i, r in ipairs(type(rows) == 'table' and rows or {}) do
        if i > limit then
            nextCursor = events[#events].id
            break
        end
        events[#events + 1] = rowOut(r)
    end
    return {
        ok = true, events = events, next = nextCursor,
        note = 'Server metadata timeline. No video exists; rows marked clientReported rest on a client report.',
    }
end

--- Keeps a window of an officer's timeline past retention (a case attached it).
function T.Hold(cid, from, to, caseRef, opts)
    if not T.Allowed('HoldTimeline') then return err('not_allowed') end
    if not validCid(cid) then return err('bad_args', 'citizenid') end
    from, to = int(from, 0), int(to, 0)
    if not from or not to or to < from then return err('bad_args', 'window') end
    if type(caseRef) ~= 'string' or #caseRef < 1 or #caseRef > 64 or not caseRef:match('^[%w_%-:%.]+$') then
        return err('bad_args', 'caseRef')
    end
    if not dbReady() then return err('db_unavailable') end
    local existing = q('scalar', [[SELECT id FROM pf_police_telemetry_holds WHERE citizenid = ? AND from_at = ? AND to_at = ?
        AND case_ref = ? LIMIT 1]], { cid, from, to, caseRef })
    if tonumber(existing) then return { ok = true, holdId = tonumber(existing), duplicate = true } end
    local id, ok = q('insert', 'INSERT INTO pf_police_telemetry_holds (citizenid, from_at, to_at, case_ref, at) VALUES (?, ?, ?, ?, ?)',
        { cid, from, to, caseRef, now() })
    if not ok then return err('db_unavailable') end
    return { ok = true, holdId = tonumber(id) }
end

-- ── exports ───────────────────────────────────────────────────────────────────────────────────
exports('MarkTimeline', function(who, kind, data, opts)
    if not T.Allowed('MarkTimeline') then return err('not_allowed') end
    return T.Mark(who, kind, data, opts)
end)
exports('GetTimeline', function(cid, from, to, opts) return T.GetTimeline(cid, from, to, opts) end)
exports('HoldTimeline', function(cid, from, to, caseRef, opts) return T.Hold(cid, from, to, caseRef, opts) end)

-- ── items ─────────────────────────────────────────────────────────────────────────────────────
-- The equipment items of this unit, registered with pfm-core when the shared list lacks them.
T.Items = {
    bodycam = { name = 'bodycam', label = 'Body Camera', weight = 300, type = 'item', image = 'newscam.png', unique = false, useable = true, shouldClose = true, description = 'Records a metadata timeline while worn (no video)' },
    riot_shield = { name = 'riot_shield', label = 'Riot Shield', weight = 6000, type = 'item', image = 'armor.png', unique = false, useable = true, shouldClose = true, description = 'Ballistic shield' },
    police_drone = { name = 'police_drone', label = 'Police Drone', weight = 2000, type = 'item', image = 'radioscanner.png', unique = false, useable = true, shouldClose = true, description = 'Camera drone with a limited range' },
}
function T.RegisterItems()
    local Items = exports['pfm-core']:GetShared('Items') or {}
    for name, def in pairs(T.Items) do
        if not Items[name] then pcall(function() exports['pfm-core']:AddItem(name, def) end) end
    end
end
T.RegisterItems()

QBCore.Functions.CreateUseableItem(cfg().BodycamItem or 'bodycam', function(source)
    local src = source
    local on = not (T.recording[src] and T.recording[src].body)
    local ok, why = T.SetBodycam(src, on)
    if not ok then return notify(src, why, 'error') end
    notify(src, on and 'bodycam_on' or 'bodycam_off', on and 'success' or 'primary')
end)

-- ── lifecycle ─────────────────────────────────────────────────────────────────────────────────
AddEventHandler('QBCore:Server:SetDuty', function(src, onDuty)
    if not onDuty then T.Stop(src, 'off_duty') end
end)

AddEventHandler('QBCore:Server:OnJobUpdate', function(src, job)
    if type(job) ~= 'table' or job.type ~= 'leo' or not job.onduty then T.Stop(src, 'job_change') end
end)

-- The medical engine says someone went down: a recording officer who went down, or whose subject
-- went down, gets a note.
AddEventHandler('pf-ambulancejob:server:patientDown', function(src, cid, state, cause)
    src = tonumber(src)
    if src and T.recording[src] then T.Mark(src, 'note', { event = 'officer_down', state = tostring(state) }) end
    local attacker = type(cause) == 'table' and cause.attackerCid or nil
    if type(attacker) == 'string' and attacker ~= cid then
        T.Mark(attacker, 'note', { event = 'subject_down', subject = type(cid) == 'string' and cid or nil, state = tostring(state) })
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    T.Stop(src, 'dropped')
end)

AddEventHandler('onResourceStop', function(name)
    if name == GetCurrentResourceName() then T.Flush() end
end)

CreateThread(function()
    while true do
        Wait(math.floor(num(cfg().SampleSeconds, 5) * 1000))
        local ok, e = pcall(T.Tick)
        if not ok then print('^1[pfm-policejob]^7 telemetry sampler failed: ' .. tostring(e)) end
    end
end)

CreateThread(function()
    while true do
        Wait(math.floor(num(cfg().FlushSeconds, 30) * 1000))
        T.Flush()
    end
end)

CreateThread(function()
    while true do
        Wait(3600 * 1000)
        T.Sweep()
    end
end)
