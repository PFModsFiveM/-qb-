-- Batch 18 (18E) on MariaDB: pf-policemdt-DEV cases and investigations (server/cases.lua) and the
-- schema's v8 (server/schema.lua):
--   * v8 applies once on a v7 install (existing warrants read approval_state 'legacy'), every step
--     can run again, and the case/BOLO/audit tables and warrant columns exist;
--   * cases: create (server case number, lead = creator, audit row, caseChanged), status machine with
--     lead/supervisor rules, links checked against their owners (MDT tables, pf-justice and
--     pfm-policejob by contract stubs), people named from the players table, append-only entries,
--     assignments to officers only, read-only once submitted/closed;
--   * court submission: stored 'pending' with key pf-policemdt:case:<id>:court:<subId> while
--     pf-justice has no FileCase (case ready_for_court), handed over once by the sweep when it does
--     (case submitted), a clear refusal is 'refused' and can be withdrawn;
--   * AttachExternalRecord for allowlisted resources (case and incident targets), deleted characters.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
local states = { ['pf-justice'] = 'started', ['pfm-policejob'] = 'started' }
function GetResourceState(name) return states[name] or 'missing' end

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
addPlayerRow('SUP3', 'Cara', 'Sergeant', 'police')
addPlayerRow('SUS9', 'Sam', 'Suspect', 'unemployed')
addPlayerRow('WIT8', 'Will', 'Witness', 'unemployed')
addPlayerRow('DOJ7', 'Dana', 'Prosecutor', 'doj')

