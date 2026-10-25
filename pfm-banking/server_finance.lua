-- qb-banking finance module: credit score, loans, credit cards.
-- Money moves through PFLedger.Transfer between the player's bank and system:loans / system:credit.
-- Loan payments use natural idempotency keys (loan id + payment number, or billing period), and each
-- loan/card update is conditional on the row still being in the state that was charged for; when it
-- is not, the charge is refunded.
local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions' })
local L = PFLedger

local function bankRef(citizenid) return 'player:' .. citizenid .. ':bank' end

local function locked(citizenid, cb, fn)
    local status = L.WithLock('bank:' .. citizenid, fn)
    if status == 'busy' then cb({ success = false, message = 'Please wait for your last transaction' })
    elseif status == 'error' then cb({ success = false, message = 'Error' }) end
end

-- Returns a charge that could not be applied to its loan or card.
local function refund(res, citizenid, amount, systemAccount, reason)
    return L.Transfer({
        from = systemAccount, to = bankRef(citizenid), amount = amount,
        key = 'refund:' .. res.txId, kind = 'refund', reason = reason, actor = citizenid,
    })
end

-- ── schema ───────────────────────────────────────────────────────────
MySQL.ready(function()
    MySQL.query([[CREATE TABLE IF NOT EXISTS bank_credit (
        citizenid VARCHAR(50) NOT NULL PRIMARY KEY,
        score INT NOT NULL DEFAULT 650,
        updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
    )]])
    MySQL.query([[CREATE TABLE IF NOT EXISTS bank_loans (
        id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
        citizenid VARCHAR(50) NOT NULL,
        tier VARCHAR(32) NOT NULL,
        principal INT NOT NULL,
        balance INT NOT NULL,
        apr DECIMAL(5,2) NOT NULL,
        payment_amount INT NOT NULL,
        payments_total INT NOT NULL,
        payments_made INT NOT NULL DEFAULT 0,
        missed_payments INT NOT NULL DEFAULT 0,
        next_payment BIGINT NOT NULL,
        status VARCHAR(16) NOT NULL DEFAULT 'active',
        created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        INDEX idx_citizen (citizenid),
        INDEX idx_status (status)
    )]])
    MySQL.query([[CREATE TABLE IF NOT EXISTS bank_cards (
        id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
        citizenid VARCHAR(50) NOT NULL,
        card_id VARCHAR(32) NOT NULL,
        card_number VARCHAR(20) NOT NULL,
        credit_limit INT NOT NULL,
        balance INT NOT NULL DEFAULT 0,
        apr DECIMAL(5,2) NOT NULL,
        status VARCHAR(16) NOT NULL DEFAULT 'active',
        created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        INDEX idx_citizen (citizenid)
    )]])
end)

-- ── credit score ─────────────────────────────────────────────────────
local function GetCreditScore(citizenid)
    local score = MySQL.scalar.await('SELECT score FROM bank_credit WHERE citizenid = ?', { citizenid })
    if not score then
        score = Config.credit.default
        MySQL.insert('INSERT INTO bank_credit (citizenid, score) VALUES (?, ?)', { citizenid, score })
    end
    return score
end

local function AdjustCreditScore(citizenid, delta)
    local score = GetCreditScore(citizenid)
    local newScore = math.max(Config.credit.min, math.min(Config.credit.max, score + delta))
    MySQL.update('UPDATE bank_credit SET score = ? WHERE citizenid = ?', { newScore, citizenid })
    return newScore
end

exports('GetCreditScore', GetCreditScore)
exports('AdjustCreditScore', AdjustCreditScore)

-- ── helpers ──────────────────────────────────────────────────────────
local function getPlayer(src)
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return nil, nil end
    return Player, Player.PlayerData.citizenid
end

local function getLoans(citizenid)
    return MySQL.query.await('SELECT * FROM bank_loans WHERE citizenid = ? AND status = "active" ORDER BY id DESC', { citizenid }) or {}
end

local function getCards(citizenid)
    return MySQL.query.await('SELECT * FROM bank_cards WHERE citizenid = ? AND status = "active" ORDER BY id DESC', { citizenid }) or {}
end

local function notify(src, msg, kind)
    TriggerClientEvent('QBCore:Notify', src, msg, kind or 'primary')
