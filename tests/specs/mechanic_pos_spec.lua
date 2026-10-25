-- pf-mechanicjob POS (server/register_pos.lua) and the tablet checkout (server/tablet.lua) on the
-- pfm-banking ledger: the customer pays, the shop's bank account receives the takings, the commission
-- comes out of the takings, and nobody can mint money or pick another shop's account.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/fake_db.lua')
function GetCurrentResourceName() return 'pfm-banking' end
local govRunning = false
function GetResourceState(name)
    if name == 'pf-government' then return govRunning and 'started' or 'missing' end
    if name == 'pf-computer' then return 'missing' end
    return 'started'
end
local gov = { registered = {}, revenue = {}, closed = {} }

QBCoreMock.Shared.Jobs = { mechanic = { label = 'Mechanic' }, bennys = { label = "Benny's" }, police = { label = 'Police' } }

Config = nil
load_resource('pfm-banking/config.lua')
load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')
Mock.exportsByResource['pfm-banking'] = Mock.exportsByResource['__self']

-- pf-mechanicjob's own config, merged into the shared Config
local bankingConfig = Config
Config = nil
load_resource('[pfscripts]/pf-mechanicjob/config.lua')
for k, v in pairs(bankingConfig) do if Config[k] == nil then Config[k] = v end end
Config.DefaultTax = 0.10
Config.UseGovernmentTax = false
Config.RegisterItems = nil
Config.ReceiptItems = {}

FakeDB.extraPatterns = {
    { 'SELECT item_id, category, label, price FROM pf_pos_items WHERE business = ?', function()
        return { { item_id = 'oil_change', category = 'service', label = 'Oil Change', price = 100 },
                 { item_id = 'tire', category = 'tires', label = 'Tire', price = 50 } }
    end },
    { 'SELECT item, label, category, price, is_custom, is_deleted FROM mechanic_prices', function() return {} end },
    { 'SELECT item FROM mechanic_mandatory_charges', function() return {} end },
    { 'SELECT name FROM pf_business', function() return nil end },
    { 'INSERT INTO pf_pos_transactions', function() return 1 end },
    { 'INSERT INTO pf_mechanic_transactions', function() return 1 end },
}

load_resource('[pfscripts]/pf-mechanicjob/server/register_pos.lua')
load_resource('[pfscripts]/pf-mechanicjob/server/tablet.lua')

local L = PFLedger
local MECH, CUST, RIVAL, CIV = 1, 2, 3, 4
local CART = { { item = 'oil_change', qty = 1 }, { item = 'tire', qty = 1 } }  -- 150 + 10% tax = 165

