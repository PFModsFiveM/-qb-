local newExports = function(funcName, func)
    AddEventHandler(('__cfx_export_LegacyFuel_%s'):format(funcName), function(setCB)
        setCB(func)
    end)
    exports(funcName, func)
end

-- The shared fuel level ('qb-fuel' on the vehicle) is written by the server only
-- (sv_stateBagStrictMode): the driver's client reports its level and the server only lets it go
-- down, as fast as driving burns fuel (a new car takes its driver's first report); refuelling
-- raises it on the server (pump, jerry can).
local reportFuel = function(vehicle, fuel)
    if not Config.SyncFuelBetweenPlayers or not NetworkGetEntityIsNetworked(vehicle) then return end
    TriggerServerEvent('qb-fuel:server:syncFuel', NetworkGetNetworkIdFromEntity(vehicle), fuel + 0.0)
end

local SetFuel = function(vehicle, fuel)
    if not DoesEntityExist(vehicle) or not IsEntityAVehicle(vehicle) then return end
    if fuel < 0 then fuel = 0 end
    if fuel > 100 then fuel = 100 end

    NetworkRequestControlOfEntity(vehicle)
    SetVehicleFuelLevel(vehicle, fuel + 0.0)
    reportFuel(vehicle, fuel)
    -- a car spawned a moment ago may not be known to the server yet: report once more shortly
    SetTimeout(1500, function()
        if DoesEntityExist(vehicle) then reportFuel(vehicle, GetVehicleFuelLevel(vehicle)) end
    end)
end

newExports('SetFuel', SetFuel)

local GetFuel = function(vehicle)
    if not DoesEntityExist(vehicle) or not IsEntityAVehicle(vehicle) then return end

    return GetVehicleFuelLevel(vehicle)
end

newExports('GetFuel', GetFuel)

if Config.SyncFuelBetweenPlayers then
    -- last shared level seen per car: a write at or below it is the server answering a driver's
    -- report, a write above it is a refuel
    local lastShared, tracked = {}, 0

    local forgetRemovedVehicles = function()
        local kept, n = {}, 0
        for entity, level in pairs(lastShared) do
            if DoesEntityExist(entity) then kept[entity], n = level, n + 1 end
        end
        lastShared, tracked = kept, n
    end

    AddStateBagChangeHandler('qb-fuel', nil, function(bagName, _, value)
        local entity = GetEntityFromStateBagName(bagName)
        if entity == 0 then return end
        if not DoesEntityExist(entity) or not IsEntityAVehicle(entity) then return end
        value = tonumber(value)
        if not value then return end
        local before = lastShared[entity]
        lastShared[entity] = value
        if before == nil then
            tracked = tracked + 1
            if tracked > 256 then forgetRemovedVehicles() end
        end
        -- The car this client drives burns fuel here. When the server caps a report (it never
        -- lowers the level faster than Config.MaxFuelBurnPerSecond), its answer sits above our
        -- real level: keep ours and let the next reports bring the shared level down to it.
        if before and value <= before and GetPedInVehicleSeat(entity, -1) == PlayerPedId()
            and GetVehicleFuelLevel(entity) < value then
            return
        end
        SetVehicleFuelLevel(entity, value + 0.0)
    end)

    AddEventHandler('gameEventTriggered', function(event, data)
        if event ~= 'CEventNetworkPlayerEnteredVehicle' then return end
        local player, vehicle = data[1], data[2]
        local playerPed = PlayerPedId()
        if player ~= 128 or GetPedInVehicleSeat(vehicle, -1) ~= playerPed then return end

        CreateThread(function()
            while DoesEntityExist(vehicle) and GetPedInVehicleSeat(vehicle, -1) == playerPed do
                if IsVehicleEngineOn(vehicle) then
                    reportFuel(vehicle, GetVehicleFuelLevel(vehicle))
                end
                Wait(Config.FuelSyncTime * 1000)
            end
        end)
    end)

    AddEventHandler('onResourceStart', function(resourceName)
        if resourceName ~= GetCurrentResourceName() then return end

        local playerPed = PlayerPedId()
        local vehicle = GetVehiclePedIsIn(playerPed, false)
        if vehicle == 0 or GetPedInVehicleSeat(vehicle, -1) ~= playerPed then return end

        CreateThread(function()
            while DoesEntityExist(vehicle) and GetPedInVehicleSeat(vehicle, -1) == playerPed do
                if IsVehicleEngineOn(vehicle) then
                    reportFuel(vehicle, GetVehicleFuelLevel(vehicle))
                end
                Wait(Config.FuelSyncTime * 1000)
            end
        end)
    end)
end
