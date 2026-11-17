-- pf-ambulancejob hospital services (batch 20A) on a real database with the real pfm-banking ledger:
-- migration v8 (extends 19G's prescription and dispense tables, adds orders, stays, death records,
-- supply usage; rerun-safe, also from v7 after a partial run); the pharmacy (prescription keyed per
-- admission and drug, fills reserved before the items move, out of stock gives the fill back,
-- refill interval, controlled-substance withdrawals and returns logged before the items move);
-- lab orders whose results come from the engine state at the draw and are released when due;
-- imaging that confirms a diagnosis through the 17A layer; surgery in the operating room with
-- retained-projectile recovery; ward/ICU stays priced per stay on the one keyed bill.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
STARTED = {}
function GetResourceState(res) return (STARTED[res] ~= false) and 'started' or 'missing' end
function GetEntityHealth() return 200 end
function GetPedArmour() return 0 end
function GetEntityAttachedTo() return 0 end
function SetEntityCoords() end
Bags = {}
function Player(src)
    Bags[src] = Bags[src] or {}
    local b = Bags[src]
    return { state = setmetatable({ set = function(_, k, v) b[k] = v end }, { __index = b }) }
end
function AddEventHandler(name, fn)
    local prev = Mock.eventHandlers[name]
    if prev then Mock.eventHandlers[name] = function(...) prev(...) fn(...) end else Mock.eventHandlers[name] = fn end
end

-- the bank
RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
function GetCurrentResourceName() return 'pfm-banking' end
Config = nil
load_resource('pfm-banking/config.lua')
load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')
local bankingConfig = Config
Mock.exportsByResource['pfm-banking'] = Mock.exportsByResource['__self']
Mock.exportsByResource['__self'] = nil
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end
assert(PFLedger.Start(), 'ledger start')
MySQL.query.await("INSERT INTO bank_accounts (account_name, account_balance, account_type, users) VALUES ('ambulance', 0, 'job', '[]') ON DUPLICATE KEY UPDATE account_balance = 0")
MySQL.query.await("INSERT IGNORE INTO pf_ledger_baselines (account, balance) VALUES ('society:ambulance', 0)")

-- other resources: the phone (invoices), the inventory (stashes and pockets)
Mock.exportsByResource['pfm-phone'] = { CreateInvoice = function() return 901 end }
Stash, Pockets = {}, {}
Mock.exportsByResource['pfm-inventory'] = {
    RemoveItem = function(_, id, item, n)
        n = n or 1
        local bag = type(id) == 'string' and Stash or Pockets
        bag[id] = bag[id] or {}
        if (bag[id][item] or 0) < n then return false end
        bag[id][item] = bag[id][item] - n
        return true
    end,
    AddItem = function(_, id, item, n)
        local bag = type(id) == 'string' and Stash or Pockets
        bag[id] = bag[id] or {}
        bag[id][item] = (bag[id][item] or 0) + (n or 1)
        return true
    end,
    CreateInventory = function(_, id) Stash[id] = Stash[id] or {} end,
    OpenInventory = function() end,
    HasItem = function() return true end,
}
QBCoreMock.Commands.Add = function() end

function GetCurrentResourceName() return 'pf-ambulancejob' end
Config = nil
load_resource('pfm-banking/payouts.lua')
local AJ = '[pfscripts]/pf-ambulancejob/'
for _, f in ipairs({ 'config.lua', 'config_medical.lua', 'config_hospital.lua', 'shared/framework.lua', 'shared/medical/anatomy.lua',
    'shared/medical/injuries.lua', 'shared/medical/physiology_model.lua', 'shared/medical/effects_model.lua', 'shared/medical/findings.lua',
    'server/main.lua' }) do
    load_resource(AJ .. f)
end
for k, v in pairs(bankingConfig) do if Config[k] == nil then Config[k] = v end end
Config.WipeInventoryOnRespawn = false

