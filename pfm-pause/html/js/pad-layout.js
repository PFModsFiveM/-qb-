// Copyright (c) 2026 Whippy, from WHIP, LGPL-3.0; modified for PF.
// ========================================
// CONTROLLER — the pause menu's Controller screen (pfm-ui's button layout, through client/main.lua)
//
// The map goes and an Xbox controller fills the screen, every button with a line drawn out to what it does — on
// foot, in a vehicle, or with LB held. One of the server's buttons is chosen (pad, keys or mouse) and the bar at the
// bottom puts another action on it; "Reset to the server's default" puts back the server's layout.
//
// ONLY THE SERVER'S BUTTONS CHANGE (pfm-ui's slots): the D-pad, LB held, and LB with A, B, X, Y or the D-pad. What
// goes on them: pfm-ui's own actions and the ones other resources registered (RegisterPadAction). GTA's own buttons
// are drawn with what GTA has on them (its Standard layout) and say so.
//
// LUA OWNS THE LAYOUT. Every change goes to client/main.lua ('padLayoutSet' / 'padLayoutReset'), which asks pfm-ui
// to swap and save it, and answers with the layout as it now is; the page only draws what it is told. 'padLayout'
// pushes a change made elsewhere.
//
// PF: the original's slots L3, A in a vehicle and B on foot are not pfm-ui's, so those buttons are GTA's here; LB
// held is a slot of its own (pfm-ui runs an action while it is held).
// ========================================

import { nuiCallback, escapeHtml } from './utils.js';
import { padGlyph } from './pad-glyphs.js';

const NS = 'http://www.w3.org/2000/svg';

const VIEWS = [
    { id: 'foot', label: 'On foot' },
    { id: 'car', label: 'In a vehicle' },
    { id: 'lb', label: 'Holding LB' },
];

// ---- the drawing ----
//
// LAID OUT AS GTA'S OWN CONTROLLER PAGE (GTA Enhanced's picture as the reference, the original drawing kept). 3D Clanker exported the picture GTA draws there (pause_menu_pages_settings_pc /
// controller, 1024 px; Rockstar's, so never shipped) and the shape, the rings and the label lines here
// are measured from it: GTA's px → the box = (px - 82) × 0.7218, (px - 270) × 0.7218 + 30. Nine rows a
// side, straight lines with square bends, in GTA's order.
//
// The controller is drawn in its own box (0-620 across, 0-470 down) placed at OX, OY on a 1600-wide
// stage. Labels stand in two columns: the left one ends at LABEL_L, the right one starts at LABEL_R;
// the lines end at LINE_L / LINE_R. A line's first point is on its button, in stage terms (its place in
// the box plus OX, OY).
const OX = 490, OY = 190;
const LABEL_L = 460, LABEL_R = 1140;
const LINE_L = 474, LINE_R = 1126;
const ROWS = [189, 247, 305, 363, 423, 478, 539, 596, 654];

/** A role on a button in a view: one of the server's slots (it can change), the server's own fixed use, GTA's.
 *  A slot with nothing on it says what the button does then: `also`, GTA's action on it as well (D-pad left's
 *  radio in a car, said beside the server's); `gta`, GTA's action left to it (LB + Y free: Y still gets in);
 *  `plain`, the slot it falls back to (LB + a D-pad direction free: the direction's own action);
 *  `fixed`, the server's fixed use, which it has free and takes first when not. */
const slot = (id, opts = {}) => ({ kind: 'slot', slot: id, also: opts.also, gtaElse: opts.gta, plainElse: opts.plain, fixedElse: opts.fixed });
const fixed = (text, why) => ({ kind: 'fixed', text, why });
const gta = (text) => ({ kind: 'gta', text });
const dim = { kind: 'dim' };   // LB's view: not part of the LB layer

const LB_WHY = 'The combo key: hold LB and press another button. "Holding LB" shows what each one does.';
const PAUSE_WHY = 'Opens this menu.';

/** Every button with a label, in its column's order, top to bottom (GTA's). `glyphs`: its pictures in
 *  the bar. The lines are GTA's routes, button first. Which of a stick's two lines is moving it and which
 *  is pressing it is GTA's page's choice too: moving it from the side (left) or the middle (right). */
