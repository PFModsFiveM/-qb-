-- pfm-core vehicle spawns: only job garage models (on duty) or server-granted tickets, near the
-- player, rate limited. The callbacks used to spawn any model anywhere for any client.
load_resource('tests/lua/fivem_mocks.lua')
QBCore = QBCoreMock
QBCoreMock.Shared.Vehicles = { adder = { name = 'Adder' }, blista = { name = 'Blista' } }
Spawned = {}
function CreateVehicle(model) Spawned[#Spawned + 1] = model; return 900 + #Spawned end
function CreateAutomobile() return 0 end
function TaskWarpPedIntoVehicle() end
function NetworkGetEntityOwner(e) return 1 end
QBCoreMock.Functions.SpawnVehicle = function(src, model) return CreateVehicle(model) end
QBCoreMock.Functions.CreateAutomobile = function(src, model) return CreateVehicle(model) end
load_resource('pfm-core/server/vehicle_spawns.lua')
load_resource('pfm-core/server/events.lua')

local P = 1
local HERE = vector3(100.0, 100.0, 30.0)
local function spawn(model, coords) return Mock.callCallback('QBCore:Server:SpawnVehicle', P, model, coords or HERE, true) end

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 100
    Mock.players, Mock.coords, Spawned = {}, { [P] = HERE }, {}
    Mock.newPlayer(P).PlayerData.job = { name = 'taxi', onduty = true }
    PFVehicleSpawns.jobs, PFVehicleSpawns.tickets, PFVehicleSpawns.last = {}, {}, {}
    PFVehicleSpawns.RegisterJobVehicles('taxi', { 'taxi' })
end

describe('vehicle spawns', function()
    it('an arbitrary model is refused', function()
        assert_eq(spawn('adder'), nil)
        assert_eq(#Spawned, 0)
    end)
    it("the job's own garage model spawns while on duty, not off duty", function()
        assert_true(spawn('taxi') ~= nil)
        Mock.clock = Mock.clock + 10
        Mock.players[P].PlayerData.job.onduty = false
        assert_eq(spawn('taxi'), nil)
    end)
    it('a server-granted ticket allows one spawn of that model', function()
        PFVehicleSpawns.GrantVehicleSpawn(P, 'blista')
        assert_true(spawn('blista') ~= nil)
        Mock.clock = Mock.clock + 10
        assert_eq(spawn('blista'), nil, 'used up')
    end)
    it('the spawn point must be near the player', function()
        assert_eq(spawn('taxi', vector3(5000.0, 5000.0, 30.0)), nil)
    end)
    it('spawns are rate limited', function()
        assert_true(spawn('taxi') ~= nil)
        assert_eq(spawn('taxi'), nil)
    end)
    it('the long-distance callback has the same rules', function()
        assert_eq(Mock.callCallback('QBCore:Server:CreateVehicle', P, 'adder', HERE, false), nil)
    end)
end)
