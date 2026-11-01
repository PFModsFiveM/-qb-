-- pf-jobs device apps, second round (server/devices.lua): the Tow app registers for the tow job only
-- and its handlers reach the tow code as the player; the Bus app takes and returns depot buses;
-- Gruppe 6 and Garbage leaders set crew shares; Gruppe 6 upgrades are bought from the app. Every
-- payload is checked before any job code runs.
load_resource('tests/lua/ledger_env.lua')
QBCore = QBCoreMock
QBCoreMock.Shared.Items.moneybag = { name = 'moneybag', label = 'Money Bag', weight = 0 }
Citizen.SetTimeout = function() return 1 end
Citizen.ClearTimeout = function() end
SetTimeout = function() end

local alive = {}
function CreateVehicleServerSetter(hash, _, x, y, z)
    Mock.nextNetId = Mock.nextNetId + 1
    alive[Mock.nextNetId], Mock.models[Mock.nextNetId], Mock.coords[Mock.nextNetId] = true, hash, vector3(x, y, z)
    return Mock.nextNetId
end
function CreateVehicle(hash, x, y, z) return CreateVehicleServerSetter(hash, nil, x, y, z) end
function DoesEntityExist(e) return alive[e] == true or Mock.players[e] ~= nil end
function DeleteEntity(e) alive[e] = nil end
function SetVehicleNumberPlateText(veh, plate) Mock.plates[veh] = plate end
function SetVehicleDoorsLocked() end
function SetEntityHeading() end
function GetVehicleEngineHealth() return 1000.0 end
function GetVehicleBodyHealth() return 1000.0 end
Mock.exportsByResource['pfm-inventory'] = {
    GetInventory = function() return nil end, CreateInventory = function() end, SetInventory = function() end,
    OpenInventory = function() end, RemoveInventory = function() end,
}
local function started(name) return name ~= 'pf-services' and 'started' or 'missing' end
GetResourceState = started

