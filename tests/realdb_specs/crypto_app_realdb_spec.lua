-- pfm-crypto's Crypto app on a real database: its migration, buy / sell exactly once per id through
-- the real ledger, coins sent to an offline wallet with one atomic update, trade history and the
-- recorded price history.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
local started = { ['pf-devices'] = true, ['pfm-banking'] = true, ['pfm-core'] = true }
function GetResourceState(name) return started[name] and 'started' or 'missing' end

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
local function addPlayer(cid, money, wallet)
    MySQL.query.await([[INSERT INTO players (citizenid, cid, license, name, money, charinfo, job, gang, position, metadata, inventory)
        VALUES (?, 1, ?, ?, ?, '{}', '{}', '{}', '{}', ?, '[]')]], { cid, 'license:' .. cid, cid, json.encode(money), json.encode({ walletid = wallet }) })
end
addPlayer('CRY00001', { cash = 0, bank = 2000, crypto = 0 }, 'W-ONLINE-1')
addPlayer('CRY00002', { cash = 0, bank = 0, crypto = 1.5 }, 'W-OFFLINE-2')

-- the bank and its ledger
function GetCurrentResourceName() return 'pfm-banking' end
Config = nil
load_resource('pfm-banking/config.lua')
load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')
Mock.exportsByResource['pfm-banking'] = Mock.exportsByResource['__self']
Mock.exportsByResource['__self'] = nil
assert(PFLedger.Start(), 'ledger start')
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, resource, list) return RunMigrations(resource, list) end

-- pf-devices
load_resource('[pfscripts]/pf-devices/shared/config.lua')
function GetCurrentResourceName() return 'pf-devices' end
for _, f in ipairs({ 'registry', 'installs', 'rpc', 'push', 'sites', 'builtin_apps', 'main' }) do
    load_resource('[pfscripts]/pf-devices/server/' .. f .. '.lua')
end
Mock.exportsByResource['pf-devices'] = Mock.exportsByResource['__self']
Mock.exportsByResource['__self'] = nil

-- pfm-crypto
function GetCurrentResourceName() return 'pfm-crypto' end
load_resource('pfm-banking/payouts.lua')
load_resource('pfm-crypto/config.lua')
load_resource('pfm-crypto/server/main.lua')
load_resource('pfm-crypto/server/app.lua')
Mock.invokingResource = 'pfm-crypto'
local startedOk = CryptoApp.Start()
Mock.invokingResource = nil

local P = 1
local me = Mock.newPlayer(P, 'CRY00001')
me.PlayerData.money = { cash = 0, bank = 2000, crypto = 0 }
me.PlayerData.metadata.walletid = 'W-ONLINE-1'
Crypto.Worth['qbit'] = 250

local function rpc(method, payload)
    Mock.gameTimer = Mock.gameTimer + 5000
    PFDevices.__resetRpc()
    return PFDevices.HandleRpc(P, 'crypto', method, payload)
end
local function count(sql, params) return tonumber(MySQL.scalar.await(sql, params)) end

describe('the crypto migration', function()
    it('creates its tables (and the stock crypto table) and reruns as a no-op', function()
        assert_true(startedOk)
        assert_eq(count("SELECT COUNT(*) FROM crypto WHERE crypto = 'qbit'"), 1)
        local before = count("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = 'pfm-crypto'")
        assert_true(CryptoApp.Start())
        assert_eq(count("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = 'pfm-crypto'"), before)
        assert_true(PFDevices.GetApp('crypto') ~= nil)
    end)
end)