const BUTTONS = [
    // ---- left ----
    { id: 'lt', name: 'LT', glyphs: ['lt'], side: 'L', row: ROWS[0],
      line: [[626, 224], [626, ROWS[0]], [LINE_L, ROWS[0]]],
      roles: { foot: gta('Aim'), car: gta('Brake / reverse'), lb: dim } },
    { id: 'lb', name: 'LB', glyphs: ['lb'], side: 'L', row: ROWS[1],
      line: [[626, ROWS[1]], [LINE_L, ROWS[1]]],
      roles: { foot: slot('lb', { gta: 'Weapon wheel' }), car: slot('lb', { gta: 'Weapon wheel' }), lb: fixed('Held', LB_WHY) } },
    { id: 'view', name: 'View', glyphs: ['view'], side: 'L', row: ROWS[2],
      line: [[746, 333], [746, ROWS[2]], [LINE_L, ROWS[2]]],
      roles: { foot: gta('Change camera'), car: gta('Change camera'), lb: dim } },
    { id: 'ls', name: 'Left stick', glyphs: ['ls'], side: 'L', row: ROWS[3],
      line: [[611, ROWS[3]], [LINE_L, ROWS[3]]],
      roles: { foot: gta('Move'), car: gta('Steer'), lb: dim } },
    { id: 'l3', name: 'L3 (stick press)', glyphs: ['l3'], side: 'L', row: ROWS[4],
      line: [[638, 354], [638, ROWS[4]], [LINE_L, ROWS[4]]],
      roles: { foot: gta('Stealth'), car: gta('Horn'), lb: dim } },
    { id: 'dpad_up', name: 'D-pad up', glyphs: ['dpad_up'], side: 'L', row: ROWS[5],
      line: [[713, 419], [655, 419], [655, ROWS[5]], [LINE_L, ROWS[5]]],
      roles: { foot: slot('dpad_up'), car: slot('dpad_up'), lb: slot('lb_dpad_up', { plain: 'dpad_up' }) } },
    { id: 'dpad_left', name: 'D-pad left', glyphs: ['dpad_left'], side: 'L', row: ROWS[6],
      line: [[681, 449], [681, ROWS[6]], [LINE_L, ROWS[6]]],
      roles: { foot: slot('dpad_left'), car: slot('dpad_left', { also: 'Radio' }), lb: slot('lb_dpad_left', { plain: 'dpad_left' }) } },
    { id: 'dpad_down', name: 'D-pad down', glyphs: ['dpad_down'], side: 'L', row: ROWS[7],
      line: [[713, 481], [713, ROWS[7]], [LINE_L, ROWS[7]]],
      roles: { foot: slot('dpad_down'), car: slot('dpad_down'), lb: slot('lb_dpad_down', { plain: 'dpad_down' }) } },
    { id: 'dpad_right', name: 'D-pad right', glyphs: ['dpad_right'], side: 'L', row: ROWS[8],
      line: [[746, 449], [746, ROWS[8]], [LINE_L, ROWS[8]]],
      roles: { foot: slot('dpad_right'), car: slot('dpad_right', { also: 'Headlights' }), lb: slot('lb_dpad_right', { plain: 'dpad_right' }) } },
    // ---- right ----
    { id: 'rt', name: 'RT', glyphs: ['rt'], side: 'R', row: ROWS[0],
      line: [[976, 224], [976, ROWS[0]], [LINE_R, ROWS[0]]],
      roles: { foot: gta('Shoot'), car: gta('Accelerate'), lb: dim } },
    { id: 'rb', name: 'RB', glyphs: ['rb'], side: 'R', row: ROWS[1],
      line: [[976, ROWS[1]], [LINE_R, ROWS[1]]],
      roles: { foot: gta('Take cover'), car: gta('Handbrake'), lb: dim } },
    { id: 'menu', name: 'Menu', glyphs: ['menu'], side: 'R', row: ROWS[2],
      line: [[855, 333], [855, 273], [1084, 273], [1084, ROWS[2]], [LINE_R, ROWS[2]]],
      roles: { foot: fixed('Pause menu', PAUSE_WHY), car: fixed('Pause menu', PAUSE_WHY), lb: dim } },
    { id: 'y', name: 'Y', glyphs: ['y'], side: 'R', row: ROWS[3],
      line: [[985, 307], [1044, 307], [1044, ROWS[3]], [LINE_R, ROWS[3]]],
      roles: { foot: gta('Get in a vehicle'), car: gta('Get out'), lb: slot('lb_y', { gta: 'Get in / out' }) } },
    { id: 'b', name: 'B', glyphs: ['b'], side: 'R', row: ROWS[4],
      line: [[1005, 372], [1005, ROWS[4]], [LINE_R, ROWS[4]]],
      roles: { foot: gta('Reload / punch'), car: gta('Cinematic camera'), lb: slot('lb_b', { gta: 'Reload / punch' }) } },
    { id: 'a', name: 'A', glyphs: ['a'], side: 'R', row: ROWS[5],
      line: [[963, 414], [963, ROWS[5]], [LINE_R, ROWS[5]]],
      roles: { foot: gta('Sprint'), car: gta('Sprint'), lb: slot('lb_a', { gta: 'Sprint' }) } },
    { id: 'x', name: 'X', glyphs: ['x'], side: 'R', row: ROWS[6],
      line: [[920, 372], [920, ROWS[6]], [LINE_R, ROWS[6]]],
      roles: { foot: gta('Jump'), car: gta('Next weapon'), lb: slot('lb_x', { gta: 'Jump' }) } },
    { id: 'rs', name: 'Right stick', glyphs: ['rs'], side: 'R', row: ROWS[7],
      line: [[888, 450], [888, ROWS[7]], [LINE_R, ROWS[7]]],
      roles: { foot: gta('Look'), car: gta('Look'), lb: dim } },
    { id: 'r3', name: 'R3 (stick press)', glyphs: ['r3'], side: 'R', row: ROWS[8],
      line: [[860, 449], [860, ROWS[8]], [LINE_R, ROWS[8]]],
      roles: { foot: gta('Look behind'), car: gta('Look behind'), lb: dim } },
];

const BY_ID = new Map(BUTTONS.map((b) => [b.id, b]));
const STICK_OF = { ls: true, l3: true, rs: true, r3: true };   // the two buttons each stick's shape is
const LEFT = BUTTONS.filter((b) => b.side === 'L');
const RIGHT = BUTTONS.filter((b) => b.side === 'R');

