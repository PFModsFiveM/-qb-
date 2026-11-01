-- Scrap -> mechanic shops on a real database, through the real resources: the recycling plant
-- (pf-jobs recycle) sorts packages into materials and pays the shift once on the ledger; the
-- recycler stocks scrap as a player supplier (pf-stores); a mechanic shop orders scrap from its
-- supply catalog (pf-mechanicjob Config.SuppliesCatalog.materials, through pf-computer's job-business
-- buyer) at per-unit prices; the supplier fills it, is paid, and the shop's stock gets exactly the
-- units it paid for (one unit per case, so supplier stock and delivery match).
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function GetResourceState() return 'started' end
function GetCurrentResourceName() return 'pfm-banking' end
function SetEntityRotation() end
function FreezeEntityPosition() end
function GetEntityHeading() return 0.0 end
function SaveResourceFile() return true end
function LoadResourceFile() return nil end
function RegisterCommand() end

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
RealDB.exec('pfm-inventory/qb-inventory.sql')
RealDB.exec('[pfscripts]/pf-stores/install.sql')

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
-- pf-mechanicjob's catalog settings (its other settings would clash with the merged config)
Config = nil
load_resource('[pfscripts]/pf-mechanicjob/config.lua')
local mech = Config
Config = merged
Config.SuppliesCatalog, Config.RegisterItems = mech.SuppliesCatalog, mech.RegisterItems
Config.Delivery = { DropoffRadius = 80.0, ReturnRadius = 35.0, MinSeconds = 45, MaxAverageSpeed = 45.0 }
Config.WorkTruck = { Enabled = false }
Config.NpcJobs = { Enabled = false }
Config.SupplyChain = {
    PlayerSuppliers = true, SupplierOfferSeconds = 60, AIMarkup = 0.15, PlayerSupplierShareOfMarkup = 0.5,
    DriverPrioritySeconds = 120, DriverMaxSeconds = 1800, AIDeliverySeconds = 300, PalletModel = 'prop_boxpile_06b', DuplicateWindowSeconds = 10,
}
QBCoreMock.Shared.Items.supply_crate = { name = 'supply_crate', label = 'Supply Crate', weight = 5000, type = 'item', unique = true, image = 'x.png' }
for _, name in ipairs({ 'metalscrap', 'plastic', 'copper', 'rubber', 'iron', 'aluminum', 'steel', 'glass', 'cryptostick' }) do
    QBCoreMock.Shared.Items[name] = { name = name, label = name, weight = 1, type = 'item', unique = false, useable = false, image = name .. '.png' }
end
QBCoreMock.Shared.Jobs = { mechanic = { label = 'Mechanic', grades = {} } }
local SHOP = vector3(-350.18, -133.84, 39.01)
Mock.exportsByResource['pf-government'] = {
    HasPermission = function() return false end,
    CheckBusinessLicense = function() return true end,
    GetDeliveryZone = function(_, id) if id == 'mechanic:mechanic' then return { x = SHOP.x, y = SHOP.y, z = SHOP.z, heading = 0.0, label = 'Mechanic' } end end,
}
Mock.exportsByResource['pf-devices'] = { Push = function() return true end, RegisterApp = function() return true end, RegisterAppHandlers = function() return true end }

load_resource('pfm-core/server/migrations.lua')
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')
load_resource('pfm-inventory/server/freshness.lua')
load_resource('pfm-inventory/server/main.lua')
load_resource('pfm-inventory/server/functions.lua')
load_resource('pfm-inventory/server/hooks.lua')
load_resource('[pfscripts]/pf-stores/server_orders.lua')
load_resource('[pfscripts]/pf-trucking/server.lua')
load_resource('pfm-worldobjects/server.lua')
QBCore = QBCoreMock
load_resource('[pfscripts]/pf-computer/server/main.lua')
load_resource('[pfscripts]/pf-mechanicjob/server/business_data_provider.lua')
function GetCurrentResourceName() return 'pf-jobs' end
load_resource('pfm-banking/payouts.lua')
load_resource('[pfscripts]/pf-jobs/server/apps/recycle.lua')
for _, res in ipairs({ 'pfm-banking', 'pfm-inventory', 'pf-stores', 'pf-trucking', 'pfm-worldobjects', 'pf-computer', 'pf-mechanicjob' }) do
    Mock.exportsByResource[res] = Mock.exportsByResource['__self']
end

local L, O, W, R = PFLedger, PFOrders, PFWorldObjects, PFRecycle
local BOSS, RECYCLER = 1, 2
local CIDS = { [BOSS] = 'MECH1', [RECYCLER] = 'RECY1' }

