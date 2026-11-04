-- Batch 15 unit 15E, pf-government keyed department society moves and the CreateBill passthrough, on a
-- real database with the real ledger:
--   - SpendFromDepartmentSociety / AddFundsToDepartmentSociety with a key move money once per key
--     (a retry returns the first result); without a key they behave as before (each call moves);
--   - the same key with other arguments is refused (key_reused);
--   - a move the ledger clearly refused is retried under the next numbered ledger key (<key>:2);
--   - an unclear ledger answer is held: no money moves under a new key, the reconcile books it once;
--   - the CreateBill export passes issuedBy, issuedByName and recurring, so a recurring bill dedupes.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
local states = { ['pf-services'] = 'missing', ['pfm-houses'] = 'missing', ['pfm-phone'] = 'missing' }
function GetResourceState(name) return states[name] or 'started' end
vec3 = vec3 or vector3
vec4 = vec4 or vector4
GlobalState = {}

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
function GetCurrentResourceName() return 'pfm-banking' end
Config = nil
load_resource('pfm-banking/config.lua')
load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')
Mock.exportsByResource['pfm-banking'] = Mock.exportsByResource['__self']
Mock.exportsByResource['__self'] = nil
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end
assert(PFLedger.Start(), 'ledger start')

RealDB.exec('[pfscripts]/pf-government/sql/install.sql')
function GetCurrentResourceName() return 'pf-government' end
QBCoreMock.Shared.Jobs = { government = { label = 'Government', grades = {} } }
Config = nil
load_resource('pfm-banking/payouts.lua')
for _, f in ipairs({ 'config.lua', 'server/core.lua', 'server/schema.lua', 'server/treasury.lua', 'server/budgets.lua',
    'server/bills.lua', 'server/audit.lua', 'server/main.lua' }) do
    load_resource('[pfscripts]/pf-government/' .. f)
end
function NotifyGovernment() end
function DebugPrint() end
Mock.exportsByResource['pf-government'] = Mock.exportsByResource['__self']
Mock.exportsByResource['__self'] = nil
assert(GovSchema.Ensure(), 'government migrations')
InitializeTreasury()
InitializeBudgets()

local function num(v) return tonumber(v) or 0 end
local function scalar(q, p) return MySQL.scalar.await(q, p or {}) end
local function society(name) return num(scalar('SELECT account_balance FROM bank_accounts WHERE account_name = ?', { name })) end
local function spent(dept) return num(scalar('SELECT spent_this_month FROM pf_gov_department_monthly_plans WHERE department = ? AND month_key = ?', { dept, os.date('%Y-%m') })) end
local function txs(prefix) return num(scalar('SELECT COUNT(*) FROM pf_transactions WHERE idempotency_key LIKE ?', { prefix .. '%' })) end
local function row(key) return MySQL.single.await('SELECT * FROM pf_gov_budget_transactions WHERE idem_key = ?', { key }) end
local gov = exports['pf-government']

local n = 0
local function fresh(prefix) n = n + 1 return ('pf-government:dept:police:%s:%d'):format(prefix, n) end
assert(exports['pfm-banking']:AddMoney('police', 20000, 'spec funding', 'spec:police:seed'))
assert(exports['pfm-banking']:AddMoney('government', 50000, 'spec funding', 'spec:gov:seed'))

