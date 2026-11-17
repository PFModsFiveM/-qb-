-- The daily routine of the prison (batch 19D; config_facility.lua Config.Facility.Routine).
--
-- One cycle of phases (count, meal, work, yard, count, meal, lock-in) repeats from a fixed anchor,
-- so the phase is the same after a restart. Every tick each online inmate gets the activity the
-- phase gives them (raised as pfm-prison:server:inmateStatus): solitary, a visit in progress or a
-- lockdown come first; yard and work need the privilege (discipline.lua).
--
-- Low population: a headcount opens only when at least one inmate is online (expected = the
-- inmates online during the count). It closes at the end of the phase by itself, or earlier when an
-- on-duty corrections officer inside the walls conducts it. Presence is the server's: the walls
-- test of the escape sampler. An inmate who logged off during the count is listed as offline, not
-- missing; one in the infirmary or on a transfer is accounted for. Meals are timed events: each
-- online inmate inside the walls is served once per meal (also one who logs in during it); the
-- serving is recorded as a 'meal' row so a restart does not serve twice.

PFPrison = PFPrison or {}
PFPrison.Schedule = PFPrison.Schedule or {}
local S = PFPrison.Schedule
local F = PFPrison.Facility
local I = PFPrison.Internal
local CF = Config.Facility or {}
local R = CF.Routine or {}
local num = F.num

S.lastKey = S.lastKey or nil
S.openCount = S.openCount or nil
S.served = S.served or { key = nil, cids = {} }
S.mealProvider = S.mealProvider or nil

local ACCOUNTED = { infirmary = true, transfer = true }

-- ── phases ─────────────────────────────────────────────────────────────────────────────────────

