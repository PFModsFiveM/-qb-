-- Shop purchases: the server's shop record is authoritative, never the client's item table.
load_resource('tests/lua/fivem_mocks.lua')
Config = nil
load_resource('pfm-inventory/config/config.lua')
load_resource('pfm-inventory/config/freshness.lua')
load_resource('pfm-inventory/server/freshness.lua')
load_resource('pfm-inventory/server/main.lua')
load_resource('pfm-inventory/server/functions.lua')
load_resource('pfm-inventory/server/hooks.lua')

local SRC = 1
local BUY = 'qb-inventory:server:attemptPurchase'

local function stackOf(name)
    for _, it in pairs(Mock.players[SRC].PlayerData.items) do if it.name == name then return it end end
end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    local p = Mock.newPlayer(SRC)
    p.PlayerData.money.cash = 1000
    RegisteredShops['247'] = {
        name = '247',
        items = {
            [1] = { name = 'sandwich', amount = 50, price = 5, info = {}, slot = 1 },
            [2] = { name = 'weapon_pistol', amount = 5, price = 200, info = { quality = 100 }, slot = 2 },
        },
    }
end

describe('attemptPurchase', function()
    it('ignores client-supplied item info', function()
        local ok = Mock.callCallback(BUY, SRC, { shop = 'shop-247', amount = 1,
            item = { name = 'weapon_pistol', slot = 2, info = { quality = 100, attachments = { { component = 'COMPONENT_AT_PI_SUPP' } }, serie = 'FORGED' } } })
        assert_true(ok)
        local pistol = stackOf('weapon_pistol')
        assert_eq(pistol.info.attachments, nil, 'no forged attachments')
        assert_true(pistol.info.serie ~= 'FORGED', 'server-generated serial')
    end)
    it('bought food gets a server-assigned freshness record, not a forged one', function()
        Mock.callCallback(BUY, SRC, { shop = 'shop-247', amount = 2,
            item = { name = 'sandwich', slot = 1, info = { fresh = { batch = 'EVIL', used = 0, life = 9e9, at = 9e12 } } } })
        local s = stackOf('sandwich')
        assert_true(s.info.fresh.batch ~= 'EVIL')
        assert_eq(s.info.fresh.life, 12 * 3600)
    end)
    it('charges the correct total', function()
        Mock.callCallback(BUY, SRC, { shop = 'shop-247', amount = 3, item = { name = 'sandwich', slot = 1 } })
        assert_eq(Mock.players[SRC].PlayerData.money.cash, 1000 - 15)
    end)
    it('rejects malformed requests without crashing or charging', function()
        assert_false(Mock.callCallback(BUY, SRC, nil))
        assert_false(Mock.callCallback(BUY, SRC, { shop = 'shop-247', amount = 1 }))
        assert_false(Mock.callCallback(BUY, SRC, { shop = 'shop-247', amount = 1, item = { name = 'sandwich', slot = 99 } }))
        assert_false(Mock.callCallback(BUY, SRC, { shop = 'shop-247', amount = 0 / 0, item = { name = 'sandwich', slot = 1 } }))
        assert_false(Mock.callCallback(BUY, SRC, { shop = 'shop-247', amount = 1, item = { name = 'goldbar', slot = 1 } }))
        assert_eq(Mock.players[SRC].PlayerData.money.cash, 1000)
    end)
end)
