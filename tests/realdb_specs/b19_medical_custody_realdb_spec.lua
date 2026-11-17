-- pf-ambulancejob medical care in custody (batch 19G) on a real database: migration v7 (custody
-- columns on pf_hosp_admissions, pf_med_screenings, pf_med_custody_care, pf_med_custody_reports,
-- pf_hosp_prescriptions, pf_hosp_dispense_log) on a fresh database and on one at v6, rerun-safe;
-- one active care per citizen (UNIQUE active_cid), close once; the screening key; the prescription
-- dose reservation (two takers of one dose: one wins), undo and the per-dose dispense key; and the
-- whole escorted-transfer flow on real rows (pf-justice mocked by its contract): transfer, report,
-- restart (care relinked from the rows), discharge -> ReturnCustody, care closed, no bill.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
STARTED = { ['pf-justice'] = true }
function GetResourceState(res) return STARTED[res] and 'started' or 'missing' end
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
QBCoreMock.Commands.Add = function() end

load_resource('pfm-core/server/migrations.lua')
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end

-- pf-justice by contract (15C TransferCustody / ReturnCustody / AddCustodyLog / GetCustody / IsIncarcerated)
JU = { custody = { RDBHELD = { id = 501, state = 'held', facility = 'mrpd_holding' } }, orders = { RDBINM = { id = 601, facility = 'bolingbroke' } }, calls = {} }
local function juCalls(name) local n = 0 for _, c in ipairs(JU.calls) do if c == name then n = n + 1 end end return n end
Mock.exportsByResource['pf-justice'] = {
    GetCustody = function(_, who)
        local c = JU.custody[who]
        return { ok = true, custody = c and { id = c.id, state = c.state, facility = c.facility } or nil }
    end,
    IsIncarcerated = function(_, who) local o = JU.orders[who] if not o then return false end return true, o.id, o.facility end,
    TransferCustody = function(_, id) JU.calls[#JU.calls + 1] = 'TransferCustody' for _, c in pairs(JU.custody) do if c.id == id then c.prev, c.state = c.state, 'hospital' end end return { ok = true } end,
    ReturnCustody = function(_, id) JU.calls[#JU.calls + 1] = 'ReturnCustody' for _, c in pairs(JU.custody) do if c.id == id and c.state == 'hospital' then c.state = c.prev end end return { ok = true } end,
    AddCustodyLog = function() JU.calls[#JU.calls + 1] = 'AddCustodyLog' return { ok = true, logId = 1 } end,
}
Stash = {}
Mock.exportsByResource['pfm-inventory'] = {
    RemoveItem = function(_, id, item, n) local s = Stash[id] or {} if (s[item] or 0) < (n or 1) then return false end s[item] = s[item] - (n or 1) return true end,
    AddItem = function(_, id, item, n) if type(id) == 'string' then Stash[id] = Stash[id] or {} Stash[id][item] = (Stash[id][item] or 0) + (n or 1) end return true end,
    CreateInventory = function(_, id) Stash[id] = Stash[id] or {} end,
    OpenInventory = function() end,
}

function GetCurrentResourceName() return 'pf-ambulancejob' end
Config = nil
load_resource('pfm-banking/payouts.lua')
local AJ = '[pfscripts]/pf-ambulancejob/'
for _, f in ipairs({ 'config.lua', 'config_medical.lua', 'config_hospital.lua', 'shared/framework.lua', 'shared/medical/anatomy.lua',
    'shared/medical/injuries.lua', 'shared/medical/physiology_model.lua', 'shared/medical/effects_model.lua', 'server/main.lua' }) do
    load_resource(AJ .. f)
end

-- (re)loads the server modules, as a resource restart does: empty memory, same database
local function restart()
    Mock.eventHandlers['pf-ambulancejob:server:admissionChanged'] = nil
    Mock.eventHandlers['QBCore:Server:PlayerLoaded'] = nil
    Mock.eventHandlers['pf-justice:server:orderCreated'] = nil
    PFHospital = nil
    for _, f in ipairs({ 'server/medical/schema.lua', 'server/medical/store.lua', 'server/medical/engine.lua', 'server/medical/downstate.lua',
        'server/medical/effects.lua', 'server/medical/api.lua', 'server/medical/recovery.lua', 'server/hospital/facility.lua',
        'server/hospital/beds.lua', 'server/hospital/admissions.lua', 'server/hospital/billing.lua', 'server/hospital/ai_care.lua',
        'server/hospital/custody.lua' }) do
        load_resource(AJ .. f)
    end
    Mock.exportsByResource['pf-ambulancejob'] = Mock.exportsByResource['__self']
    PFMed.Engine.Random = function() return 0.5 end
    assert(PFMed.Schema.Start(), 'medical tables')
    assert(PFHospital.Admissions.Start(), 'hospital ready')
    assert(PFHospital.Custody.Start(), 'custody care ready')
    return PFHospital
end

local function versions()
    local out = {}
    for _, r in ipairs(MySQL.query.await("SELECT version FROM pf_schema_migrations WHERE resource = 'pf-ambulancejob' ORDER BY version")) do out[#out + 1] = tonumber(r.version) end
    return table.concat(out, ',')
end
local function count(sql, params) return tonumber(MySQL.scalar.await(sql, params)) or 0 end
local function hasColumn(t, c)
    return count('SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = ?', { t, c }) == 1
end
local NEW_TABLES = { 'pf_med_screenings', 'pf_med_custody_care', 'pf_med_custody_reports', 'pf_hosp_prescriptions', 'pf_hosp_dispense_log' }

local H = restart()
local Q = H.SQL

local INMATE, MEDIC, OFFICER, HELD = 1, 2, 3, 4
local function online(src, cid)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.metadata.injail = 0
    Mock.fireEvent('QBCore:Server:PlayerLoaded', nil, p)
    return p
end
local function cb(name, src, ...) return Mock.callCallback('pf-ambulancejob:server:' .. name, src, ...) end
BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 10000
    Mock.players, Mock.coords = {}, {}
    online(INMATE, 'RDBINM')
    online(MEDIC, 'RDBMED').PlayerData.job = { name = 'ambulance', type = 'ems', onduty = true, grade = { level = 2 } }
    online(OFFICER, 'RDBCOP').PlayerData.job = { name = 'corrections', type = 'corrections', onduty = true, grade = { level = 1 } }
    online(HELD, 'RDBHELD')
end

describe('migration v7 (custody care)', function()
    it('applies after v6 on a fresh database; a rerun applies nothing', function()
        assert_eq(versions(), '1,2,3,5,6,7,8') -- v8: batch 20 hospital services (extends the prescription tables)
        for _, t in ipairs(NEW_TABLES) do assert_eq(count('SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?', { t }), 1, t) end
        assert_true(hasColumn('pf_hosp_admissions', 'custody_ref'))
        assert_true(hasColumn('pf_hosp_admissions', 'escort_cid'))
        assert_true(RunMigrations('pf-ambulancejob', PFMed.Schema.Migrations))
        assert_eq(count("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = 'pf-ambulancejob'"), 7)
        assert_eq(MySQL.scalar.await("SELECT name FROM pf_schema_migrations WHERE resource = 'pf-ambulancejob' AND version = 7"), 'custody care')
    end)
    it('a server at v6 gets only v7, rerun-safe after a partial run (columns already there)', function()
        for _, t in ipairs(NEW_TABLES) do MySQL.query.await('DROP TABLE IF EXISTS `' .. t .. '`') end
        MySQL.query.await('ALTER TABLE pf_hosp_admissions DROP COLUMN escort_cid')
        MySQL.query.await("DELETE FROM pf_schema_migrations WHERE resource = 'pf-ambulancejob' AND version IN (7, 8)")
        assert_eq(versions(), '1,2,3,5,6')
        H = restart()
        Q = H.SQL
        assert_eq(versions(), '1,2,3,5,6,7,8')
        assert_true(hasColumn('pf_hosp_admissions', 'escort_cid'))
        assert_true(hasColumn('pf_hosp_admissions', 'custody_ref'))
    end)
end)

describe('care rows', function()
    it('one active care per citizen; close once; the closed row frees the citizen', function()
        local t = os.time()
        local id = Q.InsertCare({ citizenid = 'RDBX', kind = 'marked', custody_id = 9, facility = 'mrpd_holding', created_at = t, idem_key = 'k:care:1' })
        assert_true(tonumber(id) ~= nil)
        local ok = pcall(Q.InsertCare, { citizenid = 'RDBX', kind = 'marked', created_at = t })
        assert_false(ok, 'a second active care is refused by UNIQUE active_cid')
        assert_eq(Q.ActiveCareOf('RDBX').idem_key, 'k:care:1')
        assert_eq(Q.UpdateCare(id, { kind = 'transfer', custody_id = 9, facility = 'mrpd_holding', admission_id = 3, hospital_id = 'pillbox', escort_cid = 'C1', ju_transfer = true }), 1)
        local r = MySQL.single.await('SELECT * FROM pf_med_custody_care WHERE id = ?', { id })
        assert_eq(r.kind, 'transfer')
        assert_eq(tonumber(r.ju_transfer), 1)
        assert_eq(Q.CloseCare(id, 'returned', 'discharged', t), 1)
        assert_eq(Q.CloseCare(id, 'cleared', 'again', t), 0, 'closes once')
        assert_eq(Q.UpdateCare(id, { kind = 'marked' }), 0, 'a closed care is not rewritten')
        assert_eq(Q.ActiveCareOf('RDBX'), nil)
        assert_true(tonumber(Q.InsertCare({ citizenid = 'RDBX', kind = 'marked', created_at = t })) ~= nil, 'a new care after the close')
        assert_eq(Q.FindCareByKey('k:care:1').state, 'returned')
        Q.InsertCareReport({ care_id = id, citizenid = 'RDBX', kind = 'escort_away', detail = 'x', at = t })
        assert_eq(#Q.ListCareReports(id), 1)
    end)
    it('the screening key is unique; the latest screening in the window is read', function()
        local t = os.time()
        Q.InsertScreening({ citizenid = 'RDBS', context = 'booking', result = 'fit', fit_for_work = true, infirmary_needed = false, restrictions = '[]', at = t - 10, idem_key = 'scr:1' })
        assert_false((pcall(Q.InsertScreening, { citizenid = 'RDBS', context = 'booking', result = 'fit', at = t, idem_key = 'scr:1' })))
        Q.InsertScreening({ citizenid = 'RDBS', context = 'infirmary', result = 'hospital_required', fit_for_work = false, infirmary_needed = true, at = t })
        local latest = Q.LatestScreening('RDBS', t - 100)
        assert_eq(latest.result, 'hospital_required')
        assert_eq(tonumber(latest.fit_for_work), 0)
        assert_eq(Q.LatestScreening('RDBS', t + 1), nil)
        assert_eq(Q.FindScreeningByKey('scr:1').context, 'booking')
    end)
end)

describe('prescription SQL', function()
    it('a dose is reserved once (two takers of dose n: one wins), the last fills it, undo gives it back', function()
        local t = os.time()
        local id = Q.InsertRx({ citizenid = 'RDBRX', drug = 'painkillers', dose = '1 tablet', qty = 2, controlled = false, prescriber_cid = 'DOC',
            created_at = t, expires_at = t + 3600, interval_seconds = 60, custody_ref = 'order:1' })
        assert_eq(#Q.ActiveRx('RDBRX', t), 1)
        assert_eq(Q.ReserveDose(id, 0, t), 1)
        assert_eq(Q.ReserveDose(id, 0, t), 0, 'the second taker of dose 1 loses')
        Q.InsertDispense({ prescription_id = id, citizenid = 'RDBRX', drug = 'painkillers', qty = 1, by_cid = 'infirmary', stash = 's', at = t, dose_no = 1, idem_key = 'pf-ambulancejob:rx:' .. id .. ':1' })
        assert_false((pcall(Q.InsertDispense, { prescription_id = id, citizenid = 'RDBRX', drug = 'painkillers', qty = 1, by_cid = 'x', stash = 's', at = t, idem_key = 'pf-ambulancejob:rx:' .. id .. ':1' })))
        assert_eq(Q.ReserveDose(id, 1, t + 60), 1)
        local r = Q.GetRx(id)
        assert_eq(r.state, 'filled')
        assert_eq(tonumber(r.dispensed), 2)
        assert_eq(Q.UndoDose(id, 2, t), 1)
        r = Q.GetRx(id)
        assert_eq(r.state, 'active')
        assert_eq(tonumber(r.dispensed), 1)
        assert_eq(tonumber(r.last_dispensed_at), t)
        assert_eq(Q.DeleteDispense('pf-ambulancejob:rx:' .. id .. ':1'), 1)
        assert_eq(Q.CancelRx(id), 1)
        assert_eq(Q.CancelRx(id), 0)
        local id2 = Q.InsertRx({ citizenid = 'RDBRX', drug = 'bandage', dose = '1', qty = 1, prescriber_cid = 'DOC', created_at = t, expires_at = t + 5, interval_seconds = 0 })
        assert_true(Q.ExpireRx(t + 10) >= 1)
        assert_eq(Q.GetRx(id2).state, 'expired')
    end)
    it('the dose callback writes the dispense row with its key and moves the item', function()
        Mock.coords[MEDIC] = vector3(1766.9, 2594.8, 45.66)
        Mock.coords[INMATE] = vector3(1767.9, 2594.8, 45.66)
        local res = cb('custodyPrescribe', MEDIC, INMATE, 'painkillers', 3, 2)
        assert_true(res.ok, tostring(res.message))
        Stash.pf_infirmary_bolingbroke = { painkillers = 2 }
        local d = cb('custodyDose', INMATE)
        assert_true(d.ok, tostring(d.message))
        assert_eq(count('SELECT COUNT(*) FROM pf_hosp_dispense_log WHERE idem_key = ?', { ('pf-ambulancejob:rx:%d:1'):format(res.prescriptionId) }), 1)
        assert_eq(Stash.pf_infirmary_bolingbroke.painkillers, 1)
        assert_eq(tonumber(Q.GetRx(res.prescriptionId).dispensed), 1)
    end)
end)

describe('escorted transfer on real rows', function()
    it('transfer, report, restart (care relinked), discharge -> custody returned, care closed, no bill', function()
        Mock.coords[HELD] = vector3(460.0, -995.0, 24.9)
        Mock.coords[OFFICER] = vector3(468.0, -995.0, 24.9)
        local res = cb('custodyTransfer', OFFICER, HELD, 'pillbox')
        assert_true(res.ok, tostring(res.message))
        local a = MySQL.single.await('SELECT * FROM pf_hosp_admissions WHERE id = ?', { res.admissionId })
        assert_eq(a.custody_ref, 'custody:501')
        assert_eq(a.escort_cid, 'RDBCOP')
        local care = Q.ActiveCareOf('RDBHELD')
        assert_eq(care.kind, 'transfer')
        assert_eq(tonumber(care.admission_id), res.admissionId)
        assert_eq(tonumber(care.ju_transfer), 1)
        assert_eq(JU.custody.RDBHELD.state, 'hospital')
        -- the escort stays behind: reported (once)
        Mock.coords[HELD] = vector3(330.0, -588.0, 43.3)
        H.Admissions.Tick(os.time())
        Mock.clock = Mock.clock + Config.Hospital.Custody.EscortGraceSeconds
        H.Admissions.Tick(os.time())
        assert_eq(count("SELECT COUNT(*) FROM pf_med_custody_reports WHERE citizenid = 'RDBHELD' AND kind = 'escort_away'"), 1)
        -- a restart keeps the care and the link
        H = restart()
        Q = H.SQL
        assert_eq(H.Custody.Of('RDBHELD').admission_id, res.admissionId)
        assert_eq(H.Admissions.ById(res.admissionId).custody_ref, 'custody:501')
        Mock.coords[MEDIC] = vector3(330.0, -588.0, 43.3)
        local d = cb('discharge', MEDIC, res.admissionId, {})
        assert_true(d.ok, tostring(d.message))
        assert_eq(juCalls('ReturnCustody'), 1)
        assert_eq(JU.custody.RDBHELD.state, 'held')
        assert_eq(Q.ActiveCareOf('RDBHELD'), nil)
        assert_eq(MySQL.single.await('SELECT state FROM pf_med_custody_care WHERE id = ?', { care.id }).state, 'returned')
        assert_eq(count('SELECT COUNT(*) FROM pf_hosp_bills WHERE admission_id = ?', { res.admissionId }), 0, 'custody care is not billed')
        assert_eq(count("SELECT COUNT(*) FROM pf_med_screenings WHERE citizenid = 'RDBHELD' AND context = 'infirmary'"), 1, 're-screened at discharge')
    end)
end)
