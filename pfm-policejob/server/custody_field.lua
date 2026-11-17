-- Field custody (batch 18A, architecture 4.10 and 5.4): surrender, detain, frisk, zipties, escort,
-- carry, vehicle placement, arrest, release at the scene, hand-over between officers, property
-- seizure and holding cells.
--
-- The server owns every piece of state here. The client asks (net events below) and is told the
-- result; it never reports a state. Per target the server keeps:
--   Field[target]   = { state = 'surrendered' | 'detained', by, since, untilAt }  (hands up / held)
--   Escort[target]  = { by, kind = 'escort' | 'carry', since }                       (attached to someone)
--   Seat[target]    = { vehicle, netId, seat, by, tried = { [seat] = true } }        (placed in a car)
--   Lead[target]    = officer source responsible at the scene (arrest / hand-over)
-- The state bag pf:escort = { state, by } is written from these (server only) so other clients can
-- show the right target options and animations; GetFieldState(src) returns the same for servers.
--
-- Rules for every net event (architecture 6.2): numeric ids only, one action of a kind per second per
-- player, server positions within Config.CustodyField.TouchDistance (2.5 m), job and duty read from
-- pfm-core. Civilians may still drag or carry a cuffed or downed player and put them in a car (by
-- design); detaining, frisking, arresting, releasing and hand-overs are on-duty police only.
-- Detention (this file) and custody (pf-justice) are separate: detaining creates no record; the arrest
-- opens a pf-justice custody (OpenCustody) and a car placement moves it to in_transport.

PoliceField = PoliceField or {}
local F = PoliceField

local Field, Escort, Seat, Lead = {}, {}, {}, {}
local Rate = {}        -- [src] = { [action] = GetGameTimer() }
local Frisks = {}      -- [officerSrc] = { target, cid, at, nonce, items = { [slot] = { name, serial } } }
local LockedCells = {} -- [custodyId] = door alias locked by PlaceInCell (unlocked when the custody closes)
local arrestLock = {}  -- [citizenid] = true while an arrest for them waits on pf-justice
F._state = { Field = Field, Escort = Escort, Seat = Seat, Lead = Lead, Frisks = Frisks, LockedCells = LockedCells }

local RESOURCE = 'pfm-policejob'

local function cfg() return (Config and Config.CustodyField) or {} end
local function touch() return tonumber(cfg().TouchDistance) or 2.5 end

local function notify(src, msg, kind)
    TriggerClientEvent('QBCore:Notify', src, msg, kind or 'error')
end

