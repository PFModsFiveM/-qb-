-- pfm-jewelery: the server starts each smash (weapon, police on duty, at the case) and pays after it.
load_resource('tests/lua/fivem_mocks.lua')
Inv = {}
Mock.exportsByResource['pfm-inventory'] = { AddItem = function(_, src, item, n) Inv[src] = (Inv[src] or 0) + (n or 1) return true end }
setmetatable(QBCoreMock.Shared.Items, { __index = function(_, k) return { name = k, label = k } end })
load_resource('pfm-jewelery/config.lua')
load_resource('pfm-jewelery/server/main.lua')

local R, COP = 1, 2
local weapon = {}
function GetSelectedPedWeapon(ped) return weapon[ped] or 0 end
local function case(k) return Config.Locations[k].coords end
local function loot() return Inv[R] or 0 end

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 100000
    Mock.gameTimer = Mock.gameTimer + 60000
    Mock.players, Mock.coords, Inv, Mock.dropped, weapon = {}, {}, {}, {}, {}
    Mock.newPlayer(R).PlayerData.job = { name = 'unemployed', onduty = false }
    for k in pairs(Config.Locations) do Config.Locations[k].isOpened = false; Config.Locations[k].isBusy = false end
    Mock.fireEvent('playerDropped', R)
    Config.RequiredCops = 1
    Mock.newPlayer(COP).PlayerData.job = { name = 'police', type = 'leo', onduty = true }
    weapon[R] = joaat('weapon_pistol')
    Mock.coords[R] = case(1)
end

describe('jewelery', function()
    it('a bare reward event pays nothing and bans nobody', function()
        Mock.fireNet('qb-jewellery:server:vitrineReward', R, 1)
        assert_eq(loot(), 0)
        assert_eq(#Mock.dropped, 0)
        assert_false(Config.Locations[1].isOpened)
    end)
    it('a smash pays once after the smash time', function()
        Mock.fireNet('qb-jewellery:server:setVitrineState', R, 'isBusy', true, 1)
        assert_true(Config.Locations[1].isBusy)
        Mock.fireNet('qb-jewellery:server:vitrineReward', R, 1)   -- too early
        assert_eq(loot(), 0)
        Mock.clock = Mock.clock + 10
        Mock.gameTimer = Mock.gameTimer + 60000
        Mock.fireNet('qb-jewellery:server:vitrineReward', R, 1)
        assert_true(loot() > 0)
        assert_true(Config.Locations[1].isOpened)
        local got = loot()
        Mock.gameTimer = Mock.gameTimer + 60000
        Mock.fireNet('qb-jewellery:server:vitrineReward', R, 1)
        assert_eq(loot(), got)
    end)
    it('no smash without a weapon or without police on duty', function()
        weapon[R] = 0
        Mock.fireNet('qb-jewellery:server:setVitrineState', R, 'isBusy', true, 1)
        assert_false(Config.Locations[1].isBusy)
        weapon[R] = joaat('weapon_pistol')
        Mock.players[COP].PlayerData.job.onduty = false
        Mock.gameTimer = Mock.gameTimer + 60000
        Mock.fireNet('qb-jewellery:server:setVitrineState', R, 'isBusy', true, 1)
        assert_false(Config.Locations[1].isBusy)
    end)
end)
