-- The shared supply order service end to end on a real database: pf-stores (orders, suppliers),
-- pf-trucking (contracts), pfm-banking (ledger, escrow), pfm-inventory (stashes) and pfm-worldobjects
-- (delivery pallets), all running their real code in one Lua VM.
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
for _, res in ipairs({ 'pfm-banking', 'pfm-inventory', 'pf-stores', 'pf-trucking', 'pfm-worldobjects' }) do
    Mock.exportsByResource[res] = Mock.exportsByResource['__self']
end

local L, O, W = PFLedger, PFOrders, PFWorldObjects
local OWNER, SHOPPER, DRIVER, DRIVER2, SUPP = 1, 2, 3, 4, 5
local PICKUP, DROP = vector3(0.0, 0.0, 0.0), vector3(3000.0, 0.0, 0.0)
local CART = { { name = 'lockpick', quantity = 50 } }   -- 50 x 20 = 1000; freight 250; AI markup 150

assert(L.Start(), 'ledger start')
assert(O.Start(), 'order service start')
assert(W.Start(), 'world objects start')
MySQL.query.await("INSERT INTO pf_stores (store_id, label, store_type, owner_citizenid, purchased_at) VALUES ('corner', 'Corner Store', 'purchasable', 'OWN1', 1)")
for src, cid in pairs({ [OWNER] = 'OWN1', [SHOPPER] = 'SHOP1', [DRIVER] = 'DRV1', [DRIVER2] = 'DRV2', [SUPP] = 'SUP1' }) do
    MySQL.query.await("INSERT INTO players (citizenid, cid, license, name, money, charinfo, job, gang, position, metadata, inventory) VALUES (?, 1, ?, ?, '{\"cash\":0,\"bank\":0}', '{}', '{}', '{}', '{}', '{}', '[]')", { cid, 'license:' .. cid, cid })
end

local function players()
    Mock.players = {}
    for src, cid in pairs({ [OWNER] = 'OWN1', [SHOPPER] = 'SHOP1', [DRIVER] = 'DRV1', [DRIVER2] = 'DRV2', [SUPP] = 'SUP1' }) do
        local p = Mock.newPlayer(src, cid)
        p.PlayerData.money = { cash = 0, bank = 0 }
        p.PlayerData.items = {}
        p.Functions.GetMoney = function(kind) return p.PlayerData.money[kind] or 0 end
    end
end

local function society(name) return tonumber(MySQL.scalar.await('SELECT account_balance FROM bank_accounts WHERE account_name = ?', { name })) or 0 end
local function stock(item) return tonumber(MySQL.scalar.await("SELECT stock_cases FROM pf_store_supply_stock WHERE store_id = 'corner' AND supply_name = ?", { item })) or 0 end
local function status(id) return O.Get(id).status end
local function cb(name, src, ...) return Mock.callCallback(name, src, ...) end
local function order(cart, method) return O.Create(OWNER, { kind = 'store', buyerId = 'corner', method = method or 'trucking', cart = cart or CART }) end
local function fundStore(amount)
    assert(L.EnsureSociety('store_corner', 'business'))
    assert(L.Transfer({ from = 'system:test', to = 'society:store_corner', amount = amount, key = L.AutoKey('fund'), kind = 'test' }).ok)
end
local function tick(seconds) Mock.clock = Mock.clock + (seconds or 0); O.Tick() end
local function pallet(orderId) return MySQL.single.await('SELECT * FROM pf_world_objects WHERE order_id = ?', { orderId }) end

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 10000
    Mock.gameTimer = Mock.gameTimer + 100000
    players()
    Mock.coords = { [OWNER] = DROP, [SHOPPER] = DROP, [DRIVER] = PICKUP, [DRIVER2] = PICKUP, [SUPP] = DROP }
end