assert(L.Start(), 'ledger start')
assert(O.Start(), 'order service start')
assert(W.Start(), 'world objects start')
assert(R.Start(), 'recycling migrations')
for _, cid in pairs(CIDS) do
    MySQL.query.await("INSERT INTO players (citizenid, cid, license, name, money, charinfo, job, gang, position, metadata, inventory) VALUES (?, 1, ?, ?, '{\"cash\":0,\"bank\":0}', '{}', '{}', '{}', '{}', '{}', '[]')", { cid, 'license:' .. cid, cid })
end
-- the boss's Order Supplies app on PF Computer (pf-computer registers its job-business buyer on the way)
local function pc(action, payload)
    Mock.clientEvents = {}
    Mock.gameTimer = Mock.gameTimer + 100000
    Mock.fireNet('pf-computer:server:callback', BOSS, 7, action, payload or {})
    local ev = Mock.clientEventsNamed('pf-computer:client:callback')[1]
    return ev and ev.args[2]
end

local inv = exports['pfm-inventory']
local function society(name) return tonumber(MySQL.scalar.await('SELECT account_balance FROM bank_accounts WHERE account_name = ?', { name })) or 0 end
local function tick(seconds) Mock.clock = Mock.clock + (seconds or 0) O.Tick() end
local function stock() local s = inv:GetInventory('bizstash-mechanic') local n = 0 for _, it in pairs(s and s.items or {}) do if it.name == 'metalscrap' then n = n + it.amount end end return n end

Mock.players = {}
for src, cid in pairs(CIDS) do
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.items = {}
    p.PlayerData.money = { cash = 0, bank = 0 }
end
Mock.players[BOSS].PlayerData.job = { name = 'mechanic', label = 'Mechanic', onduty = true, isboss = true, grade = { level = 4 } }

BeforeEach = function()
    Mock.reset()
    Mock.gameTimer = Mock.gameTimer + 100000
end

local orderId
local ORDER = 500

describe('1. the mechanic supply catalog sells scrap materials', function()
    it('every material at its own per-unit price, next to the parts, in the Order Supplies app', function()
        local res = pc('business:supplies:catalog', { mode = 'job' })
        assert_true(res and res.ok, res and tostring(res.error))
        local byItem, parts = {}, 0
        for _, it in ipairs(res.data.catalog.items) do
            byItem[it.item] = it
            if it.category ~= 'Materials' then parts = parts + 1 end
        end
        assert_true(parts > 10, 'the parts are still there: ' .. parts)
        for _, m in ipairs(mech.SuppliesCatalog.materials) do
            assert_true(byItem[m.item] ~= nil, m.item .. ' listed')
            assert_eq(byItem[m.item].caseSize, 1)
            assert_eq(byItem[m.item].pricePerCase, m.casePrice)
            assert_eq(byItem[m.item].category, 'Materials')
        end
    end)
end)

describe('2. the recycling plant produces the scrap', function()
    local function package()
        local s = R.__shift(RECYCLER)
        local shelf = R.Config.Shelves[s.target]
        Mock.coords[RECYCLER] = vector3(shelf.x, shelf.y, shelf.z)
        Mock.fireNet('pf-jobs:recycle:pickup', RECYCLER)
        Mock.clock = Mock.clock + 10
        Mock.gameTimer = Mock.gameTimer + 10000
        local d = R.Config.DropLocation
        Mock.coords[RECYCLER] = vector3(d.x, d.y, d.z)
        Mock.fireNet('pf-jobs:recycle:handIn', RECYCLER)
        Mock.gameTimer = Mock.gameTimer + 10000
    end
    it('a shift sorts packages into materials and is paid once when it ends', function()
        local desk = R.Config.DutyLocation
        Mock.coords[RECYCLER] = vector3(desk.x, desk.y, desk.z)
        Mock.fireNet('pf-jobs:recycle:clockIn', RECYCLER)
        assert_true(R.__shift(RECYCLER) ~= nil)
        package()
        package()
        local sorted = 0
        for _, m in ipairs(R.Config.Materials) do sorted = sorted + inv:GetItemCount(RECYCLER, m.item) end
        assert_true(sorted > 0, 'materials in the pockets')
        local row = MySQL.single.await('SELECT packages, materials, wage, status FROM pf_recycle_shifts WHERE citizenid = ?', { 'RECY1' })
        assert_eq(tonumber(row.packages), 2)
        assert_eq(tonumber(row.materials), sorted)
        assert_eq(row.status, 'open')
        Mock.fireNet('pf-jobs:recycle:clockOut', RECYCLER, false)
        Mock.fireNet('pf-jobs:recycle:clockOut', RECYCLER, false)
        assert_eq(Mock.players[RECYCLER].PlayerData.money.bank, 2 * R.Config.Levels[1].wage)
        assert_eq(MySQL.single.await('SELECT status FROM pf_recycle_shifts WHERE citizenid = ?', { 'RECY1' }).status, 'paid')
        local paid = MySQL.scalar.await("SELECT COUNT(*) FROM pf_transactions WHERE idempotency_key LIKE 'pf-jobs:recycle:shift:%' AND state = 'completed'")
        assert_eq(tonumber(paid), 1)
    end)
end)

