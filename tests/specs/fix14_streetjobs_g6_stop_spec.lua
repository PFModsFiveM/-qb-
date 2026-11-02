-- Batch 14 (JOBS-1): a Gruppe 6 pickup is served only to a guard standing at that stop, by the
-- server's own position of the ped. The stop numbers alone used to let a client open and empty every
-- stop of the route from the vault, then deposit for the full contract pay.
load_resource('tests/lua/ledger_env.lua')
QBCore = QBCoreMock
QBCoreMock.Shared.Items.moneybag = { name = 'moneybag', label = 'Money Bag', weight = 1000 }
Citizen = Citizen or {}
Citizen.SetTimeout = function() return 1 end
Citizen.ClearTimeout = function() end
SetTimeout = function(_, fn) fn() end -- the shared-stash recount runs at once here

function CreateVehicleServerSetter() Mock.nextNetId = Mock.nextNetId + 1 return Mock.nextNetId end
function SetVehicleNumberPlateText(veh, plate) Mock.plates[veh] = plate end
function SetVehicleDoorsLocked() end

local stashes, opened = {}, {}
Mock.exportsByResource['pfm-inventory'] = {
    GetInventory = function(_, id) return stashes[id] end,
    CreateInventory = function(_, id) stashes[id] = stashes[id] or { items = {} } end,
    SetInventory = function(_, id, items) stashes[id] = { items = items } end,
    OpenInventory = function(_, src, id) opened[#opened + 1] = { src = src, id = id } end,
    RemoveInventory = function(_, id) stashes[id] = nil end,
}

local function loadGruppe6(serverSide)
    LedgerEnv.load('pf-jobs', { '[pfscripts]/pf-jobs/config.lua', '[pfscripts]/pf-jobs/server/apps/gruppe6.lua' })
    Config.Gruppe6.ServerSideStash = serverSide == true
    Config.Gruppe6.UseDatabase = false
    Config.Gruppe6.MoneyBagsPerLocationMin, Config.Gruppe6.MoneyBagsPerLocationMax = 3, 3
end

local GUARD = 1
local BAG = 'moneybag'
local carried = {}
local function newGuard(src)
    local p = Mock.newPlayer(src)
    p.PlayerData.job = { name = 'gruppe6', onduty = true }
    carried[src] = 0
    p.Functions.GetItemByName = function(name) if name == BAG and carried[src] > 0 then return { name = BAG, amount = carried[src] } end end
    p.Functions.RemoveItem = function(name, n) if name == BAG then carried[src] = carried[src] - n end return true end
    p.Functions.AddItem = function(name, n) if name == BAG then carried[src] = carried[src] + n end return true end
    return p
end
local function startContract(src)
    Mock.fireNet('pf-jobs:gruppe6:startSearch', src)
    Mock.fireNet('pf-jobs:gruppe6:acceptContract', src, { contractId = 0 })
    local starts = Mock.clientEventsNamed('pf-jobs:gruppe6:startContract')
    return starts[#starts].args[1]
end
local function vault()
    local d = Config.Gruppe6.DepositLocation
    return vector3(d.x, d.y, d.z)
end
local function stop(data, n) local c = data.locationPool[data.pickupSequence[n]] return vector3(c.x, c.y, c.z) end
local function offset(c, metres) return vector3(c.x + metres, c.y, c.z) end
local function view(src) return Mock.callCallback('pf-jobs:gruppe6:getAppView', src) end
local function paid() return LedgerEnv.paid('pf-jobs:gruppe6:') end
local function stashOf(data, n) return ('pf_gruppe6_pickup_%s_%s'):format(data.pickupSequence[n], n) end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players, Mock.coords, stashes, opened = {}, {}, {}, {}
end

describe('fix14 Gruppe 6: pickups only at the stop (shared stash)', function()
    it('opening a stop from the vault does nothing; at the stop it opens', function()
        loadGruppe6(false)
        newGuard(GUARD)
        local data = startContract(GUARD)
        Mock.coords[GUARD] = vault()
        Mock.fireNet('pf-jobs:gruppe6:openPickupStash', GUARD, data.pickupSequence[1], 1)
        assert_eq(stashes[stashOf(data, 1)], nil, 'no stash seeded from afar')
        assert_eq(#opened, 0, 'nothing opened from afar')
        Mock.coords[GUARD] = offset(stop(data, 1), 13.0)
        Mock.fireNet('pf-jobs:gruppe6:openPickupStash', GUARD, data.pickupSequence[1], 1)
        assert_eq(#opened, 0, 'just outside the range is still refused')
        Mock.coords[GUARD] = offset(stop(data, 1), 8.0)
        Mock.fireNet('pf-jobs:gruppe6:openPickupStash', GUARD, data.pickupSequence[1], 1)
        assert_eq(#opened, 1, 'within reach of the stop it opens')
        assert_eq(stashes[stashOf(data, 1)].items[1].amount, 3)
    end)

    it('bags moved out of an open stash after walking away are not credited', function()
        loadGruppe6(false)
        newGuard(GUARD)
        local data = startContract(GUARD)
        local id = stashOf(data, 1)
        Mock.coords[GUARD] = stop(data, 1)
        Mock.fireNet('pf-jobs:gruppe6:openPickupStash', GUARD, data.pickupSequence[1], 1)
        -- one bag at the stop: counted
        stashes[id].items[1].amount = 2
        Mock.fireNet('qb-inventory:server:SetInventoryData', GUARD, id, 'player')
        assert_eq(view(GUARD).contract.bagsTaken, 1)
        -- the stash is left open and the guard drives off: the rest counts nothing
        Mock.coords[GUARD] = vault()
        stashes[id].items[1].amount = 0
        Mock.fireNet('qb-inventory:server:SetInventoryData', GUARD, id, 'player')
        assert_eq(view(GUARD).contract.bagsTaken, 1, 'the bags taken away from the stop do not count')
    end)

    it('the close check credits a stop only at the stop', function()
        loadGruppe6(false)
        newGuard(GUARD)
        local data = startContract(GUARD)
        local id = stashOf(data, 1)
        Mock.coords[GUARD] = stop(data, 1)
        Mock.fireNet('pf-jobs:gruppe6:openPickupStash', GUARD, data.pickupSequence[1], 1)
        stashes[id].items[1].amount = 0 -- emptied (the move event not seen yet)
        Mock.coords[GUARD] = vault()
        Mock.fireNet('pf-jobs:gruppe6:checkStashAfterClose', GUARD, data.pickupSequence[1], 1)
        assert_eq(view(GUARD).contract.bagsTaken or 0, 0, 'nothing credited away from the stop')
        Mock.coords[GUARD] = stop(data, 1)
        Mock.fireNet('pf-jobs:gruppe6:checkStashAfterClose', GUARD, data.pickupSequence[1], 1)
        assert_eq(view(GUARD).contract.bagsTaken, 3, 'credited back at the stop')
    end)
end)

describe('fix14 Gruppe 6: pickups only at the stop (server-side stash)', function()
    it('emptying every stop from the vault gives no bag and no pay', function()
        loadGruppe6(true)
        newGuard(GUARD)
        local data = startContract(GUARD)
        Mock.coords[GUARD] = vault()
        for n, loc in ipairs(data.pickupSequence) do
            Mock.fireNet('pf-jobs:gruppe6:openPickupStash', GUARD, loc, n)
            for _ = 1, data.locationBags[n] do Mock.fireNet('pf-jobs:gruppe6:takePickupBag', GUARD, loc, n) end
        end
        assert_eq(carried[GUARD], 0, 'no bag from afar')
        Mock.fireNet('pf-jobs:gruppe6:depositComplete', GUARD)
        assert_eq(#paid(), 0)
    end)

    it('driving the route pays as before', function()
        loadGruppe6(true)
        newGuard(GUARD)
        local data = startContract(GUARD)
        local total = 0
        for n, loc in ipairs(data.pickupSequence) do
            Mock.coords[GUARD] = offset(stop(data, n), 2.0)
            Mock.fireNet('pf-jobs:gruppe6:openPickupStash', GUARD, loc, n)
            for _ = 1, data.locationBags[n] do Mock.fireNet('pf-jobs:gruppe6:takePickupBag', GUARD, loc, n) end
            total = total + data.locationBags[n]
        end
        assert_eq(carried[GUARD], total)
        Mock.coords[GUARD] = vault()
        Mock.fireNet('pf-jobs:gruppe6:depositComplete', GUARD)
        local rows = paid()
        assert_eq(#rows, 1)
        assert_eq(rows[1].amount, data.payout)
    end)

    it('a bag is taken only at its own stop, not at the next one', function()
        loadGruppe6(true)
        newGuard(GUARD)
        local data = startContract(GUARD)
        Mock.coords[GUARD] = stop(data, 2) -- standing at stop 2 while stop 1 is due
        Mock.fireNet('pf-jobs:gruppe6:takePickupBag', GUARD, data.pickupSequence[1], 1)
        assert_eq(carried[GUARD], 0)
        Mock.coords[GUARD] = stop(data, 1)
        Mock.fireNet('pf-jobs:gruppe6:takePickupBag', GUARD, data.pickupSequence[1], 1)
        assert_eq(carried[GUARD], 1)
    end)
end)