describe('keyed spend', function()
    it('the same key twice moves money once and books it once', function()
        local key = fresh('equipment')
        local s0, sp0 = society('police'), spent('police')
        local ok, snap = gov:SpendFromDepartmentSociety('police', 1000, 'equipment', 'CID1', 'Chief', 'Radios', key)
        assert_true(ok, tostring(snap))
        assert_eq(society('police'), s0 - 1000)
        local ok2, snap2, dup = gov:SpendFromDepartmentSociety('police', 1000, 'equipment', 'CID1', 'Chief', 'Radios', key)
        assert_true(ok2)
        assert_eq(dup, 'duplicate')
        assert_true(type(snap2) == 'table')
        assert_eq(society('police'), s0 - 1000, 'no second move')
        assert_eq(spent('police'), sp0 + 1000, 'booked once')
        assert_eq(txs(key), 1)
        local r = row(key)
        assert_eq(r.state, 'applied')
        assert_eq(r.ledger_key, key .. ':1')
        local tx = MySQL.single.await('SELECT * FROM pf_transactions WHERE idempotency_key = ?', { key .. ':1' })
        assert_eq(tx.from_account, 'society:police')
        assert_eq(tx.state, 'completed')
    end)
    it('without a key it behaves as before: every call moves', function()
        local s0 = society('police')
        assert_true((gov:SpendFromDepartmentSociety('police', 100, 'operations', 'CID1', 'Chief', 'Coffee')))
        assert_true((gov:SpendFromDepartmentSociety('police', 100, 'operations', 'CID1', 'Chief', 'Coffee')))
        assert_eq(society('police'), s0 - 200)
        assert_eq(num(scalar("SELECT COUNT(*) FROM pf_gov_budget_transactions WHERE reason = 'Coffee' AND idem_key IS NULL AND state IS NULL")), 2)
    end)
    it('a key reused with other arguments is refused; bad keys and amounts are refused', function()
        local key = fresh('vehicles')
        assert_true((gov:SpendFromDepartmentSociety('police', 300, 'vehicles', 'CID1', 'Chief', 'Car', key)))
        local s0 = society('police')
        local ok, err = gov:SpendFromDepartmentSociety('police', 301, 'vehicles', 'CID1', 'Chief', 'Car', key)
        assert_false(ok)
        assert_eq(err, 'key_reused')
        assert_eq(select(2, gov:SpendFromDepartmentSociety('ems', 300, 'vehicles', 'CID1', 'Chief', 'Car', key)), 'key_reused')
        assert_eq(select(2, gov:SpendFromDepartmentSociety('police', 300, 'vehicles', 'CID1', 'Chief', 'Car', 'bad key!')), 'invalid_key')
        assert_eq(select(2, gov:SpendFromDepartmentSociety('police', 300, 'vehicles', 'CID1', 'Chief', 'Car', string.rep('k', 121))), 'invalid_key')
        assert_eq(select(2, gov:SpendFromDepartmentSociety('police', -5, 'vehicles', 'CID1', 'Chief', 'Car', fresh('neg'))), 'invalid_amount')
        assert_eq(select(2, gov:SpendFromDepartmentSociety('police', 5, 'bribes', 'CID1', 'Chief', 'Car', fresh('cat'))), 'invalid_category')
        assert_eq(society('police'), s0)
    end)
    it('a clear ledger refusal fails the attempt; the same key then moves under the next numbered key', function()
        local key = fresh('emergency')
        local real = society('police')
        -- the cached balance still shows the money, but the account is empty: the ledger refuses
        MySQL.update.await("UPDATE bank_accounts SET account_balance = 0 WHERE account_name = 'police'")
        local ok, err = gov:SpendFromDepartmentSociety('police', 500, 'emergency', 'CID1', 'Chief', 'Generator', key)
        assert_false(ok)
        assert_eq(err, 'insufficient_society_funds')
        assert_eq(row(key).state, 'failed')
        assert_eq(MySQL.single.await('SELECT state FROM pf_transactions WHERE idempotency_key = ?', { key .. ':1' }).state, 'failed')
        MySQL.update.await("UPDATE bank_accounts SET account_balance = ? WHERE account_name = 'police'", { real })
        local sp0 = spent('police')
        local ok2 = gov:SpendFromDepartmentSociety('police', 500, 'emergency', 'CID1', 'Chief', 'Generator', key)
        assert_true(ok2)
        assert_eq(row(key).state, 'applied')
        assert_eq(row(key).ledger_key, key .. ':2')
        assert_eq(society('police'), real - 500)
        assert_eq(spent('police'), sp0 + 500)
        assert_eq(txs(key), 2)
    end)
    it('an unclear ledger answer is held: no new key, nothing more moves; the reconcile books it once', function()
        local key = fresh('maintenance')
        local s0, sp0 = society('police'), spent('police')
        -- attempt 1 is in the ledger, still pending (the bank crashed mid-transfer)
        MySQL.insert.await([[INSERT INTO pf_transactions (tx_id, idempotency_key, kind, from_account, to_account, amount, state)
            VALUES ('TXBUDGETSPEC1', ?, 'withdraw', 'society:police', 'system:pf-government', 700, 'pending')]], { key .. ':1' })
        local ok, err = gov:SpendFromDepartmentSociety('police', 700, 'maintenance', 'CID1', 'Chief', 'Roof', key)
        assert_false(ok)
        assert_eq(err, 'payment_unclear')
        assert_eq(select(2, gov:SpendFromDepartmentSociety('police', 700, 'maintenance', 'CID1', 'Chief', 'Roof', key)), 'payment_unclear')
        assert_eq(txs(key), 1, 'never a second ledger key while unclear')
        assert_eq(row(key).state, 'pending')
        assert_eq(ReconcileBudgetMoves(), 0, 'still unknown: left pending')
        -- the ledger settles it as completed (as its recovery would, debiting the society)
        MySQL.update.await("UPDATE bank_accounts SET account_balance = account_balance - 700 WHERE account_name = 'police'")
        MySQL.update.await("UPDATE pf_transactions SET state = 'completed' WHERE idempotency_key = ?", { key .. ':1' })
        assert_eq(ReconcileBudgetMoves(), 1)
        assert_eq(row(key).state, 'applied')
        assert_eq(spent('police'), sp0 + 700, 'booked once')
        assert_eq(ReconcileBudgetMoves(), 0)
        local ok3, _, dup = gov:SpendFromDepartmentSociety('police', 700, 'maintenance', 'CID1', 'Chief', 'Roof', key)
        assert_true(ok3)
        assert_eq(dup, 'duplicate')
        assert_eq(spent('police'), sp0 + 700)
        assert_eq(society('police'), s0 - 700)
    end)
    it('a refused pending attempt found by the reconcile becomes failed, and a retry uses the next key', function()
        local key = fresh('upgrades')
        MySQL.insert.await([[INSERT INTO pf_transactions (tx_id, idempotency_key, kind, from_account, to_account, amount, state)
            VALUES ('TXBUDGETSPEC2', ?, 'withdraw', 'society:police', 'system:pf-government', 50, 'pending')]], { key .. ':1' })
        assert_eq(select(2, gov:SpendFromDepartmentSociety('police', 50, 'upgrades', 'CID1', 'Chief', 'x', key)), 'payment_unclear')
        MySQL.update.await("UPDATE pf_transactions SET state = 'failed', error = 'insufficient_funds' WHERE idempotency_key = ?", { key .. ':1' })
        assert_eq(ReconcileBudgetMoves(), 1)
        assert_eq(row(key).state, 'failed')
        local s0 = society('police')
        assert_true((gov:SpendFromDepartmentSociety('police', 50, 'upgrades', 'CID1', 'Chief', 'x', key)))
        assert_eq(row(key).ledger_key, key .. ':2')
        assert_eq(society('police'), s0 - 50)
    end)
end)

