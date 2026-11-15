// Copyright (c) 2026 Whippy, from WHIP, LGPL-3.0; modified for PF.
// ========================================
// MAIN — the page's one module entry: the small local stand-in for the original's single-page set-up
// (main.js's two listeners, controller.js's hint strip and scope reports, utils.js's --ui-scale).
//
//   * --ui-scale: the window's height over 1440 (the sheets zoom their pages by it).
//   * Lua's messages: dispatched to the modules that registered them (router.js). 'pad' is a controller intent
//     (client/main.lua reads the pad), 'padAnalog' the sticks and triggers on the map, 'device' which one the
//     player holds (html[data-input] = 'pad' | 'kbm').
//   * Keys: every keydown to the top scope (the pause menu's).
//   * The scope's wish for the sticks as numbers is told to Lua ('navScope'), and on a pad the hint strip says
//     which buttons do what.
// ========================================

import { NuiRouter } from './router.js';
import { nuiCallback } from './utils.js';
import { padGlyph } from './pad-glyphs.js';
import './prefs.js';
import './pause.js';

function applyScale() {
    document.documentElement.style.setProperty('--ui-scale', String(window.innerHeight / 1440));
}
applyScale();
window.addEventListener('resize', applyScale);

function setDevice(pad) {
    document.documentElement.dataset.input = pad ? 'pad' : 'kbm';
    drawPadHints();
}
if (!document.documentElement.dataset.input) document.documentElement.dataset.input = 'kbm';

window.addEventListener('message', (event) => {
    const d = event.data;
    if (!d || typeof d !== 'object' || typeof d.action !== 'string') return;
    if (d.action === 'pad') {
        if (typeof d.intent === 'string') NuiRouter.handleNav(d.intent, {});
        drawPadHints();
        return;
    }
    if (d.action === 'padAnalog') {
        NuiRouter.handleAnalog({ x: +d.x || 0, y: +d.y || 0, lt: +d.lt || 0, rt: +d.rt || 0, rx: +d.rx || 0, ry: +d.ry || 0 });
        return;
    }
    if (d.action === 'device') { setDevice(d.pad === true); return; }
    if (d.action === 'pauseOpen' && typeof d.pad === 'boolean') setDevice(d.pad);
    NuiRouter.dispatch(d);
    drawPadHints();
});

document.addEventListener('keydown', (e) => {
    NuiRouter.handleKey(e);
    drawPadHints();
});

// ---- the scope, told to Lua: does it want the sticks as numbers (the map)? ----

NuiRouter.onNavScopeChange((name, analog) => {
    nuiCallback('navScope', { scope: name, analog: !!analog });
    drawPadHints();
});

// ---- the hint strip ----

const hintStrip = document.createElement('div');
hintStrip.id = 'pad-hints';
document.body.appendChild(hintStrip);
let shownHints = '';

function drawPadHints() {
    const hints = NuiRouter.activeNavHints() || [];
    const sig = JSON.stringify(hints);
    if (sig === shownHints) return;
    shownHints = sig;
    hintStrip.textContent = '';
    // A hint's button may be a list, for a button held under another: [['lb', 'a'], 'Something'].
    for (const [button, label] of hints) {
        const imgs = (Array.isArray(button) ? button : [button])
            .map((name) => padGlyph(name, 'pad-hint-glyph')).filter(Boolean);
        if (!imgs.length) continue;
        const item = document.createElement('span');
        item.className = 'pad-hint';
        for (const img of imgs) item.appendChild(img);
        item.appendChild(document.createTextNode(label));
        hintStrip.appendChild(item);
    }
    hintStrip.classList.toggle('visible', hintStrip.childElementCount > 0);
}

NuiRouter.onHintsChange(drawPadHints);
