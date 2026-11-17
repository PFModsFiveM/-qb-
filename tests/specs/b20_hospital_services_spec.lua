-- pf-ambulancejob hospital services (batch 20A), mocked: discharge orders accept prescriptions
-- (they were refused before) and only from a physician; a prescription fill and a ward-drug
-- withdrawal write their log row BEFORE any item moves and undo it when the stock is short (no
-- item is handed out without its row, no row stays without its move); lab samples are read from
-- the engine state (never from the client); imaging and lab ordering follow the tiers; surgery
-- needs a surgeon in the operating room, the patient in their bed there and a confirmed diagnosis,
-- and its retained-projectile payload is accepted by pfm-policejob's evidence lab handler as it is
-- (the real L.OnProjectileRecovered, keyed pf-ambulancejob:projectile:<injuryId>); the bill
-- replaces 17E's single bed line by one line per ward/ICU stay at the stay's own rate.
-- The SQL itself runs in b20_hospital_services_realdb_spec.
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
function GetEntityHealth() return 200 end
function GetPedArmour() return 0 end
function GetEntityAttachedTo() return 0 end
function SetEntityCoords() end
STARTED = {}
function GetResourceState(res) return STARTED[res] and 'started' or 'missing' end
QBCoreMock.Commands.Add = function() end
Mock.exportsByResource['pfm-core'].RunMigrations = function() return true end

