-- Prison discipline with due process (batch 19D; PF_ARCHITECTURE 5.13; Config.Facility.Discipline).
--
--   reported -> hearing_scheduled -> heard -> sanctioned | dismissed
--
-- * An infraction is reported by on-duty corrections staff, or by pfm-prison itself / an allowed
--   resource through RecordInfraction (a contraband find of security.lua). It is keyed (opts.key,
--   pf_prison_infractions.idem_key): the same key returns the first infraction.
-- * The inmate is told at once and has MinNoticeSeconds before any hearing.
-- * A hearing is held by an on-duty corrections officer of grade >= HearingGrade who did not report
--   it. An online inmate attends (within HearingReach of the officer, server positions); an offline
--   inmate is heard in absentia only after a scheduled hearing time has passed.
-- * Sanctions: forfeit of work credits (pf-justice AdjustOrder 'forfeit', key
--   pfm-prison:discipline:<id>:forfeit; pf-justice only takes back credits pfm-prison gave), loss of
--   privileges for N hours, solitary up to MaxSolitaryMinutes (both rows in pf_prison_privileges).
-- * Low population: with no hearing officer on duty for AutoHearingAfter an automatic hearing
--   decides, limited to the code's privilege losses (no forfeit, no solitary without a person).

PFPrison = PFPrison or {}
PFPrison.Discipline = PFPrison.Discipline or {}
local D = PFPrison.Discipline
local F = PFPrison.Facility
local B = PFPrison.Bridge
local CF = Config.Facility or {}
local DC = CF.Discipline or {}
local num, Err = F.num, F.Err

D.priv = D.priv or {}         -- [cid] = { [kind] = untilAt } (kind 'solitary' included)
D.pending = D.pending or {}   -- [infractionId] = { orderId, seconds, attempts }: a forfeit to retry
D.lastOfficerAt = D.lastOfficerAt or os.time()
D.nextTickAt = D.nextTickAt or 0

local NEXT = {
    reported = { hearing_scheduled = true, heard = true },
    hearing_scheduled = { hearing_scheduled = true, heard = true },
    heard = { sanctioned = true, dismissed = true },
}
D.Transitions = NEXT

function D.CanMove(from, to) return NEXT[from] ~= nil and NEXT[from][to] == true end

local function codes() return DC.Codes or {} end
local function hearingGrade() return num(DC.HearingGrade, 2) end

-- ── privileges ─────────────────────────────────────────────────────────────────────────────────

local function setPriv(cid, kind, untilAt)
    D.priv[cid] = D.priv[cid] or {}
    if num(D.priv[cid][kind], 0) < untilAt then D.priv[cid][kind] = untilAt end
end

function D.LoadPrivileges(cid)
    local rows = F.Db('query', [[SELECT kind, MAX(until_at) AS until_at FROM pf_prison_privileges WHERE citizenid = ? AND until_at > ?
        GROUP BY kind]], { cid, os.time() })
    D.priv[cid] = nil
    for _, r in ipairs(type(rows) == 'table' and rows or {}) do setPriv(cid, r.kind, num(r.until_at, 0)) end
end

function D.InSolitary(cid, now)
    local p = D.priv[cid]
    return p ~= nil and num(p.solitary, 0) > (now or os.time())
end

--- False while the privilege is lost (or the inmate is in solitary, which suspends them all).
function D.HasPrivilege(cid, kind, now)
    now = now or os.time()
    local p = D.priv[cid]
    if not p then return true end
    if num(p.solitary, 0) > now then return false end
    return num(p[kind], 0) <= now
end

--- { kind = untilAt } of the privileges an inmate has lost right now.
function D.Restrictions(cid, now)
    now = now or os.time()
    local out = {}
    for kind, u in pairs(D.priv[cid] or {}) do if u > now then out[kind] = u end end
    return out
end

-- ── reading ────────────────────────────────────────────────────────────────────────────────────

local COLS = 'id, citizenid, order_id, code, severity, state, evidence_ids, hearing_at, heard_by, sanction, reported_by, at, idem_key'

function D.Get(id)
    id = F.Int(id, 1, 2147483647)
    if not id then return nil end
    local r = F.Db('single', 'SELECT ' .. COLS .. ' FROM pf_prison_infractions WHERE id = ?', { id })
    return type(r) == 'table' and r.id and r or nil
