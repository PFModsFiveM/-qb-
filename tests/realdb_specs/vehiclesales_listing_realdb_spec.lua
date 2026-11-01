-- pfm-vehiclesales used lot on the real database: the migration adds the column that keeps a listed
-- car's own record (rerun-safe, also on a table from the old install file); listing removes the car
-- only when it is paid off, not impounded and not in a job fleet (one statement, so a car put in a
-- fleet after the check is not taken); taking a car back writes its finance columns, condition and
-- odometer back exactly; a buyer gets the condition but no loan; a sell-back is paid once.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
local states = { ['pf-government'] = 'missing', ['pf-citizen'] = 'missing', ['pfm-phone'] = 'missing', ['pf-devices'] = 'missing' }
function GetResourceState(name) return states[name] or 'started' end
vec3 = vec3 or vector3
vec4 = vec4 or vector4

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
RealDB.exec('pfm-garages/player_vehicles.sql')
RealDB.exec('[pfscripts]/pf-jobgarages/sql/pf_jobgarages.sql')
-- the lot's table as an existing server has it: from the old install file, without the new column
MySQL.query.await([[CREATE TABLE `occasion_vehicles` (
  `id` int(11) NOT NULL AUTO_INCREMENT, `seller` varchar(50) DEFAULT NULL, `price` int(11) DEFAULT NULL,
  `description` longtext DEFAULT NULL, `plate` varchar(50) DEFAULT NULL, `model` varchar(50) DEFAULT NULL,
  `mods` text DEFAULT NULL, `occasionid` varchar(50) DEFAULT NULL, PRIMARY KEY (`id`), KEY `occasionId` (`occasionid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

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

QBCoreMock.Shared.Vehicles = { sultan = { name = 'Sultan', brand = 'Karin', price = 20000, category = 'sports' } }

function GetCurrentResourceName() return 'pfm-vehiclesales' end
Config = nil
load_resource('pfm-banking/payouts.lua')
load_resource('pfm-vehiclesales/config.lua')
load_resource('pfm-vehicleshop/settlements.lua')
load_resource('pfm-vehiclesales/server/main.lua')
PFUsedCars.Start()
assert(PFUsedCars.dbReady, 'pfm-vehiclesales migrations')

local SELLER, BUYER = 1, 2
local CAR_ENTITY = 700
local LOT = vector3(Config.Zones.SandyOccasions.BuyVehicle.x, Config.Zones.SandyOccasions.BuyVehicle.y, Config.Zones.SandyOccasions.BuyVehicle.z)
local runNo = 0
local sellerCid, buyerCid
local function bank(src) return Mock.players[src].PlayerData.money.bank end
local function later() Mock.gameTimer = Mock.gameTimer + 10000 end
local function row(plate) return MySQL.single.await('SELECT * FROM player_vehicles WHERE plate = ?', { plate }) end
local function listing(plate) return MySQL.single.await('SELECT * FROM occasion_vehicles WHERE plate = ?', { plate }) end
local function completed(pattern) return tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_transactions WHERE idempotency_key LIKE ? AND state = 'completed'", { pattern })) or 0 end
local function car(plate, cols)
    cols = cols or {}
    MySQL.insert.await([[INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, garage, state, fuel, engine, body, depotprice, drivingdistance,
        balance, paymentamount, paymentsleft, financetime) VALUES ('license:1', ?, 'sultan', '1', '{"old":1}', ?, 'pillboxgarage', 0, ?, ?, ?, ?, ?, ?, ?, ?, ?)]],
        { cols.citizenid or sellerCid, plate, cols.fuel or 100, cols.engine or 1000, cols.body or 1000, cols.depotprice or 0, cols.drivingdistance,
          cols.balance or 0, cols.paymentamount or 0, cols.paymentsleft or 0, cols.financetime or 0 })
end
local function seatIn(plate) Mock.vehicleOf[SELLER] = CAR_ENTITY Mock.plates[CAR_ENTITY] = plate end
local function list(plate) later() Mock.fireNet('qb-occasions:server:sellVehicle', SELLER, 9000, { plate = plate, model = 'sultan', mods = { color = 3 }, desc = 'nice' }) end
local function takeBack(plate) later() Mock.fireNet('qb-occasions:server:ReturnVehicle', SELLER, { plate = plate, oid = listing(plate).occasionid }) end
local function fleetCar(plate) MySQL.insert.await("INSERT INTO job_garage_vehicles (garage_id, plate, model, label, min_grade, active, assignment_type) VALUES ('mech', ?, 'sultan', 'x', 0, 1, 'none')", { plate }) end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords = {}, {}
    Mock.vehicleOf, Mock.plates, Mock.deleted = {}, {}, {}
    later()
    runNo = runNo + 1
    sellerCid, buyerCid = 'USELL' .. runNo, 'UBUY' .. runNo
    local seller = Mock.newPlayer(SELLER, sellerCid)
    seller.PlayerData.money = { cash = 0, bank = 1000 }
    seller.PlayerData.license = 'license:1'
    local buyer = Mock.newPlayer(BUYER, buyerCid)
    buyer.PlayerData.money = { cash = 0, bank = 50000 }
    buyer.PlayerData.license = 'license:2'
    for src in pairs(Mock.players) do Mock.players[src].PlayerData.source = src Mock.coords[src] = LOT end
    MySQL.query.await('DELETE FROM occasion_vehicles')
end

describe('the used-lot migration', function()
    it('adds the column to a table from the old install file, and is rerun-safe', function()
        local n = tonumber(MySQL.scalar.await([[SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE()
            AND TABLE_NAME = 'occasion_vehicles' AND COLUMN_NAME = 'vehicle_state']]))
        assert_eq(n, 1)
        for _, sql in ipairs(PFUsedCars.Migrations[1].up) do MySQL.query.await(sql) end   -- every step again
        PFUsedCars.Start()
        assert_true(PFUsedCars.dbReady)
    end)
end)

describe('listing and taking back', function()
    it('a paid-off car is listed with its record, and taken back with every column as it was', function()
        local plate = 'LST' .. runNo
        car(plate, { engine = 640.5, fuel = 37, body = 880, drivingdistance = 5000 })
        seatIn(plate)
        list(plate)
        assert_eq(row(plate), nil, 'the car left the garage')
        local l = listing(plate)
        assert_true(l ~= nil, 'listed')
        assert_eq(l.model, 'sultan')
        local kept = json.decode(l.vehicle_state)
        assert_eq(kept.engine, 640.5)
        assert_eq(kept.drivingdistance, 5000)
        assert_eq(Mock.deleted[1], CAR_ENTITY)
        takeBack(plate)
        local back = row(plate)
        assert_true(back ~= nil, 'back in the garage')
        assert_eq(back.citizenid, sellerCid)
        assert_eq(tonumber(back.engine), 640.5)
        assert_eq(tonumber(back.fuel), 37)
        assert_eq(tonumber(back.body), 880)
        assert_eq(tonumber(back.drivingdistance), 5000)
        assert_eq(tonumber(back.balance), 0)
        assert_eq(tonumber(back.hash), GetHashKey('sultan'))
        assert_eq(listing(plate), nil)
    end)
    it('a listing that carries a loan gives the finance columns back unchanged', function()
        local plate = 'OLD' .. runNo
        MySQL.insert.await('INSERT INTO occasion_vehicles (seller, price, description, plate, model, mods, occasionid, vehicle_state) VALUES (?, 9000, ?, ?, ?, ?, ?, ?)',
            { sellerCid, 'old', plate, 'sultan', '{}', 'OC77', json.encode({ balance = 8000, paymentamount = 1000, paymentsleft = 8, financetime = 600 }) })
        takeBack(plate)
        local back = row(plate)
        assert_eq(tonumber(back.balance), 8000)
        assert_eq(tonumber(back.paymentamount), 1000)
        assert_eq(tonumber(back.paymentsleft), 8)
        assert_eq(tonumber(back.financetime), 600)
    end)
    it('a financed car is not listed: the row and its loan stay', function()
        local plate = 'FIN' .. runNo
        car(plate, { balance = 8000, paymentamount = 1000, paymentsleft = 8, financetime = 600 })
        seatIn(plate)
        list(plate)
        assert_eq(listing(plate), nil)
        local r = row(plate)
        assert_eq(tonumber(r.balance), 8000)
        assert_eq(tonumber(r.paymentsleft), 8)
        assert_eq(#Mock.deleted, 0)
    end)
    it('an impounded car is not listed', function()
        local plate = 'DEP' .. runNo
        car(plate, { depotprice = 500 })
        seatIn(plate)
        list(plate)
        assert_eq(listing(plate), nil)
        assert_true(row(plate) ~= nil)
    end)
    it('a buyer gets the condition and odometer, not the loan', function()
        local plate = 'BUY' .. runNo
        MySQL.insert.await('INSERT INTO occasion_vehicles (seller, price, description, plate, model, mods, occasionid, vehicle_state) VALUES (?, 9000, ?, ?, ?, ?, ?, ?)',
            { sellerCid, 'x', plate, 'sultan', '{}', 'OC88', json.encode({ balance = 8000, paymentamount = 1000, paymentsleft = 8, financetime = 600, engine = 700, drivingdistance = 99 }) })
        later()
        Mock.fireNet('qb-occasions:server:buyVehicle', BUYER, { plate = plate, oid = 'OC88', price = 9000 })
        local r = row(plate)
        assert_eq(r.citizenid, buyerCid)
        assert_eq(tonumber(r.engine), 700)
        assert_eq(tonumber(r.drivingdistance), 99)
        assert_eq(tonumber(r.balance), 0)
        assert_eq(tonumber(r.paymentsleft), 0)
        assert_eq(bank(BUYER), 41000)
    end)
end)

describe('job fleet cars', function()
    it('are not listed or sold back', function()
        local plate = 'FLT' .. runNo
        car(plate)
        fleetCar(plate)
        seatIn(plate)
        list(plate)
        later()
        Mock.fireNet('qb-occasions:server:sellVehicleBack', SELLER, { plate = plate })
        assert_eq(listing(plate), nil)
        assert_true(row(plate) ~= nil)
        assert_eq(bank(SELLER), 1000)
    end)
    it('a car put in a fleet after the check is not taken by the hand-over', function()
        local plate = 'RAC' .. runNo
        car(plate)
        seatIn(plate)
        -- the fleet check answers "not in a fleet", and the car joins a fleet before the DELETE runs
        local scalar = MySQL.scalar
        MySQL.scalar = setmetatable({ await = function(q, p)
            if q:find('SELECT id FROM job_garage_vehicles', 1, true) then fleetCar(plate) return nil end
            return scalar.await(q, p)
        end }, getmetatable(scalar))
        list(plate)
        MySQL.scalar = scalar
        assert_eq(listing(plate), nil)
        assert_true(row(plate) ~= nil, 'the car is still in the garage record')
    end)
end)

describe('selling back', function()
    it('pays half the catalogue price once and removes the car', function()
        local plate = 'SBK' .. runNo
        car(plate)
        seatIn(plate)
        later()
        Mock.fireNet('qb-occasions:server:sellVehicleBack', SELLER, { plate = plate })
        later()
        Mock.fireNet('qb-occasions:server:sellVehicleBack', SELLER, { plate = plate })
        assert_eq(row(plate), nil)
        assert_eq(bank(SELLER), 11000)
        assert_eq(completed('pfm-vehiclesales:sellback:' .. plate .. ':%'), 1)
    end)
end)
