-- qb-banking finance module: credit score, loans, credit cards
local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions' })

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

    local tier = Config.loans.tiers[tonumber(data.tierIndex) or 0]
    local amount = math.floor(tonumber(data.amount) or 0)
    if not tier or amount < tier.amountMin or amount > tier.amountMax then
        return cb({ success = false, message = 'Invalid loan request' })
    end

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

    MySQL.insert('INSERT INTO bank_loans (citizenid, tier, principal, balance, apr, payment_amount, payments_total, next_payment) VALUES (?, ?, ?, ?, ?, ?, ?, ?)', {
        citizenid, tier.name, amount, total, tier.apr, payment, tier.payments, nextPayment,
    })

    Player.Functions.AddMoney('bank', amount, ('bank-loan (%s)'):format(tier.name))
    exports['pfm-banking']:CreateBankStatement(source, 'checking', amount, ('%s loan disbursed'):format(tier.name), 'deposit', 'player')
    TriggerEvent('qb-log:server:CreateLog', 'banking', 'Loan Issued', 'green', ('**%s** took a %s loan of $%s (total owed $%s)'):format(GetPlayerName(source), tier.name, amount, total))
    cb({ success = true, message = ('Loan approved — $%s deposited'):format(amount) })
end)

local function chargeLoanPayment(loan, amount, Player)
    -- returns true when paid
    if Player and Player.PlayerData.money.bank >= amount then
        Player.Functions.RemoveMoney('bank', amount, 'loan-payment')
        return true
    end
    return false
end

QBCore.Functions.CreateCallback('qb-banking:server:payLoan', function(source, cb, data)
    local Player, citizenid = getPlayer(source)
    if not Player then return cb({ success = false, message = 'Error' }) end
    local loan = MySQL.single.await('SELECT * FROM bank_loans WHERE id = ? AND citizenid = ? AND status = "active"', { tonumber(data.loanId), citizenid })
    if not loan then return cb({ success = false, message = 'Loan not found' }) end

    local amount = math.min(loan.payment_amount, loan.balance)
    if not chargeLoanPayment(loan, amount, Player) then
        return cb({ success = false, message = 'Insufficient bank balance' })
    end

    local newBalance = loan.balance - amount
    local made = loan.payments_made + 1
    if newBalance <= 0 then
        MySQL.update('UPDATE bank_loans SET balance = 0, payments_made = ?, status = "paid" WHERE id = ?', { made, loan.id })
        AdjustCreditScore(citizenid, Config.credit.loanPayoff)
        cb({ success = true, message = 'Loan fully paid off — credit score increased' })
    else
        MySQL.update('UPDATE bank_loans SET balance = ?, payments_made = ?, next_payment = ? WHERE id = ?', {
            newBalance, made, os.time() + Config.loans.billingIntervalMinutes * 60, loan.id,
        })
        AdjustCreditScore(citizenid, Config.credit.onTimePayment)
        cb({ success = true, message = ('Payment made — $%s remaining'):format(newBalance) })
    end
    exports['pfm-banking']:CreateBankStatement(source, 'checking', amount, 'Loan payment', 'withdraw', 'player')
end)

QBCore.Functions.CreateCallback('qb-banking:server:payoffLoan', function(source, cb, data)
    local Player, citizenid = getPlayer(source)
    if not Player then return cb({ success = false, message = 'Error' }) end
    local loan = MySQL.single.await('SELECT * FROM bank_loans WHERE id = ? AND citizenid = ? AND status = "active"', { tonumber(data.loanId), citizenid })
    if not loan then return cb({ success = false, message = 'Loan not found' }) end
    if Player.PlayerData.money.bank < loan.balance then
        return cb({ success = false, message = 'Insufficient bank balance' })
    end
    Player.Functions.RemoveMoney('bank', loan.balance, 'loan-payoff')
    MySQL.update('UPDATE bank_loans SET balance = 0, status = "paid" WHERE id = ?', { loan.id })
    AdjustCreditScore(citizenid, Config.credit.loanPayoff)
    exports['pfm-banking']:CreateBankStatement(source, 'checking', loan.balance, 'Loan payoff', 'withdraw', 'player')
    cb({ success = true, message = 'Loan paid off — credit score increased' })
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
    local product = getCardProduct(data.cardId)
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
    local card = MySQL.single.await('SELECT * FROM bank_cards WHERE id = ? AND citizenid = ? AND status = "active"', { tonumber(data.cardId), citizenid })
    if not card then return cb({ success = false, message = 'Card not found' }) end

    local amount = math.floor(tonumber(data.amount) or 0)
    if amount < 1 then return cb({ success = false, message = 'Invalid amount' }) end
    local fee = math.ceil(amount * Config.creditCards.advanceFeePct)
    if card.balance + amount + fee > card.credit_limit then
        return cb({ success = false, message = 'That would exceed your credit limit' })
    end

    MySQL.update('UPDATE bank_cards SET balance = balance + ? WHERE id = ?', { amount + fee, card.id })
    Player.Functions.AddMoney('bank', amount, 'card-advance')
    exports['pfm-banking']:CreateBankStatement(source, 'checking', amount, ('Cash advance (fee $%s)'):format(fee), 'deposit', 'player')
    cb({ success = true, message = ('$%s advanced (fee $%s)'):format(amount, fee) })
end)

