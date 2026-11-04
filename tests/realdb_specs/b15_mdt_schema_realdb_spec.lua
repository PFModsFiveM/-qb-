-- pf-policemdt-DEV schema on the real database (batch 15, unit 15F):
--   * fresh database: v1-v7 apply, every table the server code names exists, every column the code
--     inserts into exists, the default charges/template/cameras equal the SQL files' rows, and a
--     second run (and a rerun of every step) changes nothing;
--   * the SQL file imported by hand (with staff edits): the migrations run without error and no
--     existing value changes; a deleted default is not brought back;
--   * a batch-14 install at v6: v1-v6 are not applied again, the data stays, v7 adds the tables;
--   * older column sets: the old SOP column is renamed, missing columns are added with defaults,
--     snake_case charge money columns are left as they are.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
function GetResourceState() return 'missing' end
promise = promise or { new = function() return { resolve = function(self, v) self.value = v end } end }
Citizen.Await = Citizen.Await or function(p) return p.value end

load_resource('pfm-core/server/migrations.lua')
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end

local KEY = 'pf-policemdt-DEV'
local RES_DIR = '[pfscripts]/pf-policemdt-DEV/'
function GetCurrentResourceName() return KEY end
Config = nil
load_resource(RES_DIR .. 'shared/framework.lua')
load_resource(RES_DIR .. 'config.lua')
load_resource(RES_DIR .. 'server/access.lua')
load_resource(RES_DIR .. 'server/schema.lua')
local Schema = PFMdtSchema

-- ── helpers ────────────────────────────────────────────────────────────────

local function dropAll()
    local rows = MySQL.query.await('SELECT TABLE_NAME AS t FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE()') or {}
    for _, r in ipairs(rows) do MySQL.query.await(('DROP TABLE IF EXISTS `%s`'):format(r.t)) end
end
local function run()
    Schema.state, Schema.lastError = 'idle', nil
    return Schema.Run()
end
local function scalar(sql, p) return tonumber(MySQL.scalar.await(sql, p or {})) end
local function tableExists(t) return scalar('SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?', { t }) == 1 end
local function columnsOf(t)
    local out = {}
    for _, r in ipairs(MySQL.query.await('SELECT COLUMN_NAME AS c FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?', { t }) or {}) do out[r.c] = true end
    return out
