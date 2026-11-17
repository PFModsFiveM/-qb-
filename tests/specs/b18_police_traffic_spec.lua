-- pfm-policejob traffic (batch 18B, server/traffic.lua + server/vehicle.lua), mocked:
--   * radar: the speed is the server's GetEntitySpeed of the vehicle named by net id, within range and
--     the beam cone of the police car's heading (rear antenna) or, on foot, the radar gun's; a speed
--     over the limit is logged as a speed event for the measuring officer;
--   * ALPR: vehicles are sorted into spatial buckets, a reader only checks its own and the next cells
--     (the work is counted); reads are deduped and written in one batched insert; a flagged plate
--     alerts the unit's officer only, a fixed reader alerts every on-duty police job; the MDT's
--     flags are cached and replaced by pf_mdt:server:plateFlagsChanged; the lookup budget per tick;
--   * an ALPR unit runs only in a police car with its officer inside and on duty;
--   * police:server:IsPlateFlagged answers on-duty officers only;
--   * breathalyzer: item, 2.5 m, BAC from pf-ambulancejob GetBreathAlcohol only; nothing is
--     recorded when the medical side cannot answer;
--   * citations: amount from the config, never the client; speeding only from the officer's own
--     fresh reading; pf-justice gets the key pfm-policejob:citation:<uid>;
--   * traffic incidents keep only vehicles and people the server sees near the officer;
--   * RunPlate: caller allowlist and an on-duty viewer.
load_resource('tests/lua/fivem_mocks.lua')
QBCore = QBCoreMock
Commands = {}
QBCoreMock.Commands.Add = function(name, _, _, _, fn) Commands[name] = fn end

local started = { ['pf-policemdt-DEV'] = true, ['pf-ambulancejob'] = true, ['pf-justice'] = true }
function GetResourceState(name) return started[name] and 'started' or 'missing' end
function GetCurrentResourceName() return 'pfm-policejob' end

-- world
local vehicles, speeds, headings, types, exists = {}, {}, {}, {}, {}
function GetAllVehicles() return vehicles end
function GetEntitySpeed(e) return speeds[e] or 0 end
function GetEntityHeading(e) return headings[e] or 0 end
function GetEntityType(e) return types[e] or 2 end
function DoesEntityExist(e) return exists[e] ~= false end

