-- pf-ambulancejob batch-17 schema and recovery on a real database: migration v5 (treatments,
-- restrictions, hospital admissions, bills, bill lines) on a fresh database and on one at v3, the v3
-- findings/diagnoses tables left exactly as they were, a rerun that applies nothing, the bill-line
-- cascade and the admission key; then the recovery SQL as it runs: offline healing across a
-- restart (save, advance the clock, reload -> recovered), restrictions that survive a relog, expire
-- offline, extend instead of duplicating, are read for an offline citizen and go with the character.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
function GetResourceState() return 'started' end
function GetCurrentResourceName() return 'pf-ambulancejob' end

load_resource('pfm-core/server/migrations.lua')
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end

local AJ = '[pfscripts]/pf-ambulancejob/'
load_resource(AJ .. 'config.lua')
load_resource(AJ .. 'config_medical.lua')
load_resource(AJ .. 'shared/framework.lua')
for _, f in ipairs({ 'anatomy', 'injuries', 'physiology_model', 'effects_model' }) do
    load_resource(AJ .. 'shared/medical/' .. f .. '.lua')
end

-- (re)loads the server modules, as a resource restart does: empty cache, same database
local function restart()
    for _, f in ipairs({ 'schema', 'store', 'engine', 'effects', 'api', 'recovery' }) do
        load_resource(AJ .. 'server/medical/' .. f .. '.lua')
    end
    PFMed.Engine.Random = function() return 0.5 end
    PFMed.Recovery.Random = function() return 0.99 end
    Mock.exportsByResource['pf-ambulancejob'] = Mock.exportsByResource['__self']
    return PFMed.Schema.Start()
end

