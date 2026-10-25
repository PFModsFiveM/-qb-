-- pf-computer's Order Supplies app in store mode, on the shared supply order service, on a real database.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function GetResourceState() return 'started' end
function GetCurrentResourceName() return 'pfm-banking' end
function SetEntityRotation() end
function FreezeEntityPosition() end
function GetEntityHeading() return 0.0 end
function SaveResourceFile() end
function LoadResourceFile() return nil end
function RegisterCommand() end

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
RealDB.exec('pfm-inventory/qb-inventory.sql')
RealDB.exec('[pfscripts]/pf-stores/install.sql')

-- each resource has its own Config in FiveM; here they share one table (no conflicting keys)
local merged = {}
local function loadConfig(path)
    Config = nil
    load_resource(path)
    for k, v in pairs(Config or {}) do if merged[k] == nil then merged[k] = v end end
end
loadConfig('pfm-banking/config.lua')
loadConfig('pfm-inventory/config/config.lua')
loadConfig('pfm-inventory/config/freshness.lua')
loadConfig('[pfscripts]/pf-trucking/config.lua')
loadConfig('pfm-worldobjects/config.lua')
loadConfig('[pfscripts]/pf-computer/config/config.lua')
Config = merged
Config.Stores = {
    corner = {
        id = 'corner', label = 'Corner Store', type = 'purchasable',
        storefront = { enabled = true, items = { { name = 'lockpick', price = 50, cost = 20, maxQuantity = 5 }, { name = 'sandwich', price = 10, cost = 4, maxQuantity = 20 } } },
        trucking = {
            enabled = true, payoutRate = 0.12, payoutMin = 250,
            pickup = { label = 'Warehouse', coords = vector4(0.0, 0.0, 0.0, 0.0) },
            dropoff = { label = 'Corner Store', coords = vector3(3000.0, 0.0, 0.0) },
        },
    },
}
Config.Delivery = { DropoffRadius = 80.0, ReturnRadius = 35.0, MinSeconds = 45, MaxAverageSpeed = 45.0 }
Config.WorkTruck = {
    Enabled = true, RentalFee = 100, PlatePrefix = 'WK', Models = { 'phantom' },
    Depots = { { id = 'depot', label = 'Depot', spawnCoords = vector4(0.0, 0.0, 0.0, 0.0), returnCoords = vector4(5.0, 0.0, 0.0, 0.0) } },
}
Config.NpcJobs = { Enabled = false }
Config.SupplyChain = {
    PlayerSuppliers = true, SupplierOfferSeconds = 60, AIMarkup = 0.15, PlayerSupplierShareOfMarkup = 0.5,
    DriverPrioritySeconds = 120, DriverMaxSeconds = 1800, AIDeliverySeconds = 300, PalletModel = 'prop_boxpile_06b',
}
QBCoreMock.Shared.Items.supply_crate = { name = 'supply_crate', label = 'Supply Crate', weight = 5000, type = 'item', unique = true, useable = false, image = 'cardboard_box.png' }
QBCoreMock.Shared.Items.lockpick.weight = 10
QBCoreMock.Shared.Jobs = {}

load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')
load_resource('pfm-inventory/server/freshness.lua')
load_resource('pfm-inventory/server/main.lua')
load_resource('pfm-inventory/server/functions.lua')
load_resource('pfm-inventory/server/hooks.lua')
load_resource('[pfscripts]/pf-stores/server_orders.lua')
load_resource('[pfscripts]/pf-stores/server.lua')
load_resource('[pfscripts]/pf-trucking/server.lua')
load_resource('pfm-worldobjects/server.lua')
SavedFiles = {}
function SaveResourceFile(_, path, content) SavedFiles[path] = content; return true end
load_resource('[pfscripts]/pf-computer/server/main.lua')
for _, res in ipairs({ 'pfm-banking', 'pfm-inventory', 'pf-stores', 'pf-trucking', 'pfm-worldobjects' }) do
    Mock.exportsByResource[res] = Mock.exportsByResource['__self']
end

-- pf-computer registers its job-business buyer when pf-stores is (re)started
TriggerEvent('onResourceStart', 'pf-stores')

