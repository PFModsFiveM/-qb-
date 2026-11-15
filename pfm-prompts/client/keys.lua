-- pfm-prompts: which key a prompt's badge shows, on a keyboard or a pad.
-- (PF code. The key-label idea, asking the game through GetControlInstructionalButton and reading
-- 't_E', follows WHIP's Interactions.keyName: Copyright (c) 2026 Whippy, from WHIP, LGPL-3.0;
-- modified for PF.)
--
-- A prompt names a GTA control (38 by default) and a key label for the keyboard ('E'). The game is
-- asked which input the control is on, so the badge is right after a player rebinds it:
--   't_E'    a keyboard key with a text name: shown as that text;
--   'b_NNN'  a button with no text (a mouse button, a pad button): on a pad, Config.PadButtonIds
--            names its glyph, else GTA's default pad layout for the control (PAD_DEFAULT below).

PromptKeys = {}

-- GTA's default ("Standard") pad layout for the controls prompts use, by control id. Xbox names; the
-- glyphs are neutral shapes (html/js/glyphs.js).
local PAD_DEFAULT = {
    [18] = 'pad_a',      -- INPUT_SKIP_CUTSCENE
    [20] = 'pad_down',   -- INPUT_MULTIPLAYER_INFO
    [21] = 'pad_a',      -- INPUT_SPRINT
    [22] = 'pad_x',      -- INPUT_JUMP
    [23] = 'pad_y',      -- INPUT_ENTER
    [24] = 'pad_rt',     -- INPUT_ATTACK
    [25] = 'pad_lt',     -- INPUT_AIM
    [26] = 'pad_r3',     -- INPUT_LOOK_BEHIND
    [27] = 'pad_up',     -- INPUT_PHONE
    [29] = 'pad_r3',     -- INPUT_SPECIAL_ABILITY_SECONDARY
    [36] = 'pad_l3',     -- INPUT_DUCK
    [37] = 'pad_lb',     -- INPUT_SELECT_WEAPON
    [38] = 'pad_lb',     -- INPUT_PICKUP (E / LB)
    [44] = 'pad_rb',     -- INPUT_COVER
    [45] = 'pad_b',      -- INPUT_RELOAD
    [46] = 'pad_right',  -- INPUT_TALK
    [47] = 'pad_left',   -- INPUT_DETONATE
    [48] = 'pad_down',   -- INPUT_HUD_SPECIAL
    [51] = 'pad_right',  -- INPUT_CONTEXT (E / D-pad right)
    [52] = 'pad_left',   -- INPUT_CONTEXT_SECONDARY
    [73] = 'pad_a',      -- INPUT_VEH_DUCK
    [74] = 'pad_right',  -- INPUT_VEH_HEADLIGHT
    [75] = 'pad_y',      -- INPUT_VEH_EXIT
    [86] = 'pad_l3',     -- INPUT_VEH_HORN
    [140] = 'pad_b',     -- INPUT_MELEE_ATTACK_LIGHT
    [172] = 'pad_up',    -- INPUT_CELLPHONE_UP
    [173] = 'pad_down',  -- INPUT_CELLPHONE_DOWN
    [174] = 'pad_left',  -- INPUT_CELLPHONE_LEFT
    [175] = 'pad_right', -- INPUT_CELLPHONE_RIGHT
    [176] = 'pad_a',     -- INPUT_CELLPHONE_SELECT
    [177] = 'pad_b',     -- INPUT_CELLPHONE_CANCEL
    [191] = 'pad_a',     -- INPUT_FRONTEND_RDOWN
    [194] = 'pad_b',     -- INPUT_FRONTEND_RRIGHT
    [199] = 'pad_start', -- INPUT_FRONTEND_PAUSE
    [201] = 'pad_a',     -- INPUT_FRONTEND_ACCEPT
    [202] = 'pad_b',     -- INPUT_FRONTEND_CANCEL
    [203] = 'pad_x',     -- INPUT_FRONTEND_X
    [204] = 'pad_y',     -- INPUT_FRONTEND_Y
    [244] = 'pad_back',  -- INPUT_INTERACTION_MENU
}

