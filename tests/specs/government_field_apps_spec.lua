-- pf-government field apps on pf-devices (mocked): every app registers with a real government
-- permission; the real pf-devices access check keeps others out; each handler refuses without its
-- permission or away from the place it needs, and on success runs the existing government handler.
-- Also the business request flow against a stand-in pf-services: a request only completes once the
-- approval really happened at the recorded spot.
load_resource('tests/lua/fivem_mocks.lua')

local started = { ['pf-devices'] = true, ['pf-government'] = true, ['pfm-core'] = true, ['pf-services'] = true }
function GetResourceState(name) return started[name] and 'started' or 'missing' end
function GetCurrentResourceName() return 'pf-government' end
function GetEntityHeading() return 45.0 end
vec4 = vec4 or vector4

-- a forgiving database: statements a test cares about are answered by `on` handlers, the rest get
-- neutral answers (inserts get ids, updates touch one row)
local DB = { handlers = {}, nextId = 100, log = {} }
local function on(fragment, fn) table.insert(DB.handlers, 1, { fragment, fn }) end
local function run(kind, q, p)
    DB.log[#DB.log + 1] = q
    for _, h in ipairs(DB.handlers) do if q:find(h[1], 1, true) then return h[2](p or {}, kind) end end
    if kind == 'insert' then DB.nextId = DB.nextId + 1 return DB.nextId end
    if kind == 'update' then return 1 end
    if kind == 'query' then return {} end
    return nil
end
local function op(kind)
    local function call(q, p, cb)
        if type(p) == 'function' then cb, p = p, nil end
        local out = run(kind, q, p)
        if cb then cb(out) end
        return out
    end
    return setmetatable({ await = function(q, p) return call(q, p) end }, { __call = function(_, q, p, cb) return call(q, p, cb) end })
end
MySQL = { query = op('query'), insert = op('insert'), update = op('update'), scalar = op('scalar'), single = op('single'), prepare = op('query') }

Config = nil
load_resource('[pfscripts]/pf-government/config.lua')
load_resource('[pfscripts]/pf-devices/shared/config.lua')
load_resource('[pfscripts]/pf-devices/server/registry.lua')
load_resource('[pfscripts]/pf-devices/server/installs.lua')
load_resource('[pfscripts]/pf-devices/server/rpc.lua')
load_resource('[pfscripts]/pf-devices/server/push.lua')
Mock.exportsByResource['pf-devices'] = {
    RegisterApp = function(_, def) return PFDevices.RegisterApp(def, 'pf-government') end,
    RegisterAppHandlers = function(_, id, map) return PFDevices.RegisterAppHandlers(id, map, 'pf-government') end,
    PushToJob = function() return 0 end,
    PushToCitizen = function() return true end,
}

for _, f in ipairs({ 'server/core.lua', 'server/schema.lua', 'server/bills.lua', 'server/businesses.lua', 'server/licenses.lua',
    'server/callbacks.lua', 'server/premises.lua', 'server/delivery_zones.lua', 'server/apps/common.lua', 'server/apps/fines.lua',
    'server/apps/inspections.lua', 'server/apps/requests.lua', 'server/apps/budget.lua', 'server/apps/announcements.lua',
    'server/apps/setup.lua', 'server/apps/register.lua' }) do
    load_resource('[pfscripts]/pf-government/' .. f)
end
Mock.exportsByResource['pf-government'] = Mock.exportsByResource['__self']
GovSchema.Ensure = function() return true end
function LogAudit() end
function NotifyGovernment() end
function DebugPrint() end
function IsGovernmentEmployee(src) local P = Mock.players[src] return P ~= nil and P.PlayerData.job.name == 'government' end
PFDevices.RPC_TEST = true
function GetGameTimer() return 0 end

-- spies on the existing government handlers: they record the call and run the real handler
local calls = {}
for _, action in ipairs({ 'fine:issueImmediate', 'bill:create', 'bill:waive', 'premises:slot:approve', 'premises:list',
    'announcement:create', 'announcement:delete', 'business:updateLocation' }) do
    local real = Government.NuiCallbacks[action]
    assert(real, action .. ' exists')
    Government.NuiCallbacks[action] = function(data, cb) calls[#calls + 1] = { action = action, data = data } return real(data, cb) end
end
local function called(action)
    local n, last = 0, nil
    for _, c in ipairs(calls) do if c.action == action then n, last = n + 1, c.data end end
    return n, last
end
local realRecord = RecordBusinessInspection
local inspections = {}
function RecordBusinessInspection(...) inspections[#inspections + 1] = { ... } return realRecord(...) end
local realIssue = IssueLicense
local licenses = {}
function IssueLicense(...) licenses[#licenses + 1] = { ... } return realIssue(...) end

-- a stand-in for pf-services' request service (its own logic is tested in pf-services specs)
local FS
local function resetServices()
    FS = { reqs = {}, handlers = FS and FS.handlers or {}, n = 0 }
end
resetServices()
Mock.exportsByResource['pf-services'] = {
    Emit = function() return 1 end,
    CreateRequest = function(_, o)
        for _, r in pairs(FS.reqs) do
            if (r.status == 'open' or r.status == 'accepted') and r.ref.type == o.ref.type and r.ref.id == o.ref.id then return { ok = true, id = r.id, existing = true } end
        end
        FS.n = FS.n + 1
        FS.reqs[FS.n] = { id = FS.n, kind = o.kind, status = 'open', title = o.title, details = o.details, coords = o.coords, ref = o.ref,
            from = o.from, requester = o.requester, meta = o.meta, job = 'government' }
        return { ok = true, id = FS.n }
    end,
    GetRequest = function(_, id) return FS.reqs[tonumber(id)] end,
    AcceptRequest = function(_, src, id)
        local r, P = FS.reqs[id], Mock.players[src]
        if r.status ~= 'open' then return { ok = false, error = 'not_open' } end
        if P.PlayerData.job.name ~= 'government' or not P.PlayerData.job.onduty then return { ok = false, error = 'wrong_job' } end
        r.status, r.assignee = 'accepted', P.PlayerData.citizenid
        return { ok = true }
    end,
    CompleteRequest = function(_, src, id, proof)
        local r = FS.reqs[id]
        if r.status ~= 'accepted' or r.assignee ~= Mock.players[src].PlayerData.citizenid then return { ok = false, error = 'not_yours' } end
        local ok, why = FS.handlers[r.kind].canComplete(r, src, proof)
        if ok ~= true then return { ok = false, error = why or 'not_done' } end
        r.status = 'completed'
        return { ok = true }
    end,
    CancelRequest = function(_, src, id, reason) FS.reqs[id].status, FS.reqs[id].closeReason = 'cancelled', reason return { ok = true } end,
    FindOpenByRef = function(_, t, id)
        for _, r in pairs(FS.reqs) do if (r.status == 'open' or r.status == 'accepted') and r.ref.type == t and r.ref.id == id then return r end end
    end,
    CloseByRef = function() return { ok = true } end,
    ListForJob = function() local out = {} for _, r in pairs(FS.reqs) do out[#out + 1] = r end return out end,
    RegisterRequestHandler = function(_, kind, h) FS.handlers[kind] = h return true end,
}

local CIV, CLERK, MAYOR, UTIL, DEPUTY, OWNER = 1, 2, 3, 4, 5, 6
local SHOP = vector3(100.0, 200.0, 30.0)
local BIZ = { business_id = 'store:corner', business_name = 'Corner Store', business_type = 'store', owner_id = 'OWN1',
    location_x = SHOP.x, location_y = SHOP.y, location_z = SHOP.z }
local NOLOC = { business_id = 'store:nowhere', business_name = 'Nowhere', business_type = 'store', owner_id = 'X' }
local rows, slots, bills

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 100
    calls, inspections, licenses = {}, {}, {}
    rows, slots = {}, {}
    bills = { [7] = { id = 7, status = 'unpaid' }, [8] = { id = 8, status = 'paid' } }
    DB.handlers = {}
    on('FROM pf_gov_businesses WHERE business_id = ?', function(p)
        if p[1] == BIZ.business_id then return BIZ end
        if p[1] == NOLOC.business_id then return NOLOC end
    end)
    on('FROM pf_gov_businesses WHERE owner_id = ?', function() return { BIZ } end)
    on('SELECT id, status FROM pf_gov_bills WHERE id = ?', function(p) return bills[tonumber(p[1])] end)
    on('INSERT INTO pf_gov_premises_slots', function() DB.nextId = DB.nextId + 1 slots[DB.nextId] = true return DB.nextId end)
    on('SELECT 1 FROM pf_gov_premises_slots WHERE id = ?', function(p) return slots[tonumber(p[1])] and 1 or nil end)
    on('INSERT INTO pf_gov_business_requests', function(p)
        rows[p[1]] = { request_id = p[1], business_id = p[2], kind = p[3], subject = p[4], note = p[5], x = p[6], y = p[7], z = p[8], heading = p[9], requested_by = p[10], status = 'open' }
        return 0
    end)
    on('FROM pf_gov_business_requests WHERE request_id = ?', function(p) return rows[tonumber(p[1])] end)
    on('UPDATE pf_gov_business_requests SET decision', function(p)
        local r = rows[tonumber(p[6])]
        if r then r.decision, r.decision_note, r.decided_by, r.outcome_ref = p[1], p[2], p[3], p[5] end
        return 1
    end)
    on('UPDATE pf_gov_business_requests SET status', function(p) if rows[tonumber(p[2])] then rows[tonumber(p[2])].status = p[1] end return 1 end)
    Mock.players = {}
    local function gov(src, cid, grade)
        local p = Mock.newPlayer(src, cid)
        p.PlayerData.job = { name = 'government', grade = { level = grade }, onduty = true }
    end
    Mock.newPlayer(CIV, 'CIV1').PlayerData.job = { name = 'unemployed', grade = { level = 0 } }
    gov(CLERK, 'CLK1', 1)
    gov(MAYOR, 'MAY1', 4)
    gov(UTIL, 'UTL1', 0)
    gov(DEPUTY, 'DEP1', 3)
    Mock.newPlayer(OWNER, 'OWN1').PlayerData.job = { name = 'unemployed', grade = { level = 0 } }
    Mock.coords = { [CIV] = SHOP, [CLERK] = SHOP, [MAYOR] = SHOP, [UTIL] = SHOP, [DEPUTY] = SHOP, [OWNER] = SHOP }
    PFDevices.__resetRpc()
end

local function rpc(src, app, method, payload) return PFDevices.HandleRpc(src, app, method, payload or {}) end

describe('registration and access', function()
    it('registers every app with pf-devices under a real government permission', function()
        PFDevices.__reset()
        assert_true(GovApps.RegisterAll())
        local known = {}
        for _, role in pairs(Config.Roles) do for _, perm in ipairs(role.permissions) do known[perm] = true end end
        local ids = { 'govfines', 'govinspections', 'govrequests', 'govbudget', 'govannouncements', 'govsetup', 'cityhallrequests' }
        for _, id in ipairs(ids) do
            local app = PFDevices.GetApp(id)
            assert_true(app ~= nil, id .. ' registered')
            assert_eq(app.resource, 'pf-government')
            assert_eq(app.category, id == 'cityhallrequests' and 'business' or 'government', id .. ' category')
            for _, perm in ipairs(app.access.gov or {}) do assert_true(known[perm], id .. ' uses a real permission: ' .. perm) end
        end
        assert_true(PFDevices.GetApp('cityhallrequests').access.handler)
        local devices = table.concat(PFDevices.GetApp('govrequests').devices, ',')
        assert_eq(devices, 'computer,tablet')
        assert_eq(table.concat(PFDevices.GetApp('govfines').devices, ','), 'tablet')
    end)
    it('pf-devices keeps out everyone without the permission', function()
        assert_eq(rpc(CIV, 'govfines', 'nearby').error, 'not_authorized')
        assert_eq(rpc(UTIL, 'govfines', 'nearby').error, 'not_authorized', 'utility manager has no fines permission')
        assert_true(rpc(CLERK, 'govfines', 'nearby').ok)
        assert_eq(rpc(CLERK, 'govsetup', 'businesses').error, 'not_authorized')
        assert_eq(rpc(CIV, 'govbudget', 'overview').error, 'not_authorized')
        assert_eq(rpc(CIV, 'govrequests', 'list').error, 'not_authorized')
        assert_true(rpc(CIV, 'govannouncements', 'list').ok, 'everyone reads announcements')
        assert_true(rpc(OWNER, 'cityhallrequests', 'overview').ok, 'a business owner opens City Hall Requests')
        DB.handlers = {}   -- nobody owns anything now
        assert_eq(rpc(OWNER, 'cityhallrequests', 'overview').error, 'not_authorized')
    end)
end)

describe('Fines', function()
    it('fines only a person standing next to the official, through fine:issueImmediate', function()
        Mock.coords[CIV] = SHOP + vector3(10.0, 0.0, 0.0)
        local res = GovApps.Fines.issue(CLERK, { target = 'citizen', playerId = CIV, amount = 250, reason = 'Littering' })
        assert_eq(res.error, 'not_nearby')
        assert_eq(called('fine:issueImmediate'), 0)
        Mock.coords[CIV] = SHOP + vector3(2.0, 0.0, 0.0)
        local near = GovApps.Fines.nearby(CLERK).people
        assert_eq(#near, 5, 'everyone in range but the official')
        for _, p in ipairs(near) do assert_eq(p.cid, nil, 'no citizen ids to the tablet') end
        res = GovApps.Fines.issue(CLERK, { target = 'citizen', playerId = CIV, amount = 250, reason = 'Littering' })
        assert_true(res.ok, tostring(res.error))
        local n, data = called('fine:issueImmediate')
        assert_eq(n, 1)
        assert_eq(data.targetCitizenId, 'CIV1')
        assert_eq(data.amount, 250)
        assert_eq(data.source, CLERK)
        assert_eq(#Mock.clientEventsNamed('QBCore:Notify'), 1, 'the person is told')
    end)
    it('refuses bad amounts, a missing reason and officials without the permission', function()
        for _, amount in ipairs({ 0, 1.5, -5, 999999, 'x' }) do
            assert_eq(GovApps.Fines.issue(CLERK, { target = 'citizen', playerId = CIV, amount = amount, reason = 'r' }).error, 'invalid_amount')
        end
        assert_eq(GovApps.Fines.issue(CLERK, { target = 'citizen', playerId = CIV, amount = 10 }).error, 'reason_required')
        assert_eq(GovApps.Fines.issue(UTIL, { target = 'citizen', playerId = CIV, amount = 10, reason = 'r' }).error, 'no_permission')
        assert_eq(called('fine:issueImmediate'), 0)
    end)
    it('fines a registered business through bill:create', function()
        assert_eq(GovApps.Fines.issue(CLERK, { target = 'business', businessId = 'store:none', amount = 500, reason = 'r' }).error, 'business_not_found')
        local res = GovApps.Fines.issue(CLERK, { target = 'business', businessId = 'store:corner', amount = 500, reason = 'Blocking the road' })
        assert_true(res.ok, tostring(res.error))
        local n, data = called('bill:create')
        assert_eq(n, 1)
        assert_eq(data.targetType, 'business')
        assert_eq(data.targetId, 'store:corner')
        assert_eq(data.billType, 'fine')
    end)
    it('waives only open bills, with a reason, through bill:waive', function()
        assert_eq(GovApps.Fines.waive(CLERK, { billId = 8, reason = 'x' }).error, 'not_open')
        assert_eq(GovApps.Fines.waive(CLERK, { billId = 7 }).error, 'reason_required')
        assert_eq(GovApps.Fines.waive(UTIL, { billId = 7, reason = 'x' }).error, 'no_permission')
        assert_eq(called('bill:waive'), 0)
        assert_true(GovApps.Fines.waive(CLERK, { billId = 7, reason = 'Issued in error' }).ok)
        local n, data = called('bill:waive')
        assert_eq(n, 1)
        assert_eq(data.billId, 7)
    end)
end)

describe('Inspections', function()
    it('files only at the business, with the businesses permission', function()
        assert_eq(GovApps.Inspections.file(CLERK, { businessId = 'store:corner', result = 'compliant' }).error, 'no_permission')
        assert_eq(GovApps.Inspections.file(DEPUTY, { businessId = 'store:nowhere', result = 'compliant' }).error, 'no_business_location')
        Mock.coords[DEPUTY] = SHOP + vector3(200.0, 0.0, 0.0)
        assert_eq(GovApps.Inspections.file(DEPUTY, { businessId = 'store:corner', result = 'compliant' }).error, 'too_far')
        Mock.coords[DEPUTY] = SHOP
        assert_eq(GovApps.Inspections.file(DEPUTY, { businessId = 'store:corner', result = 'closed' }).error, 'invalid_result')
        assert_eq(GovApps.Inspections.file(DEPUTY, { businessId = 'store:corner', result = 'flagged' }).error, 'findings_required')
        assert_eq(#inspections, 0)
        local res = GovApps.Inspections.file(DEPUTY, { businessId = 'store:corner', result = 'flagged', findings = 'Mould', followUpDays = 99 })
        assert_true(res.ok, tostring(res.error))
        assert_eq(#inspections, 1)
        assert_eq(inspections[1][1], 'store:corner')
        assert_eq(inspections[1][2], 'flagged')
        assert_eq(inspections[1][4], 'DEP1')
        assert_eq(res.followUpDays, 30, 'follow-up capped')
    end)
end)

describe('Business Setup', function()
    it('approves a slot through premises:slot:approve only at the business', function()
        Mock.coords[DEPUTY] = SHOP + vector3(300.0, 0.0, 0.0)
        assert_eq(GovApps.Setup.approveSlot(DEPUTY, { businessId = 'store:corner', slotType = 'fridge' }).error, 'too_far')
        assert_eq(called('premises:slot:approve'), 0)
        assert_eq(GovApps.Setup.approveSlot(CLERK, { businessId = 'store:corner', slotType = 'fridge' }).error, 'no_permission')
        Mock.coords[DEPUTY] = SHOP + vector3(2.0, 0.0, 0.0)
        local res = GovApps.Setup.approveSlot(DEPUTY, { businessId = 'store:corner', slotType = 'fridge', label = 'Back' })
        assert_true(res.ok, tostring(res.error))
        local n, data = called('premises:slot:approve')
        assert_eq(n, 1)
        assert_eq(data.slotType, 'fridge')
        assert_true(slots[res.slotId], 'the real handler stored the slot')
    end)
    it('sets the delivery zone at the official\'s position, never one the tablet sends', function()
        local seen
        local realSet = DeliveryZones.Set
        DeliveryZones.Set = function(scope, ref, pos, opts) seen = { scope = scope, ref = ref, pos = pos } return true, 9 end
        Mock.coords[DEPUTY] = SHOP + vector3(3.0, 4.0, 0.0)
        local res = GovApps.Setup.setZone(DEPUTY, { businessId = 'store:corner', x = 9999, y = 9999, z = 9999 })
        DeliveryZones.Set = realSet
        assert_true(res.ok, tostring(res.error))
        assert_eq(seen.scope, 'business')
        assert_eq(seen.pos.x, SHOP.x + 3.0)
        assert_eq(seen.pos.heading, 45.0)
    end)
    it('sets the registry location through business:updateLocation', function()
        assert_true(GovApps.Setup.setLocation(DEPUTY, { businessId = 'store:corner' }).ok)
        local n, data = called('business:updateLocation')
        assert_eq(n, 1)
        assert_eq(data.locationX, SHOP.x)
    end)
end)

describe('Announcements and City Budget', function()
    it('posting needs the announcement permission and runs announcement:create', function()
        assert_eq(GovApps.Announcements.create(CLERK, { title = 'Hi', body = 'x' }).error, 'no_permission')
        assert_eq(GovApps.Announcements.create(MAYOR, { title = '', body = 'x' }).error, 'missing_fields')
        assert_eq(called('announcement:create'), 0)
        local res = GovApps.Announcements.create(MAYOR, { title = 'Road works', body = 'Vinewood Blvd closed', priority = 'loud', days = 90 })
        assert_true(res.ok, tostring(res.error))
        local n, data = called('announcement:create')
        assert_eq(n, 1)
        assert_eq(data.priority, 'normal', 'unknown priority')
        assert_eq(data.duration, 30 * 86400, 'duration capped')
        on('SELECT 1 FROM pf_gov_announcements', function() return 1 end)
        assert_true(GovApps.Announcements.delete(MAYOR, { id = 4 }).ok)
        assert_eq(called('announcement:delete'), 1)
    end)
    it('the budget is a read-only overview', function()
        function GetAllBudgetDetails() return { { department = 'police', approved_monthly_budget = 1000, society_balance = 500, spent_this_month = 20, budget_status = 'Tight' } } end
        function GetInfrastructureOverview() return { month_key = '2026-10', departments = { police = { condition_percent = 90 } }, districts = { downtown = { power_stage = 3, water_stage = 1, blackout = true } } } end
        function GetTreasuryBalance() return 12345 end
        function HasDistrictWater() return true end
        function GetDistrictWaterPressure() return 100 end
        local res = GovApps.Budget.overview(UTIL)
        assert_true(res.ok)
        assert_eq(res.treasury, 12345)
        assert_eq(res.departments[1].label, 'Police Department')
        assert_eq(res.districts[1].label, 'Downtown')
        assert_true(res.districts[1].blackout)
        assert_eq(GovApps.get, nil)
        local budget = GovApps.Get('govbudget').handlers
        for name in pairs(budget) do assert_eq(name, 'overview', 'no write methods') end
    end)
end)

describe('business request flow', function()
    local SPOT = SHOP + vector3(10.0, 5.0, 0.0)
    it('registers a completion check for every government request kind', function()
        assert_true(GovRequests.RegisterHandlers())
        for _, kind in ipairs({ 'gov.request.slot', 'gov.request.inspection', 'gov.request.license', 'gov.request.delivery_zone' }) do
            assert_true(FS.handlers[kind] ~= nil and type(FS.handlers[kind].canComplete) == 'function', kind)
        end
    end)
    it('a slot request completes only after an approval at the recorded spot', function()
        resetServices()
        Mock.coords[OWNER] = SPOT
        local sub = GovRequests.BusinessHandlers.requestSlot(OWNER, { businessId = 'store:corner', slotType = 'shelf' })
        assert_true(sub.ok, tostring(sub.error))
        local req = FS.reqs[sub.id]
        assert_eq(req.from.type, 'business')
        assert_eq(req.ref.id, 'store:corner#shelf')
        assert_eq(rows[sub.id].x, SPOT.x)
        -- completing from Dispatch without the approval does nothing
        assert_true(GovRequests.GovHandlers.accept(DEPUTY, { id = sub.id }).ok)
        local early = Mock.exportsByResource['pf-services'].CompleteRequest(nil, DEPUTY, sub.id, {})
        assert_eq(early.error, 'not_approved')
        -- away from the spot: refused, nothing created
        Mock.coords[DEPUTY] = SHOP
        assert_eq(GovRequests.GovHandlers.approve(DEPUTY, { id = sub.id }).error, 'too_far')
        assert_eq(called('premises:slot:approve'), 0)
        assert_eq(req.status, 'accepted')
        -- at the spot: the real slot handler runs and the request completes
        Mock.coords[DEPUTY] = SPOT + vector3(1.0, 0.0, 0.0)
        local res = GovRequests.GovHandlers.approve(DEPUTY, { id = sub.id, note = 'ok' })
        assert_true(res.ok, tostring(res.error))
        assert_eq(called('premises:slot:approve'), 1)
        assert_eq(req.status, 'completed')
        assert_eq(rows[sub.id].decision, 'approved')
    end)
    it('another official cannot decide a request someone else took', function()
        resetServices()
        Mock.coords[OWNER] = SPOT
        local sub = GovRequests.BusinessHandlers.requestDeliveryZone(OWNER, { businessId = 'store:corner' })
        assert_true(GovRequests.GovHandlers.accept(DEPUTY, { id = sub.id }).ok)
        assert_eq(GovRequests.GovHandlers.approve(MAYOR, { id = sub.id }).error, 'not_yours')
        assert_eq(GovRequests.GovHandlers.deny(MAYOR, { id = sub.id, note = 'no' }).error, 'not_yours')
    end)
    it('licenses need the licenses permission and go through IssueLicense', function()
        resetServices()
        local sub = GovRequests.BusinessHandlers.requestLicense(OWNER, { businessId = 'store:corner', licenseType = 'general_business' })
        assert_true(sub.ok, tostring(sub.error))
        assert_eq(GovRequests.GovHandlers.approve(UTIL, { id = sub.id }).error, 'no_permission')
        assert_eq(#licenses, 0)
        on("SELECT 1 FROM pf_gov_licenses WHERE id = ?", function() return 1 end)
        local res = GovRequests.GovHandlers.approve(CLERK, { id = sub.id })
        assert_true(res.ok, tostring(res.error))
        assert_eq(#licenses, 1)
        assert_eq(licenses[1][1], 'general_business')
        assert_eq(licenses[1][3], 'store:corner')
    end)
    it('a denial needs a note and closes the request; strangers cannot ask', function()
        resetServices()
        Mock.coords[OWNER] = SPOT
        local sub = GovRequests.BusinessHandlers.requestSlot(OWNER, { businessId = 'store:corner', slotType = 'locker' })
        assert_eq(GovRequests.GovHandlers.deny(DEPUTY, { id = sub.id }).error, 'note_required')
        assert_true(GovRequests.GovHandlers.deny(DEPUTY, { id = sub.id, note = 'Fire exit' }).ok)
        assert_eq(FS.reqs[sub.id].status, 'cancelled')
        assert_eq(rows[sub.id].decision, 'denied')
        DB.handlers = {}
        Mock.clock = Mock.clock + 100
        assert_eq(GovRequests.BusinessHandlers.requestSlot(CIV, { businessId = 'store:corner', slotType = 'locker' }).error, 'not_owner')
    end)
end)
