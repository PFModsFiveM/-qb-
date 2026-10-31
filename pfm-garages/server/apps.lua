-- The Garages app (pf-devices, tablet and computer): every car the citizen owns with where it is,
-- its condition and a waypoint; the impound release fee paid ahead through the same ledger path as
-- the depot (the car is then taken out at a depot); a tow of a car that is out to one of the
-- citizen's garages through pf-services 'tow.recovery'. Nothing here spawns a car. Every handler
-- reads the player's own rows by their citizen id; nothing the client sends identifies the owner.

PFGarages = PFGarages or {}

local APP = 'garages'
local sharedVehicles = exports['pfm-core']:GetShared('Vehicles') or {}

local Tow = {
    radius = 30.0,          -- the tow driver delivers the car within this distance of the garage
    cooldown = 30,          -- seconds between tow requests of one citizen
    minDistance = 60.0,     -- a car already at the garage does not need a tow
}
local lastTow = {}          -- [citizenid] = os.time()

local function started(res) return GetResourceState(res) == 'started' end

local function playerOf(src) return exports['pfm-core']:GetPlayer(src) end

local function cleanPlate(v)
    if type(v) ~= 'string' then return nil end
    v = v:gsub('^%s+', ''):gsub('%s+$', '')
    if v == '' or #v > 16 or v:find('[%c]') then return nil end
    return v
end

local function nameOf(Player)
    local ci = Player.PlayerData.charinfo or {}
    local n = ((ci.firstname or '') .. ' ' .. (ci.lastname or '')):gsub('^%s+', ''):gsub('%s+$', '')
    return n ~= '' and n or 'A citizen'
end

local function vehicleLabel(model)
    local v = sharedVehicles[model]
    if not v then return tostring(model or 'Unknown vehicle'), '', '' end
    local brand = v.brand or ''
    return (brand ~= '' and (brand .. ' ' .. (v.name or model)) or (v.name or model)), brand, v.category or ''
end

local function point(v)
    if not v then return nil end
    local x, y = tonumber(v.x), tonumber(v.y)
    if not x or not y then return nil end
    return { x = math.floor(x * 100 + 0.5) / 100, y = math.floor(y * 100 + 0.5) / 100 }
end

local function pct(v, max)
    v = tonumber(v)
    if not v then return nil end
    return math.max(0, math.min(100, math.floor(v / max * 100 + 0.5)))
end

-- The depot a car of this model is taken to (the one whose vehicle classes include its class).
local function depotFor(model)
    local class = PFGarages.VehicleClasses and PFGarages.VehicleClasses[(sharedVehicles[model] or {}).category or 'compacts']
    local fallback
    for id, g in pairs(Config.Garages) do
        if g.type == 'depot' then
            for _, c in ipairs(g.category or {}) do
                if c == class then return id, g end
            end
            if not fallback or id < fallback then fallback = id end
        end
    end
    if fallback then return fallback, Config.Garages[fallback] end
end