-- The game's own name for a control, for the screen renderer: GTA draws "~INPUT_PICKUP~" in text as
-- the right key or pad button by itself.
local INPUT_NAME = {
    [18] = 'INPUT_SKIP_CUTSCENE', [20] = 'INPUT_MULTIPLAYER_INFO', [21] = 'INPUT_SPRINT', [22] = 'INPUT_JUMP',
    [23] = 'INPUT_ENTER', [24] = 'INPUT_ATTACK', [25] = 'INPUT_AIM', [26] = 'INPUT_LOOK_BEHIND',
    [27] = 'INPUT_PHONE', [29] = 'INPUT_SPECIAL_ABILITY_SECONDARY', [36] = 'INPUT_DUCK',
    [37] = 'INPUT_SELECT_WEAPON', [38] = 'INPUT_PICKUP', [44] = 'INPUT_COVER', [45] = 'INPUT_RELOAD',
    [46] = 'INPUT_TALK', [47] = 'INPUT_DETONATE', [48] = 'INPUT_HUD_SPECIAL', [51] = 'INPUT_CONTEXT',
    [52] = 'INPUT_CONTEXT_SECONDARY', [73] = 'INPUT_VEH_DUCK', [74] = 'INPUT_VEH_HEADLIGHT',
    [75] = 'INPUT_VEH_EXIT', [86] = 'INPUT_VEH_HORN', [140] = 'INPUT_MELEE_ATTACK_LIGHT',
    [172] = 'INPUT_CELLPHONE_UP', [173] = 'INPUT_CELLPHONE_DOWN', [174] = 'INPUT_CELLPHONE_LEFT',
    [175] = 'INPUT_CELLPHONE_RIGHT', [176] = 'INPUT_CELLPHONE_SELECT', [177] = 'INPUT_CELLPHONE_CANCEL',
    [191] = 'INPUT_FRONTEND_RDOWN', [194] = 'INPUT_FRONTEND_RRIGHT', [199] = 'INPUT_FRONTEND_PAUSE',
    [201] = 'INPUT_FRONTEND_ACCEPT', [202] = 'INPUT_FRONTEND_CANCEL', [203] = 'INPUT_FRONTEND_X',
    [204] = 'INPUT_FRONTEND_Y', [244] = 'INPUT_INTERACTION_MENU',
}

local PAD_MS = 250      -- how often the input device is asked again
local GLYPH_MS = 1000   -- how often the game is asked which input a control is on

local padNow, padAt = false, nil

--- Is a pad the active input? pfm-ui's answer when it is running (it watches for pad input), else
--- the game's own (IsUsingKeyboard false means the last input was a pad). Asked at most every PAD_MS.
---@param now number|nil  GetGameTimer
---@return boolean
function PromptKeys.padActive(now)
    now = now or GetGameTimer()
    if padAt ~= nil and now - padAt < PAD_MS then return padNow end
    padAt = now
    local answer = nil
    if GetResourceState('pfm-ui') == 'started' then
        local ok, v = pcall(function() return exports['pfm-ui']:IsPadActive() end)
        if ok and v ~= nil then answer = v == true end
    end
    if answer == nil then answer = not IsUsingKeyboard(0) end
    padNow = answer and true or false
    return padNow
end

--- Forget the cached device (tests, or a forced re-check).
function PromptKeys.reset()
    padAt = nil
    PromptKeys._glyphs = {}
end

PromptKeys._glyphs = {}   -- [control * 2 + (pad and 1 or 0)] = { at, glyph }

--- What the game reports for a control: ('t', 'E'), ('b', 'b_123') or nil.
local function instructional(control)
    local ok, s = pcall(GetControlInstructionalButton, 0, control, true)
    if not ok or type(s) ~= 'string' then return nil end
    local key = s:match('^t_(.+)$')
    if key then return 't', key end
    if s:match('^b_%d+$') then return 'b', s end
    return nil
end

--- The badge glyph for a control: a key's text on a keyboard, a pad_* glyph on a pad.
---@param control number  GTA control id
---@param keyLabel string|nil  the prompt's own key label (the keyboard fallback)
---@param pad boolean  PromptKeys.padActive()
---@param now number|nil
---@return string
function PromptKeys.glyph(control, keyLabel, pad, now)
    control = tonumber(control) or 38
    now = now or GetGameTimer()
    local slot = control * 2 + (pad and 1 or 0)
    local c = PromptKeys._glyphs[slot]
    if c and now - c.at < GLYPH_MS then return c.glyph end

    local glyph
    local kind, value = instructional(control)
    if pad then
        if kind == 'b' and (Config.PadButtonIds or {})[value] then
            glyph = Config.PadButtonIds[value]
        else
            glyph = PAD_DEFAULT[control] or 'pad_a'
        end
    else
        if kind == 't' and #value <= 6 then
            glyph = value:upper()
        else
            glyph = (type(keyLabel) == 'string' and keyLabel ~= '') and keyLabel:upper() or 'E'
        end
    end
    if c then c.at, c.glyph = now, glyph else PromptKeys._glyphs[slot] = { at = now, glyph = glyph } end
    return glyph
end

--- "~INPUT_PICKUP~" for the screen renderer, or nil for a control without a known name.
---@param control number
---@return string|nil
function PromptKeys.inputToken(control)
    local n = INPUT_NAME[tonumber(control) or 38]
    return n and ('~' .. n .. '~') or nil
end

--- The default pad glyph for a control (exposed for tests and the README table).
function PromptKeys.padDefault(control)
    return PAD_DEFAULT[tonumber(control) or -1]
end

-- /pfmprompts_glyph <control>: what the game reports for a control on the device in use, to fill in
-- Config.PadButtonIds when a pad button's glyph comes out wrong.
RegisterCommand('pfmprompts_glyph', function(_, args)
    local control = tonumber(args and args[1]) or 38
    local ok, s = pcall(GetControlInstructionalButton, 0, control, true)
    print(('[pfm-prompts] control %d: game reports %s (pad active: %s, badge shows %s)'):format(control,
        tostring(ok and s or '?'), tostring(PromptKeys.padActive()),
        PromptKeys.glyph(control, 'E', PromptKeys.padActive())))
end, false)