end

-- ── finance snapshot for the UI ──────────────────────────────────────
QBCore.Functions.CreateCallback('qb-banking:server:getFinance', function(source, cb)
    local Player, citizenid = getPlayer(source)
    if not Player then return cb(nil) end
    local score = GetCreditScore(citizenid)
    cb({
        score = score,
        scoreMin = Config.credit.min,
        scoreMax = Config.credit.max,
        loans = getLoans(citizenid),
        cards = getCards(citizenid),
        tiers = Config.loans.tiers,
        cardProducts = Config.creditCards.products,
        maxActiveLoans = Config.loans.maxActive,
        advanceFeePct = Config.creditCards.advanceFeePct,
    })
end)

-- ── loans ────────────────────────────────────────────────────────────
QBCore.Functions.CreateCallback('qb-banking:server:applyLoan', function(source, cb, data)
    local Player, citizenid = getPlayer(source)
    if not Player then return cb({ success = false, message = 'Error' }) end

    data = data or {}
    local tier = Config.loans.tiers[tonumber(data.tierIndex) or 0]
    local amount = math.floor(tonumber(data.amount) or 0)
    if not tier or amount < tier.amountMin or amount > tier.amountMax then
        return cb({ success = false, message = 'Invalid loan request' })
    end

    locked(citizenid, cb, function()
        local score = GetCreditScore(citizenid)
        if score < tier.minScore then
            return cb({ success = false, message = ('Your credit score (%d) is too low for this loan'):format(score) })
        end

        local active = getLoans(citizenid)
        if #active >= Config.loans.maxActive then
            return cb({ success = false, message = 'You already have the maximum number of active loans' })
        end

        local total = math.ceil(amount * (1 + tier.apr / 100))
        local payment = math.ceil(total / tier.payments)
        local nextPayment = os.time() + Config.loans.billingIntervalMinutes * 60

        -- the loan row exists before the money does; if the payout fails the loan is voided
        local loanId = MySQL.insert.await('INSERT INTO bank_loans (citizenid, tier, principal, balance, apr, payment_amount, payments_total, next_payment) VALUES (?, ?, ?, ?, ?, ?, ?, ?)', {
            citizenid, tier.name, amount, total, tier.apr, payment, tier.payments, nextPayment,
        })
        if not loanId then return cb({ success = false, message = 'Error' }) end
        local res = L.Transfer({
            from = 'system:loans', to = bankRef(citizenid), amount = amount,
            key = ('loan:%d:disburse'):format(loanId), kind = 'loan', reason = ('%s loan'):format(tier.name), actor = citizenid,
        })
        if not res.ok then
            MySQL.update.await('UPDATE bank_loans SET status = "void" WHERE id = ? AND payments_made = 0', { loanId })
            return cb({ success = false, message = L.Message(res.error) })
        end

        exports['pfm-banking']:CreateBankStatement(source, 'checking', amount, ('%s loan disbursed'):format(tier.name), 'deposit', 'player')
        TriggerEvent('qb-log:server:CreateLog', 'banking', 'Loan Issued', 'green', ('**%s** took a %s loan of $%s (total owed $%s)'):format(GetPlayerName(source), tier.name, amount, total))
        cb({ success = true, message = ('Loan approved — $%s deposited'):format(amount) })
    end)
end)

--- The idempotency key for a payment on a loan in its current state. Any change to the loan
--- (a payment, a late fee) changes the key; manual payment and autopay of the same installment share it.
local function loanKey(loan, what)
    return ('loan:%d:%s:%d:%s'):format(loan.id, what, tonumber(loan.payments_made) or 0, tostring(tonumber(loan.balance) or 0))
end

