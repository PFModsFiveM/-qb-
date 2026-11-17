-- Visitation (batch 19D; Config.Facility.Visitation; table pf_prison_visits).
--
--   booked -> checked_in -> in_progress -> done        (cancelled | no_show | denied on the way)
--
-- * A citizen books a slot for an inmate (aligned slots in visiting hours, up to HorizonDays ahead,
--   RoomCapacity visits per slot, MaxSocialPerDay social visits per inmate, MaxOpenPerVisitor per
--   visitor). Social visits need the inmate's 'visits' privilege; attorney visits (lawyer / doj
--   grades) are a right and are not taken away by discipline. The visitor gets a mail and a
--   calendar entry (pf-citizen), the inmate a notice.
-- * Check-in at the visitor desk (server position) from CheckInEarlyMinutes before the slot.
-- * With corrections staff on duty a visitor must be searched (cleared) by an officer standing with
--   them before the visit starts; with nobody on duty the visit goes ahead (low population).
-- * The visit is in progress while both stand in the visit room (server positions) during the
--   slot; it ends when the slot ends or one side has been away LeaveGraceSeconds. A lockdown ends
--   running visits. Nobody shows up NoShowMinutes into the slot: no_show.

PFPrison = PFPrison or {}
PFPrison.Visitation = PFPrison.Visitation or {}
local V = PFPrison.Visitation
local F = PFPrison.Facility
local B = PFPrison.Bridge
local CF = Config.Facility or {}
local VC = CF.Visitation or {}
local num, Err = F.num, F.Err

V.active = V.active or {}   -- [visitId] = { id, inmate, visitor, slotAt, state, kind, searched, awaySince, waitedNotice }

local OPEN = { booked = true, checked_in = true, in_progress = true }
local NEXT = {
    booked = { checked_in = true, cancelled = true, no_show = true, denied = true },
    checked_in = { in_progress = true, cancelled = true, no_show = true, denied = true },
    in_progress = { done = true },
}
V.Transitions = NEXT

local function slotSeconds() return math.max(5, num(VC.SlotMinutes, 20)) * 60 end

local function fromRow(r)
    return { id = math.tointeger(tonumber(r.id)), inmate = r.inmate_cid, visitor = r.visitor_cid, slotAt = num(r.slot_at, 0),
        state = r.state, kind = r.kind or 'social', searched = num(r.searched, 0) == 1 }
end

--- Moves a visit (compare-and-set on the state) and keeps the memory in step.
function V.Move(v, to, notes)
    if not (NEXT[v.state] and NEXT[v.state][to]) then return false end
    local n = F.Db('update', 'UPDATE pf_prison_visits SET state = ?, notes = COALESCE(?, notes) WHERE id = ? AND state = ?',
        { to, notes and F.Text(notes, 255) or nil, v.id, v.state })
    if tonumber(n) ~= 1 then return false end
    local from = v.state
    v.state = to
    if not OPEN[to] then V.active[v.id] = nil end
    F.Audit(v.inmate, 'visit', { id = v.id, from = from, to = to, visitor = v.visitor, notes = notes })
    return true
end

function V.InProgress(cid)
    for _, v in pairs(V.active) do
        if v.inmate == cid and v.state == 'in_progress' then return true end
    end
    return false
end

-- ── booking ────────────────────────────────────────────────────────────────────────────────────

local function isAttorney(P)
    local job = P.PlayerData.job or {}
    local min = (VC.AttorneyJobs or {})[job.name]
    if min == nil then return false end
    local grade = type(job.grade) == 'table' and num(job.grade.level, 0) or num(job.grade, 0)
    return grade >= num(min, 0)
end

local function notifyCitizen(cid, slotAt, inmateLabel)
    if GetResourceState('pf-citizen') ~= 'started' then return end
    local when = os.date('%Y-%m-%d %H:%M', slotAt)
    pcall(function()
        exports['pf-citizen']:SendMail(cid, { sender = 'Bolingbroke Penitentiary', senderType = 'government', subject = 'Visit booked',
            message = ('Your visit with %s is booked for %s. Check in at the visitor desk up to %d minutes before.'):format(inmateLabel, when,
                num(VC.CheckInEarlyMinutes, 10)) })
    end)
    pcall(function()
        exports['pf-citizen']:AddCalendarEvent('personal', cid, { title = 'Prison visit', description = 'Visit with ' .. inmateLabel,
            location = 'Bolingbroke Penitentiary', starts = slotAt, ends = slotAt + slotSeconds(), remind = 30 }, 'Bolingbroke Penitentiary')
    end)
