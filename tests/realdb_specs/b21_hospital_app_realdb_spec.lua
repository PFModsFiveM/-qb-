-- pf-emsmdt batch 21D on a real database: the hospital workstation's read-only SQL on
-- pf-ambulancejob's tables, created by pf-ambulancejob's own migrations (pf_hosp_bills,
-- pf_hosp_bill_lines, pf_hosp_prescriptions) and pfm-core's players table: the counter queue (active,
-- unexpired, this facility only, newest first, paged, search by citizen id or name words with LIKE
-- wildcards taken literally), bills (facility, state, search, paging) and bill lines, and the
-- offline-name lookup. pf-ambulancejob's exports are mocked by contract for the facility list.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
local resState = { ['pf-ambulancejob'] = 'started', ['pf-devices'] = 'started' }
function GetResourceState(r) return resState[r] or 'missing' end
CreateThread = function() end
SetTimeout = function() end
Wait = function() end
QBCore = QBCoreMock

RealDB.exec('pfm-core/qbcore.sql')
load_resource('pfm-core/server/migrations.lua')
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end

-- pf-ambulancejob's tables through its own migrations
function GetCurrentResourceName() return 'pf-ambulancejob' end
Config = nil
load_resource('[pfscripts]/pf-ambulancejob/config.lua')
load_resource('[pfscripts]/pf-ambulancejob/server/medical/schema.lua')
assert(PFMed.Schema.Start(), 'pf-ambulancejob tables')

Mock.exportsByResource['pf-ambulancejob'] = {
    GetHospitalStatus = function(_, id)
        local key = ({ 'pillbox', 'paleto' })[id] or id
        if key ~= 'pillbox' and key ~= 'paleto' then return { ok = false, error = 'not_found' } end
        return { ok = true, hospitalId = key, label = key, beds = {}, staffOnDuty = 1, aiActive = false }
    end,
    IsInCustodyCare = function() return false end,
}

function GetCurrentResourceName() return 'pf-emsmdt' end
Config = nil
load_resource('[pfscripts]/pf-emsmdt/config.lua')
load_resource('[pfscripts]/pf-emsmdt/server/hospital_app.lua')
local HA = PFHospitalApp

Mock.players = {}
local CHIEF = 7
Mock.newPlayer(CHIEF, 'CHIEF1').PlayerData.job = { name = 'ambulance', onduty = true, grade = { level = 4 } }
local function rpc(method, payload) return HA.Handlers[method](CHIEF, payload or {}) end

