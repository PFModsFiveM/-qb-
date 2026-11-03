-- Batch 14, pf-restaurants X1/X4 on a real database: menu items and custom recipes saved before
-- menu text had to be plain text are cleaned when the restaurant loads them, in memory and in the
-- database; a recipe's old platform identifier (createdBy/updatedBy 'license:...') is dropped.
-- Clean rows are left as they are (no write).
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function GetResourceState() return 'missing' end

Config = nil
load_resource('[pfscripts]/pf-restaurants/config/shared.lua')
load_resource('[pfscripts]/pf-restaurants/config/items.lua')
load_resource('[pfscripts]/pf-restaurants/config/restaurants.lua')
load_resource('[pfscripts]/pf-restaurants/config/stations.lua')
load_resource('[pfscripts]/pf-restaurants/config/recipes.lua')
Config.Logging.Enabled = false
load_resource('pfm-core/server/migrations.lua')
QBCore = QBCoreMock
for _, f in ipairs({ 'main', 'persistence' }) do
    load_resource('[pfscripts]/pf-restaurants/server/' .. f .. '.lua')
end
InitRestaurants()
assert(RunMigrations('pf-restaurants', RestaurantDB.Migrations), 'restaurant migrations')

local BID = 'burgershot_vespucci'
local XSS = '<img src=x onerror=postData(1)>'

local function saveMenu(id, item)
    item.menuItemId = id
    MySQL.query.await('INSERT INTO pf_restaurant_menu (business_id, menu_item_id, data) VALUES (?, ?, ?)', { BID, id, json.encode(item) })
end
local function menuRow(id)
    return json.decode(MySQL.scalar.await('SELECT data FROM pf_restaurant_menu WHERE menu_item_id = ?', { id }))
end
local function recipeRow(id)
    return json.decode(MySQL.scalar.await('SELECT data FROM pf_restaurant_recipes WHERE recipe_id = ?', { id }))
end

describe('saved menu text is cleaned on load', function()
    it('a dish saved with markup loads, and stays in the database, as plain text', function()
        saveMenu('menu_bad', { recipeId = 'burger_classic', displayName = XSS .. 'Burger', description = 'The "best" `one` & more',
            category = '<b>Mains</b>', image = '"><script>', price = 10, enabled = true })
        saveMenu('menu_good', { recipeId = 'burger_classic', displayName = "Bob's Fish & Chips", description = 'Fine', category = 'Mains', price = 8, enabled = true })
        MySQL.query.await('INSERT INTO pf_restaurant_recipes (recipe_id, business_id, data) VALUES (?, ?, ?)', { 'custom_old', BID,
            json.encode({ recipeId = 'custom_old', businessId = BID, label = '<script>x</script>Stack', category = 'Mains', createdBy = 'license:abc123', updatedBy = 'steam:1100001' }) })
        local goodBefore = MySQL.scalar.await('SELECT data FROM pf_restaurant_menu WHERE menu_item_id = ?', { 'menu_good' })

        RestaurantData.menus, RestaurantData.recipes = {}, {}
        RestaurantDB.Load()

        local item = RestaurantData.menus[BID].menu_bad
        for _, field in ipairs({ 'displayName', 'description', 'category', 'image' }) do
            assert_false(item[field]:find('[<>"`]'), field .. ' in memory: ' .. item[field])
            assert_false(menuRow('menu_bad')[field]:find('[<>"`]'), field .. ' in the database')
        end
        assert_eq(item.displayName, 'img src=x onerror=postData(1)Burger')
        assert_eq(item.description, 'The best one & more', '"&" is kept')
        assert_eq(menuRow('menu_bad').price, 10, 'the rest of the row is unchanged')

        assert_eq(RestaurantData.menus[BID].menu_good.displayName, "Bob's Fish & Chips")
        assert_eq(MySQL.scalar.await('SELECT data FROM pf_restaurant_menu WHERE menu_item_id = ?', { 'menu_good' }), goodBefore, 'a clean row is not rewritten')

        local recipe = RestaurantData.recipes.custom_old
        assert_eq(recipe.label, 'scriptx/scriptStack')
        assert_eq(recipe.createdBy, nil, 'no platform identifier kept')
        assert_eq(recipe.updatedBy, nil)
        assert_eq(recipeRow('custom_old').label, 'scriptx/scriptStack')
        assert_eq(recipeRow('custom_old').createdBy, nil)
    end)

    it('a recipe that records a citizen id keeps it', function()
        MySQL.query.await('INSERT INTO pf_restaurant_recipes (recipe_id, business_id, data) VALUES (?, ?, ?)', { 'custom_new', BID,
            json.encode({ recipeId = 'custom_new', businessId = BID, label = 'Stack', createdBy = 'ABC12345' }) })
        RestaurantData.recipes = {}
        RestaurantDB.Load()
        assert_eq(RestaurantData.recipes.custom_new.createdBy, 'ABC12345')
    end)
end)