describe('trades on a real database', function()
    it('buys exactly once per id, the bank side on the ledger', function()
        local first = rpc('buy', { coins = 1.25, ref = 'rt-buy-000001' })
        assert_true(first.ok, tostring(first.error))
        assert_eq(first.total, 313, 'rounded up: 1.25 x 250 = 312.5')
        assert_true(rpc('buy', { coins = 1.25, ref = 'rt-buy-000001' }).duplicate)
        assert_eq(me.PlayerData.money.bank, 2000 - 313)
        assert_eq(me.PlayerData.money.crypto, 1.25)
        assert_eq(count("SELECT COUNT(*) FROM pf_transactions WHERE idempotency_key = 'pfm-crypto:buy:CRY00001:rt-buy-000001:bank' AND state = 'completed' AND to_account = 'system:pfm-crypto'"), 1)
    end)
    it('sells exactly once per id, paying from the exchange', function()
        local first = rpc('sell', { coins = 0.5, ref = 'rt-sell-00001' })
        assert_true(first.ok, tostring(first.error))
        assert_eq(first.total, 125)
        assert_true(rpc('sell', { coins = 0.5, ref = 'rt-sell-00001' }).duplicate)
        assert_eq(me.PlayerData.money.crypto, 0.75)
        assert_eq(me.PlayerData.money.bank, 2000 - 313 + 125)
        assert_eq(count("SELECT COUNT(*) FROM pf_transactions WHERE idempotency_key = 'pfm-crypto:sell:CRY00001:rt-sell-00001' AND state = 'completed'"), 1)
    end)
    it('sends coins to an offline wallet once, in one atomic update', function()
        assert_true(rpc('send', { walletId = 'W-OFFLINE-2', coins = 0.25, ref = 'rt-send-00001' }).ok)
        assert_true(rpc('send', { walletId = 'W-OFFLINE-2', coins = 0.25, ref = 'rt-send-00001' }).duplicate)
        assert_eq(me.PlayerData.money.crypto, 0.5)
        local stored = json.decode(MySQL.scalar.await("SELECT money FROM players WHERE citizenid = 'CRY00002'"))
        assert_near(tonumber(stored.crypto), 1.75, 0.000001)
        assert_eq(count("SELECT COUNT(*) FROM pf_crypto_transfers WHERE transfer_key = 'pfm-crypto:send:CRY00001:rt-send-00001' AND to_cid = 'CRY00002'"), 1)
        local dup = pcall(MySQL.insert.await, "INSERT INTO pf_crypto_transfers (transfer_key, from_cid, to_cid, coins) VALUES ('pfm-crypto:send:CRY00001:rt-send-00001', 'a', 'b', 1)")
        assert_false(dup, 'the transfer key is unique in the database')
    end)
    it('lists the trades and transfers in the history', function()
        local h = rpc('history', {})
        assert_true(h.ok)
        assert_eq(#h.trades, 2)
        assert_eq(h.trades[1].side, 'sell')
        assert_eq(h.trades[1].coins, 0.5)
        assert_eq(h.trades[2].side, 'buy')
        assert_eq(h.trades[2].price, 250)
        assert_eq(#h.transfers, 1)
        assert_eq(h.transfers[1].direction, 'out')
        assert_eq(h.transfers[1].to, nil, 'the other wallet is not named')
    end)
end)

describe('price history', function()
    it('records every price change and reports the 24 hour change', function()
        CryptoApp.OnPrice('qbit', 200)
        CryptoApp.OnPrice('qbit', 240)
        CryptoApp.OnPrice('qbit', 250)
        MySQL.update.await("UPDATE pf_crypto_prices SET created_at = NOW() - INTERVAL 2 DAY WHERE worth = 200")
        local m = rpc('market', {})
        assert_true(m.ok)
        assert_eq(#m.history, 3)
        assert_eq(m.history[1].price, 200, 'oldest first')
        assert_eq(m.history[3].price, 250)
        assert_eq(m.change.from, 200)
        assert_eq(m.change.pct, 25)
        assert_eq(m.wallet.coins, 0.5)
        assert_eq(m.wallet.value, 125)
    end)
end)

-- a trade id the app kept after a lost answer never stands for another trade
describe('a reused trade id on a real database', function()
    it('buy and sell answer with the stored trade and refuse another amount', function()
        Crypto.Worth['qbit'] = 250
        local bank, coins = me.PlayerData.money.bank, me.PlayerData.money.crypto
        assert_eq(rpc('buy', { coins = 0.1, ref = 'rt-reuse-buy01' }).total, 25)
        assert_eq(rpc('buy', { coins = 0.2, ref = 'rt-reuse-buy01' }).error, 'already_processed')
        Crypto.Worth['qbit'] = 300
        local again = rpc('buy', { coins = 0.1, ref = 'rt-reuse-buy01' })
        assert_true(again.ok and again.duplicate)
        assert_eq(again.total, 25, 'the stored cost, not one at the new price')
        assert_eq(again.price, 250)
        assert_near(again.coins, 0.1, 0.000001)
        Crypto.Worth['qbit'] = 250
        assert_true(rpc('sell', { coins = 0.1, ref = 'rt-reuse-sell1' }).ok)
        assert_eq(rpc('sell', { coins = 0.2, ref = 'rt-reuse-sell1' }).error, 'already_processed')
        local sold = rpc('sell', { coins = 0.1, ref = 'rt-reuse-sell1' })
        assert_true(sold.duplicate)
        assert_eq(sold.total, 25)
        assert_eq(me.PlayerData.money.bank, bank)
        assert_near(me.PlayerData.money.crypto, coins, 0.000001)
    end)
    it('send refuses another amount or another wallet under the same id', function()
        addPlayer('CRY00003', { cash = 0, bank = 0, crypto = 0 }, 'W-OFFLINE-3')
        local coins = me.PlayerData.money.crypto
        assert_true(rpc('send', { walletId = 'W-OFFLINE-2', coins = 0.05, ref = 'rt-reuse-send1' }).ok)
        assert_eq(rpc('send', { walletId = 'W-OFFLINE-2', coins = 0.06, ref = 'rt-reuse-send1' }).error, 'already_processed')
        assert_eq(rpc('send', { walletId = 'W-OFFLINE-3', coins = 0.05, ref = 'rt-reuse-send1' }).error, 'already_processed')
        local same = rpc('send', { walletId = 'W-OFFLINE-2', coins = 0.05, ref = 'rt-reuse-send1' })
        assert_true(same.ok and same.duplicate)
        assert_near(same.coins, 0.05, 0.000001)
        assert_near(me.PlayerData.money.crypto, coins - 0.05, 0.000001)
        local third = json.decode(MySQL.scalar.await("SELECT money FROM players WHERE citizenid = 'CRY00003'"))
        assert_near(tonumber(third.crypto) or 0, 0, 0.000001)
        assert_eq(count("SELECT COUNT(*) FROM pf_crypto_transfers WHERE transfer_key = 'pfm-crypto:send:CRY00001:rt-reuse-send1'"), 1)
    end)
end)
