local sharedItems = exports['pfm-core']:GetShared('Items')

local currentGate = 0
local requiredItemsShowed = false
local requiredItems = {}
local inRange = false
local securityLockdown = false
local PlayerJob = {}
-- gate positions and doors come from Config.Gates (shared with the server, which decides)
local Gates = {}
for i, g in ipairs(Config.Gates or {}) do
    Gates[i] = { gatekey = g.gatekey, coords = g.coords, hit = false }
end

-- Functions

--- This will draw 3d text at the given location with the given text
--- @param x number
--- @param y number
--- @param z number
--- @param text string
--- @return nil
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

-- the gates, lockdown and alarm as the server has them
local function LoadPrisonState()
    QBCore.Functions.TriggerCallback('prison:server:GetState', function(state)
        if type(state) ~= 'table' then return end
        securityLockdown = state.lockdown == true
        for _, g in pairs(Gates) do g.hit = false end
        for _, i in ipairs(type(state.gates) == 'table' and state.gates or {}) do
            if Gates[i] then Gates[i].hit = true end
        end
    end)
end

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    PlayerJob = QBCore.Functions.GetPlayerData().job
    if LocalPlayer.state['isLoggedIn'] then LoadPrisonState() end
end)

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    PlayerJob = QBCore.Functions.GetPlayerData().job
    LoadPrisonState()
end)

RegisterNetEvent('QBCore:Client:OnPlayerUpdated', function(key, val)
    if key == 'job' then
        local JobInfo = val
        PlayerJob = JobInfo
    elseif key == 'all' then
        local JobInfo = val.job
        PlayerJob = JobInfo
    end
end)

-- Hacking a gate: the server checks the inmate, the gate and the items (the gatecrack is used up)
-- and hands back the hack, then decides the result (pfm-minigames checks the puzzle when it can).
RegisterNetEvent('electronickit:UseElectronickit', function()
    if currentGate ~= 0 and not securityLockdown and Gates[currentGate] and not Gates[currentGate].hit then
        local hasItem = QBCore.Functions.HasItem('gatecrack')
        if hasItem then
            TriggerServerEvent('prison:server:StartGateHack', currentGate)
        else
            QBCore.Functions.Notify(Lang:t('error.item_missing'), 'error')
        end
    end
end)

RegisterNetEvent('prison:client:GateHackStart', function(gate, ticketId, challenge)
    if not Gates[gate] then return end
    TriggerEvent('qb-inventory:client:requiredItems', requiredItems, false)
    QBCore.Functions.Progressbar('hack_gate', Lang:t('info.connecting_device'), math.random(5000, 10000), false, true, {
        disableMovement = true,
        disableCarMovement = true,
        disableMouse = false,
        disableCombat = true,
    }, {
        animDict = 'anim@gangops@facility@servers@',
        anim = 'hotwire',
        flags = 16,
    }, {}, {}, function()                                      -- Done
        StopAnimTask(PlayerPedId(), 'anim@gangops@facility@servers@', 'hotwire', 1.0)
        local success
        if type(challenge) == 'table' then
            success = exports['pfm-minigames']:PlayChallenge(challenge) -- judged by the server
        else
            success = exports['pfm-minigames']:Hacking(Config.GateHack and Config.GateHack.Size or 5, Config.GateHack and Config.GateHack.Seconds or 30)
        end
        TriggerServerEvent('prison:server:GateHackResult', ticketId, success == true)
    end, function() -- Cancel
        StopAnimTask(PlayerPedId(), 'anim@gangops@facility@servers@', 'hotwire', 1.0)
        QBCore.Functions.Notify(Lang:t('error.cancelled'), 'error')
    end)
end)

RegisterNetEvent('prison:client:SetLockDown', function(isLockdown)
    securityLockdown = isLockdown
    if not securityLockdown or not inJail then return end
    TriggerEvent('chat:addMessage', {
        color = { 255, 0, 0 },
        multiline = true,
        args = { 'HOSTAGE', Lang:t('error.security_activated') }
    })
end)

