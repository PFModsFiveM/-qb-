-- pf-stores and pf-trucking net callbacks: buying in person, store data for its owner only, and a
-- trucking contract paid only after the cargo was picked up.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/fake_db.lua')
function GetResourceState() return 'started' end
function GetCurrentResourceName() return 'pf-stores' end

-- the bank: transfers always go through and are recorded
local transfers = {}
Mock.exportsByResource['pfm-banking'] = {
    IsLedgerReady = function() return true end,
    Transfer = function(_, opts) transfers[#transfers + 1] = opts return { ok = true, txId = #transfers } end,
    LedgerAutoKey = function(_, prefix) return prefix .. ':' .. (#transfers + 1) end,
    EnsureSocietyAccount = function() return true end,
    GetAccountBalance = function() return 1234 end,
}
Mock.exportsByResource['pf-government'] = {
    GetSalesTaxBreakdown = function(_, subtotal) return { subtotal = subtotal, tax = 0, total = subtotal, rate = 0 } end,
}

Config = {
    Stores = {
        corner = {
            id = 'corner', label = 'Corner Store', type = 'purchasable',
            purchase = { price = 5000, moneyType = 'bank', coords = vector4(100.0, 0.0, 0.0, 0.0) },
            npc = { coords = vector4(110.0, 0.0, 0.0, 0.0) },
            storefront = { enabled = true, moneyTypes = { 'cash', 'bank' }, items = { { name = 'sandwich', price = 10, maxQuantity = 20 } } },
        },
    },
    Delivery = { DropoffRadius = 80.0, ReturnRadius = 35.0, MinSeconds = 45, MaxAverageSpeed = 45.0 },
    WorkTruck = { Enabled = false },
}

local S = {}
FakeDB.extraPatterns = {
    { 'SELECT store_id, label, store_type, owner_citizenid, purchased_at FROM pf_stores WHERE store_id = ?', function(p) return { S.rows[p[1]] } end },
    { 'SELECT owner_citizenid FROM pf_stores WHERE store_id = ?', function(p) local r = S.rows[p[1]] return { { owner_citizenid = r and r.owner_citizenid } } end },
    { 'UPDATE pf_stores SET owner_citizenid = ?', function(p)
        local r = S.rows[p[3]]
        if not r or (r.owner_citizenid ~= nil and r.owner_citizenid ~= '') then return 0 end
        r.owner_citizenid = p[1]
        return 1
    end },
    { 'SELECT item, price FROM pf_store_prices', function() return {} end },
    { 'SELECT supply_name, stock_cases FROM pf_store_supply_stock WHERE store_id = ?', function() return { { supply_name = 'sandwich', stock_cases = S.stock } } end },
    { 'UPDATE pf_store_supply_stock SET stock_cases = stock_cases - ?', function(p) S.stock = S.stock - p[1] return 1 end },
    { 'UPDATE pf_store_supply_stock SET stock_cases = stock_cases + ?', function(p) S.stock = S.stock + p[1] return 1 end },
    { 'INSERT INTO pf_store_ledger', function() return 1 end },
}

load_resource('[pfscripts]/pf-stores/server_orders.lua')
load_resource('[pfscripts]/pf-stores/server.lua')
load_resource('[pfscripts]/pf-trucking/server.lua')

local OWNER, SHOPPER, DRIVER = 1, 2, 3
local SHOP = vector3(110.0, 0.0, 0.0)
local PICKUP, DROP = vector3(0.0, 0.0, 0.0), vector3(3000.0, 0.0, 0.0)
local function cb(name, src, ...) return Mock.callCallback(name, src, ...) end
local given = {}

BeforeEach = function()
    Mock.reset()
    FakeDB.reset()
    transfers, given = {}, {}
    Mock.clock = (Mock.clock or 1700000000) + 1000
    S.rows = { corner = { store_id = 'corner', label = 'Corner Store', store_type = 'purchasable', owner_citizenid = 'OWN1', purchased_at = 1 } }
    S.stock = 10
    Mock.players, Mock.coords = {}, {}
    for src, cid in pairs({ [OWNER] = 'OWN1', [SHOPPER] = 'SHOP1', [DRIVER] = 'DRV1' }) do
        local p = Mock.newPlayer(src, cid)
        p.Functions.AddItem = function(name, qty) given[#given + 1] = { name = name, qty = qty } return true end
        p.Functions.RemoveItem = function() return true end
    end
    Mock.callCallback('pf-trucking:server:cancelActiveJob', DRIVER)
end

describe('pf-stores in person', function()
    it('the storefront sells only to someone at the store', function()
        Mock.coords[SHOPPER] = vector3(-2000.0, 500.0, 0.0)
        local res = cb('pf-stores:server:storefrontCheckout', SHOPPER, 'corner', { { name = 'sandwich', quantity = 2 } }, 'cash')
        assert_false(res.ok)
        assert_eq(res.error, 'too_far')
        assert_eq(#given, 0)
        assert_eq(#transfers, 0)
        Mock.coords[SHOPPER] = SHOP
        assert_true(cb('pf-stores:server:storefrontCheckout', SHOPPER, 'corner', { { name = 'sandwich', quantity = 2 } }, 'cash').ok)
        assert_eq(given[1].qty, 2)
    end)
    it('a store is bought at its for-sale sign', function()
        S.rows.corner.owner_citizenid = nil
        Mock.coords[SHOPPER] = vector3(-2000.0, 500.0, 0.0)
        assert_eq(cb('pf-stores:server:purchaseStore', SHOPPER, 'corner').error, 'too_far')
        assert_eq(#transfers, 0)
        Mock.coords[SHOPPER] = vector3(100.0, 0.0, 0.0)
        assert_true(cb('pf-stores:server:purchaseStore', SHOPPER, 'corner').ok)
        assert_eq(S.rows.corner.owner_citizenid, 'SHOP1')
    end)
    it('the owner and the store balance are shown to the owner only', function()
        local other = cb('pf-stores:server:getStore', SHOPPER, 'corner')
        assert_true(other.ok)
        assert_eq(other.data.owner_citizenid, nil)
        assert_eq(other.data.balance, nil)
        assert_true(other.data.owned)
        local own = cb('pf-stores:server:getStore', OWNER, 'corner')
        assert_eq(own.data.owner_citizenid, 'OWN1')
        assert_eq(own.data.balance, 1234)
    end)
    it('a withdrawal of NaN is refused', function()
        local res = cb('pf-stores:server:withdrawBalance', OWNER, { storeId = 'corner', amount = 0/0 })
        assert_eq(res.error, 'invalid_amount')
        assert_eq(#transfers, 0)
    end)
end)

describe('pf-trucking contract steps', function()
    local function post()
        return Mock.selfExport('CreateExternalJob')({
            title = 'Haul', payout = 1000,
            stops = { { label = 'Pickup', coords = PICKUP }, { label = 'Drop', coords = DROP } },
        })
    end
    it('driving to the drop-off without picking up the cargo pays nothing', function()
        local id = post()
        Mock.coords[DRIVER] = PICKUP
        assert_true(cb('pf-trucking:server:claimContract', DRIVER, id).ok)
        Mock.coords[DRIVER] = DROP
        Mock.clock = Mock.clock + 600
        local res = cb('pf-trucking:server:completeActiveJob', DRIVER)
        assert_false(res.ok)
        assert_eq(#transfers, 0)
        -- loading far from the pickup does not count
        Mock.fireNet('pf-trucking:server:cargoLoaded', DRIVER)
        assert_false(cb('pf-trucking:server:completeActiveJob', DRIVER).ok)
        -- the real run: hook the trailer at the pickup, then deliver; paid once
        Mock.coords[DRIVER] = PICKUP
        Mock.fireNet('pf-trucking:server:cargoLoaded', DRIVER)
        Mock.coords[DRIVER] = DROP
        assert_true(cb('pf-trucking:server:completeActiveJob', DRIVER).ok)
        assert_false(cb('pf-trucking:server:completeActiveJob', DRIVER).ok)
        assert_eq(#transfers, 1)
        assert_eq(transfers[1].amount, 1000)
    end)
end)
