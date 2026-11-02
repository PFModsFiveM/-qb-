-- Variables
local ObjectList = {}
local SpawnedSpikes = {}
local spikemodel = `P_ld_stinger_s`
local ClosestSpike = nil

-- Functions

local function GetClosestPoliceObject()
    local pos = GetEntityCoords(PlayerPedId(), true)
    local current = nil
    local dist = nil

    for id, _ in pairs(ObjectList) do
        local dist2 = #(pos - ObjectList[id].coords)
        if current then
            if dist2 < dist then
                current = id
                dist = dist2
            end
        else
            dist = dist2
            current = id
        end
    end
    return current, dist
end

function GetClosestSpike()
    local pos = GetEntityCoords(PlayerPedId(), true)
    local current = nil
    local dist = nil
    local maxDistance = 50.0

    for id, _ in pairs(SpawnedSpikes) do
        local spikeCoords = vector3(SpawnedSpikes[id].coords.x, SpawnedSpikes[id].coords.y, SpawnedSpikes[id].coords.z)
        local currentDist = #(pos - spikeCoords)

        if current then
            if currentDist < dist then
                current = id
                dist = currentDist
            end
        else
            current = id
            dist = currentDist
        end
    end

    if dist and dist <= maxDistance then
        ClosestSpike = current
    else
        ClosestSpike = nil
    end
end

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

-- Events

RegisterNetEvent('police:client:spawnCone', function()
    QBCore.Functions.Progressbar('spawn_object', Lang:t('progressbar.place_object'), 2500, false, true, {
        disableMovement = true,
        disableCarMovement = true,
        disableMouse = false,
        disableCombat = true,
    }, {
        animDict = 'anim@narcotics@trash',
        anim = 'drop_front',
        flags = 16,
    }, {}, {}, function() -- Done
        StopAnimTask(PlayerPedId(), 'anim@narcotics@trash', 'drop_front', 1.0)
        TriggerServerEvent('police:server:spawnObject', 'cone')
    end, function() -- Cancel
        StopAnimTask(PlayerPedId(), 'anim@narcotics@trash', 'drop_front', 1.0)
        QBCore.Functions.Notify(Lang:t('error.canceled'), 'error')
    end)
end)

RegisterNetEvent('police:client:spawnBarrier', function()
    QBCore.Functions.Progressbar('spawn_object', Lang:t('progressbar.place_object'), 2500, false, true, {
        disableMovement = true,
        disableCarMovement = true,
        disableMouse = false,
        disableCombat = true,
    }, {
        animDict = 'anim@narcotics@trash',
        anim = 'drop_front',
        flags = 16,
    }, {}, {}, function() -- Done
        StopAnimTask(PlayerPedId(), 'anim@narcotics@trash', 'drop_front', 1.0)
        TriggerServerEvent('police:server:spawnObject', 'barrier')
    end, function() -- Cancel
        StopAnimTask(PlayerPedId(), 'anim@narcotics@trash', 'drop_front', 1.0)
        QBCore.Functions.Notify(Lang:t('error.canceled'), 'error')
    end)
end)

RegisterNetEvent('police:client:spawnRoadSign', function()
    QBCore.Functions.Progressbar('spawn_object', Lang:t('progressbar.place_object'), 2500, false, true, {
        disableMovement = true,
        disableCarMovement = true,
        disableMouse = false,
        disableCombat = true,
    }, {
        animDict = 'anim@narcotics@trash',
        anim = 'drop_front',
        flags = 16,
    }, {}, {}, function() -- Done
        StopAnimTask(PlayerPedId(), 'anim@narcotics@trash', 'drop_front', 1.0)
        TriggerServerEvent('police:server:spawnObject', 'roadsign')
    end, function() -- Cancel
        StopAnimTask(PlayerPedId(), 'anim@narcotics@trash', 'drop_front', 1.0)
        QBCore.Functions.Notify(Lang:t('error.canceled'), 'error')
    end)
end)

