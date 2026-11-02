-- Batch 14 (hotdog-client-price-quality, hotdog-deposit-race, ledger-unclear-handback):
--  * the price, amount and quality of a sale are the server's: a sale names only a customer ped the
--    server checks (exists, not a player, close, not served lately); the old Sell(coords, amount,
--    price) let any client sell any hot dog at the top price;
--  * a hot dog is cooked through a server-judged challenge: the server's fault count sets the
--    quality, the stock is the server's, capped by the level from the server's reputation, and the
--    reputation is given only for a hot dog made (the free UpdateReputation event is gone);
--  * the deposit lock is taken before the ledger wait: two callbacks at once charge once;
--  * an unclear sale payment keeps the hot dogs sold and is paid later under the same key.
load_resource('tests/lua/ledger_env.lua')
local rawType, vecMeta = type, getmetatable(vector3(0, 0, 0))
function type(v) if rawType(v) == 'table' and getmetatable(v) == vecMeta then return 'vector3' end return rawType(v) end

-- pfm-minigames: the verdict the next Verify gives
local verdict = { passed = true, faults = 0 }
local issued = {}
Mock.exportsByResource['pfm-minigames'] = {
    IssueChallenge = function(_, src, kind, opts)
        local id = 'CH' .. (#issued + 1)
        issued[#issued + 1] = { id = id, src = src, kind = kind, opts = opts }
        return { id = id, kind = kind, puzzle = { amount = opts.amount } }
    end,
    Verify = function(_, src, id)
        for _, c in ipairs(issued) do if c.id == id and c.src == src and not c.used then c.used = true return verdict.passed, verdict.faults end end
        return false, 0, 'unknown'
    end,
    Cancel = function() return true end,
}
function IsPedAPlayer(ped) return Mock.players[ped] ~= nil end
LedgerEnv.load('pfm-hotdogjob', { 'pfm-hotdogjob/config.lua', 'pfm-hotdogjob/server/main.lua' })

local V, OTHER, STAND, C1, C2 = 1, 2, 900, 901, 902
local SPAWN = Config.Locations.spawn.coords
local bankExports = Mock.exportsByResource['pfm-banking']
local realTransfer = bankExports.Transfer

local function cash() return Mock.players[V].PlayerData.money.cash end
local function bank() return Mock.players[V].PlayerData.money.bank end
local function rep() return Mock.players[V].PlayerData.metadata.rep.hotdog end
local function near(dx) return vector3(SPAWN.x + dx, SPAWN.y, SPAWN.z) end
local function takeStand()
    assert_true(Mock.callCallback('qb-hotdogjob:server:HasMoney', V), 'deposit paid')
    Mock.fireNet('qb-hotdogjob:server:standPlaced', V, STAND)
end
local function cook(faults, passed)
    verdict.faults, verdict.passed = faults or 0, passed ~= false
    Mock.clock = Mock.clock + 20
    local ch, why = Mock.callCallback('qb-hotdogjob:server:startCook', V)
    if not ch then return nil, why end
    Mock.fireNet('qb-hotdogjob:server:finishCook', V, ch.id)
    return ch
end
local function lastStock()
    local ev = Mock.clientEventsNamed('qb-hotdogjob:client:UpdateStock')
    return ev[#ev] and ev[#ev].args[1] or {}
end
local function offer(customer)
    Mock.clock = Mock.clock + 10
    return Mock.callCallback('qb-hotdogjob:server:offer', V, customer or C1)
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    bankExports.Transfer = realTransfer
    Mock.clock = Mock.clock + 100000
    Mock.players, Mock.coords, Mock.models = {}, {}, {}
    issued, verdict = {}, { passed = true, faults = 0 }
    for _, src in ipairs({ V, OTHER }) do
        local p = Mock.newPlayer(src)
        p.PlayerData.money = { cash = 0, bank = 1000 }
        p.PlayerData.metadata.rep = { hotdog = 0 }
        function p.GetRep(kind) return p.PlayerData.metadata.rep[kind] or 0 end
        function p.AddRep(kind, n) p.PlayerData.metadata.rep[kind] = (p.PlayerData.metadata.rep[kind] or 0) + n end
        Mock.fireEvent('playerDropped', src)
    end
    Mock.models[STAND] = GetHashKey('prop_hotdogstand_01')
    Mock.coords[STAND] = near(0.0)
    Mock.coords[V] = near(1.0)
    Mock.coords[OTHER] = near(2.0)
    Mock.coords[C1] = near(2.5)
    Mock.coords[C2] = near(-2.0)
end

describe('fix14 hot dogs: the server decides the sale', function()
    it('the old client-priced sale pays nothing', function()
        takeStand()
        cook(0)
        Mock.fireNet('qb-hotdogjob:server:Sell', V, vector3(0, 0, 0), 3, 15)
        Mock.fireNet('qb-hotdogjob:server:Sell', V, C1, 3, 15)
        assert_eq(cash(), 0, 'no offer was made: nothing sold')
    end)

    it('the price comes from the band of the level the server reads from the reputation', function()
        takeStand()
        for _ = 1, 3 do cook(0) end
        local o = offer()
        assert_eq(o.quality, 'exotic')
        local band = Config.Stock.exotic.Price[1]
        assert_true(o.total >= band.min * o.amount and o.total <= band.max * o.amount, 'a level-1 price')
        Mock.fireNet('qb-hotdogjob:server:Sell', V, C1)
        assert_eq(cash(), o.total)
        -- at 200 reputation the level-4 band applies
        Mock.players[V].PlayerData.metadata.rep.hotdog = 200
        local o2 = offer(C2)
        local top = Config.Stock.exotic.Price[4]
        assert_true(o2.total >= top.min * o2.amount, 'a level-4 price')
    end)

    it('a customer must be a nearby NPC, served once in a while', function()
        takeStand()
        for _ = 1, 6 do cook(0) end
        assert_eq(offer(OTHER), nil, 'another player is no customer')
        Mock.coords[C2] = near(30.0)
        assert_eq(offer(C2), nil, 'a far ped is no customer')
        local o = offer(C1)
        Mock.fireNet('qb-hotdogjob:server:Sell', V, C1)
        assert_eq(cash(), o.total)
        assert_eq(offer(C1), nil, 'the same customer does not buy again at once')
    end)

    it('a sale names the customer of its offer, within its time', function()
        takeStand()
        cook(0)
        offer(C1)
        Mock.fireNet('qb-hotdogjob:server:Sell', V, C2)
        assert_eq(cash(), 0, 'not the customer of the offer')
        local o = offer(C1)
        Mock.clock = Mock.clock + 600
        Mock.fireNet('qb-hotdogjob:server:Sell', V, C1)
        assert_eq(cash(), 0, 'the offer ran out')
        assert_true(o ~= nil)
    end)

    it('with nothing in stock there is nothing to offer', function()
        takeStand()
        local o = offer()
        assert_true(o.empty)
    end)
end)

describe('fix14 hot dogs: the server decides the cook', function()
    it('the free reputation event is gone', function()
        assert_eq(Mock.netHandlers['qb-hotdogjob:server:UpdateReputation'], nil)
    end)

    it('the quality follows the server fault count, and reputation comes with a hot dog made', function()
        takeStand()
        cook(0)
        assert_eq(lastStock().exotic, 1)
        assert_eq(rep(), 3)
        cook(1)
        assert_eq(lastStock().rare, 1)
        assert_eq(rep(), 5)
        cook(4)
        assert_eq(lastStock().common, 1)
        assert_eq(rep(), 6)
        cook(0, false) -- quit / too fast / expired
        assert_eq(lastStock().exotic, 1, 'a failed challenge makes nothing')
        assert_eq(rep(), 6)
    end)

    it('a finish without a matching cook makes nothing', function()
        takeStand()
        Mock.fireNet('qb-hotdogjob:server:finishCook', V, 'CH-MADE-UP')
        local ch = Mock.callCallback('qb-hotdogjob:server:startCook', V)
        Mock.fireNet('qb-hotdogjob:server:finishCook', V, 'CH-OTHER')
        assert_eq(rep(), 0)
        assert_eq(#Mock.clientEventsNamed('qb-hotdogjob:client:UpdateStock'), 0)
        Mock.fireNet('qb-hotdogjob:server:finishCook', V, ch.id) -- its own id still counts, once
        Mock.fireNet('qb-hotdogjob:server:finishCook', V, ch.id)
        assert_eq(rep(), 3)
        assert_eq(lastStock().exotic, 1)
    end)

    it('cooking happens only at the registered stand', function()
        assert_true(Mock.callCallback('qb-hotdogjob:server:HasMoney', V))
        assert_eq(select(2, cook(0)), 'too_far', 'no stand registered yet')
        Mock.models[903] = GetHashKey('prop_bench_01a')
        Mock.coords[903] = near(0.5)
        Mock.fireNet('qb-hotdogjob:server:standPlaced', V, 903)
        assert_eq(select(2, cook(0)), 'too_far', 'not a hot dog stand')
        Mock.fireNet('qb-hotdogjob:server:standPlaced', V, STAND)
        Mock.coords[V] = near(10.0)
        assert_eq(select(2, cook(0)), 'too_far', 'away from the stand')
        Mock.coords[V] = near(1.0)
        assert_true(cook(0) ~= nil)
    end)

    it('the stock is capped by the level', function()
        takeStand()
        local cap = Config.Stock.exotic.Max[1]
        for _ = 1, cap do cook(0) end
        Mock.players[V].PlayerData.metadata.rep.hotdog = 0 -- stay at level 1
        cook(0)
        assert_eq(lastStock().exotic, cap)
    end)
end)

describe('fix14 hot dogs: deposit and payments', function()
    it('two deposit callbacks at once charge once', function()
        local second
        bankExports.Transfer = function(self, opts)
            if second == nil then second = Mock.callCallback('qb-hotdogjob:server:HasMoney', V) end
            return realTransfer(opts) -- the ledger's own export takes no self
        end
        local first = Mock.callCallback('qb-hotdogjob:server:HasMoney', V)
        bankExports.Transfer = realTransfer
        assert_true(first)
        assert_false(second, 'the second found the first in progress')
        assert_eq(bank(), 1000 - Config.StandDeposit)
        assert_eq(#LedgerEnv.paid('pfm-hotdogjob:stand:'), 1)
    end)

    it('an unclear deposit is asked again under its key, never charged twice', function()
        local keys = {}
        bankExports.Transfer = function(_, opts)
            keys[#keys + 1] = opts.key
            return { ok = false, state = 'pending', txId = 'TXD', error = 'pending' }
        end
        assert_false(Mock.callCallback('qb-hotdogjob:server:HasMoney', V))
        bankExports.Transfer = function(_, opts) keys[#keys + 1] = opts.key return { ok = false, error = 'ledger_unavailable' } end
        assert_false(Mock.callCallback('qb-hotdogjob:server:HasMoney', V))
        bankExports.Transfer = realTransfer
        assert_true(Mock.callCallback('qb-hotdogjob:server:HasMoney', V))
        assert_eq(keys[2], keys[1])
        assert_eq(LedgerEnv.paid('pfm-hotdogjob:stand:')[1].idempotency_key, keys[1], 'one deposit, under the first key')
        assert_eq(bank(), 1000 - Config.StandDeposit)
    end)

    it('an unclear sale payment keeps the hot dogs sold and pays later under the same key', function()
        takeStand()
        for _ = 1, 3 do cook(0) end
        local o = offer(C1)
        local key
        bankExports.Transfer = function(_, opts)
            key = opts.key
            return { ok = false, state = 'debited', txId = 'TXS', error = 'credit_failed' }
        end
        Mock.fireNet('qb-hotdogjob:server:Sell', V, C1)
        bankExports.Transfer = realTransfer
        assert_eq(cash(), 0)
        assert_eq(lastStock().exotic, 3 - o.amount, 'not put back in stock')
        offer(C2) -- the next offer settles the waiting payment
        assert_eq(cash(), o.total)
        assert_eq(#LedgerEnv.paid(key), 1)
    end)
end)
