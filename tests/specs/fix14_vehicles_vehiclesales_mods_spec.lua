-- pfm-vehiclesales (fix14 VS-1): a listing shows and hands on the look saved on the car's own record
-- (player_vehicles.mods, what the garage or a mechanic last saved), with its plate. The props the
-- seller's client sent were stored as they came, so listing a stock car with forged props
-- (engine 3, armour 4, turbo...) and taking it back wrote those upgrades into the garage record,
-- and a buyer got exactly the forged car.
load_resource('tests/lua/ledger_env.lua')

QBCoreMock.Shared = QBCoreMock.Shared or {}
QBCoreMock.Shared.Vehicles = { sultan = { name = 'Sultan', price = 20000, hash = 'h_sultan' } }
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end

local listings, owned = {}, {}
local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
local function lastQuery() return FakeDB.log[#FakeDB.log] end
local function ownedBy(plate, cid)
    local v = owned[plate]
    return v and v.citizenid == cid and v or nil
end
FakeDB.extraPatterns = {
    { "AND TABLE_NAME = 'job_garage_vehicles'", function() return 0 end },
    { 'SELECT * FROM player_vehicles WHERE plate = ? AND citizenid = ?', function(p)
        local v = ownedBy(p[1], p[2])
        return v and { v } or {}
    end },
    { 'SELECT COUNT(*) FROM occasion_vehicles', function() return count(listings) end },
    { 'DELETE FROM player_vehicles WHERE plate = ? AND citizenid = ?', function(p)
        if not ownedBy(p[1], p[2]) then return { affectedRows = 0 } end
        owned[p[1]] = nil
        return { affectedRows = 1 }
    end },
    { 'INSERT INTO occasion_vehicles', function(p)
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
    { 'INSERT INTO player_vehicles (', function(p)
        local row, i = {}, 0
        for col in lastQuery():match('%((.-)%)'):gmatch('[^,%s`]+') do i = i + 1 row[col] = p[i] end
        owned[row.plate] = row
        return 1
    end },
    { "FROM pfm_vehiclesales_held WHERE state IN ('waiting', 'finishing')", function() return {} end },
    { 'INSERT IGNORE INTO pfm_vehiclesales_owed', function() return 1 end },
}
LedgerEnv.load('pfm-vehiclesales', { 'pfm-vehiclesales/config.lua', 'pfm-vehicleshop/settlements.lua', 'pfm-vehiclesales/server/main.lua' })
Mock.exportsByResource['pfm-phone'] = { sendNewMailToOffline = function() end }

local SELLER, BUYER = 1, 2
local CAR_ENTITY = 700
local LOT = vector3(Config.Zones.SandyOccasions.BuyVehicle.x, Config.Zones.SandyOccasions.BuyVehicle.y, Config.Zones.SandyOccasions.BuyVehicle.z)
local FORGED = { modEngine = 3, modBrakes = 2, modTransmission = 2, modSuspension = 3, modArmor = 4, modTurbo = true, plate = 'SOMEONE' }
local function later() Mock.gameTimer = Mock.gameTimer + 10000 end
local function seatIn(plate) Mock.vehicleOf[SELLER] = CAR_ENTITY Mock.plates[CAR_ENTITY] = plate end
local function list(plate, mods) later() Mock.fireNet('qb-occasions:server:sellVehicle', SELLER, 9000, { plate = plate, model = 'sultan', mods = mods, desc = 'clean' }) end
local function takeBack(plate) later() Mock.fireNet('qb-occasions:server:ReturnVehicle', SELLER, { plate = plate, oid = listings[plate].occasionid }) end
local function buy(plate) later() Mock.fireNet('qb-occasions:server:buyVehicle', BUYER, { plate = plate, oid = listings[plate].occasionid, price = listings[plate].price }) end

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
    listings, owned = {}, {}
    owned.STOCK1 = { id = 5, citizenid = 'CID1', license = 'license:1', vehicle = 'sultan', hash = 'h_sultan', plate = 'STOCK1',
        mods = '{"color1":12,"modEngine":-1}', state = 0, balance = 0, depotprice = 0, fuel = 80, engine = 1000, body = 1000 }
    PFUsedCars.Start()
end

describe('fix14 VS-1: the look of a listed car', function()
    it('is the one on the car\'s record, whatever props the client sends', function()
        seatIn('STOCK1')
        list('STOCK1', FORGED)
        local l = listings.STOCK1
        assert_true(l ~= nil, 'listed')
        local mods = json.decode(l.mods)
        assert_eq(mods.color1, 12, 'the saved colour')
        assert_eq(mods.modEngine, -1, 'the saved (stock) engine')
        assert_eq(mods.modArmor, nil, 'no forged armour')
        assert_eq(mods.modTurbo, nil, 'no forged turbo')
        assert_eq(mods.plate, 'STOCK1', 'with the car\'s own plate')
    end)

    it('comes back unchanged when the seller takes the car back', function()
        seatIn('STOCK1')
        list('STOCK1', FORGED)
        takeBack('STOCK1')
        local back = json.decode(owned.STOCK1.mods)
        assert_eq(back.modEngine, -1)
        assert_eq(back.modArmor, nil)
        assert_eq(back.color1, 12)
    end)

    it('is what a buyer gets', function()
        seatIn('STOCK1')
        list('STOCK1', FORGED)
        buy('STOCK1')
        local bought = owned.STOCK1
        assert_eq(bought.citizenid, 'CID2')
        local mods = json.decode(bought.mods)
        assert_eq(mods.modArmor, nil)
        assert_eq(mods.color1, 12)
        local finished = Mock.clientEventsNamed('qb-occasions:client:BuyFinished')
        assert_eq(#finished, 1)
        assert_eq(json.decode(finished[1].args[1].mods).modTurbo, nil)
    end)

    it('a car with no saved look (never parked) is listed stock, not refused; garbage on record reads as stock', function()
        owned.STOCK1.mods = nil
        seatIn('STOCK1')
        list('STOCK1', FORGED)
        assert_eq(json.decode(listings.STOCK1.mods).modArmor, nil)
        assert_eq(json.decode(listings.STOCK1.mods).plate, 'STOCK1')
        takeBack('STOCK1')
        owned.STOCK1.mods = 'not json'
        seatIn('STOCK1')
        list('STOCK1', nil)
        assert_eq(json.decode(listings.STOCK1.mods).plate, 'STOCK1')
    end)
end)
