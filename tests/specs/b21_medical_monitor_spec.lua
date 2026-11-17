-- pf-ambulancejob vitals monitor (batch 21 follow-up; architecture 4.1 pf-ambulancejob:client:Monitor):
-- callbacks pf-ambulancejob:server:monitorAttach(target) / monitorDetach with the ECG's own gates
-- (on-duty medic of the ECG tier, touch distance, the monitor at hand, patient online); readings
-- (patientSrc, { hr, sbp, dbp, rr, spo2, temp }, rhythm) from the engine pushed to the attached
-- medic only by the named Monitor.Tick; the monitor comes off when they are apart, either goes
-- offline or the medic goes off duty; one monitor per medic and bounded per patient and in total.
load_resource('tests/lua/fivem_mocks.lua')
function IsDuplicityVersion() return true end
function GetCurrentResourceName() return 'pf-ambulancejob' end
function GetResourceState() return 'started' end
function AddEventHandler(name, fn)
    local prev = Mock.eventHandlers[name]
    if prev then Mock.eventHandlers[name] = function(...) prev(...) fn(...) end else Mock.eventHandlers[name] = fn end
end
function GetAllVehicles() return {} end
Items = {}
Mock.exportsByResource['pfm-inventory'] = { HasItem = function(_, src, name) return (Items[src] or {})[name] == true end }
Mock.exportsByResource['pfm-core'].RunMigrations = function() return true end

local AJ = '[pfscripts]/pf-ambulancejob/'
local function installFakeSQL()
    local Q = PFMed.SQL
    Q.LoadPatient = function() return nil end
    Q.LoadOpenInjuries = function() return {} end
    Q.FindInjuryByKey = function() return nil end
    Q.InsertInjury = function() return 1 end
    Q.UpsertPatients = function() return true end
    Q.UpsertInjuries = function() return true end
    Q.InsertEvents = function() return true end
    Q.Sweep = function() return {} end
end

local M, Store
local function boot()
    Mock.eventHandlers, Mock.netHandlers, Mock.callbacks = {}, {}, {}
    Mock.exportsByResource['__self'] = {}
    PFMed, PFAmbulance, Config, PFHospital = nil, nil, nil, nil
    load_resource(AJ .. 'config.lua')
    load_resource(AJ .. 'config_medical.lua')
    load_resource(AJ .. 'shared/framework.lua')
    for _, f in ipairs({ 'anatomy', 'injuries', 'physiology_model', 'effects_model', 'findings' }) do load_resource(AJ .. 'shared/medical/' .. f .. '.lua') end
    for _, f in ipairs({ 'schema', 'store', 'engine', 'effects', 'api', 'diagnosis', 'exam' }) do load_resource(AJ .. 'server/medical/' .. f .. '.lua') end
    load_resource(AJ .. 'server/ems/monitor.lua')
    installFakeSQL()
    Mock.exportsByResource['__self'].GetAdmission = function() return { ok = true } end
    Mock.exportsByResource['pf-ambulancejob'] = Mock.exportsByResource['__self']
    assert(PFMed.Schema.Start(), 'schema ready')
    M, Store = PFMed.Monitor, PFMed.Store
end

local PATIENT, MEDIC, EMR, CIV, MEDIC2 = 1, 2, 3, 4, 5
local FIELD = vector3(500.0, 500.0, 30.0)
local function online(src, cid, grade)
    local p = Mock.newPlayer(src, cid)
    if grade then p.PlayerData.job = { name = 'ambulance', onduty = true, grade = { level = grade } } end
    Mock.fireEvent('QBCore:Server:PlayerLoaded', nil, p)
    return p
end
local function attach(src, target)
    Mock.gameTimer = Mock.gameTimer + 600
    return Mock.callCallback('pf-ambulancejob:server:monitorAttach', src, target)
