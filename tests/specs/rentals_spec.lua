-- pf-rentals: the server prices the rental and charges it through the ledger; only the rented car can
-- be spawned, once.
load_resource('tests/lua/ledger_env.lua')
local spawned = {}
function IsModelInCdimage() return true end
function IsModelAVehicle() return true end
function CreateVehicleServerSetter(hash) spawned[#spawned + 1] = hash return 5000 + #spawned end
function DoesEntityExist() return true end
function SetVehicleOnGroundProperly() end
function SetVehicleEngineHealth() end
function SetVehicleBodyHealth() end
function SetVehicleDirtLevel() end
function SetVehicleEngineOn() end
function NetworkGetNetworkIdFromEntity(e) return e end
function GetVehicleNumberPlateText() return 'RENT001' end
Mock.exportsByResource['oxmysql'] = { execute = function() end }
RegisterCommand = RegisterCommand or function() end

LedgerEnv.load('pf-rentals', { '[pfscripts]/pf-rentals/config.lua', '[pfscripts]/pf-rentals/server/integration.lua' })
Config.Debug = false
Config.UseQBVehicleKeys = false

local P = 1
local DESK = Config.RentalLocations[1].coords
local CAR = Config.RentalVehicles[1]   -- id 1
local function money() return Mock.players[P].PlayerData.money end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players, Mock.coords = {}, {}
    spawned = {}
    Mock.newPlayer(P).PlayerData.money = { cash = 0, bank = 10000 }
    Mock.coords[P] = DESK
end

describe('renting', function()
    it('charges the configured price times the days, whatever the client says', function()
        Mock.fireNet('pf-rentals:confirmRental', P, { vehicleId = CAR.id, duration = 3, totalPrice = 1 })
        assert_eq(money().bank, 10000 - CAR.price * 3)
        assert_eq(#LedgerEnv.paid('pf-rentals:'), 1)
    end)
    it('refuses bad durations, unknown cars and renting away from a desk', function()
        Mock.fireNet('pf-rentals:confirmRental', P, { vehicleId = CAR.id, duration = 0 })
        Mock.fireNet('pf-rentals:confirmRental', P, { vehicleId = 999, duration = 1 })
        Mock.coords[P] = vector3(0, 0, 0)
        Mock.fireNet('pf-rentals:confirmRental', P, { vehicleId = CAR.id, duration = 1 })
        assert_eq(money().bank, 10000)
    end)
end)

describe('spawning a rental', function()
    local point = { x = DESK.x + 3, y = DESK.y, z = DESK.z, w = 0.0 }
    it('spawns only the rented car, once', function()
        Mock.fireNet('pf-rentals:spawnVehicle', P, 'rhino', point, {})          -- nothing rented
        assert_eq(#spawned, 0)
        Mock.fireNet('pf-rentals:confirmRental', P, { vehicleId = CAR.id, duration = 1 })
        Mock.fireNet('pf-rentals:spawnVehicle', P, 'rhino', point, {})          -- not the rented model
        assert_eq(#spawned, 0)
        Mock.fireNet('pf-rentals:spawnVehicle', P, CAR.model, point, {})
        Mock.fireNet('pf-rentals:spawnVehicle', P, CAR.model, point, {})
        assert_eq(#spawned, 1)
    end)
    it('not far from the renter', function()
        Mock.fireNet('pf-rentals:confirmRental', P, { vehicleId = CAR.id, duration = 1 })
        Mock.fireNet('pf-rentals:spawnVehicle', P, CAR.model, { x = 0, y = 0, z = 0, w = 0 }, {})
        assert_eq(#spawned, 0)
    end)
end)