end

local function inmateLabel(cid)
    local P = F.PlayerByCid(cid)
    local ci = P and P.PlayerData.charinfo
    if type(ci) == 'table' and ci.firstname then return (tostring(ci.firstname) .. ' ' .. tostring(ci.lastname or '')):sub(1, 60) end
    return 'inmate ' .. cid
end

--- A citizen books a visit. kind = 'social' (default) | 'attorney'.
function V.Book(src, inmateCid, slotAt, kind)
    local P = F.Player(src)
    if not P then return Err('bad_args', 'Unknown player') end
    if not F.Rate(src, 'visitBook', 2) then return Err('rate_limited', 'Wait a moment') end
    kind = kind == nil and 'social' or kind
    if kind ~= 'social' and kind ~= 'attorney' then return Err('bad_args', 'Unknown visit kind') end
    if not F.ValidCid(inmateCid) then return Err('bad_args', 'Unknown inmate') end
    local vcid = P.PlayerData.citizenid
    if vcid == inmateCid then return Err('bad_args', 'You cannot visit yourself') end
    local mine = B.rows[vcid]
    if mine and (mine.status == 'in_cell' or mine.status == 'escaped') then return Err('no_permission', 'Inmates cannot book visits') end
    if kind == 'attorney' and not isAttorney(P) then return Err('no_permission', 'Attorney visits are for lawyers and the DOJ') end
    local now = os.time()
    local slot = slotSeconds()
    slotAt = F.Int(slotAt, math.floor(now / slot) * slot, now + num(VC.HorizonDays, 7) * 86400)
    if not slotAt or slotAt % slot ~= 0 then return Err('bad_args', 'Pick one of the offered visiting slots') end
    local hour = tonumber(os.date('*t', slotAt).hour) or 0
    local hours = VC.Hours or { from = 10, to = 22 }
    if hour < num(hours.from, 10) or hour >= num(hours.to, 22) then return Err('bad_args', 'Outside visiting hours') end
    local D = PFPrison.Discipline
    return F.WithLock('visitslot:' .. slotAt, function()
        return F.WithLock('visitinmate:' .. inmateCid, function()
            local row = F.Row(inmateCid)
            if not row then return Err('not_found', 'No such inmate here') end
            if kind == 'social' and D and not D.HasPrivilege(inmateCid, 'visits') then
                return Err('no_permission', "The inmate's visits are suspended")
            end
            local inSlot = F.Db('query', [[SELECT inmate_cid, visitor_cid FROM pf_prison_visits WHERE slot_at = ?
                AND state IN ('booked', 'checked_in', 'in_progress')]], { slotAt })
            if inSlot == nil then return Err('db_unavailable', 'Bookings are unavailable right now') end
            if #inSlot >= num(VC.RoomCapacity, 4) then return Err('conflict', 'That slot is full') end
            for _, r in ipairs(inSlot) do
                if r.inmate_cid == inmateCid then return Err('conflict', 'The inmate already has a visit in that slot') end
                if r.visitor_cid == vcid then return Err('conflict', 'You already have a visit in that slot') end
            end
            local open = F.Db('scalar', [[SELECT COUNT(*) FROM pf_prison_visits WHERE visitor_cid = ? AND state IN ('booked', 'checked_in')
                AND slot_at >= ?]], { vcid, now - slot })
            if num(open, 0) >= num(VC.MaxOpenPerVisitor, 3) then return Err('conflict', 'You have too many open bookings') end
            if kind == 'social' then
                local t = os.date('*t', slotAt)
                local dayStart = os.time({ year = t.year, month = t.month, day = t.day, hour = 0, min = 0, sec = 0 })
                local today = F.Db('scalar', [[SELECT COUNT(*) FROM pf_prison_visits WHERE inmate_cid = ? AND kind = 'social'
                    AND slot_at >= ? AND slot_at < ? AND state NOT IN ('cancelled', 'denied')]], { inmateCid, dayStart, dayStart + 86400 })
                if num(today, 0) >= num(VC.MaxSocialPerDay, 2) then return Err('conflict', 'The inmate has no social visits left that day') end
            end
            local id, ok = F.Db('insert', [[INSERT INTO pf_prison_visits (inmate_cid, visitor_cid, slot_at, state, kind, searched, created_at)
                VALUES (?, ?, ?, 'booked', ?, 0, ?)]], { inmateCid, vcid, slotAt, kind, now })
            id = math.tointeger(tonumber(id))
            if not ok or not id then return Err('db_unavailable', 'The visit could not be booked') end
            V.active[id] = { id = id, inmate = inmateCid, visitor = vcid, slotAt = slotAt, state = 'booked', kind = kind, searched = false }
            F.Audit(inmateCid, 'visit', { id = id, to = 'booked', visitor = vcid, slotAt = slotAt, kind = kind }, vcid)
            F.Notify(F.SrcOf(inmateCid), ('A %s visit was booked for you at %s'):format(kind, os.date('%H:%M', slotAt)), 'primary')
            F.Notify(src, 'Visit booked for ' .. os.date('%Y-%m-%d %H:%M', slotAt), 'success')
            notifyCitizen(vcid, slotAt, inmateLabel(inmateCid))
            return { ok = true, visitId = id, slotAt = slotAt, kind = kind }
        end)
    end)
