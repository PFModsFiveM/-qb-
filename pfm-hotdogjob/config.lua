Config = Config or {}
Config.UseTarget = GetConvar('UseTarget', 'false') == 'true'
-- Config --

Config.StandDeposit = 250

-- Server-side sale limits
Config.MaxSalePerCustomer = 3 -- most hotdogs a single customer sale can contain
Config.SaleCooldown = 5       -- minimum seconds between sales
Config.RepCooldown = 3        -- minimum seconds between reputation gains

-- Consecutive sales in one stand session add a small payout multiplier (reset when the stand is returned)
Config.StreakBonus = { enabled = false, perDelivery = 0.02, cap = 0.25 }

Config.MyLevel = 1
Config.MaxReputation = 200

Config.Locations = {
    ['take'] = {
        coords = vector4(39.31, -1005.54, 29.48, 240.57),
    },
    ['spawn'] = {
        coords = vector4(38.15, -1001.65, 29.44, 342.5),
    },
}

Config.Stock = {
    ['exotic'] = {
        Current = 0,
        Max = {
            [1] = 15,
            [2] = 30,
            [3] = 45,
            [4] = 60,
        },
        Label = Lang:t('info.label_a'),
        Price = {
            [1] = {
                min = 8,
                max = 12,
            },
            [2] = {
                min = 9,
                max = 13,
            },
            [3] = {
                min = 10,
                max = 14,
            },
            [4] = {
                min = 11,
                max = 15,
            },
        }
    },
    ['rare'] = {
        Current = 0,
        Max = {
            [1] = 15,
            [2] = 30,
            [3] = 45,
            [4] = 60,
        },
        Label = Lang:t('info.label_b'),
        Price = {
            [1] = {
                min = 6,
                max = 9,
            },
            [2] = {
                min = 7,
                max = 10,
            },
            [3] = {
                min = 8,
                max = 11,
            },
            [4] = {
                min = 9,
                max = 12,
            },
        }
    },
    ['common'] = {
        Current = 0,
        Max = {
            [1] = 15,
            [2] = 30,
            [3] = 45,
            [4] = 60,
        },
        Label = Lang:t('info.label_c'),
        Price = {
            [1] = {
                min = 4,
                max = 6,
            },
            [2] = {
                min = 5,
                max = 7,
            },
            [3] = {
                min = 6,
                max = 9,
            },
            [4] = {
                min = 7,
                max = 9,
            },
        }
    },
}