--- Locale text (locales/*.lua 'field.*'), the English fallback when a locale lacks it; %{name}
--- placeholders are filled from params either way.
local function t(key, fallback, params)
    local ok, s = pcall(function() return Lang:t('field.' .. key, params) end)
    if not ok or type(s) ~= 'string' or s == 'field.' .. key then s = fallback end
    for k, v in pairs(params or {}) do s = (s:gsub('%%{' .. k .. '}', (tostring(v):gsub('%%', '%%%%')))) end
    return s
end

local function getPlayer(src) return src and exports['pfm-core']:GetPlayer(src) or nil end

local function isLeo(P) return P ~= nil and P.PlayerData.job.type == 'leo' and P.PlayerData.job.onduty == true end
local function meta(P) return P.PlayerData.metadata or {} end
local function isDown(P) local m = meta(P) return m['isdead'] == true or m['inlaststand'] == true end
local function isCuffed(P) return meta(P)['ishandcuffed'] == true end

--- Server id from a client argument: an integer of an online player, or nil.
local function toSrc(v)
    local n = tonumber(v)
    if not n or n ~= n or n < 1 or n > 65535 or n % 1 ~= 0 then return nil end
    local ped = GetPlayerPed(n)
    if not ped or ped == 0 then return nil end
    return n
end
F.ToSrc = toSrc

local function pos(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    return GetEntityCoords(ped)
end

local function dist(a, b)
    if not a or not b then return math.huge end
    local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function near(a, b, limit) return dist(pos(a), pos(b)) <= (limit or touch()) end
F.Near = near

--- One action of each kind per RateMs per player (architecture 6.3: field custody actions 1/s).
local function allow(src, action)
    local now = GetGameTimer()
    Rate[src] = Rate[src] or {}
    local last = Rate[src][action]
    if last and now - last < (tonumber(cfg().RateMs) or 1000) then return false end
    Rate[src][action] = now
    return true
end
F.Allow = allow

local function cid(P) return P.PlayerData.citizenid end

local function callable(v)
    if type(v) == 'function' then return true end
    if type(v) ~= 'table' then return false end
    if type(rawget(v, '__cfx_functionReference')) == 'string' then return true end
    local mt = getmetatable(v)
    return type(mt) == 'table' and rawget(mt, '__call') ~= nil
end

-- ── public state ────────────────────────────────────────────────────────────────────────────────

--- The state other resources and clients see: escorted/carried > in_vehicle > detained > surrendered.
function F.StateOf(target)
    local e = Escort[target]
    if e then return e.kind == 'carry' and 'carried' or 'escorted', e.by end
    local s = Seat[target]
    if s and s.placed then
        -- out of that car by now (driven off, pulled out by a script): the placement is over
        local ped = GetPlayerPed(target)
        if ped and ped ~= 0 and GetVehiclePedIsIn(ped, false) == s.vehicle then return 'in_vehicle', s.by end
        Seat[target] = nil
    end
    local f = Field[target]
    if f then return f.state, f.by end
    return 'free', nil
end

--- Writes the replicated bag pf:escort and tells the target's own client (it plays the animation).
function F.Sync(target)
    local state, by = F.StateOf(target)
    local value = state ~= 'free' and { state = state, by = by } or nil
    pcall(function() Player(target).state:set('pf:escort', value, true) end)
    TriggerClientEvent('police:client:FieldState', target, state, by)
end

--- exports['pfm-policejob']:GetFieldState(src) -> { ok, state, by, lead, since, cuffed, cuffKind, vehicle, seat }
function F.GetFieldState(who)
    local src = tonumber(who)
    local P = src and getPlayer(src)
    if not P then return { ok = false, error = 'not_found', message = 'No such player' } end
    local state, by = F.StateOf(src)
    local rec = PoliceCuffRecord and PoliceCuffRecord(src) or nil
    local out = { ok = true, state = state, by = by, lead = Lead[src], cuffed = isCuffed(P), down = isDown(P) }
    if out.cuffed then out.cuffKind = rec and rec.kind or 'handcuffs' end
    local f = Field[src]
    out.since = (Escort[src] and Escort[src].since) or (f and f.since) or nil
    local s = Seat[src]
    if s and s.placed then out.vehicle, out.seat = s.netId, s.seat end
    return out
end
exports('GetFieldState', function(who) return F.GetFieldState(who) end)

-- ── links to other modules ──────────────────────────────────────────────────────────────────────

--- Telemetry timeline (18C: MarkTimeline(who, kind, data), written while the officer records). Kinds
--- used here: use_of_force (data.kind = handcuffs | ziptie), detain, frisk, escort, arrest, release,
--- and note (data.action = seizure | transport | handover | holding_cell). Never breaks the action.
function F.Mark(src, kind, data)
    pcall(function()
        local T = PFTelemetry
        if type(T) == 'table' and callable(T.Mark) then return T.Mark(src, kind, data) end
        return exports[RESOURCE]:MarkTimeline(src, kind, data)
    end)
end

local function justice() return PoliceJustice end

--- The open pf-justice custody of a player (public shape) or nil.
function F.OpenCustody(src)
    local J = justice()
    if not J or not J.Up() then return nil end
    local res = J.Call('GetCustody', src)
    local c = type(res) == 'table' and res.ok and res.custody or nil
    if type(c) == 'table' and c.id and not c.closedAt then return c end
    return nil
end

local function custodyLog(custodyId, kind, data, actorSrc)
    local J = justice()
    if not custodyId or not J then return end
    J.Call('AddCustodyLog', custodyId, kind, data, { actor = { src = actorSrc } })
end

-- ── clearing ────────────────────────────────────────────────────────────────────────────────────

--- Ends an escort or carry: the target is detached, the escorting player's animation stops.
function F.EndEscort(target, why)
    local e = Escort[target]
    if not e then return false end
    Escort[target] = nil
    TriggerClientEvent('police:client:SetEscorted', target, false, e.by, e.kind)
    if e.by and GetPlayerPed(e.by) ~= 0 then TriggerClientEvent('police:client:EscortEnded', e.by, target, e.kind, why) end
    F.Sync(target)
    return true
end

--- Everything this module holds about a target (jailed, released, dropped).
function F.Clear(target, why)
    target = tonumber(target)
    if not target then return end
    F.EndEscort(target, why)
    local had = Field[target] ~= nil or Seat[target] ~= nil
    Field[target], Seat[target], Lead[target] = nil, nil, nil
    if had then F.Sync(target) end
end

--- Called by PoliceSetCuffed when cuffs come off: an escort that rested on the cuffs ends.
function F.OnUncuffed(target)
    local e = Escort[target]
    if not e then return end
    local T = getPlayer(target)
    if T and isDown(T) then return end
    local f = Field[target]
    local by = getPlayer(e.by)
    if f and (f.state == 'detained' or f.state == 'surrendered') and isLeo(by) then return end
    F.EndEscort(target, 'uncuffed')
end

--- A player left. As the target: everything about them goes. As the escorting player: the target is
--- released from the escort (it stays cuffed as it was) and detentions they held end.
function F.OnDropped(src)
    Rate[src], Frisks[src] = nil, nil
    F.Clear(src, 'dropped')
    for target, e in pairs(Escort) do
        if e.by == src then
            F.EndEscort(target, 'escort_dropped')
            notify(target, t('escort_dropped', 'The person escorting you left; you are no longer escorted'), 'primary')
        end
    end
    for target, f in pairs(Field) do
        if f.by == src and f.state == 'detained' then Field[target] = nil F.Sync(target) end
    end
    for target, s in pairs(Seat) do
        if s.by == src and not s.placed then Seat[target] = nil end
    end
    for target, lead in pairs(Lead) do
        if lead == src then Lead[target] = nil end
    end
end

--- Expired surrenders and over-long detentions (called every 10 s; specs call it directly).
function F.Sweep(now)
    now = now or os.time()
    local maxDetain = (tonumber(cfg().DetainMaxMinutes) or 30) * 60
    for target, f in pairs(Field) do
        local expired = (f.state == 'surrendered' and f.untilAt and now >= f.untilAt)
            or (f.state == 'detained' and now - (f.since or now) >= maxDetain)
        if expired then
            Field[target] = nil
            F.Sync(target)
            notify(target, f.state == 'surrendered' and t('hands_down', 'You lowered your hands') or t('detain_expired', 'You are no longer detained'), 'primary')
        end
    end
end

CreateThread(function()
    while true do
        Wait(10000)
        F.Sweep()
    end
end)

-- ── common checks ───────────────────────────────────────────────────────────────────────────────

--- Checks shared by the officer actions: rate, ids, duty, reach. Returns actor, target players or nil.
local function officerAction(src, action, rawTarget)
    if type(src) ~= 'number' or src <= 0 then return nil end
    if not allow(src, action) then return nil end
    local target = toSrc(rawTarget)
    if not target or target == src then return nil end
    local A, T = getPlayer(src), getPlayer(target)
    if not A or not T then return nil end
    if not isLeo(A) then notify(src, t('police_only', 'For on-duty police only')) return nil end
    if not near(src, target) then notify(src, t('too_far', 'You must be right next to them')) return nil end
    return A, T, target
end

local function actorFree(src, A)
    return not isCuffed(A) and not isDown(A) and not Escort[src] and not (Field[src] and Field[src].state == 'detained')
end

-- ── surrender ───────────────────────────────────────────────────────────────────────────────────

--- police:server:Surrender: the player raises (or lowers) their hands; it lasts SurrenderSeconds.
function F.Surrender(src)
    if type(src) ~= 'number' or src <= 0 or not allow(src, 'surrender') then return false end
    local P = getPlayer(src)
    if not P then return false end
    local f = Field[src]
    if f and f.state == 'surrendered' then
        Field[src] = nil
        F.Sync(src)
        return true
    end
    if f or Escort[src] or F.StateOf(src) == 'in_vehicle' or isCuffed(P) or isDown(P) then return false end
    local now = os.time()
    Field[src] = { state = 'surrendered', since = now, untilAt = now + (tonumber(cfg().SurrenderSeconds) or 120) }
    F.Sync(src)
    return true
end
RegisterNetEvent('police:server:Surrender', function() F.Surrender(source) end)

-- ── detain ──────────────────────────────────────────────────────────────────────────────────────

--- police:server:Detain(target): on-duty police, 2.5 m; the target has their hands up, is cuffed or is
--- down. Detaining again releases the detention. No custody record (architecture 5.4).
function F.Detain(src, rawTarget)
    local A, T, target = officerAction(src, 'detain', rawTarget)
    if not A then return false end
    local f = Field[target]
    if f and f.state == 'detained' then
        Field[target] = nil
        F.Sync(target)
        notify(src, t('detain_ended', 'Detention ended'), 'success')
        notify(target, t('detain_expired', 'You are no longer detained'), 'primary')
        F.Mark(src, 'detain', { target = cid(T), ended = true })
        return true
    end
    if not (f and f.state == 'surrendered') and not isCuffed(T) and not isDown(T) then
        notify(src, t('detain_need', 'They must have their hands up, be cuffed or be down'))
        return false
    end
    Field[target] = { state = 'detained', by = src, since = os.time() }
    Lead[target] = Lead[target] or src
    F.Sync(target)
    notify(src, t('detained', 'Detained'), 'success')
    notify(target, t('you_detained', 'You are being detained'), 'primary')
    F.Mark(src, 'detain', { target = cid(T) })
    return true
end
RegisterNetEvent('police:server:Detain', function(target) F.Detain(source, target) end)

-- ── frisk ───────────────────────────────────────────────────────────────────────────────────────

-- Item text that reaches a client menu: printable, no markup characters, clipped.
local function plain(s, max)
    s = tostring(s or ''):gsub('[%c<>&"\'`]', ''):gsub('^%s+', ''):gsub('%s+$', '')
    return s:sub(1, max or 48)
end

local function itemDef(name)
    local items = QBCore and QBCore.Shared and QBCore.Shared.Items
    if type(items) ~= 'table' then
        local ok, shared = pcall(function() return exports['pfm-core']:GetShared('Items') end)
        items = ok and shared or {}
    end
    return items[name]
end

local function serialOf(item)
    local info = type(item.info) == 'table' and item.info or {}
    local s = info.serie or info.serial
    return type(s) == 'string' and plain(s, 32) or nil
end

--- Weapon items the target carries, read from the server's inventory copy.
function F.WeaponsOf(T)
    local out = {}
    for slot, item in pairs(T.PlayerData.items or {}) do
        if type(item) == 'table' and type(item.name) == 'string' then
            local def = itemDef(item.name)
            local kind = item.type or (def and def.type)
            if kind == 'weapon' then
                out[#out + 1] = { slot = tonumber(item.slot) or tonumber(slot), name = item.name,
                    label = plain((def and def.label) or item.label or item.name), serial = serialOf(item) }
            end
        end
    end
    table.sort(out, function(a, b) return (a.slot or 0) < (b.slot or 0) end)
    return out
end

--- police:server:Frisk(target): weapons-only pat-down. The officer gets the list the server read;
--- seizing one goes through police:server:FriskSeize within FriskSeconds.
function F.Frisk(src, rawTarget)
    local A, T, target = officerAction(src, 'frisk', rawTarget)
    if not A then return false end
    local f = Field[target]
    if not (f and (f.state == 'surrendered' or f.state == 'detained')) and not isCuffed(T) and not isDown(T) then
        notify(src, t('frisk_need', 'They must have their hands up, be detained, cuffed or down'))
        return false
    end
    local list = F.WeaponsOf(T)
    local session = { target = target, cid = cid(T), at = os.time(), nonce = PFPayout and PFPayout.NewId and PFPayout.NewId() or tostring(math.random(1, 1e9)), items = {} }
    for _, w in ipairs(list) do session.items[w.slot] = { name = w.name, serial = w.serial, label = w.label } end
    Frisks[src] = session
    TriggerClientEvent('police:client:FriskResult', src, target, list)
    notify(target, t('being_frisked', 'You are being patted down'), 'primary')
    F.Mark(src, 'frisk', { target = session.cid, weapons = #list })
    return true, list
end
RegisterNetEvent('police:server:Frisk', function(target) F.Frisk(source, target) end)

--- police:server:FriskSeize(target, slot): takes one listed weapon into evidence (an evidence bag in
--- the officer's inventory, chain of custody from the pat-down). The item leaves the target first;
--- if the evidence record fails it is handed back.
function F.FriskSeize(src, rawTarget, rawSlot)
    local A, T, target = officerAction(src, 'frisk_seize', rawTarget)
    if not A then return false end
    local session = Frisks[src]
    local slot = tonumber(rawSlot)
    if not session or session.target ~= target or session.cid ~= cid(T) or not slot or slot % 1 ~= 0 then return false end
    if os.time() - session.at > (tonumber(cfg().FriskSeconds) or 60) then
        Frisks[src] = nil
        notify(src, t('frisk_again', 'Pat them down again first'))
        return false
    end
    local listed = session.items[slot]
    if not listed then return false end
    T = getPlayer(target) -- fresh copy: the item must still be in that slot
    local item = T and (T.PlayerData.items or {})[slot]
    if type(item) ~= 'table' or item.name ~= listed.name or serialOf(item) ~= listed.serial then
        session.items[slot] = nil
        notify(src, t('frisk_gone', 'That item is no longer on them'))
        return false
    end
    local E = PFEvidence and PFEvidence.Api
    if not E or not callable(E.CreateEvidence) then
        notify(src, t('evidence_down', 'The evidence system is not available; nothing was seized'))
        return false
    end
    session.items[slot] = nil
    if not exports['pfm-inventory']:RemoveItem(target, item.name, 1, slot, 'police:server:FriskSeize') then
        notify(src, t('frisk_gone', 'That item is no longer on them'))
        return false
    end
    local p = pos(src)
    local res = E.CreateEvidence({
        kind = 'weapon', label = listed.label, attrs = { item = item.name, serial = listed.serial },
        scene = p and { coords = { x = p.x, y = p.y, z = p.z }, label = 'Pat-down' } or nil,
        collectedBy = src, method = 'search', origin = { type = 'frisk', id = session.cid },
    }, { key = ('pfm-policejob:frisk:%s:%s:%d'):format(session.cid, session.nonce, slot), giveTo = src, actor = { src = src } })
    if type(res) ~= 'table' or not res.ok then
        exports['pfm-inventory']:AddItem(target, item.name, 1, slot, item.info, 'police:server:FriskSeize:undo')
        notify(src, (type(res) == 'table' and res.message) or t('evidence_down', 'The evidence system is not available; nothing was seized'))
        return false
    end
    notify(src, t('frisk_seized', 'Seized into evidence (%{tag})', { tag = tostring(res.tag) }), 'success')
    notify(target, t('item_seized', 'An officer took a weapon from you'), 'error')
    F.Mark(src, 'note', { action = 'seizure', target = session.cid, evidenceId = res.evidenceId, item = item.name })
    local c = F.OpenCustody(target)
    if c then custodyLog(c.id, 'note', { text = 'Weapon seized at pat-down', evidenceId = res.evidenceId }, src) end
    return true, res
end
RegisterNetEvent('police:server:FriskSeize', function(target, slot) F.FriskSeize(source, target, slot) end)

-- ── zipties ─────────────────────────────────────────────────────────────────────────────────────

--- police:server:Ziptie(target): anyone with a zipties item; the target has their hands up, is detained
--- or is down (no resist window: they are not fighting). The item is used up on the server first; the
--- cuff state is the server's (soft, kind 'ziptie'), so every cuff check sees it.
function F.Ziptie(src, rawTarget)
    if type(src) ~= 'number' or src <= 0 or not allow(src, 'ziptie') then return false end
    local target = toSrc(rawTarget)
    if not target or target == src then return false end
    local A, T = getPlayer(src), getPlayer(target)
    if not A or not T or not actorFree(src, A) then return false end
    if not near(src, target) then notify(src, t('too_far', 'You must be right next to them')) return false end
    if isCuffed(T) then notify(src, t('already_cuffed', 'They are already restrained')) return false end
    local f = Field[target]
    if not (f and (f.state == 'surrendered' or f.state == 'detained')) and not isDown(T) then
        notify(src, t('ziptie_need', 'They must have their hands up, be detained or be down'))
        return false
    end
    local item = cfg().ZiptieItem or 'zipties'
    if not exports['pfm-inventory']:RemoveItem(src, item, 1, false, 'police:server:Ziptie') then
        notify(src, t('no_zipties', 'You have no zipties'))
        return false
    end
    local leo = isLeo(A)
    PoliceSetCuffed(target, true, { soft = true, kind = 'ziptie', by = src, leo = leo })
    TriggerClientEvent('police:client:CuffAnimation', src, true)
    if f and f.state == 'surrendered' then Field[target] = nil F.Sync(target) end
    if leo then
        F.Mark(src, 'use_of_force', { kind = 'ziptie', target = cid(T) })
        local c = F.OpenCustody(target)
        if c then custodyLog(c.id, 'use_of_force', { kind = 'ziptie' }, src) end
    end
    return true
end
RegisterNetEvent('police:server:Ziptie', function(target) F.Ziptie(source, target) end)

--- police:server:CutZiptie(target): a ziptie_cutter item or on-duty police; only zipties come off this way.
function F.CutZiptie(src, rawTarget)
    if type(src) ~= 'number' or src <= 0 or not allow(src, 'cutziptie') then return false end
    local target = toSrc(rawTarget)
    if not target or target == src then return false end
    local A, T = getPlayer(src), getPlayer(target)
    if not A or not T or not actorFree(src, A) then return false end
    if not near(src, target) then notify(src, t('too_far', 'You must be right next to them')) return false end
    local rec = PoliceCuffRecord and PoliceCuffRecord(target)
    if not isCuffed(T) or not rec or rec.kind ~= 'ziptie' then notify(src, t('no_ziptie_on', 'They are not ziptied')) return false end
    local cutter = cfg().ZiptieCutterItem or 'ziptie_cutter'
    if not isLeo(A) and not exports['pfm-inventory']:HasItem(src, cutter, 1) then
        notify(src, t('no_cutter', 'You need a ziptie cutter'))
        return false
    end
    PoliceSetCuffed(target, false)
    return true
end
RegisterNetEvent('police:server:CutZiptie', function(target) F.CutZiptie(source, target) end)

-- ── escort and carry ────────────────────────────────────────────────────────────────────────────

--- May `A` move `T` around? Anyone: cuffed or down (by design; medics move down patients this way).
--- On-duty police also: detained or hands up.
local function canMove(A, T, target)
    if isCuffed(T) or isDown(T) then return true end
    local f = Field[target]
    if isLeo(A) and f and (f.state == 'detained' or f.state == 'surrendered') then return true end
    return false
end

local function startEscort(src, rawTarget, kind)
    if type(src) ~= 'number' or src <= 0 or not allow(src, kind) then return false end
    local target = toSrc(rawTarget)
    if not target or target == src then return false end
    local A, T = getPlayer(src), getPlayer(target)
    if not A or not T then return false end
    local e = Escort[target]
    if e and e.by == src then return F.EndEscort(target, 'stopped') end -- the same player lets go
    if not near(src, target) then notify(src, t('too_far', 'You must be right next to them')) return false end
    if not actorFree(src, A) then return false end
    if e then notify(src, t('already_escorted', 'Someone else is already holding them')) return false end
    for _, other in pairs(Escort) do
        if other.by == src then notify(src, t('hands_full', 'You are already escorting someone')) return false end
    end
    if F.StateOf(target) == 'in_vehicle' then notify(src, t('in_vehicle', 'Take them out of the vehicle first')) return false end
    if not canMove(A, T, target) then
        notify(src, Lang:t('error.not_cuffed_dead'))
        return false
    end
    Escort[target] = { by = src, kind = kind, since = os.time() }
    TriggerClientEvent('police:client:SetEscorted', target, true, src, kind)
    if kind == 'carry' then TriggerClientEvent('police:client:GetKidnappedDragger', src, target) end
    F.Sync(target)
    if isLeo(A) and kind == 'escort' then F.Mark(src, 'escort', { target = cid(T) }) end
    return true
end

function F.Escort(src, target) return startEscort(src, target, 'escort') end
function F.Carry(src, target) return startEscort(src, target, 'carry') end
RegisterNetEvent('police:server:EscortPlayer', function(target) F.Escort(source, target) end)
RegisterNetEvent('police:server:KidnapPlayer', function(target) F.Carry(source, target) end)

-- ── vehicle placement ───────────────────────────────────────────────────────────────────────────

local function seatOrder()
    local list = {}
    for _, s in ipairs(cfg().RearSeats or { 1, 2, 3, 4, 5, 6 }) do list[#list + 1] = s end
    if cfg().AllowFrontSeat then list[#list + 1] = 0 end
    return list
end

local function vehicleExists(veh)
    if not veh or veh == 0 then return false end
    if DoesEntityExist and not DoesEntityExist(veh) then return false end
    if GetEntityType and GetEntityType(veh) ~= 2 then return false end
    return true
end

--- The vehicle the officer means: the client's hint (a network id) when it really is a vehicle next
--- to both, otherwise the nearest vehicle to the officer. Positions are the server's.
function F.PickVehicle(src, target, netHint)
    local reach = tonumber(cfg().VehicleReach) or 6.0
    local a, b = pos(src), pos(target)
    local hint = tonumber(netHint)
    if hint and hint == hint and hint % 1 == 0 and hint > 0 then
        local veh = NetworkGetEntityFromNetworkId(hint)
        if vehicleExists(veh) then
            local v = GetEntityCoords(veh)
            if dist(a, v) <= reach and dist(b, v) <= reach + touch() then return veh end
        end
    end
    local best, bestD
    for _, veh in ipairs(GetAllVehicles and GetAllVehicles() or {}) do
        if vehicleExists(veh) then
            local d = dist(a, GetEntityCoords(veh))
            if d <= reach and (not bestD or d < bestD) then best, bestD = veh, d end
        end
    end
    return best
end

--- The first free seat in RearSeats order that has not been tried for this placement.
local function freeSeat(veh, tried, target)
    for _, seat in ipairs(seatOrder()) do
        if not tried[seat] and GetPedInVehicleSeat(veh, seat) == 0 then
            local taken = false
            for other, s in pairs(Seat) do
                if other ~= target and s.vehicle == veh and s.seat == seat then taken = true break end
            end
            if not taken then return seat end
        end
    end
    return nil
end

local function placeInSeat(target, s)
    local seat = freeSeat(s.vehicle, s.tried, target)
    if not seat then
        Seat[target] = nil
        F.Sync(target)
        if s.by and GetPlayerPed(s.by) ~= 0 then notify(s.by, t('no_seat', 'No free rear seat in that vehicle')) end
        return false
    end
    s.seat, s.tried[seat], s.attempts = seat, true, (s.attempts or 0) + 1
    -- the target's client detaches and sits in exactly this seat; the server sets it too
    TriggerClientEvent('police:client:PutInVehicle', target, s.netId, seat)
    local ped = GetPlayerPed(target)
    if SetPedIntoVehicle and ped and ped ~= 0 then pcall(SetPedIntoVehicle, ped, s.vehicle, seat) end
    SetTimeout(tonumber(cfg().SeatCheckMs) or 1500, function() F.VerifySeat(target) end)
    return true
end

--- After a placement: is the target really in that vehicle (server native)? If not (the seat does not
--- exist on that model, or was taken), the next free seat is tried; with none left the officer is told.
function F.VerifySeat(target)
    local s = Seat[target]
    if not s or s.placed then return s and s.placed or false end
    local ped = GetPlayerPed(target)
    if ped and ped ~= 0 and GetVehiclePedIsIn(ped, false) == s.vehicle then
        s.placed = true
        F.Sync(target)
        F.OnPlaced(target, s)
        return true
    end
    if not vehicleExists(s.vehicle) then Seat[target] = nil F.Sync(target) return false end
    return placeInSeat(target, s)
end

--- A placed suspect in an open custody moves to in_transport (pf-justice machine).
function F.OnPlaced(target, s)
    local A = getPlayer(s.by)
    if not isLeo(A) then return end
    local c = F.OpenCustody(target)
    if c and c.state == 'arrested' then
        PoliceJustice.Call('SetCustodyState', c.id, 'in_transport', { actor = { src = s.by }, note = 'Placed in a vehicle' })
    end
    F.Mark(s.by, 'note', { action = 'transport', target = cid(getPlayer(target) or { PlayerData = {} }), custodyId = c and c.id or nil })
end

--- police:server:PutPlayerInVehicle(target, vehicleNetIdHint)
function F.PutInVehicle(src, rawTarget, netHint)
    if type(src) ~= 'number' or src <= 0 or not allow(src, 'vehicle') then return false end
    local target = toSrc(rawTarget)
    if not target or target == src then return false end
    local A, T = getPlayer(src), getPlayer(target)
    if not A or not T or not actorFree(src, A) then return false end
    if not near(src, target) then notify(src, t('too_far', 'You must be right next to them')) return false end
    if not canMove(A, T, target) then notify(src, Lang:t('error.not_cuffed_dead')) return false end
    local e = Escort[target]
    if e and e.by ~= src then notify(src, t('already_escorted', 'Someone else is already holding them')) return false end
    local ped = GetPlayerPed(target)
    if GetVehiclePedIsIn(ped, false) ~= 0 then notify(src, t('already_in_vehicle', 'They are already in a vehicle')) return false end
    local veh = F.PickVehicle(src, target, netHint)
    if not veh then notify(src, t('no_vehicle', 'No vehicle next to you')) return false end
    if e then Escort[target] = nil TriggerClientEvent('police:client:EscortEnded', src, target, e.kind, 'vehicle') end
    local s = { vehicle = veh, netId = NetworkGetNetworkIdFromEntity(veh), by = src, tried = {} }
    Seat[target] = s
    if Field[target] and Field[target].state == 'surrendered' then Field[target] = nil end
    return placeInSeat(target, s)
end
RegisterNetEvent('police:server:PutPlayerInVehicle', function(target, netHint) F.PutInVehicle(source, target, netHint) end)

--- police:server:SetPlayerOutVehicle(target)
function F.TakeOutOfVehicle(src, rawTarget)
    if type(src) ~= 'number' or src <= 0 or not allow(src, 'vehicle') then return false end
    local target = toSrc(rawTarget)
    if not target or target == src then return false end
    local A, T = getPlayer(src), getPlayer(target)
    if not A or not T or not actorFree(src, A) then return false end
    if not near(src, target) then notify(src, t('too_far', 'You must be right next to them')) return false end
    if not canMove(A, T, target) then notify(src, Lang:t('error.not_cuffed_dead')) return false end
    local ped = GetPlayerPed(target)
    if GetVehiclePedIsIn(ped, false) == 0 then notify(src, t('not_in_vehicle', 'They are not in a vehicle')) return false end
    Seat[target] = nil
    TriggerClientEvent('police:client:SetOutVehicle', target)
    F.Sync(target)
    if isLeo(A) then
        local c = F.OpenCustody(target)
        if c and c.state == 'in_transport' then
            PoliceJustice.Call('SetCustodyState', c.id, 'arrested', { actor = { src = src }, note = 'Taken out of the vehicle' })
        end
    end
    return true
end
RegisterNetEvent('police:server:SetPlayerOutVehicle', function(target) F.TakeOutOfVehicle(source, target) end)

-- ── arrest, release, hand-over ──────────────────────────────────────────────────────────────────

--- police:server:Arrest(target): opens the pf-justice custody (state arrested). The suspect is cuffed
--- (handcuffs or zipties) or down. The key is the restraint episode plus a count, so a double event
--- finds the same custody and a later arrest in the same cuffs gets a new key.
function F.Arrest(src, rawTarget)
    local A, T, target = officerAction(src, 'arrest', rawTarget)
    if not A then return false end
    if cfg().ArrestNeedsRestraint ~= false and not isCuffed(T) and not isDown(T) then
        notify(src, t('arrest_need', 'Cuff them first'))
        return false
    end
    local J = justice()
    if not J or not J.Up() then notify(src, t('justice_down', 'The justice system is not available right now')) return false end
    local tcid = cid(T)
    if arrestLock[tcid] then return false end
    arrestLock[tcid] = true
    local ok, res = pcall(function()
        local rec = PoliceCuffRecord and PoliceCuffRecord(target) or nil
        -- a downed suspect without cuffs: the minute stands in for the restraint episode
        local episode = rec and rec.at or math.floor(os.time() / 60)
        local n = (rec and rec.arrests or 0) + 1
        local key = ('pfm-policejob:arrest:%s:%d:%d'):format(tcid, episode, n)
        local c = J.Call('OpenCustody', target, { reason = 'Field arrest', state = 'arrested', key = key, actor = { src = src } })
        if type(c) == 'table' and c.error == 'conflict' and tonumber(c.custodyId) then
            notify(src, t('already_custody', 'They are already in custody (#%{id})', { id = c.custodyId }))
            return { ok = false, error = 'conflict', custodyId = tonumber(c.custodyId) }
        end
        if type(c) ~= 'table' or not c.ok then
            notify(src, J.Text(c))
            return c
        end
        if rec then rec.arrests = n end
        if c.duplicate and (c.state == 'released' or c.state == 'transferred') then
            -- the key belongs to an arrest that is already over: nothing is open now
            notify(src, t('arrest_closed', 'That arrest is already closed; arrest them again'))
            return { ok = false, error = 'invalid_state' }
        end
        local custodyId = tonumber(c.custodyId)
        Lead[target] = src
        if Field[target] then Field[target] = nil end
        F.Sync(target)
        if not c.duplicate then
            if rec and isCuffed(T) then custodyLog(custodyId, 'use_of_force', { kind = rec.kind or 'handcuffs', soft = rec.soft == true }, src) end
            notify(src, t('arrested', 'Arrested: custody #%{id}', { id = custodyId }), 'success')
            notify(target, t('you_arrested', 'You are under arrest'), 'error')
        end
        F.Mark(src, 'arrest', { target = tcid, custodyId = custodyId })
        return { ok = true, custodyId = custodyId, duplicate = c.duplicate }
    end)
    arrestLock[tcid] = nil
    if not ok then
        print(('^1[pfm-policejob]^7 arrest failed: %s'):format(tostring(res)))
        notify(src, t('arrest_failed', 'The arrest failed; nothing was changed'))
        return false
    end
    return res
end
RegisterNetEvent('police:server:Arrest', function(target) F.Arrest(source, target) end)

--- police:server:ReleaseAtScene(target): no charges. An open custody closes through pf-justice
--- (ReleaseFromCustody 'no_charges': cuffs off, property back); without one the detention and the
--- police cuffs end here.
function F.ReleaseAtScene(src, rawTarget)
    local A, T, target = officerAction(src, 'release', rawTarget)
    if not A then return false end
    local c = F.OpenCustody(target)
    if c then
        local res = PoliceJustice.Call('ReleaseFromCustody', c.id, 'no_charges', { actor = { src = src }, note = 'Released at the scene' })
        if type(res) ~= 'table' or not res.ok then
            notify(src, PoliceJustice.Text(res))
            return false
        end
    elseif PoliceJustice and PoliceJustice.Up() then
        -- pf-justice running but GetCustody unknown: never release a custody blindly
        local res = PoliceJustice.Call('GetCustody', target)
        if type(res) ~= 'table' or not res.ok then
            notify(src, PoliceJustice.Text(res))
            return false
        end
    end
    local rec = PoliceCuffRecord and PoliceCuffRecord(target)
    T = getPlayer(target)
    if T and isCuffed(T) and (not rec or rec.leo or rec.by == src) then PoliceSetCuffed(target, false) end
    F.EndEscort(target, 'released')
    Field[target], Lead[target] = nil, nil
    if Seat[target] and not Seat[target].placed then Seat[target] = nil end
    F.Sync(target)
    notify(src, t('released', 'Released at the scene'), 'success')
    notify(target, t('you_released', 'You are free to go'), 'success')
    F.Mark(src, 'release', { target = T and cid(T) or nil, custodyId = c and c.id or nil })
    return true
end
RegisterNetEvent('police:server:ReleaseAtScene', function(target) F.ReleaseAtScene(source, target) end)

--- police:server:HandOver(target, toOfficer): the responsible officer hands the suspect to another
--- on-duty officer standing with them. The escort ends (the new officer takes them), the field lead
--- moves, and an open custody gets a log line naming both officers.
function F.HandOver(src, rawTarget, rawTo)
    local A, T, target = officerAction(src, 'handover', rawTarget)
    if not A then return false end
    local to = toSrc(rawTo)
    local B = to and getPlayer(to)
    if not B or to == src or to == target then notify(src, t('handover_who', 'Name an officer next to you')) return false end
    if not isLeo(B) then notify(src, t('handover_leo', 'They are not on-duty police')) return false end
    if not near(to, target) then notify(src, t('handover_far', 'The other officer must be next to the suspect')) return false end
    local c = F.OpenCustody(target)
    local responsible = Lead[target] == src or (Escort[target] and Escort[target].by == src)
        or (Field[target] and Field[target].by == src) or (c and c.officerCid == cid(A))
    if not responsible then notify(src, t('handover_not_yours', 'You are not the officer responsible for them')) return false end
    if Escort[target] and Escort[target].by == src then F.EndEscort(target, 'handover') end
    if Field[target] and Field[target].state == 'detained' then Field[target].by = to end
    if Seat[target] then Seat[target].by = to end
    Lead[target] = to
    F.Sync(target)
    if c then custodyLog(c.id, 'note', { text = 'Custody handed over at the scene', from = cid(A), to = cid(B) }, src) end
    notify(src, t('handover_done', 'Handed over'), 'success')
    notify(to, t('handover_received', 'You are now responsible for the suspect'), 'primary')
    F.Mark(src, 'note', { action = 'handover', target = cid(T), to = cid(B), custodyId = c and c.id or nil })
    F.Mark(to, 'note', { action = 'handover', target = cid(T), from = cid(A), custodyId = c and c.id or nil })
    return true
end
RegisterNetEvent('police:server:HandOver', function(target, to) F.HandOver(source, target, to) end)

--- police:server:SeizeProperty(target): everything but the kept items goes into a pf-justice property
--- locker linked to the open custody (one receipt per custody; a repeat returns the same receipt).
function F.SeizeProperty(src, rawTarget)
    local A, T, target = officerAction(src, 'property', rawTarget)
    if not A then return false end
    local c = F.OpenCustody(target)
    if not c then notify(src, t('need_custody', 'Arrest them first')) return false end
    local res = PoliceJustice.Call('SeizeProperty', target, {
        custodyId = c.id, items = 'all', keep = cfg().PropertyKeep or { 'phone' }, reason = 'Seized at arrest',
        key = ('pfm-policejob:property:%d'):format(c.id), actor = { src = src },
    })
    if type(res) ~= 'table' or not res.ok then notify(src, PoliceJustice.Text(res)) return false end
    notify(src, t('property_done', 'Property receipt #%{id}', { id = res.receiptId }), 'success')
    F.Mark(src, 'note', { action = 'seizure', target = cid(T), custodyId = c.id, receiptId = res.receiptId, items = res.items })
    return true, res
end
RegisterNetEvent('police:server:SeizeProperty', function(target) F.SeizeProperty(source, target) end)

--- police:server:PlaceInCell(target, cellId): a booked custody goes into a pf-justice holding cell
--- (AssignHoldingCell checks the state, the cell and the medical screening); then the cell door is
--- locked through pfm-doorlock SetDoorState (door alias = cell id) and unlocked when the custody closes.
function F.PlaceInCell(src, rawTarget, cellId)
    local A, T, target = officerAction(src, 'cell', rawTarget)
    if not A then return false end
    if type(cellId) ~= 'string' or #cellId < 1 or #cellId > 32 or cellId:find('[^%w_]') then return false end
    local c = F.OpenCustody(target)
    if not c then notify(src, t('need_custody', 'Arrest them first')) return false end
    local res = PoliceJustice.Call('AssignHoldingCell', c.id, cellId, { actor = { src = src } })
    if type(res) ~= 'table' or not res.ok then notify(src, PoliceJustice.Text(res)) return false end
    local door = cellId
    local locked = F.SetDoor(door, true)
    if locked then LockedCells[c.id] = door end
    if not locked then notify(src, t('door_manual', 'Placed in the cell; lock the door by hand'), 'primary')
    else notify(src, t('in_cell', 'Placed in the cell'), 'success') end
    F.Mark(src, 'note', { action = 'holding_cell', target = cid(T), custodyId = c.id, cell = cellId })
    return true
end
RegisterNetEvent('police:server:PlaceInCell', function(target, cellId) F.PlaceInCell(source, target, cellId) end)

function F.SetDoor(door, locked)
    if GetResourceState('pfm-doorlock') ~= 'started' then return false end
    local ok, res = pcall(function() return exports['pfm-doorlock']:SetDoorState(door, locked, { reason = 'holding cell' }) end)
    return ok and type(res) == 'table' and res.ok == true
end

--- pf-justice: a custody that closes ends what this module held for that citizen and opens the cell
--- door it locked.
AddEventHandler('pf-justice:server:custodyChanged', function(custody)
    if type(custody) ~= 'table' or not custody.closedAt then return end
    local id = tonumber(custody.id)
    local door = id and LockedCells[id]
    if door then
        LockedCells[id] = nil
        F.SetDoor(door, false)
    end
    local P = type(custody.cid) == 'string' and exports['pfm-core']:GetPlayerByCitizenId(custody.cid) or nil
    if P then F.Clear(P.PlayerData.source, 'custody_closed') end
end)
