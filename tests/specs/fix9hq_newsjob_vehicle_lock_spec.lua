-- pfm-newsjob (mocked), review fixes 9hq:
--  (a) the 'one news vehicle at a time' lock follows the server entity: it is freed when the issued
--      vehicle no longer exists (cleaned up, despawned) or is a wreck (engine health -4000: the server
--      deletes it), on entityRemoved, and when the spawn fails; it is taken before the spawn yields.
--  (b) storing is decided by the server (vehicle exists, at its garage point, reporter in it or next
--      to it; the server deletes it); the trunk is stocked only for a van the server just spawned,
--      once, and no client event stocks a trunk for a plate it names.
load_resource('tests/lua/fivem_mocks.lua')
function GetCurrentResourceName() return 'pfm-newsjob' end
Config = nil
load_resource('pfm-newsjob/config.lua')

local inventories, items, removedInv = {}, {}, {}
Mock.exportsByResource['pfm-inventory'] = {
    CreateInventory = function(_, id) inventories[id] = true end,
    AddItem = function(_, id, name) items[#items + 1] = { id = id, name = name } return true end,
    RemoveInventory = function(_, id) removedInv[#removedInv + 1] = id; inventories[id] = nil end,
    GetItemCount = function() return 0 end, -- the reporter carries no gear (fix14_streetjobs_newsgear covers the rest)
    GetInventory = function() return nil end,
}
Mock.exportsByResource['pfm-vehiclekeys'] = { HasKeys = function() return true end }

-- server entities: which exist, where they are, their plates
local alive, nextVeh, spawnFails, duringSpawn = {}, 5000, false, nil
function DoesEntityExist(e) return alive[e] == true end
local engineHealth = {}
function GetVehicleEngineHealth(e) return engineHealth[e] or 1000.0 end
function SetVehicleNumberPlateText(veh, plate) Mock.plates[veh] = plate end
local realDelete = DeleteEntity
function DeleteEntity(e) alive[e] = nil; return realDelete(e) end
QBCoreMock.Functions.SpawnVehicle = function(src, model, coords, warp)
    if duringSpawn then local f = duringSpawn; duringSpawn = nil; f() end  -- what happens while the spawn yields
    if spawnFails then return 0 end
    nextVeh = nextVeh + 1
    local veh = nextVeh
    alive[veh] = true
    Mock.models[veh] = joaat(model)
    Mock.coords[veh] = vector3(coords.x, coords.y, coords.z)
    if warp then Mock.vehicleOf[src] = veh end
    return veh
end

load_resource('pfm-newsjob/server/main.lua')
local fieldStatus = Mock.selfExport('GetFieldStatus')

local REP = 1
local VAN = Config.Locations.vehicle.coords
local function at(e, c) Mock.coords[e] = vector3(c.x, c.y, c.z) end
local function issuedVehicle()
    local list = Mock.clientEventsNamed('pfm-newsjob:client:spawnVehicle')
    local ev = list[#list]
    return ev and ev.args[5], ev and ev.args[3]
end
local function request()
    Mock.clock = Mock.clock + 60
    return NewsJob.RequestVehicle(REP, 'vehicle', 'rumpo')
end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords, Mock.vehicleOf, Mock.plates, Mock.deleted = {}, {}, {}, {}, {}
    inventories, items, removedInv = {}, {}, {}
    alive, spawnFails, duringSpawn, engineHealth = {}, false, nil, {}
    Config.SpawnCooldown = 10
    NewsJob.__reset()
    Mock.clock = Mock.clock + 1000
    local p = Mock.newPlayer(REP, 'CIDREP')
    p.PlayerData.job = { name = 'reporter', grade = { level = 0 }, onduty = true }
    at(REP, VAN)
end

describe('fix9hq newsjob: the one-vehicle lock frees when the vehicle is gone', function()
    it('a destroyed / despawned van no longer holds the lock on the next request', function()
        assert_true(request())
        local veh = issuedVehicle()
        assert_true(veh ~= nil and alive[veh], 'the server spawned the van')
        assert_eq(select(2, request()), 'vehicle_out')
        alive[veh] = nil -- wrecked and cleaned up by the game
        assert_eq(fieldStatus().CIDREP, nil, 'the newsroom does not show a vehicle that is gone')
        assert_true(request(), 'a reporter whose van is gone can take another')
        assert_eq(select(2, request()), 'vehicle_out')
    end)

    it('entityRemoved for the issued vehicle frees the lock; other entities do not', function()
        assert_true(request())
        local veh = issuedVehicle()
        Mock.fireEvent('entityRemoved', nil, 424242)
        assert_eq(select(2, request()), 'vehicle_out')
        Mock.fireEvent('entityRemoved', nil, veh)
        assert_eq(fieldStatus().CIDREP, nil)
        assert_true(inventories['trunk-' .. select(2, issuedVehicle())] == nil, 'the gone van\'s trunk is dropped')
        assert_true(request())
    end)

    it('a wrecked van that still exists frees the lock: the server deletes the wreck', function()
        assert_true(request())
        local veh, plate = issuedVehicle()
        at(veh, vector3(VAN.x + 2, VAN.y, VAN.z))
        Mock.vehicleOf[REP] = nil -- nobody can sit in a wreck
        engineHealth[veh] = 250.0 -- damaged, still drivable: keeps the lock
        assert_eq(select(2, request()), 'vehicle_out')
        assert_true(alive[veh])
        engineHealth[veh] = -4000.0 -- exploded; the script entity stays in the world
        assert_eq(fieldStatus().CIDREP, nil, 'the newsroom does not show a wreck')
        assert_true(request(), 'a reporter whose van blew up can take another')
        assert_eq(alive[veh], nil, 'the wreck was deleted by the server')
        assert_eq(Mock.deleted[1], veh)
        assert_eq(removedInv[1], 'trunk-' .. plate, 'the trunk of the wreck goes with it')
        local stored = Mock.clientEventsNamed('pfm-newsjob:client:vehicleStored')
        assert_eq(#stored, 1)
        assert_eq(stored[1].args[1], plate, 'the client drops the keys of the wreck')
        local newVeh, newPlate = issuedVehicle()
        assert_true(newVeh ~= veh and alive[newVeh])
        assert_true(newPlate ~= nil)
        assert_eq(select(2, request()), 'vehicle_out')
    end)

    it('a helicopter that crashed and burnt away from the helipad frees the lock', function()
        local HELI = Config.Locations.heli.coords
        at(REP, HELI)
        Mock.clock = Mock.clock + 60
        assert_true(NewsJob.RequestVehicle(REP, 'heli', 'frogger'))
        local heli = issuedVehicle()
        at(heli, vector3(1500, -2000, 20))
        Mock.vehicleOf[REP] = nil
        engineHealth[heli] = -4000.0
        Mock.clock = Mock.clock + 60
        assert_true(NewsJob.RequestVehicle(REP, 'heli', 'frogger'))
        assert_eq(alive[heli], nil)
    end)

    it('storing a wreck frees the lock and deletes it', function()
        assert_true(request())
        local veh = issuedVehicle()
        engineHealth[veh] = -4000.0
        Mock.vehicleOf[REP] = nil
        at(veh, vector3(800, 800, 30))
        local ok, how = NewsJob.StoreVehicle(REP)
        assert_true(ok)
        assert_eq(how, 'gone')
        assert_eq(alive[veh], nil)
        assert_true(request())
    end)

    it('a failed spawn frees the lock at once', function()
        spawnFails = true
        assert_eq(select(2, request()), 'spawn_failed')
        assert_eq(fieldStatus().CIDREP, nil)
        assert_eq(#Mock.clientEventsNamed('pfm-newsjob:client:spawnVehicle'), 0)
        assert_eq(#items, 0, 'no trunk for a van that was never spawned')
        spawnFails = false
        assert_true(request())
    end)

    it('the lock is taken before the spawn yields', function()
        Config.SpawnCooldown = 0
        local second
        duringSpawn = function() second = { NewsJob.RequestVehicle(REP, 'vehicle', 'rumpo') } end
        assert_true(request())
        assert_false(second[1])
        assert_eq(second[2], 'vehicle_out')
        local spawned = 0
        for _ in pairs(alive) do spawned = spawned + 1 end
        assert_eq(spawned, 1)
    end)

    it('a reporter who drops while the van spawns does not leave a van behind', function()
        duringSpawn = function() Mock.fireEvent('playerDropped', REP) end
        assert_eq(select(2, request()), 'cancelled')
        assert_eq(#Mock.deleted, 1)
        assert_eq(next(alive), nil)
    end)
end)

describe('fix9hq newsjob: storing is decided by the server', function()
    it('the client store event alone does not free the lock when the van is away from the garage', function()
        assert_true(request())
        local veh = issuedVehicle()
        at(veh, vector3(500, 500, 30)) -- left out in the city
        at(REP, VAN)                   -- reporter walks back to the garage
        Mock.vehicleOf[REP] = nil
        Mock.fireNet('pfm-newsjob:server:vehicleStored', REP)
        assert_true(alive[veh], 'the van is not deleted')
        assert_eq(fieldStatus().CIDREP.label, 'Rumpo')
        -- a van left far away (stolen, sunk, stuck) is retired by the server on the next request
        assert_true(request())
        assert_eq(alive[veh], nil, 'the server deleted the van left in the city')
        local newVeh = issuedVehicle()
        assert_true(newVeh ~= veh and alive[newVeh], 'a new van was issued')
    end)

    it('a van parked near the reporter still blocks a new one (it has to be stored)', function()
        assert_true(request())
        local veh = issuedVehicle()
        at(veh, vector3(VAN.x + 10.0, VAN.y, VAN.z))
        at(REP, VAN)
        Mock.vehicleOf[REP] = nil
        assert_eq(select(2, request()), 'vehicle_out')
        assert_true(alive[veh])
    end)

    it('a van the reporter is sitting in is never retired by a request', function()
        assert_true(request())
        local veh = issuedVehicle()
        at(veh, vector3(500, 500, 30))
        at(REP, VAN)
        Mock.vehicleOf[REP] = veh
        assert_eq(select(2, request()), 'vehicle_out')
        assert_true(alive[veh])
    end)

    it('the van at the garage with the reporter far from it is not stored', function()
        assert_true(request())
        local veh = issuedVehicle()
        Mock.vehicleOf[REP] = nil
        at(REP, vector3(VAN.x + 40, VAN.y, VAN.z))
        assert_eq(select(2, NewsJob.StoreVehicle(REP)), 'too_far')
        assert_true(alive[veh])
    end)

    it('the van at its garage point with the reporter in it is deleted by the server and the lock freed', function()
        assert_true(request())
        local veh, plate = issuedVehicle()
        at(veh, vector3(VAN.x + 3, VAN.y, VAN.z))
        Mock.fireNet('pfm-newsjob:server:vehicleStored', REP)
        assert_eq(alive[veh], nil, 'the server deleted the van')
        assert_eq(Mock.deleted[1], veh)
        assert_eq(#Mock.clientEventsNamed('pfm-newsjob:client:vehicleStored'), 1)
        assert_eq(removedInv[1], 'trunk-' .. plate, 'the stored van\'s trunk goes with it')
        assert_eq(fieldStatus().CIDREP, nil)
        assert_true(request())
    end)

    it('a reporter with no vehicle out cannot store anything', function()
        assert_eq(select(2, NewsJob.StoreVehicle(REP)), 'no_vehicle')
        assert_eq(#Mock.deleted, 0)
    end)
end)

describe('fix9hq newsjob: trunk items only for a van the server just issued', function()
    it('the server stocks the van it spawned once, with the server plate', function()
        assert_true(request())
        local veh, plate = issuedVehicle()
        assert_eq(Mock.plates[veh], plate, 'the server set the plate')
        assert_true(inventories['trunk-' .. plate])
        assert_eq(#items, 3)
        for _, it in ipairs(items) do assert_eq(it.id, 'trunk-' .. plate) end
    end)

    it('the helicopter gets no trunk', function()
        at(REP, Config.Locations.heli.coords)
        Mock.clock = Mock.clock + 60
        assert_true(NewsJob.RequestVehicle(REP, 'heli', 'frogger'))
        assert_eq(#items, 0)
    end)

    it('no client event stocks a trunk for a plate it names', function()
        assert_true(request())
        local _, plate = issuedVehicle()
        local before = #items
        assert_eq(Mock.netHandlers['qb-newsjob:server:addVehicleItems'], nil, 'the client stocking event is gone')
        assert_eq(NewsJob.StockTrunk, nil)
        assert_eq(#items, before)
        assert_true(plate ~= nil)
    end)
end)
