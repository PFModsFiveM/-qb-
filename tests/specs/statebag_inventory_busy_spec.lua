-- pfm-inventory, sv_stateBagStrictMode: `inv_busy` is written by the server only. It is true while
-- the server has the player's inventory open, while logged out, or while the player holds an
-- action lock it asked for ('qb-inventory:server:setActionBusy'). A client can add or drop its
-- own lock, never clear the server's open-inventory flag; bad requests change nothing.
load_resource('tests/lua/fivem_mocks.lua')
Config = nil
load_resource('pfm-inventory/config/config.lua')
load_resource('pfm-inventory/config/freshness.lua')
load_resource('pfm-inventory/server/freshness.lua')
load_resource('pfm-inventory/server/main.lua')
load_resource('pfm-inventory/server/functions.lua')
load_resource('pfm-inventory/server/hooks.lua')
local vehicleAnswer = {}
QBCoreMock.Functions.TriggerClientCallback = function(_, _, cb) cb(vehicleAnswer[1], vehicleAnswer[2]) end
load_resource('pfm-inventory/server/commands.lua')

local ME, OTHER, LOGGEDOUT = 1, 2, 9

local function busy(src) return Player(src).state.inv_busy end
local function ask(src, reason, value) Mock.fireNet('qb-inventory:server:setActionBusy', src, reason, value) end
local function openCount(src)
    local n = 0
    for _, e in ipairs(Mock.clientEventsNamed('qb-inventory:client:openInventory')) do
        if e.target == src then n = n + 1 end
    end
    return n
end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    Mock.clock = Mock.clock + 100000           -- a fresh rate window and no lock left from before
    Mock.newPlayer(ME)
    Mock.newPlayer(OTHER)
    for _, src in ipairs({ ME, OTHER, LOGGEDOUT }) do
        Mock.fireEvent('playerDropped', src)   -- forget server-side busy state of earlier tests
        Player(src).state.inv_busy = false
    end
    PurgeExpiredBusyLocks()
end

describe('action locks a client asks for', function()
    it('a lock makes the player busy and the inventory key refuses to open', function()
        ask(ME, 'weed', true)
        assert_eq(busy(ME), true)
        OpenInventory(ME)
        assert_eq(openCount(ME), 0, 'refused while planting')
        ask(ME, 'weed', false)
        assert_eq(busy(ME), false)
        OpenInventory(ME)
        assert_eq(openCount(ME), 1)
    end)

    it('one lock released leaves the others held; only the asker is affected', function()
        ask(ME, 'weed', true)
        ask(ME, 'cornerselling', true)
        ask(ME, 'weed', false)
        assert_eq(busy(ME), true, 'cornerselling still held')
        assert_eq(busy(OTHER), false, 'another player is untouched')
        ask(ME, 'cornerselling', false)
        assert_eq(busy(ME), false)
    end)

    it('bad requests change nothing', function()
        ask(ME, 'weed', 'yes')                    -- not a boolean
        ask(ME, 42, true)                         -- not a name
        ask(ME, '', true)
        ask(ME, string.rep('a', 33), true)        -- too long
        ask(ME, 'we ed', true)                    -- bad characters
        ask(ME, 'weed\n', true)
        ask(LOGGEDOUT, 'weed', true)              -- no character loaded
        assert_eq(busy(ME), false)
        assert_eq(busy(LOGGEDOUT), false)
    end)

    it('requests beyond the rate limit are ignored', function()
        for i = 1, 30 do ask(ME, 'spam', i % 2 == 1) end   -- 30 accepted, ending released
        assert_eq(busy(ME), false)
        ask(ME, 'spam', true)                               -- the 31st in the window
        assert_eq(busy(ME), false, 'ignored')
        Mock.clock = Mock.clock + 11
        ask(ME, 'spam', true)
        assert_eq(busy(ME), true, 'a new window')
    end)

    it('a player holds at most 8 locks', function()
        for i = 1, 9 do ask(ME, 'lock' .. i, true) end
        for i = 1, 8 do ask(ME, 'lock' .. i, false) end
        assert_eq(busy(ME), false, 'the ninth was never taken')
    end)

    it('a lock the client never released ends after 30 minutes', function()
        ask(ME, 'cornerselling', true)
        Mock.clock = Mock.clock + 29 * 60
        PurgeExpiredBusyLocks()
        assert_eq(busy(ME), true)
        Mock.clock = Mock.clock + 2 * 60
        PurgeExpiredBusyLocks()
        assert_eq(busy(ME), false)
    end)

    it('the client cannot release a lock taken by server code', function()
        assert_true(SetBusyLock(ME, 'robbery', true))
        ask(ME, 'robbery', false)
        assert_eq(busy(ME), true, 'client locks are separate from server locks')
        SetBusyLock(ME, 'robbery', false)
        assert_eq(busy(ME), false)
    end)
end)

describe('the server owns the open-inventory flag', function()
    it('an open inventory makes the player busy, and the client cannot clear it', function()
        OpenInventory(ME)
        assert_eq(openCount(ME), 1)
        assert_eq(busy(ME), true)
        ask(ME, 'weed', true)
        ask(ME, 'weed', false)
        assert_eq(busy(ME), true, 'still open on the server')
        OpenInventory(ME)
        assert_eq(openCount(ME), 1, 'no second inventory while one is open')
        Mock.fireNet('qb-inventory:server:closeInventory', ME, nil)
        assert_eq(busy(ME), false)
    end)

    it('closing an inventory keeps an action lock the player holds', function()
        ask(ME, 'harness', true)
        CloseInventory(ME)
        assert_eq(busy(ME), true)
        ask(ME, 'harness', false)
        assert_eq(busy(ME), false)
    end)

    it('a searched player is busy until the search closes', function()
        OpenInventoryById(OTHER, ME)
        assert_eq(busy(ME), true)
        Mock.fireNet('qb-inventory:server:closeInventory', OTHER, 'otherplayer-' .. ME)
        assert_eq(busy(ME), false)
    end)
end)

describe('login and logout (the client used to set these itself)', function()
    it('logout makes the player busy, the next character load clears every lock', function()
        ask(ME, 'cornerselling', true)
        Mock.fireEvent('QBCore:Server:OnPlayerUnload', ME, ME)
        assert_eq(busy(ME), true)
        Mock.fireEvent('QBCore:Server:PlayerLoaded', ME, Mock.players[ME])
        assert_eq(busy(ME), false, 'no lock carried over')
    end)

    it('the inventory client no longer writes inv_busy', function()
        local src = __readfile('pfm-inventory/client/main.lua')
        assert_false(src:find("state:set('inv_busy'", 1, true), 'no client write left')
    end)
end)
