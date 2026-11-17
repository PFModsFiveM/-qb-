-- pf-ambulancejob hospital core on a real database (batch 17E): the admission, restriction, bill and
-- bill-line SQL against 17C's migration v5 tables, with the real pfm-banking ledger. A bill is
-- built from server rows only (the admission and pf_med_treatments), charged once from the
-- patient's bank straight to society:ambulance under pf-ambulancejob:bill:<id>:<attempt>; a clear
-- refusal becomes a pfm-phone invoice (ref pf-ambulancejob:bill:<id>) that is paid when pfm-phone
-- reports it settled; an unclear charge is looked up by its key and never charged twice. Moves are
-- conditional (two closers cannot both win) and bed occupancy is rebuilt from the rows at start.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
function GetResourceState() return 'started' end
local health = {}
function GetEntityHealth(ped) return health[ped] or 200 end
function GetPedArmour() return 0 end
function GetEntityAttachedTo() return 0 end
function SetEntityCoords() end
Bags = {}
function Player(src)
    Bags[src] = Bags[src] or {}
    local b = Bags[src]
    return { state = setmetatable({ set = function(_, k, v) b[k] = v end }, { __index = b }) }
end
function AddEventHandler(name, fn)
    local prev = Mock.eventHandlers[name]
    if prev then Mock.eventHandlers[name] = function(...) prev(...) fn(...) end else Mock.eventHandlers[name] = fn end
end

-- the bank
RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
function GetCurrentResourceName() return 'pfm-banking' end
Config = nil
load_resource('pfm-banking/config.lua')
load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')
local bankingConfig = Config
Mock.exportsByResource['pfm-banking'] = Mock.exportsByResource['__self']
Mock.exportsByResource['__self'] = nil
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end
assert(PFLedger.Start(), 'ledger start')
MySQL.query.await("INSERT INTO bank_accounts (account_name, account_balance, account_type, users) VALUES ('ambulance', 0, 'job', '[]') ON DUPLICATE KEY UPDATE account_balance = 0")
MySQL.query.await("INSERT IGNORE INTO pf_ledger_baselines (account, balance) VALUES ('society:ambulance', 0)")