/** Each slot's name in words, for "now on D-pad up". */
const SLOT_NAMES = {
    dpad_up: 'D-pad up', dpad_down: 'D-pad down', dpad_left: 'D-pad left', dpad_right: 'D-pad right',
    lb: 'LB (hold)',
    lb_a: 'LB + A', lb_b: 'LB + B', lb_x: 'LB + X', lb_y: 'LB + Y',
    lb_dpad_up: 'LB + D-pad up', lb_dpad_down: 'LB + D-pad down',
    lb_dpad_left: 'LB + D-pad left', lb_dpad_right: 'LB + D-pad right',
};

/** Where an action does anything, said on its label in a view where it does not. */
const WHERE_NOTE = { car: 'in the driver\'s seat', foot: 'on foot' };

// ---- the controller's shapes, in its own box (0-620 across, 0-470 down) ----
//
// An Xbox Series controller, front on, in the style of GTA's page: a black body with a grey edge, the
// shells' seam along the underside, white rings for the sticks, the D-pad and the buttons. Points are
// measured from GTA's picture (see above) and smoothed into curves here; the right half is the left one
// mirrored. No Xbox logo: the guide button is a plain ring.

/** A smooth curve through points (Catmull-Rom as cubic Béziers); `closed` joins the last to the first. */
function smooth(pts, closed) {
    const n = pts.length;
    const P = (i) => pts[closed ? (i + n) % n : Math.max(0, Math.min(n - 1, i))];
    const r = (v) => Math.round(v * 10) / 10;
    let d = `M${pts[0][0]} ${pts[0][1]}`;
    for (let i = 0; i < (closed ? n : n - 1); i++) {
        const p0 = P(i - 1), p1 = P(i), p2 = P(i + 1), p3 = P(i + 2);
        d += ` C${r(p1[0] + (p2[0] - p0[0]) / 6)} ${r(p1[1] + (p2[1] - p0[1]) / 6)}`
            + ` ${r(p2[0] - (p3[0] - p1[0]) / 6)} ${r(p2[1] - (p3[1] - p1[1]) / 6)} ${p2[0]} ${p2[1]}`;
    }
    return d + (closed ? ' Z' : '');
}

const mirror = ([x, y]) => [620 - x, y];

/** The body's left half, from the middle of the top edge round to the middle of the underside. */
const BODY_LEFT = [
    [310, 46.6], [260, 47.5], [217.3, 48.8], [186.2, 50.2], [157.4, 53.1], [135.7, 58.9], [114, 68.3], [95, 80],
    [82, 104], [71, 130], [61, 158], [52, 184], [43, 210], [33, 241], [25, 267], [17, 297], [9, 323], [4, 340],
    [1.2, 366], [0.4, 378], [1.4, 392], [7.2, 414], [17, 431], [33, 449], [46, 457.5], [60, 464.5], [72, 462],
    [92.4, 446.5], [114, 422.7], [135.7, 397.4], [157.4, 372.1], [179, 354.1], [200.7, 346.9], [260, 346.4], [310, 346.4],
];
const BODY = smooth([...BODY_LEFT, ...BODY_LEFT.slice(1, -1).reverse().map(mirror)], true);

/** Where the top and bottom shells meet: inside the underside and the grips' inner edges. */
const SEAM_LEFT = [[58, 451], [76, 444], [96, 431], [116, 410], [137, 386], [158, 362], [180, 344], [200, 335.5],
    [216, 334], [260, 334], [310, 334]];
const SEAM = smooth([...SEAM_LEFT, ...SEAM_LEFT.slice(0, -1).reverse().map(mirror)], false);

/** The trigger: the thin lobe at the top. The bumper: the crescent between it and the body's top edge. */
const TRIGGER_OUTER = [[103.2, 62.5], [114, 50.2], [124.9, 40.1], [135.7, 34.3], [146.5, 32.2], [161, 30.7], [179, 30.7],
    [189.8, 31.5], [198.5, 33.6]];
const TRIGGER_FOOT = [[97, 80], [110.4, 55.3], [128.5, 46.6], [150.1, 40.1], [171.8, 36.5], [189.8, 35.1]];
const BODY_TOP = [[217.3, 48.8], [186.2, 50.2], [157.4, 53.1], [135.7, 58.9], [114, 68.3]];
const LT_PTS = [...TRIGGER_OUTER, ...TRIGGER_FOOT.slice(1).reverse()];
const LB_PTS = [...TRIGGER_FOOT, [198.5, 34.4], [207.9, 41.5], ...BODY_TOP];
const LT_PATH = smooth(LT_PTS, true);
const RT_PATH = smooth(LT_PTS.map(mirror), true);
const LB_PATH = smooth(LB_PTS, true);
const RB_PATH = smooth(LB_PTS.map(mirror), true);

/** Centres, and the rings' sizes. */
const LS_AT = [148, 159.9], RS_AT = [397.7, 258.8], DPAD_AT = [223, 258.8];
const RING_R = 49.8, CAP_R = 27.4, FACE_R = 22.4, SMALL_R = 15.5;
const VIEW_AT = [256.2, 158.5], MENU_AT = [364.5, 158.5], SHARE_AT = [309.7, 185.2], GUIDE_AT = [309.7, 84.9];

/** The face buttons: centre, letter, the glyphs' colour. */
const FACE = {
    y: { x: 472.8, y: 116.6, c: '#eab308' },
    b: { x: 514.6, y: 159.2, c: '#ef4444' },
    a: { x: 472.8, y: 201.8, c: '#22c55e' },
    x: { x: 430.2, y: 159.2, c: '#3b82f6' },
};

