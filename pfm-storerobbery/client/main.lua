local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions' })
local currentRegister = 0
local currentSafe = 0
local copsCalled = false
local CurrentCops = 0
local PlayerJob = {}
local onDuty = false
local usingAdvanced = false

CreateThread(function()
    Wait(1000)
    if QBCore.Functions.GetPlayerData().job ~= nil and next(QBCore.Functions.GetPlayerData().job) then
        PlayerJob = QBCore.Functions.GetPlayerData().job
    end
end)

CreateThread(function()
    while true do
        Wait(1000 * 60 * 5)
        if copsCalled then
            copsCalled = false
        end
    end
end)

CreateThread(function()
    Wait(1000)
    setupRegister()
    setupSafes()
    while true do
        local ped = PlayerPedId()
        local pos = GetEntityCoords(ped)
        local inRange = false
        for k in pairs(Config.Registers) do
            local dist = #(pos - Config.Registers[k][1].xyz)
            if dist <= 1 and Config.Registers[k].robbed then
                inRange = true
                DrawText3Ds(Config.Registers[k][1].xyz, Lang:t('text.the_cash_register_is_empty'))
            end
        end
        if not inRange then
            Wait(2000)
        end
        Wait(3)
    end
end)

CreateThread(function()
    while true do
        Wait(1)
        local inRange = false
        if QBCore ~= nil then
            local pos = GetEntityCoords(PlayerPedId())
            for safe, _ in pairs(Config.Safes) do
                local dist = #(pos - Config.Safes[safe][1].xyz)
                if dist < 3 then
                    inRange = true
                    if dist < 1.0 then
                        if not Config.Safes[safe].robbed then
                            DrawText3Ds(Config.Safes[safe][1].xyz, Lang:t('text.try_combination'))
                            if IsControlJustPressed(0, 38) then
                                if CurrentCops >= Config.MinimumStoreRobberyPolice then
                                    currentSafe = safe
                                    if math.random(1, 100) <= 65 and not QBCore.Functions.IsWearingGloves() then
                                        TriggerServerEvent('evidence:server:CreateFingerDrop', pos)
                                    end
                                    if math.random(100) <= 50 then
                                        TriggerServerEvent('hud:server:GainStress', math.random(1, 3))
                                    end
                                    if Config.Safes[safe].type == 'keypad' then
                                        SendNUIMessage({
                                            action = 'openKeypad',
                                        })
                                        SetNuiFocus(true, true)
                                    else
                                        crackPadlock(safe)
                                    end

                                    if not copsCalled then
                                        pos = GetEntityCoords(PlayerPedId())
                                        local s1, s2 = GetStreetNameAtCoord(pos.x, pos.y, pos.z)
                                        local street1 = GetStreetNameFromHashKey(s1)
                                        local street2 = GetStreetNameFromHashKey(s2)
                                        local streetLabel = street1
                                        if street2 ~= nil then
                                            streetLabel = streetLabel .. ' ' .. street2
                                        end
                                        TriggerServerEvent('qb-storerobbery:server:callCops', 'safe', currentSafe, streetLabel, pos)
                                        copsCalled = true
                                    end
                                else
                                    QBCore.Functions.Notify(Lang:t('error.minimum_store_robbery_police', { MinimumStoreRobberyPolice = Config.MinimumStoreRobberyPolice }), 'error')
                                end
                            end
                        else
                            DrawText3Ds(Config.Safes[safe][1].xyz, Lang:t('text.safe_opened'))
                        end
                    end
                end
            end
        end

        if not inRange then
            Wait(2000)
        end
    end
end)

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    PlayerJob = QBCore.Functions.GetPlayerData().job
    onDuty = true
end)

RegisterNetEvent('QBCore:Client:SetDuty', function(duty)
    onDuty = duty
end)

RegisterNetEvent('QBCore:Client:OnPlayerUpdated', function(key, val)
    if key == 'job' then
        local JobInfo = val
        PlayerJob = JobInfo
        onDuty = true
    elseif key == 'all' then
        local JobInfo = val.job
        PlayerJob = JobInfo
        onDuty = true
    end
end)

RegisterNetEvent('police:SetCopCount', function(amount)
    CurrentCops = amount
end)

