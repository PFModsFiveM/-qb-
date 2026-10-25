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
    if IsVehicleOwned(plate) then
        if not fullImpound then
            MySQL.query('UPDATE player_vehicles SET state = ?, depotprice = ?, body = ?, engine = ?, fuel = ? WHERE plate = ?', { 0, price, body, engine, fuel, plate })
            TriggerClientEvent('QBCore:Notify', src, Lang:t('info.vehicle_taken_depot', { price = price }))
        else
            MySQL.query('UPDATE player_vehicles SET state = ?, body = ?, engine = ?, fuel = ? WHERE plate = ?', { 2, body, engine, fuel, plate })
            TriggerClientEvent('QBCore:Notify', src, Lang:t('info.vehicle_seized'))
        end
    end
end)

RegisterNetEvent('police:server:TakeOutImpound', function(plate, garage)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or Player.PlayerData.job.type ~= 'leo' or not Player.PlayerData.job.onduty then return end
    if type(plate) ~= 'string' or not Config.Locations['impound'][garage] then return end
    local playerPed = GetPlayerPed(src)
    local playerCoords = GetEntityCoords(playerPed)
    local targetCoords = Config.Locations['impound'][garage]
    if #(playerCoords - targetCoords) > 10.0 then return DropPlayer(src, 'Attempted exploit abuse') end
    MySQL.update('UPDATE player_vehicles SET state = ? WHERE plate = ? AND state = ?', { 0, plate, 2 })
    TriggerClientEvent('QBCore:Notify', src, Lang:t('success.impound_vehicle_removed'), 'success')
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
