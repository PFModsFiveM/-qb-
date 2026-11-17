-- pf-justice supervision and monitors (unit 19B, PF_ARCHITECTURE 4.7.8): supervision rows follow probation /
-- parole orders; appointments (officer gate, keys, calendar entry); check-ins only in a probation office zone or
-- next to a probation officer (server positions); violations are REPORTS for the officer that never touch
-- orders or custody; the sweep reports missed appointments / overdue check-ins once; the monitor geofence
-- (curfew over midnight, house arrest, no-go zones) needs consecutive samples, reports once per episode,
-- and is repeat-guarded; the /checkin command; deleted characters are anonymised.
--
-- The supervision statements run on an in-memory store below, matched by their exact text from
-- PFJustice.SQL (a changed statement fails here); the real SQL runs in
-- realdb_specs/b19_justice_supervision_realdb_spec.lua.
load_resource('tests/lua/fivem_mocks.lua')
QBCore = QBCoreMock
function GetCurrentResourceName() return 'pf-justice' end
local started = { ['pf-citizen'] = true, ['pfm-houses'] = true }
function GetResourceState(name) return started[name] and 'started' or 'missing' end

local mails, jobMails, calendar = {}, {}, {}
Mock.exportsByResource['pf-citizen'] = {
    SendMail = function(_, cid, opts) mails[#mails + 1] = { cid = cid, opts = opts } return #mails end,
    SendMailToJob = function(_, job, opts) jobMails[#jobMails + 1] = { job = job, opts = opts } return 1 end,
    AddCalendarEvent = function(_, scope, owner, data) calendar[#calendar + 1] = { scope = scope, owner = owner, data = data } return 40 + #calendar end,
}
local owned = {}
Mock.exportsByResource['pfm-houses'] = { GetOwnedHouses = function() return owned end }

Config = nil
load_resource('[pfscripts]/pf-justice/config.lua')
load_resource('[pfscripts]/pf-justice/shared/states.lua')
load_resource('[pfscripts]/pf-justice/server/main.lua')
local J = PFJustice
local Q = J.SQL

-- orders stand-in: the rows supervision.lua reads, and spies on everything that could change a sentence
local ORDERS = {}
local touched = {}
local function spy(name) return function() touched[#touched + 1] = name return { ok = true } end end
J.Orders = { Row = function(id) return ORDERS[tonumber(id)] end, Public = function(r) return r end, Norm = function(r) return r end,
    Create = spy('Orders.Create'), SetState = spy('Orders.SetState'), Adjust = spy('Orders.Adjust'), ReleaseNow = spy('Orders.ReleaseNow') }
J.API = setmetatable({}, { __index = function(_, k) return spy('API.' .. k) end })
J.Custody = setmetatable({}, { __index = function(_, k) return spy('Custody.' .. k) end })
J.Schema = { Has = function(v) return v == 4 end }
J.ready = true
load_resource('[pfscripts]/pf-justice/server/supervision.lua')
load_resource('[pfscripts]/pf-justice/server/monitors.lua')
Mock.exportsByResource['pf-justice'] = Mock.exportsByResource['__self']

-- ── in-memory store for the supervision statements ─────────────────────────────────────────────
local DB
local function resetDB() DB = { sup = {}, ev = {}, houses = {}, n = { s = 0, e = 0 } } end
resetDB()
local function copy(t) if not t then return nil end local o = {} for k, v in pairs(t) do o[k] = v end return o end
local function sorted(tbl, cmp)
    local out = {}
    for _, r in pairs(tbl) do out[#out + 1] = r end
    table.sort(out, cmp or function(a, b) return a.id < b.id end)
    return out
end
local function filter(tbl, pred, cmp, limit)
    local out = {}
    for _, r in ipairs(sorted(tbl, cmp)) do
        if pred(r) then out[#out + 1] = copy(r) if limit and #out >= limit then break end end
    end
    return out
end
local function key(e) local d = json.decode(e.detail or '') or {} return d.key, d.type end
local H = {}
H[Q.supInsert] = function(p)
    for _, s in pairs(DB.sup) do if s.order_id == p[1] then return 0 end end
    DB.n.s = DB.n.s + 1
    DB.sup[DB.n.s] = { id = DB.n.s, order_id = p[1], citizenid = p[2], state = p[3], monitor = p[4], next_checkin_at = p[5], created_at = p[6] }
    return DB.n.s
end
H[Q.supById] = function(p) return copy(DB.sup[tonumber(p[1])]) end
H[Q.supByOrder] = function(p) return filter(DB.sup, function(s) return s.order_id == p[1] end)[1] end
H[Q.supByCid] = function(p) return filter(DB.sup, function(s) return s.citizenid == p[1] end, function(a, b) return a.id > b.id end, 20) end
H[Q.supSetState] = function(p)
    local s = DB.sup[tonumber(p[3])]
    if not s or s.state ~= p[4] then return 0 end
    s.state, s.ended_at = p[1], p[2]
    return 1
end
H[Q.supSetOfficer] = function(p)
    local s = DB.sup[tonumber(p[2])]
    if not s or s.officer_cid ~= nil then return 0 end
    s.officer_cid = p[1]
    return 1
end
H[Q.supSetMonitor] = function(p) local s = DB.sup[tonumber(p[2])] if not s then return 0 end s.monitor = p[1] return 1 end
H[Q.supSetNextCheckin] = function(p)
    local s = DB.sup[tonumber(p[2])]
    if not s or s.next_checkin_at ~= p[3] then return 0 end
    s.next_checkin_at = p[1]
    return 1
end
H[Q.supDueCheckins] = function(p)
    return filter(DB.sup, function(s) return s.state == 'active' and s.next_checkin_at ~= nil and s.next_checkin_at <= p[1] end, nil, 100)
end
H[Q.supMonitored] = function()
    local out = filter(DB.sup, function(s) return s.state == 'active' and s.monitor ~= nil end)
    for _, r in ipairs(out) do r.order_conditions = ORDERS[r.order_id] and json.encode(ORDERS[r.order_id].conditions or {}) end
    return out
end
H[Q.supMissing] = function()
    local have = {}
    for _, s in pairs(DB.sup) do have[s.order_id] = true end
    return filter(ORDERS, function(o) return (o.kind == 'probation' or o.kind == 'parole') and Sup_OPEN(o.state) and not have[o.id] end)
end
H[Q.supStale] = function()
    local out = {}
    for _, s in ipairs(sorted(DB.sup)) do
        local o = ORDERS[s.order_id]
        if o and Sup_OPEN(s.state) and o.state ~= s.state then out[#out + 1] = { id = s.id, order_id = s.order_id, state = s.state, order_state = o.state } end
    end
    return out
end
H[Q.supAnon] = function(p) local n = 0 for _, s in pairs(DB.sup) do if s.citizenid == p[2] then s.citizenid = p[1] n = n + 1 end end return n end
H[Q.supHouseCoords] = function(p) return DB.houses[p[1]] and { coords = DB.houses[p[1]] } or nil end
H[Q.supEvInsert] = function(p)
    DB.n.e = DB.n.e + 1
    DB.ev[DB.n.e] = { id = DB.n.e, supervision_id = p[1], kind = p[2], due_at = p[3], done_at = p[4], state = p[5], detail = p[6], by_cid = p[7], at = p[8] }
    return DB.n.e
end
H[Q.supEvBySup] = function(p) return filter(DB.ev, function(e) return e.supervision_id == p[1] end, function(a, b) return a.id > b.id end, p[2]) end
H[Q.supEvByKey] = function(p)
    return filter(DB.ev, function(e) return e.supervision_id == p[1] and e.kind == p[2] and key(e) == p[3] end)[1]
end
H[Q.supEvRecent] = function(p)
    return filter(DB.ev, function(e) local _, t = key(e) return e.supervision_id == p[1] and e.kind == 'violation' and t == p[2] and e.at >= p[3] end,
        function(a, b) return a.id > b.id end, 1)[1]
end
H[Q.supEvOpenAppts] = function(p)
    return filter(DB.ev, function(e) return e.supervision_id == p[1] and e.kind == 'appointment' and e.state == 'scheduled' end,
        function(a, b) if a.due_at ~= b.due_at then return a.due_at < b.due_at end return a.id < b.id end)
end
H[Q.supEvDueAppts] = function(p)
    return filter(DB.ev, function(e) return e.kind == 'appointment' and e.state == 'scheduled' and e.due_at <= p[1] end, nil, 100)
end
H[Q.supEvSetState] = function(p)
    local e = DB.ev[tonumber(p[3])]
    if not e or e.state ~= p[4] then return 0 end
    e.state, e.done_at = p[1], p[2]
    return 1
end
H[Q.supEvSetDetail] = function(p) local e = DB.ev[tonumber(p[2])] if not e then return 0 end e.detail = p[1] return 1 end
H[Q.supEvCancelAppts] = function(p)
    local n = 0
    for _, e in pairs(DB.ev) do
        if e.supervision_id == p[2] and e.kind == 'appointment' and e.state == 'scheduled' then e.state, e.done_at = 'cancelled', p[1] n = n + 1 end
    end
    return n
end
H[Q.supEvAnon] = function(p) local n = 0 for _, e in pairs(DB.ev) do if e.by_cid == p[2] then e.by_cid = p[1] n = n + 1 end end return n end
H[Q.insertAudit] = function() return 1 end
local dbDown = false
local function run(sql, params)
    if dbDown then error('db down') end
    local fn = H[sql]
    if not fn then error('unexpected SQL in spec: ' .. tostring(sql):sub(1, 80)) end
    return fn(params or {})
end
local function await(kind)
    return setmetatable({ await = function(sql, p) return run(sql, p) end }, { __call = function(_, sql, p) return run(sql, p) end })
end
MySQL = { query = await(), single = await(), insert = await(), update = await(), scalar = await() }

local Sup, Mon = J.Supervision, J.Monitors
function Sup_OPEN(state) return Sup.OPEN[state] == true end
local api = exports['pf-justice']

local OFFICER, CITIZEN, COP, CLERK, JUDGE, OTHER = 1, 2, 3, 4, 5, 6
local OFFICE = vector3(-544.67, -204.25, 38.22)
local HOME = { x = 300.0, y = 300.0, z = 30.0, radius = 30.0 }
local NOGO = { x = 1000.0, y = 1000.0, z = 30.0, radius = 50.0 }
local BASE = 1700000000
BASE = BASE + ((23 - os.date('*t', BASE).hour) % 24) * 3600 -- 23:00 local

local nextOrder = 0
local function order(conditions, extra)
    nextOrder = nextOrder + 1
    local o = { id = nextOrder, cid = 'PROBCID', citizenid = 'PROBCID', kind = 'probation', state = 'active', days = 30,
        conditions = conditions, endsAt = Mock.clock + 30 * 86400 }
    for k, v in pairs(extra or {}) do o[k] = v end
    ORDERS[o.id] = o
    TriggerEvent('pf-justice:server:orderCreated', o)
    return o, H[Q.supByOrder]({ o.id })
end
local function evs(supId, kind) return filter(DB.ev, function(e) return e.supervision_id == supId and (not kind or e.kind == kind) end) end
local function emitted(name)
    local n = 0
    for _, e in ipairs(Mock.serverEvents) do if e.name == 'pf-justice:server:' .. name then n = n + 1 end end
    return n
end
local CURFEW = { { kind = 'checkin', everyDays = 7 }, { kind = 'curfew', from = 22, to = 6, zone = HOME }, { kind = 'no_go', zone = NOGO },
    { kind = 'monitor' } }

-- a geofence sample at time t (the server clock moves with it)
local function tick(t) Mock.clock = t return Mon.Tick(t) end

BeforeEach = function()
    resetDB()
    Mock.reset()
    Mock.clock = BASE
    for k in pairs(ORDERS) do ORDERS[k] = nil end
    touched = {}
    mails, jobMails, calendar = {}, {}, {}
    owned = {}
    dbDown = false
    Mon.index, Mon.breach = {}, {}
    J.Rate.Forget('')
    Mock.players = {}
    local function job(src, cid, j) local p = Mock.newPlayer(src, cid) p.PlayerData.job = j return p end
    job(OFFICER, 'POCID', { name = 'doj', type = 'doj', onduty = true, grade = { level = 3 } })
    Mock.newPlayer(CITIZEN, 'PROBCID')
    job(COP, 'COPCID', { name = 'police', type = 'leo', onduty = true, grade = { level = 1 } })
    job(CLERK, 'CLERKCID', { name = 'doj', type = 'doj', onduty = true, grade = { level = 0 } })
    job(JUDGE, 'JUDGECID', { name = 'judge', type = 'doj', onduty = true, grade = { level = 1 } })
    Mock.newPlayer(OTHER, 'OTHERCID')
    Mock.coords = { [OFFICER] = vector3(0.0, 0.0, 0.0), [CITIZEN] = vector3(5000.0, 5000.0, 30.0), [COP] = vector3(0.0, 0.0, 0.0),
        [OTHER] = OFFICE }
    Mock.invokingResource = 'pf-policemdt-DEV'
end

describe('b19 supervision rows follow orders', function()
    it('a probation order gets one row with the check-in due date and the court-ordered monitor', function()
        local o, row = order(CURFEW)
        assert_true(row ~= nil, 'row created')
        assert_eq(row.state, 'active')
        assert_eq(row.next_checkin_at, BASE + 7 * 86400)
        local m = json.decode(row.monitor)
        assert_eq(m.mode, 'curfew')
        assert_eq(m.from, 1320)
        assert_eq(m.to, 360)
        assert_true(Mon.index.PROBCID ~= nil, 'monitor indexed')
        TriggerEvent('pf-justice:server:orderCreated', o)
        assert_eq(#filter(DB.sup, function() return true end), 1)
        assert_eq(mails[1].cid, 'PROBCID')
        assert_eq(mails[1].opts.ref, ('pf-justice:sup:%d:start'):format(row.id))
    end)

    it('other order kinds get no row; a monitor whose home cannot be placed tracks no-go zones and leaves a note', function()
        ORDERS[50] = { id = 50, cid = 'PROBCID', kind = 'fine', state = 'issued' }
        TriggerEvent('pf-justice:server:orderCreated', ORDERS[50])
        assert_eq(#filter(DB.sup, function() return true end), 0)
        local _, row = order({ { kind = 'monitor', mode = 'home', house = 'nothouse' } })
        assert_eq(json.decode(row.monitor).mode, 'track')
        local notes = evs(row.id, 'note')
        assert_eq(#notes, 1)
        assert_eq(json.decode(notes[1].detail).action, 'monitor_home_unresolved')
    end)

    it('state changes are mirrored: suspended stops the monitor, completed cancels appointments', function()
        local o, row = order(CURFEW)
        local r = Sup.Schedule(row.id, { at = BASE + 3600 }, { key = 'k1', actor = { src = OFFICER } }, {})
        assert_true(r.ok)
        o.state = 'suspended'
        TriggerEvent('pf-justice:server:orderChanged', o, { action = 'state', from = 'active', to = 'suspended' })
        assert_eq(DB.sup[row.id].state, 'suspended')
        assert_eq(Mon.index.PROBCID, nil)
        o.state = 'active'
        TriggerEvent('pf-justice:server:orderChanged', o, { action = 'state', from = 'suspended', to = 'active' })
        assert_true(Mon.index.PROBCID ~= nil, 'monitor back on resume')
        o.state = 'completed'
        TriggerEvent('pf-justice:server:orderChanged', o, { action = 'state', from = 'active', to = 'completed' })
        assert_eq(DB.sup[row.id].state, 'completed')
        assert_eq(DB.sup[row.id].ended_at, BASE)
        assert_eq(DB.ev[r.appointmentId].state, 'cancelled')
        assert_eq(Mon.index.PROBCID, nil)
    end)

    it('the reconcile creates missing rows and follows orders that changed while the event was lost', function()
        ORDERS[60] = { id = 60, cid = 'PROBCID', citizenid = 'PROBCID', kind = 'parole', state = 'active', conditions = {} }
        local out = Sup.Reconcile()
        assert_eq(out.created, 1)
        ORDERS[60].state = 'revoked'
        out = Sup.Reconcile()
        assert_eq(out.followed, 1)
        assert_eq(H[Q.supByOrder]({ 60 }).state, 'revoked')
    end)
end)

describe('b19 appointments', function()
    it('only on-duty probation officers, judges or admins schedule; keys are required and deduplicated', function()
        local _, row = order(CURFEW)
        local spec = { at = BASE + 3600, office = 2, note = 'Bring ID' }
        assert_eq(api:ScheduleAppointment(row.id, spec, { key = 'a', actor = { src = CLERK } }).error, 'no_permission')
        assert_eq(api:ScheduleAppointment(row.id, spec, { key = 'a', actor = { src = COP } }).error, 'no_permission')
        assert_eq(api:ScheduleAppointment(row.id, spec, { actor = { src = OFFICER } }).error, 'bad_args')
        assert_eq(api:ScheduleAppointment(row.id, spec, { key = 'a' }).error, 'no_permission') -- no player actor
        Mock.players[OFFICER].PlayerData.job.onduty = false
        assert_eq(api:ScheduleAppointment(row.id, spec, { key = 'a', actor = { src = OFFICER } }).error, 'no_permission')
        Mock.players[OFFICER].PlayerData.job.onduty = true
        local r = api:ScheduleAppointment(row.id, spec, { key = 'a', actor = { src = OFFICER } })
        assert_true(r.ok, tostring(r.error))
        assert_eq(r.calendarId, 41)
        assert_true(api:ScheduleAppointment(row.id, spec, { key = 'a', actor = { src = OFFICER } }).duplicate)
        assert_eq(#calendar, 1)
        assert_eq(calendar[1].scope, 'personal')
        assert_eq(calendar[1].owner, 'PROBCID')
        assert_eq(calendar[1].data.location, 'Sandy Shores probation desk')
        assert_eq(DB.sup[row.id].officer_cid, 'POCID')
        assert_true(api:ScheduleAppointment(row.id, { at = BASE + 7200 }, { key = 'b', actor = { src = JUDGE } }).ok, 'judge')
        assert_eq(DB.sup[row.id].officer_cid, 'POCID', 'a judge does not take the case')
        Mock.invokingResource = 'pfm-prison'
        assert_eq(api:ScheduleAppointment(row.id, spec, { key = 'c', actor = { src = OFFICER } }).error, 'not_allowed')
    end)

    it('refuses times in the past, too close or too far ahead, and unknown offices', function()
        local _, row = order(CURFEW)
        local function try(spec) return api:ScheduleAppointment(row.id, spec, { key = 'x' .. tostring(spec.at) .. tostring(spec.office), actor = { src = OFFICER } }) end
        assert_eq(try({ at = BASE - 60 }).error, 'bad_args')
        assert_eq(try({ at = BASE + 60 }).error, 'bad_args')
        assert_eq(try({ at = BASE + 61 * 86400 }).error, 'bad_args')
        assert_eq(try({ at = BASE + 3600, office = 99 }).error, 'bad_args')
    end)
end)

describe('b19 check-ins', function()
    it('the citizen checks in only inside a probation office zone; the attended appointment and next due date update', function()
        local _, row = order(CURFEW)
        local appt = Sup.Schedule(row.id, { at = BASE + 15 * 60 }, { actor = { src = OFFICER } }, {})
        assert_eq(Sup.CheckIn(row.id, { actor = { src = CITIZEN } }, {}).error, 'too_far')
        J.Rate.Forget('')
        Mock.coords[CITIZEN] = vector3(OFFICE.x + 10.0, OFFICE.y, OFFICE.z)
        local r = Sup.CheckIn(row.id, { actor = { src = CITIZEN } }, {})
        assert_true(r.ok, tostring(r.error))
        assert_eq(r.appointmentId, appt.appointmentId)
        assert_eq(DB.ev[appt.appointmentId].state, 'attended')
        assert_eq(DB.sup[row.id].next_checkin_at, BASE + 7 * 86400)
        assert_eq(Sup.CheckIn(row.id, { actor = { src = CITIZEN } }, {}).error, 'rate_limited')
    end)

    it('a probation officer records a field visit only standing next to the citizen; others cannot check someone in', function()
        local _, row = order(CURFEW)
        Mock.coords[OFFICER] = vector3(5020.0, 5000.0, 30.0)
        assert_eq(Sup.CheckIn(row.id, { actor = { src = OFFICER } }, {}).error, 'too_far')
        J.Rate.Forget('')
        Mock.coords[OFFICER] = vector3(5002.0, 5000.0, 30.0)
        local r = Sup.CheckIn(row.id, { actor = { src = OFFICER } }, {})
        assert_true(r.ok, tostring(r.error))
        assert_eq(json.decode(evs(row.id, 'checkin')[1].detail).where, 'field')
        assert_eq(Sup.CheckIn(row.id, { actor = { src = OTHER } }, {}).error, 'no_permission')
        assert_eq(Sup.CheckIn(row.id, {}, {}).error, 'no_permission')
    end)

    it('/checkin checks the caller in; an offline or ended supervision is refused', function()
        local o, row = order(CURFEW)
        assert_true(Mock.rawCommands.checkin ~= nil, 'command registered')
        Mock.coords[CITIZEN] = OFFICE
        Mock.rawCommands.checkin(CITIZEN, {})
        assert_eq(#evs(row.id, 'checkin'), 1)
        o.state = 'completed'
        TriggerEvent('pf-justice:server:orderChanged', o, { action = 'state' })
        J.Rate.Forget('')
        assert_eq(Sup.CheckIn(row.id, { actor = { src = CITIZEN } }, {}).error, 'invalid_state')
    end)
end)

describe('b19 violations are reports, never custody', function()
    it('police and probation officers report; the officer is mailed; nothing changes the order or custody', function()
        local o, row = order(CURFEW)
        H[Q.supSetOfficer]({ 'POCID', row.id })
        Mock.invokingResource = 'pfm-policejob'
        assert_eq(api:RecordViolation(row.id, { kind = 'weapons' }, { key = 'v1', actor = { src = OTHER } }).error, 'no_permission')
        assert_eq(api:RecordViolation(row.id, { kind = 'jailbreak' }, { key = 'v1', actor = { src = COP } }).error, 'bad_args')
        local r = api:RecordViolation(row.id, { kind = 'weapons', note = 'Pistol', evidenceIds = { 7 } }, { key = 'v1', actor = { src = COP } })
        assert_true(r.ok, tostring(r.error))
        assert_true(api:RecordViolation(row.id, { kind = 'weapons' }, { key = 'v1', actor = { src = COP } }).duplicate)
        local v = evs(row.id, 'violation')
        assert_eq(#v, 1)
        assert_eq(v[1].state, 'open')
        local d = json.decode(v[1].detail)
        assert_eq(d.type, 'weapons')
        assert_eq(d.source, 'officer')
        assert_eq(d.x, 5000)
        assert_eq(mails[#mails].cid, 'POCID')
        assert_eq(mails[#mails].opts.ref, ('pf-justice:supviol:%d'):format(r.violationId))
        assert_eq(emitted('supervisionViolation'), 1)
        assert_eq(#touched, 0, 'no order or custody function was called')
        assert_eq(o.state, 'active')
        assert_eq(DB.sup[row.id].state, 'active')
        Mock.invokingResource = 'pfm-prison'
        assert_eq(api:RecordViolation(row.id, { kind = 'other' }, { key = 'v2', actor = { src = COP } }).error, 'not_allowed')
    end)

    it('without a supervising officer the DOJ is mailed', function()
        local _, row = order(CURFEW)
        Mock.invokingResource = 'pfm-policejob'
        assert_true(api:RecordViolation(row.id, { kind = 'alcohol' }, { key = 'v3', actor = { src = COP } }).ok)
        assert_eq(#jobMails, 1)
        assert_eq(jobMails[1].job, 'doj')
    end)

    it('GetSupervision shows violation reports only to full readers', function()
        local _, row = order(CURFEW)
        Sup.Violation(row.id, { kind = 'contact' }, { source = 'system' }, {})
        Mock.invokingResource = 'pf-citizen'
        local s = api:GetSupervision('PROBCID').supervision
        assert_eq(s.violations, nil)
        assert_eq(s.monitor.mode, 'curfew')
        assert_eq(s.monitor.home, nil, 'home location hidden from other resources')
        assert_eq(s.conditions[2].kind, 'curfew')
        assert_eq(s.conditions[2].zone, nil, 'condition zones hidden from other resources')
        Mock.invokingResource = 'pf-policemdt-DEV'
        s = api:GetSupervision('PROBCID').supervision
        assert_eq(#s.violations, 1)
        assert_eq(s.violations[1].detail.key, nil)
        assert_eq(s.monitor.home.x, 300.0)
    end)
end)

describe('b19 sweep', function()
    it('a missed appointment and an overdue check-in become one report each; the due date moves on', function()
        local _, row = order(CURFEW)
        local a = Sup.Schedule(row.id, { at = BASE + 3600 }, { actor = { src = OFFICER } }, {})
        Mock.clock = BASE + 7 * 86400 + 25 * 3600
        local out = Sup.Sweep(Mock.clock)
        assert_eq(out.missed, 1)
        assert_eq(out.checkins, 1)
        assert_eq(DB.ev[a.appointmentId].state, 'missed')
        assert_eq(DB.sup[row.id].next_checkin_at, BASE + 14 * 86400)
        out = Sup.Sweep(Mock.clock)
        assert_eq(out.missed + out.checkins, 0)
        assert_eq(#evs(row.id, 'violation'), 2)
        assert_eq(#touched, 0)
    end)
end)

describe('b19 monitor geofence', function()
    it('a curfew breach needs two samples, is reported once per episode and after a fresh episode only past the repeat guard', function()
        local _, row = order(CURFEW)
        Mock.coords[CITIZEN] = vector3(2000.0, 2000.0, 30.0)
        assert_eq(tick(BASE), 0)
        assert_eq(tick(BASE + 5), 1)
        assert_eq(tick(BASE + 10), 0)
        local v = evs(row.id, 'violation')
        assert_eq(#v, 1)
        local d = json.decode(v[1].detail)
        assert_eq(d.type, 'curfew')
        assert_eq(d.source, 'monitor')
        -- home briefly, then out again: still the same episode
        Mock.coords[CITIZEN] = vector3(305.0, 300.0, 30.0)
        tick(BASE + 15)
        Mock.coords[CITIZEN] = vector3(2000.0, 2000.0, 30.0)
        tick(BASE + 20) tick(BASE + 25)
        assert_eq(#evs(row.id, 'violation'), 1)
        -- home long enough to close the episode; a new breach within RepeatSeconds is not reported again
        Mock.coords[CITIZEN] = vector3(305.0, 300.0, 30.0)
        tick(BASE + 30) tick(BASE + 35) tick(BASE + 40)
        Mock.coords[CITIZEN] = vector3(2000.0, 2000.0, 30.0)
        tick(BASE + 45) tick(BASE + 50)
        assert_eq(#evs(row.id, 'violation'), 1)
        -- later the same night: a new report
        Mock.coords[CITIZEN] = vector3(305.0, 300.0, 30.0)
        tick(BASE + 1900) tick(BASE + 1905) tick(BASE + 1910)
        Mock.coords[CITIZEN] = vector3(2000.0, 2000.0, 30.0)
        tick(BASE + 1915)
        assert_eq(tick(BASE + 1920), 1)
        assert_eq(#touched, 0, 'a breach never changes custody or the order')
    end)

    it('the curfew window wraps midnight; outside the window being away is fine', function()
        assert_true(Mon.InWindow(23 * 60 + 30, 1320, 360))
        assert_true(Mon.InWindow(5 * 60 + 59, 1320, 360))
        assert_false(Mon.InWindow(6 * 60, 1320, 360))
        assert_false(Mon.InWindow(12 * 60, 1320, 360))
        assert_true(Mon.InWindow(13 * 60, 12 * 60, 14 * 60))
        assert_eq(Sup.MinuteOfDay('22:30'), 1350)
        assert_eq(Sup.MinuteOfDay(6.5), 390)
        assert_eq(Sup.MinuteOfDay('25:00'), nil)
        local _, row = order(CURFEW)
        Mock.coords[CITIZEN] = vector3(2000.0, 2000.0, 30.0)
        tick(BASE + 13 * 3600) -- 12:00
        tick(BASE + 13 * 3600 + 5)
        assert_eq(#evs(row.id, 'violation'), 0)
    end)

    it('house arrest reports leaving the home at any hour; no-go zones report in every mode; offline is not sampled', function()
        DB.houses.grove1 = json.encode({ enter = { x = 120.0, y = -1900.0, z = 25.0 } })
        owned = { { house = 'grove1', citizenid = 'PROBCID', value = 1, label = 'Grove St 1' } }
        local _, row = order({ { kind = 'no_go', zone = NOGO } })
        assert_eq(Mon.index.PROBCID, nil, 'no monitor ordered')
        assert_eq(api:SetMonitor('PROBCID', { mode = 'home', house = 'grove1' }, { actor = { src = COP } }).error, 'no_permission')
        owned[1].citizenid = 'SOMEONE'
        assert_eq(api:SetMonitor('PROBCID', { mode = 'home', house = 'grove1' }, { actor = { src = OFFICER } }).error, 'bad_args')
        owned[1].citizenid = 'PROBCID'
        local r = api:SetMonitor('PROBCID', { mode = 'home', house = 'grove1' }, { actor = { src = OFFICER } })
        assert_true(r.ok, tostring(r.error))
        Mock.coords[CITIZEN] = vector3(120.0, -1900.0, -5.0) -- the shell under the entrance counts as home
        tick(BASE + 13 * 3600) tick(BASE + 13 * 3600 + 5)
        assert_eq(#evs(row.id, 'violation'), 0)
        Mock.coords[CITIZEN] = vector3(1010.0, 1000.0, 30.0)
        tick(BASE + 13 * 3600 + 10)
        Mock.players[CITIZEN] = nil -- logged off between samples: the count restarts
        tick(BASE + 13 * 3600 + 15)
        assert_eq(#evs(row.id, 'violation'), 0)
        Mock.newPlayer(CITIZEN, 'PROBCID')
        tick(BASE + 13 * 3600 + 20)
        assert_eq(tick(BASE + 13 * 3600 + 25), 2, 'home zone and no-go')
        local types = {}
        for _, e in ipairs(evs(row.id, 'violation')) do types[json.decode(e.detail).type] = true end
        assert_true(types.home_zone and types.no_go)
        assert_true(api:SetMonitor('PROBCID', false, { actor = { src = OFFICER } }).ok)
        assert_eq(Mon.index.PROBCID, nil)
        assert_eq(DB.sup[row.id].monitor, nil)
    end)

    it('a report that could not be written is tried again at the next sample', function()
        local _, row = order(CURFEW)
        Mock.coords[CITIZEN] = vector3(2000.0, 2000.0, 30.0)
        tick(BASE)
        dbDown = true
        assert_eq(tick(BASE + 5), 0)
        dbDown = false
        assert_eq(tick(BASE + 10), 1)
        assert_eq(#evs(row.id, 'violation'), 1)
    end)

    it('the index is rebuilt from the database at start', function()
        order(CURFEW)
        Mon.index = {}
        assert_true(Mon.LoadIndex())
        assert_true(Mon.index.PROBCID ~= nil)
        assert_eq(#Mon.index.PROBCID.noGo, 1)
    end)
end)

describe('b19 deleted characters', function()
    it('supervision rows and their events lose the citizen id', function()
        local _, row = order(CURFEW)
        Mock.invokingResource = nil
        Mock.fireEvent('pfm-core:server:characterDeleted', nil, 'PROBCID')
        assert_true(DB.sup[row.id].citizenid:sub(1, 5) == 'anon-', 'anonymised')
        assert_eq(Mon.index.PROBCID, nil)
    end)
end)
