-- pf-emsmdt schema by migrations (batch 15G): one file (server/schema.lua) owns the 'pf-emsmdt' key; v1
-- (roster reset backups, batch 14) keeps its number, name and SQL; v2 creates every table the server
-- code uses; no other server file creates or alters tables; start-up work waits for the schema; the
-- patient profile always answers and no longer counts PCRs by a column that does not exist.
load_resource('tests/lua/fivem_mocks.lua')
function IsDuplicityVersion() return true end
function GetConvar(_, default) return default end
function GetResourceState() return 'started' end
QBCore = QBCoreMock
promise = promise or { new = function() return { resolve = function(self, v) self.value = v end } end }
Citizen = Citizen or {}
Citizen.Await = Citizen.Await or function(p) return p.value end

local DIR = '[pfscripts]/pf-emsmdt/'
local SERVER_FILES = { 'main.lua', 'roster.lua', 'sop.lua', 'officers.lua', 'item_handler.lua', 'devices.lua' }

-- oxmysql recorder; `silent` lists SQL fragments that never call back (oxmysql on an SQL error)
local log, silent = {}, {}
local function respond(sql, cb, value)
    log[#log + 1] = sql
    for _, frag in ipairs(silent) do if sql:find(frag, 1, true) then return end end
    if Mock.callable(cb) then cb(value) end
    return value
end
local function rowsFor(sql, params)
    if sql:find('FROM players WHERE citizenid', 1, true) then
        return { { citizenid = params and params[1], charinfo = json.encode({ firstname = 'Pat', lastname = 'Ient', birthdate = '1990-01-01' }), metadata = '{}' } }
    end
    if sql:find('information_schema', 1, true) then return { { c = 1 } } end -- every table "exists"
    return {}
end
local function q(_, sql, params, cb)
    if Mock.callable(params) then cb, params = params, nil end
    return respond(sql, cb, rowsFor(sql, params))
end
Mock.exportsByResource['oxmysql'] = {
    execute = q, query = q, fetch = q,
    insert = function(_, sql, params, cb) if Mock.callable(params) then cb = params end return respond(sql, cb, 1) end,
    update = function(_, sql, params, cb) if Mock.callable(params) then cb = params end return respond(sql, cb, 1) end,
    scalar = function(_, sql, params, cb) if Mock.callable(params) then cb = params end return respond(sql, cb, 0) end,
}

local runs, runResult = {}, true
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, key, list)
    runs[#runs + 1] = { key = key, list = list }
    if runResult == true then return true end
    return false, runResult
end

local threads = {}
CreateThread = function(fn) threads[#threads + 1] = fn end
local function runThreads() local t = threads threads = {} for _, fn in ipairs(t) do fn() end end
local timers = {}
SetTimeout = function(ms, fn) timers[#timers + 1] = { ms = ms, fn = fn } end
Wait = function() end

function GetCurrentResourceName() return 'pf-emsmdt' end
Config = nil
load_resource(DIR .. 'config.lua')
load_resource(DIR .. 'shared/framework.lua')

local function loadServer()
    PFEmsSchema = nil
    threads, timers, log = {}, {}, {}
    load_resource(DIR .. 'server/schema.lua')
    load_resource(DIR .. 'server/main.lua')
    load_resource(DIR .. 'server/officers.lua')
    load_resource(DIR .. 'server/roster.lua')
    load_resource(DIR .. 'server/sop.lua')
end

local function ran(fragment)
    local n = 0
    for _, sql in ipairs(log) do if sql:find(fragment, 1, true) then n = n + 1 end end
    return n
end

local MEDIC = 1
BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    runs, runResult, silent = {}, true, {}
    local p = Mock.newPlayer(MEDIC, 'MED1')
    p.PlayerData.job = { name = 'ambulance', onduty = true, grade = { level = 1 } }
end

describe('pf-emsmdt schema file', function()
    it('every pf_emsmdt_ table the server code names is created by the schema', function()
        loadServer()
        local created = {}
        for _, t in ipairs(PFEmsSchema.TABLES) do created[t.name] = true end
        created['pf_emsmdt_roster_backup'] = PFEmsSchema.Migrations[1].up[1]:find('`pf_emsmdt_roster_backup`', 1, true) ~= nil
        local seen = 0
        for _, f in ipairs(SERVER_FILES) do
            local src = __readfile(DIR .. 'server/' .. f)
            for name in src:gmatch('pf_emsmdt_[%a_]+') do
                -- event names (pf_emsmdt_dispatch:server:...) are not tables
                if not name:find('pf_emsmdt_dispatch', 1, true) then
                    seen = seen + 1
                    assert_true(created[name] == true, name .. ' (' .. f .. ') is created by server/schema.lua')
                end
            end
        end
        assert_true(seen >= 10, 'table names were found in the server code')
    end)

    it('no other server file creates or alters a table or runs migrations', function()
        for _, f in ipairs(SERVER_FILES) do
            local src = __readfile(DIR .. 'server/' .. f)
            assert_eq(src:find('CREATE TABLE', 1, true), nil, f .. ' has no CREATE TABLE')
            assert_eq(src:find('ALTER TABLE', 1, true), nil, f .. ' has no ALTER TABLE')
            assert_eq(src:find('RunMigrations', 1, true), nil, f .. ' does not run migrations')
        end
    end)

    it('the manifest loads the schema before the other server files', function()
        local m = __readfile(DIR .. 'fxmanifest.lua')
        local s, main = m:find("'server/schema.lua'", 1, true), m:find("'server/main.lua'", 1, true)
        assert_true(s ~= nil and main ~= nil and s < main)
    end)

    it('v1 keeps its number, name and SQL; v2 is a function step; both under the resource key', function()
        loadServer()
        runThreads()
        assert_eq(#runs, 1)
        assert_eq(runs[1].key, 'pf-emsmdt')
        local v1, v2 = PFEmsSchema.Migrations[1], PFEmsSchema.Migrations[2]
        assert_eq(v1.version, 1)
        assert_eq(v1.name, 'roster reset backups')
        assert_eq(#v1.up, 1)
        assert_true(v1.up[1]:find('KEY `idx_emsmdt_roster_backup_batch` (`batch`)', 1, true) ~= nil)
        assert_eq(v2.version, 2)
        assert_true(Mock.callable(v2.up))
        assert_eq(#PFEmsSchema.Migrations, 2)
    end)

    it('v2 creates every table, adds missing columns and renames an old SOP column, all guarded', function()
        loadServer()
        local queries, colExists = {}, {}
        local savedMySQL = MySQL
        MySQL = {
            query = { await = function(sql) queries[#queries + 1] = sql return {} end },
            scalar = { await = function(_, p) return colExists[p[1] .. '.' .. p[2]] and 1 or 0 end },
        }
        colExists['pf_emsmdt_sops.procedure'] = true
        PFEmsSchema.ApplyV2()
        local creates, alters, rename = 0, 0, 0
        for _, sql in ipairs(queries) do
            if sql:find('CREATE TABLE IF NOT EXISTS', 1, true) then creates = creates + 1 end
            if sql:find('ADD COLUMN', 1, true) then alters = alters + 1 end
            if sql:find('CHANGE `procedure` `procedure_text`', 1, true) then rename = rename + 1 end
        end
        assert_eq(creates, 8)
        assert_eq(alters, 5)
        assert_eq(rename, 1)
        -- a second run over an upgraded table adds and renames nothing
        queries = {}
        for _, c in ipairs(PFEmsSchema.COLUMNS) do colExists[c[1] .. '.' .. c[2]] = true end
        colExists['pf_emsmdt_sops.procedure_text'] = true
        PFEmsSchema.ApplyV2()
        for _, sql in ipairs(queries) do assert_eq(sql:find('ALTER TABLE', 1, true), nil, 'rerun alters nothing') end
        MySQL = savedMySQL
    end)
end)

describe('start-up waits for the schema', function()
    it('seeds and legacy copies run only after the schema is applied', function()
        loadServer()
        assert_eq(ran('pf_emsmdt_roster'), 0, 'nothing before the schema')
        assert_eq(ran('pf_emsmdt_sops'), 0)
        runThreads()            -- schema start
        assert_true(PFEmsSchema.Ready())
        runThreads()            -- the queued start-up work
        assert_true(ran('SELECT COUNT(*) FROM pf_emsmdt_roster') > 0, 'roster defaults checked')
        assert_true(ran('SELECT COUNT(*) FROM `pf_emsmdt_sops`') > 0, 'SOP seed checked')
    end)

    it('a failed migration retries, keeps the start-up work waiting, and runs it after a later success', function()
        loadServer()
        runResult = 'db down'
        runThreads()
        assert_eq(#runs, PFEmsSchema.START_ATTEMPTS, 'retried')
        assert_false(PFEmsSchema.Ready())
        assert_eq(PFEmsSchema.LastError(), 'db down')
        runThreads()
        assert_eq(ran('pf_emsmdt_roster'), 0, 'no seed on a missing schema')
        runResult = true
        assert_true(PFEmsSchema.Ensure())
        runThreads()
        assert_true(ran('SELECT COUNT(*) FROM pf_emsmdt_roster') > 0)
    end)

    it('the roster reset refuses while the schema cannot be applied', function()
        loadServer()
        runResult = 'db down'
        runThreads()
        local cmd = Mock.rawCommands['pfemsmdt_roster_reset']
        log = {}
        cmd(0)
        assert_eq(ran('pf_emsmdt_roster_backup'), 0)
        assert_eq(ran('DELETE FROM pf_emsmdt_roster'), 0)
    end)
end)

describe('patient profile', function()
    local function profile() return Mock.callCallback('pf_emsmdt:getPatientProfile', MEDIC, { citizenId = 'PAT1' }) end

    it('answers not_ready before the schema is applied', function()
        loadServer()
        local res = profile()
        assert_eq(res.success, false)
        assert_eq(res.error, 'not_ready')
    end)

    it('answers with the notes and runs no PCR query (the old one used a missing column)', function()
        loadServer()
        runThreads()
        -- the old count against patient_care_reports errored: oxmysql never called back
        silent = { 'patient_care_reports' }
        log = {}
        local res = profile()
        assert_true(res ~= nil, 'answered')
        assert_eq(res.success, true)
        assert_eq(res.profile.name, 'Pat Ient')
        assert_eq(res.profile.pcrCount, nil, 'no made-up PCR count')
        assert_eq(ran('patient_care_reports'), 0)
        assert_eq(ran('pf_emsmdt_patient_notes'), 1)
    end)

    it('a database that never answers ends in a timeout reply, once', function()
        loadServer()
        runThreads()
        silent = { 'FROM players WHERE citizenid' }
        local answers = {}
        Mock.callbacks['pf_emsmdt:getPatientProfile'](MEDIC, function(r) answers[#answers + 1] = r end, { citizenId = 'PAT1' })
        assert_eq(#answers, 0)
        assert_eq(#timers, 1)
        timers[1].fn()
        timers[1].fn()
        assert_eq(#answers, 1)
        assert_eq(answers[1].error, 'timeout')
    end)
end)
