-- pfm-towjob on the ledger: deposit charged and refunded once, salary paid once per tow session.
load_resource('tests/lua/ledger_env.lua')
Mock.exportsByResource['pfm-inventory'] = { AddItem = function() return true end }
LedgerEnv.load('pfm-towjob', { 'pfm-towjob/config.lua', 'pfm-towjob/server/main.lua' })

local T, TRUCK, CAR = 1, 300, 400
local function bank() return Mock.players[T].PlayerData.money.bank end
local function cash() return Mock.players[T].PlayerData.money.cash end
local function v3(c) return vector3(c.x, c.y, c.z) end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.clock = Mock.clock + 1000
    Mock.players, Mock.coords = {}, {}
    local p = Mock.newPlayer(T)
    p.PlayerData.job = { name = 'tow', onduty = true }
    p.PlayerData.money = { cash = 1000, bank = 0 }
end

describe('tow job', function()
    it('the truck deposit is charged and refunded once', function()
        Mock.fireNet('qb-tow:server:DoBail', T, true, 'flatbed')
        assert_eq(cash(), 1000 - Config.BailPrice)
        Mock.coords[T] = v3(Config.Locations['vehicle'].coords)
        Mock.fireNet('qb-tow:server:DoBail', T, false)
        Mock.fireNet('qb-tow:server:DoBail', T, false)
        assert_eq(bank(), Config.BailPrice)
    end)
    it('a towed car is paid once at the depot', function()
        local spot = Config.Locations['towspots'][1]
        Mock.models[CAR] = joaat(spot.model)
        Mock.coords[CAR] = v3(spot.coords)
        Mock.coords[TRUCK] = v3(spot.coords)
        Mock.vehicleOf[T] = TRUCK
        Mock.fireNet('qb-tow:server:nano', T, CAR)
        local drop = v3(Config.Locations['dropoff'].coords)
        Mock.coords[T], Mock.coords[CAR] = drop, drop
        Mock.clock = Mock.clock + 600
        Mock.fireNet('qb-tow:server:vehicleDropped', T)
        Mock.coords[T] = v3(Config.Locations['main'].coords)
        Mock.fireNet('qb-tow:server:11101110', T)
        local paid = bank()
        assert_true(paid > 0)
        Mock.fireNet('qb-tow:server:11101110', T)
        assert_eq(bank(), paid)
        assert_eq(#LedgerEnv.paid('pfm-towjob:'), 1)
    end)
end)
