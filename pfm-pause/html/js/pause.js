// Copyright (c) 2026 Whippy, from WHIP, LGPL-3.0; modified for PF.
// ========================================
// PAUSE MENU — in place of GTA's (client/main.lua)
//
// Left: the brand mark with its loading light, then Resume / Map / Controller / Swap Character /
// Game Settings / Server Settings / Help / Quit, and where the player is. Game Settings opens GTA's own settings menu
// in the pause menu's place; Server Settings slides the menu away for the Settings page (settings-page.js) with this
// server's settings (pfm-ui's), as Controller (pad-layout.js) and Help (help-page.js, PF's own) do.
// Behind it, filling the screen, the map — centred on the
// player in the middle of the screen. Map slides the menu away and makes the map live: drag, zoom,
// double-click for a waypoint, a legend. Controller slides it away too and hides the map for the
// controller screen (pad-layout.js). Swap Character and Quit
// ask first. The map is 3D (pause-map.js): on the map V or a pad's LB tilts it, and a right-drag or the right
// stick turns and tilts it; back to the menu it is flat again.
//
// Keyboard, mouse and pad all drive it: keys through the scope's onKey, the pad through onNav (client/main.lua
// sends intents), the mouse on the elements themselves. On the map a pad's left stick pans, its
// triggers zoom and its right stick turns, smoothly, through onAnalog.
//
// PF: the menu's items come from Lua with each open (an item may be off, with a note: Swap Character with no
// character screen). Swap Character and Quit ask Lua first: its answer carries a one-time token, and only a
// confirm with that token does it (client/main.lua). The logo is our own mark (logo-light.js brandMarkup).
// ========================================

import { NuiRouter } from './router.js';
import { nuiCallback } from './utils.js';
import { PauseMap } from './pause-map.js';
import { BLIP_NAMES } from './blip-names.js';
import { brandMarkup, logoLight } from './logo-light.js';
import { PadLayout } from './pad-layout.js';
import { SettingsPage } from './settings-page.js';
import { HelpPage } from './help-page.js';

// The menu, until Lua sends this server's (pauseOpen: Config.Pause.Menu, with the items it cannot offer marked off).
const MENU_DEFAULT = [
    { id: 'resume', label: 'Resume' },
    { id: 'map', label: 'Map' },
    { id: 'controller', label: 'Controller' },
    { id: 'swap', label: 'Swap Character' },
    { id: 'gameSettings', label: 'Game Settings' },
    { id: 'serverSettings', label: 'Server Settings' },
    { id: 'help', label: 'Help' },
    { id: 'quit', label: 'Quit' },
];

/** The questions asked before something that cannot be taken back. `mode`: what Lua is asked to do (client/main.lua
 *  'leave'). Quit leaves the server, or with Config.Pause.QuitMode = 'quit' closes the game. */
const CONFIRMS = {
    swap: { q: 'Are you sure you wish to swap characters?', sub: 'You will go back to the character screen.',
        yes: 'Swap', mode: 'swap', danger: false },
    quit: { q: 'Leave the server?', sub: "You will go back to FiveM's server list.",
        yes: 'Leave', mode: 'disconnect', danger: true },
    quitGame: { q: 'Quit the game?', sub: 'GTA V closes.', yes: 'Quit', mode: 'quit', danger: true },
};

// The map behind the menu: 4.3, then 35% closer and 25% closer twice more. Zoom doubles per level, so
// each "x% closer" adds log2(1 + x): about 5.38, closer than the map's own opening zoom.
const PREVIEW_ZOOM = 4.3 + Math.log2(1.35) + 2 * Math.log2(1.25);
const MAP_ZOOM = 4.6;       // the map on its own, on opening
const GLIDE_MS = 380;       // the menu sliding away, and the map's centre with it
const PAN_STEP = 150;       // px per arrow key / D-pad press
const STICK_PAN = 1300;     // px a second with the stick all the way over (half way is a quarter of it)
const TRIGGER_ZOOM = 2.4;   // zoom levels a second with a trigger pulled all the way (likewise)
const STICK_TURN = 120;     // degrees a second the right stick turns the map, all the way over (likewise)
const STICK_TILT = 60;      // ...and tilts it, up toward the horizon
// Blip snapping on a pad, as GTA's map does: the centre this near a blip is on it — the blip is
// picked, the stick slows over it, and let go there the map slides it to the middle.
const SNAP_R = 20;          // px
const SNAP_SLOW = 0.45;     // the stick's speed while on one
const SNAP_MS = 160;        // the slide