QBCore.Functions.CreateCallback('qb-banking:server:payCard', function(source, cb, data)
    local Player, citizenid = getPlayer(source)
    if not Player then return cb({ success = false, message = 'Error' }) end
    local card = MySQL.single.await('SELECT * FROM bank_cards WHERE id = ? AND citizenid = ? AND status = "active"', { tonumber(data.cardId), citizenid })
    if not card then return cb({ success = false, message = 'Card not found' }) end

    local amount = math.min(math.floor(tonumber(data.amount) or 0), card.balance)
    if amount < 1 then return cb({ success = false, message = 'Nothing to pay' }) end
    if Player.PlayerData.money.bank < amount then
        return cb({ success = false, message = 'Insufficient bank balance' })
    end

    Player.Functions.RemoveMoney('bank', amount, 'card-payment')
    MySQL.update('UPDATE bank_cards SET balance = balance - ? WHERE id = ?', { amount, card.id })
    exports['pfm-banking']:CreateBankStatement(source, 'checking', amount, 'Credit card payment', 'withdraw', 'player')
    if amount >= card.balance then
        AdjustCreditScore(citizenid, Config.credit.cardInterestPaid)
        cb({ success = true, message = 'Card balance cleared — credit score increased' })
    else
        cb({ success = true, message = ('Paid $%s toward your card'):format(amount) })
    end
end)

-- ── billing cycle: loan installments + card interest ─────────────────
local function runLoanBilling()
    local due = MySQL.query.await('SELECT * FROM bank_loans WHERE status = "active" AND next_payment <= ?', { os.time() }) or {}
    for _, loan in ipairs(due) do
        local Player = QBCore.Functions.GetPlayerByCitizenId(loan.citizenid)
        local offline = false
        if not Player then
            Player = QBCore.Functions.GetOfflinePlayerByCitizenId(loan.citizenid)
            offline = true
        end
        local amount = math.min(loan.payment_amount, loan.balance)
        local paid = false
        if Player and Player.PlayerData.money.bank >= amount then
            Player.Functions.RemoveMoney('bank', amount, 'loan-autopay')
            if offline then Player.Functions.Save() end
            paid = true
        end
        local nextPayment = os.time() + Config.loans.billingIntervalMinutes * 60
        if paid then
            local newBalance = loan.balance - amount
            if newBalance <= 0 then
                MySQL.update('UPDATE bank_loans SET balance = 0, payments_made = payments_made + 1, status = "paid" WHERE id = ?', { loan.id })
                AdjustCreditScore(loan.citizenid, Config.credit.loanPayoff)
            else
                MySQL.update('UPDATE bank_loans SET balance = ?, payments_made = payments_made + 1, next_payment = ? WHERE id = ?', { newBalance, nextPayment, loan.id })
                AdjustCreditScore(loan.citizenid, Config.credit.onTimePayment)
            end
            if not offline and Player.PlayerData.source then
                notify(Player.PlayerData.source, ('Loan installment of $%s collected'):format(amount), 'primary')
            end
        else
            local lateFee = math.ceil(loan.payment_amount * Config.loans.lateFeePct)
            MySQL.update('UPDATE bank_loans SET balance = balance + ?, missed_payments = missed_payments + 1, next_payment = ? WHERE id = ?', { lateFee, nextPayment, loan.id })
            AdjustCreditScore(loan.citizenid, Config.credit.missedPayment)
            if Player and not offline and Player.PlayerData.source then
                notify(Player.PlayerData.source, ('Missed loan payment — $%s late fee added, credit score reduced'):format(lateFee), 'error')
            end
        end
    end
end

local function runCardInterest()
    -- flat per-cycle interest on carried balances (apr spread over a week of cycles)
    local cycles = math.max(1, math.floor((7 * 24 * 60) / Config.creditCards.interestIntervalMinutes))
    MySQL.update('UPDATE bank_cards SET balance = CEIL(balance * (1 + (apr / 100) / 52 / ?)) WHERE status = "active" AND balance > 0', { cycles })
end

CreateThread(function()
    while true do
        Wait(Config.loans.billingIntervalMinutes * 60 * 1000)
        local ok, err = pcall(runLoanBilling)
        if not ok then print('[qb-banking] loan billing error: ' .. tostring(err)) end
        local ok2, err2 = pcall(runCardInterest)
        if not ok2 then print('[qb-banking] card interest error: ' .. tostring(err2)) end
    end
end)
