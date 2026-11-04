-- pf-justice orders (batch 15B, acceptance 2, 4, 5, 6, 8): CreateOrder validates per kind, is
-- idempotent by opts.key (duplicate / key_reused), enforces the caller allowlist, writes an order event
-- and fires orderCreated once; state changes, credits and releases follow the machines; fines are paid
-- on the real ledger (ledger_env) under pf-justice:order:<id>:pay:<n>, a clear refusal becomes a phone
-- invoice with ref pf-justice:order:<id>, an unclear result is held as payment_pending and settled by
-- the sweep through GetTransaction; citations with a contest window; conviction records, audited
-- expungement; a deleted character's open orders are vacated and the history kept anonymised.
--
-- The pf-justice statements run on an in-memory table store below (matched by their exact text from
-- PFJustice.SQL, so a changed statement fails here); the real SQL is covered by
-- realdb_specs/b15_justice_schema_realdb_spec.lua.
load_resource('tests/lua/ledger_env.lua')
QBCore = QBCoreMock

local invoices, invoiceAnswer = {}, nil
Mock.exportsByResource['pfm-phone'] = {
    CreateInvoice = function(_, data)
        invoices[#invoices + 1] = data
        if invoiceAnswer == false then return nil, 'db_error' end
        return 500 + #invoices
    end,
}
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end

LedgerEnv.load('pf-justice', {
    '[pfscripts]/pf-justice/config.lua',
    '[pfscripts]/pf-justice/shared/states.lua',
    '[pfscripts]/pf-justice/server/main.lua',
    '[pfscripts]/pf-justice/server/schema.lua',
    '[pfscripts]/pf-justice/server/orders.lua',
    '[pfscripts]/pf-justice/server/clock.lua',
    '[pfscripts]/pf-justice/server/records.lua',
    '[pfscripts]/pf-justice/server/api.lua',
})
Mock.exportsByResource['pf-justice'] = Mock.exportsByResource['__self']
local J = PFJustice
local Q = J.SQL

-- ── in-memory store for the pf-justice statements ──────────────────────────────────────────────
local DB
local function resetDB()
    DB = { orders = {}, events = {}, citations = {}, records = {}, audit = {}, n = { o = 0, e = 0, c = 0, r = 0, a = 0 } }
end
resetDB()
local function copy(t) if not t then return nil end local o = {} for k, v in pairs(t) do o[k] = v end return o end
local function list(tbl, desc)
    local out = {}
    for _, r in pairs(tbl) do out[#out + 1] = r end
    table.sort(out, function(a, b) if desc then return a.id > b.id end return a.id < b.id end)
    return out
end
local function has(v, set) for _, x in ipairs(set) do if x == v then return true end end return false end
local INC, OPEN = { 'jail', 'prison', 'remand' }, { 'pending', 'active', 'suspended' }
local function where(tbl, pred, desc, limit)
    local out = {}
    for _, r in ipairs(list(tbl, desc)) do
        if pred(r) then out[#out + 1] = copy(r) if limit and #out >= limit then break end end
    end
    return out
end
local H = {}
H[Q.insertOrder] = function(p)
    for _, o in pairs(DB.orders) do
        if p[21] and o.idem_key == p[21] then error('Duplicate entry for key uq_jo_key') end
        if p[22] and o.legacy_ref == p[22] then error('Duplicate entry for key uq_jo_legacy') end
    end
    DB.n.o = DB.n.o + 1
    local id = DB.n.o
    DB.orders[id] = { id = id, citizenid = p[1], kind = p[2], state = p[3], facility = p[4], clock = p[5], required_seconds = p[6],
        served_seconds = 0, credit_seconds = 0, forfeit_seconds = 0, last_tick_at = p[20], amount = p[7], paid_amount = 0,
        pay_attempt = 0, refund_attempt = 0, victim_cid = p[8], units = p[9], units_done = 0, days = p[10], conditions = p[11], charges = p[12],
        source_type = p[13], source_id = p[14], custody_id = p[15], parent_order_id = p[16], starts_at = p[17], due_at = p[18],
        ends_at = p[19], idem_key = p[21], legacy_ref = p[22], created_by = p[23], created_at = p[24], updated_at = p[25] }
    return id
end
H[Q.orderById] = function(p) return copy(DB.orders[tonumber(p[1])]) end
H[Q.orderByKey] = function(p) return where(DB.orders, function(o) return o.idem_key == p[1] end)[1] end
H[Q.orderByLegacy] = function(p) return where(DB.orders, function(o) return o.legacy_ref == p[1] end)[1] end
H[Q.ordersByCid] = function(p) return where(DB.orders, function(o) return o.citizenid == p[1] end, true, 500) end
H[Q.openIncarceration] = function(p)
    return where(DB.orders, function(o) return o.citizenid == p[1] and has(o.kind, INC) and has(o.state, OPEN) end)
end
H[Q.activeIndex] = function() return where(DB.orders, function(o) return has(o.kind, INC) and o.state == 'active' end) end
local function cas(id, from, fn)
    local o = DB.orders[tonumber(id)]
    if not o or o.state ~= from then return 0 end
    fn(o)
    return 1
end
H[Q.setState] = function(p) return cas(p[3], p[4], function(o) o.state, o.updated_at = p[1], p[2] end) end
H[Q.finish] = function(p) return cas(p[4], p[5], function(o) o.state, o.ends_at, o.updated_at = p[1], p[2], p[3] end) end
H[Q.activate] = function(p)
    return cas(p[4], p[5], function(o) o.state, o.starts_at, o.last_tick_at, o.updated_at = 'active', o.starts_at or p[1], p[2], p[3] end)
end
H[Q.saveClock] = function(p)
    local o = DB.orders[tonumber(p[5])]
    if not o or not (o.state == 'active' or o.state == 'pending') then return 0 end
    o.served_seconds, o.last_tick_at, o.release_at, o.updated_at = p[1], p[2], p[3], p[4]
    return 1
end
H[Q.adjust] = function(p)
    return cas(p[7], p[8], function(o)
        o.required_seconds, o.credit_seconds, o.forfeit_seconds, o.units, o.amount, o.updated_at = p[1], p[2], p[3], p[4], p[5], p[6]
    end)
end
H[Q.payBegin] = function(p)
    local o = DB.orders[tonumber(p[5])]
    if not o or o.state ~= p[6] or o.pay_attempt ~= p[7] then return 0 end
    o.state, o.pay_attempt, o.pay_key, o.pay_from, o.updated_at = 'payment_pending', p[1], p[2], p[3], p[4]
    return 1
end
H[Q.paid] = function(p) return cas(p[4], p[5], function(o) o.state, o.paid_amount, o.ends_at, o.updated_at = 'paid', p[1], p[2], p[3] end) end
H[Q.setInvoice] = function(p) return cas(p[4], p[5], function(o) o.state, o.invoice_id, o.updated_at = p[1], p[2], p[3] end) end
H[Q.byInvoice] = function(p) return where(DB.orders, function(o) return o.invoice_id == p[1] end, true)[1] end
H[Q.duePayments] = function(p)
    return where(DB.orders, function(o) return o.state == 'payment_pending' and o.updated_at <= p[1] and o.id > p[2] end, false, 50)
end
H[Q.dueRefunds] = function(p)
    return where(DB.orders, function(o) return (o.refund_state == 'due' or o.refund_state == 'unclear') and o.updated_at <= p[1] and o.id > p[2] end, false, 50)
end
H[Q.refundBegin] = function(p)
    local o = DB.orders[tonumber(p[6])]
    if not o or o.refund_state ~= nil then return 0 end
    o.refund_state, o.refund_attempt, o.refund_amount, o.refund_cid, o.refund_society, o.refund_invoice, o.updated_at = 'due', 0, p[1], p[2], p[3], p[4], p[5]
    return 1
end
H[Q.refundStep] = function(p)
    local o = DB.orders[tonumber(p[4])]
    if not o or o.refund_state ~= p[5] or o.refund_attempt ~= p[6] then return 0 end
    o.refund_state, o.refund_attempt, o.updated_at = p[1], p[2], p[3]
    return 1
end
PhoneInvoices = {} -- [invoice id] = true while pfm-phone still holds the row
H[Q.phoneInvoice] = function(p) return PhoneInvoices[p[1]] and { id = p[1] } or nil end
H[Q.dueDeadlines] = function(p)
    return where(DB.orders, function(o)
        return has(o.kind, { 'fine', 'citation', 'restitution', 'community_service' }) and has(o.state, { 'issued', 'upheld', 'assigned', 'active' })
            and o.due_at ~= nil and o.due_at <= p[1]
    end, false, 100)
end
H[Q.dueSupervision] = function(p)
    return where(DB.orders, function(o) return has(o.kind, { 'probation', 'parole' }) and o.state == 'active' and o.ends_at and o.ends_at <= p[1] end, false, 100)
end
local function rename(tbl, col, p)
    local n = 0
    for _, r in pairs(tbl) do if r[col] == p[2] then r[col] = p[1] n = n + 1 end end
    return n
end
H[Q.anonOrders] = function(p) return rename(DB.orders, 'citizenid', p) end
H[Q.anonVictim] = function(p) return rename(DB.orders, 'victim_cid', p) end
H[Q.anonCreatedBy] = function(p) return rename(DB.orders, 'created_by', p) end
H[Q.anonRefundCid] = function(p) return rename(DB.orders, 'refund_cid', p) end
H[Q.anonEventActor] = function(p) return rename(DB.events, 'actor_cid', p) end
H[Q.anonAuditActor] = function(p) return rename(DB.audit, 'actor_cid', p) end
H[Q.anonAuditEntity] = function(p)
    local n = 0
    for _, a in pairs(DB.audit) do if a.entity == 'record' and a.entity_id == p[2] then a.entity_id = p[1] n = n + 1 end end
    return n
end
H[Q.anonExpungedBy] = function(p) return rename(DB.records, 'expunged_by', p) end
local function replaceIn(tbl, p)
    local n = 0
    for _, r in pairs(tbl) do
        if type(r.detail) == 'string' and r.detail:find(p[1], 1, true) then
            local out, i = {}, 1
            while true do
                local a, b = r.detail:find(p[1], i, true)
                if not a then out[#out + 1] = r.detail:sub(i) break end
                out[#out + 1] = r.detail:sub(i, a - 1) .. p[2]
                i = b + 1
            end
            r.detail = table.concat(out)
            n = n + 1
        end
    end
    return n
end
H[Q.anonEventDetail] = function(p) return replaceIn(DB.events, p) end
H[Q.anonAuditDetail] = function(p) return replaceIn(DB.audit, p) end
H[Q.recordQueued] = function()
    local seen, out = {}, {}
    for _, e in ipairs(list(DB.events, true)) do
        if e.action == 'record_queued' and not seen[e.order_id] then seen[e.order_id] = true out[#out + 1] = { order_id = e.order_id } end
    end
    return out
end
H[Q.recordQueueDone] = function(p)
    for _, e in pairs(DB.events) do if e.idem_key == p[1] then e.action = 'record_done' return 1 end end
    return 0
end
H[Q.anonOfficer] = function(p) return rename(DB.citations, 'officer_cid', p) end
H[Q.anonRecords] = function(p) return rename(DB.records, 'citizenid', p) end
H[Q.insertEvent] = function(p)
    if p[7] then for _, e in pairs(DB.events) do if e.idem_key == p[7] then error('Duplicate entry for key uq_joe_key') end end end
    DB.n.e = DB.n.e + 1
    DB.events[DB.n.e] = { id = DB.n.e, order_id = p[1], action = p[2], detail = p[3], actor_cid = p[4], actor_kind = p[5],
        actor_resource = p[6], idem_key = p[7], at = p[8] }
    return DB.n.e
end
H[Q.eventByKey] = function(p) return where(DB.events, function(e) return e.idem_key == p[1] end)[1] end
H[Q.deleteEventByKey] = function(p)
    for id, e in pairs(DB.events) do if e.idem_key == p[1] then DB.events[id] = nil return 1 end end
    return 0
end
H[Q.countEvents] = function(p) return #where(DB.events, function(e) return e.order_id == p[1] and e.action == p[2] end) end
H[Q.insertCitation] = function(p)
    for _, c in pairs(DB.citations) do if c.uid == p[2] then error('Duplicate entry for key uq_cit_uid') end end
    DB.n.c = DB.n.c + 1
    DB.citations[DB.n.c] = { id = DB.n.c, order_id = p[1], uid = p[2], violation = p[3], plate = p[4], speed_kmh = p[5], limit_kmh = p[6],
        x = p[7], y = p[8], officer_cid = p[9], contest_until = p[10], at = p[11] }
    return DB.n.c
end
H[Q.citationByOrder] = function(p) return where(DB.citations, function(c) return c.order_id == p[1] end)[1] end
H[Q.insertRecord] = function(p)
    DB.n.r = DB.n.r + 1
    DB.records[DB.n.r] = { id = DB.n.r, citizenid = p[1], kind = p[2], ref_type = p[3], ref_id = p[4], summary = p[5], at = p[6] }
    return DB.n.r
end
H[Q.recordsByCid] = function(p) return where(DB.records, function(r) return r.citizenid == p[1] and r.expunged_at == nil end, true, p[2]) end
H[Q.recordsAllByCid] = function(p) return where(DB.records, function(r) return r.citizenid == p[1] end, true, p[2]) end
H[Q.recordByRef] = function(p)
    return where(DB.records, function(r) return r.citizenid == p[1] and r.kind == p[2] and r.ref_type == p[3] and r.ref_id == p[4] end)[1]
end
H[Q.expungeRecord] = function(p)
    local r = DB.records[tonumber(p[4])]
    if not r or r.citizenid ~= p[5] or r.expunged_at ~= nil then return 0 end
    r.expunged_at, r.expunged_by, r.expunge_ref = p[1], p[2], p[3]
    return 1
end
H[Q.insertAudit] = function(p)
    DB.n.a = DB.n.a + 1
    DB.audit[DB.n.a] = { id = DB.n.a, entity = p[1], entity_id = p[2], action = p[3], actor_cid = p[4], actor_kind = p[5], detail = p[7], at = p[8] }
    return DB.n.a
end
H[Q.sweepAudit] = function(p)
    local n = 0
    for id, a in pairs(DB.audit) do if a.at < p[1] then DB.audit[id] = nil n = n + 1 end end
    return n
end
H[Q.sweepOrderEvents] = function(p)
    local n = 0
    for id, e in pairs(DB.events) do if e.at < p[1] then DB.events[id] = nil n = n + 1 end end
    return n
end
FakeDB.extraPatterns = { { 'CREATE UNIQUE INDEX IF NOT EXISTS', function() return 0 end }, { 'CREATE INDEX IF NOT EXISTS', function() return 0 end } }
for sql, fn in pairs(H) do table.insert(FakeDB.extraPatterns, { sql, fn }) end

-- ── helpers ─────────────────────────────────────────────────────────────────────────────────────
local COP, SUSPECT, JUDGE, OTHER, ADMIN = 1, 2, 3, 4, 5
local api = exports['pf-justice']
local function as(res) Mock.invokingResource = res end
local function emitted(name)
    local out = {}
    for _, e in ipairs(Mock.serverEvents) do if e.name == 'pf-justice:server:' .. name then out[#out + 1] = e.args end end
    return out
end
local function events(orderId, action)
    local out = {}
    for _, e in ipairs(list(DB.events)) do if e.order_id == orderId and (not action or e.action == action) then out[#out + 1] = e end end
    return out
end
local function money(src) return Mock.players[src].PlayerData.money end
local function prison(minutes, key, extra)
    local spec = { cid = 'SUSPECTCID', kind = 'prison', minutes = minutes, facility = 'bolingbroke',
        sourceRef = { type = 'mdt_sentence', id = '991' }, charges = { { code = 'P-101', label = 'Robbery', count = 1 } } }
    for k, v in pairs(extra or {}) do spec[k] = v end
    return api:CreateOrder(spec, { key = key or ('pf-policemdt:sentence:' .. minutes .. ':prison'), actor = { src = COP } })
end
local function fine(amount, key, extra)
    local spec = { cid = 'SUSPECTCID', kind = 'fine', amount = amount, sourceRef = { type = 'mdt_sentence', id = 's' .. amount } }
    for k, v in pairs(extra or {}) do spec[k] = v end
    return api:CreateOrder(spec, { key = key or ('pf-policemdt:sentence:' .. amount .. ':fine'), actor = { src = COP } })
end

BeforeEach = function()
    LedgerEnv.reset()
    resetDB()
    Mock.reset()
    Mock.players = {}
    invoices, invoiceAnswer = {}, nil
    Mock.clock = 1700000000
    for k in pairs(J.Orders.activeIndex) do J.Orders.activeIndex[k] = nil end
    for k in pairs(J.Clock.inmates) do J.Clock.inmates[k] = nil end
    for k in pairs(J.Clock.srcOf) do J.Clock.srcOf[k] = nil end
    J.Rate.Forget('')
    PFJustice.LegacyImport = nil
    for k in pairs(PhoneInvoices) do PhoneInvoices[k] = nil end
    for k in pairs(J.Records.queue) do J.Records.queue[k] = nil end
    J.Orders.cursor.payments, J.Orders.cursor.refunds = 0, 0
    FakeDB.society('police', 0, 'job')
    FakeDB.society('doj', 0, 'job')
    local cop = Mock.newPlayer(COP, 'COPCID')
    cop.PlayerData.job = { name = 'police', type = 'leo', onduty = true, grade = { level = 2 } }
    Mock.newPlayer(SUSPECT, 'SUSPECTCID').PlayerData.money = { cash = 300, bank = 1000 }
    local judge = Mock.newPlayer(JUDGE, 'JUDGECID')
    judge.PlayerData.job = { name = 'judge', onduty = true, grade = { level = 1 } }
    Mock.newPlayer(OTHER, 'OTHERCID').PlayerData.money = { cash = 0, bank = 5000 }
    Mock.newPlayer(ADMIN, 'ADMINCID')
    Mock.aces = { [ADMIN] = { command = true } }
    Mock.coords = { [COP] = vector3(100.0, 200.0, 30.0), [SUSPECT] = vector3(101.0, 200.0, 30.0) }
    assert_true(J.Boot(), 'boot')
    as('pf-policemdt-DEV')
end

-- ── schema ──────────────────────────────────────────────────────────────────────────────────────
describe('schema', function()
    it('v1 applies; v2 (legacy import) waits for 15C code and runs once when it is there', function()
        assert_true(FakeDB.migrations['pf-justice:1'])
        assert_eq(FakeDB.migrations['pf-justice:2'], nil, 'no import code: v2 is not recorded')
        assert_true(J.Schema.Ready())
        local runs = 0
        PFJustice.LegacyImport = { Run = function() runs = runs + 1 return { ok = true } end }
        assert_true(J.Schema.Run())
        assert_true(FakeDB.migrations['pf-justice:2'])
        assert_eq(runs, 1)
        assert_true(J.Schema.Run())
        assert_eq(runs, 1, 'applied once')
    end)

    it('a failing import leaves v2 unapplied (retried at the next start), v1 still works', function()
        PFJustice.LegacyImport = { Run = function() return { ok = false, error = 'boom' } end }
        assert_true(J.Schema.Run())
        assert_eq(FakeDB.migrations['pf-justice:2'], nil)
        assert_true(prison(10).ok)
    end)
end)

-- ── CreateOrder ─────────────────────────────────────────────────────────────────────────────────
describe('CreateOrder', function()
    it('refuses a resource that is not on the allowlist, and writes nothing', function()
        as('some-script')
        local res = prison(10)
        assert_eq(res.ok, false)
        assert_eq(res.error, 'not_allowed')
        assert_eq(DB.n.o, 0)
        assert_eq(#emitted('orderCreated'), 0)
    end)

    it('creates an active prison order with an event and orderCreated once', function()
        local res = prison(30)
        assert_true(res.ok)
        assert_eq(res.state, 'active')
        local o = DB.orders[res.orderId]
        assert_eq(o.kind, 'prison')
        assert_eq(o.required_seconds, 1800)
        assert_eq(o.clock, 'online', 'owner decision D2')
        assert_eq(o.facility, 'bolingbroke')
        assert_eq(o.created_by, 'COPCID')
        assert_eq(o.source_type, 'mdt_sentence')
        assert_eq(#events(res.orderId, 'created'), 1)
        local ev = emitted('orderCreated')
        assert_eq(#ev, 1)
        assert_eq(ev[1][1].id, res.orderId)
        assert_eq(ev[1][1].cid, 'SUSPECTCID')
        assert_eq(ev[1][1].remainingSeconds, 1800)
        assert_true(select(1, api:IsIncarcerated('SUSPECTCID')))
        assert_eq(api:GetJailMinutes(SUSPECT), 30)
    end)

    it('is idempotent by key: the same arguments return the first order once; different ones are key_reused', function()
        local a = prison(30, 'pf-policemdt:sentence:7:prison')
        local b = prison(30, 'pf-policemdt:sentence:7:prison')
        assert_true(b.ok)
        assert_true(b.duplicate)
        assert_eq(b.orderId, a.orderId)
        assert_eq(DB.n.o, 1)
        assert_eq(#emitted('orderCreated'), 1, 'fired once')
        assert_eq(#events(a.orderId, 'created'), 1)
        local c = prison(45, 'pf-policemdt:sentence:7:prison')
        assert_eq(c.ok, false)
        assert_eq(c.error, 'key_reused')
        assert_eq(DB.n.o, 1)
    end)

    it('a key raced in by another writer between the check and the insert is a duplicate', function()
        local realInsert = H[Q.insertOrder]
        local spec = { cid = 'SUSPECTCID', kind = 'fine', amount = 50, sourceRef = { type = 'mdt_sentence', id = 'r1' } }
        -- the first insert fails as the unique key would: someone else stored the same key
        for _, e in ipairs(FakeDB.extraPatterns) do
            if e[1] == Q.insertOrder then
                e[2] = function(p)
                    e[2] = realInsert
                    realInsert(p)
                    error('Duplicate entry for key uq_jo_key')
                end
            end
        end
        local res = api:CreateOrder(spec, { key = 'race:1', actor = { src = COP } })
        assert_true(res.ok)
        assert_true(res.duplicate)
        assert_eq(DB.n.o, 1)
    end)

    it('validates per kind', function()
        local function bad(spec, opts, code)
            local res = api:CreateOrder(spec, opts or { key = 'k:' .. tostring(spec.kind), actor = { src = COP } })
            assert_eq(res.ok, false, tostring(spec.kind))
            assert_eq(res.error, code or 'bad_args', tostring(spec.kind))
        end
        bad({ cid = 'SUSPECTCID', kind = 'prison' })                                   -- no minutes
        bad({ cid = 'SUSPECTCID', kind = 'jail', minutes = 0 })
        bad({ cid = 'SUSPECTCID', kind = 'jail', minutes = 1441 })
        bad({ cid = 'SUSPECTCID', kind = 'jail', minutes = 1.5 })
        bad({ cid = 'SUSPECTCID', kind = 'jail', minutes = 0 / 0 })
        bad({ cid = 'SUSPECTCID', kind = 'prison', minutes = 10, facility = 'mrpd_holding' }) -- holding is not a prison
        bad({ cid = 'SUSPECTCID', kind = 'prison', minutes = 10, facility = 'moon' })
        bad({ cid = 'SUSPECTCID', kind = 'fine' })
        bad({ cid = 'SUSPECTCID', kind = 'fine', amount = -5 })
        bad({ cid = 'SUSPECTCID', kind = 'fine', amount = 10, dueAt = Mock.clock - 5 })
        bad({ cid = 'SUSPECTCID', kind = 'restitution', amount = 10, victimCid = 'SUSPECTCID' })
        bad({ cid = 'SUSPECTCID', kind = 'community_service', units = 0 })
        bad({ cid = 'SUSPECTCID', kind = 'probation', days = 400 })
        bad({ cid = 'SUSPECTCID', kind = 'parole', days = 10, conditions = { { kind = 'fly' } } })
        bad({ cid = 'SUSPECTCID', kind = 'banishment' })
        bad({ cid = 'bad cid!', kind = 'fine', amount = 10 })
        bad({ cid = 'SUSPECTCID', kind = 'fine', amount = 10, sourceRef = { type = 'rumour' } })
        bad({ cid = 'SUSPECTCID', kind = 'fine', amount = 10 }, { actor = { src = COP } })         -- no key
        bad({ cid = 'SUSPECTCID', kind = 'fine', amount = 10 }, { key = 'has space', actor = { src = COP } })
        bad({ cid = 'SUSPECTCID', kind = 'jail', minutes = 5, clock = 'realtime' }, nil, 'no_permission')
        bad({ cid = 'SUSPECTCID', kind = 'fine', amount = 10 }, { key = 'off:1', actor = { src = 99 } }, 'offline')
        assert_eq(DB.n.o, 0)
    end)

    it('each kind starts in its machine state with its own fields', function()
        local now = Mock.clock
        local r = api:CreateOrder({ cid = 'SUSPECTCID', kind = 'community_service', units = 10 }, { key = 'cs:1', actor = { src = COP } })
        assert_eq(r.state, 'assigned')
        assert_eq(DB.orders[r.orderId].due_at, now + Config.CommunityService.DefaultDays * 86400)
        assert_eq(DB.orders[r.orderId].clock, 'realtime', 'CS deadlines run in real time')
        r = api:CreateOrder({ cid = 'SUSPECTCID', kind = 'probation', days = 14, conditions = { { kind = 'checkin', everyDays = 7 } } },
            { key = 'prob:1', actor = { src = COP } })
        assert_eq(r.state, 'active')
        assert_eq(DB.orders[r.orderId].ends_at, now + 14 * 86400)
        r = api:CreateOrder({ cid = 'SUSPECTCID', kind = 'restitution', amount = 250, victimCid = 'OTHERCID' }, { key = 'res:1', actor = { src = COP } })
        assert_eq(r.state, 'issued')
        assert_eq(DB.orders[r.orderId].victim_cid, 'OTHERCID')
        r = api:CreateOrder({ cid = 'SUSPECTCID', kind = 'remand', facility = 'mrpd_holding' }, { key = 'rem:1', actor = { src = COP } })
        assert_eq(r.state, 'active')
        assert_eq(DB.orders[r.orderId].required_seconds, nil, 'remand without a fixed time')
    end)

    it('an admin may choose the clock policy; the MDT may not', function()
        as('pfm-adminmenu')
        local r = api:CreateOrder({ cid = 'SUSPECTCID', kind = 'jail', minutes = 5, clock = 'hybrid' }, { key = 'adm:1', actor = { kind = 'admin', src = ADMIN } })
        assert_true(r.ok)
        assert_eq(DB.orders[r.orderId].clock, 'hybrid')
        local denied = api:CreateOrder({ cid = 'SUSPECTCID', kind = 'jail', minutes = 5 }, { key = 'adm:2', actor = { kind = 'admin', src = COP } })
        assert_eq(denied.error, 'no_permission', 'an admin actor needs the ACE')
    end)

    it('a second incarceration joins the chain: never two active orders for one citizen', function()
        local a = prison(30)
        local b = prison(60, 'k:conc')
        assert_eq(b.state, 'pending')
        assert_eq(b.existing, a.orderId)
        assert_eq(DB.orders[b.orderId].parent_order_id, a.orderId)
        assert_true(DB.orders[b.orderId].starts_at ~= nil, 'concurrent: counts from now')
        local c = prison(20, 'k:cons', { merge = 'consecutive' })
        assert_eq(c.state, 'pending')
        assert_eq(DB.orders[c.orderId].parent_order_id, b.orderId, 'consecutive: after the last one')
        assert_eq(DB.orders[c.orderId].starts_at, nil)
        local active = 0
        for _, o in pairs(DB.orders) do if o.state == 'active' then active = active + 1 end end
        assert_eq(active, 1)
        -- 60 min running beside the 30, then the 20 after them
        assert_eq(api:GetJailMinutes('SUSPECTCID'), 80)
    end)
end)

-- ── state changes ───────────────────────────────────────────────────────────────────────────────
describe('SetOrderState and ReleaseNow', function()
    it('pfm-prison completes; releaseOrdered fires once; it may not vacate', function()
        local a = prison(30)
        as('pfm-prison')
        local denied = api:SetOrderState(a.orderId, 'vacated', {})
        assert_eq(denied.error, 'no_permission')
        local res = api:SetOrderState(a.orderId, 'completed', { reason = 'served' })
        assert_true(res.ok)
        assert_eq(DB.orders[a.orderId].state, 'completed')
        assert_eq(#emitted('releaseOrdered'), 1)
        assert_eq(emitted('releaseOrdered')[1][1], 'SUSPECTCID')
        local again = api:SetOrderState(a.orderId, 'completed', {})
        assert_true(again.duplicate)
        assert_eq(#emitted('releaseOrdered'), 1, 'exactly once')
        assert_false(select(1, api:IsIncarcerated('SUSPECTCID')))
        local back = api:SetOrderState(a.orderId, 'active', {})
        assert_eq(back.error, 'invalid_state')
    end)

    it('a concurrent order with time left takes over; release only when the chain is done', function()
        local a = prison(30)
        local b = prison(60, 'k:conc')
        as('pfm-prison')
        assert_true(api:SetOrderState(a.orderId, 'completed', {}).ok)
        assert_eq(DB.orders[b.orderId].state, 'active')
        assert_eq(#emitted('releaseOrdered'), 0)
        local _, orderId = api:IsIncarcerated(SUSPECT)
        assert_eq(orderId, b.orderId)
        assert_true(api:SetOrderState(b.orderId, 'completed', {}).ok)
        assert_eq(#emitted('releaseOrdered'), 1)
    end)

    it('ReleaseNow vacates the whole chain once', function()
        prison(30)
        prison(60, 'k:conc')
        prison(20, 'k:cons', { merge = 'consecutive' })
        as('pfm-policejob')
        local res = api:ReleaseNow(SUSPECT, '/unjail', { actor = { src = COP } })
        assert_true(res.ok)
        assert_eq(res.released, 3)
        for _, o in pairs(DB.orders) do assert_eq(o.state, 'vacated') end
        assert_eq(#emitted('releaseOrdered'), 1)
        local again = api:ReleaseNow('SUSPECTCID', 'again', {})
        assert_eq(again.released, 0)
        assert_eq(#emitted('releaseOrdered'), 1)
        as('pf-policemdt-DEV')
        assert_eq(api:ReleaseNow(SUSPECT, 'x', {}).error, 'not_allowed')
    end)

    it('fines are waived, not vacated; the machine refuses the rest', function()
        local f = fine(100)
        as('pfm-adminmenu')
        assert_eq(api:SetOrderState(f.orderId, 'vacated', { actor = { kind = 'admin', src = ADMIN } }).error, 'invalid_state')
        assert_eq(api:SetOrderState(f.orderId, 'waived', { actor = { src = COP } }).error, 'no_permission', 'adminmenu needs an admin actor')
        assert_true(api:SetOrderState(f.orderId, 'waived', { actor = { kind = 'admin', src = ADMIN } }).ok)
        assert_eq(DB.orders[f.orderId].state, 'waived')
        assert_eq(api:SetOrderState(9999, 'waived', { actor = { kind = 'admin', src = ADMIN } }).error, 'not_found')
    end)
end)

describe('AdjustOrder', function()
    it('pfm-prison credits are keyed and capped at Config.Credits.MaxShare', function()
        local a = prison(60)
        as('pfm-prison')
        local r1 = api:AdjustOrder(a.orderId, { kind = 'credit', seconds = 600, reason = 'work' }, { key = 'pfm-prison:credit:1:t1' })
        assert_true(r1.ok)
        assert_eq(r1.applied, 600)
        local dup = api:AdjustOrder(a.orderId, { kind = 'credit', seconds = 600 }, { key = 'pfm-prison:credit:1:t1' })
        assert_true(dup.duplicate)
        assert_eq(DB.orders[a.orderId].credit_seconds, 600, 'a retry never credits twice')
        assert_eq(api:AdjustOrder(a.orderId, { kind = 'credit', seconds = 300 }, { key = 'pfm-prison:credit:1:t1' }).error, 'key_reused')
        -- 50 % of 3600 s is the most work can take off
        local r2 = api:AdjustOrder(a.orderId, { kind = 'credit', seconds = 3601 }, { key = 'pfm-prison:credit:1:t2' })
        assert_eq(r2.error, 'bad_args', 'over MaxSecondsPerCall')
        r2 = api:AdjustOrder(a.orderId, { kind = 'credit', seconds = 3000 }, { key = 'pfm-prison:credit:1:t3' })
        assert_eq(r2.applied, 1200)
        assert_eq(DB.orders[a.orderId].credit_seconds, 1800)
        assert_eq(api:AdjustOrder(a.orderId, { kind = 'credit', seconds = 60 }, {}).error, 'bad_args', 'key required')
        assert_eq(api:AdjustOrder(a.orderId, { kind = 'modify', seconds = 60 }, { key = 'm1' }).error, 'no_permission')
        assert_eq(#emitted('orderChanged') >= 2, true)
    end)

    it('forfeits only take back credits (prison); admins may add time', function()
        local a = prison(60)
        as('pfm-prison')
        api:AdjustOrder(a.orderId, { kind = 'credit', seconds = 300 }, { key = 'c1' })
        local f = api:AdjustOrder(a.orderId, { kind = 'forfeit', seconds = 900 }, { key = 'f1' })
        assert_eq(f.applied, 300)
        assert_eq(DB.orders[a.orderId].forfeit_seconds, 300)
        as('pfm-adminmenu')
        f = api:AdjustOrder(a.orderId, { kind = 'forfeit', seconds = 900 }, { key = 'f2', actor = { kind = 'admin', src = ADMIN } })
        assert_eq(f.applied, 900)
        assert_eq(api:GetJailMinutes(SUSPECT), 75)
        local m = api:AdjustOrder(a.orderId, { kind = 'modify', seconds = 600 }, { actor = { kind = 'admin', src = ADMIN } })
        assert_true(m.ok)
        assert_eq(DB.orders[a.orderId].required_seconds, 600)
    end)

    it('escape suspends (not a completion) and recapture resumes', function()
        local a = prison(60)
        as('pfm-prison')
        local s = api:AdjustOrder(a.orderId, { kind = 'suspend', reason = 'escape' }, { key = 'esc:1' })
        assert_true(s.ok)
        assert_eq(DB.orders[a.orderId].state, 'suspended')
        assert_eq(#emitted('releaseOrdered'), 0, 'an escape is not a release')
        assert_false(select(1, api:IsIncarcerated(SUSPECT)))
        assert_true(api:AdjustOrder(a.orderId, { kind = 'resume' }, { key = 'esc:1:back' }).ok)
        assert_eq(DB.orders[a.orderId].state, 'active')
        assert_eq(api:AdjustOrder(a.orderId, { kind = 'resume' }, { key = 'esc:2' }).error, 'invalid_state')
    end)

    it('a credit that serves the order completes it for an online inmate', function()
        local a = prison(10)
        as('pfm-adminmenu')
        assert_eq(api:AdjustOrder(a.orderId, { kind = 'credit', seconds = 600 }, { actor = { kind = 'admin', src = ADMIN } }).error, 'bad_args', 'credits are keyed')
        api:AdjustOrder(a.orderId, { kind = 'credit', seconds = 600 }, { key = 'adm:c1', actor = { kind = 'admin', src = ADMIN } })
        assert_eq(DB.orders[a.orderId].state, 'completed')
        assert_eq(#emitted('releaseOrdered'), 1)
    end)
end)

-- ── payments ────────────────────────────────────────────────────────────────────────────────────
describe('PayOrder on the real ledger', function()
    it('charges once under pf-justice:order:<id>:pay:1 to society:police', function()
        local f = fine(400)
        local res = api:PayOrder(f.orderId, { payerSrc = SUSPECT, account = 'bank', key = 'mdt:pay:1' })
        assert_true(res.ok)
        assert_eq(res.state, 'paid')
        assert_eq(money(SUSPECT).bank, 600)
        assert_eq(FakeDB.bank_accounts.police.account_balance, 400)
        local key = 'pf-justice:order:' .. f.orderId .. ':pay:1'
        assert_eq(FakeDB.byKey[key].state, 'completed')
        assert_eq(DB.orders[f.orderId].paid_amount, 400)
        assert_eq(#emitted('paymentSettled'), 1)
        assert_eq(emitted('paymentSettled')[1][2], 'paid')
        -- the same caller key again: nothing more
        local again = api:PayOrder(f.orderId, { payerSrc = SUSPECT, account = 'bank', key = 'mdt:pay:1' })
        assert_true(again.ok)
        assert_true(again.duplicate)
        assert_eq(money(SUSPECT).bank, 600)
        assert_eq(api:PayOrder(f.orderId, { payerSrc = SUSPECT, key = 'mdt:pay:2' }).error, 'invalid_state')
        -- a paid fine is a conviction on the record
        assert_eq(#where(DB.records, function(r) return r.kind == 'conviction' and r.ref_id == tostring(f.orderId) end), 1)
    end)

    it('court fines go to society:doj; restitution to the victim', function()
        local f = fine(100, 'court:1', { sourceRef = { type = 'court_decision', id = 'c1' } })
        assert_true(api:PayOrder(f.orderId, { payerSrc = SUSPECT, account = 'cash', key = 'p1' }).ok)
        assert_eq(FakeDB.bank_accounts.doj.account_balance, 100)
        assert_eq(money(SUSPECT).cash, 200)
        local r = api:CreateOrder({ cid = 'SUSPECTCID', kind = 'restitution', amount = 250, victimCid = 'OTHERCID' }, { key = 'res:1', actor = { src = COP } })
        Mock.clock = Mock.clock + 10
        assert_true(api:PayOrder(r.orderId, { payerSrc = SUSPECT, key = 'p2' }).ok)
        assert_eq(money(OTHER).bank, 5250)
    end)

    it('a clear refusal becomes a phone invoice (ref, cannot decline); the phone settles it', function()
        local f = fine(5000)
        local res = api:PayOrder(f.orderId, { payerSrc = SUSPECT, account = 'bank', key = 'k1' })
        assert_eq(res.ok, false)
        assert_eq(res.error, 'insufficient_funds')
        assert_eq(res.state, 'invoiced')
        assert_eq(#invoices, 1)
        assert_eq(invoices[1].ref, 'pf-justice:order:' .. f.orderId)
        assert_eq(invoices[1].candecline, 0)
        assert_eq(invoices[1].society, 'police')
        assert_eq(invoices[1].amount, 5000)
        assert_eq(money(SUSPECT).bank, 1000, 'nothing taken')
        assert_eq(DB.orders[f.orderId].invoice_id, res.invoiceId)
        assert_eq(api:PayOrder(f.orderId, { payerSrc = SUSPECT, key = 'k2' }).error, 'invalid_state', 'pay the invoice on the phone')
        -- pfm-phone raises the server-only event once the invoice is paid
        Mock.fireEvent('pfm-phone:server:invoiceSettled', nil, { id = res.invoiceId, ref = 'pf-justice:order:' .. f.orderId, amount = 5000 }, 'paid')
        assert_eq(DB.orders[f.orderId].state, 'paid')
        assert_eq(#emitted('paymentSettled'), 1)
        Mock.fireEvent('pfm-phone:server:invoiceSettled', nil, { id = res.invoiceId, ref = 'pf-justice:order:' .. f.orderId }, 'paid')
        assert_eq(#emitted('paymentSettled'), 1, 'settled once')
    end)

    it('an invoice without ref is matched by id; declined goes back to issued; a client cannot fire it', function()
        local f = fine(5000)
        local res = api:PayOrder(f.orderId, { payerSrc = SUSPECT, key = 'k1' })
        Mock.fireEvent('pfm-phone:server:invoiceSettled', SUSPECT, { id = res.invoiceId }, 'paid')
        assert_eq(DB.orders[f.orderId].state, 'invoiced', 'from a player source: ignored')
        Mock.fireEvent('pfm-phone:server:invoiceSettled', nil, { id = res.invoiceId }, 'declined')
        assert_eq(DB.orders[f.orderId].state, 'issued')
        assert_eq(DB.orders[f.orderId].invoice_id, nil)
    end)

    it('someone else paying with too little is refused without an invoice for the citizen', function()
        local f = fine(400)
        Mock.players[OTHER].PlayerData.money.bank = 10
        local res = api:PayOrder(f.orderId, { payerSrc = OTHER, key = 'o1' })
        assert_eq(res.error, 'insufficient_funds')
        assert_eq(res.state, 'issued')
        assert_eq(#invoices, 0)
        -- the next attempt uses a new numbered ledger key (a failed key stays failed)
        Mock.clock = Mock.clock + 10
        Mock.players[OTHER].PlayerData.money.bank = 1000
        assert_true(api:PayOrder(f.orderId, { payerSrc = OTHER, key = 'o2' }).ok)
        assert_eq(FakeDB.byKey['pf-justice:order:' .. f.orderId .. ':pay:1'].state, 'failed')
        assert_eq(FakeDB.byKey['pf-justice:order:' .. f.orderId .. ':pay:2'].state, 'completed')
    end)

    it('an unclear result is held as payment_pending, never charged again, and settled by the sweep', function()
        local f = fine(400)
        FakeDB.failNext.creditSociety = true -- the bank errors after the money left the player
        local res = api:PayOrder(f.orderId, { payerSrc = SUSPECT, key = 'u1' })
        assert_eq(res.ok, false)
        assert_eq(res.error, 'payment_unclear')
        assert_eq(DB.orders[f.orderId].state, 'payment_pending')
        assert_eq(money(SUSPECT).bank, 600)
        Mock.clock = Mock.clock + 10
        local again = api:PayOrder(f.orderId, { payerSrc = SUSPECT, key = 'u2' })
        assert_eq(again.error, 'payment_unclear')
        assert_eq(money(SUSPECT).bank, 600, 'not charged twice')
        assert_eq(FakeDB.byKey['pf-justice:order:' .. f.orderId .. ':pay:2'], nil, 'no new key while unclear')
        -- the sweep waits while the ledger row is debited
        Mock.clock = Mock.clock + 200
        J.Orders.Sweep(Mock.clock)
        assert_eq(DB.orders[f.orderId].state, 'payment_pending')
        PFLedger.Recover()
        J.Orders.Sweep(Mock.clock)
        assert_eq(DB.orders[f.orderId].state, 'paid')
        assert_eq(FakeDB.bank_accounts.police.account_balance, 400)
        assert_eq(#emitted('paymentSettled'), 1)
    end)

    it('a payment that never reached the ledger (crash) goes back to issued; the next attempt is numbered', function()
        local f = fine(400)
        local o = DB.orders[f.orderId]
        o.state, o.pay_attempt, o.pay_key, o.updated_at = 'payment_pending', 1, 'pf-justice:order:' .. f.orderId .. ':pay:1', Mock.clock
        Mock.clock = Mock.clock + 300
        J.Orders.Sweep(Mock.clock)
        assert_eq(o.state, 'issued')
        assert_eq(emitted('paymentSettled')[1][2], 'failed')
        assert_true(api:PayOrder(f.orderId, { payerSrc = SUSPECT, key = 'n1' }).ok)
        assert_eq(FakeDB.byKey['pf-justice:order:' .. f.orderId .. ':pay:2'].state, 'completed')
    end)

    it('allowlist, arguments and the payer rate limit', function()
        local f = fine(400)
        as('some-script')
        assert_eq(api:PayOrder(f.orderId, { payerSrc = SUSPECT, key = 'x' }).error, 'not_allowed')
        as('pf-government')
        assert_eq(api:PayOrder(f.orderId, { payerSrc = 77, key = 'x' }).error, 'offline')
        assert_eq(api:PayOrder(f.orderId, { payerSrc = 'two', key = 'x' }).error, 'bad_args')
        assert_eq(api:PayOrder(f.orderId, { payerSrc = SUSPECT, account = 'crypto', key = 'x' }).error, 'bad_args')
        assert_eq(api:PayOrder(f.orderId, { payerSrc = SUSPECT }).error, 'bad_args', 'key required')
        Mock.players[SUSPECT].PlayerData.money.bank = 0
        Mock.players[SUSPECT].PlayerData.money.cash = 0
        invoiceAnswer = false
        assert_eq(api:PayOrder(f.orderId, { payerSrc = SUSPECT, key = 'r1' }).error, 'insufficient_funds')
        assert_eq(api:PayOrder(f.orderId, { payerSrc = SUSPECT, key = 'r2' }).error, 'rate_limited')
    end)
end)

-- ── citations ───────────────────────────────────────────────────────────────────────────────────
describe('citations', function()
    local function cite(key, extra)
        local spec = { cid = 'SUSPECTCID', amount = 150, violation = 'Speeding', plate = 'abc123', speed = 120, limit = 80,
            officerSrc = COP, location = { x = 9999, y = 9999 } }
        for k, v in pairs(extra or {}) do spec[k] = v end
        return api:IssueCitation(spec, { key = key or 'pfm-policejob:citation:u1' })
    end

    it('creates a citation order plus a citation row at the officer server position', function()
        as('pfm-policejob')
        local res = cite()
        assert_true(res.ok)
        local o = DB.orders[res.orderId]
        assert_eq(o.kind, 'citation')
        assert_eq(o.state, 'issued')
        assert_eq(o.source_type, 'citation')
        local c = DB.citations[res.citationId]
        assert_eq(c.order_id, res.orderId)
        assert_eq(c.uid, o.source_id)
        assert_eq(c.officer_cid, 'COPCID')
        assert_eq(c.plate, 'ABC123')
        assert_eq(c.x, 100.0, 'the server position, not the caller value')
        assert_eq(c.contest_until, Mock.clock + 7 * 86400)
        local again = cite()
        assert_true(again.duplicate)
        assert_eq(again.citationId, res.citationId)
        assert_eq(DB.n.c, 1)
    end)

    it('only an on-duty officer cites', function()
        as('pfm-policejob')
        Mock.players[COP].PlayerData.job.onduty = false
        assert_eq(cite('k2').error, 'no_permission')
        assert_eq(DB.n.o, 0)
    end)

    it('contest window: the cited citizen contests once; a decision upholds or dismisses', function()
        as('pfm-policejob')
        local res = cite()
        as('pf-policemdt-DEV')
        assert_eq(api:ContestCitation(res.orderId, { actor = { src = OTHER } }).error, 'no_permission')
        assert_true(api:ContestCitation(res.orderId, { actor = { src = SUSPECT }, reason = 'radar was wrong' }).ok)
        assert_eq(DB.orders[res.orderId].state, 'contested')
        assert_eq(api:PayOrder(res.orderId, { payerSrc = SUSPECT, key = 'c1' }).error, 'invalid_state', 'not payable while contested')
        as('pfm-adminmenu')
        assert_true(api:DecideCitation(res.orderId, true, { actor = { kind = 'admin', src = ADMIN } }).ok)
        assert_eq(DB.orders[res.orderId].state, 'upheld')
        assert_eq(#where(DB.records, function(r) return r.kind == 'citation' end), 1, 'an upheld citation is on the record')
        as('pf-policemdt-DEV')
        assert_eq(api:ContestCitation(res.orderId, { actor = { src = SUSPECT } }).error, 'invalid_state', 'once')
        assert_true(api:PayOrder(res.orderId, { payerSrc = SUSPECT, key = 'c2' }).ok)
        assert_eq(#where(DB.records, function(r) return r.kind == 'citation' end), 1, 'no second entry')
    end)

    it('the window closes; a dismissed citation leaves no record', function()
        as('pfm-policejob')
        local a = cite('k:a')
        local b = cite('k:b', { contestDays = 1 })
        as('pf-policemdt-DEV')
        Mock.clock = Mock.clock + 2 * 86400
        assert_eq(api:ContestCitation(b.orderId, { actor = { src = SUSPECT } }).error, 'invalid_state')
        assert_true(api:ContestCitation(a.orderId, { actor = { src = SUSPECT } }).ok)
        as('pfm-adminmenu')
        assert_true(api:DecideCitation(a.orderId, false, { actor = { kind = 'admin', src = ADMIN } }).ok)
        assert_eq(DB.orders[a.orderId].state, 'dismissed')
        assert_eq(#where(DB.records, function(r) return r.kind == 'citation' end), 0)
    end)
end)

-- ── deadlines ───────────────────────────────────────────────────────────────────────────────────
describe('real-time deadlines (sweep)', function()
    it('fines and community service go overdue at dueAt; probation completes at its end', function()
        local f = fine(100)
        local cs = api:CreateOrder({ cid = 'SUSPECTCID', kind = 'community_service', units = 5 }, { key = 'cs:1', actor = { src = COP } })
        local p = api:CreateOrder({ cid = 'SUSPECTCID', kind = 'probation', days = 3 }, { key = 'p:1', actor = { src = COP } })
        Mock.clock = Mock.clock + 3 * 86400 + 1
        J.Orders.Sweep(Mock.clock)
        assert_eq(DB.orders[f.orderId].state, 'issued')
        assert_eq(DB.orders[p.orderId].state, 'completed')
        assert_eq(#where(DB.records, function(r) return r.ref_id == tostring(p.orderId) end), 1)
        Mock.clock = Mock.clock + 14 * 86400
        local out = J.Orders.Sweep(Mock.clock)
        assert_eq(out.overdue, 2)
        assert_eq(DB.orders[f.orderId].state, 'overdue')
        assert_eq(DB.orders[cs.orderId].state, 'overdue')
        -- an overdue fine can still be paid
        assert_true(api:PayOrder(f.orderId, { payerSrc = SUSPECT, key = 'late' }).ok)
    end)
end)

-- ── records ─────────────────────────────────────────────────────────────────────────────────────
describe('records', function()
    it('a completed sentence is one conviction; a vacated one is none', function()
        local a = prison(30)
        as('pfm-prison')
        api:SetOrderState(a.orderId, 'completed', {})
        local b = (function() as('pf-policemdt-DEV') return prison(10, 'k:b') end)()
        as('pfm-adminmenu')
        api:SetOrderState(b.orderId, 'vacated', { actor = { kind = 'admin', src = ADMIN } })
        local conv = where(DB.records, function(r) return r.kind == 'conviction' end)
        assert_eq(#conv, 1)
        assert_eq(conv[1].ref_id, tostring(a.orderId))
        assert_true(conv[1].summary:find('Prison sentence 30 min', 1, true) ~= nil)
        assert_true(conv[1].summary:find('P-101 Robbery', 1, true) ~= nil)
        assert_true(#emitted('recordChanged') >= 1)
    end)

    it('GetRecord is filtered per invoker; AddRecordEntry is allowlisted and deduplicated by ref', function()
        local add = api:AddRecordEntry('SUSPECTCID', { kind = 'arrest', ref = { type = 'custody', id = '12' }, summary = 'Arrested for robbery' }, { actor = { src = COP } })
        assert_true(add.ok)
        local dup = api:AddRecordEntry('SUSPECTCID', { kind = 'arrest', ref = 'custody:12', summary = 'Arrested again' }, {})
        assert_true(dup.duplicate)
        assert_eq(dup.entryId, add.entryId)
        assert_eq(api:AddRecordEntry('SUSPECTCID', { kind = 'legacy_flag', summary = 'x' }, {}).error, 'bad_args')
        as('some-script')
        assert_eq(api:AddRecordEntry('SUSPECTCID', { kind = 'note', summary = 'x' }, {}).error, 'not_allowed')
        local rec = api:GetRecord('SUSPECTCID', {})
        assert_true(rec.ok)
        assert_eq(#rec.entries, 1)
        assert_eq(rec.entries[1].summary, 'Arrested for robbery')
        assert_eq(rec.entries[1].refId, nil, 'default fields only')
        as('pf-policemdt-DEV')
        assert_eq(api:GetRecord('SUSPECTCID', {}).entries[1].refId, '12')
    end)

    it('Expunge soft-deletes with an audit row, for a judge or an admin only', function()
        local e1 = api:AddRecordEntry('SUSPECTCID', { kind = 'note', summary = 'one' }, {}).entryId
        local e2 = api:AddRecordEntry('SUSPECTCID', { kind = 'note', summary = 'two' }, {}).entryId
        as('pf-government')
        assert_eq(api:Expunge('SUSPECTCID', { e1 }, { actor = { src = OTHER } }).error, 'no_permission')
        Mock.players[JUDGE].PlayerData.job.onduty = false
        assert_eq(api:Expunge('SUSPECTCID', { e1 }, { actor = { src = JUDGE } }).error, 'no_permission', 'an off-duty judge')
        Mock.players[JUDGE].PlayerData.job.onduty = true
        local res = api:Expunge('SUSPECTCID', { e1, e1 }, { actor = { src = JUDGE }, courtOrderId = 'CO-9' })
        assert_true(res.ok)
        assert_eq(res.n, 1)
        assert_eq(DB.records[e1].expunged_at, Mock.clock, 'the row stays')
        assert_eq(DB.records[e1].expunged_by, 'JUDGECID')
        assert_eq(DB.records[e1].expunge_ref, 'CO-9')
        local audit = where(DB.audit, function(a) return a.entity == 'record' and a.action == 'expunge' end)
        assert_eq(#audit, 1)
        assert_eq(audit[1].actor_cid, 'JUDGECID')
        local rec = api:GetRecord('SUSPECTCID', {})
        assert_eq(#rec.entries, 1)
        assert_eq(rec.entries[1].id, e2)
        assert_eq(api:Expunge('SUSPECTCID', { e1 }, { actor = { src = JUDGE } }).n, 0, 'twice changes nothing')
        as('some-script')
        assert_eq(api:Expunge('SUSPECTCID', { e2 }, { actor = { src = JUDGE } }).error, 'not_allowed')
    end)
end)

-- ── deleted characters ──────────────────────────────────────────────────────────────────────────
describe('pfm-core:server:characterDeleted', function()
    it('vacates open orders, leaves an unclear payment to the sweep and keeps the history anonymised', function()
        local a = prison(30)
        local f = fine(100)
        local paid = fine(50, 'k:paid')
        api:PayOrder(paid.orderId, { payerSrc = SUSPECT, key = 'pp' })
        local pend = fine(70, 'k:pend')
        DB.orders[pend.orderId].state = 'payment_pending'
        local entry = api:AddRecordEntry('SUSPECTCID', { kind = 'note', summary = 'kept' }, {}).entryId
        Mock.fireEvent('pfm-core:server:characterDeleted', SUSPECT, 'SUSPECTCID')
        assert_eq(DB.orders[a.orderId].state, 'active', 'a player cannot raise it')
        Mock.fireEvent('pfm-core:server:characterDeleted', nil, 'SUSPECTCID')
        assert_eq(DB.orders[a.orderId].state, 'vacated')
        assert_eq(DB.orders[f.orderId].state, 'waived')
        assert_eq(DB.orders[paid.orderId].state, 'paid')
        assert_eq(DB.orders[pend.orderId].state, 'payment_pending')
        local token = DB.orders[a.orderId].citizenid
        assert_true(token:sub(1, 5) == 'anon-', 'anonymised')
        for _, o in pairs(DB.orders) do assert_eq(o.citizenid, token, 'one token for all rows') end
        assert_eq(DB.records[entry].citizenid, token)
        assert_eq(DB.records[entry].summary, 'kept')
        assert_true(#where(DB.records, function(r) return r.kind == 'conviction' end) >= 1, 'court history kept')
        assert_false(select(1, api:IsIncarcerated('SUSPECTCID')))
        assert_eq(#where(DB.audit, function(x) return x.entity == 'character' end), 1)
        assert_eq(#emitted('releaseOrdered'), 0, 'nobody to release: the character is gone')
        assert_true(#emitted('orderChanged') >= 2)
    end)
end)

describe('reads', function()
    it('GetOrder / GetOrders are filtered for other resources; GetActiveIncarceration reports the chain', function()
        local a = prison(30)
        fine(100)
        as('some-script')
        local res = api:GetOrder(a.orderId)
        assert_true(res.ok)
        assert_eq(res.order.kind, 'prison')
        assert_eq(res.order.charges, nil, 'default fields only')
        assert_eq(res.order.createdBy, nil)
        local listed = api:GetOrders('SUSPECTCID', { kinds = { 'fine' } })
        assert_eq(#listed.list, 1)
        assert_eq(listed.list[1].kind, 'fine')
        assert_eq(api:GetOrders('SUSPECTCID', { limit = 500 }).error, 'bad_args')
        as('pf-policemdt-DEV')
        assert_eq(api:GetOrder(a.orderId).order.charges[1].code, 'P-101')
        local act = api:GetActiveIncarceration('SUSPECTCID')
        assert_eq(act.order.id, a.orderId)
        assert_eq(act.remainingSeconds, 1800)
        assert_eq(act.facility, 'bolingbroke')
        assert_eq(api:GetActiveIncarceration('NOBODY').remainingSeconds, 0)
    end)
end)

-- ── second round (adversarial check of 15B) ─────────────────────────────────────────────────────
local function invoicedFine(amount)
    local f = fine(amount or 5000)
    local res = api:PayOrder(f.orderId, { payerSrc = SUSPECT, account = 'bank', key = 'inv:' .. f.orderId })
    assert_eq(res.state, 'invoiced')
    return f.orderId, res.invoiceId
end
local function phoneSettles(orderId, invoiceId, outcome, amount)
    Mock.fireEvent('pfm-phone:server:invoiceSettled', nil, { id = invoiceId, ref = 'pf-justice:order:' .. orderId, amount = amount or 5000,
        citizenid = 'SUSPECTCID', society = 'police' }, outcome)
end
local function refundKey(id, n) return 'pf-justice:order:' .. id .. ':invoice_refund' .. (n and n > 1 and (':' .. n) or '') end

describe('invoiced fines are not closed while the phone invoice is live', function()
    it('a waiver is refused (conflict), recorded once, and applied when the invoice is declined', function()
        local id = invoicedFine()
        as('pfm-adminmenu')
        local w = api:SetOrderState(id, 'waived', { actor = { kind = 'admin', src = ADMIN }, reason = 'court mercy' })
        assert_eq(w.ok, false)
        assert_eq(w.error, 'conflict')
        assert_true(w.waiverPending)
        assert_eq(DB.orders[id].state, 'invoiced', 'the order still waits for its invoice')
        assert_eq(api:SetOrderState(id, 'waived', { actor = { kind = 'admin', src = ADMIN } }).error, 'conflict')
        assert_eq(#events(id, 'waive_pending'), 1, 'recorded once')
        -- no internal path closes it either
        local ok, err = J.Orders.MoveLocked(J.Orders.Row(id), 'waived', 'x', nil)
        assert_false(ok)
        assert_eq(err.error, 'conflict')
        phoneSettles(id, DB.orders[id].invoice_id, 'declined')
        assert_eq(DB.orders[id].state, 'waived', 'the recorded waiver applies')
        assert_eq(#events(id, 'waived'), 1)
    end)

    it('a waiver pending when the invoice is paid: the order is waived and the payment refunded under the stable key', function()
        local id, invoiceId = invoicedFine()
        as('pfm-adminmenu')
        api:SetOrderState(id, 'waived', { actor = { kind = 'admin', src = ADMIN } })
        FakeDB.bank_accounts.police.account_balance = 5000 -- the phone moved the money into society:police
        Mock.players[SUSPECT].PlayerData.money.bank = 0
        phoneSettles(id, invoiceId, 'paid')
        local o = DB.orders[id]
        assert_eq(o.state, 'waived')
        assert_eq(o.paid_amount, 0, 'nothing is recorded as paid on a waived order')
        assert_eq(o.refund_state, 'done')
        assert_eq(FakeDB.byKey[refundKey(id)].state, 'completed')
        assert_eq(money(SUSPECT).bank, 5000, 'refunded to the payer')
        assert_eq(FakeDB.bank_accounts.police.account_balance, 0)
        assert_eq(#events(id, 'invoice_paid_late'), 1)
        assert_eq(#events(id, 'refunded'), 1)
        assert_eq(#where(DB.records, function(r) return r.kind == 'conviction' end), 0, 'a waived fine is no conviction')
        local settled = emitted('paymentSettled')
        assert_eq(settled[#settled][2], 'refunded')
    end)

    it('a paid settlement for an order no longer invoiced is logged and refunded: numbered after a clear refusal, held while unclear', function()
        local id, invoiceId = invoicedFine()
        DB.orders[id].state = 'waived' -- closed some other way while the invoice stayed live
        Mock.players[SUSPECT].PlayerData.money.bank = 0
        phoneSettles(id, invoiceId, 'paid') -- society:police is empty: the refund is clearly refused
        assert_eq(#events(id, 'invoice_paid_late'), 1, 'never silently ignored')
        assert_eq(DB.orders[id].refund_state, 'due')
        assert_eq(FakeDB.byKey[refundKey(id)].state, 'failed')
        phoneSettles(id, invoiceId, 'paid') -- the same report again
        assert_eq(#events(id, 'invoice_paid_late'), 1, 'one log per invoice')
        assert_eq(FakeDB.byKey[refundKey(id, 2)], nil, 'no second attempt from a repeated report')
        -- the sweep retries under the next numbered key (a failed key stays failed)
        Mock.clock = Mock.clock + 300
        J.Orders.Sweep(Mock.clock)
        assert_eq(FakeDB.byKey[refundKey(id, 2)].state, 'failed')
        -- an unclear attempt is held: looked up, never paid again under a new key
        FakeDB.bank_accounts.police.account_balance = 5000
        local realTransfer = PFPayout.Transfer
        PFPayout.Transfer = function() return { ok = false, state = 'debited', unclear = true } end
        Mock.clock = Mock.clock + 300
        J.Orders.Sweep(Mock.clock)
        PFPayout.Transfer = realTransfer
        assert_eq(DB.orders[id].refund_state, 'unclear')
        assert_eq(DB.orders[id].refund_attempt, 3)
        local banking = Mock.exportsByResource['pfm-banking']
        local realGet = banking.GetTransaction
        banking.GetTransaction = function(_, k) if k == refundKey(id, 3) then return { state = 'debited' } end return realGet(_, k) end
        Mock.clock = Mock.clock + 300
        J.Orders.Sweep(Mock.clock)
        assert_eq(DB.orders[id].refund_state, 'unclear', 'waits while the ledger is unclear')
        assert_eq(FakeDB.byKey[refundKey(id, 4)], nil)
        banking.GetTransaction = realGet -- attempt 3 never reached the ledger: nothing moved, the next key pays
        Mock.clock = Mock.clock + 300
        J.Orders.Sweep(Mock.clock)
        Mock.clock = Mock.clock + 300
        local out = J.Orders.Sweep(Mock.clock)
        assert_eq(out.refunds, 1)
        assert_eq(DB.orders[id].refund_state, 'done')
        assert_eq(FakeDB.byKey[refundKey(id, 4)].state, 'completed')
        assert_eq(money(SUSPECT).bank, 5000, 'refunded once')
    end)

    it('a repeated paid report for an invoice that settled the order refunds nothing', function()
        local id, invoiceId = invoicedFine()
        phoneSettles(id, invoiceId, 'paid')
        assert_eq(DB.orders[id].state, 'paid')
        assert_eq(DB.orders[id].paid_amount, 5000)
        phoneSettles(id, invoiceId, 'paid')
        assert_eq(#events(id, 'invoice_paid_late'), 0)
        assert_eq(DB.orders[id].refund_state, nil)
    end)

    it('a deleted character: a gone invoice is waived; one still being paid keeps the waiver and settles paid', function()
        local gone, goneInvoice = invoicedFine(5000)
        Mock.clock = Mock.clock + 10
        local paying, payingInvoice = invoicedFine(6000)
        PhoneInvoices[payingInvoice] = true -- pfm-core keeps a 'paying' invoice of a deleted character
        assert_true(goneInvoice ~= payingInvoice)
        Mock.fireEvent('pfm-core:server:characterDeleted', nil, 'SUSPECTCID')
        assert_eq(DB.orders[gone].state, 'waived')
        assert_eq(DB.orders[paying].state, 'invoiced', 'still being paid on the phone')
        assert_eq(#events(paying, 'waive_pending'), 1)
        Mock.fireEvent('pfm-phone:server:invoiceSettled', nil, { id = payingInvoice, ref = 'pf-justice:order:' .. paying, amount = 6000,
            citizenid = 'SUSPECTCID', society = 'police' }, 'paid')
        assert_eq(DB.orders[paying].state, 'paid', 'paid before the deletion; nobody to refund')
        assert_eq(DB.orders[paying].refund_state, nil)
    end)
end)

describe('payments keep their amount and their state', function()
    it('modify is refused while a payment is pending or invoiced; paid_amount is what the ledger moved', function()
        local f = fine(400)
        FakeDB.failNext.creditSociety = true
        assert_eq(api:PayOrder(f.orderId, { payerSrc = SUSPECT, key = 'u1' }).error, 'payment_unclear')
        as('pfm-adminmenu')
        local a = api:AdjustOrder(f.orderId, { kind = 'modify', amount = 900 }, { actor = { kind = 'admin', src = ADMIN } })
        assert_eq(a.error, 'conflict')
        assert_eq(DB.orders[f.orderId].amount, 400)
        -- even if the row's amount changed some other way, the paid amount is the ledger's
        DB.orders[f.orderId].amount = 900
        Mock.clock = Mock.clock + 300
        PFLedger.Recover()
        J.Orders.Sweep(Mock.clock)
        assert_eq(DB.orders[f.orderId].state, 'paid')
        assert_eq(DB.orders[f.orderId].paid_amount, 400)
        as('pf-policemdt-DEV')
        local id = invoicedFine(5000)
        as('pfm-adminmenu')
        assert_eq(api:AdjustOrder(id, { kind = 'modify', amount = 100 }, { actor = { kind = 'admin', src = ADMIN } }).error, 'conflict')
    end)

    it('a clearly refused payment returns referred, overdue and upheld orders to that state', function()
        Mock.players[OTHER].PlayerData.money.bank = 10
        for _, st in ipairs({ 'referred', 'overdue' }) do
            local f = fine(5000, 'k:' .. st)
            DB.orders[f.orderId].state = st
            J.Rate.Forget('')
            local res = api:PayOrder(f.orderId, { payerSrc = OTHER, account = 'bank', key = 'p:' .. st })
            assert_eq(res.error, 'insufficient_funds')
            assert_eq(DB.orders[f.orderId].state, st, st .. ' is kept')
        end
        as('pfm-policejob')
        local c = api:IssueCitation({ cid = 'SUSPECTCID', amount = 5000, violation = 'Speeding', officerSrc = COP }, { key = 'cit:up' })
        DB.orders[c.orderId].state = 'upheld'
        as('pf-policemdt-DEV')
        J.Rate.Forget('')
        assert_eq(api:PayOrder(c.orderId, { payerSrc = OTHER, key = 'p:up' }).error, 'insufficient_funds')
        assert_eq(DB.orders[c.orderId].state, 'upheld')
        -- the sweep too: a refusal the ledger settles later returns to pay_from
        local f = fine(300, 'k:sweep')
        DB.orders[f.orderId].state = 'referred'
        J.Rate.Forget('')
        FakeDB.failNext.creditSociety = true
        Mock.players[OTHER].PlayerData.money.bank = 1000
        assert_eq(api:PayOrder(f.orderId, { payerSrc = OTHER, key = 'p:sw' }).error, 'payment_unclear')
        local banking = Mock.exportsByResource['pfm-banking']
        local realGet = banking.GetTransaction
        banking.GetTransaction = function() return { state = 'failed', error = 'insufficient_funds' } end
        Mock.clock = Mock.clock + 300
        J.Orders.Sweep(Mock.clock)
        banking.GetTransaction = realGet
        assert_eq(DB.orders[f.orderId].state, 'referred')
    end)

    it('the payment sweep reaches newer rows while older ones keep waiting', function()
        local ids = {}
        for i = 1, 56 do
            local f = fine(10 + i, 'k:many:' .. i)
            local o = DB.orders[f.orderId]
            o.state, o.pay_attempt, o.pay_key, o.updated_at = 'payment_pending', 1, 'pf-justice:order:' .. f.orderId .. ':pay:1', Mock.clock
            ids[i] = f.orderId
        end
        local newest = ids[56]
        local banking = Mock.exportsByResource['pfm-banking']
        local realGet = banking.GetTransaction
        -- the 55 older ones keep answering 'pending'; the newest never reached the ledger
        banking.GetTransaction = function(_, k)
            if k == 'pf-justice:order:' .. newest .. ':pay:1' then return nil end
            return { state = 'pending' }
        end
        for _ = 1, 3 do
            Mock.clock = Mock.clock + 300
            J.Orders.Sweep(Mock.clock)
        end
        banking.GetTransaction = realGet
        assert_eq(DB.orders[newest].state, 'issued', 'not starved by rows that wait')
        assert_eq(DB.orders[ids[1]].state, 'payment_pending')
    end)
end)

describe('keys and locks', function()
    it('a keyed credit whose event cannot be stored (database error) is not applied; the retry applies it once', function()
        local p = prison(60)
        as('pfm-prison')
        local entry
        for _, e in ipairs(FakeDB.extraPatterns) do if e[1] == Q.insertEvent then entry = e end end
        local real = entry[2]
        entry[2] = function(params)
            if params[7] == 'pfm-prison:credit:x:1' then entry[2] = real error('Lock wait timeout exceeded') end
            return real(params)
        end
        local a = api:AdjustOrder(p.orderId, { kind = 'credit', seconds = 600 }, { key = 'pfm-prison:credit:x:1' })
        assert_eq(a.error, 'db_unavailable')
        assert_eq(DB.orders[p.orderId].credit_seconds, 0, 'nothing applied without its key')
        local b = api:AdjustOrder(p.orderId, { kind = 'credit', seconds = 600 }, { key = 'pfm-prison:credit:x:1' })
        assert_true(b.ok)
        local c = api:AdjustOrder(p.orderId, { kind = 'credit', seconds = 600 }, { key = 'pfm-prison:credit:x:1' })
        assert_true(c.duplicate)
        assert_eq(DB.orders[p.orderId].credit_seconds, 600, 'credited once')
        -- suspend with a key: same rule
        entry[2] = function(params)
            if params[7] == 'esc:x' then entry[2] = real error('Lock wait timeout exceeded') end
            return real(params)
        end
        assert_eq(api:AdjustOrder(p.orderId, { kind = 'suspend' }, { key = 'esc:x' }).error, 'db_unavailable')
        assert_eq(DB.orders[p.orderId].state, 'active')
    end)

    it('a conviction skipped while the record lock is busy is queued and written later, also after a restart', function()
        local p = prison(30)
        J.Locks.Take('record:SUSPECTCID')
        as('pfm-prison')
        assert_true(api:SetOrderState(p.orderId, 'completed', {}).ok)
        J.Locks.Free('record:SUSPECTCID')
        local function convictions() return #where(DB.records, function(r) return r.kind == 'conviction' and r.ref_id == tostring(p.orderId) end) end
        assert_eq(convictions(), 0)
        assert_true(J.Records.queue[p.orderId])
        -- a restart loses the memory queue; the queued event brings it back
        J.Records.queue[p.orderId] = nil
        assert_true(J.Records.LoadQueue())
        assert_true(J.Records.queue[p.orderId])
        assert_eq(J.Records.RetryQueued(), 1)
        assert_eq(convictions(), 1)
        assert_eq(J.Records.queue[p.orderId], nil)
        J.Records.LoadQueue()
        assert_eq(J.Records.queue[p.orderId], nil, 'done entries are not reloaded')
        J.Records.queue[p.orderId] = true
        J.Records.RetryQueued()
        assert_eq(convictions(), 1, 'never twice')
    end)

    it('pfm-adminmenu creates orders only with an admin actor', function()
        as('pfm-adminmenu')
        local spec = { cid = 'SUSPECTCID', kind = 'fine', amount = 10, sourceRef = { type = 'admin', id = 'a1' } }
        assert_eq(api:CreateOrder(spec, { key = 'adm:f1' }).error, 'no_permission')
        assert_eq(api:CreateOrder(spec, { key = 'adm:f1', actor = { src = COP } }).error, 'no_permission')
        assert_true(api:CreateOrder(spec, { key = 'adm:f1', actor = { kind = 'admin', src = ADMIN } }).ok)
    end)

    it('two IssueCitation calls racing with one key: the second is a duplicate', function()
        as('pfm-policejob')
        local entry
        for _, e in ipairs(FakeDB.extraPatterns) do if e[1] == Q.insertCitation then entry = e end end
        local real = entry[2]
        -- the racing call stores its row between our check and our insert
        entry[2] = function(params) entry[2] = real real(params) error('Duplicate entry for key uq_cit_uid') end
        local res = api:IssueCitation({ cid = 'SUSPECTCID', amount = 50, violation = 'Speeding', officerSrc = COP }, { key = 'cit:race' })
        assert_true(res.ok)
        assert_true(res.duplicate)
        assert_eq(DB.n.c, 1)
        assert_eq(res.citationId, 1)
    end)
end)

describe('deleted characters (second round)', function()
    it('a contested citation is dismissed; ids in events, payer details, audit rows, created_by and expunged_by are anonymised', function()
        as('pfm-policejob')
        local c = api:IssueCitation({ cid = 'SUSPECTCID', amount = 100, violation = 'Speeding', officerSrc = COP }, { key = 'cit:d1' })
        as('pf-policemdt-DEV')
        assert_true(api:ContestCitation(c.orderId, { actor = { src = SUSPECT } }).ok)
        local f = fine(50, 'k:payer')
        assert_true(api:PayOrder(f.orderId, { payerSrc = SUSPECT, key = 'pp:1' }).ok)
        -- the suspect pays someone else's fine too (payer only)
        local other = api:CreateOrder({ cid = 'OTHERCID', kind = 'fine', amount = 20 }, { key = 'k:other', actor = { src = COP } })
        J.Rate.Forget('')
        assert_true(api:PayOrder(other.orderId, { payerSrc = SUSPECT, key = 'pp:2' }).ok)
        Mock.fireEvent('pfm-core:server:characterDeleted', nil, 'SUSPECTCID')
        assert_eq(DB.orders[c.orderId].state, 'dismissed', 'closed, not left open under the token')
        for _, e in pairs(DB.events) do
            assert_true(e.actor_cid ~= 'SUSPECTCID', 'event actor')
            assert_true(not (e.detail or ''):find('SUSPECTCID', 1, true), 'event detail ' .. tostring(e.detail))
        end
        assert_eq(DB.orders[other.orderId].citizenid, 'OTHERCID', 'other people keep their orders')
        -- an officer and a judge deleted: created_by, citation officer, audit actor and expunged_by
        local e1 = api:AddRecordEntry('OTHERCID', { kind = 'note', summary = 'n' }, {}).entryId
        as('pf-government')
        assert_true(api:Expunge('OTHERCID', { e1 }, { actor = { src = JUDGE } }).ok)
        Mock.fireEvent('pfm-core:server:characterDeleted', nil, 'COPCID')
        Mock.fireEvent('pfm-core:server:characterDeleted', nil, 'JUDGECID')
        for _, o in pairs(DB.orders) do assert_true(o.created_by ~= 'COPCID', 'created_by') end
        for _, ci in pairs(DB.citations) do assert_true(ci.officer_cid ~= 'COPCID', 'officer') end
        for _, a in pairs(DB.audit) do
            assert_true(a.actor_cid ~= 'JUDGECID' and a.actor_cid ~= 'SUSPECTCID', 'audit actor')
            assert_true(a.entity_id ~= 'SUSPECTCID', 'audit entity')
        end
        assert_true(DB.records[e1].expunged_by ~= 'JUDGECID', 'expunged_by')
        assert_true(DB.records[e1].expunged_by:sub(1, 5) == 'anon-')
    end)
end)
