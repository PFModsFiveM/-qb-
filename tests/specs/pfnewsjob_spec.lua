-- pfm-newsjob (mocked): vehicles only with a server-granted ticket for a model the grade may take at
-- that garage, on duty and standing there; the trunk is stocked once for the issued plate only; duty
-- is toggled at the duty point; the equipment needs a reporter on duty; the newsroom sees who is out.
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

describe('pfm-newsjob vehicles', function()
    it('grants a ticket only for an allowed model, on duty, at the garage, one at a time', function()
        at(REP, Config.Locations.vehicle.coords)
        assert_eq(select(2, NewsJob.RequestVehicle(OTHER, 'vehicle', 'rumpo')), 'not_on_duty')
        assert_eq(select(2, NewsJob.RequestVehicle(REP, 'vehicle', 'adder')), 'not_allowed')
        assert_eq(select(2, NewsJob.RequestVehicle(REP, 'vehicle', 'frogger')), 'not_allowed', 'helicopters come from the helipad')
        Mock.players[REP].PlayerData.job.onduty = false
        assert_eq(select(2, NewsJob.RequestVehicle(REP, 'vehicle', 'rumpo')), 'not_on_duty')
        Mock.players[REP].PlayerData.job.onduty = true
        at(REP, vector3(0, 0, 0))
        assert_eq(select(2, NewsJob.RequestVehicle(REP, 'vehicle', 'rumpo')), 'too_far')
        at(REP, Config.Locations.vehicle.coords)
        assert_true(NewsJob.RequestVehicle(REP, 'vehicle', 'rumpo'))
        assert_eq(#grants, 1)
        local spawn = Mock.clientEventsNamed('pfm-newsjob:client:spawnVehicle')[1]
        assert_eq(spawn.args[2], 'rumpo')
        local plate = spawn.args[3]
        assert_true(plate:match('^WZNW%d%d%d%d$') ~= nil, 'the server picks the plate')
        Mock.clock = Mock.clock + 60
        assert_eq(select(2, NewsJob.RequestVehicle(REP, 'vehicle', 'rumpo')), 'vehicle_out')
        assert_eq(fieldStatus().CIDREP.label, 'Rumpo')
        Mock.fireNet('pfm-newsjob:server:vehicleStored', REP)
        assert_eq(fieldStatus().CIDREP, nil)
        assert_true(NewsJob.RequestVehicle(REP, 'vehicle', 'rumpo'))
        onJob(REP, { name = 'unemployed' })
        assert_eq(fieldStatus().CIDREP, nil, 'leaving the job ends the field assignment')
    end)

    it('stocks the trunk once, only for the issued plate the reporter sits in with keys', function()
        at(REP, Config.Locations.vehicle.coords)
        assert_true(NewsJob.RequestVehicle(REP, 'vehicle', 'rumpo'))
        local plate = Mock.clientEventsNamed('pfm-newsjob:client:spawnVehicle')[1].args[3]
        assert_eq(select(2, NewsJob.StockTrunk(REP, 'OTHER123')), 'not_issued')
        assert_eq(select(2, NewsJob.StockTrunk(REP, plate)), 'not_in_vehicle')
        Mock.vehicleOf[REP] = 900
        Mock.plates[900] = plate .. ' '
        assert_eq(select(2, NewsJob.StockTrunk(REP, plate)), 'no_keys')
        keys[REP .. ':' .. plate] = true
        assert_true(NewsJob.StockTrunk(REP, plate))
        assert_true(inventories['trunk-' .. plate])
        assert_eq(#items, 3)
        assert_eq(select(2, NewsJob.StockTrunk(REP, plate)), 'already_stocked')
        assert_eq(#items, 3)
    end)
end)

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
