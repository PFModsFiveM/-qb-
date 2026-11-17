-- Batch 20 unit 20E, pf-government department management on a real database:
--   1. schema v7: the training, asset, asset event, payroll report and procurement tables and the
--      two period indexes exist, and every v7 step runs again without error (rerun-safe);
--   2. the asset register: registration (generated and given serials, keys, a serial conflict),
--      issue and return by serial with keys (duplicate, key_reused), state rules, lookups, lists,
--      history, a deleted holder's equipment marked lost;
--   3. training: a pass grants the course's qualification through the qualification store
--      (pf_gov_dept_qualifications, source 'training', expiry from validDays), a fail grants
--      nothing, the instructor rules, keys;
--   4. payroll reports: wages from the real ledger's 'wage' transfers (state wages and society
--      wages, other jobs left out, an unsettled wage apart), budget moves, shift hours clipped to
--      the period, a saved report written once;
--   5. the department app's SQL: the roster from the players table (JSON_VALUE), procurements.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
local states = { ['pf-justice'] = 'missing', ['pf-services'] = 'missing', ['pfm-houses'] = 'missing', ['pfm-phone'] = 'missing',
    ['pfm-management'] = 'missing', ['pf-devices'] = 'missing' }
function GetResourceState(name) return states[name] or 'started' end
vec3 = vec3 or vector3
vec4 = vec4 or vector4
GlobalState = {}

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
function GetCurrentResourceName() return 'pfm-banking' end
Config = nil
load_resource('pfm-banking/config.lua')
load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')
Mock.exportsByResource['pfm-banking'] = Mock.exportsByResource['__self']
Mock.exportsByResource['__self'] = nil
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end
assert(PFLedger.Start(), 'ledger start')
local bank = exports['pfm-banking']

RealDB.exec('[pfscripts]/pf-government/sql/install.sql')
function GetCurrentResourceName() return 'pf-government' end
QBCoreMock.Shared.Jobs = { government = { label = 'Government', grades = {} } }
Config = nil
load_resource('pfm-banking/payouts.lua')
for _, f in ipairs({ 'config.lua', 'server/core.lua', 'server/schema.lua', 'server/treasury.lua', 'server/budgets.lua',
    'server/departments/core.lua', 'server/departments/qualifications.lua', 'server/departments/shifts.lua',
    'server/departments/training.lua', 'server/departments/assets.lua', 'server/departments/payroll.lua',
    'server/apps/common.lua', 'server/apps/department.lua' }) do
    load_resource('[pfscripts]/pf-government/' .. f)
end
function NotifyGovernment() end
function DebugPrint() end
Mock.exportsByResource['pf-government'] = Mock.exportsByResource['__self']
Mock.exportsByResource['__self'] = nil
assert(GovSchema.Ensure(), 'government migrations')
InitializeTreasury()
InitializeBudgets()
local gov = exports['pf-government']
local D, App = GovDept, GovApps.Department

local function num(v) return tonumber(v) or 0 end
local function scalar(q, p) return MySQL.scalar.await(q, p or {}) end
local function rows(q, p) return MySQL.query.await(q, p or {}) or {} end

local function employ(src, cid, job, grade, onduty, isboss)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.job = { name = job, grade = { level = grade, name = 'G' .. grade, isboss = isboss or false }, isboss = isboss or false, onduty = onduty == true }
    MySQL.query.await([[INSERT INTO players (citizenid, license, name, money, charinfo, job, position, metadata)
        VALUES (?, ?, 'x', '{"bank":0,"cash":0}', ?, ?, '{}', '{}') ON DUPLICATE KEY UPDATE job = VALUES(job), charinfo = VALUES(charinfo)]],
        { cid, 'license:' .. cid, json.encode(p.PlayerData.charinfo), json.encode(p.PlayerData.job) })
    return p