describe('ordering', function()
    it('a business order is priced by the server and its payment held in escrow', function()
        fundStore(5000)
        local res = order({ { name = 'lockpick', quantity = 50, cost = 0.01, price = 0.01 } })
        assert_true(res.ok, tostring(res.error))
        local o = O.Get(res.data.orderId)
        assert_eq(tonumber(o.subtotal), 1000)
        assert_eq(tonumber(o.ai_markup), 150)
        assert_eq(tonumber(o.total), 1150)
        assert_eq(tonumber(o.freight_payout), 250)
        assert_eq(o.status, 'awaiting_delivery')
        assert_eq(society('store_corner'), 3850)
        assert_eq(society('freight_escrow'), 1150)
        local history = Mock.selfExport('GetOrderHistory')(o.id)
        local seen = {}
        for _, h in ipairs(history) do seen[#seen + 1] = h.to_status end
        assert_eq(table.concat(seen, ','), 'created,paid,awaiting_supplier,awaiting_delivery')
        assert_true(O.Cancel(OWNER, 'store', 'corner', o.id).ok)
    end)
    it('only the owner can order, and an unfunded store gets a failed order and pays nothing', function()
        assert_eq(O.Create(SHOPPER, { kind = 'store', buyerId = 'corner', method = 'trucking', cart = CART }).error, 'not_owner')
        -- empty the store's account first
        local balance = society('store_corner')
        if balance > 0 then assert_true(L.Transfer({ from = 'society:store_corner', to = 'system:test', amount = balance, key = L.AutoKey('drain'), kind = 'test' }).ok) end
        local before = society('store_corner')
        local res = order({ { name = 'lockpick', quantity = 100 } }, 'trucking')   -- costs 2300, the store has less
        assert_true(before < 2300)
        assert_false(res.ok)
        assert_eq(res.error, 'insufficient_funds')
        assert_eq(status(MySQL.scalar.await('SELECT MAX(id) FROM pf_store_supply_orders')), 'failed')
        assert_eq(society('store_corner'), before)
    end)
end)

describe('player trucker delivery', function()
    local id
    it('a player claims the contract first; nobody else can', function()
        fundStore(1150)
        id = order().data.orderId
        assert_true(cb('pf-trucking:server:claimContract', DRIVER, 'SUP-' .. id).ok)
        assert_eq(status(id), 'assigned')
        assert_false(cb('pf-trucking:server:claimContract', DRIVER2, 'SUP-' .. id).ok)
    end)
    it('loading at the pickup puts it in transit', function()
        Mock.fireNet('pf-trucking:server:cargoLoaded', DRIVER)
        assert_eq(status(id), 'in_transit')
    end)
    it('arriving pays the driver once and delivers a sealed pallet', function()
        Mock.coords[DRIVER] = DROP
        Mock.clock = Mock.clock + 600
        assert_true(cb('pf-trucking:server:completeActiveJob', DRIVER).ok)
        assert_eq(Mock.players[DRIVER].PlayerData.money.bank, 250)
        assert_false(cb('pf-trucking:server:completeActiveJob', DRIVER).ok)
        assert_eq(Mock.players[DRIVER].PlayerData.money.bank, 250, 'paid once')
        local o = O.Get(id)
        assert_eq(o.status, 'delivered')
        assert_eq(tonumber(o.settled), 1)
        assert_eq(society('freight_escrow'), 0, 'escrow fully paid out: driver 250, supplier 750, AI markup 150')
        local p = pallet(id)
        assert_true(p ~= nil and p.state == 'sealed')
        local inv = Mock.selfExport('GetInventory')(p.stash_id)
        local crates = 0
        for _, it in pairs(inv.items) do if it.name == 'supply_crate' then crates = crates + 1 end end
        assert_eq(crates, 1)
        local saved = MySQL.scalar.await('SELECT items FROM inventories WHERE identifier = ?', { p.stash_id })
        assert_true(saved ~= nil and saved:find('supply_crate') ~= nil, 'stash saved to the database')
        assert_eq(stock('lockpick'), 0, 'not stock until unpacked')
    end)
    it('sealed crates cannot be taken out of the pallet', function()
        local p = pallet(id)
        Mock.coords[OWNER] = vector3(p.x, p.y, p.z)
        Mock.fireNet('pfm-worldobjects:server:open', OWNER, p.id)
        local inv = Mock.selfExport('GetInventory')(p.stash_id)
        assert_eq(inv.isOpen, OWNER)
        local slot = next(inv.items)
        Mock.fireNet('qb-inventory:server:SetInventoryData', OWNER, p.stash_id, 'player', slot, 1, 1, 1)
        assert_true(inv.items[slot] ~= nil and inv.items[slot].name == 'supply_crate', 'still in the pallet')
        Mock.fireNet('qb-inventory:server:closeInventory', OWNER, p.stash_id)
    end)
    it('only the owner, next to it, can unpack; once', function()
        local p = pallet(id)
        assert_false(W.Unpack(SHOPPER, p.id).ok)
        Mock.coords[OWNER] = vector3(900.0, 900.0, 0.0)
        assert_eq(W.Unpack(OWNER, p.id).error, 'too_far')
        Mock.coords[OWNER] = vector3(p.x, p.y, p.z)
        local unpacked = W.Unpack(OWNER, p.id)
        assert_true(unpacked.ok, tostring(unpacked.error))
        assert_eq(stock('lockpick'), 50)
        assert_false(W.Unpack(OWNER, p.id).ok)
        assert_eq(stock('lockpick'), 50, 'stock added once')
        assert_eq(status(id), 'unpacked')
        assert_eq(pallet(id).state, 'unpacked')
    end)
end)

describe('AI fallback', function()
    it('no player trucker in time: an AI driver delivers, paid once under the same key', function()
        fundStore(1150)
        local id = order().data.orderId
        tick(121)
        assert_eq(status(id), 'in_transit')
        assert_false(cb('pf-trucking:server:claimContract', DRIVER, 'SUP-' .. id).ok, 'gone from the pool')
        tick(301)
        assert_eq(status(id), 'delivered')
        local tx = MySQL.single.await('SELECT * FROM pf_transactions WHERE idempotency_key = ?', { 'freight:supply:' .. id })
        assert_eq(tx.to_account, 'system:pf-stores-freight')
        assert_true(pallet(id) ~= nil)
    end)
end)

describe('player suppliers', function()
    it('a registered supplier with stock is offered the order first and earns from it', function()
        assert_true(O.RegisterSupplier(SUPP, 'Farm Fresh').ok)
        assert_true(O.SetOffer(SUPP, 'lockpick', 20).ok)
        assert_true(Mock.selfExport('AddItem')(SUPP, 'lockpick', 60, false, false, 'test'))
        assert_true(O.DepositStock(SUPP, 'lockpick', 60).ok)
        assert_eq(O.DepositStock(SUPP, 'lockpick', 60).error, 'missing_items', 'only goods they really have')
        fundStore(1150)
        local before = society('store_corner')
        local id = order().data.orderId
        assert_eq(status(id), 'awaiting_supplier')
        assert_eq(#O.OpenOffersFor(SUPP).data, 1)
        assert_true(O.AcceptSupply(SUPP, id).ok)
        assert_false(O.AcceptSupply(SUPP, id).ok, 'accepted once')
        assert_eq(tonumber(MySQL.scalar.await("SELECT stock_qty FROM pf_supplier_offers WHERE item = 'lockpick'")), 10)
        assert_eq(Mock.players[SUPP].PlayerData.money.bank, 75, 'half the AI markup')
        assert_eq(society('store_corner'), before - 1150 + 75, 'the other half back to the store')
        tick(121); tick(301)
        assert_eq(status(id), 'delivered')
        assert_eq(Mock.players[SUPP].PlayerData.money.bank, 75 + 750, 'goods share to the player supplier')
    end)
    it('if no supplier accepts in time, the AI supplier fills it', function()
        assert_true(Mock.selfExport('AddItem')(SUPP, 'lockpick', 50, false, false, 'test'))
        assert_true(O.DepositStock(SUPP, 'lockpick', 50).ok)
        fundStore(1150)
        local id = order().data.orderId
        assert_eq(status(id), 'awaiting_supplier')
        tick(61)
        assert_eq(status(id), 'awaiting_delivery')
        assert_eq(O.Get(id).supplier_kind, 'ai')
        assert_true(O.Cancel(OWNER, 'store', 'corner', id).ok)
    end)
end)

describe('cancellation', function()
    it('an unclaimed order is refunded in full, once; a claimed one cannot be cancelled', function()
        MySQL.update.await('UPDATE pf_supplier_offers SET stock_qty = 0')   -- no player supplier this time
        fundStore(1150)
        local before = society('store_corner')
        local id = order().data.orderId
        assert_true(O.Cancel(OWNER, 'store', 'corner', id).ok)
        assert_eq(society('store_corner'), before)
        assert_false(O.Cancel(OWNER, 'store', 'corner', id).ok)
        assert_eq(society('store_corner'), before)
        assert_false(cb('pf-trucking:server:claimContract', DRIVER, 'SUP-' .. id).ok)
        fundStore(1150)
        local id2 = order().data.orderId
        local claim = cb('pf-trucking:server:claimContract', DRIVER, 'SUP-' .. id2)
        assert_true(claim.ok, tostring(claim.error))
        assert_eq(O.Cancel(OWNER, 'store', 'corner', id2).error, 'not_cancellable')
        assert_eq(O.Cancel(SHOPPER, 'store', 'corner', id2).error, 'not_owner')
    end)
end)

describe('pickup and small orders', function()
    it('a pickup order pays the supplier directly and stocks the store at once, once', function()
        fundStore(40)
        local before = stock('sandwich')
        local res = order({ { name = 'sandwich', quantity = 10 } }, 'pickup')   -- 10 x 4, no markup
        assert_true(res.ok, tostring(res.error))
        assert_eq(status(res.data.orderId), 'unpacked')
        assert_eq(stock('sandwich'), before + 10)
        assert_false(Mock.selfExport('DeliverSupplyOrder')(OWNER, { storeId = 'corner', orderId = res.data.orderId }).ok)
        assert_eq(stock('sandwich'), before + 10)
    end)
    it('a deferred pickup is collected once', function()
        fundStore(40)
        local res = O.Create(OWNER, { kind = 'store', buyerId = 'corner', method = 'pickup', cart = { { name = 'sandwich', quantity = 10 } }, deferDelivery = true })
        assert_eq(status(res.data.orderId), 'ready')
        local before = stock('sandwich')
        assert_true(Mock.selfExport('DeliverSupplyOrder')(OWNER, { storeId = 'corner', orderId = res.data.orderId }).ok)
        assert_false(Mock.selfExport('DeliverSupplyOrder')(OWNER, { storeId = 'corner', orderId = res.data.orderId }).ok)
        assert_eq(stock('sandwich'), before + 10)
    end)
    it('the trucker pay never exceeds a small order, and a delivery order cannot be self-delivered', function()
        MySQL.update.await('UPDATE pf_supplier_offers SET stock_qty = 0')
        fundStore(46)
        local res = order({ { name = 'sandwich', quantity = 10 } })              -- 40, freight capped to 40, markup 6
        assert_true(res.ok, tostring(res.error))
        local o = O.Get(res.data.orderId)
        assert_eq(tonumber(o.freight_payout), 40)
        assert_eq(Mock.selfExport('DeliverSupplyOrder')(OWNER, { storeId = 'corner', orderId = o.id }).error, 'delivered_by_trucking')
        assert_true(O.Cancel(OWNER, 'store', 'corner', o.id).ok)
    end)
end)

describe('work trucks', function()
    it('the rental fee comes out of the escrowed pay, and re-claiming does not take it twice', function()
        MySQL.update.await('UPDATE pf_supplier_offers SET stock_qty = 0')
        fundStore(1150)
        local id = order().data.orderId
        Mock.coords[DRIVER2] = vector3(0.0, 0.0, 0.0)
        assert_true(cb('pf-trucking:server:requestWorkTruck', DRIVER2).ok)
        assert_true(cb('pf-trucking:server:claimContract', DRIVER2, 'SUP-' .. id).ok)
        cb('pf-trucking:server:cancelActiveJob', DRIVER2)
        assert_eq(status(id), 'awaiting_delivery', 'released back')
        assert_true(cb('pf-trucking:server:requestWorkTruck', DRIVER2).ok)
        local claim = cb('pf-trucking:server:claimContract', DRIVER2, 'SUP-' .. id)
        assert_eq(claim.job.payoutNet, 150)
        Mock.fireNet('pf-trucking:server:cargoLoaded', DRIVER2)
        Mock.clock = Mock.clock + 600
        Mock.coords[DRIVER2] = DROP
        assert_true(cb('pf-trucking:server:markDelivered', DRIVER2).ok)
        Mock.coords[DRIVER2] = vector3(5.0, 0.0, 0.0)
        assert_true(cb('pf-trucking:server:completeDeliveredJob', DRIVER2).ok)
        assert_eq(Mock.players[DRIVER2].PlayerData.money.bank, 150, '250 less the 100 rental')
        assert_eq(status(id), 'delivered')
    end)
end)

describe('restarts', function()
    it('a claimed contract comes back to its driver after pf-trucking restarts', function()
        local id = tonumber(MySQL.scalar.await("SELECT MAX(id) FROM pf_store_supply_orders WHERE status = 'assigned'"))
        assert_true(id ~= nil)
        load_resource('[pfscripts]/pf-trucking/server.lua')   -- fresh contract pool, as after a restart
        Mock.exportsByResource['pf-trucking'] = Mock.exportsByResource['__self']
        TriggerEvent('pf-trucking:server:started')
        assert_false(cb('pf-trucking:server:claimContract', DRIVER2, 'SUP-' .. id).ok, 'still the first driver\'s')
        Mock.coords[DRIVER] = DROP
        Mock.clock = Mock.clock + 600
        assert_true(cb('pf-trucking:server:completeActiveJob', DRIVER).ok, 'the driver can finish it')
        assert_eq(status(id), 'delivered')
    end)
    it('an order interrupted before its payment is failed, not left hanging', function()
        MySQL.query.await("INSERT INTO pf_store_supply_orders (store_id, buyer_kind, owner_citizenid, method, status, total, items_json, created_at) VALUES ('corner', 'store', 'OWN1', 'trucking', 'created', 10, '[]', ?)", { (Mock.clock - 3600) * 1000 })
        local id = tonumber(MySQL.scalar.await('SELECT MAX(id) FROM pf_store_supply_orders'))
        O.RecoverPayments()
        assert_eq(status(id), 'failed')
    end)
    it('pallets come back at their saved place after a restart, each with its own stash', function()
        local rows = MySQL.query.await("SELECT id, stash_id FROM pf_world_objects WHERE state = 'sealed'")
        assert_true(#rows >= 2)
        local seen = {}
        for _, r in ipairs(rows) do
            assert_eq(seen[r.stash_id], nil, 'stash ids are unique')
            seen[r.stash_id] = true
        end
        W.entities = {}
        assert_true(W.Start())
        for _, r in ipairs(rows) do assert_true(W.entities[r.id] ~= nil, 'respawned ' .. r.id) end
    end)
end)

describe('books', function()
    it('the ledger reconciles after all of it', function()
        local report = L.Reconcile()
        for _, m in ipairs(report.mismatches) do print('mismatch', m.account, m.expected, m.actual) end
        assert_eq(#report.mismatches, 0)
    end)
end)
