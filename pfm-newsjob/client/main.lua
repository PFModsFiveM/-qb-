QBCore = exports['pfm-core']:GetCoreObject({ 'Functions' })
PlayerJob = {}
CurrentPlate = {}

-- One garage blip, shown only while in the news job (it used to add a new blip on every job update).
local garageBlip = nil

local function refreshBlip()
    local isReporter = PlayerJob and PlayerJob.name == Config.Job
    if isReporter and not garageBlip then
        local c = Config.Locations['vehicle'].coords
        garageBlip = AddBlipForCoord(c.x, c.y, c.z)
        SetBlipSprite(garageBlip, 225)
        SetBlipDisplay(garageBlip, 4)
        SetBlipScale(garageBlip, 0.6)
        SetBlipAsShortRange(garageBlip, true)
        SetBlipColour(garageBlip, 1)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName(Lang:t('text.vehicle'))
        EndTextCommandSetBlipName(garageBlip)
    elseif not isReporter and garageBlip then
        RemoveBlip(garageBlip)
        garageBlip = nil
    end
end

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    PlayerJob = QBCore.Functions.GetPlayerData().job or {}
    refreshBlip()
end)

RegisterNetEvent('QBCore:Client:OnPlayerUpdated', function(key, val)
    if key == 'job' then
        PlayerJob = val or {}
        refreshBlip()
    elseif key == 'all' then
        PlayerJob = (val and val.job) or {}
        refreshBlip()
    end
end)

RegisterNetEvent('QBCore:Client:OnJobUpdate', function(job)
    PlayerJob = job or {}
    refreshBlip()
end)

RegisterNetEvent('QBCore:Client:SetDuty', function(onDuty)
    if PlayerJob then PlayerJob.onduty = onDuty end
end)

local function DrawText3D(x, y, z, text)
    SetTextScale(0.35, 0.35)
    SetTextFont(4)
    SetTextProportional(1)
    SetTextColour(255, 255, 255, 215)
    BeginTextCommandDisplayText('STRING')
    SetTextCentre(true)
    AddTextComponentSubstringPlayerName(text)
    SetDrawOrigin(x, y, z, 0)
    EndTextCommandDisplayText(0.0, 0.0)
    local factor = (string.len(text)) / 370
    DrawRect(0.0, 0.0 + 0.0125, 0.017 + factor, 0.03, 0, 0, 0, 75)
    ClearDrawOrigin()
end

