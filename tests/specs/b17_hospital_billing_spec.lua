-- pf-ambulancejob hospital bills (batch 17E, owner decisions D5/D6/D17): itemised from server
-- records only (admission row, bed hours, treatment log), charged once from the patient's bank
-- straight to society:ambulance under pf-ambulancejob:bill:<id>:<attempt>, a phone invoice that
-- cannot be declined (ref pf-ambulancejob:bill:<id>) after a clear refusal, unclear results held
-- and looked up (never charged again), coverage discounts by server job, AI care at x1.5.
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
    S.MarkStaff = function(id, at, cid)
        local r = DB.adm[id]
        if not r or r.staff_acted_at then return 0 end
        r.staff_acted_at, r.staff_cid = at, cid
        return 1
    end
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


local function ambulance() return FakeDB.bank_accounts.ambulance.account_balance end
local function bank(src) return Mock.players[src].PlayerData.money.bank end
local function only(t) local n, last = 0, nil for _, v in pairs(t) do n = n + 1; last = v end return n, last end
local function billOf(admId) for _, b in pairs(DB.bills) do if b.admission_id == admId then return b end end end
local function linesOf(billId) local out = {} for _, l in ipairs(DB.lines) do if l.bill_id == billId then out[#out + 1] = l end end return out end

local function admitAndDischarge(opts)
    opts = opts or {}
    Mock.coords[PATIENT] = reception()
    local id = cb('checkIn', PATIENT, 'pillbox').admissionId
    staff(MEDIC, 2)
    Mock.coords[MEDIC] = reception()
    assert_true(cb('admit', MEDIC, id, 'ed').ok)
    for _, t in ipairs(opts.treatments or {}) do
        local admId = id
        if t.adm == false then admId = nil end
        DB.treatments[#DB.treatments + 1] = { id = #DB.treatments + 1, citizenid = t.cid or 'PATIENTCID', action = t.action, location = t.location or 'hospital',
            result = t.result or 'ok', admission_id = admId, at = os.time(), by_cid = t.by or 'MEDICCID', by_job = t.job or 'ambulance' }
    end
    advance(opts.stay or 600)
    local res = cb('discharge', MEDIC, id, {})
    assert_true(res.ok, tostring(res.message))
    return id
end

describe('itemised bill', function()
    it('is built from the admission and the treatment log only, and paid once to society:ambulance', function()
        local id = admitAndDischarge({ stay = 3 * 3600 + 5, treatments = {
            { action = 'sutures' }, { action = 'morphine' }, { action = 'cast', result = 'refused' },
            { action = 'sutures', cid = 'CIVCID' }, { action = 'splint', adm = false, location = 'field' },
            -- not hospital care: the patient's own bandage, a civilian's dressing, a police officer's tourniquet
            { action = 'pressure_dressing', by = 'PATIENTCID', job = 'unemployed' }, { action = 'pressure_dressing', by = 'CIVCID', job = 'unemployed' },
            { action = 'tourniquet', by = 'NURSECID', job = 'police' },
        } })
        local n, bill = only(DB.bills)
        assert_eq(n, 1)
        assert_eq(bill.admission_id, id)
        local t = Config.Hospital.Tariff
        local expected = t.Admission.checkin + 4 * t.BedHour.ed + t.Treatments.sutures + t.Drugs.morphine
        assert_eq(bill.total, expected)
        local kinds = {}
        for _, l in ipairs(linesOf(bill.id)) do kinds[l.kind] = (kinds[l.kind] or 0) + 1 end
        assert_eq(kinds.procedure, 1); assert_eq(kinds.bed, 1); assert_eq(kinds.treatment, 1); assert_eq(kinds.drug, 1)
        assert_eq(bill.state, 'paid')
        assert_eq(bank(PATIENT), 5000 - expected)
        assert_eq(ambulance(), expected)
        assert_eq(#LedgerEnv.paid('pf-ambulancejob:bill:' .. bill.id .. ':1'), 1, 'keyed charge')
        assert_eq(#Mails, 1, 'itemised mail')
        -- a second close, a sweep or a collect pays nothing more
        H.Billing.Sweep(os.time())
        H.Billing.Collect(bill.id)
        assert_eq(bank(PATIENT), 5000 - expected)
        assert_eq(H.Billing.ForAdmission({ id = id, citizenid = 'PATIENTCID', hospital_id = 'pillbox', reason = 'checkin', arrived_at = os.time() }), bill.id)
        assert_eq(only(DB.bills), 1)
    end)
    it('nothing is charged at check-in; a patient who cannot pay is still treated and gets an undeclinable invoice', function()
        Mock.players[PATIENT].PlayerData.money.bank = 10
        Mock.coords[PATIENT] = reception()
        cb('checkIn', PATIENT, 'pillbox')
        assert_eq(bank(PATIENT), 10)
        local id = H.Admissions.OpenOf('PATIENTCID').id
        staff(MEDIC, 2)
        Mock.coords[MEDIC] = reception()
        assert_true(cb('admit', MEDIC, id, 'ed').ok, 'treated without money')
        advance(2)
        assert_true(cb('discharge', MEDIC, id, {}).ok)
        local bill = billOf(id)
        assert_eq(bill.state, 'invoiced')
        assert_eq(bank(PATIENT), 10)
        assert_eq(ambulance(), 0)
        assert_eq(#Invoices, 1)
        local inv = Invoices[1]
        assert_eq(inv.candecline, 0)
        assert_eq(inv.society, 'ambulance')
        assert_eq(inv.ref, 'pf-ambulancejob:bill:' .. bill.id)
        assert_eq(inv.amount, bill.total)
        assert_eq(bill.invoice_id, 501)
        -- a settlement raised by a client is ignored; one with another amount too; the real one pays it
        Mock.fireEvent('pfm-phone:server:invoiceSettled', 7, { ref = inv.ref, amount = inv.amount, citizenid = 'PATIENTCID' }, 'paid')
        assert_eq(billOf(id).state, 'invoiced')
        Mock.fireEvent('pfm-phone:server:invoiceSettled', nil, { ref = inv.ref, amount = 1, citizenid = 'PATIENTCID' }, 'paid')
        assert_eq(billOf(id).state, 'invoiced')
        Mock.fireEvent('pfm-phone:server:invoiceSettled', nil, { ref = inv.ref, amount = inv.amount, citizenid = 'PATIENTCID' }, 'paid')
        assert_eq(billOf(id).state, 'paid')
    end)
    it('a cancelled invoice waives the bill; invoices of other resources are not ours', function()
        Mock.players[PATIENT].PlayerData.money.bank = 0
        local id = admitAndDischarge()
        local bill = billOf(id)
        Mock.fireEvent('pfm-phone:server:invoiceSettled', nil, { ref = 'pf-justice:order:' .. bill.id, amount = bill.total, citizenid = 'PATIENTCID' }, 'paid')
        assert_eq(billOf(id).state, 'invoiced')
        Mock.fireEvent('pfm-phone:server:invoiceSettled', nil, { ref = Invoices[1].ref, amount = bill.total, citizenid = 'PATIENTCID' }, 'cancelled')
        assert_eq(billOf(id).state, 'waived')
    end)
    it('pfm-phone down: the bill stays open and the sweep invoices it later (one invoice)', function()
        Mock.players[PATIENT].PlayerData.money.bank = 0
        local create = Mock.exportsByResource['pfm-phone'].CreateInvoice
        Mock.exportsByResource['pfm-phone'].CreateInvoice = function() return nil, 'db_error' end
        local id = admitAndDischarge()
        assert_eq(billOf(id).state, 'open')
        Mock.exportsByResource['pfm-phone'].CreateInvoice = create
        advance(Config.Hospital.Billing.SweepSeconds + 1)
        H.Billing.Sweep(os.time())
        assert_eq(billOf(id).state, 'invoiced')
        assert_eq(#Invoices, 1)
        assert_eq(bank(PATIENT), 0, 'no second bank charge after the clear refusal')
    end)
end)

describe('what is billable', function()
    it('only staff care on someone else and the AI\'s rows; never self-care, civilians or rows without a provider', function()
        local B = H.Billing
        assert_true(B.Billable({ by_cid = 'MEDICCID', by_job = 'ambulance' }, 'PATIENTCID'))
        assert_true(B.Billable({ by_job = 'ai_care' }, 'PATIENTCID'))
        assert_false(B.Billable({ by_cid = 'PATIENTCID', by_job = 'ambulance' }, 'PATIENTCID'), 'a medic treating themselves')
        assert_false(B.Billable({ by_cid = 'CIVCID', by_job = 'unemployed' }, 'PATIENTCID'))
        assert_false(B.Billable({ by_job = 'ambulance' }, 'PATIENTCID'), 'no provider')
    end)
end)

describe('ledger outcomes', function()
    it('an unclear charge is held as payment_pending, looked up by its key, never charged again', function()
        local real = PFPayout.Charge
        local calls = {}
        PFPayout.Charge = function(who, acc, amount, opts) calls[#calls + 1] = opts.key return false, { ok = false, state = 'pending', unclear = true } end
        local id = admitAndDischarge()
        local bill = billOf(id)
        assert_eq(bill.state, 'payment_pending')
        assert_eq(bill.pay_key, 'pf-ambulancejob:bill:' .. bill.id .. ':1')
        local bk = Mock.exportsByResource['pfm-banking']
        local getTx = bk.GetTransaction
        local looked = {}
        bk.GetTransaction = function(_, key) looked[#looked + 1] = key return { state = 'pending' } end
        advance(Config.Hospital.Billing.SweepSeconds + 1)
        H.Billing.Sweep(os.time())
        assert_eq(billOf(id).state, 'payment_pending')
        assert_eq(#calls, 1, 'no new key while unclear')
        assert_eq(looked[1], bill.pay_key .. ':bank')
        bk.GetTransaction = function() return { state = 'completed' } end
        advance(Config.Hospital.Billing.SweepSeconds + 1)
        H.Billing.Sweep(os.time())
        assert_eq(billOf(id).state, 'paid')
        bk.GetTransaction = getTx
        PFPayout.Charge = real
    end)
    it('a clearly failed pending key is followed by the next numbered key', function()
        local real = PFPayout.Charge
        local calls = {}
        PFPayout.Charge = function(who, acc, amount, opts)
            calls[#calls + 1] = opts.key
            if #calls == 1 then return false, { ok = false, state = 'pending', unclear = true } end
            return real(who, acc, amount, opts)
        end
        local id = admitAndDischarge()
        local bk = Mock.exportsByResource['pfm-banking']
        local getTx = bk.GetTransaction
        bk.GetTransaction = function() return { state = 'failed', error = 'timeout' } end
        advance(Config.Hospital.Billing.SweepSeconds + 1)
        H.Billing.Sweep(os.time())
        bk.GetTransaction = getTx
        PFPayout.Charge = real
        local bill = billOf(id)
        assert_eq(calls[2], 'pf-ambulancejob:bill:' .. bill.id .. ':2')
        assert_eq(bill.state, 'paid')
        assert_eq(ambulance(), bill.total)
    end)
    it('bank not running: the bill stays open and is charged by the sweep under the next key', function()
        local real = PFPayout.Charge
        PFPayout.Charge = function() return false, { ok = false, error = 'bank_unavailable' } end
        local id = admitAndDischarge()
        assert_eq(billOf(id).state, 'open')
        PFPayout.Charge = real
        advance(Config.Hospital.Billing.SweepSeconds + 1)
        H.Billing.Sweep(os.time())
        local bill = billOf(id)
        assert_eq(bill.state, 'paid')
        assert_eq(#LedgerEnv.paid('pf-ambulancejob:bill:' .. bill.id .. ':2'), 1)
    end)
end)

describe('prices', function()
    it('on-duty public servants get the coverage discount (server job)', function()
        Mock.players[PATIENT].PlayerData.job = { name = 'police', onduty = true, grade = { level = 1 } }
        local id = admitAndDischarge()
        local bill = billOf(id)
        assert_eq(bill.discount, math.floor(bill.total / 2))
        assert_eq(ambulance(), bill.total - bill.discount)
    end)
    it('AI care bills every line at x1.5, a respawn bills the respawn fee once per death', function()
        Mock.coords[PATIENT] = reception()
        local id = cb('checkIn', PATIENT, 'pillbox').admissionId
        advance(Config.Hospital.AI.WaitSeconds + 1)
        H.AI.Tick(os.time())
        local a = H.Admissions.ById(id)
        assert_eq(a.mode, 'ai')
        local b = H.Beds.Def('pillbox', a.bed_id)
        Mock.coords[PATIENT] = vector3(b.coords.x, b.coords.y, b.coords.z)
        advance(a.aiDoneAt - os.time())
        H.AI.Tick(os.time())
        local bill = billOf(id)
        local t, m = Config.Hospital.Tariff, Config.Hospital.AI.PriceMultiplier
        assert_eq(bill.total, math.floor(t.Admission.checkin * m + 0.5) + math.floor(t.BedHour.ed * m + 0.5))
    end)
    it('respawn: one admission and one bill per death, with the respawn fee', function()
        Config.WipeInventoryOnRespawn = false
        Health[PATIENT] = 0
        Mock.fireNet('pf-ambulancejob:server:ReportDown', PATIENT, { nonce = 'n1', kind = 'laststand' })
        Health[PATIENT] = 150
        advance(Config.Medical.Down.LaststandSeconds + 1); D.Tick(os.time())
        advance(Config.Medical.Consciousness.RespawnAfterSeconds + 1)
        Mock.coords[PATIENT] = reception()
        Mock.fireNet('pf-ambulancejob:server:RequestRespawn', PATIENT)
        advance(6)
        Mock.fireNet('pf-ambulancejob:server:RequestRespawn', PATIENT)
        local a = H.Admissions.OpenOf('PATIENTCID')
        assert_eq(DB.nextAdm, 1)
        assert_eq(only(DB.bills), 0, 'billed when the stay ends')
        H.Admissions.Tick(os.time()) -- seen in the hospital (the bed)
        Mock.coords[PATIENT] = vector3(0.0, 0.0, 0.0)
        H.Admissions.Tick(os.time())
        advance(Config.Hospital.Intake.LeaveGraceSeconds)
        H.Admissions.Tick(os.time())
        assert_eq(DB.adm[a.id].state, 'left_ama')
        local n, bill = only(DB.bills)
        assert_eq(n, 1)
        local t = Config.Hospital.Tariff
        assert_eq(bill.total, t.Admission.respawn + t.BedHour.ed)
        assert_eq(bank(PATIENT), 5000 - bill.total)
    end)
end)
