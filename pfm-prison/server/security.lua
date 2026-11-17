-- pfm-prison security (batch 19F; PF_ARCHITECTURE 4.8, PF_ULTIMATE_SYSTEM_PLAN 19F).
--
-- What it does, all decided on the server (job, duty, grade and positions are read here, never sent):
--   * doors: the security doors (Config.Security.Doors) are set through pfm-doorlock SetDoorState,
--     which needs no online player; a lockdown locks every one of them and no gate can be hacked;
--   * lockdowns: the lockdown state, its grade rule and its persistence are the facility's (19D
--     server/facility.lua, export SetLockdown); Sec.SetLockdown goes through it and then relocks every
--     hacked gate and security door; main.lua refuses gate hacks while either lockdown is on;
--   * cameras: fixed camera points shown to on-duty staff at a control point (and to the Corrections
--     MDT through ViewCamera); every view is audited (pf_prison_events 'camera');
--   * alarms and zones: alarms (escape, zone breach, failed gate hack, manual/riot, lockdown) go to the
--     staff on duty; inmates seen in a restricted zone raise a zone alarm (main.lua's sampler);
--   * searches (pf_prison_searches): pat searches of inmates, visitor searches at the visitor entry
--     and cell-locker searches. Detection is rolled on the server per contraband stack
--     (Chance[kind] x Concealment). What is found on a person is seized into a pf-justice property
--     locker (SeizeProperty, key pfm-prison:contraband:<searchId>:seize) and forfeited to evidence
--     (ForfeitPropertyItems -> pfm-policejob CreateEvidence); what is found in a cell locker becomes
--     evidence directly (CreateEvidence, key pfm-prison:contraband:<searchId>:<n>). Nothing is ever
--     removed without a receipt or an evidence record: a missing export fails closed (the item stays
--     where it was), and a seizure whose evidence could not be made stays in the locker and is retried;
--   * escapes (pf_prison_escapes): the order is suspended by justice_bridge.lua (unchanged, D12: the
--     property stays in the locker); here the escape is recorded, the inmate's classification raised,
--     the staff alerted and an arrest warrant requested from the police MDT (fails closed and is
--     retried while the export is missing). A recapture (justice_bridge Admit 'readmit') closes the
--     escape row and takes the work credits back (AdjustOrder forfeit, key
--     pfm-prison:escape:<orderId>:<escapedAt>:forfeit; pf-justice caps it at the credits earned).

PFPrison = PFPrison or {}
PFPrison.Security = PFPrison.Security or {}
local Sec = PFPrison.Security
local I = PFPrison.Internal
local B = PFPrison.Bridge
local SC = Config.Security or {}
local FAC = SC.Facility or (Config.Justice and Config.Justice.Facility) or 'bolingbroke'
local SEARCH = SC.Search or {}
local ESC = SC.Escape or {}

Sec.alarms = Sec.alarms or {}          -- open alarms, oldest first
Sec.alarmSeq = Sec.alarmSeq or 0
Sec.escapes = Sec.escapes or {}        -- [cid] = { id, orderId, escapedAt, warrantId, attempts, nextAt, gate, method }
Sec.forfeits = Sec.forfeits or {}      -- [key] = { cid, orderId, seconds, attempts }
Sec.pending = Sec.pending or {}        -- [searchId] = { receiptId, items, attempts, nextAt, cid }
Sec.busy = Sec.busy or {}              -- [target] = true while a search of it runs
Sec.lastSearch = Sec.lastSearch or {}  -- [target] = os.time()
Sec.lastOfficer = Sec.lastOfficer or {} -- [cid] = os.time()
Sec.zoneSeen = Sec.zoneSeen or {}      -- [src .. ':' .. zone] = os.time()
Sec.cameraSeen = Sec.cameraSeen or {}  -- [cid .. ':' .. camera] = os.time()
Sec.warned = Sec.warned or {}          -- one console line per missing interface

local SYSTEM = { kind = 'system', label = 'pfm-prison security' }

local function num(v, d) return tonumber(v) or d end
local function now() return os.time() end
local function validCid(cid) return type(cid) == 'string' and #cid >= 1 and #cid <= 64 and cid:match('^[%w_%-]+$') ~= nil end
local function err(code, message) return { ok = false, error = code, message = message } end
local function dist(a, b)
    if not a or not b then return math.huge end
    local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function warnOnce(what, msg)
    if Sec.warned[what] then return end
    Sec.warned[what] = true
    print(('^3[pfm-prison]^7 %s'):format(msg))
end

-- ── storage ─────────────────────────────────────────────────────────────────────────────────────

Sec.SQL = {
    event = 'INSERT INTO pf_prison_events (citizenid, facility, kind, detail, actor_cid, at) VALUES (?, ?, ?, ?, ?, ?)',
    searchInsert = 'INSERT INTO pf_prison_searches (facility, kind, target, by_cid, found, evidence_ids, at) VALUES (?, ?, ?, ?, NULL, NULL, ?)',
    searchUpdate = 'UPDATE pf_prison_searches SET found = ?, evidence_ids = ? WHERE id = ?',
    searchPending = [[SELECT id, target, found FROM pf_prison_searches WHERE facility = ? AND at >= ? AND found LIKE '%"forfeit_pending"%'
        ORDER BY id LIMIT 100]],
    escapeInsert = 'INSERT INTO pf_prison_escapes (citizenid, order_id, method, gate, warrant_id, escaped_at, recaptured_at) VALUES (?, ?, ?, ?, NULL, ?, NULL)',
    escapeWarrant = 'UPDATE pf_prison_escapes SET warrant_id = ? WHERE id = ? AND warrant_id IS NULL',
    escapeRecaptured = 'UPDATE pf_prison_escapes SET recaptured_at = ? WHERE id = ? AND recaptured_at IS NULL',
    escapeRecapturedByOrder = 'UPDATE pf_prison_escapes SET recaptured_at = ? WHERE citizenid = ? AND order_id = ? AND recaptured_at IS NULL',
    escapesOpen = [[SELECT id, citizenid, order_id, method, gate, warrant_id, escaped_at FROM pf_prison_escapes
        WHERE recaptured_at IS NULL AND escaped_at >= ? ORDER BY id]],
    visitSearched = [[UPDATE pf_prison_visits SET searched = 1 WHERE visitor_cid = ? AND state IN ('booked', 'checked_in')
        AND slot_at BETWEEN ? AND ?]],
    anonSearches = 'UPDATE pf_prison_searches SET by_cid = ? WHERE by_cid = ?',
    deleteSearchesOf = 'DELETE FROM pf_prison_searches WHERE target = ?',
    deleteEscapesOf = 'DELETE FROM pf_prison_escapes WHERE citizenid = ?',
}

local function dbReady() return PFPrisonSchema ~= nil and PFPrisonSchema.Ready() end

local function db(kind, sql, params)
    if not dbReady() then return nil, false end
    local ok, res = pcall(MySQL[kind].await, sql, params or {})
    if not ok then
        print(('^1[pfm-prison]^7 database error: %s'):format(tostring(res)))
        return nil, false
    end
    return res, true
end
Sec.DB = db

local function encode(v)
    local ok, s = pcall(json.encode, v)
    return ok and s or nil
end

local function decode(s)
    if type(s) ~= 'string' or s == '' then return nil end
    local ok, v = pcall(json.decode, s)
    return ok and v or nil
end

local EVENT_KINDS = { search = true, escape = true, recapture = true, anomaly = true, lockdown = true, alarm = true, door = true, camera = true }

--- One pf_prison_events row of this module (detail clipped to 4 KB).
function Sec.Event(cid, kind, detail, actorCid)
    if not EVENT_KINDS[kind] then return false end
    local s = detail ~= nil and encode(detail) or nil
    if s and #s > 4096 then s = encode({ truncated = true }) end
    local _, ok = db('insert', Sec.SQL.event, { validCid(cid) and cid or nil, FAC, kind, s, validCid(actorCid) and actorCid or nil, now() })
    return ok
end

-- ── who is acting ───────────────────────────────────────────────────────────────────────────────

local function playerOf(src)
    src = math.tointeger(tonumber(src))
    if not src or src < 1 then return nil end
    return I.getPlayer(src), src
end

--- The on-duty security staff member behind src: { src, cid, job, grade, control } or nil, error.
function Sec.Staff(src)
    local P, s = playerOf(src)
    if not P then return nil, err('offline', 'Not online') end
    local job = P.PlayerData.job or {}
    local min = (SC.StaffJobs or { corrections = 0, police = 0 })[job.name]
    if min == nil then return nil, err('no_permission', 'Prison security staff only') end
    if job.onduty ~= true then return nil, err('not_on_duty', 'You are off duty') end
    local grade = type(job.grade) == 'table' and num(job.grade.level, 0) or num(job.grade, 0)
    if grade < num(min, 0) then return nil, err('no_permission', 'Your grade may not do that') end
    local cg = (SC.ControlGrade or {})[job.name]
    return { kind = 'player', src = s, cid = P.PlayerData.citizenid, job = job.name, grade = grade,
        control = cg ~= nil and grade >= num(cg, 99) }
end

local function atPoint(src, points)
    local pos = I.pedPos(src)
    if not pos then return nil end
    for _, p in ipairs(points or {}) do
        if p.coords and dist(pos, p.coords) <= num(p.radius, 5.0) then return p end
    end
    return nil
end

function Sec.AtControlPoint(src) return atPoint(src, SC.ControlPoints) ~= nil end

--- The actor of an export or internal call: { src } is re-read here; system and admin pass.
--- needControl: the action needs ControlGrade at a control point.
local function resolveActor(actor, needControl)
    if type(actor) ~= 'table' then return nil, err('bad_args', 'opts.actor is required') end
    if actor.kind == 'system' then return { kind = 'system', label = tostring(actor.label or 'system'):sub(1, 32) } end
    if actor.kind == 'admin' then
        local s = math.tointeger(tonumber(actor.src))
        if not s or not IsPlayerAceAllowed(s, 'admin') then return nil, err('no_permission', 'An admin actor is required') end
        local P = I.getPlayer(s)
        return { kind = 'admin', src = s, cid = P and P.PlayerData.citizenid or nil }
    end
    local staff, e = Sec.Staff(actor.src)
    if not staff then return nil, e end
    if needControl then
        if not staff.control then return nil, err('no_permission', 'Your grade may not do that') end
        if not Sec.AtControlPoint(staff.src) then return nil, err('too_far', 'Use the controls at the gatehouse') end
    end
    return staff
end
Sec.ResolveActor = resolveActor

local function staffList(jobs)
    local out = {}
    for _, src in ipairs(I.players()) do
        local P = I.getPlayer(src)
        local job = P and P.PlayerData.job
        if job and job.onduty == true and jobs[job.name] then out[#out + 1] = tonumber(src) end
    end
    return out
end

-- ── alarms ──────────────────────────────────────────────────────────────────────────────────────

local ALARM_KINDS = { escape = 'Escape', zone = 'Restricted zone', gate = 'Gate tampering', manual = 'Manual alarm', riot = 'Disturbance',
    lockdown = 'Lockdown', contraband = 'Contraband' }

--- Raises an alarm: kept in the open list, written to the audit trail and sent to the staff on
--- duty (escapes and riots also to the police). spec = { label, coords, cid, by }.
function Sec.RaiseAlarm(kind, spec)
    if not ALARM_KINDS[kind] then return err('bad_args', 'Unknown alarm kind') end
    spec = type(spec) == 'table' and spec or {}
    Sec.alarmSeq = Sec.alarmSeq + 1
    local c = spec.coords
    local alarm = { id = Sec.alarmSeq, kind = kind, label = tostring(spec.label or ALARM_KINDS[kind]):sub(1, 64), at = now(),
        coords = c and { x = math.floor(c.x * 10) / 10, y = math.floor(c.y * 10) / 10, z = math.floor((c.z or 0) * 10) / 10 } or nil,
        cid = validCid(spec.cid) and spec.cid or nil }
    Sec.alarms[#Sec.alarms + 1] = alarm
    while #Sec.alarms > num(SC.MaxAlarms, 50) do table.remove(Sec.alarms, 1) end
    Sec.Event(alarm.cid, 'alarm', { id = alarm.id, kind = kind, label = alarm.label, coords = alarm.coords }, spec.by)
    local jobs = { corrections = true }
    if kind == 'escape' or kind == 'riot' then jobs.police = true end
    for _, s in ipairs(staffList(jobs)) do
        TriggerClientEvent('prison:client:SecurityAlert', s, { id = alarm.id, kind = kind, label = alarm.label, coords = alarm.coords })
    end
    return { ok = true, alarmId = alarm.id }
end

--- Clears an open alarm (staff). Returns { ok } or an error.
function Sec.ClearAlarm(alarmId, opts)
    local actor, e = resolveActor(type(opts) == 'table' and opts.actor or nil, false)
    if not actor then return e end
    alarmId = math.tointeger(tonumber(alarmId))
    for i, a in ipairs(Sec.alarms) do
        if a.id == alarmId then
            table.remove(Sec.alarms, i)
            Sec.Event(a.cid, 'alarm', { id = a.id, cleared = true }, actor.cid)
            return { ok = true }
        end
    end
    return err('not_found', 'No such alarm')
end

-- main.lua: a failed gate hack locked the gates down
function Sec.OnGateAlarm(reason)
    Sec.RaiseAlarm('gate', { label = tostring(reason or 'Gate tampering') })
end

--- main.lua's sampler: an inmate inside the walls at `pos`. Restricted zones raise an alarm once
--- per inmate and zone per ZoneCooldown.
function Sec.SampleInmate(src, pos, at)
    if not pos then return end
    at = at or now()
    for _, z in ipairs(SC.Zones or {}) do
        if z.coords and dist(pos, z.coords) <= num(z.radius, 5.0) then
            local key = tostring(src) .. ':' .. tostring(z.id)
            if at - num(Sec.zoneSeen[key], -math.huge) >= num(SC.ZoneCooldown, 300) then
                Sec.zoneSeen[key] = at
                local P = I.getPlayer(src)
                Sec.RaiseAlarm('zone', { label = ('Inmate in %s'):format(z.label or z.id), coords = pos,
                    cid = P and P.PlayerData.citizenid or nil })
            end
        end
    end
end

-- ── doors and lockdowns ─────────────────────────────────────────────────────────────────────────

local function doorExport(id, locked, reason)
    local ok, res = pcall(function() return exports['pfm-doorlock']:SetDoorState(id, locked, { reason = reason }) end)
    return ok and type(res) == 'table' and res.ok == true, ok and res or nil
end

local function findDoor(door)
    local idx = math.tointeger(tonumber(door))
    local list = SC.Doors or {}
    if idx and list[idx] then return list[idx], idx end
    for i, d in ipairs(list) do if d.id == door then return d, i end end
    return nil
end

--- Locks or unlocks one security door. opts = { actor, reason }. No door opens during a lockdown.
function Sec.SetDoor(door, locked, opts)
    opts = type(opts) == 'table' and opts or {}
    local d = findDoor(door)
    if not d then return err('not_found', 'No such door') end
    locked = locked == true
    local actor, e = resolveActor(opts.actor, true)
    if not actor then return e end
    if not locked and I.lockdownActive and I.lockdownActive() then return err('invalid_state', 'The prison is in lockdown') end
    local ok, res = doorExport(d.id, locked, tostring(opts.reason or 'prison security'):sub(1, 64))
    if not ok then return err(type(res) == 'table' and res.error or 'unavailable', 'The door could not be set') end
    Sec.Event(nil, 'door', { door = d.id, locked = locked }, actor.cid)
    return { ok = true, door = d.id, locked = locked }
end

--- Locks every security door (a lockdown). Returns how many locked.
function Sec.LockAllDoors(reason)
    local n = 0
    for _, d in ipairs(SC.Doors or {}) do
        if doorExport(d.id, true, reason or 'prison lockdown') then n = n + 1 end
    end
    return n
end

--- Lockdowns are the facility's (batch 19D server/facility.lua: PFPrison.Facility.ApplyLockdown, its
--- grade rule, its persistence and its SetLockdown export); this is the security side of the same
--- switch: the facility's checks and state, then every hacked gate and security door locked.
--- opts = { actor = { src } | system | admin, reason, minutes }.
function Sec.SetLockdown(on, opts)
    opts = type(opts) == 'table' and opts or {}
    on = on == true
    local F = PFPrison.Facility
    if type(F) ~= 'table' or not I.isCallable(F.ApplyLockdown) then
        return err('unavailable', 'The facility module is not running; no lockdown')
    end
    local actor = opts.actor
    local res
    if type(actor) == 'table' and actor.src and actor.kind ~= 'admin' then
        local staff, e = resolveActor(actor, false)
        if not staff then return e end
        if not I.isCallable(F.StaffLockdown) then return err('unavailable', 'The facility module is not running; no lockdown') end
        res = F.StaffLockdown(staff.src, on, opts.reason, opts.minutes)
    else
        local a, e = resolveActor(actor or SYSTEM, false)
        if not a then return e end
        res = F.ApplyLockdown(on, { reason = opts.reason, minutes = opts.minutes, actorCid = a.cid })
    end
    if type(res) ~= 'table' or res.ok ~= true then return res or err('unavailable', 'No lockdown') end
    if on then
        if I.isCallable(I.relockGates) then I.relockGates() end
        res.doorsLocked = Sec.LockAllDoors(tostring(opts.reason or 'prison lockdown'):sub(1, 64))
        Sec.RaiseAlarm('lockdown', { label = 'Lockdown: ' .. tostring(opts.reason or 'ordered'):sub(1, 48) })
    end
    return res
end

-- ── cameras ─────────────────────────────────────────────────────────────────────────────────────

local function cameraOf(id)
    local list = SC.Cameras or {}
    local idx = math.tointeger(tonumber(id))
    if idx and list[idx] then return list[idx], idx end
    for i, c in ipairs(list) do if c.id == id then return c, i end end
    return nil
end

local function v3(v) return v and { x = v.x, y = v.y, z = v.z } or nil end

--- The camera points of the facility (positions only; there is no recording: FiveM cannot capture video).
function Sec.ListCameras()
    local out = {}
    for i, c in ipairs(SC.Cameras or {}) do out[#out + 1] = { index = i, id = c.id, label = c.label, coords = v3(c.coords) } end
    return { ok = true, facility = FAC, cameras = out }
end

--- Shows a camera to on-duty staff at a control point (the client points a scripted camera there).
function Sec.ViewCamera(src, cameraId)
    local staff, e = Sec.Staff(src)
    if not staff then return e end
    if not Sec.AtControlPoint(staff.src) then return err('too_far', 'The cameras are watched from the gatehouse') end
    local cam, idx = cameraOf(cameraId)
    if not cam then return err('not_found', 'No such camera') end
    local key = staff.cid .. ':' .. cam.id
    if now() - num(Sec.cameraSeen[key], -math.huge) >= num(SC.CameraAuditSeconds, 60) then
        Sec.cameraSeen[key] = now()
        Sec.Event(nil, 'camera', { camera = cam.id }, staff.cid)
    end
    TriggerClientEvent('prison:client:ViewCamera', staff.src, { index = idx, count = #(SC.Cameras or {}), id = cam.id, label = cam.label,
        coords = v3(cam.coords), lookAt = v3(cam.lookAt), fov = num(cam.fov, 60.0) })
    return { ok = true, camera = cam.id, index = idx }
end

-- ── contraband ──────────────────────────────────────────────────────────────────────────────────

local function sharedItem(name)
    local ok, items = pcall(function() return exports['pfm-core']:GetShared('Items') end)
    return ok and type(items) == 'table' and items[name] or nil
end

--- The contraband class of an item name ('weapon', 'drug', 'phone', 'tool') or nil.
function Sec.ContrabandClass(name)
    if type(name) ~= 'string' then return nil end
    local cls = (SEARCH.Items or {})[name]
    if cls then return cls end
    for prefix, c in pairs(SEARCH.Prefixes or {}) do
        if name:sub(1, #prefix) == prefix then return c end
    end
    local def = sharedItem(name)
    if type(def) == 'table' and def.type == 'weapon' then return 'weapon' end
    return nil
end

--- The chance a search of `kind` finds a stack of class `cls` (0..1).
function Sec.DetectChance(kind, cls)
    local base = num((SEARCH.Chance or {})[kind], 0.5)
    local conceal = SEARCH.Concealment or {}
    local f = num(conceal[cls], num(conceal.default, 1.0))
    return math.max(0, math.min(1, base * f))
end

--- Rolls detection for every contraband stack of `items` ({ name, amount, slot, info }).
function Sec.Roll(kind, items)
    local found = {}
    for _, it in ipairs(items or {}) do
        local cls = Sec.ContrabandClass(it.name)
        if cls and num(it.amount, 0) > 0 and math.random() < Sec.DetectChance(kind, cls) then
            found[#found + 1] = { name = it.name, amount = math.floor(num(it.amount, 1)), slot = math.tointeger(tonumber(it.slot)),
                info = type(it.info) == 'table' and it.info or nil, class = cls }
        end
    end
    return found
end

local function playerItems(src)
    local P = I.getPlayer(src)
    local out = {}
    for _, it in pairs(P and P.PlayerData.items or {}) do
        if type(it) == 'table' and type(it.name) == 'string' and num(it.amount, 0) > 0 then
            out[#out + 1] = { name = it.name, amount = it.amount, slot = it.slot, info = it.info }
        end
    end
    table.sort(out, function(a, b) return num(a.slot, 0) < num(b.slot, 0) end)
    return out
end

local function inv(fn, ...)
    local n, args = select('#', ...), { ... }
    local ok, a = pcall(function()
        local e = exports['pfm-inventory']
        return e[fn](e, table.unpack(args, 1, n))
    end)
    if not ok then return nil, false end
    return a, true
end

local function stashItems(stash)
    local data = inv('GetInventory', stash)
    local out = {}
    for _, it in pairs(type(data) == 'table' and type(data.items) == 'table' and data.items or {}) do
        if type(it) == 'table' and type(it.name) == 'string' and num(it.amount, 0) > 0 then
            out[#out + 1] = { name = it.name, amount = it.amount, slot = it.slot, info = it.info }
        end
    end
    table.sort(out, function(a, b) return num(a.slot, 0) < num(b.slot, 0) end)
    return out
end

local function ensureEvidenceStash()
    local stash = SEARCH.EvidenceStash or ('pfprison_evidence_' .. FAC)
    inv('CreateInventory', stash, { label = 'Prison evidence', maxweight = 200000, slots = 50 })
    return stash
end

local function justice(name, ...)
    if GetResourceState('pf-justice') ~= 'started' then return nil end
    local n, args = select('#', ...), { ... }
    local ok, res = pcall(function()
        local e = exports['pf-justice']
        return e[name](e, table.unpack(args, 1, n))
    end)
    if not ok then
        warnOnce('ju:' .. name, ('pf-justice %s is not available: %s'):format(name, tostring(res)))
        return nil
    end
    return res
end

local function evidenceKind(cls)
    if cls == 'weapon' then return 'weapon' end
    if cls == 'drug' then return 'drug' end
    return 'item'
end

local function evidenceAttrs(kind, it)
    if kind == 'weapon' then return { item = it.name, serial = type(it.info) == 'table' and (it.info.serie or it.info.serial) or nil } end
    return { item = it.name, amount = it.amount }
end

-- A seizure held in a pf-justice locker becomes evidence (ForfeitPropertyItems). The receipt is
-- re-read, so a retry forfeits only the rows still held. Returns evidenceIds, state, error.
local function forfeitReceipt(receiptId)
    local got = justice('GetPropertyReceipt', receiptId)
    if type(got) ~= 'table' or got.ok ~= true or type(got.receipt) ~= 'table' then
        return nil, 'forfeit_pending', type(got) == 'table' and got.error or 'justice_unavailable'
    end
    local want, done = {}, {}
    for _, row in ipairs(got.receipt.items or {}) do
        if row.state == 'held' and tonumber(row.id) then want[#want + 1] = { id = tonumber(row.id) }
        elseif row.state == 'forfeited' and tonumber(row.evidenceId) then done[#done + 1] = tonumber(row.evidenceId) end
    end
    if #want == 0 then return done, 'evidence' end
    local res = justice('ForfeitPropertyItems', receiptId, want, { actor = SYSTEM, giveTo = 'stash:' .. ensureEvidenceStash() })
    if type(res) == 'table' and res.ok == true then
        for _, id in ipairs(res.evidenceIds or {}) do done[#done + 1] = tonumber(id) end
        return done, 'evidence'
    end
    for _, id in ipairs(type(res) == 'table' and res.evidenceIds or {}) do done[#done + 1] = tonumber(id) end
    return done, 'forfeit_pending', type(res) == 'table' and res.error or 'justice_unavailable'
end

local function idsText(ids)
    local parts = {}
    for _, id in ipairs(ids or {}) do if #parts < 30 then parts[#parts + 1] = tostring(math.floor(id)) end end
    local s = table.concat(parts, ',')
    return s ~= '' and s:sub(1, 255) or nil
end

local function publicItems(found)
    local out = {}
    for _, it in ipairs(found) do out[#out + 1] = { name = it.name, amount = it.amount, class = it.class } end
    return out
end

-- Seizes what was found on a person (pf-justice locker), then forfeits it to evidence.
local function seizeFromPerson(searchId, actor, targetSrc, orderId, found)
    local list = {}
    for _, it in ipairs(found) do list[#list + 1] = { name = it.name, slot = it.slot, amount = it.amount } end
    local res = justice('SeizeProperty', targetSrc, { items = list, orderId = orderId, reason = ('contraband (prison search #%d)'):format(searchId),
        key = ('pfm-prison:contraband:%d:seize'):format(searchId), actor = { src = actor.src } })
    if type(res) ~= 'table' or res.ok ~= true or not tonumber(res.receiptId) then
        -- nothing was taken (pf-justice rolls a failed seizure back): the items stay with the person
        return { state = 'not_seized', error = type(res) == 'table' and res.error or 'justice_unavailable' }, {}
    end
    local receiptId = math.tointeger(tonumber(res.receiptId))
    local ids, state, e = forfeitReceipt(receiptId)
    return { state = state, receiptId = receiptId, error = e }, ids or {}
end

-- Cell locker contents become evidence directly (pf-justice has no locker for a cell). Each item
-- leaves the locker only together with its evidence record; a failure puts it back.
local function seizeFromCell(searchId, stash, cellId, coords, found)
    local ids, failed = {}, nil
    local giveTo = 'stash:' .. ensureEvidenceStash()
    for n, it in ipairs(found) do
        local removed = inv('RemoveItem', stash, it.name, it.amount, it.slot, 'pfm-prison:contraband')
        if removed ~= true then
            failed = failed or 'not_found'
        else
            local kind = evidenceKind(it.class)
            local ok, res = pcall(function()
                return exports['pfm-policejob']:CreateEvidence({
                    kind = kind, label = (it.name .. ' x' .. it.amount):sub(1, 64), attrs = evidenceAttrs(kind, it),
                    method = 'prison_search', sealed = true,
                    scene = { coords = coords and { x = coords.x, y = coords.y, z = coords.z } or nil, label = ('Bolingbroke cell %s'):format(cellId) },
                    origin = { type = 'prison_cell', id = tostring(cellId):sub(1, 64) },
                }, { key = ('pfm-prison:contraband:%d:%d'):format(searchId, n), giveTo = giveTo, actor = SYSTEM })
            end)
            if ok and type(res) == 'table' and res.ok == true and tonumber(res.evidenceId) then
                ids[#ids + 1] = tonumber(res.evidenceId)
            else
                inv('AddItem', stash, it.name, it.amount, it.slot, it.info, 'pfm-prison:contraband_undo')
                failed = failed or (ok and type(res) == 'table' and res.error) or 'evidence_unavailable'
            end
        end
    end
    local state = failed == nil and 'evidence' or (#ids > 0 and 'partial' or 'not_seized')
    return { state = state, error = failed }, ids
end

-- ── cells ───────────────────────────────────────────────────────────────────────────────────────

--- The locker position of a cell: Config.Security.CellLockers, else a position the facility config
--- gives the cell (config_facility.lua). nil = the cell has no locker.
function Sec.CellCoords(cellId)
    if type(cellId) ~= 'string' or cellId == '' then return nil end
    local c = (SC.CellLockers or {})[cellId]
    if c then return c end
    local fac = Config.Facility
    local cells = type(fac) == 'table' and (fac.Cells or (type(fac[FAC]) == 'table' and fac[FAC].Cells)) or nil
    if type(cells) == 'table' then
        local e = cells[cellId]
        if type(e) ~= 'table' then
            for _, x in ipairs(cells) do if type(x) == 'table' and (x.id == cellId or x.cellId == cellId) then e = x break end end
        end
        if type(e) == 'table' then return e.locker or e.coords end
    end
    return nil
end

local function allCells()
    local out = {}
    for id, c in pairs(SC.CellLockers or {}) do out[id] = c end
    local fac = Config.Facility
    local cells = type(fac) == 'table' and (fac.Cells or (type(fac[FAC]) == 'table' and fac[FAC].Cells)) or nil
    for k, x in pairs(type(cells) == 'table' and cells or {}) do
        if type(x) == 'table' then
            local id = type(k) == 'string' and k or x.id or x.cellId
            local c = x.locker or x.coords
            if type(id) == 'string' and c and not out[id] then out[id] = c end
        end
    end
    return out
end

--- The cell whose locker is within reach of src (server position), or nil.
function Sec.CellAt(src)
    local pos = I.pedPos(src)
    if not pos then return nil end
    local best, bestD
    for id, c in pairs(allCells()) do
        local d = dist(pos, c)
        if d <= num(SEARCH.CellReach, 3.0) and (not bestD or d < bestD) then best, bestD = id, d end
    end
    return best, best and allCells()[best] or nil
end

function Sec.CellStash(cellId) return ('pfprison_cell_%s_%s'):format(FAC, tostring(cellId):gsub('[^%w_%-]', '')) end

--- An inmate opens the locker of their own cell (standing at it).
function Sec.OpenCellLocker(src)
    local P = I.getPlayer(src)
    if not P then return err('offline', 'Not online') end
    local row = B.rows[P.PlayerData.citizenid]
    if not row or row.status ~= 'in_cell' or not B.IsAdmitted(src) then return err('no_permission', 'You have no cell here') end
    local coords = Sec.CellCoords(row.cell_id)
    if not coords then return err('not_found', 'Your cell has no locker') end
    local pos = I.pedPos(src)
    if dist(pos, coords) > num(SEARCH.CellReach, 3.0) then return err('too_far', 'Go to your cell') end
    local stash = Sec.CellStash(row.cell_id)
    local data = { label = ('Cell %s locker'):format(row.cell_id), maxweight = num(SC.CellLockerWeight, 20000), slots = num(SC.CellLockerSlots, 10) }
    inv('CreateInventory', stash, data)
    local _, ok = inv('OpenInventory', src, stash, data)
    if not ok then return err('unavailable', 'The locker could not be opened') end
    return { ok = true, cell = row.cell_id }
end

-- ── searches ────────────────────────────────────────────────────────────────────────────────────

local function nearestPlayer(src, reach)
    local pos = I.pedPos(src)
    if not pos then return nil end
    local best, bestD
    for _, other in ipairs(I.players()) do
        other = tonumber(other)
        if other and other ~= src then
            local d = dist(pos, I.pedPos(other))
            if d <= reach and (not bestD or d < bestD) then best, bestD = other, d end
        end
    end
    return best
end

local function inZone(pos, zone)
    return type(zone) == 'table' and zone.coords ~= nil and dist(pos, zone.coords) <= num(zone.radius, 10.0)
end

local function infraction(cid, orderId, searchId, evidenceIds, actor)
    local ok, res = pcall(function()
        return exports['pfm-prison']:RecordInfraction(cid, { code = SEARCH.InfractionCode or 'contraband', severity = num(SEARCH.InfractionSeverity, 2),
            evidenceIds = evidenceIds, orderId = orderId }, { key = ('pfm-prison:contraband:%d:infraction'):format(searchId), actor = { src = actor.src } })
    end)
    if ok and type(res) == 'table' and res.ok == true then return tonumber(res.infractionId) end
    warnOnce('infraction', 'RecordInfraction is not available: contraband searches record no infraction')
    return nil
end

--- A search by on-duty staff. kind = 'pat' (an inmate within reach), 'visitor' (anyone at the
--- visitor entry) or 'cell' (the cell locker the officer stands at). target = a server id for
--- pat/visitor (nil = the nearest person). Returns { ok, searchId, found = { { name, amount, class } },
--- state, evidenceIds, receiptId } or an error.
function Sec.Search(officerSrc, kind, target)
    local staff, e = Sec.Staff(officerSrc)
    if not staff then return e end
    if kind ~= 'pat' and kind ~= 'visitor' and kind ~= 'cell' then return err('bad_args', 'Unknown search') end
    local t = now()
    if t - num(Sec.lastOfficer[staff.cid], -math.huge) < num(SEARCH.OfficerCooldown, 5) then return err('rate_limited', 'Slow down') end
    local officerPos = I.pedPos(staff.src)
    if not officerPos then return err('offline', 'Not in the world') end

    local targetKey, targetSrc, targetCid, orderId, stash, cellId, cellCoords, items
    if kind == 'cell' then
        cellId, cellCoords = Sec.CellAt(staff.src)
        if not cellId then return err('too_far', 'Stand at a cell locker') end
        targetKey, stash = 'cell:' .. cellId, Sec.CellStash(cellId)
    else
        targetSrc = math.tointeger(tonumber(target)) or nearestPlayer(staff.src, num(SEARCH.Reach, 2.5))
        if not targetSrc or targetSrc == staff.src then return err('not_found', 'Nobody to search') end
        local TP = I.getPlayer(targetSrc)
        if not TP then return err('offline', 'Not online') end
        local tpos = I.pedPos(targetSrc)
        if dist(officerPos, tpos) > num(SEARCH.Reach, 2.5) then return err('too_far', 'Too far away') end
        targetCid = TP.PlayerData.citizenid
        if kind == 'pat' then
            if not PFPrison.IsServing(targetSrc) then return err('invalid_state', 'Not an inmate here') end
            local row = B.rows[targetCid]
            orderId = row and row.order_id or nil
        elseif not inZone(tpos, SEARCH.VisitorZone) or not inZone(officerPos, SEARCH.VisitorZone) then
            return err('too_far', 'Visitors are searched at the visitor entry')
        end
        targetKey = targetCid
    end
    if Sec.busy[targetKey] then return err('busy', 'Already being searched') end
    if t - num(Sec.lastSearch[targetKey], -math.huge) < num(SEARCH.TargetCooldown, 60) then return err('rate_limited', 'Searched a moment ago') end
    -- the lock is taken before the first database wait
    Sec.busy[targetKey] = true
    Sec.lastOfficer[staff.cid] = t
    local ok, res = pcall(function()
        local searchId = db('insert', Sec.SQL.searchInsert, { FAC, kind, targetKey:sub(1, 64), staff.cid, t })
        searchId = math.tointeger(tonumber(searchId))
        if not searchId or searchId < 1 then return err('db_unavailable', 'The search could not be recorded') end
        Sec.lastSearch[targetKey] = t
        -- what the target holds now (read after the wait, right before the roll)
        items = kind == 'cell' and stashItems(stash) or playerItems(targetSrc)
        local found = Sec.Roll(kind, items)
        local outcome, ids = { state = 'clean' }, {}
        if #found > 0 then
            if kind == 'cell' then outcome, ids = seizeFromCell(searchId, stash, cellId, cellCoords, found)
            else outcome, ids = seizeFromPerson(searchId, staff, targetSrc, orderId, found) end
        end
        local record = { items = publicItems(found), state = outcome.state, receiptId = outcome.receiptId, error = outcome.error,
            cell = cellId, attempts = 0 }
        db('update', Sec.SQL.searchUpdate, { encode(record), idsText(ids), searchId })
        if outcome.state == 'forfeit_pending' then
            Sec.pending[searchId] = { receiptId = outcome.receiptId, attempts = 0, nextAt = t + num(SEARCH.RetrySeconds, 60), record = record }
        end
        local infractionId
        if kind == 'pat' and #found > 0 and outcome.state ~= 'not_seized' then
            infractionId = infraction(targetCid, orderId, searchId, ids, staff)
        end
        if kind == 'visitor' then
            db('update', Sec.SQL.visitSearched, { targetCid, t - 3600, t + 3600 })
        end
        Sec.Event(targetCid, 'search', { searchId = searchId, kind = kind, found = #found, state = outcome.state, cell = cellId }, staff.cid)
        if #found > 0 then
            Sec.RaiseAlarm('contraband', { label = ('Contraband found (%s search #%d)'):format(kind, searchId), coords = officerPos, cid = targetCid, by = staff.cid })
        end
        return { ok = true, searchId = searchId, kind = kind, found = publicItems(found), state = outcome.state, error = outcome.error,
            evidenceIds = ids, receiptId = outcome.receiptId, infractionId = infractionId }
    end)
    Sec.busy[targetKey] = nil
    if not ok then
        print(('^1[pfm-prison]^7 search failed: %s'):format(tostring(res)))
        return err('db_unavailable', 'The search failed')
    end
    if res.ok and targetSrc then
        I.notify(targetSrc, #res.found > 0 and 'You were searched: contraband was taken' or 'You were searched', #res.found > 0 and 'error' or 'primary')
    end
    return res
end

--- Seizures held in a locker whose evidence could not be made yet: asked again (tick, and at start).
function Sec.RetryPending(at)
    at = at or now()
    for searchId, p in pairs(Sec.pending) do
        if at >= num(p.nextAt, 0) then
            local ids, state, e = forfeitReceipt(p.receiptId)
            p.attempts = p.attempts + 1
            p.record.attempts, p.record.error = p.attempts, e
            if state == 'evidence' then
                p.record.state = 'evidence'
                Sec.pending[searchId] = nil
                db('update', Sec.SQL.searchUpdate, { encode(p.record), idsText(ids), searchId })
            elseif p.attempts >= num(SEARCH.MaxRetries, 30) then
                -- the items stay in the pf-justice locker (held, never handed back by this module)
                p.record.state = 'held_in_locker'
                Sec.pending[searchId] = nil
                db('update', Sec.SQL.searchUpdate, { encode(p.record), idsText(ids), searchId })
                Sec.Event(nil, 'anomaly', { what = 'contraband_forfeit_failed', searchId = searchId, receiptId = p.receiptId, error = e })
            else
                p.nextAt = at + num(SEARCH.RetrySeconds, 60)
                db('update', Sec.SQL.searchUpdate, { encode(p.record), idsText(ids), searchId })
            end
        end
    end
end

function Sec.LoadPending()
    local rows = db('query', Sec.SQL.searchPending, { FAC, now() - 7 * 86400 })
    for _, r in ipairs(type(rows) == 'table' and rows or {}) do
        local rec = decode(r.found)
        local id = math.tointeger(tonumber(r.id))
        if id and type(rec) == 'table' and rec.state == 'forfeit_pending' and tonumber(rec.receiptId) and not Sec.pending[id] then
            Sec.pending[id] = { receiptId = math.tointeger(tonumber(rec.receiptId)), attempts = num(rec.attempts, 0), nextAt = 0, record = rec }
        end
    end
end

--- Staff open the prison evidence stash (at the evidence point) to hand the bags to the police.
function Sec.OpenEvidence(src)
    local staff, e = Sec.Staff(src)
    if not staff then return e end
    if not atPoint(staff.src, { SEARCH.EvidencePoint }) then return err('too_far', 'The evidence stash is at the gatehouse') end
    local stash = ensureEvidenceStash()
    local _, ok = inv('OpenInventory', staff.src, stash, { label = 'Prison evidence', maxweight = 200000, slots = 50 })
    if not ok then return err('unavailable', 'The evidence stash could not be opened') end
    return { ok = true }
end

-- ── escapes ─────────────────────────────────────────────────────────────────────────────────────

-- The arrest warrant for an escapee, asked from the police MDT. pf-policemdt-DEV has no server
-- export to create a warrant yet (only its officers' callback): until it has RequestWarrant the
-- call fails closed (no warrant is invented) and is asked again WarrantRetrySeconds later.
function Sec.RequestWarrant(esc)
    if esc.warrantId or not esc.id then return false end
    esc.attempts = (esc.attempts or 0) + 1
    esc.nextAt = now() + num(ESC.WarrantRetrySeconds, 120)
    if GetResourceState('pf-policemdt-DEV') ~= 'started' then return false end
    local ok, res = pcall(function()
        return exports['pf-policemdt-DEV']:RequestWarrant({
            type = 'arrest', suspectCitizenId = esc.cid, title = 'Escape from Bolingbroke Penitentiary',
            narrative = ('Escaped from Bolingbroke Penitentiary while serving order #%d (escape #%d)%s.'):format(esc.orderId, esc.id,
                esc.gate and (' through gate ' .. tostring(esc.gate)) or ''),
            charges = ESC.Charges or { 'Escape from custody' },
            source = { type = 'prison_escape', id = tostring(esc.id) },
        }, { key = ('pfm-prison:escape:%d:warrant'):format(esc.id), actor = SYSTEM })
    end)
    if ok and type(res) == 'table' and res.ok == true and type(res.warrantId) == 'string' and res.warrantId ~= '' then
        esc.warrantId = res.warrantId:sub(1, 32)
        db('update', Sec.SQL.escapeWarrant, { esc.warrantId, esc.id })
        Sec.Event(esc.cid, 'escape', { escapeId = esc.id, warrantId = esc.warrantId })
        return true
    end
    if not ok then warnOnce('warrant', 'pf-policemdt-DEV RequestWarrant is not available: escape warrants are not requested yet') end
    if esc.attempts == 1 then
        Sec.Event(esc.cid, 'anomaly', { what = 'warrant_request_failed', escapeId = esc.id, error = ok and type(res) == 'table' and res.error or 'unavailable' })
    end
    return false
end

--- main.lua: a confirmed escape of a pf-justice inmate (justice_bridge already suspended the order).
function Sec.OnEscape(src, cid, pos, info)
    if not validCid(cid) then return end
    info = type(info) == 'table' and info or {}
    local row = B.rows[cid]
    if not row or not row.order_id then return end
    local t = num(row.status_at, now())
    local gate = info.gate and tostring(info.gate):sub(1, 8) or nil
    local method = tostring(info.method or 'unknown'):sub(1, 16)
    local id = db('insert', Sec.SQL.escapeInsert, { cid, row.order_id, method, gate, t })
    id = math.tointeger(tonumber(id))
    local esc = { id = id and id > 0 and id or nil, cid = cid, orderId = row.order_id, escapedAt = t, method = method, gate = gate, attempts = 0, nextAt = 0 }
    Sec.escapes[cid] = esc
    -- classification raised: kept on the inmate row (and so through the recapture)
    local cls = ESC.Classification or 'max'
    if row.classification ~= cls then
        row.classification = cls
        B.SaveRow(row)
    end
    Sec.RaiseAlarm('escape', { label = 'Escape', coords = pos, cid = cid })
    if esc.id then Sec.RequestWarrant(esc)
    else Sec.Event(cid, 'anomaly', { what = 'escape_not_recorded', orderId = row.order_id }) end
end

-- The recapture forfeit: AdjustOrder forfeit (pf-justice caps a prison forfeit at the credits earned).
function Sec.RunForfeit(key, f)
    if GetResourceState('pf-justice') ~= 'started' then f.attempts = f.attempts + 1 return false end
    local ok, res = pcall(function()
        return exports['pf-justice']:AdjustOrder(f.orderId, { kind = 'forfeit', seconds = f.seconds, reason = 'escape: recaptured' },
            { key = key, actor = SYSTEM })
    end)
    f.attempts = f.attempts + 1
    if ok and type(res) == 'table' and res.ok == true then
        Sec.forfeits[key] = nil
        Sec.Event(f.cid, 'recapture', { orderId = f.orderId, forfeitSeconds = f.seconds, applied = tonumber(res.applied) or 0, escapeId = f.escapeId })
        return true
    end
    local e = ok and type(res) == 'table' and res.error or 'justice_unavailable'
    local permanent = { invalid_state = true, not_found = true, bad_args = true, no_permission = true, not_allowed = true, key_reused = true }
    if permanent[e] or f.attempts >= num(ESC.MaxActionAttempts, 10) then
        Sec.forfeits[key] = nil
        Sec.Event(f.cid, 'anomaly', { what = 'escape_forfeit_refused', orderId = f.orderId, error = e, attempts = f.attempts })
        return true
    end
    return false
end

--- An escapee taken back in (justice_bridge Admit 'readmit'): the escape row is closed and the
--- credits are forfeited. escapedAt = the row's status_at at the escape (stable across restarts).
function Sec.OnRecaptured(cid, orderId, escapedAt)
    if not validCid(cid) then return end
    local esc = Sec.escapes[cid]
    Sec.escapes[cid] = nil
    local t = now()
    if esc and esc.id then db('update', Sec.SQL.escapeRecaptured, { t, esc.id })
    else db('update', Sec.SQL.escapeRecapturedByOrder, { t, cid, orderId }) end
    local escOrder = esc and esc.orderId or orderId
    local at = esc and esc.escapedAt or escapedAt
    local seconds = math.floor(num(ESC.ForfeitSeconds, 3600))
    if seconds < 1 or not escOrder or not at then return end
    local key = ('pfm-prison:escape:%d:%d:forfeit'):format(escOrder, math.floor(at))
    local f = { cid = cid, orderId = escOrder, seconds = math.min(seconds, 3600), attempts = 0, escapeId = esc and esc.id or nil }
    Sec.forfeits[key] = f
    Sec.RunForfeit(key, f)
end

-- justice_bridge's Admit is wrapped: a readmission of an escaped row is a recapture.
if type(B) == 'table' and I.isCallable(B.Admit) and not B.securityWrapped then
    local admit = B.Admit
    B.securityWrapped = true
    B.Admit = function(src, order, how)
        local P = I.getPlayer(src)
        local cid = P and P.PlayerData.citizenid
        local row = cid and B.rows[cid]
        local wasEscaped = row ~= nil and row.status == 'escaped'
        local escapedAt, escOrder = row and row.status_at, row and row.order_id
        local res = admit(src, order, how)
        if res == 'admitted' and wasEscaped then
            local ok, e = pcall(Sec.OnRecaptured, cid, escOrder, escapedAt)
            if not ok then print(('^1[pfm-prison]^7 recapture record failed: %s'):format(tostring(e))) end
        end
        return res
    end
end

function Sec.LoadEscapes()
    local rows = db('query', Sec.SQL.escapesOpen, { now() - 30 * 86400 })
    for _, r in ipairs(type(rows) == 'table' and rows or {}) do
        if validCid(r.citizenid) and not Sec.escapes[r.citizenid] then
            Sec.escapes[r.citizenid] = { id = math.tointeger(tonumber(r.id)), cid = r.citizenid, orderId = math.tointeger(tonumber(r.order_id)),
                escapedAt = tonumber(r.escaped_at), method = r.method, gate = r.gate, warrantId = r.warrant_id, attempts = 0, nextAt = 0 }
        end
    end
end

-- ── tick, start and players ─────────────────────────────────────────────────────────────────────

--- Every TickSeconds: warrant requests and recapture forfeits that failed, pending evidence.
function Sec.Tick(at)
    at = at or now()
    for _, esc in pairs(Sec.escapes) do
        if esc.id and not esc.warrantId and esc.attempts < num(ESC.WarrantMaxAttempts, 30) and at >= num(esc.nextAt, 0) then
            Sec.RequestWarrant(esc)
        end
    end
    for key, f in pairs(Sec.forfeits) do Sec.RunForfeit(key, f) end
    Sec.RetryPending(at)
end

function Sec.Boot()
    if not dbReady() then return false end
    Sec.LoadEscapes()
    Sec.LoadPending()
    return true
end

CreateThread(function()
    Wait(2500) -- after the schema (justice_bridge's Boot runs it)
    local booted = Sec.Boot()
    while true do
        Wait(math.max(5, num(SC.TickSeconds, 15)) * 1000)
        if not booted then booted = Sec.Boot() end
        local ok, e = pcall(Sec.Tick)
        if not ok then print(('^1[pfm-prison]^7 security tick failed: %s'):format(tostring(e))) end
    end
end)

AddEventHandler('playerDropped', function()
    local src = tonumber(source)
    if not src then return end
    for key in pairs(Sec.zoneSeen) do
        if key:sub(1, #tostring(src) + 1) == tostring(src) .. ':' then Sec.zoneSeen[key] = nil end
    end
end)

AddEventHandler('pfm-core:server:characterDeleted', function(cid)
    local s = tonumber(source)
    if (s and s > 0) or not validCid(cid) then return end
    Sec.escapes[cid] = nil
    db('update', Sec.SQL.deleteSearchesOf, { cid })
    db('update', Sec.SQL.deleteEscapesOf, { cid })
    db('update', Sec.SQL.anonSearches, { 'deleted', cid })
end)

-- ── net events and commands (staff and inmates; every check is above) ───────────────────────────

local function answer(src, res, okText)
    if type(res) ~= 'table' then return end
    if res.ok then
        if okText then I.notify(src, okText, 'success') end
    else
        I.notify(src, res.message or res.error or 'Refused', 'error')
    end
end

local function foundText(res)
    if #res.found == 0 then return ('Search #%d: nothing found'):format(res.searchId) end
    local names = {}
    for _, it in ipairs(res.found) do names[#names + 1] = ('%s x%d'):format(it.name, it.amount) end
    local where = res.state == 'evidence' and 'taken into evidence' or res.state == 'forfeit_pending' and 'held in a property locker (evidence pending)'
        or res.state == 'partial' and 'partly taken into evidence' or 'left in place (evidence unavailable)'
    return ('Search #%d found %s: %s'):format(res.searchId, table.concat(names, ', '), where)
end

RegisterNetEvent('prison:server:SecuritySearch', function(kind, target)
    local src = source
    if type(kind) ~= 'string' then return end
    local res = Sec.Search(src, kind, target)
    if res.ok then I.notify(src, foundText(res), #res.found > 0 and 'success' or 'primary') else answer(src, res) end
end)

RegisterNetEvent('prison:server:ViewCamera', function(id)
    local src = source
    if type(id) ~= 'number' and type(id) ~= 'string' then return end
    answer(src, Sec.ViewCamera(src, id))
end)

RegisterNetEvent('prison:server:OpenCellLocker', function()
    local src = source
    answer(src, Sec.OpenCellLocker(src))
end)

-- /prisonsearch [pat|visitor|cell] [server id]
RegisterCommand('prisonsearch', function(src, args)
    if not src or src < 1 then return end
    local kind = args[1] or 'pat'
    local res = Sec.Search(src, kind, tonumber(args[2]))
    if res.ok then I.notify(src, foundText(res), #res.found > 0 and 'success' or 'primary') else answer(src, res) end
end, false)

-- /prisonlockdown on|off [minutes] [reason]
RegisterCommand('prisonlockdown', function(src, args)
    if not src or src < 1 then return end
    local on = args[1] == 'on'
    if args[1] ~= 'on' and args[1] ~= 'off' then return I.notify(src, 'Use /prisonlockdown on|off [minutes] [reason]', 'error') end
    local minutes = tonumber(args[2])
    local reason = table.concat(args, ' ', minutes and 3 or 2)
    answer(src, Sec.SetLockdown(on, { actor = { src = src }, minutes = minutes, reason = reason ~= '' and reason or nil }))
end, false)

-- /prisondoor <1..n> lock|unlock
RegisterCommand('prisondoor', function(src, args)
    if not src or src < 1 then return end
    if args[2] ~= 'lock' and args[2] ~= 'unlock' then return I.notify(src, 'Use /prisondoor <door> lock|unlock', 'error') end
    answer(src, Sec.SetDoor(args[1], args[2] == 'lock', { actor = { src = src } }), 'Door ' .. args[2] .. 'ed')
end, false)

-- /prisoncam [n]
RegisterCommand('prisoncam', function(src, args)
    if not src or src < 1 then return end
    answer(src, Sec.ViewCamera(src, tonumber(args[1]) or 1))
end, false)

-- /prisonalarm [list | clear <id> | riot]
RegisterCommand('prisonalarm', function(src, args)
    if not src or src < 1 then return end
    local staff, e = Sec.Staff(src)
    if not staff then return answer(src, e) end
    if args[1] == 'clear' then return answer(src, Sec.ClearAlarm(args[2], { actor = { src = src } }), 'Alarm cleared') end
    if args[1] == 'riot' then
        if not staff.control then return answer(src, err('no_permission', 'Your grade may not do that')) end
        return answer(src, Sec.RaiseAlarm('riot', { label = 'Disturbance reported', coords = I.pedPos(src), by = staff.cid }), 'Alarm raised')
    end
    if #Sec.alarms == 0 then return I.notify(src, 'No open alarms', 'primary') end
    for i = math.max(1, #Sec.alarms - 4), #Sec.alarms do
        local a = Sec.alarms[i]
        I.notify(src, ('#%d %s (%s)'):format(a.id, a.label, os.date('%H:%M', a.at)), 'primary')
    end
end, false)

-- /prisonevidence: open the prison evidence stash at the gatehouse
RegisterCommand('prisonevidence', function(src)
    if not src or src < 1 then return end
    answer(src, Sec.OpenEvidence(src))
end, false)

-- /celllocker: an inmate opens the locker of their own cell
RegisterCommand('celllocker', function(src)
    if not src or src < 1 then return end
    answer(src, Sec.OpenCellLocker(src))
end, false)

-- ── exports ─────────────────────────────────────────────────────────────────────────────────────

local function allowed(name)
    local inv = GetInvokingResource()
    if inv == nil or inv == GetCurrentResourceName() then return true end
    local list = (SC.Callers or {})[name]
    return list == '*' or (type(list) == 'table' and list[inv] == true)
end

--- GetSecurityStatus(facility): open read for apps and the MDTs.
exports('GetSecurityStatus', function(facility)
    if facility ~= nil and facility ~= FAC then return err('not_found', 'No such facility') end
    local alarms = {}
    for _, a in ipairs(Sec.alarms) do alarms[#alarms + 1] = { id = a.id, kind = a.kind, label = a.label, at = a.at, coords = a.coords } end
    local doors = {}
    for i, d in ipairs(SC.Doors or {}) do
        local ok, locked = pcall(function() return exports['pfm-doorlock']:GetDoorState(d.id) end)
        doors[#doors + 1] = { index = i, id = d.id, label = d.label, locked = ok and locked or nil }
    end
    local escaped = 0
    for _ in pairs(Sec.escapes) do escaped = escaped + 1 end
    return { ok = true, facility = FAC, lockdown = I.lockdownActive() == true,
        alarms = alarms, doors = doors, openEscapes = escaped, cameras = #(SC.Cameras or {}) }
end)

exports('ListCameras', function(facility)
    if facility ~= nil and facility ~= FAC then return err('not_found', 'No such facility') end
    return Sec.ListCameras()
end)

exports('ViewCamera', function(src, cameraId)
    if not allowed('ViewCamera') then return err('not_allowed', 'This resource may not show cameras') end
    return Sec.ViewCamera(src, cameraId)
end)

exports('SearchInmate', function(officerSrc, kind, target)
    if not allowed('Search') then return err('not_allowed', 'This resource may not search') end
    return Sec.Search(officerSrc, kind, target)
end)

exports('RaiseAlarm', function(facility, kind, opts)
    if not allowed('RaiseAlarm') then return err('not_allowed', 'This resource may not raise alarms') end
    if facility ~= nil and facility ~= FAC then return err('not_found', 'No such facility') end
    opts = type(opts) == 'table' and opts or {}
    local actor, e = resolveActor(opts.actor or SYSTEM, false)
    if not actor then return e end
    return Sec.RaiseAlarm(kind, { label = opts.label, coords = opts.coords, by = actor.cid })
end)

exports('SetSecurityDoor', function(door, locked, opts)
    if not allowed('SetDoor') then return err('not_allowed', 'This resource may not set doors') end
    return Sec.SetDoor(door, locked, opts)
end)
