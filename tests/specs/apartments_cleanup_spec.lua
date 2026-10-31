-- pfm-apartments and a deleted character: pfm-core passes the names of the apartments it deleted;
-- each one's stash is emptied (pfm-inventory ClearStash and its inventories row), names that are not
-- apartment ids are ignored, and a new apartment never gets an id whose stash still exists.
load_resource('tests/lua/fivem_mocks.lua')
function GetResourceState(name) return name == 'pfm-inventory' and 'started' or 'missing' end

local deletedStash, stashes, cleared = {}, {}, {}
local apartments = {}
MySQL.query = setmetatable({ await = function(sql, params)
    if sql:find('DELETE FROM inventories WHERE identifier = ?', 1, true) then
        deletedStash[#deletedStash + 1] = params[1]
        stashes[params[1]] = nil
        return { affectedRows = 1 }
    end
    if sql:find('SELECT COUNT(*) as count FROM inventories WHERE identifier = ?', 1, true) then
        return { { count = stashes[params[1]] and 1 or 0 } }
    end
    if sql:find('SELECT COUNT(*) as count FROM apartments WHERE name = ?', 1, true) then
        return { { count = apartments[params[1]] and 1 or 0 } }
    end
    if sql:find('SELECT name FROM apartments WHERE citizenid = ?', 1, true) then return {} end
    return {}
end }, { __call = function() return {} end })
local inserted = {}
MySQL.insert = setmetatable({ await = function() return 1 end }, { __call = function(_, sql, params) inserted[#inserted + 1] = params return 1 end })
Mock.exportsByResource['pfm-inventory'] = { ClearStash = function(_, id) cleared[#cleared + 1] = id end }

Config = nil
load_resource('pfm-apartments/config.lua')
load_resource('pfm-apartments/server/main.lua')

local function fire(...) Mock.eventHandlers['pfm-core:server:characterDeleted'](...) end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    deletedStash, cleared, inserted = {}, {}, {}
end

describe("a deleted character's apartment", function()
    it('has its stash emptied, for each apartment name pfm-core passes', function()
        stashes.apartment1123456 = true
        fire('CID9', { apartments = { 'apartment1123456', 'apartment3777' } })
        assert_eq(#cleared, 2)
        assert_eq(cleared[1], 'apartment1123456')
        assert_eq(deletedStash[1], 'apartment1123456')
        assert_eq(deletedStash[2], 'apartment3777')
        assert_eq(stashes.apartment1123456, nil)
    end)
    it('ignores names that are not apartment ids, and calls without the list', function()
        fire('CID9', { apartments = { 'policetrash', 'apartment1x', 'apartment1', "apartment1'; DROP TABLE x", 42, string.rep('apartment1', 10) .. '1' } })
        fire('CID9')                              -- the old one-argument event
        fire('CID9', 'apartment1123')
        fire('CID9', { apartments = 'apartment1123' })
        fire('', { apartments = { 'apartment1123' } })
        assert_eq(#cleared, 0)
        assert_eq(#deletedStash, 0)
    end)
    it('a new apartment skips an id whose stash still exists', function()
        local p = Mock.newPlayer(1, 'NEWCID')
        p.PlayerData.metadata.inside = { apartment = {} }
        stashes.apartment1500 = true                  -- left over from an old character
        local rolls = { 500, 501 }
        local realRandom = math.random
        math.random = function(a, b) if a == 1 and b == 1000000 then return table.remove(rolls, 1) end return realRandom(a, b) end
        Mock.fireNet('apartments:server:CreateApartment', 1, 'apartment1', 'South Rockford Drive', false)
        math.random = realRandom
        assert_eq(#inserted, 1)
        assert_eq(inserted[1][1], 'apartment1501')
    end)
end)
