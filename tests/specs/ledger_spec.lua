-- pfm-banking ledger + the real banking server code on a fake database.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/fake_db.lua')
function GetCurrentResourceName() return 'pfm-banking' end

QBCoreMock.Shared.Jobs = {
    police = { label = 'Police' }, ambulance = { label = 'EMS' }, burgershot = { label = 'Burger Shot' },
}

Config = nil
load_resource('pfm-banking/config.lua')
load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')

local L = PFLedger
local POLICE_BOSS, BURGER_BOSS, COP, CIV = 1, 2, 3, 4

local function bal(name) return FakeDB.bank_accounts[name] and FakeDB.bank_accounts[name].account_balance end
local function money(src, kind) return Mock.players[src].PlayerData.money[kind] end
local function syncCache()
    for k in pairs(BankingAccounts) do BankingAccounts[k] = nil end
    for name, acc in pairs(FakeDB.bank_accounts) do
        BankingAccounts[name] = { account_name = name, account_balance = acc.account_balance, account_type = acc.account_type, citizenid = acc.citizenid, users = acc.users }
    end
end
local function cbCall(name, src, data) return Mock.callCallback('qb-banking:server:' .. name, src, data) end
local function txCount() return #FakeDB.transactions end

BeforeEach = function()
    Mock.reset()
    FakeDB.reset()
    FakeDB.migrations = {}
    Mock.clock = 1700000000
    Mock.players = {}
    Mock.invokingResource = nil
    local function player(src, cid, job, isboss, cash, bank)
        local p = Mock.newPlayer(src, cid)
        p.PlayerData.job = { name = job, isboss = isboss }
        p.PlayerData.gang = { name = 'none', isboss = false }
        p.PlayerData.money = { cash = cash, bank = bank }
        return p
    end
    player(POLICE_BOSS, 'PB1', 'police', true, 100, 1000)
    player(BURGER_BOSS, 'BB1', 'burgershot', true, 100, 1000)
    player(COP, 'CP1', 'police', false, 100, 1000)
    player(CIV, 'CV1', 'unemployed', false, 100, 1000)
    FakeDB.society('police', 5000, 'job')
    FakeDB.society('burgershot', 300, 'job')
    FakeDB.society('ambulance', 0, 'job')
    FakeDB.society('mates', 800, 'shared', 'CV1', '["PB1"]')
    L.ready, L.failed = false, false
    assert(L.Start(), 'ledger start')
    syncCache()
end

