-- pf-policemdt-DEV schema by migrations (batch 15, unit 15F):
--   * server/schema.lua is the one owner of the migration key: v1-v6 keep their numbers and names,
--     v7 creates the SQL-file tables; no other server file runs migrations or DDL;
--   * every pf_mdt_ table the server code names is created by a migration step (fresh install);
--   * v7 only creates what is missing, adds only missing columns/indexes, never touches the
--     charges' money columns of old installs, renames the old SOP column, seeds only empty tables
--     with INSERT IGNORE;
--   * sentencing, the officer pages, the SOPs and the ESX paths wait for the schema; a failed
--     schema run keeps sentencing off and the officer pages answer no_db.
load_resource('tests/lua/fivem_mocks.lua')
function IsDuplicityVersion() return true end
function GetResourceState() return 'missing' end
QBCore = QBCoreMock
promise = promise or { new = function() return { resolve = function(self, v) self.value = v end } end }
Citizen.Await = Citizen.Await or function(p) return p.value end

local RES_DIR = '[pfscripts]/pf-policemdt-DEV/'

-- fake oxmysql export API (main.lua, officers.lua, sop.lua): records every statement
local oxLog = {}
local function ox(_, sql, params, cb)
    if Mock.callable(params) then cb, params = params, {} end
    oxLog[#oxLog + 1] = sql
    if cb then cb({}) end
    return {}
end
Mock.exportsByResource['oxmysql'] = {
    execute = ox, query = ox, fetch = ox,
    insert = function(_, sql, params, cb) oxLog[#oxLog + 1] = sql if Mock.callable(cb) then cb(1) end return 1 end,
    update = function(_, sql, params, cb) oxLog[#oxLog + 1] = sql if Mock.callable(cb) then cb(1) end return 1 end,
    scalar = function(_, sql, params, cb) if Mock.callable(params) then cb = params end oxLog[#oxLog + 1] = sql if Mock.callable(cb) then cb(0) end return 0 end,
}

-- the migration runner: records each call; `migrationResult` decides the answer
local runs, migrationResult = {}, true
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, key, list)
    runs[#runs + 1] = { key = key, list = list }
    if migrationResult == true then return true end
    return false, migrationResult
end

-- MySQL global used by v7's function step: a scripted information_schema and a statement log
local fake = { columns = {}, indexes = {}, tables = {}, log = {} }
local function mysqlRun(kind, sql, params)
    fake.log[#fake.log + 1] = sql
    if sql:find('information_schema.COLUMNS', 1, true) then
        local out = {}
        for t, cols in pairs(fake.columns) do for c in pairs(cols) do out[#out + 1] = { t = t, c = c } end end
        return out
    end
    if sql:find('information_schema.STATISTICS', 1, true) then
        local out = {}
        for t, idx in pairs(fake.indexes) do for i in pairs(idx) do out[#out + 1] = { t = t, i = i } end end
        return out
    end
    if sql:find('information_schema.TABLES', 1, true) then
        local out = {}
        for t in pairs(fake.tables) do out[#out + 1] = { t = t } end
        return out
    end
    if kind == 'scalar' then return 0 end
    if kind == 'single' then return nil end
    return {}
end
local function op(kind)
    return setmetatable({ await = function(sql, p) return mysqlRun(kind, sql, p) end },
        { __call = function(_, sql, p, cb) local r = mysqlRun(kind, sql, p) if cb then cb(r) end return r end })
end
MySQL = { query = op('query'), insert = op('insert'), update = op('update'), single = op('single'), scalar = op('scalar'), prepare = op('query') }
local function logged(fragment)
    local n = 0
    for _, sql in ipairs(fake.log) do if sql:find(fragment, 1, true) then n = n + 1 end end
    return n
end

function GetCurrentResourceName() return 'pf-policemdt-DEV' end
Config = nil
load_resource(RES_DIR .. 'shared/framework.lua')
load_resource(RES_DIR .. 'config.lua')
load_resource(RES_DIR .. 'server/access.lua')
load_resource(RES_DIR .. 'server/schema.lua')
load_resource(RES_DIR .. 'server/main.lua')
load_resource(RES_DIR .. 'server/sentencing.lua')
load_resource(RES_DIR .. 'server/sop.lua')
load_resource(RES_DIR .. 'server/officers.lua')
local Schema, S = PFMdtSchema, PFMdtSentencing
QBCoreMock.Shared.Jobs.police = { label = 'Police', grades = { ['0'] = {}, ['4'] = { isboss = true } } }

-- server scripts in manifest order
local manifest = __readfile(RES_DIR .. 'fxmanifest.lua')
local serverScripts = {}
do
    local block = manifest:match('server_scripts%s*(%b{})')
    for f in block:gmatch("'(server/[%w_]+%.lua)'") do serverScripts[#serverScripts + 1] = f end
end
local function src(f) return __readfile(RES_DIR .. f) end

-- every CREATE TABLE of every migration step (v7's are in Schema.Tables)
local function createdTables()
    local out = {}
    local function scan(sql) for t in sql:gmatch('CREATE TABLE IF NOT EXISTS `([%w_]+)`') do out[t] = true end end
    for _, m in ipairs(Schema.Migrations) do
        if type(m.up) == 'table' then for _, sql in ipairs(m.up) do scan(sql) end end
    end
    for _, t in ipairs(Schema.Tables) do scan(t.sql) end
    return out
end

local function resetSchema(result)
    Schema.state, Schema.lastError = 'idle', nil
    runs, migrationResult = {}, result == nil and true or result
end

describe('MDT schema: one owner of the migration key', function()
    it('loads before main.lua and the never-loaded SQL injector is gone', function()
        local pos = {}
        for i, f in ipairs(serverScripts) do pos[f] = i end
        assert_true(pos['server/schema.lua'] ~= nil, 'schema.lua in server_scripts')
        assert_true(pos['server/schema.lua'] > pos['server/access.lua'] and pos['server/schema.lua'] < pos['server/main.lua'], 'after access.lua, before main.lua')
        assert_true(pos['server/sentencing.lua'] > pos['server/schema.lua'])
        assert_false(pcall(__readfile, RES_DIR .. 'server/sql_init.lua'), 'sql_init.lua deleted')
        assert_true(manifest:find('sql_init', 1, true) == nil)
    end)

    it('only schema.lua calls the runner, under the resource name, and no other file runs DDL', function()
        for _, f in ipairs(serverScripts) do
            -- main.lua's charges diagnostics read SHOW CREATE TABLE; that is not DDL
            local code = src(f):gsub('SHOW CREATE TABLE', '')
            if f ~= 'server/schema.lua' then
                assert_true(code:find('RunMigrations', 1, true) == nil, f .. ' calls RunMigrations')
                assert_true(code:find('CREATE TABLE', 1, true) == nil, f .. ' creates a table')
                assert_true(code:find('ALTER TABLE', 1, true) == nil, f .. ' alters a table')
            end
        end
        assert_eq(S.Migrations, nil, 'sentencing.lua no longer has its own list')
        resetSchema()
        assert_true(Schema.Run())
        assert_eq(#runs, 1)
        assert_eq(runs[1].key, 'pf-policemdt-DEV')
    end)

    it('keeps v1-v6 with their numbers and names, and adds v7', function()
        local want = { 'server-owned MDT jail', 'sentence payment state', 'licence actions audit', 'charge changes audit',
            'roster reset backups', 'jail released while offline', 'MDT tables from the SQL files' }
        assert_eq(#Schema.Migrations, 7)
        for v, name in ipairs(want) do
            assert_eq(Schema.Migrations[v].version, v)
            assert_eq(Schema.Migrations[v].name, name)
        end
        assert_true(Schema.Migrations[1].up[1]:find('CREATE TABLE IF NOT EXISTS `pf_mdt_active_jails`', 1, true) ~= nil)
        assert_eq(#Schema.Migrations[2].up, 9)
        assert_true(Schema.Migrations[6].up[1]:find('`released_why` VARCHAR(16) NULL', 1, true) ~= nil)
        assert_true(Mock.callable(Schema.Migrations[7].up), 'v7 is one function step')
    end)
end)

describe('MDT schema: every table the code uses is created', function()
    it('covers every pf_mdt_ table named in the server scripts', function()
        -- names that are not tables: event prefixes, a convar, an index name, and the pre-v2 FTO
        -- table main.lua reads only when an old install still has it
        local notTables = { pf_mdt_dispatch = true, pf_mdt_evidence_webhook = true,
            pf_mdt_esx_license_suspensions_expires = true, pf_mdt_fto_reports_legacy = true }
        local created = createdTables()
        local seen = 0
        for _, f in ipairs(serverScripts) do
            for name in src(f):gmatch('pf_mdt_[%w_]+') do
                if not notTables[name] then
                    seen = seen + 1
                    assert_true(created[name], name .. ' (named in ' .. f .. ') is not created by a migration')
                end
            end
        end
        assert_true(seen > 100)
    end)

    it('creates the 30 SQL-file tables and the ESX table, without DROP', function()
        local created = createdTables()
        for _, t in ipairs({ 'pf_mdt_warrants', 'pf_mdt_incidents', 'pf_mdt_reports', 'pf_mdt_roster', 'pf_mdt_sops',
            'pf_mdt_fto_reports', 'pf_mdt_fto_report_audit', 'pf_mdt_bulletins', 'pf_mdt_citizen_notes', 'pf_mdt_citizen_flags',
            'pf_mdt_citizen_profiles', 'pf_mdt_officer_mgmt_profiles', 'pf_mdt_officer_discipline', 'pf_mdt_officer_audit',
            'pf_mdt_officer_profiles', 'pf_mdt_weapons_registry', 'pf_mdt_vehicle_notes', 'pf_mdt_vehicle_flags',
            'pf_mdt_vehicle_strikes', 'pf_mdt_vehicle_activity', 'pf_mdt_vehicle_profiles', 'pf_mdt_charges',
            'pf_mdt_pending_sentences', 'pf_mdt_incident_evidence', 'pf_mdt_evidence', 'pf_mdt_manual_citizens',
            'pf_mdt_manual_vehicles', 'pf_mdt_cctv_cameras', 'pf_mdt_chat', 'pf_mdt_templates',
            'pf_mdt_esx_license_suspensions', 'pf_mdt_sentences' }) do
            assert_true(created[t], t)
        end
        assert_true(created.pf_mdt_fto_reports_legacy == nil)
        for _, t in ipairs(Schema.Tables) do
            assert_true(t.sql:find('^CREATE TABLE IF NOT EXISTS') ~= nil, t.name)
            assert_true(t.sql:upper():find('DROP', 1, true) == nil, t.name)
        end
        for _, m in ipairs(Schema.Migrations) do
            if type(m.up) == 'table' then for _, sql in ipairs(m.up) do assert_true(sql:upper():find('DROP', 1, true) == nil) end end
        end
    end)
end)

describe('MDT schema: v7 on an existing database', function()
    -- `tables`: the tables that exist before v7 runs (as a set, or a list of names)
    local function v7(columns, indexes, tables)
        local set = {}
        for k, v in pairs(tables or {}) do if type(k) == 'number' then set[v] = true else set[k] = v end end
        fake.columns, fake.indexes, fake.tables, fake.log = columns or {}, indexes or {}, set, {}
        Schema.Migrations[7].up()
    end

    it('a fresh database gets every table, column-less upgrades are skipped, and the seeds run', function()
        v7()
        assert_eq(logged('CREATE TABLE IF NOT EXISTS'), #Schema.Tables)
        assert_eq(logged('ADD COLUMN'), 0, 'no table to upgrade in the scripted schema')
        assert_eq(logged('INSERT IGNORE INTO `pf_mdt_charges`'), 1)
        assert_eq(logged('INSERT IGNORE INTO `pf_mdt_templates`'), 1)
        assert_eq(logged('INSERT IGNORE INTO `pf_mdt_cctv_cameras`'), 1)
        for _, s in ipairs(Schema.Seeds) do assert_true(s.sql:find('^INSERT IGNORE INTO') ~= nil, s.table) end
    end)

    it('adds only the missing columns and indexes, and leaves old money columns alone', function()
        local full = {}
        for _, c in ipairs(Schema.Columns) do full[c[1]] = full[c[1]] or {} full[c[1]][c[2]] = true end
        -- an officer table as server/officers.lua first created it, and charges with snake_case money
        full.pf_mdt_officer_mgmt_profiles.is_supervisor = nil
        full.pf_mdt_officer_mgmt_profiles.terminated = nil
        full.pf_mdt_charges = { id = true, code = true, name = true, description = true, fine_amount = true, bail_amount = true, jail_time = true }
        full.pf_mdt_roster = { id = true, citizenid = true }
        local idx = { pf_mdt_officer_mgmt_profiles = { PRIMARY = true, idx_status = true }, pf_mdt_roster = { idx_citizenid = true } }
        v7(full, idx, { 'pf_mdt_charges', 'pf_mdt_templates', 'pf_mdt_cctv_cameras' })
        assert_eq(logged('ADD COLUMN'), 2)
        assert_eq(logged('ALTER TABLE `pf_mdt_officer_mgmt_profiles` ADD COLUMN `terminated`'), 1)
        assert_eq(logged('ALTER TABLE `pf_mdt_officer_mgmt_profiles` ADD COLUMN `is_supervisor`'), 1)
        assert_eq(logged('ADD COLUMN `fineAmount`'), 0, 'camelCase money columns are never added')
        assert_eq(logged('ADD INDEX'), 2)
        assert_eq(logged('ADD INDEX `idx_officer_terminated`'), 1)
        assert_eq(logged('ADD INDEX `idx_terminated_status`'), 1)
        assert_eq(logged('INSERT IGNORE'), 0, 'tables that were already there are not seeded')
    end)

    it('seeds only the tables it creates itself, also when an existing one is empty', function()
        -- templates and cameras were imported by hand and emptied by staff; charges is new
        v7(nil, nil, { 'pf_mdt_templates', 'pf_mdt_cctv_cameras' })
        assert_eq(logged('INSERT IGNORE INTO `pf_mdt_charges`'), 1)
        assert_eq(logged('INSERT IGNORE INTO `pf_mdt_templates`'), 0)
        assert_eq(logged('INSERT IGNORE INTO `pf_mdt_cctv_cameras`'), 0)
        assert_true(fake.log[1]:find('information_schema.TABLES', 1, true) ~= nil, 'existing tables are read before any CREATE')
    end)

    it('renames the old SOP column once, and a report status column starts as its approval state', function()
        local cols = {}
        for _, c in ipairs(Schema.Columns) do cols[c[1]] = cols[c[1]] or {} cols[c[1]][c[2]] = true end
        cols.pf_mdt_sops = { id = true, ['procedure'] = true }
        cols.pf_mdt_reports.status = nil
        v7(cols, {}, { 'pf_mdt_charges', 'pf_mdt_templates', 'pf_mdt_cctv_cameras' })
        assert_eq(logged('ALTER TABLE `pf_mdt_sops` CHANGE `procedure` `procedure_text` TEXT NOT NULL'), 1)
        assert_eq(logged('ALTER TABLE `pf_mdt_reports` ADD COLUMN `status`'), 1)
        assert_eq(logged('UPDATE `pf_mdt_reports` SET `status` = `approvalStatus`'), 1)
        cols.pf_mdt_sops = { id = true, procedure_text = true }
        cols.pf_mdt_reports.status = true
        v7(cols, {}, { 'pf_mdt_charges', 'pf_mdt_templates', 'pf_mdt_cctv_cameras' })
        assert_eq(logged('CHANGE `procedure`'), 0)
        assert_eq(logged('UPDATE `pf_mdt_reports`'), 0, 'an existing status column is not rewritten')
    end)
end)

describe('MDT schema: modules wait for it', function()
    it('runs once; later callers reuse the result', function()
        resetSchema()
        assert_true(Schema.WaitReady())
        assert_true(Schema.WaitReady())
        assert_true(Schema.Run())
        assert_eq(#runs, 1)
        assert_true(Schema.Ready())
    end)

    it('announces readiness with a server-only event', function()
        resetSchema()
        local got = 0
        AddEventHandler('pf_mdt:server:schemaReady', function() got = got + 1 end)
        assert_true(Schema.Run())
        assert_eq(got, 1)
    end)

    it('sentencing starts only on a ready schema', function()
        resetSchema('boom')
        assert_false(S.Start())
        assert_false(S.dbReady)
        assert_eq(Schema.state, 'failed')
        assert_eq(Schema.lastError, 'boom')
        assert_false(Schema.WaitReady(), 'a failed run is not repeated by every waiter')
        assert_eq(#runs, 1)
        migrationResult = true
        assert_true(Schema.Run(), 'Run tries again')
        assert_true(S.Start())
        assert_true(S.dbReady)
    end)

    it('the officer pages answer no_db while the schema failed, and query once it is ready', function()
        local p = Mock.newPlayer(1, 'COP1')
        p.PlayerData.job = { name = 'police', label = 'Police', onduty = true, isboss = true, grade = { level = 4 } }
        resetSchema('boom')
        Schema.Run()
        oxLog = {}
        local res = Mock.callCallback('pf_mdt:officers:list', 1)
        assert_eq(res and res.error, 'no_db')
        assert_eq(#oxLog, 0, 'no query against missing tables')
        resetSchema()
        Schema.Run()
        Mock.callCallback('pf_mdt:officers:list', 1)
        assert_true(#oxLog > 0)
    end)
end)
