-- pfm-scrapyard Scrap List app: lists the server's wanted cars, refreshes open apps when the list
-- changes, and sets a waypoint only to a real yard.
load_resource('tests/lua/fivem_mocks.lua')
function GetResourceState(name) return (name == 'pf-devices') and 'started' or 'missing' end
Mock.exportsByResource['pfm-core'].GetShared = function(_, key)
    if key == 'Vehicles' then return { blista = { brand = 'Dinka', name = 'Blista' } } end
    return QBCoreMock.Shared[key]
end
local app, broadcasts = {}, {}
Mock.exportsByResource['pf-devices'] = {
    RegisterApp = function(_, def) app.def = def return true end,
    RegisterAppHandlers = function(_, id, map) app.h = map return true end,
    Broadcast = function(_, id, event) broadcasts[#broadcasts + 1] = { id = id, event = event } return true end,
}
Config = nil
load_resource('pfm-scrapyard/config.lua')
load_resource('pfm-scrapyard/server.lua')
load_resource('pfm-scrapyard/server_devices.lua')
Mock.eventHandlers['pf-devices:server:ready']()

describe('Scrap List app', function()
    it('is installable and lists the wanted cars with their names', function()
        assert_eq(app.def.id, 'scraplist')
        assert_true(app.def.access.installable)
        Config.CurrentVehicles = { [1] = 'blista', [3] = 'unknownmodel' }
        local res = app.h.list(1, {})
        assert_eq(#res.vehicles, 2)
        assert_eq(res.vehicles[1].label, 'Dinka Blista')
        assert_eq(res.vehicles[2].label, 'unknownmodel')
        assert_true(#res.yards >= 1)
    end)
    it('a new list refreshes open apps', function()
        broadcasts = {}
        GenerateVehicleList()
        assert_eq(broadcasts[1].id, 'scraplist')
        assert_eq(broadcasts[1].event, 'changed')
    end)
    it('waypoints only to a configured yard', function()
        assert_true(app.h.waypoint(1, { id = 1 }).ok)
        assert_eq(Mock.clientEventsNamed('qb-scrapyard:client:waypoint')[1].target, 1)
        assert_eq(app.h.waypoint(1, { id = 99 }).error, 'unknown_yard')
    end)
end)
