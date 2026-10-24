-- pf-stores (store purchase, storefront sales, sales tax, owner withdrawals, balance migration) and
-- pf-trucking (contract pay) on the pfm-banking ledger, running the real resource files on the fake
-- database. pf-government is replaced by a small stub that records the tax it is handed.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/fake_db.lua')
function GetCurrentResourceName() return 'pfm-banking' end
function GetResourceState() return 'started' end

Config = nil
load_resource('pfm-banking/config.lua')
load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')
Mock.exportsByResource['pfm-banking'] = Mock.exportsByResource['__self']

-- pf-stores and pf-trucking read their settings from the same global Config at call time
Config.Stores = {
    corner = {
        id = 'corner', label = 'Corner Store', type = 'purchasable',
        purchase = { price = 5000, moneyType = 'bank' },
        storefront = { enabled = true, moneyTypes = { 'cash', 'bank' }, defaultMoneyType = 'cash',
            items = { { name = 'sandwich', price = 10, cost = 4, maxQuantity = 20 }, { name = 'lockpick', price = 50, cost = 20, maxQuantity = 5 } } },
        trucking = {
            enabled = true, payoutRate = 0.12, payoutMin = 250,
            pickup = { label = 'Warehouse', coords = vector3(0.0, 0.0, 0.0) },
            dropoff = { label = 'Corner Store', coords = vector3(3000.0, 0.0, 0.0) },
        },
    },
    npc = {
        id = 'npc', label = 'NPC Shop', type = 'static',
        storefront = { enabled = true, moneyTypes = { 'cash' }, items = { { name = 'sandwich', price = 10 } } },
    },
}
Config.Delivery = { DropoffRadius = 80.0, ReturnRadius = 35.0, MinSeconds = 45, MaxAverageSpeed = 45.0 }
Config.WorkTruck = {
    Enabled = true, RentalFee = 100, PlatePrefix = 'WK', Models = { 'phantom' },
    Depots = { { id = 'depot', label = 'Depot', spawnCoords = vector4(0.0, 0.0, 0.0, 0.0), returnCoords = vector4(5.0, 0.0, 0.0, 0.0) } },
}