end
local function saveOffline(cid, job, first)
    MySQL.query.await([[INSERT INTO players (citizenid, license, name, money, charinfo, job, position, metadata)
        VALUES (?, ?, 'x', '{"bank":0,"cash":0}', ?, ?, '{}', '{}') ON DUPLICATE KEY UPDATE job = VALUES(job)]],
        { cid, 'license:' .. cid, json.encode({ firstname = first or 'Off', lastname = 'Line' }), json.encode(job) })
end

local COP, LT, MED, CHIEF, OTHER = 1, 2, 3, 4, 5
local seq = 0
local C = {}
BeforeEach = function()
    Mock.reset()
    seq = seq + 1
    Mock.players, Mock.aces = {}, {}
    Mock.invokingResource = nil
    for k in pairs(D.Q.cache) do D.Q.cache[k] = nil end
    for k in pairs(D.S.open) do D.S.open[k] = nil end
    C = { cop = 'RCOP' .. seq, lt = 'RLT' .. seq, med = 'RMED' .. seq, chief = 'RCHF' .. seq, other = 'ROTH' .. seq }
    employ(COP, C.cop, 'police', 1, true)
    employ(LT, C.lt, 'police', 3, true)
    employ(MED, C.med, 'ambulance', 1, true)
    employ(CHIEF, C.chief, 'ambulance', 4, true, true)
    employ(OTHER, C.other, 'mechanic', 0, true)
end

local V7 = { 'pf_gov_dept_training', 'pf_gov_dept_assets', 'pf_gov_dept_asset_events', 'pf_gov_dept_payroll_reports', 'pf_gov_dept_procurements' }

describe('20E schema v7 (real DB)', function()
    it('creates the department management tables and indexes', function()
        for _, t in ipairs(V7) do
            assert_eq(num(scalar('SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?', { t })), 1, t)
        end
        assert_eq(num(scalar("SELECT MAX(version) FROM pf_schema_migrations WHERE resource = 'pf-government'")), 7)
        assert_true(num(scalar([[SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = DATABASE()
            AND TABLE_NAME = 'pf_gov_budget_transactions' AND INDEX_NAME = 'idx_gov_budget_tx_dept_at']])) > 0)
        assert_true(num(scalar([[SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = DATABASE()
            AND TABLE_NAME = 'pf_gov_dept_assets' AND INDEX_NAME = 'uq_da_serial' AND NON_UNIQUE = 0]])) > 0)
    end)

    it('every v7 step runs again without error (rerun-safe)', function()
        local v7
        for _, m in ipairs(GovSchema.Migrations) do if m.version == 7 then v7 = m end end
        assert_true(v7 ~= nil)
        for _, step in ipairs(v7.up) do MySQL.query.await(step, {}) end
        for _, t in ipairs(V7) do
            assert_eq(num(scalar('SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?', { t })), 1, t)
        end
    end)
end)