RegisterNetEvent('prison:client:PrisonBreakAlert', function()
    local coords = vector3(Config.Locations['middle'].x, Config.Locations['middle'].y, Config.Locations['middle'].z)
    local alertData = { title = Lang:t('info.police_alert_title'), coords = { x = coords.x, y = coords.y, z = coords.z }, description = Lang:t('info.police_alert_description') }
    TriggerEvent('qb-phone:client:addPoliceAlert', alertData)
    TriggerEvent('police:client:policeAlert', coords, Lang:t('info.police_alert_description'))

    local BreakBlip = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(BreakBlip, 161)
    SetBlipScale(BreakBlip, 3.0)
    SetBlipColour(BreakBlip, 3)
    PulseBlip(BreakBlip)
    PlaySound(-1, 'Lose_1st', 'GTAO_FM_Events_Soundset', 0, 0, 1)
    Wait(100)
    PlaySoundFrontend(-1, 'Beep_Red', 'DLC_HEIST_HACKING_SNAKE_SOUNDS', 1)
    Wait(100)
    PlaySound(-1, 'Lose_1st', 'GTAO_FM_Events_Soundset', 0, 0, 1)
    Wait(100)
    PlaySoundFrontend(-1, 'Beep_Red', 'DLC_HEIST_HACKING_SNAKE_SOUNDS', 1)
    Wait((1000 * 60 * 5))
    RemoveBlip(BreakBlip)
end)

RegisterNetEvent('prison:client:SetGateHit', function(key, isHit)
    if Gates[key] then Gates[key].hit = isHit == true end
end)

RegisterNetEvent('prison:client:JailAlarm', function(toggle)
    if toggle then
        local alarmIpl = GetInteriorAtCoordsWithType(1787.004, 2593.1984, 45.7978, 'int_prison_main')

        RefreshInterior(alarmIpl)
        EnableInteriorProp(alarmIpl, 'prison_alarm')

        CreateThread(function()
            while not PrepareAlarm('PRISON_ALARMS') do
                Wait(100)
            end
            StartAlarm('PRISON_ALARMS', true)
        end)
    else
        local alarmIpl = GetInteriorAtCoordsWithType(1787.004, 2593.1984, 45.7978, 'int_prison_main')

        RefreshInterior(alarmIpl)
        DisableInteriorProp(alarmIpl, 'prison_alarm')

        CreateThread(function()
            while not PrepareAlarm('PRISON_ALARMS') do
                Wait(100)
            end
            StopAllAlarms(true)
        end)
    end
end)

-- Threads

CreateThread(function()
    Wait(500)
    requiredItems = {
        [1] = { name = sharedItems['electronickit']['name'], image = sharedItems['electronickit']['image'] },
        [2] = { name = sharedItems['gatecrack']['name'], image = sharedItems['gatecrack']['image'] },
    }
    while true do
        inRange = false
        currentGate = 0
        local sleep = 1000
        if PlayerJob?.name ~= 'police' and PlayerJob?.name ~= 'corrections' then
            local pos = GetEntityCoords(PlayerPedId())
            for k in pairs(Gates) do
                local dist = #(pos - Gates[k].coords)
                if dist < 1.5 then
                    currentGate = k
                    inRange = true
                    if securityLockdown then
                        sleep = 0
                        DrawText3D(Gates[k].coords.x, Gates[k].coords.y, Gates[k].coords.z, '~r~SYSTEM LOCKDOWN')
                    elseif Gates[k].hit then
                        sleep = 0
                        DrawText3D(Gates[k].coords.x, Gates[k].coords.y, Gates[k].coords.z, 'SYSTEM BREACH')
                    elseif not requiredItemsShowed then
                        requiredItemsShowed = true
                        TriggerEvent('qb-inventory:client:requiredItems', requiredItems, true)
                    end
                end
            end

            if not inRange then
                if requiredItemsShowed then
                    requiredItemsShowed = false
                    TriggerEvent('qb-inventory:client:requiredItems', requiredItems, false)
                end
            end
        end
        Wait(sleep)
    end
end)

-- Leaving the prison is decided by the server (escape or back to a cell): no client check here.

-- ── security (batch 19F): alerts for staff and the camera view ─────────────────────────────────
-- Everything here only shows what the server decided; the server checks job, duty, grade and where
-- the viewer stands before it sends a camera or an alert.

RegisterNetEvent('prison:client:SecurityAlert', function(alert)
    local invoker = GetInvokingResource()
    if invoker and invoker ~= GetCurrentResourceName() then return end -- only the server sends these
    if type(alert) ~= 'table' then return end
    local label = tostring(alert.label or 'Prison alarm'):sub(1, 64)
    QBCore.Functions.Notify('Bolingbroke: ' .. label, 'error', 8000)
    local c = alert.coords
    if type(c) ~= 'table' or not tonumber(c.x) or not tonumber(c.y) then return end
    local blip = AddBlipForCoord(tonumber(c.x), tonumber(c.y), tonumber(c.z) or 0.0)
    SetBlipSprite(blip, 161)
    SetBlipScale(blip, 1.2)
    SetBlipColour(blip, 1)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(label)
    EndTextCommandSetBlipName(blip)
    SetTimeout(120000, function() RemoveBlip(blip) end)
end)