local T = os.time()
local function player(cid, first, last)
    MySQL.query.await('INSERT INTO players (citizenid, license, name, money, charinfo, job, gang, position, metadata, inventory) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        { cid, 'license:' .. cid, first, '{}', json.encode({ firstname = first, lastname = last }), '{}', '{}', '{}', '{}', '[]' })
end
player('ANN001', 'Ann', 'Lee')
player('BOB002', 'Bob', 'Stone')
player('PCT003', '50%_off', 'Sale')

local function rx(cid, drug, state, hospital, expires, created)
    return MySQL.insert.await([[INSERT INTO pf_hosp_prescriptions (citizenid, drug, dose, qty, refills, controlled, prescriber_cid, state, created_at,
        expires_at, dispensed, interval_seconds, hospital_id, admission_id, units_per_fill) VALUES (?, ?, 'd', 3, 2, 0, 'DOC1', ?, ?, ?, 1, 86400, ?, 5, 4)]],
        { cid, drug, state, created or T, expires, hospital })
end
rx('ANN001', 'painkillers', 'active', 'pillbox', T + 86400)
rx('BOB002', 'antibiotics', 'active', 'pillbox', T + 86400)
rx('ANN001', 'bandage', 'active', 'paleto', T + 86400)       -- other facility
rx('BOB002', 'crutches', 'filled', 'pillbox', T + 86400)     -- collected
rx('ANN001', 'antibiotics', 'active', 'pillbox', T - 10)     -- expired
rx('PCT003', 'bandage', 'active', 'pillbox', T + 86400)
-- an infirmary dose schedule (19G: no hospital_id) never shows at a counter
MySQL.insert.await([[INSERT INTO pf_hosp_prescriptions (citizenid, drug, dose, qty, prescriber_cid, state, created_at, expires_at, custody_ref)
    VALUES ('BOB002', 'painkillers', 'd', 4, 'DOC1', 'active', ?, ?, 'order:1')]], { T, T + 86400 })

local function bill(cid, hospital, state, total, discount)
    local id = MySQL.insert.await([[INSERT INTO pf_hosp_bills (citizenid, admission_id, hospital_id, total, discount, state, created_at)
        VALUES (?, 5, ?, ?, ?, ?, ?)]], { cid, hospital, total, discount, state, T })
    MySQL.insert.await('INSERT INTO pf_hosp_bill_lines (bill_id, kind, label, qty, unit_price) VALUES (?, ?, ?, ?, ?), (?, ?, ?, ?, ?)',
        { id, 'admission', 'Check-in', 1, 250, id, 'bed', 'Ward', 2, 100 })
    return tonumber(id)
end
local b1 = bill('ANN001', 'pillbox', 'paid', 450, 0)
local b2 = bill('BOB002', 'pillbox', 'invoiced', 900, 450)
local b3 = bill('ANN001', 'paleto', 'open', 300, 0)
for i = 1, 26 do bill('BOB002', 'pillbox', 'open', 100 + i, 0) end

describe('b21 hospital app on MariaDB: counter queue', function()
    it('only active, unexpired prescriptions of this facility, newest first', function()
        local res = rpc('pharmacy', { facility = 'pillbox' })
        assert_true(res.ok, tostring(res.error))
        assert_eq(#res.list, 3)
        assert_eq(res.list[1].citizenid, 'PCT003')
        assert_eq(res.list[2].name, 'Bob Stone')
        assert_eq(res.list[3].label, 'Painkillers')
        assert_eq(res.list[3].units, 4)
        assert_eq(res.list[3].filled, 1)
        assert_eq(res.list[3].nextAt, nil)
        assert_eq(res.more, false)
    end)
    it('search by citizen id or name words; wildcards are literal', function()
        assert_eq(#rpc('pharmacy', { facility = 'pillbox', q = 'ANN001' }).list, 1)
        assert_eq(rpc('pharmacy', { facility = 'pillbox', q = 'bob stone' }).list[1].citizenid, 'BOB002')
        assert_eq(#rpc('pharmacy', { facility = 'pillbox', q = 'Ann Stone' }).list, 0)
        local pct = rpc('pharmacy', { facility = 'pillbox', q = '50%_' })
        assert_eq(#pct.list, 1)
        assert_eq(pct.list[1].citizenid, 'PCT003')
        assert_eq(#rpc('pharmacy', { facility = 'pillbox', q = '%' }).list, 1, 'a bare % matches only a literal %')
    end)
end)

describe('b21 hospital app on MariaDB: bills', function()
    it('newest first, 25 a page, and a second page', function()
        local p1 = rpc('bills', { facility = 'pillbox' })
        assert_true(p1.ok, tostring(p1.error))
        assert_eq(#p1.list, 25)
        assert_eq(p1.more, true)
        local p2 = rpc('bills', { facility = 'pillbox', page = 2 })
        assert_eq(#p2.list, 3)
        assert_eq(p2.more, false)
        assert_eq(p2.list[3].id, b1)
    end)
    it('by state and name; the due amount after coverage', function()
        local res = rpc('bills', { facility = 'pillbox', state = 'invoiced', q = 'bob' })
        assert_eq(#res.list, 1)
        assert_eq(res.list[1].id, b2)
        assert_eq(res.list[1].due, 450)
        assert_eq(res.list[1].name, 'Bob Stone')
        assert_eq(#rpc('bills', { facility = 'pillbox', state = 'paid', q = 'BOB002' }).list, 0)
        assert_eq(#rpc('bills', { facility = 'paleto' }).list, 1)
    end)
    it('lines of one bill', function()
        local res = rpc('billLines', { billId = b2 })
        assert_true(res.ok, tostring(res.error))
        assert_eq(#res.lines, 2)
        assert_eq(res.lines[2].amount, 200)
        assert_eq(res.discount, 450)
        assert_true(rpc('billLines', { billId = b3 }).ok, 'paleto is a known facility too')
        assert_eq(rpc('billLines', { billId = 999999 }).error, 'not_found')
    end)
end)

describe('b21 hospital app on MariaDB: names', function()
    it('offline patients get their names from players.charinfo in one query', function()
        local names = HA.Names({ 'ANN001', 'BOB002', 'NOPE99' })
        assert_eq(names.ANN001.name, 'Ann Lee')
        assert_eq(names.BOB002.online, false)
        assert_true(names.NOPE99 == nil)
    end)
end)
