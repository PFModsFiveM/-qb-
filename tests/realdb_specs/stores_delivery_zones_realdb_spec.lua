-- pf-stores' supply order service on a real database: where a trucking order is delivered. A
-- business's own delivery point wins; without one the government default delivery zone (the
-- business's own, else its district's) is used; with neither, or with trucking switched off, there
-- is no delivery. Also: buying a store reaches the city timeline once.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function GetResourceState(name) return name == 'pf-trucking' and 'missing' or 'started' end
function GetCurrentResourceName() return 'pfm-banking' end
function SetEntityRotation() end
function FreezeEntityPosition() end
function GetEntityHeading() return 0.0 end
function SaveResourceFile() end
function LoadResourceFile() return nil end
function RegisterCommand() end

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
RealDB.exec('[pfscripts]/pf-stores/install.sql')
RealDB.exec('[pfscripts]/pf-government/sql/install.sql')

local merged = {}
local function loadConfig(path)
    Config = nil
    load_resource(path)
    for k, v in pairs(Config or {}) do if merged[k] == nil then merged[k] = v end end
end
loadConfig('pfm-banking/config.lua')
Config = merged
local PICK = { label = 'Warehouse', coords = vector4(0.0, 0.0, 0.0, 0.0) }
local ITEMS = { { name = 'lockpick', price = 50, cost = 20, maxQuantity = 5 } }
Config.Stores = {
    corner = { id = 'corner', label = 'Corner Store', type = 'purchasable', storefront = { enabled = true, items = ITEMS },
        purchase = { price = 1000, moneyType = 'bank', coords = vector3(10.0, 10.0, 10.0) },
        trucking = { enabled = true, payoutRate = 0.12, payoutMin = 50, pickup = PICK, dropoff = { label = 'Corner Store', coords = vector3(3000.0, 0.0, 0.0) } } },
    nodrop = { id = 'nodrop', label = 'No Drop', type = 'purchasable', storefront = { enabled = true, items = ITEMS },
        trucking = { enabled = true, payoutRate = 0.12, payoutMin = 50, pickup = PICK } },
    bare = { id = 'bare', label = 'Bare Store', type = 'purchasable', storefront = { enabled = true, items = ITEMS } },
    off = { id = 'off', label = 'Off Store', type = 'purchasable', storefront = { enabled = true, items = ITEMS },
        trucking = { enabled = false, pickup = PICK } },
}
Config.SupplyChain = { PlayerSuppliers = false, AIMarkup = 0.15, DriverPrioritySeconds = 120, DriverMaxSeconds = 1800, AIDeliverySeconds = 300 }
-- the parts of pf-government's config its delivery zones read
Config.FrameworkResourceName = 'pfm-core'
Config.Infrastructure = { Districts = { industrial = { priority = 6, label = 'Industrial Zone' } } }
QBCoreMock.Shared.Items.lockpick.weight = 10

load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')
load_resource('[pfscripts]/pf-stores/server_orders.lua')
load_resource('[pfscripts]/pf-stores/server.lua')
Mock.exportsByResource['pfm-banking'] = Mock.exportsByResource['__self']
Mock.exportsByResource['pf-stores'] = Mock.exportsByResource['__self']

