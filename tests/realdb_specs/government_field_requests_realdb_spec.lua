-- pf-government field apps on a real database with the real pf-services request service: a business
-- asks City Hall for an equipment slot, a delivery zone, a license and an inspection from the City
-- Hall Requests app; officials approve on site (slots and zones where the business recorded them) or
-- deny with a note; a request only completes when the approval really happened; delivery zones fall
-- back to the district zone.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
local states = { ['pfm-cityhall'] = 'missing', ['pf-devices'] = 'missing' }
function GetResourceState(name) return states[name] or 'started' end
vec3 = vec3 or vector3
vec4 = vec4 or vector4
local headings = {}
function GetEntityHeading(ped) return headings[ped] or 0.0 end

-- the bank (license fees are billed, slots and zones are free)
RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
function GetCurrentResourceName() return 'pfm-banking' end
Config = nil
load_resource('pfm-banking/config.lua')
load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')
Mock.exportsByResource['pfm-banking'] = Mock.exportsByResource['__self']
assert(PFLedger.Start(), 'ledger start')

-- pf-government
RealDB.exec('[pfscripts]/pf-government/sql/install.sql')
function GetCurrentResourceName() return 'pf-government' end
QBCoreMock.Shared.Jobs = { government = { label = 'Government' } }
Config = nil
load_resource('pfm-banking/payouts.lua')
for _, f in ipairs({ 'config.lua', 'server/core.lua', 'server/schema.lua', 'server/treasury.lua', 'server/taxes.lua', 'server/utilities.lua',
    'server/bills.lua', 'server/businesses.lua', 'server/audit.lua', 'server/licenses.lua', 'server/integrations.lua',
    'server/staff.lua', 'server/callbacks.lua', 'server/premises.lua', 'server/delivery_zones.lua',
    'server/apps/common.lua', 'server/apps/fines.lua', 'server/apps/inspections.lua', 'server/apps/requests.lua',
    'server/apps/budget.lua', 'server/apps/announcements.lua', 'server/apps/setup.lua' }) do
    load_resource('[pfscripts]/pf-government/' .. f)
end
function NotifyGovernment() end
function IsGovernmentEmployee(src) local P = QBCoreMock.Functions.GetPlayer(src) return P ~= nil and P.PlayerData.job.name == Config.GovernmentJob end
function DebugPrint() end
Mock.exportsByResource['pf-government'] = Mock.exportsByResource['__self']
InitializeTreasury()
InitializeTaxes()
InitializeBusinesses()
assert(GovSchema.Ensure(), 'government migrations')
assert(GovSchema.Ensure(), 'migrations are rerun-safe')

