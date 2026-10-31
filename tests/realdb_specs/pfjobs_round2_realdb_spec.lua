-- pf-jobs on a real database: the migrations (bus, Gruppe 6 upgrades, tow) apply on an install
-- that already has the old pf-jobs tables and rerun safely; bus stats and the route log are written
-- and read back; a Gruppe 6 upgrade is stored once and applied after a reload; a tow rental and its
-- deposit survive a restart and are refunded once; a deleted character's rows go from every table;
-- pf-jobgarages reads the saved manage grade.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
local bankUp = true
function GetResourceState(name)
    if name == 'pfm-banking' then return bankUp and 'started' or 'stopped' end
    if name == 'pf-services' or name == 'pf-devices' then return 'missing' end
    return 'started'
end
QBCore = QBCoreMock
Citizen.SetTimeout = function() return 1 end
Citizen.ClearTimeout = function() end
SetTimeout = function() end

-- the bank and its ledger
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
local bankConfig = Config
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, resource, list) return RunMigrations(resource, list) end

-- an install that already has the old pf-jobs tables (imported from pf-jobs/sql)
for _, f in ipairs({ 'bus.sql', 'taxi.sql', 'garbage.sql', 'gruppe6_full.sql' }) do RealDB.exec('[pfscripts]/pf-jobs/sql/' .. f) end
MySQL.query.await([[CREATE TABLE IF NOT EXISTS pf_garbage_groups (id INT NOT NULL AUTO_INCREMENT, host_citizenid VARCHAR(64) NOT NULL,
    open TINYINT(1) NOT NULL DEFAULT 0, created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY (id))]])
MySQL.query.await([[CREATE TABLE IF NOT EXISTS pf_garbage_group_members (group_id INT NOT NULL, citizenid VARCHAR(64) NOT NULL,
    display_name VARCHAR(64) NOT NULL, cut_percent INT NOT NULL DEFAULT 0, PRIMARY KEY (group_id, citizenid))]])

-- pf-jobs
local alive = {}
function CreateVehicleServerSetter(hash, _, x, y, z)
    Mock.nextNetId = Mock.nextNetId + 1
    alive[Mock.nextNetId], Mock.models[Mock.nextNetId], Mock.coords[Mock.nextNetId] = true, hash, vector3(x, y, z)
    return Mock.nextNetId
end
function DoesEntityExist(e) return alive[e] == true or Mock.players[e] ~= nil end
function DeleteEntity(e) alive[e] = nil end
function SetVehicleNumberPlateText(v, p) Mock.plates[v] = p end
function SetVehicleDoorsLocked() end
function GetVehicleEngineHealth() return 1000.0 end
function GetVehicleBodyHealth() return 1000.0 end
QBCoreMock.Shared.Items.moneybag = { name = 'moneybag', label = 'Money Bag', weight = 0 }

local FILES = { 'config.lua', 'server/apps/bus.lua', 'server/apps/gruppe6.lua', 'server/apps/tow.lua', 'server/schema.lua' }
local function loadJobs()
    function GetCurrentResourceName() return 'pf-jobs' end
    Config = nil
    load_resource('pfm-banking/payouts.lua')
    for _, f in ipairs(FILES) do load_resource('[pfscripts]/pf-jobs/' .. f) end
    for k, v in pairs(bankConfig) do if Config[k] == nil then Config[k] = v end end
    Config.Bus.Pricing.RushHourMultiplier, Config.Bus.Pricing.NightBonus = 1.0, 1.0
end
loadJobs()

local D, E = 1, 2
local function player(src, cid, money)
    MySQL.query.await("INSERT IGNORE INTO players (citizenid, cid, license, name, money, charinfo, job, gang, position, metadata, inventory) VALUES (?, 1, ?, 'T', ?, '{}', '{}', '{}', '{}', '{}', '[]')",
        { cid, 'license:' .. cid, json.encode(money) })
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.money = { cash = money.cash, bank = money.bank }
    return p
end
local function count(sql, params) return tonumber(MySQL.scalar.await(sql, params)) or 0 end

describe('pf-jobs migrations', function()
    it('apply over the old tables and rerun as a no-op', function()
        assert_true(PFJobsSchema.Run())
        assert_eq(count("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = 'pf-jobs'"), 3)
        assert_true(PFJobsSchema.Run())
        assert_eq(count("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = 'pf-jobs'"), 3)
        for _, t in ipairs({ 'bus_stats', 'bus_routes_log', 'pf_gruppe6_xp', 'pf_gruppe6_upgrades', 'pf_tow_stats', 'pf_tow_rentals' }) do
            assert_eq(count('SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?', { t }), 1, t)
        end
    end)
end)