RegisterNetEvent('police:client:spawnTent', function()
    QBCore.Functions.Progressbar('spawn_object', Lang:t('progressbar.place_object'), 2500, false, true, {
        disableMovement = true,
        disableCarMovement = true,
        disableMouse = false,
        disableCombat = true,
    }, {
        animDict = 'anim@narcotics@trash',
        anim = 'drop_front',
        flags = 16,
    }, {}, {}, function() -- Done
        StopAnimTask(PlayerPedId(), 'anim@narcotics@trash', 'drop_front', 1.0)
        TriggerServerEvent('police:server:spawnObject', 'tent')
    end, function() -- Cancel
        StopAnimTask(PlayerPedId(), 'anim@narcotics@trash', 'drop_front', 1.0)
        QBCore.Functions.Notify(Lang:t('error.canceled'), 'error')
    end)
end)

RegisterNetEvent('police:client:spawnLight', function()
    QBCore.Functions.Progressbar('spawn_object', Lang:t('progressbar.place_object'), 2500, false, true, {
        disableMovement = true,
        disableCarMovement = true,
        disableMouse = false,
        disableCombat = true,
    }, {
        animDict = 'anim@narcotics@trash',
        anim = 'drop_front',
        flags = 16,
    }, {}, {}, function() -- Done
        StopAnimTask(PlayerPedId(), 'anim@narcotics@trash', 'drop_front', 1.0)
        TriggerServerEvent('police:server:spawnObject', 'light')
    end, function() -- Cancel
        StopAnimTask(PlayerPedId(), 'anim@narcotics@trash', 'drop_front', 1.0)
        QBCore.Functions.Notify(Lang:t('error.canceled'), 'error')
    end)
end)

RegisterNetEvent('police:client:deleteObject', function()
    local objectId, dist = GetClosestPoliceObject()
    if dist < 5.0 then
        QBCore.Functions.Progressbar('remove_object', Lang:t('progressbar.remove_object'), 2500, false, true, {
            disableMovement = true,
            disableCarMovement = true,
            disableMouse = false,
            disableCombat = true,
        }, {
            animDict = 'weapons@first_person@aim_rng@generic@projectile@thermal_charge@',
            anim = 'plant_floor',
            flags = 16,
        }, {}, {}, function() -- Done
            StopAnimTask(PlayerPedId(), 'weapons@first_person@aim_rng@generic@projectile@thermal_charge@', 'plant_floor', 1.0)
            TriggerServerEvent('police:server:deleteObject', objectId)
        end, function() -- Cancel
            StopAnimTask(PlayerPedId(), 'weapons@first_person@aim_rng@generic@projectile@thermal_charge@', 'plant_floor', 1.0)
            QBCore.Functions.Notify(Lang:t('error.canceled'), 'error')
        end)
    end
end)

RegisterNetEvent('police:client:removeObject', function(objectId)
    NetworkRequestControlOfEntity(ObjectList[objectId].object)
    DeleteObject(ObjectList[objectId].object)
    ObjectList[objectId] = nil
end)

RegisterNetEvent('police:client:spawnObject', function(objectId, type, player)
    local coords = GetEntityCoords(GetPlayerPed(GetPlayerFromServerId(player)))
    local heading = GetEntityHeading(GetPlayerPed(GetPlayerFromServerId(player)))
    local forward = GetEntityForwardVector(PlayerPedId())
    local x, y, z = table.unpack(coords + forward * 0.5)
    local spawnedObj = CreateObject(Config.Objects[type].model, x, y, z, true, false, false)
    PlaceObjectOnGroundProperly(spawnedObj)
    SetEntityHeading(spawnedObj, heading)
    FreezeEntityPosition(spawnedObj, Config.Objects[type].freeze)
    ObjectList[objectId] = {
        id = objectId,
        object = spawnedObj,
        coords = vector3(x, y, z - 0.3),
    }
end)

