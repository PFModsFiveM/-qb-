-- pf-jobgarages on the real database: adding a car to a fleet is one INSERT ... SELECT that re-checks
-- the owner, parked, not impounded, no active fleet and not on the used lot (pfm-vehiclesales'
-- occasion_vehicles), so a car listed or moved between the checks and the add is not added; a car
-- the garage had before comes back on its old row; a repossessed car (the record gone) leaves every
-- fleet and a car out is taken off the road.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
function GetResourceState() return 'missing' end
function GetAllVehicles() return {} end
function SetTimeout() end

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-garages/player_vehicles.sql')
RealDB.exec('[pfscripts]/pf-jobgarages/sql/pf_jobgarages.sql')
RealDB.exec('pfm-vehiclesales/qb-vehiclesales.sql')

Config = nil
load_resource('[pfscripts]/pf-jobgarages/config.lua')
load_resource('[pfscripts]/pf-jobgarages/server/main.lua')

local GARAGE = 'mechanic_main'
local MANAGER = 1
local runNo = 0
local cid

local function car(plate, cols)
    cols = cols or {}
    MySQL.insert.await("INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, garage, state, depotprice) VALUES ('license:1', ?, ?, '1', '{}', ?, 'pillboxgarage', ?, ?)",
        { cols.citizenid or cid, cols.vehicle or 'flatbed', plate, cols.state or 1, cols.depotprice or 0 })
end
local function fleetRows(plate) return MySQL.query.await('SELECT * FROM job_garage_vehicles WHERE plate = ? ORDER BY id', { plate }) or {} end
local function activeCount(plate) return tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM job_garage_vehicles WHERE plate = ? AND active = 1', { plate })) or 0 end
local function add(plate) Mock.fireNet('jobgarages:addFleetVehicle', MANAGER, GARAGE, { plate = plate, label = 'Truck', min_grade = 1 }) end
local function told(text)
    for _, e in ipairs(Mock.clientEventsNamed('QBCore:Notify')) do if e.args[1] == text then return true end end
    return false
end

-- run `fn` in the moment the add's INSERT executes (another player acting between the checks and it)
local function beforeAdd(fn)
    local real = MySQL.update
    MySQL.update = setmetatable({ await = function(q, p)
        if fn and q:find('INSERT INTO job_garage_vehicles', 1, true) then local f = fn fn = nil f() end
        return real.await(q, p)
    end }, { __call = function(_, ...) return real(...) end })
    return function() MySQL.update = real end
end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    runNo = runNo + 1
    cid = 'JGM' .. runNo
    local p = Mock.newPlayer(MANAGER, cid)
    p.PlayerData.job = { name = 'mechanic', grade = { level = 4 }, onduty = true, isboss = true }
    p.PlayerData.license = 'license:1'
end