local function phases()
    local out = {}
    for _, p in ipairs(R.Phases or {}) do
        local m = num(p.minutes, 0)
        if type(p.name) == 'string' and m > 0 then out[#out + 1] = { name = p.name, seconds = math.floor(m * 60), count = p.count == true, meal = p.meal } end
    end
    if #out == 0 then out[1] = { name = 'lockin', seconds = 3600 } end
    return out
end

function S.CycleSeconds()
    local total = 0
    for _, p in ipairs(phases()) do total = total + p.seconds end
    return total
end

--- The phase at `now`: { index, name, label, startsAt, endsAt, count, meal, key }.
function S.Phase(now)
    now = now or os.time()
    local list = phases()
    local cycle = S.CycleSeconds()
    local anchor = num(R.Anchor, 0)
    local n = math.floor((now - anchor) / cycle)
    local t = (now - anchor) - n * cycle
    local start = anchor + n * cycle
    for i, p in ipairs(list) do
        if t < p.seconds then
            return { index = i, name = p.name, label = (R.Labels or {})[p.name] or p.name, startsAt = start, endsAt = start + p.seconds,
                count = p.count, meal = p.meal, key = ('%d:%d'):format(n, i) }
        end
        t = t - p.seconds
        start = start + p.seconds
    end
    local p = list[#list]
    return { index = #list, name = p.name, label = p.name, startsAt = start, endsAt = start + p.seconds, key = ('%d:%d'):format(n, #list) }
end

--- When the next headcount is due (the current one while it is open).
function S.NextCount(now)
    now = now or os.time()
    if S.openCount then return S.openCount.dueAt end
    local t = now
    for _ = 1, #phases() * 2 + 1 do
        local p = S.Phase(t)
        if p.count and p.startsAt >= now then return p.startsAt end
        t = p.endsAt
    end
    return nil
end

--- Whether an activity is open now (work.lua of 19E may ask before giving a job).
function S.Allows(activity, now)
    now = now or os.time()
    if F.IsLockedDown(now) then return false end
    local p = S.Phase(now)
    if activity == 'work' then return p.name ~= 'count' and p.name ~= 'lockin' end
    if activity == 'yard' then return p.name == 'yard' end
    return true
end

-- ── activity ───────────────────────────────────────────────────────────────────────────────────

--- What the routine makes of one online inmate now.
function S.ActivityFor(cid, phase, now, src)
    local D, V = PFPrison.Discipline, PFPrison.Visitation
    -- in the prison infirmary or on an escorted hospital transfer (pf-ambulancejob custody care)
    local care = F.CareKind(src or F.SrcOf(cid))
    if care then return care end
    if F.intakeAt[cid] and now - F.intakeAt[cid] < num(CF.IntakeSeconds, 60) then return 'intake' end
    if D and F.Callable(D.InSolitary) and D.InSolitary(cid, now) then return 'solitary' end
    if V and F.Callable(V.InProgress) and V.InProgress(cid) then return 'visitation' end
    if F.IsLockedDown(now) then return 'in_cell' end
    local has = function(kind) return not (D and F.Callable(D.HasPrivilege)) or D.HasPrivilege(cid, kind, now) end
    if phase.name == 'meal' then return 'meal' end
    if phase.name == 'work' then return has('work') and 'work' or 'in_cell' end
    if phase.name == 'yard' then return has('yard') and 'yard' or 'in_cell' end
    return 'in_cell'
end

-- ── meals ──────────────────────────────────────────────────────────────────────────────────────

--- 19E's kitchen may serve meals from its own stock: fn(cid, src, meal) -> true when served.
function F.SetMealProvider(fn)
    if fn ~= nil and not F.Callable(fn) then return false end
    S.mealProvider = fn
    return true
end

local function giveMeal(cid, src, meal)
    if S.mealProvider then
        local ok, served = pcall(S.mealProvider, cid, src, meal)
        if ok and served == true then return true end
    end
    local items = R.Meal or {}
    if #items == 0 then return false end
    local given = 0
    for _, it in ipairs(items) do
        local ok, added = pcall(function()
            return exports['pfm-inventory']:AddItem(src, it.name, math.max(1, math.floor(num(it.amount, 1))), false, false, 'pfm-prison:meal')
        end)
        if ok and added then given = given + 1 end
    end
    return given > 0
end

function S.ServeMeals(phase, now)
    if S.served.key ~= phase.key then S.served = { key = phase.key, cids = {} } end
    local n = 0
    for _, e in ipairs(F.OnlineInmates()) do
        if not S.served.cids[e.cid] and I.insidePrison(I.pedPos(e.src)) then
            if giveMeal(e.cid, e.src, phase.meal) then
                S.served.cids[e.cid] = true
                F.Audit(e.cid, 'meal', { meal = phase.meal, key = phase.key })
                F.Notify(e.src, 'You were served ' .. tostring(phase.meal or 'a meal'), 'success')
                n = n + 1
            end
        end
    end
    return n
end

-- ── headcounts ─────────────────────────────────────────────────────────────────────────────────

--- Opens a count when at least one inmate is online. Returns the open count or nil.
function S.OpenCount(dueAt, closesAt, now, phaseKey)
    if S.openCount then return S.openCount end
    -- one routine count per count phase (an officer may close it early; it does not reopen)
    if phaseKey then
        if S.countKey == phaseKey then return nil end
    end
    local online = F.OnlineInmates()
    if #online == 0 then return nil end
    local expected = {}
    for _, e in ipairs(online) do expected[e.cid] = true end
    local id, ok = F.Db('insert', 'INSERT INTO pf_prison_counts (facility, due_at, expected, present) VALUES (?, ?, ?, 0)', { F.FAC, dueAt, #online })
    if not ok then return nil end
    if phaseKey then S.countKey = phaseKey end
    S.openCount = { id = math.tointeger(tonumber(id)), dueAt = dueAt, closesAt = closesAt, expected = expected, openedAt = now }
    for _, e in ipairs(online) do F.Notify(e.src, 'Headcount: stand by your cell', 'primary') end
    F.NotifyStaff(('Headcount open: %d inmate(s) online'):format(#online), 'primary')
    return S.openCount
end

--- Closes the open count with the server's presence. byCid = the officer, or nil (the routine).
function S.CloseCount(byCid, now)
    local c = S.openCount
    if not c then return nil end
    now = now or os.time()
    local present, missing, offline, accounted = 0, {}, {}, {}
    local expected = 0
    for cid in pairs(c.expected) do
        expected = expected + 1
        local src = F.SrcOf(cid)
        local row = F.Row(cid)
        local act = F.activity[cid]
        if not src then
            offline[#offline + 1] = cid
        elseif row and ((act and ACCOUNTED[act.status]) or F.CareKind(src)) then
            accounted[#accounted + 1] = cid
            present = present + 1
        elseif row and I.insidePrison(I.pedPos(src)) then
            present = present + 1
        elseif row then
            missing[#missing + 1] = cid
        else
            -- released or escaped during the count: the bridge and the escape path report those
            offline[#offline + 1] = cid
        end
    end
    table.sort(missing)
    local detail = F.Encode({ missing = missing, offline = offline, accounted = accounted })
    local n = F.Db('update', [[UPDATE pf_prison_counts SET closed_at = ?, expected = ?, present = ?, missing = ?, by_cid = ?
        WHERE id = ? AND closed_at IS NULL]], { now, expected, present, detail, byCid, c.id })
    S.openCount = nil
    if tonumber(n) ~= 1 then return nil end
    F.Audit(nil, 'count', { countId = c.id, expected = expected, present = present, missing = missing, offline = #offline }, byCid)
    if #missing > 0 then
        F.NotifyStaff(('Headcount: %d missing (%s)'):format(#missing, table.concat(missing, ', ', 1, math.min(#missing, 5))), 'error')
    else
        F.NotifyStaff(('Headcount clear: %d/%d present'):format(present, expected - #offline), 'success')
    end
    return { countId = c.id, expected = expected, present = present, missing = missing, offline = offline, accounted = accounted }
end

--- An officer conducts the count (on duty, inside the walls). With no count open one is held at once.
function S.ConductCount(src)
    local P, e = F.Staff(src, 0)
    if not P then return e end
    local pos = F.Pos(src)
    if not pos or not I.insidePrison(pos) then return F.Err('too_far', 'Conduct the count from inside the facility') end
    local now = os.time()
    if not S.openCount then
        if not S.OpenCount(now, now, now) then return F.Err('invalid_state', 'No inmate is online; there is nobody to count') end
    end
    local res = S.CloseCount(P.PlayerData.citizenid, now)
    if not res then return F.Err('db_unavailable', 'The count could not be recorded') end
    res.ok = true
    return res
end

-- ── tick ───────────────────────────────────────────────────────────────────────────────────────

function S.Tick(now)
    now = now or os.time()
    local phase = S.Phase(now)
    if S.openCount and now >= S.openCount.closesAt then S.CloseCount(nil, now) end
    local entered = S.lastKey ~= phase.key
    S.lastKey = phase.key
    if entered then
        if phase.count then S.OpenCount(phase.startsAt, phase.endsAt, now, phase.key) end
        if not F.IsLockedDown(now) then
            for _, e in ipairs(F.OnlineInmates()) do F.Notify(e.src, phase.label, 'primary') end
        end
    end
    local online = F.OnlineInmates()
    if phase.count and not S.openCount and #online > 0 and S.countKey ~= phase.key then
        -- the first inmate came online during the count phase
        S.OpenCount(phase.startsAt, phase.endsAt, now, phase.key)
    end
    if S.openCount then
        for _, e in ipairs(online) do S.openCount.expected[e.cid] = true end
    end
    if phase.meal then S.ServeMeals(phase, now) end
    for _, e in ipairs(online) do
        local status = S.ActivityFor(e.cid, phase, now, e.src)
        if F.SetActivity(e.cid, status) then
            TriggerClientEvent('pfm-prison:client:Routine', e.src, { phase = phase.name, label = phase.label, endsAt = phase.endsAt, status = status })
        end
    end
end

--- Start: a count left open by a restart is closed as interrupted; meals already served in the
--- running meal phase are not served again.
function S.Boot(now)
    now = now or os.time()
    F.Db('update', [[UPDATE pf_prison_counts SET closed_at = ?, missing = '{"interrupted":true}' WHERE facility = ? AND closed_at IS NULL]], { now, F.FAC })
    S.openCount, S.lastKey = nil, nil
    local phase = S.Phase(now)
    S.served = { key = phase.key, cids = {} }
    if phase.meal then
        local rows = F.Db('query', "SELECT citizenid FROM pf_prison_events WHERE facility = ? AND kind = 'meal' AND at >= ?", { F.FAC, phase.startsAt })
        for _, r in ipairs(type(rows) == 'table' and rows or {}) do
            if r.citizenid then S.served.cids[r.citizenid] = true end
        end
    end
    return true
end

-- ── callbacks ──────────────────────────────────────────────────────────────────────────────────

F.Callback('conductCount', function(src) return S.ConductCount(src) end)

--- The routine as anyone sees it (an inmate also gets their own status).
F.Callback('routine', function(src)
    local now = os.time()
    local p = S.Phase(now)
    local cid = F.CidOf(src)
    return { ok = true, phase = p.name, label = p.label, endsAt = p.endsAt, nextCount = S.NextCount(now),
        lockdown = F.IsLockedDown(now), status = cid and F.Row(cid) and F.Activity(cid) or nil }
end)

--- The last counts (staff).
F.Callback('countHistory', function(src)
    local P, e = F.Staff(src, 0)
    if not P then return e end
    local rows = F.Db('query', [[SELECT id, due_at, closed_at, expected, present, missing, by_cid FROM pf_prison_counts
        WHERE facility = ? ORDER BY id DESC LIMIT 20]], { F.FAC })
    local list = {}
    for _, r in ipairs(type(rows) == 'table' and rows or {}) do
        list[#list + 1] = { id = tonumber(r.id), dueAt = tonumber(r.due_at), closedAt = tonumber(r.closed_at), expected = tonumber(r.expected),
            present = tonumber(r.present), detail = F.Decode(r.missing), by = r.by_cid }
    end
    return { ok = true, counts = list }
end)
