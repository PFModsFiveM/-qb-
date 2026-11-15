// Copyright (c) 2026 Whippy, from WHIP, LGPL-3.0; modified for PF.
// ========================================
// PLAYER PREFERENCES THE PAGE READS ITSELF (pfm-ui's registry, through client/main.lua)
//
// Each player's own choices live in Lua and are changed on the pause menu's Settings page, under Server
// (settings-page.js). The few the page itself acts on — those declared with `page = true`, such as the menu
// cursor's speed — arrive here ('playerPrefs': at start, at playerLoaded, and whenever one changes).
//
//     import { pref } from './prefs.js';
//     const speed = BASE * pref('pad.cursorSpeed', 100) / 100;   // read when used: a change applies at once
// ========================================

import { NuiRouter } from './router.js';

const values = {};
const listeners = [];

function changed() {
    for (const fn of listeners) {
        try { fn(); } catch (e) { console.error('[prefs] onPrefs:', e); }
    }
}

NuiRouter.register('playerPrefs', (d) => {
    if (d && d.values && typeof d.values === 'object') Object.assign(values, d.values);
    changed();
});

/** A preference's value, or `fallback` until Lua has said. */
export function pref(key, fallback) {
    const v = values[key];
    return v === undefined || v === null ? fallback : v;
}

/** The page's own guess at a value, until Lua's answer replaces it: the Settings page's Server rows, while a slider is dragged
 *  or a change is on its way, so what reads it (the minimap's preview) follows at once. */
export function setPref(key, value) {
    values[key] = value;
    changed();
}

/** fn() whenever a value may have changed. */
export function onPrefs(fn) {
    if (typeof fn === 'function') listeners.push(fn);
}
