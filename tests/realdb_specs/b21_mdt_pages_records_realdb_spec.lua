-- Batch 21 (21A) on MariaDB: pf-policemdt-DEV server/pages_records.lua against the real tables.
--   * pf_mdt:cases:deathRecord: the case-link lookup (pf_mdt_case_links from the MDT schema), a link
--     of another case or type refused, the audit row written to pf_mdt_record_audit on every read;
--   * pf_mdt:citations:list: the pf_justice_citations IN-list read by order id, the players IN-list
--     read for officer names, the pf_police_citations read of field citations pf-justice has not
--     taken, paging by order id. Each table comes from its owner's own migration DDL (pf-justice v1,
--     pfm-policejob), and players from qbcore.sql, so the collations are the real ones; the module
--     reads them with separate lookups, never a join across them.
-- pf-justice GetOrders and pf-ambulancejob GetDeathRecord are export stubs by contract.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
local states = { ['pf-justice'] = 'started', ['pf-ambulancejob'] = 'started' }
function GetResourceState(name) return states[name] or 'missing' end
QBCore = QBCoreMock

RealDB.exec('pfm-core/qbcore.sql')
function GetCurrentResourceName() return 'pfm-core' end
load_resource('pfm-core/server/migrations.lua')
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end

local function addPlayerRow(cid, first, last, job)
    MySQL.query.await([[INSERT INTO players (citizenid, cid, license, name, money, charinfo, job, gang, position, metadata, inventory)
        VALUES (?, 1, ?, ?, '{}', ?, ?, '{}', '{}', '{}', '[]')]],
        { cid, 'license:' .. cid, first, json.encode({ firstname = first, lastname = last }), json.encode({ name = job, grade = { level = 0 } }) })
end
addPlayerRow('OFF1', 'Ada', 'Lead', 'police')
addPlayerRow('OFF2', 'Ben', 'Patrol', 'police')
addPlayerRow('CIT1', 'Carl', 'Driver', 'unemployed')

-- the owners' own DDL for the two tables this module reads (no other part of those resources runs)
local function ownerDDL(lists, tableName)
    for _, list in ipairs(lists) do
        for _, step in ipairs(type(list) == 'table' and list or {}) do
            local steps = type(step) == 'table' and step.up or { step }
            for _, sql in ipairs(type(steps) == 'table' and steps or {}) do
                if type(sql) == 'string' and sql:find('CREATE TABLE IF NOT EXISTS `' .. tableName .. '`', 1, true) then return sql end
            end
        end
    end
    error('no DDL for ' .. tableName)
end
load_resource('[pfscripts]/pf-justice/server/schema.lua')
MySQL.query.await(ownerDDL({ PFJustice.Schema.V1 }, 'pf_justice_citations'))
load_resource('pfm-policejob/server/schema.lua')
MySQL.query.await(ownerDDL({ PFPoliceSchema.Migrations }, 'pf_police_citations'))

