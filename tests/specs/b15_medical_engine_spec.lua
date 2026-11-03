-- pf-ambulancejob medical engine (batch 15A) with an in-memory stand-in for its SQL layer:
-- the store's lifecycle (load on PlayerLoaded with offline catch-up, write-behind, flush on drop and
-- stop, character delete), the tick that touches only active patients, injuries with idempotency
-- keys, toxins, the consciousness machine and its events, the export allowlists and per-caller
-- summary fields, the consumption listener and the diagnosis layers kept apart from the injuries.
load_resource('tests/lua/fivem_mocks.lua')
function IsDuplicityVersion() return true end
function GetCurrentResourceName() return 'pf-ambulancejob' end
function GetResourceState() return 'started' end

load_resource('[pfscripts]/pf-ambulancejob/config.lua')
load_resource('[pfscripts]/pf-ambulancejob/config_medical.lua')
load_resource('[pfscripts]/pf-ambulancejob/shared/framework.lua')
for _, f in ipairs({ 'anatomy', 'injuries', 'physiology_model', 'effects_model' }) do
    load_resource('[pfscripts]/pf-ambulancejob/shared/medical/' .. f .. '.lua')
end

-- ── in-memory SQL layer (the real statements run in b15_medical_store_realdb_spec) ────────────
local DB
local function copy(t)
    if type(t) ~= 'table' then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = copy(v) end
    return o
