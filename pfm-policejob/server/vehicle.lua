-- Police vehicles: impound / depot / seizure (with the tow job), impound records, seizure release,
-- the legacy plate commands and the legacy radar alert.
--
-- Impound records (batch 18B, pf_police_impounds): every impound of an owned car writes one row with
-- reason, officer, hold-until and case reference. States: ordered (a tow order is open) ->
-- impounded -> released. A depot row is released when the owner paid the depot fee at a garage
-- (seen when the row is read). A seizure with a hold cannot be released before the hold ends,
-- except by a supervisor (Config.Traffic.Impound.OverrideGrade).
--
-- Plate flags: /flagplate keeps a field flag in memory (shared with server/traffic.lua through
-- PFTraffic.FieldFlags); the MDT's flags come from pf-policemdt-DEV GetPlateFlags (server/traffic.lua).

PFTraffic = PFTraffic or {}
PFTraffic.FieldFlags = PFTraffic.FieldFlags or {}
local Plates = PFTraffic.FieldFlags -- [PLATE] = { isflagged, reason, at, by }

PFImpound = PFImpound or {}
local I = PFImpound

local function IsVehicleOwned(plate)
    local result = MySQL.scalar.await('SELECT plate FROM player_vehicles WHERE plate = ?', { plate })
    return result
end

local function TrafficCfg() return Config.Traffic or {} end
local function LeoTypes() return TrafficCfg().LeoJobTypes or { leo = true } end

local function IsOnDutyLeo(Player)
    local job = Player and Player.PlayerData and Player.PlayerData.job
    return job ~= nil and LeoTypes()[job.type] == true and job.onduty == true
end

local function GradeOf(Player)
    local g = Player and Player.PlayerData.job and Player.PlayerData.job.grade
    return type(g) == 'table' and (tonumber(g.level) or 0) or (tonumber(g) or 0)
end

