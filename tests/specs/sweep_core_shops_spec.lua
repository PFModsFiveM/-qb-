-- pfm-shops: the stock update after a purchase is a server-only event (any client could empty any
-- shop's stock through it).
load_resource('tests/lua/fivem_mocks.lua')
function LoadResourceFile() return '{}' end
function SaveResourceFile() end
Config = nil
load_resource('pfm-shops/config.lua')
load_resource('pfm-shops/server/main.lua')

local SHOP
for name, loc in pairs(Config.Locations) do
    if loc.products and loc.products[1] then SHOP = name break end
end
Config.Locations[SHOP].useStock = true

describe('qb-shops:server:UpdateShopItems', function()
    it('is not a net event', function()
        assert_eq(Mock.netHandlers['qb-shops:server:UpdateShopItems'], nil)
    end)
    it('pfm-inventory (server) can still trigger it', function()
        -- (the stock arithmetic itself uses a compound assignment the test preprocessor cannot rewrite)
        assert_eq(type(Mock.eventHandlers['qb-shops:server:UpdateShopItems']), 'function')
    end)
end)