local viewing = nil -- { cam, index, count, label, from }

local function stopCamera()
    if not viewing then return end
    RenderScriptCams(false, false, 0, true, true)
    DestroyCam(viewing.cam, false)
    ClearFocus()
    ClearTimecycleModifier()
    viewing = nil
end

local function cameraText(text)
    SetTextFont(4)
    SetTextScale(0.45, 0.45)
    SetTextColour(255, 255, 255, 230)
    SetTextOutline()
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayText(0.02, 0.02)
end

RegisterNetEvent('prison:client:ViewCamera', function(cam)
    local invoker = GetInvokingResource()
    if invoker and invoker ~= GetCurrentResourceName() then return end -- only the server sends these
    if type(cam) ~= 'table' or type(cam.coords) ~= 'table' or type(cam.lookAt) ~= 'table' then return end
    local c, l = cam.coords, cam.lookAt
    if not tonumber(c.x) or not tonumber(l.x) then return end
    local first = viewing == nil
    if first then
        viewing = { cam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true), from = GetEntityCoords(PlayerPedId()) }
    end
    viewing.index, viewing.count = tonumber(cam.index) or 1, tonumber(cam.count) or 1
    viewing.label = tostring(cam.label or ''):sub(1, 48)
    SetCamCoord(viewing.cam, c.x, c.y, c.z)
    PointCamAtCoord(viewing.cam, l.x, l.y, l.z)
    SetCamFov(viewing.cam, tonumber(cam.fov) or 60.0)
    SetFocusPosAndVel(c.x, c.y, c.z, 0.0, 0.0, 0.0)
    SetTimecycleModifier('scanline_cam_cheap')
    RenderScriptCams(true, false, 0, true, true)
    if not first then return end
    -- a frame loop only while a camera is on screen (it draws the overlay and reads the keys)
    CreateThread(function()
        while viewing do
            DisableAllControlActions(0)
            EnableControlAction(0, 245, true) -- chat
            EnableControlAction(0, 249, true) -- push to talk
            cameraText(('CAM %d/%d  %s   [LEFT/RIGHT] switch  [BACKSPACE] exit'):format(viewing.index, viewing.count, viewing.label))
            if IsDisabledControlJustPressed(0, 177) or IsDisabledControlJustPressed(0, 194) then
                stopCamera()
            elseif IsDisabledControlJustPressed(0, 175) then
                TriggerServerEvent('prison:server:ViewCamera', viewing.index % viewing.count + 1)
            elseif IsDisabledControlJustPressed(0, 174) then
                TriggerServerEvent('prison:server:ViewCamera', (viewing.index - 2) % viewing.count + 1)
            elseif #(GetEntityCoords(PlayerPedId()) - viewing.from) > 3.0 or IsEntityDead(PlayerPedId()) then
                stopCamera()
            end
            Wait(0)
        end
    end)
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then stopCamera() end
end)

CreateThread(function()
    TriggerEvent('chat:addSuggestion', '/prisonsearch', 'Search for contraband (staff)', {
        { name = 'kind', help = 'pat, visitor or cell' }, { name = 'id', help = 'server id (optional: the nearest person)' } })
    TriggerEvent('chat:addSuggestion', '/prisonlockdown', 'Order or lift a lockdown (staff, gatehouse)', { { name = 'state', help = 'on or off' } })
    TriggerEvent('chat:addSuggestion', '/prisondoor', 'Lock or unlock a security door (staff, gatehouse)', {
        { name = 'door', help = 'door number' }, { name = 'action', help = 'lock or unlock' } })
    TriggerEvent('chat:addSuggestion', '/prisoncam', 'Watch the prison cameras (staff, gatehouse)', { { name = 'n', help = 'camera number' } })
    TriggerEvent('chat:addSuggestion', '/prisonalarm', 'Open alarms (staff)', { { name = 'action', help = 'list, clear <id> or riot' } })
    TriggerEvent('chat:addSuggestion', '/prisonevidence', 'Open the prison evidence stash (staff, gatehouse)')
    TriggerEvent('chat:addSuggestion', '/celllocker', 'Open the locker of your cell (inmates)')
end)