describe('3. sold to the mechanic shop as a player supplier', function()
    it('the recycler stocks scrap they really carry', function()
        local have = inv:GetItemCount(RECYCLER, 'metalscrap')
        assert_true(inv:AddItem(RECYCLER, 'metalscrap', ORDER - have, false, false, 'test'))
        assert_true(O.RegisterSupplier(RECYCLER, 'Paleto Scrap').ok)
        assert_true(O.SetOffer(RECYCLER, 'metalscrap', 3).ok)
        assert_true(O.DepositStock(RECYCLER, 'metalscrap', ORDER).ok)
        assert_eq(inv:GetItemCount(RECYCLER, 'metalscrap'), 0)
    end)
    it('the shop orders scrap, the supplier accepts, and the shop gets exactly what it paid for', function()
        assert(L.EnsureSociety('mechanic', 'job'))
        assert(L.Transfer({ from = 'system:test', to = 'society:mechanic', amount = 3000, key = L.AutoKey('fund'), kind = 'test' }).ok)
        local before = Mock.players[RECYCLER].PlayerData.money.bank
        local res = pc('business:supplies:orders:create', { mode = 'job', fulfillment = 'delivery', items = { { item = 'metalscrap', quantity = ORDER, pricePerCase = 0.01 } } })
        assert_true(res and res.ok, res and tostring(res.error))
        orderId = res.data.orderId
        local o = O.Get(orderId)
        assert_eq(tonumber(o.subtotal), ORDER * 3, 'priced from the catalog, not the client')
        local lines = json.decode(o.items_json)
        assert_eq(lines[1].caseSize, 1)
        assert_eq(lines[1].cost, 3)
        assert_eq(o.status, 'awaiting_supplier')
        assert_true(O.AcceptSupply(RECYCLER, orderId).ok)
        tick(121)
        tick(301)
        o = O.Get(orderId)
        assert_eq(o.status, 'delivered')
        local markupShare = math.floor(ORDER * 3 * 0.15 * 0.5 * 100 + 0.5) / 100
        -- the full goods value (the shop paid the freight on top) and half the markup, at delivery
        assert_true(tonumber(o.freight_payout) > 0)
        assert_eq(tonumber(o.total), ORDER * 3 + tonumber(o.ai_markup) + tonumber(o.freight_payout))
        assert_eq(Mock.players[RECYCLER].PlayerData.money.bank, before + markupShare + ORDER * 3)
        local pallet = MySQL.single.await('SELECT * FROM pf_world_objects WHERE order_id = ?', { orderId })
        Mock.coords[BOSS] = vector3(pallet.x, pallet.y, pallet.z)
        assert_true(W.Unpack(BOSS, pallet.id).ok)
        assert_eq(stock(), ORDER, 'one unit per unit the supplier stocked')
        assert_false(W.Unpack(BOSS, pallet.id).ok)
        assert_eq(stock(), ORDER, 'unpacked once')
    end)
end)

describe('4. recycling rows of a deleted character', function()
    it('are removed', function()
        Mock.fireEvent('pfm-core:server:characterDeleted', nil, 'RECY1')
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_recycle_shifts WHERE citizenid = 'RECY1'")), 0)
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_recycle_stats WHERE citizenid = 'RECY1'")), 0)
    end)
end)

