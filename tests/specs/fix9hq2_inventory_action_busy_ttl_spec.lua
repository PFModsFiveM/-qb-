-- pfm-inventory: a client's own action lock may carry a time to live,
-- 'qb-inventory:server:setActionBusy'(reason, busy, ttlSeconds) with ttlSeconds an optional number
-- 1..600 (default: the 30 minute safety net). The progress bar uses it so a bar whose client never
-- sends the release (crash, resource stop) does not keep the inventory blocked for half an hour.
-- A bad ttl makes the request change nothing; the lock still ends on release, logout and
-- disconnect, and the TTL is honoured on time (not only at the next minute sweep).
load_resource('tests/lua/fivem_mocks.lua')
Config = nil
load_resource('pfm-inventory/config/config.lua')
load_resource('pfm-inventory/config/freshness.lua')
load_resource('pfm-inventory/server/freshness.lua')
load_resource('pfm-inventory/server/main.lua')
load_resource('pfm-inventory/server/functions.lua')
load_resource('pfm-inventory/server/hooks.lua')

local ME, OTHER, COP = 1, 2, 3

-- SetTimeout as FiveM runs it: the callback after `ms`, on the mocked clock (seconds)
local timers = {}
SetTimeout = function(ms, fn) timers[#timers + 1] = { at = Mock.clock + ms / 1000, fn = fn } end
local function advance(seconds)
    Mock.clock = Mock.clock + seconds
    local due = {}
    for i = #timers, 1, -1 do
        if timers[i].at <= Mock.clock then due[#due + 1] = timers[i]; table.remove(timers, i) end
    end
    table.sort(due, function(a, b) return a.at < b.at end)
    for _, t in ipairs(due) do t.fn() end
end

local function busy(src) return Player(src).state.inv_busy end
local function ask(src, reason, value, ttl) Mock.fireNet('qb-inventory:server:setActionBusy', src, reason, value, ttl) end
local function openCount(src)
    local n = 0
    for _, e in ipairs(Mock.clientEventsNamed('qb-inventory:client:openInventory')) do
        if e.target == src then n = n + 1 end
    end
    return n
end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords = {}, {}
    Mock.clock = Mock.clock + 100000           -- a fresh rate window, every earlier lock expired
    for _, src in ipairs({ ME, OTHER, COP }) do Mock.newPlayer(src) end
    for _, src in ipairs({ ME, OTHER, COP }) do
        Mock.fireEvent('playerDropped', src)
        Player(src).state.inv_busy = false
    end
    for k in pairs(InventoryViewers) do InventoryViewers[k] = nil end
    PurgeExpiredBusyLocks()
    timers = {}
    Mock.reset()
    Mock.coords[ME], Mock.coords[COP] = vector3(0, 0, 0), vector3(1, 0, 0)
end

describe('setActionBusy with a time to live', function()
    it('a lock with a ttl holds for that long and ends on time without the minute sweep', function()
        ask(ME, 'progressbar', true, 5)
        assert_eq(busy(ME), true)
        advance(5)
        assert_eq(busy(ME), true, 'still held at its ttl')
        OpenInventory(ME)
        assert_eq(openCount(ME), 0, 'the inventory key is refused while the bar runs')
        advance(2)
        assert_eq(busy(ME), false, 'the timer ended it (no PurgeExpiredBusyLocks call)')
        OpenInventory(ME)
        assert_eq(openCount(ME), 1)
    end)

    it('without a ttl the lock keeps the 30 minute safety net', function()
        ask(ME, 'progressbar', true)
        assert_eq(#timers, 0, 'no short timer for the default')
        advance(29 * 60)
        PurgeExpiredBusyLocks()
        assert_eq(busy(ME), true)
        advance(2 * 60)
        PurgeExpiredBusyLocks()
        assert_eq(busy(ME), false)
    end)

    it('the bounds 1 and 600 are accepted; a fraction is rounded up to whole seconds', function()
        ask(ME, 'a', true, 1)
        ask(ME, 'b', true, 600)
        ask(ME, 'c', true, 2.5)
        assert_eq(busy(ME), true)
        advance(2)
        PurgeExpiredBusyLocks()
        assert_eq(busy(ME), true, 'b and c still held')
        advance(1)
        PurgeExpiredBusyLocks()
        assert_eq(busy(ME), true, 'c rounded up to 3 s, b still held')
        advance(597)
        PurgeExpiredBusyLocks()
        assert_eq(busy(ME), true, 'b holds its full 600 s')
        advance(2)
        assert_eq(busy(ME), false)
    end)

    it('a bad ttl makes the request change nothing', function()
        local nan = 0 / 0
        for _, bad in ipairs({ 0, 0.5, -5, 601, 1e9, math.huge, -math.huge, nan, '30', 'abc', true, {} }) do
            ask(ME, 'progressbar', true, bad)
        end
        assert_eq(busy(ME), false, 'no lock was taken')
        assert_eq(#timers, 0)
        -- and none of them counted: a lock with a good ttl is still taken
        ask(ME, 'progressbar', true, 10)
        assert_eq(busy(ME), true)
    end)

    it('a release always works, whatever ttl comes with it', function()
        ask(ME, 'progressbar', true, 60)
        ask(ME, 'progressbar', false, 'junk')
        assert_eq(busy(ME), false)
        ask(ME, 'progressbar', true, 60)
        ask(ME, 'progressbar', false, 9999)
        assert_eq(busy(ME), false)
    end)

    it('taking the lock again replaces its ttl, and the old timer does not end the new lock', function()
        ask(ME, 'progressbar', true, 5)
        advance(3)
        ask(ME, 'progressbar', true, 10)          -- a second bar started before the first ended
        advance(4)                                -- the first lock's timer has run
        assert_eq(busy(ME), true, 'the new lock is still held')
        advance(8)
        assert_eq(busy(ME), false, 'ended at the new ttl')
    end)

    it('a ttl lock ends on disconnect and on logout', function()
        ask(ME, 'progressbar', true, 300)
        Mock.players[ME] = nil
        Mock.fireEvent('playerDropped', ME)
        -- (FiveM drops the state bag with the player; recompute it to see what the server still holds)
        SetInventoryBusy(ME, false)
        assert_eq(busy(ME), false, 'gone on disconnect')
        Mock.newPlayer(ME)
        ask(ME, 'progressbar', true, 300)
        Mock.fireEvent('QBCore:Server:OnPlayerUnload', ME, ME)
        Mock.fireEvent('QBCore:Server:PlayerLoaded', ME, Mock.players[ME])
        assert_eq(busy(ME), false, 'the next character starts without it')
        advance(400)                              -- its timer finds nothing to do
        assert_eq(busy(ME), false)
    end)

    it("a ttl lock is the player's own: other locks and players are untouched", function()
        assert_true(SetBusyLock(ME, 'robbery', true))
        ask(ME, 'progressbar', true, 3)
        ask(OTHER, 'progressbar', true, 300)
        advance(5)
        assert_eq(busy(ME), true, 'the server lock stays after the bar lock ends')
        assert_eq(busy(OTHER), true)
        SetBusyLock(ME, 'robbery', false)
        assert_eq(busy(ME), false)
    end)

    it('server code still sets its own ttl through the export path', function()
        assert_true(SetBusyLock(ME, 'job', true, 20))
        advance(19)
        assert_eq(busy(ME), true)
        advance(3)
        assert_eq(busy(ME), false)
    end)
end)

describe('client locks cannot crowd out server locks', function()
    it('a player holding the maximum of client locks can still be searched', function()
        for i = 1, 8 do ask(ME, 'lock' .. i, true, 600) end
        ask(ME, 'lock9', true, 600)
        OpenInventoryById(COP, ME)
        assert_eq(InventoryViewers[ME], COP, 'the search opened (it used to fail on the lock limit)')
        assert_eq(openCount(COP), 1)
        Mock.fireNet('qb-inventory:server:closeInventory', COP, 'otherplayer-' .. ME)
        for i = 1, 9 do ask(ME, 'lock' .. i, false) end
        assert_eq(busy(ME), false, 'the ninth client lock was never taken')
    end)
end)
