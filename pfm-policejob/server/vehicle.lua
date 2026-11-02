local Plates = {}

local function IsVehicleOwned(plate)
    local result = MySQL.scalar.await('SELECT plate FROM player_vehicles WHERE plate = ?', { plate })
    return result
end

local function IsOnDutyLeo(Player)
    return Player and Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty
end

local function TrimPlate(plate)
    return (tostring(plate or ''):gsub('^%s+', ''):gsub('%s+$', ''))
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

-- Callbacks

QBCore.Functions.CreateCallback('police:GetImpoundedVehicles', function(source, cb)
    local vehicles = {}
    -- the impound list (owners' citizenids and licenses) is for officers only
    if not IsOnDutyLeo(exports['pfm-core']:GetPlayer(source)) then return cb(vehicles) end
    MySQL.query('SELECT * FROM player_vehicles WHERE state = ?', { 2 }, function(result)
        if result[1] then
            vehicles = result
        end
        cb(vehicles)
    end)
end)

QBCore.Functions.CreateCallback('police:server:IsPlateFlagged', function(_, cb, plate)
    local retval = false
    if Plates and Plates[plate] then
        if Plates[plate].isflagged then
            retval = true
        end
    end
    cb(retval)
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
-- opts: { fullImpound, price, body, engine, fuel, officer = citizenid }
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
-- impounded the car on the spot while the order was still open.
local AppliedOrders = {}

local function ApplyImpoundOrder(plate, opts, requestId)
    requestId = tonumber(requestId)
    if requestId then
        if AppliedOrders[requestId] then return false end
        AppliedOrders[requestId] = true
    end
    return ApplyImpound(plate, opts)
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

RegisterNetEvent('police:server:Impound', function(plate, fullImpound, price, body, engine, fuel)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or Player.PlayerData.job.type ~= 'leo' or not Player.PlayerData.job.onduty then return end
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
    local opts = { fullImpound = fullImpound == true, price = price, body = body, engine = engine, fuel = fuel, fuelCap = fuelCap, officer = Player.PlayerData.citizenid }

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
            TriggerClientEvent('police:client:ImpoundDecision', src, plate, 'tow')
            TriggerClientEvent('QBCore:Notify', src, 'Tow ordered: leave the vehicle, a tow truck is coming', 'success')
            return
        end
    end

    CloseOpenImpoundOrder(plate)
    ApplyImpound(plate, opts)
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
-- fuel it liked. The client then applies the stored mods and damage.
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
    releasing[plate] = nil
    TriggerClientEvent('QBCore:Notify', src, Lang:t('success.impound_vehicle_removed'), 'success')
    cb(NetworkGetNetworkIdFromEntity(veh), { plate = plate, mods = row.mods, body = tonumber(row.body), engine = tonumber(row.engine) })
end)

RegisterNetEvent('police:server:FlaggedPlateTriggered', function(coords, plate)
    local src = source
    -- sent by the driver of a flagged car passing a radar: the plate must really be flagged and the
    -- alert goes to the radar the driver is at (any text and position used to be relayed to police)
    if type(plate) ~= 'string' or #plate > 16 then return end
    if not (Plates[plate:upper()] and Plates[plate:upper()].isflagged) then return end
    local pos = GetEntityCoords(GetPlayerPed(src))
    coords = nil
    for _, radar in ipairs(Config.Radars or {}) do
        if #(pos - radar) < 40.0 then coords = radar break end
    end
    if not coords then return end
    for _, Player in pairs(QBCore.Functions.GetQBPlayers()) do
        if Player then
            if (Player.PlayerData.job.name == 'police' and Player.PlayerData.job.onduty) then
                local veh_plate = plate:upper()
                local message = Lang:t('info.flagged_vehicle_radar', { plate = veh_plate })
                TriggerClientEvent('police:client:policeAlert', Player.PlayerData.source, coords, message)
            end
        end
    end
end)

-- Commands

QBCore.Commands.Add('flagplate', Lang:t('commands.flagplate'), { { name = 'plate', help = Lang:t('info.plate_number') }, { name = 'reason', help = Lang:t('info.flag_reason') } }, true, function(source, args)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        local reason = {}
        for i = 2, #args, 1 do
            reason[#reason + 1] = args[i]
        end
        Plates[args[1]:upper()] = {
            isflagged = true,
            reason = table.concat(reason, ' ')
        }
        TriggerClientEvent('QBCore:Notify', src, Lang:t('info.vehicle_flagged', { vehicle = args[1]:upper(), reason = table.concat(reason, ' ') }))
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

QBCore.Commands.Add('unflagplate', Lang:t('commands.unflagplate'), { { name = 'plate', help = Lang:t('info.plate_number') } }, true, function(source, args)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        if Plates and Plates[args[1]:upper()] then
            if Plates[args[1]:upper()].isflagged then
                Plates[args[1]:upper()].isflagged = false
                TriggerClientEvent('QBCore:Notify', src, Lang:t('info.unflag_vehicle', { vehicle = args[1]:upper() }))
            else
                TriggerClientEvent('QBCore:Notify', src, Lang:t('error.vehicle_not_flag'), 'error')
            end
        else
            TriggerClientEvent('QBCore:Notify', src, Lang:t('error.vehicle_not_flag'), 'error')
        end
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

QBCore.Commands.Add('plateinfo', Lang:t('commands.plateinfo'), { { name = 'plate', help = Lang:t('info.plate_number') } }, true, function(source, args)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        if Plates and Plates[args[1]:upper()] then
            if Plates[args[1]:upper()].isflagged then
                TriggerClientEvent('QBCore:Notify', src, Lang:t('success.vehicle_flagged', { plate = args[1]:upper(), reason = Plates[args[1]:upper()].reason }), 'success')
            else
                TriggerClientEvent('QBCore:Notify', src, Lang:t('error.vehicle_not_flag'), 'error')
            end
        else
            TriggerClientEvent('QBCore:Notify', src, Lang:t('error.vehicle_not_flag'), 'error')
        end
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)
