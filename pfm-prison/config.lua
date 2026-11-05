Config = {}
Config.UseTarget = GetConvar('UseTarget', 'false') == 'true' -- Use qb-target interactions (don't change this, go to your server.cfg and add `setr UseTarget true` to use this and just that from true to false or the other way around)
Config.MaxJailTime = 1440 -- Hard server-side cap (months/minutes) any jail sentence is clamped to
Config.JailResourceAllowlist = { -- Server resources allowed to jail and release players (exports JailPlayer / ReleasePlayer)
    ['pfm-policejob'] = true,
    ['pfm-adminmenu'] = true,
    ['pf-policemdt-DEV'] = true,
    ['pf-justice'] = true,
}

-- The sentence, the release, escapes and the gates are decided on the server.
Config.Prison = {
    InsideRadius = 200.0,     -- metres from Locations.middle that count as inside the prison
    SampleSeconds = 2,        -- how often the server looks at where each inmate is
    GraceSeconds = 20,        -- after being taken to a cell (or loading in) outside samples are ignored this long
    MaxSpeed = 30.0,          -- m/s an inmate can plausibly move between two looks; more is a teleport
    BreachWindow = 600,       -- seconds a breached (hacked) gate lets inmates out
    GateReach = 12.0,         -- metres from a breached gate that count as going through it
    ExitWindow = 8,           -- the last look inside the walls must be this recent when an inmate is seen outside
    SendBackSeconds = 10,     -- an inmate outside without a breach is taken back at most this often
    JobMinSeconds = 8,        -- a prison job cannot be finished sooner than this after it was given
    JobReach = 3.5,           -- metres from the job spot the inmate must stand when finishing it
    PhoneChance = 1,          -- % chance per finished job of finding a phone (once per sentence)
    JobTravelSpeed = 8.0,     -- m/s: a job spot reached faster than this from where the job was given is a teleport
    JobDwellSeconds = 3,      -- the server must have seen the inmate at the job spot this long before the job counts
    KeepJob = true,           -- owner decision D1: an inmate keeps the job and is put off duty (false: unemployed, the old way)
    JailMoney = 80,           -- cash paid once per sentence on intake (bank ledger, keyed per sentence); 0 = none
}

-- pf-justice (batch 16). pf-justice owns every sentence and its one clock; pfm-prison answers
-- "inside the walls" (export IsInside), takes inmates in when an order starts and lets them out when
-- pf-justice orders the release. The old metadata runtime (injail counted down here) stays for as
-- long as pf-justice says so: Config.Compat.LegacyRuntimes.prison in pf-justice/config.lua.
Config.Justice = {
    -- 'auto' = follow pf-justice's Config.Compat.LegacyRuntimes (read from its config file at start;
    -- prison for this prison's sentences, mdt for imported MDT jails); 'legacy' / 'justice' force the
    -- old runtime on / off (keep it the same as pf-justice's flag; the console says which one runs)
    Runtime = 'auto',
    Facility = 'bolingbroke',     -- the pf-justice facility this prison is
    -- transport intake (pf-justice Config.Prison.Intake = 'transport'): a pending order starts when
    -- the prisoner is brought here (server position); placeholder at the front gate, check in game
    Intake = { coords = vector3(1845.0, 2585.0, 45.67), radius = 15.0 },
    RecaptureInside = true,       -- an escapee seen back inside the walls serves on (the order resumes)
    LoadDelaySeconds = 3,         -- after a login, wait for pf-justice's own load (legacy import, clock)
    PumpSeconds = 2,              -- queued intakes, releases and order changes are handled this often
    MaxActionAttempts = 10,       -- a refused suspend / resume / credit is retried at most this often
    EventRetentionDays = 180,     -- pf_prison_events rows older than this are swept (daily, 500 at a time)
}

-- Prison break gates: hacked at `coords` with an electronickit (needs a gatecrack, used up);
-- `gatekey` is the pfm-doorlock door the server opens.
-- `door` is the pfm-doorlock alias the server sets through SetDoorState (no player needed); the old
-- updateState path with `gatekey` is used only when that export is not there.
Config.Gates = {
    { gatekey = 13, door = 'bolingbroke_gate_1', coords = vector3(1845.99, 2604.7, 45.58) },
    { gatekey = 14, door = 'bolingbroke_gate_2', coords = vector3(1819.47, 2604.67, 45.56) },
    { gatekey = 15, door = 'bolingbroke_gate_3', coords = vector3(1804.74, 2616.311, 45.61) },
}
Config.GateHack = {
    Reach = 2.5,              -- metres from the gate's hack point (server position)
    MinSeconds = 5,           -- a hack cannot finish sooner (the connect bar alone takes 5 s)
    MaxSeconds = 60,          -- an unfinished hack is void after this
    StartCooldown = 30,       -- seconds between two hack starts of one inmate
    LockdownSeconds = 600,    -- a failed hack locks every gate down this long (one lockdown and alert at a time)
    AlarmSeconds = 300,       -- the alarm rings this long; the gates lock again when it stops
    OpenSeconds = 300,        -- a hacked gate locks again after this long in any case
    AlertChance = 50,         -- % chance an opened gate alerts the police at once
    Size = 5, Seconds = 30,   -- the hacking puzzle (pfm-minigames)
}

Config.Jobs = {
    ['electrician'] = 'Electrician'
}

Config.Uniforms = {
    ['male'] = {
        outfitData = {
            ['t-shirt'] = { item = 15, texture = 0 },
            ['torso2'] = { item = 345, texture = 0 },
            ['arms'] = { item = 19, texture = 0 },
            ['pants'] = { item = 3, texture = 7 },
            ['shoes'] = { item = 1, texture = 0 },
        }
    },
    ['female'] = {
        outfitData = {
            ['t-shirt'] = { item = 14, texture = 0 },
            ['torso2'] = { item = 370, texture = 0 },
            ['arms'] = { item = 0, texture = 0 },
            ['pants'] = { item = 0, texture = 12 },
            ['shoes'] = { item = 1, texture = 0 },
        }
    },
}

Config.Locations = {
    freedom = vector4(1740.88, 2476.57, 44.85, 299.49),
    outside = vector4(1848.13, 2586.05, 44.67, 269.5),
    yard = vector4(1765.67, 2565.91, 44.56, 1.5),
    middle = vector4(1693.33, 2569.51, 44.55, 123.5),
    spawns = {
        { coords = vector4(1661.046, 2524.681, 45.564, 260.545) },
        { coords = vector4(1650.812, 2540.582, 45.564, 230.436) },
        { coords = vector4(1654.959, 2545.535, 45.564, 230.436) },
        { coords = vector4(1697.106, 2525.558, 45.564, 187.208) },
        { coords = vector4(1673.084, 2519.823, 45.564, 229.542) },
        { coords = vector4(1666.029, 2511.367, 45.564, 233.888) },
        { coords = vector4(1691.229, 2509.635, 45.564, 52.432) },
        { coords = vector4(1770.59, 2536.064, 45.564, 258.113) },
        { coords = vector4(1792.45, 2584.37, 45.56, 276.24) },
        { coords = vector4(1768.33, 2566.08, 45.56, 176.83) },
        { coords = vector4(1696.09, 2469.4, 45.56, 1.4) }
    },
    jobs = {
        electrician = {
            { coords = vector4(1761.46, 2540.41, 45.56, 272.249) },
            { coords = vector4(1718.54, 2527.802, 45.56, 272.249) },
            { coords = vector4(1700.199, 2474.811, 45.56, 272.249) },
            { coords = vector4(1664.827, 2501.58, 45.56, 272.249) },
            { coords = vector4(1621.622, 2509.302, 45.56, 272.249) },
            { coords = vector4(1627.936, 2538.393, 45.56, 272.249) },
            { coords = vector4(1625.1, 2575.988, 45.56, 272.249) }
        }
    }
}
