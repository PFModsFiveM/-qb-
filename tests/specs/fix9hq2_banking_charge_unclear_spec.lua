-- PFPayout.Charge (@pfm-banking/payouts.lua) tries the accounts in order. It moves on to the next
-- account only after a clear refusal of the previous one (insufficient funds, a 'failed' transfer with
-- no money taken). On any outcome it cannot be sure of (pending, debited, in_progress, internal_error,
-- ledger_write_failed, a stored duplicate that is not completed or failed, bank not running) it stops,
-- so the ledger's recovery can never complete the first charge on top of a second one.
-- Part one stubs the bank's Transfer export; part two runs the real ledger on the fake database.
load_resource('tests/lua/fivem_mocks.lua')
function GetResourceState() return 'started' end
function GetCurrentResourceName() return 'pf-test' end
load_resource('pfm-banking/payouts.lua')

local SRC, CID = 7, 'CHG00001'
local calls, replies

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    Mock.newPlayer(SRC, CID)
    calls, replies = {}, {}
    Mock.exportsByResource['pfm-banking'] = {
        Transfer = function(_, opts)
            calls[#calls + 1] = opts
            local account = opts.from:match(':(%a+)$')
            return replies[account] or { ok = true, txId = 'TX-' .. account, state = 'completed', duplicate = false }
        end,
    }
end

local function charge(opts)
    opts = opts or {}
    opts.key = opts.key or 'fee-1'
    return PFPayout.Charge(SRC, { 'cash', 'bank' }, 100, opts)
end

local function notices()
    local out = {}
    for _, e in ipairs(Mock.clientEventsNamed('QBCore:Notify')) do out[#out + 1] = e.args[1] end
    return out
end

describe('Charge stops when the first account is not clearly refused', function()
    for _, case in ipairs({
        { name = 'debited (fresh)', reply = { ok = false, txId = 'TX1', state = 'debited', error = 'credit_failed', duplicate = false } },
        { name = 'pending (stored under the key)', reply = { ok = false, txId = 'TX1', state = 'pending', error = 'pending', duplicate = true } },
        { name = 'debited (stored under the key)', reply = { ok = false, txId = 'TX1', state = 'debited', error = 'debited', duplicate = true } },
        { name = 'in_progress (a double click)', reply = { ok = false, error = 'in_progress', duplicate = false } },
        { name = 'internal_error', reply = { ok = false, error = 'internal_error', duplicate = false } },
        { name = 'ledger_write_failed', reply = { ok = false, error = 'ledger_write_failed', duplicate = false } },
        { name = 'failed, interrupted_unverified (stored)', reply = { ok = false, txId = 'TX1', state = 'failed', error = 'interrupted_unverified', duplicate = true } },
        { name = 'an unknown reply', reply = { ok = false, error = 'something_new' } },
    }) do
        it(case.name .. ': the bank account is not charged', function()
            replies.cash = case.reply
            local used, res = charge()
            assert_eq(used, false)
            assert_eq(#calls, 1, 'only the first account was tried')
            assert_eq(calls[1].key, 'fee-1:cash')
            assert_eq(res.state, case.reply.state)
            assert_eq(res.error, case.reply.error)
            assert_true(res.unclear, 'the caller is told the outcome is not known yet')
            local n = notices()
            assert_eq(#n, 1, 'the player is told')
            assert_true(n[1]:find('still processing', 1, true) ~= nil, n[1])
        end)
    end

    it('a compensated transfer (refunded) stops too, but is settled, not unclear', function()
        replies.cash = { ok = false, txId = 'TX1', state = 'compensated', error = 'unknown_account', duplicate = false }
        local used, res = charge()
        assert_eq(used, false)
        assert_eq(#calls, 1)
        assert_false(res.unclear)
        assert_true(notices()[1]:find('did not go through', 1, true) ~= nil)
    end)

    it('the bank not running stops at once: nothing is charged', function()
        replies.cash = { ok = false, error = 'bank_unavailable' }
        local used, res = charge()
        assert_eq(used, false)
        assert_eq(#calls, 1)
        assert_eq(res.error, 'bank_unavailable')
        assert_true(notices()[1]:find('did not respond', 1, true) ~= nil)
    end)

    it('quiet callers are not notified', function()
        replies.cash = { ok = false, error = 'in_progress' }
        assert_eq(charge({ quiet = true }), false)
        assert_eq(#notices(), 0)
    end)

    it('the stop applies to any account order (bank first, then cash)', function()
        replies.bank = { ok = false, txId = 'TX1', state = 'debited', error = 'debited', duplicate = true }
        local used = PFPayout.Charge(SRC, { 'bank', 'cash' }, 100, { key = 'fine-1', quiet = true })
        assert_eq(used, false)
        assert_eq(#calls, 1)
        assert_eq(calls[1].key, 'fine-1:bank')
    end)
end)

describe('Charge moves on after a clear refusal', function()
    it('insufficient cash: the bank pays', function()
        replies.cash = { ok = false, txId = 'TX1', state = 'failed', error = 'insufficient_funds', duplicate = false }
        local used, res = charge()
        assert_eq(used, 'bank')
        assert_true(res.ok)
        assert_eq(#calls, 2)
        assert_eq(calls[2].key, 'fee-1:bank')
        assert_eq(#notices(), 0)
    end)
    it('a stored failure on the first account (same key again): the bank pays', function()
        replies.cash = { ok = false, txId = 'TX1', state = 'failed', error = 'insufficient_funds', duplicate = true }
        assert_eq(charge(), 'bank')
    end)
    it('a debit the ledger rolled back (failed, state_conflict): the bank pays', function()
        replies.cash = { ok = false, txId = 'TX1', state = 'failed', error = 'state_conflict', duplicate = false }
        assert_eq(charge(), 'bank')
    end)
    it('a refusal before anything was written (no transaction): the bank is tried', function()
        replies.cash = { ok = false, error = 'insufficient_funds' }
        assert_eq(charge(), 'bank')
        assert_eq(#calls, 2)
    end)
    it('both refuse: false with the last refusal, not unclear', function()
        replies.cash = { ok = false, txId = 'TX1', state = 'failed', error = 'insufficient_funds' }
        replies.bank = { ok = false, txId = 'TX2', state = 'failed', error = 'insufficient_funds' }
        local used, res = charge()
        assert_eq(used, false)
        assert_eq(res.error, 'insufficient_funds')
        assert_eq(#calls, 2)
        assert_true(not res.unclear)
    end)
    it('cash refused, then the bank unclear: stops there with unclear', function()
        replies.cash = { ok = false, txId = 'TX1', state = 'failed', error = 'insufficient_funds' }
        replies.bank = { ok = false, error = 'in_progress' }
        local used, res = charge()
        assert_eq(used, false)
        assert_true(res.unclear)
    end)
    it('the first account pays: the second is never tried', function()
        assert_eq(charge(), 'cash')
        assert_eq(#calls, 1)
    end)
end)

-- ── real ledger ───────────────────────────────────────────────────────────
local L
local function realLedger(cash, bank)
    if not L then
        load_resource('tests/lua/fake_db.lua')
        function GetCurrentResourceName() return 'pfm-banking' end
        Config = nil
        load_resource('pfm-banking/config.lua')
        load_resource('pfm-core/server/migrations.lua')
        load_resource('pfm-banking/server_ledger.lua')
        load_resource('pfm-banking/server.lua')
        L = PFLedger
    end
    Mock.exportsByResource['pfm-banking'] = Mock.exportsByResource['__self']
    FakeDB.reset()
    FakeDB.migrations = {}
    Mock.clock = 1700000000
    L.ready, L.failed = false, false
    assert_true(L.Start())
    local p = Mock.players[SRC]
    p.PlayerData.money = { cash = cash or 500, bank = bank or 500 }
    FakeDB.players[CID] = { citizenid = CID, money = json.encode(p.PlayerData.money) }
    return p
end

local function chargeReal(key, opts)
    opts = opts or {}
    opts.key, opts.quiet = key, true
    return PFPayout.Charge(SRC, { 'cash', 'bank' }, 100, opts)
end

local function rows(prefix)
    local out = {}
    for k, row in pairs(FakeDB.byKey) do if k:sub(1, #prefix) == prefix then out[k] = row end end
    return out
end

describe('Charge with the real ledger', function()
    it('a double click while the cash charge holds its key does not fall through to the bank', function()
        local p = realLedger()
        local inner
        local realRemove = p.RemoveMoney
        p.RemoveMoney = function(kind, amount, ...)
            if not inner then inner = { chargeReal('dbl-1') } end
            return realRemove(kind, amount, ...)
        end
        p.Functions.RemoveMoney = p.RemoveMoney
        local used = chargeReal('dbl-1')
        assert_eq(used, 'cash')
        assert_true(inner ~= nil, 'the second call ran while the first held the key')
        assert_eq(inner[1], false)
        assert_eq(inner[2].error, 'in_progress')
        assert_true(inner[2].unclear)
        assert_eq(p.PlayerData.money.cash, 400)
        assert_eq(p.PlayerData.money.bank, 500, 'charged once')
        assert_eq(rows('dbl-1:bank')['dbl-1:bank'], nil, 'no bank transfer was even started')
    end)

    it('a crash after the cash debit: the bank is not charged, recovery completes the cash charge, and the same key reports it', function()
        local p = realLedger()
        FakeDB.society('police', 0, 'job')
        FakeDB.failNext.creditSociety = true -- the database errors after the cash left the player
        local used, res = chargeReal('crash-1', { to = 'society:police' })
        assert_eq(used, false)
        assert_eq(res.error, 'internal_error')
        assert_true(res.unclear)
        assert_eq(FakeDB.byKey['crash-1:cash'].state, 'debited')
        assert_eq(p.PlayerData.money.cash, 400)
        assert_eq(p.PlayerData.money.bank, 500, 'the old Charge took the bank here as well')
        assert_eq(FakeDB.byKey['crash-1:bank'], nil)
        Mock.clock = Mock.clock + 120
        L.Recover()
        assert_eq(FakeDB.byKey['crash-1:cash'].state, 'completed')
        assert_eq(FakeDB.bank_accounts.police.account_balance, 100)
        -- the caller retrying with the same key now learns the charge went through, once
        local again = chargeReal('crash-1', { to = 'society:police' })
        assert_eq(again, 'cash')
        assert_eq(p.PlayerData.money.cash, 400)
        assert_eq(p.PlayerData.money.bank, 500)
        assert_eq(FakeDB.bank_accounts.police.account_balance, 100)
    end)

    it('a crash before the debit was recorded (money may have left): never charged a second time', function()
        local p = realLedger()
        local realRemove = p.RemoveMoney
        p.RemoveMoney = function(kind, amount, ...)
            FakeDB.failNext.setState = true -- the pending -> debited write errors after the memory debit
            return realRemove(kind, amount, ...)
        end
        p.Functions.RemoveMoney = p.RemoveMoney
        local used, res = chargeReal('unv-1')
        p.RemoveMoney, p.Functions.RemoveMoney = realRemove, realRemove
        assert_eq(used, false)
        assert_eq(res.error, 'internal_error')
        assert_true(res.unclear)
        assert_eq(p.PlayerData.money.cash, 400, 'the cash left memory')
        assert_eq(p.PlayerData.money.bank, 500)
        Mock.clock = Mock.clock + 120
        L.Recover()
        assert_eq(FakeDB.byKey['unv-1:cash'].state, 'failed')
        assert_eq(FakeDB.byKey['unv-1:cash'].error, 'interrupted_unverified')
        -- the same key again: the stored cash row is unverified, so the bank is still not touched
        local again, res2 = chargeReal('unv-1')
        assert_eq(again, false)
        assert_true(res2.duplicate)
        assert_true(res2.unclear)
        assert_eq(p.PlayerData.money.bank, 500)
        assert_eq(FakeDB.byKey['unv-1:bank'], nil)
    end)

    it('not enough cash: the bank pays; the same key again pays nothing more', function()
        local p = realLedger(50, 500)
        assert_eq(chargeReal('low-1'), 'bank')
        assert_eq(FakeDB.byKey['low-1:cash'].state, 'failed')
        assert_eq(p.PlayerData.money.cash, 50)
        assert_eq(p.PlayerData.money.bank, 400)
        assert_eq(chargeReal('low-1'), 'bank', 'the stored failure moves on; the stored bank charge answers')
        assert_eq(p.PlayerData.money.bank, 400)
        assert_eq(p.PlayerData.money.cash, 50)
    end)

    it('a destination that refuses (compensated): the cash comes back and the bank is not tried', function()
        local p = realLedger()
        local used, res = chargeReal('comp-1', { to = 'society:nosuchsociety' })
        assert_eq(used, false)
        assert_eq(res.state, 'compensated')
        assert_false(res.unclear)
        assert_eq(p.PlayerData.money.cash, 500)
        assert_eq(p.PlayerData.money.bank, 500)
        assert_eq(FakeDB.byKey['comp-1:bank'], nil)
    end)
end)
