-- Corrections MDT app (batch 21E): pfm-prison server/apps.lua on top of the real facility,
-- schedule, discipline, visitation and security modules (pf-justice, pf-devices, the inventory and
-- the doors are stubbed by their contracts, as in b19_prison_facility_spec). Covers:
--   * registration on pf-devices (module entry, styles, corrections on duty) and every handler;
--   * every handler reads job, duty and grade again (reads too: population, inmate, trust);
--   * the `can` answer per grade (housing / hearing / lockdown / trust);
--   * population: names (online characters, then the players table), filter, sort, server paging;
--   * one inmate: placement, sentence from pf-justice GetActiveIncarceration (and its absence),
--     infractions, work, trust only for the trust grade, cells the inmate may move to;
--   * cells, assign / out of service, classification relayed with the actor;
--   * routine, headcount history, an officer's count (inside the walls only);
--   * infractions paged; report with a server-made hearing time; schedule; hearing with sanctions;
--   * visits board, search (distance is the module's), cancel; lockdown through security.lua (doors
--     and gates locked, grade 3); alarms cleared; cameras listed (no camera is shown).
load_resource('tests/lua/ledger_env.lua')
QBCore = QBCoreMock
vec2 = vector2

function AddEventHandler(name, fn)
    local prev = Mock.eventHandlers[name]
    if prev then
        Mock.eventHandlers[name] = function(...) prev(...) fn(...) end
    else
        Mock.eventHandlers[name] = fn
    end
end
function LoadResourceFile(res, file)
    if res == 'pf-justice' and file == 'config.lua' then
        return 'Config = Config or {}\nConfig.Compat = { LegacyRuntimes = { mdt = false, prison = false, policejob = false } }\n'
    end
    return nil
end
function SetEntityCoords(ped, x, y, z) Mock.coords[ped] = vector3(x, y, z + 0.9) end
local function copy(o) local t = {} for k, v in pairs(o) do t[k] = v end return t end

