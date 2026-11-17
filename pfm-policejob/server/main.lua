-- Variables
QBCore = exports['pfm-core']:GetCoreObject({ 'Functions', 'Commands' })
local sharedWeapons = exports['pfm-core']:GetShared('Weapons')

local function Eq() return Config.Equipment or {} end

-- Functions

local function OnDutyOfType(P, types)
    return P ~= nil and P.PlayerData.job ~= nil and types[P.PlayerData.job.type] == true and P.PlayerData.job.onduty == true
end

local function BlipJobs() return (Eq().Blips or {}).Jobs or { leo = true, ems = true } end

--- On-duty leo/ems with their position, callsign and job.
local function DutyBlipList()
    local dutyPlayers, recipients = {}, {}
    local types = BlipJobs()
    for _, v in pairs(QBCore.Functions.GetQBPlayers()) do
        if OnDutyOfType(v, types) then
            local src = v.PlayerData.source
            local ped = GetPlayerPed(src)
            local coords = GetEntityCoords(ped)
            dutyPlayers[#dutyPlayers + 1] = {
                source = src,
                label = v.PlayerData.metadata['callsign'],
                job = v.PlayerData.job.name,
                location = { x = coords.x, y = coords.y, z = coords.z, w = GetEntityHeading(ped) },
            }
            recipients[#recipients + 1] = src
        end
    end
    return dutyPlayers, recipients
end

--- Sends the duty GPS to on-duty leo/ems only (every 5 s). It used to go to every client (-1), so
--- any player could read where every officer and medic was.
function PolicePushDutyBlips()
    local list, recipients = DutyBlipList()
    for _, src in ipairs(recipients) do
        TriggerClientEvent('police:client:UpdateBlips', src, list)
    end
    return #recipients
end

local function GetCurrentCops()
    local amount = 0
    for _, v in pairs(QBCore.Functions.GetQBPlayers()) do
        if v and v.PlayerData.job.type == 'leo' and v.PlayerData.job.onduty then
            amount = amount + 1
        end
    end
    return amount
end

-- Cop count for the robbery scripts: one broadcast per CopCount.GlobalSeconds at most. A request
-- inside the window is remembered and sent by the next tick, so a duty change is never lost.
local copCountAt, copCountPending, copCountAsked = 0, false, {}

function PoliceBroadcastCopCount(force)
    local now = os.time()
    local gap = tonumber((Eq().CopCount or {}).GlobalSeconds) or 5
    if not force and now - copCountAt < gap then
        copCountPending = true
        return false
    end
    copCountAt, copCountPending = now, false
    TriggerClientEvent('police:SetCopCount', -1, GetCurrentCops())
    return true
end

function PoliceCopCountTick()
    if copCountPending then PoliceBroadcastCopCount() end
end

-- Callbacks

-- The on-duty roster with callsigns: only for on-duty leo/ems (any client could read it before).
QBCore.Functions.CreateCallback('police:GetDutyPlayers', function(source, cb)
    local caller = exports['pfm-core']:GetPlayer(source)
    if not OnDutyOfType(caller, BlipJobs()) then return cb({}) end
    local dutyPlayers = {}
    for _, v in pairs(QBCore.Functions.GetQBPlayers()) do
        if v and v.PlayerData.job.type == 'leo' and v.PlayerData.job.onduty then
            dutyPlayers[#dutyPlayers + 1] = {
                source = v.PlayerData.source,
                label = v.PlayerData.metadata['callsign'],
                job = v.PlayerData.job.name
            }
        end
    end
    cb(dutyPlayers)
end)

-- A head count only (robbery scripts gate on it); no names or positions.
QBCore.Functions.CreateCallback('police:GetCops', function(_, cb)
    cb(GetCurrentCops())
end)

-- Whether someone is dead: only about a player standing next to the caller (the cuff flow asks
-- about the person in front of it); any client could probe anyone's state before.
QBCore.Functions.CreateCallback('police:server:isPlayerDead', function(source, cb, playerId)
    local target = tonumber(playerId)
    local Player = target and exports['pfm-core']:GetPlayer(target)
    if not Player or not exports['pfm-core']:GetPlayer(source) then return cb(false) end
    local range = tonumber(Eq().DeadCheckRange) or 5.0
    if #(GetEntityCoords(GetPlayerPed(source)) - GetEntityCoords(GetPlayerPed(target))) > range then return cb(false) end
    cb(Player.PlayerData.metadata['isdead'] == true)
end)

QBCore.Functions.CreateCallback('police:IsSilencedWeapon', function(source, cb, weapon)
    local Player = exports['pfm-core']:GetPlayer(source)
    if not Player or not sharedWeapons[weapon] then return cb(false) end
    local itemInfo = Player.GetItemByName(sharedWeapons[weapon]['name'])
    local retval = false
    if itemInfo then
        if itemInfo.info and itemInfo.info.attachments then
            for k in pairs(itemInfo.info.attachments) do
                if itemInfo.info.attachments[k].component == 'COMPONENT_AT_AR_SUPP_02' or
                    itemInfo.info.attachments[k].component == 'COMPONENT_AT_AR_SUPP' or
                    itemInfo.info.attachments[k].component == 'COMPONENT_AT_PI_SUPP_02' or
                    itemInfo.info.attachments[k].component == 'COMPONENT_AT_PI_SUPP' then
                    retval = true
                end
            end
        end
    end
    cb(retval)
end)

-- Whether a ranking officer is on duty (pfm-houses home invasion): answered only to on-duty LEO,
-- and only on-duty officers count (off-duty officers used to count, and anyone could ask).
QBCore.Functions.CreateCallback('police:server:IsPoliceForcePresent', function(source, cb)
    local caller = exports['pfm-core']:GetPlayer(source)
    if not OnDutyOfType(caller, { leo = true }) then return cb(false) end
    local minGrade = tonumber(Eq().ForcePresentGrade) or 2
    for _, v in pairs(QBCore.Functions.GetQBPlayers()) do
        local job = v and v.PlayerData.job
        if job and job.type == 'leo' and job.onduty and (tonumber(job.grade and job.grade.level) or 0) >= minGrade then
            return cb(true)
        end
    end
    cb(false)
end)

-- Events

-- Duty points (pfm-core registry): going on duty through QBCore:ToggleDuty needs an officer of any
-- 'leo' job at one of the station duty desks (server position); going off duty works anywhere.
-- pfm-core's registry starts empty after a restart of pfm-core, so the points are sent again then.
local function RegisterPoliceDutyPoints()
    pcall(function()
        exports['pfm-core']:RegisterDutyPoints({ type = 'leo', points = Config.Locations['duty'], radius = Config.DutyRadius or 2.5 })
    end)
end
RegisterPoliceDutyPoints()

-- Restricted radio channels: pma-voice asks this check when a player joins one of them.
function PoliceRadioAllowed(src, channel)
    local types = (Eq().RadioChannels or {})[channel]
    if not types then return true end
    return OnDutyOfType(exports['pfm-core']:GetPlayer(tonumber(src)), types)
end

local function RegisterRadioChecks()
    if GetResourceState('pma-voice') ~= 'started' then return 0 end
    local n = 0
    for channel in pairs(Eq().RadioChannels or {}) do
        local ch = tonumber(channel)
        if ch and pcall(function()
            exports['pma-voice']:addChannelCheck(ch, function(src) return PoliceRadioAllowed(src, ch) end)
        end) then n = n + 1 end
    end
    return n
end
PoliceRegisterRadioChecks = RegisterRadioChecks
RegisterRadioChecks()

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        CreateThread(function()
            MySQL.query("DELETE FROM inventories WHERE identifier = 'policetrash'")
        end)
    elseif resourceName == 'pfm-core' then
        RegisterPoliceDutyPoints()
    elseif resourceName == 'pma-voice' then
        RegisterRadioChecks()
    end
end)

