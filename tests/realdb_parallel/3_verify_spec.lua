-- Parallel ledger test, step 3: after all workers finished. Expected totals for N workers
-- (PF_RT_WORKER carries N here): shared keys once, own keys once per worker.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function GetCurrentResourceName() return 'pfm-banking' end
function GetResourceState() return 'started' end
Config = nil
load_resource('pfm-banking/config.lua')
load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')

local N = tonumber(__TEST_WORKER) or 1
local ROUNDS = 60
local function bank(cid) return tonumber(json.decode(MySQL.scalar.await('SELECT money FROM players WHERE citizenid = ?', { cid })).bank) end
local function soc() return tonumber(MySQL.scalar.await("SELECT account_balance FROM bank_accounts WHERE account_name = 'parsoc'")) end

describe('after the parallel run', function()
    it('each shared key moved money once and each own key once', function()
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_transactions WHERE idempotency_key LIKE 'par:shared:%'")), ROUNDS * 2)
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_transactions WHERE idempotency_key LIKE 'par:own:%'")), ROUNDS * N)
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_transactions WHERE idempotency_key LIKE 'par:%' AND state <> 'completed'")), 0)
    end)
    it('balances add up exactly', function()
        assert_eq(bank('PARB0001'), ROUNDS * 10 + ROUNDS * 5)
        assert_eq(bank('PARA0001'), 100000 - ROUNDS * 5 - ROUNDS * N)
        assert_eq(soc(), 100000 - ROUNDS * 10 + ROUNDS * N)
    end)
    it('reconciliation finds nothing wrong', function()
        assert_true(PFLedger.Start())
        local report = PFLedger.Reconcile()
        assert_eq(#(report.mismatches or {}), 0)
    end)
end)
