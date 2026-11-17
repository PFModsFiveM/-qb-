-- Batch 20 unit 20C on a real database, through the real ledger, inventory and order service:
--   1. a department manager orders hospital supplies: pf-stores prices the cart through the
--      'facility' adapter (registered across the resource boundary, funcrefs), charges
--      society:ambulance once (supply:<id>:charge), the AI supplier and driver deliver, the goods are
--      unpacked into the real stash pf_hosp_supply_pillbox (quantity x case size), the purchase row
--      in pf_gov_dept_procurements (20E's v7) is delivered, the department books get one keyed
--      society_spend line, and pf-ambulancejob logs the delivery in pf_hosp_supply_usage (20A's v8);
--   2. an unfunded department: insufficient_funds, the row failed, no money moved;
--   3. keys on the UNIQUE idem_key; the open-charge block (COUNT payment_pending) on real rows;
--   4. the reconcile on real rows: an unclear charge (pf_transactions pending) is held, a completed
--      one becomes charge_held, a crash-left 'created' row is linked to its order (NOT EXISTS
--      lookup), a paid row whose order was cancelled or unpacked follows it;
--   5. the usage log: rig restock rows and the once-only delivery key (INSERT IGNORE).
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
vec3 = vec3 or vector3
vec4 = vec4 or vector4
GlobalState = {}
STATES = { ['pfm-banking'] = 'started', ['pfm-inventory'] = 'started', ['pf-stores'] = 'started', ['pf-government'] = 'started' }
function GetResourceState(name) return STATES[name] or 'missing' end
function GetCurrentResourceName() return 'pfm-banking' end
function FreezeEntityPosition() end
function GetEntityHeading() return 0.0 end
function LoadResourceFile() return nil end
function RegisterCommand() end
function SaveResourceFile() return true end
function AddEventHandler(name, fn)
    local prev = Mock.eventHandlers[name]
    if prev then Mock.eventHandlers[name] = function(...) prev(...) fn(...) end else Mock.eventHandlers[name] = fn end
end
QBCoreMock.Commands.Add = function() end
Mock.clock = 1800000000

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
RealDB.exec('pfm-inventory/qb-inventory.sql')
RealDB.exec('[pfscripts]/pf-stores/install.sql')
RealDB.exec('[pfscripts]/pf-government/sql/install.sql')
load_resource('pfm-core/server/migrations.lua')
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end
for name, def in pairs({ bandage = 100, ifaks = 400, supply_crate = 5000 }) do
    QBCoreMock.Shared.Items[name] = { name = name, label = name, weight = def, type = 'item', unique = name == 'supply_crate', image = name .. '.png' }
end
QBCoreMock.Shared.Jobs = { ambulance = { label = 'EMS' }, corrections = { label = 'Corrections' }, police = { label = 'Police' } }

-- ── pf-ambulancejob: its medical schema (v8 has pf_hosp_supply_usage) and the supplies module ──
Config = nil
local AJ = '[pfscripts]/pf-ambulancejob/'
for _, f in ipairs({ 'config.lua', 'config_ems.lua', 'config_hospital.lua', 'shared/framework.lua', 'server/medical/schema.lua' }) do
    load_resource(AJ .. f)
end
assert(RunMigrations('pf-ambulancejob', PFMed.Schema.Migrations), 'AJ medical schema')
load_resource(AJ .. 'server/hospital/facility.lua')
load_resource(AJ .. 'server/hospital/supplies.lua')
AJCFG = Config
local S = PFHospital.Supplies

-- ── the bank, the inventory, the order service and pf-government ──
local merged = {}
local function loadConfig(path)
    Config = nil
    load_resource(path)
    for k, v in pairs(Config or {}) do if merged[k] == nil then merged[k] = v end end
end
loadConfig('pfm-banking/config.lua')
loadConfig('pfm-inventory/config/config.lua')
loadConfig('pfm-inventory/config/freshness.lua')
loadConfig('[pfscripts]/pf-government/config.lua')
Config = merged
Config.SupplyChain = { PlayerSuppliers = false, AIMarkup = 0.15, DriverPrioritySeconds = 60, DriverMaxSeconds = 1800,
    AIDeliverySeconds = 300, PalletModel = 'prop_boxpile_06b', DuplicateWindowSeconds = 10 }
if Config.Logging then Config.Logging.Enabled = false end
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')
load_resource('pfm-inventory/server/freshness.lua')
load_resource('pfm-inventory/server/main.lua')
load_resource('pfm-inventory/server/functions.lua')
load_resource('pfm-inventory/server/hooks.lua')
load_resource('[pfscripts]/pf-stores/server_orders.lua')
for _, f in ipairs({ 'server/core.lua', 'server/schema.lua', 'server/budgets.lua', 'server/departments/core.lua', 'server/departments/procurement.lua' }) do
    load_resource('[pfscripts]/pf-government/' .. f)
end
GOVCFG = Config
for _, res in ipairs({ 'pfm-banking', 'pfm-inventory', 'pf-stores', 'pf-government' }) do
    Mock.exportsByResource[res] = Mock.exportsByResource['__self']
end

assert(PFLedger.Start(), 'ledger start')
assert(PFOrders.Start(), 'order service start')
assert(GovSchema.Ensure(), 'pf-government schema')
local P, D = GovDept.Procurement, GovDept

local MGR, MEDIC, COMGR = 1, 2, 3
local function employ(src, cid, job, grade)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.job = { name = job, grade = { level = grade }, onduty = true }
    MySQL.query.await("INSERT IGNORE INTO players (citizenid, cid, license, name, money, charinfo, job, gang, position, metadata, inventory) VALUES (?, 1, ?, ?, '{\"cash\":0,\"bank\":0}', '{}', '{}', '{}', '{}', '{}', '[]')",
        { cid, 'license:' .. cid, cid })
end
employ(MGR, 'EMSMGR1', 'ambulance', 3)
employ(MEDIC, 'EMSMED1', 'ambulance', 1)
employ(COMGR, 'COMGR1', 'corrections', 4)

local function balance(name) return tonumber(MySQL.scalar.await('SELECT account_balance FROM bank_accounts WHERE account_name = ?', { name })) or 0 end
local function fund(name, amount)
    assert(PFLedger.EnsureSociety(name, 'job'))
    assert(PFLedger.Transfer({ from = 'system:test', to = 'society:' .. name, amount = amount, key = PFLedger.AutoKey('fund'), kind = 'test' }).ok)
end
local function stashCount(id, item)
    local inv = exports['pfm-inventory']:GetInventory(id)
    local n = 0
    for _, it in pairs(inv and inv.items or {}) do if it.name == item then n = n + (tonumber(it.amount) or 0) end end
    return n
end
local function proc(id) return MySQL.single.await('SELECT * FROM pf_gov_dept_procurements WHERE id = ?', { id }) end
local function useAj() Config = AJCFG end
local function useGov() Config = GOVCFG end

describe('20C procurement on the real ledger and order service', function()
    it('registers the facility buyer kind with pf-stores across the boundary', function()
        useGov()
        assert_true(P.Register())
        assert_true(PFOrders.kinds.facility ~= nil)
        assert_true(Mock.callable(PFOrders.kinds.facility.price), 'adapter functions are funcrefs on the pf-stores side')
    end)

    local procId, orderId
    it('a manager orders hospital supplies: society:ambulance is charged once', function()
        useGov()
        fund('ambulance', 5000)
        local before = balance('ambulance')
        local res = P.Create(MGR, 'ems:pillbox', { { name = 'bandage', quantity = 5 }, { name = 'ifaks', quantity = 2 } })
        assert_true(res.ok, tostring(res.error) .. ' ' .. tostring(res.message))
        procId, orderId = res.procurement.id, res.procurement.orderId
        local order = PFOrders.Get(orderId)
        assert_eq(order.buyer_kind, 'facility')
        assert_eq(order.buyer_ref, 'society:ambulance')
        -- goods 620 (5 x 60 + 2 x 160), markup 15 %, freight 10 % with a 200 minimum
        assert_near(tonumber(order.total), 620 + 93 + 200, 0.01)
        assert_near(before - balance('ambulance'), 913, 0.01)
        local tx = PFLedger.GetTransaction(('supply:%d:charge'):format(orderId))
        assert_eq(tx.state, 'completed')
        assert_eq(tx.from_account, 'society:ambulance')
        local row = proc(procId)
        assert_eq(row.state, 'paid')
        assert_eq(tonumber(row.store_order_id), orderId)
        assert_eq(tonumber(row.total), 913)
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_transactions WHERE from_account = 'society:ambulance'")), 1)
    end)

    it('the AI driver delivers; the goods land in the supply room stash, booked once, logged by the hospital', function()
        useGov()
        Mock.clock = Mock.clock + 120
        PFOrders.Tick()                                -- no player driver in time: the AI takes it
        assert_eq(PFOrders.Get(orderId).status, 'in_transit')
        Mock.clock = Mock.clock + 400
        -- pf-government raises the delivery event; the hospital logs it under its own config
        local handler = Mock.eventHandlers['pf-government:server:facilityStockDelivered']
        Mock.eventHandlers['pf-government:server:facilityStockDelivered'] = function(data) useAj() handler(data) useGov() end
        PFOrders.Tick()
        Mock.eventHandlers['pf-government:server:facilityStockDelivered'] = handler
        assert_eq(PFOrders.Get(orderId).status, 'unpacked')
        assert_eq(stashCount('pf_hosp_supply_pillbox', 'bandage'), 50)
        assert_eq(stashCount('pf_hosp_supply_pillbox', 'ifaks'), 8)
        assert_eq(proc(procId).state, 'delivered')
        local books = MySQL.query.await('SELECT amount, transaction_type, idem_key FROM pf_gov_budget_transactions WHERE department = ? AND idem_key = ?',
            { 'ems', ('pf-government:dept:ems:procurement:%d'):format(procId) })
        assert_eq(#books, 1)
        assert_eq(books[1].transaction_type, 'society_spend')
        assert_near(tonumber(books[1].amount), 913, 0.01)
        assert_false(P.Book(proc(procId)), 'booked once')
        local usage = MySQL.query.await("SELECT facility, item, qty, reason, ref_id FROM pf_hosp_supply_usage WHERE reason = 'delivery' ORDER BY item")
        assert_eq(#usage, 2)
        assert_eq(usage[1].facility, 'pillbox')
        assert_eq(usage[1].item, 'bandage')
        assert_eq(tonumber(usage[1].qty), 50)
        assert_eq(tonumber(usage[1].ref_id), orderId)
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_transactions WHERE from_account = 'society:ambulance'")), 1, 'charged once in all')
    end)

    it('an unfunded department: insufficient_funds, the row failed, nothing moved', function()
        useGov()
        PFLedger.EnsureSociety('corrections', 'job')
        local before = balance('corrections')
        local res = P.Create(COMGR, 'corrections:bolingbroke_infirmary', { { name = 'bandage', quantity = 4 } })
        assert_eq(res.error, 'insufficient_funds')
        local row = MySQL.single.await("SELECT state FROM pf_gov_dept_procurements WHERE buyer_id = 'corrections:bolingbroke_infirmary' ORDER BY id DESC LIMIT 1")
        assert_eq(row.state, 'failed')
        assert_eq(balance('corrections'), before)
    end)

    it('keys: the same key returns the first purchase (UNIQUE idem_key)', function()
        useGov()
        local a = P.Create(MGR, 'ems:paleto', { { name = 'bandage', quantity = 4 } }, { key = 'rdb:proc:1' })
        assert_true(a.ok, tostring(a.error))
        local b = P.Create(MGR, 'ems:paleto', { { name = 'bandage', quantity = 4 } }, { key = 'rdb:proc:1' })
        assert_true(b.duplicate)
        assert_eq(b.procurement.id, a.procurement.id)
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_gov_dept_procurements WHERE idem_key = 'rdb:proc:1'")), 1)
    end)

    it('a cancelled purchase is refunded by pf-stores and follows in the row', function()
        useGov()
        local before = balance('ambulance')
        local res = P.Create(MGR, 'ems:paleto', { { name = 'ifaks', quantity = 3 } })
        assert_true(res.ok, tostring(res.error))
        local c = P.Cancel(MGR, res.procurement.id)
        assert_true(c.ok, tostring(c.error))
        assert_eq(proc(res.procurement.id).state, 'cancelled')
        assert_near(balance('ambulance'), before, 0.01)
    end)
end)

describe('20C held charges and the reconcile on real rows', function()
    local function fakeOrder(status, createdMs)
        return MySQL.insert.await([[INSERT INTO pf_store_supply_orders (store_id, buyer_kind, buyer_ref, owner_citizenid, method, status, total, items_json, created_at)
            VALUES ('ems:pillbox', 'facility', 'society:ambulance', 'EMSMGR1', 'trucking', ?, 500.5, '[]', ?)]], { status, createdMs })
    end
    local function ledgerRow(key, state)
        MySQL.insert.await([[INSERT INTO pf_transactions (tx_id, idempotency_key, kind, from_account, to_account, amount, state, created_at)
            VALUES (?, ?, 'supplies', 'society:ambulance', 'society:freight_escrow', 500.5, ?, NOW())]], { 'rdbtx' .. key:gsub('[^%w]', ''), key, state })
    end

    it('an unclear charge blocks new orders for the facility until the ledger answers', function()
        useGov()
        local oid = fakeOrder('failed', (os.time() - 5) * 1000)
        ledgerRow(('supply:%d:charge'):format(oid), 'pending')
        local id = MySQL.insert.await([[INSERT INTO pf_gov_dept_procurements (dept, buyer_id, store_order_id, method, items, total, state, by_cid, at, updated_at)
            VALUES ('ems', 'ems:pillbox', ?, 'trucking', '{}', 501, 'payment_pending', 'EMSMGR1', ?, ?)]], { oid, os.time(), os.time() })
        assert_eq(P.Create(MGR, 'ems:pillbox', { { name = 'bandage', quantity = 5 } }).error, 'payment_pending')
        assert_eq(P.ChargeState(oid), 'unclear')
        P.ReconcileTick()
        assert_eq(proc(id).state, 'payment_pending', 'still unclear: held')
        MySQL.update.await("UPDATE pf_transactions SET state = 'completed' WHERE idempotency_key = ?", { ('supply:%d:charge'):format(oid) })
        P.ReconcileTick()
        assert_eq(proc(id).state, 'charge_held')
        assert_true(P.Create(MGR, 'ems:pillbox', { { name = 'bandage', quantity = 5 } }).ok, 'orders open again')
    end)

    it('a crash-left created row is linked to the order it placed (only an unclaimed one)', function()
        useGov()
        local t = os.time()
        local oid = fakeOrder('awaiting_delivery', t * 1000)
        local id = MySQL.insert.await([[INSERT INTO pf_gov_dept_procurements (dept, buyer_id, method, items, total, state, by_cid, at, updated_at)
            VALUES ('ems', 'ems:pillbox', 'trucking', '{}', 0, 'created', 'EMSMGR1', ?, ?)]], { t, t })
        local found = P.FindStoreOrder('ems:pillbox', 'EMSMGR1', t * 1000)
        assert_eq(tonumber(found.id), tonumber(oid))
        Mock.clock = Mock.clock + 300
        P.ReconcileTick()
        local row = proc(id)
        assert_eq(row.state, 'paid')
        assert_eq(tonumber(row.store_order_id), tonumber(oid))
        assert_eq(P.FindStoreOrder('ems:pillbox', 'EMSMGR1', t * 1000), nil, 'a claimed order is not found again')
    end)

    it('a paid row follows its order when it ended elsewhere', function()
        useGov()
        local oid = fakeOrder('unpacked', os.time() * 1000)
        local id = MySQL.insert.await([[INSERT INTO pf_gov_dept_procurements (dept, buyer_id, store_order_id, method, items, total, state, by_cid, at, updated_at)
            VALUES ('ems', 'ems:pillbox', ?, 'trucking', '{}', 501, 'paid', 'EMSMGR1', ?, ?)]], { oid, os.time(), os.time() })
        local oid2 = fakeOrder('cancelled', os.time() * 1000)
        local id2 = MySQL.insert.await([[INSERT INTO pf_gov_dept_procurements (dept, buyer_id, store_order_id, method, items, total, state, by_cid, at, updated_at)
            VALUES ('ems', 'ems:pillbox', ?, 'trucking', '{}', 501, 'paid', 'EMSMGR1', ?, ?)]], { oid2, os.time(), os.time() })
        P.ReconcileTick()
        assert_eq(proc(id).state, 'delivered')
        assert_eq(proc(id2).state, 'cancelled')
        assert_eq(tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM pf_gov_budget_transactions WHERE idem_key = ?', { ('pf-government:dept:ems:procurement:%d'):format(id) })), 1)
    end)

    it('lists the department purchases newest first', function()
        useGov()
        local res = P.List(MEDIC, 5)
        assert_true(res.ok)
        assert_true(#res.list >= 1)
        for _, r in ipairs(res.list) do assert_eq(r.dept, 'ems') end
    end)
end)

describe('20C the hospital supply usage log', function()
    it('rig restock rows and the once-only delivery key', function()
        useAj()
        assert_true(S.Log('pillbox', 'bandage', 6, 'rig_restock', nil))
        assert_true(S.Log('pillbox', 'bandage', 6, 'rig_restock', nil))
        assert_eq(S.OnDelivered({ stash = 'pf_hosp_supply_paleto', orderId = 9001, items = { { item = 'ifaks', qty = 4 } } }), 1)
        S.OnDelivered({ stash = 'pf_hosp_supply_paleto', orderId = 9001, items = { { item = 'ifaks', qty = 4 } } })
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_hosp_supply_usage WHERE reason = 'rig_restock'")), 2)
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_hosp_supply_usage WHERE ref_id = 9001")), 1)
        useGov()
    end)
end)
