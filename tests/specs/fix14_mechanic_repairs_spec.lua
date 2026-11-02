-- pf-mechanicjob repairs and cosmetic parts (server/main.lua, server/cosmetics.lua):
--  MECH-3  pf_mech:server:attemptRepair: a mechanic (or a public repair kit holder with a toolbox)
--          standing at the car, a known part, a sane amount and wheel; nothing is taken before the
--          checks, and nothing for a car that is not there. The repair is recorded per car.
--  MECH-X4 applyMod: a cosmetic item, only its own mod types (never engine, armour...), a mechanic
--          at the car; paint and tint only send values from fixed ranges for a car beside the player.
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
    p.Functions.AddItem = function(name, n) p.inv[name] = (p.inv[name] or 0) + (n or 1) return true end
    return p
end

Config = nil
load_resource('[pfscripts]/pf-mechanicjob/config.lua')
load_resource('[pfscripts]/pf-mechanicjob/shared/debug.lua')
Config.Debug = false
load_resource('[pfscripts]/pf-mechanicjob/shared/performance_parts.lua')
load_resource('[pfscripts]/pf-mechanicjob/server/main.lua')
load_resource('[pfscripts]/pf-mechanicjob/server/cosmetics.lua')

local MECH, CIV, KIT = 1, 2, 3
local CAR, FAR_CAR = 500, 501
local HERE = vector3(100.0, 100.0, 30.0)

local function count(src, item) return Mock.players[src].inv[item] or 0 end
local function repair(src, veh, part, n, wheel) return Mock.callCallback('pf_mech:server:attemptRepair', src, veh, part, n, wheel) end
local function applied() return #Mock.clientEventsNamed('pf_mech:applyPart') end

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 1000
    Mock.players, Mock.coords, Mock.plates = {}, {}, {}
    states, engineOn = {}, {}
    PFMech.RepairLog, PFMech.RecentRepairs = {}, {}
    existing = { [CAR] = true, [FAR_CAR] = true }
    withInventory(Mock.newPlayer(MECH, 'MECH1'), { engine_part = 3, body_part = 3, brake_pads = 4, spoiler = 2, water_bottle = 1, toolbox = 1 })
        .PlayerData.job = { name = 'mechanic', onduty = true }
    withInventory(Mock.newPlayer(CIV, 'CIV1'), { engine_part = 3, spoiler = 1, paintcan = 2, tint_supplies = 2 })
    withInventory(Mock.newPlayer(KIT, 'KIT1'), { engine_part = 1, repair_kit = 1, toolbox = 1 })
    Mock.coords[MECH], Mock.coords[CIV], Mock.coords[KIT], Mock.coords[CAR] = HERE, HERE, HERE, HERE
    Mock.coords[FAR_CAR] = vector3(2000.0, 2000.0, 30.0)
    Mock.plates[CAR], Mock.plates[FAR_CAR] = 'CAR00001', 'FAR00001'
    Entity(CAR).state.partDamage = { engine_part = 80, body_part = 60, brakes = 75 }
    Entity(FAR_CAR).state.partDamage = { engine_part = 80 }
end

