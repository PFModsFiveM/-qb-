-- Police equipment, telemetry and the hardening settings of batch 18 (unit 18C).
-- Read by server/telemetry.lua, server/objects.lua, server/gameplay.lua, server/main.lua and the
-- matching client files. Every value here is a server decision; clients only read labels and models.

Config = Config or {}

Config.Equipment = {
    -- Officer telemetry ("bodycam/dashcam"). This is a timeline of server-known metadata (positions,
    -- weapon in hand, vehicle entry, radio channel, server-seen actions). There is no video in FiveM.
    Telemetry = {
        Enabled = true,
        BodycamItem = 'bodycam',     -- using it toggles body recording (must stay in the inventory)
        SampleSeconds = 5,           -- position/weapon/vehicle/radio sample of recording officers
        FlushSeconds = 30,           -- batched insert into pf_police_telemetry
        MinMoveMeters = 2.0,         -- a position sample is written after this much movement...
        PosEverySeconds = 30,        -- ...or after this long standing still
        MaxBuffer = 5000,            -- rows waiting for the insert; the oldest position samples go first
        InsertBatch = 200,           -- rows per INSERT statement
        RetentionDays = 30,          -- rows older than this are deleted unless a hold covers them
        SweepBatch = 500,
        MaxWindowSeconds = 6 * 3600, -- longest window one GetTimeline call may read
        PageLimit = 100,             -- rows per page (cursor paging with opts.after)
        SupervisorGrade = 2,         -- on-duty LEO of this grade or higher may read other officers' timelines
        DataMaxChars = 500,          -- the data column
        MarkRate = { PerSecond = 5, Burst = 20 }, -- marks per officer
        -- Extra rig models (hashes or names) that record as a dashcam. Every model of
        -- Config.AuthorizedVehicles, Config.WhitelistedVehicles and Config.PoliceHelicopter is a rig already.
        DashcamModels = {},
        -- Other resources that may call the exports (the own resource always may). A missing list
        -- refuses every other resource.
        Callers = {
            MarkTimeline = { ['pf-justice'] = true, ['pf-policemdt-DEV'] = true },
            GetTimeline = { ['pf-justice'] = true, ['pf-policemdt-DEV'] = true },
            HoldTimeline = { ['pf-justice'] = true, ['pf-policemdt-DEV'] = true },
        },
    },

    -- Scene props. The server spawns every prop at the officer's own position and keeps the list.
    Props = {
        PerOfficer = 12,             -- props one officer may have out at a time
        Total = 150,                 -- props on the whole server
        LifetimeSeconds = 3600,      -- the server takes a prop up by itself after this
        RemoveRange = 3.0,           -- an on-duty officer takes up a prop within this distance
        PlaceDistance = 1.0,         -- metres in front of the officer
        RateMs = 750,                -- one placement per officer per this many ms
        Kinds = {
            cone = { label = 'Cone', model = `prop_roadcone02a`, freeze = false, max = 12 },
            barrier = { label = 'Barrier', model = `prop_barrier_work06a`, freeze = true, max = 8 },
            roadsign = { label = 'Road sign', model = `prop_snow_sign_road_06g`, freeze = true, max = 4 },
            tent = { label = 'Tent', model = `prop_gazebo_03`, freeze = true, max = 2 },
            light = { label = 'Work light', model = `prop_worklight_03b`, freeze = true, max = 4 },
            tape = { label = 'Police line', model = `prop_barrier_work05`, freeze = true, max = 8 },
        },
    },

    -- Riot shield: a usable item; the server spawns the shield and the owner's client holds it.
    RiotShield = {
        Item = 'riot_shield',
        Model = `prop_ballistic_shield`,
        Total = 40,                  -- shields out on the whole server
    },

    -- K9 sniff search: the dog alerts exactly when the server finds one of these items.
    K9 = {
        Qualification = 'k9',        -- pf-government qualification (granted by the police department)
        PlayerRange = 3.0,
        VehicleRange = 5.0,
        CooldownSeconds = 15,
        DrugItems = {
            joint = true, cokebaggy = true, crack_baggy = true, xtcbaggy = true, coke_brick = true,
            coke_small_brick = true, weed_brick = true, oxy = true, meth = true,
            weed_whitewidow = true, weed_skunk = true, weed_purplehaze = true, weed_ogkush = true,
            weed_amnesia = true, weed_ak47 = true,
        },
    },

    -- Drone: a camera the operator flies within Radius of their own (server) position.
    Drone = {
        Item = 'police_drone',
        Radius = 250.0,
        MaxSeconds = 600,
        CooldownSeconds = 30,
        HintSlackMeters = 15.0,      -- a position hint may be this far past the radius (lag)
        LogEverySeconds = 15,        -- drone positions in the operator's timeline
    },

    -- Gunshot residue comes from the server: weaponDamageEvent (the shooter hit something) and the
    -- shooter's casing reports. The shooter's own client no longer reports it.
    GSR = {
        Ammo = {
            AMMO_PISTOL = true, AMMO_SMG = true, AMMO_RIFLE = true, AMMO_MG = true, AMMO_SHOTGUN = true,
            AMMO_SNIPER = true, AMMO_MINIGUN = true,
        },
        MetaWriteSeconds = 30,       -- metadata.gsr (survives a relog) is written at most this often
    },

    -- Duty GPS: positions go only to on-duty leo/ems, never to every client.
    Blips = {
        Jobs = { leo = true, ems = true }, -- job types that send and receive
        RequestSeconds = 5,          -- police:server:UpdateBlips per player
    },

    -- Cop count broadcast (robbery scripts read it): one per GlobalSeconds at most.
    CopCount = { GlobalSeconds = 5, PerSourceSeconds = 10 },

    -- Information callbacks
    DeadCheckRange = 5.0,            -- police:server:isPlayerDead answers only about someone this close
    ForcePresentGrade = 2,           -- police:server:IsPoliceForcePresent counts on-duty LEO of this grade

    -- Structured police alerts. A client names what it saw; the text officers read is built here.
    -- Old callers still send free text: it is matched to a kind (Patterns, lower case, plain find)
    -- and replaced by that kind's text, so no client can put its own words on officers' screens.
    Alerts = {
        Kinds = {
            storerobbery = { title = 'Store robbery', text = 'Store robbery in progress' },
            bankrobbery = { title = 'Bank alarm', text = 'Bank robbery alarm triggered' },
            robbery = { title = 'Robbery', text = 'Robbery in progress' },
            vehicletheft = { title = 'Vehicle theft', text = 'Vehicle theft in progress' },
            drugsale = { title = 'Drug sale', text = 'Drug sale in progress' },
            suspicious = { title = 'Suspicious activity', text = 'Suspicious activity reported' },
            emergency = { title = 'Emergency', text = 'Emergency call' },
        },
        Patterns = {
            { 'store', 'storerobbery' }, { 'bank', 'bankrobbery' }, { 'fleeca', 'bankrobbery' },
            { 'savings', 'bankrobbery' }, { 'pacific', 'bankrobbery' }, { 'vehicle', 'vehicletheft' },
            { 'theft', 'vehicletheft' }, { 'carjack', 'vehicletheft' }, { 'drug', 'drugsale' },
            { 'robbery', 'robbery' }, { 'suspic', 'suspicious' },
        },
        Default = 'suspicious',
    },

    -- Fingerprint scanner (station): a session between the officer and the person scanned
    Fingerprint = { Range = 2.5, SessionSeconds = 120 },

    -- User-facing text (server notifications); English, edit freely
    Text = {
        on_duty_police_only = 'Only on-duty police can do this',
        bodycam_on = 'Bodycam recording',
        bodycam_off = 'Bodycam stopped',
        bodycam_lost = 'Bodycam stopped: the camera is no longer on you',
        dashcam_on = 'Dashcam recording',
        dashcam_off = 'Dashcam stopped',
        prop_limit = 'You have too many props out',
        prop_type_limit = 'You have too many of these out',
        prop_server_limit = 'Too many props are out on the server',
        prop_none = 'No police prop close enough',
        shield_limit = 'No shield available right now',
        k9_no_qual = 'You are not a certified K9 handler',
        k9_cooldown = 'The dog needs a moment',
        k9_too_far = 'Too far away for the dog',
        k9_alert = 'The K9 alerts: it smells narcotics',
        k9_clear = 'The K9 shows no interest',
        drone_busy = 'The drone needs a moment',
        drone_started = 'Drone up',
        drone_ended = 'Drone landed',
        drone_range = 'Drone out of range: landed',
        no_item = 'You need the equipment for this',
        cam_retired = 'Static cameras moved to the MDT CCTV page',
    },
}
