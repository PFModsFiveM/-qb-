-- Vineyard -> restaurants on a real database, through the real resources: a vineyard worker makes
-- wine (pf-jobs vineyard), registers as a player supplier and stocks it from the Supplier app
-- (pf-stores), a restaurant orders wine priced at its own supply price (pf-restaurants
-- Config.Supplies.PricePerItem, not the $1 beverage price), the supplier accepts and is paid on the
-- ledger, the delivery is unpacked into the restaurant's stock, poured into glasses at the drink
-- station, and the glass goes on the menu.
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
Config = nil
for _, f in ipairs({ 'shared', 'items', 'restaurants', 'stations', 'recipes' }) do load_resource('[pfscripts]/pf-restaurants/config/' .. f .. '.lua') end
for k, v in pairs(Config) do merged[k] = v end
Config = merged
Config.Delivery = { DropoffRadius = 80.0, ReturnRadius = 35.0, MinSeconds = 45, MaxAverageSpeed = 45.0 }
Config.WorkTruck = { Enabled = false }
Config.NpcJobs = { Enabled = false }
Config.SupplyChain = {
    PlayerSuppliers = true, SupplierOfferSeconds = 60, AIMarkup = 0.15, PlayerSupplierShareOfMarkup = 0.5,
    DriverPrioritySeconds = 120, DriverMaxSeconds = 1800, AIDeliverySeconds = 300, PalletModel = 'prop_boxpile_06b', DuplicateWindowSeconds = 10,
}
Config.Logging.Enabled = false
QBCoreMock.Shared.Items.supply_crate = { name = 'supply_crate', label = 'Supply Crate', weight = 5000, type = 'item', unique = true, image = 'x.png' }
for _, it in ipairs({ { 'wine', 'Wine', 300 }, { 'grapejuice', 'Grape Juice', 200 }, { 'grape', 'Grape', 100 } }) do
    QBCoreMock.Shared.Items[it[1]] = { name = it[1], label = it[2], weight = it[3], type = 'item', unique = false, useable = true, image = it[1] .. '.png' }
end
QBCoreMock.Shared.Jobs = { burgershot = { label = 'Burger Shot' } }
Mock.exportsByResource['pf-government'] = {
    GetSalesTaxRate = function() return 0.0 end,
    CollectTaxAmount = function(_, amount) return amount end,
    HasPermission = function() return false end,
    CheckBusinessLicense = function() return true end,
}
-- the Supplier app's registration, as pf-devices sees it
local supplierApp = {}
Mock.exportsByResource['pf-devices'] = {
    RegisterApp = function(_, def) supplierApp.def = def return true end,
    RegisterAppHandlers = function(_, id, map) supplierApp.h = map return true end,
    Push = function() return true end,
}

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
for _, f in ipairs({ 'main', 'persistence', 'business', 'recipes', 'menu', 'orders', 'stations', 'inventory', 'equipment', 'hygiene', 'fire', 'placeholders_government' }) do
    load_resource('[pfscripts]/pf-restaurants/server/' .. f .. '.lua')
end
-- pf-jobs' vineyard, with its own ledger helper (system:pf-jobs)
function GetCurrentResourceName() return 'pf-jobs' end
load_resource('pfm-banking/payouts.lua')
load_resource('[pfscripts]/pf-jobs/server/apps/vineyard.lua')
function GetCurrentResourceName() return 'pf-stores' end
load_resource('[pfscripts]/pf-stores/server_supplier_app.lua')
for _, res in ipairs({ 'pfm-banking', 'pfm-inventory', 'pf-stores', 'pf-trucking', 'pfm-worldobjects', 'pf-restaurants' }) do
    Mock.exportsByResource[res] = Mock.exportsByResource['__self']
end
Mock.eventHandlers['pf-devices:server:ready']()

local L, O, W, V = PFLedger, PFOrders, PFWorldObjects, PFVineyard
local BID = 'burgershot_vespucci'
local BOSS, VINT = 1, 2
local CIDS = { [BOSS] = 'BOSS1', [VINT] = 'VINT1' }
local DRINKS = vector3(-1195.0, -895.5, 13.98)

