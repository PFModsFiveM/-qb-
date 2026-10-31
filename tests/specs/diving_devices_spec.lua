-- pfm-diving Dive Guide app: today's area with the coral left, prices, buyers; waypoints only to
-- real places; open apps refresh when the area moves.
load_resource('tests/lua/fivem_mocks.lua')
setmetatable(QBCoreMock.Shared.Items, { __index = function(_, k) return { name = k, label = 'L:' .. k } end })
function GetResourceState(name) return (name == 'pf-devices') and 'started' or 'missing' end
local app, broadcasts = {}, {}
Mock.exportsByResource['pf-devices'] = {
    RegisterApp = function(_, def) app.def = def return true end,
    RegisterAppHandlers = function(_, id, map) app.h = map return true end,
    Broadcast = function(_, id, event) broadcasts[#broadcasts + 1] = { id = id, event = event } return true end,
}
load_resource('pfm-diving/config.lua')
load_resource('pfm-diving/server/main.lua')
Mock.eventHandlers['pf-devices:server:ready']()

describe('Dive Guide app', function()
    it('is installable and shows the current area, coral left, prices and buyers', function()
        assert_eq(app.def.id, 'diveguide')
        assert_true(app.def.access.installable)
        local _, area = Mock.callCallback('qb-diving:server:GetDivingConfig', 1)
        local d = app.h.status(1, {})
        assert_eq(d.area, Config.CoralLocations[area].label)
        assert_true(d.total > 0)
        assert_eq(d.left, d.total)
        assert_eq(#d.corals, #Config.CoralTypes)
        assert_eq(d.corals[1].label, 'L:' .. Config.CoralTypes[1].item)
        assert_true(#d.buyers >= 1)
    end)
    it('waypoints to the area and to a buyer, nothing else', function()
        assert_true(app.h.waypoint(1, { target = 'area' }).ok)
        assert_true(app.h.waypoint(1, { target = 'buyer', id = 1 }).ok)
        assert_eq(app.h.waypoint(1, { target = 'buyer', id = 42 }).error, 'unknown_place')
        assert_eq(#Mock.clientEventsNamed('qb-diving:client:waypoint'), 2)
    end)
    it('a moved area refreshes open apps', function()
        TriggerEvent('pfm-diving:server:areaChanged')
        assert_eq(broadcasts[#broadcasts].id, 'diveguide')
    end)
end)
