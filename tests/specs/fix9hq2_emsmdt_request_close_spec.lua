-- pf-emsmdt: a call pf-services put on the EMS board (CreateDispatchCall with the request's id) leaves the
-- board when that request closes: deleted when cancelled or expired (the patient respawned, checked in,
-- logged out, left, or nobody came), shown as done when completed (revived). Only the call with that
-- request id is touched, the same request is posted once, and no client can raise the event.
load_resource('tests/lua/fivem_mocks.lua')
function IsDuplicityVersion() return true end
function GetResourceState() return 'started' end
QBCore = QBCoreMock
promise = promise or { new = function() return { resolve = function(self, v) self.value = v end } end }
Citizen = Citizen or {}
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

function GetCurrentResourceName() return 'pf-emsmdt' end
Config = nil
load_resource('[pfscripts]/pf-emsmdt/config.lua')
load_resource('[pfscripts]/pf-emsmdt/shared/framework.lua')
load_resource('[pfscripts]/pf-emsmdt/server/main.lua')
SetTimeout = function(ms, fn) if (ms or 0) <= 1000 then fn() end end

local MEDIC = 1
local create = function(data) return Mock.selfExport('CreateDispatchCall')(data) end
local changed = Mock.eventHandlers['pf-services:requestChanged']

local function board()
    local calls = Mock.callCallback('pf_emsmdt_dispatch:server:GetCalls', MEDIC) or {}
    local byRequest, n = {}, 0
    for _, c in ipairs(calls) do
        n = n + 1
        if c.requestId then byRequest[c.requestId] = c end
    end
    return byRequest, n, calls
end

-- what pf-services/server/main.lua passes for a new ems.patient request
local function posted(id, title)
    return create({ title = title or ('Person down: Patient ' .. id), description = 'Unconscious or badly injured person',
        code = 'EMS', priority = 1, coords = { x = 10.0 + id, y = 20.0, z = 30.0 }, locationLabel = title,
        createdBy = 'Medical alert', callType = 'ems.patient', status = 'pending', requestId = id })
end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    Mock.newPlayer(MEDIC).PlayerData.job = { name = 'ambulance', type = 'ems', onduty = true, grade = { level = 1 } }
    -- clear the board the test before left
    local _, _, calls = board()
    for _, c in ipairs(calls) do changed({ id = c.requestId or -1 }, 'cancelled') end
end

describe('EMS MDT calls follow their pf-services request', function()
    it('the export is reachable and the board starts empty', function()
        assert_true(type(create) == 'function')
        assert_true(type(changed) == 'function', 'pf-emsmdt listens to pf-services:requestChanged')
        local _, n = board()
        assert_eq(n, 0)
    end)
    it('cancelled (respawned, checked in, logged out, left) or expired: the call is gone', function()
        posted(11); posted(12); posted(13)
        changed({ id = 11, kind = 'ems.patient', status = 'cancelled' }, 'cancelled')
        changed({ id = 12, kind = 'ems.patient', status = 'expired' }, 'expired')
        local by, n = board()
        assert_eq(n, 1)
        assert_eq(by[11], nil)
        assert_eq(by[12], nil)
        assert_true(by[13] ~= nil, 'another patient keeps their call')
    end)
    it('completed (revived): the call stays as done', function()
        posted(21)
        changed({ id = 21, kind = 'ems.patient', status = 'completed' }, 'completed')
        local by = board()
        assert_eq(by[21].status, 'completed')
    end)
    it('accepted, released, on site or created leave the call as it is', function()
        posted(31)
        for _, what in ipairs({ 'accepted', 'released', 'on_site', 'created' }) do changed({ id = 31 }, what) end
        local by = board()
        assert_eq(by[31].status, 'pending')
    end)
    it('only the call with that request id: an unlinked call with the same title and spot stays', function()
        create({ title = 'Person down: Patient 41', callType = 'ems.patient', coords = { x = 51.0, y = 20.0, z = 30.0 }, status = 'pending' })
        changed({ id = 41, kind = 'ems.patient', title = 'Person down: Patient 41', coords = { x = 51.0, y = 20.0, z = 30.0 } }, 'cancelled')
        local _, n = board()
        assert_eq(n, 1)
        changed({ kind = 'ems.patient' }, 'cancelled')        -- no id: nothing
        changed('junk', 'cancelled')
        local _, n2 = board()
        assert_eq(n2, 1)
    end)
    it('the same request is posted once', function()
        local a = posted(51)
        local b = posted(51)
        assert_eq(a.id, b.id)
        local _, _, calls = board()
        local n = 0
        for _, c in ipairs(calls) do if c.requestId == 51 then n = n + 1 end end
        assert_eq(n, 1)
    end)
    it('no client can raise it: not a net event, and a player source is ignored', function()
        assert_eq(Mock.netHandlers['pf-services:requestChanged'], nil)
        posted(61)
        Mock.fireEvent('pf-services:requestChanged', MEDIC, { id = 61 }, 'cancelled')
        local by = board()
        assert_true(by[61] ~= nil)
    end)
end)
