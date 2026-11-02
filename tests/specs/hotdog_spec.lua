-- pfm-hotdogjob on the ledger: stand deposit charged and refunded once, each sale paid once; the
-- Hot Dog Stand app. (Cooking and selling are decided by the server: fix14_streetjobs_hotdog_spec.)
load_resource('tests/lua/ledger_env.lua')
-- FiveM's type() reports vectors as 'vector3'; the shared mock vectors are plain tables
local rawType, vecMeta = type, getmetatable(vector3(0, 0, 0))
function type(v) if rawType(v) == 'table' and getmetatable(v) == vecMeta then return 'vector3' end return rawType(v) end

-- pfm-minigames: every cook answered with no fault
Mock.exportsByResource['pfm-minigames'] = {
    IssueChallenge = function(_, src) return { id = 'CH' .. tostring(Mock.gameTimer), kind = 'keys', puzzle = {} } end,
    Verify = function() return true, 0, nil end,
    Cancel = function() return true end,
}
function IsPedAPlayer(ped) return Mock.players[ped] ~= nil end
LedgerEnv.load('pfm-hotdogjob', { 'pfm-hotdogjob/config.lua', 'pfm-hotdogjob/server/main.lua' })

local V, STAND, CUSTOMER = 1, 900, 901
local function cash() return Mock.players[V].PlayerData.money.cash end
local function bank() return Mock.players[V].PlayerData.money.bank end
local SPAWN = Config.Locations.spawn.coords

-- a stand out at the depot with `n` perfect hot dogs cooked, and a customer next to it
local function standWithDogs(n)
    assert_true(Mock.callCallback('qb-hotdogjob:server:HasMoney', V))
    Mock.models[STAND] = GetHashKey('prop_hotdogstand_01')
    Mock.coords[STAND] = vector3(SPAWN.x, SPAWN.y, SPAWN.z)
    Mock.coords[V] = vector3(SPAWN.x + 1.0, SPAWN.y, SPAWN.z)
    Mock.coords[CUSTOMER] = vector3(SPAWN.x + 2.0, SPAWN.y, SPAWN.z)
    Mock.fireNet('qb-hotdogjob:server:standPlaced', V, STAND)
    for _ = 1, n do
        local ch = Mock.callCallback('qb-hotdogjob:server:startCook', V)
        Mock.fireNet('qb-hotdogjob:server:finishCook', V, ch.id)
    end
end
local function sell()
    Mock.clock = Mock.clock + 10
    local offer = Mock.callCallback('qb-hotdogjob:server:offer', V, CUSTOMER)
    Mock.fireNet('qb-hotdogjob:server:Sell', V, CUSTOMER)
    return offer
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.clock = Mock.clock + 100000
    Mock.players, Mock.coords, Mock.models = {}, {}, {}
    local p = Mock.newPlayer(V)
    p.PlayerData.money = { cash = 0, bank = 1000 }
    p.PlayerData.metadata.rep = { hotdog = 0 }
    function p.GetRep(kind) return p.PlayerData.metadata.rep[kind] or 0 end
    function p.AddRep(kind, n) p.PlayerData.metadata.rep[kind] = (p.PlayerData.metadata.rep[kind] or 0) + n end
    Mock.fireEvent('playerDropped', V) -- no stand left from an earlier test
end

describe('hot dog stand', function()
    it('deposit, a sale and the refund all go through the ledger once', function()
        standWithDogs(3)
        assert_eq(bank(), 1000 - Config.StandDeposit)
        assert_true(Mock.callCallback('qb-hotdogjob:server:HasMoney', V))       -- second stand: not charged again
        assert_eq(bank(), 1000 - Config.StandDeposit)
        local offer = sell()
        assert_true(offer.amount >= 1)
        assert_eq(cash(), offer.total)
        assert_true(Mock.callCallback('qb-hotdogjob:server:BringBack', V))
        assert_eq(bank(), 1000)
        assert_false(Mock.callCallback('qb-hotdogjob:server:BringBack', V))
        assert_eq(bank(), 1000)
    end)
    it('when the bank is down a sale pays nothing and the hot dogs stay in stock', function()
        standWithDogs(3)
        PFLedger.ready = false
        sell()
        PFLedger.ready = true
        assert_eq(cash(), 0)
        local again = sell()
        assert_true(again ~= nil and again.amount >= 1, 'the stock is still there')
        assert_eq(cash(), again.total)
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
        assert_false(app.h.status(V).standOut)
        standWithDogs(3)
        local rep = Mock.players[V].PlayerData.metadata.rep.hotdog
        local offer = sell()
        local st = app.h.status(V)
        assert_true(st.standOut)
        assert_eq(st.sold, offer.amount)
        assert_eq(st.earned, offer.total)
        assert_eq(st.reputation, rep)
        assert_eq(st.stock.exotic, 3 - offer.amount)
        assert_eq(pushes[#pushes].id, 'hotdogstand')
        assert_eq(pushes[#pushes].payload.sold, offer.amount)
        assert_true(app.h.waypoint(V).ok)
        GetResourceState = realState
    end)
end)
