local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions', 'Commands' })
local trunkBusy = {}

function IsCloseToTarget(source, target)
    if not DoesPlayerExist(target) then return false end
    return #(GetEntityCoords(GetPlayerPed(source)) - GetEntityCoords(GetPlayerPed(target))) < 2.0
end

RegisterNetEvent('qb-radialmenu:trunk:server:Door', function(open, plate, door)
    local src = source
    local ped = GetPlayerPed(src)
    if ped <= 0 then return end

    local playerCoords = GetEntityCoords(ped)
    if not playerCoords then return end

    local vehicle = GetClosestVehicle(playerCoords.x, playerCoords.y, playerCoords.z, 10.0, 0, 70)
    if vehicle == 0 then return end

    local targetPlate = QBCore.Shared.Trim(plate)
    local closestVehiclePlate = QBCore.Shared.Trim(GetVehicleNumberPlateText(vehicle))
    if not targetPlate or not closestVehiclePlate or targetPlate ~= closestVehiclePlate then return end

    local vehicleCoords = GetEntityCoords(vehicle)
    if not vehicleCoords then return end
    if #(playerCoords - vehicleCoords) > 2.0 then return end

    TriggerClientEvent('qb-radialmenu:trunk:client:Door', -1, plate, door, open)
end)

RegisterNetEvent('qb-trunk:server:setTrunkBusy', function(plate, busy)
    if type(plate) ~= 'string' or #plate > 16 then return end
    trunkBusy[plate] = busy == true or nil
end)

-- Only a player who is already cuffed, dead or down can be put in a trunk (as for being carried off
-- with police:server:KidnapPlayer); any nearby player could be forced in before.
RegisterNetEvent('qb-trunk:server:KidnapTrunk', function(target, closestVehicle)
    local src = source
    target = tonumber(target)
    if not target or target == src or not IsCloseToTarget(src, target) then return end
    local Target = exports['pfm-core']:GetPlayer(target)
    if not Target then return end
    local meta = Target.PlayerData.metadata or {}
    if not (meta['ishandcuffed'] or meta['isdead'] or meta['inlaststand']) then return end
    TriggerClientEvent('qb-trunk:client:KidnapGetIn', target, closestVehicle)
end)

QBCore.Functions.CreateCallback('qb-trunk:server:getTrunkBusy', function(_, cb, plate)
    if trunkBusy[plate] then
        cb(true)
        return
    end
    cb(false)
end)

QBCore.Commands.Add('getintrunk', Lang:t('general.getintrunk_command_desc'), {}, false, function(source)
    TriggerClientEvent('qb-trunk:client:GetIn', source)
end)

QBCore.Commands.Add('putintrunk', Lang:t('general.putintrunk_command_desc'), {}, false, function(source)
    TriggerClientEvent('qb-trunk:server:KidnapTrunk', source)
end)
