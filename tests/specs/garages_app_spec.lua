-- pfm-garages Garages app (pf-devices): registered on start and when pf-devices is ready; lists only
-- the player's own cars with their real state; pays the impound release fee through the same ledger
-- path as the depot (stable keys, never twice) so the car can then be taken out at the depot; asks
-- pf-services for a tow of a car that is out and parks it once the tow is completed; refuses
-- everything that is not the player's, and bad payloads.
load_resource('tests/lua/ledger_env.lua')
QBCoreMock.Shared.Vehicles = {
    sultan = { name = 'Sultan', brand = 'Karin', price = 1000, category = 'sports' },
    dinghy = { name = 'Dinghy', brand = 'Nagasaki', price = 1000, category = 'boats' },
}
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end

local cars, releases, nextRelease = {}, {}, 0
local fleetPlates = {}
local existing, plates, seat = {}, {}, {}
local function copy(t) local o = {} for k, v in pairs(t) do o[k] = v end return o end

FakeDB.extraPatterns = {
    { "AND TABLE_NAME = 'job_garage_vehicles'", function() return 1 end },
    { 'SELECT plate FROM job_garage_vehicles WHERE active = 1 AND plate IN', function(p)
        local out = {}
        for _, plate in ipairs(p) do if fleetPlates[plate] then out[#out + 1] = { plate = plate } end end
        return out
    end },
    { 'UPDATE player_vehicles SET state = 1 WHERE state = 0', function() return 0 end },
    { 'SELECT * FROM player_vehicles WHERE citizenid = ? AND depotprice > 0', function(p)
        local out = {}
        for plate, c in pairs(cars) do if c.citizenid == p[1] and (c.depotprice or 0) > 0 then local r = copy(c) r.plate = plate out[#out + 1] = r end end
        return out
    end },
    { 'SELECT plate, vehicle, garage, state, depotprice, fuel, engine, body, balance FROM player_vehicles WHERE citizenid = ?', function(p)
        local out = {}
        for plate, c in pairs(cars) do if c.citizenid == p[1] then local r = copy(c) r.plate = plate out[#out + 1] = r end end
        table.sort(out, function(a, b) return a.plate < b.plate end)
        return out
    end },
    { 'SELECT plate, vehicle, garage, state, depotprice FROM player_vehicles WHERE plate = ? AND citizenid = ?', function(p)
        local c = cars[p[1]]
        if not c or c.citizenid ~= p[2] then return nil end   -- oxmysql single: nil for no row
        local r = copy(c) r.plate = p[1]
        return { r }
    end },
    { 'SELECT vehicle, mods, state, depotprice FROM player_vehicles WHERE plate = ? AND citizenid = ?', function(p)
        local c = cars[p[1]]
        return (c and c.citizenid == p[2]) and { c } or nil
    end },
    { 'SELECT depotprice FROM player_vehicles WHERE plate = ? AND citizenid = ?', function(p)
        local c = cars[p[1]]
        return (c and c.citizenid == p[2]) and c.depotprice or nil
    end },
    { 'SELECT state FROM player_vehicles WHERE plate = ? AND citizenid = ?', function(p)
        local c = cars[p[1]]
        return (c and c.citizenid == p[2]) and c.state or nil
    end },
    { 'UPDATE player_vehicles SET depotprice = 0', function(p) if cars[p[1]] then cars[p[1]].depotprice = 0 end return 1 end },
    { 'UPDATE player_vehicles SET state = ? WHERE plate = ? AND citizenid = ?', function(p) if cars[p[2]] and cars[p[2]].citizenid == p[3] then cars[p[2]].state = p[1] end return 1 end },
    { 'UPDATE player_vehicles SET state = 0 WHERE plate = ? AND citizenid = ?', function(p) if cars[p[1]] then cars[p[1]].state = 0 end return 1 end },
    { 'UPDATE player_vehicles SET state = 1, garage = ?', function(p)
        local c = cars[p[4]]
        if not c or c.citizenid ~= p[5] or c.state ~= 0 or c.depotprice ~= 0 then return 0 end
        c.state, c.garage = 1, p[1]
        return 1
    end },
    -- pfm_garage_depot_releases
    { "FROM pfm_garage_depot_releases WHERE plate = ? AND state IN ('open', 'paid') ORDER BY id DESC", function(p)
        local best
        for _, r in pairs(releases) do
            if r.plate == p[1] and (r.state == 'open' or r.state == 'paid') and (not best or r.id > best.id) then best = r end
        end
        return best and { copy(best) } or nil
    end },
    { 'INSERT INTO pfm_garage_depot_releases', function(p)
        nextRelease = nextRelease + 1
        releases[nextRelease] = { id = nextRelease, plate = p[1], citizenid = p[2], fee = p[3], paid = 0, attempt = 1, state = 'open' }
        return nextRelease
    end },
    { "UPDATE pfm_garage_depot_releases SET state = 'void' WHERE id = ?", function(p) releases[p[1]].state = 'void' return 1 end },
    { 'UPDATE pfm_garage_depot_releases SET attempt = ? WHERE id = ?', function(p) releases[p[2]].attempt = p[1] return 1 end },
    { "UPDATE pfm_garage_depot_releases SET paid = paid + ?", function(p)
        local r = releases[p[4]]
        r.paid, r.fee, r.state, r.attempt, r.ledger_key = r.paid + p[1], p[2], 'paid', 1, p[3]
        return 1
    end },
    { "UPDATE pfm_garage_depot_releases SET state = 'used'", function(p)
        for _, r in pairs(releases) do if r.plate == p[1] and (r.state == 'open' or r.state == 'paid') then r.state = 'used' end end
        return 1
    end },
    { "UPDATE pfm_garage_depot_releases SET state = 'void' WHERE plate = ?", function(p)
        for _, r in pairs(releases) do if r.plate == p[1] and (r.state == 'open' or r.state == 'paid') then r.state = 'void' end end
        return 1
    end },
    { "SELECT plate, paid FROM pfm_garage_depot_releases WHERE citizenid = ? AND state = 'paid'", function(p)
        local out = {}
        for _, r in pairs(releases) do if r.citizenid == p[1] and r.state == 'paid' then out[#out + 1] = { plate = r.plate, paid = r.paid } end end
        return out
    end },
    { 'DELETE FROM pfm_garage_depot_releases WHERE citizenid = ?', function(p)
        for id, r in pairs(releases) do if r.citizenid == p[1] then releases[id] = nil end end
        return { affectedRows = 1 }
    end },
}

-- pf-devices and pf-services as seen by this resource
local registered, handlers, pushes = {}, {}, {}
Mock.exportsByResource['pf-devices'] = {
    RegisterApp = function(_, def) registered[#registered + 1] = def return true end,
    RegisterAppHandlers = function(_, id, map) handlers[id] = map return true end,
    Push = function(_, src, app, event) pushes[#pushes + 1] = { src = src, app = app, event = event } return true end,
    PushToCitizen = function(_, cid, app, event) pushes[#pushes + 1] = { cid = cid, app = app, event = event } return true end,
}
local requests, nextReq = {}, 0
Mock.exportsByResource['pf-services'] = {
    GetRequestKind = function(_, kind) return kind == 'tow.recovery' and { reward = 175 } or nil end,
    FindOpenByRef = function(_, t, id)
        for _, r in pairs(requests) do if r.ref.type == t and r.ref.id == id and (r.status == 'open' or r.status == 'accepted') then return r end end
    end,
    CreateRequest = function(_, opts)
        nextReq = nextReq + 1
        local r = { id = nextReq, kind = opts.kind, status = 'open', plate = opts.plate, ref = opts.ref, requester = opts.requester, meta = opts.meta, coords = opts.coords, payer = opts.payer }
        requests[nextReq] = r
        return { ok = true, id = nextReq, request = r }
    end,
    GetRequest = function(_, id) return requests[id] end,
    CancelRequest = function(_, src, id) requests[id].status = 'cancelled' return { ok = true } end,
}

LedgerEnv.load('pfm-garages', { 'pfm-garages/config.lua', 'pfm-garages/server/main.lua', 'pfm-garages/server/apps.lua' })

local nextEntity = 900
function CreateVehicleServerSetter() nextEntity = nextEntity + 1; existing[nextEntity] = true; return nextEntity end
function SetVehicleNumberPlateText(veh, plate) plates[veh] = plate end
function GetVehicleNumberPlateText(veh) return plates[veh] end
function DoesEntityExist(e) return existing[e] == true end
function GetAllVehicles() local out = {} for e in pairs(existing) do out[#out + 1] = e end table.sort(out) return out end
function GetPedInVehicleSeat(veh) return seat[veh] or 0 end
function GetVehicleEngineHealth() return 640.0 end
function GetVehicleBodyHealth() return 820.0 end
function DeleteEntity(e) existing[e] = nil end

local P, OTHER = 1, 2
local HERE = vector3(10, 10, 10)
local DEPOT = Config.Garages.depotLot.spawnPoint[1]
local MOTEL = Config.Garages.motelgarage.takeVehicle
local function bank(src) return Mock.players[src].PlayerData.money.bank end
local function spawn(src, plate, at) return Mock.callCallback('qb-garages:server:spawnvehicle', src, plate, 'sultan', at or DEPOT) end
local function app(method, src, payload) return handlers.garages[method](src, payload or {}) end
local function find(list, plate) for _, v in ipairs(list.vehicles) do if v.plate == plate then return v end end end
local function inWorld(plate, pos)
    nextEntity = nextEntity + 1
    existing[nextEntity], plates[nextEntity] = true, plate
    Mock.coords[nextEntity] = pos or vector3(1000, 1000, 30)
    return nextEntity
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.clock = Mock.clock + 1000
    Mock.players, Mock.coords = {}, {}
    registered = {}
    existing, plates, seat = {}, {}, {}
    fleetPlates, releases, requests, pushes = {}, {}, {}, {}
    nextRelease = 0
    for _, src in ipairs({ P, OTHER }) do
        Mock.newPlayer(src).PlayerData.money = { cash = 0, bank = 5000 }
        Mock.players[src].PlayerData.license = 'license:' .. src
        Mock.coords[src] = HERE
    end
    cars = {
        PARKED1 = { citizenid = 'CID1', vehicle = 'sultan', mods = '{}', state = 1, depotprice = 0, garage = 'motelgarage', fuel = 80, engine = 900, body = 500, balance = 0 },
        OUT1 = { citizenid = 'CID1', vehicle = 'sultan', mods = '{}', state = 0, depotprice = 0, garage = 'motelgarage', fuel = 50, engine = 1000, body = 1000, balance = 2500 },
        IMPOUND1 = { citizenid = 'CID1', vehicle = 'sultan', mods = '{}', state = 0, depotprice = 500, garage = 'motelgarage', fuel = 10, engine = 300, body = 200, balance = 0 },
        SEIZED1 = { citizenid = 'CID1', vehicle = 'sultan', mods = '{}', state = 2, depotprice = 300, garage = 'gov_lockup', fuel = 10, engine = 300, body = 200, balance = 0 },
        THEIRS1 = { citizenid = 'CID2', vehicle = 'sultan', mods = '{}', state = 0, depotprice = 700, garage = 'motelgarage', fuel = 10, engine = 300, body = 200, balance = 0 },
    }
end

describe('registration', function()
    it('registers the app for everyone on both devices, on start and when pf-devices is ready', function()
        PFGarages.Start()
        assert_true(PFGarages.dbReady, 'migrations ran')
        assert_eq(#registered, 1)
        local def = registered[1]
        assert_eq(def.id, 'garages')
        assert_true(def.access.anyone)
        assert_eq(def.devices[1], 'tablet')
        assert_eq(def.devices[2], 'computer')
        assert_eq(def.entry, 'html/apps/garages.js')
        for _, m in ipairs({ 'list', 'locate', 'payDepot', 'requestTow', 'cancelTow' }) do assert_true(handlers.garages[m] ~= nil, m) end
        Mock.eventHandlers['pf-devices:server:ready']()
        assert_eq(#registered, 2)
    end)
end)

describe('the vehicle list', function()
    it('shows only my cars, each with its real state, place and condition', function()
        PFGarages.Start()
        fleetPlates.OUT1 = nil
        local list = app('list', P)
        assert_true(list.ok)
        assert_eq(#list.vehicles, 4)
        assert_eq(find(list, 'THEIRS1'), nil)
        local parked = find(list, 'PARKED1')
        assert_eq(parked.status, 'garaged')
        assert_eq(parked.location.label, 'Motel Parking')
        assert_eq(parked.location.coords.x, MOTEL.x)
        assert_eq(parked.fuel, 80)
        assert_eq(parked.engine, 90)
        assert_eq(parked.body, 50)
        assert_eq(parked.label, 'Karin Sultan')
        local imp = find(list, 'IMPOUND1')
        assert_eq(imp.status, 'impounded')
        assert_eq(imp.fee, 500)
        assert_true(imp.canPay)
        assert_eq(imp.location.label, 'Depot Lot')
        assert_eq(find(list, 'SEIZED1').status, 'seized')
        assert_eq(find(list, 'SEIZED1').canPay, nil)
        local out = find(list, 'OUT1')
        assert_eq(out.status, 'out')
        assert_eq(out.finance, 2500)
        assert_false(out.inWorld)
        assert_false(out.canTow)
        assert_eq(list.feesDue, 500)
        assert_eq(list.towFee, 175)
    end)
    it('a job fleet car is shown as such, without actions', function()
        PFGarages.Start()
        fleetPlates.IMPOUND1 = true
        local imp = find(app('list', P), 'IMPOUND1')
        assert_eq(imp.status, 'fleet')
        assert_eq(imp.canPay, nil)
        assert_eq(app('payDepot', P, { plate = 'IMPOUND1' }).error, 'fleet')
        assert_eq(bank(P), 5000)
    end)
end)

describe('paying the impound release fee from the app', function()
    it('charges once through the ledger; the car is then taken out at the depot without paying again', function()
        PFGarages.Start()
        local res = app('payDepot', P, { plate = 'IMPOUND1' })
        assert_true(res.ok, tostring(res.error))
        assert_eq(res.paid, 500)
        assert_eq(res.depot.label, 'Depot Lot')
        assert_eq(bank(P), 4500)
        -- paying again, from the app or at the depot, costs nothing
        assert_true(app('payDepot', P, { plate = 'IMPOUND1' }).already)
        Mock.fireNet('qb-garages:server:PayDepotPrice', P, { plate = 'IMPOUND1' })
        assert_eq(bank(P), 4500)
        assert_eq(#LedgerEnv.paid('pfm-garages:depot:'), 1)
        assert_true(find(app('list', P), 'IMPOUND1').feePaid)
        -- the depot list shows it as paid, and the spawn lets it out once, next to the player
        Mock.coords[P] = vector3(DEPOT.x, DEPOT.y, DEPOT.z)
        local depotList = Mock.callCallback('qb-garages:server:GetGarageVehicles', P, 'depotLot', 'depot', {})
        for _, v in ipairs(depotList) do if v.plate == 'IMPOUND1' then assert_eq(v.depotprice, 0) end end
        assert_true(spawn(P, 'IMPOUND1') ~= nil)
        assert_eq(cars.IMPOUND1.depotprice, 0)
        assert_eq(releases[1].state, 'used')
    end)
    it('a release paid ahead survives a restart (it is stored, not only remembered)', function()
        PFGarages.Start()
        assert_true(app('payDepot', P, { plate = 'IMPOUND1' }).ok)
        -- a fresh copy of the resource has nothing in memory
        LedgerEnv.load('pfm-garages', { 'pfm-garages/config.lua', 'pfm-garages/server/main.lua', 'pfm-garages/server/apps.lua' })
        PFGarages.Start()
        Mock.coords[P] = vector3(DEPOT.x, DEPOT.y, DEPOT.z)
        assert_true(spawn(P, 'IMPOUND1') ~= nil)
        assert_eq(bank(P), 4500)
    end)
    it('not enough money: nothing moves, and a later attempt with money pays under a new key', function()
        PFGarages.Start()
        Mock.players[P].PlayerData.money = { cash = 100, bank = 100 }
        assert_eq(app('payDepot', P, { plate = 'IMPOUND1' }).error, 'insufficient_funds')
        assert_eq(bank(P), 100)
        assert_eq(spawn(P, 'IMPOUND1'), nil)
        Mock.players[P].PlayerData.money.bank = 900
        local res = app('payDepot', P, { plate = 'IMPOUND1' })
        assert_true(res.ok, tostring(res.error))
        assert_eq(bank(P), 400)
        assert_eq(#LedgerEnv.paid('pfm-garages:depot:'), 1)
    end)
    it('the same release key, retried after a crash before it was recorded, does not charge again', function()
        PFGarages.Start()
        assert_true(app('payDepot', P, { plate = 'IMPOUND1' }).ok)
        -- as if the server stopped right after the ledger moved the money
        releases[1].paid, releases[1].state, releases[1].attempt = 0, 'open', 1
        assert_true(app('payDepot', P, { plate = 'IMPOUND1' }).ok)
        assert_eq(bank(P), 4500)
        assert_eq(releases[1].state, 'paid')
    end)
    it('refuses cars that are not mine, seized cars, cars without a fee and bad payloads', function()
        PFGarages.Start()
        assert_eq(app('payDepot', P, { plate = 'THEIRS1' }).error, 'not_owned')
        assert_eq(app('payDepot', P, { plate = 'SEIZED1' }).error, 'seized')
        assert_eq(app('payDepot', P, { plate = 'PARKED1' }).error, 'nothing_due')
        assert_eq(app('payDepot', P, { plate = 12 }).error, 'bad_plate')
        assert_eq(app('payDepot', P, { plate = string.rep('A', 40) }).error, 'bad_plate')
        assert_eq(app('payDepot', P, {}).error, 'bad_plate')
        assert_eq(bank(P), 5000)
        assert_eq(bank(OTHER), 5000)
        -- a seized car with an old fee never leaves through the depot
        Mock.coords[P] = vector3(DEPOT.x, DEPOT.y, DEPOT.z)
        assert_eq(spawn(P, 'SEIZED1'), nil)
    end)
end)

describe('locating a car that is out', function()
    it('only my own car, only while it is in the city', function()
        PFGarages.Start()
        assert_eq(app('locate', P, { plate = 'OUT1' }).error, 'not_found')
        inWorld('OUT1', vector3(321, 654, 30))
        local res = app('locate', P, { plate = 'OUT1' })
        assert_eq(res.coords.x, 321)
        inWorld('THEIRS1')
        assert_eq(app('locate', P, { plate = 'THEIRS1' }).error, 'not_owned')
        assert_eq(app('locate', P, { plate = { 'x' } }).error, 'bad_plate')
    end)
end)

describe('a tow to a garage', function()
    it('creates a tow.recovery request paid by the citizen, with the garage as destination', function()
        PFGarages.Start()
        inWorld('OUT1', vector3(1000, 1000, 30))
        assert_true(find(app('list', P), 'OUT1').canTow)
        local res = app('requestTow', P, { plate = 'OUT1', garage = 'motelgarage' })
        assert_true(res.ok, tostring(res.error))
        local req = requests[res.id]
        assert_eq(req.kind, 'tow.recovery')
        assert_eq(req.requester, 'CID1')
        assert_eq(req.ref.type, 'vehicle')
        assert_eq(req.ref.id, 'OUT1')
        assert_eq(req.meta.garage, 'motelgarage')
        assert_eq(req.meta.destination.x, MOTEL.x)
        assert_eq(req.coords.x, 1000)             -- where the car is (server side), not the player
        assert_eq(req.payer, nil)                 -- the kind's default payer: the requester
        local listed = find(app('list', P), 'OUT1')
        assert_true(listed.tow ~= nil and listed.tow.mine)
        assert_false(listed.canTow)
        assert_eq(app('requestTow', P, { plate = 'OUT1', garage = 'motelgarage' }).error, 'tow_exists')
    end)
    it('once the tow driver completed it, the car is parked in that garage', function()
        PFGarages.Start()
        local veh = inWorld('OUT1', vector3(1000, 1000, 30))
        local res = app('requestTow', P, { plate = 'OUT1', garage = 'motelgarage' })
        -- not delivered yet: nothing happens
        requests[res.id].status = 'completed'
        Mock.eventHandlers['pf-services:requestChanged'](requests[res.id], 'completed')
        assert_eq(cars.OUT1.state, 0)
        -- delivered at the garage
        Mock.coords[veh] = vector3(MOTEL.x + 5, MOTEL.y, MOTEL.z)
        Mock.eventHandlers['pf-services:requestChanged'](requests[res.id], 'completed')
        assert_eq(cars.OUT1.state, 1)
        assert_eq(cars.OUT1.garage, 'motelgarage')
        assert_eq(existing[veh], nil)
        -- a forged event for a request that is not completed parks nothing
        cars.OUT1.state = 0
        local veh2 = inWorld('OUT1', vector3(MOTEL.x, MOTEL.y, MOTEL.z))
        requests[res.id].status = 'accepted'
        Mock.eventHandlers['pf-services:requestChanged']({ id = res.id, kind = 'tow.recovery', meta = { purpose = 'garage' } }, 'completed')
        assert_eq(cars.OUT1.state, 0)
        assert_true(existing[veh2])
    end)
    it('refuses cars that are not out, not mine, driven, already there, unknown garages and bad payloads', function()
        PFGarages.Start()
        assert_eq(app('requestTow', P, { plate = 'PARKED1', garage = 'motelgarage' }).error, 'not_out')
        assert_eq(app('requestTow', P, { plate = 'IMPOUND1', garage = 'motelgarage' }).error, 'not_out')
        assert_eq(app('requestTow', P, { plate = 'THEIRS1', garage = 'motelgarage' }).error, 'not_owned')
        assert_eq(app('requestTow', P, { plate = 'OUT1', garage = 'motelgarage' }).error, 'not_found')
        local veh = inWorld('OUT1', vector3(1000, 1000, 30))
        assert_eq(app('requestTow', P, { plate = 'OUT1', garage = 'police' }).error, 'bad_garage')
        assert_eq(app('requestTow', P, { plate = 'OUT1', garage = 'depotLot' }).error, 'bad_garage')
        assert_eq(app('requestTow', P, { plate = 'OUT1', garage = 'nowhere' }).error, 'bad_garage')
        assert_eq(app('requestTow', P, { plate = 'OUT1' }).error, 'bad_request')
        assert_eq(app('requestTow', P, { plate = 5, garage = 'motelgarage' }).error, 'bad_request')
        seat[veh] = 77
        assert_eq(app('requestTow', P, { plate = 'OUT1', garage = 'motelgarage' }).error, 'occupied')
        seat[veh] = nil
        Mock.coords[veh] = vector3(MOTEL.x, MOTEL.y, MOTEL.z)
        assert_eq(app('requestTow', P, { plate = 'OUT1', garage = 'motelgarage' }).error, 'already_there')
        local n = 0 for _ in pairs(requests) do n = n + 1 end
        assert_eq(n, 0)
    end)
    it('only the citizen who asked can cancel it', function()
        PFGarages.Start()
        inWorld('OUT1', vector3(1000, 1000, 30))
        local res = app('requestTow', P, { plate = 'OUT1', garage = 'motelgarage' })
        cars.OUT1.citizenid = 'CID1'
        assert_eq(app('cancelTow', OTHER, { plate = 'OUT1' }).error, 'not_found')
        assert_true(app('cancelTow', P, { plate = 'OUT1' }).ok)
        assert_eq(requests[res.id].status, 'cancelled')
    end)
end)

describe('a deleted character', function()
    it('loses their paid releases; a bad id changes nothing', function()
        PFGarages.Start()
        assert_true(app('payDepot', P, { plate = 'IMPOUND1' }).ok)
        Mock.eventHandlers['pfm-core:server:characterDeleted']('')
        Mock.eventHandlers['pfm-core:server:characterDeleted']({})
        assert_true(releases[1] ~= nil)
        Mock.eventHandlers['pfm-core:server:characterDeleted']('CID1')
        assert_eq(releases[1], nil)
        assert_false(PFGarages.ReleasePaid('IMPOUND1', 'CID1', 500))
    end)
end)
