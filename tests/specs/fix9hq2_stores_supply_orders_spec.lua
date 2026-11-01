-- pf-stores supply orders (server_orders.lua): money and stock between buyer, escrow and a player
-- supplier.
--   (a) the player supplier's markup bonus is paid at delivery, not at accept: accept-then-cancel
--       pays the supplier nothing and refunds the buyer the escrowed total; an order accepted before
--       the change (markup split already paid) refunds the total less what left escrow.
--   (b) supplier stock units follow Config.SupplyChain.CaseSize for every line (restaurants and
--       stores order single items): 12 bottles of wine in cases of 6 take 2 cases from the supplier.
--   (c) a failed cancellation refund stays owed and is retried at start and by the order timer,
--       under a fresh key only after the ledger stored the failure.
-- The database and the ledger are small in-memory stand-ins defined here.
load_resource('tests/lua/fivem_mocks.lua')

function GetResourceState(name) return name == 'pfm-banking' and 'started' or 'missing' end

local ESCROW = 'society:freight_escrow'
local BUYER = 'society:store_corner'
local OWNER, SUPP = 1, 2

-- ── database ────────────────────────────────────────────────────────────────
local db
local function resetDb()
    db = { orders = {}, suppliers = {}, offers = {}, events = 0 }
end
local function copy(t)
    if type(t) ~= 'table' then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = v end
    return o
end
local function orderRow(id) return db.orders[tonumber(id)] end
local function offerRow(supplierId, item)
    for _, o in ipairs(db.offers) do
        if o.supplier_id == tonumber(supplierId) and o.item == item then return o end
    end
end
local function supplierBy(field, value)
    for _, s in ipairs(db.suppliers) do if s[field] == value then return s end end