--- Charges one loan payment and applies it; a retry with the same loan state never charges twice.
--- Returns ok, error code or the loan's new balance.
local function collectLoanPayment(loan, amount, key, reason, kind)
    local opts = {
        from = bankRef(loan.citizenid), to = 'system:loans', amount = amount,
        key = key, kind = kind or 'loan_payment', reason = reason, actor = loan.citizenid,
        metadata = { loan = loan.id },
    }
    local res = L.Transfer(opts)
    if not res.ok and res.duplicate and (res.state == 'failed' or res.state == 'compensated') then
        -- an earlier attempt for this installment moved no money (e.g. the player was short): try again
        opts.key = key .. ':' .. L.NewTxId()
        res = L.Transfer(opts)
    end
    if not res.ok then return false, res.error end

    local newBalance = loan.balance - amount
    local applied
    if newBalance <= 0 then
        applied = MySQL.update.await('UPDATE bank_loans SET balance = 0, payments_made = payments_made + 1, status = "paid" WHERE id = ? AND status = "active" AND payments_made = ? AND balance = ?',
            { loan.id, loan.payments_made, loan.balance })
    else
        applied = MySQL.update.await('UPDATE bank_loans SET balance = ?, payments_made = payments_made + 1, next_payment = ? WHERE id = ? AND status = "active" AND payments_made = ? AND balance = ?',
            { newBalance, os.time() + Config.loans.billingIntervalMinutes * 60, loan.id, loan.payments_made, loan.balance })
    end
    if (tonumber(applied) or 0) < 1 then
        -- the loan changed between reading it and charging (another payment won): give the money back
        if not res.duplicate then refund(res, loan.citizenid, amount, 'system:loans', 'Loan payment refund') end
        return false, 'loan_changed'
    end
    return true, math.max(0, newBalance)
end

QBCore.Functions.CreateCallback('qb-banking:server:payLoan', function(source, cb, data)
    local Player, citizenid = getPlayer(source)
    if not Player then return cb({ success = false, message = 'Error' }) end
    data = data or {}
    locked(citizenid, cb, function()
        local loan = MySQL.single.await('SELECT * FROM bank_loans WHERE id = ? AND citizenid = ? AND status = "active"', { tonumber(data.loanId), citizenid })
        if not loan then return cb({ success = false, message = 'Loan not found' }) end

        local amount = math.min(loan.payment_amount, loan.balance)
        local ok, result = collectLoanPayment(loan, amount, loanKey(loan, 'installment'), 'Loan payment')
        if not ok then
            local msg = result == 'insufficient_funds' and 'Insufficient bank balance'
                or result == 'loan_changed' and 'The loan was just updated — try again' or L.Message(result)
            return cb({ success = false, message = msg })
        end

        exports['pfm-banking']:CreateBankStatement(source, 'checking', amount, 'Loan payment', 'withdraw', 'player')
        if result <= 0 then
            AdjustCreditScore(citizenid, Config.credit.loanPayoff)
            cb({ success = true, message = 'Loan fully paid off — credit score increased' })
        else
            AdjustCreditScore(citizenid, Config.credit.onTimePayment)
            cb({ success = true, message = ('Payment made — $%s remaining'):format(result) })
        end
    end)
end)

QBCore.Functions.CreateCallback('qb-banking:server:payoffLoan', function(source, cb, data)
    local Player, citizenid = getPlayer(source)
    if not Player then return cb({ success = false, message = 'Error' }) end
    data = data or {}
    locked(citizenid, cb, function()
        local loan = MySQL.single.await('SELECT * FROM bank_loans WHERE id = ? AND citizenid = ? AND status = "active"', { tonumber(data.loanId), citizenid })
        if not loan then return cb({ success = false, message = 'Loan not found' }) end

        local ok, result = collectLoanPayment(loan, loan.balance, loanKey(loan, 'payoff'), 'Loan payoff', 'loan_payoff')
        if not ok then
            local msg = result == 'insufficient_funds' and 'Insufficient bank balance'
                or result == 'loan_changed' and 'The loan was just updated — try again' or L.Message(result)
            return cb({ success = false, message = msg })
        end
        AdjustCreditScore(citizenid, Config.credit.loanPayoff)
        exports['pfm-banking']:CreateBankStatement(source, 'checking', loan.balance, 'Loan payoff', 'withdraw', 'player')
        cb({ success = true, message = 'Loan paid off — credit score increased' })
    end)
end)

-- ── credit cards ─────────────────────────────────────────────────────
local function getCardProduct(id)
    for _, p in ipairs(Config.creditCards.products) do
        if p.id == id then return p end
    end
end