function el(tag, attrs, parent) {
    const n = document.createElementNS(NS, tag);
    for (const k in attrs) n.setAttribute(k, attrs[k]);
    if (parent) parent.appendChild(n);
    return n;
}

/** The drawing: the controller, a line and a label per button. Built once; draw() sets its states. */
function buildStage(svg) {
    svg.setAttribute('viewBox', '0 150 1600 548');
    svg.setAttribute('preserveAspectRatio', 'xMidYMid meet');

    // THE LINES BETWEEN THE BODY AND THE BUTTONS: over the body, so they reach the buttons in its
    // middle, and under the buttons, so a line passing one goes behind it.
    const shell = el('g', { class: 'pl-pad', transform: `translate(${OX} ${OY})` }, svg);
    const lines = el('g', { class: 'pl-lines' }, svg);
    const pad = el('g', { class: 'pl-pad', transform: `translate(${OX} ${OY})` }, svg);
    const labels = el('g', { class: 'pl-labels' }, svg);
    const parts = new Map();   // button id -> { shape, line, label, cap, main }

    // The triggers behind the body; the body, its edge, the shells' seam.
    const lt = el('path', { d: LT_PATH, class: 'pl-part pl-trigger' }, shell);
    const rt = el('path', { d: RT_PATH, class: 'pl-part pl-trigger' }, shell);
    el('path', { d: BODY, class: 'pl-body' }, shell);
    el('path', { d: SEAM, class: 'pl-seam' }, shell);

    // The bumpers, over the body's top edge.
    const lb = el('path', { d: LB_PATH, class: 'pl-part pl-bumper' }, pad);
    const rb = el('path', { d: RB_PATH, class: 'pl-part pl-bumper' }, pad);

    // The sticks: a white ring, a grey cap with its grip ticks round the edge.
    const stick = ([cx, cy]) => {
        const g = el('g', { class: 'pl-stick' }, pad);
        el('circle', { cx, cy, r: RING_R, class: 'pl-part pl-ring' }, g);
        el('circle', { cx, cy, r: CAP_R, class: 'pl-cap' }, g);
        let ticks = '';
        for (let i = 0; i < 36; i++) {
            const a = (i / 36) * Math.PI * 2, c = Math.cos(a), s = Math.sin(a);
            ticks += `M${(cx + c * (CAP_R - 4.5)).toFixed(1)} ${(cy + s * (CAP_R - 4.5)).toFixed(1)}`
                + `L${(cx + c * (CAP_R - 0.8)).toFixed(1)} ${(cy + s * (CAP_R - 0.8)).toFixed(1)}`;
        }
        el('path', { d: ticks, class: 'pl-ticks' }, g);
        return g;
    };
    const ls = stick(LS_AT);
    const rs = stick(RS_AT);

    // The D-pad: a white ring, a dark cross in it, each arm its own button.
    const [dx, dy] = DPAD_AT;
    el('circle', { cx: dx, cy: dy, r: RING_R, class: 'pl-part pl-ring pl-dpad-ring' }, pad);
    el('rect', { x: dx - 12.3, y: dy - 12.3, width: 24.6, height: 24.6, class: 'pl-hub' }, pad);
    const arm = (x, y, w, h, rot) => {
        const g = el('g', { class: 'pl-arm' }, pad);
        el('rect', { x, y, width: w, height: h, rx: 2, class: 'pl-part pl-arm-shape' }, g);
        const cx = x + w / 2, cy = y + h / 2;
        el('path', { d: `M${cx} ${cy - 4.5} l5 7 h-10 Z`, class: 'pl-arrow', transform: `rotate(${rot} ${cx} ${cy})` }, g);
        return g;
    };
    const dUp = arm(dx - 12.3, dy - 30, 24.6, 18, 0);
    const dDown = arm(dx - 12.3, dy + 12, 24.6, 18, 180);
    const dLeft = arm(dx - 30, dy - 12.3, 18, 24.6, -90);
    const dRight = arm(dx + 12, dy - 12.3, 18, 24.6, 90);

    // The face buttons: white rings, the letters in their colours (as the pad glyphs have them).
    const face = {};
    for (const k of Object.keys(FACE)) {
        const f = FACE[k];
        const g = el('g', { class: 'pl-face' }, pad);
        el('circle', { cx: f.x, cy: f.y, r: FACE_R, class: 'pl-part pl-ring' }, g);
        const t = el('text', { x: f.x, y: f.y + 8.5, class: 'pl-letter', fill: f.c }, g);
        t.textContent = k.toUpperCase();
        face[k] = g;
    }

    // The middle: View, Menu, Share and the guide button (no label: FiveM has no use for the last two).
    const ringed = (at, mark, cls) => {
        const g = el('g', {}, pad);
        el('circle', { cx: at[0], cy: at[1], r: SMALL_R, class: 'pl-part pl-ring' }, g);
        el('path', { d: mark, class: cls }, g);
        return g;
    };
    const [vx, vy] = VIEW_AT, [mx, my] = MENU_AT, [sx, sy] = SHARE_AT, [gx, gy] = GUIDE_AT;
    const view = ringed(VIEW_AT, `M${vx - 6} ${vy - 5} h7 v6 h-7 Z M${vx - 2} ${vy - 1} h8 v6 h-8 Z`, 'pl-mark');
    const menu = ringed(MENU_AT, `M${mx - 6} ${my - 4} h12 M${mx - 6} ${my} h12 M${mx - 6} ${my + 4} h12`, 'pl-mark-line');
    el('rect', { x: sx - 17, y: sy - 9.4, width: 34, height: 18.8, rx: 9.4, class: 'pl-part pl-ring pl-share' }, pad);
    el('path', { d: `M${sx - 7} ${sy + 3.5} h14 M${sx} ${sy + 1.5} v-7 M${sx - 3} ${sy - 2.5} l3 -3 l3 3`, class: 'pl-mark-line' }, pad);
    el('circle', { cx: gx, cy: gy, r: 21.5, class: 'pl-guide' }, pad);
    el('circle', { cx: gx, cy: gy, r: 13, class: 'pl-guide-mark' }, pad);

    const shapes = { lt, rt, lb, rb, ls, l3: ls, rs, r3: rs, dpad_up: dUp, dpad_down: dDown,
        dpad_left: dLeft, dpad_right: dRight, view, menu, ...face };

    for (const b of BUTTONS) {
        const pts = b.line.map((p) => p.join(',')).join(' ');
        const line = el('polyline', { points: pts, class: 'pl-line' }, lines);

        const left = b.side === 'L';
        const x = left ? LABEL_L : LABEL_R;
        const anchor = left ? 'end' : 'start';
        const label = el('g', { class: 'pl-label', 'data-btn': b.id }, labels);
        // The hit area: the whole row, out to the line's end.
        const hitX = left ? 150 : LINE_R - 6;
        el('rect', { x: hitX, y: b.row - 28, width: left ? LINE_L + 6 - hitX : 1450 - hitX, height: 56, class: 'pl-hit' }, label);
        const cap = el('text', { x, y: b.row - 8, 'text-anchor': anchor, class: 'pl-cap-text' }, label);
        const main = el('text', { x, y: b.row + 19, 'text-anchor': anchor, class: 'pl-main' }, label);
        const shape = shapes[b.id];
        if (shape) {
            shape.classList.add('pl-btn');
            shape.dataset.btn = b.id;
        }
        parts.set(b.id, { shape, line, label, cap, main });
    }
    return parts;
}

