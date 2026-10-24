-- The pfm-banking ledger and its migrations against a real MariaDB/MySQL database.
-- Run with: PF_TEST_DB="mysql://root@127.0.0.1:3399" node realdb/run.js
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function GetCurrentResourceName() return 'pfm-banking' end
function GetResourceState() return 'started' end

-- the stock schema a server has before any PF migration, plus existing data that must survive
RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
MySQL.query.await("INSERT INTO players (citizenid, cid, license, name, money, charinfo, job, gang, position, metadata, inventory) VALUES ('OLD00001', 1, 'license:old', 'Old', '{\"cash\":120,\"bank\":5000,\"crypto\":0}', '{}', '{}', '{}', '{}', '{}', '[]')")
MySQL.query.await("INSERT INTO bank_accounts (account_name, account_balance, account_type, users) VALUES ('mechanic', 7500, 'job', '[]')")

Config = nil
load_resource('pfm-banking/config.lua')
load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')
local L = PFLedger

local ONLINE = 1
local function society(name)
    return tonumber(MySQL.scalar.await('SELECT account_balance FROM bank_accounts WHERE account_name = ?', { name }))
end
local function offlineBank(cid)
    local money = json.decode(MySQL.scalar.await('SELECT money FROM players WHERE citizenid = ?', { cid }))
    return tonumber(money.bank)
end
local function txState(key)
    return MySQL.scalar.await('SELECT state FROM pf_transactions WHERE idempotency_key = ?', { key })
end
local function age(key, seconds)
    MySQL.update.await('UPDATE pf_transactions SET updated_at = NOW() - INTERVAL ? SECOND WHERE idempotency_key = ?', { seconds, key })
end
-- makes the next execution of one ledger statement raise, like a crash at that point
local failNext = {}
local realUpdate = MySQL.update.await
MySQL.update.await = function(query, params)
    for name, sql in pairs(L.SQL) do
        if sql == query and failNext[name] then
            failNext[name] = nil
            error('simulated crash at ' .. name)
        end
    end
    return realUpdate(query, params)
end

