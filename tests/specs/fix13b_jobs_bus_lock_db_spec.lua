-- pf-jobs bus (server/apps/bus.lua), 'bus:server:spawnBus' with Config.Bus.UseDatabase on: the
-- first wait of a spawn request is the driver's stats read (MySQL.single.await in getPlayerStats).
-- The per-player lock must be taken before that read, not after it: a second request that arrives
-- while the first one waits on the database is refused at once, without reading the stats or
-- bringing out a bus of its own. (fix9hq2_jobs_bus_spawn_lock_spec runs without the database, where
-- only the wait for the spawned entity yields, so a lock taken after the read passed it too.)
load_resource('tests/lua/ledger_env.lua')
QBCore = QBCoreMock

local spawned = {}
function CreateVehicleServerSetter(hash, _, x, y, z)
    Mock.nextNetId = Mock.nextNetId + 1
    spawned[#spawned + 1] = { id = Mock.nextNetId, hash = hash }
    Mock.models[Mock.nextNetId] = hash
    Mock.coords[Mock.nextNetId] = vector3(x, y, z)
    return Mock.nextNetId
end
function DoesEntityExist() return true end
function Wait() end
function SetVehicleNumberPlateText(veh, plate) Mock.plates[veh] = plate end
function SetVehicleDoorsLocked() end

LedgerEnv.load('pf-jobs', { '[pfscripts]/pf-jobs/config.lua', '[pfscripts]/pf-jobs/server/apps/bus.lua' })
local B = Config.Bus
B.Pricing.RushHourMultiplier, B.Pricing.NightBonus = 1.0, 1.0

-- the stats read waits on the database: it yields until the spec lets it answer
local statReads, row
local function yieldingSingle()
    return { await = function(query, params)
        if query:find('FROM bus_stats', 1, true) then
            statReads[#statReads + 1] = params and params[1]
            if coroutine.isyieldable() then coroutine.yield('db') end
            return row
        end
        return nil
    end }
end

local D = 1
local function atDepot(src) Mock.coords[src] = vector3(B.Depot.coords.x, B.Depot.coords.y, B.Depot.coords.z) end

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
local function toldBusy(src)
    for _, e in ipairs(Mock.clientEventsNamed('QBCore:Notify')) do
        if e.target == src and e.args[1] == 'Your bus is already being brought out' then return true end
    end
    return false
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players, Mock.coords, Mock.vehicleOf, Mock.models, Mock.deleted = {}, {}, {}, {}, {}
    spawned, statReads, row = {}, {}, { routes_completed = 0, total_passengers = 0, total_earnings = 0, total_time = 0 }
    B.UseDatabase = true
    MySQL.single = yieldingSingle()
    Mock.newPlayer(D).PlayerData.job = { name = 'unemployed', onduty = true }
    Mock.fireEvent('playerDropped', D)
    PFJobsBus.ForgetCitizen('CID1') -- no cached stats: the next request reads them
    atDepot(D)
end

describe('bus: the spawn lock with the stats read on the database', function()
    it('a second request while the first waits on the stats read is refused at once', function()
        local first = request(D)
        assert_eq(coroutine.status(first), 'suspended', 'the first request waits on the database')
        assert_eq(#statReads, 1)
        assert_eq(#spawned, 0, 'no bus yet')
        local second = request(D)
        assert_eq(coroutine.status(second), 'dead', 'the second request ended without waiting')
        assert_true(toldBusy(D), 'and was told why')
        assert_eq(#statReads, 1, 'it never read the stats (the lock comes before the first wait)')
        finish(first)
        assert_eq(#spawned, 1, 'one bus')
        assert_true(PFJobsBus.View(D).bus ~= nil, 'and it is the tracked one')
    end)

    it('the lock is released after the stats read and the spawn: the next request goes through', function()
        finish(request(D))
        assert_eq(#spawned, 1)
        Mock.fireNet('bus:server:returnBus', D)
        finish(request(D))
        assert_eq(#spawned, 2)
    end)

    it('a driver who leaves during the stats read brings out no bus', function()
        local co = request(D)
        Mock.fireEvent('playerDropped', D)
        finish(co)
        assert_eq(#spawned, 0)
        assert_eq(PFJobsBus.View(D).bus, nil)
    end)

    it('another driver is not held up by this one\'s database wait', function()
        local E = 2
        Mock.newPlayer(E).PlayerData.job = { name = 'unemployed', onduty = true }
        atDepot(E)
        local a = request(D)
        local b = request(E)
        assert_eq(#statReads, 2, 'both read their own stats')
        finish(a)
        finish(b)
        assert_eq(#spawned, 2)
    end)
end)
