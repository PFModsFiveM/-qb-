-- pfm-garages on the real database (fix14 GAR-1..3): house garages are read from the real
-- houselocations table (its default "no garage" value skipped); parking changes the row only while
-- the car is out or parked (never a seized one) and takes the car out of the world; taking out
-- changes the row only in the state the spawn checked, so a second take-out of the same car fails.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
local states = { ['pf-government'] = 'missing', ['pf-services'] = 'missing', ['pfm-fuel'] = 'missing', ['pf-devices'] = 'missing' }
function GetResourceState(name) return states[name] or 'started' end

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
RealDB.exec('pfm-garages/player_vehicles.sql')
RealDB.exec('pfm-houses/qb-houses.sql')
function GetCurrentResourceName() return 'pfm-banking' end
Config = nil
load_resource('pfm-banking/config.lua')
load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')
Mock.exportsByResource['pfm-banking'] = Mock.exportsByResource['__self']
Mock.exportsByResource['__self'] = nil
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end
assert(PFLedger.Start(), 'ledger start')
QBCoreMock.Shared.Vehicles = { sultan = { name = 'Sultan', brand = 'Karin', price = 1000, category = 'sports' } }

-- houses: one with a garage, one with the column default (no garage)
MySQL.insert.await("INSERT INTO houselocations (name, label, coords, owned, price, tier, garage) VALUES ('Mirror Park1', 'Mirror Park 1', '{}', 1, 1000, 1, ?)",
    { '{"x":1100.5,"y":-640.25,"z":56.8,"w":180}' })
MySQL.insert.await("INSERT INTO houselocations (name, label, coords, owned, price, tier) VALUES ('Empty Lot1', 'Empty Lot 1', '{}', 0, 1000, 1)", {})
local keys = {}
Mock.exportsByResource['pfm-houses'] = { hasKey = function(_, _, cid, house) return keys[house .. '|' .. cid] == true end }

function GetCurrentResourceName() return 'pfm-garages' end
Config = nil
load_resource('pfm-banking/payouts.lua')
load_resource('pfm-garages/config.lua')
load_resource('pfm-garages/server/main.lua')
PFGarages.Start()

