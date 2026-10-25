-- pfm-pawnshop: a sale or melt pickup from too far away is refused and logged, never a ban.
load_resource('tests/lua/ledger_env.lua')
LedgerEnv.load('pfm-pawnshop', { 'pfm-pawnshop/config.lua', 'pfm-pawnshop/server/main.lua' })
local bans = 0
FakeDB.extraPatterns = FakeDB.extraPatterns or {}
table.insert(FakeDB.extraPatterns, 1, { 'INSERT INTO bans', function() bans = bans + 1 return 1 end })

local P = 1
BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.gameTimer = Mock.gameTimer + 60000
    Mock.players, Mock.coords = {}, {}
    Mock.newPlayer(P)
    Mock.coords[P] = vector3(-5000.0, -5000.0, 0.0)
    bans = 0
end

describe('pawnshop requests from too far away', function()
    it('are refused and nobody is banned or dropped', function()
        Mock.fireNet('qb-pawnshop:server:sellPawnItems', P, 'goldchain', 1, 999)
        Mock.gameTimer = Mock.gameTimer + 5000
        Mock.fireNet('qb-pawnshop:server:pickupMelted', P, { item = 'goldbar' })
        assert_eq(bans, 0)
        assert_eq(#Mock.dropped, 0)
        assert_eq(#LedgerEnv.paid(''), 0, 'nothing paid')
    end)
end)
