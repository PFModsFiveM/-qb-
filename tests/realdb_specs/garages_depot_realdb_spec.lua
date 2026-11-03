-- pfm-garages impound release fee on the real database and the real ledger: paid ahead from the
-- Garages app once (stable keys: a retry or a second click never charges again), stored so it
-- survives a restart, used up when the car leaves the depot, refused for cars that are not the
-- player's or are seized; a failed attempt (not enough money) does not block a later payment.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
local states = { ['pf-government'] = 'missing', ['pf-services'] = 'missing' }
function GetResourceState(name) return states[name] or 'started' end
vec3 = vec3 or vector3
vec4 = vec4 or vector4

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
RealDB.exec('pfm-garages/player_vehicles.sql')
function GetCurrentResourceName() return 'pfm-banking' end
Config = nil
load_resource('pfm-banking/config.lua')
load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')
Mock.exportsByResource['pfm-banking'] = Mock.exportsByResource['__self']
Mock.exportsByResource['__self'] = nil
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end
assert(PFLedger.Start(), 'ledger start')

QBCoreMock.Shared.Vehicles = { sultan = { name = 'Sultan', brand = 'Karin', price = 1000, category = 'sports' } }
Mock.exportsByResource['pf-devices'] = { RegisterApp = function() return true end, RegisterAppHandlers = function() return true end, Push = function() return true end }

local function loadGarages()
    function GetCurrentResourceName() return 'pfm-garages' end
    Config = nil
    load_resource('pfm-banking/payouts.lua')
    load_resource('pfm-garages/config.lua')
    load_resource('pfm-garages/server/main.lua')
    load_resource('pfm-garages/server/apps.lua')
    PFGarages.Start()
end
loadGarages()
assert(PFGarages.dbReady, 'pfm-garages migrations')

local existing = {}
local nextEntity = 900
function CreateVehicleServerSetter() nextEntity = nextEntity + 1 existing[nextEntity] = true return nextEntity end
function SetVehicleNumberPlateText() end
function DoesEntityExist(e) return existing[e] == true end
function GetAllVehicles() return {} end

local P, OTHER = 1, 2
local DEPOT = Config.Garages.depotLot.spawnPoint[1]
local function bank(src) return Mock.players[src].PlayerData.money.bank end
local function cash(src) return Mock.players[src].PlayerData.money.cash end
local function car(plate, owner, state, fee)
    MySQL.insert.await("INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, garage, state, depotprice) VALUES ('l', ?, 'sultan', '1', '{}', ?, 'motelgarage', ?, ?)",
        { owner, plate, state, fee })
end
local function row(plate) return MySQL.single.await('SELECT state, depotprice FROM player_vehicles WHERE plate = ?', { plate }) end
local function charges(plate)
    return tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_transactions WHERE idempotency_key LIKE 'pfm-garages:depot:%' AND state = 'completed' AND reason = ?", { 'Impound release ' .. plate })) or 0
end
local function spawn(src, plate) return Mock.callCallback('qb-garages:server:spawnvehicle', src, plate, 'depotLot', 1) end

local plateNo = 0
local function newPlate() plateNo = plateNo + 1 return ('DEP%04d'):format(plateNo) end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    for _, src in ipairs({ P, OTHER }) do
        local p = Mock.newPlayer(src, 'GCID' .. src)
        p.PlayerData.money = { cash = 100, bank = 2000 }
        p.PlayerData.source = src
        Mock.coords[src] = vector3(DEPOT.x, DEPOT.y, DEPOT.z)
    end
end

