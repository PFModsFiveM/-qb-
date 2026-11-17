-- Batch 20 (20F) police personnel, use of force, IA, armory, mocked (the SQL runs on MariaDB in
-- tests/realdb_specs/b20_police_personnel_realdb_spec.lua):
--   * manifests: pf-policemdt-DEV loads server/personnel_ext.lua, pfm-policejob server/armory.lua;
--   * schema v9: one rerun-safe statement list; reports and complaints carry a UNIQUE idem_key;
--   * gate: every write endpoint is in the access gate with its action and default grade;
--   * DraftUseOfForce / the MDT draft read the server timeline (pfm-policejob GetTimeline, the
--     caller as viewer) and hold it; nothing the client sends sets the force level, the events or
--     the summary; client-reported rows never raise the level; an unreadable timeline is recorded;
--   * the review chain: never the officer or the subject, a higher rank, a note to return, the
--     closer is not the reviewer; the automatic draft tick drafts on reportable force only;
--   * IA: keyed intake (duplicate / key_reused), the portal complainant is the actor, a daily cap,
--     the officer named never sees or works the complaint; performance reviews and the GOV
--     qualification view; the officer profile carries the personnel summary;
--   * armory: duty, counter distance, whitelist (Config.ArmoryWhitelist, defaults when empty),
--     rank, qualification, fails closed without pf-government, one per item and MaxOut, keyed
--     IssueAsset/ReturnAsset, the serial on the item, compensation when a step fails.
load_resource('tests/lua/fivem_mocks.lua')
function IsDuplicityVersion() return true end
local states = {}
function GetResourceState(name) return states[name] or 'missing' end
QBCore = QBCoreMock
promise = promise or { new = function() return { resolve = function(self, v) self.value = v end } end }
Citizen = Citizen or {}
Citizen.Await = Citizen.Await or function(p) return p.value end

