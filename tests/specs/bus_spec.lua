-- pfm-busjob: each payment comes from a new stop a real drive from the last paid one.
load_resource('tests/lua/ledger_env.lua')
LedgerEnv.load('pfm-busjob', { 'pfm-busjob/config.lua', 'pfm-busjob/server/main.lua' })

local DRIVER = 1
local STOPS = Config.NPCLocations.Locations
local function at(c) Mock.coords[DRIVER] = vector3(c.x, c.y, c.z) end
local function cash() return Mock.players[DRIVER].PlayerData.money.cash end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.clock = Mock.clock + 1000
    Mock.players, Mock.coords, Mock.dropped = {}, {}, {}
    Mock.newPlayer(DRIVER).PlayerData.job = { name = 'bus', onduty = true }
    Mock.fireNet('qb-busjob:server:EndShift', DRIVER)
    at(Config.Location)
    Mock.fireNet('qb-busjob:server:StartShift', DRIVER)
end

describe('bus pay', function()
    it('a parked bus is paid once per stop', function()
        at(STOPS[1])
        Mock.fireNet('qb-busjob:server:NpcPay', DRIVER)
        local first = cash()
        assert_true(first > 0)
        for _ = 1, 5 do
            Mock.clock = Mock.clock + 15
            Mock.fireNet('qb-busjob:server:NpcPay', DRIVER)
        end
        assert_eq(cash(), first)
    end)
    it('driving to the next stop pays again', function()
        at(STOPS[1])
        Mock.fireNet('qb-busjob:server:NpcPay', DRIVER)
        local first = cash()
        at(STOPS[2])
        Mock.clock = Mock.clock + 120
        Mock.fireNet('qb-busjob:server:NpcPay', DRIVER)
        assert_true(cash() > first)
        assert_eq(#LedgerEnv.paid('pfm-busjob:'), 2)
    end)
end)
