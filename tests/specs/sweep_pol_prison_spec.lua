-- pfm-prison: jail money, items after an escape, the phone search and the prison alarm.
load_resource('tests/lua/ledger_env.lua')
QBCore = QBCoreMock
vec2 = vector2
local added = {}
Mock.exportsByResource['pfm-inventory'] = {
    AddItem = function(_, src, name, amount) added[#added + 1] = { src = src, name = name, amount = amount } return true end,
}
LedgerEnv.load('pfm-prison', { 'pfm-prison/config.lua', 'pfm-prison/server/main.lua' })

local INMATE, COP = 1, 2
local MIDDLE = vector3(Config.Locations['middle'].x, Config.Locations['middle'].y, Config.Locations['middle'].z)

local function inmate() return Mock.players[INMATE] end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players, Mock.coords = {}, {}
    added = {}
    local p = Mock.newPlayer(INMATE)
    p.PlayerData.money = { cash = 0, bank = 0 }
    p.PlayerData.job = { name = 'unemployed' }
    p.ClearInventory = function() p.PlayerData.items = {} end
    p.SetJob = function(name) p.PlayerData.job = { name = name } end
    p.PlayerData.items = {}
    p.PlayerData.metadata.injail = 1
    Mock.fireNet('prison:server:SetJailStatus', INMATE, 0)   -- clears what the previous test left behind
    p.PlayerData.metadata.injail = 30
    Mock.coords[INMATE] = MIDDLE
    local cop = Mock.newPlayer(COP)
    cop.PlayerData.job = { name = 'police', onduty = true }
    Mock.coords[COP] = vector3(0, 0, 0)
end

describe('jail money', function()
    it('is paid once per sentence even with an empty inventory', function()
        for _ = 1, 5 do Mock.fireNet('prison:server:SaveJailItems', INMATE) end
        assert_eq(inmate().PlayerData.money.cash, 80)
    end)
    it('is paid again for the next sentence', function()
        Mock.fireNet('prison:server:SaveJailItems', INMATE)
        inmate().PlayerData.metadata.injail = 1
        Mock.fireNet('prison:server:SetJailStatus', INMATE, 0)        -- time served
        inmate().PlayerData.metadata.injail = 30
        Mock.fireNet('prison:server:SaveJailItems', INMATE)
        assert_eq(inmate().PlayerData.money.cash, 160)
    end)
end)

describe('escape', function()
    it('an escapee does not get the stored items back', function()
        inmate().PlayerData.items = { { name = 'goldbar', amount = 3 } }
        Mock.fireNet('prison:server:SaveJailItems', INMATE)
        Mock.coords[INMATE] = MIDDLE + vector3(500, 0, 0)
        Mock.fireNet('prison:server:SetJailStatus', INMATE, 0)
        assert_eq(inmate().PlayerData.metadata.injail, 0)
        Mock.fireNet('prison:server:GiveJailItems', INMATE)          -- "not escaped", says the client
        assert_eq(#added, 0)
    end)
    it('a released inmate gets the items back', function()
        inmate().PlayerData.items = { { name = 'goldbar', amount = 3 } }
        Mock.fireNet('prison:server:SaveJailItems', INMATE)
        inmate().PlayerData.metadata.injail = 1
        Mock.fireNet('prison:server:SetJailStatus', INMATE, 0)
        Mock.fireNet('prison:server:GiveJailItems', INMATE)
        assert_eq(#added, 1)
        assert_eq(added[1].name, 'goldbar')
    end)
end)

describe('phone search and alarm', function()
    it('spamming the phone search is rate limited', function()
        local rolls = 0
        local realRandom = math.random
        math.random = function(...) rolls = rolls + 1 return realRandom(...) end
        for _ = 1, 50 do Mock.fireNet('prison:server:CheckChance', INMATE) end
        math.random = realRandom
        assert_eq(rolls, 2)          -- one search: chance and odd
    end)
    it('the alarm needs a real break and rings once', function()
        Mock.clock = Mock.clock + 3600                   -- long after the escape in an earlier test
        Mock.fireNet('prison:server:JailAlarm', COP)
        assert_eq(#Mock.clientEventsNamed('prison:client:JailAlarm'), 0)
        Mock.fireNet('prison:server:SecurityLockdown', INMATE)
        Mock.fireNet('prison:server:JailAlarm', COP)
        Mock.fireNet('prison:server:JailAlarm', COP)
        assert_eq(#Mock.clientEventsNamed('prison:client:JailAlarm'), 1)
        assert_eq(Mock.callCallback('prison:server:IsAlarmActive', COP), true)
    end)
    it('a missing criminal record does not crash', function()
        Mock.fireNet('prison:server:CheckRecordStatus', INMATE)
        assert_true(true)
    end)
end)
