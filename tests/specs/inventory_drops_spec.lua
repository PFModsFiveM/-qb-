-- Security tests for ground drops: forged item data and remote repositioning.
load_resource('tests/lua/fivem_mocks.lua')
QBCoreMock.Shared.Items.markedbills = { name = 'markedbills', label = 'Marked Money', weight = 1000, type = 'item', unique = true, useable = false, image = 'markedbills.png' }
Config = nil
load_resource('pfm-inventory/config/config.lua')
load_resource('pfm-inventory/config/freshness.lua')
load_resource('pfm-inventory/server/freshness.lua')
load_resource('pfm-inventory/server/main.lua')
load_resource('pfm-inventory/server/functions.lua')
load_resource('pfm-inventory/server/hooks.lua')

local THIEF, OWNER = 1, 2

local function onlyDrop()
    local id, drop = next(Drops)
    return id, drop
end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    Mock.newPlayer(THIEF)
    Mock.newPlayer(OWNER)
    Mock.coords = { [THIEF] = vector3(0, 0, 0), [OWNER] = vector3(500, 500, 0) }
    for k in pairs(Drops) do Drops[k] = nil end
    DropHolders = {}
end

describe('createDrop', function()
    it('stores the server item, not the forged client item', function()
        assert_true(AddItem(THIEF, 'markedbills', 1, 1, { worth = 500 }))
        local forged = { name = 'markedbills', amount = 1, fromSlot = 1, info = { worth = 99999999 }, weight = 0, label = 'Free money' }
        local dropNet = Mock.callCallback('qb-inventory:server:createDrop', THIEF, forged)
        assert_true(dropNet, 'drop created')
        local _, drop = onlyDrop()
        local stored = drop.items[1]
        assert_eq(stored.info.worth, 500, 'worth from the server copy')
        assert_eq(stored.weight, 1000, 'weight from the server copy')
        assert_eq(stored.label, 'Marked Money')
    end)
    it('rejects dropping more than the slot holds', function()
        assert_true(AddItem(THIEF, 'goldbar', 1, 1))
        QBCoreMock.Shared.Items.goldbar.weight = 1
        local res = Mock.callCallback('qb-inventory:server:createDrop', THIEF, { name = 'goldbar', amount = 50, fromSlot = 1 })
        assert_false(res)
        assert_eq(next(Drops), nil, 'no drop created')
    end)
    it('rejects a mismatched name: the server item in that slot is what drops', function()
        assert_true(AddItem(THIEF, 'lockpick', 1, 1))
        Mock.callCallback('qb-inventory:server:createDrop', THIEF, { name = 'goldbar', amount = 1, fromSlot = 1 })
        local _, drop = onlyDrop()
        assert_eq(drop.items[1].name, 'lockpick')
    end)
    it('food dropped on the ground switches to outdoor storage', function()
        assert_true(AddItem(THIEF, 'sandwich', 1, 1))
        Mock.callCallback('qb-inventory:server:createDrop', THIEF, { amount = 1, fromSlot = 1 })
        local _, drop = onlyDrop()
        assert_eq(drop.items[1].info.fresh.storage, 'outdoor')
    end)
end)

describe('updateDrop', function()
    local function makeOwnersDrop()
        assert_true(AddItem(OWNER, 'goldbar', 1, 1))
        Mock.callCallback('qb-inventory:server:createDrop', OWNER, { amount = 1, fromSlot = 1 })
        local id, drop = onlyDrop()
        drop.isOpen = false
        return id, drop
    end

    it('a player far from a drop cannot pull it to themselves', function()
        local id, drop = makeOwnersDrop()
        Mock.fireNet('qb-inventory:server:updateDrop', THIEF, id, vector3(0, 0, 0))
        assert_eq(drop.coords.x, 500, 'drop stays where it was')
    end)
    it('holding requires being next to the bag', function()
        local id, drop = makeOwnersDrop()
        Mock.fireNet('qb-inventory:server:holdDrop', THIEF, id)
        Mock.fireNet('qb-inventory:server:updateDrop', THIEF, id)
        assert_eq(drop.coords.x, 500)
    end)
    it('the carrier places it where the server sees them, ignoring client coords', function()
        local id, drop = makeOwnersDrop()
        Mock.fireNet('qb-inventory:server:holdDrop', OWNER, id)
        Mock.coords[OWNER] = vector3(520, 510, 0)
        Mock.fireNet('qb-inventory:server:updateDrop', OWNER, id, vector3(-9999, -9999, 0))
        assert_eq(drop.coords.x, 520)
        assert_eq(drop.coords.y, 510)
    end)
    it('invalid ids do not crash the handler', function()
        Mock.fireNet('qb-inventory:server:updateDrop', THIEF, nil)
        Mock.fireNet('qb-inventory:server:updateDrop', THIEF, 'drop-does-not-exist')
        Mock.fireNet('qb-inventory:server:holdDrop', THIEF, 42)
    end)
end)

