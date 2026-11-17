-- pf-emsmdt batch 21D on a real database: the hospital workstation's read-only SQL on
-- pf-ambulancejob's tables, created by pf-ambulancejob's own migrations (pf_hosp_bills,
-- pf_hosp_bill_lines) and pfm-core's players table: the name search (JSON_VALUE of first and last
-- name, minimum term length, LIKE wildcards literal) and the offline-name lookup. pf-ambulancejob's exports are mocked by contract for the
-- facility list; the counter queue (pf-ambulancejob's ListPharmacyQueue) is in the e2e spec.
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

describe('b21 hospital app on MariaDB: name search (B21-5)', function()
    it('matches first and last name values, never the JSON keys', function()
        local function cids(q) local t = HA.SQL.CidsByName(q) table.sort(t) return table.concat(t, ',') end
        assert_eq(cids('ann'), 'ANN001')
        assert_eq(cids('Stone'), 'BOB002')
        assert_eq(cids('bob stone'), 'BOB002')
        assert_eq(cids('Ann Stone'), '')
        assert_eq(cids('name'), '', 'the key "firstname" is not a name')
        assert_eq(cids('first'), '')
        assert_eq(cids('a'), '', 'below the minimum term length')
        assert_eq(cids('50%_'), 'PCT003', 'wildcards literal')
        assert_eq(cids('%%'), '')
    end)
end)

-- (bills and bill lines: batch 22 moved those reads into pf-ambulancejob's ListBills / GetBillLines;
-- tests/realdb_specs/b22_hospital_reads_realdb_spec.lua runs them and the workstation over them)

describe('b21 hospital app on MariaDB: names', function()
    it('offline patients get their names from players.charinfo in one query', function()
        local names = HA.Names({ 'ANN001', 'BOB002', 'NOPE99' })
        assert_eq(names.ANN001.name, 'Ann Lee')
        assert_eq(names.BOB002.online, false)
        assert_true(names.NOPE99 == nil)
    end)
end)
