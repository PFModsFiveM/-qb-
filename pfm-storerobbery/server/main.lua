local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions' })
local sharedItems = exports['pfm-core']:GetShared('Items')
local SafeCodes = {}

-- server-side robbery sessions (PF hardening):
local activeRegisters = {} -- [register] = { src, at }
local safeAttempts = {}    -- [safe] = { src, at }      (padlock minigame claims)
local safeUnlocked = {}    -- [safe] = src              (keypad code entered correctly)
local copsCallCooldown = {} -- [src] = os.time()

CreateThread(function()
    while true do
        SafeCodes = {
            [1] = math.random(1000, 9999),
            [2] = { math.random(1, 149), math.random(500.0, 600.0), math.random(360.0, 400), math.random(600.0, 900.0) },
            [3] = { math.random(150, 359), math.random(-300.0, -60.0), math.random(0, 100), math.random(-500.0, -160.0) },
            [4] = math.random(1000, 9999),
            [5] = math.random(1000, 9999),
            [6] = { math.random(1, 149), math.random(150.0, 200.0), math.random(100, 140), math.random(150.0, 220.0), math.random(-100, 100), math.random(140, 300) },
            [7] = math.random(1000, 9999),
            [8] = math.random(1000, 9999),
            [9] = math.random(1000, 9999),
            [10] = { math.random(1, 149), math.random(300.0, 500.0), math.random(200, 260), math.random(500.0, 800.0), math.random(300, 440), math.random(650, 900) },
            [11] = math.random(1000, 9999),
            [12] = math.random(1000, 9999),
            [13] = math.random(1000, 9999),
            [14] = { math.random(150, 450), math.random(-360.0, 0.0), math.random(360, 720) },
            [15] = math.random(1000, 9999),
            [16] = math.random(1000, 9999),
            [17] = math.random(1000, 9999),
            [18] = { math.random(150, 450), math.random(1.0, 100.0), math.random(360, 450), math.random(300.0, 340.0), math.random(350, 400), math.random(320.0, 340.0), math.random(350, 600) },
            [19] = math.random(1000, 9999),
        }
        Wait((1000 * 60) * 40)
    end
end)

-- ══ helpers ═══════════════════════════════════════════════════════

local function GetCopCount()
    local amount = 0
    local players = QBCore.Functions.GetQBPlayers()
    for _, v in pairs(players) do
        if v and v.PlayerData.job.type == 'leo' and v.PlayerData.job.onduty then
            amount += 1
        end
    end
    return amount
end

-- more police online = bigger payouts (risk scales reward)
local function CopLootMultiplier()
    local cfg = Config.CopsLootScaling or {}
    local baseCops = Config.MinimumStoreRobberyPolice or 2
    local extra = math.max(0, GetCopCount() - baseCops)
    local mult = 1.0 + extra * (cfg.PerExtraCop or 0.15)
    return math.min(mult, cfg.MaxMultiplier or 1.6)
end

local function RollCash(range)
    local mult = CopLootMultiplier()
    return math.floor(math.random(range.min, range.max) * mult)
end

local function GiveMarkedBills(src, bags, range)
    local info = { worth = RollCash(range) }
    exports['pfm-inventory']:AddItem(src, 'markedbills', bags, false, info, 'qb-storerobbery:reward')
    TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems['markedbills'], 'add')
end

-- ══ registers ═════════════════════════════════════════════════════

-- the lockpick minigame succeeded: validate everything server-side and open a session
RegisterNetEvent('qb-storerobbery:server:setRegisterStatus', function(register)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    register = tonumber(register)
    local reg = register and Config.Registers[register]
    if not reg then return end
    local playerCoords = GetEntityCoords(GetPlayerPed(src))
    if #(playerCoords - reg[1].xyz) > 3.0 then return DropPlayer(src, 'Attempted exploit abuse') end
    if reg.robbed then return end
    if GetCopCount() < (Config.MinimumStoreRobberyPolice or 2) then return end
    if not Player.GetItemByName('lockpick') and not Player.GetItemByName('advancedlockpick') then return end

    reg.robbed = true
    reg.time = Config.resetTime
    activeRegisters[register] = { src = src, at = os.time() }
    TriggerClientEvent('qb-storerobbery:client:setRegisterStatus', -1, register, reg)
end)

