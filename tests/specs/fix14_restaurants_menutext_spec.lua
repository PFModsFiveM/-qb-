-- Batch 14, pf-restaurants X1/X2 (server side): menu text is plain text. A dish name, description,
-- category or image, and a custom recipe's label or category, with a markup character (< > " `) is
-- refused with a message; '&' and apostrophes stay allowed ("Fish & Chips", "Bob's Burger").
-- Text is cut on a character boundary. Saved rows are cleaned on load (realdb spec).
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/fake_db.lua')
function GetResourceState() return 'missing' end

Config = nil
load_resource('[pfscripts]/pf-restaurants/config/shared.lua')
load_resource('[pfscripts]/pf-restaurants/config/items.lua')
load_resource('[pfscripts]/pf-restaurants/config/restaurants.lua')
load_resource('[pfscripts]/pf-restaurants/config/stations.lua')
load_resource('[pfscripts]/pf-restaurants/config/recipes.lua')
Config.Logging.Enabled = false
QBCore = QBCoreMock
for _, f in ipairs({ 'main', 'persistence', 'business', 'recipes', 'menu' }) do
    load_resource('[pfscripts]/pf-restaurants/server/' .. f .. '.lua')
end
InitRestaurants()

local saved = {}
FakeDB.extraPatterns = {
    { 'INSERT INTO pf_restaurant_menu', function(p) saved[#saved + 1] = p[3] return 1 end },
    { 'INSERT INTO pf_restaurant_recipes', function() return 1 end },
}

local BID = 'burgershot_vespucci'
local BOSS = 1
local XSS = '<img src=x onerror=postData(1)>'

local function notes(src)
    local out = {}
    for _, e in ipairs(Mock.clientEventsNamed('QBCore:Notify')) do if e.target == src then out[#out + 1] = e.args[1] end end
    return table.concat(out, ' | ')
end
local function onlyItem()
    local id, item = next(RestaurantData.menus[BID] or {})
    return item, id
end

BeforeEach = function()
    Mock.reset()
    FakeDB.reset()
    saved = {}
    Mock.players = {}
    local p = Mock.newPlayer(BOSS, 'BOSS1')
    p.PlayerData.job = { name = 'burgershot', onduty = true, isboss = true, grade = { level = 4 } }
    RestaurantData.menus[BID] = {}
end

describe('menu text is plain text', function()
    it('a dish name with markup is refused, with a message', function()
        Mock.fireNet('pf-restaurants:server:createMenuItem', BOSS, BID, { recipeId = 'burger_classic', price = 5, displayName = XSS })
        assert_eq(onlyItem(), nil, 'not created')
        assert_true(notes(BOSS):find('cannot contain', 1, true) ~= nil, notes(BOSS))
        assert_eq(#saved, 0)
        for _, field in ipairs({ 'description', 'category', 'image' }) do
            Mock.fireNet('pf-restaurants:server:createMenuItem', BOSS, BID, { recipeId = 'burger_classic', price = 5, displayName = 'Ok', [field] = 'a "quoted" `tick`' })
            assert_eq(onlyItem(), nil, field .. ' with markup')
        end
    end)

    it('"&" and apostrophes are plain text', function()
        Mock.fireNet('pf-restaurants:server:createMenuItem', BOSS, BID, { recipeId = 'burger_classic', price = 5, displayName = "Bob's Fish & Chips", description = 'Salt & vinegar' })
        local item = onlyItem()
        assert_true(item ~= nil)
        assert_eq(item.displayName, "Bob's Fish & Chips")
        assert_eq(item.description, 'Salt & vinegar')
    end)

    it('an update with markup changes nothing, not even the price in it', function()
        Mock.fireNet('pf-restaurants:server:createMenuItem', BOSS, BID, { recipeId = 'burger_classic', price = 5, displayName = 'Classic' })
        local item, id = onlyItem()
        Mock.fireNet('pf-restaurants:server:updateMenuItem', BOSS, BID, id, { displayName = XSS, price = 9 })
        assert_eq(item.displayName, 'Classic')
        assert_eq(item.price, 5)
        Mock.fireNet('pf-restaurants:server:updateMenuItem', BOSS, BID, id, { description = '<script>x</script>' })
        assert_eq(item.description, '')
        Mock.fireNet('pf-restaurants:server:updateMenuItem', BOSS, BID, id, { displayName = 'Classic & Cheese', price = 9 })
        assert_eq(item.displayName, 'Classic & Cheese')
        assert_eq(item.price, 9)
    end)

    it("a recipe's label becomes the default name only as plain text", function()
        RestaurantData.recipes.custom_old = { recipeId = 'custom_old', businessId = BID, label = 'Old ' .. XSS .. 'Stack', category = '<b>Mains</b>' }
        Mock.fireNet('pf-restaurants:server:createMenuItem', BOSS, BID, { recipeId = 'custom_old', price = 5 })
        local item = onlyItem()
        assert_true(item ~= nil)
        assert_false(item.displayName:find('[<>"`]'), item.displayName)
        assert_false(item.category:find('[<>"`]'), item.category)
        RestaurantData.recipes.custom_old = nil
    end)

    it('a custom recipe label or category with markup is refused', function()
        local before = 0
        for _ in pairs(RestaurantData.recipes) do before = before + 1 end
        Mock.fireNet('pf-restaurants:server:createRecipe', BOSS, BID, { label = XSS, components = { { item = 'burger_bun', qty = 1 } }, output = { item = 'burger_bun' } })
        Mock.fireNet('pf-restaurants:server:createRecipe', BOSS, BID, { label = 'Fine', category = '"x"', components = { { item = 'burger_bun', qty = 1 } }, output = { item = 'burger_bun' } })
        local after = 0
        for _ in pairs(RestaurantData.recipes) do after = after + 1 end
        assert_eq(after, before)
    end)
end)

describe('PlainText', function()
    it('cuts on a character boundary and turns control characters into spaces', function()
        local text = PlainText(string.rep('a', 59) .. 'é', 60)
        assert_eq(#text, 59, 'the half character is dropped')
        assert_true(utf8.len(text) ~= nil)
        assert_eq(PlainText('a\nb\tc', 10), 'a b c')
        local stripped, had = PlainText('<b>Fish & Chips</b>', 60, true)
        assert_eq(stripped, 'bFish & Chips/b')
        assert_true(had)
        assert_eq(PlainText({}, 10), nil)
    end)
end)