QBCore.Functions.CreateCallback('qb-banking:server:orderCreditCard', function(source, cb, data)
    local Player, citizenid = getPlayer(source)
    if not Player then return cb({ success = false, message = 'Error' }) end
    local product = type(data) == 'table' and getCardProduct(data.cardId) or nil
    if not product then return cb({ success = false, message = 'Unknown card' }) end

    local score = GetCreditScore(citizenid)
    if score < product.minScore then
        return cb({ success = false, message = ('Your credit score (%d) is too low for this card'):format(score) })
    end

    local existing = MySQL.scalar.await('SELECT COUNT(*) FROM bank_cards WHERE citizenid = ? AND card_id = ? AND status = "active"', { citizenid, product.id })
    if existing and existing > 0 then
        return cb({ success = false, message = 'You already hold this card' })
    end

    local cardNumber = ('%d %d %d %d'):format(math.random(4000, 4999), math.random(1000, 9999), math.random(1000, 9999), math.random(1000, 9999))
    MySQL.insert('INSERT INTO bank_cards (citizenid, card_id, card_number, credit_limit, apr) VALUES (?, ?, ?, ?, ?)', {
        citizenid, product.id, cardNumber, product.limit, product.apr,
    })
    TriggerEvent('qb-log:server:CreateLog', 'banking', 'Credit Card Issued', 'green', ('**%s** was issued a %s'):format(GetPlayerName(source), product.label))
    cb({ success = true, message = ('%s approved'):format(product.label) })
end)

QBCore.Functions.CreateCallback('qb-banking:server:cardAdvance', function(source, cb, data)
    local Player, citizenid = getPlayer(source)
    if not Player then return cb({ success = false, message = 'Error' }) end
    data = data or {}
    local amount = math.floor(tonumber(data.amount) or 0)
    if amount < 1 or not L.Amount(amount) then return cb({ success = false, message = 'Invalid amount' }) end
    local fee = math.ceil(amount * Config.creditCards.advanceFeePct)

    locked(citizenid, cb, function()
        local card = MySQL.single.await('SELECT * FROM bank_cards WHERE id = ? AND citizenid = ? AND status = "active"', { tonumber(data.cardId), citizenid })
        if not card then return cb({ success = false, message = 'Card not found' }) end

        -- reserve the debt first (the limit check is part of the UPDATE), then pay out; a failed payout
        -- releases the reservation. A crash in between leaves the debt without the cash, never free cash.
        local reserved = MySQL.update.await('UPDATE bank_cards SET balance = balance + ? WHERE id = ? AND status = "active" AND balance + ? <= credit_limit',
            { amount + fee, card.id, amount + fee })
        if (tonumber(reserved) or 0) < 1 then
            return cb({ success = false, message = 'That would exceed your credit limit' })
        end
        local res = L.Transfer({
            from = 'system:credit', to = bankRef(citizenid), amount = amount,
            key = L.AutoKey('cardadv'), kind = 'card_advance', reason = 'Credit card cash advance', actor = citizenid,
            metadata = { card = card.id, fee = fee },
        })
        if not res.ok then
            MySQL.update.await('UPDATE bank_cards SET balance = balance - ? WHERE id = ?', { amount + fee, card.id })
            return cb({ success = false, message = L.Message(res.error) })
        end
        exports['pfm-banking']:CreateBankStatement(source, 'checking', amount, ('Cash advance (fee $%s)'):format(fee), 'deposit', 'player')
        cb({ success = true, message = ('$%s advanced (fee $%s)'):format(amount, fee) })
    end)
end)

