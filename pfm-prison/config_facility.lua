-- Prison facility operations (batch 19D): cells, classification, the daily routine, headcounts,
-- meals, discipline (architecture 5.13) and visitation. Read by server/facility.lua, schedule.lua,
-- discipline.lua and visitation.lua. Coordinates marked "check in game" are first placements.

Config = Config or {}

Config.Facility = {
    Id = 'bolingbroke',           -- the pf-justice facility this prison is (Config.Justice.Facility)
    TickSeconds = 5,              -- routine, counts, meals and visits are looked at this often
    StaffJob = 'corrections',     -- job of the facility staff (pfm-core jobs: 0 Cadet .. 5 Warden)
    -- other resources that may call the write exports (the resource itself always may)
    Callers = {
        SetLockdown = { ['pfm-adminmenu'] = true },
        RecordInfraction = { ['pfm-adminmenu'] = true },
    },
    Grades = {
        Housing = 2,              -- reclassify an inmate, move a cell, take a cell out of service
        Lockdown = 3,             -- start or end a facility lockdown from duty
    },
    LockdownMaxMinutes = 240,     -- a staff lockdown ends by itself after this long at most
    IntakeSeconds = 60,           -- the inmate shows as 'intake' this long after being taken in
    UniformItem = 'prison_uniform', -- handed out at intake (only when the item exists), taken back at release
    Overflow = 'medium',          -- when no cell of the classification (or higher) is free: still housed, logged

    -- classification at intake: by the time to serve, raised by an escape record or a recent
    -- sanctioned serious infraction (never lowered automatically)
    Classification = {
        Order = { 'min', 'medium', 'max' },
        MinUpToMinutes = 60,      -- required time up to this -> min
        MediumUpToMinutes = 240,  -- up to this -> medium; longer -> max
        EscapeLookbackDays = 90,  -- an escape from here in this window -> max
        SeriousSeverity = 4,      -- a sanctioned infraction of at least this severity ...
        SeriousLookbackDays = 30, -- ... in this window raises the class by one
    },

    -- Cells are logical housing units (pfm-doorlock has no per-cell doors at Bolingbroke). coords are
    -- spots inside the walls used for the cell blip and solitary placement (check in game).
    Cells = {
        { id = 'A101', block = 'A', classification = 'min', capacity = 2, coords = vector4(1661.046, 2524.681, 45.564, 260.545) },
        { id = 'A102', block = 'A', classification = 'min', capacity = 2, coords = vector4(1650.812, 2540.582, 45.564, 230.436) },
        { id = 'A103', block = 'A', classification = 'min', capacity = 2, coords = vector4(1654.959, 2545.535, 45.564, 230.436) },
        { id = 'A104', block = 'A', classification = 'min', capacity = 2, coords = vector4(1673.084, 2519.823, 45.564, 229.542) },
        { id = 'B101', block = 'B', classification = 'medium', capacity = 2, coords = vector4(1697.106, 2525.558, 45.564, 187.208) },
        { id = 'B102', block = 'B', classification = 'medium', capacity = 2, coords = vector4(1666.029, 2511.367, 45.564, 233.888) },
        { id = 'B103', block = 'B', classification = 'medium', capacity = 2, coords = vector4(1691.229, 2509.635, 45.564, 52.432) },
        { id = 'B104', block = 'B', classification = 'medium', capacity = 2, coords = vector4(1770.59, 2536.064, 45.564, 258.113) },
        { id = 'C101', block = 'C', classification = 'max', capacity = 1, coords = vector4(1792.45, 2584.37, 45.56, 276.24) },
        { id = 'C102', block = 'C', classification = 'max', capacity = 1, coords = vector4(1768.33, 2566.08, 45.56, 176.83) },
        { id = 'C103', block = 'C', classification = 'max', capacity = 1, coords = vector4(1696.09, 2469.4, 45.56, 1.4) },
    },
    Solitary = { coords = vector4(1696.09, 2469.4, 45.56, 1.4) }, -- placement for a solitary term (check in game)
}

