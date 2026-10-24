-- pfm-vineyard: a new vine for every pick, and wine and juice only after their processing time.
load_resource('tests/lua/fivem_mocks.lua')
Inv = {}
Mock.exportsByResource['pfm-inventory'] = {
    AddItem = function(_, src, item, n) Inv[item] = (Inv[item] or 0) + (n or 1) return true end,
    RemoveItem = function(_, src, item, n) Inv[item] = (Inv[item] or 0) - (n or 1) return true end,
}
load_resource('pfm-vineyard/config.lua')
load_resource('pfm-vineyard/server.lua')

local W = 1
local VINE1, VINE2 = vector3(-1875.41, 2100.37, 138.86), vector3(-1908.69, 2107.48, 131.31)

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 1000
    Mock.gameTimer = Mock.gameTimer + 60000
    Mock.players, Mock.coords, Inv = {}, {}, {}
    local p = Mock.newPlayer(W)
    p.PlayerData.job = { name = 'vineyard', onduty = true }
    p.GetItemByName = function(item) if (Inv[item] or 0) > 0 then return { name = item, amount = Inv[item] } end end
    Mock.fireEvent('playerDropped', W)
end

describe('vineyard', function()
    it('one vine pays once; the next pick needs another vine', function()
        Mock.coords[W] = VINE1
        Mock.fireNet('qb-vineyard:server:getGrapes', W)
        local first = Inv.grape or 0
        assert_true(first > 0)
        Mock.gameTimer = Mock.gameTimer + 60000
        Mock.fireNet('qb-vineyard:server:getGrapes', W)
        assert_eq(Inv.grape, first)
        Mock.coords[W] = VINE2
        Mock.fireNet('qb-vineyard:server:getGrapes', W)
        assert_true(Inv.grape > first)
    end)
    it('wine comes out only after the wine timer', function()
        Inv.grapejuice = 23
        Mock.coords[W] = Config.Vineyard.wine.coords
        assert_true(Mock.callCallback('qb-vineyard:server:loadIngredients', W))
        Mock.fireNet('qb-vineyard:server:receiveWine', W)
        assert_eq(Inv.wine, nil)
        Mock.clock = Mock.clock + Config.wineTimer
        Mock.fireNet('qb-vineyard:server:receiveWine', W)
        assert_true((Inv.wine or 0) > 0)
    end)
end)
