-- pf-mechanicjob items and car changes (server/main.lua, server/nos.lua, server/advanced_systems.lua):
-- nothing hands out items it didn't take, and car changes need the player at (or in) that car.
load_resource('tests/lua/fivem_mocks.lua')
QBCore = QBCoreMock

-- stubs the shared mocks lack
local states = {}
local stateMeta = { __index = { set = function(self, k, v) rawset(self, k, v) end } }
function Entity(e)
    states[e] = states[e] or { state = setmetatable({}, stateMeta) }
    return states[e]
end
local vehicles = {}
function GetAllVehicles() return vehicles end
local existing = {}
function DoesEntityExist(e) return existing[e] == true end
function GetIsVehicleEngineRunning() return false end

-- pf_mech_fitted_parts, the only table these handlers use: [plate .. '|' .. slot] = item
local fitted = {}
local baseScalar, baseQuery, baseUpdate = MySQL.scalar, MySQL.query, MySQL.update
MySQL.scalar = { await = function(q, p)
    if q:find('FROM pf_mech_fitted_parts', 1, true) then return fitted[p[1] .. '|' .. p[2]] end
    return baseScalar.await(q, p)
end }
MySQL.query = { await = function(q, p)
    if q:find('INTO pf_mech_fitted_parts', 1, true) then
        if not (q:find('INSERT IGNORE', 1, true) and fitted[p[1] .. '|' .. p[2]]) then fitted[p[1] .. '|' .. p[2]] = p[3] end
        return {}
    end
    return baseQuery.await(q, p)
end }
MySQL.update = { await = function(q, p)
    if q:find('DELETE FROM pf_mech_fitted_parts', 1, true) then
        local key = p[1] .. '|' .. p[2]
        if fitted[key] == p[3] then fitted[key] = nil return 1 end
        return 0
    end
    return baseUpdate.await(q, p)
end }

local function withInventory(p, items)
    p.inv = items or {}
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
    p.Functions.AddItem = function(name, n)
        p.inv[name] = (p.inv[name] or 0) + (n or 1)
        return true
    end
    return p
end

Config = nil
load_resource('[pfscripts]/pf-mechanicjob/config.lua')
load_resource('[pfscripts]/pf-mechanicjob/shared/debug.lua')
Config.Debug = false
Config.AdvancedSystems.Enabled = true
Config.AdvancedSystems.ChopShop.Enabled = true
QBCoreMock.Shared.Items.emptynos = { name = 'emptynos', label = 'Empty NOS' }
QBCoreMock.Shared.Items.nos = { name = 'nos', label = 'NOS' }
load_resource('[pfscripts]/pf-mechanicjob/shared/performance_parts.lua')
load_resource('[pfscripts]/pf-mechanicjob/server/main.lua')
load_resource('[pfscripts]/pf-mechanicjob/server/nos.lua')
load_resource('[pfscripts]/pf-mechanicjob/server/advanced_systems.lua')
PFMech.SchemaReady = true

local MECH, CIV = 1, 2
local CAR, FAR_CAR = 500, 501
local SHOP = vector3(100.0, 100.0, 30.0)
local CHOP = Config.AdvancedSystems.ChopShop.Zones[1].coords

local function count(src, item) return Mock.players[src].inv[item] or 0 end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords, Mock.vehicleOf, Mock.plates, Mock.deleted = {}, {}, {}, {}, {}
    states = {}
    withInventory(Mock.newPlayer(MECH, 'CIDM'), { toolbox = 1 }).PlayerData.job = { name = 'mechanic', onduty = true, grade = { level = 0 } }
    fitted = {}
    withInventory(Mock.newPlayer(CIV, 'CIDC')).PlayerData.job = { name = 'unemployed' }
    vehicles = { CAR, FAR_CAR }
    existing = { [CAR] = true, [FAR_CAR] = true }
    Mock.plates[CAR], Mock.plates[FAR_CAR] = ' DIESEL1 ', 'FARAWAY1'
    Mock.coords[MECH], Mock.coords[CIV], Mock.coords[CAR] = SHOP, SHOP, SHOP
    Mock.coords[FAR_CAR] = vector3(900.0, 900.0, 30.0)
