-- pf-ambulancejob batch 17A: diagnoses, the chart and the medical record. setDiagnosis (tier >= 2,
-- suspected / ruled_out only, no probing for hidden injuries, a confirmed diagnosis cannot be ruled
-- out by examination); getChart (privacy 6.6: attending, recent care, admitted, physician; never the
-- injury rows; every read audited); GetMedicalRecord (caller allowlist, purposes self / treatment /
-- court_order, confirmed diagnoses only, every read and denial audited); HasFinding / HasDiagnosis.
load_resource('tests/lua/fivem_mocks.lua')
function IsDuplicityVersion() return true end
function GetCurrentResourceName() return 'pf-ambulancejob' end
function GetResourceState() return 'started' end

function AddEventHandler(name, fn)
    local prev = Mock.eventHandlers[name]
    if prev then Mock.eventHandlers[name] = function(...) prev(...) fn(...) end else Mock.eventHandlers[name] = fn end
end
function GetAllVehicles() return {} end
Items, Admissions, CourtOrders = {}, {}, {}
Mock.exportsByResource['pfm-inventory'] = { HasItem = function(_, src, name) return (Items[src] or {})[name] == true end }
Mock.exportsByResource['pfm-core'].RunMigrations = function() return true end

local AJ = '[pfscripts]/pf-ambulancejob/'
DB = nil
local function copy(t)
    if type(t) ~= 'table' then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = copy(v) end
    return o