-- pf-government stub
Gov = { accept = true, credited = {}, keys = {} }
Mock.exportsByResource['pf-government'] = {
    GetSalesTaxBreakdown = function(_, subtotal)
        local tax = math.floor(subtotal * 10 + 0.5) / 100
        return { subtotal = subtotal, tax = tax, total = subtotal + tax, rate = 10 }
    end,
    CollectTaxAmount = function(_, amount, _, _, _, _, key)
        if not Gov.accept then return 0 end
        if not Gov.keys[key] then
            Gov.keys[key] = true
            Gov.credited[#Gov.credited + 1] = amount
        end
        return amount
    end,
}

-- pf-stores tables
Store = {}
local function resetStore()
    Store.rows = {
        corner = { store_id = 'corner', label = 'Corner Store', store_type = 'purchasable', owner_citizenid = 'OWN1', purchased_at = 1, balance = 0 },
        npc = { store_id = 'npc', label = 'NPC Shop', store_type = 'static', owner_citizenid = nil, purchased_at = nil, balance = 0 },
    }
    Store.stock = { corner = { sandwich = 10, lockpick = 2 }, npc = { sandwich = 10 } }
    Store.staleStock = nil      -- when set, the stock read reports this instead (another shopper raced us)
    Store.ledger = {}
    Store.claimFails = false
    Store.orders = {}
end
local function orderById(id) return Store.orders[tonumber(id)] end
FakeDB.extraPatterns = {
    -- supply orders
    { 'SELECT store_id, label, store_type, purchased_at FROM pf_stores WHERE owner_citizenid = ?', function(p)
        local out = {}
        for id, r in pairs(Store.rows) do
            if r.owner_citizenid == p[1] then out[#out + 1] = { store_id = id, label = r.label, store_type = r.store_type, purchased_at = r.purchased_at } end
        end
        return out
    end },
    { 'SELECT id, method, status, total, items_json, created_at, delivered_at FROM pf_store_supply_orders WHERE store_id = ?', function(p)
        local out = {}
        for i = #Store.orders, 1, -1 do
            local o = Store.orders[i]
            if o.store_id == p[1] then out[#out + 1] = o end
        end
        return out
    end },
    { 'SELECT owner_citizenid FROM pf_stores WHERE store_id = ?', function(p)
        local r = Store.rows[p[1]]
        return { { owner_citizenid = r and r.owner_citizenid } }
    end },
    { 'SELECT id, method, status, external_contract_id, total, created_at FROM pf_store_supply_orders WHERE store_id = ? AND owner_citizenid', function() return {} end },
    { 'INSERT INTO pf_store_supply_orders', function(p)
        local id = #Store.orders + 1
        Store.orders[id] = { id = id, store_id = p[1], owner_citizenid = p[2], method = p[3], status = p[4], total = p[5], items_json = p[6], created_at = p[7], freight_payout = p[8] }
        return id
    end },
    { 'SELECT id, store_id, status, items_json FROM pf_store_supply_orders WHERE id = ?', function(p) return { orderById(p[1]) } end },
    { 'SELECT id, store_id, method, status, total FROM pf_store_supply_orders WHERE id = ?', function(p) return { orderById(p[1]) } end },
    { 'SELECT id, store_id, method FROM pf_store_supply_orders WHERE id = ?', function(p) return { orderById(p[1]) } end },
    { 'SELECT total, freight_payout FROM pf_store_supply_orders WHERE id = ?', function(p) return { orderById(p[1]) } end },
    { "SELECT id, store_id, items_json, freight_payout, created_at FROM pf_store_supply_orders WHERE method = 'trucking'", function()
        local out = {}
        for _, o in ipairs(Store.orders) do if o.method == 'trucking' and o.status == 'outsource_posted' then out[#out + 1] = o end end
        return out
    end },
    { "UPDATE pf_store_supply_orders SET status = 'delivered'", function(p)
        local o = orderById(p[2])
        if o and (o.status == 'ordered' or o.status == 'outsource_posted') then o.status = 'delivered'; return 1 end
        return 0
    end },
    { "UPDATE pf_store_supply_orders SET status = 'cancelled'", function(p)
        local o = orderById(p[1])
        if o and o.status == 'outsource_posted' then o.status = 'cancelled'; return 1 end
        return 0
    end },
    { 'UPDATE pf_store_supply_orders SET status = ? WHERE id = ?', function(p) orderById(p[2]).status = p[1]; return 1 end },
    { 'UPDATE pf_store_supply_orders SET external_contract_id = ?', function(p) orderById(p[2]).external_contract_id = p[1]; return 1 end },
    { 'INSERT INTO pf_store_supply_stock', function(p)
        Store.stock[p[1]] = Store.stock[p[1]] or {}
        Store.stock[p[1]][p[2]] = (Store.stock[p[1]][p[2]] or 0) + p[3]
        return 1
    end },
    { 'SELECT store_id, label, store_type, owner_citizenid, purchased_at FROM pf_stores WHERE store_id = ?', function(p)
        return { Store.rows[p[1]] }
    end },
    { 'SELECT store_id, balance FROM pf_stores WHERE balance > 0', function()
        local out = {}
        for id, r in pairs(Store.rows) do if r.balance > 0 then out[#out + 1] = { store_id = id, balance = r.balance } end end
        return out
    end },
    { 'UPDATE pf_stores SET balance = 0 WHERE store_id = ? AND balance = ?', function(p)
        local r = Store.rows[p[1]]
        if r and r.balance == p[2] then r.balance = 0; return 1 end
        return 0
    end },
    { 'UPDATE pf_stores SET owner_citizenid = ?', function(p)
        local r = Store.rows[p[3]]
        if Store.claimFails or not r or (r.owner_citizenid ~= nil and r.owner_citizenid ~= '') then return 0 end
        r.owner_citizenid, r.purchased_at = p[1], p[2]
        return 1
    end },
    { 'SELECT item, price FROM pf_store_prices', function() return {} end },
    { 'SELECT supply_name, stock_cases FROM pf_store_supply_stock WHERE store_id = ?', function(p)
        local out = {}
        for name, n in pairs(Store.staleStock or Store.stock[p[1]] or {}) do out[#out + 1] = { supply_name = name, stock_cases = n } end
        return out
    end },
    { 'UPDATE pf_store_supply_stock SET stock_cases = stock_cases - ?', function(p)
        local s = Store.stock[p[2]]
        if not s or (s[p[3]] or 0) < p[4] then return 0 end
        s[p[3]] = s[p[3]] - p[1]
        return 1
    end },
    { 'UPDATE pf_store_supply_stock SET stock_cases = stock_cases + ?', function(p)
        local s = Store.stock[p[2]]
        s[p[3]] = (s[p[3]] or 0) + p[1]
        return 1
    end },
    { 'INSERT INTO pf_store_ledger', function(p) Store.ledger[#Store.ledger + 1] = p; return #Store.ledger end },
}

load_resource('[pfscripts]/pf-stores/server.lua')
load_resource('[pfscripts]/pf-trucking/server.lua')
Mock.exportsByResource['pf-trucking'] = Mock.exportsByResource['__self']

-- pf-computer (the Order Supplies app), with its own config merged into the shared Config
SavedFiles = {}
-- pf-computer's data file as it was before company accounts moved to the bank: the mechanic shop has
-- 700 in its old balance, of which 400 was paid in by players (500 deposited - 100 withdrawn) and 300
-- came from recorded sales.
SeedPcData = json.encode({
    businessAccounts = {
        mechanic = {
            balance = 700,
            transactions = {
                { type = 'sale', amount = 300, description = 'POS Sale' },
                { type = 'withdrawal', amount = 100, description = 'Withdrawal' },
                { type = 'deposit', amount = 500, description = 'Deposit' },
            },
        },
    },
})
function LoadResourceFile(_, path) if path == 'data/pc_data.json' then return SeedPcData end return nil end
QBCoreMock.Shared.Jobs = { mechanic = { label = 'Mechanic' }, burgershot = { label = 'Burger Shot' } }
function SaveResourceFile(_, path, content) SavedFiles[path] = content; return true end
function RegisterCommand() end
local sharedConfig = Config
load_resource('[pfscripts]/pf-computer/config/config.lua')
for k, v in pairs(sharedConfig) do if Config[k] == nil then Config[k] = v end end
load_resource('[pfscripts]/pf-computer/server/main.lua')
Mock.exportsByResource['pf-stores'] = Mock.exportsByResource['__self']

local L = PFLedger
OWNER, SHOPPER, DRIVER = 1, 2, 3
local clockBase = 1700000000
local testNo = 0
local inventory, inventoryFull = {}, false

local function storeBal() return FakeDB.bank_accounts.store_corner and FakeDB.bank_accounts.store_corner.account_balance or 0 end
local function money(src, kind) return Mock.players[src].PlayerData.money[kind or 'bank'] end
local function checkout(src, storeId, cart, moneyType)
    return Mock.callCallback('pf-stores:server:storefrontCheckout', src, storeId, cart, moneyType)
end
local function cb(name, src, ...) return Mock.callCallback(name, src, ...) end

BeforeEach = function()
    Mock.reset()
    FakeDB.reset()
    FakeDB.migrations = {}
    testNo = testNo + 1
    Mock.clock = clockBase + testNo * 1000 -- clears the resources' per-player cooldowns between tests
    Mock.players = {}
    Mock.coords = {}
    inventory, inventoryFull = {}, false
    for src, cid in pairs({ [OWNER] = 'OWN1', [SHOPPER] = 'SHOP1', [DRIVER] = 'DRV1' }) do
        local p = Mock.newPlayer(src, cid)
        p.PlayerData.money = { cash = 500, bank = 10000 }
        p.Functions.AddItem = function(name, qty)
            if inventoryFull then return false end
            inventory[name] = (inventory[name] or 0) + qty
            return true
        end
        p.Functions.RemoveItem = function(name, qty)
            inventory[name] = (inventory[name] or 0) - qty
            return true
        end
    end
    Gov.accept, Gov.credited, Gov.keys = true, {}, {}
    resetStore()
    for k in pairs(BankingAccounts) do BankingAccounts[k] = nil end   -- pfm-banking's in-memory account cache
    L.ready, L.failed = false, false
    assert(L.Start(), 'ledger start')
    -- pf-trucking keeps contracts in memory: drop the driver's job and any supply contracts left over
    Mock.callCallback('pf-trucking:server:cancelActiveJob', DRIVER)
    Mock.callCallback('pf-trucking:server:returnWorkTruck', DRIVER)
    for i = 1, 20 do Mock.selfExport('CancelExternalJob')(('SUP-%d'):format(i)) end
    Mock.reset()
end

local function noMismatches()
    local report = L.Reconcile()
    for _, m in ipairs(report.mismatches) do print('mismatch', m.account, m.expected, m.actual) end
    return #report.mismatches == 0
end

describe('pf-stores storefront', function()
    it('a sale charges the shopper, pays the owner the subtotal and the treasury the tax', function()
        local res = checkout(SHOPPER, 'corner', { { name = 'sandwich', quantity = 3 } }, 'cash')
        assert_true(res.ok)
        assert_eq(money(SHOPPER, 'cash'), 467)                         -- 30 + 10% tax
        assert_eq(storeBal(), 30)
        assert_eq(Gov.credited[1], 3)
        assert_eq(Store.stock.corner.sandwich, 7)
        assert_eq(inventory.sandwich, 3)
        assert_eq(FakeDB.bank_accounts.store_corner.account_type, 'business')
        assert_true(noMismatches())
    end)
    it('tax the treasury cannot accept is refunded to the shopper instead of vanishing', function()
        Gov.accept = false
        local res = checkout(SHOPPER, 'corner', { { name = 'sandwich', quantity = 3 } }, 'cash')
        assert_true(res.ok)
        assert_eq(money(SHOPPER, 'cash'), 470)
        assert_eq(res.data.tax, 0)
        assert_eq(res.data.total, 30)
        assert_eq(storeBal(), 30)
    end)
    it('a shopper who cannot pay gets nothing and nothing moves', function()
        Mock.players[SHOPPER].PlayerData.money.cash = 5
        local res = checkout(SHOPPER, 'corner', { { name = 'lockpick', quantity = 1 } }, 'cash')
        assert_false(res.ok)
        assert_eq(res.error, 'not_enough_money')
        assert_eq(money(SHOPPER, 'cash'), 5)
        assert_eq(Store.stock.corner.lockpick, 2)
        assert_eq(inventory.lockpick, nil)
    end)
    it('stock that runs out during checkout refunds the shopper in full and restores stock', function()
        Store.staleStock = { sandwich = 10, lockpick = 10 }               -- the read says plenty, the row says 2
        local res = checkout(SHOPPER, 'corner', { { name = 'sandwich', quantity = 2 }, { name = 'lockpick', quantity = 3 } }, 'cash')
        assert_false(res.ok)
        assert_eq(res.error, 'out_of_stock')
        assert_eq(money(SHOPPER, 'cash'), 500)
        assert_eq(Store.stock.corner.sandwich, 10)
        assert_eq(storeBal(), 0)
    end)
    it('a full inventory refunds the shopper in full and restores stock', function()
        inventoryFull = true
        local res = checkout(SHOPPER, 'corner', { { name = 'sandwich', quantity = 2 } }, 'bank')
        assert_false(res.ok)
        assert_eq(money(SHOPPER, 'bank'), 10000)
        assert_eq(Store.stock.corner.sandwich, 10)
        assert_eq(#Gov.credited, 0)
    end)
    it('with the bank down nothing is sold', function()
        L.ready = false
        local res = checkout(SHOPPER, 'corner', { { name = 'sandwich', quantity = 1 } }, 'cash')
        L.ready = true
        assert_false(res.ok)
        assert_eq(money(SHOPPER, 'cash'), 500)
        assert_eq(inventory.sandwich, nil)
    end)
    it('an ownerless store still charges the shopper but credits no account', function()
        local res = checkout(SHOPPER, 'npc', { { name = 'sandwich', quantity = 1 } }, 'cash')
        assert_true(res.ok)
        assert_eq(money(SHOPPER, 'cash'), 489)
        assert_eq(FakeDB.bank_accounts.store_npc, nil)
    end)
end)

describe('pf-stores owner money', function()
    it('the owner withdraws from the store account to their bank', function()
        checkout(SHOPPER, 'corner', { { name = 'lockpick', quantity = 2 } }, 'bank')
        assert_eq(storeBal(), 100)
        local res = cb('pf-stores:server:withdrawBalance', OWNER, { storeId = 'corner', amount = 60 })
        assert_true(res.ok)
        assert_eq(res.data.balance, 40)
        assert_eq(money(OWNER), 10060)
        assert_true(noMismatches())
    end)
    it('a withdrawal over the store balance is refused', function()
        checkout(SHOPPER, 'corner', { { name = 'sandwich', quantity = 1 } }, 'bank')
        local res = cb('pf-stores:server:withdrawBalance', OWNER, { storeId = 'corner', amount = 500 })
        assert_false(res.ok)
        assert_eq(money(OWNER), 10000)
        assert_eq(storeBal(), 10)
    end)
    it('someone who does not own the store cannot withdraw', function()
        checkout(SHOPPER, 'corner', { { name = 'sandwich', quantity = 1 } }, 'bank')
        local res = cb('pf-stores:server:withdrawBalance', SHOPPER, { storeId = 'corner', amount = 5 })
        assert_false(res.ok)
        assert_eq(storeBal(), 10)
    end)
    it('balances kept in pf_stores.balance are moved to the bank once', function()
        Store.rows.corner.balance = 1234.5
        assert_eq(MigrateStoreBalancesToBank(), 1)
        assert_eq(storeBal(), 1234.5)
        assert_eq(Store.rows.corner.balance, 0)
        assert_eq(MigrateStoreBalancesToBank(), 0)
        assert_eq(storeBal(), 1234.5)
    end)
    it('buying a store charges the buyer; losing the race refunds them', function()
        Store.rows.corner.owner_citizenid = nil
        Store.claimFails = true
        local res = cb('pf-stores:server:purchaseStore', SHOPPER, 'corner')
        assert_false(res.ok)
        assert_eq(money(SHOPPER), 10000)
        Store.claimFails = false
        res = cb('pf-stores:server:purchaseStore', SHOPPER, 'corner')
        assert_true(res.ok)
        assert_eq(money(SHOPPER), 5000)
        assert_eq(Store.rows.corner.owner_citizenid, 'SHOP1')
    end)
end)

describe('pf-trucking pay', function()
    local DROP = vector3(3000.0, 0.0, 0.0)
    local function postJob(payout)
        return Mock.selfExport('CreateExternalJob')({
            title = 'Test Haul', payout = payout or 1000,
            stops = { { label = 'Pickup', coords = vector3(0.0, 0.0, 0.0) }, { label = 'Drop', coords = DROP } },
        })
    end
    local function claim(id) return cb('pf-trucking:server:claimContract', DRIVER, id) end

    it('completing away from the drop-off pays nothing and keeps the job', function()
        claim(postJob())
        Mock.clock = Mock.clock + 600
        local res = cb('pf-trucking:server:completeActiveJob', DRIVER)
        assert_false(res.ok)
        assert_eq(money(DRIVER), 10000)
        Mock.coords[DRIVER] = DROP
        assert_true(cb('pf-trucking:server:completeActiveJob', DRIVER).ok)  -- the job was kept
    end)
    it('arriving faster than the route allows (teleport) is refused', function()
        claim(postJob())
        Mock.coords[DRIVER] = DROP
        Mock.clock = Mock.clock + 10                                    -- 3 km in 10 s
        assert_false(cb('pf-trucking:server:completeActiveJob', DRIVER).ok)
        assert_eq(money(DRIVER), 10000)
    end)
    it('a real delivery is paid once through the ledger', function()
        claim(postJob(1000))
        Mock.coords[DRIVER] = DROP
        Mock.clock = Mock.clock + 600
        local res = cb('pf-trucking:server:completeActiveJob', DRIVER)
        assert_true(res.ok)
        assert_eq(money(DRIVER), 11000)
        local tx = FakeDB.transactions[#FakeDB.transactions]
        assert_eq(tx.from_account, 'system:pf-trucking')
        assert_false(cb('pf-trucking:server:completeActiveJob', DRIVER).ok)  -- nothing left to pay
        assert_eq(money(DRIVER), 11000)
    end)
    it('a work-truck job pays once, at the depot, net of the rental fee', function()
        Mock.coords[DRIVER] = vector3(0.0, 0.0, 0.0)
        assert_true(cb('pf-trucking:server:requestWorkTruck', DRIVER).ok)
        claim(postJob(1000))
        Mock.clock = Mock.clock + 600
        -- the old shortcut: "complete" at the drop-off paid, then the depot return paid again
        assert_false(cb('pf-trucking:server:completeActiveJob', DRIVER).ok)
        -- claiming delivery away from the drop-off is refused
        assert_false(cb('pf-trucking:server:markDelivered', DRIVER).ok)
        Mock.coords[DRIVER] = DROP
        assert_true(cb('pf-trucking:server:markDelivered', DRIVER).ok)
        -- finishing away from the depot is refused
        assert_false(cb('pf-trucking:server:completeDeliveredJob', DRIVER).ok)
        Mock.coords[DRIVER] = vector3(5.0, 0.0, 0.0)
        local res = cb('pf-trucking:server:completeDeliveredJob', DRIVER)
        assert_true(res.ok)
        assert_eq(money(DRIVER), 10900)
        assert_false(cb('pf-trucking:server:completeDeliveredJob', DRIVER).ok)
        assert_eq(money(DRIVER), 10900)
    end)
    it('when the bank is down the job is kept and paid once on retry', function()
        claim(postJob(500))
        Mock.coords[DRIVER] = DROP
        Mock.clock = Mock.clock + 600
        L.ready = false
        assert_false(cb('pf-trucking:server:completeActiveJob', DRIVER).ok)
        L.ready = true
        assert_true(cb('pf-trucking:server:completeActiveJob', DRIVER).ok)
        assert_eq(money(DRIVER), 10500)
    end)
    it('an external (store supply) job completed with an own truck now notifies its owner', function()
        claim(postJob())
        Mock.coords[DRIVER] = DROP
        Mock.clock = Mock.clock + 600
        cb('pf-trucking:server:completeActiveJob', DRIVER)
        local fired = false
        for _, e in ipairs(Mock.serverEvents) do if e.name == 'pf-trucking:server:externalJobCompleted' then fired = true end end
        assert_true(fired)
    end)
end)

describe('pf-stores supply orders', function()
    local DROP = vector3(3000.0, 0.0, 0.0)
    local function order(method, cart)
        return Mock.selfExport('CheckoutSupplies')(OWNER, { storeId = 'corner', method = method, cart = cart or { { name = 'sandwich', quantity = 10 } } })
    end
    local function fund(amount)
        return cb('pf-stores:server:depositBalance', OWNER, { storeId = 'corner', amount = amount })
    end
    local function escrow() return FakeDB.bank_accounts.freight_escrow and FakeDB.bank_accounts.freight_escrow.account_balance or 0 end
    local function deliverTruck(id)
        assert_true(cb('pf-trucking:server:claimContract', DRIVER, id).ok)
        Mock.coords[DRIVER] = DROP
        Mock.clock = Mock.clock + 600
        return cb('pf-trucking:server:completeActiveJob', DRIVER)
    end

    it('the owner funds the store from their bank; others cannot', function()
        local res = fund(2500)
        assert_true(res.ok)
        assert_eq(res.data.balance, 2500)
        assert_eq(money(OWNER), 7500)
        assert_false(cb('pf-stores:server:depositBalance', SHOPPER, { storeId = 'corner', amount = 100 }).ok)
        Mock.clock = Mock.clock + 5
        local broke = fund(999999)
        assert_false(broke.ok)
        assert_eq(broke.error, 'insufficient_bank')
        assert_eq(storeBal(), 2500)
    end)
    it('a pickup order is paid from the store account and stocks the store once', function()
        fund(100)
        local res = order('pickup')                                      -- 10 x 4
        assert_true(res.ok)
        assert_eq(storeBal(), 60)
        assert_eq(Store.stock.corner.sandwich, 20)
        assert_eq(FakeDB.transactions[#FakeDB.transactions].to_account, 'system:pf-stores-supplier')
        -- a second delivery of the same order is a no-op (reported as done, adds nothing)
        Mock.selfExport('DeliverSupplyOrder')(OWNER, { storeId = 'corner', orderId = res.data.orderId })
        assert_eq(Store.stock.corner.sandwich, 20)
    end)
    it('supplies are no longer free: an unfunded store cannot order', function()
        local res = order('pickup')
        assert_false(res.ok)
        assert_eq(res.error, 'insufficient_store_funds')
        assert_eq(Store.stock.corner.sandwich, 10)
        assert_eq(#Store.orders, 0)
    end)
    it('a trucking order holds the payment in escrow; delivery pays the trucker and the supplier from it', function()
        fund(5000)
        local res = order('trucking', { { name = 'lockpick', quantity = 100 } })   -- 100 x 20 = 2000
        assert_true(res.ok)
        assert_eq(storeBal(), 3000)
        assert_eq(escrow(), 2000)
        assert_eq(Store.orders[1].freight_payout, 250)                  -- 12% = 240, minimum 250
        local done = deliverTruck(res.data.contractId)
        assert_true(done.ok)
        assert_eq(money(DRIVER), 10250)
        assert_eq(escrow(), 0)                                          -- 250 to the driver, 1750 to the supplier
        assert_eq(Store.orders[1].status, 'delivered')
        assert_eq(Store.stock.corner.lockpick, 102)
        assert_true(noMismatches())
    end)
    it('with a rented work truck the rental fee comes out of the escrowed pay', function()
        fund(5000)
        local res = order('trucking', { { name = 'lockpick', quantity = 100 } })
        Mock.coords[DRIVER] = vector3(0.0, 0.0, 0.0)
        assert_true(cb('pf-trucking:server:requestWorkTruck', DRIVER).ok)
        assert_true(cb('pf-trucking:server:claimContract', DRIVER, res.data.contractId).ok)
        Mock.clock = Mock.clock + 600
        Mock.coords[DRIVER] = DROP
        assert_true(cb('pf-trucking:server:markDelivered', DRIVER).ok)
        Mock.coords[DRIVER] = vector3(5.0, 0.0, 0.0)
        assert_true(cb('pf-trucking:server:completeDeliveredJob', DRIVER).ok)
        assert_eq(money(DRIVER), 10150)                                 -- 250 - 100 rental
        assert_eq(escrow(), 0)
    end)
    it('the order total caps the trucker pay (small orders)', function()
        fund(100)
        local res = order('trucking', { { name = 'sandwich', quantity = 10 } })   -- 40 total, minimum pay 250
        assert_true(res.ok)
        assert_eq(Store.orders[1].freight_payout, 40)
        deliverTruck(res.data.contractId)
        assert_eq(money(DRIVER), 10040)
        assert_eq(escrow(), 0)
    end)
    it('an unclaimed trucking order can be cancelled for a full refund; a claimed one cannot', function()
        fund(5000)
        local a = order('trucking', { { name = 'lockpick', quantity = 50 } })
        local cancel = Mock.selfExport('CancelSupplyOrder')(OWNER, { storeId = 'corner', orderId = a.data.orderId })
        assert_true(cancel.ok)
        assert_eq(storeBal(), 5000)
        assert_eq(escrow(), 0)
        Mock.clock = Mock.clock + 30
        local b = order('trucking', { { name = 'lockpick', quantity = 50 } })
        assert_true(cb('pf-trucking:server:claimContract', DRIVER, b.data.contractId).ok)
        assert_false(Mock.selfExport('CancelSupplyOrder')(OWNER, { storeId = 'corner', orderId = b.data.orderId }).ok)
        assert_eq(escrow(), 1000)
    end)
    it('the store is refunded when the trucking contract cannot be posted', function()
        fund(5000)
        local saved = Mock.exportsByResource['pf-trucking']
        Mock.exportsByResource['pf-trucking'] = {}
        local res = order('trucking', { { name = 'lockpick', quantity = 50 } })
        Mock.exportsByResource['pf-trucking'] = saved
        assert_false(res.ok)
        assert_eq(storeBal(), 5000)
        assert_eq(escrow(), 0)
        assert_eq(Store.orders[1].status, 'failed')
    end)
    it('after a restart open orders are re-posted and still paid only once', function()
        fund(5000)
        local res = order('trucking', { { name = 'lockpick', quantity = 100 } })
        Mock.selfExport('CancelExternalJob')(res.data.contractId)          -- pf-trucking lost its contracts
        assert_eq(RepostOpenSupplyOrders(), 1)
        assert_eq(RepostOpenSupplyOrders(), 1)                          -- re-posting again keeps the same contract
        assert_true(deliverTruck(res.data.contractId).ok)
        assert_eq(money(DRIVER), 10250)
        assert_eq(escrow(), 0)
    end)
    it('a trucking order cannot be self-delivered by the owner', function()
        fund(5000)
        local res = order('trucking', { { name = 'lockpick', quantity = 10 } })
        local d = Mock.selfExport('DeliverSupplyOrder')(OWNER, { storeId = 'corner', orderId = res.data.orderId })
        assert_false(d.ok)
        assert_eq(d.error, 'delivered_by_trucking')
        assert_eq(Store.stock.corner.lockpick, 2)
    end)
    it('cancelling and re-claiming a contract does not shrink the pay again', function()
        fund(5000)
        local res = order('trucking', { { name = 'lockpick', quantity = 100 } })
        Mock.coords[DRIVER] = vector3(0.0, 0.0, 0.0)
        assert_true(cb('pf-trucking:server:requestWorkTruck', DRIVER).ok)
        cb('pf-trucking:server:claimContract', DRIVER, res.data.contractId)
        cb('pf-trucking:server:cancelActiveJob', DRIVER)
        assert_true(cb('pf-trucking:server:requestWorkTruck', DRIVER).ok)
        local claim = cb('pf-trucking:server:claimContract', DRIVER, res.data.contractId)
        assert_eq(claim.job.payoutNet, 150)
    end)
end)

describe('pf-computer Order Supplies for player-owned stores', function()
    local function pc(action, src, payload)
        Mock.clientEvents = {}
        Mock.fireNet('pf-computer:server:callback', src, 7, action, payload or {})
        local ev = Mock.clientEventsNamed('pf-computer:client:callback')[1]
        assert_true(ev ~= nil, 'no callback response for ' .. action)
        return ev.args[2]
    end
    local function fund(amount)
        return cb('pf-stores:server:depositBalance', OWNER, { storeId = 'corner', amount = amount })
    end
    local function setJob(src, name, isboss)
        Mock.players[src].PlayerData.job = { name = name, label = name, isboss = isboss or false, grade = { level = 0 } }
    end

    it('a store owner with an ordinary job gets their store, priced by pf-stores, with the bank balance', function()
        setJob(OWNER, 'unemployed')
        fund(300)
        local res = pc('business:supplies:catalog', OWNER)
        assert_true(res.ok)
        assert_eq(res.data.mode, 'store')
        assert_eq(res.data.storeId, 'corner')
        assert_eq(res.data.balance, 300)
        assert_true(res.data.deliveryAvailable)
        local prices = {}
        for _, it in ipairs(res.data.catalog.items) do prices[it.item] = it.pricePerCase end
        assert_eq(prices.sandwich, 4)
        assert_eq(prices.lockpick, 20)
    end)
    it('ordering for pickup charges the store bank account, stocks the store, and never touches the JSON accounts', function()
        setJob(OWNER, 'unemployed')
        fund(300)
        local res = pc('business:supplies:orders:create', OWNER, { fulfillment = 'pickup', items = { { item = 'sandwich', quantity = 10 } } })
        assert_true(res.ok)
        assert_eq(res.balance, 260)
        assert_eq(storeBal(), 260)
        assert_eq(Store.stock.corner.sandwich, 20)
        for _, content in pairs(SavedFiles) do
            assert_true(not tostring(content):find('corner'), 'store data written to the pf-computer data file')
        end
        local list = pc('business:supplies:orders:list', OWNER)
        assert_eq(list.data[1].status, 'picked_up')
    end)
    it('an unfunded store cannot order through the app', function()
        setJob(OWNER, 'unemployed')
        local res = pc('business:supplies:orders:create', OWNER, { fulfillment = 'pickup', items = { { item = 'sandwich', quantity = 10 } } })
        assert_false(res.ok)
        assert_eq(res.error, 'insufficient_store_funds')
        assert_eq(Store.stock.corner.sandwich, 10)
    end)
    it('the app cannot set prices: a forged cheap price in the request is ignored', function()
        setJob(OWNER, 'unemployed')
        fund(300)
        local res = pc('business:supplies:orders:create', OWNER, { fulfillment = 'pickup', items = { { item = 'lockpick', quantity = 5, pricePerCase = 0.01 } } })
        assert_true(res.ok)
        assert_eq(storeBal(), 200)                                      -- 5 x 20
    end)
    it('a delivery order goes to trucking and can be cancelled from the app for a refund', function()
        setJob(OWNER, 'unemployed')
        fund(5000)
        local res = pc('business:supplies:orders:create', OWNER, { fulfillment = 'delivery', items = { { item = 'lockpick', quantity = 50 } } })
        assert_true(res.ok)
        assert_eq(storeBal(), 4000)
        local list = pc('business:supplies:orders:list', OWNER)
        assert_eq(list.data[1].status, 'in_transit')
        assert_true(list.data[1].cancellable)
        local cancel = pc('business:supplies:orders:cancel', OWNER, { orderId = list.data[1].id })
        assert_true(cancel.ok)
        assert_eq(storeBal(), 5000)
    end)
    it('someone who owns no store and has no business is refused cleanly (this used to crash the handler)', function()
        setJob(SHOPPER, 'unemployed')
        local res = pc('business:supplies:catalog', SHOPPER)
        assert_false(res.ok)
        assert_eq(res.error, 'job_not_allowed')
        local res2 = pc('business:supplies:orders:create', SHOPPER, { mode = 'store', fulfillment = 'pickup', items = { { item = 'sandwich', quantity = 1 } } })
        assert_false(res2.ok)
    end)
    it('a business boss who also owns a store can switch between them', function()
        setJob(OWNER, 'burgershot', true)
        Mock.players[OWNER].PlayerData.job.grade = { level = 4 }       -- burgershot needs grade 3+
        local asJob = pc('business:supplies:catalog', OWNER)
        assert_true(asJob.ok)
        assert_eq(asJob.data.mode, 'job')
        assert_true(asJob.data.canSwitch)
        local asStore = pc('business:supplies:catalog', OWNER, { mode = 'store' })
        assert_eq(asStore.data.mode, 'store')
        assert_true(asStore.data.canSwitch)
    end)
end)
describe('pf-computer company accounts are the job bank account', function()
    local function pc(action, src, payload)
        Mock.clientEvents = {}
        Mock.fireNet('pf-computer:server:callback', src, 9, action, payload or {})
        local ev = Mock.clientEventsNamed('pf-computer:client:callback')[1]
        assert_true(ev ~= nil, 'no callback response for ' .. action)
        return ev.args[2]
    end
    local function bank(job) return FakeDB.bank_accounts[job] and FakeDB.bank_accounts[job].account_balance or 0 end
    local function seed(job, amount)
        FakeDB.society(job, amount, 'job')
        BankingAccounts[job] = { account_name = job, account_balance = amount, account_type = 'job' }
    end
    local function staff(src, isboss)
        Mock.players[src].PlayerData.job = { name = 'burgershot', label = 'Burger Shot', isboss = isboss, grade = { level = 4 } }
    end

    it('the old data-file balance moves to the bank once, player-funded part only', function()
        local moved = MigrateBusinessAccountsToBank()
        assert_eq(moved, 1)
        assert_eq(bank('mechanic'), 400)                                -- 500 deposited - 100 withdrawn
        assert_eq(MigrateBusinessAccountsToBank(), 0)                   -- already done
        assert_eq(bank('mechanic'), 400)
        assert_true(noMismatches())
    end)
    it('the company account shows the bank balance and history', function()
        staff(OWNER, true)
        seed('burgershot', 1234)
        local res = pc('business:account:list', OWNER)
        assert_true(res.ok)
        assert_eq(res.data.balance, 1234)
    end)
    it('a deposit moves the player\'s bank money into the job bank account', function()
        staff(OWNER, false)
        local res = pc('business:account:deposit', OWNER, { amount = 250, description = 'float' })
        assert_true(res.ok)
        assert_eq(money(OWNER), 9750)
        assert_eq(bank('burgershot'), 250)
        assert_eq(res.data.balance, 250)
        assert_eq(res.data.transactions[1].type, 'deposit')
        local broke = pc('business:account:deposit', OWNER, { amount = 99999 })
        assert_false(broke.ok)
        assert_eq(broke.error, 'insufficient_funds')
        assert_false(pc('business:account:deposit', OWNER, { amount = -50 }).ok)
        assert_eq(money(OWNER), 9750)
    end)
    it('only the boss withdraws, and never more than the account holds', function()
        seed('burgershot', 300)
        staff(OWNER, false)
        local res = pc('business:account:withdraw', OWNER, { amount = 100 })
        assert_false(res.ok)
        assert_eq(res.error, 'not_boss')
        staff(OWNER, true)
        assert_false(pc('business:account:withdraw', OWNER, { amount = 301 }).ok)
        assert_true(pc('business:account:withdraw', OWNER, { amount = 100 }).ok)
        assert_eq(bank('burgershot'), 200)
        assert_eq(money(OWNER), 10100)
    end)
    it('DepositSale only records the sale: it cannot create money', function()
        seed('mechanic', 50)
        local res = Mock.selfExport('DepositSale')('mechanic', 1000000, 'Tablet Checkout')
        assert_true(res.ok)
        assert_eq(bank('mechanic'), 50)
        assert_eq(res.balance, 50)
    end)
    it('job supply orders are paid from the job bank account', function()
        -- a job business's catalog comes from its provider resource (here a stub for pf-mechanicjob)
        Mock.exportsByResource['pf-mechanicjob'] = {
            GetBusinessConfig = function() return { businessName = 'Mechanic', businessType = 'mechanic',
                suppliesCatalog = { items = { { item = 'engine_oil', label = 'Engine Oil', category = 'Parts', pricePerCase = 40 } } } } end,
        }
        Mock.players[OWNER].PlayerData.job = { name = 'mechanic', label = 'Mechanic', isboss = true, grade = { level = 4 } }
        local order = { mode = 'job', fulfillment = 'pickup', items = { { item = 'engine_oil', quantity = 3 } } }
        local refused = pc('business:supplies:orders:create', OWNER, order)
        assert_false(refused.ok)
        assert_eq(refused.error, 'insufficient_funds')
        seed('mechanic', 1000)
        local res = pc('business:supplies:orders:create', OWNER, order)
        assert_true(res.ok)
        assert_eq(bank('mechanic'), 880)
        Mock.exportsByResource['pf-mechanicjob'] = nil    end)
end)