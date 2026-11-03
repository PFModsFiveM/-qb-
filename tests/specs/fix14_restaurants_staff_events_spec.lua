-- Batch 14, pf-restaurants:
--  R1  kitchen tickets and cooking sessions reach only the restaurant's staff on shift, and carry no
--      citizen or server ids (nor payment details); the staff callbacks and syncStations neither.
--  R2  a role saved on the staff list (staff screen, Job Board) counts only on shift: on duty in the
--      restaurant's job, or clocked in at a register. Management permissions work off shift.
--  X3  the stock stashes need storage.access (not cashiers), on shift.
--  X4  custom recipes record the citizen id (server only), are not broadcast, and only the
--      restaurant's staff read them.
--  X5  a cooking session carries the server clock (serverNow) for the client's progress display.
-- Menu text (X1/X2) is in fix14_restaurants_menutext_spec.lua.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/fake_db.lua')
local started = { ['pfm-banking'] = true, ['pfm-inventory'] = true }
function GetResourceState(name) return started[name] and 'started' or 'missing' end

Config = nil
load_resource('[pfscripts]/pf-restaurants/config/shared.lua')
load_resource('[pfscripts]/pf-restaurants/config/items.lua')
load_resource('[pfscripts]/pf-restaurants/config/restaurants.lua')
load_resource('[pfscripts]/pf-restaurants/config/stations.lua')
load_resource('[pfscripts]/pf-restaurants/config/recipes.lua')
Config.Logging.Enabled = false
QBCore = QBCoreMock
for _, f in ipairs({ 'main', 'persistence', 'business', 'recipes', 'menu', 'orders', 'stations', 'inventory', 'integration' }) do
    load_resource('[pfscripts]/pf-restaurants/server/' .. f .. '.lua')
end
InitRestaurants()

local BID, PZ = 'burgershot_vespucci', 'pizzathis'
local REGISTER = vector3(-1195.5, -892.0, 13.98)
local GRILL = vector3(-1200.5, -891.2, 13.98)
local FRIDGE = vector3(-1202.1, -897.8, 13.98)
local PZ_REGISTER = vector3(808.9, -751.3, 26.78)
local FAR = vector3(0.0, 0.0, 0.0)

