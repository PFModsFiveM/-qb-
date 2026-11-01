-- pfm-vehiclesales: a financed car is not listed on the used lot or sold back (listing deleted the
-- player_vehicles row, so taking it back came back with balance 0: the loan was gone), and neither
-- is an active job fleet car (pfm-garages never hands one out, so the buyer paid for nothing).
load_resource('tests/lua/ledger_env.lua')

QBCoreMock.Shared = QBCoreMock.Shared or {}
QBCoreMock.Shared.Vehicles = { sultan = { name = 'Sultan', price = 20000, hash = 'h_sultan' } }

local listings = {}   -- occasion_vehicles: [plate] = row
local owned = {}      -- player_vehicles: [plate] = row
local fleet = {}      -- job_garage_vehicles (active): [plate] = id

-- the DELETE keeps a financed row only when the statement says so (the old one did not)
local function guarded() return FakeDB.log[#FakeDB.log]:find('balance <= 0', 1, true) ~= nil end
local function ownedBy(p, column)
    local v = owned[p[1]]
    return v and v.citizenid == p[2] and v[column] == p[3] and v or nil
end

FakeDB.extraPatterns = {
    { "AND TABLE_NAME = 'job_garage_vehicles'", function() return 1 end },
    { 'FROM job_garage_vehicles WHERE plate = ? AND active = 1', function(p) return fleet[p[1]] end },
    { 'SELECT balance FROM player_vehicles WHERE plate = ? AND citizenid = ? AND vehicle = ?', function(p)
        local v = ownedBy(p, 'vehicle')
        return v and { { balance = v.balance } } or {}
    end },
    { 'SELECT balance FROM player_vehicles WHERE plate = ? AND citizenid = ? AND hash = ?', function(p)
        local v = ownedBy(p, 'hash')
        return v and { { balance = v.balance } } or {}
    end },
    { 'DELETE FROM player_vehicles WHERE plate = ? AND citizenid = ? and vehicle = ?', function(p)
        local v = ownedBy(p, 'vehicle')
        if v and (v.balance <= 0 or not guarded()) then owned[p[1]] = nil return { affectedRows = 1 } end
        return { affectedRows = 0 }
    end },
    { 'DELETE FROM player_vehicles WHERE plate = ? AND citizenid = ? and hash = ?', function(p)
        local v = ownedBy(p, 'hash')
        if v and (v.balance <= 0 or not guarded()) then owned[p[1]] = nil return { affectedRows = 1 } end
        return { affectedRows = 0 }
    end },
    { 'INSERT INTO occasion_vehicles', function(p)
        listings[p[4]] = { seller = p[1], price = p[2], description = p[3], plate = p[4], model = p[5], mods = p[6], occasionid = p[7] }
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
    { 'INSERT INTO player_vehicles', function(p)
        owned[p[6]] = { citizenid = p[2], vehicle = p[3], hash = p[4], plate = p[6], balance = 0 }
        return 1
    end },
}

LedgerEnv.load('pfm-vehiclesales', { 'pfm-vehiclesales/config.lua', 'pfm-vehiclesales/server/main.lua' })

local SELLER = 1
local LOT = vector3(Config.Zones.SandyOccasions.BuyVehicle.x, Config.Zones.SandyOccasions.BuyVehicle.y, Config.Zones.SandyOccasions.BuyVehicle.z)
local function bank(src) return Mock.players[src].PlayerData.money.bank end
local function later() Mock.gameTimer = Mock.gameTimer + 10000 end
local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
local function car(plate, balance)
    owned[plate] = { citizenid = 'CID1', vehicle = 'sultan', hash = 'h_sultan', plate = plate, balance = balance,
        paymentamount = balance > 0 and 1000 or 0, paymentsleft = balance > 0 and 8 or 0, financetime = balance > 0 and 600 or 0 }
    return owned[plate]
end
local function list(plate) Mock.fireNet('qb-occasions:server:sellVehicle', SELLER, 9000, { plate = plate, model = 'sultan', mods = {}, desc = 'nice' }) end
local function sellBack(plate) Mock.fireNet('qb-occasions:server:sellVehicleBack', SELLER, { plate = plate, model = 'h_sultan' }) end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players, Mock.coords = {}, {}
    later()
    local p = Mock.newPlayer(SELLER)
    p.PlayerData.money = { cash = 0, bank = 1000 }
    p.PlayerData.license = 'license:1'
    Mock.coords[SELLER] = LOT
    listings, owned, fleet = {}, {}, {}
end

describe('a financed car on the used lot', function()
    it('is not listed: the car and its loan stay as they were', function()
        local row = car('LOAN1', 8000)
        list('LOAN1')
        assert_eq(count(listings), 0, 'nothing listed')
        assert_true(owned.LOAN1 == row, 'the row was not deleted')
        assert_eq(owned.LOAN1.balance, 8000)
        assert_eq(owned.LOAN1.paymentamount, 1000)
        assert_eq(owned.LOAN1.paymentsleft, 8)
        assert_eq(owned.LOAN1.financetime, 600)
    end)
    it('is not sold back to the lot (no payout, the loan stays)', function()
        car('LOAN2', 8000)
        sellBack('LOAN2')
        assert_eq(bank(SELLER), 1000)
        assert_eq(owned.LOAN2.balance, 8000)
        assert_eq(#LedgerEnv.paid('pfm-vehiclesales:sellback:'), 0)
    end)
    it('a paid-off car is still listed and taken back as before', function()
        car('FREE1', 0)
        list('FREE1')
        assert_eq(owned.FREE1, nil)
        local l = listings.FREE1
        assert_true(l ~= nil, 'listed')
        later()
        Mock.fireNet('qb-occasions:server:ReturnVehicle', SELLER, { plate = 'FREE1', oid = l.occasionid })
        assert_eq(listings.FREE1, nil)
        assert_eq(owned.FREE1.citizenid, 'CID1')
    end)
end)

describe('a job fleet car on the used lot', function()
    it('is not listed', function()
        car('FLEET1', 0)
        fleet.FLEET1 = 7
        list('FLEET1')
        assert_eq(count(listings), 0)
        assert_true(owned.FLEET1 ~= nil, 'still the owner\'s car')
    end)
    it('is not sold back', function()
        car('FLEET2', 0)
        fleet.FLEET2 = 8
        sellBack('FLEET2')
        assert_eq(bank(SELLER), 1000)
        assert_true(owned.FLEET2 ~= nil)
    end)
    it('a car that left the fleet can be sold back', function()
        car('FLEET3', 0)
        sellBack('FLEET3')
        assert_eq(owned.FLEET3, nil)
        assert_eq(bank(SELLER), 11000)
    end)
end)