local function versions()
    local rows = MySQL.query.await("SELECT version FROM pf_schema_migrations WHERE resource = 'pf-ambulancejob' ORDER BY version")
    local out = {}
    for _, r in ipairs(rows) do out[#out + 1] = tonumber(r.version) end
    return table.concat(out, ',')
end
local function tableExists(name)
    return tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?', { name })) == 1
end
local function columns(name)
    local rows = MySQL.query.await('SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? ORDER BY ORDINAL_POSITION', { name })
    local out = {}
    for _, r in ipairs(rows) do out[#out + 1] = r.COLUMN_NAME .. ':' .. r.COLUMN_TYPE .. ':' .. r.IS_NULLABLE end
    return table.concat(out, ',')
end
local function count(sql, params) return tonumber(MySQL.scalar.await(sql, params)) or 0 end
local function online(src, cid)
    Mock.fireEvent('QBCore:Server:PlayerLoaded', nil, Mock.newPlayer(src, cid))
end
local NEW_TABLES = { 'pf_med_treatments', 'pf_med_restrictions', 'pf_hosp_admissions', 'pf_hosp_bills', 'pf_hosp_bill_lines' }

describe('migration v5', function()
    it('applies on a fresh database after v1-v3; a second run applies nothing', function()
        assert_true(restart())
        assert_eq(versions(), '1,2,3,5', 'v4 lives under the legacy-import key')
        for _, t in ipairs(NEW_TABLES) do assert_true(tableExists(t), t) end
        assert_true(RunMigrations('pf-ambulancejob', PFMed.Schema.Migrations))
        assert_eq(versions(), '1,2,3,5')
        local name = MySQL.scalar.await("SELECT name FROM pf_schema_migrations WHERE resource = 'pf-ambulancejob' AND version = 5")
        assert_eq(name, 'clinical and hospital core')
    end)

    it('a server at v3 gets only v5, and the v3 findings/diagnoses tables keep their shape and rows', function()
        for _, t in ipairs({ 'pf_hosp_bill_lines', 'pf_hosp_bills', 'pf_hosp_admissions', 'pf_med_restrictions', 'pf_med_treatments' }) do
            MySQL.query.await('DROP TABLE IF EXISTS `' .. t .. '`')
        end
        MySQL.query.await("DELETE FROM pf_schema_migrations WHERE resource = 'pf-ambulancejob' AND version = 5")
        assert_eq(versions(), '1,2,3')
        local findingsBefore, dxBefore = columns('pf_med_findings'), columns('pf_med_diagnoses')
        MySQL.insert.await("INSERT INTO pf_med_findings (citizenid, modality, sign, certainty, at) VALUES ('V3', 'look', 'open_wound', 'observed', 1)")
        assert_true(restart())
        assert_eq(versions(), '1,2,3,5')
        assert_eq(columns('pf_med_findings'), findingsBefore)
        assert_eq(columns('pf_med_diagnoses'), dxBefore)
        assert_eq(count("SELECT COUNT(*) FROM pf_med_findings WHERE citizenid = 'V3'"), 1)
        for _, t in ipairs(NEW_TABLES) do assert_true(tableExists(t), t) end
    end)

    it('bill lines go with their bill; an admission key is unique; restriction columns as planned', function()
        assert_true(restart())
        local bill = MySQL.insert.await("INSERT INTO pf_hosp_bills (citizenid, hospital_id, total, state, created_at) VALUES ('B1', 'pillbox', 500, 'open', 1)")
        MySQL.insert.await("INSERT INTO pf_hosp_bill_lines (bill_id, kind, label, unit_price) VALUES (?, 'bed', 'Bed', 200)", { bill })
        MySQL.insert.await("INSERT INTO pf_hosp_bill_lines (bill_id, kind, label, qty, unit_price) VALUES (?, 'drug', 'Morphine', 2, 150)", { bill })
        assert_eq(count('SELECT COUNT(*) FROM pf_hosp_bill_lines WHERE bill_id = ?', { bill }), 2)
        MySQL.query.await('DELETE FROM pf_hosp_bills WHERE id = ?', { bill })
        assert_eq(count('SELECT COUNT(*) FROM pf_hosp_bill_lines WHERE bill_id = ?', { bill }), 0, 'cascade')
        MySQL.insert.await("INSERT INTO pf_hosp_admissions (citizenid, hospital_id, state, arrived_at, idem_key) VALUES ('A1', 'pillbox', 'arrived', 1, 'adm-1')")
        local ok = pcall(MySQL.insert.await, "INSERT INTO pf_hosp_admissions (citizenid, hospital_id, state, arrived_at, idem_key) VALUES ('A2', 'pillbox', 'arrived', 1, 'adm-1')")
        assert_false(ok, 'idem_key is unique')
        assert_eq(count("SELECT COUNT(*) FROM pf_hosp_admissions WHERE mode = 'staff'"), 1, 'mode defaults to staff')
        assert_eq(columns('pf_med_restrictions'), 'id:int(11):NO,citizenid:varchar(64):NO,kind:varchar(32):NO,reason:varchar(128):YES,'
            .. 'injury_id:int(11):YES,from_at:bigint(20):NO,until_at:bigint(20):YES,ended_at:bigint(20):YES,by_cid:varchar(64):YES')
    end)
end)

describe('recovery on the real tables', function()
    it('offline healing: save, advance the clock, reload -> recovered, its restriction ended at the right time', function()
        assert_true(restart())
        Mock.players = {}
        online(1, 'HEAL1')
        local E, R = PFMed.Engine, PFMed.Recovery
        local inj = assert(E.AddInjury('HEAL1', { mechanism = 'fall', type = 'fracture', subtype = 'closed', structure = 'tibia_l', severity = 3 }, {}))
        assert(E.UpdateInjury('HEAL1', inj.id, { bleed_ml_min = 0, treatments = { splinted = true, cast = true } }, {}))
        R.Advance('HEAL1')
        assert_eq(inj.stage, 'recovering')
        local recoverAt = inj.recover_at
        assert_eq(recoverAt, os.time() + 43200)
        local r = MySQL.single.await("SELECT * FROM pf_med_restrictions WHERE citizenid = 'HEAL1'")
        assert_eq(r.kind, 'crutches')
        assert_eq(tonumber(r.injury_id), inj.id)
        assert_eq(tonumber(r.until_at), recoverAt)
        Mock.fireEvent('playerDropped', 1)
        local row = MySQL.single.await('SELECT stage, recover_at FROM pf_med_injuries WHERE id = ?', { inj.id })
        assert_eq(row.stage, 'recovering')
        assert_eq(tonumber(row.recover_at), recoverAt)

        Mock.clock = Mock.clock + 86400   -- a day offline, a restart in between
        assert_true(restart())
        online(1, 'HEAL1')
        PFMed.Store.Flush()
        row = MySQL.single.await('SELECT stage, recovered_at FROM pf_med_injuries WHERE id = ?', { inj.id })
        assert_eq(row.stage, 'recovered')
        assert_eq(tonumber(row.recovered_at), recoverAt, 'healed when it was due, not at login')
        r = MySQL.single.await("SELECT ended_at FROM pf_med_restrictions WHERE citizenid = 'HEAL1'")
        assert_eq(tonumber(r.ended_at), recoverAt)
        assert_eq(PFMed.Store.Peek('HEAL1').stage, 'healthy')
        local push = Mock.clientEventsNamed('pf-ambulancejob:client:Effects')
        assert_eq(push[#push].args[1].walk, 0)
        Mock.fireEvent('playerDropped', 1)
    end)

    it('restrictions survive a relog and a restart; extend, end, expire offline; read offline; deleted with the character', function()
        assert_true(restart())
        Mock.players = {}
        local R = PFMed.Recovery
        -- written while the citizen is offline (a discharge after they left)
        local a = R.AddRestriction('REL1', { kind = 'no_drive', seconds = 3600, reason = 'Concussion' })
        assert_true(a.ok, tostring(a.error))
        local b = R.AddRestriction('REL1', { kind = 'no_drive', seconds = 7200 })
        assert_true(b.extended)
        assert_eq(count("SELECT COUNT(*) FROM pf_med_restrictions WHERE citizenid = 'REL1'"), 1)
        assert_eq(count("SELECT until_at FROM pf_med_restrictions WHERE citizenid = 'REL1'"), os.time() + 7200)
        assert_true(R.AddRestriction('REL1', { kind = 'cast_arm_l' }).ok)
        local res = R.GetRestrictions('REL1')
        assert_eq(#res.list, 2, 'read for an offline citizen')

        online(4, 'REL1')
        local p = PFMed.Store.Peek('REL1')
        assert_true(p.restrictions.no_drive ~= nil and p.restrictions.cast_arm_l ~= nil, 'loaded at login')
        local push = Mock.clientEventsNamed('pf-ambulancejob:client:Effects')
        assert_eq(push[#push].args[1].drive, 2)
        Mock.fireEvent('playerDropped', 4)

        assert_true(restart())
        Mock.clock = Mock.clock + 3 * 3600   -- the no_drive order ran out while offline
        online(4, 'REL1')
        p = PFMed.Store.Peek('REL1')
        assert_true(p.restrictions.no_drive == nil, 'expired offline')
        assert_true(p.restrictions.cast_arm_l ~= nil, 'open-ended one kept')
        assert_eq(count("SELECT COUNT(*) FROM pf_med_restrictions WHERE citizenid = 'REL1' AND kind = 'no_drive' AND ended_at IS NOT NULL"), 1)
        assert_eq(R.EndRestriction('REL1', 'cast_arm_l').ended, 1)
        assert_eq(count("SELECT COUNT(*) FROM pf_med_restrictions WHERE citizenid = 'REL1' AND ended_at IS NULL"), 0)
        Mock.fireEvent('playerDropped', 4)

        R.AddRestriction('REL1', { kind = 'no_sprint' })
        Mock.fireEvent('pfm-core:server:characterDeleted', nil, 'REL1')
        assert_eq(count("SELECT COUNT(*) FROM pf_med_restrictions WHERE citizenid = 'REL1'"), 0)
    end)

    it('an uncared wound left offline is infected at login (one keyed infection row)', function()
        assert_true(restart())
        Mock.players = {}
        online(5, 'INF1')
        local inj = assert(PFMed.Engine.AddInjury('INF1', { mechanism = 'edged', type = 'laceration', subtype = 'deep', region = 'thigh_l', severity = 2 }, {}))
        Mock.fireEvent('playerDropped', 5)
        Mock.clock = Mock.clock + 4 * 3600
        assert_true(restart())
        online(5, 'INF1')
        PFMed.Store.Flush()
        assert_eq(count("SELECT COUNT(*) FROM pf_med_injuries WHERE citizenid = 'INF1' AND type = 'infection' AND idem_key = ?", { 'pf-ambulancejob:infection:' .. inj.id }), 1)
        assert_eq(MySQL.scalar.await('SELECT stage FROM pf_med_injuries WHERE id = ?', { inj.id }), 'complicated')
        Mock.fireEvent('playerDropped', 5)
    end)
end)
