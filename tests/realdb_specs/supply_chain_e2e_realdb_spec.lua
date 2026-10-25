-- The whole business supply chain on a real database, through the real resources:
--   restaurant boss orders ingredients on PF Computer -> priced by the server, paid from the restaurant's
--   bank account into escrow -> AI supplier -> contract to player truckers (priority, one winner) ->
--   loaded at the warehouse -> pf-stores and pf-trucking restart mid-delivery -> delivered, driver paid
--   once -> persistent sealed pallet at the restaurant's receiving point -> other businesses and
--   strangers locked out -> pfm-worldobjects restarts, pallet restored at the same position and rotation
--   -> unpacked once into the restaurant's fridge/freezer stock -> cooked from that stock -> sold to a
--   customer, revenue to the restaurant, tax to the government -> the ledger reconciles.
-- Also: AI delivery when no trucker takes it, cancellation before and after a driver takes it,
-- duplicate submissions, insufficient funds.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function GetResourceState() return 'started' end
function GetCurrentResourceName() return 'pfm-banking' end
function FreezeEntityPosition() end
function GetEntityHeading() return 0.0 end
function LoadResourceFile() return nil end
function RegisterCommand() end
SavedFiles = {}
function SaveResourceFile(_, path, content) SavedFiles[path] = content return true end

-- the world objects spawned, with their rotation, to check what a restart restores
local spawned, rotations = {}, {}
function CreateObjectNoOffset(model, x, y, z)
    Mock.nextNetId = Mock.nextNetId + 1
    spawned[Mock.nextNetId] = { model = model, x = x, y = y, z = z }
    return Mock.nextNetId
end
function SetEntityRotation(entity, rx, ry, rz) rotations[entity] = { rx = rx, ry = ry, rz = rz } end

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
Config = nil
for _, f in ipairs({ 'shared', 'items', 'restaurants', 'stations', 'recipes' }) do load_resource('[pfscripts]/pf-restaurants/config/' .. f .. '.lua') end
for k, v in pairs(Config) do merged[k] = v end
Config = merged
Config.Restaurants.burgershot_vespucci.zones.receiving.deliveryHeading = 135.0
Config.Delivery = { DropoffRadius = 80.0, ReturnRadius = 35.0, MinSeconds = 45, MaxAverageSpeed = 45.0 }
Config.WorkTruck = { Enabled = false }
Config.NpcJobs = { Enabled = false }
Config.SupplyChain = {
    PlayerSuppliers = false, AIMarkup = 0.15, DriverPrioritySeconds = 120, DriverMaxSeconds = 1800,
    AIDeliverySeconds = 300, PalletModel = 'prop_boxpile_06b', DuplicateWindowSeconds = 10,
}
Config.Logging.Enabled = false
QBCoreMock.Shared.Items.supply_crate = { name = 'supply_crate', label = 'Supply Crate', weight = 5000, type = 'item', unique = true, image = 'x.png' }
QBCoreMock.Shared.Jobs = { burgershot = { label = 'Burger Shot' }, pizzathis = { label = 'Pizza This' } }

-- pf-government stand-in for sales tax (its own flows have their own real-database specs)
local taxes = {}
Mock.exportsByResource['pf-government'] = {
    GetSalesTaxRate = function() return 0.10 end,
    CollectTaxAmount = function(_, amount, _, _, _, _, key) taxes[key] = amount return amount end,
    HasPermission = function() return false end,
    CheckBusinessLicense = function() return true end,
}

load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')
load_resource('pfm-inventory/server/freshness.lua')
load_resource('pfm-inventory/server/main.lua')
load_resource('pfm-inventory/server/functions.lua')
load_resource('pfm-inventory/server/hooks.lua')
local function loadOrderService()
    load_resource('[pfscripts]/pf-stores/server_orders.lua')
end
loadOrderService()
load_resource('[pfscripts]/pf-trucking/server.lua')
load_resource('pfm-worldobjects/server.lua')
QBCore = QBCoreMock
for _, f in ipairs({ 'main', 'persistence', 'business', 'recipes', 'menu', 'orders', 'stations', 'inventory', 'equipment', 'hygiene', 'fire', 'placeholders_government' }) do
    load_resource('[pfscripts]/pf-restaurants/server/' .. f .. '.lua')
