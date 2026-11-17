-- pf-ambulancejob batch 17B: the treatment engine. Items are used up on the server before any
-- effect; scope of practice comes from pf-government qualifications (implied by grade when it is not
-- running); distance, location, patient state and procedure order are checked on the server; a
-- tourniquet left on damages the limb once; CPR pauses the arrest timer only while ticks come from
-- within 1.5 m; a defibrillator needs a shockable rhythm; a repeated req returns the first result;
-- the legacy applyTreatment keys and RevivePlayer still work; stabilising is not recovering.
load_resource('tests/lua/ledger_env.lua')
function IsDuplicityVersion() return true end

function AddEventHandler(name, fn)
    local prev = Mock.eventHandlers[name]
    if prev then Mock.eventHandlers[name] = function(...) prev(...) fn(...) end else Mock.eventHandlers[name] = fn end
end
Bags = {}
function Player(src)
    Bags[src] = Bags[src] or {}
    local b = Bags[src]
    return { state = setmetatable({ set = function(_, k, v) b[k] = v end }, { __index = b }) }
end
Health, Armour = {}, {}
function GetEntityHealth(ped) return Health[ped] or 200 end
function GetPedArmour(ped) return Armour[ped] or 0 end
function GetEntityAttachedTo() return 0 end
Items, RemoveFails, Removed = {}, false, {}
Mock.exportsByResource['pfm-inventory'] = {
    RemoveItem = function(_, src, item, n)
        if RemoveFails then return false end
        local have = (Items[src] or {})[item] or 0
        if have < (n or 1) then return false end
        Items[src][item] = have - (n or 1)
        Removed[#Removed + 1] = { src = src, item = item }
        return true
    end,
    AddItem = function(_, src, item, n) Items[src] = Items[src] or {}; Items[src][item] = (Items[src][item] or 0) + (n or 1) return true end,
}
QBCoreMock.Functions.HasItem = function(src, item, n) return ((Items[src] or {})[item] or 0) >= (n or 1) end
Commands = {}
QBCoreMock.Commands.Add = function(name, _, _, _, fn) Commands[name] = fn end
QBCoreMock.Functions.HasPermission = function() return false end
function GetPlayers() local out = {} for s in pairs(Mock.players) do out[#out + 1] = tostring(s) end return out end
function SetEntityCoords() end
Closes = {}
Mock.exportsByResource['pf-services'] = {
    CreateRequest = function() return { ok = true, id = 1 } end,
    CloseByRef = function(_, t, id, status, reason) Closes[#Closes + 1] = { type = t, id = id, status = status, reason = reason } return { ok = true } end,
    Emit = function() return 1 end,
}
Quals = {}
local GOV = { HasQualification = function(_, cid, qual) return (Quals[cid] or {})[qual] == true, 'granted' end }
Mock.exportsByResource['pfm-core'].RunMigrations = function() return true end

DB = { patients = {}, injuries = {}, events = {}, treatments = {}, nextId = 0 }
Findings, Diagnoses = {}, {}
local function copy(t)
    if type(t) ~= 'table' then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = copy(v) end
    return o
end
local function installFakeSQL()
    local Q = PFMed.SQL
    Q.LoadPatient = function(cid) return copy(DB.patients[cid]) end
    Q.LoadOpenInjuries = function(cid)
        local out = {}
        for _, r in pairs(DB.injuries) do if r.citizenid == cid and r.stage ~= 'recovered' then out[#out + 1] = copy(r) end end
        return out
    end
    Q.FindInjuryByKey = function(key) for _, r in pairs(DB.injuries) do if r.idem_key == key then return { id = r.id, citizenid = r.citizenid, attrs = r.attrs } end end end
    Q.InsertInjury = function(r) DB.nextId = DB.nextId + 1; local row = copy(r); row.id = DB.nextId; DB.injuries[row.id] = row; return row.id end
    Q.UpsertPatients = function(rows) for _, r in ipairs(rows) do DB.patients[r.citizenid] = copy(r) end return true end
    Q.UpsertInjuries = function(rows) for _, r in ipairs(rows) do local o = DB.injuries[r.id] or {}; for k, v in pairs(r) do o[k] = v end; DB.injuries[r.id] = o end return true end
    Q.InsertEvents = function(rows) for _, e in ipairs(rows) do DB.events[#DB.events + 1] = copy(e) end return true end
    Q.Sweep = function() return {} end
    Q.ListFindings = function(cid) local out = {} for _, f in ipairs(Findings) do if f.citizenid == cid then out[#out + 1] = copy(f) end end return out end
    Q.ListDiagnoses = function(cid) local out = {} for _, d in ipairs(Diagnoses) do if d.citizenid == cid then out[#out + 1] = copy(d) end end return out end
    Q.InsertTreatment = function(r) DB.treatments[#DB.treatments + 1] = copy(r); return #DB.treatments end
end

local AJ = '[pfscripts]/pf-ambulancejob/'
local FILES = { AJ .. 'config.lua', AJ .. 'config_medical.lua', AJ .. 'shared/framework.lua' }
for _, f in ipairs({ 'anatomy', 'injuries', 'physiology_model', 'effects_model', 'treatments' }) do FILES[#FILES + 1] = AJ .. 'shared/medical/' .. f .. '.lua' end
FILES[#FILES + 1] = AJ .. 'server/main.lua'
for _, f in ipairs({ 'schema', 'store', 'engine', 'downstate', 'effects', 'api', 'treatment' }) do FILES[#FILES + 1] = AJ .. 'server/medical/' .. f .. '.lua' end
FILES[#FILES + 1] = AJ .. 'server/items.lua'
FILES[#FILES + 1] = AJ .. 'server/treatment.lua'

local D, Store, Engine, TX
local function boot()
    Mock.eventHandlers, Mock.netHandlers, Mock.netHandlerList, Mock.callbacks, Mock.useables = {}, {}, {}, {}, {}
    PFMed, PFEmsRequests, PFMedItems = nil, nil, nil
    DB = { patients = {}, injuries = {}, events = {}, treatments = {}, nextId = 0 }
    LedgerEnv.load('pf-ambulancejob', FILES)
    installFakeSQL()
    Mock.exportsByResource['pf-ambulancejob'] = Mock.exportsByResource['__self']
    D, Store, Engine, TX = PFMed.Down, PFMed.Store, PFMed.Engine, PFMed.Treat
    assert(PFMed.Schema.Start(), 'schema ready')
end

local PATIENT, MEDIC, EMR, CIV, DOC = 1, 2, 3, 4, 5
local function online(src, cid, job)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.money = { cash = 0, bank = 5000 }
    p.PlayerData.metadata.injail = 0
    if job then p.PlayerData.job = job end
    Mock.fireEvent('QBCore:Server:PlayerLoaded', nil, p)
    return p
end
local function advance(s) Mock.clock = Mock.clock + s end
local function patient() return Store.Peek('PATIENTCID') end
local function level() return patient().consciousness end
local function injury(id) return patient().injuries[id] end
local function wound(spec)
    spec.mechanism = spec.mechanism or 'edged'
    local inj = assert(Engine.AddInjury('PATIENTCID', spec, {}), 'injury added')
    return inj.id
end
local function treat(src, data)
    data.target = data.target or PATIENT
    return Mock.callCallback('pf-ambulancejob:server:treat', src, data)
end
local function goDown()
    Health[PATIENT] = 0
    Mock.fireNet('pf-ambulancejob:server:ReportDown', PATIENT, { nonce = 'n1', kind = 'laststand' })
    Health[PATIENT] = 150
end
local function events(name)
    local out = {}
    for _, e in ipairs(Mock.serverEvents) do if e.name == name then out[#out + 1] = e end end
    return out
end
local function lastToken(src)
    local list = Mock.clientEventsNamed('pf-ambulancejob:client:Revive')
    for i = #list, 1, -1 do if list[i].target == src then return list[i].args[1], list[i].args[2] end end
end
local HOSPITAL

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.clock = 1700000000
    Mock.players, Mock.coords, Mock.aces, Mock.dropped, Mock.models, Mock.vehicleOf = {}, {}, {}, {}, {}, {}
    Mock.invokingResource = nil
    Health, Armour, Items, Bags, Closes, Findings, Diagnoses, Removed = {}, {}, {}, {}, {}, {}, {}, {}
    RemoveFails = false
    Mock.exportsByResource['pf-government'] = GOV
    Quals = {
        MEDICCID = { emr = true, emt = true, paramedic = true },
        EMRCID = { emr = true },
        DOCCID = { emr = true, emt = true, paramedic = true, nurse = true, physician = true },
    }
    GetAllVehicles = nil
    boot()
    Engine.Random = function() return 0.5 end
    TX.Random = function() return 0.99 end
    online(PATIENT, 'PATIENTCID')
    online(MEDIC, 'MEDICCID', { name = 'ambulance', type = 'ems', onduty = true, grade = { level = 1 } })
    online(EMR, 'EMRCID', { name = 'ambulance', type = 'ems', onduty = true, grade = { level = 0 } })
    online(CIV, 'CIVCID')
    online(DOC, 'DOCCID', { name = 'ambulance', type = 'ems', onduty = true, grade = { level = 2 } })
    Mock.coords[PATIENT] = vector3(100.0, 100.0, 30.0)
    Mock.coords[MEDIC] = vector3(101.0, 100.0, 30.0)
    Mock.coords[EMR] = vector3(100.0, 101.0, 30.0)
    Mock.coords[CIV] = vector3(99.0, 100.0, 30.0)
    Mock.coords[DOC] = vector3(100.0, 99.0, 30.0)
    HOSPITAL = Config.Locations['hospital'][1]['location']
end

describe('items are used up on the server before any effect', function()
    it('RemoveItem returning false: no effect, no log, nothing changed', function()
        local id = wound({ type = 'laceration', subtype = 'deep', region = 'forearm_l', severity = 3 })
        Items[MEDIC] = { pressure_dressing = 1 }
        RemoveFails = true
        local res = treat(MEDIC, { action = 'pressure_dressing', req = 'a1' })
        assert_false(res.ok)
        assert_eq(res.error, 'missing_item')
        assert_eq(injury(id).treatments.pressure, nil, 'no dressing without the item')
        assert_eq(#DB.treatments, 0)
        assert_eq(#events('pf-ambulancejob:server:treatmentApplied'), 0)
        RemoveFails = false
        advance(5)
        res = treat(MEDIC, { action = 'pressure_dressing', req = 'a2' })
        assert_true(res.ok)
        assert_eq(injury(id).treatments.pressure, true)
        assert_eq(Items[MEDIC].pressure_dressing, 0)
        assert_eq(#DB.treatments, 1)
        assert_eq(DB.treatments[1].action, 'pressure_dressing')
        assert_eq(DB.treatments[1].by_cid, 'MEDICCID')
        assert_eq(DB.treatments[1].location, 'field')
        local ev = events('pf-ambulancejob:server:treatmentApplied')
        assert_eq(#ev, 1)
        assert_eq(ev[1].args[1], 'PATIENTCID')
        assert_eq(ev[1].args[2].action, 'pressure_dressing')
        assert_eq(ev[1].args[2].injuryId, id)
    end)
    it('a missing item refuses before anything happens; no wound to treat uses nothing', function()
        local res = treat(MEDIC, { action = 'pressure_dressing' })
        assert_eq(res.error, 'missing_item')
        Items[MEDIC] = { pressure_dressing = 1 }
        advance(5)
        res = treat(MEDIC, { action = 'pressure_dressing' })
        assert_eq(res.error, 'invalid_state', 'nothing bleeds')
        assert_eq(Items[MEDIC].pressure_dressing, 1)
    end)
    it('a hidden-injury action uses the item even when nothing is found (no probing for injuries)', function()
        Items[MEDIC] = { splint = 1 }
        local res = treat(MEDIC, { action = 'splint', region = 'lower_leg_r' })
        assert_true(res.ok)
        assert_eq(res.result.changed.result, 'no_effect')
        assert_eq(Items[MEDIC].splint, 0)
        local id = wound({ type = 'fracture', subtype = 'closed', structure = 'tibia_l', severity = 3, mechanism = 'fall' })
        Items[MEDIC] = { splint = 1 }
        advance(10)
        res = treat(MEDIC, { action = 'splint', region = 'lower_leg_l' })
        assert_true(res.ok)
        assert_eq(injury(id).treatments.splinted, true)
        assert_eq(injury(id).stage, 'stabilized')
        assert_eq(res.result.changed.result, 'applied')
    end)
end)

describe('scope of practice, distance and location', function()
    it('an EMR cannot decompress a chest; a paramedic can (with a finding)', function()
        local id = wound({ type = 'organ_trauma', subtype = 'tension', structure = 'lung_l', severity = 3, mechanism = 'firearm' })
        Items[EMR] = { decompression_needle = 1 }
        Items[MEDIC] = { decompression_needle = 1 }
        local res = treat(EMR, { action = 'needle_decompression' })
        assert_eq(res.error, 'no_permission')
        assert_eq(Items[EMR].decompression_needle, 1)
        res = treat(MEDIC, { action = 'needle_decompression' })
        assert_eq(res.error, 'invalid_state', 'no finding supports it')
        assert_eq(Items[MEDIC].decompression_needle, 1)
        Findings[1] = { citizenid = 'PATIENTCID', sign = 'absent_breath_sounds', certainty = 'suspected', structure = 'lung_l', at = os.time() }
        advance(10)
        res = treat(MEDIC, { action = 'needle_decompression' })
        assert_true(res.ok)
        assert_eq(Items[MEDIC].decompression_needle, 0)
        assert_eq(injury(id).treatments.decompressed, true)
        assert_eq(injury(id).stage, 'stabilized')
    end)
    it('a granted qualification counts; without pf-government the grade implies it', function()
        Items[EMR] = { iv_kit = 2 }
        assert_eq(treat(EMR, { action = 'iv_access' }).error, 'no_permission')
        Quals.EMRCID = { emr = true, emt = true, paramedic = true }
        advance(20) -- past the tier cache
        assert_true(treat(EMR, { action = 'iv_access' }).ok, 'granted paramedic')
        Mock.exportsByResource['pf-government'] = nil
        Quals = {}
        boot()
        online(PATIENT, 'PATIENTCID'); online(MEDIC, 'MEDICCID', { name = 'ambulance', type = 'ems', onduty = true, grade = { level = 1 } })
        online(EMR, 'EMRCID', { name = 'ambulance', type = 'ems', onduty = true, grade = { level = 0 } })
        Items[MEDIC], Items[EMR] = { iv_kit = 1 }, { iv_kit = 1 }
        assert_eq(treat(EMR, { action = 'iv_access' }).error, 'no_permission', 'grade 0 implies emr only')
        assert_true(treat(MEDIC, { action = 'iv_access' }).ok, 'grade 1 implies paramedic')
    end)
    it('off-duty medics and civilians get civilian scope only', function()
        wound({ type = 'laceration', subtype = 'deep', region = 'forearm_l', severity = 3 })
        Items[CIV] = { hemostatic_gauze = 1, pressure_dressing = 1 }
        assert_eq(treat(CIV, { action = 'hemostatic_gauze' }).error, 'no_permission')
        assert_true(treat(CIV, { action = 'pressure_dressing' }).ok, 'anyone can press on a wound')
        Mock.players[MEDIC].PlayerData.job.onduty = false
        Items[MEDIC] = { hemostatic_gauze = 1 }
        assert_eq(treat(MEDIC, { action = 'hemostatic_gauze' }).error, 'not_on_duty')
    end)
    it('the patient must be within 2.5 m (server positions)', function()
        wound({ type = 'laceration', subtype = 'deep', region = 'forearm_l', severity = 3 })
        Items[MEDIC] = { pressure_dressing = 1 }
        Mock.coords[MEDIC] = vector3(103.0, 100.0, 30.0)
        assert_eq(treat(MEDIC, { action = 'pressure_dressing' }).error, 'too_far')
        assert_eq(Items[MEDIC].pressure_dressing, 1)
    end)
    it('hospital-only care is refused in the field; blood needs an ambulance or a hospital', function()
        local id = wound({ type = 'laceration', subtype = 'deep', region = 'forearm_l', severity = 2 })
        Items[DOC] = { suture_kit = 1, blood_onegative = 1, iv_kit = 1 }
        assert_eq(treat(DOC, { action = 'sutures' }).error, 'invalid_state')
        assert_true(treat(DOC, { action = 'iv_access' }).ok)
        advance(10)
        assert_eq(treat(DOC, { action = 'blood_onegative' }).error, 'invalid_state', 'no rig nearby')
        -- an ambulance parks next to them
        Mock.models[900] = GetHashKey('ambulance')
        Mock.coords[900] = vector3(103.0, 99.0, 30.0)
        GetAllVehicles = function() return { 900 } end
        advance(10)
        assert_true(treat(DOC, { action = 'blood_onegative' }).ok)
        assert_eq(DB.treatments[#DB.treatments].location, 'rig')
        -- at the hospital the wound is closed once the bleeding is controlled
        Mock.coords[PATIENT] = HOSPITAL
        Mock.coords[DOC] = vector3(HOSPITAL.x + 1.0, HOSPITAL.y, HOSPITAL.z)
        advance(15)
        assert_eq(treat(DOC, { action = 'sutures' }).error, 'invalid_state', 'still bleeding')
        Items[DOC].hemostatic_gauze = 1
        Items[DOC].pressure_dressing = 1
        assert_true(treat(DOC, { action = 'pressure_dressing' }).ok)
        advance(10)
        assert_true(treat(DOC, { action = 'hemostatic_gauze' }).ok)
        advance(15)
        local res = treat(DOC, { action = 'sutures' })
        assert_true(res.ok)
        assert_eq(injury(id).stage, 'treated')
        assert_eq(Items[DOC].suture_kit, 0)
        assert_eq(DB.treatments[#DB.treatments].location, 'hospital')
    end)
end)

describe('procedure order and stabilisation', function()
    it('fluids and IV drugs need IV access first', function()
        Items[MEDIC] = { saline_bag = 1, iv_kit = 1, txa = 1 }
        assert_eq(treat(MEDIC, { action = 'fluids' }).error, 'invalid_state')
        assert_eq(Items[MEDIC].saline_bag, 1)
        assert_true(treat(MEDIC, { action = 'iv_access' }).ok)
        advance(10)
        local before = patient().blood_ml
        patient().blood_ml = 3500
        assert_true(treat(MEDIC, { action = 'fluids' }).ok)
        assert_near(patient().blood_ml, 4000, 1)
        assert_true(patient().hgb_factor < 1, 'saline dilutes')
        advance(10)
        assert_true(treat(MEDIC, { action = 'txa' }).ok)
        advance(10)
        Items[MEDIC].txa = 1
        assert_eq(treat(MEDIC, { action = 'txa' }).error, 'invalid_state', 'no second dose this soon')
        assert_eq(Items[MEDIC].txa, 1)
        assert_true(before > 0)
    end)
    it('a tourniquet controls an arterial bleed (stabilized) but heals nothing and gives no blood back', function()
        local id = wound({ type = 'laceration', subtype = 'arterial', region = 'thigh_l', severity = 3 })
        advance(5); Engine.Tick(os.time())
        local blood = patient().blood_ml
        assert_true(blood < 5000)
        Items[CIV] = { tourniquet = 1 }
        local res = treat(CIV, { action = 'tourniquet', region = 'thigh_l' })
        assert_true(res.ok)
        local inj = injury(id)
        assert_true(type(inj.treatments.tourniquet) == 'number')
        assert_eq(inj.stage, 'stabilized')
        assert_true(inj.stage ~= 'recovered' and inj.stage ~= 'treated')
        assert_eq(patient().blood_ml, blood, 'no blood restored')
        assert_eq(Engine.Bleeding(patient(), os.time()).total, 0)
        assert_eq(patient().stage, 'stabilized')
    end)
    it('pressure alone does not control an arterial bleed', function()
        local id = wound({ type = 'laceration', subtype = 'arterial', region = 'thigh_l', severity = 3 })
        Items[MEDIC] = { pressure_dressing = 1 }
        assert_true(treat(MEDIC, { action = 'pressure_dressing' }).ok)
        assert_eq(injury(id).stage, 'injured')
        assert_true(Engine.Bleeding(patient(), os.time()).total > 1)
    end)
    it('a tourniquet left on too long damages the limb once (keyed)', function()
        local id = wound({ type = 'laceration', subtype = 'arterial', region = 'thigh_l', severity = 3 })
        Items[MEDIC] = { tourniquet = 1 }
        assert_true(treat(MEDIC, { action = 'tourniquet', region = 'thigh_l' }).ok)
        local function crushes()
            local n = 0
            for _, inj in pairs(patient().injuries) do if inj.type == 'crush' then n = n + 1 end end
            return n
        end
        advance(Config.Medical.Treatment and Config.Medical.Treatment.TourniquetLimitSeconds or 7100)
        TX.Tick(os.time())
        assert_eq(crushes(), 0, 'not yet')
        advance(200)
        TX.Tick(os.time())
        assert_eq(crushes(), 1)
        assert_eq(injury(id).treatments.tq_damage, true)
        TX.Tick(os.time())
        advance(600)
        TX.Tick(os.time())
        assert_eq(crushes(), 1, 'once')
    end)
end)

describe('CPR and defibrillation', function()
    local function arrestByBleeding()
        goDown()
        local p = patient()
        p.blood_ml = 2300
        Engine.Evaluate(p, os.time())
        assert_eq(level(), 'arrest')
    end
    it('ticks from within 1.5 m pause the arrest timer; from 2 m they do not', function()
        arrestByBleeding()
        Mock.coords[MEDIC] = vector3(101.2, 100.0, 30.0)
        for _ = 1, 80 do
            advance(5)
            local res = Mock.callCallback('pf-ambulancejob:server:cprTick', MEDIC, PATIENT)
            assert_true(res.ok)
            Engine.Tick(os.time())
        end
        assert_eq(level(), 'arrest', 'CPR kept them from dying for 400 s')
        Mock.coords[MEDIC] = vector3(102.0, 100.0, 30.0)
        for _ = 1, 70 do
            advance(5)
            local res = Mock.callCallback('pf-ambulancejob:server:cprTick', MEDIC, PATIENT)
            assert_eq(res.error, 'too_far')
            Engine.Tick(os.time())
        end
        assert_eq(level(), 'dead')
    end)
    it('a provider who moves more than 1 m between ticks does not count', function()
        arrestByBleeding()
        Mock.coords[MEDIC] = vector3(101.0, 100.0, 30.0)
        advance(5)
        assert_true(Mock.callCallback('pf-ambulancejob:server:cprTick', MEDIC, PATIENT).ok)
        local marked = patient().cpr_last_at
        Mock.coords[MEDIC] = vector3(99.0, 100.5, 30.0)
        advance(5)
        local res = Mock.callCallback('pf-ambulancejob:server:cprTick', MEDIC, PATIENT)
        assert_false(res.ok)
        assert_eq(patient().cpr_last_at, marked)
    end)
    it('the defibrillator refuses a non-shockable rhythm (nothing happens)', function()
        arrestByBleeding()
        Items[MEDIC] = { aed = 1 }
        local res = treat(MEDIC, { action = 'defibrillate' })
        assert_eq(res.error, 'invalid_state')
        assert_true(res.message:find('No shock') ~= nil)
        assert_eq(level(), 'arrest')
        assert_eq(Items[MEDIC].aed, 1, 'equipment is never used up')
    end)
    it('a shockable rhythm (high-voltage arrest) converts with a shock', function()
        goDown()
        local id = wound({ type = 'electrical', subtype = 'high_voltage', severity = 5, mechanism = 'electrical' })
        assert_eq(level(), 'arrest')
        assert_eq(TX.Rhythm(patient(), os.time()), 'vf')
        Items[CIV] = { aed = 1 }
        TX.Random = function() return 0.0 end
        local res = treat(CIV, { action = 'defibrillate' })
        assert_true(res.ok)
        assert_eq(level(), 'unconscious')
        assert_eq(injury(id).severity, 4)
        assert_eq(DB.treatments[#DB.treatments].result, 'rosc')
        advance(15)
        assert_eq(treat(CIV, { action = 'defibrillate' }).error, 'invalid_state', 'they have a pulse now')
    end)
    it('CPR on corrected causes can bring circulation back; then the medic revives without healing', function()
        goDown()
        local p = patient()
        p.blood_ml = 2300
        Engine.Evaluate(p, os.time())
        assert_eq(level(), 'arrest')
        TX.Random = function() return 0.0 end
        advance(5)
        Mock.callCallback('pf-ambulancejob:server:cprTick', MEDIC, PATIENT)
        advance(5)
        local res = Mock.callCallback('pf-ambulancejob:server:cprTick', MEDIC, PATIENT)
        assert_eq(res.result.changed.rosc, nil, 'blood loss is still uncorrected')
        -- blood given through IV access
        Items[MEDIC] = { iv_kit = 1, blood_onegative = 2 }
        Mock.coords[PATIENT] = HOSPITAL
        Mock.coords[MEDIC] = vector3(HOSPITAL.x + 1.0, HOSPITAL.y, HOSPITAL.z)
        assert_true(treat(MEDIC, { action = 'iv_access' }).ok)
        advance(10)
        assert_true(treat(MEDIC, { action = 'blood_onegative' }).ok)
        advance(10)
        assert_true(treat(MEDIC, { action = 'blood_onegative' }).ok)
        advance(5)
        Mock.callCallback('pf-ambulancejob:server:cprTick', MEDIC, PATIENT)
        advance(5)
        res = Mock.callCallback('pf-ambulancejob:server:cprTick', MEDIC, PATIENT)
        assert_eq(res.result.changed.rosc, true)
        assert_eq(level(), 'unconscious')
        local blood = patient().blood_ml
        Items[MEDIC].firstaid = 1
        advance(10)
        res = treat(MEDIC, { action = 'first_aid_revive' })
        assert_true(res.ok, tostring(res.message))
        local token, mode = lastToken(PATIENT)
        assert_eq(mode, 'ems')
        Health[PATIENT] = 200
        advance(2)
        Mock.fireNet('pf-ambulancejob:server:ReviveApplied', PATIENT, token)
        assert_true(level() == 'alert' or level() == 'altered')
        assert_near(patient().blood_ml, blood, 5, 'the revive restores no blood')
    end)
end)

describe('dedupe and legacy entry points', function()
    it('the same req returns the first result and uses one item', function()
        wound({ type = 'laceration', subtype = 'deep', region = 'forearm_l', severity = 3 })
        wound({ type = 'laceration', subtype = 'deep', region = 'forearm_r', severity = 3 })
        Items[MEDIC] = { pressure_dressing = 2 }
        local a = treat(MEDIC, { action = 'pressure_dressing', req = 'same-1' })
        advance(10)
        local b = treat(MEDIC, { action = 'pressure_dressing', req = 'same-1' })
        assert_true(a.ok)
        assert_true(b.ok)
        assert_eq(b.duplicate, true)
        assert_eq(Items[MEDIC].pressure_dressing, 1)
        assert_eq(#DB.treatments, 1)
        advance(31)
        local c = treat(MEDIC, { action = 'pressure_dressing', req = 'same-1' })
        assert_true(c.ok and not c.duplicate, 'after 30 s it is a new request')
        assert_eq(Items[MEDIC].pressure_dressing, 0)
    end)
    it('bad requests are refused: unknown action, bad req, self where not allowed', function()
        assert_eq(treat(MEDIC, { action = 'teleport' }).error, 'bad_args')
        assert_eq(treat(MEDIC, { action = 'pressure_dressing', req = string.rep('x', 80) }).error, 'bad_args')
        assert_eq(treat(MEDIC, { action = 'needle_decompression', target = MEDIC }).error, 'bad_args')
        assert_eq(Mock.callCallback('pf-ambulancejob:server:treat', MEDIC, 'junk').error, 'bad_args')
    end)
    it('applyTreatment keys from the EMS MDT panel still work (bandage -> pressure dressing)', function()
        local id = wound({ type = 'laceration', subtype = 'deep', region = 'forearm_l', severity = 3 })
        Items[MEDIC] = { bandage = 1 }
        Mock.fireNet('pf-ambulancejob:server:applyTreatment', MEDIC, PATIENT, 'bandage')
        assert_eq(injury(id).treatments.pressure, true)
        assert_eq(Items[MEDIC].bandage, 0)
        assert_eq(DB.treatments[1].action, 'pressure_dressing')
        local note = Mock.clientEventsNamed('QBCore:Notify')
        assert_eq(note[#note].args[2], 'success')
        Mock.fireNet('pf-ambulancejob:server:applyTreatment', MEDIC, PATIENT, 'teleport')
        note = Mock.clientEventsNamed('QBCore:Notify')
        assert_eq(note[#note].args[2], 'error')
    end)
    it('/heal (TreatWounds) is basic wound care: a bandage on a visible wound, no full heal', function()
        local id = wound({ type = 'laceration', subtype = 'superficial', region = 'forearm_l', severity = 1 })
        Items[MEDIC] = { bandage = 1 }
        Mock.fireNet('hospital:server:TreatWounds', CIV, PATIENT)
        assert_eq(injury(id).treatments.dressed, nil, 'a citizen has no wound care')
        Mock.fireNet('hospital:server:TreatWounds', MEDIC, PATIENT)
        assert_eq(injury(id).treatments.dressed, true)
        assert_eq(injury(id).stage, 'treated', 'a minor wound is done in the field')
        assert_eq(#Mock.clientEventsNamed('hospital:client:HealInjuries'), 0)
        local closed = false
        for _, c in ipairs(Closes) do if c.type == 'citizen:ems.patient' and c.status == 'completed' then closed = true end end
        assert_true(closed)
    end)
    it('RevivePlayer from a medic: revive when unconscious (kit used), never on the dead', function()
        goDown()
        Items[MEDIC] = { firstaid = 2 }
        local blood = patient().blood_ml
        Mock.fireNet('hospital:server:RevivePlayer', MEDIC, PATIENT)
        local token, mode = lastToken(PATIENT)
        assert_true(type(token) == 'string')
        assert_eq(mode, 'ems')
        assert_eq(Items[MEDIC].firstaid, 1)
        assert_eq(patient().blood_ml, blood)
        -- a patient who would not stay awake is refused (bleeding out)
        Mock.reset()
        boot()
        online(PATIENT, 'PATIENTCID'); online(MEDIC, 'MEDICCID', { name = 'ambulance', type = 'ems', onduty = true, grade = { level = 1 } })
        Items[MEDIC] = { firstaid = 1 }
        goDown()
        patient().blood_ml = 2450
        advance(2)
        Mock.fireNet('hospital:server:RevivePlayer', MEDIC, PATIENT)
        assert_eq(lastToken(PATIENT), nil)
        assert_eq(Items[MEDIC].firstaid, 1, 'nothing used for a refused revive')
        D.SetLevel(PATIENT, 'dead', 'laststand', 'test')
        advance(2)
        Mock.fireNet('hospital:server:RevivePlayer', MEDIC, PATIENT)
        assert_eq(lastToken(PATIENT), nil)
        assert_eq(#Mock.dropped, 0)
    end)
end)
