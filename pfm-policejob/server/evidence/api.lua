-- Evidence exports (architecture 4.9) and the module's start-up, ticks and player hooks.
--
-- Exports check the invoking resource against Config.Evidence.Callers, read the actor from the
-- server (opts.actor = { src } | { kind = 'system' }), and return { ok = true, ... } or
-- { ok = false, error, message }. Server-only events (AddEventHandler, never net):
--   pfm-policejob:server:evidenceCreated(item)          a new evidence row (public shape)
--   pfm-policejob:server:evidenceCustody(item, event)   a custody row: { event, from, to, actor, note, at }

PFEvidence = PFEvidence or {}
local E = PFEvidence
E.Api = E.Api or {}
local A = E.Api
local Store, C, S = E.Store, E.Custody, E.Scene

local function actorFrom(opts, fallbackSrc)
    local raw = type(opts) == 'table' and opts.actor or nil
    if raw == nil and fallbackSrc then raw = { src = fallbackSrc } end
    return E.Actor(raw)
end

--- Wraps an export: allowlist, then the body inside pcall (a failure changes nothing it reports).
local function export(name, body)
    local fn = function(...)
        if not E.Allowed(name) then return E.Err('not_allowed', 'This resource may not call ' .. name) end
        local res = table.pack(pcall(body, ...))
        if not res[1] then
            print(('^1[pfm-policejob]^7 %s failed: %s'):format(name, tostring(res[2])))
            return E.Err('db_unavailable', 'Evidence could not be processed')
        end
        return res[2]
    end
    A[name] = fn
    exports(name, fn)
    return fn
end

-- ── CreateEvidence ────────────────────────────────────────────────────────────────────────────
local function giveTarget(giveTo)
    if giveTo == nil then return nil end
    if type(giveTo) == 'number' or (type(giveTo) == 'string' and giveTo:match('^%d+$')) then
        local P = E.Player(E.Int(giveTo, 1, 65535))
        if not P then return nil, 'offline' end
        return { inv = P.PlayerData.source, type = 'player' }
    end
    local stash = type(giveTo) == 'string' and giveTo:match('^stash:(.+)$')
    if not stash or #stash > 60 or stash:find('[%c"\'\\]') then return nil, 'bad_args' end
    return { inv = stash, type = 'inventory' }
end

--- Normalises a CreateEvidence spec into row fields. Returns fields, giveTo or nil, error.
function A.BuildSpec(spec, opts, actor)
    local cfg = E.Cfg()
    if type(spec) ~= 'table' then return nil, nil, 'bad_args', 'spec must be a table' end
    local def = (cfg.Kinds or {})[spec.kind]
    if not def then return nil, nil, 'bad_args', 'unknown kind' end
    local attrs, why = Store.CleanAttrs(spec.kind, spec.attrs)
    if not attrs then return nil, nil, 'bad_args', why end
    local label = E.Str(spec.label, 64) or def.label or spec.kind
    local method = spec.method == nil and 'manual' or spec.method
    if not (cfg.Methods or {})[method] then return nil, nil, 'bad_args', 'unknown method' end
    local scene = type(spec.scene) == 'table' and spec.scene or {}
    local coords = scene.coords ~= nil and E.Coords(scene.coords) or nil
    if scene.coords ~= nil and not coords then return nil, nil, 'bad_args', 'bad scene coords' end
    local sceneId = scene.sceneId ~= nil and E.Ref(scene.sceneId, 32) or nil
    if scene.sceneId ~= nil and not sceneId then return nil, nil, 'bad_args', 'bad scene id' end
    local links = {}
    if spec.caseRef ~= nil then
        local ref = Store.CaseRef(spec.caseRef)
        if not ref then return nil, nil, 'bad_args', 'bad case reference' end
        links[1] = ref
    end
    local origin = type(spec.origin) == 'table' and spec.origin or nil
    local originType = origin and E.Ref(origin.type, 16) or nil
    local originId = origin and E.Ref(origin.id, 64) or nil
    if origin and (not originType or not originId) then return nil, nil, 'bad_args', 'bad origin' end
    local sealed = spec.sealed ~= false

    local collector
    if spec.collectedBy ~= nil then
        collector = E.Player(E.Int(spec.collectedBy, 1, 65535))
        if not collector then return nil, nil, 'offline', 'the collecting officer is not here' end
        if not E.IsLeo(collector) then return nil, nil, 'no_permission', 'evidence is collected by on-duty police' end
    end

    local give
    if def.physical then
        local giveTo = opts.giveTo
        if giveTo == nil and collector then giveTo = collector.PlayerData.source end
        if giveTo == nil then return nil, nil, 'bad_args', 'physical evidence needs giveTo' end
        local err
        give, err = giveTarget(giveTo)
        if not give then return nil, nil, err, 'bad giveTo' end
    end

    local flags
    if def.contact and collector and Store.GloveRuleActive() and not Store.HasGloves(collector) then flags = 'contaminated' end
    local holderKind, holderRef = 'record', 'record'
    if give then holderKind, holderRef = C.Holder(give.type, give.inv) end
    local fields = {
        kind = spec.kind, label = label, attrs = attrs, state = sealed and 'sealed' or 'collected', sealed = sealed,
        quality = 100, flags = flags, holder_kind = holderKind, holder_ref = holderRef,
        scene_coords = coords and E.CoordsText(coords) or nil, scene_label = E.Str(scene.label, 96), scene_id = sceneId,
        collected_by = collector and collector.PlayerData.citizenid or (actor.cid or actor.label),
        collected_at = E.Now(), method = method, case_refs = links, origin_type = originType, origin_id = originId,
        idem_key = opts.key,
    }
    fields.integrity = Store.ComputeIntegrity(fields, {}, fields.collected_at)
    return fields, give
