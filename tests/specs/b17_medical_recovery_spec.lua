-- pf-ambulancejob recovery (batch 17C) with an in-memory stand-in for the SQL layer: the injury stage
-- machine (stabilise, treat, recover, self-heal of minor wounds), restrictions set by healing wounds
-- and by other modules (persisted, re-pushed at load, extended instead of duplicated, ended when the
-- wound heals or the time runs out), offline progression across a relog, infection of an uncared
-- wound and its worsening, re-bleed on server-seen exertion, the no_drive sampler that logs (only
-- watched patients are sampled) and the GetRestrictions export with its privacy rule.
load_resource('tests/lua/fivem_mocks.lua')
function IsDuplicityVersion() return true end
function GetCurrentResourceName() return 'pf-ambulancejob' end
function GetResourceState() return 'started' end

local AJ = '[pfscripts]/pf-ambulancejob/'
load_resource(AJ .. 'config.lua')
load_resource(AJ .. 'config_medical.lua')
load_resource(AJ .. 'shared/framework.lua')
for _, f in ipairs({ 'anatomy', 'injuries', 'physiology_model', 'effects_model' }) do
    load_resource(AJ .. 'shared/medical/' .. f .. '.lua')
end

-- server natives the sampler reads (not in the shared mocks)
local velocity = {}
local nativeCalls = { velocity = 0, vehicle = 0 }
function GetEntityVelocity(ent) nativeCalls.velocity = nativeCalls.velocity + 1 return velocity[ent] or vector3(0, 0, 0) end
local baseVehicleOf = GetVehiclePedIsIn
function GetVehiclePedIsIn(ped, last) nativeCalls.vehicle = nativeCalls.vehicle + 1 return baseVehicleOf(ped, last) end

-- ── in-memory SQL layer (the real statements run in b17_medical_schema_realdb_spec) ────────────
local DB
local function copy(t)
    if type(t) ~= 'table' then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = copy(v) end
    return o