-- Registers are picked through the server: it checks the register and the pick, sends the lockpick
-- challenge (pfm-minigames), judges it and decides whether the pick breaks.
local picking = false
RegisterNetEvent('lockpicks:UseLockpick', function(isAdvanced)
    if picking then return end
    local ped = PlayerPedId()
    local pos = GetEntityCoords(ped)
    for k in pairs(Config.Registers) do
        local dist = #(pos - Config.Registers[k][1].xyz)
        if dist <= 1 and not Config.Registers[k].robbed then
            if CurrentCops >= Config.MinimumStoreRobberyPolice then
                usingAdvanced = isAdvanced == true
                TriggerServerEvent('qb-storerobbery:server:startRegister', k, usingAdvanced)
                if not QBCore.Functions.IsWearingGloves() then
                    TriggerServerEvent('evidence:server:CreateFingerDrop', pos)
                end
                if not copsCalled then
                    local s1, s2 = GetStreetNameAtCoord(pos.x, pos.y, pos.z)
                    local street1 = GetStreetNameFromHashKey(s1)
                    local street2 = GetStreetNameFromHashKey(s2)
                    local streetLabel = street1
                    if street2 ~= nil then
                        streetLabel = streetLabel .. ' ' .. street2
                    end
                    TriggerServerEvent('qb-storerobbery:server:callCops', 'cashier', k, streetLabel, pos)
                    copsCalled = true
                end
            else
                QBCore.Functions.Notify(Lang:t('error.minimum_store_robbery_police', { MinimumStoreRobberyPolice = Config.MinimumStoreRobberyPolice }), 'error')
            end
            return
        end
    end
end)

RegisterNetEvent('qb-storerobbery:client:registerChallenge', function(register, challenge)
    if picking or not Config.Registers[register] then return end
    picking = true
    pcall(function() exports['pfm-minigames']:PlayChallenge(challenge) end)
    -- also after a failure: the server rolls the pick's breakage then
    TriggerServerEvent('qb-storerobbery:server:finishRegister', register)
    SetTimeout(10000, function() picking = false end) -- in case the result never arrives
end)

-- The server's verdict: an opened register is emptied (progress bar); a failed pick may leave
-- fingerprints.
RegisterNetEvent('qb-storerobbery:client:registerResult', function(register, opened)
    picking = false
    if not opened then
        if (not QBCore.Functions.IsWearingGloves() and math.random(1, 100) <= 25) then
            TriggerServerEvent('evidence:server:CreateFingerDrop', GetEntityCoords(PlayerPedId()))
        end
        QBCore.Functions.Notify(Lang:t('error.process_canceled'), 'error')
        return
    end
    emptyRegister(register)
end)

function setupRegister()
    QBCore.Functions.TriggerCallback('qb-storerobbery:server:getRegisterStatus', function(Registers)
        for k in pairs(Registers) do
            Config.Registers[k].robbed = Registers[k].robbed
        end
    end)
end

function setupSafes()
    QBCore.Functions.TriggerCallback('qb-storerobbery:server:getSafeStatus', function(Safes)
        for k in pairs(Safes) do
            Config.Safes[k].robbed = Safes[k].robbed
        end
    end)
end

DrawText3Ds = function(coords, text)
    SetTextScale(0.35, 0.35)
    SetTextFont(4)
    SetTextProportional(1)
    SetTextColour(255, 255, 255, 215)
    BeginTextCommandDisplayText('STRING')
    SetTextCentre(true)
    AddTextComponentSubstringPlayerName(text)
    SetDrawOrigin(coords, 0)
    EndTextCommandDisplayText(0.0, 0.0)
    local factor = (string.len(text)) / 370
    DrawRect(0.0, 0.0 + 0.0125, 0.017 + factor, 0.03, 0, 0, 0, 75)
    ClearDrawOrigin()
end

function loadAnimDict(dict)
    while (not HasAnimDictLoaded(dict)) do
        RequestAnimDict(dict)
        Wait(100)
    end
end

function takeAnim()
    local ped = PlayerPedId()
    while (not HasAnimDictLoaded('amb@prop_human_bum_bin@idle_b')) do
        RequestAnimDict('amb@prop_human_bum_bin@idle_b')
        Wait(100)
    end
    TaskPlayAnim(ped, 'amb@prop_human_bum_bin@idle_b', 'idle_d', 8.0, 8.0, -1, 50, 0, false, false, false)
    Wait(2500)
    TaskPlayAnim(ped, 'amb@prop_human_bum_bin@idle_b', 'exit', 8.0, 8.0, -1, 50, 0, false, false, false)
end

local openingDoor = false

-- Empties a register the server opened for this player (finishRegister): the server pays after
-- the progress bar, if the player stayed at the register for it.
function emptyRegister(register)
    currentRegister = register
    local lockpickTime = 25000
    LockpickDoorAnim(lockpickTime)
    QBCore.Functions.Progressbar('search_register', Lang:t('text.emptying_the_register'), lockpickTime, false, true, {
        disableMovement = true,
        disableCarMovement = true,
        disableMouse = false,
        disableCombat = true,
    }, {
        animDict = 'veh@break_in@0h@p_m_one@',
        anim = 'low_force_entry_ds',
        flags = 16,
    }, {}, {}, function() -- Done
        openingDoor = false
        ClearPedTasks(PlayerPedId())
        TriggerServerEvent('qb-storerobbery:server:takeMoney', register, true)
    end, function() -- Cancel
        openingDoor = false
        ClearPedTasks(PlayerPedId())
        QBCore.Functions.Notify(Lang:t('error.process_canceled'), 'error')
        currentRegister = 0
    end)
    CreateThread(function()
        while openingDoor do
            TriggerServerEvent('hud:server:GainStress', math.random(1, 3))
            Wait(10000)
        end
    end)
