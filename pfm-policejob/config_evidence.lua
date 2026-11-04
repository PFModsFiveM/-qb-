-- Evidence and chain of custody (server/evidence/*). Loaded after config.lua.
-- Every value here is read on the server; the client only gets what it needs to draw drops.
Config = Config or {}

Config.Evidence = {
    -- Items. The bag is unique and carries info.evidenceId; the custody recorder watches every item
    -- listed in BagItems. When BagItem is not in the shared items yet, new bags use LegacyBagItem.
    BagItem = 'evidence_bag',
    LegacyBagItem = 'filled_evidence_bag',
    EmptyBagItem = 'empty_evidence_bag',
    GloveItem = 'nitrile_gloves',
    BagItems = { evidence_bag = true, filled_evidence_bag = true },

    TagPrefix = 'EV',
    -- Labs and courts: evidence is handed in, and opened without integrity cost, only by someone
    -- standing there (server position). A lab tech (pf-government qualification LabRole) may open lab
    -- evidence from anywhere. Ids are what TransferEvidence { kind = 'lab', labId } names.
    Labs = {
        main = { label = 'Mission Row forensics', coords = vector3(442.17, -996.07, 30.69), radius = 15.0 },
    },
    Courts = {
        { label = 'Courthouse', coords = vector3(-544.85, -204.40, 38.22), radius = 40.0 },
    },
    LabRole = 'lab_tech',
    -- extra stash-id patterns for evidence drawers (two captures: station index, drawer number); the
    -- locale's 'info.current_evidence' phrase is recognised without this
    DrawerPatterns = {},
    SupervisorGrade = 3,          -- leo grade that may move, release or destroy evidence someone else holds
    HandoverReach = 2.5,          -- officer to officer handover (touch rule, architecture 6.4)
    LockerReach = 3.0,            -- the officer must stand at the evidence locker
    ListLimit = 100,              -- ListEvidence page size cap
    CustodyListLimit = 100,       -- custody events GetEvidence returns (newest last)
    MaxCaseLinks = 20,
    CaseRefTypes = { incident = true, report = true, case = true, warrant = true, custody = true, booking = true, court_case = true, order = true },
    Methods = { scene = true, search = true, seizure = true, booking = true, surgery = true, prison_search = true, swab = true, manual = true, registered = true },
    -- custody gap: the bag is outside police custody longer than this: holder unknown (removed,
    -- missing), on the ground, or with someone who is not on-duty police (a civilian)
    GapMinutes = 30,
    -- a bag removed from an inventory that turns up nowhere within this many seconds is flagged missing
    MissingAfterSeconds = 10,

    -- Integrity score (shown to courts, architecture 4.9): starts at 100.
    Integrity = {
        Start = 100,
        SealBroken = 12,          -- each seal break outside a lab or court
        Gap = 20,                 -- each custody gap
        NoGloves = 10,            -- prints/DNA collected without gloves
    },

    -- Kinds and their attrs (type per field: str<N>, int, bool, url, plate). physical = carried in a bag;
    -- contact = prints/DNA (glove rule); biological = quality falls with age at collection.
    Kinds = {
        casing      = { label = 'Bullet casing', physical = true, attrs = { caliber = 'str32', weaponHash = 'int', weapon = 'str50', serial = 'str32' } },
        projectile  = { label = 'Projectile', physical = true, attrs = { caliber = 'str32', weaponHash = 'int', serial = 'str32', fromInjuryId = 'str64' } },
        blood       = { label = 'Blood sample', physical = true, contact = true, biological = true, attrs = { sampleId = 'str32', bloodtype = 'str8' } },
        fingerprint = { label = 'Fingerprint lift', physical = true, contact = true, biological = true, attrs = { printId = 'str32', quality = 'int' } },
        dna_swab    = { label = 'DNA swab', physical = true, contact = true, biological = true, attrs = { sampleId = 'str32', quality = 'int' } },
        gsr_kit     = { label = 'GSR kit', physical = true, attrs = { result = 'str16' } },
        drug        = { label = 'Narcotics', physical = true, attrs = { item = 'str50', amount = 'int' } },
        weapon      = { label = 'Weapon', physical = true, attrs = { item = 'str50', serial = 'str32' } },
        item        = { label = 'Item', physical = true, attrs = { item = 'str50', amount = 'int' } },
        document    = { label = 'Document', physical = true, attrs = { title = 'str64', body = 'str2000' } },
        photo       = { label = 'Photo', physical = false, attrs = { url = 'url', clientSupplied = 'bool' } },
        vehicle     = { label = 'Vehicle', physical = false, attrs = { plate = 'plate' } },
        digital     = { label = 'Digital record', physical = false, attrs = { kind = 'str16', ref = 'str64' } },
    },
    PhotoHosts = { 'cdn.discordapp.com', 'media.discordapp.net', 'i.imgur.com', 'imgur.com', 'r2.fivemanage.com', 'fivemanage.com' },

    -- Scene drops (blood, casings, prints) reported by clients and persisted by the server.
    Scene = {
        SyncRadius = 150.0,       -- drops are sent only to on-duty LEO this close (server positions)
        CellSize = 100,           -- metres per grid cell
        MaxPerCell = 200,         -- live drops per cell; more are refused
        MaxLive = 6000,           -- live drops kept in memory on the whole server
        MaxPerPlayer = 50,        -- live drops of one kind one player left; the next replaces their oldest
                                  -- (3 kinds x 50 < MaxPerCell, so one player cannot fill a cell or the server)
        RatePerSecond = 5,        -- per player and per drop type (architecture 6.3)
        RateBurst = 5,
        HintRadius = 10.0,        -- a client position further than this from the server position is refused
        ExactRadius = 3.0,        -- within this the client position is used as is (cosmetic scatter)
        CollectReach = 2.5,       -- bagging is a touch action
        ClearRadius = 12.0,       -- clean-up reaches this far from the officer
        ClearMaxIds = 200,
        -- age (minutes) after which a biological drop yields a partial sample, and after which a
        -- drop cannot be recovered at all (the row is kept as 'unrecoverable')
        DegradeMinutes = { blood = 60, fingerprint = 120, casing = 0 },
        LifetimeMinutes = { blood = 240, fingerprint = 480, casing = 1440 },
        PartialQuality = 50,
        FlushMs = 2000,           -- new drops are written in one multi-row insert at this interval
        SyncTickMs = 5000,        -- officers moving into a new cell get a snapshot of drops around them
        DecayTickMs = 60000,
        RetentionDays = 30,       -- unrecoverable/cleared rows are deleted after this (false keeps them; collected rows are always kept)
    },

    -- Rate limits of the legacy net events (per source).
    Rates = {
        collect = { perSecond = 2, burst = 4 },
        clear = { perSecond = 0.5, burst = 1 },
    },

    -- Exports that write or read private data check GetInvokingResource() against these lists
    -- (architecture 3.4). This resource itself always passes.
    Callers = {
        CreateEvidence   = { ['pfm-prison'] = true, ['pf-justice'] = true, ['pf-ambulancejob'] = true },
        GetEvidence      = { ['pf-policemdt-DEV'] = true, ['pf-justice'] = true },
        ListEvidence     = { ['pf-policemdt-DEV'] = true, ['pf-justice'] = true },
        TransferEvidence = { ['pf-policemdt-DEV'] = true, ['pf-justice'] = true },
        SealEvidence     = {},
        BreakSeal        = {},
        LinkEvidence     = { ['pf-policemdt-DEV'] = true },
        UnlinkEvidence   = { ['pf-policemdt-DEV'] = true },
        DisposeEvidence  = { ['pf-justice'] = true },
    },

    -- custody rows of released/destroyed evidence older than this are swept (nil keeps them forever)
    CustodyRetentionDays = nil,
}
