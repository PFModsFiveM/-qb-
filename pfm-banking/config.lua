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

-- ── Branches ─────────────────────────────────────────────────────────
-- One name per Config.locations index (shown in the Bank app and in city events).
Config.branchNames = { 'Legion Square', 'Alta', 'Hawick Ave', 'Del Perro Blvd', 'Great Ocean Hwy', 'Route 68', 'Vinewood', 'Paleto Bay' }

-- A robbed branch closes (pfm-bankrobbery fires qb-banking:server:SetBankClosed). While closed, its
-- counter and the ATMs within `radius` refuse service on the server; it reopens by itself.
Config.BranchClosure = {
    minutes = 20,          -- how long a robbed branch stays closed
    maxMinutes = 180,      -- longest closure the /bankbranch admin command may set
    radius = 30.0,         -- counters and ATMs this close to a closed branch are closed too
}

-- pfm-bankrobbery bank ids (Config.SmallBanks index, 'paleto', 'pacific') -> Config.locations index.
Config.RobberyBranches = { [1] = 2, [2] = 1, [3] = 3, [4] = 4, [5] = 5, [6] = 6, paleto = 8, pacific = 7 }

-- ── Bank app (tablet and computer, pf-devices) ──────────────────────
-- Remote banking moves money between bank accounts only; cash stays at the counter and the ATM.
Config.App = {
    maxTransfer = 250000,          -- largest single payment to someone else
    maxInternal = 10000000,        -- largest single move between your own accounts / your society
    dailyTransferLimit = 1000000,  -- total sent to other people from the app in 24 hours
    statementPageSize = 25,
    cooldownMs = 1500,             -- minimum time between two money actions of one player
}

-- ── Cash points ──────────────────────────────────────────────────────
-- Cash changes hands only where the player stands (position read on the server): at a bank counter
-- (Config.locations) for withdrawals and deposits, or at an ATM (Config.ATMs) for withdrawals (the
-- ATM screen has no deposit). Remote banking (transfers, the Bank app) needs neither.
Config.CashRange = {
    counter = 5.0,   -- metres from a Config.locations point
    atm = 4.0,       -- metres from a Config.ATMs point (the points are where a player stands at the ATM)
}

-- Where the ATMs stand. The client opens the ATM screen next to any ATM model (Config.atmModels);
-- the server only opens it and pays out cash within Config.CashRange.atm of one of these points, so a
-- modified client cannot withdraw anywhere. An ATM that is missing here (for example one added by a
-- custom map) refuses cash until its position is added; an admin standing at it can use /atmcheck to
-- get the line to add. An empty list makes every ATM refuse (bank counters keep working).
--
-- Sources (positions copied as published, not measured here):
--   * esx_atm config.lua, Config.ATMLocations, GPL-3.0, Copyright (C) 2015-2018 Jérémie N'gadi
--     (ESX-Org/esx_atm, read from the mirror https://github.com/ESX-Brasil/esx_atm at a11170f).
--   * The last five: vRP vrp/cfg/atms.lua, MIT, Copyright (c) 2017 ImagicTheCat
--     (https://github.com/ImagicTheCat/vRP at 8d35fdf), the entries more than 2 m from every esx_atm
--     point, rounded to 3 decimals. The ATMs both lists share agree within about 1.6 m.
Config.ATMs = {
    vector3(-386.733, 6045.953, 31.501),
    vector3(-110.753, 6467.703, 31.784),
    vector3(155.4300, 6641.991, 31.784),
    vector3(174.6720, 6637.218, 31.784),
    vector3(1703.138, 6426.783, 32.730),
    vector3(1735.114, 6411.035, 35.164),
    vector3(1702.842, 4933.593, 42.051),
    vector3(1967.333, 3744.293, 32.272),
    vector3(1174.532, 2705.278, 38.027),
    vector3(2564.399, 2585.100, 38.016),
    vector3(2558.683, 349.6010, 108.050),
    vector3(2558.051, 389.4817, 108.660),
    vector3(1077.692, -775.796, 58.218),
    vector3(1139.018, -469.886, 66.789),
    vector3(1168.975, -457.241, 66.641),
    vector3(1153.884, -326.540, 69.245),
    vector3(236.4638, 217.4718, 106.840),
    vector3(265.0043, 212.1717, 106.780),
    vector3(-164.568, 233.5066, 94.919),
    vector3(-1827.04, 785.5159, 138.020),
    vector3(-1409.39, -99.2603, 52.473),
    vector3(-1215.64, -332.231, 37.881),
    vector3(-2072.41, -316.959, 13.345),
    vector3(-2975.72, 379.7737, 14.992),
    vector3(-2962.60, 482.1914, 15.762),
    vector3(-3144.13, 1127.415, 20.868),
    vector3(-1305.40, -706.240, 25.352),
    vector3(-717.614, -915.880, 19.268),
    vector3(-526.566, -1222.90, 18.434),
    vector3(149.4551, -1038.95, 29.366),
    vector3(-846.304, -340.402, 38.687),
    vector3(-1216.27, -331.461, 37.773),
    vector3(-56.1935, -1752.53, 29.452),
    vector3(-273.001, -2025.60, 30.197),
    vector3(314.187, -278.621, 54.170),
    vector3(-351.534, -49.529, 49.042),
    vector3(-1570.197, -546.651, 34.955),
    vector3(33.232, -1347.849, 29.497),
    vector3(129.216, -1292.347, 29.269),
    vector3(289.012, -1256.545, 29.440),
    vector3(1686.753, 4815.809, 42.008),
    vector3(-302.408, -829.945, 32.417),
    vector3(5.134, -919.949, 29.557),
    vector3(-284.037, 6224.385, 31.187),
    vector3(-135.165, 6365.738, 31.101),
    vector3(-94.9690, 6455.301, 31.784),
    vector3(1821.917, 3683.483, 34.244),
    vector3(540.0420, 2671.007, 42.177),
    vector3(381.2827, 323.2518, 103.270),
    vector3(285.2029, 143.5690, 104.970),
    vector3(157.7698, 233.5450, 106.450),
    vector3(-1205.35, -325.579, 37.870),
    vector3(-2955.70, 488.7218, 15.486),
    vector3(-3044.22, 595.2429, 7.595),
    vector3(-3241.10, 996.6881, 12.500),
    vector3(-3241.11, 1009.152, 12.877),
    vector3(-538.225, -854.423, 29.234),
    vector3(-711.156, -818.958, 23.768),
    vector3(-256.831, -719.646, 33.444),
    vector3(-203.548, -861.588, 30.205),
    vector3(112.4102, -776.162, 31.427),
    vector3(112.9290, -818.710, 31.386),
    vector3(119.9000, -883.826, 31.191),
    vector3(-261.692, -2012.64, 30.121),
    vector3(-254.112, -692.483, 33.616),
    vector3(-1415.909, -211.825, 46.500),
    vector3(-1430.122, -211.014, 46.500),
    vector3(287.645, -1282.646, 29.659),
    vector3(295.839, -895.640, 29.217),
    vector3(-1315.73, -834.89, 16.96),
    vector3(89.75, 2.35, 68.31),
    -- vRP (MIT)
    vector3(-821.566, -1081.903, 11.132),
    vector3(1171.523, 2702.449, 38.175),
    vector3(-1091.547, 2708.558, 18.944),
    vector3(-256.173, -716.032, 33.520),
    vector3(-660.728, -853.970, 24.484)
}
