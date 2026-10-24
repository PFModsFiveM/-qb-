-- pf-mechanicjob roadside service: the server starts each call for one car and pays once, only when
-- the server itself reads that car as repaired, with the mechanic beside it after the minimum time.
-- Also: the old client-built invoice handlers are gone.
load_resource('tests/lua/ledger_env.lua')
FakeDB.extraPatterns = {
    { 'UPDATE pf_mechanic_progress SET xp', function() return 1 end },
}
local health = {}  -- [vehicle] = { engine, body }
function GetVehicleEngineHealth(v) return (health[v] or {}).engine or 0.0 end
function GetVehicleBodyHealth(v) return (health[v] or {}).body or 0.0 end
function GetVehicleNumberPlateText() return 'RDSIDE01' end
local gone = {}
function DoesEntityExist(e) return not gone[e] end

LedgerEnv.load('pf-mechanicjob', { '[pfscripts]/pf-mechanicjob/config.lua' })
Config.AdvancedSystems.Enabled = true
Config.AdvancedSystems.RoadsideService.Enabled = true
load_resource('[pfscripts]/pf-mechanicjob/server/advanced_systems.lua')

local MECH, CIV, CAR = 1, 2, 500
local CAR_AT = vector3(200.0, 200.0, 30.0)
local function bank(src) return Mock.players[src].PlayerData.money.bank end
local function start(src) Mock.fireNet('pf-mechanicjob:server:advanced:startRoadside', src, CAR) end
local function complete(src) Mock.fireNet('pf-mechanicjob:server:advanced:completeRoadside', src, { plate = 'ANYPLATE' }) end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.clock = Mock.clock + 10000
    Mock.players, Mock.coords, health, gone = {}, {}, {}, {}
    Mock.newPlayer(MECH).PlayerData.job = { name = 'mechanic', onduty = true }
    Mock.newPlayer(CIV).PlayerData.job = { name = 'unemployed', onduty = false }
    Mock.coords[MECH], Mock.coords[CIV], Mock.coords[CAR] = CAR_AT, CAR_AT, CAR_AT
    health[CAR] = { engine = 250.0, body = 450.0 }
    Mock.fireEvent('playerDropped', MECH)
end

describe('roadside service', function()
    it('a completion the server never started pays nothing', function()
        complete(MECH)
        assert_eq(bank(MECH), 0)
    end)
    it('only mechanics can start a call', function()
        start(CIV)
        health[CAR] = { engine = 1000.0, body = 1000.0 }
        Mock.clock = Mock.clock + 60
        complete(CIV)
        assert_eq(bank(CIV), 0)
    end)
    it('pays once, after the repair, by the car, and not too soon', function()
        start(MECH)
        Mock.clock = Mock.clock + 60
        complete(MECH)                                        -- the server still reads it as broken
        assert_eq(bank(MECH), 0)
        health[CAR] = { engine = 1000.0, body = 1000.0 }
        Mock.coords[MECH] = vector3(400.0, 400.0, 30.0)
        complete(MECH)                                        -- not beside the car
        assert_eq(bank(MECH), 0)
        Mock.coords[MECH] = CAR_AT
        complete(MECH)
        local paid = bank(MECH)
        assert_true(paid > 0)
        complete(MECH)
        assert_eq(bank(MECH), paid)
        assert_eq(#LedgerEnv.paid('pf-mechanicjob:roadside:'), 1)
    end)
    it('a repair reported before the minimum time is paid once the time has passed', function()
        start(MECH)
        health[CAR] = { engine = 1000.0, body = 1000.0 }
        complete(MECH)
        assert_eq(bank(MECH), 0)
        Mock.clock = Mock.clock + 60
        complete(MECH)
        assert_true(bank(MECH) > 0)
    end)
    it('calls have a cooldown', function()
        start(MECH)
        health[CAR] = { engine = 1000.0, body = 1000.0 }
        Mock.clock = Mock.clock + 60
        complete(MECH)
        local paid = bank(MECH)
        health[CAR] = { engine = 250.0, body = 450.0 }
        start(MECH)                                           -- straight away: refused
        health[CAR] = { engine = 1000.0, body = 1000.0 }
        Mock.clock = Mock.clock + 60
        complete(MECH)
        assert_eq(bank(MECH), paid)
    end)
end)

describe('mechanic invoices', function()
    it('the client-built invoice handlers no longer exist', function()
        -- server/main.lua is too large to load here, so check its source
        local src = __readfile('[pfscripts]/pf-mechanicjob/server/main.lua')
        assert_eq(src:find("RegisterNetEvent('pos:customerPay'", 1, true), nil)
        assert_eq(src:find("RegisterNetEvent('pos:requestCharge'", 1, true), nil)
    end)
end)
