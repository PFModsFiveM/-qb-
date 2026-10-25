Config = Config or {}

Config.WorldObjects = {
    -- models objects may use (the server refuses anything else)
    Models = {
        'prop_boxpile_06b', 'prop_boxpile_07d', 'prop_boxpile_02b', 'prop_pallet_02a', 'prop_cs_cardbox_01',
    },
    -- models business fixtures may use (equipment installed through pf-government premises)
    FixtureModels = {
        'prop_bar_fridge_01', 'prop_ice_box_01', 'prop_ff_shelves_01', 'prop_till_01', 'prop_cooker_03',
        'prop_bbq_5', 'prop_office_desk_01', 'p_cs_locker_01', 'prop_pallet_02a',
    },
    InteractDistance = 3.0,     -- how close a player must be to open, unpack or move an object
    MoveMaxDistance = 30.0,     -- how far an object may be moved from where it was delivered
    StashSlots = 30,
    StashWeight = 2000000,
    AdminAce = 'pfm-worldobjects.admin',
}
