-- pfm-inventory: a search of another player holds its own busy lock on the searched player. It used
-- to set the searched player's open-inventory flag, which stayed set forever when the searcher
-- disconnected or walked away: the searched player could not open their inventory until relog.
-- Now the search lock ends on close, on the searcher's drop or logout, when the searched player
-- leaves, and when the searcher walks out of reach; the searched player's other locks stay.
load_resource('tests/lua/fivem_mocks.lua')
Config = nil
load_resource('pfm-inventory/config/config.lua')
load_resource('pfm-inventory/config/freshness.lua')
load_resource('pfm-inventory/server/freshness.lua')
load_resource('pfm-inventory/server/main.lua')
load_resource('pfm-inventory/server/functions.lua')
load_resource('pfm-inventory/server/hooks.lua')

local TARGET, COP, ROBBER = 1, 2, 3

local function busy(src) return Player(src).state.inv_busy end
local function openCount(src)
    local n = 0
    for _, e in ipairs(Mock.clientEventsNamed('qb-inventory:client:openInventory')) do
        if e.target == src then n = n + 1 end
    end
    return n
end
local function closedFor(src)
    local n = 0
    for _, e in ipairs(Mock.clientEventsNamed('qb-inventory:client:closeInv')) do
        if e.target == src then n = n + 1 end
    end
    return n
end
local function closeSearch(viewer, target)
    Mock.fireNet('qb-inventory:server:closeInventory', viewer, 'otherplayer-' .. target)
end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    Mock.coords = {}
    Mock.clock = Mock.clock + 100000
    for _, src in ipairs({ TARGET, COP, ROBBER }) do Mock.newPlayer(src) end
    for _, src in ipairs({ TARGET, COP, ROBBER }) do
        Mock.fireEvent('playerDropped', src)   -- forget server-side state of earlier tests
        Player(src).state.inv_busy = false
    end
    for k in pairs(InventoryViewers) do InventoryViewers[k] = nil end
    PurgeExpiredBusyLocks()
    Mock.reset()                               -- drop the events the cleanup sent
    -- everyone stands together
    Mock.coords[TARGET] = vector3(0, 0, 0)
    Mock.coords[COP] = vector3(1, 0, 0)
    Mock.coords[ROBBER] = vector3(0, 1, 0)
end

