local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions' })
local sharedItems = exports['pfm-core']:GetShared('Items')
local SafeCodes = {}
local typeOf = type

-- server-side robbery sessions (PF hardening):
local activeRegisters = {} -- [register] = { src, at }
local safeAttempts = {}    -- [safe] = { src, at }      (padlock minigame claims)
local safeUnlocked = {}    -- [safe] = src              (keypad code entered correctly)
local copsCallCooldown = {} -- [src] = os.time()
-- Keypad guesses: 3 wrong codes lock that safe for the player for 10 minutes (the 4-digit code could
-- be brute-forced before: 9000 guesses, no limit).
local keypadFails = {}      -- [citizenid] = { [safe] = { count, lockedUntil } }
local MAX_KEYPAD_FAILS = 3
local KEYPAD_LOCKOUT = 600
-- The padlock is cracked with a server-judged key challenge (about 18 s to play through); the
-- challenge itself enforces how fast it can be played.
local MIN_PADLOCK_SECONDS = 15
-- Register lockpicking: one attempt per player at a time, judged by pfm-minigames.
local pickAttempts = {}    -- [src] = { register, at (ms), challengeId, item }
local lastPickStart = {}   -- [src] = GetGameTimer()
local PICK_MIN_MS, PICK_MAX_MS = 1000, 60000

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

-- ══ city events ═══════════════════════════════════════════════════
-- A robbery that really started (the server opened a register or a safe) is reported once per store
-- to pf-services: the timeline, a news lead and (police = true) a police dispatch request at the store.
local storeReported = {} -- [safeKey] = os.time() of the last report

local function CityEvent(kind, data, opts)
    if GetResourceState('pf-services') ~= 'started' then return nil end
    local svc = exports['pf-services']
    if not svc then return nil end
    local ok, id = pcall(function() return svc:Emit(kind, data, opts) end)
    return ok and id or nil
end

-- The owner of a player-owned pf-stores shop at this spot hears about it (the robbery loot itself is
-- not taken from the shop: its money lives in its bank account, not in the till).
local function TellStoreOwner(coords, name)
    if GetResourceState('pf-stores') ~= 'started' then return end
    pcall(function()
        local cfg = exports['pf-stores']:GetStoreConfig()
        for storeId, def in pairs((cfg and cfg.Stores) or {}) do
            local c = def.npc and def.npc.coords
            if c and #(vector3(c.x, c.y, c.z) - coords) <= (Config.OwnedStoreRadius or 25.0) then
                local owner = exports['pf-stores']:GetStoreOwner(tostring(def.id or storeId))
                local Owner = type(owner) == 'string' and owner ~= '' and QBCore.Functions.GetPlayerByCitizenId(owner)
                if Owner then
                    TriggerClientEvent('QBCore:Notify', Owner.PlayerData.source, ('Your store %s is being robbed!'):format(def.label or name), 'error', 10000)
                end
                return
            end
        end
    end)
end

local function ReportStoreRobbery(storeKey, coords)
    local now = os.time()
    if storeReported[storeKey] and now - storeReported[storeKey] < (Config.RobberyReportWindow or 900) then return end
    storeReported[storeKey] = now
    local name = (Config.StoreNames and Config.StoreNames[storeKey]) or 'a convenience store'
    coords = vector3(coords.x, coords.y, coords.z)
    CityEvent('crime.robbery.store', { store = name, storeKey = storeKey, location = name, place = name, ref = 'robbery:store:' .. tostring(storeKey),
        details = 'Robbery in progress at ' .. name }, {
        title = 'Store robbery at ' .. name, coords = coords, dedupe = 'store:' .. tostring(storeKey),
    })
    TellStoreOwner(coords, name)
end

-- ══ registers ═════════════════════════════════════════════════════

-- ── server-judged minigames (pfm-minigames) ──────────────────────
local function IssueChallenge(src, kind, opts)
    local ok, ch = pcall(function() return exports['pfm-minigames']:IssueChallenge(src, kind, opts) end)
    if ok and typeOf(ch) == 'table' and typeOf(ch.id) == 'string' then return ch end
    return nil
end

local function ChallengePassed(src, id)
    if typeOf(id) ~= 'string' then return false end
    local ok, passed = pcall(function() return exports['pfm-minigames']:Verify(src, id) end)
    return ok and passed == true
end

local function CancelChallenge(src, id)
    if typeOf(id) ~= 'string' then return end
    pcall(function() exports['pfm-minigames']:Cancel(src, id) end)
end