describe('20E asset register (real DB)', function()
    it('registers with a generated serial once per key; a given serial is unique across the city', function()
        local r = gov:RegisterAsset('police', { kind = 'radio', label = 'Radio' }, { key = 'rd:a:' .. seq, actor = { src = LT } })
        assert_true(r.ok, r.error)
        assert_true(r.asset.serial:match('^PD%-RAD%-[0-9A-Z]+$') ~= nil, r.asset.serial)
        assert_eq(r.asset.state, 'in_stock')
        local again = gov:RegisterAsset('police', { kind = 'radio' }, { key = 'rd:a:' .. seq, actor = { src = LT } })
        assert_true(again.duplicate)
        assert_eq(again.asset.serial, r.asset.serial)
        assert_eq(gov:RegisterAsset('police', { kind = 'taser' }, { key = 'rd:a:' .. seq, actor = { src = LT } }).error, 'key_reused')
        local given = gov:RegisterAsset('police', { kind = 'sidearm', serial = 'sn-' .. seq, item = 'weapon_pistol' }, { key = 'rd:b:' .. seq, actor = { src = LT } })
        assert_eq(given.asset.serial, ('SN-' .. seq))
        assert_eq(gov:RegisterAsset('ems', { kind = 'radio', serial = 'SN-' .. seq }, { key = 'rd:c:' .. seq, actor = { src = CHIEF } }).error, 'conflict')
        assert_eq(gov:RegisterAsset('police', { kind = 'radio' }, { key = 'rd:d:' .. seq, actor = { src = COP } }).error, 'no_permission')
        assert_eq(num(scalar("SELECT COUNT(*) FROM pf_gov_dept_asset_events e JOIN pf_gov_dept_assets a ON a.id = e.asset_id WHERE a.serial = ? AND e.event = 'register'", { r.asset.serial })), 1)
    end)

    it('issue and return by serial with keys, state rules, lookups and history', function()
        local sn = 'IR-' .. seq
        assert_true(gov:RegisterAsset('police', { kind = 'bodycam', serial = sn }, { key = 'ir:r:' .. seq, actor = { src = LT } }).ok)
        local iss = gov:IssueAsset(sn, C.cop, { key = 'ir:i:' .. seq, actor = { src = COP }, ref = 'armory:1' })
        assert_true(iss.ok, iss.error)
        assert_eq(iss.asset.state, 'issued')
        assert_eq(iss.asset.holder, C.cop)
        assert_eq(iss.asset.ref, 'armory:1')
        assert_true(gov:IssueAsset(sn, C.cop, { key = 'ir:i:' .. seq, actor = { src = COP } }).duplicate)
        assert_eq(gov:IssueAsset(sn, C.lt, { key = 'ir:i:' .. seq, actor = { src = LT } }).error, 'key_reused')
        local busy = gov:IssueAsset(sn, C.lt, { key = 'ir:i2:' .. seq, actor = { src = LT } })
        assert_eq(busy.error, 'invalid_state')
        assert_eq(busy.state, 'issued')
        local got = gov:GetAsset(sn:lower())
        assert_eq(got.asset.holder, C.cop)
        assert_eq(#gov:ListAssets('police', { holder = C.cop, state = 'issued' }).list, 1)
        assert_eq(gov:ReturnAsset(sn, { key = 'ir:x:' .. seq, actor = { src = MED } }).error, 'no_permission')
        local ret = gov:ReturnAsset(sn, { key = 'ir:ret:' .. seq, actor = { src = COP }, to = 'maintenance' })
        assert_true(ret.ok, ret.error)
        assert_eq(ret.holder, C.cop)
        assert_eq(ret.asset.state, 'maintenance')
        assert_eq(ret.asset.holder, nil)
        assert_true(gov:ReturnAsset(sn, { key = 'ir:ret:' .. seq, actor = { src = COP }, to = 'maintenance' }).duplicate)
        assert_eq(D.A.Move(sn, 'repair', { key = 'ir:rep:' .. seq, actor = { src = COP } }).error, 'no_permission')
        assert_true(D.A.Move(sn, 'repair', { key = 'ir:rep:' .. seq, actor = { src = LT } }).ok)
        assert_true(D.A.Move(sn, 'retire', { key = 'ir:ret2:' .. seq, actor = { src = LT } }).ok)
        assert_eq(gov:IssueAsset(sn, C.cop, { key = 'ir:i3:' .. seq, actor = { src = COP } }).error, 'invalid_state')
        local hist = D.A.History(sn)
        assert_eq(#hist.list, 5)
        assert_eq(hist.list[1].event, 'retire')
        assert_eq(hist.list[4].event, 'issue')
        assert_eq(num(scalar("SELECT COUNT(*) FROM pf_gov_dept_audit WHERE target = ? AND action LIKE 'asset_%'", { sn })), 5)
    end)

    it('a deleted character\'s equipment is marked lost', function()
        local sn = 'DL-' .. seq
        assert_true(gov:RegisterAsset('police', { kind = 'radio', serial = sn }, { key = 'dl:r:' .. seq, actor = { src = LT } }).ok)
        assert_true(gov:IssueAsset(sn, C.cop, { key = 'dl:i:' .. seq, actor = { src = LT } }).ok)
        assert_eq(D.A.RemoveCharacter(C.cop), 1)
        local a = gov:GetAsset(sn).asset
        assert_eq(a.state, 'lost')
        assert_eq(a.holder, nil)
        assert_true(D.A.Move(sn, 'found', { key = 'dl:f:' .. seq, actor = { src = LT } }).ok)
        assert_eq(gov:GetAsset(sn).asset.state, 'in_stock')
    end)
end)

describe('20E training (real DB)', function()
    it('a pass grants the qualification through the qualification store; a fail grants nothing', function()
        local r = gov:RecordTraining(C.cop, 'k9_course', 'pass', { key = 'tr:a:' .. seq, actor = { src = LT }, score = 88 })
        assert_true(r.ok, r.error)
        assert_true(r.granted)
        local q = MySQL.single.await('SELECT state, source, idem_key FROM pf_gov_dept_qualifications WHERE citizenid = ? AND qual = ?', { C.cop, 'k9' })
        assert_eq(q.state, 'granted')
        assert_eq(q.source, 'training')
        assert_eq(q.idem_key, ('pf-government:training:%d:grant'):format(r.id))
        assert_true((gov:HasQualification(C.cop, 'k9')))
        assert_eq(num(scalar('SELECT qual_granted FROM pf_gov_dept_training WHERE id = ?', { r.id })), 1)
        local dup = gov:RecordTraining(C.cop, 'k9_course', 'pass', { key = 'tr:a:' .. seq, actor = { src = LT } })
        assert_true(dup.duplicate)
        assert_eq(num(scalar('SELECT COUNT(*) FROM pf_gov_dept_training WHERE citizenid = ?', { C.cop })), 1)
        local f = gov:RecordTraining(C.cop, 'swat_course', 'fail', { key = 'tr:b:' .. seq, actor = { src = LT } })
        assert_true(f.ok)
        assert_false(f.granted)
        assert_false((gov:HasQualification(C.cop, 'swat')))
        assert_eq(#gov:ListTraining(C.cop).list, 2)
    end)

    it('a timed course expires the granted qualification; instructor rules', function()
        local now = os.time()
        local r = gov:RecordTraining(C.cop, 'firearms_requal', 'pass', { key = 'tr:c:' .. seq, actor = { src = LT } })
        assert_true(r.ok)
        assert_false(r.granted, 'firearms_requal grants no qualification')
        assert_true(r.expiresAt >= now + 180 * 86400 - 5)
        -- an EMT (no physician qualification) cannot teach the paramedic course
        employ(6, 'RMED2' .. seq, 'ambulance', 0, true)
        assert_eq(gov:RecordTraining('RMED2' .. seq, 'paramedic_course', 'pass', { key = 'tr:d:' .. seq, actor = { src = MED } }).error, 'no_permission')
        -- the paramedic (grade 1, implied paramedic) may teach the EMT course
        local e = gov:RecordTraining('RMED2' .. seq, 'emt_course', 'pass', { key = 'tr:e:' .. seq, actor = { src = MED } })
        assert_true(e.ok, e.error)
        assert_eq(scalar('SELECT source FROM pf_gov_dept_qualifications WHERE citizenid = ? AND qual = ?', { 'RMED2' .. seq, 'emt' }), 'training')
        assert_eq(gov:RecordTraining(C.other, 'emt_course', 'pass', { key = 'tr:f:' .. seq, actor = { src = CHIEF } }).error, 'invalid_state')
        assert_eq(gov:RecordTraining(C.lt, 'k9_course', 'pass', { key = 'tr:g:' .. seq, actor = { src = LT } }).error, 'no_permission')
    end)
end)

describe('20E payroll report (real DB)', function()
    it('wages from the ledger, budget moves and shift hours for a period; saved once', function()
        local now = os.time()
        local from, to = now - 7200, now + 3600
        local w1, w2, w3 = 'RW1' .. seq, 'RW2' .. seq, 'RW3' .. seq
        saveOffline(w1, { name = 'police', grade = { level = 1, name = 'Officer' } }, 'Ada')
        saveOffline(w2, { name = 'police', grade = { level = 2, name = 'Sergeant' } }, 'Bo')
        saveOffline(w3, { name = 'mechanic', grade = { level = 0 } }, 'Cy')
        bank:EnsureSocietyAccount('police')
        MySQL.update.await("UPDATE bank_accounts SET account_balance = 100000 WHERE account_name = 'police'", {})
        -- what pfm-core PayPaycheck sends: state wages and society wages
        assert_true(bank:Transfer({ from = 'system:paycheck', to = 'player:' .. w1 .. ':bank', amount = 150, key = 'paycheck:' .. w1 .. ':1:' .. seq,
            kind = 'wage', reason = 'Employee Paycheck', actor = w1, metadata = { job = 'police' } }).ok)
        assert_true(bank:Transfer({ from = 'system:paycheck', to = 'player:' .. w1 .. ':bank', amount = 150, key = 'paycheck:' .. w1 .. ':2:' .. seq,
            kind = 'wage', reason = 'Employee Paycheck', actor = w1, metadata = { job = 'police' } }).ok)
        assert_true(bank:Transfer({ from = 'society:police', to = 'player:' .. w2 .. ':bank', amount = 200, key = 'paycheck:' .. w2 .. ':1:' .. seq,
            kind = 'wage', reason = 'Employee Paycheck', actor = w2, metadata = { job = 'police' } }).ok)
        -- another job's state wage is not police payroll; an unsettled wage is shown apart
        assert_true(bank:Transfer({ from = 'system:paycheck', to = 'player:' .. w3 .. ':bank', amount = 90, key = 'paycheck:' .. w3 .. ':1:' .. seq,
            kind = 'wage', metadata = { job = 'mechanic' } }).ok)
        MySQL.insert.await([[INSERT INTO pf_transactions (tx_id, idempotency_key, kind, from_account, to_account, amount, state, metadata)
            VALUES (?, ?, 'wage', 'society:police', ?, 75, 'debited', '{"job":"police"}')]], { 'tx' .. seq .. 'p', 'paycheck:' .. w2 .. ':2:' .. seq, 'player:' .. w2 .. ':bank' })
        -- the harness clock is not the database clock: date the ledger rows inside the period
        MySQL.update.await("UPDATE pf_transactions SET created_at = FROM_UNIXTIME(?) WHERE kind = 'wage' AND idempotency_key LIKE ?", { now - 100, 'paycheck:%:' .. seq })
        -- budget moves of the department, one outside the period, one pending keyed move
        MySQL.insert.await([[INSERT INTO pf_gov_budget_transactions (department, month_key, transaction_type, category, amount, created_at)
            VALUES ('police', '2026-11', 'treasury_funding', 'monthly', 5000, FROM_UNIXTIME(?)), ('police', '2026-11', 'society_spend', 'equipment', 1200, FROM_UNIXTIME(?)),
            ('police', '2026-11', 'society_spend', 'equipment', 999, FROM_UNIXTIME(?))]], { now - 60, now - 30, from - 86400 })
        MySQL.insert.await([[INSERT INTO pf_gov_budget_transactions (department, month_key, transaction_type, category, amount, idem_key, state, created_at)
            VALUES ('police', '2026-11', 'society_spend', 'fleet', 300, ?, 'pending', FROM_UNIXTIME(?))]], { 'pr:pend:' .. seq, now - 10 })
        -- shifts: one inside, one started before the period (clipped), one of another department
        MySQL.insert.await([[INSERT INTO pf_gov_dept_shifts (citizenid, dept, job, grade, started_at, ended_at, end_reason) VALUES
            (?, 'police', 'police', 1, ?, ?, 'duty_off'), (?, 'police', 'police', 1, ?, ?, 'duty_off'), (?, 'ems', 'ambulance', 1, ?, ?, 'duty_off')]],
            { w1, now - 3600, now - 1800, w1, from - 3600, from + 1800, w2, now - 3600, now })
        local res = D.P.Build('police', from, to)
        assert_true(res.ok, res.error)
        local rep = res.report
        local by = {}
        for _, e in ipairs(rep.employees) do by[e.cid] = e end
        assert_eq(by[w1].wagesPaid, 300)
        assert_eq(by[w1].paychecks, 2)
        assert_eq(by[w1].hours, 1)
        assert_eq(by[w1].shifts, 2)
        assert_eq(by[w1].name, 'Ada Line')
        assert_eq(by[w1].gradeName, 'Officer')
        assert_eq(by[w2].wagesPaid, 200)
        assert_eq(by[w2].wagesPending, 75)
        assert_eq(by[w2].hours, 0, 'the EMS shift is not police time')
        assert_eq(by[w3], nil, 'a mechanic wage is not police payroll')
        assert_eq(rep.totals.wagesPaid, 500)
        assert_eq(rep.totals.fromState, 300)
        assert_eq(rep.totals.fromSociety, 200)
        assert_eq(rep.totals.wagesPending, 75)
        assert_eq(rep.totals.fundingIn, 5000)
        assert_eq(rep.totals.spendOut, 1200)
        assert_eq(rep.totals.pendingMoves, 300)
        assert_true(rep.partial)
        -- a period still running cannot be saved; an ended one is saved once
        assert_eq(D.P.Save('police', from, to, C.lt).error, 'invalid_state')
        local s1 = D.P.Save('police', from, now - 1, C.lt)
        assert_true(s1.ok, s1.error)
        assert_eq(s1.saved.wagesTotal, 500)
        assert_true(D.P.Save('police', from, now - 1, C.lt).duplicate)
        assert_eq(num(scalar('SELECT COUNT(*) FROM pf_gov_dept_payroll_reports WHERE dept = ?', { 'police' })), 1)
        local full = D.P.Saved('police', s1.saved.id)
        assert_eq(full.saved.report.totals.wagesPaid, 500)
        assert_eq(D.P.Build('police', from, from + 100 * 86400).error, 'bad_args')
        MySQL.update.await('DELETE FROM pf_gov_dept_payroll_reports', {})
    end)
end)

describe('20E department app SQL (real DB)', function()
    it('the roster reads the department\'s jobs from the players table; procurements list', function()
        saveOffline('ROFF' .. seq, { name = 'police', grade = { level = 0, name = 'Recruit' } }, 'Off')
        local r = App.roster(LT)
        assert_true(r.ok, r.error)
        local by = {}
        for _, e in ipairs(r.list) do by[e.cid] = e end
        assert_true(by[C.cop] ~= nil and by[C.cop].online)
        assert_true(by['ROFF' .. seq] ~= nil and not by['ROFF' .. seq].online)
        assert_eq(by[C.med], nil)
        assert_eq(App.roster(COP).error, 'no_permission')
        MySQL.insert.await([[INSERT INTO pf_gov_dept_procurements (dept, buyer_id, store_order_id, method, items, total, state, by_cid, at, idem_key)
            VALUES ('police', 'police:mrpd_armory', 7, 'trucking', '[{"name":"radio","quantity":2}]', 900, 'paid', ?, ?, ?)]], { C.lt, os.time(), 'pc:' .. seq })
        local p = App.procurements(LT)
        assert_true(p.ok, p.error)
        assert_eq(p.list[1].buyer, 'police:mrpd_armory')
        assert_eq(p.list[1].items[1].quantity, 2)
        local b = App.budget(LT)
        assert_true(b.ok, b.error)
        assert_eq(b.dept, 'police')
    end)
end)
