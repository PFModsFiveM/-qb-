-- pfm-banking server_accounts.lua (IBAN shared/business accounts) and server_finance.lua (loans,
-- credit cards) on the ledger, running the real resource files on the fake database.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/fake_db.lua')
function GetCurrentResourceName() return 'pfm-banking' end

Config = nil
load_resource('pfm-banking/config.lua')
load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')
load_resource('pfm-banking/server_accounts.lua')
load_resource('pfm-banking/server_finance.lua')
Mock.exportsByResource['pfm-banking'] = Mock.exportsByResource['__self']

local L = PFLedger
local OWNER, MEMBER, STRANGER = 1, 2, 3
local ACC -- the owner's shared account id

local function money(src) return Mock.players[src].PlayerData.money.bank end
local function acctBal(id) return FakeDB.v2[id] and FakeDB.v2[id].balance end
local function cb(name, src, data) return Mock.callCallback('qb-banking:server:' .. name, src, data) end
local function lastTx() return FakeDB.transactions[#FakeDB.transactions] end
local function noMismatches()
    local report = L.Reconcile()
    for _, m in ipairs(report.mismatches) do print('mismatch', m.account, m.expected, m.actual) end
    return #report.mismatches == 0
end

BeforeEach = function()
    Mock.reset()
    FakeDB.reset()
    FakeDB.migrations = {}
    Mock.clock = 1700000000
    Mock.players = {}
    local function player(src, cid, bank)
        local p = Mock.newPlayer(src, cid)
        p.PlayerData.money = { cash = 0, bank = bank }
        return p
    end
    player(OWNER, 'OW1', 2000)
    player(MEMBER, 'MB1', 2000)
    player(STRANGER, 'ST1', 2000)
    FakeDB.players.OFF1 = { money = { bank = 50, cash = 0 } }          -- an offline citizen
    FakeDB.personalIban.OFF1 = 'PF00000001'
    FakeDB.personalIban.GONE1 = 'PF00000002'                           -- IBAN of a deleted character
    ACC = FakeDB.ibanAccount('OW1', 1000, 'Silverio Shared')
    FakeDB.member(ACC, 'MB1', { d = 1, w = 0 })                       -- may deposit, may not withdraw
    L.ready, L.failed = false, false
    assert(L.Start(), 'ledger start')
end

describe('IBAN accounts: migration', function()
    it('v2 records a reconciliation baseline for every existing account', function()
        assert_eq(FakeDB.baselines['acct:' .. ACC], 1000)
        assert_true(FakeDB.migrations['pfm-banking:2'])
    end)
end)

describe('IBAN accounts: deposits and withdrawals', function()
    it('a deposit moves money from the personal balance through the ledger', function()
        local res = cb('accountDeposit', OWNER, { accountId = ACC, amount = 300 })
        assert_true(res.success)
        assert_eq(money(OWNER), 1700)
        assert_eq(acctBal(ACC), 1300)
        local tx = lastTx()
        assert_eq(tx.from_account, 'player:OW1:bank')
        assert_eq(tx.to_account, 'acct:' .. ACC)
        assert_eq(tx.state, 'completed')
        assert_eq(#FakeDB.bankTx, 2)                                   -- history rows for both sides
    end)
    it('a deposit larger than the bank balance is refused and nothing moves', function()
        local res = cb('accountDeposit', OWNER, { accountId = ACC, amount = 5000 })
        assert_false(res.success)
        assert_eq(money(OWNER), 2000)
        assert_eq(acctBal(ACC), 1000)
        assert_eq(#FakeDB.bankTx, 0)
    end)
    it('a withdrawal larger than the account balance is refused', function()
        local res = cb('accountWithdraw', OWNER, { accountId = ACC, amount = 1500 })
        assert_false(res.success)
        assert_eq(acctBal(ACC), 1000)
        assert_eq(money(OWNER), 2000)
    end)
    it('a member without withdraw permission and a stranger cannot withdraw', function()
        assert_false(cb('accountWithdraw', MEMBER, { accountId = ACC, amount = 10 }).success)
        assert_false(cb('accountWithdraw', STRANGER, { accountId = ACC, amount = 10 }).success)
        assert_false(cb('accountDeposit', STRANGER, { accountId = ACC, amount = 10 }).success)
        assert_eq(acctBal(ACC), 1000)
        assert_true(cb('accountDeposit', MEMBER, { accountId = ACC, amount = 10 }).success)
    end)
    it('negative, zero and non-numeric amounts are refused', function()
        for _, amount in ipairs({ -500, 0, 'abc', 0 / 0 }) do
            assert_false(cb('accountWithdraw', OWNER, { accountId = ACC, amount = amount }).success)
        end
        assert_eq(acctBal(ACC), 1000)
        assert_eq(money(OWNER), 2000)
    end)
    it('a second money action while the first is running is refused (double-click)', function()
        local inner
        L.WithLock('bank:OW1', function()
            inner = cb('accountWithdraw', OWNER, { accountId = ACC, amount = 100 })
        end)
        assert_false(inner.success)
        assert_eq(acctBal(ACC), 1000)
    end)
    it('balances still reconcile after a mix of operations', function()
        cb('accountDeposit', OWNER, { accountId = ACC, amount = 250 })
        cb('accountWithdraw', OWNER, { accountId = ACC, amount = 75 })
        cb('accountDeposit', MEMBER, { accountId = ACC, amount = 20 })
        assert_true(noMismatches())
    end)
    it('reconciliation flags money written into an account outside the ledger', function()
        FakeDB.v2[ACC].balance = FakeDB.v2[ACC].balance + 999
        assert_false(noMismatches())
    end)
end)

describe('IBAN accounts: transfers', function()
    it('pays an offline citizen by IBAN through their stored balance', function()
        local res = cb('accountTransfer', OWNER, { fromRef = ACC, toIban = 'PF00000001', amount = 200 })
        assert_true(res.success)
        assert_eq(acctBal(ACC), 800)
        assert_eq(FakeDB.players.OFF1.money.bank, 250)
    end)
    it('refunds the source when the recipient no longer exists', function()
        local res = cb('accountTransfer', OWNER, { fromRef = 'personal', toIban = 'PF00000002', amount = 200 })
        assert_false(res.success)
        assert_eq(money(OWNER), 2000)
        assert_eq(lastTx().state, 'compensated')
    end)
    it('moves money between two IBAN accounts', function()
        local other = FakeDB.ibanAccount('ST1', 0, 'Other')
        local res = cb('accountTransfer', OWNER, { fromRef = ACC, toIban = FakeDB.v2[other].iban, amount = 400 })
        assert_true(res.success)
        assert_eq(acctBal(ACC), 600)
        assert_eq(acctBal(other), 400)
    end)
    it('a member without withdraw permission cannot send money out of the account', function()
        local res = cb('accountTransfer', MEMBER, { fromRef = ACC, toIban = 'PF00000001', amount = 100 })
        assert_false(res.success)
        assert_eq(acctBal(ACC), 1000)
    end)
    it('money sent to an account that was closed in the meantime goes back to the sender', function()
        local res = L.Transfer({ from = 'player:OW1:bank', to = 'acct:999', amount = 100, key = 'gone-acct' })
        assert_false(res.ok)
        assert_eq(res.state, 'compensated')
        assert_eq(money(OWNER), 2000)
    end)
end)

describe('IBAN accounts: open and close', function()
    it('the creation fee goes through the ledger and the new account gets a baseline', function()
        local res = cb('createAccount', OWNER, { label = 'Burger Fund', type = 'business' })
        assert_true(res.success)
        assert_eq(money(OWNER), 1500)
        assert_eq(lastTx().to_account, 'system:bank_fees')
        assert_eq(FakeDB.baselines['acct:' .. res.accountId], 0)
    end)
    it('without the fee no account is opened', function()
        Mock.players[OWNER].PlayerData.money.bank = 100
        local res = cb('createAccount', OWNER, { label = 'Broke Co', type = 'shared' })
        assert_false(res.success)
        assert_eq(#FakeDB.v2, 1)
        assert_eq(money(OWNER), 100)
    end)
    it('the fee is refunded when the account row cannot be written', function()
        FakeDB.failInsertV2 = true
        local res = cb('createAccount', OWNER, { label = 'Fails', type = 'shared' })
        assert_false(res.success)
        assert_eq(money(OWNER), 2000)
    end)
    it('an account with money in it cannot be closed; an empty one can', function()
        assert_false(cb('accountDelete', OWNER, { accountId = ACC }).success)
        assert_eq(acctBal(ACC), 1000)
        cb('accountWithdraw', OWNER, { accountId = ACC, amount = 1000 })
        assert_true(cb('accountDelete', OWNER, { accountId = ACC }).success)
        assert_eq(FakeDB.v2[ACC], nil)
        assert_eq(money(OWNER), 3000)
    end)
end)

describe('loans', function()
    local function apply(amount) return cb('applyLoan', OWNER, { tierIndex = 1, amount = amount or 10000 }) end

    it('a loan is paid out from system:loans', function()
        assert_true(apply().success)
        assert_eq(money(OWNER), 12000)
        assert_eq(FakeDB.loans[1].status, 'active')
        assert_eq(lastTx().from_account, 'system:loans')
    end)
    it('when the bank is unavailable the loan is voided and nothing is paid', function()
        L.ready = false
        assert_false(apply().success)
        L.ready = true
        assert_eq(money(OWNER), 2000)
        assert_eq(FakeDB.loans[1].status, 'void')
        assert_eq(#cb('getFinance', OWNER).loans, 0)
    end)
    it('an installment is charged once and reduces the loan', function()
        apply()
        local loan = FakeDB.loans[1]
        local before = loan.balance
        assert_true(cb('payLoan', OWNER, { loanId = 1 }).success)
        assert_eq(money(OWNER), 12000 - loan.payment_amount)
        assert_eq(loan.balance, before - loan.payment_amount)
        assert_eq(loan.payments_made, 1)
    end)
    it('a payment that failed for lack of funds works once the player has the money', function()
        apply()
        Mock.players[OWNER].PlayerData.money.bank = 0
        assert_false(cb('payLoan', OWNER, { loanId = 1 }).success)
        Mock.players[OWNER].PlayerData.money.bank = 5000
        assert_true(cb('payLoan', OWNER, { loanId = 1 }).success)
        assert_eq(FakeDB.loans[1].payments_made, 1)
    end)
    it('a payment charged just before a crash is applied on retry without charging again', function()
        apply()
        local loan = FakeDB.loans[1]
        -- the charge went through but the server died before the loan row was updated
        local key = ('loan:%d:installment:%d:%s'):format(loan.id, loan.payments_made, tostring(loan.balance))
        assert_true(L.Transfer({ from = 'player:OW1:bank', to = 'system:loans', amount = loan.payment_amount, key = key }).ok)
        local afterCharge = money(OWNER)
        assert_true(cb('payLoan', OWNER, { loanId = 1 }).success)
        assert_eq(money(OWNER), afterCharge)                            -- not charged a second time
        assert_eq(loan.payments_made, 1)
    end)
    it('payoff takes the exact balance and closes the loan', function()
        apply()
        local owed = FakeDB.loans[1].balance
        assert_true(cb('payoffLoan', OWNER, { loanId = 1 }).success)
        assert_eq(money(OWNER), 12000 - owed)
        assert_eq(FakeDB.loans[1].status, 'paid')
        assert_false(cb('payoffLoan', OWNER, { loanId = 1 }).success)  -- nothing left to pay
    end)
    it('autopay charges an offline borrower from their stored balance', function()
        FakeDB.players.OFF1.money.bank = 10000
        FakeDB.loans[1] = { id = 1, citizenid = 'OFF1', tier = 'Starter', principal = 2500, balance = 2950, apr = 18, payment_amount = 246,
            payments_total = 12, payments_made = 0, missed_payments = 0, next_payment = Mock.clock - 1, status = 'active' }
        BankingFinance.runLoanBilling()
        assert_eq(FakeDB.players.OFF1.money.bank, 10000 - 246)
        assert_eq(FakeDB.loans[1].payments_made, 1)
    end)
    it('a missed autopay adds one late fee per period, even if billing runs twice', function()
        FakeDB.loans[1] = { id = 1, citizenid = 'OFF1', tier = 'Starter', principal = 2500, balance = 2950, apr = 18, payment_amount = 246,
            payments_total = 12, payments_made = 0, missed_payments = 0, next_payment = Mock.clock - 1, status = 'active' }
        BankingFinance.runLoanBilling()
        BankingFinance.runLoanBilling()
        assert_eq(FakeDB.loans[1].missed_payments, 1)
        assert_eq(FakeDB.loans[1].balance, 2950 + math.ceil(246 * Config.loans.lateFeePct))
        assert_eq(FakeDB.players.OFF1.money.bank, 50)
    end)
    it('autopay while the bank is unavailable is not counted as a missed payment', function()
        FakeDB.loans[1] = { id = 1, citizenid = 'OW1', tier = 'Starter', principal = 2500, balance = 2950, apr = 18, payment_amount = 246,
            payments_total = 12, payments_made = 0, missed_payments = 0, next_payment = Mock.clock - 1, status = 'active' }
        L.ready = false
        BankingFinance.runLoanBilling()
        L.ready = true
        assert_eq(FakeDB.loans[1].missed_payments, 0)
        assert_eq(FakeDB.loans[1].balance, 2950)
    end)
end)

describe('credit cards', function()
    local function card(balance)
        FakeDB.cards[1] = { id = 1, citizenid = 'OW1', card_id = 'fleeca_green', credit_limit = 10000, balance = balance or 0, apr = 24, status = 'active' }
    end

    it('a cash advance adds debt plus fee and pays out through the ledger', function()
        card(0)
        assert_true(cb('cardAdvance', OWNER, { cardId = 1, amount = 1000 }).success)
        assert_eq(money(OWNER), 3000)
        assert_eq(FakeDB.cards[1].balance, 1020)
        assert_eq(lastTx().from_account, 'system:credit')
    end)
    it('an advance over the limit is refused and nothing moves', function()
        card(9500)
        assert_false(cb('cardAdvance', OWNER, { cardId = 1, amount = 1000 }).success)
        assert_eq(FakeDB.cards[1].balance, 9500)
        assert_eq(money(OWNER), 2000)
    end)
    it('a failed payout releases the reserved debt', function()
        card(0)
        L.ready = false
        assert_false(cb('cardAdvance', OWNER, { cardId = 1, amount = 1000 }).success)
        L.ready = true
        assert_eq(FakeDB.cards[1].balance, 0)
        assert_eq(money(OWNER), 2000)
    end)
    it('a card payment is charged and reduces the debt, never below zero', function()
        card(300)
        assert_true(cb('payCard', OWNER, { cardId = 1, amount = 5000 }).success)  -- capped at the debt
        assert_eq(money(OWNER), 1700)
        assert_eq(FakeDB.cards[1].balance, 0)
    end)
    it('if the debt shrinks while paying, the charge is refunded', function()
        card(300)
        local realTransfer = L.Transfer
        L.Transfer = function(opts)
            local res = realTransfer(opts)
            if opts.to == 'system:credit' then FakeDB.cards[1].balance = 100 end  -- another payment landed
            return res
        end
        local res = cb('payCard', OWNER, { cardId = 1, amount = 300 })
        L.Transfer = realTransfer
        assert_false(res.success)
        assert_eq(money(OWNER), 2000)
        assert_eq(FakeDB.cards[1].balance, 100)
    end)
end)