assert(L.Start(), 'ledger start')
assert(O.Start(), 'order service start')
assert(W.Start(), 'world objects start')
InitRestaurants()
assert(RestaurantDB.Boot(), 'restaurants boot')
assert(V.Start(), 'vineyard migrations')
for _, cid in pairs(CIDS) do
    MySQL.query.await("INSERT INTO players (citizenid, cid, license, name, money, charinfo, job, gang, position, metadata, inventory) VALUES (?, 1, ?, ?, '{\"cash\":0,\"bank\":0}', '{}', '{}', '{}', '{}', '{}', '[]')", { cid, 'license:' .. cid, cid })
end

local inv = exports['pfm-inventory']
local function society(name) return tonumber(MySQL.scalar.await('SELECT account_balance FROM bank_accounts WHERE account_name = ?', { name })) or 0 end
local function fund(amount)
    assert(L.EnsureSociety('restaurant_' .. BID, 'business'))
    assert(L.Transfer({ from = 'system:test', to = 'society:restaurant_' .. BID, amount = amount, key = L.AutoKey('fund'), kind = 'test' }).ok)
end
local function stash(storage, item)
    local s = inv:GetInventory(StockStashId(BID, storage))
    local n = 0
    for _, it in pairs(s and s.items or {}) do if it.name == item then n = n + it.amount end end
    return n
end
local function tick(seconds) Mock.clock = Mock.clock + (seconds or 0) O.Tick() end
local function offerStock() return tonumber(MySQL.scalar.await("SELECT stock_qty FROM pf_supplier_offers WHERE item = 'wine'")) or 0 end

Mock.players = {}
for src, cid in pairs(CIDS) do
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.items = {}
    p.PlayerData.money = { cash = 0, bank = 0 }
end
Mock.players[BOSS].PlayerData.job = { name = 'burgershot', label = 'Burger Shot', onduty = true, isboss = true, grade = { level = 4 } }
Mock.players[VINT].PlayerData.job = { name = 'vineyard', label = 'Vineyard', onduty = true, grade = { level = 0 } }

BeforeEach = function()
    Mock.reset()
    Mock.gameTimer = Mock.gameTimer + 100000
end

local orderId, made