-- ── pf-justice (contract) ──────────────────────────────────────────────────────────────────────
local JU = {}
local function resetJU() JU.orders, JU.n, JU.calls, JU.down = {}, 0, {}, false end
resetJU()
local function openOf(cid)
    local out = {}
    for _, o in ipairs(JU.orders) do
        if o.cid == cid and (o.state == 'active' or o.state == 'pending' or o.state == 'suspended') then out[#out + 1] = o end
    end
    return out
end
Mock.exportsByResource['pf-justice'] = {
    GetOrders = function(_, cid)
        local list = {}
        for _, o in ipairs(JU.orders) do if o.cid == cid then list[#list + 1] = copy(o) end end
        return { ok = true, list = list }
    end,
    GetActiveIncarceration = function(_, who)
        JU.calls[#JU.calls + 1] = { name = 'GetActiveIncarceration', who = who }
        if JU.down then return { ok = false, error = 'db_unavailable' } end
        local o = openOf(who)[1]
        if not o then return { ok = true, remainingSeconds = 0 } end
        return { ok = true, order = copy(o), remainingSeconds = o.remainingSeconds, facility = o.facility }
    end,
    GetJailMinutes = function() return 0 end,
    AdjustOrder = function(_, id, change, opts)
        JU.calls[#JU.calls + 1] = { name = 'AdjustOrder', id = id, change = change, opts = opts }
        return { ok = true, applied = change.seconds }
    end,
    SeizeProperty = function(_, src)
        Mock.players[src].PlayerData.items = {}
        JU.n = JU.n + 1
        return { ok = true, receiptId = JU.n }
    end,
    ReturnProperty = function() return { ok = true } end,
    SetOrderState = function() return { ok = true } end,
}

-- ── inventory, doors, pf-devices ───────────────────────────────────────────────────────────────
Mock.exportsByResource['pfm-inventory'] = {
    AddItem = function() return true end, RemoveItem = function() return true end,
    HasItem = function() return false end, ClearInventory = function() end, GetItemsByName = function() return {} end,
}
local doors = {}
Mock.exportsByResource['pfm-doorlock'] = {
    SetDoorState = function(_, id, locked) doors[#doors + 1] = { id = id, locked = locked } return { ok = true, locked = locked, changed = true } end,
    GetDoorState = function(_, id) for i = #doors, 1, -1 do if doors[i].id == id then return doors[i].locked end end return nil end,
}
local devices = { apps = {}, handlers = {} }
Mock.exportsByResource['pf-devices'] = {
    RegisterApp = function(_, def) devices.apps[def.id] = def return true end,
    RegisterAppHandlers = function(_, id, map) devices.handlers[id] = map return true end,
}

-- ── pf_prison_* and players on a tiny in-memory store ──────────────────────────────────────────
local Tb
local function resetTables()
    Tb = { inmates = {}, events = {}, oos = {}, inf = {}, infN = 0, priv = {}, counts = {}, countN = 0, visits = {}, visitN = 0,
        work = {}, tx = {}, players = {}, playerQueries = 0 }
end
resetTables()
local function infList(pred, desc)
    local out = {}
    for i = 1, Tb.infN do local r = Tb.inf[i] if r and pred(r) then out[#out + 1] = copy(r) end end
    if desc then table.sort(out, function(a, b) return a.id > b.id end) end
    return out
end
local function page(list, p) local out = {} for i = p[2] + 1, math.min(#list, p[2] + p[1]) do out[#out + 1] = list[i] end return out end
local function visitList(pred)
    local out = {}
    for i = 1, Tb.visitN do local r = Tb.visits[i] if r and pred(r) then out[#out + 1] = copy(r) end end
    return out
end
local OPENV = { booked = true, checked_in = true, in_progress = true }
local OPENI = { reported = true, hearing_scheduled = true }
local CLOSEDI = { heard = true, sanctioned = true, dismissed = true }
FakeDB.extraPatterns = {
    -- the app's own reads (apps.lua)
    { 'FROM players WHERE citizenid IN', function(p)
        Tb.playerQueries = Tb.playerQueries + 1
        local out = {}
        for _, cid in ipairs(p) do if Tb.players[cid] then out[#out + 1] = { citizenid = cid, charinfo = Tb.players[cid] } end end
        return out
    end },
    { "('reported', 'hearing_scheduled') ORDER BY id LIMIT ? OFFSET ?", function(p) return page(infList(function(r) return OPENI[r.state] end), p) end },
    { "('heard', 'sanctioned', 'dismissed') ORDER BY id DESC LIMIT ? OFFSET ?", function(p) return page(infList(function(r) return CLOSEDI[r.state] end, true), p) end },
    { 'FROM pf_prison_infractions ORDER BY id DESC LIMIT ? OFFSET ?', function(p) return page(infList(function() return true end, true), p) end },
    { 'FROM pf_prison_work_log WHERE citizenid = ?', function(p)
        local out = {}
        for i = #Tb.work, 1, -1 do if Tb.work[i].citizenid == p[1] then out[#out + 1] = copy(Tb.work[i]) end end
        return out
    end },
    { 'GROUP BY citizenid HAVING bal > 0', function()
        local sums = {}
        for _, r in ipairs(Tb.tx) do
            if r.ledger_state == 'completed' or r.ledger_state == 'internal' then sums[r.citizenid] = (sums[r.citizenid] or 0) + r.amount end
        end
        local out = {}
        for cid, bal in pairs(sums) do if bal > 0 then out[#out + 1] = { citizenid = cid, bal = bal } end end
        table.sort(out, function(a, b) return a.bal > b.bal end)
        return out
    end },
    { 'FROM pf_prison_account_tx WHERE citizenid = ? ORDER BY id DESC', function(p)
        local out = {}
        for i = #Tb.tx, 1, -1 do if Tb.tx[i].citizenid == p[1] then out[#out + 1] = copy(Tb.tx[i]) end end
        return out
    end },
    { 'SELECT id, due_at, closed_at, expected, present, missing, by_cid FROM pf_prison_counts', function()
        local out = {}
        for i = Tb.countN, 1, -1 do out[#out + 1] = copy(Tb.counts[i]) end
        return out
    end },
    { 'WHERE slot_at >= ? AND slot_at < ? ORDER BY slot_at', function(p)
        return visitList(function(r) return r.slot_at >= p[1] and r.slot_at < p[2] end)
    end },
    -- the modules' statements (as in b19_prison_facility_spec)
    { 'INSERT INTO pf_prison_inmates', function(p) Tb.inmates[p[1]] = { citizenid = p[1], status = p[4], cell_id = p[5], classification = p[6] } return 1 end },
    { 'DELETE FROM pf_prison_inmates', function(p) Tb.inmates[p[1]] = nil return 1 end },
    { 'SELECT * FROM pf_prison_inmates', function() return {} end },
    { 'INSERT INTO pf_prison_events', function(p)
        Tb.events[#Tb.events + 1] = { citizenid = p[1], kind = p[3], detail = p[4], actor_cid = p[5], at = p[6] }
        return #Tb.events
    end },
    { "kind = 'lockdown'", function() return {} end },
    { "kind = 'meal'", function() return {} end },
    { "kind = 'escape'", function() return 0 end },
    { 'pf_prison_escapes', function() return 0 end },
    { 'pf_prison_events', function() return 0 end },
    { 'INSERT INTO pf_prison_cells', function() return 1 end },
    { 'SELECT cell_id, out_of_service', function()
        local out = {}
        for id, v in pairs(Tb.oos) do out[#out + 1] = { cell_id = id, out_of_service = v } end
        return out
    end },
    { 'UPDATE pf_prison_cells', function(p) Tb.oos[p[3]] = p[1] return 1 end },
    { 'INSERT INTO pf_prison_infractions', function(p)
        Tb.infN = Tb.infN + 1
        Tb.inf[Tb.infN] = { id = Tb.infN, citizenid = p[1], order_id = p[2], code = p[3], severity = p[4], state = p[5], evidence_ids = p[6],
            hearing_at = p[7], reported_by = p[8], at = p[9], idem_key = p[10] }
        return Tb.infN
    end },
    { 'WHERE idem_key = ?', function(p) return infList(function(r) return r.idem_key == p[1] end) end },
    { 'FROM pf_prison_infractions WHERE id = ?', function(p) return infList(function(r) return r.id == p[1] end) end },
    { 'AND severity >= ?', function() return 0 end },
    { 'sanction LIKE', function() return {} end },
    { 'AND at <= ?', function(p) return infList(function(r) return OPENI[r.state] and r.at <= p[1] end) end },
    { 'FROM pf_prison_infractions WHERE citizenid = ?', function(p) return infList(function(r) return r.citizenid == p[1] end, true) end },
    { 'UPDATE pf_prison_infractions SET sanction = ? WHERE id = ?', function(p) Tb.inf[p[2]].sanction = p[1] return 1 end },
    { 'UPDATE pf_prison_infractions SET', function(p)
        local id, from = p[#p - 1], p[#p]
        local r = Tb.inf[id]
        if not r or r.state ~= from then return 0 end
        r.state = p[1]
        if #p == 4 then
            local v = p[2]
            if type(v) == 'number' then r.hearing_at = v elseif tostring(v):sub(1, 1) == '{' then r.sanction = v else r.heard_by = v end
        end
        return 1
    end },
    { 'DELETE FROM pf_prison_infractions', function() return 0 end },
    { "VALUES (?, 'solitary', ?, ?)", function(p) Tb.priv[#Tb.priv + 1] = { citizenid = p[1], kind = 'solitary', until_at = p[2] } return #Tb.priv end },
    { 'INSERT INTO pf_prison_privileges', function(p) Tb.priv[#Tb.priv + 1] = { citizenid = p[1], kind = p[2], until_at = p[3] } return #Tb.priv end },
    { 'FROM pf_prison_privileges', function() return {} end },
    { 'DELETE FROM pf_prison_privileges', function() return 0 end },
    { 'INSERT INTO pf_prison_counts', function(p) Tb.countN = Tb.countN + 1 Tb.counts[Tb.countN] = { id = Tb.countN, due_at = p[2], expected = p[3], present = 0 } return Tb.countN end },
    { 'UPDATE pf_prison_counts SET closed_at = ?, expected', function(p)
        local c = Tb.counts[p[6]]
        if not c or c.closed_at then return 0 end
        c.closed_at, c.expected, c.present, c.missing, c.by_cid = p[1], p[2], p[3], p[4], p[5]
        return 1
    end },
    { 'pf_prison_counts', function() return 0 end },
    { 'INSERT INTO pf_prison_visits', function(p)
        Tb.visitN = Tb.visitN + 1
        Tb.visits[Tb.visitN] = { id = Tb.visitN, inmate_cid = p[1], visitor_cid = p[2], slot_at = p[3], state = 'booked', kind = p[4], searched = 0, created_at = p[5] }
        return Tb.visitN
    end },
    { 'WHERE slot_at = ?', function(p) return visitList(function(r) return r.slot_at == p[1] and OPENV[r.state] end) end },
    { "WHERE visitor_cid = ? AND state IN ('booked', 'checked_in')", function() return 0 end },
    { "kind = 'social'", function() return 0 end },
    { 'FROM pf_prison_visits WHERE id = ?', function(p) return visitList(function(r) return r.id == p[1] end) end },
    { 'SET searched = 1', function(p) local r = Tb.visits[p[1]] if r then r.searched = 1 return 1 end return 0 end },
    { 'UPDATE pf_prison_visits SET state = ?, notes', function(p)
        local r = Tb.visits[p[3]]
        if not r or r.state ~= p[4] then return 0 end
        r.state, r.notes = p[1], p[2] or r.notes
        return 1
    end },
    { 'pf_prison_visits', function() return {} end },
    { 'pf_prison_searches', function() return {} end },
}
Mock.exportsByResource['pfm-core'].RunMigrations = function() return true end

LedgerEnv.load('pfm-prison', { 'pfm-prison/config.lua', 'pfm-prison/config_facility.lua', 'pfm-prison/server/main.lua',
    'pfm-prison/server/schema.lua', 'pfm-prison/server/justice_bridge.lua', 'pfm-prison/server/facility.lua',
    'pfm-prison/server/schedule.lua', 'pfm-prison/server/discipline.lua', 'pfm-prison/server/visitation.lua',
    'pfm-prison/server/security.lua', 'pfm-prison/server/apps.lua' })
-- the app reads its own resource's exports (GetFacilityStatus, GetSecurityStatus) by name
Mock.exportsByResource['pfm-prison'] = Mock.exportsByResource['__self']
local B, F, S, D, V, A = PFPrison.Bridge, PFPrison.Facility, PFPrison.Schedule, PFPrison.Discipline, PFPrison.Visitation, PFPrison.Apps
-- economy.lua is batch 19E's (its own spec); here its contract: Balance(cid) -> { settled, outPending, inPending, available }
local balances = {}
PFPrison.Economy = { Balance = function(cid) return balances[cid] end }

local MIDDLE = Config.Locations.middle
local function at(dx, dy) return vector3(MIDDLE.x + dx, MIDDLE.y + dy, MIDDLE.z) end
local OUTSIDE = vector3(0, 0, 0)
local GATEHOUSE = Config.Security.ControlPoints[1].coords
local T0 = os.time({ year = 2026, month = 11, day = 17, hour = 12, min = 0, sec = 0 })

local function citizen(src, cid, job, grade, first, last)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.job = { name = job or 'unemployed', onduty = true, grade = { level = grade or 0, name = 'Rank ' .. tostring(grade or 0) } }
    p.PlayerData.charinfo = { firstname = first or 'First' .. src, lastname = last or 'Last' .. src }
    p.SetJobDuty = function(on) p.PlayerData.job.onduty = on end
    p.Functions.SetJobDuty = p.SetJobDuty
    Mock.players[src] = p
    Mock.coords[src] = OUTSIDE
    return p
end
local function officer(src, grade) local p = citizen(src, 'CO' .. src, 'corrections', grade, 'Officer', 'No' .. src) Mock.coords[src] = at(2, 2) return p end
local function jail(src, minutes, extra)
    local cid = Mock.players[src].PlayerData.citizenid
    JU.n = JU.n + 1
    local o = { id = 100 + JU.n, cid = cid, kind = 'prison', state = 'active', facility = 'bolingbroke', requiredSeconds = minutes * 60,
        servedSeconds = 60, creditSeconds = 120, forfeitSeconds = 0, remainingSeconds = minutes * 60 - 180 }
    for k, v in pairs(extra or {}) do o[k] = v end
    JU.orders[#JU.orders + 1] = o
    Mock.coords[src] = at(math.random(-20, 20), math.random(-20, 20))
    TriggerEvent('pf-justice:server:orderCreated', copy(o))
    B.Pump()
    return o
end
--- an offline inmate held here (a pf_prison_inmates row, as after a restart)
local function heldOffline(cid, cell, class, admitted)
    B.rows[cid] = { citizenid = cid, order_id = 900, facility = 'bolingbroke', status = 'in_cell', cell_id = cell,
        classification = class or 'medium', admitted_at = admitted or T0, status_at = T0, receipt_ids = {} }
end
local function call(method, src, payload)
    -- through the pf-devices boundary: the payload arrives as a copy
    local fn = devices.handlers.corrections[method]
    assert_true(fn ~= nil, 'handler ' .. method)
    return Mock.cross(fn, src, payload or {})
end
local function clientEvents(name, target)
    local out = {}
    for _, e in ipairs(Mock.clientEventsNamed(name)) do if target == nil or e.target == target then out[#out + 1] = e end end
    return out
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players, Mock.coords = {}, {}
    Mock.clock = T0
    resetJU()
    resetTables()
    doors = {}
    balances = {}
    for k in pairs(B.rows) do B.rows[k] = nil end
    B.queue, B.actions, B.credits, B.pending, B.escapees, B.needSeize, B.loadAt = {}, {}, {}, {}, {}, {}, {}
    F.activity, F.intakeAt, F.locks, F.rates, F.lockdown = {}, {}, {}, {}, { on = false }
    S.lastKey, S.openCount, S.countKey, S.served, S.mealProvider = nil, nil, nil, { cids = {} }, nil
    D.priv, D.pending, D.nextTickAt, D.lastOfficerAt = {}, {}, 0, T0
    V.active = {}
    PFPrison.Security.alarms = {}
    A.names = {}
    Mock.gameTimer = (Mock.gameTimer or 0) + 100000
    B.ResetMode()
    B.Boot()
    F.Boot(T0)
    devices.apps, devices.handlers = {}, {}
    A.Register()
end
local function later(s) Mock.gameTimer = Mock.gameTimer + (s or 5) * 1000 Mock.clock = Mock.clock + (s or 5) end

describe('21E registration', function()
    it('registers the corrections module app for corrections on duty, with every handler', function()
        local def = devices.apps.corrections
        assert_true(def ~= nil)
        assert_eq(def.kind, 'module')
        assert_eq(def.entry, 'html/apps/corrections.js')
        assert_eq(def.styles[1], 'html/apps/corrections.css')
        assert_eq(def.access.jobs.corrections, 0)
        assert_true(def.access.onduty)
        for _, m in ipairs({ 'init', 'status', 'population', 'inmate', 'cells', 'assignCell', 'setCellService', 'setClassification', 'schedule',
            'conductCount', 'infractions', 'reportInfraction', 'scheduleHearing', 'holdHearing', 'visits', 'visitSearch', 'visitCancel',
            'security', 'setLockdown', 'clearAlarm', 'cameras', 'trust' }) do
            assert_true(devices.handlers.corrections[m] ~= nil, m)
        end
    end)
    it('pf-devices restarting registers it again', function()
        devices.apps = {}
        TriggerEvent('pf-devices:server:ready')
        assert_true(devices.apps.corrections ~= nil)
    end)
end)

describe('21E who may read and act (re-read on the server)', function()
    it('refuses everyone but on-duty corrections staff on every read', function()
        citizen(1, 'INA')
        jail(1, 30)
        citizen(5, 'COP5', 'police', 4)
        local off = officer(6, 5)
        off.PlayerData.job.onduty = false
        for _, m in ipairs({ 'init', 'status', 'population', 'cells', 'schedule', 'infractions', 'visits', 'security', 'cameras', 'trust' }) do
            assert_eq(call(m, 5).error, 'no_permission', m)
            assert_eq(call(m, 6).error, 'not_on_duty', m)
        end
        assert_eq(call('inmate', 5, { cid = 'INA' }).error, 'no_permission')
        assert_eq(#JU.calls, 0) -- the sentence was never read for them
    end)
    it('answers what each grade may do, and the actions check the grade again', function()
        officer(7, 1)
        local can = call('init', 7).can
        assert_false(can.housing)
        assert_false(can.hearing)
        assert_false(can.lockdown)
        assert_true(can.trust)
        assert_true(can.report)
        officer(8, 3)
        can = call('init', 8).can
        assert_true(can.housing and can.hearing and can.lockdown and can.trust)
        officer(9, 0)
        assert_false(call('init', 9).can.trust)
        assert_eq(call('trust', 9).error, 'no_permission')
        assert_eq(call('setLockdown', 7, { on = true, reason = 'x' }).error, 'no_permission')
        assert_false(F.lockdown.on)
        assert_eq(#doors, 0)
        assert_eq(call('setCellService', 7, { cellId = 'A101', outOfService = true }).error, 'no_permission')
        assert_false(F.cells.A101.outOfService)
        assert_eq(call('scheduleHearing', 7, { id = 1, inMinutes = 10 }).error, 'no_permission')
    end)
    it('init carries the facility status, the codes, privileges, classes and limits', function()
        officer(8, 3)
        local res = call('init', 8)
        assert_true(res.ok)
        assert_eq(res.me.name, 'Officer No8')
        assert_eq(res.status.facility, 'bolingbroke')
        assert_eq(res.status.cells.total, 19)
        assert_eq(res.codes[1].code, 'P-100')
        assert_eq(res.codes[1].label, 'Disobeying an order')
        assert_eq(res.classes[3], 'max')
        assert_eq(res.limits.maxSolitaryMinutes, 60)
        assert_true(#res.privileges == 5)
        assert_eq(res.blocks[1], 'A')
    end)
end)

describe('21E population', function()
    it('names come from online characters, then one players query; filter, sort and pages are the server\'s', function()
        officer(9, 0)
        citizen(1, 'INA', nil, nil, 'Alice', 'Zed')
        jail(1, 30)
        for i = 1, 29 do
            local cid = ('OFF%02d'):format(i)
            heldOffline(cid, nil, i <= 10 and 'max' or 'medium', T0 + i)
            if i ~= 7 then Tb.players[cid] = json.encode({ firstname = 'Bob', lastname = ('Off%02d'):format(i) }) end
        end
        local res = call('population', 9, {})
        assert_true(res.ok)
        assert_eq(res.total, 30)
        assert_eq(res.pages, 2)
        assert_eq(#res.inmates, 25)
        assert_eq(Tb.playerQueries, 1)
        -- the name cache spares the next page a query
        local p2 = call('population', 9, { page = 2 })
        assert_eq(#p2.inmates, 5)
        assert_eq(Tb.playerQueries, 1)
        -- search by name, by cid; the offline inmate without a players row is still found by cid
        local q = call('population', 9, { q = 'alice' })
        assert_eq(q.total, 1)
        assert_eq(q.inmates[1].name, 'Alice Zed')
        assert_true(q.inmates[1].online)
        assert_true(q.inmates[1].cellId ~= nil)
        q = call('population', 9, { q = 'off07' })
        assert_eq(q.total, 1)
        assert_eq(q.inmates[1].name, nil)
        -- classification filter and sort by name
        q = call('population', 9, { classification = 'max', sort = 'name' })
        assert_eq(q.total, 10)
        assert_eq(q.inmates[1].name, 'Bob Off01')
        -- status filter: the intake status of a fresh inmate
        q = call('population', 9, { status = 'intake' })
        assert_eq(q.total, 1)
        -- bad filter values are ignored, a page past the end is the last page
        q = call('population', 9, { status = '<x>', classification = 'nope', sort = 'drop', page = 99 })
        assert_eq(q.page, 2)
    end)
end)

describe('21E one inmate', function()
    it('shows placement, the pf-justice sentence, infractions, work, trust (by grade) and the cells to move to', function()
        officer(9, 1)
        citizen(1, 'INA', nil, nil, 'Alice', 'Zed')
        jail(1, 30, { charges = { { code = 'PC-1', label = 'Robbery', count = 2 } } })
        Tb.work[#Tb.work + 1] = { citizenid = 'INA', job = 'kitchen', credit_seconds = 300, wage = 25, at = T0 }
        balances.INA = { settled = 140, outPending = 10, inPending = 25, available = 130 }
        Tb.tx[#Tb.tx + 1] = { citizenid = 'INA', kind = 'earning', amount = 25, ledger_state = 'completed', at = T0 }
        local res = call('inmate', 9, { cid = 'INA' })
        assert_true(res.ok)
        assert_eq(res.inmate.name, 'Alice Zed')
        assert_eq(res.inmate.classification, 'min')
        assert_eq(res.sentence.orderId, 101)
        assert_eq(res.sentence.requiredSeconds, 1800)
        assert_eq(res.sentence.creditSeconds, 120)
        assert_eq(res.sentence.timeToRelease, 1620)
        assert_eq(res.sentence.charges[1].label, 'Robbery')
        assert_eq(res.sentence.charges[1].count, 2)
        assert_eq(res.work[1].job, 'kitchen')
        assert_eq(res.trust.balance, 130)
        assert_eq(res.trust.incoming, 25)
        assert_eq(res.trust.recent[1].kind, 'earning')
        -- moves: in service, of the inmate's class or higher, with room, not the current cell
        local seen = {}
        for _, c in ipairs(res.cellOptions) do seen[c.id] = true end
        assert_false(seen[res.inmate.cellId] == true)
        assert_true(seen.C101 == true)
        -- a cadet does not see the trust account
        officer(8, 0)
        assert_eq(call('inmate', 8, { cid = 'INA' }).trust, nil)
        -- pf-justice not answering: said so, not a fake clock
        JU.down = true
        assert_false(call('inmate', 9, { cid = 'INA' }).sentence.available)
        assert_eq(call('inmate', 9, { cid = 'NOBODY' }).error, 'not_found')
        assert_eq(call('inmate', 9, { cid = '<img>' }).error, 'bad_args')
    end)
    it('a medium inmate is never offered a min cell', function()
        officer(9, 2)
        heldOffline('MED1', 'B101', 'medium')
        local res = call('inmate', 9, { cid = 'MED1' })
        for _, c in ipairs(res.cellOptions) do assert_true(c.classification ~= 'min', c.id) end
    end)
end)

describe('21E cells and housing', function()
    it('lists occupants by name and the overflow; moves and service changes go through the facility with the actor', function()
        officer(9, 2)
        citizen(1, 'INA', nil, nil, 'Alice', 'Zed')
        jail(1, 30)
        heldOffline('OVR', nil, 'max')
        Tb.players.OVR = json.encode({ firstname = 'Over', lastname = 'Flow' })
        local res = call('cells', 9)
        assert_true(res.ok)
        assert_eq(#res.cells, 11)
        local cellA = B.rows.INA.cell_id
        local found
        for _, c in ipairs(res.cells) do if c.id == cellA then found = c end end
        assert_eq(found.occupants[1].name, 'Alice Zed')
        assert_eq(res.overflow[1].cid, 'OVR')
        assert_eq(res.overflow[1].name, 'Over Flow')
        -- move: the facility's rule (class) still decides
        assert_eq(call('assignCell', 9, { cid = 'OVR', cellId = 'A102' }).error, 'invalid_state') -- a max inmate never goes to a min cell
        later(2)
        local mv = call('assignCell', 9, { cid = 'INA', cellId = 'C101' })
        assert_true(mv.ok)
        assert_eq(B.rows.INA.cell_id, 'C101')
        later(2)
        assert_eq(call('assignCell', 9, { cid = 'INA', cellId = 'ZZZ' }).error, 'bad_args')
        -- out of service moves the occupant; logged with the officer
        later(2)
        local oos = call('setCellService', 9, { cellId = 'C101', outOfService = true })
        assert_true(oos.ok)
        assert_eq(oos.moved, 1)
        assert_true(F.cells.C101.outOfService)
        assert_true(B.rows.INA.cell_id ~= 'C101')
        local last = Tb.events[#Tb.events]
        assert_eq(last.actor_cid, 'CO9')
        later(2)
        local cl = call('setClassification', 9, { cid = 'INA', classification = 'max', reason = 'threats' })
        assert_true(cl.ok)
        assert_eq(B.rows.INA.classification, 'max')
        assert_eq(call('setClassification', 9, { cid = 'INA', classification = 'super' }).error, 'bad_args')
    end)
end)

describe('21E routine and headcounts', function()
    it('shows the phase, the coming phases and the counts; an officer counts from inside the walls', function()
        officer(9, 0)
        citizen(1, 'INA', nil, nil, 'Alice', 'Zed')
        jail(1, 30)
        local res = call('schedule', 9)
        assert_true(res.ok)
        assert_true(res.phase.label ~= nil)
        assert_eq(#res.upcoming, #Config.Facility.Routine.Phases + 1)
        assert_true(res.upcoming[1].current)
        Mock.coords[9] = OUTSIDE
        assert_eq(call('conductCount', 9).error, 'too_far')
        Mock.coords[9] = at(1, 1)
        later(3)
        local c = call('conductCount', 9)
        assert_true(c.ok)
        assert_eq(c.present, 1)
        res = call('schedule', 9)
        assert_eq(res.counts[1].present, 1)
        assert_eq(res.counts[1].by, 'CO9')
        assert_eq(res.names.CO9, 'Officer No9')
    end)
    it('a missing inmate is named in the count result', function()
        officer(9, 0)
        Mock.coords[9] = at(1, 1)
        citizen(1, 'INA', nil, nil, 'Alice', 'Zed')
        jail(1, 30)
        Mock.coords[1] = OUTSIDE
        local c = call('conductCount', 9)
        assert_eq(c.missing[1], 'INA')
        assert_eq(c.names.INA, 'Alice Zed')
    end)
end)

describe('21E discipline', function()
    it('reports with a hearing time made from the server clock; lists, schedules and holds hearings through discipline.lua', function()
        officer(8, 0)
        officer(9, 2)
        citizen(1, 'INA', nil, nil, 'Alice', 'Zed')
        jail(1, 30)
        assert_eq(call('reportInfraction', 8, { cid = 'INA', code = 'P-999' }).error, 'bad_args')
        later(3)
        assert_eq(call('reportInfraction', 8, { cid = 'INA', code = 'P-100', evidenceIds = 'x' }).error, 'bad_args')
        later(3)
        local r = call('reportInfraction', 8, { cid = 'INA', code = 'P-300', evidenceIds = { 4, 5 }, hearingInMinutes = 10 })
        assert_true(r.ok)
        assert_eq(r.state, 'hearing_scheduled')
        assert_eq(Tb.inf[r.infractionId].hearing_at, Mock.clock + 600)
        assert_eq(Tb.inf[r.infractionId].reported_by, 'CO8')
        assert_eq(Tb.inf[r.infractionId].evidence_ids, '4,5')
        -- the open list, named
        local list = call('infractions', 9, { filter = 'open' })
        assert_true(list.ok)
        assert_eq(#list.list, 1)
        assert_eq(list.list[1].label, 'Fighting')
        assert_eq(list.names.INA, 'Alice Zed')
        assert_eq(list.names.CO8, 'Officer No8')
        assert_false(list.hasMore)
        -- reschedule: relative minutes on the server's clock; the notice rule is discipline.lua's
        later(2)
        local s = call('scheduleHearing', 9, { id = r.infractionId, inMinutes = 6 })
        assert_true(s.ok)
        assert_eq(s.hearingAt, Mock.clock + 360)
        -- the hearing: the inmate attends, the reporting officer may not hear it
        later(400)
        Mock.coords[9] = Mock.coords[1]
        assert_eq(call('holdHearing', 9, { id = r.infractionId, verdict = 'maybe' }).error, 'bad_args')
        assert_eq(call('holdHearing', 9, { id = r.infractionId, verdict = 'guilty', privileges = 'yard' }).error, 'bad_args')
        local hres = call('holdHearing', 9, { id = r.infractionId, verdict = 'guilty', note = 'seen on camera',
            forfeitMinutes = 15, privileges = { { kind = 'yard', hours = 24 } } })
        assert_true(hres.ok)
        assert_eq(hres.state, 'sanctioned')
        assert_eq(hres.sanction.forfeit.state, 'applied')
        assert_eq(Tb.priv[1].kind, 'yard')
        local adj
        for _, c in ipairs(JU.calls) do if c.name == 'AdjustOrder' then adj = c end end
        assert_eq(adj.opts.key, ('pfm-prison:discipline:%d:forfeit'):format(r.infractionId))
        -- decided list
        local closed = call('infractions', 9, { filter = 'closed' })
        assert_eq(closed.list[1].state, 'sanctioned')
        assert_eq(#call('infractions', 9, { filter = 'open' }).list, 0)
    end)
    it('pages the list 25 at a time', function()
        officer(9, 2)
        for i = 1, 27 do
            Tb.infN = Tb.infN + 1
            Tb.inf[Tb.infN] = { id = Tb.infN, citizenid = 'X' .. i, code = 'P-100', severity = 1, state = 'reported', at = T0 }
        end
        local p1 = call('infractions', 9, { filter = 'open', page = 1 })
        assert_eq(#p1.list, 25)
        assert_true(p1.hasMore)
        local p2 = call('infractions', 9, { filter = 'open', page = 2 })
        assert_eq(#p2.list, 2)
        assert_false(p2.hasMore)
        assert_eq(p2.list[1].id, 26)
    end)
end)

describe('21E visits', function()
    it('the board names both sides; a search needs the officer with the visitor; staff cancel', function()
        officer(9, 0)
        citizen(1, 'INA', nil, nil, 'Alice', 'Zed')
        jail(1, 30)
        citizen(2, 'VIS', nil, nil, 'Vera', 'Visitor')
        local slot = 20 * 60
        local slotAt = math.ceil((T0 + 3600) / slot) * slot
        Tb.visitN = 1
        Tb.visits[1] = { id = 1, inmate_cid = 'INA', visitor_cid = 'VIS', slot_at = slotAt, state = 'booked', kind = 'social', searched = 0, created_at = T0 }
        local res = call('visits', 9)
        assert_true(res.ok)
        assert_eq(res.visits[1].id, 1)
        assert_eq(res.names.VIS, 'Vera Visitor')
        assert_eq(res.names.INA, 'Alice Zed')
        Mock.coords[2] = OUTSIDE
        assert_eq(call('visitSearch', 9, { id = 1, allow = true }).error, 'too_far')
        Mock.coords[2] = Mock.coords[9]
        later(2)
        assert_true(call('visitSearch', 9, { id = 1, allow = true }).searched)
        assert_eq(Tb.visits[1].searched, 1)
        later(2)
        assert_true(call('visitCancel', 9, { id = 1 }).ok)
        assert_eq(Tb.visits[1].state, 'cancelled')
        assert_eq(call('visitCancel', 9, { id = 'x' }).error, 'bad_args')
    end)
end)

describe('21E lockdown, alarms, cameras', function()
    it('a sergeant locks down through security.lua (gates and security doors locked, alarm raised) and ends it', function()
        officer(9, 3)
        local res = call('setLockdown', 9, { on = true, reason = 'riot in B', minutes = 30 })
        assert_true(res.ok)
        assert_true(F.lockdown.on)
        assert_eq(F.lockdown.by, 'CO9')
        assert_true(res.doorsLocked == #Config.Security.Doors)
        local sec = call('security', 9)
        assert_true(sec.lockdown)
        assert_eq(sec.lockdownReason, 'riot in B')
        assert_eq(sec.lockdownBy, 'CO9')
        assert_eq(sec.names.CO9, 'Officer No9')
        assert_eq(sec.alarms[#sec.alarms].kind, 'lockdown')
        assert_true(sec.doors[1].locked)
        assert_eq(call('setLockdown', 9, { on = true, minutes = 9999 }).error, 'bad_args')
        -- clear the alarm, end the lockdown (the facility's own rate limit applies)
        assert_true(call('clearAlarm', 9, { id = sec.alarms[#sec.alarms].id }).ok)
        assert_eq(#call('security', 9).alarms, 0)
        later(6)
        assert_true(call('setLockdown', 9, { on = false }).ok)
        assert_false(F.lockdown.on)
    end)
    it('lists the camera points and the control point; it never shows a camera', function()
        officer(9, 0)
        local res = call('cameras', 9)
        assert_true(res.ok)
        assert_eq(#res.cameras, #Config.Security.Cameras)
        assert_eq(res.cameras[1].label, 'Front gate')
        assert_eq(res.controlPoints[1], 'Gatehouse')
        assert_eq(#clientEvents('prison:client:ViewCamera'), 0)
    end)
end)

describe('21E trust accounts (read only)', function()
    it('lists accounts with money, named, and one account in detail', function()
        officer(9, 1)
        citizen(1, 'INA', nil, nil, 'Alice', 'Zed')
        jail(1, 30)
        Tb.tx = {
            { citizenid = 'INA', kind = 'deposit', amount = 100, ledger_state = 'completed', at = T0 },
            { citizenid = 'INA', kind = 'purchase', amount = -20, ledger_state = 'completed', at = T0 + 1 },
            { citizenid = 'OLD', kind = 'earning', amount = 50, ledger_state = 'completed', at = T0 },
            { citizenid = 'OLD', kind = 'deposit', amount = 999, ledger_state = 'failed', at = T0 },
        }
        Tb.players.OLD = json.encode({ firstname = 'Old', lastname = 'Timer' })
        local res = call('trust', 9)
        assert_true(res.ok)
        assert_eq(#res.accounts, 2)
        assert_eq(res.accounts[1].cid, 'INA')
        assert_eq(res.accounts[1].balance, 80)
        assert_true(res.accounts[1].held)
        assert_false(res.accounts[2].held)
        assert_eq(res.total, 130)
        assert_eq(res.names.OLD, 'Old Timer')
        balances.INA = { settled = 80, outPending = 0, inPending = 0, available = 80 }
        local one = call('trust', 9, { cid = 'INA' })
        assert_true(one.ok)
        assert_eq(one.balance, 80)
        assert_eq(one.recent[1].kind, 'purchase')
        assert_eq(call('trust', 9, { cid = 'NOACC' }).error, 'unavailable')
    end)
end)