local function Holds(src, item)
    return item ~= nil and exports['pfm-inventory']:GetItemByName(src, item) ~= nil
end

-- Register lockpicking, all on the server: startRegister checks the player, the register and the pick
-- and sends a pin-lockpick challenge; finishRegister opens the register only when pfm-minigames judged
-- that challenge passed, in time, with the player still there holding the pick. A failed, restarted
-- or abandoned attempt rolls the pick's breakage here (it used to break only when the client asked).
local function PickItem(src, wantAdvanced)
    if wantAdvanced and Holds(src, 'advancedlockpick') then return 'advancedlockpick' end
    if Holds(src, 'lockpick') then return 'lockpick' end
    if Holds(src, 'advancedlockpick') then return 'advancedlockpick' end
    return nil
end

local function FailPick(src, attempt)
    CancelChallenge(src, attempt.challengeId)
    TriggerClientEvent('qb-storerobbery:client:registerResult', src, attempt.register, false)
    if not Holds(src, attempt.item) then return end
    local chance = (Config.LockpickBreakChance or {})[attempt.item] or 0
    if math.random(1, 100) > chance then return end
    if exports['pfm-inventory']:RemoveItem(src, attempt.item, 1, false, 'qb-storerobbery:lockpickBroke') then
        TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems[attempt.item], 'remove')
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.you_broke_the_lock_pick'), 'error')
    end
end

local function RegisterAt(src, register)
    register = tonumber(register)
    local reg = register and Config.Registers[register]
    if not reg then return nil end
    if #(GetEntityCoords(GetPlayerPed(src)) - reg[1].xyz) > 3.0 then return nil end
    return register, reg
end

RegisterNetEvent('qb-storerobbery:server:startRegister', function(register, wantAdvanced)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    local reg
    register, reg = RegisterAt(src, register)
    if not register or reg.robbed or activeRegisters[register] then return end
    local meta = Player.PlayerData.metadata or {}
    if meta.isdead or meta.inlaststand or meta.ishandcuffed then return end
    if GetCopCount() < (Config.MinimumStoreRobberyPolice or 2) then return end
    local now = GetGameTimer()
    if lastPickStart[src] and now - lastPickStart[src] < (Config.LockpickCooldownSeconds or 2) * 1000 then return end
    local item = PickItem(src, wantAdvanced == true)
    if not item then return end
    lastPickStart[src] = now

    -- a new attempt ends the open one as failed (a restart does not dodge the breakage)
    if pickAttempts[src] then
        local old = pickAttempts[src]
        pickAttempts[src] = nil
        FailPick(src, old)
    end

    local ch = IssueChallenge(src, 'lockpick', { pins = Config.RegisterLockpickPins or 1, tag = 'storerobbery:register:' .. register })
    if not ch then return end
    local attempt = { register = register, at = now, challengeId = ch.id, item = item }
    pickAttempts[src] = attempt
    SetTimeout(PICK_MAX_MS + 1000, function()
        if pickAttempts[src] ~= attempt then return end
        pickAttempts[src] = nil
        FailPick(src, attempt)
    end)
    TriggerClientEvent('qb-storerobbery:client:registerChallenge', src, register, ch)
end)

RegisterNetEvent('qb-storerobbery:server:finishRegister', function(register)
    local src = source
    local attempt = pickAttempts[src]
    register = tonumber(register)
    if not attempt or attempt.register ~= register then return end
    pickAttempts[src] = nil -- one finish per attempt

    local passed = ChallengePassed(src, attempt.challengeId)
    local elapsed = GetGameTimer() - attempt.at
    local Player = exports['pfm-core']:GetPlayer(src)
    local _, reg = RegisterAt(src, register)
    if passed and elapsed >= PICK_MIN_MS and elapsed <= PICK_MAX_MS and Player and reg and not reg.robbed
        and not activeRegisters[register] and Holds(src, attempt.item)
        and GetCopCount() >= (Config.MinimumStoreRobberyPolice or 2) then
        reg.robbed = true
        reg.time = Config.resetTime
        activeRegisters[register] = { src = src, at = os.time() }
        TriggerClientEvent('qb-storerobbery:client:setRegisterStatus', -1, register, reg)
        TriggerClientEvent('qb-storerobbery:client:registerResult', src, register, true)
        ReportStoreRobbery(reg.safeKey, reg[1])
        return
    end
    FailPick(src, attempt)
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
        -- a keypad code on a sticky note (padlock safes are cracked with the dial minigame instead)
        if Config.Safes[reg.safeKey].type == 'keypad' and math.random(1, 100) <= Config.stickyNoteChance then
            local info = { label = Lang:t('text.safe_code') .. tostring(SafeCodes[reg.safeKey]) }
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
    local now = os.time()
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then cb(false) return end
    local cid = Player.PlayerData.citizenid -- by character, so reconnecting doesn't reset the lockout
    keypadFails[cid] = keypadFails[cid] or {}
    local fails = keypadFails[cid][safe] or { count = 0, lockedUntil = 0 }
    if now < fails.lockedUntil then
        TriggerClientEvent('QBCore:Notify', src, 'The keypad is locked out. Try again later.', 'error')
        cb(false)
        return
    end
    local correct = tonumber(guess) ~= nil and tonumber(guess) == SafeCodes[safe]
    if correct then
        safeUnlocked[safe] = src
        keypadFails[cid][safe] = nil
    else
        fails.count = fails.count + 1
        if fails.count >= MAX_KEYPAD_FAILS then
            fails = { count = 0, lockedUntil = now + KEYPAD_LOCKOUT }
        end
        keypadFails[cid][safe] = fails
    end
    cb(correct)
end)

