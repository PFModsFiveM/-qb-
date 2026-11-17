-- pf-justice supervision (unit 19B) on a real database: schema v4 tables from 19A, every statement of
-- server/supervision.lua and server/monitors.lua runs on MariaDB:
--   * a probation order gets one supervision row (INSERT IGNORE on uq_js_order), with the check-in due date
--     and the court-ordered monitor; the boot reconcile creates a missing row and follows a changed order;
--   * appointments are keyed through JSON_VALUE(detail, '$.key'), get a calendar entry once, set the officer;
--   * check-ins need a probation office zone (server position), mark an appointment attended and move the
--     next due date (compare-and-set with <=>);
--   * violations are reports: keyed, repeat-guarded, mailed to the officer, never touching orders or custody;
--   * the sweep reports a missed appointment and an overdue check-in once each;
--   * the monitor geofence reports a curfew breach once per episode and not again after a restart;
--   * SetMonitor places a house the citizen owns (pfm-houses GetOwnedHouses + houselocations);
--   * an order revoked or completed ends the row, cancels appointments and drops the monitor.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
local states = { ['pfm-banking'] = 'missing', ['pfm-phone'] = 'missing', ['pf-ambulancejob'] = 'missing', ['pfm-prison'] = 'missing' }
function GetResourceState(name) return states[name] or 'started' end

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-houses/qb-houses.sql')
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end
load_resource('pfm-core/server/migrations.lua')

