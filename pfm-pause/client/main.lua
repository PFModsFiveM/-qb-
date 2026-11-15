-- Copyright (c) 2026 Whippy, from WHIP, LGPL-3.0; modified for PF.
-- pfm-pause: PF's pause menu in place of GTA's. The page is ported (see NOTICE.md); the map's data
-- (blips, the player, the waypoint, the GPS line) is read here as the original reads it. PF's own
-- safeguards are kept around it.
--
-- Escape, P or a pad's Start open this menu, never GTA's pause screen. GTA has no switch to turn its
-- pause off, so the two pause controls (199 INPUT_FRONTEND_PAUSE: P and Start, 200
-- INPUT_FRONTEND_PAUSE_ALTERNATE: Escape) are held off every frame and read through the Disabled
-- readers. The game keeps running (it is multiplayer): only this player's input is taken, by NUI focus
-- (and DisableAllControlActions while a pad keeps input on), and the world behind is blurred.
--
-- GTA's own frontend is still used where it is the real thing: the game settings and its key bindings. While
-- one of those is up the pause keys are left alone (they close it), and when it closes the menu comes back.
--
-- THE MAP IS THE PAGE'S, THE DATA IS GTA'S. While the menu is open the player and the waypoint are sent four
-- times a second, every blip and the GPS line every 2 s ('pauseData'). A waypoint set on the map is GTA's
-- waypoint, so the radar's own GPS line follows it.
--
-- Everything is on PfmPause so the specs can run a frame at a time; the loop at the bottom drives it.

PfmPause = PfmPause or {}

local Cfg = Config.Pause

local CONTROL_PAUSE = 199        -- P, a pad's Start
local CONTROL_PAUSE_ALT = 200    -- Escape

-- frontend controls read for the pad while the menu is open
local PAD_DIRS = {
    { intent = 'up',    control = 188 },
    { intent = 'down',  control = 187 },
    { intent = 'left',  control = 189 },
    { intent = 'right', control = 190 },
}
local PAD_PRESS = {
    { intent = 'select',  control = 201 },  -- A
    { intent = 'back',    control = 202 },  -- B
    { intent = 'buttonX', control = 203 },  -- X
    { intent = 'buttonY', control = 204 },  -- Y
    { intent = 'tabPrev', control = 205 },  -- LB
    { intent = 'tabNext', control = 206 },  -- RB
}
local AXIS_X, AXIS_Y = 195, 196
local RIGHT_X, RIGHT_Y = 197, 198
local TRIGGER = { lt = { 207, 25, 72 }, rt = { 208, 24, 71 } }
local STICK_DEADZONE = 0.6
local ANALOG_DEADZONE = 0.18     -- the map's stick: a light push is a slow pan, not a press
local TRIGGER_DEADZONE = 0.08
local ANALOG_STEP = 0.02         -- positions are rounded to this, so a shaking thumb is not a stream of messages
local ANALOG_GAP_MS = 33
local OPEN_GRACE_MS = 250        -- a press still down from the one that opened the menu is ignored
local DEFAULT_DELAY, DEFAULT_RATE = 380, 110

local MENU_IDS = {
    resume = true, map = true, controller = true, swap = true, gameSettings = true, serverSettings = true,
    help = true, quit = true,
}

-- state
local isOpen = false
local openedAt = 0
local lastForeignFocus = -1e9    -- when another page last had NUI focus (or this menu closed)
local frontend = nil             -- { kind, started, seen } while GTA's own frontend is up for us
local keepInput = false
local padWas = nil
local heldSince, lastFired = {}, {}
local repeatDelay, repeatRate = DEFAULT_DELAY, DEFAULT_RATE
local pendingLeave = nil         -- { mode, token, at } between asking and confirming
local lastReport = -1e9
local loggedIn = false
local navAnalog = false          -- the page's scope wants the sticks as numbers (the map)
local sent = { x = 0, y = 0, lt = 0, rt = 0, rx = 0, ry = 0, at = 0 }
local feedGen = 0

-- ============================================================================================
-- helpers
-- ============================================================================================

local function now() return GetGameTimer() end

local function started(res)
    return GetResourceState ~= nil and GetResourceState(res) == 'started'
end

local function uiRunning() return started('pfm-ui') end

local QBCore = nil
local function core()
    if QBCore then return QBCore end
    if not started('pfm-core') then return nil end
    local ok, obj = pcall(function() return exports['pfm-core']:GetCoreObject() end)
    if ok and type(obj) == 'table' then QBCore = obj end
    return QBCore
end

local function playerData()
    local c = core()
    if c and c.Functions and c.Functions.GetPlayerData then
        local ok, pd = pcall(c.Functions.GetPlayerData)
        if ok and type(pd) == 'table' then return pd end
    end
    return c and c.PlayerData or {}
end

local function isLoggedIn()
    if loggedIn then return true end
    local lp = LocalPlayer
    if lp and lp.state and lp.state.isLoggedIn then return true end
    return false
end

local function metadata()
    local md = playerData().metadata
    return type(md) == 'table' and md or {}
end

local function isDead()
    local md = metadata()
    return md.isdead == true or md.inlaststand == true
end

local function nuiFocused()
    if IsNuiFocused == nil then return false end
    return IsNuiFocused() == true
end

--- Another resource says its page is up (one shown without focus, or one that keeps game input).
local function blockedByExport()
    for _, b in ipairs(Cfg.BlockingExports or {}) do
        if started(b.resource) then
            local ok, v = pcall(function() return exports[b.resource][b.export]() end)
            if ok and v then return b.resource end
        end
    end
    return nil
end

