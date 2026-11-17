-- pf-emsmdt batch 21D end to end on a real database: the hospital workstation's handlers
-- (server/hospital_app.lua) driving the real pf-ambulancejob (17E admissions, beds and bills, 20A
-- lab) through its exports and its own server callbacks, as pfm-core holds them, with the real ledger.
-- A patient checks in; a physician at the workstation triages, admits to an ED bed, orders a lab
-- test and discharges with a restriction; the rows, the bed, the order and the one bill are real.
-- Refusals of pf-ambulancejob (too far, scope of practice) come back unchanged.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
STARTED = {}
function GetResourceState(res) return (STARTED[res] ~= false) and 'started' or 'missing' end
function GetEntityHealth() return 200 end
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

-- other resources: the phone (invoices), the inventory (stashes and pockets)
Mock.exportsByResource['pfm-phone'] = { CreateInvoice = function() return 901 end }
Stash, Pockets = {}, {}
Mock.exportsByResource['pfm-inventory'] = {
    RemoveItem = function(_, id, item, n)
        n = n or 1
        local bag = type(id) == 'string' and Stash or Pockets
        bag[id] = bag[id] or {}
        if (bag[id][item] or 0) < n then return false end
        bag[id][item] = bag[id][item] - n
        return true
    end,
    AddItem = function(_, id, item, n)
        local bag = type(id) == 'string' and Stash or Pockets
        bag[id] = bag[id] or {}
        bag[id][item] = (bag[id][item] or 0) + (n or 1)
        return true
    end,
    CreateInventory = function(_, id) Stash[id] = Stash[id] or {} end,
    OpenInventory = function() end,
    HasItem = function() return true end,
}
QBCoreMock.Commands.Add = function() end

function GetCurrentResourceName() return 'pf-ambulancejob' end
Config = nil
load_resource('pfm-banking/payouts.lua')
local AJ = '[pfscripts]/pf-ambulancejob/'
for _, f in ipairs({ 'config.lua', 'config_medical.lua', 'config_hospital.lua', 'shared/framework.lua', 'shared/medical/anatomy.lua',
    'shared/medical/injuries.lua', 'shared/medical/physiology_model.lua', 'shared/medical/effects_model.lua', 'shared/medical/findings.lua',
    'server/main.lua' }) do
    load_resource(AJ .. f)
end
for k, v in pairs(bankingConfig) do if Config[k] == nil then Config[k] = v end end
Config.WipeInventoryOnRespawn = false

local SERVER = { 'server/medical/schema.lua', 'server/medical/store.lua', 'server/medical/engine.lua', 'server/medical/downstate.lua',
    'server/medical/effects.lua', 'server/medical/api.lua', 'server/medical/diagnosis.lua', 'server/medical/exam.lua', 'server/medical/recovery.lua',
    'server/hospital/facility.lua', 'server/hospital/beds.lua', 'server/hospital/admissions.lua', 'server/hospital/billing.lua',
    'server/hospital/ai_care.lua', 'server/hospital/pharmacy.lua', 'server/hospital/lab.lua', 'server/hospital/imaging.lua',
    'server/hospital/surgery.lua' }

-- (re)loads the server modules, as a resource restart does: empty memory, same database
local function restart()
    for _, ev in ipairs({ 'QBCore:Server:PlayerLoaded', 'pf-ambulancejob:server:admissionChanged', 'pfm-core:server:characterDeleted' }) do
        Mock.eventHandlers[ev] = nil
    end
    PFHospital = nil
    for _, f in ipairs(SERVER) do load_resource(AJ .. f) end
    Mock.exportsByResource['pf-ambulancejob'] = Mock.exportsByResource['__self']
    PFMed.Engine.Random = function() return 0.5 end
    PFMed.Diagnosis.Random = function() return 0 end -- every sign that can be found is found
    assert(PFMed.Schema.Start(), 'medical tables')
    assert(PFHospital.Admissions.Start(), 'hospital ready')
    PFHospital.Pharmacy.Start()
    assert(PFHospital.Stays.Start(os.time()), 'stays ready')
    PFHospital.Imaging.WaitFor = function() end
    PFHospital.Surgery.WaitFor = function() end
    PFHospital.Orders.Recover() -- what the start does once the tables are ready
    return PFHospital
end
local H = restart()
Mock.exportsByResource['pf-ambulancejob'] = Mock.exportsByResource['__self']
-- pfm-core keeps the server callbacks pf-ambulancejob registered; GetCoreObject hands them out
QBCoreMock.ServerCallbacks = Mock.callbacks
Config.SupervisorGrades = { ambulance = { [2] = true } }
LoadResourceFile = function() return nil end
load_resource('[pfscripts]/pf-emsmdt/server/hospital_app.lua')
local HA = PFHospitalApp

local PATIENT, DOC, FAR = 1, 3, 4
local function online(src, cid)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.money = { cash = 0, bank = 50000 }
    p.PlayerData.metadata.injail = 0
    Mock.fireEvent('QBCore:Server:PlayerLoaded', nil, p)
    return p
end
local reception = Config.Hospital.Facilities.pillbox.reception.coords
local function rpc(method, src, payload) return Mock.cross(function(s, p) return HA.Handlers[method](s, p) end, src, payload or {}) end