-- pf-justice by contract (orders, custody; FileCase only once 19A exists)
local JU = { filed = {}, fileMode = nil, n = 100 }
local juMock = {
    GetOrder = function(_, id)
        if id == 41 then return { ok = true, order = { id = 41, kind = 'fine' } } end
        if id == 42 then return { ok = true, order = { id = 42, kind = 'citation' } } end
        return { ok = false, error = 'not_found' }
    end,
    GetCustody = function(_, cid)
        if cid == 'SUS9' then return { ok = true, custody = { id = 77, cid = 'SUS9', state = 'booked' } } end
        return { ok = true }
    end,
}
local function fileCase(_, spec, opts)
    JU.filed[#JU.filed + 1] = { spec = spec, opts = opts }
    if JU.fileMode == 'refuse' then return { ok = false, error = 'bad_args', message = 'Charges missing a class' } end
    if JU.fileMode == 'throw' then error('court database down') end
    for _, f in ipairs(JU.filed) do
        if f.caseId and f.opts.key == opts.key then return { ok = true, duplicate = true, caseId = f.caseId } end
    end
    JU.n = JU.n + 1
    JU.filed[#JU.filed].caseId = JU.n
    return { ok = true, caseId = JU.n }
end
Mock.exportsByResource['pf-justice'] = juMock

-- pfm-policejob evidence by contract
local PJ = { links = {}, unlinks = {} }
Mock.exportsByResource['pfm-policejob'] = {
    LinkEvidence = function(_, id, caseRef, opts)
        if tonumber(id) ~= 501 then return { ok = false, error = 'not_found', message = 'No such evidence' } end
        PJ.links[#PJ.links + 1] = { id = id, caseRef = caseRef, actor = opts and opts.actor }
        return { ok = true, evidenceId = 501 }
    end,
    UnlinkEvidence = function(_, id, caseRef, opts)
        PJ.unlinks[#PJ.unlinks + 1] = { id = id, caseRef = caseRef }
        return { ok = true, evidenceId = tonumber(id) }
    end,
    ListEvidence = function(_, filter)
        PJ.lastFilter = filter
        return { ok = true, list = { { id = 501, tag = 'EV-26-501', kind = 'casing', state = 'stored', integrity = 100 } } }
    end,
}

function GetCurrentResourceName() return 'pf-policemdt-DEV' end
Config = nil
local RES = '[pfscripts]/pf-policemdt-DEV/'
load_resource(RES .. 'shared/framework.lua')
load_resource(RES .. 'config.lua')
load_resource(RES .. 'server/access.lua')
load_resource(RES .. 'server/schema.lua')
local Schema = PFMdtSchema
local KEY = 'pf-policemdt-DEV'

local function n(sql, p) return tonumber(MySQL.scalar.await(sql, p or {})) or 0 end
local function one(sql, p) return MySQL.single.await(sql, p or {}) end
local function hasColumn(t, c)
    return n('SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = ?', { t, c }) == 1
end
local function hasTable(t)
    return n('SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?', { t }) == 1
end

describe('MDT schema v8 (MariaDB)', function()
    it('a v7 install applies only v8; old warrants read legacy; the new tables and columns exist', function()
        local v17 = {}
        for i = 1, 7 do v17[i] = Schema.Migrations[i] end
        assert_eq(RunMigrations(KEY, v17), true)
        MySQL.query.await("INSERT INTO pf_mdt_warrants (warrantId, suspectCitizenId, suspectName, issuedBy, status) VALUES ('W-1', 'SUS9', 'Sam Suspect', 'Ada Lead', 'active')")
        local before = n('SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = ?', { KEY })
        assert_eq(before, 7)
        assert_true(Schema.Run(), tostring(Schema.lastError))
        local rows = MySQL.query.await('SELECT version, name FROM pf_schema_migrations WHERE resource = ? ORDER BY version', { KEY })
        assert_eq(#rows, 9) -- v9 (20F personnel) applies in the same run
        assert_eq(tonumber(rows[8].version), 8)
        assert_eq(rows[8].name, 'cases, BOLOs, record audit, warrant columns')
        for _, t in ipairs({ 'pf_mdt_cases', 'pf_mdt_case_links', 'pf_mdt_case_people', 'pf_mdt_case_entries', 'pf_mdt_case_submissions',
            'pf_mdt_incident_links', 'pf_mdt_bolos', 'pf_mdt_record_audit' }) do
            assert_true(hasTable(t), t)
        end
        for _, c in ipairs({ 'warrant_type', 'approval_state', 'approved_by', 'review_id', 'served_custody_id', 'address' }) do
            assert_true(hasColumn('pf_mdt_warrants', c), c)
        end
        assert_true(hasColumn('pf_mdt_incidents', 'deleted_at'))
        assert_true(hasColumn('pf_mdt_sentences', 'justice_order_ids'))
        assert_true(hasColumn('pf_mdt_sentences', 'deleted_at'))
        assert_eq(n("SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'pf_mdt_warrants' AND INDEX_NAME = 'idx_warrant_suspect_cid'"), 1)
        local w = one("SELECT approval_state, warrant_type FROM pf_mdt_warrants WHERE warrantId = 'W-1'")
        assert_eq(w.approval_state, 'legacy')
        assert_eq(w.warrant_type, 'arrest')
        -- a role name as long as person_of_interest fits
        MySQL.query.await("INSERT INTO pf_mdt_case_people (case_id, role, name) VALUES (999, 'person_of_interest', 'x')")
        assert_eq(n("SELECT COUNT(*) FROM pf_mdt_case_people WHERE role = 'person_of_interest'"), 1)
        MySQL.query.await('DELETE FROM pf_mdt_case_people WHERE case_id = 999')
    end)

    it('a second run applies nothing and every v8 step can run again', function()
        assert_eq(RunMigrations(KEY, Schema.Migrations), true)
        assert_eq(n('SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = ?', { KEY }), 9) -- v9 (20F) included
        for _, sql in ipairs(Schema.Migrations[8].up) do MySQL.query.await(sql) end
        assert_eq(one("SELECT approval_state FROM pf_mdt_warrants WHERE warrantId = 'W-1'").approval_state, 'legacy')
    end)
end)

-- the cases module on the migrated tables
load_resource(RES .. 'server/cases.lua')
local Cases = PFMdtCases
QBCoreMock.Shared.Jobs.police = { label = 'Police', grades = { ['0'] = {}, ['4'] = { isboss = true } } }

MySQL.query.await("INSERT INTO pf_mdt_incidents (incidentId, title) VALUES ('INC-1', 'Store robbery')")
MySQL.query.await("INSERT INTO pf_mdt_reports (reportId, type, title) VALUES ('RPT-1', 'Arrest Report', 'Robbery arrest')")
MySQL.query.await("INSERT INTO pf_mdt_bolos (kind, plate, description, status, by_cid, created_at, expires_at) VALUES ('vehicle', 'ABC123', 'Red sedan', 'active', 'OFF1', 1, 9999999999)")
MySQL.query.await("INSERT INTO pf_mdt_manual_citizens (citizenId, firstname, lastname) VALUES ('M-1', 'Mona', 'Manual')")
MySQL.query.await("INSERT IGNORE INTO pf_mdt_charges (code, name) VALUES ('PC-211', 'Robbery'), ('PC-245', 'Assault with Deadly Weapon')")
local BOLO_ID = n("SELECT id FROM pf_mdt_bolos WHERE plate = 'ABC123'")
local MANUAL_ID = n("SELECT id FROM pf_mdt_manual_citizens WHERE citizenId = 'M-1'")

local LEAD, PATROL, SUP, CIV = 1, 2, 3, 4
local NAMES = { OFF1 = { 'Ada', 'Lead' }, OFF2 = { 'Ben', 'Patrol' }, SUP3 = { 'Cara', 'Sergeant' } }
local function officer(src, cid, grade, onduty)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.charinfo = { firstname = NAMES[cid][1], lastname = NAMES[cid][2] }
    p.PlayerData.job = { name = 'police', type = 'leo', label = 'Police', grade = { level = grade }, onduty = onduty ~= false }
    return p
end
BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    Mock.invokingResource = nil
    officer(LEAD, 'OFF1', 2)
    officer(PATROL, 'OFF2', 1)
    officer(SUP, 'SUP3', 3)
    Mock.newPlayer(CIV, 'WIT8')
end
local function call(name, src, data)
    Mock.gameTimer = Mock.gameTimer + 5000 -- past the 1 s write limit
    return Mock.callCallback(name, src, data)
end
local function events(name)
    local out = {}
    for _, e in ipairs(Mock.serverEvents) do if e.name == name then out[#out + 1] = e end end
    return out
end

local CASE
describe('cases: create, gate and status (MariaDB)', function()
    it('an on-duty officer creates a case: server number, creator leads, audit row, caseChanged', function()
        local res = call('pf_mdt:cases:create', LEAD, { title = '  Fleeca robbery\n', summary = 'Two suspects', priority = 3 })
        assert_eq(res.ok, true, tostring(res.message))
        assert_eq(res.success, true)
        CASE = res.caseId
        local row = one('SELECT * FROM pf_mdt_cases WHERE id = ?', { CASE })
        assert_eq(row.case_no, ('C-%06d'):format(CASE))
        assert_eq(res.caseNo, row.case_no)
        assert_eq(row.title, 'Fleeca robbery')
        assert_eq(row.status, 'open')
        assert_eq(tonumber(row.priority), 3)
        assert_eq(row.lead_cid, 'OFF1')
        assert_eq(row.created_by, 'OFF1')
        assert_eq(n("SELECT COUNT(*) FROM pf_mdt_record_audit WHERE entity = 'case' AND entity_id = ? AND action = 'create' AND by_cid = 'OFF1'", { tostring(CASE) }), 1)
        local ev = events('pf_mdt:server:caseChanged')
        assert_eq(#ev, 1)
        assert_eq(ev[1].args[1].caseNo, row.case_no)
    end)

    it('civilians, off-duty officers and bad input are refused; nothing is written', function()
        local before = n('SELECT COUNT(*) FROM pf_mdt_cases')
        local r1 = call('pf_mdt:cases:create', CIV, { title = 'x' })
        assert_eq(r1.success, false)
        assert_eq(r1.error, 'no_access')
        Mock.players[PATROL].PlayerData.job.onduty = false
        local r2 = call('pf_mdt:cases:create', PATROL, { title = 'x' })
        assert_eq(r2.error, 'off_duty')
        local r3 = call('pf_mdt:cases:create', LEAD, { title = '   ' })
        assert_eq(r3.error, 'bad_args')
        local r4 = call('pf_mdt:cases:create', LEAD, { title = 'ok', priority = 9 })
        assert_eq(r4.error, 'bad_args')
        assert_eq(n('SELECT COUNT(*) FROM pf_mdt_cases'), before)
        -- civilians cannot read either
        assert_eq(call('pf_mdt:cases:get', CIV, { caseId = CASE }).error, 'no_access')
    end)

    it('two writes inside a second: the second is rate limited', function()
        call('pf_mdt:cases:update', LEAD, { caseId = CASE, priority = 2 })
        local res = Mock.callCallback('pf_mdt:cases:update', LEAD, { caseId = CASE, priority = 4 })
        assert_eq(res.error, 'rate_limited')
        assert_eq(tonumber(one('SELECT priority FROM pf_mdt_cases WHERE id = ?', { CASE }).priority), 2)
    end)

    it('status: only the lead or a supervisor moves it, along the machine; reopening needs a supervisor', function()
        assert_eq(call('pf_mdt:cases:setStatus', PATROL, { caseId = CASE, status = 'active' }).error, 'no_permission')
        assert_eq(call('pf_mdt:cases:setStatus', LEAD, { caseId = CASE, status = 'submitted' }).error, 'invalid_state')
        assert_eq(call('pf_mdt:cases:setStatus', LEAD, { caseId = CASE, status = 'ready_for_court' }).error, 'invalid_state')
        assert_eq(call('pf_mdt:cases:setStatus', LEAD, { caseId = CASE, status = 'nonsense' }).error, 'bad_args')
        local res = call('pf_mdt:cases:setStatus', LEAD, { caseId = CASE, status = 'active' })
        assert_eq(res.ok, true)
        assert_eq(one('SELECT status FROM pf_mdt_cases WHERE id = ?', { CASE }).status, 'active')
        assert_eq(n("SELECT COUNT(*) FROM pf_mdt_record_audit WHERE entity_id = ? AND action = 'status'", { tostring(CASE) }), 1)
        -- a second case: closed by the lead, reopened only by a supervisor
        local other = call('pf_mdt:cases:create', LEAD, { title = 'Old burglary' }).caseId
        assert_eq(call('pf_mdt:cases:setStatus', LEAD, { caseId = other, status = 'closed' }).ok, true)
        assert_eq(call('pf_mdt:cases:setStatus', LEAD, { caseId = other, status = 'active' }).error, 'no_permission')
        assert_eq(call('pf_mdt:cases:addEntry', LEAD, { caseId = other, kind = 'note', body = 'late note' }).error, 'invalid_state')
        assert_eq(call('pf_mdt:cases:setStatus', SUP, { caseId = other, status = 'active' }).ok, true)
    end)

    it('lead: a supervisor assigns another officer; a civilian cannot lead; a patrol officer cannot take a led case', function()
        assert_eq(call('pf_mdt:cases:setLead', PATROL, { caseId = CASE, leadCid = 'OFF2' }).error, 'no_permission')
        assert_eq(call('pf_mdt:cases:setLead', SUP, { caseId = CASE, leadCid = 'SUS9' }).error, 'bad_args')
        local res = call('pf_mdt:cases:setLead', SUP, { caseId = CASE, leadCid = 'OFF2' })
        assert_eq(res.ok, true)
        assert_eq(res.leadName, 'Ben Patrol')
        assert_eq(one('SELECT lead_cid FROM pf_mdt_cases WHERE id = ?', { CASE }).lead_cid, 'OFF2')
        -- the new lead hands it back
        assert_eq(call('pf_mdt:cases:setLead', PATROL, { caseId = CASE, leadCid = 'OFF1' }).ok, true)
    end)
end)

describe('cases: links checked against their owners (MariaDB)', function()
    it('MDT records: incident, report, warrant, BOLO; unknown ids not found; a repeat is a duplicate', function()
        local r = call('pf_mdt:cases:link', PATROL, { caseId = CASE, refType = 'incident', refId = 'INC-1', note = 'scene' })
        assert_eq(r.ok, true, tostring(r.message))
        assert_eq(call('pf_mdt:cases:link', PATROL, { caseId = CASE, refType = 'incident', refId = 'INC-1' }).duplicate, true)
        assert_eq(call('pf_mdt:cases:link', PATROL, { caseId = CASE, refType = 'incident', refId = 'INC-404' }).error, 'not_found')
        assert_eq(call('pf_mdt:cases:link', PATROL, { caseId = CASE, refType = 'report', refId = 'RPT-1' }).ok, true)
        assert_eq(call('pf_mdt:cases:link', PATROL, { caseId = CASE, refType = 'warrant', refId = 'W-1' }).ok, true)
        assert_eq(call('pf_mdt:cases:link', PATROL, { caseId = CASE, refType = 'bolo', refId = BOLO_ID }).ok, true)
        assert_eq(call('pf_mdt:cases:link', PATROL, { caseId = CASE, refType = 'warrant', refId = "W-1' OR 1=1" }).error, 'bad_args')
        assert_eq(n('SELECT COUNT(*) FROM pf_mdt_case_links WHERE case_id = ?', { CASE }), 4)
    end)

    it('pf-justice records: orders and citations by GetOrder, custody by the citizen, death records only from the system', function()
        assert_eq(call('pf_mdt:cases:link', PATROL, { caseId = CASE, refType = 'order', refId = 41 }).ok, true)
        assert_eq(call('pf_mdt:cases:link', PATROL, { caseId = CASE, refType = 'citation', refId = 41 }).error, 'bad_args')
        assert_eq(call('pf_mdt:cases:link', PATROL, { caseId = CASE, refType = 'citation', refId = 42 }).ok, true)
        assert_eq(call('pf_mdt:cases:link', PATROL, { caseId = CASE, refType = 'order', refId = 43 }).error, 'not_found')
        local c = call('pf_mdt:cases:link', PATROL, { caseId = CASE, refType = 'custody', citizenid = 'SUS9' })
        assert_eq(c.ok, true)
        assert_eq(c.refId, '77')
        assert_eq(call('pf_mdt:cases:link', PATROL, { caseId = CASE, refType = 'custody', citizenid = 'WIT8' }).error, 'not_found')
        assert_eq(call('pf_mdt:cases:link', PATROL, { caseId = CASE, refType = 'death_record', refId = 5 }).error, 'bad_args')
        states['pf-justice'] = 'stopped'
        assert_eq(call('pf_mdt:cases:link', PATROL, { caseId = CASE, refType = 'order', refId = 42 }).error, 'db_unavailable')
        states['pf-justice'] = 'started'
    end)

    it('evidence goes through PJ LinkEvidence with the case ref and the officer as actor', function()
        local r = call('pf_mdt:cases:link', PATROL, { caseId = CASE, refType = 'evidence', refId = 501 })
        assert_eq(r.ok, true, tostring(r.message))
        assert_eq(#PJ.links, 1)
        assert_eq(PJ.links[1].caseRef.type, 'case')
        assert_eq(PJ.links[1].caseRef.id, tostring(CASE))
        assert_eq(PJ.links[1].actor.src, PATROL)
        assert_eq(call('pf_mdt:cases:link', PATROL, { caseId = CASE, refType = 'evidence', refId = 999 }).error, 'not_found')
        states['pfm-policejob'] = 'stopped'
        local before = n('SELECT COUNT(*) FROM pf_mdt_case_links WHERE case_id = ?', { CASE })
        assert_eq(call('pf_mdt:cases:link', PATROL, { caseId = CASE, refType = 'evidence', refId = 501 }).error, 'db_unavailable')
        assert_eq(n('SELECT COUNT(*) FROM pf_mdt_case_links WHERE case_id = ?', { CASE }), before)
        states['pfm-policejob'] = 'started'
    end)
end)

local SUSPECT, WITNESS, UNKNOWN
describe('cases: people and entries (MariaDB)', function()
    it('people are named from the server, never the client; manual and unidentified people; repeats are duplicates', function()
        local s = call('pf_mdt:cases:addPerson', PATROL, { caseId = CASE, role = 'suspect', citizenid = 'SUS9', name = 'Fake Name' })
        assert_eq(s.ok, true)
        SUSPECT = s.personId
        assert_eq(one('SELECT name FROM pf_mdt_case_people WHERE id = ?', { SUSPECT }).name, 'Sam Suspect')
        assert_eq(call('pf_mdt:cases:addPerson', PATROL, { caseId = CASE, role = 'suspect', citizenid = 'SUS9' }).duplicate, true)
        WITNESS = call('pf_mdt:cases:addPerson', PATROL, { caseId = CASE, role = 'witness', citizenid = 'WIT8' }).personId
        assert_true(WITNESS ~= nil)
        local m = call('pf_mdt:cases:addPerson', PATROL, { caseId = CASE, role = 'victim', manualId = MANUAL_ID })
        assert_eq(m.name, 'Mona Manual')
        UNKNOWN = call('pf_mdt:cases:addPerson', PATROL, { caseId = CASE, role = 'person_of_interest', name = 'Unknown male, red jacket' }).personId
        assert_true(UNKNOWN ~= nil)
        assert_eq(call('pf_mdt:cases:addPerson', PATROL, { caseId = CASE, role = 'suspect', citizenid = 'NOPE1' }).error, 'not_found')
        assert_eq(call('pf_mdt:cases:addPerson', PATROL, { caseId = CASE, role = 'judge', name = 'x' }).error, 'bad_args')
    end)

    it('statements and interviews need a person on the case; leads move by status; entries are append-only', function()
        assert_eq(call('pf_mdt:cases:addEntry', PATROL, { caseId = CASE, kind = 'statement', body = 'I saw it' }).error, 'bad_args')
        assert_eq(call('pf_mdt:cases:addEntry', PATROL, { caseId = CASE, kind = 'statement', personId = 999999, body = 'x' }).error, 'not_found')
        local st = call('pf_mdt:cases:addEntry', PATROL, { caseId = CASE, kind = 'statement', personId = WITNESS, body = 'Two men in masks.\nRed sedan.' })
        assert_eq(st.ok, true)
        local row = one('SELECT * FROM pf_mdt_case_entries WHERE id = ?', { st.entryId })
        assert_eq(row.body, 'Two men in masks.\nRed sedan.')
        assert_eq(row.by_cid, 'OFF2')
        assert_eq(row.by_name, 'Ben Patrol')
        assert_eq(call('pf_mdt:cases:addEntry', PATROL, { caseId = CASE, kind = 'interview', personId = SUSPECT, body = 'Denies involvement' }).ok, true)
        assert_eq(call('pf_mdt:cases:addEntry', PATROL, { caseId = CASE, kind = 'surveillance', body = 'Sedan parked at Grove 22:10' }).ok, true)
        local lead = call('pf_mdt:cases:addEntry', PATROL, { caseId = CASE, kind = 'lead', body = 'Check pawn shops' })
        assert_eq(one('SELECT status FROM pf_mdt_case_entries WHERE id = ?', { lead.entryId }).status, 'open')
        assert_eq(call('pf_mdt:cases:setEntryStatus', PATROL, { entryId = lead.entryId, status = 'followed' }).ok, true)
        assert_eq(call('pf_mdt:cases:setEntryStatus', PATROL, { entryId = lead.entryId, status = 'done' }).error, 'bad_args')
        assert_eq(call('pf_mdt:cases:setEntryStatus', PATROL, { entryId = st.entryId, status = 'open' }).error, 'invalid_state')
        assert_eq(call('pf_mdt:cases:addEntry', PATROL, { caseId = CASE, kind = 'poem', body = 'x' }).error, 'bad_args')
        -- a person with a statement stays on the case
        assert_eq(call('pf_mdt:cases:removePerson', LEAD, { personId = WITNESS }).error, 'conflict')
        assert_eq(call('pf_mdt:cases:removePerson', PATROL, { personId = UNKNOWN }).error, 'no_permission')
        assert_eq(call('pf_mdt:cases:removePerson', LEAD, { personId = UNKNOWN }).ok, true)
    end)

    it('assignments: the lead assigns officers only; others may assign only themselves; the assignee closes it', function()
        assert_eq(call('pf_mdt:cases:addEntry', PATROL, { caseId = CASE, kind = 'assignment', assigneeCid = 'SUP3', body = 'Pull CCTV' }).error, 'no_permission')
        assert_eq(call('pf_mdt:cases:addEntry', LEAD, { caseId = CASE, kind = 'assignment', assigneeCid = 'SUS9', body = 'x' }).error, 'bad_args')
        local a = call('pf_mdt:cases:addEntry', LEAD, { caseId = CASE, kind = 'assignment', assigneeCid = 'OFF2', body = 'Canvass the block' })
        assert_eq(a.ok, true)
        local notes = Mock.clientEventsNamed('QBCore:Notify')
        assert_eq(notes[#notes].target, PATROL)
        assert_eq(call('pf_mdt:cases:addEntry', PATROL, { caseId = CASE, kind = 'assignment', assigneeCid = 'OFF2', body = 'Also pawn shops' }).ok, true)
        -- the assignee sees the case under "mine"
        local mine = call('pf_mdt:cases:list', PATROL, { mine = true })
        assert_eq(mine.ok, true)
        assert_eq(#mine.list, 1)
        assert_eq(mine.list[1].id, CASE)
        assert_eq(call('pf_mdt:cases:setEntryStatus', PATROL, { entryId = a.entryId, status = 'done' }).ok, true)
    end)

    it('get returns the case, links, people, entries, live PJ evidence and what the viewer may do', function()
        local res = call('pf_mdt:cases:get', PATROL, { caseId = CASE })
        assert_eq(res.ok, true)
        assert_eq(res.case.leadName, 'Ada Lead')
        assert_eq(#res.links, 8)
        assert_eq(#res.people, 3)
        assert_true(#res.entries >= 6)
        assert_eq(res.evidence[1].tag, 'EV-26-501')
        assert_eq(PJ.lastFilter.caseRef.id, tostring(CASE))
        assert_eq(PJ.lastFilter.viewer, PATROL)
        assert_eq(res.can.manage, false)
        assert_eq(res.can.submit, false)
        local lead = call('pf_mdt:cases:get', LEAD, { caseId = CASE })
        assert_eq(lead.can.manage, true)
        assert_eq(lead.can.submit, true)
        local list = call('pf_mdt:cases:list', PATROL, { q = 'fleeca' })
        assert_eq(#list.list, 1)
        assert_eq(call('pf_mdt:cases:list', PATROL, { q = '%' }).list[1] == nil, true)
    end)
end)

describe('cases: court submission (MariaDB)', function()
    it('without FileCase the submission is stored pending with its key; the case is ready_for_court', function()
        assert_eq(call('pf_mdt:cases:submit', PATROL, { caseId = CASE, personId = SUSPECT, charges = { 'PC-211' } }).error, 'no_permission')
        assert_eq(call('pf_mdt:cases:submit', LEAD, { caseId = CASE, personId = WITNESS, charges = { 'PC-211' } }).error, 'bad_args')
        assert_eq(call('pf_mdt:cases:submit', LEAD, { caseId = CASE, personId = SUSPECT, charges = { 'PC-999' } }).error, 'bad_args')
        assert_eq(call('pf_mdt:cases:submit', LEAD, { caseId = CASE, personId = SUSPECT, charges = { 'PC-211' }, prosecutorCid = 'OFF2' }).error, 'bad_args')
        local res = call('pf_mdt:cases:submit', LEAD, { caseId = CASE, personId = SUSPECT, charges = { 'PC-211', 'PC-245', 'PC-211' }, prosecutorCid = 'DOJ7' })
        assert_eq(res.ok, true, tostring(res.message))
        assert_eq(res.state, 'pending')
        assert_eq(res.key, ('pf-policemdt:case:%d:court:%d'):format(CASE, res.submissionId))
        local sub = one('SELECT * FROM pf_mdt_case_submissions WHERE id = ?', { res.submissionId })
        assert_eq(sub.state, 'pending')
        assert_eq(sub.idem_key, res.key)
        assert_eq(sub.citizenid, 'SUS9')
        assert_eq(tonumber(sub.attempts), 1)
        local spec = json.decode(sub.spec)
        assert_eq(#spec.charges, 2)
        assert_eq(spec.charges[1].name, 'Robbery')
        assert_eq(spec.custodyId, 77)
        assert_eq(spec.incidentIds[1], 'INC-1')
        assert_eq(spec.evidenceIds[1], 501)
        assert_eq(spec.prosecutorCid, 'DOJ7')
        assert_eq(one('SELECT status FROM pf_mdt_cases WHERE id = ?', { CASE }).status, 'ready_for_court')
        -- the same suspect again: the existing submission
        local again = call('pf_mdt:cases:submit', LEAD, { caseId = CASE, personId = SUSPECT, charges = { 'PC-211' } })
        assert_eq(again.duplicate, true)
        assert_eq(again.submissionId, res.submissionId)
        -- pulling the case back or closing it waits for the pending submission
        assert_eq(call('pf_mdt:cases:setStatus', LEAD, { caseId = CASE, status = 'active' }).error, 'conflict')
        assert_eq(call('pf_mdt:cases:setStatus', LEAD, { caseId = CASE, status = 'closed' }).error, 'conflict')
        -- a call that breaks off keeps it pending, under the same key
        juMock.FileCase = fileCase
        JU.fileMode = 'throw'
        assert_eq(Cases.SweepSubmissions(), 0)
        assert_eq(one('SELECT state FROM pf_mdt_case_submissions WHERE id = ?', { res.submissionId }).state, 'pending')
        assert_eq(JU.filed[1].opts.key, res.key)
    end)

    it('once FileCase exists the sweep files it once: court case id saved, case submitted, no second filing', function()
        JU.fileMode = nil
        local calls = #JU.filed
        assert_eq(Cases.SweepSubmissions(), 1)
        assert_eq(#JU.filed, calls + 1)
        local f = JU.filed[#JU.filed]
        assert_eq(f.spec.cid, 'SUS9')
        assert_eq(f.opts.actor.kind, 'system')
        assert_eq(f.opts.filedBy, 'OFF1')
        local sub = one("SELECT * FROM pf_mdt_case_submissions WHERE case_id = ? AND citizenid = 'SUS9'", { CASE })
        assert_eq(sub.state, 'filed')
        assert_eq(tonumber(sub.court_case_id), f.caseId)
        local c = one('SELECT status, court_case_id FROM pf_mdt_cases WHERE id = ?', { CASE })
        assert_eq(c.status, 'submitted')
        assert_eq(tonumber(c.court_case_id), f.caseId)
        assert_eq(Cases.SweepSubmissions(), 0)
        assert_eq(#JU.filed, calls + 1)
        -- a submitted case is read-only
        assert_eq(call('pf_mdt:cases:addEntry', LEAD, { caseId = CASE, kind = 'note', body = 'x' }).error, 'invalid_state')
        assert_eq(call('pf_mdt:cases:withdrawSubmission', LEAD, { submissionId = sub.id }).error, 'invalid_state')
    end)

    it('with FileCase present a submission files at once; a clear refusal is refused and can be withdrawn', function()
        local id = call('pf_mdt:cases:create', LEAD, { title = 'Assault at the docks' }).caseId
        local p = call('pf_mdt:cases:addPerson', LEAD, { caseId = id, role = 'suspect', citizenid = 'SUS9' }).personId
        local ok = call('pf_mdt:cases:submit', LEAD, { caseId = id, personId = p, charges = { 'PC-245' } })
        assert_eq(ok.state, 'filed')
        assert_true(ok.courtCaseId ~= nil)
        assert_eq(one('SELECT status FROM pf_mdt_cases WHERE id = ?', { id }).status, 'submitted')

        local id2 = call('pf_mdt:cases:create', LEAD, { title = 'Shoplifting' }).caseId
        local p2 = call('pf_mdt:cases:addPerson', LEAD, { caseId = id2, role = 'suspect', citizenid = 'SUS9' }).personId
        JU.fileMode = 'refuse'
        local r = call('pf_mdt:cases:submit', LEAD, { caseId = id2, personId = p2, charges = { 'PC-211' } })
        assert_eq(r.ok, true)
        assert_eq(r.state, 'refused')
        local sub = one('SELECT state, last_error FROM pf_mdt_case_submissions WHERE id = ?', { r.submissionId })
        assert_eq(sub.state, 'refused')
        assert_eq(sub.last_error, 'Charges missing a class')
        assert_eq(one('SELECT status FROM pf_mdt_cases WHERE id = ?', { id2 }).status, 'ready_for_court')
        assert_eq(call('pf_mdt:cases:withdrawSubmission', PATROL, { submissionId = r.submissionId }).error, 'no_permission')
        local w = call('pf_mdt:cases:withdrawSubmission', LEAD, { submissionId = r.submissionId })
        assert_eq(w.ok, true)
        assert_eq(one('SELECT status FROM pf_mdt_cases WHERE id = ?', { id2 }).status, 'active')
        -- a new submission gets a new key
        JU.fileMode = nil
        local again = call('pf_mdt:cases:submit', LEAD, { caseId = id2, personId = p2, charges = { 'PC-211' } })
        assert_eq(again.state, 'filed')
        assert_true(again.key ~= r.key)
        juMock.FileCase = nil
    end)
end)

describe('AttachExternalRecord and deleted characters (MariaDB)', function()
    it('allowlisted resources attach records to a case once; others are refused', function()
        local attach = Mock.selfExport('AttachExternalRecord')
        Mock.invokingResource = 'pf-ambulancejob'
        local r = attach({ caseId = CASE }, { type = 'death_record', id = 12 }, { note = 'Coroner record' })
        assert_eq(r.ok, true, tostring(r.message))
        local row = one("SELECT * FROM pf_mdt_case_links WHERE case_id = ? AND ref_type = 'death_record'", { CASE })
        assert_eq(row.ref_id, '12')
        assert_eq(row.by_cid, 'system:pf-ambulancejob')
        assert_eq(attach({ caseId = CASE }, { type = 'death_record', id = 12 }).duplicate, true)
        assert_eq(attach({ caseId = CASE }, { type = 'incident', id = 'INC-1' }).error, 'bad_args')
        assert_eq(attach({ caseId = 999999 }, { type = 'telemetry', id = 'OFF1:1-2' }).error, 'not_found')
        Mock.invokingResource = 'some-script'
        assert_eq(attach({ caseId = CASE }, { type = 'telemetry', id = 'x' }).error, 'not_allowed')
        -- a player actor is read from the server
        Mock.invokingResource = 'pfm-policejob'
        local t = attach({ caseId = CASE }, { type = 'telemetry', id = 'OFF1:100-200' }, { actor = { src = PATROL } })
        assert_eq(t.ok, true)
        assert_eq(one('SELECT by_cid FROM pf_mdt_case_links WHERE id = ?', { t.linkId }).by_cid, 'OFF2')
        -- a system record is removed only by a supervisor
        Mock.invokingResource = nil
        local dr = n("SELECT id FROM pf_mdt_case_links WHERE case_id = ? AND ref_type = 'death_record'", { CASE })
        local id3 = call('pf_mdt:cases:create', LEAD, { title = 'Unlink test' }).caseId
        Mock.invokingResource = 'pf-justice'
        local cl = attach({ caseId = id3 }, { type = 'death_record', id = 13 })
        Mock.invokingResource = nil
        assert_eq(call('pf_mdt:cases:unlink', LEAD, { linkId = cl.linkId }).error, 'no_permission')
        assert_eq(call('pf_mdt:cases:unlink', SUP, { linkId = cl.linkId }).ok, true)
        assert_true(dr > 0)
    end)

    it('incident targets go to the incident links; the incident view lists them and the cases that link it', function()
        local attach = Mock.selfExport('AttachExternalRecord')
        Mock.invokingResource = 'pf-justice'
        local r = attach({ incidentId = 'INC-1' }, { type = 'custody', id = 77 })
        assert_eq(r.ok, true)
        assert_eq(attach({ incidentId = 'INC-1' }, { type = 'custody', id = 77 }).duplicate, true)
        assert_eq(attach({ incidentId = 'INC-404' }, { type = 'custody', id = 77 }).error, 'not_found')
        local numeric = n("SELECT id FROM pf_mdt_incidents WHERE incidentId = 'INC-1'")
        assert_eq(attach({ incidentId = numeric }, { type = 'order', id = 41 }).ok, true)
        Mock.invokingResource = nil
        assert_eq(n("SELECT COUNT(*) FROM pf_mdt_record_audit WHERE entity = 'incident' AND entity_id = 'INC-1'"), 2)
        local view = call('pf_mdt:cases:incidentLinks', PATROL, { incidentId = 'INC-1' })
        assert_eq(view.ok, true)
        assert_eq(#view.links, 2)
        assert_eq(view.cases[1].id, CASE)
    end)

    it('unlinking evidence asks PJ to drop its case ref too', function()
        local id4 = call('pf_mdt:cases:create', LEAD, { title = 'Evidence unlink' }).caseId
        local l = call('pf_mdt:cases:link', LEAD, { caseId = id4, refType = 'evidence', refId = 501 })
        assert_eq(l.ok, true)
        local before = #PJ.unlinks
        assert_eq(call('pf_mdt:cases:unlink', LEAD, { linkId = l.linkId }).ok, true)
        assert_eq(#PJ.unlinks, before + 1)
        assert_eq(PJ.unlinks[#PJ.unlinks].caseRef.id, tostring(id4))
        assert_eq(n('SELECT COUNT(*) FROM pf_mdt_case_links WHERE id = ?', { l.linkId }), 0)
    end)

    it('a deleted character leaves the case anonymous and cancels what still waits for the court', function()
        local id5 = call('pf_mdt:cases:create', LEAD, { title = 'Deleted suspect' }).caseId
        local p = call('pf_mdt:cases:addPerson', LEAD, { caseId = id5, role = 'suspect', citizenid = 'WIT8' }).personId
        local s = call('pf_mdt:cases:submit', LEAD, { caseId = id5, personId = p, charges = { 'PC-211' } })
        assert_eq(s.state, 'pending')
        Mock.fireEvent('pfm-core:server:characterDeleted', nil, 'WIT8')
        assert_eq(n("SELECT COUNT(*) FROM pf_mdt_case_people WHERE citizenid = 'WIT8'"), 0)
        assert_eq(one('SELECT name FROM pf_mdt_case_people WHERE id = ?', { p }).name, 'Deleted character')
        assert_eq(one('SELECT state FROM pf_mdt_case_submissions WHERE id = ?', { s.submissionId }).state, 'cancelled')
        -- the filed submission of SUS9 is a court record and stays
        assert_eq(n("SELECT COUNT(*) FROM pf_mdt_case_submissions WHERE citizenid = 'SUS9' AND state = 'filed'"), 3)
    end)
end)
