-- pf-jobs Gruppe 6 (server/apps/gruppe6.lua), 'pf-jobs:gruppe6:depositComplete':
--   * two requests at once (a double click, two progress bars) used to both pass the `finished`
--     check before the payout yielded; the second one's payout came back as a duplicate of the
--     first and the contract XP was added again. The contract is now locked before the first yield;
--   * the lock is released afterwards, so a deposit that could not finish can be tried again;
--   * bags the inventory refused to take are not counted as deposited.
load_resource('tests/lua/ledger_env.lua')
QBCore = QBCoreMock
QBCoreMock.Shared.Items.moneybag = { name = 'moneybag', label = 'Money Bag', weight = 0 }
Citizen = Citizen or {}
Citizen.SetTimeout = function() return 1 end
Citizen.ClearTimeout = function() end
SetTimeout = function(_, fn) fn() end
function CreateVehicleServerSetter() Mock.nextNetId = Mock.nextNetId + 1; return Mock.nextNetId end
function SetVehicleNumberPlateText() end
function SetVehicleDoorsLocked() end
Mock.exportsByResource['pfm-inventory'] = {
    GetInventory = function() return nil end, CreateInventory = function() end, SetInventory = function() end,
    OpenInventory = function() end, RemoveInventory = function() end,
}

LedgerEnv.load('pf-jobs', { '[pfscripts]/pf-jobs/config.lua', '[pfscripts]/pf-jobs/server/apps/gruppe6.lua' })
local G6 = Config.Gruppe6
G6.UseDatabase = false
G6.ServerSideStash = true
G6.MoneyBagsPerLocationMin, G6.MoneyBagsPerLocationMax = 2, 2
G6.Debug = false

-- The payout yields (as the ledger's MySQL.*.await calls do on a server) when run in a coroutine,
-- so a second request can arrive while the first one is being paid.
local realPay = PFPayout.Pay
PFPayout.Pay = function(...)
    if coroutine.isyieldable() then coroutine.yield('paying') end
    return realPay(...)
end

local GUARD = 1
local carried, removeWorks = {}, true
local function newGuard(src)
    local p = Mock.newPlayer(src)
    p.PlayerData.job = { name = 'unemployed', onduty = true }
    carried[src] = 0
    p.Functions.GetItemByName = function(name) if name == 'moneybag' and carried[src] > 0 then return { name = name, amount = carried[src] } end end
    p.Functions.RemoveItem = function(name, n)
        if not removeWorks then return false end
        if name == 'moneybag' then carried[src] = carried[src] - n end
        return true
    end
    p.Functions.AddItem = function(name, n) if name == 'moneybag' then carried[src] = carried[src] + n end return true end
    return p
end

-- takes a contract and collects every bag, then stands at the vault
local function collectAll(src)
    Mock.fireNet('pf-jobs:gruppe6:startSearch', src)
    Mock.fireNet('pf-jobs:gruppe6:acceptContract', src, { contractId = 0 })
    local starts = Mock.clientEventsNamed('pf-jobs:gruppe6:startContract')
    local data = starts[#starts].args[1]
    for n, loc in ipairs(data.pickupSequence) do
        Mock.fireNet('pf-jobs:gruppe6:openPickupStash', src, loc, n)
        for _ = 1, data.locationBags[n] do Mock.fireNet('pf-jobs:gruppe6:takePickupBag', src, loc, n) end
    end
    local d = G6.DepositLocation
    Mock.coords[src] = vector3(d.x, d.y, d.z)
    return data
end

local function deposit(src)
    local co = coroutine.create(function() Mock.fireNet('pf-jobs:gruppe6:depositComplete', src) end)
    local ok, err = coroutine.resume(co)
    assert(ok, err)
    return co
end
local function finish(co)
    while coroutine.status(co) == 'suspended' do
        local ok, err = coroutine.resume(co)
        assert(ok, err)
    end
end
local function xpEvents(src)
    local n = 0
    for _, e in ipairs(Mock.clientEventsNamed('pf-jobs:gruppe6:updateXP')) do
        if e.target == src then n = n + 1 end
    end
    return n
end
local function paid() return LedgerEnv.paid('pf-jobs:gruppe6:') end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players, Mock.coords = {}, {}
    removeWorks = true
    Mock.fireEvent('playerDropped', GUARD)
    newGuard(GUARD)
end

describe('Gruppe 6 deposit at the vault', function()
    it('two deposit requests at once pay the contract and add its XP once', function()
        local data = collectAll(GUARD)
        local total = 0
        for _, c in ipairs(data.locationBags) do total = total + c end
        assert_eq(carried[GUARD], total, 'every bag collected')

        local first = deposit(GUARD)
        assert_eq(coroutine.status(first), 'suspended', 'first request is being paid')
        local second = deposit(GUARD)   -- arrives while the first one waits on the ledger
        finish(first)
        local xpAfterFirst = Mock.players[GUARD].PlayerData.metadata.gruppe6_xp
        finish(second)

        assert_eq(carried[GUARD], 0, 'bags handed in')
        assert_eq(#paid(), 1, 'one payout')
        assert_true((xpAfterFirst or 0) > 0, 'the contract gives XP')
        assert_eq(xpEvents(GUARD), 1, 'XP added once')
        assert_eq(Mock.players[GUARD].PlayerData.metadata.gruppe6_xp, xpAfterFirst, 'XP not added again')
    end)

    it('a deposit that could not take the bags credits nothing, and the next one goes through', function()
        collectAll(GUARD)
        local bags = carried[GUARD]
        removeWorks = false
        finish(deposit(GUARD))
        assert_eq(carried[GUARD], bags, 'bags still carried')
        assert_eq(#paid(), 0, 'nothing paid for bags not handed in')
        assert_eq(xpEvents(GUARD), 0)

        removeWorks = true
        finish(deposit(GUARD))   -- not left locked by the refused attempt
        assert_eq(carried[GUARD], 0)
        assert_eq(#paid(), 1)
        assert_eq(xpEvents(GUARD), 1)
        finish(deposit(GUARD))   -- the contract is over
        assert_eq(#paid(), 1)
        assert_eq(xpEvents(GUARD), 1)
    end)
end)
