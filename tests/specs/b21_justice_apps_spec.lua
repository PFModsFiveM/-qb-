-- Batch 21, unit 21F: pf-justice apps on pf-devices (server/apps.lua), mocked. The SQL of the lists and the
-- full flows (file -> schedule -> decide, pay on the ledger) run on the real database in
-- realdb_specs/b21_justice_apps_realdb_spec.lua.
--   * registration: three module apps (court, community-service, justice-records) with their handlers; the
--     manifest serves the module files and loads apps.lua after api.lua;
--   * access and roles from the server (job, grade, duty, ACE), never from the client;
--   * idempotency keys are made on the server, bound to the player, the character and the form;
--   * every handler relays to the existing module with actor = { src } and only the fields that module
--     reads (decisions, sentences, court orders, supervision, community service, PayOrder, ContestCitation);
--   * the citizen portal works on the caller's own records only; the IA complaint goes to pf-policemdt-DEV
--     FileIaComplaint with actor = { src } and a server key;
--   * pushes to the Court app carry ids only.
load_resource('tests/lua/fivem_mocks.lua')
vec3 = vec3 or vector3
local resStates = {}
function GetResourceState(name) return resStates[name] or 'missing' end
function GetCurrentResourceName() return 'pf-justice' end
Mock.clock = Mock.clock or 1800000000