local function pref(key, default)
    if not uiRunning() then return default end
    local ok, v = pcall(function() return exports['pfm-ui']:GetPref(key) end)
    if ok and v ~= nil then return v end
    return default
end

--- Is the last input a gamepad right now? pfm-ui's answer when it runs (it knows the player's
--- "controller support" setting), else the native.
local function padNow()
    if uiRunning() then
        local ok, v = pcall(function() return exports['pfm-ui']:IsPadActiveNow() end)
        if ok and v ~= nil then return v == true end
    end
    if IsUsingKeyboard then return not IsUsingKeyboard(2) end
    return false
end

local function setKeepInput(on)
    if keepInput == on then return end
    keepInput = on
    SetNuiFocusKeepInput(on)
end

local function resetPad()
    heldSince, lastFired = {}, {}
end

local function str(v, max)
    if type(v) ~= 'string' then return nil end
    return v:sub(1, max or 64)
end

-- ============================================================================================
-- reading GTA's map (ported: see the header)
-- ============================================================================================

--- Sprites the page draws itself, or that are not places (Config.Pause.MapSkipSprites).
local SKIP_SPRITE = {}
for _, s in ipairs(Cfg.MapSkipSprites or { 4, 5, 6, 7, 8, 9, 10, 161, 163, 164 }) do SKIP_SPRITE[s] = true end

--- Highest sprite id asked about. GTA's go past 900; a few spare cost two natives each.
local MAX_SPRITE = 1000

--- Display modes that never draw on the big map: 0 hidden, 5 and 9 the radar only.
local NOT_ON_MAP = { [0] = true, [5] = true, [9] = true }

--- GET_BLIP_HUD_COLOUR, by name or, on a client whose Lua lacks it, by hash.
local function blipHudColour(blip)
    if GetBlipHudColour then return GetBlipHudColour(blip) end
    return Citizen.InvokeNative(0x729B5F1EFBC0AAEE, blip, Citizen.ResultAsInteger())
end

local hexCache = {}
local function hudHex(hud)
    local h = hexCache[hud]
    if h then return h end
    local r, g, b = GetHudColour(hud)
    h = ('#%02x%02x%02x'):format(r or 255, g or 255, b or 255)
    hexCache[hud] = h
    return h
end

--- The waypoint's and the GPS line's colour as the game draws them now (HUD_COLOUR_WAYPOINT). Fresh every time:
--- a HUD skin can change it while the menu is up.
local ROUTE_HUD_COLOUR = 142
local function routeColour()
    local r, g, b = GetHudColour(ROUTE_HUD_COLOUR)
    return ('#%02x%02x%02x'):format(r or 164, g or 76, b or 242)
end

local function finite(n)
    return type(n) == 'number' and n == n and n > -math.huge and n < math.huge
end

--- Every blip on the big map: { x, y, sprite, colour }. GTA gives no blip's name, so the page names them by sprite.
function PfmPause.readBlips()
    local list = {}
    for sprite = 0, MAX_SPRITE do
        if not SKIP_SPRITE[sprite] then
            local b = GetFirstBlipInfoId(sprite)
            while DoesBlipExist(b) do
                if not NOT_ON_MAP[GetBlipInfoIdDisplay(b)] and GetBlipAlpha(b) > 0 then
                    local c = GetBlipInfoIdCoord(b)
                    -- NaN or infinite: one attached to something this client cannot see right now
                    if c and finite(c.x) and finite(c.y) then
                        list[#list + 1] = {
                            x = math.floor(c.x * 10 + 0.5) / 10, y = math.floor(c.y * 10 + 0.5) / 10,
                            sprite = sprite, colour = hudHex(blipHudColour(b)),
                        }
                    end
                end
                b = GetNextBlipInfoId(sprite)
            end
        end
    end
    return list
end

--- Points along a GPS route, `step` metres apart, from the player. GTA gives one point per question
--- (GetPosAlongGpsTypeRoute) and repeats the end once the distance passes it, which is where this
--- stops. Slot 0 is the waypoint's route, 1 a blip's (SetBlipRoute).
local ROUTE_STEP, ROUTE_MAX = 30.0, 700

local function posAlongRoute(fromPlayer, dist, slot)
    if GetPosAlongGpsTypeRoute then return GetPosAlongGpsTypeRoute(fromPlayer, dist, slot) end
    if GetGpsWaypointRouteEnd then return GetGpsWaypointRouteEnd(fromPlayer, dist, slot) end
    return Citizen.InvokeNative(0xF3162836C28F9DA5, Citizen.PointerValueVector(), fromPlayer, dist, slot,
        Citizen.ReturnResultAnyway())
end

