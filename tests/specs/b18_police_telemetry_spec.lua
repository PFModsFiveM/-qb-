-- pfm-policejob officer telemetry (batch 18, unit 18C): the "bodycam/dashcam" is a server metadata
-- timeline, never video.
--   * body recording is toggled by the `bodycam` item (on-duty LEO who carries it); dash recording
--     runs while the officer sits in a police rig; losing the camera or going off duty stops it;
--   * samples come from server natives only (position, weapon in hand, vehicle, pma-voice radio);
--   * rows are buffered (bounded) and written in batched multi-row inserts; a failed insert keeps them;
--   * MarkTimeline writes only for recording officers (anomaly always), allowlisted callers only;
--   * GetTimeline: own timeline, supervisors, courts only with a valid order (fails closed without
--     pf-justice), bounded window, cursor paging;
--   * the retention sweep keeps rows covered by a hold.
load_resource('tests/lua/fivem_mocks.lua')
QBCore = QBCoreMock
Commands = {}
QBCoreMock.Commands.Add = function(name, _, _, _, fn) Commands[name] = fn end

local weapons, heading = {}, {}
function GetSelectedPedWeapon(ped) return weapons[ped] or 0 end
function GetEntityHeading(ped) return heading[ped] or 0.0 end
Mock.models, Mock.vehicleOf, Mock.plates = {}, {}, {}
local held = {}
local resources = {}
function GetResourceState(name) return resources[name] or 'missing' end
Mock.exportsByResource['pfm-inventory'] = {
    HasItem = function(_, src, item) return held[src] ~= nil and held[src][item] == true end,
}
local courtValid = false
Mock.exportsByResource['pf-justice'] = {
    IsCourtOrderValid = function(_, ref, purpose, cid) return courtValid and purpose == 'telemetry' and ref == 'CO-1' and cid == 'COPCID' end,
}
QBCoreMock.Shared.Weapons[GetHashKey('weapon_pistol')] = { name = 'weapon_pistol', label = 'Pistol', ammotype = 'AMMO_PISTOL' }

-- the schema module (unit 18B) owns the tables; here it is ready
PFPoliceSchema = { Ready = function() return true end }