QBCore.Functions.CreateCallback('qb-banking:server:payCard', function(source, cb, data)
    local Player, citizenid = getPlayer(source)
    if not Player then return cb({ success = false, message = 'Error' }) end
    data = data or {}
    locked(citizenid, cb, function()
        local card = MySQL.single.await('SELECT * FROM bank_cards WHERE id = ? AND citizenid = ? AND status = "active"', { tonumber(data.cardId), citizenid })
        if not card then return cb({ success = false, message = 'Card not found' }) end

        local amount = math.min(math.floor(tonumber(data.amount) or 0), card.balance)
        if amount < 1 then return cb({ success = false, message = 'Nothing to pay' }) end

        local res = L.Transfer({
            from = bankRef(citizenid), to = 'system:credit', amount = amount,
            key = L.AutoKey('cardpay'), kind = 'card_payment', reason = 'Credit card payment', actor = citizenid,
            metadata = { card = card.id },
        })
        if not res.ok then
            local msg = res.error == 'insufficient_funds' and 'Insufficient bank balance' or L.Message(res.error)
            return cb({ success = false, message = msg })
        end
        -- never pay below zero: if interest or another payment changed the debt, refund the charge
        local applied = MySQL.update.await('UPDATE bank_cards SET balance = balance - ? WHERE id = ? AND balance >= ?', { amount, card.id, amount })
        if (tonumber(applied) or 0) < 1 then
            refund(res, citizenid, amount, 'system:credit', 'Credit card payment refund')
            return cb({ success = false, message = 'Your card balance just changed — payment refunded' })
        end

        exports['pfm-banking']:CreateBankStatement(source, 'checking', amount, 'Credit card payment', 'withdraw', 'player')
        if amount >= card.balance then
            AdjustCreditScore(citizenid, Config.credit.cardInterestPaid)
            cb({ success = true, message = 'Card balance cleared — credit score increased' })
        else
            cb({ success = true, message = ('Paid $%s toward your card'):format(amount) })
        end
    end)
end)

-- ── billing cycle: loan installments + card interest ─────────────────
local function runLoanBilling()
    local due = MySQL.query.await('SELECT * FROM bank_loans WHERE status = "active" AND next_payment <= ?', { os.time() }) or {}
    for _, loan in ipairs(due) do
        -- skipped (and retried next cycle) while the player is in the middle of a bank action
        L.WithLock('bank:' .. loan.citizenid, function()
            local amount = math.min(loan.payment_amount, loan.balance)
            -- the ledger charges online and offline players alike
            local ok, result = collectLoanPayment(loan, amount, loanKey(loan, 'installment'), 'Loan autopay', 'loan_autopay')
            local Online = QBCore.Functions.GetPlayerByCitizenId(loan.citizenid)
            local src = Online and Online.PlayerData.source
            if ok then
                AdjustCreditScore(loan.citizenid, result <= 0 and Config.credit.loanPayoff or Config.credit.onTimePayment)
                if src then notify(src, ('Loan installment of $%s collected'):format(amount), 'primary') end
            elseif result == 'insufficient_funds' then
                -- only a real shortfall is a missed payment; conditional on next_payment so it applies once per period
                local lateFee = math.ceil(loan.payment_amount * Config.loans.lateFeePct)
                local nextPayment = os.time() + Config.loans.billingIntervalMinutes * 60
                local charged = MySQL.update.await('UPDATE bank_loans SET balance = balance + ?, missed_payments = missed_payments + 1, next_payment = ? WHERE id = ? AND status = "active" AND next_payment = ?',
                    { lateFee, nextPayment, loan.id, loan.next_payment })
                if (tonumber(charged) or 0) > 0 then
                    AdjustCreditScore(loan.citizenid, Config.credit.missedPayment)
                    if src then notify(src, ('Missed loan payment — $%s late fee added, credit score reduced'):format(lateFee), 'error') end
                end
            end
            -- any other error (bank unavailable, loan changed) is retried next cycle without a penalty
        end)
    end
end

local function runCardInterest()
    -- flat per-cycle interest on carried balances (apr spread over a week of cycles)
    local cycles = math.max(1, math.floor((7 * 24 * 60) / Config.creditCards.interestIntervalMinutes))
    MySQL.update('UPDATE bank_cards SET balance = CEIL(balance * (1 + (apr / 100) / 52 / ?)) WHERE status = "active" AND balance > 0', { cycles })
end

-- resource-wide handle (used by the test harness to run one billing cycle)
BankingFinance = { runLoanBilling = runLoanBilling, runCardInterest = runCardInterest }

CreateThread(function()
    while true do
        Wait(Config.loans.billingIntervalMinutes * 60 * 1000)
        local ok, err = pcall(runLoanBilling)
        if not ok then print('[qb-banking] loan billing error: ' .. tostring(err)) end
        local ok2, err2 = pcall(runCardInterest)
        if not ok2 then print('[qb-banking] card interest error: ' .. tostring(err2)) end
    end
end)
