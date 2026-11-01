-- A police impound is never lost to the tow job:
--   pfm-policejob treats the order as placed only when pf-services answers with a tow.impound
--   request (an open garage or mechanic tow of the car is not an impound order);
--   a tow.impound that closes without a delivery (expired, cancelled, released and never taken)
--   writes the impound directly (pf-jobs tow_requests onClosed -> pfm-policejob FinalizeImpound);
--   each order is applied once, also when an officer impounds on the spot while it is open.
load_resource('tests/lua/fivem_mocks.lua')
QBCore = QBCoreMock
QBCoreMock.Commands.Add = function() end
Lang = { t = function(_, key) return key end }

local started = { ['pf-services'] = true, ['pfm-policejob'] = true }
function GetResourceState(name) return started[name] and 'started' or 'missing' end

local locked, deleted = {}, {}
function GetAllVehicles() local out = {} for v in pairs(Mock.plates) do out[#out + 1] = v end return out end
function SetVehicleDoorsLocked(v, s) locked[v] = s end
function DeleteEntity(e) deleted[#deleted + 1] = e; Mock.plates[e] = nil end
function DoesEntityExist(e) return Mock.plates[e] ~= nil end

-- pf-services stand-in
local requests, handlers, nextAnswer, openOrder, cancels = {}, {}, nil, nil, {}
Mock.exportsByResource['pf-services'] = {
    CreateRequest = function(_, opts)
        requests[#requests + 1] = opts
        if nextAnswer then return nextAnswer end
        return { ok = true, id = 40 + #requests, request = { id = 40 + #requests, kind = opts.kind, plate = opts.plate, meta = opts.meta } }
    end,
    RegisterRequestHandler = function(_, kind, h) handlers[kind] = h return true end,
    Emit = function() return 1 end,
    FindOpenByRef = function(_, t, id, kind) if openOrder and t == 'vehicle' and (kind == nil or kind == openOrder.kind) then return openOrder end return nil end,
    CancelRequest = function(_, src, id, reason)
        cancels[#cancels + 1] = { src = src, id = id, reason = reason }
        -- pf-services runs the kind's onClosed when it closes the order
        if openOrder and openOrder.id == id and handlers['tow.impound'] then handlers['tow.impound'].onClosed(openOrder, reason) end
        openOrder = nil
        return { ok = true }
    end,
}

Config = nil
load_resource('pfm-policejob/config.lua')
load_resource('pfm-policejob/server/main.lua')
load_resource('pfm-policejob/server/vehicle.lua')
local police = Mock.exportsByResource['__self']
Mock.exportsByResource['pfm-policejob'] = {
    GetImpoundLots = function() return police.GetImpoundLots() end,
    FinalizeImpound = function(_, plate, opts, id) return police.FinalizeImpound(plate, opts, id) end,
}

function GetCurrentResourceName() return 'pf-jobs' end
load_resource('[pfscripts]/pf-jobs/server/apps/tow_requests.lua')
Mock.fireEvent('onResourceStart', nil, 'pf-jobs')

local COP, TOW, CAR = 1, 2, 500
local STREET = vector3(100.0, 100.0, 30.0)

local function sql(fragment)
    local out = {}
    for _, c in ipairs(Mock.dbCalls) do if c.query:find(fragment, 1, true) then out[#out + 1] = c end end
    return out
end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords, Mock.plates = {}, {}, {}
    requests, deleted, locked, cancels, nextAnswer, openOrder = {}, {}, {}, {}, nil, nil
    local cop = Mock.newPlayer(COP, 'COPCID')
    cop.PlayerData.job = { name = 'police', type = 'leo', onduty = true, grade = { level = 2 } }
    cop.PlayerData.source = COP
    Mock.coords[COP] = STREET
    Mock.plates[CAR] = 'ABC123  '
    Mock.coords[CAR] = STREET
    MySQL.scalar.await = function() return 'ABC123' end
end

local function towDriver(onduty)
    local t = Mock.newPlayer(TOW, 'TOWCID')
    t.PlayerData.job = { name = 'tow', onduty = onduty, grade = { level = 0 } }
    t.PlayerData.source = TOW
end

describe('the impound order', function()
    it('an answer that is not a tow.impound request (an open garage tow) does not count as ordered', function()
        towDriver(true)
        nextAnswer = { ok = true, existing = true, id = 9, request = { id = 9, kind = 'tow.recovery' } }
        Mock.fireNet('police:server:Impound', COP, 'ABC123', false, 500, 900, 800, 50)
        assert_eq(#requests, 1)
        assert_eq(Mock.clientEventsNamed('police:client:ImpoundDecision')[1].args[2], 'instant', 'impounded on the spot instead')
        assert_eq(#sql('depotprice'), 1)
        assert_eq(deleted[1], CAR)
    end)

    it('a tow.impound answer is a tow order: nothing written yet', function()
        towDriver(true)
        Mock.fireNet('police:server:Impound', COP, 'ABC123', false, 500, 900, 800, 50)
        assert_eq(Mock.clientEventsNamed('police:client:ImpoundDecision')[1].args[2], 'tow')
        assert_eq(#sql('UPDATE player_vehicles'), 0)
    end)
end)

describe('a tow order that ends without a delivery', function()
    it('registers onClosed, which writes the impound once', function()
        local h = handlers['tow.impound']
        assert_true(Mock.callable(h.onClosed), 'tow.impound handles closing untowed')
        local req = { id = 71, status = 'expired', plate = 'ABC123', meta = { fullImpound = false, price = 750, body = 900, engine = 800, fuel = 50 } }
        h.onClosed(req, 'expired')
        assert_eq(#sql('depotprice'), 1, 'impound written')
        assert_eq(sql('depotprice')[1].params[2], 750)
        assert_eq(deleted[1], CAR)
        -- the same order cannot apply twice (onClosed again, or a late onCompleted)
        Mock.plates[CAR] = 'ABC123'
        h.onClosed(req, 'expired')
        h.onCompleted(req)
        assert_eq(#sql('depotprice'), 1)
        assert_eq(#deleted, 1)
    end)

    it('a seized car closed by cancel is seized', function()
        handlers['tow.impound'].onClosed({ id = 72, status = 'cancelled', plate = 'ABC123', meta = { fullImpound = true } }, 'cancelled_by_job')
        assert_eq(#sql('UPDATE player_vehicles SET state = ?, body'), 1)
    end)

    it('an officer impounding on the spot closes the open order without applying it twice', function()
        towDriver(false)
        openOrder = { id = 73, kind = 'tow.impound', plate = 'ABC123', meta = { fullImpound = false, price = 300 } }
        Mock.fireNet('police:server:Impound', COP, 'ABC123', false, 500, 900, 800, 50)
        assert_eq(#cancels, 1)
        assert_eq(cancels[1].id, 73)
        assert_eq(cancels[1].src, nil)
        assert_eq(#sql('depotprice'), 1, 'one impound, the officer\'s')
        assert_eq(sql('depotprice')[1].params[2], 500)
    end)

    it('the delivered order (onCompleted) applies once', function()
        local req = { id = 74, plate = 'ABC123', meta = { fullImpound = false, price = 100 } }
        handlers['tow.impound'].onCompleted(req)
        Mock.plates[CAR] = 'ABC123'
        handlers['tow.impound'].onClosed(req, 'expired')
        assert_eq(#sql('depotprice'), 1)
    end)
end)