-- every inventory call in order, with the SQL writes interleaved (the order is what is tested)
Trace, Stash, Pockets = {}, {}, {}
Mock.exportsByResource['pfm-inventory'] = {
    RemoveItem = function(_, id, item, n)
        Trace[#Trace + 1] = 'remove:' .. tostring(id) .. ':' .. item
        local bag = type(id) == 'string' and Stash or Pockets
        bag[id] = bag[id] or {}
        if (bag[id][item] or 0) < (n or 1) then return false end
        bag[id][item] = bag[id][item] - (n or 1)
        return true
    end,
    AddItem = function(_, id, item, n)
        Trace[#Trace + 1] = 'add:' .. tostring(id) .. ':' .. item
        local bag = type(id) == 'string' and Stash or Pockets
        bag[id] = bag[id] or {}
        bag[id][item] = (bag[id][item] or 0) + (n or 1)
        return true
    end,
    CreateInventory = function() end,
    OpenInventory = function(_, src, id) Trace[#Trace + 1] = 'open:' .. tostring(id) end,
    GetInventory = function(_, id)
        local items = {}
        for name, n in pairs(Stash[id] or {}) do items[#items + 1] = { name = name, amount = n } end
        return { items = items }
    end,
    HasItem = function() return true end,
}

local function copy(t)
    if type(t) ~= 'table' then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = copy(v) end
    return o
end

local function installFakeSQL()
    local M = PFMed.SQL
    M.LoadPatient = function(cid) return copy(DB.patients[cid]) end
    M.LoadOpenInjuries = function() return {} end
    M.FindInjuryByKey = function() return nil end
    M.InsertInjury = function(r) DB.nextId = DB.nextId + 1 return DB.nextId end
    M.UpsertPatients = function() return true end
    M.UpsertInjuries = function() return true end
    M.InsertEvents = function() return true end
    M.Sweep = function() return {} end
    local S = PFHospital.SQL
    S.InsertAdmission = function(r) DB.nextAdm = DB.nextAdm + 1 local row = copy(r) row.id = DB.nextAdm DB.adm[row.id] = row return row.id end
    S.FindAdmissionByKey = function() return nil end
    S.GetAdmission = function(id) return copy(DB.adm[id]) end
    S.LoadOpenAdmissions = function() return {} end
    S.MoveAdmission = function(id, from, row)
        local r = DB.adm[id]
        if not r or r.state ~= from then return 0 end
        for k, v in pairs(row) do r[k] = v end
        return 1
    end
    S.InsertRestriction = function() return 1 end
    S.MarkStaff = function() return 1 end
    S.FindBillByAdmission = function() return nil end
    S.InsertBill = function() DB.bills = DB.bills + 1 return DB.bills end
    S.InsertBillLines = function(_, lines) DB.lines = copy(lines) return true end
    S.TreatmentsFor = function() return {} end
    -- 20A
    S.PhFindRxByKey = function(key) for _, r in pairs(DB.rx) do if r.idem_key == key then return copy(r) end end end
    S.PhInsertRx = function(r) local row = copy(r) row.id = #DB.rx + 1 row.state = 'active' row.dispensed = 0 DB.rx[row.id] = row return row.id end
    S.PhActiveRx = function(cid)
        local out = {}
        for _, r in ipairs(DB.rx) do if r.citizenid == cid and r.state == 'active' and r.hospital_id then out[#out + 1] = copy(r) end end
        return out
    end
    S.PhReserveFill = function(id, dispensed, at)
        local r = DB.rx[id]
        if not r or r.state ~= 'active' or r.dispensed ~= dispensed then return 0 end
        r.dispensed, r.last_dispensed_at = r.dispensed + 1, at
        if r.dispensed >= r.qty then r.state = 'filled' end
        Trace[#Trace + 1] = 'reserve'
        return 1
    end
    S.PhUndoFill = function(id, after, prev)
        local r = DB.rx[id]
        if not r or r.dispensed ~= after then return 0 end
        r.state, r.dispensed, r.last_dispensed_at = 'active', r.dispensed - 1, prev
        Trace[#Trace + 1] = 'undo'
        return 1
    end
    S.PhInsertLog = function(r) DB.log[r.idem_key] = copy(r) Trace[#Trace + 1] = 'log:' .. r.kind return #Trace end
    S.PhDeleteLog = function(key) local had = DB.log[key] ~= nil DB.log[key] = nil Trace[#Trace + 1] = 'unlog' return had and 1 or 0 end
    S.PhAdmissionRx = function() return {} end
    S.PhGetRx = function(id) return copy(DB.rx[id]) end
    S.PhCancelPharmacyRx = function(id, hospitalId, by)
        local r = DB.rx[id]
        if not r or r.state ~= 'active' or r.hospital_id ~= hospitalId then return 0 end
        r.state, r.cancelled_by = 'cancelled', by
        return 1
    end
    S.PhCancelRx = function(id, by) local r = DB.rx[id] if r and r.state == 'active' then r.state = 'cancelled' return 1 end return 0 end
    S.OrdBillable = function() return {} end
    S.OrdSetBill = function() return 1 end
    S.StaysFor = function(id) return copy(DB.stays[id] or {}) end
    S.StayInsert = function() DB.nextStay = DB.nextStay + 1 return DB.nextStay end
    S.StayEnd = function() return 1 end
    S.StaySetBill = function() return 1 end
    S.OrdInsert = function(r) DB.nextOrd = DB.nextOrd + 1 DB.ord[DB.nextOrd] = copy(r) return DB.nextOrd end
    S.OrdOpenFor = function() return nil end
    S.OrdCancel = function() return 1 end
    S.OrdResult = function() return 1 end
    S.SuInsertTreatment = function(r) DB.tx[#DB.tx + 1] = copy(r) return #DB.tx end
end

local AJ = '[pfscripts]/pf-ambulancejob/'
local FILES = { AJ .. 'config.lua', AJ .. 'config_medical.lua', AJ .. 'config_hospital.lua', AJ .. 'shared/framework.lua' }
for _, f in ipairs({ 'anatomy', 'injuries', 'physiology_model', 'effects_model', 'findings' }) do FILES[#FILES + 1] = AJ .. 'shared/medical/' .. f .. '.lua' end
FILES[#FILES + 1] = AJ .. 'server/main.lua'
for _, f in ipairs({ 'schema', 'store', 'engine', 'downstate', 'effects', 'api', 'diagnosis', 'exam' }) do FILES[#FILES + 1] = AJ .. 'server/medical/' .. f .. '.lua' end
for _, f in ipairs({ 'facility', 'beds', 'admissions', 'billing', 'ai_care', 'pharmacy', 'lab', 'imaging', 'surgery' }) do
    FILES[#FILES + 1] = AJ .. 'server/hospital/' .. f .. '.lua'
end

local H, A
local function boot()
    Mock.eventHandlers, Mock.netHandlers, Mock.netHandlerList, Mock.callbacks = {}, {}, {}, {}
    PFMed, PFEmsRequests, PFHospital, RespawnPlayer = nil, nil, nil, nil
    LedgerEnv.load('pf-ambulancejob', FILES)
    installFakeSQL()
    Mock.exportsByResource['pf-ambulancejob'] = Mock.exportsByResource['__self']
    H, A = PFHospital, PFHospital.Admissions
    QBCore = QBCoreMock
    assert(PFMed.Schema.Start(), 'schema ready')
    assert(A.Start(), 'hospital ready')
    H.Billing.Collect = function() return 'skip' end -- the ledger path is the real-DB spec's
    H.Surgery.WaitFor = function() end
    H.Imaging.WaitFor = function() end
end

local PATIENT, MEDIC, DOC, EMR = 1, 2, 3, 4
local PILLBOX = vector3(330.0, -588.0, 43.3)
local COUNTER, ROOM
local function job(src, grade)
    Mock.players[src].PlayerData.job = { name = 'ambulance', type = 'ems', onduty = true, grade = { level = grade } }
end
local function cb(name, src, ...) return Mock.callCallback('pf-ambulancejob:server:' .. name, src, ...) end
local function advance(s) Mock.clock = Mock.clock + s end
local function bedPos(id)
    for _, d in pairs(Config.Hospital.Facilities.pillbox.departments) do
        for _, b in ipairs(d.beds) do if b.id == id then return vector3(b.coords.x, b.coords.y, b.coords.z) end end
    end
end
local function has(list, item) for _, v in ipairs(list) do if v == item then return true end end return false end
local function indexOf(list, item) for i, v in ipairs(list) do if v == item then return i end end return nil end

--- An open admission with a bed for the patient (through 17E's own create).
local function admitted(dept, bed)
    H.Beds.Claim('pillbox', bed, 'PATCID', -1)
    local a = H.WithLock('cid:PATCID', function()
        return A.Create('PATCID', { hospitalId = 'pillbox', state = dept == 'ed' and 'in_treatment' or 'admitted', dept = dept, bedId = bed, reason = 'checkin' })
    end)
    assert(a, 'admission')
    return a
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.clock = 1700000000
    Mock.players, Mock.coords, Mock.aces = {}, {}, {}
    Mock.invokingResource = nil
    Trace, Stash, Pockets = {}, {}, {}
    STARTED = {}
    DB = { patients = {}, nextId = 100, adm = {}, nextAdm = 0, bills = 0, rx = {}, log = {}, stays = {}, nextStay = 0, ord = {}, nextOrd = 0, tx = {} }
    boot()
    COUNTER = Config.Hospital.Pharmacy.Counters.pillbox.coords
    ROOM = Config.Hospital.Surgery.Rooms[1].coords
    for src, cid in pairs({ [PATIENT] = 'PATCID', [MEDIC] = 'MEDCID', [DOC] = 'DOCCID', [EMR] = 'EMRCID' }) do
        local p = Mock.newPlayer(src, cid)
        p.PlayerData.metadata.injail = 0
        Mock.fireEvent('QBCore:Server:PlayerLoaded', nil, p)
        Mock.coords[src] = PILLBOX
    end
    job(MEDIC, 1) -- tier 3 (paramedic)
    job(DOC, 3)   -- tier 5, surgeon by the grade fallback
    job(EMR, 0)   -- tier 1
end

describe('discharge orders with prescriptions', function()
    it('are accepted now (17E refused them) and validated against the formulary', function()
        local out, why = A.CleanOrders({ prescriptions = { { drug = 'painkillers', units = 6, fills = 2 } } })
        assert_true(out ~= nil, tostring(why))
        assert_eq(out.prescriptions[1].drug, 'painkillers')
        assert_eq(out.prescriptions[1].units, 6)
        assert_eq(select(2, A.CleanOrders({ prescriptions = { { drug = 'fentanyl', units = 1 } } })), 'That is not on the formulary.')
        assert_eq(A.CleanOrders({ prescriptions = { { drug = 'painkillers', units = 99 } } }), nil)
        assert_eq(select(2, A.CleanOrders({ prescriptions = { { drug = 'bandage' }, { drug = 'bandage' } } })), 'One prescription per drug.')
        assert_true(A.CleanOrders({ prescriptions = {} }) ~= nil, 'an empty list is no prescription')
        assert_true(A.CleanOrders({ restrictions = { { kind = 'no_sprint', hours = 2 } } }) ~= nil)
    end)
    it('need a physician: a nurse-level discharge and a system export with prescriptions are refused', function()
        local a = admitted('ward', 'w1')
        assert_eq(A.Discharge(MEDIC, a.id, { prescriptions = { { drug = 'painkillers', units = 2 } } }).error, 'no_permission')
        local res = A.ExportDischargePatient(a.id, { actor = { kind = 'system', label = 'spec' }, orders = { prescriptions = { { drug = 'painkillers' } } } })
        assert_eq(res.error, 'no_permission')
        assert_true(A.ById(a.id) ~= nil, 'still open')
        local ok = A.Discharge(DOC, a.id, { prescriptions = { { drug = 'painkillers', units = 2 } } })
        assert_true(ok.ok, tostring(ok.message))
        assert_eq(#DB.rx, 1)
        assert_eq(DB.rx[1].idem_key, ('pf-ambulancejob:rx:%d:painkillers'):format(a.id))
        assert_eq(DB.rx[1].prescriber_cid, 'DOCCID')
        assert_eq(DB.rx[1].admission_id, a.id)
    end)
end)

describe('pharmacy counter and ward drugs', function()
    it('a fill is reserved and logged before the stock moves; short stock gives it back and removes the row', function()
        local a = admitted('ward', 'w1')
        Mock.coords[DOC], Mock.coords[PATIENT] = bedPos('w1'), bedPos('w1')
        local rx = cb('rxPrescribe', DOC, PATIENT, 'painkillers', 3, 1)
        assert_true(rx.ok, tostring(rx.message))
        Mock.coords[PATIENT] = COUNTER
        Trace = {}
        assert_eq(cb('pharmacyCollect', PATIENT).error, 'conflict')
        assert_eq(table.concat(Trace, ','), 'reserve,log:dispense,remove:pf_pharmacy_pillbox:painkillers,undo,unlog')
        assert_eq(next(DB.log), nil)
        assert_eq(DB.rx[rx.prescriptionId].dispensed, 0)
        assert_eq(Pockets[PATIENT], nil, 'nothing handed out')
        Stash.pf_pharmacy_pillbox = { painkillers = 3 }
        Trace = {}
        advance(5)
        local c = cb('pharmacyCollect', PATIENT)
        assert_true(c.ok, tostring(c.message))
        assert_true(indexOf(Trace, 'log:dispense') < indexOf(Trace, 'remove:pf_pharmacy_pillbox:painkillers'))
        assert_eq(Pockets[PATIENT].painkillers, 3)
        assert_eq(DB.log[('pf-ambulancejob:rx:%d:1'):format(rx.prescriptionId)].qty, 3)
    end)
    it('ward drugs need the scope tier and a patient admitted here; the controlled row comes first', function()
        local a = admitted('ward', 'w1')
        Mock.coords[EMR], Mock.coords[MEDIC] = COUNTER, COUNTER
        Stash.pf_pharmacy_pillbox = { morphine = 4 }
        assert_eq(cb('pharmacyWithdraw', EMR, 'morphine', 1, PATIENT).error, 'no_permission')
        assert_eq(cb('pharmacyWithdraw', MEDIC, 'morphine', 9, PATIENT).error, 'bad_args')
        advance(2)
        assert_eq(cb('pharmacyWithdraw', MEDIC, 'morphine', 1, DOC).error, 'invalid_state', 'not a patient here')
        advance(2)
        Trace = {}
        local w = cb('pharmacyWithdraw', MEDIC, 'morphine', 2, PATIENT)
        assert_true(w.ok, tostring(w.message))
        assert_eq(Trace[1], 'log:withdraw')
        local row
        for _, r in pairs(DB.log) do row = r end
        assert_true(row.controlled)
        assert_eq(row.admission_id, a.id)
        assert_eq(Pockets[MEDIC].morphine, 2)
        -- a stash that cannot give: the row is removed again
        Stash.pf_pharmacy_pillbox = {}
        advance(2)
        Trace = {}
        assert_eq(cb('pharmacyWithdraw', MEDIC, 'morphine', 1, PATIENT).error, 'conflict')
        assert_eq(table.concat(Trace, ','), 'log:withdraw,remove:pf_pharmacy_pillbox:morphine,unlog')
    end)
end)

describe('pharmacy stock and cancels (check fixes)', function()
    it('staff never open the stock stash: a read-only view and a restock logged before the items move', function()
        Mock.coords[MEDIC] = COUNTER
        Stash.pf_pharmacy_pillbox = { morphine = 3, painkillers = 7 }
        assert_eq(cb('pharmacyStock', MEDIC).error, 'no_permission', 'below the log tier')
        Mock.coords[DOC] = COUNTER
        Trace = {}
        local v = cb('pharmacyStock', DOC)
        assert_true(v.ok, tostring(v.message))
        for _, e in ipairs(Trace) do assert_true(e:sub(1, 5) ~= 'open:', 'the stash was opened to a player') end
        local seen = {}
        for _, r in ipairs(v.list) do seen[r.item] = r end
        assert_eq(seen.morphine.amount, 3)
        assert_true(seen.morphine.controlled)
        assert_eq(seen.painkillers.amount, 7)
        Pockets[DOC] = { morphine = 2 }
        Trace = {}
        local r = cb('pharmacyRestock', DOC, 'morphine', 2)
        assert_true(r.ok, tostring(r.message))
        assert_eq(table.concat(Trace, ','), 'log:restock,remove:' .. DOC .. ':morphine,add:pf_pharmacy_pillbox:morphine')
        assert_eq(Stash.pf_pharmacy_pillbox.morphine, 5)
        local row
        for _, l in pairs(DB.log) do if l.kind == 'restock' then row = l end end
        assert_true(row.controlled)
        advance(2)
        Trace = {}
        assert_eq(cb('pharmacyRestock', DOC, 'morphine', 4).error, 'conflict', 'not carried')
        assert_eq(table.concat(Trace, ','), 'log:restock,remove:' .. DOC .. ':morphine,unlog')
        advance(2)
        assert_eq(cb('pharmacyRestock', DOC, 'pistol_ammo', 1).error, 'bad_args')
    end)
    it('a physician cancels only a pharmacy prescription of the hospital they stand in', function()
        local now = os.time()
        DB.rx[1] = { id = 1, citizenid = 'PATCID', drug = 'painkillers', state = 'active', qty = 3, dispensed = 0, custody_ref = 'order:9', expires_at = now + 999 }
        DB.rx[2] = { id = 2, citizenid = 'PATCID', drug = 'painkillers', state = 'active', qty = 1, dispensed = 0, hospital_id = 'paleto', expires_at = now + 999 }
        DB.rx[3] = { id = 3, citizenid = 'PATCID', drug = 'antibiotics', state = 'active', qty = 1, dispensed = 0, hospital_id = 'pillbox', expires_at = now + 999 }
        Mock.coords[DOC] = PILLBOX
        assert_eq(cb('rxCancel', DOC, 1).error, 'not_found', 'an infirmary dose schedule is not the pharmacy\'s')
        assert_eq(DB.rx[1].state, 'active')
        assert_eq(cb('rxCancel', DOC, 2).error, 'too_far', 'another hospital\'s prescription')
        assert_eq(DB.rx[2].state, 'active')
        assert_eq(cb('rxCancel', MEDIC, 3).error, 'no_permission')
        assert_true(cb('rxCancel', DOC, 3).ok)
        assert_eq(DB.rx[3].state, 'cancelled')
    end)
end)

describe('lab and imaging', function()
    it('a sample is read from the engine state and the character, not from anything the client sends', function()
        local p = PFMed.Store.Get('PATCID')
        p.toxins = { ethanol = 0.21 }
        Mock.players[PATIENT].PlayerData.metadata.bloodtype = 'O-'
        assert_eq(H.Lab.Sample('PATCID', 'bac', Mock.players[PATIENT], os.time()).values.bac, 0.21)
        assert_eq(H.Lab.Sample('PATCID', 'blood_type', Mock.players[PATIENT], os.time()).values.bloodType, 'O-')
        p.blood_ml = 3500
        local cbc = H.Lab.Sample('PATCID', 'cbc', Mock.players[PATIENT], os.time()).values
        assert_true(cbc.hemoglobin < 14.5 and cbc.platelets < 250, 'blood loss shows in the count')
    end)
    it('ordering follows the tiers and needs an open admission', function()
        Mock.coords[DOC] = PILLBOX
        assert_eq(cb('labOrder', DOC, PATIENT, 'cbc').error, 'invalid_state', 'no admission')
        admitted('ward', 'w1')
        advance(2)
        assert_eq(cb('labOrder', MEDIC, PATIENT, 'cbc').error, 'no_permission', 'a paramedic does not order labs')
        assert_eq(cb('imagingOrder', MEDIC, PATIENT, 'ct').error, 'no_permission', 'imaging is ordered by a physician')
        assert_eq(cb('labOrder', DOC, PATIENT, 'dna').error, 'bad_args')
        advance(2)
        assert_true(cb('labOrder', DOC, PATIENT, 'cbc').ok)
    end)
end)

describe('stays on the bill', function()
    local function beds(a, rows)
        DB.stays[a.id] = rows
        local out = {}
        for _, l in ipairs(H.Billing.Lines(a)) do if l.kind == 'bed' then out[#out + 1] = l end end
        return out
    end
    it('replace 17E\'s single bed line: the admission\'s time in started hours, split over the rates by time', function()
        local a = admitted('ward', 'w1')
        local t = os.time()
        a.discharged_at = t + 3 * 3600
        local before = H.Billing.Lines(a)
        local T = Config.Hospital.Tariff.BedHour
        -- 1 h ward + 2 h ICU: three hours, one line per rate
        local b = beds(a, { { id = 7, dept = 'ward', level = 'ward', started_at = t, ended_at = t + 3600 },
            { id = 8, dept = 'ward', level = 'icu', started_at = t + 3600, ended_at = t + 3 * 3600 } })
        assert_eq(#b, 2)
        assert_eq(b[1].ref_id, 7)
        assert_eq(b[1].qty * b[1].unit_price, T.ward)
        assert_eq(b[2].qty, 2)
        assert_eq(b[2].unit_price, T.icu)
        -- 10 min ED + 10 min ward: one started hour for the admission, not one per stay
        b = beds(a, { { id = 1, dept = 'ed', level = 'ed', started_at = t, ended_at = t + 600 },
            { id = 2, dept = 'ward', level = 'ward', started_at = t + 600, ended_at = t + 1200 } })
        local hours = 0
        for _, l in ipairs(b) do hours = hours + l.qty end
        assert_eq(hours, 1)
        -- toggling ICU/standard four times in 80 minutes: two hours (40 min at each rate), not four
        b = beds(a, { { id = 11, dept = 'ward', level = 'ward', started_at = t, ended_at = t + 1200 },
            { id = 12, dept = 'ward', level = 'icu', started_at = t + 1200, ended_at = t + 2400 },
            { id = 13, dept = 'ward', level = 'ward', started_at = t + 2400, ended_at = t + 3600 },
            { id = 14, dept = 'ward', level = 'icu', started_at = t + 3600, ended_at = t + 4800 } })
        assert_eq(#b, 2, 'one line per rate')
        assert_eq(b[1].qty + b[2].qty, 2)
        assert_eq(b[1].qty * b[1].unit_price + b[2].qty * b[2].unit_price, T.ward + T.icu)
        -- without stay rows the 17E line stays as it was
        DB.stays[a.id] = nil
        local plain = H.Billing.Lines(a)
        assert_eq(#plain, #before)
    end)
    it('a care level is set by a physician on a bed patient and opens a new stay', function()
        local a = admitted('ward', 'w1')
        Mock.coords[MEDIC], Mock.coords[DOC] = PILLBOX, PILLBOX
        assert_eq(H.Stays.current[a.id].level, 'ward', 'the admission opened its stay')
        assert_eq(H.Stays.SetLevel(MEDIC, a.id, 'icu').error, 'no_permission')
        assert_eq(H.Stays.SetLevel(DOC, a.id, 'spa').error, 'bad_args')
        advance(2)
        local r = H.Stays.SetLevel(DOC, a.id, 'icu')
        assert_true(r.ok, tostring(r.message))
        assert_eq(H.Stays.current[a.id].level, 'icu')
        advance(2)
        assert_true(H.Stays.SetLevel(DOC, a.id, 'icu').unchanged)
    end)
end)

local captured
describe('surgery', function()
    local function setup()
        local a = admitted('ed', 'ed1')
        local inj = PFMed.Engine.AddInjury('PATCID', { mechanism = 'firearm', type = 'gunshot', subtype = 'retained', region = 'thigh_l', severity = 3,
            attrs = { weapon = 453432689, caliber = 'SMALL_CALIBER', projectile = true }, attackerCid = 'SHOOTER1' }, { key = 'spec:b20:gsw' })
        assert_true(inj ~= nil, 'injury')
        Mock.coords[PATIENT] = bedPos('ed1')
        Mock.coords[DOC], Mock.coords[MEDIC] = ROOM, ROOM
        return a, inj
    end
    it('needs a surgeon in the room, the patient in their bed there and a confirmed diagnosis', function()
        local a, inj = setup()
        local confirmed = false
        PFMed.Diagnosis.HasDiagnosis = function(cid, f) return confirmed and cid == 'PATCID' and f.injuryId == inj.id and f.statuses.confirmed == true end
        assert_eq(cb('surgery', MEDIC, PATIENT, inj.id, 'surgery_trauma').error, 'no_permission')
        advance(3)
        assert_eq(cb('surgery', DOC, PATIENT, inj.id, 'surgery_trauma').error, 'invalid_state', 'no confirmed diagnosis')
        confirmed = true
        advance(3)
        Mock.coords[DOC] = PILLBOX
        assert_eq(cb('surgery', DOC, PATIENT, inj.id, 'surgery_trauma').error, 'too_far', 'outside the operating room')
        Mock.coords[DOC] = ROOM
        advance(3)
        Mock.coords[PATIENT] = bedPos('ed1') + vector3(0.0, 3.5, 0.0)
        assert_eq(cb('surgery', DOC, PATIENT, inj.id, 'surgery_trauma').error, 'invalid_state', 'not lying in the bed')
        Mock.coords[PATIENT] = bedPos('ed1')
        advance(3)
        assert_eq(cb('surgery', DOC, PATIENT, inj.id, 'surgery_burn').error, 'bad_args')
        advance(3)
        Mock.reset()
        local op = cb('surgery', DOC, PATIENT, inj.id, 'surgery_trauma')
        assert_true(op.ok, tostring(op.message))
        assert_true(op.projectileRecovered)
        local n = 0
        for _, e in ipairs(Mock.serverEvents) do
            if e.name == 'pf-ambulancejob:server:projectileRecovered' then n = n + 1 captured = { cid = e.args[1], p = e.args[2] } end
        end
        assert_eq(n, 1)
        assert_eq(captured.cid, 'PATCID')
        assert_eq(captured.p.injuryId, inj.id)
        assert_eq(captured.p.caliber, 'SMALL_CALIBER')
        assert_eq(captured.p.weaponHash, 453432689)
        assert_eq(captured.p.attackerCid, 'SHOOTER1')
        assert_eq(captured.p.byCid, 'DOCCID')
        assert_eq(DB.tx[1].action, 'surgery_trauma')
        assert_eq(DB.tx[1].admission_id, a.id)
        local stored = PFMed.Store.Peek('PATCID').injuries[inj.id]
        assert_true(stored.treatments.surgery ~= nil)
        assert_true(stored.attrs.projectileRecovered ~= nil)
        -- once: a second operation is refused and raises nothing
        advance(3)
        Mock.reset()
        assert_eq(cb('surgery', DOC, PATIENT, inj.id, 'surgery_trauma').error, 'invalid_state')
        for _, e in ipairs(Mock.serverEvents) do assert_true(e.name ~= 'pf-ambulancejob:server:projectileRecovered') end
    end)
end)

-- The payload as pfm-policejob's evidence lab receives it (the real handler, contract 4.1 / 18D).
describe('projectile contract with pfm-policejob', function()
    it('L.OnProjectileRecovered accepts the payload from pf-ambulancejob and keys the evidence on the injury', function()
        assert_true(captured ~= nil, 'the surgery test captured a payload')
        function GetCurrentResourceName() return 'pfm-policejob' end
        Mock.exportsByResource['pf-government'] = { HasQualification = function() return false end }
        QBCore = Mock.coreObject()
        Config = nil
        load_resource('pfm-policejob/config.lua')
        load_resource('pfm-policejob/config_evidence.lua')
        load_resource('pfm-policejob/server/schema.lua')
        load_resource('pfm-policejob/server/commands.lua')
        load_resource('pfm-policejob/server/evidence/store.lua')
        load_resource('pfm-policejob/server/evidence/custody.lua')
        load_resource('pfm-policejob/server/evidence/scene.lua')
        load_resource('pfm-policejob/server/evidence/api.lua')
        load_resource('pfm-policejob/server/evidence/lab.lua')
        PFPoliceSchema.state = 'ready'
        local seen
        PFEvidence.Api.Internal.CreateEvidence = function(spec, opts) seen = { spec = spec, opts = opts } return { ok = true, evidenceId = 1 } end
        PFEvidence.Store.EnsureLocker = function(station, label, stash) return { id = 1, station = station, label = label, stash_id = stash } end
        Mock.invokingResource = 'pf-ambulancejob'
        local res = PFEvidence.Lab.OnProjectileRecovered(captured.cid, captured.p)
        Mock.invokingResource = nil
        assert_true(res and res.ok, tostring(res and res.error))
        assert_eq(seen.opts.key, 'pf-ambulancejob:projectile:' .. tostring(captured.p.injuryId))
        assert_eq(seen.spec.kind, 'projectile')
        assert_eq(seen.spec.attrs.caliber, 'SMALL_CALIBER')
        assert_eq(seen.spec.attrs.weaponHash, 453432689)
    end)
end)
