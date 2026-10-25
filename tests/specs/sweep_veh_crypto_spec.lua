-- pfm-crypto: a Qbit transfer tells the receiver's phone only the message, not the sender's player data.
load_resource('tests/lua/fivem_mocks.lua')
MySQL.query = setmetatable({ await = function(query)
    if query:find('walletid', 1, true) then return { { citizenid = 'CID2' } } end
    return {}
end }, { __call = function() return {} end })
Config = nil
load_resource('pfm-crypto/config.lua')
load_resource('pfm-crypto/server/main.lua')

local SENDER, RECEIVER = 1, 2

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    Mock.gameTimer = Mock.gameTimer + 100000
    local s = Mock.newPlayer(SENDER)
    s.PlayerData.money = { cash = 0, bank = 5000, crypto = 10 }
    s.PlayerData.metadata.walletid = 'WALLET1'
    local r = Mock.newPlayer(RECEIVER)
    r.PlayerData.money = { cash = 0, bank = 0, crypto = 0 }
    r.PlayerData.metadata.walletid = 'WALLET2'
end

describe('Qbit transfer', function()
    it("moves the coins and sends nobody the sender's player data", function()
        local res = Mock.callCallback('qb-crypto:server:TransferCrypto', SENDER, { Coins = 2, WalletId = 'WALLET2' })
        assert_eq(type(res), 'table')
        assert_eq(Mock.players[RECEIVER].PlayerData.money.crypto, 2)
        local ev = Mock.clientEventsNamed('qb-phone:client:AddTransaction')
        assert_eq(#ev, 2)
        for _, e in ipairs(ev) do
            assert_eq(e.args[1], nil, 'player object sent to ' .. tostring(e.target))
            assert_eq(e.args[2], nil)
            assert_eq(type(e.args[3]), 'string')
        end
    end)
end)
