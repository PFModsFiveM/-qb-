-- pfm-pawnshop Pawn Shop app (server/devices.lua): installable on both devices, shows the prices the
-- server really pays, what the player carries, the hours (also enforced at the counter when the
-- shop keeps hours) and the player's melting job; read-only.
load_resource('tests/lua/ledger_env.lua')
-- before the resource loads: it reads the items once, through exports['pfm-core']:GetShared (a copy)
QBCoreMock.Shared.Items.goldchain = { name = 'goldchain', label = 'Gold Chain', weight = 100, type = 'item' }
QBCoreMock.Shared.Items.rolex = { name = 'rolex', label = 'Golden Watch', weight = 100, type = 'item' }
LedgerEnv.load('pfm-pawnshop', { 'pfm-pawnshop/config.lua', 'pfm-pawnshop/server/main.lua', 'pfm-pawnshop/server/devices.lua' })
local app = {}
Mock.exportsByResource['pf-devices'] = {
    RegisterApp = function(_, def) app.def = def return true end,
    RegisterAppHandlers = function(_, id, map) app.h = map return true end,
}
local clock = { 12, 30 }
Mock.exportsByResource['pfm-weathersync'] = { getTime = function() return clock[1], clock[2] end }
local removed = {}
Mock.exportsByResource['pfm-inventory'] = {
    RemoveItem = function(_, src, item, n) removed[#removed + 1] = { item = item, n = n } return true end,
    AddItem = function() return true end,
}
Mock.eventHandlers['pf-devices:server:ready']()

local P = 1
local SHOP = Config.PawnLocation[1].coords
BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.gameTimer = Mock.gameTimer + 60000
    Mock.players, Mock.coords, removed = {}, {}, {}
    local p = Mock.newPlayer(P)
    p.PlayerData.items = { { name = 'goldchain', amount = 3, slot = 1 }, { name = 'goldchain', amount = 2, slot = 2 }, { name = 'rolex', amount = 1, slot = 3 } }
    Config.UseTimes = false
    clock = { 12, 30 }
end

describe('Pawn Shop app', function()
    it('is an installable app on both devices', function()
        assert_eq(app.def.id, 'pawnshop')
        assert_true(app.def.access.installable)
        assert_eq(table.concat(app.def.devices, ','), 'tablet,computer')
        assert_eq(app.def.entry, 'html/pawnshop.js')
    end)
    it('shows the prices the counter pays and what the player carries', function()
        local view = app.h.getInit(P, {})
        assert_true(view.ok)
        assert_eq(#view.prices, #Config.PawnItems)
        local byItem = {}
        for _, p in ipairs(view.prices) do byItem[p.item] = p end
        for _, v in ipairs(Config.PawnItems) do assert_eq(byItem[v.item].price, v.price, 'the server price') end
        assert_eq(byItem.goldchain.have, 5, 'every slot counted')
        assert_eq(byItem.rolex.have, 1)
        local prices = Mock.callCallback('qb-pawnshop:server:getPawnPrices', P)
        assert_eq(prices.goldchain, byItem.goldchain.price, 'the sell menu shows the same prices')
        assert_eq(#view.locations, 1)
        assert_eq(view.locations[1].x, SHOP.x)
        assert_false(view.hours.limited)
        assert_eq(view.melting, nil)
        assert_true(#view.meltable >= 1)
    end)
    it('shows the hours and the counter keeps them', function()
        Config.UseTimes = true
        clock = { 22, 5 }
        local view = app.h.getInit(P, {})
        assert_true(view.hours.limited)
        assert_eq(view.hours.hour, 22)
        assert_false(view.hours.openNow)
        Mock.coords[P] = SHOP
        Mock.fireNet('qb-pawnshop:server:sellPawnItems', P, 'goldchain', 1, 999)
        assert_eq(#removed, 0, 'closed: nothing bought')
        assert_eq(#LedgerEnv.paid('pfm-pawnshop:'), 0)
        clock = { 10, 0 }
        assert_true(app.h.getInit(P, {}).hours.openNow)
        Mock.gameTimer = Mock.gameTimer + 5000
        Mock.fireNet('qb-pawnshop:server:sellPawnItems', P, 'goldchain', 1, 999)
        assert_eq(#removed, 1)
        assert_eq(#LedgerEnv.paid('pfm-pawnshop:'), 1)
    end)
    it('follows the melting job until it can be collected', function()
        Mock.coords[P] = SHOP
        Mock.fireNet('qb-pawnshop:server:meltItemRemove', P, 'goldchain', 2)
        local view = app.h.getInit(P, {})
        assert_eq(view.melting.item, 'goldchain')
        assert_eq(view.melting.amount, 2)
        assert_false(view.melting.ready)
        assert_true(view.melting.readyIn > 0)
        assert_eq(view.melting.rewards[1].item, 'goldbar')
        assert_eq(view.melting.rewards[1].amount, 4)
        Mock.clock = Mock.clock + view.melting.readyIn
        assert_true(app.h.getInit(P, {}).melting.ready)
        Mock.gameTimer = Mock.gameTimer + 5000
        Mock.fireNet('qb-pawnshop:server:pickupMelted', P)
        assert_eq(app.h.getInit(P, {}).melting, nil, 'collected')
    end)
end)
