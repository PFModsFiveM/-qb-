-- Prison facility operations (batch 19D): server/facility.lua, schedule.lua, discipline.lua and
-- visitation.lua on top of the batch-16 bridge (pf-justice stubbed by its contract, as in
-- b16_prison_justice_spec). The pf_prison_* statements run on a small in-memory table set below;
-- the real SQL is covered by realdb_specs/b19_prison_facility_realdb_spec.lua.
--   * intake: classification by time to serve, a cell of that class or higher (never lower), the
--     uniform item, overflow when full; release takes the uniform back;
--   * GetInmate / GetFacilityStatus carry cell, activity, next count, cell totals;
--   * routine: activities by phase and privilege, counts only with an inmate online, an officer's
--     count (on duty, inside), meals once per meal per inmate inside the walls;
--   * discipline (architecture 5.13): staff report, notice period, impartial officer of the hearing
--     grade, attendance, forfeit through AdjustOrder with its key, solitary, automatic hearings only
--     restrict privileges, RecordInfraction caller list;
--   * visitation: privileges, attorney right, hours, desk, search when staffed, room presence,
--     leaving ends the visit, lockdown ends it, no-show;
--   * SetLockdown: staff grade, caller list, gates locked through SetDoorState, expiry.
load_resource('tests/lua/ledger_env.lua')
QBCore = QBCoreMock
vec2 = vector2

-- FiveM runs every handler of an event; the shared mock keeps one per name, so chain them here
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