describe('keyed treasury funding', function()
    it('moves from the treasury account to the department society once per key, in one ledger transfer', function()
        local key = 'pf-government:dept:corrections:funding:2026-11'
        local t0, c0 = society('government'), society('corrections')
        local ok, snap = gov:AddFundsToDepartmentSociety('corrections', 4000, 'CIDM', 'Mayor', 'Monthly funding', key)
        assert_true(ok, tostring(snap))
        assert_eq(society('government'), t0 - 4000)
        assert_eq(society('corrections'), c0 + 4000)
        local ok2, _, dup = gov:AddFundsToDepartmentSociety('corrections', 4000, 'CIDM', 'Mayor', 'Monthly funding', key)
        assert_true(ok2)
        assert_eq(dup, 'duplicate')
        assert_eq(society('government'), t0 - 4000)
        assert_eq(society('corrections'), c0 + 4000)
        local tx = MySQL.single.await('SELECT * FROM pf_transactions WHERE idempotency_key = ?', { key .. ':1' })
        assert_eq(tx.from_account, 'society:government')
        assert_eq(tx.to_account, 'society:corrections')
        assert_eq(row(key).transaction_type, 'treasury_funding')
        assert_eq(row(key).state, 'applied')
        -- the treasury mirror follows the account
        assert_eq(num(GetTreasuryBalance()), society('government'))
    end)
    it('without a key it behaves as before', function()
        local t0, d0 = society('government'), society('doj')
        assert_true((gov:AddFundsToDepartmentSociety('doj', 250, 'CIDM', 'Mayor', 'Court costs')))
        assert_true((gov:AddFundsToDepartmentSociety('doj', 250, 'CIDM', 'Mayor', 'Court costs')))
        assert_eq(society('government'), t0 - 500)
        assert_eq(society('doj'), d0 + 500)
    end)
    it('more than the treasury holds is refused before anything moves', function()
        local key = 'pf-government:dept:doj:funding:huge'
        local t0 = society('government')
        local ok, err = gov:AddFundsToDepartmentSociety('doj', t0 + 1, 'CIDM', 'Mayor', 'Too much', key)
        assert_false(ok)
        assert_eq(err, 'Insufficient treasury funds')
        assert_eq(row(key), nil)
        assert_eq(society('government'), t0)
    end)
end)

describe('CreateBill export passthrough', function()
    it('passes issuedBy, issuedByName and recurring: a recurring bill is created once per ref and period', function()
        local recurring = { ref = 'house:spec_villa', period = '2026-11-02' }
        local ok, msg, id = gov:CreateBill('citizen', 'CIDB1', 120, 'property_tax', nil, 'Weekly property tax', 'system', 'City Hall', recurring)
        assert_true(ok, tostring(msg))
        local b = MySQL.single.await('SELECT * FROM pf_gov_bills WHERE id = ?', { id })
        assert_eq(b.bill_ref, 'house:spec_villa')
        assert_eq(b.bill_period, '2026-11-02')
        assert_eq(b.issued_by, 'system')
        assert_eq(b.issued_by_name, 'City Hall')
        local ok2, err2, existing = gov:CreateBill('citizen', 'CIDB1', 120, 'property_tax', nil, 'Weekly property tax', 'system', 'City Hall', recurring)
        assert_false(ok2)
        assert_eq(err2, 'duplicate')
        assert_eq(existing, id)
        assert_eq(num(scalar("SELECT COUNT(*) FROM pf_gov_bills WHERE bill_ref = 'house:spec_villa'")), 1)
        -- a bill without recurring is still a plain bill each time
        assert_true((gov:CreateBill('citizen', 'CIDB1', 10, 'fine', nil, 'Littering')))
        assert_true((gov:CreateBill('citizen', 'CIDB1', 10, 'fine', nil, 'Littering')))
        assert_eq(num(scalar("SELECT COUNT(*) FROM pf_gov_bills WHERE target_id = 'CIDB1' AND description = 'Littering'")), 2)
        -- the six-argument form names the calling resource as the issuer
        assert_eq(scalar("SELECT issued_by FROM pf_gov_bills WHERE description = 'Littering' LIMIT 1"), 'resource:pf-government')
    end)
end)
