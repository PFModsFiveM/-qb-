-- pf-justice bail on the real pfm-banking ledger (unit 15C acceptance 5):
--   * the payer must be within PayerDistance of the offering officer, at a bail desk, or the
--     prisoner (server positions); the money moves once, keyed pf-justice:bail:<id>:<attempt>, from
--     the payer's bank to society:doj; posting releases the custody ('bailed') or vacates the order;
--   * a clear refusal goes back to 'offered' and the next attempt uses a new numbered key; an
--     unclear result is held as payment_pending and settled by the sweep from the ledger record,
--     never charged again under a new key;
--   * offers expire, can be declined by the payer or the prisoner, can name the payer;
--   * exoneration refunds the payer once (pf-justice:bail:<id>:refund, numbered after a clear
--     failure); forfeiture keeps the money; only a court (or a system caller) decides either;
--   * a remanded citizen gets bail from a court only; MDT bail imported in batch 15 stays the MDT's.
load_resource('tests/lua/ledger_env.lua')
local ROOT = __JU_ROOT or '[pfscripts]/pf-justice/'
QBCore = QBCoreMock
Mock.exportsByResource['pfm-policejob'] = { IsCuffed = function() return false end, SetCuffed = function() return true end }
Mock.exportsByResource['pfm-inventory'] = {
    CreateInventory = function() return true end, GetInventory = function() return { items = {} } end, SaveStash = function() end,
}
LedgerEnv.load('pf-justice', { ROOT .. 'config.lua', ROOT .. 'shared/states.lua', ROOT .. 'server/main.lua',
    ROOT .. 'server/custody.lua', ROOT .. 'server/property.lua', ROOT .. 'server/bail.lua' })
Mock.exportsByResource['pf-justice'] = {}
for k, v in pairs(Mock.exportsByResource['__self']) do Mock.exportsByResource['pf-justice'][k] = v end
local J = PFJustice
local K = J.CustodyKit
local B = J.Bail

