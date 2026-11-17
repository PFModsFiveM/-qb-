-- pfm-policejob traffic and impound records on MariaDB (batch 18B):
--   * schema v3 (traffic, impound, telemetry, lab tables) on a fresh database and on one where the
--     batch-15 schema (v1, v2) already ran; a second run applies nothing;
--   * impound records: reason, officer, hold and case from police:server:Impound; a held seizure
--     stays in the impound for a normal officer and a supervisor may release it; the depot record
--     ends when the owner paid at a garage; a tow order is recorded 'ordered', finalized once, and
--     after a restart (memory lost) the database still says it was applied;
--   * citations: one row per uid written before pf-justice is asked; pf-justice not answering leaves
--     it pending and the sweep retries with the same key; one order per uid; a radar reading is cited
--     once; a speed camera cites the driver with the uid SE<speed event id>;
--   * ALPR reads in one batched insert and the retention sweep; breath tests; traffic incidents and
--     their listing by plate; RunPlate against player_vehicles and players; character deletion.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
local started = { ['pf-justice'] = true, ['pf-ambulancejob'] = true }
function GetResourceState(name) return started[name] and 'started' or 'missing' end
function GetCurrentResourceName() return 'pfm-policejob' end

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-garages/player_vehicles.sql')

load_resource('pfm-core/server/migrations.lua')
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end
QBCore = QBCoreMock
Commands = {}
QBCoreMock.Commands.Add = function(name, _, _, _, fn) Commands[name] = fn end

-- world
local vehicles, speeds = {}, {}
function GetAllVehicles() return vehicles end
function GetEntitySpeed(e) return speeds[e] or 0 end
function GetEntityHeading() return 0 end
function GetEntityType() return 2 end
function DoesEntityExist(e) return Mock.plates[e] ~= nil end
function DeleteEntity(e) Mock.plates[e] = nil end
function CreateVehicleServerSetter() return 777 end
function SetVehicleNumberPlateText() end
function SetVehicleDoorsLocked() end