-- the other resources the hospital talks to
Invoices = {}
Mock.exportsByResource['pfm-phone'] = { CreateInvoice = function(_, data) Invoices[#Invoices + 1] = data return 900 + #Invoices end }
Mock.exportsByResource['pfm-inventory'] = { RemoveItem = function() return true end, AddItem = function() return true end }
QBCoreMock.Commands.Add = function() end

-- pf-ambulancejob: the medical store (migrations v1-v5 under the 'pf-ambulancejob' key) and the hospital
function GetCurrentResourceName() return 'pf-ambulancejob' end
Config = nil
load_resource('pfm-banking/payouts.lua')
local AJ = '[pfscripts]/pf-ambulancejob/'
for _, f in ipairs({ 'config.lua', 'config_medical.lua', 'config_hospital.lua', 'shared/framework.lua', 'shared/medical/anatomy.lua',
    'shared/medical/injuries.lua', 'shared/medical/physiology_model.lua', 'shared/medical/effects_model.lua', 'server/main.lua',
    'server/medical/schema.lua', 'server/medical/store.lua', 'server/medical/engine.lua', 'server/medical/downstate.lua',
    'server/medical/effects.lua', 'server/medical/api.lua', 'server/hospital/facility.lua', 'server/hospital/beds.lua',
    'server/hospital/admissions.lua', 'server/hospital/billing.lua', 'server/hospital/ai_care.lua' }) do
    load_resource(AJ .. f)
end
for k, v in pairs(bankingConfig) do if Config[k] == nil then Config[k] = v end end
Mock.exportsByResource['pf-ambulancejob'] = Mock.exportsByResource['__self']
Config.WipeInventoryOnRespawn = false
local H = PFHospital
assert(PFMed.Schema.Start(), 'medical tables')
assert(H.Admissions.Start(), 'hospital ready')

local PATIENT, MEDIC, POOR = 1, 2, 3
local function reception() return Config.Hospital.Facilities.pillbox.reception.coords end
local function cb(name, src, ...) return Mock.callCallback('pf-ambulancejob:server:' .. name, src, ...) end
local function row(id) return MySQL.single.await('SELECT * FROM pf_hosp_admissions WHERE id = ?', { id }) end
local function billOf(admId) return MySQL.single.await('SELECT * FROM pf_hosp_bills WHERE admission_id = ?', { admId }) end
local function ambulance() return tonumber(MySQL.scalar.await("SELECT account_balance FROM bank_accounts WHERE account_name = 'ambulance'")) end
local function txs(prefix) return MySQL.query.await("SELECT * FROM pf_transactions WHERE idempotency_key LIKE ? ORDER BY id", { prefix .. '%' }) end

local function online(src, cid, bank)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.money = { cash = 0, bank = bank or 5000 }
    p.PlayerData.metadata.injail = 0
    Mock.fireEvent('QBCore:Server:PlayerLoaded', nil, p)
    return p
end

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 10000 -- rate limits from the last test are over
    Mock.players, Mock.coords = {}, {}
    Invoices = {}
    online(PATIENT, 'RDBPAT')
    online(MEDIC, 'RDBMED').PlayerData.job = { name = 'ambulance', type = 'ems', onduty = true, grade = { level = 2 } }
    online(POOR, 'RDBPOOR', 20)
    Mock.coords[MEDIC] = reception()
end

local function stay(src, treatments)
    Mock.coords[src] = reception()
    local res = cb('checkIn', src, 'pillbox')
    assert_true(res.ok, tostring(res.message))
    local id = res.admissionId
    local ad = cb('admit', MEDIC, id, 'ed')
    assert_true(ad.ok, 'admitted: ' .. tostring(ad.message))
    for _, t in ipairs(treatments or {}) do
        MySQL.insert.await([[INSERT INTO pf_med_treatments (citizenid, action, by_cid, by_job, location, admission_id, result, at)
            VALUES (?, ?, 'RDBMED', 'ambulance', 'hospital', ?, ?, ?)]], { t.cid or Mock.players[src].PlayerData.citizenid, t.action, id, t.result or 'ok', os.time() })
    end
    Mock.clock = Mock.clock + 2 * 3600 + 30
    local d = cb('discharge', MEDIC, id, { restrictions = { { kind = 'no_sprint', hours = 6 } }, followUpHours = 48 })
    assert_true(d.ok, tostring(d.message))
    return id
end

describe('hospital tables (17C v5) and admission SQL', function()
    it('check-in, admit and discharge write the rows; the discharge writes a restriction row', function()
        local id = stay(PATIENT)
        local r = row(id)
        assert_eq(r.state, 'discharged')
        assert_eq(r.hospital_id, 'pillbox')
        assert_eq(r.dept, 'ed')
        assert_eq(r.bed_id, 'ed1')
        assert_true(tonumber(r.discharged_at) ~= nil)
        local orders = json.decode(r.discharge_orders)
        assert_eq(orders.restrictions[1].kind, 'no_sprint')
        local rs = MySQL.single.await("SELECT * FROM pf_med_restrictions WHERE citizenid = 'RDBPAT' ORDER BY id DESC LIMIT 1")
        assert_eq(rs.kind, 'no_sprint')
        assert_eq(tonumber(rs.until_at), tonumber(rs.from_at) + 6 * 3600)
        assert_eq(rs.by_cid, 'RDBMED')
    end)
    it('a move is conditional on the state it saw (two closers cannot both win)', function()
        Mock.coords[PATIENT] = reception()
        local id = cb('checkIn', PATIENT, 'pillbox').admissionId
        local base = { state = 'left_ama', mode = 'staff', discharged_at = os.time() }
        assert_eq(H.SQL.MoveAdmission(id, 'checked_in', base), 1)
        assert_eq(H.SQL.MoveAdmission(id, 'checked_in', base), 0)
        -- the memory copy was not told: its own move now fails cleanly instead of reopening the row
        local a = H.Admissions.ById(id)
        local moved, err = H.Admissions.Move(a, 'discharged', {}, nil)
        assert_eq(moved, nil)
        assert_eq(err, 'invalid_state')
        assert_eq(row(id).state, 'left_ama')
        H.Admissions.Start() -- drop the stale memory copy
    end)
    it('bed occupancy is rebuilt from the open rows at start', function()
        Mock.coords[PATIENT] = reception()
        local id = cb('checkIn', PATIENT, 'pillbox').admissionId
        assert_true(cb('admit', MEDIC, id, 'ward', 'w2').ok)
        assert_true(H.Admissions.Start())
        local occ = H.Beds.Occupant('pillbox', 'w2')
        assert_eq(occ and occ.admissionId, id)
        assert_eq(H.Admissions.OpenOf('RDBPAT').id, id)
        assert_eq(#H.SQL.ListAdmissions('pillbox', true, 10) >= 1, true)
        Mock.clock = Mock.clock + 5
        assert_true(cb('discharge', MEDIC, id, {}).ok)
        assert_eq(H.Beds.Occupant('pillbox', 'w2'), nil)
    end)
    it('an idempotency key makes AdmitPatient answer a repeat with the same admission', function()
        Mock.invokingResource = 'pfm-prison'
        local r1 = exports['pf-ambulancejob']:AdmitPatient('RDBPOOR', { hospitalId = 'bolingbroke', dept = 'infirmary' }, { key = 'pfm-prison:rdb:1' })
        local r2 = exports['pf-ambulancejob']:AdmitPatient('RDBPOOR', { hospitalId = 'bolingbroke', dept = 'infirmary' }, { key = 'pfm-prison:rdb:1' })
        Mock.invokingResource = nil
        assert_true(r1.ok, tostring(r1.message))
        assert_true(r2.duplicate)
        assert_eq(r2.admissionId, r1.admissionId)
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_hosp_admissions WHERE idem_key = 'pfm-prison:rdb:1'")), 1)
        local res = exports['pf-ambulancejob']:DischargePatient(r1.admissionId, { actor = { kind = 'system', label = 'spec' } })
        assert_true(res.ok)
    end)
end)

describe('bills on the ledger', function()
    it('itemised from the rows only and paid once from the bank to society:ambulance', function()
        local before = ambulance()
        local id = stay(PATIENT, { { action = 'sutures' }, { action = 'txa' }, { action = 'cast', result = 'refused' },
            { action = 'sutures', cid = 'RDBMED' } })
        local bill = billOf(id)
        local t = Config.Hospital.Tariff
        local expected = t.Admission.checkin + 3 * t.BedHour.ed + t.Treatments.sutures + t.Drugs.txa
        assert_eq(tonumber(bill.total), expected)
        assert_eq(bill.state, 'paid')
        local lines = MySQL.query.await('SELECT kind, qty, unit_price FROM pf_hosp_bill_lines WHERE bill_id = ? ORDER BY id', { bill.id })
        assert_eq(#lines, 4)
        local sum = 0
        for _, l in ipairs(lines) do sum = sum + tonumber(l.qty) * tonumber(l.unit_price) end
        assert_eq(sum, expected)
        local list = txs('pf-ambulancejob:bill:' .. bill.id .. ':')
        assert_eq(#list, 1)
        assert_eq(list[1].idempotency_key, 'pf-ambulancejob:bill:' .. bill.id .. ':1:bank')
        assert_eq(list[1].to_account, 'society:ambulance')
        assert_eq(list[1].from_account, 'player:RDBPAT:bank')
        assert_eq(list[1].state, 'completed')
        assert_eq(ambulance(), before + expected)
        -- a sweep, a second collect and a second close of the same admission change nothing
        H.Billing.Sweep(os.time() + 99999)
        H.Billing.Collect(bill.id)
        H.Billing.ForAdmission(H.SQL.GetAdmission(id))
        assert_eq(tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM pf_hosp_bills WHERE admission_id = ?', { id })), 1)
        assert_eq(#txs('pf-ambulancejob:bill:' .. bill.id .. ':'), 1)
        assert_eq(ambulance(), before + expected)
    end)
    it('no funds: a phone invoice with the bill ref, paid when pfm-phone reports it settled', function()
        local before = ambulance()
        local id = stay(POOR)
        local bill = billOf(id)
        assert_eq(bill.state, 'invoiced')
        assert_eq(tonumber(bill.invoice_id), 901)
        assert_eq(Invoices[1].ref, 'pf-ambulancejob:bill:' .. bill.id)
        assert_eq(Invoices[1].candecline, 0)
        assert_eq(ambulance(), before, 'nothing credited without a payment')
        Mock.fireEvent('pfm-phone:server:invoiceSettled', nil, { ref = Invoices[1].ref, amount = Invoices[1].amount, citizenid = 'RDBPOOR' }, 'paid')
        assert_eq(billOf(id).state, 'paid')
        assert_true(tonumber(billOf(id).settled_at) ~= nil)
    end)
    it('an unclear charge waits for its key; a key the ledger never saw is retried under the next number', function()
        local real = PFPayout.Charge
        PFPayout.Charge = function() return false, { ok = false, state = 'pending', unclear = true } end
        local id = stay(PATIENT)
        PFPayout.Charge = real
        local bill = billOf(id)
        assert_eq(bill.state, 'payment_pending')
        assert_eq(bill.pay_key, 'pf-ambulancejob:bill:' .. bill.id .. ':1')
        Mock.clock = Mock.clock + Config.Hospital.Billing.SweepSeconds + 1
        H.Billing.Sweep(os.time())
        bill = billOf(id)
        assert_eq(bill.state, 'paid')
        assert_eq(tonumber(bill.attempt), 2)
        local list = txs('pf-ambulancejob:bill:' .. bill.id .. ':')
        assert_eq(#list, 1)
        assert_eq(list[1].idempotency_key, 'pf-ambulancejob:bill:' .. bill.id .. ':2:bank')
    end)
end)
