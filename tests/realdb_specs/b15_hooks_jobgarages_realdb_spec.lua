-- Batch 15H platform hooks, pf-jobgarages on a real database: migration key pf-jobgarages v1 creates
-- the three tables of sql/pf_jobgarages.sql and adds the fleet service columns (fresh database, over
-- tables imported from the SQL file with rows in them, and a second run that applies nothing); the
-- new exports GetFleetVehicle / ListFleet / SetServiceState (allowlisted, validated, one change per
-- plate, compare-and-set on the state, logged); a car with a mechanic or out of service cannot be
-- taken out (also when that happens between the check and the take); and the existing flows (add,
-- take, store, force return) work unchanged on the migrated tables.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
function GetResourceState() return 'missing' end
local worldVehicles = {}
function GetAllVehicles() return worldVehicles end
function SetTimeout() end
function GetCurrentResourceName() return 'pf-jobgarages' end

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-garages/player_vehicles.sql')
load_resource('pfm-core/server/migrations.lua')
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end

Config = nil
load_resource('[pfscripts]/pf-jobgarages/config.lua')
load_resource('[pfscripts]/pf-jobgarages/server/main.lua')
Mock.exportsByResource['pf-jobgarages'] = Mock.exportsByResource['__self']
local api = exports['pf-jobgarages']
local G = PFJobGarages

local MECH, COP = 1, 2
local GARAGE = 'mechanic_main'
local AT_GARAGE = vector3(869.03, -2127.16, 30.6)
local runNo = 0

local function scalar(sql, p) return MySQL.scalar.await(sql, p or {}) end
local function count(sql, p) return tonumber(scalar(sql, p)) or 0 end
local function tableExists(name)
    return count('SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?', { name }) == 1
end
local function columnExists(name)
    return count([[SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE()
        AND TABLE_NAME = 'job_garage_vehicles' AND COLUMN_NAME = ?]], { name }) == 1
end
local function as(resource, fn)
    Mock.invokingResource = resource
    local ok, res = pcall(fn)
    Mock.invokingResource = nil
    if not ok then error(res, 2) end
    return res
end
local function fleetCar(plate, garage, cols)
    cols = cols or {}
    MySQL.insert.await([[INSERT INTO job_garage_vehicles (garage_id, plate, model, label, min_grade, active, assignment_type, `out`, out_citizenid, out_name)
        VALUES (?, ?, ?, ?, 0, ?, 'none', ?, ?, ?)]], { garage or GARAGE, plate, cols.model or 'flatbed', cols.label or 'Truck',
        cols.active or 1, cols.out or 0, cols.outCid, cols.outName })
    return tonumber(scalar('SELECT id FROM job_garage_vehicles WHERE plate = ? AND garage_id = ?', { plate, garage or GARAGE }))
end
local function told(text)
    for _, e in ipairs(Mock.clientEventsNamed('QBCore:Notify')) do if e.args[1] == text then return true end end
    return false
end
local function take(id) return Mock.callCallback('jobgarages:takeVehicle', MECH, GARAGE, id) end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    Mock.invokingResource = nil
    runNo = runNo + 1
    local m = Mock.newPlayer(MECH, 'JGH' .. runNo)
    m.PlayerData.job = { name = 'mechanic', grade = { level = 4 }, onduty = true, isboss = true }
    m.PlayerData.license = 'license:1'
    m.PlayerData.name = 'Mech'
    Mock.coords[MECH] = AT_GARAGE
    local c = Mock.newPlayer(COP, 'JGC' .. runNo)
    c.PlayerData.job = { name = 'police', grade = { level = 1 }, onduty = true }
    worldVehicles = {}
end

