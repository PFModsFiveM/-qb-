-- pf-mechanicjob: a garage save in flight cannot put an older NOS back (server/garage_sync.lua,
-- server/nos.lua). The 30 s driving save and the garage store used to write the NOS columns with the
-- wear, from a snapshot taken before their database wait; when the bottle was emptied (or used down,
-- or removed) meanwhile, that write landed after the NOS save and the bottle came back full. Now the
-- driving save leaves NOS out, and every NOS write (NOS handlers, admin customs, the garage store)
-- goes through one ordered writer per plate that always ends on the newest state.
-- Database writes can be held here (in flight) and released later, in any order.
load_resource('tests/lua/fivem_mocks.lua')
QBCore = QBCoreMock

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
    for _, c in ipairs(cols) do named[c] = true end
    inserts[#inserts + 1] = named
    local function land()
        local row = rows.diag[p[1]] or {}
        for i, c in ipairs(cols) do row[c] = p[i] end
        rows.diag[p[1]] = row
    end
    if holdWrites and coroutine.isyieldable() then
        local slot = { land = land, co = coroutine.running(), named = named }
        held[#held + 1] = slot
        coroutine.yield()
        return 1
    end
    land()
    return 1
end }
MySQL.update = { await = function() return 1 end }

local function withInventory(p)
    p.inv = {}
    p.Functions.GetItemByName = function(name)
        local n = p.inv[name]
        if n and n > 0 then return { name = name, amount = n, label = name } end
    end
    p.Functions.RemoveItem = function(name, n)
        n = n or 1
        if (p.inv[name] or 0) < n then return false end
        p.inv[name] = p.inv[name] - n
        return true
    end
    p.Functions.AddItem = function(name, n) p.inv[name] = (p.inv[name] or 0) + (n or 1) return true end
    return p
end

Config = nil
load_resource('[pfscripts]/pf-mechanicjob/config.lua')
Config.Debug = false
QBCoreMock.Shared.Items.emptynos = { name = 'emptynos', label = 'Empty NOS' }
QBCoreMock.Shared.Items.nos = { name = 'nos', label = 'NOS' }
load_resource('[pfscripts]/pf-mechanicjob/server/garage_sync.lua')
-- the NOS columns exist (the migration ran: mechanic_saved_state_realdb_spec)
function RunMigrations() return true end
assert(PFMech.GarageSyncSchema())
load_resource('[pfscripts]/pf-mechanicjob/server/nos.lua')
load_resource('[pfscripts]/pf-mechanicjob/server/admin_customs.lua')

local OWNER, ADMIN = 1, 2
local CAR, RESPAWN = 700, 701
local PLATE = 'NOSCAR1'
local HERE = vector3(10.0, 10.0, 30.0)
local props = { plate = PLATE, engineHealth = 990.0, bodyHealth = 1000.0 }

local function st(veh) return Entity(veh).state end
local function saved() return rows.diag[PLATE] end
-- runs a client event in its own thread (it may wait on a held write)
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
local function heldWear() for i, s in ipairs(held) do if s.named.brakes then return table.remove(held, i) end end end
local function heldNos() for i, s in ipairs(held) do if s.named.nos_has then return table.remove(held, i) end end end

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 100000
    for _, v in ipairs({ CAR, RESPAWN }) do Mock.fireEvent('entityRemoved', nil, v) end
    Mock.fireEvent('playerDropped', OWNER)
    Mock.players, Mock.coords, Mock.vehicleOf, Mock.plates, Mock.aces = {}, {}, {}, {}, {}
    states, existing = {}, { [CAR] = true, [RESPAWN] = true }
    Mock.models = { [CAR] = GetHashKey('sultan'), [RESPAWN] = GetHashKey('sultan') }
    Mock.plates[CAR], Mock.plates[RESPAWN] = PLATE, PLATE
    withInventory(Mock.newPlayer(OWNER, 'CID1'))
    withInventory(Mock.newPlayer(ADMIN, 'CID2'))
    Mock.aces[ADMIN] = { ['pf.mechanic.admincustoms'] = true }
    Mock.coords[OWNER], Mock.coords[ADMIN], Mock.coords[CAR], Mock.coords[RESPAWN] = HERE, HERE, HERE, HERE
    rows = {
        veh = { [PLATE] = { vehicle = 'sultan', citizenid = 'CID1' } },
        diag = { [PLATE] = { plate = PLATE, citizenid = 'CID1', brakes = 5, nos_has = 1, nos_level = 60, nos_color = '#FF0000' } },
    }
    held, holdWrites, inserts = {}, false, {}
    -- the owner drives the car, which carries its saved bottle
    Mock.vehicleOf[OWNER] = CAR
    Mock.fireNet('pf_mech:server:restoreVehicleState', OWNER, CAR)
    assert(st(CAR).nos and st(CAR).nos.level == 60)
    st(CAR).partDamage.brakes = 12
end

-- the car is lost before any other save and the plate spawns again
local function respawnNos()
    existing[CAR] = nil
    Mock.fireEvent('entityRemoved', nil, CAR)
    Mock.vehicleOf[OWNER] = RESPAWN
    Mock.fireNet('pf_mech:server:restoreVehicleState', OWNER, RESPAWN)
    return st(RESPAWN).nos
end

describe('the 30 s driving save', function()
    it('never writes the NOS columns', function()
        Mock.fireNet('pf_mech:sync:cacheVehicleState', OWNER, { plate = PLATE, netId = CAR, props = props })
        assert_eq(#inserts, 1)
        assert_true(inserts[1].brakes, 'the wear is saved')
        assert_eq(inserts[1].nos_has, nil, 'no NOS column in the driving save')
        assert_eq(saved().brakes, 12)
    end)

    it('in flight while the bottle is emptied: the bottle stays empty', function()
        holdWrites = true
        local sync = async('pf_mech:sync:cacheVehicleState', OWNER, { plate = PLATE, netId = CAR, props = props })
        local wear = heldWear()
        assert_true(wear ~= nil, 'the driving save is waiting on the database')
        holdWrites = false
        Mock.fireNet('pf_mech:nos:giveEmpty', OWNER, CAR)                 -- the driver used it up
        assert_eq(saved().nos_has, 0)
        release(wear)                                                     -- the older save lands last
        assert_eq(coroutine.status(sync), 'dead')
        assert_eq(saved().nos_has, 0)
        assert_eq(saved().brakes, 12)
        local nos = respawnNos()
        assert_true(not (nos and nos.has), 'no full bottle back')
    end)

    it('in flight while the level falls: the lower level stays', function()
        holdWrites = true
        local wearSync = async('pf_mech:sync:cacheVehicleState', OWNER, { plate = PLATE, netId = CAR, props = props })
        local wear = heldWear()
        holdWrites = false
        Mock.fireNet('pf_mech:nos:updateLevel', OWNER, CAR, 15)
        assert_eq(saved().nos_level, 15)
        release(wear)
        assert_eq(coroutine.status(wearSync), 'dead')
        assert_eq(saved().nos_level, 15)
        assert_eq(respawnNos().level, 15)
    end)
end)

describe('the garage store', function()
    it("saves the car's NOS, with the wear", function()
        st(CAR).nos.level = 44                                            -- used down since the last mark
        Mock.fireNet('qb-garages:server:updateVehicleStats', OWNER, PLATE, 100, 900, 1000)
        assert_eq(saved().brakes, 12)
        assert_eq(saved().nos_has, 1)
        assert_eq(saved().nos_level, 44)
        assert_eq(saved().nos_color, '#FF0000')
    end)

    it('in flight while the bottle is emptied: the bottle stays empty', function()
        holdWrites = true
        local store = async('qb-garages:server:updateVehicleStats', OWNER, PLATE, 100, 900, 1000)
        local wear = heldWear()
        assert_true(wear ~= nil, 'the store is waiting on the database')
        holdWrites = false
        Mock.fireNet('pf_mech:nos:giveEmpty', OWNER, CAR)
        assert_eq(saved().nos_has, 0)
        release(wear)
        assert_eq(coroutine.status(store), 'dead')
        assert_eq(saved().nos_has, 0, 'the store snapshot from before the empty is not written over it')
        assert_eq(saved().nos_level, 0)
        assert_eq(saved().brakes, 12)
    end)

    it('while a NOS save is in flight, the newest state is written last', function()
        holdWrites = true
        local level = async('pf_mech:nos:updateLevel', OWNER, CAR, 35)    -- writes level 35, held
        local first = heldNos()
        assert_true(first ~= nil)
        holdWrites = false
        Mock.fireNet('qb-garages:server:updateVehicleStats', OWNER, PLATE, 100, 900, 1000)   -- queues 35 again
        Mock.fireNet('pf_mech:nos:giveEmpty', OWNER, CAR)                -- queues the empty bottle
        assert_eq(saved().nos_level, 60, 'nothing written past the one in flight')
        release(first)
        assert_eq(coroutine.status(level), 'dead')
        assert_eq(saved().nos_has, 0, 'the empty bottle, written after the level')
        local nosWrites = 0
        for _, named in ipairs(inserts) do if named.nos_has then nosWrites = nosWrites + 1 end end
        assert_eq(nosWrites, 2, 'the store snapshot was replaced by the newer one, not written')
    end)

    it('the NOS is snapped with the wear: a car deleted while the wear is written still saves it', function()
        st(CAR).nos.level = 22
        holdWrites = true
        local store = async('qb-garages:server:updateVehicleStats', OWNER, PLATE, 100, 900, 1000)
        local wear = heldWear()
        holdWrites = false
        existing[CAR] = nil                                               -- the garage deletes the car
        Mock.vehicleOf[OWNER] = nil
        release(wear)
        assert_eq(coroutine.status(store), 'dead')
        assert_eq(saved().nos_has, 1)
        assert_eq(saved().nos_level, 22)
    end)
end)

describe('admin customs NOS changes', function()
    it('are saved at once, so a lost car keeps them', function()
        Mock.fireNet('pf-mechanicjob:server:adminCustoms:vehicleState', ADMIN, CAR, 'nosRemove')
        assert_eq(st(CAR).nos, nil)
        assert_eq(saved().nos_has, 0)
        Mock.fireNet('pf-mechanicjob:server:adminCustoms:vehicleState', ADMIN, CAR, 'nosInstall')
        assert_eq(saved().nos_has, 1)
        assert_eq(saved().nos_level, Config.NOS.capacity or 100)
        Mock.fireNet('pf-mechanicjob:server:adminCustoms:vehicleState', ADMIN, CAR, 'nosRemove')
        local nos = respawnNos()
        assert_true(not (nos and nos.has))
    end)
end)
