-- pfm-prompts: the registry. Prompts on a point, an entity, a network id, every object of a model,
-- or a pfm-doorlock door; which ones are in sight and in reach; which one is focused; the keys.
--
-- Copyright (c) 2026 Whippy, from WHIP, LGPL-3.0; modified for PF.
-- (The parts of WHIP whip_core/client/interact.lua that prompts need: the 25 m spatial grid, the
-- per-resource cleanup, focus by aim then reach, option cycling on controls 16/17, hold to use and
-- the pass loop's score / draw split. WHIP's action system, typing, previews, follow callbacks and
-- the NUI renderer are not ported.)
--
-- Scoring (score()) runs about every Config.ScoreMs while anything is near and builds `visible`, the
-- prompts to draw, each with its state (idle / active / focused / info). Drawing runs every frame from
-- `visible` and allocates nothing. Keys are read every frame for the focused prompt only.

PfmPrompts = {}
local M = PfmPrompts

-- The renderers sign in here (client/render_world.lua, client/render_screen.lua).
PromptRenderers = {}

local sqrt, cos, rad, floor = math.sqrt, math.cos, math.rad, math.floor

local CELL_SIZE = 25.0           -- spatial grid cell, metres
local MODEL_SCAN_MS = 1000       -- how often the object pool is searched for model prompts
local DOOR_RETRY_MS = 5000       -- how often an unresolved door prompt asks pfm-doorlock again
local SCROLL_BLOCK = { 14, 15, 16, 17 }  -- the weapon wheel, held off while a prompt's options cycle

local registry = {}   -- [key] = prompt (key = owner .. ':' .. id)
local grid = {}       -- [cellKey] = { [key] = true }  (coords and resolved door prompts)
local dynamic = {}    -- [key] = true  (entity, netId and model prompts: their position moves)
local pendingDoors = {} -- [key] = true (door prompts pfm-doorlock has not placed yet)

local visible = {}    -- [vkey] = entry: what the renderer draws (vkey = key, or key .. '#' .. entity)
local visibleN = 0
local spare = {}      -- entries that left `visible`, kept for reuse
local focusVKey = nil -- the focused entry's vkey
local hold = nil      -- { vkey, opt, start, ms } while a hold-to-use runs

local nearbyCells, nearbyAt, nearbyRange = {}, nil, nil
local lastModelScan = -MODEL_SCAN_MS
local lastDoorRetry = -DOOR_RETRY_MS
local nextScoreAt = 0

M.renderer = nil      -- set by client/main.lua: { frame, clear, name }

-- ---------------------------------------------------------------------------------------------
-- Helpers

local function ownerOfCall()
    local inv = GetInvokingResource()
    if inv == nil or inv == '' then return GetCurrentResourceName() end
    return inv
end

local function keyOf(owner, id) return owner .. ':' .. tostring(id) end

local function str(v)
    if type(v) == 'string' then return v end
    if type(v) == 'number' then return tostring(v) end
    return nil
end

local function num(v, fallback)
    v = tonumber(v)
    if v == nil then return fallback end
    return v
end