describe('bus stats on the database', function()
    it('a completed route is logged and the stats come back after a restart', function()
        player(D, 'RDBUS001', { cash = 0, bank = 0 })
        -- about the stats on the database; bus_spec covers the depot bus the distance pay needs
        local needsBus = Config.Bus.MileageNeedsBus
        Config.Bus.MileageNeedsBus = false
        local route = PFJobsBus.Routes()[1]
        Mock.fireNet('bus:server:startRoute', D, route.id)
        for i, stop in ipairs(route.stops) do
            Mock.clock = Mock.clock + 120
            Mock.coords[D] = stop.coords
            Mock.fireNet('bus:server:completeStop', D, i)
        end
        Mock.fireNet('bus:server:completeRoute', D)
        Config.Bus.MileageNeedsBus = needsBus
        local paid = Mock.players[D].PlayerData.money.cash
        assert_true(paid > 0)
        local row = MySQL.single.await('SELECT routes_completed, total_earnings FROM bus_stats WHERE citizen_id = ?', { 'RDBUS001' })
        assert_eq(tonumber(row.routes_completed), 1)
        assert_eq(tonumber(row.total_earnings), paid)
        assert_eq(count('SELECT COUNT(*) FROM bus_routes_log WHERE citizen_id = ? AND route_id = ?', { 'RDBUS001', route.id }), 1)
        PFJobsBus.ForgetCitizen('RDBUS001') -- the cache only; the row stays
        assert_eq(PFJobsBus.View(D).stats.routesCompleted, 1)
        assert_eq(PFJobsBus.View(D).stats.totalEarnings, paid)
    end)
end)