local L, O = PFLedger, PFOrders
local OWNER = 1
assert(L.Start(), 'ledger start')
assert(O.Start(), 'order service start')
MySQL.query.await("INSERT INTO pf_stores (store_id, label, store_type, owner_citizenid, purchased_at) VALUES ('corner', 'Corner Store', 'purchasable', 'OWN1', 1)")

local function society(name) return tonumber(MySQL.scalar.await('SELECT account_balance FROM bank_accounts WHERE account_name = ?', { name })) or 0 end
local function stock(item) return tonumber(MySQL.scalar.await("SELECT stock_cases FROM pf_store_supply_stock WHERE store_id = 'corner' AND supply_name = ?", { item })) or 0 end
local function fundStore(amount)
    assert(L.EnsureSociety('store_corner', 'business'))
    assert(L.Transfer({ from = 'system:test', to = 'society:store_corner', amount = amount, key = L.AutoKey('fund'), kind = 'test' }).ok)
end
local function pc(action, payload)
    Mock.clientEvents = {}
    Mock.gameTimer = Mock.gameTimer + 100000
    Mock.fireNet('pf-computer:server:callback', OWNER, 7, action, payload or {})
    local ev = Mock.clientEventsNamed('pf-computer:client:callback')[1]
    return ev and ev.args[2]
end

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 10000
    Mock.players = {}
    local p = Mock.newPlayer(OWNER, 'OWN1')
    p.PlayerData.money = { cash = 0, bank = 0 }
    p.PlayerData.job = { name = 'unemployed', label = 'Unemployed', isboss = false, grade = { level = 0 } }
end

describe('Order Supplies app, store mode', function()
    it('a pickup order is charged to the store bank account and stocks the store; forged prices are ignored', function()
        fundStore(300)
        local res = pc('business:supplies:orders:create', { fulfillment = 'pickup', items = { { item = 'lockpick', quantity = 5, pricePerCase = 0.01 } } })
        assert_true(res and res.ok, res and tostring(res.error))
        assert_eq(society('store_corner'), 200)                          -- 5 x 20
        assert_eq(stock('lockpick'), 5)
        for _, content in pairs(SavedFiles) do
            assert_true(not tostring(content):find('corner'), 'store data written to the pf-computer data file')
        end
        local list = pc('business:supplies:orders:list')
        assert_eq(list.data[1].status, 'picked_up')
    end)
    it('an unfunded store cannot order', function()
        local res = pc('business:supplies:orders:create', { fulfillment = 'pickup', items = { { item = 'lockpick', quantity = 50 } } })
        assert_false(res.ok)
        assert_eq(res.error, 'insufficient_store_funds')
    end)
    it('a delivery order waits for a trucker and can be cancelled from the app for a full refund', function()
        fundStore(1150)
        local before = society('store_corner')
        local res = pc('business:supplies:orders:create', { fulfillment = 'delivery', items = { { item = 'lockpick', quantity = 50 } } })
        assert_true(res.ok, tostring(res.error))
        assert_eq(society('store_corner'), before - 1150)
        local list = pc('business:supplies:orders:list')
        assert_eq(list.data[1].orderStatus, 'awaiting_delivery')
        assert_true(list.data[1].cancellable)
        assert_true(pc('business:supplies:orders:cancel', { orderId = list.data[1].id }).ok)
        assert_eq(society('store_corner'), before)
        assert_false(pc('business:supplies:orders:cancel', { orderId = list.data[1].id }).ok)
    end)
end)

