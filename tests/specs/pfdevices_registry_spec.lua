-- pf-devices: the shared app registry, access rules and per-device app lists.
load_resource('tests/lua/fivem_mocks.lua')

Config = {}
load_resource('[pfscripts]/pf-devices/shared/config.lua')

local startedResources = { ['pf-jobs'] = true, ['pf-government'] = true, ['pf-devices'] = true }
function GetResourceState(name) return startedResources[name] and 'started' or 'missing' end
function GetCurrentResourceName() return 'pf-devices' end
local invoking = 'pf-jobs'
function GetInvokingResource() return invoking end

local govPerms = {}
Mock.exportsByResource['pf-government'] = {
    HasPermission = function(_, src, perm) return govPerms[src] ~= nil and govPerms[src][perm] == true end,
}
Mock.exportsByResource['pf-x'] = {
    CanUseApp = function(_, src, appId) return src == 7 and appId == 'checked' end,
}

load_resource('[pfscripts]/pf-devices/server/registry.lua')
load_resource('[pfscripts]/pf-devices/server/installs.lua')
load_resource('[pfscripts]/pf-devices/server/push.lua')

local function player(src, job, grade, onduty)
    local p = Mock.newPlayer(src)
    p.PlayerData.job = { name = job or 'unemployed', grade = { level = grade or 0, name = 'g' }, onduty = onduty == true }
    return p
end