describe('drop access', function()
    local function ownersOpenDrop()
        assert_true(AddItem(OWNER, 'goldbar', 2, 1))
        Mock.callCallback('qb-inventory:server:createDrop', OWNER, { amount = 2, fromSlot = 1 })
        local id, drop = onlyDrop()
        return id, drop -- createDrop leaves it open for the owner
    end

    it('the drop list only names bag entities, never contents', function()
        local id = ownersOpenDrop()
        local list = Mock.callCallback('qb-inventory:server:GetCurrentDrops', THIEF)
        assert_true(list[id] ~= nil)
        assert_eq(list[id].items, nil)
        assert_eq(list[id].coords, nil)
        assert_eq(list[id].isOpen, nil)
    end)
    it('another player cannot close a drop someone has open, so cannot open it alongside them', function()
        local id, drop = ownersOpenDrop()
        Mock.coords[THIEF] = drop.coords
        Mock.fireNet('qb-inventory:server:closeInventory', THIEF, id)
        assert_eq(drop.isOpen, OWNER)
        Mock.fireNet('qb-inventory:server:openDrop', THIEF, id)
        assert_eq(drop.isOpen, OWNER)
    end)
    it('another player cannot close a stash someone has open', function()
        Inventories['stash-test'] = { items = {}, isOpen = OWNER }
        Mock.fireNet('qb-inventory:server:closeInventory', THIEF, 'stash-test')
        assert_eq(Inventories['stash-test'].isOpen, OWNER)
        Mock.fireNet('qb-inventory:server:closeInventory', THIEF, { 'not a string' })
    end)
    it('a carried drop cannot be opened, and an open drop cannot be picked up', function()
        local id, drop = ownersOpenDrop()
        Mock.coords[THIEF] = drop.coords
        Mock.fireNet('qb-inventory:server:holdDrop', THIEF, id)      -- the owner has it open
        assert_eq(DropHolders[id], nil)
        Mock.fireNet('qb-inventory:server:closeInventory', OWNER, id)
        Mock.fireNet('qb-inventory:server:holdDrop', OWNER, id)
        assert_eq(DropHolders[id], OWNER)
        Mock.fireNet('qb-inventory:server:openDrop', THIEF, id)
        assert_eq(drop.isOpen, false)
    end)
    it('items cannot be taken from an open drop after walking away from it', function()
        local id, drop = ownersOpenDrop()
        Mock.coords[OWNER] = vector3(900, 900, 0)
        Mock.fireNet('qb-inventory:server:SetInventoryData', OWNER, id, 'player', 1, 5, 2, 2)
        assert_eq(drop.items[1].amount, 2, 'still in the drop')
    end)
    it('fractional and NaN amounts are refused', function()
        local id, drop = ownersOpenDrop()
        Mock.fireNet('qb-inventory:server:SetInventoryData', OWNER, id, 'player', 1, 5, 2, 0.5)
        Mock.fireNet('qb-inventory:server:SetInventoryData', OWNER, id, 'player', 1, 5, 2, 0 / 0)
        assert_eq(drop.items[1].amount, 2)
    end)
    it('a legitimate move out of a drop still works', function()
        local id, drop = ownersOpenDrop()
        Mock.fireNet('qb-inventory:server:SetInventoryData', OWNER, id, 'player', 1, 5, 2, 2)
        local _, after = next(Drops)
        local left = after and after.items[1] and after.items[1].amount or 0
        assert_eq(left, 0)
    end)
end)