RegisterNetEvent('qb-policejob:server:stash', function()
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if Player.PlayerData.job.type ~= 'leo' or not Player.PlayerData.job.onduty then return end
    local citizenId = Player.PlayerData.citizenid
    local stashName = 'policestash_' .. citizenId
    exports['pfm-inventory']:OpenInventory(src, stashName)
end)

RegisterNetEvent('qb-policejob:server:trash', function()
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if Player.PlayerData.job.type ~= 'leo' or not Player.PlayerData.job.onduty then return end
    exports['pfm-inventory']:OpenInventory(src, 'policetrash', {
        maxweight = 4000000,
        slots = 300,
    })
end)

RegisterNetEvent('qb-policejob:server:evidence', function(currentEvidence)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if Player.PlayerData.job.type ~= 'leo' or not Player.PlayerData.job.onduty then return end
    if type(currentEvidence) ~= 'string' or #currentEvidence < 1 or #currentEvidence > 64 then return end
    -- only an evidence drawer at the locker the officer stands at (any stash name used to be accepted,
    -- e.g. another player's stash)
    local slot = currentEvidence:match('(%d+)%s*$')
    if not slot or #slot > 6 then return end
    local pos = GetEntityCoords(GetPlayerPed(src))
    local valid = false
    for i, loc in ipairs(Config.Locations['evidence'] or {}) do
        if #(pos - vector3(loc.x, loc.y, loc.z)) < 3.0 and currentEvidence == Lang:t('info.current_evidence', { value = i, value2 = slot }) then
            valid = true
            break
        end
    end
    if not valid then return end
    exports['pfm-inventory']:OpenInventory(src, currentEvidence, {
        maxweight = 4000000,
        slots = 500,
    })
end)

-- Police alerts. Any client may report something to the police (store robberies, car thefts, drug
-- sales report through this), so each player is held to Config.AlertRate: at most Max alerts per
-- Window seconds, and the same kind again within the window is dropped. The client only names what
-- it saw: the text officers read comes from Config.Equipment.Alerts (a client used to be able to put
-- any words, e.g. a fake "officer down", on every officer's screen). Server scripts call the export.
local alertTimes = {} -- [src] = { os.time(), ... } of the alerts let through in the window
local alertKinds = {} -- [src] = { [kind] = os.time() }

local function cleanAlertText(text)
    if type(text) ~= 'string' then return nil end
    text = text:gsub('%c', ' '):sub(1, 256)
    if text:match('^%s*$') then return nil end
    return text
end

local function SendPoliceAlert(coords, text, title)
    local players = QBCore.Functions.GetQBPlayers()
    for _, v in pairs(players) do
        if v and v.PlayerData.job.type == 'leo' and v.PlayerData.job.onduty then
            local alertData = { title = title or Lang:t('info.new_call'), coords = { x = coords.x, y = coords.y, z = coords.z }, description = text }
            TriggerClientEvent('qb-phone:client:addPoliceAlert', v.PlayerData.source, alertData)
            TriggerClientEvent('police:client:policeAlert', v.PlayerData.source, coords, text)
        end
    end
end

-- Used when config_equipment.lua is not loaded, so alerts never stop working.
local DEFAULT_ALERTS = {
    Kinds = {
        robbery = { title = 'Robbery', text = 'Robbery in progress' },
        suspicious = { title = 'Suspicious activity', text = 'Suspicious activity reported' },
        emergency = { title = 'Emergency', text = 'Emergency call' },
    },
    Patterns = { { 'robbery', 'robbery' } },
    Default = 'suspicious',
}
local function AlertCfg() return Eq().Alerts or DEFAULT_ALERTS end

--- The alert kind a legacy free-text report means (Config.Equipment.Alerts.Patterns), or the default.
function PoliceAlertKindFor(text)
    local cfg = AlertCfg()
    local kinds = cfg.Kinds or {}
    if type(text) == 'string' then
        local key = text:lower()
        if kinds[key] then return key end
        for _, p in ipairs(cfg.Patterns or {}) do
            if type(p[1]) == 'string' and key:find(p[1], 1, true) and kinds[p[2]] then return p[2] end
        end
    end
    return kinds[cfg.Default] and cfg.Default or next(kinds)
end

local function AlertAllowed(src, kind)
    local rate = Config.AlertRate or {}
    local window, max = tonumber(rate.Window) or 30, tonumber(rate.Max) or 2
    local now = os.time()
    local times = {}
    for _, t in ipairs(alertTimes[src] or {}) do
        if now - t < window then times[#times + 1] = t end
    end
    local kinds = alertKinds[src] or {}
    for k, at in pairs(kinds) do
        if now - at >= window then kinds[k] = nil end
    end
    alertTimes[src], alertKinds[src] = times, kinds
    if #times >= max or kinds[kind] then return false end
    times[#times + 1] = now
    kinds[kind] = now
    return true
end

--- A structured alert from a player, at the player's server position. Returns true when sent.
function PoliceStructuredAlert(src, kind)
    local def = kind and (AlertCfg().Kinds or {})[kind]
    if not def then return false end
    local numericSrc = tonumber(src)
    -- a server script that TriggerEvents this keeps its own player as source: held to the same limit
    if not numericSrc or numericSrc <= 0 then return false end
    if not exports['pfm-core']:GetPlayer(numericSrc) then return false end
    if not AlertAllowed(numericSrc, kind) then return false end
    SendPoliceAlert(GetEntityCoords(GetPlayerPed(numericSrc)), def.text, def.title)
    return true
end

--- exports['pfm-policejob']:PoliceAlert(coords, text, title) for server scripts: an alert at a
--- position the caller decided, to every on-duty officer (no rate limit).
exports('PoliceAlert', function(coords, text, title)
    text = cleanAlertText(text)
    if not text or (type(coords) ~= 'table' and type(coords) ~= 'vector3' and type(coords) ~= 'vector4') then return false end
    local x, y, z = tonumber(coords.x), tonumber(coords.y), tonumber(coords.z)
    if not x or not y or not z then return false end
    SendPoliceAlert(vector3(x, y, z), text, type(title) == 'string' and title:sub(1, 64) or nil)
    return true
end)

-- New callers name the kind: TriggerServerEvent('police:server:Alert', 'storerobbery').
RegisterNetEvent('police:server:Alert', function(kind)
    if type(kind) ~= 'string' or #kind > 32 then return end
    PoliceStructuredAlert(source, kind)
end)

-- Legacy free-text callers (pfm-storerobbery, pfm-bankrobbery, pfm-vehiclekeys, pfm-drugs,
-- pfm-jewelery): the text only picks the kind.
RegisterNetEvent('police:server:policeAlert', function(text)
    text = cleanAlertText(text)
    if not text then return end
    PoliceStructuredAlert(source, PoliceAlertKindFor(text))
end)

-- police:client:SendEmergencyMessage forwarded a client position and text that no handler took;
-- it is now an 'emergency' alert at the sender's server position (both arguments are ignored).
RegisterNetEvent('police:server:SendEmergencyMessage', function()
    PoliceStructuredAlert(source, 'emergency')
end)

-- Officer down and panic also go on the police MDT dispatch board.
function PoliceMdtDispatch(kind, src, coords, callsign)
    if GetResourceState('pf-policemdt-DEV') ~= 'started' then return false end
    local title = kind == 'panic' and 'Officer panic button' or 'Officer down'
    local ok = pcall(function()
        exports['pf-policemdt-DEV']:CreateDispatchCall({
            title = title, description = ('%s (%s)'):format(title, tostring(callsign or 'unknown')),
            code = kind == 'panic' and '10-99' or '10-13', priority = 1, callType = kind,
            coords = { x = coords.x, y = coords.y, z = coords.z }, createdBy = 'pfm-policejob', status = 'pending',
        })
    end)
    return ok
end

-- An officer who is down presses the emergency button: the text is built here from their own
-- name and callsign (any client could send "officer down" with any text before), once a minute.
local officerDownAt = {}
RegisterNetEvent('police:server:OfficerDown', function()
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player or Player.PlayerData.job.type ~= 'leo' or not Player.PlayerData.job.onduty then return end
    local meta = Player.PlayerData.metadata
    if not (meta['isdead'] or meta['inlaststand']) then return end
    local now = os.time()
    if officerDownAt[src] and now - officerDownAt[src] < 60 then return end
    officerDownAt[src] = now
    local text = Lang:t('info.officer_down', { lastname = (Player.PlayerData.charinfo or {}).lastname or '', callsign = meta['callsign'] or '' })
    local coords = GetEntityCoords(GetPlayerPed(src))
    SendPoliceAlert(coords, text)
    PoliceMdtDispatch('officer_down', src, coords, meta['callsign'])
    if PFTelemetry then PFTelemetry.Mark(src, 'note', { event = 'officer_down_button' }) end
end)

-- The duty GPS on request (a client that just loaded or changed job): only to on-duty leo/ems, at
-- most every Blips.RequestSeconds; anyone else gets an empty list (clears stale blips). No handler
-- existed before, so the request did nothing.
local blipAsked = {}
RegisterNetEvent('police:server:UpdateBlips', function()
    local src = source
    local now = os.time()
    local gap = tonumber((Eq().Blips or {}).RequestSeconds) or 5
    if blipAsked[src] and now - blipAsked[src] < gap then return end
    blipAsked[src] = now
    local Player = exports['pfm-core']:GetPlayer(src)
    if not OnDutyOfType(Player, BlipJobs()) then
        TriggerClientEvent('police:client:UpdateBlips', src, {})
        return
    end
    local list = DutyBlipList()
    TriggerClientEvent('police:client:UpdateBlips', src, list)
end)

-- A client asks for the cop count to be sent again (load, duty toggle): at most once per
-- CopCount.PerSourceSeconds per player, and one broadcast per GlobalSeconds for everyone (any
-- client could loop a broadcast to every player before).
RegisterNetEvent('police:server:UpdateCurrentCops', function()
    local src = tonumber(source)
    if not src then return end
    local now = os.time()
    local gap = tonumber((Eq().CopCount or {}).PerSourceSeconds) or 10
    if copCountAsked[src] and now - copCountAsked[src] < gap then return end
    copCountAsked[src] = now
    PoliceBroadcastCopCount()
end)

-- The server knows when the count changes.
AddEventHandler('QBCore:Server:SetDuty', function()
    PoliceBroadcastCopCount()
end)

-- police:server:SetHandcuffStatus is gone: the cuff state is set by the server only
-- (server/interactions.lua, PoliceSetCuffed).

-- Station fingerprint scanner. An on-duty officer within 2.5 m opens a session with the person
-- scanned; a scan from either side shows that person's own print, to both of them only. Before, any
-- player could open it, and a scan sent the scanning player's own print to any session id.
local fpSessions = {} -- [officer src] = { target, at }

local function FpRange() return tonumber((Eq().Fingerprint or {}).Range) or 2.5 end

RegisterNetEvent('police:server:showFingerprint', function(playerId)
    local src = source
    local target = tonumber(playerId)
    local Player = exports['pfm-core']:GetPlayer(src)
    if not target or target == src or not exports['pfm-core']:GetPlayer(target) then return end
    if not OnDutyOfType(Player, { leo = true }) then return end
    if #(GetEntityCoords(GetPlayerPed(src)) - GetEntityCoords(GetPlayerPed(target))) > FpRange() then return end
    fpSessions[src] = { target = target, at = os.time() }
    TriggerClientEvent('police:client:showFingerprint', target, src)
    TriggerClientEvent('police:client:showFingerprint', src, target)
end)

RegisterNetEvent('police:server:showFingerprintId', function(sessionId)
    local src = source
    local other = tonumber(sessionId)
    if not other then return end
    -- the session is found from either side; the print shown is always the scanned person's
    local officer, target
    if fpSessions[src] and fpSessions[src].target == other then officer, target = src, other
    elseif fpSessions[other] and fpSessions[other].target == src then officer, target = other, src
    else return end
    local session = fpSessions[officer]
    if os.time() - session.at > (tonumber((Eq().Fingerprint or {}).SessionSeconds) or 120) then
        fpSessions[officer] = nil
        return
    end
    local Target = exports['pfm-core']:GetPlayer(target)
    if not Target or not exports['pfm-core']:GetPlayer(officer) then return end
    if #(GetEntityCoords(GetPlayerPed(officer)) - GetEntityCoords(GetPlayerPed(target))) > FpRange() then return end
    local fid = Target.PlayerData.metadata['fingerprint']
    TriggerClientEvent('police:client:showFingerprintId', officer, fid)
    TriggerClientEvent('police:client:showFingerprintId', target, fid)
end)

RegisterNetEvent('police:server:SetTracker', function(targetId)
    local src = source
    targetId = tonumber(targetId)
    if not targetId then return end
    local Player = exports['pfm-core']:GetPlayer(src)
    local Target = exports['pfm-core']:GetPlayer(targetId)
    if not Player or not Target then return end
    if Player.PlayerData.job.type ~= 'leo' or not Player.PlayerData.job.onduty then return end
    local playerCoords = GetEntityCoords(GetPlayerPed(src))
    local targetCoords = GetEntityCoords(GetPlayerPed(targetId))
    if #(playerCoords - targetCoords) > 2.5 then return DropPlayer(src, 'Attempted exploit abuse') end

    local TrackerMeta = Target.PlayerData.metadata['tracker']
    if TrackerMeta then
        Target.Functions.SetMetaData('tracker', false)
        TriggerClientEvent('QBCore:Notify', targetId, Lang:t('success.anklet_taken_off'), 'success')
        TriggerClientEvent('QBCore:Notify', src, Lang:t('success.took_anklet_from', { firstname = Target.PlayerData.charinfo.firstname, lastname = Target.PlayerData.charinfo.lastname }), 'success')
        TriggerClientEvent('police:client:SetTracker', targetId, false)
    else
        Target.Functions.SetMetaData('tracker', true)
        TriggerClientEvent('QBCore:Notify', targetId, Lang:t('success.put_anklet'), 'success')
        TriggerClientEvent('QBCore:Notify', src, Lang:t('success.put_anklet_on', { firstname = Target.PlayerData.charinfo.firstname, lastname = Target.PlayerData.charinfo.lastname }), 'success')
        TriggerClientEvent('police:client:SetTracker', targetId, true)
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    alertTimes[src], alertKinds[src], officerDownAt[src] = nil, nil, nil
    blipAsked[src], copCountAsked[src], fpSessions[src] = nil, nil, nil
    PoliceBroadcastCopCount()
end)

-- The anklet position is read by the server (/ankletlocation in server/commands.lua); the tracked
-- player's client is no longer asked for it.

-- Threads

CreateThread(function()
    while true do
        Wait(1000 * 60 * 10)
        PoliceBroadcastCopCount(true)
    end
end)

CreateThread(function()
    while true do
        Wait(5000)
        PoliceCopCountTick()
        PolicePushDutyBlips()
    end
end)

-- Items

QBCore.Functions.CreateUseableItem('handcuffs', function(source)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player.GetItemByName('handcuffs') then return end
    TriggerClientEvent('police:client:CuffPlayerSoft', src)
end)

QBCore.Functions.CreateUseableItem('moneybag', function(source, item)
    local src = source
    local Player = exports['pfm-core']:GetPlayer(src)
    if not Player then return end
    if not Player.GetItemByName('moneybag') or not item.info or item.info == '' then return end
    if Player.PlayerData.job.type ~= 'leo' then return end
    local cash = tonumber(item.info.cash)
    if not cash or cash <= 0 or cash ~= cash or cash == math.huge then return end
    -- paid out of the evidence account the cash was seized into, once per bag id; bags made before
    -- this change have no id and are paid under a fresh key
    local bagKey = 'pfm-policejob:moneybag:' .. tostring(item.info.bag or ('legacy-' .. PFPayout.NewId()))
    if not exports['pfm-inventory']:RemoveItem(src, 'moneybag', 1, item.slot, 'qb-policejob:moneybag') then return end
    local res = PFPayout.Transfer({
        from = 'system:pfm-policejob-evidence', to = ('player:%s:cash'):format(Player.PlayerData.citizenid),
        amount = math.floor(cash), key = bagKey, kind = 'seizure', reason = 'Evidence bag opened', actor = Player.PlayerData.citizenid,
    })
    if not res.ok then
        exports['pfm-inventory']:AddItem(src, 'moneybag', 1, false, item.info, 'qb-policejob:moneybag-return')
    elseif res.duplicate then
        TriggerClientEvent('QBCore:Notify', src, 'This evidence bag was already opened', 'error')
    end
end)

-- Vehicles this job may spawn through pfm-core (QBCore:Server:SpawnVehicle only spawns registered
-- job vehicles or vehicles the server granted a ticket for)
-- (every leo job; police also return impounded player cars, so any catalog model is allowed on duty)
CreateThread(function()
    local models = { Config.PoliceHelicopter }
    for _, grade in pairs(Config.AuthorizedVehicles or {}) do
        for model in pairs(grade) do models[#models + 1] = model end
    end
    for model in pairs(Config.WhitelistedVehicles or {}) do models[#models + 1] = model end
    for name, job in pairs(exports['pfm-core']:GetShared('Jobs') or {}) do
        if job.type == 'leo' or name == 'police' then
            pcall(function() exports['pfm-core']:RegisterJobVehicles(name, models, { catalog = true }) end)
        end
    end
end)
