-- Batch 22 (22C) MDT relays, mocked: pf-policemdt-DEV server/pages_ext.lua
--   * pf_mdt:custody:get also shows the booking's property receipt (pf-justice GetPropertyReceipt
--     with the caller as viewer; item info stays on the server) and the newest page of the custody
--     log (pf-justice GetCustodyLog, viewer = caller), and the audit row says so;
--   * pf_mdt:custody:history pages older log entries: on duty, checked cursor, audited before the
--     answer leaves (no answer without the audit row), allowed through the client bridge;
--   * pf_mdt:lab:queue reads the page's lab jobs with ONE pfm-policejob ListLabJobs call (caller as
--     viewer) instead of one GetEvidence per row.
load_resource('tests/lua/fivem_mocks.lua')
function IsDuplicityVersion() return true end
local states = {}
function GetResourceState(name) return states[name] or 'missing' end
QBCore = QBCoreMock
local SQL = { inserts = {}, fail = false }
MySQL = { query = { await = function() return {} end }, single = { await = function() return nil end },
    insert = { await = function(sql, p)
        if SQL.fail then error('db down') end
        SQL.inserts[#SQL.inserts + 1] = { sql = sql, params = p }
        return #SQL.inserts
    end }, update = { await = function() return 1 end }, scalar = { await = function() return 0 end } }

local JU = { calls = {} }
local function rec(t, name, args) t.calls[#t.calls + 1] = { name = name, args = args } end
Mock.exportsByResource['pf-justice'] = {
    GetCustody = function(_, who, opts) rec(JU, 'GetCustody', { who, opts }) return { ok = true, custody = JU.custody } end,
    GetBooking = function(_, id) rec(JU, 'GetBooking', { id }) return JU.booking or { ok = false, error = 'not_found', message = 'No booking' } end,
    GetPropertyReceipt = function(_, id, opts) rec(JU, 'GetPropertyReceipt', { id, opts }) return JU.receipt end,
    GetCustodyLog = function(_, id, opts) rec(JU, 'GetCustodyLog', { id, opts }) return JU.log end,
    GetActiveIncarceration = function() return { ok = true, remainingSeconds = 0 } end,
    GetOrders = function() return { ok = true, list = {} } end,
    GetBail = function() return { ok = true } end,
}
local PJ = { calls = {} }
Mock.exportsByResource['pfm-policejob'] = {
    ListEvidence = function(_, filter) rec(PJ, 'ListEvidence', { filter }) return PJ.list end,
    GetEvidence = function(_, id, opts) rec(PJ, 'GetEvidence', { id, opts }) return { ok = true, labs = {} } end,
    ListLabJobs = function(_, filter) rec(PJ, 'ListLabJobs', { filter }) return PJ.jobs end,
}
Mock.exportsByResource['pf-government'] = { HasQualification = function() return false end }

local RES = '[pfscripts]/pf-policemdt-DEV/'
function GetCurrentResourceName() return 'pf-policemdt-DEV' end
Config = nil
load_resource(RES .. 'shared/framework.lua')
load_resource(RES .. 'config.lua')
load_resource(RES .. 'server/access.lua')
load_resource(RES .. 'server/pages_ext.lua')

local OFF, OFFDUTY, CIV = 1, 3, 4
local function cop(src, cid, grade, onduty)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.job = { name = 'police', type = 'leo', grade = { level = grade }, onduty = onduty ~= false, isboss = false }
end
BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    Mock.gameTimer = (Mock.gameTimer or 0) + 100000
    states = { ['pf-justice'] = 'started', ['pfm-policejob'] = 'started', ['pf-government'] = 'started' }
    JU.calls, JU.custody, JU.booking, JU.receipt, JU.log = {}, nil, nil, nil, { ok = true, list = {} }
    PJ.calls, PJ.list, PJ.jobs = {}, { ok = true, list = {} }, { ok = true, jobs = {} }
    SQL.inserts, SQL.fail = {}, false
    cop(OFF, 'OFF1', 1)
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
local function count(t, name)
    local n = 0
    for _, c in ipairs(t.calls) do if c.name == name then n = n + 1 end end
    return n
end

describe('22C custody record: property receipt and custody log', function()
    it('shows the booking receipt (viewer = caller, item info kept on the server) and the newest log page', function()
        JU.custody = { id = 12, cid = 'ABC123', state = 'held' }
        JU.booking = { ok = true, booking = { bookingNo = 'B-1', receiptId = 31 } }
        JU.receipt = { ok = true, receipt = { id = 31, cid = 'ABC123', state = 'held', lockerStash = 'pfj_locker_31', reason = 'booking',
            seizedBy = 'OFF1', seizedAt = 100, items = { { id = 1, name = 'phone', amount = 1, state = 'held', info = { serial = 'S-1' } },
                { id = 2, name = 'weapon_pistol', amount = 1, state = 'forfeited', evidenceId = 77, info = { serial = 'W-9' } } } } }
        JU.log = { ok = true, custodyId = 12, list = { { id = 9, kind = 'meal', data = { text = 'lunch' }, actorCid = 'OFF1', at = 300 },
            { id = 8, kind = 'rights_read', actorCid = 'OFF1', at = 200 } }, nextBefore = 8 }
        local r = call('pf_mdt:custody:get', OFF, { cid = 'ABC123' })
        assert_true(r.ok, tostring(r.error))
        assert_eq(r.booking.receiptId, 31)
        local gr = last(JU, 'GetPropertyReceipt')
        assert_eq(gr[1], 31)
        assert_eq(gr[2].viewer, OFF)
        assert_eq(r.receipt.id, 31)
        assert_eq(r.receipt.state, 'held')
        assert_eq(#r.receipt.items, 2)
        assert_eq(r.receipt.items[2].evidenceId, 77)
        assert_eq(r.receipt.items[1].info, nil, 'item info stays on the server')
        assert_eq(r.receipt.lockerStash, nil)
        assert_eq(r.receipt.cid, nil)
        local gl = last(JU, 'GetCustodyLog')
        assert_eq(gl[1], 12)
        assert_eq(gl[2].viewer, OFF)
        assert_eq(gl[2].limit, 25)
        assert_eq(#r.log, 2)
        assert_eq(r.log[1].kind, 'meal')
        assert_eq(r.log[1].data.text, 'lunch')
        assert_eq(r.logNext, 8)
        local detail = json.decode(SQL.inserts[1].params[6])
        assert_eq(detail.receipt, 31)
        assert_eq(detail.log, true)
    end)

    it('no receipt id asks for no receipt; a refused receipt or log is shown as its message', function()
        JU.custody = { id = 12, cid = 'ABC123', state = 'held' }
        JU.booking = { ok = true, booking = { bookingNo = 'B-1' } }
        JU.log = { ok = false, error = 'no_permission', message = 'Officers on duty only' }
        local r = call('pf_mdt:custody:get', OFF, { cid = 'ABC123' })
        assert_true(r.ok)
        assert_eq(last(JU, 'GetPropertyReceipt'), nil)
        assert_eq(r.receipt, nil)
        assert_eq(r.log, nil)
        assert_eq(r.logError, 'Officers on duty only')
        JU.booking = { ok = true, booking = { bookingNo = 'B-1', receiptId = 5 } }
        JU.receipt = { ok = false, error = 'not_found', message = 'No such receipt' }
        r = call('pf_mdt:custody:get', OFF, { cid = 'ABC123' })
        assert_eq(r.receipt, nil)
        assert_eq(r.receiptError, 'No such receipt')
    end)

    it('pages older log entries on duty, with the caller as viewer, audited before the answer', function()
        JU.log = { ok = true, custodyId = 12, list = { { id = 7, kind = 'note', data = { text = 'calm' }, actorCid = 'OFF1', at = 150 } } }
        local r = call('pf_mdt:custody:history', OFF, { custodyId = 12, before = 8 })
        assert_true(r.ok, tostring(r.error))
        assert_eq(#r.log, 1)
        assert_eq(r.log[1].id, 7)
        assert_eq(r.logNext, nil)
        local gl = last(JU, 'GetCustodyLog')
        assert_eq(gl[1], 12)
        assert_eq(gl[2].before, 8)
        assert_eq(gl[2].viewer, OFF)
        assert_eq(#SQL.inserts, 1)
        assert_eq(SQL.inserts[1].params[1], 'custody')
        assert_eq(SQL.inserts[1].params[2], '12')
        assert_eq(SQL.inserts[1].params[3], 'read')
        assert_eq(json.decode(SQL.inserts[1].params[6]).op, 'custody_log')
        -- no audit row, no answer
        SQL.fail = true
        local f = call('pf_mdt:custody:history', OFF, { custodyId = 12, before = 8 })
        assert_eq(f.ok, false)
        assert_eq(f.error, 'db_unavailable')
        assert_eq(f.log, nil)
    end)

    it('refuses off duty, civilians and bad cursors before asking pf-justice', function()
        assert_eq(call('pf_mdt:custody:history', OFFDUTY, { custodyId = 12, before = 8 }).error, 'not_on_duty')
        assert_eq(call('pf_mdt:custody:history', CIV, { custodyId = 12, before = 8 }).error, 'no_access')
        assert_eq(call('pf_mdt:custody:history', OFF, { custodyId = 12 }).error, 'bad_args')
        assert_eq(call('pf_mdt:custody:history', OFF, { custodyId = 12, before = 'x' }).error, 'bad_args')
        assert_eq(call('pf_mdt:custody:history', OFF, { custodyId = -1, before = 3 }).error, 'bad_args')
        assert_eq(count(JU, 'GetCustodyLog'), 0)
    end)

    it('the history endpoint is on the client bridge allowlist', function()
        local f = __readfile(RES .. 'client/pages_ext.lua')
        assert_true(f:find("'pf_mdt:custody:history'", 1, true) ~= nil)
    end)
end)

describe('22C lab queue: one ListLabJobs for the page', function()
    it('asks pfm-policejob once for every item of the page, caller as viewer, and files the jobs per item', function()
        PJ.list = { ok = true, list = { { id = 1 }, { id = 2 }, { id = 3 } }, next = 3 }
        PJ.jobs = { ok = true, jobs = { { id = 41, evidenceId = 1, test = 'dna', state = 'queued' },
            { id = 42, evidenceId = 1, test = 'prints', state = 'ready' }, { id = 43, evidenceId = 3, test = 'tox', state = 'released' } } }
        local r = call('pf_mdt:lab:queue', OFF, { state = 'at_lab' })
        assert_true(r.ok)
        assert_eq(count(PJ, 'ListLabJobs'), 1)
        assert_eq(count(PJ, 'GetEvidence'), 0, 'no per-row read')
        local f = last(PJ, 'ListLabJobs')[1]
        assert_eq(f.viewer, OFF)
        assert_eq(#f.evidenceIds, 3)
        assert_eq(f.evidenceIds[1], 1)
        assert_eq(#r.list[1].labs, 2)
        assert_eq(#r.list[2].labs, 0)
        assert_eq(r.list[3].labs[1].id, 43)
        assert_eq(r.next, 3)
    end)

    it('a refused job list marks the rows, an empty page asks nothing', function()
        PJ.list = { ok = true, list = { { id = 1 } } }
        PJ.jobs = { ok = false, error = 'no_permission' }
        local r = call('pf_mdt:lab:queue', OFF, {})
        assert_true(r.ok)
        assert_eq(r.list[1].labs, nil)
        assert_eq(r.list[1].labsError, 'The lab jobs could not be read')
        PJ.calls = {}
        PJ.list = { ok = true, list = {} }
        call('pf_mdt:lab:queue', OFF, {})
        assert_eq(count(PJ, 'ListLabJobs'), 0)
    end)
end)