-- database: records statements; inserts get ids, singles answer from `singles`
local inserts, updates, singles, nextId = {}, {}, {}, 0
local function rec(list, q, p) list[#list + 1] = { q = q, p = p } end
MySQL = {
    insert = setmetatable({ await = function(q, p) rec(inserts, q, p); nextId = nextId + 1; return nextId end }, { __call = function(_, q, p) rec(inserts, q, p) end }),
    update = setmetatable({ await = function(q, p) rec(updates, q, p); return 1 end }, { __call = function(_, q, p) rec(updates, q, p) end }),
    single = setmetatable({ await = function(q, p) for frag, fn in pairs(singles) do if q:find(frag, 1, true) then return fn(p) end end return nil end }, { __call = function() end }),
    scalar = setmetatable({ await = function() return nil end }, { __call = function() end }),
    query = setmetatable({ await = function() return {} end }, { __call = function(_, q, p, cb) if type(cb) == 'function' then cb({}) end end }),
}
local function insertsInto(tbl)
    local out = {}
    for _, i in ipairs(inserts) do if i.q:find('INSERT INTO ' .. tbl, 1, true) then out[#out + 1] = i end end
    return out
end

-- other resources
local mdtFlags, lookups, activity = {}, 0, {}
Mock.exportsByResource['pf-policemdt-DEV'] = {
    GetPlateFlags = function(_, plate) lookups = lookups + 1 return mdtFlags[plate] or { flags = {}, boloIds = {} } end,
    RecordPlateActivity = function(_, plate, spec) activity[#activity + 1] = { plate = plate, spec = spec } return { ok = true } end,
}
local bac, bacCalls = 0.1234, 0
Mock.exportsByResource['pf-ambulancejob'] = {
    GetBreathAlcohol = function(_, who) bacCalls = bacCalls + 1 return { ok = true, bac = bac } end,
}
local justice, justiceAnswer = {}, nil
Mock.exportsByResource['pf-justice'] = {
    IssueCitation = function(_, spec, opts)
        justice[#justice + 1] = { spec = spec, opts = opts }
        return justiceAnswer or { ok = true, orderId = 70 + #justice, citationId = 7 }
    end,
}

Config = nil
load_resource('pfm-policejob/config.lua')
load_resource('pfm-policejob/config_traffic.lua')
Mock.exportsByResource['pfm-core'].RunMigrations = function() return true end
load_resource('pfm-policejob/server/schema.lua')
assert(PFPoliceSchema.Run())
load_resource('pfm-policejob/server/vehicle.lua')
load_resource('pfm-policejob/server/traffic.lua')
local T = PFTraffic
Config.Traffic.SpeedLimits.Zones = {}

local COP, CIV, SHERIFF, OFFCOP = 1, 2, 3, 4
local CRUISER, CAR = 900, 501

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords, Mock.plates, Mock.models, Mock.vehicleOf = {}, {}, {}, {}, {}
    Mock.gameTimer = Mock.gameTimer + 100000
    Mock.clock = Mock.clock + 3600
    vehicles, speeds, headings, types, exists = { CRUISER, CAR }, {}, {}, {}, {}
    inserts, updates, singles = {}, {}, {}
    mdtFlags, lookups, activity, justice, justiceAnswer = {}, 0, {}, {}, nil
    bac, bacCalls = 0.1234, 0
    T.Readers, T.FlagCache, T.Seen, T.Alerted, T.CamSeen, T.ReadQueue, T.Rate = {}, {}, {}, {}, {}, {}, {}
    T.FieldFlags = PFTraffic.FieldFlags
    for k in pairs(T.FieldFlags) do T.FieldFlags[k] = nil end
    T.Stats.checks = 0
    Config.Traffic.Alpr.FixedReaders = {}
    started['pf-ambulancejob'] = true
    local cop = Mock.newPlayer(COP, 'COPCID')
    cop.PlayerData.job = { name = 'police', type = 'leo', onduty = true, grade = { level = 1 } }
    local sh = Mock.newPlayer(SHERIFF, 'SHERIFFCID')
    sh.PlayerData.job = { name = 'bcso', type = 'leo', onduty = true, grade = { level = 0 } }
    local off = Mock.newPlayer(OFFCOP, 'OFFCID')
    off.PlayerData.job = { name = 'police', type = 'leo', onduty = false, grade = { level = 0 } }
    Mock.newPlayer(CIV, 'CIVCID')
    -- the officer sits in a police cruiser at the origin facing north (+y)
    Mock.models[CRUISER] = GetHashKey('police')
    Mock.plates[CRUISER] = 'LSPD 001'
    Mock.coords[CRUISER] = vector3(0, 0, 0)
    Mock.vehicleOf[COP] = CRUISER
    Mock.coords[COP] = vector3(0, 0, 0)
    Mock.models[CAR] = GetHashKey('sultan')
    Mock.plates[CAR] = ' ABC123 '
    Mock.coords[CAR] = vector3(0, 100, 0)
    speeds[CAR] = 30.0 -- 108 km/h
end

describe('radar', function()
    it('reads the speed from the server native, whatever else the client sends', function()
        Mock.fireNet('police:server:RadarMeasure', COP, CAR, 999)
        local r = Mock.clientEventsNamed('police:client:RadarReading')
        assert_eq(#r, 1)
        assert_eq(r[1].target, COP)
        assert_eq(r[1].args[1].speed, 108)
        assert_eq(r[1].args[1].limit, 80)
        assert_eq(r[1].args[1].plate, 'ABC123')
        assert_eq(r[1].args[1].device, 'vehicle')
        local ev = insertsInto('pf_police_speed_events')
        assert_eq(#ev, 1)
        assert_eq(ev[1].p[2], 'radar')
        assert_eq(ev[1].p[3], 'COPCID')
        assert_eq(ev[1].p[4], 108)
        assert_eq(r[1].args[1].eventId, nextId)
    end)
    it('only inside the beam: ahead, or behind with the rear antenna; not to the side, not beyond range', function()
        Mock.coords[CAR] = vector3(100, 0, 0)          -- east of a north-facing car
        assert_false(T.RadarMeasure(COP, CAR).ok)
        Mock.coords[CAR] = vector3(0, -100, 0)         -- behind
        assert_true(T.RadarMeasure(COP, CAR).ok)
        Config.Traffic.Radar.RearAntenna = false
        assert_false(T.RadarMeasure(COP, CAR).ok)
        Config.Traffic.Radar.RearAntenna = true
        Mock.coords[CAR] = vector3(0, 200, 0)          -- beyond 150 m
        assert_eq(T.RadarMeasure(COP, CAR).error, 'too_far')
        Mock.coords[CAR] = vector3(5, 100, 0)          -- inside the 12 degree cone
        assert_true(T.RadarMeasure(COP, CAR).ok)
    end)
    it('under the limit: a reading but no speed event', function()
        speeds[CAR] = 10.0
        local r = T.RadarMeasure(COP, CAR)
        assert_true(r.ok)
        assert_eq(r.eventId, nil)
        assert_eq(#insertsInto('pf_police_speed_events'), 0)
    end)
    it('on foot the radar gun item is needed and the cone follows the officer', function()
        Mock.vehicleOf[COP] = nil
        assert_eq(T.RadarMeasure(COP, CAR).error, 'no_permission')
        Mock.players[COP].PlayerData.items = { { name = 'radar_gun', amount = 1, slot = 1 } }
        local r = T.RadarMeasure(COP, CAR)
        assert_true(r.ok)
        assert_eq(r.device, 'handheld')
    end)
    it('civilians and off-duty officers get nothing; a bad net id is refused', function()
        Mock.vehicleOf[CIV] = CRUISER
        Mock.fireNet('police:server:RadarMeasure', CIV, CAR)
        Mock.fireNet('police:server:RadarMeasure', OFFCOP, CAR)
        assert_eq(#Mock.clientEventsNamed('police:client:RadarReading'), 0)
        assert_eq(T.RadarMeasure(COP, 'x').error, 'bad_args')
        types[CAR] = 1
        assert_eq(T.RadarMeasure(COP, CAR).error, 'not_found')
    end)
    it('is rate limited to two measurements a second', function()
        Mock.fireNet('police:server:RadarMeasure', COP, CAR)
        Mock.fireNet('police:server:RadarMeasure', COP, CAR)
        assert_eq(#Mock.clientEventsNamed('police:client:RadarReading'), 1)
    end)
end)

describe('ALPR', function()
    local function scatter(n, spacing)
        local side = math.ceil(math.sqrt(n))
        for i = 0, n - 1 do
            local v = 2000 + i
            vehicles[#vehicles + 1] = v
            Mock.plates[v] = ('P%05d'):format(i)
            Mock.coords[v] = vector3((i % side) * spacing - 1000, math.floor(i / side) * spacing - 1000, 0)
        end
    end

    it('a reader checks only the vehicles in its own and the neighbouring buckets', function()
        scatter(400, 100)                               -- 400 cars over 2 km x 2 km
        assert_true(T.SetReader(COP, true))
        T.AlprTick(Mock.clock)
        -- a scan of every vehicle would be 402 distance checks; the buckets around the reader hold a handful
        assert_true(T.Stats.checks < 30, 'checks: ' .. T.Stats.checks)
        local reads = insertsInto('pf_police_alpr_reads')
        assert_eq(#reads, 1, 'one batched insert')
        -- ABC123 at 100 m is out of the 60 m range; the one car within 60 m of the origin is read
        local plates = {}
        for i = 1, #reads[1].p, 7 do plates[#plates + 1] = reads[1].p[i] end
        assert_eq(#plates, 1)
        assert_eq(plates[1], 'P00210')
        assert_eq(reads[1].p[2], 'unit:LSPD 001')
    end)
    it('a flagged plate alerts the unit\'s officer only; the next tick does not read it again', function()
        Mock.coords[CAR] = vector3(0, 30, 0)
        mdtFlags['ABC123'] = { flags = { 'STOLEN' }, boloIds = { 4 } }
        T.SetReader(COP, true)
        assert_eq(T.AlprTick(Mock.clock), 1)
        local hits = Mock.clientEventsNamed('police:client:AlprHit')
        assert_eq(#hits, 1)
        assert_eq(hits[1].target, COP)
        assert_eq(hits[1].args[1].flags[1], 'STOLEN')
        assert_eq(#Mock.clientEventsNamed('police:client:policeAlert'), 0)
        assert_eq(insertsInto('pf_police_alpr_reads')[1].p[6], 'STOLEN')
        assert_eq(activity[1].spec.type, 'alpr_hit')
        assert_eq(T.AlprTick(Mock.clock + 5), 0)
        assert_eq(#Mock.clientEventsNamed('police:client:AlprHit'), 1)
        assert_eq(lookups, 1, 'cached')
    end)
    it('a fixed reader alerts every on-duty police job, never off-duty officers or civilians', function()
        Config.Traffic.Alpr.FixedReaders = { { coords = vector3(500, 500, 0), label = 'Test reader' } }
        Mock.coords[CAR] = vector3(510, 500, 0)
        mdtFlags['ABC123'] = { flags = { 'BOLO' }, boloIds = { 9 } }
        assert_eq(T.AlprTick(Mock.clock), 1)
        local alerts = Mock.clientEventsNamed('police:client:policeAlert')
        local to = {}
        for _, a in ipairs(alerts) do to[a.target] = true end
        assert_true(to[COP] and to[SHERIFF], 'police and sheriff')
        assert_false(to[OFFCOP] or to[CIV])
        -- the legacy client report of the same car at a radar adds nothing within the window
        assert_true(T.FixedAlertSeen('fixed:1', 'ABC123'))
    end)
    it('the MDT flag change replaces the cached answer at once', function()
        Mock.coords[CAR] = vector3(0, 30, 0)
        T.SetReader(COP, true)
        assert_eq(T.AlprTick(Mock.clock), 0)
        TriggerEvent('pf_mdt:server:plateFlagsChanged', 'ABC123', { flags = { 'STOLEN' }, boloIds = {} })
        T.Seen = {}
        assert_eq(T.AlprTick(Mock.clock + 1), 1)
        assert_eq(lookups, 1, 'no new lookup: the event filled the cache')
    end)
    it('cache misses beyond the lookup budget wait for the next tick', function()
        Config.Traffic.Alpr.MaxLookupsPerTick = 2
        for i = 1, 5 do
            local v = 3000 + i
            vehicles[#vehicles + 1] = v
            Mock.plates[v] = 'BUD' .. i
            Mock.coords[v] = vector3(i, 10, 0)
        end
        T.SetReader(COP, true)
        T.AlprTick(Mock.clock)
        assert_eq(lookups, 2)
        T.AlprTick(Mock.clock + 1)
        assert_eq(lookups, 4)
        Config.Traffic.Alpr.MaxLookupsPerTick = 25
    end)
    it('a field flag from /flagplate is merged in', function()
        Commands.flagplate(COP, { 'abc123', 'seen', 'speeding' })
        local f = T.FlagsFor('ABC123')
        assert_eq(f.flags[#f.flags], 'FIELD')
        assert_eq(f.field, 'seen speeding')
    end)
    it('a unit runs only in a police car with its officer inside and on duty', function()
        Mock.vehicleOf[COP] = CAR
        assert_false(T.SetReader(COP, true))
        Mock.vehicleOf[COP] = CRUISER
        Mock.fireNet('police:server:AlprToggle', CIV, true)
        assert_eq(T.Readers[CIV], nil)
        Mock.fireNet('police:server:AlprToggle', COP, true)
        assert_true(T.Readers[COP] ~= nil)
        Mock.vehicleOf[COP] = nil                       -- the officer got out
        T.AlprTick(Mock.clock)
        assert_eq(T.Readers[COP], nil)
        local st = Mock.clientEventsNamed('police:client:AlprState')
        assert_eq(st[#st].args[1], false)
    end)
end)

describe('plate flag callback', function()
    it('answers on-duty officers only', function()
        mdtFlags['ABC123'] = { flags = { 'STOLEN' }, boloIds = {} }
        assert_eq(Mock.callCallback('police:server:IsPlateFlagged', CIV, 'ABC123'), false)
        assert_eq(Mock.callCallback('police:server:IsPlateFlagged', OFFCOP, 'ABC123'), false)
        assert_eq(Mock.callCallback('police:server:IsPlateFlagged', COP, 'ABC123'), true)
    end)
end)

describe('breathalyzer', function()
    local function setup()
        Mock.players[COP].PlayerData.items = { { name = 'breathalyzer', amount = 1, slot = 1 } }
        Mock.coords[CIV] = vector3(1, 1, 0)
    end
    it('BAC comes from pf-ambulancejob and is recorded', function()
        setup()
        local r = T.Breathalyze(COP, CIV)
        assert_true(r.ok)
        assert_eq(r.bac, 0.123)
        assert_true(r.over)
        local row = insertsInto('pf_police_breath_tests')[1]
        assert_eq(row.p[1], 'CIVCID')
        assert_eq(row.p[2], 'COPCID')
        assert_eq(row.p[3], 0.123)
    end)
    it('needs the item, the touch distance and an on-duty officer', function()
        Mock.coords[CIV] = vector3(1, 1, 0)
        assert_eq(T.Breathalyze(COP, CIV).error, 'no_permission')
        setup()
        Mock.coords[CIV] = vector3(3, 0, 0)
        assert_eq(T.Breathalyze(COP, CIV).error, 'too_far')
        Mock.coords[CIV] = vector3(1, 1, 0)
        assert_eq(T.Breathalyze(CIV, COP).error, 'no_permission')
        assert_eq(bacCalls, 0)
    end)
    it('without the medical side nothing is invented or recorded', function()
        setup()
        started['pf-ambulancejob'] = nil
        assert_eq(T.Breathalyze(COP, CIV).error, 'db_unavailable')
        assert_eq(#insertsInto('pf_police_breath_tests'), 0)
    end)
end)

describe('citations', function()
    it('the amount comes from the config and pf-justice gets the citation key', function()
        Mock.coords[CIV] = vector3(2, 0, 0)
        Mock.fireNet('police:server:IssueCitation', COP, CIV, 'reckless', 1, 999999)
        assert_eq(#justice, 1)
        assert_eq(justice[1].spec.amount, Config.Traffic.Citations.Violations.reckless.amount)
        assert_eq(justice[1].spec.cid, 'CIVCID')
        assert_eq(justice[1].spec.officerSrc, COP)
        local row = insertsInto('pf_police_citations')[1]
        assert_eq(justice[1].opts.key, 'pfm-policejob:citation:' .. row.p[1])
    end)
    it('speeding only from the officer\'s own fresh radar reading, cited once', function()
        Mock.coords[CIV] = vector3(2, 0, 0)
        local ev = { id = 5, plate = 'ABC123', officer_cid = 'OTHER', speed_kmh = 120, limit_kmh = 80, at = Mock.clock, driver_cid = 'CIVCID' }
        singles['FROM pf_police_speed_events'] = function() return ev end
        assert_eq(T.IssueCitation(COP, CIV, 'speeding', 5).error, 'no_permission')
        ev.officer_cid = 'COPCID'
        ev.at = Mock.clock - 3600
        assert_eq(T.IssueCitation(COP, CIV, 'speeding', 5).error, 'invalid_state')
        ev.at = Mock.clock
        assert_eq(T.IssueCitation(COP, CIV, 'speeding', nil).error, 'bad_args')
        local r = T.IssueCitation(COP, CIV, 'speeding', 5)
        assert_true(r.ok)
        local s = Config.Traffic.Citations.Speeding
        assert_eq(justice[1].spec.amount, s.Base + 40 * s.PerKmh)
        assert_eq(justice[1].spec.speed, 120)
        assert_eq(justice[1].spec.plate, 'ABC123')
        ev.citation_order_id = 71
        assert_eq(T.IssueCitation(COP, CIV, 'speeding', 5).error, 'conflict')
    end)
    it('a speeding reading is tied to its vehicle: only its driver at the reading or its owner', function()
        Mock.coords[CIV] = vector3(2, 0, 0)
        -- an NPC car was measured (no player driving): a player standing nearby cannot be cited for it
        local ev = { id = 6, plate = 'NPC1', officer_cid = 'COPCID', speed_kmh = 130, limit_kmh = 80, at = Mock.clock, driver_cid = nil }
        singles['FROM pf_police_speed_events'] = function() return ev end
        local owner
        MySQL.scalar.await = function(q) if q:find('FROM player_vehicles', 1, true) then return owner end end
        assert_eq(T.IssueCitation(COP, CIV, 'speeding', 6).error, 'no_permission')
        ev.driver_cid = 'SOMEONE'
        assert_eq(T.IssueCitation(COP, CIV, 'speeding', 6).error, 'no_permission')
        assert_eq(#justice, 0)
        -- the registered owner of the plate may be cited
        owner = 'CIVCID'
        assert_true(T.IssueCitation(COP, CIV, 'speeding', 6).ok)
        MySQL.scalar.await = function() return nil end
    end)
    it('the radar stores the driver the server sees in the measured vehicle', function()
        Mock.vehicleOf[CIV] = CAR
        assert_true(T.RadarMeasure(COP, CAR).ok)
        assert_eq(insertsInto('pf_police_speed_events')[1].p[9], 'CIVCID')
        Mock.vehicleOf[CIV] = nil
        assert_true(T.RadarMeasure(COP, CAR).ok)
        assert_eq(insertsInto('pf_police_speed_events')[2].p[9], nil)
    end)
    it('too far, unknown codes and civilians are refused', function()
        Mock.coords[CIV] = vector3(20, 0, 0)
        assert_eq(T.IssueCitation(COP, CIV, 'reckless').error, 'too_far')
        Mock.coords[CIV] = vector3(2, 0, 0)
        assert_eq(T.IssueCitation(COP, CIV, 'murder').error, 'bad_args')
        assert_eq(T.IssueCitation(CIV, COP, 'reckless').error, 'no_permission')
        assert_eq(#justice, 0)
    end)
    it('pf-justice not answering leaves the citation pending for a retry', function()
        Mock.coords[CIV] = vector3(2, 0, 0)
        justiceAnswer = { ok = false, error = 'db_unavailable' }
        local r = T.IssueCitation(COP, CIV, 'reckless')
        assert_true(r.pending)
        local retry
        for _, u in ipairs(updates) do if u.q:find('attempts = attempts + 1, next_at', 1, true) then retry = u end end
        assert_true(retry ~= nil)
    end)
end)

describe('traffic incidents', function()
    it('keeps only the vehicles and people the server sees near the officer', function()
        Mock.coords[CAR] = vector3(10, 0, 0)
        Mock.coords[CIV] = vector3(5, 0, 0)
        Mock.coords[SHERIFF] = vector3(500, 0, 0)
        local r = T.LogIncident(COP, { kind = 'stop', summary = 'Stopped for speed\n', plates = { 'abc123', 'NOPE1', CAR }, people = { CIV, SHERIFF, 99 } })
        assert_true(r.ok)
        assert_eq(#r.plates, 1)
        assert_eq(r.plates[1], 'ABC123')
        assert_eq(#r.people, 1)
        assert_eq(r.people[1].cid, 'CIVCID')
        local row = insertsInto('pf_police_traffic_incidents')[1]
        assert_eq(row.p[1], 'stop')
        assert_eq(row.p[6], 'COPCID')
        assert_eq(row.p[7], 'Stopped for speed')
        assert_eq(activity[1].spec.type, 'traffic_stop')
        assert_eq(T.LogIncident(COP, { kind = 'party' }).error, 'bad_args')
        assert_eq(T.LogIncident(CIV, { kind = 'stop' }).error, 'no_permission')
    end)
end)

describe('RunPlate', function()
    it('only listed resources and on-duty viewers', function()
        local run = Mock.selfExport('RunPlate')
        Mock.invokingResource = 'some-resource'
        assert_eq(run('ABC123').error, 'not_allowed')
        Mock.invokingResource = 'pf-policemdt-DEV'
        assert_eq(run('ABC123', { viewer = CIV }).error, 'no_permission')
        singles['FROM player_vehicles pv'] = function() return { citizenid = 'OWNER1', vehicle = 'sultan', state = 0, charinfo = '{"firstname":"Ann","lastname":"Lee"}', metadata = '{"licences":{"driver":true}}' } end
        mdtFlags['ABC123'] = { flags = { 'STOLEN' }, boloIds = { 3 } }
        local r = run('ABC123', { viewer = COP })
        Mock.invokingResource = nil
        assert_true(r.ok)
        assert_eq(r.owner.name, 'Ann Lee')
        assert_eq(r.owner.licence.driver, 'valid')
        assert_eq(r.flags[1], 'STOLEN')
        assert_eq(r.bolos[1], 3)
        assert_eq(r.registration, 'unknown')
        assert_eq(run('this plate is far too long').error, 'bad_args')
    end)
end)

describe('speed cameras', function()
    it('a speeding player driver is cited by the system; an on-duty officer is logged, not cited', function()
        local cam = Config.Traffic.SpeedCameras.List[1]
        vehicles = { CAR }
        Mock.coords[CAR] = cam.coords
        speeds[CAR] = (cam.kmh + 40) / 3.6
        Mock.vehicleOf[COP] = nil
        Mock.vehicleOf[CIV] = CAR
        assert_eq(T.CameraTick(Mock.clock), 1)
        assert_eq(#justice, 1)
        assert_eq(justice[1].opts.actor.kind, 'system')
        assert_eq(justice[1].spec.officerSrc, nil)
        local ev = insertsInto('pf_police_speed_events')[1]
        assert_eq(ev.p[2], 'camera')
        local cit = insertsInto('pf_police_citations')[1]
        assert_eq(cit.p[1], 'SE' .. tostring(cit.p[8]), 'uid from the speed event id')
        assert_eq(justice[1].opts.key, 'pfm-policejob:citation:' .. cit.p[1])
        assert_eq(T.CameraTick(Mock.clock + 1), 0, 'one event per camera and plate in the window')
        -- an on-duty officer driving the car
        T.CamSeen = {}
        Mock.vehicleOf[CIV] = nil
        Mock.vehicleOf[COP] = CAR
        assert_eq(T.CameraTick(Mock.clock + 2), 1)
        assert_eq(#justice, 1, 'not cited')
        -- under limit + tolerance: nothing
        T.CamSeen = {}
        speeds[CAR] = (cam.kmh + Config.Traffic.SpeedCameras.ToleranceKmh) / 3.6
        assert_eq(T.CameraTick(Mock.clock + 3), 0)
    end)
end)

describe('impound release', function()
    it('fails closed when the impound record cannot be read; no record row at all still releases', function()
        local LOT = Config.Locations['impound'][1]
        Mock.coords[COP] = LOT
        function CreateVehicleServerSetter() return 700 end
        function SetVehicleNumberPlateText() end
        local carRow = { vehicle = 'adder', mods = '{}' }
        singles['FROM player_vehicles WHERE plate = ? AND state = ?'] = function() return carRow end
        -- the impound record query raises (database error)
        singles['FROM pf_police_impounds'] = function() error('db down') end
        assert_eq(Mock.callCallback('police:server:ReleaseImpound', COP, 'HELD1', 1), nil)
        local n = 0
        for _, u in ipairs(updates) do if u.q:find('UPDATE player_vehicles', 1, true) then n = n + 1 end end
        assert_eq(n, 0, 'the car stays impounded')
        -- the schema is not ready: same
        singles['FROM pf_police_impounds'] = function() return nil end
        PFPoliceSchema.state = 'failed'
        assert_eq(Mock.callCallback('police:server:ReleaseImpound', COP, 'HELD1', 1), nil)
        PFPoliceSchema.state = 'ready'
        -- readable and no row (a legacy impound): released as before
        assert_eq(Mock.callCallback('police:server:ReleaseImpound', COP, 'HELD1', 1), 700)
    end)
end)
