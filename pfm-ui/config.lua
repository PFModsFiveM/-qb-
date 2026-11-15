-- pfm-ui settings. The controller parts are ported from WHIP (Copyright (c) 2026 Whippy, LGPL-3.0;
-- modified for PF). See NOTICE.md.

Config = Config or {}

Config.Pad = {
    -- Controller support on or off for everyone (a player can also turn it off: /padset pad.enabled false).
    Enabled = true,

    -- How long the device must stay the same before pfm-ui says it changed (ms). A hand on the mouse
    -- while the other holds a pad makes the answer flap; this damps the broadcast, not the reads.
    SettleMs = 300,

    -- Menus: a held direction fires once, waits RepeatDelayMs, then repeats every RepeatRateMs.
    RepeatDelayMs = 380,
    RepeatRateMs = 110,

    -- What each button does outside menus. Players can change their own (/padbind <slot> <action>).
    -- Slots: dpad_up, dpad_down, dpad_left, dpad_right, lb (runs while LB is held),
    --        lb_a, lb_b, lb_x, lb_y, lb_dpad_up, lb_dpad_down, lb_dpad_left, lb_dpad_right (LB + button).
    -- Actions: radial, inventory, target, phone, menufocus, emotes, or one another resource registers
    -- with exports['pfm-ui']:RegisterPadAction. false leaves the button to GTA (or to a resource that asks).
    Layout = {
        dpad_up       = 'phone',
        dpad_down     = 'radial',
        dpad_left     = 'menufocus',
        dpad_right    = 'inventory',
        lb            = 'target',
        lb_a          = false,      -- kept free: A opens the target menu while LB is held
        lb_b          = false,
        lb_x          = false,
        lb_y          = 'emotes',
        lb_dpad_up    = false,
        lb_dpad_down  = false,
        lb_dpad_left  = false,
        lb_dpad_right = false,
    },
}

-- Player settings the server decides for everyone: { ['pad.enabled'] = false }. A forced setting
-- cannot be changed by players; their own choice is kept for when it is no longer forced.
-- The replicated convar does the same without editing this file:
--     setr pfm_ui_forced "pad.enabled=false,pad.repeatDelay=300"
Config.ForcedPrefs = {}