// ---- the screen ----

export class PadLayout {
    /** @param {HTMLElement} root  the pause menu's root; @param {() => void} onBack  back to its menu */
    constructor(root, onBack) {
        this.onBack = onBack;
        this.state = null;
        this.view = 'foot';
        this.sel = 'dpad_up';
        this.focus = 'stage';       // 'stage' | 'chips' | 'confirm'
        this.chip = 0;
        this.confirmSel = 1;        // Cancel, by default
        this.note = '';             // what the last change did
        this.isOpen = false;

        const wrap = document.createElement('section');
        wrap.className = 'pm-pad';
        wrap.innerHTML = `
            <header class="pl-head">
                <button class="pm-back pl-back" type="button"><span class="pm-back-arrow">&#8592;</span> Menu</button>
                <div class="pl-title">Controller</div>
                <nav class="pl-tabs">
                    <span class="pl-tab-glyph" data-g="lb"></span>
                    ${VIEWS.map((v) => `<button class="pl-tab" type="button" data-view="${v.id}">${v.label}</button>`).join('')}
                    <span class="pl-tab-glyph" data-g="rb"></span>
                </nav>
                <div class="pl-status"></div>
            </header>
            <div class="pl-stage"><svg class="pl-svg" xmlns="${NS}"></svg></div>
            <div class="pl-foot">GTA's own buttons are shown as GTA's Standard controller layout has them, and are set in GTA's Settings. The server's can be changed here.</div>
            <footer class="pl-bar">
                <div class="pl-what">
                    <div class="pl-what-glyphs"></div>
                    <div class="pl-what-text"><div class="pl-what-name"></div><div class="pl-what-sub"></div></div>
                </div>
                <div class="pl-choices"></div>
                <div class="pl-side">
                    <button class="pl-reset" type="button">Reset to the server's default</button>
                    <div class="pl-confirm">
                        <span class="pl-confirm-q">Reset every button?</span>
                        <button class="pl-cbtn" data-c="0" type="button">Reset</button>
                        <button class="pl-cbtn" data-c="1" type="button">Cancel</button>
                    </div>
                </div>
            </footer>`;
        root.appendChild(wrap);
        this.wrap = wrap;

        for (const g of wrap.querySelectorAll('.pl-tab-glyph')) {
            const img = padGlyph(g.dataset.g, 'pl-tab-img');
            if (img) g.appendChild(img);
        }
        this.tabs = [...wrap.querySelectorAll('.pl-tab')];
        this.statusEl = wrap.querySelector('.pl-status');
        this.whatGlyphs = wrap.querySelector('.pl-what-glyphs');
        this.whatName = wrap.querySelector('.pl-what-name');
        this.whatSub = wrap.querySelector('.pl-what-sub');
        this.choicesEl = wrap.querySelector('.pl-choices');
        this.resetBtn = wrap.querySelector('.pl-reset');
        this.confirmEl = wrap.querySelector('.pl-confirm');
        this.confirmBtns = [...wrap.querySelectorAll('.pl-cbtn')];
        this.parts = buildStage(wrap.querySelector('.pl-svg'));

        // ---- mouse ----
        wrap.querySelector('.pl-back').addEventListener('click', () => this.onBack());
        this.tabs.forEach((t) => t.addEventListener('click', () => this.setView(t.dataset.view)));
        wrap.querySelector('.pl-svg').addEventListener('mouseover', (e) => {
            const id = e.target.closest('[data-btn]')?.dataset.btn;
            if (id && this.focus === 'stage' && this.selectable(id) && id !== this.sel) { this.sel = id; this.draw(); }
        });
        wrap.querySelector('.pl-svg').addEventListener('click', (e) => {
            const id = e.target.closest('[data-btn]')?.dataset.btn;
            if (!id || !this.selectable(id)) return;
            this.sel = id;
            this.focus = 'stage';
            this.enterChips();
        });
        this.choicesEl.addEventListener('click', (e) => {
            const c = e.target.closest('.pl-chip');
            if (!c) return;
            this.chip = Number(c.dataset.i);
            this.assign();
        });
        this.resetBtn.addEventListener('click', () => this.askReset());
        this.confirmBtns.forEach((b, i) => {
            b.addEventListener('mouseenter', () => { if (this.focus === 'confirm') { this.confirmSel = i; this.draw(); } });
            b.addEventListener('click', () => this.answerReset(i));
        });
    }