describe('migration pf-jobgarages v1', function()
    it('before it runs the exports answer db_unavailable and nothing is created', function()
        assert_false(G.SchemaReady())
        assert_eq(as('pf-mechanicjob', function() return api:GetFleetVehicle('ABC') end).error, 'db_unavailable')
        assert_eq(as('pf-mechanicjob', function() return api:ListFleet('mechanic') end).error, 'db_unavailable')
        assert_eq(as('pf-mechanicjob', function() return api:SetServiceState('ABC', 'due') end).error, 'db_unavailable')
        assert_false(tableExists('job_garage_vehicles'))
    end)
    it('creates the three tables and the service columns on a fresh database; a second run applies nothing', function()
        assert_true(G.Migrate())
        assert_true(G.SchemaReady())
        for _, t in ipairs({ 'job_garage_vehicles', 'job_garage_permissions', 'job_garage_logs' }) do assert_true(tableExists(t), t) end
        for _, c in ipairs({ 'service_state', 'last_service_at', 'service_due_at', 'last_body', 'last_engine' }) do assert_true(columnExists(c), c) end
        assert_eq(count("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = 'pf-jobgarages' AND version = 1"), 1)
        assert_true(G.Migrate())
        assert_eq(count("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = 'pf-jobgarages'"), 1)
        assert_eq(scalar([[SELECT COLUMN_DEFAULT FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE()
            AND TABLE_NAME = 'job_garage_vehicles' AND COLUMN_NAME = 'service_state']]):gsub("'", ''), 'ok')
    end)
    it('over tables imported from sql/pf_jobgarages.sql: keeps the rows, adds the columns, every car starts ok', function()
        for _, t in ipairs({ 'job_garage_vehicles', 'job_garage_permissions', 'job_garage_logs' }) do MySQL.query.await('DROP TABLE ' .. t) end
        MySQL.query.await("DELETE FROM pf_schema_migrations WHERE resource = 'pf-jobgarages'")
        RealDB.exec('[pfscripts]/pf-jobgarages/sql/pf_jobgarages.sql')
        assert_false(columnExists('service_state'))
        local id = fleetCar('OLD1')
        MySQL.insert.await("INSERT INTO job_garage_permissions (garage_id, min_grade_use, min_grade_manage) VALUES ('police_main', 1, 3)")
        assert_true(G.Migrate())
        assert_true(columnExists('service_state'))
        assert_eq(scalar('SELECT service_state FROM job_garage_vehicles WHERE id = ?', { id }), 'ok')
        assert_eq(scalar('SELECT plate FROM job_garage_vehicles WHERE id = ?', { id }), 'OLD1')
        assert_eq(count("SELECT min_grade_manage FROM job_garage_permissions WHERE garage_id = 'police_main'"), 3)
        -- a version that stopped halfway restarts from its first step without an error
        MySQL.query.await("DELETE FROM pf_schema_migrations WHERE resource = 'pf-jobgarages'")
        assert_true(G.Migrate())
    end)
end)

