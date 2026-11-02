-- pf-mechanicjob floor jack and clutch job (MECH-4), diagnostic scan reports (MECH-10)
-- (server/advanced_systems.lua):
--  * a car is lifted only by a mechanic holding a floor jack, at that car (found by net id on the
--    server); the lift is kept per car and forgotten when the car is gone;
--  * the clutch job is started at a lifted car, and completed only for that car, lifted by the same
--    mechanic, beside them, after the steps' minimum time; the pilot bearing method decides what is
--    used (the client's consume list is ignored); the clutch reset reaches only that car's plate;
--  * a scan report for insurance is built from server data: the config's price for a tool the
--    mechanic holds, the plate of the car beside them, at most one per player per 30 s.
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

-- the engineering store: which plates had their clutch replaced
local clutches = {}
function require(name)
    assert(name == 'server.engineering.sv_engineering', name)
    return { ReplaceClutch = function(_, plate, cost) clutches[#clutches + 1] = { plate = plate, cost = cost } return true end }
end

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
Config.AdvancedSystems.Enabled = true
-- what an insurance resource listening on the first configured event receives
local reports = {}
AddEventHandler(Config.AdvancedSystems.Integrations.Insurance.EventNames[1], function(payload) reports[#reports + 1] = payload end)
load_resource('[pfscripts]/pf-mechanicjob/server/advanced_systems.lua')

local MECH, MECH2, CIV = 1, 2, 3
local CAR, FAR_CAR = 500, 501
local HERE = vector3(100.0, 100.0, 30.0)
local KIT = { floor_jack = 1, service_clutch_replacement = 1, transmission_jack = 1, flywheel_service_kit = 1,
    mechanic_hammer = 1, mechanic_socket = 1, sliced_bread = 2, obd_scanner = 1 }

local function copy(t) local o = {} for k, v in pairs(t) do o[k] = v end return o end
local function count(src, item) return Mock.players[src].inv[item] or 0 end
local function lift(src, veh, on) Mock.fireNet('pf-mechanicjob:server:advanced:setLiftState', src, veh, on) end
local function lifted(src, veh) return Mock.callCallback('pf-mechanicjob:server:advanced:getLiftState', src, veh) end
local function startClutch(src, veh) return Mock.callCallback('pf-mechanicjob:server:advanced:startClutch', src, veh) end
local function finish(src, payload) Mock.fireNet('pf-mechanicjob:server:advanced:completeClutchWorkflow', src, payload) end

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 10000
    Mock.players, Mock.coords, Mock.plates = {}, {}, {}
    states, clutches, reports = {}, {}, {}
    existing = { [CAR] = true, [FAR_CAR] = true }
    withInventory(Mock.newPlayer(MECH, 'MECH1'), copy(KIT)).PlayerData.job = { name = 'mechanic', onduty = true }
    withInventory(Mock.newPlayer(MECH2, 'MECH2'), copy(KIT)).PlayerData.job = { name = 'mechanic', onduty = true }
    withInventory(Mock.newPlayer(CIV, 'CIV1'), copy(KIT))
    for _, src in ipairs({ MECH, MECH2, CIV }) do Mock.coords[src] = HERE end
    Mock.coords[CAR], Mock.coords[FAR_CAR] = HERE, vector3(3000.0, 0.0, 30.0)
    Mock.plates[CAR], Mock.plates[FAR_CAR] = 'CLUTCH01', 'XYZ123  '
    for _, v in ipairs({ CAR, FAR_CAR }) do Mock.fireEvent('entityRemoved', nil, v) end
    for _, src in ipairs({ MECH, MECH2, CIV }) do Mock.fireEvent('playerDropped', src) end
end

describe('MECH-4 floor jack', function()
    it('only a mechanic with a jack, at that car, lifts it; any plate string no longer counts', function()
        lift(CIV, CAR, true)
        lift(MECH, FAR_CAR, true)                         -- across the map
        lift(MECH, 'XYZ123', true)                        -- a plate, as the old client sent
        Mock.players[MECH2].inv.floor_jack = 0
        lift(MECH2, CAR, true)
        assert_eq(lifted(MECH, CAR), false)
        assert_eq(lifted(MECH, FAR_CAR), false)
        lift(MECH, CAR, true)
        assert_eq(lifted(MECH, CAR), true)
        lift(MECH, CAR, false)
        assert_eq(lifted(MECH, CAR), false)
    end)

    it('a lift is forgotten when the car is gone', function()
        lift(MECH, CAR, true)
        Mock.fireEvent('entityRemoved', nil, CAR)
        assert_eq(lifted(MECH, CAR), false)
    end)
end)

describe('MECH-4 clutch job', function()
    it('from anywhere, without lift or start, for a made-up plate: nothing (the old exploit)', function()
        finish(MECH, { plate = 'XYZ123' })
        lift(MECH, CAR, true)
        finish(MECH, { netId = CAR, plate = 'XYZ123', pilotBearingMethod = 'bread_method' })   -- never started
        assert_eq(#clutches, 0)
        assert_eq(count(MECH, 'service_clutch_replacement'), 1)
    end)

    it('needs the car lifted by this mechanic and a mechanic job to start', function()
        assert_eq(startClutch(MECH, CAR), false)          -- not lifted
        lift(MECH2, CAR, true)
        assert_eq(startClutch(MECH, CAR), false)          -- lifted by someone else
        assert_eq(startClutch(CIV, CAR), false)
        lift(MECH, CAR, true)
        assert_eq(startClutch(MECH, CAR), true)
    end)

    it('completes only after the steps time, for that car beside the mechanic', function()
        lift(MECH, CAR, true)
        assert_eq(startClutch(MECH, CAR), true)
        Mock.clock = Mock.clock + 20
        finish(MECH, { netId = CAR, pilotBearingMethod = 'bread_method' })   -- 20 s: the steps take ~70
        assert_eq(#clutches, 0)
        Mock.clock = Mock.clock + 50
        finish(MECH, { netId = FAR_CAR, pilotBearingMethod = 'bread_method' })
        assert_eq(#clutches, 0, 'another car')
        finish(MECH, { netId = CAR, pilotBearingMethod = 'bread_method', consume = { obd_scanner = 1, sliced_bread = 'x' } })
        assert_eq(#clutches, 1)
        assert_eq(clutches[1].plate, 'CLUTCH01')
        assert_eq(count(MECH, 'service_clutch_replacement'), 0)
        assert_eq(count(MECH, 'sliced_bread'), 1, 'one slice for the bread method')
        assert_eq(count(MECH, 'obd_scanner'), 1, 'the client list is ignored')
        finish(MECH, { netId = CAR, pilotBearingMethod = 'bread_method' })
        assert_eq(#clutches, 1, 'one job, one clutch')
        assert_eq(reports[1].metadata.pilotBearingMethod, 'bread_method')
        assert_eq(reports[1].metadata.consume, nil, 'no client payload passed on')
    end)

    it('the pilot bearing method must be one the mechanic has the tools for', function()
        lift(MECH, CAR, true)
        startClutch(MECH, CAR)
        Mock.clock = Mock.clock + 70
        finish(MECH, { netId = CAR, pilotBearingMethod = 'pulley_puller' })   -- no puller
        finish(MECH, { netId = CAR, pilotBearingMethod = 'magic' })
        assert_eq(#clutches, 0)
        Mock.players[MECH].inv.pulley_puller = 1
        finish(MECH, { netId = CAR, pilotBearingMethod = 'pulley_puller' })
        assert_eq(#clutches, 1)
        assert_eq(count(MECH, 'sliced_bread'), 2)
        assert_eq(count(MECH, 'pulley_puller'), 1, 'the puller is a tool, not used up')
    end)
end)

describe('MECH-10 diagnostic scan reports', function()
    local function scan(src, payload) Mock.fireNet('pf-mechanicjob:server:advanced:diagnosticReport', src, payload) end

    it('the cost and the plate are the server\'s; the client payload is not passed on', function()
        scan(MECH, { netId = CAR, tool = 'obd_scanner', cost = 1e9, plate = 'OTHER', note = 'x' })
        assert_eq(#reports, 1)
        assert_eq(reports[1].cost, Config.AdvancedSystems.Diagnostics.ScanCosts.obd_scanner)
        assert_eq(reports[1].plate, 'CLUTCH01')
        assert_eq(reports[1].metadata, nil)
        assert_eq(reports[1].note, nil)
    end)

    it('no report without the tool, a car beside the mechanic or a mechanic job; one per 30 s', function()
        scan(CIV, { netId = CAR, tool = 'obd_scanner' })
        scan(MECH, { netId = FAR_CAR, tool = 'obd_scanner' })
        scan(MECH, { netId = CAR, tool = 'multimeter' })          -- not held
        scan(MECH, { netId = CAR, tool = 'water_bottle' })
        assert_eq(#reports, 0)
        scan(MECH, { netId = CAR, tool = 'obd_scanner' })
        for _ = 1, 5 do scan(MECH, { netId = CAR, tool = 'obd_scanner' }) end
        assert_eq(#reports, 1)
        Mock.clock = Mock.clock + 31
        scan(MECH, { netId = CAR, tool = 'obd_scanner' })
        assert_eq(#reports, 2)
    end)
end)