CreateThread(function()
    while true do
        Wait(3)
        if LocalPlayer.state.isLoggedIn then
            local inRange = false
            local pos = GetEntityCoords(PlayerPedId())
            if PlayerJob.name == Config.Job then
                local duty = Config.Locations['duty'].coords
                if #(pos - vector3(duty.x, duty.y, duty.z)) < 1.5 then
                    inRange = true
                    DrawText3D(duty.x, duty.y, duty.z, PlayerJob.onduty and Lang:t('text.duty_off') or Lang:t('text.duty_on'))
                    if IsControlJustReleased(0, 38) then TriggerServerEvent('pfm-newsjob:server:toggleDuty') end
                end
                if #(pos - vector3(Config.Locations['vehicle'].coords.x, Config.Locations['vehicle'].coords.y, Config.Locations['vehicle'].coords.z)) < 10.0 then
                    inRange = true
                    DrawMarker(2, Config.Locations['vehicle'].coords.x, Config.Locations['vehicle'].coords.y, Config.Locations['vehicle'].coords.z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.3, 0.2, 0.15, 200, 200, 200, 222, false, false, false, true, false, false, false)
                    if #(pos - vector3(Config.Locations['vehicle'].coords.x, Config.Locations['vehicle'].coords.y, Config.Locations['vehicle'].coords.z)) < 1.5 then
                        if IsPedInAnyVehicle(PlayerPedId(), false) then
                            DrawText3D(Config.Locations['vehicle'].coords.x, Config.Locations['vehicle'].coords.y, Config.Locations['vehicle'].coords.z, Lang:t('text.store_vehicle'))
                        else
                            DrawText3D(Config.Locations['vehicle'].coords.x, Config.Locations['vehicle'].coords.y, Config.Locations['vehicle'].coords.z, Lang:t('text.vehicles'))
                        end
                        if IsControlJustReleased(0, 38) then
                            if IsPedInAnyVehicle(PlayerPedId(), false) then
                                StoreCurrentVehicle()
                            else
                                MenuGarage('vehicle')
                            end
                        end
                    end
                elseif #(pos - vector3(Config.Locations['heli'].coords.x, Config.Locations['heli'].coords.y, Config.Locations['heli'].coords.z)) < 5.0 then
                    inRange = true
                    DrawMarker(2, Config.Locations['heli'].coords.x, Config.Locations['heli'].coords.y, Config.Locations['heli'].coords.z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.3, 0.2, 0.15, 200, 200, 200, 222, false, false, false, true, false, false, false)
                    if #(pos - vector3(Config.Locations['heli'].coords.x, Config.Locations['heli'].coords.y, Config.Locations['heli'].coords.z)) < 1.5 then
                        if IsPedInAnyVehicle(PlayerPedId(), false) then
                            DrawText3D(Config.Locations['heli'].coords.x, Config.Locations['heli'].coords.y, Config.Locations['heli'].coords.z, Lang:t('text.store_helicopters'))
                        else
                            DrawText3D(Config.Locations['heli'].coords.x, Config.Locations['heli'].coords.y, Config.Locations['heli'].coords.z, Lang:t('text.helicopters'))
                        end
                        if IsControlJustReleased(0, 38) then
                            if IsPedInAnyVehicle(PlayerPedId(), false) then
                                StoreCurrentVehicle()
                            else
                                MenuGarage('heli')
                            end
                        end
                    end
                end
                if not inRange then
                    Wait(2500)
                end
            else
                Wait(2500)
            end
        else
            Wait(2500)
        end
    end
end)

CreateThread(function()
    while true do
        Wait(1)
        local inRange = false
        if LocalPlayer.state.isLoggedIn then
            local pos = GetEntityCoords(PlayerPedId())
            if #(pos - vector3(Config.Locations['main'].coords.x, Config.Locations['main'].coords.y, Config.Locations['main'].coords.z)) < 1.5 or #(pos - vector3(Config.Locations['inside'].coords.x, Config.Locations['inside'].coords.y, Config.Locations['inside'].coords.z)) < 1.5 then
                inRange = true
                if #(pos - vector3(Config.Locations['main'].coords.x, Config.Locations['main'].coords.y, Config.Locations['main'].coords.z)) < 1.5 then
                    DrawText3D(Config.Locations['main'].coords.x, Config.Locations['main'].coords.y, Config.Locations['main'].coords.z, Lang:t('text.enter'))
                    if IsControlJustReleased(0, 38) then
                        DoScreenFadeOut(500)
                        while not IsScreenFadedOut() do
                            Wait(10)
                        end

                        SetEntityCoords(PlayerPedId(), Config.Locations['inside'].coords.x, Config.Locations['inside'].coords.y, Config.Locations['inside'].coords.z, 0, 0, 0, false)
                        SetEntityHeading(PlayerPedId(), Config.Locations['inside'].coords.w)

                        Wait(100)

                        DoScreenFadeIn(1000)
                    end
                elseif #(pos - vector3(Config.Locations['inside'].coords.x, Config.Locations['inside'].coords.y, Config.Locations['inside'].coords.z)) < 1.5 then
                    DrawText3D(Config.Locations['inside'].coords.x, Config.Locations['inside'].coords.y, Config.Locations['inside'].coords.z, Lang:t('text.go_outside'))
                    if IsControlJustReleased(0, 38) then
                        DoScreenFadeOut(500)
                        while not IsScreenFadedOut() do
                            Wait(10)
                        end

                        SetEntityCoords(PlayerPedId(), Config.Locations['outside'].coords.x, Config.Locations['outside'].coords.y, Config.Locations['outside'].coords.z, 0, 0, 0, false)
                        SetEntityHeading(PlayerPedId(), Config.Locations['outside'].coords.w)

                        Wait(100)

                        DoScreenFadeIn(1000)
                    end
                end
            end
        end
        if not inRange then
            Wait(2500)
        end
    end
end)
