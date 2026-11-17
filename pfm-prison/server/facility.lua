-- Prison facility operations (batch 19D; PF_ARCHITECTURE 4.8, 5.13; config_facility.lua).
--
-- pfm-prison holds a citizen for a pf-justice order (server/justice_bridge.lua). This file adds the
-- facility around that stay:
--   * intake: classification (min / medium / max: time to serve, escape record, serious
--     infractions), a cell of that classification (or a higher one, never a lower one), the uniform
--     item; release takes the uniform back. Every move is a 'housing' row in pf_prison_events.
--   * the activity status other resources read through GetInmate (intake, in_cell, yard, work,
--     meal, infirmary, visitation, solitary, transfer): set by schedule.lua, discipline.lua and
--     visitation.lua, raised as pfm-prison:server:inmateStatus(cid, status).
--   * SetLockdown (staff, admin menu): gates locked through pfm-doorlock, routine and visits stop,
--     survives a restart (the last manual lockdown row of pf_prison_events is read back).
--   * GetInmate / GetFacilityStatus: the batch-16 exports of justice_bridge.lua are registered again
--     here (a later exports() registration of the same name replaces the earlier one) with the
--     cell, the activity, the next count and the cell totals.
-- The helpers at the top (staff checks, locks, rate limits, audit) are used by schedule.lua,
-- discipline.lua and visitation.lua through PFPrison.Facility.
--
-- Inmates of the old metadata runtime (pf-justice LegacyRuntimes.prison still on) are not housed
-- here: they have no pf_prison_inmates row.

PFPrison = PFPrison or {}
PFPrison.Facility = PFPrison.Facility or {}
local F = PFPrison.Facility
local B = PFPrison.Bridge
local I = PFPrison.Internal
local CF = Config.Facility or {}
local FAC = CF.Id or (Config.Justice and Config.Justice.Facility) or 'bolingbroke'
F.FAC = FAC

local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions' })

F.cells = F.cells or {}        -- [cellId] = { id, block, classification, capacity, outOfService, coords }
F.cellOrder = F.cellOrder or {} -- cell ids in config order
F.activity = F.activity or {}  -- [cid] = { status, at }
F.intakeAt = F.intakeAt or {}  -- [cid] = os.time() of the intake (shown as 'intake' for IntakeSeconds)
F.locks = F.locks or {}
F.rates = F.rates or {}
F.lockdown = F.lockdown or { on = false }
F.booted = F.booted or false

-- ── small helpers (copied validation rules, architecture 3.6) ──────────────────────────────────

local function num(v, d) return tonumber(v) or d end
F.num = num

function F.Int(v, min, max)
    local n = tonumber(v)
    if not n or n ~= n or n == math.huge or n == -math.huge then return nil end
    n = math.tointeger(n) or (n == math.floor(n) and math.floor(n) or nil)
    if not n then return nil end
    if (min and n < min) or (max and n > max) then return nil end
    return n
end

