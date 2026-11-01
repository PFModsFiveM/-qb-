local vehicleClasses = {
    [0] = true,
    [1] = true,
    [2] = true,
    [3] = true,
    [4] = true,
    [5] = true,
    [6] = true,
    [7] = true,
    [8] = true,
    [9] = true,
    [10] = true,
    [11] = true,
    [12] = true,
    [13] = false,
    [14] = false,
    [15] = false,
    [16] = false,
    [17] = true,
    [18] = true,
    [19] = true,
    [20] = true,
    [21] = false
}

-- The HUD (pf-hud) shows the cruise indicator from this event. It is sent once when cruise turns
-- on and once when it turns off, whatever ends it (brake, slowing down, leaving the seat).
local cruiseActive = false

local function setCruise(active)
    if cruiseActive == active then return end
    cruiseActive = active
    TriggerEvent('seatbelt:client:ToggleCruise', active)
end

local function triggerCruiseControl(veh)
    if cruiseActive then return end -- one cruise loop at a time; Y while cruising sets the speed
    local ped = PlayerPedId()
    if IsPedInAnyVehicle(ped, false) then
        local speed = GetEntitySpeed(veh)
        if speed > 0 and GetVehicleCurrentGear(veh) > 0 then
            speed = GetEntitySpeed(veh)
            -- checked once, when cruise is switched on (the original behaviour): switched on while
            -- going straight, it holds the speed through turns; switched on while steering or on the
            -- handbrake, it does not push the car and only the brake ends it
            local isTurningOrHandbraking = IsControlPressed(2, 76) or IsControlPressed(2, 63) or IsControlPressed(2, 64)
            if GetResourceState('pfm-fuel') == 'started' then
                if exports['pfm-fuel']:GetFuel(veh) <= 10 then
                    QBCore.Functions.Notify(Lang:t('cruise.not_Enough_Fuel'), 'error')
                    return
                end
            end
            if GetResourceState('LegacyFuel') == 'started' then
                if exports['LegacyFuel']:GetFuel(veh) <= 10 then
                    QBCore.Functions.Notify(Lang:t('cruise.not_Enough_Fuel'), 'error')
                    return
                end
            end
            setCruise(true)
            QBCore.Functions.Notify(Lang:t('cruise.activated'))
            CreateThread(function()
                local switchedOff = false
                while speed > 0 and DoesEntityExist(veh) and GetPedInVehicleSeat(veh, -1) == ped do
                    Wait(0)
                    if not isTurningOrHandbraking and GetEntitySpeed(veh) < speed - 1.5 then
                        switchedOff = true
                        break
                    end

                    if not isTurningOrHandbraking and IsVehicleOnAllWheels(veh) and GetEntitySpeed(veh) < speed then
                        SetVehicleForwardSpeed(veh, speed)
                    end

                    if IsControlJustPressed(1, 246) then
                        speed = GetEntitySpeed(veh)
                    end

                    if IsControlJustPressed(2, 72) then
                        switchedOff = true
                        break
                    end
                end
                setCruise(false)
                if switchedOff then
                    QBCore.Functions.Notify(Lang:t('cruise.deactivated'), 'error')
                end
            end)
        end
    end
end

RegisterCommand('togglecruise', function()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    local driver = GetPedInVehicleSeat(veh, -1)
    local vehClass = GetVehicleClass(veh)
    if ped == driver and vehicleClasses[vehClass] then
        triggerCruiseControl(veh)
    end
end, false)

RegisterKeyMapping('togglecruise', 'Toggle Cruise Control', 'keyboard', 'Y')
