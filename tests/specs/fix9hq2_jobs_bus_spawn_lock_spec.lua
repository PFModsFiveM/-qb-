-- pf-jobs bus (server/apps/bus.lua), 'bus:server:spawnBus': the driver's stats read (MySQL) and the
-- wait for the spawned entity yield on a server, so two requests sent at once both passed the
-- "already have a bus out" check and each brought out a bus. Only the second was tracked: the
-- first was never cleaned up, and passengers did not board it (the route paid nothing for them).
-- A per-player lock is now held from before the first yield until the request ends, on every path.
load_resource('tests/lua/ledger_env.lua')
QBCore = QBCoreMock

-- A freshly created vehicle exists only after a server tick (Wait), and Wait yields when the
-- handler runs in a coroutine, so a second request can arrive in between (as on a server).
local spawned, pendingEntity = {}, {}
function CreateVehicleServerSetter(hash, _, x, y, z, w)
    Mock.nextNetId = Mock.nextNetId + 1
    spawned[#spawned + 1] = { id = Mock.nextNetId, hash = hash }
    Mock.models[Mock.nextNetId] = hash
    Mock.coords[Mock.nextNetId] = vector3(x, y, z)
    pendingEntity[Mock.nextNetId] = true
    return Mock.nextNetId
end
function DoesEntityExist(e) return not pendingEntity[e] end
function Wait()
    for e in pairs(pendingEntity) do pendingEntity[e] = nil end
    if coroutine.isyieldable() then coroutine.yield('tick') end
end
function SetVehicleNumberPlateText(veh, plate) Mock.plates[veh] = plate end
function SetVehicleDoorsLocked() end

LedgerEnv.load('pf-jobs', { '[pfscripts]/pf-jobs/config.lua', '[pfscripts]/pf-jobs/server/apps/bus.lua' })
local B = Config.Bus
B.UseDatabase = false
B.Pricing.RushHourMultiplier, B.Pricing.NightBonus = 1.0, 1.0

local D = 1
local function at(c) Mock.coords[D] = vector3(c.x, c.y, c.z) end

-- starts a spawn request in a coroutine: it runs up to its first yield
local function request(src, model)
    local handler = Mock.netHandlers['bus:server:spawnBus']
    local co = coroutine.create(function()
        source = src
        handler(model or 'bus')
    end)
    local ok, err = coroutine.resume(co)
    assert(ok, err)
    source = nil
    return co
end
local function finish(co)
    while coroutine.status(co) == 'suspended' do
        local ok, err = coroutine.resume(co)
        assert(ok, err)
    end
end
local function deletedHas(id)
    for _, e in ipairs(Mock.deleted) do if e == id then return true end end
    return false
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players, Mock.coords, Mock.vehicleOf, Mock.models, Mock.deleted = {}, {}, {}, {}, {}
    spawned, pendingEntity = {}, {}
    Mock.newPlayer(D).PlayerData.job = { name = 'unemployed', onduty = true }
    Mock.fireEvent('playerDropped', D)
    PFJobsBus.ForgetCitizen('CID1')
    Mock.deleted = {}
    at(B.Depot.coords)
end

describe('bus: two spawn requests at once', function()
    it('bring out one bus, and that bus is the tracked one', function()
        local first = request(D)
        assert_eq(#spawned, 1, 'the first request is waiting for its bus')
        local second = request(D)
        finish(first)
        finish(second)
        assert_eq(#spawned, 1, 'only one bus brought out')
        local view = PFJobsBus.View(D)
        assert_true(view.bus ~= nil, 'the bus is tracked')
        assert_eq(view.bus.plate, Mock.plates[spawned[1].id])
        assert_eq(#Mock.clientEventsNamed('bus:client:vehicleSpawned'), 1)
        local told = false
        for _, e in ipairs(Mock.clientEventsNamed('QBCore:Notify')) do
            if e.target == D and e.args[1] == 'Your bus is already being brought out' then told = true end
        end
        assert_true(told, 'the second request is told why')
    end)

    it('a request that fails with an error does not keep the lock', function()
        local real = CreateVehicleServerSetter
        CreateVehicleServerSetter = function() error('spawn native failed') end
        local co = coroutine.create(function()
            source = D
            Mock.netHandlers['bus:server:spawnBus']('bus')
        end)
        local ok, err = coroutine.resume(co)
        source = nil
        CreateVehicleServerSetter = real
        assert_false(ok, 'the error still reaches the server log')
        assert_true(tostring(err):find('spawn native failed', 1, true) ~= nil)
        finish(request(D))
        assert_eq(#spawned, 1, 'the next request brings a bus out')
        assert_true(PFJobsBus.View(D).bus ~= nil)
    end)

    it('the lock is released: after returning the bus another can be taken', function()
        finish(request(D))
        assert_eq(#spawned, 1)
        Mock.fireNet('bus:server:returnBus', D)
        assert_eq(PFJobsBus.View(D).bus, nil)
        finish(request(D))
        assert_eq(#spawned, 2, 'a second bus after the first went back')
        assert_true(PFJobsBus.View(D).bus ~= nil)
    end)

    it('a refused request (away from the depot) does not keep the lock', function()
        Mock.coords[D] = vector3(0, 0, 0)
        finish(request(D))
        assert_eq(#spawned, 0)
        at(B.Depot.coords)
        finish(request(D))
        assert_eq(#spawned, 1)
    end)

    it('a driver who leaves while the bus comes out leaves no bus behind', function()
        local co = request(D)
        assert_eq(#spawned, 1)
        Mock.fireEvent('playerDropped', D)
        finish(co)
        assert_true(deletedHas(spawned[1].id), 'the bus is deleted')
        assert_eq(PFJobsBus.View(D).bus, nil, 'and not tracked')
    end)

    it('different drivers are not held up by each other', function()
        local E = 2
        Mock.newPlayer(E).PlayerData.job = { name = 'unemployed', onduty = true }
        Mock.coords[E] = vector3(B.Depot.coords.x, B.Depot.coords.y, B.Depot.coords.z)
        local a = request(D)
        local b = request(E)
        finish(a)
        finish(b)
        assert_eq(#spawned, 2)
    end)
end)
