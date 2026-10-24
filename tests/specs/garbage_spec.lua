-- pfm-garbagejob: only a paid deposit is refunded, and each stop (the last one too) pays once.
load_resource('tests/lua/fivem_mocks.lua')
Mock.exportsByResource['pfm-inventory'] = { AddItem = function() return true end }
load_resource('pfm-garbagejob/config.lua')
load_resource('pfm-garbagejob/server/main.lua')

local W = 1
local function bank() return Mock.players[W].PlayerData.money.bank end
local function newShift(continue)
    local ok, stop, bags, total = Mock.callCallback('qb-garbagejob:server:NewShift', W, continue)
    return ok, stop, total
end
local function collect(stopNum, stop)
    local c = Config.Locations['trashcan'][stop].coords
    Mock.coords[W] = vector3(c.x, c.y, c.z)
    Mock.clock = Mock.clock + 60
    return Mock.callCallback('qb-garbagejob:server:NextStop', W, stop, stopNum, nil)
end
local function payslip(continue)
    local c = Config.Locations['paycheck'].coords
    Mock.coords[W] = vector3(c.x, c.y, c.z)
    Mock.fireNet('qb-garbagejob:server:PayShift', W, continue)
end

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 10000
    Mock.players, Mock.coords = {}, {}
    local p = Mock.newPlayer(W)
    p.PlayerData.job = { name = Config.Jobname, onduty = true }
    p.PlayerData.money.bank = 1000
end

describe('garbage job', function()
    it('a deposit that was never paid is never refunded', function()
        assert_true(newShift(false))
        payslip(false)
        assert_eq(bank(), 1000)
    end)
    it('a full route pays every stop once and refunds the paid deposit', function()
        local ok, stop, total = newShift(false)
        Mock.fireNet('qb-garbagejob:server:payDeposit', W)
        assert_eq(bank(), 1000 - Config.TruckPrice)
        for n = 1, total do
            local more, nextStop = collect(n, stop)
            if more then stop = nextStop end
        end
        -- the last stop again: nothing more
        local again = collect(total, stop)
        assert_false(again)
        payslip(false)
        assert_true(bank() > 1000)
    end)
    it('"continue" without a held deposit gets no free deposit', function()
        Mock.players[W].PlayerData.money.bank = 0
        assert_false(newShift(true))
    end)
end)
