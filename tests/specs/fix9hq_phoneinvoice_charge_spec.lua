-- pfm-phone invoice charge attempts on the ledger: an attempt the ledger is still settling is never
-- charged again, a completed attempt means paid, failed attempts never lock the invoice out, and one
-- invoice is paid by one request at a time.
load_resource('tests/lua/ledger_env.lua')

local invoices = {}   -- [id] = row
local onSelect        -- runs once inside the invoice SELECT (a database yield in FiveM)

FakeDB.extraPatterns = {
    { 'INSERT INTO player_mails', function() return 1 end },
    { 'SELECT * FROM phone_invoices WHERE id = ? AND citizenid = ?', function(p)
        local hook = onSelect
        onSelect = nil
        if hook then hook() end
        local row = invoices[tonumber(p[1])]
        return (row and row.citizenid == p[2]) and { row } or {}
    end },
    { 'DELETE FROM phone_invoices WHERE id = ? AND citizenid = ?', function(p)
        local row = invoices[tonumber(p[1])]
        if row and row.citizenid == p[2] then invoices[tonumber(p[1])] = nil return { affectedRows = 1 } end
        return { affectedRows = 0 }
    end },
}

local FILES = { 'pfm-phone/config.lua', 'pfm-phone/server/main.lua' }
LedgerEnv.load('pfm-phone', FILES)
Mock.exportsByResource['pfm-phone'] = { sendNewMailToOffline = function() end }

local A = 1
local KEY1 = 'pfm-phone:invoice:7:bank'
local function bank() return Mock.players[A].PlayerData.money.bank end
local function pay() return Mock.selfExport('PayInvoice')(A, 7) end
local function police() return FakeDB.bank_accounts['police'].account_balance end

-- completed charge rows of invoice 7 (the society payout has its own key)
local function charges()
    local n = 0
    for _, row in ipairs(LedgerEnv.paid('pfm-phone:invoice:7')) do
        if tostring(row.idempotency_key):sub(-5) == ':bank' then n = n + 1 end
    end
    return n
end

