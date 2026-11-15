-- pfm-prompts settings. The 'world' renderer's settings are ported from WHIP's Config.Interact3D:
-- Copyright (c) 2026 Whippy, from WHIP, LGPL-3.0; modified for PF.
Config = {}

-- How prompts are drawn:
--   'world'   textured quads in the world, sampled from three DUI atlases (badge, label, preview);
--             depth-tested (a wall hides them) and projected in the same frame as the camera.
--   'screen'  the fallback: 2D text and a key box at the projected point (SetDrawOrigin). Used
--             automatically when the game refuses the DUI textures.
-- The convar `pfm_prompts_renderer` (setr pfm_prompts_renderer screen) overrides this.
Config.Renderer = 'world'

-- Defaults for a prompt that does not say: the range its key works in, and the range it is drawn in.
Config.Distance = 2.0
Config.ShowDistance = 6.0
-- No prompt is drawn further than this, whatever it asks for (it is also the grid search radius).
Config.MaxShowDistance = 25.0

-- At most this many prompts are drawn at once (the nearest win).
Config.MaxDrawn = 24

-- Scoring (what is in range, what is focused) runs about this often while prompts are near, in ms.
-- Drawing runs every frame. With nothing near, the loop sleeps IdleMs between checks.
Config.ScoreMs = 66
Config.IdleMs = 250

-- Focus: of the prompts in reach, the one nearest the middle of the screen inside this cone
-- (half-angle, degrees) wins; with none inside it, the nearest in reach that is not behind you
-- (inside FocusConeNear) wins.
Config.FocusCone = 30.0
Config.FocusConeNear = 100.0

-- Which prompts show their words: 'focused' (the one the key acts on, plus in-reach prompts with
-- nothing to press, such as a door the player cannot unlock), or 'active' (every prompt in reach,
-- nearest first, as many as there are label rows).
Config.Labels = 'focused'

-- Cycling a prompt's options: the mouse wheel (16 next, 17 previous, as WHIP) and, on a pad, the
-- D-pad (173 down = next, 172 up = previous). The weapon wheel controls are held off meanwhile.
Config.ScrollControls = { next = 16, prev = 17 }
Config.PadScrollControls = { next = 173, prev = 172 }

-- Pad glyphs. The badge asks the game (GetControlInstructionalButton) which button a control is on.
-- A keyboard key comes back as text ('t_E') and is shown as it is. A pad button comes back as a
-- button id ('b_NNN'): ids listed here pick the glyph; any other falls back to GTA's default pad layout
-- for that control (client/keys.lua). /pfmprompts_glyph <control> prints what the game reports.
-- Glyphs: pad_a pad_b pad_x pad_y pad_lb pad_rb pad_lt pad_rt pad_l3 pad_r3 pad_up pad_down
-- pad_left pad_right pad_start pad_back.
Config.PadButtonIds = {
    -- ['b_NNN'] = 'pad_lb',
}

-- Colours: neutral, for a dark UI. Badge colours are CSS colours (#rrggbb or rgba()).
Config.Colors = {
    key = '#ffffff',                    -- the focused disc
    ink = 'rgb(15, 17, 21)',            -- the key's glyph on it, and the dark grounds
    ring = 'rgba(255, 255, 255, 0.95)', -- an in-reach ring
    ringDim = 'rgba(255, 255, 255, 0.55)', -- a distant ring
    ground = 'rgba(15, 17, 21, 0.55)',  -- inside a ring
    info = 'rgba(27, 31, 38, 0.92)',    -- the disc of a prompt with nothing to press
    infoInk = '#e6e8ec',                -- its icon
    label = '#ffffff',                  -- the action ("Unlock")
    sublabel = '#b4bac6',               -- the sublabel ("Locked")
    holdFill = { 230, 232, 236 },       -- the hold ring (r, g, b)
}

-- The 'world' renderer.
Config.World = {
    -- The badge's height on screen in pixels (at 1440p), when the prompt is at its own Distance. Its
    -- size in metres follows from the real FOV. Past that it shrinks like any object.
    badgePx = 62,
    -- The label row's height on screen, same units. Its width follows the atlas row's proportions.
    labelPx = 88,
    -- State the badge size in metres outright instead. nil = work it out.
    badgeMetres = nil,
    -- Space between badge and label, as a fraction of the badge's height.
    gap = 0.35,
    -- How long every transition takes (fades, crossfade between states, the option stack), in ms.
    fadeMs = 110,
    -- How many label rows the atlas holds (only prompts showing words take one).
    labelRows = 8,
    -- How far a prompt is pulled toward the camera so the door or prop it labels does not cover it,
    -- in metres. Capped at half the distance to the camera.
    depthBias = 0.30,
    -- A prompt with several options draws them as a column: the gap, and how visible the others are.
    stackGap = 0.25,
    stackAlpha = 0.45,
    -- An option's picture (`image`): its height as a multiple of the label's.
    previewScale = 3.4,
    -- The badge's shape: 'keycap' (rounded square) or 'classic' (disc); dark swaps black and white.
    theme = 'keycap',
    dark = false,
    -- Opacity in each state: seen (in sight, too far) / in reach / focused.
    opacity = { seen = 0.35, inReach = 0.85, focused = 1.0 },
    -- How long a Flash() lasts, in ms.
    flashMs = 900,
}

-- The 'screen' (fallback) renderer.
Config.Screen = {
    font = 4,
    textScale = 0.36,
    sublabelScale = 0.30,
    keyBox = { w = 0.018, h = 0.03 },   -- the key box, screen fractions
    -- Prompts beyond reach are drawn as a small dot.
    dotSize = 0.006,
}
