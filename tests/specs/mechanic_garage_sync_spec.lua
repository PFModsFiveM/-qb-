-- pf-mechanicjob garage sync (server/garage_sync.lua): a car's saved mods and damage can only be
-- written by its owner or by whoever is in that car right now.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/fake_db.lua')
QBCore = QBCoreMock
Wait = function() error('stop thread') end      -- the stale-cache cleanup loop
CreateThread = function(fn) pcall(fn) end

local owners = { ['OWNED1'] = 'CID1', ['OWNED2'] = 'CID2' }
local modsWrites, diagWrites = {}, {}

FakeDB.extraPatterns = {
    { 'SELECT citizenid FROM player_vehicles WHERE plate = ?', function(p)
        return owners[p[1]] and { citizenid = owners[p[1]] } or nil
    end },
    { 'UPDATE player_vehicles SET mods = ? WHERE plate = ?', function(p) modsWrites[#modsWrites + 1] = { plate = p[2], mods = p[1] }; return 1 end },
    { 'INSERT INTO vehicle_diagnostics', function(p) diagWrites[#diagWrites + 1] = { plate = p[1], cid = p[2] }; return 1 end },
}

Config = nil
load_resource('[pfscripts]/pf-mechanicjob/config.lua')
Config.Debug = false
load_resource('[pfscripts]/pf-mechanicjob/server/garage_sync.lua')

local OWNER, STRANGER = 1, 2
local props = { plate = 'OWNED1', partDamage = { oil = 50 }, engineHealth = 900, modEngine = 4 }

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    Mock.vehicleOf, Mock.plates = {}, {}
    Mock.newPlayer(OWNER, 'CID1')
    Mock.newPlayer(STRANGER, 'CID9')
    modsWrites, diagWrites = {}, {}
end

describe('pf-mechanicjob garage sync', function()
    it("a stranger cannot overwrite someone else's car", function()
        Mock.fireNet('pf_mech:saveFullDiagnostics', STRANGER, 'OWNED1', props)
        Mock.fireNet('pf_mech:sync:cacheVehicleState', STRANGER, { plate = 'OWNED1', props = props })
        Mock.fireNet('pf_mech:sync:forceSave', STRANGER, 'OWNED1')
        Mock.fireNet('qb-garages:server:updateVehicleStats', STRANGER, 'OWNED1', 100, 1000, 1000)
        assert_eq(#modsWrites, 0)
        assert_eq(#diagWrites, 0)
    end)
    it('the owner saves their own car', function()
        Mock.fireNet('pf_mech:saveFullDiagnostics', OWNER, 'OWNED1', props)
        assert_eq(#modsWrites, 1)
        assert_eq(diagWrites[1].cid, 'CID1')
    end)
    it("whoever is in the car can sync it (a friend driving the owner's car)", function()
        Mock.vehicleOf[STRANGER] = 500
        Mock.plates[500] = ' OWNED1 '
        Mock.fireNet('pf_mech:sync:cacheVehicleState', STRANGER, { plate = 'OWNED1', props = props })
        Mock.fireNet('qb-garages:server:updateVehicleStats', STRANGER, 'OWNED1', 100, 1000, 1000)
        assert_eq(#modsWrites, 1)
        assert_eq(modsWrites[1].plate, 'OWNED1')
    end)
    it('being in one car does not unlock another plate', function()
        Mock.vehicleOf[STRANGER] = 500
        Mock.plates[500] = 'OWNED1'
        Mock.fireNet('pf_mech:saveFullDiagnostics', STRANGER, 'OWNED2', props)
        assert_eq(#modsWrites, 0)
    end)
    it('rejects bad or oversized props and unowned plates', function()
        Mock.fireNet('pf_mech:saveFullDiagnostics', OWNER, 'OWNED1', 'nope')
        Mock.fireNet('pf_mech:saveFullDiagnostics', OWNER, 'OWNED1', { plate = 'OWNED1', junk = string.rep('x', 70000) })
        Mock.fireNet('pf_mech:saveFullDiagnostics', OWNER, 'NOBODY', props)
        Mock.fireNet('pf_mech:sync:cacheVehicleState', OWNER, 'not a table')
        assert_eq(#modsWrites, 0)
    end)
end)
