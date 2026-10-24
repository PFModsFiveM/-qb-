-- Integration tests: pfm-inventory's real server files on the FiveM mock runtime.
load_resource('tests/lua/fivem_mocks.lua')
Config = nil
load_resource('pfm-inventory/config/config.lua')
load_resource('pfm-inventory/config/freshness.lua')
load_resource('pfm-inventory/server/freshness.lua')
load_resource('pfm-inventory/server/main.lua')
load_resource('pfm-inventory/server/functions.lua')
load_resource('pfm-inventory/server/hooks.lua')

local HOUR = 3600
local SRC = 1
local MOVE = 'qb-inventory:server:SetInventoryData'

local function countItem(items, name)
    local total, stacks = 0, 0
    for _, item in pairs(items) do
        if item.name == name then
            total = total + item.amount
            stacks = stacks + 1
        end
    end
    return total, stacks
end

local function itemAt(items, slot)
    for _, item in pairs(items) do
        if item.slot == slot then return item end
    end
end

local function openStash(id, maxweight, slots)
    CreateInventory(id, { label = id, maxweight = maxweight or 100000, slots = slots or 10 })
    Inventories[id].isOpen = SRC
    return Inventories[id]
end

BeforeEach = function()
    Mock.reset()
    Mock.clock = 1700000000
    for k in pairs(Inventories) do Inventories[k] = nil end
    Mock.players = {}
    Mock.newPlayer(SRC)
    Player(SRC).state.inv_busy = false
    PFFreshness.StorageOverrides = {}
    DropHolders = {}
    for k in pairs(Drops) do Drops[k] = nil end
end

describe('AddItem input validation', function()
    it('rejects zero, negative and non-numeric amounts', function()
        local items = Mock.players[SRC].PlayerData.items
        assert_false(AddItem(SRC, 'lockpick', 0), 'zero')
        assert_false(AddItem(SRC, 'lockpick', -5), 'negative')
        assert_false(AddItem(SRC, 'lockpick', 0 / 0), 'NaN')
        assert_eq(countItem(items, 'lockpick'), 0)
    end)
    it('refuses to overwrite a different item in an explicit slot', function()
        local items = Mock.players[SRC].PlayerData.items
        assert_true(AddItem(SRC, 'goldbar', 1, 3))
        assert_false(AddItem(SRC, 'lockpick', 1, 3), 'slot 3 holds a goldbar')
        assert_eq(itemAt(items, 3).name, 'goldbar', 'goldbar not destroyed')
    end)
    it('copies info so callers cannot share a table between stacks', function()
        local shared = { quality = 80 }
        assert_true(AddItem(SRC, 'phone', 1, nil, shared))
        shared.quality = 1
        local items = Mock.players[SRC].PlayerData.items
        local _, phone = next(items)
        assert_eq(phone.info.quality, 80)
    end)
end)

describe('batch-aware stacking', function()
    it('food from different batches lands in separate stacks', function()
        assert_true(AddItem(SRC, 'sandwich', 2))
        Mock.clock = Mock.clock + HOUR
        assert_true(AddItem(SRC, 'sandwich', 3))
        local total, stacks = countItem(Mock.players[SRC].PlayerData.items, 'sandwich')
        assert_eq(total, 5)
        assert_eq(stacks, 2)
    end)
    it('non-perishables still stack as before', function()
        assert_true(AddItem(SRC, 'lockpick', 2))
        assert_true(AddItem(SRC, 'lockpick', 3))
        local total, stacks = countItem(Mock.players[SRC].PlayerData.items, 'lockpick')
        assert_eq(total, 5)
        assert_eq(stacks, 1)
    end)
    it('a split of one batch can be stacked back together', function()
        openStash('stash-a')
        assert_true(AddItem(SRC, 'sandwich', 4, 1))
        Mock.fireNet(MOVE, SRC, 'player', 'player', 1, 2, 4, 2)       -- split 2 into slot 2
        Mock.fireNet(MOVE, SRC, 'player', 'player', 2, 1, 2, 2)       -- stack them back
        local total, stacks = countItem(Mock.players[SRC].PlayerData.items, 'sandwich')
        assert_eq(total, 4)
        assert_eq(stacks, 1)
    end)
    it('dragging one batch onto another batch swaps instead of merging', function()
        assert_true(AddItem(SRC, 'sandwich', 2, 1))
        Mock.clock = Mock.clock + HOUR
        assert_true(AddItem(SRC, 'sandwich', 3, 2))
        local items = Mock.players[SRC].PlayerData.items
        local batch1, batch2 = itemAt(items, 1).info.fresh.batch, itemAt(items, 2).info.fresh.batch
        Mock.fireNet(MOVE, SRC, 'player', 'player', 1, 2, 2, 2)
        local total, stacks = countItem(items, 'sandwich')
        assert_eq(total, 5)
        assert_eq(stacks, 2, 'batches kept apart')
        assert_eq(itemAt(items, 2).info.fresh.batch, batch1)
        assert_eq(itemAt(items, 1).info.fresh.batch, batch2)
    end)
end)

