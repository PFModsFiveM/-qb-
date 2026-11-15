-- Copyright (c) 2026 Whippy, from WHIP, LGPL-3.0; modified for PF.
-- (WHIP whip_core/client/interact_world.lua, reduced and renamed: no box wrapping, centring or
-- fitting, no theme atlases or style animations; a fourth badge row for prompts with nothing to
-- press; the label row carries a sublabel; the preview browser is made on first use.)
--
-- World-space prompts: textured triangles drawn by the engine, depth-tested, with no position passing
-- through a browser. What is drawn comes from at most three DUIs, however many prompts exist:
--   badge atlas   every badge state for every glyph in use in one texture (a state change is a UV cell)
--   label atlas   N rows of text, repainted only when a row's text changes
--   preview       one picture for the focused option (512x288), made the first time one is asked for
-- Two quads per prompt: the badge sits on the world point, the label is a fixed-size cell beside it
-- (DUI is one-way, so the text width is unknown).

local R = { name = 'world' }

-- Atlas geometry, shared with the HTML pages.
local BADGE_COLS   = 32       -- distinct glyphs (keys, pad buttons, icons); a full atlas falls back to column 0
local BADGE_CELL   = 128      -- px per square cell (fitted down by attach() if the game refuses the width)
local BADGE_STATES = 4        -- idle / active / focused / info, in that row order
local BADGE_DISC_FRAC = 0.78  -- how much of a cell the visible disc fills (badge.html's --disc-frac)

local LABEL_W     = 1024      -- px, one row's width
local LABEL_ROW_H = 96        -- px, one row's height

local TXD_BADGE, TEX_BADGE     = 'pfm_prompts_badge_txd', 'badge'
local TXD_LABEL, TEX_LABEL     = 'pfm_prompts_label_txd', 'label'
local TXD_PREVIEW, TEX_PREVIEW = 'pfm_prompts_preview_txd', 'preview'
local PREVIEW_W, PREVIEW_H = 512, 288

local badgePage, labelPage, previewPage = nil, nil, nil
local previewSrc = nil
local attached = false

-- glyph -> atlas column. 'E' is claimed up front, then the white cell the hold ring samples.
local keyCols, keyList, keyCount = { E = 0, __white = 1 }, { 'E', '__white' }, 2

-- Label rows: [rowIndex] = { id = owner vkey or nil, text, sub }
local rows = {}

-- Cached sizing
local badgeM, labelM = nil, nil
local sizedForFov = nil

--- The per-prompt animation state ([vkey] = fx), outliving the entry so a prompt can fade out.
local fx = {}

-- Scalars, not vectors, in the draw path: every vector operation allocates.

--- The resolution every pixel figure in Config is quoted at.
local REFERENCE_H = 1440.0

--- How tall in metres something must be to appear `px` tall on a 1440p screen at Config.Distance:
--- screen fraction = worldHeight / (2 * distance * tan(fov/2)). GetGameplayCamFov is vertical.
local function pxToMetres(px, fov)
    local range = Config.Distance or 2.0
    return (px / REFERENCE_H) * 2.0 * range * math.tan(math.rad(fov) * 0.5)
end

local function updateBadgeSize()
    local cfg = Config.World or {}
    local fov = GetGameplayCamFov()
    if not fov or fov <= 0 then
        badgeM = badgeM or 0.06
        labelM = labelM or 0.045
        return
    end
    if fov == sizedForFov then return end
    sizedForFov = fov
    if cfg.badgeMetres then
        badgeM = cfg.badgeMetres + 0.0
    else
        -- The disc's height to hit the target, scaled out to the whole cell (which carries a margin).
        badgeM = pxToMetres(cfg.badgePx or 62, fov) / BADGE_DISC_FRAC
    end
    labelM = pxToMetres(cfg.labelPx or 88, fov)
end

local function badgeSetup()
    local st = PromptStyle.get()
    return json.encode({
        cell = BADGE_CELL, cols = BADGE_COLS, keys = keyList, discFrac = BADGE_DISC_FRAC,
        theme = st.theme, dark = st.dark, colors = Config.Colors or {},
    })
end

local function labelSetup()
    return { setup = { width = LABEL_W, rowH = LABEL_ROW_H, rows = #rows, colors = Config.Colors or {} } }
end

local function newBadgePage()
    return PromptDui.new({
        name = 'badge', url = 'badge.html', txd = TXD_BADGE, tex = TEX_BADGE,
        width = function() return BADGE_CELL * BADGE_COLS end,
        height = function() return BADGE_CELL * BADGE_STATES end,
        setup = badgeSetup,
        -- Told again a moment after it is up: a browser may not be listening for the first message.
        again = { 500, 1500 },
        quiet = true,
    })
end

---@return boolean attached
function R.attach()
    if attached then return true end
    local cfg = Config.World or {}
    local rowCount = math.max(1, math.floor(cfg.labelRows or 8))
    rows = {}
    for i = 1, rowCount do rows[i] = { id = nil, text = nil, sub = nil } end

    -- A browser wider than the game allows throws and names the limit ("Invalid Width [1, 8192]"):
    -- the cell is fitted to it and the atlas made again. Any other refusal leaves the renderer off.
    badgePage = newBadgePage()
    local made, why = badgePage:ensure()
    local maxW = not made and tonumber(tostring(why):match('Invalid Width %[%d+, (%d+)%]'))
    if maxW and maxW >= BADGE_COLS then
        BADGE_CELL = math.min(BADGE_CELL, maxW // BADGE_COLS)
        badgePage = newBadgePage()
        made, why = badgePage:ensure()
    end
    if not made then
        badgePage = nil
        print(('[pfm-prompts] the game refused the badge texture, so 3D prompts are off: %s'):format(tostring(why)))
        return false
    end

    labelPage = PromptDui.new({ name = 'label', url = 'label.html', width = LABEL_W,
        height = LABEL_ROW_H * rowCount, txd = TXD_LABEL, tex = TEX_LABEL, setup = labelSetup,
        without = 'prompts show no words' })
    labelPage:ensure()

    -- The preview is made the first time a prompt shows a picture (most servers never use one).
    previewPage = PromptDui.new({ name = 'preview', url = 'preview.html', width = PREVIEW_W,
        height = PREVIEW_H, txd = TXD_PREVIEW, tex = TEX_PREVIEW, without = 'prompts show no pictures' })
    previewSrc = nil
    attached = true
    sizedForFov = nil
    updateBadgeSize()
    return true
end

function R.detach()
    if badgePage then badgePage:release(); badgePage = nil end
    if labelPage then labelPage:release(); labelPage = nil end
    if previewPage then previewPage:release(); previewPage = nil end
    previewSrc = nil
    attached = false
    rows = {}
    fx = {}
end

--- Nothing on screen: the browsers stay (they are the expensive part); the rows are handed back.
function R.clear()
    for i = 1, #rows do
        if rows[i].id then
            rows[i].id, rows[i].text, rows[i].sub = nil, nil, nil
            if labelPage then labelPage:send({ row = i - 1, text = '', sub = '' }, i) end
        end
    end
    if previewPage and previewSrc then previewPage:send({ image = '' }, 'image') end
    previewSrc = nil
    fx = {}
end

--- Still fading something out.
function R.busy()
    return next(fx) ~= nil
end

-- Glyphs and label rows

--- Which atlas column holds this glyph, claiming one if new. A full atlas falls back to column 0.
local function columnForKey(key)
    key = key or 'E'
    local col = keyCols[key]
    if col then return col end
    if keyCount >= BADGE_COLS then
        print(('[pfm-prompts] badge atlas is full (%d glyphs): "%s" shows as E'):format(BADGE_COLS, tostring(key)))
        keyCols[key] = 0
        return 0
    end
    col = keyCount
    keyCols[key] = col
    keyCount = keyCount + 1
    keyList[keyCount] = key
    -- Rare: only the first time a glyph is ever seen.
    if badgePage then badgePage:send(badgeSetup(), 'setup') end
    return col
end

--- Hand every row this prompt holds back to the pool.
local function releaseRow(f)
    local held = f._rows
    if not held then return end
    for k = 1, #held do
        local i = held[k]
        local row = rows[i]
        if row and row.id == f.id then
            row.id, row.text, row.sub = nil, nil, nil
            if labelPage then labelPage:send({ row = i - 1, text = '', sub = '' }, i) end
        end
        held[k] = nil
    end
    f._rows, f._row, f._slots = nil, nil, nil
end

--- Paint one row, only if what it says differs. The only place a repaint happens.
local function paintRow(i, text, sub)
    local row = rows[i]
    if not row then return end
    text, sub = text or '', sub or ''
    if row.text == text and row.sub == sub then return end
    row.text, row.sub = text, sub
    if labelPage then labelPage:send({ row = i - 1, text = text, sub = sub }, i) end
end

--- Give this prompt a row per option, each saying what its option says. With more options than rows,
--- a rolling window holds the options round the selection (repainting is asynchronous, so scrolling
--- only changes which row the quad samples).
---@return boolean ok  false when the atlas had no room
local function ensureRow(f)
    local labels, subs = f.optLabels, f.optSubs
    local want = (f.actionable and labels and #labels > 0) and #labels or 1
    local slots = math.min(want, #rows)
    f._slots = slots
    local held = f._rows
    if not held then held = {}; f._rows = held end

    for k = 1, slots do
        local i = held[k]
        if not (i and rows[i] and rows[i].id == f.id) then
            i = nil
            for j = 1, #rows do
                if not rows[j].id then
                    rows[j].id, rows[j].text, rows[j].sub = f.id, nil, nil
                    i = j
                    break
                end
            end
            held[k] = i
        end
    end

    local sel = f.sel or 1
    if sel < 1 then sel = 1 elseif sel > want then sel = want end
    local lo = sel - math.floor((slots - 1) / 2)
    if lo > want - slots + 1 then lo = want - slots + 1 end
    if lo < 1 then lo = 1 end
    for n = lo, lo + slots - 1 do
        local i = held[(n - 1) % slots + 1]
        if i then
            if n == sel or not f.actionable then
                paintRow(i, f.label, f.sublabel)
            else
                paintRow(i, labels[n], subs and subs[n])
            end
        end
    end

    -- Options went away: the surplus rows go back.
    for k = slots + 1, #held do
        local i = held[k]
        local row = i and rows[i]
        if row and row.id == f.id then
            row.id, row.text, row.sub = nil, nil, nil
            if labelPage then labelPage:send({ row = i - 1, text = '', sub = '' }, i) end
        end
        held[k] = nil
    end

    f._row = held[(sel - 1) % slots + 1]
    return f._row ~= nil
end

-- Drawing

local quadDraw = PromptQuad.draw
local billboardBasis = PromptQuad.billboardBasis

---@return number 0 idle | 1 in reach | 2 focused | 3 info (in reach, nothing to press)
local function stateOf(focused, active, actionable)
    if focused then return 2 end
    if active and not actionable then return 3 end
    return active and 1 or 0
end

--- The badge's tint: the style's, unless a Flash() is decaying (two pulses of colour).
local FLASH_CURVE = {
    { 0.00, 1.0 }, { 0.20, 1.0 }, { 0.34, 0.0 }, { 0.46, 0.0 }, { 0.60, 1.0 }, { 0.74, 1.0 }, { 1.00, 0.0 },
}

local function flashAmount(k)
    for i = 1, #FLASH_CURVE - 1 do
        local a, b = FLASH_CURVE[i], FLASH_CURVE[i + 1]
        if k <= b[1] then
            local span = b[1] - a[1]
            if span <= 0 then return b[2] end
            return a[2] + (b[2] - a[2]) * ((k - a[1]) / span)
        end
    end
    return 0.0
end

local function flashTint(f, st, now)
    local br, bg, bb = st.tintR, st.tintG, st.tintB
    if not f.flashAt then return br, bg, bb end
    local age = now - f.flashAt
    if age < 0 or age >= st.flashMs then return br, bg, bb end
    local amt = flashAmount(age / st.flashMs)
    if amt <= 0.0 then return br, bg, bb end
    local inv = 1.0 - amt
    local fr, fg, fb = f.flashR or br, f.flashG or bg, f.flashB or bb
    return math.floor(fr + (br - fr) * inv + 0.5), math.floor(fg + (bg - fg) * inv + 0.5),
        math.floor(fb + (bb - fb) * inv + 0.5)
end

--- Move `cur` toward `target` by a frame's worth of a `dur`-second transition (frame-rate independent).
local function approach(cur, target, dt, dur)
    if dur <= 0 then return target end
    local step = dt / dur
    if step >= 1.0 then return target end
    return cur + (target - cur) * step
end

--- 0..1 held to that range, as 0..255.
local function byte(x)
    if x <= 0.0 then return 0 end
    if x >= 1.0 then return 255 end
    return math.floor(x * 255.0 + 0.5)
end

local TAU = math.pi * 2.0
local RING_SEGS = 40

--- A point `t` of the way round the hold ring (clockwise from the top), in the badge's plane, and the
--- path's direction there. A circle of radius `half`, or with a `corner` a rounded square.
local function ringPoint(t, half, corner)
    if not corner then
        local ang = t * TAU
        local s, c = math.sin(ang), math.cos(ang)
        return s * half, c * half, c, -s
    end
    local straight = half - corner
    local arc = corner * math.pi * 0.5
    local d = (t % 1.0) * (8.0 * straight + 4.0 * arc)
    if d < straight then return d, half, 1.0, 0.0 end
    d = d - straight
    for k = 1, 4 do
        if d < arc then
            local ang = (k - 1) * math.pi * 0.5 + d / corner
            local s, c = math.sin(ang), math.cos(ang)
            local ccx = (k <= 2) and straight or -straight
            local ccy = (k == 1 or k == 4) and straight or -straight
            return ccx + s * corner, ccy + c * corner, c, -s
        end
        d = d - arc
        local len = (k < 4) and (2.0 * straight) or straight
        if d < len then
            if k == 1 then return half, straight - d, 0.0, -1.0 end
            if k == 2 then return straight - d, -half, -1.0, 0.0 end
            if k == 3 then return -half, -straight + d, 0.0, 1.0 end
            return -straight + d, half, 1.0, 0.0
        end
        d = d - len
    end
    return 0.0, half, 1.0, 0.0
end

local function ringArc(cx, cy, cz, rx, ry, rz, ux, uy, uz, half, corner, perimeter, thick, from, to,
                       u0, v0, u1, v1, a, r, g, b)
    local px, py, dx, dy = ringPoint((from + to) * 0.5, half, corner)
    local tx, ty, tz = rx * dx + ux * dy, ry * dx + uy * dy, rz * dx + uz * dy
    local ox, oy, oz = -rx * dy + ux * dx, -ry * dy + uy * dx, -rz * dy + uz * dx
    local len = (to - from) * perimeter * 1.12   -- a little long, so neighbours meet
    quadDraw(TXD_BADGE, TEX_BADGE,
             cx + rx * px + ux * py, cy + ry * px + uy * py, cz + rz * px + uz * py,
             tx, ty, tz, ox, oy, oz, len, thick, u0, v0, u1, v1, a, r, g, b)
end

--- The hold ring: a dark track all the way round, and over it the part filled so far (`p`, 0..1).
local function drawHoldRing(cx, cy, cz, rx, ry, rz, ux, uy, uz, half, corner, thick, p, a, r, g, b)
    local col = keyCols.__white
    local u0, u1 = (col + 0.3) / BADGE_COLS, (col + 0.7) / BADGE_COLS
    local v0, v1 = 0.3 / BADGE_STATES, 0.7 / BADGE_STATES
    local perimeter = corner and (8.0 * (half - corner) + 2.0 * math.pi * corner) or (TAU * half)
    local trackA = math.floor(a * 0.55 + 0.5)
    local seg = 1.0 / RING_SEGS
    for i = 0, RING_SEGS - 1 do
        local from = i * seg
        if trackA >= 1 then
            ringArc(cx, cy, cz, rx, ry, rz, ux, uy, uz, half, corner, perimeter, thick, from, from + seg,
                    u0, v0, u1, v1, trackA, 0, 0, 0)
        end
        if p > from then
            ringArc(cx, cy, cz, rx, ry, rz, ux, uy, uz, half, corner, perimeter, thick, from, math.min(p, from + seg),
                    u0, v0, u1, v1, a, r, g, b)
        end
    end
end

--- The prompts that want a label this score frame, nearest first: one reused list.
local wantRows = {}
local function nearerFirst(a, b) return (a.dist or 0) < (b.dist or 0) end

--- Draw one frame. `visible` is the registry's [vkey] = entry.
---@param visible table
---@param isScoreFrame boolean
---@param now number  GetGameTimer
function R.frame(visible, isScoreFrame, now)
    if not attached then return end
    updateBadgeSize()
    badgePage:used()

    local cfg = Config.World or {}
    local st = PromptStyle.get()
    local cam = GetFinalRenderedCamCoord()
    local camX, camY, camZ = cam.x, cam.y, cam.z
    local rx, ry, rz, ux, uy, uz = billboardBasis()

    local defaultActive = Config.Distance or 2.0
    if defaultActive <= 0.0 then defaultActive = 2.0 end
    local bM = badgeM or 0.06
    local labelH = labelM or 0.045
    local labelW = labelH * (LABEL_W / LABEL_ROW_H)

    local dt = GetFrameTime()
    if dt <= 0.0 then dt = 1.0 / 60.0 end

    -- Mark everything gone, then un-mark what is still here; what stays marked fades out where it was.
    for _, f in pairs(fx) do f.alive = false end

    for vkey, e in pairs(visible) do
        local f = fx[vkey]
        if not f then
            f = { a = 0.0, state = stateOf(e.focused, e.active, e.actionable), prev = nil, blend = 1.0,
                  labelA = 0.0, stackA = 0.0, imageA = 0.0, holdA = 0.0, slide = e.sel or 1,
                  optLabels = {}, optSubs = {}, optGlyphs = {} }
            fx[vkey] = f
        end
        f.id = vkey
        f.alive = true
        f.x, f.y, f.z, f.dist = e.x, e.y, e.z, e.dist
        f.label, f.sublabel, f.actionable = e.label, e.sublabel, e.actionable
        f.glyph = e.glyph
        f.sizeScale = ((e.sizeRange or defaultActive) / defaultActive) * (e.scale or 1.0)
        f.flashAt, f.flashR, f.flashG, f.flashB = e.flashAt, e.flashR, e.flashG, e.flashB
        f.holdP, f.holdDoneAt = e.holdP, e.holdDoneAt
        if e.holdP then f.holdShown = e.holdP end
        f.image = e.image
        f.wantImage = (e.focused and e.image and e.image ~= '') and true or false
        f.wantLabel = e.wantLabel and true or false
        f.targetA = PromptStyle.alpha(st, e.focused, e.active)
        f.availN = e.availN or 1
        f.sel = e.sel or 1
        -- Shared by reference: the registry rebuilds these in place.
        f.optLabels, f.optSubs, f.optGlyphs = e.optLabels, e.optSubs, e.optGlyphs

        local held, slots = f._rows, f._slots
        if held and slots and slots > 0 then
            local sel = f.sel
            if sel < 1 then sel = 1 end
            f._row = held[(sel - 1) % slots + 1]
        end
        f.wantStack = (e.focused and (e.availN or 1) > 1) and true or false

        local want = stateOf(e.focused, e.active, e.actionable)
        local col = columnForKey(f.glyph)
        if want ~= f.state or col ~= f.col then
            -- A crossfade: the outgoing cell under the incoming one until the blend completes.
            f.prev, f.prevCol = f.state, f.col or col
            f.state, f.col = want, col
            f.blend = 0.0
        end
    end

    -- The preview: sent only when it changes.
    local wantImage = nil
    for _, f in pairs(fx) do
        if f.alive and f.wantImage then wantImage = f.image; break end
    end
    if wantImage ~= previewSrc then
        previewSrc = wantImage
        if previewPage and (wantImage or previewPage:exists()) then
            if wantImage then previewPage:ensure() end
            previewPage:send({ image = wantImage or '' }, 'image')
        end
    end

    -- Rows follow the fx, so a label fades out with its prompt. Recomputed on score frames only.
    if isScoreFrame then
        for _, f in pairs(fx) do
            if f.alive and f.wantLabel then wantRows[#wantRows + 1] = f end
        end
        table.sort(wantRows, nearerFirst)
        for _, f in pairs(fx) do
            if f._rows and not (f.wantLabel and f.alive) and (f.labelA or 0) <= 0.02 then releaseRow(f) end
        end
        for i = 1, #wantRows do ensureRow(wantRows[i]) end
        for i = #wantRows, 1, -1 do wantRows[i] = nil end
    end

    local maxBias = cfg.depthBias or 0.30
    local fade = st.fade

    for vkey, f in pairs(fx) do
        f.a = approach(f.a, f.alive and f.targetA or 0.0, dt, fade)
        f.labelA = approach(f.labelA, (f.alive and f.wantLabel) and 1.0 or 0.0, dt, fade)
        f.imageA = approach(f.imageA, (f.alive and f.wantImage) and 1.0 or 0.0, dt, fade)
        f.stackA = approach(f.stackA, (f.alive and f.wantStack) and 1.0 or 0.0, dt, fade)
        f.holdA = approach(f.holdA, (f.alive and f.holdP) and 1.0 or 0.0, dt, fade)
        f.slide = approach(f.slide or f.sel or 1, f.sel or 1, dt, st.slide)
        if f.blend < 1.0 then
            f.blend = approach(f.blend, 1.0, dt, st.crossfade)
            if f.blend > 0.995 then f.blend = 1.0; f.prev = nil end
        end

        -- Faded out: release what it holds and forget it.
        if not f.alive and f.a <= 0.004 then
            releaseRow(f)
            fx[vkey] = nil
            goto nextFx
        end

        do
            local a = byte(f.a)

            -- A finished hold pops.
            local animBadge = 1.0
            if f.holdDoneAt then
                local p = (now - f.holdDoneAt) / 220.0
                if p >= 0.0 and p < 1.0 then animBadge = 1.0 + 0.24 * math.sin(math.pi * p) end
            end

            -- Pulled toward the camera along the view ray (same pixel, in front, scaled so its screen
            -- size is unchanged), so the door or prop it labels does not cover it.
            local dx, dy, dz = camX - f.x, camY - f.y, camZ - f.z
            local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
            local bias, shrink = 0.0, 1.0
            if dist > 0.05 then
                bias = math.min(maxBias, dist * 0.5)
                shrink = (dist - bias) / dist
            end
            local inv = bias / math.max(dist, 0.0001)
            local cx, cy, cz = f.x + dx * inv, f.y + dy * inv, f.z + dz * inv

            local sc      = (f.sizeScale or 1.0) * shrink
            local bMs     = bM * sc * st.badgeScale
            local gapMs   = bMs * st.gap
            local ls      = sc * st.labelScale
            local labelWs = labelW * ls
            local labelHs = labelH * ls
            local bDraw   = bMs * animBadge

            -- The carousel: the selected option sits at the anchor and the list slides through it.
            local step = bMs * (1.0 + st.stackGap)
            local slide = f.slide or f.sel or 1
            local poff = -((f.sel or 1) - slide) * step
            local pcx, pcy, pcz = cx + ux * poff, cy + uy * poff, cz + uz * poff

            local col = f.col or 0
            local outA = (f.prev and f.blend < 1.0) and math.floor(a * (1.0 - f.blend) + 0.5) or 0
            local inA  = (f.prev and f.blend < 1.0) and math.min(255, math.floor(a * f.blend + 0.5)) or a
            local tr, tg, tb = flashTint(f, st, now)

            if outA >= 1 then
                local s, pc = f.prev, f.prevCol or col
                quadDraw(TXD_BADGE, TEX_BADGE, pcx, pcy, pcz, rx, ry, rz, ux, uy, uz, bDraw, bDraw,
                         pc / BADGE_COLS, s / BADGE_STATES, (pc + 1) / BADGE_COLS, (s + 1) / BADGE_STATES, outA, tr, tg, tb)
            end
            if inA >= 1 then
                local s = f.state
                quadDraw(TXD_BADGE, TEX_BADGE, pcx, pcy, pcz, rx, ry, rz, ux, uy, uz, bDraw, bDraw,
                         col / BADGE_COLS, s / BADGE_STATES, (col + 1) / BADGE_COLS, (s + 1) / BADGE_STATES, inA, tr, tg, tb)
            end

            -- The hold ring, just outside the disc.
            if f.holdA > 0.004 and f.holdShown then
                local ra = math.min(255, math.floor(a * f.holdA + 0.5))
                if ra >= 1 then
                    local thick = bMs * 0.07
                    local half = bDraw * BADGE_DISC_FRAC * 0.5 + thick * 0.9
                    local corner = (st.theme == 'keycap') and (bDraw * BADGE_DISC_FRAC * 0.26 + thick * 0.9) or nil
                    drawHoldRing(pcx, pcy, pcz, rx, ry, rz, ux, uy, uz, half, corner, thick,
                                 f.holdShown, ra, st.holdR, st.holdG, st.holdB)
                end
            end

            -- The other options: drawn from the focused row (the only row with a glyph), dimmed.
            if f.stackA > 0.004 and f.optGlyphs and (f.availN or 1) > 1 then
                local sa = math.min(255, math.floor(a * st.stackAlpha * f.stackA + 0.5))
                if sa >= 1 then
                    local sel = f.sel or 1
                    for k = 1, f.availN do
                        if k ~= sel then
                            local koff = -(k - slide) * step
                            local kcol = columnForKey(f.optGlyphs[k])
                            quadDraw(TXD_BADGE, TEX_BADGE, cx + ux * koff, cy + uy * koff, cz + uz * koff,
                                     rx, ry, rz, ux, uy, uz, bMs, bMs,
                                     kcol / BADGE_COLS, 2 / BADGE_STATES, (kcol + 1) / BADGE_COLS, 3 / BADGE_STATES,
                                     sa, tr, tg, tb)
                        end
                    end
                end
            end

            -- The label, hung off the badge's right edge (riding the slide).
            if f._row and f.labelA > 0.004 then
                local la = math.min(255, math.floor(a * f.labelA + 0.5))
                if la >= 1 then
                    local offset = (bMs * 0.5) + gapMs + (labelWs * 0.5)
                    local lv0 = (f._row - 1) / #rows
                    local lv1 = f._row / #rows
                    quadDraw(TXD_LABEL, TEX_LABEL,
                             pcx + rx * offset, pcy + ry * offset, pcz + rz * offset,
                             rx, ry, rz, ux, uy, uz, labelWs, labelHs,
                             0.0, lv0, 1.0, lv1, la, st.labelR, st.labelG, st.labelB)
                end
            end

            -- The picture above the words, aligned to where they start.
            if f.imageA > 0.004 and f.image and previewPage and previewPage:exists() then
                local ia = math.min(255, math.floor(a * f.imageA + 0.5))
                if ia >= 1 then
                    previewPage:used()
                    local imgH = labelHs * st.previewScale
                    local imgW = imgH * (PREVIEW_W / PREVIEW_H)
                    local across = (bMs * 0.5) + gapMs + (imgW * 0.5)
                    local up = (labelHs * 0.5) + (imgH * 0.5) + (labelHs * 0.35)
                    quadDraw(TXD_PREVIEW, TEX_PREVIEW,
                             pcx + rx * across + ux * up, pcy + ry * across + uy * up, pcz + rz * across + uz * up,
                             rx, ry, rz, ux, uy, uz, imgW, imgH, 0.0, 0.0, 1.0, 1.0, ia, 255, 255, 255)
                end
            end
        end

        ::nextFx::
    end
end

--- For tests and /pfmprompts: what the renderer holds.
function R._state()
    return { fx = fx, rows = rows, keyCols = keyCols, attached = attached, badgeM = badgeM, labelM = labelM }
end

PromptRenderers.world = R