describe('MECH-3 attemptRepair', function()
    it('a non-mechanic without a repair kit repairs nothing and keeps the part', function()
        assert_eq(repair(CIV, CAR, 'engine_part', 1), false)
        assert_eq(count(CIV, 'engine_part'), 3)
        assert_eq(Entity(CAR).state.partDamage.engine_part, 80)
        assert_eq(applied(), 0)
    end)

    it('a car across the map is out of reach (the getaway car during a chase)', function()
        assert_eq(repair(MECH, FAR_CAR, 'engine_part', 1), false)
        assert_eq(count(MECH, 'engine_part'), 3)
        assert_eq(Entity(FAR_CAR).state.partDamage.engine_part, 80)
    end)

    it('a car that is not there takes nothing', function()
        existing[CAR] = nil
        assert_eq(repair(MECH, CAR, 'engine_part', 1), false)
        assert_eq(count(MECH, 'engine_part'), 3)
    end)

    it('only known parts, amounts 1-10, wheels from the real set', function()
        assert_eq(repair(MECH, CAR, 'water_bottle', 1), false)       -- any item name used to be consumed
        assert_eq(count(MECH, 'water_bottle'), 1)
        for _, n in ipairs({ 0, -1, 1.5, 11, 'x' }) do assert_eq(repair(MECH, CAR, 'brakes', n), false) end
        assert_eq(repair(MECH, CAR, 'brakes', 1, 99), false)
        assert_eq(count(MECH, 'brake_pads'), 4)
        assert_eq(applied(), 0)
    end)

    it('a mechanic at the car repairs it with parts; the repair is recorded on that car', function()
        assert_eq(repair(MECH, CAR, 'engine_part', 1), true)
        assert_eq(Entity(CAR).state.partDamage.engine_part, 0)
        assert_eq(count(MECH, 'engine_part'), 2)
        assert_eq(repair(MECH, CAR, 'brakes', 2, 1), true)
        assert_eq(Entity(CAR).state.partDamage.brakes, 25)
        assert_eq(count(MECH, 'brake_pads'), 2)
        local log = PFMech.RepairLog[CAR]
        assert_eq(#log, 2)
        assert_eq(log[1].src, MECH)
        assert_eq(log[1].part, 'engine_part')
        assert_eq(PFMech.RecentRepairs[MECH].veh, CAR)
        assert_eq(applied(), 2)
        assert_eq(Mock.clientEventsNamed('pf_mech:applyPart')[2].args[1].wheel, 1)
    end)

    it('the public repair kit still lets its holder fit their own part (wear names map to parts)', function()
        assert_eq(repair(KIT, CAR, 'engine_part', 1), true)
        assert_eq(count(KIT, 'engine_part'), 0)
        Entity(CAR).state.partDamage.oil = 90
        Mock.players[KIT].inv.engine_oil = 1
        assert_eq(repair(KIT, CAR, 'oil', 1), true)                 -- the kit picks the worst wear by name
        assert_eq(Entity(CAR).state.partDamage.oil, 0)
        Mock.players[KIT].inv.toolbox = 0
        Mock.players[KIT].inv.engine_part = 1
        assert_eq(repair(KIT, CAR, 'engine_part', 1), false, 'no toolbox')
    end)

    it('the unchecked usePart event is gone', function()
        assert_eq(Mock.netHandlers['pf_mech:usePart'], nil)
    end)
end)

describe('MECH-X4 cosmetic mods', function()
    local function mod(src, data) Mock.fireNet('pf_mech:server:applyMod', src, data) end
    local function mods() return Mock.clientEventsNamed('pf_mech:client:modApplied') end

    it('a bottle of water never fits engine level 4', function()
        mod(MECH, { item = 'water_bottle', vehicle = CAR, modType = 11, modIndex = 3 })
        assert_eq(#mods(), 0)
        assert_eq(count(MECH, 'water_bottle'), 1)
    end)

    it('a cosmetic item sets only its own mod types, never a performance slot', function()
        mod(MECH, { item = 'spoiler', vehicle = CAR, modType = 11, modIndex = 3 })   -- engine
        mod(MECH, { item = 'spoiler', vehicle = CAR, modType = 16, modIndex = -1 })  -- armour off
        mod(MECH, { item = 'spoiler', vehicle = CAR, modType = 0, modIndex = 999 })  -- out of range
        mod(MECH, { item = 'spoiler', vehicle = CAR, modType = 0, modIndex = 1.5 })
        assert_eq(#mods(), 0)
        assert_eq(count(MECH, 'spoiler'), 2)
        mod(MECH, { item = 'spoiler', vehicle = CAR, modType = 0, modIndex = 2 })
        assert_eq(#mods(), 1)
        assert_eq(mods()[1].args[1].modType, 0)
        assert_eq(mods()[1].args[1].modIndex, 2)
        assert_eq(count(MECH, 'spoiler'), 1)
    end)

    it('a mechanic at the car with the engine off; others are refused', function()
        mod(CIV, { item = 'spoiler', vehicle = CAR, modType = 0, modIndex = 1 })
        mod(MECH, { item = 'spoiler', vehicle = FAR_CAR, modType = 0, modIndex = 1 })
        engineOn[CAR] = true
        mod(MECH, { item = 'spoiler', vehicle = CAR, modType = 0, modIndex = 1 })
        assert_eq(#mods(), 0)
        assert_eq(count(CIV, 'spoiler'), 1)
        assert_eq(count(MECH, 'spoiler'), 2)
    end)

    it('the dead applyPaint copy and applyWheels are gone from main.lua', function()
        local src = __readfile('[pfscripts]/pf-mechanicjob/server/main.lua')
        assert_eq(src:find("RegisterNetEvent('pf_mech:server:applyWheels'", 1, true), nil)
        assert_eq(src:find("RegisterNetEvent('pf_mech:server:applyPaint'", 1, true), nil)
    end)
end)

describe('MECH-X4 paint and tint (public items)', function()
    local function paint(src, data) Mock.fireNet('pf_mech:server:applyPaint', src, data) end
    local function tint(src, data) Mock.fireNet('pf_mech:server:applyTint', src, data) end

    it('only fixed values for a car beside the player are sent on', function()
        paint(CIV, { vehicle = FAR_CAR, paintType = 'primary', colorType = 'classic', colorId = 12 })
        paint(CIV, { vehicle = CAR, paintType = 'engine', colorType = 'classic', colorId = 12 })
        paint(CIV, { vehicle = CAR, paintType = 'primary', colorType = 'classic', colorId = 5000 })
        paint(CIV, { vehicle = CAR, paintType = 'primary', colorType = 'classic', colorId = 12, finish = 'x' })
        tint(CIV, { vehicle = CAR, tintLevel = 99 })
        tint(CIV, { vehicle = FAR_CAR, tintLevel = 2 })
        assert_eq(#Mock.clientEventsNamed('pf_mech:client:syncVehiclePaint'), 0)
        assert_eq(#Mock.clientEventsNamed('pf_mech:client:syncVehicleTint'), 0)
        assert_eq(count(CIV, 'paintcan'), 2)
        assert_eq(count(CIV, 'tint_supplies'), 2)
        paint(CIV, { vehicle = CAR, paintType = 'primary', colorType = 'classic', colorId = 12, finish = 'matte', extra = 'junk' })
        tint(CIV, { vehicle = CAR, tintLevel = 2 })
        local sent = Mock.clientEventsNamed('pf_mech:client:syncVehiclePaint')
        assert_eq(#sent, 1)
        assert_eq(sent[1].args[1].colorId, 12)
        assert_eq(sent[1].args[1].extra, nil, 'only the server-built fields')
        assert_eq(Mock.clientEventsNamed('pf_mech:client:syncVehicleTint')[1].args[2], 2)
        assert_eq(count(CIV, 'paintcan'), 1)
        assert_eq(count(CIV, 'tint_supplies'), 1)
    end)
end)
