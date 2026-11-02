local sharedItems = exports['pfm-core']:GetShared('Items')

local function IsOnDutyLeo(Player)
    return Player and Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty
end

-- City events (pf-services): a jail sentence is a court record the newsroom may cover (news lead).
-- Only public facts go out: the name, the sentence length, the prison.
local function CityEvent(kind, data, opts)
    if GetResourceState('pf-services') ~= 'started' then return nil end
    local svc = exports['pf-services']
    if not svc then return nil end
    local ok, id = pcall(function() return svc:Emit(kind, data, opts) end)
    return ok and id or nil
end

-- seized cash is held here until an officer opens the evidence bag (server/main.lua pays from it)
EVIDENCE_ACCOUNT = 'system:pfm-policejob-evidence'

-- A search or robbery starts only within this distance, and pfm-inventory ends it as soon as the two
-- are further apart (the searcher can no longer take items from a distance).
local SEARCH_REACH = 2.5

RegisterNetEvent('police:server:SearchPlayer', function()
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if not IsOnDutyLeo(Player) then return end
    local player, distance = QBCore.Functions.GetClosestPlayer(src)
    if player ~= -1 and distance < SEARCH_REACH then
        local SearchedPlayer = exports['pfm-core']:GetPlayer(tonumber(player))
        if not SearchedPlayer then return end
        -- nothing to report when the search did not open (e.g. one of them stepped away meanwhile)
        if not exports['pfm-inventory']:OpenInventoryById(src, tonumber(player), { reach = SEARCH_REACH }) then return end
        TriggerClientEvent('QBCore:Notify', src, Lang:t('info.cash_found', { cash = SearchedPlayer.PlayerData.money['cash'] }))
        TriggerClientEvent('QBCore:Notify', player, Lang:t('info.being_searched'))
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.none_nearby'), 'error')
    end
end)

-- ── Handcuffs ─────────────────────────────────────────────────────
-- The server owns the cuff state: metadata 'ishandcuffed' (what inventory, trunk, vehicle and robbery
-- checks read), the state bag 'handcuffed', and Cuffs below. The client is told the state
-- (police:client:SetCuffed) and never reports it: a cuffed client used to send
-- police:server:SetHandcuffStatus(false) and was free on the server while still shown cuffed.
-- Cuffs put on by an on-duty officer come back after a relog (within RelogMinutes); cuffs put on by
-- anyone else with a handcuffs item come off by themselves after CivilianCuffMinutes, so a player
-- left cuffed by a robber is not stuck.
local Cuffs = {}        -- [targetSrc] = { soft, by = officerSrc, leo = bool, at = os.time() }
local CuffRecords = {}  -- [citizenid] = { soft, leo, at }: kept across a drop for the relog
local pendingCuffs = {} -- [targetSrc] = { officer, soft, nonce, startedAt, deadline, presses }
local resistCooldowns = {} -- [officerSrc] = GetGameTimer() of the last resisted attempt
local resistImmuneUntil = {} -- [targetSrc] = GetGameTimer(): a suspect who just broke free cannot resist again before
local MIN_PRESS_MS = 80 -- no human mashes faster than this per press

local function gameplayCfg() return Config.Gameplay or {} end
local function resistCfg() return gameplayCfg().ResistCuff or {} end

local function setStateBag(src, key, value)
    pcall(function() Player(src).state:set(key, value, true) end)
end

