-- pf-services Dispatch app on a real database: the request list (ListForJob's SQL) and the per-request
-- actions agree on who works a request. A citizen's roadside call is made for 'mechanic' but listed to
-- every shop the kind names (mechanic, bennys, beeker), and each of them gets its waypoint; a job the
-- kind does not name sees neither. A City Hall request is taken from Dispatch only with the
-- pf-government permission for its kind, and a refused accept leaves the row open.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
local started = { ['pf-government'] = true }
function GetResourceState(name) if name == 'pf-government' then return started[name] and 'started' or 'missing' end return 'started' end
GetInvokingResource = GetInvokingResource or function() return nil end

-- the bank (a citizen's roadside call escrows its fee on the ledger)
RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
function GetCurrentResourceName() return 'pfm-banking' end
Config = nil
load_resource('pfm-banking/config.lua')
load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')
Mock.exportsByResource['pfm-banking'] = Mock.exportsByResource['__self']
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end
assert(PFLedger.Start(), 'ledger start')

local handlers = {}
Mock.exportsByResource['pf-devices'] = {
    PushToJob = function() return 1 end,
    PushToCitizen = function() return true end,
    RegisterApp = function() return true end,
    RegisterAppHandlers = function(_, id, map) handlers[id] = map return true end,
}
-- pf-government's role check: src -> { perm = true }
local govPerms = {}
Mock.exportsByResource['pf-government'] = {
    HasPermission = function(_, src, perm) return (govPerms[src] or {})[perm] == true end,
}

function GetCurrentResourceName() return 'pf-services' end
Config = {}
load_resource('pfm-banking/payouts.lua')
load_resource('[pfscripts]/pf-services/shared/catalog.lua')
load_resource('[pfscripts]/pf-services/shared/config.lua')
load_resource('[pfscripts]/pf-services/server/schema.lua')
load_resource('[pfscripts]/pf-services/server/events.lua')
load_resource('[pfscripts]/pf-services/server/requests.lua')
load_resource('[pfscripts]/pf-services/server/apps.lua')
load_resource('[pfscripts]/pf-services/server/main.lua')
assert(RunMigrations('pf-services', PFServices.Migrations))
PFServices.RegisterApps()

local CITIZEN, LSC, BENNY, BEEKER, COP, CLERK, LICENSER = 1, 2, 3, 4, 5, 6, 7

local function row(id) return MySQL.single.await('SELECT status, job, assignee_cid FROM pf_service_requests WHERE id = ?', { id }) end
local function inList(src, id)
    local list = handlers.dispatch.list(src)
    assert_true(list.ok, 'list for ' .. src)
    for _, r in ipairs(list.requests) do if r.id == id then return r end end
    return nil
end
local function waypoints(src)
    local n = 0
    for _, e in ipairs(Mock.clientEventsNamed('pf-services:client:waypoint')) do if e.target == src then n = n + 1 end end
    return n
end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords, govPerms = {}, {}, {}
    started['pf-government'] = true
    MySQL.query.await('DELETE FROM pf_service_requests')
    PFServices.__resetRequests()
    local function add(src, cid, job)
        local p = Mock.newPlayer(src, cid)
        p.PlayerData.source = src
        p.PlayerData.money = { cash = 0, bank = 1000 }
        if job then p.PlayerData.job = { name = job, label = job, onduty = true, grade = { level = 0 } } end
    end
    add(CITIZEN, 'CIT1')
    add(LSC, 'LSC1', 'mechanic')
    add(BENNY, 'BEN1', 'bennys')
    add(BEEKER, 'BEE1', 'beeker')
    add(COP, 'COP1', 'police')
    add(CLERK, 'GOV1', 'government')
    add(LICENSER, 'GOV2', 'government')
    govPerms[LICENSER] = { licenses = true }
    Mock.coords[CITIZEN] = vector3(150.0, -250.0, 30.0)
end

describe('Dispatch: the waypoint follows the list', function()
    it("a roadside call is listed to every shop and each gets its waypoint; Benny's takes it", function()
        local res = PFServices.CitizenRequest(CITIZEN, 'mechanic.roadside', 'flat tyre')
        assert_true(res.ok, res.error)
        assert_eq(row(res.id).job, 'mechanic', 'the request row names the first shop')
        for _, src in ipairs({ LSC, BENNY, BEEKER }) do
            local r = inList(src, res.id)
            assert_true(r ~= nil, 'listed to ' .. src)
            assert_near(r.coords.x, 150.0, 0.01)
            local w = handlers.dispatch.waypoint(src, { id = res.id })
            assert_true(w.ok, 'waypoint for ' .. src .. ': ' .. tostring(w.error))
            assert_near(w.coords.y, -250.0, 0.01)
            assert_eq(waypoints(src), 1)
        end
        assert_true(handlers.dispatch.accept(BENNY, { id = res.id }).ok)
        local after = row(res.id)
        assert_eq(after.status, 'accepted')
        assert_eq(after.assignee_cid, 'BEN1')
    end)
    it('a job the kind does not name sees neither the call nor its waypoint', function()
        local res = PFServices.CitizenRequest(CITIZEN, 'mechanic.roadside', 'flat tyre')
        assert_true(res.ok, res.error)
        assert_eq(inList(COP, res.id), nil)
        local w = handlers.dispatch.waypoint(COP, { id = res.id })
        assert_false(w.ok)
        assert_eq(w.error, 'not_found')
        assert_eq(waypoints(COP), 0)
        assert_eq(handlers.dispatch.accept(COP, { id = res.id }).error, 'wrong_job')
        assert_eq(row(res.id).status, 'open')
    end)
end)

describe('Dispatch: City Hall requests need the role permission', function()
    local function licenseRequest()
        local res = PFServices.CreateRequest({ kind = 'gov.request.license', title = 'Diner: Food license',
            coords = vector3(5.0, 6.0, 7.0), ref = { type = 'business', id = 'diner1' },
            from = { type = 'business', id = 'diner1', name = 'Diner' } })
        assert_true(res.ok, res.error)
        return res.id
    end
    it('without it the request cannot be taken (and stays open); with it the clerk takes it', function()
        local id = licenseRequest()
        local seen = inList(CLERK, id)
        assert_true(seen ~= nil, 'every government employee sees it')
        assert_true(seen.canClaim == false)
        local a = handlers.dispatch.accept(CLERK, { id = id })
        assert_false(a.ok)
        assert_eq(a.error, 'no_permission')
        assert_eq(row(id).status, 'open')
        assert_eq(row(id).assignee_cid, nil)
        assert_true(inList(LICENSER, id).canClaim == true)
        local b = handlers.dispatch.accept(LICENSER, { id = id })
        assert_true(b.ok, b.error)
        assert_eq(b.request.mine, true)
        assert_eq(b.request.requester, nil, 'the result is the public view, not the row')
        local after = row(id)
        assert_eq(after.status, 'accepted')
        assert_eq(after.assignee_cid, 'GOV2')
    end)
    it('pf-government stopped: nobody takes it from Dispatch', function()
        local id = licenseRequest()
        started['pf-government'] = false
        assert_eq(handlers.dispatch.accept(LICENSER, { id = id }).error, 'no_permission')
        assert_eq(row(id).status, 'open')
    end)
    it('a mechanic neither sees it nor locates it', function()
        local id = licenseRequest()
        assert_eq(inList(BENNY, id), nil)
        assert_eq(handlers.dispatch.waypoint(BENNY, { id = id }).error, 'not_found')
    end)
end)
