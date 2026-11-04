-- pf-justice sentence clock (batch 15B, acceptance 3; owner decision D2): the spec drives
-- PFJustice.Clock.Tick. Online-only, hybrid and realtime policies; time counts only inside the
-- facility (presence provider), with the fallback radius when the provider's resource is not running
-- or its export fails; a tick never counts more than MaxGapSeconds; credits and forfeits move the
-- release; concurrent and consecutive orders; an escaped (suspended) order does not count; hospital
-- custody counts; a completion while offline finishes at the next load; releaseOrdered fires exactly
-- once; a restart resumes from the stored absolute values.
--
-- The pf-justice statements run on the same in-memory table store as b15_justice_orders_spec.lua
-- (matched by their exact text from PFJustice.SQL); the real SQL is covered by the real-DB spec.
load_resource('tests/lua/ledger_env.lua')
QBCore = QBCoreMock

-- pfm-prison IsInside (16C) stand-in: inside[src] = true/false, or an error
local inside, prisonStarted, prisonThrows = {}, true, false
Mock.exportsByResource['pfm-prison'] = {
    IsInside = function(_, src)
        if prisonThrows then error('IsInside failed') end
        return inside[src] == true
    end,
}
local inCare = {}
Mock.exportsByResource['pf-ambulancejob'] = { IsInCare = function(_, src) return inCare[src] == true end }
local realState = GetResourceState
function GetResourceState(res)
    if res == 'pfm-prison' and not prisonStarted then return 'stopped' end
    return realState(res)
