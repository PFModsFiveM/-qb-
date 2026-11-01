-- pfm-inventory player search, batch 13b:
-- (a) Every search is range bound, decided before the 1.5 s opening wait: to the caller's own limit
--     (police search and robbery pass 2.5 m), never more than 5 m. Only the admin menu, recognised
--     by the resource that called the export, searches from any distance. A searcher who steps back
--     during the wait gets no search; one who walks off later loses it within seconds and can no
--     longer move the target's items. (Reach used to be decided after the wait, so a searcher who
--     stepped back during it got a search with no reach at all.)
-- (b) The searched player's own open paths (the real inventory key command, the hotbar key, drop
--     bags, shops, the backpack) free them at once from a search whose searcher walked off. (The inventory key
--     returned on inv_busy before the stale search was ever checked.)
-- (c) The search takes its lock before the wait and closes the target's own windows; while it holds
--     them they cannot move, drop, give or use their items. Every failure path releases the lock.
load_resource('tests/lua/fivem_mocks.lua')

-- keep the resource's threads so the search check loop can be run by hand
local threads = {}
CreateThread = function(fn) threads[#threads + 1] = fn end

-- the inventory key asks the client which vehicle storage it is at; nil = none
QBCoreMock.Functions.TriggerClientCallback = function(_, _, cb) cb(nil) end
local used = {}
QBCoreMock.Functions.CanUseItem = function(name)
    return { func = function(src) used[#used + 1] = { src = src, name = name } end }
end

Config = nil
load_resource('pfm-inventory/config/config.lua')
load_resource('pfm-inventory/config/freshness.lua')
load_resource('pfm-inventory/server/freshness.lua')
load_resource('pfm-inventory/server/main.lua')
load_resource('pfm-inventory/server/functions.lua')
load_resource('pfm-inventory/server/hooks.lua')
load_resource('pfm-inventory/server/commands.lua')
load_resource('pfm-inventory/server/backpack.lua')

local TARGET, COP, ROBBER = 1, 2, 3

-- the loop whose wait is the short search check (the other loops wait a minute or more)
local searchThread, searchThreadMs
do
    local realWait = Wait
    for _, fn in ipairs(threads) do
        local ms
        Wait = function(m) ms = m error('stop') end
        pcall(fn)
        if ms and ms <= 5000 then searchThread, searchThreadMs = fn, ms end
    end
    Wait = realWait
end
local function runSearchCheckOnce()
    assert_true(searchThread ~= nil, 'a short search check loop exists')
    local realWait, calls = Wait, 0
    Wait = function() calls = calls + 1 if calls > 1 then error('stop') end end
    pcall(searchThread)
    Wait = realWait
end

local function busy(src) return Player(src).state.inv_busy end
local function count(name, src)
    local n = 0
    for _, e in ipairs(Mock.clientEventsNamed(name)) do
        if e.target == src then n = n + 1 end
    end
    return n
end
local function openCount(src) return count('qb-inventory:client:openInventory', src) end
local function closedFor(src) return count('qb-inventory:client:closeInv', src) end
local function searchWindows(src)
    local n = 0
    for _, e in ipairs(Mock.clientEventsNamed('qb-inventory:client:openInventory')) do
        local other = e.args[2]
        if e.target == src and type(other) == 'table' and tostring(other.name):find('^otherplayer%-') then n = n + 1 end
    end
    return n
end
-- runs `fn` once, inside the next opening wait
local function duringWait(fn)
    local realWait = Wait
    Wait = function() Wait = realWait fn() end
end
local function move(src, from, to, fromSlot, toSlot, amount)
    Mock.fireNet('qb-inventory:server:SetInventoryData', src, from, to, fromSlot, toSlot, amount, amount)
end
local function key(src, name) Mock.rawCommands[name](src) end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords = {}, {}
    Mock.clock = Mock.clock + 100000
    Mock.invokingResource = nil
    for _, src in ipairs({ TARGET, COP, ROBBER }) do Mock.newPlayer(src) end
    for _, src in ipairs({ TARGET, COP, ROBBER }) do
        Mock.fireEvent('playerDropped', src)
        Player(src).state.inv_busy = false
    end
    for k in pairs(InventoryViewers) do InventoryViewers[k] = nil end
    for k in pairs(Drops) do Drops[k] = nil end
    for k in pairs(Inventories) do Inventories[k] = nil end
    PurgeExpiredBusyLocks()
    used = {}
    Mock.reset()
    Mock.coords[TARGET] = vector3(0, 0, 0)
    Mock.coords[COP] = vector3(1, 0, 0)
    Mock.coords[ROBBER] = vector3(0, 1, 0)
    Mock.players[TARGET].PlayerData.items = {
        [1] = { name = 'water_bottle', amount = 2, slot = 1, info = {}, type = 'item', weight = 500 },
        [2] = { name = 'lockpick', amount = 1, slot = 2, info = {}, type = 'item', weight = 300 },
    }
end

describe('(a) range binding is decided before the opening wait', function()
    it('a searcher who steps back during the wait gets no search at all', function()
        duringWait(function() Mock.coords[COP] = vector3(6, 0, 0) end)
        assert_eq(OpenInventoryById(COP, TARGET), false)
        assert_eq(searchWindows(COP), 0, 'no window opened')
        assert_eq(InventoryViewers[TARGET], nil)
        assert_eq(busy(TARGET), false, 'the target is free')
        assert_eq(closedFor(COP), 0, 'no stray close for a window that never opened')
    end)

    it('the probe case: stepped back to 6 m during the wait, then 200 m away, cannot loot', function()
        duringWait(function() Mock.coords[COP] = vector3(6, 0, 0) end)
        OpenInventoryById(COP, TARGET)
        Mock.coords[COP] = vector3(200, 0, 0)
        move(COP, 'otherplayer-' .. TARGET, 'player', 1, 1, 2)
        assert_true(Mock.players[TARGET].PlayerData.items[1] ~= nil, 'nothing taken from afar')
        assert_eq(busy(TARGET), false)
    end)

    it("the caller's own limit binds the whole search (police: 2.5 m)", function()
        assert_eq(OpenInventoryById(COP, TARGET, { reach = 2.5 }), true)
        Mock.coords[COP] = vector3(2.4, 0, 0)
        assert_true(CheckInventorySearch(TARGET), 'still within 2.5 m')
        Mock.coords[COP] = vector3(3, 0, 0)       -- within the old 5 m, beyond the caller's limit
        move(COP, 'otherplayer-' .. TARGET, 'player', 1, 1, 2)
        assert_eq(Mock.players[TARGET].PlayerData.items[1].amount, 2, 'nothing taken beyond 2.5 m')
        assert_eq(InventoryViewers[TARGET], nil, 'the search ended')
        assert_eq(busy(TARGET), false)
        assert_eq(closedFor(COP), 1, "the searcher's window is closed")
    end)

    it("the caller's limit is checked at the start too; a refused search touches nothing", function()
        Mock.coords[COP] = vector3(3, 0, 0)
        OpenInventory(TARGET)                      -- the target has their own inventory open
        Mock.reset()
        assert_eq(OpenInventoryById(COP, TARGET, { reach = 2.5 }), false)
        assert_eq(InventoryViewers[TARGET], nil)
        assert_eq(closedFor(TARGET), 0, "the target's window stays open")
        assert_eq(busy(TARGET), true, 'only their own window keeps them busy')
        Mock.fireNet('qb-inventory:server:closeInventory', TARGET, nil)
        assert_eq(busy(TARGET), false)
    end)

    it('a caller cannot widen the reach past 5 m; bad limits fall back to 5 m', function()
        Mock.coords[COP] = vector3(6, 0, 0)
        for _, reach in ipairs({ 1000, math.huge, -1, 0, 0 / 0, '100', true }) do
            assert_eq(OpenInventoryById(COP, TARGET, { reach = reach }), false, 'refused at 6 m: ' .. tostring(reach))
        end
        assert_eq(OpenInventoryById(COP, TARGET, 1000), false, 'a bare number is not a limit table')
        assert_eq(busy(TARGET), false)
        Mock.coords[COP] = vector3(4, 0, 0)
        assert_eq(OpenInventoryById(COP, TARGET, { reach = 1000 }), true)
        Mock.coords[COP] = vector3(5.5, 0, 0)
        assert_eq(CheckInventorySearch(TARGET), false, 'capped at 5 m')
    end)

    it('a resource other than the admin menu cannot search from afar', function()
        Mock.coords[COP] = vector3(500, 0, 0)
        Mock.invokingResource = 'pf-somejob'
        assert_eq(OpenInventoryById(COP, TARGET), false)
        Mock.invokingResource = nil
        assert_eq(OpenInventoryById(COP, TARGET), false, 'nor code with no invoking resource')
        assert_eq(InventoryViewers[TARGET], nil)
        assert_eq(busy(TARGET), false)
    end)

    it('the admin menu searches from any distance; a limit it passes still binds', function()
        Mock.coords[COP] = vector3(500, 0, 0)
        Mock.invokingResource = 'pfm-adminmenu'
        assert_eq(OpenInventoryById(COP, TARGET), true)
        Mock.invokingResource = nil
        CheckInventorySearches()
        runSearchCheckOnce()
        assert_eq(InventoryViewers[TARGET], COP, 'not range bound')
        Mock.fireNet('qb-inventory:server:closeInventory', COP, 'otherplayer-' .. TARGET)
        Mock.coords[COP] = vector3(1, 0, 0)
        Mock.invokingResource = 'pfm-adminmenu'
        assert_eq(OpenInventoryById(COP, TARGET, { reach = 2.5 }), true)
        Mock.invokingResource = nil
        Mock.coords[COP] = vector3(3, 0, 0)
        assert_eq(CheckInventorySearch(TARGET), false)
    end)

    it('the calling resource is read before the wait', function()
        Mock.invokingResource = 'pf-somejob'
        duringWait(function()
            Mock.invokingResource = 'pfm-adminmenu'  -- whatever runs during the wait changes nothing
            Mock.coords[COP] = vector3(500, 0, 0)
        end)
        assert_eq(OpenInventoryById(COP, TARGET), false)
        Mock.invokingResource = nil
        assert_eq(busy(TARGET), false)
    end)

    it('the search check loop ends a walked-off search within seconds', function()
        assert_true(searchThreadMs ~= nil and searchThreadMs <= 5000, 'checked every few seconds')
        OpenInventoryById(COP, TARGET)
        runSearchCheckOnce()
        assert_eq(InventoryViewers[TARGET], COP, 'a valid search stays')
        Mock.coords[TARGET] = vector3(0, 40, 0)   -- the searched player walked off
        runSearchCheckOnce()
        assert_eq(InventoryViewers[TARGET], nil)
        assert_eq(busy(TARGET), false)
        assert_eq(closedFor(COP), 1)
    end)
end)

describe("(b) the searched player's own open paths free them from a stale search", function()
    it('the inventory key (the real command) frees them at once', function()
        OpenInventoryById(COP, TARGET)
        Mock.coords[COP] = vector3(40, 0, 0)
        key(TARGET, 'inventory')
        assert_eq(InventoryViewers[TARGET], nil, 'the stale search ended')
        assert_eq(openCount(TARGET), 1, 'and their inventory opened on the same key press')
        assert_eq(closedFor(COP), 1)
    end)

    it('the inventory key is refused while the search is valid', function()
        OpenInventoryById(COP, TARGET)
        key(TARGET, 'inventory')
        assert_eq(openCount(TARGET), 0)
        assert_eq(InventoryViewers[TARGET], COP)
    end)

    it('the hotbar key frees them too', function()
        OpenInventoryById(COP, TARGET)
        key(TARGET, 'hotbar')
        assert_eq(count('qb-inventory:client:hotbar', TARGET), 0, 'refused while searched')
        Mock.coords[COP] = vector3(40, 0, 0)
        key(TARGET, 'hotbar')
        assert_eq(InventoryViewers[TARGET], nil)
        assert_eq(count('qb-inventory:client:hotbar', TARGET), 1)
    end)

    it('a drop bag cannot be opened while searched; trying frees a stale search', function()
        Drops['drop-77'] = { name = 'drop-77', label = 'Drop', items = {}, entityId = 77, createdTime = os.time(),
            coords = vector3(0, 0, 0), maxweight = 1000, slots = 10, isOpen = false }
        OpenInventoryById(COP, TARGET)
        Mock.fireNet('qb-inventory:server:openDrop', TARGET, 'drop-77')
        assert_eq(Drops['drop-77'].isOpen, false, 'refused while searched')
        Mock.coords[COP] = vector3(40, 0, 0)
        Mock.fireNet('qb-inventory:server:openDrop', TARGET, 'drop-77')
        assert_eq(InventoryViewers[TARGET], nil)
        assert_eq(Drops['drop-77'].isOpen, TARGET)
    end)

    it('the backpack stays shut while searched; asking frees a stale search', function()
        Mock.players[TARGET].PlayerData.items[3] = { name = 'backpack', amount = 1, slot = 3, info = { identifier = 'BP1' }, type = 'item' }
        OpenInventoryById(COP, TARGET)
        assert_eq(Mock.callCallback('qb-inventory:server:getBackpack', TARGET), nil)
        assert_eq(Inventories['backpack-BP1'], nil, 'not opened')
        Mock.coords[COP] = vector3(40, 0, 0)
        local bp = Mock.callCallback('qb-inventory:server:getBackpack', TARGET)
        assert_eq(InventoryViewers[TARGET], nil)
        assert_eq(bp and bp.name, 'backpack-BP1')
    end)

    it('a shop cannot be opened while searched; trying frees a stale search', function()
        RegisteredShops['testshop'] = { name = 'testshop', label = 'Test', slots = 0, items = {} }
        OpenInventoryById(COP, TARGET)
        OpenShop(TARGET, 'testshop')
        assert_eq(openCount(TARGET), 0)
        Mock.coords[COP] = vector3(40, 0, 0)
        OpenShop(TARGET, 'testshop')
        assert_eq(InventoryViewers[TARGET], nil)
        assert_eq(openCount(TARGET), 1)
        RegisteredShops['testshop'] = nil
    end)
end)

describe("(c) the lock is taken before the wait and the target's windows close", function()
    it('the searched player cannot open their inventory during the opening wait', function()
        local busyDuring
        duringWait(function()
            busyDuring = busy(TARGET)
            OpenInventory(TARGET)
            key(TARGET, 'inventory')
        end)
        assert_eq(OpenInventoryById(COP, TARGET), true)
        assert_eq(busyDuring, true, 'locked before the wait')
        assert_eq(openCount(TARGET), 0, 'their own inventory never opened')
        assert_eq(searchWindows(COP), 1)
    end)

    it('their own open inventory closes when the search starts', function()
        OpenInventory(TARGET)
        assert_eq(OpenInventoryById(COP, TARGET), true)
        assert_eq(closedFor(TARGET), 1)
        Mock.fireNet('qb-inventory:server:closeInventory', COP, 'otherplayer-' .. TARGET)
        assert_eq(busy(TARGET), false, 'free once the search closes, without their own close')
    end)

    it('an open stash or drop of theirs closes too', function()
        Inventories['stash-hide'] = { items = {}, isOpen = TARGET, label = 'Hide', maxweight = 100000, slots = 10 }
        OpenInventoryById(COP, TARGET)
        assert_eq(closedFor(TARGET), 1)
        Mock.fireNet('qb-inventory:server:closeInventory', COP, 'otherplayer-' .. TARGET)
        Inventories['stash-hide'] = nil
        Mock.reset()
        Drops['drop-78'] = { name = 'drop-78', items = {}, entityId = 78, createdTime = os.time(), coords = vector3(0, 0, 0), isOpen = TARGET }
        OpenInventoryById(COP, TARGET)
        assert_eq(closedFor(TARGET), 1)
    end)

    it('a search the target was making closes for them', function()
        OpenInventoryById(TARGET, ROBBER)
        assert_eq(InventoryViewers[ROBBER], TARGET)
        Mock.reset()
        OpenInventoryById(COP, TARGET)
        assert_eq(InventoryViewers[ROBBER], nil)
        assert_eq(busy(ROBBER), false)
        assert_eq(closedFor(TARGET), 1)
    end)

    it('nothing is closed for a target who has nothing open (their other NUI keeps focus)', function()
        OpenInventoryById(COP, TARGET)
        assert_eq(closedFor(TARGET), 0)
    end)

    it('while searched they cannot move, drop, give or use their own items', function()
        Inventories['stash-hide'] = { items = {}, isOpen = TARGET, label = 'Hide', maxweight = 100000, slots = 10 }
        OpenInventoryById(COP, TARGET)
        -- a modified client that ignored the close still claims the stash open
        move(TARGET, 'player', 'stash-hide', 1, 1, 2)
        move(TARGET, 'player', 'player', 1, 5, 2)
        assert_eq(Mock.players[TARGET].PlayerData.items[1].amount, 2, 'nothing moved')
        assert_eq(next(Inventories['stash-hide'].items), nil)
        assert_eq(Mock.callCallback('qb-inventory:server:createDrop', TARGET, { fromSlot = 1, amount = 1 }), false)
        assert_eq(next(Drops), nil, 'nothing dropped')
        assert_eq(Mock.callCallback('qb-inventory:server:giveItem', TARGET, ROBBER, 'water_bottle', 1, 1), false)
        Mock.fireNet('qb-inventory:server:useItem', TARGET, { slot = 2 })
        assert_eq(#used, 0, 'nothing used')
        assert_eq(Mock.players[TARGET].PlayerData.items[1].amount, 2)
        -- the searcher still takes what they find
        move(COP, 'otherplayer-' .. TARGET, 'player', 2, 1, 1)
        assert_eq(Mock.players[TARGET].PlayerData.items[2], nil, 'the searcher took the lockpick')
        -- once the search ends, the player uses their inventory again
        Mock.fireNet('qb-inventory:server:closeInventory', COP, 'otherplayer-' .. TARGET)
        move(TARGET, 'player', 'stash-hide', 1, 1, 2)
        assert_eq(Mock.players[TARGET].PlayerData.items[1], nil, 'moved after the search')
    end)

    it('a hook refusing the search releases the lock', function()
        local hooks = Events.InventoryOpened.hooks
        hooks[#hooks + 1] = { fn = function() return false end, resource = 'spec' }
        assert_eq(OpenInventoryById(COP, TARGET), false)
        hooks[#hooks] = nil
        assert_eq(InventoryViewers[TARGET], nil)
        assert_eq(busy(TARGET), false)
    end)

    it('the target leaving during the wait: nothing opens, nothing held', function()
        duringWait(function()
            Mock.players[TARGET] = nil
            Mock.fireEvent('playerDropped', TARGET)
        end)
        assert_eq(OpenInventoryById(COP, TARGET), false)
        assert_eq(searchWindows(COP), 0)
        assert_eq(InventoryViewers[TARGET], nil)
        assert_eq(closedFor(COP), 0)
    end)

    it('the target logging out during the wait: nothing opens, nothing held', function()
        duringWait(function() Mock.fireEvent('QBCore:Server:OnPlayerUnload', TARGET, TARGET) end)
        assert_eq(OpenInventoryById(COP, TARGET), false)
        assert_eq(searchWindows(COP), 0)
        assert_eq(InventoryViewers[TARGET], nil)
    end)

    it('the searcher opening their own inventory during the wait: no search window, target free', function()
        duringWait(function() OpenInventory(COP) end)
        assert_eq(OpenInventoryById(COP, TARGET), false)
        assert_eq(searchWindows(COP), 0)
        assert_eq(openCount(COP), 1, 'only their own inventory')
        assert_eq(busy(TARGET), false)
    end)

    it('a search window that fails to build releases the target', function()
        local real = ItemsForClient
        ItemsForClient = function() error('bad item') end
        local ok, opened = pcall(OpenInventoryById, COP, TARGET)
        ItemsForClient = real
        assert_true(ok, 'the error is contained')
        assert_eq(opened, false)
        assert_eq(InventoryViewers[TARGET], nil)
        assert_eq(busy(TARGET), false)
    end)

    it('search pressed twice during the wait opens one window', function()
        duringWait(function() OpenInventoryById(COP, TARGET) end)
        assert_eq(OpenInventoryById(COP, TARGET), false, 'the first one was replaced')
        assert_eq(searchWindows(COP), 1)
        assert_eq(InventoryViewers[TARGET], COP)
        assert_eq(busy(TARGET), true)
    end)

    it('another searcher taking over during the wait keeps their search', function()
        duringWait(function() OpenInventoryById(ROBBER, TARGET) end)
        assert_eq(OpenInventoryById(COP, TARGET), false)
        assert_eq(searchWindows(COP), 0)
        assert_eq(searchWindows(ROBBER), 1)
        assert_eq(InventoryViewers[TARGET], ROBBER)
        assert_eq(busy(TARGET), true)
    end)

    it('a player held by a search cannot search anyone; nobody searches themselves', function()
        OpenInventoryById(ROBBER, COP)
        assert_eq(OpenInventoryById(COP, TARGET), false)
        assert_eq(busy(TARGET), false)
        assert_eq(OpenInventoryById(TARGET, TARGET), false)
        assert_eq(InventoryViewers[TARGET], nil)
    end)
end)