describe('5. a part the shop buys in cases of 10', function()
    it('takes 10 stock units from the supplier per case, never fewer (no duplicated items)', function()
        local res = pc('business:supplies:catalog', { mode = 'job' })
        local part
        for _, it in ipairs(res.data.catalog.items) do
            if (tonumber(it.caseSize) or 1) == 10 and it.category ~= 'Materials' then part = it break end
        end
        assert_true(part ~= nil, 'a part sold in cases of 10')
        QBCoreMock.Shared.Items[part.item] = QBCoreMock.Shared.Items[part.item]
            or { name = part.item, label = part.item, weight = 1, type = 'item', unique = false, useable = false, image = 'x.png' }
        assert_eq(O.SupplierUnits({ name = part.item, quantity = 2, caseSize = 10, cost = 100 }), 20)
        assert_eq(O.SupplierUnits({ name = 'x', quantity = 3, cost = 5 }), 3, 'lines without a case size are unchanged')
        Config.SupplyChain.CaseSize = { [part.item] = 3 }
        assert_eq(O.SupplierUnits({ name = part.item, quantity = 1, caseSize = 10, cost = 100 }), nil, '10 items are not whole units of 3')
        Config.SupplyChain.CaseSize = nil

        assert_true(inv:AddItem(RECYCLER, part.item, 9, false, false, 'test'))
        assert_true(O.SetOffer(RECYCLER, part.item, part.pricePerCase / 10).ok)
        assert_true(O.DepositStock(RECYCLER, part.item, 9).ok)
        assert(L.Transfer({ from = 'system:test', to = 'society:mechanic', amount = part.pricePerCase * 3, key = L.AutoKey('fund'), kind = 'test' }).ok)
        local made = pc('business:supplies:orders:create', { mode = 'job', fulfillment = 'delivery', items = { { item = part.item, quantity = 1 } } })
        assert_true(made and made.ok, made and tostring(made.error))
        local first = O.Get(made.data.orderId)
        assert_true(first.status ~= 'awaiting_supplier', '9 units cannot fill a case of 10: the AI supplier takes it')
        assert_eq(first.supplier_kind, 'ai')
        assert_false(O.AcceptSupply(RECYCLER, first.id).ok)
        assert_eq(tonumber(MySQL.scalar.await('SELECT stock_qty FROM pf_supplier_offers WHERE item = ?', { part.item })), 9, 'nothing reserved')

        assert_true(inv:AddItem(RECYCLER, part.item, 1, false, false, 'test'))
        assert_true(O.DepositStock(RECYCLER, part.item, 1).ok)
        Mock.clock = Mock.clock + 30   -- past the duplicate-order window
        local again = pc('business:supplies:orders:create', { mode = 'job', fulfillment = 'delivery', items = { { item = part.item, quantity = 1 } } })
        assert_true(again and again.ok, again and tostring(again.error))
        local id = again.data.orderId
        assert_true(id ~= first.id, 'a new order')
        assert_eq(O.Get(id).status, 'awaiting_supplier', 'with 10 units the supplier is offered it')
        local open = O.OpenOffersFor(RECYCLER)
        assert_true(#open.data >= 1)
        assert_true(O.AcceptSupply(RECYCLER, id).ok)
        assert_eq(tonumber(MySQL.scalar.await('SELECT stock_qty FROM pf_supplier_offers WHERE item = ?', { part.item })), 0, 'all 10 units reserved')
        tick(121)
        tick(301)
        assert_eq(O.Get(id).status, 'delivered')
        local pallet = MySQL.single.await('SELECT * FROM pf_world_objects WHERE order_id = ?', { id })
        Mock.coords[BOSS] = vector3(pallet.x, pallet.y, pallet.z)
        assert_true(W.Unpack(BOSS, pallet.id).ok)
        local s = inv:GetInventory('bizstash-mechanic')
        local n = 0
        for _, it in pairs(s and s.items or {}) do if it.name == part.item then n = n + it.amount end end
        assert_eq(n, 10, 'the shop receives the 10 items the supplier handed over')
        assert_eq(json.decode(O.Get(id).items_json)[1].reservedUnits, 10, 'the reservation is recorded on the order')

        -- a cancelled order gives back exactly what was reserved; an order accepted before
        -- reservations were recorded gives back its line quantity (what the old code reserved)
        local function stockQty() return tonumber(MySQL.scalar.await('SELECT stock_qty FROM pf_supplier_offers WHERE item = ?', { part.item })) end
        local before = stockQty()
        O.ReturnSupplierStock({ supplier_ref = 'RECY1', items_json = json.encode({ { name = part.item, quantity = 1, caseSize = 10, reservedUnits = 10 } }) })
        assert_eq(stockQty(), before + 10)
        O.ReturnSupplierStock({ supplier_ref = 'RECY1', items_json = json.encode({ { name = part.item, quantity = 1, caseSize = 10 } }) })
        assert_eq(stockQty(), before + 11, 'legacy order: its line quantity')
    end)
end)