end

function LockpickDoorAnim(time)
    time = time / 1000
    loadAnimDict('veh@break_in@0h@p_m_one@')
    TaskPlayAnim(PlayerPedId(), 'veh@break_in@0h@p_m_one@', 'low_force_entry_ds', 3.0, 3.0, -1, 16, 0, false, false, false)
    openingDoor = true
    CreateThread(function()
        while openingDoor do
            TaskPlayAnim(PlayerPedId(), 'veh@break_in@0h@p_m_one@', 'low_force_entry_ds', 3.0, 3.0, -1, 16, 0, 0, 0, 0)
            Wait(2000)
            time = time - 2
            TriggerServerEvent('qb-storerobbery:server:takeMoney', currentRegister, false)
            if time <= 0 then
                openingDoor = false
                StopAnimTask(PlayerPedId(), 'veh@break_in@0h@p_m_one@', 'low_force_entry_ds', 1.0)
            end
        end
        currentRegister = 0
    end)
end

RegisterNUICallback('callcops', function(_, cb)
    TriggerEvent('police:SetCopAlert')
    cb('ok')
end)

-- Padlock safes: the server sends the dial challenge (pfm-minigames) and judges it; the combination
-- never reaches the client. SafeReward pays only for a challenge the server saw passed.
local cracking = false
function crackPadlock(safe)
    if cracking then return end
    cracking = true
    QBCore.Functions.TriggerCallback('qb-storerobbery:server:startPadlock', function(challenge)
        if not challenge then
            cracking = false
            return
        end
        local ok, passed = pcall(function() return exports['pfm-minigames']:PlayChallenge(challenge) end)
        if ok and passed and not Config.Safes[safe].robbed then
            TriggerServerEvent('qb-storerobbery:server:SafeReward', safe)
            takeAnim()
        else
            QBCore.Functions.Notify(Lang:t('error.process_canceled'), 'error')
        end
        currentSafe = 0
        copsCalled = false
        cracking = false
    end, safe)
end

RegisterNUICallback('PadLockClose', function(_, cb)
    SetNuiFocus(false, false)
    copsCalled = false
    cb('ok')
end)

RegisterNUICallback('CombinationFail', function(_, cb)
    PlaySound(-1, 'Place_Prop_Fail', 'DLC_Dmod_Prop_Editor_Sounds', 0, 0, 1)
    cb('ok')
end)

RegisterNUICallback('TryCombination', function(data, cb)
    -- the guess is validated server-side; the code never reaches the client
    QBCore.Functions.TriggerCallback('qb-storerobbery:server:isCombinationRight', function(correct)
        if correct then
            TriggerServerEvent('qb-storerobbery:server:SafeReward', currentSafe)
            SetNuiFocus(false, false)
            SendNUIMessage({
                action = 'closeKeypad',
                error = false,
            })
            currentSafe = 0
            takeAnim()
        else
            TriggerEvent('police:SetCopAlert')
            SetNuiFocus(false, false)
            SendNUIMessage({
                action = 'closeKeypad',
                error = true,
            })
            currentSafe = 0
        end
        cb('ok')
    end, currentSafe, tonumber(data.combination))
end)

RegisterNetEvent('qb-storerobbery:client:setRegisterStatus', function(batch, val)
    -- Has to be a better way maybe like adding a unique id to identify the register
    if (type(batch) ~= 'table') then
        Config.Registers[batch] = val
    else
        for k in pairs(batch) do
            Config.Registers[k] = batch[k]
        end
    end
end)

RegisterNetEvent('qb-storerobbery:client:setSafeStatus', function(safe, bool)
    Config.Safes[safe].robbed = bool
end)

RegisterNetEvent('qb-storerobbery:client:robberyCall', function(_, _, _, coords)
    if (PlayerJob.name == 'police' or PlayerJob.type == 'leo') and onDuty then
        PlaySound(-1, 'Lose_1st', 'GTAO_FM_Events_Soundset', 0, 0, 1)
        TriggerServerEvent('police:server:policeAlert', Lang:t('email.storerobbery_progress'))

        local transG = 250
        local blip = AddBlipForCoord(coords.x, coords.y, coords.z)
        SetBlipSprite(blip, 458)
        SetBlipColour(blip, 1)
        SetBlipDisplay(blip, 4)
        SetBlipAlpha(blip, transG)
        SetBlipScale(blip, 1.0)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName(Lang:t('email.shop_robbery'))
        EndTextCommandSetBlipName(blip)
        while transG ~= 0 do
            Wait(180 * 4)
            transG = transG - 1
            SetBlipAlpha(blip, transG)
            if transG == 0 then
                SetBlipSprite(blip, 2)
                RemoveBlip(blip)
                return
            end
        end
    end
end)
