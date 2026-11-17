-- pf-ambulancejob batch 17A on a real database: exams write pf_med_findings and confirmed
-- pf_med_diagnoses; the care-relation, vitals, chart-treatment and record queries (documented
-- injuries only, attacker details left out; the treatments clause works with and without the v5
-- pf_med_treatments table); GetMedicalRecord and getChart end to end with every read audited.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
function GetResourceState() return 'started' end
function GetCurrentResourceName() return 'pf-ambulancejob' end
function GetAllVehicles() return {} end
function AddEventHandler(name, fn)
    local prev = Mock.eventHandlers[name]
    if prev then Mock.eventHandlers[name] = function(...) prev(...) fn(...) end else Mock.eventHandlers[name] = fn end
end

load_resource('pfm-core/server/migrations.lua')
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end
Mock.exportsByResource['pfm-inventory'] = { HasItem = function() return false end }

local AJ = '[pfscripts]/pf-ambulancejob/'
load_resource(AJ .. 'config.lua')
load_resource(AJ .. 'config_medical.lua')
load_resource(AJ .. 'shared/framework.lua')
for _, f in ipairs({ 'anatomy', 'injuries', 'physiology_model', 'effects_model', 'findings' }) do load_resource(AJ .. 'shared/medical/' .. f .. '.lua') end
load_resource(AJ .. 'server/injury_database.lua')

local Admissions = {}
local function restart()
    Mock.eventHandlers, Mock.callbacks = {}, {}
    for _, f in ipairs({ 'schema', 'store', 'engine', 'effects', 'api', 'diagnosis', 'exam' }) do load_resource(AJ .. 'server/medical/' .. f .. '.lua') end
    PFMed.Engine.Random = function() return 0.5 end
    PFMed.Diagnosis.Random = function() return 0 end
    PFMed.Exam.WaitFor = function() end
    Mock.exportsByResource['__self'].GetAdmission = function(_, cid)
        local a = Admissions[cid]
        return a and { ok = true, admission = a } or { ok = true }
    end
    Mock.exportsByResource['pf-ambulancejob'] = Mock.exportsByResource['__self']
    return PFMed.Schema.Start()
end