local SERVER = { 'server/medical/schema.lua', 'server/medical/store.lua', 'server/medical/engine.lua', 'server/medical/downstate.lua',
    'server/medical/effects.lua', 'server/medical/api.lua', 'server/medical/diagnosis.lua', 'server/medical/exam.lua', 'server/medical/recovery.lua',
    'server/hospital/facility.lua', 'server/hospital/beds.lua', 'server/hospital/admissions.lua', 'server/hospital/billing.lua',
    'server/hospital/ai_care.lua', 'server/hospital/pharmacy.lua', 'server/hospital/lab.lua', 'server/hospital/imaging.lua',
    'server/hospital/surgery.lua' }

-- (re)loads the server modules, as a resource restart does: empty memory, same database
local function restart()
    for _, ev in ipairs({ 'QBCore:Server:PlayerLoaded', 'pf-ambulancejob:server:admissionChanged', 'pfm-core:server:characterDeleted' }) do
        Mock.eventHandlers[ev] = nil
    end
    PFHospital = nil
    for _, f in ipairs(SERVER) do load_resource(AJ .. f) end
    Mock.exportsByResource['pf-ambulancejob'] = Mock.exportsByResource['__self']
    PFMed.Engine.Random = function() return 0.5 end
    PFMed.Diagnosis.Random = function() return 0 end -- every sign that can be found is found
    assert(PFMed.Schema.Start(), 'medical tables')
    assert(PFHospital.Admissions.Start(), 'hospital ready')
    PFHospital.Pharmacy.Start()
    assert(PFHospital.Stays.Start(os.time()), 'stays ready')
    PFHospital.Imaging.WaitFor = function() end
    PFHospital.Surgery.WaitFor = function() end
    return PFHospital
end
local H = restart()
local Q = H.SQL

