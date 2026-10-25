-- Smaller job-group fixes: server-only events are not client events any more (pf-scoreboard,
-- pf-tablet / pf-jobs business refresh, pf-jobs garbage XP and bus tables), the elevator takes only
-- real floors from players at the shaft, and pf-jobs loads one Gruppe6 server, not two.
load_resource('tests/lua/fivem_mocks.lua')
QBCore = QBCoreMock
QBCoreMock.Functions.GetPlayers = function() return {} end
local timeouts = {}
function SetTimeout(_, fn) timeouts[#timeouts + 1] = fn end
function GetResourcePath() return nil end

load_resource('[pfscripts]/pf-scoreboard/server/main.lua')
-- both business apps listen to the same server event; the mock keeps one handler per name
local dutyHandlers = {}
local realAddEventHandler = AddEventHandler
AddEventHandler = function(name, fn)
    if name == 'QBCore:Server:SetDuty' then dutyHandlers[#dutyHandlers + 1] = fn end
    return realAddEventHandler(name, fn)
end
Config = {}
load_resource('[pfscripts]/pf-tablet/server/apps/business.lua')
load_resource('[pfscripts]/pf-jobs/server/apps/business.lua')
AddEventHandler = realAddEventHandler
Config = nil
load_resource('[pfscripts]/pf-elevator/config.lua')
load_resource('[pfscripts]/pf-elevator/server.lua')

local P = 1
local function named(name) return #Mock.clientEventsNamed(name) end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords, timeouts = {}, {}, {}
    Mock.newPlayer(P)
end

describe('job group: server-only events and small checks', function()
    it('clients cannot put scoreboard text on other screens', function()
        assert_eq(Mock.netHandlers['pf-scoreboard:server:showForPlayer'], nil)
        assert_eq(Mock.netHandlers['pf-scoreboard:server:updateForPlayer'], nil)
        assert_eq(Mock.netHandlers['pf-scoreboard:server:hideForPlayer'], nil)
        -- other resources still use them on the server
        TriggerEvent('pf-scoreboard:server:showForPlayer', 5, 'Title', 'Sub', '1/2')
        assert_eq(Mock.clientEventsNamed('pf-scoreboard:client:show')[1].target, 5)
    end)

    it('QBCore:Server:OnJobUpdate and QBCore:ToggleDuty are not client events here, and duty pushes are limited', function()
        assert_eq(Mock.netHandlers['QBCore:Server:OnJobUpdate'], nil)
        assert_eq(Mock.netHandlers['QBCore:ToggleDuty'], nil, 'refreshes follow pfm-core QBCore:Server:SetDuty')
        assert_eq(#dutyHandlers, 2)
        Mock.gameTimer = Mock.gameTimer + 5000
        for _ = 1, 20 do for _, fn in ipairs(dutyHandlers) do fn(P, true) end end
        assert_eq(named('pf-tablet:client:businessPushRefresh'), 1)
        assert_eq(named('pf-jobs:client:businessPushRefresh'), 1)
        -- the change made inside that second is still pushed once afterwards
        Mock.gameTimer = Mock.gameTimer + 5000
        for _, fn in ipairs(timeouts) do fn() end
        assert_eq(named('pf-tablet:client:businessPushRefresh'), 2)
        assert_eq(named('pf-jobs:client:businessPushRefresh'), 2)
    end)

    it('the elevator takes only real floors, from players at the shaft', function()
        local shaft = Config.Elevators.spawnPos
        Mock.coords[P] = vector3(0, 0, 0)
        Mock.fireNet('pf-elevator:requestFloor', P, 2)
        assert_eq(named('pf-elevator:startMoving'), 0)
        Mock.coords[P] = vector3(shaft.x + 2, shaft.y, 120.0)
        Mock.fireNet('pf-elevator:requestFloor', P, 'x')
        Mock.fireNet('pf-elevator:requestFloor', P, 99)
        assert_eq(named('pf-elevator:startMoving'), 0)
        Mock.fireNet('pf-elevator:requestFloor', P, 2)
        assert_eq(named('pf-elevator:startMoving'), 1)
    end)

    it('pf-jobs loads only the apps Gruppe6 server', function()
        local manifest = __readfile('[pfscripts]/pf-jobs/fxmanifest.lua')
        local code = manifest:gsub('%-%-[^\n]*', '')
        assert_eq(code:find("'server/*.lua'", 1, true), nil)
        assert_eq(code:find('server/gruppe6.lua', 1, true), nil)
        assert_true(code:find("'server/apps/*.lua'", 1, true) ~= nil)
    end)
end)