function GetCurrentResourceName() return 'pf-policemdt-DEV' end
Config = nil
local RES = '[pfscripts]/pf-policemdt-DEV/'
load_resource(RES .. 'shared/framework.lua')
load_resource(RES .. 'config.lua')
load_resource(RES .. 'server/access.lua')
load_resource(RES .. 'server/schema.lua')
assert(PFMdtSchema.Run(), 'MDT schema: ' .. tostring(PFMdtSchema.lastError))
local audits = {}
PFMdtRecords = { Audit = function(by, entity, id, action) audits[#audits + 1] = { entity = entity, id = id, action = action } return true end }
load_resource(RES .. 'server/pages_records.lua')

local function n(sql, p) return tonumber(MySQL.scalar.await(sql, p or {})) or 0 end
local OFFICER, OFFDUTY = 1, 2
local function players()
    Mock.players = {}
    local o = Mock.newPlayer(OFFICER, 'OFF1')
    o.PlayerData.job = { name = 'police', grade = { level = 1 }, onduty = true }
    local f = Mock.newPlayer(OFFDUTY, 'OFF2')
    f.PlayerData.job = { name = 'police', grade = { level = 1 }, onduty = false }
end
local function call(name, src, data)
    Mock.gameTimer = Mock.gameTimer + 5000
    return Mock.callCallback(name, src, data)
end

-- a case with a death record link and an incident link, and a second case with its own death link
local now = os.time()
MySQL.query.await("INSERT INTO pf_mdt_cases (id, case_no, title, status, priority, created_by, created_at, updated_at) VALUES (7, 'C-000007', 'Body at the pier', 'active', 2, 'OFF1', ?, ?), (8, 'C-000008', 'Other', 'active', 2, 'OFF1', ?, ?)", { now, now, now, now })
local deathLink = MySQL.insert.await("INSERT INTO pf_mdt_case_links (case_id, ref_type, ref_id, note, by_cid, at) VALUES (7, 'death_record', '12', 'from the morgue', 'system:pf-ambulancejob', ?)", { now })
local incidentLink = MySQL.insert.await("INSERT INTO pf_mdt_case_links (case_id, ref_type, ref_id, note, by_cid, at) VALUES (7, 'incident', 'INC1', NULL, 'OFF1', ?)", { now })
local otherLink = MySQL.insert.await("INSERT INTO pf_mdt_case_links (case_id, ref_type, ref_id, note, by_cid, at) VALUES (8, 'death_record', '13', NULL, 'OFF1', ?)", { now })

local morgueCalls = {}
Mock.exportsByResource['pf-ambulancejob'] = {
    GetDeathRecord = function(_, id)
        morgueCalls[#morgueCalls + 1] = id
        return { ok = true, record = { id = id, cid = 'CIT1', state = 'examined', cause = 'Drowning', manner = 'accident', createdAt = now,
            findings = { intake = { raw = true }, autopsy = { note = 'Water in the lungs', injuries = {}, toxins = {} } } } }
    end,
}

describe('pages_records on MariaDB: death record of a case', function()
    it('reads the link of the case, refuses other cases and types, audits every read in pf_mdt_record_audit', function()
        players()
        local r = call('pf_mdt:cases:deathRecord', OFFICER, { caseId = 7, linkId = deathLink })
        assert_true(r.ok, tostring(r.error))
        assert_eq(morgueCalls[1], 12)
        assert_eq(r.record.cause, 'Drowning')
        assert_eq(r.record.findings, nil)
        assert_eq(r.record.autopsy.note, 'Water in the lungs')
        local row = MySQL.single.await("SELECT entity, entity_id, action, by_cid, by_job, detail FROM pf_mdt_record_audit WHERE entity = 'case' ORDER BY id DESC LIMIT 1")
        assert_eq(row.entity, 'case'); assert_eq(row.entity_id, '7'); assert_eq(row.action, 'read'); assert_eq(row.by_cid, 'OFF1'); assert_eq(row.by_job, 'police')
        local d = json.decode(row.detail)
        assert_eq(d.op, 'death_record'); assert_eq(d.recordId, 12); assert_eq(tonumber(d.linkId), tonumber(deathLink))
        call('pf_mdt:cases:deathRecord', OFFICER, { caseId = 7, linkId = deathLink })
        assert_eq(n("SELECT COUNT(*) FROM pf_mdt_record_audit WHERE entity = 'case' AND entity_id = '7' AND action = 'read'"), 2, 'every read audited')

        assert_eq(call('pf_mdt:cases:deathRecord', OFFICER, { caseId = 7, linkId = otherLink }).error, 'not_found', 'link of another case')
        assert_eq(call('pf_mdt:cases:deathRecord', OFFICER, { caseId = 7, linkId = incidentLink }).error, 'bad_args', 'not a death record')
        assert_eq(call('pf_mdt:cases:deathRecord', OFFICER, { caseId = 7, linkId = 999999 }).error, 'not_found')
        assert_eq(call('pf_mdt:cases:deathRecord', OFFDUTY, { caseId = 7, linkId = deathLink }).error, 'not_on_duty')
        assert_eq(#morgueCalls, 2, 'refused reads never reach the morgue')
        assert_eq(n("SELECT COUNT(*) FROM pf_mdt_record_audit WHERE entity = 'case'"), 2)
    end)
end)

describe('pages_records on MariaDB: citations of a citizen', function()
    it('joins pf-justice orders with pf_justice_citations rows and officer names, pages by order id', function()
        players()
        -- 25 citation orders by contract; their citation rows in pf-justice's real table
        local orders = {}
        for id = 25, 1, -1 do orders[#orders + 1] = { id = id, cid = 'CIT1', kind = 'citation', state = id % 2 == 0 and 'paid' or 'active', amount = 100 + id, createdAt = now } end
        orders[#orders + 1] = { id = 90, cid = 'CIT1', kind = 'fine', state = 'active', amount = 1 }
        local asked
        Mock.exportsByResource['pf-justice'] = { GetOrders = function(_, cid, filter) asked = { cid = cid, filter = filter } return { ok = true, list = orders } end }
        for id = 1, 25 do
            MySQL.insert.await([[INSERT INTO pf_justice_citations (order_id, uid, violation, plate, speed_kmh, limit_kmh, x, y, officer_cid, contest_until, at)
                VALUES (?, ?, ?, 'AB12', 90, 50, NULL, NULL, ?, ?, ?)]], { id, 'JU' .. id, 'Speeding ' .. id, id % 2 == 0 and 'OFF1' or 'OFF2', now + 86400, now + id })
        end
        MySQL.insert.await([[INSERT INTO pf_police_citations (uid, citizenid, officer_cid, code, violation, amount, plate, state, error, created_at, updated_at)
            VALUES ('F1', 'CIT1', 'OFF2', 'T1', 'Red light', 50, NULL, 'pending', NULL, ?, ?), ('F2', 'CIT1', 'OFF1', 'T2', 'No lights', 40, NULL, 'issued', NULL, ?, ?),
            ('F3', 'CIT9', 'OFF1', 'T3', 'Other citizen', 30, NULL, 'failed', 'court_refused', ?, ?)]], { now, now, now, now, now, now })

        local r = call('pf_mdt:citations:list', OFFICER, { citizenId = 'CIT1' })
        assert_true(r.ok, tostring(r.error) .. ' ' .. tostring(r.message))
        assert_eq(asked.cid, 'CIT1'); assert_eq(asked.filter.kinds[1], 'citation')
        assert_eq(#r.list, 20)
        assert_eq(r.list[1].orderId, 25); assert_eq(r.list[1].reason, 'Speeding 25'); assert_eq(r.list[1].uid, 'JU25')
        assert_eq(r.list[1].officerName, 'Ben Patrol', 'odd ids: OFF2 from the players table')
        assert_eq(r.list[2].officerName, 'Ada Lead')
        assert_eq(r.list[1].speed, 90); assert_eq(r.list[1].contestUntil, now + 86400); assert_eq(r.list[1].issuedAt, now + 25)
        assert_eq(r.next, 6)
        assert_eq(#r.pending, 1, 'only this citizen\'s pending/failed field citations')
        assert_eq(r.pending[1].uid, 'F1'); assert_eq(r.pending[1].officerName, 'Ben Patrol')
        assert_eq(audits[#audits].entity, 'citizen')

        local r2 = call('pf_mdt:citations:list', OFFICER, { citizenId = 'CIT1', after = r.next })
        assert_eq(#r2.list, 5)
        assert_eq(r2.list[1].orderId, 5); assert_eq(r2.list[5].orderId, 1)
        assert_eq(r2.list[5].reason, 'Speeding 1')
        assert_eq(r2.next, nil)
        assert_eq(#r2.pending, 0)
    end)

    it('a citizen without citations gets empty lists; an order without a citation row still shows', function()
        players()
        Mock.exportsByResource['pf-justice'] = { GetOrders = function() return { ok = true, list = { { id = 500, kind = 'citation', state = 'active', amount = 75, createdAt = now } } } end }
        local r = call('pf_mdt:citations:list', OFFICER, { citizenId = 'OFF2' })
        assert_true(r.ok)
        assert_eq(#r.list, 1); assert_eq(r.list[1].amount, 75); assert_eq(r.list[1].reason, nil); assert_eq(r.list[1].issuedAt, now)
        assert_eq(#r.pending, 0)
        Mock.exportsByResource['pf-justice'] = { GetOrders = function() return { ok = true, list = {} } end }
        r = call('pf_mdt:citations:list', OFFICER, { citizenId = 'OFF2' })
        assert_eq(#r.list, 0); assert_eq(r.next, nil)
    end)
end)
