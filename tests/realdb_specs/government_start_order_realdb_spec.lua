-- pf-government start order on a real database: a business resource that registers before
-- pf-government's own start-up still works (the schema is made on first use). Header from
-- government_business_realdb_spec: restaurants register under their owner, each
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
    'server/bills.lua', 'server/businesses.lua', 'server/audit.lua', 'server/licenses.lua', 'server/integrations.lua' }) do
    load_resource('[pfscripts]/pf-government/' .. f)
end
function NotifyGovernment() end
function DebugPrint() end
Mock.exportsByResource['pf-government'] = Mock.exportsByResource['__self']

describe('registering before pf-government has started', function()
    it('works: the business, its account and the new columns are there', function()
        TriggerEvent('pf-restaurants:server:registerBusiness', 'early', 'Early Diner', 'CID1')
        local row = MySQL.single.await("SELECT * FROM pf_gov_businesses WHERE business_id = 'restaurant:early'")
        assert_true(row ~= nil, 'registered')
        assert_eq(row.account_ref, 'society:restaurant_early')
        assert_eq(row.business_status, 'active')
        assert_true(exports['pf-government']:CanBusinessTrade('restaurant:early'))
    end)
    it('and a second registration (restart) keeps working', function()
        TriggerEvent('pf-restaurants:server:registerBusiness', 'early', 'Early Diner', 'CID2')
        assert_eq(MySQL.scalar.await("SELECT owner_id FROM pf_gov_businesses WHERE business_id = 'restaurant:early'"), 'CID2')
    end)
end)
