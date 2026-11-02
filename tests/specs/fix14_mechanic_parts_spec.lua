-- pf-mechanicjob performance parts (server/main.lua, shared/performance_parts.lua):
--  MECH-X3 the item alone decides the mod (one cheap part used to fit any upgrade); fitting is
--          mechanic work with a toolbox, at the car, engine off.
--  MECH-X2 a part comes off only through the server: a mechanic with a toolbox at the car, engine
--          off; the server sets the slot back to stock on every client and in the saved props, and
--          hands over the part it has on record for that car and slot, once.
--  MECH-2  the record is per car and slot in the database (fix14_mechanic_parts_realdb_spec.lua
--          checks it survives a restart).
load_resource('tests/lua/fivem_mocks.lua')
QBCore = QBCoreMock

local states = {}
local stateMeta = { __index = { set = function(self, k, v) rawset(self, k, v) end } }
function Entity(e)
    states[e] = states[e] or { state = setmetatable({}, stateMeta) }
    return states[e]
end
local existing, engineOn = {}, {}
function DoesEntityExist(e) return existing[e] == true end
function GetAllVehicles() local out = {} for e in pairs(existing) do out[#out + 1] = e end return out end
function GetIsVehicleEngineRunning(v) return engineOn[v] == true end

-- pf_mech_fitted_parts and the saved props writes
local fitted, propWrites = {}, {}
MySQL.scalar = { await = function(q, p)
    if q:find('FROM pf_mech_fitted_parts', 1, true) then return fitted[p[1] .. '|' .. p[2]] end
end }
MySQL.query = { await = function(q, p)
    if q:find('INTO pf_mech_fitted_parts', 1, true) then
        if not (q:find('INSERT IGNORE', 1, true) and fitted[p[1] .. '|' .. p[2]]) then fitted[p[1] .. '|' .. p[2]] = p[3] end
    end
    return {}
end }
MySQL.update = { await = function(q, p)
    if q:find('DELETE FROM pf_mech_fitted_parts', 1, true) then
        local key = p[1] .. '|' .. p[2]
        if fitted[key] == p[3] then fitted[key] = nil return 1 end
        return 0
    end
    if q:find('UPDATE player_vehicles SET mods = JSON_SET', 1, true) then
        propWrites[#propWrites + 1] = { key = q:match("'%$%.([%w_]+)'"), value = p[1], plate = p[2] }
        return 1
    end
    return 0
end }

local function withInventory(p, items)
    p.inv = items or {}
    p.full = false
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
        if p.full then return false end
        p.inv[name] = (p.inv[name] or 0) + (n or 1)
        return true
    end
    return p
end

Config = nil
load_resource('[pfscripts]/pf-mechanicjob/config.lua')
load_resource('[pfscripts]/pf-mechanicjob/shared/debug.lua')
Config.Debug = false
load_resource('[pfscripts]/pf-mechanicjob/shared/performance_parts.lua')
load_resource('[pfscripts]/pf-mechanicjob/server/main.lua')
PFMech.SchemaReady = true

local MECH, CIV = 1, 2
local CAR, FAR_CAR = 500, 501
local HERE = vector3(100.0, 100.0, 30.0)

local function count(src, item) return Mock.players[src].inv[item] or 0 end
local function fit(src, item, veh, extra)
    local data = { item = item, vehicle = veh or CAR }
    for k, v in pairs(extra or {}) do data[k] = v end
    Mock.fireNet('pf_mech:server:applyPerformanceUpgrade', src, data)
end
local function takeOff(src, slot, veh) Mock.fireNet('pf-mechanicjob:server:returnUpgradeItem', src, slot, veh or CAR) end
local function upgrades() return Mock.clientEventsNamed('pf_mech:client:upgradeApplied') end
local function last() local u = upgrades() return u[#u] and u[#u].args[1] end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords, Mock.plates = {}, {}, {}
    states, engineOn, fitted, propWrites = {}, {}, {}, {}
    existing = { [CAR] = true, [FAR_CAR] = true }
    withInventory(Mock.newPlayer(MECH, 'MECH1'), { toolbox = 1, engine1 = 2, engine2 = 1, engine4 = 1, headlights = 1, turbo = 1 })
        .PlayerData.job = { name = 'mechanic', onduty = true }
    withInventory(Mock.newPlayer(CIV, 'CIV1'), { toolbox = 1, engine1 = 1 })
    Mock.coords[MECH], Mock.coords[CIV], Mock.coords[CAR] = HERE, HERE, HERE
    Mock.coords[FAR_CAR] = vector3(900.0, 900.0, 30.0)
    Mock.plates[CAR], Mock.plates[FAR_CAR] = 'TUNED001', 'FAR00001'
end

describe('MECH-X3 the item decides the mod', function()
    it('engine1 with a client asking for engine level 4 fits engine level 1', function()
        fit(MECH, 'engine1', CAR, { modType = 11, modIndex = 3 })
        assert_eq(#upgrades(), 1)
        assert_eq(last().modType, 11)
        assert_eq(last().modIndex, 0)
        assert_eq(count(MECH, 'engine1'), 1)
        assert_eq(fitted['TUNED001|engine'], 'engine1')
    end)

    it('headlights never fit a turbo', function()
        fit(MECH, 'headlights', CAR, { modType = 18, modIndex = 0, isToggle = true })
        assert_eq(last().modType, 22)
        assert_eq(last().isToggle, true)
        assert_eq(fitted['TUNED001|xenon'], 'headlights')
        assert_eq(fitted['TUNED001|turbo'], nil)
    end)

    it('only a mechanic with a toolbox, at the car, engine off', function()
        fit(CIV, 'engine1')
        fit(MECH, 'engine1', FAR_CAR)
        engineOn[CAR] = true
        fit(MECH, 'engine1')
        engineOn[CAR] = false
        Mock.players[MECH].inv.toolbox = 0
        fit(MECH, 'engine1')
        assert_eq(#upgrades(), 0)
        assert_eq(count(CIV, 'engine1'), 1)
        assert_eq(count(MECH, 'engine1'), 2)
    end)

    it('fitting over a recorded part gives that part back (a swap)', function()
        fit(MECH, 'engine2')
        fit(MECH, 'engine4')
        assert_eq(fitted['TUNED001|engine'], 'engine4')
        assert_eq(count(MECH, 'engine2'), 1, 'engine2 came back out')
        assert_eq(count(MECH, 'engine4'), 0)
        assert_eq(propWrites[#propWrites].key, 'modEngine')
        assert_eq(propWrites[#propWrites].value, 3)
    end)
end)

describe('MECH-X2 taking a part off', function()
    it('the server sets the slot to stock everywhere, then hands over its recorded part, once', function()
        fit(MECH, 'engine4')
        takeOff(MECH, 'engine')
        assert_eq(count(MECH, 'engine4'), 1)
        assert_eq(last().remove, true)
        assert_eq(last().modType, 11)
        assert_eq(propWrites[#propWrites].key, 'modEngine')
        assert_eq(propWrites[#propWrites].value, -1)
        takeOff(MECH, 'engine')
        assert_eq(count(MECH, 'engine4'), 1, 'nothing more on record')
    end)

    it('asking for a different item than the one fitted returns the fitted one only', function()
        fit(MECH, 'engine1')
        takeOff(MECH, 'engine5')                                 -- the slot of engine5 is 'engine'
        assert_eq(count(MECH, 'engine5'), 0)
        assert_eq(count(MECH, 'engine1'), 2)
    end)

    it('a passer-by, a car far away or a running engine: nothing comes off', function()
        fit(MECH, 'turbo')
        local before = #upgrades()
        takeOff(CIV, 'turbo')
        takeOff(MECH, 'turbo', FAR_CAR)
        engineOn[CAR] = true
        takeOff(MECH, 'turbo')
        assert_eq(#upgrades(), before)
        assert_eq(count(CIV, 'turbo'), 0)
        assert_eq(fitted['TUNED001|turbo'], 'turbo')
    end)

    it('with no room for the part it stays on the car (no stock reset, record kept)', function()
        fit(MECH, 'engine2')
        local before = #upgrades()
        Mock.players[MECH].full = true
        takeOff(MECH, 'engine')
        assert_eq(#upgrades(), before)
        assert_eq(fitted['TUNED001|engine'], 'engine2')
    end)

    it('a part fitted before the records existed comes off without an item', function()
        takeOff(MECH, 'brakes')
        assert_eq(last().remove, true)
        assert_eq(last().modType, 12)
        assert_eq(count(MECH, 'brakes1') + count(MECH, 'brakes2') + count(MECH, 'brakes3'), 0)
    end)
end)
