-- pfm-doorlock: a client acts only as itself, from beside the door; `unlockAnyway` needs a grant from a
-- server script and `usedLockpick` a lockpick.
load_resource('tests/lua/fivem_mocks.lua')
local perms = {}
QBCoreMock.Functions.HasPermission = function(src, perm) return perms[src] == perm end
Config = nil
load_resource('pfm-doorlock/config.lua')
Config.DoorStates = Config.DoorStates or {}
load_resource('pfm-doorlock/server/main.lua')
local GrantDoorAccess = Mock.selfExport('GrantDoorAccess')

local THIEF, COP = 1, 2
local DOOR = vector3(10.0, 0.0, 0.0)

local function setState() return Mock.clientEventsNamed('qb-doorlock:client:setState') end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    perms = {}
    Config.DoorList = {
        ['mrpd-armory'] = { objCoords = DOOR, authorizedJobs = { police = 0 }, locked = true, distance = 2.0 },
        ['backdoor'] = { objCoords = DOOR, pickable = true, locked = true, distance = 2.0 },
    }
    Config.DoorStates = {}
    for _, src in ipairs({ THIEF, COP }) do
        local p = Mock.newPlayer(src)
        p.PlayerData.job = { name = src == COP and 'police' or 'unemployed', grade = { level = 0 } }
        p.PlayerData.gang = { name = 'none', grade = { level = 0 } }
        p.GetItemByName = function(name)
            for _, it in pairs(p.PlayerData.items) do if it.name == name then return it end end
        end
        p.RemoveItem = function() return true end
    end
    Mock.coords = { [THIEF] = vector3(9.0, 0.0, 0.0), [COP] = vector3(500.0, 0.0, 0.0) }
end

describe('updateState from a client', function()
    it("naming another player's id (sentSource) does not borrow their access", function()
        Mock.fireNet('qb-doorlock:server:updateState', THIEF, 'mrpd-armory', false, false, false, false, true, true, COP)
        assert_true(Config.DoorList['mrpd-armory'].locked)
        assert_eq(#setState(), 0)
    end)
    it('unlockAnyway alone opens nothing', function()
        Mock.fireNet('qb-doorlock:server:updateState', THIEF, 'mrpd-armory', false, false, false, true)
        assert_true(Config.DoorList['mrpd-armory'].locked)
    end)
    it('a server grant lets that player unlock that door once', function()
        assert_true(GrantDoorAccess(THIEF, 'mrpd-armory', 60000))
        Mock.fireNet('qb-doorlock:server:updateState', THIEF, 'mrpd-armory', false, false, false, true)
        assert_false(Config.DoorList['mrpd-armory'].locked)
        Config.DoorList['mrpd-armory'].locked = true
        Mock.fireNet('qb-doorlock:server:updateState', THIEF, 'mrpd-armory', false, false, false, true)
        assert_true(Config.DoorList['mrpd-armory'].locked, 'used up')
    end)
    it('an authorized player must still be at the door', function()
        Mock.fireNet('qb-doorlock:server:updateState', COP, 'mrpd-armory', false, false, false, false)
        assert_true(Config.DoorList['mrpd-armory'].locked, 'cop across the map')
        Mock.coords[COP] = vector3(11.0, 0.0, 0.0)
        Mock.fireNet('qb-doorlock:server:updateState', COP, 'mrpd-armory', false, false, false, false)
        assert_false(Config.DoorList['mrpd-armory'].locked, 'cop at the door')
    end)
    it('a lockpick unlock needs a lockpick', function()
        Mock.fireNet('qb-doorlock:server:updateState', THIEF, 'backdoor', false, false, true, false)
        assert_true(Config.DoorList['backdoor'].locked)
        Mock.players[THIEF].PlayerData.items[1] = { name = 'lockpick', slot = 1, amount = 1 }
        Mock.fireNet('qb-doorlock:server:updateState', THIEF, 'backdoor', false, false, true, false)
        assert_false(Config.DoorList['backdoor'].locked)
    end)
    it('server scripts keep full control', function()
        source = ''
        Mock.netHandlers['qb-doorlock:server:updateState']('mrpd-armory', false, false, false, true, false, false, COP)
        source = nil
        assert_false(Config.DoorList['mrpd-armory'].locked)
    end)
end)

describe('scheduledRestart', function()
    it('a client cannot trigger the door-state save', function()
        local saved = 0
        function SaveResourceFile() saved = saved + 1 end
        Mock.fireNet('txAdmin:events:scheduledRestart', THIEF, { secondsRemaining = 30 })
        assert_eq(saved, 0)
    end)
end)
