Config = Config or {}

-- Server-authoritative food freshness. Shelf life is always taken from this file;
-- freshness values stored in item metadata are re-validated against it on every insert,
-- so nothing a client or another resource writes can extend an item's life.
Config.Freshness = {
    Enabled = true,

    -- Perishables only stack when they share a batch and their freshness differs by at most this many percent.
    StackTolerancePct = 1.0,

    -- Shelf life in seconds when kept in 'normal' storage (rate 1.0).
    Categories = {
        prepared = { shelfLife = 12 * 3600 },  -- cooked meals, sandwiches, hot drinks
        meat     = { shelfLife = 1 * 86400 },
        seafood  = { shelfLife = 18 * 3600 },
        dairy    = { shelfLife = 3 * 86400 },
        produce  = { shelfLife = 4 * 86400 },
        bakery   = { shelfLife = 3 * 86400 },
        packaged = { shelfLife = 30 * 86400 },  -- snacks, candy
        beverage = { shelfLife = 20 * 86400 },  -- sealed drinks
    },

    -- item name -> category. Items not listed are non-perishable and behave exactly as before.
    Items = {
        sandwich = 'prepared',
        tosti = 'prepared',
        coffee = 'prepared',
        twerks_candy = 'packaged',
        snikkel_candy = 'packaged',
        water_bottle = 'beverage',
        kurkakola = 'beverage',
    },

    -- How fast shelf life is used up relative to normal storage.
    Storage = {
        normal = 1.0,
        person = 1.0,         -- player pockets / backpack
        stash = 1.0,          -- houses, lockers, generic stashes
        fridge = 0.25,
        freezer = 0.04,       -- 25x longer than normal storage
        open_fridge = 0.6,    -- fridge door left open
        broken_fridge = 1.0,  -- failed equipment: no better than the counter
        trunk = 1.25,
        glovebox = 1.5,
        outdoor = 1.75,       -- ground drops
        sunlight = 2.0,
        hot = 2.5,
    },

    -- Inventory identifier -> storage type. Lua patterns, first match wins.
    -- Player inventories are always 'person'. Business equipment can override any
    -- identifier at runtime with exports['pfm-inventory']:SetStorageCondition(id, type).
    StorageRules = {
        { '^backpack%-', 'person' },
        { '^trunk%-', 'trunk' },
        { '^glovebox%-', 'glovebox' },
        { '^drop%-', 'outdoor' },
        { '^freezer', 'freezer' },
        { '^fridge', 'fridge' },
    },
    DefaultStashStorage = 'stash',
    -- Deliveries: goods left packed age normally for this long after delivery, then at the
    -- DeliveryStorage rate until someone unpacks them
    DeliveryGraceSeconds = 1800,
    DeliveryGraceStorage = 'normal',
    DeliveryStorage = 'outdoor',
    -- Ground drops use the 'sunlight' rate in these weathers between these game hours
    Sunlight = { Weathers = { EXTRASUNNY = true, CLEAR = true }, FromHour = 11, ToHour = 16 },

    -- Freshness bands, highest first. Spoiled food is never deleted; it stays usable with penalties.
    States = {
        { min = 70, state = 'fresh', label = 'Fresh' },
        { min = 40, state = 'good', label = 'Good' },
        { min = 0.5, state = 'stale', label = 'Stale' },
        { min = 0, state = 'spoiled', label = 'Spoiled' },
    },

    -- Consumption effects per band: benefit multiplies hunger/thirst gained, illness is a % chance.
    Effects = {
        fresh = { benefit = 1.0, illness = 0 },
        good = { benefit = 0.9, illness = 0 },
        stale = { benefit = 0.6, illness = 10 },
        spoiled = { benefit = 0.25, illness = 45 },
    },
}
