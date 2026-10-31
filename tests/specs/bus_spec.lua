-- pf-jobs bus (server/apps/bus.lua), which replaced pfm-busjob: the shipped routes are real (every
-- stop found, stops a real drive apart, depot to depot), NPC passengers board only the driver's bus
-- and pay when they reach their stop, a route pays once on the ledger, stops must be driven, routes
-- and buses follow the driver's level, and buses come from the depot.
load_resource('tests/lua/ledger_env.lua')
QBCore = QBCoreMock
local spawned = {}
function CreateVehicleServerSetter(hash, _, x, y, z, w)
    Mock.nextNetId = Mock.nextNetId + 1
    spawned[#spawned + 1] = { id = Mock.nextNetId, hash = hash }
    Mock.models[Mock.nextNetId] = hash
    Mock.coords[Mock.nextNetId] = vector3(x, y, z)
    return Mock.nextNetId
end
function SetVehicleNumberPlateText(veh, plate) Mock.plates[veh] = plate end
function SetVehicleDoorsLocked() end
local health = 1000.0
function GetVehicleEngineHealth() return health end
function GetVehicleBodyHealth() return health end

LedgerEnv.load('pf-jobs', { '[pfscripts]/pf-jobs/config.lua', '[pfscripts]/pf-jobs/server/apps/bus.lua' })
Config.Bus.UseDatabase = false
-- time of day must not change the expected fares
Config.Bus.Pricing.RushHourMultiplier, Config.Bus.Pricing.NightBonus = 1.0, 1.0

local D = 1
local B = Config.Bus
local function cash() return Mock.players[D].PlayerData.money.cash end
local function at(c) Mock.coords[D] = vector3(c.x, c.y, c.z) end
local function lastStop() local e = Mock.clientEventsNamed('bus:client:stopCompleted'); return e[#e] end
local function routeById(id) for _, r in ipairs(PFJobsBus.Routes()) do if r.id == id then return r end end end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.clock = Mock.clock + 100000
    Mock.players, Mock.coords, Mock.vehicleOf, Mock.models, spawned = {}, {}, {}, {}, {}
    health = 1000.0
    Mock.newPlayer(D).PlayerData.job = { name = 'unemployed', onduty = true }
    Mock.fireEvent('playerDropped', D) -- clears routes and buses from the previous test
    PFJobsBus.ForgetCitizen('CID1')
end

-- takes a depot bus and sits the driver in it
local function takeBus(model)
    at(B.Depot.coords)
    Mock.fireNet('bus:server:spawnBus', D, model or 'bus')
    local bus = spawned[#spawned].id
    Mock.vehicleOf[D] = bus
    return bus
end

-- drives the route: at each stop (bus and driver), after a drive of 2 minutes
local function drive(route, opts)
    opts = opts or {}
    for i, stop in ipairs(route.stops) do
        Mock.clock = Mock.clock + 120
        at(stop.coords)
        if opts.bus then Mock.coords[opts.bus] = stop.coords end
        Mock.fireNet('bus:server:completeStop', D, i)
    end
end

describe('bus routes in config', function()
    it('every route expands, runs depot to depot, and its stops are a real drive apart', function()
        local list = PFJobsBus.Routes()
        assert_eq(#list, #B.Routes, 'no route skipped for an unknown stop')
        assert_true(#list >= 8)
        local depot = B.Depot.coords
        for _, r in ipairs(list) do
            assert_true(#r.stops >= 6, r.name .. ' has stops')
            assert_true(r.baseDistance > 0 and r.estimatedTime > 0, r.name .. ' distance and time')
            assert_true(#(r.stops[1].coords - depot) < 1 and #(r.stops[#r.stops].coords - depot) < 1, r.name .. ' starts and ends at the depot')
            for i = 2, #r.stops do
                assert_true(#(r.stops[i].coords - r.stops[i - 1].coords) >= 100, ('%s stop %d is a drive from the last'):format(r.name, i))
            end
            -- the route can be driven within its distance at the bus speed limit
            local straight = 0
            for i = 2, #r.stops do straight = straight + #(r.stops[i].coords - r.stops[i - 1].coords) end
            assert_true(r.baseDistance * 1609.34 >= straight, r.name .. ' distance is at least the straight line')
        end
        -- pfm-busjob's five stops are all used
        local used = {}
        for _, r in ipairs(list) do for _, s in ipairs(r.stops) do used[s.name] = true end end
        for _, name in ipairs({ 'Strawberry Avenue', 'Forum Drive', 'Ginger Street', 'San Andreas Avenue', 'Vespucci Boulevard' }) do
            assert_true(used[name], name .. ' is on a route')
        end
    end)

    it('harder routes need a higher level', function()
        local view = PFJobsBus.View(D)
        for _, r in ipairs(view.routes) do assert_eq(r.difficulty, 'easy') end
        assert_true(#view.lockedRoutes > 0)
        Mock.fireNet('bus:server:startRoute', D, 7) -- hard
        assert_eq(PFJobsBus.View(D).activeRoute, nil)
        assert_eq(PFJobsBus.GetLevel(30), 3)
    end)
end)

describe('bus passengers and pay', function()
    it('a route driven in the depot bus carries passengers to their stops and pays once', function()
        local bus = takeBus()
        local route = routeById(1)
        Mock.fireNet('bus:server:startRoute', D, 1)
        drive(route, { bus = bus })
        local view = PFJobsBus.View(D).activeRoute
        assert_eq(view.currentStop, #route.stops + 1)
        assert_eq(view.onBoard, 0, 'everyone gets off at the end')
        local boarded, delivered = view.passengersPickedUp, view.passengersDelivered
        assert_true(boarded > 0, 'passengers boarded')
        assert_eq(delivered, boarded)
        assert_eq(lastStop().args[3].inBus, true)
        Mock.fireNet('bus:server:completeRoute', D)
        local paid = cash()
        -- 8 stops x 2 min is later than the 7 min timetable: no on-time bonus; full health
        local base = math.floor(delivered * B.Pricing.BasePayPerPassenger + route.baseDistance * B.Pricing.PayPerMile)
        assert_true(paid > 0)
        assert_true(paid <= math.floor(base * 1.10) and paid >= math.floor(base * 0.9), ('fare %d near base %d'):format(paid, base))
        Mock.fireNet('bus:server:completeRoute', D)
        assert_eq(cash(), paid)
        assert_eq(#LedgerEnv.paid('pf-jobs:bus:'), 1)
        local stats = PFJobsBus.View(D).stats
        assert_eq(stats.routesCompleted, 1)
        assert_eq(stats.totalPassengers, delivered)
    end)

    it('with MileageNeedsBus off, stops checked in without the bus take no passengers: only the mileage is paid', function()
        local route = routeById(1)
        B.MileageNeedsBus = false
        Mock.fireNet('bus:server:startRoute', D, 1)
        drive(route)
        local view = PFJobsBus.View(D).activeRoute
        assert_eq(view.passengersPickedUp, 0)
        assert_eq(lastStop().args[3].inBus, false)
        Mock.fireNet('bus:server:completeRoute', D)
        B.MileageNeedsBus = true
        assert_true(cash() > 0)
        assert_true(cash() <= math.floor(route.baseDistance * B.Pricing.PayPerMile * 1.15) + 1)
    end)

    it('by default (MileageNeedsBus) a route checked in without the bus pays nothing', function()
        assert_true(B.MileageNeedsBus, 'the shipped default')
        Mock.fireNet('bus:server:startRoute', D, 1)
        drive(routeById(1))
        Mock.fireNet('bus:server:completeRoute', D)
        assert_eq(cash(), 0)
        assert_eq(#LedgerEnv.paid('pf-jobs:bus:'), 0)
    end)

    it('a bus that is not the driver\'s depot bus does not count', function()
        takeBus()
        Mock.vehicleOf[D] = 9999 -- another bus
        Mock.models[9999] = GetHashKey('bus')
        local route = routeById(1)
        Mock.fireNet('bus:server:startRoute', D, 1)
        drive(route)
        assert_eq(PFJobsBus.View(D).activeRoute.passengersPickedUp, 0)
    end)

    it('stops count in order, at the stop, and only after a real drive from the last one', function()
        local route = routeById(1)
        Mock.fireNet('bus:server:startRoute', D, 1)
        at(route.stops[2].coords)
        Mock.fireNet('bus:server:completeStop', D, 2) -- out of order
        assert_eq(PFJobsBus.View(D).activeRoute.currentStop, 1)
        at(route.stops[1].coords)
        Mock.fireNet('bus:server:completeStop', D, 1)
        at(route.stops[2].coords)
        Mock.fireNet('bus:server:completeStop', D, 2) -- no time to drive there
        assert_eq(PFJobsBus.View(D).activeRoute.currentStop, 2)
        Mock.clock = Mock.clock + 60
        Mock.coords[D] = vector3(route.stops[2].coords.x + 200, route.stops[2].coords.y, route.stops[2].coords.z)
        Mock.fireNet('bus:server:completeStop', D, 2) -- not at the stop
        assert_eq(PFJobsBus.View(D).activeRoute.currentStop, 2)
        at(route.stops[2].coords)
        Mock.fireNet('bus:server:completeStop', D, 2)
        assert_eq(PFJobsBus.View(D).activeRoute.currentStop, 3)
        Mock.fireNet('bus:server:completeRoute', D)
        assert_eq(#LedgerEnv.paid('pf-jobs:bus:'), 0, 'not every stop visited')
    end)

    it('a battered bus loses part of the fare and stars', function()
        local bus = takeBus()
        local route = routeById(1)
        Mock.fireNet('bus:server:startRoute', D, 1)
        health = 400.0
        drive(route, { bus = bus })
        Mock.fireNet('bus:server:completeRoute', D)
        local view = PFJobsBus.View(D)
        assert_true(view.stats.averageRating < 4.0, 'rating from the server')
        local delivered = math.max(1, view.stats.totalPassengers)
        local base = math.floor(delivered * B.Pricing.BasePayPerPassenger + route.baseDistance * B.Pricing.PayPerMile)
        assert_true(cash() < base, 'damage lowered the fare')
    end)
end)

describe('depot buses', function()
    it('are handed out at the depot only, one at a time, by level, and returned there', function()
        Mock.coords[D] = vector3(0, 0, 0)
        Mock.fireNet('bus:server:spawnBus', D, 'bus')
        assert_eq(#spawned, 0, 'away from the depot')
        at(B.Depot.coords)
        Mock.fireNet('bus:server:spawnBus', D, 'coach')
        assert_eq(#spawned, 0, 'the coach needs level 3')
        Mock.fireNet('bus:server:spawnBus', D, 'rhino')
        assert_eq(#spawned, 1, 'an unknown model falls back to the city bus')
        assert_eq(spawned[1].hash, GetHashKey('bus'))
        Mock.fireNet('bus:server:spawnBus', D, 'bus')
        assert_eq(#spawned, 1, 'one bus at a time')
        local view = PFJobsBus.View(D)
        assert_eq(view.bus.model, 'bus')
        assert_eq(view.bus.capacity, 15)
        -- the bus is away: it cannot be returned
        Mock.coords[spawned[1].id] = vector3(0, 0, 0)
        Mock.fireNet('bus:server:returnBus', D)
        assert_true(PFJobsBus.View(D).bus ~= nil)
        Mock.coords[spawned[1].id] = B.Depot.coords
        Mock.fireNet('bus:server:returnBus', D)
        assert_eq(PFJobsBus.View(D).bus, nil)
        assert_eq(Mock.deleted[#Mock.deleted], spawned[1].id)
    end)

    it('a configured bus job is required when set', function()
        B.Job = 'bus'
        at(B.Depot.coords)
        Mock.fireNet('bus:server:spawnBus', D, 'bus')
        Mock.fireNet('bus:server:startRoute', D, 1)
        assert_eq(#spawned, 0)
        assert_eq(PFJobsBus.View(D).activeRoute, nil)
        Mock.players[D].PlayerData.job = { name = 'bus', onduty = true }
        Mock.fireNet('bus:server:startRoute', D, 1)
        assert_true(PFJobsBus.View(D).activeRoute ~= nil)
        B.Job = nil
    end)
end)