describe('adding a car to a fleet on the database', function()
    it('an owned, parked car is added with its own model and the label and grade asked for', function()
        local plate = 'JGA' .. runNo
        car(plate)
        add(plate)
        local rows = fleetRows(plate)
        assert_eq(#rows, 1)
        assert_eq(rows[1].model, 'flatbed')
        assert_eq(rows[1].label, 'Truck')
        assert_eq(tonumber(rows[1].min_grade), 1)
        assert_eq(tonumber(rows[1].active), 1)
        assert_true(told('Vehicle added to job fleet.'))
    end)

    it('a car for sale on the used lot is not added', function()
        local plate = 'JGL' .. runNo
        car(plate)
        MySQL.insert.await("INSERT INTO occasion_vehicles (seller, price, description, plate, model, mods, occasionid) VALUES (?, 100, '', ?, 'flatbed', '{}', 'OC1')", { cid, plate })
        add(plate)
        assert_eq(#fleetRows(plate), 0)
        assert_true(told('This vehicle is for sale on the used car lot.'))
    end)

    it('a car listed in the moment between the checks and the add is not added (one statement)', function()
        local plate = 'JGR' .. runNo
        car(plate)
        -- the listing as pfm-vehiclesales makes it: the owner's record removed, the listing written
        local restore = beforeAdd(function()
            MySQL.query.await('DELETE FROM player_vehicles WHERE plate = ?', { plate })
            MySQL.insert.await("INSERT INTO occasion_vehicles (seller, price, description, plate, model, mods, occasionid) VALUES (?, 100, '', ?, 'flatbed', '{}', 'OC2')", { cid, plate })
        end)
        add(plate)
        restore()
        assert_eq(#fleetRows(plate), 0)
        assert_false(told('Vehicle added to job fleet.'))
    end)

    it('a car still on record but listed in that moment is refused by the lot condition itself', function()
        local plate = 'JGS' .. runNo
        car(plate)
        local restore = beforeAdd(function()
            MySQL.insert.await("INSERT INTO occasion_vehicles (seller, price, description, plate, model, mods, occasionid) VALUES (?, 100, '', ?, 'flatbed', '{}', 'OC3')", { cid, plate })
        end)
        add(plate)
        restore()
        assert_eq(#fleetRows(plate), 0)
    end)

    it('a car taken out or impounded in that moment is not added', function()
        local plate = 'JGT' .. runNo
        car(plate)
        local restore = beforeAdd(function() MySQL.update.await('UPDATE player_vehicles SET state = 0 WHERE plate = ?', { plate }) end)
        add(plate)
        restore()
        assert_eq(#fleetRows(plate), 0)
        MySQL.update.await('UPDATE player_vehicles SET state = 1 WHERE plate = ?', { plate })
        restore = beforeAdd(function() MySQL.update.await('UPDATE player_vehicles SET depotprice = 500 WHERE plate = ?', { plate }) end)
        add(plate)
        restore()
        assert_eq(#fleetRows(plate), 0)
    end)

    it('a car put in another fleet in that moment is not added twice', function()
        local plate = 'JGF' .. runNo
        car(plate)
        local restore = beforeAdd(function()
            MySQL.insert.await("INSERT INTO job_garage_vehicles (garage_id, plate, model, label, min_grade, active, assignment_type) VALUES ('police_main', ?, 'flatbed', 'x', 0, 1, 'none')", { plate })
        end)
        add(plate)
        restore()
        assert_eq(activeCount(plate), 1)
        assert_eq(fleetRows(plate)[1].garage_id, 'police_main')
    end)

    it('a car the garage had before comes back on its old row (garage and plate are unique)', function()
        local plate = 'JGB' .. runNo
        car(plate)
        add(plate)
        local id = fleetRows(plate)[1].id
        MySQL.update.await("UPDATE job_garage_vehicles SET active = 0, assignment_type = 'citizenid', assigned_citizenid = 'X' WHERE id = ?", { id })
        Mock.reset()
        add(plate)
        local rows = fleetRows(plate)
        assert_eq(#rows, 1, 'no second row')
        assert_eq(rows[1].id, id)
        assert_eq(tonumber(rows[1].active), 1)
        assert_eq(rows[1].assignment_type, 'none', 'starts fresh')
        assert_true(told('Vehicle added to job fleet.'), 'it used to fail on the unique key and still say "added"')
    end)
end)

describe('a repossessed car leaves the fleet on the database', function()
    it('every fleet entry goes inactive and a car out is despawned, only when the record is gone', function()
        local plate = 'JGP' .. runNo
        car(plate)
        add(plate)
        MySQL.update.await('UPDATE job_garage_vehicles SET `out` = 1 WHERE plate = ?', { plate })
        TriggerEvent('pfm-vehicleshop:server:vehicleRepossessed', plate, cid)
        assert_eq(activeCount(plate), 1, 'the car is still on record: nothing changes')
        MySQL.query.await('DELETE FROM player_vehicles WHERE plate = ?', { plate })
        TriggerEvent('pfm-vehicleshop:server:vehicleRepossessed', plate, cid)
        assert_eq(activeCount(plate), 0)
        assert_eq(tonumber(fleetRows(plate)[1].out), 0)
        assert_eq(#Mock.clientEventsNamed('jobgarages:forceDespawn'), 1)
        local log = MySQL.scalar.await("SELECT COUNT(*) FROM job_garage_logs WHERE plate = ? AND action = 'repossessed'", { plate })
        assert_eq(tonumber(log), 1)
    end)
end)
