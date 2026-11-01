-- pfm-fuel: the shared fuel level ('qb-fuel' state bag) of a car. The network owner of any EMPTY
-- car could set it to any level from any distance ('qb-fuel:server:syncFuel'), so a modded client
-- near parked cars drained them all. Now only the driver reports, a report only lowers the level,
-- by at most what driving burns since the last level written, and raises come from the server's
-- refuel paths (a paid pump refill, the player's own jerry can) or server code (SetVehicleFuel).
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
function DoesEntityExist(e) return entityType[e] ~= nil end

local charged, taxed = {}, {}
PFPayout = {
    NewId = function() return tostring(#charged + 1) end,
    Charge = function(player, kind, amount, opts)
        if PFPayout.duringCharge then local f = PFPayout.duringCharge PFPayout.duringCharge = nil f() end
        if player.cannotPay then return false end
        charged[#charged + 1] = { cid = player.PlayerData.citizenid, kind = kind, amount = amount, key = opts and opts.key }
        return true
    end,
}

Config = nil
load_resource('pfm-fuel/Config.lua')
load_resource('pfm-fuel/server/main.lua')
load_resource('pfm-fuel/server/pricing.lua')
-- the station price and sales tax have their own specs: a flat price here
GetStationFuelPrice = function() return 5 end
GetFuelTaxRate = function() return 0 end
CollectFuelTax = function(...) taxed[#taxed + 1] = { ... } end

local DRIVER, OWNER, PASSERBY, FARAWAY = 1, 2, 3, 4
local CAR, OTHER, PED = 500, 501, 600
local HERE = vector3(100.0, 100.0, 30.0)
local fuelExports = Mock.exportsByResource['__self']

local function fuel(veh) return Entity(veh).state['qb-fuel'] end
local function sync(src, netId, level) Mock.fireNet('qb-fuel:server:syncFuel', src, netId, level) end
local function later(seconds) Mock.gameTimer = Mock.gameTimer + seconds * 1000 end
local function refill(src, litres, netId) return Mock.callCallback('qb-fuel:server:refillVehicle', src, litres, netId) end
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
    states, owners, charged, taxed = {}, {}, {}, {}
    PFPayout.duringCharge = nil
    entityType = { [CAR] = 2, [OTHER] = 2, [PED] = 1 }
    for _, src in ipairs({ DRIVER, OWNER, PASSERBY, FARAWAY }) do Mock.newPlayer(src) end
    Mock.coords[CAR], Mock.coords[OTHER] = HERE, HERE + vector3(4.0, 0, 0)
    Mock.coords[DRIVER], Mock.coords[OWNER], Mock.coords[PASSERBY] = HERE, HERE + vector3(2.0, 0, 0), HERE + vector3(3.0, 0, 0)
    Mock.coords[FARAWAY] = vector3(900.0, 900.0, 30.0)
    Config.SyncFuelBetweenPlayers = true
    Config.MaxFuelBurnPerSecond = 0.5
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

    it('the driver\'s report never raises it', function()
        parked(CAR, 40)
        Mock.vehicleOf[DRIVER] = CAR
        later(10)
        sync(DRIVER, CAR, 100)
        sync(DRIVER, CAR, 40.5)
        assert_eq(fuel(CAR), 40.0)
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

    it('a rejected or equal report does not use up the allowance', function()
        parked(CAR, 50)
        Mock.vehicleOf[DRIVER] = CAR
        later(5)
        sync(DRIVER, CAR, 60)
        later(5)
        sync(DRIVER, CAR, 0)
        assert_eq(fuel(CAR), 45.0, 'the 10 s since the last write count')
    end)

    it('a long-parked car: the allowance stops growing after 30 s', function()
        parked(CAR, 80)
        later(3600)
        Mock.vehicleOf[FARAWAY] = CAR -- sits in it, now the driver
        sync(FARAWAY, CAR, 0)
        assert_eq(fuel(CAR), 65.0)
    end)

    it('the cap follows Config.MaxFuelBurnPerSecond; a bad value falls back to 0.5', function()
        Config.MaxFuelBurnPerSecond = 2
        Mock.vehicleOf[DRIVER] = CAR
        sync(DRIVER, CAR, 80)
        later(10)
        sync(DRIVER, CAR, 0)
        assert_eq(fuel(CAR), 60.0)
        Config.MaxFuelBurnPerSecond = -5
        later(10)
        sync(DRIVER, CAR, 0)
        assert_eq(fuel(CAR), 55.0)
    end)
end)

describe('fix9hq2 vehiclefx: refuelling raises it on the server', function()
    it('a paid pump refill adds the litres to the car beside the player and answers with the level', function()
        parked(CAR, 50)
        local paid, level = refill(PASSERBY, 20, CAR)
        assert_eq(paid, true)
        assert_eq(level, 70.0)
        assert_eq(#charged, 1)
        assert_eq(charged[1].amount, 100, '20 litres at 5')
        assert_eq(fuel(CAR), 70.0, 'from the shared level, not the client\'s')
    end)

    it('only what fits in the tank is charged; a full tank is not charged at all', function()
        parked(CAR, 70.4)
        local paid, level = refill(PASSERBY, 60, CAR)
        assert_eq(paid, true)
        assert_eq(charged[1].amount, 145, '29 litres fit')
        assert_eq(level, 99.4)
        later(5)
        local paid2, level2, reason = refill(PASSERBY, 10, CAR)
        assert_eq(paid2, false)
        assert_eq(level2, 99.4)
        assert_eq(reason, 'full')
        assert_eq(#charged, 1)
    end)

    it('no charge and no raise when unpaid, too far away, without a car, or for a non-vehicle', function()
        parked(CAR, 50)
        Mock.players[PASSERBY].cannotPay = true
        assert_eq(refill(PASSERBY, 20, CAR), false, 'unpaid')
        Mock.players[PASSERBY].cannotPay = nil
        later(5)
        local ok, _, why = refill(FARAWAY, 20, CAR)
        assert_eq(ok, false, 'far from the car')
        assert_eq(why, 'no_vehicle')
        later(5)
        assert_eq(refill(PASSERBY, 20, nil), false, 'no car')
        later(5)
        assert_eq(refill(PASSERBY, 20, PED), false, 'not a vehicle')
        later(5)
        assert_eq(refill(PASSERBY, -5, CAR), false, 'bad litres')
        assert_eq(#charged, 0)
        assert_eq(fuel(CAR), 50.0)
    end)

    it('a car with no shared level yet: paid, but the client\'s word is not taken for its level', function()
        local paid, level = refill(PASSERBY, 20, CAR)
        assert_eq(paid, true)
        assert_eq(level, nil)
        assert_eq(fuel(CAR), nil, 'its driver\'s first report sets it')
        Mock.vehicleOf[PASSERBY] = CAR
        sync(PASSERBY, CAR, 35)
        assert_eq(fuel(CAR), 35.0)
    end)

    it('the refill cooldown still applies', function()
        parked(CAR, 10)
        assert_eq(refill(PASSERBY, 10, CAR), true)
        assert_eq(refill(PASSERBY, 10, CAR), false)
        assert_eq(fuel(CAR), 20.0)
    end)

    local function giveCan(src, litres)
        local p = Mock.players[src]
        p.can = { slot = 3, info = { fuel = litres, ammo = litres, serie = 'JC1' } }
        p.GetItemByName = function(name) if name == 'weapon_petrolcan' then return p.can end end
        p.RemoveItem = function() if p.onRemove then p.onRemove() end return p.removeResult ~= false end
        p.AddItem = function(_, _, _, info) p.can = { slot = 3, info = info } return true end
        p.notes = {}
        p.Notify = function(msg) p.notes[#p.notes + 1] = msg end
        return p
    end

    it('a jerry can pours what leaves the can into the car', function()
        parked(CAR, 50)
        local p = giveCan(PASSERBY, 40)
        Mock.fireNet('qb-fuel:server:setCanFuel', PASSERBY, 10, CAR)
        assert_eq(p.can.info.fuel, 10)
        assert_eq(p.can.info.serie, 'JC1', 'the rest of the item info is kept')
        assert_eq(fuel(CAR), 80.0)
        Mock.fireNet('qb-fuel:server:setCanFuel', PASSERBY, 30, CAR)
        assert_eq(p.can.info.fuel, 10, 'the can never refills')
        assert_eq(fuel(CAR), 80.0)
    end)

    it('two pours from one can at once count it once', function()
        parked(CAR, 20)
        local p = giveCan(PASSERBY, 40)
        p.onRemove = function()
            p.onRemove = nil
            Mock.fireNet('qb-fuel:server:setCanFuel', PASSERBY, 0, CAR) -- arrives while the first yields
        end
        Mock.fireNet('qb-fuel:server:setCanFuel', PASSERBY, 0, CAR)
        assert_eq(fuel(CAR), 60.0)
    end)

    it('one refuel per car at a time: another one landing during the payment is refused', function()
        parked(CAR, 50)
        local can = giveCan(OWNER, 40)
        local second
        PFPayout.duringCharge = function()
            second = { refill(DRIVER, 40, CAR) }                    -- another pump on the same car
            Mock.fireNet('qb-fuel:server:setCanFuel', OWNER, 0, CAR) -- and a jerry can
        end
        local paid, level = refill(PASSERBY, 40, CAR)
        assert_eq(paid, true)
        assert_eq(level, 90.0)
        assert_eq(second[1], false)
        assert_eq(second[3], 'busy')
        assert_eq(can.can.info.fuel, 40, 'the can was not poured')
        assert_eq(can.notes[1], 'error.vehicle_busy')
        assert_eq(#charged, 1, 'only the first refill was charged')
        later(5)
        Mock.fireNet('qb-fuel:server:setCanFuel', OWNER, 30, CAR)
        assert_eq(fuel(CAR), 100.0, 'free again afterwards')
    end)

    it('the can is not emptied without a car in reach, nor when the inventory swap fails', function()
        parked(CAR, 20)
        local p = giveCan(FARAWAY, 40)
        Mock.fireNet('qb-fuel:server:setCanFuel', FARAWAY, 0, CAR)
        Mock.fireNet('qb-fuel:server:setCanFuel', FARAWAY, 0, nil)
        assert_eq(p.can.info.fuel, 40)
        local q = giveCan(PASSERBY, 40)
        local original = q.can
        q.removeResult = false
        Mock.fireNet('qb-fuel:server:setCanFuel', PASSERBY, 0, CAR)
        assert_eq(original.info.fuel, 40, 'the inventory\'s item is untouched')
        assert_eq(fuel(CAR), 20.0)
    end)
end)

describe('fix9hq2 vehiclefx: server code sets a car\'s level', function()
    it('SetVehicleFuel gives a new car its first value; the driver then only lowers it', function()
        assert_eq(fuelExports.SetVehicleFuel(CAR, 35), true)
        assert_eq(fuelExports.GetVehicleFuel(CAR), 35.0)
        Mock.vehicleOf[DRIVER] = CAR
        sync(DRIVER, CAR, 100)
        assert_eq(fuel(CAR), 35.0, 'the driver\'s first report cannot replace the server\'s value')
        later(10)
        sync(DRIVER, CAR, 33)
        assert_eq(fuel(CAR), 33.0)
    end)

    it('rejects non-vehicles, unknown entities and bad levels; clamps to 0-100', function()
        assert_eq(fuelExports.SetVehicleFuel(PED, 50), false)
        assert_eq(fuelExports.SetVehicleFuel(9999, 50), false)
        assert_eq(fuelExports.SetVehicleFuel(CAR, 0 / 0), false)
        assert_eq(fuelExports.SetVehicleFuel(CAR, 'full'), false)
        assert_eq(fuel(CAR), nil)
        fuelExports.SetVehicleFuel(CAR, 250)
        assert_eq(fuel(CAR), 100.0)
        assert_eq(fuelExports.GetVehicleFuel(PED), nil)
    end)
end)

describe('fix9hq2 vehiclefx: the honest flow end to end', function()
    it('a new car gets its first value, drives down, refuels at the pump, drives down again', function()
        Mock.vehicleOf[DRIVER] = CAR
        sync(DRIVER, CAR, 40)                                     -- taken out of the garage
        for _ = 1, 6 do later(10) sync(DRIVER, CAR, fuel(CAR) - 2) end -- a minute of driving
        assert_eq(fuel(CAR), 28.0)
        Mock.vehicleOf[DRIVER] = nil                              -- gets out at the pump
        later(20)
        local paid, level = refill(DRIVER, 60, CAR)
        assert_eq(paid, true)
        assert_eq(level, 88.0)
        Mock.vehicleOf[DRIVER] = CAR
        later(10)
        sync(DRIVER, CAR, 86.5)
        assert_eq(fuel(CAR), 86.5)
    end)
end)
