-- The Corrections MDT on the tablet and the computer (batch 21E; pf-devices module app 'corrections').
--
-- The page (html/apps/corrections.js) calls the handlers below through pf-devices ctx.rpc. pf-devices
-- lets only on-duty corrections staff in (access rule); every handler reads the player's job, duty and
-- grade again here (PFPrison.Facility.Staff) before it reads or changes anything, and every change is
-- made by the existing modules, which check again:
--   facility.lua   roster, cells, classification, lockdown (also through security.lua), status
--   schedule.lua   routine phases, headcounts (an officer counts from inside the walls)
--   discipline.lua infractions, hearings, sanctions
--   visitation.lua the day's visit board, visitor searches, cancellations
--   security.lua   alarms, doors (read), camera points (listed only: a camera is watched at the
--                  gatehouse control point, security.lua ViewCamera; there is no video recording)
--   economy.lua    trust accounts (read only here: money moves only at the trust window and the ledger)
--   pf-justice     the sentence (GetActiveIncarceration: pf-justice owns the one clock)
-- Positions, grades, times and amounts never come from the page. A relative time the page sends
-- (a hearing "in N minutes") is turned into a time here with the server's clock.

PFPrison = PFPrison or {}
PFPrison.Apps = PFPrison.Apps or {}
local A = PFPrison.Apps
local RES = GetCurrentResourceName()
local APP_ID = 'corrections'

local function num(v, d) return tonumber(v) or d end
local function F() return PFPrison.Facility end
local function S() return PFPrison.Schedule end
local function D() return PFPrison.Discipline end
local function V() return PFPrison.Visitation end
local function Sec() return PFPrison.Security end
local function E() return PFPrison.Economy end
local function B() return PFPrison.Bridge end
local function CF() return Config.Facility or {} end
local function DC() return (Config.Facility or {}).Discipline or {} end
-- optional overrides (Config.CorrectionsApp is not in config.lua yet; these are the defaults)
local function AC() return Config.CorrectionsApp or {} end

local PAGE = 25
local STATUSES = { intake = true, in_cell = true, yard = true, work = true, meal = true, infirmary = true, visitation = true,
    solitary = true, transfer = true, escaped = true }
local SORTS = { cell = true, name = true, admitted = true, class = true }

local function err(code, message) return { ok = false, error = code, message = message } end

local function callable(v)
    if type(v) == 'function' then return true end
    if type(v) ~= 'table' then return false end
    if type(rawget(v, '__cfx_functionReference')) == 'string' then return true end
    local mt = getmetatable(v)
    return type(mt) == 'table' and rawget(mt, '__call') ~= nil
end

--- The facility modules this app relays to must be loaded.
local function ready()
    local f = F()
    return type(f) == 'table' and callable(f.Staff)
end

-- ── who is asking ──────────────────────────────────────────────────────────────────────────────

local function grades()
    local G = CF().Grades or {}
    return {
        housing = num(G.Housing, 2),
        lockdown = num(G.Lockdown, 3),
        hearing = num(DC().HearingGrade, 2),
        trust = num(AC().TrustGrade, 1),
    }
end

--- On-duty corrections staff of at least minGrade (read now, never from the page).
--- Returns P, grade or nil, error.
local function staff(src, minGrade)
    if not ready() then return nil, err('unavailable', 'The facility is not running') end
    local P, e, grade = F().Staff(src, minGrade or 0)
    if not P then return nil, e or err('no_permission', 'Corrections staff only') end
    return P, num(grade, 0)
end
A.Staff = staff

--- What this grade may do; the page shows only these actions (the handlers check again).
function A.Can(grade)
    local g = grades()
    grade = num(grade, 0)
    return {
        housing = grade >= g.housing, lockdown = grade >= g.lockdown, hearing = grade >= g.hearing, trust = grade >= g.trust,
        report = true, count = true, visits = true, alarms = true,
    }
end

-- ── names (online characters first, then one query for the rest; cached briefly) ───────────────

A.names = A.names or {} -- [cid] = { name, at }

local function nameOf(charinfo)
    if type(charinfo) == 'string' then
        local ok, v = pcall(json.decode, charinfo)
        charinfo = ok and v or nil
    end
    if type(charinfo) ~= 'table' or not charinfo.firstname then return nil end
    return (tostring(charinfo.firstname) .. ' ' .. tostring(charinfo.lastname or '')):gsub('%s+$', ''):sub(1, 60)