end
load_resource('[pfscripts]/pf-computer/server/main.lua')
for _, res in ipairs({ 'pfm-banking', 'pfm-inventory', 'pf-stores', 'pf-trucking', 'pfm-worldobjects', 'pf-restaurants', 'pf-computer' }) do
    Mock.exportsByResource[res] = Mock.exportsByResource['__self']
end

local BID = 'burgershot_vespucci'
local BOSS, DRIVER, DRIVER2, RIVAL, CUSTOMER = 1, 2, 3, 4, 5
local CIDS = { [BOSS] = 'BOSS1', [DRIVER] = 'DRV1', [DRIVER2] = 'DRV2', [RIVAL] = 'RIV1', [CUSTOMER] = 'CUST1' }
local WAREHOUSE = Config.Supplies.Warehouse.coords
local RECEIVING = Config.Restaurants[BID].zones.receiving.deliverySpawn
local GRILL = vector3(-1200.5, -891.2, 13.98)
local REGISTER = vector3(-1195.5, -892.0, 13.98)

assert(PFLedger.Start(), 'ledger start')
assert(PFOrders.Start(), 'order service start')
assert(PFWorldObjects.Start(), 'world objects start')
InitRestaurants()
assert(RestaurantDB.Boot(), 'restaurants boot')
for _, cid in pairs(CIDS) do
    MySQL.query.await("INSERT INTO players (citizenid, cid, license, name, money, charinfo, job, gang, position, metadata, inventory) VALUES (?, 1, ?, ?, '{\"cash\":0,\"bank\":0}', '{}', '{}', '{}', '{}', '{}', '[]')", { cid, 'license:' .. cid, cid })
end

local function society(name) return tonumber(MySQL.scalar.await('SELECT account_balance FROM bank_accounts WHERE account_name = ?', { name })) or 0 end
local function fund(amount)
    assert(PFLedger.EnsureSociety('restaurant_' .. BID, 'business'))
    assert(PFLedger.Transfer({ from = 'system:test', to = 'society:restaurant_' .. BID, amount = amount, key = PFLedger.AutoKey('fund'), kind = 'test' }).ok)
end
local function order(id) return PFOrders.Get(id) end
local function pallet(id) return MySQL.single.await('SELECT * FROM pf_world_objects WHERE order_id = ?', { id }) end
local function stash(storage, item)
    local inv = exports['pfm-inventory']:GetInventory(StockStashId(BID, storage))
    local n = 0
    for _, it in pairs(inv and inv.items or {}) do if it.name == item then n = n + it.amount end end
    return n
end
local function cb(name, src, ...) return Mock.callCallback(name, src, ...) end
local function pc(src, action, payload)
    Mock.clientEvents = {}
    Mock.gameTimer = Mock.gameTimer + 100000
    Mock.fireNet('pf-computer:server:callback', src, 7, action, payload or {})
    local ev = Mock.clientEventsNamed('pf-computer:client:callback')[1]
    return ev and ev.args[2]
end
local function tick(seconds) Mock.clock = Mock.clock + (seconds or 0) PFOrders.Tick() end
local function players()
    Mock.players = {}
    for src, cid in pairs(CIDS) do
        local p = Mock.newPlayer(src, cid)
        p.PlayerData.money = { cash = 200, bank = 0 }
        p.PlayerData.items = {}
        p.PlayerData.job = { name = 'unemployed', onduty = false, grade = { level = 0 } }
    end
    Mock.players[BOSS].PlayerData.job = { name = 'burgershot', label = 'Burger Shot', onduty = true, isboss = true, grade = { level = 4 } }
    Mock.players[RIVAL].PlayerData.job = { name = 'pizzathis', label = 'Pizza This', onduty = true, isboss = true, grade = { level = 4 } }
end
local CART = { { item = 'raw_bacon', quantity = 6, pricePerCase = 0.01 }, { item = 'raw_beef_patty', quantity = 4 } }