-- ── pf-justice stand-in (contract only) ────────────────────────────────────────────────────────
local JU = {}
local function resetJU() JU.orders, JU.n, JU.calls, JU.adjustAnswer = {}, 0, {}, nil end
resetJU()
local function jcalls(name)
    local out = {}
    for _, c in ipairs(JU.calls) do if c.name == name then out[#out + 1] = c end end
    return out
end
local function openOf(cid)
    local out = {}
    for _, o in ipairs(JU.orders) do
        if o.cid == cid and (o.state == 'active' or o.state == 'pending' or o.state == 'suspended') then out[#out + 1] = o end
    end
    return out
end
local function cidOfWho(who)
    if type(who) == 'number' then return Mock.players[who] and Mock.players[who].PlayerData.citizenid end
    return who
end
Mock.exportsByResource['pf-justice'] = {
    GetOrders = function(_, cid)
        local list = {}
        for _, o in ipairs(JU.orders) do if o.cid == cid then list[#list + 1] = copy(o) end end
        return { ok = true, list = list }
    end,
    GetJailMinutes = function(_, who)
        for _, o in ipairs(openOf(cidOfWho(who))) do if o.state == 'active' then return math.ceil(o.requiredSeconds / 60) end end
        return 0
    end,
    AdjustOrder = function(_, id, change, opts)
        JU.calls[#JU.calls + 1] = { name = 'AdjustOrder', id = id, change = change, opts = opts }
        if JU.adjustAnswer then return JU.adjustAnswer end
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

-- ── inventory, doors ───────────────────────────────────────────────────────────────────────────
local inv = {}
local function resetInv() inv.items, inv.adds, inv.removes = {}, {}, {} end
resetInv()
local function holds(src, name) return (inv.items[src] or {})[name] or 0 end
Mock.exportsByResource['pfm-inventory'] = {
    AddItem = function(_, src, name, amount)
        inv.items[src] = inv.items[src] or {}
        inv.items[src][name] = (inv.items[src][name] or 0) + amount
        inv.adds[#inv.adds + 1] = { src = src, name = name, amount = amount }
        return true
    end,
    RemoveItem = function(_, src, name, amount)
        if holds(src, name) < amount then return false end
        inv.items[src][name] = inv.items[src][name] - amount
        inv.removes[#inv.removes + 1] = { src = src, name = name }
        return true
    end,
    HasItem = function(_, src, name) return holds(src, name) > 0 end,
    ClearInventory = function() end,
}
local doors = {}
Mock.exportsByResource['pfm-doorlock'] = {
    SetDoorState = function(_, id, locked) doors[#doors + 1] = { id = id, locked = locked } return { ok = true, locked = locked, changed = true } end,
}
QBCoreMock.Shared.Items.prison_uniform = { name = 'prison_uniform', label = 'Prison uniform' }

-- ── pf_prison_* on a tiny in-memory store ──────────────────────────────────────────────────────
local Tb
local function resetTables()
    Tb = { inmates = {}, events = {}, oos = {}, inf = {}, infN = 0, priv = {}, counts = {}, countN = 0, visits = {}, visitN = 0, escapes = {} }
end
resetTables()
local function infList(pred)
    local out = {}
    for i = 1, Tb.infN do local r = Tb.inf[i] if r and pred(r) then out[#out + 1] = copy(r) end end
    return out
end
local function visitList(pred)
    local out = {}
    for i = 1, Tb.visitN do local r = Tb.visits[i] if r and pred(r) then out[#out + 1] = copy(r) end end
    return out
end
local OPENV = { booked = true, checked_in = true, in_progress = true }
FakeDB.extraPatterns = {
    { 'INSERT INTO pf_prison_inmates', function(p) Tb.inmates[p[1]] = { citizenid = p[1], status = p[4], cell_id = p[5], classification = p[6] } return 1 end },
    { 'DELETE FROM pf_prison_inmates', function(p) Tb.inmates[p[1]] = nil return 1 end },
    { 'SELECT * FROM pf_prison_inmates', function() return {} end },
    { 'INSERT INTO pf_prison_events', function(p)
        Tb.events[#Tb.events + 1] = { citizenid = p[1], kind = p[3], detail = p[4], actor_cid = p[5], at = p[6] }
        return #Tb.events
    end },
    { "kind = 'lockdown'", function()
        for i = #Tb.events, 1, -1 do
            local e = Tb.events[i]
            if e.kind == 'lockdown' and tostring(e.detail):find('"manual":true', 1, true) then return { e } end
        end
        return {}
    end },
    { "kind = 'meal'", function() return {} end },
    { "kind = 'escape'", function() return 0 end },
    { 'pf_prison_escapes', function(p) return Tb.escapes[p[1]] or 0 end },
    { 'pf_prison_events', function() return 0 end },
    { 'INSERT INTO pf_prison_cells', function() return 1 end },
    { 'SELECT cell_id, out_of_service', function()
        local out = {}
        for id, v in pairs(Tb.oos) do out[#out + 1] = { cell_id = id, out_of_service = v } end
        return out
    end },
    { 'UPDATE pf_prison_cells', function(p) Tb.oos[p[3]] = p[1] return 1 end },
    -- infractions
    { 'INSERT INTO pf_prison_infractions', function(p)
        if p[10] then for i = 1, Tb.infN do if Tb.inf[i] and Tb.inf[i].idem_key == p[10] then error('Duplicate entry') end end end
        Tb.infN = Tb.infN + 1
        Tb.inf[Tb.infN] = { id = Tb.infN, citizenid = p[1], order_id = p[2], code = p[3], severity = p[4], state = p[5], evidence_ids = p[6],
            hearing_at = p[7], reported_by = p[8], at = p[9], idem_key = p[10] }
        return Tb.infN
    end },
    { 'WHERE idem_key = ?', function(p) return infList(function(r) return r.idem_key == p[1] end) end },
    { 'FROM pf_prison_infractions WHERE id = ?', function(p) return infList(function(r) return r.id == p[1] end) end },
    { 'AND severity >= ?', function(p)
        return #infList(function(r) return r.citizenid == p[1] and r.state == 'sanctioned' and r.severity >= p[2] and r.at >= p[3] end)
    end },
    { 'sanction LIKE', function() return infList(function(r) return r.state == 'sanctioned' and tostring(r.sanction):find('"state":"pending"', 1, true) end) end },
    { 'AND at <= ?', function(p) return infList(function(r) return (r.state == 'reported' or r.state == 'hearing_scheduled') and r.at <= p[1] end) end },
    { 'FROM pf_prison_infractions WHERE state IN', function() return infList(function(r) return r.state == 'reported' or r.state == 'hearing_scheduled' end) end },
    { 'FROM pf_prison_infractions WHERE citizenid = ?', function(p) return infList(function(r) return r.citizenid == p[1] end) end },
    { 'UPDATE pf_prison_infractions SET sanction = ? WHERE id = ?', function(p) Tb.inf[p[2]].sanction = p[1] return 1 end },
    { 'UPDATE pf_prison_infractions SET', function(p, q) return 0 end },
    { 'DELETE FROM pf_prison_infractions', function() return 0 end },
    -- privileges
    { "VALUES (?, 'solitary', ?, ?)", function(p) Tb.priv[#Tb.priv + 1] = { citizenid = p[1], kind = 'solitary', until_at = p[2] } return #Tb.priv end },
    { 'INSERT INTO pf_prison_privileges', function(p) Tb.priv[#Tb.priv + 1] = { citizenid = p[1], kind = p[2], until_at = p[3] } return #Tb.priv end },
    { 'FROM pf_prison_privileges', function(p)
        local out = {}
        for _, r in ipairs(Tb.priv) do if (r.citizenid == p[1] and r.until_at > (p[2] or 0)) or (p[2] == nil and r.until_at > p[1]) then out[#out + 1] = copy(r) end end
        return out
    end },
    { 'DELETE FROM pf_prison_privileges', function() return 0 end },
    -- counts
    { 'INSERT INTO pf_prison_counts', function(p) Tb.countN = Tb.countN + 1 Tb.counts[Tb.countN] = { id = Tb.countN, due_at = p[2], expected = p[3] } return Tb.countN end },
    { 'UPDATE pf_prison_counts SET closed_at = ?, expected', function(p)
        local c = Tb.counts[p[6]]
        if not c or c.closed_at then return 0 end
        c.closed_at, c.expected, c.present, c.missing, c.by_cid = p[1], p[2], p[3], p[4], p[5]
        return 1
    end },
    { 'pf_prison_counts', function() return 0 end },
    -- visits
    { 'INSERT INTO pf_prison_visits', function(p)
        Tb.visitN = Tb.visitN + 1
        Tb.visits[Tb.visitN] = { id = Tb.visitN, inmate_cid = p[1], visitor_cid = p[2], slot_at = p[3], state = 'booked', kind = p[4], searched = 0, created_at = p[5] }
        return Tb.visitN
    end },
    { 'WHERE slot_at = ?', function(p) return visitList(function(r) return r.slot_at == p[1] and OPENV[r.state] and r.state ~= nil end) end },
    { "WHERE visitor_cid = ? AND state IN ('booked', 'checked_in')", function(p)
        return #visitList(function(r) return r.visitor_cid == p[1] and (r.state == 'booked' or r.state == 'checked_in') and r.slot_at >= p[2] end)
    end },
    { "kind = 'social'", function(p)
        return #visitList(function(r) return r.inmate_cid == p[1] and r.kind == 'social' and r.slot_at >= p[2] and r.slot_at < p[3]
            and r.state ~= 'cancelled' and r.state ~= 'denied' end)
    end },
    { 'FROM pf_prison_visits WHERE id = ?', function(p) return visitList(function(r) return r.id == p[1] end) end },
    { 'SET searched = 1', function(p) local r = Tb.visits[p[1]] if r and (r.state == 'booked' or r.state == 'checked_in') then r.searched = 1 return 1 end return 0 end },
    { 'UPDATE pf_prison_visits SET state = ?, notes', function(p)
        local r = Tb.visits[p[3]]
        if not r or r.state ~= p[4] then return 0 end
        r.state, r.notes = p[1], p[2] or r.notes
        return 1
    end },
    { 'pf_prison_visits', function() return {} end },
}
-- generic compare-and-set for the infraction state moves: UPDATE ... SET state = ?, <col> = ? WHERE id = ? AND state = ?
for i, e in ipairs(FakeDB.extraPatterns) do
    if e[1] == 'UPDATE pf_prison_infractions SET' then
        FakeDB.extraPatterns[i] = { e[1], function(p)
            local id, from = p[#p - 1], p[#p]
            local r = Tb.inf[id]
            if not r or r.state ~= from then return 0 end
            r.state = p[1]
            if #p == 4 then
                -- the extra column is heard_by, hearing_at or sanction (by value type)
                local v = p[2]
                if type(v) == 'number' then r.hearing_at = v elseif tostring(v):sub(1, 1) == '{' then r.sanction = v else r.heard_by = v end
            end
            return 1
        end }
    end
end
Mock.exportsByResource['pfm-core'].RunMigrations = function() return true end

LedgerEnv.load('pfm-prison', { 'pfm-prison/config.lua', 'pfm-prison/config_facility.lua', 'pfm-prison/server/main.lua',
    'pfm-prison/server/schema.lua', 'pfm-prison/server/justice_bridge.lua', 'pfm-prison/server/facility.lua',
    'pfm-prison/server/schedule.lua', 'pfm-prison/server/discipline.lua', 'pfm-prison/server/visitation.lua' })
local B, F, S, D, V = PFPrison.Bridge, PFPrison.Facility, PFPrison.Schedule, PFPrison.Discipline, PFPrison.Visitation
local CF = Config.Facility

local MIDDLE = Config.Locations.middle
local function at(dx, dy) return vector3(MIDDLE.x + dx, MIDDLE.y + dy, MIDDLE.z) end
local OUTSIDE = vector3(0, 0, 0)
local T0 = os.time({ year = 2026, month = 11, day = 17, hour = 12, min = 0, sec = 0 })
local function as(res, name, ...)
    Mock.invokingResource = res
    local a, b = Mock.selfExport(name)(...)
    Mock.invokingResource = nil
    return a, b
end
local function statuses(cid)
    local out = {}
    for _, e in ipairs(Mock.serverEvents) do
        if e.name == 'pfm-prison:server:inmateStatus' and e.args[1] == cid then out[#out + 1] = e.args[2] end
    end
    return out
end
local function notified(src, text)
    for _, e in ipairs(Mock.clientEventsNamed('QBCore:Notify')) do
        if e.target == src and tostring(e.args[1]):find(text, 1, true) then return true end
    end
    return false
end
local function citizen(src, cid, job, grade)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.job = { name = job or 'unemployed', onduty = true, grade = { level = grade or 0 } }
    p.SetJobDuty = function(on) p.PlayerData.job.onduty = on end
    p.Functions = p.Functions or {}
    p.Functions.SetJobDuty = p.SetJobDuty
    Mock.players[src] = p
    Mock.coords[src] = OUTSIDE
    return p
end
local function jail(src, minutes)
    local cid = Mock.players[src].PlayerData.citizenid
    JU.n = JU.n + 1
    local o = { id = 100 + JU.n, cid = cid, kind = 'prison', state = 'active', facility = 'bolingbroke', requiredSeconds = minutes * 60 }
    JU.orders[#JU.orders + 1] = o
    Mock.coords[src] = at(math.random(-20, 20), math.random(-20, 20))
    TriggerEvent('pf-justice:server:orderCreated', copy(o))
    B.Pump()
    return o
end
local function free(src)
    local cid = Mock.players[src].PlayerData.citizenid
    for _, o in ipairs(openOf(cid)) do o.state = 'completed' end
    TriggerEvent('pf-justice:server:releaseOrdered', cid, 0, 'served')
    B.Pump()
end
--- first moment from now in a phase of that name
local function toPhase(name)
    local t = Mock.clock
    for _ = 1, 400 do
        local p = S.Phase(t)
        if p.name == name and p.startsAt >= Mock.clock then Mock.clock = p.startsAt + 1 return p end
        t = p.endsAt
    end
    error('no phase ' .. name)
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players, Mock.coords = {}, {}
    Mock.clock = T0
    resetJU()
    resetInv()
    resetTables()
    doors = {}
    for k in pairs(B.rows) do B.rows[k] = nil end
    B.queue, B.actions, B.credits, B.pending, B.escapees, B.needSeize, B.loadAt = {}, {}, {}, {}, {}, {}, {}
    F.activity, F.intakeAt, F.locks, F.rates, F.lockdown = {}, {}, {}, {}, { on = false }
    S.lastKey, S.openCount, S.countKey, S.served, S.mealProvider = nil, nil, nil, { cids = {} }, nil
    D.priv, D.pending, D.nextTickAt, D.lastOfficerAt = {}, {}, 0, T0
    V.active = {}
    Mock.gameTimer = (Mock.gameTimer or 0) + 100000
    B.ResetMode()
    B.Boot()
    F.Boot(T0)
end

local function tick() Mock.gameTimer = Mock.gameTimer + 10000 end

describe('19D intake and housing', function()
    it('classifies by time to serve, houses in a cell of that class, issues the uniform and logs housing', function()
        citizen(1, 'INA')
        citizen(2, 'INB')
        jail(1, 30)
        jail(2, 600)
        local a = as('pf-justice', 'GetInmate', 'INA').inmate
        local b = as('pf-justice', 'GetInmate', 'INB').inmate
        assert_eq(a.classification, 'min')
        assert_eq(a.cellId:sub(1, 1), 'A')
        assert_eq(a.block, 'A')
        assert_eq(b.classification, 'max')
        assert_eq(b.cellId:sub(1, 1), 'C')
        assert_eq(a.status, 'intake')
        assert_eq(holds(1, 'prison_uniform'), 1)
        assert_eq(Tb.inmates.INA.cell_id, a.cellId)
        local housing = 0
        for _, e in ipairs(Tb.events) do if e.kind == 'housing' then housing = housing + 1 end end
        assert_eq(housing, 2)
        assert_eq(statuses('INA')[#statuses('INA')], 'intake')
    end)
    it('a full class goes up (never down); with no cell left the inmate is housed in overflow and staff are told', function()
        citizen(9, 'CO9', 'corrections', 3)
        for i = 1, 3 do citizen(10 + i, 'MAX' .. i) jail(10 + i, 900) end
        citizen(14, 'MAX4')
        jail(14, 900)
        assert_eq(B.rows.MAX4.cell_id, nil)
        assert_true(notified(9, 'No free cell'))
        -- min cells full -> a min inmate goes to medium, never to max-only being skipped downward
        for i = 1, 8 do citizen(20 + i, 'MIN' .. i) jail(20 + i, 10) end
        citizen(29, 'MIN9')
        jail(29, 10)
        assert_eq(B.rows.MIN9.classification, 'min')
        assert_eq(F.cells[B.rows.MIN9.cell_id].classification, 'medium')
    end)
    it('an escape record makes the classification max', function()
        citizen(1, 'ESC')
        Tb.escapes.ESC = 1
        jail(1, 10)
        assert_eq(B.rows.ESC.classification, 'max')
    end)
    it('release takes the uniform back and frees the cell', function()
        citizen(1, 'INA')
        jail(1, 30)
        local cell = B.rows.INA.cell_id
        free(1)
        assert_eq(holds(1, 'prison_uniform'), 0)
        assert_eq(as('pf-justice', 'GetInmate', 'INA').inmate, nil)
        assert_eq(F.Occupancy()[cell], nil)
    end)
    it('staff move cells only into an in-service cell of the class or higher with room; grade is checked', function()
        citizen(1, 'INA')
        jail(1, 30)
        citizen(9, 'CO9', 'corrections', 1)
        assert_eq(F.AssignCell(9, 'INA', 'B101').error, 'no_permission')
        Mock.players[9].PlayerData.job.grade.level = 2
        assert_true(F.AssignCell(9, 'INA', 'B101').ok)
        assert_eq(B.rows.INA.cell_id, 'B101')
        citizen(2, 'INX')
        jail(2, 900)
        assert_eq(F.AssignCell(9, 'INX', 'A102').error, 'invalid_state')
        assert_true(F.SetCellService(9, 'B101', true).ok)
        assert_true(B.rows.INA.cell_id ~= 'B101')
        assert_eq(F.AssignCell(9, 'INA', 'B101').error, 'invalid_state')
    end)
end)

describe('19D facility status', function()
    it('GetFacilityStatus carries the phase, the next count and the cell totals', function()
        citizen(1, 'INA')
        jail(1, 30)
        local st = as('pf-justice', 'GetFacilityStatus', 'bolingbroke')
        local total = 0
        for _, c in ipairs(CF.Cells) do total = total + c.capacity end
        assert_eq(st.cells.total, total)
        assert_eq(st.cells.free, total - 1)
        assert_true(st.nextCount ~= nil and st.nextCount >= Mock.clock - 3600)
        assert_true(st.phase ~= nil)
        assert_eq(st.population, 1)
        assert_eq(as('pf-justice', 'GetFacilityStatus', 'elsewhere').error, 'not_found')
    end)
end)

describe('19D routine, counts and meals', function()
    it('the phase gives the activity; a lost privilege keeps the inmate in the cell', function()
        citizen(1, 'INA')
        citizen(2, 'INB')
        jail(1, 30)
        jail(2, 30)
        Mock.clock = Mock.clock + CF.IntakeSeconds + 1
        toPhase('yard')
        D.priv.INB = { yard = Mock.clock + 3600 }
        S.Tick(Mock.clock)
        assert_eq(F.Activity('INA'), 'yard')
        assert_eq(F.Activity('INB'), 'in_cell')
        toPhase('work')
        S.Tick(Mock.clock)
        assert_eq(F.Activity('INA'), 'work')
        D.priv.INA = { solitary = Mock.clock + 600 }
        S.Tick(Mock.clock)
        assert_eq(F.Activity('INA'), 'solitary')
        assert_eq(as('pf-justice', 'GetInmate', 'INA').inmate.status, 'solitary')
    end)
    it('a count opens only with an inmate online, closes at the end with the server presence', function()
        toPhase('count')
        S.Tick(Mock.clock)
        assert_eq(S.openCount, nil)
        assert_eq(Tb.countN, 0)
        citizen(1, 'INA')
        citizen(2, 'INB')
        jail(1, 30)
        jail(2, 30)
        S.Tick(Mock.clock)
        assert_true(S.openCount ~= nil)
        assert_eq(Tb.counts[1].expected, 2)
        Mock.coords[2] = OUTSIDE
        local p = S.Phase(Mock.clock)
        Mock.clock = p.endsAt
        S.Tick(Mock.clock)
        assert_eq(S.openCount, nil)
        assert_eq(Tb.counts[1].present, 1)
        assert_true(tostring(Tb.counts[1].missing):find('INB', 1, true) ~= nil)
    end)
    it('an inmate who logged off during the count is offline, not missing', function()
        citizen(1, 'INA')
        citizen(2, 'INB')
        jail(1, 30)
        jail(2, 30)
        toPhase('count')
        S.Tick(Mock.clock)
        Mock.players[2] = nil
        local res = S.CloseCount(nil, Mock.clock)
        assert_eq(#res.missing, 0)
        assert_eq(res.offline[1], 'INB')
        assert_eq(res.present, 1)
    end)
    it('an inmate in custody care (19F follow-up: pf-ambulancejob IsInCustodyCare) is accounted for and shows infirmary / transfer', function()
        local care = {}
        Mock.exportsByResource['pf-ambulancejob'] = {
            IsInCustodyCare = function(_, who) if care[who] then return true, care[who], 'pillbox' end return false end,
        }
        citizen(1, 'INA')
        citizen(2, 'INB')
        jail(1, 30)
        jail(2, 30)
        Mock.clock = Mock.clock + CF.IntakeSeconds + 1
        toPhase('count')
        S.Tick(Mock.clock)
        -- INA is at the hospital on an escorted transfer, INB in the prison infirmary
        care[1], care[2] = 'transfer', 'infirmary'
        Mock.coords[1] = OUTSIDE
        S.Tick(Mock.clock)
        assert_eq(F.Activity('INA'), 'transfer')
        assert_eq(as('pf-justice', 'GetInmate', 'INB').inmate.status, 'infirmary')
        local res = S.CloseCount(nil, Mock.clock)
        assert_eq(#res.missing, 0, 'not missing while in custody care')
        assert_eq(res.present, 2)
        assert_eq(#res.accounted, 2)
        -- the care ends: the routine status comes back, and outside the walls is missing again
        care[1], care[2] = nil, nil
        toPhase('yard')
        S.Tick(Mock.clock)
        assert_eq(F.Activity('INB'), 'yard')
        Mock.exportsByResource['pf-ambulancejob'] = nil
    end)
    it('an officer conducts the count on duty inside the walls; it does not reopen in the same phase', function()
        citizen(1, 'INA')
        jail(1, 30)
        toPhase('count')
        S.Tick(Mock.clock)
        citizen(9, 'CO9', 'corrections', 0)
        assert_eq(S.ConductCount(9).error, 'too_far')
        Mock.players[9].PlayerData.job.onduty = false
        Mock.coords[9] = at(1, 1)
        assert_eq(S.ConductCount(9).error, 'not_on_duty')
        Mock.players[9].PlayerData.job.onduty = true
        local res = S.ConductCount(9)
        assert_true(res.ok)
        assert_eq(res.present, 1)
        assert_eq(Tb.counts[1].by_cid, 'CO9')
        S.Tick(Mock.clock + 10)
        assert_eq(S.openCount, nil)
        assert_eq(Tb.countN, 1)
        citizen(3, 'NOBODY')
        Mock.players[1] = nil
        assert_eq(S.ConductCount(9).error, 'invalid_state')
    end)
    it('meals are served once per meal to inmates inside the walls, also to one who logs in during it', function()
        citizen(1, 'INA')
        citizen(2, 'INB')
        jail(1, 30)
        jail(2, 30)
        Mock.coords[2] = OUTSIDE
        toPhase('meal')
        S.Tick(Mock.clock)
        S.Tick(Mock.clock + 5)
        assert_eq(holds(1, 'sandwich'), 1)
        assert_eq(holds(2, 'sandwich'), 0)
        Mock.coords[2] = at(2, 2)
        S.Tick(Mock.clock + 10)
        assert_eq(holds(2, 'sandwich'), 1)
        -- the kitchen (19E) may serve from its own stock instead
        F.SetMealProvider(function() return true end)
        toPhase('meal')
        S.Tick(Mock.clock)
        assert_eq(holds(1, 'sandwich'), 1)
    end)
end)

describe('19D discipline (architecture 5.13)', function()
    local function setup()
        citizen(1, 'INA')
        local o = jail(1, 60)
        Mock.coords[1] = at(0, 0)
        Mock.clock = Mock.clock + CF.IntakeSeconds + 1
        citizen(8, 'REP', 'corrections', 0)
        citizen(9, 'HEAR', 'corrections', 2)
        Mock.coords[8], Mock.coords[9] = at(1, 0), at(0, 1)
        return o
    end
    it('only on-duty staff report; the inmate is told; the notice period and an impartial officer of the grade hear it', function()
        setup()
        citizen(5, 'CIV')
        assert_eq(D.Record('INA', { code = 'P-300' }, { actor = { src = 5 } }).error, 'no_permission')
        assert_eq(D.Record('INA', { code = 'NOPE' }, { actor = { src = 8 } }).error, 'bad_args')
        local r = D.Record('INA', { code = 'P-300' }, { actor = { src = 8 } })
        assert_true(r.ok)
        assert_eq(r.state, 'reported')
        assert_true(notified(1, 'Infraction reported'))
        local decision = { verdict = 'guilty', sanctions = { privileges = { { kind = 'yard', hours = 2 } } } }
        assert_eq(D.HoldHearing(9, r.infractionId, decision).error, 'invalid_state') -- notice
        Mock.clock = Mock.clock + CF.Discipline.MinNoticeSeconds
        assert_eq(D.HoldHearing(8, r.infractionId, decision).error, 'no_permission') -- grade 0 (and the reporter)
        Mock.players[8].PlayerData.job.grade.level = 3
        tick()
        assert_eq(D.HoldHearing(8, r.infractionId, decision).error, 'no_permission') -- the reporting officer
        Mock.coords[1] = at(50, 50)
        assert_eq(D.HoldHearing(9, r.infractionId, decision).error, 'too_far') -- the inmate attends
        Mock.coords[1] = at(0, 0)
        local res = D.HoldHearing(9, r.infractionId, decision)
        assert_true(res.ok)
        assert_eq(res.state, 'sanctioned')
        assert_eq(Tb.inf[r.infractionId].state, 'sanctioned')
        assert_false(D.HasPrivilege('INA', 'yard'))
        assert_true(D.HasPrivilege('INA', 'commissary'))
        assert_eq(D.HoldHearing(9, r.infractionId, decision).error, 'invalid_state')
    end)
    it('a forfeit goes through AdjustOrder with the hearing key; solitary places the inmate; not guilty changes nothing', function()
        local o = setup()
        local r = D.Record('INA', { code = 'P-310' }, { actor = { src = 8 } })
        Mock.clock = Mock.clock + CF.Discipline.MinNoticeSeconds
        assert_eq(D.HoldHearing(9, r.infractionId, { verdict = 'guilty', sanctions = { forfeitMinutes = 999 } }).error, 'bad_args')
        local res = D.HoldHearing(9, r.infractionId, { verdict = 'guilty', sanctions = { forfeitMinutes = 15, solitaryMinutes = 30 } })
        assert_true(res.ok)
        local adj = jcalls('AdjustOrder')
        assert_eq(#adj, 1)
        assert_eq(adj[1].id, o.id)
        assert_eq(adj[1].change.kind, 'forfeit')
        assert_eq(adj[1].change.seconds, 900)
        assert_eq(adj[1].opts.key, ('pfm-prison:discipline:%d:forfeit'):format(r.infractionId))
        assert_eq(res.sanction.forfeit.state, 'applied')
        assert_true(D.InSolitary('INA'))
        local spot = CF.Solitary.coords
        assert_near(Mock.coords[1].x, spot.x, 0.01)
        assert_eq(F.Activity('INA'), 'solitary')
        tick()
        local r2 = D.Record('INA', { code = 'P-100' }, { actor = { src = 8 } })
        Mock.clock = Mock.clock + CF.Discipline.MinNoticeSeconds
        Mock.coords[9] = Mock.coords[1]
        local res2 = D.HoldHearing(9, r2.infractionId, { verdict = 'not_guilty', sanctions = { forfeitMinutes = 5 } })
        assert_eq(res2.state, 'dismissed')
        assert_eq(#jcalls('AdjustOrder'), 1)
    end)
    it('a forfeit pf-justice is busy for is retried with the same key', function()
        setup()
        local r = D.Record('INA', { code = 'P-300' }, { actor = { src = 8 } })
        Mock.clock = Mock.clock + CF.Discipline.MinNoticeSeconds
        JU.adjustAnswer = { ok = false, error = 'busy' }
        local res = D.HoldHearing(9, r.infractionId, { verdict = 'guilty', sanctions = { forfeitMinutes = 5 } })
        assert_eq(res.sanction.forfeit.state, 'pending')
        JU.adjustAnswer = nil
        assert_eq(D.RetryForfeits(), 1)
        local adj = jcalls('AdjustOrder')
        assert_eq(#adj, 2)
        assert_eq(adj[2].opts.key, adj[1].opts.key)
        assert_true(tostring(Tb.inf[r.infractionId].sanction):find('"applied"', 1, true) ~= nil)
    end)
    it('an offline inmate is heard only after a scheduled hearing time (in absentia)', function()
        setup()
        local r = D.Record('INA', { code = 'P-200' }, { actor = { src = 8 } })
        Mock.clock = Mock.clock + CF.Discipline.MinNoticeSeconds
        Mock.players[1] = nil
        local decision = { verdict = 'guilty', sanctions = { privileges = { { kind = 'commissary', hours = 1 } } } }
        assert_eq(D.HoldHearing(9, r.infractionId, decision).error, 'offline')
        tick()
        assert_true(D.ScheduleHearing(9, r.infractionId, Mock.clock + 600).ok)
        tick()
        assert_eq(D.HoldHearing(9, r.infractionId, decision).error, 'offline')
        Mock.clock = Mock.clock + 601
        tick()
        assert_true(D.HoldHearing(9, r.infractionId, decision).ok)
    end)
    it('an automatic hearing waits for AutoHearingAfter without a hearing officer and only restricts privileges', function()
        setup()
        local r = D.Record('INA', { code = 'P-300' }, { actor = { src = 8 } })
        Mock.clock = Mock.clock + CF.Discipline.AutoHearingAfter + 10
        assert_eq(D.AutoHearings(Mock.clock), 0) -- a hearing officer is on duty
        Mock.players[9] = nil
        assert_eq(D.AutoHearings(Mock.clock), 0) -- the officer was on duty just now
        Mock.clock = Mock.clock + CF.Discipline.AutoHearingAfter
        assert_eq(D.AutoHearings(Mock.clock), 1)
        assert_eq(Tb.inf[r.infractionId].state, 'sanctioned')
        assert_eq(Tb.inf[r.infractionId].heard_by, 'auto')
        assert_eq(#jcalls('AdjustOrder'), 0)
        assert_false(D.InSolitary('INA'))
        assert_false(D.HasPrivilege('INA', 'yard'))
        assert_false(D.HasPrivilege('INA', 'commissary'))
    end)
    it('RecordInfraction: the caller list, a system actor, the key', function()
        setup()
        assert_eq(as('some-script', 'RecordInfraction', 'INA', { code = 'P-200' }, {}).error, 'not_allowed')
        local a = as('pfm-adminmenu', 'RecordInfraction', 'INA', { code = 'P-200', evidenceIds = { 4, 5 } }, { key = 'adm:1' })
        assert_true(a.ok)
        assert_eq(Tb.inf[a.infractionId].evidence_ids, '4,5')
        local b = as('pfm-adminmenu', 'RecordInfraction', 'INA', { code = 'P-200' }, { key = 'adm:1' })
        assert_true(b.duplicate)
        assert_eq(b.infractionId, a.infractionId)
        assert_eq(as('pfm-adminmenu', 'RecordInfraction', 'NOTHERE', { code = 'P-200' }, {}).error, 'not_found')
    end)
end)

describe('19D visitation', function()
    local SLOT
    local function setup()
        SLOT = CF.Visitation.SlotMinutes * 60
        citizen(1, 'INA')
        jail(1, 60)
        Mock.clock = Mock.clock + CF.IntakeSeconds + 1
        citizen(5, 'VIS')
        citizen(6, 'LAW', 'lawyer', 0)
        return math.floor(Mock.clock / SLOT) * SLOT + SLOT
    end
    local function room(src) Mock.coords[src] = CF.Visitation.Room.coords end
    it('booking: hours, privilege, attorney right, notices', function()
        local slot = setup()
        local night = os.time({ year = 2026, month = 11, day = 18, hour = 3, min = 0, sec = 0 })
        assert_eq(V.Book(5, 'INA', night).error, 'bad_args')
        tick()
        assert_eq(V.Book(5, 'INA', slot + 7).error, 'bad_args')
        tick()
        assert_eq(V.Book(5, 'INA', slot, 'attorney').error, 'no_permission')
        D.priv.INA = { visits = Mock.clock + 86400 }
        tick()
        assert_eq(V.Book(5, 'INA', slot).error, 'no_permission')
        local a = V.Book(6, 'INA', slot, 'attorney')
        assert_true(a.ok)
        assert_true(notified(1, 'attorney visit'))
        D.priv.INA = nil
        tick()
        assert_true(V.Book(5, 'INA', slot + SLOT).ok)
        citizen(7, 'INB')
        jail(7, 30)
        tick()
        assert_eq(V.Book(7, 'INA', slot + 2 * SLOT).error, 'no_permission') -- inmates do not book
    end)
    it('check-in at the desk; with staff on duty the visitor is searched; the visit runs while both are in the room', function()
        local slot = setup()
        local id = V.Book(5, 'INA', slot).visitId
        Mock.clock = slot - 60
        assert_eq(V.CheckIn(5, id).error, 'too_far')
        Mock.coords[5] = CF.Visitation.Desk.coords
        assert_true(V.CheckIn(5, id).ok)
        citizen(9, 'CO9', 'corrections', 0)
        Mock.coords[9] = at(60, 60)
        Mock.clock = slot + 1
        room(1)
        room(5)
        V.Tick(Mock.clock)
        assert_eq(V.active[id].state, 'checked_in') -- not searched yet
        assert_eq(V.Search(9, id, true).error, 'too_far')
        Mock.coords[9] = CF.Visitation.Room.coords
        assert_true(V.Search(9, id, true).ok)
        V.Tick(Mock.clock)
        assert_eq(V.active[id].state, 'in_progress')
        S.Tick(Mock.clock)
        assert_eq(F.Activity('INA'), 'visitation')
        Mock.coords[5] = OUTSIDE
        V.Tick(Mock.clock + 5)
        assert_eq(V.active[id].state, 'in_progress')
        V.Tick(Mock.clock + 5 + CF.Visitation.LeaveGraceSeconds)
        assert_eq(V.active[id], nil)
        assert_eq(Tb.visits[id].state, 'done')
    end)
    it('with nobody on duty the visit starts without a search; a lockdown ends it; nobody coming is a no-show', function()
        local slot = setup()
        local id = V.Book(5, 'INA', slot).visitId
        tick()
        local id2 = V.Book(6, 'INA', slot + SLOT, 'attorney').visitId
        Mock.clock = slot
        Mock.coords[5] = CF.Visitation.Desk.coords
        assert_true(V.CheckIn(5, id).ok)
        room(1)
        room(5)
        V.Tick(Mock.clock)
        assert_eq(V.active[id].state, 'in_progress')
        F.ApplyLockdown(true, { reason = 'test' })
        assert_eq(Tb.visits[id].state, 'done')
        F.ApplyLockdown(false, {})
        Mock.clock = slot + SLOT + CF.Visitation.NoShowMinutes * 60
        V.Tick(Mock.clock)
        assert_eq(Tb.visits[id2].state, 'no_show')
    end)
    it('the visitor or the inmate cancels; others cannot', function()
        local slot = setup()
        local id = V.Book(5, 'INA', slot).visitId
        citizen(3, 'STRANGER')
        assert_eq(V.Cancel(3, id).error, 'no_permission')
        assert_true(V.Cancel(1, id).ok)
        assert_eq(Tb.visits[id].state, 'cancelled')
    end)
end)

describe('19D lockdown', function()
    it('staff need the lockdown grade; gates are locked through pfm-doorlock; it ends by itself', function()
        citizen(1, 'INA')
        jail(1, 30)
        Mock.clock = Mock.clock + CF.IntakeSeconds + 1
        citizen(9, 'CO9', 'corrections', 2)
        assert_eq(F.StaffLockdown(9, true, 'riot', 10).error, 'no_permission')
        Mock.players[9].PlayerData.job.grade.level = 3
        local res = F.StaffLockdown(9, true, 'riot', 10)
        assert_true(res.ok)
        assert_eq(#doors, #Config.Gates)
        for _, d in ipairs(doors) do assert_true(d.locked) end
        local lc = Mock.clientEventsNamed('prison:client:SetLockDown')
        assert_eq(lc[#lc].args[1], true)
        assert_true(as('pf-justice', 'GetFacilityStatus', 'bolingbroke').lockdown)
        assert_eq(F.Activity('INA'), 'in_cell')
        assert_false(S.Allows('work'))
        Mock.clock = Mock.clock + 601
        F.Tick(Mock.clock)
        assert_false(F.lockdown.on)
        assert_false(as('pf-justice', 'GetFacilityStatus', 'bolingbroke').lockdown)
    end)
    it('SetLockdown export: caller list, facility name', function()
        assert_eq(as('some-script', 'SetLockdown', 'bolingbroke', true, {}).error, 'not_allowed')
        assert_eq(as('pfm-adminmenu', 'SetLockdown', 'elsewhere', true, {}).error, 'not_found')
        assert_true(as('pfm-adminmenu', 'SetLockdown', 'bolingbroke', true, { reason = 'drill', minutes = 5 }).ok)
        assert_true(F.lockdown.on)
        assert_true(as('pfm-adminmenu', 'SetLockdown', 'bolingbroke', false, {}).ok)
        assert_false(F.lockdown.on)
    end)
end)