local function money(src, kind) return Mock.players[src].PlayerData.money[kind or 'bank'] end
local function shop(name) return FakeDB.bank_accounts[name] and FakeDB.bank_accounts[name].account_balance or 0 end
local function charge(src, data) Mock.fireNet('mechanic:server:chargeCustomer', src, data) end
-- the bill most recently sent to a customer's screen
local function lastBill()
    local bills = Mock.clientEventsNamed('mechanic:client:confirmCharge')
    return bills[#bills] and bills[#bills].args[1]
end
local function answer(src, bill, accept) Mock.fireNet('mechanic:server:answerCharge', src, bill and bill.id, accept) end
-- the mechanic bills the customer and the customer accepts on their screen
local function chargeAndPay(src, data)
    charge(src, data)
    answer(data.customerId, lastBill(), true)
end
local function totalMoney()
    local sum = 0
    for _, p in pairs(Mock.players) do sum = sum + p.PlayerData.money.cash + p.PlayerData.money.bank end
    for _, acc in pairs(FakeDB.bank_accounts) do sum = sum + acc.account_balance end
    return sum
end

BeforeEach = function()
    Mock.clock = Mock.clock + 1000          -- bills left pending by an earlier test expire
    Mock.reset()
    FakeDB.reset()
    FakeDB.migrations = {}
    Mock.players = {}
    Mock.coords = {}
    for k in pairs(BankingAccounts) do BankingAccounts[k] = nil end
    local function player(src, cid, job, isboss)
        local p = Mock.newPlayer(src, cid)
        p.PlayerData.job = { name = job, label = job, isboss = isboss or false, onduty = true, grade = { level = 0 } }
        p.PlayerData.money = { cash = 500, bank = 1000 }
        Mock.coords[src] = vector3(0.0, 0.0, 0.0)
        return p
    end
    player(MECH, 'MECH1', 'mechanic')
    player(CUST, 'CUST1', 'unemployed')
    player(RIVAL, 'RIV1', 'bennys')
    player(CIV, 'CIV1', 'unemployed')
    L.ready, L.failed = false, false
    assert(L.Start(), 'ledger start')
end

describe('mechanic POS', function()
    it('the customer pays, the shop is paid, and the commission comes out of the takings', function()
        local before = totalMoney()
        chargeAndPay(MECH, { customerId = CUST, items = CART, paymentType = 'cash', business = 'mechanic' })
        assert_eq(money(CUST, 'cash'), 335)                             -- 165 charged
        assert_eq(money(MECH), 1033)                                    -- 20% of 165 = 33
        assert_eq(shop('mechanic'), 132)                                -- 165 - 33
        assert_eq(totalMoney(), before)                                 -- nothing created
    end)
    it('the client can no longer send the money to another shop or society', function()
        charge(MECH, { customerId = CUST, items = CART, paymentType = 'cash', business = 'police' })
        assert_eq(money(CUST, 'cash'), 500)
        assert_eq(shop('police'), 0)
        -- without a business name the mechanic's own shop is used
        chargeAndPay(MECH, { customerId = CUST, items = CART, paymentType = 'cash' })
        assert_eq(shop('mechanic'), 132)
    end)
    it('a mechanic of another shop is paid into their own shop', function()
        chargeAndPay(RIVAL, { customerId = CUST, items = CART, paymentType = 'card' })
        assert_eq(shop('bennys'), 132)
        assert_eq(shop('mechanic'), 0)
    end)
    it('someone who is not a mechanic cannot charge anyone', function()
        charge(CIV, { customerId = CUST, items = CART, paymentType = 'cash', business = 'mechanic' })
        assert_eq(money(CUST, 'cash'), 500)
        assert_eq(money(CIV), 1000)
    end)
    it('a customer who is not nearby cannot be charged', function()
        Mock.coords[CUST] = vector3(500.0, 0.0, 0.0)
        charge(MECH, { customerId = CUST, items = CART, paymentType = 'cash' })
        assert_eq(money(CUST, 'cash'), 500)
        assert_eq(money(MECH), 1000)
    end)
    it('a customer who cannot pay is not charged and nobody is paid', function()
        Mock.players[CUST].PlayerData.money.cash = 100
        chargeAndPay(MECH, { customerId = CUST, items = CART, paymentType = 'cash' })
        assert_eq(money(CUST, 'cash'), 100)
        assert_eq(money(MECH), 1000)
        assert_eq(shop('mechanic'), 0)
    end)
    it('charging yourself pays your shop and earns no commission', function()
        charge(MECH, { customerId = MECH, items = CART, paymentType = 'card' })
        assert_eq(money(MECH), 835)
        assert_eq(shop('mechanic'), 165)
    end)
    it('with the bank down nothing is charged', function()
        L.ready = false
        charge(MECH, { customerId = CUST, items = CART, paymentType = 'cash' })
        L.ready = true
        assert_eq(money(CUST, 'cash'), 500)
        assert_eq(money(MECH), 1000)
    end)
end)

describe('mechanic tablet checkout', function()
    it('no longer pays a commission on a client-sent total', function()
        local ok = Mock.callCallback('pf_mech:tablet:checkout', MECH, {}, 1000000000)
        assert_false(ok)
        assert_eq(money(MECH), 1000)
    end)
end)

describe('mechanic POS: the customer confirms the bill', function()
    it('nothing is charged until the customer presses Pay, and the bill shows what they pay', function()
        charge(MECH, { customerId = CUST, items = CART, paymentType = 'cash' })
        local bill = lastBill()
        assert_true(bill ~= nil)
        assert_eq(bill.total, 165)
        assert_eq(#bill.items, 2)
        assert_eq(money(CUST, 'cash'), 500)
        assert_eq(shop('mechanic'), 0)
        answer(CUST, bill, true)
        assert_eq(money(CUST, 'cash'), 335)
    end)
    it('declining charges nothing', function()
        charge(MECH, { customerId = CUST, items = CART, paymentType = 'cash' })
        answer(CUST, lastBill(), false)
        assert_eq(money(CUST, 'cash'), 500)
        assert_eq(money(MECH), 1000)
    end)
    it('only the billed customer can accept, and only once', function()
        charge(MECH, { customerId = CUST, items = CART, paymentType = 'cash' })
        local bill = lastBill()
        answer(CIV, bill, true)                                         -- someone else tries to accept
        assert_eq(money(CUST, 'cash'), 500)
        answer(CUST, bill, true)
        answer(CUST, bill, true)                                        -- a repeated answer
        assert_eq(money(CUST, 'cash'), 335)
        assert_eq(shop('mechanic'), 132)
    end)
    it('an expired bill cannot be paid', function()
        charge(MECH, { customerId = CUST, items = CART, paymentType = 'cash' })
        local bill = lastBill()
        Mock.clock = Mock.clock + 61
        answer(CUST, bill, true)
        assert_eq(money(CUST, 'cash'), 500)
    end)
    it('a customer who walked away before accepting is not charged', function()
        charge(MECH, { customerId = CUST, items = CART, paymentType = 'cash' })
        local bill = lastBill()
        Mock.coords[CUST] = vector3(300.0, 0.0, 0.0)
        answer(CUST, bill, true)
        assert_eq(money(CUST, 'cash'), 500)
    end)
    it('a customer has one bill at a time, and a mechanic waits for an answer', function()
        charge(MECH, { customerId = CUST, items = CART, paymentType = 'cash' })
        local first = lastBill()
        charge(RIVAL, { customerId = CUST, items = CART, paymentType = 'cash' })
        assert_eq(lastBill().id, first.id)                              -- no second bill was sent
        answer(CUST, first, false)
        charge(RIVAL, { customerId = CUST, items = CART, paymentType = 'cash' })
        assert_true(lastBill().id ~= first.id)
    end)
    it('a forged bill id does nothing', function()
        answer(CUST, { id = '999-999' }, true)
        assert_eq(money(CUST, 'cash'), 500)
    end)
end)

describe('mechanic shops in the government registry', function()
    local function withGovernment()
        govRunning = true
        gov.registered, gov.revenue, gov.closed = {}, {}, {}
        Mock.exportsByResource['pf-government'] = {
            RegisterBusinessWithGovernment = function(_, id, label, kind, owner) gov.registered[id] = { kind = kind, owner = owner } return true end,
            AddBusinessRevenue = function(_, id, amount, key, account) gov.revenue[#gov.revenue + 1] = { id = id, amount = amount, key = key, account = account } return true end,
            CanBusinessTrade = function(_, id) if gov.closed[id] then return false, gov.closed[id] end return true end,
            CollectTaxAmount = function(_, tax) return 0 end,
        }
    end
    it('a sale registers the shop and is reported once, with the shop account', function()
        withGovernment()
        chargeAndPay(MECH, { customerId = CUST, items = CART, paymentType = 'cash' })
        assert_eq(gov.registered['mechanic:mechanic'].kind, 'mechanic')
        assert_eq(#gov.revenue, 1)
        assert_eq(gov.revenue[1].id, 'mechanic:mechanic')
        assert_eq(gov.revenue[1].amount, 150)
        assert_eq(gov.revenue[1].account, 'society:mechanic')
        govRunning = false
    end)
    it('a shop the government closed cannot charge customers', function()
        withGovernment()
        gov.closed['mechanic:mechanic'] = 'closed'
        chargeAndPay(MECH, { customerId = CUST, items = CART, paymentType = 'cash' })
        assert_eq(money(CUST, 'cash'), 500)
        assert_eq(shop('mechanic'), 0)
        assert_eq(#gov.revenue, 0)
        govRunning = false
    end)
end)
