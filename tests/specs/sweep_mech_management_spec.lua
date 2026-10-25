-- pf-mechanicjob staff management (server/management.lua, server/main.lua): a manager acts only on
-- staff of their own shop, below their own rank, never on themselves; prices and settings are for
-- managers; server-only events are not network events.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/fake_db.lua')
QBCore = QBCoreMock

local roles, offlineJobs, writes = {}, {}, {}
local function wrote(fragment)
    for _, w in ipairs(writes) do if w:find(fragment, 1, true) then return true end end
    return false
end
FakeDB.extraPatterns = {
    { 'SELECT role FROM pf_business_employees WHERE citizenid = ?', function(p)
        return roles[p[1]] and { { role = roles[p[1]] } } or {}
    end },
    { 'SELECT job FROM players WHERE citizenid = ?', function(p)
        local j = offlineJobs[p[1]]
        return j and { { job = json.encode(j) } } or {}
    end },
    { 'SELECT charinfo FROM players', function() return { { charinfo = '{"firstname":"Sam","lastname":"Doe"}' } } end },
    { 'SELECT * FROM pf_business_locations', function() return {} end },
    { 'pf_business_employees', function(_, q) return 1 end },
    { 'pf_mechanic_products', function() writes[#writes + 1] = 'pf_mechanic_products'; return 1 end },
    { 'mechanic_prices', function() writes[#writes + 1] = 'mechanic_prices'; return 1 end },
    { 'pf_employees', function() writes[#writes + 1] = 'pf_employees'; return 1 end },
    { 'UPDATE players SET job', function() writes[#writes + 1] = 'players.job'; return 1 end },
}
MySQL.delete = MySQL.update
MySQL.execute = MySQL.update

local grades = {}
for g = 0, 4 do grades[tostring(g)] = { name = 'G' .. g, isboss = g == 4 or nil } end
QBCoreMock.Shared.Jobs.mechanic = { label = 'Mechanic', grades = grades }

Config = nil
load_resource('[pfscripts]/pf-mechanicjob/config.lua')
load_resource('[pfscripts]/pf-mechanicjob/shared/debug.lua')
Config.Debug = false
Config.ManagementApp = Config.ManagementApp or {}
load_resource('[pfscripts]/pf-mechanicjob/server/main.lua')
load_resource('[pfscripts]/pf-mechanicjob/server/management.lua')

local BOSS, MANAGER, EMP, COP, RIVAL = 1, 2, 3, 4, 5
local SHOP = vector3(10.0, 10.0, 10.0)

local function person(src, cid, job, grade, isboss)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.job = { name = job, grade = { level = grade }, isboss = isboss or false, onduty = true }
    p.Functions.SetJob = function(name, g) p.PlayerData.job = { name = name, grade = { level = tonumber(g) or 0 } } end
    Mock.coords[src] = SHOP
    return p
end
local function jobOf(src) return Mock.players[src].PlayerData.job end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords = {}, {}
    writes, offlineJobs = {}, {}
    person(BOSS, 'BOSS1', 'mechanic', 4, true)
    person(MANAGER, 'MGR1', 'mechanic', 2)
    person(EMP, 'EMP1', 'mechanic', 0)
    person(COP, 'COP1', 'police', 3)
    person(RIVAL, 'RIV1', 'mechanic2', 1)
    roles = { BOSS1 = 'owner', MGR1 = 'manager', EMP1 = 'employee' }
end

describe('staff changes', function()
    it('a manager cannot fire or promote someone outside the shop', function()
        Mock.fireNet('pf_mechanic:fireEmployee', MANAGER, 'COP1')
        Mock.callCallback('pf_mech:management:fire', MANAGER, 'COP1')
        Mock.fireNet('pf_mechanic:promoteEmployee', MANAGER, 'COP1')
        Mock.fireNet('pf_mechanic:setEmployeeRole', MANAGER, 'COP1', 'employee', 0)
        Mock.callCallback('pf_mech:management:promote', MANAGER, 'RIV1')
        assert_eq(jobOf(COP).name, 'police')
        assert_eq(jobOf(COP).grade.level, 3)
        assert_eq(jobOf(RIVAL).name, 'mechanic2')
        assert_eq(jobOf(RIVAL).grade.level, 1)
    end)
    it('an offline citizen of another job is not touched either', function()
        offlineJobs.OFF1 = { name = 'ambulance', grade = { level = 2 } }
        Mock.fireNet('pf_mechanic:fireEmployee', MANAGER, 'OFF1')
        Mock.fireNet('pf_mechanic:setEmployeeRole', MANAGER, 'OFF1', 'employee', 0)
        assert_eq(wrote('players.job'), false)
    end)
    it('no one raises themselves, and a manager cannot hand out a rank at or above their own', function()
        Mock.fireNet('pf_mechanic:setEmployeeRole', MANAGER, 'MGR1', 'owner', 4)
        assert_eq(jobOf(MANAGER).grade.level, 2)
        Mock.fireNet('pf_mechanic:setEmployeeRole', MANAGER, 'EMP1', 'manager', 4)
        Mock.fireNet('pf_mechanic:setEmployeeRole', MANAGER, 'EMP1', 'owner', 0)
        assert_eq(jobOf(EMP).grade.level, 0)
        Mock.callCallback('pf_mech:management:promote', MANAGER, 'EMP1')    -- 0 -> 1 is fine
        assert_eq(jobOf(EMP).grade.level, 1)
        Mock.callCallback('pf_mech:management:promote', MANAGER, 'EMP1')    -- 1 -> 2 would equal the manager
        assert_eq(jobOf(EMP).grade.level, 1)
        Mock.fireNet('pf_mechanic:fireEmployee', MANAGER, 'BOSS1')          -- above the manager
        assert_eq(jobOf(BOSS).name, 'mechanic')
    end)
    it('the boss can still promote and fire their staff', function()
        Mock.fireNet('pf_mechanic:promoteEmployee', BOSS, 'EMP1')
        assert_eq(jobOf(EMP).grade.level, 1)
        Mock.fireNet('pf_mechanic:fireEmployee', BOSS, 'MGR1')
        assert_eq(jobOf(MANAGER).name, 'unemployed')
    end)
    it('hiring needs the person online and next to the manager', function()
        offlineJobs.OFF1 = { name = 'ambulance', grade = { level = 2 } }
        assert_eq(Mock.callCallback('pf_mech:management:hire', BOSS, 'OFF1'), false)
        assert_eq(wrote('players.job'), false)
        Mock.coords[COP] = vector3(500.0, 500.0, 10.0)
        assert_eq(Mock.callCallback('pf_mech:management:hire', BOSS, 'COP1'), false)
        assert_eq(jobOf(COP).name, 'police')
        Mock.coords[COP] = SHOP
        assert_eq(Mock.callCallback('pf_mech:management:hire', BOSS, 'COP1'), true)
        assert_eq(jobOf(COP).name, 'mechanic')
    end)
    it('ownership goes only to staff or someone standing there', function()
        offlineJobs.OFF1 = { name = 'ambulance', grade = { level = 2 } }
        Mock.fireNet('pf_mechanic:transferOwnership', BOSS, 'OFF1')
        assert_eq(jobOf(BOSS).name, 'mechanic')
        assert_eq(wrote('players.job'), false)
    end)
    it('main.lua employee editor: only this shop, below the boss', function()
        Mock.fireNet('pf_mech:mgmt:updateEmployee', BOSS, { cid = 'COP1', grade = 4, salary = 10 })
        Mock.fireNet('pf_mech:mgmt:updateEmployee', BOSS, { cid = 'RIV1', grade = 3, salary = 10 })
        assert_eq(jobOf(COP).name, 'police')
        assert_eq(jobOf(RIVAL).grade.level, 1)
        assert_eq(wrote('pf_employees'), false)
        Mock.fireNet('pf_mech:mgmt:updateEmployee', BOSS, { cid = 'EMP1', grade = 3, salary = 10 })
        assert_eq(jobOf(EMP).grade.level, 3)
    end)
end)

describe('prices and server-only events', function()
    it('an ordinary employee cannot change prices; negative prices are refused', function()
        Mock.fireNet('pf_mechanic:updatePrice', EMP, 1, 5)
        Mock.fireNet('pf_mechanic:addProduct', EMP, { name = 'x', category = 'y', price = 1 })
        Mock.fireNet('pf_mechanic:updateProductPrice', MANAGER, 'oil_change', -500)
        assert_eq(wrote('pf_mechanic_products'), false)
        assert_eq(wrote('mechanic_prices'), false)
        Mock.fireNet('pf_mechanic:updateProductPrice', MANAGER, 'oil_change', 120)
        assert_eq(wrote('mechanic_prices'), true)
    end)
    it('location reloads and sales refreshes are not network events', function()
        assert_eq(Mock.netHandlers['pf_mechanic:reloadLocations'], nil)
        assert_eq(Mock.netHandlers['pf_mechanic:refreshManagementData'], nil)
        assert_eq(Mock.netHandlers['onServerResourceStart'], nil)
    end)
end)
