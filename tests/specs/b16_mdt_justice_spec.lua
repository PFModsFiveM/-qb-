-- Batch 16 (16D): the police MDT's jail runtime is handed to pf-justice (pf-policemdt-DEV
-- server/sentencing.lua). pf-justice is a contract stub here (its own specs cover it; the real one
-- runs in tests/realdb_specs/b16_mdt_justice_realdb_spec.lua):
--   * the switch follows pf-justice's Config.Compat.LegacyRuntimes.mdt read from its config file;
--     Config.Sentencing.Justice.Runtime forces a side; an unreadable file keeps the built-in jail;
--   * after the hand-over a sentence keeps the presence / custody rules, the locks and its
--     pf_mdt_sentences row, then makes pf-justice orders keyed pf-policemdt:sentence:<id>:fine|jail
--     (the MDT moves no money and fills no pf_mdt_active_jails row); the jail order un-cuffs the
--     prisoner and the client only draws pf-justice's time;
--   * postBail / /bailaccept / /baildecline relay to OfferBail / AcceptBail / DeclineBail with the
--     amount from the sentence row; an imported order gets no new offer;
--   * the built-in jail never runs (no tick, no S.Jail, no client release, no MDT /unjail); a fine
--     from before the hand-over that settles later still settles, its jail time a pf-justice order.
load_resource('tests/lua/fivem_mocks.lua')
function IsDuplicityVersion() return true end
local states = { ['pf-justice'] = 'started', ['pfm-banking'] = 'started', ['pfm-policejob'] = 'started' }
function GetResourceState(name) return states[name] or 'missing' end
QBCore = QBCoreMock
local Commands = {}
QBCoreMock.Commands.Add = function(name, _, _, _, fn) Commands[name] = fn end

