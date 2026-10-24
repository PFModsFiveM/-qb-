Config = Config or {}

Config.WorldObjects = {
    -- models objects may use (the server refuses anything else)
    Models = {
        'prop_boxpile_06b', 'prop_boxpile_07d', 'prop_boxpile_02b', 'prop_pallet_02a', 'prop_cs_cardbox_01',
    },
    InteractDistance = 3.0,     -- how close a player must be to open, unpack or move an object
    MoveMaxDistance = 30.0,     -- how far an object may be moved from where it was delivered
    StashSlots = 30,
    StashWeight = 2000000,
    AdminAce = 'pfm-worldobjects.admin',
}