end

local function load(id)
    id = F.Int(id, 1, 2147483647)
    if not id then return nil end
    if V.active[id] then return V.active[id] end
    local r = F.Db('single', 'SELECT id, inmate_cid, visitor_cid, slot_at, state, kind, searched FROM pf_prison_visits WHERE id = ?', { id })
    return type(r) == 'table' and r.id and fromRow(r) or nil
end

--- The visitor, the inmate or on-duty staff cancel a visit that has not started.
function V.Cancel(src, id)
    local cid = F.CidOf(src)
    if not cid then return Err('bad_args', 'Unknown player') end
    local v = load(id)
    if not v then return Err('not_found', 'Unknown visit') end
    if v.visitor ~= cid and v.inmate ~= cid and not F.Staff(src, 0) then return Err('no_permission', 'Not your visit') end
    return F.WithLock('visit:' .. v.id, function()
        if not V.Move(v, 'cancelled', 'cancelled by ' .. cid) then return Err('invalid_state', 'The visit is ' .. v.state) end
        F.Notify(F.SrcOf(v.inmate == cid and v.visitor or v.inmate), 'A visit was cancelled', 'error')
        return { ok = true }
    end)
end

--- The visitor checks in at the desk.
function V.CheckIn(src, id)
    local cid = F.CidOf(src)
    local v = load(id)
    if not cid or not v or v.visitor ~= cid then return Err('not_found', 'No such visit of yours') end
    local now = os.time()
    if now < v.slotAt - num(VC.CheckInEarlyMinutes, 10) * 60 or now >= v.slotAt + slotSeconds() then
        return Err('invalid_state', 'Check in shortly before your slot')
    end
    if F.IsLockedDown(now) then return Err('invalid_state', 'The facility is in lockdown; visits are suspended') end
    local desk = VC.Desk or {}
    if not desk.coords or F.Dist(F.Pos(src), desk.coords) > num(desk.radius, 4.0) then return Err('too_far', 'Check in at the visitor desk') end
    return F.WithLock('visit:' .. v.id, function()
        if not V.Move(v, 'checked_in') then return Err('invalid_state', 'The visit is ' .. v.state) end
        V.active[v.id] = v
        local staffed = #F.StaffOnDuty(0) > 0
        if staffed and VC.RequireSearchWhenStaffed ~= false and not v.searched then
            F.NotifyStaff('A visitor checked in and waits to be searched', 'primary')
            F.Notify(src, 'Checked in. Wait for an officer to search you', 'primary')
        else
            F.Notify(src, 'Checked in. Go to the visit room', 'success')
        end
        return { ok = true }
    end)
end

