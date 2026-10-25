-- pfm-bankrobbery: the police alert must come from the bank it names (any spot and any bank id
-- used to work, and an unknown Fleeca id errored).
load_resource('tests/lua/fivem_mocks.lua')
Mock.exportsByResource['pfm-inventory'] = { AddItem = function() return true end, RemoveItem = function() return true end, GetItemByName = function() end }
setmetatable(QBCoreMock.Shared.Items, { __index = function(_, k) return { name = k, label = k } end })
load_resource('pfm-bankrobbery/sh_config.lua')
load_resource('pfm-bankrobbery/sv_config.lua')
Config.OnRobberyStart, Config.OnRobberyTimeoutEnd, Config.OnBlackout, Config.OnPoliceCameraHit = function() end, function() end, function() end, function() end
load_resource('pfm-bankrobbery/server/main.lua')

local R = 1
local function calls() return #Mock.clientEventsNamed('qb-bankrobbery:client:robberyCall') end

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 1000
    Mock.players, Mock.coords = {}, {}
    Mock.newPlayer(R)
end

describe('bank robbery alert', function()
    it('is ignored away from the bank, even with coordinates next to the player', function()
        Mock.coords[R] = vector3(1000, 1000, 30)
        Mock.fireNet('qb-bankrobbery:server:callCops', R, 'small', 1, vector3(1000, 1000, 30))
        Mock.clock = Mock.clock + 60
        Mock.fireNet('qb-bankrobbery:server:callCops', R, 'pacific', 0, vector3(1000, 1000, 30))
        assert_eq(calls(), 0)
    end)
    it('an unknown bank id is ignored without an error', function()
        Mock.coords[R] = vector3(1000, 1000, 30)
        local ok = pcall(Mock.fireNet, 'qb-bankrobbery:server:callCops', R, 'small', 999, vector3(1000, 1000, 30))
        assert_true(ok)
        assert_eq(calls(), 0)
    end)
    it('at the Fleeca panel it alerts', function()
        local c = Config.SmallBanks[1]['coords']
        Mock.coords[R] = vector3(c.x, c.y, c.z)
        Mock.fireNet('qb-bankrobbery:server:callCops', R, 'small', 1, vector3(c.x, c.y, c.z))
        assert_eq(calls(), 1)
    end)
end)
