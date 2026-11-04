-- Evidence records (pf_evidence_items) and the helpers every server/evidence/* module shares:
-- config, validation, actors, caller allowlists, rate limits, locks, integrity and the state machine.
--
-- One row per physical or recorded piece of evidence. A physical item lives in an inventory as a
-- unique bag item whose info carries evidenceId; the row says who holds it (holder_kind/holder_ref)
-- and every change of holder or state is one pf_evidence_custody row (custody.lua). Clients never
-- write any of it: drops come from server-checked reports (scene.lua), bags from the server.
--
-- Holder refs: player:<citizenid> | inv:<inventory id> (stash, trunk, glovebox) | drop:<ground drop id>
--              | lab:<id> | court:<case id> | released:<citizenid> | destroyed | record | unknown
-- Holder kinds: officer | civilian | inventory | locker | ground | lab | court | released | record | unknown

PFEvidence = PFEvidence or {}
local E = PFEvidence
E.Store = E.Store or {}
local Store = E.Store

function E.Cfg() return (Config and Config.Evidence) or {} end
function E.SceneCfg() return E.Cfg().Scene or {} end

function E.Now() return os.time() end

function E.Err(code, message) return { ok = false, error = code, message = message or code } end

-- ── validation (architecture 3.6) ─────────────────────────────────────────────────────────────
function E.Str(v, max)
    if type(v) ~= 'string' then return nil end
    v = v:gsub('%c', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    if v == '' then return nil end
    if max and #v > max then v = v:sub(1, max) end
    return v
end

function E.Int(v, min, max)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge then return nil end
    v = math.floor(v)
    if (min and v < min) or (max and v > max) then return nil end
    return v
end

-- ids, keys and refs: letters, digits and - _ : . only
function E.Ref(v, max)
    if type(v) == 'number' then v = tostring(math.floor(v)) end
    if type(v) ~= 'string' or v == '' or #v > (max or 64) then return nil end
    if not v:match('^[%w%-_:%.]+$') then return nil end
    return v
end

function E.Coords(c)
    if type(c) ~= 'table' and type(c) ~= 'vector3' then return nil end
    local x, y, z = tonumber(c.x), tonumber(c.y), tonumber(c.z)
    if not x or not y or not z then return nil end
    for _, n in ipairs({ x, y, z }) do
        if n ~= n or n > 20000 or n < -20000 then return nil end
    end
    return vector3(x, y, z)
end

function E.CoordsText(v)
    if not v then return nil end
    return ('%.2f,%.2f,%.2f'):format(v.x, v.y, v.z)
end

function E.ParseCoords(s)
    if type(s) ~= 'string' then return nil end
    local x, y, z = s:match('^(%-?[%d%.]+),(%-?[%d%.]+),(%-?[%d%.]+)$')
    if not x then return nil end
    return { x = tonumber(x), y = tonumber(y), z = tonumber(z) }
end

-- a callable from another resource arrives as a funcref table (never test type == 'function')
function E.Callable(v)
    if type(v) == 'function' then return true end
    if type(v) ~= 'table' then return false end
    if type(rawget(v, '__cfx_functionReference')) == 'string' then return true end
    local mt = getmetatable(v)
    return type(mt) == 'table' and rawget(mt, '__call') ~= nil
end

-- JSON with sorted keys, so two equal tables always encode the same (idempotency comparisons)
function E.Canon(v)
    local t = type(v)
    if t == 'table' then
        local n = #v
        local count = 0
        for _ in pairs(v) do count = count + 1 end
        if n > 0 and count == n then
            local parts = {}
            for i = 1, n do parts[i] = E.Canon(v[i]) end
            return '[' .. table.concat(parts, ',') .. ']'
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do
            local val = v[k]
            if val == nil then val = v[tonumber(k)] end
            parts[#parts + 1] = json.encode(k) .. ':' .. E.Canon(val)
        end
        return '{' .. table.concat(parts, ',') .. '}'
    elseif t == 'number' and v == math.floor(v) then
        return ('%d'):format(v)
    end
    return json.encode(v)
end

function E.RandomHex(n)
    local out = {}
    for i = 1, n do out[i] = ('%x'):format(math.random(0, 15)) end
    return table.concat(out)
end

-- ── players and actors (architecture 3.5) ─────────────────────────────────────────────────────
function E.Player(src)
    src = tonumber(src)
    if not src or src <= 0 then return nil end
    return exports['pfm-core']:GetPlayer(src)
end

function E.IsLeo(P)
    local job = P and P.PlayerData and P.PlayerData.job
    return job ~= nil and job.type == 'leo' and job.onduty == true
end

function E.Grade(P)
    local g = P and P.PlayerData and P.PlayerData.job and P.PlayerData.job.grade
    if type(g) == 'table' then return tonumber(g.level) or 0 end
    return tonumber(g) or 0
end

function E.Pos(src) return GetEntityCoords(GetPlayerPed(src)) end

function E.Dist(a, b)
    if not a or not b then return math.huge end
    local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- Reads who acts from the server: { kind = 'player', src, cid, job, grade, leo, supervisor } or a
--- system/admin actor. Nothing in opts.actor except src, kind and label is used.
function E.Actor(actor)
    if actor == nil then return { kind = 'system', label = GetInvokingResource() or GetCurrentResourceName() } end
    if type(actor) ~= 'table' then return nil, 'bad_args' end
    if actor.src ~= nil then
        local src = E.Int(actor.src, 1, 65535)
        local P = src and E.Player(src)
        if not P then return nil, 'offline' end
        local a = {
            kind = 'player', src = src, cid = P.PlayerData.citizenid, job = P.PlayerData.job and P.PlayerData.job.name,
            grade = E.Grade(P), leo = E.IsLeo(P),
        }
        a.supervisor = a.leo and a.grade >= (E.Cfg().SupervisorGrade or 3)
        if actor.kind == 'admin' then
            if not IsPlayerAceAllowed(src, 'admin') then return nil, 'no_permission' end
            a.kind, a.admin = 'admin', true
        end
        return a
    end
    if actor.kind == 'system' then
        return { kind = 'system', label = E.Str(actor.label, 32) or GetInvokingResource() or 'system' }
    end
    return nil, 'bad_args'
end

-- ── caller allowlists (architecture 3.4) ──────────────────────────────────────────────────────
local deniedLog = {}
function E.Allowed(exportName)
    local invoker = GetInvokingResource()
    if invoker == nil or invoker == GetCurrentResourceName() then return true end
    local list = (E.Cfg().Callers or {})[exportName]
    if list == '*' or (type(list) == 'table' and list[invoker]) then return true end
    local key = invoker .. ':' .. exportName
    local now = E.Now()
    if not deniedLog[key] or now - deniedLog[key] >= 60 then
        deniedLog[key] = now
        print(('^3[pfm-policejob]^7 %s is not allowed to call %s'):format(invoker, exportName))
    end
    return false
end

-- ── rate limits (token bucket per key) and locks ──────────────────────────────────────────────
local buckets = {}
function E.Rate(key, perSecond, burst)
    local now = GetGameTimer()
    local b = buckets[key]
    if not b then
        b = { tokens = burst, at = now }
        buckets[key] = b
    else
        b.tokens = math.min(burst, b.tokens + (now - b.at) / 1000 * perSecond)
        b.at = now
    end
    if b.tokens < 1 then return false end
    b.tokens = b.tokens - 1
    return true
end

function E.ForgetSource(src)
    local prefix = tostring(src) .. ':'
    for k in pairs(buckets) do
        if k:sub(1, #prefix) == prefix then buckets[k] = nil end
    end
end

local locks = {}
function E.Lock(key)
    if locks[key] then return false end
    locks[key] = true
    return true
end
function E.Unlock(key) locks[key] = nil end
function E.IsLocked(key) return locks[key] == true end

function E.DbReady()
    return PFPoliceSchema ~= nil and PFPoliceSchema.Ready()
end

-- ── state machine (architecture 5.7) ─────────────────────────────────────────────────────────
Store.Transitions = {
    collected  = { sealed = true, stored = true, in_transit = true, at_lab = true, released = true, destroyed = true },
    sealed     = { stored = true, in_transit = true, at_lab = true, in_court = true, released = true, destroyed = true },
    in_transit = { in_transit = true, stored = true, at_lab = true, in_court = true, released = true, destroyed = true },
    stored     = { stored = true, in_transit = true, at_lab = true, in_court = true, released = true, destroyed = true },
    at_lab     = { at_lab = true, analysed = true, stored = true, in_transit = true },
    analysed   = { analysed = true, stored = true, in_transit = true, at_lab = true, in_court = true, released = true, destroyed = true },
    in_court   = { in_court = true, stored = true, in_transit = true, released = true, destroyed = true },
    released   = {},
    destroyed  = {},
}

function Store.CanMove(from, to)
    local t = Store.Transitions[from]
    return t ~= nil and t[to] == true
end

function Store.IsTerminal(state) return state == 'released' or state == 'destroyed' end

-- ── attrs per kind ────────────────────────────────────────────────────────────────────────────
local function validUrl(v)
    v = E.Str(v, 255)
    if not v or not v:match('^https://[%w%-%.]+/[%w%-%._~/%%%?=&]*$') then return nil end
    local host = v:match('^https://([%w%-%.]+)/')
    for _, allowed in ipairs(E.Cfg().PhotoHosts or {}) do
        if host == allowed or host:sub(-(#allowed + 1)) == '.' .. allowed then return v end
    end
    return nil
end

--- Copies only the fields the kind's schema lists, each checked; unknown fields are dropped.
function Store.CleanAttrs(kind, attrs)
    local def = (E.Cfg().Kinds or {})[kind]
    if not def then return nil, 'unknown kind' end
    if attrs ~= nil and type(attrs) ~= 'table' then return nil, 'attrs must be a table' end
    local out = {}
    for field, ty in pairs(def.attrs or {}) do
        local v = attrs and attrs[field]
        if v ~= nil then
            local clean
            local len = ty:match('^str(%d+)$')
            if len then clean = E.Str(type(v) == 'number' and tostring(v) or v, tonumber(len))
            elseif ty == 'int' then clean = E.Int(v, -2147483648, 4294967295)
            elseif ty == 'bool' then clean = v == true
            elseif ty == 'url' then clean = validUrl(v); if not clean then return nil, 'bad ' .. field end
            elseif ty == 'plate' then
                clean = type(v) == 'string' and v:upper():gsub('[^%w ]', ''):gsub('^%s+', ''):gsub('%s+$', '') or nil
                if not clean or clean == '' or #clean > 8 then return nil, 'bad ' .. field end
            end
            out[field] = clean
        end
    end
    if attrs and attrs.clientReported == true then out.clientReported = true end
    if kind == 'photo' then out.clientSupplied = true end -- screenshots always come from a client
    local encoded = json.encode(out)
    if #encoded > 4096 then return nil, 'attrs too large' end
    return out
end

-- ── rows ──────────────────────────────────────────────────────────────────────────────────────
local COLS = [[id, tag, kind, label, attrs, state, sealed, quality, integrity, flags, holder_kind, holder_ref,
    scene_coords, scene_label, scene_id, collected_by, collected_at, method, case_refs, origin_type, origin_id, idem_key]]

Store.SQL = {
    insert = [[INSERT INTO pf_evidence_items (tag, kind, label, attrs, state, sealed, quality, integrity, flags, holder_kind, holder_ref,
        scene_coords, scene_label, scene_id, collected_by, collected_at, method, case_refs, origin_type, origin_id, idem_key)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]],
    setTag = 'UPDATE pf_evidence_items SET tag = ? WHERE id = ?',
    byId = 'SELECT ' .. COLS .. ' FROM pf_evidence_items WHERE id = ? LIMIT 1',
    byTag = 'SELECT ' .. COLS .. ' FROM pf_evidence_items WHERE tag = ? LIMIT 1',
    byKey = 'SELECT ' .. COLS .. ' FROM pf_evidence_items WHERE idem_key = ? LIMIT 1',
    deleteItem = 'DELETE FROM pf_evidence_items WHERE id = ?',
    deleteCustody = 'DELETE FROM pf_evidence_custody WHERE evidence_id = ?',
    -- compare-and-set on the holder and state the caller read
    move = [[UPDATE pf_evidence_items SET holder_kind = ?, holder_ref = ?, state = ?
        WHERE id = ? AND state = ? AND (holder_ref = ? OR (holder_ref IS NULL AND ? IS NULL))]],
    setSeal = 'UPDATE pf_evidence_items SET sealed = ?, state = ? WHERE id = ? AND state = ? AND sealed = ?',
    setLinks = 'UPDATE pf_evidence_items SET case_refs = ? WHERE id = ?',
    setIntegrity = 'UPDATE pf_evidence_items SET integrity = ?, flags = ? WHERE id = ?',
    custody = [[INSERT INTO pf_evidence_custody (evidence_id, event, from_ref, to_ref, actor_cid, actor_src, actor_job, pos, note, at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]],
    custodyOf = [[SELECT id, event, from_ref, to_ref, actor_cid, actor_src, actor_job, pos, note, at
        FROM pf_evidence_custody WHERE evidence_id = ? ORDER BY at, id LIMIT 1000]],
    locker = 'SELECT id, station, label, stash_id, case_ref FROM pf_evidence_lockers WHERE id = ? LIMIT 1',
    lockerByStash = 'SELECT id, station, label, stash_id, case_ref FROM pf_evidence_lockers WHERE stash_id = ? LIMIT 1',
    lockerInsert = 'INSERT IGNORE INTO pf_evidence_lockers (station, label, stash_id, case_ref, created_at) VALUES (?, ?, ?, ?, ?)',
    sweepCustody = [[DELETE FROM pf_evidence_custody WHERE at < ?
        AND evidence_id IN (SELECT id FROM pf_evidence_items WHERE state IN ('released', 'destroyed')) LIMIT 500]],
}

local function q(kind, sql, params)
    local ok, res = pcall(MySQL[kind].await, sql, params)
    if not ok then
        print(('^1[pfm-policejob]^7 evidence query failed: %s'):format(tostring(res)))
        return nil, false
    end
    return res, true
end
Store.Query = q

local function affected(res)
    if type(res) == 'number' then return res end
    if type(res) == 'table' then return tonumber(res.affectedRows) or 0 end
    return 0
end
Store.Affected = affected

local function splitFlags(s)
    local out = {}
    if type(s) == 'string' then
        for f in s:gmatch('[%w_]+') do out[#out + 1] = f end
    end
    return out
end

local function hasFlag(list, f)
    for _, v in ipairs(list) do if v == f then return true end end
    return false
end
Store.HasFlag = hasFlag

--- Case links are stored as "type:id" strings so ListEvidence can filter them reliably.
function Store.CaseRef(ref)
    if type(ref) ~= 'table' then return nil end
    local ty = E.Ref(ref.type, 16)
    local id = E.Ref(ref.id, 64)
    if not ty or not id or not (E.Cfg().CaseRefTypes or {})[ty] then return nil end
    return ty .. ':' .. id
end

local function decodeLinks(s)
    local list = type(s) == 'string' and json.decode(s) or nil
    return type(list) == 'table' and list or {}
end
Store.DecodeLinks = decodeLinks

--- Normalises a DB row (numbers may come back as strings).
function Store.Normalise(row)
    if type(row) ~= 'table' or row.id == nil then return nil end
    row.id = math.floor(tonumber(row.id))
    row.sealed = tonumber(row.sealed) == 1 or row.sealed == true
    row.quality = tonumber(row.quality) or 100
    row.integrity = tonumber(row.integrity) or 100
    row.collected_at = tonumber(row.collected_at) or 0
    return row
end

function Store.Get(id)
    id = E.Int(id, 1)
    if not id then return nil end
    local row = q('single', Store.SQL.byId, { id })
    return Store.Normalise(row)
end

function Store.GetByKey(key)
    local row = q('single', Store.SQL.byKey, { key })
    return Store.Normalise(row)
end

--- The public shape of a row (attrs decoded, links as { type, id }).
function Store.Public(row)
    local attrs = type(row.attrs) == 'string' and json.decode(row.attrs) or {}
    local links = {}
    for _, s in ipairs(decodeLinks(row.case_refs)) do
        local ty, id = tostring(s):match('^([^:]+):(.+)$')
        if ty then links[#links + 1] = { type = ty, id = id } end
    end
    local def = (E.Cfg().Kinds or {})[row.kind] or {}
    return {
        id = row.id, tag = row.tag, kind = row.kind, label = row.label, attrs = attrs or {}, state = row.state,
        sealed = row.sealed, quality = row.quality, integrity = row.integrity, flags = splitFlags(row.flags),
        holder = { kind = row.holder_kind, ref = row.holder_ref },
        scene = { coords = E.ParseCoords(row.scene_coords), label = row.scene_label, sceneId = row.scene_id },
        collectedBy = row.collected_by, collectedAt = row.collected_at, method = row.method,
        caseRefs = links, origin = row.origin_type and { type = row.origin_type, id = row.origin_id } or nil,
        physical = def.physical == true,
        -- identifying a biological sample needs the lab (batch 18); until then it is awaiting lab
        identification = def.biological and row.kind ~= 'fingerprint' and 'awaiting_lab' or nil,
    }
end

--- Inserts a row and gives it its tag (EV-<year>-<id>). Returns id, tag; or nil, 'duplicate', row
--- when the idempotency key exists; or nil, 'db'.
function Store.Insert(f)
    local now = f.collected_at or E.Now()
    local tmp = 'T' .. E.RandomHex(15)
    local id, ok = q('insert', Store.SQL.insert, {
        tmp, f.kind, f.label, json.encode(f.attrs or {}), f.state, f.sealed and 1 or 0, f.quality or 100,
        f.integrity or 100, f.flags, f.holder_kind, f.holder_ref, f.scene_coords, f.scene_label, f.scene_id,
        f.collected_by, now, f.method, json.encode(f.case_refs or {}), f.origin_type, f.origin_id, f.idem_key,
    })
    id = ok and tonumber(id) or nil
    if not id or id < 1 then
        if f.idem_key then
            local existing = Store.GetByKey(f.idem_key)
            if existing then return nil, 'duplicate', existing end
        end
        return nil, 'db'
    end
    id = math.floor(id)
    local tag = ('%s-%s-%06d'):format(E.Cfg().TagPrefix or 'EV', os.date('%Y', now), id)
    q('update', Store.SQL.setTag, { tag, id })
    return id, tag
end

--- Removes a row that never became a real item (its bag could not be handed out).
function Store.Rollback(id)
    q('query', Store.SQL.deleteCustody, { id })
    q('query', Store.SQL.deleteItem, { id })
end

--- One custody/audit row. actor from E.Actor.
function Store.AddCustody(evidenceId, event, fromRef, toRef, actor, note, pos)
    actor = actor or {}
    local _, ok = q('insert', Store.SQL.custody, {
        evidenceId, event, fromRef, toRef, actor.cid, actor.src, actor.job or (actor.kind ~= 'player' and actor.label or nil),
        pos and E.CoordsText(pos) or nil, note and tostring(note):sub(1, 255) or nil, E.Now(),
    })
    return ok
end

function Store.Custody(evidenceId)
    local rows = q('query', Store.SQL.custodyOf, { evidenceId })
    local out = {}
    for _, r in ipairs(type(rows) == 'table' and rows or {}) do
        r.at = tonumber(r.at) or 0
        r.actor_src = tonumber(r.actor_src)
        out[#out + 1] = r
    end
    return out
end

-- ── integrity (architecture 4.9) ──────────────────────────────────────────────────────────────
local function unknownRef(ref)
    return ref == nil or ref == 'unknown' or tostring(ref):sub(1, 5) == 'drop:'
end
Store.UnknownRef = unknownRef

-- custody.lua writes this note when a bag reaches someone who is not on-duty police (a civilian):
-- the chain cannot vouch for it there either, so that time counts towards a gap like an unknown holder
Store.CIVILIAN_NOTE = 'not on-duty police'
local function outsideCustody(ev)
    return unknownRef(ev.to_ref) or (type(ev.note) == 'string' and ev.note:sub(1, #Store.CIVILIAN_NOTE) == Store.CIVILIAN_NOTE)
end

local CUSTODY_HOLDER_EVENTS = {
    collected = true, moved = true, handed_over = true, stored = true, checked_out = true, checked_in = true,
    submitted_lab = true, presented_court = true, released = true, destroyed = true, flagged_missing = true,
}

--- Pure: score and flags from the row and its custody events (ascending).
function Store.ComputeIntegrity(row, events, now)
    local cfg = E.Cfg().Integrity or {}
    local score = cfg.Start or 100
    local flags = {}
    local function flag(f) if not hasFlag(flags, f) then flags[#flags + 1] = f end end
    local gapSeconds = (E.Cfg().GapMinutes or 30) * 60

    local unknownSince, gaps = nil, 0
    for _, ev in ipairs(events or {}) do
        if ev.event == 'seal_broken' then
            local where = tostring(ev.from_ref or '')
            if where:sub(1, 4) ~= 'lab:' and where:sub(1, 6) ~= 'court:' then
                score = score - (cfg.SealBroken or 12)
                flag('seal_broken')
            end
        elseif CUSTODY_HOLDER_EVENTS[ev.event] then
            local at = tonumber(ev.at) or 0
            if outsideCustody(ev) and ev.event ~= 'released' and ev.event ~= 'destroyed' then
                unknownSince = unknownSince or at
            else
                if unknownSince and at - unknownSince > gapSeconds then gaps = gaps + 1 end
                unknownSince = nil
            end
        end
    end
    if unknownSince and (now or E.Now()) - unknownSince > gapSeconds then gaps = gaps + 1 end
    if gaps > 0 then
        score = score - gaps * (cfg.Gap or 20)
        flag('gap')
    end

    local stored = splitFlags(row.flags)
    local def = (E.Cfg().Kinds or {})[row.kind] or {}
    if hasFlag(stored, 'contaminated') then
        flag('contaminated')
        if def.contact then score = score - (cfg.NoGloves or 10) end
    end
    if row.holder_ref == 'unknown' then flag('missing') end
    if score < 0 then score = 0 end
    return score, flags
end

--- Recomputes and stores the integrity of one row; returns score, flags, events.
function Store.Refresh(row)
    local events = Store.Custody(row.id)
    local score, flags = Store.ComputeIntegrity(row, events, E.Now())
    local text = #flags > 0 and table.concat(flags, ',') or nil
    if score ~= row.integrity or text ~= row.flags then
        q('update', Store.SQL.setIntegrity, { score, text, row.id })
        row.integrity, row.flags = score, text
    end
    return score, flags, events
end

--- Moves a row to a new holder/state if nobody changed it since it was read.
function Store.Move(row, holderKind, holderRef, state)
    local res, ok = q('update', Store.SQL.move, { holderKind, holderRef, state, row.id, row.state, row.holder_ref, row.holder_ref })
    if not ok or affected(res) ~= 1 then return false end
    row.holder_kind, row.holder_ref, row.state = holderKind, holderRef, state
    return true
end

-- ── lockers ───────────────────────────────────────────────────────────────────────────────────
-- The station evidence drawers (server/main.lua opens them as Lang 'info.current_evidence' with the
-- station index and drawer number) count as lockers. Their stash id depends on the server's locale
-- ("1 | Drawer 4", "1 | Lade 4"...), so the pattern is built from that same phrase; operators can add
-- their own patterns in Config.Evidence.DrawerPatterns (two captures: station, drawer). A drawer gets
-- a pf_evidence_lockers row the first time evidence is checked into it; every locker row's stash id
-- is known after start (Store.LoadLockers).
local function escapePattern(s) return (s:gsub('[%^%$%(%)%%%.%[%]%*%+%-%?]', '%%%0')) end

function Store.DrawerPatterns()
    if Store.drawerPatterns then return Store.drawerPatterns end
    local list = {}
    for _, p in ipairs(E.Cfg().DrawerPatterns or {}) do
        if type(p) == 'string' then list[#list + 1] = p end
    end
    local ok, phrase = pcall(function() return Lang:t('info.current_evidence', { value = 'XSTATIONX', value2 = 'XDRAWERX' }) end)
    if ok and type(phrase) == 'string' and phrase:find('XSTATIONX', 1, true) and phrase:find('XDRAWERX', 1, true) then
        local pat = escapePattern(phrase):gsub('XSTATIONX', '(%%d+)'):gsub('XDRAWERX', '(%%d+)')
        list[#list + 1] = '^' .. pat .. '$'
    end
    list[#list + 1] = '^(%d+) | Drawer (%d+)$' -- the English phrase, for stashes made before a locale change
    Store.drawerPatterns = list
    return list
end

function Store.DrawerOf(stashId)
    if type(stashId) ~= 'string' or #stashId > 64 then return nil end
    for _, pat in ipairs(Store.DrawerPatterns()) do
        local station, drawer = stashId:match(pat)
        station, drawer = tonumber(station), tonumber(drawer)
        if station and drawer and Config.Locations and Config.Locations['evidence'] and Config.Locations['evidence'][station] then
            return station, drawer
        end
    end
    return nil
end

--- Remembers the stash id of every locker row (after the schema is ready).
function Store.LoadLockers()
    local rows = q('query', 'SELECT stash_id FROM pf_evidence_lockers', {})
    E.lockerStashes = E.lockerStashes or {}
    for _, r in ipairs(type(rows) == 'table' and rows or {}) do
        if type(r.stash_id) == 'string' then E.lockerStashes[r.stash_id] = true end
    end
end

function Store.IsLockerStash(stashId)
    return Store.DrawerOf(stashId) ~= nil or (E.lockerStashes or {})[stashId] == true
end

function Store.LockerLocation(stashId)
    local station = Store.DrawerOf(stashId)
    local loc = station and Config.Locations and Config.Locations['evidence'] and Config.Locations['evidence'][station]
    if not loc then return nil end
    return vector3(loc.x, loc.y, loc.z)
end

--- A locker by row id, or a station drawer by its stash id (registered on first use).
function Store.ResolveLocker(lockerId)
    if type(lockerId) == 'string' and Store.DrawerOf(lockerId) then
        local station = Store.DrawerOf(lockerId)
        if not (Config.Locations and Config.Locations['evidence'] and Config.Locations['evidence'][station]) then return nil end
        local row = q('single', Store.SQL.lockerByStash, { lockerId })
        if not row then
            q('insert', Store.SQL.lockerInsert, { 'drawer:' .. station, lockerId, lockerId, nil, E.Now() })
            row = q('single', Store.SQL.lockerByStash, { lockerId })
        end
        if row then E.lockerStashes = E.lockerStashes or {}; E.lockerStashes[row.stash_id] = true end
        return row
    end
    local id = E.Int(lockerId, 1)
    if not id then return nil end
    local row = q('single', Store.SQL.locker, { id })
    if row then E.lockerStashes = E.lockerStashes or {}; E.lockerStashes[row.stash_id] = true end
    return row
end

-- ── the bag item ──────────────────────────────────────────────────────────────────────────────
--- The bag item name for new bags: the new unique evidence_bag once the item exists, else the legacy bag.
function Store.BagItemName()
    local cfg = E.Cfg()
    local items = E.sharedItems or {}
    if items[cfg.BagItem or 'evidence_bag'] then return cfg.BagItem or 'evidence_bag' end
    return cfg.LegacyBagItem or 'filled_evidence_bag'
end

function Store.IsBag(item)
    if type(item) ~= 'table' or type(item.name) ~= 'string' then return false end
    if not (E.Cfg().BagItems or {})[item.name] then return false end
    return type(item.info) == 'table' and E.Int(item.info.evidenceId, 1) ~= nil
end

--- The bag's info, built from the row only (shown in the inventory tooltip).
function Store.BagInfo(row)
    local attrs = type(row.attrs) == 'string' and json.decode(row.attrs) or (type(row.attrs) == 'table' and row.attrs) or {}
    local info = {
        evidenceId = row.id, tag = row.tag, kind = row.kind, label = row.label, sealed = row.sealed == true,
        type = row.kind, -- legacy readers of filled_evidence_bag used info.type
        description = ('%s %s (%s)'):format(row.tag or '', row.label or '', row.sealed and 'sealed' or 'seal broken'),
    }
    if row.scene_label then info.street = row.scene_label end
    if row.kind == 'blood' then
        info.sample = attrs.sampleId
        info.dnalabel = attrs.sampleId -- a sample id, not an identity: the lab identifies it
        info.bloodtype = attrs.bloodtype
    elseif row.kind == 'fingerprint' then
        info.fingerprint = attrs.printId -- compared with the station fingerprint scanner
    elseif row.kind == 'dna_swab' then
        info.sample = attrs.sampleId
    elseif row.kind == 'casing' or row.kind == 'projectile' then
        info.caliber = attrs.caliber
        info.weapon = attrs.weapon
        info.serial = attrs.serial
    elseif row.kind == 'drug' or row.kind == 'item' then
        info.item, info.amount = attrs.item, attrs.amount
    elseif row.kind == 'weapon' then
        info.item, info.serial = attrs.item, attrs.serial
    elseif row.kind == 'document' then
        info.title = attrs.title
    end
    return info
end

--- True when this player carries the glove item (server inventory).
function Store.HasGloves(P)
    local glove = E.Cfg().GloveItem or 'nitrile_gloves'
    for _, item in pairs(P and P.PlayerData and P.PlayerData.items or {}) do
        if type(item) == 'table' and item.name == glove and (tonumber(item.amount) or 1) > 0 then return true end
    end
    return false
end

--- Whether the glove rule can apply at all: without the item in the shared items nobody could pass it.
function Store.GloveRuleActive()
    return (E.sharedItems or {})[E.Cfg().GloveItem or 'nitrile_gloves'] ~= nil
end

function Store.SweepRetention(now)
    local days = E.Cfg().CustodyRetentionDays
    if not days then return 0 end
    local res = q('query', Store.SQL.sweepCustody, { (now or E.Now()) - days * 86400 })
    return affected(res)
end

E.sharedItems = exports['pfm-core']:GetShared('Items') or {}
