-- pfm-vehiclesales (used lot): a financed car is not listed or sold back (listing removed the
-- player_vehicles row, so taking it back came back with balance 0: the loan was gone), and neither is
-- an active job fleet car (pfm-garages never hands one out, so the buyer paid for nothing) or an
-- impounded one. A listing keeps the car's own record, so taking it back restores the finance columns
-- (never reset) with its condition and odometer; a buyer gets the condition, never a loan. The car
-- listed or sold back is the one the seller sits in (read on the server), and the server removes it.
load_resource('tests/lua/ledger_env.lua')

QBCoreMock.Shared = QBCoreMock.Shared or {}
QBCoreMock.Shared.Vehicles = { sultan = { name = 'Sultan', price = 20000, hash = 'h_sultan' } }
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end

local listings = {}   -- occasion_vehicles: [plate] = row
local owned = {}      -- player_vehicles: [plate] = row
local fleet = {}      -- job_garage_vehicles (active): [plate] = id
local failListing = false
local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
local function lastQuery() return FakeDB.log[#FakeDB.log] end
local function ownedBy(plate, cid)
    local v = owned[plate]
    return v and v.citizenid == cid and v or nil
end

FakeDB.extraPatterns = {
    { "AND TABLE_NAME = 'job_garage_vehicles'", function() return 1 end },
    { 'SELECT id FROM job_garage_vehicles WHERE plate = ? AND active = 1', function(p) return fleet[p[1]] end },
    { 'SELECT balance, depotprice FROM player_vehicles WHERE plate = ? AND citizenid = ?', function(p)
        local v = ownedBy(p[1], p[2])
        return v and { v } or {}
    end },
    { 'SELECT * FROM player_vehicles WHERE plate = ? AND citizenid = ?', function(p)
        local v = ownedBy(p[1], p[2])
        return v and { v } or {}
    end },
    { 'SELECT COUNT(*) FROM occasion_vehicles', function() return count(listings) end },
    -- the hand-over: only a paid-off, not impounded car, and (when the statement says so) not in a fleet
    { 'DELETE FROM player_vehicles WHERE plate = ? AND citizenid = ?', function(p)
        local v = ownedBy(p[1], p[2])
        local q = lastQuery()
        if not v then return { affectedRows = 0 } end
        if q:find('balance <= 0', 1, true) and (v.balance or 0) > 0 then return { affectedRows = 0 } end
        if q:find('depotprice <= 0', 1, true) and (v.depotprice or 0) > 0 then return { affectedRows = 0 } end
        if q:find('NOT EXISTS', 1, true) and fleet[p[3]] then return { affectedRows = 0 } end
        owned[p[1]] = nil
        return { affectedRows = 1 }
    end },
    { 'INSERT INTO occasion_vehicles', function(p)
        if failListing then return nil end
        listings[p[4]] = { seller = p[1], price = p[2], description = p[3], plate = p[4], model = p[5], mods = p[6], occasionid = p[7], vehicle_state = p[8] }
        return 1
    end },
    { 'SELECT * FROM occasion_vehicles WHERE plate = ? AND occasionid = ?', function(p)
        local l = listings[p[1]]
        return (l and l.occasionid == p[2]) and { l } or {}
    end },
    { 'DELETE FROM occasion_vehicles WHERE occasionid = ? AND plate = ?', function(p)
        local l = listings[p[2]]
        if l and l.occasionid == p[1] then listings[p[2]] = nil return { affectedRows = 1 } end
        return { affectedRows = 0 }
    end },
    { 'DELETE FROM occasion_vehicles WHERE plate = ? AND occasionid = ? AND price = ?', function(p)
        local l = listings[p[1]]
        if l and l.occasionid == p[2] and l.price == p[3] then listings[p[1]] = nil return { affectedRows = 1 } end
        return { affectedRows = 0 }
    end },
    -- a garage row with exactly the columns the statement names
    { 'INSERT INTO player_vehicles (', function(p)
        local row, i = {}, 0
        for col in lastQuery():match('%((.-)%)'):gmatch('[^,%s`]+') do i = i + 1 row[col] = p[i] end
        owned[row.plate] = row
        return 1
    end },
}
-- the settlement tables (settlements.lua): nothing held or owed in these tests
FakeDB.extraPatterns[#FakeDB.extraPatterns + 1] = { "FROM pfm_vehiclesales_held WHERE state IN ('waiting', 'finishing')", function() return {} end }
FakeDB.extraPatterns[#FakeDB.extraPatterns + 1] = { 'INSERT IGNORE INTO pfm_vehiclesales_owed', function() return 1 end }

LedgerEnv.load('pfm-vehiclesales', { 'pfm-vehiclesales/config.lua', 'pfm-vehicleshop/settlements.lua', 'pfm-vehiclesales/server/main.lua' })
Mock.exportsByResource['pfm-phone'] = { sendNewMailToOffline = function() end }

local SELLER, BUYER = 1, 2
local CAR_ENTITY = 700
local LOT = vector3(Config.Zones.SandyOccasions.BuyVehicle.x, Config.Zones.SandyOccasions.BuyVehicle.y, Config.Zones.SandyOccasions.BuyVehicle.z)
local function bank(src) return Mock.players[src].PlayerData.money.bank end
local function later() Mock.gameTimer = Mock.gameTimer + 10000 end
local function car(plate, balance, extra)
    owned[plate] = { id = 5, citizenid = 'CID1', license = 'license:1', vehicle = 'sultan', hash = 'h_sultan', plate = plate, mods = '{"old":1}', state = 0,
        balance = balance, paymentamount = balance > 0 and 1000 or 0, paymentsleft = balance > 0 and 8 or 0, financetime = balance > 0 and 600 or 0,
        depotprice = 0, fuel = 100, engine = 1000, body = 1000 }
    for k, v in pairs(extra or {}) do owned[plate][k] = v end
    return owned[plate]
end
-- the seller sits in the car with that plate (what the server reads)
local function seatIn(plate) Mock.vehicleOf[SELLER] = CAR_ENTITY Mock.plates[CAR_ENTITY] = plate end
local function list(plate) later() Mock.fireNet('qb-occasions:server:sellVehicle', SELLER, 9000, { plate = plate, model = 'sultan', mods = { color = 3 }, desc = 'nice' }) end
local function sellBack(plate) later() Mock.fireNet('qb-occasions:server:sellVehicleBack', SELLER, { plate = plate, model = 'h_sultan' }) end
local function takeBack(plate) later() Mock.fireNet('qb-occasions:server:ReturnVehicle', SELLER, { plate = plate, oid = listings[plate].occasionid }) end
local function listedEvents() return #Mock.clientEventsNamed('qb-occasions:client:vehicleListed') end
local function notified(text)
    for _, e in ipairs(Mock.clientEventsNamed('QBCore:Notify')) do if e.args[1] == text then return true end end
    return false
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players, Mock.coords = {}, {}
    Mock.vehicleOf, Mock.plates, Mock.deleted = {}, {}, {}
    later()
    for src, money in pairs({ [SELLER] = 1000, [BUYER] = 50000 }) do
        local p = Mock.newPlayer(src)
        p.PlayerData.money = { cash = 0, bank = money }
        p.PlayerData.license = 'license:' .. src
        Mock.coords[src] = LOT
    end
    listings, owned, fleet, failListing = {}, {}, {}, false
    PFUsedCars.Start()
end

describe('the used-lot schema', function()
    it('the migration adds the column that keeps the car record (rerun-safe)', function()
        assert_true(PFUsedCars.dbReady)
        local found = false
        for _, step in ipairs(PFUsedCars.Migrations[1].up) do
            if step:find('ADD COLUMN IF NOT EXISTS `vehicle_state`', 1, true) then found = true end
        end
        assert_true(found)
    end)
end)

describe('a financed car on the used lot', function()
    it('is not listed: the car and its loan stay as they were, and it stays in the world', function()
        local row = car('LOAN1', 8000)
        seatIn('LOAN1')
        list('LOAN1')
        assert_eq(count(listings), 0, 'nothing listed')
        assert_true(owned.LOAN1 == row, 'the row was not deleted')
        assert_eq(owned.LOAN1.balance, 8000)
        assert_eq(owned.LOAN1.paymentamount, 1000)
        assert_eq(owned.LOAN1.paymentsleft, 8)
        assert_eq(owned.LOAN1.financetime, 600)
        assert_eq(#Mock.deleted, 0, 'the car was not removed')
        assert_eq(listedEvents(), 0, 'the client is not told to remove it')
        assert_true(notified('error.finish_payments'))
    end)
    it('is not sold back to the lot (no payout, the loan stays)', function()
        car('LOAN2', 8000)
        seatIn('LOAN2')
        sellBack('LOAN2')
        assert_eq(bank(SELLER), 1000)
        assert_eq(owned.LOAN2.balance, 8000)
        assert_eq(#LedgerEnv.paid('pfm-vehiclesales:sellback:'), 0)
        assert_eq(#Mock.deleted, 0)
    end)
    it('a listing that carries a loan gives it back on take-back: the finance columns are never reset', function()
        -- a car listed with a plan on record (e.g. before this rule): taking it back must not clear it
        listings.OLDLOAN = { seller = 'CID1', price = 9000, plate = 'OLDLOAN', occasionid = 'OC5', model = 'sultan', mods = '{}',
            vehicle_state = json.encode({ balance = 8000, paymentamount = 1000, paymentsleft = 8, financetime = 600, engine = 812.5, fuel = 41, body = 990, drivingdistance = 1234 }) }
        takeBack('OLDLOAN')
        local back = owned.OLDLOAN
        assert_true(back ~= nil, 'the car is back')
        assert_eq(back.citizenid, 'CID1')
        assert_eq(back.balance, 8000)
        assert_eq(back.paymentamount, 1000)
        assert_eq(back.paymentsleft, 8)
        assert_eq(back.financetime, 600)
        assert_eq(back.engine, 812.5)
        assert_eq(back.fuel, 41)
        assert_eq(back.drivingdistance, 1234)
        assert_eq(listings.OLDLOAN, nil)
    end)
    it('a paid-off car is listed and taken back with its record unchanged', function()
        car('FREE1', 0, { engine = 640, fuel = 37, drivingdistance = 5000 })
        seatIn('FREE1')
        list('FREE1')
        assert_eq(owned.FREE1, nil)
        local l = listings.FREE1
        assert_true(l ~= nil, 'listed')
        assert_eq(l.model, 'sultan', 'the model on record')
        assert_eq(Mock.deleted[1], CAR_ENTITY, 'the server removed the listed car')
        assert_eq(listedEvents(), 1)
        local kept = json.decode(l.vehicle_state)
        assert_eq(kept.balance, 0)
        assert_eq(kept.engine, 640)
        takeBack('FREE1')
        assert_eq(listings.FREE1, nil)
        assert_eq(owned.FREE1.citizenid, 'CID1')
        assert_eq(owned.FREE1.balance, 0)
        assert_eq(owned.FREE1.paymentsleft, 0)
        assert_eq(owned.FREE1.engine, 640)
        assert_eq(owned.FREE1.fuel, 37)
        assert_eq(owned.FREE1.drivingdistance, 5000)
    end)
    it('a listing from before the record was kept still comes back', function()
        listings.LEGACY = { seller = 'CID1', price = 500, plate = 'LEGACY', occasionid = 'OC7', model = 'sultan', mods = '{}' }
        takeBack('LEGACY')
        assert_eq(owned.LEGACY.citizenid, 'CID1')
        assert_eq(owned.LEGACY.balance, nil, 'the table default applies')
    end)
    it('a buyer gets the car\'s condition but never a loan', function()
        listings.SOLD1 = { seller = 'CID9', price = 9000, plate = 'SOLD1', occasionid = 'OC8', model = 'sultan', mods = '{}',
            vehicle_state = json.encode({ balance = 8000, paymentamount = 1000, paymentsleft = 8, financetime = 600, engine = 700, drivingdistance = 99 }) }
        later()
        Mock.fireNet('qb-occasions:server:buyVehicle', BUYER, { plate = 'SOLD1', oid = 'OC8', price = 9000 })
        assert_eq(owned.SOLD1.citizenid, 'CID2')
        assert_eq(owned.SOLD1.engine, 700)
        assert_eq(owned.SOLD1.drivingdistance, 99)
        assert_eq(owned.SOLD1.balance, nil)
        assert_eq(owned.SOLD1.paymentsleft, nil)
        assert_eq(bank(BUYER), 41000)
    end)
end)

describe('which car is listed', function()
    it('only the car the seller sits in, whatever plate the client names', function()
        car('MINE1', 0)
        car('PARKED', 0)
        seatIn('MINE1')
        later()
        Mock.fireNet('qb-occasions:server:sellVehicle', SELLER, 9000, { plate = 'PARKED', model = 'sultan', mods = {}, desc = '' })
        assert_eq(listings.PARKED, nil, 'not the parked car')
        assert_true(owned.PARKED ~= nil)
        assert_true(listings.MINE1 ~= nil, 'the car they sit in')
    end)
    it('not on foot', function()
        car('WALK1', 0)
        list('WALK1')
        assert_eq(count(listings), 0)
        assert_true(owned.WALK1 ~= nil)
    end)
    it('not an impounded car', function()
        car('DEPOT1', 0, { depotprice = 500 })
        seatIn('DEPOT1')
        list('DEPOT1')
        assert_eq(count(listings), 0)
        assert_true(owned.DEPOT1 ~= nil)
        assert_true(notified('error.impounded'))
    end)
    it('not onto a full lot', function()
        for i = 1, #Config.Zones.SandyOccasions.VehicleSpots do listings['FULL' .. i] = { plate = 'FULL' .. i, occasionid = 'OC' .. i } end
        car('ONEMORE', 0)
        seatIn('ONEMORE')
        list('ONEMORE')
        assert_eq(listings.ONEMORE, nil)
        assert_true(owned.ONEMORE ~= nil)
        assert_true(notified('error.no_space_on_lot'))
    end)
    it('when the listing cannot be written, the car goes back to its owner as it was', function()
        car('FAIL1', 0, { engine = 512 })
        seatIn('FAIL1')
        failListing = true
        list('FAIL1')
        assert_eq(count(listings), 0)
        assert_eq(owned.FAIL1.citizenid, 'CID1')
        assert_eq(owned.FAIL1.engine, 512)
        assert_eq(owned.FAIL1.mods, '{"old":1}')
        assert_eq(#Mock.deleted, 0, 'the car stays in the world')
    end)
end)

describe('a job fleet car on the used lot', function()
    it('is not listed', function()
        car('FLEET1', 0)
        fleet.FLEET1 = 7
        seatIn('FLEET1')
        list('FLEET1')
        assert_eq(count(listings), 0)
        assert_true(owned.FLEET1 ~= nil, 'still the owner\'s car')
        assert_true(notified('error.fleet_vehicle'))
    end)
    it('is not sold back', function()
        car('FLEET2', 0)
        fleet.FLEET2 = 8
        seatIn('FLEET2')
        sellBack('FLEET2')
        assert_eq(bank(SELLER), 1000)
        assert_true(owned.FLEET2 ~= nil)
    end)
    it('a car put in a fleet between the check and the hand-over is refused by the hand-over itself', function()
        car('FLEET4', 0)
        seatIn('FLEET4')
        -- the fleet check passes, then the car joins a fleet before the DELETE runs
        local check = FakeDB.extraPatterns[2]
        local original = check[2]
        check[2] = function(p) fleet.FLEET4 = 9 return nil end
        list('FLEET4')
        check[2] = original
        assert_eq(count(listings), 0)
        assert_true(owned.FLEET4 ~= nil)
    end)
    it('the menu is told why before the contract opens', function()
        car('FLEET5', 0)
        fleet.FLEET5 = 3
        local owns, balance, blocked = Mock.callCallback('qb-occasions:server:checkVehicleOwner', SELLER, 'FLEET5')
        assert_true(owns == true)
        assert_eq(balance, 0)
        assert_eq(blocked, 'error.fleet_vehicle')
    end)
    it('a car that left the fleet can be sold back, once, and the server removes it', function()
        car('FLEET3', 0)
        seatIn('FLEET3')
        sellBack('FLEET3')
        sellBack('FLEET3')
        assert_eq(owned.FLEET3, nil)
        assert_eq(bank(SELLER), 11000)
        assert_eq(#LedgerEnv.paid('pfm-vehiclesales:sellback:'), 1)
        assert_eq(Mock.deleted[1], CAR_ENTITY)
    end)
end)
