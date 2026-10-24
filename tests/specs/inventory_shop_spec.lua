-- Shop purchases: the server's shop record is authoritative, never the client's item table, and the
-- cash is paid through the ledger with the stock reserved first.
load_resource('tests/lua/ledger_env.lua')
LedgerEnv.load('pfm-inventory', {
    'pfm-inventory/config/config.lua', 'pfm-inventory/config/freshness.lua', 'pfm-inventory/server/freshness.lua',
    'pfm-inventory/server/main.lua', 'pfm-inventory/server/functions.lua', 'pfm-inventory/server/hooks.lua',
})

local SRC = 1
local BUY = 'qb-inventory:server:attemptPurchase'

local function stackOf(name)
    for _, it in pairs(Mock.players[SRC].PlayerData.items) do if it.name == name then return it end end
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
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
    it('charges the correct total, once, through the ledger', function()
        Mock.callCallback(BUY, SRC, { shop = 'shop-247', amount = 3, item = { name = 'sandwich', slot = 1 } })
        assert_eq(Mock.players[SRC].PlayerData.money.cash, 1000 - 15)
        assert_eq(#LedgerEnv.paid('pfm-inventory:shop:247:'), 1)
        assert_eq(RegisteredShops['247'].items[1].amount, 47)
    end)
    it('a failed payment leaves the stock as it was', function()
        Mock.players[SRC].PlayerData.money.cash = 2
        assert_false(Mock.callCallback(BUY, SRC, { shop = 'shop-247', amount = 3, item = { name = 'sandwich', slot = 1 } }))
        assert_eq(RegisteredShops['247'].items[1].amount, 50)
        assert_eq(Mock.players[SRC].PlayerData.money.cash, 2)
    end)
    it('the bank being down charges nothing and keeps the stock', function()
        local state = GetResourceState
        GetResourceState = function(name) if name == 'pfm-banking' then return 'stopped' end return state(name) end
        local ok = Mock.callCallback(BUY, SRC, { shop = 'shop-247', amount = 3, item = { name = 'sandwich', slot = 1 } })
        GetResourceState = state
        assert_false(ok)
        assert_eq(RegisteredShops['247'].items[1].amount, 50)
        assert_eq(Mock.players[SRC].PlayerData.money.cash, 1000)
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
