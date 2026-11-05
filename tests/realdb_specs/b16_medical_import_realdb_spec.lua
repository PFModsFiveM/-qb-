-- pf-ambulancejob migration v4 (batch 16B) on a real database: an installed server at v3 with
-- legacy player_injuries rows gets the anomaly index and the one-time import (open rows become
-- pf_med_injuries rows with legacy_id, deleted rows stay out, nothing bleeds); a second run imports
-- nothing; the injuries load into the engine at login; the legacy scan shows them once.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
function GetResourceState() return 'started' end
function GetCurrentResourceName() return 'pf-ambulancejob' end

load_resource('pfm-core/server/migrations.lua')
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end

load_resource('[pfscripts]/pf-ambulancejob/config.lua')
load_resource('[pfscripts]/pf-ambulancejob/config_medical.lua')
load_resource('[pfscripts]/pf-ambulancejob/shared/framework.lua')
for _, f in ipairs({ 'anatomy', 'injuries', 'physiology_model', 'effects_model', 'mechanisms' }) do
    load_resource('[pfscripts]/pf-ambulancejob/shared/medical/' .. f .. '.lua')
end

local function restart()
    for _, f in ipairs({ 'schema', 'store', 'engine', 'effects', 'api', 'ingest', 'legacy_import' }) do
        load_resource('[pfscripts]/pf-ambulancejob/server/medical/' .. f .. '.lua')
    end
    load_resource('[pfscripts]/pf-ambulancejob/server/injury_database.lua')
    return PFMed.Schema.Start()
end
local function count(sql, params) return tonumber(MySQL.scalar.await(sql, params)) or 0 end
local function versions()
    local out = {}
    for _, r in ipairs(MySQL.query.await("SELECT version FROM pf_schema_migrations WHERE resource = 'pf-ambulancejob' ORDER BY version")) do out[#out + 1] = tonumber(r.version) end
    return table.concat(out, ',')
end

describe('migration v4: legacy injury import', function()
    it('imports open legacy rows once, with legacy_id, no bleeding, deleted rows left out', function()
        -- a fresh database each run (realdb/run.js)
        -- the batch-15 server: v1-v3, and rows the old client self-report wrote
        load_resource('[pfscripts]/pf-ambulancejob/server/medical/schema.lua')
        assert_true(RunMigrations('pf-ambulancejob', { PFMed.Schema.Migrations[1], PFMed.Schema.Migrations[2], PFMed.Schema.Migrations[3] }))
        assert_eq(versions(), '1,2,3')
        local ins = "INSERT INTO player_injuries (citizen_id, injury_type, severity, body_zone, weapon, created_at, deleted_at) VALUES (?, ?, ?, ?, ?, FROM_UNIXTIME(?), ?)"
        MySQL.insert.await(ins, { 'IMP1', 'gunshot_wound', 'critical', 'torso', 'Pistol', 1690000000, nil })
        MySQL.insert.await(ins, { 'IMP1', 'fracture', 'severe', 'left_leg', 'Fall', 1690000100, nil })
        MySQL.insert.await(ins, { 'IMP1', 'blast_injury', 'moderate', 'right_arm', 'Grenade', 1690000200, nil })
        MySQL.insert.await(ins, { 'IMP1', 'burn', 'minor', 'head', 'Fire', 1690000300, '2023-07-22 10:00:00' })   -- deleted: not imported
        MySQL.insert.await(ins, { 'bad cid!', 'laceration', 'minor', 'torso', 'Knife', 1690000400, nil })       -- not a citizen id
        local legacyRows = count('SELECT COUNT(*) FROM player_injuries')

        assert_true(restart())
        assert_eq(versions(), '1,2,3,4')
        assert_eq(count("SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'pf_med_events' AND INDEX_NAME = 'idx_med_ev_cid_action'"), 3, 'three-column anomaly index')
        assert_eq(count("SELECT COUNT(*) FROM pf_med_injuries WHERE legacy_id IS NOT NULL"), 3)
        assert_eq(count("SELECT COUNT(*) FROM pf_med_injuries WHERE citizenid = 'IMP1'"), 4, 'the blast also left a bruise row')
        assert_eq(count("SELECT COUNT(*) FROM pf_med_injuries WHERE mechanism <> 'legacy' OR bleed_ml_min <> 0 OR stage <> 'injured'"), 0)
        local gsw = MySQL.single.await("SELECT * FROM pf_med_injuries WHERE type = 'gunshot'")
        assert_eq(tonumber(gsw.severity), 5)
        assert_eq(gsw.region, 'chest_l')
        assert_eq(tonumber(gsw.created_at), 1690000000)
        local fx = MySQL.single.await("SELECT * FROM pf_med_injuries WHERE type = 'fracture'")
        assert_eq(fx.structure, 'femur_l')
        assert_eq(tonumber(fx.severity), 4)
        -- the verification query of PF_DATABASE_MIGRATIONS.md section 13 (minus the row that cannot be mapped)
        assert_eq(count('SELECT COUNT(*) FROM player_injuries p LEFT JOIN pf_med_injuries m ON m.legacy_id = p.id WHERE p.deleted_at IS NULL AND m.id IS NULL'), 1)
        assert_eq(count('SELECT COUNT(*) FROM player_injuries'), legacyRows, 'the legacy table is left as history')

        -- once: a second run (and a rerun of the step) imports nothing
        local again = PFMed.LegacyImport.Run()
        assert_eq(again.inserted, 0)
        assert_true(RunMigrations('pf-ambulancejob', PFMed.Schema.Migrations))
        assert_eq(count("SELECT COUNT(*) FROM pf_med_injuries WHERE citizenid = 'IMP1'"), 4)

        -- the engine loads them at login; the legacy scan shows each injury once
        Mock.players = {}
        local p = Mock.newPlayer(1, 'IMP1')
        Mock.fireEvent('QBCore:Server:PlayerLoaded', nil, p)
        local pat = PFMed.Store.Peek('IMP1')
        local n = 0
        for _ in pairs(pat.injuries) do n = n + 1 end
        assert_eq(n, 4)
        assert_eq(pat.consciousness, 'alert', 'an old record starts no acute threat')
        assert_eq(#GetCitizenInjuries('IMP1'), 4)
        Mock.fireEvent('playerDropped', 1)
    end)

    it('a row written to the legacy table after the import is listed and removed as before', function()
        assert_true(restart())
        MySQL.insert.await("INSERT INTO player_injuries (citizen_id, injury_type, severity, body_zone) VALUES ('IMP2', 'laceration', 'minor', 'left_arm')")
        local list = GetCitizenInjuries('IMP2')
        assert_eq(#list, 1)
        assert_eq(list[1].source, 'legacy')
        assert_eq(RemoveTreatedInjuries('IMP2', { laceration = true }, 'severe'), 1)
        assert_eq(count("SELECT COUNT(*) FROM player_injuries WHERE citizen_id = 'IMP2'"), 0)
    end)
end)