end
local function ordersWhere(pred)
    local ids, out = {}, {}
    for id in pairs(db.orders) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do if pred(db.orders[id]) then out[#out + 1] = copy(db.orders[id]) end end
    return out
end

-- O.Transition: UPDATE pf_store_supply_orders SET status = ?, `col` = ? | NULL ... WHERE id = ? AND status = ?
local function transition(sql, p)
    local sets = sql:match('SET (.-) WHERE id = %? AND status = %?$')
    local cols, i = {}, 1
    for piece in (sets .. ','):gmatch('%s*(.-),') do
        local col, val = piece:match('^`?([%w_]+)`? = (.+)$')
        if val == '?' then cols[col] = { p[i] }; i = i + 1 else cols[col] = { nil } end
    end
    local id, from = p[i], p[i + 1]
    local row = orderRow(id)
    if not row or row.status ~= from then return 0 end
    for col, v in pairs(cols) do row[col] = v[1] end
    return 1
end

local unknown = {}
local function run(kind, sql, p)
    p = p or {}
    if sql:find('^UPDATE pf_store_supply_orders SET status = %?') then return transition(sql, p) end
    if sql:find('FROM pf_store_supply_orders WHERE id = %? LIMIT 1') then return { copy(orderRow(p[1])) } end
    if sql:find('INSERT INTO pf_supply_order_events') then db.events = db.events + 1 return db.events end
    if sql:find('UPDATE pf_store_supply_orders SET settled = 1 WHERE id = %?') then
        local r = orderRow(p[1]); if r then r.settled = 1 return 1 end return 0
    end
    if sql:find("SET refund_state = 'done' WHERE id = %? AND refund_state = 'pending'") then
        local r = orderRow(p[1]); if r and r.refund_state == 'pending' then r.refund_state = 'done' return 1 end return 0
    end
    if sql:find('SET refund_attempt = %? WHERE id = %? AND refund_attempt = %?') then
        local r = orderRow(p[2]); if r and (r.refund_attempt or 0) == p[3] then r.refund_attempt = p[1] return 1 end return 0
    end
    if sql:find("WHERE status = 'cancelled' AND refund_state = 'pending'") then
        return ordersWhere(function(o) return o.status == 'cancelled' and o.refund_state == 'pending' end)
    end
    if sql:find("WHERE status = 'awaiting_supplier' AND supplier_deadline <= %?") then
        return ordersWhere(function(o) return o.status == 'awaiting_supplier' and (o.supplier_deadline or 0) <= p[1] end)
    end
    if sql:find("WHERE status = 'awaiting_delivery' AND driver_deadline <= %?") then
        return ordersWhere(function(o) return o.status == 'awaiting_delivery' and (o.driver_deadline or 0) <= p[1] end)
    end
    if sql:find("WHERE status = 'in_transit' AND driver_kind = 'ai'") then
        return ordersWhere(function(o) return o.status == 'in_transit' and o.driver_kind == 'ai' and (o.ai_eta or 0) <= p[1] end)
    end
    if sql:find("WHERE status IN %('assigned', 'in_transit'%) AND driver_kind = 'player'") then
        return ordersWhere(function(o) return (o.status == 'assigned' or o.status == 'in_transit') and o.driver_kind == 'player' and (o.assigned_at or 0) <= p[1] end)
    end
    if sql:find("WHERE status IN %('delivered', 'unpacked'%) AND settled = 0") then
        return ordersWhere(function(o) return (o.status == 'delivered' or o.status == 'unpacked') and (o.settled or 0) == 0 end)
    end
    if sql:find("WHERE status = 'created' AND created_at <= %?") then
        return ordersWhere(function(o) return o.status == 'created' and o.created_at <= p[1] end)
    end
    if sql:find("WHERE status = 'paid'") then return ordersWhere(function(o) return o.status == 'paid' end) end
    if sql:find('FROM pf_suppliers WHERE citizenid = %?') then return { copy(supplierBy('citizenid', p[1])) } end
    if sql:find('SET stock_qty = stock_qty %- %?') then
        local units, supId, item, need, maxPrice = p[1], p[2], p[3], p[4], p[5]
        local o = offerRow(supId, item)
        if not o or o.stock_qty < need or o.unit_price > maxPrice then return 0 end
        o.stock_qty = o.stock_qty - units
        return 1
    end
    if sql:find('SET stock_qty = stock_qty %+ %? WHERE supplier_id = %? AND item = %?') then
        local o = offerRow(p[2], p[3]); if not o then return 0 end
        o.stock_qty = o.stock_qty + p[1]
        return 1
    end
    unknown[#unknown + 1] = kind .. ': ' .. sql:sub(1, 120)
    return kind == 'query' and {} or nil
end
local function api(kind, shape)
    local fn = function(sql, p)
        local res = run(kind, sql, p)
        if shape == 'single' then return type(res) == 'table' and res[1] or nil end
        return res
    end
    return setmetatable({ await = fn }, { __call = function(_, sql, p, cb) local r = fn(sql, p) if cb then cb(r) end return r end })
end
MySQL = { query = api('query'), single = api('query', 'single'), update = api('update'), insert = api('insert'), scalar = api('query', 'single') }

-- ── ledger ──────────────────────────────────────────────────────────────────
local bank
local function resetBank()
    bank = { balances = {}, byKey = {}, failKeys = {}, throwKeys = {}, n = 0 }
end
local function bal(ref) return bank.balances[ref] or 0 end
local function r2(n) return math.floor(n * 100 + 0.5) / 100 end
Mock.exportsByResource['pfm-banking'] = {
    IsLedgerReady = function() return true end,
    EnsureSocietyAccount = function() return true end,
    GetTransaction = function(_, k) return bank.byKey[k] and copy(bank.byKey[k]) or nil end,
    Transfer = function(_, o)
        if bank.throwKeys[o.key] then bank.throwKeys[o.key] = nil error('bank went away') end
        local existing = bank.byKey[o.key]
        if existing then
            return { ok = existing.state == 'completed', duplicate = true, state = existing.state, txId = existing.tx_id,
                error = existing.state ~= 'completed' and (existing.error or existing.state) or nil }
        end
        bank.n = bank.n + 1
        local tx = { tx_id = 'TX' .. bank.n, idempotency_key = o.key, from_account = o.from, to_account = o.to, amount = o.amount, kind = o.kind }
        bank.byKey[o.key] = tx
        local system = o.from:sub(1, 7) == 'system:'
        if bank.failKeys[o.key] or (not system and bal(o.from) < o.amount) then
            bank.failKeys[o.key] = nil
            tx.state, tx.error = 'failed', 'insufficient_funds'
            return { ok = false, error = 'insufficient_funds', txId = tx.tx_id, state = 'failed' }
        end
        bank.balances[o.from] = r2(bal(o.from) - o.amount)
        bank.balances[o.to] = r2(bal(o.to) + o.amount)
        tx.state = 'completed'
        return { ok = true, txId = tx.tx_id, state = 'completed' }
    end,
}
local function seedTx(k, from, to, amount, state)
    bank.n = bank.n + 1
    bank.byKey[k] = { tx_id = 'TX' .. bank.n, idempotency_key = k, from_account = from, to_account = to, amount = amount, state = state }
    if state == 'completed' or state == 'debited' then bank.balances[from] = r2(bal(from) - amount) end
    if state == 'completed' then bank.balances[to] = r2(bal(to) + amount) end
end

-- ── the resource ────────────────────────────────────────────────────────────
Config = { SupplyChain = { AIMarkup = 0.15, PlayerSupplierShareOfMarkup = 0.5, SupplierOfferSeconds = 120, DriverPrioritySeconds = 300 } }
load_resource('[pfscripts]/pf-stores/server_orders.lua')
local O = PFOrders
O.RegisterBuyerKind('store', {
    canManage = function(src, id) return src == OWNER and id == 'corner' end,
    account = function() return BUYER end,
    ensureAccount = function() return true end,
    price = function() return {}, 0 end,
    route = function() return nil end,
    unpack = function() return true end,
})

local POOL = 1000          -- other orders' money in the shared escrow account
local nextId = 0
-- an order paid into escrow: subtotal 100 + AI markup 15 = 115, freight 20
local function placeOrder(lines, status, extra)
    nextId = nextId + 1
    local row = {
        id = nextId, store_id = 'corner', buyer_kind = 'store', buyer_ref = BUYER, owner_citizenid = 'OWN1', method = 'trucking',
        status = status or 'awaiting_supplier', total = 115, subtotal = 100, ai_markup = 15, freight_payout = 20,
        items_json = json.encode(lines or { { name = 'lockpick', quantity = 5, cost = 20 } }), created_at = os.time() * 1000.0,
        supplier_deadline = os.time() * 1000.0 + 600000, driver_deadline = os.time() * 1000.0 + 600000, settled = 0, refund_attempt = 0,
    }
    for k, v in pairs(extra or {}) do row[k] = v end
    db.orders[row.id] = row
    bank.balances[ESCROW] = r2(bal(ESCROW) + row.total)
    return row.id
end
local function supplier(item, price, stock)
    db.suppliers[1] = db.suppliers[1] or { id = 7, citizenid = 'SUP1', name = 'Farm', active = 1 }
    db.offers[#db.offers + 1] = { supplier_id = 7, item = item, unit_price = price, stock_qty = stock }
end
local function stockOf(item) local o = offerRow(7, item) return o and o.stock_qty end
local function supplierBank() return bal('player:SUP1:bank') end

BeforeEach = function()
    Mock.reset()
    resetDb()
    resetBank()
    unknown = {}
    Config.SupplyChain.CaseSize = {}
    Mock.players = {}
    Mock.newPlayer(OWNER, 'OWN1')
    Mock.newPlayer(SUPP, 'SUP1')
    bank.balances[ESCROW] = POOL
end

local function noUnknownQueries() assert_eq(#unknown, 0, 'unhandled SQL: ' .. tostring(unknown[1])) end

describe('(a) the supplier markup bonus is paid at delivery', function()
    it('accept then cancel: the supplier earns nothing, the buyer gets the whole escrowed total back', function()
        supplier('lockpick', 20, 10)
        local id = placeOrder()
        assert_true(O.AcceptSupply(SUPP, id).ok)
        assert_eq(supplierBank(), 0, 'no bonus at accept')
        assert_eq(bal(BUYER), 0, 'no markup refund at accept either: the markup stays in escrow')
        assert_eq(bal(ESCROW), POOL + 115)
        local res = O.Cancel(OWNER, 'store', 'corner', id)
        assert_true(res.ok, tostring(res.error))
        assert_eq(res.data.refunded, 115)
        assert_eq(bal(BUYER), 115, 'refunded in full')
        assert_eq(supplierBank(), 0, 'the supplier keeps nothing from a cancelled order')
        assert_eq(bal(ESCROW), POOL, 'the other orders\' escrow is untouched')
        assert_eq(stockOf('lockpick'), 10, 'reserved stock returned')
        assert_eq(bank.byKey['supply:' .. id .. ':markup-supplier'], nil)
        noUnknownQueries()
    end)
    it('delivered: the supplier gets the goods share and the bonus, the buyer the rest of the markup, once', function()
        supplier('lockpick', 20, 10)
        local id = placeOrder()
        assert_true(O.AcceptSupply(SUPP, id).ok)
        db.orders[id].status = 'delivered'
        assert_true(O.Settle(O.Get(id)))
        assert_eq(supplierBank(), 80 + 7.5, 'goods (100 - 20 freight) + half the markup')
        assert_eq(bal(BUYER), 7.5, 'the other half of the markup back to the buyer')
        assert_eq(bal(ESCROW), POOL + 20, 'only the freight left (paid to the driver by pf-trucking)')
        assert_eq(db.orders[id].settled, 1)
        O.Tick()
        assert_eq(supplierBank(), 87.5, 'paid once')
        noUnknownQueries()
    end)
    it('an order accepted before the change (split already paid) refunds the total less what left escrow', function()
        local id = placeOrder(nil, 'awaiting_delivery', { supplier_kind = 'player', supplier_ref = 'SUP1' })
        seedTx('supply:' .. id .. ':markup-supplier', ESCROW, 'player:SUP1:bank', 7.5, 'completed')
        seedTx('supply:' .. id .. ':markup-refund', ESCROW, BUYER, 7.5, 'completed')
        local res = O.Cancel(OWNER, 'store', 'corner', id)
        assert_true(res.ok)
        assert_eq(res.data.refunded, 100)
        assert_eq(bal(BUYER), 107.5, 'the buyer has 115 - 7.5 (the bonus already paid)')
        assert_eq(bal(ESCROW), POOL, 'escrow pays out exactly what this order put in')
    end)
    it('while an older split is still being settled by the ledger, the refund waits and is retried', function()
        local id = placeOrder(nil, 'awaiting_delivery', { supplier_kind = 'player', supplier_ref = 'SUP1' })
        seedTx('supply:' .. id .. ':markup-supplier', ESCROW, 'player:SUP1:bank', 7.5, 'debited')
        local res = O.Cancel(OWNER, 'store', 'corner', id)
        assert_true(res.ok)
        assert_true(res.data.refundPending)
        assert_eq(bal(BUYER), 0)
        assert_eq(db.orders[id].refund_state, 'pending')
        -- the ledger's recovery finishes the old transfer
        bank.byKey['supply:' .. id .. ':markup-supplier'].state = 'completed'
        bank.balances['player:SUP1:bank'] = 7.5
        O.Tick()
        assert_eq(bal(BUYER), 107.5)
        assert_eq(bal(ESCROW), POOL)
        assert_eq(db.orders[id].refund_state, 'done')
    end)
end)

describe('(b) supplier stock units follow CaseSize for every line', function()
    it('a restaurant line of single bottles is converted to the supplier\'s cases', function()
        Config.SupplyChain.CaseSize = { wine = 6 }
        local units, maxPrice = O.SupplierUnits({ name = 'wine', quantity = 12, cost = 18 })
        assert_eq(units, 2, '12 bottles = 2 cases of 6')
        assert_true(math.abs(maxPrice - 108) < 0.01, 'price per case = 6 x 18 (got ' .. tostring(maxPrice) .. ')')
        assert_eq(O.SupplierUnits({ name = 'wine', quantity = 4, cost = 18 }), nil, '4 bottles are not whole cases: AI supplier')
        assert_eq(O.SupplierUnits({ name = 'bread', quantity = 3, cost = 5 }), 3, 'no CaseSize: one unit per item')
        assert_eq(O.SupplierUnits({ name = 'part', quantity = 2, caseSize = 10, cost = 100 }), 20, 'buyer cases of 10')
        Config.SupplyChain.CaseSize = { part = 5 }
        assert_eq(O.SupplierUnits({ name = 'part', quantity = 2, caseSize = 10, cost = 100 }), 4, '20 items = 4 supplier cases of 5')
    end)
    it('accepting 12 bottles takes 2 cases (12 bottles) from the supplier, and a cancel gives back the same', function()
        Config.SupplyChain.CaseSize = { wine = 6 }
        supplier('wine', 100, 5)                       -- 100 per case of 6 is under the buyer's 108
        local id = placeOrder({ { name = 'wine', label = 'Wine', quantity = 12, cost = 18 } })
        assert_true(O.AcceptSupply(SUPP, id).ok)
        assert_eq(stockOf('wine'), 3, '2 cases reserved, not 12')
        assert_eq(json.decode(db.orders[id].items_json)[1].reservedUnits, 2)
        assert_eq(json.decode(db.orders[id].items_json)[1].quantity, 12, 'the restaurant still receives 12 bottles')
        assert_true(O.Cancel(OWNER, 'store', 'corner', id).ok)
        assert_eq(stockOf('wine'), 5)
    end)
    it('a supplier asking more per case than the buyer pays for those bottles is not used', function()
        Config.SupplyChain.CaseSize = { wine = 6 }
        supplier('wine', 109, 5)
        local id = placeOrder({ { name = 'wine', quantity = 12, cost = 18 } })
        assert_eq(O.AcceptSupply(SUPP, id).error, 'not_enough_stock')
        assert_eq(stockOf('wine'), 5)
    end)
end)

describe('(c) a failed cancellation refund is retried', function()
    it('stays owed, is retried by the timer under a fresh key after the stored failure, and is paid once', function()
        local id = placeOrder()
        bank.failKeys['supply:' .. id .. ':cancel'] = true
        local res = O.Cancel(OWNER, 'store', 'corner', id)
        assert_true(res.ok, 'the order is cancelled')
        assert_true(res.data.refundPending)
        assert_eq(bal(BUYER), 0)
        assert_eq(db.orders[id].refund_state, 'pending')
        assert_eq(bank.byKey['supply:' .. id .. ':cancel'].state, 'failed')
        O.Tick()
        assert_eq(bal(BUYER), 115, 'refunded by the timer')
        assert_eq(bank.byKey['supply:' .. id .. ':cancel:1'].state, 'completed')
        assert_eq(db.orders[id].refund_state, 'done')
        assert_eq(db.orders[id].refund_attempt, 1)
        O.Tick()
        O.RecoverPayments()
        assert_eq(bal(BUYER), 115, 'once')
        assert_eq(bank.byKey['supply:' .. id .. ':cancel:2'], nil)
        assert_eq(bal(ESCROW), POOL)
        noUnknownQueries()
    end)
    it('is retried at start; a call that stored nothing is retried under the same key', function()
        local id = placeOrder()
        bank.throwKeys['supply:' .. id .. ':cancel'] = true
        local res = O.Cancel(OWNER, 'store', 'corner', id)
        assert_true(res.ok)
        assert_true(res.data.refundPending)
        assert_eq(bank.byKey['supply:' .. id .. ':cancel'], nil, 'nothing stored by the ledger')
        O.RecoverPayments()
        assert_eq(bal(BUYER), 115, 'refunded at start')
        assert_eq(bank.byKey['supply:' .. id .. ':cancel'].state, 'completed', 'same key: there was no stored failure')
        assert_eq(db.orders[id].refund_attempt, 0)
        assert_eq(db.orders[id].refund_state, 'done')
    end)
    it('a cancelled order with no refund owed is left alone', function()
        local id = placeOrder(nil, 'cancelled')
        O.Tick()
        O.RecoverPayments()
        assert_eq(bal(BUYER), 0)
        assert_false(O.RefundCancelled(id))
        assert_eq(bal(ESCROW), POOL + 115)
    end)
end)
