-- pfm-garages parking and taking out (fix14 GAR-2, GAR-3). Parking: the garage is the server's (its
-- type, who may use it), the player stands at it, the car is the one the server sees them in (or right
-- beside them) with that plate, and that car leaves the world: parking only changed the row, so the car
-- stayed out and the garage handed out a second copy. Taking out: only at the garage the player stands
-- at, a parked car from the garage it is parked in, an impounded one from a depot, on one of that
-- garage's spawn points, never while a car with that plate is in the world, and one at a time.
load_resource('tests/lua/ledger_env.lua')
QBCoreMock.Shared.Vehicles = {
    sultan = { name = 'Sultan', price = 1000, category = 'sports' },
    dinghy = { name = 'Dinghy', price = 1000, category = 'boats' },
}

local cars = {}         -- player_vehicles: [plate] = row
local fleetPlates = {}
local onFleetQuery      -- runs once while the fleet table is read (another request in that wait)
local function copy(t) local o = {} for k, v in pairs(t) do o[k] = v end return o end
FakeDB.extraPatterns = {
    { "AND TABLE_NAME = 'job_garage_vehicles'", function() return 1 end },
    { 'SELECT plate FROM job_garage_vehicles WHERE active = 1 AND plate IN', function(p)
        if onFleetQuery then local f = onFleetQuery onFleetQuery = nil f() end
        local out = {}
        for _, plate in ipairs(p) do if fleetPlates[plate] then out[#out + 1] = { plate = plate } end end
        return out
    end },
    { 'SELECT vehicle, state FROM player_vehicles WHERE plate = ? AND citizenid = ?', function(p)
        local c = cars[p[1]]
        return (c and c.citizenid == p[2]) and { copy(c) } or nil
    end },
    { 'SELECT vehicle, mods, state, depotprice, garage FROM player_vehicles WHERE plate = ? AND citizenid = ?', function(p)
        local c = cars[p[1]]
        return (c and c.citizenid == p[2]) and { copy(c) } or nil
    end },
    { 'UPDATE player_vehicles SET state = 1, garage = ? WHERE plate = ? AND citizenid = ? AND state IN (0, 1)', function(p)
        local c = cars[p[2]]
        if not c or c.citizenid ~= p[3] or (c.state ~= 0 and c.state ~= 1) then return 0 end
        c.state, c.garage = 1, p[1]
        return 1
    end },
    { 'UPDATE player_vehicles SET state = 0, depotprice = 0 WHERE plate = ? AND citizenid = ? AND state = ? AND depotprice = ?', function(p)
        local c = cars[p[1]]
        if not c or c.citizenid ~= p[2] or c.state ~= p[3] or c.depotprice ~= p[4] then return 0 end
        c.state, c.depotprice = 0, 0
        return 1
    end },
    { 'SELECT depotprice FROM player_vehicles WHERE plate = ? AND citizenid = ?', function(p)
        local c = cars[p[1]]
        return (c and c.citizenid == p[2]) and c.depotprice or nil
    end },
    -- the statements of the code before this fix, so a check against it fails on what it does
    { 'SELECT citizenid FROM player_vehicles WHERE plate = ?', function(p) return cars[p[1]] and cars[p[1]].citizenid end },
    { 'UPDATE player_vehicles SET state = ?, garage = ? WHERE plate = ?', function(p) if cars[p[3]] then cars[p[3]].state, cars[p[3]].garage = p[1], p[2] end return 1 end },
    { 'SELECT vehicle, mods, state, depotprice FROM player_vehicles WHERE plate = ? AND citizenid = ?', function(p)
        local c = cars[p[1]]
        return (c and c.citizenid == p[2]) and { copy(c) } or nil
    end },
    { 'UPDATE player_vehicles SET depotprice = 0 WHERE plate = ? AND citizenid = ?', function(p) if cars[p[1]] then cars[p[1]].depotprice = 0 end return 1 end },
    { 'UPDATE player_vehicles SET state = 0 WHERE plate = ? AND citizenid = ?', function(p) if cars[p[1]] then cars[p[1]].state = 0 end return 1 end },
}
LedgerEnv.load('pfm-garages', { 'pfm-garages/config.lua', 'pfm-garages/server/main.lua' })

-- the world: entities with a plate, a position and a model
local existing, plates, spawned, timers = {}, {}, {}, {}
local nextEntity = 900
function CreateVehicleServerSetter(hash, kind, x, y, z, w)
    nextEntity = nextEntity + 1
    existing[nextEntity] = true
    Mock.models[nextEntity] = hash
    Mock.coords[nextEntity] = vector3(x, y, z)
    spawned[#spawned + 1] = { entity = nextEntity, x = x, y = y, z = z, w = w }
    return nextEntity
end
function SetVehicleNumberPlateText(veh, plate) plates[veh] = plate end
function GetVehicleNumberPlateText(veh) return plates[veh] end
function DoesEntityExist(e) return existing[e] == true end
function DeleteEntity(e) existing[e] = nil end
function GetAllVehicles() local out = {} for e in pairs(existing) do out[#out + 1] = e end table.sort(out) return out end
function SetTimeout(_, fn) timers[#timers + 1] = fn end
local function runTimers() local list = timers timers = {} for _, fn in ipairs(list) do fn() end end

local P, OTHER = 1, 2
local function at(id) local t = Config.Garages[id].takeVehicle return vector3(t.x, t.y, t.z) end
local function standAt(src, id) Mock.coords[src] = at(id) end
--- a car in the world with that plate; the player sits in it when `driver` is given
local function car(plate, pos, driver)
    nextEntity = nextEntity + 1
    existing[nextEntity], plates[nextEntity] = true, plate
    Mock.coords[nextEntity] = pos
    Mock.models[nextEntity] = GetHashKey('sultan')
    if driver then Mock.vehicleOf[driver] = nextEntity Mock.coords[driver] = pos end
    return nextEntity
end
local function park(src, plate, garage, clientType) return Mock.callCallback('qb-garages:server:canDeposit', src, plate, clientType or 'public', garage, 1) end
local function spawn(src, plate, garage, index) return Mock.callCallback('qb-garages:server:spawnvehicle', src, plate, garage, index or 1) end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players, Mock.coords, Mock.vehicleOf, Mock.models = {}, {}, {}, {}
    existing, plates, spawned, timers, fleetPlates = {}, {}, {}, {}, {}
    onFleetQuery = nil
    for _, src in ipairs({ P, OTHER }) do
        local p = Mock.newPlayer(src)
        p.PlayerData.money = { cash = 0, bank = 5000 }
        p.PlayerData.license = 'license:' .. src
    end
    cars = {
        OUT1 = { citizenid = 'CID1', vehicle = 'sultan', mods = '{"color1":3}', state = 0, depotprice = 0, garage = 'motelgarage' },
        PARKED1 = { citizenid = 'CID1', vehicle = 'sultan', mods = '{}', state = 1, depotprice = 0, garage = 'sapcounsel' },
        IMPOUND1 = { citizenid = 'CID1', vehicle = 'sultan', mods = '{}', state = 0, depotprice = 500, garage = 'motelgarage' },
        SEIZED1 = { citizenid = 'CID1', vehicle = 'sultan', mods = '{}', state = 2, depotprice = 0, garage = 'motelgarage' },
    }
end

describe('GAR-2 parking', function()
    it('the dealership scenario: a car still being driven cannot be marked parked from anywhere', function()
        car('OUT1', vector3(-50, -50, 30), P)
        assert_false(park(P, 'OUT1', 'x'), 'a garage that does not exist')
        assert_false(park(P, 'OUT1', 'motelgarage'), 'far from the garage')
        assert_eq(cars.OUT1.state, 0)
    end)

    it('the car must be the one the player sits in, or one right beside them, with that plate', function()
        local pos = at('motelgarage')
        car('SOMEONE', pos, P)                                    -- sits in another car
        car('OUT1', vector3(pos.x + 40, pos.y, pos.z))            -- OUT1 is across the car park
        assert_false(park(P, 'OUT1', 'motelgarage'))
        assert_eq(cars.OUT1.state, 0)
        car('OUT1', vector3(pos.x + 4, pos.y, pos.z))             -- now one is right beside them
        assert_true(park(P, 'OUT1', 'motelgarage'))
        assert_eq(cars.OUT1.state, 1)
        assert_eq(cars.OUT1.garage, 'motelgarage')
    end)

    it('the parked car leaves the world; until it is gone it is not handed out again', function()
        local veh = car('OUT1', at('motelgarage'), P)
        assert_true(park(P, 'OUT1', 'motelgarage'))
        Mock.vehicleOf[P] = nil
        assert_eq(spawn(P, 'OUT1', 'motelgarage'), nil, 'the first copy still exists')
        assert_eq(#spawned, 0)
        -- the owner's client did not delete it: the server does
        runTimers()
        assert_eq(existing[veh], nil)
        local netId, props = spawn(P, 'OUT1', 'motelgarage')
        assert_true(netId ~= nil, 'now it comes out, once')
        assert_eq(props.color1, 3)
        assert_eq(spawn(P, 'OUT1', 'motelgarage'), nil)
    end)

    it('an honest client that deleted the car itself: the take-out works as soon as it is gone', function()
        local veh = car('OUT1', at('motelgarage'), P)
        assert_true(park(P, 'OUT1', 'motelgarage'))
        existing[veh] = nil
        Mock.vehicleOf[P] = nil
        assert_true(spawn(P, 'OUT1', 'motelgarage') ~= nil)
        runTimers()                                                -- nothing left to remove
        assert_eq(#spawned, 1)
    end)

    it('a second live car with the plate is refused while the tracked one exists, and a different model is refused', function()
        local real = car('OUT1', at('motelgarage'), P)
        assert_true(park(P, 'OUT1', 'motelgarage'))                -- tracked until it leaves the world
        local stray = car('OUT1', at('motelgarage'), P)            -- a client-made copy with the plate
        cars.OUT1.state = 0
        assert_false(park(P, 'OUT1', 'motelgarage'), 'the tracked car keeps its place')
        runTimers()
        existing[real] = nil
        Mock.models[stray] = GetHashKey('adder')                   -- not the owned model
        assert_false(park(P, 'OUT1', 'motelgarage'), 'another model with the plate is not the owned car')
    end)

    it('the garage\'s own type counts: a depot takes no cars, a job garage only its job, a gang garage only its gang', function()
        car('OUT1', at('depotLot'), P)
        assert_false(park(P, 'OUT1', 'depotLot', 'public'))
        car('OUT1', at('police'), P)
        assert_false(park(P, 'OUT1', 'police', 'public'), 'not police')
        Mock.players[P].PlayerData.job = { name = 'police', type = 'leo' }
        assert_true(park(P, 'OUT1', 'police', 'public'))
        runTimers()                                                -- the parked car leaves the world
        cars.OUT1.state = 0
        car('OUT1', at('ballas'), P)
        assert_false(park(P, 'OUT1', 'ballas', 'job'), 'not a Ballas member')
        Mock.players[P].PlayerData.gang = { name = 'ballas' }
        assert_true(park(P, 'OUT1', 'ballas', 'job'))
    end)

    it('someone else\'s car, a seized car and a fleet car are not parked; bad payloads do not crash', function()
        car('OUT1', at('motelgarage'), OTHER)
        assert_false(park(OTHER, 'OUT1', 'motelgarage'))
        car('SEIZED1', at('motelgarage'), P)
        assert_false(park(P, 'SEIZED1', 'motelgarage'))
        assert_eq(cars.SEIZED1.state, 2)
        fleetPlates.OUT1 = true
        car('OUT1', at('motelgarage'), P)
        assert_false(park(P, 'OUT1', 'motelgarage'))
        assert_eq(cars.OUT1.state, 0)
        assert_false(park(P, nil, 'motelgarage'))
        assert_false(park(P, 'OUT1', { 'motelgarage' }))
        assert_false(Mock.callCallback('qb-garages:server:canDeposit', P, 'OUT1', 'public', 'motelgarage', 0))
    end)
end)

describe('GAR-3 taking out', function()
    it('a parked car comes out only at the garage it is parked in, with the player there', function()
        standAt(P, 'motelgarage')
        assert_eq(spawn(P, 'PARKED1', 'motelgarage'), nil, 'parked at San Andreas, not at the motel')
        assert_eq(spawn(P, 'PARKED1', 'sapcounsel'), nil, 'the right garage, but the player is not there')
        assert_eq(#spawned, 0)
        assert_eq(cars.PARKED1.state, 1)
        standAt(P, 'sapcounsel')
        assert_true(spawn(P, 'PARKED1', 'sapcounsel') ~= nil)
        assert_eq(cars.PARKED1.state, 0)
    end)

    it('Config.SharedGarages lets any of the player\'s garages hand it out (still at that garage)', function()
        Config.SharedGarages = true
        standAt(P, 'motelgarage')
        local netId = spawn(P, 'PARKED1', 'motelgarage')
        Config.SharedGarages = false
        assert_true(netId ~= nil)
    end)

    it('the car is placed on the garage\'s spawn point; the client only picks its number', function()
        cars.PILL1 = { citizenid = 'CID1', vehicle = 'sultan', mods = '{}', state = 1, depotprice = 0, garage = 'pillboxgarage' }
        standAt(P, 'pillboxgarage')
        assert_true(spawn(P, 'PILL1', 'pillboxgarage', 3) ~= nil)
        local p3 = Config.Garages.pillboxgarage.spawnPoint[3]
        assert_eq(spawned[1].x, p3.x)
        assert_eq(spawned[1].y, p3.y)
        assert_eq(spawned[1].w, p3.w)
        -- a number the garage does not have: a free point of the garage (not the occupied third one)
        cars.PILL2 = { citizenid = 'CID1', vehicle = 'sultan', mods = '{}', state = 1, depotprice = 0, garage = 'pillboxgarage' }
        assert_true(spawn(P, 'PILL2', 'pillboxgarage', { x = 0, y = 0 }) ~= nil)
        local p1 = Config.Garages.pillboxgarage.spawnPoint[1]
        assert_eq(spawned[2].x, p1.x)
        cars.PILL3 = { citizenid = 'CID1', vehicle = 'sultan', mods = '{}', state = 1, depotprice = 0, garage = 'pillboxgarage' }
        assert_true(spawn(P, 'PILL3', 'pillboxgarage', 99) ~= nil)
        local p2 = Config.Garages.pillboxgarage.spawnPoint[2]
        assert_eq(spawned[3].x, p2.x, 'the first free point')
    end)

    it('an impounded car leaves only from a depot, once its fee is paid; a depot does not hand out parked cars', function()
        standAt(P, 'depotLot')
        assert_eq(spawn(P, 'IMPOUND1', 'depotLot'), nil, 'not paid')
        Mock.fireNet('qb-garages:server:PayDepotPrice', P, { plate = 'IMPOUND1' })
        assert_eq(Mock.players[P].PlayerData.money.bank, 4500)
        standAt(P, 'motelgarage')
        assert_eq(spawn(P, 'IMPOUND1', 'motelgarage'), nil, 'paid, but this is not a depot')
        standAt(P, 'depotLot')
        assert_true(spawn(P, 'IMPOUND1', 'depotLot') ~= nil)
        assert_eq(cars.IMPOUND1.depotprice, 0)
        cars.PARKED1.garage = 'depotLot'
        assert_eq(spawn(P, 'PARKED1', 'depotLot'), nil)
    end)

    it('a car with this plate anywhere in the world (never tracked here) blocks the take-out', function()
        car('PARKED1', vector3(3000, 3000, 30))
        standAt(P, 'sapcounsel')
        assert_eq(spawn(P, 'PARKED1', 'sapcounsel'), nil)
        assert_eq(cars.PARKED1.state, 1)
    end)

    it('a second take-out while the first waits on the database makes no second car', function()
        standAt(P, 'sapcounsel')
        local second
        onFleetQuery = function() second = spawn(P, 'PARKED1', 'sapcounsel') end
        local first = spawn(P, 'PARKED1', 'sapcounsel')
        assert_true(first ~= nil)
        assert_eq(second, nil)
        assert_eq(#spawned, 1)
    end)

    it('the row leaves only in the state checked: changed meanwhile, the car is removed again', function()
        standAt(P, 'sapcounsel')
        onFleetQuery = function() cars.PARKED1.state = 0 end   -- e.g. taken out another way meanwhile
        assert_eq(spawn(P, 'PARKED1', 'sapcounsel'), nil)
        assert_eq(#spawned, 1)
        assert_eq(existing[spawned[1].entity], nil, 'the car made for it is gone')
    end)

    it('seized cars, other players\' cars, unknown garages and bad payloads give nothing', function()
        standAt(P, 'motelgarage')
        assert_eq(spawn(P, 'SEIZED1', 'motelgarage'), nil)
        standAt(OTHER, 'sapcounsel')
        assert_eq(spawn(OTHER, 'PARKED1', 'sapcounsel'), nil)
        assert_eq(spawn(P, 'PARKED1', 'nowhere'), nil)
        assert_eq(spawn(P, 'PARKED1', nil), nil)
        assert_eq(spawn(P, { 'x' }, 'sapcounsel'), nil)
        assert_eq(Mock.callCallback('qb-garages:server:spawnvehicle', P, 'PARKED1', 'sultan', vector4(1, 1, 1, 1)), nil, 'the old call shape')
        assert_eq(#spawned, 0)
    end)
end)