end
local function pushes(to)
    local out = {}
    for _, e in ipairs(Mock.clientEventsNamed('pf-ambulancejob:client:Monitor')) do
        if to == nil or e.target == to then out[#out + 1] = e end
    end
    return out
end

BeforeEach = function()
    Mock.reset()
    Mock.clock = 1700000000
    Mock.players, Mock.coords = {}, {}
    Items = {}
    boot()
    online(PATIENT, 'PATCID')
    online(MEDIC, 'MEDCID', 1)   -- paramedic (tier 3: the ECG tier)
    online(EMR, 'EMRCID', 0)     -- tier 1
    online(CIV, 'CIVCID')
    online(MEDIC2, 'MED2CID', 1)
    Mock.coords[PATIENT] = FIELD
    for _, s in ipairs({ MEDIC, EMR, CIV, MEDIC2 }) do Mock.coords[s] = vector3(501.0, 500.0, 30.0) end
    Items[MEDIC] = { aed = true }
    Items[EMR] = { aed = true }
    Items[MEDIC2] = { aed = true }
end

describe('attach', function()
    it('has the ECG gates: tier, the monitor at hand, touch distance, an online patient', function()
        assert_eq(attach(CIV, PATIENT).error, 'no_permission')
        assert_eq(attach(EMR, PATIENT).error, 'no_permission', 'below the ECG tier')
        Items[MEDIC] = {}
        assert_eq(attach(MEDIC, PATIENT).error, 'invalid_state', 'no monitor at hand')
        Items[MEDIC] = { aed = true }
        Mock.coords[MEDIC] = vector3(504.0, 500.0, 30.0)
        assert_eq(attach(MEDIC, PATIENT).error, 'too_far')
        Mock.coords[MEDIC] = vector3(501.0, 500.0, 30.0)
        assert_eq(attach(MEDIC, 99).error, 'not_found')
        assert_eq(attach(MEDIC, MEDIC).error, 'bad_args')
        assert_eq(M.Count(), 0)
        local r = attach(MEDIC, PATIENT)
        assert_true(r.ok, tostring(r.message))
        assert_eq(r.patient, PATIENT)
        assert_true(type(r.vitals.hr) == 'number' and type(r.vitals.spo2) == 'number')
        assert_eq(r.rhythm, 'sinus')
        assert_eq(#pushes(MEDIC), 1, 'one reading at once')
    end)
end)

describe('readings', function()
    it('go to the attached medic only, as (patientSrc, vitals, rhythm), from the engine state', function()
        assert_true(attach(MEDIC, PATIENT).ok)
        Mock.reset()
        assert_eq(M.Tick(os.time()), 1)
        local list = pushes()
        assert_eq(#list, 1)
        assert_eq(list[1].target, MEDIC)
        assert_eq(list[1].args[1], PATIENT)
        local p = Store.Peek('PATCID')
        local v = PFMed.Engine.Vitals(p, os.time())
        assert_eq(list[1].args[2].hr, v.hr)
        assert_eq(list[1].args[2].sbp, v.sbp)
        for _, k in ipairs({ 'hr', 'sbp', 'dbp', 'rr', 'spo2', 'temp' }) do assert_true(list[1].args[2][k] ~= nil, k) end
        assert_eq(list[1].args[3], PFMed.Physiology.Rhythm(v, v.conditions, p.consciousness, p.cause))
        -- in arrest nothing is measurable: a flat reading and the arrest rhythm
        p.consciousness = 'arrest'
        Mock.reset()
        M.Tick(os.time())
        local r = pushes(MEDIC)[1]
        assert_eq(r.args[2].hr, 0)
        assert_eq(r.args[2].spo2, 0)
        assert_true(r.args[3] == 'pea' or r.args[3] == 'vf' or r.args[3] == 'asystole', tostring(r.args[3]))
    end)
end)

describe('detach', function()
    it('by the medic, when apart, when the patient leaves, when the medic goes off duty', function()
        assert_true(attach(MEDIC, PATIENT).ok)
        assert_true(Mock.callCallback('pf-ambulancejob:server:monitorDetach', MEDIC).ok)
        assert_eq(M.Count(), 0)
        assert_eq(Mock.callCallback('pf-ambulancejob:server:monitorDetach', MEDIC).error, 'not_found')
        -- a few metres are fine; further apart takes it off
        assert_true(attach(MEDIC, PATIENT).ok)
        Mock.coords[MEDIC] = vector3(505.0, 500.0, 30.0)
        Mock.reset()
        assert_eq(M.Tick(os.time()), 1)
        Mock.coords[MEDIC] = vector3(510.0, 500.0, 30.0)
        Mock.reset()
        assert_eq(M.Tick(os.time()), 0)
        assert_eq(M.Count(), 0)
        assert_eq(#pushes(), 0)
        -- off duty
        Mock.coords[MEDIC] = vector3(501.0, 500.0, 30.0)
        assert_true(attach(MEDIC, PATIENT).ok)
        Mock.players[MEDIC].PlayerData.job.onduty = false
        assert_eq(M.Tick(os.time()), 0)
        assert_eq(M.Count(), 0)
        -- the patient drops
        Mock.players[MEDIC].PlayerData.job.onduty = true
        PFMed.Diagnosis.ForgetTier(MEDIC)
        assert_true(attach(MEDIC, PATIENT).ok)
        Mock.fireEvent('playerDropped', PATIENT)
        assert_eq(M.Count(), 0)
        -- another character on the same server id is not the patient
        online(PATIENT, 'PATCID')
        assert_true(attach(MEDIC, PATIENT).ok)
        Mock.players[PATIENT] = nil
        online(PATIENT, 'OTHERCID')
        assert_eq(M.Tick(os.time()), 0)
        assert_eq(M.Count(), 0)
    end)
end)

describe('bounds', function()
    it('one monitor per medic, MaxPerPatient per patient, MaxTotal in all; a tick touches only those', function()
        assert_true(attach(MEDIC, PATIENT).ok)
        assert_true(attach(MEDIC, PATIENT).duplicate)
        assert_eq(M.Count(), 1)
        M.Defaults.MaxPerPatient = 1
        assert_eq(attach(MEDIC2, PATIENT).error, 'busy')
        M.Defaults.MaxPerPatient = 4
        M.Defaults.MaxTotal = 1
        assert_eq(attach(MEDIC2, PATIENT).error, 'busy')
        M.Defaults.MaxTotal = 64
        assert_true(attach(MEDIC2, PATIENT).ok)
        Mock.reset()
        assert_eq(M.Tick(os.time()), 2)
        assert_eq(#pushes(), 2)
    end)
end)