describe('Gruppe 6 upgrades on the database', function()
    it('are stored once, charged once, and applied after a reload', function()
        local p = player(D, 'RDG60001', { cash = 0, bank = 50000 })
        MySQL.query.await('INSERT INTO pf_gruppe6_xp (citizenid, xp, level) VALUES (?, 1200, 2)', { 'RDG60001' })
        assert_eq(PFJobsG6.BuyUpgrade(D, 'tier_2'), true)
        assert_eq(PFJobsG6.BuyUpgrade(D, 'tier_2'), false)
        assert_eq(count('SELECT COUNT(*) FROM pf_gruppe6_upgrades WHERE citizenid = ?', { 'RDG60001' }), 1)
        assert_eq(count('SELECT price FROM pf_gruppe6_upgrades WHERE citizenid = ? AND upgrade_id = ?', { 'RDG60001', 'tier_2' }), Config.Gruppe6.Upgrades.tier_2.cost)
        assert_eq(p.PlayerData.money.bank, 50000 - Config.Gruppe6.Upgrades.tier_2.cost)
        assert_eq(count("SELECT COUNT(*) FROM pf_transactions WHERE idempotency_key LIKE 'pf-jobs:gruppe6:upgrade:RDG60001:%' AND state = 'completed'"), 1)
        -- a fresh server reads the upgrade back: level 2 with the licence gets tier 2 contracts
        loadJobs()
        Mock.fireNet('pf-jobs:gruppe6:startSearch', D)
        local offers = Mock.clientEventsNamed('pf-jobs:gruppe6:contracts')
        assert_eq(offers[#offers].args[1][1].tier, 2)
    end)
end)

describe('tow rentals on the database', function()
    it('a deposit survives a restart and comes back once at the bay', function()
        local p = player(E, 'RDTOW001', { cash = 1000, bank = 0 })
        p.PlayerData.job = { name = 'tow', onduty = true }
        local bay = Config.Tow.FlatbedSpawn
        Mock.coords[E] = vector3(bay.x, bay.y, bay.z)
        assert_eq(PFJobsTow.Rent(E, 'flatbed', true).ok, true)
        assert_eq(p.PlayerData.money.cash, 750)
        local row = MySQL.single.await('SELECT model, plate, deposit FROM pf_tow_rentals WHERE citizenid = ?', { 'RDTOW001' })
        assert_eq(row.model, 'flatbed')
        assert_eq(tonumber(row.deposit), 250)
        -- the server restarts: the truck is gone, the rental is not
        loadJobs()
        TriggerEvent('pf-jobs:server:schemaReady')
        local v = PFJobsTow.View(E)
        assert_eq(v.rental.orphaned, true)
        assert_eq(PFJobsTow.Rent(E, 'flatbed', true).error, 'rental_active')
        assert_eq(PFJobsTow.Return(E, true).ok, true)
        assert_eq(p.PlayerData.money.bank, 250)
        assert_eq(count('SELECT COUNT(*) FROM pf_tow_rentals WHERE citizenid = ?', { 'RDTOW001' }), 0)
        assert_eq(PFJobsTow.Return(E, true).error, 'no_rental')
        assert_eq(p.PlayerData.money.bank, 250)
    end)
end)

describe('a deleted character', function()
    it('loses its rows in every pf-jobs table; other characters keep theirs', function()
        for _, cid in ipairs({ 'GONE0001', 'KEEP0001' }) do
            MySQL.query.await('INSERT INTO bus_stats (citizen_id) VALUES (?)', { cid })
            MySQL.query.await('INSERT INTO bus_routes_log (citizen_id, route_id) VALUES (?, 1)', { cid })
            MySQL.query.await('INSERT INTO taxi_stats (citizen_id) VALUES (?)', { cid })
            MySQL.query.await('INSERT INTO pf_gruppe6_xp (citizenid, xp, level) VALUES (?, 5, 1) ON DUPLICATE KEY UPDATE xp = 5', { cid })
            MySQL.query.await("INSERT INTO pf_gruppe6_upgrades (citizenid, upgrade_id, price) VALUES (?, 'bag_capacity', 1)", { cid })
            local gid = MySQL.insert.await('INSERT INTO pf_gruppe6_groups (host_citizenid) VALUES (?)', { cid })
            MySQL.query.await("INSERT INTO pf_gruppe6_group_members (group_id, citizenid, display_name) VALUES (?, ?, 'x')", { gid, cid })
            MySQL.query.await('INSERT INTO pf_garbage_xp (citizenid, xp, level) VALUES (?, 1, 1)', { cid })
            MySQL.query.await('INSERT INTO pf_tow_stats (citizenid, xp) VALUES (?, 10)', { cid })
            MySQL.query.await("INSERT INTO pf_tow_rentals (citizenid, rental_id, model, plate, deposit) VALUES (?, ?, 'flatbed', 'TOWR1', 250)", { cid, 'r-' .. cid })
        end
        local before = count('SELECT COUNT(*) FROM bus_stats WHERE citizen_id = ?', { 'KEEP0001' })
        TriggerEvent('pfm-core:server:characterDeleted', 'GONE0001')
        for _, t in ipairs(PFJobsSchema.CharacterRows) do
            local exists = count('SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?', { t[1] }) == 1
            if exists then
                assert_eq(count(('SELECT COUNT(*) FROM `%s` WHERE `%s` = ?'):format(t[1], t[2]), { 'GONE0001' }), 0, t[1])
            end
        end
        assert_eq(count('SELECT COUNT(*) FROM bus_stats WHERE citizen_id = ?', { 'KEEP0001' }), before)
        assert_eq(count('SELECT COUNT(*) FROM pf_gruppe6_upgrades WHERE citizenid = ?', { 'KEEP0001' }), 1)
        assert_eq(count('SELECT COUNT(*) FROM pf_tow_rentals WHERE citizenid = ?', { 'KEEP0001' }), 1)
        assert_eq(count('SELECT COUNT(*) FROM pf_gruppe6_group_members WHERE citizenid = ?', { 'KEEP0001' }), 1)
    end)
end)

describe('pf-jobgarages on the database', function()
    it('the saved manage grade decides who manages the fleet', function()
        RealDB.exec('[pfscripts]/pf-jobgarages/sql/pf_jobgarages.sql')
        local jobsConfig = Config
        Config = nil
        load_resource('[pfscripts]/pf-jobgarages/config.lua')
        load_resource('[pfscripts]/pf-jobgarages/server/main.lua')
        local cfg = Config.JobGarages.mechanic_main
        local p = Mock.newPlayer(7, 'RDMECH01')
        p.PlayerData.job = { name = 'mechanic', grade = { level = 2 }, onduty = true }
        assert_false((PFJobGarages.CanManageGarage(7, 'mechanic_main', cfg)))
        MySQL.query.await("INSERT INTO job_garage_permissions (garage_id, min_grade_use, min_grade_manage) VALUES ('mechanic_main', 0, 2)")
        assert_true((PFJobGarages.CanManageGarage(7, 'mechanic_main', cfg)))
        -- a deleted character's assignment and car out are cleared
        MySQL.query.await([[INSERT INTO job_garage_vehicles (garage_id, plate, model, label, min_grade, active, assignment_type, assigned_citizenid, `out`, out_citizenid)
            VALUES ('mechanic_main', 'RDFLT1', 'flatbed', 'Flatbed', 0, 1, 'citizenid', 'RDMECH01', 1, 'RDMECH01')]])
        TriggerEvent('pfm-core:server:characterDeleted', 'RDMECH01')
        local row = MySQL.single.await("SELECT assignment_type, assigned_citizenid, `out` FROM job_garage_vehicles WHERE plate = 'RDFLT1'")
        assert_eq(row.assignment_type, 'none')
        assert_eq(row.assigned_citizenid, nil)
        assert_eq(tonumber(row.out), 0)
        Config = jobsConfig
    end)
end)
