-- pf-jobs Gruppe6 (server/apps/gruppe6.lua): a contract pays for the bags handed in at the vault,
-- the truck is the contract's own, pickups must be the contract's stops, and parties need an invite.
load_resource('tests/lua/ledger_env.lua')
QBCore = QBCoreMock
QBCoreMock.Shared.Items.moneybag = { name = 'moneybag', label = 'Money Bag', weight = 1000 }
Citizen = Citizen or {}
Citizen.SetTimeout = function() return 1 end
Citizen.ClearTimeout = function() end
SetTimeout = function(_, fn) fn() end

local spawnedVehicles = {}
function CreateVehicleServerSetter(hash, _, x, y, z, w)
    Mock.nextNetId = Mock.nextNetId + 1
    spawnedVehicles[#spawnedVehicles + 1] = { hash = hash, x = x, y = y }
    return Mock.nextNetId
end
function SetVehicleNumberPlateText(veh, plate) Mock.plates[veh] = plate end
function SetVehicleDoorsLocked() end

local stashes = {}
Mock.exportsByResource['pfm-inventory'] = {
    GetInventory = function(_, id) return stashes[id] end,
    CreateInventory = function(_, id) stashes[id] = stashes[id] or { items = {} } end,
    SetInventory = function(_, id, items) stashes[id] = { items = items } end,
    OpenInventory = function() end,
    RemoveInventory = function(_, id) stashes[id] = nil end,
}

local function loadGruppe6()
    LedgerEnv.load('pf-jobs', { '[pfscripts]/pf-jobs/config.lua', '[pfscripts]/pf-jobs/server/apps/gruppe6.lua' })
    Config.Gruppe6.ServerSideStash = false
    Config.Gruppe6.UseDatabase = false
    Config.Gruppe6.MoneyBagsPerLocationMin, Config.Gruppe6.MoneyBagsPerLocationMax = 3, 3
end

local GUARD, OTHER = 1, 2
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
local function vault()
    local d = Config.Gruppe6.DepositLocation
    return vector3(d.x, d.y, d.z)
end
local function startContract(src)
    Mock.fireNet('pf-jobs:gruppe6:startSearch', src)
    Mock.fireNet('pf-jobs:gruppe6:acceptContract', src, { contractId = 0 })
    local starts = Mock.clientEventsNamed('pf-jobs:gruppe6:startContract')
    return starts[#starts].args[1]
end
local function paid() return LedgerEnv.paid('pf-jobs:gruppe6:') end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players, Mock.coords, stashes, spawnedVehicles = {}, {}, {}, {}
    loadGruppe6()
    newGuard(GUARD)
    newGuard(OTHER)
end

describe('pf-jobs Gruppe6', function()
    it('accepting a contract and depositing at once pays nothing (it used to pay in full)', function()
        startContract(GUARD)
        Mock.coords[GUARD] = vault()
        Mock.fireNet('pf-jobs:gruppe6:depositComplete', GUARD)
        assert_eq(#paid(), 0)
    end)

    it('a made-up stash reported as emptied credits no bags', function()
        local data = startContract(GUARD)
        Mock.fireNet('pf-jobs:gruppe6:checkStashAfterClose', GUARD, 9999, 1)
        Mock.fireNet('pf-jobs:gruppe6:checkStashAfterClose', GUARD, data.pickupSequence[1], 1)
        carried[GUARD] = 50
        Mock.coords[GUARD] = vault()
        Mock.fireNet('pf-jobs:gruppe6:depositComplete', GUARD)
        assert_eq(carried[GUARD], 50)
        assert_eq(#paid(), 0)
    end)

    it("a pickup must be the contract's stop, and an emptied one is not refilled", function()
        local data = startContract(GUARD)
        local loc = data.pickupSequence[1]
        Mock.fireNet('pf-jobs:gruppe6:openPickupStash', GUARD, loc + 1000, 1)
        assert_eq(stashes[('pf_gruppe6_pickup_%s_%s'):format(loc + 1000, 1)], nil)
        local id = ('pf_gruppe6_pickup_%s_%s'):format(loc, 1)
        Mock.fireNet('pf-jobs:gruppe6:openPickupStash', GUARD, loc, 1)
        assert_eq(stashes[id].items[1].amount, 3)
        stashes[id].items[1].amount = 0
        source = GUARD
        TriggerEvent('qb-inventory:server:SetInventoryData', id, 'player', 1, 1, 3, 3)
        source = nil
        assert_eq(stashes[id], nil)
        Mock.fireNet('pf-jobs:gruppe6:openPickupStash', GUARD, loc, 1)
        assert_eq(stashes[id], nil)
    end)

    it('bags handed in at the vault are paid by share, once', function()
        local data = startContract(GUARD)
        local loc = data.pickupSequence[1]
        local id = ('pf_gruppe6_pickup_%s_%s'):format(loc, 1)
        Mock.fireNet('pf-jobs:gruppe6:openPickupStash', GUARD, loc, 1)
        stashes[id].items[1].amount = 0
        carried[GUARD] = 3
        source = GUARD
        TriggerEvent('qb-inventory:server:SetInventoryData', id, 'player', 1, 1, 3, 3)
        source = nil
        Mock.fireNet('pf-jobs:gruppe6:endContract', GUARD)
        -- not at the vault: nothing
        Mock.fireNet('pf-jobs:gruppe6:depositComplete', GUARD)
        assert_eq(carried[GUARD], 3)
        Mock.coords[GUARD] = vault()
        Mock.fireNet('pf-jobs:gruppe6:depositComplete', GUARD)
        assert_eq(carried[GUARD], 0)
        local rows = paid()
        assert_eq(#rows, 1)
        local total = 0
        for _, c in ipairs(data.locationBags) do total = total + c end
        assert_eq(rows[1].amount, math.floor(1000 * 3 / total))   -- tier 1 early-end cap x share
        local xp = Mock.players[GUARD].PlayerData.metadata.gruppe6_xp
        Mock.fireNet('pf-jobs:gruppe6:depositComplete', GUARD)
        assert_eq(#paid(), 1)
        assert_eq(Mock.players[GUARD].PlayerData.metadata.gruppe6_xp, xp)
    end)

    it("the truck is the contract's model, spawned once, only for its contract", function()
        Mock.fireNet('pf-jobs:gruppe6:spawnVehicle', OTHER, 'rhino', 'HACK', { x = 1, y = 2, z = 3, w = 0 })
        assert_eq(#spawnedVehicles, 0)
        local data = startContract(GUARD)
        Mock.fireNet('pf-jobs:gruppe6:spawnVehicle', GUARD, 'rhino', 'HACK', { x = 1, y = 2, z = 3, w = 0 })
        Mock.fireNet('pf-jobs:gruppe6:spawnVehicle', GUARD, 'rhino', 'HACK', { x = 1, y = 2, z = 3, w = 0 })
        assert_eq(#spawnedVehicles, 1)
        assert_eq(spawnedVehicles[1].hash, GetHashKey(data.vehicle))
        assert_eq(spawnedVehicles[1].x, data.spawnCoords.x)
        assert_eq(Mock.plates[Mock.nextNetId], data.plate)
    end)

    it('joining a party needs an invite from its leader', function()
        Mock.fireNet('pf-jobs:gruppe6:createGroup', GUARD)
        Mock.fireNet('pf-jobs:gruppe6:acceptInvite', OTHER, GUARD)
        assert_eq(Mock.callCallback('pf-jobs:gruppe6:getGroup', OTHER), nil)
        Mock.fireNet('pf-jobs:gruppe6:invitePlayer', GUARD, OTHER)
        Mock.fireNet('pf-jobs:gruppe6:acceptInvite', OTHER, GUARD)
        assert_eq(Mock.callCallback('pf-jobs:gruppe6:getGroup', OTHER).leader, GUARD)
    end)
end)