end
local function installFakeSQL()
    DB = { patients = {}, injuries = {}, events = {}, restrictions = {}, nextId = 0, nextR = 0, calls = {} }
    local Q = PFMed.SQL
    local function call(name) DB.calls[name] = (DB.calls[name] or 0) + 1 end
    Q.LoadPatient = function(cid) return copy(DB.patients[cid]) end
    Q.LoadOpenInjuries = function(cid)
        local out = {}
        for _, r in pairs(DB.injuries) do if r.citizenid == cid and r.stage ~= 'recovered' then out[#out + 1] = copy(r) end end
        table.sort(out, function(a, b) return a.id < b.id end)
        return out
    end
    Q.FindInjuryByKey = function(key)
        for _, r in pairs(DB.injuries) do if r.idem_key == key then return { id = r.id, citizenid = r.citizenid, attrs = r.attrs } end end
    end
    Q.InjuryOwner = function(id) return DB.injuries[id] and DB.injuries[id].citizenid end
    Q.InsertInjury = function(r)
        if r.idem_key then for _, x in pairs(DB.injuries) do if x.idem_key == r.idem_key then error("Duplicate entry for key 'uq_med_inj_key'") end end end
        DB.nextId = DB.nextId + 1
        local row = copy(r)
        row.id = DB.nextId
        DB.injuries[row.id] = row
        return row.id
    end
    Q.UpsertPatients = function(rows) for _, r in ipairs(rows) do DB.patients[r.citizenid] = copy(r) end return true end
    Q.UpsertInjuries = function(rows)
        for _, r in ipairs(rows) do
            local old = DB.injuries[r.id] or {}
            for k, v in pairs(r) do old[k] = v end
            DB.injuries[r.id] = old
        end
        return true
    end
    Q.InsertEvents = function(rows) for _, e in ipairs(rows) do DB.events[#DB.events + 1] = copy(e) end return true end
    Q.DeleteCharacter = function() return {} end
    -- restrictions
    Q.LoadRestrictions = function(cid)
        call('LoadRestrictions')
        local out = {}
        for _, r in pairs(DB.restrictions) do if r.citizenid == cid and r.ended_at == nil then out[#out + 1] = copy(r) end end
        table.sort(out, function(a, b) return a.id < b.id end)
        return out
    end
    Q.ReadRestrictions = function(cid, at)
        call('ReadRestrictions')
        local out = {}
        for _, r in pairs(DB.restrictions) do
            if r.citizenid == cid and r.ended_at == nil and (r.until_at == nil or r.until_at > at) then out[#out + 1] = copy(r) end
        end
        table.sort(out, function(a, b) return a.id < b.id end)
        return out
    end
    Q.InsertRestriction = function(r)
        call('InsertRestriction')
        DB.nextR = DB.nextR + 1
        local row = copy(r)
        row.id = DB.nextR
        DB.restrictions[row.id] = row
        return row.id
    end
    Q.EndRestriction = function(id, at) call('EndRestriction') if DB.restrictions[id] then DB.restrictions[id].ended_at = at end return 1 end
    Q.SetRestrictionUntil = function(id, untilAt) call('SetRestrictionUntil') if DB.restrictions[id] then DB.restrictions[id].until_at = untilAt end return 1 end
    Q.DeleteRestrictions = function(cid)
        call('DeleteRestrictions')
        for id, r in pairs(DB.restrictions) do if r.citizenid == cid then DB.restrictions[id] = nil end end
        return 1
    end
end

Mock.exportsByResource['pfm-core'].RunMigrations = function() return true end

local function fresh()
    for _, f in ipairs({ 'schema', 'store', 'engine', 'effects', 'api', 'recovery' }) do
        load_resource(AJ .. 'server/medical/' .. f .. '.lua')
    end
    installFakeSQL()
    assert(PFMed.Schema.Start(), 'schema ready')
    PFMed.Engine.Random = function() return 0.5 end
    PFMed.Recovery.Random = function() return 0.99 end
    Mock.exportsByResource['pf-ambulancejob'] = Mock.exportsByResource['__self']
end

local Store, Engine, Rec, Fx
local function online(src, cid)
    local p = Mock.newPlayer(src, cid)
    Mock.fireEvent('QBCore:Server:PlayerLoaded', nil, p)
    return p
end
local function drop(src) Mock.fireEvent('playerDropped', src) end
local function patient(cid) return Store.Peek(cid or 'CID1') end
local function add(spec, cid)
    local inj, err = Engine.AddInjury(cid or 'CID1', spec, {})
    assert(inj, 'injury added: ' .. tostring(err))
    return inj
end
local function upd(id, patch, cid) return assert(Engine.UpdateInjury(cid or 'CID1', id, patch, {}), 'update') end
local function openRows(cid, kind)
    local out = {}
    for _, r in pairs(DB.restrictions) do
        if r.citizenid == (cid or 'CID1') and r.ended_at == nil and (kind == nil or r.kind == kind) then out[#out + 1] = r end
    end
    return out
end
local function lastEffects(src)
    local list = Mock.clientEventsNamed('pf-ambulancejob:client:Effects')
    for i = #list, 1, -1 do if list[i].target == (src or 1) then return list[i].args[1], list[i].args[2] end end
end
local function as(resource, fn)
    Mock.invokingResource = resource
    local ok, a = pcall(fn)
    Mock.invokingResource = nil
    if not ok then error(a, 2) end
    return a
end

local TIBIA = { mechanism = 'fall', type = 'fracture', subtype = 'closed', structure = 'tibia_l', severity = 3 }
local HUMERUS = { mechanism = 'fall', type = 'fracture', subtype = 'closed', structure = 'humerus_r', severity = 2 }
local BRUISE = { mechanism = 'blunt', type = 'bruising', subtype = 'contusion', region = 'thigh_l', severity = 1 }
local CUT = { mechanism = 'edged', type = 'laceration', subtype = 'deep', region = 'thigh_l', severity = 2 }
local CONCUSSION = { mechanism = 'blunt', type = 'head_trauma', subtype = 'concussion', structure = 'brain', severity = 1 }

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords, Mock.aces, Mock.vehicleOf = {}, {}, {}, {}
    velocity = {}
    nativeCalls.velocity, nativeCalls.vehicle = 0, 0
    Mock.invokingResource = nil
    Mock.clock = 1700000000
    fresh()
    Store, Engine, Rec, Fx = PFMed.Store, PFMed.Engine, PFMed.Recovery, PFMed.Effects
end

-- ── stage machine ──────────────────────────────────────────────────────────────────────────────

describe('stage machine', function()
    it('a fracture stays injured without a splint, stabilises with one and recovers after a cast', function()
        online(1)
        local inj = add(TIBIA)
        upd(inj.id, { bleed_ml_min = 0 })
        Rec.Advance('CID1')
        assert_eq(inj.stage, 'injured', 'a broken leg is not stable just because it stopped bleeding')
        upd(inj.id, { treatments = { splinted = true } })
        Rec.Advance('CID1')
        assert_eq(inj.stage, 'stabilized')
        upd(inj.id, { treatments = { cast = true } })
        Rec.Advance('CID1')
        assert_eq(inj.stage, 'recovering', 'definitive care moves on to recovering in the same pass')
        assert_eq(inj.recover_at, os.time() + 43200, 'catalogue heal time for severity 3')
        assert_eq(patient().stage, 'recovering')
    end)

    it('a recovering wound recovers at recover_at and its restriction ends with it', function()
        online(1)
        local inj = add(TIBIA)
        upd(inj.id, { bleed_ml_min = 0, treatments = { splinted = true, cast = true } })
        Rec.Advance('CID1')
        assert_eq(inj.stage, 'recovering')
        local rows = openRows('CID1', 'crutches')
        assert_eq(#rows, 1, 'a healing leg fracture means crutches')
        assert_eq(rows[1].injury_id, inj.id)
        assert_eq(rows[1].until_at, inj.recover_at)
        assert_true(patient().restrictions.crutches ~= nil)
        Mock.clock = Mock.clock + 43199
        Rec.Advance('CID1')
        assert_eq(inj.stage, 'recovering', 'not yet')
        Mock.clock = Mock.clock + 1
        Rec.Advance('CID1')
        assert_eq(inj.stage, 'recovered')
        assert_eq(#openRows('CID1'), 0, 'restriction ended')
        assert_eq(patient().stage, 'healthy')
        assert_true(patient().restrictions.crutches == nil)
    end)

    it('a treatment module recover_at wins over the catalogue time', function()
        online(1)
        local inj = add(HUMERUS)
        upd(inj.id, { bleed_ml_min = 0, treatments = { splinted = true } })
        Rec.Advance('CID1')
        upd(inj.id, { stage = 'treated', recover_at = os.time() + 600 })
        Rec.Advance('CID1')
        assert_eq(inj.stage, 'recovering')
        assert_eq(inj.recover_at, os.time() + 600)
        assert_eq(#openRows('CID1', 'cast_arm_r'), 1, 'arm restriction on the right side')
    end)

    it('a minor bruise heals on its own, slower than with care; a deep cut does not', function()
        online(1)
        local bruise = add(BRUISE)
        local cut = add(CUT)
        upd(cut.id, { bleed_ml_min = 0 })
        Rec.Advance('CID1')
        assert_eq(bruise.stage, 'recovering')
        assert_true(bruise.attrs.self_heal == true)
        assert_eq(bruise.recover_at, os.time() + math.floor(900 * 1.5 + 0.5))
        assert_eq(cut.stage, 'stabilized', 'a moderate cut waits for wound care')
        upd(cut.id, { treatments = { basic_wound_care = true } })
        Rec.Advance('CID1')
        assert_eq(cut.stage, 'recovering')
        assert_eq(cut.recover_at, os.time() + 3600)
    end)

    it('a wound that still bleeds is not stabilised; a tourniquet counts as controlled', function()
        online(1)
        local cut = add(CUT)
        Rec.Advance('CID1')
        assert_eq(cut.stage, 'injured')
        upd(cut.id, { treatments = { tourniquet = true } })
        Rec.Advance('CID1')
        assert_eq(cut.stage, 'stabilized')
    end)

    it('the engine flag or the action name both count as the treatment', function()
        online(1)
        local inj = add(TIBIA)
        upd(inj.id, { bleed_ml_min = 0, treatments = { splint = true } })
        Rec.Advance('CID1')
        assert_eq(inj.stage, 'stabilized', 'action name splint')
        upd(inj.id, { treatments = { surgery = true } })
        Rec.Advance('CID1')
        assert_eq(inj.stage, 'recovering', 'surgery_ortho is met by the surgery flag')
    end)

    it('the Sync loop advances a patient whose record changed (treated -> recovering at once)', function()
        online(1)
        local inj = add(TIBIA)
        upd(inj.id, { bleed_ml_min = 0, treatments = { splinted = true, cast = true } })
        Fx.Sync(os.time())
        assert_eq(inj.stage, 'recovering')
        local payload = lastEffects(1)
        local found = false
        for _, k in ipairs(payload.restrictions) do if k == 'crutches' then found = true end end
        assert_true(found, 'the new restriction went out with the profile')
    end)
end)

-- ── offline progression and relog ─────────────────────────────────────────────────────────────

describe('offline progression', function()
    it('time offline counts: a wound recovering at logout is recovered at the next login', function()
        online(1)
        local inj = add(TIBIA)
        upd(inj.id, { bleed_ml_min = 0, treatments = { splinted = true, cast = true } })
        Rec.Advance('CID1')
        local recoverAt = inj.recover_at
        drop(1)
        assert_true(Store.Peek('CID1') == nil, 'flushed and evicted')
        assert_eq(DB.injuries[inj.id].stage, 'recovering')
        Mock.clock = Mock.clock + 86400
        online(2, 'CID1')
        Store.Flush()
        local row = DB.injuries[inj.id]
        assert_eq(row.stage, 'recovered')
        assert_eq(row.recovered_at, recoverAt, 'healed at recover_at, not at the login')
        assert_eq(#openRows('CID1'), 0, 'its restriction ended while offline')
        local payload = lastEffects(2)
        assert_eq(payload.walk, 0)
        assert_eq(#payload.restrictions, 0)
    end)

    it('restrictions survive a relog and are pushed again at load', function()
        online(1)
        local res = Rec.AddRestriction('CID1', { kind = 'no_drive', seconds = 7200, reason = 'Discharge order' })
        assert_true(res.ok, tostring(res.error))
        local payload = lastEffects(1)
        assert_eq(payload.drive, 2, 'no_drive keeps drive at 2')
        drop(1)
        Mock.clock = Mock.clock + 600
        Mock.reset()
        online(1)
        assert_true(patient().restrictions.no_drive ~= nil)
        payload = lastEffects(1)
        assert_true(payload ~= nil, 'pushed at load even for the same content')
        assert_eq(payload.drive, 2)
        assert_eq(payload.restrictions[1], 'no_drive')
        Mock.clock = Mock.clock + 7200
        Rec.Advance('CID1')
        assert_eq(#openRows('CID1'), 0, 'expired')
        assert_eq(lastEffects(1).drive, 0)
    end)
end)

-- ── restrictions from other modules ───────────────────────────────────────────────────────────

describe('AddRestriction', function()
    it('validates, extends the same kind instead of adding a row, and works for an offline citizen', function()
        assert_eq(Rec.AddRestriction('CID1', { kind = 'No Drive!' }).error, 'bad_args')
        assert_eq(Rec.AddRestriction('CID1', { kind = 'no_drive', seconds = 5 }).error, 'bad_args')
        assert_eq(Rec.AddRestriction('bad cid', { kind = 'no_drive' }).error, 'bad_args')
        local a = Rec.AddRestriction('CID9', { kind = 'no_sprint', seconds = 3600 })
        assert_true(a.ok)
        local b = Rec.AddRestriction('CID9', { kind = 'no_sprint', seconds = 7200 })
        assert_true(b.ok and b.extended)
        assert_eq(b.id, a.id)
        local rows = openRows('CID9', 'no_sprint')
        assert_eq(#rows, 1)
        assert_eq(rows[1].until_at, os.time() + 7200, 'moved to the later end')
        local c = Rec.AddRestriction('CID9', { kind = 'no_sprint', seconds = 600 })
        assert_true(c.extended)
        assert_eq(openRows('CID9', 'no_sprint')[1].until_at, os.time() + 7200, 'never shortened')
    end)

    it('holds a lock across its database wait (a second call meanwhile is busy)', function()
        online(1)
        local inner
        local orig = PFMed.SQL.InsertRestriction
        PFMed.SQL.InsertRestriction = function(r)
            inner = Rec.AddRestriction('CID1', { kind = 'no_sprint' })
            return orig(r)
        end
        local res = Rec.AddRestriction('CID1', { kind = 'no_drive' })
        PFMed.SQL.InsertRestriction = orig
        assert_true(res.ok)
        assert_eq(inner.error, 'busy')
        assert_eq(#openRows('CID1'), 1)
    end)

    it('EndRestriction lifts a kind and the client is told', function()
        online(1)
        Rec.AddRestriction('CID1', { kind = 'no_drive' })
        assert_eq(lastEffects(1).drive, 2)
        local res = Rec.EndRestriction('CID1', 'no_drive')
        assert_eq(res.ended, 1)
        assert_eq(#openRows('CID1'), 0)
        assert_eq(lastEffects(1).drive, 0)
    end)

    it('ReloadRestrictions picks up rows another module wrote itself (deferred while a pass holds the patient)', function()
        online(1)
        local function write(kind)
            DB.nextR = DB.nextR + 1
            DB.restrictions[DB.nextR] = { id = DB.nextR, citizenid = 'CID1', kind = kind, from_at = os.time(), until_at = os.time() + 3600 }
        end
        write('no_drive')
        assert_true(patient().restrictions.no_drive == nil, 'not known yet')
        local res = Rec.ReloadRestrictions('CID1')
        assert_true(res.ok and res.reloaded)
        assert_true(patient().restrictions.no_drive ~= nil)
        assert_eq(lastEffects(1).drive, 2, 'pushed')
        -- while a pass waits on the database the reload is kept for the end of that pass
        write('no_sprint')
        local orig = PFMed.SQL.InsertRestriction
        local inner
        PFMed.SQL.InsertRestriction = function(r) inner = Rec.ReloadRestrictions('CID1') return orig(r) end
        Rec.AddRestriction('CID1', { kind = 'crutches' })
        PFMed.SQL.InsertRestriction = orig
        assert_true(inner.deferred)
        Rec.Advance('CID1')
        assert_true(patient().restrictions.no_sprint ~= nil, 'reloaded by the next pass')
        assert_true(Rec.ReloadRestrictions('CIDOFF').ok, 'offline: the next load reads the table')
    end)

    it('a deleted character loses its restriction rows', function()
        Rec.AddRestriction('CIDX', { kind = 'no_drive' })
        Mock.fireEvent('pfm-core:server:characterDeleted', nil, 'CIDX')
        assert_eq(#openRows('CIDX'), 0)
        -- a player cannot raise it
        Rec.AddRestriction('CIDY', { kind = 'no_drive' })
        Mock.fireEvent('pfm-core:server:characterDeleted', 5, 'CIDY')
        assert_eq(#openRows('CIDY'), 1)
    end)
end)

-- ── complications ──────────────────────────────────────────────────────────────────────────────

describe('infection', function()
    it('an uncared open wound becomes infected after the configured time, once (keyed)', function()
        online(1)
        local cut = add(CUT)
        upd(cut.id, { bleed_ml_min = 0 })
        Rec.Advance('CID1')
        assert_eq(cut.stage, 'stabilized')
        Mock.clock = Mock.clock + 7199
        Rec.Advance('CID1')
        assert_eq(cut.stage, 'stabilized', 'not yet')
        Mock.clock = Mock.clock + 1
        Rec.Advance('CID1')
        assert_eq(cut.stage, 'complicated')
        local infId = cut.attrs.infected
        local inf = patient().injuries[infId]
        assert_true(inf ~= nil and inf.type == 'infection')
        assert_eq(inf.idem_key, 'pf-ambulancejob:infection:' .. cut.id)
        Rec.Advance('CID1')
        local n = 0
        for _, i in pairs(patient().injuries) do if i.type == 'infection' then n = n + 1 end end
        assert_eq(n, 1, 'one infection per wound')
    end)

    it('wound care in time prevents it; a small cut never gets infected', function()
        online(1)
        local cut = add(CUT)
        upd(cut.id, { bleed_ml_min = 0, treatments = { pressure = true } })
        local small = add({ mechanism = 'edged', type = 'laceration', subtype = 'superficial', region = 'forearm_l', severity = 1 })
        upd(small.id, { bleed_ml_min = 2 })
        upd(cut.id, { treatments = { basic_wound_care = true } })
        Mock.clock = Mock.clock + 10000
        Rec.Advance('CID1')
        assert_true(cut.attrs.infected == nil)
        assert_true(small.attrs.infected == nil)
    end)

    it('an untreated infection worsens (several steps after time offline); antibiotics resolve the complication', function()
        online(1)
        local cut = add(CUT)
        upd(cut.id, { bleed_ml_min = 0 })
        Mock.clock = Mock.clock + 7200
        Rec.Advance('CID1')
        local inf = patient().injuries[cut.attrs.infected]
        assert_eq(inf.severity, 1)
        Mock.clock = Mock.clock + 3600 * 5
        Rec.Advance('CID1')
        assert_eq(inf.severity, 3, 'capped at MaxSeverity')
        upd(inf.id, { treatments = { antibiotics = true } })
        Rec.Advance('CID1')
        assert_eq(inf.stage, 'recovering', 'antibiotics stabilise and treat the infection')
        assert_eq(cut.stage, 'stabilized', 'the wound may stabilise again')
        upd(cut.id, { treatments = { sutures = true } })
        Rec.Advance('CID1')
        assert_eq(cut.stage, 'recovering')
    end)
end)

describe('re-bleed on exertion', function()
    local function dressedCut()
        online(1)
        Mock.coords[1] = vector3(0, 0, 0)
        local cut = add(CUT)
        upd(cut.id, { bleed_ml_min = 0.5, treatments = { pressure = true } })
        Rec.Advance('CID1')
        assert_eq(cut.stage, 'stabilized')
        Fx.Push(1, { force = true })
        assert_true(Rec.IsWatched('CID1') ~= nil and Rec.IsWatched('CID1').rebleed, 'watched for exertion')
        return cut
    end

    it('sprinting with a dressed wound can open it again (server-read speed, rolled once per episode)', function()
        local cut = dressedCut()
        Rec.Random = function() return 0.05 end
        velocity[1] = vector3(6, 0, 0)
        Rec.Sample(os.time())
        Rec.Sample(os.time())
        assert_eq(cut.stage, 'stabilized', 'two samples are not an episode')
        Rec.Sample(os.time())
        assert_eq(cut.stage, 'complicated')
        assert_true(cut.treatments.pressure == nil, 'the dressing failed')
        assert_eq(cut.bleed_ml_min, 2.5, 'bleeds again at half its first bleed')
        assert_eq(cut.attrs.rebleed, 1)
        assert_true(Engine.IsActive('CID1'), 'the engine ticks the bleeding again')
    end)

    it('walking does not count, a failed roll waits for the cooldown, a tourniquet is never at risk', function()
        local cut = dressedCut()
        local rolls = 0
        Rec.Random = function() rolls = rolls + 1 return 0.99 end
        velocity[1] = vector3(2, 0, 0)
        for _ = 1, 5 do Rec.Sample(os.time()) end
        assert_eq(rolls, 0, 'walking speed')
        velocity[1] = vector3(6, 0, 0)
        for _ = 1, 6 do Rec.Sample(os.time()) end
        assert_eq(rolls, 1, 'one roll inside the cooldown')
        Mock.clock = Mock.clock + 120
        for _ = 1, 3 do Rec.Sample(os.time()) end
        assert_eq(rolls, 2)
        assert_eq(cut.stage, 'stabilized')
        upd(cut.id, { treatments = { tourniquet = true } })
        Fx.Push(1, { force = true })
        assert_true(Rec.IsWatched('CID1') == nil, 'nothing to watch any more')
    end)
end)

-- ── no_drive sampler ──────────────────────────────────────────────────────────────────────────

describe('no_drive sampler', function()
    it('logs a driver with no_drive once per minute and pushes the profile again; a passenger is fine', function()
        online(1)
        online(2, 'CID2')
        Rec.AddRestriction('CID1', { kind = 'no_drive' })
        assert_true(Rec.IsWatched('CID1') ~= nil)
        assert_true(Rec.IsWatched('CID2') == nil, 'a healthy player is not watched')
        nativeCalls.vehicle = 0
        Rec.Sample(os.time())
        assert_eq(nativeCalls.vehicle, 1, 'only the watched patient is sampled')
        Mock.vehicleOf[1] = 500
        local before = #Mock.clientEventsNamed('pf-ambulancejob:client:Effects')
        Rec.Sample(os.time())
        Rec.Sample(os.time())
        Store.Flush()
        local anomalies = 0
        for _, e in ipairs(DB.events) do if e.action == 'anomaly' and e.detail:find('no_drive_violation', 1, true) then anomalies = anomalies + 1 end end
        assert_eq(anomalies, 1, 'rate limited')
        assert_eq(Rec.stats.violations, 1)
        assert_eq(#Mock.clientEventsNamed('pf-ambulancejob:client:Effects'), before + 1, 'profile sent again')
        Mock.clock = Mock.clock + 60
        Rec.Sample(os.time())
        assert_eq(Rec.stats.violations, 2)
        assert_eq(#openRows('CID1'), 1, 'logged, not punished')
    end)

    it('a passenger (not in seat -1) is not a violation; the injury-derived no_drive is watched too', function()
        online(1)
        add(CONCUSSION)
        Fx.Push(1, { force = true })
        assert_true(Rec.IsWatched('CID1') == nil or not Rec.IsWatched('CID1').noDrive, 'concussion sev 1 alone allows driving')
        Rec.AddRestriction('CID1', { kind = 'concussion' })
        assert_true(Rec.IsWatched('CID1').noDrive, 'concussion restriction keeps drive at 2')
        local seat = GetPedInVehicleSeat
        GetPedInVehicleSeat = function() return 0 end
        Mock.vehicleOf[1] = 500
        Rec.Sample(os.time())
        GetPedInVehicleSeat = seat
        assert_eq(Rec.stats.violations, 0)
    end)
end)

-- ── export ─────────────────────────────────────────────────────────────────────────────────────

describe('GetRestrictions export', function()
    it('is open to every resource; reasons only for medical callers; offline citizens read from the table', function()
        online(1)
        Rec.AddRestriction('CID1', { kind = 'no_drive', seconds = 3600, reason = 'Concussion follow-up' })
        local res = as('pf-policemdt-DEV', function() return exports['pf-ambulancejob']:GetRestrictions(1) end)
        assert_true(res.ok)
        assert_eq(res.list[1].kind, 'no_drive')
        assert_eq(res.list[1]['until'], os.time() + 3600)
        assert_eq(res.list[1].reason, 'injury', 'generic for police')
        res = as('pf-emsmdt', function() return exports['pf-ambulancejob']:GetRestrictions('CID1') end)
        assert_eq(res.list[1].reason, 'Concussion follow-up')
        Rec.AddRestriction('CID7', { kind = 'crutches', seconds = 600, reason = 'Leg' })
        res = as('pfm-prison', function() return exports['pf-ambulancejob']:GetRestrictions('CID7') end)
        assert_true(res.ok)
        assert_eq(#res.list, 1)
        assert_eq(res.list[1].kind, 'crutches')
        assert_eq(res.list[1].reason, 'injury')
        assert_eq(as('x', function() return exports['pf-ambulancejob']:GetRestrictions('bad id!') end).error, 'bad_args')
        assert_eq(as('x', function() return exports['pf-ambulancejob']:GetRestrictions(77) end).error, 'not_found')
    end)

    it('derived restrictions of an online patient are listed too', function()
        online(1)
        add({ mechanism = 'fall', type = 'fracture', subtype = 'closed', structure = 'femur_l', severity = 4 })
        local res = as('pfm-prison', function() return exports['pf-ambulancejob']:GetRestrictions(1) end)
        local kinds = {}
        for _, r in ipairs(res.list) do kinds[r.kind] = true end
        assert_true(kinds.bed_rest and kinds.no_sprint, 'from the profile')
    end)
end)
