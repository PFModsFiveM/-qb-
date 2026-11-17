-- pf-ambulancejob batch 17A: exams (callback pf-ambulancejob:server:exam). Findings by modality and
-- tier with sensitivity (a miss gives no finding, never a false one); tier, distance, instrument,
-- hospital and imaging-room checks on the server; internal bleeding only on FAST/CT; the same exam
-- within 60 s returns the stored result; the server waits the exam's time and re-checks; locks and
-- the rate limit; examOptions; /checkinjuries opens the exam flow (client).
load_resource('tests/lua/fivem_mocks.lua')
function IsDuplicityVersion() return true end
function GetCurrentResourceName() return 'pf-ambulancejob' end
function GetResourceState() return 'started' end

-- FiveM runs every handler of an event; the mock keeps one per name, so chain them
function AddEventHandler(name, fn)
    local prev = Mock.eventHandlers[name]
    if prev then Mock.eventHandlers[name] = function(...) prev(...) fn(...) end else Mock.eventHandlers[name] = fn end
end
Vehicles = {}
function GetAllVehicles() return Vehicles end
Items, Quals, Admissions = {}, {}, {}
Mock.exportsByResource['pfm-inventory'] = {
    HasItem = function(_, src, name) return (Items[src] or {})[name] == true end,
}
Mock.exportsByResource['pfm-core'].RunMigrations = function() return true end

local AJ = '[pfscripts]/pf-ambulancejob/'

-- in-memory SQL (the real statements run in b17_medical_diagnosis_realdb_spec)
DB = nil
local function copy(t)
    if type(t) ~= 'table' then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = copy(v) end
    return o
end
local function installFakeSQL()
    DB = { patients = {}, injuries = {}, events = {}, findings = {}, diagnoses = {}, nextId = 0 }
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
    Q.DxCareTreatment = function() error("Table 'pf_med_treatments' doesn't exist") end
    Q.DxFindingForInjury = function(cid, id) for _, f in ipairs(DB.findings) do if f.citizenid == cid and f.injury_id == id then return 1 end end return nil end
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
        if not a then return { ok = true } end
        return { ok = true, admission = a }
    end
    Mock.exportsByResource['pf-ambulancejob'] = Mock.exportsByResource['__self']
    assert(PFMed.Schema.Start(), 'schema ready')
    Exam, Dx, Store, Engine = PFMed.Exam, PFMed.Diagnosis, PFMed.Store, PFMed.Engine
    Engine.Random = function() return 0.5 end
    Exam.WaitFor = function() end
end

local PATIENT, MEDIC, CIV, DOC = 1, 2, 3, 4
local function online(src, cid, job)
    local p = Mock.newPlayer(src, cid)
    if job then p.PlayerData.job = job end
    Mock.fireEvent('QBCore:Server:PlayerLoaded', nil, p)
    return p
end
local function medicJob(grade) return { name = 'ambulance', onduty = true, grade = { level = grade or 1 } } end
local function rawExam(src, target, modality) return Mock.callCallback('pf-ambulancejob:server:exam', src, target, modality) end
-- each call half a second apart (the rate limit refills 2 per second); the rate spec calls rawExam
local function exam(src, target, modality) Mock.gameTimer = Mock.gameTimer + 600 return rawExam(src, target, modality) end
local function addInjury(spec) local inj = Engine.AddInjury('PATIENTCID', spec, {}) assert_true(inj ~= nil, 'injury added') return inj end
local function signs(res)
    local out = {}
    for _, f in ipairs(res.findings or {}) do out[f.sign] = f end
    return out
end
local function forInjury(res, id)
    for _, f in ipairs(res.findings or {}) do if f.injuryId == id then return f end end
    return nil
end
local FIELD = vector3(500.0, 500.0, 30.0)
local IMAGING = vector3(326.98, -576.17, 43.02)

