-- pfm-phone invoices are paid exactly once across any crash, and the money taken from the payer
-- always reaches the business:
--   (a) a charge the ledger recovered as failed 'interrupted_unverified' is unclear: the invoice
--       waits (in_progress) and is never charged under a new key until it is reconciled;
--   (b) an invoice with a completed, pending or debited charge is not declined;
--   (c) the row stays (pay_state 'paying', hidden from the phone) and is not reported paid until the
--       business and the commission are credited; each payout has numbered keys of its own, and the
--       sweep finishes a half-paid invoice;
--   (d) after a crash between the payouts and the delete, the events and mails go out exactly once;
--   (e) a row without a token is checked against its id keys before it is given one.
-- Second round: the sweep pages past rows that wait for good; 5 and 5.0 share one lock; a business
-- the bank refuses is never charged for; in id-key mode a payout counts only after this charge; no
-- commission mail for a commission that was dropped.
load_resource('tests/lua/ledger_env.lua')

local invoices = {}       -- [id] = row
local nextId = 1
local hasToken, hasPayState, uuidDefault = true, true, true
local adds = {}           -- [column] = ALTER ADD COLUMN count
local mails = {}          -- { cid, subject } of every mail pfm-phone sent
local afterTx             -- runs once right after the next ledger key lookup (a database yield in FiveM)
local onTx                -- runs once before it

local function copy(t) local c = {} for k, v in pairs(t) do c[k] = v end return c end
local function affected(n) return { affectedRows = n } end
local function mine(p) local row = invoices[tonumber(p[2])] return row and row.citizenid == p[3] and row or nil end

-- the ALTERs, [3] and [4] below; a spec may swap in failing ones, BeforeEach puts these back
local ADD_TOKEN = { 'ADD COLUMN `ledger_token`', function() adds.ledger_token = (adds.ledger_token or 0) + 1 hasToken = true return {} end }
local ADD_PAY_STATE = { 'ADD COLUMN `pay_state`', function() adds.pay_state = (adds.pay_state or 0) + 1 hasPayState = true return {} end }

