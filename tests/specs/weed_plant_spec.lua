-- pfm-weed: plants go only into a house the player holds keys for, and only when that can be checked.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/fake_db.lua')
QBCore = QBCoreMock
Lang = Lang or { t = function(_, k) return k end }
CreateThread = function() end

local planted = 0
local seeds = 0
local housesState, keyResult = 'started', true
function GetResourceState(name) if name == 'pfm-houses' then return housesState end return 'started' end
Mock.exportsByResource['pfm-houses'] = {
    hasKey = function() if keyResult == 'error' then error('boom') end return keyResult end,
}
Mock.exportsByResource['pfm-inventory'] = {
    RemoveItem = function() if seeds < 1 then return false end seeds = seeds - 1 return true end,
}
FakeDB.extraPatterns = {
    { 'INSERT INTO house_plants', function() planted = planted + 1 return 1 end },
}

load_resource('pfm-weed/config.lua')
load_resource('pfm-weed/server/main.lua')

local P = 1
local SPOT = vector3(100.0, 200.0, 30.0)
local function plant() Mock.fireNet('qb-weed:server:placePlant', P, json.encode({ x = SPOT.x, y = SPOT.y, z = SPOT.z }), 'ogkush', 'house_one') end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords = {}, {}
    Mock.newPlayer(P)
    Mock.coords[P] = SPOT
    planted, seeds, housesState, keyResult = 0, 1, 'started', true
end

describe('weed planting', function()
    it('works in a house you hold keys for', function()
        plant()
        assert_eq(planted, 1)
        assert_eq(seeds, 0)
    end)
    it('is refused without keys, with pfm-houses stopped, or when the key check errors', function()
        keyResult = false
        plant()
        housesState, keyResult = 'stopped', true
        plant()
        housesState, keyResult = 'started', 'error'
        plant()
        assert_eq(planted, 0)
        assert_eq(seeds, 1)
    end)
end)
