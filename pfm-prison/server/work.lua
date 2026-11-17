-- Prison work (batch 19E; PF_ARCHITECTURE 4.8, config_work.lua).
--
-- Jobs tied to what the prison really needs:
--   kitchen      three stations; each shift adds meal portions to the canteen stash, which the
--                routine's meal times (19D schedule.lua) serve from before its own fallback meal;
--   laundry      three stations; each shift adds clean linen (laundry_bag) to the prison laundry
--                stash, and full batches move to the hospital linen stash (a stash transfer);
--   maintenance  a unit of a pf-government work order at a prison site (ClaimWorkOrder with the
--                claimant kind 'cs', proved by ReportWorkUnit, which checks the time on site);
--   electrician  the old round: spots assigned by server/main.lua, checked the same way.
-- The server decides every step: the station is the server's, the inmate's server position must be
-- at it, each step waits its minimum time, a teleport (main.lua's sampler) or an impossible speed
-- between stations voids the shift, and the client's only input is which step it says it did.
--
-- A finished shift is one row in pf_prison_work_log (ticket numbered per order, UNIQUE): its time
-- credit goes to pf-justice (AdjustOrder credit, key pfm-prison:credit:<orderId>:<ticket>, the
-- same key on every retry; capped here per shift and per day, and by pf-justice's MaxShare), its
-- wage into the inmate trust (server/economy.lua). credit_seconds is stored negative while
-- pf-justice has not answered (a retry is due), and the applied seconds once it has.

PFPrison = PFPrison or {}
PFPrison.Work = PFPrison.Work or {}
local W = PFPrison.Work
local CW = Config.Work or {}
local SYSTEM = { kind = 'system', label = 'pfm-prison work' }
local PERMANENT = { invalid_state = true, not_found = true, bad_args = true, no_permission = true, not_allowed = true, key_reused = true }

local function num(v, d) return tonumber(v) or d end
local function int(v, lo, hi)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge then return nil end
    v = math.floor(v)
    if v < lo or v > hi then return nil end
    return v
end
local function I() return PFPrison.Internal or {} end
local function E() return PFPrison.Economy or {} end
local function notify(src, text, kind) TriggerClientEvent('QBCore:Notify', src, text, kind or 'primary') end
local function v3(p) return vector3(p.x, p.y, p.z) end
local function dist(a, b) return #(v3(a) - v3(b)) end

W.sessions = W.sessions or {}   -- [src] = the shift in progress
W.lastStart = W.lastStart or {} -- [src] = os.time() of the last start
W.credits = W.credits or {}     -- [key] = { cid, orderId, ticket, seconds, attempts, nextAt }: credits to retry
W.locks = W.locks or {}         -- [cid] = true while a shift is written
W.maint = W.maint or { unavailable = 'not_checked', nextAt = 0 }

W.SQL = {
    daySums = [[SELECT COUNT(*) AS n, COALESCE(SUM(ABS(credit_seconds)), 0) AS credit, COALESCE(SUM(wage), 0) AS wage
        FROM pf_prison_work_log WHERE citizenid = ? AND at >= ?]],
    lastTicket = 'SELECT COALESCE(MAX(ticket), 0) FROM pf_prison_work_log WHERE order_id = ?',
    insert = [[INSERT INTO pf_prison_work_log (citizenid, order_id, job, ticket, output, credit_seconds, wage, at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)]],
    setCredit = 'UPDATE pf_prison_work_log SET credit_seconds = ? WHERE order_id = ? AND ticket = ? AND credit_seconds < 0',
    pendingCredits = 'SELECT * FROM pf_prison_work_log WHERE credit_seconds < 0 AND at >= ? ORDER BY id LIMIT 100',
}

local function db(kind, sql, params)
    local fn = E().db
    if fn then return fn(kind, sql, params) end
    return nil, false
end

-- ── who is working ───────────────────────────────────────────────────────────────────────────

--- The inmate this prison holds for a pf-justice order and who is inside now:
--- { src, cid, orderId, row }; nil otherwise (escaped, released, the old runtime, not ours).
function PFPrison.Inmate(src)
    src = tonumber(src)
    local P = src and I().getPlayer and I().getPlayer(src)
    if not P then return nil end
    local cid = P.PlayerData.citizenid
    local B = PFPrison.Bridge or {}
    local row = B.rows and B.rows[cid]
    if not row or row.status ~= 'in_cell' or not tonumber(row.order_id) then return nil end
    if PFPrison.Regime and PFPrison.Regime(src) ~= 'justice' then return nil end
    return { src = src, cid = cid, orderId = math.tointeger(tonumber(row.order_id)), row = row }
end

local function lockedDown()
    local F = PFPrison.Facility
    if F and F.IsLockedDown then return F.IsLockedDown() == true end
    local fn = I().lockdownUntil
    return fn ~= nil and num(fn(), 0) > os.time()
end

local function teleportedSince(src, since)
    local t = I().track and I().track[src]
    return t ~= nil and t.teleportAt ~= nil and t.teleportAt >= since
end

-- ── stashes (kitchen and laundry output) ─────────────────────────────────────────────────────

local function inv(name, ...)
    local args, n = { ... }, select('#', ...)
    local ok, res = pcall(function()
        local e = exports['pfm-inventory']
        return e[name](e, table.unpack(args, 1, n))
    end)
    if not ok then return nil end
    return res
end

local function ensureStash(id, label, slots, weight)
    if not inv('GetInventory', id) then inv('CreateInventory', id, { label = label, maxweight = weight, slots = slots }) end
    return inv('GetInventory', id) ~= nil
end

local function stashCount(id, item)
    local stash = inv('GetInventory', id)
    local n = 0
    for _, it in pairs(stash and stash.items or {}) do
        if type(it) == 'table' and it.name == item then n = n + num(it.amount, 0) end
    end
    return n
end
W.StashCount = stashCount

--- Kitchen output: portions into the canteen stash (up to MaxStock). Returns how many went in.
function W.AddMeals(n)
    local K = CW.Kitchen or {}
    if not ensureStash(K.Stash, K.StashLabel, K.StashSlots, K.StashWeight) then return 0 end
    n = math.min(n, math.max(0, num(K.MaxStock, 60) - stashCount(K.Stash, K.MealItem)))
    if n < 1 then return 0 end
    return inv('AddItem', K.Stash, K.MealItem, n, false, false, 'pfm-prison:kitchen') and n or 0
end

--- The routine's meal time (19D schedule.lua): one portion from the canteen stock. False when the
--- canteen is empty (the schedule then serves its own fallback meal).
function W.ServeMeal(cid, src)
    local K = CW.Kitchen or {}
    if not src or stashCount(K.Stash, K.MealItem) < 1 then return false end
    if not inv('RemoveItem', K.Stash, K.MealItem, 1, false, 'pfm-prison:canteen') then return false end
    if inv('AddItem', src, K.MealItem, 1, false, false, 'pfm-prison:canteen') then return true end
    inv('AddItem', K.Stash, K.MealItem, 1, false, false, 'pfm-prison:canteen_undo')
    return false
end

--- Laundry output: clean linen into the prison laundry stash. Returns how many went in.
function W.AddLinen(n)
    local L = CW.Laundry or {}
    if not ensureStash(L.Stash, L.StashLabel, L.StashSlots, L.StashWeight) then return 0 end
    return inv('AddItem', L.Stash, L.Item, n, false, false, 'pfm-prison:laundry') and n or 0
end

--- Full batches of clean linen move to the hospital linen stash (rolled back when it refuses them).
function W.ShipLinen()
    local L = CW.Laundry or {}
    local batch = math.max(1, num(L.ShipBatch, 6))
    if stashCount(L.Stash, L.Item) < batch then return 0 end
    if not ensureStash(L.HospitalStash, L.HospitalLabel, L.HospitalSlots, L.HospitalWeight) then return 0 end
    if stashCount(L.HospitalStash, L.Item) + batch > num(L.MaxHospitalStock, 120) then return 0 end
    if not inv('RemoveItem', L.Stash, L.Item, batch, false, 'pfm-prison:linen_out') then return 0 end
    if inv('AddItem', L.HospitalStash, L.Item, batch, false, false, 'pfm-prison:linen_in') then return batch end
    inv('AddItem', L.Stash, L.Item, batch, false, false, 'pfm-prison:linen_undo')
    return 0
end

-- ── maintenance: pf-government work orders at the prison ─────────────────────────────────────

local function gov(name, ...)
    if GetResourceState('pf-government') ~= 'started' then return nil end
    local args, n = { ... }, select('#', ...)
    local ok, res = pcall(function()
        local e = exports['pf-government']
        return e[name](e, table.unpack(args, 1, n))
    end)
    if not ok or type(res) ~= 'table' then return nil end
    return res
end

local function maintCfg() return CW.Maintenance or {} end

--- Keeps OpenOrders prison work orders open (one per site and day, keyed). Maintenance is offered
--- only while pf-government lists and accepts them; any refusal hides it until the next look.
function W.EnsureMaintenance(now)
    now = now or os.time()
    local job = (CW.Jobs or {}).maintenance
    if not job then W.maint.unavailable = 'disabled' return false end
    local M = maintCfg()
    local res = gov('ListWorkOrders', { district = M.District, csEligible = true, limit = 20 })
    if not res or res.ok ~= true then
        W.maint.unavailable = res and res.error or 'government_unavailable'
        return false
    end
    local open, bySite = 0, {}
    for _, o in ipairs(res.list or {}) do
        if o.status == 'open' or o.status == 'in_progress' then
            open = open + 1
            if o.site and o.site.label then bySite[o.site.label] = true end
        end
    end
    local day = math.floor(now / 86400)
    for i, site in ipairs(M.Sites or {}) do
        if open >= num(M.OpenOrders, 2) then break end
        if not bySite[site.label] then
            local c = gov('CreateWorkOrder', {
                kind = site.kind, district = M.District, units = num(M.Units, 4), csEligible = true,
                site = { x = site.x, y = site.y, z = site.z, r = site.r, label = site.label },
                effect = { field = M.Field or 'maintenance_backlog', delta = num(M.Delta, -400) },
                expiresAt = now + num(M.LifetimeHours, 24) * 3600, source = { type = 'pfm-prison', id = i },
            }, { key = ('pfm-prison:wo:%d:%d'):format(i, day) })
            if not c or (c.ok ~= true and c.error ~= 'conflict') then
                W.maint.unavailable = c and c.error or 'government_unavailable'
                return false
            end
            if c.ok then open = open + 1 end
        end
    end
    W.maint.unavailable = nil
    return true
end

--- One unit of an open prison work order for this inmate (claimant kind 'cs': unpaid by the city;
--- the wage comes from corrections). Returns the claim or nil, message.
function W.ClaimMaintenance(inmate)
    if W.maint.unavailable then return nil, 'There is no maintenance work right now' end
    local res = gov('ListWorkOrders', { district = maintCfg().District, csEligible = true, limit = 20 })
    if not res or res.ok ~= true then return nil, 'There is no maintenance work right now' end
    for _, o in ipairs(res.list or {}) do
        if num(o.unitsOpen, 0) > 0 then
            local c = gov('ClaimWorkOrder', o.id, { kind = 'cs', cid = inmate.cid, ref = ('pfm-prison:%d'):format(inmate.orderId) })
            if c and c.ok == true and tonumber(c.claimId) then
                local s = c.site or o.site or {}
                return { claimId = math.tointeger(tonumber(c.claimId)), workOrderId = o.id, label = o.label,
                    site = { x = num(s.x, 0), y = num(s.y, 0), z = num(s.z, 0), r = num(s.r, 10), label = s.label },
                    minSeconds = num(c.minSeconds, 0) }
            end
            if c and c.error == 'conflict' and c.message and c.message:find('current work unit', 1, true) then
                return nil, 'You still hold an unfinished work unit'
            end
        end
    end
    return nil, 'There is no maintenance work right now'
end

local function releaseClaim(session)
    if session and session.claim then gov('ReleaseWorkClaim', session.claim.claimId, 'shift dropped') end
end

-- ── the shift record: credit and wage ────────────────────────────────────────────────────────

--- pf-justice time credit for one ticket (same key on every retry). Returns the applied seconds,
--- or nil while it is queued.
function W.Credit(cid, orderId, ticket, seconds, attempts)
    local key = ('pfm-prison:credit:%d:%d'):format(orderId, ticket)
    local res = PFPrison.Bridge and PFPrison.Bridge.Justice and PFPrison.Bridge.Justice('AdjustOrder', orderId,
        { kind = 'credit', seconds = seconds, reason = 'prison work' }, { key = key, actor = SYSTEM })
    if type(res) == 'table' and res.ok == true then
        local applied = math.max(0, math.floor(num(res.applied, 0)))
        db('update', W.SQL.setCredit, { applied, orderId, ticket })
        W.credits[key] = nil
        E().Event(cid, 'credit', { orderId = orderId, ticket = ticket, seconds = seconds, applied = applied })
        return applied
    end
    local err = type(res) == 'table' and res.error or 'justice_unavailable'
    attempts = (attempts or 0) + 1
    if PERMANENT[err] or attempts >= 100 then
        db('update', W.SQL.setCredit, { 0, orderId, ticket })
        W.credits[key] = nil
        E().Event(cid, 'anomaly', { what = 'credit_refused', orderId = orderId, ticket = ticket, error = err })
        return 0
    end
    W.credits[key] = { cid = cid, orderId = orderId, ticket = ticket, seconds = seconds, attempts = attempts,
        nextAt = os.time() + num(CW.CreditRetrySeconds, 30) }
    return nil
end

--- Writes one finished shift and starts its credit and wage. Returns { ok, ticket, credit, wage }.
function W.Complete(inmate, jobName, made)
    local job = (CW.Jobs or {})[jobName]
    local cid, orderId = inmate.cid, inmate.orderId
    if not job or not orderId then return { ok = false, error = 'bad_args' } end
    if W.locks[cid] then return { ok = false, error = 'busy' } end
    W.locks[cid] = true
    local ok, rec = pcall(function()
        local now = os.time()
        local sums, okSums = db('single', W.SQL.daySums, { cid, E().DayStart(now) })
        if not okSums then return { ok = false, error = 'db_unavailable' } end
        sums = sums or {}
        if num(sums.n, 0) >= num(CW.MaxTicketsPerDay, 12) then return { ok = false, error = 'limit' } end
        local credit = math.max(0, math.min(num(job.creditSeconds, 0), num(CW.MaxCreditSecondsPerDay, 2400) - num(sums.credit, 0)))
        local wage = math.max(0, math.min(num(job.wage, 0), num(CW.MaxWagePerDay, 600) - num(sums.wage, 0)))
        local ticket = num(db('scalar', W.SQL.lastTicket, { orderId }), 0) + 1
        local okJson, out = pcall(json.encode, made or {})
        local _, okIns = db('insert', W.SQL.insert, { cid, orderId, jobName, ticket, okJson and out or nil, -credit, wage, now })
        if not okIns then return { ok = false, error = 'db_unavailable' } end
        return { ok = true, ticket = ticket, credit = credit, wage = wage }
    end)
    W.locks[cid] = nil
    if not ok then
        print(('^1[pfm-prison]^7 work record of %s failed: %s'):format(tostring(cid), tostring(rec)))
        return { ok = false, error = 'db_unavailable' }
    end
    if not rec.ok then return rec end
    if rec.credit > 0 then rec.applied = W.Credit(cid, orderId, rec.ticket, rec.credit) end
    if rec.wage > 0 then
        local paid = E().Earn and E().Earn(cid, orderId, rec.ticket, rec.wage)
        rec.wageState = type(paid) == 'table' and paid.state or 'failed'
    end
    E().Event(cid, 'work', { job = jobName, orderId = orderId, ticket = rec.ticket, credit = rec.credit, wage = rec.wage, made = made })
    return rec
end

local function tellDone(src, label, rec)
    if not rec.ok then
        if rec.error == 'limit' then return notify(src, 'You have worked enough shifts today', 'error') end
        return notify(src, 'Your shift could not be recorded; try again', 'error')
    end
    local parts = { label .. ' shift done' }
    if rec.applied and rec.applied > 0 then parts[#parts + 1] = ('%d min off your sentence'):format(math.floor(rec.applied / 60))
    elseif rec.credit > 0 and rec.applied == nil then parts[#parts + 1] = 'time credit pending' end
    if rec.wage > 0 then
        parts[#parts + 1] = rec.wageState == 'completed' and ('$%d to your trust'):format(rec.wage)
            or rec.wageState == 'pending' and ('$%d wage pending'):format(rec.wage) or 'wage delayed (the corrections budget is empty)'
    end
    notify(src, table.concat(parts, ', '), 'success')
end

-- ── shifts ───────────────────────────────────────────────────────────────────────────────────

local function publicSession(s)
    local job = (CW.Jobs or {})[s.job] or {}
    local steps = {}
    for i, st in ipairs(job.steps or {}) do steps[i] = { label = st.label, x = st.coords.x, y = st.coords.y, z = st.coords.z, minSeconds = st.minSeconds } end
    return { job = s.job, label = job.label or s.job, steps = steps, next = s.step + 1,
        site = s.claim and { x = s.claim.site.x, y = s.claim.site.y, z = s.claim.site.z, r = s.claim.site.r,
            label = s.claim.site.label or s.claim.label, minSeconds = s.claim.minSeconds } or nil }
end

--- The jobs an inmate can start now (shown on the work board).
function W.Offer(inmate)
    local list = {}
    for name, job in pairs(CW.Jobs or {}) do
        if name ~= 'electrician' and (name ~= 'maintenance' or not W.maint.unavailable) then
            list[#list + 1] = { name = name, label = job.label or name, wage = num(job.wage, 0), minutes = math.floor(num(job.creditSeconds, 0) / 60) }
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

--- Drops a shift (and gives back its maintenance unit).
function W.Drop(src, why)
    local s = W.sessions[src]
    if not s then return false end
    W.sessions[src] = nil
    releaseClaim(s)
    TriggerClientEvent('pfm-prison:client:WorkSession', src, nil, why)
    return true
end

function W.Start(src, jobName)
    local now = os.time()
    if CW.Enabled == false then return nil, 'Prison work is closed' end
    local job = type(jobName) == 'string' and (CW.Jobs or {})[jobName]
    if not job or jobName == 'electrician' then return nil, 'No such job' end
    local inmate = PFPrison.Inmate(src)
    if not inmate then return nil, 'Only inmates can take a shift' end
    if W.sessions[src] then return nil, 'Finish or drop your current shift first' end
    if W.lastStart[src] and now - W.lastStart[src] < num(CW.StartCooldown, 20) then return nil, 'Wait a moment' end
    local pos = I().pedPos(src)
    if not pos or not CW.Board or dist(pos, CW.Board) > num(CW.Reach, 2.5) + 1.0 then return nil, 'Go to the work board' end
    if lockedDown() then return nil, 'The prison is in lockdown' end
    if E().Revoked(inmate.cid, 'work') then return nil, 'Your work privilege is suspended' end
    local sums = db('single', W.SQL.daySums, { inmate.cid, E().DayStart(now) })
    if not sums or num(sums.n, 0) >= num(CW.MaxTicketsPerDay, 12) then return nil, 'You have worked enough shifts today' end
    -- the board might have answered after a release or a second start: look again after the waits
    if W.sessions[src] or not PFPrison.Inmate(src) then return nil, 'Finish or drop your current shift first' end
    local claim
    if jobName == 'maintenance' then
        local why
        claim, why = W.ClaimMaintenance(inmate)
        if not claim then return nil, why end
    end
    W.lastStart[src] = now
    local s = { job = jobName, cid = inmate.cid, orderId = inmate.orderId, startedAt = now, step = 0, lastStepAt = now,
        lastPos = { x = pos.x, y = pos.y, z = pos.z }, claim = claim }
    W.sessions[src] = s
    return s
end

function W.Step(src, index)
    local s = W.sessions[src]
    if not s then return false end
    local job = (CW.Jobs or {})[s.job] or {}
    local steps = job.steps or {}
    index = int(index, 1, #steps)
    if not index or index ~= s.step + 1 then return false end
    local inmate = PFPrison.Inmate(src)
    if not inmate or inmate.cid ~= s.cid then W.Drop(src, 'You are no longer on the work roster') return false end
    local now = os.time()
    if teleportedSince(src, s.startedAt) then W.Drop(src, 'Your shift was void') return false end
    local pos = I().pedPos(src)
    local st = steps[index]
    if not pos or dist(pos, st.coords) > num(CW.Reach, 2.5) then return false, 'You are not at the station' end
    local dt = now - s.lastStepAt
    if dt < num(st.minSeconds, 5) then return false, 'Take your time with it' end
    if dist(pos, s.lastPos) / math.max(1, dt) > num(CW.MaxTravelSpeed, 9.0) then W.Drop(src, 'Your shift was void') return false end
    s.step, s.lastStepAt, s.lastPos = index, now, { x = pos.x, y = pos.y, z = pos.z }
    return true
end

function W.Finish(src)
    local s = W.sessions[src]
    if not s then return nil end
    local job = (CW.Jobs or {})[s.job] or {}
    local now = os.time()
    local inmate = PFPrison.Inmate(src)
    if not inmate or inmate.cid ~= s.cid or inmate.orderId ~= s.orderId then
        W.Drop(src, 'You are no longer on the work roster')
        return nil
    end
    if teleportedSince(src, s.startedAt) then W.Drop(src, 'Your shift was void') return nil end
    if s.step < #(job.steps or {}) then return nil, 'Finish every station first' end
    if now - s.startedAt < num(job.minSeconds, 0) then return nil, 'Keep working a little longer' end
    local made = {}
    if s.claim then
        local res = gov('ReportWorkUnit', s.claim.claimId, { src = src }, { key = ('pf-government:wo:%d:1'):format(s.claim.claimId) })
        if not res then return nil, 'The city works office is not answering; try again' end
        if res.ok ~= true then
            if res.error == 'too_soon' then return nil, ('Keep working: %d seconds left'):format(num(res.remaining, 0)) end
            if res.error == 'too_far' or res.error == 'invalid_state' and (res.message or ''):find('vehicle', 1, true) then
                return nil, res.message or 'You are not at the work site'
            end
            W.Drop(src, res.message or 'This work unit is no longer open')
            return nil
        end
        made.workOrderId, made.claimId, made.unitsDone = s.claim.workOrderId, s.claim.claimId, res.unitsDone
    end
    -- the shift is used up before anything that waits
    W.sessions[src] = nil
    if s.job == 'kitchen' then
        made.meals = W.AddMeals(num((CW.Kitchen or {}).Portions, 4))
    elseif s.job == 'laundry' then
        made.linen = W.AddLinen(num((CW.Laundry or {}).BagsPerShift, 2))
        made.shipped = W.ShipLinen()
    end
    local rec = W.Complete(inmate, s.job, made)
    TriggerClientEvent('pfm-prison:client:WorkSession', src, nil)
    tellDone(src, job.label or s.job, rec)
    return rec
end

--- The electrician round of server/main.lua (its spot, its sampler): the same checks as
--- prison:server:JobDone, then a recorded shift here instead of a random cut.
function W.Electrician(src, location)
    local It = I()
    local job = It.jobs and It.jobs[src]
    if not job or job.name ~= 'electrician' then return nil end
    location = math.tointeger(tonumber(location))
    if location ~= job.location then return nil end
    local inmate = PFPrison.Inmate(src)
    if not inmate then return nil end
    local P = Config.Prison or {}
    local now = os.time()
    local spot, pos = It.jobSpot(job), It.pedPos(src)
    if not spot or not pos or #(v3(pos) - spot) > num(P.JobReach, 3.5) then return nil end
    local travel = job.assignedPos and #(spot - v3(job.assignedPos)) / math.max(1.0, num(P.JobTravelSpeed, 8.0)) or 0
    if now - job.assignedAt < num(P.JobMinSeconds, 8) + travel then return nil end
    if teleportedSince(src, job.assignedAt) then
        E().Event(inmate.cid, 'anomaly', { what = 'job_teleport', job = job.name, spot = location })
        local nextJob = It.assignJob(src, job.name, location)
        TriggerClientEvent('prison:client:SetJob', src, nextJob.name, nextJob.location, PFPrison.TimeLeft(src))
        return nil
    end
    if not job.onSpotSince or now - job.onSpotSince < num(P.JobDwellSeconds, 3) then return nil end
    if E().Revoked(inmate.cid, 'work') then return nil, 'Your work privilege is suspended' end
    -- the spot is used up before anything that can wait
    It.jobs[src] = nil
    local rec = W.Complete(inmate, 'electrician', { spot = location })
    tellDone(src, 'Electrician', rec)
    if It.inmates and It.inmates[src] then
        local nextJob = It.assignJob(src, job.name, location)
        TriggerClientEvent('prison:client:SetJob', src, nextJob.name, nextJob.location, PFPrison.TimeLeft(src))
    end
    return rec
end

-- ── ticks ────────────────────────────────────────────────────────────────────────────────────

--- Credits pf-justice could not take yet (same key), shifts of inmates who left, laundry shipping
--- and the prison work orders.
function W.Tick(now)
    now = now or os.time()
    for key, c in pairs(W.credits) do
        if W.credits[key] == c and now >= c.nextAt then W.Credit(c.cid, c.orderId, c.ticket, c.seconds, c.attempts) end
    end
    for src, s in pairs(W.sessions) do
        local inmate = PFPrison.Inmate(src)
        if not inmate or inmate.cid ~= s.cid or now - s.startedAt > num(CW.MaxSessionSeconds, 1200) then W.Drop(src, 'Your shift ended') end
    end
    W.ShipLinen()
    if now >= num(W.maint.nextAt, 0) then
        W.maint.nextAt = now + num(maintCfg().EnsureSeconds, 300)
        W.EnsureMaintenance(now)
    end
end

--- After a restart: credits whose answer never came (negative credit_seconds) are asked again.
function W.Boot(now)
    now = now or os.time()
    local n = 0
    for _, r in ipairs(db('query', W.SQL.pendingCredits, { now - 7 * 86400 }) or {}) do
        local orderId, ticket = math.tointeger(tonumber(r.order_id)), math.tointeger(tonumber(r.ticket))
        if orderId and ticket then
            W.credits[('pfm-prison:credit:%d:%d'):format(orderId, ticket)] = { cid = r.citizenid, orderId = orderId, ticket = ticket,
                seconds = -num(r.credit_seconds, 0), attempts = 0, nextAt = now }
            n = n + 1
        end
    end
    local F = PFPrison.Facility
    if F and F.SetMealProvider then F.SetMealProvider(function(cid, src) return W.ServeMeal(cid, src) end) end
    return n
end

CreateThread(function()
    Wait(4000)
    while not (PFPrisonSchema and PFPrisonSchema.Ready()) do Wait(2000) end
    W.Boot()
    while true do
        local ok, err = pcall(W.Tick)
        if not ok then print(('^1[pfm-prison]^7 work tick failed: %s'):format(tostring(err))) end
        Wait(5000)
    end
end)

-- ── net events and callbacks (inmates) ───────────────────────────────────────────────────────

local lastAct = {}
local function rate(src, seconds)
    local now = os.time()
    if lastAct[src] and now - lastAct[src] < seconds then return false end
    lastAct[src] = now
    return true
end

RegisterNetEvent('pfm-prison:server:WorkStart', function(jobName)
    local src = source
    if not rate(src, 1) then return end
    local s, why = W.Start(src, type(jobName) == 'string' and jobName:sub(1, 16) or nil)
    if not s then return notify(src, why or 'You cannot start that shift', 'error') end
    TriggerClientEvent('pfm-prison:client:WorkSession', src, publicSession(s))
end)

RegisterNetEvent('pfm-prison:server:WorkStep', function(index)
    local src = source
    if not rate(src, 1) then return end
    local ok, why = W.Step(src, index)
    if ok then
        TriggerClientEvent('pfm-prison:client:WorkSession', src, publicSession(W.sessions[src]))
    elseif why then
        notify(src, why, 'error')
    end
end)

RegisterNetEvent('pfm-prison:server:WorkFinish', function()
    local src = source
    if not rate(src, 1) then return end
    local rec, why = W.Finish(src)
    if not rec and why then notify(src, why, 'error') end
end)

RegisterNetEvent('pfm-prison:server:WorkDrop', function()
    local src = source
    if not rate(src, 1) then return end
    W.Drop(src, 'Shift dropped')
end)

RegisterNetEvent('pfm-prison:server:ElectricianDone', function(location)
    local src = source
    if not rate(src, 1) then return end
    local _, why = W.Electrician(src, location)
    if why then notify(src, why, 'error') end
end)

local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions' })
-- What the work board shows: the jobs, today's shifts and limits, the shift in progress.
QBCore.Functions.CreateCallback('pfm-prison:server:workState', function(src, cb)
    local inmate = PFPrison.Inmate(src)
    if not inmate then return cb(nil) end
    local sums = db('single', W.SQL.daySums, { inmate.cid, E().DayStart(os.time()) }) or {}
    cb({ jobs = W.Offer(inmate), shifts = num(sums.n, 0), maxShifts = num(CW.MaxTicketsPerDay, 12),
        creditMinutes = math.floor(num(sums.credit, 0) / 60), maxCreditMinutes = math.floor(num(CW.MaxCreditSecondsPerDay, 2400) / 60),
        wage = num(sums.wage, 0), maxWage = num(CW.MaxWagePerDay, 600),
        session = W.sessions[src] and publicSession(W.sessions[src]) or nil })
end)
