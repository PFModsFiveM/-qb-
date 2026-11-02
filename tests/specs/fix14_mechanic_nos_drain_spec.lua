-- pf-mechanicjob NOS (MECH-11, server/nos.lua): the bottle drains on the server while its driver
-- boosts (Config.NOS.levels[levelSel].drainPerSec per second); at 0 the server clears the car's NOS
-- and saves it. The driver only says when boosting starts and stops. The client used to report the
-- level itself, so a modified client never emptied its bottle, and a passenger could empty (and
-- save empty) the driver's.
load_resource('tests/lua/fivem_mocks.lua')
QBCore = QBCoreMock

local states = {}
local stateMeta = { __index = { set = function(self, k, v) rawset(self, k, v) end } }
function Entity(e)
    states[e] = states[e] or { state = setmetatable({}, stateMeta) }
    return states[e]
end
local existing, drivers = {}, {}
function DoesEntityExist(e) return existing[e] == true end
function GetIsVehicleEngineRunning() return false end
function GetPedInVehicleSeat(veh, seat) if seat == -1 then return drivers[veh] or 0 end return 0 end

Config = nil
load_resource('[pfscripts]/pf-mechanicjob/config.lua')
Config.Debug = false
QBCoreMock.Shared.Items.emptynos = { name = 'emptynos', label = 'Empty NOS' }
local saves = {}
PFMech = { SaveNos = function(veh) saves[#saves + 1] = { veh = veh, nos = Entity(veh).state.nos } end }
load_resource('[pfscripts]/pf-mechanicjob/server/nos.lua')

local DRIVER, PASSENGER = 1, 2
local CAR = 500
local L1, L2 = Config.NOS.levels[1].drainPerSec, Config.NOS.levels[2].drainPerSec

local function nos() return Entity(CAR).state.nos end
local function boost(src, on) Mock.fireNet('pf_mech:nos:boost', src, CAR, on) end
local function seconds(n) for _ = 1, n do Mock.clock = Mock.clock + 1; PFMech.NosDrainTick() end end

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 1000
    Mock.players, Mock.coords, Mock.vehicleOf = {}, {}, {}
    states, saves = {}, {}
    existing = { [CAR] = true }
    Mock.newPlayer(DRIVER)
    Mock.newPlayer(PASSENGER)
    Mock.vehicleOf[DRIVER], Mock.vehicleOf[PASSENGER] = CAR, CAR
    drivers = { [CAR] = DRIVER }
    Entity(CAR).state.nos = { has = true, level = 100, levelSel = 1, color = '#55CCFF' }
    for _, src in ipairs({ DRIVER, PASSENGER }) do Mock.fireEvent('playerDropped', src) end
end

describe('MECH-11 the server drains the bottle', function()
    it('the level report is gone: no client sets the level any more', function()
        assert_eq(Mock.netHandlers['pf_mech:nos:updateLevel'], nil)
    end)

    it('drains every second of boosting, at the boost level\'s rate, and stops on release', function()
        boost(DRIVER, true)
        seconds(2)
        assert_eq(nos().level, 100 - 2 * L1)
        boost(DRIVER, false)
        seconds(3)
        assert_eq(nos().level, 100 - 2 * L1, 'not boosting: no drain')
        nos().levelSel = 2
        boost(DRIVER, true)
        seconds(1)
        assert_eq(nos().level, 100 - 2 * L1 - L2)
    end)

    it('a client that never says stop still empties the bottle; it is cleared and saved at 0', function()
        boost(DRIVER, true)
        seconds(20)
        assert_eq(nos().has, false)
        assert_eq(nos().level, 0)
        assert_eq(nos().color, '#55CCFF')
        assert_eq(saves[#saves].nos.has, false, 'the empty bottle is saved')
    end)

    it('the level is saved each time it falls past a step of 10', function()
        boost(DRIVER, true)
        seconds(1)                                    -- 100 -> 88
        assert_eq(#saves, 1)
        assert_eq(saves[1].nos.level, 100 - L1)
    end)

    it('a passenger can neither boost nor empty the driver\'s bottle', function()
        boost(PASSENGER, true)
        seconds(5)
        assert_eq(nos().level, 100)
        Mock.fireNet('pf_mech:nos:giveEmpty', PASSENGER, CAR)
        Mock.fireNet('pf_mech:nos:giveEmpty', DRIVER, CAR)
        assert_eq(nos().has, true)
        assert_eq(nos().level, 100)
        assert_eq(#saves, 0)
    end)

    it('the boost ends when the driver leaves the seat or the car is gone', function()
        boost(DRIVER, true)
        seconds(1)
        drivers[CAR] = nil
        seconds(3)
        assert_eq(nos().level, 100 - L1)
        drivers[CAR] = DRIVER
        boost(DRIVER, true)
        existing[CAR] = nil
        seconds(3)
        assert_eq(nos().level, 100 - L1)
    end)

    it('an empty or missing bottle does not boost; start/stop messages are rate limited', function()
        Entity(CAR).state.nos = { has = false, level = 0 }
        boost(DRIVER, true)
        seconds(1)
        assert_eq(#saves, 0)
        Entity(CAR).state.nos = { has = true, level = 100, levelSel = 1 }
        for _ = 1, 30 do boost(DRIVER, false) end
        boost(DRIVER, true)                            -- over the limit in this window
        seconds(1)
        assert_eq(nos().level, 100)
    end)
end)
