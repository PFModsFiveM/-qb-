-- pf-jobs device apps (server/devices.lua): Taxi, Gruppe 6, Garbage and Bus register with pf-devices
-- with the right access, and every RPC reaches the real job code (server/apps/*.lua, captured by
-- server/devices_capture.lua) with the player's own source, after validating its payload.
load_resource('tests/lua/ledger_env.lua')
QBCore = QBCoreMock
QBCoreMock.Shared.Items.moneybag = { name = 'moneybag', label = 'Money Bag', weight = 1000 }
Citizen.SetTimeout = function() return 1 end
Citizen.ClearTimeout = function() end
SetTimeout = function() end

function CreateVehicleServerSetter() Mock.nextNetId = Mock.nextNetId + 1; return Mock.nextNetId end
local trucks = {}
function CreateVehicle() Mock.nextNetId = Mock.nextNetId + 1; trucks[#trucks + 1] = Mock.nextNetId; return Mock.nextNetId end
function SetVehicleNumberPlateText(veh, plate) Mock.plates[veh] = plate end
function SetVehicleDoorsLocked() end
function SetEntityHeading() end
function GetVehicleEngineHealth() return 1000.0 end
function GetVehicleBodyHealth() return 1000.0 end
Mock.exportsByResource['pfm-inventory'] = {
    GetInventory = function() return nil end, CreateInventory = function() end, SetInventory = function() end,
    OpenInventory = function() end, RemoveInventory = function() end,
}

-- installed apps (pf_device_apps) on the fake database
local installs = {}
FakeDB.extraPatterns = {
    { 'SELECT app_id FROM pf_device_apps', function(p)
        local out = {}
        for _, r in ipairs(installs) do if r[1] == p[1] then out[#out + 1] = { app_id = r[2] } end end
        return out
    end },
    { 'INSERT IGNORE INTO pf_device_apps', function(p) installs[#installs + 1] = { p[1], p[2] }; return 1 end },
}

-- pf-devices exports as pf-jobs sees them (the invoking resource is pf-jobs)
Mock.exportsByResource['pf-devices'] = {
    RegisterApp = function(_, def) return PFDevices.RegisterApp(def, 'pf-jobs') end,
    RegisterAppHandlers = function(_, id, map) return PFDevices.RegisterAppHandlers(id, map, 'pf-jobs') end,
}

local mockRegisterNetEvent = RegisterNetEvent
local BUS_STOP = vector3(100.0, 100.0, 30.0)

-- Everything is loaded fresh for each test: the job scripts keep per-player state in locals.
local function loadAll(busEnabled)
    RegisterNetEvent = mockRegisterNetEvent
    PFJobsCapture, PFJobsCallback, PFJobsDevices = nil, nil, nil
    Mock.netHandlers, Mock.netHandlerList, Mock.callbacks, Mock.eventHandlers = {}, {}, {}, {}
    LedgerEnv.load('pf-jobs', {
        '[pfscripts]/pf-jobs/config.lua',
        '[pfscripts]/pf-jobs/server/devices_capture.lua',
        '[pfscripts]/pf-jobs/server/apps/taxi.lua',
        '[pfscripts]/pf-jobs/server/apps/bus.lua',
        '[pfscripts]/pf-jobs/server/apps/garbage.lua',
        '[pfscripts]/pf-jobs/server/apps/gruppe6.lua',
        '[pfscripts]/pf-jobs/server/devices.lua',
    })
    RegisterNetEvent = mockRegisterNetEvent
    Config.Taxi.UseDatabase = false
    Config.Garbage.UseDatabase = false
    Config.Gruppe6.UseDatabase = false
    Config.Gruppe6.MoneyBagsPerLocationMin, Config.Gruppe6.MoneyBagsPerLocationMax = 3, 3
    Config.Bus.Enabled = busEnabled == true
    Config.Bus.UseDatabase = false
    Config.Bus.Routes = { { id = 1, name = 'Downtown Loop', difficulty = 'easy', baseDistance = 2, estimatedTime = 600000,
        stops = { { name = 'Legion', isPickup = true, passengerCount = 4, coords = BUS_STOP } } } }
    Config.Bus.Pricing = { BasePayPerPassenger = 10, PayPerMile = 20, RushHourMultiplier = 1, NightBonus = 1,
        LevelMultiplier = {}, OnTimeBonus = 0, VehicleHealthPenalty = 0, PassengerRatingModifier = {} }
    Config.Bus.Levels = { { level = 1, minRoutes = 0, maxRoutes = 999 } }
    load_resource('[pfscripts]/pf-devices/shared/config.lua')
    Config.Rpc.burst, Config.Rpc.perSecond = 1000, 1000
    load_resource('[pfscripts]/pf-devices/server/registry.lua')
    load_resource('[pfscripts]/pf-devices/server/installs.lua')
    load_resource('[pfscripts]/pf-devices/server/rpc.lua')
    load_resource('[pfscripts]/pf-devices/server/push.lua')
    PFDevices.__resetInstalls()
    assert_true(PFJobsDevices.Register(), 'apps registered')
end

local DRIVER, CITIZEN, GUARD, OTHER, THIRD = 1, 2, 3, 4, 5
local function rpc(src, app, method, payload) return PFDevices.HandleRpc(src, app, method, payload) end
local function install(src, app) assert_eq(PFDevices.InstallApp(src, app).ok, true, 'install ' .. app) end
local function eventsTo(name, src)
    local out = {}
    for _, e in ipairs(Mock.clientEventsNamed(name)) do if e.target == src then out[#out + 1] = e end end
    return out
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players, Mock.coords, installs, trucks = {}, {}, {}, {}
    Mock.clock = Mock.clock + 10000
    loadAll(false)
    Mock.newPlayer(DRIVER).PlayerData.job = { name = 'taxi', grade = { level = 0 }, onduty = true }
    Mock.newPlayer(CITIZEN)
    Mock.newPlayer(GUARD)
    Mock.newPlayer(OTHER)
    Mock.newPlayer(THIRD)
end

describe('pf-jobs device apps: registration', function()
    it('registers taxi for the taxi job and the side jobs as App Store apps, on both devices', function()
        local taxi = PFDevices.GetApp('taxi')
        assert_eq(taxi.resource, 'pf-jobs')
        assert_eq(taxi.category, 'jobs')
        assert_eq(taxi.access.jobs.taxi, 0)
        assert_eq(taxi.access.installable, nil)
        assert_eq(table.concat(taxi.devices, ','), 'computer,tablet')
        assert_eq(taxi.entry, 'html/apps/taxi.js')
        assert_eq(taxi.styles[1], 'html/apps/taxi.css')
        for _, id in ipairs({ 'gruppe6', 'garbage' }) do
            local app = PFDevices.GetApp(id)
            assert_true(app.access.installable, id .. ' is installable')
            assert_eq(app.access.jobs, nil)
            assert_eq(app.store.publisher, 'PF Jobs')
            assert_true(#app.store.description > 0)
            assert_eq(app.category, 'jobs')
            assert_eq(table.concat(app.devices, ','), 'computer,tablet')
        end
        assert_eq(PFDevices.GetApp('bus'), nil, 'the bus job is off in the shipped config')
        assert_true(PFDevices.GetHandler('taxi', 'acceptCall') ~= nil)
        assert_true(PFDevices.GetHandler('gruppe6', 'createGroup') ~= nil)
        -- the taxi app is on the taxi driver's home screen; the side jobs wait in the store
        local view = PFDevices.GetAppsFor(DRIVER, 'tablet')
        assert_eq(#view.apps, 1)
        assert_eq(view.apps[1].id, 'taxi')
        assert_eq(#view.store, 2)
        assert_eq(#PFDevices.GetAppsFor(CITIZEN, 'computer').apps, 0)
    end)

    it('registers the bus once it is enabled, and again when pf-devices restarts', function()
        loadAll(true)
        assert_true(PFDevices.GetApp('bus').access.installable)
        PFDevices.__reset()
        assert_eq(PFDevices.GetApp('taxi'), nil)
        TriggerEvent('pf-devices:server:ready')
        assert_true(PFDevices.GetApp('taxi') ~= nil)
        assert_true(PFDevices.GetApp('bus') ~= nil)
        PFDevices.__reset()
        Mock.fireEvent('onResourceStart', nil, 'pf-jobs')
        assert_true(PFDevices.GetApp('garbage') ~= nil, 'registers on its own start')
    end)
end)

describe('pf-jobs device apps: taxi', function()
    it('a player without the taxi job reaches neither the app nor the raw events', function()
        assert_eq(rpc(CITIZEN, 'taxi', 'getInit').error, 'not_authorized')
        assert_eq(rpc(CITIZEN, 'taxi', 'acceptCall', { id = 'TAXI_1_1000' }).error, 'not_authorized')
        Mock.fireNet('pf-taxi:server:toggleAccepting', CITIZEN, { accepting = true })
        Mock.fireNet('pf-taxi:server:acceptCall', CITIZEN, nil)
        assert_eq(#Mock.clientEventsNamed('pf-taxi:client:rideStarted'), 0)
        Mock.players[CITIZEN].PlayerData.money.cash = 1000
        Mock.fireNet('pf-taxi:server:rentVehicle', CITIZEN, { spawnCode = 'taxi' })
        assert_eq(Mock.players[CITIZEN].PlayerData.money.cash, 1000)
    end)

    it('accepts a call and completes the ride through the real ride code, paying the driver once', function()
        local res = rpc(DRIVER, 'taxi', 'toggleAccepting', { accepting = true })
        assert_eq(res.ok, true)
        assert_eq(res.dashboard.accepting, true)
        local calls = rpc(DRIVER, 'taxi', 'getCalls').calls
        assert_true(#calls > 0, 'calls offered')
        res = rpc(DRIVER, 'taxi', 'acceptCall', { id = calls[1].id })
        assert_eq(res.ok, true)
        local ride = res.dashboard.activeRide
        assert_eq(ride.src, DRIVER)
        assert_eq(#eventsTo('pf-taxi:client:rideStarted', DRIVER), 1)
        assert_eq(rpc(DRIVER, 'taxi', 'acceptCall', { id = calls[1].id }).error, 'refused', 'one ride at a time')
        -- not picked up yet: completing is refused by the ride code
        Mock.coords[DRIVER] = vector3(ride.destination.x, ride.destination.y, ride.destination.z)
        assert_eq(rpc(DRIVER, 'taxi', 'completeRide', { rideId = ride.id }).error, 'refused')
        assert_eq(Mock.players[DRIVER].PlayerData.money.bank, 0)
        -- the world script picks the passenger up and drives to the destination
        Mock.coords[DRIVER] = vector3(ride.pickup.x, ride.pickup.y, ride.pickup.z)
        Mock.fireNet('pf-taxi:server:ridePickedUp', DRIVER, ride.id)
        assert_eq(rpc(DRIVER, 'taxi', 'getInit').dashboard.activeRide.stage, 'destination')
        Mock.coords[DRIVER] = vector3(ride.destination.x, ride.destination.y, ride.destination.z)
        Mock.clock = Mock.clock + 3600
        res = rpc(DRIVER, 'taxi', 'completeRide', { rideId = ride.id })
        assert_eq(res.ok, true)
        assert_eq(res.dashboard.activeRide, nil)
        assert_true(Mock.players[DRIVER].PlayerData.money.bank > 0)
        assert_eq(#LedgerEnv.paid('pf-jobs:taxi:ride:' .. ride.id .. ':'), 1)
        assert_eq(rpc(DRIVER, 'taxi', 'completeRide', { rideId = ride.id }).error, 'no_active_ride')
        assert_eq(#LedgerEnv.paid('pf-jobs:taxi:ride:'), 1)
        assert_eq(source, nil, 'the global source is restored')
    end)

    it('rents and returns a cab through the ledger, and cancels a ride', function()
        Mock.players[DRIVER].PlayerData.money.cash = 1000
        local res = rpc(DRIVER, 'taxi', 'rentVehicle', { spawnCode = 'taxi' })
        assert_eq(res.ok, true)
        assert_true(res.dashboard.rental.plate ~= nil)
        assert_eq(Mock.players[DRIVER].PlayerData.money.cash, 1000 - 420)
        assert_eq(rpc(DRIVER, 'taxi', 'rentVehicle', { spawnCode = 'taxi' }).error, 'rental_active', 'one rental at a time')
        res = rpc(DRIVER, 'taxi', 'returnVehicle')
        assert_eq(res.ok, true)
        assert_eq(Mock.players[DRIVER].PlayerData.money.bank, 300)
        assert_eq(rpc(DRIVER, 'taxi', 'returnVehicle').error, 'no_rental')
        rpc(DRIVER, 'taxi', 'toggleAccepting', { accepting = true })
        local calls = rpc(DRIVER, 'taxi', 'getCalls').calls
        local ride = rpc(DRIVER, 'taxi', 'acceptCall', { id = calls[1].id }).dashboard.activeRide
        assert_eq(rpc(DRIVER, 'taxi', 'cancelRide', { rideId = ride.id }).ok, true)
        assert_eq(#eventsTo('pf-taxi:client:rideCancelled', DRIVER), 1)
        assert_eq(rpc(DRIVER, 'taxi', 'getPhotos').ok, true)
    end)

    it('refuses bad taxi payloads before any job code runs', function()
        assert_eq(rpc(DRIVER, 'taxi', 'toggleAccepting', { accepting = 'yes' }).error, 'bad_request')
        assert_eq(rpc(DRIVER, 'taxi', 'acceptCall', { id = 5 }).error, 'bad_request')
        assert_eq(rpc(DRIVER, 'taxi', 'acceptCall', { id = string.rep('x', 100) }).error, 'bad_request')
        assert_eq(rpc(DRIVER, 'taxi', 'acceptCall', { id = 'a b;c' }).error, 'bad_request')
        assert_eq(rpc(DRIVER, 'taxi', 'completeRide', {}).error, 'bad_request')
        assert_eq(rpc(DRIVER, 'taxi', 'rentVehicle', { spawnCode = { 'taxi' } }).error, 'bad_request')
        assert_eq(rpc(DRIVER, 'taxi', 'cancelRide', { rideId = 12 }).error, 'bad_request')
        assert_eq(#Mock.clientEventsNamed('pf-taxi:client:rideStarted'), 0)
        assert_eq(#Mock.clientEventsNamed('pf-taxi:client:callsData'), 0)
    end)
end)

describe('pf-jobs device apps: gruppe 6', function()
    it('needs the app installed', function()
        assert_eq(rpc(GUARD, 'gruppe6', 'getInit').error, 'not_installed')
        install(GUARD, 'gruppe6')
        local res = rpc(GUARD, 'gruppe6', 'getInit')
        assert_eq(res.ok, true)
        assert_eq(res.playerId, GUARD)
        assert_eq(res.level, 1)
        assert_eq(res.config.levels[2].xp, Config.Gruppe6.LevelThresholds[2])
        assert_eq(res.groups, nil, 'other parties are not sent')
    end)

    it('creates a party, invites by id and joins by invite and by code, each as its own player', function()
        install(GUARD, 'gruppe6'); install(OTHER, 'gruppe6'); install(THIRD, 'gruppe6')
        local res = rpc(GUARD, 'gruppe6', 'createGroup')
        assert_eq(res.ok, true)
        assert_eq(res.view.group.leader, GUARD)
        local code = res.view.group.groupCode
        assert_eq(#code, 6)
        assert_eq(rpc(GUARD, 'gruppe6', 'createGroup').error, nil, 'already leading: the party stays')
        -- an invite reaches the invited player only
        assert_eq(rpc(GUARD, 'gruppe6', 'invitePlayer', { targetId = OTHER }).ok, true)
        local invites = eventsTo('pf-jobs:gruppe6:receiveInvite', OTHER)
        assert_eq(#invites, 1)
        assert_eq(invites[1].args[2], GUARD)
        local other = rpc(OTHER, 'gruppe6', 'getInit')
        assert_eq(other.invites[1].leaderId, GUARD)
        -- accepting without an invite from that leader is refused by the party code
        assert_eq(rpc(THIRD, 'gruppe6', 'acceptInvite', { leaderId = GUARD }).error, 'refused')
        res = rpc(OTHER, 'gruppe6', 'acceptInvite', { leaderId = GUARD })
        assert_eq(res.ok, true)
        assert_eq(res.view.group.leader, GUARD)
        res = rpc(THIRD, 'gruppe6', 'joinByCode', { code = code:lower() })
        assert_eq(res.ok, true)
        assert_eq(#res.view.group.members, 2)
        assert_eq(rpc(OTHER, 'gruppe6', 'kickMember', { targetId = THIRD }).error, 'refused', 'only the leader kicks')
        assert_eq(rpc(GUARD, 'gruppe6', 'kickMember', { targetId = THIRD }).ok, true)
        assert_eq(rpc(OTHER, 'gruppe6', 'leaveGroup').ok, true)
        assert_eq(rpc(GUARD, 'gruppe6', 'disbandGroup').ok, true)
        assert_eq(rpc(GUARD, 'gruppe6', 'refresh').group, nil)
    end)

    it('searches and accepts a contract for the player, shown without coordinates', function()
        install(GUARD, 'gruppe6')
        local res = rpc(GUARD, 'gruppe6', 'startSearch')
        assert_eq(res.ok, true)
        assert_eq(#eventsTo('pf-jobs:gruppe6:contracts', GUARD), 1)
        assert_eq(#eventsTo('pf-jobs:client:updateScoreboard', GUARD), 1)
        res = rpc(GUARD, 'gruppe6', 'acceptContract', { index = 0 })
        assert_eq(res.ok, true)
        assert_eq(#eventsTo('pf-jobs:gruppe6:startContract', GUARD), 1)
        assert_true(res.view.contract.totalBags > 0)
        assert_eq(res.view.contract.locationPool, nil)
        assert_eq(res.view.contract.payoutId, nil)
        assert_eq(rpc(GUARD, 'gruppe6', 'startSearch').error, 'contract_active')
        res = rpc(GUARD, 'gruppe6', 'endContract')
        assert_eq(res.ok, true)
        assert_eq(#eventsTo('pf-jobs:gruppe6:goToDeposit', GUARD), 1)
    end)

    it('refuses bad gruppe 6 payloads', function()
        install(GUARD, 'gruppe6')
        rpc(GUARD, 'gruppe6', 'createGroup')
        Mock.reset()
        assert_eq(rpc(GUARD, 'gruppe6', 'invitePlayer', { targetId = 'abc' }).error, 'bad_request')
        assert_eq(rpc(GUARD, 'gruppe6', 'invitePlayer', { targetId = GUARD }).error, 'bad_request')
        assert_eq(rpc(GUARD, 'gruppe6', 'invitePlayer', { targetId = 2.5 }).error, 'bad_request')
        assert_eq(rpc(GUARD, 'gruppe6', 'joinByCode', { code = '!!' }).error, 'bad_request')
        assert_eq(rpc(GUARD, 'gruppe6', 'joinByCode', { code = string.rep('A', 40) }).error, 'bad_request')
        assert_eq(rpc(GUARD, 'gruppe6', 'acceptContract', { index = -1 }).error, 'bad_request')
        assert_eq(rpc(GUARD, 'gruppe6', 'acceptInvite', {}).error, 'bad_request')
        assert_eq(#Mock.clientEventsNamed('pf-jobs:gruppe6:receiveInvite'), 0)
        assert_eq(#Mock.clientEventsNamed('QBCore:Notify'), 0, 'no job code ran')
    end)
end)

describe('pf-jobs device apps: garbage', function()
    it('starts a run with a truck for the player, one at a time', function()
        install(GUARD, 'garbage')
        local res = rpc(GUARD, 'garbage', 'getInit')
        assert_eq(res.ok, true)
        assert_eq(res.active, false)
        assert_eq(res.config.levels[1].payPerBag, Config.Garbage.PayoutPerBag[1])
        res = rpc(GUARD, 'garbage', 'startJob')
        assert_eq(res.ok, true)
        assert_eq(res.state.active, true)
        assert_eq(#trucks, 1)
        assert_eq(#eventsTo('pf-jobs:garbage:vehicleSpawned', GUARD), 1)
        assert_eq(#eventsTo('pf-jobs:garbage:setActiveZone', GUARD), 1)
        assert_eq(rpc(GUARD, 'garbage', 'startJob').error, 'run_active')
        assert_eq(#trucks, 1)
    end)

    it('runs a crew: create, join by code, invite, leave and disband', function()
        install(GUARD, 'garbage'); install(OTHER, 'garbage'); install(THIRD, 'garbage')
        local res = rpc(GUARD, 'garbage', 'createGroup')
        assert_eq(res.ok, true)
        local code = res.state.currentGroup.groupCode
        res = rpc(OTHER, 'garbage', 'joinByCode', { code = code })
        assert_eq(res.ok, true)
        assert_eq(res.state.currentGroup.leader, GUARD)
        assert_eq(rpc(GUARD, 'garbage', 'invitePlayer', { targetId = THIRD }).ok, true)
        assert_eq(#eventsTo('pf-jobs:garbage:receiveInvite', THIRD), 1)
        assert_eq(rpc(THIRD, 'garbage', 'getInit').pendingInvites[1].leaderId, GUARD)
        assert_eq(rpc(THIRD, 'garbage', 'acceptInvite', { leaderId = GUARD }).ok, true)
        -- a member cannot start the crew's run
        assert_eq(rpc(OTHER, 'garbage', 'startJob').error, 'refused')
        assert_eq(#trucks, 0)
        assert_eq(rpc(THIRD, 'garbage', 'leaveGroup').ok, true)
        assert_eq(rpc(GUARD, 'garbage', 'disbandGroup').ok, true)
        assert_eq(rpc(OTHER, 'garbage', 'getInit').currentGroup, nil)
        assert_eq(rpc(GUARD, 'garbage', 'joinByCode', { code = 'no way' }).error, 'bad_request')
        assert_eq(rpc(GUARD, 'garbage', 'kickMember', { targetId = -3 }).error, 'bad_request')
    end)
end)

describe('pf-jobs device apps: bus', function()
    it('starts and cancels a route as the player, and checks stops in through the bus', function()
        loadAll(true)
        install(DRIVER, 'bus')
        local res = rpc(DRIVER, 'bus', 'getInit')
        assert_eq(res.ok, true)
        assert_eq(res.routes[1].id, 1)
        assert_eq(rpc(DRIVER, 'bus', 'startRoute', { routeId = 'one' }).error, 'bad_request')
        assert_eq(rpc(DRIVER, 'bus', 'checkInStop').error, 'no_route')
        res = rpc(DRIVER, 'bus', 'startRoute', { routeId = 1 })
        assert_eq(res.ok, true)
        assert_eq(res.view.activeRoute.routeId, 1)
        assert_eq(#eventsTo('bus:client:loadRoute', DRIVER), 1)
        assert_eq(rpc(DRIVER, 'bus', 'startRoute', { routeId = 1 }).error, 'route_active')
        assert_eq(rpc(DRIVER, 'bus', 'checkInStop').ok, true)
        assert_eq(#eventsTo('bus:client:completeStop', DRIVER), 1)
        -- the bus checks the stop in (client/bus.lua), the server confirms it to the app
        Mock.coords[DRIVER] = BUS_STOP
        Mock.fireNet('bus:server:completeStop', DRIVER, 1)
        assert_eq(#eventsTo('bus:client:stopCompleted', DRIVER), 1)
        res = rpc(DRIVER, 'bus', 'cancelRoute')
        assert_eq(res.ok, true)
        assert_eq(res.view.activeRoute, nil)
        assert_eq(#eventsTo('bus:client:routeCancelled', DRIVER), 1)
        assert_eq(rpc(DRIVER, 'bus', 'startRoute', { routeId = 99 }).error, 'refused')
    end)
end)

describe('pf-jobs device apps: capture', function()
    it('waits for a callback that answers later, and gives up on one that never answers', function()
        local pending
        PFJobsCallback('test:later', function(src, cb, a) pending = function() cb('later', src, a) end end)
        PFJobsCallback('test:never', function() end)
        promise = { new = function()
            local p = {}
            function p:resolve(v) self.value = v end
            return p
        end }
        Citizen.Await = function(p) if pending then pending(); pending = nil end return p.value end
        local answered, a, b, c = PFJobsCapture.call('test:later', 7, 'x')
        assert_eq(answered, true)
        assert_eq(a, 'later'); assert_eq(b, 7); assert_eq(c, 'x')
        assert_eq((PFJobsCapture.call('test:never', 7)), false)
        promise, Citizen.Await = nil, nil
        assert_eq((PFJobsCapture.call('test:unknown', 7)), false)
    end)

    it('a failing job handler restores the source and reports a server error', function()
        PFJobsCapture.net['pf-taxi:server:toggleAccepting'] = { function() error('boom') end }
        local res = rpc(DRIVER, 'taxi', 'toggleAccepting', { accepting = true })
        assert_eq(res.error, 'server_error')
        assert_eq(source, nil)
    end)
end)