end
local function installFakeSQL()
    DB = { patients = {}, injuries = {}, events = {}, findings = {}, diagnoses = {}, nextId = 0, calls = {}, deleted = {} }
    local Q = PFMed.SQL
    local function call(name) DB.calls[name] = (DB.calls[name] or 0) + 1 end
    Q.LoadPatient = function(cid) call('LoadPatient') return copy(DB.patients[cid]) end
    Q.LoadOpenInjuries = function(cid, limit)
        call('LoadOpenInjuries')
        local out = {}
        for _, r in pairs(DB.injuries) do if r.citizenid == cid and r.stage ~= 'recovered' then out[#out + 1] = copy(r) end end
        table.sort(out, function(a, b) return a.id < b.id end)
        while #out > limit do table.remove(out) end
        return out
    end
    Q.FindInjuryByKey = function(key)
        call('FindInjuryByKey')
        for _, r in pairs(DB.injuries) do if r.idem_key == key then return { id = r.id, citizenid = r.citizenid, attrs = r.attrs } end end
    end
    Q.InjuryOwner = function(id) return DB.injuries[id] and DB.injuries[id].citizenid end
    Q.InsertInjury = function(r)
        call('InsertInjury')
        if r.idem_key then for _, x in pairs(DB.injuries) do if x.idem_key == r.idem_key then error("Duplicate entry for key 'uq_med_inj_key'") end end end
        DB.nextId = DB.nextId + 1
        local row = copy(r)
        row.id = DB.nextId
        DB.injuries[row.id] = row
        return row.id
    end
    Q.UpsertPatients = function(rows)
        call('UpsertPatients')
        DB.lastPatientBatch = #rows
        for _, r in ipairs(rows) do DB.patients[r.citizenid] = copy(r) end
        return true
    end
    Q.UpsertInjuries = function(rows)
        call('UpsertInjuries')
        for _, r in ipairs(rows) do
            local old = DB.injuries[r.id] or {}
            for k, v in pairs(r) do old[k] = v end
            DB.injuries[r.id] = old
        end
        return true
    end
    Q.InsertEvents = function(rows) call('InsertEvents') for _, e in ipairs(rows) do DB.events[#DB.events + 1] = copy(e) end return true end
    Q.DeleteCharacter = function(cid)
        call('DeleteCharacter')
        DB.deleted[#DB.deleted + 1] = cid
        DB.patients[cid] = nil
        for id, r in pairs(DB.injuries) do if r.citizenid == cid then DB.injuries[id] = nil end end
        return { patients = 1 }
    end
    Q.InsertFinding = function(r) DB.findings[#DB.findings + 1] = copy(r) return #DB.findings end
    Q.ListFindings = function(cid) local o = {} for _, f in ipairs(DB.findings) do if f.citizenid == cid then o[#o + 1] = f end end return o end
    Q.InsertDiagnosis = function(r) DB.diagnoses[#DB.diagnoses + 1] = copy(r) return #DB.diagnoses end
    Q.ListDiagnoses = function(cid) local o = {} for _, d in ipairs(DB.diagnoses) do if d.citizenid == cid then o[#o + 1] = d end end return o end
end

Mock.exportsByResource['pfm-core'].RunMigrations = function() return true end

-- (re)loads the server modules: every test starts with an empty cache and active set
local function fresh()
    for _, f in ipairs({ 'schema', 'store', 'engine', 'effects', 'api' }) do
        load_resource('[pfscripts]/pf-ambulancejob/server/medical/' .. f .. '.lua')
    end
    installFakeSQL()
    assert(PFMed.Schema.Start(), 'schema ready')
    PFMed.Engine.Random = function() return 0.5 end
    Mock.exportsByResource['pf-ambulancejob'] = Mock.exportsByResource['__self']
end

local Store, Engine
local function online(src, cid)
    local p = Mock.newPlayer(src, cid)
    Mock.fireEvent('QBCore:Server:PlayerLoaded', nil, p)
    return p
end
local function patient(cid) return Store.Peek(cid or 'CID1') end
local function tick(seconds, step)
    step = step or 5
    local n = 0
    for _ = 1, math.floor(seconds / step) do
        Mock.clock = Mock.clock + step
        n = n + Engine.Tick(os.time())
    end
    return n
end
local function as(resource, fn)
    Mock.invokingResource = resource
    local ok, a, b = pcall(fn)
    Mock.invokingResource = nil
    if not ok then error(a, 2) end
    return a, b
end
local function aj() return exports['pf-ambulancejob'] end
local function eventsNamed(name)
    local out = {}
    for _, e in ipairs(Mock.serverEvents) do if e.name == name then out[#out + 1] = e end end
    return out
end
local ARTERIAL = { mechanism = 'edged', type = 'laceration', subtype = 'arterial', structure = 'femoral_l', severity = 4 }

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords, Mock.aces = {}, {}, {}
    Mock.invokingResource = nil
    Mock.clock = 1700000000
    fresh()
    Store, Engine = PFMed.Store, PFMed.Engine
end

-- ── store lifecycle ───────────────────────────────────────────────────────────────────────────

describe('store lifecycle', function()
    it('loads a character on PlayerLoaded; a healthy one is not ticked and not written', function()
        online(1)
        assert_true(patient() ~= nil)
        assert_eq(DB.calls.LoadPatient, 1)
        assert_false(Engine.IsActive('CID1'))
        Store.WriteBehind()
        assert_eq(DB.calls.UpsertPatients, nil, 'nothing changed, nothing written')
    end)

    it('the tick touches only active patients: healthy players cost no store reads', function()
        for src = 1, 40 do online(src) end
        Store.stats.peeks = 0
        assert_eq(tick(30), 0)
        assert_eq(Store.stats.peeks, 0, 'no reads for 40 healthy players')
        assert_true(Engine.AddInjury('CID7', ARTERIAL, { key = 'k1' }))
        Store.stats.peeks = 0
        assert_eq(tick(5), 1)
        assert_eq(Store.stats.peeks, 1, 'one read for the one active patient')
    end)

    it('write-behind writes all dirty patients in one statement, then nothing until the next change', function()
        online(1); online(2)
        Engine.AddInjury('CID1', ARTERIAL, { key = 'a' })
        Engine.AddToxin('CID2', 'ethanol', 0.05)
        tick(10)
        assert_eq(DB.calls.UpsertPatients, nil, 'nothing written before the write-behind pass')
        Store.WriteBehind()
        assert_eq(DB.calls.UpsertPatients, 1)
        assert_eq(DB.lastPatientBatch, 2)
        assert_eq(DB.calls.UpsertInjuries, 1)
        assert_true(#DB.events >= 2, 'audit rows written with the flush')
        assert_true(DB.patients.CID1.blood_ml < 5000)
        assert_eq(DB.patients.CID2.toxins, json.encode({ ethanol = 0.05 }))
    end)

    it('a change made while a write is in flight is kept for the next pass; a failed write is retried', function()
        online(1)
        local inj = Engine.AddInjury('CID1', { mechanism = 'edged', type = 'laceration', subtype = 'deep', region = 'forearm_l', severity = 2 }, {})
        local real = PFMed.SQL.UpsertPatients
        PFMed.SQL.UpsertPatients = function(rows)
            -- the database wait: the treatment engine changes the wound meanwhile
            Engine.UpdateInjury('CID1', inj.id, { treatments = { pressure = true } })
            return real(rows)
        end
        assert_true(Store.Flush())
        PFMed.SQL.UpsertPatients = real
        assert_true(Store.IsDirty('CID1'), 'still dirty after the in-flight change')
        assert_true(Store.Flush())
        assert_true(DB.injuries[inj.id].treatments:find('pressure', 1, true) ~= nil)
        Engine.AddToxin('CID1', 'ethanol', 0.05)
        PFMed.SQL.UpsertPatients = function() error('connection lost') end
        assert_false(Store.Flush())
        PFMed.SQL.UpsertPatients = real
        assert_true(Store.IsDirty('CID1'))
        assert_true(Store.Flush())
        assert_eq(DB.patients.CID1.toxins, json.encode({ ethanol = 0.05 }))
    end)

    it('playerDropped and logout write the patient at once and free the memory', function()
        online(1); online(2)
        Engine.AddToxin('CID1', 'ethanol', 0.1)
        Engine.AddToxin('CID2', 'ethanol', 0.1)
        Mock.fireEvent('playerDropped', 1)
        assert_eq(patient('CID1'), nil)
        assert_true(DB.patients.CID1 ~= nil)
        assert_eq(Store.CidOf(1), nil)
        assert_false(Engine.IsActive('CID1'))
        Mock.fireEvent('QBCore:Server:OnPlayerUnload', nil, 2)
        assert_eq(patient('CID2'), nil)
        assert_true(DB.patients.CID2 ~= nil)
    end)

    it('resource stop flushes every dirty patient', function()
        online(1)
        Engine.AddToxin('CID1', 'ethanol', 0.1)
        Mock.fireEvent('onResourceStop', nil, 'other-resource')
        assert_eq(DB.calls.UpsertPatients, nil)
        Mock.fireEvent('onResourceStop', nil, 'pf-ambulancejob')
        assert_eq(DB.calls.UpsertPatients, 1)
    end)

    it('offline catch-up on load uses the absolute timestamps', function()
        local t = Mock.clock
        DB.patients.CID1 = { citizenid = 'CID1', consciousness = 'alert', stage = 'healthy', blood_ml = 4000, hgb_factor = 1, airway = 'clear',
            breathing = 1, pain = 0, temp_c = 37, toxins = json.encode({ ethanol = 0.1 }), last_tick_at = t - 3600, updated_at = t - 3600 }
        DB.patients.CID2 = { citizenid = 'CID2', consciousness = 'arrest', stage = 'injured', blood_ml = 2400, hgb_factor = 1, airway = 'clear',
            breathing = 1, pain = 0, temp_c = 37, arrest_since = t - 400, down_since = t - 500, last_tick_at = t - 400, updated_at = t - 400 }
        online(1); online(2)
        local p1 = patient('CID1')
        assert_near(p1.toxins.ethanol, 0.085, 0.0001)
        assert_near(p1.blood_ml, 4030, 0.5)
        assert_eq(patient('CID2').consciousness, 'dead', 'arrest ran out while offline')
        assert_true(patient('CID2').can_respawn_at > t)
    end)

    it('a deleted character loses every medical row; a player cannot raise the event', function()
        online(1)
        Engine.AddInjury('CID1', ARTERIAL, { key = 'del' })
        Mock.fireEvent('pfm-core:server:characterDeleted', 5, 'CID1')
        assert_eq(DB.calls.DeleteCharacter, nil)
        Mock.fireEvent('pfm-core:server:characterDeleted', nil, 'CID1')
        assert_eq(DB.deleted[1], 'CID1')
        assert_eq(patient('CID1'), nil)
        Store.WriteBehind()
        assert_eq(DB.patients.CID1, nil, 'nothing written back after the delete')
    end)

    it('loads players already online when the resource restarts', function()
        Mock.newPlayer(1); Mock.newPlayer(2)
        assert_eq(Store.LoadOnline(), 2)
        assert_eq(Store.CidOf(2), 'CID2')
    end)
end)

-- ── engine ────────────────────────────────────────────────────────────────────────────────────

describe('engine', function()
    it('an arterial bleed lowers blood, changes consciousness and raises the events', function()
        online(1)
        local seen = {}
        Engine.OnConsciousness(function(cid, from, to, cause) seen[#seen + 1] = { cid, from, to, cause } end)
        local inj = Engine.AddInjury('CID1', ARTERIAL, { key = 'bleed-1' })
        assert_true(inj.attrs.arterial and inj.attrs.noclot)
        assert_eq(inj.region, 'thigh_l', 'region from the structure')
        local added = eventsNamed('pf-ambulancejob:server:injuryAdded')
        assert_eq(#added, 1)
        assert_eq(added[1].args[1], 'CID1')
        assert_eq(added[1].args[2].attrs._fp, nil, 'no internals in the event')
        tick(600)
        local p = patient()
        assert_true(p.blood_ml < 3000)
        assert_true(#seen >= 2, 'consciousness changed')
        local changes = eventsNamed('pf-ambulancejob:server:consciousnessChanged')
        assert_eq(#changes, #seen)
        assert_eq(changes[1].args[1], 1, 'src first')
        assert_eq(changes[1].args[2], 'CID1')
        assert_eq(changes[1].args[3], 'alert')
        assert_true(p.consciousness == 'arrest' or p.consciousness == 'dead')
        local down, level = Engine.IsDown('CID1')
        assert_true(down); assert_eq(level, p.consciousness)
    end)

    it('CPR ticks pause the arrest-to-death timer; without them the patient dies', function()
        online(1)
        Engine.AddInjury('CID1', ARTERIAL, { key = 'cpr' })
        local p = patient()
        for _ = 1, 200 do
            if p.consciousness == 'arrest' then break end
            tick(5)
        end
        assert_eq(p.consciousness, 'arrest')
        for _ = 1, 80 do -- 400 s of CPR
            p.cpr_last_at = os.time()
            tick(5)
        end
        assert_eq(p.consciousness, 'arrest', 'still in arrest after 400 s with CPR')
        tick(305)
        assert_eq(p.consciousness, 'dead')
        assert_false(Engine.IsActive('CID1'), 'the dead are not ticked')
    end)

    it('a controlled wound and no toxins leave the active set', function()
        online(1)
        local inj = Engine.AddInjury('CID1', { mechanism = 'edged', type = 'laceration', subtype = 'deep', region = 'forearm_l', severity = 2 }, { key = 'cut' })
        assert_true(Engine.IsActive('CID1'))
        local ok = Engine.UpdateInjury('CID1', inj.id, { treatments = { pressure = true } })
        assert_true(ok)
        tick(5)
        Engine.UpdateInjury('CID1', inj.id, { stage = 'stabilized' })
        Engine.UpdateInjury('CID1', inj.id, { stage = 'treated' })
        tick(5)
        assert_false(Engine.IsActive('CID1'))
        local _, code = Engine.UpdateInjury('CID1', inj.id, { stage = 'injured' })
        assert_eq(code, 'invalid_state')
        assert_eq(patient().stage, 'treated')
    end)

    it('opioid overdose makes the patient unconscious at once', function()
        online(1)
        Engine.AddToxin('CID1', 'opioid', 150)
        assert_eq(patient().consciousness, 'unconscious')
        assert_true((Engine.IsDown('CID1')))
        local _, code = Engine.AddToxin('CID1', 'opioid', 9999)
        assert_eq(code, 'bad_args')
        _, code = Engine.AddToxin('CID1', 'dragon_venom', 1)
        assert_eq(code, 'bad_args')
    end)

    it('forced transitions follow the table (report down, no auto death from alert)', function()
        online(1)
        assert_true(Engine.SetConsciousness('CID1', 'unconscious', 'report', 'gta_health', { holdSeconds = 30 }))
        tick(20)
        assert_eq(patient().consciousness, 'unconscious', 'held')
        local _, code = Engine.SetConsciousness('CID1', 'dead', 'report')
        assert_eq(code, 'invalid_state')
        tick(60)
        assert_eq(patient().consciousness, 'alert', 'wakes up after the hold with a normal GCS')
        local path = {}
        for _, e in ipairs(eventsNamed('pf-ambulancejob:server:consciousnessChanged')) do path[#path + 1] = e.args[4] end
        assert_eq(table.concat(path, ','), 'unconscious,altered,alert', 'one level at a time')
    end)

    it('idempotency keys: a repeat returns the first injury, other arguments are refused', function()
        online(1)
        local a = Engine.AddInjury('CID1', ARTERIAL, { key = 'same' })
        local b, _, dup = Engine.AddInjury('CID1', ARTERIAL, { key = 'same' })
        assert_eq(b.id, a.id); assert_true(dup)
        local spec = { mechanism = 'blunt', type = 'bruising', region = 'chest_l', severity = 1 }
        local _, code = Engine.AddInjury('CID1', spec, { key = 'same' })
        assert_eq(code, 'key_reused')
        assert_eq(DB.calls.InsertInjury, 1)
        local _, bad = Engine.AddInjury('CID1', ARTERIAL, { key = 'has spaces' })
        assert_eq(bad, 'bad_args')
    end)

    it('validates specs against the catalogue and anatomy', function()
        online(1)
        local cases = {
            { { mechanism = 'firearm', type = 'dragon', severity = 2, region = 'head' }, 'unknown injury type' },
            { { mechanism = 'magic', type = 'bruising', severity = 2, region = 'head' }, 'unknown mechanism' },
            { { mechanism = 'blunt', type = 'bruising', severity = 6, region = 'head' }, 'severity must be 1..5' },
            { { mechanism = 'blunt', type = 'fracture', severity = 2, structure = 'liver' }, 'this injury type cannot affect that structure' },
            { { mechanism = 'blunt', type = 'fracture', severity = 2, region = 'head', structure = 'femur_l' }, 'structure is not in that region' },
            { { mechanism = 'blunt', type = 'fracture', severity = 2 }, 'region or structure needed' },
        }
        for _, c in ipairs(cases) do
            local _, code, msg = Engine.AddInjury('CID1', c[1], {})
            assert_eq(code, 'bad_args'); assert_eq(msg, c[2])
        end
        local f = Engine.AddInjury('CID1', { mechanism = 'fall', type = 'fracture', severity = 3, region = 'lower_leg_l' }, {})
        assert_true(f.structure == 'tibia_l' or f.structure == 'fibula_l', 'a bone of the region')
        local d = Engine.AddInjury('CID1', { mechanism = 'blunt', type = 'dislocation', severity = 2, structure = 'knee_r' }, {})
        assert_eq(d.subtype, 'knee')
        local tox = Engine.AddInjury('CID1', { mechanism = 'poisoning', type = 'poisoning', subtype = 'opioid', severity = 2 }, {})
        assert_eq(tox.region, nil, 'systemic')
    end)

    it('merges into a matching injury when the open-injury cap is reached', function()
        online(1)
        Config.Medical.MaxOpenInjuries = 2
        Engine.AddInjury('CID1', { mechanism = 'blunt', type = 'bruising', region = 'chest_l', severity = 1 }, {})
        Engine.AddInjury('CID1', { mechanism = 'blunt', type = 'bruising', region = 'thigh_l', severity = 1 }, {})
        local m = Engine.AddInjury('CID1', { mechanism = 'blunt', type = 'bruising', region = 'chest_l', severity = 2 }, {})
        local _, code = Engine.AddInjury('CID1', { mechanism = 'blunt', type = 'bruising', region = 'head', severity = 2 }, {})
        Config.Medical.MaxOpenInjuries = 40
        assert_eq(m.severity, 3)
        assert_eq(code, 'conflict')
        assert_eq(DB.calls.InsertInjury, 2)
    end)
end)

-- ── exports ───────────────────────────────────────────────────────────────────────────────────

describe('exports', function()
    it('refuse resources that are not on Config.Medical.Callers', function()
        online(1)
        as('random-resource', function()
            assert_eq(aj():GetPatientSummary(1).error, 'not_allowed')
            assert_eq(aj():ApplyInjury(1, ARTERIAL, { key = 'x' }).error, 'not_allowed')
            assert_eq(aj():AddToxin(1, 'ethanol', 0.05).error, 'not_allowed')
            local down, level = aj():IsDown(1)
            assert_false(down); assert_eq(level, 'alert', 'IsDown is open')
        end)
        assert_eq(DB.calls.InsertInjury, nil)
    end)

    it('GetPatientSummary gives police only the non-medical fields, the EMS MDT everything', function()
        online(1)
        Engine.AddInjury('CID1', { mechanism = 'fall', type = 'fracture', subtype = 'closed', structure = 'femur_l', severity = 3 }, {})
        local police = as('pf-policemdt-DEV', function() return aj():GetPatientSummary(1) end)
        assert_true(police.ok)
        assert_eq(police.cid, 'CID1'); assert_true(police.online)
        assert_eq(police.consciousness, 'alert'); assert_eq(police.down, false); assert_eq(police.stage, 'injured')
        assert_true(#police.restrictions > 0)
        assert_eq(police.vitals, nil); assert_eq(police.bleeding, nil); assert_eq(police.updatedAt, nil)
        local ems = as('pf-emsmdt', function() return aj():GetPatientSummary('CID1') end)
        assert_true(ems.vitals ~= nil and ems.vitals.hr > 75, 'pain raises the heart rate')
        assert_eq(ems.bleeding, 0, 'a closed fracture bleeds inside: no visible bleeding')
        local prison = as('pfm-prison', function() return aj():GetPatientSummary(1) end)
        assert_eq(prison.vitals, nil)
        patient().triage = 'red'
        assert_eq(as('pf-justice', function() return aj():GetPatientSummary(1) end).triage, 'red', 'booking screening reads the triage')
        assert_eq(as('pf-justice', function() return aj():GetPatientSummary(1) end).vitals, nil)
        assert_eq(as('pf-policemdt-DEV', function() return aj():GetPatientSummary(1) end).triage, nil)
    end)

    it('GetPatientSummary reads an offline citizen from the database', function()
        DB.patients.CID9 = { citizenid = 'CID9', consciousness = 'dead', stage = 'injured', blood_ml = 2000, hgb_factor = 1, airway = 'clear',
            breathing = 1, pain = 0, temp_c = 37, last_tick_at = os.time(), updated_at = os.time() }
        local r = as('pf-justice', function() return aj():GetPatientSummary('CID9') end)
        assert_true(r.ok); assert_false(r.online); assert_true(r.down); assert_eq(r.consciousness, 'dead')
        local bad = as('pf-justice', function() return aj():GetPatientSummary({}) end)
        assert_eq(bad.error, 'bad_args')
        assert_eq(as('pf-justice', function() return aj():GetPatientSummary(77) end).error, 'not_found')
        assert_eq(as('pfm-prison', function() return aj():ApplyInjury(77, ARTERIAL, { key = 'k77' }) end).error, 'offline')
    end)

    it('ApplyInjury: key required, server-read actor, admin ACE, patient online', function()
        online(1); Mock.newPlayer(2).PlayerData.job = { name = 'police' }
        as('pfm-prison', function()
            assert_eq(aj():ApplyInjury(1, ARTERIAL, {}).error, 'bad_args')
            local r = aj():ApplyInjury(1, { mechanism = 'blunt', type = 'bruising', region = 'abdomen', severity = 1 },
                { key = 'pfm-prison:fight:1', actor = { kind = 'system', label = 'yard fight' } })
            assert_true(r.ok); assert_true(r.injuryId ~= nil)
            local again = aj():ApplyInjury(1, { mechanism = 'blunt', type = 'bruising', region = 'abdomen', severity = 1 }, { key = 'pfm-prison:fight:1' })
            assert_true(again.duplicate); assert_eq(again.injuryId, r.injuryId)
            assert_eq(aj():ApplyInjury('NOBODY1', ARTERIAL, { key = 'off' }).error, 'offline')
            assert_eq(aj():ApplyInjury(1, { type = 'bruising' }, { key = 'bad' }).error, 'bad_args')
        end)
        as('pfm-adminmenu', function()
            assert_eq(aj():ApplyInjury(1, ARTERIAL, { key = 'adm', actor = { kind = 'admin', src = 2 } }).error, 'no_permission')
            Mock.aces[2] = { admin = true }
            assert_true(aj():ApplyInjury(1, ARTERIAL, { key = 'adm', actor = { kind = 'admin', src = 2 } }).ok)
        end)
        Store.WriteBehind()
        local admin
        for _, e in ipairs(DB.events) do if e.action == 'injury' and e.actor_src == 2 then admin = e end end
        assert_true(admin ~= nil, 'audited with the actor read from the server')
        assert_eq(admin.actor_cid, 'CID2'); assert_eq(admin.actor_job, 'police')
    end)

    it('AddToxin: allowlisted, key dedupe, online only', function()
        online(1)
        as('pfm-drugs', function()
            assert_true(aj():AddToxin(1, 'opioid', 20, { key = 'dose-1' }).ok)
            assert_true(aj():AddToxin(1, 'opioid', 20, { key = 'dose-1' }).duplicate)
            assert_eq(aj():AddToxin(1, 'opioid', 30, { key = 'dose-1' }).error, 'key_reused')
            assert_eq(aj():AddToxin(1, 'opioid', -5).error, 'bad_args')
            assert_eq(aj():AddToxin('OFFLINE1', 'opioid', 5).error, 'offline')
        end)
        assert_eq(patient().toxins.opioid, 20)
    end)
end)

-- ── consumables (pfm-smallresources:server:consumed, 15H) ─────────────────────────────────────

describe('consumption listener', function()
    it('alcohol adds ethanol, poisoned food adds food poisoning, a clean meal nothing', function()
        online(1)
        Mock.fireEvent('pfm-smallresources:server:consumed', nil, 1, 'beer', 'alcohol', {})
        Mock.fireEvent('pfm-smallresources:server:consumed', nil, 1, 'beer', 'alcohol', {})
        assert_near(patient().toxins.ethanol, 0.04, 0.0001)
        Mock.fireEvent('pfm-smallresources:server:consumed', nil, 1, 'sandwich', 'food', { quality = 80 })
        assert_eq(patient().toxins.food_poisoning, nil)
        Mock.fireEvent('pfm-smallresources:server:consumed', nil, 1, 'burger', 'food', { poisoned = true })
        assert_eq(patient().toxins.food_poisoning, Config.Medical.Consumables.FoodPoisoningDose)
        assert_true(Engine.IsActive('CID1'))
    end)
    it('ignores a player source and junk arguments', function()
        online(1)
        Mock.fireEvent('pfm-smallresources:server:consumed', 1, 1, 'vodka', 'alcohol', {})
        Mock.fireEvent('pfm-smallresources:server:consumed', nil, 'x', 'vodka', 'alcohol', {})
        Mock.fireEvent('pfm-smallresources:server:consumed', nil, 1, string.rep('a', 80), 'alcohol', {})
        assert_eq(patient().toxins.ethanol, nil)
    end)
end)

-- ── diagnosis layers ──────────────────────────────────────────────────────────────────────────

describe('diagnosis layers', function()
    it('are stored apart from the true injuries and may be wrong', function()
        online(1); online(2)
        local real = Engine.AddInjury('CID1', { mechanism = 'fall', type = 'fracture', subtype = 'closed', structure = 'femur_l', severity = 3 }, {})
        local other = Engine.AddInjury('CID2', ARTERIAL, {})
        -- a wrong suspicion: no injury behind it, nothing changes in the injuries
        assert_true(Store.SetDiagnosis('CID1', { injuryType = 'fracture', structure = 'pelvis', status = 'suspected', source = 'provider', byCid = 'CID2' }))
        assert_eq(patient().injuries[real.id].structure, 'femur_l')
        local _, code = Store.SetDiagnosis('CID1', { injuryId = real.id, injuryType = 'fracture', status = 'confirmed', source = 'provider' })
        assert_eq(code, 'invalid_state', 'only imaging, labs or surgery confirm')
        assert_true(Store.SetDiagnosis('CID1', { injuryId = real.id, injuryType = 'fracture', structure = 'femur_l', status = 'confirmed', source = 'imaging' }))
        assert_true(Store.AddFinding('CID1', { injuryId = real.id, modality = 'palpate', region = 'thigh_l', sign = 'crepitus', certainty = 'observed', byTier = 1 }))
        local _, nf = Store.AddFinding('CID1', { injuryId = other.id, modality = 'look', sign = 'open_wound', certainty = 'observed' })
        assert_eq(nf, 'not_found', "a finding never points at someone else's injury")
        local _, bad = Store.AddFinding('CID1', { modality = 'telepathy', sign = 'x', certainty = 'observed' })
        assert_eq(bad, 'bad_args')
        assert_eq(#Store.ListDiagnoses('CID1'), 2)
        assert_eq(#Store.ListFindings('CID1'), 1)
        local summary = PFMed.Api.Summary(patient(), os.time())
        assert_eq(summary.injuries, nil, 'the summary carries no injury rows')
    end)
end)