-- 15B by contract
local orders, setStates = {}, {}
J.API = { GetOrder = function(id) return orders[id] and { ok = true, order = orders[id] } or { ok = false, error = 'not_found' } end }
J.Orders = {
    SetState = function(id, to, opts)
        setStates[#setStates + 1] = { id = id, to = to, reason = opts and opts.reason }
        if orders[id] then orders[id].state = to end
        return { ok = true }
    end,
    Event = function() return true end,
}
J.Clock = { SetHospitalCustody = function() end }

-- in-memory custody / property / bail stores with the SQL semantics (compare-and-set)
local DB
local function copy(r) local o = {} for k, v in pairs(r) do o[k] = v end return o end
local function apply(r, fields) for k, v in pairs(fields) do if v == K.NULL then r[k] = nil else r[k] = v end end end
local function inSet(v, list) for _, x in ipairs(list) do if x == v then return true end end return false end
local function nextId() DB.n = DB.n + 1 return DB.n end
J.Custody.Store = {
    openOf = function(cid) for _, r in pairs(DB.custody) do if r.citizenid == cid and not r.closed_at then return copy(r) end end end,
    get = function(id) return DB.custody[id] and copy(DB.custody[id]) end,
    byKey = function() end, latestOf = function() end,
    insert = function(row) local r = copy(row) r.id = nextId() DB.custody[r.id] = r return r.id end,
    cas = function(id, from, fields) local r = DB.custody[id] if not r or r.state ~= from or r.closed_at then return false end apply(r, fields) return true end,
    log = function(cid, kind, data, actor, at) DB.log[#DB.log + 1] = { id = #DB.log + 1, custody_id = cid, kind = kind, data = data, at = at } return #DB.log end,
    lastLogOf = function(cid, kind) for i = #DB.log, 1, -1 do local l = DB.log[i] if l.custody_id == cid and l.kind == kind then return l end end end,
    listLog = function() return {} end, dueHolds = function() return {} end, openAllOf = function() return {} end,
}
J.Property.Store = {
    forField = function() return {} end, forCustody = function() return {} end, forOrder = function() return {} end, forCitizen = function() return {} end,
    linkOrder = function() end,
}
local OPEN = { 'offered', 'accepted', 'payment_pending', 'posted' }
J.Bail.Store = {
    insert = function(row) local r = copy(row) r.id = nextId() r.state = 'offered' r.pay_attempt = 0 DB.bail[r.id] = r return r.id end,
    get = function(id) return DB.bail[id] and copy(DB.bail[id]) end,
    openFor = function(field, id) for _, b in pairs(DB.bail) do if b[field] == id and inSet(b.state, OPEN) then return copy(b) end end end,
    latestOf = function(cid) local best for _, b in pairs(DB.bail) do if b.citizenid == cid and (not best or b.id > best.id) then best = b end end return best and copy(best) end,
    orderVacateReason = function(orderId)
        for i = #setStates, 1, -1 do if setStates[i].id == orderId and setStates[i].to == 'vacated' then return setStates[i].reason end end
    end,
    due = function(now, afterId)
        local out = {}
        for _, b in pairs(DB.bail) do
            local refOpen = (b.custody_id and DB.custody[b.custody_id] and not DB.custody[b.custody_id].closed_at)
                or (b.order_id and orders[b.order_id] and (orders[b.order_id].state == 'active' or orders[b.order_id].state == 'pending'))
            if b.state == 'accepted' or b.state == 'payment_pending' or (b.state == 'exonerated' and b.pay_key)
                or (b.state == 'offered' and b.expires_at < now) or (b.state == 'posted' and refOpen) then
                if b.id <= (afterId or 0) then goto skip end
                out[#out + 1] = copy(b)
            end
            ::skip::
        end
        table.sort(out, function(a, b) return a.id < b.id end)
        while #out > 50 do table.remove(out) end
        return out
    end,
    openOfCitizen = function() return {} end,
    cas = function(id, from, fields) local b = DB.bail[id] if not b or b.state ~= from then return false end apply(b, fields) return true end,
}

local COP, PRISONER, PAYER, JUDGE = 1, 2, 3, 4
local STATION = vector3(441.0, -981.0, 30.7)
local STREET = vector3(200.0, 200.0, 30.0)
local DESK = Config.Bail.Desks[1].coords

local function bank(src) return Mock.players[src].PlayerData.money.bank end
local function doj() local a = FakeDB.bank_accounts['doj'] return a and a.account_balance or 0 end
local function paid(key) local row = FakeDB.byKey[key] return row and row.state == 'completed' end
local function custodyFor(state)
    local id = nextId()
    DB.custody[id] = { id = id, citizenid = 'PRI2', state = state or 'held', facility = 'mrpd_holding', opened_at = Mock.clock, updated_at = Mock.clock }
    return id
end
local function offer(spec, actorSrc)
    local id = custodyFor()
    return B.Offer({ custodyId = id }, spec or { amount = 400 }, { actor = { src = actorSrc or COP } }), id
end

BeforeEach = function()
    LedgerEnv.reset()
    Mock.reset()
    Mock.players = {}
    Mock.invokingResource = nil
    Mock.clock = Mock.clock + 1000
    Mock.clock = Mock.clock + 600
    DB = { custody = {}, log = {}, bail = {}, n = 0 }
    orders, setStates = {}, {}
    Config.Compat = nil
    local c = Mock.newPlayer(COP, 'COP1')
    c.PlayerData.job = { name = 'police', type = 'leo', grade = { level = 1 }, onduty = true }
    local p = Mock.newPlayer(PRISONER, 'PRI2')
    p.PlayerData.money.bank = 1000
    local y = Mock.newPlayer(PAYER, 'PAY3')
    y.PlayerData.money.bank = 1000
    local j = Mock.newPlayer(JUDGE, 'JUD4')
    j.PlayerData.job = { name = 'judge', grade = { level = 1 }, onduty = true }
    Mock.coords[COP], Mock.coords[PRISONER], Mock.coords[PAYER], Mock.coords[JUDGE] = STATION, STATION, STATION, STREET
end

describe('posting bail', function()
    it('a payer next to the officer pays once from the bank into society:doj; the custody is released', function()
        local o, custodyId = offer()
        assert_eq(o.ok, true, tostring(o.error))
        local res = B.Accept(o.bailId, PAYER, {})
        assert_eq(res.ok, true, tostring(res.error) .. ' ' .. tostring(res.message))
        assert_eq(res.state, 'posted')
        assert_eq(bank(PAYER), 600)
        assert_eq(doj(), 400)
        assert_true(paid(('pf-justice:bail:%d:1'):format(o.bailId)), 'keyed ledger row')
        assert_eq(DB.custody[custodyId].state, 'released')
        assert_eq(DB.custody[custodyId].release_reason, 'bailed')
        Mock.clock = Mock.clock + 6
        assert_eq(B.Accept(o.bailId, PAYER, {}).duplicate, true)
        assert_eq(bank(PAYER), 600, 'never twice')
    end)

    it('refuses a payer away from the officer and every desk; a desk or the prisoner may pay', function()
        local o = offer()
        Mock.coords[PAYER] = STREET
        local res = B.Accept(o.bailId, PAYER, {})
        assert_eq(res.error, 'too_far')
        assert_eq(bank(PAYER), 1000)
        assert_eq(DB.bail[o.bailId].state, 'offered')
        Mock.clock = Mock.clock + 6
        Mock.coords[PAYER] = DESK
        assert_eq(B.Accept(o.bailId, PAYER, {}).ok, true)
        -- the prisoner pays their own bail from the cell
        local o2 = offer()
        Mock.coords[PRISONER] = STREET
        assert_eq(B.Accept(o2.bailId, PRISONER, {}).ok, true)
        assert_eq(bank(PRISONER), 600)
    end)

    it('a clear refusal goes back to offered; the next attempt uses a new numbered key', function()
        local o = offer({ amount = 1500 })
        local res = B.Accept(o.bailId, PAYER, {})
        assert_eq(res.ok, false)
        assert_eq(res.error, 'insufficient_funds')
        assert_eq(DB.bail[o.bailId].state, 'offered')
        assert_eq(FakeDB.byKey[('pf-justice:bail:%d:1'):format(o.bailId)].state, 'failed')
        Mock.players[PAYER].PlayerData.money.bank = 2000
        Mock.clock = Mock.clock + 6
        local again = B.Accept(o.bailId, PAYER, {})
        assert_eq(again.ok, true, tostring(again.error))
        assert_true(paid(('pf-justice:bail:%d:2'):format(o.bailId)), 'attempt 2 key')
        assert_eq(bank(PAYER), 500)
    end)

    it('an unclear payment waits as payment_pending and settles from the ledger record, once', function()
        local o, custodyId = offer()
        local real = Mock.exportsByResource['pfm-banking'].Transfer
        Mock.exportsByResource['pfm-banking'].Transfer = function(_, opts) real(opts) error('connection lost') end
        local res = B.Accept(o.bailId, PAYER, {})
        Mock.exportsByResource['pfm-banking'].Transfer = real
        assert_eq(res.ok, false)
        assert_eq(res.error, 'payment_unclear')
        assert_eq(res.state, 'payment_pending')
        assert_eq(DB.bail[o.bailId].state, 'payment_pending')
        assert_eq(DB.custody[custodyId].closed_at, nil, 'not released yet')
        -- a second accept cannot charge again under a new key
        Mock.clock = Mock.clock + 6
        assert_eq(B.Accept(o.bailId, PAYER, {}).error, 'invalid_state')
        B.Tick(Mock.clock)
        assert_eq(DB.bail[o.bailId].state, 'payment_pending', 'held for PaymentHoldSeconds')
        B.Tick(Mock.clock + Config.Bail.PaymentHoldSeconds + 1)
        assert_eq(DB.bail[o.bailId].state, 'posted')
        assert_eq(DB.custody[custodyId].state, 'released')
        assert_eq(bank(PAYER), 600, 'charged exactly once')
    end)

    it('an unclear call that never reached the ledger goes back to offered without a charge', function()
        local o = offer()
        local real = Mock.exportsByResource['pfm-banking'].Transfer
        Mock.exportsByResource['pfm-banking'].Transfer = function() error('timeout before sending') end
        B.Accept(o.bailId, PAYER, {})
        Mock.exportsByResource['pfm-banking'].Transfer = real
        assert_eq(DB.bail[o.bailId].state, 'payment_pending')
        B.Tick(Mock.clock)
        B.Tick(Mock.clock + Config.Bail.PaymentHoldSeconds + 1)
        assert_eq(DB.bail[o.bailId].state, 'offered')
        assert_eq(bank(PAYER), 1000)
        Mock.clock = Mock.clock + 6
        assert_eq(B.Accept(o.bailId, PAYER, {}).ok, true)
        assert_true(paid(('pf-justice:bail:%d:2'):format(o.bailId)), 'the next attempt is a new key')
    end)

    it('one payment try per payer every 5 seconds', function()
        local o = offer({ amount = 5000 })
        B.Accept(o.bailId, PAYER, {})
        assert_eq(B.Accept(o.bailId, PAYER, {}).error, 'rate_limited')
    end)

    it('bail on an order vacates that order when posted', function()
        orders[71] = { id = 71, cid = 'PRI2', kind = 'jail', state = 'active' }
        local o = B.Offer({ orderId = 71 }, { amount = 250 }, { actor = { src = COP } })
        assert_eq(o.ok, true, tostring(o.error))
        assert_eq(B.Accept(o.bailId, PAYER, {}).ok, true)
        assert_eq(setStates[1].id, 71)
        assert_eq(setStates[1].to, 'vacated')
        assert_eq(setStates[1].reason, 'bail:' .. o.bailId, 'the vacate names this bail')
        -- a shadow of a jail the MDT still runs gets no pf-justice bail in batch 15
        orders[73] = { id = 73, cid = 'PRI2', kind = 'jail', state = 'active', legacyRef = 'mdt_jail:5' }
        assert_eq(B.Offer({ orderId = 73 }, { amount = 250 }, { actor = { src = COP } }).error, 'invalid_state')
        orders[72] = { id = 72, cid = 'PRI2', kind = 'fine', state = 'issued' }
        assert_eq(B.Offer({ orderId = 72 }, { amount = 250 }, { actor = { src = COP } }).error, 'invalid_state')
    end)
end)

describe('offers', function()
    it('validates the offer and allows one open bail per custody', function()
        assert_eq(B.Offer({ custodyId = custodyFor() }, { amount = 0 }, { actor = { src = COP } }).error, 'bad_args')
        assert_eq(B.Offer({ custodyId = custodyFor() }, { amount = Config.Bail.MaxAmount + 1 }, { actor = { src = COP } }).error, 'bad_args')
        assert_eq(B.Offer({}, { amount = 10 }, { actor = { src = COP } }).error, 'bad_args')
        local id = custodyFor()
        local a = B.Offer({ custodyId = id }, { amount = 300 }, { actor = { src = COP } })
        assert_eq(B.Offer({ custodyId = id }, { amount = 300 }, { actor = { src = COP } }).duplicate, true)
        assert_eq(B.Offer({ custodyId = id }, { amount = 900 }, { actor = { src = COP } }).error, 'conflict')
        local civ = Mock.newPlayer(9, 'CIV9')
        assert_eq(B.Offer({ custodyId = custodyFor() }, { amount = 10 }, { actor = { src = 9 } }).error, 'no_permission')
        assert_true(a.ok and civ ~= nil)
    end)

    it('a remanded citizen gets bail from a court only', function()
        local id = custodyFor('remanded')
        assert_eq(B.Offer({ custodyId = id }, { amount = 300 }, { actor = { src = COP } }).error, 'invalid_state')
        assert_eq(B.Offer({ custodyId = id }, { amount = 300 }, { actor = { src = JUDGE } }).ok, true)
    end)

    it('a named payer is the only one who may pay; payer or prisoner may decline', function()
        local o = offer({ amount = 100, payerCid = 'PAY3' })
        Mock.coords[PRISONER] = STATION
        assert_eq(B.Accept(o.bailId, PRISONER, {}).error, 'no_permission')
        local stranger = Mock.newPlayer(8, 'STR8')
        assert_eq(B.Decline(o.bailId, 8).error, 'no_permission')
        assert_eq(B.Decline(o.bailId, PAYER).ok, true)
        assert_eq(DB.bail[o.bailId].state, 'declined')
        assert_true(stranger ~= nil)
    end)

    it('offers expire: refused at payment and swept', function()
        local o = offer()
        Mock.clock = Mock.clock + Config.Bail.OfferSeconds + 5
        assert_eq(B.Accept(o.bailId, PAYER, {}).error, 'invalid_state')
        assert_eq(DB.bail[o.bailId].state, 'expired')
        local o2 = offer()
        B.Tick(Mock.clock + Config.Bail.OfferSeconds + 5)
        assert_eq(DB.bail[o2.bailId].state, 'expired')
    end)

    it('MDT bail imported in batch 15 stays with the MDT until the hand-over', function()
        local o = offer()
        DB.bail[o.bailId].legacy_ref = 'mdt_bail:9'
        assert_eq(B.Accept(o.bailId, PAYER, {}).error, 'invalid_state')
        Config.Compat = { LegacyRuntimes = { mdt = false } }
        Mock.clock = Mock.clock + 6
        assert_eq(B.Accept(o.bailId, PAYER, {}).ok, true)
    end)

    it('callers outside the allowlist are refused; GetBail is open', function()
        local o = offer()
        Mock.invokingResource = 'pf-jobs'
        assert_eq(Mock.exportsByResource['pf-justice'].AcceptBail(o.bailId, PAYER, {}).error, 'not_allowed')
        assert_eq(Mock.exportsByResource['pf-justice'].GetBail('PRI2').bail.state, 'offered')
        Mock.invokingResource = 'pf-policemdt-DEV'
        assert_eq(Mock.exportsByResource['pf-justice'].AcceptBail(o.bailId, PAYER, {}).ok, true)
    end)
end)

describe('exoneration and forfeiture', function()
    local function postedBail()
        local o = offer()
        assert_eq(B.Accept(o.bailId, PAYER, {}).ok, true)
        return o.bailId
    end
    it('exoneration refunds the payer once, keyed', function()
        local id = postedBail()
        assert_eq(B.Exonerate(id, { actor = { src = COP } }).error, 'no_permission')
        local res = B.Exonerate(id, { actor = { src = JUDGE } })
        assert_eq(res.ok, true, tostring(res.error))
        assert_eq(res.state, 'refunded')
        assert_eq(bank(PAYER), 1000)
        assert_eq(doj(), 0)
        assert_true(paid(('pf-justice:bail:%d:refund'):format(id)))
        assert_eq(B.Exonerate(id, {}).duplicate, true)
        assert_eq(bank(PAYER), 1000, 'refunded once')
    end)
    it('a refused refund stays exonerated; the retry uses a new numbered key', function()
        local id = postedBail()
        FakeDB.bank_accounts['doj'].account_balance = 0
        local res = B.Exonerate(id, {})
        assert_eq(res.ok, false)
        assert_eq(DB.bail[id].state, 'exonerated')
        FakeDB.bank_accounts['doj'].account_balance = 400
        local again = B.Exonerate(id, {})
        assert_eq(again.ok, true, tostring(again.error))
        assert_true(paid(('pf-justice:bail:%d:refund:2'):format(id)), 'numbered refund key')
        assert_eq(bank(PAYER), 1000)
    end)
    it('forfeiture keeps the money with the city and cannot be exonerated afterwards', function()
        local id = postedBail()
        assert_eq(B.Forfeit(id, { actor = { src = COP } }).error, 'no_permission')
        assert_eq(B.Forfeit(id, { actor = { src = JUDGE } }).ok, true)
        assert_eq(doj(), 400)
        assert_eq(bank(PAYER), 600)
        assert_eq(B.Exonerate(id, {}).error, 'invalid_state')
        assert_eq(DB.bail[id].state, 'forfeited')
    end)
end)

describe('rework: bail only while the citizen is still held (checker P1, P2, retries)', function()
    it('a custody released before payment: the offer is dead, nobody is charged', function()
        local o, custodyId = offer()
        assert_eq(J.Custody.Release(custodyId, 'no_charges', { actor = { src = COP } }).ok, true)
        assert_eq(DB.bail[o.bailId].state, 'expired', 'closing the custody ended the offer')
        local res = B.Accept(o.bailId, PAYER, {})
        assert_eq(res.ok, false)
        assert_eq(bank(PAYER), 1000)
        assert_eq(doj(), 0)
    end)

    it('an offer still open when its custody ended is refused and expired under the lock', function()
        local o, custodyId = offer()
        -- closed without the bail hook (as a crash between the two would leave it)
        DB.custody[custodyId].closed_at, DB.custody[custodyId].state = Mock.clock, 'released'
        local res = B.Accept(o.bailId, PAYER, {})
        assert_eq(res.error, 'invalid_state')
        assert_eq(DB.bail[o.bailId].state, 'expired')
        assert_eq(bank(PAYER), 1000)
    end)

    it('remand ends earlier offers; an order that ends ends its offer', function()
        local o, custodyId = offer()
        DB.custody[custodyId].state = 'booked'
        assert_eq(J.Custody.SetState(custodyId, 'remanded', { actor = { src = JUDGE } }).ok, true)
        assert_eq(DB.bail[o.bailId].state, 'expired')
        orders[81] = { id = 81, cid = 'PRI2', kind = 'jail', state = 'active' }
        local o2 = B.Offer({ orderId = 81 }, { amount = 100 }, { actor = { src = COP } })
        orders[81].state = 'completed'
        B.OnOrderChanged(orders[81])
        assert_eq(DB.bail[o2.bailId].state, 'expired')
        assert_eq(B.Accept(o2.bailId, PAYER, {}).error, 'invalid_state')
    end)

    it('the refund key is written with exonerated: a failed later write never marks an unpaid refund done', function()
        local o = offer()
        assert_eq(B.Accept(o.bailId, PAYER, {}).ok, true)
        local realCas = J.Bail.Store.cas
        local failOnce = true
        J.Bail.Store.cas = function(id, from, fields)
            if failOnce and from == 'exonerated' and fields.pay_key then failOnce = false return false end
            return realCas(id, from, fields)
        end
        local res = B.Exonerate(o.bailId, { actor = { src = JUDGE } })
        B.Tick(Mock.clock + 1)
        J.Bail.Store.cas = realCas
        assert_eq(res.ok, true, tostring(res.error))
        assert_true(DB.bail[o.bailId].pay_key:find(':refund', 1, true) ~= nil, 'the refund key went in with exonerated')
        assert_eq(DB.bail[o.bailId].state, 'refunded')
        assert_eq(bank(PAYER), 1000, 'refunded for real')
    end)

    it('an exoneration interrupted before the transfer is paid by the sweep under its own refund key', function()
        local o = offer()
        assert_eq(B.Accept(o.bailId, PAYER, {}).ok, true)
        -- what a crash right after the compare-and-set leaves behind
        DB.bail[o.bailId].state, DB.bail[o.bailId].pay_key = 'exonerated', ('pf-justice:bail:%d:refund'):format(o.bailId)
        B.Tick(Mock.clock + 1)
        assert_eq(DB.bail[o.bailId].state, 'refunded')
        assert_eq(bank(PAYER), 1000)
        -- a payment key never settles a refund (an older row): it gets a refund key first
        local o2 = offer()
        Mock.clock = Mock.clock + 6
        assert_eq(B.Accept(o2.bailId, PAYER, {}).ok, true)
        DB.bail[o2.bailId].state = 'exonerated'
        B.Tick(Mock.clock + 2)
        assert_true(paid(('pf-justice:bail:%d:refund'):format(o2.bailId)), 'paid under a refund key')
        assert_eq(bank(PAYER), 1000)
    end)

    it('a posted bail whose release failed is released by the sweep', function()
        local o, custodyId = offer()
        local realRelease = J.Custody.Release
        J.Custody.Release = function() return { ok = false, error = 'busy' } end
        local res = B.Accept(o.bailId, PAYER, {})
        J.Custody.Release = realRelease
        assert_eq(res.ok, true)
        assert_eq(DB.custody[custodyId].closed_at, nil, 'not released yet')
        B.Tick(Mock.clock + 1)
        assert_eq(DB.custody[custodyId].state, 'released')
        assert_eq(DB.custody[custodyId].release_reason, 'bailed')
        assert_eq(bank(PAYER), 600, 'paid once')
    end)

    it('a payment that settles after the custody ended some other way goes back to the payer', function()
        local o, custodyId = offer()
        local real = Mock.exportsByResource['pfm-banking'].Transfer
        Mock.exportsByResource['pfm-banking'].Transfer = function(_, opts) real(opts) error('connection lost') end
        B.Accept(o.bailId, PAYER, {})
        Mock.exportsByResource['pfm-banking'].Transfer = real
        assert_eq(DB.bail[o.bailId].state, 'payment_pending')
        DB.custody[custodyId].state = 'booked'
        J.Custody.Release(custodyId, 'no_charges', { actor = { src = COP } })
        B.Tick(Mock.clock)
        B.Tick(Mock.clock + Config.Bail.PaymentHoldSeconds + 1)
        assert_eq(DB.bail[o.bailId].state, 'refunded')
        assert_eq(bank(PAYER), 1000)
        assert_eq(DB.custody[custodyId].release_reason, 'no_charges')
    end)
end)

describe('round 3: a sentence, a court vacate or a remand voids a bail still settling', function()
    local function pend(bailId)
        local real = Mock.exportsByResource['pfm-banking'].Transfer
        Mock.exportsByResource['pfm-banking'].Transfer = function(_, opts) real(opts) error('connection lost') end
        local res = B.Accept(bailId, PAYER, {})
        Mock.exportsByResource['pfm-banking'].Transfer = real
        assert_eq(DB.bail[bailId].state, 'payment_pending')
        return res
    end
    local function settle()
        B.Tick(Mock.clock)
        B.Tick(Mock.clock + Config.Bail.PaymentHoldSeconds + 1)
    end

    it('a holding-cell jail at the custody facility ends the custody bail offer (P9)', function()
        local o, cust = offer()
        orders[95] = { id = 95, cid = 'PRI2', kind = 'jail', state = 'active', facility = 'mrpd_holding' }
        J.Custody.OnOrderCreated(orders[95])
        assert_eq(DB.bail[o.bailId].state, 'expired')
        assert_eq(B.Accept(o.bailId, PAYER, {}).ok, false)
        assert_eq(bank(PAYER), 1000)
        assert_eq(DB.custody[cust].closed_at, nil, 'the custody stays for the jail')
        assert_eq(orders[95].state, 'active')
        -- a new custody bail cannot be paid either
        local o2 = B.Offer({ custodyId = cust }, { amount = 100 }, { actor = { src = COP } })
        Mock.clock = Mock.clock + 6
        assert_eq(B.Accept(o2.bailId, PAYER, {}).error, 'invalid_state')
    end)

    it('a payment pending when the holding-cell jail starts is refunded, not a release from the sentence', function()
        local o, cust = offer()
        pend(o.bailId)
        orders[96] = { id = 96, cid = 'PRI2', kind = 'jail', state = 'active', facility = 'mrpd_holding' }
        J.Custody.OnOrderCreated(orders[96])
        settle()
        assert_eq(DB.bail[o.bailId].state, 'refunded')
        assert_eq(DB.bail[o.bailId].pay_key, ('pf-justice:bail:%d:refund'):format(o.bailId))
        assert_eq(bank(PAYER), 1000)
        assert_eq(DB.custody[cust].closed_at, nil)
        assert_eq(orders[96].state, 'active')
    end)

    it('an order bail that settles after a court vacated the order is refunded (P5)', function()
        orders[91] = { id = 91, cid = 'PRI2', kind = 'jail', state = 'active' }
        local o = B.Offer({ orderId = 91 }, { amount = 300 }, { actor = { src = COP } })
        pend(o.bailId)
        J.Orders.SetState(91, 'vacated', { reason = 'appeal granted' })
        settle()
        assert_eq(DB.bail[o.bailId].state, 'refunded')
        assert_eq(bank(PAYER), 1000)
        assert_eq(doj(), 0)
    end)

    it('a remand while a payment is pending stops the release; a court offer after the remand still works (P8)', function()
        local o, cust = offer()
        DB.custody[cust].state = 'booked'
        pend(o.bailId)
        assert_eq(J.Custody.SetState(cust, 'remanded', { actor = { src = JUDGE } }).ok, true)
        settle()
        assert_eq(DB.custody[cust].state, 'remanded', 'still remanded')
        assert_eq(DB.bail[o.bailId].state, 'refunded')
        assert_eq(bank(PAYER), 1000)
        Mock.clock = Mock.clock + 6
        local o2 = B.Offer({ custodyId = cust }, { amount = 200 }, { actor = { src = JUDGE } })
        assert_eq(o2.ok, true)
        Mock.coords[PAYER] = DESK
        assert_eq(B.Accept(o2.bailId, PAYER, {}).ok, true)
        assert_eq(DB.custody[cust].state, 'released')
    end)
end)

describe('round 3: the sweep reaches every row; refused automatic refunds are retried', function()
    it('rows the sweep must leave never hide newer ones; MDT offers stay the MDT\'s until the hand-over', function()
        for i = 1, 60 do
            local id = nextId()
            DB.bail[id] = { id = id, citizenid = 'L' .. i, state = 'payment_pending', amount = 10, pay_key = 'pf-policemdt:bail:' .. i .. ':1',
                legacy_ref = 'mdt_bail:' .. i, offered_at = Mock.clock, expires_at = Mock.clock + 100000 }
        end
        local lid = nextId()
        DB.bail[lid] = { id = lid, citizenid = 'L0', state = 'offered', amount = 10, legacy_ref = 'mdt_bail:999', offered_at = Mock.clock, expires_at = Mock.clock - 1 }
        local o = offer()
        DB.bail[o.bailId].expires_at = Mock.clock - 1
        B.Tick(Mock.clock)
        B.Tick(Mock.clock)
        assert_eq(DB.bail[o.bailId].state, 'expired', 'reached past 60 rows it leaves alone')
        assert_eq(DB.bail[lid].state, 'offered', 'the MDT still owns its offer')
        assert_eq(DB.bail[lid - 1].state, 'payment_pending', 'live MDT payments stay with the MDT')
        Config.Compat = { LegacyRuntimes = { mdt = false } }
        B.Tick(Mock.clock)
        B.Tick(Mock.clock)
        assert_eq(DB.bail[lid].state, 'expired', 'after the hand-over the expired offer is closed')
    end)

    it('a refused automatic refund is retried under the next numbered key after a pause, up to the cap', function()
        local o, cust = offer()
        local real = Mock.exportsByResource['pfm-banking'].Transfer
        Mock.exportsByResource['pfm-banking'].Transfer = function(_, opts) real(opts) error('connection lost') end
        B.Accept(o.bailId, PAYER, {})
        Mock.exportsByResource['pfm-banking'].Transfer = real
        J.Custody.Release(cust, 'no_charges', { actor = { src = COP } })
        FakeDB.bank_accounts['doj'].account_balance = 0
        B.Tick(Mock.clock)
        B.Tick(Mock.clock + Config.Bail.PaymentHoldSeconds + 1)
        assert_eq(DB.bail[o.bailId].state, 'exonerated', 'the refund was refused')
        assert_eq(bank(PAYER), 600)
        B.Tick(Mock.clock + 1)
        assert_eq(DB.bail[o.bailId].pay_key, ('pf-justice:bail:%d:refund'):format(o.bailId), 'no new key before the pause')
        FakeDB.bank_accounts['doj'].account_balance = 400
        Mock.clock = Mock.clock + (Config.Bail.RefundRetrySeconds or 600) + 1
        B.Tick(Mock.clock)
        assert_eq(DB.bail[o.bailId].state, 'refunded')
        assert_true(paid(('pf-justice:bail:%d:refund:2'):format(o.bailId)), 'paid under the second key')
        assert_eq(bank(PAYER), 1000)
    end)

    it('after MaxRefundAttempts refused keys the bail is audited as stuck and waits for a court', function()
        Config.Bail.MaxRefundAttempts = 2
        local o, cust = offer()
        local real = Mock.exportsByResource['pfm-banking'].Transfer
        Mock.exportsByResource['pfm-banking'].Transfer = function(_, opts) real(opts) error('connection lost') end
        B.Accept(o.bailId, PAYER, {})
        Mock.exportsByResource['pfm-banking'].Transfer = real
        J.Custody.Release(cust, 'no_charges', { actor = { src = COP } })
        FakeDB.bank_accounts['doj'].account_balance = 0
        B.Tick(Mock.clock)
        B.Tick(Mock.clock + Config.Bail.PaymentHoldSeconds + 1)
        for _ = 1, 4 do
            Mock.clock = Mock.clock + 700
            B.Tick(Mock.clock)
        end
        Config.Bail.MaxRefundAttempts = nil
        assert_eq(DB.bail[o.bailId].pay_key, ('pf-justice:bail:%d:refund:2'):format(o.bailId), 'capped at two keys')
        local stuck = 0
        for _, l in ipairs(DB.log) do if l.kind == 'bail_refund_stuck' then stuck = stuck + 1 end end
        assert_eq(stuck, 1, 'audited once')
        FakeDB.bank_accounts['doj'].account_balance = 400
        local res = B.Exonerate(o.bailId, { actor = { src = JUDGE } })
        assert_eq(res.ok, true, tostring(res.error))
        assert_eq(bank(PAYER), 1000)
    end)
end)

describe('round 4: remand, hospital, escape and a vacate in between', function()
    local function pend(bailId)
        local real = Mock.exportsByResource['pfm-banking'].Transfer
        Mock.exportsByResource['pfm-banking'].Transfer = function(_, opts) real(opts) error('connection lost') end
        B.Accept(bailId, PAYER, {})
        Mock.exportsByResource['pfm-banking'].Transfer = real
        assert_eq(DB.bail[bailId].state, 'payment_pending')
    end
    local function settle()
        B.Tick(Mock.clock)
        B.Tick(Mock.clock + Config.Bail.PaymentHoldSeconds + 1)
    end

    it('a remand still voids an earlier bail after the citizen went to hospital (Q1)', function()
        local o, cust = offer()
        DB.custody[cust].state = 'booked'
        pend(o.bailId)
        Mock.clock = Mock.clock + 2
        assert_eq(J.Custody.SetState(cust, 'remanded', { actor = { src = JUDGE } }).ok, true)
        DB.custody[cust].prev_state, DB.custody[cust].state = 'remanded', 'hospital'
        settle()
        assert_eq(DB.custody[cust].state, 'hospital', 'not released')
        assert_eq(DB.bail[o.bailId].state, 'refunded')
        assert_eq(bank(PAYER), 1000)
    end)

    it('a bail settling while the citizen is in hospital waits and releases after the return, never from hospital', function()
        local o, cust = offer()
        pend(o.bailId)
        DB.custody[cust].prev_state, DB.custody[cust].state = 'held', 'hospital'
        settle()
        assert_eq(DB.bail[o.bailId].state, 'posted')
        assert_eq(DB.custody[cust].state, 'hospital', 'not released from hospital')
        B.Tick(Mock.clock + 500)
        assert_eq(DB.custody[cust].state, 'hospital')
        DB.custody[cust].state = 'held'
        B.Tick(Mock.clock + 600)
        assert_eq(DB.custody[cust].state, 'released')
        assert_eq(DB.custody[cust].release_reason, 'bailed')
        assert_eq(bank(PAYER), 600, 'paid once')
    end)

    it('an escape is never forgiven: an order bail settling after the escape is refunded (Q2)', function()
        orders[97] = { id = 97, cid = 'PRI2', kind = 'jail', state = 'active' }
        local o = B.Offer({ orderId = 97 }, { amount = 250 }, { actor = { src = COP } })
        pend(o.bailId)
        orders[97].state = 'suspended'
        settle()
        assert_eq(orders[97].state, 'suspended')
        assert_eq(DB.bail[o.bailId].state, 'refunded')
        assert_eq(bank(PAYER), 1000)
        -- an open offer dies with the escape
        orders[98] = { id = 98, cid = 'PRI2', kind = 'jail', state = 'active' }
        local o2 = B.Offer({ orderId = 98 }, { amount = 250 }, { actor = { src = COP } })
        orders[98].state = 'suspended'
        B.OnOrderChanged(orders[98])
        assert_eq(DB.bail[o2.bailId].state, 'expired')
    end)

    it('a vacate by a court between the check and the bail\'s own vacate is not counted as the bail\'s (c)', function()
        orders[99] = { id = 99, cid = 'PRI2', kind = 'jail', state = 'active' }
        local o = B.Offer({ orderId = 99 }, { amount = 250 }, { actor = { src = COP } })
        local realSet = J.Orders.SetState
        J.Orders.SetState = function(id, to, opts)
            -- the court got there first: 15B answers a repeated vacate as a duplicate
            setStates[#setStates + 1] = { id = id, to = 'vacated', reason = 'court release' }
            orders[id].state = 'vacated'
            return { ok = true, duplicate = true }
        end
        local res = B.Accept(o.bailId, PAYER, {})
        J.Orders.SetState = realSet
        assert_eq(res.ok, false)
        assert_eq(DB.bail[o.bailId].state, 'refunded')
        assert_eq(bank(PAYER), 1000)
    end)
end)