local function TrimPlate(plate)
    return (tostring(plate or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

-- strips control characters, trims and clips; nil when nothing is left
local function CleanText(v, max)
    if type(v) ~= 'string' then return nil end
    v = v:gsub('%c', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    if v == '' then return nil end
    return v:sub(1, max)
end

-- the vehicle being impounded must exist next to the officer (any owned plate could be impounded from anywhere)
local function IsPlateNearby(src, plate)
    local pos = GetEntityCoords(GetPlayerPed(src))
    plate = TrimPlate(plate):upper()
    for _, veh in ipairs(GetAllVehicles()) do
        if TrimPlate(GetVehicleNumberPlateText(veh)):upper() == plate and #(pos - GetEntityCoords(veh)) < 10.0 then
            return true
        end
    end
    return false
end

local function Clamp(v, lo, hi)
    v = tonumber(v)
    if not v or v ~= v then return nil end
    return math.max(lo, math.min(hi, v))
end

-- ── impound records ─────────────────────────────────────────────────────────────────────────────

local function DbReady()
    return PFPoliceSchema ~= nil and PFPoliceSchema.Ready ~= nil and PFPoliceSchema.Ready() == true
end

local function Affected(res)
    if type(res) == 'table' then return tonumber(res.affectedRows) or tonumber(res.changedRows) or 0 end
    return tonumber(res) or 0
end

local function Q(kind, sql, params)
    local ok, res = pcall(MySQL[kind].await, sql, params)
    if not ok then
        print(('^1[pfm-policejob]^7 impound record query failed: %s'):format(tostring(res)))
        return nil, false
    end
    return res, true
end

I.SQL = {
    insert = 'INSERT INTO pf_police_impounds (plate, owner_cid, kind, reason, officer_cid, lot, fee, hold_until, case_ref, tow_request_id, state, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    byOrder = 'SELECT id, state FROM pf_police_impounds WHERE tow_request_id = ? ORDER BY id DESC LIMIT 1',
    orderImpounded = "UPDATE pf_police_impounds SET state = 'impounded' WHERE tow_request_id = ? AND state = 'ordered'",
    active = "SELECT id, plate, owner_cid, kind, reason, officer_cid, lot, fee, hold_until, case_ref, tow_request_id, state, created_at FROM pf_police_impounds WHERE plate = ? AND state IN ('ordered', 'impounded') ORDER BY id DESC LIMIT 1",
    latest = 'SELECT id, plate, owner_cid, kind, reason, officer_cid, lot, fee, hold_until, case_ref, tow_request_id, state, released_by, created_at, released_at FROM pf_police_impounds WHERE plate = ? ORDER BY id DESC LIMIT 1',
    release = "UPDATE pf_police_impounds SET state = 'released', released_by = ?, released_at = ? WHERE id = ? AND state IN ('ordered', 'impounded')",
    supersede = "UPDATE pf_police_impounds SET state = 'released', released_by = 'superseded', released_at = ? WHERE plate = ? AND state IN ('ordered', 'impounded') AND id <> ?",
    owner = 'SELECT citizenid FROM player_vehicles WHERE plate = ? LIMIT 1',
    depotState = 'SELECT state, depotprice FROM player_vehicles WHERE plate = ? LIMIT 1',
    activeFor = "SELECT plate, kind, reason, officer_cid, hold_until, case_ref, created_at FROM pf_police_impounds WHERE state IN ('ordered', 'impounded') AND plate IN (%s)",
}

--- Details an officer gives with an impound (client hints, checked here): reason, hold, case ref.
function I.CleanDetails(details, fullImpound)
    local cfg = TrafficCfg().Impound or {}
    details = type(details) == 'table' and details or {}
    local out = { reason = CleanText(details.reason, 255) or cfg.DefaultReason or 'Impounded by police' }
    local hours = math.tointeger(tonumber(details.holdHours))
    -- a hold only makes sense on a seizure: a depot car is fetched by its owner at a garage
    if fullImpound and hours and hours > 0 then
        out.holdHours = math.min(hours, tonumber(cfg.MaxHoldHours) or 168)
    end
    local case = CleanText(details.caseRef, 64)
    if case and case:match('^[%w%-_:#%.]+$') then out.caseRef = case end
    return out
end

--- Writes one impound row for an owned car; nil when the schema is not ready or the car has no owner.
--- spec = { plate, kind = 'depot'|'seizure', reason, officer, fee, holdUntil, caseRef, towRequestId, state, lot }
function I.Record(spec)
    if not DbReady() then return nil end
    local plate = TrimPlate(spec.plate):upper()
    if plate == '' or #plate > 16 then return nil end
    local owner = Q('scalar', I.SQL.owner, { TrimPlate(spec.plate) })
    if type(owner) ~= 'string' or owner == '' then return nil end
    local now = os.time()
    local id = Q('insert', I.SQL.insert, {
        plate, owner, spec.kind == 'seizure' and 'seizure' or 'depot', CleanText(spec.reason, 255) or 'Impounded by police',
        tostring(spec.officer or 'system'):sub(1, 64), spec.lot and tostring(spec.lot):sub(1, 32) or nil,
        math.max(0, math.floor(tonumber(spec.fee) or 0)), tonumber(spec.holdUntil), spec.caseRef,
        tonumber(spec.towRequestId), spec.state or 'impounded', now,
    })
    id = tonumber(id)
    -- a newer impound of the same car closes any older open record (one active record per plate)
    if id then Q('update', I.SQL.supersede, { now, plate, id }) end
    return id
end

--- Impound record fields from the options an impound carries (also the tow order's meta).
local function RecordSpec(plate, opts, state, requestId)
    return {
        plate = plate, kind = opts.fullImpound and 'seizure' or 'depot', reason = opts.reason,
        officer = opts.officer, fee = opts.fullImpound and 0 or opts.price, holdUntil = opts.holdUntil,
        caseRef = opts.caseRef, towRequestId = requestId, state = state,
    }
end

--- True when the tow order's impound is already recorded as done (survives a restart).
function I.OrderApplied(requestId)
    if not DbReady() then return false end
    local row = Q('single', I.SQL.byOrder, { requestId })
    return type(row) == 'table' and (row.state == 'impounded' or row.state == 'released')
end

-- A depot record ends when the owner fetched the car (a garage cleared the fee or garaged it).
local function ReconcileDepot(row)
    if row.kind ~= 'depot' or row.state ~= 'impounded' then return row end
    local car = Q('single', I.SQL.depotState, { row.plate })
    if type(car) ~= 'table' then return row end
    local state, fee = tonumber(car.state), tonumber(car.depotprice)
    if state == 1 or (state == 0 and fee == 0 and (tonumber(row.fee) or 0) > 0) then
        local res = Q('update', I.SQL.release, { 'garage', os.time(), row.id })
        if Affected(res) == 1 then return nil end
    end
    return row
end

local function PublicRow(row)
    if type(row) ~= 'table' or not tonumber(row.id) then return nil end
    return {
        id = tonumber(row.id), plate = row.plate, ownerCid = row.owner_cid, kind = row.kind, reason = row.reason,
        officerCid = row.officer_cid, lot = row.lot, fee = tonumber(row.fee) or 0, holdUntil = tonumber(row.hold_until),
        caseRef = row.case_ref, towRequestId = tonumber(row.tow_request_id), state = row.state,
        releasedBy = row.released_by, createdAt = tonumber(row.created_at), releasedAt = tonumber(row.released_at),
    }
end

--- The open impound record of a plate (ordered or impounded), or nil.
function I.Active(plate)
    if not DbReady() then return nil, 'db_unavailable' end
    plate = TrimPlate(plate):upper()
    local row, ok = Q('single', I.SQL.active, { plate })
    if not ok then return nil, 'db_unavailable' end
    if type(row) ~= 'table' or not row.id then return nil end
    return PublicRow(ReconcileDepot(row))
end

--- GetImpound(plate) (architecture 4.10): { ok, impound? } with the open record, or the last one
--- with opts.history.
function I.Get(plate, opts)
    if type(plate) ~= 'string' or #plate > 16 or TrimPlate(plate) == '' then return { ok = false, error = 'bad_args' } end
    local active, err = I.Active(plate)
    if err then return { ok = false, error = err, message = 'Impound records are not available' } end
    if active or not (type(opts) == 'table' and opts.history) then return { ok = true, impound = active } end
    local row = Q('single', I.SQL.latest, { TrimPlate(plate):upper() })
    return { ok = true, impound = PublicRow(row) }
end

--- Marks the open record of a plate released.
function I.MarkReleased(plate, by)
    local row = I.Active(plate)
    if not row then return false end
    return Affected(Q('update', I.SQL.release, { tostring(by or 'system'):sub(1, 64), os.time(), row.id })) == 1
end

exports('GetImpound', function(plate, opts)
    local invoker = GetInvokingResource()
    if invoker ~= nil and invoker ~= GetCurrentResourceName() then
        local list = (TrafficCfg().Callers or {}).GetImpound
        if list ~= '*' and not (type(list) == 'table' and list[invoker]) then return { ok = false, error = 'not_allowed' } end
    end
    return I.Get(plate, opts)
end)

-- Callbacks

QBCore.Functions.CreateCallback('police:GetImpoundedVehicles', function(source, cb)
    local vehicles = {}
    -- the impound list (owners' citizenids and licenses) is for officers only
    if not IsOnDutyLeo(exports['pfm-core']:GetPlayer(source)) then return cb(vehicles) end
    MySQL.query('SELECT * FROM player_vehicles WHERE state = ?', { 2 }, function(result)
        if result and result[1] then
            vehicles = result
            -- attach the impound record (reason, hold, case) so the officer sees why a car is held
            if DbReady() and #vehicles <= 200 then
                local marks, params = {}, {}
                for i, v in ipairs(vehicles) do marks[i] = '?'; params[i] = TrimPlate(v.plate):upper() end
                local rows = Q('query', I.SQL.activeFor:format(table.concat(marks, ',')), params)
                local byPlate = {}
                for _, r in ipairs(type(rows) == 'table' and rows or {}) do byPlate[r.plate] = r end
                for _, v in ipairs(vehicles) do
                    local r = byPlate[TrimPlate(v.plate):upper()]
                    if r then v.impound = { kind = r.kind, reason = r.reason, holdUntil = tonumber(r.hold_until), caseRef = r.case_ref, officer = r.officer_cid } end
                end
            end
        end
        cb(vehicles)
    end)
end)

local function FieldFlag(plate)
    local f = Plates[plate]
    if not f or not f.isflagged then return nil end
    local hours = tonumber((TrafficCfg().Alpr or {}).FieldFlagHours) or 12
    if f.at and os.time() - f.at > hours * 3600 then Plates[plate] = nil return nil end
    return f
end

-- Flags of a plate: the MDT's (server/traffic.lua) plus a field flag from /flagplate.
local function PlateFlagged(plate)
    plate = TrimPlate(plate):upper()
    if FieldFlag(plate) then return true end
    if PFTraffic.FlagsFor then
        local f = PFTraffic.FlagsFor(plate)
        return f ~= nil and #(f.flags or {}) > 0
    end
    return false
end

QBCore.Functions.CreateCallback('police:server:IsPlateFlagged', function(source, cb, plate)
    -- plate flags are police information: on-duty officers only
    if not IsOnDutyLeo(exports['pfm-core']:GetPlayer(source)) then return cb(false) end
    if type(plate) ~= 'string' or #plate > 16 then return cb(false) end
    cb(PlateFlagged(plate))
end)

-- Events

RegisterNetEvent('heli:server:spotlight', function(state)
    local serverID = source
    if not IsOnDutyLeo(exports['pfm-core']:GetPlayer(serverID)) then return end
    state = state == true
    TriggerClientEvent('heli:client:spotlight', -1, serverID, state)
end)

-- The vehicle entity with this plate (server-side, OneSync), or nil.
local function FindVehicleByPlate(plate)
    plate = TrimPlate(plate):upper()
    for _, veh in ipairs(GetAllVehicles()) do
        if TrimPlate(GetVehicleNumberPlateText(veh)):upper() == plate then return veh end
    end
    return nil
end

local function TowDriversOnDuty()
    local cfg = Config.ImpoundTow or {}
    local n = 0
    for _, P in pairs(QBCore.Functions.GetQBPlayers() or {}) do
        local job = P.PlayerData and P.PlayerData.job
        if job and job.name == (cfg.TowJob or 'tow') and job.onduty then n = n + 1 end
    end
    return n
end

-- Writes the impound to the vehicle record and removes the car from the world.
-- opts: { fullImpound, price, body, engine, fuel, officer = citizenid, reason, holdUntil, caseRef }
local function ApplyImpound(plate, opts)
    opts = opts or {}
    plate = TrimPlate(plate)
    if IsVehicleOwned(plate) then
        -- fuel: the server's level; else (fuelCap) the client's value only lowers the stored one;
        -- with neither (an order from the tow job) the stored fuel stays as it is
        local fuel = Clamp(opts.fuel, 0, 100)
        local cap = Clamp(opts.fuelCap, 0, 100)
        local fuelSql, fuelArgs = 'fuel = fuel', {}
        if fuel then
            fuelSql, fuelArgs = 'fuel = ?', { fuel }
        elseif cap then
            fuelSql, fuelArgs = 'fuel = LEAST(COALESCE(fuel, ?), ?)', { cap, cap }
        end
        local params
        if not opts.fullImpound then
            params = { 0, tonumber(opts.price) or 0, Clamp(opts.body, 0, 1000), Clamp(opts.engine, -4000, 1000) }
            for _, v in ipairs(fuelArgs) do params[#params + 1] = v end
            params[#params + 1] = plate
            MySQL.query('UPDATE player_vehicles SET state = ?, depotprice = ?, body = ?, engine = ?, ' .. fuelSql .. ' WHERE plate = ?', params)
        else
            params = { 2, Clamp(opts.body, 0, 1000), Clamp(opts.engine, -4000, 1000) }
            for _, v in ipairs(fuelArgs) do params[#params + 1] = v end
            params[#params + 1] = plate
            MySQL.query('UPDATE player_vehicles SET state = ?, body = ?, engine = ?, ' .. fuelSql .. ' WHERE plate = ?', params)
        end
    end
    local veh = FindVehicleByPlate(plate)
    if veh and DoesEntityExist(veh) then DeleteEntity(veh) end
    if GetResourceState('pf-services') == 'started' then
        pcall(function()
            exports['pf-services']:Emit('police.impound', { plate = plate, seized = opts.fullImpound == true }, { actor = opts.officer, dedupe = plate })
        end)
    end
    return true
end

--- Impound lots for the tow job: list of { coords = vector3, radius = number }.
exports('GetImpoundLots', function()
    local out = {}
    for _, c in ipairs(Config.Locations['impound'] or {}) do
        out[#out + 1] = { coords = c, radius = (Config.ImpoundTow or {}).LotRadius or 40.0 }
    end
    return out
end)

-- Tow orders (pf-services 'tow.impound' request ids) whose impound was already written: an order
-- is applied once, whether the tow driver delivered it, it closed untowed, or an officer
-- impounded the car on the spot while the order was still open. The impound record (state
-- 'impounded' / 'released' for the order) keeps that true across a restart.
local AppliedOrders = {}

local function ApplyImpoundOrder(plate, opts, requestId)
    requestId = tonumber(requestId)
    if requestId then
        -- marked before the first database wait, so two calls for one order cannot both apply it
        if AppliedOrders[requestId] then return false end
        AppliedOrders[requestId] = true
        if I.OrderApplied(requestId) then return false end
    end
    local applied = ApplyImpound(plate, opts)
    if DbReady() then
        local moved = requestId and Affected(Q('update', I.SQL.orderImpounded, { requestId })) == 1
        if not moved then I.Record(RecordSpec(plate, opts, 'impounded', requestId)) end
    end
    return applied
end

--- Called by the tow job when an ordered car reached an impound lot (server-checked there), and
--- when a tow order ends without a tow (expired, cancelled): the impound is then written directly,
--- as when no tow driver is on duty. `requestId` (the tow order) makes a second call a no-op.
exports('FinalizeImpound', function(plate, opts, requestId)
    if type(plate) ~= 'string' or #plate > 16 then return false end
    return ApplyImpoundOrder(plate, type(opts) == 'table' and opts or {}, requestId)
end)

-- An officer impounds on the spot while a tow order for the car is still open: the order is
-- closed (the city's tow fee refunded) and marked applied, so its close does not impound twice.
local function CloseOpenImpoundOrder(plate)
    if GetResourceState('pf-services') ~= 'started' then return end
    pcall(function()
        local open = exports['pf-services']:FindOpenByRef('vehicle', TrimPlate(plate):upper(), 'tow.impound')
        if type(open) == 'table' and tonumber(open.id) and open.kind == 'tow.impound' then
            AppliedOrders[tonumber(open.id)] = true
            exports['pf-services']:CancelRequest(nil, open.id, 'impounded_on_site')
        end
    end)
end

-- The fuel stored with an impounded car is the level the server keeps for it (pfm-fuel), not what
-- the officer's client reports. Without a level for that car the client's value can only lower the
-- stored one (fuelCap); with fuel sync off, the client's level is all there is.
local function ServerFuel(veh, plate)
    if not veh or GetResourceState('pfm-fuel') ~= 'started' then return nil, false end
    local ok, synced = pcall(function() return exports['pfm-fuel']:IsFuelSynced() end)
    if not ok or synced ~= true then return nil, false end
    local okLevel, level = pcall(function() return exports['pfm-fuel']:GetVehicleFuel(veh, TrimPlate(plate)) end)
    level = okLevel and tonumber(level) or nil
    if level and level == level then return math.max(0, math.min(100, level)), true end
    return nil, true
end

-- Body and engine health as the server sees the car, when the natives are there.
local function ServerHealth(veh, body, engine)
    if veh and GetVehicleBodyHealth and GetVehicleEngineHealth then
        local okB, b = pcall(GetVehicleBodyHealth, veh)
        local okE, e = pcall(GetVehicleEngineHealth, veh)
        if okB and tonumber(b) then body = Clamp(b, 0, 1000) end
        if okE and tonumber(e) then engine = Clamp(e, -4000, 1000) end
    end
    return body, engine
end

-- details (batch 18B, optional for old clients): { reason, holdHours (seizure only), caseRef }
RegisterNetEvent('police:server:Impound', function(plate, fullImpound, price, body, engine, fuel, details)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not IsOnDutyLeo(Player) then return end
    if type(plate) ~= 'string' or #plate > 16 then return end
    price = tonumber(price) or 0
    if price < 0 or price ~= price or price == math.huge then price = 0 end
    price = math.min(math.floor(price), Config.MaxFine or 50000)
    body, engine, fuel = Clamp(body, 0, 1000), Clamp(engine, -4000, 1000), Clamp(fuel, 0, 100)
    if not IsPlateNearby(src, plate) then return end
    local car = FindVehicleByPlate(plate)
    body, engine = ServerHealth(car, body, engine)
    local level, synced = ServerFuel(car, plate)
    local fuelCap
    if level then fuel = level elseif synced then fuel, fuelCap = nil, fuel end
    local info = I.CleanDetails(details, fullImpound == true)
    local opts = {
        fullImpound = fullImpound == true, price = price, body = body, engine = engine, fuel = fuel, fuelCap = fuelCap,
        officer = Player.PlayerData.citizenid, reason = info.reason, caseRef = info.caseRef,
        holdUntil = info.holdHours and (os.time() + info.holdHours * 3600) or nil,
    }

    -- a tow driver on duty brings the car in; the city pays the tow through pf-services
    local cfg = Config.ImpoundTow or {}
    if cfg.Enabled and GetResourceState('pf-services') == 'started' and TowDriversOnDuty() > 0 then
        local veh = FindVehicleByPlate(plate)
        local ci = Player.PlayerData.charinfo or {}
        local ok, res = pcall(function()
            return exports['pf-services']:CreateRequest({
                kind = 'tow.impound',
                title = ('Impound %s'):format(TrimPlate(plate)),
                details = opts.fullImpound and 'Seized by police: take it to the impound lot' or ('Depot: release fee $%d'):format(price),
                coords = veh and GetEntityCoords(veh) or GetEntityCoords(GetPlayerPed(src)),
                plate = TrimPlate(plate),
                ref = { type = 'vehicle', id = TrimPlate(plate):upper() },
                from = { type = 'job', id = Player.PlayerData.job.name, name = ((ci.firstname or '') .. ' ' .. (ci.lastname or '')):gsub('^%s+', '') },
                meta = opts,
            })
        end)
        -- only a tow.impound order counts (an open garage or mechanic tow of the car is not one)
        if ok and type(res) == 'table' and res.ok and type(res.request) == 'table' and res.request.kind == 'tow.impound' then
            if veh then SetVehicleDoorsLocked(veh, 2) end
            -- an existing order for the car keeps its own record
            if not res.existing then I.Record(RecordSpec(plate, opts, 'ordered', res.request.id or res.id)) end
            TriggerClientEvent('police:client:ImpoundDecision', src, plate, 'tow')
            TriggerClientEvent('QBCore:Notify', src, 'Tow ordered: leave the vehicle, a tow truck is coming', 'success')
            return
        end
    end

    CloseOpenImpoundOrder(plate)
    ApplyImpound(plate, opts)
    I.Record(RecordSpec(plate, opts, 'impounded', nil))
    TriggerClientEvent('police:client:ImpoundDecision', src, plate, 'instant')
    if IsVehicleOwned(plate) then
        if not opts.fullImpound then
            TriggerClientEvent('QBCore:Notify', src, Lang:t('info.vehicle_taken_depot', { price = price }))
        else
            TriggerClientEvent('QBCore:Notify', src, Lang:t('info.vehicle_seized'))
        end
    end
end)

-- Releasing a seized car from the police impound: the server takes the row out of the impound once
-- (state 2 -> 0), spawns the car itself with its plate and names its row to pfm-fuel, so it starts
-- with the fuel stored for it. The officer's client used to spawn it, set its plate and give it any
-- fuel it liked. The client then applies the stored mods and damage. A seizure held until a later
-- time stays in the impound unless a supervisor releases it.
local sharedVehicles
local releasing = {} -- [plate] = true while a release of it is in progress

QBCore.Functions.CreateCallback('police:server:ReleaseImpound', function(source, cb, plate, garage)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or not IsOnDutyLeo(Player) then return cb(nil) end
    garage = math.tointeger(tonumber(garage))
    local lot = garage and Config.Locations['impound'][garage]
    if type(plate) ~= 'string' or #plate > 16 or not lot then return cb(nil) end
    plate = TrimPlate(plate)
    if plate == '' then return cb(nil) end
    if #(GetEntityCoords(GetPlayerPed(src)) - vector3(lot.x, lot.y, lot.z)) > 10.0 then return cb(nil) end
    if releasing[plate] then return cb(nil) end
    releasing[plate] = true
    local record = I.Active(plate)
    local override = tonumber((TrafficCfg().Impound or {}).OverrideGrade) or 3
    if record and record.holdUntil and record.holdUntil > os.time() and GradeOf(Player) < override then
        releasing[plate] = nil
        TriggerClientEvent('QBCore:Notify', src, ('This vehicle is held until %s'):format(os.date('%Y-%m-%d %H:%M', record.holdUntil)), 'error')
        return cb(nil)
    end
    local ok, row = pcall(MySQL.single.await, 'SELECT vehicle, mods, body, engine, fuel FROM player_vehicles WHERE plate = ? AND state = ? LIMIT 1', { plate, 2 })
    if not ok or not row then releasing[plate] = nil return cb(nil) end
    -- one release per seizure: the row leaves the impound before anything spawns
    local okU, changed = pcall(MySQL.update.await, 'UPDATE player_vehicles SET state = ? WHERE plate = ? AND state = ?', { 0, plate, 2 })
    changed = okU and (type(changed) == 'table' and tonumber(changed.affectedRows) or tonumber(changed)) or 0
    if changed ~= 1 then releasing[plate] = nil return cb(nil) end
    sharedVehicles = sharedVehicles or exports['pfm-core']:GetShared('Vehicles') or {}
    local model = row.vehicle
    local hash = type(model) == 'number' and model or (type(model) == 'string' and GetHashKey(model)) or nil
    local vehType = (type(model) == 'string' and sharedVehicles[model] and sharedVehicles[model].type) or 'automobile'
    local veh = hash and CreateVehicleServerSetter(hash, vehType, lot.x, lot.y, lot.z, lot.w or 0.0)
    if not veh or veh == 0 then
        MySQL.update('UPDATE player_vehicles SET state = ? WHERE plate = ? AND state = ?', { 2, plate, 0 })
        releasing[plate] = nil
        return cb(nil)
    end
    SetVehicleNumberPlateText(veh, plate)
    -- pfm-fuel gives the car the fuel stored in this row (the plate set above reaches the server
    -- only through a client)
    if GetResourceState('pfm-fuel') == 'started' then pcall(function() exports['pfm-fuel']:UseStoredFuel(veh, plate) end) end
    if record then I.MarkReleased(plate, Player.PlayerData.citizenid) end
    releasing[plate] = nil
    TriggerClientEvent('QBCore:Notify', src, Lang:t('success.impound_vehicle_removed'), 'success')
    cb(NetworkGetNetworkIdFromEntity(veh), { plate = plate, mods = row.mods, body = tonumber(row.body), engine = tonumber(row.engine) })
end)

-- Legacy: sent by old clients when the driver of a flagged car passed a radar. The server's own
-- fixed ALPR readers (server/traffic.lua) see these cars now; this report is still checked (the
-- plate must be flagged and the driver at a radar) and dropped when that reader already alerted.
RegisterNetEvent('police:server:FlaggedPlateTriggered', function(coords, plate)
    local src = source
    if type(plate) ~= 'string' or #plate > 16 then return end
    plate = TrimPlate(plate):upper()
    if not PlateFlagged(plate) then return end
    local pos = GetEntityCoords(GetPlayerPed(src))
    coords = nil
    local radarIndex
    for i, radar in ipairs(Config.Radars or {}) do
        if #(pos - radar) < 40.0 then coords, radarIndex = radar, i break end
    end
    if not coords then return end
    if PFTraffic.FixedAlertSeen and PFTraffic.FixedAlertSeen('fixed:' .. radarIndex, plate) then return end
    local message = Lang:t('info.flagged_vehicle_radar', { plate = plate })
    for _, Player in pairs(QBCore.Functions.GetQBPlayers()) do
        -- every on-duty police job (sheriff, state police...), not only 'police'
        if Player and IsOnDutyLeo(Player) then
            TriggerClientEvent('police:client:policeAlert', Player.PlayerData.source, coords, message)
        end
    end
end)

-- Commands

local function PlateArg(args)
    local plate = type(args) == 'table' and args[1]
    if type(plate) ~= 'string' then return nil end
    plate = TrimPlate(plate):upper()
    if plate == '' or #plate > 16 then return nil end
    return plate
end

QBCore.Commands.Add('flagplate', Lang:t('commands.flagplate'), { { name = 'plate', help = Lang:t('info.plate_number') }, { name = 'reason', help = Lang:t('info.flag_reason') } }, true, function(source, args)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not IsOnDutyLeo(Player) then
        return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.on_duty_police_only'), 'error')
    end
    local plate = PlateArg(args)
    if not plate then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.vehicle_not_flag'), 'error') end
    local reason = {}
    for i = 2, #args, 1 do reason[#reason + 1] = tostring(args[i]) end
    reason = CleanText(table.concat(reason, ' '), 120) or 'No reason given'
    -- a field flag: memory only, expires after Config.Traffic.Alpr.FieldFlagHours (MDT flags persist)
    Plates[plate] = { isflagged = true, reason = reason, at = os.time(), by = Player.PlayerData.citizenid }
    TriggerClientEvent('QBCore:Notify', src, Lang:t('info.vehicle_flagged', { vehicle = plate, reason = reason }))
end)

QBCore.Commands.Add('unflagplate', Lang:t('commands.unflagplate'), { { name = 'plate', help = Lang:t('info.plate_number') } }, true, function(source, args)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not IsOnDutyLeo(Player) then
        return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.on_duty_police_only'), 'error')
    end
    local plate = PlateArg(args)
    if plate and FieldFlag(plate) then
        Plates[plate] = nil
        TriggerClientEvent('QBCore:Notify', src, Lang:t('info.unflag_vehicle', { vehicle = plate }))
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.vehicle_not_flag'), 'error')
    end
end)

QBCore.Commands.Add('plateinfo', Lang:t('commands.plateinfo'), { { name = 'plate', help = Lang:t('info.plate_number') } }, true, function(source, args)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not IsOnDutyLeo(Player) then
        return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.on_duty_police_only'), 'error')
    end
    local plate = PlateArg(args)
    if not plate then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.vehicle_not_flag'), 'error') end
    -- the full plate check (owner, licence, MDT flags, impound) when server/traffic.lua is loaded
    if PFTraffic.RunPlateFor then return PFTraffic.RunPlateFor(src, plate) end
    local f = FieldFlag(plate)
    if f then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('success.vehicle_flagged', { plate = plate, reason = f.reason }), 'success')
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.vehicle_not_flag'), 'error')
    end
end)
