-- pfm-crypto: buying and selling Qbit moves the bank side through the ledger; coins stay their own
-- balance (the ledger carries bank and cash only).
load_resource('tests/lua/ledger_env.lua')
LedgerEnv.load('pfm-crypto', { 'pfm-crypto/config.lua', 'pfm-crypto/server/main.lua' })

local P = 1
local function money() return Mock.players[P].PlayerData.money end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players = {}
    Mock.gameTimer = (Mock.gameTimer or 0) + 100000
    local p = Mock.newPlayer(P)
    p.PlayerData.money = { cash = 0, bank = 1000, crypto = 0 }
    p.PlayerData.metadata.walletid = 'WALLET1'
    Crypto.Worth['qbit'] = 100
end

describe('buying Qbit', function()
    it('takes the bank money through the ledger, then credits the coins', function()
        local res = Mock.callCallback('qb-crypto:server:BuyCrypto', P, { Coins = 2 })
        assert_true(type(res) == 'table')
        assert_eq(money().bank, 800)
        assert_eq(money().crypto, 2)
        assert_eq(#LedgerEnv.paid('pfm-crypto:buy:'), 1)
    end)
    it('without the money nothing happens', function()
        assert_eq(Mock.callCallback('qb-crypto:server:BuyCrypto', P, { Coins = 50 }), false)
        assert_eq(money().bank, 1000)
        assert_eq(money().crypto, 0)
    end)
end)

describe('selling Qbit', function()
    it('pays the bank through the ledger', function()
        money().crypto = 3
        Mock.callCallback('qb-crypto:server:SellCrypto', P, { Coins = 2 })
        assert_eq(money().crypto, 1)
        assert_eq(money().bank, 1200)
        assert_eq(#LedgerEnv.paid('pfm-crypto:sell:'), 1)
    end)
    it('gives the coins back when the bank cannot pay', function()
        money().crypto = 3
        local state = GetResourceState
        GetResourceState = function(name) if name == 'pfm-banking' then return 'stopped' end return state(name) end
        local res = Mock.callCallback('qb-crypto:server:SellCrypto', P, { Coins = 2 })
        GetResourceState = state
        assert_eq(res, false)
        assert_eq(money().crypto, 3)
        assert_eq(money().bank, 1000)
    end)
end)