BeforeEach = function()
    Mock.reset()
    Mock.clock = 1700000000
    Mock.players, Mock.coords, Mock.aces, Mock.models = {}, {}, {}, {}
    Mock.invokingResource = nil
    Items, Quals, Admissions, Vehicles = {}, {}, {}, {}
    PFHospital = nil
    Mock.exportsByResource['pf-government'] = nil   -- tiers by grade unless a spec adds quals
    boot()
    Dx.Random = function() return 0 end              -- every present sign is found unless a spec says otherwise
    online(PATIENT, 'PATIENTCID')
    online(MEDIC, 'MEDICCID', medicJob(1))           -- grade 1: paramedic (tier 3)
    online(CIV, 'CIVCID')
    online(DOC, 'DOCCID', medicJob(2))               -- grade 2: physician (tier 5)
    Mock.coords[PATIENT] = FIELD
    Mock.coords[MEDIC] = vector3(501.0, 500.0, 30.0)
    Mock.coords[CIV] = vector3(500.0, 501.0, 30.0)
    Mock.coords[DOC] = vector3(499.0, 500.0, 30.0)
end

local MEASURES = { responsiveness = true, not_breathing = true, external_bleeding = true, pulse = true, respiratory_rate = true,
    blood_pressure = true, spo2 = true, temperature = true, glucose = true, rhythm = true, pain_score = true, unresponsive = true, hemoglobin = true }

