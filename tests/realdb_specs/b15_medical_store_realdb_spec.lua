-- pf-ambulancejob medical store (batch 15A) on a real database: migrations v1 (moved unchanged) + v2
-- + v3 on a fresh database and on one that already has v1, a rerun that applies nothing; save,
-- advance the clock, reload (offline catch-up from absolute timestamps); the multi-row write-behind;
-- idempotency keys held by the unique column; character delete; retention; the diagnosis layers.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
function GetResourceState() return 'started' end
function GetCurrentResourceName() return 'pf-ambulancejob' end

load_resource('pfm-core/server/migrations.lua')
-- the schema runs through exports['pfm-core']:RunMigrations (function steps cross as funcrefs)
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end

load_resource('[pfscripts]/pf-ambulancejob/config.lua')
load_resource('[pfscripts]/pf-ambulancejob/config_medical.lua')
load_resource('[pfscripts]/pf-ambulancejob/shared/framework.lua')
for _, f in ipairs({ 'anatomy', 'injuries', 'physiology_model', 'effects_model' }) do
    load_resource('[pfscripts]/pf-ambulancejob/shared/medical/' .. f .. '.lua')
end
load_resource('[pfscripts]/pf-ambulancejob/server/injury_database.lua')

-- (re)loads the server modules, as a resource restart does: empty cache, same database
local function restart()
    for _, f in ipairs({ 'schema', 'store', 'engine', 'effects', 'api' }) do
        load_resource('[pfscripts]/pf-ambulancejob/server/medical/' .. f .. '.lua')
    end
    PFMed.Engine.Random = function() return 0.5 end
    Mock.exportsByResource['pf-ambulancejob'] = Mock.exportsByResource['__self']
    return PFMed.Schema.Start()
end

