-- Batch 15 unit 15I (mocked): pf-government department core. Membership from the live job,
-- qualifications (implied by grade with no rows, granted/revoked by managers, revocation overrides,
-- expiry, keys), shifts from the duty events (open/close reasons, drops, job changes, restart, the
-- minute tick), owner decision D1 (an incarcerated employee is forced off duty), the department
-- audit, caller allowlists and locks. The SQL itself runs on a real database in
-- b15_gov_departments_realdb_spec; here a small in-memory table emulation answers the statements.
load_resource('tests/lua/fivem_mocks.lua')

local started = { ['pf-government'] = true, ['pfm-core'] = true, ['pf-justice'] = true }
function GetResourceState(name) return started[name] and 'started' or 'missing' end
function GetCurrentResourceName() return 'pf-government' end
GlobalState = {}
vec4 = vec4 or vector4
vec3 = vec3 or vector3

-- ── an in-memory pf_gov_dept_* (only the statements the department files send) ──
local DB = { quals = {}, shifts = {}, audit = {}, players = {}, nextId = 0, failNext = nil, onInsertShift = nil }
local function nid() DB.nextId = DB.nextId + 1 return DB.nextId end
local function has(q, s) return q:find(s, 1, true) ~= nil end
local function boom(q) if DB.failNext and has(q, DB.failNext) then DB.failNext = nil error('db down') end end