-- pf-justice by contract: one order per key (a repeat returns the first order with duplicate = true)
local justice = { calls = {}, byKey = {}, answer = nil, next = 100 }
Mock.exportsByResource['pf-justice'] = {
    IssueCitation = function(_, spec, opts)
        justice.calls[#justice.calls + 1] = { spec = spec, key = opts and opts.key, actor = opts and opts.actor }
        if justice.answer then return justice.answer end
        local first = justice.byKey[opts.key]
        if first then return { ok = true, orderId = first, citationId = first, duplicate = true } end
        justice.next = justice.next + 1
        justice.byKey[opts.key] = justice.next
        return { ok = true, orderId = justice.next, citationId = justice.next }
    end,
}
Mock.exportsByResource['pf-ambulancejob'] = { GetBreathAlcohol = function() return { ok = true, bac = 0.0912 } end }

Config = nil
load_resource('pfm-policejob/config.lua')
load_resource('pfm-policejob/config_traffic.lua')
Config.Traffic.SpeedLimits.Zones = {}
Config.Traffic.Alpr.FixedReaders = {}

local function count(sql, params) return tonumber(MySQL.scalar.await(sql, params or {})) or 0 end
local function applied() return count("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = 'pfm-policejob'") end

describe('schema v3', function()
    it('on top of the batch-15 schema only v3 runs; a second run applies nothing', function()
        -- an installed batch-15 server: v1 and v2 (unchanged in the list) already applied
        load_resource('pfm-policejob/server/schema.lua')
        local M = PFPoliceSchema.Migrations
        assert_true(RunMigrations('pfm-policejob', { M[1], M[2] }))
        assert_eq(applied(), 2)
        assert_true(PFPoliceSchema.Run())
        assert_eq(applied(), 3)
        for _, t in ipairs({ 'pf_police_alpr_reads', 'pf_police_speed_events', 'pf_police_breath_tests', 'pf_police_impounds',
            'pf_police_traffic_incidents', 'pf_police_citations', 'pf_police_telemetry', 'pf_police_telemetry_holds',
            'pf_evidence_reference_samples', 'pf_evidence_test_fires', 'pf_evidence_lab_jobs' }) do
            assert_eq(count('SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?', { t }), 1, t)
        end
        PFPoliceSchema.state = 'idle'
        assert_true(PFPoliceSchema.Run())
        assert_eq(applied(), 3)
        -- every step is rerun-safe (an interrupted v3 starts again from its first step)
        for _, sql in ipairs(PFPoliceSchema.Migrations[3].up) do MySQL.query.await(sql) end
    end)
end)

load_resource('pfm-policejob/server/vehicle.lua')
load_resource('pfm-policejob/server/traffic.lua')
local T, I = PFTraffic, PFImpound

local COP, SUP, CIV = 1, 2, 3
local CAR, CRUISER = 501, 900
local LOT = Config.Locations['impound'][1]

local function players()
    Mock.players, Mock.coords, Mock.plates, Mock.vehicleOf, Mock.models = {}, {}, {}, {}, {}
    local cop = Mock.newPlayer(COP, 'COPCID')
    cop.PlayerData.job = { name = 'police', type = 'leo', onduty = true, grade = { level = 1 } }
    local sup = Mock.newPlayer(SUP, 'SUPCID')
    sup.PlayerData.job = { name = 'police', type = 'leo', onduty = true, grade = { level = 4 } }
    Mock.newPlayer(CIV, 'CIVCID')
    Mock.coords[COP], Mock.coords[SUP], Mock.coords[CIV] = vector3(0, 0, 0), vector3(1, 0, 0), vector3(2, 0, 0)
end

local function car(plate, state, depot)
    MySQL.insert.await("INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, garage, state, depotprice) VALUES ('l', 'CIVCID', 'sultan', '1', '{}', ?, 'pillbox', ?, ?)",
        { plate, state or 0, depot or 0 })
end

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 86400
    Mock.gameTimer = Mock.gameTimer + 100000
    players()
    justice.calls, justice.answer = {}, nil
    T.Readers, T.Seen, T.CamSeen, T.ReadQueue, T.Rate, T.Submitting, T.CiteLocks = {}, {}, {}, {}, {}, {}, {}
    vehicles, speeds = {}, {}
end

describe('impound records', function()
    it('a seizure keeps reason, officer, hold and case; a held car stays in for a normal officer', function()
        car('SEIZ1', 0)
        vehicles = { CAR }
        Mock.plates[CAR], Mock.coords[CAR] = 'SEIZ1', vector3(3, 0, 0)
        Mock.fireNet('police:server:Impound', COP, 'SEIZ1', true, 0, 900, 900, 50, { reason = 'Evidence in a robbery', holdHours = 9999, caseRef = 'CASE-12' })
        local row = MySQL.single.await("SELECT * FROM pf_police_impounds WHERE plate = 'SEIZ1'")
        assert_eq(row.kind, 'seizure')
        assert_eq(row.reason, 'Evidence in a robbery')
        assert_eq(row.officer_cid, 'COPCID')
        assert_eq(row.owner_cid, 'CIVCID')
        assert_eq(row.case_ref, 'CASE-12')
        assert_eq(row.state, 'impounded')
        assert_eq(tonumber(row.hold_until), Mock.clock + Config.Traffic.Impound.MaxHoldHours * 3600, 'hold capped')
        assert_eq(count("SELECT state FROM player_vehicles WHERE plate = 'SEIZ1'"), 2)

        Mock.coords[COP], Mock.coords[SUP] = LOT, LOT
        assert_eq(Mock.callCallback('police:server:ReleaseImpound', COP, 'SEIZ1', 1), nil, 'held')
        assert_eq(count("SELECT state FROM player_vehicles WHERE plate = 'SEIZ1'"), 2)
        assert_eq(Mock.callCallback('police:server:ReleaseImpound', SUP, 'SEIZ1', 1), 777, 'a supervisor may release it')
        row = MySQL.single.await("SELECT * FROM pf_police_impounds WHERE plate = 'SEIZ1'")
        assert_eq(row.state, 'released')
        assert_eq(row.released_by, 'SUPCID')
        assert_eq(Mock.exportsByResource['__self'].GetImpound('SEIZ1').impound, nil)
        assert_eq(I.Get('SEIZ1', { history = true }).impound.state, 'released')
    end)

    it('a depot record has no hold and ends when the owner paid at a garage', function()
        car('DEPOT1', 0)
        vehicles = { CAR }
        Mock.plates[CAR], Mock.coords[CAR] = 'DEPOT1', vector3(3, 0, 0)
        Mock.fireNet('police:server:Impound', COP, 'DEPOT1', false, 750, 900, 900, 50, { reason = 'Parked on the sidewalk', holdHours = 24 })
        local imp = I.Get('DEPOT1').impound
        assert_eq(imp.kind, 'depot')
        assert_eq(imp.fee, 750)
        assert_eq(imp.holdUntil, nil)
        -- the garage cleared the fee when the owner took the car out
        MySQL.update.await("UPDATE player_vehicles SET depotprice = 0, state = 0 WHERE plate = 'DEPOT1'")
        assert_eq(I.Get('DEPOT1').impound, nil)
        assert_eq(MySQL.single.await("SELECT released_by FROM pf_police_impounds WHERE plate = 'DEPOT1'").released_by, 'garage')
    end)

    it('a tow order is recorded, finalized once, and stays applied after a restart', function()
        car('TOW1', 0)
        vehicles = { CAR }
        Mock.plates[CAR], Mock.coords[CAR] = 'TOW1', vector3(3, 0, 0)
        started['pf-services'] = true
        local tow = Mock.newPlayer(9, 'TOWCID')
        tow.PlayerData.job = { name = 'tow', onduty = true }
        Mock.exportsByResource['pf-services'] = {
            CreateRequest = function(_, o) return { ok = true, id = 55, request = { id = 55, kind = 'tow.impound', meta = o.meta } } end,
            Emit = function() return 1 end,
        }
        Mock.fireNet('police:server:Impound', COP, 'TOW1', true, 0, 900, 900, 50, { reason = 'Stolen' })
        assert_eq(MySQL.single.await("SELECT state FROM pf_police_impounds WHERE plate = 'TOW1'").state, 'ordered')
        local finalize = Mock.exportsByResource['__self'].FinalizeImpound
        assert_true(finalize('TOW1', { fullImpound = true, officer = 'COPCID', reason = 'Stolen' }, 55))
        assert_eq(MySQL.single.await("SELECT state FROM pf_police_impounds WHERE plate = 'TOW1'").state, 'impounded')
        assert_eq(count("SELECT COUNT(*) FROM pf_police_impounds WHERE plate = 'TOW1'"), 1)
        -- a restart loses the memory of applied orders; the record still says it was applied
        load_resource('pfm-policejob/server/vehicle.lua')
        MySQL.update.await("UPDATE player_vehicles SET state = 0 WHERE plate = 'TOW1'")
        assert_false(Mock.exportsByResource['__self'].FinalizeImpound('TOW1', { fullImpound = true }, 55))
        assert_eq(count("SELECT state FROM player_vehicles WHERE plate = 'TOW1'"), 0, 'not impounded twice')
        started['pf-services'] = nil
        Mock.players[9] = nil
    end)
end)

describe('citations', function()
    it('pending while pf-justice cannot answer, then one order for the uid', function()
        justice.answer = { ok = false, error = 'db_unavailable' }
        local r = T.IssueCitation(COP, CIV, 'reckless')
        assert_true(r.pending)
        local row = MySQL.single.await("SELECT * FROM pf_police_citations WHERE citizenid = 'CIVCID' ORDER BY id DESC LIMIT 1")
        assert_eq(row.state, 'pending')
        assert_eq(tonumber(row.attempts), 1)
        assert_eq(tonumber(row.amount), Config.Traffic.Citations.Violations.reckless.amount)
        -- not due yet
        assert_eq(T.CitationSweep(Mock.clock), 0)
        justice.answer = nil
        assert_eq(T.CitationSweep(Mock.clock + 61), 1)
        row = MySQL.single.await('SELECT * FROM pf_police_citations WHERE id = ?', { row.id })
        assert_eq(row.state, 'issued')
        assert_true(tonumber(row.order_id) > 100)
        assert_eq(#justice.calls, 2)
        assert_eq(justice.calls[1].key, 'pfm-policejob:citation:' .. row.uid)
        assert_eq(justice.calls[2].key, justice.calls[1].key, 'the retry uses the same key')
        assert_eq(justice.calls[2].spec.officerSrc, COP, 'the officer is still on duty')
        assert_eq(T.CitationSweep(Mock.clock + 200), 0)
        -- a clear refusal ends it
        justice.answer = { ok = false, error = 'no_permission' }
        T.IssueCitation(COP, CIV, 'red_light')
        assert_eq(MySQL.single.await("SELECT state FROM pf_police_citations WHERE code = 'red_light'").state, 'failed')
    end)

    it('a radar reading is cited once', function()
        Mock.vehicleOf[COP] = CRUISER
        Mock.models[CRUISER] = GetHashKey('police')
        Mock.plates[CRUISER], Mock.coords[CRUISER] = 'LSPD1', vector3(0, 0, 0)
        Mock.plates[CAR], Mock.coords[CAR] = 'FAST1', vector3(0, 80, 0)
        speeds[CAR] = 40.0 -- 144 km/h
        Mock.vehicleOf[CIV] = CAR                     -- the citizen drives the measured car
        local reading = T.RadarMeasure(COP, CAR)
        assert_true(reading.ok and reading.eventId ~= nil)
        local r = T.IssueCitation(COP, CIV, 'speeding', reading.eventId)
        assert_true(r.ok)
        local ev = MySQL.single.await('SELECT * FROM pf_police_speed_events WHERE id = ?', { reading.eventId })
        assert_eq(tonumber(ev.citation_order_id), r.orderId)
        assert_eq(tonumber(ev.speed_kmh), 144)
        assert_eq(ev.driver_cid, 'CIVCID')
        assert_eq(T.IssueCitation(COP, CIV, 'speeding', reading.eventId).error, 'conflict')
        -- even without the link (a crash between the two writes) the unique reading blocks a second row
        MySQL.update.await('UPDATE pf_police_speed_events SET citation_order_id = NULL WHERE id = ?', { reading.eventId })
        assert_eq(T.IssueCitation(COP, CIV, 'speeding', reading.eventId).error, 'conflict')
        assert_eq(count('SELECT COUNT(*) FROM pf_police_citations WHERE speed_event_id = ?', { reading.eventId }), 1)
    end)

    it('a reading of a car nobody drove cites only its registered owner', function()
        Mock.vehicleOf[COP] = CRUISER
        Mock.models[CRUISER] = GetHashKey('police')
        Mock.plates[CRUISER], Mock.coords[CRUISER] = 'LSPD1', vector3(0, 0, 0)
        Mock.plates[CAR], Mock.coords[CAR] = 'OWNED9', vector3(0, 80, 0)
        speeds[CAR] = 40.0
        local reading = T.RadarMeasure(COP, CAR)
        assert_eq(MySQL.scalar.await('SELECT driver_cid FROM pf_police_speed_events WHERE id = ?', { reading.eventId }), nil)
        local other = Mock.newPlayer(4, 'OTHERCID')
        Mock.coords[4] = vector3(2, 1, 0)
        assert_eq(T.IssueCitation(COP, 4, 'speeding', reading.eventId).error, 'no_permission')
        car('OWNED9', 0)                              -- registered to CIVCID
        assert_eq(T.IssueCitation(COP, 4, 'speeding', reading.eventId).error, 'no_permission')
        assert_true(T.IssueCitation(COP, CIV, 'speeding', reading.eventId).ok)
    end)

    it('a speed camera cites the driving player with the uid of its speed event', function()
        local cam = Config.Traffic.SpeedCameras.List[1]
        vehicles = { CAR }
        Mock.plates[CAR], Mock.coords[CAR] = 'CAM1', cam.coords
        Mock.vehicleOf[CIV] = CAR
        speeds[CAR] = (cam.kmh + 30) / 3.6
        assert_eq(T.CameraTick(Mock.clock), 1)
        local ev = MySQL.single.await("SELECT * FROM pf_police_speed_events WHERE plate = 'CAM1'")
        assert_eq(ev.source, 'camera')
        local cit = MySQL.single.await("SELECT * FROM pf_police_citations WHERE plate = 'CAM1'")
        assert_eq(cit.uid, 'SE' .. ev.id)
        assert_eq(cit.state, 'issued')
        assert_eq(justice.calls[#justice.calls].actor.kind, 'system')
        assert_eq(T.CameraTick(Mock.clock + 5), 0, 'deduped')
        assert_eq(count("SELECT COUNT(*) FROM pf_police_alpr_reads WHERE plate = 'CAM1'"), 1)
    end)
end)

describe('reads, breath tests, incidents, plates', function()
    it('ALPR reads are written in one insert and swept after the retention', function()
        Mock.vehicleOf[COP] = CRUISER
        Mock.models[CRUISER] = GetHashKey('police')
        Mock.plates[CRUISER], Mock.coords[CRUISER] = 'LSPD1', vector3(0, 0, 0)
        vehicles = { CRUISER }
        for i = 1, 5 do
            vehicles[#vehicles + 1] = 600 + i
            Mock.plates[600 + i], Mock.coords[600 + i] = 'RD' .. i, vector3(i * 5, 0, 0)
        end
        assert_true(T.SetReader(COP, true))
        T.AlprTick(Mock.clock)
        assert_eq(count("SELECT COUNT(*) FROM pf_police_alpr_reads WHERE reader = 'unit:LSPD1'"), 5)
        MySQL.update.await("UPDATE pf_police_alpr_reads SET at = ? WHERE plate IN ('RD1', 'RD2')", { Mock.clock - 15 * 86400 })
        assert_eq(T.RetentionSweep(Mock.clock), 2)
        assert_eq(count("SELECT COUNT(*) FROM pf_police_alpr_reads WHERE reader = 'unit:LSPD1'"), 3)
    end)

    it('a breath test row; an incident and its listing by plate; RunPlate from the register', function()
        Mock.players[COP].PlayerData.items = { { name = 'breathalyzer', amount = 1 } }
        local b = T.Breathalyze(COP, CIV)
        assert_true(b.ok)
        assert_eq(tonumber(MySQL.scalar.await('SELECT bac FROM pf_police_breath_tests WHERE id = ?', { b.testId })), 0.091)

        vehicles = { CAR }
        Mock.plates[CAR], Mock.coords[CAR] = 'INC1', vector3(4, 0, 0)
        local inc = T.LogIncident(COP, { kind = 'collision', summary = 'Rear-ended at the lights', plates = { 'INC1' }, people = { CIV } })
        assert_true(inc.ok)
        local list = Mock.exportsByResource['__self'].ListTrafficIncidents({ plate = 'INC1' })
        assert_eq(#list.list, 1)
        assert_eq(list.list[1].people[1].cid, 'CIVCID')
        assert_eq(#Mock.exportsByResource['__self'].ListTrafficIncidents({ plate = 'OTHER' }).list, 0)

        MySQL.insert.await("INSERT INTO players (citizenid, license, name, money, charinfo, job, position, metadata) VALUES ('CIVCID', 'l', 'n', '{}', ?, '{}', '{}', ?)",
            { '{"firstname":"Cara","lastname":"Ivy"}', '{"licences":{"driver":false}}' })
        car('RUN1', 1)
        local r = T.RunPlate('run1')
        assert_true(r.ok)
        assert_eq(r.owner.citizenid, 'CIVCID')
        assert_eq(r.owner.name, 'Cara Ivy')
        assert_eq(r.owner.licence.driver, 'revoked')
        assert_eq(r.model, 'sultan')
        assert_true(r.flagsUnavailable, 'no MDT running: said so')
        assert_eq(T.RunPlate('NOBODY').owner, nil)
    end)

    it('character deletion removes breath tests and citations and anonymises impound records', function()
        MySQL.insert.await("INSERT INTO pf_police_impounds (plate, owner_cid, kind, reason, officer_cid, state, created_at) VALUES ('DEL1', 'GONECID', 'depot', 'x', 'COPCID', 'released', 1)")
        MySQL.insert.await("INSERT INTO pf_police_breath_tests (citizenid, officer_cid, bac, device, at) VALUES ('GONECID', 'COPCID', 0.010, 'breathalyzer', 1)")
        TriggerEvent('pfm-core:server:characterDeleted', 'GONECID')
        assert_eq(count("SELECT COUNT(*) FROM pf_police_breath_tests WHERE citizenid = 'GONECID'"), 0)
        assert_eq(count("SELECT COUNT(*) FROM pf_police_impounds WHERE owner_cid = 'GONECID'"), 0)
        assert_eq(count("SELECT COUNT(*) FROM pf_police_impounds WHERE plate = 'DEL1'"), 1)
    end)
end)
