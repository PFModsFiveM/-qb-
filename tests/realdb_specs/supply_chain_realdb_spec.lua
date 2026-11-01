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
local CART = { { name = 'lockpick', quantity = 50 } }   -- 50 x 20 = 1000 goods + AI markup 150 + freight 250 on top = 1400

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
        assert_eq(tonumber(o.freight_payout), 250)
        assert_eq(tonumber(o.total), 1400, 'the buyer pays the freight on top of the goods and the markup')
        assert_eq(res.data.freight, 250)
        assert_eq(o.status, 'awaiting_delivery')
        assert_eq(society('store_corner'), 3600)
        assert_eq(society('freight_escrow'), 1400)
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
        local res = order({ { name = 'lockpick', quantity = 100 } }, 'trucking')   -- costs 2000 + 300 + 250, the store has less
        assert_true(before < 2550)
        assert_false(res.ok)
        assert_eq(res.error, 'insufficient_funds')
        assert_eq(status(MySQL.scalar.await('SELECT MAX(id) FROM pf_store_supply_orders')), 'failed')
        assert_eq(society('store_corner'), before)
    end)
end)

describe('player trucker delivery', function()
    local id
    it('a player claims the contract first; nobody else can', function()
        fundStore(1400)
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
        assert_eq(society('freight_escrow'), 0, 'escrow fully paid out: driver 250, supplier 1000, AI markup 150')
        local supplierTx = MySQL.single.await('SELECT * FROM pf_transactions WHERE idempotency_key = ?', { 'supply:' .. id .. ':supplier' })
        assert_eq(tonumber(supplierTx.amount), 1000, 'the supplier gets the full goods value')
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
        fundStore(1400)
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
        fundStore(1400)
        local before = society('store_corner')
        local id = order().data.orderId
        assert_eq(status(id), 'awaiting_supplier')
        assert_eq(#O.OpenOffersFor(SUPP).data, 1)
        assert_true(O.AcceptSupply(SUPP, id).ok)
        assert_false(O.AcceptSupply(SUPP, id).ok, 'accepted once')
        assert_eq(tonumber(MySQL.scalar.await("SELECT stock_qty FROM pf_supplier_offers WHERE item = 'lockpick'")), 10)
        -- nothing is paid at accept: the markup stays in escrow until the order is delivered
        assert_eq(Mock.players[SUPP].PlayerData.money.bank, 0, 'no bonus before delivery')
        assert_eq(society('store_corner'), before - 1400, 'no markup refund before delivery either')
        tick(121); tick(301)
        assert_eq(status(id), 'delivered')
        assert_eq(Mock.players[SUPP].PlayerData.money.bank, 1000 + 75, 'the full goods value and half the AI markup to the player supplier')
        assert_eq(society('store_corner'), before - 1400 + 75, 'the other half of the markup back to the store')
        assert_eq(society('freight_escrow'), 0)
    end)
    it('food is stocked only while fresh: stale or spoiled food is refused and kept by the supplier', function()
        assert_true(O.RegisterSupplier(SUPP, 'Farm Fresh').ok)
        assert_true(O.SetOffer(SUPP, 'sandwich', 4).ok)
        local life = 12 * 3600
        local function aged(share)
            return { fresh = { v = 1, batch = 'Btest-' .. share, cat = 'prepared', life = life, used = math.floor(life * share), at = os.time(), storage = 'person' } }
        end
        assert_true(Mock.selfExport('AddItem')(SUPP, 'sandwich', 5, false, aged(0.9), 'test'))   -- stale (10 % left)
        assert_eq(O.DepositStock(SUPP, 'sandwich', 3).error, 'not_fresh_enough')
        assert_eq(Mock.selfExport('GetItemCount')(SUPP, 'sandwich'), 5, 'nothing taken')
        assert_true(Mock.selfExport('AddItem')(SUPP, 'sandwich', 4, false, aged(0.1), 'test'))   -- fresh
        assert_true(O.DepositStock(SUPP, 'sandwich', 4).ok)
        assert_eq(Mock.selfExport('GetItemCount')(SUPP, 'sandwich'), 5, 'only the fresh ones went into stock')
        assert_eq(tonumber(MySQL.scalar.await("SELECT stock_qty FROM pf_supplier_offers WHERE item = 'sandwich'")), 4)
        MySQL.update.await("DELETE FROM pf_supplier_offers WHERE item = 'sandwich'")
    end)
    it('if no supplier accepts in time, the AI supplier fills it', function()
        assert_true(Mock.selfExport('AddItem')(SUPP, 'lockpick', 50, false, false, 'test'))
        assert_true(O.DepositStock(SUPP, 'lockpick', 50).ok)
        fundStore(1400)
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
        fundStore(1400)
        local before = society('store_corner')
        local id = order().data.orderId
        assert_true(O.Cancel(OWNER, 'store', 'corner', id).ok)
        assert_eq(society('store_corner'), before)
        assert_false(O.Cancel(OWNER, 'store', 'corner', id).ok)
        assert_eq(society('store_corner'), before)
        assert_false(cb('pf-trucking:server:claimContract', DRIVER, 'SUP-' .. id).ok)
        fundStore(1400)
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
    it('a small delivery pays the trucker\'s minimum on top of the goods, and a delivery order cannot be self-delivered', function()
        MySQL.update.await('UPDATE pf_supplier_offers SET stock_qty = 0')
        Config.SupplyChain.MinDeliveryGoods = 0                                -- the owner turned the minimum off
        fundStore(296)
        local before = society('store_corner')
        local res = order({ { name = 'sandwich', quantity = 10 } })              -- goods 40 + markup 6 + freight 250 (the minimum)
        Config.SupplyChain.MinDeliveryGoods = nil
        assert_true(res.ok, tostring(res.error))
        local o = O.Get(res.data.orderId)
        assert_eq(tonumber(o.freight_payout), 250, 'the minimum, not capped at the goods value')
        assert_eq(tonumber(o.total), 296)
        assert_eq(society('store_corner'), before - 296)
        assert_eq(Mock.selfExport('DeliverSupplyOrder')(OWNER, { storeId = 'corner', orderId = o.id }).error, 'delivered_by_trucking')
        local cancelled = O.Cancel(OWNER, 'store', 'corner', o.id)
        assert_true(cancelled.ok)
        assert_eq(cancelled.data.refunded, 296, 'refunded in full, freight included')
        assert_eq(society('store_corner'), before)
    end)
end)

describe('work trucks', function()
    it('the rental fee comes out of the escrowed pay, and re-claiming does not take it twice', function()
        MySQL.update.await('UPDATE pf_supplier_offers SET stock_qty = 0')
        fundStore(1400)
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
    it('pf-trucking starting before pf-stores has migrated does not query the order table yet', function()
        -- seen on staging: pf-trucking started first and its event ran a query for columns the
        -- pf-stores migration had not added yet; pf-stores recovers contracts itself after migrating
        local recovered, orig = 0, O.RecoverContracts
        O.RecoverContracts = function() recovered = recovered + 1 return 0 end
        O.ready = false
        TriggerEvent('pf-trucking:server:started')
        O.ready = true
        TriggerEvent('pf-trucking:server:started')
        O.RecoverContracts = orig
        assert_eq(recovered, 1)
    end)
    it('a claimed contract comes back to its driver after pf-trucking restarts', function()
        local id = tonumber(MySQL.scalar.await("SELECT MAX(id) FROM pf_store_supply_orders WHERE status = 'assigned'"))
        assert_true(id ~= nil)
        load_resource('[pfscripts]/pf-trucking/server.lua')   -- fresh contract pool, as after a restart
        Mock.exportsByResource['pf-trucking'] = Mock.exportsByResource['__self']
        TriggerEvent('pf-trucking:server:started')
        assert_false(cb('pf-trucking:server:claimContract', DRIVER2, 'SUP-' .. id).ok, 'still the first driver\'s')
        Mock.coords[DRIVER] = PICKUP                                -- not loaded before the restart: load it
        Mock.fireNet('pf-trucking:server:cargoLoaded', DRIVER)
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

describe('cancellation refunds on the real ledger', function()
    it('a refund the ledger refused is retried under a new key after its wait, and paid once', function()
        MySQL.update.await('UPDATE pf_supplier_offers SET stock_qty = 0')
        fundStore(1400)
        local escrowBefore = society('freight_escrow')
        local id = order().data.orderId
        assert_eq(society('freight_escrow'), escrowBefore + 1400)
        -- the account the refund goes to does not exist (yet): the ledger stores the refusal
        MySQL.update.await("UPDATE pf_store_supply_orders SET buyer_ref = 'society:store_moved' WHERE id = ?", { id })
        local res = O.Cancel(OWNER, 'store', 'corner', id)
        assert_true(res.ok, tostring(res.error))
        assert_true(res.data.refundPending, 'cancelled, refund still owed')
        local first = L.GetTransaction('supply:' .. id .. ':cancel')
        assert_true(first ~= nil and first.state ~= 'completed', 'the first key failed: ' .. tostring(first and first.state))
        assert_eq(O.Get(id).refund_state, 'pending')
        assert_eq(society('freight_escrow'), escrowBefore + 1400, 'the money stays in escrow')
        assert_true(L.EnsureSociety('store_moved', 'business'))
        tick(5)
        assert_eq(society('store_moved'), 0, 'not before the retry wait')
        tick(11)
        assert_eq(society('store_moved'), 1400, 'refunded by the order timer')
        assert_eq(L.GetTransaction('supply:' .. id .. ':cancel:1').state, 'completed', 'under a new key')
        assert_eq(O.Get(id).refund_state, 'done')
        assert_eq(tonumber(O.Get(id).refund_attempt), 1)
        tick(3600)
        O.RecoverPayments()
        assert_eq(society('store_moved'), 1400, 'once')
        assert_eq(society('freight_escrow'), escrowBefore)
    end)
    it('migration 3: an older cancelled order whose refund never reached the ledger is owed and refunded once', function()
        fundStore(200)
        local escrowBefore = society('freight_escrow')
        local function oldCancelled()
            local oid = MySQL.insert.await([[INSERT INTO pf_store_supply_orders (store_id, buyer_kind, buyer_ref, owner_citizenid, method, status,
                total, subtotal, ai_markup, freight_payout, items_json, created_at, payment_state)
                VALUES ('corner', 'store', 'society:store_corner', 'OWN1', 'trucking', 'cancelled', 100, 80, 12, 8, '[]', ?, 'paid')]], { Mock.clock * 1000.0 })
            assert_true(L.Transfer({ from = 'society:store_corner', to = 'society:freight_escrow', amount = 100, key = ('supply:%d:charge'):format(oid), kind = 'supplies' }).ok)
            return oid
        end
        local owed, refunded = oldCancelled(), oldCancelled()
        assert_true(L.Transfer({ from = 'society:freight_escrow', to = 'society:store_corner', amount = 100, key = ('supply:%d:cancel'):format(refunded), kind = 'refund' }).ok)
        assert_true(O.Migrations[3].up() == nil)
        assert_eq(O.Get(owed).refund_state, 'pending', 'its refund never went through')
        assert_eq(O.Get(refunded).refund_state, nil, 'already refunded: nothing owed')
        local before = society('store_corner')
        O.RecoverPayments()
        assert_eq(society('store_corner'), before + 100)
        assert_eq(O.Get(owed).refund_state, 'done')
        O.Migrations[3].up()
        O.RecoverPayments()
        assert_eq(society('store_corner'), before + 100, 'rerun-safe')
        assert_eq(society('freight_escrow'), escrowBefore)
    end)
end)

-- Batch 13b: payouts from escrow under numbered keys, payees gone for good, the delivery minimum.
describe('settlement and refunds when the bank refuses, on the real ledger', function()
    local function escrowOut(id)
        return tonumber(MySQL.scalar.await([[SELECT COALESCE(SUM(amount), 0) FROM pf_transactions WHERE from_account = 'society:freight_escrow'
            AND state = 'completed' AND (idempotency_key LIKE ? OR idempotency_key LIKE ?)]], { ('supply:%d:%%'):format(id), ('freight:supply:%d%%'):format(id) })) or 0
    end
    local function rowsFor(id)
        return tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM pf_transactions WHERE idempotency_key LIKE ? OR idempotency_key LIKE ?',
            { ('supply:%d:%%'):format(id), ('freight:supply:%d%%'):format(id) })) or 0
    end
    local function txState(k) local tx = L.GetTransaction(k) return tx and tx.state end

    it('a payout refused by a short escrow is paid under the next key once the money is back', function()
        MySQL.update.await('UPDATE pf_supplier_offers SET stock_qty = 0')
        fundStore(1400)
        local id = order().data.orderId
        tick(121)
        assert_eq(status(id), 'in_transit', 'an AI driver')
        -- the escrow account is short (someone took money out of it)
        local drained = society('freight_escrow') - 300
        assert_true(L.Transfer({ from = 'society:freight_escrow', to = 'system:test', amount = drained, key = L.AutoKey('drain'), kind = 'test' }).ok)
        tick(301)
        assert_eq(status(id), 'delivered', 'the freight (250) could still be paid')
        assert_eq(txState('supply:' .. id .. ':supplier'), 'failed')
        assert_eq(tonumber(O.Get(id).settled), 0)
        assert_true(L.Transfer({ from = 'system:test', to = 'society:freight_escrow', amount = drained, key = L.AutoKey('refill'), kind = 'test' }).ok)
        tick(5)
        assert_eq(txState('supply:' .. id .. ':supplier:1'), nil, 'not before its wait')
        tick(11)
        assert_eq(txState('supply:' .. id .. ':supplier:1'), 'completed', 'under the next key')
        assert_eq(txState('supply:' .. id .. ':markup:1'), 'completed')
        assert_eq(tonumber(O.Get(id).settled), 1)
        assert_eq(escrowOut(id), 1400, 'escrow paid out exactly what the order put in')
        local n = rowsFor(id)
        tick(3601)
        assert_eq(rowsFor(id), n, 'paid once')
    end)
    it('a deleted supplier\'s goods share and bonus go back to the store after 5 refusals; the sweep stops', function()
        MySQL.update.await('UPDATE pf_supplier_offers SET stock_qty = 0')
        MySQL.query.await("INSERT INTO players (citizenid, cid, license, name, money, charinfo, job, gang, position, metadata, inventory) VALUES ('SUPGONE', 1, 'license:SUPGONE', 'SUPGONE', '{\"cash\":0,\"bank\":0}', '{}', '{}', '{}', '{}', '{}', '[]')")
        local GONE = 6
        local p = Mock.newPlayer(GONE, 'SUPGONE')
        p.PlayerData.money = { cash = 0, bank = 0 }
        p.PlayerData.items = {}
        p.Functions.GetMoney = function(kind) return p.PlayerData.money[kind] or 0 end
        Mock.coords[GONE] = DROP
        assert_true(O.RegisterSupplier(GONE, 'Gone Farm').ok)
        assert_true(O.SetOffer(GONE, 'lockpick', 20).ok)
        assert_true(Mock.selfExport('AddItem')(GONE, 'lockpick', 50, false, false, 'test'))
        assert_true(O.DepositStock(GONE, 'lockpick', 50).ok)
        fundStore(1400)
        local id = order().data.orderId
        assert_true(O.AcceptSupply(GONE, id).ok)
        -- the supplier's character is deleted before the delivery
        Mock.players[GONE] = nil
        MySQL.query.await("DELETE FROM players WHERE citizenid = 'SUPGONE'")
        tick(121); tick(301)
        assert_eq(status(id), 'delivered')
        local first = L.GetTransaction('supply:' .. id .. ':supplier')
        assert_eq(first.state, 'compensated')
        assert_eq(first.error, 'unknown_account')
        for _, wait in ipairs({ 16, 31, 61, 121 }) do tick(wait) end
        assert_eq(txState('supply:' .. id .. ':supplier:4'), 'compensated', 'five refusals, five keys')
        assert_eq(txState('supply:' .. id .. ':supplier:buyer'), nil, 'not given up on before the fifth')
        tick(241)
        local back = L.GetTransaction('supply:' .. id .. ':supplier:buyer')
        assert_eq(back.state, 'completed')
        assert_eq(back.to_account, 'society:store_corner')
        assert_eq(tonumber(back.amount), 1000)
        assert_eq(tonumber(L.GetTransaction('supply:' .. id .. ':markup-supplier:buyer').amount), 75)
        assert_eq(tonumber(O.Get(id).settled), 1)
        local rec = MySQL.single.await("SELECT * FROM pf_supply_order_payouts WHERE order_id = ? AND part = 'supplier'", { id })
        assert_eq(rec.outcome, 'returned')
        assert_eq(rec.payee, 'player:SUPGONE:bank')
        assert_eq(rec.paid_to, 'society:store_corner')
        assert_eq(escrowOut(id), 1400, 'escrow paid out exactly what the order put in: freight, goods and markup')
        local n = rowsFor(id)
        tick(3601); tick(3601)
        assert_eq(rowsFor(id), n, 'the sweep stopped')
        MySQL.update.await("DELETE FROM pf_suppliers WHERE citizenid = 'SUPGONE'")
    end)
    it('a cancellation refund to an account gone for good is forfeited after 5 refusals: held in escrow, recorded', function()
        MySQL.update.await('UPDATE pf_supplier_offers SET stock_qty = 0')
        fundStore(1400)
        local id = order().data.orderId
        MySQL.update.await("UPDATE pf_store_supply_orders SET buyer_ref = 'society:store_gone' WHERE id = ?", { id })
        local res = O.Cancel(OWNER, 'store', 'corner', id)
        assert_true(res.ok)
        assert_true(res.data.refundPending)
        for _, wait in ipairs({ 16, 31, 61, 121 }) do tick(wait) end
        assert_eq(O.Get(id).refund_state, 'pending')
        tick(241)
        assert_eq(O.Get(id).refund_state, 'forfeited')
        local rec = MySQL.single.await("SELECT * FROM pf_supply_order_payouts WHERE order_id = ? AND part = 'cancel'", { id })
        assert_eq(rec.outcome, 'held')
        assert_eq(tonumber(rec.amount), 1400)
        assert_eq(escrowOut(id), 0, 'still in escrow')
        local held = exports['pf-stores']:ListUnpaidSupplyPayouts('held')
        assert_true(#held >= 1 and tonumber(held[1].order_id) == id, 'listed for staff')
        local n = rowsFor(id)
        tick(3601); tick(3601)
        O.RecoverPayments()
        assert_eq(rowsFor(id), n, 'no more ledger rows')
    end)
    it('migration 4 is safe to run again', function()
        assert_true(O.Migrations[4].up() == nil)
        assert_true(O.Migrations[4].up() == nil)
        assert_true(tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM pf_supply_order_payouts')) >= 2)
    end)
end)

describe('the delivery minimum on the real database', function()
    it('a delivery with less goods than the freight minimum is refused before anything is charged or stored; a pickup is not', function()
        fundStore(1000)
        local before, maxId = society('store_corner'), tonumber(MySQL.scalar.await('SELECT MAX(id) FROM pf_store_supply_orders'))
        local res = Mock.selfExport('CheckoutSupplies')(OWNER, { storeId = 'corner', method = 'trucking', cart = { { name = 'sandwich', quantity = 10 } } })
        assert_false(res.ok)
        assert_eq(res.error, 'below_delivery_minimum')
        assert_eq(res.data.minGoods, 250, 'the store\'s freight minimum')
        assert_true(tostring(res.message):find('at least $250 of goods', 1, true) ~= nil, tostring(res.message))
        assert_eq(society('store_corner'), before)
        assert_eq(tonumber(MySQL.scalar.await('SELECT MAX(id) FROM pf_store_supply_orders')), maxId, 'no order stored')
        assert_true(Mock.selfExport('CheckoutSupplies')(OWNER, { storeId = 'corner', method = 'pickup', cart = { { name = 'sandwich', quantity = 10 } } }).ok)
        assert_eq(exports['pf-stores']:GetDeliveryPricing('store', 'corner').minGoods, 250)
    end)
end)

describe('the store\'s own order screens', function()
    it('list what each order cost (goods, markup, freight) and count only money really spent', function()
        local list = Mock.selfExport('ListSupplyOrders')(OWNER, { storeId = 'corner' })
        assert_true(list.ok, tostring(list.error))
        local delivery, spent = nil, 0
        for _, o in ipairs(list.data.orders) do
            if o.method == 'trucking' and o.subtotal == 1000 and not delivery then delivery = o end
            if o.status ~= 'failed' and o.status ~= 'cancelled' then spent = spent + o.total end
        end
        assert_true(delivery ~= nil, 'a delivery order is listed')
        assert_eq(delivery.total, 1400)
        assert_eq(delivery.markup, 150)
        assert_eq(delivery.freight, 250)
        local manager = Mock.selfExport('GetStoreManagerData')(OWNER, { storeId = 'corner' })
        assert_true(manager.ok, tostring(manager.error))
        assert_eq(math.floor(manager.data.stats.spend7d * 100 + 0.5), math.floor(spent * 100 + 0.5), 'failed and cancelled orders are not spending')
        assert_eq(manager.data.orders[1].freight ~= nil, true)
    end)
end)

describe('books', function()
    it('the ledger reconciles after all of it', function()
        local report = L.Reconcile()
        for _, m in ipairs(report.mismatches) do print('mismatch', m.account, m.expected, m.actual) end
        assert_eq(#report.mismatches, 0)
    end)
end)

describe('store ownership from the government', function()
    local function owner() return MySQL.scalar.await("SELECT owner_citizenid FROM pf_stores WHERE store_id = 'corner'") end
    it('a government transfer changes the store owner; only pf-government may do it', function()
        local before = owner()
        Mock.invokingResource = 'pf-stores'
        assert_false(exports['pf-stores']:SetStoreOwnerFromGovernment('corner', 'DRV1'), 'other resources cannot')
        assert_eq(owner(), before)
        Mock.invokingResource = 'pf-government'
        assert_false(exports['pf-stores']:SetStoreOwnerFromGovernment('corner', 'NOBODY'), 'unknown citizen')
        assert_true(exports['pf-stores']:SetStoreOwnerFromGovernment('corner', 'DRV1'))
        assert_eq(owner(), 'DRV1')
        assert_true(exports['pf-stores']:SetStoreOwnerFromGovernment('corner', nil))
        assert_eq(owner(), nil, 'unowned: for sale again')
        assert_true(exports['pf-stores']:SetStoreOwnerFromGovernment('corner', before))
        Mock.invokingResource = nil
    end)
end)

-- The Supplier app (pf-devices) runs the same supplier flow from the tablet and the computer.
describe('Supplier app', function()
    local app = {}
    Mock.exportsByResource['pf-devices'] = {
        RegisterApp = function(_, def) app.def = def return true end,
        RegisterAppHandlers = function(_, id, map) app.id, app.h = id, map return true end,
    }
    load_resource('[pfscripts]/pf-stores/server_supplier_app.lua')
    Mock.eventHandlers['pf-devices:server:ready']()

    it('registers an installable app and runs the supplier flow through it', function()
        assert_eq(app.def.id, 'supplier')
        assert_true(app.def.access.installable)
        MySQL.update.await("DELETE FROM pf_supplier_offers")
        MySQL.update.await("DELETE FROM pf_suppliers WHERE citizenid = 'SUP1'")
        assert_false(app.h.status(SUPP, {}).supplier, 'not a supplier yet')
        assert_eq(app.h.setOffer(SUPP, { item = 'lockpick', price = 20 }).error, 'not_a_supplier')
        assert_true(app.h.register(SUPP, { name = 'Grapeseed Farms' }).ok)
        assert_true(app.h.setOffer(SUPP, { item = 'lockpick', price = 20 }).ok)
        assert_true(Mock.selfExport('AddItem')(SUPP, 'lockpick', 60, false, false, 'test'))
        local st = app.h.status(SUPP, {})
        assert_eq(st.name, 'Grapeseed Farms')
        assert_eq(st.offers[1].item, 'lockpick')
        assert_eq(st.carried.lockpick.items, 60)
        assert_eq(app.h.stock(SUPP, { item = 'lockpick', cases = 70 }).error, 'missing_items')
        assert_true(app.h.stock(SUPP, { item = 'lockpick', cases = 60 }).ok)
        fundStore(1400)
        local id = order().data.orderId
        st = app.h.status(SUPP, {})
        assert_eq(#st.orders, 1)
        assert_eq(st.orders[1].orderId, id)
        assert_true(app.h.accept(SUPP, { orderId = id }).ok)
        assert_false(app.h.accept(SUPP, { orderId = id }).ok, 'once')
        assert_eq(status(id), 'awaiting_delivery')
    end)
end)
