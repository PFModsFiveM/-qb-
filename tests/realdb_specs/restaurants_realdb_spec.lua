-- pf-restaurants on a real database: stock as persistent stashes, supplies through the shared order
-- service, all-or-nothing cooking from restaurant stock, server-priced orders paid through the ledger.
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
loadConfig('pfm-worldobjects/config.lua')
-- pf-restaurants' config files add to one Config table
Config = nil
load_resource('[pfscripts]/pf-restaurants/config/shared.lua')
load_resource('[pfscripts]/pf-restaurants/config/items.lua')
load_resource('[pfscripts]/pf-restaurants/config/restaurants.lua')
load_resource('[pfscripts]/pf-restaurants/config/stations.lua')
load_resource('[pfscripts]/pf-restaurants/config/recipes.lua')
for k, v in pairs(Config) do merged[k] = v end
Config = merged
Config.SupplyChain = { PlayerSuppliers = false, AIMarkup = 0.15, DriverPrioritySeconds = 120, AIDeliverySeconds = 300, PalletModel = 'prop_boxpile_06b' }
Config.Logging.Enabled = false
QBCoreMock.Shared.Items.supply_crate = { name = 'supply_crate', label = 'Supply Crate', weight = 5000, type = 'item', unique = true, image = 'x.png' }

