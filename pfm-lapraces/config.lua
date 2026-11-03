Config = Config or {}

Config.WhitelistedCreators = {
    "PUTCID",
}

Config.RaceSetupAllowed = true

-- Race timing is the server's: a checkpoint counts when the racer is within this many metres of it
-- (server position, which lags the client's a little at speed; the client counts a pass within 7.5/12.5 m,
-- and a smaller radius keeps the per-segment minimum below from shrinking to nothing), and no sooner than its distance from
-- the previous one at this top speed (m/s; ~324 km/h, above any car in the city).
Config.CheckpointRadius = 25.0
Config.MaxSpeed = 90.0
