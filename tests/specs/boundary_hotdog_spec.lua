-- pfm-hotdogjob reputation: the player it gets from exports['pfm-core']:GetPlayer is a copy taken
-- before AddRep, so the reputation sent to the client after a cook must be read again (it showed
-- the old value). Reputation comes only from a hot dog the server cooked (no free event any more).
load_resource('tests/lua/ledger_env.lua')
local rawType, vecMeta = type, getmetatable(vector3(0, 0, 0))
function type(v) if rawType(v) == 'table' and getmetatable(v) == vecMeta then return 'vector3' end return rawType(v) end
Mock.exportsByResource['pfm-minigames'] = {
    IssueChallenge = function() return { id = 'CH1', kind = 'keys', puzzle = {} } end,
    Verify = function() return true, 0, nil end,
    Cancel = function() return true end,
}
function IsPedAPlayer(ped) return Mock.players[ped] ~= nil end
LedgerEnv.load('pfm-hotdogjob', { 'pfm-hotdogjob/config.lua', 'pfm-hotdogjob/server/main.lua' })

local V, STAND = 1, 900
local realTime = os.time
local now = realTime()
os.time = function(t) if t then return realTime(t) end return now end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players, Mock.coords, Mock.models = {}, {}, {}
    local p = Mock.newPlayer(V)
    p.PlayerData.money = { cash = 0, bank = 1000 }
    p.PlayerData.metadata.rep = { hotdog = 10 }
    function p.GetRep(kind) return p.PlayerData.metadata.rep[kind] or 0 end
    function p.AddRep(kind, n) p.PlayerData.metadata.rep[kind] = (p.PlayerData.metadata.rep[kind] or 0) + n end
    local spawn = Config.Locations.spawn.coords
    Mock.coords[V] = vector3(spawn.x, spawn.y, spawn.z)
    Mock.coords[STAND] = vector3(spawn.x + 1.0, spawn.y, spawn.z)
    Mock.models[STAND] = GetHashKey('prop_hotdogstand_01')
end

describe('hot dog reputation', function()
    it('the client is sent the reputation after the gain', function()
        assert_true(Mock.callCallback('qb-hotdogjob:server:HasMoney', V), 'stand session started')
        Mock.fireNet('qb-hotdogjob:server:standPlaced', V, STAND)
        Mock.clientEvents = {}
        local ch = Mock.callCallback('qb-hotdogjob:server:startCook', V)
        Mock.fireNet('qb-hotdogjob:server:finishCook', V, ch.id)
        assert_eq(Mock.players[V].PlayerData.metadata.rep.hotdog, 13)
        local sent = Mock.clientEventsNamed('qb-hotdogjob:client:UpdateReputation')
        assert_eq(#sent, 1)
        assert_eq(sent[1].args[1].hotdog, 13, 'not the value from before the gain')
    end)
end)
