-- pfm-taxijob: a fare is paid once per passenger the server saw picked up, at a drop-off a real drive away.
load_resource('tests/lua/fivem_mocks.lua')
Mock.exportsByResource['pfm-inventory'] = { AddItem = function() return true end }
load_resource('pfm-taxijob/config.lua')
Config.Advanced.Bonus.Enabled = false
load_resource('pfm-taxijob/server/main.lua')

local DRIVER = 1
local function at(c) Mock.coords[DRIVER] = vector3(c.x, c.y, c.z) end
local function cash() return Mock.players[DRIVER].PlayerData.money.cash end
local TAKE, DELIVER = Config.NPCLocations.TakeLocations, Config.NPCLocations.DeliverLocations

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 1000
    Mock.players, Mock.coords, Mock.dropped = {}, {}, {}
    Mock.newPlayer(DRIVER).PlayerData.job = { name = 'taxi', onduty = true }
    Mock.fireNet('qb-taxi:server:EndShift', DRIVER)
    at(Config.Location)
    Mock.fireNet('qb-taxi:server:StartShift', DRIVER)
end

describe('taxi fares', function()
    it('parking at a drop-off pays nothing without a passenger', function()
        at(DELIVER[1])
        Mock.fireNet('qb-taxi:server:NpcPay', DRIVER)
        assert_eq(cash(), 0)
    end)
    it('a picked-up passenger pays once at a far drop-off after the drive', function()
        at(TAKE[1])
        Mock.fireNet('qb-taxi:server:PickupNpc', DRIVER, 1)
        at(DELIVER[1])
        Mock.fireNet('qb-taxi:server:NpcPay', DRIVER)          -- instantly: too fast
        assert_eq(cash(), 0)
        Mock.clock = Mock.clock + 120
        Mock.fireNet('qb-taxi:server:NpcPay', DRIVER)
        local paid = cash()
        assert_true(paid > 0)
        Mock.clock = Mock.clock + 120
        Mock.fireNet('qb-taxi:server:NpcPay', DRIVER)          -- same passenger again
        assert_eq(cash(), paid)
    end)
    it('a pickup reported away from the pickup point does not count', function()
        at(DELIVER[1])
        Mock.fireNet('qb-taxi:server:PickupNpc', DRIVER, 1)
        Mock.clock = Mock.clock + 120
        Mock.fireNet('qb-taxi:server:NpcPay', DRIVER)
        assert_eq(cash(), 0)
    end)
end)
