-- pf-ambulancejob registers its duty desks with pfm-core (batch 14: DUTY-1), on start and again when
-- pfm-core restarts; medics clock in at a desk (pfm-core's ToggleDuty checks it), out anywhere.
load_resource('tests/lua/ledger_env.lua')
GetInvokingResource = function() return nil end
Mock.exportsByResource['pf-services'] = {
    CreateRequest = function() return { ok = true, id = 1 } end, CloseByRef = function() return { ok = true } end, Emit = function() return 1 end,
}
Mock.exportsByResource['pfm-inventory'] = { RemoveItem = function() return true end, AddItem = function() return true end }
QBCoreMock.Functions.HasItem = function() return false end
QBCoreMock.Commands.Add = function() end
local calls = {}
Mock.exportsByResource['pfm-core'].RegisterDutyPoints = function(_, spec) calls[#calls + 1] = spec return true, #spec.points end
LedgerEnv.load('pf-ambulancejob', { '[pfscripts]/pf-ambulancejob/config.lua', '[pfscripts]/pf-ambulancejob/server/main.lua' })

describe('ambulance duty points', function()
    it('are the duty desks of the config, for the ambulance job', function()
        assert_eq(#calls, 1)
        assert_eq(calls[1].job, 'ambulance')
        assert_eq(#calls[1].points, #Config.Locations['duty'])
        assert_near(calls[1].points[1].x, Config.Locations['duty'][1].x, 0.001)
    end)
    it('are sent again when pfm-core restarts', function()
        Mock.eventHandlers['onResourceStart']('pfm-core')
        assert_eq(#calls, 2)
        Mock.eventHandlers['onResourceStart']('some-other-resource')
        assert_eq(#calls, 2)
    end)
end)
