-- pfm-houserobbery and pfm-bankrobbery: loot only after the real steps happened on the server
-- (tools used up, minigame time passed, player in place), never from a bare client event.
load_resource('tests/lua/fivem_mocks.lua')

-- items players hold, and an inventory export that works on them
Inv = {}
local function count(src, item) return (Inv[src] and Inv[src][item]) or 0 end
local function give(src, item, n) Inv[src] = Inv[src] or {}; Inv[src][item] = count(src, item) + (n or 1) end
Mock.exportsByResource['pfm-inventory'] = {
    AddItem = function(_, src, item, n) give(src, item, n or 1); return true end,
    RemoveItem = function(_, src, item, n)
        n = n or 1
        if count(src, item) < n then return false end
        Inv[src][item] = count(src, item) - n
        return true
    end,
    GetItemByName = function(_, src, item) if count(src, item) > 0 then return { name = item, amount = count(src, item) } end end,
}
-- reward tables name many items the mock list does not have
setmetatable(QBCoreMock.Shared.Items, { __index = function(_, k) return { name = k, label = k, unique = false } end })

load_resource('pfm-houserobbery/config.lua')
load_resource('pfm-houserobbery/server/main.lua')
load_resource('pfm-bankrobbery/sh_config.lua')
load_resource('pfm-bankrobbery/sv_config.lua')
Config.OnRobberyStart, Config.OnRobberyTimeoutEnd, Config.OnBlackout, Config.OnPoliceCameraHit = function() end, function() end, function() end, function() end
load_resource('pfm-bankrobbery/server/main.lua')

local ROBBER, OTHER = 1, 2
local HOUSE = 'perfectdrive1'
local function at(src, c) Mock.coords[src] = vector3(c.x, c.y, c.z) end
local function lootCount(src)
    local n = 0
    for item, k in pairs(Inv[src] or {}) do
        if item ~= 'lockpick' and item ~= 'advancedlockpick' and item ~= 'screwdriverset' and item ~= 'drill'
            and item ~= 'electronickit' and item ~= 'trojan_usb' and not item:find('security_card') then n = n + k end
    end
    return n
end
local function fire(name, src, ...) Mock.fireNet(name, src, ...) end

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 10000
    Mock.players, Mock.coords, Inv = {}, {}, {}
    for _, src in ipairs({ ROBBER, OTHER }) do
        local p = Mock.newPlayer(src)
        p.Functions.GetItemByName = function(item) if count(src, item) > 0 then return { name = item, amount = count(src, item) } end end
        p.PlayerData.job = { name = 'unemployed', type = 'none', onduty = false }
    end
    -- house state from earlier tests
    for _, h in pairs(Config.Houses) do
        h.opened = false
        for _, f in pairs(h.furniture) do f.searched = false; f.isBusy = false end
    end
    math.randomseed(7)
end

describe('house robbery', function()
    local door = function() return Config.Houses[HOUSE].coords end

    it('a bare "enter house" event no longer opens a house', function()
        at(ROBBER, door())
        fire('qb-houserobbery:server:enterHouse', ROBBER, HOUSE)
        assert_false(Config.Houses[HOUSE].opened)
    end)
    it('without a lockpick the attempt does not count', function()
        at(ROBBER, door())
        fire('qb-houserobbery:server:startLockpick', ROBBER, HOUSE)
        Mock.clock = Mock.clock + 5
        fire('qb-houserobbery:server:enterHouse', ROBBER, HOUSE)
        assert_false(Config.Houses[HOUSE].opened)
    end)
    it('a picked lock opens the house once the minigame had time, at the door only', function()
        give(ROBBER, 'advancedlockpick')
        at(ROBBER, door())
        fire('qb-houserobbery:server:startLockpick', ROBBER, HOUSE)
        fire('qb-houserobbery:server:enterHouse', ROBBER, HOUSE)        -- instantly: refused
        assert_false(Config.Houses[HOUSE].opened)
        fire('qb-houserobbery:server:startLockpick', ROBBER, HOUSE)
        Mock.clock = Mock.clock + 5
        fire('qb-houserobbery:server:enterHouse', ROBBER, HOUSE)
        assert_true(Config.Houses[HOUSE].opened)
    end)
    it('only players who got in can search, and each piece pays once', function()
        give(ROBBER, 'advancedlockpick')
        at(ROBBER, door()); at(OTHER, door())
        fire('qb-houserobbery:server:startLockpick', ROBBER, HOUSE)
        Mock.clock = Mock.clock + 5
        fire('qb-houserobbery:server:enterHouse', ROBBER, HOUSE)
        fire('qb-houserobbery:server:searchFurniture', OTHER, 1, HOUSE)   -- never went in
        assert_eq(lootCount(OTHER), 0)
        assert_false(Config.Houses[HOUSE].furniture[1].searched)
        fire('qb-houserobbery:server:searchFurniture', ROBBER, 1, HOUSE)
        assert_true(Config.Houses[HOUSE].furniture[1].searched)
        local after = lootCount(ROBBER)
        for _ = 1, 20 do fire('qb-houserobbery:server:searchFurniture', ROBBER, 1, HOUSE) end
        assert_eq(lootCount(ROBBER), after)
    end)
    it('busy flags cannot be set by players who are not inside', function()
        fire('qb-houserobbery:server:SetBusyState', OTHER, 1, HOUSE, true)
        assert_false(Config.Houses[HOUSE].furniture[1].isBusy)
    end)
end)

