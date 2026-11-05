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
--
-- Batch 16 (pf-justice): every inmate is held under one of two regimes.
--   'legacy'  the old runtime above: metadata injail counted down here, items in metadata jailitems.
--             Used only while pf-justice still says Config.Compat.LegacyRuntimes.prison ~= false.
--   'justice' a pf-justice order at Bolingbroke (server/justice_bridge.lua): pf-justice counts the
--             time (asking IsInside), the items are in its property locker, work is a time credit
--             through AdjustOrder and an escape suspends the order (items stay in the locker, D12).
-- The walls, gates, alarm, escape detection and work checks below are the same for both.

PFPrison = PFPrison or {}

local JailResourceAllowlist = Config.JailResourceAllowlist or {
    ['pfm-policejob'] = true,
    ['pfm-adminmenu'] = true,
}
local MaxJailTime = Config.MaxJailTime or 1440
local P = Config.Prison or {}
local G = Config.GateHack or {}
local Gates = Config.Gates or {}

local Inmates = {}       -- [src] = 'legacy' | 'justice' for every online player serving a sentence here
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
local jobSeq = 0

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

-- The pf-justice bridge (server/justice_bridge.lua) fills PFPrison.Bridge; these defaults keep the
-- old runtime working when it is not loaded.
PFPrison.Bridge = PFPrison.Bridge or {}
local function bridge(name)
    local fn = PFPrison.Bridge[name]
    if isCallable(fn) then return fn end
    return nil
end

--- Whether the old metadata runtime still owns sentences (pf-justice LegacyRuntimes.prison).
function PFPrison.LegacyRuntime()
    local fn = bridge('LegacyRuntime')
    if fn then return fn() == true end
    return true
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

-- Gates through pfm-doorlock SetDoorState (batch 15H: no player needed). Only when that export is
-- not there (an older pfm-doorlock) the old updateState path runs, which needs an online player.
local function setGate(gate, locked, reason)
    local ok, res = pcall(function()
        return exports['pfm-doorlock']:SetDoorState(gate.door or gate.gatekey, locked, { reason = reason })
    end)
    if ok and type(res) == 'table' and res.ok == true then return true end
    if ok and type(res) == 'table' and res.error == 'not_found' and gate.door then
        -- the alias did not resolve: try the door key itself
        local ok2, res2 = pcall(function() return exports['pfm-doorlock']:SetDoorState(gate.gatekey, locked, { reason = reason }) end)
        if ok2 and type(res2) == 'table' and res2.ok == true then return true end
    end
    return false
end

-- Hacked gates lock again when the alarm stops, or OpenSeconds after they opened.
local function RelockGate(i)
    local open = GateOpen[i]
    if not open then return end
    GateOpen[i] = nil
    if Gates[i] and not setGate(Gates[i], true, 'prison gate relocked') then
        local by = getPlayer(open.by) and open.by or anyOnlinePlayer()
        if by then
            TriggerEvent('qb-doorlock:server:updateState', Gates[i].gatekey, true, false, false, true, false, false, by)
        end
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
    local ev = bridge('Event')
    if ev then ev(nil, 'lockdown', { untilAt = LockdownUntil, reason = 'failed gate hack' }) end
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
    if not setGate(gate, false, 'prison gate hacked') then
        -- older pfm-doorlock: a one-time grant for the hacker, then the change with unlockAnyway
        pcall(function() exports['pfm-doorlock']:GrantDoorAccess(src, gate.gatekey, 10000) end)
        TriggerEvent('qb-doorlock:server:updateState', gate.gatekey, false, false, false, true, false, false, src)
    end
    TriggerClientEvent('prison:client:SetGateHit', -1, i, true)
    local B = bridge('Event')
    if B then B(nil, 'lockdown', { gate = i, opened = true }) end
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
    jobSeq = jobSeq + 1
    -- the ticket names this job in a pf-justice credit key (pfm-prison:credit:<orderId>:<ticket>):
    -- time-based, so it never repeats after a restart
    Jobs[src] = { name = name, location = location, assignedAt = os.time(), assignedPos = pedPos(src),
        ticket = ('%d-%d'):format(os.time(), jobSeq) }
    return Jobs[src]
end

