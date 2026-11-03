-- pfm-garages: a car is spawned only from the garage (state 1) or after its impound fee was paid, never
-- twice while the first copy exists, and at the garage the player stands at; the client cannot mark a
-- car parked or clear its impound fee.
load_resource('tests/lua/ledger_env.lua')
QBCoreMock.Shared.Vehicles = { sultan = { name = 'Sultan', price = 1000, category = 'sports' } }

local cars = {}        -- player_vehicles: [plate] = row
local existing = {}    -- entities that still exist
local fleetPlates = {}  -- pf-jobgarages active fleet plates
FakeDB.extraPatterns = {
    { "AND TABLE_NAME = 'job_garage_vehicles'", function() return 1 end },
    { 'SELECT plate FROM job_garage_vehicles WHERE active = 1 AND plate IN', function(p)
        local out = {}
        for _, plate in ipairs(p) do if fleetPlates[plate] then out[#out + 1] = { plate = plate } end end
        return out
    end },
    { 'SELECT * FROM player_vehicles WHERE citizenid = ? AND depotprice > 0', function(p)
        local out = {}
        for plate, c in pairs(cars) do if c.citizenid == p[1] and (c.depotprice or 0) > 0 then out[#out + 1] = { plate = plate, vehicle = c.vehicle, citizenid = c.citizenid } end end
        table.sort(out, function(a, b) return a.plate < b.plate end)
        return out
    end },
    { 'SELECT vehicle, mods, state, depotprice, garage FROM player_vehicles WHERE plate = ? AND citizenid = ?', function(p)
        local c = cars[p[1]]
        return (c and c.citizenid == p[2]) and { c } or {}
    end },
    -- the take-out: only in the state the spawn checked
    { 'UPDATE player_vehicles SET state = 0, depotprice = 0 WHERE plate = ? AND citizenid = ? AND state = ? AND depotprice = ?', function(p)
        local c = cars[p[1]]
        if not c or c.citizenid ~= p[2] or c.state ~= p[3] or (c.depotprice or 0) ~= p[4] then return 0 end
        c.state, c.depotprice = 0, 0
        return 1
    end },
    { 'SELECT vehicle, mods FROM player_vehicles WHERE plate = ? AND citizenid = ?', function(p)
        local c = cars[p[1]]
        return (c and c.citizenid == p[2]) and { c } or {}
    end },
    { 'SELECT depotprice FROM player_vehicles WHERE plate = ? AND citizenid = ?', function(p)
        local c = cars[p[1]]
        return (c and c.citizenid == p[2]) and c.depotprice or nil
    end },
    { 'SELECT citizenid FROM player_vehicles WHERE plate = ?', function(p) return cars[p[1]] and cars[p[1]].citizenid end },
    { 'UPDATE player_vehicles SET depotprice = 0', function(p) if cars[p[1]] then cars[p[1]].depotprice = 0 end return 1 end },
    { 'UPDATE player_vehicles SET state = ? WHERE plate = ? AND citizenid = ?', function(p) if cars[p[2]] and cars[p[2]].citizenid == p[3] then cars[p[2]].state = p[1] end return 1 end },
    { 'UPDATE player_vehicles SET state = 0', function(p) if cars[p[1]] then cars[p[1]].state = 0 end return 1 end },
    { 'UPDATE player_vehicles SET state = ?, garage = ?', function(p) if cars[p[3]] then cars[p[3]].state = p[1] end return 1 end },
}
LedgerEnv.load('pfm-garages', { 'pfm-garages/config.lua', 'pfm-garages/server/main.lua' })

local nextEntity = 900
function CreateVehicleServerSetter() nextEntity = nextEntity + 1; existing[nextEntity] = true; return nextEntity end
function SetVehicleNumberPlateText() end
function DoesEntityExist(e) return existing[e] == true end

local P, OTHER = 1, 2
local MOTEL = Config.Garages.motelgarage.takeVehicle
local DEPOT = Config.Garages.depotLot.takeVehicle
local HERE = vector3(MOTEL.x, MOTEL.y, MOTEL.z)

local function spawn(src, plate, garage) return Mock.callCallback('qb-garages:server:spawnvehicle', src, plate, garage or 'motelgarage', 1) end
local function atDepot(src) Mock.coords[src] = vector3(DEPOT.x, DEPOT.y, DEPOT.z) end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players, Mock.coords = {}, {}
    existing = {}
    fleetPlates = {}
    for _, src in ipairs({ P, OTHER }) do
        Mock.newPlayer(src).PlayerData.money = { cash = 0, bank = 5000 }
        Mock.coords[src] = HERE
    end
    cars = {
        PARKED1 = { citizenid = 'CID1', vehicle = 'sultan', mods = '{}', state = 1, depotprice = 0, garage = 'motelgarage' },
        OUT1 = { citizenid = 'CID1', vehicle = 'sultan', mods = '{}', state = 0, depotprice = 0, garage = 'motelgarage' },
        IMPOUND1 = { citizenid = 'CID1', vehicle = 'sultan', mods = '{}', state = 0, depotprice = 500, garage = 'motelgarage' },
    }
end

describe('taking a car out', function()
    it('a parked car comes out once; it cannot be spawned again while it exists', function()
        assert_true(spawn(P, 'PARKED1') ~= nil)
        assert_eq(cars.PARKED1.state, 0)
        -- the client says the car is gone and marks it parked: still refused
        Mock.fireNet('qb-garages:server:UpdateOutsideVehicle', P, 'PARKED1', nil)
        Mock.fireNet('qb-garages:server:updateVehicleState', P, 1, 'PARKED1')
        assert_eq(spawn(P, 'PARKED1'), nil)
    end)
    it('a car that is out cannot be taken out of the garage', function()
        assert_eq(spawn(P, 'OUT1'), nil)
    end)
    it('an impounded car needs its fee paid first', function()
        atDepot(P)
        assert_eq(spawn(P, 'IMPOUND1', 'depotLot'), nil)
        Mock.fireNet('qb-garages:server:updateVehicleState', P, 0, 'IMPOUND1') -- used to clear the fee
        assert_eq(cars.IMPOUND1.depotprice, 500)
        Mock.fireNet('qb-garages:server:PayDepotPrice', P, { plate = 'IMPOUND1' })
        assert_eq(Mock.players[P].PlayerData.money.bank, 4500)
        assert_true(spawn(P, 'IMPOUND1', 'depotLot') ~= nil)
        assert_eq(cars.IMPOUND1.depotprice, 0)
    end)
    it('someone else cannot take my car, and nobody can spawn one away from the garage', function()
        assert_eq(spawn(OTHER, 'PARKED1'), nil)
        Mock.coords[P] = vector3(MOTEL.x + 200, MOTEL.y, MOTEL.z)
        assert_eq(spawn(P, 'PARKED1'), nil)
        assert_eq(cars.PARKED1.state, 1)
    end)
end)

describe('job fleet cars', function()
    it('do not come out of the personal garage', function()
        fleetPlates.PARKED1 = true
        assert_eq(spawn(P, 'PARKED1'), nil)
        assert_eq(cars.PARKED1.state, 1)
        fleetPlates.PARKED1 = nil          -- taken out of the fleet: the owner gets it back
        assert_true(spawn(P, 'PARKED1') ~= nil)
    end)
    it('are not listed at the impound and their fee cannot be paid there', function()
        cars.IMPOUND2 = { citizenid = 'CID1', vehicle = 'sultan', mods = '{}', state = 0, depotprice = 500, garage = 'motelgarage' }
        fleetPlates.IMPOUND2 = true
        local list = Mock.callCallback('qb-garages:server:GetGarageVehicles', P, 'nowhere', 'depot', {})
        assert_eq(#list, 1)
        assert_eq(list[1].plate, 'IMPOUND1')
        Mock.fireNet('qb-garages:server:PayDepotPrice', P, { plate = 'IMPOUND2' })
        assert_eq(Mock.players[P].PlayerData.money.bank, 5000)
        atDepot(P)
        assert_eq(spawn(P, 'IMPOUND2', 'depotLot'), nil)
    end)
end)
