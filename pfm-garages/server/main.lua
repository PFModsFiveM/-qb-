local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions' })
local sharedVehicles = exports['pfm-core']:GetShared('Vehicles')
local OutsideVehicles = {}

-- Handler

AddEventHandler('onResourceStart', function(resource)
    if resource == GetCurrentResourceName() then
        Wait(100)
        if Config['AutoRespawn'] then
            MySQL.update('UPDATE player_vehicles SET state = 1 WHERE state = 0', {})
        else
            MySQL.update('UPDATE player_vehicles SET depotprice = ? WHERE state = 0', { Config.DepotPrice or 500 })
        end
    end
end)

-- Functions

local vehicleClasses = {
    compacts = 0,
    sedans = 1,
    suvs = 2,
    coupes = 3,
    muscle = 4,
    sportsclassics = 5,
    sports = 6,
    super = 7,
    motorcycles = 8,
    offroad = 9,
    industrial = 10,
    utility = 11,
    vans = 12,
    cycles = 13,
    boats = 14,
    helicopters = 15,
    planes = 16,
    service = 17,
    emergency = 18,
    military = 19,
    commercial = 20,
    trains = 21,
    openwheel = 22,
}

-- Returns the owning citizenid for a plate, or nil
local function GetPlateOwner(plate)
    if type(plate) ~= 'string' or plate == '' then return nil end
    return MySQL.scalar.await('SELECT citizenid FROM player_vehicles WHERE plate = ? LIMIT 1', { plate })
end

-- True when the player owns the plate
local function IsPlateOwnedBy(Player, plate)
    if not Player then return false end
    local owner = GetPlateOwner(plate)
    return owner ~= nil and owner == Player.PlayerData.citizenid
end

local function clampNumber(value, min, max, default)
    value = tonumber(value)
    if not value then return default end
    if value < min then return min end
    if value > max then return max end
    return value
end

local function arrayToSet(array)
    local set = {}
    for _, item in ipairs(array) do
        set[item] = true
    end
    return set
end