function F.Text(v, max)
    if type(v) ~= 'string' then return nil end
    local s = v:gsub('%c', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    if s == '' then return nil end
    return s:sub(1, max or 255)
end

function F.ValidCid(cid) return type(cid) == 'string' and #cid >= 1 and #cid <= 64 and cid:match('^[%w_%-]+$') ~= nil end
function F.ValidKey(k) return type(k) == 'string' and #k >= 1 and #k <= 128 and k:match('^[%w%-_:%.]+$') ~= nil end

function F.Err(code, message) return { ok = false, error = code, message = message } end
local Err = F.Err

function F.Callable(v)
    if type(v) == 'function' then return true end
    if type(v) ~= 'table' then return false end
    if type(rawget(v, '__cfx_functionReference')) == 'string' then return true end
    local mt = getmetatable(v)
    return type(mt) == 'table' and rawget(mt, '__call') ~= nil
end

function F.Player(src)
    src = tonumber(src)
    if not src then return nil end
    local ok, P = pcall(function() return exports['pfm-core']:GetPlayer(src) end)
    if ok and type(P) == 'table' and P.PlayerData then return P end
    return nil
end

function F.PlayerByCid(cid)
    if not F.ValidCid(cid) then return nil end
    local ok, P = pcall(function() return exports['pfm-core']:GetPlayerByCitizenId(cid) end)
    if ok and type(P) == 'table' and P.PlayerData then return P end
    return nil
end

--- Server id of an online citizen (nil when offline).
function F.SrcOf(cid)
    local P = F.PlayerByCid(cid)
    return P and tonumber(P.PlayerData.source) or nil
end

function F.CidOf(src)
    local P = F.Player(src)
    return P and P.PlayerData.citizenid or nil
end

function F.Pos(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    return GetEntityCoords(ped)
end

function F.Dist(a, b)
    if not a or not b then return math.huge end
    return #(vector3(a.x, a.y, a.z or 0) - vector3(b.x, b.y, b.z or 0))
end

function F.Notify(src, text, kind)
    if src then TriggerClientEvent('QBCore:Notify', src, text, kind or 'primary') end
end

function F.Players()
    local ok, list = pcall(function() return QBCore.Functions.GetPlayers() end)
    return ok and type(list) == 'table' and list or {}
end

--- An on-duty staff member of at least `minGrade`. Returns the player, or nil and an error result.
function F.Staff(src, minGrade)
    local P = F.Player(src)
    if not P then return nil, Err('bad_args', 'Unknown player') end
    local job = P.PlayerData.job or {}
    if job.name ~= (CF.StaffJob or 'corrections') then return nil, Err('no_permission', 'Corrections staff only') end
    if not job.onduty then return nil, Err('not_on_duty', 'Go on duty first') end
    local grade = type(job.grade) == 'table' and num(job.grade.level, 0) or num(job.grade, 0)
    if grade < (minGrade or 0) then return nil, Err('no_permission', 'Your rank cannot do this') end
    return P, nil, grade
end

--- Server ids of on-duty staff of at least `minGrade`.
function F.StaffOnDuty(minGrade)
    local out = {}
    for _, src in ipairs(F.Players()) do
        if F.Staff(src, minGrade) then out[#out + 1] = tonumber(src) end
    end
    return out
end

function F.NotifyStaff(text, kind)
    for _, src in ipairs(F.StaffOnDuty(0)) do F.Notify(src, text, kind) end
end

--- At most one action per `seconds` per source and action name.
function F.Rate(src, action, seconds)
    local key = tostring(src) .. ':' .. action
    local now = GetGameTimer and GetGameTimer() or os.time() * 1000
    local last = F.rates[key]
    if last and now - last < (seconds or 1) * 1000 then return false end
    F.rates[key] = now
    return true
end

--- Runs fn while holding a named lock (taken before the first database wait). busy when held.
function F.WithLock(key, fn)
    if F.locks[key] then return Err('busy', 'Being changed right now; try again') end
    F.locks[key] = true
    local ok, res = pcall(fn)
    F.locks[key] = nil
    if not ok then
        print(('^1[pfm-prison]^7 %s failed: %s'):format(key, tostring(res)))
        return Err('db_unavailable', 'Something went wrong; nothing was changed')
    end
    return res
end

-- ── database and audit ─────────────────────────────────────────────────────────────────────────

function F.DbReady() return PFPrisonSchema ~= nil and PFPrisonSchema.Ready() end

function F.Db(kind, sql, params)
    if not F.DbReady() then return nil, false end
    local ok, res = pcall(MySQL[kind].await, sql, params or {})
    if not ok then
        print(('^1[pfm-prison]^7 database error: %s'):format(tostring(res)))
        return nil, false
    end
    return res, true
end

function F.Encode(v)
    local ok, s = pcall(json.encode, v)
    return ok and s or nil
end

function F.Decode(s)
    if type(s) ~= 'string' or s == '' then return nil end
    local ok, v = pcall(json.decode, s)
    return ok and v or nil
end

--- One pf_prison_events row (architecture 3.8; detail <= 4 KB).
function F.Audit(cid, kind, detail, actorCid)
    local s = detail ~= nil and F.Encode(detail) or nil
    if s and #s > 4096 then s = F.Encode({ truncated = true }) end
    local _, ok = F.Db('insert', 'INSERT INTO pf_prison_events (citizenid, facility, kind, detail, actor_cid, at) VALUES (?, ?, ?, ?, ?, ?)',
        { F.ValidCid(cid) and cid or nil, FAC, tostring(kind):sub(1, 16), s, F.ValidCid(actorCid) and actorCid or nil, os.time() })
    return ok
end

-- ── inmates ────────────────────────────────────────────────────────────────────────────────────

--- The pf_prison_inmates row of a citizen held here and inside (not escaped, not being released).
function F.Row(cid)
    local row = B and B.rows and B.rows[cid]
    if row and row.status == 'in_cell' then return row end
    return nil
end

--- Online inmates inside: list of { cid, src, row }.
function F.OnlineInmates()
    local out = {}
    for _, src in ipairs(F.Players()) do
        local cid = F.CidOf(src)
        local row = cid and F.Row(cid)
        if row then out[#out + 1] = { cid = cid, src = tonumber(src), row = row } end
    end
    return out
end

--- The activity status changes (raised once per change).
function F.SetActivity(cid, status)
    local cur = F.activity[cid]
    if cur and cur.status == status then return false end
    F.activity[cid] = { status = status, at = os.time() }
    TriggerEvent('pfm-prison:server:inmateStatus', cid, status)
    return true
end

function F.Activity(cid)
    local row = B and B.rows and B.rows[cid]
    if not row then return nil end
    if row.status ~= 'in_cell' then return row.status end
    local a = F.activity[cid]
    return a and a.status or 'in_cell'
end

-- ── cells ──────────────────────────────────────────────────────────────────────────────────────

local CLASS_RANK = {}
for i, c in ipairs((CF.Classification or {}).Order or { 'min', 'medium', 'max' }) do CLASS_RANK[c] = i end
F.CLASS_RANK = CLASS_RANK

function F.ValidClass(c) return type(c) == 'string' and CLASS_RANK[c] ~= nil end

--- Cells from config (layout is config's: block, classification, capacity); the out-of-service
--- flag is the database's. Seeded at every start, so a new config cell appears without a version.
function F.LoadCells()
    F.cells, F.cellOrder = {}, {}
    for _, c in ipairs(CF.Cells or {}) do
        if type(c) == 'table' and type(c.id) == 'string' and #c.id <= 16 and F.ValidClass(c.classification) and not F.cells[c.id] then
            F.cells[c.id] = { id = c.id, block = tostring(c.block or '?'):sub(1, 8), classification = c.classification,
                capacity = math.max(1, math.min(20, math.floor(num(c.capacity, 2)))), outOfService = false, coords = c.coords }
            F.cellOrder[#F.cellOrder + 1] = c.id
        end
    end
    for _, id in ipairs(F.cellOrder) do
        local c = F.cells[id]
        F.Db('update', [[INSERT INTO pf_prison_cells (facility, cell_id, block, classification, capacity, out_of_service) VALUES (?, ?, ?, ?, ?, 0)
            ON DUPLICATE KEY UPDATE block = VALUES(block), classification = VALUES(classification), capacity = VALUES(capacity)]],
            { FAC, id, c.block, c.classification, c.capacity })
    end
    local rows = F.Db('query', 'SELECT cell_id, out_of_service FROM pf_prison_cells WHERE facility = ?', { FAC })
    for _, r in ipairs(type(rows) == 'table' and rows or {}) do
        local c = F.cells[r.cell_id]
        if c then c.outOfService = num(r.out_of_service, 0) == 1 end
    end
    return #F.cellOrder
end

--- [cellId] = occupants (inmates inside, escapees and releases not counted).
function F.Occupancy(exceptCid)
    local occ = {}
    for cid, row in pairs(B and B.rows or {}) do
        if cid ~= exceptCid and row.status == 'in_cell' and row.cell_id then occ[row.cell_id] = (occ[row.cell_id] or 0) + 1 end
    end
    return occ
end

--- A free cell of the classification, or of the next higher one (never a lower one).
function F.PickCell(class, exceptCid)
    local occ = F.Occupancy(exceptCid)
    local rank = CLASS_RANK[class] or CLASS_RANK.medium or 2
    local order = (CF.Classification or {}).Order or { 'min', 'medium', 'max' }
    for r = rank, #order do
        local best, bestN
        for _, id in ipairs(F.cellOrder) do
            local c = F.cells[id]
            if c.classification == order[r] and not c.outOfService then
                local n = occ[id] or 0
                if n < c.capacity and (bestN == nil or n < bestN) then best, bestN = id, n end
            end
        end
        if best then return best end
    end
    return nil
end

--- Moves an inmate into a cell (nil = no free cell: housed without one, logged as overflow).
function F.House(cid, cellId, why, actorCid)
    local row = B.rows[cid]
    if not row then return false end
    local from = row.cell_id
    row.cell_id = cellId
    B.SaveRow(row)
    F.Audit(cid, 'housing', { from = from, to = cellId, classification = row.classification, why = why, overflow = cellId == nil or nil }, actorCid)
    local src = F.SrcOf(cid)
    local c = cellId and F.cells[cellId]
    if src then
        if c then
            F.Notify(src, ('Cell %s, block %s (%s security)'):format(c.id, c.block, row.classification), 'primary')
            -- the client may mark the cell; it never decides where the inmate is
            TriggerClientEvent('pfm-prison:client:Housing', src, { cellId = c.id, block = c.block, classification = row.classification,
                coords = c.coords and { x = c.coords.x, y = c.coords.y, z = c.coords.z, w = c.coords.w } or nil })
        end
    end
    if not cellId then F.NotifyStaff('No free cell for an inmate: housed in overflow, assign a cell', 'error') end
    return true
end

-- ── classification ─────────────────────────────────────────────────────────────────────────────

local function raise(class, steps)
    local order = (CF.Classification or {}).Order or { 'min', 'medium', 'max' }
    local r = math.min(#order, (CLASS_RANK[class] or 2) + (steps or 1))
    return order[r]
end
F.RaiseClass = raise

--- Classification for an order: by the time to serve, then the record here.
function F.Classify(cid, order)
    local cc = CF.Classification or {}
    local seconds = num(order and (order.requiredSeconds or order.remainingSeconds), 0)
    local minutes = seconds / 60
    local class = minutes <= num(cc.MinUpToMinutes, 60) and 'min' or (minutes <= num(cc.MediumUpToMinutes, 240) and 'medium' or 'max')
    local now = os.time()
    local since = now - num(cc.EscapeLookbackDays, 90) * 86400
    local esc = F.Db('scalar', 'SELECT COUNT(*) FROM pf_prison_escapes WHERE citizenid = ? AND escaped_at >= ?', { cid, since })
    local escEv = F.Db('scalar', "SELECT COUNT(*) FROM pf_prison_events WHERE citizenid = ? AND kind = 'escape' AND at >= ?", { cid, since })
    if num(esc, 0) > 0 or num(escEv, 0) > 0 then return 'max', 'escape record' end
    local serious = F.Db('scalar', [[SELECT COUNT(*) FROM pf_prison_infractions WHERE citizenid = ? AND state = 'sanctioned'
        AND severity >= ? AND at >= ?]], { cid, num(cc.SeriousSeverity, 4), now - num(cc.SeriousLookbackDays, 30) * 86400 })
    if num(serious, 0) > 0 then return raise(class, 1), 'serious infraction' end
    return class, 'sentence length'
end

--- Sets an inmate's classification and moves the cell when it no longer fits.
--- opts = { actor = { src } | { kind = 'system', label }, reason }. Staff need Grades.Housing.
function F.SetClassification(cid, class, opts)
    opts = type(opts) == 'table' and opts or {}
    if not F.ValidCid(cid) or not F.ValidClass(class) then return Err('bad_args', 'Unknown inmate or classification') end
    local actorCid
    local actor = type(opts.actor) == 'table' and opts.actor or {}
    if actor.src then
        local P, e = F.Staff(actor.src, num((CF.Grades or {}).Housing, 2))
        if not P then return e end
        actorCid = P.PlayerData.citizenid
    elseif actor.kind ~= 'system' then
        return Err('bad_args', 'An actor is required')
    end
    return F.WithLock('inmate:' .. cid, function()
        local row = B.rows[cid]
        if not row or (row.status ~= 'in_cell' and row.status ~= 'escaped') then return Err('not_found', 'Not an inmate here') end
        local from = row.classification
        if from == class then return { ok = true, unchanged = true, classification = class, cellId = row.cell_id } end
        row.classification = class
        B.SaveRow(row)
        F.Audit(cid, 'classify', { from = from, to = class, reason = F.Text(opts.reason, 120) }, actorCid)
        local cell = row.cell_id and F.cells[row.cell_id]
        if row.status == 'in_cell' and (not cell or cell.classification ~= class) then
            F.House(cid, F.PickCell(class, cid), 'reclassified', actorCid)
        end
        return { ok = true, classification = class, cellId = row.cell_id }
    end)
end

--- Staff move an inmate to a cell (it must be in service, of the inmate's class or higher, and free).
function F.AssignCell(src, cid, cellId)
    local P, e = F.Staff(src, num((CF.Grades or {}).Housing, 2))
    if not P then return e end
    if not F.ValidCid(cid) or type(cellId) ~= 'string' or not F.cells[cellId] then return Err('bad_args', 'Unknown inmate or cell') end
    return F.WithLock('inmate:' .. cid, function()
        local row = F.Row(cid)
        if not row then return Err('not_found', 'Not an inmate here') end
        local c = F.cells[cellId]
        if c.outOfService then return Err('invalid_state', 'The cell is out of service') end
        if (CLASS_RANK[c.classification] or 0) < (CLASS_RANK[row.classification] or 0) then
            return Err('invalid_state', 'A ' .. row.classification .. ' inmate cannot be housed in a ' .. c.classification .. ' cell')
        end
        if row.cell_id == cellId then return { ok = true, unchanged = true, cellId = cellId } end
        if (F.Occupancy(cid)[cellId] or 0) >= c.capacity then return Err('conflict', 'The cell is full') end
        F.House(cid, cellId, 'staff move', P.PlayerData.citizenid)
        return { ok = true, cellId = cellId }
    end)
end

--- Staff take a cell out of service (its inmates are moved) or back into service.
function F.SetCellService(src, cellId, outOfService)
    local P, e = F.Staff(src, num((CF.Grades or {}).Housing, 2))
    if not P then return e end
    local c = type(cellId) == 'string' and F.cells[cellId]
    if not c then return Err('bad_args', 'Unknown cell') end
    outOfService = outOfService == true
    return F.WithLock('cell:' .. cellId, function()
        local _, ok = F.Db('update', 'UPDATE pf_prison_cells SET out_of_service = ? WHERE facility = ? AND cell_id = ?', { outOfService and 1 or 0, FAC, cellId })
        if not ok then return Err('db_unavailable', 'The cell could not be changed') end
        c.outOfService = outOfService
        F.Audit(nil, 'housing', { cell = cellId, outOfService = outOfService }, P.PlayerData.citizenid)
        local moved = 0
        if outOfService then
            for cid, row in pairs(B.rows) do
                if row.status == 'in_cell' and row.cell_id == cellId then
                    F.House(cid, F.PickCell(row.classification, cid), 'cell out of service', P.PlayerData.citizenid)
                    moved = moved + 1
                end
            end
        end
        return { ok = true, moved = moved }
    end)
end

-- ── intake and release (wrapped around the bridge's Admit / Release) ──────────────────────────

local function itemExists(name)
    local ok, item = pcall(function() return exports['pfm-core']:GetShared('Items')[name] end)
    return ok and item ~= nil
end

local function hasItem(src, name)
    local ok, has = pcall(function() return exports['pfm-inventory']:HasItem(src, name) end)
    return ok and has == true
end

--- The uniform item at intake (only when the item exists and the inmate has none).
function F.IssueUniform(src)
    local name = CF.UniformItem
    if type(name) ~= 'string' or name == '' or not itemExists(name) or hasItem(src, name) then return false end
    local ok, added = pcall(function() return exports['pfm-inventory']:AddItem(src, name, 1, false, false, 'pfm-prison:intake') end)
    return ok and added == true
end

function F.TakeUniform(src)
    local name = CF.UniformItem
    if type(name) ~= 'string' or name == '' or not src or not hasItem(src, name) then return false end
    local ok, removed = pcall(function() return exports['pfm-inventory']:RemoveItem(src, name, 1, false, 'pfm-prison:release') end)
    return ok and removed == true
end

--- After the bridge took a citizen in: classification, cell, uniform, the 'intake' status.
function F.OnAdmitted(src, order, fresh)
    local cid = F.CidOf(src)
    local row = cid and B.rows[cid]
    if not row or row.status ~= 'in_cell' then return end
    local class, why = F.Classify(cid, order)
    if not fresh then
        -- a readmission never lowers the class (an escape raised it)
        if (CLASS_RANK[row.classification] or 0) > (CLASS_RANK[class] or 0) then class, why = row.classification, 'kept' end
    end
    local before = row.classification
    row.classification = class
    if fresh or before ~= class then F.Audit(cid, 'classify', { from = fresh and nil or before, to = class, reason = why }) end
    local cell = row.cell_id and F.cells[row.cell_id]
    local occ = F.Occupancy(cid)
    if fresh or not cell or cell.outOfService or cell.classification ~= class or (occ[row.cell_id] or 0) >= cell.capacity then
        F.House(cid, F.PickCell(class, cid), fresh and 'intake' or 'readmission')
    else
        B.SaveRow(row)
    end
    F.IssueUniform(src)
    F.intakeAt[cid] = os.time()
    F.activity[cid] = nil
    F.SetActivity(cid, 'intake')
    if PFPrison.Discipline and F.Callable(PFPrison.Discipline.LoadPrivileges) then PFPrison.Discipline.LoadPrivileges(cid) end
end

function F.OnReleased(src, cid)
    F.TakeUniform(src)
    F.activity[cid], F.intakeAt[cid] = nil, nil
    if PFPrison.Visitation and F.Callable(PFPrison.Visitation.OnReleased) then PFPrison.Visitation.OnReleased(cid) end
end

if B and F.Callable(B.Admit) and not B.facilityWrapped then
    B.facilityWrapped = true
    local admit, release = B.Admit, B.Release
    B.Admit = function(src, order, how)
        local cid = F.CidOf(src)
        local before = cid and B.rows[cid]
        local fresh = before == nil or before.status == 'releasing' or before.status == 'intake'
        local res = admit(src, order, how)
        if res == 'admitted' then
            local ok, err = pcall(F.OnAdmitted, src, order, fresh)
            if not ok then print(('^1[pfm-prison]^7 intake of %s failed: %s'):format(tostring(cid), tostring(err))) end
        end
        return res
    end
    B.Release = function(src, row, why)
        local res = release(src, row, why)
        if res == 'released' then pcall(F.OnReleased, src, row.citizenid) end
        return res
    end
end

-- ── lockdown ───────────────────────────────────────────────────────────────────────────────────

--- Manual (staff / admin) lockdown, or the one a failed gate hack started (server/main.lua).
function F.IsLockedDown(now)
    now = now or os.time()
    if F.lockdown.on and (not F.lockdown.untilAt or F.lockdown.untilAt > now) then return true end
    return I and F.Callable(I.lockdownUntil) and num(I.lockdownUntil(), 0) > now or false
end

local function lockGates()
    for _, g in ipairs(Config.Gates or {}) do
        pcall(function() exports['pfm-doorlock']:SetDoorState(g.door or g.gatekey, true, { reason = 'prison lockdown' }) end)
    end
end

--- Starts or ends a lockdown. opts = { reason, minutes, actorCid }. Internal (checked by callers).
function F.ApplyLockdown(on, opts)
    opts = opts or {}
    local now = os.time()
    if on then
        local minutes = F.Int(opts.minutes, 1, num(CF.LockdownMaxMinutes, 240)) or num(CF.LockdownMaxMinutes, 240)
        F.lockdown = { on = true, untilAt = now + minutes * 60, reason = F.Text(opts.reason, 120) or 'lockdown', by = opts.actorCid, at = now }
        lockGates()
        TriggerClientEvent('prison:client:SetLockDown', -1, true)
        if PFPrison.Visitation and F.Callable(PFPrison.Visitation.OnLockdown) then PFPrison.Visitation.OnLockdown() end
        for _, e in ipairs(F.OnlineInmates()) do
            F.SetActivity(e.cid, 'in_cell')
            F.Notify(e.src, 'Lockdown: return to your cell', 'error')
        end
        F.NotifyStaff('Facility lockdown started: ' .. F.lockdown.reason, 'error')
    else
        F.lockdown = { on = false, at = now, by = opts.actorCid }
        -- the gate-hack lockdown of main.lua may still run; it lifts its own
        if not F.IsLockedDown(now) then TriggerClientEvent('prison:client:SetLockDown', -1, false) end
        F.NotifyStaff('Facility lockdown ended', 'success')
    end
    F.Audit(nil, 'lockdown', { manual = true, on = on == true, untilAt = F.lockdown.untilAt, reason = F.lockdown.reason }, opts.actorCid)
    if PFPrison.Schedule and F.Callable(PFPrison.Schedule.Tick) then pcall(PFPrison.Schedule.Tick, now) end
    return { ok = true, lockdown = F.lockdown.on, untilAt = F.lockdown.untilAt }
end

--- A staff lockdown (grade Grades.Lockdown, on duty).
function F.StaffLockdown(src, on, reason, minutes)
    local P, e = F.Staff(src, num((CF.Grades or {}).Lockdown, 3))
    if not P then return e end
    if not F.Rate(src, 'lockdown', 5) then return Err('rate_limited', 'Wait a moment') end
    return F.ApplyLockdown(on == true, { reason = reason, minutes = minutes, actorCid = P.PlayerData.citizenid })
end

--- The last manual lockdown comes back after a restart while its time has not run out.
function F.RestoreLockdown(now)
    now = now or os.time()
    local r = F.Db('single', [[SELECT detail, actor_cid FROM pf_prison_events WHERE facility = ? AND kind = 'lockdown'
        AND detail LIKE '%"manual":true%' ORDER BY id DESC LIMIT 1]], { FAC })
    local d = type(r) == 'table' and F.Decode(r.detail)
    if type(d) == 'table' and d.on == true and num(d.untilAt, 0) > now then
        F.lockdown = { on = true, untilAt = num(d.untilAt, 0), reason = d.reason or 'lockdown', by = r.actor_cid, at = now }
        lockGates()
        return true
    end
    return false
end

-- ── exports ────────────────────────────────────────────────────────────────────────────────────

--- Caller check of a write export (architecture 3.4): the resource itself or the config list.
function F.Allowed(exportName)
    local invoker = GetInvokingResource()
    if invoker == nil or invoker == GetCurrentResourceName() then return true, invoker end
    local list = (CF.Callers or {})[exportName]
    if list == '*' then return true, invoker end
    return type(list) == 'table' and list[invoker] == true, invoker
end

--- SetLockdown(facility, on, opts) -> { ok, lockdown, untilAt }. opts = { reason, minutes, actor = { src } }
--- (a staff actor needs Grades.Lockdown; without an actor the caller resource answers for it).
exports('SetLockdown', function(facility, on, opts)
    local allowed = F.Allowed('SetLockdown')
    if not allowed then return Err('not_allowed', 'This resource may not set a lockdown') end
    if (facility or FAC) ~= FAC then return Err('not_found', 'No such facility') end
    opts = type(opts) == 'table' and opts or {}
    local actor = type(opts.actor) == 'table' and opts.actor or nil
    if actor and actor.src then return F.StaffLockdown(actor.src, on == true, opts.reason, opts.minutes) end
    return F.ApplyLockdown(on == true, { reason = opts.reason, minutes = opts.minutes })
end)

--- GetInmate(who): who = server id or citizenid -> { ok, inmate? = { cid, orderId, cellId, block,
--- classification, status, since, admittedAt } }. status is the activity while inside.
exports('GetInmate', function(who)
    local cid, P
    if type(who) == 'number' then
        P = F.Player(who)
        cid = P and P.PlayerData.citizenid
    elseif F.ValidCid(who) then
        cid = who
    end
    if not cid then return Err('bad_args', 'Unknown player or citizen id') end
    local row = B.rows[cid]
    if row then
        local a = row.status == 'in_cell' and F.activity[cid] or nil
        local cell = row.cell_id and F.cells[row.cell_id]
        return { ok = true, inmate = { cid = cid, orderId = row.order_id, cellId = row.cell_id, block = cell and cell.block or nil,
            classification = row.classification, status = F.Activity(cid), since = a and a.at or row.status_at, admittedAt = row.admitted_at } }
    end
    if B.LegacyRuntime() then
        P = P or F.PlayerByCid(cid)
        if P and I.sentenceOf(P) > 0 then
            return { ok = true, inmate = { cid = cid, status = 'in_cell', classification = 'medium', legacy = true } }
        end
    end
    return { ok = true }
end)

--- GetFacilityStatus(facility) -> { ok, population, online, escaped, lockdown, lockdownUntil,
--- alarms, nextCount, phase, cells = { total, free, outOfService } }.
exports('GetFacilityStatus', function(facility)
    facility = facility or FAC
    if facility ~= FAC then return Err('not_found', 'No such facility') end
    local now = os.time()
    local population, escaped = 0, 0
    for _, row in pairs(B.rows) do
        if row.status == 'escaped' then escaped = escaped + 1
        elseif row.status ~= 'releasing' then population = population + 1 end
    end
    local online, legacy = 0, 0
    for _, regime in pairs(I.inmates) do
        online = online + 1
        if regime == 'legacy' then legacy = legacy + 1 end
    end
    local gates = 0
    for _ in pairs(I.gateOpen) do gates = gates + 1 end
    local total, used, oos = 0, 0, 0
    local occ = F.Occupancy()
    for _, id in ipairs(F.cellOrder) do
        local c = F.cells[id]
        if c.outOfService then oos = oos + 1 else
            total = total + c.capacity
            used = used + math.min(c.capacity, occ[id] or 0)
        end
    end
    local S = PFPrison.Schedule
    local phase = S and F.Callable(S.Phase) and S.Phase(now) or nil
    local lockUntil = math.max(F.lockdown.on and num(F.lockdown.untilAt, 0) or 0, num(I.lockdownUntil(), 0))
    return { ok = true, facility = FAC, population = population + legacy, online = online, escaped = escaped,
        lockdown = F.IsLockedDown(now), lockdownUntil = lockUntil > now and lockUntil or nil,
        lockdownReason = F.lockdown.on and F.lockdown.reason or nil,
        alarms = { alarm = I.alarmActive() == true, gatesOpen = gates },
        nextCount = S and F.Callable(S.NextCount) and S.NextCount(now) or nil,
        phase = phase and { name = phase.name, label = phase.label, endsAt = phase.endsAt } or nil,
        cells = { total = total, free = math.max(0, total - used), outOfService = oos } }
end)

-- ── staff callbacks (the Corrections MDT of batch 21 calls these) ──────────────────────────────

--- The roster: every inmate held here with cell, class and activity (on-duty staff only).
function F.Roster(src)
    local P, e = F.Staff(src, 0)
    if not P then return e end
    local list = {}
    for cid, row in pairs(B.rows) do
        if row.status ~= 'releasing' then
            local cell = row.cell_id and F.cells[row.cell_id]
            list[#list + 1] = { cid = cid, orderId = row.order_id, cellId = row.cell_id, block = cell and cell.block or nil,
                classification = row.classification, status = F.Activity(cid), online = F.SrcOf(cid) ~= nil, admittedAt = row.admitted_at }
        end
        if #list >= 100 then break end
    end
    table.sort(list, function(a, b) return tostring(a.cellId or '~') < tostring(b.cellId or '~') end)
    local cells = {}
    local occ = F.Occupancy()
    for _, id in ipairs(F.cellOrder) do
        local c = F.cells[id]
        cells[#cells + 1] = { id = id, block = c.block, classification = c.classification, capacity = c.capacity,
            occupants = occ[id] or 0, outOfService = c.outOfService }
    end
    return { ok = true, inmates = list, cells = cells }
end

local function cb(name, fn)
    QBCore.Functions.CreateCallback('pfm-prison:server:' .. name, function(source, respond, ...)
        local src = tonumber(source)
        if not src or src <= 0 then return respond(Err('bad_args', 'No player')) end
        if not F.Rate(src, 'cb:' .. name, 0.5) then return respond(Err('rate_limited', 'Slow down')) end
        local ok, res = pcall(fn, src, ...)
        if not ok then
            print(('^1[pfm-prison]^7 %s failed: %s'):format(name, tostring(res)))
            res = Err('db_unavailable', 'Something went wrong')
        end
        respond(res)
    end)
end
F.Callback = cb

cb('facilityRoster', function(src) return F.Roster(src) end)
cb('setLockdown', function(src, on, reason, minutes) return F.StaffLockdown(src, on == true, reason, minutes) end)
cb('setClassification', function(src, cid, class, reason)
    return F.SetClassification(cid, class, { actor = { src = src }, reason = reason })
end)
cb('assignCell', function(src, cid, cellId) return F.AssignCell(src, cid, cellId) end)
cb('setCellService', function(src, cellId, outOfService) return F.SetCellService(src, cellId, outOfService == true) end)

-- ── characters deleted ─────────────────────────────────────────────────────────────────────────

AddEventHandler('pfm-core:server:characterDeleted', function(cid)
    local s = tonumber(source)
    if (s and s > 0) or not F.ValidCid(cid) then return end
    F.activity[cid], F.intakeAt[cid] = nil, nil
    F.Db('update', 'DELETE FROM pf_prison_infractions WHERE citizenid = ?', { cid })
    F.Db('update', 'DELETE FROM pf_prison_privileges WHERE citizenid = ?', { cid })
    F.Db('update', 'DELETE FROM pf_prison_visits WHERE inmate_cid = ? OR visitor_cid = ?', { cid, cid })
    F.Db('update', 'UPDATE pf_prison_counts SET by_cid = NULL WHERE by_cid = ?', { cid })
    if PFPrison.Discipline and PFPrison.Discipline.priv then PFPrison.Discipline.priv[cid] = nil end
end)

-- ── start and the tick ─────────────────────────────────────────────────────────────────────────

--- After the tables are ready: cells, a lockdown that was running, the modules' own loads.
function F.Boot(now)
    if not F.DbReady() then return false end
    now = now or os.time()
    F.LoadCells()
    F.RestoreLockdown(now)
    for _, m in ipairs({ PFPrison.Schedule, PFPrison.Discipline, PFPrison.Visitation }) do
        if m and F.Callable(m.Boot) then
            local ok, err = pcall(m.Boot, now)
            if not ok then print(('^1[pfm-prison]^7 boot failed: %s'):format(tostring(err))) end
        end
    end
    F.booted = true
    return true
end

--- One facility tick (every TickSeconds; specs call it): lockdown end, routine, visits, discipline.
function F.Tick(now)
    now = now or os.time()
    if F.lockdown.on and F.lockdown.untilAt and F.lockdown.untilAt <= now then F.ApplyLockdown(false, {}) end
    for cid in pairs(F.intakeAt) do
        if not B.rows[cid] then F.intakeAt[cid] = nil end
    end
    for cid in pairs(F.activity) do
        if not F.Row(cid) then F.activity[cid] = nil end
    end
    for _, m in ipairs({ PFPrison.Schedule, PFPrison.Visitation, PFPrison.Discipline }) do
        if m and F.Callable(m.Tick) then
            local ok, err = pcall(m.Tick, now)
            if not ok then print(('^1[pfm-prison]^7 facility tick failed: %s'):format(tostring(err))) end
        end
    end
end

CreateThread(function()
    while not F.booted do
        Wait(2000)
        if F.DbReady() then F.Boot() end
    end
    while true do
        Wait(math.max(1, num(CF.TickSeconds, 5)) * 1000)
        F.Tick()
    end
end)
