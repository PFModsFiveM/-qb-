Config                  = {}
Config.DynamicWeather   = true -- Set this to false if you don't want the weather to change automatically every 10 minutes.

-- On server start
Config.StartWeather     = 'EXTRASUNNY' -- Default weather                       default: 'EXTRASUNNY'
Config.BaseTime         = 8 -- Time                                             default: 8
Config.TimeOffset       = 0 -- Time offset                                      default: 0
Config.FreezeTime       = false -- freeze time                                  default: false
Config.Blackout         = false -- Set blackout                                 default: false
Config.BlackoutVehicle  = false -- Set blackout affects vehicles                default: false
Config.NewWeatherTimer  = 10 -- Time (in minutes) between each weather change   default: 10
Config.Disabled         = false -- Set weather disabled                         default: false
Config.RealTimeSync     = false -- Activate realtime synchronization            default: false

-- Weighted weather transitions. When false (default) the original uniform-random stage
-- logic is used. When true, each weather type picks its successor from a weighted table,
-- so weather flows naturally (clear -> clouds -> rain) and storms stay rare.
Config.DynamicWeatherPatterns = false
Config.WeatherPatterns = {
    -- [current] = { { weather = 'NEXT', weight = n }, ... } - higher weight = more likely
    EXTRASUNNY = { { weather = 'EXTRASUNNY', weight = 4 }, { weather = 'CLEAR', weight = 4 }, { weather = 'CLOUDS', weight = 2 } },
    CLEAR      = { { weather = 'CLEAR', weight = 4 }, { weather = 'EXTRASUNNY', weight = 3 }, { weather = 'CLOUDS', weight = 3 }, { weather = 'SMOG', weight = 1 } },
    NEUTRAL    = { { weather = 'CLEAR', weight = 5 }, { weather = 'CLOUDS', weight = 3 } },
    SMOG       = { { weather = 'CLEAR', weight = 4 }, { weather = 'FOGGY', weight = 2 }, { weather = 'CLOUDS', weight = 2 } },
    FOGGY      = { { weather = 'CLEARING', weight = 3 }, { weather = 'CLEAR', weight = 3 }, { weather = 'OVERCAST', weight = 2 } },
    OVERCAST   = { { weather = 'CLOUDS', weight = 3 }, { weather = 'RAIN', weight = 2 }, { weather = 'CLEARING', weight = 2 }, { weather = 'FOGGY', weight = 1 } },
    CLOUDS     = { { weather = 'CLEAR', weight = 3 }, { weather = 'OVERCAST', weight = 3 }, { weather = 'RAIN', weight = 1 }, { weather = 'CLOUDS', weight = 2 } },
    CLEARING   = { { weather = 'CLEAR', weight = 4 }, { weather = 'CLOUDS', weight = 3 }, { weather = 'EXTRASUNNY', weight = 2 } },
    RAIN       = { { weather = 'CLEARING', weight = 4 }, { weather = 'OVERCAST', weight = 2 }, { weather = 'THUNDER', weight = 1 } },
    THUNDER    = { { weather = 'RAIN', weight = 3 }, { weather = 'CLEARING', weight = 3 } },
    SNOW       = { { weather = 'SNOWLIGHT', weight = 3 }, { weather = 'BLIZZARD', weight = 1 }, { weather = 'CLEARING', weight = 2 } },
    BLIZZARD   = { { weather = 'SNOW', weight = 3 }, { weather = 'SNOWLIGHT', weight = 2 } },
    SNOWLIGHT  = { { weather = 'SNOW', weight = 2 }, { weather = 'CLEARING', weight = 2 }, { weather = 'CLOUDS', weight = 2 } },
    XMAS       = { { weather = 'XMAS', weight = 1 } },
    HALLOWEEN  = { { weather = 'HALLOWEEN', weight = 1 } },
}

Config.AvailableWeatherTypes = { -- DON'T TOUCH EXCEPT IF YOU KNOW WHAT YOU ARE DOING
    'EXTRASUNNY',
    'CLEAR',
    'NEUTRAL',
    'SMOG',
    'FOGGY',
    'OVERCAST',
    'CLOUDS',
    'CLEARING',
    'RAIN',
    'THUNDER',
    'SNOW',
    'BLIZZARD',
    'SNOWLIGHT',
    'XMAS',
    'HALLOWEEN',
}
