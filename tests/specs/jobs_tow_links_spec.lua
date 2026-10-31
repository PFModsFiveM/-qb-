-- Police impound → tow job → impound lot, and mechanic → tow job → mechanic shop.
-- pfm-policejob orders a tow (pf-services 'tow.impound') when a tow driver is on duty, otherwise it
-- impounds at once; the tow job's checks (pf-jobs/server/apps/tow_requests.lua) complete a request
-- only when the car is really at the destination with the driver next to it; the mechanic's tow
-- request is built on the server from the car next to the mechanic.
load_resource('tests/lua/fivem_mocks.lua')
QBCore = QBCoreMock
QBCoreMock.Commands.Add = function() end
Lang = { t = function(_, key) return key end }

local started = { ['pf-services'] = true, ['pfm-policejob'] = true }
function GetResourceState(name) return started[name] and 'started' or 'missing' end

-- world: vehicles with plates and positions
local vehicles, locked = {}, {}
function GetAllVehicles() local out = {} for v in pairs(Mock.plates) do out[#out + 1] = v end return out end
function SetVehicleDoorsLocked(v, s) locked[v] = s end
local deleted = {}
function DeleteEntity(e) deleted[#deleted + 1] = e; Mock.plates[e] = nil end
function DoesEntityExist(e) return Mock.plates[e] ~= nil end

-- pf-services stand-in: records requests and hands back handlers
local requests, handlers, emits = {}, {}, {}
Mock.exportsByResource['pf-services'] = {
    CreateRequest = function(_, opts) requests[#requests + 1] = opts return { ok = true, id = #requests } end,
    RegisterRequestHandler = function(_, kind, h) handlers[kind] = h return true end,
    Emit = function(_, kind, data, opts) emits[#emits + 1] = { kind = kind, data = data, opts = opts } return 1 end,
}

-- pfm-policejob
Config = nil
load_resource('pfm-policejob/config.lua')
load_resource('pfm-policejob/server/main.lua')
load_resource('pfm-policejob/server/vehicle.lua')
local police = Mock.exportsByResource['__self']
Mock.exportsByResource['pfm-policejob'] = {
    GetImpoundLots = function() return police.GetImpoundLots() end,
    FinalizeImpound = function(_, plate, opts) return police.FinalizeImpound(plate, opts) end,
}

-- pf-jobs tow checks
function GetCurrentResourceName() return 'pf-jobs' end
load_resource('[pfscripts]/pf-jobs/server/apps/tow_requests.lua')
Mock.fireEvent('onResourceStart', nil, 'pf-jobs')

local COP, TOW, CAR = 1, 2, 500
local LOT = Config.Locations['impound'][1]
local STREET = vector3(100.0, 100.0, 30.0)

local function sql(fragment)
    local out = {}
    for _, c in ipairs(Mock.dbCalls) do if c.query:find(fragment, 1, true) then out[#out + 1] = c end end
    return out
end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords, Mock.plates = {}, {}, {}
    requests, emits, deleted, locked = {}, {}, {}, {}
    local cop = Mock.newPlayer(COP, 'COPCID')
    cop.PlayerData.job = { name = 'police', type = 'leo', onduty = true, grade = { level = 2 } }
    cop.PlayerData.source = COP
    Mock.coords[COP] = STREET
    Mock.plates[CAR] = 'ABC123  '
    Mock.coords[CAR] = STREET
    -- the car is owned (IsVehicleOwned returns the plate)
    MySQL.scalar.await = function() return 'ABC123' end
end

local function addTowDriver(onduty)
    local t = Mock.newPlayer(TOW, 'TOWCID')
    t.PlayerData.job = { name = 'tow', onduty = onduty, grade = { level = 0 } }
    t.PlayerData.source = TOW
    return t
end

describe('police impound with the tow job', function()
    it('no tow driver on duty: impounded on the spot, as before (server removes the car)', function()
        addTowDriver(false)
        Mock.fireNet('police:server:Impound', COP, 'ABC123', true, 0, 900, 800, 50)
        assert_eq(#requests, 0)
        assert_eq(#sql('UPDATE player_vehicles SET state = ?, body'), 1, 'seized')
        assert_eq(deleted[1], CAR)
        assert_eq(Mock.clientEventsNamed('police:client:ImpoundDecision')[1].args[2], 'instant')
        assert_eq(emits[1].kind, 'police.impound')
    end)

    it('a tow driver on duty: a tow order instead; the car stays, locked, and the record waits', function()
        addTowDriver(true)
        Mock.fireNet('police:server:Impound', COP, 'ABC123', false, 750, 900, 800, 50)
        assert_eq(#requests, 1)
        local r = requests[1]
        assert_eq(r.kind, 'tow.impound')
        assert_eq(r.plate, 'ABC123')
        assert_eq(r.ref.id, 'ABC123')
        assert_eq(r.from.id, 'police')
        assert_eq(r.meta.price, 750)
        assert_false(r.meta.fullImpound)
        assert_near(r.coords.x, STREET.x, 0.01, 'the car position from the server')
        assert_eq(#deleted, 0)
        assert_eq(locked[CAR], 2)
        assert_eq(#sql('UPDATE player_vehicles'), 0, 'nothing written until the car is at the lot')
        assert_eq(Mock.clientEventsNamed('police:client:ImpoundDecision')[1].args[2], 'tow')
    end)

    it('the tow request completes only at an impound lot with the driver next to the car', function()
        addTowDriver(true)
        local h = handlers['tow.impound']
        assert_true(h ~= nil, 'the tow job registered its check')
        local req = { plate = 'ABC123', meta = { fullImpound = false, price = 750, body = 900, engine = 800, fuel = 50 } }
        Mock.coords[TOW] = STREET
        local ok, why = h.canComplete(req, TOW)
        assert_false(ok)
        assert_eq(why, 'not_at_destination')
        Mock.coords[CAR] = LOT
        Mock.coords[TOW] = vector3(LOT.x + 100, LOT.y, LOT.z)
        ok, why = h.canComplete(req, TOW)
        assert_false(ok)
        assert_eq(why, 'too_far')
        Mock.coords[TOW] = vector3(LOT.x + 5, LOT.y, LOT.z)
        assert_true((h.canComplete(req, TOW)))
        -- completion writes the impound and removes the car
        h.onCompleted(req)
        assert_eq(#sql('depotprice'), 1)
        assert_eq(sql('depotprice')[1].params[2], 750)
        assert_eq(deleted[1], CAR)
        -- a car that is gone cannot be completed
        assert_eq(select(2, h.canComplete(req, TOW)), 'vehicle_not_found')
    end)

    it('FinalizeImpound refuses bad plates', function()
        assert_false(police.FinalizeImpound(12, {}))
        assert_false(police.FinalizeImpound(string.rep('A', 20), {}))
    end)
end)

describe('vehicle recovery to a mechanic shop', function()
    it('completes only at a mechanic shop', function()
        addTowDriver(true)
        local h = handlers['tow.recovery']
        local shop = exports['pf-jobs'] and nil
        local req = { plate = 'ABC123', meta = {} }
        Mock.coords[TOW] = STREET
        assert_eq(select(2, h.canComplete(req, TOW)), 'not_at_destination')
        local burton = vector3(-337.39, -136.92, 39.01)
        Mock.coords[CAR] = burton
        Mock.coords[TOW] = vector3(burton.x + 3, burton.y, burton.z)
        assert_true((h.canComplete(req, TOW)))
        assert_eq(select(2, h.canComplete({ meta = {} }, TOW)), 'no_plate')
    end)
end)
