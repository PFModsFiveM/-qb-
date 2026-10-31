-- pfm-weathersync, pfm-streetraces, pfm-lapraces → pf-services: severe weather is one bulletin per
-- change; a race result the server judged (two or more racers, winner at the finish) is a news lead.
load_resource('tests/lua/fivem_mocks.lua')
Emits = {}
Mock.exportsByResource['pf-services'] = {
    Emit = function(_, kind, data, opts) Emits[#Emits + 1] = { kind = kind, data = data, opts = opts or {} } return #Emits end,
}
Mock.exportsByResource['pfm-banking'] = { Transfer = function() return { ok = true } end }
function GetResourceState(name) return (name == 'pf-services' or name == 'pfm-banking') and 'started' or 'missing' end
Commands = {}
QBCoreMock.Commands.Add = function(name, _, _, _, fn) Commands[name] = fn end
QBCoreMock.Functions.HasPermission = function() return false end
QBCoreMock.Functions.GetPermission = function() return 'admin' end
-- fengari has no '%02.f' (precision without digits), which the lap races' clock text uses
local realFormat = string.format
string.format = function(fmt, ...) return realFormat((tostring(fmt):gsub('%%(%d*)%.f', '%%%1.0f')), ...) end
local function events(kind)
    local out = {}
    for _, e in ipairs(Emits) do if e.kind == kind then out[#out + 1] = e end end
    return out
end

Config = nil
load_resource('pfm-weathersync/config.lua')
load_resource('pfm-weathersync/server/server.lua')
local WeatherCfg = Config
local setWeather, nextStage = Mock.selfExport('setWeather'), Mock.selfExport('nextWeatherStage')
Config = nil
load_resource('pfm-streetraces/config.lua')
load_resource('pfm-streetraces/server/main.lua')
local StreetCfg = Config
Config = nil
load_resource('pfm-lapraces/config.lua')
load_resource('pfm-lapraces/server/main.lua')
local LapCfg = Config

local A, B = 1, 2
BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 10000
    Mock.players, Mock.coords, Emits = {}, {}, {}
    Mock.newPlayer(A, 'ACID').PlayerData.charinfo = { firstname = 'Ann', lastname = 'Speed' }
    Mock.newPlayer(B, 'BCID').PlayerData.charinfo = { firstname = 'Bob', lastname = 'Slow' }
end

describe('severe weather', function()
    it('turning into a storm is one bulletin; staying in it or calm weather adds none', function()
        Config = WeatherCfg
        setWeather('CLEAR')
        setWeather('THUNDER')
        setWeather('THUNDER')
        setWeather('RAIN')
        local ev = events('weather.severe')
        assert_eq(#ev, 1)
        assert_eq(ev[1].data.weather, 'THUNDER')
        assert_eq(ev[1].data.previous, 'CLEAR')
        setWeather('BLIZZARD')
        assert_eq(#events('weather.severe'), 2)
    end)
    it('the automatic weather cycle reports a storm too', function()
        Config = WeatherCfg
        setWeather('RAIN')
        Config.DynamicWeatherPatterns = true
        Config.WeatherPatterns.RAIN = { { weather = 'THUNDER', weight = 1 } }
        nextStage()
        Config.DynamicWeatherPatterns = false
        local ev = events('weather.severe')
        assert_eq(#ev, 1)
        assert_eq(ev[1].data.weather, 'THUNDER')
    end)
end)

describe('street race result', function()
    local start, finish = vector3(100, 100, 30), vector3(700, 100, 30)
    local function race(withB)
        Config = StreetCfg
        Mock.coords[A] = start
        Commands.createrace(A, { '200' })
        Mock.fireNet('qb-streetraces:NewRace', A, { endx = finish.x, endy = finish.y, endz = finish.z })
        local ids = Mock.clientEventsNamed('qb-streetraces:SetRaceId')
        local id = ids[#ids].args[1]
        if withB then
            Mock.coords[B] = start
            Mock.fireNet('qb-streetraces:JoinRace', B, id)
        end
        Commands.startrace(A)
        return id
    end
    it('the server-judged winner of a race with two racers is one lead', function()
        local id = race(true)
        Mock.clock = Mock.clock + 60
        Mock.coords[A] = vector3(5, 5, 5)
        Mock.fireNet('qb-streetraces:RaceWon', A, id)                          -- not at the finish
        assert_eq(#Emits, 0)
        Mock.coords[A] = finish
        Mock.fireNet('qb-streetraces:RaceWon', A, id)
        Mock.coords[B] = finish
        Mock.fireNet('qb-streetraces:RaceWon', B, id)                          -- race already over
        local ev = events('race.finished')
        assert_eq(#ev, 1)
        assert_eq(ev[1].data.winner, 'Ann Speed')
        assert_eq(ev[1].data.seconds, 60)
        assert_eq(ev[1].data.racers, 2)
        assert_near(ev[1].opts.coords.x, finish.x, 0.01)
    end)
    it('a solo "race" is no news', function()
        local id = race(false)
        Mock.clock = Mock.clock + 60
        Mock.coords[A] = finish
        Mock.fireNet('qb-streetraces:RaceWon', A, id)
        assert_eq(#Emits, 0)
    end)
end)

describe('lap race result', function()
    local cps = {
        { coords = { x = 0, y = 0, z = 30 }, offset = {} },
        { coords = { x = 500, y = 0, z = 30 }, offset = {} },
        { coords = { x = 1000, y = 0, z = 30 }, offset = {} },
    }
    local function setup(name)
        Config = LapCfg
        Mock.fireNet('qb-lapraces:server:SaveRace', A, { RaceName = name, Checkpoints = cps, RaceDistance = 1000 })
        local id
        for rid, r in pairs(Mock.callCallback('qb-lapraces:server:GetListedRaces', A)) do if r.RaceName == name then id = rid end end
        Mock.fireNet('qb-lapraces:server:SetupRace', A, id, 0)
        Mock.fireNet('qb-lapraces:server:JoinRace', A, { RaceId = id })
        Mock.fireNet('qb-lapraces:server:JoinRace', B, { RaceId = id })
        Mock.fireNet('qb-lapraces:server:StartRace', A, id)
        Mock.clock = Mock.clock + 100
        return id
    end
    it('the first finisher, at the finish line, is one lead with the server race time', function()
        local id = setup('Docks Sprint')
        Mock.coords[A] = vector3(1005, 3, 30)
        Mock.fireNet('qb-lapraces:server:FinishPlayer', A, { RaceId = id }, 1000, 0, 0)
        Mock.coords[B] = vector3(1000, 0, 30)
        Mock.fireNet('qb-lapraces:server:FinishPlayer', B, { RaceId = id }, 1200, 0, 0)
        local ev = events('race.finished')
        assert_eq(#ev, 1)
        assert_eq(ev[1].data.race, 'Docks Sprint')
        assert_eq(ev[1].data.winner, 'Ann Speed')
        assert_eq(ev[1].data.seconds, 100)
        assert_eq(ev[1].data.racers, 2)
    end)
    it('a "finish" sent far from the finish line is not reported', function()
        local id = setup('Hill Sprint')
        Mock.coords[A] = vector3(20, 20, 30)                                   -- still at the start
        Mock.fireNet('qb-lapraces:server:FinishPlayer', A, { RaceId = id }, 1000, 0, 0)
        assert_eq(#Emits, 0)
    end)
end)
