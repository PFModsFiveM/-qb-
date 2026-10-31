function StoreCurrentVehicle()
    local veh = GetVehiclePedIsIn(PlayerPedId(), false)
    if veh == 0 then return end

    local plate = QBCore.Functions.GetPlate(veh)
    if not CurrentPlate[plate] then return end

    TriggerServerEvent('qb-vehiclekeys:server:RemoveVehicleKeys', plate)
    CurrentPlate[plate] = nil
    DeleteVehicle(veh)
    TriggerServerEvent('pfm-newsjob:server:vehicleStored')
end

-- The server picks the plate and grants a one-time spawn ticket for the model; the client only spawns it.
local function RequestReporterVehicle(args)
    TriggerServerEvent('pfm-newsjob:server:requestVehicle', args.location, args.vehicle)
end

RegisterNetEvent('pfm-newsjob:client:spawnVehicle', function(location, model, plate, modLivery)
    local garage = Config.Locations[location]
    if not garage or type(model) ~= 'string' or type(plate) ~= 'string' then return end
    local coords = garage.coords
    QBCore.Functions.TriggerCallback('QBCore:Server:SpawnVehicle', function(netId)
        if not netId then return end
        local veh = NetToVeh(netId)
        SetVehicleNumberPlateText(veh, plate)
        CurrentPlate[plate] = true
        SetEntityHeading(veh, coords.w)
        exports['LegacyFuel']:SetFuel(veh, 100.0)
        TaskWarpPedIntoVehicle(PlayerPedId(), veh, -1)
        TriggerEvent('vehiclekeys:client:SetOwner', plate)
        SetVehicleEngineOn(veh, true, true, false)
        if modLivery then
            local livery = GetVehicleLiveryCount(veh) < 0 and modLivery - 1 or modLivery
            QBCore.Functions.SetVehicleProperties(veh, { modLivery = livery })
        end
        if Config.UseableItems and location == 'vehicle' then
            Wait(500)
            TriggerServerEvent('qb-newsjob:server:addVehicleItems', plate)
        end
    end, model, coords, true)
end)

function MenuGarage(location)
    local currentGarrage = Config.Locations[location]
    if not currentGarrage or not currentGarrage.vehicles then return end

    local grade = QBCore.Functions.GetPlayerData().job.grade.level
    local menu = { { header = Lang:t('text.' .. location), isMenuHeader = true } }

    local best
    for g in pairs(currentGarrage.vehicles) do
        local n = tonumber(g)
        if n and n <= grade and (not best or n > best) then best = n end
    end
    for veh, vehData in pairs(best and currentGarrage.vehicles[best] or {}) do
        menu[#menu + 1] = {
            header = vehData.label,
            txt = '',
            params = {
                event = RequestReporterVehicle,
                args = { vehicle = veh, location = location, modLivery = vehData.modLivery },
                isAction = true
            }
        }
    end

    menu[#menu + 1] = {
        header = Lang:t('text.close_menu'),
        txt = '',
        params = { event = 'qb-menu:client:closeMenu' }
    }

    exports['pfm-menu']:openMenu(menu)
end
