-- pf-devices: the RPC bridge (routing, access, limits, errors) and the built-in apps.
load_resource('tests/lua/fivem_mocks.lua')

Config = {}
load_resource('[pfscripts]/pf-devices/shared/config.lua')
Config.Rpc.burst = 5
Config.Rpc.perSecond = 1000

local startedResources = { ['pf-jobs'] = true, ['pf-devices'] = true, ['pfm-core'] = true }
function GetResourceState(name) return startedResources[name] and 'started' or 'missing' end
function GetCurrentResourceName() return 'pf-devices' end
function GetInvokingResource() return 'pf-jobs' end

-- GetGameTimer in the mocks advances one millisecond per call; the limiter needs real time control
local clock = 0
function GetGameTimer() return clock end

Mock.exportsByResource['pf-legacy'] = {
    AppRpc = function(_, src, appId, method, payload) return { ok = true, via = 'export', src = src, method = method } end,
}

load_resource('[pfscripts]/pf-devices/server/registry.lua')
load_resource('[pfscripts]/pf-devices/server/installs.lua')
load_resource('[pfscripts]/pf-devices/server/rpc.lua')
load_resource('[pfscripts]/pf-devices/server/push.lua')
load_resource('[pfscripts]/pf-devices/server/sites.lua')
load_resource('[pfscripts]/pf-devices/server/builtin_apps.lua')
load_resource('[pfscripts]/pf-devices/server/main.lua')

local function player(src, job, grade)
    local p = Mock.newPlayer(src)
    p.PlayerData.job = { name = job or 'unemployed', grade = { level = grade or 0 }, onduty = true }
    p.PlayerData.source = src
    return p
end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    PFDevices.__reset()
    PFDevices.__resetInstalls()
    PFDevices.__resetRpc()
    PFDevices.__resetSites()
    clock = 0
end