-- MySQL that records statements; query.await may be told to fail or to return rows
local failNext, nextRows = false, nil
local function record(kind)
    local fn = function(query, params)
        Mock.dbCalls[#Mock.dbCalls + 1] = { kind = kind, query = query, params = params }
        if failNext then failNext = false error('db down') end
        if nextRows and kind == 'query' and query:find('^%s*SELECT') then local r = nextRows nextRows = nil return r end
        return {}
    end
    return setmetatable({ await = fn }, { __call = function(_, q, p) return fn(q, p) end })
end
MySQL = { query = record('query'), insert = record('insert'), scalar = record('scalar'), update = record('update'), single = record('single'), prepare = record('prepare') }

Config = nil
load_resource('pfm-policejob/config.lua')
load_resource('pfm-policejob/config_equipment.lua')
load_resource('pfm-policejob/server/main.lua')
load_resource('pfm-policejob/server/telemetry.lua')

local T = PFTelemetry
local COP, SGT, CIV, COP2 = 1, 2, 3, 4
local RIG = 900

local function rows(kind)
    local out = {}
    for _, r in ipairs(T.buffer) do if not kind or r.kind == kind then out[#out + 1] = r end end
    return out
end
local function inserts()
    local out = {}
    for _, c in ipairs(Mock.dbCalls) do if c.query:find('INSERT INTO pf_police_telemetry ', 1, true) then out[#out + 1] = c end end
    return out
end

BeforeEach = function()
    for src in pairs(T.recording) do T.recording[src] = nil end
    for i = #T.buffer, 1, -1 do T.buffer[i] = nil end
    T.dropped = 0
    Mock.reset()
    Mock.players, Mock.coords, Mock.models, Mock.vehicleOf, Mock.plates = {}, {}, {}, {}, {}
    weapons, held, resources, courtValid, failNext, nextRows = {}, {}, {}, false, false, nil
    Mock.invokingResource = nil
    Mock.clock = Mock.clock + 100000
    Mock.gameTimer = Mock.gameTimer + 100000
    Config.Equipment.Telemetry.MaxBuffer = 5000
    for _, src in ipairs({ COP, SGT, COP2 }) do
        local p = Mock.newPlayer(src, src == COP and 'COPCID' or (src == SGT and 'SGTCID' or 'COP2CID'))
        p.PlayerData.job = { name = 'police', type = 'leo', onduty = true, grade = { level = src == SGT and 3 or 0 } }
    end
    Mock.newPlayer(CIV, 'CIVCID')
    Mock.coords[COP] = vector3(100, 100, 30)
    Mock.coords[SGT] = vector3(200, 200, 30)
    Mock.coords[COP2] = vector3(300, 300, 30)
    Mock.coords[CIV] = vector3(101, 100, 30)
    for _, src in ipairs({ COP, SGT, CIV, COP2 }) do Player(src).state.radioChannel = 0 end
end

describe('recording devices', function()
    it('the bodycam item turns body recording on and off for an on-duty officer who carries it', function()
        held[COP] = { bodycam = true }
        Mock.useables.bodycam(COP)
        assert_eq(T.DeviceOf(COP), 'body')
        local started = rows('note')
        assert_eq(#started, 1)
        assert_eq(json.decode(started[1].data).event, 'recording_started')
        Mock.useables.bodycam(COP)
        assert_eq(T.DeviceOf(COP), nil)
    end)
    it('a civilian, an off-duty officer or an officer without the camera cannot record', function()
        held[CIV] = { bodycam = true }
        Mock.useables.bodycam(CIV)
        assert_eq(T.DeviceOf(CIV), nil)
        Mock.useables.bodycam(COP2)                  -- no camera
        assert_eq(T.DeviceOf(COP2), nil)
        held[SGT] = { bodycam = true }
        Mock.players[SGT].PlayerData.job.onduty = false
        Mock.useables.bodycam(SGT)
        assert_eq(T.DeviceOf(SGT), nil)
        assert_eq(#T.buffer, 0)
    end)
    it('sitting in a police rig records as a dashcam without a bodycam', function()
        Mock.models[RIG] = GetHashKey(Config.PoliceHelicopter)
        Mock.vehicleOf[COP] = RIG
        Mock.plates[RIG] = 'LSPD 01'
        T.Tick()
        assert_eq(T.DeviceOf(COP), 'dash')
        assert_eq(#rows('pos'), 1)
        assert_eq(rows('pos')[1].device, 'dash')
        local state = Mock.clientEventsNamed('police:client:TelemetryState')
        assert_eq(state[#state].target, COP)
        assert_eq(state[#state].args[1], 'dash')
        Mock.vehicleOf[COP] = nil                     -- stepped out: no rig, no bodycam
        T.Tick()
        assert_eq(T.DeviceOf(COP), nil)
    end)
    it('a civilian in a rig model records nothing', function()
        Mock.models[RIG] = GetHashKey(Config.PoliceHelicopter)
        Mock.vehicleOf[CIV] = RIG
        T.Tick()
        assert_eq(T.DeviceOf(CIV), nil)
        assert_eq(#T.buffer, 0)
    end)
    it('stops when the camera leaves the inventory, and when the officer goes off duty', function()
        held[COP] = { bodycam = true }
        Mock.useables.bodycam(COP)
        held[COP] = {}
        T.Tick()
        assert_eq(T.DeviceOf(COP), nil)
        held[SGT] = { bodycam = true }
        Mock.useables.bodycam(SGT)
        Mock.players[SGT].PlayerData.job.onduty = false
        T.Tick()
        assert_eq(T.DeviceOf(SGT), nil)
    end)
end)

describe('samples come from server natives', function()
    it('position on movement or after PosEverySeconds; weapon out/in; vehicle in/out; radio', function()
        held[COP] = { bodycam = true }
        Mock.useables.bodycam(COP)
        T.Tick()
        assert_eq(#rows('pos'), 1)
        T.Tick()                                      -- did not move, too soon
        assert_eq(#rows('pos'), 1)
        Mock.coords[COP] = vector3(110, 100, 30)
        T.Tick()
        assert_eq(#rows('pos'), 2)
        assert_near(rows('pos')[2].x, 110, 0.01)
        Mock.clock = Mock.clock + Config.Equipment.Telemetry.PosEverySeconds
        T.Tick()
        assert_eq(#rows('pos'), 3)

        weapons[COP] = GetHashKey('weapon_pistol')
        T.Tick()
        local out = rows('weapon_out')
        assert_eq(#out, 1)
        assert_eq(json.decode(out[1].data).weapon, 'weapon_pistol')
        weapons[COP] = 0xA2719263
        T.Tick()
        assert_eq(#rows('weapon_in'), 1)

        Mock.models[77] = 12345
        Mock.vehicleOf[COP] = 77
        Mock.plates[77] = 'ABC 123'
        T.Tick()
        assert_eq(json.decode(rows('vehicle_in')[1].data).plate, 'ABC 123')
        Mock.vehicleOf[COP] = nil
        T.Tick()
        assert_eq(#rows('vehicle_out'), 1)

        Player(COP).state.radioChannel = 3
        T.Tick()
        assert_eq(json.decode(rows('radio')[1].data).channel, 3)
    end)
    it('nothing is broadcast to every client', function()
        held[COP] = { bodycam = true }
        Mock.useables.bodycam(COP)
        T.Tick()
        for _, e in ipairs(Mock.clientEvents) do assert_true(e.target ~= -1, e.name .. ' went to -1') end
    end)
end)

describe('batched, bounded writes', function()
    it('one multi-row INSERT per InsertBatch rows; the buffer empties', function()
        local per = Config.Equipment.Telemetry.InsertBatch
        for i = 1, per + 5 do T.Push({ cid = 'COPCID', device = 'body', kind = 'pos', x = i, y = 0, z = 0, clientReported = 0, at = i }) end
        assert_eq(T.Flush(), per + 5)
        local ins = inserts()
        assert_eq(#ins, 2)
        assert_eq(#ins[1].params, per * 8)            -- data is NULL in the SQL, never a hole in the list
        assert_eq(#ins[2].params, 5 * 8)
        assert_true(ins[2].query:find('NULL', 1, true) ~= nil)
        assert_eq(#T.buffer, 0)
    end)
    it('a failed insert keeps the rows for the next flush', function()
        T.Push({ cid = 'COPCID', device = 'body', kind = 'note', clientReported = 0, at = 1 })
        failNext = true
        assert_eq(T.Flush(), 0)
        assert_eq(#T.buffer, 1)
        assert_eq(T.Flush(), 1)
    end)
    it('nothing is written before the schema is ready', function()
        local ready = PFPoliceSchema.Ready
        PFPoliceSchema.Ready = function() return false end
        T.Push({ cid = 'COPCID', device = 'body', kind = 'note', clientReported = 0, at = 1 })
        assert_eq(T.Flush(), 0)
        PFPoliceSchema.Ready = ready
        assert_eq(#inserts(), 0)
    end)
    it('a full buffer drops the oldest position sample first', function()
        Config.Equipment.Telemetry.MaxBuffer = 3
        T.Push({ kind = 'note', at = 1 })
        T.Push({ kind = 'pos', at = 2 })
        T.Push({ kind = 'cuff', at = 3 })
        T.Push({ kind = 'frisk', at = 4 })
        assert_eq(#T.buffer, 3)
        assert_eq(T.dropped, 1)
        assert_eq(T.buffer[1].kind, 'note')
        assert_eq(T.buffer[2].kind, 'cuff')
    end)
end)

describe('MarkTimeline', function()
    local mark = function(...) return Mock.selfExport('MarkTimeline')(...) end
    it('is written only while the officer records, at the server position', function()
        local r = mark(COP, 'cuff', { subject = 'CIVCID' })
        assert_true(r.ok)
        assert_false(r.recorded)
        assert_eq(#T.buffer, 0)
        held[COP] = { bodycam = true }
        Mock.useables.bodycam(COP)
        r = mark('COPCID', 'cuff', { subject = 'CIVCID', x = 9999 })
        assert_true(r.recorded)
        local row = rows('cuff')[1]
        assert_near(row.x, 100, 0.01)
        assert_eq(json.decode(row.data).subject, 'CIVCID')
    end)
    it('anomaly rows are always kept', function()
        local r = mark(COP2, 'anomaly', { what = 'speed' })
        assert_true(r.recorded)
        assert_eq(rows('anomaly')[1].device, 'srv')
    end)
    it('refuses unknown kinds and officers', function()
        assert_eq(mark(COP, 'teleport', {}).error, 'bad_args')
        assert_eq(mark({ 1 }, 'cuff', {}).error, 'bad_args')
    end)
    it('only allowlisted resources may call it', function()
        Mock.invokingResource = 'some-resource'
        assert_eq(mark(COP, 'note', {}).error, 'not_allowed')
        Mock.invokingResource = 'pf-justice'
        assert_true(mark(COP, 'note', {}).ok)
    end)
    it('data stays short: scalars only, never more than DataMaxChars', function()
        held[COP] = { bodycam = true }
        Mock.useables.bodycam(COP)
        local big = {}
        for i = 1, 30 do big['k' .. i] = string.rep('x', 200) end
        big.nested = { a = 1 }
        mark(COP, 'note', big)
        local data = rows('note')[#rows('note')].data
        assert_true(#data <= Config.Equipment.Telemetry.DataMaxChars)
        assert_eq(json.decode(data).nested, nil)
    end)
    it('is rate limited per officer', function()
        held[COP] = { bodycam = true }
        Mock.useables.bodycam(COP)
        local limited = 0
        for _ = 1, 40 do if mark(COP, 'note', {}).error == 'rate_limited' then limited = limited + 1 end end
        assert_true(limited > 0)
    end)
end)

describe('GetTimeline', function()
    local get = function(...) return Mock.selfExport('GetTimeline')(...) end
    local t0 = 1700000000
    it('an officer reads their own; a supervisor reads others; a lower grade does not', function()
        assert_true(get('COPCID', t0, t0 + 60, { viewer = COP }).ok)
        assert_true(get('COPCID', t0, t0 + 60, { viewer = SGT }).ok)
        assert_eq(get('COPCID', t0, t0 + 60, { viewer = COP2 }).error, 'no_permission')
        assert_eq(get('COPCID', t0, t0 + 60, { viewer = CIV }).error, 'no_permission')
    end)
    it('another resource needs a viewer or a valid court order; the order check fails closed', function()
        Mock.invokingResource = 'pf-justice'
        assert_eq(get('COPCID', t0, t0 + 60, {}).error, 'no_permission')
        assert_eq(get('COPCID', t0, t0 + 60, { courtOrderId = 'CO-1' }).error, 'no_permission') -- pf-justice not started
        resources['pf-justice'] = 'started'
        assert_eq(get('COPCID', t0, t0 + 60, { courtOrderId = 'CO-1' }).error, 'no_permission') -- no valid order
        courtValid = true
        assert_true(get('COPCID', t0, t0 + 60, { courtOrderId = 'CO-1' }).ok)
        Mock.invokingResource = 'random-resource'
        assert_eq(get('COPCID', t0, t0 + 60, { courtOrderId = 'CO-1' }).error, 'not_allowed')
    end)
    it('bad windows are refused', function()
        assert_eq(get('COPCID', t0 + 60, t0, { viewer = COP }).error, 'bad_args')
        assert_eq(get('COPCID', t0, t0 + Config.Equipment.Telemetry.MaxWindowSeconds + 1, { viewer = COP }).error, 'bad_args')
        assert_eq(get("x' OR 1", t0, t0 + 1, { viewer = COP }).error, 'bad_args')
    end)
    it('flushes first, pages with a cursor and says it is not video', function()
        T.Push({ cid = 'COPCID', device = 'body', kind = 'note', clientReported = 0, at = t0 })
        local list = {}
        for i = 1, 3 do list[i] = { id = i, device = 'body', kind = 'pos', x = 1, y = 2, z = 3, client_reported = i == 3 and 1 or 0, at = t0 + i } end
        nextRows = list
        local r = get('COPCID', t0, t0 + 60, { viewer = COP, limit = 2 })
        assert_true(r.ok)
        assert_eq(#inserts(), 1)                     -- the buffered row went in before the read
        assert_eq(#r.events, 2)
        assert_eq(r.next, 2)
        assert_true(r.note:find('No video', 1, true) ~= nil)
        local sel = Mock.dbCalls[#Mock.dbCalls]
        assert_eq(sel.params[1], 'COPCID')
        assert_eq(sel.params[5], 3)                  -- limit + 1 to know there is a next page
    end)
end)

describe('retention and holds', function()
    it('the sweep deletes old rows only where no hold covers them', function()
        T.Sweep(Mock.clock)
        local q = Mock.dbCalls[#Mock.dbCalls]
        assert_true(q.query:find('DELETE FROM pf_police_telemetry', 1, true) ~= nil)
        assert_true(q.query:find('pf_police_telemetry_holds', 1, true) ~= nil)
        assert_eq(q.params[1], Mock.clock - Config.Equipment.Telemetry.RetentionDays * 86400)
    end)
    it('HoldTimeline validates and is allowlisted', function()
        local hold = Mock.selfExport('HoldTimeline')
        assert_eq(hold('COPCID', 10, 5, 'case:1').error, 'bad_args')
        assert_eq(hold('COPCID', 5, 10, 'bad ref with spaces').error, 'bad_args')
        Mock.invokingResource = 'other'
        assert_eq(hold('COPCID', 5, 10, 'case:1').error, 'not_allowed')
        Mock.invokingResource = 'pf-policemdt-DEV'
        assert_true(hold('COPCID', 5, 10, 'case:1').ok)
    end)
end)

describe('lifecycle', function()
    it('a dropped officer stops recording (memory is freed)', function()
        held[COP] = { bodycam = true }
        Mock.useables.bodycam(COP)
        Mock.fireEvent('playerDropped', COP)
        assert_eq(T.recording[COP], nil)
    end)
    it('the medical engine says the officer went down: a note in the timeline', function()
        held[COP] = { bodycam = true }
        Mock.useables.bodycam(COP)
        Mock.fireEvent('pf-ambulancejob:server:patientDown', nil, COP, 'COPCID', 'unconscious', { mechanism = 'gunshot' })
        local notes = rows('note')
        assert_eq(json.decode(notes[#notes].data).event, 'officer_down')
    end)
end)
