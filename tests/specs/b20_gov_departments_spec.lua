-- Batch 20 unit 20E (mocked): pf-government department management.
--   * caller allowlists of the new exports (fail closed), argument and actor checks before any
--     database work;
--   * the asset register's change path: the key is stored on the event row, a failed event insert
--     puts the asset back so a retry with the same key applies once; issue rules (duty,
--     manager-only issues, selfIssue = false, the holder's department);
--   * training grants only through the qualification store (GovDept.Q.Grant, system actor,
--     source 'training', invoker nil) and a replay of the training key finishes a failed grant;
--   * payroll: an unreadable ledger fails the report (no partial wages), the period limit, who
--     may read it;
--   * the department app handlers check the department role on the server (non-managers, other
--     departments, non-members), namespace client keys per viewer, and the app is offered only
--     when its module ships.
-- The SQL runs on a real database in b20_gov_departments_realdb_spec.
load_resource('tests/lua/fivem_mocks.lua')

local started = { ['pf-government'] = true, ['pfm-core'] = true }
function GetResourceState(name) return started[name] and 'started' or 'missing' end
function GetCurrentResourceName() return 'pf-government' end
GlobalState = {}
vec4 = vec4 or vector4
vec3 = vec3 or vector3

-- ── a programmable database: DB.on(pattern, fn(kind, q, p)) answers matching statements ──
local DB = { rules = {}, log = {} }
function DB.on(pattern, fn) DB.rules[#DB.rules + 1] = { pattern = pattern, fn = fn } end
function DB.clear() DB.rules, DB.log = {}, {} end
local function run(kind, q, p)
    DB.log[#DB.log + 1] = { kind = kind, q = q, p = p }
    for i = #DB.rules, 1, -1 do
        local r = DB.rules[i]
        if q:find(r.pattern, 1, true) then return r.fn(kind, q, p or {}) end
    end
    if kind == 'query' then return {} end
    if kind == 'insert' then return 1 end
    if kind == 'update' then return 1 end
    return nil
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
local function logged(pattern)
    local n = 0
    for _, c in ipairs(DB.log) do if c.q:find(pattern, 1, true) then n = n + 1 end end
    return n
end

QBCoreMock.Functions.GetPlayersByJob = function() return {} end

local moduleShips = false
function LoadResourceFile(res, path)
    if res == 'pf-government' and path == 'html/apps/department.js' and moduleShips then return 'PFApps.register()' end
    return nil
end

Config = nil
load_resource('[pfscripts]/pf-government/config.lua')
for _, f in ipairs({ 'server/core.lua', 'server/schema.lua', 'server/departments/core.lua',
    'server/departments/qualifications.lua', 'server/departments/shifts.lua', 'server/departments/training.lua',
    'server/departments/assets.lua', 'server/departments/payroll.lua', 'server/apps/common.lua', 'server/apps/department.lua' }) do
    load_resource('[pfscripts]/pf-government/' .. f)
end
GovSchema.Ensure = function() return true end
Config.Departments.ManagerGrade = { police = 3, ambulance = 3, corrections = 4, doj = 4, judge = 2, government = 3 }
Mock.exportsByResource['pf-government'] = Mock.exportsByResource['__self']
Mock.exportsByResource['__self'] = nil
local gov = exports['pf-government']
local D, App = GovDept, GovApps.Department

local function employ(src, cid, job, grade, onduty, isboss)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.job = { name = job, grade = { level = grade, isboss = isboss or false }, isboss = isboss or false, onduty = onduty == true }
    return p
end

local COP, LT, MED, CHIEF, MECH, GOVT = 1, 2, 3, 4, 5, 6
local realGrant = D.Q.Grant
BeforeEach = function()
    Mock.reset()
    DB.clear()
    Mock.players, Mock.aces = {}, {}
    Mock.invokingResource = nil
    D.Q.Grant = realGrant
    for k in pairs(D.locks) do D.locks[k] = nil end
    for k in pairs(D.Q.cache) do D.Q.cache[k] = nil end
    employ(COP, 'COP1', 'police', 1, true)
    employ(LT, 'LT1', 'police', 3, true)
    employ(MED, 'MED1', 'ambulance', 1, true)
    employ(CHIEF, 'CHF1', 'ambulance', 4, true, true)
    employ(MECH, 'MEC1', 'mechanic', 0, true)
    employ(GOVT, 'GOV1', 'government', 2, true)
    -- no qualification rows: grades imply
    DB.on('FROM pf_gov_dept_qualifications WHERE citizenid = ?', function() return {} end)
end

-- an in-memory asset table for the change path
local function assetTable(rows)
    local events = {}
    DB.on('FROM pf_gov_dept_assets WHERE serial = ?', function(_, _, p)
        for _, r in ipairs(rows) do if r.serial == p[1] then local c = {} for k, v in pairs(r) do c[k] = v end return c end end
    end)
    DB.on('FROM pf_gov_dept_assets WHERE id = ?', function(_, _, p)
        for _, r in ipairs(rows) do if r.id == p[1] then local c = {} for k, v in pairs(r) do c[k] = v end return c end end
    end)
    DB.on('FROM pf_gov_dept_asset_events WHERE idem_key = ?', function(_, _, p)
        for _, e in ipairs(events) do if e.idem_key == p[1] then return e end end
    end)
    DB.on('UPDATE pf_gov_dept_assets SET state = ?', function(_, _, p)
        for _, r in ipairs(rows) do
            if r.id == p[8] and r.state == p[9] then
                r.state, r.holder_cid, r.issued_at, r.issued_by, r.issue_ref, r.location, r.updated_at = p[1], p[2], p[3], p[4], p[5], p[6], p[7]
                return 1
            end
        end
        return 0
    end)
    DB.on('INSERT INTO pf_gov_dept_asset_events', function(_, _, p)
        if DB.failEvent then DB.failEvent = nil error('Lost connection to server') end
        events[#events + 1] = { asset_id = p[1], event = p[3], to_state = p[5], holder_cid = p[8], idem_key = p[11] }
        return #events
    end)
    return events
end
local function radio(state, holder)
    return { id = 7, dept = 'police', kind = 'radio', serial = 'PD-RAD-1', state = state or 'in_stock', holder_cid = holder, updated_at = 0, cost = 0, acquired_at = 0 }
end

describe('20E exports: caller allowlists and arguments', function()
    it('every new write or private export refuses an unlisted resource (fail closed)', function()
        Mock.invokingResource = 'some-resource'
        assert_eq(gov:RegisterAsset('police', { kind = 'radio' }, { key = 'k1' }).error, 'not_allowed')
        assert_eq(gov:IssueAsset('PD-RAD-1', 'COP1', { key = 'k1' }).error, 'not_allowed')
        assert_eq(gov:ReturnAsset('PD-RAD-1', { key = 'k1' }).error, 'not_allowed')
        assert_eq(gov:GetAsset('PD-RAD-1').error, 'not_allowed')
        assert_eq(gov:ListAssets('police', {}).error, 'not_allowed')
        assert_eq(gov:RecordTraining('COP1', 'k9_course', 'pass', { key = 'k1' }).error, 'not_allowed')
        assert_eq(gov:ListTraining('COP1', {}).error, 'not_allowed')
        assert_eq(#DB.log, 0, 'nothing reached the database')
        Mock.invokingResource = 'pfm-policejob'
        assert_eq(gov:IssueAsset('bad serial!', 'COP1', { key = 'k1', actor = { src = COP } }).error, 'bad_args')
        assert_eq(gov:IssueAsset('PD-RAD-1', 'COP1', { actor = { src = COP } }).error, 'bad_args', 'a key is required')
        assert_eq(gov:IssueAsset('PD-RAD-1', 'COP1', { key = 'k1', actor = { kind = 'system' } }).error, 'no_permission',
            'only pf-government acts as the system')
        assert_eq(gov:ReturnAsset('PD-RAD-1', { key = 'k1', actor = { src = COP }, to = 'retired' }).error, 'bad_args')
        assert_eq(gov:RegisterAsset('police', { kind = 'monitor' }, { key = 'k1', actor = { src = LT } }).error, 'bad_args',
            'police do not hold rig monitors')
        assert_eq(#DB.log, 0)
    end)
end)

describe('20E asset change path', function()
    it('a failed event insert puts the asset back; the retry with the same key applies once', function()
        local rows = { radio() }
        local events = assetTable(rows)
        DB.failEvent = true
        local r = D.A.Issue('PD-RAD-1', 'COP1', { key = 'iss:1', actor = { src = COP } })
        assert_eq(r.error, 'db_unavailable')
        assert_eq(rows[1].state, 'in_stock', 'the change was put back')
        assert_eq(rows[1].holder_cid, nil)
        local ok = D.A.Issue('PD-RAD-1', 'COP1', { key = 'iss:1', actor = { src = COP } })
        assert_true(ok.ok, ok.error)
        assert_eq(rows[1].state, 'issued')
        assert_eq(#events, 1)
        assert_true(D.A.Issue('PD-RAD-1', 'COP1', { key = 'iss:1', actor = { src = COP } }).duplicate)
        assert_eq(#events, 1)
        local changes = 0
        for _, e in ipairs(Mock.serverEvents) do if e.name == 'pf-government:server:assetChanged' then changes = changes + 1 end end
        assert_eq(changes, 1, 'one assetChanged for the one change')
    end)

    it('issue rules: duty, manager-only issues to others, selfIssue = false, the holder\'s department', function()
        local rows = { radio() }
        assetTable(rows)
        Mock.players[COP].PlayerData.job.onduty = false
        assert_eq(D.A.Issue('PD-RAD-1', 'COP1', { key = 'a1', actor = { src = COP } }).error, 'not_on_duty')
        Mock.players[COP].PlayerData.job.onduty = true
        assert_eq(D.A.Issue('PD-RAD-1', 'LT1', { key = 'a2', actor = { src = COP } }).error, 'no_permission', 'an officer cannot issue to others')
        assert_eq(D.A.Issue('PD-RAD-1', 'COP1', { key = 'a3', actor = { src = MED } }).error, 'no_permission', 'another department')
        assert_eq(D.A.Issue('PD-RAD-1', 'MED1', { key = 'a4', actor = { src = LT } }).error, 'invalid_state', 'a medic cannot hold police equipment')
        rows[1].kind = 'radar'
        assert_eq(D.A.Issue('PD-RAD-1', 'COP1', { key = 'a5', actor = { src = COP } }).error, 'no_permission', 'radar units are manager-issued')
        assert_true(D.A.Issue('PD-RAD-1', 'COP1', { key = 'a6', actor = { src = LT } }).ok)
        assert_eq(rows[1].holder_cid, 'COP1')
        assert_eq(rows[1].issued_by, 'LT1')
        -- returns: the holder or a manager
        assert_eq(D.A.Return('PD-RAD-1', { key = 'r1', actor = { src = MED } }).error, 'no_permission')
        local r = D.A.Return('PD-RAD-1', { key = 'r2', actor = { src = COP }, to = 'lost' })
        assert_true(r.ok)
        assert_eq(rows[1].state, 'lost')
        assert_eq(D.A.Return('PD-RAD-1', { key = 'r3', actor = { src = COP } }).error, 'invalid_state')
    end)
end)

describe('20E armory equipment (B20-2: weapons must not multiply)', function()
    local function armoryRows()
        local rows = {
            { id = 7, dept = 'police', kind = 'sidearm', serial = 'PD-SDA-1', item = 'weapon_pistol', state = 'issued', holder_cid = 'COP1',
                issue_ref = 'armory', issued_at = 100, issued_by = 'COP1', updated_at = 0, cost = 0, acquired_at = 0 },
            { id = 8, dept = 'police', kind = 'sidearm', serial = 'PD-SDA-2', item = 'weapon_pistol', state = 'in_stock', updated_at = 0, cost = 0, acquired_at = 0 },
        }
        assetTable(rows)
        DB.on("WHERE holder_cid = ? AND state = 'lost'", function(_, _, p)
            for _, r in ipairs(rows) do if r.holder_cid == p[1] and r.state == 'lost' and r.issue_ref == p[2] then return { serial = r.serial } end end
        end)
        return rows
    end

    it('neither the holder nor a manager can book an armory-issued weapon back in from the app', function()
        local rows = armoryRows()
        assert_eq(App.returnAsset(COP, { serial = 'PD-SDA-1', key = 'nonce-r001' }).error, 'invalid_state', 'the holder keeps the item: no return outside the armory')
        assert_eq(App.returnAsset(COP, { serial = 'PD-SDA-1', to = 'lost', key = 'nonce-r002' }).error, 'no_permission', 'the holder cannot report it lost')
        assert_eq(App.returnAsset(LT, { serial = 'PD-SDA-1', key = 'nonce-r003' }).error, 'invalid_state', 'a manager cannot book it in')
        assert_eq(App.returnAsset(LT, { serial = 'PD-SDA-1', to = 'maintenance', key = 'nonce-r004' }).error, 'invalid_state')
        assert_eq(rows[1].state, 'issued')
        Mock.invokingResource = 'pf-policemdt-DEV'
        assert_eq(gov:ReturnAsset('PD-SDA-1', { key = 'mdt:r1', actor = { src = COP } }).error, 'invalid_state', 'another allowed resource is not the armory')
        Mock.invokingResource = nil
        assert_eq(rows[1].state, 'issued')
    end)

    it('a manager marks it lost: the holder stays recorded and the armory issues them nothing until resolved', function()
        local rows = armoryRows()
        local r = App.returnAsset(LT, { serial = 'PD-SDA-1', to = 'lost', key = 'nonce-l001' })
        assert_true(r.ok, r.error)
        assert_eq(rows[1].state, 'lost')
        assert_eq(rows[1].holder_cid, 'COP1', 'lost while held by')
        assert_eq(rows[1].issue_ref, 'armory')
        Mock.invokingResource = 'pfm-policejob'
        local again = gov:IssueAsset('PD-SDA-2', 'COP1', { key = 'arm:i2', actor = { src = COP }, ref = 'armory' })
        assert_eq(again.error, 'conflict')
        assert_eq(rows[2].state, 'in_stock')
        Mock.invokingResource = nil
        assert_eq(App.assetAction(LT, { serial = 'PD-SDA-1', action = 'found', key = 'nonce-f001' }).error, 'invalid_state',
            'found from the register would let the item exist twice')
        -- the item turns up at the armory: it books it in, and the officer may draw again
        Mock.invokingResource = 'pfm-policejob'
        local back = gov:ReturnAsset('PD-SDA-1', { key = 'arm:r1', actor = { src = COP } })
        assert_true(back.ok, back.error)
        assert_eq(rows[1].state, 'in_stock')
        assert_eq(rows[1].holder_cid, nil)
        assert_true(gov:IssueAsset('PD-SDA-2', 'COP1', { key = 'arm:i3', actor = { src = COP }, ref = 'armory' }).ok)
        Mock.invokingResource = nil
    end)

    it('a write-off (retire) resolves it; the armory itself books an issued weapon in', function()
        local rows = armoryRows()
        Mock.invokingResource = 'pfm-policejob'
        assert_true(gov:ReturnAsset('PD-SDA-1', { key = 'arm:r9', actor = { src = COP } }).ok)
        assert_eq(rows[1].state, 'in_stock')
        Mock.invokingResource = nil
        rows[1].state, rows[1].holder_cid, rows[1].issue_ref = 'issued', 'COP1', 'armory'
        assert_true(App.returnAsset(LT, { serial = 'PD-SDA-1', to = 'lost', key = 'nonce-l009' }).ok)
        assert_true(App.assetAction(LT, { serial = 'PD-SDA-1', action = 'retire', key = 'nonce-w009' }).ok)
        assert_eq(rows[1].state, 'retired')
        assert_eq(rows[1].holder_cid, nil)
        Mock.invokingResource = 'pfm-policejob'
        assert_true(gov:IssueAsset('PD-SDA-2', 'COP1', { key = 'arm:i9', actor = { src = COP }, ref = 'armory' }).ok)
        Mock.invokingResource = nil
    end)

    it('non-armory equipment keeps the old return rules', function()
        local rows = { radio('issued', 'COP1') }
        assetTable(rows)
        assert_true(App.returnAsset(COP, { serial = 'PD-RAD-1', key = 'nonce-x001' }).ok)
        assert_eq(rows[1].state, 'in_stock')
    end)
end)

describe('20E training grants through the qualification store', function()
    it('a failed grant is finished by a replay of the same training key; never a second grant key', function()
        local calls = {}
        local fail = true
        D.Q.Grant = function(cid, qual, opts, invoker)
            calls[#calls + 1] = { cid = cid, qual = qual, opts = opts, invoker = invoker }
            if fail then return { ok = false, error = 'busy' } end
            return { ok = true, qual = qual, state = 'granted' }
        end
        local stored
        DB.on('FROM pf_gov_dept_training WHERE idem_key = ?', function() return stored end)
        DB.on('SELECT job FROM players WHERE citizenid = ?', function() return nil end)
        DB.on('INSERT INTO pf_gov_dept_training', function(_, _, p)
            stored = { id = 41, citizenid = p[1], dept = p[2], course = p[3], result = p[4], grants_qual = p[7], qual_granted = 0, expires_at = p[8] }
            return 41
        end)
        local granted = 0
        DB.on('UPDATE pf_gov_dept_training SET qual_granted = 1', function() granted = granted + 1; if stored then stored.qual_granted = 1 end return 1 end)
        local r = D.T.Record('COP1', 'k9_course', 'pass', { key = 'tr:1', actor = { src = LT } })
        assert_true(r.ok)
        assert_false(r.granted)
        assert_eq(r.grantError, 'busy')
        assert_eq(granted, 0)
        assert_eq(calls[1].qual, 'k9')
        assert_eq(calls[1].opts.source, 'training')
        assert_eq(calls[1].opts.actor.kind, 'system')
        assert_eq(calls[1].opts.key, 'pf-government:training:41:grant')
        assert_eq(calls[1].invoker, nil, 'the system actor is only accepted from pf-government itself')
        fail = false
        local again = D.T.Record('COP1', 'k9_course', 'pass', { key = 'tr:1', actor = { src = LT } })
        assert_true(again.duplicate)
        assert_true(again.granted)
        assert_eq(calls[2].opts.key, 'pf-government:training:41:grant')
        assert_eq(granted, 1)
        local third = D.T.Record('COP1', 'k9_course', 'pass', { key = 'tr:1', actor = { src = LT } })
        assert_true(third.granted)
        assert_eq(#calls, 2, 'a finished grant is not asked again')
        assert_eq(D.T.Record('COP1', 'swat_course', 'pass', { key = 'tr:1', actor = { src = LT } }).error, 'key_reused')
    end)

    it('instructor and trainee rules', function()
        D.Q.Grant = function() error('must not grant') end
        assert_eq(D.T.Record('COP1', 'k9_course', 'pass', { key = 'x1', actor = { src = COP } }).error, 'no_permission', 'k9 has no instructor qualification: managers only')
        assert_eq(D.T.Record('LT1', 'k9_course', 'pass', { key = 'x2', actor = { src = LT } }).error, 'no_permission', 'own training')
        Mock.players[LT].PlayerData.job.onduty = false
        assert_eq(D.T.Record('COP1', 'k9_course', 'pass', { key = 'x3', actor = { src = LT } }).error, 'not_on_duty')
        Mock.players[LT].PlayerData.job.onduty = true
        assert_eq(D.T.Record('COP1', 'emt_course', 'pass', { key = 'x4', actor = { src = LT } }).error, 'no_permission', 'another department\'s course')
        assert_eq(D.T.Record('COP1', 'k9_course', 'passed', { key = 'x5', actor = { src = LT } }).error, 'bad_args')
        assert_eq(D.T.Record('COP1', 'k9_course', 'pass', { key = 'x6', actor = { kind = 'system' } }, nil).error, 'no_permission')
    end)
end)

describe('20E payroll', function()
    it('an unreadable ledger fails the whole report; the period limit; who may read', function()
        DB.on('FROM pf_transactions', function() error("Table 'pf_transactions' doesn't exist") end)
        assert_eq(D.P.Build('police', 1000, 2000).error, 'bank_unavailable')
        assert_eq(D.P.Build('police', 2000, 1000).error, 'bad_args')
        assert_eq(D.P.Build('police', 0, 93 * 86400).error, 'bad_args')
        assert_eq(D.P.Build('nowhere', 0, 10).error, 'bad_args')
        assert_true(D.P.CanView(LT, 'police'))
        assert_false(D.P.CanView(COP, 'police'))
        assert_false(D.P.CanView(LT, 'ems'))
        assert_false(D.P.CanView(MECH, 'police'))
        local saved = HasPermission
        HasPermission = function(src, perm) return src == GOVT and perm == 'budgets' end
        assert_true(D.P.CanView(GOVT, 'police'), 'a budget official reads any department')
        HasPermission = saved
    end)

    it('a wage query covers state wages of the department\'s jobs and its societies only', function()
        local seen
        DB.on('FROM pf_transactions', function(_, q, p) seen = { q = q, p = p } return {} end)
        DB.on('FROM pf_gov_dept_shifts', function() return {} end)
        DB.on('FROM pf_gov_budget_transactions', function() return {} end)
        local r = D.P.Build('doj', 1000, 2000)
        assert_true(r.ok, r.error)
        assert_true(seen.q:find("kind = 'wage'", 1, true) ~= nil)
        -- doj and judge jobs: society:doj, society:judge, and system:paycheck only for those jobs
        assert_eq(seen.p[3], 'society:doj')
        assert_eq(seen.p[4], 'society:judge')
        assert_eq(seen.p[5], 'doj')
        assert_eq(seen.p[6], 'judge')
        assert_true(seen.q:find("from_account = 'system:paycheck' AND JSON_VALUE(metadata, '$.job') IN", 1, true) ~= nil)
    end)
end)

describe('20E department app handlers check the role on the server', function()
    it('non-members, non-managers and other departments are refused before any change', function()
        local called = {}
        for _, name in ipairs({ 'Register', 'Issue', 'Return', 'Move' }) do
            local orig = D.A[name]
            D.A[name] = function(...) called[#called + 1] = name return orig(...) end
        end
        assert_eq(App.overview(MECH).error, 'no_permission')
        assert_eq(App.roster(COP).error, 'no_permission')
        assert_eq(App.registerAsset(COP, { kind = 'radio', key = 'nonce-0001' }).error, 'no_permission')
        assert_eq(App.assetAction(COP, { serial = 'PD-RAD-1', action = 'retire', key = 'nonce-0002' }).error, 'no_permission')
        assert_eq(App.procurements(COP).error, 'no_permission')
        assert_eq(App.payroll(COP, { from = 1, to = 2 }).error, 'no_permission')
        assert_eq(App.budget(LT, { dept = 'ems' }).error, 'no_permission', 'a police manager cannot read the EMS budget')
        assert_eq(App.grantQual(COP, { cid = 'MED1', qual = 'k9', key = 'nonce-0003' }).error, 'no_permission')
        assert_eq(App.grantQual(LT, { cid = 'COP1', qual = 'surgeon', key = 'nonce-0004' }).error, 'bad_args', 'another department\'s qualification')
        assert_eq(App.member(COP, { cid = 'LT1' }).error, 'no_permission')
        assert_eq(App.training(COP, { cid = 'LT1' }).error, 'no_permission')
        assert_eq(App.registerAsset(LT, { kind = 'radio' }).error, 'bad_args', 'a write needs a request key')
        -- an asset of another department is not found for this viewer
        assetTable({ { id = 9, dept = 'ems', kind = 'aed', serial = 'EMS-AED-1', state = 'in_stock', updated_at = 0, cost = 0, acquired_at = 0 } })
        assert_eq(App.issueAsset(LT, { serial = 'EMS-AED-1', cid = 'LT1', key = 'nonce-0005' }).error, 'not_found')
        assert_eq(App.assetHistory(LT, { serial = 'EMS-AED-1' }).error, 'not_found')
        assert_eq(#called, 0, 'no asset change was attempted')
        assert_eq(logged('UPDATE pf_gov_dept_assets'), 0)
    end)

    it('client keys are namespaced per viewer; a non-manager sees only their own assets and shifts', function()
        local got
        D.A.Register = function(dept, spec, opts) got = { dept = dept, spec = spec, opts = opts } return { ok = true } end
        assert_true(App.registerAsset(LT, { kind = 'radio', key = 'nonce-1234', serial = 'X1' }).ok)
        assert_eq(got.opts.key, 'pf-government:app:LT1:nonce-1234')
        assert_eq(got.dept, 'police', 'the viewer\'s department, never the client\'s')
        assert_eq(got.opts.actor.src, LT)
        local filter
        local origList = D.A.List
        D.A.List = function(dept, f) filter = f return { ok = true, list = {} } end
        App.assets(COP, { holder = 'LT1' })
        assert_eq(filter.holder, 'COP1')
        App.assets(LT, { holder = 'COP1' })
        assert_eq(filter.holder, 'COP1')
        D.A.List = origList
        local sf
        local origS = D.S.List
        D.S.List = function(dept, f) sf = { dept = dept, f = f } return { ok = true, list = {} } end
        App.shifts(COP, { cid = 'LT1' })
        assert_eq(sf.f.viewer, COP, 'ListShifts limits a non-manager to their own shifts')
        D.S.List = origS
    end)

    it('roster: the boss\'s own job comes from pfm-management, the other department jobs from the players table', function()
        started['pfm-management'] = true
        local asked
        Mock.exportsByResource['pfm-management'] = {
            ListEmployees = function(_, src, scope)
                asked = { src = src, scope = scope }
                return { { citizenid = 'DOJ9', name = 'Pat Clerk', grade = { level = 0, name = 'Clerk' }, isboss = false, online = false, onduty = false } }
            end,
        }
        employ(7, 'DOJB', 'doj', 4, true, true)
        local playersQuery
        DB.on("FROM players\n        WHERE JSON_VALUE(job, '$.name') IN", function(_, q, p)
            playersQuery = p
            return { { citizenid = 'JUD1', charinfo = '{"firstname":"Jo","lastname":"Judge"}', job = '{"name":"judge","grade":{"level":1,"name":"Judge"}}' } }
        end)
        local r = App.roster(7)
        assert_true(r.ok, r.error)
        assert_eq(asked.src, 7)
        assert_eq(asked.scope, 'job')
        assert_eq(#playersQuery, 1)
        assert_eq(playersQuery[1], 'judge', 'only the jobs pfm-management did not list')
        local by = {}
        for _, e in ipairs(r.list) do by[e.cid] = e end
        assert_eq(by.DOJ9.name, 'Pat Clerk')
        assert_eq(by.JUD1.name, 'Jo Judge')
        assert_eq(by.JUD1.job, 'judge')
        started['pfm-management'] = nil
        Mock.exportsByResource['pfm-management'] = nil
    end)

    it('purchases go through GovDept.Procurement with a namespaced key, managers only', function()
        local saved = D.Procurement
        local got
        D.Procurement = { Create = function(src, buyerId, cart, opts) got = { src = src, buyerId = buyerId, cart = cart, opts = opts } return { ok = true } end,
            Cancel = function(src, id) got = { cancel = id, src = src } return { ok = true } end, Catalog = function() return { ok = true } end }
        assert_eq(App.placeProcurement(COP, { buyerId = 'police:mrpd_armory', cart = { { name = 'radio', quantity = 1 } }, key = 'nonce-5555' }).error, 'no_permission')
        assert_eq(got, nil)
        assert_true(App.placeProcurement(LT, { buyerId = 'police:mrpd_armory', cart = { { name = 'radio', quantity = 1 } }, key = 'nonce-5555' }).ok)
        assert_eq(got.src, LT)
        assert_eq(got.opts.key, 'pf-government:app:LT1:nonce-5555')
        assert_eq(App.cancelProcurement(COP, { id = 3 }).error, 'no_permission')
        assert_true(App.cancelProcurement(LT, { id = 3 }).ok)
        assert_eq(got.cancel, 3)
        D.Procurement = nil
        assert_eq(App.placeProcurement(LT, { buyerId = 'x', cart = {}, key = 'nonce-6666' }).error, 'unavailable')
        D.Procurement = saved
    end)

    it('the app is offered only when its module ships, to every department job', function()
        assert_eq(GovApps.Get('department'), nil, 'html/apps/department.js is not there: no app on the devices')
        moduleShips = true
        load_resource('[pfscripts]/pf-government/server/apps/department.lua')
        local entry = GovApps.Get('department')
        assert_true(entry ~= nil)
        assert_eq(entry.def.access.jobs.police, 0)
        assert_eq(entry.def.access.jobs.judge, 0)
        assert_eq(entry.def.access.jobs.mechanic, nil)
        assert_true(type(entry.handlers.roster) == 'function')
        moduleShips = false
    end)
end)