-- a programmable database: answers[i] = { pat, kind?, fn(params, sql) }; every call is recorded
local queries, answers = {}, {}
local function answer(kind, q, p)
    queries[#queries + 1] = { kind = kind, q = q, p = p }
    for _, a in ipairs(answers) do
        if (a.kind == nil or a.kind == kind) and type(q) == 'string' and q:find(a.pat, 1, true) then return a.fn(p, q) end
    end
    if kind == 'query' then return {} end
    if kind == 'update' then return 0 end
    return nil
end
MySQL = setmetatable({}, { __index = function(_, kind)
    return setmetatable({ await = function(q, p) return answer(kind, q, p) end }, { __call = function(_, q, p) return answer(kind, q, p) end })
end })

Config = nil
local FILES = { 'config.lua', 'shared/states.lua', 'shared/cs_tasks.lua', 'server/main.lua', 'server/schema.lua', 'server/orders.lua',
    'server/clock.lua', 'server/records.lua', 'server/custody.lua', 'server/booking.lua', 'server/property.lua', 'server/bail.lua',
    'server/legacy_import.lua', 'server/compat.lua', 'server/courts.lua', 'server/warrants.lua', 'server/supervision.lua',
    'server/monitors.lua', 'server/community_service.lua', 'server/restitution.lua', 'server/api.lua', 'server/apps.lua' }
for _, f in ipairs(FILES) do load_resource('[pfscripts]/pf-justice/' .. f) end
local J = PFJustice
local A = J.Apps

-- pf-devices and the police MDT as pf-justice sees them
local registered, registeredHandlers, pushes, iaCalls, iaAnswer = {}, {}, {}, {}, nil
local function stubExports()
    Mock.exportsByResource['pf-devices'] = {
        RegisterApp = function(_, def) registered[def.id] = def return true end,
        RegisterAppHandlers = function(_, id, map) registeredHandlers[id] = map return true end,
        PushToJob = function(_, job, app, event, payload, onduty) pushes[#pushes + 1] = { job = job, app = app, event = event, payload = payload, onduty = onduty } end,
    }
    Mock.exportsByResource['pf-policemdt-DEV'] = {
        FileIaComplaint = function(_, spec, opts) iaCalls[#iaCalls + 1] = { spec = spec, opts = opts } return iaAnswer or { ok = true, complaintId = 77, state = 'received' } end,
    }
end

local JUDGE, CLERK, PROS, DEF, LAWYER, COP, SGT, CIV, PO, ADMIN, CIV2, OFFDOJ, GOVSUP = 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13
local function player(src, cid, job, grade, onduty, jtype)
    local P = Mock.newPlayer(src, cid)
    P.PlayerData.job = { name = job, type = jtype, grade = { level = grade }, onduty = onduty ~= false }
    return P
end

-- one handler of an app, called as pf-devices calls it (src, payload, ctx)
local function rpc(app, method, src, payload)
    for _, entry in ipairs(A.Defs) do
        if entry.def.id == app then return entry.handlers[method](src, payload or {}, { app = app, method = method }) end
    end
    error('no app ' .. app)
end

-- module functions replaced for a test and put back before the next
local saved = {}
local function stub(tbl, name, fn)
    saved[#saved + 1] = { tbl = tbl, name = name, fn = tbl[name] }
    tbl[name] = fn
end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    Mock.aces = {}
    Mock.coords = {}
    Mock.invokingResource = nil
    for i = #saved, 1, -1 do saved[i].tbl[saved[i].name] = saved[i].fn end
    saved = {}
    queries, answers, registered, registeredHandlers, pushes, iaCalls, iaAnswer = {}, {}, {}, {}, {}, {}, nil
    resStates = { ['pf-devices'] = 'started', ['pf-policemdt-DEV'] = 'started', ['pf-government'] = 'started' }
    stubExports()
    J.ready = true
    J.Schema.Has = function() return true end
    A.keys, A.csAccess = {}, {}
    J.Rate.Forget('')
    player(JUDGE, 'JUDGE1', 'judge', 0)
    player(CLERK, 'DOJ0', 'doj', 0)
    player(PROS, 'DOJ1', 'doj', 1)
    player(DEF, 'DOJ2', 'doj', 2)
    player(LAWYER, 'LAW1', 'lawyer', 0)
    player(COP, 'COP1', 'police', 2, true, 'leo')
    player(SGT, 'SGT1', 'police', 4, true, 'leo')
    player(CIV, 'CIV1', 'unemployed', 0)
    player(PO, 'PO1', 'doj', 3)
    player(ADMIN, 'ADM1', 'unemployed', 0)
    player(CIV2, 'CIV2', 'unemployed', 0)
    player(OFFDOJ, 'DOJOFF', 'doj', 1, false)
    player(GOVSUP, 'GOV1', 'government', 0)
    Mock.aces[ADMIN] = { command = true }
end

describe('registration and manifest', function()
    it('registers the three module apps with their handlers on pf-devices', function()
        assert_true(A.RegisterAll())
        assert_eq(registered['court'].entry, 'html/apps/court.js')
        assert_eq(registered['community-service'].entry, 'html/apps/cs.js')
        assert_eq(registered['justice-records'].entry, 'html/apps/records.js')
        for _, id in ipairs({ 'court', 'community-service', 'justice-records' }) do
            assert_eq(registered[id].styles[1], 'html/apps/justice.css')
            assert_true(registered[id].devices[1] == 'tablet' and registered[id].devices[2] == 'computer')
        end
        assert_true(registered['court'].access.handler == true and registered['community-service'].access.handler == true)
        assert_true(registered['justice-records'].access.anyone == true)
        for _, m in ipairs({ '__access', 'me', 'key', 'docket', 'cases', 'case', 'schedule', 'decide', 'file', 'warrants', 'decideWarrant',
            'courtOrders', 'issueOrder', 'revokeOrder', 'caseload', 'supervision', 'appointment', 'checkIn', 'violation', 'monitor' }) do
            assert_true(Mock.callable(registeredHandlers['court'][m]), 'court.' .. m)
        end
        for _, m in ipairs({ 'pay', 'contest', 'iaForm', 'fileComplaint', 'record', 'court', 'sentence', 'fines' }) do
            assert_true(Mock.callable(registeredHandlers['justice-records'][m]), 'records.' .. m)
        end
        for _, m in ipairs({ 'state', 'startShift', 'endShift', 'listWork', 'claim', 'abandon', 'complete', 'board', 'nearby', 'verify', 'orders' }) do
            assert_true(Mock.callable(registeredHandlers['community-service'][m]), 'cs.' .. m)
        end
    end)

    it('does nothing while pf-devices is not running, and registers again when it starts', function()
        resStates['pf-devices'] = 'missing'
        assert_false(A.RegisterAll())
        assert_eq(next(registered), nil)
        resStates['pf-devices'] = 'started'
        Mock.eventHandlers['onResourceStart']('pf-devices')
        assert_true(registered['court'] ~= nil)
    end)

    it('the manifest serves the module files and loads apps.lua after api.lua', function()
        local lists = {}
        local function capture(name) return function(v) lists[name] = v end end
        for _, k in ipairs({ 'fx_version', 'game', 'author', 'description', 'version', 'lua54' }) do _G[k] = function() end end
        for _, k in ipairs({ 'dependencies', 'shared_scripts', 'server_scripts', 'client_scripts', 'files' }) do _G[k] = capture(k) end
        load_resource('[pfscripts]/pf-justice/fxmanifest.lua')
        local pos = {}
        for i, f in ipairs(lists.server_scripts) do pos[f] = i end
        assert_true(pos['server/apps.lua'] == pos['server/api.lua'] + 1, 'apps.lua right after api.lua')
        local files = {}
        for _, f in ipairs(lists.files or {}) do files[f] = true end
        for _, f in ipairs({ 'html/apps/court.js', 'html/apps/cs.js', 'html/apps/records.js', 'html/apps/justice.css' }) do assert_true(files[f], f) end
    end)
end)

describe('access and roles come from the server', function()
    local function access(app, src) return rpc(app, '__access', src) end

    it('the Court app opens for court jobs, probation officers, fallback police and admins only', function()
        for _, src in ipairs({ JUDGE, CLERK, PROS, DEF, LAWYER, SGT, PO, ADMIN, OFFDOJ }) do assert_true(access('court', src), 'src ' .. src) end
        assert_false(access('court', COP), 'a patrol officer below the fallback grade')
        assert_false(access('court', CIV))
        Config.Courts.WarrantFallback.Enabled = false
        assert_false(access('court', SGT), 'no fallback, no court app for police')
        Config.Courts.WarrantFallback.Enabled = true
    end)

    it('me answers the roles from job, grade and duty; off duty shows why', function()
        local me = rpc('court', 'me', JUDGE)
        assert_true(me.ok and me.roles.judge and me.roles.court and me.roles.warrants)
        assert_false(me.roles.clerk)
        local pros = rpc('court', 'me', PROS)
        assert_true(pros.roles.prosecutor and not pros.roles.judge and not pros.roles.warrants)
        local def = rpc('court', 'me', LAWYER)
        assert_true(def.roles.defender and not def.roles.prosecutor)
        local off = rpc('court', 'me', OFFDOJ)
        assert_false(off.roles.court)
        assert_true(off.offDuty)
        local po = rpc('court', 'me', PO)
        assert_true(po.roles.probation)
        local sgt = rpc('court', 'me', SGT)
        assert_true(sgt.roles.warrants and not sgt.roles.court)
        local adm = rpc('court', 'me', ADMIN)
        assert_true(adm.roles.admin and adm.roles.judge)
        assert_true(#me.courtrooms >= 1 and #me.facilities >= 1 and #me.violationTypes >= 1)
    end)

    it('every court handler refuses a player without the role, before any database work', function()
        local n = #queries
        assert_eq(rpc('court', 'docket', CIV).error, 'no_permission')
        assert_eq(rpc('court', 'cases', COP).error, 'no_permission')
        assert_eq(rpc('court', 'cases', OFFDOJ).error, 'not_on_duty')
        assert_eq(rpc('court', 'courtOrders', PROS).error, 'no_permission')
        assert_eq(rpc('court', 'issueOrder', CLERK, { kind = 'search' }).error, 'no_permission')
        assert_eq(rpc('court', 'caseload', PROS).error, 'no_permission')
        assert_eq(rpc('court', 'warrants', COP).error, 'no_permission')
        assert_eq(#queries, n, 'no query was run')
    end)

    it('a verdict by a clerk is refused by Courts.RecordDecision itself (the app only relays)', function()
        local key = rpc('court', 'key', CLERK, { scope = 'decision' }).key
        local res = rpc('court', 'decide', CLERK, { caseId = 5, key = key, decision = { kind = 'verdict', verdict = 'guilty' } })
        assert_eq(res.error, 'no_permission')
        for _, q in ipairs(queries) do assert_false(q.q:find('INSERT', 1, true) ~= nil, 'nothing written') end
    end)

    it('the Community Service app opens for supervisor jobs and for citizens with an open order', function()
        assert_true(rpc('community-service', '__access', PO))
        assert_true(rpc('community-service', '__access', GOVSUP))
        assert_false(rpc('community-service', '__access', CIV))
        answers[#answers + 1] = { pat = "kind = 'community_service'", kind = 'query', fn = function(p)
            if p[1] == 'CIV2' then return { { id = 9, citizenid = 'CIV2', kind = 'community_service', state = 'assigned', units = 5, units_done = 0, due_at = 1 } } end
            return {}
        end }
        assert_true(rpc('community-service', '__access', CIV2))
        assert_false(rpc('community-service', '__access', CIV), 'cached refusal stays a refusal')
    end)
end)

describe('server-made keys', function()
    it('a form key works only for the player, the character and the form it was made for', function()
        local got
        stub(J.Courts, 'RecordDecision', function(caseId, decision, opts, ctx) got = { caseId = caseId, decision = decision, opts = opts, ctx = ctx } return { ok = true, decisionId = 1 } end)
        assert_eq(rpc('court', 'decide', JUDGE, { caseId = 5, decision = { kind = 'plea', plea = 'guilty' } }).error, 'bad_key')
        assert_eq(rpc('court', 'decide', JUDGE, { caseId = 5, key = 'pf-justice:app:decision:made-up', decision = { kind = 'plea', plea = 'guilty' } }).error, 'bad_key')
        local key = rpc('court', 'key', JUDGE, { scope = 'decision' }).key
        assert_true(type(key) == 'string' and key:find('^pf%-justice:app:decision:') ~= nil)
        assert_eq(rpc('court', 'key', JUDGE, { scope = 'ia' }).error, 'bad_args', 'the court app makes no complaint keys')
        assert_eq(rpc('court', 'key', JUDGE, { scope = 'whatever' }).error, 'bad_args')
        local hearingKey = rpc('court', 'key', JUDGE, { scope = 'hearing' }).key
        assert_eq(rpc('court', 'decide', JUDGE, { caseId = 5, key = hearingKey, decision = { kind = 'plea', plea = 'guilty' } }).error, 'bad_key', 'another form')
        assert_eq(rpc('court', 'decide', PROS, { caseId = 5, key = key, decision = { kind = 'dismissal' } }).error, 'bad_key', 'another player')
        assert_true(rpc('court', 'decide', JUDGE, { caseId = 5, key = key, decision = { kind = 'plea', plea = 'guilty' } }).ok)
        assert_eq(got.opts.key, key)
        assert_eq(got.opts.actor.src, JUDGE)
        -- a retry with the same key is the same action (the module answers duplicate)
        assert_true(rpc('court', 'decide', JUDGE, { caseId = 5, key = key, decision = { kind = 'plea', plea = 'guilty' } }).ok)
        assert_eq(got.opts.key, key)
        -- a new character on the same server id starts without the old keys
        Mock.newPlayer(JUDGE, 'JUDGE2').PlayerData.job = { name = 'judge', grade = { level = 0 }, onduty = true }
        assert_eq(rpc('court', 'decide', JUDGE, { caseId = 5, key = key, decision = { kind = 'plea', plea = 'guilty' } }).error, 'bad_key')
    end)

    it('only the 30 newest keys of a player stay valid', function()
        local first = A.IssueKey(JUDGE, 'decision')
        for _ = 1, 30 do A.IssueKey(JUDGE, 'decision') end
        assert_eq(A.TakeKey(JUDGE, 'decision', first), nil)
    end)
end)

describe('court handlers relay to the court module with actor = { src }', function()
    it('a decision carries only the fields RecordDecision reads (no client source, clock or coordinates)', function()
        local got
        stub(J.Courts, 'RecordDecision', function(caseId, decision, opts) got = { caseId = caseId, decision = decision, opts = opts } return { ok = true } end)
        local key = rpc('court', 'key', JUDGE, { scope = 'decision' }).key
        rpc('court', 'decide', JUDGE, { caseId = 12, key = key, decision = { kind = 'sentence', note = 'n', plea = 'x', orders = {
            { kind = 'jail', minutes = 30, facility = 'bolingbroke', clock = 'realtime', sourceRef = { type = 'admin' }, cid = 'SOMEONE' },
            { kind = 'probation', days = 30, conditions = { { kind = 'checkin', everyDays = 7 }, { kind = 'no_go', zone = { x = 1, y = 2 } } } },
        } } })
        assert_eq(got.caseId, 12)
        local o1, o2 = got.decision.orders[1], got.decision.orders[2]
        assert_true(o1.kind == 'jail' and o1.minutes == 30 and o1.facility == 'bolingbroke')
        assert_true(o1.clock == nil and o1.sourceRef == nil and o1.cid == nil, 'no fields the court does not read')
        assert_eq(got.decision.plea, nil, 'only the fields of the decision kind')
        assert_eq(o2.conditions[1].everyDays, 7)
        assert_eq(o2.conditions[2].zone, nil, 'no client coordinates')
        assert_eq(rpc('court', 'decide', JUDGE, { caseId = 12, key = key, decision = { kind = 'sentence', orders = {} } }).error, 'bad_args')
    end)

    it('schedule, file, court orders, revoke and warrant decisions pass the player and a server key', function()
        local calls = {}
        local function rec(name) return function(...) calls[name] = { ... } return { ok = true } end end
        stub(J.Courts, 'ScheduleHearing', rec('schedule'))
        stub(J.Courts, 'FileCase', rec('file'))
        stub(J.Courts, 'IssueCourtOrder', rec('issue'))
        stub(J.Courts, 'RevokeCourtOrder', rec('revoke'))
        stub(J.Warrants, 'Decide', rec('warrant'))
        local hk = rpc('court', 'key', CLERK, { scope = 'hearing' }).key
        assert_true(rpc('court', 'schedule', CLERK, { caseId = 3, kind = 'trial', at = 1800003600, courtroom = 'courtroom_2', notes = 'n', key = hk }).ok)
        assert_true(calls.schedule[1] == 3 and calls.schedule[2].kind == 'trial' and calls.schedule[2].at == 1800003600)
        assert_true(calls.schedule[3].actor.src == CLERK and calls.schedule[3].key == hk)
        assert_eq(rpc('court', 'schedule', PROS, { caseId = 3, kind = 'trial', key = hk }).error, 'no_permission')
        local fk = rpc('court', 'key', PROS, { scope = 'file' }).key
        assert_true(rpc('court', 'file', PROS, { cid = 'CIV1', kind = 'criminal', charges = { { code = 'PC-484', label = 'Theft' } }, custodyId = 4, key = fk }).ok)
        local spec = calls.file[1]
        assert_true(spec.cid == 'CIV1' and spec.charges[1].code == 'PC-484' and spec.custodyId == nil, 'no custody link from the app')
        assert_eq(spec.prosecutorCid, 'DOJ1', 'the prosecutor is the player, read on the server')
        assert_eq(calls.file[2].key, fk)
        assert_eq(rpc('court', 'file', PROS, { cid = 'bad cid!', charges = {}, key = rpc('court', 'key', PROS, { scope = 'file' }).key }).error, 'bad_args')
        local ok = rpc('court', 'key', JUDGE, { scope = 'courtorder' }).key
        assert_true(rpc('court', 'issueOrder', JUDGE, { kind = 'evidence_destroy', evidenceIds = '12, 13', hours = 24, key = ok }).ok)
        assert_true(calls.issue[1].evidenceIds[1] == '12' and calls.issue[1].evidenceIds[2] == '13' and calls.issue[2].key == ok)
        assert_true(rpc('court', 'revokeOrder', JUDGE, { ref = 'CO-2611-4', reason = 'done' }).ok)
        assert_true(calls.revoke[1] == 'CO-2611-4' and calls.revoke[2].actor.src == JUDGE)
        assert_true(rpc('court', 'decideWarrant', JUDGE, { reviewId = 8, decision = 'deny', note = 'thin' }).ok)
        assert_true(calls.warrant[1] == 8 and calls.warrant[2] == 'deny' and calls.warrant[3].note == 'thin' and calls.warrant[3].actor.src == JUDGE)
    end)

    it('the case list builds its filter on the server: fixed sorts, escaped search, pages of 25', function()
        local sql, params
        answers[#answers + 1] = { pat = 'FROM pf_justice_cases', kind = 'query', fn = function(p, q) sql, params = q, p
            local rows = {}
            for i = 1, 26 do rows[i] = { id = i, case_no = 'CR26-' .. i, citizenid = 'CIV1', state = 'filed', kind = 'criminal', filed_at = 1 } end
            return rows
        end }
        answers[#answers + 1] = { pat = 'FROM players', kind = 'query', fn = function() return { { citizenid = 'CIV1', charinfo = '{"firstname":"Ann","lastname":"Lee"}' } } end }
        local res = rpc('court', 'cases', JUDGE, { scope = 'mine', kind = 'criminal', q = 'an_n', sort = 'case_no', page = 2 })
        assert_true(res.ok, tostring(res.error))
        assert_true(res.more and #res.list == 25 and res.page == 2)
        assert_eq(res.list[1].name, 'Ann Lee')
        assert_true(sql:find('ORDER BY case_no ASC', 1, true) ~= nil)
        assert_true(sql:find('judge_cid = ? OR prosecutor_cid = ? OR defender_cid = ?', 1, true) ~= nil)
        assert_eq(params[1], 'JUDGE1')
        assert_eq(params[5], 'an\\_n%', 'LIKE wildcards are escaped')
        assert_eq(rpc('court', 'cases', JUDGE, { q = '100%' }).error, 'bad_search', 'no wildcard reaches LIKE')
        assert_eq(params[#params], 25, 'offset of page 2')
        assert_eq(params[#params - 1], 26, 'one extra row tells whether there is a next page')
        assert_eq(rpc('court', 'cases', JUDGE, { sort = 'id; DROP TABLE players' }).error, 'bad_args')
        assert_eq(rpc('court', 'cases', JUDGE, { scope = 'nobody' }).error, 'bad_args')
        assert_eq(rpc('court', 'cases', JUDGE, { q = '<img>' }).error, 'bad_search')
    end)

    it('warrant reviews: judges read every state; fallback police read the waiting ones and see what they may decide', function()
        answers[#answers + 1] = { pat = 'FROM pf_justice_warrant_reviews WHERE state = ?', kind = 'query', fn = function(p)
            return { { id = 4, warrant_id = 'W1', type = 'arrest', target_cid = 'CIV1', affidavit = 'a', requested_by = 'SGT1', state = p[1], requested_at = 1 },
                { id = 5, warrant_id = 'W2', type = 'arrest', target_cid = 'CIV1', affidavit = 'b', requested_by = 'COP1', state = p[1], requested_at = 1 } }
        end }
        local j = rpc('court', 'warrants', JUDGE, { state = 'requested' })
        assert_true(j.ok and j.list[1].canDecide and j.list[2].canDecide)
        assert_true(rpc('court', 'warrants', JUDGE, { state = 'approved' }).ok)
        assert_eq(rpc('court', 'warrants', JUDGE, { state = 'nonsense' }).error, 'bad_args')
        J.Courts.lastJudgeAt = os.time() - 100000
        Mock.players[JUDGE].PlayerData.job.onduty = false -- the fallback opens only with no judge on duty
        local s = rpc('court', 'warrants', SGT, { state = 'requested' })
        assert_true(s.ok)
        assert_false(s.list[1].canDecide, 'never the requester')
        assert_true(s.list[2].canDecide)
        assert_eq(rpc('court', 'warrants', SGT, { state = 'approved' }).error, 'no_permission')
    end)

    it('probation: caseload scopes, supervision actions relay with a server key', function()
        local sql, params
        answers[#answers + 1] = { pat = 'FROM pf_justice_supervision s JOIN', kind = 'query', fn = function(p, q) sql, params = q, p return {} end }
        assert_true(rpc('court', 'caseload', PO, { scope = 'mine' }).ok)
        assert_true(sql:find('s.officer_cid = ?', 1, true) ~= nil and params[1] == 'PO1')
        assert_true(rpc('court', 'caseload', PO, { scope = 'unassigned' }).ok)
        assert_true(sql:find('s.officer_cid IS NULL', 1, true) ~= nil)
        local calls = {}
        stub(J.Supervision, 'Schedule', function(...) calls.appt = { ... } return { ok = true } end)
        stub(J.Supervision, 'CheckIn', function(...) calls.checkin = { ... } return { ok = true } end)
        stub(J.Supervision, 'Violation', function(...) calls.viol = { ... } return { ok = true } end)
        stub(J.Supervision, 'SetMonitor', function(...) calls.mon = { ... } return { ok = true } end)
        local k = rpc('court', 'key', PO, { scope = 'appointment' }).key
        assert_true(rpc('court', 'appointment', PO, { supId = 3, at = 1800090000, office = 2, minutes = 30, note = 'x', key = k }).ok)
        assert_true(calls.appt[1] == 3 and calls.appt[2].office == 2 and calls.appt[3].key == k and calls.appt[3].actor.src == PO)
        assert_true(rpc('court', 'checkIn', PO, { supId = 3 }).ok)
        assert_true(calls.checkin[1] == 3 and calls.checkin[2].actor.src == PO)
        local vk = rpc('court', 'key', PO, { scope = 'violation' }).key
        assert_true(rpc('court', 'violation', PO, { supId = 3, kind = 'curfew', note = 'late', key = vk }).ok)
        assert_true(calls.viol[2].kind == 'curfew' and calls.viol[3].key == vk)
        assert_true(rpc('court', 'monitor', PO, { cid = 'CIV1', mode = 'home', house = 'h1', zone = 'z' }).ok)
        assert_true(calls.mon[1] == 'CIV1' and calls.mon[2].mode == 'home' and calls.mon[2].house == 'h1' and calls.mon[2].zone == nil)
        assert_true(rpc('court', 'monitor', PO, { cid = 'CIV1', remove = true }).ok)
        assert_eq(calls.mon[2], false)
        assert_eq(rpc('court', 'appointment', COP, { supId = 3 }).error, 'no_permission')
    end)
end)

describe('the citizen portal reads and acts on the caller only', function()
    it('PayOrder on an own order with a key from the order attempt; another person\'s order is not found', function()
        local paid
        stub(J.Orders, 'Row', function(id)
            if id == 21 then return { id = 21, citizenid = 'CIV1', kind = 'fine', state = 'issued', pay_attempt = 0 } end
            if id == 22 then return { id = 22, citizenid = 'CIV2', kind = 'fine', state = 'issued', pay_attempt = 0 } end
            if id == 23 then return { id = 23, citizenid = 'CIV1', kind = 'fine', state = 'issued', pay_attempt = 2 } end
            if id == 24 then return { id = 24, citizenid = 'CIV1', kind = 'fine', state = 'paid', pay_attempt = 1 } end
            return nil
        end)
        stub(J.Orders, 'Pay', function(id, opts, ctx) paid = { id = id, opts = opts } return { ok = true, state = 'paid' } end)
        assert_true(rpc('justice-records', 'pay', CIV, { orderId = 21, account = 'bank', key = 'client-key', payerSrc = 99 }).ok)
        assert_true(paid.id == 21 and paid.opts.payerSrc == CIV and paid.opts.account == 'bank')
        assert_eq(paid.opts.key, 'pf-justice:portal:21:pay:1', 'the key comes from the server, never the client')
        rpc('justice-records', 'pay', CIV, { orderId = 23, account = 'cash' })
        assert_true(paid.opts.key == 'pf-justice:portal:23:pay:3' and paid.opts.account == 'cash', 'a refused attempt moved the counter: a new key')
        paid = nil
        assert_eq(rpc('justice-records', 'pay', CIV, { orderId = 22 }).error, 'not_found')
        assert_eq(paid, nil)
        local done = rpc('justice-records', 'pay', CIV, { orderId = 24 })
        assert_true(done.ok and done.duplicate and paid == nil, 'already paid: nothing charged')
        assert_eq(rpc('justice-records', 'pay', CIV, { orderId = 21, account = 'crypto' }).error, 'bad_args')
    end)

    it('contest relays the player as the actor (ContestCitation checks the cited citizen)', function()
        local got
        stub(J.Orders, 'ContestCitation', function(id, opts) got = { id = id, opts = opts } return { ok = true } end)
        assert_true(rpc('justice-records', 'contest', CIV, { orderId = 30, reason = 'radar', actor = { src = JUDGE } }).ok)
        assert_true(got.id == 30 and got.opts.actor.src == CIV and got.opts.reason == 'radar')
    end)

    it('an IA complaint goes to FileIaComplaint with actor = { src } and a server key; the complainant is never the payload', function()
        assert_eq(rpc('justice-records', 'fileComplaint', CIV, { summary = 'He shoved me at the pier for no reason', officerName = 'Ofc. Ray', key = 'mine' }).error, 'bad_key')
        local form = rpc('justice-records', 'iaForm', CIV)
        assert_true(form.ok and form.key:find('^pf%-justice:app:ia:') ~= nil and #form.categories == 6)
        local res = rpc('justice-records', 'fileComplaint', CIV, { summary = 'He shoved me at the pier for no reason', officerName = 'Ofc. Ray',
            category = 'force', incidentRef = 'INC-4', complainantCid = 'CIV2', officerCid = 'COP1', key = form.key })
        assert_true(res.ok and res.complaintId == 77)
        local call = iaCalls[1]
        assert_true(call.opts.actor.src == CIV and call.opts.key == form.key)
        assert_eq(call.spec.complainantCid, nil, 'pf-policemdt-DEV takes the complainant from actor.src')
        assert_true(call.spec.category == 'force' and call.spec.officerCid == 'COP1' and call.spec.officerName == 'Ofc. Ray' and call.spec.incidentRef == 'INC-4')
        assert_eq(rpc('justice-records', 'fileComplaint', CIV2, { summary = 'x', key = form.key }).error, 'bad_key', 'another player cannot use the key')
        iaAnswer = { ok = false, error = 'rate_limited', message = 'Too many complaints today; IA will contact you' }
        assert_eq(rpc('justice-records', 'fileComplaint', CIV, { summary = 'Another long enough complaint text', officerName = 'x', key = form.key }).error, 'rate_limited')
        resStates['pf-policemdt-DEV'] = 'stopped'
        assert_eq(rpc('justice-records', 'iaForm', CIV).error, 'ia_unavailable')
        assert_eq(rpc('justice-records', 'fileComplaint', CIV, { summary = 'x', key = form.key }).error, 'ia_unavailable')
    end)

    it('the record is read for the caller only and keeps only the public fields', function()
        local asked
        stub(J.Records, 'Get', function(cid, opts, ctx) asked = cid return { ok = true, entries = { { id = 1, kind = 'conviction', summary = 'Fine $100', at = 5,
            refType = 'order', refId = '9', expungedBy = 'X' } } } end)
        local res = rpc('justice-records', 'record', CIV, { cid = 'CIV2' })
        assert_eq(asked, 'CIV1')
        assert_true(res.entries[1].summary == 'Fine $100' and res.entries[1].refType == nil and res.entries[1].expungedBy == nil)
    end)

    it('the sentence view drops the officer\'s violation reports, notes and monitor details', function()
        stub(J.Orders, 'GetActiveIncarceration', function() return { ok = true, remainingSeconds = 600,
            order = { id = 3, kind = 'jail', state = 'active', facility = 'bolingbroke', clock = 'online', requiredSeconds = 1200, servedSeconds = 600 } } end)
        stub(J.Supervision, 'Get', function() return { ok = true, supervision = { id = 1, kind = 'probation', state = 'active',
            violations = { { id = 1 } }, notes = { { id = 2 } }, monitor = { mode = 'home', home = { x = 1, y = 2 } },
            appointments = { { id = 5, state = 'scheduled', detail = { location = 'City Hall', by = 'PO1', calendarId = 3 } } }, checkins = {} } } end)
        stub(J.CS, 'Get', function() return { ok = true, orders = {} } end)
        local res = rpc('justice-records', 'sentence', CIV)
        assert_true(res.ok and res.incarceration.remainingSeconds == 600 and res.incarceration.facility == 'Bolingbroke Penitentiary')
        assert_true(res.supervision.violations == nil and res.supervision.notes == nil)
        assert_true(res.supervision.monitor.mode == 'home' and res.supervision.monitor.home == nil)
        assert_true(res.supervision.appointments[1].detail.location == 'City Hall' and res.supervision.appointments[1].detail.by == nil)
    end)

    it('fines mark what is payable here and what can still be contested', function()
        stub(J.Orders, 'List', function(cid, filter) return { ok = true, list = {
            { id = 1, kind = 'fine', state = 'issued', amount = 100, paidAmount = 0 },
            { id = 2, kind = 'citation', state = 'issued', amount = 50, paidAmount = 0 },
            { id = 3, kind = 'fine', state = 'invoiced', amount = 70, paidAmount = 0 },
            { id = 4, kind = 'citation', state = 'issued', amount = 50, paidAmount = 0 },
        } } end)
        answers[#answers + 1] = { pat = 'FROM pf_justice_citations WHERE order_id IN', kind = 'query', fn = function()
            return { { order_id = 2, violation = 'speeding', contest_until = os.time() + 100 }, { order_id = 4, violation = 'parking', contest_until = os.time() - 1 } }
        end }
        local res = rpc('justice-records', 'fines', CIV)
        assert_true(res.list[1].payable and res.list[1].owed == 100)
        assert_true(res.list[2].contestable and res.list[2].violation == 'speeding')
        assert_false(res.list[3].payable, 'a phone invoice is paid on the phone')
        assert_false(res.list[4].contestable, 'the window closed')
    end)
end)

describe('community service', function()
    it('citizen actions call the runtime for the caller and refresh the world client', function()
        local calls, pushed = {}, {}
        for _, name in ipairs({ 'StartShift', 'EndShift', 'ListWork', 'Claim', 'Abandon', 'Complete' }) do
            stub(J.CS, name, function(...) calls[#calls + 1] = { name = name, args = { ... } } return { ok = true } end)
        end
        stub(J.CS, 'Push', function(src) pushed[#pushed + 1] = src end)
        stub(J.CS, 'Ready', function() return true end)
        assert_true(rpc('community-service', 'startShift', CIV).ok)
        assert_true(rpc('community-service', 'claim', CIV, { workOrderId = 44 }).ok)
        assert_true(rpc('community-service', 'complete', CIV, { taskId = 7 }).ok)
        assert_eq(rpc('community-service', 'complete', CIV, { taskId = 7 }).error, 'rate_limited', 'one per second, like the net events')
        assert_true(calls[1].name == 'StartShift' and calls[1].args[1] == CIV)
        assert_true(calls[2].name == 'Claim' and calls[2].args[2] == 44)
        assert_true(calls[3].name == 'Complete' and calls[3].args[2] == 7)
        assert_eq(#pushed, 3, 'the world markers follow every answer (a refused repeat changed nothing)')
    end)

    it('the sign-off: supervisors only; the nearby list comes from server positions and open shifts', function()
        stub(J.CS, 'Ready', function() return true end)
        stub(J.CS, 'IsSupervisor', function(src) return src == PO end)
        stub(J.CS, 'OpenShift', function(cid) if cid == 'CIV1' or cid == 'CIV2' then return { id = cid == 'CIV1' and 1 or 2, supervisor_cid = nil } end return nil end)
        Mock.coords[PO] = vector3(0, 0, 0)
        Mock.coords[CIV] = vector3(10, 0, 0)
        Mock.coords[CIV2] = vector3(300, 0, 0)
        Mock.coords[JUDGE] = vector3(5, 0, 0)
        assert_eq(rpc('community-service', 'nearby', CIV).error, 'no_permission')
        local res = rpc('community-service', 'nearby', PO)
        assert_true(res.ok)
        assert_eq(#res.list, 1, 'only signed-in workers within reach')
        assert_true(res.list[1].src == CIV and res.list[1].distance == 10)
        local verified
        stub(J.CS, 'Verify', function(sup, target) verified = { sup, target } return { ok = true, shiftId = 1 } end)
        stub(J.CS, 'Push', function() end)
        assert_true(rpc('community-service', 'verify', PO, { target = CIV }).ok)
        assert_true(verified[1] == PO and verified[2] == CIV)
        assert_eq(rpc('community-service', 'verify', CIV, { target = CIV2 }).error, 'no_permission')
    end)
end)

describe('pushes to the Court app', function()
    it('a case or warrant review change pushes ids only, to on-duty judges and DOJ', function()
        Mock.eventHandlers['pf-justice:server:caseChanged']({ id = 5, cid = 'CIV1', charges = { 'x' } }, { action = 'decision' })
        assert_eq(#pushes, 2)
        assert_true(pushes[1].job == 'judge' and pushes[2].job == 'doj' and pushes[1].onduty == true)
        assert_true(pushes[1].event == 'caseChanged' and pushes[1].payload.caseId == 5 and pushes[1].payload.cid == nil)
        Mock.eventHandlers['pf-justice:server:warrantReviewChanged']({ id = 9, affidavit = 'secret' })
        assert_true(pushes[3].event == 'warrantChanged' and pushes[3].payload.reviewId == 9 and pushes[3].payload.affidavit == nil)
    end)
end)
