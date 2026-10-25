-- pfm-smallresources: tackles reach only nearby players, client log events are limited to the death
-- log, and harness events only touch a harness.
load_resource('tests/lua/fivem_mocks.lua')
QBCoreMock.Shared.Items.harness = { name = 'harness', label = 'Harness', weight = 1000, type = 'item', unique = true, useable = true }
Config = nil
load_resource('pfm-smallresources/config.lua')
Posts = {}
function PerformHttpRequest(url, cb, method, body) Posts[#Posts + 1] = json.decode(body) end
PFPayout = { NewId = function() return 'x' end, Charge = function() return true end }
load_resource('pfm-smallresources/server/main.lua')
load_resource('pfm-smallresources/server/logs.lua')

local removed = {}
Mock.exportsByResource['pfm-inventory'] = {
    RemoveItem = function(_, src, item, amount, slot) removed[#removed + 1] = { src = src, item = item, slot = slot } return true end,
}

local A, B, FAR = 1, 2, 3

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    Posts, removed = {}, {}
    for _, src in ipairs({ A, B, FAR }) do
        local p = Mock.newPlayer(src)
        p.SetInventory = function() end
    end
    Mock.coords = { [A] = vector3(0, 0, 0), [B] = vector3(1.5, 0, 0), [FAR] = vector3(400, 0, 0) }
    Mock.clock = Mock.clock + 100
end

describe('tackle', function()
    it('a player across the map cannot be tackled', function()
        Mock.fireNet('tackle:server:TacklePlayer', A, FAR)
        assert_eq(#Mock.clientEventsNamed('tackle:client:GetTackled'), 0)
    end)
    it('a player right beside is tackled', function()
        Mock.fireNet('tackle:server:TacklePlayer', A, B)
        local ev = Mock.clientEventsNamed('tackle:client:GetTackled')
        assert_eq(#ev, 1)
        assert_eq(ev[1].target, B)
    end)
    it('a bad id is ignored', function()
        Mock.fireNet('tackle:server:TacklePlayer', A, -1)
        Mock.fireNet('tackle:server:TacklePlayer', A, 999)
        assert_eq(#Mock.clientEventsNamed('tackle:client:GetTackled'), 0)
    end)
end)

describe('qb-log:server:CreateLog', function()
    -- a server script's TriggerEvent: no player source (the mocks route TriggerEvent to AddEventHandler only)
    local function serverLog(...)
        source = ''
        Mock.netHandlers['qb-log:server:CreateLog'](...)
        source = nil
    end
    local function serverLogs(name, n)
        for _ = 1, n do serverLog(name, 'title', 'red', 'msg') end
    end
    it('a client cannot post to other logs', function()
        serverLogs('bans', 9)
        Mock.fireNet('qb-log:server:CreateLog', A, 'bans', 'fake ban', 'red', 'fake', true)
        assert_eq(#Posts, 0, 'the tenth entry would have flushed the queue')
    end)
    it('a client death log goes out without @everyone or an image', function()
        serverLogs('death', 9)
        Mock.fireNet('qb-log:server:CreateLog', A, 'death', 'died', 'red', 'msg', true, 'https://example.invalid/x.png')
        assert_eq(#Posts, 1)
        assert_eq(Posts[1].content, nil, 'no @everyone')
        assert_eq(Posts[1].embeds[10].image, nil, 'no image')
    end)
    it('a client can send at most one log every few seconds', function()
        serverLogs('death', 8)
        Mock.fireNet('qb-log:server:CreateLog', A, 'death', 'died', 'red', 'msg')
        Mock.fireNet('qb-log:server:CreateLog', A, 'death', 'died', 'red', 'msg')
        assert_eq(#Posts, 0, 'the second one was dropped')
    end)
    it('server scripts still log with @everyone', function()
        serverLogs('robbing', 9)
        serverLog('robbing', 't', 'red', 'm', true)
        assert_eq(Posts[1].content, '@everyone')
    end)
end)

describe('harness', function()
    it('equip:harness edits only a harness in the named slot', function()
        local p = Mock.players[A]
        p.PlayerData.items[1] = { name = 'weapon_pistol', slot = 1, amount = 1, info = {} }
        Mock.fireNet('equip:harness', A, { slot = 1 })
        assert_eq(p.PlayerData.items[1].info.uses, nil, 'the pistol is untouched')
        p.PlayerData.items[2] = { name = 'harness', slot = 2, amount = 1, info = {} }
        Mock.fireNet('equip:harness', A, { slot = 2 })
        assert_eq(p.PlayerData.items[2].info.uses, Config.HarnessUses - 1)
    end)
    it('a missing slot or payload does not crash', function()
        Mock.fireNet('equip:harness', A, { slot = 9 })
        Mock.fireNet('equip:harness', A, nil)
        Mock.fireNet('seatbelt:DoHarnessDamage', A, 5, nil)
        Mock.fireNet('seatbelt:DoHarnessDamage', A, 5, { slot = 9 })
    end)
    it('harness damage at 0 removes that harness slot', function()
        Mock.players[A].PlayerData.items[2] = { name = 'harness', slot = 2, amount = 1, info = { uses = 3 } }
        Mock.fireNet('seatbelt:DoHarnessDamage', A, 0, { slot = 2 })
        assert_eq(#removed, 1)
        assert_eq(removed[1].slot, 2)
    end)
end)
