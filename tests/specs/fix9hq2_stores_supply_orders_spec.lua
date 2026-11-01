-- pf-stores supply orders (server_orders.lua, server_supplier_app.lua): money and stock between the
-- buyer, the escrow, a player supplier and the driver.
--   (a) the player supplier's markup bonus is paid at delivery, not at accept: accept-then-cancel
--       pays the supplier nothing and refunds the buyer the escrowed total; an order accepted before
--       the change (markup split already paid) refunds the total less what left escrow.
--   (b) supplier stock units follow Config.SupplyChain.CaseSize for every line (restaurants and
--       stores order single items) wherever stock is stocked, matched, reserved and given back; a
--       cancel gives back the reservation recorded on the order.
--   (c) a failed cancellation refund stays owed and is retried (at start and by the order timer,
--       with a growing wait), under a fresh key each time the ledger stored a failure.
--   (d) owner decision: the buyer pays the freight on top of the goods. total = goods + markup +
--       freight; the supplier gets the full goods value (+ markup share), the driver the freight,
--       and escrow pays out exactly what the order put in.
-- The database and the ledger are small in-memory stand-ins defined here.
load_resource('tests/lua/fivem_mocks.lua')

function GetResourceState(name) return name == 'pfm-banking' and 'started' or 'missing' end

local ESCROW = 'society:freight_escrow'
local BUYER = 'society:store_corner'
local AI_SUPPLIER, AI_FREIGHT = 'system:pf-stores-supplier', 'system:pf-stores-freight'
local OWNER, SUPP, SUPP2 = 1, 2, 3

