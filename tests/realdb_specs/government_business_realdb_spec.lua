-- pf-government business registry on a real database: restaurants register under their owner, each
-- sale is recorded once, business tax moves from the restaurant's own account to the treasury (never
-- created), an underfunded business is billed instead, and a closure or a power cut stops trading
-- until the delinquent bill is paid.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
GetInvokingResource = GetInvokingResource or function() return nil end
local states = { ['pfm-cityhall'] = 'missing' }
function GetResourceState(name) return states[name] or 'started' end
vec3 = vec3 or vector3
vec4 = vec4 or vector4 or function(x, y, z, w) return { x = x, y = y, z = z, w = w } end

-- the bank
RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
function GetCurrentResourceName() return 'pfm-banking' end
Config = nil
load_resource('pfm-banking/config.lua')
load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')
Mock.exportsByResource['pfm-banking'] = Mock.exportsByResource['__self']
assert(PFLedger.Start(), 'ledger start')

-- pf-government
RealDB.exec('[pfscripts]/pf-government/sql/install.sql')
function GetCurrentResourceName() return 'pf-government' end
QBCoreMock.Shared.Jobs = { government = { label = 'Government' } }
Config = nil
load_resource('pfm-banking/payouts.lua')
for _, f in ipairs({ 'config.lua', 'server/core.lua', 'server/treasury.lua', 'server/taxes.lua', 'server/utilities.lua',
    'server/bills.lua', 'server/businesses.lua', 'server/audit.lua', 'server/licenses.lua', 'server/integrations.lua',
    'server/staff.lua', 'server/callbacks.lua' }) do
    load_resource('[pfscripts]/pf-government/' .. f)
end
function NotifyGovernment() end
function DebugPrint() end
Mock.exportsByResource['pf-government'] = Mock.exportsByResource['__self']
InitializeTreasury()
InitializeTaxes()
InitializeBusinesses()

local BIZ = 'restaurant:bs'
local function society(name) return tonumber(MySQL.scalar.await('SELECT account_balance FROM bank_accounts WHERE account_name = ?', { name })) end
local function setSociety(name, amount)
    MySQL.query.await("INSERT INTO bank_accounts (account_name, account_balance, account_type, users) VALUES (?, ?, 'business', '[]') ON DUPLICATE KEY UPDATE account_balance = VALUES(account_balance)", { name, amount })
    MySQL.query.await('INSERT IGNORE INTO pf_ledger_baselines (account, balance) VALUES (?, ?)', { 'society:' .. name, amount })
end
local function business() return MySQL.single.await('SELECT * FROM pf_gov_businesses WHERE business_id = ?', { BIZ }) end
local function report(amount, key) TriggerEvent('pf-restaurants:server:addRevenue', 'bs', amount, key) end
local function trade() return exports['pf-government']:CanBusinessTrade(BIZ) end

describe('restaurants in the government registry', function()
    it('register under their owner, and re-registering updates the owner', function()
        TriggerEvent('pf-restaurants:server:registerBusiness', 'bs', 'Burger Shot', 'CID1')
        assert_eq(business().owner_id, 'CID1')
        TriggerEvent('pf-restaurants:server:registerBusiness', 'bs', 'Burger Shot', 'CID2')
        assert_eq(business().owner_id, 'CID2')
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_gov_utilities WHERE property_type = 'business' AND property_id = ?", { BIZ })), 1)
        assert_true(trade())
    end)
    it('record each sale once and move the business tax from the restaurant to the treasury', function()
        setSociety('restaurant_bs', 1000)
        local treasuryBefore = society('government')
        report(500, 'restaurant:ORD1')
        report(500, 'restaurant:ORD1')          -- the same order again
        local rate = CalculateTax(100, 'business') / 100
        assert_true(rate > 0, 'business tax configured')
        assert_eq(tonumber(business().total_revenue), 500)
        assert_eq(society('restaurant_bs'), 1000 - 500 * rate)
        assert_eq(society('government'), treasuryBefore + 500 * rate)
        assert_eq(tonumber(business().total_taxes_paid), 500 * rate)
    end)
    it('an underfunded restaurant is billed; the treasury gets nothing it was not paid', function()
        setSociety('restaurant_bs', 0)
        local treasuryBefore = society('government')
        report(400, 'restaurant:ORD2')
        assert_eq(society('government'), treasuryBefore)
        assert_eq(society('restaurant_bs'), 0)
        local bill = MySQL.single.await("SELECT * FROM pf_gov_bills WHERE target_type = 'business' AND target_id = ? AND bill_type = 'tax'", { BIZ })
        assert_true(bill ~= nil, 'tax billed')
        assert_eq(MySQL.scalar.await("SELECT tax_state FROM pf_gov_business_revenue WHERE event_key = 'restaurant:ORD2'"), 'billed')
    end)
    it('a closed business or one without power cannot trade; paying the delinquent bill restores power', function()
        MySQL.update.await("UPDATE pf_gov_businesses SET business_status = 'closed' WHERE business_id = ?", { BIZ })
        local ok, why = trade()
        assert_eq(ok, false)
        assert_eq(why, 'closed')
        MySQL.update.await("UPDATE pf_gov_businesses SET business_status = 'active' WHERE business_id = ?", { BIZ })

        -- the tax bill goes delinquent and the power is cut, as the escalation does
        local bill = MySQL.single.await("SELECT * FROM pf_gov_bills WHERE target_id = ? AND bill_type = 'tax'", { BIZ })
        MySQL.update.await("UPDATE pf_gov_bills SET status = 'delinquent' WHERE id = ?", { bill.id })
        DisconnectService('business', BIZ, 'power', 'system', 'System', 'Delinquent bill #' .. bill.id)
        ok, why = trade()
        assert_eq(ok, false)
        assert_eq(why, 'no_power')

        assert_true(PayBill(bill.id, tonumber(bill.amount), 'CID2', 'Owner'))
        assert_true(trade(), 'power back once the last delinquent bill is paid')
    end)
    it('a cut-off made by staff stays after a payment', function()
        DisconnectService('business', BIZ, 'power', 'GOV1', 'Inspector', 'Safety')
        local id = CreateBill('business', BIZ, 10, 'utility', os.date('%Y-%m-%d %H:%M:%S', os.time() + 3600), 'Utility', 'system', 'Utilities')
        local bill = MySQL.single.await("SELECT * FROM pf_gov_bills WHERE target_id = ? AND bill_type = 'utility' ORDER BY id DESC LIMIT 1", { BIZ })
        assert_true(PayBill(bill.id, 10, 'CID2', 'Owner'))
        assert_eq(select(2, trade()), 'no_power')
    end)
end)

