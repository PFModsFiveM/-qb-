-- pf-restaurants: wine and grape juice from the vineyard are real restaurant supplies with their own
-- prices (Config.Supplies.PricePerItem before the category price, in the catalog and in the order
-- service's pricing), and drinks a restaurant can pour and put on its menu.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/fake_db.lua')
function GetResourceState() return 'started' end

Config = nil
for _, f in ipairs({ 'shared', 'items', 'restaurants', 'stations', 'recipes' }) do load_resource('[pfscripts]/pf-restaurants/config/' .. f .. '.lua') end
Config.Logging.Enabled = false
QBCore = QBCoreMock
local perishables = {}
Mock.exportsByResource['pfm-inventory'] = {
    RegisterPerishables = function(_, map) for k, v in pairs(map) do perishables[k] = v end return true end,
}
for _, f in ipairs({ 'main', 'persistence', 'business', 'recipes', 'menu', 'stations', 'inventory' }) do
    load_resource('[pfscripts]/pf-restaurants/server/' .. f .. '.lua')
end
InitRestaurants()
FakeDB.extraPatterns = { { 'INSERT INTO pf_restaurant_menu', function() return 1 end } }

local BID = 'burgershot_vespucci'
local BOSS = 1

describe('vineyard supplies', function()
    it('wine and grape juice are beverages with their own price; everything else keeps its category price', function()
        assert_eq(Config.Items.wine.category, 'beverages')
        assert_eq(Config.Items.grapejuice.category, 'beverages')
        assert_eq(SupplyUnitPrice('wine'), Config.Supplies.PricePerItem.wine)
        assert_eq(SupplyUnitPrice('grapejuice'), Config.Supplies.PricePerItem.grapejuice)
        assert_true(SupplyUnitPrice('wine') > Config.Supplies.PricePerUnit.beverages)
        assert_eq(SupplyUnitPrice('coffee_beans'), Config.Supplies.PricePerUnit.beverages)
        assert_eq(SupplyUnitPrice('raw_bacon'), Config.Supplies.PricePerUnit.meat_raw)
        assert_eq(SupplyUnitPrice('wine_glass'), nil, 'a poured glass is not a supply')
        assert_eq(SupplyUnitPrice('lockpick'), nil, 'not a restaurant item')
        assert_eq(SupplyUnitPrice(nil), nil)
        assert_eq(Mock.selfExport('GetSupplyUnitPrice')('wine'), Config.Supplies.PricePerItem.wine)
    end)
    it('the supply catalog lists them at that price, in their storage area', function()
        local cat = Mock.selfExport('GetSupplyCatalog')(BID)
        local byItem = {}
        for _, it in ipairs(cat.items) do byItem[it.item] = it end
        assert_eq(byItem.wine.pricePerCase, 18)
        assert_eq(byItem.wine.storage, 'dry')
        assert_eq(byItem.grapejuice.pricePerCase, 10)
        assert_eq(byItem.grapejuice.storage, 'fridge')
        assert_eq(byItem.wine_glass, nil)
        assert_eq(byItem.tea_bags.pricePerCase, Config.Supplies.PricePerUnit.beverages)
    end)
    it('the order service is charged that price, never the client\'s', function()
        local lines, total = RestaurantSupplyAdapter.price(BID, {
            { name = 'WINE', quantity = 3, cost = 0.01 }, { name = 'grapejuice', quantity = 2.9 }, { name = 'tea_bags', quantity = 4 },
            { name = 'wine_glass', quantity = 10 }, { name = 'wine', quantity = 0 },
        })
        assert_eq(#lines, 3)
        assert_eq(lines[1].cost, 18)
        assert_eq(lines[2].quantity, 2)
        assert_eq(total, 3 * 18 + 2 * 10 + 4 * Config.Supplies.PricePerUnit.beverages)
    end)
    it('they keep like sealed drinks and the glasses become items', function()
        RestaurantDB.RegisterItems()
        assert_eq(perishables.wine, 'beverage')
        assert_eq(perishables.grapejuice, 'beverage')
        assert_true(QBCoreMock.Shared.Items.wine_glass ~= nil)
        assert_true(QBCoreMock.Shared.Items.grape_juice_glass ~= nil)
        assert_true(QBCoreMock.Shared.Items.wine_glass.useable, 'a drink')
    end)
end)

describe('drink recipes', function()
    it('the drink station pours wine into four glasses and grape juice into two', function()
        local wine = FindComponentRule('fill_drink', 'drink', { { item = 'wine', qty = 1 } })
        assert_true(wine ~= nil)
        assert_eq(wine.output[1].item, 'wine_glass')
        assert_eq(wine.output[1].qty, 4)
        local juice = FindComponentRule('fill_drink', 'drink', { { item = 'grapejuice', qty = 1 } })
        assert_eq(juice.output[1].item, 'grape_juice_glass')
        assert_eq(juice.output[1].qty, 2)
        assert_eq(FindComponentRule('fill_drink', 'grill', { { item = 'wine', qty = 1 } }), nil, 'only at a drink station')
        -- both restaurants have a drink station with Fill Drink
        for _, id in ipairs({ 'burgershot_vespucci', 'pizzathis' }) do
            local found = false
            for _, st in pairs(RestaurantData.stations[id] or {}) do if st.type == 'drink' then found = true end end
            assert_true(found, id .. ' has a drink station')
        end
    end)
    it('the glasses are menu recipes in the drinks category', function()
        assert_eq(Config.Recipes.wine_glass.label, 'Glass of Wine')
        assert_eq(Config.Recipes.wine_glass.category, 'drinks')
        assert_eq(Config.Recipes.wine_glass.output.item, 'wine_glass')
        assert_eq(Config.Recipes.grape_juice_glass.output.item, 'grape_juice_glass')
        local p = Mock.newPlayer(BOSS, 'BOSS1')
        p.PlayerData.job = { name = 'burgershot', grade = { level = 4 }, isboss = true, onduty = true }
        Mock.fireNet('pf-restaurants:server:createMenuItem', BOSS, BID, { recipeId = 'grape_juice_glass', price = 4 })
        local found
        for _, m in pairs(RestaurantData.menus[BID] or {}) do if m.recipeId == 'grape_juice_glass' then found = m end end
        assert_true(found ~= nil)
        assert_eq(found.displayName, 'Grape Juice')
        assert_eq(found.category, 'drinks')
    end)
end)