describe('a search lock on the searched player', function()
    it('ends when the searcher disconnects mid-search', function()
        OpenInventoryById(COP, TARGET)
        assert_eq(busy(TARGET), true)
        Mock.players[COP] = nil
        Mock.fireEvent('playerDropped', COP)
        assert_eq(busy(TARGET), false, 'no longer locked once the searcher is gone')
        assert_eq(InventoryViewers[TARGET], nil)
        OpenInventory(TARGET)
        assert_eq(openCount(TARGET), 1, 'the searched player opens their own inventory again')
    end)

    it("the searcher's drop leaves the searched player's other locks", function()
        assert_true(SetBusyLock(TARGET, 'robbery', true))
        OpenInventoryById(COP, TARGET)
        Mock.players[COP] = nil
        Mock.fireEvent('playerDropped', COP)
        assert_eq(busy(TARGET), true, 'the robbery lock is not the search')
        SetBusyLock(TARGET, 'robbery', false)
        assert_eq(busy(TARGET), false)
    end)

    it('closing the search releases only its own lock', function()
        Mock.fireNet('qb-inventory:server:setActionBusy', TARGET, 'harness', true)
        OpenInventoryById(COP, TARGET)
        closeSearch(COP, TARGET)
        assert_eq(InventoryViewers[TARGET], nil)
        assert_eq(busy(TARGET), true, 'the harness lock stays')
        Mock.fireNet('qb-inventory:server:setActionBusy', TARGET, 'harness', false)
        assert_eq(busy(TARGET), false)
    end)

    it('another player cannot close a search they are not making', function()
        OpenInventoryById(COP, TARGET)
        closeSearch(ROBBER, TARGET)
        assert_eq(busy(TARGET), true)
        assert_eq(InventoryViewers[TARGET], COP)
    end)

    it('ends on the minute check when the searcher walked away', function()
        OpenInventoryById(COP, TARGET)
        Mock.coords[COP] = vector3(4, 0, 0)
        CheckInventorySearches()
        assert_eq(busy(TARGET), true, 'still within reach')
        Mock.coords[COP] = vector3(40, 0, 0)
        CheckInventorySearches()
        assert_eq(busy(TARGET), false)
        assert_eq(InventoryViewers[TARGET], nil)
        assert_eq(closedFor(COP), 1, "the searcher's window is closed")
    end)

    it('ends when the searched player tries to open an inventory after the searcher walked away', function()
        OpenInventoryById(COP, TARGET)
        OpenInventory(TARGET)
        assert_eq(openCount(TARGET), 0, 'refused while searched from beside them')
        Mock.coords[COP] = vector3(40, 0, 0)
        OpenInventory(TARGET)
        assert_eq(openCount(TARGET), 1)
    end)

    it("the searcher's next item move after walking away is refused and ends the search", function()
        Mock.players[TARGET].PlayerData.items = { [1] = { name = 'water', amount = 1, slot = 1, info = {} } }
        OpenInventoryById(COP, TARGET)
        Mock.coords[COP] = vector3(40, 0, 0)
        Mock.fireNet('qb-inventory:server:SetInventoryData', COP, 'otherplayer-' .. TARGET, 'player', 1, 1, 1, 1)
        assert_eq(Mock.players[TARGET].PlayerData.items[1] ~= nil, true, 'nothing taken from afar')
        assert_eq(InventoryViewers[TARGET], nil)
        assert_eq(busy(TARGET), false)
    end)

    it('an admin search opened from afar is not range bound, and still ends on drop', function()
        Mock.coords[COP] = vector3(500, 0, 0)
        OpenInventoryById(COP, TARGET)
        CheckInventorySearches()
        assert_eq(busy(TARGET), true)
        Mock.players[COP] = nil
        Mock.fireEvent('playerDropped', COP)
        assert_eq(busy(TARGET), false)
    end)

    it('a long search keeps its lock past the 30 minute lock limit', function()
        OpenInventoryById(COP, TARGET)
        for _ = 1, 40 do
            Mock.clock = Mock.clock + 60
            PurgeExpiredBusyLocks()
            CheckInventorySearches()
        end
        assert_eq(busy(TARGET), true, 'renewed while the search is valid')
        closeSearch(COP, TARGET)
        assert_eq(busy(TARGET), false)
    end)

    it('ends when the searcher logs out', function()
        OpenInventoryById(COP, TARGET)
        Mock.fireEvent('QBCore:Server:OnPlayerUnload', COP, COP)
        assert_eq(busy(TARGET), false)
        assert_eq(InventoryViewers[TARGET], nil)
    end)

    it('the searched player leaving closes the search for the searcher', function()
        OpenInventoryById(COP, TARGET)
        Mock.players[TARGET] = nil
        Mock.fireEvent('playerDropped', TARGET)
        assert_eq(InventoryViewers[TARGET], nil)
        assert_eq(closedFor(COP), 1)
    end)

    it('a new search by the same searcher releases the previous one', function()
        OpenInventoryById(COP, TARGET)
        OpenInventoryById(COP, ROBBER)
        assert_eq(busy(TARGET), false)
        assert_eq(busy(ROBBER), true)
        assert_eq(InventoryViewers[TARGET], nil)
        assert_eq(InventoryViewers[ROBBER], COP)
    end)

    it('a second searcher takes over; the first one cannot release it any more', function()
        OpenInventoryById(COP, TARGET)
        OpenInventoryById(ROBBER, TARGET)
        assert_eq(InventoryViewers[TARGET], ROBBER)
        assert_eq(closedFor(COP), 1)
        closeSearch(COP, TARGET)
        assert_eq(busy(TARGET), true)
        Mock.players[ROBBER] = nil
        Mock.fireEvent('playerDropped', ROBBER)
        assert_eq(busy(TARGET), false)
    end)

    it('a searcher who leaves during the opening wait never locks the target', function()
        local realWait = Wait
        Wait = function() Mock.players[COP] = nil; Mock.fireEvent('playerDropped', COP) end
        OpenInventoryById(COP, TARGET)
        Wait = realWait
        assert_eq(InventoryViewers[TARGET], nil)
        assert_eq(busy(TARGET), false)
    end)
end)