describe('1. wine and grape juice are restaurant supplies', function()
    it('at their own price, not the $1 beverage price, in the right storage area', function()
        local catalog = exports['pf-restaurants']:GetSupplyCatalog(BID)
        local byItem = {}
        for _, it in ipairs(catalog.items) do byItem[it.item] = it end
        assert_eq(byItem.wine.pricePerCase, Config.Supplies.PricePerItem.wine)
        assert_true(byItem.wine.pricePerCase > Config.Supplies.PricePerUnit.beverages, 'wine is not $1')
        assert_eq(byItem.wine.category, 'beverages')
        assert_eq(byItem.wine.storage, 'dry')
        assert_eq(byItem.grapejuice.pricePerCase, Config.Supplies.PricePerItem.grapejuice)
        assert_eq(byItem.grapejuice.storage, 'fridge')
        assert_eq(byItem.soda_syrup_cola.pricePerCase, Config.Supplies.PricePerUnit.beverages, 'other beverages keep their category price')
        assert_eq(byItem.wine_glass, nil, 'a poured glass is not a supply')
        assert_eq(exports['pf-restaurants']:GetSupplyUnitPrice('wine'), 18)
        assert_eq(exports['pf-restaurants']:GetSupplyUnitPrice('wine_glass'), nil)
    end)
    it('the order service prices a cart from them and drops what is not a supply', function()
        local lines, total = O.kinds.restaurant.price(BID, { { name = 'wine', quantity = 5, cost = 0.01 }, { name = 'wine_glass', quantity = 3 }, { name = 'grapejuice', quantity = 2 } })
        assert_eq(#lines, 2)
        assert_eq(total, 5 * 18 + 2 * 10)
        assert_eq(lines[1].cost, 18, 'the client cost is ignored')
    end)
    it('wine and grape juice keep (they are perishable beverages) and the glasses are real items', function()
        assert_true(PFFreshness.IsPerishable('wine'))
        assert_true(PFFreshness.IsPerishable('grapejuice'))
        assert_true(QBCoreMock.Shared.Items.wine_glass ~= nil)
        assert_true(QBCoreMock.Shared.Items.grape_juice_glass ~= nil)
    end)
end)

describe('2. the vineyard makes the wine', function()
    it('a barrel of grape juice from several batches becomes wine after the wine time, once', function()
        for _ = 1, 3 do assert_true(inv:AddItem(VINT, 'grapejuice', 8, false, false, 'test')) end
        Mock.coords[VINT] = V.Config.Winery.coords
        assert_true(Mock.callCallback('pf-jobs:vineyard:loadWine', VINT))
        assert_eq(inv:GetItemCount(VINT, 'grapejuice'), 1)
        Mock.fireNet('pf-jobs:vineyard:collectWine', VINT)
        assert_eq(inv:GetItemCount(VINT, 'wine'), 0, 'still fermenting')
        Mock.clock = Mock.clock + V.Config.WineSeconds
        Mock.fireNet('pf-jobs:vineyard:collectWine', VINT)
        made = inv:GetItemCount(VINT, 'wine')
        assert_true(made >= V.Config.WinePerBarrel[1], 'bottled ' .. made)
        Mock.fireNet('pf-jobs:vineyard:collectWine', VINT)
        assert_eq(inv:GetItemCount(VINT, 'wine'), made, 'once')
        local row = MySQL.single.await('SELECT wine, barrel_ready_at FROM pf_vineyard_stats WHERE citizenid = ?', { 'VINT1' })
        assert_eq(tonumber(row.wine), made)
        assert_eq(row.barrel_ready_at, nil)
    end)
end)

describe('3. sold to a restaurant through the Supplier app', function()
    it('the worker registers, offers wine up to the restaurant price and stocks what they carry', function()
        assert_true(inv:AddItem(VINT, 'wine', 60 - made, false, false, 'test'))
        assert_eq(supplierApp.def.id, 'supplier')
        assert_true(supplierApp.h.register(VINT, { name = 'Tongva Hills Vineyard' }).ok)
        assert_true(supplierApp.h.setOffer(VINT, { item = 'wine', price = 18 }).ok)
        assert_true(supplierApp.h.stock(VINT, { item = 'wine', cases = 60 }).ok, 'fresh vineyard wine is accepted')
        assert_eq(inv:GetItemCount(VINT, 'wine'), 0)
        assert_eq(offerStock(), 60)
        local status = supplierApp.h.status(VINT, {})
        assert_eq(status.offers[1].item, 'wine')
        assert_eq(status.offers[1].stock, 60)
    end)
    it('the restaurant orders 60 bottles at $18 and the supplier is offered the order first', function()
        fund(2000)
        Mock.coords[BOSS] = DRINKS
        local res = O.Create(BOSS, { kind = 'restaurant', buyerId = BID, method = 'trucking', cart = { { name = 'wine', quantity = 60 } } })
        assert_true(res.ok, tostring(res.error))
        orderId = res.data.orderId
        local o = O.Get(orderId)
        assert_eq(tonumber(o.subtotal), 60 * 18)
        assert_eq(o.status, 'awaiting_supplier')
        local open = supplierApp.h.status(VINT, {}).orders
        assert_eq(#open, 1)
        assert_eq(open[1].orderId, orderId)
    end)
    it('the supplier accepts once; the stock is reserved and nothing is paid until delivery', function()
        assert_true(supplierApp.h.accept(VINT, { orderId = orderId }).ok)
        assert_false(supplierApp.h.accept(VINT, { orderId = orderId }).ok, 'accepted once')
        assert_eq(offerStock(), 0)
        local o = O.Get(orderId)
        assert_eq(o.supplier_kind, 'player')
        assert_eq(o.supplier_ref, 'VINT1')
        -- the markup share is paid at delivery: a cancel now would leave the supplier nothing
        assert_eq(Mock.players[VINT].PlayerData.money.bank, 0)
    end)
    it('delivered: the supplier is paid the full goods value and the markup share once; the wine lands in the restaurant stock', function()
        tick(121)
        tick(301)
        local o = O.Get(orderId)
        assert_eq(o.status, 'delivered')
        local freight = tonumber(o.freight_payout)
        assert_true(freight > 0)
        assert_eq(tonumber(o.total), 60 * 18 + tonumber(o.ai_markup) + freight, 'the restaurant paid the freight on top')
        local share = math.floor(60 * 18 * 0.15 * 0.5 * 100 + 0.5) / 100
        assert_eq(Mock.players[VINT].PlayerData.money.bank, share + 60 * 18, 'no freight taken out of the wine money')
        tick(10)
        assert_eq(Mock.players[VINT].PlayerData.money.bank, share + 60 * 18, 'paid once')
        local pallet = MySQL.single.await('SELECT * FROM pf_world_objects WHERE order_id = ?', { orderId })
        Mock.coords[BOSS] = vector3(pallet.x, pallet.y, pallet.z)
        assert_true(W.Unpack(BOSS, pallet.id).ok)
        assert_eq(stash('dry', 'wine'), 60)
    end)
end)

describe('4. made and sold by the restaurant', function()
    it('a bottle from the stock pours four glasses of wine at the drink station', function()
        Mock.coords[BOSS] = DRINKS
        Mock.fireNet('pf-restaurants:server:startStationAction', BOSS, BID, 'bs_drink_1', 1, { action = 'fill_drink', inputItems = { { item = 'wine', qty = 1 } } })
        assert_eq(stash('dry', 'wine'), 59)
        local ev = Mock.clientEventsNamed('pf-restaurants:client:stationSessionStart')
        local session = ev[#ev].args[4]
        assert_eq(session.outputItem, 'wine_glass')
        Mock.clock = Mock.clock + 9
        Mock.fireNet('pf-restaurants:server:completeStationAction', BOSS, session.sessionId)
        assert_eq(inv:GetItemCount(BOSS, 'wine_glass'), 4)
    end)
    it('the glass of wine goes on the menu at a price the restaurant sets', function()
        Mock.fireNet('pf-restaurants:server:createMenuItem', BOSS, BID, { recipeId = 'wine_glass', price = 9 })
        local found
        for _, m in pairs(RestaurantData.menus[BID] or {}) do if m.recipeId == 'wine_glass' then found = m end end
        assert_true(found ~= nil, 'on the menu')
        assert_eq(found.displayName, 'Glass of Wine')
        assert_eq(found.category, 'drinks')
        assert_eq(found.price, 9)
        local saved = MySQL.scalar.await('SELECT COUNT(*) FROM pf_restaurant_menu WHERE business_id = ? AND menu_item_id = ?', { BID, found.menuItemId })
        assert_eq(tonumber(saved), 1, 'saved')
    end)
    it('grape juice pours two glasses', function()
        assert_true(inv:AddItem(StockStashId(BID, 'fridge'), 'grapejuice', 1, false, false, 'test'))
        Mock.fireNet('pf-restaurants:server:startStationAction', BOSS, BID, 'bs_drink_1', 2, { action = 'fill_drink', inputItems = { { item = 'grapejuice', qty = 1 } } })
        local ev = Mock.clientEventsNamed('pf-restaurants:client:stationSessionStart')
        local session = ev[#ev].args[4]
        assert_eq(session.outputItem, 'grape_juice_glass')
        Mock.clock = Mock.clock + 6
        Mock.fireNet('pf-restaurants:server:completeStationAction', BOSS, session.sessionId)
        assert_eq(inv:GetItemCount(BOSS, 'grape_juice_glass'), 2)
        assert_eq(stash('fridge', 'grapejuice'), 0)
    end)
end)
