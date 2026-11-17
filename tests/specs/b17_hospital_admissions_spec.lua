-- pf-ambulancejob hospital core (batch 17E): check-in only at the reception desk, triage colours on
-- the patient record (pf-justice screening), server-held beds (the old jail-bed and zone-name
-- bugs), admit / discharge / transfer by medical tier, discharge orders (restrictions + calendar),
-- the respawn path into the ED with injuries kept, left-AMA, the exports and the AI care rule
-- (below MinStaff AND after the wait; x2 time; never on a down patient; surgery wait).
load_resource('tests/lua/ledger_env.lua')
function IsDuplicityVersion() return true end

-- FiveM runs every handler of an event; the mock keeps one per name, so this spec chains them
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
Health = {}
function GetEntityHealth(ped) return Health[ped] or 200 end
function GetPedArmour() return 0 end
function GetEntityAttachedTo() return 0 end
function SetEntityCoords() end
Commands = {}
QBCoreMock.Commands.Add = function(name, _, _, _, fn) Commands[name] = fn end
QBCoreMock.Functions.HasItem = function() return true end
Mock.exportsByResource['pfm-inventory'] = { RemoveItem = function() return true end, AddItem = function() return true end }
Mock.exportsByResource['pfm-core'].RunMigrations = function() return true end