BeforeEach = function()
    Mock.reset()
    Mock.gameTimer = Mock.gameTimer + 100000
    players()
    Mock.coords = { [BOSS] = GRILL, [DRIVER] = WAREHOUSE, [DRIVER2] = WAREHOUSE, [RIVAL] = RECEIVING, [CUSTOMER] = REGISTER }
end

local id   -- the order followed through the chain

describe('1. ordering on PF Computer', function()
    it('the restaurant catalog comes from pf-restaurants and is not empty', function()
        local res = pc(BOSS, 'business:supplies:catalog', { mode = 'job' })
        assert_true(res and res.ok, res and tostring(res.error))
        assert_eq(res.data.businessType, 'restaurant')
        assert_true(#res.data.catalog.items > 10, 'ingredients listed: ' .. #res.data.catalog.items)
        assert_true(res.data.deliveryAvailable, 'the receiving point makes delivery available')
    end)
    it('an unfunded restaurant cannot order, and no money moves', function()
        local res = pc(BOSS, 'business:supplies:orders:create', { mode = 'job', fulfillment = 'delivery', items = CART })
        assert_false(res.ok)
        assert_eq(res.error, 'insufficient_funds')
        assert_eq(society('freight_escrow'), 0)
    end)
    it('the order is priced by the server and paid from the restaurant account into escrow; a resend is not charged twice', function()
        fund(100)
        local res = pc(BOSS, 'business:supplies:orders:create', { mode = 'job', fulfillment = 'delivery', items = CART })
        assert_true(res.ok, tostring(res.error))
        id = res.data.orderId
        local o = order(id)
        local subtotal = 6 * Config.Supplies.PricePerUnit.meat_raw + 4 * Config.Supplies.PricePerUnit.meat_raw
        assert_eq(tonumber(o.subtotal), subtotal, 'client prices ignored')
        assert_eq(o.buyer_kind, 'restaurant')
        assert_eq(o.store_id, BID)
        assert_eq(tonumber(o.total), math.floor(subtotal * 1.15 * 100 + 0.5) / 100)
        assert_eq(society('restaurant_' .. BID), 100 - tonumber(o.total))
        assert_eq(society('freight_escrow'), tonumber(o.total))
        local again = pc(BOSS, 'business:supplies:orders:create', { mode = 'job', fulfillment = 'delivery', items = CART })
        assert_true(again.ok)
        assert_eq(again.data.orderId, id, 'the same order, not a second one')
        assert_eq(society('restaurant_' .. BID), 100 - tonumber(o.total), 'charged once')
        local tx = MySQL.single.await('SELECT * FROM pf_transactions WHERE idempotency_key = ?', { ('supply:%d:charge'):format(id) })
        assert_eq(tx.from_account, 'society:restaurant_' .. BID)
        assert_eq(o.payment_tx, tx.tx_id, 'the order points at its ledger transaction')
    end)
    it('the AI supplier takes it and the delivery is offered to player truckers', function()
        local o = order(id)
        assert_eq(o.status, 'awaiting_delivery')
        assert_eq(o.supplier_kind, 'ai')
        local list = pc(BOSS, 'business:supplies:orders:list', { mode = 'job' })
        assert_eq(list.data[1].orderStatus, 'awaiting_delivery')
    end)
end)

describe('2. player trucker', function()
    it('only one of two truckers gets the contract', function()
        local first = cb('pf-trucking:server:claimContract', DRIVER, 'SUP-' .. id)
        local second = cb('pf-trucking:server:claimContract', DRIVER2, 'SUP-' .. id)
        assert_true(first.ok, tostring(first.error))
        assert_false(second.ok)
        assert_eq(order(id).status, 'assigned')
        assert_eq(order(id).driver_ref, 'DRV1')
    end)
    it('once a driver has it, the restaurant cannot cancel', function()
        local before = society('restaurant_' .. BID)
        local res = pc(BOSS, 'business:supplies:orders:cancel', { mode = 'job', orderId = id })
        assert_false(res.ok)
        assert_eq(society('restaurant_' .. BID), before)
    end)
    it('the cargo is loaded at the warehouse, not anywhere', function()
        Mock.coords[DRIVER] = vector3(0.0, 0.0, 0.0)
        Mock.fireNet('pf-trucking:server:cargoLoaded', DRIVER)
        assert_eq(order(id).status, 'assigned')
        Mock.coords[DRIVER] = WAREHOUSE
        Mock.fireNet('pf-trucking:server:cargoLoaded', DRIVER)
        assert_eq(order(id).status, 'in_transit')
    end)
    it('pf-stores and pf-trucking restart mid-delivery: same order, same driver, nothing lost', function()
        loadOrderService()
        load_resource('[pfscripts]/pf-trucking/server.lua')
        Mock.exportsByResource['pf-stores'] = Mock.exportsByResource['__self']
        Mock.exportsByResource['pf-trucking'] = Mock.exportsByResource['__self']
        assert_true(PFOrders.Start())
        assert_true(RegisterRestaurantSupplies())
        TriggerEvent('pf-trucking:server:started')
        assert_eq(order(id).status, 'in_transit')
        assert_eq(order(id).driver_ref, 'DRV1')
        assert_false(cb('pf-trucking:server:claimContract', DRIVER2, 'SUP-' .. id).ok, 'still the first driver')
    end)
    it('arriving at the restaurant pays the driver once and leaves a pallet', function()
        assert_false(cb('pf-trucking:server:completeActiveJob', DRIVER).ok, 'not at the restaurant yet')
        Mock.coords[DRIVER] = RECEIVING
        Mock.clock = Mock.clock + 900
        assert_true(cb('pf-trucking:server:completeActiveJob', DRIVER).ok)
        local pay = Mock.players[DRIVER].PlayerData.money.bank
        assert_true(pay > 0, 'driver paid')
        assert_false(cb('pf-trucking:server:completeActiveJob', DRIVER).ok)
        assert_eq(Mock.players[DRIVER].PlayerData.money.bank, pay, 'paid once')
        assert_eq(order(id).status, 'delivered')
        assert_eq(society('freight_escrow'), 0, 'escrow settled: driver, supplier and markup paid out')
        local p = pallet(id)
        assert_true(p ~= nil and p.state == 'sealed')
        assert_eq(p.owner_ref, 'restaurant:' .. BID)
        assert_true(math.abs(p.x - RECEIVING.x) < 0.01 and math.abs(p.y - RECEIVING.y) < 0.01)
        assert_eq(tonumber(p.rz), 135.0)
    end)
end)

describe('3. the pallet', function()
    it('another restaurant, a stranger or a forged request cannot open, move or unpack it', function()
        local p = pallet(id)
        Mock.coords[RIVAL] = vector3(p.x, p.y, p.z)
        Mock.fireNet('pfm-worldobjects:server:open', RIVAL, p.id)
        assert_true(not (Mock.selfExport('GetInventory')(p.stash_id) or {}).isOpen, 'not opened')
        assert_false(PFWorldObjects.Unpack(RIVAL, p.id).ok)
        assert_false(PFWorldObjects.Move(RIVAL, p.id).ok)
        assert_false(PFWorldObjects.Unpack(CUSTOMER, p.id).ok)
        assert_eq(stash('fridge', 'raw_bacon'), 0)
    end)
    it('its contents are sealed: staff can look but not take', function()
        local p = pallet(id)
        Mock.coords[BOSS] = vector3(p.x, p.y, p.z)
        Mock.fireNet('pfm-worldobjects:server:open', BOSS, p.id)
        local inv = Mock.selfExport('GetInventory')(p.stash_id)
        assert_eq(inv.isOpen, BOSS)
        local slot = next(inv.items)
        Mock.fireNet('qb-inventory:server:SetInventoryData', BOSS, p.stash_id, 'player', slot, 1, 1, 1)
        assert_eq(inv.items[slot] and inv.items[slot].name, 'supply_crate', 'still on the pallet')
        Mock.fireNet('qb-inventory:server:closeInventory', BOSS, p.stash_id)
    end)
    it('pfm-worldobjects restarts: the pallet comes back where it was, the same way round, with its contents', function()
        local p = pallet(id)
        spawned, rotations = {}, {}
        load_resource('pfm-worldobjects/server.lua')
        Mock.exportsByResource['pfm-worldobjects'] = Mock.exportsByResource['__self']
        assert_true(PFWorldObjects.Start())
        local entity = PFWorldObjects.entities[p.id]
        assert_true(entity ~= nil, 'respawned')
        assert_true(math.abs(spawned[entity].x - p.x) < 0.001 and math.abs(spawned[entity].y - p.y) < 0.001 and math.abs(spawned[entity].z - p.z) < 0.001)
        assert_eq(rotations[entity].rz, 135.0)
        local saved = MySQL.scalar.await('SELECT items FROM inventories WHERE identifier = ?', { p.stash_id })
        assert_true(saved ~= nil and saved:find('supply_crate') ~= nil, 'contents in the database')
    end)
    it('unpacking puts the goods in the right storage once, aged by their wait, and the pallet goes away', function()
        local p = pallet(id)
        Mock.coords[BOSS] = vector3(p.x, p.y, p.z)
        Mock.clock = Mock.clock + 3600            -- the pallet waited an hour
        local res = PFWorldObjects.Unpack(BOSS, p.id)
        assert_true(res.ok, tostring(res.error))
        assert_eq(stash(StorageFor('raw_bacon'), 'raw_bacon'), 6)
        assert_eq(stash(StorageFor('raw_beef_patty'), 'raw_beef_patty'), 4)
        assert_false(PFWorldObjects.Unpack(BOSS, p.id).ok)
        assert_false(PFOrders.Unpack(BOSS, id).ok)
        assert_eq(stash(StorageFor('raw_bacon'), 'raw_bacon'), 6, 'stocked once')
        assert_eq(order(id).status, 'unpacked')
        assert_eq(pallet(id).state, 'unpacked')
        local inv = exports['pfm-inventory']:GetInventory(StockStashId(BID, StorageFor('raw_bacon')))
        for _, it in pairs(inv.items) do
            if it.name == 'raw_bacon' then
                local f = exports['pfm-inventory']:GetFreshness(it.name, it.info)
                assert_true(f.pct < 100, 'aged by the wait: ' .. tostring(f.pct))
            end
        end
        local history = MySQL.query.await('SELECT to_status FROM pf_supply_order_events WHERE order_id = ? ORDER BY id', { id })
        local path = {}
        for _, h in ipairs(history) do path[#path + 1] = h.to_status end
        assert_eq(table.concat(path, '>'), 'created>paid>awaiting_supplier>awaiting_delivery>assigned>in_transit>delivered>unpacked')
    end)
end)

describe('3b. the business computer shows the real stock', function()
    it('Inventory lists what is in the restaurant stock areas, with freshness; typed quantities are refused', function()
        local res = pc(BOSS, 'business:stock:get', {})
        assert_true(res and res.ok, res and tostring(res.error))
        local bacon
        for _, it in ipairs(res.data.items) do if it.name == 'raw_bacon' then bacon = it end end
        assert_true(bacon ~= nil, 'delivered bacon listed')
        assert_eq(bacon.amount, 6)
        assert_eq(bacon.area, StorageFor('raw_bacon'))
        assert_true(bacon.freshness ~= nil and bacon.freshness.pct ~= nil)
        local typed = pc(BOSS, 'business:inventory:updateQuantity', { ingredientId = 'raw_bacon', quantity = 999 })
        assert_false(typed.ok)
        assert_eq(pc(BOSS, 'business:stock:get', {}).data.items[1] ~= nil, true)
        local stranger = pc(CUSTOMER, 'business:stock:get', {})
        assert_false(stranger and stranger.ok, 'not for someone outside the business')
    end)
    it('Premises asks pf-government for the restaurant, as the authenticated player', function()
        local gov = Mock.exportsByResource['pf-government']
        local asked
        gov.ListPremisesFor = function(_, src, id) asked = { src = src, id = id } return { ok = true, data = { slots = {} } } end
        gov.BuyPremisesEquipment = function(_, src, slotId, kind) asked = { src = src, slotId = slotId, kind = kind } return { ok = false, error = 'too_far' } end
        assert_true(pc(BOSS, 'business:premises:list', {}).ok)
        assert_eq(asked.src, BOSS)
        assert_eq(asked.id, 'restaurant:' .. BID)
        local buy = pc(BOSS, 'business:premises:buy', { slotId = 3, equipmentType = 'fridge_commercial' })
        assert_eq(buy.error, 'too_far')
        assert_eq(asked.slotId, 3)
        gov.ListPremisesFor, gov.BuyPremisesEquipment = nil, nil
    end)
end)

describe('4. kitchen and counter', function()
    it('cooking takes the delivered stock from the restaurant, not the cook', function()
        Mock.coords[BOSS] = GRILL
        Mock.fireNet('pf-restaurants:server:startStationAction', BOSS, BID, 'bs_grill_1', 1, { action = 'grill_bacon', inputItems = { { item = 'raw_bacon', qty = 2 } } })
        assert_eq(stash(StorageFor('raw_bacon'), 'raw_bacon'), 4)
        local ev = Mock.clientEventsNamed('pf-restaurants:client:stationSessionStart')
        local session = ev[#ev].args[4]
        Mock.clock = Mock.clock + 26
        Mock.fireNet('pf-restaurants:server:completeStationAction', BOSS, session.sessionId)
        assert_eq(exports['pfm-inventory']:GetItemCount(BOSS, 'bacon_cooked'), 2)
    end)
    it('a customer pays the server price; revenue to the restaurant, tax to the government', function()
        Mock.fireNet('pf-restaurants:server:createMenuItem', BOSS, BID, { recipeId = 'burger_classic', price = 10 })
        local menuId = next(RestaurantData.menus[BID])
        Mock.coords[BOSS] = REGISTER
        local before = society('restaurant_' .. BID)
        Mock.fireNet('pf-restaurants:server:createOrder', BOSS, BID, { items = { { menuItemId = menuId, qty = 2, price = 0.01 } }, paymentMethod = 'cash', customerId = CUSTOMER })
        local bill = Mock.clientEventsNamed('pf-restaurants:client:confirmPayment')[1].args[1]
        Mock.fireNet('pf-restaurants:server:answerPayment', CUSTOMER, bill.orderId, true)
        Mock.fireNet('pf-restaurants:server:answerPayment', CUSTOMER, bill.orderId, true)
        assert_eq(Mock.players[CUSTOMER].PlayerData.money.cash, 200 - 22, 'charged once at the server price')
        assert_eq(society('restaurant_' .. BID), before + 20)
        assert_eq(taxes['restaurant:' .. bill.orderId .. ':tax'], 2)
    end)
end)

describe('5. other paths', function()
    it('no trucker in time: the AI delivers, with a pallet, and no player is paid', function()
        fund(100)
        local res = pc(BOSS, 'business:supplies:orders:create', { mode = 'job', fulfillment = 'delivery', items = { { item = 'lettuce', quantity = 5 } } })
        assert_true(res.ok, tostring(res.error))
        local aid = res.data.orderId
        tick(121)                                   -- the player trucker window passes
        assert_true(order(aid).driver_kind == 'ai' or order(aid).status == 'in_transit', 'AI took it: ' .. tostring(order(aid).status))
        tick(301)                                   -- the AI drive
        assert_eq(order(aid).status, 'delivered')
        assert_true(pallet(aid) ~= nil)
        assert_eq(Mock.players[DRIVER].PlayerData.money.bank, 0)
        local tx = MySQL.single.await('SELECT * FROM pf_transactions WHERE idempotency_key = ?', { 'freight:supply:' .. aid })
        assert_eq(tx.to_account, 'system:pf-stores-freight')
    end)
    it('an order nobody has taken yet is cancelled from the computer with a full refund, once', function()
        fund(100)
        local before = society('restaurant_' .. BID)
        local res = pc(BOSS, 'business:supplies:orders:create', { mode = 'job', fulfillment = 'delivery', items = { { item = 'tomato', quantity = 3 } } })
        assert_true(res.ok, tostring(res.error))
        assert_true(pc(BOSS, 'business:supplies:orders:cancel', { mode = 'job', orderId = res.data.orderId }).ok)
        assert_eq(society('restaurant_' .. BID), before)
        assert_false(pc(BOSS, 'business:supplies:orders:cancel', { mode = 'job', orderId = res.data.orderId }).ok)
        assert_eq(society('restaurant_' .. BID), before, 'refunded once')
        assert_eq(order(res.data.orderId).status, 'cancelled')
    end)
    it('another restaurant boss sees none of these orders', function()
        local list = pc(RIVAL, 'business:supplies:orders:list', { mode = 'job' })
        for _, o in ipairs(list.data or {}) do assert_true(o.id ~= id, 'pizzathis sees burgershot orders') end
    end)
    it('with the bank down nothing is ordered and no money moves (fails closed)', function()
        fund(100)
        local before = society('restaurant_' .. BID)
        local orders = tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM pf_store_supply_orders'))
        local realState = GetResourceState
        GetResourceState = function(name) if name == 'pfm-banking' then return 'stopped' end return realState(name) end
        local res = pc(BOSS, 'business:supplies:orders:create', { mode = 'job', fulfillment = 'delivery', items = { { item = 'onion', quantity = 2 } } })
        GetResourceState = realState
        assert_false(res.ok)
        assert_eq(res.error, 'bank_unavailable')
        assert_eq(society('restaurant_' .. BID), before)
        assert_eq(tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM pf_store_supply_orders')), orders, 'no order row left behind')
    end)
    it('with the order service down a pallet cannot be unpacked, and stays sealed', function()
        fund(100)
        local res = pc(BOSS, 'business:supplies:orders:create', { mode = 'job', fulfillment = 'delivery', items = { { item = 'garlic', quantity = 2 } } })
        assert_true(res.ok, tostring(res.error))
        tick(121) tick(301)
        local p = pallet(res.data.orderId)
        assert_true(p ~= nil)
        Mock.coords[BOSS] = vector3(p.x, p.y, p.z)
        local realState = GetResourceState
        GetResourceState = function(name) if name == 'pf-stores' then return 'stopped' end return realState(name) end
        local un = PFWorldObjects.Unpack(BOSS, p.id)
        GetResourceState = realState
        assert_false(un.ok)
        assert_eq(pallet(res.data.orderId).state, 'sealed')
        assert_eq(order(res.data.orderId).status, 'delivered')
        assert_true(PFWorldObjects.Unpack(BOSS, p.id).ok, 'works again once it is back')
    end)
    it('a trucker cannot be paid while the bank is down, and is paid once when it is back', function()
        fund(100)
        local res = pc(BOSS, 'business:supplies:orders:create', { mode = 'job', fulfillment = 'delivery', items = { { item = 'potato', quantity = 4 } } })
        assert_true(res.ok, tostring(res.error))
        local oid = res.data.orderId
        assert_true(cb('pf-trucking:server:claimContract', DRIVER2, 'SUP-' .. oid).ok)
        Mock.coords[DRIVER2] = WAREHOUSE
        Mock.fireNet('pf-trucking:server:cargoLoaded', DRIVER2)
        Mock.coords[DRIVER2] = RECEIVING
        Mock.clock = Mock.clock + 900
        local realState = GetResourceState
        GetResourceState = function(name) if name == 'pfm-banking' then return 'stopped' end return realState(name) end
        local down = cb('pf-trucking:server:completeActiveJob', DRIVER2)
        GetResourceState = realState
        assert_false(down.ok, 'not completed without the bank')
        assert_eq(Mock.players[DRIVER2].PlayerData.money.bank, 0)
        assert_true(order(oid).status == 'in_transit', 'still in transit: ' .. tostring(order(oid).status))
        assert_true(cb('pf-trucking:server:completeActiveJob', DRIVER2).ok)
        local pay = Mock.players[DRIVER2].PlayerData.money.bank
        assert_true(pay > 0)
        assert_false(cb('pf-trucking:server:completeActiveJob', DRIVER2).ok)
        assert_eq(Mock.players[DRIVER2].PlayerData.money.bank, pay, 'paid once')
        assert_eq(order(oid).status, 'delivered')
    end)
    it('every account reconciles with the ledger', function()
        local report = PFLedger.Reconcile()
        assert_eq(#(report.mismatches or {}), 0)
    end)
end)
