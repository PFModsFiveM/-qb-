-- pfm-newsjob (mocked): duty at the duty point; the equipment needs a reporter on duty; the newsroom sees who is out.
load_resource('tests/lua/fivem_mocks.lua')
function GetCurrentResourceName() return 'pfm-newsjob' end
Config = nil
load_resource('pfm-newsjob/config.lua')
local grants, inventories, items, keys = {}, {}, {}, {}
Mock.exportsByResource['pfm-core'].GrantVehicleSpawn = function(_, src, model) grants[#grants + 1] = { src = src, model = model } return true end
Mock.exportsByResource['pfm-inventory'] = {
    CreateInventory = function(_, id) inventories[id] = true end,
    AddItem = function(_, id, name) items[#items + 1] = { id = id, name = name } return true end,
}
Mock.exportsByResource['pfm-vehiclekeys'] = { HasKeys = function(_, src, plate) return keys[src .. ':' .. plate] == true end }
local onJob
local realAdd = AddEventHandler
AddEventHandler = function(name, fn) if name == 'QBCore:Server:OnJobUpdate' then onJob = fn end return realAdd(name, fn) end
load_resource('pfm-newsjob/server/main.lua')
AddEventHandler = realAdd
local fieldStatus = Mock.selfExport('GetFieldStatus')

local REP, OTHER = 1, 2
local function at(src, c) Mock.coords[src] = vector3(c.x, c.y, c.z) end
BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords, Mock.vehicleOf, Mock.plates = {}, {}, {}, {}
    grants, inventories, items, keys = {}, {}, {}, {}
    NewsJob.__reset()
    Mock.clock = Mock.clock + 100
    local p = Mock.newPlayer(REP, 'CIDREP')
    p.PlayerData.job = { name = 'reporter', grade = { level = 0 }, onduty = true }
    p.Functions.SetJobDuty = function(v) p.PlayerData.job.onduty = v end
    Mock.newPlayer(OTHER, 'CIDOTHER').PlayerData.job = { name = 'police', grade = { level = 4 }, onduty = true }
end

-- The vehicle lock, the server spawn and the trunk stocking are covered by fix9hq_newsjob_vehicle_lock_spec.lua
-- (the old ticket design these cases tested was replaced).

describe('pfm-newsjob duty and equipment', function()
    it('duty toggles only for reporters at the duty point and tells the server', function()
        assert_eq(select(2, NewsJob.ToggleDuty(OTHER)), 'not_reporter')
        assert_eq(select(2, NewsJob.ToggleDuty(REP)), 'too_far')
        at(REP, Config.Locations.duty.coords)
        local ok, onduty = NewsJob.ToggleDuty(REP)
        assert_true(ok)
        assert_false(onduty)
        assert_false(Mock.players[REP].PlayerData.job.onduty)
        local fired = false
        for _, e in ipairs(Mock.serverEvents) do if e.name == 'QBCore:Server:SetDuty' then fired = true end end
        assert_true(fired, 'pf-devices and pf-news refresh on QBCore:Server:SetDuty')
    end)

    it('the camera and mics need a reporter on duty', function()
        Mock.useables.newscam(OTHER)
        assert_eq(#Mock.clientEventsNamed('Cam:ToggleCam'), 0)
        Mock.players[REP].PlayerData.job.onduty = false
        Mock.useables.newsmic(REP)
        assert_eq(#Mock.clientEventsNamed('Mic:ToggleMic'), 0)
        Mock.players[REP].PlayerData.job.onduty = true
        Mock.useables.newsbmic(REP)
        assert_eq(#Mock.clientEventsNamed('Mic:ToggleBMic'), 1)
        assert_true(Mock.selfExport('IsOnDuty')(REP))
        assert_false(Mock.selfExport('IsOnDuty')(OTHER))
    end)
end)
