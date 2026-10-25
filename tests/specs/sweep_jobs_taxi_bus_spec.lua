-- pf-jobs taxi photos and bus: photo rows are rate-limited and cut to their columns, the bus table
-- setup is not a client event, and no bus is handed out while the bus job is disabled.
load_resource('tests/lua/ledger_env.lua')
QBCore = QBCoreMock
local busesSpawned = 0
function CreateVehicleServerSetter() busesSpawned = busesSpawned + 1; Mock.nextNetId = Mock.nextNetId + 1; return Mock.nextNetId end
function SetVehicleNumberPlateText() end
function SetVehicleDoorsLocked() end

LedgerEnv.load('pf-jobs', {
    '[pfscripts]/pf-jobs/config.lua',
    '[pfscripts]/pf-jobs/server/apps/taxi.lua',
    '[pfscripts]/pf-jobs/server/apps/bus.lua',
})

-- the oxmysql Async API the taxi photos use, on the fake database
MySQL.Async = {
    execute = function(q, p, cb) local r = MySQL.query.await(q, p); if cb then cb(r) end end,
    insert = function(q, p, cb) local r = MySQL.insert.await(q, p); if cb then cb(r) end end,
}

local photos = {}
FakeDB.extraPatterns = {
    { 'CREATE TABLE IF NOT EXISTS taxi_vehicle_photos', function() return 0 end },
    { 'INSERT INTO taxi_vehicle_photos', function(p) photos[#photos + 1] = p; return #photos end },
}

local D = 1
BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players, photos, busesSpawned = {}, {}, 0
    Mock.newPlayer(D).PlayerData.job = { name = 'taxi', onduty = true }
    Mock.fireEvent('playerDropped', D)
    Config.Taxi.UseDatabase = true
    Config.Bus.Enabled = false
end

describe('pf-jobs taxi photos and bus', function()
    it('photo rows: one per few seconds, fields cut to the column sizes, junk ignored', function()
        Mock.fireNet('pf-taxi:server:capturePhoto', D, 'junk')
        Mock.gameTimer = Mock.gameTimer + 10000
        Mock.fireNet('pf-taxi:server:capturePhoto', D, { filename = string.rep('f', 1000), model = 'taxi', plate = string.rep('P', 100) })
        for _ = 1, 10 do Mock.fireNet('pf-taxi:server:capturePhoto', D, { filename = 'x.png' }) end
        assert_eq(#photos, 1)
        assert_eq(#photos[1][2], 255)
        assert_eq(#photos[1][4], 20)
        Mock.gameTimer = Mock.gameTimer + 10000
        Mock.fireNet('pf-taxi:server:capturePhoto', D, { filename = 'y.png' })
        assert_eq(#photos, 2)
    end)

    it('bus tables are set up by the server only, and no bus is handed out while the job is off', function()
        assert_eq(Mock.netHandlers['bus:server:createTables'], nil)
        Mock.fireNet('bus:server:spawnBus', D, 'bus')
        assert_eq(busesSpawned, 0)
    end)
end)