-- pf-services, pf-citizen and pfm-phone record what they were asked
Requests, Closes, Calendar, Mails, Invoices = {}, {}, {}, {}, {}
Mock.exportsByResource['pf-services'] = {
    CreateRequest = function(_, opts) Requests[#Requests + 1] = opts return { ok = true, id = #Requests } end,
    CloseByRef = function(_, t, id, status, reason) Closes[#Closes + 1] = { type = t, id = id, status = status, reason = reason } return { ok = true } end,
    FindOpenByRef = function(_, t, id) return AcceptedRef[t .. ':' .. tostring(id)] end,
    RegisterRequestKind = function() return true end,
    RegisterRequestHandler = function(_, kind, handler) RequestHandlers[kind] = handler return true end,
    Emit = function() return 1 end,
}
AcceptedRef, RequestHandlers = {}, {}
Mock.exportsByResource['pf-citizen'] = {
    AddCalendarEvent = function(_, scope, owner, p) Calendar[#Calendar + 1] = { scope = scope, owner = owner, p = p } return #Calendar end,
    SendMail = function(_, cid, opts) Mails[#Mails + 1] = { cid = cid, opts = opts } return #Mails end,
}
Mock.exportsByResource['pfm-phone'] = {
    CreateInvoice = function(_, data) Invoices[#Invoices + 1] = data return 500 + #Invoices end,
}

local function copy(t)
    if type(t) ~= 'table' then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = copy(v) end
    return o
end

-- in-memory tables for the medical store and the hospital (their SQL runs in the real-DB specs)
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

    local S = PFHospital.SQL
    S.InsertAdmission = function(r) DB.nextAdm = DB.nextAdm + 1; local row = copy(r); row.id = DB.nextAdm; DB.adm[row.id] = row; return row.id end
    S.FindAdmissionByKey = function(key) for _, r in pairs(DB.adm) do if r.idem_key == key then return copy(r) end end end
    S.GetAdmission = function(id) return copy(DB.adm[id]) end
    S.LoadOpenAdmissions = function()
        local out = {}
        for _, r in pairs(DB.adm) do if PFHospital.Admissions.OPEN[r.state] then out[#out + 1] = copy(r) end end
        table.sort(out, function(a, b) return a.id < b.id end)
        return out
    end
    S.ListAdmissions = function(fid) local out = {} for _, r in pairs(DB.adm) do if r.hospital_id == fid then out[#out + 1] = copy(r) end end return out end
    S.MoveAdmission = function(id, from, row)
        local r = DB.adm[id]
        if not r or r.state ~= from then return 0 end
        for k, v in pairs(row) do r[k] = v end
        for _, k in ipairs({ 'bed_id', 'triage', 'dept' }) do if row[k] == nil then r[k] = nil end end
        return 1
    end
    S.InsertRestriction = function(r) DB.restrictions[#DB.restrictions + 1] = copy(r) return #DB.restrictions end
    S.FindBillByAdmission = function(id) for _, b in pairs(DB.bills) do if b.admission_id == id then return copy(b) end end end
    S.GetBill = function(id) return copy(DB.bills[id]) end
    S.InsertBill = function(r) DB.nextBill = DB.nextBill + 1; local b = copy(r); b.id = DB.nextBill; b.attempt = 0; DB.bills[b.id] = b; return b.id end
    S.InsertBillLines = function(id, lines) for _, l in ipairs(lines) do local c = copy(l); c.bill_id = id; DB.lines[#DB.lines + 1] = c end return true end
    S.BillLines = function(id) local out = {} for _, l in ipairs(DB.lines) do if l.bill_id == id then out[#out + 1] = copy(l) end end return out end
    S.MoveBill = function(id, from, attempt, r)
        local b = DB.bills[id]
        if not b or b.state ~= from or b.attempt ~= attempt then return 0 end
        for _, k in ipairs({ 'state', 'attempt', 'pay_key', 'invoice_id', 'settled_at', 'next_check_at' }) do b[k] = r[k] end
        return 1
    end
    S.DueBills = function(at)
        local out = {}
        for _, b in pairs(DB.bills) do
            if (b.state == 'open' or b.state == 'charging' or b.state == 'payment_pending') and (b.next_check_at == nil or b.next_check_at <= at) then out[#out + 1] = { id = b.id } end
        end
        return out
    end
    S.TreatmentsFor = function(cid, admId, from, to)
        local out = {}
        for _, t in ipairs(DB.treatments) do
            if t.citizenid == cid and (t.admission_id == admId or (t.admission_id == nil and (t.location == 'hospital' or t.location == 'or') and t.at >= from and t.at <= to)) then out[#out + 1] = copy(t) end
        end
        return out
    end
    S.InsertTreatment = function(r) local c = copy(r); c.id = #DB.treatments + 1; c.location = 'hospital'; DB.treatments[#DB.treatments + 1] = c return c.id end
end

local AJ = '[pfscripts]/pf-ambulancejob/'
local FILES = { AJ .. 'config.lua', AJ .. 'config_medical.lua', AJ .. 'config_hospital.lua', AJ .. 'shared/framework.lua' }
for _, f in ipairs({ 'anatomy', 'injuries', 'physiology_model', 'effects_model' }) do FILES[#FILES + 1] = AJ .. 'shared/medical/' .. f .. '.lua' end
FILES[#FILES + 1] = AJ .. 'server/main.lua'
for _, f in ipairs({ 'schema', 'store', 'engine', 'downstate', 'effects', 'api' }) do FILES[#FILES + 1] = AJ .. 'server/medical/' .. f .. '.lua' end
for _, f in ipairs({ 'facility', 'beds', 'admissions', 'billing', 'ai_care' }) do FILES[#FILES + 1] = AJ .. 'server/hospital/' .. f .. '.lua' end

local H, D, Store, Engine
local function boot()
    Mock.eventHandlers, Mock.netHandlers, Mock.netHandlerList, Mock.callbacks = {}, {}, {}, {}
    PFMed, PFEmsRequests, PFHospital, RespawnPlayer = nil, nil, nil, nil
    LedgerEnv.load('pf-ambulancejob', FILES)
    installFakeSQL()
    Mock.exportsByResource['pf-ambulancejob'] = Mock.exportsByResource['__self']
    H, D, Store, Engine = PFHospital, PFMed.Down, PFMed.Store, PFMed.Engine
    QBCore = QBCoreMock
    assert(PFMed.Schema.Start(), 'schema ready')
    assert(H.Admissions.Start(), 'hospital ready')
end

local PATIENT, MEDIC, NURSE, CIV = 1, 2, 3, 4
local PB = Config and nil
local function online(src, cid)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.money = { cash = 0, bank = 5000 }
    p.PlayerData.metadata.injail = 0
    p.ClearInventory = function() p.cleared = true end
    Mock.fireEvent('QBCore:Server:PlayerLoaded', nil, p)
    return p
end
local function staff(src, grade, onduty)
    Mock.players[src].PlayerData.job = { name = 'ambulance', type = 'ems', onduty = onduty ~= false, grade = { level = grade } }
end
local function advance(s) Mock.clock = Mock.clock + s end
local function reception(id) return Config.Hospital.Facilities[id or 'pillbox'].reception.coords end
local function bedCoords(fid, bedId) local b = H.Beds.Def(fid, bedId) return vector3(b.coords.x, b.coords.y, b.coords.z) end
local function cb(name, src, ...) return Mock.callCallback('pf-ambulancejob:server:' .. name, src, ...) end
local function wound(cid, spec)
    local inj = Engine.AddInjury(cid, spec, { source = 'export', actor = { kind = 'system', label = 'spec' } })
    assert(inj, 'injury added')
    return inj
end
local function lastBed(src)
    local list = Mock.clientEventsNamed('pf-ambulancejob:client:Bed')
    for i = #list, 1, -1 do if list[i].target == src then return list[i].args[1], list[i].args[2] end end
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.clock = 1700000000
    Mock.players, Mock.coords, Mock.aces = {}, {}, {}
    Mock.invokingResource = nil
    Health, Bags, Requests, Closes, Calendar, Mails, Invoices, AcceptedRef, RequestHandlers = {}, {}, {}, {}, {}, {}, {}, {}, {}
    DB = { patients = {}, injuries = {}, events = {}, nextId = 0, adm = {}, nextAdm = 0, restrictions = {}, bills = {}, nextBill = 0, lines = {}, treatments = {} }
    FakeDB.society('ambulance', 0)
    boot()
    Engine.Random = function() return 0.5 end
    H.AI.Random = function() return 0.99 end
    online(PATIENT, 'PATIENTCID')
    online(MEDIC, 'MEDICCID')
    online(NURSE, 'NURSECID')
    online(CIV, 'CIVCID')
    Mock.coords[PATIENT] = vector3(100.0, 100.0, 30.0)
    Mock.coords[MEDIC] = vector3(0.0, 0.0, 0.0)
    Mock.coords[NURSE] = vector3(0.0, 0.0, 0.0)
    Mock.coords[CIV] = vector3(50.0, 50.0, 30.0)
end

describe('check-in', function()
    it('is refused away from the reception desk and works at it', function()
        local res = cb('checkIn', PATIENT, 'pillbox')
        assert_false(res.ok)
        assert_eq(res.error, 'too_far')
        Mock.coords[PATIENT] = reception('pillbox')
        advance(3)
        res = cb('checkIn', PATIENT, 'pillbox')
        assert_true(res.ok, tostring(res.message))
        assert_eq(res.mode, 'staff')
        assert_eq(DB.adm[res.admissionId].state, 'checked_in')
        assert_eq(DB.adm[res.admissionId].hospital_id, 'pillbox')
        assert_eq(#Requests, 1, 'a Dispatch request for the waiting patient')
        assert_eq(Requests[1].ref.type, 'hospital_admission')
    end)
    it('another hospital\'s desk does not count, an unknown id is refused, the legacy index maps', function()
        Mock.coords[PATIENT] = reception('paleto')
        assert_eq(cb('checkIn', PATIENT, 'pillbox').error, 'too_far')
        advance(3)
        assert_eq(cb('checkIn', PATIENT, 'nowhere').error, 'bad_args')
        advance(3)
        local res = cb('checkIn', PATIENT, 2)
        assert_true(res.ok)
        assert_eq(DB.adm[res.admissionId].hospital_id, 'paleto')
    end)
    it('the prison infirmary takes no walk-ins', function()
        Mock.coords[PATIENT] = vector3(1766.9, 2594.8, 45.66)
        assert_eq(cb('checkIn', PATIENT, 'bolingbroke').error, 'no_permission')
    end)
    it('a down patient cannot check in; a second check-in returns the same admission', function()
        Mock.coords[PATIENT] = reception()
        Health[PATIENT] = 0
        Mock.fireNet('pf-ambulancejob:server:ReportDown', PATIENT, { nonce = 'n', kind = 'laststand' })
        assert_eq(cb('checkIn', PATIENT, 'pillbox').error, 'invalid_state')
        Mock.coords[CIV] = reception()
        local a = cb('checkIn', CIV, 'pillbox')
        advance(3)
        local b = cb('checkIn', CIV, 'pillbox')
        assert_true(b.duplicate)
        assert_eq(b.admissionId, a.admissionId)
        assert_eq(DB.nextAdm, 1)
    end)
    it('the legacy SendToBed (isRevive) is a forwarder to the same check-in; the old handler finds no bed', function()
        Mock.coords[PATIENT] = reception()
        assert_eq(Config.Locations['hospital'][1]['beds'], nil, 'legacy points carry no beds')
        Mock.fireNetAll('hospital:server:SendToBed', PATIENT, 1, true, 1)
        assert_eq(DB.nextAdm, 1)
        assert_eq(#Mock.clientEventsNamed('hospital:client:SendToBed'), 0, 'the old 16A bed flow did not run')
        assert_eq(Mock.players[PATIENT].PlayerData.money.bank, 5000, 'nothing charged at check-in')
    end)
    it('sets an automatic triage colour on the patient record (GetPatientSummary for pf-justice)', function()
        wound('PATIENTCID', { mechanism = 'firearm', type = 'gunshot', region = 'thigh_l', severity = 4 })
        Mock.coords[PATIENT] = reception()
        local res = cb('checkIn', PATIENT, 'pillbox')
        local tri = DB.adm[res.admissionId].triage
        assert_true(tri == 'orange' or tri == 'red', 'serious wound -> orange or red, got ' .. tostring(tri))
        Mock.invokingResource = 'pf-justice'
        local s = exports['pf-ambulancejob']:GetPatientSummary('PATIENTCID')
        Mock.invokingResource = nil
        assert_eq(s.triage, tri)
    end)
end)

describe('triage and admit', function()
    local function checkedIn()
        Mock.coords[PATIENT] = reception()
        return cb('checkIn', PATIENT, 'pillbox').admissionId
    end
    it('triage needs on-duty staff with the tier, next to the patient, inside the hospital', function()
        local id = checkedIn()
        Mock.coords[MEDIC] = reception()
        assert_eq(cb('triage', MEDIC, PATIENT, 'red').error, 'no_permission', 'not staff')
        staff(MEDIC, 1, false)
        advance(2)
        assert_eq(cb('triage', MEDIC, PATIENT, 'red').error, 'not_on_duty')
        staff(MEDIC, 0)
        advance(2)
        assert_eq(cb('triage', MEDIC, PATIENT, 'red').error, 'no_permission', 'tier 1 cannot triage')
        staff(MEDIC, 1)
        -- a paramedic (tier 3) triages only inside the ED zone, the desk is not in it
        advance(2)
        assert_eq(cb('triage', MEDIC, PATIENT, 'red').error, 'no_permission')
        staff(NURSE, 2)
        Mock.coords[NURSE] = vector3(320.0, -590.0, 43.3)
        advance(2)
        assert_eq(cb('triage', NURSE, PATIENT, 'red').error, 'too_far', 'not next to the patient')
        Mock.coords[NURSE] = reception()
        advance(2)
        assert_eq(cb('triage', NURSE, PATIENT, 'purple').error, 'bad_args')
        advance(2)
        local res = cb('triage', NURSE, PATIENT, 'yellow')
        assert_true(res.ok, tostring(res.message))
        assert_eq(DB.adm[id].triage, 'yellow')
        assert_eq(DB.adm[id].state, 'triaged')
        assert_eq(Store.Peek('PATIENTCID').triage, 'yellow', 'p.triage for booking screening')
        assert_eq(Closes[#Closes].status, 'completed')
    end)
    it('a walk-in triaged by staff gets an admission; outside a hospital nothing happens', function()
        staff(NURSE, 2)
        Mock.coords[NURSE] = vector3(101.0, 100.0, 30.0)
        assert_eq(cb('triage', NURSE, PATIENT, 'green').error, 'too_far')
        advance(2)
        Mock.coords[PATIENT] = vector3(330.0, -588.0, 43.3)
        Mock.coords[NURSE] = vector3(331.0, -588.0, 43.3)
        local res = cb('triage', NURSE, PATIENT, 'green')
        assert_true(res.ok)
        assert_eq(DB.adm[res.admissionId].reason, 'walkin')
    end)
    it('admit holds a server bed: two patients never share one, beds are per facility', function()
        local id = checkedIn()
        Mock.coords[CIV] = reception()
        local id2 = cb('checkIn', CIV, 'pillbox').admissionId
        staff(MEDIC, 2)
        Mock.coords[MEDIC] = reception()
        local r1 = cb('admit', MEDIC, id, 'ed', 'ed1')
        assert_true(r1.ok, tostring(r1.message))
        assert_eq(DB.adm[id].state, 'in_treatment')
        assert_eq(DB.adm[id].bed_id, 'ed1')
        local action, data = lastBed(PATIENT)
        assert_eq(action, 'enter')
        assert_eq(data.bedId, 'ed1')
        advance(2)
        assert_eq(cb('admit', MEDIC, id2, 'ed', 'ed1').error, 'conflict')
        advance(2)
        local r2 = cb('admit', MEDIC, id2, 'ward')
        assert_true(r2.ok)
        assert_eq(r2.bedId, 'w1')
        assert_eq(DB.adm[id2].state, 'admitted')
        -- Paleto's ed1 is a different bed from Pillbox's ed1
        assert_eq(H.Beds.Occupant('paleto', 'ed1'), nil)
        assert_eq(H.Facility.Status('pillbox').beds.ed.free, 4)
    end)
    it('admit refuses a patient who left the building, a bed of another department, a junior medic', function()
        local id = checkedIn()
        staff(MEDIC, 0)
        Mock.coords[MEDIC] = reception()
        assert_eq(cb('admit', MEDIC, id, 'ed').error, 'no_permission')
        staff(MEDIC, 1)
        advance(2)
        assert_eq(cb('admit', MEDIC, id, 'ed', 'w1').error, 'bad_args')
        Mock.coords[PATIENT] = vector3(0.0, 0.0, 0.0)
        advance(2)
        assert_eq(cb('admit', MEDIC, id, 'ed').error, 'too_far')
    end)
end)

describe('discharge', function()
    local function admitted()
        Mock.coords[PATIENT] = reception()
        local id = cb('checkIn', PATIENT, 'pillbox').admissionId
        staff(MEDIC, 2)
        Mock.coords[MEDIC] = reception()
        assert_true(cb('admit', MEDIC, id, 'ed').ok)
        advance(2)
        return id
    end
    it('writes the restrictions and a calendar follow-up, frees the bed and lets the patient up', function()
        local id = admitted()
        local res = cb('discharge', MEDIC, id, { restrictions = { { kind = 'no_drive', hours = 12, reason = 'Concussion' }, { kind = 'crutches', hours = 48 } },
            followUpHours = 24 })
        assert_true(res.ok, tostring(res.message))
        assert_eq(DB.adm[id].state, 'discharged')
        assert_eq(#DB.restrictions, 2)
        assert_eq(DB.restrictions[1].citizenid, 'PATIENTCID')
        assert_eq(DB.restrictions[1].kind, 'no_drive')
        assert_eq(DB.restrictions[1].until_at, Mock.clock + 12 * 3600)
        assert_eq(DB.restrictions[1].by_cid, 'MEDICCID')
        assert_eq(#Calendar, 1)
        assert_eq(Calendar[1].scope, 'personal')
        assert_eq(Calendar[1].owner, 'PATIENTCID')
        assert_eq(Calendar[1].p.starts, Mock.clock + 24 * 3600)
        assert_eq(H.Beds.Occupant('pillbox', 'ed1'), nil)
        assert_eq((lastBed(PATIENT)), 'leave')
        assert_eq(H.Admissions.OpenOf('PATIENTCID'), nil)
        assert_eq(Store.Peek('PATIENTCID').triage, nil, 'triage cleared at discharge')
    end)
    it('restrictions go through the recovery module when it is there (17C AddRestriction), else into the table', function()
        local id = admitted()
        local added = {}
        PFMed.Recovery = { AddRestriction = function(cid, spec) added[#added + 1] = { cid = cid, spec = spec } return { ok = true, id = #added } end,
            ReloadRestrictions = function() error('no reload when nothing was written directly') end }
        assert_true(cb('discharge', MEDIC, id, { restrictions = { { kind = 'no_drive', hours = 2 } } }).ok)
        PFMed.Recovery = nil
        assert_eq(#added, 1)
        assert_eq(added[1].cid, 'PATIENTCID')
        assert_eq(added[1].spec.kind, 'no_drive')
        assert_eq(added[1].spec.untilAt, Mock.clock + 7200)
        assert_eq(added[1].spec.byCid, 'MEDICCID')
        assert_eq(#DB.restrictions, 0)
    end)
    it('refuses unknown restriction kinds, prescriptions, a far follow-up and a nurse-less tier', function()
        local id = admitted()
        assert_eq(cb('discharge', MEDIC, id, { restrictions = { { kind = 'fly', hours = 1 } } }).error, 'bad_args')
        advance(2)
        assert_eq(cb('discharge', MEDIC, id, { prescriptions = { { drug = 'morphine' } } }).error, 'bad_args')
        advance(2)
        assert_eq(cb('discharge', MEDIC, id, { followUpHours = 24 * 400 }).error, 'bad_args')
        staff(MEDIC, 1)
        advance(2)
        assert_eq(cb('discharge', MEDIC, id, {}).error, 'no_permission')
        assert_eq(DB.adm[id].state, 'in_treatment')
    end)
    it('DischargePatient export: caller allowlist, court-order actor, duplicate key', function()
        local id = admitted()
        Mock.invokingResource = 'pf-taxi'
        assert_eq(exports['pf-ambulancejob']:DischargePatient(id, {}).error, 'not_allowed')
        Mock.invokingResource = 'pf-justice'
        local res = exports['pf-ambulancejob']:DischargePatient(id, { key = 'pf-justice:court:7', actor = { kind = 'system', label = 'court order' } })
        assert_true(res.ok, tostring(res.message))
        local again = exports['pf-ambulancejob']:DischargePatient(id, { key = 'pf-justice:court:7' })
        assert_true(again.duplicate)
        Mock.invokingResource = nil
    end)
end)

describe('transfer', function()
    it('closes this admission as transferred and opens one at the target; it closes if nobody arrives', function()
        Mock.coords[PATIENT] = reception()
        local id = cb('checkIn', PATIENT, 'pillbox').admissionId
        staff(NURSE, 2)
        Mock.coords[NURSE] = reception()
        local res = cb('transfer', NURSE, id, { hospitalId = 'paleto' })
        assert_true(res.ok, tostring(res.message))
        assert_eq(DB.adm[id].state, 'transferred')
        local new = DB.adm[res.admissionId]
        assert_eq(new.hospital_id, 'paleto')
        assert_eq(new.state, 'waiting')
        advance(Config.Hospital.Intake.TransferArriveSeconds + 1)
        H.Admissions.Tick(os.time())
        assert_eq(DB.adm[res.admissionId].state, 'left_ama')
    end)
    it('the prison infirmary takes only inmates', function()
        Mock.coords[PATIENT] = reception()
        local id = cb('checkIn', PATIENT, 'pillbox').admissionId
        staff(NURSE, 2)
        Mock.coords[NURSE] = reception()
        assert_eq(cb('transfer', NURSE, id, { facility = 'bolingbroke' }).error, 'no_permission')
    end)
end)

describe('leaving', function()
    it('leaving the building without a discharge closes the admission as left AMA (after the grace)', function()
        Mock.coords[PATIENT] = reception()
        local id = cb('checkIn', PATIENT, 'pillbox').admissionId
        Mock.coords[PATIENT] = vector3(0.0, 0.0, 0.0)
        H.Admissions.Tick(os.time())
        assert_eq(DB.adm[id].state, 'checked_in', 'grace')
        advance(Config.Hospital.Intake.LeaveGraceSeconds)
        H.Admissions.Tick(os.time())
        assert_eq(DB.adm[id].state, 'left_ama')
        assert_eq(Closes[#Closes].status, 'cancelled')
    end)
    it('an offline patient keeps the admission for the grace time, then it closes', function()
        Mock.coords[CIV] = reception()
        local id = cb('checkIn', CIV, 'pillbox').admissionId
        Mock.players[CIV] = nil
        H.Admissions.Tick(os.time())
        advance(Config.Hospital.Intake.OfflineGraceSeconds)
        H.Admissions.Tick(os.time())
        assert_eq(DB.adm[id].state, 'left_ama')
    end)
end)

describe('respawn', function()
    local function die()
        Health[PATIENT] = 0
        Mock.fireNet('pf-ambulancejob:server:ReportDown', PATIENT, { nonce = 'n1', kind = 'laststand' })
        Health[PATIENT] = 150
        advance(Config.Medical.Down.LaststandSeconds + 1); D.Tick(os.time())
        advance(Config.Medical.Consciousness.RespawnAfterSeconds + 1)
    end
    it('admits to the ED of the nearest hospital with a bed and the revive token; injuries are kept', function()
        Config.WipeInventoryOnRespawn = false
        local inj = wound('PATIENTCID', { mechanism = 'blunt', type = 'fracture', region = 'lower_leg_l', structure = 'tibia_l', severity = 2 })
        die()
        Mock.coords[PATIENT] = vector3(-200.0, 6300.0, 31.0) -- near Paleto
        Mock.fireNet('pf-ambulancejob:server:RequestRespawn', PATIENT)
        local a = H.Admissions.OpenOf('PATIENTCID')
        assert_true(a ~= nil, 'admitted')
        assert_eq(a.hospital_id, 'paleto')
        assert_eq(a.state, 'in_treatment')
        assert_eq(a.dept, 'ed')
        assert_eq(a.reason, 'respawn')
        local action, data = lastBed(PATIENT)
        assert_eq(action, 'enter')
        assert_true(type(data.token) == 'string', 'revive token with the bed')
        -- the bed applies the revive: the patient is up and the fracture is still there
        Health[PATIENT] = 200
        advance(2)
        Mock.fireNet('pf-ambulancejob:server:ReviveApplied', PATIENT, data.token)
        assert_eq(Store.Peek('PATIENTCID').consciousness, 'alert')
        local still = Store.Peek('PATIENTCID').injuries[inj.id]
        assert_true(still ~= nil and still.stage ~= 'recovered', 'injury kept')
        local respawned = 0
        for _, e in ipairs(Mock.serverEvents) do if e.name == 'pf-ambulancejob:server:respawned' then respawned = respawned + 1; assert_eq(e.args[3], 'paleto') end end
        assert_eq(respawned, 1)
    end)
    it('asked again for the same death: same admission, one respawned event, one wipe', function()
        Config.WipeInventoryOnRespawn = true
        die()
        Mock.coords[PATIENT] = reception()
        Mock.fireNet('pf-ambulancejob:server:RequestRespawn', PATIENT)
        advance(6)
        Mock.fireNet('hospital:server:RespawnAtHospital', PATIENT, 1)
        assert_eq(DB.nextAdm, 1)
        local n = 0
        for _, e in ipairs(Mock.serverEvents) do if e.name == 'pf-ambulancejob:server:respawned' then n = n + 1 end end
        assert_eq(n, 1)
        Config.WipeInventoryOnRespawn = false
    end)
    it('an inmate respawns in the prison infirmary (its own bed keys)', function()
        Config.WipeInventoryOnRespawn = false
        Mock.players[PATIENT].PlayerData.metadata.injail = 30
        die()
        Mock.fireNet('pf-ambulancejob:server:RequestRespawn', PATIENT)
        local a = H.Admissions.OpenOf('PATIENTCID')
        assert_eq(a.hospital_id, 'bolingbroke')
        assert_eq(a.bed_id, 'i1')
        assert_eq(H.Beds.Occupant('pillbox', 'ed1'), nil, 'a jail bed never blocks a hospital bed')
    end)
    it('not before the server has them dead', function()
        Mock.fireNet('pf-ambulancejob:server:RequestRespawn', PATIENT)
        assert_eq(DB.nextAdm, 0)
    end)
end)

describe('exports', function()
    it('IsInCare, GetAdmission, ListAdmissions, GetHospitalStatus, AdmitPatient (keyed)', function()
        Mock.coords[PATIENT] = reception()
        local id = cb('checkIn', PATIENT, 'pillbox').admissionId
        Mock.invokingResource = 'pf-justice'
        local inCare, aid = exports['pf-ambulancejob']:IsInCare(PATIENT)
        assert_true(inCare)
        assert_eq(aid, id)
        assert_false((exports['pf-ambulancejob']:IsInCare('CIVCID')))
        assert_eq(exports['pf-ambulancejob']:GetAdmission('PATIENTCID').admission.id, id)
        assert_eq(exports['pf-ambulancejob']:ListAdmissions('pillbox').error, 'not_allowed')
        Mock.invokingResource = 'pf-emsmdt'
        assert_eq(#exports['pf-ambulancejob']:ListAdmissions('pillbox').list, 1)
        local st = exports['pf-ambulancejob']:GetHospitalStatus('pillbox')
        assert_eq(st.beds.ed.total, 5)
        assert_true(st.aiActive, 'no staff on duty')
        Mock.invokingResource = 'pfm-prison'
        assert_eq(exports['pf-ambulancejob']:AdmitPatient('CIVCID', { hospitalId = 'bolingbroke', dept = 'infirmary' }, {}).error, 'bad_args', 'key required')
        local r = exports['pf-ambulancejob']:AdmitPatient('CIVCID', { hospitalId = 'bolingbroke', dept = 'infirmary', reason = 'fight' }, { key = 'pfm-prison:infirmary:1' })
        assert_true(r.ok, tostring(r.message))
        assert_eq(r.bedId, 'i1')
        local again = exports['pf-ambulancejob']:AdmitPatient('CIVCID', { hospitalId = 'bolingbroke', dept = 'infirmary' }, { key = 'pfm-prison:infirmary:1' })
        assert_true(again.duplicate)
        assert_eq(exports['pf-ambulancejob']:AdmitPatient('CIVCID', { hospitalId = 'pillbox', dept = 'ed' }, { key = 'pfm-prison:infirmary:1' }).error, 'key_reused')
        Mock.invokingResource = nil
    end)
end)

describe('AI care (D17)', function()
    local function waiting(wounds)
        for _, w in ipairs(wounds or {}) do wound('PATIENTCID', w) end
        Mock.coords[PATIENT] = reception()
        return cb('checkIn', PATIENT, 'pillbox').admissionId
    end
    it('does not take a patient before the wait, and not while two medics are on duty', function()
        local id = waiting()
        H.AI.Tick(os.time())
        assert_eq(DB.adm[id].mode, 'staff', 'before the wait')
        staff(MEDIC, 1); staff(NURSE, 2)
        advance(Config.Hospital.AI.WaitSeconds + 1)
        H.AI.Tick(os.time())
        assert_eq(DB.adm[id].mode, 'staff', 'two medics on duty: the patient waits for them')
        staff(NURSE, 2, false)
        H.AI.Tick(os.time())
        assert_eq(DB.adm[id].mode, 'ai', 'one medic who did not come: the AI takes over')
    end)
    it('not when a medic accepted the request in the Dispatch app', function()
        local id = waiting()
        AcceptedRef['hospital_admission:' .. id] = { status = 'accepted', assignee = 'MEDICCID' }
        advance(Config.Hospital.AI.WaitSeconds + 1)
        H.AI.Tick(os.time())
        assert_eq(DB.adm[id].mode, 'staff')
    end)
    it('stabilises at x2 time only while the patient is in bed, then discharges with restrictions and a follow-up', function()
        local id = waiting({ { mechanism = 'blunt', type = 'fracture', region = 'lower_leg_l', structure = 'tibia_l', severity = 2 } })
        advance(Config.Hospital.AI.WaitSeconds + 1)
        H.AI.Tick(os.time())
        local a = H.Admissions.ById(id)
        assert_eq(a.mode, 'ai')
        assert_eq(a.state, 'in_treatment')
        local duration = a.aiDoneAt - os.time()
        assert_eq(duration, (Config.Hospital.AI.BaseSeconds + Config.Hospital.AI.PerInjurySeconds) * 2, 'x2 time')
        -- out of bed: the clock does not run
        Mock.coords[PATIENT] = reception()
        advance(duration)
        H.AI.Tick(os.time())
        assert_eq(DB.adm[id].state, 'in_treatment', 'paused while not in bed')
        Mock.coords[PATIENT] = bedCoords('pillbox', a.bed_id)
        advance(duration)
        H.AI.Tick(os.time())
        assert_eq(DB.adm[id].state, 'discharged')
        local inj
        for _, i in pairs(Store.Peek('PATIENTCID').injuries) do inj = i end
        assert_eq(inj.stage, 'stabilized', 'left stabilized for a medic')
        assert_true(inj.treatments.splinted ~= nil, 'splinted')
        local kinds = {}
        for _, r in ipairs(DB.restrictions) do kinds[r.kind] = true end
        assert_true(kinds.crutches, 'leg fracture -> crutches')
        assert_eq(#Calendar, 1)
        local ai = 0
        for _, t in ipairs(DB.treatments) do if t.action == 'ai_stabilize' and t.admission_id == id then ai = ai + 1 end end
        assert_eq(ai, 1, 'the AI care is in the treatment log')
    end)
    it('never treats a down patient', function()
        local id = waiting()
        advance(Config.Hospital.AI.WaitSeconds + 1)
        H.AI.Tick(os.time())
        local a = H.Admissions.ById(id)
        Mock.coords[PATIENT] = bedCoords('pillbox', a.bed_id)
        Health[PATIENT] = 0
        Mock.fireNet('pf-ambulancejob:server:ReportDown', PATIENT, { nonce = 'x', kind = 'laststand' })
        advance(3600)
        H.AI.Tick(os.time())
        assert_eq(DB.adm[id].state, 'in_treatment')
    end)
    it('surgery waits for an on-duty surgeon; with none for SurgeryWaitSeconds the AI operates', function()
        local id = waiting({ { mechanism = 'firearm', type = 'internal_bleeding', region = 'abdomen', structure = 'liver', severity = 3 } })
        staff(MEDIC, 3) -- one surgeon on duty (below MinStaff, so the AI still takes the patient)
        advance(Config.Hospital.AI.WaitSeconds + 1)
        H.AI.Tick(os.time())
        local a = H.Admissions.ById(id)
        assert_eq(a.mode, 'ai')
        Mock.coords[PATIENT] = bedCoords('pillbox', a.bed_id)
        advance(a.aiDoneAt - os.time())
        local out = H.AI.Tick(os.time())
        assert_eq(out[id], 'awaiting_surgeon')
        advance(Config.Hospital.AI.SurgeryWaitSeconds + 1)
        assert_eq(H.AI.Tick(os.time())[id], 'awaiting_surgeon', 'a surgeon is on duty: no AI surgery')
        staff(MEDIC, 3, false)
        H.AI.Tick(os.time())
        advance(Config.Hospital.AI.SurgeryWaitSeconds)
        assert_eq(H.AI.Tick(os.time())[id], 'discharged')
        local ops = 0
        for _, t in ipairs(DB.treatments) do if t.action == 'ai_surgery' then ops = ops + 1 end end
        assert_eq(ops, 1)
    end)
end)