local installs = {}
FakeDB.extraPatterns = {
    { 'SELECT app_id FROM pf_device_apps', function(p)
        local out = {}
        for _, r in ipairs(installs) do if r[1] == p[1] then out[#out + 1] = { app_id = r[2] } end end
        return out
    end },
    { 'INSERT IGNORE INTO pf_device_apps', function(p) installs[#installs + 1] = { p[1], p[2] }; return 1 end },
}
Mock.exportsByResource['pf-devices'] = {
    RegisterApp = function(_, def) return PFDevices.RegisterApp(def, 'pf-jobs') end,
    RegisterAppHandlers = function(_, id, map) return PFDevices.RegisterAppHandlers(id, map, 'pf-jobs') end,
}

local mockRegisterNetEvent = RegisterNetEvent
local function loadAll()
    RegisterNetEvent = mockRegisterNetEvent
    PFJobsCapture, PFJobsCallback, PFJobsDevices, PFJobsTow, PFJobsBus, PFJobsG6, PFJobsGarbage = nil, nil, nil, nil, nil, nil, nil
    Mock.netHandlers, Mock.netHandlerList, Mock.callbacks, Mock.eventHandlers = {}, {}, {}, {}
    LedgerEnv.load('pf-jobs', {
        '[pfscripts]/pf-jobs/config.lua',
        '[pfscripts]/pf-jobs/server/devices_capture.lua',
        '[pfscripts]/pf-jobs/server/apps/bus.lua',
        '[pfscripts]/pf-jobs/server/apps/garbage.lua',
        '[pfscripts]/pf-jobs/server/apps/gruppe6.lua',
        '[pfscripts]/pf-jobs/server/apps/taxi.lua',
        '[pfscripts]/pf-jobs/server/apps/tow.lua',
        '[pfscripts]/pf-jobs/server/devices.lua',
    })
    RegisterNetEvent = mockRegisterNetEvent
    GetResourceState = started
    Config.Taxi.UseDatabase, Config.Garbage.UseDatabase, Config.Gruppe6.UseDatabase = false, false, false
    Config.Bus.UseDatabase, Config.Tow.UseDatabase = false, false
    load_resource('[pfscripts]/pf-devices/shared/config.lua')
    Config.Rpc.burst, Config.Rpc.perSecond = 1000, 1000
    load_resource('[pfscripts]/pf-devices/server/registry.lua')
    load_resource('[pfscripts]/pf-devices/server/installs.lua')
    load_resource('[pfscripts]/pf-devices/server/rpc.lua')
    load_resource('[pfscripts]/pf-devices/server/push.lua')
    PFDevices.__resetInstalls()
    assert_true(PFJobsDevices.Register(), 'apps registered')
end

local TOW, CITIZEN, LEAD, MEMBER = 1, 2, 3, 4
local function rpc(src, app, method, payload) return PFDevices.HandleRpc(src, app, method, payload) end
local function install(src, app) assert_eq(PFDevices.InstallApp(src, app).ok, true, 'install ' .. app) end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players, Mock.coords, Mock.models, installs, alive = {}, {}, {}, {}, {}
    Mock.clock = Mock.clock + 10000
    loadAll()
    local t = Mock.newPlayer(TOW)
    t.PlayerData.job = { name = 'tow', grade = { level = 0 }, onduty = true }
    t.PlayerData.money = { cash = 1000, bank = 0 }
    Mock.newPlayer(CITIZEN)
    Mock.newPlayer(LEAD).PlayerData.money = { cash = 0, bank = 50000 }
    Mock.newPlayer(MEMBER)
end

describe('Tow app', function()
    it('is registered on both devices for the tow job only', function()
        local app = PFDevices.GetApp('tow')
        assert_true(app ~= nil)
        -- the tow job, or an open rental for the return only (fix9hq2_jobs_tow_return_spec)
        assert_eq(app.access.handler, true)
        assert_eq(app.access.jobs, nil)
        assert_eq(app.access.installable, nil)
        assert_eq(table.concat(app.devices, ','), 'computer,tablet')
        assert_eq(app.entry, 'html/apps/tow.js')
        assert_eq(rpc(CITIZEN, 'tow', 'getInit').error, 'not_authorized')
        local apps = PFDevices.GetAppsFor(TOW, 'tablet').apps
        local found = false
        for _, a in ipairs(apps) do if a.id == 'tow' then found = true end end
        assert_true(found, 'on the tow driver\'s home screen')
    end)

    it('rents and returns the flatbed as the player, and refuses bad payloads', function()
        local res = rpc(TOW, 'tow', 'getInit')
        assert_eq(res.ok, true)
        assert_eq(res.rental, nil)
        assert_true(#res.levels >= 3)
        assert_eq(res.config.payBase, Config.Tow.Contracts.PayBase)
        assert_eq(rpc(TOW, 'tow', 'rentFlatbed', { model = { 'flatbed' } }).error, 'bad_request')
        assert_eq(rpc(TOW, 'tow', 'acceptRequest', { id = 'x' }).error, 'bad_request')
        assert_eq(rpc(TOW, 'tow', 'completeRequest', { id = -4 }).error, 'bad_request')
        assert_eq(rpc(TOW, 'tow', 'releaseRequest', { id = 1.5 }).error, 'bad_request')
        res = rpc(TOW, 'tow', 'rentFlatbed', { model = 'flatbed' })
        assert_eq(res.error, 'not_at_depot')
        assert_eq(res.message, PFJobsTow.Messages.not_at_depot)
        local bay = Config.Tow.FlatbedSpawn
        Mock.coords[TOW] = vector3(bay.x, bay.y, bay.z)
        res = rpc(TOW, 'tow', 'rentFlatbed', { model = 'flatbed' })
        assert_eq(res.ok, true)
        assert_eq(res.view.rental.model, 'flatbed')
        assert_eq(Mock.players[TOW].PlayerData.money.cash, 750)
        assert_eq(#Mock.clientEventsNamed('QBCore:Notify'), 0, 'the app shows the result, not a second notification')
        res = rpc(TOW, 'tow', 'returnFlatbed')
        assert_eq(res.ok, true)
        assert_eq(res.view.rental, nil)
        assert_eq(Mock.players[TOW].PlayerData.money.bank, 250)
        assert_eq(rpc(TOW, 'tow', 'startContract').error, 'no_truck')
        assert_eq(rpc(TOW, 'tow', 'acceptRequest', { id = 3 }).error, 'services_offline')
    end)
end)

describe('Bus app depot', function()
    it('takes and returns a depot bus', function()
        install(CITIZEN, 'bus')
        assert_eq(rpc(CITIZEN, 'bus', 'takeBus', { model = 'bus bus' }).error, 'bad_request')
        assert_eq(rpc(CITIZEN, 'bus', 'takeBus', { model = 'bus' }).error, 'refused', 'away from the depot')
        local d = Config.Bus.Depot.coords
        Mock.coords[CITIZEN] = vector3(d.x, d.y, d.z)
        local res = rpc(CITIZEN, 'bus', 'getInit')
        assert_eq(res.atDepot, true)
        assert_eq(#res.routes > 0, true)
        assert_true(res.routes[1].estimatedPay > 0)
        res = rpc(CITIZEN, 'bus', 'takeBus', { model = 'bus' })
        assert_eq(res.ok, true)
        assert_eq(res.view.bus.model, 'bus')
        assert_eq(rpc(CITIZEN, 'bus', 'takeBus', { model = 'bus' }).error, 'bus_out')
        res = rpc(CITIZEN, 'bus', 'returnBus')
        assert_eq(res.ok, true)
        assert_eq(rpc(CITIZEN, 'bus', 'returnBus').error, 'no_bus')
    end)
end)

describe('crew shares from the apps', function()
    it('the Gruppe 6 leader sets valid shares; members and bad shares are refused', function()
        install(LEAD, 'gruppe6'); install(MEMBER, 'gruppe6')
        local code = rpc(LEAD, 'gruppe6', 'createGroup').view.group.groupCode
        assert_eq(rpc(MEMBER, 'gruppe6', 'joinByCode', { code = code }).ok, true)
        local view = rpc(LEAD, 'gruppe6', 'refresh')
        assert_eq(#view.group.splits, 2)
        assert_eq(view.group.splits[1].pct + view.group.splits[2].pct, 100)
        assert_eq(rpc(LEAD, 'gruppe6', 'setSplits', { splits = 'all' }).error, 'bad_request')
        assert_eq(rpc(LEAD, 'gruppe6', 'setSplits', { splits = { { id = LEAD, pct = 150 } } }).error, 'bad_request')
        assert_eq(rpc(MEMBER, 'gruppe6', 'setSplits', { splits = { { id = LEAD, pct = 50 }, { id = MEMBER, pct = 50 } } }).error, 'not_leader')
        assert_eq(rpc(LEAD, 'gruppe6', 'setSplits', { splits = { { id = LEAD, pct = 95 }, { id = MEMBER, pct = 5 } } }).error, 'refused', 'below the floor')
        assert_eq(rpc(LEAD, 'gruppe6', 'setSplits', { splits = { { id = LEAD, pct = 60 }, { id = MEMBER, pct = 30 } } }).error, 'refused', 'not 100')
        local res = rpc(LEAD, 'gruppe6', 'setSplits', { splits = { { id = LEAD, pct = 70 }, { id = MEMBER, pct = 30 } } })
        assert_eq(res.ok, true)
        assert_eq(res.view.group.payoutSplits[MEMBER], 30)
    end)

    it('the Garbage leader sets the crew shares', function()
        install(LEAD, 'garbage'); install(MEMBER, 'garbage')
        local code = rpc(LEAD, 'garbage', 'createGroup').state.currentGroup.groupCode
        assert_eq(rpc(MEMBER, 'garbage', 'joinByCode', { code = code }).ok, true)
        local res = rpc(LEAD, 'garbage', 'setSplits', { splits = { { id = LEAD, pct = 40 }, { id = MEMBER, pct = 60 } } })
        assert_eq(res.ok, true)
        assert_eq(res.state.currentGroup.payoutSplits[MEMBER], 60)
        assert_eq(rpc(LEAD, 'garbage', 'setSplits', { splits = { { id = LEAD, pct = 100 } } }).error, 'refused', 'every member needs a share')
        assert_eq(res.state.config, nil)
        assert_eq(rpc(LEAD, 'garbage', 'getInit').config.splitFloor, Config.Garbage.Groups.MinSplitPercent)
    end)
end)

describe('Gruppe 6 upgrades from the app', function()
    it('lists the upgrades and buys one once from the bank', function()
        install(LEAD, 'gruppe6')
        local init = rpc(LEAD, 'gruppe6', 'getInit')
        assert_true(#init.upgrades >= 4)
        assert_eq(init.config.tiers[2].upgrade, 'tier_2')
        assert_eq(rpc(LEAD, 'gruppe6', 'buyUpgrade', { id = 'free_money' }).error, 'bad_request')
        assert_eq(rpc(LEAD, 'gruppe6', 'buyUpgrade', { id = 'tier_2' }).error, 'refused', 'level 2 needed')
        local res = rpc(LEAD, 'gruppe6', 'buyUpgrade', { id = 'priority_dispatch' })
        assert_eq(res.ok, true)
        local owned = false
        for _, u in ipairs(res.view.upgrades) do if u.id == 'priority_dispatch' then owned = u.owned end end
        assert_true(owned)
        assert_eq(Mock.players[LEAD].PlayerData.money.bank, 50000 - Config.Gruppe6.Upgrades.priority_dispatch.cost)
        assert_eq(rpc(LEAD, 'gruppe6', 'buyUpgrade', { id = 'priority_dispatch' }).error, 'refused')
        assert_eq(#LedgerEnv.paid('pf-jobs:gruppe6:upgrade:'), 1)
    end)
end)
