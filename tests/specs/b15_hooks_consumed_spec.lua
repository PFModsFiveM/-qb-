-- Batch 15H platform hooks, pfm-smallresources: the server-only event
-- pfm-smallresources:server:consumed(src, itemName, kind, info) fires once per use, only after the
-- server removed the item (never when the removal failed, never for a bottle that was only opened),
-- with kind food / drink / alcohol / custom and info = { poisoned = the server's own illness roll,
-- quality = the dish's server-set quality }. A client cannot raise it. Also the evidence items the
-- pfm-policejob evidence store (15D) needs in pfm-core shared/items.lua.
load_resource('tests/lua/fivem_mocks.lua')

Config = nil
load_resource('pfm-inventory/config/config.lua')
load_resource('pfm-inventory/config/freshness.lua')
load_resource('pfm-inventory/server/freshness.lua')
load_resource('pfm-inventory/server/main.lua')
load_resource('pfm-inventory/server/functions.lua')
load_resource('pfm-inventory/server/hooks.lua')
local inventoryConfig = Config

Config = nil
load_resource('pfm-smallresources/config.lua')
for k, v in pairs(inventoryConfig) do if Config[k] == nil then Config[k] = v end end
Config.Consumables.eat.sandwich = 40
Config.Consumables.drink.water_bottle = 30
Config.Consumables.alcohol.beer = 20
Config.MaxReplenish = false
QBCoreMock.Shared.Items.beer = { name = 'beer', label = 'Beer', weight = 500, type = 'item', unique = false, useable = true, image = 'beer.png' }
QBCoreMock.Shared.Items.test_dish = { name = 'test_dish', label = 'Dish', weight = 200, type = 'item', unique = false, useable = true, image = 'x.png' }
QBCoreMock.Shared.Items.test_snack = { name = 'test_snack', label = 'Snack', weight = 200, type = 'item', unique = false, useable = true, image = 'x.png' }
QBCoreMock.Shared.Items.test_tonic = { name = 'test_tonic', label = 'Tonic', weight = 200, type = 'item', unique = false, useable = true, image = 'x.png' }
QBCoreMock.Shared.Items.joint = { name = 'joint', label = 'Joint', weight = 10, type = 'item', unique = false, useable = true, image = 'x.png' }
QBCoreMock.Shared.Items.test_vodka = { name = 'test_vodka', label = 'Vodka', weight = 200, type = 'item', unique = false, useable = true, image = 'x.png' }

function GetResourceState() return 'started' end
local removeOk = true -- a spec turns the inventory's removal down (an item moved away meanwhile)
Mock.exportsByResource['pfm-inventory'] = {
    RemoveItem = function(_, ...) if not removeOk then return false end return RemoveItem(...) end,
    GetFreshness = function(_, ...) return GetFreshness(...) end,
}
load_resource('pfm-smallresources/server/consumables.lua')
local X = Mock.exportsByResource['__self']

local SRC = 1
local seen -- every consumed event: { src, item, kind, info, heldWhenRaised }

local function itemAt(items, slot)
    for _, item in pairs(items) do if item.slot == slot then return item end end
end
local function held(name)
    local n = 0
    for _, item in pairs(Mock.players[SRC].PlayerData.items) do if item.name == name then n = n + (item.amount or 1) end end
    return n
end
local function use(name, slot)
    Mock.useables[name](SRC, itemAt(Mock.players[SRC].PlayerData.items, slot))
end

AddEventHandler('pfm-smallresources:server:consumed', function(src, itemName, kind, info)
    seen[#seen + 1] = { src = src, item = itemName, kind = kind, info = info, heldWhenRaised = held(itemName) }
end)

BeforeEach = function()
    Mock.reset()
    Mock.clock = 1700000000
    Mock.gameTimer = Mock.gameTimer + 120000 -- past every use cooldown
    Mock.players = {}
    local p = Mock.newPlayer(SRC)
    p.PlayerData.metadata.hunger = 10
    p.PlayerData.metadata.thirst = 10
    seen = {}
    removeOk = true
    math.randomseed(7)
end

describe('the consumed event', function()
    it('is not a net event: a client cannot raise it', function()
        assert_eq(Mock.netHandlers['pfm-smallresources:server:consumed'], nil)
    end)

    it('food: fires once, after the server removed the item, with kind food and the illness roll', function()
        assert_true(AddItem(SRC, 'sandwich', 2, 1))
        use('sandwich', 1)
        assert_eq(#seen, 1)
        assert_eq(seen[1].src, SRC)
        assert_eq(seen[1].item, 'sandwich')
        assert_eq(seen[1].kind, 'food')
        assert_eq(seen[1].heldWhenRaised, 1, 'raised after the removal')
        assert_eq(seen[1].info.poisoned, false)
        assert_eq(seen[1].info.quality, nil)
        -- the hunger grant is unchanged
        Mock.fireNet('consumables:server:addHunger', SRC)
        assert_eq(Mock.players[SRC].PlayerData.metadata.hunger, 50)
        assert_eq(#seen, 1, 'applying the grant raises nothing more')
    end)

    it('does not fire when the removal failed', function()
        assert_true(AddItem(SRC, 'sandwich', 1, 1))
        removeOk = false
        use('sandwich', 1)
        assert_eq(#seen, 0)
        assert_eq(held('sandwich'), 1)
    end)

    it('drink: kind drink', function()
        assert_true(AddItem(SRC, 'water_bottle', 1, 1))
        use('water_bottle', 1)
        assert_eq(#seen, 1)
        assert_eq(seen[1].kind, 'drink')
        assert_eq(seen[1].heldWhenRaised, 0)
    end)

    it("a poisoned dish reports the server's roll and its quality (pf-ambulancejob's food poisoning)", function()
        assert_true((X.AddFood('test_dish', 30)))
        assert_true(AddItem(SRC, 'test_dish', 1, 1, { quality = 64.4, poisonRisk = 1 }))
        use('test_dish', 1)
        assert_eq(#seen, 1)
        assert_eq(seen[1].kind, 'food')
        assert_eq(seen[1].info.poisoned, true)
        assert_eq(seen[1].info.quality, 64)
        -- the same roll makes the player ill on the client
        Mock.fireNet('consumables:server:addHunger', SRC)
        assert_eq(#Mock.clientEventsNamed('consumables:client:FoodPoisoning'), 1)
    end)

    it('a quality out of range is clamped; a non-number quality is left out', function()
        assert_true((X.AddDrink('test_tonic', 10)))
        assert_true(AddItem(SRC, 'test_tonic', 1, 1, { quality = 1e9 }))
        use('test_tonic', 1)
        assert_eq(seen[1].info.quality, 100)
        assert_true(AddItem(SRC, 'test_tonic', 1, 1, { quality = 'great' }))
        Mock.gameTimer = Mock.gameTimer + 120000
        use('test_tonic', 1)
        assert_eq(seen[2].info.quality, nil)
    end)

    it('alcohol: opening the bottle raises nothing; drinking it (the server removal) raises kind alcohol once', function()
        assert_true(AddItem(SRC, 'beer', 1, 1))
        use('beer', 1)
        assert_eq(#seen, 0, 'only opened')
        Mock.fireNet('consumables:server:drinkAlcohol', SRC, 'beer')
        assert_eq(#seen, 1)
        assert_eq(seen[1].kind, 'alcohol')
        assert_eq(seen[1].item, 'beer')
        assert_eq(seen[1].heldWhenRaised, 0)
        assert_eq(seen[1].info.poisoned, false)
        Mock.gameTimer = Mock.gameTimer + 120000
        Mock.fireNet('consumables:server:drinkAlcohol', SRC, 'beer')
        assert_eq(#seen, 1, 'no second drink without a bottle')
    end)

    it('alcohol: no event when the bottle is gone before it is drunk', function()
        assert_true(AddItem(SRC, 'beer', 1, 1))
        use('beer', 1)
        removeOk = false
        Mock.fireNet('consumables:server:drinkAlcohol', SRC, 'beer')
        assert_eq(#seen, 0)
    end)

    it('alcohol added at runtime carries the quality of the bottle that was opened', function()
        assert_true((X.AddAlcohol('test_vodka', 10)))
        assert_true(AddItem(SRC, 'test_vodka', 1, 1, { quality = 90 }))
        use('test_vodka', 1)
        Mock.fireNet('consumables:server:drinkAlcohol', SRC, 'test_vodka')
        assert_eq(#seen, 1)
        assert_eq(seen[1].kind, 'alcohol')
        assert_eq(seen[1].info.quality, 90)
    end)

    it('custom consumables: kind custom, no illness field', function()
        assert_true((X.AddCustom('test_snack', { replenish = { type = 'Hunger', replenish = 5 } })))
        assert_true(AddItem(SRC, 'test_snack', 1, 1))
        use('test_snack', 1)
        assert_eq(#seen, 1)
        assert_eq(seen[1].kind, 'custom')
        assert_eq(seen[1].info.poisoned, nil)
        assert_eq(seen[1].heldWhenRaised, 0)
    end)

    it('non-consumable usables (drugs, armor) raise nothing', function()
        assert_true(AddItem(SRC, 'joint', 1, 1))
        use('joint', 1)
        assert_eq(held('joint'), 0, 'used up as before')
        assert_eq(#seen, 0)
    end)
end)

describe('evidence items in pfm-core shared/items.lua (for the 15D evidence store)', function()
    local saved = QBCore
    QBCore = { Shared = {} }
    load_resource('pfm-core/shared/items.lua')
    local items = QBCore.Shared.Items
    QBCore = saved

    it('evidence_bag is unique (each bag carries its own info.evidenceId) and not usable', function()
        local bag = items.evidence_bag
        assert_true(bag ~= nil)
        assert_eq(bag.name, 'evidence_bag')
        assert_eq(bag.unique, true)
        assert_eq(bag.useable, false)
        assert_eq(bag.type, 'item')
        assert_true(type(bag.weight) == 'number' and bag.weight > 0)
    end)
    it('nitrile_gloves stack and are carried, not used (the glove rule reads the inventory)', function()
        local g = items.nitrile_gloves
        assert_true(g ~= nil)
        assert_eq(g.name, 'nitrile_gloves')
        assert_eq(g.unique, false)
        assert_eq(g.useable, false)
    end)
    it('the legacy bags stay', function()
        assert_true(items.filled_evidence_bag ~= nil)
        assert_true(items.empty_evidence_bag ~= nil)
    end)
end)
