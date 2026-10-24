Config = {
    useTarget = GetConvar('UseTarget', 'false') == 'true',
    atmModels = { 'prop_atm_01', 'prop_atm_02', 'prop_atm_03', 'prop_fleeca_atm' },
    useDailyLimit = true,
    dailyLimit = 5000,
    maxAccounts = 2,
    blipInfo = {
        name = 'Bank',
        sprite = 108,
        color = 2,
        scale = 0.55
    },
    locations = {
        vector3(149.05, -1041.3, 29.37),
        vector3(313.32, -280.03, 54.17),
        vector3(-351.94, -50.72, 49.04),
        vector3(-1212.68, -331.83, 37.78),
        vector3(-2961.67, 482.31, 15.7),
        vector3(1175.64, 2707.71, 38.09),
        vector3(247.65, 223.87, 106.29),
        vector3(-111.98, 6470.56, 31.63)
    }
}

-- ── Bank brands ──────────────────────────────────────────────────────
-- One entry per Config.locations index. ATMs and unknown locations use 'fleeca'.
Config.locationBrands = { 'fleeca', 'fleeca', 'fleeca', 'fleeca', 'fleeca', 'fleeca', 'pacific', 'blaine' }

Config.brandStyles = {
    fleeca  = { label = 'Fleeca Bank',            short = 'FLEECA',  accent = '#2fbf71', gradient = { '#124c31', '#2fbf71' } },
    maze    = { label = 'Maze Bank',              short = 'MAZE',    accent = '#e03a3a', gradient = { '#5c1010', '#e03a3a' } },
    pacific = { label = 'Pacific Standard',       short = 'PACIFIC', accent = '#4f8cff', gradient = { '#12284c', '#4f8cff' } },
    blaine  = { label = 'Blaine County Savings',  short = 'BCS',     accent = '#d8a33c', gradient = { '#4c3812', '#d8a33c' } },
    pf      = { label = 'PF Credit Union',        short = 'PFCU',    accent = '#5b9dff', gradient = { '#15253f', '#5b9dff' } },
}

-- ── Multi-account banking (server_accounts.lua) ─────────────────────
-- Legacy shared accounts (bank_accounts, type 'shared') are moved to IBAN accounts at start and the
-- legacy "open account" is closed. Set to false to keep the legacy kind (not recommended).
Config.MigrateLegacySharedAccounts = true
Config.AccountCreationFee = 500          -- charged from bank when opening a shared/business account
Config.MaxOwnedAccounts = 3              -- max shared/business accounts owned per citizen
Config.MaxCardsPerAccount = 4            -- max active (non-cancelled) cards per account / personal

-- ── Credit score ─────────────────────────────────────────────────────
Config.credit = {
    default = 650,                       -- starting score for new citizens
    min = 300,
    max = 850,
    onTimePayment = 4,                   -- score gained per on-time loan payment
    missedPayment = -18,                 -- score lost per missed loan payment
    loanPayoff = 15,                     -- score gained for fully paying off a loan
    cardInterestPaid = 2,                -- score gained when card balance cleared
}

-- ── Loans ────────────────────────────────────────────────────────────
Config.loans = {
    maxActive = 2,                       -- active loans per citizen
    billingIntervalMinutes = 30,         -- how often a loan installment is due
    lateFeePct = 0.05,                   -- % of the installment added when a payment is missed
    tiers = {
        -- Flat interest: total owed = amount * (1 + apr/100). Paid over `payments` installments.
        { name = 'Starter',  minScore = 300, amountMin = 2500,  amountMax = 25000,  apr = 18.0, payments = 12 },
        { name = 'Standard', minScore = 580, amountMin = 10000, amountMax = 75000,  apr = 11.5, payments = 16 },
        { name = 'Premier',  minScore = 660, amountMin = 25000, amountMax = 200000, apr = 7.0,  payments = 20 },
        { name = 'Platinum', minScore = 740, amountMin = 50000, amountMax = 500000, apr = 4.5,  payments = 24 },
    },
}

-- ── Credit cards ─────────────────────────────────────────────────────
Config.creditCards = {
    advanceFeePct = 0.02,                -- fee on cash advances
    interestIntervalMinutes = 30,        -- how often interest accrues on carried balances
    products = {
        { id = 'fleeca_green',   label = 'Fleeca Green',   minScore = 300, limit = 10000,  apr = 24.0, gradient = { '#124c31', '#2fbf71' } },
        { id = 'maze_platinum',  label = 'Maze Platinum',  minScore = 640, limit = 50000,  apr = 16.0, gradient = { '#3c3c46', '#9fa6b8' } },
        { id = 'pacific_black',  label = 'Pacific Black',  minScore = 760, limit = 250000, apr = 9.0,  gradient = { '#0a0a0e', '#2c2c38' } },
    },
}