--- A callback from another resource arrives as a funcref (a table): it is called, never type-tested
--- as a function. pcall'd: a throwing callback counts as "no" and is reported once.
local reported = {}
local function ask(P, field, fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return true, res end
    local rk = P.key .. '\1' .. field
    if not reported[rk] then
        reported[rk] = true
        print(('[pfm-prompts] %s of prompt "%s" (%s) failed: %s'):format(field, tostring(P.id), P.owner, tostring(res)))
    end
    return false, nil
end

local function cellKeyOf(x, y)
    return floor(x / CELL_SIZE) .. '_' .. floor(y / CELL_SIZE)
end

local function gridInsert(P)
    local k = cellKeyOf(P.x, P.y)
    P._cell = k
    local bucket = grid[k]
    if not bucket then bucket = {}; grid[k] = bucket end
    bucket[P.key] = true
    nearbyAt = nil
end

local function gridRemove(P)
    local bucket = P._cell and grid[P._cell]
    if bucket then
        bucket[P.key] = nil
        if not next(bucket) then grid[P._cell] = nil end
    end
    P._cell = nil
end

-- ---------------------------------------------------------------------------------------------
-- Definitions

--- One option from a definition (or one entry of def.options), with the definition's own fields as
--- the defaults.
local function makeOption(src, base, index)
    base = base or {}
    local o = {
        index = index,
        label = str(src.label) or base.label,
        sublabel = str(src.sublabel) or base.sublabel,
        key = str(src.key) or base.key or 'E',
        control = num(src.control, base.control or 38),
        holdMs = num(src.holdMs, base.holdMs),
        icon = str(src.icon) or base.icon,
        image = str(src.image) or base.image,
        args = src.args or base.args,
        clientEvent = str(src.clientEvent) or base.clientEvent,
    }
    if src.canInteract ~= nil then o.canInteract = src.canInteract else o.canInteract = base.canInteract end
    if src.onPress ~= nil then o.onPress = src.onPress else o.onPress = base.onPress end
    if src.label == false then o.label = nil end
    if src.sublabel == false then o.sublabel = nil end
    if o.holdMs and o.holdMs <= 0 then o.holdMs = nil end
    return o
end

--- An option the key can act on: it has something to do.
local function hasAction(o)
    return o.onPress ~= nil or o.clientEvent ~= nil
end

local function vec(v)
    if v == nil then return nil end
    local ok, x, y, z = pcall(function() return v.x, v.y, v.z end)
    if ok and tonumber(x) and tonumber(y) and tonumber(z) then return x + 0.0, y + 0.0, z + 0.0 end
    if type(v) == 'table' and tonumber(v[1]) and tonumber(v[2]) and tonumber(v[3]) then
        return v[1] + 0.0, v[2] + 0.0, v[3] + 0.0
    end
    return nil
end

--- Where a pfm-doorlock door is: its text coords, else its object coords, else between its two
--- doors. `door` is the door's id in pfm-doorlock's list, or its door-system hash.
local function doorPosition(door)
    if GetResourceState('pfm-doorlock') ~= 'started' then return nil end
    local ok, list = pcall(function() return exports['pfm-doorlock']:GetDoorList() end)
    if not ok or type(list) ~= 'table' then return nil end
    local d = list[door]
    if not d then
        for id, dd in pairs(list) do
            if type(dd) == 'table' and (dd.doorHash == door
                or (type(door) == 'number' and (GetHashKey('door_' .. tostring(id)) == door
                    or (type(dd.doorHash) == 'string' and GetHashKey(dd.doorHash) == door)))) then
                d = dd
                break
            end
        end
    end
    if type(d) ~= 'table' then return nil end
    local x, y, z = vec(d.textCoords)
    if x then return x, y, z end
    x, y, z = vec(d.objCoords)
    if x then return x, y, z end
    if type(d.doors) == 'table' and d.doors[1] then
        local ax, ay, az = vec(d.doors[1].objCoords)
        local bx, by, bz = d.doors[2] and vec(d.doors[2].objCoords)
        if ax and bx then return (ax + bx) * 0.5, (ay + by) * 0.5, (az + bz) * 0.5 end
        if ax then return ax, ay, az end
    end
    return nil
end

local function place(P)
    gridRemove(P)
    dynamic[P.key] = nil
    pendingDoors[P.key] = nil
    if P.kind == 'coords' then
        gridInsert(P)
    elseif P.kind == 'door' then
        local x, y, z = doorPosition(P.door)
        if x then
            P.x, P.y, P.z = x + P.ox, y + P.oy, z + P.oz
            gridInsert(P)
        else
            pendingDoors[P.key] = true
        end
    else
        dynamic[P.key] = true
    end
end

--- Build a prompt from its definition. Returns nil and a reason for a definition that cannot work.
local function build(key, id, owner, def)
    if type(def) ~= 'table' then return nil, 'definition must be a table' end
    local P = { key = key, id = id, owner = owner, def = def, sel = 1 }

    local ox, oy, oz = vec(def.offset)
    P.ox, P.oy, P.oz = ox or 0.0, oy or 0.0, oz or 0.0
    P.hasOffset = ox ~= nil

    local cx, cy, cz = vec(def.coords)
    if cx then
        P.kind = 'coords'
        P.x, P.y, P.z = cx + P.ox, cy + P.oy, cz + P.oz
    elseif tonumber(def.entity) then
        P.kind = 'entity'; P.entity = tonumber(def.entity)
    elseif tonumber(def.netId) then
        P.kind = 'net'; P.netId = tonumber(def.netId)
    elseif def.model ~= nil then
        P.kind = 'model'
        P.model = type(def.model) == 'string' and GetHashKey(def.model) or tonumber(def.model)
        if not P.model then return nil, 'model must be a hash or a name' end
        P.instances = {}
    elseif def.door ~= nil then
        P.kind = 'door'; P.door = def.door
    else
        return nil, 'a prompt needs coords, entity, netId, model or door'
    end

    local maxShow = Config.MaxShowDistance or 25.0
    P.distance = num(def.distance, Config.Distance or 2.0)
    P.showDistance = math.min(num(def.showDistance, Config.ShowDistance or 6.0), maxShow)
    if P.showDistance < P.distance then P.showDistance = P.distance end
    P.scale = num(def.scale, 1.0)

    local base = makeOption(def, nil, 1)
    if type(def.options) == 'table' and #def.options > 0 then
        P.options = {}
        for i = 1, #def.options do
            if type(def.options[i]) == 'table' then P.options[#P.options + 1] = makeOption(def.options[i], base, #P.options + 1) end
        end
        if #P.options == 0 then P.options = { base } end
    else
        P.options = { base }
    end
    -- Reused per score frame: which options are offered now (indexes into P.options).
    P.avail, P.availN = {}, 0
    return P
end

-- ---------------------------------------------------------------------------------------------
-- The API (exports in client/main.lua)

---@return boolean ok, string|nil why
function M.add(id, def, owner)
    if id == nil then return false, 'id required' end
    owner = owner or ownerOfCall()
    local key = keyOf(owner, id)
    local P, why = build(key, id, owner, def)
    if not P then
        print(('[pfm-prompts] prompt "%s" from %s refused: %s'):format(tostring(id), owner, why))
        return false, why
    end
    if registry[key] then M.remove(id, owner) end
    registry[key] = P
    place(P)
    return true
end

---@return boolean ok
function M.update(id, patch, owner)
    owner = owner or ownerOfCall()
    local key = keyOf(owner, id)
    local old = registry[key]
    if not old or type(patch) ~= 'table' then return false end
    local def = {}
    for k, v in pairs(old.def) do def[k] = v end
    -- A patch that places the prompt somewhere new replaces the old anchor.
    if patch.coords ~= nil or patch.entity ~= nil or patch.netId ~= nil or patch.model ~= nil or patch.door ~= nil then
        def.coords, def.entity, def.netId, def.model, def.door = nil, nil, nil, nil, nil
    end
    for k, v in pairs(patch) do def[k] = v end
    local P, why = build(key, id, owner, def)
    if not P then return false, why end
    P.sel = old.sel
    P.flashAt, P.flashR, P.flashG, P.flashB = old.flashAt, old.flashR, old.flashG, old.flashB
    gridRemove(old)
    dynamic[key], pendingDoors[key] = nil, nil
    registry[key] = P
    place(P)
    return true
end

local function dropVisibleOf(key)
    for vkey, e in pairs(visible) do
        if e.key == key then
            visible[vkey] = nil
            visibleN = visibleN - 1
            spare[#spare + 1] = e
            if focusVKey == vkey then focusVKey = nil end
            if hold and hold.vkey == vkey then hold = nil end
        end
    end
end

---@return boolean removed
function M.remove(id, owner)
    owner = owner or ownerOfCall()
    local key = keyOf(owner, id)
    local P = registry[key]
    if not P then return false end
    gridRemove(P)
    dynamic[key], pendingDoors[key] = nil, nil
    registry[key] = nil
    dropVisibleOf(key)
    for rk in pairs(reported) do
        if rk:sub(1, #key + 1) == key .. '\1' then reported[rk] = nil end
    end
    return true
end

---@return number removed
function M.removeAllFor(resource)
    if type(resource) ~= 'string' then return 0 end
    local n = 0
    for key, P in pairs(registry) do
        if P.owner == resource then
            M.remove(P.id, resource)
            n = n + 1
        end
    end
    return n
end

function M.exists(id, owner)
    return registry[keyOf(owner or ownerOfCall(), id)] ~= nil
end

--- Flash the badge in a colour (an answer: green for done, red for refused).
function M.flash(id, r, g, b, owner)
    local P = registry[keyOf(owner or ownerOfCall(), id)]
    if not P then return false end
    P.flashAt, P.flashR, P.flashG, P.flashB = GetGameTimer(), num(r, 255), num(g, 255), num(b, 255)
    return true
end

--- The focused prompt's id and its owner, or nil.
function M.getFocused()
    local e = focusVKey and visible[focusVKey]
    if not e then return nil end
    local P = registry[e.key]
    return P and P.id, P and P.owner
end

--- Everything a spec or a debug command may want to look at.
function M._state()
    return { registry = registry, grid = grid, visible = visible, focus = focusVKey, hold = hold,
             dynamic = dynamic, pendingDoors = pendingDoors }
end

-- ---------------------------------------------------------------------------------------------
-- Scoring

local function rebuildNearby(px, py, range)
    for i = #nearbyCells, 1, -1 do nearbyCells[i] = nil end
    local r = math.ceil(range / CELL_SIZE)
    local cx, cy = floor(px / CELL_SIZE), floor(py / CELL_SIZE)
    for dx = -r, r do
        for dy = -r, r do nearbyCells[#nearbyCells + 1] = (cx + dx) .. '_' .. (cy + dy) end
    end
end

local function scanModels(px, py, pz, now)
    lastModelScan = now
    local any = false
    for key in pairs(dynamic) do
        local P = registry[key]
        if P and P.kind == 'model' then any = true; P._n = 0 end
    end
    if not any then return end
    local pool = GetGamePool('CObject') or {}
    for i = 1, #pool do
        local ent = pool[i]
        local model = GetEntityModel(ent)
        for key in pairs(dynamic) do
            local P = registry[key]
            if P and P.kind == 'model' and P.model == model then
                local c = GetEntityCoords(ent)
                local dx, dy, dz = c.x - px, c.y - py, c.z - pz
                local reach = P.showDistance + 5.0
                if dx * dx + dy * dy + dz * dz <= reach * reach then
                    P._n = P._n + 1
                    P.instances[P._n] = ent
                end
            end
        end
    end
    for key in pairs(dynamic) do
        local P = registry[key]
        if P and P.kind == 'model' then
            for i = #P.instances, P._n + 1, -1 do P.instances[i] = nil end
        end
    end
end

local function entityPos(P, ent)
    if not ent or ent == 0 or not DoesEntityExist(ent) then return nil end
    local c
    if P.hasOffset then
        c = GetOffsetFromEntityInWorldCoords(ent, P.ox, P.oy, P.oz)
    else
        c = GetEntityCoords(ent)
    end
    return c.x, c.y, c.z
end

-- Scratch for a score frame.
local seen = {}          -- [vkey] = true: entries still visible this score frame
local order = {}         -- drawn entries, nearest first, when more than MaxDrawn are near
local function nearerFirst(a, b) return a.dist < b.dist end

local S = {}             -- the score frame's shared reads (player, camera, cones, pad)

local function evalOptions(P, ent)
    local n = 0
    local opts = P.options
    for i = 1, #opts do
        local o = opts[i]
        local ok = hasAction(o)
        if ok and o.canInteract ~= nil then
            local fine, res = ask(P, 'canInteract', o.canInteract, P.id, o.index, ent)
            ok = fine and res and true or false
        end
        if ok then n = n + 1; P.avail[n] = i end
    end
    for i = #P.avail, n + 1, -1 do P.avail[i] = nil end
    P.availN = n
    if P.sel > n then P.sel = n end
    if P.sel < 1 then P.sel = 1 end
    return n
end

--- One prompt (or one instance of a model prompt) at x, y, z: into `visible` if it is to be drawn.
local function consider(P, vkey, x, y, z, ent)
    local dx, dy, dz = x - S.px, y - S.py, z - S.pz
    local dist = sqrt(dx * dx + dy * dy + dz * dz)
    if dist > P.showDistance then return end

    -- Behind the camera: not drawn, not focusable.
    local ax, ay, az = x - S.camX, y - S.camY, z - S.camZ
    local alen = sqrt(ax * ax + ay * ay + az * az)
    local aim = 1.0
    if alen > 0.001 then aim = (S.cfx * ax + S.cfy * ay + S.cfz * az) / alen end
    if aim < -0.2 then return end

    local n = evalOptions(P, ent)
    local actionable = n > 0
    local o = actionable and P.options[P.avail[P.sel]] or P.options[1]
    -- Nothing to press and nothing to say: hidden (canInteract hides the action; a prompt with a
    -- sublabel still says it, e.g. "Locked").
    if not actionable and not o.sublabel then return end

    local e = visible[vkey]
    if not e then
        e = table.remove(spare) or {}
        for k in pairs(e) do e[k] = nil end
        e.optGlyphs, e.optLabels, e.optSubs = {}, {}, {}
        visible[vkey] = e
        visibleN = visibleN + 1
    end
    seen[vkey] = true
    e.vkey, e.key, e.entity = vkey, P.key, ent
    e.x, e.y, e.z = x, y, z
    e.dist = dist
    e.aim = aim
    e.active = dist <= P.distance
    e.actionable = actionable
    e.availN = actionable and n or 1
    e.sel = actionable and P.sel or 1
    e.label = actionable and (o.label or '') or ''
    e.sublabel = o.sublabel or ''
    e.icon = o.icon
    e.image = actionable and o.image or nil
    e.glyph = actionable and PromptKeys.glyph(o.control, o.key, S.pad, S.now) or (o.icon or 'dot')
    e.control = o.control
    e.sizeRange = P.distance
    e.scale = P.scale
    e.flashAt, e.flashR, e.flashG, e.flashB = P.flashAt, P.flashR, P.flashG, P.flashB
    -- The option stack: each offered option's glyph and words (the renderer reads them by index).
    local g, l, s = e.optGlyphs, e.optLabels, e.optSubs
    local count = actionable and n or 0
    for i = 1, count do
        local oi = P.options[P.avail[i]]
        g[i] = PromptKeys.glyph(oi.control, oi.key, S.pad, S.now)
        l[i] = oi.label or ''
        s[i] = oi.sublabel or ''
    end
    for i = #g, count + 1, -1 do g[i], l[i], s[i] = nil, nil, nil end
    e.focused = false

    -- Focus: in reach and something to press. Looked at (inside the aim cone) beats nearest.
    if e.active and actionable then
        if aim >= S.coneAim then
            if aim > S.bestAim then S.bestAim, S.bestAimKey = aim, vkey end
        elseif aim >= S.coneNear then
            if dist < S.bestNear then S.bestNear, S.bestNearKey = dist, vkey end
        end
    end
end

--- One score frame: what is in sight, in reach and focused.
---@param now number  GetGameTimer
function M.score(now)
    local ped = PlayerPedId()
    local pc = GetEntityCoords(ped)
    S.px, S.py, S.pz = pc.x, pc.y, pc.z
    local cam = GetFinalRenderedCamCoord()
    S.camX, S.camY, S.camZ = cam.x, cam.y, cam.z
    S.cfx, S.cfy, S.cfz = PromptCameraForward()
    S.coneAim = cos(rad(Config.FocusCone or 30.0))
    S.coneNear = cos(rad(Config.FocusConeNear or 100.0))
    S.bestAim, S.bestAimKey = -2.0, nil
    S.bestNear, S.bestNearKey = math.huge, nil
    S.pad = PromptKeys.padActive(now)
    S.now = now

    for k in pairs(seen) do seen[k] = nil end

    -- Door prompts pfm-doorlock could not place yet (it starts after us, or the door list loads late).
    if next(pendingDoors) and now - lastDoorRetry >= DOOR_RETRY_MS then
        lastDoorRetry = now
        for key in pairs(pendingDoors) do
            local P = registry[key]
            if P then place(P) else pendingDoors[key] = nil end
        end
    end

    -- Static prompts: the grid cells round the player.
    local range = Config.MaxShowDistance or 25.0
    local myCell = cellKeyOf(S.px, S.py)
    if nearbyAt ~= myCell or nearbyRange ~= range then
        nearbyAt, nearbyRange = myCell, range
        rebuildNearby(S.px, S.py, range)
    end
    for c = 1, #nearbyCells do
        local bucket = grid[nearbyCells[c]]
        if bucket then
            for key in pairs(bucket) do
                local P = registry[key]
                if P then consider(P, key, P.x, P.y, P.z, nil) end
            end
        end
    end

    -- Moving prompts.
    if next(dynamic) then
        if now - lastModelScan >= MODEL_SCAN_MS then scanModels(S.px, S.py, S.pz, now) end
        for key in pairs(dynamic) do
            local P = registry[key]
            if P then
                if P.kind == 'entity' then
                    local x, y, z = entityPos(P, P.entity)
                    if x then consider(P, key, x, y, z, P.entity) end
                elseif P.kind == 'net' then
                    if NetworkDoesNetworkIdExist(P.netId) then
                        local ent = NetworkGetEntityFromNetworkId(P.netId)
                        local x, y, z = entityPos(P, ent)
                        if x then consider(P, key, x, y, z, ent) end
                    end
                elseif P.kind == 'model' then
                    for i = 1, #P.instances do
                        local ent = P.instances[i]
                        local x, y, z = entityPos(P, ent)
                        if x then consider(P, key .. '#' .. ent, x, y, z, ent) end
                    end
                end
            end
        end
    end

    -- What left: back to the spare pool.
    for vkey, e in pairs(visible) do
        if not seen[vkey] then
            visible[vkey] = nil
            visibleN = visibleN - 1
            spare[#spare + 1] = e
        end
    end

    -- Too many: the nearest MaxDrawn stay.
    local maxDrawn = Config.MaxDrawn or 24
    if visibleN > maxDrawn then
        for i = #order, 1, -1 do order[i] = nil end
        for _, e in pairs(visible) do order[#order + 1] = e end
        table.sort(order, nearerFirst)
        for i = maxDrawn + 1, #order do
            local e = order[i]
            visible[e.vkey] = nil
            visibleN = visibleN - 1
            spare[#spare + 1] = e
            if S.bestAimKey == e.vkey then S.bestAimKey = nil end
            if S.bestNearKey == e.vkey then S.bestNearKey = nil end
        end
    end

    -- A hold in progress keeps its prompt focused while it is still in reach.
    local focus = S.bestAimKey or S.bestNearKey
    if hold then
        local he = visible[hold.vkey]
        if he and he.active and he.actionable then focus = hold.vkey end
    end
    focusVKey = focus
    if focus then visible[focus].focused = true end

    -- Which entries show words.
    local labelsAll = Config.Labels == 'active'
    for _, e in pairs(visible) do
        local hasText = (e.label ~= '' or e.sublabel ~= '')
        e.wantLabel = hasText and (e.focused or (e.active and (labelsAll or not e.actionable))) or false
    end
    return visibleN
end

-- ---------------------------------------------------------------------------------------------
-- Keys

local function isJustPressed(c)
    return IsControlJustPressed(0, c) or IsDisabledControlJustPressed(0, c)
end

local function isPressed(c)
    return IsControlPressed(0, c) or IsDisabledControlPressed(0, c)
end

--- Run the option: re-checked at the moment of the press, then its server event, client event or
--- callback. Server checks stay where they are: this only asks.
local function fire(P, o, e)
    if o.canInteract ~= nil then
        local fine, res = ask(P, 'canInteract', o.canInteract, P.id, o.index, e and e.entity or nil)
        if not (fine and res) then return false end
    end
    P.pressAt = GetGameTimer()
    if type(o.onPress) == 'string' then
        local args = type(o.args) == 'table' and o.args or {}
        TriggerServerEvent(o.onPress, table.unpack(args))
    elseif o.onPress ~= nil then
        ask(P, 'onPress', o.onPress, P.id, { option = o.index, entity = e and e.entity or nil,
            coords = e and vector3(e.x, e.y, e.z) or nil })
    end
    if o.clientEvent then
        local args = type(o.args) == 'table' and o.args or {}
        TriggerEvent(o.clientEvent, table.unpack(args))
    end
    return true
end

--- The selected offered option of an entry's prompt.
local function selected(e)
    local P = e and registry[e.key]
    if not P or P.availN < 1 then return nil, nil end
    local oi = P.avail[P.sel]
    return P, oi and P.options[oi]
end

--- Read the keys for the focused prompt (every frame while something is drawn).
---@param now number
function M.keys(now)
    local e = focusVKey and visible[focusVKey]
    local P, o = selected(e)

    -- Cycle the options: the wheel (16 next, 17 previous) and, on a pad, the D-pad. The weapon wheel
    -- is held off meanwhile so scrolling does not change weapon. Clamped, not wrapped (as WHIP).
    if P and P.availN > 1 then
        for i = 1, #SCROLL_BLOCK do DisableControlAction(0, SCROLL_BLOCK[i], true) end
        local sc, pc = Config.ScrollControls or {}, Config.PadScrollControls or {}
        local padOn = S.pad
        if padOn then
            DisableControlAction(0, pc.next or 173, true)
            DisableControlAction(0, pc.prev or 172, true)
        end
        local nextP = IsDisabledControlJustPressed(0, sc.next or 16) or (padOn and IsDisabledControlJustPressed(0, pc.next or 173))
        local prevP = IsDisabledControlJustPressed(0, sc.prev or 17) or (padOn and IsDisabledControlJustPressed(0, pc.prev or 172))
        if nextP and P.sel < P.availN then
            P.sel = P.sel + 1
            nextScoreAt = 0
        elseif prevP and P.sel > 1 then
            P.sel = P.sel - 1
            nextScoreAt = 0
        end
        -- The entry follows at once (the renderer slides to it; the words change on the next score).
        e.sel = P.sel
        o = P.options[P.avail[P.sel]]
    end

    -- The press: only the focused prompt reacts.
    if P and o and not hold and isJustPressed(o.control) then
        nextScoreAt = 0
        if o.holdMs then
            hold = { vkey = focusVKey, opt = o.index, start = now, ms = o.holdMs }
            e.holdP = 0.0
        else
            fire(P, o, e)
        end
    end

    -- Hold to use: runs while the same option of the same prompt stays focused and the key stays down.
    if hold then
        local he = visible[hold.vkey]
        local HP, ho = selected(he)
        if not he or focusVKey ~= hold.vkey or not ho or ho.index ~= hold.opt or not isPressed(ho.control) then
            if he then he.holdP = nil end
            hold = nil
        else
            local p = (now - hold.start) / hold.ms
            if p < 1.0 then
                he.holdP = p
            else
                he.holdP = nil
                he.holdDoneAt = now
                hold = nil
                fire(HP, ho, he)
            end
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- The pass

--- Nothing to draw: the renderer lets go of its rows and fades.
function M.clear()
    for vkey, e in pairs(visible) do
        visible[vkey] = nil
        spare[#spare + 1] = e
    end
    visibleN = 0
    focusVKey = nil
    hold = nil
    if M.renderer and M.renderer.clear then M.renderer.clear() end
end

--- One pass of the loop. Returns how long to wait before the next.
---@param now number
---@return number ms
function M.tick(now)
    local R = M.renderer
    if not next(registry) then
        if visibleN > 0 then M.clear() end
        -- The last prompts were just removed: let them fade out.
        if R and R.busy and R.busy() then
            R.frame(visible, true, now)
            return 0
        end
        return 500
    end
    if IsPauseMenuActive() then return 250 end

    local isScoreFrame = now >= nextScoreAt
    if isScoreFrame then
        M.score(now)
        nextScoreAt = now + (visibleN > 0 and (Config.ScoreMs or 66) or (Config.IdleMs or 250))
    end

    if visibleN == 0 then
        -- Still fading out what just left.
        if R and R.busy and R.busy() then
            R.frame(visible, isScoreFrame, now)
            return 0
        end
        return Config.IdleMs or 250
    end

    if R then R.frame(visible, isScoreFrame, now) end
    M.keys(now)
    return 0
end

--- Forget the clock (tests; also after a renderer change, so the next pass scores at once).
function M.scoreSoon() nextScoreAt = 0 end

M._S = S
