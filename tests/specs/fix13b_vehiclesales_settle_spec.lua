-- pfm-vehiclesales (used lot) on the real ledger (fake database): a job fleet car is not sold, and
-- the claim that hands a listing over repeats the fleet check in the same statement; the lot's
-- listing callback sends only what the lot shows (not the seller's loan); a failed fleet-table lookup
-- refuses instead of being cached as "no fleet"; a purchase whose charge the bank cannot confirm yet
-- gives no car now, holds the listing, and is finished (car parked) or put back when the ledger
-- settles; the seller's money and refunds are kept and retried until paid; a sell-back the bank may
-- still pay is paid, once, instead of being lost.
load_resource('tests/lua/ledger_env.lua')

QBCoreMock.Shared = QBCoreMock.Shared or {}
QBCoreMock.Shared.Vehicles = { sultan = { name = 'Sultan', price = 20000, hash = 'h_sultan' } }
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end

local listings = {}   -- occasion_vehicles: [plate] = row
local owned = {}      -- player_vehicles: [plate] = row
local fleet = {}      -- job_garage_vehicles (active): [plate] = id
local fleetLookupBroken = false
local fleetOnClaim = nil   -- a plate put in a fleet in the moment the claim runs
local nextListing = 1
local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
local function lastQuery() return FakeDB.log[#FakeDB.log] end

local store = { owed = {}, held = {}, n = 0 }
local function copy(r) local c = {} for k, v in pairs(r) do c[k] = v end return c end
local function rowsOf(t, keep)
    local out = {}
    for _, r in pairs(t) do if keep(r) then out[#out + 1] = copy(r) end end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

FakeDB.extraPatterns = {
    -- the settlement tables, as the real ones behave (rows copied out, unique keys)
    { 'INSERT IGNORE INTO pfm_vehiclesales_owed', function(p)
        for _, r in pairs(store.owed) do if r.ledger_key == p[1] then return 0 end end
        store.n = store.n + 1
        store.owed[store.n] = { id = store.n, ledger_key = p[1], attempt = p[2], to_kind = p[3], to_id = p[4], account = p[5], amount = p[6],
            kind = p[7], reason = p[8], state = p[9], last_error = p[10] }
        return store.n
    end },
    { "FROM pfm_vehiclesales_owed WHERE state = 'open'", function() return rowsOf(store.owed, function(r) return r.state == 'open' end) end },
    { 'UPDATE pfm_vehiclesales_owed SET attempt = ?, state = ?, last_error = ? WHERE id = ?', function(p)
        local r = store.owed[p[4]]
        if r then r.attempt, r.state, r.last_error = p[1], p[2], p[3] end
        return r and 1 or 0
    end },
    { 'INSERT INTO pfm_vehiclesales_held', function(p)
        local row
        for _, r in pairs(store.held) do if r.charge_key == p[2] then row = r end end
        if not row then store.n = store.n + 1 row = { id = store.n } store.held[store.n] = row end
        row.flow, row.charge_key, row.accounts, row.tx_id, row.citizenid, row.plate, row.amount, row.data, row.state, row.outcome, row.created =
            p[1], p[2], p[3], p[4], p[5], p[6], p[7], p[8], 'waiting', nil, p[9]
        return row.id
    end },
    { "FROM pfm_vehiclesales_held WHERE state IN ('waiting', 'finishing')", function()
        return rowsOf(store.held, function(r) return r.state == 'waiting' or r.state == 'finishing' end)
    end },
    { 'UPDATE pfm_vehiclesales_held SET state = ?, outcome = ? WHERE id = ? AND state = ?', function(p)
        local r = store.held[p[3]]
        if not r or r.state ~= p[4] then return 0 end
        r.state, r.outcome = p[1], p[2]
        return 1
    end },
    { 'UPDATE pfm_vehiclesales_held SET data = ? WHERE id = ?', function(p) local r = store.held[p[2]] if r then r.data = p[1] end return 1 end },

    { "AND TABLE_NAME = 'job_garage_vehicles'", function()
        if fleetLookupBroken then return nil end   -- what oxmysql gives for a query that failed
        return 1
    end },
    { 'SELECT id FROM job_garage_vehicles WHERE plate = ? AND active = 1', function(p) return fleet[p[1]] end },
    { 'SELECT balance, depotprice FROM player_vehicles WHERE plate = ? AND citizenid = ?', function(p)
        local v = owned[p[1]]
        return (v and v.citizenid == p[2]) and { v } or {}
    end },
    { 'SELECT * FROM player_vehicles WHERE plate = ? AND citizenid = ?', function(p)
        local v = owned[p[1]]
        return (v and v.citizenid == p[2]) and { v } or {}
    end },
    { 'SELECT citizenid FROM player_vehicles WHERE plate = ?', function(p) return owned[p[1]] and owned[p[1]].citizenid or nil end },
    { 'SELECT COUNT(*) FROM occasion_vehicles', function() return count(listings) end },
    { 'DELETE FROM player_vehicles WHERE plate = ? AND citizenid = ?', function(p)
        local v = owned[p[1]]
        if not v or v.citizenid ~= p[2] or (v.balance or 0) > 0 or (v.depotprice or 0) > 0 then return { affectedRows = 0 } end
        if lastQuery():find('NOT EXISTS', 1, true) and fleet[p[3]] then return { affectedRows = 0 } end
        owned[p[1]] = nil
        return { affectedRows = 1 }
    end },
    { 'INSERT INTO occasion_vehicles', function(p)
        nextListing = nextListing + 1
        listings[p[4]] = { id = nextListing, seller = p[1], price = p[2], description = p[3], plate = p[4], model = p[5], mods = p[6], occasionid = p[7], vehicle_state = p[8] }
        return nextListing
    end },
    { 'SELECT seller, price, description, plate, model, mods, occasionid FROM occasion_vehicles ORDER BY id', function()
        local out = {}
        for _, l in pairs(listings) do
            out[#out + 1] = { seller = l.seller, price = l.price, description = l.description, plate = l.plate, model = l.model, mods = l.mods, occasionid = l.occasionid }
        end
        return out
    end },
    { 'SELECT * FROM occasion_vehicles WHERE plate = ? AND occasionid = ?', function(p)
        local l = listings[p[1]]
        return (l and l.occasionid == p[2]) and { l } or {}
    end },
    { 'SELECT id FROM occasion_vehicles WHERE occasionid = ? AND plate = ?', function(p)
        local l = listings[p[2]]
        return (l and l.occasionid == p[1]) and l.id or nil
    end },
    -- the buyer's claim: the listing as it was read (price) and, when the statement says so, not a fleet car
    { 'DELETE FROM occasion_vehicles WHERE plate = ? AND occasionid = ? AND price = ?', function(p)
        if fleetOnClaim then fleet[fleetOnClaim] = 9 end
        local l = listings[p[1]]
        if not l or l.occasionid ~= p[2] or l.price ~= p[3] then return { affectedRows = 0 } end
        if lastQuery():find('NOT EXISTS', 1, true) and fleet[p[4]] then return { affectedRows = 0 } end
        listings[p[1]] = nil
        return { affectedRows = 1 }
    end },
    { 'INSERT INTO player_vehicles (', function(p)
        local row, i = {}, 0
        for col in lastQuery():match('%((.-)%)'):gmatch('[^,%s`]+') do i = i + 1 row[col] = p[i] end
        owned[row.plate] = row
        return 1
    end },
}

LedgerEnv.load('pfm-vehiclesales', { 'pfm-vehiclesales/config.lua', 'pfm-vehicleshop/settlements.lua', 'pfm-vehiclesales/server/main.lua' })
Mock.exportsByResource['pfm-phone'] = { sendNewMailToOffline = function() end }

-- the write that completes a charge fails once: the money left the buyer, recovery completes it
local failCredit = false
local fakeUpdate = MySQL.update
MySQL.update = setmetatable({ await = function(q, p)
    if failCredit and q == PFLedger.SQL.setState and p[1] == 'completed' and p[4] == 'debited' then
        failCredit = false
        error('injected: the credit write failed')
    end
    return fakeUpdate.await(q, p)
end }, { __call = function(_, ...) return fakeUpdate(...) end })

local bank = Mock.exportsByResource['pfm-banking']
local realTransfer = bank.Transfer
local intercept = {}   -- [key pattern] = reply instead of running the transfer
bank.Transfer = function(opts)
    for pattern, reply in pairs(intercept) do if opts.key:find(pattern) then return reply end end
    return realTransfer(opts)
end
Mock.rawExports[bank.Transfer] = true

local SELLER, BUYER = 1, 2
local LOT = vector3(Config.Zones.SandyOccasions.BuyVehicle.x, Config.Zones.SandyOccasions.BuyVehicle.y, Config.Zones.SandyOccasions.BuyVehicle.z)
local function balance(src) return Mock.players[src].PlayerData.money.bank end
local function later() Mock.gameTimer = Mock.gameTimer + 10000 end
local function holds() return rowsOf(store.held, function() return true end) end
local function owedRows() return rowsOf(store.owed, function() return true end) end
local function told(src, key)
    for _, e in ipairs(Mock.clientEventsNamed('QBCore:Notify')) do
        if e.target == src and e.args[1] == key then return true end
    end
    return false
end
local function settle() Mock.clock = Mock.clock + 120 PFLedger.Recover() PFSettle.Sweep() end
local function listCar(plate, price)
    nextListing = nextListing + 1
    listings[plate] = { id = nextListing, seller = 'CID1', price = price or 9000, description = 'nice', plate = plate, model = 'sultan', mods = '{"color":3}',
        occasionid = 'OC' .. nextListing, vehicle_state = json.encode({ balance = 4000, paymentamount = 500, fuel = 40, engine = 900, drivingdistance = 1200 }) }
    return listings[plate]
end
local function buy(plate)
    later()
    local l = listings[plate]
    Mock.fireNet('qb-occasions:server:buyVehicle', BUYER, { plate = plate, oid = l.occasionid, price = l.price })
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
        FakeDB.players[p.PlayerData.citizenid] = { citizenid = p.PlayerData.citizenid, money = json.encode(p.PlayerData.money) }
    end
    listings, owned, fleet, fleetLookupBroken, fleetOnClaim, failCredit, intercept = {}, {}, {}, false, nil, false, {}
    store.owed, store.held = {}, {}
    PFUsedCars.Start()
end

-- first in the file: the table lookup has not been answered yet (a found table is kept)
describe('the fleet check fails closed', function()
    it('a failed lookup stops a purchase before the buyer pays, and is not cached as "no fleet"', function()
        listCar('FLC002')
        fleet.FLC002 = 5
        fleetLookupBroken = true
        buy('FLC002')
        assert_eq(balance(BUYER), 50000, 'not charged')
        assert_true(listings.FLC002 ~= nil, 'still listed')
        assert_eq(owned.FLC002, nil)
        assert_true(told(BUYER, 'error.lot_unavailable'))
        -- it is asked again (the old code kept "no table" for 5 minutes and sold the fleet car)
        fleetLookupBroken = false
        buy('FLC002')
        assert_eq(balance(BUYER), 50000)
        assert_eq(owned.FLC002, nil)
        assert_true(told(BUYER, 'error.fleet_vehicle'))
    end)
end)

describe('job fleet cars are not sold on the lot', function()
    it('a listing that is an active fleet car is refused before the buyer is charged', function()
        listCar('FLT001')
        fleet.FLT001 = 3
        buy('FLT001')
        assert_eq(balance(BUYER), 50000, 'not charged')
        assert_true(listings.FLT001 ~= nil, 'still listed')
        assert_eq(owned.FLT001, nil)
        assert_true(told(BUYER, 'error.fleet_vehicle'))
    end)

    it('a car put in a fleet in the moment of the sale is not handed over (the claim repeats the check); the buyer is refunded', function()
        listCar('FLT002')
        fleetOnClaim = 'FLT002'
        buy('FLT002')
        assert_true(lastQuery and true)
        assert_true(listings.FLT002 ~= nil, 'the listing was not claimed')
        assert_eq(owned.FLT002, nil, 'no car for the buyer')
        assert_eq(balance(BUYER), 50000, 'refunded')
        assert_eq(balance(SELLER), 1000, 'the seller was not paid')
    end)
end)

describe("the lot's listing callback", function()
    it('sends only what the lot shows: never the seller\'s loan or the car record', function()
        listCar('LST001')
        local rows = Mock.callCallback('qb-occasions:server:getVehicles', BUYER)
        assert_eq(#rows, 1)
        local r = rows[1]
        assert_eq(r.vehicle_state, nil, 'the finance/condition record stays on the server')
        assert_eq(r.id, nil)
        for _, col in ipairs({ 'seller', 'price', 'description', 'plate', 'model', 'mods', 'occasionid' }) do
            assert_true(r[col] ~= nil, col .. ' is what the lot uses')
        end
        for k in pairs(r) do
            assert_true(({ seller = 1, price = 1, description = 1, plate = 1, model = 1, mods = 1, occasionid = 1 })[k] ~= nil, 'unexpected column ' .. k)
        end
    end)
end)

describe('a purchase the bank cannot confirm yet', function()
    it('no car now, the listing held for the buyer; the car is parked for them once the charge completes, the seller paid once', function()
        listCar('HLD001')
        failCredit = true
        buy('HLD001')
        assert_eq(balance(BUYER), 41000, 'the money left the buyer')
        assert_eq(owned.HLD001, nil, 'no car yet')
        assert_eq(listings.HLD001, nil, 'held: nobody else can buy it meanwhile')
        assert_eq(#Mock.clientEventsNamed('qb-occasions:client:BuyFinished'), 0, 'nothing spawned')
        assert_true(told(BUYER, 'info.payment_held'))
        assert_eq(#holds(), 1)
        -- a second purchase while it waits charges nothing
        listCar('HLD002')
        buy('HLD002')
        assert_eq(balance(BUYER), 41000)
        assert_true(told(BUYER, 'error.payment_waiting'))
        PFSettle.Sweep()
        assert_eq(owned.HLD001, nil, 'still waiting')
        settle()
        local car = owned.HLD001
        assert_true(car ~= nil, 'the car is the buyer\'s')
        assert_eq(car.citizenid, 'CID2')
        assert_eq(car.state, 1, 'parked')
        assert_eq(car.garage, Config.DeliveryGarage)
        assert_eq(car.balance, nil, 'never the seller\'s loan')
        assert_eq(car.drivingdistance, 1200, 'its odometer')
        assert_eq(balance(SELLER), 1000 + math.ceil(9000 / 100 * 77))
        assert_true(told(BUYER, 'info.held_delivered'))
        settle()
        assert_eq(balance(SELLER), 1000 + math.ceil(9000 / 100 * 77), 'paid once')
        assert_eq(balance(BUYER), 41000, 'charged once')
    end)

    it('a charge that never reached the ledger puts the car back on the lot after the grace time; nothing taken', function()
        listCar('HLD003')
        intercept['^pfm%-vehiclesales:buy:.*:bank$'] = { ok = false, error = 'ledger_write_failed' }
        buy('HLD003')
        intercept = {}
        assert_eq(listings.HLD003, nil, 'held')
        settle()
        assert_eq(listings.HLD003, nil, 'still too early to tell')
        Mock.clock = Mock.clock + PFSettle.MISSING_GRACE
        PFSettle.Sweep()
        assert_true(listings.HLD003 ~= nil, 'back on the lot')
        assert_eq(listings.HLD003.vehicle_state ~= nil, true, 'with the car record it was listed with')
        assert_eq(owned.HLD003, nil)
        assert_eq(balance(BUYER), 50000)
        assert_true(told(BUYER, 'info.held_cancelled'))
        PFSettle.Sweep()
        assert_eq(count(listings), 1, 'put back once')
    end)

    it('a listing gone before the money arrived: the buyer is refunded once it clears', function()
        listCar('HLD004')
        fleetOnClaim = 'HLD004'   -- the claim fails (a fleet car meanwhile)
        failCredit = true
        buy('HLD004')
        fleetOnClaim = nil
        assert_true(listings.HLD004 ~= nil, 'not claimed')
        assert_eq(balance(BUYER), 41000)
        settle()
        assert_eq(balance(BUYER), 50000, 'refunded')
        assert_eq(owned.HLD004, nil)
        assert_eq(balance(SELLER), 1000)
    end)
end)

describe('owed payments on the lot', function()
    it("a seller's money the bank does not complete is kept and paid by the sweep, once", function()
        listCar('OWE001')
        intercept[':seller$'] = { ok = false, error = 'ledger_write_failed' }
        buy('OWE001')
        assert_true(owned.OWE001 ~= nil, 'the buyer has the car')
        local spawn = Mock.clientEventsNamed('qb-occasions:client:BuyFinished')[1].args[1]
        assert_eq(spawn.plate, 'OWE001')
        assert_eq(spawn.vehicle_state, nil, 'the buyer is not sent the seller\'s loan record')
        assert_eq(balance(SELLER), 1000)
        local o = owedRows()
        assert_eq(#o, 1)
        assert_eq(o[1].to_id, 'CID1')
        intercept = {}
        PFSettle.Sweep()
        assert_eq(balance(SELLER), 1000 + math.ceil(9000 / 100 * 77))
        PFSettle.Sweep()
        assert_eq(balance(SELLER), 1000 + math.ceil(9000 / 100 * 77))
    end)

    it('a sell-back the bank may still pay keeps the car with the lot and pays the seller once', function()
        owned.SBK001 = { citizenid = 'CID1', license = 'license:1', vehicle = 'sultan', plate = 'SBK001', mods = '{}', state = 0, balance = 0, depotprice = 0 }
        Mock.vehicleOf[SELLER] = 701
        Mock.plates[701] = 'SBK001'
        intercept['^pfm%-vehiclesales:sellback:'] = { ok = false, state = 'pending', error = 'pending', txId = 'TXS' }
        later()
        Mock.fireNet('qb-occasions:server:sellVehicleBack', SELLER, {})
        assert_eq(owned.SBK001, nil, 'not given back: the payment may still complete')
        assert_eq(Mock.deleted[#Mock.deleted], 701, 'the sold car leaves the world')
        assert_true(told(SELLER, 'info.sold_back_pending'))
        assert_eq(balance(SELLER), 1000)
        assert_eq(#owedRows(), 1)
        intercept = {}
        PFSettle.Sweep()
        assert_eq(balance(SELLER), 11000)
        PFSettle.Sweep()
        assert_eq(balance(SELLER), 11000, 'once')
    end)

    it('a sell-back the bank clearly did not pay gives the car back', function()
        owned.SBK002 = { citizenid = 'CID1', license = 'license:1', vehicle = 'sultan', plate = 'SBK002', mods = '{}', state = 0, balance = 0, depotprice = 0 }
        Mock.vehicleOf[SELLER] = 702
        Mock.plates[702] = 'SBK002'
        intercept['^pfm%-vehiclesales:sellback:'] = { ok = false, error = 'ledger_write_failed' }
        later()
        Mock.fireNet('qb-occasions:server:sellVehicleBack', SELLER, {})
        assert_true(owned.SBK002 ~= nil, 'restored')
        assert_eq(#owedRows(), 0)
    end)
end)