-- the ledger: every transfer succeeds and is recorded
local transfers = {}
Mock.exportsByResource['pfm-banking'] = {
    Transfer = function(_, opts) transfers[#transfers + 1] = opts return { ok = true } end,
    EnsureSocietyAccount = function() return true end,
}

-- the inventory: restaurant stashes with bacon; players take anything; opened stashes recorded
local stashes, opened, given = {}, {}, {}
local function resetInventory()
    stashes = { ['restaurant-' .. BID .. '-fridge'] = { items = { [1] = { name = 'raw_bacon', amount = 40, slot = 1, info = {} } } } }
    opened, given = {}, {}
end
Mock.exportsByResource['pfm-inventory'] = {
    GetInventory = function(_, id) return stashes[id] end,
    RemoveItem = function(_, id, item, qty, slot)
        local stash = stashes[id]
        local it = stash and stash.items[slot]
        if not it or it.name ~= item or it.amount < qty then return false end
        it.amount = it.amount - qty
        return true
    end,
    AddItem = function(_, target, item, qty)
        if type(target) == 'number' then given[#given + 1] = { src = target, item = item, qty = qty } end
        return true
    end,
    SaveStash = function() end,
    OpenInventory = function(_, src, id) opened[#opened + 1] = { src = src, id = id } end,
    GetFreshness = function() return { pct = 100 } end,
    FreshnessAtPercent = function() return nil end,
}

-- the database rows this spec touches
local orderRows, recipeSaves = {}, {}
FakeDB.extraPatterns = {
    { 'INSERT INTO pf_restaurant_employees', function() return 1 end },
    { 'DELETE FROM pf_restaurant_employees', function() return 1 end },
    { "SELECT citizenid FROM pf_restaurant_employees", function() return nil end },
    { 'SELECT COUNT(*) FROM pf_restaurant_employees', function() return 0 end },
    { 'SELECT 1 FROM players', function() return 1 end },
    { 'INSERT INTO pf_restaurant_menu', function() return 1 end },
    { 'INSERT INTO pf_restaurant_recipes', function(p) recipeSaves[#recipeSaves + 1] = p[3] return 1 end },
    { 'DELETE FROM pf_restaurant_recipes', function() return 1 end },
    { 'INSERT INTO pf_restaurant_orders', function(p)
        orderRows[p[1]] = { status = p[3], data = p[10] }
        return 1
    end },
    { 'UPDATE pf_restaurant_orders SET status = ?', function(p)
        local row = orderRows[p[3]]
        if not row or row.status ~= p[4] then return 0 end
        row.status = p[1]
        return 1
    end },
    { 'UPDATE pf_restaurant_orders SET data = ?', function(p)
        if orderRows[p[2]] then orderRows[p[2]].data = p[1] end
        return 1
    end },
    { 'SELECT data FROM pf_restaurant_orders WHERE business_id', function()
        local out = {}
        for _, row in pairs(orderRows) do out[#out + 1] = { data = row.data } end
        return out
    end },
    { 'SELECT data FROM pf_restaurant_orders WHERE order_id', function(p) return orderRows[p[1]] and orderRows[p[1]].data end },
}

-- players: job staff (owner, cook), saved staff (hired cook, cashier, manager, co-owner), a
-- customer, and a supervisor of the job who is off duty
local OWNER, COOKJ, HIRED, CASHIER, CUSTOMER, MGR, OWN2, OFFJOB = 1, 2, 3, 4, 5, 6, 7, 8
local CIDS = { [OWNER] = 'OWN1', [COOKJ] = 'COOKJ', [HIRED] = 'HIRE1', [CASHIER] = 'CASH1', [CUSTOMER] = 'CUST1', [MGR] = 'MGR1', [OWN2] = 'OWN2', [OFFJOB] = 'OFFJ' }

local function player(src, job)
    local p = Mock.newPlayer(src, CIDS[src])
    p.PlayerData.job = job or { name = 'unemployed', onduty = true, grade = { level = 0 } }
    return p
end

BeforeEach = function()
    Mock.reset()
    FakeDB.reset()
    transfers, orderRows, recipeSaves = {}, {}, {}
    resetInventory()
    Mock.players, Mock.coords = {}, {}
    player(OWNER, { name = 'burgershot', onduty = true, isboss = true, grade = { level = 4 } })
    player(COOKJ, { name = 'burgershot', onduty = true, isboss = false, grade = { level = 1 } })
    for _, src in ipairs({ HIRED, CASHIER, CUSTOMER, MGR, OWN2 }) do player(src) end
    player(OFFJOB, { name = 'burgershot', onduty = false, isboss = false, grade = { level = 3 } })
    RestaurantData.employees[BID] = {
        HIRE1 = { citizenid = 'HIRE1', role = 'kitchen_staff' },
        CASH1 = { citizenid = 'CASH1', role = 'cashier' },
        MGR1 = { citizenid = 'MGR1', role = 'manager' },
        OWN2 = { citizenid = 'OWN2', role = 'owner' },
    }
    RestaurantData.employees[PZ] = { HIRE1 = { citizenid = 'HIRE1', role = 'employee' } }
    RestaurantData.shifts = {}
    RestaurantData.orders = {}
    RestaurantData.menus[BID] = {
        menu_burger = { menuItemId = 'menu_burger', recipeId = 'burger_classic', displayName = 'Classic', price = 10, enabled = true },
    }
    for _, station in pairs(RestaurantData.stations[BID]) do
        station.sessions = {}
        for _, slot in ipairs(station.slots) do slot.occupied, slot.session = false, nil end
    end
    for src in pairs(CIDS) do Mock.coords[src] = REGISTER end
end

local function targetsOf(name)
    local out = {}
    for _, e in ipairs(Mock.clientEventsNamed(name)) do out[#out + 1] = e.target end
    table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
    return out
end
local function list(t) return table.concat((function() local o = {} for i, v in ipairs(t) do o[i] = tostring(v) end return o end)(), ',') end
local function notes(src)
    local out = {}
    for _, e in ipairs(Mock.clientEventsNamed('QBCore:Notify')) do if e.target == src then out[#out + 1] = e.args[1] end end
    return table.concat(out, ' | ')
end
-- every string anywhere in a value, and every key, for "no ids in here" checks
local function scan(value, keys, strings)
    keys, strings = keys or {}, strings or {}
    if type(value) == 'table' then
        for k, v in pairs(value) do
            keys[tostring(k)] = true
            scan(v, keys, strings)
        end
    elseif type(value) == 'string' then
        strings[value] = true
    end
    return keys, strings
end
local function assertNoIds(value, where)
    local keys, strings = scan(value)
    for _, k in ipairs({ 'customerCid', 'customerSrc', 'cashierCid', 'cashierSrc', 'playerCid', 'playerSrc', 'consumed', 'qualitySnapshot', 'createdBy', 'updatedBy' }) do
        assert_false(keys[k], where .. ' has ' .. k)
    end
    for _, cid in pairs(CIDS) do assert_false(strings[cid], where .. ' carries the citizen id ' .. cid) end
end
local function clockIn(src, businessId)
    Mock.coords[src] = businessId == PZ and PZ_REGISTER or REGISTER
    Mock.fireNet('pf-restaurants:server:clockIn', src, businessId or BID)
end
local function cookBacon(src, slot)
    Mock.coords[src] = GRILL
    Mock.fireNet('pf-restaurants:server:startStationAction', src, BID, 'bs_grill_1', slot, { action = 'grill_bacon', inputItems = { { item = 'raw_bacon', qty = 2 } } })
end
local function sessionCount()
    local n = 0
    for _, st in pairs(RestaurantData.stations[BID]) do for _ in pairs(st.sessions) do n = n + 1 end end
    return n
end

describe('R2: a saved role counts only on shift', function()
    it('a hired cook off shift cannot cook; clocked in at a register they can', function()
        assert_eq(RoleOf(HIRED, BID), nil)
        cookBacon(HIRED, 1)
        assert_eq(sessionCount(), 0, 'no session off shift')
        assert_eq(stashes['restaurant-' .. BID .. '-fridge'].items[1].amount, 40, 'no stock taken')
        -- not at a register: refused
        Mock.coords[HIRED] = GRILL
        Mock.fireNet('pf-restaurants:server:clockIn', HIRED, BID)
        assert_false(ClockedIn(HIRED, BID, 'HIRE1'))
        assert_true(notes(HIRED):find('register', 1, true) ~= nil, notes(HIRED))
        clockIn(HIRED)
        assert_true(ClockedIn(HIRED, BID, 'HIRE1'))
        assert_eq(RoleOf(HIRED, BID), 'kitchen_staff')
        cookBacon(HIRED, 1)
        assert_eq(sessionCount(), 1)
        Mock.coords[HIRED] = REGISTER
        Mock.fireNet('pf-restaurants:server:clockOut', HIRED, BID)
        assert_eq(RoleOf(HIRED, BID), nil, 'clocked out')
    end)

    it('a cashier rings up only while clocked in', function()
        Mock.fireNet('pf-restaurants:server:createOrder', CASHIER, BID, { items = { { menuItemId = 'menu_burger', qty = 1 } }, paymentMethod = 'cash' })
        assert_eq(#transfers, 0, 'off shift: no sale')
        clockIn(CASHIER)
        Mock.fireNet('pf-restaurants:server:createOrder', CASHIER, BID, { items = { { menuItemId = 'menu_burger', qty = 1 } }, paymentMethod = 'cash' })
        assert_true(#transfers > 0, 'on shift: sold')
    end)

    it('management works off shift, floor work does not', function()
        for _, perm in ipairs({ 'menu.create', 'menu.edit', 'employee.manage', 'supplies.order', 'analytics.view', 'recipe.create' }) do
            assert_true(HasPermission(MGR, BID, perm), 'manager off shift: ' .. perm)
        end
        assert_false(HasPermission(MGR, BID, 'orders.void'), 'voiding is floor work')
        assert_false(HasPermission(MGR, BID, 'storage.access'))
        assert_true(Mock.selfExport('HasPermission')(OWN2, BID, 'premises.buy'), 'an owner buys premises equipment from home')
        assert_false(HasPermission(OWN2, BID, 'pos.use'))
        clockIn(MGR)
        assert_true(HasPermission(MGR, BID, 'orders.void'))
    end)

    it("the restaurant's job off duty: management yes, floor work after clocking in", function()
        assert_true(HasPermission(OFFJOB, BID, 'employee.view'))
        assert_false(HasPermission(OFFJOB, BID, 'pos.use'))
        assert_false(HasPermission(OFFJOB, BID, 'station.use'))
        clockIn(OFFJOB)
        assert_true(HasPermission(OFFJOB, BID, 'pos.use'))
        -- job staff on duty need no clock-in
        assert_true(HasPermission(COOKJ, BID, 'station.use'))
    end)

    it('a shift belongs to the server id and character that started it', function()
        clockIn(HIRED)
        -- the same character back on another server id: not on shift
        Mock.players[HIRED] = nil
        local p = Mock.newPlayer(20, 'HIRE1')
        p.PlayerData.job = { name = 'unemployed', onduty = true }
        Mock.coords[20] = GRILL
        assert_eq(RoleOf(20, BID), nil)
        -- another character on the old server id: not on shift either
        Mock.players[20] = nil
        player(HIRED)
        Mock.players[HIRED].PlayerData.citizenid = 'OTHER'
        assert_eq(RoleOf(HIRED, BID), nil)
    end)

    it('logout, disconnect or a character change ends the shift', function()
        clockIn(HIRED)
        clockIn(CASHIER)
        Mock.fireEvent('QBCore:Server:OnPlayerUnload', HIRED, HIRED)
        assert_false(ClockedIn(HIRED, BID, 'HIRE1'))
        assert_true(ClockedIn(CASHIER, BID, 'CASH1'), 'other staff stay on shift')
    end)

    it('away from the restaurant for LeaveMinutes: clocked out; a short trip is fine', function()
        clockIn(HIRED)
        Mock.coords[HIRED] = FAR
        SweepShifts()
        Mock.clock = Mock.clock + 5 * 60
        Mock.coords[HIRED] = GRILL
        SweepShifts()
        assert_true(ClockedIn(HIRED, BID, 'HIRE1'), 'back in time')
        Mock.coords[HIRED] = FAR
        SweepShifts()
        Mock.clock = Mock.clock + Config.Shifts.LeaveMinutes * 60
        SweepShifts()
        assert_false(ClockedIn(HIRED, BID, 'HIRE1'), 'gone too long')
        assert_true(notes(HIRED):find('clocked out', 1, true) ~= nil, notes(HIRED))
        -- a player who left the server is dropped from the shifts by the same check
        clockIn(CASHIER)
        Mock.players[CASHIER] = nil
        SweepShifts()
        assert_eq(RestaurantData.shifts[BID].CASH1, nil)
    end)

    it('one shift at a time: clocking in elsewhere ends the other', function()
        clockIn(HIRED, BID)
        clockIn(HIRED, PZ)
        assert_false(ClockedIn(HIRED, BID, 'HIRE1'))
        assert_true(ClockedIn(HIRED, PZ, 'HIRE1'))
    end)

    it('strangers cannot clock in', function()
        clockIn(CUSTOMER)
        assert_eq(next(RestaurantData.shifts[BID] or {}), nil)
    end)

    it('isEmployee tells staff off shift to clock in', function()
        local ok, data = Mock.callCallback('pf-restaurants:server:isEmployee', HIRED, BID)
        assert_false(ok)
        assert_true(data and data.offShift, 'offShift')
        ok, data = Mock.callCallback('pf-restaurants:server:isEmployee', CUSTOMER, BID)
        assert_false(ok)
        assert_eq(data, nil)
        clockIn(HIRED)
        ok, data = Mock.callCallback('pf-restaurants:server:isEmployee', HIRED, BID)
        assert_true(ok)
        assert_eq(data.role, 'kitchen_staff')
    end)

    it('an owner off shift still hires through the Job Board and the staff screen', function()
        local ok, why = Mock.selfExport('AddStaff')(BID, 'NEW9', 'cashier', 'OWN2')
        assert_true(ok, tostring(why))
        Mock.fireNet('pf-restaurants:server:addEmployee', OWN2, BID, 'NEW8', 'cashier')
        assert_eq(RestaurantData.employees[BID].NEW8.role, 'cashier')
        local list = Mock.callCallback('pf-restaurants:server:getEmployees', OWN2, BID)
        assert_true(list.HIRE1 ~= nil and list.HIRE1.onShift == false)
    end)
end)

describe('X3: stock stashes', function()
    it('kitchen staff on shift open them; a cashier never; nobody off shift', function()
        Mock.coords[HIRED] = FRIDGE
        Mock.fireNet('pf-restaurants:server:openStorage', HIRED, BID, 'fridge')
        assert_eq(#opened, 0, 'off shift')
        clockIn(HIRED)
        clockIn(CASHIER)
        Mock.coords[HIRED], Mock.coords[CASHIER] = FRIDGE, FRIDGE
        Mock.fireNet('pf-restaurants:server:openStorage', CASHIER, BID, 'fridge')
        assert_eq(#opened, 0, 'a cashier has no storage.access')
        Mock.fireNet('pf-restaurants:server:openStorage', HIRED, BID, 'fridge')
        assert_eq(#opened, 1)
        assert_eq(opened[1].id, 'restaurant-' .. BID .. '-fridge')
        -- still only at the stash
        Mock.coords[HIRED] = REGISTER
        Mock.fireNet('pf-restaurants:server:openStorage', HIRED, BID, 'fridge')
        assert_eq(#opened, 1)
        Mock.fireNet('pf-restaurants:server:openStorage', HIRED, BID, { 'fridge' })
        assert_eq(#opened, 1)
    end)
end)

describe('R1: orders reach the kitchen only, without ids', function()
    local function ringUp()
        clockIn(CASHIER)
        Mock.coords[CUSTOMER] = REGISTER
        Mock.fireNet('pf-restaurants:server:createOrder', CASHIER, BID, { items = { { menuItemId = 'menu_burger', qty = 2 } }, paymentMethod = 'card', customerId = CUSTOMER })
        local bill = Mock.clientEventsNamed('pf-restaurants:client:confirmPayment')[1].args[1]
        Mock.fireNet('pf-restaurants:server:answerPayment', CUSTOMER, bill.orderId, true)
        return bill.orderId
    end

    it('a new order goes to the staff on shift as a ticket: items, no ids, no payment', function()
        local orderId = ringUp()
        -- the owner and cook are on duty in the job, the cashier is clocked in; the hired cook is
        -- off shift and the customer is not staff
        assert_eq(list(targetsOf('pf-restaurants:client:newOrder')), list({ OWNER, COOKJ, CASHIER }))
        local ticket = Mock.clientEventsNamed('pf-restaurants:client:newOrder')[1].args[2]
        assert_eq(ticket.orderId, orderId)
        assert_eq(ticket.items[1].displayName, 'Classic')
        assert_eq(ticket.items[1].qty, 2)
        assert_true(ticket.placedAt ~= nil)
        assertNoIds(ticket, 'the ticket')
        for _, k in ipairs({ 'paymentMethod', 'total', 'subtotal', 'tax' }) do assert_eq(ticket[k], nil, k) end
    end)

    it('status updates go to the same staff only', function()
        local orderId = ringUp()
        Mock.reset()
        Mock.coords[COOKJ] = GRILL
        Mock.fireNet('pf-restaurants:server:updateOrderStatus', COOKJ, orderId, 'preparing')
        assert_eq(list(targetsOf('pf-restaurants:client:orderStatusUpdate')), list({ OWNER, COOKJ, CASHIER }))
    end)

    it('the open tickets and the order history carry no ids', function()
        ringUp()
        local active = Mock.callCallback('pf-restaurants:server:getActiveOrders', COOKJ, BID)
        assert_eq(#active, 1)
        assertNoIds(active, 'active orders')
        assert_eq(#Mock.callCallback('pf-restaurants:server:getActiveOrders', HIRED, BID), 0, 'off shift: none')
        local history = Mock.callCallback('pf-restaurants:server:getOrderHistory', MGR, BID)
        assert_eq(#history, 1)
        assertNoIds(history, 'order history')
        assert_eq(history[1].total, 20, 'the books keep the amounts')
    end)
end)

describe('R1 / X5: cooking sessions', function()
    it('a session goes to the staff on shift as a public session with the server clock', function()
        cookBacon(COOKJ, 1)
        assert_eq(list(targetsOf('pf-restaurants:client:stationSessionStart')), list({ OWNER, COOKJ }))
        local session = Mock.clientEventsNamed('pf-restaurants:client:stationSessionStart')[1].args[4]
        assertNoIds(session, 'the session')
        assert_eq(session.serverNow, os.time())
        assert_eq(session.startTime, os.time())
        assert_eq(session.duration, 25000)
        assert_eq(session.stationId, 'bs_grill_1')
        local synced = Mock.callCallback('pf-restaurants:server:getStationSessions', OWNER, BID)
        assert_true(synced[session.sessionId] ~= nil)
        assertNoIds(synced, 'getStationSessions')
        assert_eq(next(Mock.callCallback('pf-restaurants:server:getStationSessions', CUSTOMER, BID)), nil, 'not staff: nothing')
        Mock.fireNet('pf-restaurants:server:syncStations', CUSTOMER)
        local stations = Mock.clientEventsNamed('pf-restaurants:client:syncStations')[1].args[1]
        assertNoIds(stations, 'syncStations')
        assert_true(stations[BID].bs_grill_1.slots[1].occupied)
    end)

    it('with no slot given the first free slot is used; "Take off" finds the cook\'s own dish', function()
        cookBacon(COOKJ, 0)
        cookBacon(COOKJ, 0)
        local grill = RestaurantData.stations[BID].bs_grill_1
        assert_true(grill.slots[1].occupied and grill.slots[2].occupied)
        -- someone else cannot take it off
        Mock.coords[OWNER] = GRILL
        Mock.clock = Mock.clock + 26
        Mock.fireNet('pf-restaurants:server:takeOffStation', OWNER, BID, 'bs_grill_1')
        assert_eq(#given, 0)
        Mock.fireNet('pf-restaurants:server:takeOffStation', COOKJ, BID, 'bs_grill_1')
        assert_eq(#given, 1)
        assert_eq(given[1].item, 'bacon_cooked')
        assert_eq(sessionCount(), 1)
    end)

    it('the end of a session reaches the cook even after clocking out', function()
        clockIn(HIRED)
        cookBacon(HIRED, 1)
        RestaurantData.shifts[BID].HIRE1 = nil              -- clocked out (or left) meanwhile
        Mock.clock = Mock.clock + 26
        Mock.fireNet('pf-restaurants:server:takeOffStation', HIRED, BID, 'bs_grill_1')
        assert_eq(#given, 1, 'their own dish')
        local targets = targetsOf('pf-restaurants:client:stationSessionEnd')
        assert_true(list(targets):find(tostring(HIRED), 1, true) ~= nil, list(targets))
        for _, t in ipairs(targets) do assert_true(t ~= -1, 'not broadcast') end
    end)
end)

describe('X4: custom recipes', function()
    local function create()
        Mock.fireNet('pf-restaurants:server:createRecipe', OWN2, BID, { label = 'Stack', components = { { item = 'burger_bun', qty = 1 } }, output = { item = 'burger_bun' } })
        for id, r in pairs(RestaurantData.recipes) do if r.businessId == BID then return id end end
    end

    it('keeps the citizen id, not a platform identifier, and broadcasts nothing', function()
        local id = create()
        assert_true(id ~= nil, 'created by an owner off shift (management)')
        assert_eq(RestaurantData.recipes[id].createdBy, 'OWN2')
        Mock.fireNet('pf-restaurants:server:updateRecipe', MGR, id, { label = 'Big Stack' })
        assert_eq(RestaurantData.recipes[id].updatedBy, 'MGR1')
        assert_true(recipeSaves[#recipeSaves]:find('"updatedBy":"MGR1"', 1, true) ~= nil, 'saved with the change')
        for _, e in ipairs(Mock.clientEvents) do
            assert_true(e.name ~= 'pf-restaurants:client:recipeUpdate' and e.name ~= 'pf-restaurants:client:recipeDeleted', e.name)
            assert_false(json.encode(e.args):find('license:', 1, true), 'a platform identifier went to a client: ' .. e.name)
        end
        RestaurantData.recipes[id] = nil
    end)

    it("only the restaurant's staff read its custom recipes, without who made them", function()
        local id = create()
        local mine = Mock.callCallback('pf-restaurants:server:getRecipes', MGR, BID)
        assert_true(mine[id] ~= nil, 'staff (off shift) see it')
        assertNoIds(mine[id], 'the recipe')
        assert_true(mine.burger_classic ~= nil, 'and the built-in ones')
        local theirs = Mock.callCallback('pf-restaurants:server:getRecipes', CUSTOMER, BID)
        assert_eq(theirs[id], nil)
        assert_true(theirs.burger_classic ~= nil, 'built-in recipes are public')
        assert_eq(Mock.callCallback('pf-restaurants:server:getRecipe', CUSTOMER, id), nil)
        local one = Mock.callCallback('pf-restaurants:server:getRecipe', MGR, id)
        assert_eq(one.label, 'Stack')
        assert_eq(one.createdBy, nil)
        -- another restaurant's recipe is not on this menu
        RestaurantData.recipes[id].businessId = PZ
        Mock.fireNet('pf-restaurants:server:createMenuItem', MGR, BID, { recipeId = id, price = 5 })
        for _, item in pairs(RestaurantData.menus[BID]) do assert_true(item.recipeId ~= id) end
        RestaurantData.recipes[id] = nil
    end)
end)
