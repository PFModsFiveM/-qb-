-- pfm-vehiclekeys on the real database: keys a client asks for go to the car's owner in
-- player_vehicles, and to the employee a pf-jobgarages fleet car (a manager's own car) is signed
-- out to (until restart, not saved on the character); never to another player, a fleet car not
-- signed out, or one signed out to someone else. Without the job_garage_vehicles table (pf-jobgarages
-- not installed) the fleet rule simply gives nothing.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
function GetResourceState() return 'missing' end
local timers = {}
function SetTimeout(ms, fn) timers[#timers + 1] = { ms = ms, fn = fn } end
function GetEntityType() return 2 end
function IsPedAPlayer(ped) return Mock.players[ped] ~= nil end
local locks = {}
function SetVehicleDoorsLocked(veh, state) locks[#locks + 1] = { veh = veh, state = state } end

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-garages/player_vehicles.sql')

Config = nil
load_resource('pfm-vehiclekeys/config.lua')
load_resource('pfm-vehiclekeys/server/main.lua')

local MANAGER, EMPLOYEE, OTHER = 1, 2, 3
local CAR = 60

local function car(plate, citizenid)
    MySQL.insert.await("INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, garage, state) VALUES ('license:1', ?, 'flatbed', '1', '{}', ?, 'pillboxgarage', 0)", { citizenid, plate })
end
local function signOut(plate, citizenid, out)
    MySQL.insert.await("INSERT INTO job_garage_vehicles (garage_id, plate, model, label, min_grade, active, `out`, out_citizenid) VALUES ('mechanic_main', ?, 'flatbed', 'Truck', 0, 1, ?, ?)", { plate, out and 1 or 0, citizenid })
end
local function acquire(src, arg)
    Mock.gameTimer = Mock.gameTimer + 10000
    Mock.fireNet('qb-vehiclekeys:server:AcquireVehicleKeys', src, arg)
end
local function keys(src, plate) return HasKeys(src, plate) == true end
local function persisted(src, plate) return Mock.players[src].PlayerData.metadata.vehicleKeys[plate] == true end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords, Mock.vehicleOf, Mock.plates = {}, {}, {}, {}
    locks = {}
    for _, src in ipairs({ MANAGER, EMPLOYEE, OTHER }) do
        Mock.newPlayer(src).PlayerData.metadata.vehicleKeys = {}
        Mock.coords[src] = vector3(0, 0, 0)
    end
    Mock.coords[CAR] = vector3(2, 0, 0)
end

describe('before pf-jobgarages is installed', function()
    it('the owner gets keys; nobody gets a fleet car (the fleet table is missing)', function()
        car('NOFLEET1', 'CID' .. MANAGER)
        acquire(MANAGER, 'NOFLEET1')
        assert_true(keys(MANAGER, 'NOFLEET1'))
        assert_true(persisted(MANAGER, 'NOFLEET1'), "the owner's keys are kept")
        acquire(EMPLOYEE, 'NOFLEET1')
        assert_false(keys(EMPLOYEE, 'NOFLEET1'))
    end)
end)

describe('with pf-jobgarages', function()
    it('a fleet car signed out to the employee gives them keys until restart, by plate or by the car', function()
        RealDB.exec('[pfscripts]/pf-jobgarages/sql/pf_jobgarages.sql')
        car('FLEET001', 'CID' .. MANAGER)
        signOut('FLEET001', 'CID' .. EMPLOYEE, true)
        acquire(EMPLOYEE, 'FLEET001')
        assert_false(keys(EMPLOYEE, 'FLEET001'), '"no table" is remembered for a while')
        -- ... and asked again later (pf-jobgarages installed meanwhile)
        assert_true(#timers >= 1 and timers[1].ms >= 60000)
        for _, t in ipairs(timers) do t.fn() end
        timers = {}
        acquire(EMPLOYEE, 'FLEET001')
        assert_true(keys(EMPLOYEE, 'FLEET001'))
        assert_false(persisted(EMPLOYEE, 'FLEET001'), "not saved on the employee's character")

        RemoveKeys(EMPLOYEE, 'FLEET001')
        Mock.plates[CAR] = 'FLEET001'
        acquire(EMPLOYEE, CAR)
        assert_true(keys(EMPLOYEE, 'FLEET001'), 'from the car itself')
    end)
    it('not to another player, nor for a fleet car not out or out to someone else', function()
        car('FLEET002', 'CID' .. MANAGER)
        signOut('FLEET002', 'CID' .. EMPLOYEE, false)
        acquire(EMPLOYEE, 'FLEET002')
        assert_false(keys(EMPLOYEE, 'FLEET002'), 'parked in the fleet')
        car('FLEET003', 'CID' .. MANAGER)
        signOut('FLEET003', 'CID' .. EMPLOYEE, true)
        acquire(OTHER, 'FLEET003')
        assert_false(keys(OTHER, 'FLEET003'), 'out to someone else')
        Mock.vehicleOf[OTHER] = CAR
        Mock.plates[CAR] = 'FLEET003'
        acquire(OTHER, CAR)
        assert_false(keys(OTHER, 'FLEET003'), 'even at its wheel')
    end)
    it('the employee may lock and unlock the signed-out car without keys; another player may not', function()
        car('FLEET004', 'CID' .. MANAGER)
        signOut('FLEET004', 'CID' .. EMPLOYEE, true)
        Mock.plates[CAR] = 'FLEET004'
        Mock.fireNet('qb-vehiclekeys:server:setVehLockState', OTHER, CAR, 1)
        assert_eq(#locks, 0)
        Mock.fireNet('qb-vehiclekeys:server:setVehLockState', EMPLOYEE, CAR, 1)
        assert_eq(#locks, 1)
    end)
end)