describe('migrations on a real database', function()
    it('apply on a stock schema and keep existing balances', function()
        assert_true(L.Start(), 'ledger started')
        assert_eq(society('mechanic'), 7500)
        assert_eq(offlineBank('OLD00001'), 5000)
        local applied = tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = 'pfm-banking'"))
        assert_true(applied >= 3)
    end)
    it('rerun as a no-op', function()
        local before = tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM pf_schema_migrations'))
        L.ready = false
        assert_true(L.Start())
        assert_eq(tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM pf_schema_migrations')), before)
        assert_eq(society('mechanic'), 7500)
    end)
    it('the idempotency key is unique in the database itself', function()
        local ok = pcall(function()
            MySQL.query.await("INSERT INTO pf_transactions (tx_id, idempotency_key, kind, from_account, to_account, amount, state) VALUES ('t1','dup-key','x','system:a','system:b',1,'pending')")
            MySQL.query.await("INSERT INTO pf_transactions (tx_id, idempotency_key, kind, from_account, to_account, amount, state) VALUES ('t2','dup-key','x','system:a','system:b',1,'pending')")
        end)
        assert_false(ok, 'second row with the same key rejected')
        MySQL.query.await("DELETE FROM pf_transactions WHERE idempotency_key = 'dup-key'")
    end)
    it('a business society account can be created (account_type accepts business)', function()
        assert_true(L.EnsureSociety('store_7', 'business'))
        assert_eq(society('store_7'), 0)
    end)
end)

describe('transfers on a real database', function()
    it('moves money once per key and repeats the original result', function()
        local first = L.Transfer({ from = 'society:mechanic', to = 'system:test', amount = 250, key = 'rt:once', kind = 'test' })
        assert_true(first.ok)
        local again = L.Transfer({ from = 'society:mechanic', to = 'system:test', amount = 250, key = 'rt:once', kind = 'test' })
        assert_true(again.ok)
        assert_true(again.duplicate)
        assert_eq(again.txId, first.txId)
        assert_eq(society('mechanic'), 7250)
    end)
    it('refuses an overdraft and records it as failed', function()
        local res = L.Transfer({ from = 'society:mechanic', to = 'system:test', amount = 1000000, key = 'rt:overdraft', kind = 'test' })
        assert_false(res.ok)
        assert_eq(txState('rt:overdraft'), 'failed')
        assert_eq(society('mechanic'), 7250)
    end)
    it('credits an offline player in players.money', function()
        local res = L.Transfer({ from = 'system:test', to = 'player:OLD00001:bank', amount = 75.5, key = 'rt:offline', kind = 'test' })
        assert_true(res.ok)
        assert_eq(offlineBank('OLD00001'), 5075.5)
    end)
    it('debits an online player in memory and credits the database account', function()
        Mock.players = {}
        local p = Mock.newPlayer(ONLINE, 'ONL00001')
        p.PlayerData.money = { cash = 0, bank = 1000 }
        local res = L.Transfer({ from = 'player:ONL00001:bank', to = 'society:mechanic', amount = 400, key = 'rt:online', kind = 'test' })
        assert_true(res.ok)
        assert_eq(p.PlayerData.money.bank, 600)
        assert_eq(society('mechanic'), 7650)
    end)
end)

describe('recovery after a crash, on a real database', function()
    it('a crash after the debit is completed by recovery, crediting once', function()
        failNext.creditSociety = true
        local res = L.Transfer({ from = 'system:test', to = 'society:mechanic', amount = 100, key = 'rt:crash-credit', kind = 'test' })
        assert_false(res.ok)
        local s = txState('rt:crash-credit')
        assert_true(s == 'debited' or s == 'pending', 'left in progress: ' .. tostring(s))
        assert_eq(society('mechanic'), 7650, 'not credited yet')
        age('rt:crash-credit', 600)
        L.Recover()
        assert_eq(txState('rt:crash-credit'), 'completed')
        assert_eq(society('mechanic'), 7750)
        L.Recover()
        assert_eq(society('mechanic'), 7750, 'recovering twice credits once')
    end)
    it('a crash before the debit is failed by recovery and moves nothing', function()
        failNext.debitSociety = true
        local res = L.Transfer({ from = 'society:mechanic', to = 'system:test', amount = 100, key = 'rt:crash-debit', kind = 'test' })
        assert_false(res.ok)
        age('rt:crash-debit', 600)
        L.Recover()
        assert_eq(txState('rt:crash-debit'), 'failed')
        assert_eq(society('mechanic'), 7750)
    end)
    it('recovery never completes a transfer whose debit did not happen', function()
        MySQL.query.await("INSERT INTO pf_transactions (tx_id, idempotency_key, kind, from_account, to_account, amount, state, updated_at) VALUES ('ghost1','rt:ghost','test','society:mechanic','system:test',500,'pending', NOW() - INTERVAL 600 SECOND)")
        L.Recover()
        assert_eq(txState('rt:ghost'), 'failed')
        assert_eq(society('mechanic'), 7750)
    end)
    it('a retry with the key of a crashed transfer reports the outcome instead of paying again', function()
        local res = L.Transfer({ from = 'system:test', to = 'society:mechanic', amount = 100, key = 'rt:crash-credit', kind = 'test' })
        assert_true(res.ok)
        assert_true(res.duplicate)
        assert_eq(society('mechanic'), 7750)
    end)
end)

describe('reconciliation on a real database', function()
    it('finds no mismatch after legitimate transfers, and flags a direct balance edit', function()
        local report = L.Reconcile()
        for _, m in ipairs(report.mismatches) do print('mismatch', m.account, m.expected, m.actual) end
        assert_eq(#report.mismatches, 0)
        MySQL.update.await("UPDATE bank_accounts SET account_balance = account_balance + 999 WHERE account_name = 'mechanic'")
        report = L.Reconcile()
        local found = false
        for _, m in ipairs(report.mismatches) do if m.account == 'mechanic' then found = true end end
        assert_true(found, 'the edit outside the ledger is reported')
    end)
end)
