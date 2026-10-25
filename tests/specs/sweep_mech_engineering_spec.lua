-- pf-mechanicjob engineering and supplies (server/engineering/sv_events.lua, sv_integration.lua,
-- server/supplies.lua): upgrade/service events are server-only, wear and ECU changes come only from
-- the driver of that car, and a supplies run completes only at the drop-off.
load_resource('tests/lua/fivem_mocks.lua')
QBCore = QBCoreMock

-- Engineering module stand-in: records calls; tunings by plate
local calls, tunings = {}, {}
local Engineering = setmetatable({
    GetTuning = function(_, plate) return tunings[plate] end,
    GetOrCreateTuning = function(_, plate) tunings[plate] = tunings[plate] or { engine_wear = 0, turbo_wear = 0 }; return tunings[plate] end,
}, { __index = function(_, name)
    return function(_, ...) calls[#calls + 1] = { name = name, args = { ... } }; return true, 'ok' end
end })
function require(name)
    if name == 'config.engineering' then return { Enabled = true, ServiceCosts = {} } end
    return Engineering
end
local function called(name)
    local out = {}
    for _, c in ipairs(calls) do if c.name == name then out[#out + 1] = c end end
    return out
end

Config = nil
load_resource('[pfscripts]/pf-mechanicjob/config.lua')
load_resource('[pfscripts]/pf-mechanicjob/shared/debug.lua')
Config.Debug = false
load_resource('[pfscripts]/pf-mechanicjob/server/engineering/sv_events.lua')
load_resource('[pfscripts]/pf-mechanicjob/server/engineering/sv_integration.lua')

local nextEntity = 900
function CreateVehicleServerSetter() nextEntity = nextEntity + 1; return nextEntity end
load_resource('[pfscripts]/pf-mechanicjob/server/supplies.lua')

local DRIVER, OTHER, CAR = 1, 2, 500
local DROP = { x = 300.0, y = 300.0, z = 20.0, w = 0.0 }

BeforeEach = function()
    Mock.reset()
    calls, tunings = {}, {}
    Mock.players, Mock.coords, Mock.vehicleOf, Mock.plates = {}, {}, {}, {}
    Mock.newPlayer(DRIVER).PlayerData.job = { name = 'mechanic', grade = { level = 0 } }
    Mock.newPlayer(OTHER).PlayerData.job = { name = 'mechanic', grade = { level = 0 } }
    Mock.vehicleOf[DRIVER] = CAR
    Mock.plates[CAR] = 'TUNED 1'
end

describe('engineering', function()
    it('upgrade and service events cannot be sent by a client', function()
        for _, name in ipairs({ 'engineering:applySimpleUpgrade', 'engineering:installComponent', 'engineering:serviceOil',
            'engineering:serviceCooling', 'engineering:rebuildEngine', 'engineering:replaceClutch',
            'engineering:rebuildGearbox', 'pf-mechanicjob:server:upgradeItem' }) do
            assert_eq(Mock.netHandlers[name], nil)
            assert_true(Mock.eventHandlers[name] ~= nil)
        end
    end)
    it('wear, ECU map and boost only from the driver of that car', function()
        Mock.fireNet('engineering:syncWearAndHeat', OTHER, 'TUNED1', 0, 0, 0, 0)
        Mock.fireNet('engineering:setECUMap', OTHER, 'TUNED1', 'race')
        Mock.fireNet('engineering:setBoost', OTHER, 'TUNED1', 20)
        Mock.fireNet('engineering:setBoost', DRIVER, 'OTHER99', 20)      -- driving a different car
        assert_eq(#calls, 0)
        Mock.fireNet('engineering:setECUMap', DRIVER, 'TUNED1', 'race')
        assert_eq(#called('SetECUMap'), 1)
    end)
    it('a driver cannot wind their wear back down', function()
        tunings.TUNED1 = { engine_wear = 60, turbo_wear = 40 }
        Mock.fireNet('engineering:syncWearAndHeat', DRIVER, 'TUNED1', 0, 0, 50, 50)
        local c = called('SyncWearAndHeat')[1]
        assert_true(c ~= nil)
        assert_eq(c.args[3], 60)
        assert_eq(c.args[4], 40)
        Mock.fireNet('engineering:syncWearAndHeat', DRIVER, 'TUNED1', 'x', 0, 0, 0)  -- junk is dropped
        assert_eq(#called('SyncWearAndHeat'), 1)
    end)
end)

describe('supplies run', function()
    local function start()
        local ok = Mock.selfExport('StartSuppliesPickup')(DRIVER, { id = 7, deliveryLocation = DROP })
        assert_true(ok)
    end
    local function result()
        local ev = Mock.clientEventsNamed('pf-mechanicjob:client:supplies:deliveryComplete')
        return ev[#ev] and ev[#ev].args[1]
    end
    it('a client cannot start a mission with an order it made up', function()
        assert_eq(Mock.netHandlers['pf-mechanicjob:server:supplies:startPickup'], nil)
    end)
    it('completes only with the driver and trailer at the drop-off', function()
        Mock.coords[DRIVER] = vector3(0.0, 0.0, 0.0)
        start()
        Mock.fireNet('pf-mechanicjob:server:trailerHooked', DRIVER)
        Mock.fireNet('pf-mechanicjob:server:completeSuppliesDelivery', DRIVER)
        assert_eq(result(), false)
        Mock.fireNet('pf-mechanicjob:server:completeDelivery', DRIVER)     -- legacy event, no hook check
        assert_eq(result(), false)
        local trailer = nextEntity                          -- spawned last
        Mock.coords[DRIVER] = vector3(DROP.x, DROP.y, DROP.z)
        Mock.coords[trailer] = vector3(DROP.x + 10.0, DROP.y, DROP.z)
        Mock.fireNet('pf-mechanicjob:server:completeSuppliesDelivery', DRIVER)
        assert_eq(result(), true)
    end)
end)
