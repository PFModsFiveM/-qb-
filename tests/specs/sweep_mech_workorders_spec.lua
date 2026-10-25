-- pf-mechanicjob work orders (server/work_orders.lua): an order pays a mechanic who has had it for a
-- while and used the part it needs; accepting and completing straight away pays nothing.
load_resource('tests/lua/ledger_env.lua')

-- the stubs the shared mocks lack
MySQL.Sync = { fetchAll = function(q, p) return MySQL.query.await(q, p) end }
MySQL.Async = {
    insert = function(q, p) return MySQL.insert.await(q, p) end,
    execute = function(q, p, cb) local r = MySQL.update.await(q, p); if cb then cb(r) end; return r end,
}
FakeDB.extraPatterns = {
    { 'pf_mechanic_progress', function() return {} end },
    { 'pf_mech_profiles', function() return {} end },
    { 'INSERT INTO pf_work_orders', function() return 1 end },
}
-- the search thread runs one round: Wait lets `waitBudget` calls through, then stops the thread
local waitBudget = 0
Wait = function() if waitBudget <= 0 then error('stop thread') end; waitBudget = waitBudget - 1 end
CreateThread = function(fn) pcall(fn) end
local stateMeta = { __index = { set = function(self, k, v) rawset(self, k, v) end } }
local states = {}
function Entity(e)
    states[e] = states[e] or { state = setmetatable({}, stateMeta) }
    return states[e]
end

LedgerEnv.load('pf-mechanicjob', {
    '[pfscripts]/pf-mechanicjob/config.lua',
    '[pfscripts]/pf-mechanicjob/shared/debug.lua',
})
Config.Debug = false
load_resource('[pfscripts]/pf-mechanicjob/server/main.lua')
load_resource('[pfscripts]/pf-mechanicjob/server/work_orders.lua')

local function withInventory(p, items)
    p.inv = items or {}
    p.Functions.GetItemByName = function(name)
        local n = p.inv[name]
        if n and n > 0 then return { name = name, amount = n, label = name } end
    end
    p.Functions.RemoveItem = function(name, n)
        n = n or 1
        if (p.inv[name] or 0) < n then return false end
        p.inv[name] = p.inv[name] - n
        return true
    end
    p.Functions.AddItem = function(name, n) p.inv[name] = (p.inv[name] or 0) + (n or 1) return true end
    return p
end

local MECH, CIV = 1, 2
local cidSeq = 0
local function bank(src) return Mock.players[src].PlayerData.money.bank end

-- start searching, let one offer appear, accept it; returns the accepted order
local function takeOrder(src)
    Mock.callCallback('pf_mech:workorders:startSearch', src)
    local data = Mock.callCallback('pf_mech:workorders:getData', src)
    local offer = data.availableOrders[1]
    assert_true(offer ~= nil)
    local res = Mock.callCallback('pf_mech:workorders:accept', src, offer.id)
    assert_true(res.success)
    return res.order
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players = {}
    Mock.clock = Mock.clock + 100000
    cidSeq = cidSeq + 1
    withInventory(Mock.newPlayer(MECH, 'MECH' .. cidSeq)).PlayerData.job = { name = 'mechanic', onduty = true, grade = { level = 0 } }
    withInventory(Mock.newPlayer(CIV, 'CIV' .. cidSeq)).PlayerData.job = { name = 'unemployed' }
    waitBudget = 1
end

describe('work orders', function()
    it('accept-and-complete straight away pays nothing', function()
        local order = takeOrder(MECH)
        Mock.players[MECH].inv[order.requiredItem] = 1
        local res = Mock.callCallback('pf_mech:workorders:complete', MECH, order.id)
        Mock.fireNet('pf_mech:workorders:completeRepair', MECH, order.id, order.requiredItem)
        assert_eq(res.success, false)
        assert_eq(bank(MECH), 0)
    end)
    it('a player who is not a mechanic is never paid', function()
        local order = takeOrder(CIV)
        Mock.players[CIV].inv[order.requiredItem] = 1
        Mock.clock = Mock.clock + 600
        Mock.fireNet('pf_mech:workorders:completeRepair', CIV, order.id, order.requiredItem)
        Mock.callCallback('pf_mech:workorders:complete', CIV, order.id)
        assert_eq(bank(CIV), 0)
    end)
    it('the part the order needs is required (not whatever item the client names)', function()
        local order = takeOrder(MECH)
        Mock.players[MECH].inv.sandwich = 1
        Mock.clock = Mock.clock + 600
        Mock.fireNet('pf_mech:workorders:completeRepair', MECH, order.id, 'sandwich')
        assert_eq(bank(MECH), 0)
        assert_eq(Mock.players[MECH].inv.sandwich, 1)
    end)
    it('pays once when the work is done, taking the part', function()
        local order = takeOrder(MECH)
        Mock.players[MECH].inv[order.requiredItem] = 2
        Mock.clock = Mock.clock + 600
        Mock.fireNet('pf_mech:workorders:completeRepair', MECH, order.id, order.requiredItem)
        local paid = bank(MECH)
        assert_true(paid > 0)
        assert_eq(Mock.players[MECH].inv[order.requiredItem], 1)
        Mock.fireNet('pf_mech:workorders:completeRepair', MECH, order.id, order.requiredItem)
        assert_eq(bank(MECH), paid)
        assert_eq(#LedgerEnv.paid('pf-mechanicjob:workorder:'), 1)
    end)
    it('a part spent on the repair through the diagnostics menu counts', function()
        local order = takeOrder(MECH)
        Mock.players[MECH].inv[order.requiredItem] = 1
        Mock.clock = Mock.clock + 600
        local partKey = order.requiredItem == 'brake_pads' and 'brakes' or order.requiredItem
        local ok = Mock.callCallback('pf_mech:server:attemptRepair', MECH, 777, partKey, 1)
        assert_true(ok)
        assert_eq(Mock.players[MECH].inv[order.requiredItem], 0)
        local res = Mock.callCallback('pf_mech:workorders:complete', MECH, order.id)
        assert_true(res.success)
        assert_true(bank(MECH) > 0)
    end)
end)