-- The public garages a citizen may have a car towed to, and their own house garages.
local function towGarages(Player)
    local out = {}
    for id, g in pairs(Config.Garages) do
        local allowed = g.type == 'public'
        if g.type == 'house' and g.houseName and started('pfm-houses') then
            local ok, has = pcall(function() return exports['pfm-houses']:hasKey(Player.PlayerData.license, Player.PlayerData.citizenid, g.houseName) end)
            allowed = ok and has == true
        end
        if allowed and g.takeVehicle then
            out[#out + 1] = { id = id, label = g.label or id, type = g.type, coords = point(g.takeVehicle) }
        end
    end
    table.sort(out, function(a, b) return a.label < b.label end)
    return out
end

local function openTow(plate)
    if not started('pf-services') then return nil end
    local ok, req = pcall(function() return exports['pf-services']:FindOpenByRef('vehicle', plate) end)
    return ok and type(req) == 'table' and req or nil
end

local function push(src, event, payload)
    if not started('pf-devices') then return end
    pcall(function() exports['pf-devices']:Push(src, APP, event, payload or {}) end)
end

local function pushCitizen(cid, event, payload)
    if not started('pf-devices') then return end
    pcall(function() exports['pf-devices']:PushToCitizen(cid, APP, event, payload or {}) end)
end

function PFGarages.PushChanged(src) push(src, 'changed') end

local function bankOf(Player)
    local m = Player.PlayerData.money or {}
    return tonumber(m.cash) or 0, tonumber(m.bank) or 0
end

--- Every car the player owns, as the app shows it.
function PFGarages.AppList(src)
    local Player = playerOf(src)
    if not Player then return { ok = false, error = 'no_player' } end
    local cid = Player.PlayerData.citizenid
    local rows = MySQL.query.await('SELECT plate, vehicle, garage, state, depotprice, fuel, engine, body, balance FROM player_vehicles WHERE citizenid = ?', { cid }) or {}
    local plates = {}
    for _, r in ipairs(rows) do plates[#plates + 1] = r.plate end
    local fleet = PFGarages.FleetPlateSet(plates)
    local paid = PFGarages.PaidReleases(cid)
    local vehicles, feesDue = {}, 0
    for _, r in ipairs(rows) do
        local label, brand, category = vehicleLabel(r.vehicle)
        local state, fee = tonumber(r.state) or 1, math.floor(tonumber(r.depotprice) or 0)
        local v = {
            plate = r.plate, model = r.vehicle, label = label, brand = brand, category = category,
            fuel = pct(r.fuel, 100), engine = pct(r.engine, 1000), body = pct(r.body, 1000),
            finance = (tonumber(r.balance) or 0) > 0 and tonumber(r.balance) or nil,
        }
        if fleet[r.plate] then
            v.status = 'fleet'
        elseif state == 2 then
            v.status = 'seized'
        elseif fee > 0 then
            v.status = 'impounded'
            v.fee = fee
            local p = paid[r.plate]
            v.feePaid = p ~= nil and (p == true or p >= fee)
            v.canPay = not v.feePaid
            if not v.feePaid then feesDue = feesDue + fee end
            local depotId, depot = depotFor(r.vehicle)
            if depot then v.location = { id = depotId, label = depot.label or depotId, coords = point(depot.takeVehicle) } end
        elseif state == 1 then
            if paid[r.plate] then PFGarages.VoidStaleRelease(r.plate) end
            v.status = 'garaged'
            local g = r.garage and Config.Garages[r.garage]
            v.location = { id = r.garage, label = g and g.label or (r.garage and 'House garage' or 'Unknown garage'), coords = g and point(g.takeVehicle) or nil }
        else
            if paid[r.plate] then PFGarages.VoidStaleRelease(r.plate) end
            v.status = 'out'
            v.inWorld = PFGarages.FindVehicle(r.plate) ~= nil
            local tow = openTow(r.plate)
            if tow then
                v.tow = { id = tow.id, status = tow.status, assignee = tow.assigneeName, mine = tow.requester == cid, garage = tow.meta and tow.meta.garageLabel }
            end
            v.canTow = v.inWorld and not tow and started('pf-services')
        end
        vehicles[#vehicles + 1] = v
    end
    table.sort(vehicles, function(a, b) if a.label ~= b.label then return a.label < b.label end return a.plate < b.plate end)
    local cash, bank = bankOf(Player)
    local towFee
    if started('pf-services') then
        local ok, def = pcall(function() return exports['pf-services']:GetRequestKind('tow.recovery') end)
        towFee = ok and type(def) == 'table' and tonumber(def.reward) or nil
    end
    return {
        ok = true, vehicles = vehicles, feesDue = feesDue, cash = cash, bank = bank,
        garages = towGarages(Player), towFee = towFee, towAvailable = started('pf-services'),
    }
end

local function ownRow(cid, plate)
    return MySQL.single.await('SELECT plate, vehicle, garage, state, depotprice FROM player_vehicles WHERE plate = ? AND citizenid = ? LIMIT 1', { plate, cid })
end

--- Where an owned car that is out is right now (for a waypoint).
function PFGarages.AppLocate(src, payload)
    local Player = playerOf(src)
    if not Player then return { ok = false, error = 'no_player' } end
    local plate = cleanPlate(payload and payload.plate)
    if not plate then return { ok = false, error = 'bad_plate' } end
    local row = ownRow(Player.PlayerData.citizenid, plate)
    if not row then return { ok = false, error = 'not_owned' } end
    if PFGarages.IsFleetPlate(plate) then return { ok = false, error = 'fleet' } end
    local veh = PFGarages.FindVehicle(plate)
    if not veh or not DoesEntityExist(veh) then return { ok = false, error = 'not_found' } end
    return { ok = true, coords = point(GetEntityCoords(veh)) }
end

--- Pays the impound release fee ahead; the car is then taken out at the depot without paying again.
function PFGarages.AppPayDepot(src, payload)
    local plate = cleanPlate(payload and payload.plate)
    if not plate then return { ok = false, error = 'bad_plate' } end
    local res = PFGarages.PayDepot(src, plate)
    if res.ok then
        local _, depot = depotFor((ownRow(playerOf(src).PlayerData.citizenid, plate) or {}).vehicle)
        res.depot = depot and { label = depot.label, coords = point(depot.takeVehicle) } or nil
        push(src, 'changed')
    end
    return res
end

--- Asks the tow job to bring a car that is out to one of the citizen's garages. The citizen pays the
--- call-out fee through pf-services (escrowed, refunded if nobody does it); once a tow driver
--- delivered it, the car is parked there (see the requestChanged listener below).
function PFGarages.AppRequestTow(src, payload)
    local Player = playerOf(src)
    if not Player then return { ok = false, error = 'no_player' } end
    if type(payload) ~= 'table' then return { ok = false, error = 'bad_request' } end
    local plate = cleanPlate(payload.plate)
    local garageId = type(payload.garage) == 'string' and #payload.garage <= 64 and payload.garage or nil
    if not plate or not garageId then return { ok = false, error = 'bad_request' } end
    if not started('pf-services') then return { ok = false, error = 'tow_unavailable' } end
    local cid = Player.PlayerData.citizenid

    local garage
    for _, g in ipairs(towGarages(Player)) do if g.id == garageId then garage = g end end
    if not garage or not garage.coords then return { ok = false, error = 'bad_garage' } end
    local row = ownRow(cid, plate)
    if not row then return { ok = false, error = 'not_owned' } end
    if PFGarages.IsFleetPlate(plate) then return { ok = false, error = 'fleet' } end
    if tonumber(row.state) ~= 0 or (tonumber(row.depotprice) or 0) > 0 then return { ok = false, error = 'not_out' } end
    local veh = PFGarages.FindVehicle(plate)
    if not veh or not DoesEntityExist(veh) then return { ok = false, error = 'not_found' } end
    local driver = GetPedInVehicleSeat(veh, -1)
    if driver and driver ~= 0 then return { ok = false, error = 'occupied' } end
    local pos = GetEntityCoords(veh)
    local g = Config.Garages[garageId].takeVehicle
    if #(vector3(pos.x, pos.y, pos.z) - vector3(g.x, g.y, g.z)) <= Tow.minDistance then return { ok = false, error = 'already_there' } end
    if openTow(plate) then return { ok = false, error = 'tow_exists' } end
    local now = os.time()
    if lastTow[cid] and now - lastTow[cid] < Tow.cooldown then return { ok = false, error = 'cooldown' } end
    lastTow[cid] = now

    local label = vehicleLabel(row.vehicle)
    local ok, res = pcall(function()
        return exports['pf-services']:CreateRequest({
            kind = 'tow.recovery',
            title = ('Tow %s to %s'):format(plate, garage.label),
            details = ('%s asks for their %s to be brought to %s'):format(nameOf(Player), label, garage.label),
            coords = pos, plate = plate,
            ref = { type = 'vehicle', id = plate },
            from = { type = 'citizen', id = cid, name = nameOf(Player) },
            requester = cid,
            meta = {
                purpose = 'garage', garage = garageId, garageLabel = garage.label, owner = cid,
                destination = { x = g.x, y = g.y, z = g.z, radius = Tow.radius },
            },
        })
    end)
    if not ok or type(res) ~= 'table' then
        lastTow[cid] = nil
        return { ok = false, error = 'tow_unavailable' }
    end
    if not res.ok then
        lastTow[cid] = nil
        return { ok = false, error = res.error or 'tow_unavailable' }
    end
    if res.existing then return { ok = false, error = 'tow_exists' } end
    push(src, 'changed')
    return { ok = true, id = res.id, garage = garage.label }
end

--- Cancels the citizen's own tow request (the fee comes back through pf-services).
function PFGarages.AppCancelTow(src, payload)
    local Player = playerOf(src)
    if not Player then return { ok = false, error = 'no_player' } end
    local plate = cleanPlate(payload and payload.plate)
    if not plate then return { ok = false, error = 'bad_plate' } end
    local req = openTow(plate)
    if not req or req.requester ~= Player.PlayerData.citizenid then return { ok = false, error = 'not_found' } end
    local ok, res = pcall(function() return exports['pf-services']:CancelRequest(src, req.id, 'owner_cancelled') end)
    if not ok or type(res) ~= 'table' then return { ok = false, error = 'tow_unavailable' } end
    if res.ok then push(src, 'changed') end
    return res
end

-- A garage tow this resource asked for was completed: the delivered car is parked in that garage.
-- The request is read back from pf-services (the event payload is not trusted on its own), and the
-- car must still be out, belong to the same owner and stand at the garage.
function PFGarages.OnTowCompleted(reqId)
    if not started('pf-services') then return false end
    local ok, req = pcall(function() return exports['pf-services']:GetRequest(reqId) end)
    if not ok or type(req) ~= 'table' or req.kind ~= 'tow.recovery' or req.status ~= 'completed' then return false end
    local meta = req.meta or {}
    if meta.purpose ~= 'garage' or type(meta.garage) ~= 'string' or type(meta.owner) ~= 'string' then return false end
    local plate = cleanPlate(req.plate)
    local garage = Config.Garages[meta.garage]
    if not plate or not garage or not garage.takeVehicle then return false end
    local row = ownRow(meta.owner, plate)
    if not row or tonumber(row.state) ~= 0 or (tonumber(row.depotprice) or 0) > 0 then return false end
    local veh = PFGarages.FindVehicle(plate)
    if not veh or not DoesEntityExist(veh) then return false end
    local pos, g = GetEntityCoords(veh), garage.takeVehicle
    if #(vector3(pos.x, pos.y, pos.z) - vector3(g.x, g.y, g.z)) > Tow.radius + 15.0 then return false end
    local engine = GetVehicleEngineHealth and tonumber(GetVehicleEngineHealth(veh)) or nil
    local body = GetVehicleBodyHealth and tonumber(GetVehicleBodyHealth(veh)) or nil
    local n = MySQL.update.await('UPDATE player_vehicles SET state = 1, garage = ?, engine = COALESCE(?, engine), body = COALESCE(?, body) WHERE plate = ? AND citizenid = ? AND state = 0 AND depotprice = 0',
        { meta.garage, engine and math.max(0, math.min(1000, engine)) or nil, body and math.max(0, math.min(1000, body)) or nil, plate, meta.owner })
    if (tonumber(n) or 0) < 1 then return false end
    DeleteEntity(veh)
    PFGarages.ForgetOutside(plate)
    pushCitizen(meta.owner, 'changed')
    local owner = exports['pfm-core']:GetPlayerByCitizenId(meta.owner)
    if owner then
        TriggerClientEvent('QBCore:Notify', owner.PlayerData.source, ('Your %s was towed to %s and parked there.'):format(plate, garage.label or meta.garage), 'success')
    end
    return true
end

-- Server-only event of pf-services (not a net event).
AddEventHandler('pf-services:requestChanged', function(req, status)
    if status ~= 'completed' or type(req) ~= 'table' or req.kind ~= 'tow.recovery' then return end
    if type(req.meta) ~= 'table' or req.meta.purpose ~= 'garage' then return end
    PFGarages.OnTowCompleted(tonumber(req.id))
end)

-- ── registration ────────────────────────────────────────────────────────────────────────────────

function PFGarages.RegisterApps()
    if not started('pf-devices') then return end
    local devices = exports['pf-devices']
    devices:RegisterApp({
        id = APP, name = 'Garages', icon = '🚗', entry = 'html/apps/garages.js', styles = { 'html/apps/garages.css' },
        devices = { 'tablet', 'computer' }, category = 'apps', order = 20, access = { anyone = true },
        window = { width = 880, height = 620 },
        description = 'Your vehicles: where they are, impound fees and tows',
    })
    devices:RegisterAppHandlers(APP, {
        list = function(src) return PFGarages.AppList(src) end,
        locate = function(src, p) return PFGarages.AppLocate(src, p) end,
        payDepot = function(src, p) return PFGarages.AppPayDepot(src, p) end,
        requestTow = function(src, p) return PFGarages.AppRequestTow(src, p) end,
        cancelTow = function(src, p) return PFGarages.AppCancelTow(src, p) end,
    })
end

AddEventHandler('pf-devices:server:ready', function() PFGarages.RegisterApps() end)
