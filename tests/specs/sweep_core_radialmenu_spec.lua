-- pfm-radialmenu: only a cuffed, dead or downed player can be put in a trunk, and stretchers are
-- cleared around the player who removes one.
load_resource('tests/lua/fivem_mocks.lua')
function DoesPlayerExist(id) return Mock.players[tonumber(id)] ~= nil end
load_resource('pfm-radialmenu/server/trunk.lua')
load_resource('pfm-radialmenu/server/stretcher.lua')

local A, B = 1, 2

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    Mock.newPlayer(A)
    Mock.newPlayer(B)
    Mock.coords = { [A] = vector3(0, 0, 0), [B] = vector3(1, 0, 0) }
end

describe('KidnapTrunk', function()
    it('a free, healthy player is not forced into a trunk', function()
        Mock.fireNet('qb-trunk:server:KidnapTrunk', A, B, 77)
        assert_eq(#Mock.clientEventsNamed('qb-trunk:client:KidnapGetIn'), 0)
    end)
    it('a cuffed player is', function()
        Mock.players[B].PlayerData.metadata.ishandcuffed = true
        Mock.fireNet('qb-trunk:server:KidnapTrunk', A, B, 77)
        local ev = Mock.clientEventsNamed('qb-trunk:client:KidnapGetIn')
        assert_eq(#ev, 1)
        assert_eq(ev[1].target, B)
    end)
    it('a bad target id is ignored', function()
        Mock.fireNet('qb-trunk:server:KidnapTrunk', A, 'x', 77)
        Mock.fireNet('qb-trunk:server:KidnapTrunk', A, A, 77)
        assert_eq(#Mock.clientEventsNamed('qb-trunk:client:KidnapGetIn'), 0)
    end)
end)

describe('RemoveStretcher', function()
    it("the area cleared is around the sender, not a position the client sends", function()
        Mock.coords[A] = vector3(50, 50, 0)
        Mock.fireNet('qb-radialmenu:server:RemoveStretcher', A, vector3(-1000, 2000, 0), 5)
        local ev = Mock.clientEventsNamed('qb-radialmenu:client:RemoveStretcherFromArea')
        assert_eq(#ev, 1)
        assert_eq(ev[1].args[1].x, 50)
    end)
end)
