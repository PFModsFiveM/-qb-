-- Parallel ledger test, step 1 (run once by realdb/ledger_parallel.js): schema, migrations, accounts.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function GetCurrentResourceName() return 'pfm-banking' end
function GetResourceState() return 'started' end
RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
for _, cid in ipairs({ 'PARA0001', 'PARB0001' }) do
    MySQL.query.await("INSERT INTO players (citizenid, cid, license, name, money, charinfo, job, gang, position, metadata, inventory) VALUES (?, 1, ?, 'Par', ?, '{}', '{}', '{}', '{}', '{}', '[]')",
        { cid, 'license:' .. cid, cid == 'PARA0001' and '{"cash":0,"bank":100000,"crypto":0}' or '{"cash":0,"bank":0,"crypto":0}' })
end
MySQL.query.await("INSERT INTO bank_accounts (account_name, account_balance, account_type, users) VALUES ('parsoc', 100000, 'job', '[]')")
Config = nil
load_resource('pfm-banking/config.lua')
load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')

describe('parallel ledger setup', function()
    it('migrations applied and accounts in place', function()
        assert_true(PFLedger.Start())
        assert_eq(tonumber(MySQL.scalar.await("SELECT account_balance FROM bank_accounts WHERE account_name = 'parsoc'")), 100000)
    end)
end)