--- An on-duty officer standing with the visitor clears (allow) or turns them away (deny).
function V.Search(src, id, allow, note)
    local P, e = F.Staff(src, 0)
    if not P then return e end
    local v = load(id)
    if not v or not OPEN[v.state] or v.state == 'in_progress' then return Err('not_found', 'No visit waiting') end
    local vsrc = F.SrcOf(v.visitor)
    if not vsrc or F.Dist(F.Pos(vsrc), F.Pos(src)) > 2.5 then return Err('too_far', 'Stand with the visitor') end
    return F.WithLock('visit:' .. v.id, function()
        if allow == true then
            local n = F.Db('update', "UPDATE pf_prison_visits SET searched = 1 WHERE id = ? AND state IN ('booked', 'checked_in')", { v.id })
            if tonumber(n) ~= 1 then return Err('invalid_state', 'The visit is ' .. v.state) end
            v.searched = true
            F.Audit(v.inmate, 'visit', { id = v.id, searched = true, visitor = v.visitor }, P.PlayerData.citizenid)
            F.Notify(vsrc, 'Search cleared. Go to the visit room', 'success')
            return { ok = true, searched = true }
        end
        if not V.Move(v, 'denied', F.Text(note, 200) or 'denied at the search') then return Err('invalid_state', 'The visit is ' .. v.state) end
        F.Notify(vsrc, 'Your visit was denied', 'error')
        return { ok = true, denied = true }
    end)
end

-- ── the visit room ─────────────────────────────────────────────────────────────────────────────

local function inRoom(src)
    local room = VC.Room or {}
    return src ~= nil and room.coords ~= nil and F.Dist(F.Pos(src), room.coords) <= num(room.radius, 8.0)
end

function V.Tick(now)
    now = now or os.time()
    local slot = slotSeconds()
    local staffed = #F.StaffOnDuty(0) > 0
    local locked = F.IsLockedDown(now)
    local D = PFPrison.Discipline
    for _, v in pairs(V.active) do
        local endAt = v.slotAt + slot
        if v.state == 'in_progress' then
            local isrc, vsrc = F.SrcOf(v.inmate), F.SrcOf(v.visitor)
            if now >= endAt then
                V.Move(v, 'done', 'slot ended')
            elseif inRoom(isrc) and inRoom(vsrc) then
                v.awaySince = nil
            else
                v.awaySince = v.awaySince or now
                if now - v.awaySince >= num(VC.LeaveGraceSeconds, 30) then V.Move(v, 'done', 'left the room') end
            end
        elseif now >= v.slotAt + num(VC.NoShowMinutes, 10) * 60 or now >= endAt then
            V.Move(v, 'no_show', 'did not start')
        elseif v.state == 'checked_in' and now >= v.slotAt and not locked then
            local isrc, vsrc = F.SrcOf(v.inmate), F.SrcOf(v.visitor)
            if not F.Row(v.inmate) then
                V.Move(v, 'cancelled', 'the inmate is no longer held')
            elseif v.kind == 'social' and D and not D.HasPrivilege(v.inmate, 'visits', now) then
                V.Move(v, 'denied', 'visits suspended')
                F.Notify(vsrc, "The inmate's visits are suspended", 'error')
            elseif staffed and VC.RequireSearchWhenStaffed ~= false and not v.searched then
                if not v.waitedNotice then
                    v.waitedNotice = true
                    F.Notify(vsrc, 'Wait for an officer to search you', 'primary')
                end
            elseif inRoom(isrc) and inRoom(vsrc) then
                if V.Move(v, 'in_progress') then
                    V.active[v.id] = v
                    F.SetActivity(v.inmate, 'visitation')
                    F.Notify(isrc, 'Visit started', 'success')
                    F.Notify(vsrc, 'Visit started', 'success')
                end
            end
        end
    end
end

--- A lockdown ends the visits in progress (the others wait or run out).
function V.OnLockdown()
    for _, v in pairs(V.active) do
        if v.state == 'in_progress' then V.Move(v, 'done', 'ended by a lockdown') end
    end
end

--- The inmate left the prison: their bookings are cancelled.
function V.OnReleased(cid)
    for _, v in pairs(V.active) do
        if v.inmate == cid and v.state ~= 'in_progress' then V.Move(v, 'cancelled', 'the inmate was released') end
    end
    for _, v in pairs(V.active) do
        if v.inmate == cid and v.state == 'in_progress' then V.Move(v, 'done', 'the inmate was released') end
    end
