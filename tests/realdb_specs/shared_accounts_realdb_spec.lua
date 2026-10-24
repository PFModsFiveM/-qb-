-- Moving legacy shared accounts (bank_accounts 'shared') into IBAN accounts, on a real database.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function GetCurrentResourceName() return 'pfm-banking' end
function GetResourceState() return 'started' end

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
-- two legacy shared accounts as an existing server has them
MySQL.query.await([[INSERT INTO bank_accounts (citizenid, account_name, account_balance, account_type, users)
    VALUES ('OWNA0001', 'family_fund', 3200, 'shared', '["MEMB0001","MEMB0002"]'),
           ('OWNB0001', 'empty_club', 0, 'shared', '[]'),
           (NULL, 'police', 9000, 'job', '[]')]])

Config = nil
load_resource('pfm-banking/config.lua')
load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server_shared_migration.lua')
local L = PFLedger
assert(L.Start(), 'ledger start')

local function legacyRows() return MySQL.query.await('SELECT * FROM bank_accounts') end
local function v2(label) return MySQL.single.await('SELECT * FROM bank_accounts_v2 WHERE label = ?', { label }) end
local function member(id, cid) return MySQL.single.await('SELECT * FROM bank_account_members WHERE account_id = ? AND citizenid = ?', { id, cid }) end
local function legacyBalance(name) return tonumber(MySQL.scalar.await('SELECT account_balance FROM bank_accounts WHERE account_name = ?', { name })) end

describe('legacy shared accounts become IBAN accounts', function()
    it('moves the account, its members and its balance', function()
        local moved = MigrateLegacySharedAccounts(legacyRows())
        assert_true(moved.family_fund)
        assert_true(moved.empty_club)
        assert_eq(moved.police, nil, 'job accounts are not touched')
        local acct = v2('family_fund')
        assert_true(acct ~= nil)
        assert_eq(acct.owner, 'OWNA0001')
        assert_eq(tonumber(acct.balance), 3200)
        assert_eq(legacyBalance('family_fund'), 0)
        assert_eq(legacyBalance('police'), 9000)
        local owner = member(acct.id, 'OWNA0001')
        assert_eq(tonumber(owner.can_manage), 1)
        local m = member(acct.id, 'MEMB0002')
        assert_eq(tonumber(m.can_withdraw), 1)
        assert_eq(tonumber(m.can_deposit), 1)
        assert_eq(tonumber(m.can_manage), 0)
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_transactions WHERE kind = 'migration' AND state = 'completed'")), 1)
    end)
    it('rerunning creates no second account and moves nothing twice', function()
        MigrateLegacySharedAccounts(legacyRows())
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM bank_accounts_v2 WHERE label = 'family_fund'")), 1)
        assert_eq(tonumber(v2('family_fund').balance), 3200)
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_transactions WHERE kind = 'migration'")), 1)
    end)
    it('the books still balance after the move', function()
        local report = L.Reconcile()
        for _, mm in ipairs(report.mismatches) do print('mismatch', mm.account, mm.expected, mm.actual) end
        assert_eq(#report.mismatches, 0)
    end)
end)