describe('scope of practice, distance, instruments and place', function()
    it('modalities need the tier: a civilian may look and ask, not take a pulse; an EMR cannot use a cuff', function()
        assert_true(exam(CIV, PATIENT, 'look').ok)
        assert_true(exam(CIV, PATIENT, 'ask').ok, 'ask is the pain scale')
        local r = exam(CIV, PATIENT, 'pulse')
        assert_eq(r.error, 'no_permission')
        Mock.players[MEDIC].PlayerData.job = medicJob(0) -- recruit: EMR (tier 1)
        Dx.ForgetTier(MEDIC)
        assert_true(exam(MEDIC, PATIENT, 'pulse').ok)
        Items[MEDIC] = { bp_cuff = true }
        assert_eq(exam(MEDIC, PATIENT, 'bp_cuff').error, 'no_permission')
    end)
    it('an off-duty medic is tier 0', function()
        Mock.players[MEDIC].PlayerData.job.onduty = false
        assert_eq(exam(MEDIC, PATIENT, 'palpate').error, 'no_permission')
        assert_true(exam(MEDIC, PATIENT, 'look').ok)
    end)
    it('tiers come from pf-government qualifications when it answers', function()
        Mock.exportsByResource['pf-government'] = { HasQualification = function(_, cid, q) return (Quals[cid] or {})[q] == true end }
        Quals.MEDICCID = { emr = true }               -- grade 1 but only certified as EMR
        Items[MEDIC] = { stethoscope = true }
        local r = exam(MEDIC, PATIENT, 'auscultate')
        assert_eq(r.error, 'no_permission', 'EMR cannot auscultate')
        Quals.MEDICCID = { emr = true, emt = true, paramedic = true }
        Dx.ForgetTier(MEDIC)
        assert_true(exam(MEDIC, PATIENT, 'auscultate').ok)
    end)
    it('server distance: 2.5 m for field exams', function()
        Mock.coords[MEDIC] = vector3(503.0, 500.0, 30.0)
        assert_eq(exam(MEDIC, PATIENT, 'look').error, 'too_far')
        Mock.coords[MEDIC] = vector3(502.4, 500.0, 30.0)
        assert_true(exam(MEDIC, PATIENT, 'look').ok)
    end)
    it('an instrument is an item held, an ambulance within 10 m or the hospital', function()
        local r = exam(MEDIC, PATIENT, 'bp_cuff')
        assert_eq(r.error, 'invalid_state')
        assert_true(r.message:find('bp_cuff', 1, true) ~= nil, r.message)
        Items[MEDIC] = { bp_cuff = true }
        assert_true(exam(MEDIC, PATIENT, 'bp_cuff').ok, 'item held')
        Items[MEDIC] = {}
        Vehicles = { 900 }
        Mock.models[900] = GetHashKey('ambulance')
        Mock.coords[900] = vector3(512.0, 500.0, 30.0)  -- 11 m from the medic
        Mock.clock = Mock.clock + 61
        assert_eq(exam(MEDIC, PATIENT, 'bp_cuff').error, 'invalid_state', 'rig too far')
        Mock.coords[900] = vector3(508.0, 500.0, 30.0)
        assert_true(exam(MEDIC, PATIENT, 'bp_cuff').ok, 'rig within 10 m')
        Vehicles = {}
        Mock.coords[PATIENT] = vector3(310.0, -590.0, 43.0)  -- Pillbox
        Mock.coords[MEDIC] = vector3(311.0, -590.0, 43.0)
        Mock.clock = Mock.clock + 61
        assert_true(exam(MEDIC, PATIENT, 'bp_cuff').ok, 'hospital instruments')
    end)
    it('FAST has no handheld version: a rig or the hospital only', function()
        Items[MEDIC] = { bp_cuff = true, stethoscope = true, aed = true }
        assert_eq(exam(MEDIC, PATIENT, 'fast_us').error, 'invalid_state')
        Vehicles = { 901 }
        Mock.models[901] = GetHashKey('ambulance')
        Mock.coords[901] = vector3(505.0, 500.0, 30.0)
        assert_true(exam(MEDIC, PATIENT, 'fast_us').ok)
    end)
    it('labs need the patient in a hospital and a nurse or higher', function()
        assert_eq(exam(DOC, PATIENT, 'labs').error, 'invalid_state')
        Mock.coords[PATIENT] = vector3(310.0, -590.0, 43.0)
        Mock.coords[DOC] = vector3(311.0, -590.0, 43.0)
        Mock.coords[MEDIC] = vector3(309.0, -590.0, 43.0)
        assert_eq(exam(MEDIC, PATIENT, 'labs').error, 'no_permission', 'paramedic')
        assert_true(exam(DOC, PATIENT, 'labs').ok)
    end)
    it('imaging only in an imaging room with the patient in a server-held bed', function()
        Mock.coords[PATIENT] = vector3(310.0, -590.0, 43.0)   -- in the hospital, not the imaging room
        Mock.coords[DOC] = vector3(311.0, -590.0, 43.0)
        Admissions.PATIENTCID = { state = 'admitted', bedId = 'pb_8', hospitalId = 'pillbox' }
        local r = exam(DOC, PATIENT, 'xray')
        assert_eq(r.error, 'invalid_state')
        assert_true(r.message:find('imaging', 1, true) ~= nil, r.message)
        Mock.coords[PATIENT] = IMAGING
        Mock.coords[DOC] = vector3(330.0, -576.0, 43.0)      -- 3 m away (same room)
        Admissions.PATIENTCID = { state = 'waiting', hospitalId = 'pillbox' }
        assert_eq(exam(DOC, PATIENT, 'xray').error, 'invalid_state', 'waiting holds no bed')
        Admissions.PATIENTCID = nil
        assert_eq(exam(DOC, PATIENT, 'ct').error, 'invalid_state', 'not admitted')
        Admissions.PATIENTCID = { state = 'admitted', bedId = 'pb_8', hospitalId = 'pillbox' }
        assert_true(exam(DOC, PATIENT, 'xray').ok)
        assert_true(exam(DOC, PATIENT, 'ct').ok)
        Mock.coords[MEDIC] = vector3(328.0, -576.0, 43.0)
        assert_eq(exam(MEDIC, PATIENT, 'ct').error, 'no_permission', 'a paramedic cannot order CT')
    end)
    it('with the hospital core (17E) loaded its bed check decides: in a bed of an imaging department', function()
        local inBed
        PFHospital = {
            Beds = { PatientInBed = function(src) return src == PATIENT and inBed or nil end },
            Facility = { At = function(pos) return pos.x > 300 and pos.x < 400 and 'pillbox' or nil end },
            Admissions = { OpenOf = function(cid) return Admissions[cid] end },
        }
        Mock.coords[PATIENT] = vector3(352.0, -588.0, 43.0)
        Mock.coords[DOC] = vector3(354.0, -588.0, 43.0)
        local r = exam(DOC, PATIENT, 'xray')
        assert_eq(r.error, 'invalid_state')
        assert_true(r.message:find('bed', 1, true) ~= nil, r.message)
        inBed = { hospitalId = 'pillbox', bedId = 'ed1', dept = 'ed', imaging = false }
        r = exam(DOC, PATIENT, 'xray')
        assert_true(r.message:find('imaging', 1, true) ~= nil, r.message)
        inBed = { hospitalId = 'pillbox', bedId = 'w3', dept = 'ward', imaging = true }
        assert_true(exam(DOC, PATIENT, 'xray').ok)
        assert_true(exam(DOC, PATIENT, 'labs').ok, 'the facility zone counts as the hospital')
        Admissions.PATIENTCID = { state = 'admitted', bed_id = 'w3' }
        assert_true(Dx.Admission('PATIENTCID') ~= nil, 'admissions read in memory')
        PFHospital = nil
    end)
    it('bad arguments: unknown modality, yourself, a bad or empty target', function()
        assert_eq(exam(MEDIC, PATIENT, 'mri').error, 'bad_args')
        assert_eq(exam(MEDIC, MEDIC, 'look').error, 'bad_args')
        assert_eq(exam(MEDIC, 'x', 'look').error, 'bad_args')
        assert_eq(exam(MEDIC, 99, 'look').error, 'not_found')
    end)
end)