local function versions()
    local rows = MySQL.query.await("SELECT version, name FROM pf_schema_migrations WHERE resource = 'pf-ambulancejob' ORDER BY version")
    local out = {}
    for _, r in ipairs(rows) do out[#out + 1] = tonumber(r.version) end
    return table.concat(out, ','), rows
end
local function tableExists(name)
    return tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?', { name })) == 1
end
local ALL_TABLES = { 'pf_med_patients', 'pf_med_injuries', 'pf_med_events', 'pf_med_findings', 'pf_med_diagnoses',
    'player_treatment_log', 'player_injuries', 'player_health_snapshot' }

local function online(src, cid)
    local p = Mock.newPlayer(src, cid)
    Mock.fireEvent('QBCore:Server:PlayerLoaded', nil, p)
    return p
end
local function tick(seconds)
    for _ = 1, math.floor(seconds / 5) do
        Mock.clock = Mock.clock + 5
        PFMed.Engine.Tick(os.time())
    end
end
local function count(sql, params) return tonumber(MySQL.scalar.await(sql, params)) or 0 end

describe('migrations', function()
    it('v1, v2 and v3 apply on a fresh database; a second run applies nothing', function()
        assert_true(restart())
        local list, rows = versions()
        assert_eq(list, '1,2,3')
        assert_eq(rows[1].name, 'injury records, treatment log, health snapshots', 'v1 kept its name')
        for _, t in ipairs(ALL_TABLES) do assert_true(tableExists(t), t) end
        assert_true(RunMigrations('pf-ambulancejob', PFMed.Schema.Migrations))
        assert_eq((versions()), '1,2,3')
        local uniques = MySQL.query.await("SELECT INDEX_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'pf_med_injuries' AND NON_UNIQUE = 0")
        local names = {}
        for _, r in ipairs(uniques) do names[r.INDEX_NAME] = true end
        assert_true(names.uq_med_inj_key and names.uq_med_inj_legacy)
    end)

    it('an installed server that already has v1 gets only v2 and v3, its legacy rows untouched', function()
        for _, t in ipairs(ALL_TABLES) do MySQL.query.await('DROP TABLE IF EXISTS `' .. t .. '`') end
        MySQL.query.await("DELETE FROM pf_schema_migrations WHERE resource = 'pf-ambulancejob'")
        -- the old server: only v1, applied as injury_database.lua used to (same key, same step)
        assert_true(RunMigrations('pf-ambulancejob', { PFMed.Schema.Migrations[1] }))
        assert_eq((versions()), '1')
        MySQL.insert.await("INSERT INTO player_injuries (citizen_id, injury_type, severity, body_zone) VALUES ('OLD1', 'laceration', 'minor', 'left_arm')")
        assert_true(restart())
        assert_eq((versions()), '1,2,3')
        assert_eq(count("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = 'pf-ambulancejob' AND version = 1"), 1)
        assert_eq(count("SELECT COUNT(*) FROM player_injuries WHERE citizen_id = 'OLD1'"), 1)
        assert_true(tableExists('pf_med_patients') and tableExists('pf_med_events'))
    end)

    it('the legacy InjuryDB entry point still works through the schema module', function()
        assert_true(restart())
        assert_true(InjuryDB.Start())
        assert_true(AddInjury('LEG1', { type = 'burn', severity = 'minor', zone = 'torso', health = 90, weapon = 'fire' }) ~= nil)
        assert_eq(#GetCitizenInjuries('LEG1'), 1)
    end)
end)

describe('persistence', function()
    it('save, advance the clock, reload: offline catch-up from absolute timestamps', function()
        assert_true(restart())
        Mock.players = {}
        online(1, 'SAVE1'); online(11, 'SAVE2')
        local E = PFMed.Engine
        assert_true(E.AddToxin('SAVE1', 'ethanol', 0.2))
        local inj = E.AddInjury('SAVE1', { mechanism = 'edged', type = 'laceration', subtype = 'deep', region = 'forearm_l', severity = 2 }, { key = 'save-cut' })
        assert_true(inj and inj.id > 0)
        -- an arterial wound does not clot: offline it bleeds for the capped 120 s only
        local art = E.AddInjury('SAVE2', { mechanism = 'edged', type = 'laceration', subtype = 'arterial', structure = 'brachial_l', severity = 1 }, {})
        assert_eq(art.bleed_ml_min, 40)
        tick(60)
        local before = PFMed.Store.Peek('SAVE1')
        local bloodAtDrop = before.blood_ml
        local arterialAtDrop = PFMed.Store.Peek('SAVE2').blood_ml
        assert_near(arterialAtDrop, 5000 - 40, 0.5)
        Mock.fireEvent('playerDropped', 11)
        Mock.fireEvent('playerDropped', 1)
        assert_eq(PFMed.Store.Peek('SAVE1'), nil)
        local row = MySQL.single.await("SELECT * FROM pf_med_patients WHERE citizenid = 'SAVE1'")
        assert_true(row ~= nil)
        assert_near(tonumber(row.blood_ml), bloodAtDrop, 1)
        assert_eq(tonumber(row.last_tick_at), os.time())
        local stored = MySQL.single.await('SELECT * FROM pf_med_injuries WHERE id = ?', { inj.id })
        assert_eq(stored.idem_key, 'save-cut')
        assert_true(tonumber(stored.bleed_ml_min) < 5 and tonumber(stored.bleed_ml_min) > 4, 'clotted a little while online')

        Mock.clock = Mock.clock + 7200   -- two hours offline
        assert_true(restart())
        online(1, 'SAVE1')
        local p = PFMed.Store.Peek('SAVE1')
        assert_near(p.toxins.ethanol, 0.2 - 0.015 * (7200 + 60) / 3600, 0.002)
        assert_eq(p.injuries[inj.id].bleed_ml_min, 0, 'the wound clotted while offline')
        assert_true(p.blood_ml > bloodAtDrop - 10 and p.blood_ml <= bloodAtDrop + 0.5 * 120, 'a few ml lost, then regeneration')
        assert_eq(p.injuries[inj.id].stage, 'injured')
        online(11, 'SAVE2')
        assert_near(PFMed.Store.Peek('SAVE2').blood_ml, arterialAtDrop - 40 * 120 / 60, 0.5, 'two hours offline cost 120 s of bleeding')
        Mock.fireEvent('playerDropped', 1)
        Mock.fireEvent('playerDropped', 11)
    end)

    it('an arrest that runs out while offline is death on reload', function()
        assert_true(restart())
        Mock.players = {}
        online(2, 'ARR1')
        local p = PFMed.Store.Peek('ARR1')
        p.consciousness, p.arrest_since, p.down_since = 'arrest', os.time(), os.time()
        PFMed.Store.MarkDirty('ARR1')
        Mock.fireEvent('playerDropped', 2)
        assert_eq(MySQL.scalar.await("SELECT consciousness FROM pf_med_patients WHERE citizenid = 'ARR1'"), 'arrest')
        Mock.clock = Mock.clock + 400
        assert_true(restart())
        online(2, 'ARR1')
        assert_eq(PFMed.Store.Peek('ARR1').consciousness, 'dead')
        PFMed.Store.Flush()
        local row = MySQL.single.await("SELECT consciousness, dead_at, can_respawn_at FROM pf_med_patients WHERE citizenid = 'ARR1'")
        assert_eq(row.consciousness, 'dead')
        assert_eq(tonumber(row.can_respawn_at), tonumber(row.dead_at) + 300)
    end)

    it('a held down state is stored (hold_until) and survives a restart and relog', function()
        assert_true(restart())
        Mock.players = {}
        online(12, 'HOLD1')
        assert_true(PFMed.Engine.SetConsciousness('HOLD1', 'unconscious', 'report', 'gta_health', { holdSeconds = 600 }))
        Mock.fireEvent('playerDropped', 12)
        local held = tonumber(MySQL.scalar.await("SELECT hold_until FROM pf_med_patients WHERE citizenid = 'HOLD1'"))
        assert_eq(held, os.time() + 600)
        Mock.clock = Mock.clock + 60
        assert_true(restart())
        online(12, 'HOLD1')
        tick(60)
        assert_eq(PFMed.Store.Peek('HOLD1').consciousness, 'unconscious', 'still held after the relog')
        Mock.fireEvent('playerDropped', 12)
    end)

    it('the write-behind writes many patients and their injuries in one statement each', function()
        assert_true(restart())
        Mock.players = {}
        online(3, 'WB1'); online(4, 'WB2')
        local E = PFMed.Engine
        local a = E.AddInjury('WB1', { mechanism = 'firearm', type = 'gunshot', subtype = 'penetrating', structure = 'femur_l', severity = 3 }, {})
        E.AddInjury('WB2', { mechanism = 'blunt', type = 'bruising', region = 'abdomen', severity = 2 }, {})
        E.UpdateInjury('WB1', a.id, { treatments = { tourniquet = os.time() } })
        local statements = 0
        local q = MySQL.query.await
        MySQL.query.await = function(sql, params)
            if sql:find('pf_med_patients', 1, true) and sql:find('ON DUPLICATE KEY', 1, true) then statements = statements + 1 end
            return q(sql, params)
        end
        assert_true(PFMed.Store.Flush())
        MySQL.query.await = q
        assert_eq(statements, 1)
        assert_eq(count("SELECT COUNT(*) FROM pf_med_patients WHERE citizenid IN ('WB1', 'WB2')"), 2)
        local tr = MySQL.scalar.await('SELECT treatments FROM pf_med_injuries WHERE id = ?', { a.id })
        assert_true(json.decode(tr).tourniquet ~= nil)
        assert_true(count("SELECT COUNT(*) FROM pf_med_events WHERE citizenid = 'WB1' AND action = 'injury'") == 1)
        assert_true(count("SELECT COUNT(*) FROM pf_med_events WHERE citizenid = 'WB1' AND action = 'injury_update'") == 1)
        -- the stored rows load back with their JSON
        Mock.fireEvent('playerDropped', 3)
        online(3, 'WB1')
        assert_true(PFMed.Store.Peek('WB1').injuries[a.id].treatments.tourniquet ~= nil)
        assert_eq(type(PFMed.Store.Peek('WB1').injuries[a.id].attrs._fp), 'string', 'attrs JSON round trip')
    end)

    it('idempotency keys hold in the database: a repeat after a restart is a duplicate', function()
        assert_true(restart())
        Mock.players = {}
        online(5, 'KEY1')
        local spec = { mechanism = 'blunt', type = 'bruising', region = 'chest_r', severity = 2 }
        local first = PFMed.Engine.AddInjury('KEY1', spec, { key = 'pfm-prison:fight:77' })
        Mock.fireEvent('playerDropped', 5)
        assert_true(restart())
        online(5, 'KEY1')
        local again, _, dup = PFMed.Engine.AddInjury('KEY1', spec, { key = 'pfm-prison:fight:77' })
        assert_true(dup); assert_eq(again.id, first.id)
        local _, code = PFMed.Engine.AddInjury('KEY1', { mechanism = 'blunt', type = 'bruising', region = 'head', severity = 2 }, { key = 'pfm-prison:fight:77' })
        assert_eq(code, 'key_reused')
        assert_eq(count("SELECT COUNT(*) FROM pf_med_injuries WHERE idem_key = 'pfm-prison:fight:77'"), 1)
        local _, err = PFMed.Store.InsertInjury(PFMed.Store.Peek('KEY1'), { type = 'bruising', severity = 1, stage = 'injured', mechanism = 'blunt',
            idem_key = 'pfm-prison:fight:77', created_at = os.time(), attrs = {}, treatments = {} })
        assert_eq(err, 'duplicate', 'the unique column refuses a second row')
    end)

    it('GetPatientSummary reads an offline citizen from the database', function()
        assert_true(restart())
        local r
        Mock.invokingResource = 'pf-justice'
        r = exports['pf-ambulancejob']:GetPatientSummary('ARR1')
        Mock.invokingResource = nil
        assert_true(r.ok); assert_false(r.online); assert_eq(r.consciousness, 'dead'); assert_true(r.down)
        assert_eq(r.vitals, nil)
    end)
end)

describe('character delete and retention', function()
    it('a deleted character loses its pf_med_* and legacy rows; others keep theirs', function()
        assert_true(restart())
        Mock.players = {}
        online(6, 'DEL1'); online(7, 'KEEP1')
        local E = PFMed.Engine
        local inj = E.AddInjury('DEL1', { mechanism = 'blunt', type = 'bruising', region = 'abdomen', severity = 1 }, {})
        E.AddInjury('KEEP1', { mechanism = 'blunt', type = 'bruising', region = 'abdomen', severity = 1 }, {})
        assert_true(PFMed.Store.AddFinding('DEL1', { injuryId = inj.id, modality = 'look', sign = 'bruise', certainty = 'observed' }))
        assert_true(PFMed.Store.SetDiagnosis('DEL1', { injuryType = 'bruising', status = 'suspected', source = 'provider' }))
        AddInjury('DEL1', { type = 'burn', severity = 'minor', zone = 'torso', health = 90, weapon = 'fire' })
        local legacyId = MySQL.scalar.await("SELECT id FROM player_injuries WHERE citizen_id = 'DEL1'")
        MySQL.insert.await("INSERT INTO player_treatment_log (citizen_id, treatment_type, treated_by, injury_id) VALUES ('DEL1', 'bandage', 'X', ?)", { legacyId })
        PFMed.Store.Flush()
        Mock.fireEvent('playerDropped', 6)
        Mock.fireEvent('pfm-core:server:characterDeleted', nil, 'DEL1')
        for _, t in ipairs({ 'pf_med_patients', 'pf_med_injuries', 'pf_med_events', 'pf_med_findings', 'pf_med_diagnoses' }) do
            assert_eq(count('SELECT COUNT(*) FROM `' .. t .. "` WHERE citizenid = 'DEL1'"), 0, t)
        end
        assert_eq(count("SELECT COUNT(*) FROM player_injuries WHERE citizen_id = 'DEL1'"), 0)
        assert_eq(count("SELECT COUNT(*) FROM player_treatment_log WHERE citizen_id = 'DEL1'"), 0)
        assert_eq(count("SELECT COUNT(*) FROM pf_med_injuries WHERE citizenid = 'KEEP1'"), 1)
        assert_eq(count("SELECT COUNT(*) FROM pf_med_patients WHERE citizenid = 'KEEP1'"), 1)
    end)

    it('the sweep removes old recovered injuries and old events in batches, keeps the rest', function()
        assert_true(restart())
        local t = os.time()
        local old = t - 61 * 86400
        for i = 1, 3 do
            MySQL.insert.await("INSERT INTO pf_med_injuries (citizenid, type, severity, stage, mechanism, created_at, recovered_at) VALUES ('SW1', 'bruising', 1, 'recovered', 'blunt', ?, ?)", { old, old })
        end
        MySQL.insert.await("INSERT INTO pf_med_injuries (citizenid, type, severity, stage, mechanism, created_at, recovered_at) VALUES ('SW1', 'bruising', 1, 'recovered', 'blunt', ?, ?)", { t, t })
        MySQL.insert.await("INSERT INTO pf_med_injuries (citizenid, type, severity, stage, mechanism, created_at) VALUES ('SW1', 'fracture', 3, 'injured', 'fall', ?)", { old })
        MySQL.insert.await("INSERT INTO pf_med_events (citizenid, action, at) VALUES ('SW1', 'injury', ?)", { t - 181 * 86400 })
        MySQL.insert.await("INSERT INTO pf_med_events (citizenid, action, at) VALUES ('SW1', 'injury', ?)", { t })
        Config.Medical.SweepBatch = 2
        local res = PFMed.Store.Sweep(t)
        Config.Medical.SweepBatch = 500
        assert_eq(res.injuries, 3)
        assert_eq(res.events, 1)
        assert_eq(count("SELECT COUNT(*) FROM pf_med_injuries WHERE citizenid = 'SW1'"), 2, 'recent recovered + open old injury stay')
        assert_eq(count("SELECT COUNT(*) FROM pf_med_events WHERE citizenid = 'SW1'"), 1)
    end)
end)

describe('diagnosis layers', function()
    it('findings and diagnoses are their own rows; an injury id must belong to the citizen', function()
        assert_true(restart())
        Mock.players = {}
        online(8, 'DX1'); online(9, 'DX2')
        local mine = PFMed.Engine.AddInjury('DX1', { mechanism = 'fall', type = 'fracture', subtype = 'closed', structure = 'tibia_l', severity = 3 }, {})
        local theirs = PFMed.Engine.AddInjury('DX2', { mechanism = 'fall', type = 'fracture', subtype = 'closed', structure = 'tibia_r', severity = 3 }, {})
        Mock.fireEvent('playerDropped', 9)
        local fid = PFMed.Store.AddFinding('DX1', { injuryId = mine.id, modality = 'palpate', region = 'lower_leg_l', sign = 'crepitus', certainty = 'suspected', byCid = 'DX2', byTier = 2 })
        assert_true(fid ~= nil)
        local _, err = PFMed.Store.AddFinding('DX1', { injuryId = theirs.id, modality = 'look', sign = 'deformity', certainty = 'observed' })
        assert_eq(err, 'not_found', 'checked against the database for an uncached owner')
        assert_true(PFMed.Store.SetDiagnosis('DX1', { injuryType = 'fracture', structure = 'femur_l', status = 'suspected', source = 'provider', note = 'pain in the thigh' }))
        assert_true(PFMed.Store.SetDiagnosis('DX1', { injuryId = mine.id, injuryType = 'fracture', structure = 'tibia_l', status = 'confirmed', source = 'imaging' }))
        local confirmed = PFMed.Store.ListDiagnoses('DX1', { status = 'confirmed' })
        assert_eq(#confirmed, 1)
        assert_eq(tonumber(confirmed[1].injury_id), mine.id)
        assert_eq(#PFMed.Store.ListDiagnoses('DX1'), 2)
        local f = PFMed.Store.ListFindings('DX1')
        assert_eq(#f, 1); assert_eq(f[1].sign, 'crepitus'); assert_eq(tonumber(f[1].by_tier), 2)
        assert_eq(MySQL.scalar.await('SELECT structure FROM pf_med_injuries WHERE id = ?', { mine.id }), 'tibia_l', 'the injury itself is unchanged')
    end)
end)
