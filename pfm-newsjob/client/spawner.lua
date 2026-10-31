-- Asks the server to put the issued vehicle away; the server checks it is at the garage, deletes it
-- and tells us (pfm-newsjob:client:vehicleStored).
function StoreCurrentVehicle()
    local veh = GetVehiclePedIsIn(PlayerPedId(), false)
    if veh == 0 then return end

    local plate = QBCore.Functions.GetPlate(veh)
    if not CurrentPlate[plate] then return end

    TriggerServerEvent('pfm-newsjob:server:vehicleStored')
end

RegisterNetEvent('pfm-newsjob:client:vehicleStored', function(plate)
    if type(plate) ~= 'string' then return end
    TriggerServerEvent('qb-vehiclekeys:server:RemoveVehicleKeys', plate)
    CurrentPlate[plate] = nil
end)

-- The server checks the request, spawns the vehicle, sets its plate and stocks the van's trunk; the
-- client only asks, then sets fuel, keys and livery on the vehicle it is given.
local function RequestReporterVehicle(args)
    TriggerServerEvent('pfm-newsjob:server:requestVehicle', args.location, args.vehicle)
end

RegisterNetEvent('pfm-newsjob:client:spawnVehicle', function(location, model, plate, modLivery, netId)
    local garage = Config.Locations[location]
    if not garage or type(model) ~= 'string' or type(plate) ~= 'string' or type(netId) ~= 'number' then return end
    local tries = 0
    while not NetworkDoesNetworkIdExist(netId) and tries < 100 do
        Wait(50)
        tries = tries + 1
    end
    if not NetworkDoesNetworkIdExist(netId) then return end
    local veh = NetToVeh(netId)
    if veh == 0 then return end
    SetVehicleNumberPlateText(veh, plate)
    CurrentPlate[plate] = true
    SetEntityHeading(veh, garage.coords.w)
    exports['LegacyFuel']:SetFuel(veh, 100.0)
    if GetVehiclePedIsIn(PlayerPedId(), false) ~= veh then TaskWarpPedIntoVehicle(PlayerPedId(), veh, -1) end
    TriggerEvent('vehiclekeys:client:SetOwner', plate)
    SetVehicleEngineOn(veh, true, true, false)
    if modLivery then
        local livery = GetVehicleLiveryCount(veh) < 0 and modLivery - 1 or modLivery
        QBCore.Functions.SetVehicleProperties(veh, { modLivery = livery })
    end
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
