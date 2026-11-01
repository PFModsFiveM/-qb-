-- pf-mechanicjob: a repair made while a wear save is in flight is not lost (server/garage_sync.lua).
-- The 30 s driving save (and the garage store) snapped the car's wear, then waited on the database
-- to write it. A repair in that wait was not in the snapshot, so vehicle_diagnostics kept the wear
-- from before the repair, and a car lost before the next save (a crash, a restart) came back worn:
-- the repair was undone. Worse, a newer save queued after the repair could land first and the older
-- one over it. Wear writes now go through one ordered writer per plate, like the NOS ones; every
-- server repair raises the car's wearEpoch (PFMech.MarkWearRepaired), and the writer compares it: a
-- write older than the car's epoch is snapped again before it goes out, and a repair that lands
-- while a write is waiting or running snaps the repaired car at once (PFMech.WearRepaired) and is
-- written straight after it, even if the car is gone by then. A failed write, or an error in the
-- writer, does not leave the plate counted as saved or blocked.
-- Database writes can be held here (in flight) and released later.
load_resource('tests/lua/fivem_mocks.lua')
QBCore = QBCoreMock

-- as in FiveM, every handler of a server event runs (garage_sync.lua and advanced_systems.lua both
-- handle 'entityRemoved'; the shared mock keeps only the last one)
local eventLists = {}
function AddEventHandler(name, fn)
    eventLists[name] = eventLists[name] or {}
    table.insert(eventLists[name], fn)
    Mock.eventHandlers[name] = function(...) for _, f in ipairs(eventLists[name]) do f(...) end end
end

local states = {}
local stateMeta = { __index = { set = function(self, k, v) rawset(self, k, v) end } }
function Entity(e)
    states[e] = states[e] or { state = setmetatable({}, stateMeta) }
    return states[e]