local PATIENT, NURSE, DOC = 1, 2, 3
local PAT = 'RDBPAT20'
local function cb(name, src, ...) return Mock.callCallback('pf-ambulancejob:server:' .. name, src, ...) end
local function count(sql, params) return tonumber(MySQL.scalar.await(sql, params)) or 0 end
local function versions()
    local out = {}
    for _, r in ipairs(MySQL.query.await("SELECT version FROM pf_schema_migrations WHERE resource = 'pf-ambulancejob' ORDER BY version")) do out[#out + 1] = tonumber(r.version) end
    return table.concat(out, ',')
end
local function hasColumn(t, c)
    return count('SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = ?', { t, c }) == 1
end
local function tableExists(t)
    return count('SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?', { t }) == 1
end
local function advance(s) Mock.clock = Mock.clock + s end
local function online(src, cid, bank)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.money = { cash = 0, bank = bank or 50000 }
    p.PlayerData.metadata.injail = 0
    p.PlayerData.metadata.bloodtype = 'AB+'
    Mock.fireEvent('QBCore:Server:PlayerLoaded', nil, p)
    return p
end
local F = function() return Config.Hospital.Facilities.pillbox end
local function bedPos(id)
    for _, d in pairs(F().departments) do for _, b in ipairs(d.beds) do if b.id == id then return vector3(b.coords.x, b.coords.y, b.coords.z) end end end
end
local COUNTER = Config.Hospital.Pharmacy.Counters.pillbox.coords
local ROOM = Config.Hospital.Surgery.Rooms[1].coords
local STASH = Config.Hospital.Pharmacy.Stashes.pillbox.id

BeforeEach = function()
    Mock.reset()
    advance(10000) -- the last test's rate limits are over
    Mock.players, Mock.coords = {}, {}
    Mock.invokingResource = nil
    Stash, Pockets = {}, {}
    online(PATIENT, PAT)
    online(NURSE, 'RDBNUR20').PlayerData.job = { name = 'ambulance', type = 'ems', onduty = true, grade = { level = 1 } } -- tier 3
    online(DOC, 'RDBDOC20').PlayerData.job = { name = 'ambulance', type = 'ems', onduty = true, grade = { level = 3 } }   -- tier 5, surgeon
    Mock.coords[PATIENT] = vector3(F().reception.coords.x, F().reception.coords.y, F().reception.coords.z)
    Mock.coords[NURSE] = vector3(F().reception.coords.x + 1, F().reception.coords.y, F().reception.coords.z)
    Mock.coords[DOC] = vector3(F().reception.coords.x - 1, F().reception.coords.y, F().reception.coords.z)
end

--- Checks the patient in and admits them to a bed (returns the admission id).
local function admitTo(dept, bed)
    local res = cb('checkIn', PATIENT, 'pillbox')
    assert_true(res.ok, 'check-in: ' .. tostring(res.message))
    Mock.coords[DOC] = bedPos(bed)
    Mock.coords[PATIENT] = bedPos(bed)
    local ad = cb('admit', DOC, res.admissionId, dept, bed)
    assert_true(ad.ok, 'admit: ' .. tostring(ad.message))
    return res.admissionId
end
local function discharge(id, orders)
    Mock.coords[DOC] = vector3(330.0, -588.0, 43.3)
    local d = cb('discharge', DOC, id, orders or {})
    assert_true(d.ok, 'discharge: ' .. tostring(d.message))
end

describe('migration v8 (hospital services, morgue, supplies)', function()
    it('applies after v7 on a fresh database, extends the 19G tables; a rerun applies nothing', function()
        assert_eq(versions(), '1,2,3,5,6,7,8')
        assert_eq(MySQL.scalar.await("SELECT name FROM pf_schema_migrations WHERE resource = 'pf-ambulancejob' AND version = 8"), 'hospital services, morgue, supplies')
        for _, t in ipairs({ 'pf_hosp_orders', 'pf_hosp_stays', 'pf_med_death_records', 'pf_hosp_supply_usage' }) do assert_true(tableExists(t), t) end
        for _, c in ipairs({ 'hospital_id', 'admission_id', 'units_per_fill', 'cancelled_by', 'idem_key' }) do assert_true(hasColumn('pf_hosp_prescriptions', c), c) end
        for _, c in ipairs({ 'kind', 'controlled', 'hospital_id', 'admission_id' }) do assert_true(hasColumn('pf_hosp_dispense_log', c), c) end
        -- 19G's columns are still there (extended, never recreated)
        for _, c in ipairs({ 'dispensed', 'interval_seconds', 'custody_ref' }) do assert_true(hasColumn('pf_hosp_prescriptions', c), c) end
        assert_true(RunMigrations('pf-ambulancejob', PFMed.Schema.Migrations))
        assert_eq(versions(), '1,2,3,5,6,7,8')
        -- the keys are unique
        local t = os.time()
        local ins = "INSERT INTO pf_hosp_prescriptions (citizenid, drug, dose, qty, prescriber_cid, state, created_at, expires_at, idem_key) VALUES ('K', 'x', '1', 1, 'D', 'active', ?, ?, 'k:rx:1')"
        MySQL.insert.await(ins, { t, t + 9 })
        assert_false((pcall(MySQL.insert.await, ins, { t, t + 9 })))
    end)
    it('a server at v7 gets v8, rerun-safe after a partial run (some columns and tables already there)', function()
        MySQL.query.await('DROP TABLE IF EXISTS `pf_hosp_stays`')
        MySQL.query.await('ALTER TABLE pf_hosp_dispense_log DROP COLUMN controlled')
        MySQL.query.await("DELETE FROM pf_schema_migrations WHERE resource = 'pf-ambulancejob' AND version = 8")
        assert_eq(versions(), '1,2,3,5,6,7')
        H = restart()
        Q = H.SQL
        assert_eq(versions(), '1,2,3,5,6,7,8')
        assert_true(tableExists('pf_hosp_stays'))
        assert_true(hasColumn('pf_hosp_dispense_log', 'controlled'))
        assert_true(hasColumn('pf_hosp_prescriptions', 'units_per_fill'))
    end)
end)

describe('pharmacy', function()
    it('a physician prescribes once per drug and admission; fills are reserved first, stock moves after', function()
        local id = admitTo('ward', 'w1')
        Mock.coords[DOC] = bedPos('w1')
        assert_eq(cb('rxPrescribe', NURSE, PATIENT, 'painkillers', 4, 2).error, 'no_permission', 'tier 3 cannot prescribe')
        local rx = cb('rxPrescribe', DOC, PATIENT, 'painkillers', 4, 2)
        assert_true(rx.ok, tostring(rx.message))
        advance(2)
        local again = cb('rxPrescribe', DOC, PATIENT, 'painkillers', 4, 2)
        assert_true(again.duplicate)
        assert_eq(again.prescriptionId, rx.prescriptionId)
        local row = Q.PhGetRx(rx.prescriptionId)
        assert_eq(row.idem_key, ('pf-ambulancejob:rx:%d:painkillers'):format(id))
        assert_eq(row.hospital_id, 'pillbox')
        assert_eq(tonumber(row.units_per_fill), 4)
        assert_eq(tonumber(row.qty), 2)
        -- away from the counter: refused; empty stock: the fill is given back, nothing logged
        Mock.coords[PATIENT] = vector3(330.0, -588.0, 43.3)
        assert_eq(cb('pharmacyCollect', PATIENT).error, 'too_far')
        Mock.coords[PATIENT] = COUNTER
        advance(5)
        assert_eq(cb('pharmacyCollect', PATIENT).error, 'conflict')
        assert_eq(tonumber(Q.PhGetRx(rx.prescriptionId).dispensed), 0)
        assert_eq(count('SELECT COUNT(*) FROM pf_hosp_dispense_log WHERE prescription_id = ?', { rx.prescriptionId }), 0)
        Stash[STASH] = { painkillers = 10 }
        advance(5)
        local c1 = cb('pharmacyCollect', PATIENT)
        assert_true(c1.ok, tostring(c1.message))
        assert_eq(c1.units, 4)
        assert_eq(Pockets[PATIENT].painkillers, 4)
        assert_eq(Stash[STASH].painkillers, 6)
        local log = MySQL.single.await('SELECT * FROM pf_hosp_dispense_log WHERE idem_key = ?', { ('pf-ambulancejob:rx:%d:1'):format(rx.prescriptionId) })
        assert_eq(log.kind, 'dispense')
        assert_eq(tonumber(log.qty), 4)
        assert_eq(log.hospital_id, 'pillbox')
        assert_eq(tonumber(log.admission_id), id)
        advance(5)
        assert_eq(cb('pharmacyCollect', PATIENT).error, 'too_soon', 'the refill interval')
        advance(24 * 3600)
        assert_true(cb('pharmacyCollect', PATIENT).ok)
        assert_eq(Q.PhGetRx(rx.prescriptionId).state, 'filled')
        advance(5)
        assert_eq(cb('pharmacyCollect', PATIENT).error, 'not_found')
        discharge(id)
    end)
    it('discharge orders carry prescriptions (physician), billed on the one bill; the record lists them', function()
        local id = admitTo('ward', 'w2')
        Mock.coords[NURSE] = vector3(330.0, -588.0, 43.3)
        assert_eq(cb('discharge', NURSE, id, { prescriptions = { { drug = 'antibiotics', units = 3 } } }).error, 'no_permission')
        assert_eq(cb('discharge', DOC, id, { prescriptions = { { drug = 'heroin', units = 3 } } }).error, 'bad_args')
        advance(2 * 3600)
        discharge(id, { prescriptions = { { drug = 'antibiotics', units = 3, fills = 2 }, { drug = 'crutches', units = 1 } } })
        local rows = MySQL.query.await('SELECT drug, qty, units_per_fill, idem_key FROM pf_hosp_prescriptions WHERE admission_id = ? ORDER BY drug', { id })
        assert_eq(#rows, 2)
        assert_eq(rows[1].drug, 'antibiotics')
        assert_eq(rows[1].idem_key, ('pf-ambulancejob:rx:%d:antibiotics'):format(id))
        local bill = MySQL.single.await('SELECT * FROM pf_hosp_bills WHERE admission_id = ?', { id })
        local drugLines = MySQL.query.await("SELECT label, qty, unit_price FROM pf_hosp_bill_lines WHERE bill_id = ? AND kind = 'drug' ORDER BY id", { bill.id })
        assert_eq(#drugLines, 2)
        local P = Config.Hospital.Pharmacy.Formulary
        assert_eq(tonumber(drugLines[1].qty) * tonumber(drugLines[1].unit_price) + tonumber(drugLines[2].qty) * tonumber(drugLines[2].unit_price),
            6 * P.antibiotics.price + P.crutches.price)
        assert_eq(bill.state, 'paid')
        local rec = PFMed.Diagnosis.GetMedicalRecord(PAT, { viewer = PATIENT, purpose = 'self' })
        assert_true(rec.ok, tostring(rec.message))
        assert_true(#rec.record.prescriptions >= 2)
    end)
    it('ward drugs: the controlled log is written before stock moves; no stock leaves no row; returns are logged', function()
        local id = admitTo('ward', 'w1')
        Mock.coords[NURSE] = COUNTER
        Stash[STASH] = { morphine = 1 }
        assert_eq(cb('pharmacyWithdraw', NURSE, 'morphine', 2, PATIENT).error, 'conflict')
        assert_eq(count("SELECT COUNT(*) FROM pf_hosp_dispense_log WHERE kind = 'withdraw' AND admission_id = ?", { id }), 0)
        Stash[STASH] = { morphine = 5 }
        advance(2)
        local w = cb('pharmacyWithdraw', NURSE, 'morphine', 2, PATIENT)
        assert_true(w.ok, tostring(w.message))
        assert_eq(Pockets[NURSE].morphine, 2)
        advance(2)
        assert_true(cb('pharmacyReturn', NURSE, 'morphine', 1).ok)
        assert_eq(Stash[STASH].morphine, 4)
        local log = exports['pf-ambulancejob']:GetControlledLog('pillbox')
        assert_true(log.ok)
        assert_eq(log.list[1].kind, 'return')
        assert_eq(log.list[2].kind, 'withdraw')
        assert_eq(log.list[2].admissionId, id)
        assert_eq(log.list[2].byCid, 'RDBNUR20')
        Mock.invokingResource = 'pf-hackscript'
        assert_eq(exports['pf-ambulancejob']:GetControlledLog('pillbox').error, 'not_allowed')
        Mock.invokingResource = nil
        discharge(id)
    end)
end)

describe('lab, imaging, surgery and stays on one admission', function()
    it('results come from the engine state; imaging confirms; surgery recovers the projectile; the bill prices each stay', function()
        local id = admitTo('ward', 'w3') -- w3 is in the imaging room
        local t0 = os.time()
        -- the state the tests read: a retained bullet, opioids and alcohol in the blood
        local inj = PFMed.Engine.AddInjury(PAT, { mechanism = 'firearm', type = 'gunshot', subtype = 'retained', region = 'thigh_l', severity = 3,
            attrs = { weapon = 453432689, caliber = 'SMALL_CALIBER', projectile = true }, attackerCid = 'RDBSHOOT' }, { key = 'spec:rdb20:gsw' })
        assert_true(inj ~= nil and inj.id ~= nil, 'injury')
        PFMed.Engine.AddToxin(PAT, 'opioid', 20)
        PFMed.Engine.AddToxin(PAT, 'ethanol', 0.12)

        -- lab: ordered by tier 4+, drawn by tier 3+ next to the patient, released when due
        Mock.coords[NURSE] = bedPos('w3')
        assert_eq(cb('labOrder', NURSE, PATIENT, 'cbc').error, 'no_permission', 'ordering needs a nurse')
        local orders = {}
        for _, test in ipairs({ 'cbc', 'tox', 'bac', 'blood_type' }) do
            advance(2)
            local o = cb('labOrder', DOC, PATIENT, test)
            assert_true(o.ok, test .. ': ' .. tostring(o.message))
            orders[test] = o.orderId
        end
        advance(2)
        assert_true(cb('labOrder', DOC, PATIENT, 'cbc').duplicate, 'one open order per test')
        for _, test in ipairs({ 'cbc', 'tox', 'bac', 'blood_type' }) do
            advance(2)
            local d = cb('labDraw', NURSE, orders[test])
            assert_true(d.ok, test .. ' draw: ' .. tostring(d.message))
        end
        -- not due yet: nothing released, nothing shown
        H.Lab.Tick(os.time())
        local view = cb('patientOrders', DOC, PATIENT)
        assert_true(view.ok)
        for _, o in ipairs(view.list) do if o.kind == 'lab' then assert_eq(o.result, nil) end end
        advance(700)
        local out = H.Lab.Tick(os.time())
        assert_eq(out[orders.cbc], 'resulted')
        local res = {}
        for _, o in ipairs(cb('patientOrders', DOC, PATIENT).list) do if o.kind == 'lab' then res[o.test] = o.result end end
        assert_eq(res.bac.values.bac, 0.12)
        assert_eq(res.blood_type.values.bloodType, 'AB+')
        assert_eq(table.concat(res.tox.values.positive, ','), 'ethanol,opioid')
        assert_true(res.cbc.values.hemoglobin <= 14.5 and res.cbc.values.hemoglobin > 5)
        assert_true(count("SELECT COUNT(*) FROM pf_med_findings WHERE citizenid = ? AND modality = 'labs' AND sign = 'tox_screen' AND value = 'opioid'", { PAT }) == 1)

        -- imaging: the patient must lie in the imaging bed; the x-ray confirms the diagnosis
        advance(2)
        local img = cb('imagingOrder', DOC, PATIENT, 'xray')
        assert_true(img.ok, tostring(img.message))
        local w3 = bedPos('w3')
        Mock.coords[PATIENT] = vector3(w3.x + 4.0, w3.y, w3.z)
        assert_eq(cb('imagingPerform', NURSE, img.orderId).error, 'invalid_state', 'out of bed')
        Mock.coords[PATIENT] = bedPos('w3')
        advance(3)
        local scan = cb('imagingPerform', NURSE, img.orderId)
        assert_true(scan.ok, tostring(scan.message))
        local found = false
        for _, f in ipairs(scan.findings) do if f.sign == 'retained_projectile' and f.certainty == 'confirmed' then found = true end end
        assert_true(found, 'retained projectile on the x-ray')
        assert_eq(count("SELECT COUNT(*) FROM pf_med_diagnoses WHERE citizenid = ? AND injury_id = ? AND status = 'confirmed' AND source = 'imaging'", { PAT, inj.id }), 1)

        -- ICU for two hours on the ward
        advance(3600 - 20)
        local lvl = cb('careLevel', DOC, id, 'icu')
        assert_true(lvl.ok, tostring(lvl.message))
        assert_eq(H.Stays.current[id].level, 'icu')
        -- a restart keeps the open stay and its level
        H = restart()
        Q = H.SQL
        assert_eq(H.Stays.current[id].level, 'icu')
        advance(2 * 3600)

        -- surgery: into the operating room (ED trauma bay bed), surgeon only, confirmed diagnosis only
        Mock.coords[DOC] = bedPos('ed1')
        Mock.coords[PATIENT] = bedPos('ed1')
        local ad = cb('admit', DOC, id, 'ed', 'ed1')
        assert_true(ad.ok, tostring(ad.message))
        assert_eq(H.Stays.current[id].level, 'ed')
        Mock.coords[DOC] = ROOM
        Mock.coords[NURSE] = ROOM
        Mock.reset()
        assert_eq(cb('surgery', NURSE, PATIENT, inj.id, 'surgery_trauma').error, 'no_permission', 'surgeons only')
        advance(3)
        assert_eq(cb('surgery', DOC, PATIENT, inj.id, 'surgery_neuro').error, 'bad_args', 'the operation must treat the injury')
        advance(3)
        local op = cb('surgery', DOC, PATIENT, inj.id, 'surgery_trauma')
        assert_true(op.ok, tostring(op.message))
        assert_true(op.projectileRecovered)
        local ev
        for _, e in ipairs(Mock.serverEvents) do if e.name == 'pf-ambulancejob:server:projectileRecovered' then ev = e end end
        assert_true(ev ~= nil, 'projectileRecovered raised')
        assert_eq(ev.args[1], PAT)
        local p = ev.args[2]
        assert_eq(p.injuryId, inj.id)
        assert_eq(p.caliber, 'SMALL_CALIBER')
        assert_eq(p.weaponHash, 453432689)
        assert_eq(p.attackerCid, 'RDBSHOOT')
        assert_eq(p.byCid, 'RDBDOC20')
        assert_true(type(p.at) == 'number')
        local tx = MySQL.single.await("SELECT * FROM pf_med_treatments WHERE citizenid = ? AND action = 'surgery_trauma'", { PAT })
        assert_eq(tx.location, 'or')
        assert_eq(tonumber(tx.admission_id), id)
        local stored = MySQL.single.await('SELECT treatments, attrs FROM pf_med_injuries WHERE id = ?', { inj.id })
        PFMed.Store.Flush()
        stored = MySQL.single.await('SELECT treatments, attrs FROM pf_med_injuries WHERE id = ?', { inj.id })
        assert_true(json.decode(stored.treatments).surgery ~= nil)
        assert_true(json.decode(stored.attrs).projectileRecovered ~= nil)
        advance(3)
        assert_eq(cb('surgery', DOC, PATIENT, inj.id, 'surgery_trauma').error, 'invalid_state', 'operated once')
        assert_eq(count("SELECT COUNT(*) FROM pf_hosp_orders WHERE citizenid = ? AND kind = 'procedure' AND state = 'resulted'", { PAT }), 1)

        -- 30 minutes later: discharged; the bill prices each stay (ward, ICU, ED) per started hour at its own rate
        advance(1800)
        discharge(id)
        local stays = MySQL.query.await('SELECT dept, level, started_at, ended_at, bill_id FROM pf_hosp_stays WHERE admission_id = ? ORDER BY id', { id })
        assert_eq(#stays, 3)
        assert_eq(stays[1].level, 'ward')
        assert_eq(stays[2].level, 'icu')
        assert_eq(stays[3].level, 'ed')
        for _, s in ipairs(stays) do assert_true(tonumber(s.ended_at) ~= nil, 'every stay ended') end
        local bill = MySQL.single.await('SELECT * FROM pf_hosp_bills WHERE admission_id = ?', { id })
        assert_eq(tonumber(stays[1].bill_id), tonumber(bill.id))
        local tariff = Config.Hospital.Tariff
        local beds = MySQL.query.await("SELECT qty, unit_price FROM pf_hosp_bill_lines WHERE bill_id = ? AND kind = 'bed' ORDER BY id", { bill.id })
        assert_eq(#beds, 3, 'one line per stay, no 17E single bed line')
        local rates = { tariff.BedHour.ward, tariff.BedHour.icu, tariff.BedHour.ed }
        for i, s in ipairs(stays) do
            local hours = math.max(1, math.ceil((tonumber(s.ended_at) - tonumber(s.started_at)) / 3600))
            assert_eq(tonumber(beds[i].qty), hours, 'started hours of stay ' .. i)
            assert_eq(tonumber(beds[i].unit_price), rates[i], 'rate of stay ' .. i)
        end
        assert_eq(tonumber(beds[3].qty), 1, 'the 30-minute ED stay is one started hour')
        local procs = MySQL.query.await("SELECT label, unit_price FROM pf_hosp_bill_lines WHERE bill_id = ? AND kind = 'procedure' ORDER BY id", { bill.id })
        local sumProc = 0
        for _, l in ipairs(procs) do sumProc = sumProc + tonumber(l.unit_price) end
        assert_eq(sumProc, tariff.Admission.checkin + tariff.Lab.cbc + tariff.Lab.tox + tariff.Lab.bac + tariff.Lab.blood_type + tariff.Imaging.xray
            + tariff.Treatments.surgery_trauma)
        assert_eq(count('SELECT COUNT(*) FROM pf_hosp_orders WHERE admission_id = ? AND bill_id = ?', { id, bill.id }), 5)
        -- charged once from the bank to society:ambulance under the bill's key
        assert_eq(bill.state, 'paid')
        local txs = MySQL.query.await('SELECT * FROM pf_transactions WHERE idempotency_key LIKE ?', { 'pf-ambulancejob:bill:' .. bill.id .. ':%' })
        assert_eq(#txs, 1)
        assert_eq(txs[1].to_account, 'society:ambulance')
        assert_eq(tonumber(txs[1].amount), tonumber(bill.total) - tonumber(bill.discount))
        assert_true(os.time() - t0 > 3 * 3600)
    end)
end)