end

local function sameSpec(row, fields)
    local rowAttrs = type(row.attrs) == 'string' and json.decode(row.attrs) or {}
    return row.kind == fields.kind and row.label == fields.label and E.Canon(rowAttrs or {}) == E.Canon(fields.attrs or {})
end

export('CreateEvidence', function(spec, opts)
    opts = type(opts) == 'table' and opts or {}
    local invoker = GetInvokingResource()
    if opts.key ~= nil and not E.Ref(opts.key, 128) then return E.Err('bad_args', 'bad key') end
    if invoker and invoker ~= GetCurrentResourceName() and not opts.key then return E.Err('bad_args', 'opts.key is required') end
    local actor, aerr = actorFrom(opts, type(spec) == 'table' and spec.collectedBy or nil)
    if not actor then return E.Err(aerr or 'bad_args', 'bad actor') end
    if actor.kind == 'player' and not actor.leo and not actor.admin then return E.Err('no_permission', 'On-duty police only') end
    if not E.DbReady() then return E.Err('db_unavailable', 'Evidence storage is not ready') end
    local fields, give, code, msg = A.BuildSpec(spec, opts, actor)
    if not fields then return E.Err(code, msg) end

    local lockKey = opts.key and ('key:' .. opts.key) or nil
    if lockKey and not E.Lock(lockKey) then return E.Err('busy', 'The same key is being processed') end
    local ok, res = pcall(function()
        if opts.key then
            local existing = Store.GetByKey(opts.key)
            if existing then
                if not sameSpec(existing, fields) then return E.Err('key_reused', 'The key was used for other evidence') end
                return { ok = true, duplicate = true, evidenceId = existing.id, tag = existing.tag }
            end
        end
        local id, tag, existing = Store.Insert(fields)
        if not id then
            if tag == 'duplicate' and existing then
                if not sameSpec(existing, fields) then return E.Err('key_reused', 'The key was used for other evidence') end
                return { ok = true, duplicate = true, evidenceId = existing.id, tag = existing.tag }
            end
            return E.Err('db_unavailable', 'The evidence could not be recorded')
        end
        local row = Store.Get(id)
        if not row then return E.Err('db_unavailable', 'The evidence could not be recorded') end
        local pos = actor.src and E.Pos(actor.src) or nil
        Store.AddCustody(id, 'collected', fields.origin_type and (fields.origin_type .. ':' .. fields.origin_id) or nil, row.holder_ref, actor, nil, pos)
        if row.sealed then Store.AddCustody(id, 'sealed', row.holder_ref, row.holder_ref, actor, nil, pos) end
        if give and not C.PutBag(row, give.inv) then
            Store.Rollback(id)
            return E.Err('invalid_state', 'The evidence bag could not be handed out')
        end
        TriggerEvent('pfm-policejob:server:evidenceCreated', Store.Public(row))
        return { ok = true, evidenceId = id, tag = tag }
    end)
    if lockKey then E.Unlock(lockKey) end
    if not ok then error(res) end
    return res
end)

-- ── reads ─────────────────────────────────────────────────────────────────────────────────────
--- A viewer src must be on-duty police; without a viewer the allowlisted caller reads as itself.
local function viewerAllowed(viewer)
    if viewer == nil then return true end
    local P = E.Player(E.Int(viewer, 1, 65535))
    return P ~= nil and E.IsLeo(P)
end