describe('GetFleetVehicle and ListFleet', function()
    it('return a fleet car with its garage, job, service state and who has it out', function()
        fleetCar('GFV' .. runNo, GARAGE, { out = 1, outCid = 'CIDX', outName = 'Driver X' })
        local v = as('pf-mechanicjob', function() return api:GetFleetVehicle(' gfv' .. runNo .. ' ') end)
        assert_true(v.ok)
        assert_eq(v.plate, 'GFV' .. runNo)
        assert_eq(v.garageId, GARAGE)
        assert_eq(v.job, 'mechanic')
        assert_eq(v.model, 'flatbed')
        assert_eq(v.serviceState, 'ok')
        assert_eq(v.lastServiceAt, nil)
        assert_eq(v.out, true)
        assert_eq(v.outBy, 'CIDX')
    end)
    it('not_found for an unknown or removed car, bad_args for no plate', function()
        fleetCar('GFR' .. runNo, GARAGE, { active = 0 })
        assert_eq(as('x', function() return api:GetFleetVehicle('GFR' .. runNo) end).error, 'not_found')
        assert_eq(as('x', function() return api:GetFleetVehicle('NOPE') end).error, 'not_found')
        assert_eq(as('x', function() return api:GetFleetVehicle(nil) end).error, 'bad_args')
        assert_eq(as('x', function() return api:GetFleetVehicle('TOOLONGPLATE') end).error, 'bad_args')
    end)
    it("ListFleet lists the active cars of the job's garages only", function()
        fleetCar('LM1' .. runNo, GARAGE)
        fleetCar('LP1' .. runNo, 'police_main')
        fleetCar('LP2' .. runNo, 'police_main', { active = 0 })
        local res = as('pf-government', function() return api:ListFleet('police') end)
        assert_true(res.ok)
        local plates = {}
        for _, v in ipairs(res.vehicles) do
            assert_eq(v.job, 'police')
            plates[v.plate] = true
        end
        assert_true(plates['LP1' .. runNo])
        assert_eq(plates['LP2' .. runNo], nil)
        assert_eq(plates['LM1' .. runNo], nil)
        local none = as('pf-government', function() return api:ListFleet('taxi') end)
        assert_true(none.ok)
        assert_eq(#none.vehicles, 0)
        assert_eq(as('pf-government', function() return api:ListFleet('') end).error, 'bad_args')
    end)
end)

describe('SetServiceState', function()
    it('is allowlisted: an unknown resource is refused and nothing changes', function()
        local plate = 'SA' .. runNo
        fleetCar(plate)
        local res = as('pfm-houserobbery', function() return api:SetServiceState(plate, 'out_of_service') end)
        assert_eq(res.error, 'not_allowed')
        assert_eq(scalar('SELECT service_state FROM job_garage_vehicles WHERE plate = ?', { plate }), 'ok')
        -- Config.FleetCallers overrides the defaults
        Config.FleetCallers = { SetServiceState = { ['pfm-houserobbery'] = true } }
        assert_true(as('pfm-houserobbery', function() return api:SetServiceState(plate, 'due') end).ok)
        assert_eq(as('pf-mechanicjob', function() return api:SetServiceState(plate, 'ok') end).error, 'not_allowed')
        Config.FleetCallers = nil
    end)
    it('validates the plate, the state and the options', function()
        local plate = 'SV' .. runNo
        fleetCar(plate)
        local function call(...) local a = { ... } return as('pf-mechanicjob', function() return api:SetServiceState(table.unpack(a)) end) end
        assert_eq(call(plate, 'broken').error, 'bad_args')
        assert_eq(call(plate, nil).error, 'bad_args')
        assert_eq(call('', 'ok').error, 'bad_args')
        assert_eq(call(plate, 'ok', 'x').error, 'bad_args')
        assert_eq(call(plate, 'ok', { body = 1001 }).error, 'bad_args')
        assert_eq(call(plate, 'ok', { body = 1.5 }).error, 'bad_args')
        assert_eq(call(plate, 'ok', { engine = -5000 }).error, 'bad_args')
        assert_eq(call(plate, 'ok', { dueAt = os.time() - 10 }).error, 'bad_args')
        assert_eq(call('NOPE' .. runNo, 'ok').error, 'not_found')
        assert_eq(scalar('SELECT service_state FROM job_garage_vehicles WHERE plate = ?', { plate }), 'ok')
    end)
    it('in_service then ok: records the service, the health read, the due date, a log row and an event', function()
        local plate = 'SS' .. runNo
        fleetCar(plate)
        local due = os.time() + 7 * 86400
        local res = as('pfm-policejob', function() return api:SetServiceState(plate, 'due', { dueAt = due, reason = 'mileage' }) end)
        assert_true(res.ok)
        assert_eq(res.previous, 'ok')
        assert_eq(res.serviceState, 'due')
        assert_eq(as('x', function() return api:GetFleetVehicle(plate) end).serviceDueAt, due)
        res = as('pf-mechanicjob', function() return api:SetServiceState(plate, 'in_service', { actor = { src = MECH } }) end)
        assert_true(res.ok and res.changed)
        res = as('pf-mechanicjob', function() return api:SetServiceState(plate, 'ok', { body = 990, engine = 1000, actor = { src = MECH } }) end)
        assert_true(res.ok)
        assert_eq(res.previous, 'in_service')
        local v = as('x', function() return api:GetFleetVehicle(plate) end)
        assert_eq(v.serviceState, 'ok')
        assert_true(type(v.lastServiceAt) == 'number' and math.abs(v.lastServiceAt - tonumber(scalar('SELECT UNIX_TIMESTAMP()'))) < 120, tostring(v.lastServiceAt))
        assert_eq(v.serviceDueAt, nil, 'a service clears the due date')
        assert_eq(v.lastBody, 990)
        assert_eq(v.lastEngine, 1000)
        assert_eq(count("SELECT COUNT(*) FROM job_garage_logs WHERE plate = ? AND action = 'service_state'", { plate }), 3)
        assert_eq(scalar("SELECT actor_name FROM job_garage_logs WHERE plate = ? AND action = 'service_state' ORDER BY id DESC LIMIT 1", { plate }), 'Mech')
        local changes = 0
        for _, e in ipairs(Mock.serverEvents) do if e.name == 'pf-jobgarages:server:serviceStateChanged' then changes = changes + 1 end end
        assert_eq(changes, 3)
        -- the same state again changes nothing and logs nothing
        res = as('pf-mechanicjob', function() return api:SetServiceState(plate, 'ok') end)
        assert_true(res.ok)
        assert_eq(res.changed, false)
        assert_eq(count("SELECT COUNT(*) FROM job_garage_logs WHERE plate = ? AND action = 'service_state'", { plate }), 3)
    end)
    it('a state changed by someone else between the read and the write is not overwritten (busy)', function()
        local plate = 'SC' .. runNo
        fleetCar(plate)
        local realUpdate = MySQL.update
        local inner
        MySQL.update = setmetatable({ await = function(q, p)
            if q:find('UPDATE job_garage_vehicles SET service_state', 1, true) and not inner then
                inner = true
                -- another server process (another server sharing the database) moved it meanwhile
                realUpdate.await("UPDATE job_garage_vehicles SET service_state = 'out_of_service' WHERE plate = ?", { plate })
                -- and a second call for the same plate in this process waits for the first
                inner = as('pf-mechanicjob', function() return api:SetServiceState(plate, 'due') end)
            end
            return realUpdate.await(q, p)
        end }, { __call = function(_, ...) return realUpdate(...) end })
        local res = as('pf-mechanicjob', function() return api:SetServiceState(plate, 'in_service') end)
        MySQL.update = realUpdate
        assert_eq(res.error, 'busy')
        assert_eq(inner.error, 'busy')
        assert_eq(scalar('SELECT service_state FROM job_garage_vehicles WHERE plate = ?', { plate }), 'out_of_service')
        -- the lock is released afterwards
        assert_true(as('pf-mechanicjob', function() return api:SetServiceState(plate, 'in_service') end).ok)
    end)
end)

describe('the garage flows with service states', function()
    it('a car with a mechanic or out of service stays in; a due car goes out with a notice', function()
        local id = fleetCar('TK' .. runNo)
        local plate = 'TK' .. runNo
        as('pf-mechanicjob', function() return api:SetServiceState(plate, 'in_service') end)
        local ok, why = take(id)
        assert_eq(ok, false)
        assert_eq(why, 'in_service')
        assert_true(told('This vehicle is with a mechanic.'))
        as('pf-mechanicjob', function() return api:SetServiceState(plate, 'out_of_service') end)
        ok, why = take(id)
        assert_eq(why, 'out_of_service')
        assert_eq(tonumber(scalar('SELECT `out` FROM job_garage_vehicles WHERE id = ?', { id })), 0)
        as('pf-mechanicjob', function() return api:SetServiceState(plate, 'due') end)
        Mock.reset()
        ok = take(id)
        assert_eq(ok, true)
        assert_true(told('This vehicle is due for service.'))
        assert_eq(tonumber(scalar('SELECT `out` FROM job_garage_vehicles WHERE id = ?', { id })), 1)
        assert_eq(#Mock.clientEventsNamed('jobgarages:spawnVehicle'), 1)
    end)
    it('a car sent to a mechanic between the check and the take is not taken (one statement)', function()
        local id = fleetCar('TR' .. runNo)
        local realScalar = MySQL.scalar
        MySQL.scalar = setmetatable({ await = function(q, p)
            local r = realScalar.await(q, p)
            if q:find('SELECT service_state FROM job_garage_vehicles WHERE id', 1, true) then
                MySQL.update.await("UPDATE job_garage_vehicles SET service_state = 'in_service' WHERE id = ?", { id })
            end
            return r
        end }, { __call = function(_, ...) return realScalar(...) end })
        local ok = take(id)
        MySQL.scalar = realScalar
        assert_eq(ok, false)
        assert_eq(tonumber(scalar('SELECT `out` FROM job_garage_vehicles WHERE id = ?', { id })), 0)
    end)
    it('add, take, store and force return work as before on the migrated tables', function()
        local plate = 'FL' .. runNo
        local cid = Mock.players[MECH].PlayerData.citizenid
        MySQL.insert.await("INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, garage, state, depotprice) VALUES ('license:1', ?, 'flatbed', '1', '{}', ?, 'pillboxgarage', 1, 0)", { cid, plate })
        Mock.fireNet('jobgarages:addFleetVehicle', MECH, GARAGE, { plate = plate, label = 'Truck', min_grade = 0 })
        assert_true(told('Vehicle added to job fleet.'))
        local id = tonumber(scalar('SELECT id FROM job_garage_vehicles WHERE plate = ? AND active = 1', { plate }))
        assert_eq(scalar('SELECT service_state FROM job_garage_vehicles WHERE id = ?', { id }), 'ok')
        assert_eq(take(id), true)
        assert_eq(tonumber(scalar('SELECT `out` FROM job_garage_vehicles WHERE id = ?', { id })), 1)
        -- store it: the car with that plate is beside the garage
        local veh = 5001
        Mock.plates[veh] = plate
        Mock.coords[veh] = AT_GARAGE
        worldVehicles = { veh }
        Mock.fireNet('jobgarages:storeVehicle', MECH, plate, GARAGE)
        assert_true(told('Vehicle stored!'))
        assert_eq(tonumber(scalar('SELECT `out` FROM job_garage_vehicles WHERE id = ?', { id })), 0)
        assert_eq(take(id), true)
        Mock.fireNet('jobgarages:forceReturn', MECH, GARAGE, id)
        assert_true(told('Vehicle force-returned.'))
        assert_eq(tonumber(scalar('SELECT `out` FROM job_garage_vehicles WHERE id = ?', { id })), 0)
        local data = Mock.callCallback('jobgarages:getGarageData', MECH, GARAGE)
        local listed = false
        for _, r in ipairs(data.fleet) do if r.plate == plate then listed = true end end
        assert_true(listed)
    end)
end)