end
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end
Mock.exportsByResource['pfm-core'].GetCoreObject = function(_, filters) return Mock.coreObject(filters) end

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
local C = J.Clock

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
H[Q.settleQueued] = function()
    local out = {}
    for _, e in ipairs(list(DB.events)) do if e.action == 'settle_queued' then out[#out + 1] = copy(e) end end
    return out
end
H[Q.settleDone] = function(p)
    for _, e in pairs(DB.events) do if e.idem_key == p[1] then e.action = 'settle_done' return 1 end end
    return 0
end
H[Q.deleteQueued] = function()
    local out = {}
    for _, a in ipairs(list(DB.audit)) do if a.entity == 'character' and a.action == 'delete_queued' then out[#out + 1] = { entity_id = a.entity_id } end end
    return out
end
H[Q.deleteDone] = function(p)
    local n = 0
    for _, a in pairs(DB.audit) do
        if a.entity == 'character' and a.entity_id == p[2] and a.action == 'delete_queued' then a.action, a.entity_id = 'delete_done', p[1] n = n + 1 end
    end
    return n
end
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
local COP, INMATE = 1, 2
local api = exports['pf-justice']
local CENTER = Config.Facilities.bolingbroke.fallback.center
local function at(dx) return vector3(CENTER.x + dx, CENTER.y, CENTER.z) end
local function emitted(name)
    local out = {}
    for _, e in ipairs(Mock.serverEvents) do if e.name == 'pf-justice:server:' .. name then out[#out + 1] = e.args end end
    return out
end
local function tick(n, step)
    for _ = 1, n do
        Mock.clock = Mock.clock + (step or 15)
        C.Tick(Mock.clock)
    end
end
local function order(id) return DB.orders[id] end
local function jail(minutes, extra, key)
    local spec = { cid = 'INMATECID', kind = 'prison', minutes = minutes, facility = 'bolingbroke' }
    for k, v in pairs(extra or {}) do spec[k] = v end
    Mock.invokingResource = (spec.clock and 'pfm-adminmenu') or 'pf-policemdt-DEV'
    local actor = spec.clock and { kind = 'admin', src = COP } or { src = COP }
    local res = api:CreateOrder(spec, { key = key or ('k:' .. minutes .. ':' .. tostring(spec.clock)), actor = actor })
    assert_true(res.ok, 'order: ' .. tostring(res.error))
    return res.orderId
end
local function goOffline()
    Mock.fireEvent('playerDropped', INMATE)
    Mock.players[INMATE] = nil
end
local function comeBack()
    local p = Mock.newPlayer(INMATE, 'INMATECID')
    Mock.fireEvent('QBCore:Server:PlayerLoaded', nil, p)
end

BeforeEach = function()
    LedgerEnv.reset()
    resetDB()
    Mock.reset()
    Mock.players = {}
    Mock.clock = 1700000000
    inside, prisonStarted, prisonThrows, inCare = {}, true, false, {}
    for k in pairs(J.Orders.activeIndex) do J.Orders.activeIndex[k] = nil end
    for k in pairs(C.inmates) do C.inmates[k] = nil end
    for k in pairs(C.srcOf) do C.srcOf[k] = nil end
    for k in pairs(C.pendingLoad) do C.pendingLoad[k] = nil end
    for k in pairs(C.hospital) do C.hospital[k] = nil end
    PFJustice.Custody = nil
    local cop = Mock.newPlayer(COP, 'COPCID')
    cop.PlayerData.job = { name = 'police', type = 'leo', onduty = true }
    Mock.newPlayer(INMATE, 'INMATECID')
    Mock.aces = { [COP] = { command = true } }
    Mock.coords = { [INMATE] = at(0) }
    assert_true(J.Boot())
end

describe('online clock inside the facility', function()
    it('counts only while the provider says inside, and stores absolute values', function()
        local id = jail(2)
        assert_true(C.inmates[INMATE] ~= nil, 'tracked at creation')
        inside[INMATE] = true
        tick(2)
        assert_eq(order(id).served_seconds, 30)
        assert_eq(order(id).last_tick_at, Mock.clock)
        inside[INMATE] = false
        tick(4)
        assert_eq(order(id).served_seconds, 30, 'outside: nothing counts')
        assert_eq(api:GetJailMinutes(INMATE), 2)
        inside[INMATE] = true
        tick(1)
        assert_eq(order(id).served_seconds, 45)
        assert_eq(api:GetJailMinutes(INMATE), 2, 'ceil of 75 s')
    end)

    it('the provider beats the radius: inside the radius but outside the walls does not count', function()
        local id = jail(5)
        Mock.coords[INMATE] = at(10)
        inside[INMATE] = false
        tick(3)
        assert_eq(order(id).served_seconds, 0)
    end)

    it('provider resource not running: the fallback radius decides, so the clock never stops', function()
        local id = jail(5)
        prisonStarted = false
        Mock.coords[INMATE] = at(50)
        tick(2)
        assert_eq(order(id).served_seconds, 30)
        Mock.coords[INMATE] = at(250)
        tick(2)
        assert_eq(order(id).served_seconds, 30, 'outside the radius')
        local ok, how = C.IsInside(INMATE, order(id))
        assert_false(ok)
        assert_eq(how, 'outside')
        Mock.coords[INMATE] = at(0)
        assert_eq(select(2, C.IsInside(INMATE, order(id))), 'fallback')
    end)

    it('provider export failing also falls back to the radius', function()
        local id = jail(5)
        prisonThrows = true
        tick(1)
        assert_eq(order(id).served_seconds, 15)
        assert_eq(select(2, C.IsInside(INMATE, order(id))), 'fallback')
    end)

    it('a holding facility asks the custody module of this resource', function()
        local holding = {}
        PFJustice.Custody = { IsInHoldingCell = function(src) return holding[src] == true end }
        Mock.invokingResource = 'pf-policemdt-DEV'
        local id = api:CreateOrder({ cid = 'INMATECID', kind = 'jail', minutes = 10, facility = 'mrpd_holding' }, { key = 'h:1', actor = { src = COP } }).orderId
        tick(1)
        assert_eq(order(id).served_seconds, 0)
        holding[INMATE] = true
        tick(1)
        assert_eq(order(id).served_seconds, 15)
    end)

    it('a server hitch never counts more than MaxGapSeconds', function()
        local id = jail(30)
        inside[INMATE] = true
        tick(1, 600)
        assert_eq(order(id).served_seconds, Config.Clock.MaxGapSeconds)
    end)

    it('hospital custody counts as inside; a plain hospital visit does not', function()
        local id = jail(30)
        inside[INMATE] = false
        inCare[INMATE] = true
        tick(1)
        assert_eq(order(id).served_seconds, 0, 'in care without hospital custody')
        PFJustice.Custody = { bySrc = { [INMATE] = { state = 'hospital', citizenid = 'INMATECID' } } }
        tick(1)
        assert_eq(order(id).served_seconds, 15)
        assert_eq(select(2, C.IsInside(INMATE, order(id))), 'hospital')
        inCare[INMATE] = false
        tick(1)
        assert_eq(order(id).served_seconds, 15)
    end)

    it('a suspended (escaped) order does not count; it resumes from where it stopped', function()
        local id = jail(30)
        inside[INMATE] = true
        tick(1)
        Mock.invokingResource = 'pfm-prison'
        api:AdjustOrder(id, { kind = 'suspend', reason = 'escape' }, { key = 'esc' })
        tick(4)
        assert_eq(order(id).served_seconds, 15)
        api:AdjustOrder(id, { kind = 'resume' }, { key = 'back' })
        tick(1)
        assert_eq(order(id).served_seconds, 30)
    end)

    it('pushes the remaining minutes to the inmate on each whole-minute change only', function()
        jail(3)
        inside[INMATE] = true
        Mock.reset()
        tick(4) -- 60 s
        local pushes = Mock.clientEventsNamed('pf-justice:client:Sentence')
        assert_eq(#pushes, 1)
        assert_eq(pushes[1].target, INMATE)
        assert_eq(pushes[1].args[1].minutes, 2)
        assert_eq(pushes[1].args[1].remainingSeconds, 120)
    end)
end)

describe('completion and release', function()
    it('completes when served and fires releaseOrdered exactly once', function()
        local id = jail(1)
        inside[INMATE] = true
        tick(3)
        assert_eq(order(id).state, 'active')
        tick(1)
        assert_eq(order(id).state, 'completed')
        assert_eq(order(id).served_seconds, 60)
        local rel = emitted('releaseOrdered')
        assert_eq(#rel, 1)
        assert_eq(rel[1][1], 'INMATECID')
        assert_eq(rel[1][2], id)
        tick(5)
        assert_eq(#emitted('releaseOrdered'), 1, 'never again')
        assert_eq(C.inmates[INMATE], nil, 'no longer tracked')
        assert_false(select(1, api:IsIncarcerated(INMATE)))
        local last = Mock.clientEventsNamed('pf-justice:client:Sentence')
        assert_eq(last[#last].args[1], nil, 'the client is told the sentence ended')
    end)

    it('credits bring the release forward; forfeits push it back', function()
        local id = jail(10)
        inside[INMATE] = true
        Mock.invokingResource = 'pfm-prison'
        api:AdjustOrder(id, { kind = 'credit', seconds = 240 }, { key = 'c1' })
        assert_eq(api:GetJailMinutes(INMATE), 6)
        api:AdjustOrder(id, { kind = 'forfeit', seconds = 60 }, { key = 'f1' })
        assert_eq(api:GetJailMinutes(INMATE), 7)
        tick(27) -- 405 s
        assert_eq(order(id).state, 'active')
        tick(1) -- 420 s served + 240 credit - 60 forfeit = 600
        assert_eq(order(id).state, 'completed')
        assert_eq(#emitted('releaseOrdered'), 1)
    end)

    it('a concurrent order counts beside the active one and takes over; a consecutive one starts after', function()
        local a = jail(1)
        local b = jail(2, nil, 'k:b')
        local c = jail(1, { merge = 'consecutive' }, 'k:c')
        inside[INMATE] = true
        tick(4) -- 60 s
        assert_eq(order(a).state, 'completed')
        assert_eq(order(b).state, 'active')
        assert_eq(order(b).served_seconds, 60, 'served beside the first')
        assert_eq(order(c).state, 'pending')
        assert_eq(order(c).served_seconds, 0)
        assert_eq(#emitted('releaseOrdered'), 0)
        tick(4)
        assert_eq(order(b).state, 'completed')
        assert_eq(order(c).state, 'active')
        tick(3)
        assert_eq(order(c).state, 'active')
        tick(1)
        assert_eq(order(c).state, 'completed')
        assert_eq(#emitted('releaseOrdered'), 1)
    end)
end)

describe('offline time per policy', function()
    it('online: nothing counts while away', function()
        local id = jail(10)
        inside[INMATE] = true
        tick(2)
        goOffline()
        Mock.clock = Mock.clock + 3600
        C.Tick(Mock.clock)
        assert_eq(order(id).served_seconds, 30)
        comeBack()
        assert_eq(order(id).served_seconds, 30)
        assert_true(C.inmates[INMATE] ~= nil, 'tracked again')
        tick(1)
        assert_eq(order(id).served_seconds, 45, 'the offline hour is not one big tick')
    end)

    it('hybrid: OfflineRate of the offline wall time counts at the next load', function()
        local id = jail(60, { clock = 'hybrid' })
        goOffline()
        Mock.clock = Mock.clock + 400
        comeBack()
        assert_eq(order(id).served_seconds, 100)
    end)

    it('realtime: all of it counts, online outside too; a completion while away finishes at the next load', function()
        local id = jail(30, { clock = 'realtime' })
        inside[INMATE] = false
        tick(2)
        assert_eq(order(id).served_seconds, 30, 'realtime counts outside')
        goOffline()
        Mock.clock = Mock.clock + 7200
        C.Tick(Mock.clock)
        J.Orders.Sweep(Mock.clock)
        assert_eq(order(id).state, 'active', 'not completed while offline')
        assert_eq(#emitted('releaseOrdered'), 0)
        comeBack()
        assert_eq(order(id).state, 'completed')
        local rel = emitted('releaseOrdered')
        assert_eq(#rel, 1, 'released at the load, with the player online')
        comeBack()
        assert_eq(#emitted('releaseOrdered'), 1, 'once')
    end)

    it('an admin completion while offline is final at once (release is for pfm-prison to finish at load)', function()
        local id = jail(30)
        goOffline()
        Mock.invokingResource = 'pfm-adminmenu'
        assert_true(api:SetOrderState(id, 'completed', { actor = { kind = 'admin', src = COP } }).ok)
        assert_eq(#emitted('releaseOrdered'), 1)
        comeBack()
        assert_eq(#emitted('releaseOrdered'), 1)
    end)
end)

describe('restart and busy loads', function()
    it('a restart resumes from the stored served time without counting the downtime', function()
        local id = jail(10)
        inside[INMATE] = true
        tick(4)
        -- the resource stops: memory is gone; the row keeps served_seconds
        for k in pairs(C.inmates) do C.inmates[k] = nil end
        for k in pairs(C.srcOf) do C.srcOf[k] = nil end
        for k in pairs(J.Orders.activeIndex) do J.Orders.activeIndex[k] = nil end
        Mock.clock = Mock.clock + 900
        assert_true(J.Boot())
        assert_true(select(1, api:IsIncarcerated('INMATECID')), 'index rebuilt')
        assert_true(C.inmates[INMATE] ~= nil, 'online players loaded')
        assert_eq(order(id).served_seconds, 60)
        tick(1)
        assert_eq(order(id).served_seconds, 75)
    end)

    it('a load that finds the citizen busy is retried by the next tick', function()
        local id = jail(10)
        for k in pairs(C.inmates) do C.inmates[k] = nil end
        for k in pairs(C.srcOf) do C.srcOf[k] = nil end
        J.Locks.Take('cid:INMATECID')
        assert_eq(C.Load(INMATE), 'busy')
        J.Locks.Free('cid:INMATECID')
        inside[INMATE] = true
        C.Tick(Mock.clock)
        assert_true(C.inmates[INMATE] ~= nil)
        tick(1)
        assert_eq(order(id).served_seconds, 15)
    end)

    it('a tick skips a citizen another action holds and counts the time on the next tick', function()
        local id = jail(10)
        inside[INMATE] = true
        J.Locks.Take('cid:INMATECID')
        tick(1)
        J.Locks.Free('cid:INMATECID')
        assert_eq(order(id).served_seconds, 0)
        tick(1)
        assert_eq(order(id).served_seconds, 30)
    end)
end)

describe('orders imported by the legacy import (15C)', function()
    it('are indexed and counted once the import reports them', function()
        H[Q.insertOrder]({ 'INMATECID', 'jail', 'active', 'bolingbroke', 'online', 600, nil, nil, nil, nil, nil, nil, 'mdt_sentence', '5',
            nil, nil, Mock.clock, nil, nil, nil, nil, 'mdt_jail:5', 'legacy', Mock.clock, Mock.clock })
        local id = DB.n.o
        assert_false(select(1, api:IsIncarcerated('INMATECID')), 'written behind the clock')
        Mock.fireEvent('pf-justice:server:legacyImported', INMATE, 'INMATECID', { id })
        assert_false(select(1, api:IsIncarcerated('INMATECID')), 'a client cannot raise it')
        Mock.fireEvent('pf-justice:server:legacyImported', nil, 'INMATECID', { id })
        assert_true(select(1, api:IsIncarcerated('INMATECID')))
        inside[INMATE] = true
        tick(1)
        assert_eq(order(id).served_seconds, 15)
    end)
end)

describe('hybrid clock across a restart (second round)', function()
    local function restart()
        for k in pairs(C.inmates) do C.inmates[k] = nil end
        for k in pairs(C.srcOf) do C.srcOf[k] = nil end
        Mock.clock = Mock.clock + 5
        J.Boot()
    end

    it('an hour online outside, then a restart: the hour is not counted as offline time', function()
        prisonStarted = false
        local id = jail(600, { clock = 'hybrid' })
        Mock.coords[INMATE] = at(5000) -- far outside the fallback radius
        tick(240)
        assert_eq(order(id).served_seconds, 0)
        assert_eq(order(id).last_tick_at, Mock.clock, 'saved on every tick')
        restart()
        assert_true(order(id).served_seconds <= 2, 'only the restart gap at OfflineRate, got ' .. order(id).served_seconds)
    end)

    it('an escaped (suspended) chain gains no offline time at the next load', function()
        local a = jail(60, { clock = 'hybrid' }, 'k:a')
        local b = jail(120, { clock = 'hybrid' }, 'k:b') -- concurrent, running beside a
        Mock.invokingResource = 'pfm-prison'
        assert_true(api:AdjustOrder(a, { kind = 'suspend' }, { key = 'esc:1' }).ok)
        goOffline()
        Mock.clock = Mock.clock + 4 * 3600
        comeBack()
        assert_eq(order(b).served_seconds, 0, 'nothing counts while the chain is suspended')
        assert_eq(order(b).last_tick_at, Mock.clock)
    end)
end)
