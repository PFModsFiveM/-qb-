-- pfm-crafting Crafting app (server_devices.lua): installable on both devices; every bench's recipes
-- with what they need, what the player carries (all slots), the XP lock and how many can be made,
-- and where the player's own bench stands; read-only.
load_resource('tests/lua/fivem_mocks.lua')
Config = nil
load_resource('pfm-crafting/config.lua')
Mock.exportsByResource['pfm-inventory'] = {
    RemoveItem = function() return true end, AddItem = function() return true end, HasItem = function() return true end,
}
local app = {}
Mock.exportsByResource['pf-devices'] = {
    RegisterApp = function(_, def) app.def = def return true end,
    RegisterAppHandlers = function(_, id, map) app.h = map return true end,
}
function GetResourceState() return 'started' end
load_resource('pfm-crafting/server.lua')
load_resource('pfm-crafting/server_devices.lua')
Mock.eventHandlers['pf-devices:server:ready']()

local P, OTHER = 1, 2
local rep = 0
BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords = {}, {}
    for _, src in ipairs({ P, OTHER }) do
        local p = Mock.newPlayer(src)
        p.GetRep = function() return rep end
        p.AddRep = function() end
    end
    Mock.players[P].PlayerData.items = {
        { name = 'metalscrap', amount = 30, slot = 1 }, { name = 'metalscrap', amount = 20, slot = 2 },
        { name = 'plastic', amount = 70, slot = 3 }, { name = 'item_bench', amount = 1, slot = 4 },
    }
    rep = 0
    Mock.coords[P] = vector3(10.0, 20.0, 30.0)
end

local function bench(view, kind) for _, b in ipairs(view.benches) do if b.type == kind then return b end end end
local function recipe(b, item) for _, r in ipairs(b.recipes) do if r.item == item then return r end end end

describe('Crafting app', function()
    it('is an installable app on both devices', function()
        assert_eq(app.def.id, 'crafting')
        assert_true(app.def.access.installable)
        assert_eq(table.concat(app.def.devices, ','), 'tablet,computer')
        assert_eq(app.def.entry, 'html/crafting.js')
    end)
    it('lists each bench with its recipes, what they need and how many the player can make', function()
        local view = app.h.getInit(P, {})
        assert_true(view.ok)
        assert_eq(view.benches[1].type, 'item_bench', 'the item bench first')
        local b = bench(view, 'item_bench')
        assert_eq(#b.recipes, #Config.item_bench.recipes)
        assert_eq(b.owned, 1)
        assert_eq(b.placed, nil)
        local lockpick = recipe(b, 'lockpick')            -- 22 metal scrap + 32 plastic
        assert_true(lockpick.unlocked)
        assert_eq(lockpick.requirements[1].have, 50, 'every slot counted')
        assert_eq(lockpick.canMake, 2)
        local kit = recipe(b, 'electronickit')            -- needs aluminium the player does not have
        assert_eq(kit.canMake, 0)
        local gate = recipe(b, 'gatecrack')               -- needs 110 XP
        assert_false(gate.unlocked)
        assert_eq(gate.canMake, 0)
        rep = 110
        assert_true(recipe(bench(app.h.getInit(P, {}), 'item_bench'), 'gatecrack').unlocked)
        assert_true(bench(view, 'attachment_bench') ~= nil)
    end)
    it('shows where the player\'s own bench stands, only to them', function()
        Mock.fireNet('qb-crafting:server:removeCraftingTable', P, 'item_bench')
        local b = bench(app.h.getInit(P, {}), 'item_bench')
        assert_eq(b.placed.x, 10.0)
        assert_eq(b.placed.y, 20.0)
        assert_eq(bench(app.h.getInit(OTHER, {}), 'item_bench').placed, nil)
        assert_eq(bench(app.h.getInit(P, {}), 'attachment_bench').placed, nil)
    end)
end)
