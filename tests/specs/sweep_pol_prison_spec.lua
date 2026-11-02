-- pfm-prison: jail money, items after an escape, the phone search and the prison alarm.
-- (The server decides all of it since batch 14; fix14_prison_server_spec covers the details.)
load_resource('tests/lua/ledger_env.lua')
QBCore = QBCoreMock
vec2 = vector2
local added = {}
Mock.exportsByResource['pfm-inventory'] = {
    AddItem = function(_, src, name, amount) added[#added + 1] = { src = src, name = name, amount = amount } return true end,
    ClearInventory = function(_, src) Mock.players[src].PlayerData.items = {} end,
    RemoveItem = function() return true end,
    HasItem = function() return true end,
}
Mock.exportsByResource['pfm-minigames'] = {
    IssueChallenge = function() return { id = 'c1', kind = 'hacking', puzzle = {} } end,
    Verify = function() return false end,
    Cancel = function() end,
}
LedgerEnv.load('pfm-prison', { 'pfm-prison/config.lua', 'pfm-prison/server/main.lua' })

local INMATE, COP = 1, 2
local MIDDLE = vector3(Config.Locations['middle'].x, Config.Locations['middle'].y, Config.Locations['middle'].z)

local function inmate() return Mock.players[INMATE] end
local function jail(minutes)
    Mock.invokingResource = 'pfm-policejob'
    local ok = Mock.selfExport('JailPlayer')(INMATE, minutes)
    Mock.invokingResource = nil
    return ok
end
local function unjail()
    Mock.invokingResource = 'pfm-policejob'
    local ok = Mock.selfExport('ReleasePlayer')(INMATE, 'unjail')
    Mock.invokingResource = nil
    return ok
end

BeforeEach = function()
    PFPrison.EndAlarm()
    if Mock.players[INMATE] then Mock.fireEvent('playerDropped', INMATE) end
    Mock.reset()
    LedgerEnv.reset()
    Mock.clock = Mock.clock + 5000
    Mock.players, Mock.coords = {}, {}
    added = {}
    local p = Mock.newPlayer(INMATE)
    p.PlayerData.money = { cash = 0, bank = 0 }
    p.PlayerData.job = { name = 'unemployed' }
    p.PlayerData.items = {}
    p.PlayerData.metadata.injail = 0
    Mock.coords[INMATE] = MIDDLE
    local cop = Mock.newPlayer(COP)
    cop.PlayerData.job = { name = 'police', type = 'leo', onduty = true }
    Mock.coords[COP] = vector3(0, 0, 0)
end

describe('jail money', function()
    it('is paid once per sentence even with an empty inventory', function()
        for _ = 1, 5 do jail(30) end
        assert_eq(inmate().PlayerData.money.cash, 80)
    end)
    it('is paid again for the next sentence', function()
        jail(30)
        unjail()
        jail(30)
        assert_eq(inmate().PlayerData.money.cash, 160)
    end)
end)

describe('escape', function()
    it('an inmate seen outside without a breach is taken back and keeps the stored items for the release', function()
        inmate().PlayerData.items = { { name = 'goldbar', amount = 3 } }
        jail(30)
        Mock.clock = Mock.clock + 60
        PFPrison.SampleTick()
        Mock.coords[INMATE] = MIDDLE + vector3(500, 0, 0)
        Mock.clock = Mock.clock + 2
        PFPrison.SampleTick()
        assert_eq(inmate().PlayerData.metadata.injail, 30)
        assert_eq(#added, 0)
        assert_eq(#inmate().PlayerData.metadata.jailitems, 1)
    end)
    it('a released inmate gets the items back', function()
        inmate().PlayerData.items = { { name = 'goldbar', amount = 3 } }
        jail(30)
        unjail()
        assert_eq(#added, 1)
        assert_eq(added[1].name, 'goldbar')
    end)
end)

describe('phone search and alarm', function()
    it('the phone search is part of finished prison work and cannot be spammed', function()
        assert_eq(Mock.netHandlers['prison:server:CheckChance'], nil)
        jail(30)
        local rolls = 0
        local realRandom = math.random
        math.random = function(...) rolls = rolls + 1 return realRandom(...) end
        for _ = 1, 50 do Mock.fireNet('prison:server:JobDone', INMATE, 1) end -- not at the spot, too soon
        math.random = realRandom
        assert_eq(rolls, 0)
    end)
    it('the alarm needs a real break and rings once', function()
        assert_eq(Mock.netHandlers['prison:server:JailAlarm'], nil)
        assert_eq(Mock.callCallback('prison:server:IsAlarmActive', COP), false)
        jail(30)
        Mock.coords[INMATE] = Config.Gates[1].coords
        Mock.fireNet('prison:server:StartGateHack', INMATE, 1)
        local start = Mock.clientEventsNamed('prison:client:GateHackStart')[1]
        Mock.clock = Mock.clock + 10
        Mock.fireNet('prison:server:GateHackResult', INMATE, start.args[2], true) -- the puzzle says failed
        assert_eq(#Mock.clientEventsNamed('prison:client:JailAlarm'), 1)
        assert_eq(Mock.callCallback('prison:server:IsAlarmActive', COP), true)
    end)
    it('a missing criminal record does not crash', function()
        Mock.fireNet('prison:server:CheckRecordStatus', INMATE)
        assert_true(true)
    end)
end)
