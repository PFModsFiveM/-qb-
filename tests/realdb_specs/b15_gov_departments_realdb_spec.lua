-- Batch 15 unit 15I, pf-government department core on a real database:
--   1. the v6 tables exist after the migrations (15E writes them; this unit only uses them);
--   2. qualifications: implied by the live or saved job with no rows; a grant and a revocation are
--      one row per citizen and qualification (UNIQUE), the revocation overrides the implied one, a
--      timed revocation lapses; keys: duplicate, key_reused, and a key displaced from the row is
--      found again in the audit (JSON_EXTRACT on the detail);
--   3. shifts from the duty events: open, duty_off, job_change, dropped, incarcerated (D1), the
--      start-up close as 'restart' capped at MaxShiftHours, ListShifts filters/cursor/limit;
--   4. the department audit, the retention sweep (DELETE ... LIMIT) and deleted characters.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
local states = { ['pf-justice'] = 'started' }
function GetResourceState(name) return states[name] or 'missing' end
vec3 = vec3 or vector3
vec4 = vec4 or vector4
GlobalState = {}

local T = 1800000000
local realTime = os.time
os.time = function(t) if t then return realTime(t) end return T end

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('[pfscripts]/pf-government/sql/install.sql')
function GetCurrentResourceName() return 'pf-government' end
load_resource('pfm-core/server/migrations.lua')
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end
QBCoreMock.Functions.GetPlayersByJob = function(job, onduty)
    local out = {}
    for src, p in pairs(Mock.players) do
        if p.PlayerData.job.name == job and (not onduty or p.PlayerData.job.onduty) then out[#out + 1] = src end
    end
    table.sort(out)
    return out
end
Config = nil
for _, f in ipairs({ 'config.lua', 'server/core.lua', 'server/schema.lua', 'server/departments/core.lua',
    'server/departments/qualifications.lua', 'server/departments/shifts.lua' }) do
    load_resource('[pfscripts]/pf-government/' .. f)
end
Mock.exportsByResource['pf-government'] = Mock.exportsByResource['__self']
Mock.exportsByResource['__self'] = nil
local gov = exports['pf-government']
local jailed = {}
Mock.exportsByResource['pf-justice'] = { IsIncarcerated = function(_, cid) return jailed[cid] == true end }

local D, Q, S = GovDept, GovDept.Q, GovDept.S
local function num(v) return tonumber(v) or 0 end
local function scalar(q, p) return MySQL.scalar.await(q, p or {}) end
local function rows(q, p) return MySQL.query.await(q, p or {}) or {} end

local function employ(src, cid, job, grade, onduty, isboss)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.job = { name = job, grade = { level = grade, isboss = isboss or false }, isboss = isboss or false, onduty = onduty == true }
    p.Functions.SetJobDuty = function(v)
        p.PlayerData.job.onduty = not not v
        TriggerEvent('QBCore:Server:OnJobUpdate', src, p.PlayerData.job)
    end
    return p
end
local function setDuty(src, v)
    Mock.players[src].PlayerData.job.onduty = v
    TriggerEvent('QBCore:Server:SetDuty', src, v)
end
local function savePlayer(cid, job)
    MySQL.query.await([[INSERT INTO players (citizenid, license, name, money, charinfo, job, position, metadata)
        VALUES (?, ?, 'x', '{}', '{}', ?, '{}', '{}') ON DUPLICATE KEY UPDATE job = VALUES(job)]], { cid, 'license:' .. cid, json.encode(job) })
end
local function shifts(cid) return rows('SELECT * FROM pf_gov_dept_shifts WHERE citizenid = ? ORDER BY id', { cid }) end

local COP, LT, MEDIC, EMSCHIEF, CO = 1, 2, 3, 4, 5
local seq = 0
local C = {}
BeforeEach = function()
    Mock.reset()
    seq = seq + 1
    Mock.players, Mock.aces = {}, {}
    Mock.invokingResource = nil
    for k in pairs(jailed) do jailed[k] = nil end
    for k in pairs(Q.cache) do Q.cache[k] = nil end
    for k in pairs(S.open) do S.open[k] = nil end
    C = { cop = 'COP' .. seq, lt = 'LT' .. seq, med = 'MED' .. seq, emc = 'EMC' .. seq, co = 'CO' .. seq }
    employ(COP, C.cop, 'police', 0, false)
    employ(LT, C.lt, 'police', 3, false)
    employ(MEDIC, C.med, 'ambulance', 1, false)
    employ(EMSCHIEF, C.emc, 'ambulance', 4, false, true)
    employ(CO, C.co, 'corrections', 0, false)
end

describe('15I schema', function()
    it('the v6 department tables exist after the migrations', function()
        assert_true(GovSchema.Ensure())
        for _, t in ipairs({ 'pf_gov_dept_qualifications', 'pf_gov_dept_shifts', 'pf_gov_dept_audit' }) do
            assert_eq(num(scalar('SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?', { t })), 1, t)
        end
    end)
end)

describe('15I qualifications (real DB)', function()
    it('implied with no rows, for an online and an offline citizen', function()
        assert_true((gov:HasQualification(C.cop, 'patrol')))
        assert_false((gov:HasQualification(C.cop, 'detective')))
        savePlayer('OFFL' .. seq, { name = 'police', grade = { level = 3 }, onduty = true })
        local has, source = gov:HasQualification('OFFL' .. seq, 'detective')
        assert_true(has)
        assert_eq(source, 'implied')
        assert_false((gov:HasQualification('NOPE' .. seq, 'patrol')))
        assert_eq(num(scalar('SELECT COUNT(*) FROM pf_gov_dept_qualifications')), 0)
    end)

    it('grant, then revoke: one row per citizen and qualification, the revocation overrides the grade', function()
        assert_true(gov:GrantQualification(C.cop, 'lab_tech', { actor = { src = LT }, key = 'it:lab:' .. seq }).ok)
        assert_true((gov:HasQualification(C.cop, 'lab_tech')))
        assert_true(gov:RevokeQualification(C.cop, 'lab_tech', { actor = { src = LT } }).ok)
        assert_false((gov:HasQualification(C.cop, 'lab_tech')))
        assert_eq(num(scalar('SELECT COUNT(*) FROM pf_gov_dept_qualifications WHERE citizenid = ?', { C.cop })), 1)
        assert_eq(scalar('SELECT state FROM pf_gov_dept_qualifications WHERE citizenid = ? AND qual = ?', { C.cop, 'lab_tech' }), 'revoked')
        assert_true(gov:RevokeQualification(C.cop, 'patrol', { actor = { src = LT }, reason = 'Suspended' }).ok)
        assert_false((gov:HasQualification(C.cop, 'patrol')), 'implied patrol overridden')
        local list = gov:ListQualifications(C.cop).list
        assert_eq(#list, 2)
        assert_eq(num(scalar("SELECT COUNT(*) FROM pf_gov_dept_audit WHERE target = ? AND action = 'qual_revoke' AND dept = 'police'", { C.cop })), 2)
        assert_eq(scalar("SELECT actor_cid FROM pf_gov_dept_audit WHERE target = ? AND action = 'qual_grant'", { C.cop }), C.lt)
    end)

    it('a timed revocation lapses and the grade applies again', function()
        assert_true(gov:RevokeQualification(C.med, 'emt', { actor = { src = EMSCHIEF }, expiresAt = T + 60 }).ok)
        assert_false((gov:HasQualification(C.med, 'emt')))
        T = T + 61
        assert_true((gov:HasQualification(C.med, 'emt')), 'cache entries read again after the TTL are still correct')
        Q.Forget(C.med)
        local has, source = gov:HasQualification(C.med, 'emt')
        assert_true(has)
        assert_eq(source, 'implied')
    end)

    it('keys: a duplicate, a reuse, and a key displaced from the row found in the audit', function()
        local k1, k2 = 'it:k1:' .. seq, 'it:k2:' .. seq
        assert_true(gov:GrantQualification(C.cop, 'swat', { actor = { src = LT }, key = k1 }).ok)
        assert_true(gov:GrantQualification(C.cop, 'swat', { actor = { src = LT }, key = k1 }).duplicate)
        assert_eq(gov:GrantQualification(C.cop, 'k9', { actor = { src = LT }, key = k1 }).error, 'key_reused')
        assert_eq(gov:GrantQualification(C.med, 'surgeon', { actor = { src = EMSCHIEF }, key = k1 }).error, 'key_reused', 'another citizen')
        assert_true(gov:RevokeQualification(C.cop, 'swat', { actor = { src = LT }, key = k2 }).ok)
        assert_eq(scalar('SELECT idem_key FROM pf_gov_dept_qualifications WHERE citizenid = ? AND qual = ?', { C.cop, 'swat' }), k2)
        local r = gov:GrantQualification(C.cop, 'swat', { actor = { src = LT }, key = k1 })
        assert_true(r.duplicate, 'found through JSON_EXTRACT on the audit detail')
        assert_false((gov:HasQualification(C.cop, 'swat')))
        assert_eq(num(scalar("SELECT COUNT(*) FROM pf_gov_dept_audit WHERE target = ? AND action = 'qual_grant'", { C.cop })), 1)
    end)

    it('a deleted character loses its rows', function()
        assert_true(gov:GrantQualification(C.cop, 'k9', { actor = { src = LT } }).ok)
        setDuty(COP, true)
        setDuty(COP, false)
        Mock.fireEvent('pfm-core:server:characterDeleted', nil, C.cop)
        assert_eq(num(scalar('SELECT COUNT(*) FROM pf_gov_dept_qualifications WHERE citizenid = ?', { C.cop })), 0)
        assert_eq(#shifts(C.cop), 0)
    end)
end)

describe('15I shifts (real DB)', function()
    it('duty on/off, a grade change and a drop give rows with the right reasons', function()
        setDuty(COP, true)
        T = T + 600
        Mock.players[COP].PlayerData.job.grade.level = 1
        TriggerEvent('QBCore:Server:OnJobUpdate', COP, {})
        T = T + 300
        setDuty(COP, false)
        setDuty(COP, true)
        Mock.fireEvent('playerDropped', COP, 'quit')
        local s = shifts(C.cop)
        assert_eq(#s, 3)
        assert_eq(s[1].end_reason, 'job_change')
        assert_eq(num(s[1].ended_at) - num(s[1].started_at), 600)
        assert_eq(num(s[2].grade), 1)
        assert_eq(s[2].end_reason, 'duty_off')
        assert_eq(s[3].end_reason, 'dropped')
        assert_eq(num(scalar('SELECT COUNT(*) FROM pf_gov_dept_shifts WHERE citizenid = ? AND ended_at IS NULL', { C.cop })), 0)
    end)

    it('an incarcerated employee is forced off duty (D1): no shift, an audit row, the job kept', function()
        jailed[C.co] = true
        setDuty(CO, true)
        assert_false(Mock.players[CO].PlayerData.job.onduty)
        assert_eq(#shifts(C.co), 0)
        assert_eq(num(scalar("SELECT COUNT(*) FROM pf_gov_dept_audit WHERE action = 'duty_forced_off' AND target = ? AND dept = 'corrections'", { C.co })), 1)
        jailed[C.co] = nil
        setDuty(MEDIC, true)
        TriggerEvent('pf-justice:server:orderCreated', { id = 1, cid = C.med, kind = 'prison', state = 'active' })
        assert_eq(shifts(C.med)[1].end_reason, 'incarcerated')
    end)

    it('start closes what a previous run left open, capped, and reopens for employees on duty', function()
        MySQL.insert.await("INSERT INTO pf_gov_dept_shifts (citizenid, dept, job, grade, started_at) VALUES (?, 'police', 'police', 3, ?)", { C.lt, T - 3 * 86400 })
        MySQL.insert.await("INSERT INTO pf_gov_dept_shifts (citizenid, dept, job, grade, started_at) VALUES (?, 'ems', 'ambulance', 1, ?)", { C.med, T - 900 })
        Mock.players[MEDIC].PlayerData.job.onduty = true
        assert_true(S.Start())
        local lt = shifts(C.lt)[1]
        assert_eq(lt.end_reason, 'restart')
        assert_eq(num(lt.ended_at), num(lt.started_at) + 16 * 3600)
        local med = shifts(C.med)
        assert_eq(#med, 2)
        assert_eq(num(med[1].ended_at), T)
        assert_true(med[2].ended_at == nil, 'a fresh open shift')
        assert_eq(num(scalar('SELECT COUNT(*) FROM pf_gov_dept_shifts WHERE ended_at IS NULL')), 1)
    end)

    it('ListShifts: department, open only, citizen, since, cursor and limit', function()
        MySQL.query.await('DELETE FROM pf_gov_dept_shifts')
        setDuty(COP, true); T = T + 10; setDuty(COP, false)
        T = T + 10; setDuty(LT, true)
        T = T + 10; setDuty(MEDIC, true)
        Mock.invokingResource = 'pf-policemdt-DEV'
        local all = gov:ListShifts('police', {})
        assert_true(all.ok, all.message)
        assert_eq(#all.list, 2)
        assert_eq(all.list[1].cid, C.lt)
        assert_eq(all.list[2].seconds, 10)
        assert_eq(#gov:ListShifts('police', { open = true }).list, 1)
        assert_eq(#gov:ListShifts('police', { cid = C.cop }).list, 1)
        assert_eq(#gov:ListShifts('police', { since = T - 15 }).list, 1)
        local page = gov:ListShifts('police', { limit = 1 })
        assert_eq(#page.list, 1)
        local nextPage = gov:ListShifts('police', { limit = 1, beforeId = page.nextCursor })
        assert_eq(nextPage.list[1].cid, C.cop)
        assert_eq(#gov:ListShifts('ems', {}).list, 1)
        assert_eq(gov:ListShifts('ems', { viewer = COP }).error, 'no_permission')
        Mock.invokingResource = 'random-script'
        assert_eq(gov:ListShifts('police', {}).error, 'not_allowed')
    end)
end)

describe('15I audit (real DB)', function()
    it('LogDepartmentAudit writes a row; the sweep deletes past retention in batches', function()
        Mock.invokingResource = 'pf-justice'
        local r = gov:LogDepartmentAudit('doj', 'hearing_set', C.lt, 'CASE-1', { room = 2 })
        assert_true(r.ok, r.message)
        local row = MySQL.single.await('SELECT * FROM pf_gov_dept_audit WHERE id = ?', { r.id })
        assert_eq(row.action, 'hearing_set')
        assert_eq(row.actor_resource, 'pf-justice')
        assert_eq(json.decode(row.detail).room, 2)
        Mock.invokingResource = nil
        MySQL.query.await('DELETE FROM pf_gov_dept_audit')
        MySQL.query.await('DELETE FROM pf_gov_dept_shifts')
        for i = 1, 7 do
            MySQL.insert.await("INSERT INTO pf_gov_dept_audit (dept, action, at) VALUES ('police', 'old', ?)", { T - 200 * 86400 - i })
        end
        MySQL.insert.await("INSERT INTO pf_gov_dept_audit (dept, action, at) VALUES ('police', 'new', ?)", { T - 5 })
        MySQL.insert.await("INSERT INTO pf_gov_dept_shifts (citizenid, dept, job, grade, started_at, ended_at, end_reason) VALUES ('OLD1', 'police', 'police', 0, 1, ?, 'duty_off')", { T - 200 * 86400 })
        MySQL.insert.await("INSERT INTO pf_gov_dept_shifts (citizenid, dept, job, grade, started_at) VALUES ('OPEN1', 'police', 'police', 0, 1)")
        local batch = D.SWEEP_BATCH
        D.SWEEP_BATCH = 3
        local out = D.Sweep()
        D.SWEEP_BATCH = batch
        assert_eq(out.audit, 7)
        assert_eq(out.shifts, 1)
        assert_eq(num(scalar('SELECT COUNT(*) FROM pf_gov_dept_audit')), 1)
        assert_eq(scalar('SELECT citizenid FROM pf_gov_dept_shifts'), 'OPEN1')
    end)
end)