-- ── database ────────────────────────────────────────────────────────────────
local db
local function resetDb()
    db = { orders = {}, suppliers = {}, offers = {}, events = 0, nextId = 0 }
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
    if sql:find('INSERT INTO pf_store_supply_orders') then
        db.nextId = db.nextId + 1
        db.orders[db.nextId] = { id = db.nextId, store_id = p[1], buyer_kind = p[2], buyer_ref = p[3], owner_citizenid = p[4], method = p[5],
            status = 'created', total = p[6], subtotal = p[7], ai_markup = p[8], items_json = p[9], created_at = p[10], freight_payout = p[11],
            payment_state = 'pending', settled = 0, refund_attempt = 0 }
        return db.nextId
    end
    if sql:find('^SELECT id, total, subtotal, ai_markup, freight_payout, status, items_json, created_at FROM pf_store_supply_orders') then return {} end
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
    if sql:find("WHERE status = 'awaiting_supplier' ORDER BY id") then
        return ordersWhere(function(o) return o.status == 'awaiting_supplier' end)
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
    if sql:find('SELECT citizenid FROM pf_suppliers WHERE id = %?') then return { copy(supplierBy('id', p[1])) } end
    if sql:find('SELECT o.supplier_id FROM pf_supplier_offers o JOIN pf_suppliers s') then
        local out = {}
        for _, o in ipairs(db.offers) do
            local s = supplierBy('id', o.supplier_id)
            if s and s.active == 1 and o.item == p[1] and o.stock_qty >= p[2] and o.unit_price <= p[3] then out[#out + 1] = { supplier_id = o.supplier_id } end
        end
        return out
    end
    if sql:find('SELECT item, unit_price, stock_qty FROM pf_supplier_offers WHERE supplier_id = %?') then
        local out = {}
        for _, o in ipairs(db.offers) do if o.supplier_id == p[1] then out[#out + 1] = copy(o) end end
        return out
    end
    if sql:find('SELECT stock_qty FROM pf_supplier_offers WHERE supplier_id = %? AND item = %?') then return { copy(offerRow(p[1], p[2])) } end
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
local function transferMock(_, o)
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
end
Mock.exportsByResource['pfm-banking'] = {
    IsLedgerReady = function() return true end,
    EnsureSocietyAccount = function() return true end,
    GetTransaction = function(_, k) return bank.byKey[k] and copy(bank.byKey[k]) or nil end,
    Transfer = transferMock,
}
local function seedTx(k, from, to, amount, state)
    bank.n = bank.n + 1
    bank.byKey[k] = { tx_id = 'TX' .. bank.n, idempotency_key = k, from_account = from, to_account = to, amount = amount, state = state }
    if state == 'completed' or state == 'debited' then bank.balances[from] = r2(bal(from) - amount) end
    if state == 'completed' then bank.balances[to] = r2(bal(to) + amount) end
end
local function txCount() local n = 0 for _ in pairs(bank.byKey) do n = n + 1 end return n end

-- ── inventory (a supplier's goods) ──────────────────────────────────────────
local carriedItems, removed
Mock.exportsByResource['pfm-inventory'] = {
    IsPerishable = function() return false end,
    GetItemsByName = function(_, _, item) return carriedItems[item] and { { name = item, amount = carriedItems[item], slot = 1 } } or {} end,
    RemoveItem = function(_, _, item, n)
        if (carriedItems[item] or 0) < n then return false end
        carriedItems[item] = carriedItems[item] - n
        removed[#removed + 1] = { item = item, amount = n }
        return true
    end,
}

-- ── the resource ────────────────────────────────────────────────────────────
Config = { SupplyChain = { AIMarkup = 0.15, PlayerSupplierShareOfMarkup = 0.5, SupplierOfferSeconds = 120, DriverPrioritySeconds = 300, AIDeliverySeconds = 600 } }
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
-- a buyer that really orders: catalog prices and a delivery route with a $150 freight minimum
local PRICES = { lockpick = 20, sandwich = 4, wine = 18 }
local unpacked
O.RegisterBuyerKind('shop', {
    canManage = function(src, id) return src == OWNER and id == 'deli' end,
    account = function() return BUYER end,
    ensureAccount = function() return true end,
    price = function(_, cart)
        local lines, subtotal = {}, 0
        for _, c in ipairs(cart or {}) do
            local cost = PRICES[c.name]
            if cost then lines[#lines + 1] = { name = c.name, label = c.name, quantity = c.quantity, cost = cost }; subtotal = subtotal + cost * c.quantity end
        end
        return lines, subtotal
    end,
    route = function()
        return { pickup = { label = 'Warehouse', coords = { x = 0, y = 0, z = 0 } }, dropoff = { label = 'Deli', coords = { x = 9, y = 9, z = 0 } },
            trucking = { payoutRate = 0.12, payoutMin = 150 } }
    end,
    unpack = function(_, lines) unpacked[#unpacked + 1] = lines return true end,
})

-- the Supplier app (pf-devices) on the same order service
local app = {}
Mock.exportsByResource['pf-devices'] = {
    RegisterApp = function(_, def) app.def = def return true end,
    RegisterAppHandlers = function(_, id, map) app.id, app.h = id, map return true end,
}
GetResourceState = function(name) return (name == 'pfm-banking' or name == 'pf-devices') and 'started' or 'missing' end
load_resource('[pfscripts]/pf-stores/server_supplier_app.lua')
Mock.eventHandlers['pf-devices:server:ready']()
GetResourceState = function(name) return name == 'pfm-banking' and 'started' or 'missing' end

local POOL = 1000          -- other orders' money in the shared escrow account
-- an order already paid into escrow. Freight on top (the current rule): goods 100 + AI markup 15 +
-- freight 20 = 135. legacy = true: placed before that, total = goods + markup = 115 with the
-- freight taken out of the goods.
local function placeOrder(lines, status, extra, legacy)
    db.nextId = db.nextId + 1
    local row = {
        id = db.nextId, store_id = 'corner', buyer_kind = 'store', buyer_ref = BUYER, owner_citizenid = 'OWN1', method = 'trucking',
        status = status or 'awaiting_supplier', total = legacy and 115 or 135, subtotal = 100, ai_markup = 15, freight_payout = 20,
        items_json = json.encode(lines or { { name = 'lockpick', quantity = 5, cost = 20 } }), created_at = os.time() * 1000.0,
        supplier_deadline = os.time() * 1000.0 + 600000, driver_deadline = os.time() * 1000.0 + 600000, settled = 0, refund_attempt = 0,
        payment_state = 'paid',
    }
    for k, v in pairs(extra or {}) do row[k] = v end
    db.orders[row.id] = row
    bank.balances[ESCROW] = r2(bal(ESCROW) + row.total)
    return row.id
end
local function supplier(item, price, stock, id, cid)
    id, cid = id or 7, cid or 'SUP1'
    if not supplierBy('id', id) then db.suppliers[#db.suppliers + 1] = { id = id, citizenid = cid, name = 'Farm ' .. id, active = 1 } end
    db.offers[#db.offers + 1] = { supplier_id = id, item = item, unit_price = price, stock_qty = stock }
end
local function stockOf(item, id) local o = offerRow(id or 7, item) return o and o.stock_qty end
local function supplierBank() return bal('player:SUP1:bank') end
-- pf-trucking's side of a player delivery: the driver is paid from escrow under the order's freight
-- key, then the job is completed
local function playerDriverDelivers(id, cid)
    local job = { externalType = 'pf-supply:order', externalPayload = { orderId = id } }
    TriggerEvent('pf-trucking:server:externalJobClaimed', job, { citizenid = cid })
    TriggerEvent('pf-trucking:server:externalJobLoaded', job, { citizenid = cid })
    local o = db.orders[id]
    assert_true(transferMock(nil, { from = ESCROW, to = ('player:%s:bank'):format(cid), amount = tonumber(o.freight_payout), key = ('freight:supply:%d'):format(id) }).ok)
    TriggerEvent('pf-trucking:server:externalJobCompleted', job, { citizenid = cid })
end
local function tick(seconds) Mock.clock = Mock.clock + (seconds or 0); O.Tick() end

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 100000
    resetDb()
    resetBank()
    unknown, unpacked, carriedItems, removed = {}, {}, {}, {}
    Config.SupplyChain.CaseSize = {}
    Mock.players = {}
    Mock.newPlayer(OWNER, 'OWN1')
    Mock.newPlayer(SUPP, 'SUP1')
    Mock.newPlayer(SUPP2, 'SUP2')
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
        assert_eq(bal(ESCROW), POOL + 135)
        local res = O.Cancel(OWNER, 'store', 'corner', id)
        assert_true(res.ok, tostring(res.error))
        assert_eq(res.data.refunded, 135, 'goods, markup and freight')
        assert_eq(bal(BUYER), 135, 'refunded in full')
        assert_eq(supplierBank(), 0, 'the supplier keeps nothing from a cancelled order')
        assert_eq(bal(ESCROW), POOL, 'the other orders\' escrow is untouched')
        assert_eq(stockOf('lockpick'), 10, 'reserved stock returned')
        assert_eq(bank.byKey['supply:' .. id .. ':markup-supplier'], nil)
        noUnknownQueries()
    end)
    it('accepting and cancelling over and over (a boss who is also the supplier) cannot take money out of escrow', function()
        supplier('lockpick', 20, 10)
        for _ = 1, 3 do
            local id = placeOrder()
            bank.balances[BUYER] = r2(bal(BUYER) - 135)       -- the buyer paid it
            assert_true(O.AcceptSupply(SUPP, id).ok)
            assert_true(O.Cancel(OWNER, 'store', 'corner', id).ok)
        end
        assert_eq(bal(BUYER), 0, 'every payment came back, nothing more')
        assert_eq(supplierBank(), 0)
        assert_eq(bal(ESCROW), POOL)
    end)
    it('delivered: the supplier gets the full goods value and the bonus, the buyer the rest of the markup, once', function()
        supplier('lockpick', 20, 10)
        local id = placeOrder()
        assert_true(O.AcceptSupply(SUPP, id).ok)
        db.orders[id].status = 'delivered'
        assert_true(O.Settle(O.Get(id)))
        assert_eq(supplierBank(), 100 + 7.5, 'goods (all of them: the freight is on top) + half the markup')
        assert_eq(bal(BUYER), 7.5, 'the other half of the markup back to the buyer')
        assert_eq(bal(ESCROW), POOL + 20, 'only the freight left, for the driver')
        assert_eq(db.orders[id].settled, 1)
        O.Tick()
        assert_eq(supplierBank(), 107.5, 'paid once')
        noUnknownQueries()
    end)
    it('an order accepted before the change (split already paid) refunds the total less what left escrow', function()
        local id = placeOrder(nil, 'awaiting_delivery', { supplier_kind = 'player', supplier_ref = 'SUP1' }, true)
        seedTx('supply:' .. id .. ':markup-supplier', ESCROW, 'player:SUP1:bank', 7.5, 'completed')
        seedTx('supply:' .. id .. ':markup-refund', ESCROW, BUYER, 7.5, 'completed')
        local res = O.Cancel(OWNER, 'store', 'corner', id)
        assert_true(res.ok)
        assert_eq(res.data.refunded, 100)
        assert_eq(bal(BUYER), 107.5, 'the buyer has 115 - 7.5 (the bonus already paid)')
        assert_eq(bal(ESCROW), POOL, 'escrow pays out exactly what this order put in')
    end)
    it('while an older split is still being settled by the ledger, the refund waits and is retried', function()
        local id = placeOrder(nil, 'awaiting_delivery', { supplier_kind = 'player', supplier_ref = 'SUP1' }, true)
        seedTx('supply:' .. id .. ':markup-supplier', ESCROW, 'player:SUP1:bank', 7.5, 'debited')
        local res = O.Cancel(OWNER, 'store', 'corner', id)
        assert_true(res.ok)
        assert_true(res.data.refundPending)
        assert_eq(bal(BUYER), 0)
        assert_eq(db.orders[id].refund_state, 'pending')
        -- the ledger's recovery finishes the old transfer
        bank.byKey['supply:' .. id .. ':markup-supplier'].state = 'completed'
        bank.balances['player:SUP1:bank'] = 7.5
        tick(16)
        assert_eq(bal(BUYER), 107.5)
        assert_eq(bal(ESCROW), POOL)
        assert_eq(db.orders[id].refund_state, 'done')
    end)
    it('a refund never pays back what already left escrow for the order, whoever was paid', function()
        -- e.g. a driver paid by pf-trucking although the order went back to waiting
        local id = placeOrder(nil, 'awaiting_delivery', { supplier_kind = 'ai', supplier_ref = AI_SUPPLIER })
        seedTx('freight:supply:' .. id, ESCROW, 'player:DRV1:bank', 20, 'completed')
        seedTx('freight:supply:' .. id .. ':rental', ESCROW, 'system:pf-trucking-rental', 5, 'completed')
        local res = O.Cancel(OWNER, 'store', 'corner', id)
        assert_true(res.ok)
        assert_eq(res.data.refunded, 110)
        assert_eq(bal(ESCROW), POOL)
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
    it('a broken CaseSize setting counts as 1, the same everywhere', function()
        Config.SupplyChain.CaseSize = { wine = 0, bread = 2.5, salt = -3 }
        assert_eq(O.CaseSizeOf('wine'), 1)
        assert_eq(O.CaseSizeOf('bread'), 2)
        assert_eq(O.CaseSizeOf('salt'), 1)
        assert_eq(O.SupplierUnits({ name = 'wine', quantity = 3, cost = 18 }), 3)
        assert_eq(O.SupplierUnits({ name = 'bread', quantity = 4, cost = 5 }), 2)
    end)
    it('stocking takes the same case size from the inventory (a case of 0 items is not free stock)', function()
        supplier('wine', 100, 0)
        Config.SupplyChain.CaseSize = { wine = 6 }
        carriedItems.wine = 12
        assert_true(O.DepositStock(SUPP, 'wine', 2).ok)
        assert_eq(removed[1].amount, 12, '2 cases of 6')
        assert_eq(stockOf('wine'), 2)
        Config.SupplyChain.CaseSize = { wine = 0 }
        carriedItems.wine = 1
        assert_eq(O.DepositStock(SUPP, 'wine', 2).error, 'missing_items', '2 cases need 2 bottles, not 0')
        assert_eq(stockOf('wine'), 2)
        noUnknownQueries()
    end)
    it('a restaurant order of 12 bottles is offered to the supplier with 2 cases, shown in cases, and reserves 2', function()
        Config.SupplyChain.CaseSize = { wine = 6 }
        supplier('wine', 100, 2)                                  -- 2 cases of 6 at 100 a case (under 6 x 18)
        supplier('wine', 100, 1, 8, 'SUP2')                       -- one case only: cannot fill it
        bank.balances[BUYER] = 1000
        local res = O.Create(OWNER, { kind = 'shop', buyerId = 'deli', method = 'trucking', cart = { { name = 'wine', quantity = 12 } } })
        assert_true(res.ok, tostring(res.error))
        local id = res.data.orderId
        assert_eq(db.orders[id].status, 'awaiting_supplier')
        assert_eq(#O.OpenOffersFor(SUPP).data, 1, 'matched in cases')
        assert_eq(#O.OpenOffersFor(SUPP2).data, 0)
        local st = app.h.status(SUPP, {})
        assert_eq(st.orders[1].lines[1].quantity, 2, 'shown as 2 cases')
        assert_eq(st.orders[1].lines[1].cost, 108, 'at the buyer\'s price per case')
        assert_eq(st.orders[1].pays, 216, 'the supplier is paid the full goods value')
        assert_eq(st.orders[1].bonus, 16.2, 'and half the markup')
        assert_true(app.h.accept(SUPP, { orderId = id }).ok)
        assert_eq(stockOf('wine'), 0, '2 cases reserved, not 12')
        assert_eq(json.decode(db.orders[id].items_json)[1].reservedUnits, 2)
        assert_eq(json.decode(db.orders[id].items_json)[1].quantity, 12, 'the restaurant still receives 12 bottles')
        -- delivered: the buyer unpacks exactly the bottles the supplier stocked (2 cases x 6)
        playerDriverDelivers(id, 'DRV1')
        assert_eq(db.orders[id].status, 'unpacked')
        assert_eq(unpacked[1][1].quantity, 2 * 6)
        assert_eq(supplierBank(), 216 + 16.2)
        assert_eq(bal(ESCROW), POOL)
        noUnknownQueries()
    end)
    it('a cancel gives back the reservation recorded at accept, even if CaseSize changed since', function()
        Config.SupplyChain.CaseSize = { wine = 6 }
        supplier('wine', 100, 5)
        local id = placeOrder({ { name = 'wine', label = 'Wine', quantity = 12, cost = 18 } })
        assert_true(O.AcceptSupply(SUPP, id).ok)
        assert_eq(stockOf('wine'), 3)
        Config.SupplyChain.CaseSize = { wine = 3 }                -- a recount would give back 4 cases
        assert_true(O.Cancel(OWNER, 'store', 'corner', id).ok)
        assert_eq(stockOf('wine'), 5, 'exactly the 2 cases taken')
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
        tick(5)
        assert_eq(bal(BUYER), 0, 'not before its retry wait')
        tick(11)
        assert_eq(bal(BUYER), 135, 'refunded by the timer')
        assert_eq(bank.byKey['supply:' .. id .. ':cancel:1'].state, 'completed')
        assert_eq(db.orders[id].refund_state, 'done')
        assert_eq(db.orders[id].refund_attempt, 1)
        tick(3600)
        O.RecoverPayments()
        assert_eq(bal(BUYER), 135, 'once')
        assert_eq(bank.byKey['supply:' .. id .. ':cancel:2'], nil)
        assert_eq(bal(ESCROW), POOL)
        noUnknownQueries()
    end)
    it('a refund that keeps failing gets a new key for each try, with a growing wait (no ledger spam)', function()
        local id = placeOrder()
        bank.failKeys['supply:' .. id .. ':cancel'] = true
        bank.failKeys['supply:' .. id .. ':cancel:1'] = true
        assert_true(O.Cancel(OWNER, 'store', 'corner', id).data.refundPending)
        tick(16)
        assert_eq(bank.byKey['supply:' .. id .. ':cancel:1'].state, 'failed', 'second try, second key')
        local n = txCount()
        for _ = 1, 5 do tick(5) end
        assert_eq(txCount(), n, 'nothing new while it waits (30 s after the second failure)')
        tick(10)
        assert_eq(bank.byKey['supply:' .. id .. ':cancel:2'].state, 'completed')
        assert_eq(bal(BUYER), 135)
        assert_eq(bal(ESCROW), POOL)
    end)
    it('is retried at start; a call that stored nothing is retried under the same key', function()
        local id = placeOrder()
        bank.throwKeys['supply:' .. id .. ':cancel'] = true
        local res = O.Cancel(OWNER, 'store', 'corner', id)
        assert_true(res.ok)
        assert_true(res.data.refundPending)
        assert_eq(bank.byKey['supply:' .. id .. ':cancel'], nil, 'nothing stored by the ledger')
        O.RecoverPayments()
        assert_eq(bal(BUYER), 135, 'refunded at start, without waiting')
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
        assert_eq(bal(ESCROW), POOL + 135)
    end)
end)

describe('(d) the buyer pays the freight on top of the goods (owner decision)', function()
    it('a small delivery: goods + markup + the $150 freight minimum; nothing comes out of the goods', function()
        bank.balances[BUYER] = 196
        local res = O.Create(OWNER, { kind = 'shop', buyerId = 'deli', method = 'trucking', cart = { { name = 'sandwich', quantity = 10 } } })
        assert_true(res.ok, tostring(res.error))
        assert_eq(res.data.subtotal, 40)
        assert_eq(res.data.markup, 6)
        assert_eq(res.data.freight, 150, 'the trucker\'s minimum, no longer capped at the goods value')
        assert_eq(res.data.total, 196)
        assert_eq(bal(BUYER), 0, 'charged 196')
        assert_eq(bal(ESCROW), POOL + 196)
        local id = res.data.orderId
        assert_eq(db.orders[id].status, 'awaiting_delivery', 'no player supplier: the AI supplier')
        tick(301)
        assert_eq(db.orders[id].status, 'in_transit', 'an AI driver')
        tick(601)
        assert_eq(db.orders[id].status, 'unpacked')
        assert_eq(bal(AI_FREIGHT), 150, 'the driver got the freight')
        assert_eq(bal(AI_SUPPLIER), 46, 'the supplier the full goods value and the markup')
        assert_eq(bal(ESCROW), POOL, 'escrow paid out exactly what the order put in')
        assert_eq(#unpacked, 1)
        noUnknownQueries()
    end)
    it('a player supplier gets the full goods price plus the bonus, the player driver the freight', function()
        supplier('lockpick', 20, 10)
        bank.balances[BUYER] = 300
        local res = O.Create(OWNER, { kind = 'shop', buyerId = 'deli', method = 'trucking', cart = { { name = 'lockpick', quantity = 5 } } })
        assert_true(res.ok, tostring(res.error))
        assert_eq(res.data.total, 100 + 15 + 150)
        local id = res.data.orderId
        assert_true(O.AcceptSupply(SUPP, id).ok)
        playerDriverDelivers(id, 'DRV1')
        assert_eq(db.orders[id].status, 'unpacked')
        assert_eq(bal('player:DRV1:bank'), 150)
        assert_eq(supplierBank(), 100 + 7.5, 'all of the goods: $100, not $100 - $150 freight')
        assert_eq(bal(BUYER), 300 - 265 + 7.5)
        assert_eq(bal(ESCROW), POOL)
        noUnknownQueries()
    end)
    it('an order placed before the change (freight inside the goods) settles as it was charged', function()
        supplier('lockpick', 20, 10)
        local id = placeOrder(nil, nil, nil, true)              -- total 115 = goods 100 + markup 15
        assert_true(O.AcceptSupply(SUPP, id).ok)
        db.orders[id].status = 'awaiting_delivery'
        playerDriverDelivers(id, 'DRV1')
        assert_eq(bal('player:DRV1:bank'), 20)
        assert_eq(supplierBank(), 80 + 7.5, 'the goods less the freight, as the buyer paid it')
        assert_eq(bal(ESCROW), POOL, 'nothing created, nothing left')
    end)
    it('a delivery the buyer cannot afford is not placed, and the screen gets the full price', function()
        bank.balances[BUYER] = 195
        local res = O.Create(OWNER, { kind = 'shop', buyerId = 'deli', method = 'trucking', cart = { { name = 'sandwich', quantity = 10 } } })
        assert_false(res.ok)
        assert_eq(res.error, 'insufficient_funds')
        assert_eq(res.data.total, 196)
        assert_eq(res.data.freight, 150)
        assert_eq(bal(BUYER), 195)
    end)
    it('a pickup is the goods only; the quote and the pricing match what an order is charged', function()
        bank.balances[BUYER] = 40
        local res = O.Create(OWNER, { kind = 'shop', buyerId = 'deli', method = 'pickup', cart = { { name = 'sandwich', quantity = 10 } } })
        assert_true(res.ok, tostring(res.error))
        assert_eq(res.data.total, 40)
        assert_eq(bal(AI_SUPPLIER), 40)
        local q = O.Quote('shop', 'deli', 'trucking', 40)
        assert_eq(q.total, 196)
        assert_eq(q.freight, 150)
        assert_eq(O.Quote('shop', 'deli', 'trucking', 2000).freight, 240, '12 % of the goods above the minimum')
        assert_eq(O.Quote('shop', 'deli', 'pickup', 40).total, 40)
        assert_eq(O.Quote('store', 'corner', 'trucking', 40), nil, 'no route: no delivery')
        local p = O.Pricing('shop', 'deli')
        assert_eq(p.markupRate, 0.15)
        assert_eq(p.freight.rate, 0.12)
        assert_eq(p.freight.min, 150)
        assert_eq(p.markupRefundShare, 0.5)
        assert_eq(Mock.selfExport('QuoteOrder')('shop', 'deli', 'trucking', 40).total, 196)
        assert_eq(Mock.selfExport('GetDeliveryPricing')('store', 'corner'), nil)
    end)
end)