describe('business utility bills', function()
    local function utilityBills() return MySQL.query.await("SELECT * FROM pf_gov_bills WHERE target_id = ? AND bill_type = 'utility' ORDER BY id", { BIZ }) end
    it('are paid from the business account when it can, so a running business keeps its power', function()
        MySQL.update.await("UPDATE pf_gov_utilities SET power_status = 'active', water_status = 'active', disconnected_by = NULL WHERE property_id = ?", { BIZ })
        MySQL.query.await("DELETE FROM pf_gov_bills WHERE target_id = ? AND bill_type = 'utility'", { BIZ })
        assert_eq(business().account_ref, 'society:restaurant_bs')
        setSociety('restaurant_bs', 1000)
        local treasuryBefore = society('government')
        ProcessUtilityBilling()
        local due = Config.Utilities.PowerBillAmount + Config.Utilities.WaterBillAmount
        local bills = utilityBills()
        assert_eq(#bills, 1)
        assert_eq(bills[1].status, 'paid')
        assert_eq(society('restaurant_bs'), 1000 - due)
        assert_eq(society('government'), treasuryBefore + due)
        ProcessUtilityBilling()                                 -- the same billing day again: paid once
        assert_eq(society('restaurant_bs'), 1000 - due)
    end)
    it('stay open when the business cannot pay', function()
        MySQL.query.await("DELETE FROM pf_gov_bills WHERE target_id = ? AND bill_type = 'utility'", { BIZ })
        MySQL.query.await("DELETE FROM pf_transactions WHERE idempotency_key LIKE 'gov:utility:%'")
        setSociety('restaurant_bs', 10)
        ProcessUtilityBilling()
        local bills = utilityBills()
        assert_eq(bills[1].status, 'unpaid')
        assert_eq(society('restaurant_bs'), 10)
    end)
end)

describe('inspections from business resources', function()
    it('go on the government record and set compliance; bad input and unknown businesses are refused', function()
        assert_true(exports['pf-government']:RecordBusinessInspection(BIZ, 'flagged', 'Health rating F', 'CID9', 'Inspector'))
        assert_eq(business().compliance_status, 'flagged')
        local row = MySQL.single.await('SELECT * FROM pf_gov_business_inspections WHERE business_id = ? ORDER BY id DESC LIMIT 1', { BIZ })
        assert_eq(row.result_status, 'flagged')
        assert_eq(row.inspected_by, 'CID9')
        assert_false(exports['pf-government']:RecordBusinessInspection(BIZ, 'closed', 'x'))
        assert_false(exports['pf-government']:RecordBusinessInspection('restaurant:nowhere', 'compliant', 'x'))
        assert_eq(business().business_status, 'active', 'an inspection does not close the business by itself')
    end)
end)

describe('ownership transfers', function()
    local calls
    local function stub(resource, fn, answer)
        Mock.exportsByResource[resource] = { [fn] = function(_, id, cid) calls[#calls + 1] = { resource = resource, id = id, cid = cid } return answer end }
    end
    BeforeEach = function() calls = {} end
    it('change the real owner first, then the record', function()
        MySQL.query.await("INSERT IGNORE INTO players (citizenid, cid, license, name, money, charinfo, job, gang, position, metadata, inventory) VALUES ('CID3', 1, 'license:CID3', 'New', '{}', '{}', '{}', '{}', '{}', '{}', '[]')")
        stub('pf-restaurants', 'SetOwnerFromGovernment', true)
        assert_true(TransferBusinessOwnership(BIZ, 'CID3', 'New Owner'))
        assert_eq(calls[1].resource, 'pf-restaurants')
        assert_eq(calls[1].id, 'bs')
        assert_eq(calls[1].cid, 'CID3')
        assert_eq(business().owner_id, 'CID3')
    end)
    it('change nothing when the business resource refuses', function()
        stub('pf-restaurants', 'SetOwnerFromGovernment', false)
        local ok = TransferBusinessOwnership(BIZ, 'CID9', 'Someone')
        assert_false(ok)
        assert_eq(business().owner_id, 'CID3')
    end)
    it('are refused for mechanic shops (owned by their job) and unknown businesses', function()
        RegisterBusiness('mechanic:bennys', 'Bennys', 'mechanic', 'job:bennys', nil, 'society:bennys')
        local ok, err = TransferBusinessOwnership('mechanic:bennys', 'CID3', 'New')
        assert_false(ok)
        assert_eq(err, 'job_business')
        assert_false(TransferBusinessOwnership('restaurant:nowhere', 'CID3', 'New'))
    end)
end)