local function resolveRow(id)
    if type(id) == 'string' and id:match('^%u+%-%d+%-%d+$') then
        return Store.Normalise(Store.Query('single', Store.SQL.byTag, { id }))
    end
    return Store.Get(id)
end

local function publicEvent(ev)
    return {
        id = tonumber(ev.id), event = ev.event, from = ev.from_ref, to = ev.to_ref, actor = ev.actor_cid,
        actorJob = ev.actor_job, pos = E.ParseCoords(ev.pos), note = ev.note, at = ev.at,
    }
end

export('GetEvidence', function(id, opts)
    opts = type(opts) == 'table' and opts or {}
    if not viewerAllowed(opts.viewer) then return E.Err('no_permission', 'On-duty police only') end
    if not E.DbReady() then return E.Err('db_unavailable', 'Evidence storage is not ready') end
    if id == nil or (type(id) ~= 'number' and type(id) ~= 'string') then return E.Err('bad_args', 'Missing id') end
    local row = resolveRow(id)
    if not row then return E.Err('not_found', 'No such evidence') end
    local score, flags, events = Store.Refresh(row)
    local custody, limit = {}, E.Cfg().CustodyListLimit or 100
    for i = math.max(1, #events - limit + 1), #events do custody[#custody + 1] = publicEvent(events[i]) end
    return {
        ok = true, item = Store.Public(row), custody = custody, custodyTotal = #events,
        integrity = { score = score, flags = flags },
        labs = {}, -- lab jobs arrive with batch 18 (SubmitToLab)
    }
end)

local LIST_SQL = 'SELECT id, tag, kind, label, attrs, state, sealed, quality, integrity, flags, holder_kind, holder_ref, scene_coords, '
    .. 'scene_label, scene_id, collected_by, collected_at, method, case_refs, origin_type, origin_id FROM pf_evidence_items'

--- Builds the paged query of ListEvidence. Returns sql, params, limit or nil, error.
function A.ListQuery(filter)
    local cfg = E.Cfg()
    local where, params = {}, {}
    if filter.caseRef ~= nil then
        local ref = Store.CaseRef(filter.caseRef)
        if not ref then return nil, 'bad case reference' end
        where[#where + 1] = "case_refs LIKE ? ESCAPE '!'"
        params[#params + 1] = '%"' .. ref:gsub('[!%%_]', '!%0') .. '"%'
    end
    if filter.holder ~= nil then
        local h = type(filter.holder) == 'table' and filter.holder or { ref = filter.holder }
        if h.kind ~= nil then
            local k = E.Ref(h.kind, 12)
            if not k then return nil, 'bad holder kind' end
            where[#where + 1] = 'holder_kind = ?'; params[#params + 1] = k
        end
        if h.ref ~= nil then
            local r = type(h.ref) == 'string' and #h.ref <= 64 and not h.ref:find('%c') and h.ref or nil
            if not r then return nil, 'bad holder ref' end
            where[#where + 1] = 'holder_ref = ?'; params[#params + 1] = r
        end
    end
    if filter.kind ~= nil then
        if not (cfg.Kinds or {})[filter.kind] then return nil, 'unknown kind' end
        where[#where + 1] = 'kind = ?'; params[#params + 1] = filter.kind
    end
    if filter.state ~= nil then
        if not Store.Transitions[filter.state] then return nil, 'unknown state' end
        where[#where + 1] = 'state = ?'; params[#params + 1] = filter.state
    end
    if filter.after ~= nil then
        local after = E.Int(filter.after, 1)
        if not after then return nil, 'bad cursor' end
        where[#where + 1] = 'id < ?'; params[#params + 1] = after
    end
    local max = cfg.ListLimit or 100
    local limit = E.Int(filter.limit, 1) or 25
    if limit > max then limit = max end
    local sql = LIST_SQL .. (#where > 0 and (' WHERE ' .. table.concat(where, ' AND ')) or '') .. ' ORDER BY id DESC LIMIT ?'
    params[#params + 1] = limit + 1
    return sql, params, limit
end

export('ListEvidence', function(filter)
    filter = type(filter) == 'table' and filter or {}
    if not viewerAllowed(filter.viewer) then return E.Err('no_permission', 'On-duty police only') end
    if not E.DbReady() then return E.Err('db_unavailable', 'Evidence storage is not ready') end
    local sql, params, limit = A.ListQuery(filter)
    if not sql then return E.Err('bad_args', params) end
    local rows = Store.Query('query', sql, params)
    local list = {}
    for i, r in ipairs(type(rows) == 'table' and rows or {}) do
        if i > limit then break end
        list[#list + 1] = Store.Public(Store.Normalise(r))
    end
    local nextCursor = (type(rows) == 'table' and #rows > limit and #list > 0) and list[#list].id or nil
    return { ok = true, list = list, next = nextCursor }
end)

-- ── writes ────────────────────────────────────────────────────────────────────────────────────
local function withActor(opts, fn)
    local actor, err = actorFrom(opts)
    if not actor then return E.Err(err or 'bad_args', 'bad actor') end
    return fn(actor)
end

export('TransferEvidence', function(id, to, opts)
    opts = type(opts) == 'table' and opts or {}
    return withActor(opts, function(actor) return C.Transfer(id, to, opts, actor) end)
end)

export('SealEvidence', function(id, opts)
    opts = type(opts) == 'table' and opts or {}
    return withActor(opts, function(actor) return C.Seal(id, opts, actor) end)
end)

export('BreakSeal', function(id, reason, opts)
    opts = type(opts) == 'table' and opts or {}
    return withActor(opts, function(actor) return C.BreakSeal(id, reason, opts, actor) end)
end)

export('LinkEvidence', function(id, caseRef, opts)
    opts = type(opts) == 'table' and opts or {}
    return withActor(opts, function(actor) return C.Link(id, caseRef, opts, actor, false) end)
end)

export('UnlinkEvidence', function(id, caseRef, opts)
    opts = type(opts) == 'table' and opts or {}
    return withActor(opts, function(actor) return C.Link(id, caseRef, opts, actor, true) end)
end)

export('DisposeEvidence', function(id, mode, opts)
    opts = type(opts) == 'table' and opts or {}
    return withActor(opts, function(actor) return C.Dispose(id, mode, opts, actor) end)
end)

-- ── start-up and ticks ────────────────────────────────────────────────────────────────────────
function A.Start()
    if not PFPoliceSchema or not PFPoliceSchema.WaitReady() then
        print('^1[pfm-policejob]^7 evidence not started: the schema is not ready')
        return false
    end
    Store.LoadLockers()
    S.Load()
    C.Process()
    return true
end

--- One minute of upkeep: decay, missing bags, and once a day the retention sweeps.
function A.MinuteTick(now)
    now = now or E.Now()
    S.Decay(now)
    C.CheckRemovals(now)
    if not A.lastSweep or now - A.lastSweep >= 86400 then
        A.lastSweep = now
        S.SweepRetention(now)
        Store.SweepRetention(now)
    end
end

CreateThread(function()
    if not A.Start() then return end
    local sc = E.SceneCfg()
    CreateThread(function()
        while true do
            Wait(sc.FlushMs or 2000)
            pcall(S.Flush)
        end
    end)
    CreateThread(function()
        while true do
            Wait(sc.SyncTickMs or 5000)
            pcall(S.SyncTick)
        end
    end)
    CreateThread(function()
        while true do
            Wait(5000)
            pcall(C.CheckRemovals)
        end
    end)
    while true do
        Wait(sc.DecayTickMs or 60000)
        local ok, err = pcall(A.MinuteTick)
        if not ok then print(('^1[pfm-policejob]^7 evidence upkeep failed: %s'):format(tostring(err))) end
    end
end)

-- ── player hooks ──────────────────────────────────────────────────────────────────────────────
function A.OnDutyChanged(src, onDuty)
    src = tonumber(src)
    if not src then return end
    local P = E.Player(src)
    if onDuty and P and E.IsLeo(P) then
        S.SendSnapshot(src)
    elseif S.lastCell[src] then
        S.lastCell[src] = nil
        TriggerClientEvent('evidence:client:SceneSnapshot', src, {})
    end
end

AddEventHandler('QBCore:Server:SetDuty', function(src, onDuty) A.OnDutyChanged(src, onDuty) end)
AddEventHandler('QBCore:Server:OnJobUpdate', function(src, job)
    A.OnDutyChanged(src, type(job) == 'table' and job.type == 'leo' and job.onduty == true)
end)

function A.OnPlayerDropped(src)
    E.ForgetSource(src)
    C.ForgetSource(src)
    S.ForgetSource(src)
end

AddEventHandler('playerDropped', function() A.OnPlayerDropped(source) end)

-- the person who left a drop is forgotten with the character; the evidence record stays
AddEventHandler('pfm-core:server:characterDeleted', function(citizenid)
    if type(citizenid) ~= 'string' or not E.DbReady() then return end
    Store.Query('update', 'UPDATE pf_evidence_scene_drops SET source_cid = NULL WHERE source_cid = ?', { citizenid })
    S.ForgetCitizen(citizenid)
end)