-- padlock: the dial is cracked with a key challenge the server issues and judges; the combination
-- never leaves the server (it used to be handed to the client, and the reward paid 20 s later
-- with no proof the dial was ever turned)
local padlockRequests = {} -- [src] = os.time()
QBCore.Functions.CreateCallback('qb-storerobbery:server:startPadlock', function(src, cb, safe)
    safe = tonumber(safe)
    if not CanTouchSafe(src, safe) or Config.Safes[safe].type ~= 'padlock' then
        cb(nil)
        return
    end
    local now = os.time()
    if padlockRequests[src] and now - padlockRequests[src] < 10 then
        cb(nil)
        return
    end
    -- one crack at a time per safe: another player's live attempt is not taken over
    local current = safeAttempts[safe]
    if current and current.src ~= src and now - current.at < 60 then
        cb(nil)
        return
    end
    local ch = IssueChallenge(src, 'keys', {
        amount = Config.PadlockKeys or 12, maxFaults = Config.PadlockMaxFaults or 2, tag = 'storerobbery:safe:' .. safe,
    })
    if not ch then
        cb(nil)
        return
    end
    padlockRequests[src] = now
    if current then CancelChallenge(current.src, current.challengeId) end
    safeAttempts[safe] = { src = src, at = now, challengeId = ch.id }
    cb(ch)
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

    -- only the player who actually opened it can claim: keypad unlock, or this player's padlock
    -- challenge, judged passed by pfm-minigames
    local allowed = safeUnlocked[safe] == src
    if not allowed and safeData.type == 'padlock' then
        local attempt = safeAttempts[safe]
        if not attempt or attempt.src ~= src then return end
        safeAttempts[safe] = nil -- one claim per crack
        allowed = os.time() - attempt.at >= MIN_PADLOCK_SECONDS and ChallengePassed(src, attempt.challengeId)
    end
    if not allowed then return end

    MarkSafeRobbed(safe)
    ReportStoreRobbery(safe, safeData[1])
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
    -- plain text only: the label is shown in every officer's alert UI
    streetLabel = tostring(streetLabel or ''):gsub('[<>]', ''):sub(1, 60)

    local target
    if alertType == 'safe' then
        target = Config.Safes[safe]
    else
        target = Config.Registers[safe]
    end
    local cameraId = target and target.camId
    if not cameraId then return end
    -- the alert must come from the store being robbed (any spot used to work)
    if #(playerCoords - target[1].xyz) > 15.0 then return end

    local alertData = {
        title = '10-33 | Shop Robbery',
        coords = { x = coords.x, y = coords.y, z = coords.z },
        description = Lang:t('email.someone_is_trying_to_rob_a_store', { street = streetLabel, cameraId1 = cameraId })
    }
    TriggerClientEvent('qb-storerobbery:client:robberyCall', -1, alertType, safe, streetLabel, coords)
    TriggerClientEvent('qb-phone:client:addPoliceAlert', -1, alertData)
end)

-- ══ lockpicks ═════════════════════════════════════════════════════

-- Kept as no-ops for old clients: a lockpick breaks only on the server, when an attempt fails.
RegisterNetEvent('qb-storerobbery:server:removeAdvancedLockpick', function() end)
RegisterNetEvent('qb-storerobbery:server:removeLockpick', function() end)

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
    pickAttempts[src] = nil
    lastPickStart[src] = nil
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