end

function V.Boot(now)
    now = now or os.time()
    V.active = {}
    local rows = F.Db('query', [[SELECT id, inmate_cid, visitor_cid, slot_at, state, kind, searched FROM pf_prison_visits
        WHERE state IN ('booked', 'checked_in', 'in_progress') AND slot_at >= ? LIMIT 500]], { now - 86400 })
    for _, r in ipairs(type(rows) == 'table' and rows or {}) do
        local v = fromRow(r)
        if v.id then V.active[v.id] = v end
    end
    -- older open rows (the server was down through their slot) are closed as no-shows
    F.Db('update', [[UPDATE pf_prison_visits SET state = 'no_show', notes = 'server was down' WHERE state IN ('booked', 'checked_in', 'in_progress')
        AND slot_at < ?]], { now - 86400 })
    return true
end

--- Visits of the caller (visitor or inmate), or today's board for staff.
function V.List(src, board)
    local cid = F.CidOf(src)
    if not cid then return Err('bad_args', 'Unknown player') end
    local rows
    if board then
        local P, e = F.Staff(src, 0)
        if not P then return e end
        local now = os.time()
        rows = F.Db('query', [[SELECT id, inmate_cid, visitor_cid, slot_at, state, kind, searched FROM pf_prison_visits
            WHERE slot_at >= ? AND slot_at < ? ORDER BY slot_at LIMIT 100]], { now - 3600, now + 86400 })
    else
        rows = F.Db('query', [[SELECT id, inmate_cid, visitor_cid, slot_at, state, kind, searched FROM pf_prison_visits
            WHERE visitor_cid = ? OR inmate_cid = ? ORDER BY slot_at DESC LIMIT 30]], { cid, cid })
    end
    local out = {}
    for _, r in ipairs(type(rows) == 'table' and rows or {}) do out[#out + 1] = fromRow(r) end
    return { ok = true, visits = out }
end

--- Free slots of a day for booking (count of bookings per slot; the room capacity).
function V.Slots(src, dayStart)
    if not F.Player(src) then return Err('bad_args', 'Unknown player') end
    local now = os.time()
    dayStart = F.Int(dayStart, now - 86400, now + num(VC.HorizonDays, 7) * 86400)
    if not dayStart then return Err('bad_args', 'Pick a day within the booking window') end
    local t = os.date('*t', dayStart)
    local from = os.time({ year = t.year, month = t.month, day = t.day, hour = num((VC.Hours or {}).from, 10), min = 0, sec = 0 })
    local to = os.time({ year = t.year, month = t.month, day = t.day, hour = num((VC.Hours or {}).to, 22), min = 0, sec = 0 })
    local slot = slotSeconds()
    local rows = F.Db('query', [[SELECT slot_at, COUNT(*) AS n FROM pf_prison_visits WHERE slot_at >= ? AND slot_at < ?
        AND state IN ('booked', 'checked_in', 'in_progress') GROUP BY slot_at]], { from, to })
    local used = {}
    for _, r in ipairs(type(rows) == 'table' and rows or {}) do used[num(r.slot_at, 0)] = num(r.n, 0) end
    local out = {}
    local s = math.ceil(from / slot) * slot
    while s < to and #out < 100 do
        if s >= math.floor(now / slot) * slot then
            out[#out + 1] = { slotAt = s, booked = used[s] or 0, capacity = num(VC.RoomCapacity, 4) }
        end
        s = s + slot
    end
    return { ok = true, slots = out }
end

F.Callback('visitSlots', function(src, dayStart) return V.Slots(src, dayStart) end)
F.Callback('visitBook', function(src, inmateCid, slotAt, kind) return V.Book(src, inmateCid, slotAt, kind) end)
F.Callback('visitCancel', function(src, id) return V.Cancel(src, id) end)
F.Callback('visitCheckIn', function(src, id) return V.CheckIn(src, id) end)
F.Callback('visitSearch', function(src, id, allow, note) return V.Search(src, id, allow == true, note) end)
F.Callback('visits', function(src, board) return V.List(src, board == true) end)
