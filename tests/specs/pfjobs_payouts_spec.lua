-- pf-jobs: taxi and bus pay through the ledger with stable keys, for rides and routes the server saw
-- driven; taxi rentals are charged through it and the deposit refund is paid once.
load_resource('tests/lua/ledger_env.lua')
-- count handlers per event: FiveM runs all of them, the mock keeps only the last
local handlerCount = {}
local mockRegister = RegisterNetEvent
RegisterNetEvent = function(name, fn)
    if fn then handlerCount[name] = (handlerCount[name] or 0) + 1 end
    return mockRegister(name, fn)
end
QBCore = QBCoreMock -- bus.lua uses the global set by pf-jobs/server/main.lua
function CreateVehicleServerSetter() Mock.nextNetId = Mock.nextNetId + 1; return Mock.nextNetId end
function SetVehicleNumberPlateText() end
function SetVehicleDoorsLocked() end
function GetVehicleEngineHealth() return 1000.0 end
function GetVehicleBodyHealth() return 1000.0 end

LedgerEnv.load('pf-jobs', {
    '[pfscripts]/pf-jobs/config.lua',
    '[pfscripts]/pf-jobs/server/apps/taxi.lua',
    '[pfscripts]/pf-jobs/server/apps/bus.lua',
})
RegisterNetEvent = mockRegister
Config.Taxi.UseDatabase = false
Config.Bus.UseDatabase = false

local DRIVER = 1
local bankUp = true
function GetResourceState(name) if name == 'pfm-banking' and not bankUp then return 'stopped' end return 'started' end

local function money(kind) return Mock.players[DRIVER].PlayerData.money[kind] end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    bankUp = true
    Mock.players = {}
    Mock.newPlayer(DRIVER).PlayerData.job = { name = 'taxi', onduty = true }
    Mock.clock = Mock.clock + 10000
    Mock.coords = {}
    Mock.fireNet('pf-taxi:server:cancelRide', DRIVER)
end

local function at(p) Mock.coords[DRIVER] = vector3(p.x, p.y, p.z) end

