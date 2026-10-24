local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions', 'Commands' })
local StockedTrunks = {}
local LastStock = {}

RegisterNetEvent('qb-newsjob:server:addVehicleItems', function(plate)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or Player.PlayerData.job.name ~= 'reporter' then return end
    if type(plate) ~= 'string' or plate == '' then return end
    if not exports['pfm-vehiclekeys']:HasKeys(src, plate) then return end

    -- Each plate gets stocked once; also rate-limit per player
    if StockedTrunks[plate] then return end
    local now = os.time()
    if LastStock[src] and (now - LastStock[src]) < 10 then return end

    -- Must be near the news vehicle spawn points to stock a fresh trunk
    local pCoords = GetEntityCoords(GetPlayerPed(src))
    local vehSpawn = Config.Locations['vehicle'].coords
    local heliSpawn = Config.Locations['heli'].coords
    if #(pCoords - vector3(vehSpawn.x, vehSpawn.y, vehSpawn.z)) > 30.0 and #(pCoords - vector3(heliSpawn.x, heliSpawn.y, heliSpawn.z)) > 30.0 then return end

    StockedTrunks[plate] = true
    LastStock[src] = now

    exports['pfm-inventory']:CreateInventory('trunk-' .. plate)

    for slot, item in pairs(Config.VehicleItems) do
        exports['pfm-inventory']:AddItem('trunk-' .. plate, item.name, item.amount, slot, item.info, 'qb-newsjob:vehicleItems')
    end
end)

AddEventHandler('playerDropped', function()
    LastStock[source] = nil
end)

if Config.UseableItems then
    QBCore.Functions.CreateUseableItem('newscam', function(source)
        local Player = exports['pfm-core']:GetPlayer(source)
        if not Player or Player.PlayerData.job.name ~= 'reporter' then return end

        TriggerClientEvent('Cam:ToggleCam', source)
    end)

    QBCore.Functions.CreateUseableItem('newsmic', function(source)
        local Player = exports['pfm-core']:GetPlayer(source)
        if not Player or Player.PlayerData.job.name ~= 'reporter' then return end

        TriggerClientEvent('Mic:ToggleMic', source)
    end)

    QBCore.Functions.CreateUseableItem('newsbmic', function(source)
        local Player = exports['pfm-core']:GetPlayer(source)
        if not Player or Player.PlayerData.job.name ~= 'reporter' then return end

        TriggerClientEvent('Mic:ToggleBMic', source)
    end)
else
    QBCore.Commands.Add('newscam', 'Grab a news camera', {}, false, function(source, _)
        local Player = exports['pfm-core']:GetPlayer(source)
        if not Player or Player.PlayerData.job.name ~= 'reporter' then return end

        TriggerClientEvent('Cam:ToggleCam', source)
    end)

    QBCore.Commands.Add('newsmic', 'Grab a news microphone', {}, false, function(source, _)
        local Player = exports['pfm-core']:GetPlayer(source)
        if not Player or Player.PlayerData.job.name ~= 'reporter' then return end

        TriggerClientEvent('Mic:ToggleMic', source)
    end)

    QBCore.Commands.Add('newsbmic', 'Grab a Boom microphone', {}, false, function(source, _)
        local Player = exports['pfm-core']:GetPlayer(source)
        if not Player or Player.PlayerData.job.name ~= 'reporter' then return end

        TriggerClientEvent('Mic:ToggleBMic', source)
    end)
end
