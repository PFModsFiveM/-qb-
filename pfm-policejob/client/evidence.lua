local sharedWeapons = exports['pfm-core']:GetShared('Weapons')

-- Scene evidence as this officer's client knows it. The server sends only drops within 150 m of an
-- on-duty officer (a snapshot when the officer moves into a new area or goes on duty, then each new
-- drop), never who left them. Bagging and clean-up only name a drop; the server checks the rest.

-- Variables
local CurrentStatusList = {}
local Casings = {}      -- [id] = { label = weapon hash, coords }
local Blooddrops = {}   -- [id] = { label = sample id, coords }
local Fingerprints = {} -- [id] = { coords }
local Current = nil     -- { kind, id } the drop the flashlight found
local shotAmount = 0

local StatusList = {
    ['fight'] = Lang:t('evidence.red_hands'),
    ['widepupils'] = Lang:t('evidence.wide_pupils'),
    ['redeyes'] = Lang:t('evidence.red_eyes'),
    ['weedsmell'] = Lang:t('evidence.weed_smell'),
    ['gunpowder'] = Lang:t('evidence.gunpowder'),
    ['chemicals'] = Lang:t('evidence.chemicals'),
    ['heavybreath'] = Lang:t('evidence.heavy_breathing'),
    ['sweat'] = Lang:t('evidence.sweat'),
    ['handbleed'] = Lang:t('evidence.handbleed'),
    ['confused'] = Lang:t('evidence.confused'),
    ['alcohol'] = Lang:t('evidence.alcohol'),
    ['heavyalcohol'] = Lang:t('evidence.heavy_alcohol'),
    ['agitated'] = Lang:t('evidence.agitated')
}

local WhitelistedWeapons = {
    `weapon_unarmed`,
    `weapon_snowball`,
    `weapon_stungun`,
    `weapon_petrolcan`,
    `weapon_hazardcan`,
    `weapon_fireextinguisher`
}

local Tables = { casing = Casings, blood = Blooddrops, fingerprint = Fingerprints }

-- Functions
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

local function WhitelistedWeapon(weapon)
    for i = 1, #WhitelistedWeapons do
        if WhitelistedWeapons[i] == weapon then
            return true
        end
    end
    return false
end

local function DropBulletCasing(weapon, ped)
    local randX = math.random() + math.random(-1, 1)
    local randY = math.random() + math.random(-1, 1)
    local coords = GetOffsetFromEntityInWorldCoords(ped, randX, randY, 0)
    TriggerServerEvent('evidence:server:CreateCasing', weapon, coords)
    Wait(300)
end

local function Ground(coords)
    return { x = coords.x, y = coords.y, z = coords.z - 0.9 }
end

local function StreetLabel(coords)
    local s1, s2 = GetStreetNameAtCoord(coords.x, coords.y, coords.z)
    local street1 = GetStreetNameFromHashKey(s1)
    local street2 = GetStreetNameFromHashKey(s2)
    local label = street1
    if street2 and street2 ~= '' then label = label .. ' | ' .. street2 end
    return (label:gsub("%'", ''))
end

local function CasingLabel(hash)
    local w = sharedWeapons[hash]
    if not w then return tostring(hash or '') end
    return (w.ammotype and Config.AmmoLabels[w.ammotype]) or w.label or w.name
end

-- Events
RegisterNetEvent('evidence:client:SetStatus', function(statusId, time)
    if time > 0 and StatusList[statusId] then
        if (CurrentStatusList == nil or CurrentStatusList[statusId] == nil) or
            (CurrentStatusList[statusId] and CurrentStatusList[statusId].time < 20) then
            CurrentStatusList[statusId] = {
                text = StatusList[statusId],
                time = time
            }
            QBCore.Functions.Notify(CurrentStatusList[statusId].text, 'error')
        end
    elseif StatusList[statusId] then
        CurrentStatusList[statusId] = nil
    end
    TriggerServerEvent('evidence:server:UpdateStatus', CurrentStatusList)
end)

RegisterNetEvent('evidence:client:AddBlooddrop', function(bloodId, sampleId, _, coords)
    Blooddrops[bloodId] = { label = sampleId, coords = Ground(coords) }
end)

RegisterNetEvent('evidence:client:RemoveBlooddrop', function(bloodId)
    Blooddrops[bloodId] = nil
    if Current and Current.kind == 'blood' and Current.id == bloodId then Current = nil end
end)

RegisterNetEvent('evidence:client:AddFingerPrint', function(fingerId, _, coords)
    Fingerprints[fingerId] = { coords = Ground(coords) }
end)

RegisterNetEvent('evidence:client:RemoveFingerprint', function(fingerId)
    Fingerprints[fingerId] = nil
    if Current and Current.kind == 'fingerprint' and Current.id == fingerId then Current = nil end
end)

RegisterNetEvent('evidence:client:AddCasing', function(casingId, weapon, coords)
    Casings[casingId] = { label = weapon, coords = Ground(coords) }
end)

RegisterNetEvent('evidence:client:RemoveCasing', function(casingId)
    Casings[casingId] = nil
    if Current and Current.kind == 'casing' and Current.id == casingId then Current = nil end
end)

-- Everything around the officer, replacing what the client knew (an empty list when off duty).
RegisterNetEvent('evidence:client:SceneSnapshot', function(list)
    for _, t in pairs(Tables) do
        for k in pairs(t) do t[k] = nil end
    end
    Current = nil
    if type(list) ~= 'table' then return end
    for _, d in ipairs(list) do
        local t = Tables[d.kind]
        if t and d.id then t[d.id] = { label = d.label, coords = Ground(d) } end
    end
end)