RegisterNetEvent('qb-storerobbery:server:takeMoney', function(register, isDone)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    register = tonumber(register)
    local reg = register and Config.Registers[register]
    if not reg then return end
    local playerCoords = GetEntityCoords(GetPlayerPed(src))
    if #(playerCoords - reg[1].xyz) > 3.0 then return DropPlayer(src, 'Attempted exploit abuse') end

    local session = activeRegisters[register]
    if not session or session.src ~= src then return end

    if isDone then
        -- the emptying progressbar runs 25s; anything quicker is scripted
        if os.time() - session.at < 20 then return DropPlayer(src, 'Attempted exploit abuse') end
        activeRegisters[register] = nil
        GiveMarkedBills(src, math.random(1, 3), Config.RegisterCash)
        if math.random(1, 100) <= Config.stickyNoteChance then
            local code = SafeCodes[reg.safeKey]
            local info
            if Config.Safes[reg.safeKey].type == 'keypad' then
                info = { label = Lang:t('text.safe_code') .. tostring(code) }
            else
                local label = Lang:t('text.safe_code') .. ' '
                for i = 1, #code do
                    label = label .. tostring(math.floor((code[i] % 360) / 3.60)) .. ' - '
                end
                info = { label = label:sub(1, -3) }
            end
            exports['pfm-inventory']:AddItem(src, 'stickynote', 1, false, info, 'qb-storerobbery:server:takeMoney')
            TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems['stickynote'], 'add')
        end
    end
end)

-- ══ safes ═════════════════════════════════════════════════════════

local function CanTouchSafe(src, safe)
    local safeData = safe and Config.Safes[safe]
    if not safeData then return false end
    local playerCoords = GetEntityCoords(GetPlayerPed(src))
    if #(playerCoords - safeData[1].xyz) > 3.0 then return false end
    if safeData.robbed then return false end
    if GetCopCount() < (Config.MinimumStoreRobberyPolice or 2) then return false end
    return true
end

local function MarkSafeRobbed(safe)
    Config.Safes[safe].robbed = true
    safeUnlocked[safe] = nil
    safeAttempts[safe] = nil
    TriggerClientEvent('qb-storerobbery:client:setSafeStatus', -1, safe, true)
    SetTimeout(math.random(40, 80) * (60 * 1000), function()
        Config.Safes[safe].robbed = false
        TriggerClientEvent('qb-storerobbery:client:setSafeStatus', -1, safe, false)
    end)
end

-- keypad: the guess is validated here - the code NEVER leaves the server
QBCore.Functions.CreateCallback('qb-storerobbery:server:isCombinationRight', function(src, cb, safe, guess)
    safe = tonumber(safe)
    if not CanTouchSafe(src, safe) then
        cb(false)
        return
    end
    local correct = tonumber(guess) ~= nil and tonumber(guess) == SafeCodes[safe]
    if correct then
        safeUnlocked[safe] = src
    end
    cb(correct)
end)

-- padlock: the dial minigame needs the combination client-side, but only
-- with an active, rate-limited, in-range attempt on an unrobbed safe
local padlockRequests = {} -- [src] = os.time()
QBCore.Functions.CreateCallback('qb-storerobbery:server:getPadlockCombination', function(src, cb, safe)
    safe = tonumber(safe)
    if not CanTouchSafe(src, safe) then
        cb(nil)
        return
    end
    local now = os.time()
    if padlockRequests[src] and now - padlockRequests[src] < 10 then
        cb(nil)
        return
    end
    padlockRequests[src] = now
    safeAttempts[safe] = { src = src, at = now }
    cb(SafeCodes[safe])
end)

RegisterNetEvent('qb-storerobbery:server:SafeReward', function(safe)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    safe = tonumber(safe)
    local safeData = safe and Config.Safes[safe]
    if not safeData then return end
    local playerCoords = GetEntityCoords(GetPlayerPed(src))
    if #(playerCoords - safeData[1].xyz) > 3.0 or safeData.robbed then
        return DropPlayer(src, 'Attempted exploit abuse')
    end

    -- only the player who actually opened it can claim: keypad unlock,
    -- or an active padlock attempt old enough for the minigame to have run
    local attempt = safeAttempts[safe]
    local allowed = safeUnlocked[safe] == src
        or (attempt and attempt.src == src and os.time() - attempt.at >= 10)
    if not allowed then return end

    MarkSafeRobbed(safe)
    GiveMarkedBills(src, math.random(1, 3), Config.SafeCash)
    local luck = math.random(1, 100)
    local odd = math.random(1, 100)
    if luck <= 10 then
        exports['pfm-inventory']:AddItem(src, 'rolex', math.random(3, 7), false, false, 'qb-storerobbery:server:SafeReward')
        TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems['rolex'], 'add')
        if luck == odd then
            Wait(500)
            exports['pfm-inventory']:AddItem(src, 'goldbar', 1, false, false, 'qb-storerobbery:server:SafeReward')
            TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems['goldbar'], 'add')
        end
    end
