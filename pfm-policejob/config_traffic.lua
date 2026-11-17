-- Traffic enforcement (server/traffic.lua, server/vehicle.lua, client/traffic.lua). Loaded after
-- config.lua. Every reading (speed, plate, position) is taken by the server from its own natives;
-- the client only says which vehicle it points at or which person it means.
Config = Config or {}

Config.Traffic = {
    LeoJobTypes = { leo = true },     -- job types that count as police for every traffic action

    -- Models that carry the radar and the ALPR unit. The police garage models (Config.AuthorizedVehicles)
    -- are always included; add other police models here.
    PoliceModels = {},

    -- Radar: the server reads the target's speed (GetEntitySpeed). From a police car the cone points
    -- along the car's heading (and behind it with RearAntenna); on foot the radar gun item is needed
    -- and the cone follows the officer's heading.
    Radar = {
        Range = 150.0,
        ConeDegrees = 12.0,           -- full cone width
        RearAntenna = true,
        Item = 'radar_gun',
        MinIntervalMs = 500,          -- 2 measurements per second
    },

    -- Speed limits: the first zone that contains the position wins, else DefaultKmh.
    SpeedLimits = {
        DefaultKmh = 80,
        Zones = {
            { label = 'Downtown', coords = vector3(215.0, -810.0, 30.0), radius = 900.0, kmh = 60 },
            { label = 'Vespucci', coords = vector3(-1150.0, -1300.0, 5.0), radius = 600.0, kmh = 60 },
            { label = 'Sandy Shores', coords = vector3(1850.0, 3700.0, 33.0), radius = 400.0, kmh = 50 },
            { label = 'Paleto Bay', coords = vector3(-300.0, 6200.0, 31.0), radius = 450.0, kmh = 50 },
        },
    },

    -- ALPR: units in police cars (toggled by the officer) and fixed readers. Reads are taken on the
    -- server every IntervalMs from vehicles within Range of a reader (vehicles are sorted into
    -- CellSize buckets first, so a reader only looks at its own and the neighbouring cells).
    Alpr = {
        Enabled = true,
        IntervalMs = 2000,
        Range = 60.0,
        CellSize = 60.0,              -- keep >= Range and >= every fixed reader / camera radius
        DedupeSeconds = 60,           -- one logged read per reader and plate in this window
        FixedRange = 40.0,
        -- fixed readers; nil = the legacy Config.Radars points
        FixedReaders = nil,
        MaxLookupsPerTick = 25,       -- plate-flag lookups through pf-policemdt-DEV per tick (the rest wait a tick)
        FlagCacheSeconds = 300,       -- refreshed at once by pf_mdt:server:plateFlagsChanged
        RetentionDays = 14,
        MaxQueuedReads = 2000,        -- reads waiting for the batched insert (oldest dropped beyond this)
        FieldFlagHours = 12,          -- /flagplate flags (memory only) expire after this
    },

    -- Speed cameras: the server checks vehicles inside each camera's radius every IntervalMs. A
    -- vehicle over limit + ToleranceKmh is a speed event; with AutoCite the driver (a player) gets a
    -- citation through pf-justice.
    SpeedCameras = {
        Enabled = true,
        IntervalMs = 1000,
        Max = 24,
        ToleranceKmh = 10,
        DedupeSeconds = 120,
        AutoCite = true,
        ExemptJobTypes = { leo = true, ems = true },  -- on-duty drivers of these job types are not cited
        List = {
            { id = 'cam_greatocean', label = 'Great Ocean Hwy', coords = vector3(-2612.10, 2940.81, 16.67), radius = 30.0, kmh = 100 },
            { id = 'cam_senora', label = 'Senora Fwy', coords = vector3(2792.73, 4407.68, 48.44), radius = 30.0, kmh = 110 },
            { id = 'cam_vinewood', label = 'Vinewood Blvd', coords = vector3(287.94, -517.44, 42.89), radius = 25.0, kmh = 80 },
        },
    },

    -- Breathalyzer: BAC comes from pf-ambulancejob (GetBreathAlcohol, the engine's ethanol level).
    Breath = {
        Item = 'breathalyzer',
        Distance = 2.5,
        LegalLimit = 0.08,
        MinIntervalMs = 5000,
    },

    -- Citations go through pf-justice IssueCitation; the amount comes from here, never the client.
    Citations = {
        Distance = 5.0,
        SpeedEventMaxAgeSeconds = 900,  -- a radar reading can be cited for this long
        Speeding = { Base = 150, PerKmh = 10, Max = 2500 },  -- base + per km/h over the limit
        Violations = {
            speeding = { label = 'Speeding', speed = true },
            reckless = { label = 'Reckless driving', amount = 1500 },
            red_light = { label = 'Running a red light', amount = 400 },
            no_licence = { label = 'Driving without a licence', amount = 1000 },
            illegal_parking = { label = 'Illegal parking', amount = 200 },
            dui = { label = 'Driving under the influence', amount = 2500 },
            no_helmet = { label = 'No helmet', amount = 250 },
            unroadworthy = { label = 'Unroadworthy vehicle', amount = 500 },
        },
        RetrySeconds = 60,            -- a citation pf-justice could not take yet is retried with the same key
        MaxAttempts = 30,
        Document = true,              -- a copy goes to the citizen's documents (pf-citizen)
        MinIntervalMs = 1000,
    },

    Impound = {
        DefaultReason = 'Impounded by police',
        MaxHoldHours = 168,           -- a seizure can be held up to a week
        OverrideGrade = 3,            -- leo grade that may release a seizure before its hold ends
    },

    Incidents = {
        Kinds = { collision = true, stop = true, pursuit_end = true, hazard = true },
        Radius = 30.0,                -- plates and people must be this close to the officer
        MaxPlates = 6,
        MaxPeople = 8,
        MinIntervalMs = 5000,
    },

    RunPlate = {
        GovDriverLicense = 'drivers_license',  -- pf-government licence type checked for the owner
    },

    -- Resources allowed to call the read exports (architecture 3.4). The resource itself always passes.
    Callers = {
        RunPlate = { ['pf-policemdt-DEV'] = true, ['pf-jobs'] = true },
        GetImpound = { ['pf-policemdt-DEV'] = true, ['pf-jobs'] = true, ['pfm-garages'] = true },
        ListTrafficIncidents = { ['pf-policemdt-DEV'] = true },
    },
}
