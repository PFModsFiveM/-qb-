-- pf-services loads, its catalog is consistent, and the app handlers register with pf-devices.
load_resource('tests/lua/fivem_mocks.lua')

Config = {}
load_resource('[pfscripts]/pf-services/shared/catalog.lua')
load_resource('[pfscripts]/pf-services/shared/config.lua')
function GetCurrentResourceName() return 'pf-services' end
function GetResourceState(name) return (name == 'pf-devices' or name == 'pfm-core') and 'started' or 'missing' end

local registered, handlers = {}, {}
Mock.exportsByResource['pf-devices'] = {
    RegisterApp = function(_, def) registered[def.id] = def return true end,
    RegisterAppHandlers = function(_, id, map) handlers[id] = map return true end,
    PushToJob = function() return 0 end,
    PushToCitizen = function() return true end,
}

load_resource('[pfscripts]/pf-services/server/schema.lua')
load_resource('[pfscripts]/pf-services/server/events.lua')
load_resource('[pfscripts]/pf-services/server/requests.lua')
load_resource('[pfscripts]/pf-services/server/apps.lua')
load_resource('[pfscripts]/pf-services/server/main.lua')

describe('pf-services catalog', function()
    it('every event kind has a valid news mode and every request kind a job', function()
        for kind, def in pairs(PFCatalog.Events) do
            assert_true(def.news == 'auto' or def.news == 'lead' or def.news == 'none', kind .. ' news mode')
            assert_true(type(def.label) == 'string', kind .. ' label')
        end
        for kind, def in pairs(PFCatalog.Requests) do
            assert_true(type(def.job) == 'string' or type(def.job) == 'table', kind .. ' job')
            assert_true(def.payer == 'none' or def.payer == 'requester' or def.payer:match('^society:') ~= nil, kind .. ' payer')
            assert_true(type(def.reward) == 'number' and def.reward >= 0, kind .. ' reward')
        end
    end)

    it('police events point at a request kind that exists', function()
        assert_true(PFCatalog.Requests['police.assist'] ~= nil)
    end)

    it('lists the kinds each job works, including shared kinds', function()
        local mech = table.concat(PFServices.KindsForJob('bennys'), ',')
        assert_eq(mech, 'mechanic.roadside')
        local tow = table.concat(PFServices.KindsForJob('tow'), ',')
        assert_eq(tow, 'tow.impound,tow.recovery')
    end)
end)

describe('pf-services apps', function()
    it('registers Dispatch and Services with pf-devices', function()
        PFServices.RegisterApps()
        assert_true(registered.dispatch ~= nil)
        assert_true(registered.services ~= nil)
        assert_true(registered.directory ~= nil)
        local dir = handlers.directory.list(1)
        assert_true(dir.ok)
        assert_true(#dir.services > 0)
        assert_eq(handlers.directory.waypoint(1, { id = 'nope' }).error, 'no_location')
        assert_true(registered.dispatch.access.handler == true)
        assert_true(type(handlers.dispatch.__access) == 'function')
        local p = Mock.newPlayer(1)
        p.PlayerData.job = { name = 'tow', onduty = true, grade = { level = 0 } }
        assert_true(handlers.dispatch.__access(1))
        p.PlayerData.job = { name = 'unemployed', onduty = true, grade = { level = 0 } }
        assert_false(handlers.dispatch.__access(1))
        local kinds = handlers.services.kinds(1).kinds
        local names = {}
        for _, k in ipairs(kinds) do names[#names + 1] = k.kind end
        table.sort(names)
        assert_eq(table.concat(names, ','), 'ems.patient,mechanic.roadside,police.assist,taxi.ride,tow.recovery')
    end)
end)

describe('pf-services events', function()
    it('refuses unknown kinds and dedupes repeated events', function()
        PFServices.__resetEvents()
        local seen = {}
        PFServices.OnEvent(function(ev) seen[#seen + 1] = ev end)
        assert_eq(PFServices.Emit('nope', {}), nil)
        local ev = PFServices.Emit('gov.tax.changed', { tax = 'sales', newRate = 7 }, { title = 'Sales tax 7%', dedupe = 'sales' })
        assert_true(ev ~= nil)
        assert_eq(ev.news, 'auto')
        local again, err = PFServices.Emit('gov.tax.changed', { tax = 'sales', newRate = 8 }, { dedupe = 'sales' })
        assert_eq(again, nil)
        assert_eq(err, 'duplicate')
        assert_eq(#seen, 1)
        assert_true(PFServices.RegisterEventKind('custom.thing', { news = 'lead', label = 'Thing' }))
        assert_eq(PFServices.Emit('custom.thing', {}).news, 'lead')
        assert_false((PFServices.RegisterEventKind('bad kind!', {})))
    end)
end)

describe('police and EMS dispatch is their MDT', function()
    it('a police or EMS request becomes a call on that MDT; the Dispatch app is not theirs while it runs', function()
        local calls = {}
        local mdtStarted = { ['pf-policemdt-DEV'] = true, ['pf-emsmdt'] = true }
        local realState = GetResourceState
        GetResourceState = function(name) if mdtStarted[name] then return 'started' end return realState(name) end
        Mock.exportsByResource['pf-policemdt-DEV'] = { CreateDispatchCall = function(_, c) calls[#calls + 1] = { mdt = 'police', call = c } return c end }
        Mock.exportsByResource['pf-emsmdt'] = { CreateDispatchCall = function(_, c) calls[#calls + 1] = { mdt = 'ems', call = c } return c end }
        local fire = Mock.eventHandlers['pf-services:requestChanged']
        fire({ id = 1, kind = 'police.assist', title = 'Robbery at Ltd', coords = { x = 1, y = 2, z = 3 }, from = { name = 'Alarm' } }, 'created')
        fire({ id = 2, kind = 'ems.patient', title = 'Person down', coords = { x = 4, y = 5, z = 6 } }, 'created')
        fire({ id = 3, kind = 'tow.recovery', title = 'Tow' }, 'created')
        fire({ id = 1, kind = 'police.assist' }, 'accepted')
        assert_eq(#calls, 2, 'only police and EMS creations')
        assert_eq(calls[1].mdt, 'police')
        assert_eq(calls[1].call.title, 'Robbery at Ltd')
        assert_eq(calls[1].call.coords.x, 1)
        assert_eq(calls[2].mdt, 'ems')
        assert_eq(calls[2].call.priority, 1)
        PFServices.RegisterApps()
        local p = Mock.newPlayer(9)
        p.PlayerData.job = { name = 'police', onduty = true, grade = { level = 1 } }
        assert_false(handlers.dispatch.__access(9), 'police use the MDT app')
        p.PlayerData.job = { name = 'tow', onduty = true, grade = { level = 0 } }
        assert_true(handlers.dispatch.__access(9), 'tow keeps the Dispatch app')
        mdtStarted['pf-policemdt-DEV'] = nil
        p.PlayerData.job = { name = 'police', onduty = true, grade = { level = 1 } }
        assert_true(handlers.dispatch.__access(9), 'without the MDT police fall back to the Dispatch app')
        GetResourceState = realState
    end)
end)