FakeDB.extraPatterns = {
    { 'INSERT INTO player_mails', function(p) mails[#mails + 1] = { cid = p[1], subject = p[3] } return 1 end },
    { 'information_schema.COLUMNS', function()
        local out = {}
        if hasToken then out[#out + 1] = { name = 'ledger_token', def = uuidDefault and 'uuid()' or nil } end
        if hasPayState then out[#out + 1] = { name = 'pay_state', def = nil } end
        return out
    end },
    ADD_TOKEN,
    ADD_PAY_STATE,
    { 'SET DEFAULT (UUID())', function() uuidDefault = true return {} end },
    { 'INSERT INTO phone_invoices', function(p)
        local id = nextId
        nextId = nextId + 1
        invoices[id] = { id = id, citizenid = p[1], amount = p[2], society = p[3], sender = p[4], sendercitizenid = p[5],
            candecline = p[6] or 1, reason = p[7], ledger_token = p[8] }
        return id
    end },
    { 'SELECT * FROM phone_invoices WHERE id = ? AND citizenid = ?', function(p)
        local row = invoices[tonumber(p[1])]
        return (row and row.citizenid == p[2]) and { copy(row) } or {}
    end },
    { 'SELECT * FROM phone_invoices WHERE citizenid = ?', function(p)
        local out = {}
        for _, r in pairs(invoices) do if r.citizenid == p[1] then out[#out + 1] = copy(r) end end
        return out
    end },
    { "SELECT id, citizenid FROM phone_invoices WHERE pay_state = 'paying' AND id > ? ORDER BY id LIMIT 50", function(p)
        local out = {}
        for _, r in pairs(invoices) do
            if r.pay_state == 'paying' and r.id > p[1] then out[#out + 1] = { id = r.id, citizenid = r.citizenid } end
        end
        table.sort(out, function(a, b) return a.id < b.id end)
        for i = #out, 51, -1 do out[i] = nil end -- LIMIT 50 (SWEEP_BATCH)
        return out
    end },
    { "UPDATE phone_invoices SET pay_state = 'paying' WHERE id = ? AND citizenid = ? AND pay_state IS NULL", function(p)
        local row = invoices[tonumber(p[1])]
        if row and row.citizenid == p[2] and row.pay_state == nil then row.pay_state = 'paying' return affected(1) end
        return affected(0)
    end },
    { "UPDATE phone_invoices SET pay_state = NULL WHERE id = ? AND citizenid = ? AND pay_state = 'paying'", function(p)
        local row = invoices[tonumber(p[1])]
        if row and row.citizenid == p[2] and row.pay_state == 'paying' then row.pay_state = nil return affected(1) end
        return affected(0)
    end },
    { 'UPDATE phone_invoices SET ledger_token = ? WHERE id = ? AND citizenid = ? AND (ledger_token IS NULL OR ledger_token = ?)', function(p)
        local row = mine(p)
        if row and (row.ledger_token == nil or row.ledger_token == p[4]) then row.ledger_token = p[1] return affected(1) end
        return affected(0)
    end },
    { 'DELETE FROM phone_invoices WHERE id = ? AND citizenid = ?', function(p)
        local row = invoices[tonumber(p[1])]
        if row and row.citizenid == p[2] then invoices[row.id] = nil return affected(1) end
        return affected(0)
    end },
    { 'and candecline = ? AND pay_state IS NULL', function(p)
        local row = invoices[tonumber(p[1])]
        if row and row.citizenid == p[2] and row.candecline == p[3] and row.pay_state == nil then invoices[row.id] = nil return 1 end
        return 0
    end },
    { 'SELECT charinfo FROM players WHERE citizenid = ?', function() return nil end },
    { 'SELECT * FROM players WHERE citizenid = ?', function() return {} end },
}

local FILES = { 'pfm-phone/config.lua', 'pfm-phone/server/main.lua' }

local function load()
    LedgerEnv.load('pfm-phone', FILES)
    Mock.exportsByResource['pfm-phone'] = { sendNewMailToOffline = function(_, cid, m) mails[#mails + 1] = { cid = cid, subject = m.subject } end }
    Mock.exportsByResource['pf-citizen'] = nil
    Config.BillingCommissions = {}
    local bank = Mock.exportsByResource['pfm-banking']
    bank.GetTransaction = function(_, key)
        local before = onTx
        onTx = nil
        if before then before() end
        local tx = PFLedger.GetTransaction(key)
        local after = afterTx
        afterTx = nil
        if after then after(key) end
        return tx
    end
end

local A, BILLER = 1, 2
local function bank() return Mock.players[A].PlayerData.money.bank end
local function police() return FakeDB.bank_accounts['police'].account_balance end
local function pay(id) return Mock.selfExport('PayInvoice')(A, id) end
local function decline(id) return Mock.selfExport('DeclineInvoice')(A, id) end
local function sweep() return PFPhoneInvoices.Sweep() end
local function create(amount, society)
    return Mock.selfExport('CreateInvoice')({ citizenid = 'CID1', amount = amount or 500, society = society or 'police', sender = 'Officer', sendercitizenid = 'CID2' })
end
local bases = {} -- remembered, as the row goes once it is paid
local function base(id)
    if invoices[id] then bases[id] = 'pfm-phone:invoice:tok:' .. invoices[id].ledger_token end
    return bases[id]
end
local function tx(key) return FakeDB.byKey[key] end
local function events(name, outcome)
    local n = 0
    for _, e in ipairs(Mock.serverEvents) do
        if e.name == name and (outcome == nil or e.args[2] == outcome) then n = n + 1 end
    end
    return n
end
local function paidEvents() return events('pfm-phone:server:invoiceSettled', 'paid') end
local function mailsAbout(subject)
    local n = 0
    for _, m in ipairs(mails) do if m.subject == subject then n = n + 1 end end
    return n
end
local function charges(prefix)
    local n = 0
    for _, row in ipairs(LedgerEnv.paid(prefix)) do
        if tostring(row.idempotency_key):sub(-5) == ':bank' then n = n + 1 end
    end
    return n
end
local function ledgerRows(prefix)
    local n = 0
    for k in pairs(FakeDB.byKey) do if k:sub(1, #prefix) == prefix then n = n + 1 end end
    return n
end
local function recover()
    local p, d = PFLedger.STALE_PENDING_SECONDS, PFLedger.STALE_DEBITED_SECONDS
    PFLedger.STALE_PENDING_SECONDS, PFLedger.STALE_DEBITED_SECONDS = -1, -1
    PFLedger.Recover()
    PFLedger.STALE_PENDING_SECONDS, PFLedger.STALE_DEBITED_SECONDS = p, d
end
local function listed()
    local got
    Mock.callbacks['qb-phone:server:GetInvoices'](A, function(list) got = list end)
    return got
end
-- the payer's charge made on attempt 1, then left in `state` as a crash would
local function charge(id, state, amount)
    local key = base(id) .. ':bank'
    assert_eq(PFLedger.Transfer({ from = 'player:CID1:bank', to = 'system:pfm-phone', amount = amount or 500, key = key, kind = 'purchase' }).ok, true)
    if state then tx(key).state = state end
    return key
end
-- the business credit stored on `key` and left pending, as a crash before it moved would
local function pendingSociety(key, amount)
    assert_eq(PFLedger.Transfer({ from = 'system:pfm-phone', to = 'society:police', amount = amount or 500, key = key, kind = 'deposit' }).ok, true)
    tx(key).state = 'pending'
    FakeDB.bank_accounts['police'].account_balance = FakeDB.bank_accounts['police'].account_balance - (amount or 500)
end

BeforeEach = function()
    FakeDB.extraPatterns[3], FakeDB.extraPatterns[4] = ADD_TOKEN, ADD_PAY_STATE
    Mock.reset()
    LedgerEnv.reset()
    invoices, nextId, mails, onTx, afterTx, bases = {}, 1, {}, nil, nil, {}
    hasToken, hasPayState, uuidDefault, adds = true, true, true, {}
    load()
    Mock.clock = Mock.clock + 1000
    Mock.players = {}
    Mock.newPlayer(A).PlayerData.money = { cash = 0, bank = 2000 }
    local b = Mock.newPlayer(BILLER)
    b.PlayerData.job = { name = 'police' }
    b.PlayerData.money = { cash = 0, bank = 0 }
    FakeDB.society('police', 0)
end

describe('(a) a charge recovered as interrupted_unverified', function()
    it('is unclear: the invoice waits and is never charged under a new key', function()
        local id = create()
        local key = charge(id, 'pending') -- the online payer's money left, the state write never landed
        assert_eq(bank(), 1500)
        recover()
        assert_eq(tx(key).state, 'failed')
        assert_eq(tx(key).error, 'interrupted_unverified')
        local ok, err = pay(id)
        assert_eq(ok, false)
        assert_eq(err, 'in_progress')
        assert_eq(bank(), 1500)
        assert_true(tx(base(id) .. ':retry2:bank') == nil, 'charged again on the next key')
        assert_eq(invoices[id].pay_state, 'paying')
        assert_eq(#listed(), 0)                       -- not offered to the phone meanwhile
        assert_eq(select(2, decline(id)), 'in_progress')
        assert_eq(sweep(), 0)
        load() -- a restart changes nothing
        assert_eq(select(2, pay(id)), 'in_progress')
        assert_eq(bank(), 1500)
        assert_eq(ledgerRows(base(id)), 1)
        assert_eq(police(), 0)
    end)
    it('the same when the charge itself answers failed / interrupted_unverified (res.state)', function()
        local id = create()
        local key = base(id) .. ':bank'
        -- the lookup finds nothing; recovery on another server stores the attempt as unverified meanwhile
        afterTx = function()
            FakeDB.transactions[#FakeDB.transactions + 1] = { id = #FakeDB.transactions + 1, tx_id = 'TXU1', idempotency_key = key, kind = 'purchase',
                from_account = 'player:CID1:bank', to_account = 'system:pfm-phone', amount = 500, state = 'failed', error = 'interrupted_unverified',
                created_at = Mock.clock, updated_at = Mock.clock }
            FakeDB.byKey[key] = FakeDB.transactions[#FakeDB.transactions]
            FakeDB.byTxId.TXU1 = FakeDB.byKey[key]
        end
        local ok, err = pay(id)
        assert_eq(ok, false)
        assert_eq(err, 'in_progress')
        assert_eq(bank(), 2000)
        assert_true(tx(base(id) .. ':retry2:bank') == nil, 'charged again on the next key')
        assert_eq(invoices[id].pay_state, 'paying')
        assert_eq(select(2, pay(id)), 'in_progress')
    end)
    it('once reconciled as not taken, the invoice opens and the next key charges once', function()
        local id = create()
        local key = charge(id, 'pending')
        Mock.players[A].PlayerData.money.bank = 2000 -- this time the money never left
        recover()
        assert_eq(select(2, pay(id)), 'in_progress')
        tx(key).error = 'checked_not_taken'           -- an admin settles the transfer
        assert_eq(sweep(), 1)
        assert_eq(invoices[id].pay_state, nil)
        assert_eq(#listed(), 1)
        assert_eq(pay(id), true)
        assert_eq(bank(), 1500)
        assert_eq(police(), 500)
        assert_eq(tx(base(id) .. ':retry2:bank').state, 'completed')
        assert_eq(charges(base(id)), 1)
    end)
    it('once reconciled as taken, the sweep settles it without a new charge', function()
        local id = create()
        local key = charge(id, 'pending')
        recover()
        assert_eq(select(2, pay(id)), 'in_progress')
        tx(key).state, tx(key).error = 'completed', nil -- the admin confirms the money left and completes it
        assert_eq(sweep(), 1)
        assert_eq(invoices[id], nil)
        assert_eq(bank(), 1500)
        assert_eq(police(), 500)
        assert_eq(paidEvents(), 1)
    end)
end)

describe('(b) declining an invoice the payer was charged for', function()
    it('a completed charge is not declined: the payment is finished instead', function()
        local id = create()
        charge(id) -- charged, then the server stopped before the payouts
        local ok, err = decline(id)
        assert_eq(ok, false)
        assert_eq(err, 'not_open')
        assert_eq(invoices[id], nil)
        assert_eq(police(), 500)                      -- the business is paid
        assert_eq(bank(), 1500)                       -- the payer only once
        assert_eq(events('pfm-phone:server:invoiceSettled', 'declined'), 0)
        assert_eq(paidEvents(), 1)
    end)
    it('a debited charge is not declined; it is settled once the ledger completes it', function()
        local id = create()
        local key = charge(id, 'debited')
        assert_eq(select(2, pay(id)), 'in_progress')
        local ok, err = decline(id)
        assert_eq(ok, false)
        assert_eq(err, 'in_progress')
        assert_true(invoices[id] ~= nil)
        recover()
        assert_eq(tx(key).state, 'completed')
        assert_eq(sweep(), 1)
        assert_eq(police(), 500)
        assert_eq(bank(), 1500)
        assert_eq(events('pfm-phone:server:invoiceSettled', 'declined'), 0)
        assert_eq(paidEvents(), 1)
    end)
    it('a pending charge is not declined', function()
        local id = create()
        charge(id, 'pending')
        local ok, err = decline(id)
        assert_eq(ok, false)
        assert_eq(err, 'in_progress')
        assert_true(invoices[id] ~= nil)
        assert_eq(events('pfm-phone:server:invoiceSettled', 'declined'), 0)
    end)
    it('a later attempt key counts too', function()
        local id = create()
        Mock.players[A].PlayerData.money.bank = 100
        assert_eq(select(2, pay(id)), 'insufficient_funds')
        assert_eq(select(2, pay(id)), 'insufficient_funds')
        Mock.players[A].PlayerData.money.bank = 2000
        assert_eq(PFLedger.Transfer({ from = 'player:CID1:bank', to = 'system:pfm-phone', amount = 500, key = base(id) .. ':retry3:bank', kind = 'purchase' }).ok, true)
        load() -- a restart: the walk starts at attempt 1 again
        assert_eq(select(2, decline(id)), 'not_open')
        assert_eq(police(), 500)
        assert_eq(bank(), 1500)
    end)
    it('an invoice with only failed attempts is declined once', function()
        local id = create()
        Mock.players[A].PlayerData.money.bank = 100
        assert_eq(select(2, pay(id)), 'insufficient_funds')
        assert_eq(invoices[id].pay_state, nil)
        assert_eq(decline(id), true)
        assert_eq(invoices[id], nil)
        assert_eq(events('pfm-phone:server:invoiceSettled', 'declined'), 1)
        assert_eq(mailsAbout('Invoice Declined'), 1)
        assert_eq(select(2, decline(id)), 'not_declinable')
    end)
end)

describe('(c) the business and the commission before the invoice goes', function()
    it('a business credit cut off by a crash keeps the invoice; the sweep pays it once on the next key', function()
        local id = create()
        charge(id)
        pendingSociety(base(id) .. ':society')
        local ok, err = pay(id)
        assert_eq(ok, false)                          -- not reported paid
        assert_eq(err, 'in_progress')
        assert_eq(invoices[id].pay_state, 'paying')
        assert_eq(paidEvents(), 0)
        assert_eq(bank(), 1500)
        assert_eq(#listed(), 0)
        recover()                                     -- system source: 'failed' / 'interrupted', nothing moved
        assert_eq(tx(base(id) .. ':society').state, 'failed')
        assert_eq(sweep(), 1)
        assert_eq(police(), 500)
        assert_eq(tx(base(id) .. ':society:retry2').state, 'completed')
        assert_eq(tx(base(id) .. ':society').state, 'failed')
        assert_eq(invoices[id], nil)
        assert_eq(paidEvents(), 1)
        assert_eq(bank(), 1500)
        assert_eq(charges(base(id)), 1)
    end)
    it('a refunded business credit is never reused: the next payment pays on a new key', function()
        local id = create()
        charge(id)
        local skey = base(id) .. ':society'
        assert_eq(PFLedger.Transfer({ from = 'system:pfm-phone', to = 'society:police', amount = 500, key = skey, kind = 'deposit' }).ok, true)
        tx(skey).state, tx(skey).error = 'compensated', 'unknown_account'
        FakeDB.bank_accounts['police'].account_balance = 0
        assert_eq(pay(id), true)
        assert_eq(police(), 500)
        assert_eq(tx(skey .. ':retry2').state, 'completed')
        assert_eq(bank(), 1500)
    end)
    it('a business the bank cannot hold money for is not charged for: the invoice stays open', function()
        -- a row another resource inserted for an account that does not exist (CreateInvoice refuses it)
        invoices[5] = { id = 5, citizenid = 'CID1', amount = 300, society = 'nobody', sendercitizenid = '', candecline = 1, ledger_token = 'tok5' }
        local ok, err = pay(5)
        assert_eq(ok, false)
        assert_eq(err, 'unknown_society')
        assert_eq(bank(), 2000)
        assert_eq(ledgerRows('pfm-phone:invoice:tok:tok5'), 0)
        assert_eq(invoices[5].pay_state, nil)
        assert_eq(#listed(), 1)
        assert_eq(Mock.callCallback('qb-phone:server:PayInvoice', A, nil, nil, 5), 'unknown_society') -- the phone says why
        FakeDB.society('nobody', 0)                   -- once the account exists it is paid normally
        assert_eq(pay(5), true)
        assert_eq(bank(), 1700)
        assert_eq(FakeDB.bank_accounts['nobody'].account_balance, 300)
    end)
    it('a charged invoice whose business cannot take the money stays paying; the sweep backs off, then pays it', function()
        -- charged while the account existed, then the account went before the business credit
        invoices[5] = { id = 5, citizenid = 'CID1', amount = 300, society = 'nobody', sendercitizenid = '', candecline = 1, ledger_token = 'tok5' }
        local b5 = 'pfm-phone:invoice:tok:tok5'
        assert_eq(PFLedger.Transfer({ from = 'player:CID1:bank', to = 'system:pfm-phone', amount = 300, key = b5 .. ':bank', kind = 'purchase' }).ok, true)
        local ok, err = pay(5)
        assert_eq(ok, false)
        assert_eq(err, 'in_progress')
        assert_eq(bank(), 1700)
        assert_eq(tx(b5 .. ':society').state, 'compensated')
        local rows = ledgerRows(b5)
        assert_eq(sweep(), 0)                         -- tried: a new key, refused again
        assert_eq(tx(b5 .. ':society:retry2').state, 'compensated')
        rows = ledgerRows(b5)
        assert_eq(sweep(), 0)                         -- backing off: no new ledger row
        assert_eq(ledgerRows(b5), rows)
        FakeDB.society('nobody', 0)                   -- the account is set up
        Mock.gameTimer = Mock.gameTimer + 10 * 60000
        assert_eq(sweep(), 1)
        assert_eq(FakeDB.bank_accounts['nobody'].account_balance, 300)
        assert_eq(invoices[5], nil)
        assert_eq(bank(), 1700)
        assert_eq(paidEvents(), 1)
    end)
    it('CreateInvoice refuses a business the bank cannot hold money for', function()
        local id, err = create(100, 'nobody')
        assert_eq(id, nil)
        assert_eq(err, 'unknown_society')
    end)
    it('an unclear commission keeps the invoice until it is paid once', function()
        Config.BillingCommissions = { police = 0.1 }
        local id = create()
        charge(id)
        local ckey = base(id) .. ':commission'
        assert_eq(PFLedger.Transfer({ from = 'system:pfm-phone', to = 'player:CID2:bank', amount = 50, key = ckey, kind = 'wage' }).ok, true)
        tx(ckey).state = 'pending'
        Mock.players[BILLER].PlayerData.money.bank = 0
        assert_eq(select(2, pay(id)), 'in_progress')
        assert_eq(police(), 500)
        assert_eq(invoices[id].pay_state, 'paying')
        assert_eq(mailsAbout('Commission Received'), 0)
        recover()
        assert_eq(sweep(), 1)
        assert_eq(Mock.players[BILLER].PlayerData.money.bank, 50)
        assert_eq(tx(ckey .. ':retry2').state, 'completed')
        assert_eq(invoices[id], nil)
        assert_eq(mailsAbout('Commission Received'), 1)
        assert_eq(paidEvents(), 1)
        assert_eq(police(), 500)
    end)
    it('a commission for a character that no longer exists does not hold the invoice, and sends no commission mail', function()
        Config.BillingCommissions = { police = 0.1 }
        local id = Mock.selfExport('CreateInvoice')({ citizenid = 'CID1', amount = 500, society = 'police', sender = 'Gone', sendercitizenid = 'GONE' })
        base(id)
        assert_eq(pay(id), true)
        assert_eq(police(), 500)
        assert_eq(tx(base(id) .. ':commission').state, 'compensated')
        assert_eq(invoices[id], nil)
        assert_eq(mailsAbout('Commission Received'), 0)
        assert_eq(mailsAbout('Invoice Paid'), 1)
        assert_eq(paidEvents(), 1)
    end)
    it('a dropped commission found after a crash sends no commission mail either', function()
        Config.BillingCommissions = { police = 0.1 }
        local id = Mock.selfExport('CreateInvoice')({ citizenid = 'CID1', amount = 500, society = 'police', sender = 'Gone', sendercitizenid = 'GONE' })
        charge(id)
        assert_eq(PFPayout.PaySociety('police', 500, { key = base(id) .. ':society' }), true)
        assert_eq(PFPayout.Pay('GONE', 'bank', 50, { key = base(id) .. ':commission' }), false)
        assert_eq(tx(base(id) .. ':commission').error, 'unknown_account')
        invoices[id].pay_state = 'paying'
        load() -- the restart forgets the attempt hints: the walk finds the refused commission
        Config.BillingCommissions = { police = 0.1 }
        assert_eq(sweep(), 1)
        assert_eq(invoices[id], nil)
        assert_eq(mailsAbout('Commission Received'), 0)
        assert_eq(paidEvents(), 1)
        assert_true(tx(base(id) .. ':commission:retry2') == nil, 'paid a deleted character on a new key')
    end)
    it('the payer is told the payment was taken while the business is being credited', function()
        local id = create()
        charge(id)
        pendingSociety(base(id) .. ':society')
        assert_eq(Mock.callCallback('qb-phone:server:PayInvoice', A, nil, nil, id), 'in_progress')
        local told = false
        for _, e in ipairs(Mock.clientEventsNamed('QBCore:Notify')) do
            if tostring(e.args[1]):find('payment was received', 1, true) then told = true end
        end
        assert_true(told)
    end)
end)

describe('(d) a crash between the payouts and the delete', function()
    it('the sweep removes the row and reports it paid exactly once', function()
        Config.BillingCommissions = { police = 0.1 }
        local id = create()
        charge(id)
        assert_eq(PFPayout.PaySociety('police', 500, { key = base(id) .. ':society' }), true)
        assert_eq(PFPayout.Pay('CID2', 'bank', 50, { key = base(id) .. ':commission' }), true)
        invoices[id].pay_state = 'paying'
        assert_eq(sweep(), 1)
        assert_eq(invoices[id], nil)
        assert_eq(paidEvents(), 1)
        assert_eq(events('qb-phone:server:paidInvoice'), 1)
        assert_eq(mailsAbout('Invoice Paid'), 1)
        assert_eq(mailsAbout('Commission Received'), 1)
        assert_eq(police(), 500)
        assert_eq(bank(), 1500)
        assert_eq(sweep(), 0)
        assert_eq(paidEvents(), 1)
    end)
    it('paying again does the same', function()
        local id = create()
        charge(id)
        assert_eq(PFPayout.PaySociety('police', 500, { key = base(id) .. ':society' }), true)
        assert_eq(pay(id), true)
        assert_eq(paidEvents(), 1)
        assert_eq(mailsAbout('Invoice Paid'), 1)
        assert_eq(select(2, pay(id)), 'not_found')
        assert_eq(paidEvents(), 1)
    end)
end)

describe('(e) a row without a token', function()
    it("whose id key holds this payer's completed charge is not charged again, and keeps its id keys", function()
        assert_eq(PFLedger.Transfer({ from = 'player:CID1:bank', to = 'system:pfm-phone', amount = 500, key = 'pfm-phone:invoice:42:bank', kind = 'purchase' }).ok, true)
        invoices[42] = { id = 42, citizenid = 'CID1', amount = 500, society = 'police', sendercitizenid = '', candecline = 1 }
        assert_eq(pay(42), true)
        assert_eq(bank(), 1500)
        assert_eq(police(), 500)
        assert_eq(tx('pfm-phone:invoice:42:society').state, 'completed')
        assert_eq(invoices[42], nil)
        assert_eq(paidEvents(), 1)
    end)
    it('whose id key holds a charge the ledger has not settled waits, with no token and no new key', function()
        for _, state in ipairs({ 'pending', 'debited', 'interrupted_unverified' }) do
            LedgerEnv.reset()
            load()
            FakeDB.society('police', 0)
            Mock.players[A].PlayerData.money.bank = 2000
            assert_eq(PFLedger.Transfer({ from = 'player:CID1:bank', to = 'system:pfm-phone', amount = 500, key = 'pfm-phone:invoice:43:bank', kind = 'purchase' }).ok, true)
            if state == 'interrupted_unverified' then
                tx('pfm-phone:invoice:43:bank').state, tx('pfm-phone:invoice:43:bank').error = 'failed', state
            else
                tx('pfm-phone:invoice:43:bank').state = state
            end
            invoices[43] = { id = 43, citizenid = 'CID1', amount = 500, society = 'police', sendercitizenid = '', candecline = 1 }
            assert_eq(select(2, pay(43)), 'in_progress', state)
            assert_eq(select(2, decline(43)), 'in_progress', state)
            assert_eq(invoices[43].ledger_token, nil, state)
            assert_true(tx('pfm-phone:invoice:43:retry2:bank') == nil, state)
            assert_eq(bank(), 1500, state)
            assert_eq(ledgerRows('pfm-phone:invoice:tok:'), 0, state)
        end
    end)
    it('a declined row whose id key holds this payer\'s charge is paid instead', function()
        assert_eq(PFLedger.Transfer({ from = 'player:CID1:bank', to = 'system:pfm-phone', amount = 500, key = 'pfm-phone:invoice:44:bank', kind = 'purchase' }).ok, true)
        invoices[44] = { id = 44, citizenid = 'CID1', amount = 500, society = 'police', sendercitizenid = '', candecline = 1 }
        assert_eq(select(2, decline(44)), 'not_open')
        assert_eq(police(), 500)
        assert_eq(bank(), 1500)
    end)
    it('with no charge of its own there gets a token first and is charged on it', function()
        -- an older invoice of someone else under id 45 was paid on the id key
        FakeDB.players.CIDX = { money = { bank = 1000, cash = 0 } }
        assert_eq(PFLedger.Transfer({ from = 'player:CIDX:bank', to = 'system:pfm-phone', amount = 500, key = 'pfm-phone:invoice:45:bank', kind = 'purchase' }).ok, true)
        invoices[45] = { id = 45, citizenid = 'CID1', amount = 500, society = 'police', sendercitizenid = '', candecline = 1 }
        assert_eq(pay(45), true)
        assert_eq(bank(), 1500)                       -- charged for this invoice
        assert_eq(police(), 500)                      -- and the business paid for it
        assert_eq(charges('pfm-phone:invoice:tok:'), 1)
        assert_true(tx('pfm-phone:invoice:45:retry2:bank') == nil, 'charged on the id keys')
        assert_true(invoices[45] == nil)
    end)
    it('a token is given only once the id keys show no charge of its own', function()
        invoices[46] = { id = 46, citizenid = 'CID1', amount = 500, society = 'police', sendercitizenid = '', candecline = 1 }
        Mock.players[A].PlayerData.money.bank = 100
        assert_eq(select(2, pay(46)), 'insufficient_funds')
        local token = invoices[46].ledger_token
        assert_true(type(token) == 'string' and token ~= '')
        assert_true(tx('pfm-phone:invoice:tok:' .. token .. ':bank').state == 'failed')
        assert_true(tx('pfm-phone:invoice:46:bank') == nil)
        Mock.players[A].PlayerData.money.bank = 2000
        assert_eq(pay(46), true)
        assert_eq(invoices[46], nil)
        assert_eq(bank(), 1500)
        assert_eq(tx('pfm-phone:invoice:tok:' .. token .. ':retry2:bank').state, 'completed')
    end)
    it('without the token column the id keys are used, skipping a charge of another payer there', function()
        hasToken, hasPayState = false, false
        FakeDB.extraPatterns[3] = { 'ADD COLUMN `ledger_token`', function() error('ALTER command denied') end }
        FakeDB.extraPatterns[4] = { 'ADD COLUMN `pay_state`', function() error('ALTER command denied') end }
        load()
        FakeDB.players.CIDX = { money = { bank = 1000, cash = 0 } }
        assert_eq(PFLedger.Transfer({ from = 'player:CIDX:bank', to = 'system:pfm-phone', amount = 500, key = 'pfm-phone:invoice:47:bank', kind = 'purchase' }).ok, true)
        invoices[47] = { id = 47, citizenid = 'CID1', amount = 500, society = 'police', sendercitizenid = '', candecline = 1 }
        assert_eq(pay(47), true)
        assert_eq(bank(), 1500)
        assert_eq(tx('pfm-phone:invoice:47:retry2:bank').state, 'completed')
        assert_eq(invoices[47], nil)
    end)
    it("without the token column, an older invoice's payouts under the same id do not count for this one", function()
        hasToken, hasPayState = false, false
        FakeDB.extraPatterns[3] = { 'ADD COLUMN `ledger_token`', function() error('ALTER command denied') end }
        FakeDB.extraPatterns[4] = { 'ADD COLUMN `pay_state`', function() error('ALTER command denied') end }
        load()
        Config.BillingCommissions = { police = 0.1 }
        FakeDB.players.CIDX = { money = { bank = 1000, cash = 0 } }
        -- the old invoice 47 of CIDX (same business, amount and biller), paid in full on the id keys
        assert_eq(PFLedger.Transfer({ from = 'player:CIDX:bank', to = 'system:pfm-phone', amount = 500, key = 'pfm-phone:invoice:47:bank', kind = 'purchase' }).ok, true)
        assert_eq(PFPayout.PaySociety('police', 500, { key = 'pfm-phone:invoice:47:society' }), true)
        assert_eq(PFPayout.Pay('CID2', 'bank', 50, { key = 'pfm-phone:invoice:47:commission' }), true)
        invoices[47] = { id = 47, citizenid = 'CID1', amount = 500, society = 'police', sendercitizenid = 'CID2', candecline = 1 }
        assert_eq(pay(47), true)
        assert_eq(bank(), 1500)
        assert_eq(police(), 1000)                     -- this invoice's business credit, on the next key
        assert_eq(tx('pfm-phone:invoice:47:society:retry2').state, 'completed')
        assert_eq(Mock.players[BILLER].PlayerData.money.bank, 100)
        assert_eq(tx('pfm-phone:invoice:47:commission:retry2').state, 'completed')
        assert_eq(invoices[47], nil)
        assert_eq(paidEvents(), 1)
        -- paid again after a crash before the delete: the payouts made after this charge count
        invoices[47] = { id = 47, citizenid = 'CID1', amount = 500, society = 'police', sendercitizenid = 'CID2', candecline = 1 }
        assert_eq(pay(47), true)
        assert_eq(bank(), 1500)
        assert_eq(police(), 1000)
        assert_eq(Mock.players[BILLER].PlayerData.money.bank, 100)
        assert_true(tx('pfm-phone:invoice:47:society:retry3') == nil, 'business paid twice')
    end)
end)

describe('the sweep', function()
    it('opens again a paying invoice whose charge never started (a crash before the transfer)', function()
        local id = create()
        invoices[id].pay_state = 'paying'
        assert_eq(#listed(), 0)
        assert_eq(sweep(), 1)
        assert_eq(invoices[id].pay_state, nil)
        assert_eq(#listed(), 1)
        assert_eq(bank(), 2000)
        assert_eq(pay(id), true)
        assert_eq(bank(), 1500)
    end)
    it('leaves an invoice alone while a payment of it runs', function()
        local id = create()
        local during
        onTx = function() during = sweep() end
        assert_eq(pay(id), true)
        assert_eq(during, 0)
        assert_eq(bank(), 1500)
        assert_eq(police(), 500)
        assert_eq(paidEvents(), 1)
    end)
    it('a payment never runs alongside the sweep of the same invoice', function()
        local id = create()
        charge(id)
        pendingSociety(base(id) .. ':society')
        assert_eq(select(2, pay(id)), 'in_progress')
        recover()
        local inner
        onTx = function() inner = { pay(id) } end
        assert_eq(sweep(), 1)
        assert_eq(inner[1], false)
        assert_eq(inner[2], 'in_progress')
        assert_eq(police(), 500)
        assert_eq(paidEvents(), 1)
    end)
end)

describe('(e) a reused id of the same payer and amount, without a token', function()
    it('counts as paid by the older charge, and no payout is made a second time', function()
        -- the older invoice 48 (same payer and amount, another business) was paid in full on the id keys
        FakeDB.society('mechanic', 0)
        assert_eq(PFLedger.Transfer({ from = 'player:CID1:bank', to = 'system:pfm-phone', amount = 500, key = 'pfm-phone:invoice:48:bank', kind = 'purchase' }).ok, true)
        assert_eq(PFPayout.PaySociety('mechanic', 500, { key = 'pfm-phone:invoice:48:society' }), true)
        invoices[48] = { id = 48, citizenid = 'CID1', amount = 500, society = 'police', sendercitizenid = '', candecline = 1 }
        assert_eq(pay(48), true)
        assert_eq(bank(), 1500)                       -- one charge in all
        assert_eq(police(), 0)                        -- no credit without a charge of its own
        assert_eq(FakeDB.bank_accounts['mechanic'].account_balance, 500)
        assert_true(tx('pfm-phone:invoice:48:society:retry2') == nil, 'a credit made from nothing')
        assert_eq(invoices[48], nil)
        assert_eq(paidEvents(), 0)                    -- nothing new to report
    end)
end)

describe('the sweep with rows that wait for good', function()
    -- a 'paying' row whose charge was recovered as interrupted_unverified: it waits for an admin
    local function stuckUnverified(id)
        invoices[id] = { id = id, citizenid = 'CID1', amount = 10, society = 'police', sendercitizenid = '', candecline = 1, ledger_token = 'stuck' .. id, pay_state = 'paying' }
        local key = 'pfm-phone:invoice:tok:stuck' .. id .. ':bank'
        assert_eq(PFLedger.Transfer({ from = 'player:CID1:bank', to = 'system:pfm-phone', amount = 10, key = key, kind = 'purchase' }).ok, true)
        tx(key).state, tx(key).error = 'failed', 'interrupted_unverified'
    end
    it('are paged past: a later half-paid invoice is still finished', function()
        Mock.players[A].PlayerData.money.bank = 100000
        for i = 1, 120 do stuckUnverified(i) end
        nextId = 200
        local id = create()
        charge(id)
        pendingSociety(base(id) .. ':society')
        invoices[id].pay_state = 'paying'
        recover()
        for _ = 1, 4 do
            sweep()
            Mock.gameTimer = Mock.gameTimer + 31 * 60000
        end
        assert_eq(invoices[id], nil, 'the half-paid invoice was never reached')
        assert_eq(police(), 500)
        assert_eq(paidEvents(), 1)
        assert_eq(invoices[120].pay_state, 'paying') -- the stuck ones still wait, untouched
        assert_true(tx('pfm-phone:invoice:tok:stuck120:retry2:bank') == nil)
    end)
    it('a row added behind the cursor is reached once the sweep comes round', function()
        for i = 11, 70 do stuckUnverified(i) end
        assert_eq(sweep(), 0)                         -- tries 11..60 (one batch), goes on after 60 next time
        -- a half-paid invoice with a lower id appears (charged, then the server stopped)
        invoices[5] = { id = 5, citizenid = 'CID1', amount = 500, society = 'police', sendercitizenid = '', candecline = 1, ledger_token = 'tok5' }
        charge(5)
        invoices[5].pay_state = 'paying'
        assert_eq(sweep(), 1)                         -- 61..70, then round to the start: 5
        assert_eq(invoices[5], nil)
        assert_eq(police(), 500)
        assert_eq(paidEvents(), 1)
    end)
    it('tells the admin once about an invoice waiting on an unverified charge', function()
        stuckUnverified(3)
        local lines = {}
        local realPrint = print
        print = function(...) lines[#lines + 1] = table.concat({ ... }, ' ') end
        local ok, err = pcall(function()
            for _ = 1, 3 do
                sweep()
                Mock.gameTimer = Mock.gameTimer + 31 * 60000
            end
        end)
        print = realPrint
        assert_true(ok, tostring(err))
        local told = 0
        for _, l in ipairs(lines) do
            if l:find('invoice 3 waits for an admin', 1, true) and l:find('stuck3:bank', 1, true) then told = told + 1 end
        end
        assert_eq(told, 1)
    end)
end)

describe('invoice ids', function()
    it('5 and 5.0 share one lock: a decline sent as a float during a payment answers in_progress', function()
        local id = create()
        local inner
        onTx = function() inner = { decline(id + 0.0) } end
        assert_eq(pay(id), true)
        assert_eq(inner[1], false)
        assert_eq(inner[2], 'in_progress')
        assert_eq(events('pfm-phone:server:invoiceSettled', 'declined'), 0)
        assert_eq(paidEvents(), 1)
        assert_eq(police(), 500)
    end)
    it('a whole float or a numeric string is the same invoice; anything else is refused', function()
        local id = create()
        assert_eq(select(2, pay(id + 0.5)), 'bad_request')
        assert_eq(select(2, pay(0)), 'bad_request')
        assert_eq(select(2, pay(-id)), 'bad_request')
        assert_eq(select(2, pay(1e300)), 'bad_request')
        assert_eq(select(2, decline(0 / 0)), 'bad_request')
        assert_eq(bank(), 2000)
        assert_eq(pay(tostring(id) .. '.0'), true)
        assert_eq(bank(), 1500)
    end)
end)

describe('the pay_state column', function()
    it('is added once when missing, next to the token column', function()
        hasPayState = false
        load()
        create()
        assert_eq(adds.pay_state, 1)
        assert_eq(adds.ledger_token, nil)
        load()
        create()
        assert_eq(adds.pay_state, 1)
    end)
end)