end
local function applied()
    local out = {}
    for _, r in ipairs(MySQL.query.await('SELECT version, name, applied_at FROM pf_schema_migrations WHERE resource = ? ORDER BY version', { KEY }) or {}) do
        out[#out + 1] = r
    end
    return out
end
local function mdtTables()
    local out = {}
    for _, r in ipairs(MySQL.query.await("SELECT TABLE_NAME AS t FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME LIKE 'pf\\_mdt\\_%' ORDER BY TABLE_NAME") or {}) do
        out[#out + 1] = r.t
    end
    return out
end
-- every row of every MDT table, as JSON per row, keyed by table (only the columns present now)
local function snapshot()
    local snap = {}
    for _, t in ipairs(mdtTables()) do
        local rows = MySQL.query.await(('SELECT * FROM `%s`'):format(t)) or {}
        snap[t] = rows
    end
    return snap
end
-- the rows of `before` must be unchanged in `after` (columns added since are ignored)
local function assertSameData(before, after)
    for t, rows in pairs(before) do
        local now = after[t]
        assert_true(now ~= nil, t .. ' disappeared')
        assert_eq(#now, #rows, t .. ' row count')
        for i, row in ipairs(rows) do
            for col, v in pairs(row) do
                assert_eq(now[i][col], v, ('%s row %d column %s'):format(t, i, col))
            end
        end
    end
end

-- table names in the server scripts (same exclusions as the mocked spec)
local NOT_TABLES = { pf_mdt_dispatch = true, pf_mdt_evidence_webhook = true, pf_mdt_esx_license_suspensions_expires = true, pf_mdt_fto_reports_legacy = true }
local serverScripts = {}
for f in __readfile(RES_DIR .. 'fxmanifest.lua'):match('server_scripts%s*(%b{})'):gmatch("'(server/[%w_]+%.lua)'") do serverScripts[#serverScripts + 1] = f end
local function codeTables()
    local out, list = {}, {}
    for _, f in ipairs(serverScripts) do
        for name in __readfile(RES_DIR .. f):gmatch('pf_mdt_[%w_]+') do
            if not NOT_TABLES[name] and not out[name] then out[name] = true list[#list + 1] = name end
        end
    end
    return list
end
-- column lists of every INSERT INTO pf_mdt_x (...) in the server scripts
local function codeInserts()
    local out = {}
    for _, f in ipairs(serverScripts) do
        local code = __readfile(RES_DIR .. f)
        for t, cols in code:gmatch('INSERT%s+[IGNORE%s]*INTO%s+`?(pf_mdt_[%w_]+)`?%s*(%b())') do
            out[#out + 1] = { file = f, table = t, cols = cols }
        end
    end
    return out
end

local HAND_SQL = RES_DIR .. 'sql/pf-policemdt-qb.sql'
local HAND_TEMPLATES = RES_DIR .. 'sql/pf-policemdt-templates.sql'

-- ── fresh database ─────────────────────────────────────────────────────────

local seeded = {}

describe('fresh database', function()
    it('applies v1-v7 and creates every table the server code names', function()
        dropAll()
        assert_true(run(), tostring(Schema.lastError))
        local a = applied()
        assert_eq(#a, 7)
        for v = 1, 7 do assert_eq(tonumber(a[v].version), v) end
        assert_eq(a[7].name, 'MDT tables from the SQL files')
        local names = codeTables()
        assert_true(#names >= 30)
        for _, t in ipairs(names) do assert_true(tableExists(t), t .. ' missing on a fresh database') end
        assert_false(tableExists('pf_mdt_fto_reports_legacy'))
        assert_true(columnsOf('pf_mdt_active_jails').released_why)
        assert_true(columnsOf('pf_mdt_sentences').fine_key)
        assert_true(columnsOf('pf_mdt_officer_mgmt_profiles').is_supervisor)
    end)

    it('has every column the server code inserts into', function()
        local checked = 0
        for _, ins in ipairs(codeInserts()) do
            local have = columnsOf(ins.table)
            for col in ins.cols:gsub('[()]', ''):gmatch('[^,]+') do
                col = col:gsub('`', ''):gsub('^%s+', ''):gsub('%s+$', '')
                -- main.lua's other branch for installs whose charges use snake_case money columns
                local snake = ins.table == 'pf_mdt_charges' and (col == 'fine_amount' or col == 'bail_amount' or col == 'jail_time')
                if col:match('^[%w_]+$') and not snake then
                    checked = checked + 1
                    assert_true(have[col], ('%s.%s (INSERT in %s)'):format(ins.table, col, ins.file))
                end
            end
        end
        assert_true(checked > 80, 'checked ' .. checked)
    end)

    it('seeds the default charges, template and cameras', function()
        assert_eq(scalar('SELECT COUNT(*) FROM pf_mdt_charges'), 64)
        assert_eq(scalar("SELECT COUNT(*) FROM pf_mdt_cctv_cameras WHERE camera_key LIKE 'seed%'"), 124)
        assert_eq(scalar('SELECT COUNT(*) FROM pf_mdt_templates'), 1)
        assert_true(scalar("SELECT COUNT(*) FROM pf_mdt_charges WHERE description IS NULL OR description = '' OR description = name") == 0)
        seeded.charges = MySQL.query.await('SELECT code, name, description, fineAmount, bailAmount, prisonTime, category FROM pf_mdt_charges ORDER BY code')
        seeded.cameras = MySQL.query.await('SELECT camera_key, model_hash, x, y, z, heading, location_label, status FROM pf_mdt_cctv_cameras ORDER BY camera_key')
        seeded.templates = MySQL.query.await('SELECT title, body_html, visibility, allowed_grades, allowed_officers, author_cid, author_name FROM pf_mdt_templates')
    end)

    it('a second run applies nothing, and every step can run again', function()
        local before = applied()
        local snap = snapshot()
        assert_true(run())
        local after = applied()
        assert_eq(#after, 7)
        for v = 1, 7 do assert_eq(after[v].applied_at, before[v].applied_at) end
        -- an interrupted version restarts from its first step: rerun them all by hand
        for _, m in ipairs(Schema.Migrations) do
            if type(m.up) == 'function' then m.up() else for _, sql in ipairs(m.up) do MySQL.query.await(sql) end end
        end
        assertSameData(snap, snapshot())
    end)
end)

-- ── the SQL file imported by hand ──────────────────────────────────────────

describe('database with the SQL files imported by hand', function()
    it('the migrations write the same default rows the SQL files do', function()
        dropAll()
        RealDB.exec(HAND_SQL)
        RealDB.exec(HAND_TEMPLATES)
        assert_eq(json.encode(MySQL.query.await('SELECT code, name, description, fineAmount, bailAmount, prisonTime, category FROM pf_mdt_charges ORDER BY code')), json.encode(seeded.charges))
        assert_eq(json.encode(MySQL.query.await('SELECT camera_key, model_hash, x, y, z, heading, location_label, status FROM pf_mdt_cctv_cameras ORDER BY camera_key')), json.encode(seeded.cameras))
        assert_eq(json.encode(MySQL.query.await('SELECT title, body_html, visibility, allowed_grades, allowed_officers, author_cid, author_name FROM pf_mdt_templates')), json.encode(seeded.templates))
    end)

    it('migrates without error and changes no existing value', function()
        -- staff work on top of the import: records, a removed default charge, an edited camera
        MySQL.query.await("INSERT INTO pf_mdt_warrants (warrantId, suspectName, issuedBy, status) VALUES ('W-1', 'John Doe', 'Sgt A', 'active')")
        MySQL.query.await("INSERT INTO pf_mdt_incidents (incidentId, title, involvedCitizens) VALUES ('I-1', 'Robbery', '[\"CID1\"]')")
        MySQL.query.await("INSERT INTO pf_mdt_reports (reportId, type, title, approvalStatus, status) VALUES ('R-1', 'arrest', 'Report', 'approved', 'approved')")
        MySQL.query.await("INSERT INTO pf_mdt_roster (callsign, `rank`, officer_name, citizenid, created_at, updated_at) VALUES ('1A-01', 'Officer', 'Jane', 'CID9', NOW(), NOW())")
        MySQL.query.await("INSERT INTO pf_mdt_officer_mgmt_profiles (citizenid, status, `terminated`) VALUES ('CID9', 'SUSPENDED', 0)")
        MySQL.query.await("INSERT INTO pf_mdt_sentences (citizenId, title, sentenceType, fineAmount) VALUES ('CID1', 'Old sentence', 'fine', 500)")
        MySQL.query.await("INSERT INTO pf_mdt_sops (title, category, purpose, policy, procedure_text) VALUES ('Own SOP', 'Local', 'p', 'q', 'r')")
        MySQL.query.await("DELETE FROM pf_mdt_charges WHERE code = 'PC-187'")
        MySQL.query.await("UPDATE pf_mdt_charges SET fineAmount = 1234 WHERE code = 'PC-191'")
        MySQL.query.await("UPDATE pf_mdt_cctv_cameras SET location_label = 'Our label', status = 'OFFLINE' WHERE camera_key = 'seed_0001'")
        local before = snapshot()
        assert_true(run(), tostring(Schema.lastError))
        assert_eq(#applied(), 7)
        local after = snapshot()
        assertSameData(before, after)
        assert_eq(scalar("SELECT COUNT(*) FROM pf_mdt_charges WHERE code = 'PC-187'"), 0, 'a deleted default stays deleted')
        -- what the import lacked is there now
        assert_true(tableExists('pf_mdt_active_jails'))
        assert_true(tableExists('pf_mdt_esx_license_suspensions'))
        assert_true(columnsOf('pf_mdt_officer_mgmt_profiles').is_supervisor)
        assert_eq(MySQL.scalar.await("SELECT status FROM pf_mdt_sentences WHERE title = 'Old sentence'"), 'done')
        -- and a second start applies nothing
        assert_true(run())
        assertSameData(after, snapshot())
    end)
end)

-- ── a batch-14 install at v6 ───────────────────────────────────────────────

describe('database at v6 (batch 14)', function()
    it('keeps v1-v6 and their data, applies only v7', function()
        dropAll()
        local v16 = {}
        for i = 1, 6 do v16[i] = Schema.Migrations[i] end
        assert_eq(RunMigrations(KEY, v16), true)
        MySQL.query.await("INSERT INTO pf_mdt_active_jails (citizenid, remaining_seconds, total_seconds, bail_amount, released_why) VALUES ('CID1', 300, 600, 50, NULL)")
        MySQL.query.await("INSERT INTO pf_mdt_sentences (citizenId, title, sentenceType, fineAmount, status, fine_key) VALUES ('CID1', 'S', 'fine', 100, 'payment_pending', 'pf-policemdt:fine:1')")
        MySQL.query.await("INSERT INTO pf_mdt_roster_backup (batch, callsign) VALUES ('b1', '1A-01')")
        local before = applied()
        assert_eq(#before, 6)
        -- proof that v6 is not applied again: re-applying it would bring this column back
        MySQL.query.await('ALTER TABLE pf_mdt_active_jails DROP COLUMN released_why')
        local snap = snapshot()
        assert_true(run(), tostring(Schema.lastError))
        local after = applied()
        assert_eq(#after, 7)
        for v = 1, 6 do assert_eq(after[v].applied_at, before[v].applied_at, 'v' .. v) end
        assert_false(columnsOf('pf_mdt_active_jails').released_why, 'v6 ran again')
        assertSameData(snap, snapshot())
        for _, t in ipairs(codeTables()) do assert_true(tableExists(t), t) end
        assert_eq(scalar('SELECT COUNT(*) FROM pf_mdt_charges'), 64)
    end)
end)

-- ── older column sets ──────────────────────────────────────────────────────

describe('tables from older releases', function()
    it('renames the SOP column, adds missing columns with defaults, leaves snake_case money alone', function()
        dropAll()
        MySQL.query.await([[CREATE TABLE pf_mdt_sops (id INT NOT NULL AUTO_INCREMENT, title VARCHAR(128) NOT NULL, category VARCHAR(64) NOT NULL,
            purpose TEXT NOT NULL, policy TEXT NOT NULL, `procedure` TEXT NOT NULL, notes TEXT NULL, updated_by VARCHAR(128) NULL,
            updated_at DATETIME NULL, created_at DATETIME NULL, PRIMARY KEY (id)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
        MySQL.query.await("INSERT INTO pf_mdt_sops (title, category, purpose, policy, `procedure`) VALUES ('Old', 'C', 'p', 'q', '1) step')")
        -- as server/officers.lua first created it (no termination columns, no supervisor flag)
        MySQL.query.await([[CREATE TABLE pf_mdt_officer_mgmt_profiles (citizenid VARCHAR(64) NOT NULL, hire_date DATETIME NULL,
            probation_until DATETIME NULL, is_fto TINYINT(1) NOT NULL DEFAULT 0, restrictions_json LONGTEXT NULL, flags_json LONGTEXT NULL,
            created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (citizenid)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
        MySQL.query.await("INSERT INTO pf_mdt_officer_mgmt_profiles (citizenid, is_fto) VALUES ('CID9', 1)")
        MySQL.query.await([[CREATE TABLE pf_mdt_reports (id INT NOT NULL AUTO_INCREMENT, reportId VARCHAR(16) NOT NULL, type VARCHAR(64) NOT NULL,
            title VARCHAR(255) NOT NULL, narrative LONGTEXT NULL, approvalStatus VARCHAR(16) NOT NULL DEFAULT 'pending',
            createdAt DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY (id)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
        MySQL.query.await("INSERT INTO pf_mdt_reports (reportId, type, title, approvalStatus) VALUES ('R-1', 'a', 'A', 'approved'), ('R-2', 'a', 'B', 'pending')")
        MySQL.query.await([[CREATE TABLE pf_mdt_charges (id INT NOT NULL AUTO_INCREMENT, code VARCHAR(16) NOT NULL UNIQUE, name VARCHAR(128) NOT NULL,
            fine_amount INT NOT NULL DEFAULT 0, bail_amount INT NOT NULL DEFAULT 0, jail_time INT NOT NULL DEFAULT 0, category VARCHAR(64) NULL,
            PRIMARY KEY (id)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
        MySQL.query.await("INSERT INTO pf_mdt_charges (code, name, fine_amount, bail_amount, jail_time) VALUES ('X1', 'Old charge', 700, 0, 5)")
        MySQL.query.await([[CREATE TABLE pf_mdt_weapons_registry (id INT NOT NULL AUTO_INCREMENT, serial VARCHAR(64) NOT NULL, weapon VARCHAR(64) NOT NULL,
            ownerCitizenId VARCHAR(64) NOT NULL, PRIMARY KEY (id), UNIQUE KEY uniq_serial (serial)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
        MySQL.query.await("INSERT INTO pf_mdt_weapons_registry (serial, weapon, ownerCitizenId) VALUES ('S1', 'pistol', 'CID1')")
        local snap = snapshot()
        snap.pf_mdt_sops = nil -- its column is renamed below; checked by hand

        assert_true(run(), tostring(Schema.lastError))
        assertSameData(snap, snapshot())
        local sop = MySQL.single.await("SELECT * FROM pf_mdt_sops WHERE title = 'Old'")
        assert_eq(sop.procedure_text, '1) step')
        assert_eq(sop['procedure'], nil)
        local prof = MySQL.single.await("SELECT * FROM pf_mdt_officer_mgmt_profiles WHERE citizenid = 'CID9'")
        assert_eq(prof.status, 'ACTIVE')
        assert_eq(tonumber(prof.terminated), 0)
        assert_eq(tonumber(prof.is_supervisor), 0)
        assert_eq(tonumber(prof.is_fto), 1)
        assert_eq(scalar("SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'pf_mdt_officer_mgmt_profiles' AND INDEX_NAME = 'idx_terminated_status'") > 0, true)
        assert_eq(MySQL.scalar.await("SELECT status FROM pf_mdt_reports WHERE reportId = 'R-1'"), 'approved')
        assert_eq(MySQL.scalar.await("SELECT status FROM pf_mdt_reports WHERE reportId = 'R-2'"), 'pending')
        assert_eq(MySQL.scalar.await("SELECT officer FROM pf_mdt_reports WHERE reportId = 'R-1'"), '')
        local charges = columnsOf('pf_mdt_charges')
        assert_false(charges.fineAmount, 'camelCase money columns would hide the old values')
        assert_true(charges.description)
        assert_eq(scalar('SELECT COUNT(*) FROM pf_mdt_charges'), 1, 'a penal code in use is not seeded over')
        assert_eq(scalar("SELECT stolen_status FROM pf_mdt_weapons_registry WHERE serial = 'S1'"), 0)
        -- rerun of the step on the upgraded tables
        Schema.ApplyV7()
        assert_eq(MySQL.scalar.await("SELECT status FROM pf_mdt_reports WHERE reportId = 'R-2'"), 'pending')
    end)
end)
