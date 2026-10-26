-- pf-government business loans on a real database: a loan is paid from the treasury into the
-- business's registered account, each due date adds interest and an installment once, auto-pay
-- takes it from the business account, unpaid installments count as missed payments and the loan
-- defaults after Config.Loans.DefaultAfterMissed, and a manual payment brings it back.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
GetInvokingResource = GetInvokingResource or function() return nil end
local states = { ['pfm-cityhall'] = 'missing' }
function GetResourceState(name) return states[name] or 'started' end
vec3 = vec3 or vector3
vec4 = vec4 or vector4 or function(x, y, z, w) return { x = x, y = y, z = z, w = w } end

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

RealDB.exec('[pfscripts]/pf-government/sql/install.sql')
function GetCurrentResourceName() return 'pf-government' end
QBCoreMock.Shared.Jobs = { government = { label = 'Government' } }
Config = nil
load_resource('pfm-banking/payouts.lua')
for _, f in ipairs({ 'config.lua', 'server/core.lua', 'server/treasury.lua', 'server/taxes.lua', 'server/utilities.lua',
    'server/bills.lua', 'server/businesses.lua', 'server/audit.lua', 'server/licenses.lua', 'server/integrations.lua',
    'server/staff.lua', 'server/callbacks.lua', 'server/loans.lua' }) do
    load_resource('[pfscripts]/pf-government/' .. f)
end
function NotifyGovernment() end
function IsGovernmentEmployee(src) local P = QBCoreMock.Functions.GetPlayer(src) return P ~= nil and P.PlayerData.job.name == Config.GovernmentJob end
function DebugPrint() end
Mock.exportsByResource['pf-government'] = Mock.exportsByResource['__self']
InitializeTreasury()
InitializeTaxes()
InitializeBusinesses()

local OFFICIAL, CLERK = 1, 2
local BIZ, ACCOUNT = 'restaurant:loanbs', 'restaurant_loanbs'
local TREASURY = Config.Treasury.SocietyAccount

local function society(name) return tonumber(MySQL.scalar.await('SELECT account_balance FROM bank_accounts WHERE account_name = ?', { name })) or 0 end
local function setSociety(name, amount)
    MySQL.query.await("INSERT INTO bank_accounts (account_name, account_balance, account_type, users) VALUES (?, ?, 'business', '[]') ON DUPLICATE KEY UPDATE account_balance = VALUES(account_balance)", { name, amount })
    MySQL.query.await('INSERT IGNORE INTO pf_ledger_baselines (account, balance) VALUES (?, ?)', { 'society:' .. name, amount })
end
local function nui(src, action, data)
    local got
    data = data or {}
    data.source = src
    Government.NuiCallbacks[action](data, function(r) got = r end)
    return got
end
local function loan() return MySQL.single.await('SELECT * FROM pf_gov_business_loans WHERE business_id = ? ORDER BY id DESC LIMIT 1', { BIZ }) end
local function makeDue(id) MySQL.update.await('UPDATE pf_gov_business_loans SET next_due_at = NOW() - INTERVAL 1 MINUTE WHERE id = ?', { id }) end
local function compliance() return MySQL.scalar.await('SELECT compliance_status FROM pf_gov_businesses WHERE business_id = ?', { BIZ }) end

describe('government business loans', function()
    it('setup', function()
        Mock.newPlayer(OFFICIAL, 'GOV1').PlayerData.job = { name = Config.GovernmentJob, grade = { level = 3 }, onduty = true }
        Mock.newPlayer(CLERK, 'CIT1').PlayerData.job = { name = 'unemployed', grade = { level = 0 }, onduty = true }
        TriggerEvent('pf-restaurants:server:registerBusiness', 'loanbs', 'Loan Burger', 'CID1')
        MySQL.update.await('UPDATE pf_gov_businesses SET account_ref = ? WHERE business_id = ?', { 'society:' .. ACCOUNT, BIZ })
        setSociety(ACCOUNT, 0)
        setSociety(TREASURY, 100000)
        Loans.EnsureColumns()
    end)
    it('pays the loan from the treasury into the business account, staff only', function()
        assert_false(nui(CLERK, 'business:loans:grant', { businessId = BIZ, amount = 1000 }).ok)
        assert_false(nui(OFFICIAL, 'business:loans:grant', { businessId = 'restaurant:nowhere', amount = 1000 }).ok, 'unregistered business')
        local r = nui(OFFICIAL, 'business:loans:grant', { businessId = BIZ, amount = 1000, interestRate = 5, autoPay = true, paymentIntervalDays = 7 })
        assert_true(r.ok, tostring(r.error))
        assert_eq(society(ACCOUNT), 1000)
        assert_eq(society(TREASURY), 99000)
        assert_eq(tonumber(loan().remaining_amount), 1000)
    end)
    it('a due date adds interest and an installment once; auto-pay takes it from the business', function()
        local l = loan()
        makeDue(l.id)
        assert_eq(Loans.Tick(), 1)
        assert_eq(Loans.Tick(), 0, 'the same due date is not processed twice')
        -- 1000 + 5% = 1050, installment 10% of 1000 = 100, paid
        l = loan()
        assert_eq(tonumber(l.remaining_amount), 950)
        assert_eq(tonumber(l.amount_due), 0)
        assert_eq(society(ACCOUNT), 900)
        assert_eq(society(TREASURY), 99100)
        assert_eq(l.status, 'active')
    end)
    it('an empty business account misses payments and defaults after the limit', function()
        setSociety(ACCOUNT, 0)
        MySQL.update.await("UPDATE bank_accounts SET account_balance = 0 WHERE account_name = ?", { ACCOUNT })
        local id = loan().id
        for i = 1, Config.Loans.DefaultAfterMissed do
            makeDue(id)
            Loans.Tick()
            local l = loan()
            assert_eq(tonumber(l.missed_payments), i)
            if i < Config.Loans.DefaultAfterMissed then
                assert_eq(l.status, 'active')
                assert_eq(compliance(), 'warning')
            end
        end
        local l = loan()
        assert_eq(l.status, 'defaulted')
        assert_eq(compliance(), 'non_compliant')
        assert_true(tonumber(l.amount_due) > 0)
        assert_eq(society(TREASURY), 99100, 'nothing taken that the business did not have')
        makeDue(id)
        assert_eq(Loans.Tick(), 0, 'defaulted loans are not charged again automatically')
    end)
    it('paying what is due brings a defaulted loan back to active', function()
        local l = loan()
        local due = tonumber(l.amount_due)
        setSociety(ACCOUNT, 0)
        MySQL.update.await("UPDATE bank_accounts SET account_balance = ? WHERE account_name = ?", { due + 50, ACCOUNT })
        local r = nui(OFFICIAL, 'business:loans:pay', { loanId = l.id, paymentAmount = due })
        assert_true(r.ok, tostring(r.error))
        l = loan()
        assert_eq(tonumber(l.amount_due), 0)
        assert_eq(tonumber(l.missed_payments), 0)
        assert_eq(l.status, 'active')
        assert_eq(society(ACCOUNT), 50)
    end)
end)