    // ---- open and close ----

    open() {
        this.isOpen = true;
        this.focus = 'stage';
        this.note = '';
        if (!this.selectable(this.sel)) this.sel = this.firstSelectable();
        this.draw();
        nuiCallback('padLayout', {}).then((st) => { if (st && st.actions) this.setState(st); });
    }

    close() {
        this.isOpen = false;
        this.focus = 'stage';
    }

    /** The layout as Lua has it now. */
    setState(st) {
        if (!st || !Array.isArray(st.actions)) return;
        // An empty Lua table arrives as a list.
        if (Array.isArray(st.layout)) st.layout = {};
        if (Array.isArray(st.defaults)) st.defaults = {};
        this.state = st;
        if (this.isOpen) this.draw();
    }

    // ---- what a button is, here ----

    role(id, view = this.view) {
        return BY_ID.get(id).roles[view];
    }

    selectable(id) {
        const r = BY_ID.has(id) && this.role(id);
        return !!r && r.kind !== 'dim';
    }

    firstSelectable() {
        return [...LEFT, ...RIGHT].find((b) => this.selectable(b.id))?.id || 'dpad_up';
    }

    action(id) {
        return this.state?.actions.find((a) => a.id === id) || null;
    }

    /** The action on a slot, or null. */
    on(slotId) {
        const a = this.state?.layout?.[slotId];
        return a ? this.action(a) : null;
    }

    /** What a button's label says: { text, note, kind }. */
    labelOf(id) {
        const r = this.role(id);
        if (r.kind === 'dim') {
            // LB's view: the button still does its usual thing; drawn faint.
            const usual = this.role(id, 'foot');
            return { text: this.textOf(usual, 'foot').text, note: '', kind: 'dim' };
        }
        return this.textOf(r, this.view);
    }

    textOf(r, view) {
        if (r.kind === 'gta') return { text: r.text, note: 'GTA', kind: 'gta' };
        if (r.kind === 'fixed') return { text: r.text, note: '', kind: 'fixed' };
        if (r.kind === 'slot') {
            const a = this.on(r.slot);
            if (!a) {
                // Free: what the button does then.
                if (r.plainElse) {
                    const p = this.on(r.plainElse);
                    return { text: p ? p.label : 'Nothing', note: 'as without LB', kind: p ? 'else' : 'empty' };
                }
                if (r.fixedElse) return { text: r.fixedElse, note: '', kind: 'else' };
                const g = r.gtaElse || r.also;
                return g ? { text: g, note: 'GTA', kind: 'gta' } : { text: 'Nothing', note: '', kind: 'empty' };
            }
            const off = a.where && a.where !== view && view !== 'lb' ? WHERE_NOTE[a.where] : '';
            // Not here (the sprint, in a car), and GTA has the button here: GTA's is what it does.
            if (off && r.also) return { text: r.also, note: 'GTA · ' + a.label + ' ' + off, kind: 'gta' };
            const also = r.also ? 'also GTA\'s ' + r.also.toLowerCase() : '';
            const first = r.fixedElse ? r.fixedElse.toLowerCase() + ' first' : '';
            return { text: a.label, note: [off, also, first].filter(Boolean).join(' · '), kind: 'slot' };
        }
        return { text: '', note: '', kind: 'dim' };
    }

    // ---- drawing ----

    draw() {
        const st = this.state;
        this.wrap.dataset.view = this.view;
        this.wrap.dataset.focus = this.focus;
        this.tabs.forEach((t) => t.classList.toggle('on', t.dataset.view === this.view));
        this.statusEl.textContent = st ? (st.custom ? 'Your layout' : 'Server default') : '';
        this.statusEl.classList.toggle('custom', !!st?.custom);

        for (const b of BUTTONS) {
            const p = this.parts.get(b.id);
            const l = this.labelOf(b.id);
            const r = this.role(b.id);
            const on = b.id === this.sel;
            const editable = r.kind === 'slot';
            p.cap.textContent = b.name.toUpperCase() + (l.note ? '  ·  ' + l.note.toUpperCase() : '');
            p.main.textContent = l.text;
            for (const n of [p.label, p.line]) {
                n.classList.toggle('on', on);
                n.classList.toggle('edit', editable);
                n.classList.toggle('dim', r.kind === 'dim');
                n.classList.toggle('gta', l.kind === 'gta' || l.kind === 'else');
                n.classList.toggle('empty', l.kind === 'empty');
            }
            if (p.shape && !STICK_OF[b.id]) {
                p.shape.classList.toggle('on', on);
                p.shape.classList.toggle('edit', editable);
                p.shape.classList.toggle('dim', r.kind === 'dim');
            }
        }
        // A stick is one shape for two buttons (moving it, pressing it): lit for either, and editable
        // when pressing it is one of the server's.
        for (const [stick, press] of [['ls', 'l3'], ['rs', 'r3']]) {
            const s = this.parts.get(stick).shape;
            s.classList.toggle('on', this.sel === stick || this.sel === press);
            s.classList.toggle('edit', this.role(press).kind === 'slot');
            s.classList.toggle('dim', this.role(stick).kind === 'dim' && this.role(press).kind === 'dim');
        }
        this.parts.get('lb').shape.classList.toggle('held', this.view === 'lb');

        this.drawBar();
    }

