-- Restaurant hiring from the Job Board on a real database: the registry owner of a restaurant posts a
-- vacancy, an applicant applies as themselves, and the hire adds them to the restaurant's own staff
-- (pf-restaurants AddStaff, with pf-restaurants' role and permission rules) instead of only
-- "accepting" them. Also AddStaff / RemoveStaff themselves: who may give which role, the owner role,
-- offline actors, unknown characters.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
local started = { ['pfm-core'] = true, ['pf-government'] = true, ['pf-restaurants'] = true, ['pf-citizen'] = true }
function GetResourceState(name) return started[name] and 'started' or 'missing' end
function GetCurrentResourceName() return 'pf-computer' end
function LoadResourceFile() return nil end
function SaveResourceFile() return true end
function RegisterCommand() end

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('[pfscripts]/pf-government/sql/install.sql')

-- pf-restaurants' config, then pf-computer's merged in (both use the global Config)
Config = nil
load_resource('[pfscripts]/pf-restaurants/config/shared.lua')
load_resource('[pfscripts]/pf-restaurants/config/items.lua')
load_resource('[pfscripts]/pf-restaurants/config/restaurants.lua')
load_resource('[pfscripts]/pf-restaurants/config/stations.lua')
load_resource('[pfscripts]/pf-restaurants/config/recipes.lua')
local restaurantConfig = Config
Config = nil
load_resource('[pfscripts]/pf-computer/config/config.lua')
for k, v in pairs(restaurantConfig) do if Config[k] == nil then Config[k] = v end end
Config.Logging.Enabled = false

QBCoreMock.Shared.Jobs = { unemployed = { label = 'Civilian', grades = { ['0'] = { name = 'Freelancer', payment = 10 } } } }
local mails = {}
Mock.exportsByResource['pf-citizen'] = { SendMail = function(_, cid, mail) mails[#mails + 1] = { cid = cid, mail = mail } return true end }
Mock.exportsByResource['pf-government'] = { HasPermission = function() return false end, UpdateBusinessEmployees = function() return true end }
load_resource('tests/lua/gov_registry_exports.lua')

load_resource('pfm-core/server/migrations.lua')
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, m) return RunMigrations(res, m) end

-- pf-restaurants: staff storage and rules (what the hire uses)
QBCore = QBCoreMock
for _, f in ipairs({ 'main', 'persistence', 'business', 'integration' }) do
    load_resource('[pfscripts]/pf-restaurants/server/' .. f .. '.lua')
end
Mock.exportsByResource['pf-restaurants'] = Mock.exportsByResource['__self']
InitRestaurants()
assert(RunMigrations('pf-restaurants', RestaurantDB.Migrations), 'restaurant migrations')

local BID = 'burgershot_vespucci'
assert(Config.Restaurants[BID], 'the test restaurant exists in the config')
for _, cid in ipairs({ 'OWN1', 'APP1', 'APP2', 'CSH1', 'MGR1' }) do
    MySQL.query.await([[INSERT INTO players (citizenid, cid, license, name, money, charinfo, job, gang, position, metadata, inventory)
        VALUES (?, 1, ?, ?, '{}', '{"firstname":"Test","lastname":"Person"}', '{"name":"unemployed"}', '{}', '{}', '{}', '[]')]], { cid, 'license:' .. cid, cid })
end
MySQL.query.await('INSERT INTO pf_restaurant_employees (business_id, citizenid, role) VALUES (?, ?, ?), (?, ?, ?), (?, ?, ?)',
    { BID, 'OWN1', 'owner', BID, 'CSH1', 'cashier', BID, 'MGR1', 'manager' })
RestaurantDB.Load()
MySQL.query.await("INSERT INTO pf_gov_businesses (business_id, business_name, business_type, owner_id, owner_name) VALUES (?, 'Burger Shot', 'restaurant', 'OWN1', 'Olga')", { 'restaurant:' .. BID })

-- pf-computer: storage and the Job Board
load_resource('[pfscripts]/pf-computer/server/main.lua')
load_resource('[pfscripts]/pf-computer/server/jobboard.lua')
assert(PFComputerStorage.Init(), 'computer storage')

local OWNER, APPLICANT, CASHIER = 1, 2, 3
local function player(src, cid)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.job = { name = 'unemployed', label = 'Civilian', grade = { level = 0 }, isboss = false, onduty = true }
    p.Functions = p.Functions or {}
    p.Functions.SetJob = function() return true end
    p.Functions.Save = function() end
    return p
end
local function call(src, action, payload) return PFComputer.dispatch(action, payload or {}, src) end
local AddStaff = function(...) return Mock.exportsByResource['pf-restaurants'].AddStaff(...) end
local RemoveStaff = function(...) return Mock.exportsByResource['pf-restaurants'].RemoveStaff(...) end
local function staffRole(cid) return MySQL.scalar.await('SELECT role FROM pf_restaurant_employees WHERE business_id = ? AND citizenid = ?', { BID, cid }) end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    player(OWNER, 'OWN1')
    player(APPLICANT, 'APP1')
    player(CASHIER, 'CSH1')
end

local post, app
describe('Job Board hiring into a restaurant', function()
    it('the registry owner sees the restaurant with its staff roles (not the owner role)', function()
        local res = call(OWNER, 'jobs:businesses')
        assert_true(res.ok)
        assert_eq(#res.data, 1)
        assert_eq(res.data[1].key, 'gov:restaurant:' .. BID)
        assert_eq(res.data[1].hireKind, 'restaurant')
        for _, r in ipairs(res.data[1].roles) do assert_true(r.id ~= 'owner') end
        assert_true(#res.data[1].roles >= 3)
    end)

    it('posts a vacancy that hires into the staff; the applicant applies as themselves', function()
        local res = call(OWNER, 'jobs:create', { business = 'gov:restaurant:' .. BID, title = 'Cashier', salary = '$20/h' })
        assert_true(res.ok, tostring(res.error))
        assert_true(res.data.hires)
        assert_eq(res.data.hireKind, 'restaurant')
        post = res.data
        assert_eq(call(CASHIER, 'jobs:apply', { jobId = post.id }).error, 'already_employed', 'already on the staff')
        local a = call(APPLICANT, 'jobs:apply', { jobId = post.id, message = 'I can count' })
        assert_true(a.ok, tostring(a.error))
        app = a.data
        assert_eq(call(CASHIER, 'jobs:hire', { applicationId = app.id, role = 'cashier' }).error, 'not_authorized', 'only the owner of the business hires here')
    end)

    it('the hire adds the applicant with the chosen role, through the restaurant\'s rules', function()
        assert_eq(call(OWNER, 'jobs:hire', { applicationId = app.id, role = 'owner' }).error, 'invalid_role')
        local bad = call(OWNER, 'jobs:hire', { applicationId = app.id, role = 'astronaut' })
        assert_eq(bad.error, 'invalid_role')
        assert_eq(MySQL.scalar.await('SELECT status FROM pf_computer_job_applications WHERE id = ?', { app.id }), 'pending', 'a refused hire leaves the application open')
        local res = call(OWNER, 'jobs:hire', { applicationId = app.id, role = 'cashier' })
        assert_true(res.ok, tostring(res.error))
        assert_eq(res.data.status, 'hired')
        assert_eq(staffRole('APP1'), 'cashier')
        assert_eq(RestaurantData.employees[BID].APP1.role, 'cashier')
        assert_eq(MySQL.scalar.await('SELECT status FROM pf_computer_job_applications WHERE id = ?', { app.id }), 'hired')
        assert_eq(MySQL.scalar.await('SELECT decided_by FROM pf_computer_job_applications WHERE id = ?', { app.id }), 'OWN1')
        assert_eq(mails[#mails].cid, 'APP1')
        assert_eq(call(OWNER, 'jobs:hire', { applicationId = app.id, role = 'cashier' }).error, 'not_pending', 'no second hire')
        local mine = call(APPLICANT, 'jobs:myApplications').data
        assert_eq(mine[1].status, 'hired')
    end)
end)

describe('pf-restaurants AddStaff / RemoveStaff', function()
    it('needs a role that may manage staff; only an owner gives or changes the owner role', function()
        local ok, why = AddStaff(BID, 'APP2', 'cashier', 'CSH1')
        assert_false(ok)
        assert_eq(why, 'no_permission', 'a cashier cannot hire')
        ok, why = AddStaff(BID, 'APP2', 'owner', 'MGR1')
        assert_eq(why, 'owner_only')
        ok, why = AddStaff(BID, 'OWN1', 'cashier', 'MGR1')
        assert_eq(why, 'owner_only', 'a manager cannot demote the owner')
        -- the manager is offline: their saved role decides
        assert_true(AddStaff(BID, 'APP2', 'kitchen_staff', 'MGR1'))
        assert_eq(staffRole('APP2'), 'kitchen_staff')
        ok, why = AddStaff(BID, 'NOBODY', 'cashier', 'OWN1')
        assert_eq(why, 'unknown_citizen')
        ok, why = AddStaff('no_such_place', 'APP2', 'cashier', 'OWN1')
        assert_eq(why, 'unknown_restaurant')
        ok, why = AddStaff(BID, 'OWN1', 'manager', 'OWN1')
        assert_false(ok, 'nobody changes their own role this way')
    end)

    it('removes staff with the same rules', function()
        local ok, why = RemoveStaff(BID, 'APP2', 'CSH1')
        assert_eq(why, 'no_permission')
        ok, why = RemoveStaff(BID, 'OWN1', 'MGR1')
        assert_eq(why, 'owner_only')
        assert_true(RemoveStaff(BID, 'APP2', 'OWN1'))
        assert_eq(staffRole('APP2'), nil)
        ok, why = RemoveStaff(BID, 'APP2', 'OWN1')
        assert_eq(why, 'not_staff')
    end)
end)
