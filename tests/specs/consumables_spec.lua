-- pfm-smallresources consumption: hunger/thirst only rise after the server consumed real food,
-- and the gain/illness follow the item's server-side freshness.
load_resource('tests/lua/fivem_mocks.lua')

-- pfm-inventory (real code) provides RemoveItem and GetFreshness
Config = nil
load_resource('pfm-inventory/config/config.lua')
load_resource('pfm-inventory/config/freshness.lua')
load_resource('pfm-inventory/server/freshness.lua')
load_resource('pfm-inventory/server/main.lua')
load_resource('pfm-inventory/server/functions.lua')
load_resource('pfm-inventory/server/hooks.lua')
local inventoryConfig = Config

-- both resources have their own global Config in FiveM; merge them for the shared test VM
Config = nil
load_resource('pfm-smallresources/config.lua')
for k, v in pairs(inventoryConfig) do if Config[k] == nil then Config[k] = v end end
Config.Consumables.eat.sandwich = 40
Config.Consumables.drink.water_bottle = 30
Config.Consumables.alcohol.beer = 20
Config.MaxReplenish = false
QBCoreMock.Shared.Items.beer = { name = 'beer', label = 'Beer', weight = 500, type = 'item', unique = false, useable = true, image = 'beer.png' }

function GetResourceState() return 'started' end
Mock.exportsByResource['pfm-inventory'] = {
    RemoveItem = function(_, ...) return RemoveItem(...) end,
    GetFreshness = function(_, ...) return GetFreshness(...) end,
}
load_resource('pfm-smallresources/server/consumables.lua')

local SRC = 1
local HOUR = 3600

local function itemAt(items, slot)
    for _, item in pairs(items) do if item.slot == slot then return item end end
end

local function use(name, slot)
    local Pl = Mock.players[SRC]
    Mock.useables[name](SRC, itemAt(Pl.PlayerData.items, slot))
end

BeforeEach = function()
    Mock.reset()
    Mock.clock = 1700000000
    Mock.players = {}
    local p = Mock.newPlayer(SRC)
    p.PlayerData.metadata.hunger = 10
    p.PlayerData.metadata.thirst = 10
    math.randomseed(7)
end

describe('needs require a real consumed item', function()
    it('addHunger without eating does nothing (no more free refills)', function()
        Mock.fireNet('consumables:server:addHunger', SRC, 100)
        assert_eq(Mock.players[SRC].PlayerData.metadata.hunger, 10)
    end)
    it('eating fresh food grants the full configured amount, ignoring the client total', function()
        assert_true(AddItem(SRC, 'sandwich', 1, 1))
        use('sandwich', 1)
        Mock.fireNet('consumables:server:addHunger', SRC, 100)
        assert_eq(Mock.players[SRC].PlayerData.metadata.hunger, 50)
        assert_eq(itemAt(Mock.players[SRC].PlayerData.items, 1), nil, 'sandwich consumed')
    end)
    it('a grant can only be used once', function()
        assert_true(AddItem(SRC, 'sandwich', 1, 1))
        use('sandwich', 1)
        Mock.fireNet('consumables:server:addHunger', SRC)
        Mock.fireNet('consumables:server:addHunger', SRC)
        assert_eq(Mock.players[SRC].PlayerData.metadata.hunger, 50)
    end)
    it('grants expire', function()
        assert_true(AddItem(SRC, 'sandwich', 1, 1))
        use('sandwich', 1)
        Mock.clock = Mock.clock + 120
        Mock.fireNet('consumables:server:addHunger', SRC)
        assert_eq(Mock.players[SRC].PlayerData.metadata.hunger, 10)
    end)
    it('an eat grant cannot be redeemed as thirst', function()
        assert_true(AddItem(SRC, 'sandwich', 1, 1))
        use('sandwich', 1)
        Mock.fireNet('consumables:server:addThirst', SRC)
        assert_eq(Mock.players[SRC].PlayerData.metadata.thirst, 10)
    end)
end)

describe('freshness affects consumption', function()
    it('stale food gives reduced benefit and warns the player', function()
        assert_true(AddItem(SRC, 'sandwich', 1, 1))
        Mock.clock = Mock.clock + 11 * HOUR          -- 12h shelf life -> ~8% left -> stale
        use('sandwich', 1)
        Mock.fireNet('consumables:server:addHunger', SRC)
        assert_eq(Mock.players[SRC].PlayerData.metadata.hunger, 10 + 24, '40 x 0.6')
        local warned = false
        for _, e in ipairs(Mock.clientEventsNamed('QBCore:Notify')) do
            if e.args[1] == 'consumables.tastes_off' then warned = true end
        end
        assert_true(warned)
    end)
    it('spoiled food is still edible but can make the player ill', function()
        Config.Freshness.Effects.spoiled.illness = 100
        assert_true(AddItem(SRC, 'sandwich', 1, 1))
        Mock.clock = Mock.clock + 48 * HOUR
        use('sandwich', 1)
        Mock.fireNet('consumables:server:addHunger', SRC)
        assert_eq(Mock.players[SRC].PlayerData.metadata.hunger, 10 + 10, '40 x 0.25')
        assert_eq(#Mock.clientEventsNamed('consumables:client:FoodPoisoning'), 1)
        Config.Freshness.Effects.spoiled.illness = 45
    end)
    it('refrigerated food stays fresh longer', function()
        CreateInventory('fridge-home', { maxweight = 100000, slots = 10 })
        assert_true(AddItem('fridge-home', 'sandwich', 1, 1))
        Mock.clock = Mock.clock + 11 * HOUR          -- 11h x 0.25 = 2.75h used -> still fresh
        local stored = itemAt(Inventories['fridge-home'].items, 1)
        assert_eq(GetFreshness('sandwich', stored.info).state, 'fresh')
    end)
end)

describe('alcohol', function()
    it('thirst is granted only after the bottle is actually removed', function()
        assert_true(AddItem(SRC, 'beer', 1, 1))
        use('beer', 1)
        Mock.fireNet('consumables:server:addThirst', SRC)          -- before drinkAlcohol: nothing
        assert_eq(Mock.players[SRC].PlayerData.metadata.thirst, 10)
        Mock.fireNet('consumables:server:drinkAlcohol', SRC, 'beer')
        Mock.fireNet('consumables:server:addThirst', SRC)
        assert_eq(Mock.players[SRC].PlayerData.metadata.thirst, 30)
    end)
    it('drinkAlcohol without using a bottle removes nothing and grants nothing', function()
        assert_true(AddItem(SRC, 'beer', 3, 1))
        Mock.fireNet('consumables:server:drinkAlcohol', SRC, 'beer')
        Mock.fireNet('consumables:server:addThirst', SRC)
        assert_eq(itemAt(Mock.players[SRC].PlayerData.items, 1).amount, 3)
        assert_eq(Mock.players[SRC].PlayerData.metadata.thirst, 10)
    end)
end)
