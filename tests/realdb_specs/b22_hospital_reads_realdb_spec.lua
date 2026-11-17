-- Batch 22 (22C) on a real database: pf-ambulancejob's read exports for the hospital workstation
-- (ListBills, GetBillLines, GetStaffTier, ListBeds; allowlist pf-emsmdt) and pf-emsmdt
-- server/hospital_app.lua reading bills, bill lines, the viewer's tier and the free beds through them
-- instead of its own SELECTs on pf-ambulancejob's tables. Real pf-ambulancejob modules, real tables.
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


local DOC, EMT, CIV = 3, 5, 6
local function rpc(method, src, payload) return Mock.cross(function(s, p) return HA.Handlers[method](s, p) end, src, payload or {}) end
local function as(res) Mock.invokingResource = res end
local aj = exports['pf-ambulancejob']
local T = os.time()

local function player(cid, first, last)
    MySQL.query.await('INSERT INTO players (citizenid, license, name, money, charinfo, job, gang, position, metadata, inventory) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        { cid, 'license:' .. cid, first, '{}', json.encode({ firstname = first, lastname = last }), '{}', '{}', '{}', '{}', '[]' })
end
player('B22ANN', 'Annie', 'Lark')
player('B22BOB', 'Bobby', 'Stoneman')
local function bill(cid, hospital, state, total, discount)
    local id = MySQL.insert.await([[INSERT INTO pf_hosp_bills (citizenid, admission_id, hospital_id, total, discount, state, created_at)
        VALUES (?, 5, ?, ?, ?, ?, ?)]], { cid, hospital, total, discount, state, T })
    MySQL.insert.await('INSERT INTO pf_hosp_bill_lines (bill_id, kind, label, qty, unit_price) VALUES (?, ?, ?, ?, ?), (?, ?, ?, ?, ?)',
        { id, 'admission', 'Check-in', 1, 250, id, 'bed', 'Ward', 2, 100 })
    return tonumber(id)
end
-- this spec owns the bills table: start empty
MySQL.query.await('DELETE FROM pf_hosp_bills')
local b1 = bill('B22ANN', 'pillbox', 'paid', 450, 0)
local b2 = bill('B22BOB', 'pillbox', 'invoiced', 900, 450)
local b3 = bill('B22ANN', 'paleto', 'open', 300, 0)
for i = 1, 26 do bill('B22BOB', 'pillbox', 'open', 100 + i, 0) end

Mock.players, Mock.coords = {}, {}
local function staff(src, cid, grade, onduty)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.job = { name = 'ambulance', type = 'ems', onduty = onduty ~= false, grade = { level = grade } }
    return p
end
staff(DOC, 'B22DOC', 2)
staff(EMT, 'B22EMT', 0)
Mock.newPlayer(CIV, 'B22CIV')

describe('22C pf-ambulancejob ListBills / GetBillLines (MariaDB)', function()
    it('pages a hospital\'s bills newest first, by state and by citizen ids', function()
        as('pf-emsmdt')
        local p1 = aj:ListBills({ hospitalId = 'pillbox', limit = 26 })
        assert_true(p1.ok, tostring(p1.error))
        assert_eq(#p1.list, 26)
        assert_true(p1.list[1].id > p1.list[2].id, 'newest first')
        local p2 = aj:ListBills({ hospitalId = 'pillbox', limit = 26, offset = 25 })
        assert_eq(#p2.list, 3)
        assert_eq(p2.list[3].id, b1)
        local inv = aj:ListBills({ hospitalId = 'pillbox', state = 'invoiced' })
        assert_eq(#inv.list, 1)
        assert_eq(inv.list[1].id, b2)
        assert_eq(inv.list[1].due, 450)
        assert_eq(inv.list[1].admissionId, 5)
        assert_eq(#aj:ListBills({ hospitalId = 'pillbox', cids = { 'B22ANN' } }).list, 1)
        assert_eq(#aj:ListBills({ hospitalId = 'paleto' }).list, 1)
        assert_eq(#aj:ListBills({ hospitalId = 'pillbox', cids = { 'bad id!' } }).list, 0, 'no valid id: nothing')
        as(nil)
    end)
    it('refuses an unknown hospital, state or too many ids, and resources not on the list', function()
        as('pf-emsmdt')
        assert_eq(aj:ListBills({ hospitalId = 'nowhere' }).error, 'bad_args')
        assert_eq(aj:ListBills({ hospitalId = 'pillbox', state = 'stolen' }).error, 'bad_args')
        local many = {}
        for i = 1, 52 do many[i] = 'C' .. i end
        assert_eq(aj:ListBills({ hospitalId = 'pillbox', cids = many }).error, 'bad_args')
        as('pfm-prison')
        assert_eq(aj:ListBills({ hospitalId = 'pillbox' }).error, 'not_allowed')
        assert_eq(aj:GetBillLines(b2).error, 'not_allowed')
        assert_eq(aj:ListBeds('pillbox').error, 'not_allowed')
        assert_eq(aj:GetStaffTier(DOC).error, 'not_allowed')
        as(nil)
    end)
    it('reads one bill with its lines, limited to a hospital when asked', function()
        as('pf-emsmdt')
        local r = aj:GetBillLines(b2)
        assert_true(r.ok, tostring(r.error))
        assert_eq(r.bill.hospitalId, 'pillbox')
        assert_eq(r.bill.discount, 450)
        assert_eq(#r.lines, 2)
        assert_eq(r.lines[2].amount, 200)
        assert_eq(aj:GetBillLines(b3, { hospitalId = 'pillbox' }).error, 'not_found')
        assert_true(aj:GetBillLines(b3, { hospitalId = 'paleto' }).ok)
        assert_eq(aj:GetBillLines(99999999).error, 'not_found')
        assert_eq(aj:GetBillLines('x').error, 'bad_args')
        as(nil)
    end)
end)

describe('22C pf-ambulancejob GetStaffTier / ListBeds', function()
    it('tier of on-duty staff from the server; others are not staff', function()
        as('pf-emsmdt')
        local d = aj:GetStaffTier(DOC)
        assert_true(d.ok)
        assert_eq(d.staff, true)
        assert_eq(d.tier, 5)
        assert_eq(aj:GetStaffTier(EMT).tier, 1)
        local c = aj:GetStaffTier(CIV)
        assert_eq(c.staff, false)
        assert_eq(c.tier, 0)
        Mock.players[EMT].PlayerData.job.onduty = false
        assert_eq(aj:GetStaffTier(EMT).staff, false)
        Mock.players[EMT].PlayerData.job.onduty = true
        assert_eq(aj:GetStaffTier(77).error, 'offline')
        assert_eq(aj:GetStaffTier('x').error, 'bad_args')
        as(nil)
    end)
    it('lists every bed of a facility with its live occupancy, no patient identity', function()
        as('pf-emsmdt')
        local before = aj:ListBeds('pillbox')
        assert_true(before.ok)
        assert_true(#before.beds > 0)
        local first = before.beds[1]
        assert_true(H.Beds.Claim('pillbox', first.id, 'B22ANN', 4242))
        local after = aj:ListBeds('pillbox')
        local row
        for _, b in ipairs(after.beds) do if b.id == first.id and b.dept == first.dept then row = b end end
        assert_eq(row.occupied, true)
        assert_eq(row.admissionId, 4242)
        assert_eq(row.citizenid, nil)
        assert_eq(aj:ListBeds('nowhere').error, 'bad_args')
        H.Beds.Release('pillbox', first.id, 4242)
        as(nil)
    end)
end)

describe('22C hospital workstation reads through the exports', function()
    it('bills: 25 a page, by state and name, names from players', function()
        local p1 = rpc('bills', DOC, { facility = 'pillbox' })
        assert_true(p1.ok, tostring(p1.error))
        assert_eq(#p1.list, 25)
        assert_eq(p1.more, true)
        local p2 = rpc('bills', DOC, { facility = 'pillbox', page = 2 })
        assert_eq(#p2.list, 3)
        assert_eq(p2.more, false)
        assert_eq(p2.list[3].id, b1)
        local res = rpc('bills', DOC, { facility = 'pillbox', state = 'invoiced', q = 'stoneman' })
        assert_eq(#res.list, 1)
        assert_eq(res.list[1].id, b2)
        assert_eq(res.list[1].due, 450)
        assert_eq(res.list[1].name, 'Bobby Stoneman')
        assert_eq(#rpc('bills', DOC, { facility = 'pillbox', state = 'paid', q = 'B22BOB' }).list, 0)
        assert_eq(rpc('bills', EMT, { facility = 'pillbox' }).error, 'no_permission')
    end)
    it('bill lines of a known facility only', function()
        local res = rpc('billLines', DOC, { billId = b2 })
        assert_true(res.ok, tostring(res.error))
        assert_eq(#res.lines, 2)
        assert_eq(res.lines[2].amount, 200)
        assert_eq(res.discount, 450)
        assert_true(rpc('billLines', DOC, { billId = b3 }).ok, 'paleto is a known facility too')
        assert_eq(rpc('billLines', DOC, { billId = 99999999 }).error, 'not_found')
    end)
    it('the workstation reads no pf-ambulancejob table itself', function()
        local src = __readfile('[pfscripts]/pf-emsmdt/server/hospital_app.lua')
        assert_true(src:find('pf_hosp_', 1, true) == nil, 'no pf_hosp_ table named')
        assert_true(src:find('pf_med_', 1, true) == nil, 'no pf_med_ table named')
    end)
    it('init carries the viewer\'s tier; the board names the free beds per department', function()
        local init = rpc('init', DOC)
        assert_true(init.ok, tostring(init.error))
        assert_eq(init.me.tier, 5)
        assert_eq(rpc('init', EMT).me.tier, 1)
        local board = rpc('board', DOC, { facility = 'pillbox' })
        assert_true(board.ok, tostring(board.error))
        local ed
        for _, b in ipairs(board.beds) do if b.dept == 'ed' then ed = b end end
        assert_eq(#ed.freeIds, ed.free)
        local taken = ed.freeIds[1]
        assert_true(H.Beds.Claim('pillbox', taken, 'B22ANN', 4343))
        board = rpc('board', DOC, { facility = 'pillbox' })
        for _, b in ipairs(board.beds) do if b.dept == 'ed' then ed = b end end
        for _, id in ipairs(ed.freeIds) do assert_true(id ~= taken, 'a held bed is not free') end
        H.Beds.Release('pillbox', taken, 4343)
    end)
end)
