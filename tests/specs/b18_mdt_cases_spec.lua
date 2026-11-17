-- Batch 18 (18E) pf-policemdt-DEV cases and investigations, mocked (the SQL itself is exercised in
-- tests/realdb_specs/b18_mdt_cases_realdb_spec.lua):
--   * manifest: server/cases.lua and server/records_ext.lua load after main.lua;
--   * schema v8: one rerun-safe statement list (IF NOT EXISTS everywhere, no DROP) that creates every
--     pf_mdt_ table cases.lua names plus the 18F BOLO/audit tables and warrant columns; cases.lua runs
--     no DDL and no migrations of its own;
--   * gate: every write endpoint is in the access gate with its action, so civilians, off-duty
--     officers and low grades are refused before the handler; the default grades exist;
--   * endpoints refuse before the schema is ready, rate limit writes, refuse while the case lock is
--     held, and check input before touching the database;
--   * court hand-over decisions: no pf-justice / no FileCase -> pending (nothing claimed), filed ->
--     court case id with the submission key, retryable errors -> pending, clear refusals -> refused;
--   * AttachExternalRecord refuses resources outside the allowlist.
load_resource('tests/lua/fivem_mocks.lua')
function IsDuplicityVersion() return true end
local states = {}
function GetResourceState(name) return states[name] or 'missing' end
QBCore = QBCoreMock