local existing, plates, timers = {}, {}, {}
local nextEntity = 900
function CreateVehicleServerSetter(_, _, x, y, z) nextEntity = nextEntity + 1 existing[nextEntity] = true Mock.coords[nextEntity] = vector3(x, y, z) return nextEntity end
function SetVehicleNumberPlateText(veh, plate) plates[veh] = plate end
function GetVehicleNumberPlateText(veh) return plates[veh] end
function DoesEntityExist(e) return existing[e] == true end
function DeleteEntity(e) existing[e] = nil end
function GetAllVehicles() local out = {} for e in pairs(existing) do out[#out + 1] = e end table.sort(out) return out end
function SetTimeout(_, fn) timers[#timers + 1] = fn end
local function runTimers() local list = timers timers = {} for _, fn in ipairs(list) do fn() end end

local P = 1
local plateNo = 0
local function newPlate() plateNo = plateNo + 1 return ('GAR%04d'):format(plateNo) end
local function car(plate, state, garage, fee)
    MySQL.insert.await("INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, garage, state, depotprice) VALUES ('l', 'GCID1', 'sultan', '1', '{}', ?, ?, ?, ?)",
        { plate, garage, state, fee or 0 })
end
local function row(plate) return MySQL.single.await('SELECT state, garage, depotprice FROM player_vehicles WHERE plate = ?', { plate }) end
local function at(id) local t = Config.Garages[id].takeVehicle return vector3(t.x, t.y, t.z) end
local function seatIn(plate, pos)
    nextEntity = nextEntity + 1
    existing[nextEntity], plates[nextEntity] = true, plate
    Mock.coords[nextEntity], Mock.coords[P] = pos, pos
    Mock.vehicleOf[P] = nextEntity
    return nextEntity
end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.vehicleOf = {}, {}
    local p = Mock.newPlayer(P, 'GCID1')
    p.PlayerData.license = 'license:1'
    p.PlayerData.money = { cash = 0, bank = 1000 }
    timers = {}
end

describe('fix14 garages on the real database', function()
    it('house garages come from houselocations; the default "no garage" value is skipped', function()
        local g = Config.Garages.mirrorpark1
        assert_true(g ~= nil)
        assert_eq(g.type, 'house')
        assert_eq(g.houseName, 'Mirror Park1')
        assert_eq(g.label, 'Mirror Park 1')
        assert_near(g.takeVehicle.x, 1100.5, 0.001)
        assert_near(g.spawnPoint[1].w, 180, 0.001)
        assert_eq(Config.Garages.emptylot1, nil)
    end)

    it('a key holder parks at the house garage; the car leaves the world; it comes out there once', function()
        local plate = newPlate()
        car(plate, 0, 'motelgarage')
        local veh = seatIn(plate, at('mirrorpark1'))
        assert_false(Mock.callCallback('qb-garages:server:canDeposit', P, plate, 'public', 'mirrorpark1', 1), 'no key')
        keys['Mirror Park1|GCID1'] = true
        assert_true(Mock.callCallback('qb-garages:server:canDeposit', P, plate, 'house', 'mirrorpark1', 1))
        assert_eq(tonumber(row(plate).state), 1)
        assert_eq(row(plate).garage, 'mirrorpark1')
        Mock.vehicleOf[P] = nil
        assert_eq(Mock.callCallback('qb-garages:server:spawnvehicle', P, plate, 'mirrorpark1', 1), nil, 'still in the world')
        runTimers()
        assert_eq(existing[veh], nil)
        assert_true(Mock.callCallback('qb-garages:server:spawnvehicle', P, plate, 'mirrorpark1', 1) ~= nil)
        assert_eq(tonumber(row(plate).state), 0)
        assert_eq(Mock.callCallback('qb-garages:server:spawnvehicle', P, plate, 'mirrorpark1', 1), nil)
    end)

    it('a seized car is never parked; a car parked elsewhere does not come out here', function()
        local seized, elsewhere = newPlate(), newPlate()
        car(seized, 2, 'motelgarage')
        car(elsewhere, 1, 'sapcounsel')
        seatIn(seized, at('motelgarage'))
        assert_false(Mock.callCallback('qb-garages:server:canDeposit', P, seized, 'public', 'motelgarage', 1))
        assert_eq(tonumber(row(seized).state), 2)
        Mock.vehicleOf[P] = nil
        Mock.coords[P] = at('motelgarage')
        assert_eq(Mock.callCallback('qb-garages:server:spawnvehicle', P, elsewhere, 'motelgarage', 1), nil)
        assert_eq(tonumber(row(elsewhere).state), 1)
    end)

    it('the take-out changes the row only in the state it checked', function()
        local plate = newPlate()
        car(plate, 1, 'motelgarage')
        -- the statement the spawn runs, against a row that changed after it was read
        MySQL.update.await('UPDATE player_vehicles SET state = 0 WHERE plate = ?', { plate })
        local n = MySQL.update.await('UPDATE player_vehicles SET state = 0, depotprice = 0 WHERE plate = ? AND citizenid = ? AND state = ? AND depotprice = ?', { plate, 'GCID1', 1, 0 })
        assert_eq(tonumber(type(n) == 'table' and n.affectedRows or n), 0)
        -- an impounded car with its fee paid ahead leaves the depot and its fee is cleared
        local imp = newPlate()
        car(imp, 0, 'motelgarage', 300)
        local n2 = MySQL.update.await('UPDATE player_vehicles SET state = 0, depotprice = 0 WHERE plate = ? AND citizenid = ? AND state = ? AND depotprice = ?', { imp, 'GCID1', 0, 300 })
        assert_eq(tonumber(type(n2) == 'table' and n2.affectedRows or n2), 1)
        assert_eq(tonumber(row(imp).depotprice), 0)
    end)
end)
