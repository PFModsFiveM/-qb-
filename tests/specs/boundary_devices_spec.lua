-- pf-devices through its exports, as every other resource uses it: the handlers pf-jobs, pf-computer,
-- pf-government, pf-stores, pf-services, pf-news and pf-citizen register arrive as function
-- references (callable tables), never as Lua functions, and must be accepted and called.
load_resource('tests/lua/fivem_mocks.lua')

Config = {}
load_resource('[pfscripts]/pf-devices/shared/config.lua')
local startedResources = { ['pf-jobs'] = true, ['pf-devices'] = true, ['pfm-core'] = true }
function GetResourceState(name) return startedResources[name] and 'started' or 'missing' end
function GetCurrentResourceName() return 'pf-devices' end
local invoking = 'pf-jobs'
function GetInvokingResource() return invoking end
local clock = 0
function GetGameTimer() return clock end

load_resource('[pfscripts]/pf-devices/server/registry.lua')
load_resource('[pfscripts]/pf-devices/server/installs.lua')
load_resource('[pfscripts]/pf-devices/server/rpc.lua')
load_resource('[pfscripts]/pf-devices/server/push.lua')
load_resource('[pfscripts]/pf-devices/server/sites.lua')
load_resource('[pfscripts]/pf-devices/server/builtin_apps.lua')
load_resource('[pfscripts]/pf-devices/server/main.lua')
Mock.exportsByResource['pf-devices'] = Mock.exportsByResource['__self']
local devices = exports['pf-devices']

local function player(src, job)
    local p = Mock.newPlayer(src)
    p.PlayerData.job = { name = job or 'unemployed', grade = { level = 0 }, onduty = true }
    p.PlayerData.source = src
    return p
end

local function rpc(src, app, method, payload)
    Mock.clientEvents = {}
    Mock.fireNet('pf-devices:server:rpc', src, 1, app, method, payload or {})
    local replies = Mock.clientEventsNamed('pf-devices:client:rpc')
    return replies[#replies] and replies[#replies].args[2]
end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    PFDevices.__reset()
    PFDevices.__resetInstalls()
    PFDevices.__resetRpc()
    PFDevices.__resetSites()
    clock = clock + 10000
    invoking = 'pf-jobs'
end

describe('pf-devices handlers registered through the exports', function()
    it('RegisterAppHandler accepts a function reference and the RPC bridge calls it', function()
        assert_true(devices:RegisterApp({ id = 'taxi', entry = 'a.js', access = { jobs = { 'taxi' } } }))
        local seen
        local ok, err = devices:RegisterAppHandler('taxi', 'getInit', function(src, payload, ctx)
            seen = { src = src, n = payload.n, method = ctx.method }
            return { calls = 3 }
        end)
        assert_true(ok, tostring(err))
        assert_true(Mock.isFuncref(PFDevices.GetHandler('taxi', 'getInit')), 'stored as the reference it arrived as')
        player(5, 'taxi')
        local res = rpc(5, 'taxi', 'getInit', { n = 7 })
        assert_eq(res.ok, true)
        assert_eq(res.calls, 3)
        assert_eq(seen.src, 5)
        assert_eq(seen.n, 7)
        assert_eq(seen.method, 'getInit')
    end)

    it('RegisterAppHandlers accepts a table of function references', function()
        devices:RegisterApp({ id = 'bus', entry = 'a.js' })
        local ok, err = devices:RegisterAppHandlers('bus', {
            status = function() return { route = 'A' } end,
            stop = function(_, p) return { stopped = p.id } end,
        })
        assert_true(ok, tostring(err))
        player(2)
        assert_eq(rpc(2, 'bus', 'status').route, 'A')
        assert_eq(rpc(2, 'bus', 'stop', { id = 4 }).stopped, 4)
    end)

    it('an access handler from another resource decides who may open the app', function()
        devices:RegisterApp({ id = 'gate', entry = 'a.js', access = { handler = true } })
        assert_true(devices:RegisterAppHandlers('gate', {
            __access = function(src) return src == 3 end,
            ping = function() return { pong = true } end,
        }))
        player(3); player(4)
        assert_true(PFDevices.CanUseApp(3, 'gate'))
        assert_false(PFDevices.CanUseApp(4, 'gate'))
        assert_eq(rpc(3, 'gate', 'ping').pong, true)
        assert_eq(rpc(4, 'gate', 'ping').error, 'not_authorized')
    end)

    it('a website handler registered through RegisterSiteHandler answers', function()
        invoking = 'pf-news'
        startedResources['pf-news'] = true
        assert_true(devices:RegisterSite({ host = 'news.ls', entry = 'site.js' }))
        assert_true(devices:RegisterSiteHandler('news.ls', 'front', function() return { items = { 'a' } } end))
        player(6)
        local appId = PFDevices.GetSite('news.ls').appId
        assert_eq(rpc(6, appId, 'front').items[1], 'a')
    end)

    it('still refuses what is not callable', function()
        devices:RegisterApp({ id = 'taxi', entry = 'a.js' })
        local ok, err = devices:RegisterAppHandler('taxi', 'x', 'not a function')
        assert_false(ok)
        assert_eq(err, 'bad handler')
        assert_false((devices:RegisterAppHandler('taxi', 'y', { plain = 'table' })))
    end)
end)