describe('Transfer core', function()
    it('moves money and records a completed transaction', function()
        local res = L.Transfer({ from = 'society:police', to = 'player:CV1:bank', amount = 250, key = 'k1', kind = 'wage' })
        assert_true(res.ok)
        assert_eq(res.state, 'completed')
        assert_eq(bal('police'), 4750)
        assert_eq(money(CIV, 'bank'), 1250)
        assert_true(type(res.txId) == 'string' and #res.txId > 10)
    end)
    it('is idempotent: the same key never moves money twice', function()
        L.Transfer({ from = 'society:police', to = 'player:CV1:bank', amount = 250, key = 'pay-1' })
        local again = L.Transfer({ from = 'society:police', to = 'player:CV1:bank', amount = 250, key = 'pay-1' })
        assert_true(again.ok)
        assert_true(again.duplicate)
        assert_eq(bal('police'), 4750)
        assert_eq(money(CIV, 'bank'), 1250)
        assert_eq(txCount(), 1)
    end)
    it('refuses to overdraw and leaves balances untouched', function()
        local res = L.Transfer({ from = 'society:burgershot', to = 'player:CV1:bank', amount = 301, key = 'k2' })
        assert_false(res.ok)
        assert_eq(res.error, 'insufficient_funds')
        assert_eq(res.state, 'failed')
        assert_eq(bal('burgershot'), 300)
        assert_eq(money(CIV, 'bank'), 1000)
    end)
    it('rejects invalid amounts before touching anything', function()
        for _, bad in ipairs({ -5, 0, 0 / 0, math.huge, 'abc', 0.004 }) do
            local res = L.Transfer({ from = 'society:police', to = 'player:CV1:bank', amount = bad, key = 'bad-' .. tostring(bad) })
            assert_eq(res.error, 'invalid_amount', 'amount ' .. tostring(bad))
        end
        assert_eq(txCount(), 0)
    end)
    it('rejects malformed account references and keys', function()
        assert_eq(L.Transfer({ from = 'police', to = 'player:CV1:bank', amount = 1, key = 'x' }).error, 'invalid_account')
        assert_eq(L.Transfer({ from = 'society:police', to = 'player:CV1:gold', amount = 1, key = 'x' }).error, 'invalid_account')
        assert_eq(L.Transfer({ from = 'society:police', to = 'society:police', amount = 1, key = 'x' }).error, 'same_account')
        assert_eq(L.Transfer({ from = 'society:police', to = 'player:CV1:bank', amount = 1 }).error, 'invalid_key')
    end)
    it('keeps cents (balances are no longer whole numbers only)', function()
        assert_true(L.Transfer({ from = 'system:test', to = 'society:police', amount = 12.35, key = 'c1' }).ok)
        assert_eq(bal('police'), 5012.35)
    end)
end)

describe('accounts that do not exist', function()
    it('a known job account is created on demand so payments to it never vanish', function()
        FakeDB.bank_accounts.ambulance = nil
        local res = L.Transfer({ from = 'player:CV1:bank', to = 'society:ambulance', amount = 50, key = 'bill-1' })
        assert_true(res.ok)
        assert_eq(bal('ambulance'), 50)
        assert_eq(FakeDB.baselines['society:ambulance'], 0, 'baseline recorded')
    end)
    it('an unknown destination is refused and the source refunded (compensated)', function()
        local res = L.Transfer({ from = 'player:CV1:bank', to = 'society:not_a_business', amount = 50, key = 'typo-1' })
        assert_false(res.ok)
        assert_eq(res.state, 'compensated')
        assert_eq(money(CIV, 'bank'), 1000)
        assert_eq(FakeDB.bank_accounts.not_a_business, nil)
    end)
    it('credits an offline player in the database, atomically with the state change', function()
        FakeDB.players.OFF1 = { money = { bank = 10, cash = 0 } }
        local res = L.Transfer({ from = 'society:police', to = 'player:OFF1:bank', amount = 90, key = 'off-1' })
        assert_true(res.ok)
        assert_eq(FakeDB.players.OFF1.money.bank, 100)
    end)
    it('refuses a transfer to a citizen that does not exist and refunds', function()
        local res = L.Transfer({ from = 'society:police', to = 'player:NOBODY:bank', amount = 90, key = 'ghost-1' })
        assert_false(res.ok)
        assert_eq(bal('police'), 5000)
    end)
end)

describe('crash recovery', function()
    it('a transfer interrupted after the debit is completed exactly once by recovery', function()
        FakeDB.failNext.creditSociety = true               -- the database errors mid-transfer, after the debit
        local res = L.Transfer({ from = 'society:police', to = 'society:burgershot', amount = 100, key = 'crash-1' })
        assert_false(res.ok)
        assert_eq(FakeDB.byKey['crash-1'].state, 'debited')
        assert_eq(bal('police'), 4900)
        assert_eq(bal('burgershot'), 300, 'not yet credited')
        Mock.clock = Mock.clock + 120
        L.Recover()
        L.Recover()                                        -- running recovery twice must not pay twice
        assert_eq(FakeDB.byKey['crash-1'].state, 'completed')
        assert_eq(bal('burgershot'), 400)
        assert_eq(bal('police'), 4900)
        local again = L.Transfer({ from = 'society:police', to = 'society:burgershot', amount = 100, key = 'crash-1' })
        assert_true(again.duplicate and again.ok, 'caller retry sees the completed result')
        assert_eq(bal('burgershot'), 400)
    end)
    it('a transfer stuck in pending is failed without moving money', function()
        FakeDB.failNext.debitSociety = true
        local res = L.Transfer({ from = 'society:police', to = 'player:CV1:bank', amount = 10, key = 'pend-1' })
        assert_eq(res.error, 'internal_error')
        assert_eq(FakeDB.byKey['pend-1'].state, 'pending')
        Mock.clock = Mock.clock + 120
        L.Recover()
        assert_eq(FakeDB.byKey['pend-1'].state, 'failed')
        assert_eq(bal('police'), 5000)
        assert_eq(money(CIV, 'bank'), 1000)
    end)
    it('a credit to a destination that disappeared during the crash is refunded on recovery', function()
        FakeDB.failNext.creditSociety = true
        L.Transfer({ from = 'society:police', to = 'society:burgershot', amount = 100, key = 'gone-1' })
        assert_eq(FakeDB.byKey['gone-1'].state, 'debited')
        FakeDB.bank_accounts.burgershot = nil
        QBCoreMock.Shared.Jobs.burgershot = nil
        Mock.clock = Mock.clock + 120
        L.Recover()
        QBCoreMock.Shared.Jobs.burgershot = { label = 'Burger Shot' }
        assert_eq(FakeDB.byKey['gone-1'].state, 'compensated')
        assert_eq(bal('police'), 5000)
    end)
end)

describe('reconciliation', function()
    it('balances that moved only through the ledger reconcile cleanly', function()
        L.Transfer({ from = 'society:police', to = 'player:CV1:bank', amount = 250, key = 'r1' })
        L.Transfer({ from = 'system:fines', to = 'society:police', amount = 40, key = 'r2' })
        local report = L.Reconcile()
        assert_eq(#report.mismatches, 0)
    end)
    it('a balance changed outside the ledger is reported', function()
        FakeDB.bank_accounts.burgershot.account_balance = 999999
        local report = L.Reconcile()
        assert_eq(#report.mismatches, 1)
        assert_eq(report.mismatches[1].account, 'burgershot')
        assert_eq(report.mismatches[1].difference, 999699)
    end)
end)

describe('legacy exports (used by ~40 call sites)', function()
    it('AddMoney still returns true and now records a transaction', function()
        Mock.invokingResource = 'pfm-policejob'
        local ok, res = Mock.selfExport('AddMoney')('police', 120, 'Fine paid')
        assert_true(ok)
        assert_eq(bal('police'), 5120)
        assert_eq(FakeDB.byTxId[res.txId].from_account, 'system:pfm-policejob')
    end)
    it('RemoveMoney refuses to overdraw (it used to go negative)', function()
        local ok = Mock.selfExport('RemoveMoney')('burgershot', 500, 'test')
        assert_false(ok)
        assert_eq(bal('burgershot'), 300)
    end)
    it('AddMoney rejects negative amounts (it used to subtract)', function()
        assert_false(Mock.selfExport('AddMoney')('police', -1000, 'x'))
        assert_eq(bal('police'), 5000)
    end)
    it('an explicit key makes a retried AddMoney safe', function()
        Mock.selfExport('AddMoney')('police', 10, 'tax', 'tax:order:77')
        Mock.selfExport('AddMoney')('police', 10, 'tax', 'tax:order:77')
        assert_eq(bal('police'), 5010)
    end)
end)

describe('bank UI exploits (closed)', function()
    it('withdrawing a negative amount from a society no longer mints money', function()
        local res = cbCall('withdraw', POLICE_BOSS, { accountName = 'police', amount = -1000 })
        assert_false(res.success)
        assert_eq(bal('police'), 5000)
    end)
    it('the boss of another job cannot withdraw from the police account', function()
        local res = cbCall('withdraw', BURGER_BOSS, { accountName = 'police', amount = 1000 })
        assert_false(res.success)
        assert_eq(bal('police'), 5000)
        assert_eq(money(BURGER_BOSS, 'cash'), 100)
    end)
    it('a non-boss employee cannot withdraw from their own job account', function()
        assert_false(cbCall('withdraw', COP, { accountName = 'police', amount = 1000 }).success)
        assert_eq(bal('police'), 5000)
    end)
    it('the police boss can withdraw from the police account', function()
        assert_true(cbCall('withdraw', POLICE_BOSS, { accountName = 'police', amount = 1000 }).success)
        assert_eq(bal('police'), 4000)
        assert_eq(money(POLICE_BOSS, 'cash'), 1100)
    end)
    it('a stranger cannot withdraw from a player-shared account; a listed user can', function()
        assert_false(cbCall('withdraw', BURGER_BOSS, { accountName = 'mates', amount = 100 }).success)
        assert_true(cbCall('withdraw', POLICE_BOSS, { accountName = 'mates', amount = 100 }).success)
        assert_eq(bal('mates'), 700)
    end)
    it('a negative internal transfer cannot drain another account', function()
        local res = cbCall('internalTransfer', CIV, { fromAccountName = 'checking', toAccountName = 'police', amount = -5000 })
        assert_false(res.success)
        assert_eq(bal('police'), 5000)
    end)
    it('a NaN amount is rejected and balances stay numeric', function()
        assert_false(cbCall('deposit', CIV, { accountName = 'checking', amount = 0 / 0 }).success)
        assert_eq(money(CIV, 'cash'), 100)
        assert_eq(money(CIV, 'bank'), 1000)
    end)
    it('external transfer works to an offline citizen', function()
        FakeDB.players.OFF2 = { money = { bank = 0, cash = 0 } }
        assert_true(cbCall('externalTransfer', CIV, { fromAccountName = 'checking', toAccountNumber = 'OFF2', amount = 300 }).success)
        assert_eq(money(CIV, 'bank'), 700)
        assert_eq(FakeDB.players.OFF2.money.bank, 300)
    end)
    it('closing a shared account pays its balance back instead of destroying it', function()
        assert_true(cbCall('deleteAccount', CIV, { accountName = 'mates' }).success)
        assert_eq(FakeDB.bank_accounts.mates, nil)
        assert_eq(money(CIV, 'bank'), 1800)
    end)
    it('opening an account with a negative deposit is refused', function()
        assert_false(cbCall('openAccount', CIV, { accountName = 'savings', amount = -500 }).success)
        assert_eq(FakeDB.bank_accounts.savings, nil)
    end)
    it('renaming onto an existing account is refused and nothing is overwritten', function()
        assert_false(cbCall('renameAccount', CIV, { oldName = 'mates', newName = 'police' }).success)
        assert_eq(bal('police'), 5000)
        assert_eq(bal('mates'), 800)
    end)
end)