function PfmPause.readRoute(slot)
    local pts, lx, ly = {}, nil, nil
    for i = 0, ROUTE_MAX do
        local ok, p = posAlongRoute(true, i * ROUTE_STEP, slot)
        if ok == 0 then ok = false end   -- by hash, the answer is a number
        if not ok or type(p) ~= 'vector3' and type(p) ~= 'table' then break end
        if not finite(p.x) or not finite(p.y) or (p.x == 0.0 and p.y == 0.0) then break end
        if lx and math.abs(p.x - lx) < 0.5 and math.abs(p.y - ly) < 0.5 then break end
        pts[#pts + 1] = { math.floor(p.x * 10) / 10, math.floor(p.y * 10) / 10 }
        lx, ly = p.x, p.y
    end
    return #pts > 1 and pts or nil
end

--- The waypoint, or FALSE when there is none, never nil: the page keeps what it has for a key the
--- message leaves out. nil is left to mean the read failed.
function PfmPause.readWaypoint()
    local wp = GetFirstBlipInfoId(8)
    if not DoesBlipExist(wp) then return false end
    local c = GetBlipInfoIdCoord(wp)
    if not c or not finite(c.x) or not finite(c.y) then return false end
    return { x = c.x, y = c.y }
end

function PfmPause.readPlayer()
    local ped = PlayerPedId()
    local c = GetEntityCoords(ped)
    local street = GetStreetNameFromHashKey((GetStreetNameAtCoord(c.x, c.y, c.z)))
    return {
        x = c.x, y = c.y, heading = GetEntityHeading(ped),
        zone = GetLabelText(GetNameOfZone(c.x, c.y, c.z)),
        street = street,
    }
end

--- Each part read on its own: one native this client lacks must not stop the whole message. A part
--- that fails is named in F8 once and the rest still go.
local failed = {}
local function warnOnce(key, text)
    if failed[key] then return end
    failed[key] = true
    print('[pfm-pause] ' .. text)
end

local function read(part, fn, ...)
    local ok, v = pcall(fn, ...)
    if ok then return v end
    warnOnce(part, ('could not read the %s for the map: %s'):format(part, tostring(v)))
    return nil
end

--- Every number in it one JSON can carry. GTA hands back NaN and infinities, and FiveM drops the WHOLE
--- message ("invalid JSON") for one of them.
local function clean(v)
    if type(v) == 'number' then return finite(v) end
    if type(v) == 'table' then
        for _, x in pairs(v) do
            if not clean(x) then return false end
        end
    end
    return true
end

local function only(part, v)
    if v == nil or clean(v) then return v end
    warnOnce(part .. ':nan', ('the %s had a number the map cannot use (NaN or infinite) and was left out'):format(part))
    return nil
end

local function cleanList(part, list)
    if type(list) ~= 'table' then return list end
    local out = {}
    for i = 1, #list do
        if clean(list[i]) then out[#out + 1] = list[i] end
    end
    return out
end

--- One message with everything that moves; `full` adds the slow parts (blips, the route).
function PfmPause.mapData(full)
    local msg = {
        action = 'pauseData',
        player = only('player', read('player', PfmPause.readPlayer)),
        waypoint = only('waypoint', read('waypoint', PfmPause.readWaypoint)),
    }
    if full then
        msg.blips = cleanList('blips', read('blips', PfmPause.readBlips)) or {}
        local route = cleanList('route', read('route', PfmPause.readRoute, 0) or read('route', PfmPause.readRoute, 1))
        msg.route = (route and #route > 1) and route or false
        msg.routeColour = read('route colour', routeColour)
    end
    return msg
end

local function push(full)
    SendNUIMessage(PfmPause.mapData(full))
end

--- While open: the player and waypoint four times a second, blips and the route every 2 s. One feed at a
--- time: each open is a new generation, and a feed from an older one stops.
local function feed(gen)
    local n = 0
    while isOpen and gen == feedGen do
        Wait(250)
        if not isOpen or gen ~= feedGen then break end
        n = n + 1
        push(n % 8 == 0)
    end
end

-- ============================================================================================
-- what the menu shows
-- ============================================================================================

local quick = {}          -- ordered: { id, label, icon, onSelect?, command?, action?, owner? }

local function quickIndex(id)
    for i, q in ipairs(quick) do if q.id == id then return i end end
    return nil
end

for _, q in ipairs(Cfg.QuickActions or {}) do
    quick[#quick + 1] = {
        id = q.id, label = q.label, icon = q.icon, command = q.command, action = q.action, requires = q.requires,
    }
end

local function quickForPage()
    local out = {}
    for _, q in ipairs(quick) do
        local show = (q.requires == nil or started(q.requires))
        if q.action == 'keybinds' and not Cfg.KeyBindingsMenu then show = false end
        if q.action == 'report' or q.tab then show = false end   -- Help has these itself
        if show then out[#out + 1] = { id = q.id, label = q.label, icon = q.icon, action = q.action } end
    end
    return out
end

function PfmPause.reportAvailable()
    return Cfg.Report ~= nil and Cfg.Report ~= false and Cfg.Report.Enabled ~= false and started('pfm-adminmenu')
end

--- Can Swap Character be offered at all (the character screen is there)? Being dead or cuffed is asked later.
function PfmPause.swapAvailable()
    local S = Cfg.SwapCharacter
    if type(S) ~= 'table' or S.Enabled == false then return false end
    return started(S.Resource or 'pfm-multicharacter')
end

--- Why a swap cannot happen right now, or nil.
local function swapRefusal()
    local S = Cfg.SwapCharacter or {}
    if not PfmPause.swapAvailable() then return S.DisabledNote or 'Not available right now.' end
    if S.AllowWhileDead ~= true and isDead() then return 'Not while you are down.' end
    if S.AllowWhileCuffed ~= true and metadata().ishandcuffed == true then return 'Not while you are cuffed.' end
    return nil
end

--- The character over where the player is.
function PfmPause.character()
    local pd = playerData()
    local ci = type(pd.charinfo) == 'table' and pd.charinfo or {}
    local job = type(pd.job) == 'table' and pd.job or {}
    local name = ((ci.firstname or '') .. ' ' .. (ci.lastname or '')):gsub('^%s+', ''):gsub('%s+$', '')
    if name == '' then return nil end
    local jobText = job.label or job.name
    local grade = type(job.grade) == 'table' and job.grade.name or nil
    if jobText and grade and grade ~= '' then jobText = jobText .. ' · ' .. grade end
    return { name = name, job = jobText, citizenid = pd.citizenid }
end

local function helpPayload()
    return {
        rules = Cfg.Rules or {},
        keybinds = Cfg.Keybinds or {},
        quick = quickForPage(),
        report = PfmPause.reportAvailable() and {
            min = Cfg.Report.MinLength or 8, max = Cfg.Report.MaxLength or 300,
        } or false,
    }
end

--- The menu's items for the page: Config.Pause.Menu, with what cannot be offered marked off (with a note).
function PfmPause.menuItems()
    local out = {}
    for _, it in ipairs(Cfg.Menu or {}) do
        local id = type(it) == 'table' and it.id or it
        if MENU_IDS[id] then
            local item = { id = id, label = type(it) == 'table' and it.label or id }
            if id == 'swap' and not PfmPause.swapAvailable() then
                item.disabled = true
                item.note = (Cfg.SwapCharacter and Cfg.SwapCharacter.DisabledNote) or 'Not available right now.'
            elseif id == 'controller' and not uiRunning() then
                item.disabled = true
                item.note = 'The controller layout comes from pfm-ui, which is not running.'
            elseif id == 'quit' and Cfg.QuitMode == 'quit' and Cfg.AllowQuit == false then
                item = nil
            end
            if item then out[#out + 1] = item end
        end
    end
    return out
end

function PfmPause.openPayload()
    return {
        action = 'pauseOpen',
        brand = Cfg.Brand or 'PF',
        menu = PfmPause.menuItems(),
        quitMode = Cfg.QuitMode == 'quit' and 'quit' or 'disconnect',
        help = helpPayload(),
        character = PfmPause.character(),
        pad = padNow(),
    }
end

-- ============================================================================================
-- open and close
-- ============================================================================================

--- Why the menu cannot open now, or nil when it can.
function PfmPause.whyNot(t)
    t = t or now()
    if isOpen then return 'open' end
    if frontend then return 'frontend' end
    if IsPauseMenuActive and IsPauseMenuActive() then return 'gta pause' end
    if Cfg.RequireLogin ~= false and not isLoggedIn() then return 'not logged in' end
    if nuiFocused() then return 'nui focus' end
    if t - lastForeignFocus < (Cfg.FocusCooldownMs or 350) then return 'cooldown' end
    if IsScreenFadedOut and IsScreenFadedOut() then return 'faded out' end
    if Cfg.AllowWhileDead == false and isDead() then return 'dead' end
    local res = blockedByExport()
    if res then return 'page open: ' .. res end
    return nil
end

function PfmPause.canOpen(t) return PfmPause.whyNot(t) == nil end

local function clearAnalog()
    if sent.x == 0 and sent.y == 0 and sent.lt == 0 and sent.rt == 0 and sent.rx == 0 and sent.ry == 0 then return end
    sent.x, sent.y, sent.lt, sent.rt, sent.rx, sent.ry = 0, 0, 0, 0, 0, 0
    SendNUIMessage({ action = 'padAnalog', x = 0, y = 0, lt = 0, rt = 0, rx = 0, ry = 0 })
end

function PfmPause.open(force)
    if isOpen then return false end
    if not force and not PfmPause.canOpen() then return false end
    isOpen = true
    openedAt = now()
    padWas = nil
    pendingLeave = nil
    navAnalog = false
    resetPad()
    repeatDelay = tonumber(pref('pad.repeatDelay', DEFAULT_DELAY)) or DEFAULT_DELAY
    repeatRate = tonumber(pref('pad.repeatRate', DEFAULT_RATE)) or DEFAULT_RATE
    SetNuiFocus(true, true)
    keepInput = false
    SetNuiFocusKeepInput(false)
    if (Cfg.BlurMs or 0) > 0 then TriggerScreenblurFadeIn(Cfg.BlurMs + 0.0) end
    SendNUIMessage(PfmPause.openPayload())
    feedGen = feedGen + 1
    local gen = feedGen
    CreateThread(function() feed(gen) end)
    push(true)
    TriggerEvent('pfm-pause:opened')
    return true
end

--- Shut the menu and give everything back: focus, kept input, blur.
function PfmPause.close()
    if not isOpen then return false end
    isOpen = false
    pendingLeave = nil
    navAnalog = false
    resetPad()
    clearAnalog()
    if keepInput then setKeepInput(false) end
    SetNuiFocusKeepInput(false)
    SetNuiFocus(false, false)
    if (Cfg.BlurMs or 0) > 0 then TriggerScreenblurFadeOut(Cfg.BlurMs + 0.0) end
    SendNUIMessage({ action = 'pauseClose' })
    -- the key that closed it must not open it again
    lastForeignFocus = now()
    TriggerEvent('pfm-pause:closed')
    return true
end

function PfmPause.isOpen() return isOpen end

-- ============================================================================================
-- GTA's own frontend: game settings, key bindings
-- ============================================================================================

local FRONTEND = {
    settings = function() return Cfg.GameSettingsMenu or 'FE_MENU_VERSION_LANDING_MENU' end,
    keys = function() return Cfg.KeyBindingsMenu or Cfg.GameSettingsMenu or 'FE_MENU_VERSION_LANDING_MENU' end,
}

function PfmPause.openFrontend(kind)
    local menu = FRONTEND[kind] and FRONTEND[kind]()
    if not menu then return false end
    if isOpen then PfmPause.close() end
    frontend = { kind = kind, started = now(), seen = false }
    CreateThread(function()
        -- the blur fade and focus hand-back settle first
        local deadline = now() + 1000
        while IsPauseMenuActive() and now() < deadline do Wait(0) end
        Wait(100)
        ActivateFrontendMenu(GetHashKey(menu), false, -1)
    end)
    return true
end

--- One frame while GTA's frontend is ours: wait for it to come up, then to close, then come back.
local function frontendFrame(t)
    if IsPauseMenuActive() then
        frontend.seen = true
        return
    end
    if frontend.seen then
        frontend = nil
        if Cfg.ReturnAfterFrontend ~= false then
            PfmPause.open(true)
            openedAt = t   -- the B or Escape that closed GTA's menu is not ours
        else
            lastForeignFocus = t
        end
    elseif t - frontend.started > 4000 then
        frontend = nil   -- it never came up
        lastForeignFocus = t
    end
end

-- ============================================================================================
-- the pad while the menu is open
-- ============================================================================================

local function sendIntent(intent, isRepeat)
    SendNUIMessage({ action = 'pad', intent = intent, ['repeat'] = isRepeat == true })
end

local function dirDown(intent, control, sx, sy)
    if IsDisabledControlPressed(0, control) then return true end
    if intent == 'left' then return sx < -STICK_DEADZONE end
    if intent == 'right' then return sx > STICK_DEADZONE end
    if intent == 'up' then return sy < -STICK_DEADZONE end
    return sy > STICK_DEADZONE
end

local function normal(control)
    local v = GetDisabledControlNormal and GetDisabledControlNormal(0, control) or 0.0
    if type(v) ~= 'number' or v ~= v then return 0.0 end
    return v
end

--- A stick past ANALOG_DEADZONE, rescaled so its edge is 0.
local function stickPast(x, y)
    local m = math.sqrt(x * x + y * y)
    if not (m > ANALOG_DEADZONE) then return 0.0, 0.0 end
    local k = math.min(1.0, (m - ANALOG_DEADZONE) / (1.0 - ANALOG_DEADZONE)) / m
    return x * k, y * k
end

local function triggerAt(side)
    local v = 0.0
    for _, c in ipairs(TRIGGER[side]) do v = math.max(v, normal(c)) end
    if v <= TRIGGER_DEADZONE then return 0.0 end
    return math.min(1.0, (v - TRIGGER_DEADZONE) / (1.0 - TRIGGER_DEADZONE))
end

local function quantise(v) return math.floor(v / ANALOG_STEP + 0.5) * ANALOG_STEP end

--- The map's sticks and triggers, sent when they change (at most one message per ANALOG_GAP_MS while they
--- move, at once when let go). Up is positive, as the page reads it.
local function sendAnalog(t, sx, sy)
    local x, y = stickPast(sx, -sy)
    local rx, ry = stickPast(normal(RIGHT_X), -normal(RIGHT_Y))
    local a = { x = quantise(x), y = quantise(y), lt = quantise(triggerAt('lt')), rt = quantise(triggerAt('rt')),
        rx = quantise(rx), ry = quantise(ry) }
    if a.x == sent.x and a.y == sent.y and a.lt == sent.lt and a.rt == sent.rt and a.rx == sent.rx and a.ry == sent.ry then
        return
    end
    local letGo = a.x == 0 and a.y == 0 and a.lt == 0 and a.rt == 0 and a.rx == 0 and a.ry == 0
    if not letGo and t - sent.at < ANALOG_GAP_MS then return end
    sent.x, sent.y, sent.lt, sent.rt, sent.rx, sent.ry, sent.at = a.x, a.y, a.lt, a.rt, a.rx, a.ry, t
    SendNUIMessage({ action = 'padAnalog', x = a.x, y = a.y, lt = a.lt, rt = a.rt, rx = a.rx, ry = a.ry })
end

local function menuFrame(t)
    if Cfg.HideHud ~= false and HideHudAndRadarThisFrame then HideHudAndRadarThisFrame() end

    -- something else put GTA's pause up over ours
    if IsPauseMenuActive() then PfmPause.close() return end

    local pad = padNow()
    if pad ~= padWas then
        padWas = pad
        SendNUIMessage({ action = 'device', pad = pad })
        if not pad then resetPad() clearAnalog() end
    end
    -- a pad's buttons only reach the game with input kept; the player's own controls stay held off
    setKeepInput(pad)
    if keepInput then DisableAllControlActions(0) end
    if not pad then return end
    if t - openedAt < OPEN_GRACE_MS then return end

    if IsDisabledControlJustPressed(0, CONTROL_PAUSE) then PfmPause.close() return end

    local sx, sy = normal(AXIS_X), normal(AXIS_Y)
    if navAnalog then
        -- the map takes the sticks as numbers: the stick is no direction for it (the D-pad still is)
        sendAnalog(t, sx, sy)
        sx, sy = 0.0, 0.0
    else
        clearAnalog()
    end
    for _, d in ipairs(PAD_DIRS) do
        if dirDown(d.intent, d.control, sx, sy) then
            local since = heldSince[d.intent]
            if not since then
                heldSince[d.intent], lastFired[d.intent] = t, t
                sendIntent(d.intent, false)
            elseif t - since >= repeatDelay and t - lastFired[d.intent] >= repeatRate then
                lastFired[d.intent] = t
                sendIntent(d.intent, true)
            end
        else
            heldSince[d.intent], lastFired[d.intent] = nil, nil
        end
    end
    for _, b in ipairs(PAD_PRESS) do
        if IsDisabledControlJustPressed(0, b.control) then sendIntent(b.intent, false) end
    end
end

-- ============================================================================================
-- every frame
-- ============================================================================================

function PfmPause.frame()
    local t = now()
    if frontend then return frontendFrame(t) end
    -- GTA's frontend up from somewhere else: its keys are its own
    if not isOpen and IsPauseMenuActive() then return end
    if Cfg.RequireLogin ~= false and not isLoggedIn() and not isOpen then return end

    DisableControlAction(0, CONTROL_PAUSE, true)
    DisableControlAction(0, CONTROL_PAUSE_ALT, true)

    if isOpen then return menuFrame(t) end

    if nuiFocused() then
        lastForeignFocus = t
        return
    end
    local esc = Cfg.OpenOnEscape ~= false and IsDisabledControlJustPressed(0, CONTROL_PAUSE_ALT)
    local p = Cfg.OpenOnP ~= false and IsDisabledControlJustPressed(0, CONTROL_PAUSE)
    if esc or p then PfmPause.open() end
end

CreateThread(function()
    while true do
        PfmPause.frame()
        Wait(0)
    end
end)

-- ============================================================================================
-- the page's buttons
-- ============================================================================================

RegisterNUICallback('pauseResume', function(_, cb)
    cb({ ok = true })
    PfmPause.close()
end)
-- the old name, for anything still posting it
RegisterNUICallback('close', function(_, cb)
    cb({ ok = true })
    PfmPause.close()
end)

--- GTA's own settings menu in the pause menu's place (Game Settings).
RegisterNUICallback('pauseSettings', function(_, cb)
    cb({ ok = true })
    PfmPause.openFrontend('settings')
end)

--- GTA's own key bindings screen.
RegisterNUICallback('pauseKeyBindings', function(_, cb)
    cb({ ok = true })
    PfmPause.openFrontend('keys')
end)

--- The page's scope wants the sticks as numbers (the map) or not.
RegisterNUICallback('navScope', function(data, cb)
    navAnalog = isOpen and type(data) == 'table' and data.analog == true
    if not navAnalog then clearAnalog() end
    cb({ ok = true })
end)

--- A waypoint set on the map (double-click, or A on a pad), or cleared ({ clear = true }). GTA's own
--- waypoint, so the radar's GPS line follows it.
local MAP_LIMIT = 10000.0
function PfmPause.setWaypoint(data)
    if type(data) ~= 'table' then return false end
    if data.clear then
        SetWaypointOff()
    elseif finite(data.x) and finite(data.y) and math.abs(data.x) < MAP_LIMIT and math.abs(data.y) < MAP_LIMIT then
        SetNewWaypoint(data.x + 0.0, data.y + 0.0)
    else
        return false
    end
    -- The route takes GTA a moment to plan; ask twice.
    SetTimeout(250, function() if isOpen then push(true) end end)
    SetTimeout(1200, function() if isOpen then push(true) end end)
    return true
end

RegisterNUICallback('pauseWaypoint', function(data, cb)
    cb({ ok = PfmPause.setWaypoint(data) })
end)

RegisterNUICallback('quick', function(data, cb)
    local id = type(data) == 'table' and str(data.id, 48)
    local i = id and quickIndex(id)
    local q = i and quick[i]
    if not q then cb({ ok = false }) return end
    cb({ ok = true })
    if q.action == 'keybinds' then PfmPause.openFrontend('keys') return end
    PfmPause.close()
    if q.onSelect then
        local ok, err = pcall(q.onSelect, q.id)
        if not ok then print(('[pfm-pause] quick action %s failed: %s'):format(q.id, tostring(err))) end
    elseif q.command then
        ExecuteCommand(q.command)
    end
end)

-- ---- Server Settings (pfm-ui's per-player registry), in the shape the Settings page reads ----

--- { groups = { { id, label, rows = { { key, label, help, type, value, default, min, max, step, options,
--- locked, changed } } } } }, grouped by each setting's group, in the order the groups first appear.
function PfmPause.prefsState(errorText)
    if not uiRunning() then
        return { groups = { { id = 'Server', label = 'Server', rows = {
            { key = '_none', label = Cfg.NoPrefsNote or 'Nothing to change here.', type = 'info', value = '', locked = true },
        } } } }
    end
    local ok, prefs = pcall(function() return exports['pfm-ui']:GetPrefs() end)
    if not ok or type(prefs) ~= 'table' then return { groups = {}, error = 'settings are not available' } end
    local groups, byId = {}, {}
    for _, p in ipairs(prefs) do
        if type(p) == 'table' and type(p.key) == 'string' then
            local gid = type(p.group) == 'string' and p.group ~= '' and p.group or 'General'
            local g = byId[gid]
            if not g then
                g = { id = gid, label = gid, rows = {} }
                byId[gid] = g
                groups[#groups + 1] = g
            end
            g.rows[#g.rows + 1] = {
                key = p.key, label = p.label or p.key, help = p.help, type = p.type,
                value = p.value, default = p.default, min = p.min, max = p.max, step = p.step, unit = p.unit,
                options = p.options, locked = p.forced == true, changed = p.value ~= p.default and p.forced ~= true,
            }
        end
    end
    return { groups = groups, error = errorText }
end

--- The older payload (kept for the specs and anything reading it): available, prefs, layout.
function PfmPause.settingsPayload()
    if not uiRunning() then return { available = false, note = Cfg.NoPrefsNote } end
    local okP, prefs = pcall(function() return exports['pfm-ui']:GetPrefs() end)
    local okL, layout = pcall(function() return exports['pfm-ui']:GetLayout() end)
    if not okP or type(prefs) ~= 'table' then return { available = false, note = Cfg.NoPrefsNote } end
    return { available = true, prefs = prefs, layout = okL and type(layout) == 'table' and layout or nil }
end

RegisterNUICallback('prefsState', function(_, cb)
    cb(PfmPause.prefsState())
end)
RegisterNUICallback('getPrefs', function(_, cb)
    cb(PfmPause.settingsPayload())
end)

--- One setting changed. Set to its default, the player's own choice is cleared instead (ResetPref).
local function setPref(key, value)
    if not uiRunning() then return false, 'settings are not available' end
    if type(key) ~= 'string' or #key > 64 then return false, 'no such setting' end
    local def
    local okL, list = pcall(function() return exports['pfm-ui']:GetPrefs() end)
    if okL and type(list) == 'table' then
        for _, p in ipairs(list) do if p.key == key then def = p.default break end end
    end
    local ok, res, why
    if def ~= nil and value == def then
        ok, res = pcall(function() return exports['pfm-ui']:ResetPref(key) end)
        if ok and res ~= true then
            -- not changed before: setting it to the default is still right
            ok, res, why = pcall(function() return exports['pfm-ui']:SetPref(key, value) end)
        end
    else
        ok, res, why = pcall(function() return exports['pfm-ui']:SetPref(key, value) end)
    end
    if not ok then return false, 'failed' end
    return res == true, why
end

RegisterNUICallback('prefsSet', function(data, cb)
    local okSet, why = setPref(type(data) == 'table' and data.key, type(data) == 'table' and data.value)
    cb(PfmPause.prefsState(not okSet and (why or 'not changed') or nil))
end)

RegisterNUICallback('setPref', function(data, cb)
    if not uiRunning() or type(data) ~= 'table' or type(data.key) ~= 'string' then
        cb({ ok = false, why = 'settings are not available' }) return
    end
    local ok, res, why = pcall(function() return exports['pfm-ui']:SetPref(data.key, data.value) end)
    local value = pref(data.key, nil)
    if not ok then cb({ ok = false, why = 'failed', value = value }) return end
    cb({ ok = res == true, why = why, value = value })
end)

--- A tab of settings back to the server's defaults.
RegisterNUICallback('prefsReset', function(data, cb)
    local group = type(data) == 'table' and str(data.group, 64)
    if uiRunning() and group then
        local okL, list = pcall(function() return exports['pfm-ui']:GetPrefs() end)
        for _, p in ipairs(okL and type(list) == 'table' and list or {}) do
            local gid = type(p.group) == 'string' and p.group ~= '' and p.group or 'General'
            if gid == group and not p.forced then pcall(function() exports['pfm-ui']:ResetPref(p.key) end) end
        end
    end
    cb(PfmPause.prefsState())
end)

AddEventHandler('pfm-ui:prefChanged', function(key, value)
    if isOpen then
        SendNUIMessage({ action = 'playerPrefs', values = { [key] = value } })
    end
end)

-- ---- the Controller screen (pfm-ui's button layout) ----

--- { actions = { { id, label, on } }, layout = { [slot] = action }, custom, swap?, error? }
function PfmPause.padState(extra)
    if not uiRunning() then return { actions = {}, layout = {}, custom = false, error = 'pfm-ui is not running' } end
    local st
    local ok, res = pcall(function() return exports['pfm-ui']:GetLayoutState() end)
    if ok and type(res) == 'table' then
        st = res
    else
        local okL, layout = pcall(function() return exports['pfm-ui']:GetLayout() end)
        st = { layout = okL and type(layout) == 'table' and layout or {}, actions = {}, custom = false }
    end
    local layout = {}
    for slot, a in pairs(st.layout or {}) do if type(a) == 'string' then layout[slot] = a end end
    local actions = {}
    for _, a in ipairs(st.actions or {}) do
        if type(a) == 'table' and type(a.id) == 'string' then
            actions[#actions + 1] = { id = a.id, label = a.label or a.id, on = true }
        end
    end
    local out = { actions = actions, layout = layout, custom = st.custom == true }
    if type(extra) == 'table' then for k, v in pairs(extra) do out[k] = v end end
    return out
end

RegisterNUICallback('padLayout', function(_, cb)
    cb(PfmPause.padState())
end)

RegisterNUICallback('padLayoutSet', function(data, cb)
    if not uiRunning() or type(data) ~= 'table' or type(data.slot) ~= 'string' then
        cb(PfmPause.padState({ error = 'not changed' })) return
    end
    local action = type(data.action) == 'string' and data.action ~= '' and data.action:sub(1, 32) or false
    local before = PfmPause.padState().layout
    local ok, res, why = pcall(function() return exports['pfm-ui']:SetLayoutSlot(data.slot:sub(1, 32), action) end)
    if not ok or res ~= true then
        cb(PfmPause.padState({ error = (ok and why) or 'not changed' })) return
    end
    local st = PfmPause.padState()
    -- the action left the button it was on, which took this button's old action: said as the swap
    if action then
        for slot, a in pairs(before) do
            if a == action and slot ~= data.slot then
                st.swap = { slot = slot, gave = st.layout[slot] }
                break
            end
        end
    end
    cb(st)
end)

RegisterNUICallback('padLayoutReset', function(_, cb)
    if uiRunning() then pcall(function() exports['pfm-ui']:ResetLayout() end) end
    cb(PfmPause.padState())
end)

RegisterNUICallback('resetLayout', function(_, cb)
    if not uiRunning() then cb({ ok = false }) return end
    pcall(function() exports['pfm-ui']:ResetLayout() end)
    cb(PfmPause.settingsPayload())
end)

-- ---- report a problem: pfm-adminmenu's /report (staff only see it, and it is logged) ----

--- The message made safe for a console command line: one line, no command separators or quotes.
function PfmPause.cleanReport(msg)
    if type(msg) ~= 'string' then return nil end
    msg = msg:gsub('[%c]', ' '):gsub('[;"\\]', ' '):gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    return msg
end

RegisterNUICallback('report', function(data, cb)
    local R = Cfg.Report or {}
    if not PfmPause.reportAvailable() then cb({ ok = false, why = 'Reports are not available right now.' }) return end
    local msg = PfmPause.cleanReport(type(data) == 'table' and data.message)
    local min, max = R.MinLength or 8, R.MaxLength or 300
    if not msg or #msg < min then cb({ ok = false, why = ('Please write at least %d characters.'):format(min) }) return end
    if #msg > max then msg = msg:sub(1, max) end
    local t = now()
    local wait = (R.CooldownSec or 60) * 1000 - (t - lastReport)
    if wait > 0 then
        cb({ ok = false, why = ('Please wait %d s before sending another report.'):format(math.ceil(wait / 1000)) })
        return
    end
    lastReport = t
    ExecuteCommand((R.Command or 'report') .. ' ' .. msg)
    cb({ ok = true })
end)

-- ---- leaving and swapping: asked first, then confirmed with the token the question carried ----

local function newToken()
    return ('%d-%d'):format(now(), math.random(100000, 999999))
end

RegisterNUICallback('leave', function(data, cb)
    local mode = type(data) == 'table' and data.mode
    if mode ~= 'disconnect' and mode ~= 'quit' and mode ~= 'swap' then cb({ ok = false }) return end
    if mode == 'quit' and Cfg.AllowQuit == false then cb({ ok = false, why = 'Quitting from here is turned off.' }) return end
    if mode == 'swap' then
        local why = swapRefusal()
        if why then pendingLeave = nil cb({ ok = false, why = why }) return end
    end
    pendingLeave = { mode = mode, token = newToken(), at = now() }
    SendNUIMessage({ action = 'confirm', mode = mode, token = pendingLeave.token })
    cb({ ok = true, token = pendingLeave.token })
end)

RegisterNUICallback('leaveCancel', function(_, cb)
    pendingLeave = nil
    cb({ ok = true })
end)

RegisterNUICallback('leaveConfirm', function(data, cb)
    local p = pendingLeave
    local token = type(data) == 'table' and data.token
    if not p or token ~= p.token or now() - p.at > 60000 then
        pendingLeave = nil
        cb({ ok = false })
        return
    end
    pendingLeave = nil
    if p.mode == 'swap' then
        local why = swapRefusal()   -- asked again: things may have changed while the question was up
        if why then cb({ ok = false, why = why }) return end
        cb({ ok = true })
        PfmPause.close()
        TriggerServerEvent('pfm-pause:server:swap')
        return
    end
    cb({ ok = true })
    if p.mode == 'quit' then
        PfmPause.close()
        ExecuteCommand('quit')
    else
        TriggerServerEvent('pfm-pause:server:leave')
    end
end)

-- ============================================================================================
-- events and exports
-- ============================================================================================

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function() loggedIn = true end)
RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
    loggedIn = false
    PfmPause.close()
end)
AddEventHandler('QBCore:Player:SetPlayerData', function()
    if isOpen then SendNUIMessage({ action = 'pauseCharacter', character = PfmPause.character() }) end
end)

--- The server refused a swap (cooldown, dead, cuffed): said in chat.
RegisterNetEvent('pfm-pause:client:swapRefused', function(why)
    if type(why) ~= 'string' then return end
    TriggerEvent('chat:addMessage', { args = { 'Pause menu', why:sub(1, 120) } })
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then
        if isOpen then
            SetNuiFocusKeepInput(false)
            SetNuiFocus(false, false)
            TriggerScreenblurFadeOut(0.0)
        end
        return
    end
    -- shortcuts a stopped resource added go with it
    local changed = false
    for i = #quick, 1, -1 do
        if quick[i].owner == res then table.remove(quick, i) changed = true end
    end
    if changed and isOpen then SendNUIMessage({ action = 'pauseHelp', help = helpPayload() }) end
end)

--- Add (or replace) a shortcut on the Help page.
---   exports['pfm-pause']:AddQuickAction({ id = 'garage', label = 'My garage', onSelect = function() end })
--- onSelect runs after the menu closes. `command = 'name'` runs a command instead. order: lower comes first.
function PfmPause.addQuickAction(def, owner)
    if type(def) ~= 'table' then return false, 'needs a table' end
    if type(def.id) ~= 'string' or not def.id:match('^[%w_%-%.]+$') or #def.id > 48 then
        return false, 'id must be letters, digits, dots, dashes or underscores (1-48)'
    end
    if type(def.label) ~= 'string' or def.label == '' then return false, 'label is required' end
    if def.onSelect == nil and type(def.command) ~= 'string' then return false, 'give it onSelect or command' end
    if def.command ~= nil and (type(def.command) ~= 'string' or not def.command:match('^[%w_%+%-%.%:][%w%s_%+%-%.%:]*$')) then
        return false, 'command must be a plain command line'
    end
    local q = {
        id = def.id, label = def.label:sub(1, 40), icon = type(def.icon) == 'string' and def.icon:sub(1, 24) or nil,
        onSelect = def.onSelect, command = def.command, owner = owner, order = tonumber(def.order),
    }
    local i = quickIndex(def.id)
    if i then quick[i] = q
    elseif q.order then
        local at = #quick + 1
        for j, other in ipairs(quick) do
            if (other.order or math.huge) > q.order then at = j break end
        end
        table.insert(quick, at, q)
    else
        quick[#quick + 1] = q
    end
    return true
end

function PfmPause.removeQuickAction(id)
    local i = quickIndex(id)
    if not i then return false end
    table.remove(quick, i)
    return true
end

function PfmPause.quickActions() return quickForPage() end

exports('IsOpen', function() return isOpen end)
exports('Open', function() return PfmPause.open() end)
exports('Close', function() return PfmPause.close() end)
exports('AddQuickAction', function(def)
    return PfmPause.addQuickAction(def, GetInvokingResource and GetInvokingResource() or nil)
end)
exports('RemoveQuickAction', function(id) return PfmPause.removeQuickAction(id) end)
