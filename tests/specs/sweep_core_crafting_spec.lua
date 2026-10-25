-- pfm-crafting: every material is checked before any is taken.
load_resource('tests/lua/fivem_mocks.lua')
Config = nil
load_resource('pfm-crafting/config.lua')
Config.item_bench.recipes = {
    { item = 'lockpick', xpRequired = 0, xpGain = 1, requiredItems = { { item = 'metalscrap', amount = 2 }, { item = 'plastic', amount = 3 } } },
}
local stock = {}
Mock.exportsByResource['pfm-inventory'] = {
    HasItem = function(_, src, item, amount) return (stock[item] or 0) >= (amount or 1) end,
    RemoveItem = function(_, src, item, amount)
        if (stock[item] or 0) < amount then return false end
        stock[item] = stock[item] - amount
        return true
    end,
    AddItem = function(_, src, item, amount) stock[item] = (stock[item] or 0) + amount return true end,
}
load_resource('pfm-crafting/server.lua')

local P = 1

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    local p = Mock.newPlayer(P)
    p.GetRep = function() return 0 end
    p.AddRep = function() end
    Mock.coords[P] = vector3(0, 0, 0)
    stock = { item_bench = 1 }
    Mock.fireNet('qb-crafting:server:addCraftingTable', P, 'item_bench') -- pick up any earlier bench
    stock = { item_bench = 1 }
    Mock.fireNet('qb-crafting:server:removeCraftingTable', P, 'item_bench')
end

describe('crafting', function()
    it('a missing second material leaves the first one in the inventory', function()
        stock.metalscrap, stock.plastic = 10, 1
        Mock.fireNet('qb-crafting:server:receiveItem', P, 'item_bench', 'lockpick', 1)
        assert_eq(stock.metalscrap, 10)
        assert_eq(stock.lockpick, nil)
    end)
    it('with all materials the item is crafted', function()
        stock.metalscrap, stock.plastic = 10, 10
        Mock.fireNet('qb-crafting:server:receiveItem', P, 'item_bench', 'lockpick', 2)
        assert_eq(stock.lockpick, 2)
        assert_eq(stock.metalscrap, 6)
        assert_eq(stock.plastic, 4)
    end)
end)
