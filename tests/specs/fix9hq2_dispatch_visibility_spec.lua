-- Dispatch app (pf-services/server/apps.lua), per-request actions:
--   (a) the waypoint uses the list's visibility rule (the kind's job list), so a Benny's or
--       Beeker's mechanic gets the waypoint of a mechanic.roadside call they see and accept;
--   (b) City Hall business requests (gov.request.*) are claimable from the generic Dispatch app
--       only with the permission pf-government's Business Requests app checks for that kind.
load_resource('tests/lua/fivem_mocks.lua')

Config = {}
load_resource('[pfscripts]/pf-services/shared/catalog.lua')
load_resource('[pfscripts]/pf-services/shared/config.lua')
function GetCurrentResourceName() return 'pf-services' end
local started = { ['pf-devices'] = true, ['pfm-core'] = true, ['pf-government'] = true }
function GetResourceState(name) return started[name] and 'started' or 'missing' end

local handlers = {}
Mock.exportsByResource['pf-devices'] = {
    RegisterApp = function() return true end,
    RegisterAppHandlers = function(_, id, map) handlers[id] = map return true end,
    PushToJob = function() return 0 end,
    PushToCitizen = function() return true end,
}

-- pf-government's permission check: src -> { perm = true }
local govPerms, permCalls = {}, {}
Mock.exportsByResource['pf-government'] = {
    HasPermission = function(_, src, perm)
        permCalls[#permCalls + 1] = { src = src, perm = perm }
        return (govPerms[src] or {})[perm] == true
    end,
}

load_resource('[pfscripts]/pf-services/server/schema.lua')
load_resource('[pfscripts]/pf-services/server/events.lua')
load_resource('[pfscripts]/pf-services/server/requests.lua')
load_resource('[pfscripts]/pf-services/server/apps.lua')
load_resource('[pfscripts]/pf-services/server/main.lua')
PFServices.RegisterApps()

-- requests held here; accept / complete / list record what reached the request layer
local REQ, accepted, completed = {}, {}, {}
PFServices.GetRequest = function(id) return REQ[tonumber(id)] end
PFServices.AcceptRequest = function(src, id)
    accepted[#accepted + 1] = { src = src, id = id }
    return { ok = true, request = REQ[id] }
end
PFServices.CompleteRequest = function(src, id)
    completed[#completed + 1] = { src = src, id = id }
    return { ok = true, request = REQ[id] }
end
PFServices.ListForJob = function(job)
    local out = {}
    for _, r in pairs(REQ) do if PFServices.WorksOn(job, r) then out[#out + 1] = r end end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end
PFServices.ListForAssignee = function() return {} end

local BENNY, BEEKER, LSC, COP, CLERK, LICENSER, BOSS = 1, 2, 3, 4, 5, 6, 7

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    started['pf-government'] = true
    govPerms, permCalls, accepted, completed = {}, {}, {}, {}
    local function add(src, cid, job)
        local p = Mock.newPlayer(src, cid)
        p.PlayerData.source = src
        p.PlayerData.job = { name = job, label = job, onduty = true, grade = { level = 0 } }
    end
    add(BENNY, 'BEN1', 'bennys')
    add(BEEKER, 'BEE1', 'beeker')
    add(LSC, 'LSC1', 'mechanic')
    add(COP, 'COP1', 'police')
    add(CLERK, 'GOV1', 'government')
    add(LICENSER, 'GOV2', 'government')
    add(BOSS, 'GOV3', 'government')
    govPerms[LICENSER] = { licenses = true }
    govPerms[BOSS] = { licenses = true, businesses = true }
    REQ = {
        [1] = { id = 1, kind = 'mechanic.roadside', job = 'mechanic', status = 'open', title = 'Flat tyre',
            coords = { x = 10.0, y = 20.0, z = 30.0 }, requester = 'CIT1' },
        [2] = { id = 2, kind = 'gov.request.license', job = 'government', status = 'open', title = 'Diner: License',
            coords = { x = 1.0, y = 2.0, z = 3.0 }, from = { type = 'business', id = 'b1', name = 'Diner' } },
        [3] = { id = 3, kind = 'gov.request.slot', job = 'government', status = 'open', title = 'Diner: slot',
            coords = { x = 4.0, y = 5.0, z = 6.0 }, from = { type = 'business', id = 'b1', name = 'Diner' } },
        [4] = { id = 4, kind = 'gov.request.unknown', job = 'government', status = 'open', title = 'x',
            coords = { x = 7.0, y = 8.0, z = 9.0 } },
    }
end

local function waypoints(src)
    local n = 0
    for _, e in ipairs(Mock.clientEventsNamed('pf-services:client:waypoint')) do if e.target == src then n = n + 1 end end
    return n
end

describe('(a) Dispatch waypoint follows the list visibility rule', function()
    it("Benny's and Beeker's mechanics get the waypoint of a roadside call (request job = mechanic)", function()
        for _, src in ipairs({ BENNY, BEEKER, LSC }) do
            local list = handlers.dispatch.list(src)
            assert_true(list.ok)
            assert_eq(#list.requests, 1, 'the call is in their list')
            assert_eq(list.requests[1].id, 1)
            local w = handlers.dispatch.waypoint(src, { id = 1 })
            assert_true(w.ok, 'waypoint for job ' .. tostring(src) .. ': ' .. tostring(w.error))
            assert_eq(w.coords.x, 10.0)
            assert_eq(waypoints(src), 1)
        end
    end)

    it('a job the kind does not list gets no waypoint', function()
        local w = handlers.dispatch.waypoint(COP, { id = 1 })
        assert_false(w.ok)
        assert_eq(w.error, 'not_found')
        assert_eq(waypoints(COP), 0)
        local g = handlers.dispatch.waypoint(BENNY, { id = 2 })
        assert_false(g.ok, 'a mechanic cannot locate a City Hall request')
    end)

    it('a missing id or payload is not_found', function()
        assert_eq(handlers.dispatch.waypoint(BENNY, { id = 999 }).error, 'not_found')
        assert_eq(handlers.dispatch.waypoint(BENNY, nil).error, 'not_found')
    end)
end)

describe('(b) City Hall requests on the generic Dispatch app', function()
    it('a government employee without the kind permission cannot claim a license request', function()
        local a = handlers.dispatch.accept(CLERK, { id = 2 })
        assert_false(a.ok)
        assert_eq(a.error, 'no_permission')
        assert_eq(#accepted, 0, 'never reached AcceptRequest')
        assert_eq(permCalls[1].perm, 'licenses', 'the government app permission for license requests')
    end)

    it('the permission is per kind: licenses does not cover a slot request', function()
        assert_eq(handlers.dispatch.accept(LICENSER, { id = 3 }).error, 'no_permission')
        assert_eq(#accepted, 0)
        local a = handlers.dispatch.accept(LICENSER, { id = 2 })
        assert_true(a.ok, a.error)
        assert_eq(accepted[1].src, LICENSER)
        assert_eq(accepted[1].id, 2)
        assert_true(handlers.dispatch.accept(BOSS, { id = 3 }).ok)
    end)

    it('an unknown gov.request kind, or pf-government stopped, is never claimable here', function()
        assert_eq(handlers.dispatch.accept(BOSS, { id = 4 }).error, 'no_permission')
        started['pf-government'] = false
        assert_eq(handlers.dispatch.accept(BOSS, { id = 2 }).error, 'no_permission')
        assert_eq(#accepted, 0)
    end)

    it('complete through Dispatch needs the same permission', function()
        REQ[2].status, REQ[2].assignee = 'accepted', 'GOV1'
        assert_eq(handlers.dispatch.complete(CLERK, { id = 2 }).error, 'no_permission')
        assert_eq(#completed, 0)
        REQ[2].assignee = 'GOV2'
        assert_true(handlers.dispatch.complete(LICENSER, { id = 2 }).ok)
    end)

    it('other kinds are not gated: a mechanic accepts a roadside call', function()
        local a = handlers.dispatch.accept(BENNY, { id = 1 })
        assert_true(a.ok, a.error)
        assert_eq(#permCalls, 0, 'no government check for non-government kinds')
    end)

    it('the list tells the client which requests the caller may take', function()
        local list = handlers.dispatch.list(LICENSER)
        local by = {}
        for _, r in ipairs(list.requests) do by[r.id] = r end
        assert_true(by[2].canClaim == true)
        assert_true(by[3].canClaim == false)
        assert_true(by[4].canClaim == false)
        local mech = handlers.dispatch.list(BENNY)
        assert_true(mech.requests[1].canClaim == true)
    end)
end)
