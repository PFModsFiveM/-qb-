-- Batch 20 (20F) on MariaDB: pf-policemdt-DEV schema v9 and server/personnel_ext.lua:
--   * a v8 install applies only v9; the tables, keys and columns exist; every v9 step runs again;
--   * a use-of-force draft from the (contract) timeline is stored with its summary, hold and key; the
--     same key finds it; the chain submit -> return -> resubmit -> approve -> close moves only with
--     the conditional updates (a stale second decision changes nothing) and leaves one row per step;
--   * IA: keyed intake, the daily cap counts real rows, the list leaves out complaints naming the
--     reader, assign -> finding -> close; performance reviews are unique per officer/reviewer/period;
--   * the officer profile summary groups real rows; audit rows are written for every change.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
local states = { ['pfm-policejob'] = 'started', ['pf-government'] = 'started' }
function GetResourceState(name) return states[name] or 'missing' end

RealDB.exec('pfm-core/qbcore.sql')
function GetCurrentResourceName() return 'pfm-core' end
load_resource('pfm-core/server/migrations.lua')
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end

local function addPlayerRow(cid, first, last, job, grade)
    MySQL.query.await([[INSERT INTO players (citizenid, cid, license, name, money, charinfo, job, gang, position, metadata, inventory)
        VALUES (?, 1, ?, ?, '{}', ?, ?, '{}', '{}', '{}', '[]')]],
        { cid, 'license:' .. cid, first, json.encode({ firstname = first, lastname = last }), json.encode({ name = job, grade = { level = grade or 0 } }) })
end
addPlayerRow('OFF1', 'Ada', 'Patrol', 'police', 1)
addPlayerRow('SGT2', 'Ben', 'Sergeant', 'police', 2)
addPlayerRow('LT3', 'Cara', 'Lieutenant', 'police', 3)
addPlayerRow('CIV4', 'Sam', 'Citizen', 'unemployed', 0)
addPlayerRow('CHF6', 'Dana', 'Chief', 'police', 4)
addPlayerRow('ZED7', 'Zed', 'Offline', 'police', 1)
addPlayerRow('CIV8', 'Vera', 'Walker', 'unemployed', 0)
MySQL.query.await([[UPDATE players SET metadata = '{"callsign":"2B-07"}' WHERE citizenid = 'ZED7']])