    drawBar() {
        const b = BY_ID.get(this.sel);
        const r = this.role(this.sel);
        const lb = this.view === 'lb' && r.kind === 'slot';

        this.whatGlyphs.textContent = '';
        for (const g of (lb ? ['lb', ...b.glyphs] : b.glyphs)) {
            const img = padGlyph(g, 'pl-what-img');
            if (img) this.whatGlyphs.appendChild(img);
        }
        this.whatName.textContent = (lb ? 'LB + ' : '') + b.name;

        const st = this.state;
        this.resetBtn.disabled = !st?.custom;
        this.confirmEl.classList.toggle('open', this.focus === 'confirm');
        this.resetBtn.classList.toggle('hidden', this.focus === 'confirm');
        this.confirmBtns.forEach((x, i) => x.classList.toggle('on', i === this.confirmSel));

        this.choicesEl.textContent = '';
        if (r.kind !== 'slot') {
            this.choicesEl.classList.remove('live');
            const l = this.labelOf(this.sel);
            if (r.kind === 'gta') {
                this.whatSub.textContent = 'GTA: ' + r.text;
                this.choicesEl.innerHTML = '<div class="pl-info">GTA\'s own button. The server leaves GTA\'s buttons to GTA; '
                    + 'its controller layout is in GTA\'s Settings.</div>';
            } else {
                this.whatSub.textContent = l.text;
                this.choicesEl.innerHTML = `<div class="pl-info">${escapeHtml(r.why || 'Always this, on this server.')}</div>`;
            }
            return;
        }

        const cur = st?.layout?.[r.slot] || null;
        const a = cur ? this.action(cur) : null;
        let does = a ? 'Does: ' + a.label : 'Free';
        if (!a) {
            // What a free one does: GTA's, or the button's own without LB.
            const l = this.labelOf(this.sel);
            if (l.kind === 'gta') does = 'Free: GTA\'s ' + l.text.toLowerCase();
            else if (l.kind === 'else') does = 'Free: ' + l.text + (r.plainElse ? ', as without LB' : '');
        }
        this.whatSub.textContent = this.note || does;
        this.choicesEl.classList.toggle('live', this.focus === 'chips');
        this.chipList().forEach((c, i) => {
            const btn = document.createElement('button');
            btn.type = 'button';
            btn.className = 'pl-chip';
            btn.dataset.i = i;
            if ((c.id || null) === cur) btn.classList.add('cur');
            if (this.focus === 'chips' && i === this.chip) btn.classList.add('on');
            const name = document.createElement('span');
            name.className = 'pl-chip-name';
            name.textContent = c.label;
            btn.appendChild(name);
            const elsewhere = c.id && Object.keys(st?.layout || {}).find((s) => st.layout[s] === c.id && s !== r.slot);
            if (elsewhere) {
                const n = document.createElement('span');
                n.className = 'pl-chip-note';
                n.textContent = 'on ' + SLOT_NAMES[elsewhere];
                btn.appendChild(n);
            } else if (c.where) {
                const n = document.createElement('span');
                n.className = 'pl-chip-note';
                n.textContent = WHERE_NOTE[c.where];
                btn.appendChild(n);
            }
            this.choicesEl.appendChild(btn);
        });
    }

    /** What can go on a slot: the actions on this server, then nothing. */
    chipList() {
        const list = (this.state?.actions || []).filter((a) => a.on).map((a) => ({ id: a.id, label: a.label, where: a.where }));
        list.push({ id: null, label: 'Nothing' });
        return list;
    }

    // ---- doing ----

    setView(v) {
        if (!VIEWS.some((x) => x.id === v)) return;
        this.view = v;
        if (this.focus === 'chips') this.focus = 'stage';
        if (!this.selectable(this.sel)) this.sel = this.nearestSelectable(this.sel);
        this.note = '';
        this.draw();
    }

    stepView(d) {
        const i = VIEWS.findIndex((v) => v.id === this.view);
        this.setView(VIEWS[(i + d + VIEWS.length) % VIEWS.length].id);
    }

    /** The selectable button nearest a row, on its side first. */
    nearestSelectable(id) {
        const b = BY_ID.get(id);
        const near = (list) => list.filter((x) => this.selectable(x.id))
            .sort((p, q) => Math.abs(p.row - b.row) - Math.abs(q.row - b.row))[0];
        return (near(b.side === 'L' ? LEFT : RIGHT) || near(b.side === 'L' ? RIGHT : LEFT) || b).id;
    }