local function startRide()
    Mock.fireNet('pf-taxi:server:toggleAccepting', DRIVER, { accepting = true })
    Mock.fireNet('pf-taxi:server:acceptCall', DRIVER, nil)
    local started = Mock.clientEventsNamed('pf-taxi:client:rideStarted')
    assert_true(#started > 0, 'ride started')
    return started[#started].args[1], started[#started].args[2]
end

-- drives the passenger from the pickup to the destination
local function driveRide(ride)
    at(ride.pickup)
    Mock.fireNet('pf-taxi:server:ridePickedUp', DRIVER, ride.id)
    at(ride.destination)
    Mock.clock = Mock.clock + 3600
end

describe('taxi fare', function()
    it('there is one rental handler (a second one used to charge every rental again)', function()
        assert_eq(handlerCount['pf-taxi:server:rentVehicle'], 1)
        assert_eq(Mock.netHandlers['pf-taxi:server:startRide'], nil)
    end)
    it('a ride not driven pays nothing: no pickup, or not at the destination', function()
        local rideId, ride = startRide()
        at(ride.destination)
        Mock.fireNet('pf-taxi:server:completeRide', DRIVER, rideId, { distanceMiles = 50.0 })   -- never picked up
        assert_eq(money('bank'), 0)
        at(ride.pickup)
        Mock.fireNet('pf-taxi:server:ridePickedUp', DRIVER, rideId)
        Mock.clock = Mock.clock + 3600
        Mock.fireNet('pf-taxi:server:completeRide', DRIVER, rideId, { distanceMiles = 50.0 })   -- still at the pickup
        assert_eq(money('bank'), 0)
    end)
    it('the fare uses the server distance, not the client one', function()
        local rideId, ride = startRide()
        driveRide(ride)
        Mock.fireNet('pf-taxi:server:completeRide', DRIVER, rideId, { distanceMiles = 500.0, collisions = -5 })
        local paid = money('bank')
        assert_true(paid > 0)
        -- the most this ride can pay at level 1 with no collisions
        local cap = math.max(50, math.floor(ride.distanceMiles * 60 * (ride.premium and 1.5 or 1) * (ride.playerClient and 2 or 1)))
        assert_true(paid <= cap, ('fare %d is within the server cap %d'):format(paid, cap))
    end)
    it('a completed ride is paid once through the ledger', function()
        local rideId, ride = startRide()
        driveRide(ride)
        Mock.fireNet('pf-taxi:server:completeRide', DRIVER, rideId, { distanceMiles = 1.0 })
        local paid = money('bank')
        assert_true(paid > 0)
        Mock.fireNet('pf-taxi:server:completeRide', DRIVER, rideId, { distanceMiles = 1.0 })
        assert_eq(money('bank'), paid)
        assert_eq(#LedgerEnv.paid('pf-jobs:taxi:ride:' .. rideId .. ':'), 1)
    end)
    it('bank down keeps the ride so completing again pays', function()
        local rideId, ride = startRide()
        driveRide(ride)
        bankUp = false
        Mock.fireNet('pf-taxi:server:completeRide', DRIVER, rideId, { distanceMiles = 1.0 })
        assert_eq(money('bank'), 0)
        bankUp = true
        Mock.fireNet('pf-taxi:server:completeRide', DRIVER, rideId, { distanceMiles = 1.0 })
        assert_true(money('bank') > 0)
        assert_eq(#LedgerEnv.paid('pf-jobs:taxi:ride:'), 1)
    end)
end)

describe('taxi rental', function()
    it('rental is charged through the ledger and the deposit refunded once', function()
        Mock.players[DRIVER].PlayerData.money.cash = 1000
        Mock.fireNet('pf-taxi:server:rentVehicle', DRIVER, { spawnCode = 'taxi' })
        assert_eq(money('cash'), 1000 - 420)
        assert_eq(#LedgerEnv.paid('pf-jobs:taxi:rental:'), 1)
        Mock.fireNet('pf-taxi:server:returnVehicle', DRIVER)
        assert_eq(money('bank'), 300)
        Mock.fireNet('pf-taxi:server:returnVehicle', DRIVER)
        assert_eq(money('bank'), 300)
    end)
    it('the depot return key refunds through the same path', function()
        Mock.players[DRIVER].PlayerData.money.cash = 1000
        Mock.fireNet('pf-taxi:server:rentVehicle', DRIVER, { spawnCode = 'taxi' })
        Mock.fireNet('pf-taxi:server:returnRentalVehicle', DRIVER)
        assert_eq(money('bank'), 300)
        assert_eq(money('cash'), 1000 - 420)
    end)
    it('bank down at return keeps the rental so returning again refunds', function()
        Mock.players[DRIVER].PlayerData.money.cash = 1000
        Mock.fireNet('pf-taxi:server:rentVehicle', DRIVER, { spawnCode = 'taxi' })
        bankUp = false
        Mock.fireNet('pf-taxi:server:returnVehicle', DRIVER)
        assert_eq(money('bank'), 0)
        bankUp = true
        Mock.fireNet('pf-taxi:server:returnVehicle', DRIVER)
        assert_eq(money('bank'), 300)
    end)
    it('not enough money charges nothing', function()
        Mock.players[DRIVER].PlayerData.money.cash = 100
        Mock.fireNet('pf-taxi:server:rentVehicle', DRIVER, { spawnCode = 'taxi' })
        assert_eq(money('cash'), 100)
        assert_eq(#LedgerEnv.paid('pf-jobs:taxi:rental:'), 0)
    end)
end)

describe('bus route', function()
    it('a route pays once; bank down leaves it open for a retry', function()
        -- the shipped config has bus disabled with no routes; give it one
        Config.Bus.Enabled = true
        local STOP = vector3(100.0, 100.0, 30.0)
        Config.Bus.Routes = { { id = 1, baseDistance = 2, estimatedTime = 600000, stops = { { isPickup = true, passengerCount = 4, coords = STOP } } } }
        Config.Bus.Pricing = { BasePayPerPassenger = 10, PayPerMile = 20, RushHourMultiplier = 1, NightBonus = 1,
            LevelMultiplier = {}, OnTimeBonus = 0, VehicleHealthPenalty = 0, PassengerRatingModifier = {} }
        local routeId = 1
        Mock.fireNet('bus:server:startRoute', DRIVER, routeId)
        Mock.fireNet('bus:server:completeRoute', DRIVER, { isOnTime = true })   -- no stop visited
        assert_eq(money('cash'), 0)
        Mock.coords[DRIVER] = vector3(500.0, 500.0, 30.0)
        Mock.fireNet('bus:server:completeStop', DRIVER, 1)                        -- far from the stop
        Mock.coords[DRIVER] = STOP
        Mock.clock = Mock.clock + 30
        Mock.fireNet('bus:server:completeRoute', DRIVER, { isOnTime = true })
        assert_eq(money('cash'), 0)
        Mock.fireNet('bus:server:completeStop', DRIVER, 1)
        Mock.fireNet('bus:server:completeRoute', DRIVER, { isOnTime = true })   -- too soon for 2 miles
        assert_eq(money('cash'), 0)
        Mock.clock = Mock.clock + 600
        bankUp = false
        Mock.fireNet('bus:server:completeRoute', DRIVER, { isOnTime = true })
        assert_eq(money('cash'), 0)
        bankUp = true
        Mock.fireNet('bus:server:completeRoute', DRIVER, { isOnTime = true })
        local paid = money('cash')
        assert_true(paid > 0)
        Mock.fireNet('bus:server:completeRoute', DRIVER, { isOnTime = true })
        assert_eq(money('cash'), paid)
        assert_eq(#LedgerEnv.paid('pf-jobs:bus:'), 1)
    end)
end)
