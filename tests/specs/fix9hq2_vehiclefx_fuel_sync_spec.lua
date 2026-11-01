-- pfm-fuel: the shared fuel level ('qb-fuel' state bag) of a car. The network owner of any EMPTY
-- car could set it to any level from any distance ('qb-fuel:server:syncFuel'), so a modded client
-- near parked cars drained them all. Now only the driver reports, a report only lowers the level,
-- by at most what driving burns since the last level written, and raises come from the server's
-- refuel paths (a paid pump refill, the player's own jerry can).
load_resource('tests/lua/fivem_mocks.lua')

local states = {}
local stateMeta = { __index = { set = function(self, k, v) rawset(self, k, v) end } }
function Entity(e)
    states[e] = states[e] or { state = setmetatable({}, stateMeta) }
    return states[e]
end
local entityType, owners = {}, {}
function GetEntityType(e) return entityType[e] or 0 end
function NetworkGetEntityOwner(e) return owners[e] end
function DoesEntityExist() return true end

local charged = {}
PFPayout = {
    NewId = function() return tostring(#charged + 1) end,
    Charge = function(player, kind, amount, opts)
        if player.cannotPay then return false end
        charged[#charged + 1] = { cid = player.PlayerData.citizenid, kind = kind, amount = amount, key = opts and opts.key }
        return true
    end,
}

Config = nil
load_resource('pfm-fuel/Config.lua')
load_resource('pfm-fuel/server/main.lua')
load_resource('pfm-fuel/server/pricing.lua')

local DRIVER, OWNER, PASSERBY, FARAWAY = 1, 2, 3, 4
local CAR, OTHER = 500, 501
local HERE = vector3(100.0, 100.0, 30.0)

local function fuel(veh) return Entity(veh).state['qb-fuel'] end
local function sync(src, netId, level) Mock.fireNet('qb-fuel:server:syncFuel', src, netId, level) end
local function later(seconds) Mock.gameTimer = Mock.gameTimer + seconds * 1000 end
--- gives `veh` a shared level `level` as a driver would, then leaves the car empty
local function parked(veh, level)
    Mock.vehicleOf[DRIVER] = veh
    sync(DRIVER, veh, level)
    Mock.vehicleOf[DRIVER] = nil
    assert_eq(fuel(veh), level + 0.0)
end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.vehicleOf, Mock.coords = {}, {}, {}
    Mock.gameTimer = Mock.gameTimer + 100000
    states, owners, charged = {}, {}, {}
    entityType = { [CAR] = 2, [OTHER] = 2 }
    for _, src in ipairs({ DRIVER, OWNER, PASSERBY, FARAWAY }) do Mock.newPlayer(src) end
    Mock.coords[CAR], Mock.coords[OTHER] = HERE, HERE + vector3(4.0, 0, 0)
    Mock.coords[DRIVER], Mock.coords[OWNER], Mock.coords[PASSERBY] = HERE, HERE + vector3(2.0, 0, 0), HERE + vector3(3.0, 0, 0)
    Mock.coords[FARAWAY] = vector3(900.0, 900.0, 30.0)
    Config.SyncFuelBetweenPlayers = true
    Config.MaxFuelBurnPerSecond = nil
end

describe('fix9hq2 vehiclefx: who may lower a car\'s shared fuel', function()
    it('the network owner of an empty car cannot drain it, near or far', function()
        parked(CAR, 80)
        parked(OTHER, 60)
        later(60)
        owners[CAR], owners[OTHER] = FARAWAY, OWNER
        sync(FARAWAY, CAR, 0)
        sync(OWNER, OTHER, 0)
        assert_eq(fuel(CAR), 80.0, 'owner far away')
        assert_eq(fuel(OTHER), 60.0, 'owner beside it')
    end)

    it('a player beside a car, or a passenger, cannot change it', function()
        parked(CAR, 80)
        later(30)
        sync(PASSERBY, CAR, 0)
        sync(PASSERBY, CAR, 100)
        Mock.vehicleOf[DRIVER] = CAR
        -- a passenger: in the car, not in the driver's seat
        local seat = GetPedInVehicleSeat
        GetPedInVehicleSeat = function(veh, s) if s == -1 then return DRIVER end return seat(veh, s) end
        sync(OWNER, CAR, 0)
        GetPedInVehicleSeat = seat
        assert_eq(fuel(CAR), 80.0)
    end)

    it('a new car with no shared level takes only its driver\'s first report', function()
        sync(PASSERBY, CAR, 30)
        owners[CAR] = OWNER
        sync(OWNER, CAR, 30)
        assert_eq(fuel(CAR), nil)
        Mock.vehicleOf[DRIVER] = CAR
        sync(DRIVER, CAR, 30)
        assert_eq(fuel(CAR), 30.0)
    end)
end)

describe('fix9hq2 vehiclefx: the driver lowers it at most as fast as driving burns', function()
    it('a drop is capped at 0.5 per second since the last level written', function()
        Mock.vehicleOf[DRIVER] = CAR
        sync(DRIVER, CAR, 80)
        later(10)
        sync(DRIVER, CAR, 0)
        assert_eq(fuel(CAR), 75.0, '10 s: 5 at most')
        later(10)
        sync(DRIVER, CAR, 73)
        assert_eq(fuel(CAR), 73.0, 'a real drop within the cap is taken as is')
        sync(DRIVER, CAR, 0)
        assert_eq(fuel(CAR), 73.0, 'a burst of reports earns nothing extra')
    end)

    it('a long-parked car: the allowance stops growing after 30 s', function()
        parked(CAR, 80)
        later(3600)
        Mock.vehicleOf[FARAWAY] = CAR -- sits in it, now the driver
        sync(FARAWAY, CAR, 0)
        assert_eq(fuel(CAR), 65.0)
    end)

    it('the cap follows Config.MaxFuelBurnPerSecond', function()
        Config.MaxFuelBurnPerSecond = 2
        Mock.vehicleOf[DRIVER] = CAR
        sync(DRIVER, CAR, 80)
        later(10)
        sync(DRIVER, CAR, 0)
        assert_eq(fuel(CAR), 60.0)
    end)
end)

describe('fix9hq2 vehiclefx: refuelling raises it on the server', function()
    it('a paid pump refill adds the litres to the car beside the player', function()
        parked(CAR, 50)
        local paid = Mock.callCallback('qb-fuel:server:refillVehicle', PASSERBY, 20, CAR, 99)
        assert_eq(paid, true)
        assert_eq(#charged, 1)
        assert_eq(fuel(CAR), 70.0, 'from the shared level, not the client\'s')
        Mock.gameTimer = Mock.gameTimer + 5000
        Mock.callCallback('qb-fuel:server:refillVehicle', PASSERBY, 60, CAR, 0)
        assert_eq(fuel(CAR), 100.0, 'a full tank at most')
    end)

    it('no raise when unpaid, too far away, or for a non-vehicle', function()
        parked(CAR, 50)
        Mock.players[PASSERBY].cannotPay = true
        assert_eq(Mock.callCallback('qb-fuel:server:refillVehicle', PASSERBY, 20, CAR, 50), false)
        Mock.players[PASSERBY].cannotPay = nil
        Mock.gameTimer = Mock.gameTimer + 5000
        assert_eq(Mock.callCallback('qb-fuel:server:refillVehicle', FARAWAY, 20, CAR, 50), true)
        Mock.gameTimer = Mock.gameTimer + 5000
        entityType[CAR] = 1
        Mock.callCallback('qb-fuel:server:refillVehicle', PASSERBY, 20, CAR, 50)
        entityType[CAR] = 2
        assert_eq(fuel(CAR), 50.0)
    end)

    it('a car with no shared level yet starts from the client\'s level', function()
        Mock.callCallback('qb-fuel:server:refillVehicle', PASSERBY, 20, CAR, 15)
        assert_eq(fuel(CAR), 35.0)
    end)

    local function giveCan(src, litres)
        local p = Mock.players[src]
        p.can = { slot = 3, info = { fuel = litres, ammo = litres } }
        p.GetItemByName = function(name) if name == 'weapon_petrolcan' then return p.can end end
        p.RemoveItem = function() if p.onRemove then p.onRemove() end return true end
        p.AddItem = function(_, _, _, info) p.can = { slot = 3, info = info } return true end
        return p
    end

    it('a jerry can pours what leaves the can into the car', function()
        parked(CAR, 50)
        local p = giveCan(PASSERBY, 40)
        Mock.fireNet('qb-fuel:server:setCanFuel', PASSERBY, 10, CAR, 0)
        assert_eq(p.can.info.fuel, 10)
        assert_eq(fuel(CAR), 80.0)
        Mock.fireNet('qb-fuel:server:setCanFuel', PASSERBY, 30, CAR, 0)
        assert_eq(p.can.info.fuel, 10, 'the can never refills')
        assert_eq(fuel(CAR), 80.0)
    end)

    it('two pours from one can at once count it once', function()
        parked(CAR, 20)
        local p = giveCan(PASSERBY, 40)
        p.onRemove = function()
            p.onRemove = nil
            Mock.fireNet('qb-fuel:server:setCanFuel', PASSERBY, 0, CAR, 0) -- arrives while the first yields
        end
        Mock.fireNet('qb-fuel:server:setCanFuel', PASSERBY, 0, CAR, 0)
        assert_eq(fuel(CAR), 60.0)
    end)
end)
