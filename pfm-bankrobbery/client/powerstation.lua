local closestStation = 0
local currentFires = {} -- [fire session id] = { script fire handles }
local placing = false
local placedOn = nil -- 'station' | 'gate': what the charge in progress was placed on
local requiredItems = { [1] = { name = QBCore.Shared.Items['thermite']['name'], image = QBCore.Shared.Items['thermite']['image'] } }

-- Functions

--- This will load an animation dictionary so you can play an animation in that dictionary
--- @param dict string
--- @return nil
local function loadAnimDict(dict)
    RequestAnimDict(dict)
    while not HasAnimDictLoaded(dict) do
        Wait(0)
    end
end

-- Events

-- Fires are lit and put out by the server (one session per charge that went off); only this session's
-- fires are removed when it ends.
RegisterNetEvent('thermite:StartFire', function(id, coords, maxChildren, isGasFire, count)
    if type(coords) ~= 'table' and type(coords) ~= 'vector3' then return end
    if #(vector3(coords.x, coords.y, coords.z) - GetEntityCoords(PlayerPedId())) >= 100 then return end
    currentFires[id] = currentFires[id] or {}
    for _ = 1, math.max(1, math.min(tonumber(count) or 1, 7)) do
        local fire = StartScriptFire(coords.x, coords.y, coords.z - 0.9, maxChildren, isGasFire == true)
        currentFires[id][#currentFires[id] + 1] = fire
    end
end)

RegisterNetEvent('thermite:StopFires', function(id)
    local fires = currentFires[id]
    if not fires then return end
    currentFires[id] = nil
    for i = 1, #fires do
        RemoveScriptFire(fires[i])
    end
end)

-- The server decides what the charge is placed on (a power station or a thermite gate), uses it up
-- and sends the challenge; the minigame's answer goes to the server, which then lights the charge.
RegisterNetEvent('thermite:UseThermite', function()
    if placing then return end
    local ped = PlayerPedId()
    local pos = GetEntityCoords(ped)
    local atStation = closestStation ~= 0 and #(pos - Config.PowerStations[closestStation].coords) < 1.5
    if not atStation and currentThermiteGate == 0 then return end
    Config.OnEvidence(pos, 85)
    if CurrentCops < Config.MinimumThermitePolice then
        QBCore.Functions.Notify(Lang:t('error.minium_police_required', { police = Config.MinimumThermitePolice }), 'error')
        return
    end
    if atStation and Config.PowerStations[closestStation].hit then
        QBCore.Functions.Notify(Lang:t('error.fuses_already_blown'), 'error')
        return
    end
    placing = true
    placedOn = atStation and 'station' or 'gate'
    QBCore.Functions.TriggerCallback('thermite:server:check', function(challenge)
        if not challenge then
            placing = false
            return
        end
        Config.ShowRequiredItems(requiredItems, false)
        loadAnimDict('weapon@w_sp_jerrycan')
        TaskPlayAnim(ped, 'weapon@w_sp_jerrycan', 'fire', 3.0, 3.9, -1, 49, 0, 0, 0, 0)
        pcall(function() exports['pfm-minigames']:PlayChallenge(challenge) end)
        ClearPedTasks(ped)
        TriggerServerEvent('qb-bankrobbery:server:thermiteFinish')
        SetTimeout(10000, function() placing = false end) -- in case the verdict never arrives
    end)
end)

-- The server's verdict on the charge: passed, it goes off after the fuse; failed, it flares up here.
RegisterNetEvent('qb-bankrobbery:client:thermiteResult', function(passed)
    placing = false
    if not passed then
        PlaySound(-1, 'Place_Prop_Fail', 'DLC_Dmod_Prop_Editor_Sounds', 0, 0, 1)
        return
    end
    for time = 3, 1, -1 do
        QBCore.Functions.Notify(Lang:t('general.thermite_detonating_in_seconds', { time = time }))
        Wait(1000)
    end
    if placedOn == 'station' then
        QBCore.Functions.Notify(Lang:t('success.fuses_are_blown'), 'success')
    elseif placedOn == 'gate' then
        QBCore.Functions.Notify(Lang:t('success.door_has_opened'), 'success')
    end
end)

RegisterNetEvent('qb-bankrobbery:client:SetStationStatus', function(key, isHit)
    Config.PowerStations[key].hit = isHit
end)

RegisterNetEvent('qb-bankrobbery:client:setThermiteGate', function(bankId, i, isOpened)
    local bank = Config.BigBanks[bankId]
    local gate = bank and bank['thermite'] and bank['thermite'][i]
    if not gate then return end
    gate['isOpened'] = isOpened == true
    if isOpened and currentThermiteGate == gate['doorId'] then currentThermiteGate = 0 end
end)

-- Threads

CreateThread(function()
    for k = 1, #Config.PowerStations do
        local stationZone = BoxZone:Create(Config.PowerStations[k].coords, 1.0, 1.0, {
            name = 'powerstation_coords_' .. k,
            heading = 90.0,
            minZ = Config.PowerStations[k].coords.z - 1,
            maxZ = Config.PowerStations[k].coords.z + 1,
            debugPoly = false
        })
        stationZone:onPlayerInOut(function(inside)
            if inside and not Config.PowerStations[k].hit then
                closestStation = k
                Config.ShowRequiredItems(requiredItems, true)
            else
                if closestStation == k then
                    closestStation = 0
                    Config.ShowRequiredItems(requiredItems, false)
                end
            end
        end)
    end
end)