    move(dir) {
        const b = BY_ID.get(this.sel);
        if (dir === 'up' || dir === 'down') {
            const list = (b.side === 'L' ? LEFT : RIGHT).filter((x) => this.selectable(x.id));
            const i = list.findIndex((x) => x.id === b.id);
            const next = list[(i + (dir === 'down' ? 1 : -1) + list.length) % list.length];
            if (next) this.sel = next.id;
        } else {
            const other = (dir === 'left') === (b.side === 'R') ? (b.side === 'R' ? LEFT : RIGHT) : null;
            if (!other) return;
            const near = other.filter((x) => this.selectable(x.id))
                .sort((p, q) => Math.abs(p.row - b.row) - Math.abs(q.row - b.row))[0];
            if (near) this.sel = near.id;
        }
        this.note = '';
        this.draw();
    }

    enterChips() {
        const r = this.role(this.sel);
        if (r.kind !== 'slot' || !this.state) { this.draw(); return; }
        const cur = this.state.layout?.[r.slot] || null;
        const list = this.chipList();
        this.chip = Math.max(0, list.findIndex((c) => (c.id || null) === cur));
        this.focus = 'chips';
        this.note = '';
        this.draw();
    }

    stepChip(d) {
        const n = this.chipList().length;
        this.chip = (this.chip + d + n) % n;
        this.draw();
    }

    async assign() {
        const r = this.role(this.sel);
        if (r.kind !== 'slot') return;
        const c = this.chipList()[this.chip];
        if (!c) return;
        const cur = this.state?.layout?.[r.slot] || null;
        this.focus = 'stage';
        if ((c.id || null) === cur) { this.draw(); return; }
        const st = await nuiCallback('padLayoutSet', { slot: r.slot, action: c.id || '' });
        if (!st || !st.actions) { this.draw(); return; }
        this.setState(st);
        this.note = this.noteOf(st, c, cur);
        this.draw();
    }

    /** What the change did, in words: "Phone is here now; D-pad up has Engine on/off". */
    noteOf(st, c, was) {
        if (st.error) return 'Not changed: ' + st.error;
        const here = c.id ? this.action(c.id)?.label + ' is here now' : 'Nothing on it now';
        const s = st.swap;
        if (!s || !s.slot) return here + (was ? ' (' + this.action(was)?.label + ' is free)' : '');
        const gave = s.gave ? this.action(s.gave)?.label : null;
        return here + '; ' + SLOT_NAMES[s.slot] + (gave ? ' has ' + gave : ' is free');
    }

    askReset() {
        if (!this.state?.custom) return;
        this.focus = 'confirm';
        this.confirmSel = 1;
        this.draw();
    }

    async answerReset(i) {
        this.focus = 'stage';
        if (i === 0) {
            const st = await nuiCallback('padLayoutReset', {});
            if (st && st.actions) this.setState(st);
            this.note = 'Back to the server\'s default';
        }
        this.draw();
    }

    // ---- keys and the pad (pause.js hands them over in this mode) ----

    /** A key. Answers false when it was "back" out of the screen (pause.js goes to its menu). */
    onKey(e) {
        if (e.type && e.type !== 'keydown') return true;
        const k = e.key.toLowerCase();
        if (k === 'arrowup' || k === 'w') return this.nav('up');
        if (k === 'arrowdown' || k === 's') return this.nav('down');
        if (k === 'arrowleft' || k === 'a') return this.nav('left');
        if (k === 'arrowright' || k === 'd') return this.nav('right');
        if (k === 'enter' || k === ' ') return this.nav('select');
        if (k === 'escape' || k === 'backspace') return this.nav('back');
        if (k === 'q') return this.nav('tabPrev');
        if (k === 'e' || k === 'tab') { e.preventDefault?.(); return this.nav('tabNext'); }
        if (k === 'r') return this.nav('buttonY');
        return true;
    }

    /** A pad (or key) intent. Answers false for "back" out of the screen. */
    nav(n) {
        if (this.focus === 'confirm') {
            if (n === 'left' || n === 'right') { this.confirmSel = 1 - this.confirmSel; this.draw(); }
            else if (n === 'select') this.answerReset(this.confirmSel);
            else if (n === 'back') { this.focus = 'stage'; this.draw(); }
            return true;
        }
        if (this.focus === 'chips') {
            if (n === 'left' || n === 'up') this.stepChip(-1);
            else if (n === 'right' || n === 'down') this.stepChip(1);
            else if (n === 'select') this.assign();
            else if (n === 'back') { this.focus = 'stage'; this.draw(); }
            else if (n === 'tabPrev') this.stepView(-1);
            else if (n === 'tabNext') this.stepView(1);
            return true;
        }
        if (n === 'up' || n === 'down' || n === 'left' || n === 'right') this.move(n);
        else if (n === 'select') this.enterChips();
        else if (n === 'tabPrev') this.stepView(-1);
        else if (n === 'tabNext') this.stepView(1);
        else if (n === 'buttonY') this.askReset();
        else if (n === 'back') return false;
        return true;
    }

    /** The pad's hint strip (controller.js). */
    hints() {
        if (this.focus === 'confirm') return [['dpad', 'Choose'], ['a', 'Select'], ['b', 'Cancel']];
        if (this.focus === 'chips') return [['dpad', 'Choose'], ['a', 'Put it here'], ['b', 'Back']];
        const h = [['dpad', 'Choose']];
        if (this.role(this.sel).kind === 'slot') h.push(['a', 'Change']);
        h.push(['lb', ''], ['rb', 'View']);
        if (this.state?.custom) h.push(['y', 'Reset']);
        h.push(['b', 'Back']);
        return h;
    }
}
