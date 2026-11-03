-- pf-mechanicjob fitted performance parts on a real database (MECH-2 / MECH-X2, server/main.lua,
-- server/schema.lua): a fitted part is recorded per car and slot, so it still comes back out as an
-- item after a restart (the record used to live in memory). Taking it off removes the record once,
-- and the saved props (player_vehicles.mods) follow the server's change.
-- MECH-5: the service history's owner check finds the owner's car whether player_vehicles keeps
-- its plate padded, with spaces inside, or as the book writes it (no spaces).
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
QBCore = QBCoreMock
function GetResourceState() return 'missing' end

local states = {}
local stateMeta = { __index = { set = function(self, k, v) rawset(self, k, v) end } }
function Entity(e)
    states[e] = states[e] or { state = setmetatable({}, stateMeta) }
    return states[e]
end
local existing = {}
function DoesEntityExist(e) return existing[e] == true end
function GetAllVehicles() local out = {} for e in pairs(existing) do out[#out + 1] = e end return out end
function GetIsVehicleEngineRunning() return false end

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-garages/player_vehicles.sql')
load_resource('pfm-core/server/migrations.lua')

Config = nil
load_resource('[pfscripts]/pf-mechanicjob/config.lua')
load_resource('[pfscripts]/pf-mechanicjob/shared/debug.lua')
Config.Debug = false
load_resource('[pfscripts]/pf-mechanicjob/shared/performance_parts.lua')
load_resource('[pfscripts]/pf-mechanicjob/server/schema.lua')
assert(PFMech.CoreSchema(), 'core migrations')
local function startResource() load_resource('[pfscripts]/pf-mechanicjob/server/main.lua') end
startResource()

local MECH = 1
local CAR = 500
local HERE = vector3(1.0, 1.0, 1.0)

local function withInventory(p, items)
    p.inv = items
    p.Functions.GetItemByName = function(name)
        local n = p.inv[name]
        if n and n > 0 then return { name = name, amount = n, label = name } end
    end
    p.Functions.RemoveItem = function(name, n)
        n = n or 1
        if (p.inv[name] or 0) < n then return false end
        p.inv[name] = p.inv[name] - n
        return true
    end
    p.Functions.AddItem = function(name, n) p.inv[name] = (p.inv[name] or 0) + (n or 1) return true end
    return p
end
local function count(item) return Mock.players[MECH].inv[item] or 0 end
local function fit(item) Mock.fireNet('pf_mech:server:applyPerformanceUpgrade', MECH, { item = item, vehicle = CAR }) end
local function takeOff(slot) Mock.fireNet('pf-mechanicjob:server:returnUpgradeItem', MECH, slot, CAR) end
local function record(slot) return MySQL.scalar.await("SELECT item FROM pf_mech_fitted_parts WHERE plate = 'TUNED001' AND slot = ?", { slot }) end
local function mods() return json.decode(MySQL.scalar.await("SELECT mods FROM player_vehicles WHERE plate = 'TUNED001'")) end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords, Mock.plates = {}, {}, {}
    states, existing = {}, { [CAR] = true }
    withInventory(Mock.newPlayer(MECH, 'MECH1'), { toolbox = 1, engine3 = 1, engine4 = 1, turbo = 1 })
        .PlayerData.job = { name = 'mechanic', onduty = true }
    Mock.coords[MECH], Mock.coords[CAR], Mock.plates[CAR] = HERE, HERE, ' TUNED001 '
    MySQL.query.await('DELETE FROM pf_mech_fitted_parts')
    MySQL.query.await('DELETE FROM player_vehicles')
    MySQL.query.await([[INSERT INTO player_vehicles (citizenid, vehicle, hash, mods, plate, state)
        VALUES ('OWN1', 'sultan', '0', '{"modEngine":-1,"modTurbo":false,"color1":5}', 'TUNED001', 0)]])
end

describe('MECH-2 fitted parts survive a restart', function()
    it('a part fitted before a restart comes back out as an item after it', function()
        fit('engine3')
        assert_eq(record('engine'), 'engine3')
        assert_eq(mods().modEngine, 2, 'the saved props follow the fit')
        startResource()                                       -- a restart: nothing kept in memory
        PFMech.SchemaReady = true
        takeOff('engine')
        assert_eq(count('engine3'), 1)
        assert_eq(record('engine'), nil)
        assert_eq(mods().modEngine, -1)
        assert_eq(mods().color1, 5, 'the rest of the props is kept')
        takeOff('engine')
        assert_eq(count('engine3'), 1, 'once')
    end)

    it('one part per slot: fitting over one hands it back', function()
        fit('engine3')
        fit('engine4')
        assert_eq(record('engine'), 'engine4')
        assert_eq(count('engine3'), 1)
        fit('turbo')
        assert_eq(mods().modTurbo, true)
        takeOff('turbo')
        assert_eq(mods().modTurbo, false)
        assert_eq(count('turbo'), 1)
        assert_eq(record('engine'), 'engine4', 'other slots untouched')
    end)
end)

describe('MECH-5 the owner reads the service history of their car', function()
    local OWNER, STRANGER = 2, 3
    local function history(src, plate) return Mock.callCallback('pf_mech:service:get', src, plate) end
    local function addCar(cid, plate)
        MySQL.query.await([[INSERT INTO player_vehicles (citizenid, vehicle, hash, mods, plate, state)
            VALUES (?, 'sultan', '0', '{}', ?, 0)]], { cid, plate })
    end

    it('matches the plate as stored, trimmed, or without its inner spaces; nobody else reads it', function()
        Mock.newPlayer(OWNER, 'OWN1')
        Mock.newPlayer(STRANGER, 'STR1')
        MySQL.query.await('DELETE FROM pf_service_book')
        MySQL.query.await([[INSERT INTO pf_service_book (plate, model, title, service, service_description, svc_date)
            VALUES ('AB12CD', 'Sultan', 'Oil', 'Changed oil', '', '2026-01-01'),
                   ('PAD001', 'Sultan', 'Brakes', 'New pads', '', '2026-01-02'),
                   ('TUNED001', 'Sultan', 'Tune', 'Engine', '', '2026-01-03')]])
        addCar('OWN1', 'AB 12 CD')                            -- spaces inside
        addCar('OWN1', ' PAD001 ')                            -- padded
        assert_eq(#history(OWNER, 'AB12CD'), 1, 'what the book and the client send')
        assert_eq(#history(OWNER, 'PAD001'), 1)
        assert_eq(#history(OWNER, ' pad001 '), 1)
        assert_eq(#history(OWNER, 'TUNED001'), 1, 'stored exactly')
        assert_eq(#history(STRANGER, 'AB12CD'), 0)
        assert_eq(#history(STRANGER, 'TUNED001'), 0)
        assert_eq(#history(OWNER, 'AB12C'), 0, 'not a prefix match')
    end)
end)
