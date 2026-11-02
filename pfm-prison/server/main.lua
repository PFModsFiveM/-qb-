local QBCore = exports['pfm-core']:GetCoreObject({ 'Functions' })
local sharedItems = exports['pfm-core']:GetShared('Items')

-- The prison runs on the server. pfm-policejob jails a player through the JailPlayer export: the
-- server stores and clears their items in one step (no wait in between), counts the sentence down
-- while it sees them inside the walls, gives the time cuts for prison work, and releases them (items
-- back) when the time is served or an officer unjails them. Clients only show it. A client used to
-- count its own sentence down and send it (any client could send 1, then 0, and walk out with its
-- items), save its own items with a 2 s wait between the copy and the clear, report its own escape,
-- and open the gates on its own word.
--
-- Escapes: every SampleSeconds the server looks at each inmate. Outside the walls is an escape only
-- when the inmate went through a gate an inmate hacked open in the last BreachWindow seconds, was
-- seen inside the walls just before, and never moved faster than MaxSpeed (a teleport voids the
-- path). Anything else (noclip over the wall, a teleport, a respawn outside) takes them back to a
-- cell with the time they have left; the countdown stops while they are outside.

PFPrison = PFPrison or {}

local JailResourceAllowlist = Config.JailResourceAllowlist or {
    ['pfm-policejob'] = true,
    ['pfm-adminmenu'] = true,
}
local MaxJailTime = Config.MaxJailTime or 1440
local P = Config.Prison or {}
local G = Config.GateHack or {}
local Gates = Config.Gates or {}

local Inmates = {}       -- [src] = true for every online player serving a sentence
local Track = {}         -- [src] = { last = { pos, at }, lastInside = { pos, at }, graceUntil, passedGateAt, sentBackAt }
local LastTick = {}      -- [src] = os.time() the sentence was last counted down (or the count started)
local Jobs = {}          -- [src] = { name, location, assignedAt }
local Tickets = {}       -- [src] = { id, gate, at, challengeId }: a gate hack in progress
local LastHackStart = {} -- [src] = os.time()
local LastAsk = {}       -- [src] = os.time() of the last time / job request
local GotPhone = {}      -- [citizenid] = true once a phone was found this sentence
local GateOpen = {}      -- [gate index] = { at = os.time(), by = src } while a hacked gate stands open
local LockdownUntil = 0
local AlarmActivated = false
local AlarmSeq = 0
local LastAlertAt = -math.huge
local hackSeq = 0

local function num(v, default) return tonumber(v) or default end
local function insideRadius() return num(P.InsideRadius, 200.0) end
local function grace() return num(P.GraceSeconds, 20) end

local function getPlayer(src)
    src = tonumber(src)
    return src and exports['pfm-core']:GetPlayer(src) or nil
end

local function isCallable(v)
    if type(v) == 'function' then return true end
    if type(v) ~= 'table' then return false end
    if type(rawget(v, '__cfx_functionReference')) == 'string' then return true end
    local mt = getmetatable(v)
    return type(mt) == 'table' and rawget(mt, '__call') ~= nil
end

local function setMeta(Player, key, value)
    local fn = Player.Functions and Player.Functions.SetMetaData
    if not isCallable(fn) then fn = Player.SetMetaData end
    fn(key, value)
end

local function sentenceOf(Player)
    return math.max(0, math.floor(num(Player.PlayerData.metadata['injail'], 0)))
end

