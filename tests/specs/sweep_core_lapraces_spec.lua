-- pfm-lapraces: tracks are saved only by whitelisted creators, the track view sends only the creator's
-- name, and race events act only on races the sender is really in.
load_resource('tests/lua/fivem_mocks.lua')
-- fengari rejects '%02.f' (no precision digits), which real Lua reads as '%02.0f'
local realFormat = string.format
string.format = function(f, ...)
    if type(f) == 'string' then f = f:gsub('%%02%.f', '%%02.0f') end
    return realFormat(f, ...)
end
Config = nil
load_resource('pfm-lapraces/config.lua')
Config.WhitelistedCreators = { 'CREATOR' }
QBCoreMock.Functions.GetPermission = function() return {} end

-- the creator's players row, as the database would return it
local playerRow = {
    citizenid = 'CREATOR', money = '{"bank":250000}', inventory = '[{"name":"weapon_pistol"}]',
    license = 'license:abc', charinfo = '{"firstname":"Ada","lastname":"Racer","phone":"5551234"}',
}
MySQL.query = setmetatable({
    await = function(query, params)
        Mock.dbCalls[#Mock.dbCalls + 1] = { kind = 'query', query = query, params = params }
        if query:find('FROM players') then
            local row = {}
            for col in query:match('SELECT (.-) FROM'):gmatch('[%w_%*]+') do
                if col == '*' then for k, v in pairs(playerRow) do row[k] = v end else row[col] = playerRow[col] end
            end
            return { row }
        end
        return {}
    end,
}, { __call = function() return {} end })

load_resource('pfm-lapraces/server/main.lua')

local CREATOR, RACER, OTHER = 1, 2, 3

local function inserts()
    local out = {}
    for _, c in ipairs(Mock.dbCalls) do if c.kind == 'insert' then out[#out + 1] = c end end
    return out
end
local function track(name)
    return { RaceName = name, RaceDistance = 1200, Checkpoints = {
        { coords = { x = 0, y = 0, z = 0 }, offset = {} }, { coords = { x = 100, y = 0, z = 0 }, offset = {} } } }
end
local function races() return Mock.callCallback('qb-lapraces:server:GetListedRaces', CREATOR) end
local function raceIdNamed(name)
    for id, r in pairs(races()) do if r.RaceName == name then return id end end
end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    Mock.newPlayer(CREATOR, 'CREATOR')
    Mock.newPlayer(RACER, 'RACER')
    Mock.newPlayer(OTHER, 'OTHER')
    Config.RaceSetupAllowed = true
    Mock.clock = Mock.clock + 1000
    -- one open race per creator: close the previous test's race
    for _, open in pairs(Mock.callCallback('qb-lapraces:server:GetRaces', CREATOR)) do
        Mock.fireNet('qb-lapraces:server:CancelRace', CREATOR, open.RaceId)
    end
    Mock.reset()
end

describe('saving tracks', function()
    it('a player who is not a whitelisted creator cannot save a track', function()
        Mock.fireNet('qb-lapraces:server:SaveRace', OTHER, track('Rogue Track'))
        assert_eq(#inserts(), 0)
        assert_eq(raceIdNamed('Rogue Track'), nil)
    end)
    it('a whitelisted creator saves it under the same id in memory and in the database', function()
        Mock.fireNet('qb-lapraces:server:SaveRace', CREATOR, track('Harbor Loop'))
        local id = raceIdNamed('Harbor Loop')
        assert_true(id, 'saved')
        assert_eq(inserts()[1].params[5], id)
    end)
    it('a malformed track does not crash', function()
        Mock.fireNet('qb-lapraces:server:SaveRace', CREATOR, { RaceName = 'Bad', Checkpoints = 'x' })
        Mock.fireNet('qb-lapraces:server:SaveRace', CREATOR, nil)
        assert_eq(#inserts(), 0)
    end)
end)

describe('track data', function()
    it("only the creator's name is sent", function()
        Mock.fireNet('qb-lapraces:server:SaveRace', CREATOR, track('Dock Sprint'))
        local id = raceIdNamed('Dock Sprint')
        local _, creator = Mock.callCallback('qb-lapraces:server:GetTrackData', OTHER, id)
        assert_eq(creator.charinfo.firstname, 'Ada')
        assert_eq(creator.charinfo.phone, nil, 'no phone number')
        assert_eq(creator.money, nil, 'no money')
        assert_eq(creator.inventory, nil, 'no inventory')
        assert_eq(creator.license, nil, 'no license')
    end)
    it('an unknown race id does not crash', function()
        assert_eq(Mock.callCallback('qb-lapraces:server:GetTrackData', OTHER, 'LR-0000'), nil)
    end)
end)

describe('race events', function()
    local function setup(name)
        Mock.fireNet('qb-lapraces:server:SaveRace', CREATOR, track(name))
        local id = raceIdNamed(name)
        Mock.fireNet('qb-lapraces:server:SetupRace', CREATOR, id, 2)
        return id
    end
    it('a lap count out of range is refused, and setup can be switched off', function()
        Mock.fireNet('qb-lapraces:server:SaveRace', CREATOR, track('Laps'))
        local id = raceIdNamed('Laps')
        Mock.fireNet('qb-lapraces:server:SetupRace', CREATOR, id, 100000)
        assert_eq(#Mock.callCallback('qb-lapraces:server:GetRaces', CREATOR), 0)
        Config.RaceSetupAllowed = false
        Mock.fireNet('qb-lapraces:server:SetupRace', CREATOR, id, 2)
        assert_eq(#Mock.callCallback('qb-lapraces:server:GetRaces', CREATOR), 0)
    end)
    it('a player not in a race cannot start or stop it', function()
        local id = setup('State')
        Mock.fireNet('qb-lapraces:server:UpdateRaceState', OTHER, id, true, false)
        assert_false(races()[id].Started, 'not started by an outsider')
        Mock.fireNet('qb-lapraces:server:JoinRace', RACER, { RaceId = id })
        Mock.fireNet('qb-lapraces:server:UpdateRaceState', RACER, id, true, false)
        assert_false(races()[id].Started, 'a racer cannot start it either; the creator does')
    end)
    it('a finish from a player not in the race sets no record', function()
        local id = setup('Records')
        Mock.reset()
        Mock.fireNet('qb-lapraces:server:FinishPlayer', OTHER, { RaceId = id, RaceName = 'Records' }, 1, 2, 1)
        assert_eq(#Mock.dbCalls, 0)
        assert_eq(next(races()[id].Records), nil)
    end)
    it('a racer finishing a started race is recorded once', function()
        local id = setup('Finish')
        Mock.fireNet('qb-lapraces:server:JoinRace', RACER, { RaceId = id })
        Mock.fireNet('qb-lapraces:server:StartRace', CREATOR, id)
        Mock.fireNet('qb-lapraces:server:FinishPlayer', RACER, { RaceId = id }, 5000, 2, 2400)
        assert_eq(races()[id].Records.Time, 2400)
        Mock.reset()
        Mock.fireNet('qb-lapraces:server:FinishPlayer', RACER, { RaceId = id }, 10, 2, 1)
        assert_eq(#Mock.dbCalls, 0, 'no second finish')
    end)
    it('a finish faster than the race has been running is refused', function()
        local id = setup('Clock')
        Mock.fireNet('qb-lapraces:server:JoinRace', RACER, { RaceId = id })
        Mock.fireNet('qb-lapraces:server:StartRace', CREATOR, id)
        Mock.clock = Mock.clock + 300 -- five minutes of racing
        Mock.fireNet('qb-lapraces:server:FinishPlayer', RACER, { RaceId = id }, 50, 2, 20)
        assert_eq(next(races()[id].Records), nil)
    end)
    it('unknown races and garbage payloads do not crash', function()
        Mock.fireNet('qb-lapraces:server:JoinRace', OTHER, { RaceId = 'LR-0000' })
        Mock.fireNet('qb-lapraces:server:JoinRace', OTHER, nil)
        Mock.fireNet('qb-lapraces:server:LeaveRace', OTHER, { RaceId = 'LR-0000' })
        Mock.fireNet('qb-lapraces:server:UpdateRacerData', OTHER, 'LR-0000', 1, 1, false)
        Mock.fireNet('qb-lapraces:server:UpdateRaceState', OTHER, 'LR-0000', true, false)
        Mock.fireNet('qb-lapraces:server:StartRace', OTHER, 'LR-0000')
        Mock.fireNet('qb-lapraces:server:FinishPlayer', OTHER, nil)
        Mock.fireNet('qb-lapraces:server:CancelRace', OTHER, { 1 })
    end)
end)