-- pfm-policejob telemetry by contract (18C)
local TL = { events = {}, holds = {} }
Mock.exportsByResource['pfm-policejob'] = {
    GetTimeline = function(_, cid, from, to, opts)
        local out = {}
        for _, e in ipairs(TL.events) do if e.at >= from and e.at <= to and e.id > ((opts and opts.after) or 0) then out[#out + 1] = e end end
        return { ok = true, events = out }
    end,
    HoldTimeline = function(_, cid, from, to, caseRef)
        TL.holds[#TL.holds + 1] = caseRef
        return { ok = true, holdId = #TL.holds }
    end,
}
Mock.exportsByResource['pf-government'] = {
    ListQualifications = function() return { ok = true, dept = 'police', list = { { qual = 'patrol', has = true, source = 'implied' } } } end,
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
local function hasIndex(t, i)
    return n('SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND INDEX_NAME = ?', { t, i }) > 0
end

describe('MDT schema v9 (MariaDB)', function()
    it('a v8 install applies only v9; tables, keys and columns exist', function()
        local v18 = {}
        for i = 1, 8 do v18[i] = Schema.Migrations[i] end
        assert_eq(RunMigrations(KEY, v18), true)
        assert_eq(n('SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = ?', { KEY }), 8)
        local before = one('SELECT applied_at FROM pf_schema_migrations WHERE resource = ? AND version = 8', { KEY }).applied_at
        assert_true(Schema.Run(), tostring(Schema.lastError))
        local rows = MySQL.query.await('SELECT version, name, applied_at FROM pf_schema_migrations WHERE resource = ? ORDER BY version', { KEY })
        assert_eq(#rows, 9)
        assert_eq(rows[9].name, 'personnel, use of force, pursuits, IA')
        assert_eq(rows[8].applied_at, before, 'v8 not applied again')
        for _, c in ipairs({ 'kind', 'officer_cid', 'subject_cid', 'custody_id', 'force_level', 'telemetry_from', 'telemetry_to',
            'telemetry_state', 'hold_id', 'auto_summary', 'narrative', 'state', 'origin', 'reviewer_cid', 'closed_by', 'idem_key', 'submitted_at' }) do
            assert_true(hasColumn('pf_mdt_force_reports', c), c)
        end
        assert_true(hasIndex('pf_mdt_force_reports', 'uq_fr_key'))
        assert_true(hasIndex('pf_mdt_ia_complaints', 'uq_ia_key'))
        assert_true(hasIndex('pf_mdt_reviews', 'uq_rev_period'))
        assert_true(hasColumn('pf_mdt_force_reviews', 'step'))
        assert_true(hasColumn('pf_mdt_ia_events', 'action'))
    end)

    it('every v9 step can run again', function()
        for _, sql in ipairs(Schema.Migrations[9].up) do MySQL.query.await(sql) end
        assert_eq(RunMigrations(KEY, Schema.Migrations), true)
        assert_eq(n('SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = ?', { KEY }), 9)
    end)
end)

load_resource(RES .. 'server/personnel_ext.lua')
local P = PFMdtPersonnel
QBCoreMock.Shared.Jobs.police = { label = 'Police', grades = { ['0'] = {}, ['1'] = {}, ['2'] = {}, ['3'] = {}, ['4'] = { isboss = true } } }

local OFF, SGT, LT, CIV, CHIEF = 1, 2, 3, 4, 6
local NAMES = { OFF1 = { 'Ada', 'Patrol' }, SGT2 = { 'Ben', 'Sergeant' }, LT3 = { 'Cara', 'Lieutenant' }, CHF6 = { 'Dana', 'Chief' } }
local function cop(src, cid, grade)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.charinfo = { firstname = NAMES[cid][1], lastname = NAMES[cid][2] }
    p.PlayerData.job = { name = 'police', type = 'leo', grade = { level = grade }, onduty = true, isboss = grade >= 4 }
end
BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    Mock.invokingResource = nil
    cop(OFF, 'OFF1', 1)
    cop(SGT, 'SGT2', 2)
    cop(LT, 'LT3', 3)
    cop(CHIEF, 'CHF6', 4)
    Mock.newPlayer(CIV, 'CIV4').PlayerData.charinfo = { firstname = 'Sam', lastname = 'Citizen' }
end
local function call(name, src, data)
    Mock.gameTimer = Mock.gameTimer + 10000
    return Mock.callCallback(name, src, data)
end

local REPORT
describe('use-of-force reports (MariaDB)', function()
    it('a draft stores the server summary, the hold and the key; the key finds it again', function()
        local t = Mock.clock
        TL.events = {
            { id = 1, kind = 'pos', coords = { x = 0, y = 0, z = 0 }, at = t - 100 },
            { id = 2, kind = 'pos', coords = { x = 100, y = 0, z = 0 }, at = t - 90 },
            { id = 3, kind = 'use_of_force', data = { action = 'tackle', subject = 'CIV4' }, coords = { x = 100, y = 0, z = 0 }, at = t - 80 },
        }
        local r = call('pf_mdt:force:draft', OFF, { minutes = 5, kind = 'pursuit' })
        assert_eq(r.ok, true, tostring(r.error))
        REPORT = r.reportId
        local row = one('SELECT * FROM pf_mdt_force_reports WHERE id = ?', { REPORT })
        assert_eq(row.kind, 'pursuit')
        assert_eq(row.state, 'draft')
        assert_eq(tonumber(row.force_level), 2)
        assert_eq(row.subject_cid, 'CIV4')
        assert_eq(row.officer_name, 'Ada Patrol')
        assert_eq(row.telemetry_state, 'ok')
        assert_eq(tonumber(row.hold_id), #TL.holds)
        local s = json.decode(row.auto_summary)
        assert_eq(s.pursuit.distance, 100)
        assert_eq(s.pursuit.maxSpeed, 10)
        assert_eq(n("SELECT COUNT(*) FROM pf_mdt_record_audit WHERE entity = 'force_report' AND entity_id = ? AND action = 'create'", { tostring(REPORT) }), 1)
        -- the same window and kind again (a double click) finds the first draft
        local again = P.DraftForce({ kind = 'pursuit', officerCid = 'OFF1', from = tonumber(row.telemetry_from), to = tonumber(row.telemetry_to) },
            { key = row.idem_key, viewer = OFF, origin = 'officer', by = { cid = 'OFF1' } })
        assert_eq(again.duplicate, true)
        assert_eq(again.reportId, REPORT)
        assert_eq(n('SELECT COUNT(*) FROM pf_mdt_force_reports'), 1)
    end)

    it('submit -> return -> resubmit -> approve -> close, one chain row per step', function()
        assert_eq(call('pf_mdt:force:submit', OFF, { id = REPORT }).error, 'bad_args', 'no narrative yet')
        assert_eq(call('pf_mdt:force:update', OFF, { id = REPORT, narrative = 'Suspect fled on foot; I tackled him at the corner.' }).ok, true)
        assert_eq(call('pf_mdt:force:submit', OFF, { id = REPORT }).state, 'submitted')
        assert_eq(call('pf_mdt:force:update', OFF, { id = REPORT, narrative = 'changed after submit' }).error, 'invalid_state')
        assert_eq(call('pf_mdt:force:review', SGT, { id = REPORT, decision = 'return', note = 'Add the injuries seen' }).state, 'returned')
        assert_eq(call('pf_mdt:force:review', LT, { id = REPORT, decision = 'approve' }).error, 'invalid_state', 'a stale second decision')
        assert_eq(call('pf_mdt:force:update', OFF, { id = REPORT, narrative = 'Suspect fled; tackled; abrasion on the left knee, EMS declined.' }).ok, true)
        assert_eq(call('pf_mdt:force:submit', OFF, { id = REPORT }).state, 'submitted')
        assert_eq(call('pf_mdt:force:review', OFF, { id = REPORT, decision = 'approve' }).error, 'no_permission')
        assert_eq(call('pf_mdt:force:review', SGT, { id = REPORT, decision = 'approve' }).state, 'reviewed')
        assert_eq(call('pf_mdt:force:close', SGT, { id = REPORT }).error, 'no_permission', 'the reviewer does not close')
        assert_eq(call('pf_mdt:force:close', CHIEF, { id = REPORT, note = 'Within policy' }).state, 'closed')
        local row = one('SELECT state, reviewer_cid, closed_by, submitted_at FROM pf_mdt_force_reports WHERE id = ?', { REPORT })
        assert_eq(row.state, 'closed')
        assert_eq(row.reviewer_cid, 'SGT2')
        assert_eq(row.closed_by, 'CHF6')
        local steps = MySQL.query.await('SELECT step, by_cid FROM pf_mdt_force_reviews WHERE report_id = ? ORDER BY id', { REPORT })
        local seq = {}
        for _, s in ipairs(steps) do seq[#seq + 1] = s.step .. ':' .. s.by_cid end
        assert_eq(table.concat(seq, ','), 'submit:OFF1,return:SGT2,submit:OFF1,approve:SGT2,close:CHF6')
        local got = call('pf_mdt:force:get', OFF, { id = REPORT })
        assert_eq(#got.chain, 5)
        assert_eq(got.report.summary.level, 2)
        assert_eq(call('pf_mdt:force:get', CIV, { id = REPORT }).error, 'no_access')
    end)

    it('lists: own reports for officers, every report for supervisors', function()
        local mine = call('pf_mdt:force:list', OFF, {})
        assert_eq(#mine.list, 1)
        assert_eq(call('pf_mdt:force:list', OFF, { officerCid = 'SGT2' }).error, 'no_permission')
        assert_eq(#call('pf_mdt:force:list', SGT, { state = 'closed' }).list, 1)
    end)
end)

describe('internal affairs (MariaDB)', function()
    local ID
    it('keyed intake, the daily cap on real rows, the list leaves out the named officer', function()
        Mock.invokingResource = 'pf-citizen'
        local file = Mock.selfExport('FileIaComplaint')
        local r = file({ officerCid = 'LT3', category = 'discourtesy', summary = 'Insulted me during the traffic stop.' }, { key = 'portal:CIV4:1', actor = { src = CIV } })
        assert_eq(r.ok, true, tostring(r.error))
        ID = r.complaintId
        assert_eq(file({ officerCid = 'LT3', summary = 'Insulted me during the traffic stop.' }, { key = 'portal:CIV4:1', actor = { src = CIV } }).duplicate, true)
        assert_eq(file({ officerCid = 'OFF1', summary = 'Insulted me during the traffic stop.' }, { key = 'portal:CIV4:1', actor = { src = CIV } }).error, 'key_reused')
        assert_eq(file({ officerCid = 'OFF1', summary = 'Second complaint, other stop.' }, { key = 'portal:CIV4:2', actor = { src = CIV } }).ok, true)
        assert_eq(file({ officerName = 'Unit 1A-12', summary = 'Third complaint today.' }, { key = 'portal:CIV4:3', actor = { src = CIV } }).ok, true)
        assert_eq(file({ officerCid = 'OFF1', summary = 'Fourth complaint today.' }, { key = 'portal:CIV4:4', actor = { src = CIV } }).error, 'rate_limited')
        Mock.invokingResource = nil
        local row = one('SELECT * FROM pf_mdt_ia_complaints WHERE id = ?', { ID })
        assert_eq(row.complainant_cid, 'CIV4')
        assert_eq(row.complainant_name, 'Sam Citizen')
        assert_eq(row.officer_name, 'Cara Lieutenant')
        assert_eq(row.channel, 'portal')
        assert_eq(row.state, 'received')
        local listLt = call('pf_mdt:ia:list', LT, {})
        for _, c in ipairs(listLt.list) do assert_true(c.officerCid ~= 'LT3', 'the named officer sees it') end
        assert_eq(#listLt.list, 2)
        assert_eq(#call('pf_mdt:ia:list', CHIEF, {}).list, 3)
    end)

    it('assign -> note -> finding -> close, with the case log', function()
        assert_eq(call('pf_mdt:ia:assign', CHIEF, { id = ID, investigatorCid = 'LT3' }).error, 'conflict')
        assert_eq(call('pf_mdt:ia:assign', CHIEF, { id = ID }).state, 'investigating')
        assert_eq(call('pf_mdt:ia:note', CHIEF, { id = ID, note = 'Bodycam timeline requested.' }).ok, true)
        assert_eq(call('pf_mdt:ia:finding', CHIEF, { id = ID, finding = 'sustained', outcome = 'Verbal counselling' }).state, 'sustained')
        assert_eq(call('pf_mdt:ia:close', CHIEF, { id = ID }).state, 'closed')
        local got = call('pf_mdt:ia:get', CHIEF, { id = ID })
        local seq = {}
        for _, e in ipairs(got.events) do seq[#seq + 1] = e.action end
        assert_eq(table.concat(seq, ','), 'received,assigned,note,sustained,closed')
        assert_eq(got.complaint.outcome, 'Verbal counselling')
        assert_eq(call('pf_mdt:ia:get', LT, { id = ID }).error, 'not_found')
    end)
end)

describe('IA: officers named in words (MariaDB)', function()
    it('resolves a unique officer from the stored characters and the roster; leaves ambiguous names unresolved', function()
        MySQL.query.await("INSERT INTO pf_mdt_roster (callsign, `rank`, officer_name, citizenid, created_at, updated_at) VALUES ('3C-01', 'Officer', 'Ada', 'OFF1', NOW(), NOW())")
        Mock.invokingResource = 'pf-justice'
        local file = Mock.selfExport('FileIaComplaint')
        local a = file({ complainantCid = 'CIV8', officerName = 'officer zed offline', summary = 'Pushed me over at the bus stop.' }, { key = 'portal:CIV8:1' })
        assert_eq(a.officerResolved, true, tostring(a.error))
        assert_eq(one('SELECT officer_cid FROM pf_mdt_ia_complaints WHERE id = ?', { a.complaintId }).officer_cid, 'ZED7', 'offline officer from players.job')
        local b = file({ complainantCid = 'CIV8', officerCallsign = '2B-07', summary = 'Pushed me over at the bus stop.' }, { key = 'portal:CIV8:2' })
        assert_eq(one('SELECT officer_cid FROM pf_mdt_ia_complaints WHERE id = ?', { b.complaintId }).officer_cid, 'ZED7', 'callsign from metadata')
        local c = file({ complainantCid = 'CIV8', officerCallsign = '3C-01', summary = 'Pushed me over at the bus stop.' }, { key = 'portal:CIV8:3' })
        assert_eq(c.officerResolved, true)
        assert_eq(one('SELECT officer_cid FROM pf_mdt_ia_complaints WHERE id = ?', { c.complaintId }).officer_cid, 'OFF1', 'callsign from the roster')
        Mock.invokingResource = nil
    end)

    it('an unresolved complaint naming an IA officer by name is hidden from that officer only', function()
        MySQL.query.await([[INSERT INTO pf_mdt_ia_complaints (complainant_cid, officer_cid, officer_name, category, channel, summary, state, created_at, updated_at)
            VALUES ('CIV8', NULL, 'Lt. CARA lieutenant', 'conduct', 'portal', 'Rude', 'received', 1, 1)]])
        local id = n("SELECT id FROM pf_mdt_ia_complaints WHERE officer_name = 'Lt. CARA lieutenant'")
        for _, c in ipairs(call('pf_mdt:ia:list', LT, {}).list) do assert_true(c.id ~= id, 'listed to the officer it names') end
        local seen = false
        for _, c in ipairs(call('pf_mdt:ia:list', CHIEF, {}).list) do if c.id == id then seen = true end end
        assert_true(seen)
        assert_eq(call('pf_mdt:ia:get', LT, { id = id }).error, 'not_found')
        assert_eq(call('pf_mdt:ia:assign', LT, { id = id }).error, 'not_found')
        assert_eq(call('pf_mdt:ia:assign', CHIEF, { id = id, investigatorCid = 'LT3' }).error, 'conflict')
    end)
end)

describe('reviews and the profile summary (MariaDB)', function()
    it('one review per officer, reviewer and period', function()
        local r = call('pf_mdt:reviews:create', SGT, { officerCid = 'OFF1', period = '2026-11', scores = { conduct = 4, reports = 3 }, notes = 'Solid month.' })
        assert_eq(r.ok, true, tostring(r.error))
        assert_eq(call('pf_mdt:reviews:create', SGT, { officerCid = 'OFF1', period = '2026-11', scores = { conduct = 5 } }).error, 'conflict')
        assert_eq(call('pf_mdt:reviews:create', LT, { officerCid = 'OFF1', period = '2026-11', scores = { conduct = 5 } }).ok, true)
        local mine = call('pf_mdt:reviews:list', OFF, {})
        assert_eq(#mine.list, 2)
        assert_eq(mine.list[2].scores.reports, 3)
    end)

    it('the profile summary groups the real rows; IA counts for IA staff only', function()
        local s = P.ProfileSummary(CHIEF, 'OFF1')
        assert_eq(s.force.counts.closed, 1)
        assert_eq(#s.force.recent, 1)
        assert_eq(#s.reviews, 2)
        assert_eq(s.qualifications[1].qual, 'patrol')
        assert_eq(s.ia.open, 2, 'the second complaint and the roster-callsign one name OFF1')
        local own = P.ProfileSummary(OFF, 'OFF1')
        assert_eq(own.ia, nil)
        assert_eq(P.ProfileSummary(OFF, 'SGT2'), nil)
    end)
end)