// ---- the page ----

const root = document.createElement('div');
root.id = 'pause';
root.innerHTML = `
    <section class="pm-mapwrap">
        <div class="pm-map"></div>
        <button class="pm-back" type="button"><span class="pm-back-arrow">&#8592;</span> Menu</button>
        <aside class="pm-legend"><div class="pm-legend-head">Legend</div><div class="pm-legend-list"></div></aside>
        <div class="pm-keys">
            <span><b>Drag</b> Move</span><span><b>Scroll</b> Zoom</span><span><b>Double-click</b> Waypoint</span>
            <span><b>V</b> 3D</span><span><b>Right-drag</b> Turn</span>
            <span><b>C</b> Centre</span><span><b>L</b> Legend</span><span><b>Esc</b> Back</span>
        </div>
    </section>
    <aside class="pm-side">
        <div class="pm-logo" role="img" aria-label="PF">${brandMarkup('pm-clip', 'PF')}</div>
        <nav class="pm-menu"></nav>
        <div class="pm-note"></div>
        <div class="pm-confirm">
            <p class="pm-confirm-q"></p>
            <p class="pm-confirm-sub"></p>
            <div class="pm-confirm-row"><button class="pm-btn" data-c="0"></button><button class="pm-btn" data-c="1">Stay</button></div>
        </div>
        <div class="pm-where"><div class="pm-char"></div><div class="pm-zone"></div><div class="pm-street"></div></div>
    </aside>`;
document.body.appendChild(root);

const menuEl = root.querySelector('.pm-menu');
const confirmBtns = [...root.querySelectorAll('.pm-confirm .pm-btn')];
const confirmQ = root.querySelector('.pm-confirm-q');
const confirmSub = root.querySelector('.pm-confirm-sub');
const zoneEl = root.querySelector('.pm-zone');
const streetEl = root.querySelector('.pm-street');
const legendEl = root.querySelector('.pm-legend');
const legendList = root.querySelector('.pm-legend-list');
const noteEl = root.querySelector('.pm-note');
const charEl = root.querySelector('.pm-char');
const logoEl = root.querySelector('.pm-logo');
const confirmYes = confirmBtns[0];

const map = new PauseMap(root.querySelector('.pm-map'));
map.turnable = true;      // this one turns and tilts (V, a right-drag, LB and the right stick)
let light = logoLight(logoEl);
let brand = 'PF';
const padScreen = new PadLayout(root, () => setMode('menu'));
const settingsScreen = new SettingsPage(root, () => setMode('menu'));
const helpScreen = new HelpPage(root, () => setMode('menu'), (id) => nuiCallback('quick', { id }));
let helpData = {};         // rules, keys, shortcuts, report (pauseOpen)

let open = false;
let mode = 'menu';        // 'menu' | 'confirm' | 'map' | 'pad' (the controller screen) | 'settings' | 'help'
let combined = false;     // a Combined Settings page: never in PF (the Game tabs need GTA's own page under it)
let menu = MENU_DEFAULT;  // the menu's items (pauseOpen)
let quitMode = 'disconnect';
let token = null;         // the one-time token Lua gave with the question up now
let items = [];           // their buttons
let sel = 0;              // the menu's highlighted item
let asking = null;        // which CONFIRMS entry the question is
let confirmSel = 1;       // Stay, by default
let legendOpen = false;
let centred = false;      // the map has found the player once since opening
let picked = null;        // the blip ringed on the map and lit in the legend
const cycle = new Map();  // legend group -> which of its blips the last click went to