-- the batch-17 v5 tables (17C's schema) with the DDL of PF_DATABASE_MIGRATIONS.md
local V5 = {
    [[CREATE TABLE IF NOT EXISTS `pf_med_treatments` (
  `id` BIGINT NOT NULL AUTO_INCREMENT, `citizenid` VARCHAR(64) NOT NULL, `injury_id` INT NULL,
  `action` VARCHAR(32) NOT NULL, `params` LONGTEXT NULL, `items` LONGTEXT NULL,
  `by_cid` VARCHAR(64) NULL, `by_job` VARCHAR(32) NULL, `location` VARCHAR(16) NOT NULL,
  `admission_id` INT NULL, `call_ref` VARCHAR(64) NULL, `req` VARCHAR(64) NULL, `result` VARCHAR(16) NOT NULL,
  `at` BIGINT NOT NULL,
  PRIMARY KEY (`id`), KEY `idx_med_tx_cid` (`citizenid`, `at`), KEY `idx_med_tx_adm` (`admission_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
    [[CREATE TABLE IF NOT EXISTS `pf_hosp_admissions` (
  `id` INT NOT NULL AUTO_INCREMENT, `citizenid` VARCHAR(64) NOT NULL, `hospital_id` VARCHAR(32) NOT NULL,
  `state` VARCHAR(16) NOT NULL, `mode` VARCHAR(8) NOT NULL DEFAULT 'staff',
  `triage` VARCHAR(8) NULL, `dept` VARCHAR(16) NULL, `bed_id` VARCHAR(32) NULL,
  `reason` VARCHAR(255) NULL, `arrived_at` BIGINT NOT NULL, `triaged_at` BIGINT NULL, `admitted_at` BIGINT NULL,
  `discharged_at` BIGINT NULL, `discharge_orders` LONGTEXT NULL, `idem_key` VARCHAR(128) NULL,
  PRIMARY KEY (`id`), UNIQUE KEY `uq_hosp_adm_key` (`idem_key`),
  KEY `idx_hosp_adm_cid` (`citizenid`, `state`), KEY `idx_hosp_adm_hosp` (`hospital_id`, `state`),
  KEY `idx_hosp_adm_bed` (`hospital_id`, `bed_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
}
local function createV5() for _, sql in ipairs(V5) do MySQL.query.await(sql) end end

local PATIENT, MEDIC, DOC, FAR = 1, 2, 3, 4
local function online(src, cid, job)
    local p = Mock.newPlayer(src, cid)
    if job then p.PlayerData.job = job end
    Mock.fireEvent('QBCore:Server:PlayerLoaded', nil, p)
    return p
end
local function cb(name, src, ...) Mock.gameTimer = Mock.gameTimer + 600 return Mock.callCallback(name, src, ...) end
local function count(sql, params) return tonumber(MySQL.scalar.await(sql, params)) or 0 end

local function setup()
    Mock.clock = 1700000000
    Mock.players, Mock.coords = {}, {}
    Mock.invokingResource = nil
    Admissions = {}
    assert_true(restart())
    createV5()
    -- one database per spec file: start every case from empty tables
    for _, t in ipairs({ 'pf_med_findings', 'pf_med_diagnoses', 'pf_med_injuries', 'pf_med_patients', 'pf_med_events', 'pf_med_treatments', 'pf_hosp_admissions' }) do
        MySQL.query.await('DELETE FROM `' .. t .. '`')
    end
    online(PATIENT, 'RPAT')
    online(MEDIC, 'RMED', { name = 'ambulance', onduty = true, grade = { level = 1 } })
    online(DOC, 'RDOC', { name = 'ambulance', onduty = true, grade = { level = 2 } })
    online(FAR, 'RFAR', { name = 'ambulance', onduty = true, grade = { level = 1 } })
    Mock.coords[PATIENT] = vector3(500.0, 500.0, 30.0)
    Mock.coords[MEDIC] = vector3(501.0, 500.0, 30.0)
    Mock.coords[DOC] = vector3(3000.0, 3000.0, 30.0)
    Mock.coords[FAR] = vector3(900.0, 900.0, 30.0)
end

describe('exams on the real tables', function()
    it('an exam stores findings; CT stores a confirmed diagnosis once; nothing for an injury nobody found', function()
        setup()
        local E = PFMed.Engine
        local bruise = E.AddInjury('RPAT', { mechanism = 'blunt', type = 'bruising', region = 'thigh_l', severity = 3, attackerCid = 'ATTACKER' }, {})
        local liver = E.AddInjury('RPAT', { mechanism = 'blunt', type = 'internal_bleeding', subtype = 'liver', structure = 'liver', region = 'abdomen', severity = 3 }, {})
        local spleen = E.AddInjury('RPAT', { mechanism = 'blunt', type = 'internal_bleeding', subtype = 'spleen', structure = 'spleen', region = 'abdomen', severity = 2 }, {})
        local r = cb('pf-ambulancejob:server:exam', MEDIC, PATIENT, 'look')
        assert_true(r.ok, tostring(r.error))
        assert_eq(count("SELECT COUNT(*) FROM pf_med_findings WHERE citizenid = 'RPAT' AND injury_id = ? AND sign = 'bruise' AND by_cid = 'RMED' AND by_tier = 3", { bruise.id }), 1)
        -- the physician scans the liver only: put the patient in the imaging bed and roll only the first CT sign
        Mock.coords[PATIENT] = vector3(326.98, -576.17, 43.02)
        Mock.coords[DOC] = vector3(328.0, -576.0, 43.0)
        Admissions.RPAT = { state = 'admitted', bedId = 'pb_8' }
        local rolls = 0
        PFMed.Diagnosis.Random = function() rolls = rolls + 1; return rolls == 1 and 0 or 0.999 end
        r = cb('pf-ambulancejob:server:exam', DOC, PATIENT, 'ct')
        assert_true(r.ok, tostring(r.message))
        assert_eq(count("SELECT COUNT(*) FROM pf_med_diagnoses WHERE citizenid = 'RPAT' AND injury_id = ? AND status = 'confirmed' AND source = 'imaging' AND injury_type = 'internal_bleeding' AND structure = 'liver'", { liver.id }), 1)
        assert_eq(count("SELECT COUNT(*) FROM pf_med_findings WHERE injury_id = ?", { spleen.id }), 0)
        Mock.clock = Mock.clock + 61
        PFMed.Diagnosis.Random = function() return 0 end
        cb('pf-ambulancejob:server:exam', DOC, PATIENT, 'ct')
        assert_eq(count("SELECT COUNT(*) FROM pf_med_diagnoses WHERE injury_id = ? AND status = 'confirmed'", { liver.id }), 1, 'once per injury')
        assert_eq(count("SELECT COUNT(*) FROM pf_med_diagnoses WHERE injury_id = ? AND status = 'confirmed'", { spleen.id }), 1)
        PFMed.Store.Flush()
        assert_true(count("SELECT COUNT(*) FROM pf_med_events WHERE citizenid = 'RPAT' AND action = 'exam'") >= 3)
    end)
end)

describe('queries', function()
    it('care relation from findings and from the treatment log, within 24 h', function()
        setup()
        local Q = PFMed.SQL
        local t = os.time()
        MySQL.insert.await("INSERT INTO pf_med_findings (citizenid, modality, sign, certainty, by_cid, by_tier, at) VALUES ('RPAT', 'look', 'bruise', 'observed', 'RMED', 3, ?)", { t - 100 })
        MySQL.insert.await("INSERT INTO pf_med_treatments (citizenid, action, by_cid, location, result, at) VALUES ('RPAT', 'splint', 'RFAR', 'field', 'ok', ?)", { t - 200 })
        assert_true(Q.DxCareFinding('RPAT', 'RMED', t - 86400) ~= nil)
        assert_eq(Q.DxCareFinding('RPAT', 'RMED', t - 50), nil)
        assert_eq(Q.DxCareFinding('RPAT', 'RFAR', t - 86400), nil)
        assert_true(Q.DxCareTreatment('RPAT', 'RFAR', t - 86400) ~= nil)
        assert_true(PFMed.Diagnosis.HadCare('RPAT', 'RFAR', t))
        assert_false(PFMed.Diagnosis.HadCare('RPAT', 'RDOC', t))
    end)
    it('documented injuries only, with and without the treatments table; vitals and treatment lists', function()
        setup()
        local Q = PFMed.SQL
        local t = os.time()
        local function inj(typ, stage)
            return MySQL.insert.await("INSERT INTO pf_med_injuries (citizenid, type, region, severity, stage, mechanism, source_attacker_cid, created_at) VALUES ('RPAT', ?, 'thigh_l', 2, ?, 'blunt', 'ATTACKER', ?)", { typ, stage, t })
        end
        local found, confirmed, treated, hidden, other = inj('bruising', 'injured'), inj('fracture', 'treated'), inj('laceration', 'recovered'), inj('internal_bleeding', 'injured'), nil
        other = MySQL.insert.await("INSERT INTO pf_med_injuries (citizenid, type, severity, stage, mechanism, created_at) VALUES ('OTHER', 'burn', 2, 'injured', 'burn', ?)", { t })
        MySQL.insert.await("INSERT INTO pf_med_findings (citizenid, injury_id, modality, sign, certainty, at) VALUES ('RPAT', ?, 'look', 'bruise', 'observed', ?)", { found, t })
        MySQL.insert.await("INSERT INTO pf_med_findings (citizenid, injury_id, modality, sign, certainty, at) VALUES ('OTHER', ?, 'look', 'burn', 'observed', ?)", { other, t })
        MySQL.insert.await("INSERT INTO pf_med_diagnoses (citizenid, injury_id, injury_type, status, source, at) VALUES ('RPAT', ?, 'fracture', 'confirmed', 'imaging', ?)", { confirmed, t })
        MySQL.insert.await("INSERT INTO pf_med_diagnoses (citizenid, injury_id, injury_type, status, source, at) VALUES ('RPAT', ?, 'internal_bleeding', 'suspected', 'provider', ?)", { hidden, t })
        MySQL.insert.await("INSERT INTO pf_med_treatments (citizenid, injury_id, action, by_cid, location, result, at) VALUES ('RPAT', ?, 'sutures', 'RDOC', 'hospital', 'ok', ?)", { treated, t })
        local function ids(rows) local o = {} for _, r in ipairs(rows) do o[tonumber(r.id)] = r end return o end
        local with = ids(Q.DxRecordInjuries('RPAT', 200, true))
        assert_true(with[found] and with[confirmed] and with[treated])
        assert_eq(with[hidden], nil, 'a suspected diagnosis alone does not document the true injury')
        assert_eq(with[other], nil)
        assert_eq(with[found].source_attacker_cid, nil, 'attacker details are not selected')
        local without = ids(Q.DxRecordInjuries('RPAT', 200, false))
        assert_eq(without[treated], nil)
        assert_true(without[found] and without[confirmed])
        -- vitals: only the measurement modalities, newest first, within the window
        MySQL.insert.await("INSERT INTO pf_med_findings (citizenid, modality, sign, value, certainty, at) VALUES ('RPAT', 'pulse', 'pulse', '88', 'observed', ?)", { t - 10 })
        MySQL.insert.await("INSERT INTO pf_med_findings (citizenid, modality, sign, value, certainty, at) VALUES ('RPAT', 'bp_cuff', 'blood_pressure', '120/78', 'observed', ?)", { t - 5 })
        MySQL.insert.await("INSERT INTO pf_med_findings (citizenid, modality, sign, value, certainty, at) VALUES ('RPAT', 'pulse', 'pulse', '70', 'observed', ?)", { t - 90000 })
        local v = Q.DxVitals('RPAT', t - 86400, 200)
        assert_eq(#v, 2)
        assert_eq(v[1].value, '120/78')
        local tr = Q.DxTreatments('RPAT', t - 86400, 100)
        assert_eq(#tr, 1)
        assert_eq(tr[1].action, 'sutures')
        assert_eq(#Q.DxRecordTreatments('RPAT', 200), 1)
        MySQL.insert.await("INSERT INTO pf_hosp_admissions (citizenid, hospital_id, state, arrived_at) VALUES ('RPAT', 'pillbox', 'discharged', ?)", { t })
        assert_eq(Q.DxRecordAdmissions('RPAT', 50)[1].hospital_id, 'pillbox')
        assert_true(Q.DxFindingForInjury('RPAT', found) ~= nil)
        assert_eq(Q.DxFindingForInjury('RPAT', hidden), nil)
        assert_eq(Q.DxFindingForInjury('OTHER', found), nil)
    end)
end)

describe('chart and record end to end', function()
    it('GetMedicalRecord falls back when the v5 tables are missing; chart and record reads are audited', function()
        setup()
        local E = PFMed.Engine
        local bruise = E.AddInjury('RPAT', { mechanism = 'blunt', type = 'bruising', region = 'thigh_l', severity = 3 }, {})
        cb('pf-ambulancejob:server:exam', MEDIC, PATIENT, 'look')
        Mock.invokingResource = 'pf-emsmdt'
        local r = Mock.selfExport('GetMedicalRecord')('RPAT', { viewer = PATIENT, purpose = 'self' })
        assert_true(r.ok)
        assert_eq(r.record.injuries[1].id, bruise.id)
        MySQL.query.await('DROP TABLE `pf_med_treatments`')
        MySQL.query.await('DROP TABLE `pf_hosp_admissions`')
        r = Mock.selfExport('GetMedicalRecord')('RPAT', { viewer = MEDIC, purpose = 'treatment' })
        assert_true(r.ok, tostring(r.error))
        assert_eq(#r.record.injuries, 1)
        assert_eq(#r.record.treatments, 0)
        assert_eq(#r.record.admissions, 0)
        assert_eq(Mock.selfExport('GetMedicalRecord')('RPAT', { viewer = FAR, purpose = 'treatment' }).error, 'no_permission')
        Mock.invokingResource = nil
        local c = cb('pf-ambulancejob:server:getChart', MEDIC, PATIENT)
        assert_true(c.ok)
        assert_true(#c.findings >= 1)
        assert_eq(#c.treatments, 0, 'no treatments table yet: empty, not an error')
        PFMed.Store.Flush()
        assert_eq(count("SELECT COUNT(*) FROM pf_med_events WHERE citizenid = 'RPAT' AND action = 'record_read'"), 4)
        assert_eq(count("SELECT COUNT(*) FROM pf_med_events WHERE citizenid = 'RPAT' AND action = 'record_read' AND detail LIKE '%denied%'"), 1)
        -- a character deletion removes the findings and diagnoses with the rest
        PFMed.Store.DeleteCharacter('RPAT')
        assert_eq(count("SELECT COUNT(*) FROM pf_med_findings WHERE citizenid = 'RPAT'"), 0)
    end)
end)