end

--- { [cid] = name } for up to 200 citizen ids (unknown ones are left out).
function A.Names(cids)
    local out, missing, seen = {}, {}, {}
    local now = os.time()
    local f = F()
    for _, cid in ipairs(cids or {}) do
        if type(cid) == 'string' and not seen[cid] and f.ValidCid(cid) then
            seen[cid] = true
            local P = f.PlayerByCid(cid)
            local name = P and nameOf(P.PlayerData.charinfo)
            if name then
                out[cid] = name
                A.names[cid] = { name = name, at = now }
            else
                -- a citizen without a players row is remembered too (no query per page)
                local c = A.names[cid]
                if c and now - c.at < 300 then out[cid] = c.name or nil
                elseif #missing < 200 then missing[#missing + 1] = cid end
            end
        end
    end
    if #missing > 0 then
        local marks = string.rep('?, ', #missing - 1) .. '?'
        local rows = f.Db('query', 'SELECT citizenid, charinfo FROM players WHERE citizenid IN (' .. marks .. ')', missing)
        if type(rows) == 'table' then
            for _, cid in ipairs(missing) do A.names[cid] = { name = false, at = now } end
        end
        for _, r in ipairs(type(rows) == 'table' and rows or {}) do
            local name = nameOf(r.charinfo)
            if name and r.citizenid then
                out[r.citizenid] = name
                A.names[r.citizenid] = { name = name, at = now }
            end
        end
    end
    return out
end

-- ── reads ──────────────────────────────────────────────────────────────────────────────────────

local function selfExport(name, ...)
    local args, n = { ... }, select('#', ...)
    local ok, res = pcall(function()
        local e = exports[RES]
        return e[name](e, table.unpack(args, 1, n))
    end)
    if ok and type(res) == 'table' then return res end
    return nil
end

local function facilityStatus()
    local st = selfExport('GetFacilityStatus', F().FAC)
    if type(st) ~= 'table' or st.ok ~= true then return nil end
    return st
end

local function sentenceOf(cid)
    local b = B()
    if not b or not callable(b.Justice) then return nil end
    local res = b.Justice('GetActiveIncarceration', cid)
    if type(res) ~= 'table' or res.ok ~= true then return { available = false } end
    local o = type(res.order) == 'table' and res.order or nil
    if not o then return { available = true, none = true } end
    local charges = {}
    for i, c in ipairs(type(o.charges) == 'table' and o.charges or {}) do
        if i > 50 then break end
        if type(c) == 'table' then charges[#charges + 1] = { code = c.code, label = c.label, count = num(c.count, 1) } end
    end
    return { available = true, orderId = o.id, kind = o.kind, state = o.state, facility = o.facility,
        requiredSeconds = num(o.requiredSeconds, 0), servedSeconds = num(o.servedSeconds, 0),
        creditSeconds = num(o.creditSeconds, 0), forfeitSeconds = num(o.forfeitSeconds, 0),
        remainingSeconds = num(o.remainingSeconds, 0), timeToRelease = num(res.remainingSeconds, 0),
        releaseAt = tonumber(o.releaseAt), createdAt = tonumber(o.createdAt), charges = charges }
end

--- One roster entry of a pf_prison_inmates row (no name).
local function entryOf(cid, row)
    local f = F()
    local cell = row.cell_id and f.cells[row.cell_id]
    return { cid = cid, orderId = row.order_id, cellId = row.cell_id, block = cell and cell.block or nil,
        classification = row.classification, status = f.Activity(cid), online = f.SrcOf(cid) ~= nil, admittedAt = row.admitted_at }
end

local function codesList()
    local out = {}
    for code, def in pairs(DC().Codes or {}) do
        out[#out + 1] = { code = code, label = def.label or code, severity = num(def.severity, 1) }
    end
    table.sort(out, function(a, b) return a.code < b.code end)
    return out
end

local function privilegesList()
    local out = {}
    for kind, on in pairs(DC().Privileges or {}) do if on then out[#out + 1] = kind end end
    table.sort(out)
    return out
end

local function blocks()
    local seen, out = {}, {}
    for _, id in ipairs(F().cellOrder or {}) do
        local c = F().cells[id]
        if c and not seen[c.block] then seen[c.block] = true out[#out + 1] = c.block end
    end
    return out
end

-- ── handlers ───────────────────────────────────────────────────────────────────────────────────

local H = {}
A.Handlers = H

--- What the page needs to start: who you are, what you may do, the facility at a glance.
function H.init(src)
    local P, grade = staff(src, 0)
    if not P then return grade end
    local job = P.PlayerData.job or {}
    local g = grades()
    return { ok = true, now = os.time(),
        me = { name = nameOf(P.PlayerData.charinfo) or P.PlayerData.citizenid, grade = grade,
            gradeLabel = type(job.grade) == 'table' and job.grade.name or nil },
        can = A.Can(grade), status = facilityStatus(),
        codes = codesList(), privileges = privilegesList(), blocks = blocks(),
        classes = (CF().Classification or {}).Order or { 'min', 'medium', 'max' },
        limits = { maxSolitaryMinutes = num(DC().MaxSolitaryMinutes, 60), maxPrivilegeHours = num(DC().MaxPrivilegeHours, 168),
            maxForfeitMinutes = num(DC().MaxForfeitMinutes, 60), minNoticeSeconds = num(DC().MinNoticeSeconds, 300),
            lockdownMaxMinutes = num(CF().LockdownMaxMinutes, 240) },
        grades = g }
end

--- The facility at a glance (also the page's periodic refresh).
function H.status(src)
    local P, e = staff(src, 0)
    if not P then return e end
    local st = facilityStatus()
    if not st then return err('unavailable', 'The facility status is not available') end
    return { ok = true, now = os.time(), status = st }
end

--- Population: filtered, sorted and paged here. payload = { q, status, classification, block, sort, page }.
function H.population(src, p)
    local P, e = staff(src, 0)
    if not P then return e end
    p = type(p) == 'table' and p or {}
    local f = F()
    local q = f.Text(p.q, 40)
    q = q and q:lower() or nil
    local status = STATUSES[p.status] and p.status or nil
    local class = f.ValidClass(p.classification) and p.classification or nil
    local block = type(p.block) == 'string' and #p.block <= 8 and p.block ~= '' and p.block or nil
    local sort = SORTS[p.sort] and p.sort or 'cell'
    local page = f.Int(p.page, 1, 1000) or 1
    local all, cids = {}, {}
    for cid, row in pairs(B().rows or {}) do
        if row.status ~= 'releasing' and #all < 500 then
            all[#all + 1] = entryOf(cid, row)
            cids[#cids + 1] = cid
        end
    end
    local names = A.Names(cids)
    local list = {}
    for _, en in ipairs(all) do
        en.name = names[en.cid]
        local keep = (not status or en.status == status) and (not class or en.classification == class) and (not block or en.block == block)
        if keep and q then
            keep = en.cid:lower():find(q, 1, true) ~= nil or (en.name ~= nil and en.name:lower():find(q, 1, true) ~= nil)
                or (en.cellId ~= nil and en.cellId:lower():find(q, 1, true) ~= nil)
        end
        if keep then list[#list + 1] = en end
    end
    local rank = f.CLASS_RANK or {}
    table.sort(list, function(a, b)
        if sort == 'name' then
            local x, y = (a.name or a.cid):lower(), (b.name or b.cid):lower()
            if x ~= y then return x < y end
        elseif sort == 'admitted' then
            if num(a.admittedAt, 0) ~= num(b.admittedAt, 0) then return num(a.admittedAt, 0) > num(b.admittedAt, 0) end
        elseif sort == 'class' then
            local x, y = num(rank[a.classification], 0), num(rank[b.classification], 0)
            if x ~= y then return x > y end
        end
        local x, y = tostring(a.cellId or '~'), tostring(b.cellId or '~')
        if x ~= y then return x < y end
        return a.cid < b.cid
    end)
    local total = #list
    local pages = math.max(1, math.ceil(total / PAGE))
    if page > pages then page = pages end
    local out = {}
    for i = (page - 1) * PAGE + 1, math.min(total, page * PAGE) do out[#out + 1] = list[i] end
    return { ok = true, now = os.time(), inmates = out, total = total, page = page, pages = pages, pageSize = PAGE }
end

--- One inmate: placement, sentence (pf-justice), discipline, work, and the trust account when the
--- grade may read it. payload = { cid }.
function H.inmate(src, p)
    local P, grade = staff(src, 0)
    if not P then return grade end
    p = type(p) == 'table' and p or {}
    local f = F()
    if not f.ValidCid(p.cid) then return err('bad_args', 'Unknown inmate') end
    local row = B().rows[p.cid]
    if not row or row.status == 'releasing' then return err('not_found', 'Not an inmate here') end
    local inmate = entryOf(p.cid, row)
    inmate.name = A.Names({ p.cid })[p.cid]
    local d = D()
    local infractions, restrictions = {}, {}
    if d and callable(d.List) then infractions = d.List(p.cid, 20) end
    if d and callable(d.Restrictions) then restrictions = d.Restrictions(p.cid) end
    local work = {}
    local rows = f.Db('query', 'SELECT job, credit_seconds, wage, at FROM pf_prison_work_log WHERE citizenid = ? ORDER BY id DESC LIMIT 10', { p.cid })
    for _, r in ipairs(type(rows) == 'table' and rows or {}) do
        work[#work + 1] = { job = r.job, creditSeconds = num(r.credit_seconds, 0), wage = num(r.wage, 0), at = num(r.at, 0) }
    end
    local trust
    if A.Can(grade).trust then trust = A.Trust(p.cid) end
    -- cells this inmate may be moved to: in service, of their class or higher, with room
    local moves = {}
    local occ = f.Occupancy(p.cid)
    local rank = f.CLASS_RANK or {}
    for _, id in ipairs(f.cellOrder or {}) do
        local c = f.cells[id]
        if not c.outOfService and num(rank[c.classification], 0) >= num(rank[row.classification], 0) and (occ[id] or 0) < c.capacity
            and id ~= row.cell_id then
            moves[#moves + 1] = { id = id, block = c.block, classification = c.classification, free = c.capacity - (occ[id] or 0) }
        end
    end
    return { ok = true, now = os.time(), inmate = inmate, sentence = sentenceOf(p.cid), infractions = infractions,
        restrictions = restrictions, work = work, trust = trust, cellOptions = moves }
end

--- Every cell with its occupants.
function H.cells(src)
    local P, e = staff(src, 0)
    if not P then return e end
    local f = F()
    local byCell, cids = {}, {}
    for cid, row in pairs(B().rows or {}) do
        if row.status == 'in_cell' and row.cell_id then
            byCell[row.cell_id] = byCell[row.cell_id] or {}
            local list = byCell[row.cell_id]
            list[#list + 1] = cid
            cids[#cids + 1] = cid
        end
    end
    local names = A.Names(cids)
    local cells = {}
    for _, id in ipairs(f.cellOrder or {}) do
        local c = f.cells[id]
        local occupants = {}
        for _, cid in ipairs(byCell[id] or {}) do occupants[#occupants + 1] = { cid = cid, name = names[cid] } end
        table.sort(occupants, function(a, b) return a.cid < b.cid end)
        cells[#cells + 1] = { id = id, block = c.block, classification = c.classification, capacity = c.capacity,
            occupants = occupants, outOfService = c.outOfService == true }
    end
    -- inmates housed without a cell (overflow) need a cell from staff
    local overflow = {}
    for cid, row in pairs(B().rows or {}) do
        if row.status == 'in_cell' and not row.cell_id then overflow[#overflow + 1] = { cid = cid, classification = row.classification } end
    end
    if #overflow > 0 then
        local on = {}
        for _, o in ipairs(overflow) do on[#on + 1] = o.cid end
        local n2 = A.Names(on)
        for _, o in ipairs(overflow) do o.name = n2[o.cid] end
    end
    return { ok = true, cells = cells, overflow = overflow }
end

function H.assignCell(src, p)
    local P, e = staff(src, grades().housing)
    if not P then return e end
    p = type(p) == 'table' and p or {}
    if not F().ValidCid(p.cid) or type(p.cellId) ~= 'string' or #p.cellId > 16 then return err('bad_args', 'Unknown inmate or cell') end
    if not F().Rate(src, 'app:assignCell', 1) then return err('rate_limited', 'Wait a moment') end
    return F().AssignCell(src, p.cid, p.cellId)
end

function H.setCellService(src, p)
    local P, e = staff(src, grades().housing)
    if not P then return e end
    p = type(p) == 'table' and p or {}
    if type(p.cellId) ~= 'string' or #p.cellId > 16 then return err('bad_args', 'Unknown cell') end
    if not F().Rate(src, 'app:cellService', 1) then return err('rate_limited', 'Wait a moment') end
    return F().SetCellService(src, p.cellId, p.outOfService == true)
end

function H.setClassification(src, p)
    local P, e = staff(src, grades().housing)
    if not P then return e end
    p = type(p) == 'table' and p or {}
    if not F().ValidCid(p.cid) or not F().ValidClass(p.classification) then return err('bad_args', 'Unknown inmate or classification') end
    if not F().Rate(src, 'app:classify', 1) then return err('rate_limited', 'Wait a moment') end
    return F().SetClassification(p.cid, p.classification, { actor = { src = src }, reason = F().Text(p.reason, 120) })
end

--- The routine (phases from now on), the open count and the last counts.
function H.schedule(src)
    local P, e = staff(src, 0)
    if not P then return e end
    local s, f = S(), F()
    if not s or not callable(s.Phase) then return err('unavailable', 'The routine is not running') end
    local now = os.time()
    local cur = s.Phase(now)
    local upcoming, t = {}, now
    for _ = 1, #(((CF().Routine or {}).Phases) or {}) + 1 do
        local ph = s.Phase(t)
        upcoming[#upcoming + 1] = { name = ph.name, label = ph.label, startsAt = ph.startsAt, endsAt = ph.endsAt, count = ph.count == true,
            meal = ph.meal, current = ph.key == cur.key }
        t = ph.endsAt
    end
    local open
    if s.openCount then
        local expected = 0
        for _ in pairs(s.openCount.expected or {}) do expected = expected + 1 end
        open = { id = s.openCount.id, dueAt = s.openCount.dueAt, closesAt = s.openCount.closesAt, expected = expected }
    end
    local rows = f.Db('query', [[SELECT id, due_at, closed_at, expected, present, missing, by_cid FROM pf_prison_counts
        WHERE facility = ? ORDER BY id DESC LIMIT 20]], { f.FAC })
    local counts, cids = {}, {}
    for _, r in ipairs(type(rows) == 'table' and rows or {}) do
        local detail = f.Decode(r.missing)
        counts[#counts + 1] = { id = tonumber(r.id), dueAt = tonumber(r.due_at), closedAt = tonumber(r.closed_at), expected = tonumber(r.expected),
            present = tonumber(r.present), by = r.by_cid, missing = type(detail) == 'table' and detail.missing or nil,
            offline = type(detail) == 'table' and type(detail.offline) == 'table' and #detail.offline or nil,
            interrupted = type(detail) == 'table' and detail.interrupted == true or nil }
        if r.by_cid then cids[#cids + 1] = r.by_cid end
        for _, m in ipairs(counts[#counts].missing or {}) do if type(m) == 'string' then cids[#cids + 1] = m end end
    end
    return { ok = true, now = now, phase = { name = cur.name, label = cur.label, startsAt = cur.startsAt, endsAt = cur.endsAt },
        nextCount = s.NextCount(now), lockdown = f.IsLockedDown(now), upcoming = upcoming, openCount = open,
        counts = counts, names = A.Names(cids) }
end

--- An officer counts now (inside the walls; schedule.lua checks the position).
function H.conductCount(src)
    local P, e = staff(src, 0)
    if not P then return e end
    if not F().Rate(src, 'app:count', 2) then return err('rate_limited', 'Wait a moment') end
    local res = S().ConductCount(src)
    if type(res) == 'table' and res.ok then
        local cids = {}
        for _, c in ipairs(res.missing or {}) do cids[#cids + 1] = c end
        res.names = A.Names(cids)
    end
    return res
end

local INF_COLS = 'id, citizenid, order_id, code, severity, state, evidence_ids, hearing_at, heard_by, sanction, reported_by, at, idem_key'
local INF_SQL = {
    open = 'SELECT ' .. INF_COLS .. " FROM pf_prison_infractions WHERE state IN ('reported', 'hearing_scheduled') ORDER BY id LIMIT ? OFFSET ?",
    closed = 'SELECT ' .. INF_COLS .. " FROM pf_prison_infractions WHERE state IN ('heard', 'sanctioned', 'dismissed') ORDER BY id DESC LIMIT ? OFFSET ?",
    all = 'SELECT ' .. INF_COLS .. ' FROM pf_prison_infractions ORDER BY id DESC LIMIT ? OFFSET ?',
}
A.INF_SQL = INF_SQL

--- Infractions, paged: payload = { filter = 'open' | 'closed' | 'all', page }.
function H.infractions(src, p)
    local P, e = staff(src, 0)
    if not P then return e end
    p = type(p) == 'table' and p or {}
    local filter = INF_SQL[p.filter] and p.filter or 'open'
    local page = F().Int(p.page, 1, 1000) or 1
    local rows = F().Db('query', INF_SQL[filter], { PAGE + 1, (page - 1) * PAGE })
    if rows == nil then return err('db_unavailable', 'The infractions cannot be read right now') end
    local list, cids = {}, {}
    for i, r in ipairs(rows) do
        if i > PAGE then break end
        local item = D().Public(r)
        list[#list + 1] = item
        cids[#cids + 1] = item.cid
        if item.reportedBy then cids[#cids + 1] = item.reportedBy end
    end
    return { ok = true, now = os.time(), list = list, page = page, hasMore = #rows > PAGE, filter = filter, names = A.Names(cids) }
end

--- payload = { cid, code, evidenceIds?, hearingInMinutes? }
function H.reportInfraction(src, p)
    local P, e = staff(src, 0)
    if not P then return e end
    p = type(p) == 'table' and p or {}
    if not F().ValidCid(p.cid) or type(p.code) ~= 'string' or #p.code > 16 then return err('bad_args', 'Pick an inmate and a code') end
    local hearingAt
    if p.hearingInMinutes ~= nil and p.hearingInMinutes ~= '' then
        local m = F().Int(p.hearingInMinutes, 0, 7 * 24 * 60)
        if not m then return err('bad_args', 'The hearing must be within 7 days') end
        hearingAt = os.time() + m * 60
    end
    local ev = p.evidenceIds
    if ev ~= nil and type(ev) ~= 'table' then return err('bad_args', 'Evidence ids must be a list') end
    if not F().Rate(src, 'app:report', 2) then return err('rate_limited', 'Wait a moment') end
    return D().Record(p.cid, { code = p.code, evidenceIds = ev, hearingAt = hearingAt }, { actor = { src = src } })
end

--- payload = { id, inMinutes }: the hearing time is the server's now + inMinutes.
function H.scheduleHearing(src, p)
    local P, e = staff(src, grades().hearing)
    if not P then return e end
    p = type(p) == 'table' and p or {}
    local id = F().Int(p.id, 1, 2147483647)
    local m = F().Int(p.inMinutes, 0, 7 * 24 * 60)
    if not id or not m then return err('bad_args', 'Pick an infraction and a time within 7 days') end
    if not F().Rate(src, 'app:schedule', 1) then return err('rate_limited', 'Wait a moment') end
    return D().ScheduleHearing(src, id, os.time() + m * 60)
end

--- payload = { id, verdict, note?, forfeitMinutes?, solitaryMinutes?, privileges? = { { kind, hours } } }
function H.holdHearing(src, p)
    local P, e = staff(src, grades().hearing)
    if not P then return e end
    p = type(p) == 'table' and p or {}
    local id = F().Int(p.id, 1, 2147483647)
    if not id or (p.verdict ~= 'guilty' and p.verdict ~= 'not_guilty') then return err('bad_args', 'An infraction and a verdict are required') end
    local sanctions
    if p.verdict == 'guilty' then
        sanctions = {}
        if p.forfeitMinutes ~= nil and p.forfeitMinutes ~= '' then sanctions.forfeitMinutes = tonumber(p.forfeitMinutes) or -1 end
        if p.solitaryMinutes ~= nil and p.solitaryMinutes ~= '' then sanctions.solitaryMinutes = tonumber(p.solitaryMinutes) or -1 end
        if p.privileges ~= nil then
            if type(p.privileges) ~= 'table' or #p.privileges > 5 then return err('bad_args', 'privileges are invalid') end
            sanctions.privileges = {}
            for _, x in ipairs(p.privileges) do
                if type(x) ~= 'table' or type(x.kind) ~= 'string' then return err('bad_args', 'privileges are invalid') end
                sanctions.privileges[#sanctions.privileges + 1] = { kind = x.kind, hours = tonumber(x.hours) }
            end
        end
    end
    if not F().Rate(src, 'app:hearing', 2) then return err('rate_limited', 'Wait a moment') end
    return D().HoldHearing(src, id, { verdict = p.verdict, note = F().Text(p.note, 255), sanctions = sanctions })
end

--- Today's visit board (an hour back to a day ahead).
function H.visits(src)
    local P, e = staff(src, 0)
    if not P then return e end
    local res = V().List(src, true)
    if type(res) ~= 'table' or not res.ok then return res end
    local cids = {}
    for _, v in ipairs(res.visits or {}) do cids[#cids + 1] = v.inmate cids[#cids + 1] = v.visitor end
    res.names = A.Names(cids)
    res.now = os.time()
    return res
end

--- An officer standing with the visitor clears or denies them. payload = { id, allow, note? }
function H.visitSearch(src, p)
    local P, e = staff(src, 0)
    if not P then return e end
    p = type(p) == 'table' and p or {}
    local id = F().Int(p.id, 1, 2147483647)
    if not id then return err('bad_args', 'Unknown visit') end
    if not F().Rate(src, 'app:visitSearch', 1) then return err('rate_limited', 'Wait a moment') end
    return V().Search(src, id, p.allow == true, F().Text(p.note, 200))
end

function H.visitCancel(src, p)
    local P, e = staff(src, 0)
    if not P then return e end
    p = type(p) == 'table' and p or {}
    local id = F().Int(p.id, 1, 2147483647)
    if not id then return err('bad_args', 'Unknown visit') end
    if not F().Rate(src, 'app:visitCancel', 1) then return err('rate_limited', 'Wait a moment') end
    return V().Cancel(src, id)
end

--- Lockdown, alarms and doors (doors are worked at the gatehouse; listed here).
function H.security(src)
    local P, e = staff(src, 0)
    if not P then return e end
    local st = selfExport('GetSecurityStatus')
    local fs = facilityStatus()
    if not st and not fs then return err('unavailable', 'Security is not available') end
    st = st or {}
    local cids = {}
    if F().lockdown and F().lockdown.by then cids[1] = F().lockdown.by end
    -- the facility's answer covers the manual lockdown and the one a failed gate hack started
    local locked
    if fs then locked = fs.lockdown == true else locked = st.lockdown == true end
    return { ok = true, now = os.time(), lockdown = locked,
        lockdownUntil = fs and fs.lockdownUntil or nil, lockdownReason = fs and fs.lockdownReason or nil,
        lockdownBy = F().lockdown and F().lockdown.on and F().lockdown.by or nil,
        alarms = st.alarms or {}, doors = st.doors or {}, openEscapes = st.openEscapes, names = A.Names(cids) }
end

--- payload = { on, reason?, minutes? }: a lockdown through security.lua (doors and gates locked
--- too) when it runs, else the facility's own; the grade rule is the facility's (Grades.Lockdown).
function H.setLockdown(src, p)
    local P, e = staff(src, grades().lockdown)
    if not P then return e end
    p = type(p) == 'table' and p or {}
    local on = p.on == true
    local minutes
    if on and p.minutes ~= nil and p.minutes ~= '' then
        minutes = F().Int(p.minutes, 1, num(CF().LockdownMaxMinutes, 240))
        if not minutes then return err('bad_args', ('Minutes must be 1 to %d'):format(num(CF().LockdownMaxMinutes, 240))) end
    end
    local reason = F().Text(p.reason, 120)
    local sec = Sec()
    if sec and callable(sec.SetLockdown) then
        return sec.SetLockdown(on, { actor = { src = src }, reason = reason, minutes = minutes })
    end
    return F().StaffLockdown(src, on, reason, minutes)
end

function H.clearAlarm(src, p)
    local P, e = staff(src, 0)
    if not P then return e end
    p = type(p) == 'table' and p or {}
    local id = F().Int(p.id, 1, 2147483647)
    if not id then return err('bad_args', 'Unknown alarm') end
    local sec = Sec()
    if not sec or not callable(sec.ClearAlarm) then return err('unavailable', 'Security is not available') end
    return sec.ClearAlarm(id, { actor = { src = src } })
end

--- The camera points (positions and labels). Viewing is at the gatehouse control point.
function H.cameras(src)
    local P, e = staff(src, 0)
    if not P then return e end
    local sec = Sec()
    if not sec or not callable(sec.ListCameras) then return err('unavailable', 'Security is not available') end
    local res = sec.ListCameras()
    local points = {}
    for _, c in ipairs((Config.Security or {}).ControlPoints or {}) do points[#points + 1] = c.label end
    res.controlPoints = points
    return res
end

-- ── trust accounts (read only) ─────────────────────────────────────────────────────────────────

--- { balance, incoming, outgoing, recent } of one inmate, or { available = false }.
function A.Trust(cid)
    local e = E()
    if not e or not callable(e.Balance) then return { available = false } end
    local bal = e.Balance(cid)
    if not bal then return { available = false } end
    local recent = {}
    local rows = F().Db('query', 'SELECT kind, amount, ledger_state, at FROM pf_prison_account_tx WHERE citizenid = ? ORDER BY id DESC LIMIT 10', { cid })
    for _, r in ipairs(type(rows) == 'table' and rows or {}) do
        recent[#recent + 1] = { kind = r.kind, amount = num(r.amount, 0), state = r.ledger_state, at = num(r.at, 0) }
    end
    return { available = true, balance = bal.available, settled = bal.settled, incoming = bal.inPending, outgoing = bal.outPending, recent = recent }
end

--- The accounts with money in them (settled rows), largest first, or one inmate's account.
--- payload = { cid? }
function H.trust(src, p)
    local P, e = staff(src, grades().trust)
    if not P then return e end
    p = type(p) == 'table' and p or {}
    if p.cid ~= nil then
        if not F().ValidCid(p.cid) then return err('bad_args', 'Unknown inmate') end
        local t = A.Trust(p.cid)
        if not t.available then return err('unavailable', 'The trust office is unavailable right now') end
        t.ok, t.cid, t.name = true, p.cid, A.Names({ p.cid })[p.cid]
        return t
    end
    local rows = F().Db('query', [[SELECT citizenid, SUM(amount) AS bal FROM pf_prison_account_tx
        WHERE ledger_state IN ('completed', 'internal') AND citizenid <> 'deleted'
        GROUP BY citizenid HAVING bal > 0 ORDER BY bal DESC, citizenid LIMIT 100]], {})
    if rows == nil then return err('db_unavailable', 'The trust office is unavailable right now') end
    local list, cids, total = {}, {}, 0
    for _, r in ipairs(rows) do
        local held = B().rows[r.citizenid]
        list[#list + 1] = { cid = r.citizenid, balance = num(r.bal, 0), held = held ~= nil and held.status ~= 'releasing' }
        cids[#cids + 1] = r.citizenid
        total = total + num(r.bal, 0)
    end
    return { ok = true, accounts = list, total = total, names = A.Names(cids) }
end

-- ── registration ───────────────────────────────────────────────────────────────────────────────

function A.Register()
    if GetResourceState('pf-devices') ~= 'started' then return false end
    local ok = pcall(function()
        exports['pf-devices']:RegisterApp({
            id = APP_ID, name = 'Corrections', icon = '🔒', kind = 'module',
            entry = 'html/apps/corrections.js', styles = { 'html/apps/corrections.css' },
            devices = { 'tablet', 'computer' }, category = 'jobs', order = 11,
            access = { jobs = { [CF().StaffJob or 'corrections'] = 0 }, onduty = true },
            window = { width = 1100, height = 720 },
            description = 'Population, cells, counts, discipline, visits and security',
        })
        exports['pf-devices']:RegisterAppHandlers(APP_ID, H)
    end)
    return ok
end

AddEventHandler('onResourceStart', function(resource)
    if resource == RES or resource == 'pf-devices' then A.Register() end
end)
AddEventHandler('pf-devices:server:ready', function() A.Register() end)