local function settledEvents()
    local out = {}
    for _, e in ipairs(Mock.serverEvents) do
        if e.name == 'qb-phone:server:paidInvoice' or e.name == 'pfm-phone:server:invoiceSettled' then out[#out + 1] = e end
    end
    return out
end

local function settings()
    Config.BillingCommissions = {}
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.load('pfm-phone', FILES) -- a fresh resource for the fresh ledger (it caches attempt numbers)
    LedgerEnv.reset()
    Mock.clock = Mock.clock + 1000
    Mock.players = {}
    onSelect = nil
    local p = Mock.newPlayer(A)
    p.PlayerData.money = { cash = 0, bank = 1000 }
    FakeDB.society('police', 0)
    settings()
    invoices = { [7] = { id = 7, citizenid = 'CID1', amount = 500, society = 'police', sender = 'Officer', sendercitizenid = '', candecline = 1 } }
end

-- charges the player on attempt 1's key and leaves the row as a crash between debit and credit would
local function debitedAttempt1(state)
    local res = PFLedger.Transfer({ from = 'player:CID1:bank', to = 'system:pfm-phone', amount = 500, key = KEY1, kind = 'purchase' })
    assert_eq(res.ok, true)
    FakeDB.byKey[KEY1].state = state
end

describe('an attempt the ledger is still settling', function()
    it('is not charged again while debited, and counts as paid once recovery completes it', function()
        debitedAttempt1('debited')
        assert_eq(bank(), 500)
        local ok, err = pay()
        assert_eq(ok, false)
        assert_eq(err, 'in_progress')
        assert_eq(bank(), 500)                 -- no second charge on a retry key
        assert_true(FakeDB.byKey['pfm-phone:invoice:7:retry2:bank'] == nil)
        assert_true(invoices[7] ~= nil)
        -- ledger recovery finishes the credit
        FakeDB.byKey[KEY1].state = 'completed'
        assert_eq(pay(), true)
        assert_eq(bank(), 500)
        assert_eq(police(), 500)
        assert_eq(invoices[7], nil)
        assert_eq(charges(), 1)
    end)
    it('settles the invoice with its events once recovery has completed the charge', function()
        debitedAttempt1('debited')
        local ok, err = pay()
        assert_eq(err, 'in_progress')
        assert_eq(#settledEvents(), 0)
        FakeDB.byKey[KEY1].state = 'completed'
        assert_eq(pay(), true)
        local ev = settledEvents()
        assert_eq(#ev, 2)
        assert_eq(ev[1].name, 'qb-phone:server:paidInvoice')
        assert_eq(ev[2].name, 'pfm-phone:server:invoiceSettled')
        assert_eq(ev[2].args[2], 'paid')
        assert_eq(ev[2].args[1].id, 7)
        -- a later replay finds the invoice gone and sends nothing again
        assert_eq(pay(), false)
        assert_eq(#settledEvents(), 2)
    end)
    it('answers in progress while pending', function()
        debitedAttempt1('pending')
        local ok, err = pay()
        assert_eq(ok, false)
        assert_eq(err, 'in_progress')
        assert_eq(bank(), 500)
        assert_true(FakeDB.byKey['pfm-phone:invoice:7:retry2:bank'] == nil)
    end)
end)

describe('a completed attempt', function()
    it('means the invoice is paid: no new charge, the business is paid once', function()
        debitedAttempt1('completed')
        assert_eq(pay(), true)
        assert_eq(bank(), 500)
        assert_eq(police(), 500)
        assert_eq(invoices[7], nil)
        invoices[7] = { id = 7, citizenid = 'CID1', amount = 500, society = 'police', sendercitizenid = '' }
        assert_eq(pay(), true)
        assert_eq(bank(), 500)
        assert_eq(police(), 500)
        assert_eq(charges(), 1)
    end)
end)

describe('failed attempts', function()
    it('never lock the invoice out, however many there were', function()
        Mock.players[A].PlayerData.money.bank = 100
        for i = 1, 25 do
            local ok, err = pay()
            assert_eq(ok, false, 'attempt ' .. i)
            assert_eq(err, 'insufficient_funds', 'attempt ' .. i)
        end
        assert_eq(bank(), 100)
        Mock.players[A].PlayerData.money.bank = 1000
        assert_eq(pay(), true)
        assert_eq(bank(), 500)
        assert_eq(police(), 500)
        assert_eq(charges(), 1)
        assert_eq(invoices[7], nil)
    end)
    it('are found again after a restart, and the next attempt charges once', function()
        Mock.players[A].PlayerData.money.bank = 100
        for _ = 1, 3 do assert_eq(pay(), false) end
        LedgerEnv.load('pfm-phone', FILES)    -- a restart forgets the attempt counter
        settings()
        Mock.players[A].PlayerData.money.bank = 1000
        assert_eq(pay(), true)
        assert_eq(bank(), 500)
        assert_eq(charges(), 1)
        assert_true(FakeDB.byKey['pfm-phone:invoice:7:retry4:bank'].state == 'completed')
        assert_eq(pay(), false)                -- the invoice is gone
        assert_eq(bank(), 500)
    end)
    it('a refunded (compensated) attempt moves on to a new key', function()
        debitedAttempt1('compensated')
        Mock.players[A].PlayerData.money.bank = 1000 -- the refund
        assert_eq(pay(), true)
        assert_eq(bank(), 500)
        assert_eq(FakeDB.byKey['pfm-phone:invoice:7:retry2:bank'].state, 'completed')
    end)
end)

describe('one payment of an invoice at a time', function()
    it('a second request while the first waits on the database is turned away', function()
        local inner
        onSelect = function() inner = { pay() } end
        assert_eq(pay(), true)
        assert_eq(inner[1], false)
        assert_eq(inner[2], 'in_progress')
        assert_eq(bank(), 500)
        assert_eq(charges(), 1)
    end)
    it('another player asking for the invoice id does not block its owner', function()
        local B = 2
        Mock.newPlayer(B).PlayerData.money = { cash = 0, bank = 1000 }
        local inner, outer
        -- B's request holds its lock across the SELECT (a yield); the owner pays meanwhile
        onSelect = function() inner = { pay() } end
        outer = { Mock.selfExport('PayInvoice')(B, 7) }
        assert_eq(inner[1], true)
        assert_eq(outer[1], false)
        assert_eq(outer[2], 'not_found')
        assert_eq(bank(), 500)
        assert_eq(Mock.players[B].PlayerData.money.bank, 1000)
        assert_eq(charges(), 1)
    end)
    it('the lock is released after a failure', function()
        Mock.players[A].PlayerData.money.bank = 100
        assert_eq(pay(), false)
        Mock.players[A].PlayerData.money.bank = 1000
        assert_eq(pay(), true)
        assert_eq(bank(), 500)
    end)
end)