-- ── MySQL (personnel_ext): records every statement, answers are scripted per test ──
local log, answers = {}, {}
local insertId = 100
local function run(kind, sql, params)
    log[#log + 1] = { kind = kind, sql = sql, params = params }
    for _, a in ipairs(answers) do
        if sql:find(a.match, 1, true) and (a.kind == nil or a.kind == kind) then
            if type(a.value) == 'function' then return a.value(sql, params) end
            return a.value
        end
    end
    if kind == 'update' then return 1 end
    if kind == 'insert' then insertId = insertId + 1 return insertId end
    if kind == 'scalar' then return 0 end
    if kind == 'query' then return {} end
    return nil
end
local function op(kind) return { await = function(sql, p) return run(kind, sql, p) end } end
MySQL = { query = op('query'), insert = op('insert'), update = op('update'), single = op('single'), scalar = op('scalar') }
local function logged(fragment, kind)
    local out = {}
    for _, e in ipairs(log) do if e.sql:find(fragment, 1, true) and (kind == nil or e.kind == kind) then out[#out + 1] = e end end
    return out
end
local function answer(match, value, kind) table.insert(answers, 1, { match = match, value = value, kind = kind }) end

-- oxmysql for server/officers.lua (callback style)
Mock.exportsByResource['oxmysql'] = {
    execute = function(_, sql, params, cb)
        local r = {}
        if sql:find('SELECT citizenid, charinfo FROM players', 1, true) then r = { { citizenid = params[1], charinfo = '{"firstname":"Ada","lastname":"Lead"}' } } end
        if Mock.callable(cb) then cb(r) end
        return r
    end,
    insert = function(_, _, _, cb) if Mock.callable(cb) then cb(1) end return 1 end,
}

-- ── pfm-policejob telemetry by contract (18C) ──
local TL = { calls = {}, holds = {}, events = {}, fail = nil }
Mock.exportsByResource['pfm-policejob'] = {
    GetTimeline = function(_, cid, from, to, opts)
        TL.calls[#TL.calls + 1] = { cid = cid, from = from, to = to, opts = opts }
        if TL.fail then return { ok = false, error = TL.fail } end
        local out = {}
        for _, e in ipairs(TL.events) do
            if (e.cid or 'OFF1') == cid and e.id > ((opts and opts.after) or 0) then out[#out + 1] = e end
        end
        return { ok = true, events = out }
    end,
    HoldTimeline = function(_, cid, from, to, caseRef)
        TL.holds[#TL.holds + 1] = { cid = cid, from = from, to = to, caseRef = caseRef }
        return { ok = true, holdId = 9 }
    end,
}

-- ── pf-government by contract (15I quals, 20E assets) ──
local GOV = { depts = {}, quals = {}, assets = {}, issued = {}, returned = {}, issueFail = nil, returnFail = nil, listed = 0 }
local function view(a) return { id = a.id, dept = a.dept, kind = a.kind, serial = a.serial, item = a.item, label = a.label, state = a.state, holder = a.holder, issuedAt = a.issuedAt } end
Mock.exportsByResource['pf-government'] = {
    GetDepartmentOf = function(_, src) return GOV.depts[src] end,
    HasQualification = function(_, cid, q) return GOV.quals[cid .. ':' .. q] == true end,
    ListQualifications = function(_, cid) return { ok = true, dept = 'police', list = { { qual = 'patrol', has = true, source = 'implied', cid = cid } } } end,
    ListAssets = function(_, dept, f)
        GOV.listed = GOV.listed + 1
        local out = {}
        for _, a in ipairs(GOV.assets) do
            if a.dept == dept and (f.state == nil or a.state == f.state) and (f.kind == nil or a.kind == f.kind)
                and (f.holder == nil or a.holder == f.holder) then out[#out + 1] = view(a) end
        end
        table.sort(out, function(x, y) return x.id > y.id end)
        return { ok = true, list = out }
    end,
    GetAsset = function(_, serial)
        for _, a in ipairs(GOV.assets) do if a.serial == serial then return { ok = true, asset = view(a) } end end
        return { ok = false, error = 'not_found' }
    end,
    IssueAsset = function(_, serial, cid, opts)
        GOV.issued[#GOV.issued + 1] = { serial = serial, cid = cid, opts = opts }
        if GOV.issueFail then return { ok = false, error = GOV.issueFail } end
        for _, a in ipairs(GOV.assets) do
            if a.serial == serial then a.state, a.holder, a.issuedAt = 'issued', cid, 1700000123 return { ok = true, asset = view(a) } end
        end
        return { ok = false, error = 'not_found' }
    end,
    ReturnAsset = function(_, serial, opts)
        GOV.returned[#GOV.returned + 1] = { serial = serial, opts = opts }
        if GOV.returnFail then return { ok = false, error = GOV.returnFail } end
        for _, a in ipairs(GOV.assets) do
            if a.serial == serial then a.state, a.holder = 'in_stock', nil return { ok = true, asset = view(a) } end
        end
        return { ok = false, error = 'not_found' }
    end,
}

-- ── pfm-inventory ──
local INV = { added = {}, removed = {}, canAdd = true, addOk = true }
Mock.exportsByResource['pfm-inventory'] = {
    CanAddItem = function() return INV.canAdd end,
    AddItem = function(_, src, item, n, slot, info, reason)
        INV.added[#INV.added + 1] = { src = src, item = item, slot = slot, info = info, reason = reason }
        if not INV.addOk then return false end
        local items = Mock.players[src].PlayerData.items
        local s = slot or (#items + 1)
        items[s] = { name = item, amount = 1, info = info, slot = s }
        return true
    end,
    RemoveItem = function(_, src, item, n, slot)
        INV.removed[#INV.removed + 1] = { src = src, item = item, slot = slot }
        local items = Mock.players[src].PlayerData.items
        if not items[slot] or items[slot].name ~= item then return false end
        items[slot] = nil
        return true
    end,
}
QBCoreMock.Shared.Items.weapon_stungun = { name = 'weapon_stungun', label = 'Taser', type = 'weapon', unique = true, weight = 1000 }
QBCoreMock.Shared.Items.weapon_carbinerifle = { name = 'weapon_carbinerifle', label = 'Carbine', type = 'weapon', unique = true, weight = 1000 }
QBCoreMock.Shared.Items.radio = { name = 'radio', label = 'Radio', type = 'item', unique = true, weight = 1000 }
QBCoreMock.Shared.Items.bodycam = { name = 'bodycam', label = 'Body Camera', type = 'item', unique = false, weight = 300 }

-- ── load pf-policemdt-DEV ──
local RES = '[pfscripts]/pf-policemdt-DEV/'
function GetCurrentResourceName() return 'pf-policemdt-DEV' end
Config = nil
load_resource(RES .. 'shared/framework.lua')
load_resource(RES .. 'config.lua')
load_resource(RES .. 'server/access.lua')
load_resource(RES .. 'server/schema.lua')
load_resource(RES .. 'server/personnel_ext.lua')
load_resource(RES .. 'server/officers.lua')
local MDT_CONFIG = Config
local P, Schema, Access = PFMdtPersonnel, PFMdtSchema, PFMdtAccess
local mdtExports = {}
for k, v in pairs(Mock.exportsByResource['__self']) do mdtExports[k] = v end
QBCoreMock.Shared.Jobs.police = { label = 'Police', grades = { ['0'] = {}, ['1'] = {}, ['2'] = {}, ['3'] = {}, ['4'] = { isboss = true } } }

-- ── load pfm-policejob armory (its own Config) ──
Config = nil
load_resource('pfm-policejob/config.lua')
load_resource('pfm-policejob/server/armory.lua')
local PJ_CONFIG = Config
local A = PFArmory
-- each armory call comes after the per-officer rate window (Config.Armory.RateMs)
local Checkout, Return = A.Checkout, A.Return
local function tick() Mock.gameTimer = Mock.gameTimer + 5000 end
local function checkout(src, item) tick() return Checkout(src, item) end
local function giveBack(src, serial) tick() return Return(src, serial) end
local function mdt() Config = MDT_CONFIG function GetCurrentResourceName() return 'pf-policemdt-DEV' end end
local function pj() Config = PJ_CONFIG function GetCurrentResourceName() return 'pfm-policejob' end end

-- players: 1 officer grade 1, 2 sergeant grade 2, 3 lieutenant grade 3, 4 civilian, 5 recruit, 6 chief
local OFF, SGT, LT, CIV, REC, CHIEF = 1, 2, 3, 4, 5, 6
local function cop(src, cid, grade, onduty)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.job = { name = 'police', type = 'leo', grade = { level = grade }, onduty = onduty ~= false, isboss = grade >= 4 }
    return p
end
local COUNTER = vector3(452.30, -982.50, 30.69)
BeforeEach = function()
    mdt()
    Mock.reset()
    Mock.players = {}
    Mock.invokingResource = nil
    Mock.gameTimer = Mock.gameTimer + 100000
    log, answers = {}, {}
    states = { ['pfm-policejob'] = 'started', ['pf-government'] = 'started' }
    Schema.state = 'ready'
    for k in pairs(P.Locks) do P.Locks[k] = nil end
    for k in pairs(P.Cursor) do P.Cursor[k] = nil end
    for k in pairs(A.Locks) do A.Locks[k] = nil end
    TL.calls, TL.holds, TL.events, TL.fail = {}, {}, {}, nil
    GOV.depts, GOV.quals, GOV.assets, GOV.issued, GOV.returned, GOV.issueFail, GOV.returnFail = {}, {}, {}, {}, {}, nil, nil
    INV.added, INV.removed, INV.canAdd, INV.addOk = {}, {}, true, true
    PJ_CONFIG.ArmoryWhitelist = {}
    cop(OFF, 'OFF1', 1)
    cop(SGT, 'SGT2', 2)
    cop(LT, 'LT3', 3)
    Mock.newPlayer(CIV, 'CIV4')
    cop(REC, 'REC5', 0)
    cop(CHIEF, 'CHF6', 4)
    for s = 1, 6 do Mock.coords[s] = COUNTER end
end
local function call(name, src, data)
    Mock.gameTimer = Mock.gameTimer + 10000
    return Mock.callCallback(name, src, data)
end
local function reportRow(over)
    local r = { id = 7, kind = 'uof', officer_cid = 'OFF1', subject_cid = 'CIV4', state = 'submitted', origin = 'officer',
        telemetry_from = 1699999000, telemetry_to = 1699999600, narrative = string.rep('x', 30), force_level = 3,
        created_by = 'OFF1', created_at = 1, updated_at = 1 }
    for k, v in pairs(over or {}) do r[k] = v end
    return r
end

describe('20F: manifests and schema v9', function()
    it('loads personnel_ext.lua after main/cases and armory.lua after main/telemetry', function()
        local m = __readfile(RES .. 'fxmanifest.lua'):match('server_scripts%s*(%b{})')
        local pos, i = {}, 0
        for f in m:gmatch("'(server/[%w_]+%.lua)'") do i = i + 1; pos[f] = i end
        assert_true(pos['server/personnel_ext.lua'] ~= nil, 'personnel_ext listed')
        assert_true(pos['server/personnel_ext.lua'] > pos['server/main.lua'])
        assert_true(pos['server/personnel_ext.lua'] > pos['server/access.lua'])
        local pm = __readfile('pfm-policejob/fxmanifest.lua'):match('server_scripts%s*(%b{})')
        local pp, j = {}, 0
        for f in pm:gmatch("'(server/[%w_]+%.lua)'") do j = j + 1; pp[f] = j end
        assert_true(pp['server/armory.lua'] ~= nil, 'armory listed')
        assert_true(pp['server/armory.lua'] > pp['server/main.lua'] and pp['server/armory.lua'] > pp['server/telemetry.lua'])
    end)

    it('v9 is one rerun-safe list with keyed reports and complaints; personnel_ext runs no DDL', function()
        local m = Schema.Migrations[9]
        assert_eq(#Schema.Migrations, 9)
        assert_eq(m.version, 9)
        assert_eq(m.name, 'personnel, use of force, pursuits, IA')
        local created = {}
        for _, sql in ipairs(m.up) do
            assert_true(sql:find('^CREATE TABLE IF NOT EXISTS') ~= nil, sql)
            assert_true(sql:upper():find('DROP', 1, true) == nil)
            created[sql:match('`([%w_]+)`')] = sql
        end
        for _, t in ipairs({ 'pf_mdt_force_reports', 'pf_mdt_force_reviews', 'pf_mdt_ia_complaints', 'pf_mdt_ia_events', 'pf_mdt_reviews' }) do
            assert_true(created[t] ~= nil, t)
        end
        assert_true(created.pf_mdt_force_reports:find('UNIQUE KEY `uq_fr_key` (`idem_key`)', 1, true) ~= nil)
        assert_true(created.pf_mdt_ia_complaints:find('UNIQUE KEY `uq_ia_key` (`idem_key`)', 1, true) ~= nil)
        local code = __readfile(RES .. 'server/personnel_ext.lua')
        assert_true(code:find('CREATE TABLE', 1, true) == nil and code:find('ALTER TABLE', 1, true) == nil and code:find('RunMigrations', 1, true) == nil)
        for name in code:gmatch('pf_mdt_[%w_]+') do
            assert_true(created[name] ~= nil or name == 'pf_mdt_record_audit', name .. ' named but not created by v9')
        end
    end)
end)

describe('20F: gate', function()
    it('every write endpoint is gated with its action and the default grades exist', function()
        local want = {
            ['pf_mdt:force:draft'] = 'forceReports', ['pf_mdt:force:update'] = 'forceReports', ['pf_mdt:force:submit'] = 'forceReports',
            ['pf_mdt:force:refresh'] = 'forceReports', ['pf_mdt:force:review'] = 'forceReview', ['pf_mdt:force:close'] = 'forceClose',
            ['pf_mdt:ia:file'] = 'iaIntake', ['pf_mdt:ia:list'] = 'iaManage', ['pf_mdt:ia:get'] = 'iaManage', ['pf_mdt:ia:assign'] = 'iaManage',
            ['pf_mdt:ia:note'] = 'iaManage', ['pf_mdt:ia:finding'] = 'iaManage', ['pf_mdt:ia:close'] = 'iaManage',
            ['pf_mdt:reviews:create'] = 'perfReview',
        }
        for name, action in pairs(want) do
            assert_eq(Access.Actions[name] and Access.Actions[name].action, action, name)
        end
        assert_eq(Config.Permissions.forceReview, 2)
        assert_eq(Config.Permissions.forceClose, 3)
        assert_eq(Config.Permissions.iaManage, 3)
    end)

    it('civilians, off-duty officers and low grades are refused before the handler', function()
        local r = call('pf_mdt:force:draft', CIV, { minutes = 10 })
        assert_eq(r.error, 'no_access')
        Mock.players[OFF].PlayerData.job.onduty = false
        assert_eq(call('pf_mdt:force:draft', OFF, { minutes = 10 }).error, 'off_duty')
        assert_eq(call('pf_mdt:force:review', REC, { id = 7, decision = 'approve' }).error, 'no_permission')
        assert_eq(call('pf_mdt:ia:list', SGT, {}).error, 'no_permission')
        assert_eq(#TL.calls, 0)
        assert_eq(#logged('pf_mdt_force_reports'), 0)
    end)
end)

describe('20F: drafts come from the server timeline', function()
    it('the MDT draft reads the own timeline with the caller as viewer; client fields set nothing', function()
        TL.events = {
            { id = 11, kind = 'pos', coords = { x = 0, y = 0, z = 0 }, at = Mock.clock - 300 },
            { id = 12, kind = 'taser', data = {}, coords = { x = 30, y = 0, z = 0 }, at = Mock.clock - 290 },
            { id = 13, kind = 'shot_reported', clientReported = true, data = { weapon = 'weapon_pistol' }, at = Mock.clock - 280 },
            { id = 14, kind = 'use_of_force', data = { kind = 'handcuffs', target = 'CIV4' }, at = Mock.clock - 270 },
        }
        local r = call('pf_mdt:force:draft', OFF, { minutes = 10, forceLevel = 1, summary = { level = 0 }, events = { { kind = 'shot_hit' } } })
        assert_eq(r.ok, true, tostring(r.error))
        assert_eq(#TL.calls, 1)
        assert_eq(TL.calls[1].cid, 'OFF1')
        assert_eq(TL.calls[1].opts.viewer, OFF)
        assert_eq(TL.calls[1].to - TL.calls[1].from, 600)
        local ins = logged('INSERT INTO pf_mdt_force_reports')[1]
        assert_true(ins ~= nil)
        assert_eq(ins.params[1], 'uof', 'a client-reported shot does not make it an OIS')
        assert_eq(ins.params[6], 3, 'level from the taser row, not the client value')
        assert_eq(ins.params[4], 'CIV4', 'the subject seen in the timeline')
        assert_eq(ins.params[9], 'ok')
        local s = json.decode(ins.params[10])
        assert_eq(s.clientReported, 1)
        assert_eq(s.level, 3)
        assert_eq(ins.params[12]:sub(1, 26), 'pf-policemdt:force:mdt:OFF')
        assert_eq(#TL.holds, 1)
        assert_eq(TL.holds[1].caseRef, 'pf-policemdt:force:' .. r.reportId)
    end)

    it('a firearm hit makes an OIS report at level 5', function()
        TL.events = { { id = 21, kind = 'shot_hit', data = { weapon = 'weapon_pistol' }, at = Mock.clock - 60 } }
        local r = call('pf_mdt:force:draft', OFF, { minutes = 5 })
        assert_eq(r.kind, 'ois')
        assert_eq(r.forceLevel, 5)
    end)

    it('an unreadable timeline is recorded on the draft (no hold)', function()
        TL.fail = 'no_permission'
        local r = call('pf_mdt:force:draft', OFF, { minutes = 5 })
        assert_eq(r.ok, true)
        assert_eq(r.telemetry, 'unavailable:no_permission')
        assert_eq(#TL.holds, 0)
    end)

    it('windows are checked; drafting for another officer needs a supervisor who outranks them', function()
        assert_eq(call('pf_mdt:force:draft', OFF, { from = Mock.clock - 9000, to = Mock.clock }).error, 'bad_args')
        assert_eq(call('pf_mdt:force:draft', OFF, { from = Mock.clock, to = Mock.clock + 600 }).error, 'bad_args')
        assert_eq(call('pf_mdt:force:draft', OFF, { from = Mock.clock - 5 * 86400, to = Mock.clock - 5 * 86400 + 60 }).error, 'bad_args')
        assert_eq(call('pf_mdt:force:draft', OFF, { minutes = 5, kind = 'riot' }).error, 'bad_args')
        assert_eq(call('pf_mdt:force:draft', OFF, { minutes = 5, officerCid = 'SGT2' }).error, 'no_permission')
        assert_eq(call('pf_mdt:force:draft', SGT, { minutes = 5, officerCid = 'LT3' }).error, 'no_permission')
        local r = call('pf_mdt:force:draft', SGT, { minutes = 5, officerCid = 'OFF1' })
        assert_eq(r.ok, true)
        assert_eq(TL.calls[#TL.calls].cid, 'OFF1')
        assert_eq(TL.calls[#TL.calls].opts.viewer, SGT)
    end)

    it('DraftUseOfForce: allowlist, key required, duplicate and key_reused', function()
        local draft = mdtExports.DraftUseOfForce
        Mock.invokingResource = 'some-script'
        assert_eq(draft({ officerCid = 'OFF1', from = Mock.clock - 60, to = Mock.clock }, { key = 'k1' }).error, 'not_allowed')
        Mock.invokingResource = 'pfm-policejob'
        assert_eq(draft({ officerCid = 'OFF1', from = Mock.clock - 60, to = Mock.clock }, {}).error, 'bad_args')
        TL.events = { { id = 31, kind = 'use_of_force', data = { action = 'tackle', subject = 'CIV4' }, at = Mock.clock - 30 } }
        local r = draft({ officerCid = 'OFF1', from = Mock.clock - 60, to = Mock.clock, forceLevel = 1 }, { key = 'pfm-policejob:uof:1' })
        assert_eq(r.ok, true, tostring(r.error))
        assert_eq(r.forceLevel, 2, 'never below what the timeline shows')
        assert_eq(TL.calls[#TL.calls].opts.viewer, OFF, 'the online officer reads their own timeline')
        answer('WHERE idem_key = ?', { id = r.reportId, officer_cid = 'OFF1', telemetry_from = Mock.clock - 60 }, 'single')
        local d = draft({ officerCid = 'OFF1', from = Mock.clock - 60, to = Mock.clock }, { key = 'pfm-policejob:uof:1' })
        assert_eq(d.duplicate, true)
        assert_eq(d.reportId, r.reportId)
        assert_eq(draft({ officerCid = 'SGT2', from = Mock.clock - 60, to = Mock.clock }, { key = 'pfm-policejob:uof:1' }).error, 'key_reused')
    end)
end)

describe('20F: review chain', function()
    it('the officer and the subject never review; a higher rank approves; return needs a note', function()
        answer('SELECT * FROM pf_mdt_force_reports WHERE id = ?', reportRow({ officer_cid = 'SGT2', subject_cid = 'LT3' }), 'single')
        assert_eq(call('pf_mdt:force:review', SGT, { id = 7, decision = 'approve' }).error, 'no_permission')
        assert_eq(call('pf_mdt:force:review', LT, { id = 7, decision = 'approve' }).error, 'no_permission', 'the subject')
        answers = {}
        answer('SELECT * FROM pf_mdt_force_reports WHERE id = ?', reportRow({ officer_cid = 'LT3' }), 'single')
        assert_eq(call('pf_mdt:force:review', SGT, { id = 7, decision = 'approve' }).error, 'no_permission', 'outranked')
        answers = {}
        answer('SELECT * FROM pf_mdt_force_reports WHERE id = ?', reportRow(), 'single')
        assert_eq(call('pf_mdt:force:review', SGT, { id = 7, decision = 'return' }).error, 'bad_args')
        local r = call('pf_mdt:force:review', SGT, { id = 7, decision = 'approve' })
        assert_eq(r.ok, true, tostring(r.error))
        local upd = logged("SET state = ?, reviewer_cid = ?", 'update')[1]
        assert_eq(upd.params[1], 'reviewed')
        assert_eq(upd.params[2], 'SGT2')
        local step = logged('INSERT INTO pf_mdt_force_reviews')[1]
        assert_eq(step.params[2], 'approve')
        assert_eq(step.params[3], 'SGT2')
    end)

    it('the closer is a second supervisor; only reviewed reports close', function()
        answer('SELECT * FROM pf_mdt_force_reports WHERE id = ?', reportRow({ state = 'reviewed', reviewer_cid = 'LT3' }), 'single')
        assert_eq(call('pf_mdt:force:close', LT, { id = 7 }).error, 'no_permission')
        local r = call('pf_mdt:force:close', CHIEF, { id = 7 })
        assert_eq(r.ok, true, tostring(r.error))
        answers = {}
        answer('SELECT * FROM pf_mdt_force_reports WHERE id = ?', reportRow({ state = 'submitted' }), 'single')
        assert_eq(call('pf_mdt:force:close', CHIEF, { id = 7 }).error, 'invalid_state')
    end)

    it('only the officer submits, with a narrative', function()
        answer('SELECT * FROM pf_mdt_force_reports WHERE id = ?', reportRow({ state = 'draft', narrative = 'short' }), 'single')
        assert_eq(call('pf_mdt:force:submit', SGT, { id = 7 }).error, 'no_permission')
        assert_eq(call('pf_mdt:force:submit', OFF, { id = 7 }).error, 'bad_args')
        answers = {}
        answer('SELECT * FROM pf_mdt_force_reports WHERE id = ?', reportRow({ state = 'draft' }), 'single')
        assert_eq(call('pf_mdt:force:submit', OFF, { id = 7 }).state, 'submitted')
    end)

    it('the report is busy while another change holds its lock', function()
        P.Locks['report:7'] = true
        assert_eq(call('pf_mdt:force:review', SGT, { id = 7, decision = 'approve' }).error, 'busy')
    end)
end)

describe('20F: automatic drafts', function()
    it('reportable force on the timeline drafts a keyed report and tells the officer; restraint alone does not', function()
        TL.events = { { id = 41, kind = 'use_of_force', data = { kind = 'handcuffs' }, at = Mock.clock - 10 } }
        assert_eq(P.AutoDraftTick(), 0)
        assert_eq(#logged('INSERT INTO pf_mdt_force_reports'), 0)
        TL.events[#TL.events + 1] = { id = 42, kind = 'taser', data = {}, at = Mock.clock - 5 }
        assert_eq(P.AutoDraftTick(), 1)
        local ins = logged('INSERT INTO pf_mdt_force_reports')
        assert_eq(#ins, 1)
        assert_eq(ins[1].params[2], 'OFF1')
        assert_eq(ins[1].params[11], 'auto')
        assert_eq(ins[1].params[12], 'pf-policemdt:force:auto:OFF1:42')
        local note = false
        for _, e in ipairs(Mock.clientEventsNamed('QBCore:Notify')) do if e.target == OFF then note = true end end
        assert_true(note, 'the officer is told')
        -- the cursor moved: the same rows draft nothing again
        local before = #logged('INSERT INTO pf_mdt_force_reports')
        P.AutoDraftTick()
        assert_eq(#logged('INSERT INTO pf_mdt_force_reports'), before)
    end)

    it('does nothing without pfm-policejob', function()
        states['pfm-policejob'] = 'missing'
        TL.events = { { id = 51, kind = 'taser', data = {}, at = Mock.clock } }
        assert_eq(P.AutoDraftTick(), 0)
        assert_eq(#TL.calls, 0)
    end)
end)

describe('20F: internal affairs', function()
    it('portal intake: key required, the complainant is the actor, duplicate and key_reused, daily cap', function()
        local file = mdtExports.FileIaComplaint
        Mock.invokingResource = 'pf-citizen'
        assert_eq(file({ summary = 'He was rude to me at the stop' }, {}).error, 'bad_args')
        local r = file({ complainantCid = 'SGT2', officerCid = 'OFF1', summary = 'He was rude to me at the stop' }, { key = 'portal:1', actor = { src = CIV } })
        assert_eq(r.ok, true, tostring(r.error))
        local ins = logged('INSERT INTO pf_mdt_ia_complaints')[1]
        assert_eq(ins.params[1], 'CIV4', 'the actor, not the cid in the spec')
        assert_eq(ins.params[6], 'portal')
        answer('FROM pf_mdt_ia_complaints WHERE idem_key = ?', { id = r.complaintId, complainant_cid = 'CIV4', officer_cid = 'OFF1' }, 'single')
        assert_eq(file({ officerCid = 'OFF1', summary = 'He was rude to me at the stop' }, { key = 'portal:1', actor = { src = CIV } }).duplicate, true)
        assert_eq(file({ officerCid = 'SGT2', summary = 'He was rude to me at the stop' }, { key = 'portal:1', actor = { src = CIV } }).error, 'key_reused')
        answers = {}
        answer('SELECT COUNT(*) FROM pf_mdt_ia_complaints WHERE complainant_cid', 3, 'scalar')
        assert_eq(file({ officerCid = 'OFF1', summary = 'Another complaint about it' }, { key = 'portal:2', actor = { src = CIV } }).error, 'rate_limited')
        Mock.invokingResource = 'other-script'
        assert_eq(file({ officerCid = 'OFF1', summary = 'x' }, { key = 'k' }).error, 'not_allowed')
    end)

    it('the officer named never sees, investigates or takes the complaint', function()
        answer('SELECT * FROM pf_mdt_ia_complaints WHERE id = ?', { id = 5, officer_cid = 'LT3', state = 'received', summary = 's' }, 'single')
        assert_eq(call('pf_mdt:ia:get', LT, { id = 5 }).error, 'not_found')
        assert_eq(call('pf_mdt:ia:assign', LT, { id = 5 }).error, 'not_found')
        assert_eq(call('pf_mdt:ia:assign', CHIEF, { id = 5, investigatorCid = 'LT3' }).error, 'conflict')
        assert_eq(call('pf_mdt:ia:assign', CHIEF, { id = 5, investigatorCid = 'OFF1' }).error, 'bad_args', 'investigator below the IA grade')
        local r = call('pf_mdt:ia:list', LT, {})
        assert_eq(r.ok, true)
        local q = logged('FROM pf_mdt_ia_complaints WHERE', 'query')[1]
        assert_true(q.sql:find('officer_cid <> ?', 1, true) ~= nil and q.params[1] == 'LT3', 'the list leaves out complaints naming the reader')
        assert_eq(call('pf_mdt:ia:file', OFF, { officerCid = 'OFF1', summary = 'Complaint about myself' }).error, 'conflict')
        assert_eq(call('pf_mdt:ia:assign', CHIEF, { id = 5 }).state, 'investigating')
    end)

    it('findings need an investigation; dismissing an uninvestigated complaint needs a reason', function()
        answer('SELECT * FROM pf_mdt_ia_complaints WHERE id = ?', { id = 5, officer_cid = 'OFF1', state = 'received', summary = 's' }, 'single')
        assert_eq(call('pf_mdt:ia:finding', LT, { id = 5, finding = 'sustained', outcome = 'Written reprimand' }).error, 'invalid_state')
        assert_eq(call('pf_mdt:ia:close', LT, { id = 5 }).error, 'bad_args')
        assert_eq(call('pf_mdt:ia:close', LT, { id = 5, outcome = 'No officer matches the description' }).state, 'closed')
    end)
end)

describe('20F: reviews, qualifications and the officer profile', function()
    it('performance reviews: not yourself, lower ranks only, scores 1-5', function()
        assert_eq(call('pf_mdt:reviews:create', SGT, { officerCid = 'SGT2', period = '2026-11', scores = { conduct = 4 } }).error, 'no_permission')
        assert_eq(call('pf_mdt:reviews:create', SGT, { officerCid = 'LT3', period = '2026-11', scores = { conduct = 4 } }).error, 'no_permission')
        assert_eq(call('pf_mdt:reviews:create', SGT, { officerCid = 'OFF1', period = '2026-11', scores = { conduct = 9 } }).error, 'bad_args')
        assert_eq(call('pf_mdt:reviews:create', SGT, { officerCid = 'OFF1', period = 'Nov', scores = { conduct = 4 } }).error, 'bad_args')
        local r = call('pf_mdt:reviews:create', SGT, { officerCid = 'OFF1', period = '2026-q4', scores = { conduct = 4, reports = 5 } })
        assert_eq(r.ok, true, tostring(r.error))
        assert_eq(logged('INSERT IGNORE INTO pf_mdt_reviews')[1].params[4], '2026-Q4')
    end)

    it('qualifications come from pf-government; another officer needs viewPersonnel', function()
        local r = call('pf_mdt:personnel:qualifications', OFF, {})
        assert_eq(r.ok, true)
        assert_eq(r.list[1].cid, 'OFF1')
        assert_eq(call('pf_mdt:personnel:qualifications', OFF, { officerCid = 'SGT2' }).error, 'no_permission')
        assert_eq(call('pf_mdt:personnel:qualifications', SGT, { officerCid = 'OFF1' }).ok, true)
        states['pf-government'] = 'missing'
        assert_eq(call('pf_mdt:personnel:qualifications', OFF, {}).error, 'unavailable')
    end)

    it('the officer profile carries the personnel summary; IA counts only for IA staff, never the officer', function()
        answer('FROM pf_mdt_force_reports WHERE officer_cid = ? GROUP BY state', { { state = 'draft', n = 2 } }, 'query')
        answer('FROM pf_mdt_ia_complaints WHERE officer_cid = ? GROUP BY state', { { state = 'investigating', n = 1 }, { state = 'sustained', n = 2 } }, 'query')
        local own = call('pf_mdt:officers:get', OFF, { citizenid = 'OFF1' })
        assert_eq(own.success, true, tostring(own.error))
        assert_eq(own.data.personnel.force.counts.draft, 2)
        assert_eq(own.data.personnel.ia, nil)
        local lt = call('pf_mdt:officers:get', LT, { citizenid = 'OFF1' })
        assert_eq(lt.data.personnel.ia.open, 1)
        assert_eq(lt.data.personnel.ia.sustained, 2)
        local other = call('pf_mdt:officers:get', OFF, { citizenid = 'SGT2' })
        assert_eq(other.data.personnel, nil, 'another officer without viewPersonnel')
    end)
end)

-- ── armory ──
local function stock(serial, kind, item, state, holder)
    GOV.assets[#GOV.assets + 1] = { id = #GOV.assets + 1, dept = 'police', kind = kind, serial = serial, item = item, label = kind, state = state or 'in_stock', holder = holder }
end

describe('20F: armory checkout', function()
    it('whitelist: defaults when Config.ArmoryWhitelist is empty; the config restricts; stacking items never', function()
        pj()
        local w = A.Whitelist()
        assert_true(w.weapon_pistol ~= nil and w.radio ~= nil)
        assert_eq(w.weapon_carbinerifle.grade, 2)
        Config.ArmoryWhitelist = { weapon_stungun = 1, bodycam = { kind = 'bodycam' }, 'radio' }
        w = A.Whitelist()
        assert_eq(w.weapon_pistol, nil)
        assert_eq(w.weapon_stungun.grade, 1)
        assert_eq(w.weapon_stungun.kind, 'taser')
        assert_eq(w.radio.grade, 0)
        assert_eq(w.bodycam, nil, 'a stacking item would merge serials')
    end)

    it('refuses off duty, away from the counter, unlisted items, low rank and missing qualifications', function()
        pj()
        GOV.depts[OFF], GOV.depts[REC] = 'police', 'police'
        stock('PD-SDA-1', 'sidearm', 'weapon_pistol')
        stock('PD-RFL-1', 'rifle', nil)
        Mock.players[OFF].PlayerData.job.onduty = false
        assert_eq(checkout(OFF, 'weapon_pistol').error, 'not_on_duty')
        Mock.players[OFF].PlayerData.job.onduty = true
        Mock.coords[OFF] = vector3(0, 0, 0)
        assert_eq(checkout(OFF, 'weapon_pistol').error, 'too_far')
        Mock.coords[OFF] = COUNTER
        assert_eq(checkout(OFF, 'goldbar').error, 'no_permission')
        assert_eq(checkout(REC, 'weapon_carbinerifle').error, 'no_permission')
        Config.ArmoryWhitelist = { weapon_pistol = { grade = 0, qual = 'firearms' } }
        assert_eq(checkout(OFF, 'weapon_pistol').error, 'no_permission')
        assert_eq(#GOV.issued, 0)
        assert_eq(#INV.added, 0)
    end)

    it('fails closed without pf-government', function()
        pj()
        states['pf-government'] = 'missing'
        assert_eq(checkout(OFF, 'weapon_pistol').error, 'unavailable')
        assert_eq(A.Menu(OFF).error, 'unavailable')
        assert_eq(#INV.added, 0)
    end)

    it('issues the oldest matching asset (keyed, the officer as actor) and hands over the item with its serial', function()
        pj()
        GOV.depts[OFF] = 'police'
        stock('PD-SDA-1', 'sidearm', 'weapon_pistol')
        stock('PD-SDA-2', 'sidearm', 'weapon_combatpistol')
        stock('PD-SDA-3', 'sidearm', nil)
        local r = checkout(OFF, 'weapon_pistol')
        assert_eq(r.ok, true, tostring(r.error))
        assert_eq(r.serial, 'PD-SDA-1')
        assert_eq(GOV.issued[1].cid, 'OFF1')
        assert_eq(GOV.issued[1].opts.actor.src, OFF)
        assert_true(GOV.issued[1].opts.key:find('^pfm%-policejob:armory:PD%-SDA%-1:issue:') ~= nil)
        assert_eq(INV.added[1].item, 'weapon_pistol')
        assert_eq(INV.added[1].info.assetSerial, 'PD-SDA-1')
        assert_eq(INV.added[1].info.serie, 'PD-SDA-1')
        -- one of each item; the next pistol draw is refused, a taser with no stock is out of stock
        assert_eq(checkout(OFF, 'weapon_pistol').error, 'conflict')
        assert_eq(checkout(OFF, 'weapon_stungun').error, 'out_of_stock')
        local m = A.Menu(OFF)
        assert_eq(m.ok, true)
        assert_eq(m.held[1].serial, 'PD-SDA-1')
        assert_eq(m.held[1].carried, true)
    end)

    it('MaxOut and a full inventory refuse before anything is issued', function()
        pj()
        GOV.depts[OFF] = 'police'
        for i = 1, 6 do stock('PD-RAD-' .. i, 'radio', 'radio', 'issued', 'OFF1') end
        stock('PD-SDA-9', 'sidearm', 'weapon_pistol')
        assert_eq(checkout(OFF, 'weapon_pistol').error, 'conflict')
        GOV.assets = {}
        stock('PD-SDA-9', 'sidearm', 'weapon_pistol')
        INV.canAdd = false
        assert_eq(checkout(OFF, 'weapon_pistol').error, 'inventory_full')
        assert_eq(#GOV.issued, 0)
    end)

    it('a failed hand-over books the asset back in with its own key', function()
        pj()
        GOV.depts[OFF] = 'police'
        stock('PD-SDA-1', 'sidearm', 'weapon_pistol')
        INV.addOk = false
        assert_eq(checkout(OFF, 'weapon_pistol').error, 'inventory_full')
        assert_eq(#GOV.returned, 1)
        assert_eq(GOV.returned[1].opts.key, GOV.issued[1].opts.key .. ':undo')
        assert_eq(GOV.assets[1].state, 'in_stock')
    end)

    it('a lock held for the officer answers busy; requests inside the rate window are refused', function()
        pj()
        GOV.depts[OFF] = 'police'
        A.Locks['OFF1'] = true
        assert_eq(checkout(OFF, 'weapon_pistol').error, 'busy')
        A.Locks['OFF1'] = nil
        assert_eq(Checkout(OFF, 'weapon_pistol').error, 'rate_limited')
        assert_eq(#GOV.issued, 0)
    end)
end)

describe('20F: armory return', function()
    it('removes exactly the item with the serial and books it in under a key from the issue time', function()
        pj()
        GOV.depts[OFF] = 'police'
        stock('PD-SDA-1', 'sidearm', 'weapon_pistol')
        assert_eq(checkout(OFF, 'weapon_pistol').ok, true)
        Mock.players[OFF].PlayerData.items[9] = { name = 'weapon_pistol', amount = 1, info = { serie = 'OWN' }, slot = 9 }
        local r = giveBack(OFF, 'pd-sda-1')
        assert_eq(r.ok, true, tostring(r.error))
        assert_eq(INV.removed[1].slot, 1)
        assert_eq(GOV.returned[1].opts.key, 'pfm-policejob:armory:PD-SDA-1:return:1700000123')
        assert_eq(GOV.assets[1].state, 'in_stock')
        assert_true(Mock.players[OFF].PlayerData.items[9] ~= nil, 'the own pistol stays')
    end)

    it('a register refusal gives the item back; only the holder who carries it returns', function()
        pj()
        GOV.depts[OFF] = 'police'
        stock('PD-SDA-1', 'sidearm', 'weapon_pistol')
        assert_eq(checkout(OFF, 'weapon_pistol').ok, true)
        assert_eq(giveBack(SGT, 'PD-SDA-1').error, 'not_found')
        GOV.returnFail = 'db_unavailable'
        local r = giveBack(OFF, 'PD-SDA-1')
        assert_eq(r.ok, false)
        assert_eq(#INV.removed, 1)
        local back = INV.added[#INV.added]
        assert_eq(back.info.assetSerial, 'PD-SDA-1', 'the same item comes back')
        GOV.returnFail = nil
        Mock.players[OFF].PlayerData.items = {}
        assert_eq(giveBack(OFF, 'PD-SDA-1').error, 'not_carried')
    end)
end)
