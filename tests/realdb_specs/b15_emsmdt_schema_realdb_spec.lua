-- pf-emsmdt schema on a real database (batch 15G): a fresh database gets every table; a second run
-- applies nothing; a batch-14 install (v1 applied, tables made by the old start-up code, older staff
-- columns, an SOP table with the old `procedure` column, data in every table) moves to v2 with no data
-- lost; a database where sql/pf-emsmdt-qb.sql was imported by hand migrates with no error and no data
-- change, and both paths end with the same columns and keys; the patient profile answers on the real
-- database even with the old patient_care_reports table present (its PCR count used a missing column).
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
function GetConvar(_, default) return default end
function GetResourceState() return 'missing' end
promise = promise or { new = function() return { resolve = function(self, v) self.value = v end } end }
Citizen.Await = Citizen.Await or function(p) return p.value end

RealDB.exec('pfm-core/qbcore.sql')
load_resource('pfm-core/server/migrations.lua')
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end
-- oxmysql-shaped: an SQL error is logged and the callback is never called (as oxmysql does)
local sqlErrors = {}
local function ox(kind)
    return function(_, sql, params, cb)
        if Mock.callable(params) then cb, params = params, nil end
        local ok, r = pcall(MySQL[kind].await, sql, params)
        if not ok then sqlErrors[#sqlErrors + 1] = tostring(r) return nil end
        if cb then cb(r) end
        return r
    end
end
Mock.exportsByResource['oxmysql'] = { execute = ox('query'), query = ox('query'), fetch = ox('query'), insert = ox('insert'), update = ox('update'), scalar = ox('scalar'), single = ox('single') }
local threads = {}
CreateThread = function(fn) threads[#threads + 1] = fn end
local function runThreads() local t = threads threads = {} for _, fn in ipairs(t) do fn() end end
SetTimeout = function() end
Wait = function() end

function GetCurrentResourceName() return 'pf-emsmdt' end
Config = nil
load_resource('[pfscripts]/pf-emsmdt/config.lua')
load_resource('[pfscripts]/pf-emsmdt/shared/framework.lua')
load_resource('[pfscripts]/pf-emsmdt/server/schema.lua')
load_resource('[pfscripts]/pf-emsmdt/server/main.lua')
load_resource('[pfscripts]/pf-emsmdt/server/officers.lua')
load_resource('[pfscripts]/pf-emsmdt/server/roster.lua')
load_resource('[pfscripts]/pf-emsmdt/server/sop.lua')
local S = PFEmsSchema
threads = {} -- the schema's start thread runs where a test asks for it

local TABLES = { 'pf_emsmdt_roster_backup' }
for _, t in ipairs(S.TABLES) do TABLES[#TABLES + 1] = t.name end

local function scalar(sql, p) return MySQL.scalar.await(sql, p or {}) end
local function count(sql, p) return tonumber(scalar(sql, p)) or 0 end
local function tableExists(name)
    return count('SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?', { name }) > 0
end
local function versions()
    local out = {}
    for _, r in ipairs(MySQL.query.await("SELECT version, name, UNIX_TIMESTAMP(applied_at) AS at FROM pf_schema_migrations WHERE resource = 'pf-emsmdt' ORDER BY version") or {}) do
        out[#out + 1] = r
    end
    return out
end
-- columns and keys of every EMS MDT table, in a stable order (column position left out: an upgraded
-- install gets added columns at the end)
local function snapshot()
    local parts = {}
    for _, r in ipairs(MySQL.query.await([[SELECT TABLE_NAME t, COLUMN_NAME c, COLUMN_TYPE ty, IS_NULLABLE n, COALESCE(COLUMN_DEFAULT, 'NULL') d, EXTRA e
        FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME LIKE 'pf\_emsmdt\_%' ORDER BY TABLE_NAME, COLUMN_NAME]]) or {}) do
        parts[#parts + 1] = table.concat({ r.t, r.c, r.ty, r.n, tostring(r.d), tostring(r.e) }, '|')
    end
    for _, r in ipairs(MySQL.query.await([[SELECT TABLE_NAME t, INDEX_NAME i, NON_UNIQUE u, GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) cols
        FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME LIKE 'pf\_emsmdt\_%' GROUP BY TABLE_NAME, INDEX_NAME, NON_UNIQUE ORDER BY TABLE_NAME, INDEX_NAME]]) or {}) do
        parts[#parts + 1] = table.concat({ 'key', r.t, r.i, tostring(r.u), r.cols }, '|')
    end
    return table.concat(parts, '\n')
end
local function wipe()
    for _, t in ipairs(TABLES) do MySQL.query.await(('DROP TABLE IF EXISTS `%s`'):format(t)) end
    MySQL.query.await('DROP TABLE IF EXISTS patient_care_reports')
    MySQL.query.await('DROP TABLE IF EXISTS pf_schema_migrations')
    assert_eq(RunMigrations('pf-emsmdt-probe', {}), true) -- creates an empty pf_schema_migrations
end
-- a fresh copy of the schema module (its ready flag starts false, as on a server start)
local function freshSchema()
    PFEmsSchema = nil
    threads = {}
    load_resource('[pfscripts]/pf-emsmdt/server/schema.lua')
    S = PFEmsSchema
end

-- one row in every table, through the columns every layout has
local function seedRows()
    MySQL.insert.await("INSERT INTO pf_emsmdt_patient_notes (citizenId, text, author) VALUES ('PAT1', 'Allergic to penicillin', 'Medic A')")
    MySQL.insert.await("INSERT INTO pf_emsmdt_user_profiles (citizenId, callsign, status, avatarUrl) VALUES ('MED1', 'M-1', 'available', NULL)")
    MySQL.insert.await("INSERT INTO pf_emsmdt_bulletins (title, body, createdByCitizenId, createdByName) VALUES ('Shift', 'Body', 'MED1', 'Medic A')")
    MySQL.insert.await("INSERT INTO pf_emsmdt_roster (callsign, `rank`, officer_name, citizenid, unit_type) VALUES ('M-77', 'Paramedic', 'Medic A', 'MED1', 'Ambulance')")
    MySQL.insert.await("INSERT INTO pf_emsmdt_staff_mgmt_profiles (citizenid, is_fto) VALUES ('MED1', 1)")
    MySQL.insert.await("INSERT INTO pf_emsmdt_staff_discipline (citizenid, type, reason) VALUES ('MED1', 'warning', 'late')")
    MySQL.insert.await("INSERT INTO pf_emsmdt_staff_audit (actor_citizenid, target_citizenid, action) VALUES ('CHIEF', 'MED1', 'hire')")
    MySQL.insert.await("INSERT INTO pf_emsmdt_roster_backup (batch, callsign) VALUES ('b1', 'M-77')")
end
local function rowDigest()
    local parts = {}
    for _, t in ipairs(TABLES) do parts[#parts + 1] = t .. '=' .. count(('SELECT COUNT(*) FROM `%s`'):format(t)) end
    parts[#parts + 1] = scalar("SELECT text FROM pf_emsmdt_patient_notes WHERE citizenId = 'PAT1'")
    parts[#parts + 1] = scalar("SELECT callsign FROM pf_emsmdt_user_profiles WHERE citizenId = 'MED1'")
    parts[#parts + 1] = scalar("SELECT citizenid FROM pf_emsmdt_roster WHERE callsign = 'M-77'")
    parts[#parts + 1] = tostring(scalar("SELECT is_fto FROM pf_emsmdt_staff_mgmt_profiles WHERE citizenid = 'MED1'"))
    parts[#parts + 1] = scalar("SELECT reason FROM pf_emsmdt_staff_discipline WHERE citizenid = 'MED1'")
    return table.concat(parts, ';')
end

local freshShape
BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    sqlErrors = {}
end

describe('pf-emsmdt schema on a fresh database', function()
    it('creates every table and records v1 and v2 under the resource key', function()
        wipe()
        freshSchema()
        runThreads()
        assert_true(S.Ready(), tostring(S.LastError()))
        for _, t in ipairs(TABLES) do assert_true(tableExists(t), t) end
        local v = versions()
        assert_eq(#v, 2)
        assert_eq(tonumber(v[1].version), 1)
        assert_eq(v[1].name, 'roster reset backups')
        assert_eq(tonumber(v[2].version), 2)
        freshShape = snapshot()
        assert_true(freshShape:find('pf_emsmdt_staff_mgmt_profiles|terminated_reason|varchar(255)', 1, true) ~= nil)
    end)

    it('a second run applies nothing and changes nothing; v2 itself can run again', function()
        seedRows()
        local before, digest = versions(), rowDigest()
        freshSchema()
        runThreads()
        assert_true(S.Ready())
        local after = versions()
        assert_eq(#after, 2)
        assert_eq(after[1].at, before[1].at)
        assert_eq(after[2].at, before[2].at)
        S.ApplyV2()
        assert_eq(rowDigest(), digest)
        assert_eq(snapshot(), freshShape)
    end)
end)

describe('a batch-14 install (v1 applied, tables from the old start-up code)', function()
    it('moves to v2 without re-applying v1 or losing data, and gains the older missing columns', function()
        wipe()
        -- v1 as batch 14 applied it
        MySQL.query.await(S.Migrations[1].up[1])
        MySQL.insert.await("INSERT INTO pf_schema_migrations (resource, version, name, applied_at) VALUES ('pf-emsmdt', 1, 'roster reset backups', '2026-01-02 03:04:05')")
        -- the tables as the old code made them; the staff profile and SOP tables in an older layout
        for _, t in ipairs(S.TABLES) do
            if t.name ~= 'pf_emsmdt_staff_mgmt_profiles' and t.name ~= 'pf_emsmdt_sops' then MySQL.query.await(t.sql) end
        end
        MySQL.query.await([[CREATE TABLE `pf_emsmdt_staff_mgmt_profiles` (
            `citizenid` VARCHAR(64) NOT NULL, `hire_date` DATETIME NULL, `probation_until` DATETIME NULL,
            `is_fto` TINYINT(1) NOT NULL DEFAULT 0, `restrictions_json` LONGTEXT NULL, `flags_json` LONGTEXT NULL,
            `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `updated_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (`citizenid`)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
        MySQL.query.await([[CREATE TABLE `pf_emsmdt_sops` (
            `id` INT NOT NULL AUTO_INCREMENT, `title` VARCHAR(128) NOT NULL, `category` VARCHAR(64) NOT NULL,
            `purpose` TEXT NOT NULL, `policy` TEXT NOT NULL, `procedure` TEXT NOT NULL, `notes` TEXT NULL,
            `updated_by` VARCHAR(128) NULL,
            `updated_at` TIMESTAMP NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            `created_at` TIMESTAMP NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`), KEY `idx_category` (`category`), KEY `idx_title` (`title`)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
        seedRows()
        MySQL.insert.await("INSERT INTO pf_emsmdt_sops (title, category, purpose, policy, `procedure`) VALUES ('Old SOP', 'Ops', 'p', 'q', 'Step one')")
        local digest = rowDigest()

        freshSchema()
        runThreads()
        assert_true(S.Ready(), tostring(S.LastError()))
        local v = versions()
        assert_eq(#v, 2)
        assert_eq(v[1].at, MySQL.scalar.await("SELECT UNIX_TIMESTAMP('2026-01-02 03:04:05')"), 'v1 not re-applied')
        assert_eq(tonumber(v[2].version), 2)
        assert_eq(rowDigest(), digest, 'no data lost')
        assert_eq(scalar("SELECT status FROM pf_emsmdt_staff_mgmt_profiles WHERE citizenid = 'MED1'"), 'ACTIVE')
        assert_eq(tonumber(scalar("SELECT `terminated` FROM pf_emsmdt_staff_mgmt_profiles WHERE citizenid = 'MED1'")), 0)
        assert_eq(scalar("SELECT procedure_text FROM pf_emsmdt_sops WHERE title = 'Old SOP'"), 'Step one')
        -- the upgraded install ends with the fresh install's columns and keys
        assert_eq(snapshot(), freshShape)
        -- and the SOP page reads the old row
        Mock.newPlayer(1, 'MED1').PlayerData.job = { name = 'ambulance', onduty = true, grade = { level = 1 } }
        local res = Mock.callCallback('pf_emsmdt:getSOPs', 1, {})
        assert_eq(res.success, true)
        assert_eq(res.data[1]['procedure'], 'Step one')
    end)
end)

describe('a database where sql/pf-emsmdt-qb.sql was imported by hand', function()
    it('migrates with no error and no data change, to the same schema as a fresh install', function()
        wipe()
        RealDB.exec('[pfscripts]/pf-emsmdt/sql/pf-emsmdt-qb.sql')
        assert_eq(snapshot(), freshShape, 'the SQL file matches server/schema.lua')
        seedRows()
        local digest = rowDigest()
        freshSchema()
        runThreads()
        assert_true(S.Ready(), tostring(S.LastError()))
        assert_eq(#versions(), 2)
        assert_eq(rowDigest(), digest)
        assert_eq(snapshot(), freshShape)
        -- importing the file again over a migrated database is harmless too
        RealDB.exec('[pfscripts]/pf-emsmdt/sql/pf-emsmdt-qb.sql')
        assert_eq(rowDigest(), digest)
    end)
end)

describe('start-up work and the patient profile on the real database', function()
    it('roster defaults and SOP seeds run after the schema, once', function()
        wipe()
        freshSchema()
        runThreads()                -- schema
        PFEmsRosterStartup()
        PFEmsSopStartup()
        local roster, sops = count('SELECT COUNT(*) FROM pf_emsmdt_roster'), count('SELECT COUNT(*) FROM pf_emsmdt_sops')
        assert_true(roster > 0, 'roster defaults')
        assert_true(sops > 0, 'SOP seed')
        PFEmsRosterStartup()
        PFEmsSopStartup()
        assert_eq(count('SELECT COUNT(*) FROM pf_emsmdt_roster'), roster)
        assert_eq(count('SELECT COUNT(*) FROM pf_emsmdt_sops'), sops)
        assert_eq(#sqlErrors, 0, table.concat(sqlErrors, ' / '))
    end)

    it('answers with the notes even where the old patient_care_reports table exists', function()
        -- the pf-ambulancejob SQL-file table: its column is citizen_id, the old count asked for citizenid
        MySQL.query.await('CREATE TABLE IF NOT EXISTS patient_care_reports (id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, citizen_id VARCHAR(50) NOT NULL)')
        MySQL.query.await('DELETE FROM players WHERE citizenid = ?', { 'PAT1' })
        MySQL.insert.await([[INSERT INTO players (citizenid, cid, license, name, money, charinfo, job, gang, position, metadata, inventory)
            VALUES ('PAT1', 1, 'license:PAT1', 'PAT1', '{}', ?, '{}', '{}', '{}', ?, '[]')]],
            { json.encode({ firstname = 'Pat', lastname = 'Ient', birthdate = '1990-01-01' }), json.encode({ bloodtype = 'O+' }) })
        MySQL.insert.await("INSERT INTO pf_emsmdt_patient_notes (citizenId, text, author) VALUES ('PAT1', 'Asthma', 'Medic A')")
        Mock.newPlayer(1, 'MED1').PlayerData.job = { name = 'ambulance', onduty = true, grade = { level = 1 } }
        local res = Mock.callCallback('pf_emsmdt:getPatientProfile', 1, { citizenId = 'PAT1' })
        assert_true(res ~= nil, 'answered')
        assert_eq(res.success, true, tostring(res.error))
        assert_eq(res.profile.bloodtype, 'O+')
        assert_eq(res.profile.notes[1].text, 'Asthma')
        assert_eq(#sqlErrors, 0, table.concat(sqlErrors, ' / '))
    end)
end)