describe('bank robbery', function()
    local fleeca = next(Config.SmallBanks)
    local panel = function() return Config.SmallBanks[fleeca].coords end
    local locker1 = function() return Config.SmallBanks[fleeca].lockers[1].coords end

    local function resetBanks()
        for _, b in pairs(Config.SmallBanks) do b.isOpened = false; for _, l in pairs(b.lockers) do l.isOpened = false; l.isBusy = false end end
        for _, b in pairs(Config.BigBanks) do b.isOpened = false; for _, l in pairs(b.lockers or {}) do l.isOpened = false; l.isBusy = false end end
    end

    it('a bare "open bank" event opens nothing', function()
        resetBanks()
        at(ROBBER, panel())
        fire('qb-bankrobbery:server:setBankState', ROBBER, fleeca)
        assert_false(Config.SmallBanks[fleeca].isOpened)
    end)
    it('the hack uses up the kit and USB, and opens the bank after it had time to run', function()
        resetBanks()
        give(ROBBER, 'electronickit'); give(ROBBER, 'trojan_usb')
        at(ROBBER, panel())
        fire('qb-bankrobbery:server:removeElectronicKit', ROBBER)
        assert_eq(count(ROBBER, 'electronickit'), 0)
        assert_eq(count(ROBBER, 'trojan_usb'), 0)
        Mock.clock = Mock.clock + 10
        fire('qb-bankrobbery:server:setBankState', ROBBER, fleeca)
        assert_true(Config.SmallBanks[fleeca].isOpened)
        -- the alarm went out from the server
        assert_true(#Mock.clientEventsNamed('qb-bankrobbery:client:robberyCall') >= 1)
    end)
    it('clients can no longer mark lockers opened; looting needs the full crack time', function()
        -- (the bank from the previous test is open; robberies run one at a time)
        at(ROBBER, locker1())
        fire('qb-bankrobbery:server:setLockerState', ROBBER, fleeca, 1, 'isOpened', true)
        assert_false(Config.SmallBanks[fleeca].lockers[1].isOpened)
        fire('qb-bankrobbery:server:recieveItem', ROBBER, 'small', fleeca, 1)
        assert_eq(lootCount(ROBBER), 0)
        fire('qb-bankrobbery:server:setLockerState', ROBBER, fleeca, 1, 'isBusy', true)
        Mock.clock = Mock.clock + 5
        fire('qb-bankrobbery:server:recieveItem', ROBBER, 'small', fleeca, 1)   -- too fast
        assert_eq(lootCount(ROBBER), 0)
        Mock.clock = Mock.clock + 30
        fire('qb-bankrobbery:server:recieveItem', ROBBER, 'small', fleeca, 1)
        assert_true(lootCount(ROBBER) > 0)
        assert_true(Config.SmallBanks[fleeca].lockers[1].isOpened)
        local got = lootCount(ROBBER)
        fire('qb-bankrobbery:server:recieveItem', ROBBER, 'small', fleeca, 1)
        assert_eq(lootCount(ROBBER), got)
    end)
    it('Paleto opens only with a security card, which the server uses up', function()
        local paleto = Config.BigBanks.paleto.coords
        at(OTHER, paleto)
        fire('qb-bankrobbery:server:setBankState', OTHER, 'paleto')
        assert_false(Config.BigBanks.paleto.isOpened)
    end)
    it('power stations are blown only right after thermite was used there', function()
        local key = next(Config.PowerStations)
        at(OTHER, Config.PowerStations[key].coords)
        fire('qb-bankrobbery:server:SetStationStatus', OTHER, key, true)
        assert_false(Config.PowerStations[key].hit == true)
        give(OTHER, 'thermite')
        local ok = Mock.callCallback('thermite:server:check', OTHER)
        assert_true(ok)
        fire('qb-bankrobbery:server:SetStationStatus', OTHER, key, true)
        assert_true(Config.PowerStations[key].hit)
        fire('qb-bankrobbery:server:SetStationStatus', OTHER, key, false)  -- players cannot restore power
        assert_true(Config.PowerStations[key].hit)
    end)
end)