end

describe('DPF removal', function()
    it('a made-up plate gives no DPF item', function()
        for i = 1, 5 do Mock.fireNet('pf_mech:dpf:remove', MECH, 'FAKE' .. i) end
        assert_eq(count(MECH, 'dpf'), 0)
    end)
    it('a car far away or a non-mechanic gives no DPF item', function()
        Mock.fireNet('pf_mech:dpf:remove', MECH, 'FARAWAY1')
        Mock.fireNet('pf_mech:dpf:remove', CIV, 'DIESEL1')
        assert_eq(count(MECH, 'dpf'), 0)
        assert_eq(count(CIV, 'dpf'), 0)
    end)
    it('a mechanic at the car gets one, once', function()
        Mock.fireNet('pf_mech:dpf:remove', MECH, 'DIESEL1')
        Mock.fireNet('pf_mech:dpf:remove', MECH, 'DIESEL1')
        assert_eq(count(MECH, 'dpf'), 1)
    end)
end)

describe('performance part returns', function()
    it('a part never fitted with an item is not handed back', function()
        Mock.fireNet('pf-mechanicjob:server:returnUpgradeItem', MECH, 'engine5', CAR)
        Mock.fireNet('pf-mechanicjob:server:returnUpgradeItem', MECH, 'turbo', CAR)
        assert_eq(count(MECH, 'engine5'), 0)
        assert_eq(count(MECH, 'turbo'), 0)
    end)
    it('a fitted part comes back once, from that car only', function()
        Mock.players[MECH].inv.engine3 = 1
        Mock.fireNet('pf_mech:server:applyPerformanceUpgrade', MECH, { item = 'engine3', vehicle = CAR, modType = 11, modIndex = 2 })
        assert_eq(count(MECH, 'engine3'), 0)
        Mock.fireNet('pf-mechanicjob:server:returnUpgradeItem', MECH, 'engine', FAR_CAR)  -- other car, far away
        assert_eq(count(MECH, 'engine3'), 0)
        Mock.fireNet('pf-mechanicjob:server:returnUpgradeItem', MECH, 'engine', CAR)
        Mock.fireNet('pf-mechanicjob:server:returnUpgradeItem', MECH, 'engine', CAR)
        assert_eq(count(MECH, 'engine3'), 1)
    end)
    it('upgrades and mods only reach a car the player is at', function()
        Mock.players[MECH].inv.engine3 = 1
        Mock.players[MECH].inv.spoiler = 1
        Mock.fireNet('pf_mech:server:applyPerformanceUpgrade', MECH, { item = 'engine3', vehicle = FAR_CAR, modType = 11, modIndex = 2 })
        Mock.fireNet('pf_mech:server:applyMod', MECH, { item = 'spoiler', vehicle = FAR_CAR, modType = 0, modIndex = 1 })
        assert_eq(#Mock.clientEventsNamed('pf_mech:client:upgradeApplied'), 0)
        assert_eq(#Mock.clientEventsNamed('pf_mech:client:modApplied'), 0)
        assert_eq(count(MECH, 'engine3'), 1)
        Mock.fireNet('pf_mech:server:applyMod', MECH, { item = 'spoiler', vehicle = CAR, modType = 0, modIndex = 1 })
        assert_eq(#Mock.clientEventsNamed('pf_mech:client:modApplied'), 1)
    end)
end)

describe('NOS', function()
    it('no empty bottle on request; a bottle is only taken when it is fitted to a car', function()
        assert_eq(Mock.netHandlers['pf_mech:nos:giveEmpty'], nil, 'the request is gone')
        Mock.players[CIV].inv.nos = 1
        Mock.fireNet('pf_mech:nos:consumeBottle', CIV)                -- no car
        assert_eq(count(CIV, 'nos'), 1)
        assert_eq(count(CIV, 'emptynos'), 0)
    end)
    it('one empty bottle per bottle the server drains, to the driver', function()
        Entity(CAR).state.nos = { has = true, level = 10, levelSel = 1 }
        Mock.vehicleOf[CIV] = CAR
        Mock.fireNet('pf_mech:nos:boost', CIV, CAR, true)
        for _ = 1, 3 do Mock.clock = Mock.clock + 1; PFMech.NosDrainTick() end
        assert_eq(Entity(CAR).state.nos.has, false)
        Mock.fireNet('pf_mech:nos:boost', CIV, CAR, false)
        Mock.fireNet('pf_mech:nos:boost', CIV, CAR, true)              -- nothing left to boost
        for _ = 1, 3 do Mock.clock = Mock.clock + 1; PFMech.NosDrainTick() end
        assert_eq(count(CIV, 'emptynos'), 1)
    end)
    it('the level falls on the server while the driver boosts; nobody else moves it', function()
        Entity(CAR).state.nos = { has = true, level = 40, levelSel = 1 }
        Mock.fireNet('pf_mech:nos:boost', CIV, CAR, true)             -- not in the car
        Mock.clock = Mock.clock + 1
        PFMech.NosDrainTick()
        assert_eq(Entity(CAR).state.nos.level, 40)
        Mock.vehicleOf[CIV] = CAR
        Mock.fireNet('pf_mech:nos:boost', CIV, CAR, true)
        Mock.clock = Mock.clock + 1
        PFMech.NosDrainTick()
        assert_eq(Entity(CAR).state.nos.level, 40 - Config.NOS.levels[1].drainPerSec)
    end)
    it('wear reports cannot repair a car or reach someone else\'s', function()
        Entity(CAR).state.partDamage = { engine_part = 60, oil = 50 }
        Mock.fireNet('pf_mech:nos:applyDamage', CIV, 'DIESEL1', { engine_part = 5 })   -- not in it
        assert_eq(Entity(CAR).state.partDamage.engine_part, 60)
        Mock.vehicleOf[CIV] = CAR
        Mock.fireNet('pf_mech:nos:applyDamage', CIV, 'DIESEL1', { engine_part = -60, oil = 'x', brakes = 50 })
        assert_eq(Entity(CAR).state.partDamage.engine_part, 60)
        assert_eq(Entity(CAR).state.partDamage.oil, 50)
        assert_eq(Entity(CAR).state.partDamage.brakes, nil)
        Mock.fireNet('pf_mech:nos:applyDamage', CIV, 'DIESEL1', { engine_part = 2 })
        assert_eq(Entity(CAR).state.partDamage.engine_part, 62)
    end)
end)

describe('chop shop', function()
    local function chop(src, payload) Mock.fireNet('pf-mechanicjob:server:advanced:completeChop', src, payload) end
    local function salvage(src) return count(src, 'axleparts') + count(src, 'brake_pads') + count(src, 'engine_part') end
    it('a report with no car pays nothing', function()
        chop(CIV, { plate = 'ANY' })
        chop(CIV, nil)
        assert_eq(salvage(CIV), 0)
    end)
    it('the car must be the one the player sits in, inside a chop zone', function()
        Mock.coords[CAR] = SHOP
        Mock.vehicleOf[CIV] = CAR
        chop(CIV, { netId = CAR })                      -- not in a chop zone
        assert_eq(salvage(CIV), 0)
        Mock.coords[CAR] = CHOP
        Mock.vehicleOf[CIV] = nil
        chop(CIV, { netId = CAR })                      -- not in the car
        assert_eq(salvage(CIV), 0)
    end)
    it('pays once per chop, removes the car, and has a cooldown', function()
        Mock.coords[CAR] = CHOP
        Mock.vehicleOf[CIV] = CAR
        chop(CIV, { netId = CAR })
        local got = salvage(CIV)
        assert_true(got > 0)
        assert_eq(Mock.deleted[1], CAR)
        chop(CIV, { netId = CAR })
        assert_eq(salvage(CIV), got)
    end)
end)
