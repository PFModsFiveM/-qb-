-- Batch 14 (JOBS-2): the passenger's rating of a taxi ride is decided by the server (a random
-- 4.0-5.0 start, less per collision and per damage the server saw on the car, more or less by the
-- ride time against the expected drive). The rating the client sends is ignored; it used to be a
-- client-side random number a modified client could set to 5.0 to dodge the low-rating wait penalty.
load_resource('tests/lua/ledger_env.lua')
QBCore = QBCoreMock
function CreateVehicleServerSetter() Mock.nextNetId = Mock.nextNetId + 1; return Mock.nextNetId end
function SetVehicleNumberPlateText() end
function SetVehicleDoorsLocked() end
function GetVehicleEngineHealth() return 1000.0 end
local body = {}
function GetVehicleBodyHealth(veh) return body[veh] or 1000.0 end

LedgerEnv.load('pf-jobs', { '[pfscripts]/pf-jobs/config.lua', '[pfscripts]/pf-jobs/server/apps/taxi.lua' })
Config.Taxi.UseDatabase = false

local DRIVER, CAR = 1, 777

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players, Mock.coords, Mock.vehicleOf, body = {}, {}, {}, {}
    Mock.newPlayer(DRIVER).PlayerData.job = { name = 'taxi', onduty = true }
    Mock.clock = Mock.clock + 10000
    Mock.fireEvent('playerDropped', DRIVER) -- a fresh profile (average 5.0) and session per test
    Mock.vehicleOf[DRIVER] = CAR
end

local function at(p) Mock.coords[DRIVER] = vector3(p.x, p.y, p.z) end
local function startRide()
    Mock.fireNet('pf-taxi:server:toggleAccepting', DRIVER, { accepting = true })
    Mock.fireNet('pf-taxi:server:acceptCall', DRIVER, nil)
    local started = Mock.clientEventsNamed('pf-taxi:client:rideStarted')
    return started[#started].args[1], started[#started].args[2]
end
-- the drive time the server expects for this ride (the default 15 m/s)
local function expected(ride) return math.max(15, (tonumber(ride.distanceMiles) or 0) * 1609.34 / 15.0) end
local function drive(ride, seconds)
    at(ride.pickup)
    Mock.fireNet('pf-taxi:server:ridePickedUp', DRIVER, ride.id)
    at(ride.destination)
    Mock.clock = Mock.clock + math.ceil(seconds)
end
local function lastRating()
    local done = Mock.clientEventsNamed('pf-taxi:client:rideCompleted')
    return done[#done] and done[#done].args[1].rating
end
local function average()
    local stats = Mock.clientEventsNamed('pf-taxi:client:updateStats')
    return stats[#stats].args[1].rating
end

describe('fix14 taxi: the ride rating is the server\'s', function()
    it('a client rating of 5 with collisions recorded still lowers the stored rating', function()
        local rideId, ride = startRide()
        for _ = 1, 5 do Mock.fireNet('pf-taxi:server:recordCollision', DRIVER, rideId, {}) end
        drive(ride, expected(ride))
        Mock.fireNet('pf-taxi:server:completeRide', DRIVER, rideId, { rating = 5.0, collisions = 0 })
        local r = lastRating()
        assert_true(r ~= nil, 'the ride completed')
        assert_true(r <= 4.1, ('five collisions: at most 5.0 - 1.0 + 0.1, got %s'):format(tostring(r)))
        assert_true(average() < 5.0, 'the stored average went down')
    end)

    it('damage the server saw on the car lowers the rating with no collision reported', function()
        local rideId, ride = startRide()
        drive(ride, expected(ride))
        body[CAR] = 800.0 -- five hits' worth of body damage since the pickup
        Mock.fireNet('pf-taxi:server:completeRide', DRIVER, rideId, { rating = 5.0 })
        assert_true(lastRating() <= 4.1, ('got %s'):format(tostring(lastRating())))
    end)

    it('a clean, prompt ride rates well whatever the client sends', function()
        local rideId, ride = startRide()
        drive(ride, expected(ride))
        Mock.fireNet('pf-taxi:server:completeRide', DRIVER, rideId, { rating = 0.0 })
        local r = lastRating()
        assert_true(r >= 4.3 and r <= 5.0, ('a clean prompt ride: 4.0-5.0 + 0.3 + 0.1, got %s'):format(tostring(r)))
    end)

    it('a ride that takes far longer than the drive needs rates lower', function()
        local rideId, ride = startRide()
        drive(ride, expected(ride) * 3 + 5)
        Mock.fireNet('pf-taxi:server:completeRide', DRIVER, rideId, { rating = 5.0 })
        local r = lastRating()
        assert_true(r <= 4.3, ('a very slow clean ride: at most 5.0 + 0.3 - 1.0, got %s'):format(tostring(r)))
    end)
end)