local function ids(list)
    local out = {}
    for _, a in ipairs(list) do out[#out + 1] = a.id end
    table.sort(out)
    return table.concat(out, ',')
end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    PFDevices.__reset()
    PFDevices.__resetInstalls()
    invoking = 'pf-jobs'
    govPerms = {}
end

describe('pf-devices registry', function()
    it('rejects bad definitions and accepts a normal one', function()
        assert_false((PFDevices.RegisterApp({ name = 'no id' }, 'pf-jobs')))
        assert_false((PFDevices.RegisterApp({ id = 'x', entry = 'https://evil/x.js' }, 'pf-jobs')), 'remote entry refused')
        assert_false((PFDevices.RegisterApp({ id = 'x', entry = '../x.js' }, 'pf-jobs')), 'path traversal refused')
        assert_false((PFDevices.RegisterApp({ id = 'x', kind = 'iframe', url = 'https://example.com/a' }, 'pf-jobs')), 'iframe must be cfx-nui')
        assert_false((PFDevices.RegisterApp({ id = 'x', entry = 'a.js', access = { jobs = {} } }, 'pf-jobs')), 'empty jobs rule refused')
        assert_true((PFDevices.RegisterApp({ id = 'Taxi', entry = 'html/apps/taxi.js', styles = { 'html/css/taxi.css' }, category = 'jobs', devices = { 'tablet', 'bogus' } }, 'pf-jobs')))
        local app = PFDevices.GetApp('taxi')
        assert_eq(app.id, 'taxi', 'ids are lower-cased')
        assert_eq(app.resource, 'pf-jobs')
        assert_eq(#app.devices, 1)
        assert_eq(app.devices[1], 'tablet', 'unknown devices dropped')
        assert_eq(app.category, 'jobs')
        assert_true(app.access.anyone, 'default access is anyone')
    end)

    it('builds public URLs from the owning resource and lists apps by device', function()
        PFDevices.RegisterApp({ id = 'taxi', entry = 'html/apps/taxi.js', styles = { 'html/css/taxi.css' }, devices = { 'tablet' } }, 'pf-jobs')
        PFDevices.RegisterApp({ id = 'both', entry = 'a.js' }, 'pf-jobs')
        player(1)
        local tablet = PFDevices.GetAppsFor(1, 'tablet')
        assert_eq(ids(tablet.apps), 'both,taxi')
        local computer = PFDevices.GetAppsFor(1, 'computer')
        assert_eq(ids(computer.apps), 'both')
        local taxi
        for _, a in ipairs(tablet.apps) do if a.id == 'taxi' then taxi = a end end
        assert_eq(taxi.entry, 'https://cfx-nui-pf-jobs/html/apps/taxi.js')
        assert_eq(taxi.styles[1], 'https://cfx-nui-pf-jobs/html/css/taxi.css')
        assert_eq(taxi.access, nil, 'access rules are not sent to clients')
        assert_eq(PFDevices.GetAppsFor(1, 'phone').error, 'unknown_device')
    end)

    it('hides apps whose resource is not started', function()
        PFDevices.RegisterApp({ id = 'ghost', entry = 'a.js' }, 'pf-stopped')
        player(1)
        assert_eq(ids(PFDevices.GetAppsFor(1, 'tablet').apps), '')
        startedResources['pf-stopped'] = true
        assert_eq(ids(PFDevices.GetAppsFor(1, 'tablet').apps), 'ghost')
        startedResources['pf-stopped'] = nil
    end)

    it('applies job, grade and duty rules on the server', function()
        PFDevices.RegisterApp({ id = 'taxi', entry = 'a.js', access = { jobs = { taxi = 0 } } }, 'pf-jobs')
        PFDevices.RegisterApp({ id = 'boss', entry = 'a.js', access = { jobs = { taxi = 3 } } }, 'pf-jobs')
        PFDevices.RegisterApp({ id = 'duty', entry = 'a.js', access = { jobs = { 'police' }, onduty = true } }, 'pf-jobs')
        player(1, 'taxi', 1, false)
        player(2, 'taxi', 3, false)
        player(3, 'police', 0, false)
        player(4, 'police', 0, true)
        player(5, 'unemployed')
        assert_eq(ids(PFDevices.GetAppsFor(1, 'tablet').apps), 'taxi')
        assert_eq(ids(PFDevices.GetAppsFor(2, 'tablet').apps), 'boss,taxi')
        assert_eq(ids(PFDevices.GetAppsFor(3, 'tablet').apps), '', 'off duty sees nothing')
        assert_eq(ids(PFDevices.GetAppsFor(4, 'tablet').apps), 'duty')
        assert_eq(ids(PFDevices.GetAppsFor(5, 'tablet').apps), '')
        assert_false(PFDevices.CanAccess(99, 'taxi'), 'unknown player refused')
    end)

    it('applies government permissions, external checks and admin rules', function()
        PFDevices.RegisterApp({ id = 'fines', entry = 'a.js', access = { gov = { 'fines.issue', 'fines.view' } } }, 'pf-government')
        PFDevices.RegisterApp({ id = 'checked', entry = 'a.js', access = { check = { resource = 'pf-x', export = 'CanUseApp' } } }, 'pf-jobs')
        PFDevices.RegisterApp({ id = 'admin', entry = 'a.js', access = { admin = true } }, 'pf-jobs')
        player(6); player(7); player(8)
        govPerms[6] = { ['fines.view'] = true }
        Mock.aces[8] = { command = true }
        assert_eq(ids(PFDevices.GetAppsFor(6, 'tablet').apps), 'fines')
        assert_eq(ids(PFDevices.GetAppsFor(7, 'tablet').apps), '', 'pf-x is not started')
        startedResources['pf-x'] = true
        assert_eq(ids(PFDevices.GetAppsFor(7, 'tablet').apps), 'checked')
        startedResources['pf-x'] = nil
        assert_eq(ids(PFDevices.GetAppsFor(8, 'tablet').apps), 'admin')
    end)

    it('uses the app handler __access when asked', function()
        PFDevices.RegisterApp({ id = 'owner', entry = 'a.js', access = { handler = true } }, 'pf-jobs')
        player(1); player(2)
        assert_false(PFDevices.CanAccess(1, 'owner'), 'no handler yet: refused')
        PFDevices.RegisterAppHandler('owner', '__access', function(src) return src == 2 end, 'pf-jobs')
        assert_false(PFDevices.CanAccess(1, 'owner'))
        assert_true(PFDevices.CanAccess(2, 'owner'))
    end)

    it('keeps an app id with its owner and drops everything when the resource stops', function()
        PFDevices.RegisterApp({ id = 'taxi', entry = 'a.js' }, 'pf-jobs')
        assert_false((PFDevices.RegisterApp({ id = 'taxi', entry = 'b.js' }, 'pf-other')), 'another started resource cannot take the id')
        assert_true((PFDevices.RegisterApp({ id = 'taxi', entry = 'c.js', name = 'Taxi 2' }, 'pf-jobs')), 'the owner may replace it')
        assert_eq(PFDevices.GetApp('taxi').name, 'Taxi 2')
        PFDevices.RegisterAppHandler('taxi', 'getInit', function() return { ok = true } end, 'pf-jobs')
        assert_false((PFDevices.RegisterAppHandler('taxi', 'hack', function() end, 'pf-other')), 'handlers only from the owner')
        Mock.fireEvent('onResourceStop', nil, 'pf-jobs')
        assert_eq(PFDevices.GetApp('taxi'), nil)
        assert_eq(PFDevices.GetHandler('taxi', 'getInit'), nil)
        -- the id is free again
        assert_true((PFDevices.RegisterApp({ id = 'taxi', entry = 'b.js' }, 'pf-other')))
    end)

    it('tells clients when the list changes', function()
        PFDevices.RegisterApp({ id = 'taxi', entry = 'a.js' }, 'pf-jobs')
        local pushes = Mock.clientEventsNamed('pf-devices:client:appsChanged')
        assert_true(#pushes >= 1)
        assert_eq(pushes[1].target, -1)
    end)

    it('sorts by order then name', function()
        PFDevices.RegisterApp({ id = 'b', entry = 'a.js', order = 5 }, 'pf-jobs')
        PFDevices.RegisterApp({ id = 'a', entry = 'a.js', order = 5 }, 'pf-jobs')
        PFDevices.RegisterApp({ id = 'z', entry = 'a.js', order = 1 }, 'pf-jobs')
        local list = PFDevices.GetApps()
        assert_eq(list[1].id .. list[2].id .. list[3].id, 'zab')
    end)
end)

describe('pf-devices installable apps', function()
    it('lists installable apps in the store until installed, then on the home screen', function()
        PFDevices.RegisterApp({ id = 'news', entry = 'a.js', access = { installable = true } }, 'pf-jobs')
        PFDevices.RegisterApp({ id = 'paid', entry = 'a.js', access = { installable = true }, store = { price = 250, description = 'Paid app' } }, 'pf-jobs')
        local p = player(1)
        local view = PFDevices.GetAppsFor(1, 'tablet')
        assert_eq(ids(view.apps), '')
        assert_eq(ids(view.store), 'news,paid')
        assert_eq(view.store[2].store.price, 250)
        assert_false(select(1, PFDevices.CanUseApp(1, 'news')))
        local res = PFDevices.InstallApp(1, 'news')
        assert_true(res.ok, res.error)
        assert_true(PFDevices.IsAppInstalled(p.PlayerData.citizenid, 'news'))
        view = PFDevices.GetAppsFor(1, 'tablet')
        assert_eq(ids(view.apps), 'news')
        assert_eq(view.apps[1].installed, true)
        assert_eq(ids(view.store), 'paid')
        assert_true(select(1, PFDevices.CanUseApp(1, 'news')))
        -- the row went to the database
        local inserted = false
        for _, c in ipairs(Mock.dbCalls) do if c.kind == 'insert' and c.query:find('pf_device_apps') then inserted = true end end
        assert_true(inserted, 'install written to pf_device_apps')
        assert_eq(PFDevices.InstallApp(1, 'news').already, true, 'installing twice is a no-op')
        assert_true(PFDevices.UninstallApp(1, 'news').ok)
        assert_eq(ids(PFDevices.GetAppsFor(1, 'tablet').apps), '')
    end)

    it('refuses to install what the player may not use, or what is not installable', function()
        PFDevices.RegisterApp({ id = 'news', entry = 'a.js', access = { installable = true, jobs = { 'reporter' } } }, 'pf-jobs')
        PFDevices.RegisterApp({ id = 'taxi', entry = 'a.js' }, 'pf-jobs')
        player(1, 'unemployed')
        assert_eq(PFDevices.InstallApp(1, 'news').error, 'not_authorized')
        assert_eq(PFDevices.InstallApp(1, 'taxi').error, 'not_installable')
        assert_eq(PFDevices.InstallApp(1, 'nope').error, 'unknown_app')
    end)

    it('charges a paid app through PFPayout and refuses when the charge fails', function()
        PFDevices.RegisterApp({ id = 'paid', entry = 'a.js', access = { installable = true }, store = { price = 250 } }, 'pf-jobs')
        local p = player(1)
        local charges = {}
        PFPayout = { Charge = function(who, accounts, amount, opts) charges[#charges + 1] = { who = who, amount = amount, key = opts.key }; return amount == 250 and 'bank' or nil end }
        assert_true(PFDevices.InstallApp(1, 'paid').ok)
        assert_eq(#charges, 1)
        assert_eq(charges[1].amount, 250)
        assert_eq(charges[1].key, 'pf-devices:install:' .. p.PlayerData.citizenid .. ':paid', 'idempotent charge key')
        PFDevices.UninstallApp(1, 'paid')
        PFPayout.Charge = function() return nil end
        assert_eq(PFDevices.InstallApp(1, 'paid').error, 'payment_failed')
        assert_false(PFDevices.IsAppInstalled(p.PlayerData.citizenid, 'paid'))
        PFPayout = nil
    end)
end)

describe('pf-devices push channel', function()
    it('pushes to one player, a job on duty, a citizen and everyone', function()
        player(1, 'police', 0, true)
        player(2, 'police', 0, false)
        player(3, 'taxi', 0, true)
        Mock.players[1].PlayerData.source = 1
        Mock.players[2].PlayerData.source = 2
        Mock.players[3].PlayerData.source = 3
        assert_true(PFDevices.Push(3, 'taxi', 'callsData', { 1 }))
        local n = PFDevices.PushToJob('police', 'policemdt', 'dispatch', { id = 1 }, true)
        assert_eq(n, 1, 'only the on-duty officer')
        assert_true(PFDevices.PushToCitizen(Mock.players[2].PlayerData.citizenid, 'mdt', 'ping', {}))
        assert_true(PFDevices.Broadcast('news', 'published', { id = 1 }))
        local events = Mock.clientEventsNamed('pf-devices:client:appEvent')
        assert_eq(#events, 4)
        assert_eq(events[1].target, 3)
        assert_eq(events[1].args[1], 'taxi')
        assert_eq(events[2].target, 1)
        assert_eq(events[3].target, 2)
        assert_eq(events[4].target, -1)
        assert_false(PFDevices.Push('abc', 'taxi', 'x'), 'bad target refused')
    end)
end)