-- pf-government's real delivery zones (core helpers, migrations, zone store)
function GetCurrentResourceName() return 'pf-government' end
load_resource('[pfscripts]/pf-government/server/core.lua')
load_resource('[pfscripts]/pf-government/server/schema.lua')
load_resource('[pfscripts]/pf-government/server/delivery_zones.lua')
function LogAudit() end
function DebugPrint() end
assert(GovSchema.Ensure(), 'government migrations')
Mock.exportsByResource['pf-government'] = {
    GetDeliveryZone = function(_, id) return DeliveryZones.Get(id) end,
    RegisterBusinessWithGovernment = function() return true end,
    CanBusinessTrade = function() return true end,
}
local events = {}
Mock.exportsByResource['pf-services'] = { Emit = function(_, kind, data, opts) events[#events + 1] = { kind = kind, data = data, opts = opts } return #events end }
function GetCurrentResourceName() return 'pf-stores' end

local L, O = PFLedger, PFOrders
assert(L.Start(), 'ledger start')
assert(O.Start(), 'order service start')
for _, id in ipairs({ 'corner', 'nodrop', 'bare', 'off' }) do
    MySQL.query.await("INSERT INTO pf_stores (store_id, label, store_type, owner_citizenid, purchased_at) VALUES (?, ?, 'purchasable', 'OWN1', 1) ON DUPLICATE KEY UPDATE owner_citizenid = 'OWN1'", { id, id })
    MySQL.query.await("INSERT INTO pf_gov_businesses (business_id, business_name, business_type, owner_id) VALUES (?, ?, 'store', 'OWN1')", { 'store:' .. id, id })
    assert(L.EnsureSociety('store_' .. id, 'business'))
    assert(L.Transfer({ from = 'system:test', to = 'society:store_' .. id, amount = 5000, key = L.AutoKey('fund'), kind = 'test' }).ok)
end
local OWNER = 1
local function zone(scope, ref, x, heading)
    assert(DeliveryZones.Set(scope, ref, { x = x, y = 50.0, z = 20.0, heading = heading or 0.0 }, { label = ref .. ' bay', cid = 'GOV1', name = 'Official' }))
end
local function order(storeId)
    return O.Create(OWNER, { kind = 'store', buyerId = storeId, method = 'trucking', cart = { { name = 'lockpick', quantity = 5 } } })
end

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 1000
    Mock.players = {}
    local p = Mock.newPlayer(OWNER, 'OWN1')
    p.PlayerData.job = { name = 'unemployed', grade = { level = 0 } }
    events = {}
end

describe('delivery position precedence', function()
    it('the store\'s own delivery point wins over a government zone', function()
        zone('business', 'store:corner', 1234.0)
        local route = O.Route('store', 'corner')
        assert_eq(route.source, 'business')
        assert_eq(route.dropoff.coords.x, 3000.0)
    end)
    it('without a delivery point and without a zone there is no trucking delivery', function()
        assert_eq(O.Route('store', 'nodrop'), nil)
        local res = order('nodrop')
        assert_false(res.ok)
        assert_eq(res.error, 'delivery_locations_not_configured')
    end)
    it('without a delivery point the business\'s government zone is used, with the store\'s own pickup', function()
        zone('business', 'store:nodrop', 777.0, 90.0)
        local route = O.Route('store', 'nodrop')
        assert_eq(route.source, 'government_zone')
        assert_eq(route.dropoff.coords.x, 777.0)
        assert_eq(route.unload.coords.w, 90.0)
        assert_eq(route.pickup.label, 'Warehouse')
        local res = order('nodrop')
        assert_true(res.ok, tostring(res.error))
        local row = O.Get(res.data.orderId)
        assert_eq(row.method, 'trucking')
        assert_true((tonumber(row.freight_payout) or 0) > 0, 'freight from the store trucking settings')
    end)
    it('a store with no trucking settings at all uses the district zone and the default pickup', function()
        assert_eq(O.Route('store', 'bare'), nil)
        zone('district', 'industrial', 4321.0)
        assert(DeliveryZones.SetBusinessDistrict('store:bare', 'industrial'))
        local route = O.Route('store', 'bare')
        assert_eq(route.source, 'district_zone')
        assert_eq(route.dropoff.coords.x, 4321.0)
        assert_eq(route.pickup.label, 'Wholesale Distributor')
        assert_true(order('bare').ok)
    end)
    it('a store with trucking switched off gets no delivery, zone or not', function()
        zone('business', 'store:off', 999.0)
        assert_eq(O.Route('store', 'off'), nil)
        assert_eq(order('off').error, 'delivery_locations_not_configured')
    end)
    it('the export answers the same', function()
        local r = exports['pf-stores']:GetDeliveryRoute('store', 'nodrop')
        assert_eq(r.source, 'government_zone')
    end)
end)

describe('buying a store', function()
    it('is recorded on the city timeline once, without the buyer\'s citizen id in the data', function()
        MySQL.query.await("UPDATE pf_stores SET owner_citizenid = NULL WHERE store_id = 'corner'")
        local buyer = Mock.newPlayer(2, 'BUY1')
        buyer.PlayerData.charinfo = { firstname = 'Bea', lastname = 'Buyer' }
        assert(L.Transfer({ from = 'system:test', to = 'player:BUY1:bank', amount = 2000, key = L.AutoKey('fundbuyer'), kind = 'test' }).ok)
        Mock.coords[2] = vector3(10.0, 10.0, 10.0)
        local res = Mock.callCallback('pf-stores:server:purchaseStore', 2, 'corner')
        assert_true(res.ok, tostring(res.error))
        assert_eq(#events, 1)
        assert_eq(events[1].kind, 'business.store.purchased')
        assert_eq(events[1].data.store, 'Corner Store')
        assert_eq(events[1].data.owner, 'Bea Buyer')
        assert_eq(events[1].data.price, 1000)
        assert_eq(events[1].opts.actor, 'BUY1')
        local again = Mock.callCallback('pf-stores:server:purchaseStore', 2, 'corner')
        assert_false(again.ok)
        assert_eq(#events, 1, 'no event for a refused purchase')
    end)
end)