--- Puts cuffs on (cuffed = true) or takes them off a player, on the server. opts: soft, by (the
--- cuffing player's source, for the paired animation), leo (cuffed by an on-duty officer).
--- @return boolean ok
function PoliceSetCuffed(target, cuffed, opts)
    opts = opts or {}
    target = tonumber(target)
    local T = target and exports['pfm-core']:GetPlayer(target)
    if not T then return false end
    cuffed = cuffed == true
    local cid = T.PlayerData.citizenid
    T.Functions.SetMetaData('ishandcuffed', cuffed)
    setStateBag(target, 'handcuffed', cuffed)
    if cuffed then
        local rec = { soft = opts.soft == true, by = tonumber(opts.by) or -1, leo = opts.leo == true, at = tonumber(opts.at) or os.time() }
        Cuffs[target] = rec
        CuffRecords[cid] = { soft = rec.soft, leo = rec.leo, at = rec.at }
    else
        Cuffs[target] = nil
        CuffRecords[cid] = nil
        pendingCuffs[target] = nil
    end
    TriggerClientEvent('police:client:SetCuffed', target, cuffed, opts.soft == true, tonumber(opts.by) or -1)
    return true
end

--- exports['pfm-policejob']:SetCuffed(src, cuffed, reason) for other server resources (a jail, an
--- unjail, a revive that frees the player). Taking cuffs off needs no officer; putting them on from
--- here counts as police cuffs.
exports('SetCuffed', function(src, cuffed, reason)
    return PoliceSetCuffed(src, cuffed == true, { leo = true, reason = type(reason) == 'string' and reason or nil })
end)
exports('IsCuffed', function(src)
    local T = exports['pfm-core']:GetPlayer(tonumber(src))
    return T ~= nil and T.PlayerData.metadata['ishandcuffed'] == true
end)

-- Cuffs on when the target is free, off when cuffed: decided from the server's own state.
local function ApplyCuff(officerSrc, targetSrc, isSoftcuff)
    local T = exports['pfm-core']:GetPlayer(targetSrc)
    local O = exports['pfm-core']:GetPlayer(officerSrc)
    if not T or not O then return end
    local cuffing = T.PlayerData.metadata['ishandcuffed'] ~= true
    PoliceSetCuffed(targetSrc, cuffing, { soft = isSoftcuff, by = officerSrc, leo = IsOnDutyLeo(O) })
    TriggerClientEvent('police:client:CuffAnimation', officerSrc, cuffing)
end

local nonceCounter = 0
local function NewNonce()
    nonceCounter = nonceCounter + 1
    return ('%d-%d'):format(nonceCounter, math.random(100000, 999999))
end

RegisterNetEvent('police:server:CuffPlayer', function(playerId, isSoftcuff)
    local src = source
    playerId = tonumber(playerId)
    if not playerId or playerId == src then return end
    local playerPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(playerId)
    local playerCoords = GetEntityCoords(playerPed)
    local targetCoords = GetEntityCoords(targetPed)
    if #(playerCoords - targetCoords) > 2.5 then return DropPlayer(src, 'Attempted exploit abuse') end

    local Player = exports['pfm-core']:GetPlayer(src)
    local CuffedPlayer = exports['pfm-core']:GetPlayer(playerId)
    if not Player or not CuffedPlayer then return end
    local leo = IsOnDutyLeo(Player)
    if not leo and not Player.GetItemByName('handcuffs') then return end
    isSoftcuff = isSoftcuff == true

    local target = CuffedPlayer.PlayerData.source
    local cfg = resistCfg()
    local meta = CuffedPlayer.PlayerData.metadata
    local now = GetGameTimer()
    -- a softcuff skips the resist window only for an on-duty officer (anyone with a handcuffs item
    -- could softcuff a standing player and rob them with no chance to resist)
    local canResist = cfg.Enabled
        and not (isSoftcuff and leo)
        and meta['ishandcuffed'] ~= true            -- uncuffing is never resisted
        and not meta['isdead'] and not meta['inlaststand']
        and not (resistImmuneUntil[target] and now < resistImmuneUntil[target])

    if not canResist then
        ApplyCuff(src, target, isSoftcuff)
        return
    end

    if resistCooldowns[src] and now - resistCooldowns[src] < (cfg.OfficerCooldown or 4000) then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.resist_cooldown'), 'error')
        return
    end
    if pendingCuffs[target] then return end

    local window = cfg.Window or 3000
    local presses = cfg.PressesNeeded or 10
    local nonce = NewNonce()
    pendingCuffs[target] = { officer = src, soft = isSoftcuff, nonce = nonce, startedAt = now, deadline = now + window, presses = presses }
    TriggerClientEvent('police:client:ResistCuff', target, src, window, presses, nonce)
    -- safety net: if the suspect's client never answers, the cuff lands anyway
    SetTimeout(window + 2000, function()
        local pending = pendingCuffs[target]
        if pending and pending.nonce == nonce then
            pendingCuffs[target] = nil
            ApplyCuff(src, target, isSoftcuff)
        end
    end)
end)

-- The suspect's answer. It must carry the attempt's nonce and arrive no faster than the presses
-- could be made and before the window closed; then the press only earns a roll the server makes
-- (Config.Gameplay.ResistCuff.Chance). A client answering "resisted" the moment the prompt arrived
-- used to make itself impossible to hardcuff.
RegisterNetEvent('police:server:ResistResult', function(nonce, resisted)
    local src = source
    local pending = pendingCuffs[src]
    if not pending or nonce ~= pending.nonce then return end
    pendingCuffs[src] = nil

    local cfg = resistCfg()
    local officer = pending.officer
    local now = GetGameTimer()
    local elapsed = now - pending.startedAt
    -- (1.5 s on top of the window for the answer's trip over the network)
    local inTime = elapsed >= pending.presses * MIN_PRESS_MS and now <= pending.deadline + 1500
    local officerPed = GetPlayerPed(officer)
    local targetPed = GetPlayerPed(src)
    local stillClose = officerPed and targetPed and #(GetEntityCoords(officerPed) - GetEntityCoords(targetPed)) <= 5.0
    local broke = resisted == true and inTime and stillClose and math.random() < (tonumber(cfg.Chance) or 0.5)

    if broke then
        resistCooldowns[officer] = now
        resistImmuneUntil[src] = now + (tonumber(cfg.Immunity) or 25000)
        TriggerClientEvent('police:client:ResistOutcome', src, true)
        TriggerClientEvent('QBCore:Notify', officer, Lang:t('error.suspect_resisted'), 'error')
        TriggerClientEvent('QBCore:Notify', src, Lang:t('success.resisted_cuff'), 'success')
    else
        if resisted == true then TriggerClientEvent('police:client:ResistOutcome', src, false) end
        ApplyCuff(officer, src, pending.soft)
    end
end)

-- Relog: police cuffs put on within RelogMinutes come back; anything else comes off.
AddEventHandler('QBCore:Server:PlayerLoaded', function(LoadedPlayer)
    local data = type(LoadedPlayer) == 'table' and LoadedPlayer.PlayerData
    if not data or not data.source then return end
    local cid = data.citizenid
    local rec = cid and CuffRecords[cid]
    local relogSeconds = (tonumber(gameplayCfg().RelogCuffMinutes) or 30) * 60
    if rec and rec.leo and os.time() - rec.at <= relogSeconds then
        PoliceSetCuffed(data.source, true, { soft = rec.soft, leo = true, at = rec.at })
    elseif (data.metadata or {})['ishandcuffed'] then
        PoliceSetCuffed(data.source, false)
    end
end)

-- A player respawning at the hospital loses the cuffs (the respawn used to uncuff on the client
-- only). pf-ambulancejob handles the respawn itself; this only frees a downed, cuffed player.
RegisterNetEvent('hospital:server:RespawnAtHospital', function()
    local src = source
    local T = exports['pfm-core']:GetPlayer(src)
    if not T then return end
    local meta = T.PlayerData.metadata
    if meta['ishandcuffed'] and (meta['isdead'] or meta['inlaststand']) then
        PoliceSetCuffed(src, false)
    end
end)

--- Cuffs put on by someone who is not an on-duty officer come off after CivilianCuffMinutes, and
--- relog records expire (called every minute; also used by tests).
function PoliceCuffSweep()
    local now = os.time()
    local civSeconds = (tonumber(gameplayCfg().CivilianCuffMinutes) or 10) * 60
    for target, rec in pairs(Cuffs) do
        if not rec.leo and now - rec.at >= civSeconds then
            PoliceSetCuffed(target, false)
            TriggerClientEvent('QBCore:Notify', target, 'You slipped out of the cuffs', 'success')
        end
    end
    local relogSeconds = (tonumber(gameplayCfg().RelogCuffMinutes) or 30) * 60
    for cid, rec in pairs(CuffRecords) do
        if now - rec.at > relogSeconds then CuffRecords[cid] = nil end
    end
end

CreateThread(function()
    while true do
        Wait(60000)
        PoliceCuffSweep()
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    pendingCuffs[src] = nil
    resistCooldowns[src] = nil
    resistImmuneUntil[src] = nil
    Cuffs[src] = nil -- CuffRecords keeps a police cuff for the relog
end)

RegisterNetEvent('police:server:EscortPlayer', function(playerId)
    local src = source
    local playerPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(playerId)
    local playerCoords = GetEntityCoords(playerPed)
    local targetCoords = GetEntityCoords(targetPed)
    if #(playerCoords - targetCoords) > 2.5 then return DropPlayer(src, 'Attempted exploit abuse') end

    local Player = exports['pfm-core']:GetPlayer(source)
    local EscortPlayer = exports['pfm-core']:GetPlayer(playerId)
    if not Player or not EscortPlayer then return end

    if ((Player.PlayerData.job.type == 'leo' or Player.PlayerData.job.name == 'ambulance') and Player.PlayerData.job.onduty) or (EscortPlayer.PlayerData.metadata['ishandcuffed'] or EscortPlayer.PlayerData.metadata['isdead'] or EscortPlayer.PlayerData.metadata['inlaststand']) then
        TriggerClientEvent('police:client:GetEscorted', EscortPlayer.PlayerData.source, Player.PlayerData.source)
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_cuffed_dead'), 'error')
    end
end)

RegisterNetEvent('police:server:KidnapPlayer', function(playerId)
    local src = source
    local playerPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(playerId)
    local playerCoords = GetEntityCoords(playerPed)
    local targetCoords = GetEntityCoords(targetPed)
    if #(playerCoords - targetCoords) > 2.5 then return DropPlayer(src, 'Attempted exploit abuse') end

    local Player = exports['pfm-core']:GetPlayer(source)
    local EscortPlayer = exports['pfm-core']:GetPlayer(playerId)
    if not Player or not EscortPlayer then return end

    if EscortPlayer.PlayerData.metadata['ishandcuffed'] or EscortPlayer.PlayerData.metadata['isdead'] or EscortPlayer.PlayerData.metadata['inlaststand'] then
        TriggerClientEvent('police:client:GetKidnappedTarget', EscortPlayer.PlayerData.source, Player.PlayerData.source)
        TriggerClientEvent('police:client:GetKidnappedDragger', Player.PlayerData.source, EscortPlayer.PlayerData.source)
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_cuffed_dead'), 'error')
    end
end)

RegisterNetEvent('police:server:SetPlayerOutVehicle', function(playerId)
    local src = source
    local playerPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(playerId)
    local playerCoords = GetEntityCoords(playerPed)
    local targetCoords = GetEntityCoords(targetPed)
    if #(playerCoords - targetCoords) > 2.5 then return DropPlayer(src, 'Attempted exploit abuse') end

    local EscortPlayer = exports['pfm-core']:GetPlayer(playerId)
    if not exports['pfm-core']:GetPlayer(src) or not EscortPlayer then return end

    if EscortPlayer.PlayerData.metadata['ishandcuffed'] or EscortPlayer.PlayerData.metadata['isdead'] then
        TriggerClientEvent('police:client:SetOutVehicle', EscortPlayer.PlayerData.source)
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_cuffed_dead'), 'error')
    end
end)

RegisterNetEvent('police:server:PutPlayerInVehicle', function(playerId)
    local src = source
    local playerPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(playerId)
    local playerCoords = GetEntityCoords(playerPed)
    local targetCoords = GetEntityCoords(targetPed)
    if #(playerCoords - targetCoords) > 2.5 then return DropPlayer(src, 'Attempted exploit abuse') end

    local EscortPlayer = exports['pfm-core']:GetPlayer(playerId)
    if not exports['pfm-core']:GetPlayer(src) or not EscortPlayer then return end

    if EscortPlayer.PlayerData.metadata['ishandcuffed'] or EscortPlayer.PlayerData.metadata['isdead'] then
        TriggerClientEvent('police:client:PutInVehicle', EscortPlayer.PlayerData.source)
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_cuffed_dead'), 'error')
    end
end)

RegisterNetEvent('police:server:BillPlayer', function(playerId, price)
    local src = source
    playerId = tonumber(playerId)
    if not playerId then return end
    local playerPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(playerId)
    local playerCoords = GetEntityCoords(playerPed)
    local targetCoords = GetEntityCoords(targetPed)
    if #(playerCoords - targetCoords) > 2.5 then return DropPlayer(src, 'Attempted exploit abuse') end

    local Player = exports['pfm-core']:GetPlayer(src)
    local OtherPlayer = exports['pfm-core']:GetPlayer(playerId)
    if not Player or not OtherPlayer or not IsOnDutyLeo(Player) then return end
    if Player.PlayerData.citizenid == OtherPlayer.PlayerData.citizenid then return end

    price = tonumber(price)
    if not price or price <= 0 or price ~= price or price == math.huge then return end
    price = math.floor(price)
    if price > (Config.MaxFine or 50000) then return end

    -- one ledger transfer from the player's bank to the officer's department (it used to be taken
    -- into this resource's account and credited in a second step that nothing checked or retried)
    local society = Player.PlayerData.job.name
    local key = ('pfm-policejob:bill:%s:%s'):format(OtherPlayer.PlayerData.citizenid, PFPayout.NewId())
    local paid, res = PFPayout.Charge(OtherPlayer, 'bank', price, { key = key, to = 'society:' .. society, kind = 'fine', reason = 'Police bill', quiet = true })
    if not paid then
        -- unclear: the money may have left; the ledger settles it, so the officer must not bill again
        if type(res) == 'table' and res.unclear then
            TriggerClientEvent('QBCore:Notify', src, 'The bank is still processing this bill. Do not bill again; check later.', 'error')
        else
            TriggerClientEvent('QBCore:Notify', src, 'They cannot pay this bill', 'error')
        end
        return
    end
    TriggerClientEvent('QBCore:Notify', OtherPlayer.PlayerData.source, Lang:t('info.fine_received', { fine = price }))
end)

RegisterNetEvent('police:server:JailPlayer', function(playerId, time)
    local src = source
    playerId = tonumber(playerId)
    if not playerId or playerId == src then return end
    local playerPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(playerId)
    local playerCoords = GetEntityCoords(playerPed)
    local targetCoords = GetEntityCoords(targetPed)
    if #(playerCoords - targetCoords) > 2.5 then return DropPlayer(src, 'Attempted exploit abuse') end

    local Player = exports['pfm-core']:GetPlayer(src)
    local OtherPlayer = exports['pfm-core']:GetPlayer(playerId)
    if not Player or not OtherPlayer or not IsOnDutyLeo(Player) then return end

    time = tonumber(time)
    if not time or time <= 0 or time ~= time or time == math.huge then return end
    time = math.floor(time)
    if time > (Config.MaxJailTime or 1440) then time = Config.MaxJailTime or 1440 end

    -- pfm-prison jails on the server: it stores and clears the items in one step, counts the time
    -- down and decides the release (the client used to do all of that)
    if GetResourceState('pfm-prison') ~= 'started' then
        TriggerClientEvent('QBCore:Notify', src, 'The prison is not available right now', 'error')
        return
    end
    local target = OtherPlayer.PlayerData.source
    -- the cuffs come off on the server first; the client drops the escort
    PoliceSetCuffed(target, false)
    TriggerClientEvent('police:client:SendToJail', target, time)
    local ok, jailed, err = pcall(function()
        return exports['pfm-prison']:JailPlayer(target, time, { officer = src })
    end)
    if not ok or not jailed then
        TriggerClientEvent('QBCore:Notify', src, ('The prison could not take them (%s)'):format(tostring(ok and err or 'error')), 'error')
        return
    end

    local currentDate = os.date('*t')
    if currentDate.day == 31 then
        currentDate.day = 30
    end
    OtherPlayer.Functions.SetMetaData('criminalrecord', {
        ['hasRecord'] = true,
        ['date'] = currentDate
    })
    TriggerClientEvent('QBCore:Notify', src, Lang:t('info.sent_jail_for', { time = time }))
    local ci = OtherPlayer.PlayerData.charinfo or {}
    local name = ((ci.firstname or '') .. ' ' .. (ci.lastname or '')):gsub('^%s+', ''):gsub('%s+$', '')
    if name == '' then name = 'A suspect' end
    CityEvent('police.sentenced', { name = name, months = time, place = 'Bolingbroke Penitentiary', by = 'police' }, {
        title = ('%s sentenced to %d months'):format(name, time), actor = Player.PlayerData.citizenid,
        dedupe = OtherPlayer.PlayerData.citizenid,
    })
end)

RegisterNetEvent('police:server:SeizeCash', function(playerId)
    local src = source
    local playerPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(playerId)
    local playerCoords = GetEntityCoords(playerPed)
    local targetCoords = GetEntityCoords(targetPed)
    if #(playerCoords - targetCoords) > 2.5 then return DropPlayer(src, 'Attempted exploit abuse') end
    local Player = exports['pfm-core']:GetPlayer(src)
    local SearchedPlayer = exports['pfm-core']:GetPlayer(playerId)
    if not Player or not SearchedPlayer then return end
    if not IsOnDutyLeo(Player) then return end
    local moneyAmount = math.floor(tonumber(SearchedPlayer.PlayerData.money['cash']) or 0)
    if moneyAmount <= 0 then return end
    -- The cash goes to the police evidence account and the bag carries an id; opening the bag pays
    -- out of that account once per bag (a duplicated bag cannot pay twice).
    local bagId = PFPayout.NewId()
    local key = 'pfm-policejob:seize:' .. bagId
    if not PFPayout.Charge(SearchedPlayer, 'cash', moneyAmount, { key = key, to = EVIDENCE_ACCOUNT, kind = 'seizure', reason = 'Cash seized by police', quiet = true }) then return end
    local info = { cash = moneyAmount, bag = bagId }
    if not exports['pfm-inventory']:AddItem(src, 'moneybag', 1, false, info, 'police:server:SeizeCash') then
        PFPayout.Transfer({ from = EVIDENCE_ACCOUNT, to = ('player:%s:cash'):format(SearchedPlayer.PlayerData.citizenid), amount = moneyAmount, key = key .. ':returned', kind = 'refund', reason = 'Seizure undone' })
        TriggerClientEvent('QBCore:Notify', src, 'Your inventory is full', 'error')
        return
    end
    TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems['moneybag'], 'add')
    TriggerClientEvent('QBCore:Notify', SearchedPlayer.PlayerData.source, Lang:t('info.cash_confiscated'))
end)

RegisterNetEvent('police:server:SeizeDriverLicense', function(playerId)
    local src = source
    local playerPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(playerId)
    local playerCoords = GetEntityCoords(playerPed)
    local targetCoords = GetEntityCoords(targetPed)
    if #(playerCoords - targetCoords) > 2.5 then return DropPlayer(src, 'Attempted exploit abuse') end

    local Player = exports['pfm-core']:GetPlayer(src)
    local SearchedPlayer = exports['pfm-core']:GetPlayer(playerId)
    if not Player or not SearchedPlayer then return end
    if not IsOnDutyLeo(Player) then return end

    local driverLicense = SearchedPlayer.PlayerData.metadata['licences']['driver']
    if driverLicense then
        local licenses = { ['driver'] = false, ['business'] = SearchedPlayer.PlayerData.metadata['licences']['business'] }
        SearchedPlayer.Functions.SetMetaData('licences', licenses)
        TriggerClientEvent('QBCore:Notify', SearchedPlayer.PlayerData.source, Lang:t('info.driving_license_confiscated'))
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.no_driver_license'), 'error')
    end
end)

RegisterNetEvent('police:server:RobPlayer', function(playerId)
    local src = source
    local playerPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(playerId)
    local playerCoords = GetEntityCoords(playerPed)
    local targetCoords = GetEntityCoords(targetPed)
    if #(playerCoords - targetCoords) > SEARCH_REACH then return DropPlayer(src, 'Attempted exploit abuse') end

    local Player = exports['pfm-core']:GetPlayer(src)
    local SearchedPlayer = exports['pfm-core']:GetPlayer(playerId)
    if not Player or not SearchedPlayer then return end
    if not (SearchedPlayer.PlayerData.metadata['ishandcuffed'] or SearchedPlayer.PlayerData.metadata['isdead'] or SearchedPlayer.PlayerData.metadata['inlaststand']) then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_cuffed_dead'), 'error')
        return
    end

    -- one ledger transfer from the victim's cash to the robber's (the robber used to be paid first,
    -- then the victim's cash taken, as two separate steps)
    local money = math.floor(tonumber(SearchedPlayer.PlayerData.money['cash']) or 0)
    if money > 0 then
        local res = PFPayout.Transfer({
            from = ('player:%s:cash'):format(SearchedPlayer.PlayerData.citizenid), to = ('player:%s:cash'):format(Player.PlayerData.citizenid),
            amount = money, key = ('pfm-policejob:rob:%s:%s'):format(SearchedPlayer.PlayerData.citizenid, PFPayout.NewId()),
            kind = 'robbery', reason = 'Robbed', actor = Player.PlayerData.citizenid,
        })
        if not res.ok then money = 0 end
    end
    exports['pfm-inventory']:OpenInventoryById(src, playerId, { reach = SEARCH_REACH })
    TriggerClientEvent('QBCore:Notify', SearchedPlayer.PlayerData.source, Lang:t('info.cash_robbed', { money = money }))
    TriggerClientEvent('QBCore:Notify', Player.PlayerData.source, Lang:t('info.stolen_money', { stolen = money }))
end)
