-- pf-jobs Gruppe6: bags taken out of a pickup stash are counted from pfm-inventory's own move event
-- (fromInventory, toInventory, ... with the mover as source), and only for the player whose pickup
-- that stash is.
load_resource('tests/lua/ledger_env.lua')
QBCore = QBCoreMock
QBCoreMock.Shared.Items = QBCoreMock.Shared.Items or {}
QBCoreMock.Shared.Items.moneybag = { name = 'moneybag', label = 'Money Bag', weight = 1000 }
Citizen = Citizen or {}
Citizen.SetTimeout = function() return 1 end
Citizen.ClearTimeout = function() end
SetTimeout = function(_, fn) fn() end           -- the recount runs at once in tests

local stashes = {}    -- [id] = { items = {...} }
Mock.exportsByResource['pfm-inventory'] = {
    GetInventory = function(_, id) return stashes[id] end,
    CreateInventory = function(_, id) stashes[id] = stashes[id] or { items = {} } end,
    SetInventory = function(_, id, items) stashes[id] = { items = items } end,
    OpenInventory = function() end,
    RemoveInventory = function(_, id) stashes[id] = nil end,
}

-- loaded fresh for every test: the script keeps bag counts per stash and contracts per player
local function loadGruppe6()
    LedgerEnv.load('pf-jobs', { '[pfscripts]/pf-jobs/config.lua', '[pfscripts]/pf-jobs/server/apps/gruppe6.lua' })
    Config.Gruppe6.ServerSideStash = false
    Config.Gruppe6.UseDatabase = false -- XP and history are not what these tests are about
    Config.Gruppe6.MoneyBagsPerLocationMin, Config.Gruppe6.MoneyBagsPerLocationMax = 3, 3
end
loadGruppe6()

local GUARD, OTHER = 1, 2
local BAG = Config.Gruppe6.MoneyBagItem

local function bagsIn(id)
    local n = 0
    for _, it in pairs((stashes[id] or {}).items or {}) do if it.name == BAG then n = n + (it.amount or 0) end end
    return n
end
local function takeBags(id, n) stashes[id].items[1].amount = stashes[id].items[1].amount - n end
local function notified(src, text)
    for _, e in ipairs(Mock.clientEventsNamed('QBCore:Notify')) do
        if e.target == src and tostring(e.args[1]):find(text, 1, true) then return true end
    end
    return false
end

local stashId
BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players, stashes = {}, {}
    loadGruppe6()
    Mock.newPlayer(GUARD).PlayerData.job = { name = 'gruppe6', onduty = true }
    Mock.newPlayer(OTHER)
    Mock.fireNet('pf-jobs:gruppe6:startSearch', GUARD)
    Mock.fireNet('pf-jobs:gruppe6:acceptContract', GUARD, { contractId = 0 })
    local start = Mock.clientEventsNamed('pf-jobs:gruppe6:startContract')
    local loc = start[#start].args[1].pickupSequence[1]
    Mock.fireNet('pf-jobs:gruppe6:openPickupStash', GUARD, loc, 1)
    stashId = ('pf_gruppe6_pickup_%s_%s'):format(loc, 1)
end

describe('Gruppe6 pickup stash', function()
    it('counts bags the guard takes out (the stash id arrives as fromInventory)', function()
        assert_eq(bagsIn(stashId), 3)
        takeBags(stashId, 2)
        source = GUARD
        TriggerEvent('qb-inventory:server:SetInventoryData', stashId, 'player', 1, 1, 2, 2)
        source = nil
        assert_true(notified(GUARD, 'You took 2 bag(s). 1 remaining.'))
    end)
    it('emptying the stash moves the guard to the next stop', function()
        takeBags(stashId, 3)
        source = GUARD
        TriggerEvent('qb-inventory:server:SetInventoryData', stashId, 'player', 1, 1, 3, 3)
        source = nil
        assert_eq(stashes[stashId], nil)
        local next = #Mock.clientEventsNamed('pf-jobs:gruppe6:nextPickup') + #Mock.clientEventsNamed('pf-jobs:gruppe6:goToDeposit')
        assert_eq(next, 1)
    end)
    it('a player without this pickup open is not credited', function()
        takeBags(stashId, 1)
        source = OTHER
        TriggerEvent('qb-inventory:server:SetInventoryData', stashId, 'player', 1, 1, 1, 1)
        source = nil
        assert_false(notified(OTHER, 'You took'))
    end)
end)
