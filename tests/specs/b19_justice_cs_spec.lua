-- Batch 19 unit 19C: pf-justice community service runtime (PF_ARCHITECTURE 4.7.9, state machine 5.8).
--   * a shift opens only inside a sign-in zone (server position); the order goes assigned -> active;
--   * work comes from pf-government (ListWorkOrders csEligible near the citizen, ClaimWorkOrder kind 'cs');
--   * steps are checked on the server: the next index only, at the server-chosen point, MinStepSeconds
--     apart, on foot, with the kind's item rule (tool held, supplies consumed on the server);
--   * a unit counts ONLY after GOV ReportWorkUnit answers ok (key pf-justice:cs:<taskId>): every refusal
--     (too soon, unavailable, claim gone) counts nothing, a repeat counts once;
--   * a disconnect keeps the shift, the task and its steps; the reconnect resumes them (a lapsed claim is
--     claimed again for the same work order);
--   * a supervisor (job, grade, duty, GOV qualification, nearby) verifies a shift; its units count x bonus;
--   * an overdue order files one court item (FileCase kind 'violation'), never an incarceration order;
--   * GetCommunityService behind the caller allowlist.
-- The pf-justice statements run on an in-memory table store matched by their exact text (PFJustice.SQL);
-- the real SQL is covered by b19_justice_cs_realdb_spec.lua.
load_resource('tests/lua/fivem_mocks.lua')
function GetCurrentResourceName() return 'pf-justice' end
local started = { ['pf-government'] = true, ['pfm-inventory'] = true }
function GetResourceState(res) return started[res] and 'started' or 'missing' end
QBCore = QBCoreMock
Mock.clock = 1800000000

for _, f in ipairs({ 'config.lua', 'shared/states.lua', 'shared/cs_tasks.lua', 'server/main.lua', 'server/orders.lua',
    'server/community_service.lua' }) do
    load_resource('[pfscripts]/pf-justice/' .. f)
end
local J = PFJustice
local CS = J.CS
local Q = J.SQL
J.ready = true
J.Schema = nil

local SITE = { x = 195.2, y = -933.9, z = 30.7, r = 30.0, label = 'Legion Square' }
local DESK = vector3(-544.67, -204.25, 38.22)
local function cfgDefaults()
    Config.CommunityService = {
        MaxUnits = 500, DefaultDays = 14,
        SignIn = { { id = 'cityhall', label = 'City Hall desk', coords = DESK, radius = 15.0 } },
        NearRadius = 1500.0, MinStepSeconds = 20, MinStepDistance = 3.0, ShiftMaxHours = 4,
        SupervisorBonus = 1.0, SupervisorJobs = { doj = 3, government = 0 }, SupervisorDistance = 30.0,
    }
    Config.Callers.GetCommunityService = '*'
end

