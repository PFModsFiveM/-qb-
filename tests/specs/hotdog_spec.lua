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

describe('Hot Dog Stand app', function()
    local app, pushes = {}, {}
    local realState = GetResourceState
    it('shows the shift, reputation and the stand state for the hotdog job, and is pushed on sales', function()
        GetResourceState = function(name) if name == 'pf-devices' then return 'started' end return realState(name) end
        Mock.exportsByResource['pf-devices'] = {
            RegisterApp = function(_, def) app.def = def return true end,
            RegisterAppHandlers = function(_, id, map) app.h = map return true end,
            Push = function(_, src, id, event, payload) pushes[#pushes + 1] = { src = src, id = id, event = event, payload = payload } return true end,
        }
        Mock.eventHandlers['pf-devices:server:ready']()
        assert_eq(app.def.id, 'hotdogstand')
        assert_eq(app.def.access.jobs.hotdog, 0)
        Mock.players[V].GetRep = function() return 40 end
        Mock.fireEvent('playerDropped', V)   -- clear the stand an earlier test left out
        assert_false(app.h.status(V).standOut)
        assert_true(Mock.callCallback('qb-hotdogjob:server:HasMoney', V))
        Mock.fireNet('qb-hotdogjob:server:Sell', V, vector3(1.0, 0.0, 0.0), 2, 5)
        local st = app.h.status(V)
        assert_true(st.standOut)
        assert_eq(st.sold, 2)
        assert_true(st.earned > 0)
        assert_eq(st.reputation, 40)
        assert_eq(pushes[1].id, 'hotdogstand')
        assert_eq(pushes[1].payload.sold, 2)
        assert_true(app.h.waypoint(V).ok)
        GetResourceState = realState
    end)
end)
