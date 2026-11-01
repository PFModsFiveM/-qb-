-- pfm-hotdogjob reputation: the player it gets from exports['pfm-core']:GetPlayer is a copy taken
-- before AddRep, so the reputation sent to the client must be read again (it showed the old value).
load_resource('tests/lua/ledger_env.lua')
local rawType, vecMeta = type, getmetatable(vector3(0, 0, 0))
function type(v) if rawType(v) == 'table' and getmetatable(v) == vecMeta then return 'vector3' end return rawType(v) end
LedgerEnv.load('pfm-hotdogjob', { 'pfm-hotdogjob/config.lua', 'pfm-hotdogjob/server/main.lua' })

local V = 1
local realTime = os.time
local now = realTime()
os.time = function(t) if t then return realTime(t) end return now end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players, Mock.coords = {}, {}
    local p = Mock.newPlayer(V)
    p.PlayerData.money = { cash = 0, bank = 1000 }
    p.PlayerData.metadata.rep = { hotdog = 10 }
    function p.GetRep(kind) return p.PlayerData.metadata.rep[kind] or 0 end
    function p.AddRep(kind, n) p.PlayerData.metadata.rep[kind] = (p.PlayerData.metadata.rep[kind] or 0) + n end
    Mock.coords[V] = vector3(0.0, 0.0, 0.0)
end

describe('hot dog reputation', function()
    it('the client is sent the reputation after the gain', function()
        assert_true(Mock.callCallback('qb-hotdogjob:server:HasMoney', V), 'stand session started')
        Mock.clientEvents = {}
        Mock.fireNet('qb-hotdogjob:server:UpdateReputation', V, 'exotic')
        assert_eq(Mock.players[V].PlayerData.metadata.rep.hotdog, 13)
        local sent = Mock.clientEventsNamed('qb-hotdogjob:client:UpdateReputation')
        assert_eq(#sent, 1)
        assert_eq(sent[1].args[1].hotdog, 13, 'not the value from before the gain')
    end)
end)
