-- Batch 19, unit 19A (mocked; the SQL and the full flows are in realdb_specs/b19_justice_courts_realdb_spec.lua):
--   * pf-government expungement: civilian:deleteRecord / civilian:clearConvictions no longer DELETE MDT rows;
--     they go through pf-policemdt-DEV ExpungeRecord (soft delete, audited there) and pf-justice Expunge for
--     the justice record's convictions; failures are reported, never a silent success;
--   * pf-justice court exports at the boundary: Config.Callers, the plain boolean of IsCourtOrderValid for the
--     batch-17/18 callers (false when refused or on bad input, never an error), key and argument checks;
--   * court roles (judge, clerk, prosecutor, defender) from job, grade and duty; admins and pf-justice itself;
--   * the warrant fallback: only with no judge on duty, after the wait, never the requester;
--   * the manifest lists the batch-19 files and Config carries the blocks 19B and 19C read.
load_resource('tests/lua/fivem_mocks.lua')
vec3 = vec3 or vector3
vec4 = vec4 or vector4 or function(x, y, z, w) return { x = x, y = y, z = z, w = w } end

local resStates = {}
function GetResourceState(name) return resStates[name] or 'missing' end

-- ── pf-government (only callbacks.lua's two handlers are this unit's) ─────────────────────────
function GetCurrentResourceName() return 'pf-government' end
function GetResourceKvpString() return nil end
function SetResourceKvp() end
function SetTimeout() end
local queries = {}
local function recordingDb(kind)
    return setmetatable({ await = function(q, p) queries[#queries + 1] = { kind = kind, q = q, p = p } return nil end },
        { __call = function(_, q, p) queries[#queries + 1] = { kind = kind, q = q, p = p } end })
end
MySQL = setmetatable({}, { __index = function(_, kind) return recordingDb(kind) end })
Config = nil
load_resource('[pfscripts]/pf-government/config.lua')
for _, f in ipairs({ 'server/core.lua', 'server/callbacks.lua' }) do load_resource('[pfscripts]/pf-government/' .. f) end
function LogAudit() end
function DebugPrint() end
local govConfig = Config
local govMySQL = MySQL
Mock.exportsByResource['__self'] = nil

-- ── pf-justice (19A files) ────────────────────────────────────────────────────────────────────
function GetCurrentResourceName() return 'pf-justice' end
Config = nil
MySQL = setmetatable({}, { __index = function(_, kind) return recordingDb(kind) end })
for _, f in ipairs({ 'config.lua', 'shared/states.lua', 'server/main.lua', 'server/schema.lua', 'server/orders.lua',
    'server/records.lua', 'server/courts.lua', 'server/warrants.lua' }) do
    load_resource('[pfscripts]/pf-justice/' .. f)
end
local juConfig = Config
local juMySQL = MySQL
Mock.exportsByResource['pf-justice-self'] = Mock.exportsByResource['__self']
local J = PFJustice
local Courts, W = J.Courts, J.Warrants
local function juExport(name) return Mock.exportsByResource['pf-justice-self'][name] end

local MAYOR, CLERKGOV, JUDGE, CLERK, PROS, DEF, LAWYER, COP, SGT, CIV = 1, 2, 3, 4, 5, 6, 7, 8, 9, 10
local function useGov() Config = govConfig MySQL = govMySQL GetCurrentResourceName = function() return 'pf-government' end end
local function useJustice() Config = juConfig MySQL = juMySQL GetCurrentResourceName = function() return 'pf-justice' end end

local function nui(src, action, data)
    useGov()
    local before = #Mock.clientEvents
    Mock.fireNet('pf-government:server:nuiCallback', src, 'cb1', action, data or {})
    for i = #Mock.clientEvents, before + 1, -1 do
        local e = Mock.clientEvents[i]
        if e.name == 'pf-government:client:nuiCallback' then return e.args[2] end
    end
end

-- the MDT and pf-justice as pf-government sees them
local mdtCalls, mdtAnswer, juCalls, juRecord, juAnswer = {}, nil, {}, nil, nil
local function stubExports()
    Mock.exportsByResource['pf-policemdt-DEV'] = {
        ExpungeRecord = function(_, spec, opts) mdtCalls[#mdtCalls + 1] = { spec = spec, opts = opts } return mdtAnswer or { ok = true, changed = 2 } end,
    }
    Mock.exportsByResource['pf-justice'] = {
        GetRecord = function(_, cid, opts) juCalls[#juCalls + 1] = { fn = 'GetRecord', cid = cid } return juRecord or { ok = true, entries = {} } end,
        Expunge = function(_, cid, ids, opts) juCalls[#juCalls + 1] = { fn = 'Expunge', cid = cid, ids = ids, opts = opts } return juAnswer or { ok = true, n = #ids } end,
    }
end

local function player(src, cid, jobName, grade, onduty)
    local P = Mock.newPlayer(src, cid)
    P.PlayerData.job = { name = jobName, grade = { level = grade }, onduty = onduty ~= false }
    return P
end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    Mock.aces = {}
    queries, mdtCalls, juCalls, juRecord, juAnswer, mdtAnswer = {}, {}, {}, nil, nil, nil
    resStates = { ['pf-policemdt-DEV'] = 'started', ['pf-justice'] = 'started' }
    stubExports()
    player(MAYOR, 'MAY1', 'government', 4)
    player(CLERKGOV, 'CLK1', 'government', 1)
    player(JUDGE, 'JUDGE1', 'judge', 0)
    player(CLERK, 'DOJ0', 'doj', 0)
    player(PROS, 'DOJ1', 'doj', 1)
    player(DEF, 'DOJ2', 'doj', 2)
    player(LAWYER, 'LAW1', 'lawyer', 0)
    player(COP, 'COP1', 'police', 2)
    player(SGT, 'SGT1', 'police', 4)
    player(CIV, 'CIV1', 'unemployed', 0)
    Mock.invokingResource = nil
    useJustice()
    J.ready = true
end

local function deletes()
    local n = 0
    for _, q in ipairs(queries) do if type(q.q) == 'string' and q.q:upper():find('DELETE') then n = n + 1 end end
    return n
end

describe('pf-government expungement goes through ExpungeRecord and Expunge (no DELETE)', function()
    it('deleteRecord soft-deletes one conviction or incident through the MDT export', function()
        local res = nui(MAYOR, 'civilian:deleteRecord', { recordType = 'conviction', recordId = 5 })
        assert_true(res.ok, tostring(res.error))
        assert_eq(res.changed, 2)
        assert_eq(#mdtCalls, 1)
        assert_eq(mdtCalls[1].spec.type, 'conviction')
        assert_eq(mdtCalls[1].spec.id, 5)
        assert_eq(mdtCalls[1].opts.actorCid, 'MAY1')
        assert_eq(deletes(), 0, 'no hard delete')
        assert_true(nui(MAYOR, 'civilian:deleteRecord', { recordType = 'incident', recordId = 9 }).ok)
        assert_eq(mdtCalls[2].spec.type, 'incident')
        assert_eq(nui(MAYOR, 'civilian:deleteRecord', { recordType = 'warrant', recordId = 9 }).error, 'unsupported_record_type')
        assert_eq(nui(MAYOR, 'civilian:deleteRecord', { recordType = 'incident', recordId = 'x' }).error, 'invalid_input')
        assert_eq(nui(CLERKGOV, 'civilian:deleteRecord', { recordType = 'incident', recordId = 9 }).error, 'no_permission')
        assert_eq(#mdtCalls, 2)
    end)

    it('a refusal or a stopped MDT is reported, never a silent success', function()
        mdtAnswer = { ok = false, error = 'not_allowed' }
        assert_eq(nui(MAYOR, 'civilian:deleteRecord', { recordType = 'conviction', recordId = 5 }).error, 'not_allowed')
        resStates['pf-policemdt-DEV'] = 'stopped'
        assert_eq(nui(MAYOR, 'civilian:deleteRecord', { recordType = 'conviction', recordId = 5 }).error, 'mdt_unavailable')
        assert_eq(nui(MAYOR, 'civilian:clearConvictions', { citizenId = 'CIV1' }).error, 'mdt_unavailable')
        assert_eq(deletes(), 0)
    end)

    it('clearConvictions clears the MDT convictions and expunges the justice conviction entries as the player', function()
        juRecord = { ok = true, entries = { { id = 11, kind = 'conviction' }, { id = 12, kind = 'arrest' }, { id = 13, kind = 'conviction' } } }
        local res = nui(MAYOR, 'civilian:clearConvictions', { citizenId = 'CIV1' })
        assert_true(res.ok, tostring(res.error))
        assert_eq(mdtCalls[1].spec.type, 'convictions')
        assert_eq(mdtCalls[1].spec.citizenId, 'CIV1')
        local ex
        for _, c in ipairs(juCalls) do if c.fn == 'Expunge' then ex = c end end
        assert_true(ex ~= nil, 'Expunge called')
        assert_eq(#ex.ids, 2)
        assert_eq(ex.ids[1], 11)
        assert_eq(ex.ids[2], 13)
        assert_eq(ex.opts.actor.src, MAYOR, 'pf-justice re-checks the records permission of the player')
        assert_eq(res.justiceExpunged, 2)
        assert_eq(deletes(), 0)
        juAnswer = { ok = false, error = 'no_permission' }
        assert_eq(nui(MAYOR, 'civilian:clearConvictions', { citizenId = 'CIV1' }).error, 'justice_no_permission')
        assert_eq(nui(MAYOR, 'civilian:clearConvictions', { citizenId = "x'; DROP" }).error, 'no_citizenid')
    end)
end)

describe('court exports at the boundary', function()
    it('IsCourtOrderValid answers a plain false to callers off the allowlist and on bad input', function()
        J.Schema.Has = function() return true end
        local fn = juExport('IsCourtOrderValid')
        Mock.invokingResource = 'pf-random'
        assert_eq(fn('CO-1', 'medical_records', 'CID1'), false)
        Mock.invokingResource = 'pf-ambulancejob'
        assert_eq(fn(nil, 'medical_records', 'CID1'), false)
        assert_eq(fn('CO-1', 'wiretap', 'CID1'), false, 'unknown purpose')
        assert_eq(fn('CO 1; --', 'medical_records', 'CID1'), false, 'bad ref')
        assert_eq(fn('CO-1', 'medical_records', 'CID1'), false, 'no such order (the DB answers nothing)')
        -- a valid row answers true (the boolean the AJ/PJ callers compare with == true)
        local row = { id = 1, ref = 'CO-1', kind = 'medical_records', citizenid = 'CID1', valid_until = os.time() + 60 }
        MySQL = setmetatable({ single = { await = function() return row end } }, { __index = function(_, k) return recordingDb(k) end })
        assert_eq(fn('CO-1', 'medical_records', 'CID1'), true)
        assert_eq(fn('CO-1', 'medical_records', nil), false, 'the order is about a person')
        row.valid_until = os.time() - 1
        assert_eq(fn('CO-1', 'medical_records', 'CID1'), false, 'expired')
        J.Schema.Has = nil
        J.ready = false
        row.valid_until = os.time() + 60
        assert_eq(fn('CO-1', 'medical_records', 'CID1'), false, 'not ready: fails closed')
    end)

    it('FileCase and RequestWarrantReview check the caller, the key and the arguments before any write', function()
        J.Schema.Has = function() return true end
        Mock.invokingResource = 'pfm-policejob'
        assert_eq(juExport('FileCase')({ cid = 'A1', charges = { { code = 'X' } } }, { key = 'k:1' }).error, 'not_allowed')
        assert_eq(juExport('RequestWarrantReview')({ warrantId = 'W1', type = 'arrest', targetCid = 'A1', requestedBy = 'C1' }, { key = 'k:1' }).error, 'not_allowed')
        Mock.invokingResource = 'pf-policemdt-DEV'
        assert_eq(juExport('FileCase')({ cid = 'A1', charges = { { code = 'X' } } }, {}).error, 'bad_args')
        assert_eq(juExport('FileCase')({ cid = 'bad cid', charges = { { code = 'X' } } }, { key = 'k:1' }).error, 'bad_args')
        assert_eq(juExport('FileCase')({ cid = 'A1', kind = 'divorce', charges = { { code = 'X' } } }, { key = 'k:1' }).error, 'bad_args')
        local rw = juExport('RequestWarrantReview')
        assert_eq(rw({ warrantId = 'W1', type = 'arrest', targetCid = 'A1', requestedBy = 'C1' }, {}).error, 'bad_args', 'key required')
        assert_eq(rw({ warrantId = 'W1', type = 'raid', targetCid = 'A1', requestedBy = 'C1' }, { key = 'k:2' }).error, 'bad_args')
        assert_eq(rw({ warrantId = 'W1', type = 'arrest', requestedBy = 'C1' }, { key = 'k:3' }).error, 'bad_args', 'an arrest names the person')
        assert_eq(rw({ warrantId = 'W1', type = 'search', requestedBy = 'C1' }, { key = 'k:4' }).error, 'bad_args', 'a search names a person or address')
        J.Schema.Has = nil
    end)

    it('the write exports a judge app uses are closed to other resources', function()
        for _, name in ipairs({ 'ScheduleHearing', 'RecordDecision', 'IssueReleaseOrder', 'IssueCourtOrder', 'RevokeCourtOrder', 'DecideWarrant' }) do
            Mock.invokingResource = 'pf-policemdt-DEV'
            assert_eq(juExport(name)(1, {}, {}).error, 'not_allowed', name)
        end
    end)
end)

describe('court roles', function()
    local function actor(src) return J.Actor.Resolve({ src = src }, nil) end
    it('judge, clerk, prosecutor and defender come from job, grade and duty', function()
        assert_true(Courts.HasRole(actor(JUDGE), 'judge'))
        assert_false(Courts.HasRole(actor(CLERK), 'judge'))
        assert_true(Courts.HasRole(actor(CLERK), 'clerk'))
        assert_false(Courts.HasRole(actor(CLERK), 'prosecutor'))
        assert_true(Courts.HasRole(actor(PROS), 'prosecutor'))
        assert_true(Courts.HasRole(actor(DEF), 'defender'))
        assert_true(Courts.HasRole(actor(LAWYER), 'defender'), 'a private lawyer defends')
        assert_false(Courts.HasRole(actor(LAWYER), 'prosecutor'))
        player(11, 'CHIEF', 'doj', 4)
        for _, r in ipairs({ 'clerk', 'prosecutor', 'defender' }) do assert_true(Courts.HasRole(actor(11), r), 'chief of justice: ' .. r) end
        assert_false(Courts.HasRole(actor(COP), 'judge'))
        Mock.players[JUDGE].PlayerData.job.onduty = false
        assert_false(Courts.HasRole(actor(JUDGE), 'judge'), 'off duty')
        assert_eq(Courts.RoleErr(actor(JUDGE), { 'judge' }).error, 'not_on_duty')
        assert_eq(Courts.RoleErr(actor(COP), { 'judge' }).error, 'no_permission')
        assert_true(Courts.HasRole({ kind = 'system' }, 'judge'))
        Mock.aces[COP] = { command = true }
        assert_true(Courts.HasRole(J.Actor.Resolve({ src = COP, kind = 'admin' }, nil), 'judge'))
    end)

    it('JudgesOnDuty counts on-duty judges only (the low-population trigger)', function()
        assert_eq(#Courts.JudgesOnDuty(), 1)
        Mock.players[JUDGE].PlayerData.job.onduty = false
        assert_eq(#Courts.JudgesOnDuty(), 0)
    end)
end)

describe('warrant fallback without judges', function()
    local function actor(src) return J.Actor.Resolve({ src = src }, nil) end
    it('a police officer of the fallback grade decides only with no judge, after the wait, and never their own', function()
        local now = os.time()
        local r = { requested_by = 'COP1', requested_at = now - 4000 }
        Courts.lastJudgeAt = now - 4000
        assert_false(W.MayDecide(actor(SGT), r, now), 'a judge is on duty')
        Mock.players[JUDGE] = nil
        assert_true(W.MayDecide(actor(SGT), r, now))
        assert_false(W.MayDecide(actor(COP), r, now), 'grade 2 is below the fallback grade')
        local own = { requested_by = 'SGT1', requested_at = now - 4000 }
        local ok, why = W.MayDecide(actor(SGT), own, now)
        assert_false(ok)
        assert_eq(why, 'own')
        assert_false(W.MayDecide(actor(SGT), { requested_by = 'COP1', requested_at = now - 60 }, now), 'too soon')
        Courts.lastJudgeAt = now - 60
        assert_false(W.MayDecide(actor(SGT), r, now), 'a judge left a minute ago')
        Config.Courts.WarrantFallback.Enabled = false
        Courts.lastJudgeAt = now - 4000
        assert_false(W.MayDecide(actor(SGT), r, now), 'judges only')
        Config.Courts.WarrantFallback.Enabled = true
    end)
end)

describe('manifest and config for batch 19', function()
    it('lists the batch-19 files in order and the config blocks 19B and 19C read', function()
        -- the manifest is Lua: capture its lists
        local lists = {}
        local function capture(name) return function(v) lists[name] = v end end
        for _, k in ipairs({ 'fx_version', 'game', 'author', 'description', 'version', 'lua54' }) do _G[k] = function() end end
        for _, k in ipairs({ 'dependencies', 'shared_scripts', 'server_scripts', 'client_scripts' }) do _G[k] = capture(k) end
        load_resource('[pfscripts]/pf-justice/fxmanifest.lua')
        local pos = {}
        for i, f in ipairs(lists.server_scripts) do pos[f] = i end
        for _, file in ipairs({ 'server/courts.lua', 'server/warrants.lua', 'server/supervision.lua', 'server/monitors.lua', 'server/community_service.lua' }) do
            assert_true(pos[file] ~= nil and pos[file] < pos['server/api.lua'], file .. ' before server/api.lua')
        end
        assert_eq(lists.shared_scripts[3], 'shared/cs_tasks.lua')
        assert_eq(lists.client_scripts[1], 'client/main.lua')
        assert_eq(lists.client_scripts[2], 'client/community_service.lua')
        assert_true(type(Config.Courts) == 'table' and type(Config.Courts.Roles) == 'table')
        assert_true(Config.CommunityService.MaxUnits == 500 and Config.CommunityService.SupervisorBonus == 1.0, 'no bonus units unless the owner opts in')
        assert_eq(Config.CommunityService.MinStepSeconds, 20)
        assert_true(Config.Supervision.MaxDays == 365 and Config.Supervision.ConditionKinds.monitor)
        assert_eq(Config.Supervision.Monitor.SampleSeconds, 5, '0.2 Hz')
        assert_true(Mock.rawCommands.courtorder ~= nil and Mock.rawCommands.warrantdecide ~= nil and Mock.rawCommands.warrantreviews ~= nil)
    end)
end)