-- pf-government stand-in: 10% sales tax, records what it collects
Gov = { collected = {} }
Mock.exportsByResource['pf-government'] = {
    GetSalesTaxRate = function() return 0.10 end,
    CollectTaxAmount = function(_, amount, _, _, _, _, key) Gov.collected[key] = amount return amount end,
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
load_resource('[pfscripts]/pf-stores/server_orders.lua')
load_resource('pfm-worldobjects/server.lua')
QBCore = QBCoreMock
for _, f in ipairs({ 'main', 'persistence', 'business', 'recipes', 'menu', 'orders', 'stations', 'inventory', 'equipment', 'hygiene', 'fire', 'placeholders_government', 'integration' }) do
    load_resource('[pfscripts]/pf-restaurants/server/' .. f .. '.lua')
end
for _, res in ipairs({ 'pfm-banking', 'pfm-inventory', 'pf-stores', 'pfm-worldobjects', 'pf-restaurants' }) do
    Mock.exportsByResource[res] = Mock.exportsByResource['__self']
end

local L, O = PFLedger, PFOrders
local BID = 'burgershot_vespucci'
local COOK, CASHIER, CUSTOMER, STRANGER = 1, 2, 3, 4
local GRILL = vector3(-1200.5, -891.2, 13.98)
local REGISTER = vector3(-1195.5, -892.0, 13.98)

assert(L.Start(), 'ledger start')
assert(O.Start(), 'orders start')
assert(PFWorldObjects.Start(), 'world objects start')
InitRestaurants()
assert(RestaurantDB.Boot(), 'restaurants boot')
for src, cid in pairs({ [COOK] = 'COOK1', [CASHIER] = 'CASH1', [CUSTOMER] = 'CUST1', [STRANGER] = 'STR1' }) do
    MySQL.query.await("INSERT INTO players (citizenid, cid, license, name, money, charinfo, job, gang, position, metadata, inventory) VALUES (?, 1, ?, ?, '{\"cash\":0,\"bank\":0}', '{}', '{}', '{}', '{}', '{}', '[]')", { cid, 'license:' .. cid, cid })
end

local function stashCount(storage, item)
    local inv = exports['pfm-inventory']:GetInventory(StockStashId(BID, storage))
    local n = 0
    for _, it in pairs(inv and inv.items or {}) do if it.name == item then n = n + it.amount end end
    return n
end
local function society(name) return tonumber(MySQL.scalar.await('SELECT account_balance FROM bank_accounts WHERE account_name = ?', { name })) or 0 end
local function fund(amount)
    assert(L.EnsureSociety('restaurant_' .. BID, 'business'))
    assert(L.Transfer({ from = 'system:test', to = 'society:restaurant_' .. BID, amount = amount, key = L.AutoKey('fund'), kind = 'test' }).ok)
end
local function supply(item, qty)
    fund(qty * 4)
    local res = O.Create(COOK, { kind = 'restaurant', buyerId = BID, method = 'pickup', cart = { { name = item, quantity = qty } } })
    assert(res.ok, 'supply order: ' .. tostring(res.error))
    return res
end
local function bank(src) return Mock.players[src].PlayerData.money.bank end
local function cash(src) return Mock.players[src].PlayerData.money.cash end
local function lastSession()
    local ev = Mock.clientEventsNamed('pf-restaurants:client:stationSessionStart')
    return ev[#ev] and ev[#ev].args[4]
end

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 1000
    Mock.players = {}
    for src, cid in pairs({ [COOK] = 'COOK1', [CASHIER] = 'CASH1', [CUSTOMER] = 'CUST1', [STRANGER] = 'STR1' }) do
        local p = Mock.newPlayer(src, cid)
        p.PlayerData.items = {}
        p.PlayerData.money = { cash = 200, bank = 200 }
        p.PlayerData.job = { name = 'unemployed', onduty = false, grade = { level = 0 } }
    end
    Mock.players[COOK].PlayerData.job = { name = 'burgershot', onduty = true, isboss = true, grade = { level = 4 } }
    Mock.players[CASHIER].PlayerData.job = { name = 'burgershot', onduty = true, isboss = false, grade = { level = 2 } }
    Mock.coords = { [COOK] = GRILL, [CASHIER] = REGISTER, [CUSTOMER] = REGISTER, [STRANGER] = GRILL }
end

describe('restaurant stock', function()
    it('restaurant items are registered with the inventory and freshness', function()
        assert_true(QBCoreMock.Shared.Items.raw_beef_patty ~= nil)
        assert_true(QBCoreMock.Shared.Items.patty_cooked ~= nil)
        assert_true(PFFreshness.IsPerishable('raw_beef_patty'))
    end)
    it('supplies ordered through the shared order service land in the right storage area', function()
        supply('raw_beef_patty', 10)
        supply('raw_bacon', 4)
        assert_eq(stashCount('freezer', 'raw_beef_patty'), 10)
        assert_eq(stashCount('fridge', 'raw_bacon'), 4)
        local saved = MySQL.scalar.await('SELECT items FROM inventories WHERE identifier = ?', { StockStashId(BID, 'freezer') })
        assert_true(saved and saved:find('raw_beef_patty') ~= nil, 'stock saved in the database')
    end)
    it('a stranger cannot order supplies for the restaurant', function()
        local res = O.Create(STRANGER, { kind = 'restaurant', buyerId = BID, method = 'pickup', cart = { { name = 'raw_bacon', quantity = 1 } } })
        assert_eq(res.error, 'not_owner')
    end)
end)

describe('cooking', function()
    it('only staff at the station can cook', function()
        Mock.fireNet('pf-restaurants:server:startStationAction', STRANGER, BID, 'bs_grill_1', 1, { action = 'grill_bacon', inputItems = { { item = 'raw_bacon', qty = 2 } } })
        assert_eq(stashCount('fridge', 'raw_bacon'), 4)
        Mock.coords[COOK] = vector3(0.0, 0.0, 0.0)
        Mock.fireNet('pf-restaurants:server:startStationAction', COOK, BID, 'bs_grill_1', 1, { action = 'grill_bacon', inputItems = { { item = 'raw_bacon', qty = 2 } } })
        assert_eq(stashCount('fridge', 'raw_bacon'), 4)
    end)
    it('cooking takes the ingredients from restaurant stock, not the cook', function()
        Mock.fireNet('pf-restaurants:server:startStationAction', COOK, BID, 'bs_grill_1', 1, { action = 'grill_bacon', inputItems = { { item = 'raw_bacon', qty = 2 } } })
        assert_eq(stashCount('fridge', 'raw_bacon'), 2)
        local session = lastSession()
        assert_true(session ~= nil)
        -- a dish without doneness is not ready before its time
        Mock.fireNet('pf-restaurants:server:completeStationAction', COOK, session.sessionId)
        assert_eq(exports['pfm-inventory']:GetItemCount(COOK, 'bacon_cooked'), 0)
        Mock.clock = Mock.clock + 26
        Mock.fireNet('pf-restaurants:server:completeStationAction', COOK, session.sessionId)
        assert_eq(exports['pfm-inventory']:GetItemCount(COOK, 'bacon_cooked'), 2)
        Mock.fireNet('pf-restaurants:server:completeStationAction', COOK, session.sessionId)
        assert_eq(exports['pfm-inventory']:GetItemCount(COOK, 'bacon_cooked'), 2, 'one output per session')
    end)
    it('with stock for one batch, a second cook gets nothing and nothing extra is taken', function()
        Mock.fireNet('pf-restaurants:server:startStationAction', COOK, BID, 'bs_grill_1', 2, { action = 'grill_bacon', inputItems = { { item = 'raw_bacon', qty = 2 } } })
        Mock.fireNet('pf-restaurants:server:startStationAction', COOK, BID, 'bs_grill_1', 3, { action = 'grill_bacon', inputItems = { { item = 'raw_bacon', qty = 2 } } })
        assert_eq(stashCount('fridge', 'raw_bacon'), 0)
        local sessions = 0
        for _, st in pairs(RestaurantData.stations[BID]) do for _ in pairs(st.sessions) do sessions = sessions + 1 end end
        assert_eq(sessions, 1, 'the second one did not start')
    end)
    it('a cook who disconnects mid-session gives the ingredients back', function()
        Mock.fireEvent('playerDropped', COOK)
        assert_eq(stashCount('fridge', 'raw_bacon'), 2)
    end)
    it('a recipe with one ingredient missing consumes nothing', function()
        local before = stashCount('freezer', 'raw_beef_patty')
        local ok, missing = ConsumeIngredients(BID, { { item = 'raw_beef_patty', qty = 1 }, { item = 'tomato', qty = 3 } })
        assert_false(ok)
        assert_eq(missing, 'tomato')
        assert_eq(stashCount('freezer', 'raw_beef_patty'), before)
    end)
end)

describe('deliveries left packed', function()
    local function pctOf(storage, item, batchNot)
        local inv = exports['pfm-inventory']:GetInventory(StockStashId(BID, storage))
        local out = {}
        for _, it in pairs(inv.items) do
            if it.name == item then out[#out + 1] = exports['pfm-inventory']:GetFreshness(it.name, it.info).pct end
        end
        table.sort(out)
        return out
    end
    it('the unpack gets the delivery time from the order service', function()
        local adapter = O.kinds.restaurant
        local realUnpack, seen = adapter.unpack, nil
        adapter.unpack = function(...) seen = { ... } return realUnpack(...) end
        supply('lettuce', 1)
        adapter.unpack = realUnpack
        -- leave the restaurant account as it was (supply() funds a little more than it spends)
        local left = society('restaurant_' .. BID)
        if left > 0 then assert(L.Transfer({ from = 'society:restaurant_' .. BID, to = 'system:test', amount = left, key = L.AutoKey('drain'), kind = 'test' }).ok) end
        assert_true(type(seen[4]) == 'number' and math.abs(seen[4] - os.time()) <= 5, 'deliveredAt passed: ' .. tostring(seen and seen[4]))
    end)
    it('spoil normally for 30 minutes, then faster, for as long as they stay packed', function()
        local adapter = O.kinds.restaurant
        local now = os.time()
        assert_true(adapter.unpack(BID, { { name = 'tomato', quantity = 1 } }, 0, now))               -- unpacked at once
        assert_true(adapter.unpack(BID, { { name = 'tomato', quantity = 1 } }, 0, now - 20 * 60))     -- inside the grace
        assert_true(adapter.unpack(BID, { { name = 'tomato', quantity = 1 } }, 0, now - 6 * 3600))    -- left out 6 hours
        local pcts = pctOf(StorageFor('tomato'), 'tomato')
        assert_eq(#pcts, 3, 'three separate batches')
        local life = 4 * 86400                                  -- produce shelf life
        local graceLoss = 100 * (20 * 60) / life                -- normal rate inside the grace
        local lateLoss = 100 * (1800 + (6 * 3600 - 1800) * Config.Freshness.Storage.outdoor) / life
        assert_true(math.abs(pcts[3] - 100) < 0.5, 'fresh: ' .. pcts[3])
        assert_true(math.abs((100 - pcts[2]) - graceLoss) < 0.5, ('grace %.2f vs %.2f'):format(100 - pcts[2], graceLoss))
        assert_true(math.abs((100 - pcts[1]) - lateLoss) < 0.5, ('late %.2f vs %.2f'):format(100 - pcts[1], lateLoss))
    end)
end)

describe('installed equipment', function()
    it('a fridge installed in an approved slot enlarges the fridge stock area', function()
        local gov = Mock.exportsByResource['pf-government']
        local inv = exports['pfm-inventory']:GetInventory(StockStashId(BID, 'fridge'))
        local base = inv.maxweight
        gov.GetInstalledEquipment = function(_, id)
            if id ~= 'restaurant:' .. BID then return {} end
            return { { equipmentType = 'fridge_commercial', slotType = 'fridge', storage = { area = 'fridge', capacity = 150 } } }
        end
        TriggerEvent('pf-government:server:equipmentChanged', 'restaurant:' .. BID)
        assert_eq(exports['pfm-inventory']:GetInventory(StockStashId(BID, 'fridge')).maxweight, base + 150 * 1000)
        assert_eq(exports['pfm-inventory']:GetInventory(StockStashId(BID, 'freezer')).maxweight, (Config.Restaurants[BID].storage.freezer.capacity or 300) * 1000, 'other areas unchanged')
        gov.GetInstalledEquipment = nil
        TriggerEvent('pf-government:server:equipmentChanged', 'restaurant:' .. BID)
        assert_eq(exports['pfm-inventory']:GetInventory(StockStashId(BID, 'fridge')).maxweight, base)
    end)
end)

describe('government record', function()
    it('staff changes update the owner and the employee count', function()
        local gov = Mock.exportsByResource['pf-government']
        local counted
        gov.UpdateBusinessEmployees = function(_, id, n) counted = { id = id, n = n } return true end
        RestaurantDB.SaveEmployee(BID, 'EMP9', 'cook')
        assert_eq(counted.id, 'restaurant:' .. BID)
        local n = tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM pf_restaurant_employees WHERE business_id = ?', { BID }))
        assert_eq(counted.n, n)
        RestaurantDB.DeleteEmployee(BID, 'EMP9')
        assert_eq(counted.n, n - 1)
        gov.UpdateBusinessEmployees = nil
    end)
end)

describe('ownership from the government', function()
    it('moves the owner role to the new citizen and removes the old owner', function()
        local function owners()
            local out = {}
            for _, r in ipairs(MySQL.query.await("SELECT citizenid FROM pf_restaurant_employees WHERE business_id = ? AND role = 'owner'", { BID })) do out[#out + 1] = r.citizenid end
            return out
        end
        RestaurantDB.SaveEmployee(BID, 'COOK1', 'owner')
        RestaurantData.employees[BID] = RestaurantData.employees[BID] or {}
        RestaurantData.employees[BID]['COOK1'] = { citizenid = 'COOK1', role = 'owner' }
        local realInvoker = GetInvokingResource
        GetInvokingResource = function() return 'pf-government' end
        assert_true(exports['pf-restaurants']:SetOwnerFromGovernment(BID, 'CASH1'))
        assert_false(exports['pf-restaurants']:SetOwnerFromGovernment(BID, 'NOBODY'), 'unknown citizen')
        GetInvokingResource = function() return 'pf-stores' end
        assert_false(exports['pf-restaurants']:SetOwnerFromGovernment(BID, 'COOK1'), 'only pf-government')
        GetInvokingResource = realInvoker
        local list = owners()
        assert_eq(#list, 1)
        assert_eq(list[1], 'CASH1')
        assert_eq(RestaurantData.employees[BID]['COOK1'], nil)
        assert_eq(RestaurantData.employees[BID]['CASH1'].role, 'owner')
        -- back to the staff the other tests expect (roles from job grades)
        for _, cid in ipairs({ 'COOK1', 'CASH1' }) do
            MySQL.query.await('DELETE FROM pf_restaurant_employees WHERE business_id = ? AND citizenid = ?', { BID, cid })
            RestaurantData.employees[BID][cid] = nil
        end
    end)
end)

describe('health inspections', function()
    it('go on the government record with the compliance the rating gives', function()
        local gov = Mock.exportsByResource['pf-government']
        local recorded
        gov.HasPermission = function(_, _, perm) return perm == 'licenses' end
        gov.RecordBusinessInspection = function(_, id, status, findings, cid) recorded = { id = id, status = status, findings = findings, cid = cid } return true end
        RestaurantData.businesses[BID].hygiene.dirtLevel = 0
        Mock.coords[STRANGER] = REGISTER
        Mock.fireNet('pf-restaurants:server:conductInspection', STRANGER, BID)
        gov.HasPermission = function() return false end
        gov.RecordBusinessInspection = nil
        assert_true(recorded ~= nil, 'recorded with the government')
        assert_eq(recorded.id, 'restaurant:' .. BID)
        assert_eq(recorded.cid, 'STR1')
        local rating = RestaurantData.businesses[BID].hygiene.healthRating
        local expected = ({ A = 'compliant', B = 'compliant', C = 'warning', D = 'non_compliant', F = 'flagged' })[rating]
        assert_eq(recorded.status, expected)
    end)
end)

describe('power cuts', function()
    it('a fridge without power keeps nothing cold until the power is back', function()
        local function chilledPct()
            local inv = exports['pfm-inventory']:GetInventory(StockStashId(BID, 'fridge'))
            for _, it in pairs(inv.items) do
                if it.name == 'raw_chicken_breast' then return exports['pfm-inventory']:GetFreshness(it.name, it.info).pct end
            end
        end
        assert_true(exports['pfm-inventory']:AddItem(StockStashId(BID, 'fridge'), 'raw_chicken_breast', 1, nil, nil, 'test'))
        local gov = Mock.exportsByResource['pf-government']
        gov.CanBusinessTrade = function() return false, 'no_power' end
        RestaurantDB.CheckColdStorage(BID)
        Mock.clock = Mock.clock + 3600
        local afterCut = chilledPct()
        gov.CanBusinessTrade = function() return true end
        RestaurantDB.CheckColdStorage(BID)
        Mock.clock = Mock.clock + 3600
        local afterRestore = chilledPct()
        gov.CanBusinessTrade = nil
        local life = 86400                                                     -- meat
        local cutLoss = 100 * 3600 * Config.Freshness.Storage.broken_fridge / life
        local coldLoss = 100 * 3600 * Config.Freshness.Storage.fridge / life
        assert_true(math.abs((100 - afterCut) - cutLoss) < 0.5, ('hour without power: lost %.2f, expected %.2f'):format(100 - afterCut, cutLoss))
        assert_true(math.abs((afterCut - afterRestore) - coldLoss) < 0.5, ('hour with power: lost %.2f, expected %.2f'):format(afterCut - afterRestore, coldLoss))
    end)
end)

describe('freshness', function()
    it('freezer stock keeps longer than stock left out, and expired food is kept, not deleted', function()
        assert_true(exports['pfm-inventory']:AddItem(StockStashId(BID, 'dry'), 'raw_beef_patty', 1, nil, nil, 'test'))
        Mock.clock = Mock.clock + 2 * 86400
        local frozen, dry
        for _, storage in ipairs({ 'freezer', 'dry' }) do
            local inv = exports['pfm-inventory']:GetInventory(StockStashId(BID, storage))
            for _, it in pairs(inv.items) do
                if it.name == 'raw_beef_patty' then
                    local f = exports['pfm-inventory']:GetFreshness(it.name, it.info)
                    if storage == 'freezer' then frozen = f.pct else dry = f.pct end
                end
            end
        end
        assert_true(frozen > dry, ('freezer %s%% vs dry %s%%'):format(tostring(frozen), tostring(dry)))
        assert_eq(dry, 0, 'spoiled after 2 days out (meat lasts 1)')
        assert_eq(stashCount('dry', 'raw_beef_patty'), 1, 'still there: spoiled, not deleted')
    end)
end)

describe('orders', function()
    local menuId
    it('the menu price is the server one; staff set it within limits', function()
        Mock.fireNet('pf-restaurants:server:createMenuItem', COOK, BID, { recipeId = 'burger_classic', price = -5 })
        assert_eq(next(RestaurantData.menus[BID] or {}), nil)
        Mock.fireNet('pf-restaurants:server:createMenuItem', COOK, BID, { recipeId = 'burger_classic', price = 10 })
        menuId = next(RestaurantData.menus[BID])
        assert_true(menuId ~= nil)
        assert_true(MySQL.scalar.await('SELECT data FROM pf_restaurant_menu WHERE menu_item_id = ?', { menuId }) ~= nil, 'menu saved')
    end)
    it('a customer is charged only after accepting, at the server price, with tax to the government', function()
        Mock.fireNet('pf-restaurants:server:createOrder', CASHIER, BID, { items = { { menuItemId = menuId, qty = 2, price = 0.01 } }, subtotal = 0.02, paymentMethod = 'cash', customerId = CUSTOMER })
        assert_eq(cash(CUSTOMER), 200, 'nothing taken before accepting')
        local bill = Mock.clientEventsNamed('pf-restaurants:client:confirmPayment')[1].args[1]
        assert_eq(bill.total, 22)
        Mock.fireNet('pf-restaurants:server:answerPayment', STRANGER, bill.orderId, true)
        assert_eq(cash(CUSTOMER), 200, 'only the customer can accept')
        Mock.fireNet('pf-restaurants:server:answerPayment', CUSTOMER, bill.orderId, true)
        assert_eq(cash(CUSTOMER), 178)
        assert_eq(society('restaurant_' .. BID), 20, 'revenue to the restaurant account')
        assert_eq(Gov.collected['restaurant:' .. bill.orderId .. ':tax'], 2)
        Mock.fireNet('pf-restaurants:server:answerPayment', CUSTOMER, bill.orderId, true)
        assert_eq(cash(CUSTOMER), 178, 'paid once')
    end)
    it('orders need a register, valid quantities and a cash/card payment', function()
        Mock.coords[CASHIER] = vector3(0.0, 0.0, 0.0)
        Mock.fireNet('pf-restaurants:server:createOrder', CASHIER, BID, { items = { { menuItemId = menuId, qty = 1 } }, paymentMethod = 'cash' })
        Mock.coords[CASHIER] = REGISTER
        Mock.fireNet('pf-restaurants:server:createOrder', CASHIER, BID, { items = { { menuItemId = menuId, qty = 0.5 } }, paymentMethod = 'cash' })
        Mock.fireNet('pf-restaurants:server:createOrder', CASHIER, BID, { items = { { menuItemId = menuId, qty = 1 } }, paymentMethod = 'crypto' })
        Mock.fireNet('pf-restaurants:server:createOrder', STRANGER, BID, { items = { { menuItemId = menuId, qty = 1 } }, paymentMethod = 'cash' })
        assert_eq(cash(CASHIER), 200)
        assert_eq(#Mock.clientEventsNamed('pf-restaurants:client:newOrder'), 0)
    end)
    it('status changes follow the kitchen path, and a completed order is refunded once from the restaurant', function()
        Mock.fireNet('pf-restaurants:server:createOrder', CASHIER, BID, { items = { { menuItemId = menuId, qty = 1 } }, paymentMethod = 'cash' })
        local order = Mock.clientEventsNamed('pf-restaurants:client:newOrder')[1].args[2]
        assert_eq(cash(CASHIER), 189, 'the cashier paid for themselves')
        Mock.fireNet('pf-restaurants:server:updateOrderStatus', CASHIER, order.orderId, 'completed')
        assert_eq(RestaurantData.orders[order.orderId].status, 'placed', 'cannot skip the kitchen')
        Mock.fireNet('pf-restaurants:server:updateOrderStatus', CASHIER, order.orderId, 'preparing')
        assert_eq(RestaurantData.orders[order.orderId].status, 'placed', 'a cashier has no kitchen display')
        for _, st in ipairs({ 'preparing', 'ready', 'completed' }) do Mock.fireNet('pf-restaurants:server:updateOrderStatus', COOK, order.orderId, st) end
        local before = society('restaurant_' .. BID)
        Mock.fireNet('pf-restaurants:server:refundOrder', CASHIER, order.orderId, 'cashier cannot refund')
        assert_eq(cash(CASHIER), 189)
        Mock.fireNet('pf-restaurants:server:refundOrder', COOK, order.orderId, 'cold fries')
        assert_eq(cash(CASHIER), 200)
        assert_eq(society('restaurant_' .. BID), before - 11)
        Mock.fireNet('pf-restaurants:server:refundOrder', COOK, order.orderId, 'again')
        assert_eq(cash(CASHIER), 200, 'refunded once')
    end)
    it('a voided order is refunded; a void cannot repeat', function()
        Mock.fireNet('pf-restaurants:server:createOrder', CASHIER, BID, { items = { { menuItemId = menuId, qty = 1 } }, paymentMethod = 'card' })
        local order = Mock.clientEventsNamed('pf-restaurants:client:newOrder')[1].args[2]
        assert_eq(bank(CASHIER), 189)
        Mock.fireNet('pf-restaurants:server:voidOrder', COOK, order.orderId, 'mistake')
        assert_eq(bank(CASHIER), 200)
        Mock.fireNet('pf-restaurants:server:voidOrder', COOK, order.orderId, 'mistake')
        assert_eq(bank(CASHIER), 200)
    end)
end)

describe('after a restart', function()
    it('menus, staff and open orders come back from the database', function()
        Mock.fireNet('pf-restaurants:server:addEmployee', COOK, BID, 'STR1', 'cashier')
        Mock.fireNet('pf-restaurants:server:createOrder', CASHIER, BID, { items = { { menuItemId = next(RestaurantData.menus[BID]), qty = 1 } }, paymentMethod = 'cash' })
        local open = Mock.clientEventsNamed('pf-restaurants:client:newOrder')[1].args[2].orderId
        RestaurantData.menus, RestaurantData.employees, RestaurantData.orders = {}, {}, {}
        RestaurantDB.Load()
        assert_true(next(RestaurantData.menus[BID]) ~= nil)
        assert_eq(RestaurantData.employees[BID].STR1.role, 'cashier')
        assert_true(RestaurantData.orders[open] ~= nil)
    end)
end)

describe('books', function()
    it('the ledger reconciles', function()
        local report = L.Reconcile()
        for _, m in ipairs(report.mismatches) do print('mismatch', m.account, m.expected, m.actual) end
        assert_eq(#report.mismatches, 0)
    end)
end)
