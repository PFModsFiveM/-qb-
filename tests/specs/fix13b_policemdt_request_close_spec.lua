-- pf-policemdt-DEV: a call pf-services put on the police board (CreateDispatchCall with the request's id,
-- e.g. a citizen's 'Police assistance' call or a city event marked for the police) leaves the board when
-- that request closes: cancelled (the citizen cancelled it, a resource closed it), expired or completed.
-- Only the call with that request id is touched, the same request is posted once, other updates
-- (accepted, released) leave it, and no client can raise the event. Like the EMS MDT (pf-emsmdt).
load_resource('tests/lua/fivem_mocks.lua')
function IsDuplicityVersion() return true end
function GetResourceState() return 'missing' end
QBCore = QBCoreMock
promise = promise or { new = function() return { resolve = function(self, v) self.value = v end } end }
Citizen.Await = Citizen.Await or function(p) return p.value end

local function call(sql, params, cb)
    if type(params) == 'function' then cb = params end
    if cb then cb({}) end
    return {}
end
Mock.exportsByResource['oxmysql'] = {
    execute = function(_, sql, params, cb) return call(sql, params, cb) end,
    query = function(_, sql, params, cb) return call(sql, params, cb) end,
    fetch = function(_, sql, params, cb) return call(sql, params, cb) end,
    insert = function(_, sql, params, cb) if type(cb) == 'function' then cb(1) end return 1 end,
    update = function(_, sql, params, cb) if type(cb) == 'function' then cb(1) end return 1 end,
    scalar = function(_, sql, params, cb) if type(cb) == 'function' then cb(0) end return 0 end,
}

function GetCurrentResourceName() return 'pf-policemdt-DEV' end
Config = nil
load_resource('[pfscripts]/pf-policemdt-DEV/shared/framework.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/config.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/server/access.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/server/main.lua')

local OFFICER = 1
local create = Mock.selfExport('CreateDispatchCall')
local changed = Mock.eventHandlers['pf-services:requestChanged']

local function board()
    local calls = Mock.callCallback('pf_mdt_dispatch:server:GetCalls', OFFICER) or {}
    local byRequest, n = {}, 0
    for _, c in ipairs(calls) do
        n = n + 1
        if c.requestId then byRequest[c.requestId] = c end
    end
    return byRequest, n, calls
end

-- what pf-services/server/main.lua passes for a new police.assist request
local function posted(id, title)
    return create({ title = title or ('Police assistance for Citizen ' .. id), description = 'Shots heard',
        code = '911', priority = 2, coords = { x = 10.0 + id, y = 20.0, z = 30.0 }, locationLabel = title,
        createdBy = 'Citizen ' .. id, callType = 'police.assist', status = 'pending', requestId = id })
end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    Mock.newPlayer(OFFICER, 'OFFCID').PlayerData.job = { name = 'police', onduty = true, grade = { level = 4 } }
    -- clear the board the test before left (an officer completing a call removes it)
    local _, _, calls = board()
    for _, c in ipairs(calls) do Mock.fireNet('pf_mdt_dispatch:server:CompleteCall', OFFICER, c.id) end
end

describe('police MDT calls follow their pf-services request', function()
    it('the export is reachable, pf-police listens to request changes, and the board starts empty', function()
        assert_true(type(create) == 'function')
        assert_true(type(changed) == 'function', 'pf-policemdt-DEV listens to pf-services:requestChanged')
        local _, n = board()
        assert_eq(n, 0)
    end)
    it('the call keeps the request id, and the same request is posted once', function()
        local a = posted(21)
        local b = posted(21)
        assert_eq(a.id, b.id)
        local by, n = board()
        assert_eq(n, 1)
        assert_eq(by[21].requestId, 21)
        assert_eq(by[21].callType, 'police.assist')
    end)
    it('cancelled or expired: the call leaves the board; another request keeps its call', function()
        posted(31); posted(32); posted(33)
        changed({ id = 31, kind = 'police.assist', status = 'cancelled' }, 'cancelled')
        changed({ id = 32, kind = 'police.assist', status = 'expired' }, 'expired')
        local by, n = board()
        assert_eq(n, 1)
        assert_eq(by[31], nil)
        assert_eq(by[32], nil)
        assert_true(by[33] ~= nil, 'another call stays')
    end)
    it('completed: the call leaves the board too (as a call an officer completes on the MDT)', function()
        posted(41)
        changed({ id = 41, kind = 'police.assist', status = 'completed' }, 'completed')
        local _, n = board()
        assert_eq(n, 0)
    end)
    it('accepted, released or a new request leave the call where it is', function()
        posted(51)
        changed({ id = 51, status = 'accepted' }, 'accepted')
        changed({ id = 51, status = 'open' }, 'released')
        changed({ id = 51, status = 'open' }, 'created')
        local by, n = board()
        assert_eq(n, 1)
        assert_eq(by[51].status, 'pending')
    end)
    it('a call without a request id is never touched, whatever closes', function()
        create({ title = 'Store robbery', coords = { x = 1.0, y = 2.0, z = 3.0 }, createdBy = 'system' })
        posted(61)
        changed({ id = 61 }, 'cancelled')
        changed({ id = 0 }, 'cancelled')
        changed({}, 'cancelled')
        changed(nil, 'cancelled')
        changed('61', 'cancelled')
        local _, n, calls = board()
        assert_eq(n, 1)
        assert_eq(calls[1].title, 'Store robbery')
    end)
    it('a client raising the event (a player source) is ignored', function()
        posted(71)
        Mock.fireEvent('pf-services:requestChanged', 5, { id = 71 }, 'cancelled')
        local by = board()
        assert_true(by[71] ~= nil)
        Mock.fireEvent('pf-services:requestChanged', nil, { id = 71 }, 'cancelled')
        by = board()
        assert_eq(by[71], nil)
    end)
end)
