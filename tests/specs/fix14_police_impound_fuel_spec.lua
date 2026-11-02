-- pfm-policejob impound and fuel (batch 13b open items, 13B-POLICE):
--   * police:server:Impound stores the level pfm-fuel keeps for the car, not the officer's client
--     number; with fuel sync on but no level for that car the client's value can only lower the
--     stored one; with sync off the client's value is all there is;
--   * releasing a seized car: the server takes it out of the impound once, spawns it with its plate
--     and names its row to pfm-fuel (UseStoredFuel), so the car starts at its stored fuel.
load_resource('tests/lua/fivem_mocks.lua')
QBCore = QBCoreMock
Commands = {}
QBCoreMock.Commands.Add = function(name, _, _, _, fn) Commands[name] = fn end

local vehicles = {}
function GetAllVehicles() return vehicles end
local fuel = { synced = true, levels = {}, named = {} }
Mock.exportsByResource['pfm-fuel'] = {
    IsFuelSynced = function() return fuel.synced end,
    GetVehicleFuel = function(_, veh, plate) return fuel.levels[veh] end,
    UseStoredFuel = function(_, veh, plate) fuel.named[#fuel.named + 1] = { veh = veh, plate = plate } return true end,
}
function GetResourceState(name) return name == 'pfm-fuel' and 'started' or 'missing' end
local spawned = {}
function CreateVehicleServerSetter(hash, vtype, x, y, z, h) spawned[#spawned + 1] = { hash = hash, type = vtype, x = x, y = y } return 900 + #spawned end
local plates = {}
function SetVehicleNumberPlateText(veh, plate) plates[veh] = plate end

-- player_vehicles: one seized car
local cars
local function resetCars() cars = { ['SEIZED1'] = { vehicle = 'adder', mods = '{"color1":3}', body = 900, engine = 800, fuel = 37, state = 2 } } end
local writes = {}
MySQL = {
    scalar = setmetatable({ await = function(q, p) if q:find('SELECT plate FROM player_vehicles', 1, true) then return (cars[p[1]] or {}).vehicle and p[1] or nil end end }, { __call = function() end }),
    single = setmetatable({ await = function(q, p)
        local c = cars[p[1]]
        if c and c.state == p[2] then return { vehicle = c.vehicle, mods = c.mods, body = c.body, engine = c.engine, fuel = c.fuel } end
    end }, { __call = function() end }),
    update = setmetatable({ await = function(q, p)
        writes[#writes + 1] = { q = q, p = p }
        local c = cars[p[2]]
        if q:find('SET state = ? WHERE plate = ? AND state = ?', 1, true) and c and c.state == p[3] then c.state = p[1] return 1 end
        return 0
    end }, { __call = function(_, q, p) writes[#writes + 1] = { q = q, p = p } end }),
    query = setmetatable({ await = function() return {} end }, { __call = function(_, q, p) writes[#writes + 1] = { q = q, p = p } end }),
}

Config = nil
load_resource('pfm-policejob/config.lua')
load_resource('pfm-policejob/server/main.lua')
load_resource('pfm-policejob/server/vehicle.lua')

local COP = 1
local function impoundWrite()
    for _, w in ipairs(writes) do if w.q:find('UPDATE player_vehicles SET state = ?', 1, true) and w.q:find('fuel', 1, true) then return w end end
end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords = {}, {}
    vehicles, writes, spawned, plates = { 500 }, {}, {}, {}
    fuel.synced, fuel.levels, fuel.named = true, {}, {}
    resetCars()
    cars['NEAR1'] = { vehicle = 'sultan', state = 0, fuel = 60 }
    Mock.plates[500] = 'NEAR1'
    Mock.coords[500] = vector3(3, 0, 0)
    local cop = Mock.newPlayer(COP, 'COPCID')
    cop.PlayerData.job = { name = 'police', type = 'leo', onduty = true }
    Mock.coords[COP] = vector3(0, 0, 0)
end

describe('impound fuel', function()
    it('is the level the server keeps for that car, whatever the officer\'s client sends', function()
        fuel.levels[500] = 12
        Mock.fireNet('police:server:Impound', COP, 'NEAR1', true, 0, 1000, 1000, 100)
        local w = impoundWrite()
        assert_true(w ~= nil)
        assert_true(w.q:find('fuel = ?', 1, true) ~= nil)
        assert_eq(w.p[4], 12)
    end)
    it('without a level for the car the client can only lower the stored fuel', function()
        Mock.fireNet('police:server:Impound', COP, 'NEAR1', true, 0, 1000, 1000, 100)
        local w = impoundWrite()
        assert_true(w.q:find('LEAST(COALESCE(fuel, ?), ?)', 1, true) ~= nil)
        assert_eq(w.p[4], 100)
        assert_eq(w.p[5], 100)
    end)
    it('with fuel sync off the client\'s level is all there is', function()
        fuel.synced = false
        Mock.fireNet('police:server:Impound', COP, 'NEAR1', true, 0, 1000, 1000, 55)
        local w = impoundWrite()
        assert_true(w.q:find('fuel = ?', 1, true) ~= nil)
        assert_eq(w.p[4], 55)
    end)
end)

describe('impound release', function()
    it('the server spawns the car with its plate and names the row to pfm-fuel', function()
        Mock.coords[COP] = Config.Locations['impound'][1]
        local netId, info = Mock.callCallback('police:server:ReleaseImpound', COP, 'SEIZED1', 1)
        assert_eq(netId, 901)
        assert_eq(#spawned, 1)
        assert_eq(spawned[1].hash, GetHashKey('adder'))
        assert_eq(plates[901], 'SEIZED1')
        assert_eq(#fuel.named, 1)
        assert_eq(fuel.named[1].plate, 'SEIZED1')
        assert_eq(info.mods, '{"color1":3}')
        assert_eq(cars['SEIZED1'].state, 0)
        assert_eq(info.fuel, nil)                    -- the fuel never goes through the client
    end)
    it('once per seizure, only on duty, only at the lot', function()
        Mock.coords[COP] = vector3(0, 0, 0)
        assert_eq(Mock.callCallback('police:server:ReleaseImpound', COP, 'SEIZED1', 1), nil)   -- not at the lot
        Mock.coords[COP] = Config.Locations['impound'][1]
        Mock.players[COP].PlayerData.job.onduty = false
        assert_eq(Mock.callCallback('police:server:ReleaseImpound', COP, 'SEIZED1', 1), nil)
        Mock.players[COP].PlayerData.job.onduty = true
        assert_true(Mock.callCallback('police:server:ReleaseImpound', COP, 'SEIZED1', 1) ~= nil)
        assert_eq(Mock.callCallback('police:server:ReleaseImpound', COP, 'SEIZED1', 1), nil)   -- already out
        assert_eq(#spawned, 1)
        assert_eq(Mock.netHandlers['police:server:TakeOutImpound'], nil)
    end)
end)
