-- pfm-lapraces (fix14 LAP-1): race times are measured on the server. Each checkpoint counts only in
-- order, with the racer standing at it (server position), after the countdown and no sooner than the
-- track allows (distance at a top speed); the finish time and best lap come from the server's stamps.
-- The client's clock (UI ticks) and its checkpoint numbers used to be taken: one second after the
-- start, FinishPlayer(race, 1, 5, 1) became the track record, and a news lead if the cheater stood at
-- the finish line. A record from before (a tick count) no longer stands.
load_resource('tests/lua/fivem_mocks.lua')
Emits = {}
Mock.exportsByResource['pf-services'] = {
    Emit = function(_, kind, data, opts) Emits[#Emits + 1] = { kind = kind, data = data, opts = opts or {} } return #Emits end,
}
function GetResourceState(name) return name == 'pf-services' and 'started' or 'missing' end
QBCoreMock.Functions.GetPermission = function() return {} end
-- fengari rejects '%02.f' (no precision digits), which real Lua reads as '%02.0f'
local realFormat = string.format
string.format = function(f, ...) return realFormat((tostring(f):gsub('%%(%d*)%.f', '%%%1.0f')), ...) end

-- a track saved before this fix, with a record that was the client's tick count
local storedTrack = {
    raceid = 'LR-1111', name = 'Old Loop', creator = 'CREATOR', distance = 2000,
    checkpoints = '[{"coords":{"x":0,"y":0,"z":0},"offset":{}},{"coords":{"x":1000,"y":0,"z":0},"offset":{}},{"coords":{"x":2000,"y":0,"z":0},"offset":{}}]',
    records = '{"Time":1,"Holder":["Cheat","Er"]}',
}
MySQL.query = setmetatable({
    await = function(query, params)
        Mock.dbCalls[#Mock.dbCalls + 1] = { kind = 'query', query = query, params = params }
        if query:find('FROM lapraces') then return { storedTrack } end
        return {}
    end,
}, { __call = function() return {} end })
function CreateThread(fn) fn() end   -- the track list loads when the resource starts
Config = nil
load_resource('pfm-lapraces/config.lua')
Config.WhitelistedCreators = { 'CREATOR' }
load_resource('pfm-lapraces/server/main.lua')
function CreateThread() end

local CREATOR, RACER, OTHER = 1, 2, 3
local CP = { vector3(0, 0, 0), vector3(1000, 0, 0), vector3(2000, 0, 0) }
local RADIUS, SPEED = Config.CheckpointRadius, Config.MaxSpeed

local function races() return Mock.callCallback('qb-lapraces:server:GetListedRaces', CREATOR) end
local function trackId(name)
    for id, r in pairs(races()) do if r.RaceName == name then return id end end
end
local nameNo = 0
local function newTrack()
    nameNo = nameNo + 1
    local name = 'Track ' .. nameNo
    local cps = {}
    for i, c in ipairs(CP) do cps[i] = { coords = { x = c.x, y = c.y, z = c.z }, offset = {} } end
    Mock.fireNet('qb-lapraces:server:SaveRace', CREATOR, { RaceName = name, Checkpoints = cps, RaceDistance = 1 })
    return trackId(name)
end
local START
--- sets up a race on `id` with `laps`, the racers joined and started; returns the server's GO time
local function start(id, laps, racers)
    Mock.fireNet('qb-lapraces:server:SetupRace', CREATOR, id, laps)
    for _, src in ipairs(racers or { RACER }) do Mock.fireNet('qb-lapraces:server:JoinRace', src, { RaceId = id }) end
    Mock.gameTimer = 100000
    Mock.fireNet('qb-lapraces:server:StartRace', CREATOR, id)
    START = 100001 + 10000   -- the countdown
    return START
end
--- the racer reports a pass standing at `pos`, `ms` after GO
local function pass(src, id, pos, ms)
    Mock.coords[src] = pos
    Mock.gameTimer = START + ms - 1
    Mock.fireNet('qb-lapraces:server:UpdateRacerData', src, id, 99, 1, true)   -- the client's numbers are not used
end
local function missed(src)
    local ev = Mock.clientEventsNamed('qb-lapraces:client:CheckpointMissed')
    for i = #ev, 1, -1 do if ev[i].target == src then return ev[i].args end end
end
local function finished(src)
    for _, e in ipairs(Mock.clientEventsNamed('qb-lapraces:client:RaceFinished')) do if e.target == src then return e.args end end
end
local function recordWrites()
    local n = 0
    for _, c in ipairs(Mock.dbCalls) do if tostring(c.query):find('UPDATE lapraces SET records', 1, true) then n = n + 1 end end
    return n
end
-- the shortest legal time between two checkpoints
local function minMs(a, b) return math.floor((#(CP[a] - CP[b]) - 2 * RADIUS) / SPEED * 1000) end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords, Emits = {}, {}, {}
    Mock.newPlayer(CREATOR, 'CREATOR').PlayerData.charinfo = { firstname = 'Ada', lastname = 'Maker' }
    Mock.newPlayer(RACER, 'RACER').PlayerData.charinfo = { firstname = 'Rex', lastname = 'Racer' }
    Mock.newPlayer(OTHER, 'OTHER').PlayerData.charinfo = { firstname = 'Ola', lastname = 'Other' }
    Config.RaceSetupAllowed = true
    Mock.clock = Mock.clock + 1000
    for _, open in pairs(Mock.callCallback('qb-lapraces:server:GetRaces', CREATOR)) do
        Mock.fireNet('qb-lapraces:server:CancelRace', CREATOR, open.RaceId)
    end
    Mock.reset()
end

describe('fix14 LAP-1: the scenario', function()
    it('a "finish" one second after the start sets no time, no record and no news', function()
        local id = newTrack()
        start(id, 5, { RACER, OTHER })
        Mock.coords[RACER] = CP[1]                                   -- teleported to the finish line
        Mock.gameTimer = START + 1000
        if Mock.netHandlers['qb-lapraces:server:FinishPlayer'] then
            Mock.fireNet('qb-lapraces:server:FinishPlayer', RACER, { RaceId = id }, 1, 5, 1)
        end
        -- and every checkpoint reported from the finish line, one after another
        for _ = 1, 15 do pass(RACER, id, CP[1], 1000) end
        assert_eq(next(races()[id].Records), nil, 'no record')
        assert_eq(recordWrites(), 0)
        assert_eq(finished(RACER), nil)
        assert_eq(#Emits, 0, 'no news lead')
    end)
end)

describe('fix14 LAP-1: a sprint', function()
    it('driven checkpoint by checkpoint is timed by the server', function()
        local id = newTrack()
        start(id, 0)
        pass(RACER, id, vector3(CP[2].x + 20, 5, 0), 15000)
        pass(RACER, id, CP[3], 31250)
        local f = finished(RACER)
        assert_true(f ~= nil, 'finished')
        assert_eq(f[2], 31250, 'total, ms')
        assert_eq(f[3], 31250, 'a sprint\'s best is its total')
        local rec = races()[id].Records
        assert_eq(rec.TimeMs, 31250)
        assert_eq(rec.Time, 31, 'whole seconds for the phone')
        assert_eq(rec.Holder[1], 'Rex')
        assert_eq(recordWrites(), 1)
        local board = races()[id].LastLeaderboard
        assert_eq(board[1].TotalTimeMs, 31250)
    end)

    it('a checkpoint reported away from it is not counted and the client is sent back to it', function()
        local id = newTrack()
        start(id, 0)
        pass(RACER, id, vector3(CP[2].x, RADIUS + 30, 0), 15000)
        local m = missed(RACER)
        assert_eq(m[1], id)
        assert_eq(m[2], 2, 'back to checkpoint 2')
        assert_eq(m[4], 'far')
        -- skipping it: checkpoint 3 does not count either
        pass(RACER, id, CP[3], 30000)
        assert_eq(missed(RACER)[2], 2)
        assert_eq(finished(RACER), nil)
        -- driving back through it, then on to the end
        pass(RACER, id, CP[2], 45000)
        pass(RACER, id, CP[3], 60000)
        assert_eq(finished(RACER)[2], 60000)
    end)

    it('faster than the track allows (a teleport) is not counted', function()
        local id = newTrack()
        start(id, 0)
        pass(RACER, id, CP[2], minMs(1, 2) - 50)
        assert_eq(missed(RACER)[4], 'fast')
        pass(RACER, id, CP[2], minMs(1, 2) + 50)
        assert_eq(missed(RACER)[4], 'fast', 'unchanged: that pass counted')
        pass(RACER, id, CP[3], minMs(1, 2) + 100)
        assert_eq(finished(RACER), nil)
        pass(RACER, id, CP[3], minMs(1, 2) + 50 + minMs(2, 3) + 10)
        assert_true(finished(RACER) ~= nil)
    end)

    it('nothing counts during the countdown', function()
        local id = newTrack()
        start(id, 0)
        pass(RACER, id, CP[2], -2000)
        assert_eq(missed(RACER)[4], 'early')
    end)

    it('only a racer of the started race is timed; garbage does not crash', function()
        local id = newTrack()
        pass(OTHER, id, CP[2], 15000)
        start(id, 0)
        pass(OTHER, id, CP[2], 15000)
        assert_eq(missed(OTHER), nil)
        Mock.fireNet('qb-lapraces:server:UpdateRacerData', RACER, nil)
        Mock.fireNet('qb-lapraces:server:UpdateRacerData', RACER, { 1 })
        Mock.fireNet('qb-lapraces:server:UpdateRacerData', RACER, 'LR-0000')
        assert_eq(next(races()[id].Records), nil)
    end)
end)

describe('fix14 LAP-1: a lap race', function()
    it('each lap ends at the start line; the best lap and the total come from the server\'s stamps', function()
        local id = newTrack()
        start(id, 2)
        -- lap 1: 2, 3, back to 1
        pass(RACER, id, CP[2], 15000)
        pass(RACER, id, CP[3], 30000)
        pass(RACER, id, CP[1], 60000)
        assert_eq(finished(RACER), nil, 'one more lap')
        -- lap 2, quicker
        pass(RACER, id, CP[2], 72000)
        pass(RACER, id, CP[3], 84000)
        pass(RACER, id, CP[1], 108000)
        local f = finished(RACER)
        assert_eq(f[2], 108000)
        assert_eq(f[3], 48000, 'the second lap')
        assert_eq(races()[id].Records.TimeMs, 48000)
    end)

    it('a lap shorter than the track\'s minimum is refused even at the right places', function()
        local id = newTrack()
        start(id, 1)
        local t = minMs(1, 2) + 1
        pass(RACER, id, CP[2], t)
        t = t + minMs(2, 3) + 1
        pass(RACER, id, CP[3], t)
        pass(RACER, id, CP[1], t + 100)                          -- 2 km back in 0.1 s
        assert_eq(missed(RACER)[2], 1)
        assert_eq(finished(RACER), nil)
        pass(RACER, id, CP[1], t + minMs(3, 1) + 1)
        assert_true(finished(RACER) ~= nil)
    end)
end)

describe('fix14 LAP-1: records and results', function()
    it('a record from before server timing does not stand; the first measured time replaces it', function()
        assert_eq(next(races()['LR-1111'].Records), nil, 'the tick-count record is not shown')
        start('LR-1111', 0)
        pass(RACER, 'LR-1111', CP[2], 20000)
        pass(RACER, 'LR-1111', CP[3], 40000)
        assert_eq(races()['LR-1111'].Records.TimeMs, 40000)
        assert_eq(recordWrites(), 1)
    end)

    it('a slower time does not replace the record', function()
        local id = newTrack()
        start(id, 0)
        pass(RACER, id, CP[2], 15000)
        pass(RACER, id, CP[3], 30000)
        start(id, 0)
        pass(RACER, id, CP[2], 20000)
        pass(RACER, id, CP[3], 45000)
        assert_eq(races()[id].Records.TimeMs, 30000)
        assert_eq(recordWrites(), 1)
    end)

    it('the winner of a race with two racers is a lead with the server\'s time; others see only the name', function()
        local id = newTrack()
        start(id, 0, { RACER, OTHER })
        pass(RACER, id, CP[2], 15000)
        pass(RACER, id, CP[3], 30500)
        assert_eq(#Emits, 1)
        assert_eq(Emits[1].data.seconds, 30)
        assert_eq(Emits[1].data.winner, 'Rex Racer')
        local ev = Mock.clientEventsNamed('qb-lapraces:client:PlayerFinishs')
        local who = ev[#ev].args[3]
        assert_eq(who.PlayerData.charinfo.firstname, 'Rex')
        assert_eq(who.PlayerData.citizenid, nil, 'not the whole player')
        assert_eq(who.PlayerData.money, nil)
    end)

    it('a track needs real positions; its length is measured on the server', function()
        Mock.fireNet('qb-lapraces:server:SaveRace', CREATOR, { RaceName = 'Bad Pos', RaceDistance = 5,
            Checkpoints = { { coords = { x = 'a', y = 0, z = 0 } }, { coords = { x = 1, y = 0, z = 0 } } } })
        assert_eq(trackId('Bad Pos'), nil)
        Mock.fireNet('qb-lapraces:server:SaveRace', CREATOR, { RaceName = 'NaN Pos', RaceDistance = 5,
            Checkpoints = { { coords = { x = 0 / 0, y = 0, z = 0 } }, { coords = { x = 1, y = 0, z = 0 } } } })
        assert_eq(trackId('NaN Pos'), nil)
        local id = newTrack()
        assert_eq(races()[id].Distance, 2000, 'not the 1 m the client said')
    end)
end)