end
local function installFakeSQL()
    DB = { patients = {}, injuries = {}, events = {}, findings = {}, diagnoses = {}, treatments = {}, nextId = 0 }
    local Q = PFMed.SQL
    Q.LoadPatient = function(cid) return copy(DB.patients[cid]) end
    Q.LoadOpenInjuries = function(cid)
        local out = {}
        for _, r in pairs(DB.injuries) do if r.citizenid == cid and r.stage ~= 'recovered' then out[#out + 1] = copy(r) end end
        return out
    end
    Q.FindInjuryByKey = function() return nil end
    Q.InjuryOwner = function(id) return DB.injuries[id] and DB.injuries[id].citizenid end
    Q.InsertInjury = function(r) DB.nextId = DB.nextId + 1; local row = copy(r); row.id = DB.nextId; DB.injuries[row.id] = row; return row.id end
    Q.UpsertPatients = function(rows) for _, r in ipairs(rows) do DB.patients[r.citizenid] = copy(r) end return true end
    Q.UpsertInjuries = function(rows) for _, r in ipairs(rows) do local o = DB.injuries[r.id] or {}; for k, v in pairs(r) do o[k] = v end; DB.injuries[r.id] = o end return true end
    Q.InsertEvents = function(rows) for _, e in ipairs(rows) do DB.events[#DB.events + 1] = copy(e) end return true end
    Q.Sweep = function() return {} end
    Q.InsertFinding = function(r) local row = copy(r); row.id = #DB.findings + 1; DB.findings[row.id] = row; return row.id end
    Q.ListFindings = function(cid, since, limit)
        local o = {}
        for i = #DB.findings, 1, -1 do local f = DB.findings[i]; if f.citizenid == cid and f.at >= since and #o < limit then o[#o + 1] = copy(f) end end
        return o
    end
    Q.InsertDiagnosis = function(r) local row = copy(r); row.id = #DB.diagnoses + 1; DB.diagnoses[row.id] = row; return row.id end
    Q.ListDiagnoses = function(cid, status, limit)
        local o = {}
        for i = #DB.diagnoses, 1, -1 do local d = DB.diagnoses[i]; if d.citizenid == cid and (not status or d.status == status) and #o < limit then o[#o + 1] = copy(d) end end
        return o
    end
    Q.DxCareFinding = function(cid, by, since) for _, f in ipairs(DB.findings) do if f.citizenid == cid and f.by_cid == by and f.at >= since then return 1 end end return nil end
    Q.DxCareTreatment = function(cid, by, since) for _, t in ipairs(DB.treatments) do if t.citizenid == cid and t.by_cid == by and t.at >= since then return 1 end end return nil end
    Q.DxFindingForInjury = function(cid, id) for _, f in ipairs(DB.findings) do if f.citizenid == cid and f.injury_id == id then return 1 end end return nil end
    Q.DxVitals = function(cid, since, limit)
        local o = {}
        local vm = { pulse = true, bp_cuff = true, spo2_probe = true, temperature = true, glucose = true, pain_scale = true, ecg = true }
        for i = #DB.findings, 1, -1 do local f = DB.findings[i]; if f.citizenid == cid and f.at >= since and vm[f.modality] and #o < limit then o[#o + 1] = copy(f) end end
        return o
    end
    Q.DxTreatments = function(cid) local o = {} for _, t in ipairs(DB.treatments) do if t.citizenid == cid then o[#o + 1] = copy(t) end end return o end
    -- the record's documented-injury query (its real SQL runs in the real-DB spec)
    Q.DxRecordInjuries = function(cid)
        local o = {}
        for id, r in pairs(DB.injuries) do
            local documented = false
            for _, f in ipairs(DB.findings) do if f.injury_id == id then documented = true end end
            for _, d in ipairs(DB.diagnoses) do if d.injury_id == id and d.status == 'confirmed' then documented = true end end
            if r.citizenid == cid and documented then o[#o + 1] = copy(r) end
        end
        return o
    end
    Q.DxRecordTreatments = Q.DxTreatments
    Q.DxRecordAdmissions = function() return { { id = 7, hospital_id = 'pillbox', state = 'discharged', arrived_at = 1 } } end
end

local Exam, Dx, Store, Engine
local function boot()
    Mock.eventHandlers, Mock.netHandlers, Mock.callbacks = {}, {}, {}
    Mock.exportsByResource['__self'] = {}
    PFMed, PFAmbulance, Config = nil, nil, nil
    load_resource(AJ .. 'config.lua')
    load_resource(AJ .. 'config_medical.lua')
    load_resource(AJ .. 'shared/framework.lua')
    for _, f in ipairs({ 'anatomy', 'injuries', 'physiology_model', 'effects_model', 'findings' }) do load_resource(AJ .. 'shared/medical/' .. f .. '.lua') end
    for _, f in ipairs({ 'schema', 'store', 'engine', 'effects', 'api', 'diagnosis', 'exam' }) do load_resource(AJ .. 'server/medical/' .. f .. '.lua') end
    installFakeSQL()
    Mock.exportsByResource['__self'].GetAdmission = function(_, cid)
        local a = Admissions[cid]
        return a and { ok = true, admission = a } or { ok = true }
    end
    Mock.exportsByResource['pf-ambulancejob'] = Mock.exportsByResource['__self']
    assert(PFMed.Schema.Start(), 'schema ready')
    Exam, Dx, Store, Engine = PFMed.Exam, PFMed.Diagnosis, PFMed.Store, PFMed.Engine
    Engine.Random = function() return 0.5 end
    Exam.WaitFor = function() end
    Dx.Random = function() return 0 end
end

local PATIENT, MEDIC, EMR, DOC, CIV, FAR = 1, 2, 3, 4, 5, 6
local function online(src, cid, job)
    local p = Mock.newPlayer(src, cid)
    if job then p.PlayerData.job = job end
    Mock.fireEvent('QBCore:Server:PlayerLoaded', nil, p)
    return p
end
local function medicJob(grade) return { name = 'ambulance', onduty = true, grade = { level = grade } } end
local function cb(name, src, ...) Mock.gameTimer = Mock.gameTimer + 600 return Mock.callCallback(name, src, ...) end
local function exam(src, modality) return cb('pf-ambulancejob:server:exam', src, PATIENT, modality) end
local function setDx(src, target, data) return cb('pf-ambulancejob:server:setDiagnosis', src, target, data) end
local function chart(src, target) return cb('pf-ambulancejob:server:getChart', src, target) end
local function record(cid, opts) return Mock.selfExport('GetMedicalRecord')(cid, opts) end
local function auditRows(action)
    Store.Flush()
    local out = {}
    for _, e in ipairs(DB.events) do if e.action == action then out[#out + 1] = e end end
    return out
end

BeforeEach = function()
    Mock.reset()
    Mock.clock = 1700000000
    Mock.players, Mock.coords, Mock.aces, Mock.models = {}, {}, {}, {}
    Mock.invokingResource = nil
    Items, Admissions, CourtOrders = {}, {}, {}
    Mock.exportsByResource['pf-government'] = nil
    Mock.exportsByResource['pf-justice'] = nil
    boot()
    online(PATIENT, 'PATIENTCID')
    online(MEDIC, 'MEDICCID', medicJob(1))  -- paramedic (tier 3)
    online(EMR, 'EMRCID', medicJob(0))      -- EMR (tier 1)
    online(DOC, 'DOCCID', medicJob(2))      -- physician (tier 5)
    online(CIV, 'CIVCID')
    online(FAR, 'FARCID', medicJob(1))      -- paramedic across town
    Mock.coords[PATIENT] = vector3(500.0, 500.0, 30.0)
    Mock.coords[MEDIC] = vector3(501.0, 500.0, 30.0)
    Mock.coords[EMR] = vector3(500.0, 501.0, 30.0)
    Mock.coords[DOC] = vector3(2000.0, 2000.0, 30.0)
    Mock.coords[CIV] = vector3(499.0, 500.0, 30.0)
    Mock.coords[FAR] = vector3(900.0, 900.0, 30.0)
end

describe('setDiagnosis', function()
    it('needs an EMT or higher; providers suspect or rule out, never confirm', function()
        local r = setDx(EMR, PATIENT, { injuryType = 'fracture', structure = 'tibia_l', status = 'suspected' })
        assert_eq(r.error, 'no_permission')
        r = setDx(MEDIC, PATIENT, { injuryType = 'fracture', structure = 'tibia_l', status = 'confirmed' })
        assert_eq(r.error, 'invalid_state')
        r = setDx(MEDIC, PATIENT, { injuryType = 'fracture', structure = 'tibia_l', status = 'suspected', note = 'pain\nleft shin' })
        assert_true(r.ok)
        local row = DB.diagnoses[#DB.diagnoses]
        assert_eq(row.status, 'suspected')
        assert_eq(row.source, 'provider')
        assert_eq(row.by_cid, 'MEDICCID')
        assert_eq(row.note, 'pain left shin', 'control characters removed')
        assert_eq(#auditRows('diagnosis'), 1)
    end)
    it('validates every argument', function()
        assert_eq(setDx(MEDIC, PATIENT, { injuryType = 'curse', status = 'suspected' }).error, 'bad_args')
        assert_eq(setDx(MEDIC, PATIENT, { injuryType = 'fracture', structure = 'tail', status = 'suspected' }).error, 'bad_args')
        assert_eq(setDx(MEDIC, PATIENT, { injuryType = 'fracture', status = 'maybe' }).error, 'bad_args')
        assert_eq(setDx(MEDIC, PATIENT, 'x').error, 'bad_args')
        assert_eq(setDx(MEDIC, PATIENT, { injuryType = 'fracture', status = 'suspected', note = 12 }).error, 'bad_args')
        assert_eq(setDx(MEDIC, PATIENT, { injuryType = 'fracture', status = 'suspected', injuryId = -1 }).error, 'bad_args')
        local long = string.rep('a', 400)
        assert_true(setDx(MEDIC, PATIENT, { injuryType = 'fracture', status = 'suspected', note = long }).ok)
        assert_eq(#DB.diagnoses[#DB.diagnoses].note, 255)
    end)
    it('an injury id only from a finding: no probing for hidden injuries', function()
        local hidden = Engine.AddInjury('PATIENTCID', { mechanism = 'blunt', type = 'internal_bleeding', subtype = 'spleen', structure = 'spleen', region = 'abdomen', severity = 2 }, {})
        local r = setDx(MEDIC, PATIENT, { injuryType = 'internal_bleeding', status = 'suspected', injuryId = hidden.id })
        assert_eq(r.error, 'not_found')
        local seen = Engine.AddInjury('PATIENTCID', { mechanism = 'blunt', type = 'bruising', region = 'thigh_l', severity = 3 }, {})
        exam(MEDIC, 'look')
        r = setDx(MEDIC, PATIENT, { injuryType = 'bruising', status = 'suspected', injuryId = seen.id })
        assert_true(r.ok)
        assert_eq(DB.diagnoses[#DB.diagnoses].injury_id, seen.id)
    end)
    it('a confirmed diagnosis cannot be ruled out by examination', function()
        local inj = Engine.AddInjury('PATIENTCID', { mechanism = 'fall', type = 'fracture', subtype = 'closed', structure = 'femur_l', region = 'thigh_l', severity = 3 }, {})
        Store.SetDiagnosis('PATIENTCID', { injuryId = inj.id, structure = 'femur_l', injuryType = 'fracture', status = 'confirmed', source = 'imaging', byCid = 'DOCCID' })
        local r = setDx(MEDIC, PATIENT, { injuryType = 'fracture', structure = 'femur_l', status = 'ruled_out' })
        assert_eq(r.error, 'invalid_state')
        assert_true(setDx(MEDIC, PATIENT, { injuryType = 'fracture', structure = 'tibia_r', status = 'ruled_out' }).ok, 'another structure')
    end)
    it('a provider far away with no care relation may not diagnose', function()
        assert_eq(setDx(FAR, PATIENT, { injuryType = 'fracture', status = 'suspected' }).error, 'no_permission')
    end)
end)

describe('getChart: privacy and contents', function()
    it('attending, recent care, admitted and physicians may see it; others not (denials audited)', function()
        assert_eq(chart(CIV, PATIENT).error, 'no_permission', 'a civilian')
        assert_eq(chart(FAR, PATIENT).error, 'no_permission', 'a paramedic with no relation')
        assert_eq(#auditRows('record_read'), 1, 'the denial is audited')
        local r = chart(MEDIC, PATIENT)
        assert_true(r.ok)
        assert_eq(r.access, 'attending')
        assert_eq(chart(DOC, PATIENT).access, 'physician')
        Admissions.PATIENTCID = { state = 'admitted', bedId = 'pb_1' }
        assert_eq(chart(FAR, PATIENT).access, 'admitted')
        Admissions.PATIENTCID = { state = 'discharged' }
        assert_eq(chart(FAR, PATIENT).error, 'no_permission', 'a discharged admission no longer counts')
        -- examined earlier, then walked away: recent care for 24 h
        exam(MEDIC, 'look')
        Mock.coords[MEDIC] = vector3(800.0, 800.0, 30.0)
        assert_eq(chart(MEDIC, PATIENT).access, 'recent_care')
        assert_eq(chart(MEDIC, 'PATIENTCID').access, 'recent_care', 'by citizen id too')
        Mock.clock = Mock.clock + 86401
        assert_eq(chart(MEDIC, PATIENT).error, 'no_permission', 'care older than 24 h')
    end)
    it('recent care survives a restart through the stored findings and treatments', function()
        exam(MEDIC, 'look')
        DB.treatments[1] = { id = 1, citizenid = 'PATIENTCID', by_cid = 'FARCID', action = 'splint', location = 'field', result = 'ok', at = os.time() }
        local saved = DB
        boot()
        DB.findings, DB.treatments = saved.findings, saved.treatments
        Mock.coords[MEDIC] = vector3(800.0, 800.0, 30.0)
        assert_eq(chart(MEDIC, PATIENT).access, 'recent_care')
        assert_eq(chart(FAR, PATIENT).access, 'recent_care', 'from the treatment log')
    end)
    it('shows findings, current diagnoses, measured vitals and the treatment log; never injury rows', function()
        local hidden = Engine.AddInjury('PATIENTCID', { mechanism = 'blunt', type = 'internal_bleeding', subtype = 'liver', structure = 'liver', region = 'abdomen', severity = 3 }, {})
        local bruise = Engine.AddInjury('PATIENTCID', { mechanism = 'blunt', type = 'bruising', region = 'thigh_l', severity = 3 }, {})
        exam(MEDIC, 'look')
        exam(MEDIC, 'pulse')
        setDx(MEDIC, PATIENT, { injuryType = 'fracture', structure = 'femur_l', status = 'suspected' })
        setDx(MEDIC, PATIENT, { injuryType = 'fracture', structure = 'femur_l', status = 'ruled_out' })
        setDx(MEDIC, PATIENT, { injuryType = 'bruising', status = 'suspected', injuryId = bruise.id })
        DB.treatments[1] = { id = 1, citizenid = 'PATIENTCID', injury_id = bruise.id, by_cid = 'MEDICCID', action = 'pressure_dressing', location = 'field', result = 'ok', at = os.time() }
        local r = chart(MEDIC, PATIENT)
        assert_true(r.ok)
        assert_eq(r.injuries, nil)
        local bruiseSeen, hiddenSeen = false, false
        for _, f in ipairs(r.findings) do
            if f.injuryId == bruise.id then bruiseSeen = true end
            if f.injuryId == hidden.id then hiddenSeen = true end
            assert_eq(f.severity, nil)
            assert_eq(f.bleed_ml_min, nil)
        end
        assert_true(bruiseSeen)
        assert_false(hiddenSeen, 'a hidden injury nobody found is not on the chart')
        assert_eq(#r.diagnoses, 2, 'latest status per diagnosis')
        local femur
        for _, d in ipairs(r.diagnoses) do if d.structure == 'femur_l' then femur = d end end
        assert_eq(femur.status, 'ruled_out')
        assert_eq(#r.vitals, 2, 'pulse and respiratory rate')
        assert_eq(r.treatments[1].action, 'pressure_dressing')
        assert_eq(r.patient.cid, 'PATIENTCID')
        local reads = auditRows('record_read')
        assert_eq(#reads, 1)
        assert_eq(reads[1].actor_cid, 'MEDICCID')
    end)
    it('a confirmed diagnosis outranks a later provider row for the same injury', function()
        local inj = Engine.AddInjury('PATIENTCID', { mechanism = 'fall', type = 'fracture', subtype = 'closed', structure = 'femur_l', region = 'thigh_l', severity = 3 }, {})
        Store.SetDiagnosis('PATIENTCID', { injuryId = inj.id, structure = 'femur_l', injuryType = 'fracture', status = 'confirmed', source = 'imaging' })
        Store.SetDiagnosis('PATIENTCID', { injuryId = inj.id, structure = 'femur_l', injuryType = 'fracture', status = 'suspected', source = 'provider' })
        local list = Dx.CurrentDiagnoses('PATIENTCID')
        assert_eq(#list, 1)
        assert_eq(list[1].status, 'confirmed')
        assert_true(Dx.HasDiagnosis('PATIENTCID', { injuryType = 'fracture', structure = 'femur_l', statuses = { confirmed = true } }))
        assert_false(Dx.HasDiagnosis('PATIENTCID', { injuryType = 'burn' }))
    end)
end)

describe('GetMedicalRecord', function()
    local function setupRecord()
        local seen = Engine.AddInjury('PATIENTCID', { mechanism = 'blunt', type = 'bruising', region = 'thigh_l', severity = 3 }, {})
        local hidden = Engine.AddInjury('PATIENTCID', { mechanism = 'blunt', type = 'internal_bleeding', subtype = 'liver', structure = 'liver', region = 'abdomen', severity = 3 }, {})
        exam(MEDIC, 'look')
        setDx(MEDIC, PATIENT, { injuryType = 'fracture', structure = 'femur_l', status = 'suspected' })
        Store.SetDiagnosis('PATIENTCID', { injuryId = seen.id, injuryType = 'bruising', status = 'confirmed', source = 'imaging' })
        return seen, hidden
    end
    it('only allowed resources may call it', function()
        Mock.invokingResource = 'pf-phone'
        assert_eq(record('PATIENTCID', { viewer = PATIENT, purpose = 'self' }).error, 'not_allowed')
        Mock.invokingResource = 'pf-emsmdt'
        assert_true(record('PATIENTCID', { viewer = PATIENT, purpose = 'self' }).ok)
    end)
    it('self: the patient sees their own record; documented injuries and confirmed diagnoses only', function()
        local seen, hidden = setupRecord()
        Mock.invokingResource = 'pf-emsmdt'
        assert_eq(record('PATIENTCID', { viewer = CIV, purpose = 'self' }).error, 'no_permission')
        local r = record('PATIENTCID', { viewer = PATIENT, purpose = 'self' })
        assert_true(r.ok)
        local ids = {}
        for _, i in ipairs(r.record.injuries) do ids[i.id] = true; assert_eq(i.source_attacker_cid, nil); assert_eq(i.attrs, nil) end
        assert_true(ids[seen.id])
        assert_eq(ids[hidden.id], nil, 'an undiscovered injury is not in the record')
        assert_eq(#r.record.diagnoses, 1)
        assert_eq(r.record.diagnoses[1].status, 'confirmed')
        assert_eq(r.record.admissions[1].hospitalId, 'pillbox')
        assert_eq(#r.record.prescriptions, 0)
        assert_eq(#r.record.deathRecords, 0)
    end)
    it('treatment: medical staff with a care relation, or a physician', function()
        setupRecord()
        Mock.invokingResource = 'pf-emsmdt'
        assert_true(record('PATIENTCID', { viewer = MEDIC, purpose = 'treatment' }).ok)
        assert_eq(record('PATIENTCID', { viewer = FAR, purpose = 'treatment' }).error, 'no_permission')
        assert_true(record('PATIENTCID', { viewer = DOC, purpose = 'treatment' }).ok)
        assert_eq(record('PATIENTCID', { viewer = CIV, purpose = 'treatment' }).error, 'no_permission')
        Mock.invokingResource = 'pf-policemdt-DEV'
        assert_eq(record('PATIENTCID', { viewer = CIV, purpose = 'treatment' }).error, 'no_permission', 'police are not medical staff')
    end)
    it('court_order: only with a valid court order from pf-justice', function()
        setupRecord()
        Mock.invokingResource = 'pf-policemdt-DEV'
        assert_eq(record('PATIENTCID', { purpose = 'court_order', courtOrderId = 'CO-1' }).error, 'no_permission', 'pf-justice has no IsCourtOrderValid yet')
        Mock.exportsByResource['pf-justice'] = { IsCourtOrderValid = function(_, ref, purpose, cid) return CourtOrders[ref] == purpose .. ':' .. cid end }
        assert_eq(record('PATIENTCID', { purpose = 'court_order', courtOrderId = 'CO-1' }).error, 'no_permission')
        CourtOrders['CO-1'] = 'medical_records:OTHER'
        assert_eq(record('PATIENTCID', { purpose = 'court_order', courtOrderId = 'CO-1' }).error, 'no_permission', 'order for someone else')
        CourtOrders['CO-1'] = 'medical_records:PATIENTCID'
        local r = record('PATIENTCID', { purpose = 'court_order', courtOrderId = 'CO-1' })
        assert_true(r.ok)
        assert_eq(record('PATIENTCID', { purpose = 'court_order' }).error, 'bad_args')
    end)
    it('every read and every denial writes a record_read audit row', function()
        setupRecord()
        Mock.invokingResource = 'pf-emsmdt'
        record('PATIENTCID', { viewer = PATIENT, purpose = 'self' })
        record('PATIENTCID', { viewer = CIV, purpose = 'self' })
        record('PATIENTCID', { viewer = PATIENT, purpose = 'gossip' })
        local rows = auditRows('record_read')
        assert_eq(#rows, 2, 'a bad purpose is refused before any read')
        local d1, d2 = json.decode(rows[1].detail), json.decode(rows[2].detail)
        assert_eq(d1.purpose, 'self')
        assert_eq(d1.invoker, 'pf-emsmdt')
        assert_eq(d2.denied, 'no_permission')
    end)
    it('bad arguments', function()
        assert_eq(record('bad cid!', { purpose = 'self', viewer = PATIENT }).error, 'bad_args')
        assert_eq(record('PATIENTCID', nil).error, 'bad_args')
        assert_eq(record('PATIENTCID', { purpose = 'self' }).error, 'bad_args', 'self needs a viewer')
        assert_eq(record('PATIENTCID', { purpose = 'self', viewer = 99 }).error, 'offline')
    end)
end)

describe('internal API for treatment preconditions', function()
    it('HasFinding matches sign, injury and certainty', function()
        local inj = Engine.AddInjury('PATIENTCID', { mechanism = 'blunt', type = 'bruising', region = 'thigh_l', severity = 3 }, {})
        assert_false(Dx.HasFinding('PATIENTCID', { sign = 'bruise' }))
        exam(MEDIC, 'look')
        assert_true(Dx.HasFinding('PATIENTCID', { sign = 'bruise', injuryId = inj.id }))
        assert_false(Dx.HasFinding('PATIENTCID', { sign = 'bruise', minCertainty = 'suspected' }), 'a bruise is observed, not suspected')
        assert_false(Dx.HasFinding('PATIENTCID', { sign = 'bruise', injuryId = inj.id + 1 }))
    end)
    it('provider tier: grade fallback without pf-government; qualifications when it answers', function()
        assert_eq(Dx.ProviderTier(MEDIC), 3)
        assert_eq(Dx.ProviderTier(DOC), 5)
        assert_eq(Dx.ProviderTier(CIV), 0)
        Mock.exportsByResource['pf-government'] = { HasQualification = function(_, cid, q) return cid == 'MEDICCID' and q == 'surgeon' end }
        Dx.ForgetTier(MEDIC)
        assert_eq(Dx.ProviderTier(MEDIC), 5)
    end)
    it('the hospital tier table (config_hospital.lua Tiers) is the one used when present', function()
        Config.Hospital = { Tiers = { Quals = { { 'nurse', 4 } }, GradeFallback = { [0] = 1, [1] = 2, [2] = 4 } } }
        Dx.ForgetTier(MEDIC)
        assert_eq(Dx.ProviderTier(MEDIC), 2, 'grade fallback from the hospital table')
        Mock.exportsByResource['pf-government'] = { HasQualification = function(_, cid, q) return cid == 'MEDICCID' and q == 'nurse' end }
        Dx.ForgetTier(MEDIC)
        assert_eq(Dx.ProviderTier(MEDIC), 4)
        Config.Hospital = nil
    end)
end)