-- ── the MDT's tables in memory ──────────────────────────────────────────────
local CHARGES = {
    J1 = { code = 'J1', name = 'Robbery', fineAmount = 0, bailAmount = 500, prisonTime = 10 },
    F1 = { code = 'F1', name = 'Speeding', fineAmount = 300, bailAmount = 0, prisonTime = 0 },
}
local DB
local function copy(t) local o = {} for k, v in pairs(t) do o[k] = v end return o end
local function resetDB() DB = { jails = {}, sentences = {}, nextSentence = 0, writesToJails = 0 } end
resetDB()
local function run(kind, sql, p)
    p = p or {}
    if sql:find('FROM pf_mdt_charges', 1, true) then
        local out = {}
        for _, code in ipairs(p) do if CHARGES[code] then out[#out + 1] = copy(CHARGES[code]) end end
        return out
    end
    if sql:find('pf_mdt_active_jails', 1, true) then
        if sql:find('^%s*UPDATE') or sql:find('^%s*DELETE') or sql:find('^%s*INSERT') then DB.writesToJails = DB.writesToJails + 1 return 0 end
        if sql:find('bail_key IS NOT NULL', 1, true) then
            local out = {} for _, r in pairs(DB.jails) do if r.bail_key and not r.released_why then out[#out + 1] = copy(r) end end return out
        end
        if sql:find('WHERE citizenid = ?', 1, true) then for _, r in pairs(DB.jails) do if r.citizenid == p[1] then return copy(r) end end return nil end
        local out = {} for _, r in pairs(DB.jails) do out[#out + 1] = copy(r) end return out
    end
    if sql:find('INSERT INTO pf_mdt_sentences', 1, true) then
        DB.nextSentence = DB.nextSentence + 1
        DB.sentences[DB.nextSentence] = { id = DB.nextSentence, citizenId = p[1], title = p[5], sentenceType = p[7], charges = p[8],
            fineAmount = p[10], prisonTime = p[11], bailAmount = p[15], bailed = 0,
            status = sql:find("'ju_pending'", 1, true) and 'ju_pending' or 'pending' }
        return DB.nextSentence
    end
    if sql:find('UPDATE pf_mdt_sentences SET status = ?, executed = ?', 1, true) then
        local r = DB.sentences[p[7]]
        if r then r.status, r.executed, r.fineSuccess, r.jailSuccess, r.error, r.fine_key = p[1], p[2], p[3], p[4], p[5], p[6] end
        return 1
    end
    if sql:find("status = ?, executed = 1, fineSuccess = ?, jailSuccess = ?, error = ?, fine_key = ? WHERE id = ? AND status = 'ju_pending'", 1, true) then
        local r = DB.sentences[p[6]]
        if r and r.status == 'ju_pending' then r.status, r.fineSuccess, r.jailSuccess, r.error, r.fine_key = p[1], p[2], p[3], p[4], p[5] return 1 end
        return 0
    end
    if sql:find("WHERE status = 'ju_pending' AND createdAt", 1, true) then
        local out = {} for _, r in pairs(DB.sentences) do if r.status == 'ju_pending' and r.stale then out[#out + 1] = copy(r) end end return out
    end
    if sql:find("WHERE status = 'payment_pending' ORDER BY", 1, true) then
        local out = {} for _, r in pairs(DB.sentences) do if r.status == 'payment_pending' then out[#out + 1] = copy(r) end end return out
    end
    if sql:find("SET status = ?, fineSuccess = ?, error = ? WHERE id = ? AND status = 'payment_pending'", 1, true) then
        local r = DB.sentences[p[4]]
        if r and r.status == 'payment_pending' then r.status, r.fineSuccess, r.error = p[1], p[2], p[3] return 1 end
        return 0
    end
    if sql:find('SET executed = 1, jailSuccess = ?', 1, true) then
        local r = DB.sentences[p[3]] if r then r.jailSuccess, r.error = p[1], p[2] end return 1
    end
    if sql:find("WHERE citizenId = ? AND (status = 'payment_pending'", 1, true) then
        for _, r in pairs(DB.sentences) do if r.citizenId == p[1] and r.status == 'payment_pending' then return copy(r) end end
        return nil
    end
    if sql:find('SELECT * FROM pf_mdt_sentences WHERE id = ?', 1, true) then local r = DB.sentences[p[1]] return r and copy(r) or nil end
    if sql:find('SELECT * FROM pf_mdt_sentences WHERE citizenId = ?', 1, true) then
        local out = {} for _, r in pairs(DB.sentences) do if r.citizenId == p[1] then out[#out + 1] = copy(r) end end return out
    end
    if sql:find('SET fineSuccess = ? WHERE id = ? AND fine_key = ?', 1, true) then
        local r = DB.sentences[p[2]] if r and r.fine_key == p[3] then r.fineSuccess = p[1] return 1 end return 0
    end
    if sql:find('SET bailed = 1', 1, true) then
        local r = DB.sentences[p[3]] if r then r.bailed, r.bailPaidByCitizenId, r.bailPaidByName = 1, p[1], p[2] end return 1
    end
    return kind == 'query' and {} or (kind == 'single' and nil or 0)
end
local function op(kind)
    return setmetatable({ await = function(sql, p) return run(kind, sql, p) end }, { __call = function(_, sql, p, cb)
        local r = run(kind, sql, p) if cb then cb(r) end return r end })
end
MySQL = { query = op('query'), insert = op('insert'), update = op('update'), single = op('single'), scalar = op('scalar'), prepare = op('query') }
Mock.exportsByResource['oxmysql'] = {
    execute = function(_, sql, params, cb) if Mock.callable(params) then cb = params end if cb then cb({}) end return {} end,
    insert = function(_, sql, params, cb) if Mock.callable(cb) then cb(1) end return 1 end,
}
Mock.exportsByResource['pfm-core'].RunMigrations = function() return true end

-- ── pf-justice stub (its exports as PF_ARCHITECTURE 12.2 describes them) ─────
local JU
local function resetJU()
    JU = { calls = {}, orders = {}, nextOrder = 0, bails = {}, nextBail = 0, custody = nil, pay = { ok = true, state = 'paid' },
        accept = { ok = true, state = 'posted' } }
end
resetJU()
local function called(name) local out = {} for _, c in ipairs(JU.calls) do if c.name == name then out[#out + 1] = c end end return out end
local function cidOf(who) if type(who) == 'number' then return Mock.players[who] and Mock.players[who].PlayerData.citizenid end return who end
local function activeOf(cid)
    for _, o in pairs(JU.orders) do
        if o.cid == cid and (o.kind == 'jail' or o.kind == 'prison') and (o.state == 'active' or o.state == 'pending') then return o end
    end
end
local function rec(name, ...) JU.calls[#JU.calls + 1] = { name = name, args = { ... } } end
Mock.exportsByResource['pf-justice'] = {
    IsIncarcerated = function(_, who) rec('IsIncarcerated', who) return activeOf(cidOf(who)) ~= nil end,
    GetOrders = function(_, cid, filter)
        rec('GetOrders', cid, filter)
        local list = {}
        for _, o in pairs(JU.orders) do
            if o.cid == cid then
                local ok = true
                if filter and filter.kinds then ok = false for _, k in ipairs(filter.kinds) do if k == o.kind then ok = true end end end
                if ok and filter and filter.states then local s = false for _, st in ipairs(filter.states) do if st == o.state then s = true end end ok = s end
                if ok then list[#list + 1] = o end
            end
        end
        return { ok = true, list = list }
    end,
    GetCustody = function(_, who) rec('GetCustody', who) return { ok = true, custody = JU.custody } end,
    CreateOrder = function(_, spec, opts)
        rec('CreateOrder', spec, opts)
        for _, o in pairs(JU.orders) do
            if o.key == opts.key then return { ok = true, duplicate = true, orderId = o.id, state = o.state } end
        end
        JU.nextOrder = JU.nextOrder + 1
        local o = { id = JU.nextOrder, cid = spec.cid, kind = spec.kind, state = spec.kind == 'fine' and 'issued' or 'active', key = opts.key,
            amount = spec.amount, remainingSeconds = spec.minutes and spec.minutes * 60 or nil, sourceRef = spec.sourceRef, charges = spec.charges }
        JU.orders[o.id] = o
        return { ok = true, orderId = o.id, state = o.state }
    end,
    PayOrder = function(_, id, opts)
        rec('PayOrder', id, opts)
        local o = JU.orders[id]
        if JU.pay.ok then o.state = 'paid' elseif JU.pay.state then o.state = JU.pay.state end
        return JU.pay
    end,
    GetActiveIncarceration = function(_, who)
        rec('GetActiveIncarceration', who)
        local o = activeOf(cidOf(who))
        if not o then return { ok = true, remainingSeconds = 0 } end
        return { ok = true, order = o, remainingSeconds = o.remainingSeconds, facility = 'bolingbroke' }
    end,
    GetOrder = function(_, id) rec('GetOrder', id) local o = JU.orders[id] return o and { ok = true, order = o } or { ok = false, error = 'not_found' } end,
    OfferBail = function(_, ref, spec, opts)
        rec('OfferBail', ref, spec, opts)
        JU.nextBail = JU.nextBail + 1
        local b = { id = JU.nextBail, orderId = ref.orderId, amount = spec.amount, payerCid = spec.payerCid, state = 'offered', expiresAt = Mock.clock + 600 }
        JU.bails[b.id] = b
        return { ok = true, bailId = b.id }
    end,
    GetBail = function(_, who)
        rec('GetBail', who)
        if type(who) == 'table' then return { ok = true, bail = JU.bails[who.bailId] } end
        local latest
        for _, b in pairs(JU.bails) do
            local o = JU.orders[b.orderId]
            if o and o.cid == cidOf(who) and (not latest or b.id > latest.id) then latest = b end
        end
        return { ok = true, bail = latest }
    end,
    AcceptBail = function(_, id, payerSrc, opts) rec('AcceptBail', id, payerSrc, opts) return JU.accept end,
    DeclineBail = function(_, id, payerSrc) rec('DeclineBail', id, payerSrc) return { ok = true } end,
}
local cuffCalls = {}
Mock.exportsByResource['pfm-policejob'] = {
    IsCuffed = function(_, src) return Mock.players[src] and Mock.players[src].PlayerData.metadata.ishandcuffed == true end,
    SetCuffed = function(_, src, on, why) cuffCalls[#cuffCalls + 1] = { src = src, on = on, why = why }
        Mock.players[src].PlayerData.metadata.ishandcuffed = on return true end,
}
local ledger = { transfers = {}, tx = {} }
Mock.exportsByResource['pfm-banking'] = {
    Transfer = function(_, opts)
        ledger.transfers[#ledger.transfers + 1] = opts
        local r = ledger.next or { ok = true, state = 'completed' }
        ledger.tx[opts.key] = { state = r.ok and 'completed' or 'failed', error = r.error, amount = opts.amount, to_account = opts.to }
        return r
    end,
    GetTransaction = function(_, key) return ledger.tx[key] end,
    EnsureSocietyAccount = function() return true end,
}

-- ── the resource, in hand-over mode (pf-justice's config file says mdt = false) ──
local JUSTICE_CONFIG = [[
Config = Config or {}
Config.Bail = { Account = 'doj', Desks = { { coords = vector3(1, 2, 3), radius = 5.0 } } }
Config.Compat = { LegacyRuntimes = { mdt = %s, prison = true, policejob = true }, RecordExpiryDays = 30 }
]]
local justiceFile = JUSTICE_CONFIG:format('false')
function LoadResourceFile(res, file)
    if res == 'pf-justice' and file == 'config.lua' then return justiceFile end
    return nil
end

function GetCurrentResourceName() return 'pf-policemdt-DEV' end
Config = nil
load_resource('[pfscripts]/pf-policemdt-DEV/shared/framework.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/config.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/server/access.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/server/main.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/server/sentencing.lua')
local S = PFMdtSentencing
assert(S.Start(), 'start')

local OFFICER, PRISONER, PAYER = 1, 2, 3
local STREET = vector3(100.0, 100.0, 30.0)
local FAR = vector3(3000.0, 3000.0, 30.0)

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    Mock.clock = Mock.clock + 3600
    Mock.gameTimer = Mock.gameTimer + 1000000
    resetDB()
    resetJU()
    cuffCalls, ledger = {}, { transfers = {}, tx = {} }
    justiceFile = JUSTICE_CONFIG:format('false')
    Config.Sentencing.Justice.Runtime = 'auto'
    S.ResetJusticeConfig()
    Mock.newPlayer(OFFICER, 'OFF1').PlayerData.job = { name = 'police', type = 'leo', onduty = true, grade = { level = 4 } }
    local p = Mock.newPlayer(PRISONER, 'CID2')
    p.PlayerData.charinfo = { firstname = 'Rob', lastname = 'Banks' }
    p.PlayerData.metadata.ishandcuffed = true
    p.PlayerData.items = { { name = 'phone', amount = 1, slot = 1 } }
    p.Functions.ClearInventory = function() p.PlayerData.items = {} end
    p.Functions.RemoveItem = function() return true end
    Mock.newPlayer(PAYER, 'PAY3')
    Mock.coords[OFFICER], Mock.coords[PRISONER], Mock.coords[PAYER] = STREET, STREET, STREET
end

local function sentence(charges, kind, extra)
    local data = { citizenId = 'CID2', title = 'Robbery', sentenceType = kind or 'sentence', charges = charges or { 'J1' } }
    for k, v in pairs(extra or {}) do data[k] = v end
    return Mock.callCallback('pf_mdt:createSentence', OFFICER, data)
end
local function sentTo(name, target)
    local out = {}
    for _, e in ipairs(Mock.clientEventsNamed(name)) do if target == nil or e.target == target then out[#out + 1] = e end end
    return out
end

describe('who runs MDT jails', function()
    it('follows pf-justice\'s config file: mdt = false hands over, true keeps the built-in jail', function()
        assert_true(S.HandedOver(), 'mdt = false')
        justiceFile = JUSTICE_CONFIG:format('true')
        S.ResetJusticeConfig()
        assert_false(S.HandedOver(), 'mdt = true')
    end)
    it('an unreadable or broken pf-justice config keeps the built-in jail', function()
        justiceFile = nil
        S.ResetJusticeConfig()
        assert_false(S.HandedOver())
        justiceFile = 'this is not lua ('
        S.ResetJusticeConfig()
        assert_false(S.HandedOver())
        -- the file cannot reach the server's globals: an assignment there changes nothing outside it
        justiceFile = 'Config = { Compat = { LegacyRuntimes = { mdt = false } } } PFMdtSentencing = nil'
        S.ResetJusticeConfig()
        assert_true(S.HandedOver())
        assert_true(PFMdtSentencing ~= nil, 'sandboxed')
    end)
    it('Config.Sentencing.Justice.Runtime forces a side', function()
        Config.Sentencing.Justice.Runtime = 'legacy'
        assert_false(S.HandedOver())
        justiceFile = JUSTICE_CONFIG:format('true')
        S.ResetJusticeConfig()
        Config.Sentencing.Justice.Runtime = 'justice'
        assert_true(S.HandedOver())
    end)
    it('the bail account is read from pf-justice too (for legacy bail moves)', function()
        assert_eq(S.JusticeConfig().bailAccount, 'doj')
    end)
end)

describe('a sentence after the hand-over', function()
    it('keeps the legal record and makes one keyed pf-justice jail order from the charges, with the custody', function()
        JU.custody = { id = 42, state = 'arrested' }
        local res = sentence({ 'J1' }, 'sentence', { prisonTime = 9999, fineAmount = 1 })
        assert_eq(res.success, true, tostring(res.error))
        local c = called('CreateOrder')
        assert_eq(#c, 1)
        local spec, opts = c[1].args[1], c[1].args[2]
        assert_eq(spec.kind, 'jail')
        assert_eq(spec.cid, 'CID2')
        assert_eq(spec.minutes, 10, 'from the charge row, not the client')
        assert_eq(spec.sourceRef.type, 'mdt_sentence')
        assert_eq(spec.sourceRef.id, tostring(res.id))
        assert_eq(spec.custodyId, 42)
        assert_eq(spec.charges[1].label, 'Robbery')
        assert_eq(opts.key, ('pf-policemdt:sentence:%d:jail'):format(res.id))
        assert_eq(opts.actor.src, OFFICER)
        local row = DB.sentences[res.id]
        assert_eq(row.status, 'done')
        assert_eq(row.jailSuccess, 1)
        assert_eq(res.jailOrderId, 1)
    end)
    it('the built-in jail is not used: no jail row, the inventory stays (pfm-prison takes it), no MDT teleport', function()
        assert_eq(sentence().success, true)
        assert_eq(DB.writesToJails, 0)
        assert_eq(#Mock.players[PRISONER].PlayerData.items, 1)
        local start = sentTo('pf_mdt:client:StartMdtSentence', PRISONER)
        assert_eq(#start, 1)
        assert_eq(start[1].args[1].justice, true, 'the client only draws the timer')
        assert_eq(start[1].args[1].seconds, 600)
    end)
    it('the jail order takes the cuffs off through pfm-policejob', function()
        assert_eq(sentence().success, true)
        assert_eq(#cuffCalls, 1)
        assert_eq(cuffCalls[1].on, false)
        assert_eq(cuffCalls[1].why, 'jail_order')
        assert_false(Mock.players[PRISONER].PlayerData.metadata.ishandcuffed)
    end)
    it('presence and custody still decide: across the map, or free and away from a desk, nothing is made', function()
        Mock.coords[PRISONER] = FAR
        assert_eq(sentence().success, false)
        Mock.coords[PRISONER] = STREET
        Mock.players[PRISONER].PlayerData.metadata.ishandcuffed = false
        local res = sentence()
        assert_eq(res.success, false)
        assert_eq(res.error, 'The suspect must be handcuffed or at a booking desk')
        assert_eq(#called('CreateOrder'), 0)
        assert_eq(DB.nextSentence, 0, 'no record either')
    end)
    it('one player cannot hold two incarcerations: an open one refuses the sentence', function()
        JU.orders[9] = { id = 9, cid = 'CID2', kind = 'prison', state = 'active', remainingSeconds = 100 }
        JU.nextOrder = 9
        local res = sentence()
        assert_eq(res.success, false)
        assert_eq(res.error, 'Citizen is already serving a sentence')
        assert_eq(#called('CreateOrder'), 0)
    end)
    it('with pf-justice stopped nothing happens', function()
        states['pf-justice'] = 'stopped'
        local res = sentence()
        states['pf-justice'] = 'started'
        assert_eq(res.success, false)
        assert_eq(DB.nextSentence, 0)
    end)
    it('a second click right after is not a second order', function()
        assert_eq(sentence().success, true)
        assert_eq(sentence().success, false)
        assert_eq(#called('CreateOrder'), 1)
    end)
    it('a fine is a pf-justice fine order paid from the citizen\'s bank through PayOrder; the MDT moves no money', function()
        local res = sentence({ 'F1' }, 'fine')
        assert_eq(res.success, true, tostring(res.error))
        local c = called('CreateOrder')[1]
        assert_eq(c.args[1].kind, 'fine')
        assert_eq(c.args[1].amount, 300)
        assert_eq(c.args[2].key, ('pf-policemdt:sentence:%d:fine'):format(res.id))
        local pay = called('PayOrder')[1]
        assert_eq(pay.args[2].payerSrc, PRISONER)
        assert_eq(pay.args[2].account, 'bank')
        assert_eq(pay.args[2].key, ('pf-policemdt:sentence:%d:pay'):format(res.id))
        assert_eq(#ledger.transfers, 0)
        assert_eq(DB.sentences[res.id].fineSuccess, 1)
        assert_eq(DB.sentences[res.id].fine_key, ('pf-policemdt:sentence:%d:fine'):format(res.id))
    end)
    it('a citizen without the money: the fine order is a phone invoice (pf-justice) and the sentence stands', function()
        JU.pay = { ok = false, error = 'insufficient_funds', state = 'invoiced', invoiceId = 7 }
        local res = sentence({ 'F1', 'J1' }, 'fine+sentence')
        assert_eq(res.success, true, tostring(res.error))
        assert_eq(res.fineState, 'invoiced')
        assert_eq(DB.sentences[res.id].fineSuccess, 0)
        assert_true(DB.sentences[res.id].error:find('invoice', 1, true) ~= nil, 'the record says so')
        assert_eq(#called('CreateOrder'), 2, 'fine and jail')
    end)
    it('an unclear payment is never charged again; no new fine for the citizen until it settles', function()
        JU.pay = { ok = false, error = 'payment_unclear', state = 'payment_pending' }
        local res = sentence({ 'F1' }, 'fine')
        assert_eq(res.fineState, 'payment_pending')
        assert_eq(#called('PayOrder'), 1)
        Mock.clock = Mock.clock + 60
        local again = sentence({ 'F1' }, 'fine')
        assert_eq(again.success, false)
        assert_eq(again.error, 'A fine for this citizen is still being confirmed by the bank; wait for it to settle')
        assert_eq(#called('PayOrder'), 1)
    end)
    it('a fine whose jail part fails afterwards stays an order; the officer is told not to sentence again', function()
        local realCreate = Mock.exportsByResource['pf-justice'].CreateOrder
        Mock.exportsByResource['pf-justice'].CreateOrder = function(self, spec, opts)
            if spec.kind == 'jail' then return { ok = false, error = 'db_unavailable', message = 'The justice database did not answer' } end
            return realCreate(self, spec, opts)
        end
        local res = sentence({ 'F1', 'J1' }, 'fine+sentence')
        Mock.exportsByResource['pf-justice'].CreateOrder = realCreate
        assert_eq(res.success, false)
        assert_eq(res.fineIssued, true)
        assert_true(res.error:find('do not sentence it again', 1, true) ~= nil)
        assert_eq(DB.sentences[res.id].status, 'done')
        assert_eq(DB.sentences[res.id].jailSuccess, 0)
        -- the double-click guard covers it too
        assert_eq(sentence({ 'F1', 'J1' }, 'fine+sentence').error, 'This citizen was just sentenced')
    end)
    it('a city news lead goes out as before', function()
        local emits = {}
        states['pf-services'] = 'started'
        Mock.exportsByResource['pf-services'] = { Emit = function(_, kind, data) emits[#emits + 1] = { kind = kind, data = data } return 1 end }
        assert_eq(sentence().success, true)
        states['pf-services'] = nil
        assert_eq(#emits, 1)
        assert_eq(emits[1].kind, 'police.sentenced')
        assert_eq(emits[1].data.months, 10)
    end)
end)

describe('the built-in jail is off after the hand-over', function()
    it('S.Jail refuses (no path jails without a pf-justice order)', function()
        local ok, err = S.Jail(PRISONER, { seconds = 600, reason = 'x' })
        assert_false(ok)
        assert_true(tostring(err):find('pf-justice', 1, true) ~= nil)
        assert_eq(DB.writesToJails, 0)
    end)
    it('the tick leaves the old jail rows alone (pf-justice imported them)', function()
        DB.jails[1] = { id = 1, citizenid = 'CID2', remaining_seconds = 0, total_seconds = 600, items = '[]', provider = 'qb-inventory' }
        S.Tick()
        assert_eq(DB.writesToJails, 0)
        assert_eq(#sentTo('pf_mdt:client:ReleaseMdtSentence'), 0)
    end)
    it('a client saying its timer ran out changes nothing', function()
        DB.jails[1] = { id = 1, citizenid = 'CID2', remaining_seconds = 0, total_seconds = 600, items = '[]', provider = 'qb-inventory' }
        Mock.fireNet('pf_mdt:server:mdtSentenceReleased', PRISONER)
        assert_eq(DB.writesToJails, 0)
    end)
    it('the release comes from pf-justice: the timer goes on releaseOrdered', function()
        TriggerEvent('pf-justice:server:releaseOrdered', 'CID2', 1, 'completed')
        local e = sentTo('pf_mdt:client:ReleaseMdtSentence', PRISONER)
        assert_eq(#e, 1)
        assert_eq(e[1].args[1].justice, true)
    end)
    it('a reconnect shows the timer of an MDT order again (an MDT jail survives a restart through pf-justice)', function()
        JU.orders[5] = { id = 5, cid = 'CID2', kind = 'jail', state = 'active', remainingSeconds = 420,
            sourceRef = { type = 'mdt_sentence', id = '3' }, charges = { { label = 'Robbery' } } }
        S.OnPlayerLoaded(PRISONER)
        local e = sentTo('pf_mdt:client:StartMdtSentence', PRISONER)
        assert_eq(#e, 1)
        assert_eq(e[1].args[1].seconds, 420)
        assert_eq(e[1].args[1].justice, true)
        -- a field or court order is not the MDT's timer
        JU.orders[5].sourceRef = { type = 'field', id = '1' }
        S.OnPlayerLoaded(PRISONER)
        assert_eq(#sentTo('pf_mdt:client:StartMdtSentence', PRISONER), 1)
    end)
    it('a fine from before the hand-over that settles later still settles; its jail time is a pf-justice order', function()
        DB.nextSentence = 7
        DB.sentences[7] = { id = 7, citizenId = 'CID2', title = 'Old', status = 'payment_pending', fine_key = 'pf-policemdt:fine:7',
            prisonTime = 15, fineAmount = 300, charges = json.encode({ { code = 'J1', name = 'Robbery' } }) }
        ledger.tx['pf-policemdt:fine:7'] = { state = 'completed', amount = 300 }
        S.CheckPendingFines()
        assert_eq(DB.sentences[7].status, 'done')
        local c = called('CreateOrder')
        assert_eq(#c, 1)
        assert_eq(c[1].args[1].minutes, 15)
        assert_eq(c[1].args[2].key, 'pf-policemdt:sentence:7:jail')
        assert_eq(DB.writesToJails, 0)
        assert_eq(DB.sentences[7].jailSuccess, 1)
        -- settled once: a second pass makes nothing
        S.CheckPendingFines()
        assert_eq(#called('CreateOrder'), 1)
    end)
    it('getCitizenSentences shows pf-justice\'s order and the sentence\'s bail', function()
        local res = sentence()
        local list = Mock.callCallback('pf_mdt:getCitizenSentences', OFFICER, { citizenId = 'CID2' })
        assert_eq(list.success, true)
        assert_eq(list.activeJail.active, true)
        assert_eq(list.activeJail.remainingMinutes, 10)
        assert_eq(list.activeJail.sentenceId, res.id)
        assert_eq(list.activeJail.bailAmount, 500)
    end)
end)

describe('bail after the hand-over', function()
    local function jailed()
        local res = sentence()
        assert_eq(res.success, true)
        return res
    end
    it('postBail is a pf-justice offer on the order, the amount from the sentence row, the payer named', function()
        local res = jailed()
        local r = Mock.callCallback('pf_mdt:postBail', OFFICER, { prisonerCitizenId = 'CID2', payerCitizenId = 'PAY3', amount = 1 })
        assert_eq(r.success, true, tostring(r.error))
        local o = called('OfferBail')[1]
        assert_eq(o.args[1].orderId, res.jailOrderId)
        assert_eq(o.args[2].amount, 500)
        assert_eq(o.args[2].payerCid, 'PAY3')
        assert_eq(o.args[3].actor.src, OFFICER)
        local prompt = sentTo('pf_mdt:client:BailOffer', PAYER)
        assert_eq(#prompt, 1)
        assert_eq(prompt[1].args[1].amount, 500)
    end)
    it('/bailaccept is AcceptBail for the payer; the sentence records the payer once pf-justice posts it', function()
        local res = jailed()
        Mock.callCallback('pf_mdt:postBail', OFFICER, { prisonerCitizenId = 'CID2', payerCitizenId = 'PAY3' })
        Commands.bailaccept(PAYER)
        local a = called('AcceptBail')[1]
        assert_eq(a.args[1], 1)
        assert_eq(a.args[2], PAYER)
        TriggerEvent('pf-justice:server:bailChanged', { id = 1, orderId = res.jailOrderId, payerCid = 'PAY3', payerName = 'Pay Er', state = 'posted' },
            { from = 'accepted', to = 'posted' })
        assert_eq(DB.sentences[res.id].bailed, 1)
        assert_eq(DB.sentences[res.id].bailPaidByCitizenId, 'PAY3')
        -- the offer was used: a second /bailaccept has nothing to pay
        Mock.gameTimer = Mock.gameTimer + 10000
        Commands.bailaccept(PAYER)
        assert_eq(#called('AcceptBail'), 1)
    end)
    it('a refusal the payer can fix keeps the offer; pf-justice\'s message reaches them', function()
        jailed()
        Mock.callCallback('pf_mdt:postBail', OFFICER, { prisonerCitizenId = 'CID2', payerCitizenId = 'PAY3' })
        JU.accept = { ok = false, error = 'too_far', message = 'You must be with the officer or at a bail desk' }
        Commands.bailaccept(PAYER)
        local n = Mock.clientEventsNamed('QBCore:Notify')
        assert_eq(n[#n].args[1], 'You must be with the officer or at a bail desk')
        JU.accept = { ok = true, state = 'posted' }
        Mock.gameTimer = Mock.gameTimer + 10000
        Commands.bailaccept(PAYER)
        assert_eq(#called('AcceptBail'), 2)
    end)
    it('/baildecline is DeclineBail', function()
        jailed()
        Mock.callCallback('pf_mdt:postBail', OFFICER, { prisonerCitizenId = 'CID2', payerCitizenId = 'PAY3' })
        Commands.baildecline(PAYER)
        assert_eq(called('DeclineBail')[1].args[1], 1)
        assert_eq(called('DeclineBail')[1].args[2], PAYER)
    end)
    it('an order imported from the old jail gets no new offer; its open pf-justice offer is passed on as it is', function()
        JU.orders[8] = { id = 8, cid = 'CID2', kind = 'jail', state = 'active', remainingSeconds = 300, legacyRef = 'mdt_jail:11',
            sourceRef = { type = 'mdt_sentence', id = '501' } }
        JU.nextOrder = 8
        local r = Mock.callCallback('pf_mdt:postBail', OFFICER, { prisonerCitizenId = 'CID2', payerCitizenId = 'PAY3' })
        assert_eq(r.success, false)
        assert_eq(#called('OfferBail'), 0)
        JU.bails[1] = { id = 1, orderId = 8, amount = 700, state = 'offered', expiresAt = Mock.clock + 1000 }
        JU.nextBail = 1
        Mock.gameTimer = Mock.gameTimer + 10000
        r = Mock.callCallback('pf_mdt:postBail', OFFICER, { prisonerCitizenId = 'CID2', payerCitizenId = 'PAY3' })
        assert_eq(r.success, true, tostring(r.error))
        assert_eq(#called('OfferBail'), 0)
        assert_eq(sentTo('pf_mdt:client:BailOffer', PAYER)[1].args[1].amount, 700)
    end)
    it('no bail for a citizen without an open order, or a sentence without a bail amount', function()
        assert_eq(Mock.callCallback('pf_mdt:postBail', OFFICER, { prisonerCitizenId = 'CID2', payerCitizenId = 'PAY3' }).success, false)
        CHARGES.J1.bailAmount = 0
        jailed()
        Mock.gameTimer = Mock.gameTimer + 10000
        local r = Mock.callCallback('pf_mdt:postBail', OFFICER, { prisonerCitizenId = 'CID2', payerCitizenId = 'PAY3' })
        CHARGES.J1.bailAmount = 500
        assert_eq(r.success, false)
        assert_eq(r.error, 'No bail amount for this sentence')
        assert_eq(#called('OfferBail'), 0)
    end)
end)

describe('pf-justice events and recovery', function()
    it('a fine order paid later marks the sentence paid', function()
        JU.pay = { ok = false, error = 'insufficient_funds', state = 'invoiced' }
        local res = sentence({ 'F1' }, 'fine')
        assert_eq(DB.sentences[res.id].fineSuccess, 0)
        TriggerEvent('pf-justice:server:paymentSettled', { id = 1, kind = 'fine', sourceRef = { type = 'mdt_sentence', id = tostring(res.id) } }, 'paid')
        assert_eq(DB.sentences[res.id].fineSuccess, 1)
    end)
    it('a sentence cut off mid-way is settled from what pf-justice holds for it', function()
        DB.nextSentence = 4
        DB.sentences[4] = { id = 4, citizenId = 'CID2', status = 'ju_pending', stale = true, fineAmount = 300, prisonTime = 10 }
        JU.orders[1] = { id = 1, cid = 'CID2', kind = 'fine', state = 'paid', sourceRef = { type = 'mdt_sentence', id = '4' } }
        S.RecoverJusticeSentences()
        local r = DB.sentences[4]
        assert_eq(r.status, 'done')
        assert_eq(r.fineSuccess, 1)
        assert_eq(r.jailSuccess, 0)
        assert_true(r.error:find('jail time', 1, true) ~= nil)
        DB.sentences[5] = { id = 5, citizenId = 'CID2', status = 'ju_pending', stale = true, fineAmount = 0, prisonTime = 10 }
        S.RecoverJusticeSentences()
        assert_eq(DB.sentences[5].status, 'failed')
        assert_eq(#called('CreateOrder'), 0, 'nothing is issued afterwards')
    end)
end)

describe('legacy bail held in the MDT\'s fines account', function()
    it('moves once to pf-justice\'s bail account when pf-justice took the payment over', function()
        DB.jails[13] = { id = 13, citizenid = 'MDTC', bail_key = 'pf-policemdt:bail:13:1-1' }
        ledger.tx['pf-policemdt:bail:13:1-1'] = { state = 'completed', amount = 700, to_account = 'society:police' }
        S.SettleLegacyBailMoves()
        assert_eq(#ledger.transfers, 1)
        local t = ledger.transfers[1]
        assert_eq(t.from, 'society:police')
        assert_eq(t.to, 'society:doj')
        assert_eq(t.amount, 700)
        assert_eq(t.key, 'pf-policemdt:bailmove:13:1')
        S.SettleLegacyBailMoves()
        assert_eq(#ledger.transfers, 1, 'once')
        assert_eq(DB.writesToJails, 0, 'the legacy row is only read')
    end)
    it('a clearly refused move goes to the next key; a payment that never went through moves nothing', function()
        DB.jails[14] = { id = 14, citizenid = 'MDTD', bail_key = 'pf-policemdt:bail:14:1-1' }
        DB.jails[15] = { id = 15, citizenid = 'MDTE', bail_key = 'pf-policemdt:bail:15:1-1' }
        ledger.tx['pf-policemdt:bail:14:1-1'] = { state = 'completed', amount = 200, to_account = 'society:police' }
        ledger.tx['pf-policemdt:bail:15:1-1'] = { state = 'failed', error = 'insufficient_funds' }
        ledger.next = { ok = false, error = 'insufficient_funds' }
        S.SettleLegacyBailMoves()
        ledger.next = nil
        S.SettleLegacyBailMoves()
        assert_eq(#ledger.transfers, 2)
        assert_eq(ledger.transfers[1].key, 'pf-policemdt:bailmove:14:1')
        assert_eq(ledger.transfers[2].key, 'pf-policemdt:bailmove:14:2')
        for _, t in ipairs(ledger.transfers) do assert_true(t.key:find(':15:', 1, true) == nil, 'nothing for the failed bail') end
    end)
end)

describe('commands', function()
    it('the MDT registers no /unjail after the hand-over (pfm-policejob\'s is the one)', function()
        assert_eq(Commands.unjail, nil)
        assert_true(Commands.bailaccept ~= nil and Commands.baildecline ~= nil)
    end)
    it('while the MDT runs its own jail, its /unjail is still there', function()
        justiceFile = JUSTICE_CONFIG:format('true')
        Config.Sentencing.Justice.Runtime = 'legacy'
        load_resource('[pfscripts]/pf-policemdt-DEV/server/sentencing.lua')
        assert_true(Commands.unjail ~= nil)
    end)
end)