end)

-- kept for client compatibility: the server now marks safes robbed itself
RegisterNetEvent('qb-storerobbery:server:setSafeStatus', function() end)

-- ══ alerts ════════════════════════════════════════════════════════

RegisterNetEvent('qb-storerobbery:server:callCops', function(alertType, safe, streetLabel, coords)
    local src = source
    if alertType ~= 'safe' and alertType ~= 'cashier' then return end
    safe = tonumber(safe)
    if not safe then return end
    local now = os.time()
    if copsCallCooldown[src] and now - copsCallCooldown[src] < 30 then return end
    copsCallCooldown[src] = now

    -- the alert location must be where the player actually is
    local playerCoords = GetEntityCoords(GetPlayerPed(src))
    if type(coords) ~= 'vector3' then
        if type(coords) == 'table' and coords.x and coords.y and coords.z then
            coords = vector3(coords.x + 0.0, coords.y + 0.0, coords.z + 0.0)
        else
            return
        end
    end
    if #(playerCoords - coords) > 50.0 then return end
    streetLabel = tostring(streetLabel or ''):sub(1, 60)

    local cameraId
    if alertType == 'safe' then
        cameraId = Config.Safes[safe] and Config.Safes[safe].camId
    else
        cameraId = Config.Registers[safe] and Config.Registers[safe].camId
    end
    if not cameraId then return end

    local alertData = {
        title = '10-33 | Shop Robbery',
        coords = { x = coords.x, y = coords.y, z = coords.z },
        description = Lang:t('email.someone_is_trying_to_rob_a_store', { street = streetLabel, cameraId1 = cameraId })
    }
    TriggerClientEvent('qb-storerobbery:client:robberyCall', -1, alertType, safe, streetLabel, coords)
    TriggerClientEvent('qb-phone:client:addPoliceAlert', -1, alertData)
end)

-- ══ lockpicks ═════════════════════════════════════════════════════

RegisterNetEvent('qb-storerobbery:server:removeAdvancedLockpick', function()
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player then return end
    exports['pfm-inventory']:RemoveItem(source, 'advancedlockpick', 1, false, 'qb-storerobbery:server:removeAdvancedLockpick')
end)

RegisterNetEvent('qb-storerobbery:server:removeLockpick', function()
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player then return end
    exports['pfm-inventory']:RemoveItem(source, 'lockpick', 1, false, 'qb-storerobbery:server:removeLockpick')
end)

-- ══ register reset ticker ═════════════════════════════════════════

CreateThread(function()
    while true do
        local toSend = {}
        for k in ipairs(Config.Registers) do
            if Config.Registers[k].time > 0 and (Config.Registers[k].time - Config.tickInterval) >= 0 then
                Config.Registers[k].time = Config.Registers[k].time - Config.tickInterval
            else
                if Config.Registers[k].robbed then
                    Config.Registers[k].time = 0
                    Config.Registers[k].robbed = false
                    activeRegisters[k] = nil
                    toSend[#toSend + 1] = Config.Registers[k]
                end
            end
        end

        if #toSend > 0 then
            TriggerClientEvent('qb-storerobbery:client:setRegisterStatus', -1, toSend, false)
        end

        Wait(Config.tickInterval)
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    copsCallCooldown[src] = nil
    padlockRequests[src] = nil
    for k, v in pairs(activeRegisters) do
        if v.src == src then activeRegisters[k] = nil end
    end
    for k, v in pairs(safeAttempts) do
        if v.src == src then safeAttempts[k] = nil end
    end
    for k, v in pairs(safeUnlocked) do
        if v == src then safeUnlocked[k] = nil end
    end
end)

-- ══ status callbacks ══════════════════════════════════════════════

QBCore.Functions.CreateCallback('qb-storerobbery:server:getRegisterStatus', function(_, cb)
    cb(Config.Registers)
end)

QBCore.Functions.CreateCallback('qb-storerobbery:server:getSafeStatus', function(_, cb)
    cb(Config.Safes)
end)