local mails, jobMails, calendar = {}, {}, {}
Mock.exportsByResource['pf-citizen'] = {
    SendMail = function(_, cid, opts) mails[#mails + 1] = { cid = cid, opts = opts } return #mails end,
    SendMailToJob = function(_, job, opts) jobMails[#jobMails + 1] = { job = job, opts = opts } return 1 end,
    AddCalendarEvent = function(_, scope, owner, data) calendar[#calendar + 1] = { scope = scope, owner = owner, data = data } return 70 + #calendar end,
}
local owned = {}
Mock.exportsByResource['pfm-houses'] = { GetOwnedHouses = function() return owned end }

function GetCurrentResourceName() return 'pf-justice' end
Config = nil
load_resource('pfm-banking/payouts.lua')
for _, f in ipairs({ 'config.lua', 'shared/states.lua', 'server/main.lua', 'server/schema.lua', 'server/orders.lua', 'server/clock.lua',
    'server/records.lua', 'server/supervision.lua', 'server/monitors.lua', 'server/api.lua' }) do
    load_resource('[pfscripts]/pf-justice/' .. f)
end
Mock.exportsByResource['pf-justice'] = Mock.exportsByResource['__self']
local J = PFJustice
local Sup, Mon = J.Supervision, J.Monitors
local api = exports['pf-justice']

local OFFICER, CITIZEN, COP, CLERK = 1, 2, 3, 4
local OFFICE = vector3(-544.67, -204.25, 38.22)
local HOME = { x = 300.0, y = 300.0, z = 30.0, radius = 30.0 }
local NOGO = { x = 1000.0, y = 1000.0, z = 30.0, radius = 50.0 }

-- a clock time whose local hour is 23 (inside a 22:00-06:00 curfew)
local base = 1700000000
base = base + ((23 - os.date('*t', base).hour) % 24) * 3600

local function scalar(sql, p) return tonumber(MySQL.scalar.await(sql, p or {})) or 0 end
local function sup(id) return MySQL.single.await('SELECT * FROM pf_justice_supervision WHERE id = ?', { id }) end
local function events(id, kind)
    return MySQL.query.await('SELECT * FROM pf_justice_supervision_events WHERE supervision_id = ? AND kind = ? ORDER BY id', { id, kind }) or {}
end

local function players()
    Mock.players = {}
    local o = Mock.newPlayer(OFFICER, 'POCID')
    o.PlayerData.job = { name = 'doj', type = 'doj', onduty = true, grade = { level = 3 } }
    Mock.newPlayer(CITIZEN, 'PROBCID')
    local c = Mock.newPlayer(COP, 'COPCID')
    c.PlayerData.job = { name = 'police', type = 'leo', onduty = true, grade = { level = 1 } }
    local k = Mock.newPlayer(CLERK, 'CLERKCID')
    k.PlayerData.job = { name = 'doj', type = 'doj', onduty = true, grade = { level = 0 } }
    Mock.coords = { [OFFICER] = vector3(0.0, 0.0, 0.0), [CITIZEN] = vector3(5000.0, 5000.0, 30.0), [COP] = vector3(0.0, 0.0, 0.0) }
end

Mock.clock = base
players()
assert(J.Boot(), 'pf-justice boot')
assert(J.Schema.Has(4), 'schema v4 applied')

local function probation(key, conditions, days)
    Mock.invokingResource = nil
    return J.API.CreateOrder({ cid = 'PROBCID', kind = 'probation', days = days or 30, conditions = conditions,
        sourceRef = { type = 'court_decision', id = key } }, { key = key })
end

local CONDITIONS = {
    { kind = 'checkin', everyDays = 7 },
    { kind = 'curfew', from = 22, to = 6, zone = HOME },
    { kind = 'no_go', zone = NOGO },
    { kind = 'monitor' },
}

local orderId, supId

describe('b19 supervision on the real database', function()
    it('creates one supervision row per probation order with check-in due date and the ordered monitor', function()
        Mock.clock = base
        local res = probation('court:1', CONDITIONS)
        assert_true(res.ok, 'order created')
        orderId = res.orderId
        local row = MySQL.single.await('SELECT * FROM pf_justice_supervision WHERE order_id = ?', { orderId })
        assert_true(row ~= nil, 'supervision row')
        supId = tonumber(row.id)
        assert_eq(row.state, 'active')
        assert_eq(row.citizenid, 'PROBCID')
        assert_eq(tonumber(row.next_checkin_at), base + 7 * 86400)
        local m = json.decode(row.monitor)
        assert_eq(m.mode, 'curfew')
        assert_eq(m.from, 22 * 60)
        assert_eq(m.to, 6 * 60)
        assert_near(m.home.x, 300.0, 0.01)
        assert_true(Mon.index.PROBCID ~= nil, 'monitor indexed')
        assert_eq(#Mon.index.PROBCID.noGo, 1)
        -- a second Ensure (event delivered twice) keeps one row
        Sup.Ensure(J.Orders.Public(J.Orders.Row(orderId)))
        assert_eq(scalar('SELECT COUNT(*) FROM pf_justice_supervision WHERE order_id = ?', { orderId }), 1)
        assert_eq(mails[1].cid, 'PROBCID')
    end)

    it('schedules appointments by key with one calendar entry, and only for probation officers', function()
        Mock.clock = base
        Mock.invokingResource = 'pf-policemdt-DEV'
        local spec = { at = base + 15 * 60, office = 1, note = 'Bring your ID' }
        local r1 = api:ScheduleAppointment(supId, spec, { key = 'pmdt:appt:1', actor = { src = OFFICER } })
        assert_true(r1.ok, 'scheduled ' .. tostring(r1.error))
        local r2 = api:ScheduleAppointment(supId, spec, { key = 'pmdt:appt:1', actor = { src = OFFICER } })
        assert_true(r2.duplicate, 'same key = same appointment')
        assert_eq(r2.appointmentId, r1.appointmentId)
        assert_eq(#events(supId, 'appointment'), 1)
        assert_eq(#calendar, 1)
        assert_eq(calendar[1].owner, 'PROBCID')
        assert_eq(calendar[1].data.starts, base + 15 * 60)
        assert_eq(sup(supId).officer_cid, 'POCID')
        local clerk = api:ScheduleAppointment(supId, spec, { key = 'pmdt:appt:2', actor = { src = CLERK } })
        assert_eq(clerk.error, 'no_permission')
        local nokey = api:ScheduleAppointment(supId, spec, { actor = { src = OFFICER } })
        assert_eq(nokey.error, 'bad_args')
    end)

    it('records a check-in only inside a probation office and marks the appointment attended', function()
        Mock.clock = base + 5 * 60
        local far = Sup.CheckIn(supId, { actor = { src = CITIZEN } }, {})
        assert_eq(far.error, 'too_far')
        J.Rate.Forget('')
        Mock.coords[CITIZEN] = OFFICE
        local ok = Sup.CheckIn(supId, { actor = { src = CITIZEN } }, {})
        assert_true(ok.ok, 'checked in ' .. tostring(ok.error))
        assert_eq(ok.nextCheckinAt, base + 5 * 60 + 7 * 86400)
        assert_eq(tonumber(sup(supId).next_checkin_at), base + 5 * 60 + 7 * 86400)
        local appt = events(supId, 'appointment')[1]
        assert_eq(appt.state, 'attended')
        assert_eq(#events(supId, 'checkin'), 1)
        local again = Sup.CheckIn(supId, { actor = { src = CITIZEN } }, {})
        assert_eq(again.error, 'rate_limited')
    end)

    it('violation reports are keyed and never touch the order or custody', function()
        Mock.clock = base + 600
        Mock.invokingResource = 'pfm-policejob'
        local r1 = api:RecordViolation(supId, { kind = 'weapons', note = 'Pistol in waistband' }, { key = 'pj:viol:1', actor = { src = COP } })
        assert_true(r1.ok, 'reported ' .. tostring(r1.error))
        local r2 = api:RecordViolation(supId, { kind = 'weapons' }, { key = 'pj:viol:1', actor = { src = COP } })
        assert_true(r2.duplicate)
        assert_eq(r2.violationId, r1.violationId)
        local v = events(supId, 'violation')
        assert_eq(#v, 1)
        assert_eq(v[1].state, 'open')
        assert_eq(json.decode(v[1].detail).type, 'weapons')
        assert_eq(MySQL.single.await('SELECT state FROM pf_justice_orders WHERE id = ?', { orderId }).state, 'active')
        assert_eq(scalar('SELECT COUNT(*) FROM pf_justice_custody'), 0)
        assert_eq(scalar("SELECT COUNT(*) FROM pf_justice_orders WHERE kind IN ('jail', 'prison', 'remand')"), 0)
        -- mailed to the supervising officer
        local found = false
        for _, m in ipairs(mails) do if m.cid == 'POCID' and m.opts.ref == ('pf-justice:supviol:%d'):format(r1.violationId) then found = true end end
        assert_true(found, 'officer mailed')
        -- read filter: a default caller sees no violations, the MDT does
        Mock.invokingResource = 'pf-citizen'
        local open = api:GetSupervision('PROBCID')
        assert_true(open.ok and open.supervision ~= nil)
        assert_eq(open.supervision.violations, nil)
        Mock.invokingResource = 'pf-policemdt-DEV'
        local full = api:GetSupervision('PROBCID')
        assert_eq(#full.supervision.violations, 1)
        assert_eq(#full.supervision.appointments, 1)
    end)

    it('the sweep reports a missed appointment and an overdue check-in once each', function()
        Mock.clock = base + 1000
        local r = api:ScheduleAppointment(supId, { at = base + 2000 }, { key = 'pmdt:appt:3', actor = { src = OFFICER } })
        assert_true(r.ok)
        Mock.clock = base + 5 * 60 + 7 * 86400 + 25 * 3600
        local out = Sup.Sweep(Mock.clock)
        assert_eq(out.missed, 1)
        assert_eq(out.checkins, 1)
        local again = Sup.Sweep(Mock.clock)
        assert_eq(again.missed, 0)
        assert_eq(again.checkins, 0)
        local kinds = {}
        for _, e in ipairs(events(supId, 'violation')) do kinds[json.decode(e.detail).type] = (kinds[json.decode(e.detail).type] or 0) + 1 end
        assert_eq(kinds.missed_appointment, 1)
        assert_eq(kinds.missed_checkin, 1)
        assert_true(tonumber(sup(supId).next_checkin_at) > Mock.clock - 24 * 3600, 'due date moved on')
    end)

    it('the monitor reports a curfew breach once per episode, also across a restart', function()
        Mock.clock = base + 14 * 86400 -- 23:00 local
        Mock.coords[CITIZEN] = vector3(2000.0, 2000.0, 30.0)
        local before = #events(supId, 'violation')
        assert_eq(Mon.Tick(Mock.clock), 0, 'first sample is not enough')
        assert_eq(Mon.Tick(Mock.clock + 5), 1, 'second sample reports')
        assert_eq(Mon.Tick(Mock.clock + 10), 0, 'same episode')
        Mon.breach = {} -- restart: memory lost, the database guard holds
        Mon.Tick(Mock.clock + 15)
        Mon.Tick(Mock.clock + 20)
        local v = events(supId, 'violation')
        assert_eq(#v, before + 1)
        local d = json.decode(v[#v].detail)
        assert_eq(d.type, 'curfew')
        assert_eq(d.source, 'monitor')
        assert_eq(MySQL.single.await('SELECT state FROM pf_justice_orders WHERE id = ?', { orderId }).state, 'active')
        -- no-go zone at any hour
        Mock.coords[CITIZEN] = vector3(1010.0, 1000.0, 30.0)
        Mon.Tick(Mock.clock + 25)
        Mon.Tick(Mock.clock + 30)
        local last = events(supId, 'violation')
        assert_eq(json.decode(last[#last].detail).type, 'no_go')
    end)

    it('SetMonitor places a house the citizen owns, and refuses one they do not', function()
        MySQL.query.await("INSERT INTO houselocations (name, label, coords, owned, price, tier) VALUES ('grove1', 'Grove St 1', ?, 1, 1000, 1)",
            { json.encode({ enter = { x = 120.0, y = -1900.0, z = 25.0, h = 0 } }) })
        Mock.invokingResource = 'pf-policemdt-DEV'
        local no = api:SetMonitor('PROBCID', { mode = 'home', house = 'grove1' }, { actor = { src = OFFICER } })
        assert_eq(no.error, 'bad_args')
        owned = { { house = 'grove1', citizenid = 'PROBCID', value = 1000, label = 'Grove St 1' } }
        local yes = api:SetMonitor('PROBCID', { mode = 'home', house = 'grove1' }, { actor = { src = OFFICER } })
        assert_true(yes.ok, 'monitor set ' .. tostring(yes.error))
        local m = json.decode(sup(supId).monitor)
        assert_eq(m.mode, 'home')
        assert_eq(m.home.house, 'grove1')
        assert_near(m.home.x, 120.0, 0.01)
        assert_eq(Mon.index.PROBCID.monitor.mode, 'home')
        local cop = api:SetMonitor('PROBCID', false, { actor = { src = COP } })
        assert_eq(cop.error, 'no_permission')
    end)

    it('a revoked order ends the supervision, cancels appointments and drops the monitor', function()
        Mock.invokingResource = 'pf-policemdt-DEV'
        local r = api:ScheduleAppointment(supId, { at = Mock.clock + 3600 }, { key = 'pmdt:appt:4', actor = { src = OFFICER } })
        assert_true(r.ok)
        Mock.invokingResource = nil
        local res = J.API.SetOrderState(orderId, 'revoked', { reason = 'court revoked probation' })
        assert_true(res.ok, 'revoked ' .. tostring(res.error))
        local row = sup(supId)
        assert_eq(row.state, 'revoked')
        assert_true(tonumber(row.ended_at) ~= nil)
        assert_eq(scalar("SELECT COUNT(*) FROM pf_justice_supervision_events WHERE supervision_id = ? AND kind = 'appointment' AND state = 'scheduled'", { supId }), 0)
        assert_eq(Mon.index.PROBCID, nil)
    end)

    it('the boot reconcile creates a missing row and follows an order that changed meanwhile', function()
        Mock.clock = base + 20 * 86400
        local res = probation('court:2', { { kind = 'checkin', everyDays = 3 } }, 10)
        assert_true(res.ok)
        local id2 = res.orderId
        MySQL.query.await('DELETE FROM pf_justice_supervision WHERE order_id = ?', { id2 })
        local out = Sup.Reconcile()
        assert_eq(out.created, 1)
        local row = MySQL.single.await('SELECT * FROM pf_justice_supervision WHERE order_id = ?', { id2 })
        assert_eq(row.state, 'active')
        -- the order completes while the event is lost
        MySQL.query.await("UPDATE pf_justice_orders SET state = 'completed' WHERE id = ?", { id2 })
        out = Sup.Reconcile()
        assert_eq(out.followed, 1)
        assert_eq(MySQL.single.await('SELECT state FROM pf_justice_supervision WHERE order_id = ?', { id2 }).state, 'completed')
    end)
end)
