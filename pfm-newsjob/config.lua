Config = {}

Config.UseableItems = true -- Set to false if you want to use commands instead of usable items

Config.Job = 'reporter'
Config.GarageRange = 8.0     -- metres from a garage point to take a vehicle there
Config.SpawnCooldown = 10    -- seconds between two vehicle requests
Config.DutyRange = 2.5       -- metres from the duty point
Config.StoreRange = 10.0     -- metres from its garage point a news vehicle must be to be put away
Config.StorePlayerRange = 6.0 -- metres from the vehicle the reporter must be (when not sitting in it)
Config.WreckedEngineHealth = -3999.0 -- an issued vehicle at or below this engine health is a wreck (exploded = -4000)

Config.Locations = {
    ['main'] = {
        coords = vector4(-597.89, -929.95, 24.0, 271.5),
    },
    -- clock in / out (reporters must be on duty to claim newsroom leads and use the equipment)
    ['duty'] = {
        coords = vector4(-600.4, -929.9, 23.86, 90.0),
    },
    ['inside'] = {
        coords = vector4(-77.46, -833.77, 243.38, 67.5),
    },
    ['outside'] = {
        coords = vector4(-598.25, -929.86, 23.86, 86.5),
    },
    ['vehicle'] = {
        coords = vector4(-552.24, -925.61, 23.86, 242.5),
        vehicles = {
            [0] = {
                ['rumpo'] = { label = 'Rumpo', modLivery = 2 },
            },
            [1] = {
                ['rumpo'] = { label = 'Rumpo', modLivery = 2 },
            },
            [2] = {
                ['rumpo'] = { label = 'Rumpo', modLivery = 2 },
            },
            [3] = {
                ['rumpo'] = { label = 'Rumpo', modLivery = 2 },
            },
            [4] = {
                ['rumpo'] = { label = 'Rumpo', modLivery = 2 },
            },
        },
    },
    ['heli'] = {
        coords = vector4(-583.08, -930.55, 36.83, 89.26),
        vehicles = {
            [0] = {
                ['frogger'] = { label = 'Frogger' },
                ['conada'] = { label = 'Conada', modLivery = 5 },
            },
            [1] = {
                ['frogger'] = { label = 'Frogger' },
                ['conada'] = { label = 'Conada', modLivery = 5 },
            },
            [2] = {
                ['frogger'] = { label = 'Frogger' },
                ['conada'] = { label = 'Conada', modLivery = 5 },
            },
            [3] = {
                ['frogger'] = { label = 'Frogger' },
                ['conada'] = { label = 'Conada', modLivery = 5 },
            },
            [4] = {
                ['frogger'] = { label = 'Frogger' },
                ['conada'] = { label = 'Conada', modLivery = 5 },
            },
        },
    }
}

-- The van's trunk carries this gear, issued per reporter (player metadata 'newsgear'): a piece the
-- reporter has been issued, or carries, is not put in again. Storing the van, going off duty or
-- leaving the job hands it back. A piece not handed back can be issued again after this many hours.
Config.GearResetHours = 24

Config.VehicleItems = {
    [1] = {
        name = 'newscam',
        amount = 1,
        info = {},
    },
    [2] = {
        name = 'newsmic',
        amount = 1,
        info = {},
    },
    [3] = {
        name = 'newsbmic',
        amount = 1,
        info = {},
    },
}

-- A news vehicle the reporter is not in and that is farther than this from them when they ask the
-- garage for a new one (stolen, sunk, stuck) is deleted by the server and replaced.
Config.AbandonRange = 50.0