-- the real pf-services request service (its config joins the shared Config table)
load_resource('[pfscripts]/pf-services/shared/catalog.lua')
load_resource('[pfscripts]/pf-services/shared/config.lua')
load_resource('[pfscripts]/pf-services/server/schema.lua')
load_resource('[pfscripts]/pf-services/server/events.lua')
load_resource('[pfscripts]/pf-services/server/requests.lua')
assert(RunMigrations('pf-services', PFServices.Migrations))
local events = {}
PFServices.OnEvent(function(ev) events[#events + 1] = ev end)
local S = PFServices
Mock.exportsByResource['pf-services'] = {
    Emit = function(_, kind, data, opts) local ev = S.Emit(kind, data, opts) return ev and ev.id end,
    CreateRequest = function(_, o) return S.CreateRequest(o) end,
    GetRequest = function(_, id) return S.GetRequest(id) end,
    FindOpenByRef = function(_, t, id) return S.FindOpenByRef(t, id) end,
    AcceptRequest = function(_, src, id) return S.AcceptRequest(src, id) end,
    CompleteRequest = function(_, src, id, proof) return S.CompleteRequest(src, id, proof) end,
    CancelRequest = function(_, src, id, reason) return S.CancelRequest(src, id, reason) end,
    CloseByRef = function(_, t, id, st, reason) return S.CloseByRef(t, id, st, reason) end,
    ListForJob = function(_, job, closed) return S.ListForJob(job, closed) end,
    RegisterRequestHandler = function(_, kind, h) return S.RegisterRequestHandler(kind, h, 'pf-government') end,
}
assert(GovRequests.RegisterHandlers(), 'request handlers registered')

local STAFF, CLERK, OWNER, STRANGER = 1, 2, 3, 4
local BIZ = 'store:corner'
local SHOP = vector3(100.0, 200.0, 30.0)
local SPOT = vector3(110.0, 207.0, 30.0)       -- where the owner asks for the slot (inside the shop)
local BAY = vector3(112.0, 190.0, 30.0)        -- where the owner asks for the delivery bay
RegisterBusiness(BIZ, 'Corner Store', 'store', 'OWN1', 'Olive Owner', 'society:store_corner')
MySQL.update.await('UPDATE pf_gov_businesses SET location_x = ?, location_y = ?, location_z = ? WHERE business_id = ?', { SHOP.x, SHOP.y, SHOP.z, BIZ })

local B, G = GovRequests.BusinessHandlers, GovRequests.GovHandlers

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    Mock.clock = Mock.clock + 100          -- past the request cooldown
    local staff = Mock.newPlayer(STAFF, 'GOV1')
    staff.PlayerData.job = { name = 'government', grade = { level = 3 }, onduty = true }
    local clerk = Mock.newPlayer(CLERK, 'CLK1')
    clerk.PlayerData.job = { name = 'government', grade = { level = 1 }, onduty = true }
    Mock.newPlayer(OWNER, 'OWN1')
    Mock.newPlayer(STRANGER, 'STR1')
    Mock.coords = { [STAFF] = SHOP, [CLERK] = SHOP, [OWNER] = SHOP, [STRANGER] = SHOP }
    headings = {}
    events = {}
end

local function row(id) return MySQL.single.await('SELECT * FROM pf_gov_business_requests WHERE request_id = ?', { id }) end

describe('City Hall Requests (business side)', function()
    it('only someone who manages the business may ask, and the app is only theirs', function()
        assert_true(B.__access(OWNER))
        assert_false(B.__access(STRANGER))
        local res = B.requestSlot(STRANGER, { businessId = BIZ, slotType = 'fridge' })
        assert_eq(res.error, 'not_owner')
        local o = B.overview(OWNER)
        assert_eq(#o.businesses, 1)
        assert_eq(o.businesses[1].id, BIZ)
    end)
    it('a slot request records where the owner stands; the same ask twice is one request', function()
        Mock.coords[OWNER] = SPOT
        headings[OWNER] = 180.0
        local res = B.requestSlot(OWNER, { businessId = BIZ, slotType = 'fridge', note = 'Back room' })
        assert_true(res.ok, tostring(res.error))
        local r = row(res.id)
        assert_eq(r.kind, 'gov.request.slot')
        assert_eq(r.subject, 'fridge')
        assert_near(r.x, SPOT.x, 0.001) assert_near(r.y, SPOT.y, 0.001)
        assert_eq(r.heading, 180.0)
        local req = S.GetRequest(res.id)
        assert_eq(req.from.type, 'business')
        assert_eq(req.from.id, BIZ)
        assert_eq(req.requester, 'OWN1')
        Mock.clock = Mock.clock + 100
        local again = B.requestSlot(OWNER, { businessId = BIZ, slotType = 'fridge' })
        assert_eq(again.error, 'already_requested')
        assert_eq(again.id, res.id)
        assert_eq(B.requestSlot(OWNER, { businessId = BIZ, slotType = 'helipad' }).error, 'invalid_slot_type')
    end)
    it('a spot far from the business is refused', function()
        Mock.coords[OWNER] = vector3(2000.0, 0.0, 30.0)
        assert_eq(B.requestDeliveryZone(OWNER, { businessId = BIZ }).error, 'too_far')
    end)
end)

describe('Business Requests (government side)', function()
    local slotReq
    it('lists the request for officials with the spot', function()
        local list = G.list(STAFF)
        assert_true(list.ok)
        for _, r in ipairs(list.requests) do if r.kind == 'slot' then slotReq = r end end
        assert_true(slotReq ~= nil, 'slot request listed')
        assert_eq(slotReq.business, 'Corner Store')
        assert_eq(slotReq.subject, 'fridge')
        assert_true(slotReq.canDecide)
        local wp = G.waypoint(STAFF, { id = slotReq.id })
        assert_near(wp.coords.x, SPOT.x, 0.001)
    end)
    it('a request cannot be completed before the approval happened', function()
        assert_true(G.accept(STAFF, { id = slotReq.id }).ok)
        local res = S.CompleteRequest(STAFF, slotReq.id, {})
        assert_false(res.ok)
        assert_eq(res.error, 'not_approved')
        assert_eq(S.GetRequest(slotReq.id).status, 'accepted')
    end)
    it('approving away from the recorded spot is refused and creates nothing', function()
        Mock.coords[STAFF] = SHOP
        local res = G.approve(STAFF, { id = slotReq.id })
        assert_eq(res.error, 'too_far')
        assert_eq(tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM pf_gov_premises_slots WHERE business_id = ?', { BIZ })), 0)
    end)
    it('approving at the spot creates the slot there and completes the request', function()
        Mock.coords[STAFF] = SPOT + vector3(0.5, 0.0, 0.0)
        headings[STAFF] = 90.0
        local res = G.approve(STAFF, { id = slotReq.id, note = 'Approved: back fridge' })
        assert_true(res.ok, tostring(res.error))
        local slot = MySQL.single.await('SELECT * FROM pf_gov_premises_slots WHERE business_id = ? AND active = 1', { BIZ })
        assert_eq(slot.slot_type, 'fridge')
        assert_near(slot.x, SPOT.x + 0.5, 0.001)
        assert_eq(slot.approved_by, 'GOV1')
        assert_eq(S.GetRequest(slotReq.id).status, 'completed')
        local r = row(slotReq.id)
        assert_eq(r.decision, 'approved')
        assert_eq(tonumber(r.outcome_ref), tonumber(slot.id))
        assert_eq(r.status, 'completed')
        -- the business sees the answer
        local mine = B.overview(OWNER).requests
        assert_eq(mine[1].status, 'completed')
        assert_eq(G.approve(STAFF, { id = slotReq.id }).error, 'closed', 'approved once')
    end)
    it('a delivery zone request is approved at the bay; the zone is where the official stands', function()
        Mock.coords[OWNER] = BAY
        local res = B.requestDeliveryZone(OWNER, { businessId = BIZ, note = 'Loading door' })
        assert_true(res.ok, tostring(res.error))
        Mock.coords[STAFF] = BAY + vector3(1.0, 1.0, 0.0)
        headings[STAFF] = 270.0
        local ok = G.approve(STAFF, { id = res.id, note = 'Rear bay' })
        assert_true(ok.ok, tostring(ok.error))
        local zone = exports['pf-government']:GetDeliveryZone(BIZ)
        assert_eq(zone.scope, 'business')
        assert_near(zone.x, BAY.x + 1.0, 0.001)
        assert_eq(zone.heading, 270.0)
        assert_eq(zone.requestId, res.id)
        assert_eq(S.GetRequest(res.id).status, 'completed')
    end)
    it('a license request needs the licenses permission and goes through the license logic', function()
        local res = B.requestLicense(OWNER, { businessId = BIZ, licenseType = 'general_business' })
        assert_true(res.ok, tostring(res.error))
        local ok = G.approve(CLERK, { id = res.id })
        assert_true(ok.ok, tostring(ok.error))
        local lic = MySQL.single.await("SELECT * FROM pf_gov_licenses WHERE owner_type = 'business' AND owner_id = ? AND license_type = 'general_business'", { BIZ })
        assert_eq(lic.status, 'active')
        assert_eq(lic.issued_by, 'CLK1')
        assert_eq(MySQL.scalar.await('SELECT license_status FROM pf_gov_businesses WHERE business_id = ?', { BIZ }), 'active')
        local fee = MySQL.single.await("SELECT * FROM pf_gov_bills WHERE target_type = 'business' AND target_id = ? AND bill_type = 'license'", { BIZ })
        assert_eq(tonumber(fee.amount), 2500)
        Mock.clock = Mock.clock + 100
        assert_eq(B.requestLicense(OWNER, { businessId = BIZ, licenseType = 'general_business' }).error, 'license_active')
    end)
    it('a clerk cannot approve slots; a denial needs a note and tells the business', function()
        Mock.coords[OWNER] = SPOT + vector3(5.0, 0.0, 0.0)
        local res = B.requestSlot(OWNER, { businessId = BIZ, slotType = 'shelf' })
        assert_true(res.ok, tostring(res.error))
        assert_eq(G.approve(CLERK, { id = res.id }).error, 'no_permission')
        assert_eq(G.deny(STAFF, { id = res.id }).error, 'note_required')
        assert_true(G.deny(STAFF, { id = res.id, note = 'Blocks the fire exit' }).ok)
        assert_eq(S.GetRequest(res.id).status, 'cancelled')
        local r = row(res.id)
        assert_eq(r.decision, 'denied')
        assert_eq(r.decision_note, 'Blocks the fire exit')
        local mine = B.overview(OWNER).requests
        assert_eq(mine[1].decisionNote, 'Blocks the fire exit')
    end)
    it('an inspection request is completed by filing the inspection at the business', function()
        local res = B.requestInspection(OWNER, { businessId = BIZ, note = 'Please certify us' })
        assert_true(res.ok, tostring(res.error))
        assert_eq(G.approve(STAFF, { id = res.id }).error, 'file_inspection')
        Mock.coords[STAFF] = vector3(900.0, 0.0, 0.0)
        assert_eq(GovApps.Inspections.file(STAFF, { businessId = BIZ, result = 'compliant', findings = 'Clean' }).error, 'too_far')
        Mock.coords[STAFF] = SHOP
        local filed = GovApps.Inspections.file(STAFF, { businessId = BIZ, result = 'compliant', findings = 'Clean' })
        assert_true(filed.ok, tostring(filed.error))
        assert_true(filed.requestCompleted)
        assert_eq(S.GetRequest(res.id).status, 'completed')
        assert_eq(tonumber(row(res.id).outcome_ref), filed.inspectionId)
    end)
    it('a failed inspection books a follow-up and shows in the due list', function()
        local filed = GovApps.Inspections.file(STAFF, { businessId = BIZ, result = 'non_compliant', findings = 'Rats', followUpDays = 2 })
        assert_true(filed.ok, tostring(filed.error))
        local ins = MySQL.single.await('SELECT follow_up_at > NOW() AS later FROM pf_gov_business_inspections WHERE id = ?', { filed.inspectionId })
        assert_eq(tonumber(ins.later), 1)
        local list = GovApps.Inspections.list(STAFF)
        assert_eq(list.businesses[1].id, BIZ)
        assert_eq(list.businesses[1].lastResult, 'non_compliant')
        MySQL.update.await('UPDATE pf_gov_business_inspections SET follow_up_at = NOW() - INTERVAL 1 HOUR WHERE id = ?', { filed.inspectionId })
        assert_eq(GovApps.Inspections.list(STAFF).businesses[1].state, 'follow_up')
    end)
end)

describe('delivery zones', function()
    it('a business without its own zone uses its district zone', function()
        RegisterBusiness('store:far', 'Far Store', 'store', 'OWN2', 'Other', 'society:store_far')
        assert_eq(exports['pf-government']:GetDeliveryZone('store:far'), nil)
        Mock.coords[STAFF] = vector3(-500.0, -500.0, 20.0)
        assert_true(GovApps.Setup.setDistrictZone(STAFF, { district = 'industrial', label = 'Port gate' }).ok)
        assert_false(GovApps.Setup.setDistrictZone(STAFF, { district = 'moon' }).ok)
        assert_true(GovApps.Setup.setDistrict(STAFF, { businessId = 'store:far', district = 'industrial' }).ok)
        local zone = exports['pf-government']:GetDeliveryZone('store:far')
        assert_eq(zone.scope, 'district')
        assert_eq(zone.district, 'industrial')
        assert_eq(zone.label, 'Port gate')
        -- its own zone wins over the district's
        Mock.coords[STAFF] = vector3(-510.0, -500.0, 20.0)
        assert_true(GovApps.Setup.setZone(STAFF, { businessId = 'store:far' }).ok)
        assert_eq(exports['pf-government']:GetDeliveryZone('store:far').scope, 'business')
        assert_true(GovApps.Setup.clearZone(STAFF, { businessId = 'store:far' }).ok)
        assert_eq(exports['pf-government']:GetDeliveryZone('store:far').scope, 'district')
    end)
    it('the zone of a business in setup is only set at the business', function()
        Mock.coords[STAFF] = vector3(3000.0, 0.0, 0.0)
        assert_eq(GovApps.Setup.setZone(STAFF, { businessId = BIZ }).error, 'too_far')
        assert_eq(GovApps.Setup.setZone(CLERK, { businessId = BIZ }).error, 'no_permission')
    end)
end)

describe('city events from these decisions', function()
    it('a failed inspection reaches the timeline with public fields only', function()
        Mock.coords[STAFF] = SHOP
        GovApps.Inspections.file(STAFF, { businessId = BIZ, result = 'flagged', findings = 'No hot water' })
        local found
        for _, ev in ipairs(events) do if ev.kind == 'gov.inspection.failed' then found = ev end end
        assert_true(found ~= nil, 'emitted')
        assert_eq(found.data.business, 'Corner Store')
        assert_eq(found.data.findings, 'No hot water')
        assert_eq(found.actor, 'GOV1')
        local stored = MySQL.single.await("SELECT * FROM pf_city_events WHERE kind = 'gov.inspection.failed' ORDER BY id DESC LIMIT 1")
        assert_true(stored ~= nil, 'on the real timeline')
        assert_true(not tostring(stored.data):find('GOV1'), 'no citizen id in the public data')
    end)
end)
