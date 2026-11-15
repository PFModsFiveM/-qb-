-- Copyright (c) 2026 Whippy, from WHIP, LGPL-3.0; modified for PF.
-- (A reduced port of WHIP whip_core/client/interact_style.lua: one look, from Config.World and
-- Config.Colors, instead of WHIP's named styles, player preferences and theme atlases.)
--
-- The prompts' look as the renderers read it: the opacity ladder, the transition times, the badge
-- shape and the colours. Resolved once (and again after PromptStyle.flush()), so a frame reads plain
-- numbers off one table.

PromptStyle = {}

local resolved = nil

local function seconds(ms, fallback)
    local n = tonumber(ms)
    if not n then return fallback end
    return math.max(0, n) / 1000.0
end

local function rgbOf(t, r, g, b)
    if type(t) == 'table' then
        return tonumber(t[1] or t.r) or r, tonumber(t[2] or t.g) or g, tonumber(t[3] or t.b) or b
    end
    if type(t) == 'string' then
        local hr, hg, hb = t:match('^#(%x%x)(%x%x)(%x%x)$')
        if hr then return tonumber(hr, 16), tonumber(hg, 16), tonumber(hb, 16) end
    end
    return r, g, b
end

local function build()
    local w = Config.World or {}
    local op = w.opacity or {}
    local colors = Config.Colors or {}
    local fade = seconds(w.fadeMs, 0.11)
    local holdR, holdG, holdB = rgbOf(colors.holdFill, 230, 232, 236)
    local theme = (w.theme == 'classic') and 'classic' or 'keycap'
    return {
        badgeScale = 1.0, labelScale = 1.0,
        seen = tonumber(op.seen) or 0.35,
        inReach = tonumber(op.inReach) or 0.85,
        focused = tonumber(op.focused) or 1.0,
        -- The badge and label are drawn white in their pages: the tint multiplies through.
        tintR = 255, tintG = 255, tintB = 255,
        labelR = 255, labelG = 255, labelB = 255,
        holdR = holdR, holdG = holdG, holdB = holdB,
        fade = fade, crossfade = fade, slide = fade,
        flashMs = tonumber(w.flashMs) or 900,
        gap = tonumber(w.gap) or 0.35,
        stackGap = tonumber(w.stackGap) or 0.25,
        stackAlpha = tonumber(w.stackAlpha) or 0.45,
        previewScale = tonumber(w.previewScale) or 3.4,
        theme = theme,
        dark = w.dark == true,
    }
end

--- The look every prompt wears.
---@return table
function PromptStyle.get()
    if not resolved then resolved = build() end
    return resolved
end

--- Forget the resolved look (a config change at runtime): the next get() reads Config again.
function PromptStyle.flush()
    resolved = nil
end

--- The opacity ladder: 0..1 for a prompt in this state.
---@param st table  PromptStyle.get()
---@param focused boolean @param active boolean
function PromptStyle.alpha(st, focused, active)
    if focused then return st.focused end
    if active then return st.inReach end
    return st.seen
end