-- ── in-memory pf-justice tables ─────────────────────────────────────────────────────────────────
local DB
local function resetDB() DB = { orders = {}, events = {}, shifts = {}, tasks = {}, n = { o = 0, e = 0, s = 0, t = 0 } } end
local function copy(t) if not t then return nil end local o = {} for k, v in pairs(t) do o[k] = v end return o end
local function sorted(tbl, desc)
    local out = {}
    for _, r in pairs(tbl) do out[#out + 1] = r end
    table.sort(out, function(a, b) if desc then return a.id > b.id end return a.id < b.id end)
    return out
end
local H = {}
H[Q.orderById] = function(p) return copy(DB.orders[tonumber(p[1])]) end
local function cas(id, from, fn)
    local o = DB.orders[tonumber(id)]
    if not o or o.state ~= from then return 0 end
    fn(o)
    return 1
end
H[Q.setState] = function(p) return cas(p[3], p[4], function(o) o.state, o.updated_at = p[1], p[2] end) end
H[Q.finish] = function(p) return cas(p[4], p[5], function(o) o.state, o.ends_at, o.updated_at = p[1], p[2], p[3] end) end
H[Q.activate] = function(p) return cas(p[4], p[5], function(o) o.state, o.starts_at = 'active', o.starts_at or p[1] end) end
H[Q.insertEvent] = function(p)
    if p[7] then for _, e in pairs(DB.events) do if e.idem_key == p[7] then error('Duplicate entry for key uq_joe_key') end end end
    DB.n.e = DB.n.e + 1
    DB.events[DB.n.e] = { id = DB.n.e, order_id = p[1], action = p[2], detail = p[3], idem_key = p[7], at = p[8] }
    return DB.n.e
end
H[Q.eventByKey] = function(p) for _, e in pairs(DB.events) do if e.idem_key == p[1] then return copy(e) end end return nil end
local OPENS = { assigned = true, active = true, overdue = true }
H[Q.csOpenOrders] = function(p)
    local out = {}
    for _, o in ipairs(sorted(DB.orders)) do
        if o.citizenid == p[1] and o.kind == 'community_service' and OPENS[o.state] and o.units_done < o.units then out[#out + 1] = copy(o) end
    end
    table.sort(out, function(a, b) if a.due_at ~= b.due_at then return a.due_at < b.due_at end return a.id < b.id end)
    return out
end
H[Q.csOrdersOf] = function(p)
    local out = {}
    for _, o in ipairs(sorted(DB.orders, true)) do if o.citizenid == p[1] and o.kind == 'community_service' then out[#out + 1] = copy(o) end end
    return out
end
H[Q.csOpenShift] = function(p)
    for _, s in ipairs(sorted(DB.shifts, true)) do if s.citizenid == p[1] and s.ended_at == nil then return copy(s) end end
    return nil
end
H[Q.csShiftById] = function(p) return copy(DB.shifts[tonumber(p[1])]) end
H[Q.csInsertShift] = function(p)
    DB.n.s = DB.n.s + 1
    DB.shifts[DB.n.s] = { id = DB.n.s, order_id = p[1], citizenid = p[2], site = p[3], started_at = p[4], units = 0 }
    return DB.n.s
end
H[Q.csEndShift] = function(p)
    local s = DB.shifts[tonumber(p[2])]
    if not s or s.ended_at ~= nil then return 0 end
    s.ended_at = p[1]
    return 1
end
H[Q.csSupervise] = function(p)
    local s = DB.shifts[tonumber(p[2])]
    if not s or s.ended_at ~= nil or s.supervisor_cid ~= nil then return 0 end
    s.supervisor_cid = p[1]
    return 1
end
H[Q.csShiftUnits] = function(p) local s = DB.shifts[tonumber(p[2])] if s then s.units = p[1] return 1 end return 0 end
H[Q.csStaleShifts] = function(p)
    local out = {}
    for _, s in ipairs(sorted(DB.shifts)) do if s.ended_at == nil and s.started_at <= p[1] then out[#out + 1] = copy(s) end end
    return out
end
H[Q.csActiveTask] = function(p)
    for _, t in ipairs(sorted(DB.tasks, true)) do if t.shift_id == p[1] and t.state == 'active' then return copy(t) end end
    return nil
end
H[Q.csTaskById] = function(p) return copy(DB.tasks[tonumber(p[1])]) end
H[Q.csInsertTask] = function(p)
    DB.n.t = DB.n.t + 1
    DB.tasks[DB.n.t] = { id = DB.n.t, shift_id = p[1], order_id = p[2], work_order_id = p[3], claim_id = p[4], kind = p[5],
        steps_done = 0, steps_needed = p[6], state = 'active', started_at = p[7] }
    return DB.n.t
end
H[Q.csStep] = function(p)
    local t = DB.tasks[tonumber(p[1])]
    if not t or t.state ~= 'active' or t.steps_done ~= p[2] or t.steps_done >= t.steps_needed then return 0 end
    t.steps_done = t.steps_done + 1
    return 1
end
H[Q.csTaskClaim] = function(p) local t = DB.tasks[tonumber(p[2])] if t and t.state == 'active' then t.claim_id = p[1] return 1 end return 0 end
H[Q.csTaskDone] = function(p)
    local t = DB.tasks[tonumber(p[2])]
    if not t or t.state ~= 'active' then return 0 end
    t.state, t.done_at = 'done', p[1]
    return 1
end
H[Q.csTaskEnd] = function(p)
    local t = DB.tasks[tonumber(p[4])]
    if not t or t.state ~= 'active' then return 0 end
    t.state, t.done_at, t.reject_reason = p[1], p[2], p[3]
    return 1
end
H[Q.csDoneWeights] = function(p)
    local out = {}
    for _, t in ipairs(sorted(DB.tasks)) do
        if t.order_id == p[1] and t.state == 'done' then out[#out + 1] = { shift_id = t.shift_id, supervisor_cid = DB.shifts[t.shift_id].supervisor_cid } end
    end
    return out
end
H[Q.csSetUnitsDone] = function(p)
    local o = DB.orders[tonumber(p[3])]
    if not o or o.kind ~= 'community_service' or o.units_done ~= p[4] then return 0 end
    o.units_done, o.updated_at = p[1], p[2]
    return 1
end
H[Q.csOverdue] = function()
    local out = {}
    for _, o in ipairs(sorted(DB.orders)) do
        if o.kind == 'community_service' and o.state == 'overdue' then
            local key, found = ('pf-justice:cs:order:%d:court'):format(o.id), false
            for _, e in pairs(DB.events) do if e.idem_key == key then found = true end end
            if not found then out[#out + 1] = { id = o.id } end
        end
    end
    return out
end
local function dispatch(kind)
    local fn = function(q, p)
        local h = H[q]
        if not h then error('unhandled SQL (' .. kind .. '): ' .. tostring(q)) end
        local r = h(p or {})
        if kind == 'update' then return r or 0 end
        return r
    end
    return setmetatable({ await = fn }, { __call = function(_, q, p) return fn(q, p) end })
end
MySQL = { query = dispatch('query'), single = dispatch('single'), insert = dispatch('insert'), update = dispatch('update'), scalar = dispatch('scalar') }

local function newOrder(cid, units, state, dueAt)
    DB.n.o = DB.n.o + 1
    DB.orders[DB.n.o] = { id = DB.n.o, citizenid = cid, kind = 'community_service', state = state or 'assigned', units = units,
        units_done = 0, due_at = dueAt or (Mock.clock + 14 * 86400), clock = 'realtime', created_at = Mock.clock, updated_at = Mock.clock,
        served_seconds = 0, credit_seconds = 0, forfeit_seconds = 0, paid_amount = 0, pay_attempt = 0, refund_attempt = 0 }
    return DB.n.o
end

-- ── pf-government work orders stand-in (contract of 4.12 / 12.5) ────────────────────────────────
local GOV
local function resetGov()
    GOV = { orders = {}, claims = {}, n = 0, reports = {}, released = {}, listFilters = {}, reportResult = nil, quals = {} }
    GOV.orders[7] = { id = 7, kind = 'litter', site = copy(SITE), units = 10, unitsDone = 0, status = 'open', csEligible = true, district = 'police_mrpd' }
    GOV.orders[8] = { id = 8, kind = 'pothole', site = copy(SITE), units = 1, unitsDone = 1, status = 'open', csEligible = true, district = 'police_mrpd' }
end
local function pub(o)
    local taken = 0
    for _, c in pairs(GOV.claims) do if c.wo == o.id and c.state == 'claimed' and c.expiresAt > Mock.clock then taken = taken + 1 end end
    return { id = o.id, kind = o.kind, site = copy(o.site), units = o.units, unitsDone = o.unitsDone, unitsOpen = o.units - o.unitsDone - taken,
        csEligible = o.csEligible, status = o.status, districtLabel = 'Mission Row', minSeconds = 60, distance = 10.0 }
end
Mock.exportsByResource['pf-government'] = {
    ListWorkOrders = function(_, filter)
        GOV.listFilters[#GOV.listFilters + 1] = filter
        local list = {}
        for _, o in ipairs(sorted(GOV.orders)) do list[#list + 1] = pub(o) end
        return { ok = true, list = list }
    end,
    GetWorkOrder = function(_, id)
        local o = GOV.orders[id]
        if not o then return { ok = false, error = 'not_found' } end
        return { ok = true, order = pub(o) }
    end,
    ClaimWorkOrder = function(_, id, claimant)
        if GOV.claimFail then return GOV.claimFail end
        assert(claimant.kind == 'cs', 'community service claims are kind cs')
        local o = GOV.orders[id]
        if not o or o.status ~= 'open' then return { ok = false, error = 'invalid_state' } end
        for cid, c in pairs(GOV.claims) do
            if c.cid == claimant.cid and c.wo == id and c.state == 'claimed' and c.expiresAt > Mock.clock then
                return { ok = true, duplicate = true, claimId = cid, site = copy(o.site), minSeconds = 60, expiresAt = c.expiresAt }
            end
        end
        GOV.n = GOV.n + 1
        GOV.claims[GOV.n] = { wo = id, cid = claimant.cid, state = 'claimed', expiresAt = Mock.clock + 600, ref = claimant.ref }
        return { ok = true, claimId = GOV.n, site = copy(o.site), minSeconds = 60, expiresAt = Mock.clock + 600 }
    end,
    ReportWorkUnit = function(_, claimId, proof, opts)
        GOV.reports[#GOV.reports + 1] = { claimId = claimId, src = proof.src, key = opts.key }
        if GOV.reportResult then return GOV.reportResult end
        for _, c in pairs(GOV.claims) do
            if c.key == opts.key then return { ok = true, duplicate = true, unitsDone = GOV.orders[c.wo].unitsDone } end
        end
        local c = GOV.claims[claimId]
        if not c or c.state ~= 'claimed' or c.expiresAt <= Mock.clock then return { ok = false, error = 'invalid_state', message = 'This claim has expired.' } end
        c.state, c.key = 'done', opts.key
        local o = GOV.orders[c.wo]
        o.unitsDone = o.unitsDone + 1
        return { ok = true, unitsDone = o.unitsDone, units = o.units, completed = o.unitsDone >= o.units }
    end,
    ReleaseWorkClaim = function(_, claimId)
        GOV.released[#GOV.released + 1] = claimId
        if GOV.claims[claimId] then GOV.claims[claimId].state = 'released' end
        return { ok = true }
    end,
    HasQualification = function(_, cid, q) return GOV.quals[cid .. ':' .. q] == true end,
}
local INV = { has = {}, removed = {} }
Mock.exportsByResource['pfm-inventory'] = {
    HasItem = function(_, src, name) return INV.has[src .. ':' .. name] == true end,
    RemoveItem = function(_, src, name, amount)
        if not INV.has[src .. ':' .. name] then return false end
        INV.removed[#INV.removed + 1] = { src = src, name = name, amount = amount }
        return true
    end,
}
local filed = {}
J.API = { FileCase = function(spec, opts) filed[#filed + 1] = { spec = spec, opts = opts } return J.fileCaseResult or { ok = true, caseId = 500 + #filed } end }

local W, SUP = 1, 2
BeforeEach = function()
    Mock.reset()
    resetDB()
    resetGov()
    cfgDefaults()
    Mock.clock = Mock.clock + 1000
    Mock.players, Mock.coords, Mock.vehicleOf = {}, {}, {}
    Mock.invokingResource = nil
    INV.has, INV.removed = {}, {}
    filed = {}
    J.fileCaseResult = nil
    for k in pairs(CS.live) do CS.live[k] = nil end
    for k in pairs(CS.bySrc) do CS.bySrc[k] = nil end
    Mock.newPlayer(W, 'WORKER1')
    Mock.coords[W] = DESK
    local sup = Mock.newPlayer(SUP, 'SUPER1')
    sup.PlayerData.job = { name = 'doj', grade = { level = 3 }, onduty = true }
    Mock.coords[SUP] = vector3(SITE.x + 5, SITE.y, SITE.z)
end

local function at(src, p) Mock.coords[src] = vector3(p.x, p.y, p.z) end
local function units(orderId) return DB.orders[orderId].units_done end

-- signs in, claims work order 7 and returns the task id
local function startTask(src)
    Mock.coords[src] = DESK
    assert_true(CS.StartShift(src).ok, 'shift')
    local c = CS.Claim(src, 7)
    assert_true(c.ok, 'claim: ' .. tostring(c.error))
    return c.taskId
end

-- does every step of the task the honest way (at each point, MinStepSeconds apart)
local function doSteps(src, taskId, count)
    local e = CS.live[taskId]
    for i = e.stepsDone + 1, count or e.stepsNeeded do
        Mock.clock = Mock.clock + 21
        at(src, e.points[i])
        local r = CS.Step(src, taskId, i)
        assert_true(r.ok, 'step ' .. i .. ': ' .. tostring(r.error))
    end
end

-- stays on site long enough (1 Hz samples) and reports
local function finish(src, taskId)
    local e = CS.live[taskId]
    at(src, e.site)
    CS.Sample(Mock.clock)
    Mock.clock = Mock.clock + e.minSeconds
    CS.Sample(Mock.clock)
    return CS.Complete(src, taskId)
end

describe('19C sign-in', function()
    it('opens a shift only inside a sign-in zone and activates the order', function()
        local oid = newOrder('WORKER1', 3)
        Mock.coords[W] = vector3(0, 0, 0)
        local r = CS.StartShift(W)
        assert_eq(r.error, 'too_far')
        Mock.coords[W] = DESK
        r = CS.StartShift(W)
        assert_true(r.ok, 'signed in')
        assert_eq(DB.orders[oid].state, 'active', 'assigned -> active on the first shift')
        assert_eq(DB.shifts[r.shiftId].site, 'cityhall')
        local again = CS.StartShift(W)
        assert_true(again.duplicate, 'the open shift is returned')
        assert_eq(again.shiftId, r.shiftId)
    end)
    it('refuses a citizen without an open order', function()
        assert_eq(CS.StartShift(W).error, 'not_found')
    end)
end)

describe('19C work list and claims', function()
    it('lists eligible GOV work near the server position and claims one unit as kind cs', function()
        newOrder('WORKER1', 3)
        CS.StartShift(W)
        Mock.coords[W] = vector3(100, 200, 30)
        local l = CS.ListWork(W)
        assert_true(l.ok)
        local f = GOV.listFilters[1]
        assert_eq(f.csEligible, true)
        assert_eq(f.near.x, 100) assert_eq(f.near.y, 200) assert_eq(f.near.r, 1500.0)
        assert_eq(#l.list, 1, 'the fully claimed order is left out')
        assert_eq(l.list[1].id, 7)
        local c = CS.Claim(W, 7)
        assert_true(c.ok)
        local t = DB.tasks[c.taskId]
        assert_eq(t.claim_id, 1) assert_eq(t.kind, 'litter') assert_eq(t.steps_needed, 5)
        assert_eq(GOV.claims[1].ref, 'pf-justice:cs:shift:' .. t.shift_id)
        assert_eq(CS.Claim(W, 7).error, 'conflict', 'one task at a time')
    end)
    it('needs an open shift', function()
        newOrder('WORKER1', 3)
        assert_eq(CS.ListWork(W).error, 'invalid_state')
        assert_eq(CS.Claim(W, 7).error, 'invalid_state')
        assert_eq(#GOV.claims, 0)
    end)
end)

describe('19C steps are validated on the server', function()
    it('checks order, position, timing and vehicle', function()
        newOrder('WORKER1', 3)
        local id = startTask(W)
        local e = CS.live[id]
        -- litter points are spread over the site
        for i = 2, #e.points do
            for j = 1, i - 1 do
                local dx, dy = e.points[i].x - e.points[j].x, e.points[i].y - e.points[j].y
                assert_true(math.sqrt(dx * dx + dy * dy) >= 3.0, 'points apart')
            end
        end
        at(W, e.points[1])
        assert_eq(CS.Step(W, id, 2).error, 'invalid_state', 'not the next step')
        at(W, e.points[2])
        assert_eq(CS.Step(W, id, 1).error, 'too_far', 'at another point')
        at(W, e.points[1])
        Mock.vehicleOf[W] = 99
        assert_eq(CS.Step(W, id, 1).error, 'invalid_state', 'in a vehicle')
        Mock.vehicleOf[W] = nil
        assert_true(CS.Step(W, id, 1).ok)
        assert_eq(DB.tasks[id].steps_done, 1)
        at(W, e.points[2])
        Mock.clock = Mock.clock + 5
        assert_eq(CS.Step(W, id, 2).error, 'rate_limited', 'MinStepSeconds apart')
        Mock.clock = Mock.clock + 20
        assert_true(CS.Step(W, id, 2).ok)
        assert_eq(DB.tasks[id].steps_done, 2)
    end)
    it('applies the item rule on the server', function()
        Config.CommunityService.TaskItems = { litter = { tool = 'weapon_garbagebag', consume = 'trashbag' } }
        newOrder('WORKER1', 3)
        local id = startTask(W)
        at(W, CS.live[id].points[1])
        assert_eq(CS.Step(W, id, 1).error, 'no_permission', 'no tool')
        INV.has[W .. ':weapon_garbagebag'] = true
        assert_eq(CS.Step(W, id, 1).error, 'no_permission', 'no supplies')
        assert_eq(DB.tasks[id].steps_done, 0)
        INV.has[W .. ':trashbag'] = true
        assert_true(CS.Step(W, id, 1).ok)
        assert_eq(#INV.removed, 1)
        assert_eq(INV.removed[1].name, 'trashbag')
    end)
    it('the net event runs the same checks and answers with the state', function()
        newOrder('WORKER1', 3)
        local id = startTask(W)
        at(W, CS.live[id].points[1])
        Mock.fireNet('pf-justice:server:CsTaskStep', W, id, 1)
        assert_eq(DB.tasks[id].steps_done, 1)
        local st = Mock.clientEventsNamed('pf-justice:client:CsState')
        assert_true(#st >= 1)
        local s = st[#st].args[1]
        assert_eq(s.task.id, id) assert_eq(s.task.stepsDone, 1)
        Mock.fireNet('pf-justice:server:CsTaskStep', 99, id, 2) -- another player
        assert_eq(DB.tasks[id].steps_done, 1)
    end)
end)

describe('19C a unit counts only after GOV ReportWorkUnit ok', function()
    it('refuses before the steps and before the time on site, without asking GOV', function()
        local oid = newOrder('WORKER1', 3)
        local id = startTask(W)
        doSteps(W, id, 4)
        at(W, SITE)
        assert_eq(CS.Complete(W, id).error, 'invalid_state')
        doSteps(W, id)
        at(W, SITE)
        CS.Sample(Mock.clock)
        Mock.clock = Mock.clock + 10
        CS.Sample(Mock.clock)
        local r = CS.Complete(W, id)
        assert_eq(r.error, 'too_soon')
        assert_true(r.remaining > 0)
        -- leaving the site breaks the stretch
        Mock.coords[W] = vector3(0, 0, 0)
        CS.Sample(Mock.clock)
        assert_eq(CS.live[id].since, nil)
        assert_eq(#GOV.reports, 0)
        assert_eq(units(oid), 0)
    end)
    it('counts nothing when GOV refuses or does not answer', function()
        local oid = newOrder('WORKER1', 3)
        local id = startTask(W)
        doSteps(W, id)
        GOV.reportResult = { ok = false, error = 'too_soon', remaining = 20 }
        assert_eq(finish(W, id).error, 'too_soon')
        GOV.reportResult = { ok = false, error = 'db_unavailable' }
        assert_eq(CS.Complete(W, id).error, 'db_unavailable')
        assert_eq(units(oid), 0)
        assert_eq(DB.tasks[id].state, 'active', 'the task is kept')
        GOV.reportResult = nil
        local r = CS.Complete(W, id)
        assert_true(r.ok)
        assert_eq(units(oid), 1)
        assert_eq(DB.tasks[id].state, 'done')
        assert_eq(GOV.reports[#GOV.reports].key, 'pf-justice:cs:' .. id)
        assert_eq(GOV.reports[#GOV.reports].src, W)
        -- a repeat counts once
        local again = CS.Complete(W, id)
        assert_true(again.ok == false or again.duplicate == true)
        assert_eq(units(oid), 1)
    end)
    it('a lapsed claim is renewed for the same work (steps kept); gone work ends the task with nothing counted', function()
        local oid = newOrder('WORKER1', 3)
        local id = startTask(W)
        doSteps(W, id)
        at(W, SITE)
        CS.Sample(Mock.clock)
        Mock.clock = Mock.clock + 700 -- the GOV claim (600 s) lapsed
        CS.Sample(Mock.clock)
        local r = CS.Complete(W, id)
        assert_true(r.renewed, 'renewed')
        assert_eq(DB.tasks[id].claim_id, 2)
        assert_eq(DB.tasks[id].steps_done, 5)
        assert_true(CS.Complete(W, id).ok)
        assert_eq(units(oid), 1)
        -- a second task whose work order closes
        local c = CS.Claim(W, 7)
        doSteps(W, c.taskId)
        GOV.orders[7].status = 'completed'
        GOV.claims[3].expiresAt = Mock.clock - 1
        r = finish(W, c.taskId)
        assert_eq(r.error, 'invalid_state')
        assert_eq(DB.tasks[c.taskId].state, 'expired')
        assert_eq(units(oid), 1)
    end)
    it('completes the order at its units and ends the shift', function()
        local oid = newOrder('WORKER1', 2)
        local id = startTask(W)
        doSteps(W, id)
        assert_true(finish(W, id).ok)
        local c = CS.Claim(W, 7)
        doSteps(W, c.taskId)
        local r = finish(W, c.taskId)
        assert_true(r.completed, 'completed')
        assert_eq(DB.orders[oid].state, 'completed')
        assert_eq(units(oid), 2)
        assert_true(DB.shifts[1].ended_at ~= nil)
    end)
    it('a vacated order counts nothing more and gives the claim back', function()
        local oid = newOrder('WORKER1', 3)
        local id = startTask(W)
        doSteps(W, id)
        DB.orders[oid].state = 'vacated'
        local r = finish(W, id)
        assert_eq(r.error, 'invalid_state')
        assert_eq(#GOV.reports, 0)
        assert_eq(DB.tasks[id].state, 'rejected')
        assert_eq(GOV.released[1], DB.tasks[id].claim_id)
    end)
end)

describe('19C disconnect keeps progress', function()
    it('resumes the shift, the task and its steps after a reconnect (new claim for the same work)', function()
        local oid = newOrder('WORKER1', 3)
        local id = startTask(W)
        doSteps(W, id, 3)
        Mock.fireEvent('playerDropped', W)
        assert_eq(CS.live[id], nil)
        assert_eq(DB.tasks[id].steps_done, 3)
        Mock.players[W] = nil
        Mock.clock = Mock.clock + 3600 -- the claim lapsed while away
        Mock.newPlayer(5, 'WORKER1')
        Mock.coords[5] = vector3(0, 0, 0)
        Mock.fireEvent('QBCore:Server:PlayerLoaded', nil, Mock.players[5])
        local e = CS.live[id]
        assert_true(e ~= nil, 'resumed')
        assert_eq(e.src, 5) assert_eq(e.stepsDone, 3)
        assert_eq(DB.tasks[id].claim_id, 2, 'claimed again')
        local st = Mock.clientEventsNamed('pf-justice:client:CsState')
        assert_eq(st[#st].args[1].task.stepsDone, 3)
        doSteps(5, id)
        assert_true(finish(5, id).ok)
        assert_eq(units(oid), 1)
    end)
    it('a shift past ShiftMaxHours ends and gives the claim back; units stay', function()
        local oid = newOrder('WORKER1', 3)
        local id = startTask(W)
        doSteps(W, id)
        assert_true(finish(W, id).ok)
        local c = CS.Claim(W, 7)
        Mock.clock = Mock.clock + 5 * 3600
        assert_eq(CS.StaleTick(Mock.clock), 1)
        assert_true(DB.shifts[1].ended_at ~= nil)
        assert_eq(DB.tasks[c.taskId].state, 'released')
        assert_eq(units(oid), 1)
    end)
end)

describe('19C supervisor verification', function()
    it('only an on-duty qualified supervisor nearby verifies; supervised units count x bonus', function()
        Config.CommunityService.SupervisorBonus = 1.5
        local oid = newOrder('WORKER1', 5)
        local id = startTask(W)
        at(W, SITE)
        assert_eq(CS.Verify(SUP, W).error, 'no_permission', 'no qualification')
        GOV.quals['SUPER1:cs_supervisor'] = true
        Mock.players[SUP].PlayerData.job.onduty = false
        assert_eq(CS.Verify(SUP, W).error, 'no_permission', 'off duty')
        Mock.players[SUP].PlayerData.job.onduty = true
        Mock.players[SUP].PlayerData.job.grade = { level = 1 }
        assert_eq(CS.Verify(SUP, W).error, 'no_permission', 'grade below the probation officer')
        Mock.players[SUP].PlayerData.job.grade = { level = 3 }
        Mock.coords[SUP] = vector3(0, 0, 0)
        assert_eq(CS.Verify(SUP, W).error, 'too_far')
        Mock.coords[SUP] = vector3(SITE.x + 5, SITE.y, SITE.z)
        assert_eq(CS.Verify(W, W).error, 'no_permission', 'not yourself')
        assert_true(CS.Verify(SUP, W).ok)
        assert_eq(DB.shifts[1].supervisor_cid, 'SUPER1')
        assert_eq(units(oid), 0, 'verifying counts nothing by itself')
        doSteps(W, id)
        assert_true(finish(W, id).ok)
        assert_eq(units(oid), 1, 'floor(1.5)')
        local c = CS.Claim(W, 7)
        doSteps(W, c.taskId)
        assert_true(finish(W, c.taskId).ok)
        assert_eq(units(oid), 3, 'floor(3.0)')
        assert_eq(DB.shifts[1].units, 3)
        assert_eq(#GOV.reports, 2)
    end)
end)

describe('19C overdue goes to the court, never to prison', function()
    it('files one court item per overdue order and keeps it finishable', function()
        local oid = newOrder('WORKER1', 1, 'overdue', Mock.clock - 10)
        local before = DB.n.o
        J.fileCaseResult = { ok = false, error = 'db_unavailable' }
        assert_eq(CS.CourtTick(Mock.clock), 0)
        J.fileCaseResult = nil
        assert_eq(CS.CourtTick(Mock.clock), 1)
        assert_eq(#filed, 2, 'retried after the failure')
        local f = filed[2]
        assert_eq(f.spec.kind, 'violation') assert_eq(f.spec.cid, 'WORKER1')
        assert_eq(f.opts.key, 'pf-justice:cs:order:' .. oid .. ':court')
        assert_eq(CS.CourtTick(Mock.clock), 0, 'once')
        assert_eq(#filed, 2)
        assert_eq(DB.n.o, before, 'no new order (no prison)')
        assert_eq(DB.orders[oid].state, 'overdue')
        -- still finishable
        local id = startTask(W)
        doSteps(W, id)
        assert_true(finish(W, id).completed)
        assert_eq(DB.orders[oid].state, 'completed')
    end)
end)

describe('19C GetCommunityService', function()
    it('answers through the caller allowlist', function()
        local oid = newOrder('WORKER1', 4)
        Mock.invokingResource = 'pf-government'
        local r = Mock.selfExport('GetCommunityService')('WORKER1')
        assert_true(r.ok)
        assert_eq(r.orders[1].orderId, oid) assert_eq(r.orders[1].units, 4) assert_eq(r.orders[1].unitsDone, 0)
        Config.Callers.GetCommunityService = nil
        assert_eq(Mock.selfExport('GetCommunityService')('WORKER1').error, 'not_allowed')
        Mock.invokingResource = nil
    end)
end)
