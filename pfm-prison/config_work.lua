-- Prison work and the inmate economy (batch 19E; server/work.lua, server/economy.lua, client/jobs.lua).
-- PF_ARCHITECTURE 4.8: work earns a capped time credit on the pf-justice order (AdjustOrder, key
-- pfm-prison:credit:<orderId>:<ticket>) and a wage paid from society:corrections into the inmate
-- trust (ledger account system:pfm-prison-trust); the trust buys at the commissary, pays a share
-- of each wage as restitution, and is paid out to the bank at release. Every position below is a
-- spot inside the Bolingbroke walls; check each one in game and move it if needed.

Config.Work = {
    Enabled = true,
    -- limits per inmate and UTC day (os.time() // 86400), counted from pf_prison_work_log
    MaxTicketsPerDay = 12,
    MaxCreditSecondsPerDay = 2400, -- pf-justice also caps all credits at Config.Credits.MaxShare of the sentence
    MaxWagePerDay = 600,
    Reach = 2.5,                   -- metres from a station (server position) for a step to count
    MaxTravelSpeed = 9.0,          -- m/s between two stations; faster is a teleport and voids the shift
    StartCooldown = 20,            -- seconds between two shift starts of one inmate
    MaxSessionSeconds = 1200,      -- an unfinished shift is dropped after this (a maintenance claim is released)
    CreditRetrySeconds = 30,       -- a credit pf-justice could not take now is retried (same key) this often
    -- where an inmate picks a shift (the work board)
    Board = vector3(1772.6, 2552.3, 45.6),
    -- the jobs. creditSeconds / wage per finished shift (before the daily caps). steps: stations in
    -- order; minSeconds = the least time since the previous step (the client's progress bar is shorter)
    Jobs = {
        kitchen = {
            label = 'Kitchen', creditSeconds = 300, wage = 45, minSeconds = 60,
            steps = {
                { label = 'Prepare ingredients', coords = vector3(1781.2, 2559.8, 45.67), minSeconds = 10 },
                { label = 'Cook the meals', coords = vector3(1777.4, 2561.6, 45.67), minSeconds = 15 },
                { label = 'Plate the trays', coords = vector3(1784.6, 2555.6, 45.67), minSeconds = 10 },
            },
        },
        laundry = {
            label = 'Laundry', creditSeconds = 240, wage = 40, minSeconds = 60,
            steps = {
                { label = 'Collect dirty linen', coords = vector3(1767.2, 2531.4, 45.56), minSeconds = 8 },
                { label = 'Load the washer', coords = vector3(1774.8, 2526.9, 45.56), minSeconds = 15 },
                { label = 'Dry and fold', coords = vector3(1771.2, 2522.5, 45.56), minSeconds = 15 },
            },
        },
        -- municipal work orders (pf-government) at the prison's own sites; shown only while
        -- pf-government accepts pfm-prison as a caller and knows the district
        maintenance = { label = 'Maintenance', creditSeconds = 360, wage = 55, minSeconds = 0 },
        -- the old electrician round (spots in Config.Locations.jobs, assigned by server/main.lua)
        electrician = { label = 'Electrician', creditSeconds = 120, wage = 25 },
    },
    -- the kitchen fills the canteen: each shift adds Portions of MealItem to the canteen stash, and
    -- the routine's meal times (server/schedule.lua, 19D) serve each inmate from that stock first
    -- (the schedule's own Config.Routine.Meal only when the canteen is empty)
    Kitchen = {
        Stash = 'pfm_prison_canteen', StashLabel = 'Prison canteen', StashSlots = 20, StashWeight = 200000,
        MealItem = 'sandwich', Portions = 4, MaxStock = 60,
    },
    -- the laundry produces clean linen (laundry_bag) into the prison laundry stash; full batches move
    -- to the hospital linen stash (a stash transfer, rolled back if the hospital stash refuses them)
    Laundry = {
        Item = 'laundry_bag', BagsPerShift = 2,
        Stash = 'pfm_prison_laundry', StashLabel = 'Prison laundry', StashSlots = 10, StashWeight = 100000,
        HospitalStash = 'pf_hosp_linen_pillbox', HospitalLabel = 'Pillbox linen store', HospitalSlots = 20, HospitalWeight = 200000,
        ShipBatch = 6, MaxHospitalStock = 120,
    },
    Maintenance = {
        District = 'prison',          -- pf-government Config.Infrastructure.Districts key for Bolingbroke
        OpenOrders = 2,               -- open prison work orders kept available
        Units = 4,
        Field = 'maintenance_backlog', Delta = -400, -- the whole order's effect on the district
        LifetimeHours = 24,
        EnsureSeconds = 300,
        Sites = {
            { label = 'Bolingbroke yard', kind = 'litter', x = 1765.7, y = 2565.9, z = 45.56, r = 25.0 },
            { label = 'Bolingbroke cell block', kind = 'public_building', x = 1700.2, y = 2525.6, z = 45.56, r = 25.0 },
            { label = 'Bolingbroke grounds', kind = 'landscaping', x = 1640.0, y = 2540.0, z = 45.56, r = 30.0 },
        },
    },
}

Config.Economy = {
    TrustAccount = 'system:pfm-prison-trust', -- the ledger account every inmate trust lives in
    WageAccount = 'society:corrections',      -- wages come from the corrections budget
    CommissaryAccount = 'society:corrections',-- commissary sales go back to it
    Kiosk = vector3(1783.9, 2549.6, 45.67),   -- trust desk and commissary window
    KioskReach = 3.0,
    MaxDeposit = 2000,                        -- one deposit from the inmate's own bank
    MaxDepositPerDay = 5000,
    MaxSpendPerDay = 400,                     -- commissary per inmate and day
    RestitutionShare = 0.25,                  -- of each wage, while a restitution order is open
    SettleAfterSeconds = 60,                  -- an unclear ledger move is looked up after this
    NotWrittenGraceSeconds = 300,             -- a pending row whose key never reached the ledger fails after this
    EarningRetrySeconds = 300,                -- a wage the corrections budget clearly refused is tried again
    MaxEarningAttempts = 10,                  -- numbered keys; then the row is left for an admin
    PayoutRetrySeconds = 120,
    TickSeconds = 60,
    -- what the commissary sells (price from here, never from the client). maxPerDay per item.
    Commissary = {
        { item = 'commissary_noodles', label = 'Instant noodles', price = 12, maxPerDay = 4 },
        { item = 'commissary_soda', label = 'Soda', price = 6, maxPerDay = 6 },
        { item = 'coffee', label = 'Coffee', price = 5, maxPerDay = 4 },
        { item = 'snikkel_candy', label = 'Candy bar', price = 4, maxPerDay = 6 },
        { item = 'commissary_hygiene', label = 'Hygiene kit', price = 15, maxPerDay = 1 },
    },
}