describe('impound release fee paid ahead', function()
    it('is charged once (cash short, so bank) and lets the car out of the depot once', function()
        local plate = newPlate()
        car(plate, 'GCID1', 0, 500)
        local res = PFGarages.AppPayDepot(P, { plate = plate })
        assert_true(res.ok, tostring(res.error))
        assert_eq(res.paid, 500)
        assert_eq(bank(P), 1500)
        assert_eq(cash(P), 100)
        assert_true(PFGarages.AppPayDepot(P, { plate = plate }).already)
        Mock.fireNet('qb-garages:server:PayDepotPrice', P, { plate = plate })
        assert_eq(bank(P), 1500)
        assert_eq(charges(plate), 1)
        local rel = MySQL.single.await('SELECT state, paid, fee FROM pfm_garage_depot_releases WHERE plate = ?', { plate })
        assert_eq(rel.state, 'paid')
        assert_eq(tonumber(rel.paid), 500)
        assert_true(spawn(P, plate) ~= nil)
        assert_eq(tonumber(row(plate).depotprice), 0)
        assert_eq(tonumber(row(plate).state), 0)
        assert_eq(MySQL.scalar.await('SELECT state FROM pfm_garage_depot_releases WHERE plate = ?', { plate }), 'used')
        assert_eq(spawn(P, plate), nil)                                  -- out already
    end)
    it('survives a restart of the resource', function()
        local plate = newPlate()
        car(plate, 'GCID1', 0, 400)
        assert_true(PFGarages.AppPayDepot(P, { plate = plate }).ok)
        loadGarages()
        assert_true(spawn(P, plate) ~= nil)
        assert_eq(bank(P), 1600)
        assert_eq(charges(plate), 1)
    end)
    it('a retry after a crash (money moved, release not written) does not charge again', function()
        local plate = newPlate()
        car(plate, 'GCID1', 0, 300)
        assert_true(PFGarages.AppPayDepot(P, { plate = plate }).ok)
        MySQL.update.await("UPDATE pfm_garage_depot_releases SET paid = 0, state = 'open', attempt = 1 WHERE plate = ?", { plate })
        loadGarages()
        assert_true(PFGarages.AppPayDepot(P, { plate = plate }).ok)
        assert_eq(bank(P), 1700)
        assert_eq(charges(plate), 1)
    end)
    it('not enough money moves nothing; a later attempt with money pays once', function()
        local plate = newPlate()
        car(plate, 'GCID1', 0, 5000)
        assert_eq(PFGarages.AppPayDepot(P, { plate = plate }).error, 'insufficient_funds')
        assert_eq(PFGarages.AppPayDepot(P, { plate = plate }).error, 'insufficient_funds')
        assert_eq(bank(P), 2000)
        assert_eq(spawn(P, plate), nil)
        Mock.players[P].PlayerData.money.bank = 9000
        loadGarages()                                                    -- a restart in between, too
        assert_true(PFGarages.AppPayDepot(P, { plate = plate }).ok)
        assert_eq(bank(P), 4000)
        assert_eq(charges(plate), 1)
    end)
    it('refuses cars that are not the player\'s or are seized, and cars without a fee', function()
        local theirs, seized, parked = newPlate(), newPlate(), newPlate()
        car(theirs, 'GCID2', 0, 500)
        car(seized, 'GCID1', 2, 500)
        car(parked, 'GCID1', 1, 0)
        assert_eq(PFGarages.AppPayDepot(P, { plate = theirs }).error, 'not_owned')
        assert_eq(PFGarages.AppPayDepot(P, { plate = seized }).error, 'seized')
        assert_eq(PFGarages.AppPayDepot(P, { plate = parked }).error, 'nothing_due')
        assert_eq(bank(P), 2000)
        assert_eq(bank(OTHER), 2000)
        assert_eq(spawn(P, seized), nil)
        -- the app list shows each with its real state
        local list = PFGarages.AppList(P)
        local status = {}
        for _, v in ipairs(list.vehicles) do status[v.plate] = v.status end
        assert_eq(status[seized], 'seized')
        assert_eq(status[parked], 'garaged')
        assert_eq(status[theirs], nil)
    end)
    it('a deleted character loses their paid releases', function()
        local plate = newPlate()
        car(plate, 'GCID1', 0, 200)
        assert_true(PFGarages.AppPayDepot(P, { plate = plate }).ok)
        Mock.eventHandlers['pfm-core:server:characterDeleted']('GCID1')
        assert_eq(tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM pfm_garage_depot_releases WHERE citizenid = ?', { 'GCID1' })), 0)
    end)
end)