describe('Order Supplies app, job business mode (shared order service)', function()
    local missions = {}
    local function asMechanicBoss()
        QBCoreMock.Shared.Jobs = QBCoreMock.Shared.Jobs or {}
        QBCoreMock.Shared.Jobs.mechanic = { label = 'Mechanic' }
        Mock.players[OWNER].PlayerData.job = { name = 'mechanic', label = 'Mechanic', isboss = true, onduty = true, grade = { level = 4 } }
        Mock.exportsByResource['pf-mechanicjob'] = {
            GetBusinessConfig = function() return { suppliesCatalog = { items = {
                { item = 'lockpick', label = 'Lockpick', pricePerCase = 50, caseSize = 3 },
                { item = 'water_bottle', label = 'Water', pricePerCase = 10, caseSize = 6 },
            } } } end,
            StartSuppliesPickup = function(_, src, order) missions[#missions + 1] = order return true end,
        }
        Mock.coords[OWNER] = vector3(500.0, 500.0, 30.0)
    end
    local function mechanicBank() return society('mechanic') end
    local function fundMechanic(amount)
        assert(L.EnsureSociety('mechanic', 'job'))
        assert(L.Transfer({ from = 'system:test', to = 'society:mechanic', amount = amount, key = L.AutoKey('fund'), kind = 'test' }).ok)
    end
    local function stashCount(item)
        local inv = exports['pfm-inventory']:GetInventory('bizstash-mechanic')
        local n = 0
        for _, it in pairs(inv and inv.items or {}) do if it.name == item then n = n + it.amount end end
        return n
    end

    it('a pickup order is charged at the catalog price, waits for the pickup run, and lands in the business stock once', function()
        asMechanicBoss()
        fundMechanic(1000)
        local res = pc('business:supplies:orders:create', { mode = 'job', fulfillment = 'pickup', items = { { item = 'lockpick', quantity = 2, pricePerCase = 0.01 }, { item = 'water_bottle', quantity = 1 } } })
        assert_true(res and res.ok, res and tostring(res.error))
        assert_eq(mechanicBank(), 1000 - 2 * 50 - 10)
        local list = pc('business:supplies:orders:list', { mode = 'job' })
        assert_eq(list.data[1].orderStatus, 'ready')
        assert_eq(stashCount('lockpick'), 0, 'not in stock before it is collected')

        local id = list.data[1].id
        assert_true(pc('business:supplies:orders:pickup', { mode = 'job', orderId = id }).ok)
        assert_eq(#missions, 1)
        assert_eq(tonumber(missions[1].id), id)
        TriggerEvent('pf-computer:server:supplies:completeOrder', OWNER, id)
        assert_eq(stashCount('lockpick'), 6)
        assert_eq(stashCount('water_bottle'), 6)
        TriggerEvent('pf-computer:server:supplies:completeOrder', OWNER, id)          -- a repeat adds nothing
        assert_eq(stashCount('lockpick'), 6)
        assert_eq(pc('business:supplies:orders:list', { mode = 'job' }).data[1].status, 'picked_up')
    end)
    it('nothing in the pf-computer data file, and only a boss of that job can order', function()
        asMechanicBoss()
        for _, content in pairs(SavedFiles) do
            assert_true(not tostring(content):find('"businessOrders":{"mechanic"', 1, true), 'job orders written to the data file')
        end
        Mock.players[OWNER].PlayerData.job.isboss = false
        local res = pc('business:supplies:orders:create', { mode = 'job', fulfillment = 'pickup', items = { { item = 'lockpick', quantity = 1 } } })
        assert_false(res and res.ok)
    end)
    it('items outside the catalog, and unfunded businesses, are refused', function()
        asMechanicBoss()
        local before = mechanicBank()
        assert_false(pc('business:supplies:orders:create', { mode = 'job', fulfillment = 'pickup', items = { { item = 'goldbar', quantity = 1 } } }).ok)
        assert_false(pc('business:supplies:orders:create', { mode = 'job', fulfillment = 'pickup', items = { { item = 'lockpick', quantity = 100 } } }).ok)
        assert_eq(mechanicBank(), before)
    end)
    it('staff open the business stock only at a stash point', function()
        asMechanicBoss()
        assert_true(pc('business:stash:place', { coords = { x = 500.0, y = 500.0, z = 30.0 } }).ok)
        Mock.clientEvents = {}
        Mock.coords[OWNER] = vector3(900.0, 900.0, 30.0)
        Mock.fireNet('pf-computer:server:openBusinessStash', OWNER, 'mechanic', 1)
        local opened = #Mock.clientEvents
        Mock.coords[OWNER] = vector3(500.5, 500.0, 30.0)
        Mock.fireNet('pf-computer:server:openBusinessStash', OWNER, 'mechanic', 1)
        assert_true(#Mock.clientEvents > opened, 'opened at the stash point')
        Mock.clientEvents = {}
        Mock.players[OWNER].PlayerData.job = { name = 'police', isboss = true, grade = { level = 4 } }
        Mock.fireNet('pf-computer:server:openBusinessStash', OWNER, 'mechanic', 1)
        assert_eq(#Mock.clientEvents, 0, 'another job cannot open it')
    end)
end)