/** Where the map's centre sits: the middle of the screen, or of what the legend leaves showing.
 *  ONLY THE LEGEND MOVES IT: the player stays in the middle of the screen behind the menu, so going to
 *  the map does not slide it across. */
const mapOffset = () => legendOpen ? -legendEl.getBoundingClientRect().width / 2 : 0;

const onPad = () => document.documentElement.dataset.input === 'pad';

// ---- modes ----

function setMode(m, instant) {
    const was = mode;
    mode = m;
    root.dataset.mode = m;
    map.setInteractive(m === 'map');
    map.setFollow(m !== 'map');   // the menu's map rides with the player; the live map is the player's to move
    map.setHidden(m === 'pad' || m === 'settings' || m === 'help');   // out of sight there: the 3D map is the minimap preview's (settings-page.js)
    if (m === 'map') {
        setLegend(false, false);  // hidden until asked for: L or a pad's Y
        map.glide(mapOffset(), MAP_ZOOM, GLIDE_MS);
    } else {
        setLegend(false, false);
        pick(null);
        map.drive(0, 0, 0);
        if (was === 'map' || instant) {
            map.setTilt(false, instant);   // the menu's map is the flat one
            map.centreOnPlayer();
            if (instant) { map.offsetX = 0; map.zoom = PREVIEW_ZOOM; map.render(); }
            else map.glide(0, PREVIEW_ZOOM, GLIDE_MS);
        }
    }
    if (m === 'confirm') drawConfirm();
    if (m === 'pad') padScreen.open();
    else if (was === 'pad') padScreen.close();
    if (m === 'settings') settingsScreen.open({ game: combined });
    else if (was === 'settings') settingsScreen.close();
    if (m === 'help') helpScreen.open(helpData);
    else if (was === 'help') helpScreen.close();
    if (m !== 'confirm' && was === 'confirm' && token) { nuiCallback('leaveCancel', {}); token = null; }
    drawMenu();
    NuiRouter.syncNavScope(true);   // the stick is numbers on the map and directions in the menu: tell Lua now
}

/** The menu's buttons, for the items `combined` asks for. */
function buildMenu(list) {
    menu = Array.isArray(list) && list.length ? list : MENU_DEFAULT;
    menuEl.innerHTML = menu.map((it, i) => `<button class="pm-item${it.disabled ? ' pm-item-off' : ''}" data-i="${i}">${escapeText(it.label)}</button>`).join('');
    items = [...menuEl.querySelectorAll('.pm-item')];
    root.classList.toggle('pm-long', menu.length > 7);   // PF: eight items fit the original's height (pause.css)
}

function drawMenu() {
    items.forEach((el, i) => el.classList.toggle('on', i === sel));
    const it = menu[sel];
    noteEl.textContent = it && it.disabled && it.note ? it.note : '';
}

