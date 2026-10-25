-- pf-restaurants net events not covered by the stock/POS work: staff management, repairs, fires,
-- hygiene and menu/recipe text.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/fake_db.lua')
function GetResourceState() return 'started' end

Config = nil
load_resource('[pfscripts]/pf-restaurants/config/shared.lua')
load_resource('[pfscripts]/pf-restaurants/config/items.lua')
load_resource('[pfscripts]/pf-restaurants/config/restaurants.lua')
load_resource('[pfscripts]/pf-restaurants/config/stations.lua')
load_resource('[pfscripts]/pf-restaurants/config/recipes.lua')
Config.Logging.Enabled = false
QBCore = QBCoreMock
for _, f in ipairs({ 'main', 'persistence', 'business', 'recipes', 'menu', 'equipment', 'hygiene', 'fire' }) do
    load_resource('[pfscripts]/pf-restaurants/server/' .. f .. '.lua')
end
InitRestaurants()

-- the restaurant's bank account: every transfer is recorded and succeeds
local transfers = {}
Mock.exportsByResource['pfm-banking'] = {
    Transfer = function(_, opts) transfers[#transfers + 1] = opts return { ok = true } end,
    LedgerAutoKey = function(_, prefix) return prefix .. ':' .. tostring(#transfers + 1) end,
}
local saved = {}
FakeDB.extraPatterns = {
    { 'INSERT INTO pf_restaurant_employees', function(p) saved[#saved + 1] = { 'save', p[2], p[3] } return 1 end },
    { 'DELETE FROM pf_restaurant_employees', function(p) saved[#saved + 1] = { 'delete', p[2] } return 1 end },
    { 'INSERT INTO pf_restaurant_menu', function() return 1 end },
    { 'INSERT INTO pf_restaurant_recipes', function() return 1 end },
    { 'DELETE FROM pf_restaurant_recipes', function() return 1 end },
}

local BID = 'burgershot_vespucci'
local STATION = 'bs_grill_1'
local GRILL = vector3(-1200.5, -891.2, 13.98)
local OWNER, MANAGER, COOK = 1, 2, 3

local function staff(src, cid, grade, isboss)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.job = { name = 'burgershot', grade = { level = grade }, isboss = isboss, onduty = true }
    p.Functions.GetItemByName = function(name) return p.items and p.items[name] or nil end
    return p
end

BeforeEach = function()
    Mock.reset()
    FakeDB.reset()
    transfers, saved = {}, {}
    Mock.players, Mock.coords = {}, {}
    staff(OWNER, 'OWN1', 4, true)
    staff(MANAGER, 'MGR1', 4, false)          -- grade 4: manager
    staff(COOK, 'COOK1', 1, false)            -- grade 1: kitchen staff
    RestaurantData.employees[BID] = { PART = { cid = 'PART', role = 'owner' } }  -- a co-owner added earlier
    RestaurantData.equipment[BID][STATION].condition = 100
    RestaurantData.businesses[BID].hygiene = { dirtLevel = 40, trashCount = 0, roachCount = 0, healthRating = 'A' }
end

describe('staff management', function()
    it('a manager cannot remove, demote or overwrite an owner', function()
        Mock.fireNet('pf-restaurants:server:removeEmployee', MANAGER, BID, 'PART')
        Mock.fireNet('pf-restaurants:server:updateEmployeeRole', MANAGER, BID, 'PART', 'employee')
        Mock.fireNet('pf-restaurants:server:addEmployee', MANAGER, BID, 'PART', 'cashier')
        assert_eq(RestaurantData.employees[BID].PART.role, 'owner')
        assert_eq(#saved, 0)
    end)
    it('a manager still manages other staff; the owner manages owners', function()
        Mock.fireNet('pf-restaurants:server:addEmployee', MANAGER, BID, 'NEW1', 'cashier')
        assert_eq(RestaurantData.employees[BID].NEW1.role, 'cashier')
        Mock.fireNet('pf-restaurants:server:updateEmployeeRole', MANAGER, BID, 'NEW1', 'supervisor')
        assert_eq(RestaurantData.employees[BID].NEW1.role, 'supervisor')
        Mock.fireNet('pf-restaurants:server:removeEmployee', OWNER, BID, 'PART')
        assert_eq(RestaurantData.employees[BID].PART, nil)
    end)
end)

describe('equipment and hygiene', function()
    it('repairing equipment in perfect condition charges nothing', function()
        Mock.fireNet('pf-restaurants:server:repairEquipment', COOK, BID, STATION)
        Mock.fireNet('pf-restaurants:server:repairEquipment', COOK, BID, STATION)
        assert_eq(#transfers, 0)
        RestaurantData.equipment[BID][STATION].condition = 40
        Mock.fireNet('pf-restaurants:server:repairEquipment', COOK, BID, STATION)
        Mock.fireNet('pf-restaurants:server:repairEquipment', COOK, BID, STATION)
        assert_eq(#transfers, 1, 'paid once, then it is repaired')
        assert_eq(transfers[1].from, 'society:restaurant_' .. BID)
    end)
    it('picking up trash that is not there does not clean the restaurant', function()
        Mock.fireNet('pf-restaurants:server:removeTrash', COOK, BID, 'trash_1')
        assert_eq(RestaurantData.businesses[BID].hygiene.dirtLevel, 40)
        RestaurantData.businesses[BID].hygiene.trashCount = 1
        Mock.fireNet('pf-restaurants:server:removeTrash', COOK, BID, 'trash_1')
        assert_true(RestaurantData.businesses[BID].hygiene.dirtLevel < 40)
        assert_eq(RestaurantData.businesses[BID].hygiene.trashCount, 0)
    end)
    it('a fire is put out by someone at it', function()
        TriggerEvent('pf-restaurants:server:startFire', BID, STATION)
        local fireId = Mock.clientEventsNamed('pf-restaurants:client:startFire')[1].args[1]
        Mock.players[COOK].items = { fire_extinguisher = { name = 'fire_extinguisher', amount = 1 } }
        Mock.coords[COOK] = vector3(0.0, 0.0, 0.0)
        Mock.fireNet('pf-restaurants:server:extinguishFire', COOK, fireId)
        assert_eq(#Mock.clientEventsNamed('pf-restaurants:client:extinguishFire'), 0)
        Mock.coords[COOK] = GRILL
        Mock.fireNet('pf-restaurants:server:extinguishFire', COOK, fireId)
        assert_eq(#Mock.clientEventsNamed('pf-restaurants:client:extinguishFire'), 1)
    end)
end)

describe('menu and recipes', function()
    it('menu text is bounded and a missing payload is ignored', function()
        Mock.fireNet('pf-restaurants:server:createMenuItem', MANAGER, BID, nil)
        local recipeId = next(Config.Recipes)
        Mock.fireNet('pf-restaurants:server:createMenuItem', MANAGER, BID, { recipeId = recipeId, price = 5, displayName = string.rep('A', 5000), description = { 'x' } })
        local _, item = next(RestaurantData.menus[BID])
        assert_eq(#item.displayName, 60)
        assert_eq(item.description, '')
    end)
    it('editing a recipe uses the same component rules as creating one', function()
        Mock.fireNet('pf-restaurants:server:createRecipe', OWNER, BID, { label = 'Stack', components = { { item = 'burger_bun', qty = 1 } }, output = { item = 'burger_bun' } })
        local id
        for rid, r in pairs(RestaurantData.recipes) do if r.businessId == BID then id = rid end end
        assert_true(id ~= nil, 'created')
        Mock.fireNet('pf-restaurants:server:updateRecipe', OWNER, id, { components = { { item = 'weapon_pistol_nope', qty = 500 } } })
        assert_eq(RestaurantData.recipes[id].components[1].item, 'burger_bun')
        Mock.fireNet('pf-restaurants:server:updateRecipe', OWNER, id, nil)
    end)
end)