local function jobSpot(job)
    local spots = job and Config.Locations.jobs[job.name]
    local spot = spots and spots[job.location]
    return spot and vector3(spot.coords.x, spot.coords.y, spot.coords.z) or nil
end

-- ── sentence ───────────────────────────────────────────────────────

local function forget(src)
    Inmates[src], Track[src], LastTick[src], Jobs[src], Tickets[src] = nil, nil, nil, nil, nil
end

local function startTracking(src, regime)
    Inmates[src] = regime or 'legacy'
    LastTick[src] = os.time()
    Track[src] = { graceUntil = os.time() + grace() }
end

--- The regime an online player is held under here ('legacy' | 'justice'), or nil.
function PFPrison.Regime(src)
    src = tonumber(src)
    if not src then return nil end
    if Inmates[src] then return Inmates[src] end
    local admitted = bridge('IsAdmitted')
    if admitted and admitted(src) then return 'justice' end
    if PFPrison.LegacyRuntime() then
        local Player = getPlayer(src)
        if Player and sentenceOf(Player) > 0 then return 'legacy' end
    end
    return nil
end

function PFPrison.IsServing(src) return PFPrison.Regime(src) ~= nil end

--- Minutes left as this prison shows them (pf-justice's clock for a 'justice' inmate).
function PFPrison.TimeLeft(src)
    local regime = PFPrison.Regime(src)
    if regime == 'justice' then
        local fn = bridge('Minutes')
        return fn and fn(src) or 0
    end
    local Player = getPlayer(src)
    return Player and sentenceOf(Player) or 0
end

-- Owner decision D1: an inmate keeps the job and goes off duty (Config.Prison.KeepJob); with
-- KeepJob = false the old way (unemployed) applies.
local function forceOffDuty(src, Player)
    local job = Player.PlayerData.job
    if not job or not job.onduty then return false end
    local fn = Player.Functions and Player.Functions.SetJobDuty
    if not isCallable(fn) then fn = Player.SetJobDuty end
    if not isCallable(fn) then return false end
    fn(false)
    TriggerClientEvent('QBCore:Client:SetDuty', src, false)
    -- duty counts, MDT rosters and pf-government shifts listen to this
    TriggerEvent('QBCore:Server:SetDuty', src, false)
    return true
end

function PFPrison.ApplyJobRule(src)
    local Player = getPlayer(src)
    if not Player or not Player.PlayerData.job then return end
    if P.KeepJob ~= false then
        if forceOffDuty(src, Player) then notify(src, Lang:t('info.off_duty_jailed'), 'error') end
        return
    end
    if Player.PlayerData.job.name ~= 'unemployed' then
        local setJob = Player.Functions and Player.Functions.SetJob
        if not isCallable(setJob) then setJob = Player.SetJob end
        if isCallable(setJob) then setJob('unemployed', 0) end
        notify(src, Lang:t('info.lost_job'))
    end
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
    PFPrison.ApplyJobRule(src)
    if not already then
        GotPhone[cid] = nil
        -- jail money through the bank ledger, once per sentence (the key is the sentence's own)
        local money = math.floor(num(P.JailMoney, 80))
        if money > 0 then
            PFPayout.Pay(cid, 'cash', money, { key = ('pfm-prison:jailmoney:%s:%s'):format(cid, jailId), reason = 'jail money', quiet = true })
        end
    end
    startTracking(src, 'legacy')
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
    -- a pf-justice order that waited for this old sentence to end is taken in now
    local after = bridge('OnLegacyReleased')
    if after then after(src) end
    return true
end

-- A confirmed escape. Old runtime: the sentence ends and the stored items are forfeited. pf-justice:
-- the order is suspended and the items stay in the property locker (owner decision D12). Either way
-- the city and the police hear of it.
local function Escape(src, pos)
    local Player = getPlayer(src)
    if not Player then return end
    if Inmates[src] == 'justice' then
        forget(src)
        local onEscape = bridge('OnEscape')
        if onEscape then onEscape(src, pos) end
        ReportEscape(Player, pos)
        BreakAlarm()
        TriggerClientEvent('prison:client:Escaped', src, { suspended = true })
        return
    end
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
    TriggerClientEvent('prison:client:Enter', src, PFPrison.TimeLeft(src), job and job.name, job and job.location, true,
        Inmates[src] == 'justice')
    notify(src, 'You were taken back to your cell', 'error')
    local ev = bridge('Event')
    if ev then ev(Player.PlayerData.citizenid, 'sendback', { x = math.floor(t.lastSeenX or 0), y = math.floor(t.lastSeenY or 0) }) end
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
    t.lastSeenX, t.lastSeenY = pos.x, pos.y
    -- prison work: how long the server has seen the inmate standing at the job spot
    local job = Jobs[src]
    if job then
        local spot = jobSpot(job)
        if spot and #(pos - spot) <= num(P.JobReach, 3.5) + 1.0 then
            job.onSpotSince = job.onSpotSince or now
        else
            job.onSpotSince = nil
        end
    end
    if t.graceUntil and now < t.graceUntil then
        if inside then t.lastInside = t.last end
        return
    end
    if prev then
        local dt = math.max(1, now - prev.at)
        if #(pos - prev.pos) > num(P.MaxSpeed, 30.0) * dt + 10.0 then
            -- a teleport: the path so far proves nothing (and no prison work counts across it)
            t.passedGateAt, t.lastInside = nil, nil
            t.teleportAt = now
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
    local list = {}
    for src, regime in pairs(Inmates) do list[#list + 1] = { src = src, regime = regime } end
    for _, e in ipairs(list) do
        local src = e.src
        local Player = getPlayer(src)
        if not Player then
            forget(src)
        elseif e.regime == 'justice' then
            local admitted = bridge('IsAdmitted')
            if admitted and admitted(src) then sample(src, now) else forget(src) end
        elseif sentenceOf(Player) > 0 then
            sample(src, now)
        end
    end
    -- escapees of a pf-justice order: one seen back inside the walls serves on
    local watch = bridge('WatchEscapees')
    if watch then watch(now) end
end

--- Counts every inmate's sentence down by a minute per minute they spent inside the walls, and
--- releases those whose time is served (every 15 s; also used by tests).
function PFPrison.MinuteTick()
    local now = os.time()
    local list = {}
    for src, regime in pairs(Inmates) do if regime == 'legacy' then list[#list + 1] = src end end
    for _, src in ipairs(list) do
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

-- Legacy exports (legacy shapes: ok, err / minutes). Once pf-justice owns prison sentences they
-- forward to it: JailPlayer -> CreateOrder (kind 'prison'), ReleasePlayer -> ReleaseNow, GetJailTime
-- -> GetJailMinutes (justice_bridge.lua).
exports('JailPlayer', function(src, minutes, opts)
    if not allowedInvoker() then return false, 'not_allowed' end
    opts = type(opts) == 'table' and opts or {}
    if not PFPrison.LegacyRuntime() then
        local fwd = bridge('ForwardJail')
        if not fwd then return false, 'justice_unavailable' end
        return fwd(src, minutes, opts, GetInvokingResource())
    end
    return PFPrison.Jail(src, minutes, opts)
end)

exports('ReleasePlayer', function(src, reason)
    if not allowedInvoker() then return false, 'not_allowed' end
    reason = type(reason) == 'string' and reason:sub(1, 32) or 'release'
    -- a pf-justice inmate is released by pf-justice (also while the old runtime still runs)
    if not PFPrison.LegacyRuntime() or PFPrison.Regime(src) == 'justice' then
        local fwd = bridge('ForwardRelease')
        if not fwd then return false, 'justice_unavailable' end
        return fwd(src, reason, GetInvokingResource())
    end
    return PFPrison.Release(src, reason)
end)

exports('GetJailTime', function(src)
    if not PFPrison.LegacyRuntime() or PFPrison.Regime(src) == 'justice' then
        local fn = bridge('JailMinutes')
        return fn and fn(src) or 0
    end
    local Player = getPlayer(src)
    return Player and sentenceOf(Player) or 0
end)

-- ── net events (inmates) ───────────────────────────────────────────

-- Prison work: the server gave the spot; finishing it there (in reasonable time) may cut the
-- sentence by 1-2 months (the client used to cut its own time) and may turn up a phone. The server
-- must have seen the inmate get there at a plausible speed (no teleport since the job was given)
-- and stand at the spot for JobDwellSeconds (lead carry-over c: a teleport from spot to spot used
-- to earn a cut every JobMinSeconds). A 'justice' inmate's cut is a pf-justice time credit.
RegisterNetEvent('prison:server:JobDone', function(location)
    local src = source
    local job = Jobs[src]
    if not job then return end
    location = math.tointeger(tonumber(location))
    if location ~= job.location then return end
    local regime = PFPrison.Regime(src)
    local Player = getPlayer(src)
    if not Player or not regime then return end
    local now = os.time()
    local spot = jobSpot(job)
    local pos = pedPos(src)
    if not spot or not pos or #(pos - spot) > num(P.JobReach, 3.5) then return end
    local travel = job.assignedPos and #(spot - job.assignedPos) / math.max(1.0, num(P.JobTravelSpeed, 8.0)) or 0
    if now - job.assignedAt < num(P.JobMinSeconds, 8) + travel then return end
    local t = Track[src]
    if t and t.teleportAt and t.teleportAt >= job.assignedAt then
        -- moved by a teleport since the job was given: no cut; a new spot from where they are now
        local ev = bridge('Event')
        if ev then ev(Player.PlayerData.citizenid, 'anomaly', { what = 'job_teleport', job = job.name, spot = location }) end
        local nextJob = AssignJob(src, job.name, location)
        TriggerClientEvent('prison:client:SetJob', src, nextJob.name, nextJob.location, PFPrison.TimeLeft(src))
        return
    end
    if not job.onSpotSince or now - job.onSpotSince < num(P.JobDwellSeconds, 3) then return end
    -- the job is used up before anything that can wait (a pf-justice credit)
    Jobs[src] = nil

    local left = PFPrison.TimeLeft(src)
    if math.random(1, 100) <= 50 then
        local cut = math.random(1, 2)
        if regime == 'justice' then
            local credit = bridge('Credit')
            local res = credit and credit(src, job, cut * 60)
            if res then left = res end
        else
            left = math.max(0, left - cut)
            setMeta(Player, 'injail', left)
            notify(src, Lang:t('success.time_cut'))
        end
    end
    Player = getPlayer(src)
    if not Player then return end
    local cid = Player.PlayerData.citizenid
    if not GotPhone[cid] and math.random(1, 100) <= num(P.PhoneChance, 1) then
        local ok, added = pcall(function() return exports['pfm-inventory']:AddItem(src, 'phone', 1, false, false, 'prison:server:JobDone') end)
        if ok and added then
            GotPhone[cid] = true
            TriggerClientEvent('qb-inventory:client:ItemBox', src, sharedItems['phone'], 'add')
            notify(src, Lang:t('success.found_phone'), 'success')
        end
    end
    if regime == 'legacy' and left <= 0 then
        notify(src, Lang:t('success.timesup'), 'success')
        PFPrison.Release(src, 'served', true)
        return
    end
    -- a 'justice' inmate whose credit ended the sentence is released by pf-justice's event
    if not Inmates[src] then return end
    local nextJob = AssignJob(src, job.name, location)
    TriggerClientEvent('prison:client:SetJob', src, nextJob.name, nextJob.location, left)
end)

-- The client asks for its time and job spot (after a load, a respawn, the desk): the server's own.
-- wantEnter: the client wants to be taken to a cell if it is serving (after a login or a respawn
-- in the prison infirmary); the server decides and sends prison:client:Enter.
RegisterNetEvent('prison:server:RequestState', function(wantEnter)
    local src = source
    local now = os.time()
    if LastAsk[src] and now - LastAsk[src] < 2 then return end
    LastAsk[src] = now
    local Player = getPlayer(src)
    if not Player then return end
    wantEnter = wantEnter == true
    local ask = bridge('RequestState')
    if Inmates[src] ~= 'legacy' and ask and ask(src, wantEnter) then return end
    if not PFPrison.LegacyRuntime() then return end
    local left = sentenceOf(Player)
    if left <= 0 then
        if Player.PlayerData.metadata['jailid'] ~= nil then PFPrison.Release(src, 'served') end
        return
    end
    if not Inmates[src] then startTracking(src, 'legacy') end
    local job = Jobs[src] or AssignJob(src)
    if wantEnter then
        TriggerClientEvent('prison:client:Enter', src, left, job and job.name, job and job.location, true, false)
    else
        TriggerClientEvent('prison:client:SetJob', src, job and job.name, job and job.location, left)
    end
end)

-- Gate hack, step 1: an inmate at a gate's hack point with an electronickit and a gatecrack (the
-- gatecrack is used up). The server issues the hacking puzzle (pfm-minigames) when it can.
RegisterNetEvent('prison:server:StartGateHack', function(gate)
    local src = source
    gate = math.tointeger(tonumber(gate))
    local g = gate and Gates[gate]
    if not g then return end
    local Player = getPlayer(src)
    if not Player or not PFPrison.IsServing(src) then return end
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
    if not Player or not PFPrison.IsServing(src) then
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

-- The old runtime at a login. Only while it owns sentences: once pf-justice does, injail is
-- pf-justice's mirror and jailitems were moved into its property locker by its legacy import
-- (restoring them here as well would give every item back twice).
local function onLoaded(src, metadata)
    if not PFPrison.LegacyRuntime() then return end
    local left = math.floor(num(metadata['injail'], 0))
    if left > 0 then
        -- the client asks to be taken to a cell when it loads; the server gives the job spot
        startTracking(src, 'legacy')
        local job = AssignJob(src)
        TriggerClientEvent('prison:client:SetJob', src, job and job.name, job and job.location, left)
    elseif metadata['jailid'] ~= nil then
        -- served (or unjailed) while the release could not finish: finish it now
        PFPrison.Release(src, 'login')
    elseif type(metadata['jailitems']) == 'table' and next(metadata['jailitems']) ~= nil then
        ReturnItems(src)
    end
end
PFPrison.OnLoadedLegacy = onLoaded

AddEventHandler('QBCore:Server:PlayerLoaded', function(LoadedPlayer)
    local data = type(LoadedPlayer) == 'table' and LoadedPlayer.PlayerData
    if not data or not tonumber(data.source) then return end
    local src = tonumber(data.source)
    onLoaded(src, data.metadata or {})
    local loaded = bridge('OnPlayerLoaded')
    if loaded then loaded(src) end
end)

-- A restart of this resource picks up everyone already serving under the old runtime (pf-justice
-- inmates are picked up by the bridge's Boot).
CreateThread(function()
    for _, src in ipairs(QBCore.Functions.GetPlayers() or {}) do
        local Player = getPlayer(src)
        if Player and sentenceOf(Player) > 0 then onLoaded(tonumber(src), Player.PlayerData.metadata) end
    end
end)

-- Owner decision D1: nobody serving here goes on duty (pf-government's shift check does the same
-- while it runs; this covers a server without it).
AddEventHandler('QBCore:Server:SetDuty', function(src, onDuty)
    src = tonumber(src)
    if not src or onDuty ~= true or P.KeepJob == false then return end
    if not PFPrison.IsServing(src) then return end
    local Player = getPlayer(src)
    if Player and forceOffDuty(src, Player) then notify(src, Lang:t('info.off_duty_jailed'), 'error') end
end)

AddEventHandler('playerDropped', function()
    local src = source
    if Tickets[src] and Tickets[src].challengeId then
        local id = Tickets[src].challengeId
        pcall(function() exports['pfm-minigames']:Cancel(src, id) end)
    end
    forget(src)
    LastHackStart[src], LastAsk[src] = nil, nil
    local dropped = bridge('OnDropped')
    if dropped then dropped(src) end
end)

-- What server/justice_bridge.lua uses of this file (one runtime: the same walls, gates, tracking
-- and work for both regimes).
PFPrison.Internal = {
    getPlayer = getPlayer, setMeta = setMeta, isCallable = isCallable, pedPos = pedPos, notify = notify,
    insidePrison = insidePrison, sentenceOf = sentenceOf,
    startTracking = startTracking, forget = forget, assignJob = AssignJob, jobSpot = jobSpot,
    reportEscape = ReportEscape, breakAlarm = BreakAlarm,
    inmates = Inmates, track = Track, jobs = Jobs, gotPhone = GotPhone, gateOpen = GateOpen,
    lockdownUntil = function() return LockdownUntil end, alarmActive = function() return AlarmActivated end,
    players = function() return QBCore.Functions.GetPlayers() or {} end,
}
