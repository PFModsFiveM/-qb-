-- pfm-truckrobbery: the payout needs the mission's own truck, the player at it, and time for the attack.
load_resource('tests/lua/fivem_mocks.lua')
Inv = {}
Mock.exportsByResource['pfm-inventory'] = { AddItem = function(_, src, item, n) Inv[item] = (Inv[item] or 0) + (n or 1) return true end }
setmetatable(QBCoreMock.Shared.Items, { __index = function(_, k) return { name = k, label = k } end })
QBCoreMock.Functions.GetPlayers = function() local out = {} for id in pairs(Mock.players) do out[#out + 1] = id end return out end
load_resource('pfm-truckrobbery/config.lua')
load_resource('pfm-truckrobbery/server/main.lua')
-- the mission timer waits: keep it paused inside a coroutine
function Wait() if coroutine.isyieldable() then coroutine.yield() end end

local R, COP, TRUCK = 1, 2, 500
Mock.models[TRUCK] = GetHashKey('stockade')

local function accept()
    coroutine.resume(coroutine.create(function() Mock.fireNet('AttackTransport:akceptujto', R) end))
    local ev = Mock.clientEventsNamed('AttackTransport:Pozwolwykonac')
    return ev[#ev] and ev[#ev].args[1]
end

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 100000
    Mock.players, Mock.coords, Inv = {}, {}, {}
    local p = Mock.newPlayer(R)
    p.PlayerData.money.bank = 100000
    Config.ActivePolice = 1
    Mock.newPlayer(COP).PlayerData.job = { name = 'police', type = 'leo', onduty = true }
end

describe('armored truck', function()
    it('the payout needs the truck, the player at it, and time', function()
        local spawn = accept()
        assert_true(spawn ~= nil)
        Mock.fireNet('AttackTransport:graczZrobilnapad', R, 20000)       -- right after accepting
        assert_eq(Inv.markedbills, nil)
        local s = Config.VehicleSpawn[spawn]
        Mock.coords[TRUCK] = vector3(s.x, s.y, s.z)
        Mock.fireNet('AttackTransport:truckSpawned', R, TRUCK)
        Mock.clock = Mock.clock + 120
        Mock.coords[R] = vector3(s.x + 500, s.y, s.z)                      -- far from the truck
        Mock.fireNet('AttackTransport:graczZrobilnapad', R, 20000)
        assert_eq(Inv.markedbills, nil)
        Mock.coords[R] = vector3(s.x + 2, s.y, s.z)
        Mock.fireNet('AttackTransport:graczZrobilnapad', R, 20000)
        assert_true((Inv.markedbills or 0) > 0)
    end)
    it('a truck reported away from the chosen spawn is ignored', function()
        local spawn = accept()
        local s = Config.VehicleSpawn[spawn]
        Mock.coords[TRUCK] = vector3(s.x + 1000, s.y, s.z)
        Mock.fireNet('AttackTransport:truckSpawned', R, TRUCK)
        Mock.clock = Mock.clock + 120
        Mock.coords[R] = Mock.coords[TRUCK]
        Mock.fireNet('AttackTransport:graczZrobilnapad', R, 20000)
        assert_eq(Inv.markedbills, nil)
    end)
end)