function escapeText(t) {
    return String(t == null ? '' : t).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function ask(id) {
    asking = CONFIRMS[id === 'quit' && quitMode === 'quit' ? 'quitGame' : id];
    confirmSel = 1;
    token = null;
    confirmQ.textContent = asking.q;
    confirmSub.textContent = asking.sub;
    confirmYes.textContent = asking.yes;
    confirmYes.classList.toggle('pm-btn-danger', asking.danger);
    confirmYes.disabled = true;   // until Lua has answered with its token
    setMode('confirm');
    const q = asking;
    nuiCallback('leave', { mode: q.mode }).then((r) => {
        if (mode !== 'confirm' || asking !== q) return;
        if (r && r.ok && r.token) { token = r.token; confirmYes.disabled = false; }
        else confirmSub.textContent = (r && r.why) || 'Not possible right now.';
    });
}

function drawConfirm() {
    confirmBtns.forEach((el, i) => el.classList.toggle('on', i === confirmSel));
}

function choose(i) {
    const it = menu[i];
    if (!it || it.disabled) return;
    const id = it.id;
    if (id === 'resume') nuiCallback('pauseResume', {});
    else if (id === 'map') setMode('map');
    else if (id === 'controller') setMode('pad');
    else if (id === 'help') setMode('help');
    else if (id === 'settings' || id === 'serverSettings') setMode('settings');
    else if (id === 'gameSettings') nuiCallback('pauseSettings', {});   // GTA's own, in the pause menu's place
    else if (CONFIRMS[id]) ask(id);
}

function answerConfirm(i) {
    if (i === 0 && asking) {
        if (!token) return;   // Lua has not answered (or said no)
        const t = token;
        token = null;
        nuiCallback('leaveConfirm', { token: t });
    } else setMode('menu');
}

// ---- legend ----

/** Friendlier names than the sprite's for the common unnamed ones (FiveM's list calls a gas
 *  station a "jerry can" and a store "crim holdups"). */
const COMMON = { 52: 'Store', 361: 'Gas station', 75: 'Tattoo parlour' };

const nameOf = (b) => b.name || COMMON[b.sprite] || BLIP_NAMES[b.sprite] || ('Blip ' + b.sprite);
const keyOf = (b) => nameOf(b) + '|' + b.sprite + '|' + b.colour;

function groupsOf(blips) {
    const groups = new Map();
    for (const b of blips) {
        const key = keyOf(b);
        let g = groups.get(key);
        if (!g) { g = { key, name: nameOf(b), sprite: b.sprite, colour: b.colour, blips: [] }; groups.set(key, g); }
        g.blips.push(b);
    }
    return [...groups.values()].sort((a, b) => a.name.localeCompare(b.name));
}

function drawLegend() {
    legendList.textContent = '';
    const groups = groupsOf(map.data.blips);
    if (!groups.length) {
        legendList.innerHTML = '<div class="pm-legend-empty">Nothing on the map</div>';
        return;
    }
    for (const g of groups) {
        const row = document.createElement('button');
        row.className = 'pm-legend-row';
        row.dataset.key = g.key;
        const icon = map.blipImage(g.sprite, g.colour);
        icon.className = 'pm-legend-icon' + (icon.classList.contains('pmap-dot') ? ' pmap-dot' : '');
        const name = document.createElement('span');
        name.className = 'pm-legend-name';
        const label = document.createElement('span');
        label.className = 'pm-legend-label';
        label.textContent = g.name;
        name.appendChild(label);
        row.append(icon, name);
        if (g.blips.length > 1) {
            const n = document.createElement('span');
            n.className = 'pm-legend-count';
            n.textContent = g.blips.length;
            row.appendChild(n);
        }
        // Each click goes to the next one of that kind.
        row.addEventListener('click', () => {
            const at = ((cycle.get(g.key) ?? -1) + 1) % g.blips.length;
            cycle.set(g.key, at);
            pick(g.blips[at], { slide: true });
            if (map.zoom < 4.6) map.glide(mapOffset(), 4.6, GLIDE_MS);
        });
        legendList.appendChild(row);
    }
    markLegend();
}

/** Light the picked blip's row, scrolled into view. Not scrollIntoView: that would also scroll the
 *  map's box, which hides the legend off its edge. */
function markLegend() {
    const key = picked ? keyOf(picked) : null;
    for (const row of legendList.children) {
        const on = !!key && row.dataset.key === key;
        row.classList.toggle('on', on);
        if (!on) continue;
        const top = row.offsetTop, bottom = top + row.offsetHeight;
        if (top < legendList.scrollTop) legendList.scrollTop = top;
        else if (bottom > legendList.scrollTop + legendList.clientHeight) legendList.scrollTop = bottom - legendList.clientHeight;
    }
}

/** Show or hide the legend; on the map, the centre slides to the middle of what it leaves showing. */
function setLegend(on, glide = true) {
    legendOpen = !!on;
    root.classList.toggle('pm-legend-open', legendOpen);
    if (legendOpen) drawLegend();
    if (glide && mode === 'map') map.glide(mapOffset(), undefined, GLIDE_MS);
}

// ---- picking a blip ----

/** Ring a blip on the map and light its row in the legend; or none. `slide` brings it to the middle,
 *  `reveal` opens the legend to show it. */
function pick(b, how) {
    picked = b || null;
    map.setPicked(picked);
    if (picked && how && how.slide) map.slideTo(picked.x, picked.y, SNAP_MS);
    if (picked && how && how.reveal && !legendOpen) setLegend(true);   // which marks it
    else markLegend();
}

/** A pad's centre over a blip picks it, and slows the stick (pause-map.js drive). */
map.onMove = () => {
    if (mode !== 'map' || !onPad()) return 1;
    const [mx, my] = map.middle();
    const b = map.blipNear(mx, my, SNAP_R);
    if (b !== picked) pick(b);
    return b ? SNAP_SLOW : 1;
};

/** The map stopped moving under a pad: on a blip, it slides to the middle. */
function settle() {
    if (mode !== 'map' || !onPad()) return;
    const [mx, my] = map.middle();
    const b = map.blipNear(mx, my, SNAP_R);
    pick(b, { slide: !!b });
}
map.onSettle = settle;

/** A click on a blip: it comes to the middle, lit in the legend. From the menu, the map opens. */
map.onBlipClick = (b) => {
    if (mode !== 'map') setMode('map');
    pick(b, { slide: true, reveal: true });
};

// ---- mouse ----

// On the menu, not each button: they are made again at each open (buildMenu).
menuEl.addEventListener('mouseover', (e) => {
    const el = e.target.closest('.pm-item');
    if (el && mode === 'menu') { sel = Number(el.dataset.i); drawMenu(); }
});
menuEl.addEventListener('click', (e) => {
    const el = e.target.closest('.pm-item');
    if (el && mode === 'menu') { sel = Number(el.dataset.i); choose(sel); }
});
confirmBtns.forEach((el, i) => {
    el.addEventListener('mouseenter', () => { confirmSel = i; drawConfirm(); });
    el.addEventListener('click', () => answerConfirm(i));
});
root.querySelector('.pm-back').addEventListener('click', () => setMode('menu'));
// NO BUTTON HERE TAKES THE KEYBOARD'S FOCUS: a focused button (even hidden) would be pressed again by the next Enter
// or Space as well as the key scope's own action. The keys are the scope's (onKey); a click still clicks.
root.addEventListener('mousedown', (e) => { if (e.target.closest('button')) e.preventDefault(); });
// The map beside the menu is a door to the map.
root.querySelector('.pm-mapwrap').addEventListener('click', () => { if (mode === 'menu') setMode('map'); });

map.onWaypoint = (x, y) => nuiCallback('pauseWaypoint', x === null ? { clear: true } : { x, y });

// ---- keys and the pad ----

function mapKey(e) {
    const k = e.key.toLowerCase();
    // One press back to the menu, legend open or not; L and Y show and hide the legend.
    if (k === 'escape' || k === 'backspace') { setMode('menu'); return; }
    if (k === 'arrowleft' || k === 'a') map.panBy(PAN_STEP, 0);
    else if (k === 'arrowright' || k === 'd') map.panBy(-PAN_STEP, 0);
    else if (k === 'arrowup' || k === 'w') map.panBy(0, PAN_STEP);
    else if (k === 'arrowdown' || k === 's') map.panBy(0, -PAN_STEP);
    else if (k === '+' || k === '=' || k === 'e') map.zoomBy(0.5);
    else if (k === '-' || k === 'q') map.zoomBy(-0.5);
    else if (k === 'c') map.centreOnPlayer();
    else if (k === 'v') map.setTilt(!map.tilted());
    else if (k === 'l') setLegend(!legendOpen);
    else if (k === 'delete' && map.data.waypoint) { map.data.waypoint = null; map.data.route = null; map.render(); map.onWaypoint(null); }
}

NuiRouter.registerKeyScope({
    name: 'pause',
    priority: 4,
    isOpen: () => open,
    onKey: (e) => {
        if (e.type && e.type !== 'keydown') return;
        if (mode === 'map') { mapKey(e); return; }
        if (mode === 'pad') { if (!padScreen.onKey(e)) setMode('menu'); return; }
        if (mode === 'settings') { if (!settingsScreen.onKey(e)) setMode('menu'); return; }
        if (mode === 'help') { if (!helpScreen.onKey(e)) setMode('menu'); return; }
        const k = e.key.toLowerCase();
        if (mode === 'confirm') {
            if (k === 'arrowleft' || k === 'arrowright' || k === 'tab') { confirmSel = 1 - confirmSel; drawConfirm(); e.preventDefault(); }
            else if (k === 'enter' || k === ' ') answerConfirm(confirmSel);
            else if (k === 'escape') setMode('menu');
            return;
        }
        if (k === 'arrowup' || k === 'w') { sel = (sel + menu.length - 1) % menu.length; drawMenu(); }
        else if (k === 'arrowdown' || k === 's') { sel = (sel + 1) % menu.length; drawMenu(); }
        else if (k === 'enter' || k === ' ') choose(sel);
        else if (k === 'escape') nuiCallback('pauseResume', {});
        else if (k === 'm') setMode('map');
    },
    onNav: (nav) => {
        if (mode === 'pad') { if (!padScreen.nav(nav)) setMode('menu'); return; }
        if (mode === 'settings') { if (!settingsScreen.nav(nav)) setMode('menu'); return; }
        if (mode === 'help') { if (!helpScreen.nav(nav)) setMode('menu'); return; }
        if (mode === 'map') {
            if (nav === 'back') setMode('menu');
            else if (nav === 'left') { map.panBy(PAN_STEP, 0); settle(); }
            else if (nav === 'right') { map.panBy(-PAN_STEP, 0); settle(); }
            else if (nav === 'up') { map.panBy(0, PAN_STEP); settle(); }
            else if (nav === 'down') { map.panBy(0, -PAN_STEP); settle(); }
            else if (nav === 'tabPrev') map.setTilt(!map.tilted());   // LB: 3D and back (LT zooms out)
            else if (nav === 'tabNext') { map.zoomBy(0.5); settle(); }
            else if (nav === 'select') {
                // On a picked blip, the waypoint goes on it, even mid-slide.
                const [sx, sy] = picked ? map.screenOf(picked.x, picked.y) : map.middle();
                map.waypointAt(sx, sy);
            }
            else if (nav === 'buttonX') map.centreOnPlayer();
            else if (nav === 'buttonY') setLegend(!legendOpen);
            return;
        }
        if (mode === 'confirm') {
            if (nav === 'left' || nav === 'right') { confirmSel = 1 - confirmSel; drawConfirm(); }
            else if (nav === 'select') answerConfirm(confirmSel);
            else if (nav === 'back') setMode('menu');
            return;
        }
        if (nav === 'up') { sel = (sel + menu.length - 1) % menu.length; drawMenu(); }
        else if (nav === 'down') { sel = (sel + 1) % menu.length; drawMenu(); }
        else if (nav === 'select') choose(sel);
        else if (nav === 'back') nuiCallback('pauseResume', {});
    },
    // On the map the sticks and triggers come as numbers (router.js activeNavAnalog): the further they
    // go, the faster — squared, so a light touch is fine control. The right stick turns (as a right-drag does)
    // and, pushed up, tilts toward the horizon.
    analog: () => mode === 'map',
    onAnalog: (a) => {
        if (mode !== 'map') { map.drive(0, 0, 0); return; }
        const pan = Math.hypot(a.x, a.y) * STICK_PAN;
        const rx = a.rx || 0, ry = a.ry || 0;
        map.drive(a.x * pan, -a.y * pan, (a.rt * a.rt - a.lt * a.lt) * TRIGGER_ZOOM,
            -rx * Math.abs(rx) * STICK_TURN, -ry * Math.abs(ry) * STICK_TILT);
    },
    // The hint strip on a pad (main.js).
    padHints: () => {
        if (mode === 'pad') return padScreen.hints();
        if (mode === 'settings') return settingsScreen.hints();
        if (mode === 'help') return helpScreen.hints();
        if (mode === 'map') {
            return [['ls', 'Move'], ['lt', 'Zoom out'], ['rt', 'Zoom in'], ['rs', 'Turn'], ['lb', '3D'], ['a', 'Waypoint'],
                ['x', 'Centre'], ['y', 'Legend'], ['b', 'Back']];
        }
        if (mode === 'confirm') return [['dpad', 'Choose'], ['a', 'Select'], ['b', 'Back']];
        return [['dpad', 'Choose'], ['a', 'Select'], ['b', 'Resume']];
    },
});

// ---- messages ----

NuiRouter.register('pauseOpen', (d) => {
    open = true;
    centred = false;
    combined = false;
    quitMode = d && d.quitMode === 'quit' ? 'quit' : 'disconnect';
    helpData = (d && d.help) || {};
    setBrand(d && d.brand);
    setCharacter(d && d.character);
    buildMenu(d && d.menu);
    sel = 0;
    root.classList.add('open');
    light.start();
    // Laid out first (display: flex), so the menu's width is known when the map is placed.
    requestAnimationFrame(() => setMode('menu', true));
});

NuiRouter.register('pauseClose', () => {
    open = false;
    root.classList.remove('open');
    light.stop();
    map.drive(0, 0, 0);
    PauseMap.release();   // the 3D map's full-screen buffers go until it is opened again
    padScreen.close();
    settingsScreen.close();
    helpScreen.close();
    token = null;
    pick(null);
    setLegend(false);
    mode = 'menu';
    root.dataset.mode = 'menu';
});

NuiRouter.register('pauseData', (d) => {
    map.setData(d);
    // New blips are new objects: the picked one is found again among them, or is gone.
    if (picked && d.blips) {
        const p = picked;
        picked = d.blips.find((b) => b.sprite === p.sprite && b.colour === p.colour
            && Math.abs(b.x - p.x) < 2 && Math.abs(b.y - p.y) < 2) || null;
        map.setPicked(picked);   // the legend below is redrawn with it
    }
    if (d.player) {
        zoneEl.textContent = d.player.zone || '';
        streetEl.textContent = d.player.street || '';
        // The menu's map follows the player — glided, frame by frame (pause-map.js follow); the live map
        // stays where it was put. Only the first reading centres it outright.
        if (!centred) {
            map.offsetX = mode === 'map' ? mapOffset() : 0;
            map.centreOnPlayer(mode === 'map' ? MAP_ZOOM : PREVIEW_ZOOM);
        }
        centred = true;
    }
    if (d.blips && legendOpen) drawLegend();
});

// The character changed while open (a job, duty).
NuiRouter.register('pauseCharacter', (d) => setCharacter(d && d.character));

// The help page's shortcuts changed (a resource added or removed one).
NuiRouter.register('pauseHelp', (d) => { helpData = (d && d.help) || helpData; if (mode === 'help') helpScreen.open(helpData, helpScreen.tabKey); });

/** The brand mark (Config.Pause.Brand), drawn again only when it changes. */
function setBrand(b) {
    const next = typeof b === 'string' && b.trim() ? b.trim().slice(0, 24) : 'PF';
    if (next === brand) return;
    brand = next;
    light.stop();
    logoEl.innerHTML = brandMarkup('pm-clip', brand);
    logoEl.setAttribute('aria-label', brand);
    light = logoLight(logoEl);
}

/** The character over where the player is: name, and job when there is one. */
function setCharacter(c) {
    charEl.textContent = '';
    if (!c || !c.name) return;
    const b = document.createElement('b');
    b.textContent = c.name;
    charEl.appendChild(b);
    if (c.job) charEl.appendChild(document.createTextNode('  ·  ' + c.job));
}

// The controller layout changed (pfm-ui's default, an action added or removed): drawn again if up.
NuiRouter.register('padLayout', (d) => padScreen.setState(d && d.state));
