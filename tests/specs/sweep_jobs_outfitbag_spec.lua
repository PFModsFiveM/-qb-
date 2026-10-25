-- pf-outfitbag: picking a bag up returns only a bag the player put down (addItem used to hand out an
-- outfit bag on every call), and only the bag's owner can read or change its outfits.
-- (The resource registers its net events as RegisterNetEvent(name) + AddEventHandler, so they are fired with Mock.fireEvent.)
load_resource('tests/lua/fivem_mocks.lua')
QBCore = QBCoreMock

local outfits = {}   -- [id] = { id, bag_id, outfit_name, outfit_data }
local nextId = 1
local function dbFind(query)
    if query:find('SELECT %* FROM outfitbag_outfits WHERE bag_id') then return 'select' end
    if query:find('INSERT INTO outfitbag_outfits') then return 'insert' end
    if query:find('DELETE FROM outfitbag_outfits') then return 'delete' end
    if query:find('UPDATE outfitbag_outfits') then return 'update' end
end
local function db(query, p)
    local kind = dbFind(query)
    if kind == 'select' then
        local out = {}
        for _, o in pairs(outfits) do if o.bag_id == p[1] then out[#out + 1] = o end end
        return out
    elseif kind == 'insert' then
        outfits[nextId] = { id = nextId, bag_id = p[1], outfit_name = p[2], outfit_data = p[3] }
        nextId = nextId + 1
        return nextId - 1
    elseif kind == 'delete' then
        local o = outfits[p[1]]
        if o and (p[2] == nil or o.bag_id == p[2]) then outfits[p[1]] = nil; return 1 end
        return 0
    elseif kind == 'update' then
        local o = outfits[p[2]]
        if o and (p[3] == nil or o.bag_id == p[3]) then o.outfit_name = p[1]; return 1 end
        return 0
    end
end
local function op() return setmetatable({ await = db }, { __call = function(_, q, p) return db(q, p) end }) end
MySQL = { query = op(), insert = op(), update = op() }

Config = nil
load_resource('[pfscripts]/pf-outfitbag/config.lua')
load_resource('[pfscripts]/pf-outfitbag/server/server.lua')
load_resource('[pfscripts]/pf-outfitbag/server/item.lua')

local OWNER, OTHER = 1, 2
local added
local function useBag(src, bagId)
    Mock.useables[Config.ItemName](src, { name = Config.ItemName, slot = 1, info = { bag_id = bagId } })
end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    outfits, nextId, added = {}, 1, {}
    for _, src in ipairs({ OWNER, OTHER }) do
        local p = Mock.newPlayer(src)
        p.Functions.AddItem = function(name, amount, _, info) added[#added + 1] = { src = src, name = name, info = info }; return true end
        p.Functions.RemoveItem = function() return true end
        PlacedOutfitBags[src] = nil
    end
end

describe('pf-outfitbag', function()
    it('addItem gives nothing without a bag put down (it used to spawn bags)', function()
        Mock.fireEvent('pf-outfitbag:addItem', OTHER, 'made-up-bag')
        Mock.fireEvent('pf-outfitbag:addItem', OTHER, 'made-up-bag')
        assert_eq(#added, 0)
    end)

    it('picking up a placed bag returns that bag once', function()
        useBag(OWNER, 'bag-1')
        Mock.fireEvent('pf-outfitbag:addItem', OWNER, 'bag-1')
        Mock.fireEvent('pf-outfitbag:addItem', OWNER, 'bag-1')
        assert_eq(#added, 1)
        assert_eq(added[1].info.bag_id, 'bag-1')
    end)

    it("another player cannot read, delete or rename a bag's outfits", function()
        useBag(OWNER, 'bag-1')
        Mock.fireEvent('pf-outfitbag:saveOutfit', OWNER, 'bag-1', 'Work', { torso = 1 })
        assert_eq(outfits[1].outfit_name, 'Work')
        assert_eq(#Mock.callCallback('pf-outfitbag:getOutfits', OTHER, 'bag-1'), 0)
        Mock.fireEvent('pf-outfitbag:deleteOutfit', OTHER, 'bag-1', 1)
        Mock.fireEvent('pf-outfitbag:renameOutfit', OTHER, 'bag-1', 1, 'Mine now')
        assert_eq(outfits[1].outfit_name, 'Work')
        -- an outfit id from another bag does not work through one's own bag either
        useBag(OTHER, 'bag-2')
        Mock.fireEvent('pf-outfitbag:deleteOutfit', OTHER, 'bag-2', 1)
        assert_true(outfits[1] ~= nil)
    end)

    it('the owner manages their outfits; oversized names and data are refused', function()
        useBag(OWNER, 'bag-1')
        Mock.fireEvent('pf-outfitbag:saveOutfit', OWNER, 'bag-1', string.rep('x', 500), { torso = 1 })
        Mock.fireEvent('pf-outfitbag:saveOutfit', OWNER, 'bag-1', 'Big', { junk = string.rep('x', 20000) })
        assert_eq(next(outfits), nil)
        Mock.fireEvent('pf-outfitbag:saveOutfit', OWNER, 'bag-1', 'Work', { torso = 1 })
        assert_eq(#Mock.callCallback('pf-outfitbag:getOutfits', OWNER, 'bag-1'), 1)
        Mock.fireEvent('pf-outfitbag:renameOutfit', OWNER, 'bag-1', 1, 'Duty')
        assert_eq(outfits[1].outfit_name, 'Duty')
        Mock.fireEvent('pf-outfitbag:deleteOutfit', OWNER, 'bag-1', 1)
        assert_eq(outfits[1], nil)
    end)
end)