local function filterVehiclesByCategory(vehicles, category)
    local filtered = {}
    local categorySet = arrayToSet(category)

    for _, vehicle in pairs(vehicles) do
        local vehicleData = sharedVehicles[vehicle.vehicle]
        local vehicleCategoryString = vehicleData and vehicleData.category or 'compacts'
        local vehicleCategoryNumber = vehicleClasses[vehicleCategoryString]

        if vehicleCategoryNumber and categorySet[vehicleCategoryNumber] then
            filtered[#filtered + 1] = vehicle
        end
    end

    return filtered
end

-- Callbacks

QBCore.Functions.CreateCallback('qb-garages:server:getHouseGarage', function(_, cb, house)
    local houseInfo = MySQL.single.await('SELECT * FROM houselocations WHERE name = ?', { house })
    cb(houseInfo)
end)

-- Collects the citizenids of online players in the given job/gang (including the requester)
local function GetGroupMemberCitizenIds(groupKind, groupName)
    local members = {}
    local players = QBCore.Functions.GetQBPlayers()
    for _, p in pairs(players) do
        local data = p and p.PlayerData
        if data then
            local group = groupKind == 'gang' and data.gang or data.job
            if group and group.name == groupName then
                members[#members + 1] = data.citizenid
            end
        end
    end
    return members
end

QBCore.Functions.CreateCallback('qb-garages:server:GetGarageVehicles', function(source, cb, garage, type, category)
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player then return end
    local citizenId = Player.PlayerData.citizenid

    local vehicles
    local garageConfig = Config.Garages[garage]
    local garageType = garageConfig and garageConfig.type or type

    if garageType == 'depot' or type == 'depot' then
        vehicles = MySQL.rawExecute.await('SELECT * FROM player_vehicles WHERE citizenid = ? AND depotprice > 0', { citizenId })
    elseif Config.SharedGarages and garageConfig and (garageType == 'job' or garageType == 'gang') and garageConfig.job then
        -- Shared job/gang garage: list vehicles of every member currently in the job/gang (read-only
        -- for non-owned entries - spawning still requires ownership server-side)
        local playerGroup = garageType == 'gang' and Player.PlayerData.gang or Player.PlayerData.job
        if not playerGroup or playerGroup.name ~= garageConfig.job then
            cb(nil)
            return
        end
        local members = GetGroupMemberCitizenIds(garageType, garageConfig.job)
        local placeholders = {}
        for i = 1, #members do placeholders[i] = '?' end
        vehicles = MySQL.rawExecute.await('SELECT * FROM player_vehicles WHERE citizenid IN (' .. table.concat(placeholders, ',') .. ')', members)
        if vehicles then
            for _, v in pairs(vehicles) do
                v.shared = v.citizenid ~= citizenId
            end
        end
    elseif Config.SharedGarages then
        vehicles = MySQL.rawExecute.await('SELECT * FROM player_vehicles WHERE citizenid = ?', { citizenId })
    else
        vehicles = MySQL.rawExecute.await('SELECT * FROM player_vehicles WHERE citizenid = ? AND garage = ?', { citizenId, garage })
    end
    if not vehicles then
        cb(nil)
        return
    end
    if #vehicles == 0 then
        cb(nil)
        return
    end
    if Config.ClassSystem then
        local filteredVehicles = filterVehiclesByCategory(vehicles, category)
        cb(filteredVehicles)
    else
        cb(vehicles)
    end
end)

-- Backwards Compat
local vehicleTypes = { -- https://docs.fivem.net/natives/?_0xA273060E
    motorcycles = 'bike',
    boats = 'boat',
    helicopters = 'heli',
    planes = 'plane',
    submarines = 'submarine',
    trailer = 'trailer',
    train = 'train'
}

local function GetVehicleTypeByModel(model)
    local vehicleData = sharedVehicles[model]
    if not vehicleData then return 'automobile' end
    local category = vehicleData.category
    local vehicleType = vehicleTypes[category]
    return vehicleType or 'automobile'
end
-- Backwards Compat

-- Spawns a vehicle and returns its network ID and properties.
QBCore.Functions.CreateCallback('qb-garages:server:spawnvehicle', function(source, cb, plate, _, coords)
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player then
        cb(nil, nil, nil)
        return
    end
    local ownedVehicle = MySQL.single.await('SELECT vehicle, mods FROM player_vehicles WHERE plate = ? AND citizenid = ? LIMIT 1', { plate, Player.PlayerData.citizenid })
    if not ownedVehicle then
        cb(nil, nil, nil)
        return
    end
    local vehType = sharedVehicles[ownedVehicle.vehicle] and sharedVehicles[ownedVehicle.vehicle].type or GetVehicleTypeByModel(ownedVehicle.vehicle)
    local hash = type(ownedVehicle.vehicle) == 'number' and ownedVehicle.vehicle or type(ownedVehicle.vehicle) == 'string' and GetHashKey(ownedVehicle.vehicle) or nil
    if not hash then
        cb(nil, nil, nil)
        return
    end
    local veh = CreateVehicleServerSetter(hash, vehType, coords.x, coords.y, coords.z, coords.w)
    local netId = NetworkGetNetworkIdFromEntity(veh)
    SetVehicleNumberPlateText(veh, plate)
    local vehProps = {}
    if ownedVehicle.mods then vehProps = json.decode(ownedVehicle.mods) end
    OutsideVehicles[plate] = { netID = netId, entity = veh }
    cb(netId, vehProps, plate)
end)

-- Checks if a vehicle can be spawned based on its type and location.
QBCore.Functions.CreateCallback('qb-garages:server:IsSpawnOk', function(_, cb, plate, type)
    if OutsideVehicles[plate] and DoesEntityExist(OutsideVehicles[plate].entity) then
        cb(false)
        return
    end
    cb(true)
end)

QBCore.Functions.CreateCallback('qb-garages:server:canDeposit', function(source, cb, plate, type, garage, state)
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player then
        cb(false)
        return
    end
    local isOwned = GetPlateOwner(plate)
    if isOwned ~= Player.PlayerData.citizenid then
        cb(false)
        return
    end
    if type == 'house' and not exports['pfm-houses']:hasKey(Player.PlayerData.license, Player.PlayerData.citizenid, Config.Garages[garage].houseName) then
        cb(false)
        return
    end
    if state == 1 then
        MySQL.update('UPDATE player_vehicles SET state = ?, garage = ? WHERE plate = ?', { state, garage, plate })
        cb(true)
    else
        cb(false)
    end
end)

-- Events

RegisterNetEvent('qb-garages:server:updateVehicleStats', function(plate, fuel, engine, body)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if type(plate) ~= 'string' then return end
    fuel = clampNumber(fuel, 0, 100, 100)
    engine = clampNumber(engine, 0, 1000, 1000)
    body = clampNumber(body, 0, 1000, 1000)
    MySQL.update('UPDATE player_vehicles SET fuel = ?, engine = ?, body = ? WHERE plate = ? AND citizenid = ?', { fuel, engine, body, plate, Player.PlayerData.citizenid })
end)

local allowedStates = { [0] = true, [1] = true, [2] = true }
RegisterNetEvent('qb-garages:server:updateVehicleState', function(state, plate)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    state = tonumber(state)
    if not state or not allowedStates[state] or type(plate) ~= 'string' then return end
    MySQL.update('UPDATE player_vehicles SET state = ?, depotprice = ? WHERE plate = ? AND citizenid = ?', { state, 0, plate, Player.PlayerData.citizenid })
end)

RegisterNetEvent('qb-garages:server:UpdateOutsideVehicle', function(plate, vehicleNetID)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or not IsPlateOwnedBy(Player, plate) then return end
    if vehicleNetID then
        OutsideVehicles[plate] = {
            netID = vehicleNetID,
            entity = NetworkGetEntityFromNetworkId(vehicleNetID)
        }
    else
        OutsideVehicles[plate] = nil
    end
end)

RegisterNetEvent('qb-garages:server:trackVehicle', function(plate)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or not IsPlateOwnedBy(Player, plate) then return end
    local vehicleData = OutsideVehicles[plate]
    if vehicleData and DoesEntityExist(vehicleData.entity) then
        TriggerClientEvent('qb-garages:client:trackVehicle', src, GetEntityCoords(vehicleData.entity))
        TriggerClientEvent('QBCore:Notify', src, Lang:t('success.vehicle_tracked'), 'success')
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.vehicle_not_tracked'), 'error')
    end
end)

RegisterNetEvent('qb-garages:server:PayDepotPrice', function(data)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or type(data) ~= 'table' or type(data.plate) ~= 'string' then return end
    local cashBalance = Player.PlayerData.money['cash']
    local bankBalance = Player.PlayerData.money['bank']
    -- Price is read from the database for the player's own vehicle only; the client-sent amount is ignored
    MySQL.scalar('SELECT depotprice FROM player_vehicles WHERE plate = ? AND citizenid = ?', { data.plate, Player.PlayerData.citizenid }, function(result)
        if result then
            local depotPrice = math.floor(tonumber(result) or 0)
            if depotPrice <= 0 then
                TriggerClientEvent('qb-garages:client:takeOutGarage', src, data)
                return
            end

            local function creditCityTreasury(amount)
                if GetResourceState('pf-government') ~= 'started' then return end
                pcall(function()
                    exports['pf-government']:DepositToTreasury(amount, 'impound', ('Impound release fee (%s)'):format(data.plate))
                end)
            end

            if cashBalance >= depotPrice then
                Player.RemoveMoney('cash', depotPrice, 'paid-depot')
                creditCityTreasury(depotPrice)
                TriggerClientEvent('qb-garages:client:takeOutGarage', src, data)
            elseif bankBalance >= depotPrice then
                Player.RemoveMoney('bank', depotPrice, 'paid-depot')
                creditCityTreasury(depotPrice)
                TriggerClientEvent('qb-garages:client:takeOutGarage', src, data)
            else
                TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_enough'), 'error')
            end
        end
    end)
end)

-- House Garages

RegisterNetEvent('qb-garages:server:syncGarage', function(updatedGarages)
    if type(updatedGarages) ~= 'table' then return end
    -- Only accept new house-garage entries from clients; never let a client overwrite
    -- or remove the static config garages (public/job/gang/depot)
    for name, garage in pairs(updatedGarages) do
        if type(garage) == 'table' and garage.type == 'house' and (not Config.Garages[name] or Config.Garages[name].type == 'house') then
            Config.Garages[name] = garage
        end
    end
end)

--Call from qb-phone

QBCore.Functions.CreateCallback('qb-garages:server:GetPlayerVehicles', function(source, cb)
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player then return cb(nil) end
    local Vehicles = {}

    MySQL.rawExecute('SELECT * FROM player_vehicles WHERE citizenid = ?', { Player.PlayerData.citizenid }, function(result)
        if result[1] then
            for _, v in pairs(result) do
                local VehicleData = sharedVehicles[v.vehicle]

                local VehicleGarage = Lang:t('error.no_garage')
                if v.garage ~= nil then
                    if Config.Garages[v.garage] ~= nil then
                        VehicleGarage = Config.Garages[v.garage].label
                    else
                        VehicleGarage = Lang:t('info.house')
                    end
                end

                local stateTranslation
                if v.state == 0 then
                    stateTranslation = Lang:t('status.out')
                elseif v.state == 1 then
                    stateTranslation = Lang:t('status.garaged')
                elseif v.state == 2 then
                    stateTranslation = Lang:t('status.impound')
                end

                local fullname
                if VehicleData and VehicleData['brand'] then
                    fullname = VehicleData['brand'] .. ' ' .. VehicleData['name']
                else
                    fullname = VehicleData and VehicleData['name'] or 'Unknown Vehicle'
                end

                Vehicles[#Vehicles + 1] = {
                    fullname = fullname,
                    brand = VehicleData and VehicleData['brand'] or '',
                    model = VehicleData and VehicleData['name'] or '',
                    plate = v.plate,
                    garage = VehicleGarage,
                    state = stateTranslation,
                    fuel = v.fuel,
                    engine = v.engine,
                    body = v.body
                }
            end
            cb(Vehicles)
        else
            cb(nil)
        end
    end)
end)

local function getAllGarages()
    local garages = {}
    for k, v in pairs(Config.Garages) do
        garages[#garages + 1] = {
            name = k,
            label = v.label,
            type = v.type,
            takeVehicle = v.takeVehicle,
            putVehicle = v.putVehicle,
            spawnPoint = v.spawnPoint,
            showBlip = v.showBlip,
            blipName = v.blipName,
            blipNumber = v.blipNumber,
            blipColor = v.blipColor,
            vehicle = v.vehicle
        }
    end
    return garages
end

exports('getAllGarages', getAllGarages)