local function pedPos(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    return GetEntityCoords(ped)
end

local function insidePrison(pos)
    if not pos then return false end
    local m = Config.Locations['middle']
    return #(vector2(pos.x, pos.y) - vector2(m.x, m.y)) <= insideRadius()
end

local function notify(src, text, kind) TriggerClientEvent('QBCore:Notify', src, text, kind) end

-- City events (pf-services). A confirmed escape is reported once: news bulletin + police dispatch
-- request (crime.prison.escape has police = true) at the spot the inmate was seen, with their public name.
local function CityEvent(kind, data, opts)
    if GetResourceState('pf-services') ~= 'started' then return nil end
    local svc = exports['pf-services']
    if not svc then return nil end
    local ok, id = pcall(function() return svc:Emit(kind, data, opts) end)
    return ok and id or nil
end

local function ReportEscape(Player, coords)
    local ci = Player.PlayerData.charinfo or {}
    local name = ((ci.firstname or '') .. ' ' .. (ci.lastname or '')):gsub('^%s+', ''):gsub('%s+$', '')
    if name == '' then name = 'An inmate' end
    local cid = Player.PlayerData.citizenid
    CityEvent('crime.prison.escape', { name = name, count = 1, location = 'Bolingbroke Penitentiary', place = 'Bolingbroke Penitentiary', ref = 'escape:' .. tostring(cid),
        details = name .. ' escaped from Bolingbroke Penitentiary' }, {
        title = name .. ' escaped from Bolingbroke Penitentiary', coords = vector3(coords.x, coords.y, coords.z),
        actor = cid, dedupe = cid,
    })
end

-- ── alarm, lockdown and gates ───────────────────────────────────────

local function anyOnlinePlayer()
    for _, src in ipairs(QBCore.Functions.GetPlayers() or {}) do
        if getPlayer(src) then return tonumber(src) end
    end
    return nil
end

local function AlertPolice()
    local now = os.time()
    -- at most one prison-break alert per LockdownSeconds (an inmate could ring one every second)
    if now - LastAlertAt < num(G.LockdownSeconds, 600) then return end
    LastAlertAt = now
    for _, v in pairs(QBCore.Functions.GetPlayers() or {}) do
        local Player = getPlayer(v)
        if Player and Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
            TriggerClientEvent('prison:client:PrisonBreakAlert', v)
        end
    end
end

-- Hacked gates lock again when the alarm stops, or OpenSeconds after they opened (pfm-doorlock wants
-- an online player to name in the change: the one who opened it, or anyone).
local function RelockGate(i)
    local open = GateOpen[i]
    if not open then return end
    GateOpen[i] = nil
    local by = getPlayer(open.by) and open.by or anyOnlinePlayer()
    if by and Gates[i] then
        TriggerEvent('qb-doorlock:server:updateState', Gates[i].gatekey, true, false, false, true, false, false, by)
    end
    TriggerClientEvent('prison:client:SetGateHit', -1, i, false)
end

local function RelockGates()
    for i in pairs(GateOpen) do RelockGate(i) end
end

function PFPrison.EndAlarm()
    AlarmActivated = false
    TriggerClientEvent('prison:client:JailAlarm', -1, false)
    RelockGates()
end

local function BreakAlarm()
    AlertPolice()
    if AlarmActivated then return end
    AlarmActivated = true
    AlarmSeq = AlarmSeq + 1
    local seq = AlarmSeq
    TriggerClientEvent('prison:client:JailAlarm', -1, true)
    SetTimeout(num(G.AlarmSeconds, 300) * 1000, function()
        if AlarmSeq == seq and AlarmActivated then PFPrison.EndAlarm() end
    end)
end

local function Lockdown()
    local now = os.time()
    if LockdownUntil > now then return end
    LockdownUntil = now + num(G.LockdownSeconds, 600)
    TriggerClientEvent('prison:client:SetLockDown', -1, true)
    BreakAlarm()
    local until_ = LockdownUntil
    SetTimeout(num(G.LockdownSeconds, 600) * 1000, function()
        if LockdownUntil == until_ then TriggerClientEvent('prison:client:SetLockDown', -1, false) end
    end)
end

local function OpenGate(i, src)
    local gate = Gates[i]
    local entry = { at = os.time(), by = src }
    GateOpen[i] = entry
    SetTimeout(num(G.OpenSeconds, 300) * 1000, function()
        if GateOpen[i] == entry then RelockGate(i) end
    end)
    -- the door opens through pfm-doorlock's server path: a one-time grant for the hacker, then the
    -- change with unlockAnyway
    pcall(function() exports['pfm-doorlock']:GrantDoorAccess(src, gate.gatekey, 10000) end)
    TriggerEvent('qb-doorlock:server:updateState', gate.gatekey, false, false, false, true, false, false, src)
    TriggerClientEvent('prison:client:SetGateHit', -1, i, true)
    if math.random(1, 100) <= num(G.AlertChance, 50) then BreakAlarm() end
end

local function gateIsOpen(i, now)
    local open = GateOpen[i]
    return open ~= nil and now - open.at <= num(P.BreachWindow, 600)
end

-- ── items ──────────────────────────────────────────────────────────

--- Moves the player's items into the stored list and clears the inventory, with no wait between
--- the copy and the clear (nothing can move an item in between). Items still stored from before
--- are kept. False when the inventory could not be cleared (nothing is stored then).
local function StoreItems(src)
    local Player = getPlayer(src)
    if not Player then return false end
    local before = Player.PlayerData.metadata['jailitems']
    local stored = {}
    if type(before) == 'table' then
        for _, v in pairs(before) do stored[#stored + 1] = v end
    end
    for _, v in pairs(Player.PlayerData.items or {}) do
        if type(v) == 'table' and type(v.name) == 'string' and num(v.amount, 0) > 0 then
            stored[#stored + 1] = { name = v.name, amount = math.floor(num(v.amount, 1)), info = v.info, type = v.type }
        end
    end
    setMeta(Player, 'jailitems', stored)
    local ok = pcall(function() exports['pfm-inventory']:ClearInventory(src) end)
    if not ok then
        setMeta(Player, 'jailitems', type(before) == 'table' and before or {})
        return false
    end
    return true
end

--- Gives the stored items back once: the list is emptied first, so a second release finds nothing.
--- Items that do not fit stay stored and are given at the next load.
local function ReturnItems(src)
    local Player = getPlayer(src)
    if not Player then return 0 end
    local stored = Player.PlayerData.metadata['jailitems']
    if type(stored) ~= 'table' or next(stored) == nil then return 0 end
    setMeta(Player, 'jailitems', {})
    local kept, given = {}, 0
    for _, v in pairs(stored) do
        if type(v) == 'table' and type(v.name) == 'string' and num(v.amount, 0) > 0 then
            local ok, added = pcall(function()
                return exports['pfm-inventory']:AddItem(src, v.name, math.floor(num(v.amount, 1)), false, v.info, 'prison:server:ReturnItems')
            end)
            if ok and added then given = given + 1 else kept[#kept + 1] = v end
        end
    end
    if #kept > 0 then
        Player = getPlayer(src)
        if Player then setMeta(Player, 'jailitems', kept) end
        notify(src, 'Some of your belongings did not fit; they are kept for you until you have room', 'error')
    end
    return given
end

-- ── prison work ────────────────────────────────────────────────────

local function jobNames()
    local names = {}
    for name in pairs(Config.Locations.jobs or {}) do names[#names + 1] = name end
    table.sort(names)
    return names
end

--- Gives the inmate a (new) job spot, never the one they just did.
local function AssignJob(src, name, avoid)
    local names = jobNames()
    if #names == 0 then return nil end
    name = (name and Config.Locations.jobs[name]) and name or names[math.random(1, #names)]
    local spots = Config.Locations.jobs[name]
    local location = math.random(1, #spots)
    if #spots > 1 and location == avoid then location = (location % #spots) + 1 end
    Jobs[src] = { name = name, location = location, assignedAt = os.time() }
    return Jobs[src]
end

-- ── sentence ───────────────────────────────────────────────────────

local function forget(src)
    Inmates[src], Track[src], LastTick[src], Jobs[src], Tickets[src] = nil, nil, nil, nil, nil
end

local function startTracking(src)
    Inmates[src] = true
    LastTick[src] = os.time()
    Track[src] = { graceUntil = os.time() + grace() }
end

--- Jails an online player for `minutes` (1..Config.MaxJailTime).
--- @return boolean ok, string|nil error
function PFPrison.Jail(src, minutes, opts)
    src = tonumber(src)
    local Player = getPlayer(src)
    if not Player then return false, 'no_player' end
    minutes = math.floor(num(minutes, 0))
    if minutes ~= minutes or minutes < 1 then return false, 'bad_time' end
    if minutes > MaxJailTime then minutes = MaxJailTime end
    local cid = Player.PlayerData.citizenid
    local already = sentenceOf(Player) > 0
    if not already then
        if not StoreItems(src) then return false, 'inventory_unavailable' end
        Player = getPlayer(src)
        if not Player then return false, 'no_player' end
    end
    local jailId = (already and Player.PlayerData.metadata['jailid']) or PFPayout.NewId()
    setMeta(Player, 'jailid', jailId)
    setMeta(Player, 'injail', minutes)
    if Player.PlayerData.job and Player.PlayerData.job.name ~= 'unemployed' then
        local setJob = Player.Functions and Player.Functions.SetJob
        if not isCallable(setJob) then setJob = Player.SetJob end
        if isCallable(setJob) then setJob('unemployed', 0) end
        notify(src, Lang:t('info.lost_job'))
    end
    if not already then
        GotPhone[cid] = nil
        -- jail money through the bank ledger, once per sentence (the key is the sentence's own)
        PFPayout.Pay(cid, 'cash', 80, { key = ('pfm-prison:jailmoney:%s:%s'):format(cid, jailId), reason = 'jail money', quiet = true })
    end
    startTracking(src)
    local job = AssignJob(src)
    TriggerClientEvent('prison:client:Enter', src, minutes, job and job.name, job and job.location)
    return true
end

--- Releases a player who is serving (or has served) a sentence: time to 0, items back, out of the
--- gate. `served`: the server's own countdown ended it (a sentence from before jail ids has none).
--- @return boolean ok, string|nil error
function PFPrison.Release(src, reason, served)
    src = tonumber(src)
    local Player = getPlayer(src)
    if not Player then return false, 'no_player' end
    if not served and sentenceOf(Player) <= 0 and Player.PlayerData.metadata['jailid'] == nil then return false, 'not_jailed' end
    setMeta(Player, 'injail', 0)
    setMeta(Player, 'jailid', nil)
    forget(src)
    GotPhone[Player.PlayerData.citizenid] = nil
    ReturnItems(src)
    TriggerClientEvent('prison:client:Released', src, reason)
    return true
end

-- A confirmed escape: the sentence ends, the stored items are forfeited, the city and police hear of it.
local function Escape(src, pos)
    local Player = getPlayer(src)
    if not Player then return end
    setMeta(Player, 'injail', 0)
    setMeta(Player, 'jailid', nil)
    setMeta(Player, 'jailitems', {})
    forget(src)
    ReportEscape(Player, pos)
    BreakAlarm()
    TriggerClientEvent('prison:client:Escaped', src)
end

-- Outside the walls without a way out: back to a cell with the time left.
local function SendBack(src, t, now)
    if t.sentBackAt and now - t.sentBackAt < num(P.SendBackSeconds, 10) then return end
    local Player = getPlayer(src)
    if not Player then return end
    t.sentBackAt, t.graceUntil = now, now + grace()
    t.last, t.lastInside, t.passedGateAt = nil, nil, nil
    local spawns = Config.Locations.spawns
    local spot = spawns[math.random(1, #spawns)].coords
    if SetEntityCoords then pcall(SetEntityCoords, GetPlayerPed(src), spot.x, spot.y, spot.z - 0.9, false, false, false, false) end
    local job = Jobs[src] or AssignJob(src)
    TriggerClientEvent('prison:client:Enter', src, sentenceOf(Player), job and job.name, job and job.location, true)
    notify(src, 'You were taken back to your cell', 'error')
end

-- Distance (on the ground) from point p to the path a -> b.
local function pathDistance(a, b, p)
    local abx, aby = b.x - a.x, b.y - a.y
    local len2 = abx * abx + aby * aby
    local t = 0
    if len2 > 0 then t = math.max(0, math.min(1, ((p.x - a.x) * abx + (p.y - a.y) * aby) / len2)) end
    local cx, cy = a.x + abx * t - p.x, a.y + aby * t - p.y
    return math.sqrt(cx * cx + cy * cy)
end

local function sample(src, now)
    local pos = pedPos(src)
    if not pos then return end
    local t = Track[src]
    if not t then t = {} Track[src] = t end
    local inside = insidePrison(pos)
    local prev = t.last
    t.last = { pos = pos, at = now }
    if t.graceUntil and now < t.graceUntil then
        if inside then t.lastInside = t.last end
        return
    end
    if prev then
        local dt = math.max(1, now - prev.at)
        if #(pos - prev.pos) > num(P.MaxSpeed, 30.0) * dt + 10.0 then
            -- a teleport: the path so far proves nothing
            t.passedGateAt, t.lastInside = nil, nil
        else
            for i, gate in ipairs(Gates) do
                if gateIsOpen(i, now) and pathDistance(prev.pos, pos, gate.coords) <= num(P.GateReach, 12.0) then
                    t.passedGateAt = now
                end
            end
        end
    end
    if inside then
        t.lastInside = t.last
        return
    end
    local li = t.lastInside
    local escaped = t.passedGateAt ~= nil and now - t.passedGateAt <= num(P.BreachWindow, 600)
        and li ~= nil and now - li.at <= num(P.ExitWindow, 8)
    if escaped then Escape(src, pos) else SendBack(src, t, now) end
end

--- One look at every inmate (every SampleSeconds; also used by tests).
function PFPrison.SampleTick()
    local now = os.time()
    for src in pairs(Inmates) do
        local Player = getPlayer(src)
        if not Player then
            forget(src)
        elseif sentenceOf(Player) > 0 then
            sample(src, now)
        end
    end
end

--- Counts every inmate's sentence down by a minute per minute they spent inside the walls, and
--- releases those whose time is served (every 15 s; also used by tests).
function PFPrison.MinuteTick()
    local now = os.time()
    for src in pairs(Inmates) do
        local Player = getPlayer(src)
        if not Player then
            forget(src)
        else
            local left = sentenceOf(Player)
            if left <= 0 then
                PFPrison.Release(src, 'served', true)
            elseif now - (LastTick[src] or now) >= 60 then
                LastTick[src] = now
                -- a minute spent outside the walls (still being brought in, or out) does not count
                if insidePrison(pedPos(src)) then
                    left = left - 1
                    setMeta(Player, 'injail', left)
                    if left <= 0 then
                        notify(src, Lang:t('success.timesup'), 'success')
                        PFPrison.Release(src, 'served', true)
                    else
                        TriggerClientEvent('prison:client:UpdateTime', src, left)
                    end
                end
            end
        end
    end
end

CreateThread(function()
    while true do
        Wait(num(P.SampleSeconds, 2) * 1000)
        local ok, err = pcall(PFPrison.SampleTick)
        if not ok then print(('^1[pfm-prison]^7 sample failed: %s'):format(tostring(err))) end
    end
end)

CreateThread(function()
    while true do
        Wait(15000)
        local ok, err = pcall(PFPrison.MinuteTick)
        if not ok then print(('^1[pfm-prison]^7 countdown failed: %s'):format(tostring(err))) end
    end
end)

-- ── exports (server resources) ─────────────────────────────────────

local function allowedInvoker()
    local invoker = GetInvokingResource()
    return invoker == nil or invoker == GetCurrentResourceName() or JailResourceAllowlist[invoker] == true
end

exports('JailPlayer', function(src, minutes, opts)
    if not allowedInvoker() then return false, 'not_allowed' end
    return PFPrison.Jail(src, minutes, type(opts) == 'table' and opts or {})
end)

exports('ReleasePlayer', function(src, reason)
    if not allowedInvoker() then return false, 'not_allowed' end
    return PFPrison.Release(src, type(reason) == 'string' and reason:sub(1, 32) or 'release')
end)

exports('GetJailTime', function(src)
    local Player = getPlayer(src)
    return Player and sentenceOf(Player) or 0
end)

-- ── net events (inmates) ───────────────────────────────────────────

-- Prison work: the server gave the spot; finishing it there (in reasonable time) may cut the
-- sentence by 1-2 months (the client used to cut its own time) and may turn up a phone.
RegisterNetEvent('prison:server:JobDone', function(location)
    local src = source
    local job = Jobs[src]
    if not job then return end
    location = math.tointeger(tonumber(location))
    if location ~= job.location then return end
    local Player = getPlayer(src)
    if not Player or sentenceOf(Player) <= 0 then return end
    local now = os.time()
    if now - job.assignedAt < num(P.JobMinSeconds, 8) then return end
    local spot = Config.Locations.jobs[job.name] and Config.Locations.jobs[job.name][location]
    local pos = pedPos(src)
    if not spot or not pos or #(pos - vector3(spot.coords.x, spot.coords.y, spot.coords.z)) > num(P.JobReach, 3.5) then return end

    local left = sentenceOf(Player)
    if math.random(1, 100) <= 50 then
        left = math.max(0, left - math.random(1, 2))
        setMeta(Player, 'injail', left)
        notify(src, Lang:t('success.time_cut'))
    end
    local cid = Player.PlayerData.citizenid
    if not GotPhone[cid] and math.random(1, 100) <= num(P.PhoneChance, 1) then
        local ok, added = pcall(function() return exports['pfm-inventory']:AddItem(src, 'phone', 1, false, false, 'prison:server:JobDone') end)
        if ok and added then
            GotPhone[cid] = true
            TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems['phone'], 'add')
            notify(src, Lang:t('success.found_phone'), 'success')
        end
    end
    if left <= 0 then
        notify(src, Lang:t('success.timesup'), 'success')
        PFPrison.Release(src, 'served', true)
        return
    end
    local nextJob = AssignJob(src, job.name, location)
    TriggerClientEvent('prison:client:SetJob', src, nextJob.name, nextJob.location, left)
end)

-- The client asks for its time and job spot (after a load, a respawn, the desk): the server's own.
RegisterNetEvent('prison:server:RequestState', function()
    local src = source
    local now = os.time()
    if LastAsk[src] and now - LastAsk[src] < 2 then return end
    LastAsk[src] = now
    local Player = getPlayer(src)
    if not Player then return end
    local left = sentenceOf(Player)
    if left <= 0 then
        if Player.PlayerData.metadata['jailid'] ~= nil then PFPrison.Release(src, 'served') end
        return
    end
    if not Inmates[src] then startTracking(src) end
    local job = Jobs[src] or AssignJob(src)
    TriggerClientEvent('prison:client:SetJob', src, job and job.name, job and job.location, left)
end)

-- Gate hack, step 1: an inmate at a gate's hack point with an electronickit and a gatecrack (the
-- gatecrack is used up). The server issues the hacking puzzle (pfm-minigames) when it can.
RegisterNetEvent('prison:server:StartGateHack', function(gate)
    local src = source
    gate = math.tointeger(tonumber(gate))
    local g = gate and Gates[gate]
    if not g then return end
    local Player = getPlayer(src)
    if not Player or sentenceOf(Player) <= 0 then return end
    local now = os.time()
    if LockdownUntil > now then return notify(src, Lang:t('error.security_activated'), 'error') end
    if GateOpen[gate] or Tickets[src] then return end
    if LastHackStart[src] and now - LastHackStart[src] < num(G.StartCooldown, 30) then return end
    local pos = pedPos(src)
    if not pos or #(pos - g.coords) > num(G.Reach, 2.5) then return end
    local okItems, hasAll = pcall(function()
        return exports['pfm-inventory']:HasItem(src, 'gatecrack') and exports['pfm-inventory']:HasItem(src, 'electronickit')
    end)
    if not okItems or not hasAll then return notify(src, Lang:t('error.item_missing'), 'error') end
    local okRemove, removed = pcall(function() return exports['pfm-inventory']:RemoveItem(src, 'gatecrack', 1, false, 'prison:server:StartGateHack') end)
    if not okRemove or not removed then return end
    TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems['gatecrack'], 'remove')
    LastHackStart[src] = now
    hackSeq = hackSeq + 1
    local ticket = { id = hackSeq, gate = gate, at = now }
    local okCh, challenge = pcall(function()
        return exports['pfm-minigames']:IssueChallenge(src, 'hacking', {
            size = G.Size or 5, seconds = G.Seconds or 30, ttl = num(G.MaxSeconds, 60) * 1000, tag = 'prison:gate:' .. gate,
        })
    end)
    if okCh and type(challenge) == 'table' and type(challenge.id) == 'string' then
        ticket.challengeId = challenge.id
    else
        challenge = nil
    end
    Tickets[src] = ticket
    SetTimeout((num(G.MaxSeconds, 60) + 5) * 1000, function()
        if Tickets[src] ~= ticket then return end
        Tickets[src] = nil
        if ticket.challengeId then pcall(function() exports['pfm-minigames']:Cancel(src, ticket.challengeId) end) end
    end)
    TriggerClientEvent('prison:client:GateHackStart', src, gate, ticket.id, challenge)
end)

-- Gate hack, step 2: once per hack, MinSeconds..MaxSeconds after the start, still at the gate. The
-- server-checked puzzle decides when there is one; without pfm-minigames challenges the result is
-- the client's word. A pass opens the gate (server-side through pfm-doorlock); a fail locks down.
RegisterNetEvent('prison:server:GateHackResult', function(ticketId, ok)
    local src = source
    local ticket = Tickets[src]
    if not ticket or ticket.id ~= tonumber(ticketId) then return end
    Tickets[src] = nil
    local Player = getPlayer(src)
    if not Player or sentenceOf(Player) <= 0 then
        if ticket.challengeId then pcall(function() exports['pfm-minigames']:Cancel(src, ticket.challengeId) end) end
        return
    end
    local passed
    if ticket.challengeId then
        local okV, verdict = pcall(function() return exports['pfm-minigames']:Verify(src, ticket.challengeId) end)
        passed = okV and verdict == true
    else
        passed = ok == true
    end
    local now = os.time()
    local elapsed = now - ticket.at
    local inTime = elapsed >= num(G.MinSeconds, 5) and elapsed <= num(G.MaxSeconds, 60)
    local pos = pedPos(src)
    local near = pos ~= nil and #(pos - Gates[ticket.gate].coords) <= num(G.Reach, 2.5) + 1.0
    if passed and inTime and near and not GateOpen[ticket.gate] and LockdownUntil <= now then
        OpenGate(ticket.gate, src)
    else
        Lockdown()
    end
end)

-- What a client that just loaded needs to show: alarm, lockdown and the open gates.
QBCore.Functions.CreateCallback('prison:server:GetState', function(_, cb)
    local now = os.time()
    local open = {}
    for i in pairs(GateOpen) do open[#open + 1] = i end
    cb({ alarm = AlarmActivated, lockdown = LockdownUntil > now, gates = open })
end)

QBCore.Functions.CreateCallback('prison:server:IsAlarmActive', function(_, cb)
    cb(AlarmActivated)
end)

RegisterNetEvent('prison:server:CheckRecordStatus', function()
    local src = source
    local Player = getPlayer(src)
    if not Player then return end
    local CriminalRecord = Player.PlayerData.metadata['criminalrecord']
    local currentDate = os.date('*t')
    if type(CriminalRecord) ~= 'table' or type(CriminalRecord['date']) ~= 'table' or not CriminalRecord['date'].month then return end

    if (CriminalRecord['date'].month + 1) == 13 then
        CriminalRecord['date'].month = 0
    end

    if CriminalRecord['hasRecord'] then
        if currentDate.month == (CriminalRecord['date'].month + 1) or currentDate.day == (CriminalRecord['date'].day - 1) then
            CriminalRecord['hasRecord'] = false
            CriminalRecord['date'] = nil
        end
    end
end)

-- ── players coming and going ───────────────────────────────────────

local function onLoaded(src, metadata)
    local left = math.floor(num(metadata['injail'], 0))
    if left > 0 then
        -- the client takes them to a cell when it loads; the server gives the job spot
        startTracking(src)
        local job = AssignJob(src)
        TriggerClientEvent('prison:client:SetJob', src, job and job.name, job and job.location, left)
    elseif metadata['jailid'] ~= nil then
        -- served (or unjailed) while the release could not finish: finish it now
        PFPrison.Release(src, 'login')
    elseif type(metadata['jailitems']) == 'table' and next(metadata['jailitems']) ~= nil then
        ReturnItems(src)
    end
end

AddEventHandler('QBCore:Server:PlayerLoaded', function(LoadedPlayer)
    local data = type(LoadedPlayer) == 'table' and LoadedPlayer.PlayerData
    if not data or not tonumber(data.source) then return end
    onLoaded(tonumber(data.source), data.metadata or {})
end)

-- A restart of this resource picks up everyone already serving.
CreateThread(function()
    for _, src in ipairs(QBCore.Functions.GetPlayers() or {}) do
        local Player = getPlayer(src)
        if Player and sentenceOf(Player) > 0 then onLoaded(tonumber(src), Player.PlayerData.metadata) end
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    if Tickets[src] and Tickets[src].challengeId then
        local id = Tickets[src].challengeId
        pcall(function() exports['pfm-minigames']:Cancel(src, id) end)
    end
    forget(src)
    LastHackStart[src], LastAsk[src] = nil, nil
end)