-- The daily routine: one cycle of phases repeated from Anchor (unix seconds), so every server and
-- every restart agrees on the phase. A count opens only when at least one inmate is online; meals
-- are timed events (each online inmate inside the walls is served once per meal).
Config.Facility.Routine = {
    Anchor = 0,
    Phases = {
        { name = 'count', minutes = 5, count = true },
        { name = 'meal', minutes = 15, meal = 'breakfast' },
        { name = 'work', minutes = 35 },
        { name = 'yard', minutes = 25 },
        { name = 'count', minutes = 5, count = true },
        { name = 'meal', minutes = 15, meal = 'dinner' },
        { name = 'lockin', minutes = 20 },
    },
    Labels = { count = 'Headcount', meal = 'Meal', work = 'Work period', yard = 'Yard time', lockin = 'Lock-in' },
    CountReach = 200.0,           -- a staff member conducting a count stands inside the walls (metres from the middle)
    -- what one meal is (the kitchen job of 19E may supply meals instead through Facility.SetMealProvider)
    Meal = { { name = 'sandwich', amount = 1 }, { name = 'water_bottle', amount = 1 } },
}

-- Discipline (architecture 5.13): reported -> hearing_scheduled -> heard -> sanctioned | dismissed.
Config.Facility.Discipline = {
    HearingGrade = 2,             -- a hearing is held by an on-duty corrections officer of at least this grade
    MinNoticeSeconds = 300,       -- the inmate has this long between the report and the hearing
    HearingReach = 10.0,          -- an online inmate attends: within this many metres of the officer
    AutoHearingAfter = 3600,      -- with no hearing officer on duty for this long an automatic hearing decides
    AutoHearing = true,           -- false: infractions wait for a person
    MaxSolitaryMinutes = 60,
    MaxPrivilegeHours = 168,
    MaxForfeitMinutes = 60,       -- per hearing (pf-justice also caps: only credits pfm-prison gave)
    ForfeitAttempts = 10,         -- a forfeit pf-justice could not take yet is retried this often
    Privileges = { commissary = true, yard = true, visits = true, phone = true, work = true },
    -- code -> label, default severity, and what an automatic hearing may impose (privileges only)
    Codes = {
        ['P-100'] = { label = 'Disobeying an order', severity = 1, auto = { { kind = 'yard', hours = 12 } } },
        ['P-110'] = { label = 'Out of place', severity = 2, auto = { { kind = 'yard', hours = 24 } } },
        ['P-120'] = { label = 'Missing a count', severity = 2, auto = { { kind = 'yard', hours = 24 } } },
        ['P-200'] = { label = 'Possession of contraband', severity = 3, auto = { { kind = 'commissary', hours = 48 } } },
        ['P-210'] = { label = 'Threatening staff', severity = 3, auto = { { kind = 'visits', hours = 48 } } },
        ['P-300'] = { label = 'Fighting', severity = 4, auto = { { kind = 'yard', hours = 48 }, { kind = 'commissary', hours = 48 } } },
        ['P-310'] = { label = 'Assault', severity = 5, auto = { { kind = 'visits', hours = 72 }, { kind = 'commissary', hours = 72 } } },
        ['P-400'] = { label = 'Escape attempt', severity = 5, auto = { { kind = 'visits', hours = 72 }, { kind = 'yard', hours = 72 } } },
    },
}

-- Visitation: citizens book a slot for an inmate, check in at the desk and meet in the visit room.
Config.Facility.Visitation = {
    SlotMinutes = 20,
    Hours = { from = 10, to = 22 },  -- server local time; a slot starts in [from, to)
    HorizonDays = 7,
    RoomCapacity = 4,                -- visits per slot
    MaxSocialPerDay = 2,             -- social visits per inmate per day
    MaxOpenPerVisitor = 3,
    CheckInEarlyMinutes = 10,
    NoShowMinutes = 10,              -- a booked visit not started this long after the slot is a no-show
    LeaveGraceSeconds = 30,          -- either side away from the room this long ends the visit
    RequireSearchWhenStaffed = true, -- with corrections on duty a visitor is searched before the visit starts
    AttorneyJobs = { lawyer = 0, doj = 1 }, -- job -> lowest grade that may book attorney visits
    Desk = { coords = vector3(1840.4, 2579.6, 46.0), radius = 4.0 },  -- visitor check-in (check in game)
    Room = { coords = vector3(1828.6, 2580.0, 46.0), radius = 8.0 },  -- the visit room (check in game)
}
