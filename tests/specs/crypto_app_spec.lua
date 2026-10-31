-- pfm-crypto's Crypto app on pf-devices (server/app.lua) with the real ledger on the fake database:
-- the server sets the price, each trade id buys / sells / sends once, coins and bank money move
-- through the shared trade code (the phone's callbacks keep working), and bad payloads move nothing.
load_resource('tests/lua/ledger_env.lua')
local started = { ['pf-devices'] = true, ['pfm-banking'] = true, ['pfm-core'] = true }
function GetResourceState(name) return started[name] and 'started' or 'missing' end

-- the coin transfer record and the wallet lookup (the real SQL runs in crypto_app_realdb_spec.lua)
local transfers = {}
FakeDB.extraPatterns = {
    { 'FROM pf_crypto_transfers WHERE transfer_key = ?', function(p)
        local t = transfers[p[1]]
        return t and { coins = t.coins, to_cid = t.to } or nil
    end },
    { 'INSERT INTO pf_crypto_transfers', function(p)
        if transfers[p[1]] then error('Duplicate entry for key uq_transfer_key') end
        transfers[p[1]] = { coins = p[5], from = p[2], to = p[3] }
        return 1
    end },
    { "JSON_EXTRACT(`metadata`, '$.walletid')", function(p)
        for _, pl in pairs(Mock.players) do
            if pl.PlayerData.metadata.walletid == p[1] then return { { citizenid = pl.PlayerData.citizenid } } end
        end
        return {}
    end },
}

LedgerEnv.load('pfm-crypto', { 'pfm-crypto/config.lua', 'pfm-crypto/server/main.lua', 'pfm-crypto/server/app.lua' })
Mock.exportsByResource['__self'] = nil
function GetCurrentResourceName() return 'pf-devices' end
load_resource('[pfscripts]/pf-devices/shared/config.lua')
for _, f in ipairs({ 'registry', 'installs', 'rpc', 'push', 'sites', 'builtin_apps', 'main' }) do
    load_resource('[pfscripts]/pf-devices/server/' .. f .. '.lua')
end
Mock.exportsByResource['pf-devices'] = Mock.exportsByResource['__self']
Mock.exportsByResource['__self'] = nil
function GetCurrentResourceName() return 'pfm-crypto' end

local ME, OTHER = 1, 2
local function money(src) return Mock.players[src].PlayerData.money end
local function rpc(src, method, payload)
    Mock.gameTimer = Mock.gameTimer + 5000 -- past the app's one-trade-per-second limit
    return PFDevices.HandleRpc(src, 'crypto', method, payload)
end
local n = 0
local function ref() n = n + 1 return ('crypto-ref-%05d'):format(n) end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players = {}
    transfers = {}
    PFDevices.__reset()
    PFDevices.__resetRpc()
    CryptoApp.__reset()
    local a = Mock.newPlayer(ME, 'ME001')
    a.PlayerData.money = { cash = 0, bank = 1000, crypto = 0 }
    a.PlayerData.metadata.walletid = 'WALLETME'
    local b = Mock.newPlayer(OTHER, 'OT001')
    b.PlayerData.money = { cash = 0, bank = 0, crypto = 0 }
    b.PlayerData.metadata.walletid = 'WALLETOT'
    Crypto.Worth['qbit'] = 100
    Mock.invokingResource = 'pfm-crypto'
    CryptoApp.Register()
    Mock.invokingResource = nil
end

describe('the Crypto app on pf-devices', function()
    it('is on the tablet and the computer for anyone', function()
        local app = PFDevices.GetApp('crypto')
        assert_eq(app.resource, 'pfm-crypto')
        assert_eq(app.access.anyone, true)
        assert_eq(table.concat(app.devices, ','), 'computer,tablet')
    end)
    it('the market shows the server price and the caller’s own wallet', function()
        local res = rpc(ME, 'market', { price = 1, walletId = 'WALLETOT' })
        assert_true(res.ok)
        assert_eq(res.price, 100)
        assert_eq(res.wallet.walletId, 'WALLETME')
        assert_eq(res.bank, 1000)
        assert_true(#res.history >= 0)
    end)
end)

describe('buying and selling from the app', function()
    it('a buy is charged through the ledger once per ref, at the server price', function()
        local r = ref()
        local first = rpc(ME, 'buy', { coins = 2, ref = r, price = 1 })
        assert_true(first.ok, tostring(first.error))
        assert_eq(first.total, 200)
        local again = rpc(ME, 'buy', { coins = 2, ref = r })
        assert_true(again.ok and again.duplicate)
        assert_eq(money(ME).bank, 800)
        assert_eq(money(ME).crypto, 2)
        assert_eq(#LedgerEnv.paid('pfm-crypto:buy:ME001:'), 1)
        assert_eq(first.wallet.coins, 2)
    end)
    it('refuses bad amounts and missing ids before anything moves', function()
        for _, coins in ipairs({ -1, 0, 'abc', 0 / 0, 1e9 }) do
            assert_eq(rpc(ME, 'buy', { coins = coins, ref = ref() }).error, 'bad_amount', tostring(coins))
        end
        assert_eq(rpc(ME, 'buy', { coins = 1 }).error, 'bad_request')
        assert_eq(rpc(ME, 'buy', { coins = 1, ref = 'x' }).error, 'bad_request')
        assert_eq(rpc(ME, 'buy', { coins = 50, ref = ref() }).error, 'insufficient_funds')
        assert_eq(money(ME).bank, 1000)
        assert_eq(money(ME).crypto, 0)
    end)
    it('a sale pays once per ref and takes the coins once', function()
        money(ME).crypto = 3
        local r = ref()
        assert_true(rpc(ME, 'sell', { coins = 2, ref = r }).ok)
        assert_true(rpc(ME, 'sell', { coins = 2, ref = r }).duplicate)
        assert_eq(money(ME).crypto, 1)
        assert_eq(money(ME).bank, 1200)
        assert_eq(#LedgerEnv.paid('pfm-crypto:sell:ME001:'), 1)
        assert_eq(rpc(ME, 'sell', { coins = 5, ref = ref() }).error, 'insufficient_coins')
        assert_eq(money(ME).crypto, 1)
    end)
    it('when the bank is down nothing is sold', function()
        money(ME).crypto = 3
        started['pfm-banking'] = false
        local res = rpc(ME, 'sell', { coins = 2, ref = ref() })
        started['pfm-banking'] = true
        assert_eq(res.error, 'bank_unavailable')
        assert_eq(money(ME).crypto, 3)
        assert_eq(money(ME).bank, 1000)
    end)
    it('one trade per second from the app', function()
        assert_true(PFDevices.HandleRpc(ME, 'crypto', 'buy', { coins = 1, ref = ref() }).ok)
        assert_eq(PFDevices.HandleRpc(ME, 'crypto', 'buy', { coins = 1, ref = ref() }).error, 'slow_down')
        assert_eq(money(ME).crypto, 1)
    end)
    it('the phone’s callbacks still trade through the same code', function()
        local res = Mock.callCallback('qb-crypto:server:BuyCrypto', ME, { Coins = 1 })
        assert_eq(type(res), 'table')
        assert_eq(res.Portfolio, 1)
        assert_eq(money(ME).bank, 900)
    end)
end)

describe('sending coins from the app', function()
    it('moves the coins once per ref and records the transfer', function()
        money(ME).crypto = 5
        local r = ref()
        assert_true(rpc(ME, 'send', { walletId = 'WALLETOT', coins = 2, ref = r }).ok)
        assert_true(rpc(ME, 'send', { walletId = 'WALLETOT', coins = 2, ref = r }).duplicate)
        assert_eq(money(ME).crypto, 3)
        assert_eq(money(OTHER).crypto, 2)
        assert_eq(transfers['pfm-crypto:send:ME001:' .. r].to, 'OT001')
    end)
    it('refuses its own wallet, unknown wallets and bad payloads', function()
        money(ME).crypto = 5
        assert_eq(rpc(ME, 'send', { walletId = 'WALLETME', coins = 1, ref = ref() }).error, 'own_wallet')
        assert_eq(rpc(ME, 'send', { walletId = 'NOPE', coins = 1, ref = ref() }).error, 'unknown_wallet')
        assert_eq(rpc(ME, 'send', { walletId = 'WALLETOT', coins = -1, ref = ref() }).error, 'bad_amount')
        assert_eq(rpc(ME, 'send', { walletId = 'WALLETOT', coins = 1 }).error, 'bad_request')
        assert_eq(rpc(ME, 'send', { walletId = 'WALLETOT', coins = 50, ref = ref() }).error, 'insufficient_coins')
        assert_eq(money(ME).crypto, 5)
        assert_eq(money(OTHER).crypto, 0)
    end)
end)

-- A ref kept after a lost answer must only ever stand for the same trade: the server answers a reused
-- ref with what that trade did, and refuses it for another amount, side or wallet.
describe('a reused trade id', function()
    it('a buy answers with the stored coins and cost, and refuses another amount', function()
        local r = ref()
        assert_true(rpc(ME, 'buy', { coins = 1, ref = r }).ok)
        local bigger = rpc(ME, 'buy', { coins = 5, ref = r })
        assert_false(bigger.ok, 'a different amount under the same id was reported as bought')
        assert_eq(bigger.error, 'already_processed')
        Crypto.Worth['qbit'] = 200
        local again = rpc(ME, 'buy', { coins = 1, ref = r })
        assert_true(again.ok and again.duplicate)
        assert_eq(again.total, 100, 'the stored cost, not one at the new price')
        assert_eq(again.price, 100)
        assert_eq(again.coins, 1)
        assert_eq(money(ME).bank, 900)
        assert_eq(money(ME).crypto, 1)
        assert_eq(#LedgerEnv.paid('pfm-crypto:buy:ME001:'), 1)
    end)
    it('a sale answers with the stored coins and payout, and refuses another amount', function()
        money(ME).crypto = 5
        local r = ref()
        assert_true(rpc(ME, 'sell', { coins = 2, ref = r }).ok)
        local other = rpc(ME, 'sell', { coins = 1, ref = r })
        assert_false(other.ok)
        assert_eq(other.error, 'already_processed')
        local again = rpc(ME, 'sell', { coins = 2, ref = r })
        assert_true(again.duplicate)
        assert_eq(again.coins, 2)
        assert_eq(again.total, 200)
        assert_eq(money(ME).crypto, 3)
        assert_eq(money(ME).bank, 1200)
    end)
    it('a send refuses another amount or another wallet under the same id', function()
        local third = Mock.newPlayer(3, 'TH001')
        third.PlayerData.money = { cash = 0, bank = 0, crypto = 0 }
        third.PlayerData.metadata.walletid = 'WALLETTH'
        money(ME).crypto = 10
        local r = ref()
        assert_true(rpc(ME, 'send', { walletId = 'WALLETOT', coins = 2, ref = r }).ok)
        assert_eq(rpc(ME, 'send', { walletId = 'WALLETOT', coins = 3, ref = r }).error, 'already_processed')
        assert_eq(rpc(ME, 'send', { walletId = 'WALLETTH', coins = 2, ref = r }).error, 'already_processed')
        local again = rpc(ME, 'send', { walletId = 'WALLETOT', coins = 2, ref = r })
        assert_true(again.ok and again.duplicate)
        assert_eq(again.coins, 2)
        assert_eq(money(ME).crypto, 8)
        assert_eq(money(OTHER).crypto, 2)
        assert_eq(money(3).crypto, 0)
    end)
end)

describe('price pushes', function()
    it('a price change reaches every open Crypto app', function()
        CryptoApp.OnPrice('qbit', 150)
        local ev = Mock.clientEventsNamed('pf-devices:client:appEvent')
        assert_eq(#ev, 1)
        assert_eq(ev[1].target, -1)
        assert_eq(ev[1].args[1], 'crypto')
        assert_eq(ev[1].args[2], 'price')
        assert_eq(ev[1].args[3].price, 150)
    end)
end)