end
local existing = {}
function DoesEntityExist(e) return existing[e] == true end
function GetAllVehicles() local out = {} for e in pairs(existing) do out[#out + 1] = e end return out end
function GetIsVehicleEngineRunning() return false end
function GetPedInVehicleSeat(veh, seat)
    if seat ~= -1 then return 0 end
    for ped, v in pairs(Mock.vehicleOf) do if v == veh then return ped end end
    return 0
end

-- the database: player_vehicles and vehicle_diagnostics rows by plate; an insert lands (its columns
-- replace the row's, as ON DUPLICATE KEY UPDATE) when it completes
local rows, held, holdWrites, inserts
MySQL.single = { await = function(q, p)
    if q:find('FROM vehicle_diagnostics', 1, true) then return rows.diag[p[1]] end
    if q:find('FROM player_vehicles', 1, true) then return rows.veh[p[1]] end
end }
MySQL.insert = { await = function(q, p)
    local colList = q:match('INSERT INTO vehicle_diagnostics %((.-)%)%s*VALUES')
    if not colList then return 0 end
    local cols = {}
    for c in colList:gmatch('`([%w_]+)`') do cols[#cols + 1] = c end
    local named = {}
    for i, c in ipairs(cols) do named[c] = p[i] end
    inserts[#inserts + 1] = named
    local function land()
        local row = rows.diag[p[1]] or {}
        for i, c in ipairs(cols) do row[c] = p[i] end
        rows.diag[p[1]] = row
    end
    if holdWrites and coroutine.isyieldable() then
        held[#held + 1] = { land = land, co = coroutine.running(), named = named }
        coroutine.yield()
        return 1
    end
    land()
    return 1
end }
MySQL.update = { await = function() return 1 end }

Config = nil
load_resource('[pfscripts]/pf-mechanicjob/config.lua')
load_resource('[pfscripts]/pf-mechanicjob/shared/debug.lua')
Config.Debug = false
load_resource('[pfscripts]/pf-mechanicjob/server/garage_sync.lua')
function RunMigrations() return true end
assert(PFMech.GarageSyncSchema())
load_resource('[pfscripts]/pf-mechanicjob/server/nos.lua')
load_resource('[pfscripts]/pf-mechanicjob/server/admin_customs.lua')
-- PFMech.MarkWearRepaired: the wear epoch every server repair raises
load_resource('[pfscripts]/pf-mechanicjob/server/advanced_systems.lua')
assert(PFMech.MarkWearRepaired, 'the repair mark is loaded')

local OWNER, ADMIN = 1, 2
local CAR, RESPAWN = 700, 701
local PLATE = 'WEARCAR'
local HERE = vector3(10.0, 10.0, 30.0)
local props = { plate = PLATE, engineHealth = 990.0, bodyHealth = 1000.0 }

local function st(veh) return Entity(veh).state end
local function saved() return rows.diag[PLATE] end
local function async(name, src, ...)
    local args = { ... }
    local co = coroutine.create(function() Mock.fireNet(name, src, table.unpack(args)) end)
    assert(coroutine.resume(co))
    return co
end
local function release(slot)
    slot.land()
    assert(coroutine.resume(slot.co))
end
-- the held write lands and the save it belongs to reports an error (returned)
local function releaseFailing(slot)
    slot.land()
    local ok, err = coroutine.resume(slot.co)
    assert(not ok, 'the save reports the failure')
    return tostring(err)
end
local function heldWear() for i, s in ipairs(held) do if s.named.brakes ~= nil then return table.remove(held, i) end end end
local function wearWrites() local n = 0 for _, w in ipairs(inserts) do if w.brakes ~= nil then n = n + 1 end end return n end
-- a mechanic's repair of the whole car, the way the server does it (admin customs reset)
local function repair() Mock.fireNet('pf-mechanicjob:server:adminCustoms:vehicleState', ADMIN, CAR, 'resetPartDamage') end
-- the car is lost before any other save and the plate spawns again: what does it come back with?
local function respawnWear()
    existing[CAR] = nil
    Mock.fireEvent('entityRemoved', nil, CAR)
    Mock.vehicleOf[OWNER] = RESPAWN
    Mock.fireNet('pf_mech:server:restoreVehicleState', OWNER, RESPAWN)
    return st(RESPAWN).partDamage
end

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 100000
    for _, v in ipairs({ CAR, RESPAWN }) do Mock.fireEvent('entityRemoved', nil, v) end
    Mock.fireEvent('playerDropped', OWNER)
    Mock.players, Mock.coords, Mock.vehicleOf, Mock.plates, Mock.aces = {}, {}, {}, {}, {}
    states, existing = {}, { [CAR] = true, [RESPAWN] = true }
    Mock.models = { [CAR] = GetHashKey('sultan'), [RESPAWN] = GetHashKey('sultan') }
    Mock.plates[CAR], Mock.plates[RESPAWN] = PLATE, PLATE
    Mock.newPlayer(OWNER, 'CID1')
    Mock.newPlayer(ADMIN, 'CID2')
    Mock.aces[ADMIN] = { ['pf.mechanic.admincustoms'] = true }
    Mock.coords[OWNER], Mock.coords[ADMIN], Mock.coords[CAR], Mock.coords[RESPAWN] = HERE, HERE, HERE, HERE
    rows = {
        veh = { [PLATE] = { vehicle = 'sultan', citizenid = 'CID1' } },
        diag = { [PLATE] = { plate = PLATE, citizenid = 'CID1', brakes = 40, engine_part = 30 } },
    }
    held, holdWrites, inserts = {}, false, {}
    -- the owner drives the worn car
    Mock.vehicleOf[OWNER] = CAR
    Mock.fireNet('pf_mech:server:restoreVehicleState', OWNER, CAR)
    assert(st(CAR).partDamage.brakes == 40)
    st(CAR).partDamage.brakes = 55
end

describe('the 30 s driving save and a repair', function()
    it('without a repair it writes once, as before', function()
        Mock.fireNet('pf_mech:sync:cacheVehicleState', OWNER, { plate = PLATE, netId = CAR, props = props })
        assert_eq(wearWrites(), 1)
        assert_eq(saved().brakes, 55)
    end)

    it('a repair during its database wait is written right after it: the repair is kept', function()
        holdWrites = true
        local sync = async('pf_mech:sync:cacheVehicleState', OWNER, { plate = PLATE, netId = CAR, props = props })
        local wear = heldWear()
        assert_true(wear ~= nil, 'the driving save is waiting on the database')
        assert_eq(wear.named.brakes, 55, 'its snapshot is from before the repair')
        holdWrites = false
        repair()
        assert_eq(st(CAR).partDamage.brakes, 0, 'repaired')
        release(wear)                                                     -- the old snapshot lands
        assert_eq(coroutine.status(sync), 'dead')
        assert_eq(wearWrites(), 2, 'the repaired car is written after it')
        assert_eq(saved().brakes, 0)
        assert_eq(saved().engine_part, 0)
        assert_eq(respawnWear().brakes, 0, 'a car lost now comes back repaired, not worn')
    end)

    it('a garage store after the repair cannot be overtaken by the older driving save', function()
        holdWrites = true
        local sync = async('pf_mech:sync:cacheVehicleState', OWNER, { plate = PLATE, netId = CAR, props = props })
        local wear = heldWear()
        holdWrites = false
        repair()
        -- the owner stores the car while the older save is still in flight
        local store = async('qb-garages:server:updateVehicleStats', OWNER, PLATE, 100, 900, 1000)
        assert_eq(coroutine.status(store), 'dead', 'the store is queued behind the save in flight')
        release(wear)
        assert_eq(coroutine.status(sync), 'dead')
        assert_eq(saved().brakes, 0, 'the newest state is written last')
        assert_eq(saved().engineHealth, 900, "the store's own readings")
        assert_eq(wearWrites(), 2, 'the old save, then the store')
    end)

    it('a save queued before a repair goes out with the repaired wear', function()
        holdWrites = true
        local first = async('pf_mech:sync:cacheVehicleState', OWNER, { plate = PLATE, netId = CAR, props = props })
        local wear = heldWear()
        holdWrites = false
        st(CAR).partDamage.brakes = 60                                    -- driven on
        local store = async('qb-garages:server:updateVehicleStats', OWNER, PLATE, 100, 900, 1000)
        repair()                                                          -- after the store asked
        release(wear)
        assert_eq(coroutine.status(first), 'dead')
        assert_eq(coroutine.status(store), 'dead')
        assert_eq(saved().brakes, 0, "the store's snapshot from before the repair was taken again")
        assert_eq(wearWrites(), 2)
    end)

    it('a car gone by the end of the write still keeps the repair (snapped at the repair)', function()
        holdWrites = true
        local store = async('qb-garages:server:updateVehicleStats', OWNER, PLATE, 100, 900, 1000)
        local wear = heldWear()
        holdWrites = false
        repair()
        existing[CAR] = nil                                               -- the garage deletes the car
        Mock.fireEvent('entityRemoved', nil, CAR)
        release(wear)
        assert_eq(coroutine.status(store), 'dead')
        assert_eq(wearWrites(), 2, 'the repaired car, snapped while it was there, is written after')
        assert_eq(saved().brakes, 0)
        assert_eq(saved().engineHealth, 900, "the store's own readings go with it")
        assert_eq(respawnWear().brakes, 0, 'it comes back repaired')
    end)

    it('a repair with no save in flight writes nothing by itself', function()
        repair()
        assert_eq(wearWrites(), 0, 'the next save writes it')
        Mock.fireNet('pf_mech:sync:cacheVehicleState', OWNER, { plate = PLATE, netId = CAR, props = props })
        assert_eq(saved().brakes, 0)
    end)
end)

describe('the wear writer when a write fails', function()
    it('a queued save that fails is not counted as written: the driving sync saves again at its next report', function()
        holdWrites = true
        local first = async('qb-garages:server:updateVehicleStats', OWNER, PLATE, 100, 900, 1000)
        local wear = heldWear()
        holdWrites = false
        -- the driving sync joins the write in flight and is told its save went out
        st(CAR).partDamage.brakes = 70
        Mock.fireNet('pf_mech:sync:cacheVehicleState', OWNER, { plate = PLATE, netId = CAR, props = props })
        local insert = MySQL.insert.await
        MySQL.insert.await = function(q, p)
            if q:find('`brakes`', 1, true) then MySQL.insert.await = insert; error('database gone') end
            return insert(q, p)
        end
        local err = releaseFailing(wear)                                  -- the queued sync write fails
        assert_true(err:find('database gone', 1, true) ~= nil, 'the newest write failed: the store is told')
        assert_eq(coroutine.status(first), 'dead')
        assert_eq(saved().brakes, 55, 'only the first write landed')
        Mock.fireNet('pf_mech:sync:cacheVehicleState', OWNER, { plate = PLATE, netId = CAR, props = props })
        assert_eq(saved().brakes, 70, 'saved at the next report, not 30 s later')
    end)

    it('an error outside the database write does not leave the plate blocked', function()
        holdWrites = true
        local first = async('qb-garages:server:updateVehicleStats', OWNER, PLATE, 100, 900, 1000)
        local wear = heldWear()
        holdWrites = false
        local store = async('qb-garages:server:updateVehicleStats', OWNER, PLATE, 100, 900, 1000)
        local exists = DoesEntityExist
        DoesEntityExist = function(e) DoesEntityExist = exists; error('native failed') end
        assert_true(releaseFailing(wear):find('native failed', 1, true) ~= nil)
        assert_eq(coroutine.status(first), 'dead')
        assert_eq(coroutine.status(store), 'dead')
        DoesEntityExist = exists
        local before = wearWrites()
        st(CAR).partDamage.brakes = 80
        Mock.fireNet('qb-garages:server:updateVehicleStats', OWNER, PLATE, 100, 900, 1000)
        assert_eq(wearWrites(), before + 1, 'the next save is written (the writer was released)')
        assert_eq(saved().brakes, 80)
    end)
end)