Mock.players, Mock.coords = {}, {}
online(PATIENT, 'RDB21PAT')
online(DOC, 'RDB21DOC').PlayerData.job = { name = 'ambulance', type = 'ems', onduty = true, grade = { level = 2 } }
online(FAR, 'RDB21FAR').PlayerData.job = { name = 'ambulance', type = 'ems', onduty = true, grade = { level = 2 } }
Mock.coords[PATIENT], Mock.coords[DOC], Mock.coords[FAR] = reception, reception, vector3(0.0, 0.0, 0.0)

local admissionId
describe('b21 hospital workstation drives the real pf-ambulancejob', function()
    it('the patient checks in and shows on the board with a name', function()
        local res = Mock.callCallback('pf-ambulancejob:server:checkIn', PATIENT, 'pillbox')
        assert_true(res.ok, tostring(res.message))
        admissionId = res.admissionId
        local init = rpc('init', DOC)
        assert_true(init.ok, tostring(init.error))
        assert_eq(init.facilities[1].id, 'pillbox')
        local found = false
        for _, f in ipairs(init.facilities) do if f.id == 'bolingbroke' then found = true end end
        assert_true(found, 'the infirmary probed by id')
        local board = rpc('board', DOC, { facility = 'pillbox' })
        assert_true(board.ok, tostring(board.error))
        assert_eq(board.admissions[1].id, admissionId)
        assert_eq(board.admissions[1].state, 'checked_in')
        assert_eq(board.admissions[1].name, 'Test Player1')
    end)
    it('a medic outside the hospital is refused by pf-ambulancejob itself', function()
        Mock.clock = Mock.clock + 10
        local res = rpc('triage', FAR, { facility = 'pillbox', admissionId = admissionId, level = 'red' })
        assert_eq(res.ok, false)
        assert_eq(res.error, 'too_far')
        assert_eq(MySQL.scalar.await('SELECT triage FROM pf_hosp_admissions WHERE id = ?', { admissionId }) == 'red', false)
    end)
    it('triage and admit write the admission row and take a bed', function()
        Mock.clock = Mock.clock + 10
        local t = rpc('triage', DOC, { facility = 'pillbox', admissionId = admissionId, level = 'red' })
        assert_true(t.ok, tostring(t.message))
        Mock.clock = Mock.clock + 10
        local a = rpc('admit', DOC, { facility = 'pillbox', admissionId = admissionId, dept = 'ed' })
        assert_true(a.ok, tostring(a.message))
        local row = MySQL.single.await('SELECT state, triage, dept, bed_id FROM pf_hosp_admissions WHERE id = ?', { admissionId })
        assert_eq(row.state, 'in_treatment')
        assert_eq(row.triage, 'red')
        assert_eq(row.bed_id, a.bedId)
        local board = rpc('board', DOC, { facility = 'pillbox' })
        local ed
        for _, b in ipairs(board.beds) do if b.dept == 'ed' then ed = b end end
        assert_eq(ed.free, ed.total - 1)
    end)
    it('a lab order lands in the queue (without its result)', function()
        Mock.clock = Mock.clock + 10
        local o = rpc('labOrder', DOC, { facility = 'pillbox', admissionId = admissionId, test = 'bac' })
        assert_true(o.ok, tostring(o.message))
        local q = rpc('orders', DOC, { facility = 'pillbox', kind = 'lab' })
        assert_true(q.ok, tostring(q.error))
        assert_eq(q.orders[1].id, o.orderId)
        assert_eq(q.orders[1].state, 'ordered')
        assert_eq(q.orders[1].hasResult, false)
    end)
    it('discharge with orders closes the admission once and makes the one bill', function()
        Mock.clock = Mock.clock + 3600
        local d = rpc('discharge', DOC, { facility = 'pillbox', admissionId = admissionId, orders = { restrictions = { { kind = 'no_sprint', hours = 6 } } } })
        assert_true(d.ok, tostring(d.message))
        assert_eq(MySQL.scalar.await('SELECT state FROM pf_hosp_admissions WHERE id = ?', { admissionId }), 'discharged')
        assert_eq(MySQL.scalar.await("SELECT kind FROM pf_med_restrictions WHERE citizenid = 'RDB21PAT' ORDER BY id DESC LIMIT 1"), 'no_sprint')
        local again = rpc('discharge', DOC, { facility = 'pillbox', admissionId = admissionId, orders = {} })
        assert_true(again.ok and again.duplicate, 'the per-admission key answers a repeat as a duplicate')
        assert_eq(tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM pf_hosp_bills WHERE admission_id = ?', { admissionId })), 1)
        local bills = rpc('bills', DOC, { facility = 'pillbox' })
        assert_true(bills.ok, tostring(bills.error))
        assert_eq(bills.list[1].admissionId, admissionId)
        assert_true(bills.list[1].total > 0)
        local lines = rpc('billLines', DOC, { billId = bills.list[1].id })
        assert_true(#lines.lines >= 1)
        local hist = rpc('history', DOC, { facility = 'pillbox', state = 'discharged' })
        assert_eq(hist.admissions[1].id, admissionId)
    end)
end)