describe('findings: sensitivity, misses and no false findings', function()
    it('a miss produces no finding (rolls above the sensitivity)', function()
        local inj = addInjury({ mechanism = 'blunt', type = 'bruising', region = 'thigh_l', severity = 3 })
        Dx.Random = function() return 0.999 end
        local r = exam(MEDIC, PATIENT, 'look')
        assert_true(r.ok)
        assert_eq(forInjury(r, inj.id), nil)
        assert_true(signs(r).responsiveness ~= nil, 'gross observations are always made')
        Mock.clock = Mock.clock + 61
        Dx.Random = function() return 0 end
        r = exam(MEDIC, PATIENT, 'look')
        local f = forInjury(r, inj.id)
        assert_eq(f.sign, 'bruise')
        assert_eq(f.region, 'thigh_l')
        assert_eq(f.structure, nil, 'looking names the region, not the structure')
        assert_eq(f.certainty, 'observed')
    end)
    it('the tier changes the sensitivity: a bystander finds less than a physician', function()
        local inj = addInjury({ mechanism = 'blunt', type = 'bruising', region = 'thigh_l', severity = 3 })
        Dx.Random = function() return 0.82 end   -- bruise: bystander 0.80, physician 0.97
        local r = exam(CIV, PATIENT, 'look')
        assert_eq(forInjury(r, inj.id), nil)
        r = exam(DOC, PATIENT, 'look')
        assert_true(forInjury(r, inj.id) ~= nil)
    end)
    it('a healthy patient: every modality returns only measurements, never an injury sign', function()
        Mock.coords[PATIENT] = IMAGING
        Mock.coords[DOC] = vector3(328.0, -576.0, 43.0)
        Admissions.PATIENTCID = { state = 'admitted', bedId = 'pb_8' }
        for _, m in ipairs(PFMed.Findings.Ordered()) do
            local r = exam(DOC, PATIENT, m)
            assert_true(r.ok, m .. ': ' .. tostring(r.error) .. ' ' .. tostring(r.message))
            for _, f in ipairs(r.findings) do
                assert_true(MEASURES[f.sign] == true, m .. ' produced ' .. f.sign)
                assert_eq(f.injuryId, nil)
            end
        end
    end)
    it('a closed fracture cannot be seen; an open one can; palpation and x-ray find the closed one', function()
        local closed = addInjury({ mechanism = 'fall', type = 'fracture', subtype = 'closed', structure = 'tibia_l', region = 'lower_leg_l', severity = 3 })
        local open = addInjury({ mechanism = 'fall', type = 'fracture', subtype = 'open', structure = 'tibia_r', region = 'lower_leg_r', severity = 3 })
        local r = exam(MEDIC, PATIENT, 'look')
        assert_eq(forInjury(r, closed.id), nil)
        assert_eq(forInjury(r, open.id).sign, 'deformity')
        r = exam(MEDIC, PATIENT, 'palpate')
        assert_eq(forInjury(r, closed.id).sign, 'bony_tenderness')
        assert_eq(forInjury(r, closed.id).certainty, 'suspected')
        Mock.coords[PATIENT] = IMAGING
        Mock.coords[DOC] = vector3(328.0, -576.0, 43.0)
        Admissions.PATIENTCID = { state = 'in_treatment', bedId = 'pb_8' }
        r = exam(DOC, PATIENT, 'xray')
        local f = forInjury(r, closed.id)
        assert_eq(f.sign, 'fracture_line')
        assert_eq(f.certainty, 'confirmed')
        assert_eq(f.structure, 'tibia_l', 'imaging names the structure')
        local confirmed = 0
        for _, d in ipairs(DB.diagnoses) do if d.status == 'confirmed' and d.source == 'imaging' and d.injury_id == closed.id then confirmed = confirmed + 1 end end
        assert_eq(confirmed, 1, 'x-ray confirms the diagnosis once')
        Mock.clock = Mock.clock + 61
        exam(DOC, PATIENT, 'xray')
        confirmed = 0
        for _, d in ipairs(DB.diagnoses) do if d.status == 'confirmed' and d.injury_id == closed.id then confirmed = confirmed + 1 end end
        assert_eq(confirmed, 1, 'a second x-ray does not duplicate it')
    end)
    it('internal bleeding is invisible until FAST or CT', function()
        local inj = addInjury({ mechanism = 'blunt', type = 'internal_bleeding', subtype = 'liver', structure = 'liver', region = 'abdomen', severity = 3 })
        Mock.coords[PATIENT] = IMAGING
        Mock.coords[DOC] = vector3(328.0, -576.0, 43.0)
        Admissions.PATIENTCID = { state = 'admitted', bedId = 'pb_8' }
        for _, m in ipairs({ 'look', 'palpate', 'auscultate', 'pupils', 'pulse', 'bp_cuff', 'spo2_probe', 'ecg', 'labs', 'xray' }) do
            local r = exam(DOC, PATIENT, m)
            assert_true(r.ok, m)
            assert_eq(forInjury(r, inj.id), nil, m .. ' must not reveal internal bleeding')
        end
        local r = exam(DOC, PATIENT, 'fast_us')
        local f = forInjury(r, inj.id)
        assert_eq(f.sign, 'free_fluid')
        assert_eq(f.certainty, 'suspected', 'FAST suggests, it does not confirm')
        assert_eq(f.region, 'abdomen')
        for _, d in ipairs(DB.diagnoses) do assert_true(d.injury_id ~= inj.id, 'FAST writes no confirmed diagnosis') end
        r = exam(DOC, PATIENT, 'ct')
        f = forInjury(r, inj.id)
        assert_eq(f.sign, 'organ_laceration')
        assert_eq(f.structure, 'liver')
        assert_eq(DB.diagnoses[#DB.diagnoses].injury_type, 'internal_bleeding')
        assert_eq(DB.diagnoses[#DB.diagnoses].status, 'confirmed')
    end)
    it('a lung wound is heard on auscultation; tension shows tracheal deviation to a paramedic', function()
        local gsw = addInjury({ mechanism = 'firearm', type = 'gunshot', subtype = 'penetrating', structure = 'lung_l', region = 'chest_l', severity = 3 })
        local tpx = addInjury({ mechanism = 'firearm', type = 'organ_trauma', subtype = 'tension', structure = 'lung_r', region = 'chest_r', severity = 3 })
        Items[MEDIC] = { stethoscope = true }
        local r = exam(MEDIC, PATIENT, 'auscultate')
        assert_eq(forInjury(r, gsw.id).sign, 'decreased_breath_sounds')
        assert_eq(forInjury(r, tpx.id).sign, 'absent_breath_sounds')
        r = exam(MEDIC, PATIENT, 'look')
        local found = false
        for _, f in ipairs(r.findings) do if f.injuryId == tpx.id and f.sign == 'tracheal_deviation' then found = true end end
        assert_true(found)
        assert_true(Dx.HasFinding('PATIENTCID', { injuryId = tpx.id, signs = { absent_breath_sounds = true, tracheal_deviation = true }, minCertainty = 'suspected' }))
    end)
    it('measurements are the derived vitals; an arrested patient has no pulse', function()
        local r = exam(MEDIC, PATIENT, 'pulse')
        local v = Engine.Vitals(Store.Peek('PATIENTCID'), os.time())
        assert_eq(r.vitals.hr, v.hr)
        assert_eq(signs(r).pulse.value, tostring(v.hr))
        Store.Peek('PATIENTCID').consciousness = 'arrest'
        Mock.clock = Mock.clock + 61
        r = exam(MEDIC, PATIENT, 'pulse')
        assert_eq(signs(r).pulse.value, 'absent')
        assert_eq(r.vitals.hr, 0)
        r = exam(MEDIC, PATIENT, 'ask')
        assert_true(signs(r).unresponsive ~= nil, 'an unresponsive patient cannot rate pain')
    end)
    it('toxins show on pupils and on the lab panel', function()
        Store.Peek('PATIENTCID').toxins = { opioid = 40 }
        Items[MEDIC] = { penlight = true }
        local r = exam(MEDIC, PATIENT, 'pupils')
        assert_true(signs(r).pinpoint_pupils ~= nil)
        Mock.coords[PATIENT] = vector3(310.0, -590.0, 43.0)
        Mock.coords[DOC] = vector3(311.0, -590.0, 43.0)
        r = exam(DOC, PATIENT, 'labs')
        assert_eq(signs(r).tox_screen.value, 'opioid')
        assert_eq(signs(r).tox_screen.certainty, 'confirmed')
    end)
end)

describe('stored results, server time and locks', function()
    it('the same exam within 60 s returns the stored result (no re-roll, no new rows)', function()
        local inj = addInjury({ mechanism = 'blunt', type = 'bruising', region = 'thigh_l', severity = 3 })
        Dx.Random = function() return 0.999 end
        local r1 = exam(MEDIC, PATIENT, 'look')
        assert_eq(forInjury(r1, inj.id), nil)
        local rows = #DB.findings
        Dx.Random = function() return 0 end
        Mock.clock = Mock.clock + 59
        local r2 = exam(MEDIC, PATIENT, 'look')
        assert_true(r2.reused)
        assert_eq(forInjury(r2, inj.id), nil, 'no re-roll')
        assert_eq(#DB.findings, rows, 'nothing new stored')
        -- another provider of the same tier gets the same stored result
        online(5, 'MEDIC2', medicJob(1))
        Mock.coords[5] = vector3(500.0, 499.0, 30.0)
        assert_true(exam(5, PATIENT, 'look').reused)
        Mock.clock = Mock.clock + 2
        local r3 = exam(MEDIC, PATIENT, 'look')
        assert_true(not r3.reused)
        assert_true(forInjury(r3, inj.id) ~= nil, 'a new exam after 60 s rolls again')
    end)
    it('the server waits the exam time and re-checks: walking away during it gives nothing', function()
        local waited
        Exam.WaitFor = function(s) waited = s; Mock.coords[MEDIC] = vector3(520.0, 500.0, 30.0) end
        local r = exam(MEDIC, PATIENT, 'palpate')
        assert_eq(waited, PFMed.Findings.Modalities.palpate.seconds)
        assert_eq(r.error, 'too_far')
        assert_eq(#DB.findings, 0)
        Exam.WaitFor = function() Mock.players[MEDIC].PlayerData.job.onduty = false; Dx.ForgetTier(MEDIC) end
        Mock.coords[MEDIC] = vector3(501.0, 500.0, 30.0)
        assert_eq(exam(MEDIC, PATIENT, 'palpate').error, 'no_permission', 'went off duty during the exam')
    end)
    it('one exam at a time per provider and per exam (locks taken before the wait)', function()
        local inner, inner2
        Exam.WaitFor = function()
            inner = exam(MEDIC, PATIENT, 'pulse')
            online(5, 'MEDIC2', medicJob(1))
            Mock.coords[5] = vector3(500.0, 499.0, 30.0)
            inner2 = exam(5, PATIENT, 'palpate')
        end
        assert_true(exam(MEDIC, PATIENT, 'palpate').ok)
        assert_eq(inner.error, 'busy')
        assert_eq(inner2.error, 'busy', 'the same exam is rolling for someone else')
    end)
    it('rate limit: 2 per second, burst 4', function()
        local errs = 0
        for i = 1, 6 do
            Mock.clock = Mock.clock + 61
            local r = rawExam(MEDIC, PATIENT, 'look')
            if r.error == 'rate_limited' then errs = errs + 1 end
        end
        assert_eq(errs, 2)
    end)
    it('an exam writes findings rows and an exam audit row', function()
        addInjury({ mechanism = 'blunt', type = 'bruising', region = 'thigh_l', severity = 3 })
        exam(MEDIC, PATIENT, 'look')
        assert_true(#DB.findings >= 2)
        assert_eq(DB.findings[1].by_cid, 'MEDICCID')
        assert_eq(DB.findings[1].by_tier, 3)
        Store.Flush()
        local found
        for _, e in ipairs(DB.events) do if e.action == 'exam' then found = e end end
        assert_true(found ~= nil)
        assert_eq(found.actor_cid, 'MEDICCID')
    end)
end)

describe('examOptions', function()
    it('lists every modality with whether it is possible here and why not; stores nothing', function()
        Items[MEDIC] = { stethoscope = true }
        local r = Mock.callCallback('pf-ambulancejob:server:examOptions', MEDIC, PATIENT)
        assert_true(r.ok)
        assert_eq(r.tier, 3)
        local by = {}
        for _, m in ipairs(r.modalities) do by[m.id] = m end
        assert_true(by.look.available)
        assert_true(by.auscultate.available)
        assert_false(by.bp_cuff.available)
        assert_true(by.bp_cuff.reason:find('bp_cuff', 1, true) ~= nil)
        assert_false(by.ct.available)
        assert_eq(#DB.findings, 0)
        assert_eq(Mock.callCallback('pf-ambulancejob:server:examOptions', MEDIC, 99).error, 'not_found')
    end)
end)

describe('client: /checkinjuries opens the exam flow', function()
    it('the command calls PFExam.Open with the target; the legacy injury list is gone', function()
        local src = __readfile(AJ .. 'client/check_injuries.lua')
        assert_true(src:find('PFExam.Open', 1, true) ~= nil)
        assert_true(src:find('getInjuriesAndData', 1, true) == nil, 'no longer the raw injury scan')
        assert_true(src:find('function IsPlayerAEMSMember', 1, true) ~= nil, 'kept for client/treatment.lua')
        assert_false(pcall(__readfile, AJ .. 'client/injury_handler.lua'), 'client/injury_handler.lua (dead code) is deleted')
    end)
    it('the exam menu asks the server for options and runs the exam callback', function()
        local src = __readfile(AJ .. 'client/exam.lua')
        assert_true(src:find("'pf-ambulancejob:server:examOptions'", 1, true) ~= nil)
        assert_true(src:find("'pf-ambulancejob:server:exam'", 1, true) ~= nil)
        assert_true(src:find("'pf-ambulancejob:server:getChart'", 1, true) ~= nil)
        assert_true(src:find("AddGlobalPlayer", 1, true) ~= nil)
    end)
end)
