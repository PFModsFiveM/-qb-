-- Batch 21 (21B) MDT page relays, mocked: server/pages_ext.lua of pf-policemdt-DEV relays the
-- custody, evidence chain, lab and telemetry pages to the resources that own that state, with the
-- caller as viewer/actor, and stores nothing:
--   * gate: reads are police only, writes need duty and their action's grade (registered actions);
--   * custody: GetCustody (latest), GetBooking, GetActiveIncarceration (the server's remaining time,
--     read-only), GetOrders, GetBail; AddCustodyLog with actor = { src } and a checked kind;
--   * evidence: ListEvidence with the caller as viewer and a filter built from checked fields only
--     ("held by me" = the caller's citizen id from the server); GetEvidence; TransferEvidence only to
--     a lab, locker or court with actor = { src } (no client-chosen officer, no release);
--   * lab: the queue is ListEvidence at a lab plus each item's jobs; SubmitToLab / ReleaseLabResult
--     with actor = { src } and checked tests;
--   * telemetry: GetTimeline with viewer = src, own citizen id by default, window capped; labelled
--     "metadata, not video";
--   * access: the permission answer the pages build their navigation from.
load_resource('tests/lua/fivem_mocks.lua')
function IsDuplicityVersion() return true end
local states = {}
function GetResourceState(name) return states[name] or 'missing' end
QBCore = QBCoreMock
-- MySQL: this file only writes audit rows; inserts are recorded and can be made to fail
local SQL = { inserts = {}, fail = false }
MySQL = { query = { await = function() return {} end }, single = { await = function() return nil end },
    insert = { await = function(sql, p)
        if SQL.fail then error('db down') end
        SQL.inserts[#SQL.inserts + 1] = { sql = sql, params = p }
        return #SQL.inserts
    end }, update = { await = function() return 1 end }, scalar = { await = function() return 0 end } }

-- ── owners by contract ──
local JU = { calls = {}, custody = nil, booking = nil, inc = { ok = true, remainingSeconds = 0 }, orders = { ok = true, list = {} }, bail = { ok = true } }
local function rec(t, name, args) t.calls[#t.calls + 1] = { name = name, args = args } end
Mock.exportsByResource['pf-justice'] = {
    GetCustody = function(_, who, opts) rec(JU, 'GetCustody', { who, opts }) return { ok = true, custody = JU.custody } end,
    GetBooking = function(_, id) rec(JU, 'GetBooking', { id }) return JU.booking or { ok = false, error = 'not_found', message = 'No booking' } end,
    GetActiveIncarceration = function(_, who) rec(JU, 'GetActiveIncarceration', { who }) return JU.inc end,
    GetOrders = function(_, cid, filter) rec(JU, 'GetOrders', { cid, filter }) return JU.orders end,
    GetBail = function(_, who) rec(JU, 'GetBail', { who }) return JU.bail end,
    AddCustodyLog = function(_, id, kind, data, opts) rec(JU, 'AddCustodyLog', { id, kind, data, opts }) return { ok = true, logId = 5 } end,
}
local PJ = { calls = {}, list = { ok = true, list = {} }, item = nil, timeline = { ok = true, events = {}, note = 'n' } }
Mock.exportsByResource['pfm-policejob'] = {
    ListEvidence = function(_, filter) rec(PJ, 'ListEvidence', { filter }) return PJ.list end,
    GetEvidence = function(_, id, opts) rec(PJ, 'GetEvidence', { id, opts })
        return PJ.item or { ok = true, item = { id = id }, custody = {}, integrity = { score = 88, flags = {} }, labs = { { id = 40 + (tonumber(id) or 0), test = 'dna', state = 'queued' } } } end,
    TransferEvidence = function(_, id, to, opts) rec(PJ, 'TransferEvidence', { id, to, opts }) return { ok = true, evidenceId = id } end,
    SubmitToLab = function(_, id, tests, opts) rec(PJ, 'SubmitToLab', { id, tests, opts }) return { ok = true, jobId = 9, eta = 100 } end,
    ReleaseLabResult = function(_, jobId, opts) rec(PJ, 'ReleaseLabResult', { jobId, opts }) return { ok = false, error = 'no_permission', message = 'Only a qualified lab technician may release results' } end,
    GetTimeline = function(_, cid, from, to, opts) rec(PJ, 'GetTimeline', { cid, from, to, opts }) return PJ.timeline end,
}
local GOV = { quals = {} }
Mock.exportsByResource['pf-government'] = {
    HasQualification = function(_, cid, q) return GOV.quals[cid .. ':' .. q] == true end,
}

-- ── load pf-policemdt-DEV: the gate, then this file ──
local RES = '[pfscripts]/pf-policemdt-DEV/'
function GetCurrentResourceName() return 'pf-policemdt-DEV' end
Config = nil
load_resource(RES .. 'shared/framework.lua')
load_resource(RES .. 'config.lua')
load_resource(RES .. 'server/access.lua')
load_resource(RES .. 'server/pages_ext.lua')
local X, Access = PFMdtPagesExt, PFMdtAccess

-- 1 officer grade 1 on duty, 2 sergeant grade 2, 3 officer off duty, 4 civilian
local OFF, SGT, OFFDUTY, CIV = 1, 2, 3, 4
local function cop(src, cid, grade, onduty)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.job = { name = 'police', type = 'leo', grade = { level = grade }, onduty = onduty ~= false, isboss = false }
    return p
end
BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    Mock.gameTimer = (Mock.gameTimer or 0) + 100000
    states = { ['pf-justice'] = 'started', ['pfm-policejob'] = 'started', ['pf-government'] = 'started' }
    JU.calls, JU.custody, JU.booking = {}, nil, nil
    JU.inc, JU.orders, JU.bail = { ok = true, remainingSeconds = 0 }, { ok = true, list = {} }, { ok = true }
    PJ.calls, PJ.list, PJ.item, PJ.timeline = {}, { ok = true, list = {} }, nil, { ok = true, events = {}, note = 'n' }
    GOV.quals = {}
    SQL.inserts, SQL.fail = {}, false
    cop(OFF, 'OFF1', 1)
    cop(SGT, 'SGT2', 2)
    cop(OFFDUTY, 'OFF3', 1, false)
    Mock.newPlayer(CIV, 'CIV4')
end
local function call(name, src, data)
    Mock.gameTimer = Mock.gameTimer + 10000
    return Mock.callCallback(name, src, data)
end
local function last(t, name)
    for i = #t.calls, 1, -1 do if t.calls[i].name == name then return t.calls[i].args end end
    return nil
end

describe('21B page relays: gate and access answer', function()
    it('registers every write with its action and default grade', function()
        assert_eq(Access.Actions['pf_mdt:custody:log'].action, 'custodyLog')
        assert_eq(Access.Actions['pf_mdt:evidence:transfer'].action, 'evidenceHandle')
        assert_eq(Access.Actions['pf_mdt:lab:submit'].action, 'evidenceHandle')
        assert_eq(Access.Actions['pf_mdt:lab:release'].action, 'labRelease')
        assert_eq(Access.MinGrade('custodyLog', 'police'), 0)
        -- reads are not write actions (off-duty officers keep reading)
        assert_eq(Access.Actions['pf_mdt:custody:get'], nil)
    end)

    it('the manifest loads the relays after the gate and personnel_ext, and the client file after main.lua', function()
        local mf = __readfile(RES .. 'fxmanifest.lua')
        local function order(block, pattern)
            local pos, i = {}, 0
            for f in mf:match(block .. '%s*(%b{})'):gmatch(pattern) do i = i + 1; pos[f] = i end
            return pos
        end
        local s = order('server_scripts', "'(server/[%w_]+%.lua)'")
        assert_true(s['server/pages_ext.lua'] ~= nil, 'server/pages_ext.lua listed')
        assert_true(s['server/pages_ext.lua'] > s['server/access.lua'] and s['server/pages_ext.lua'] > s['server/personnel_ext.lua'])
        local c = order('client_scripts', "'(client/[%w_]+%.lua)'")
        assert_true(c['client/pages_ext.lua'] ~= nil and c['client/pages_ext.lua'] > c['client/main.lua'])
        for _, f in ipairs({ 'custody.js', 'evidence_coc.js', 'lab.js', 'timeline.js', 'uof.js', 'personnel_ext.js', 'pages_ext.css' }) do
            assert_true(mf:find("'html/pages/" .. f .. "'", 1, true) ~= nil, f .. ' in files')
        end
    end)

    it('refuses civilians on reads and off-duty officers on writes, before any owner is called', function()
        local r = call('pf_mdt:custody:get', CIV, { cid = 'ABC123' })
        assert_eq(r.success, false)
        assert_eq(r.error, 'no_access')
        local w = call('pf_mdt:custody:log', OFFDUTY, { custodyId = 3, kind = 'meal' })
        assert_eq(w.error, 'off_duty')
        assert_eq(#JU.calls, 0)
        -- the off-duty officer keeps the evidence/timeline reads (their owners check duty) but not custody
        JU.custody = { id = 3, cid = 'ABC123', state = 'held' }
        assert_eq(call('pf_mdt:custody:get', OFFDUTY, { cid = 'ABC123' }).error, 'not_on_duty')
        assert_eq(#JU.calls, 0)
        assert_eq(#SQL.inserts, 0)
    end)

    it('answers what the caller may do from the server: ranks, timeline supervisors, lab qualification', function()
        GOV.quals['SGT2:lab_tech'] = true
        local a = call('pf_mdt:pages:access', OFF, {})
        assert_true(a.ok)
        assert_eq(a.cid, 'OFF1')
        assert_eq(a.onduty, true)
        assert_eq(a.can.timelineOthers, false)
        assert_eq(a.can.labTech, false)
        assert_eq(a.can.custodyLog, true)
        local s = call('pf_mdt:pages:access', SGT, {})
        assert_eq(s.can.timelineOthers, true)
        assert_eq(s.can.labTech, true)
        local off = call('pf_mdt:pages:access', OFFDUTY, {})
        assert_eq(off.onduty, false)
        -- pf-government down: no lab role, no error
        states['pf-government'] = 'stopped'
        assert_eq(call('pf_mdt:pages:access', SGT, {}).can.labTech, false)
    end)
end)

describe('21B page relays: custody record', function()
    it('reads custody (latest), booking, the active incarceration, orders and bail from pf-justice', function()
        JU.custody = { id = 12, cid = 'ABC123', state = 'held', facility = 'mrpd_holding' }
        JU.booking = { ok = true, booking = { bookingNo = 'B-1', custodyId = 12 } }
        JU.inc = { ok = true, order = { id = 7, kind = 'jail', state = 'active', requiredSeconds = 600 }, remainingSeconds = 420, facility = 'mrpd_holding' }
        JU.orders = { ok = true, list = { { id = 7, kind = 'jail' } } }
        JU.bail = { ok = true, bail = { id = 2, state = 'offered', amount = 500 } }
        local r = call('pf_mdt:custody:get', OFF, { cid = 'ABC123' })
        assert_true(r.ok and r.success)
        assert_eq(r.custody.id, 12)
        assert_eq(r.booking.bookingNo, 'B-1')
        assert_eq(r.incarceration.remainingSeconds, 420)
        assert_eq(r.incarceration.order.id, 7)
        assert_eq(r.orders[1].id, 7)
        assert_eq(r.bail.amount, 500)
        local gc = last(JU, 'GetCustody')
        assert_eq(gc[1], 'ABC123')
        assert_eq(gc[2].latest, true)
        assert_eq(last(JU, 'GetBooking')[1], 12)
        assert_eq(last(JU, 'GetOrders')[2].limit, 20)
    end)

    it('audits every custody read (never deduplicated) and returns only the booking fields the page shows', function()
        JU.custody = { id = 12, cid = 'ABC123', state = 'held' }
        JU.booking = { ok = true, booking = { id = 4, custodyId = 12, cid = 'ABC123', bookingNo = 'B-1', fingerprint = 'FP1',
            dnaSampleRef = 'S-9', bloodtype = 'O+', screening = 'clear', internal = 'x' } }
        local r = call('pf_mdt:custody:get', OFF, { cid = 'ABC123' })
        assert_true(r.ok)
        assert_eq(r.booking.bookingNo, 'B-1')
        assert_eq(r.booking.dnaSampleRef, 'S-9')
        assert_eq(r.booking.internal, nil)
        assert_eq(r.booking.cid, nil)
        assert_eq(r.booking.id, nil)
        assert_eq(#SQL.inserts, 1)
        local row = SQL.inserts[1]
        assert_true(row.sql:find('INSERT INTO pf_mdt_record_audit', 1, true) ~= nil)
        assert_eq(row.params[1], 'citizen')
        assert_eq(row.params[2], 'ABC123')
        assert_eq(row.params[3], 'read')
        assert_eq(row.params[4], 'OFF1')
        assert_eq(row.params[5], 'police')
        assert_eq(json.decode(row.params[6]).custodyId, 12)
        -- a second read by the same officer is audited again
        call('pf_mdt:custody:get', OFF, { cid = 'ABC123' })
        assert_eq(#SQL.inserts, 2)
        -- no custody on record is still a read of the citizen's orders and bail
        JU.custody = nil
        call('pf_mdt:custody:get', SGT, { cid = 'ABC123' })
        assert_eq(#SQL.inserts, 3)
        assert_eq(SQL.inserts[3].params[4], 'SGT2')
    end)

    it('shows nothing when the read cannot be audited', function()
        JU.custody = { id = 12, cid = 'ABC123', state = 'held' }
        JU.booking = { ok = true, booking = { bookingNo = 'B-1', fingerprint = 'FP1' } }
        SQL.fail = true
        local r = call('pf_mdt:custody:get', OFF, { cid = 'ABC123' })
        assert_eq(r.ok, false)
        assert_eq(r.error, 'db_unavailable')
        assert_eq(r.booking, nil)
        assert_eq(r.custody, nil)
    end)

    it('shows no booking as absent (not an error), and no custody without asking for a booking', function()
        JU.custody = { id = 12, cid = 'ABC123', state = 'arrested' }
        local r = call('pf_mdt:custody:get', OFF, { cid = 'ABC123' })
        assert_eq(r.booking, nil)
        assert_eq(r.bookingError, nil)
        JU.custody = nil
        JU.calls = {}
        local none = call('pf_mdt:custody:get', OFF, { cid = 'ABC123' })
        assert_true(none.ok)
        assert_eq(none.custody, nil)
        assert_eq(last(JU, 'GetBooking'), nil)
    end)

    it('refuses a bad citizen id and says when pf-justice is not running', function()
        assert_eq(call('pf_mdt:custody:get', OFF, { cid = 'x y' }).error, 'bad_args')
        assert_eq(call('pf_mdt:custody:get', OFF, { cid = string.rep('a', 40) }).error, 'bad_args')
        states['pf-justice'] = 'stopped'
        local r = call('pf_mdt:custody:get', OFF, { cid = 'ABC123' })
        assert_eq(r.error, 'unavailable')
        assert_eq(#JU.calls, 0)
    end)

    it('adds a custody log entry as the caller (actor = src), checks the kind and needs text for a note', function()
        local r = call('pf_mdt:custody:log', OFF, { custodyId = 12, kind = 'rights_read', text = 'Miranda read', actor = { kind = 'system' } })
        assert_true(r.ok)
        local a = last(JU, 'AddCustodyLog')
        assert_eq(a[1], 12)
        assert_eq(a[2], 'rights_read')
        assert_eq(a[3].text, 'Miranda read')
        assert_eq(a[4].actor.src, OFF)
        assert_eq(a[4].actor.kind, nil)
        assert_eq(call('pf_mdt:custody:log', OFF, { custodyId = 12, kind = 'released' }).error, 'bad_args')
        assert_eq(call('pf_mdt:custody:log', OFF, { custodyId = 12, kind = 'note', text = '   ' }).error, 'bad_args')
        assert_eq(call('pf_mdt:custody:log', OFF, { custodyId = 'abc', kind = 'meal' }).error, 'bad_args')
    end)
end)

describe('21B page relays: evidence chain and lab', function()
    it('lists evidence with the caller as viewer and only checked filter fields', function()
        PJ.list = { ok = true, list = { { id = 3 } }, next = 3 }
        local r = call('pf_mdt:evidence:list', OFF, { caseId = 12, kind = 'casing', state = 'stored', after = 50, viewer = 99, limit = 1000 })
        assert_true(r.ok)
        assert_eq(r.next, 3)
        local f = last(PJ, 'ListEvidence')[1]
        assert_eq(f.viewer, OFF)
        assert_eq(f.limit, 25)
        assert_eq(f.caseRef.type, 'case')
        assert_eq(f.caseRef.id, '12')
        assert_eq(f.kind, 'casing')
        assert_eq(f.after, 50)
        -- held by me: the citizen id comes from the server's player, not the page
        call('pf_mdt:evidence:list', OFF, { mine = true, holderKind = 'lab' })
        f = last(PJ, 'ListEvidence')[1]
        assert_eq(f.holder.ref, 'player:OFF1')
        assert_eq(f.holder.kind, nil)
        assert_eq(call('pf_mdt:evidence:list', OFF, { kind = "x' OR 1" }).error, 'bad_args')
    end)

    it('reads one item by id or tag with the caller as viewer, and relays a refusal', function()
        call('pf_mdt:evidence:get', OFF, { id = 'EV-2026-14' })
        local g = last(PJ, 'GetEvidence')
        assert_eq(g[1], 'EV-2026-14')
        assert_eq(g[2].viewer, OFF)
        PJ.item = { ok = false, error = 'not_found', message = 'No such evidence' }
        local r = call('pf_mdt:evidence:get', OFF, { id = 4 })
        assert_eq(r.ok, false)
        assert_eq(r.error, 'not_found')
        assert_eq(r.message, 'No such evidence')
        assert_eq(call('pf_mdt:evidence:get', OFF, { id = 'not a tag' }).error, 'bad_args')
    end)

    it('transfers only to a lab, locker or court, as the caller, never to a page-chosen officer or a release', function()
        call('pf_mdt:evidence:transfer', OFF, { id = 4, to = { kind = 'lab', src = 7 }, note = 'drop off' })
        local t = last(PJ, 'TransferEvidence')
        assert_eq(t[1], 4)
        assert_eq(t[2].kind, 'lab')
        assert_eq(t[2].labId, 'main')
        assert_eq(t[2].src, nil)
        assert_eq(t[3].actor.src, OFF)
        assert_eq(t[3].note, 'drop off')
        call('pf_mdt:evidence:transfer', OFF, { id = 4, to = { kind = 'locker', lockerId = '17' } })
        assert_eq(last(PJ, 'TransferEvidence')[2].lockerId, 17)
        PJ.calls = {}
        assert_eq(call('pf_mdt:evidence:transfer', OFF, { id = 4, to = { kind = 'officer', src = 2 } }).error, 'bad_args')
        assert_eq(call('pf_mdt:evidence:transfer', OFF, { id = 4, to = { kind = 'release', cid = 'X' } }).error, 'bad_args')
        assert_eq(call('pf_mdt:evidence:transfer', OFF, { id = 4, to = { kind = 'court' } }).error, 'bad_args')
        assert_eq(#PJ.calls, 0)
    end)

    it('builds the lab queue from evidence at a lab plus each item\'s jobs (caller as viewer)', function()
        PJ.list = { ok = true, list = { { id = 1, integrity = 100 }, { id = 2, integrity = 90 } }, next = nil }
        local r = call('pf_mdt:lab:queue', OFF, { state = 'at_lab' })
        assert_true(r.ok)
        local f = last(PJ, 'ListEvidence')[1]
        assert_eq(f.holder.kind, 'lab')
        assert_eq(f.state, 'at_lab')
        assert_eq(f.limit, 10)
        assert_eq(f.viewer, OFF)
        assert_eq(r.list[1].labs[1].id, 41)
        assert_eq(r.list[2].labs[1].id, 42)
        assert_eq(r.list[1].integrity, 88)
        assert_eq(last(PJ, 'GetEvidence')[2].viewer, OFF)
        assert_eq(call('pf_mdt:lab:queue', OFF, { state = 'released' }).error, 'bad_args')
    end)

    it('requests tests and releases results as the caller; the lab decides (no lab role -> refused)', function()
        local s = call('pf_mdt:lab:submit', OFF, { id = 4, tests = { 'dna', 'dna', 'tox' } })
        assert_true(s.ok)
        local a = last(PJ, 'SubmitToLab')
        assert_eq(#a[2], 2)
        assert_eq(a[3].actor.src, OFF)
        assert_eq(call('pf_mdt:lab:submit', OFF, { id = 4, tests = { 'magic' } }).error, 'bad_args')
        assert_eq(call('pf_mdt:lab:submit', OFF, { id = 4, tests = {} }).error, 'bad_args')
        local rel = call('pf_mdt:lab:release', OFF, { jobId = 9 })
        assert_eq(rel.ok, false)
        assert_eq(rel.error, 'no_permission')
        assert_eq(last(PJ, 'ReleaseLabResult')[2].actor.src, OFF)
    end)
end)

describe('21B page relays: telemetry timeline', function()
    it('reads the caller\'s own timeline by default with viewer = src, labelled metadata, not video', function()
        PJ.timeline = { ok = true, events = { { id = 1, kind = 'pos' } }, next = 1, note = 'Server metadata timeline.' }
        local r = call('pf_mdt:timeline:get', OFF, { from = 1000, to = 2800 })
        assert_true(r.ok)
        assert_eq(r.kindNote, 'metadata, not video')
        assert_eq(r.officerCid, 'OFF1')
        local t = last(PJ, 'GetTimeline')
        assert_eq(t[1], 'OFF1')
        assert_eq(t[4].viewer, OFF)
        assert_eq(t[4].limit, 100)
    end)

    it('passes another officer\'s id to pfm-policejob, which decides; caps the window', function()
        PJ.timeline = { ok = false, error = 'no_permission' }
        local r = call('pf_mdt:timeline:get', OFF, { officerCid = 'SGT2', from = 1000, to = 2000, after = 5 })
        assert_eq(r.ok, false)
        assert_eq(r.error, 'no_permission')
        local t = last(PJ, 'GetTimeline')
        assert_eq(t[1], 'SGT2')
        assert_eq(t[4].after, 5)
        assert_eq(call('pf_mdt:timeline:get', OFF, { from = 0, to = 7 * 3600 }).error, 'bad_args')
        assert_eq(call('pf_mdt:timeline:get', OFF, { from = 2000, to = 1000 }).error, 'bad_args')
        states['pfm-policejob'] = 'stopped'
        assert_eq(call('pf_mdt:timeline:get', OFF, { from = 1000, to = 2000 }).error, 'unavailable')
    end)
end)
