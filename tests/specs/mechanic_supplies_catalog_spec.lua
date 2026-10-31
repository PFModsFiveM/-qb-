-- pf-mechanicjob's supply catalog (what a mechanic shop can order on PF Computer): the scrap
-- materials from the recycling plant and the scrapyard are always listed, one unit per case at their
-- own price, next to the parts; a part of the same name is not listed twice.
load_resource('tests/lua/fivem_mocks.lua')
Config = nil
load_resource('[pfscripts]/pf-mechanicjob/config.lua')
load_resource('[pfscripts]/pf-mechanicjob/server/business_data_provider.lua')
local catalog = function() return Mock.selfExport('GetBusinessConfig')().suppliesCatalog end
local MATERIALS = { 'metalscrap', 'steel', 'aluminum', 'iron', 'copper', 'plastic', 'rubber', 'glass' }

local function index(cat)
    local by, parts = {}, 0
    for _, it in ipairs(cat.items) do
        assert_eq(by[it.item], nil, it.item .. ' listed once')
        by[it.item] = it
        if it.category ~= 'Materials' then parts = parts + 1 end
    end
    return by, parts
end

describe('mechanic supply catalog', function()
    it('lists every scrap material at its own price, one unit per case, next to all the parts', function()
        local registerItems = 0
        for _ in pairs(Config.RegisterItems) do registerItems = registerItems + 1 end
        local by, parts = index(catalog())
        assert_eq(parts, registerItems, 'the parts are all still there')
        for _, name in ipairs(MATERIALS) do
            local it = by[name]
            assert_true(it ~= nil, name)
            assert_eq(it.caseSize, 1)
            assert_eq(it.caseContents, '1x ' .. it.label)
            assert_eq(it.category, 'Materials')
            assert_true(it.pricePerCase >= 3 and it.pricePerCase <= 6, name .. ' price ' .. it.pricePerCase)
        end
        local cats = {}
        for _, c in ipairs(catalog().categories) do cats[c.id] = true end
        assert_true(cats.Materials, 'Materials is a category')
    end)
    it('keeps them when the catalog lists only some parts', function()
        Config.SuppliesCatalog.items = { { item = 'engine_oil', casePrice = 900, caseSize = 12 } }
        local by, parts = index(catalog())
        assert_eq(parts, 1)
        assert_eq(by.engine_oil.pricePerCase, 900)
        assert_true(by.metalscrap ~= nil)
        Config.SuppliesCatalog.items = {}
    end)
    it('a part with the same name as a material wins, and a material without a price is left out', function()
        Config.RegisterItems.metalscrap = { label = 'Scrap (part)', basePrice = 40, category = 'Parts' }
        table.insert(Config.SuppliesCatalog.materials, { item = 'gold', label = 'Gold' })
        local by = index(catalog())
        assert_eq(by.metalscrap.category, 'Parts')
        assert_eq(by.gold, nil)
        Config.RegisterItems.metalscrap = nil
        table.remove(Config.SuppliesCatalog.materials)
    end)
end)
