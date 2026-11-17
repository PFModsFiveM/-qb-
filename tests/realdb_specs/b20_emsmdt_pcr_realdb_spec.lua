-- pf-emsmdt batch 20 (20D) on a real database: schema v3 on a fresh database, on a v2 install and on a
-- rerun; every PCR and unit-board query (open, chart with the unique AJ id, vitals, lists with the crew
-- subquery, narrative with multi-byte text cut at the cap, the guarded handover and close updates, the
-- sweep, the cascade on a deleted character) and a restart that reloads open PCRs and the board.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
function GetConvar(_, default) return default end
local resState = { ['pf-ambulancejob'] = 'started' }
function GetResourceState(r) return resState[r] or 'missing' end
QBCore = QBCoreMock
promise = promise or { new = function() return { resolve = function(self, v) self.value = v end } end }
Citizen.Await = Citizen.Await or function(p) return p.value end

load_resource('pfm-core/server/migrations.lua')
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end
Mock.exportsByResource['oxmysql'] = {}

local AJ = { admissions = {}, deny = false }
Mock.exportsByResource['pf-ambulancejob'] = {
    GetPatientSummary = function(_, cid) return { ok = true, cid = cid, consciousness = 'alert', vitals = { hr = 88, sbp = 120, dbp = 80, rr = 16, spo2 = 98, temp = 36.9, gcs = 15, pain = 2 } } end,
    GetAdmission = function(_, cid) return { ok = true, admission = AJ.admissions[cid] } end,
    GetMedicalRecord = function() if AJ.deny then return { ok = false, error = 'no_permission' } end return { ok = true, record = {} } end,
}

