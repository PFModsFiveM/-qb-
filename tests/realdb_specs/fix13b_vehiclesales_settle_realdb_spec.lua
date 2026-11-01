-- pfm-vehiclesales (used lot) on the real database and the real ledger: the lot's listing callback
-- selects only the columns the lot shows; a car put in a job fleet in the moment of a purchase is not
-- handed over (the claim's NOT EXISTS) and the buyer is refunded; a purchase whose charge the bank
-- could not confirm holds the listing in pfm_vehiclesales_held and, once the ledger's recovery
-- completes the charge, the car is written parked for the buyer with its condition but no loan and the
-- seller is paid once; a charge that never reached the ledger puts the listing back as it was.
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
RealDB.exec('pfm-vehiclesales/qb-vehiclesales.sql')

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

local failCredit = false
local realUpdate = MySQL.update
MySQL.update = setmetatable({ await = function(q, p)
    if failCredit and q == PFLedger.SQL.setState and p[1] == 'completed' and p[4] == 'debited' then
        failCredit = false
        error('injected: the credit write failed')
    end
    return realUpdate.await(q, p)
end }, { __call = function(_, ...) return realUpdate(...) end })
-- runs in the moment the buyer's claim on a listing executes
local onClaim = nil
-- the claim's query fails once: 'before' it ran, or 'after' it ran (its answer lost)
local claimFails = nil
local realQuery = MySQL.query
MySQL.query = setmetatable({ await = function(q, p)
    if q:find('DELETE FROM occasion_vehicles WHERE plate = ? AND occasionid = ? AND price = ?', 1, true) then
        if onClaim then local f = onClaim onClaim = nil f() end
        if claimFails then
            local how = claimFails
            claimFails = nil
            if how == 'after' then realQuery.await(q, p) end
            error('injected: database connection lost')
        end
    end
    return realQuery.await(q, p)
end }, { __call = function(_, ...) return realQuery(...) end })
-- replies the bank gives for given keys instead of running the transfer
local bank = Mock.exportsByResource['pfm-banking']
local realTransfer = bank.Transfer
local intercept = {}
bank.Transfer = function(opts)
    for pattern, reply in pairs(intercept) do if opts.key:find(pattern) then return reply end end
    return realTransfer(opts)
end
Mock.rawExports[bank.Transfer] = true

local SELLER, BUYER = 1, 2
local LOT = vector3(Config.Zones.SandyOccasions.BuyVehicle.x, Config.Zones.SandyOccasions.BuyVehicle.y, Config.Zones.SandyOccasions.BuyVehicle.z)
local runNo = 0
local sellerCid, buyerCid
local SHARE = math.ceil((9000 / 100) * 77)
local function balance(src) return Mock.players[src].PlayerData.money.bank end
local function later() Mock.gameTimer = Mock.gameTimer + 10000 end
local function listing(plate) return MySQL.single.await('SELECT * FROM occasion_vehicles WHERE plate = ?', { plate }) end
local function owned(plate) return MySQL.single.await('SELECT * FROM player_vehicles WHERE plate = ?', { plate }) end
local function list(plate)
    MySQL.insert.await([[INSERT INTO occasion_vehicles (seller, price, description, plate, model, mods, occasionid, vehicle_state)
        VALUES (?, 9000, 'nice', ?, 'sultan', '{"color":3}', ?, ?)]],
        { sellerCid, plate, 'OC' .. plate, json.encode({ balance = 4000, paymentamount = 500, paymentsleft = 8, fuel = 37, engine = 640.5, drivingdistance = 5000 }) })
    return listing(plate)
end
local function buy(plate)
    later()
    local l = listing(plate)
    Mock.fireNet('qb-occasions:server:buyVehicle', BUYER, { plate = plate, oid = l.occasionid, price = tonumber(l.price) })
end
local function ageLedger() MySQL.update.await("UPDATE pf_transactions SET updated_at = NOW() - INTERVAL 10 MINUTE WHERE state IN ('pending', 'debited')") end
local function settle() ageLedger() PFLedger.Recover() PFSettle.Sweep() end
local function completed(pattern) return tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_transactions WHERE idempotency_key LIKE ? AND state = 'completed'", { pattern })) or 0 end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords = {}, {}
    Mock.vehicleOf, Mock.plates, Mock.deleted = {}, {}, {}
    later()
    runNo = runNo + 1
    sellerCid, buyerCid = 'USSELL' .. runNo, 'USBUY' .. runNo
    local seller = Mock.newPlayer(SELLER, sellerCid)
    seller.PlayerData.money = { cash = 0, bank = 1000 }
    seller.PlayerData.license = 'license:1'
    local buyer = Mock.newPlayer(BUYER, buyerCid)
    buyer.PlayerData.money = { cash = 0, bank = 50000 }
    buyer.PlayerData.license = 'license:2'
    for src in pairs(Mock.players) do Mock.players[src].PlayerData.source = src Mock.coords[src] = LOT end
    MySQL.query.await('DELETE FROM occasion_vehicles')
    failCredit, onClaim, intercept, claimFails = false, nil, {}, nil
end

describe("the lot's listing callback on the database", function()
    it('selects only the columns the lot shows, in listing order', function()
        list('USC' .. runNo .. 'A')
        list('USC' .. runNo .. 'B')
        local rows = Mock.callCallback('qb-occasions:server:getVehicles', BUYER)
        assert_eq(#rows, 2)
        assert_eq(rows[1].plate, 'USC' .. runNo .. 'A')
        assert_eq(rows[1].vehicle_state, nil, 'the seller\'s loan stays on the server')
        assert_eq(rows[1].id, nil)
        assert_eq(rows[1].occasionid, 'OCUSC' .. runNo .. 'A')
        assert_eq(rows[1].seller, sellerCid)
    end)
end)

describe('a fleet car is not sold on the database', function()
    it('a car put in a fleet in the moment of the claim stays listed; the buyer is refunded, the seller not paid', function()
        local plate = 'USF' .. runNo
        list(plate)
        onClaim = function()
            MySQL.insert.await("INSERT INTO job_garage_vehicles (garage_id, plate, model, label, min_grade, active, assignment_type) VALUES ('mech', ?, 'sultan', 'x', 0, 1, 'none')", { plate })
        end
        buy(plate)
        assert_true(listing(plate) ~= nil, 'not claimed')
        assert_eq(owned(plate), nil)
        assert_eq(balance(BUYER), 50000, 'refunded')
        assert_eq(balance(SELLER), 1000)
    end)
end)

describe('a purchase the bank cannot confirm yet, on the database', function()
    it('the listing is held; when the charge completes the car is parked for the buyer and the seller paid once', function()
        local plate = 'USH' .. runNo
        list(plate)
        failCredit = true
        buy(plate)
        assert_eq(balance(BUYER), 41000)
        assert_eq(listing(plate), nil, 'held off the lot')
        assert_eq(owned(plate), nil, 'no car yet')
        local hold = MySQL.single.await('SELECT * FROM pfm_vehiclesales_held WHERE plate = ?', { plate })
        assert_true(hold ~= nil)
        assert_eq(hold.state, 'waiting')
        assert_eq(hold.accounts, 'bank')
        assert_true(json.decode(hold.data).claimed)
        settle()
        local car = owned(plate)
        assert_true(car ~= nil, 'the car is written')
        assert_eq(car.citizenid, buyerCid)
        assert_eq(tonumber(car.state), 1)
        assert_eq(car.garage, Config.DeliveryGarage)
        assert_eq(tonumber(car.balance), 0, 'never the seller\'s loan')
        assert_eq(tonumber(car.drivingdistance), 5000, 'its odometer')
        assert_eq(tonumber(car.engine), 640.5, 'its condition')
        assert_eq(balance(SELLER), 1000 + SHARE)
        assert_eq(MySQL.scalar.await('SELECT state FROM pfm_vehiclesales_held WHERE id = ?', { hold.id }), 'done')
        settle()
        assert_eq(balance(SELLER), 1000 + SHARE, 'paid once')
        assert_eq(balance(BUYER), 41000, 'charged once')
        assert_eq(tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM player_vehicles WHERE plate = ?', { plate })), 1)
    end)

    it('a charge that never reached the ledger puts the listing back, with its record, after the grace time', function()
        local plate = 'USN' .. runNo
        local before = list(plate)
        intercept[':bank$'] = { ok = false, error = 'ledger_write_failed' }
        buy(plate)
        intercept = {}
        assert_eq(listing(plate), nil)
        PFSettle.Sweep()
        assert_eq(listing(plate), nil, 'too early to tell')
        Mock.clock = Mock.clock + PFSettle.MISSING_GRACE + 1
        PFSettle.Sweep()
        local back = listing(plate)
        assert_true(back ~= nil, 'back on the lot')
        assert_eq(back.occasionid, before.occasionid)
        assert_eq(back.vehicle_state, before.vehicle_state, 'with the record it was listed with')
        assert_eq(balance(BUYER), 50000)
        assert_eq(owned(plate), nil)
        PFSettle.Sweep()
        assert_eq(tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM occasion_vehicles WHERE plate = ?', { plate })), 1, 'put back once')
    end)
end)

describe('owed payments of the lot on the database', function()
    it("a seller's money the bank does not complete is stored and paid by the sweep, once", function()
        local plate = 'USO' .. runNo
        list(plate)
        intercept[':seller$'] = { ok = false, error = 'ledger_write_failed' }
        buy(plate)
        intercept = {}
        assert_true(owned(plate) ~= nil)
        assert_eq(balance(SELLER), 1000)
        local row = MySQL.single.await("SELECT * FROM pfm_vehiclesales_owed WHERE ledger_key LIKE ?", { 'pfm-vehiclesales:buy:OC' .. plate .. ':%:seller' })
        assert_true(row ~= nil)
        assert_eq(row.state, 'open')
        PFSettle.Sweep()
        assert_eq(balance(SELLER), 1000 + SHARE)
        PFSettle.Sweep()
        assert_eq(balance(SELLER), 1000 + SHARE)
        assert_eq(completed('pfm-vehiclesales:buy:OC' .. plate .. ':%:seller%'), 1)
    end)
end)

describe('a claim query that fails after the charge, on the database', function()
    local function hold(plate) return MySQL.single.await('SELECT * FROM pfm_vehiclesales_held WHERE plate = ?', { plate }) end

    it('an unclear charge, then the claim fails before it ran: held as unknown, claimed and delivered when the charge completes', function()
        local plate = 'USX' .. runNo
        list(plate)
        failCredit = true
        claimFails = 'before'
        buy(plate)
        assert_eq(balance(BUYER), 41000)
        local h = hold(plate)
        assert_true(h ~= nil, 'held (the old code aborted: no hold, no refund)')
        assert_eq(json.decode(h.data).claimed, nil, 'unknown')
        assert_true(listing(plate) ~= nil)
        settle()
        assert_eq(listing(plate), nil)
        assert_eq(owned(plate).citizenid, buyerCid)
        assert_eq(balance(SELLER), 1000 + SHARE)
        assert_eq(json.decode(hold(plate).data).claimed, true, 'the answer is stored')
        settle()
        assert_eq(balance(SELLER), 1000 + SHARE, 'paid once')
        assert_eq(balance(BUYER), 41000, 'charged once')
    end)

    it('a paid purchase whose claim ran but whose answer was lost: found claimed and delivered by the sweep', function()
        local plate = 'USY' .. runNo
        list(plate)
        claimFails = 'after'
        buy(plate)
        assert_eq(balance(BUYER), 41000)
        assert_eq(listing(plate), nil)
        assert_eq(owned(plate), nil, 'no car yet')
        assert_eq(hold(plate).state, 'waiting')
        PFSettle.Sweep()
        assert_eq(owned(plate).citizenid, buyerCid)
        assert_eq(tonumber(owned(plate).state), 1, 'parked')
        assert_eq(balance(SELLER), 1000 + SHARE)
        assert_eq(hold(plate).state, 'done')
        PFSettle.Sweep()
        assert_eq(balance(BUYER), 41000)
        assert_eq(balance(SELLER), 1000 + SHARE)
    end)

    it('another waiting purchase of the car recorded the claim: this buyer is refunded, nothing delivered', function()
        local plate = 'USZ' .. runNo
        list(plate)
        claimFails = 'after'
        buy(plate)
        local mine = hold(plate)
        -- an older held purchase of the same car that recorded its claim
        MySQL.insert.await([[INSERT INTO pfm_vehiclesales_held (id, flow, charge_key, accounts, citizenid, plate, amount, data, state, created)
            VALUES (?, 'usedlot', ?, 'bank', 'USOTHER', ?, 1, ?, 'waiting', ?)]], { mine.id - 100000, 'other:' .. plate, plate, json.encode({ claimed = true }), os.time() })
        PFSettle.Sweep()
        assert_eq(owned(plate), nil)
        assert_eq(balance(BUYER), 50000, 'refunded')
        assert_eq(balance(SELLER), 1000)
        MySQL.query.await('DELETE FROM pfm_vehiclesales_held WHERE charge_key = ?', { 'other:' .. plate })
        assert_eq(json.decode(MySQL.single.await('SELECT data FROM pfm_vehiclesales_held WHERE id = ?', { mine.id }).data).claimed, false, 'the answer is stored')
    end)
end)
