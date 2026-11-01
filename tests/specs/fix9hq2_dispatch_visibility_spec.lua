-- Dispatch app (pf-services/server/apps.lua), per-request actions:
--   (a) the waypoint uses the list's visibility rule (the kind's job list), so a Benny's or
--       Beeker's mechanic gets the waypoint of a mechanic.roadside call they see and accept;
--   (b) City Hall business requests (gov.request.*) are claimable from the generic Dispatch app
--       only with the permission pf-government's Business Requests app checks for that kind, read
--       from pf-government itself (its GetRequestPermission export over GovRequests.Kinds, loaded
--       here from the real files), so the list exists in one place.
-- The list itself (ListForJob, SQL) is stubbed here with the same rule; the real query is covered by
-- realdb_specs/fix9hq2_dispatch_visibility_realdb_spec.lua.
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

load_resource('[pfscripts]/pf-services/server/schema.lua')
load_resource('[pfscripts]/pf-services/server/events.lua')
load_resource('[pfscripts]/pf-services/server/requests.lua')
load_resource('[pfscripts]/pf-services/server/apps.lua')
load_resource('[pfscripts]/pf-services/server/main.lua')
PFServices.RegisterApps()

-- pf-government's own list of request permissions (Business Requests app) and its real export
GovApps = { Define = function() end }
load_resource('[pfscripts]/pf-government/server/apps/requests.lua')
load_resource('[pfscripts]/pf-government/server/registry_views.lua')
local govRequestPermission = Mock.selfExport('GetRequestPermission')
assert(govRequestPermission, 'pf-government exports GetRequestPermission')

-- pf-government's permission check: src -> { perm = true }
local govPerms, permCalls = {}, {}
Mock.exportsByResource['pf-government'] = {
    HasPermission = function(_, src, perm)
        permCalls[#permCalls + 1] = { src = src, perm = perm }
        return (govPerms[src] or {})[perm] == true
    end,
    GetRequestPermission = function(_, kind) return govRequestPermission(kind) end,
}

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

    it("Dispatch applies the permission pf-government's Business Requests app checks, for every kind", function()
        local govKinds = GovRequests.Kinds
        local n = 0
        for kind, def in pairs(govKinds) do
            n = n + 1
            assert_eq(govRequestPermission(kind), def.perm, kind)
            REQ[10 + n] = { id = 10 + n, kind = kind, job = 'government', status = 'open', title = kind }
            govPerms[CLERK] = { [def.perm] = true }
            permCalls = {}
            assert_true(handlers.dispatch.accept(CLERK, { id = 10 + n }).ok, kind)
            assert_eq(permCalls[1].perm, def.perm, kind)
        end
        assert_true(n >= 4)
        for kind in pairs(PFCatalog.Requests) do
            if kind:sub(1, 12) == 'gov.request.' then assert_true(govKinds[kind] ~= nil, kind .. ' is worked by pf-government') end
        end
    end)

    it("pf-government's list is the only one: changing it there changes what Dispatch allows", function()
        local def = GovRequests.Kinds['gov.request.license']
        def.perm = 'businesses'
        local licenser = handlers.dispatch.accept(LICENSER, { id = 2 })
        local boss = handlers.dispatch.accept(BOSS, { id = 2 })
        def.perm = 'licenses'
        assert_eq(licenser.error, 'no_permission', 'licenses no longer covers it')
        assert_true(boss.ok, 'businesses now does')
    end)

    it('a gov.request kind pf-government does not work is never claimable, whatever its registration says', function()
        assert_true(PFServices.RegisterRequestKind('gov.request.permit', { label = 'Permit', job = 'government', govPermission = 'licenses' }))
        REQ[5] = { id = 5, kind = 'gov.request.permit', job = 'government', status = 'open', title = 'Permit' }
        assert_eq(handlers.dispatch.accept(LICENSER, { id = 5 }).error, 'no_permission')
        assert_eq(handlers.dispatch.accept(BOSS, { id = 5 }).error, 'no_permission')
        -- once pf-government works it, its permission applies
        GovRequests.Kinds['gov.request.permit'] = { short = 'permit', perm = 'licenses', label = 'Permit' }
        local clerk = handlers.dispatch.accept(CLERK, { id = 5 })
        local licenser = handlers.dispatch.accept(LICENSER, { id = 5 })
        GovRequests.Kinds['gov.request.permit'] = nil
        assert_eq(clerk.error, 'no_permission')
        assert_true(licenser.ok, licenser.error)
    end)

    it("pf-government's export answers only for the kinds it works", function()
        assert_eq(govRequestPermission('gov.request.license'), 'licenses')
        assert_eq(govRequestPermission('gov.request.slot'), 'businesses')
        assert_eq(govRequestPermission('mechanic.roadside'), nil)
        assert_eq(govRequestPermission('gov.request.nope'), nil)
        assert_eq(govRequestPermission(nil), nil)
        assert_eq(govRequestPermission({ 'gov.request.license' }), nil)
    end)

    it('an older pf-government without the export: nothing is claimable (never open by default)', function()
        local gov = Mock.exportsByResource['pf-government']
        local real = gov.GetRequestPermission
        gov.GetRequestPermission = nil
        local a = handlers.dispatch.accept(BOSS, { id = 2 })
        gov.GetRequestPermission = real
        assert_eq(a.error, 'no_permission')
        assert_eq(#accepted, 0)
    end)

    it('giving a request back needs no permission (a demoted clerk is not stuck with it)', function()
        REQ[2].status, REQ[2].assignee = 'accepted', 'GOV1'
        local released = {}
        local realRelease = PFServices.ReleaseRequest
        PFServices.ReleaseRequest = function(src, id) released[#released + 1] = id return { ok = true, request = REQ[id] } end
        assert_true(handlers.dispatch.release(CLERK, { id = 2 }).ok)
        PFServices.ReleaseRequest = realRelease
        assert_eq(released[1], 2)
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