local threads = {}
CreateThread = function(fn) threads[#threads + 1] = fn end
SetTimeout = function() end
Wait = function() end
function GetCurrentResourceName() return 'pf-emsmdt' end

local DIR = '[pfscripts]/pf-emsmdt/'
local function loadAll()
    Config, PFEmsSchema, PFEmsPcr, PFEmsUnits, PFEmsDispatch = nil, nil, nil, nil, nil
    load_resource(DIR .. 'config.lua')
    load_resource(DIR .. 'shared/framework.lua')
    load_resource(DIR .. 'server/schema.lua')
    load_resource(DIR .. 'server/main.lua')
    load_resource(DIR .. 'server/units.lua')
    load_resource(DIR .. 'server/pcr.lua')
    threads = {}
    local ok = PFEmsSchema.Apply()
    local t = threads
    threads = {}
    for _, fn in ipairs(t) do fn() end
    return ok
end

local function count(sql, p) return tonumber(MySQL.scalar.await(sql, p or {})) or 0 end
local function tableExists(name) return count('SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?', { name }) > 0 end
local function versions()
    local out = {}
    for _, r in ipairs(MySQL.query.await("SELECT version FROM pf_schema_migrations WHERE resource = 'pf-emsmdt' ORDER BY version") or {}) do out[#out + 1] = tonumber(r.version) end
    return table.concat(out, ',')
end
local function wipe()
    for _, t in ipairs({ 'pf_emsmdt_pcr_entries', 'pf_emsmdt_pcr', 'pf_emsmdt_units' }) do MySQL.query.await(('DROP TABLE IF EXISTS `%s`'):format(t)) end
    MySQL.query.await('DROP TABLE IF EXISTS pf_schema_migrations')
end

local MED1, MED2, NURSE, PAT = 1, 2, 3, 4
local function setJob(src, name, onduty, grade) Mock.players[src].PlayerData.job = { name = name, onduty = onduty, grade = { level = grade or 1 } } end
local function players()
    Mock.players = {}
    Mock.newPlayer(MED1, 'MED1'); setJob(MED1, 'ambulance', true)
    Mock.newPlayer(MED2, 'MED2'); setJob(MED2, 'ambulance', true)
    Mock.newPlayer(NURSE, 'NURSE1'); setJob(NURSE, 'ambulance', true, 2)
    Mock.newPlayer(PAT, 'PAT1')
    for s = 1, 4 do Mock.coords[s] = vector3(1.0, 1.0, 1.0) end
end
local function treat(cid, id, by, at)
    Mock.invokingResource = 'pf-ambulancejob'
    TriggerEvent('pf-ambulancejob:server:treatmentApplied', cid, { id = id, action = 'chest_seal', byCid = by, at = at or Mock.clock, result = 'applied' })
    Mock.invokingResource = nil
end
local function cb(name, src, data) Mock.gameTimer = Mock.gameTimer + 5000 return Mock.callCallback(name, src, data) end

BeforeEach = function()
    Mock.reset()
    Mock.clock = 1800000000
    AJ.admissions, AJ.deny = {}, false
    players()
end

describe('schema v3', function()
    it('a fresh database gets v1-v3 and the three tables with the cascade; a second run applies nothing', function()
        wipe()
        assert_true(loadAll())
        assert_eq(versions(), '1,2,3')
        for _, t in ipairs({ 'pf_emsmdt_pcr', 'pf_emsmdt_pcr_entries', 'pf_emsmdt_units' }) do assert_true(tableExists(t), t) end
        assert_eq(count([[SELECT COUNT(*) FROM information_schema.REFERENTIAL_CONSTRAINTS WHERE CONSTRAINT_SCHEMA = DATABASE()
            AND CONSTRAINT_NAME = 'fk_pcre_pcr' AND DELETE_RULE = 'CASCADE']]), 1)
        assert_eq(count([[SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'pf_emsmdt_pcr_entries'
            AND INDEX_NAME = 'uq_pcre_ref' AND NON_UNIQUE = 0]]), 3)
        local at = MySQL.scalar.await("SELECT UNIX_TIMESTAMP(applied_at) FROM pf_schema_migrations WHERE resource = 'pf-emsmdt' AND version = 3")
        assert_true(loadAll())
        assert_eq(versions(), '1,2,3')
        assert_eq(MySQL.scalar.await("SELECT UNIX_TIMESTAMP(applied_at) FROM pf_schema_migrations WHERE resource = 'pf-emsmdt' AND version = 3"), at)
        for _, sql in ipairs(PFEmsSchema.Migrations[3].up) do MySQL.query.await(sql) end -- the steps themselves rerun
    end)

    it('a v2 install gains only v3', function()
        wipe()
        assert_eq(RunMigrations('pf-emsmdt', { PFEmsSchema.Migrations[1], PFEmsSchema.Migrations[2] }), true)
        assert_eq(versions(), '1,2')
        assert_false(tableExists('pf_emsmdt_pcr'))
        assert_true(loadAll())
        assert_eq(versions(), '1,2,3')
        assert_true(tableExists('pf_emsmdt_pcr'))
    end)
end)

describe('PCR queries on MariaDB', function()
    it('opens, charts each AJ id once with a vitals line, and lists by lead, crew and patient', function()
        wipe()
        loadAll()
        treat('PAT1', 501, 'MED1')
        treat('PAT1', 501, 'MED1')
        Mock.clock = Mock.clock + 5
        treat('PAT1', 502, 'MED2')
        assert_eq(count('SELECT COUNT(*) FROM pf_emsmdt_pcr'), 1)
        assert_eq(count("SELECT COUNT(*) FROM pf_emsmdt_pcr_entries WHERE kind = 'treatment'"), 2)
        assert_eq(count("SELECT COUNT(*) FROM pf_emsmdt_pcr_entries WHERE kind = 'treatment' AND ref_id = 501"), 1)
        assert_eq(MySQL.scalar.await("SELECT summary FROM pf_emsmdt_pcr_entries WHERE kind = 'vitals'"), 'HR 88, BP 120/80, RR 16, SpO2 98%, Temp 36.9, GCS 15, Pain 2/10, Alert')
        assert_eq(#cb('pf_emsmdt:pcr:list', MED1, {}).list, 1, 'lead')
        assert_eq(#cb('pf_emsmdt:pcr:list', MED2, {}).list, 1, 'crew (charted a line)')
        assert_eq(#cb('pf_emsmdt:pcr:list', NURSE, {}).list, 0)
        assert_eq(#cb('pf_emsmdt:pcr:list', NURSE, { scope = 'patient', citizenId = 'PAT1' }).list, 1)
        AJ.deny = true
        assert_eq(#cb('pf_emsmdt:pcr:list', NURSE, { scope = 'patient', citizenId = 'PAT1' }).list, 0)
        local got = cb('pf_emsmdt:pcr:get', MED2, { id = 1 })
        assert_true(got.ok)
        assert_eq(got.pcr.entryCount, 4)
        assert_eq(got.pcr.entries[1].kind, 'note')
    end)

    it('narrative (multi-byte text cut at the cap), handover, close and the cascade', function()
        local id = tonumber(MySQL.scalar.await('SELECT id FROM pf_emsmdt_pcr LIMIT 1'))
        Config.PCR.NarrativeMax = 10
        local res = cb('pf_emsmdt:pcr:saveNarrative', MED1, { id = id, text = 'Pätient äää\nok' })
        assert_true(res.ok)
        assert_true(res.clipped)
        local n = MySQL.scalar.await('SELECT narrative FROM pf_emsmdt_pcr WHERE id = ?', { id })
        assert_true(#n <= 10 and utf8.len(n) ~= nil, n)
        AJ.admissions['PAT1'] = { id = 12, hospitalId = 'pillbox', hospital = 'Pillbox Medical Center', state = 'triaged', open = true }
        res = cb('pf_emsmdt:pcr:acknowledgeHandover', NURSE, { id = id })
        assert_true(res.ok, tostring(res.error))
        local row = MySQL.single.await('SELECT state, handover_by, hospital_id, admission_id FROM pf_emsmdt_pcr WHERE id = ?', { id })
        assert_eq(row.state, 'handed_over')
        assert_eq(row.handover_by, 'NURSE1')
        assert_eq(row.hospital_id, 'pillbox')
        assert_eq(tonumber(row.admission_id), 12)
        assert_eq(cb('pf_emsmdt:pcr:acknowledgeHandover', NURSE, { id = id }).error, 'invalid_state')
        assert_true(cb('pf_emsmdt:pcr:close', MED1, { id = id, disposition = 'transported' }).ok)
        assert_eq(MySQL.scalar.await('SELECT disposition FROM pf_emsmdt_pcr WHERE id = ?', { id }), 'transported')
        Mock.invokingResource = nil
        TriggerEvent('pfm-core:server:characterDeleted', 'PAT1', {})
        assert_eq(count('SELECT COUNT(*) FROM pf_emsmdt_pcr'), 0)
        assert_eq(count('SELECT COUNT(*) FROM pf_emsmdt_pcr_entries'), 0, 'lines cascade')
    end)

    it('the sweep closes stale reports; a restart reloads an open PCR and keeps charting it', function()
        wipe()
        loadAll()
        treat('PAT1', 801, 'MED1')
        loadAll()
        assert_eq(PFEmsPcr.OpenByCid['PAT1'].id, 1)
        Mock.clock = Mock.clock + 30
        treat('PAT1', 802, 'MED1')
        assert_eq(count('SELECT COUNT(*) FROM pf_emsmdt_pcr'), 1)
        assert_eq(count("SELECT COUNT(*) FROM pf_emsmdt_pcr_entries WHERE kind = 'treatment'"), 2)
        Mock.clock = Mock.clock + Config.PCR.AutoCloseSeconds + 1
        assert_eq(PFEmsPcr.Tick(), 1)
        assert_eq(MySQL.scalar.await('SELECT disposition FROM pf_emsmdt_pcr WHERE id = 1'), 'no_activity')
        -- a handed-over report left alone is closed by one guarded UPDATE
        MySQL.query.await("UPDATE pf_emsmdt_pcr SET state = 'handed_over', disposition = NULL, updated_at = 1 WHERE id = 1")
        assert_eq(PFEmsPcr.Tick(), 1)
        assert_eq(MySQL.scalar.await('SELECT state FROM pf_emsmdt_pcr WHERE id = 1'), 'closed')
    end)
end)

describe('unit board persistence', function()
    it('the board is written, survives a restart and drops crew who are gone', function()
        wipe()
        loadAll()
        assert_true(cb('pf_emsmdt:units:join', MED1, { unit = 'MEDIC 1' }).ok)
        assert_true(cb('pf_emsmdt:units:join', MED2, { unit = 'MEDIC 2' }).ok)
        assert_true(cb('pf_emsmdt:units:setStatus', MED1, { status = 'transporting' }).ok)
        Mock.vehicleOf[MED1], Mock.plates[50] = 50, 'EMS 7'
        assert_true(cb('pf_emsmdt:units:setRig', MED1, {}).ok)
        local row = MySQL.single.await("SELECT status, crew, rig_plate FROM pf_emsmdt_units WHERE unit = 'MEDIC 1'")
        assert_eq(row.status, 'transporting')
        assert_eq(row.crew, '["MED1"]')
        assert_eq(row.rig_plate, 'EMS 7')
        Mock.players[MED2] = nil
        loadAll()
        assert_eq(PFEmsUnits.Get('MEDIC 1').status, 'transporting')
        assert_eq(PFEmsUnits.Get('MEDIC 1').rigPlate, 'EMS 7')
        assert_eq(PFEmsUnits.Get('MEDIC 2'), nil)
        assert_eq(count("SELECT COUNT(*) FROM pf_emsmdt_units WHERE unit = 'MEDIC 2'"), 0)
        assert_true(cb('pf_emsmdt:units:leave', MED1).ok)
        assert_eq(count('SELECT COUNT(*) FROM pf_emsmdt_units'), 0)
    end)
end)