-- MySQL global: records every statement; answers are scripted per test
local log, answers = {}, {}
local function run(kind, sql, params)
    log[#log + 1] = { kind = kind, sql = sql, params = params }
    for _, a in ipairs(answers) do
        if sql:find(a.match, 1, true) then
            if type(a.value) == 'function' then return a.value(sql, params) end
            return a.value
        end
    end
    if kind == 'update' then return 1 end
    if kind == 'insert' then return 1 end
    if kind == 'scalar' then return 0 end
    if kind == 'query' then return {} end
    return nil
end
local function op(kind) return { await = function(sql, p) return run(kind, sql, p) end } end
MySQL = { query = op('query'), insert = op('insert'), update = op('update'), single = op('single'), scalar = op('scalar') }
local function logged(fragment)
    local n = 0
    for _, e in ipairs(log) do if e.sql:find(fragment, 1, true) then n = n + 1 end end
    return n
end

local RES = '[pfscripts]/pf-policemdt-DEV/'
function GetCurrentResourceName() return 'pf-policemdt-DEV' end
Config = nil
load_resource(RES .. 'shared/framework.lua')
load_resource(RES .. 'config.lua')
load_resource(RES .. 'server/access.lua')
load_resource(RES .. 'server/schema.lua')
load_resource(RES .. 'server/cases.lua')
local Schema, Cases = PFMdtSchema, PFMdtCases
QBCoreMock.Shared.Jobs.police = { label = 'Police', grades = { ['0'] = {}, ['4'] = { isboss = true } } }

local OFFICER, LOW, CIV = 1, 2, 3
BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    Mock.invokingResource = nil
    log, answers = {}, {}
    states = {}
    Schema.state = 'ready'
    for k in pairs(Cases.Locks) do Cases.Locks[k] = nil end
    local o = Mock.newPlayer(OFFICER, 'OFF1')
    o.PlayerData.job = { name = 'police', grade = { level = 2 }, onduty = true }
    local l = Mock.newPlayer(LOW, 'OFF2')
    l.PlayerData.job = { name = 'police', grade = { level = 0 }, onduty = true }
    Mock.newPlayer(CIV, 'CIV3')
end
local function call(name, src, data)
    Mock.gameTimer = Mock.gameTimer + 5000
    return Mock.callCallback(name, src, data)
end

describe('MDT cases: manifest and schema v8', function()
    it('loads cases.lua and records_ext.lua after main.lua', function()
        local manifest = __readfile(RES .. 'fxmanifest.lua')
        local block = manifest:match('server_scripts%s*(%b{})')
        local pos, i = {}, 0
        for f in block:gmatch("'(server/[%w_]+%.lua)'") do i = i + 1; pos[f] = i end
        assert_true(pos['server/cases.lua'] ~= nil, 'cases.lua listed')
        assert_true(pos['server/records_ext.lua'] ~= nil, 'records_ext.lua listed')
        assert_true(pos['server/cases.lua'] > pos['server/main.lua'])
        assert_true(pos['server/records_ext.lua'] > pos['server/main.lua'])
        assert_true(pos['server/schema.lua'] < pos['server/main.lua'])
    end)

    it('v8 is one rerun-safe statement list after v7', function()
        local m = Schema.Migrations[8]
        assert_eq(m.version, 8)
        assert_eq(m.name, 'cases, BOLOs, record audit, warrant columns')
        assert_eq(type(m.up), 'table')
        for i = 1, 7 do assert_eq(Schema.Migrations[i].version, i) end
        for _, sql in ipairs(m.up) do
            assert_true(sql:upper():find('DROP', 1, true) == nil, sql)
            local head = sql:match('^(%u+ %u+)')
            if head == 'CREATE TABLE' then assert_true(sql:find('^CREATE TABLE IF NOT EXISTS') ~= nil, sql)
            elseif head == 'ALTER TABLE' then assert_true(sql:find('ADD COLUMN IF NOT EXISTS', 1, true) ~= nil, sql)
            elseif head == 'CREATE INDEX' then assert_true(sql:find('^CREATE INDEX IF NOT EXISTS') ~= nil, sql)
            else error('unexpected statement: ' .. sql) end
        end
    end)

    it('creates every pf_mdt_ table cases.lua names, plus the 18F tables and warrant columns', function()
        local created = {}
        for _, mig in ipairs(Schema.Migrations) do
            if type(mig.up) == 'table' then
                for _, sql in ipairs(mig.up) do for t in sql:gmatch('CREATE TABLE IF NOT EXISTS `([%w_]+)`') do created[t] = true end end
            end
        end
        for _, t in ipairs(Schema.Tables) do created[t.name] = true end
        local code = __readfile(RES .. 'server/cases.lua')
        local seen = 0
        for name in code:gmatch('pf_mdt_[%w_]+') do
            seen = seen + 1
            assert_true(created[name], name .. ' is named in cases.lua but not created')
        end
        assert_true(seen > 20)
        for _, t in ipairs({ 'pf_mdt_cases', 'pf_mdt_case_links', 'pf_mdt_case_people', 'pf_mdt_case_entries',
            'pf_mdt_case_submissions', 'pf_mdt_incident_links', 'pf_mdt_bolos', 'pf_mdt_record_audit' }) do
            assert_true(created[t], t)
        end
        local v8 = table.concat(Schema.Migrations[8].up, '\n')
        for _, c in ipairs({ 'warrant_type', 'approval_state', 'approved_by', 'review_id', 'served_custody_id', 'address' }) do
            assert_true(v8:find('`pf_mdt_warrants` ADD COLUMN IF NOT EXISTS `' .. c .. '`', 1, true) ~= nil, c)
        end
        assert_true(v8:find("`approval_state` VARCHAR(16) NOT NULL DEFAULT 'legacy'", 1, true) ~= nil)
        assert_true(v8:find('UNIQUE KEY `uq_case_sub_key` (`idem_key`)', 1, true) ~= nil, 'submission key is unique')
        -- person_of_interest (18 characters) fits the role column
        assert_true(v8:find('`role` VARCHAR(20)', 1, true) ~= nil)
        assert_true(code:find('CREATE TABLE', 1, true) == nil and code:find('ALTER TABLE', 1, true) == nil)
        assert_true(code:find('RunMigrations', 1, true) == nil)
    end)
end)

describe('MDT cases: gate and endpoint guards', function()
    it('every write endpoint is gated with its action; default grades exist', function()
        local want = {
            ['pf_mdt:cases:create'] = 'caseCreate', ['pf_mdt:cases:update'] = 'caseEdit', ['pf_mdt:cases:setStatus'] = 'caseEdit',
            ['pf_mdt:cases:setLead'] = 'caseEdit', ['pf_mdt:cases:link'] = 'caseEdit', ['pf_mdt:cases:unlink'] = 'caseEdit',
            ['pf_mdt:cases:addPerson'] = 'caseEdit', ['pf_mdt:cases:removePerson'] = 'caseEdit', ['pf_mdt:cases:addEntry'] = 'caseEdit',
            ['pf_mdt:cases:setEntryStatus'] = 'caseEdit', ['pf_mdt:cases:submit'] = 'caseSubmit',
            ['pf_mdt:cases:withdrawSubmission'] = 'caseSubmit',
        }
        for name, action in pairs(want) do
            assert_true(Mock.callbacks[name] ~= nil, name .. ' registered')
            assert_eq(PFMdtAccess.Actions[name] and PFMdtAccess.Actions[name].action, action, name)
        end
        for _, name in ipairs({ 'pf_mdt:cases:list', 'pf_mdt:cases:get', 'pf_mdt:cases:incidentLinks' }) do
            assert_true(Mock.callbacks[name] ~= nil, name)
            assert_true(PFMdtAccess.Actions[name] == nil, name .. ' is a read')
        end
        assert_eq(PFMdtAccess.MinGrade('caseSubmit', 'police'), 2)
        assert_eq(PFMdtAccess.MinGrade('caseSupervise', 'police'), 3)
        assert_eq(PFMdtAccess.MinGrade('caseCreate', 'police'), 0)
    end)

    it('civilians, off-duty officers and low grades are refused before the handler runs', function()
        assert_eq(call('pf_mdt:cases:list', CIV, {}).error, 'no_access')
        assert_eq(call('pf_mdt:cases:create', CIV, { title = 'x' }).error, 'no_access')
        Mock.players[OFFICER].PlayerData.job.onduty = false
        assert_eq(call('pf_mdt:cases:create', OFFICER, { title = 'x' }).error, 'off_duty')
        assert_eq(call('pf_mdt:cases:submit', LOW, { caseId = 1, personId = 1, charges = { 'PC-1' } }).error, 'no_permission')
        assert_eq(#log, 0, 'no query ran')
        -- an off-duty officer still reads
        Mock.players[OFFICER].PlayerData.job.onduty = false
        assert_eq(call('pf_mdt:cases:list', OFFICER, {}).ok, true)
    end)

    it('before the schema is ready nothing touches the database', function()
        Schema.state = 'running'
        local res = call('pf_mdt:cases:create', OFFICER, { title = 'Robbery' })
        assert_eq(res.error, 'db_unavailable')
        assert_eq(res.success, false)
        assert_eq(#log, 0)
    end)

    it('writes are limited to one per second per officer', function()
        assert_eq(call('pf_mdt:cases:create', OFFICER, { title = 'One' }).ok, true)
        local res = Mock.callCallback('pf_mdt:cases:create', OFFICER, { title = 'Two' })
        assert_eq(res.error, 'rate_limited')
        assert_eq(logged('INSERT INTO pf_mdt_cases'), 1)
    end)

    it('input is checked before the database: titles, statuses, kinds, roles, charges', function()
        assert_eq(call('pf_mdt:cases:create', OFFICER, { title = '\n\t ' }).error, 'bad_args')
        assert_eq(call('pf_mdt:cases:create', OFFICER, { title = 'x', priority = 0 }).error, 'bad_args')
        assert_eq(call('pf_mdt:cases:setStatus', OFFICER, { caseId = 1, status = 'deleted' }).error, 'bad_args')
        assert_eq(call('pf_mdt:cases:setStatus', OFFICER, { caseId = 'x', status = 'active' }).error, 'bad_args')
        assert_eq(call('pf_mdt:cases:link', OFFICER, { caseId = 1, refType = 'death_record', refId = 1 }).error, 'bad_args')
        assert_eq(call('pf_mdt:cases:addPerson', OFFICER, { caseId = 1, role = 'judge' }).error, 'bad_args')
        assert_eq(call('pf_mdt:cases:addEntry', OFFICER, { caseId = 1, kind = 'note', body = '   ' }).error, 'bad_args')
        assert_eq(call('pf_mdt:cases:submit', OFFICER, { caseId = 1, personId = 1, charges = {} }).error, 'bad_args')
        local many = {}
        for i = 1, 21 do many[i] = 'PC-' .. i end
        assert_eq(call('pf_mdt:cases:submit', OFFICER, { caseId = 1, personId = 1, charges = many }).error, 'bad_args')
        assert_eq(call('pf_mdt:cases:submit', OFFICER, { caseId = 1, personId = 1, charges = { "PC-1'; --" } }).error, 'bad_args')
        assert_eq(#log, 0)
    end)

    it('a held case lock answers busy and writes nothing', function()
        Cases.Locks['case:5'] = true
        assert_eq(call('pf_mdt:cases:setStatus', OFFICER, { caseId = 5, status = 'active' }).error, 'busy')
        assert_eq(call('pf_mdt:cases:addEntry', OFFICER, { caseId = 5, kind = 'note', body = 'x' }).error, 'busy')
        assert_eq(#log, 0)
    end)

    it('a long title and body are clipped, control characters removed, the case number comes from the row id', function()
        answers = { { match = 'INSERT INTO pf_mdt_cases', value = 42 } }
        local res = call('pf_mdt:cases:create', OFFICER, { title = string.rep('a', 300) .. '\0', summary = 'line1\r\nline2\7' })
        assert_eq(res.ok, true)
        assert_eq(res.caseNo, 'C-000042')
        local ins
        for _, e in ipairs(log) do if e.sql:find('INSERT INTO pf_mdt_cases', 1, true) then ins = e end end
        assert_eq(#ins.params[2], 128)
        assert_eq(ins.params[6], 'line1\nline2')
        assert_eq(ins.params[5], 'OFF1', 'the creator leads')
        assert_eq(logged('UPDATE pf_mdt_cases SET case_no'), 1)
    end)
end)

describe('MDT cases: court hand-over decisions', function()
    local function sub(state) return { id = 7, case_id = 3, state = state or 'pending', spec = '{"cid":"SUS9"}', idem_key = 'pf-policemdt:case:3:court:7', by_cid = 'OFF1' } end
    local function stubJustice(fn) Mock.exportsByResource['pf-justice'] = { FileCase = fn } end

    it('pf-justice not running: pending, nothing filed or claimed', function()
        local called = false
        stubJustice(function() called = true return { ok = true, caseId = 1 } end)
        local state, msg = Cases.HandOver(sub())
        assert_eq(state, 'pending')
        assert_true(msg:find('not available', 1, true) ~= nil)
        assert_false(called)
        assert_eq(logged("state = 'filed'"), 0)
        assert_eq(Cases.SweepSubmissions(), 0, 'the sweep waits for pf-justice')
    end)

    it('pf-justice running without FileCase (before 19A): pending, attempt counted', function()
        states['pf-justice'] = 'started'
        Mock.exportsByResource['pf-justice'] = {}
        local state = Cases.HandOver(sub())
        assert_eq(state, 'pending')
        assert_eq(logged('attempts = attempts + 1'), 1)
        assert_eq(logged("state = 'filed'"), 0)
    end)

    it('filed: FileCase gets the submission key and a system actor; the court case id is stored', function()
        states['pf-justice'] = 'started'
        local got
        stubJustice(function(_, spec, opts) got = { spec = spec, opts = opts } return { ok = true, caseId = 900 } end)
        answers = { { match = "COUNT(*) FROM pf_mdt_case_submissions WHERE case_id = ? AND state = 'pending'", value = 0 } }
        local state = Cases.HandOver(sub())
        assert_eq(state, 'filed')
        assert_eq(got.opts.key, 'pf-policemdt:case:3:court:7')
        assert_eq(got.opts.actor.kind, 'system')
        assert_eq(got.opts.filedBy, 'OFF1')
        assert_eq(got.spec.cid, 'SUS9')
        local filed
        for _, e in ipairs(log) do if e.sql:find("state = 'filed'", 1, true) then filed = e end end
        assert_eq(filed.params[1], 900)
        assert_eq(logged("UPDATE pf_mdt_cases SET status = ?"), 1, 'case moves to submitted')
    end)

    it('retryable answers stay pending; clear refusals become refused; other states are left alone', function()
        states['pf-justice'] = 'started'
        for _, code in ipairs({ 'busy', 'db_unavailable', 'not_allowed' }) do
            log = {}
            stubJustice(function() return { ok = false, error = code } end)
            assert_eq(Cases.HandOver(sub()), 'pending', code)
            assert_eq(logged("state = 'refused'"), 0, code)
        end
        for _, code in ipairs({ 'bad_args', 'key_reused', 'no_permission' }) do
            log = {}
            stubJustice(function() return { ok = false, error = code, message = 'no' } end)
            assert_eq(Cases.HandOver(sub()), 'refused', code)
            assert_eq(logged("state = 'refused'"), 1, code)
        end
        log = {}
        stubJustice(function() return { ok = true } end) -- ok without a court case id is not a filing
        assert_eq(Cases.HandOver(sub()), 'pending')
        assert_eq(logged("state = 'filed'"), 0)
        assert_eq(Cases.HandOver(sub('filed')), 'filed')
    end)
end)

describe('MDT cases: AttachExternalRecord allowlist', function()
    it('refuses resources outside the allowlist without a query; checks the record type', function()
        local attach = Mock.selfExport('AttachExternalRecord')
        Mock.invokingResource = 'random-script'
        assert_eq(attach({ caseId = 1 }, { type = 'evidence', id = 1 }).error, 'not_allowed')
        assert_eq(#log, 0)
        Mock.invokingResource = 'pf-ambulancejob'
        assert_eq(attach({ caseId = 1 }, { type = 'report', id = 1 }).error, 'bad_args')
        assert_eq(attach({ caseId = 1 }, { type = 'death_record', id = 'a b' }).error, 'bad_args')
        assert_eq(attach({}, { type = 'death_record', id = 1 }).error, 'bad_args')
        Schema.state = 'running'
        assert_eq(attach({ caseId = 1 }, { type = 'death_record', id = 1 }).error, 'db_unavailable')
        assert_eq(#log, 0)
    end)
end)
