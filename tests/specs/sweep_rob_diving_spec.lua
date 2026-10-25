-- pfm-diving: a coral is claimed before its items are handed out, and the police tip-off is placed
-- by the server, at the dive area, for the officers only.
load_resource('tests/lua/fivem_mocks.lua')

Grants = {} -- [src] = number of AddItem calls
OnFirstGrant = nil
Mock.exportsByResource['pfm-inventory'] = {
    AddItem = function(_, src)
        Grants[src] = (Grants[src] or 0) + 1
        -- the real grant loop waits between items; another request can arrive in that gap
        local hook = OnFirstGrant
        OnFirstGrant = nil
        if hook then hook() end
        return true
    end,
}
setmetatable(QBCoreMock.Shared.Items, { __index = function(_, k) return { name = k, label = k } end })

load_resource('pfm-diving/config.lua')
load_resource('pfm-diving/server/main.lua')

local D1, D2, COP, COP2 = 1, 2, 3, 4

local function currentArea()
    local _, area = Mock.callCallback('qb-diving:server:GetDivingConfig', D1)
    return area
end

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 1000
    Mock.players, Mock.coords, Grants = {}, {}, {}
    Mock.newPlayer(D1)
    Mock.newPlayer(D2)
    Mock.newPlayer(COP).PlayerData.job = { name = 'police', type = 'leo', onduty = true }
    Mock.newPlayer(COP2).PlayerData.job = { name = 'police', type = 'leo', onduty = true }
end

describe('diving corals', function()
    it('a coral taken by two divers at once pays only the first', function()
        local area = currentArea()
        local c = Config.CoralLocations[area].coords.Coral[1].coords
        Mock.coords[D1] = vector3(c.x, c.y, c.z)
        Mock.coords[D2] = vector3(c.x + 1, c.y, c.z)
        OnFirstGrant = function() Mock.fireNet('qb-diving:server:TakeCoral', D2, area, 1, true) end
        Mock.fireNet('qb-diving:server:TakeCoral', D1, area, 1, true)
        assert_true((Grants[D1] or 0) > 0)
        assert_eq(Grants[D2], nil)
        -- and the coral stays taken
        Mock.clock = Mock.clock + 10
        Mock.fireNet('qb-diving:server:TakeCoral', D2, area, 1, true)
        assert_eq(Grants[D2], nil)
    end)
    it('taking every coral of the area moves the dive to another area', function()
        local area = currentArea()
        local corals = Config.CoralLocations[area].coords.Coral
        for i = 1, #corals do
            local c = corals[i].coords
            Mock.coords[D1] = vector3(c.x, c.y, c.z)
            Mock.clock = Mock.clock + 10
            Mock.fireNet('qb-diving:server:TakeCoral', D1, area, i, true)
        end
        assert_true(currentArea() ~= area)
        assert_eq(Config.CoralLocations[area].TotalCoral, Config.CoralLocations[area].DefaultCoral)
        assert_eq(#Mock.clientEventsNamed('qb-diving:client:NewLocations'), 1)
    end)
end)

describe('diving police tip-off', function()
    it('is ignored away from the dive area, whatever spot the client names', function()
        Mock.coords[D1] = vector3(0, 0, 0)
        Mock.fireNet('qb-diving:server:CallCops', D1, vector3(0, 0, 0))
        assert_eq(#Mock.clientEventsNamed('qb-diving:client:CallCops'), 0)
        assert_eq(#Mock.clientEventsNamed('qb-phone:client:addPoliceAlert'), 0)
    end)
    it('goes to each officer once, at the diver, and at most once a minute', function()
        local c = Config.CoralLocations[currentArea()].coords.Coral[1].coords
        Mock.coords[D1] = vector3(c.x, c.y, c.z)
        Mock.fireNet('qb-diving:server:CallCops', D1, vector3(100, 200, 0))
        local alerts = Mock.clientEventsNamed('qb-phone:client:addPoliceAlert')
        assert_eq(#alerts, 2)
        for _, a in ipairs(alerts) do
            assert_true(a.target == COP or a.target == COP2)
            assert_eq(a.args[1].coords.x, c.x)
        end
        assert_eq(#Mock.clientEventsNamed('qb-diving:client:CallCops'), 2)
        Mock.clock = Mock.clock + 30
        Mock.fireNet('qb-diving:server:CallCops', D1)
        assert_eq(#Mock.clientEventsNamed('qb-phone:client:addPoliceAlert'), 2)
    end)
end)
