-- pfm-weathersync: a client's state request is answered to that client only; weather changes stay
-- admin-only.
load_resource('tests/lua/fivem_mocks.lua')
local perms = {}
QBCoreMock.Functions.HasPermission = function(src, perm) return perms[src] == perm end
function PerformHttpRequest() end
Config = nil
load_resource('pfm-weathersync/config.lua')
load_resource('pfm-weathersync/server/server.lua')

BeforeEach = function()
    Mock.reset()
    perms = {}
end

describe('weathersync', function()
    it('a state request goes back to the requester, not to everyone', function()
        Mock.fireNet('qb-weathersync:server:RequestStateSync', 4)
        for _, e in ipairs(Mock.clientEvents) do assert_eq(e.target, 4) end
        assert_true(#Mock.clientEvents >= 2)
    end)
    it('a player cannot change the weather', function()
        Mock.fireNet('qb-weathersync:server:setWeather', 4, 'THUNDER')
        assert_eq(#Mock.clientEventsNamed('qb-weathersync:client:SyncWeather'), 0)
    end)
end)
