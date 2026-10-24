-- pfm-hotdogjob on the ledger: stand deposit charged and refunded once, each sale paid once.
load_resource('tests/lua/ledger_env.lua')
-- FiveM's type() reports vectors as 'vector3'; the shared mock vectors are plain tables
local rawType, vecMeta = type, getmetatable(vector3(0, 0, 0))
function type(v) if rawType(v) == 'table' and getmetatable(v) == vecMeta then return 'vector3' end return rawType(v) end
LedgerEnv.load('pfm-hotdogjob', { 'pfm-hotdogjob/config.lua', 'pfm-hotdogjob/server/main.lua' })

local V = 1
local dogs
local function cash() return Mock.players[V].PlayerData.money.cash end
local function bank() return Mock.players[V].PlayerData.money.bank end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.clock = Mock.clock + 1000
    Mock.players, Mock.coords = {}, {}
    local p = Mock.newPlayer(V)
    p.PlayerData.money = { cash = 0, bank = 1000 }
    dogs = 10
    p.Functions.GetItemByName = function(item) if item == 'hotdog' then return { name = 'hotdog', amount = dogs } end end
    p.Functions.RemoveItem = function(_, n) if dogs < n then return false end dogs = dogs - n return true end
    p.Functions.AddItem = function(_, n) dogs = dogs + n return true end
    Mock.coords[V] = vector3(0.0, 0.0, 0.0)
end

describe('hot dog stand', function()
    it('deposit, a sale and the refund all go through the ledger once', function()
        assert_true(Mock.callCallback('qb-hotdogjob:server:HasMoney', V))
        assert_eq(bank(), 1000 - Config.StandDeposit)
        assert_true(Mock.callCallback('qb-hotdogjob:server:HasMoney', V))       -- second stand: not charged again
        assert_eq(bank(), 1000 - Config.StandDeposit)
        Mock.fireNet('qb-hotdogjob:server:Sell', V, vector3(1.0, 0.0, 0.0), 2, 5)
        assert_true(cash() > 0)
        assert_eq(dogs, 8)
        assert_true(Mock.callCallback('qb-hotdogjob:server:BringBack', V))
        assert_eq(bank(), 1000)
        assert_false(Mock.callCallback('qb-hotdogjob:server:BringBack', V))
        assert_eq(bank(), 1000)
    end)
    it('when the bank is down a sale pays nothing and the hot dogs come back', function()
        assert_true(Mock.callCallback('qb-hotdogjob:server:HasMoney', V))
        PFLedger.ready = false
        Mock.fireNet('qb-hotdogjob:server:Sell', V, vector3(1.0, 0.0, 0.0), 2, 5)
        PFLedger.ready = true
        assert_eq(cash(), 0)
        assert_eq(dogs, 10)
    end)
end)