describe('pf-devices rpc', function()
    it('routes a call to the owning handler with the real source and defaults ok to true', function()
        PFDevices.RegisterApp({ id = 'taxi', entry = 'a.js', access = { jobs = { 'taxi' } } }, 'pf-jobs')
        local seen
        PFDevices.RegisterAppHandlers('taxi', {
            getInit = function(src, payload, ctx) seen = { src = src, payload = payload, ctx = ctx } return { calls = 3 } end,
            nothing = function() end,
            scalar = function() return 42 end,
        }, 'pf-jobs')
        player(5, 'taxi')
        Mock.fireNet('pf-devices:server:rpc', 5, 1, 'taxi', 'getInit', { a = 1 })
        local replies = Mock.clientEventsNamed('pf-devices:client:rpc')
        assert_eq(#replies, 1)
        assert_eq(replies[1].target, 5)
        assert_eq(replies[1].args[1], 1, 'request id echoed')
        assert_eq(replies[1].args[2].ok, true)
        assert_eq(replies[1].args[2].calls, 3)
        assert_eq(seen.src, 5)
        assert_eq(seen.payload.a, 1)
        assert_eq(seen.ctx.method, 'getInit')
        assert_eq(PFDevices.HandleRpc(5, 'taxi', 'nothing').ok, true, 'nil result becomes ok')
        assert_eq(PFDevices.HandleRpc(5, 'taxi', 'scalar').data, 42, 'scalar result wrapped')
    end)

    it('refuses unknown apps, stopped resources, unauthorized players and unknown methods', function()
        PFDevices.RegisterApp({ id = 'taxi', entry = 'a.js', access = { jobs = { 'taxi' } } }, 'pf-jobs')
        PFDevices.RegisterAppHandler('taxi', 'getInit', function() return {} end, 'pf-jobs')
        PFDevices.RegisterApp({ id = 'ghost', entry = 'a.js' }, 'pf-stopped')
        player(1, 'taxi'); player(2, 'police')
        assert_eq(PFDevices.HandleRpc(1, 'nope', 'x').error, 'unknown_app')
        assert_eq(PFDevices.HandleRpc(1, 'ghost', 'x').error, 'app_offline')
        assert_eq(PFDevices.HandleRpc(2, 'taxi', 'getInit').error, 'not_authorized')
        assert_eq(PFDevices.HandleRpc(1, 'taxi', 'missing').error, 'unknown_method')
        assert_eq(PFDevices.HandleRpc(1, 'taxi', '__access').error, 'unknown_method', 'internal methods are not callable')
        assert_eq(PFDevices.HandleRpc(1, 1, 'x').error, 'bad_request')
        assert_eq(PFDevices.HandleRpc(1, 'taxi', 'getInit', 'notatable').error, 'bad_request')
    end)

    it('requires installation for installable apps', function()
        PFDevices.RegisterApp({ id = 'news', entry = 'a.js', access = { installable = true } }, 'pf-jobs')
        PFDevices.RegisterAppHandler('news', 'latest', function() return { items = {} } end, 'pf-jobs')
        player(1)
        assert_eq(PFDevices.HandleRpc(1, 'news', 'latest').error, 'not_installed')
        PFDevices.InstallApp(1, 'news')
        assert_eq(PFDevices.HandleRpc(1, 'news', 'latest').ok, true)
    end)

    it('turns handler errors into server_error without leaking them', function()
        PFDevices.RegisterApp({ id = 'taxi', entry = 'a.js' }, 'pf-jobs')
        PFDevices.RegisterAppHandler('taxi', 'boom', function() error('secret internal detail') end, 'pf-jobs')
        player(1)
        local res = PFDevices.HandleRpc(1, 'taxi', 'boom')
        assert_eq(res.ok, false)
        assert_eq(res.error, 'server_error')
    end)

    it('rate-limits a player and refuses oversized payloads', function()
        PFDevices.RegisterApp({ id = 'taxi', entry = 'a.js' }, 'pf-jobs')
        PFDevices.RegisterAppHandler('taxi', 'ping', function() return {} end, 'pf-jobs')
        player(1); player(2)
        for _ = 1, 5 do assert_eq(PFDevices.HandleRpc(1, 'taxi', 'ping').ok, true) end
        assert_eq(PFDevices.HandleRpc(1, 'taxi', 'ping').error, 'rate_limited')
        assert_eq(PFDevices.HandleRpc(2, 'taxi', 'ping').ok, true, 'other players unaffected')
        clock = 2000
        assert_eq(PFDevices.HandleRpc(1, 'taxi', 'ping').ok, true, 'tokens refill with time')
        local big = { blob = string.rep('x', Config.Rpc.maxPayloadBytes + 10) }
        assert_eq(PFDevices.HandleRpc(2, 'taxi', 'ping', big).error, 'payload_too_large')
    end)

    it('falls back to the resource AppRpc export when no handler is registered', function()
        startedResources['pf-legacy'] = true
        PFDevices.RegisterApp({ id = 'legacy', entry = 'a.js' }, 'pf-legacy')
        player(1)
        local res = PFDevices.HandleRpc(1, 'legacy', 'anything')
        assert_eq(res.via, 'export')
        assert_eq(res.src, 1)
        startedResources['pf-legacy'] = nil
    end)
end)

describe('pf-devices built-in apps and sites', function()
    it('registers the App Store and the Browser for everyone and serves the store list', function()
        PFDevices.RegisterBuiltinApps()
        PFDevices.RegisterApp({ id = 'news', entry = 'a.js', access = { installable = true } }, 'pf-jobs')
        player(1)
        local view = PFDevices.GetAppsFor(1, 'computer')
        local names = {}
        for _, a in ipairs(view.apps) do names[#names + 1] = a.id end
        table.sort(names)
        assert_eq(table.concat(names, ','), 'appstore,browser')
        local list = PFDevices.HandleRpc(1, 'appstore', 'list', { device = 'computer' })
        assert_eq(#list.store, 1)
        assert_eq(list.store[1].id, 'news')
        assert_eq(PFDevices.HandleRpc(1, 'appstore', 'install', { app = 'news' }).ok, true)
        list = PFDevices.HandleRpc(1, 'appstore', 'list', { device = 'computer' })
        assert_eq(#list.store, 0)
        assert_eq(#list.installed, 1)
    end)

    it('registers sites as hidden apps with handlers and lists them per player', function()
        PFDevices.RegisterBuiltinApps()
        assert_true((PFDevices.RegisterSite({ host = 'News.LS', name = 'Weazel News', entry = 'html/sites/news.js', styles = { 'html/css/news.css' } }, 'pf-jobs')))
        assert_true((PFDevices.RegisterSite({ host = 'gov.ls', name = 'City Hall', entry = 'html/sites/gov.js', access = { jobs = { 'government' } } }, 'pf-jobs')))
        assert_false((PFDevices.RegisterSite({ host = 'news.ls', entry = 'x.js' }, 'pf-other')), 'a host belongs to its owner')
        assert_true((PFDevices.RegisterSiteHandler('news.ls', 'latest', function(src) return { items = { 'a' }, src = src } end, 'pf-jobs')))
        player(1); player(2, 'government')
        local view = PFDevices.GetAppsFor(1, 'tablet')
        for _, a in ipairs(view.apps) do assert_true(a.id ~= 'site-news-ls', 'sites stay off the home screen') end
        local sites = PFDevices.GetSitesFor(1)
        assert_eq(#sites, 1)
        assert_eq(sites[1].host, 'news.ls')
        assert_eq(sites[1].entry, 'https://cfx-nui-pf-jobs/html/sites/news.js')
        assert_eq(#PFDevices.GetSitesFor(2), 2, 'government staff also see gov.ls')
        local res = PFDevices.HandleRpc(1, 'site-news-ls', 'latest')
        assert_eq(res.src, 1)
        assert_eq(res.items[1], 'a')
        local browser = PFDevices.HandleRpc(1, 'browser', 'sites')
        assert_eq(#browser.sites, 1)
        Mock.fireEvent('onResourceStop', nil, 'pf-jobs')
        assert_eq(#PFDevices.GetSitesFor(2), 0)
    end)

    it('exposes the callbacks the shells use', function()
        PFDevices.RegisterBuiltinApps()
        player(1)
        local result = Mock.callCallback('pf-devices:apps', 1, 'tablet')
        assert_eq(#result.apps, 2)
        local sites = Mock.callCallback('pf-devices:sites', 1)
        assert_eq(sites.ok, true)
    end)
end)
