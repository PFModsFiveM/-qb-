-- pfm-garages house garages (fix14 GAR-1): the server builds them itself, from houselocations at
-- start and from pfm-houses (exports SetHouseGarage) when an agent places one, keyed by the house
-- name in lower case without spaces. Clients used to send their whole garage list
-- (qb-garages:server:syncGarage), so anyone could point another house's garage at their own house
-- (its owner could no longer park there), move it away from a paid tow, give it a table label that
-- broke the Garages app for every key holder, or add any number of entries.
load_resource('tests/lua/ledger_env.lua')
QBCoreMock.Shared.Vehicles = { sultan = { name = 'Sultan', brand = 'Karin', price = 1000, category = 'sports' } }
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end

local houseRows = {}   -- houselocations
local cars = {}        -- player_vehicles: [plate] = row
local houseQueries = 0
local function copy(t) local o = {} for k, v in pairs(t) do o[k] = v end return o end
FakeDB.extraPatterns = {
    { 'SELECT name, label, garage FROM houselocations', function() houseQueries = houseQueries + 1 return houseRows end },
    { 'UPDATE player_vehicles SET state = 1 WHERE state = 0', function() return 0 end },
    { "AND TABLE_NAME = 'job_garage_vehicles'", function() return 1 end },
    { 'SELECT plate FROM job_garage_vehicles WHERE active = 1 AND plate IN', function() return {} end },
    { 'SELECT vehicle, state FROM player_vehicles WHERE plate = ? AND citizenid = ?', function(p)
        local c = cars[p[1]]
        return (c and c.citizenid == p[2]) and { copy(c) } or nil
    end },
    { 'UPDATE player_vehicles SET state = 1, garage = ? WHERE plate = ? AND citizenid = ? AND state IN (0, 1)', function(p)
        local c = cars[p[2]]
        if not c or c.citizenid ~= p[3] or (c.state ~= 0 and c.state ~= 1) then return 0 end
        c.state, c.garage = 1, p[1]
        return 1
    end },
    { 'SELECT plate, vehicle, garage, state, depotprice, fuel, engine, body, balance FROM player_vehicles WHERE citizenid = ?', function(p)
        local out = {}
        for plate, c in pairs(cars) do if c.citizenid == p[1] then local r = copy(c) r.plate = plate out[#out + 1] = r end end
        return out
    end },
    { "SELECT plate, paid FROM pfm_garage_depot_releases WHERE citizenid = ? AND state = 'paid'", function() return {} end },
    -- the statements of the code before this fix, so a check against it fails on what it does
    { 'SELECT citizenid FROM player_vehicles WHERE plate = ?', function(p) return cars[p[1]] and cars[p[1]].citizenid end },
    { 'UPDATE player_vehicles SET state = ?, garage = ? WHERE plate = ?', function(p) if cars[p[3]] then cars[p[3]].state, cars[p[3]].garage = p[1], p[2] end return 1 end },
    { 'SELECT * FROM houselocations WHERE name = ?', function(p)
        for _, r in ipairs(houseRows) do if r.name == p[1] then return { r } end end
        return nil
    end },
}

-- pfm-houses as pfm-garages sees it: who holds a key to which house
local keys, keyChecks = {}, {}
Mock.exportsByResource['pfm-houses'] = {
    hasKey = function(_, license, cid, house)
        keyChecks[#keyChecks + 1] = { license = license, cid = cid, house = house }
        return keys[house .. '|' .. cid] == true
    end,
}
Mock.exportsByResource['pf-devices'] = { RegisterApp = function() return true end, RegisterAppHandlers = function() return true end, Push = function() return true end }

LedgerEnv.load('pfm-garages', { 'pfm-garages/config.lua', 'pfm-garages/server/main.lua', 'pfm-garages/server/apps.lua' })
local SetHouseGarage = Mock.selfExport('SetHouseGarage')

local existing, plates, timers = {}, {}, {}
function DoesEntityExist(e) return existing[e] == true end
function GetVehicleNumberPlateText(veh) return plates[veh] end
function GetAllVehicles() local out = {} for e in pairs(existing) do out[#out + 1] = e end table.sort(out) return out end
function DeleteEntity(e) existing[e] = nil end
function SetTimeout(_, fn) timers[#timers + 1] = fn end

local P, ATTACKER = 1, 2
local CONFIGURED = {}
for id, g in pairs(Config.Garages) do CONFIGURED[id] = g end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players, Mock.coords, Mock.vehicleOf = {}, {}, {}
    existing, plates, timers, keys, keyChecks = {}, {}, {}, {}, {}
    houseQueries = 0
    -- only the configured garages, as on a fresh start
    for id in pairs(Config.Garages) do if not CONFIGURED[id] then Config.Garages[id] = nil end end
    for _, src in ipairs({ P, ATTACKER }) do
        local p = Mock.newPlayer(src)
        p.PlayerData.license = 'license:' .. src
        p.PlayerData.money = { cash = 0, bank = 1000 }
    end
    houseRows = {
        { name = 'Grove St1', label = 'Grove St 1', garage = '{"x":10.5,"y":20,"z":30,"w":90}' },
        { name = 'Attacker Rd1', label = 'Attacker Rd 1', garage = '{"x":900,"y":900,"z":30,"w":0}' },
        { name = 'nogarage1', label = 'No Garage 1', garage = '{"y":0,"x":0,"w":0,"z":0}' },  -- the column default
        { name = 'broken1', label = 'Broken 1', garage = '{"x":"a","y":1,"z":1}' },
        { name = 'garbage1', label = 'Garbage 1', garage = 'not json' },
        { name = 'motelgarage', label = 'Fake Motel', garage = '{"x":1,"y":1,"z":1}' },  -- the id of a configured garage
    }
    cars = { HOUSE1 = { citizenid = 'CID1', vehicle = 'sultan', state = 0, depotprice = 0, garage = 'motelgarage', fuel = 50, engine = 1000, body = 1000, balance = 0 } }
end

local function inCar(src, plate, pos)
    existing[700 + src], plates[700 + src] = true, plate
    Mock.vehicleOf[src] = 700 + src
    Mock.coords[src] = pos
    Mock.coords[700 + src] = pos
end

describe('house garages are built on the server', function()
    it('no client can send garages any more', function()
        assert_eq(Mock.netHandlers['qb-garages:server:syncGarage'], nil)
    end)

    it('come from houselocations at start, keyed by the house name; houses without a garage or with broken coords are skipped', function()
        PFGarages.Start()
        assert_eq(houseQueries, 1)
        local g = Config.Garages.grovest1
        assert_true(g ~= nil, 'the garage of Grove St1')
        assert_eq(g.type, 'house')
        assert_eq(g.houseName, 'Grove St1')
        assert_eq(g.label, 'Grove St 1')
        assert_eq(g.takeVehicle.x, 10.5)
        assert_eq(g.spawnPoint[1].w, 90)
        assert_eq(Config.Garages.nogarage1, nil)
        assert_eq(Config.Garages.broken1, nil)
        assert_eq(Config.Garages.garbage1, nil)
        -- a house named like a configured garage does not replace it
        assert_eq(Config.Garages.motelgarage.type, 'public')
        assert_eq(Config.Garages.motelgarage.label, 'Motel Parking')
    end)

    it('pfm-houses adds and moves a garage; a configured garage, another house\'s id and garbage are refused', function()
        assert_true(Mock.cross(SetHouseGarage, 'Vinewood Blvd3', 'Vinewood Blvd 3', { x = 1, y = 2, z = 3, w = 4 }))
        assert_eq(Config.Garages.vinewoodblvd3.houseName, 'Vinewood Blvd3')
        assert_true(Mock.cross(SetHouseGarage, 'Vinewood Blvd3', 'Vinewood Blvd 3', { x = 5, y = 6, z = 7, w = 8 }))
        assert_eq(Config.Garages.vinewoodblvd3.takeVehicle.x, 5, 'moved')
        assert_false(Mock.cross(SetHouseGarage, 'vinewoodblvd3', 'Other', { x = 9, y = 9, z = 9 }), 'another house with the same id')
        assert_eq(Config.Garages.vinewoodblvd3.houseName, 'Vinewood Blvd3')
        assert_false(Mock.cross(SetHouseGarage, 'Motel Garage', 'Mine now', { x = 1, y = 1, z = 1 }))
        assert_eq(Config.Garages.motelgarage.type, 'public')
        assert_false(Mock.cross(SetHouseGarage, nil, 'x', { x = 1, y = 1, z = 1 }))
        assert_false(Mock.cross(SetHouseGarage, 'Nan St1', 'x', { x = 0 / 0, y = 1, z = 1 }))
        assert_false(Mock.cross(SetHouseGarage, 'Huge St1', 'x', { x = math.huge, y = 1, z = 1 }))
        assert_false(Mock.cross(SetHouseGarage, 'Text St1', 'x', 'nope'))
        assert_false(Mock.cross(SetHouseGarage, string.rep('a', 200), 'x', { x = 1, y = 1, z = 1 }))
        assert_eq(Config.Garages.nanst1, nil)
    end)

    it('a label that is not text cannot break the Garages app', function()
        assert_true(Mock.cross(SetHouseGarage, 'Odd Ln1', { 'not', 'text' }, { x = 50, y = 50, z = 30 }))
        assert_eq(Config.Garages.oddln1.label, 'Odd Ln1')
        PFGarages.Start()
        keys['Odd Ln1|CID1'], keys['Grove St1|CID1'] = true, true
        local list = PFGarages.AppList(P)
        assert_true(list.ok)
        local ids = {}
        for _, g in ipairs(list.garages) do ids[g.id] = g end
        assert_true(ids.oddln1 ~= nil and ids.grovest1 ~= nil, 'my house garages are tow destinations')
        assert_eq(ids.attackerrd1, nil, 'not a house I have no key to')
    end)
end)

describe('parking at a house garage', function()
    it('checks the key of that house, whatever type the client names', function()
        PFGarages.Start()
        local g = Config.Garages.grovest1
        inCar(P, 'HOUSE1', vector3(g.takeVehicle.x, g.takeVehicle.y, g.takeVehicle.z))
        -- the client says 'public' (any type other than 'house' skipped the key check)
        assert_false(Mock.callCallback('qb-garages:server:canDeposit', P, 'HOUSE1', 'public', 'grovest1', 1))
        assert_eq(keyChecks[#keyChecks].house, 'Grove St1')
        assert_eq(keyChecks[#keyChecks].cid, 'CID1')
        assert_eq(cars.HOUSE1.state, 0)
        keys['Grove St1|CID1'] = true
        assert_true(Mock.callCallback('qb-garages:server:canDeposit', P, 'HOUSE1', 'public', 'grovest1', 1))
        assert_eq(cars.HOUSE1.state, 1)
        assert_eq(cars.HOUSE1.garage, 'grovest1')
    end)
    it('a garage that is not on the server does not exist', function()
        PFGarages.Start()
        inCar(P, 'HOUSE1', vector3(0, 0, 0))
        assert_false(Mock.callCallback('qb-garages:server:canDeposit', P, 'HOUSE1', 'house', 'myownhouse', 1))
        assert_eq(cars.HOUSE1.state, 0)
    end)
end)

describe('a client asking for a house garage it has not heard of', function()
    it('gets the server\'s label and position only, without a database read', function()
        PFGarages.Start()
        local before = #FakeDB.log
        local info = Mock.callCallback('qb-garages:server:getHouseGarage', P, 'Grove St1')
        assert_eq(#FakeDB.log, before, 'no query')
        assert_eq(info.label, 'Grove St 1')
        assert_eq(info.coords.x, 10.5)
        assert_eq(info.coords.w, 90)
        assert_eq(info.owned, nil)
        assert_eq(info.price, nil)
        assert_eq(Mock.callCallback('qb-garages:server:getHouseGarage', P, 'nogarage1'), nil)
        assert_eq(Mock.callCallback('qb-garages:server:getHouseGarage', P, 'grovest1'), nil, 'the house name, not the id')
        assert_eq(Mock.callCallback('qb-garages:server:getHouseGarage', P, { 1 }), nil)
    end)
end)
