-- PFPayout.Charge (@pfm-banking/payouts.lua) tries the accounts in order. It moves on to the next
-- account only after a clean refusal; when the first transfer is in an unclear state (pending,
-- debited, in_progress) it stops there, so the ledger's recovery cannot later complete the first charge
-- on top of a second one. Part one stubs the bank's Transfer export; part two uses the real ledger.
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

describe('Charge stops on an unclear state', function()
    for _, reply in ipairs({
        { ok = false, txId = 'TX1', state = 'debited', error = 'debited', duplicate = false },
        { ok = false, txId = 'TX1', state = 'pending', error = 'pending', duplicate = true },
        { ok = false, error = 'in_progress', duplicate = false },
        { ok = false, error = 'internal_error', duplicate = false },
    }) do
        it('first account ' .. tostring(reply.state or reply.error) .. ': the bank account is not charged', function()
            replies.cash = reply
            local used, res = charge()
            assert_eq(used, false)
            assert_eq(#calls, 1, 'only the first account was tried')
            assert_eq(calls[1].key, 'fee-1:cash')
            assert_eq(res.state, reply.state)
            assert_eq(res.error, reply.error)
            assert_true(#Mock.clientEventsNamed('QBCore:Notify') == 1, 'the player is told')
        end)
    end
    it('quiet callers are not notified', function()
        replies.cash = { ok = false, error = 'in_progress' }
        assert_eq(charge({ quiet = true }), false)
        assert_eq(#Mock.clientEventsNamed('QBCore:Notify'), 0)
    end)
end)

describe('Charge continues on a clean refusal', function()
    it('insufficient cash: the bank pays', function()
        replies.cash = { ok = false, txId = 'TX1', state = 'failed', error = 'insufficient_funds', duplicate = false }
        local used, res = charge()
        assert_eq(used, 'bank')
        assert_true(res.ok)
        assert_eq(#calls, 2)
        assert_eq(calls[2].key, 'fee-1:bank')
    end)
    it('a stored failure on the first account (same key again): the bank pays', function()
        replies.cash = { ok = false, txId = 'TX1', state = 'failed', error = 'insufficient_funds', duplicate = true }
        assert_eq(charge(), 'bank')
    end)
    it('both refuse: false with the last refusal', function()
        replies.cash = { ok = false, state = 'failed', error = 'insufficient_funds' }
        replies.bank = { ok = false, state = 'failed', error = 'insufficient_funds' }
        local used, res = charge()
        assert_eq(used, false)
        assert_eq(res.error, 'insufficient_funds')
        assert_eq(#calls, 2)
    end)
    it('the first account pays: the second is never tried', function()
        assert_eq(charge(), 'cash')
        assert_eq(#calls, 1)
    end)
end)

describe('Charge with the real ledger', function()
    it('a cash charge still holding its key does not fall through to the bank', function()
        load_resource('tests/lua/fake_db.lua')
        function GetCurrentResourceName() return 'pfm-banking' end
        Config = nil
        load_resource('pfm-banking/config.lua')
        load_resource('pfm-core/server/migrations.lua')
        load_resource('pfm-banking/server_ledger.lua')
        load_resource('pfm-banking/server.lua')
        Mock.exportsByResource['pfm-banking'] = Mock.exportsByResource['__self']
        FakeDB.reset()
        FakeDB.migrations = {}
        PFLedger.ready, PFLedger.failed = false, false
        assert_true(PFLedger.Start())
        local p = Mock.players[SRC]
        p.PlayerData.money = { cash = 500, bank = 500 }
        FakeDB.players[CID] = { citizenid = CID, money = json.encode(p.PlayerData.money) }
        -- the first call yields inside the ledger while a second one (a double click) arrives
        local inner
        local realRemove = p.RemoveMoney
        p.RemoveMoney = function(kind, amount, ...)
            if not inner then inner = { PFPayout.Charge(SRC, { 'cash', 'bank' }, 100, { key = 'dbl-1', quiet = true }) } end
            return realRemove(kind, amount, ...)
        end
        p.Functions.RemoveMoney = p.RemoveMoney
        local used = PFPayout.Charge(SRC, { 'cash', 'bank' }, 100, { key = 'dbl-1', quiet = true })
        assert_eq(used, 'cash')
        assert_true(inner ~= nil, 'the second call ran while the first held the key')
        assert_eq(inner[1], false)
        assert_eq(inner[2].error, 'in_progress')
        assert_eq(p.PlayerData.money.cash, 400)
        assert_eq(p.PlayerData.money.bank, 500, 'charged once')
    end)
end)