end

function D.Public(r)
    local def = codes()[r.code] or {}
    local ev = {}
    for id in tostring(r.evidence_ids or ''):gmatch('%d+') do ev[#ev + 1] = tonumber(id) end
    return { id = tonumber(r.id), cid = r.citizenid, orderId = tonumber(r.order_id), code = r.code, label = def.label or r.code,
        severity = tonumber(r.severity), state = r.state, evidenceIds = ev, hearingAt = tonumber(r.hearing_at), heardBy = r.heard_by,
        sanction = F.Decode(r.sanction), reportedBy = r.reported_by, at = tonumber(r.at) }
end

-- ── report ─────────────────────────────────────────────────────────────────────────────────────

local function evidenceList(v)
    if v == nil then return '' end
    if type(v) ~= 'table' then return nil end
    local out = {}
    for i, id in ipairs(v) do
        if i > 10 then return nil end
        id = F.Int(id, 1, 2147483647)
        if not id then return nil end
        out[#out + 1] = tostring(id)
    end
    return table.concat(out, ',')
end

--- Records an infraction. spec = { code, severity?, evidenceIds?, hearingAt? };
--- opts = { key?, actor = { src } | { kind = 'system', label } }. -> { ok, infractionId, state }
function D.Record(cid, spec, opts)
    opts = type(opts) == 'table' and opts or {}
    if not F.ValidCid(cid) or type(spec) ~= 'table' then return Err('bad_args', 'cid and spec are required') end
    local def = type(spec.code) == 'string' and codes()[spec.code]
    if not def then return Err('bad_args', 'Unknown infraction code') end
    local severity = spec.severity ~= nil and F.Int(spec.severity, 1, 5) or F.Int(def.severity, 1, 5) or 1
    if not severity then return Err('bad_args', 'severity must be 1..5') end
    local evidence = evidenceList(spec.evidenceIds)
    if not evidence then return Err('bad_args', 'evidenceIds must be up to 10 ids') end
    local now = os.time()
    local hearingAt
    if spec.hearingAt ~= nil then
        hearingAt = F.Int(spec.hearingAt, now + num(DC.MinNoticeSeconds, 300), now + 7 * 86400)
        if not hearingAt then return Err('bad_args', 'The hearing must leave the notice time and be within 7 days') end
    end
    local key = opts.key
    if key ~= nil and not F.ValidKey(key) then return Err('bad_args', 'opts.key is invalid') end
    local actor = type(opts.actor) == 'table' and opts.actor or nil
    local reporter
    if actor and actor.src then
        local P, e = F.Staff(actor.src, 0)
        if not P then return e end
        reporter = P.PlayerData.citizenid
    elseif not (actor and actor.kind == 'system') then
        return Err('bad_args', 'An actor is required')
    end
    return F.WithLock(key and ('infkey:' .. key) or ('inf:new:' .. cid), function()
        if key then
            local r = F.Db('single', 'SELECT id, citizenid, code, state FROM pf_prison_infractions WHERE idem_key = ?', { key })
            if type(r) == 'table' and r.id then
                if r.citizenid ~= cid or r.code ~= spec.code then return Err('key_reused', 'This key was used for another infraction') end
                return { ok = true, duplicate = true, infractionId = tonumber(r.id), state = r.state }
            end
        end
        local row = B.rows[cid]
        if not row or (row.status ~= 'in_cell' and row.status ~= 'escaped') then return Err('not_found', 'Not an inmate here') end
        local state = hearingAt and 'hearing_scheduled' or 'reported'
        local id, ok = F.Db('insert', [[INSERT INTO pf_prison_infractions (citizenid, order_id, code, severity, state, evidence_ids,
            hearing_at, reported_by, at, idem_key) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]],
            { cid, row.order_id, spec.code, severity, state, evidence ~= '' and evidence or nil, hearingAt, reporter, now, key })
        id = math.tointeger(tonumber(id))
        if not ok or not id then return Err('db_unavailable', 'The infraction could not be recorded') end
        F.Audit(cid, 'infraction', { id = id, code = spec.code, severity = severity, by = reporter or (actor and actor.label) }, reporter)
        local src = F.SrcOf(cid)
        F.Notify(src, ('Infraction reported: %s. You will be heard before any sanction.'):format(def.label or spec.code), 'error')
        for _, s in ipairs(F.StaffOnDuty(hearingGrade())) do F.Notify(s, 'Infraction awaiting a hearing: ' .. (def.label or spec.code), 'primary') end
        return { ok = true, infractionId = id, state = state }
    end)
end

-- ── hearings ───────────────────────────────────────────────────────────────────────────────────

local function move(id, from, to, fields)
    local sets, params = { 'state = ?' }, { to }
    for _, f in ipairs(fields or {}) do
        sets[#sets + 1] = f[1] .. ' = ?'
        params[#params + 1] = f[2]
    end
    params[#params + 1] = id
    params[#params + 1] = from
    local n = F.Db('update', 'UPDATE pf_prison_infractions SET ' .. table.concat(sets, ', ') .. ' WHERE id = ? AND state = ?', params)
    return tonumber(n) == 1
end

--- Staff set (or move) the hearing time.
function D.ScheduleHearing(src, id, at)
    local P, e = F.Staff(src, hearingGrade())
    if not P then return e end
    id = F.Int(id, 1, 2147483647)
    if not id then return Err('bad_args', 'Unknown infraction') end
    return F.WithLock('inf:' .. id, function()
        local r = D.Get(id)
        if not r then return Err('not_found', 'Unknown infraction') end
        if not D.CanMove(r.state, 'hearing_scheduled') then return Err('invalid_state', 'The infraction is ' .. r.state) end
        local now = os.time()
        local t = F.Int(at, math.max(now, num(r.at, 0) + num(DC.MinNoticeSeconds, 300)), now + 7 * 86400)
        if not t then return Err('bad_args', 'The hearing must leave the inmate the notice time and be within 7 days') end
        if not move(id, r.state, 'hearing_scheduled', { { 'hearing_at', t } }) then return Err('busy', 'The infraction changed meanwhile') end
        F.Audit(r.citizenid, 'hearing', { id = id, scheduled = t }, P.PlayerData.citizenid)
        F.Notify(F.SrcOf(r.citizenid), 'Your disciplinary hearing is scheduled', 'primary')
        return { ok = true, hearingAt = t }
    end)
end

--- Sanction rows: privileges and solitary. Returns the sanction record parts.
local function applyRows(cid, infId, privileges, solitaryMinutes, now)
    local out = { privileges = {} }
    for _, p in ipairs(privileges or {}) do
        local untilAt = now + p.hours * 3600
        F.Db('insert', 'INSERT INTO pf_prison_privileges (citizenid, kind, until_at, infraction_id) VALUES (?, ?, ?, ?)', { cid, p.kind, untilAt, infId })
        setPriv(cid, p.kind, untilAt)
        out.privileges[#out.privileges + 1] = { kind = p.kind, hours = p.hours, untilAt = untilAt }
    end
    if solitaryMinutes and solitaryMinutes > 0 then
        local untilAt = now + solitaryMinutes * 60
        F.Db('insert', "INSERT INTO pf_prison_privileges (citizenid, kind, until_at, infraction_id) VALUES (?, 'solitary', ?, ?)", { cid, untilAt, infId })
        setPriv(cid, 'solitary', untilAt)
        out.solitary = { minutes = solitaryMinutes, untilAt = untilAt }
        local src = F.SrcOf(cid)
        local spot = (CF.Solitary or {}).coords
        if src and spot and SetEntityCoords then
            pcall(SetEntityCoords, GetPlayerPed(src), spot.x, spot.y, spot.z - 0.9, false, false, false, false)
        end
        F.SetActivity(cid, 'solitary')
    end
    return out
end

local RETRY = { busy = true, justice_unavailable = true, db_unavailable = true }

--- One forfeit attempt (always the same key: pf-justice never applies it twice).
function D.Forfeit(infId, orderId, seconds, attempts)
    local res = B.Justice('AdjustOrder', orderId, { kind = 'forfeit', seconds = seconds, reason = 'discipline hearing ' .. infId },
        { key = ('pfm-prison:discipline:%d:forfeit'):format(infId), actor = { kind = 'system', label = 'pfm-prison discipline' } })
    if type(res) == 'table' and res.ok == true then
        D.pending[infId] = nil
        return { seconds = seconds, applied = num(res.applied, 0), state = 'applied' }
    end
    local err = type(res) == 'table' and res.error or 'justice_unavailable'
    attempts = (attempts or 0) + 1
    if RETRY[err] and attempts < num(DC.ForfeitAttempts, 10) then
        D.pending[infId] = { orderId = orderId, seconds = seconds, attempts = attempts }
        return { seconds = seconds, applied = 0, state = 'pending', error = err }
    end
    D.pending[infId] = nil
    return { seconds = seconds, applied = 0, state = 'refused', error = err }
end

local function normSanctions(s)
    s = type(s) == 'table' and s or {}
    local out = { privileges = {} }
    if s.forfeitMinutes ~= nil and s.forfeitMinutes ~= 0 then
        out.forfeitMinutes = F.Int(s.forfeitMinutes, 1, num(DC.MaxForfeitMinutes, 60))
        if not out.forfeitMinutes then return nil, 'forfeitMinutes is out of range' end
    end
    if s.solitaryMinutes ~= nil and s.solitaryMinutes ~= 0 then
        out.solitaryMinutes = F.Int(s.solitaryMinutes, 1, num(DC.MaxSolitaryMinutes, 60))
        if not out.solitaryMinutes then return nil, 'solitaryMinutes is out of range' end
    end
    if s.privileges ~= nil then
        if type(s.privileges) ~= 'table' or #s.privileges > 5 then return nil, 'privileges are invalid' end
        for _, p in ipairs(s.privileges) do
            local hours = type(p) == 'table' and F.Int(p.hours, 1, num(DC.MaxPrivilegeHours, 168))
            if not hours or not (DC.Privileges or {})[p.kind] then return nil, 'privileges are invalid' end
            out.privileges[#out.privileges + 1] = { kind = p.kind, hours = hours }
        end
    end
    return out
end

--- A hearing held by staff. decision = { verdict = 'guilty' | 'not_guilty', note?, sanctions? =
--- { forfeitMinutes?, privileges? = { { kind, hours } }, solitaryMinutes? } }.
function D.HoldHearing(src, id, decision)
    local P, e = F.Staff(src, hearingGrade())
    if not P then return e end
    id = F.Int(id, 1, 2147483647)
    if not id or type(decision) ~= 'table' or (decision.verdict ~= 'guilty' and decision.verdict ~= 'not_guilty') then
        return Err('bad_args', 'An infraction and a verdict are required')
    end
    local sanctions, serr = normSanctions(decision.sanctions)
    if not sanctions then return Err('bad_args', serr) end
    local note = F.Text(decision.note, 255)
    local officer = P.PlayerData.citizenid
    return F.WithLock('inf:' .. id, function()
        local r = D.Get(id)
        if not r then return Err('not_found', 'Unknown infraction') end
        if not D.CanMove(r.state, 'heard') then return Err('invalid_state', 'The infraction is ' .. r.state) end
        local now = os.time()
        local noticeEnds = num(r.at, 0) + num(DC.MinNoticeSeconds, 300)
        if now < noticeEnds then return Err('invalid_state', ('The inmate has notice for %d more seconds'):format(noticeEnds - now)) end
        if r.reported_by and r.reported_by == officer then return Err('no_permission', 'The reporting officer cannot hear the case') end
        local cid = r.citizenid
        local inmateSrc = F.SrcOf(cid)
        if inmateSrc then
            if F.Dist(F.Pos(inmateSrc), F.Pos(src)) > num(DC.HearingReach, 10.0) then
                return Err('too_far', 'The inmate attends the hearing: stand with them')
            end
        elseif not (r.hearing_at and num(r.hearing_at, 0) <= now) then
            return Err('offline', 'The inmate is offline: schedule a hearing time first (heard in absentia after it)')
        end
        if not move(id, r.state, 'heard', { { 'heard_by', officer } }) then return Err('busy', 'The infraction changed meanwhile') end
        local record = { verdict = decision.verdict, note = note, by = officer, at = now, attended = inmateSrc ~= nil }
        local to = 'dismissed'
        if decision.verdict == 'guilty' then
            to = 'sanctioned'
            local parts = applyRows(cid, id, sanctions.privileges, sanctions.solitaryMinutes, now)
            record.privileges, record.solitary = parts.privileges, parts.solitary
            if sanctions.forfeitMinutes then
                local orderId = math.tointeger(tonumber(r.order_id)) or (B.rows[cid] and B.rows[cid].order_id)
                record.forfeit = orderId and D.Forfeit(id, orderId, sanctions.forfeitMinutes * 60, 0)
                    or { seconds = sanctions.forfeitMinutes * 60, applied = 0, state = 'refused', error = 'no_order' }
            end
        end
        move(id, 'heard', to, { { 'sanction', F.Encode(record) } })
        F.Audit(cid, 'hearing', { id = id, verdict = decision.verdict, to = to, forfeit = record.forfeit }, officer)
        local def = codes()[r.code] or {}
        F.Notify(inmateSrc, ('Hearing on %s: %s'):format(def.label or r.code, decision.verdict == 'guilty' and 'sanctioned' or 'dismissed'),
            decision.verdict == 'guilty' and 'error' or 'success')
        return { ok = true, state = to, sanction = record }
    end)
end

-- ── automatic hearings (low population) ────────────────────────────────────────────────────────

function D.AutoHearings(now)
    now = now or os.time()
    if DC.AutoHearing == false then return 0 end
    if #F.StaffOnDuty(hearingGrade()) > 0 then
        D.lastOfficerAt = now
        return 0
    end
    local after = num(DC.AutoHearingAfter, 3600)
    local rows = F.Db('query', 'SELECT ' .. COLS .. [[ FROM pf_prison_infractions WHERE state IN ('reported', 'hearing_scheduled')
        AND at <= ? ORDER BY id LIMIT 20]], { now - after })
    local n = 0
    for _, r in ipairs(type(rows) == 'table' and rows or {}) do
        local waitFrom = math.max(num(r.at, 0), num(D.lastOfficerAt, 0), num(r.hearing_at, 0))
        if now - waitFrom >= after and now >= num(r.at, 0) + num(DC.MinNoticeSeconds, 300) then
            local id = math.tointeger(tonumber(r.id))
            local res = F.WithLock('inf:' .. id, function()
                local cur = D.Get(id)
                if not cur or not D.CanMove(cur.state, 'heard') then return nil end
                if not move(id, cur.state, 'heard', { { 'heard_by', 'auto' } }) then return nil end
                local held = B.rows[cur.citizenid]
                if not held or (held.status ~= 'in_cell' and held.status ~= 'escaped') then
                    move(id, 'heard', 'dismissed', { { 'sanction', F.Encode({ verdict = 'auto', auto = true, reason = 'no longer held', at = now }) } })
                    return 'dismissed'
                end
                local list = {}
                for _, p in ipairs((codes()[cur.code] or {}).auto or {}) do
                    local hours = F.Int(p.hours, 1, num(DC.MaxPrivilegeHours, 168))
                    if hours and (DC.Privileges or {})[p.kind] then list[#list + 1] = { kind = p.kind, hours = hours } end
                end
                -- an automatic hearing never forfeits time and never orders solitary (a person decides those)
                local parts = applyRows(cur.citizenid, id, list, nil, now)
                move(id, 'heard', 'sanctioned', { { 'sanction', F.Encode({ verdict = 'auto', auto = true, privileges = parts.privileges, at = now }) } })
                F.Audit(cur.citizenid, 'hearing', { id = id, auto = true, privileges = #parts.privileges })
                F.Notify(F.SrcOf(cur.citizenid), 'Automatic hearing (no officer available): privileges restricted', 'error')
                return 'sanctioned'
            end)
            if res == 'sanctioned' or res == 'dismissed' then n = n + 1 end
        end
    end
    return n
end

--- Forfeits pf-justice could not take yet (same key again).
function D.RetryForfeits()
    local n = 0
    for id, p in pairs(D.pending) do
        local res = D.Forfeit(id, p.orderId, p.seconds, p.attempts)
        if res.state ~= 'pending' then
            local r = D.Get(id)
            local rec = r and F.Decode(r.sanction) or {}
            rec.forfeit = res
            F.Db('update', 'UPDATE pf_prison_infractions SET sanction = ? WHERE id = ?', { F.Encode(rec), id })
            n = n + 1
        end
    end
    return n
end

function D.Tick(now)
    now = now or os.time()
    if now < D.nextTickAt then return end
    D.nextTickAt = now + 60
    for cid, p in pairs(D.priv) do
        local any = false
        for kind, u in pairs(p) do if u > now then any = true else p[kind] = nil end end
        if not any then D.priv[cid] = nil end
    end
    D.RetryForfeits()
    D.AutoHearings(now)
end

function D.Boot(now)
    now = now or os.time()
    D.lastOfficerAt = now
    D.priv = {}
    local rows = F.Db('query', [[SELECT citizenid, kind, MAX(until_at) AS until_at FROM pf_prison_privileges WHERE until_at > ?
        GROUP BY citizenid, kind]], { now })
    for _, r in ipairs(type(rows) == 'table' and rows or {}) do setPriv(r.citizenid, r.kind, num(r.until_at, 0)) end
    local pend = F.Db('query', [[SELECT id, order_id, sanction FROM pf_prison_infractions WHERE state = 'sanctioned'
        AND sanction LIKE '%"state":"pending"%' LIMIT 200]], {})
    for _, r in ipairs(type(pend) == 'table' and pend or {}) do
        local rec = F.Decode(r.sanction) or {}
        local f = rec.forfeit
        if type(f) == 'table' and f.state == 'pending' and tonumber(r.order_id) then
            D.pending[tonumber(r.id)] = { orderId = math.tointeger(tonumber(r.order_id)), seconds = num(f.seconds, 0), attempts = 0 }
        end
    end
    return true
end

-- ── export and callbacks ───────────────────────────────────────────────────────────────────────

--- RecordInfraction(cid, spec, opts) -> { ok, infractionId, state } (architecture 4.8).
exports('RecordInfraction', function(cid, spec, opts)
    local allowed, invoker = F.Allowed('RecordInfraction')
    if not allowed then return Err('not_allowed', 'This resource may not record infractions') end
    opts = type(opts) == 'table' and opts or {}
    local actor = type(opts.actor) == 'table' and opts.actor or nil
    if not (actor and actor.src) then actor = { kind = 'system', label = tostring(invoker or 'pfm-prison'):sub(1, 48) } end
    return D.Record(cid, spec, { key = opts.key, actor = actor })
end)

--- Infractions of one inmate (staff), newest first.
function D.List(cid, limit)
    local rows = F.Db('query', 'SELECT ' .. COLS .. ' FROM pf_prison_infractions WHERE citizenid = ? ORDER BY id DESC LIMIT ?', { cid, limit or 20 })
    local out = {}
    for _, r in ipairs(type(rows) == 'table' and rows or {}) do out[#out + 1] = D.Public(r) end
    return out
end

F.Callback('reportInfraction', function(src, cid, code, evidenceIds, hearingAt)
    return D.Record(cid, { code = code, evidenceIds = evidenceIds, hearingAt = hearingAt }, { actor = { src = src } })
end)
F.Callback('scheduleHearing', function(src, id, at) return D.ScheduleHearing(src, id, at) end)
F.Callback('holdHearing', function(src, id, decision) return D.HoldHearing(src, id, decision) end)
F.Callback('infractions', function(src, cid)
    local P, e = F.Staff(src, 0)
    if not P then return e end
    if cid ~= nil then
        if not F.ValidCid(cid) then return Err('bad_args', 'Unknown inmate') end
        return { ok = true, list = D.List(cid, 50), restrictions = D.Restrictions(cid) }
    end
    local rows = F.Db('query', 'SELECT ' .. COLS .. [[ FROM pf_prison_infractions WHERE state IN ('reported', 'hearing_scheduled')
        ORDER BY id LIMIT 100]], {})
    local out = {}
    for _, r in ipairs(type(rows) == 'table' and rows or {}) do out[#out + 1] = D.Public(r) end
    return { ok = true, list = out }
end)
--- An inmate's own record: what they are charged with, the hearings, the restrictions.
F.Callback('myInfractions', function(src)
    local cid = F.CidOf(src)
    if not cid then return Err('bad_args', 'No character') end
    return { ok = true, list = D.List(cid, 20), restrictions = D.Restrictions(cid) }
end)