local function run(kind, q, p)
    p = p or {}
    boom(q)
    -- qualifications
    if has(q, 'FROM pf_gov_dept_qualifications WHERE idem_key = ?') then
        for _, r in ipairs(DB.quals) do if r.idem_key == p[1] then return r end end
        return nil
    end
    if has(q, 'FROM pf_gov_dept_qualifications WHERE citizenid = ? AND qual = ?') then
        for _, r in ipairs(DB.quals) do if r.citizenid == p[1] and r.qual == p[2] then return r end end
        return nil
    end
    if has(q, 'SELECT qual, state, granted_by, source, expires_at, at FROM pf_gov_dept_qualifications WHERE citizenid = ?') then
        local out = {}
        for _, r in ipairs(DB.quals) do if r.citizenid == p[1] then out[#out + 1] = r end end
        return out
    end
    if has(q, 'INSERT INTO pf_gov_dept_qualifications') then
        for _, r in ipairs(DB.quals) do
            if (r.citizenid == p[1] and r.qual == p[2]) or (p[8] ~= nil and r.idem_key == p[8]) then error('Duplicate entry') end
        end
        local r = { id = nid(), citizenid = p[1], qual = p[2], state = p[3], granted_by = p[4], source = p[5], expires_at = p[6], at = p[7], idem_key = p[8] }
        DB.quals[#DB.quals + 1] = r
        return r.id
    end
    if has(q, 'UPDATE pf_gov_dept_qualifications SET state = ?') then
        for _, r in ipairs(DB.quals) do
            if r.id == p[7] then
                r.state, r.granted_by, r.source, r.expires_at, r.at, r.idem_key = p[1], p[2], p[3], p[4], p[5], p[6]
                return 1
            end
        end
        return 0
    end
    if has(q, 'DELETE FROM pf_gov_dept_qualifications WHERE citizenid = ?') then
        local keep, n = {}, 0
        for _, r in ipairs(DB.quals) do if r.citizenid == p[1] then n = n + 1 else keep[#keep + 1] = r end end
        DB.quals = keep
        return n
    end
    -- audit
    if has(q, 'FROM pf_gov_dept_audit WHERE dept = ? AND at >= ?') then
        for _, a in ipairs(DB.audit) do
            local d = a.detail and json.decode(a.detail) or {}
            if a.dept == p[1] and a.at >= p[2] and (a.action == 'qual_grant' or a.action == 'qual_revoke') and d.key == p[3] then return a end
        end
        return nil
    end
    if has(q, 'INSERT INTO pf_gov_dept_audit') then
        local a = { id = nid(), dept = p[1], action = p[2], actor_cid = p[3], actor_resource = p[4], target = p[5], detail = p[6], at = p[7] }
        DB.audit[#DB.audit + 1] = a
        return a.id
    end
    if has(q, 'DELETE FROM pf_gov_dept_audit WHERE at < ?') then
        local keep, n = {}, 0
        for _, a in ipairs(DB.audit) do if a.at < p[1] then n = n + 1 else keep[#keep + 1] = a end end
        DB.audit = keep
        return n
    end
    -- players (offline jobs)
    if has(q, 'SELECT job FROM players WHERE citizenid = ?') then return DB.players[p[1]] end
    -- shifts
    if has(q, 'INSERT INTO pf_gov_dept_shifts') then
        local s = { id = nid(), citizenid = p[1], dept = p[2], job = p[3], grade = p[4], started_at = p[5] }
        DB.shifts[#DB.shifts + 1] = s
        if DB.onInsertShift then local f = DB.onInsertShift; DB.onInsertShift = nil; f(s) end
        return s.id
    end
    if has(q, 'UPDATE pf_gov_dept_shifts SET ended_at = ?, end_reason = ? WHERE id = ?') then
        for _, s in ipairs(DB.shifts) do
            if s.id == p[3] and s.ended_at == nil then s.ended_at, s.end_reason = p[1], p[2] return 1 end
        end
        return 0
    end
    if has(q, "end_reason = 'restart' WHERE citizenid = ?") then
        local n = 0
        for _, s in ipairs(DB.shifts) do
            if s.citizenid == p[3] and s.ended_at == nil then s.ended_at, s.end_reason, n = math.min(p[1], s.started_at + p[2]), 'restart', n + 1 end
        end
        return n
    end
    if has(q, "end_reason = 'restart' WHERE ended_at IS NULL") then
        local n = 0
        for _, s in ipairs(DB.shifts) do
            if s.ended_at == nil then s.ended_at, s.end_reason, n = math.min(p[1], s.started_at + p[2]), 'restart', n + 1 end
        end
        return n
    end
    if has(q, 'SELECT id, citizenid, dept, job, grade, started_at, ended_at, end_reason FROM pf_gov_dept_shifts WHERE') then
        DB.lastShiftQuery = { q = q, p = p }
        local out, limit = {}, tonumber(q:match('LIMIT (%d+)'))
        for i = #DB.shifts, 1, -1 do
            if limit and #out >= limit then break end
            local s = DB.shifts[i]
            local ok = s.dept == p[1]
            if ok and has(q, 'citizenid = ?') then ok = s.citizenid == p[2] end
            if ok and has(q, 'ended_at IS NULL') then ok = s.ended_at == nil end
            if ok then out[#out + 1] = s end
        end
        return out
    end
    if has(q, 'DELETE FROM pf_gov_dept_shifts WHERE ended_at IS NOT NULL') then
        local keep, n = {}, 0
        for _, s in ipairs(DB.shifts) do if s.ended_at and s.ended_at < p[1] then n = n + 1 else keep[#keep + 1] = s end end
        DB.shifts = keep
        return n
    end
    if has(q, 'DELETE FROM pf_gov_dept_shifts WHERE citizenid = ?') then
        local keep, n = {}, 0
        for _, s in ipairs(DB.shifts) do if s.citizenid == p[1] then n = n + 1 else keep[#keep + 1] = s end end
        DB.shifts = keep
        return n
    end
    error('unexpected statement: ' .. q)
end
local function op(kind)
    local function call(q, p, cb)
        if type(p) == 'function' then cb, p = p, nil end
        local out = run(kind, q, p)
        if cb then cb(out) end
        return out
    end
    return setmetatable({ await = function(q, p) return call(q, p) end }, { __call = function(_, q, p, cb) return call(q, p, cb) end })
end
MySQL = { query = op('query'), insert = op('insert'), update = op('update'), scalar = op('scalar'), single = op('single'), prepare = op('query') }

-- pfm-core pieces the department files use
QBCoreMock.Functions.GetPlayersByJob = function(job, onduty)
    local out = {}
    for src, p in pairs(Mock.players) do
        if p.PlayerData.job.name == job and (not onduty or p.PlayerData.job.onduty) then out[#out + 1] = src end
    end
    table.sort(out)
    return out
end

Config = nil
load_resource('[pfscripts]/pf-government/config.lua')
for _, f in ipairs({ 'server/core.lua', 'server/schema.lua', 'server/departments/core.lua',
    'server/departments/qualifications.lua', 'server/departments/shifts.lua' }) do
    load_resource('[pfscripts]/pf-government/' .. f)
end
GovSchema.Ensure = function() return true end
Mock.exportsByResource['pf-government'] = Mock.exportsByResource['__self']
Mock.exportsByResource['__self'] = nil
local gov = exports['pf-government']

local jailed = {}
Mock.exportsByResource['pf-justice'] = { IsIncarcerated = function(_, cid) return jailed[cid] == true end }

local D, Q, S = GovDept, GovDept.Q, GovDept.S

--- An online player with a job; SetJobDuty behaves like pfm-core (the job update event follows).
local function employ(src, cid, job, grade, onduty, isboss)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.job = { name = job, grade = { level = grade, isboss = isboss or false }, isboss = isboss or false, onduty = onduty ~= false }
    p.Functions.SetJobDuty = function(v)
        p.PlayerData.job.onduty = not not v
        TriggerEvent('QBCore:Server:OnJobUpdate', src, p.PlayerData.job)
    end
    return p
end
local function setDuty(src, v)
    local p = Mock.players[src]
    p.PlayerData.job.onduty = v
    TriggerEvent('QBCore:Server:SetDuty', src, v)
end
local function setJob(src, job, grade)
    local p = Mock.players[src]
    p.PlayerData.job = { name = job, grade = { level = grade }, onduty = p.PlayerData.job.onduty }
    TriggerEvent('QBCore:Server:OnJobUpdate', src, p.PlayerData.job)
end
local function shiftsOf(cid)
    local out = {}
    for _, s in ipairs(DB.shifts) do if s.citizenid == cid then out[#out + 1] = s end end
    return out
end
local function auditOf(action)
    local out = {}
    for _, a in ipairs(DB.audit) do if a.action == action then out[#out + 1] = a end end
    return out
end

local COP, LT, CHIEF, MEDIC, EMSCHIEF, CIV, CO = 1, 2, 3, 4, 5, 6, 7
BeforeEach = function()
    Mock.reset()
    Mock.clock = 1800000000
    Mock.players, Mock.aces = {}, {}
    Mock.invokingResource = nil
    DB.quals, DB.shifts, DB.audit, DB.players, DB.failNext, DB.onInsertShift = {}, {}, {}, {}, nil, nil
    for k in pairs(jailed) do jailed[k] = nil end
    for k in pairs(Q.cache) do Q.cache[k] = nil end
    for k in pairs(S.open) do S.open[k] = nil end
    for k in pairs(S.closing) do S.closing[k] = nil end
    for k in pairs(D.locks) do D.locks[k] = nil end
    started['pf-justice'] = true
    Config.Departments.Enabled = true
    Config.Departments.ForceOffDutyWhenIncarcerated = true
    employ(COP, 'COP1', 'police', 0, false)
    employ(LT, 'LT1', 'police', 3, false)
    employ(CHIEF, 'CHF1', 'police', 4, false, true)
    employ(MEDIC, 'MED1', 'ambulance', 1, false)
    employ(EMSCHIEF, 'EMC1', 'ambulance', 4, false, true)
    employ(CIV, 'CIV1', 'unemployed', 0, false)
    employ(CO, 'CO1', 'corrections', 0, false)
end

describe('15I membership', function()
    it('GetDepartmentOf maps jobs and live players to departments', function()
        assert_eq(gov:GetDepartmentOf('police'), 'police')
        assert_eq(gov:GetDepartmentOf('ambulance'), 'ems')
        assert_eq(gov:GetDepartmentOf('judge'), 'doj')
        assert_eq(gov:GetDepartmentOf('mechanic'), nil)
        assert_eq(gov:GetDepartmentOf(MEDIC), 'ems')
        assert_eq(gov:GetDepartmentOf(CIV), nil)
        assert_eq(gov:GetDepartmentOf(999), nil)
        assert_eq(gov:GetDepartmentOf({}), nil)
    end)

    it('a manager is decided by the live grade against ManagerGrade', function()
        assert_false(D.Member(COP).manager)
        assert_true(D.Member(LT).manager)
        Mock.players[LT].PlayerData.job.grade.level = 2
        assert_false(D.Member(LT).manager, 'demotion is seen at once')
    end)
end)

describe('15I qualifications', function()
    it('implied qualifications work with no rows', function()
        local has, source = gov:HasQualification('COP1', 'patrol')
        assert_true(has)
        assert_eq(source, 'implied')
        assert_false((gov:HasQualification('COP1', 'fto')))
        assert_true((gov:HasQualification('LT1', 'detective')))
        assert_true((gov:HasQualification('MED1', 'emt')))
        assert_false((gov:HasQualification('MED1', 'surgeon')))
        assert_true((gov:HasQualification(COP, 'patrol')), 'a server id works too')
        assert_eq(#DB.quals, 0)
    end)

    it('unknown qualifications, bad ids and civilians have nothing', function()
        assert_false((gov:HasQualification('COP1', 'astronaut')))
        assert_false((gov:HasQualification('bad id!', 'patrol')))
        assert_false((gov:HasQualification('CIV1', 'patrol')))
        assert_false((gov:HasQualification('NOBODY', 'patrol')))
    end)

    it('an offline citizen is judged by the saved job', function()
        DB.players.OFF1 = json.encode({ name = 'police', grade = { level = 2 }, onduty = true })
        local has, source = gov:HasQualification('OFF1', 'fto')
        assert_true(has)
        assert_eq(source, 'implied')
        local list = gov:ListQualifications('OFF1')
        assert_true(list.ok)
        assert_eq(list.dept, 'police')
    end)

    it('fails closed when the records cannot be read', function()
        DB.failNext = 'FROM pf_gov_dept_qualifications WHERE citizenid = ?'
        assert_false((gov:HasQualification('COP1', 'patrol')))
        assert_true((gov:HasQualification('COP1', 'patrol')), 'the next read works')
    end)

    it('a manager grants a qualification: row, audit, cache cleared, holder told', function()
        assert_false((gov:HasQualification('COP1', 'lab_tech')))
        local r = gov:GrantQualification('COP1', 'lab_tech', { actor = { src = LT }, key = 'test:grant:1', reason = 'Lab course' })
        assert_true(r.ok, r.message)
        assert_eq(DB.quals[1].state, 'granted')
        assert_eq(DB.quals[1].granted_by, 'LT1')
        assert_eq(DB.quals[1].idem_key, 'test:grant:1')
        local has, source = gov:HasQualification('COP1', 'lab_tech')
        assert_true(has, 'the cached empty read was cleared')
        assert_eq(source, 'granted')
        local a = auditOf('qual_grant')[1]
        assert_eq(a.dept, 'police')
        assert_eq(a.actor_cid, 'LT1')
        assert_eq(a.target, 'COP1')
        local d = json.decode(a.detail)
        assert_eq(d.qual, 'lab_tech')
        assert_eq(d.key, 'test:grant:1')
        assert_eq(d.reason, 'Lab course')
        assert_eq(#Mock.clientEventsNamed('QBCore:Notify'), 1)
    end)

    it('a granted revocation overrides the implied qualification', function()
        local r = gov:RevokeQualification('COP1', 'patrol', { actor = { src = LT }, reason = 'Suspended' })
        assert_true(r.ok, r.message)
        assert_false((gov:HasQualification('COP1', 'patrol')))
        local list = gov:ListQualifications('COP1').list
        assert_eq(list[1].qual, 'patrol')
        assert_eq(list[1].reason, 'revoked')
        assert_false(list[1].has)
        assert_eq(#auditOf('qual_revoke'), 1)
    end)

    it('a timed revocation is a suspension that lapses', function()
        local t = os.time()
        assert_true(gov:RevokeQualification('COP1', 'patrol', { actor = { src = LT }, expiresAt = t + 3600 }).ok)
        assert_false((gov:HasQualification('COP1', 'patrol')))
        Mock.clock = t + 3601
        local has, source = gov:HasQualification('COP1', 'patrol')
        assert_true(has)
        assert_eq(source, 'implied')
    end)

    it('a grant expires, and counts only while the holder works for a department', function()
        local t = os.time()
        assert_true(gov:GrantQualification('COP1', 'swat', { actor = { src = LT }, expiresAt = t + 600 }).ok)
        local has, _, exp = gov:HasQualification('COP1', 'swat')
        assert_true(has)
        assert_eq(exp, t + 600)
        Mock.players[COP].PlayerData.job = { name = 'unemployed', grade = { level = 0 } }
        assert_false((gov:HasQualification('COP1', 'swat')), 'fired: the certificate is held but inactive')
        Mock.players[COP].PlayerData.job = { name = 'police', grade = { level = 0 } }
        assert_true((gov:HasQualification('COP1', 'swat')))
        Mock.clock = t + 601
        assert_false((gov:HasQualification('COP1', 'swat')))
        local entry = gov:ListQualifications('COP1').list
        local found
        for _, e in ipairs(entry) do if e.qual == 'swat' then found = e end end
        assert_eq(found.reason, 'expired')
    end)

    it('only managers of the qualification department may grant, never to themselves or to equal ranks', function()
        local r = gov:GrantQualification('MED1', 'swat', { actor = { src = COP } })
        assert_eq(r.error, 'no_permission', 'recruit is no manager')
        r = gov:GrantQualification('MED1', 'surgeon', { actor = { src = LT } })
        assert_eq(r.error, 'no_permission', 'police manager cannot grant an EMS qualification')
        r = gov:GrantQualification('LT1', 'swat', { actor = { src = LT } })
        assert_eq(r.error, 'no_permission', 'no self-grant')
        employ(8, 'LT2', 'police', 3, false)
        r = gov:GrantQualification('LT2', 'swat', { actor = { src = LT } })
        assert_eq(r.error, 'no_permission', 'equal rank')
        r = gov:GrantQualification('LT2', 'swat', { actor = { src = CHIEF } })
        assert_true(r.ok, 'the boss can')
        r = gov:GrantQualification('MED1', 'surgeon', { actor = { src = EMSCHIEF } })
        assert_true(r.ok)
        assert_eq(#DB.quals, 2)
    end)

    it('the target must exist and work for a department; actors are checked on the server', function()
        assert_eq(gov:GrantQualification('CIV1', 'swat', { actor = { src = LT } }).error, 'invalid_state')
        assert_eq(gov:GrantQualification('GHOST', 'swat', { actor = { src = LT } }).error, 'not_found')
        assert_eq(gov:GrantQualification('COP1', 'swat', {}).error, 'bad_args')
        assert_eq(gov:GrantQualification('COP1', 'swat', { actor = { src = 99 } }).error, 'offline')
        assert_eq(gov:GrantQualification('COP1', 'swat', { actor = { src = CIV, kind = 'admin' } }).error, 'no_permission')
        Mock.aces[CIV] = { command = true }
        assert_true(gov:GrantQualification('COP1', 'swat', { actor = { src = CIV, kind = 'admin' } }).ok, 'admin with the ACE')
        assert_eq(#DB.quals, 1)
    end)

    it('arguments are validated', function()
        local a = { src = LT }
        assert_eq(gov:GrantQualification('COP1', 'nope', { actor = a }).error, 'bad_args')
        assert_eq(gov:GrantQualification('bad id', 'swat', { actor = a }).error, 'bad_args')
        assert_eq(gov:GrantQualification('COP1', 'swat', { actor = a, key = 'has space' }).error, 'bad_args')
        assert_eq(gov:GrantQualification('COP1', 'swat', { actor = a, expiresAt = os.time() - 1 }).error, 'bad_args')
        assert_eq(gov:GrantQualification('COP1', 'swat', { actor = a, expiresAt = 0 / 0 }).error, 'bad_args')
        assert_eq(gov:GrantQualification('COP1', 'swat', { actor = a, reason = '   ' }).error, 'bad_args')
        assert_eq(#DB.quals, 0)
    end)

    it('system actors and a training source only from pf-government itself', function()
        Mock.invokingResource = 'pf-emsmdt'
        assert_eq(gov:GrantQualification('MED1', 'paramedic', { actor = { kind = 'system', label = 'x' } }).error, 'no_permission')
        assert_eq(gov:GrantQualification('MED1', 'paramedic', { actor = { src = EMSCHIEF }, source = 'training' }).error, 'bad_args')
        Mock.invokingResource = nil
        local r = Q.Grant('MED1', 'paramedic', { actor = { kind = 'system', label = 'training' }, source = 'training' }, nil)
        assert_true(r.ok, r.message)
        assert_eq(DB.quals[1].source, 'training')
        assert_eq(DB.quals[1].granted_by, 'system:training')
    end)

    it('allowlists: writes only from listed resources; reads are open', function()
        Mock.invokingResource = 'some-script'
        assert_eq(gov:GrantQualification('COP1', 'swat', { actor = { src = LT } }).error, 'not_allowed')
        assert_eq(gov:RevokeQualification('COP1', 'patrol', { actor = { src = LT } }).error, 'not_allowed')
        assert_eq(gov:ListShifts('police', {}).error, 'not_allowed')
        assert_eq(gov:LogDepartmentAudit('police', 'x', nil, nil, nil).error, 'not_allowed')
        assert_true((gov:HasQualification('COP1', 'patrol')))
        assert_true(gov:ListQualifications('COP1').ok)
        assert_true(gov:GetShift(COP).ok)
        Mock.invokingResource = 'pf-policemdt-DEV'
        assert_true(gov:GrantQualification('COP1', 'swat', { actor = { src = LT } }).ok)
        assert_eq(DB.audit[1].actor_resource, 'pf-policemdt-DEV')
    end)

    it('keys: same change is a duplicate, other arguments are key_reused, displaced keys are still known', function()
        local a = { src = LT }
        assert_true(gov:GrantQualification('COP1', 'swat', { actor = a, key = 'k:1' }).ok)
        local r = gov:GrantQualification('COP1', 'swat', { actor = a, key = 'k:1' })
        assert_true(r.duplicate)
        assert_eq(gov:GrantQualification('COP1', 'k9', { actor = a, key = 'k:1' }).error, 'key_reused')
        assert_true(gov:RevokeQualification('COP1', 'swat', { actor = a, key = 'k:2' }).ok)
        -- k:1 is no longer on the row; the audit still knows it, so the retry does not grant again
        r = gov:GrantQualification('COP1', 'swat', { actor = a, key = 'k:1' })
        assert_true(r.duplicate)
        assert_false((gov:HasQualification('COP1', 'swat')))
        assert_eq(#auditOf('qual_grant'), 1)
    end)

    it('a change that changes nothing writes nothing', function()
        assert_true(gov:GrantQualification('COP1', 'swat', { actor = { src = LT } }).ok)
        local r = gov:GrantQualification('COP1', 'swat', { actor = { src = LT } })
        assert_true(r.unchanged)
        assert_eq(#DB.audit, 1)
    end)

    it('the per-qualification lock is taken before the database wait', function()
        D.locks['dq:COP1:swat'] = true
        assert_eq(gov:GrantQualification('COP1', 'swat', { actor = { src = LT } }).error, 'busy')
        D.locks['dq:COP1:swat'] = nil
        D.locks['dqk:kk'] = true
        assert_eq(gov:GrantQualification('MED1', 'surgeon', { actor = { src = EMSCHIEF }, key = 'kk' }).error, 'busy')
        assert_eq(#DB.quals, 0)
    end)

    it('a database error inside the lock changes nothing and frees the lock', function()
        DB.failNext = 'INSERT INTO pf_gov_dept_qualifications'
        assert_eq(gov:GrantQualification('COP1', 'swat', { actor = { src = LT } }).error, 'db_unavailable')
        assert_eq(D.locks['dq:COP1:swat'], nil)
        assert_true(gov:GrantQualification('COP1', 'swat', { actor = { src = LT } }).ok)
    end)
end)

describe('15I shifts', function()
    it('duty on opens a shift, duty off closes it', function()
        setDuty(COP, true)
        local s = shiftsOf('COP1')
        assert_eq(#s, 1)
        assert_eq(s[1].dept, 'police')
        assert_eq(s[1].grade, 0)
        assert_eq(s[1].ended_at, nil)
        local g = gov:GetShift(COP)
        assert_eq(g.shift.id, s[1].id)
        assert_eq(g.shift.dept, 'police')
        Mock.clock = Mock.clock + 1800
        assert_eq(gov:GetShift(COP).shift.seconds, 1800)
        setDuty(COP, false)
        assert_eq(s[1].end_reason, 'duty_off')
        assert_eq(s[1].ended_at, Mock.clock)
        assert_eq(gov:GetShift(COP).shift, nil)
    end)

    it('duplicate duty events record one shift; a non-department job records none', function()
        setDuty(COP, true)
        TriggerEvent('QBCore:Server:OnJobUpdate', COP, {})
        TriggerEvent('QBCore:Server:SetDuty', COP, true)
        assert_eq(#shiftsOf('COP1'), 1)
        setDuty(CIV, true)
        assert_eq(#shiftsOf('CIV1'), 0)
    end)

    it('the event argument is only a hint: the live duty decides', function()
        TriggerEvent('QBCore:Server:SetDuty', COP, true)
        assert_eq(#shiftsOf('COP1'), 0, 'player is off duty in pfm-core')
    end)

    it('a job or grade change closes the shift as job_change and opens a new one', function()
        setDuty(COP, true)
        setJob(COP, 'police', 1)
        local s = shiftsOf('COP1')
        assert_eq(#s, 2)
        assert_eq(s[1].end_reason, 'job_change')
        assert_eq(s[2].grade, 1)
        assert_eq(s[2].ended_at, nil)
        setJob(COP, 'unemployed', 0)
        assert_eq(s[2].end_reason, 'job_change')
        assert_eq(gov:GetShift(COP).shift, nil)
    end)

    it('a drop or logout closes the shift as dropped', function()
        setDuty(COP, true)
        Mock.fireEvent('playerDropped', COP, 'quit')
        assert_eq(shiftsOf('COP1')[1].end_reason, 'dropped')
        setDuty(MEDIC, true)
        TriggerEvent('QBCore:Server:OnPlayerUnload', MEDIC)
        assert_eq(shiftsOf('MED1')[1].end_reason, 'dropped')
        assert_eq(next(S.open), nil, 'memory is bounded by online players')
    end)

    it('a drop during the open insert still ends closed (pending re-run)', function()
        DB.onInsertShift = function() S.Drop(COP) end
        setDuty(COP, true)
        local s = shiftsOf('COP1')
        assert_eq(#s, 1)
        assert_eq(s[1].end_reason, 'dropped')
        assert_eq(S.open[COP], nil)
    end)

    it('start closes leftover shifts as restart (capped) and records employees on duty', function()
        DB.shifts[1] = { id = 900, citizenid = 'LT1', dept = 'police', job = 'police', grade = 3, started_at = Mock.clock - 3 * 86400 }
        DB.shifts[2] = { id = 901, citizenid = 'MED1', dept = 'ems', job = 'ambulance', grade = 1, started_at = Mock.clock - 600 }
        Mock.players[MEDIC].PlayerData.job.onduty = true
        assert_true(S.Start())
        assert_eq(DB.shifts[1].end_reason, 'restart')
        assert_eq(DB.shifts[1].ended_at, DB.shifts[1].started_at + 16 * 3600, 'capped at MaxShiftHours')
        assert_eq(DB.shifts[2].ended_at, Mock.clock)
        assert_true(S.open[MEDIC] ~= nil, 'the medic on duty got a fresh shift')
        assert_eq(#shiftsOf('MED1'), 2)
    end)

    it('the minute tick opens missed shifts and closes those of players who are gone', function()
        Mock.players[MEDIC].PlayerData.job.onduty = true
        setDuty(COP, true)
        Mock.players[COP] = nil
        S.Tick()
        assert_eq(shiftsOf('COP1')[1].end_reason, 'dropped')
        assert_true(S.open[MEDIC] ~= nil)
    end)

    it('a failed close is retried by the tick with the original end time', function()
        setDuty(COP, true)
        local t = Mock.clock
        DB.failNext = 'UPDATE pf_gov_dept_shifts SET ended_at = ?, end_reason = ? WHERE id = ?'
        setDuty(COP, false)
        assert_eq(shiftsOf('COP1')[1].ended_at, nil)
        Mock.clock = t + 300
        S.Tick()
        assert_eq(shiftsOf('COP1')[1].ended_at, t)
        assert_eq(shiftsOf('COP1')[1].end_reason, 'duty_off')
    end)

    it('disabled departments record nothing', function()
        Config.Departments.Enabled = false
        setDuty(COP, true)
        assert_eq(#DB.shifts, 0)
    end)
end)

describe('15I incarcerated employees (D1)', function()
    it('going on duty while incarcerated is undone at once and audited', function()
        jailed.CO1 = true
        setDuty(CO, true)
        assert_false(Mock.players[CO].PlayerData.job.onduty, 'pfm-core duty set back off')
        assert_eq(Mock.players[CO].PlayerData.job.name, 'corrections', 'the job is kept')
        local back = Mock.clientEventsNamed('QBCore:Client:SetDuty')
        assert_eq(back[#back].args[1], false)
        assert_eq(#shiftsOf('CO1'), 0, 'no shift was opened')
        local a = auditOf('duty_forced_off')
        assert_eq(#a, 1)
        assert_eq(a[1].dept, 'corrections')
        assert_eq(a[1].target, 'CO1')
    end)

    it('a new active incarceration order takes an employee on duty off duty', function()
        setDuty(COP, true)
        assert_true(S.open[COP] ~= nil)
        TriggerEvent('pf-justice:server:orderCreated', { id = 5, cid = 'COP1', kind = 'jail', state = 'active' })
        assert_false(Mock.players[COP].PlayerData.job.onduty)
        assert_eq(shiftsOf('COP1')[1].end_reason, 'incarcerated')
        assert_eq(S.open[COP], nil)
    end)

    it('other order kinds and pending orders do not touch duty', function()
        setDuty(COP, true)
        TriggerEvent('pf-justice:server:orderCreated', { id = 6, cid = 'COP1', kind = 'fine', state = 'active' })
        TriggerEvent('pf-justice:server:orderChanged', { id = 7, cid = 'COP1', kind = 'prison', state = 'pending' }, {})
        assert_true(Mock.players[COP].PlayerData.job.onduty)
        assert_true(S.open[COP] ~= nil)
    end)

    it('the minute tick catches an incarceration whose event was missed', function()
        setDuty(MEDIC, true)
        jailed.MED1 = true
        S.Tick()
        assert_false(Mock.players[MEDIC].PlayerData.job.onduty)
        assert_eq(shiftsOf('MED1')[1].end_reason, 'incarcerated')
    end)

    it('without pf-justice running, or with the option off, duty is allowed', function()
        jailed.CO1 = true
        started['pf-justice'] = nil
        setDuty(CO, true)
        assert_true(Mock.players[CO].PlayerData.job.onduty)
        started['pf-justice'] = true
        Config.Departments.ForceOffDutyWhenIncarcerated = false
        setDuty(COP, true)
        jailed.COP1 = true
        S.Tick()
        assert_true(Mock.players[COP].PlayerData.job.onduty)
    end)
end)

describe('15I ListShifts', function()
    it('lists a department, newest first, with a cursor', function()
        setDuty(COP, true)
        setDuty(LT, true)
        setDuty(MEDIC, true)
        Mock.invokingResource = 'pf-policemdt-DEV'
        local r = gov:ListShifts('police', { limit = 1 })
        assert_true(r.ok)
        assert_eq(#r.list, 1)
        assert_eq(r.list[1].cid, 'LT1')
        assert_eq(r.nextCursor, r.list[1].id)
        assert_true(DB.lastShiftQuery.q:find('LIMIT 1', 1, true) ~= nil)
        r = gov:ListShifts('police', {})
        assert_eq(#r.list, 2)
        assert_eq(r.nextCursor, nil)
    end)

    it('a viewer must work for the department; non-managers see only their own shifts', function()
        setDuty(COP, true)
        setDuty(LT, true)
        local r = S.List('police', { viewer = COP })
        assert_true(r.ok)
        assert_eq(#r.list, 1)
        assert_eq(r.list[1].cid, 'COP1')
        assert_eq(S.List('police', { viewer = COP, cid = 'LT1' }).error, 'no_permission')
        assert_eq(S.List('police', { viewer = MEDIC }).error, 'no_permission')
        assert_eq(#S.List('police', { viewer = LT }).list, 2)
    end)

    it('rejects bad departments and filters', function()
        assert_eq(S.List('mafia', {}).error, 'bad_args')
        assert_eq(S.List('police', { limit = 101 }).error, 'bad_args')
        assert_eq(S.List('police', { limit = 0 }).error, 'bad_args')
        assert_eq(S.List('police', { cid = 'x y' }).error, 'bad_args')
        assert_eq(S.List('police', { beforeId = -1 }).error, 'bad_args')
        assert_eq(S.List('police', { viewer = 999 }).error, 'bad_args')
    end)
end)

describe('15I department audit', function()
    it('LogDepartmentAudit writes one row for a listed resource', function()
        Mock.invokingResource = 'pfm-prison'
        local r = gov:LogDepartmentAudit('corrections', 'cell_search', { src = CO }, 'INMATE1', { cell = 'A-12' })
        assert_true(r.ok, r.message)
        local a = DB.audit[1]
        assert_eq(a.dept, 'corrections')
        assert_eq(a.action, 'cell_search')
        assert_eq(a.actor_cid, 'CO1', 'the actor is resolved on the server')
        assert_eq(a.actor_resource, 'pfm-prison')
        assert_eq(a.target, 'INMATE1')
        assert_eq(json.decode(a.detail).cell, 'A-12')
        assert_true(gov:LogDepartmentAudit('police', 'note', 'COP1', 42, 'free text').ok)
        assert_eq(DB.audit[2].target, '42')
    end)

    it('validates every argument and caps the detail', function()
        Mock.invokingResource = 'pfm-prison'
        assert_eq(gov:LogDepartmentAudit('mafia', 'x').error, 'bad_args')
        assert_eq(gov:LogDepartmentAudit('police', 'bad action!').error, 'bad_args')
        assert_eq(gov:LogDepartmentAudit('police', string.rep('a', 33)).error, 'bad_args')
        assert_eq(gov:LogDepartmentAudit('police', 'x', 'bad cid!').error, 'bad_args')
        assert_eq(gov:LogDepartmentAudit('police', 'x', { src = 999 }).error, 'bad_args')
        assert_eq(gov:LogDepartmentAudit('police', 'x', nil, '   ').error, 'bad_args')
        assert_eq(gov:LogDepartmentAudit('police', 'x', nil, nil, 12).error, 'bad_args')
        assert_eq(#DB.audit, 0)
        assert_true(gov:LogDepartmentAudit('police', 'x', { kind = 'system' }, nil, { blob = string.rep('z', 5000) }).ok)
        assert_true(json.decode(DB.audit[1].detail).truncated)
    end)

    it('the daily sweep deletes rows past retention', function()
        DB.audit = { { id = 1, dept = 'police', action = 'a', at = Mock.clock - 181 * 86400 }, { id = 2, dept = 'police', action = 'b', at = Mock.clock - 10 } }
        DB.shifts = {
            { id = 3, citizenid = 'X', dept = 'police', started_at = 1, ended_at = Mock.clock - 200 * 86400 },
            { id = 4, citizenid = 'Y', dept = 'police', started_at = 1 },
        }
        local out = D.Sweep()
        assert_eq(out.audit, 1)
        assert_eq(out.shifts, 1)
        assert_eq(DB.audit[1].id, 2)
        assert_eq(DB.shifts[1].id, 4, 'an open shift is never swept')
    end)

    it('a deleted character loses its qualification and shift rows; a player cannot trigger it', function()
        assert_true(gov:GrantQualification('COP1', 'swat', { actor = { src = LT } }).ok)
        setDuty(COP, true)
        setDuty(COP, false)
        Mock.fireEvent('pfm-core:server:characterDeleted', COP, 'COP1')
        assert_eq(#DB.quals, 1, 'a player source is ignored')
        Mock.fireEvent('pfm-core:server:characterDeleted', nil, 'COP1')
        assert_eq(#DB.quals, 0)
        assert_eq(#shiftsOf('COP1'), 0)
    end)
end)
