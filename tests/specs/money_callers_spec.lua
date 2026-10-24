-- Callers of the ledger: paychecks (pfm-core), the boss-menu deposit hook (pfm-management),
-- and the government treasury (pf-government), all on the fake database.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/fake_db.lua')
function GetCurrentResourceName() return 'pfm-banking' end
function GetResourceState() return 'started' end

QBCoreMock.Shared.Jobs = { police = { label = 'Police' }, mechanic = { label = 'Mechanic' }, government = { label = 'Government' } }
QBCoreMock.Config = { Money = { PayCheckSociety = true, PayCheckTimeOut = 10 } }

Config = nil
load_resource('pfm-banking/config.lua')
load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')
Mock.exportsByResource['pfm-banking'] = Mock.exportsByResource['__self']

-- pfm-core paycheck (PayPaycheck is a global in server/functions.lua)
QBCore = QBCoreMock
QBCore.Players = {}
QBCore.ServerCallbacks, QBCore.ClientCallbacks, QBCore.UsableItems = {}, {}, {}
QBCore.Player_Buckets, QBCore.Entity_Buckets, QBCore.Player = {}, {}, {}
QBCore.Commands.List, QBCore.Commands.IgnoreList = {}, {}
load_resource('pfm-core/server/functions.lua')

-- pfm-management boss menu
load_resource('pfm-management/server/sv_boss.lua')

-- pf-government treasury (its own Config)
local bankingConfig = Config
Config = { Treasury = { StartingBalance = 0, AllowNegative = false, LowBalanceWarning = 0, UseSocietyAccount = true, SocietyAccount = 'government' } }
function LogTransaction() end
function LogAudit() end
function NotifyGovernment() end
function DebugPrint() end
function TrackWeeklyRevenue() end
load_resource('[pfscripts]/pf-government/server/treasury.lua')
local govConfig = Config
Config = bankingConfig

local L = PFLedger
local EMP = 1
local function bal(name) return FakeDB.bank_accounts[name] and FakeDB.bank_accounts[name].account_balance end

BeforeEach = function()
    Mock.reset()
    FakeDB.reset()
    FakeDB.migrations = {}
    Mock.clock = 1700000000
    Mock.players = {}
    local p = Mock.newPlayer(EMP, 'EMP1')
    p.PlayerData.job = { name = 'police', isboss = false, onduty = true, grade = { level = 0 } }
    p.PlayerData.money = { cash = 0, bank = 0 }
    FakeDB.society('police', 1000, 'job')
    FakeDB.society('mechanic', 0, 'job')
    FakeDB.society('government', 500, 'job')
    L.ready, L.failed = false, false
    assert(L.Start())
    for name, acc in pairs(FakeDB.bank_accounts) do BankingAccounts[name] = { account_name = name, account_balance = acc.account_balance, account_type = acc.account_type } end
end

describe('paychecks', function()
    it('a funded job pays its employee from the society account', function()
        PayPaycheck(Mock.players[EMP], 150)
        assert_eq(Mock.players[EMP].PlayerData.money.bank, 150)
        assert_eq(bal('police'), 850)
    end)
    it('the same pay window never pays twice (restart / duplicate timer)', function()
        PayPaycheck(Mock.players[EMP], 150)
        PayPaycheck(Mock.players[EMP], 150)
        assert_eq(Mock.players[EMP].PlayerData.money.bank, 150)
        assert_eq(bal('police'), 850)
        Mock.clock = Mock.clock + 600                                   -- next window
        PayPaycheck(Mock.players[EMP], 150)
        assert_eq(Mock.players[EMP].PlayerData.money.bank, 300)
    end)
    it('a funded job that cannot cover the wage pays nothing (it used to pay from nowhere)', function()
        FakeDB.bank_accounts.police.account_balance = 100
        BankingAccounts.police.account_balance = 100
        PayPaycheck(Mock.players[EMP], 150)
        assert_eq(Mock.players[EMP].PlayerData.money.bank, 0)
        assert_eq(bal('police'), 100)
        local warned = false
        for _, e in ipairs(Mock.clientEventsNamed('QBCore:Notify')) do if e.args[1] == 'error.company_too_poor' then warned = true end end
        assert_true(warned)
    end)
    it('an unfunded job (balance 0) is paid by the state, as before', function()
        Mock.players[EMP].PlayerData.job.name = 'mechanic'
        PayPaycheck(Mock.players[EMP], 80)
        assert_eq(Mock.players[EMP].PlayerData.money.bank, 80)
        assert_eq(FakeDB.transactions[1].from_account, 'system:paycheck')
    end)
end)

describe('boss menu deposit hook', function()
    it('is no longer a network event clients can trigger', function()
        assert_eq(Mock.netHandlers['qb-bossmenu:server:addMoney'], nil)
    end)
    it('still works for server-side callers (pf-mechanicjob register)', function()
        Mock.eventHandlers['qb-bossmenu:server:addMoney']('mechanic', 75)
        assert_eq(bal('mechanic'), 75)
    end)
end)

describe('government treasury', function()
    it('deposits move real money and report the bank balance', function()
        Config = govConfig
        local ok, _, newBalance = DepositToTreasury(250, 'test', 'unit test', 'tester')
        Config = bankingConfig
        assert_true(ok)
        assert_eq(bal('government'), 750)
        assert_eq(newBalance, 750)
    end)
    it('a withdrawal the treasury cannot cover is refused and nothing moves', function()
        Config = govConfig
        local ok = WithdrawFromTreasury(5000, 'too much', 'tester')
        Config = bankingConfig
        assert_false(ok)
        assert_eq(bal('government'), 500)
    end)
    it('tax credits move exactly the tax amount (no read-then-set race)', function()
        Config = govConfig
        -- another deposit lands between reading the balance and crediting: both must survive
        local credited = CreditTreasury(40, 'tax', 'tester')
        Mock.selfExport('AddMoney')('government', 10, 'concurrent deposit')
        local credited2 = CreditTreasury(40, 'tax', 'tester')
        Config = bankingConfig
        assert_true(credited and credited2)
        assert_eq(bal('government'), 590)
    end)
    it('a retried deposit with the same key is applied once', function()
        Config = govConfig
        FakeDB.govTransactions = {}
        local ok1 = DepositToTreasury(100, 'impound', 'fee', 'tester', 'impound:ABC123:1')
        local ok2 = DepositToTreasury(100, 'impound', 'fee', 'tester', 'impound:ABC123:1')
        Config = bankingConfig
        assert_true(ok1 and ok2)
        assert_eq(bal('government'), 600)
        assert_eq(#FakeDB.govTransactions, 1)                          -- the retry is not logged twice
        assert_eq(FakeDB.treasuryMirror, 600)
    end)
end)