local function IdsNear(t, pos, radius)
    local list = {}
    for id, v in pairs(t) do
        if #(pos - vector3(v.coords.x, v.coords.y, v.coords.z)) < radius then list[#list + 1] = id end
    end
    return list
end

RegisterNetEvent('evidence:client:ClearBlooddropsInArea', function()
    local pos = GetEntityCoords(PlayerPedId())
    QBCore.Functions.Progressbar('clear_blooddrops', Lang:t('progressbar.blood_clear'), 5000, false, true, {
        disableMovement = false,
        disableCarMovement = false,
        disableMouse = false,
        disableCombat = true
    }, {}, {}, {}, function() -- Done
        local list = IdsNear(Blooddrops, pos, 10.0)
        if #list > 0 then
            TriggerServerEvent('evidence:server:ClearBlooddrops', list)
            QBCore.Functions.Notify(Lang:t('success.blood_clear'), 'success')
        end
    end, function() -- Cancel
        QBCore.Functions.Notify(Lang:t('error.blood_not_cleared'), 'error')
    end)
end)

RegisterNetEvent('evidence:client:ClearCasingsInArea', function()
    local pos = GetEntityCoords(PlayerPedId())
    QBCore.Functions.Progressbar('clear_casings', Lang:t('progressbar.bullet_casing'), 5000, false, true, {
        disableMovement = false,
        disableCarMovement = false,
        disableMouse = false,
        disableCombat = true
    }, {}, {}, {}, function() -- Done
        local list = IdsNear(Casings, pos, 10.0)
        if #list > 0 then
            TriggerServerEvent('evidence:server:ClearCasings', list)
            QBCore.Functions.Notify(Lang:t('success.bullet_casing_removed'), 'success')
        end
    end, function() -- Cancel
        QBCore.Functions.Notify(Lang:t('error.bullet_casing_not_removed'), 'error')
    end)
end)

-- Threads

CreateThread(function()
    while true do
        Wait(10000)
        if LocalPlayer.state.isLoggedIn then
            if CurrentStatusList and next(CurrentStatusList) then
                for k, _ in pairs(CurrentStatusList) do
                    if CurrentStatusList[k].time > 0 then
                        CurrentStatusList[k].time = CurrentStatusList[k].time - 10
                    else
                        CurrentStatusList[k].time = 0
                    end
                end
                TriggerServerEvent('evidence:server:UpdateStatus', CurrentStatusList)
            end
            if shotAmount > 0 then
                shotAmount = 0
            end
        end
    end
end)

-- Gunpowder status and casings when shooting. Checked every frame only while a gun is in hand.
CreateThread(function()
    while true do
        local ped = PlayerPedId()
        if IsPedArmed(ped, 4) then
            Wait(0)
            if IsPedShooting(ped) then
                local weapon = GetSelectedPedWeapon(ped)
                if not WhitelistedWeapon(weapon) then
                    shotAmount = shotAmount + 1
                    if shotAmount > 5 and (CurrentStatusList == nil or CurrentStatusList['gunpowder'] == nil) then
                        if math.random(1, 10) <= 7 then
                            TriggerEvent('evidence:client:SetStatus', 'gunpowder', 200)
                        end
                    end
                    DropBulletCasing(weapon, ped)
                end
            end
        else
            Wait(500)
        end
    end
end)

local function FindNear(pos)
    for kind, t in pairs(Tables) do
        for id, v in pairs(t) do
            if #(pos - vector3(v.coords.x, v.coords.y, v.coords.z)) < 1.5 then return { kind = kind, id = id } end
        end
    end
    return nil
end

local function Collect(cur, drop)
    local info = { street = StreetLabel(drop.coords) }
    if cur.kind == 'casing' then
        TriggerServerEvent('evidence:server:AddCasingToInventory', cur.id, info)
    elseif cur.kind == 'blood' then
        TriggerServerEvent('evidence:server:AddBlooddropToInventory', cur.id, info)
    else
        TriggerServerEvent('evidence:server:AddFingerprintToInventory', cur.id, info)
    end
end

-- The flashlight finds drops within 1.5 m; the found drop is labelled (and bagged with G) while the
-- officer stays next to it. Draws every frame only then.
CreateThread(function()
    while true do
        local sleep = 1000
        if LocalPlayer.state.isLoggedIn and PlayerJob.type == 'leo' and PlayerJob.onduty then
            local ped = PlayerPedId()
            local pos = GetEntityCoords(ped)
            if IsPlayerFreeAiming(PlayerId()) and GetSelectedPedWeapon(ped) == `WEAPON_FLASHLIGHT` then
                sleep = 250
                Current = FindNear(pos) or Current
            end
            local drop = Current and Tables[Current.kind][Current.id]
            if drop and #(pos - vector3(drop.coords.x, drop.coords.y, drop.coords.z)) < 1.5 then
                sleep = 0
                local text
                if Current.kind == 'casing' then
                    text = Lang:t('info.bullet_casing', { value = CasingLabel(drop.label) })
                elseif Current.kind == 'blood' then
                    text = Lang:t('info.blood_text', { value = drop.label or '' })
                else
                    text = Lang:t('info.fingerprint_text')
                end
                DrawText3D(drop.coords.x, drop.coords.y, drop.coords.z, text)
                if IsControlJustReleased(0, 47) then
                    Collect(Current, drop)
                    Wait(500)
                end
            elseif Current and not drop then
                Current = nil
            end
        end
        Wait(sleep)
    end
end)