describe('moves never lose items', function()
    it('moving into a full stash keeps the item in the player inventory', function()
        openStash('tiny', 100, 10)                                     -- 100g capacity, goldbar is 7000g
        assert_true(AddItem(SRC, 'goldbar', 1, 1))
        Mock.fireNet(MOVE, SRC, 'player', 'tiny', 1, 1, 1, 1)
        assert_eq(countItem(Mock.players[SRC].PlayerData.items, 'goldbar'), 1, 'goldbar still owned')
        assert_eq(countItem(Inventories['tiny'].items, 'goldbar'), 0)
    end)
    it('a failed move tells the client to resync', function()
        openStash('tiny', 100, 10)
        assert_true(AddItem(SRC, 'goldbar', 1, 1))
        Mock.fireNet(MOVE, SRC, 'player', 'tiny', 1, 1, 1, 1)
        assert_eq(#Mock.clientEventsNamed('qb-inventory:client:updateInventory'), 1)
    end)
    it('dragging a unique item onto another of the same name keeps both', function()
        assert_true(AddItem(SRC, 'weapon_pistol', 1, 1, { serie = 'AAA' }))
        assert_true(AddItem(SRC, 'weapon_pistol', 1, 2, { serie = 'BBB' }))
        Mock.fireNet(MOVE, SRC, 'player', 'player', 1, 2, 1, 1)
        local items = Mock.players[SRC].PlayerData.items
        local total = countItem(items, 'weapon_pistol')
        assert_eq(total, 2, 'no pistol destroyed')
        local series = {}
        for _, it in pairs(items) do if it.name == 'weapon_pistol' then series[it.info.serie] = true end end
        assert_true(series.AAA and series.BBB, 'both serials survive')
    end)
    it('splitting does not share info between the two stacks', function()
        assert_true(AddItem(SRC, 'lockpick', 4, 1, { note = 'x' }))
        Mock.fireNet(MOVE, SRC, 'player', 'player', 1, 2, 4, 2)
        local items = Mock.players[SRC].PlayerData.items
        assert_true(itemAt(items, 1).info ~= itemAt(items, 2).info, 'distinct info tables')
    end)
end)

describe('access control on moves', function()
    it('cannot move items out of a stash the player has not opened', function()
        CreateInventory('someone-elses', { maxweight = 100000, slots = 10 })
        assert_true(AddItem('someone-elses', 'goldbar', 1, 1))
        Mock.fireNet(MOVE, SRC, 'someone-elses', 'player', 1, 1, 1, 1)
        assert_eq(countItem(Inventories['someone-elses'].items, 'goldbar'), 1)
        assert_eq(countItem(Mock.players[SRC].PlayerData.items, 'goldbar'), 0)
    end)
    it('ignores negative and non-numeric amounts', function()
        openStash('stash-b')
        assert_true(AddItem(SRC, 'lockpick', 2, 1))
        Mock.fireNet(MOVE, SRC, 'player', 'stash-b', 1, 1, -1, -1)
        Mock.fireNet(MOVE, SRC, 'player', 'stash-b', 1, 1, 'x', 'y')
        assert_eq(countItem(Mock.players[SRC].PlayerData.items, 'lockpick'), 2)
    end)
    it('stashes are isolated from each other', function()
        openStash('pallet-1')
        openStash('pallet-2')
        assert_true(AddItem('pallet-1', 'goldbar', 1))
        assert_eq(countItem(Inventories['pallet-1'].items, 'goldbar'), 1)
        assert_eq(countItem(Inventories['pallet-2'].items, 'goldbar'), 0)
    end)
end)

describe('freshness through real moves', function()
    it('food moved from a fridge to a trunk settles at the fridge rate', function()
        openStash('fridge-kitchen')
        openStash('trunk-ABC123')
        assert_true(AddItem('fridge-kitchen', 'sandwich', 1, 1))
        Mock.clock = Mock.clock + 8 * HOUR                           -- 8h at 0.25 = 2h used
        Mock.fireNet(MOVE, SRC, 'fridge-kitchen', 'trunk-ABC123', 1, 1, 1, 1)
        local sandwich = itemAt(Inventories['trunk-ABC123'].items, 1)
        assert_eq(sandwich.info.fresh.storage, 'trunk')
        assert_eq(sandwich.info.fresh.used, 2 * HOUR)
    end)
    it('opening an inventory sends display freshness without mutating stored items', function()
        assert_true(AddItem(SRC, 'sandwich', 1, 1))
        Mock.clock = Mock.clock + 6 * HOUR
        OpenInventory(SRC)
        local sent = Mock.clientEventsNamed('qb-inventory:client:openInventory')[1]
        local sentItem = itemAt(sent.args[1], 1)
        assert_eq(sentItem.info.freshDisplay.pct, 50)
        assert_eq(itemAt(Mock.players[SRC].PlayerData.items, 1).info.freshDisplay, nil)
    end)
    it('legacy stash food gets a freshness record when the stash opens', function()
        CreateInventory('old-stash', { maxweight = 100000, slots = 10 })
        Inventories['old-stash'].items[1] = { name = 'sandwich', amount = 2, slot = 1, info = {}, weight = 200 }
        OpenInventory(SRC, 'old-stash')
        assert_eq(type(Inventories['old-stash'].items[1].info.fresh), 'table')
    end)
end)

describe('RemoveItem validation', function()
    it('rejects invalid amounts without crashing', function()
        assert_true(AddItem(SRC, 'lockpick', 3, 1))
        assert_false(RemoveItem(SRC, 'lockpick', -2, 1))
        assert_false(RemoveItem(SRC, 'lockpick', 'abc', 1))
        assert_eq(countItem(Mock.players[SRC].PlayerData.items, 'lockpick'), 3)
    end)
end)
