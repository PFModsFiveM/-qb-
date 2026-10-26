-- pf-government business employees on a real database: the registry asks the business's own staff
-- source (pf-restaurants, the job for mechanic shops, the owner otherwise) and keeps the count.
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
    'server/staff.lua', 'server/callbacks.lua', 'server/loans.lua', 'server/employees.lua' }) do
    load_resource('[pfscripts]/pf-government/' .. f)
end
function NotifyGovernment() end
function IsGovernmentEmployee(src) local P = QBCoreMock.Functions.GetPlayer(src) return P ~= nil and P.PlayerData.job.name == Config.GovernmentJob end
function DebugPrint() end
Mock.exportsByResource['pf-government'] = Mock.exportsByResource['__self']
InitializeTreasury()
InitializeTaxes()
InitializeBusinesses()

Mock.exportsByResource['pf-restaurants'] = {
    GetStaffList = function(_, id) return id == 'empbs' and { { citizenid = 'EMP1', role = 'owner' }, { citizenid = 'EMP2', role = 'cook' } } or {} end,
}
local function addPlayer(cid, first, job)
    MySQL.query.await([[INSERT INTO players (citizenid, cid, license, name, money, charinfo, job, gang, position, metadata)
        VALUES (?, 1, ?, ?, '{}', ?, ?, '{}', '{}', '{}') ON DUPLICATE KEY UPDATE charinfo = VALUES(charinfo), job = VALUES(job)]],
        { cid, 'license:' .. cid, first, json.encode({ firstname = first, lastname = 'Test' }), json.encode(job or { name = 'unemployed' }) })
end

describe('business employees in the registry', function()
    it('a restaurant lists its staff from pf-restaurants, with names, and the count follows', function()
        addPlayer('EMP1', 'Ava') addPlayer('EMP2', 'Ben')
        TriggerEvent('pf-restaurants:server:registerBusiness', 'empbs', 'Emp Burger', 'EMP1')
        local r = exports['pf-government']:GetBusinessEmployees('restaurant:empbs')
        assert_true(r.ok)
        assert_eq(#r.employees, 2)
        assert_eq(r.employees[1].name, 'Ava Test')
        assert_eq(r.employees[2].role, 'cook')
        assert_eq(tonumber(MySQL.scalar.await("SELECT employee_count FROM pf_gov_businesses WHERE business_id = 'restaurant:empbs'")), 2)
    end)
    it('a mechanic shop lists the members of its job, bosses marked', function()
        addPlayer('MEC1', 'Cal', { name = 'empmech', isboss = true, grade = { name = 'Owner', level = 4 } })
        addPlayer('MEC2', 'Dee', { name = 'empmech', grade = { name = 'Mechanic', level = 1 } })
        RegisterBusiness('mechanic:empmech', 'Emp Mechanics', 'mechanic', 'job:empmech', 'Emp Mechanics')
        local r = exports['pf-government']:GetBusinessEmployees('mechanic:empmech')
        assert_true(r.ok, tostring(r.error))
        assert_eq(#r.employees, 2)
        local roles = {}
        for _, e in ipairs(r.employees) do roles[e.citizenid] = e.role end
        assert_eq(roles.MEC1, 'boss')
        assert_eq(roles.MEC2, 'Mechanic')
    end)
    it('a business without a staff source lists its owner; unknown businesses are refused', function()
        RegisterBusiness('store:empstore', 'Emp Store', 'store', 'EMP2', 'Ben Test')
        local r = exports['pf-government']:GetBusinessEmployees('store:empstore')
        assert_true(r.ok)
        assert_eq(#r.employees, 1)
        assert_eq(r.employees[1].role, 'owner')
        assert_false(exports['pf-government']:GetBusinessEmployees('store:nowhere').ok)
    end)
end)