-- Spike strips are placed and listed by the server (server/objects.lua).
RegisterNetEvent('police:client:SpawnSpikeStrip', function()
    if PlayerJob.type == 'leo' and PlayerJob.onduty then
        TriggerServerEvent('police:server:PlaceSpike')
    end
end)

-- The officer who placed a strip sets it flat on the ground (the server placed it at their feet).
RegisterNetEvent('police:client:SpikePlaced', function(netid)
    local tries = 0
    while not NetworkDoesNetworkIdExist(netid) and tries < 20 do Wait(100) tries += 1 end
    if not NetworkDoesNetworkIdExist(netid) then return end
    local spike = NetToObj(netid)
    if spike ~= 0 and DoesEntityExist(spike) then PlaceObjectOnGroundProperly(spike) end
end)

RegisterNetEvent('police:client:SyncSpikes', function(list)
    local clean = {}
    if type(list) == 'table' then
        for _, s in ipairs(list) do
            if type(s) == 'table' and tonumber(s.id) and s.coords and tonumber(s.coords.x) and tonumber(s.coords.y) and tonumber(s.coords.z) then
                clean[#clean + 1] = { id = tonumber(s.id), netid = s.netid, coords = vector3(s.coords.x, s.coords.y, s.coords.z) }
            end
        end
    end
    SpawnedSpikes = clean
    ClosestSpike = nil
end)

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    TriggerServerEvent('police:server:RequestSpikes')
end)

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName == GetCurrentResourceName() and LocalPlayer.state.isLoggedIn then
        TriggerServerEvent('police:server:RequestSpikes')
    end
end)

-- Threads

CreateThread(function()
    while true do
        local sleep = 1000
        if LocalPlayer.state.isLoggedIn then
            GetClosestSpike()

            if ClosestSpike then
                sleep = 0

                -- Vehicle Interaction (Bursting Tires)
                local vehicle = GetVehiclePedIsIn(PlayerPedId(), false)
                if vehicle and vehicle ~= 0 then
                    local tires = {
                        { bone = 'wheel_lf', index = 0 },
                        { bone = 'wheel_rf', index = 1 },
                        { bone = 'wheel_lm', index = 2 },
                        { bone = 'wheel_rm', index = 3 },
                        { bone = 'wheel_lr', index = 4 },
                        { bone = 'wheel_rr', index = 5 }
                    }

                    for a = 1, #tires do
                        local tirePos = GetWorldPositionOfEntityBone(vehicle, GetEntityBoneIndexByName(vehicle, tires[a].bone))
                        local spike = GetClosestObjectOfType(tirePos.x, tirePos.y, tirePos.z, 15.0, spikemodel, 1, 1, 1)
                        local spikePos = GetEntityCoords(spike, false)
                        local distance = #(tirePos - spikePos)

                        if distance < 1.8 then
                            if not IsVehicleTyreBurst(vehicle, tires[a].index, true) or IsVehicleTyreBurst(vehicle, tires[a].index, false) then
                                SetVehicleTyreBurst(vehicle, tires[a].index, false, 1000.0)
                            end
                        end
                    end
                end

                -- Ped Interaction (Deleting Spike)
                local ped = PlayerPedId()
                local pos = GetEntityCoords(ped)
                local dist = #(pos - SpawnedSpikes[ClosestSpike].coords)
                if dist < 4 and not IsPedInAnyVehicle(ped, false) then
                    if PlayerJob.type == 'leo' and PlayerJob.onduty then
                        DrawText3D(pos.x, pos.y, pos.z, Lang:t('info.delete_spike'))
                        if IsControlJustPressed(0, 38) then
                            -- the server checks the officer is beside it and takes it up
                            TriggerServerEvent('police:server:RemoveSpike', SpawnedSpikes[ClosestSpike].id)
                            ClosestSpike = nil
                        end
                    end
                end
            end
        end
        Wait(sleep)
    end
end)
