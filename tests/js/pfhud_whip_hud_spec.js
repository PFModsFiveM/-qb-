// pf-hud's page after the WHIP port (html/index.html: js/router.js, js/status-hud.js, js/vehicle-dial.js,
// js/radar-tuner.js, app.js; classic scripts, no build step): the gauges render from the client's messages, the vehicle
// mode, the dial falling back to the flat one without WebGL, money in the capsule, the row under the map's frame, the
// layout editor on a controller (pfm-ui's pad.js), the radar tuner. The client side is
// tests/specs/pfhud_whip_port_spec.lua. Run: node js/pfhud_whip_hud_spec.js
const fs = require('fs');
const path = require('path');
const { JSDOM, VirtualConsole } = require('jsdom');
const PF = path.resolve(__dirname, '..', '..', '..', '[pfscripts]', 'pf-hud');
const HUD = path.join(PF, 'html');
const PAD = path.resolve(__dirname, '..', '..', 'pfm-ui', 'html', 'pad.js');

let passed = 0, failed = 0;
const failures = [];
const pending = [];
function check(name, fn) {
    try {
        const r = fn();
        if (r && typeof r.then === 'function') { pending.push(r.then(() => passed++, (e) => { failed++; failures.push(`${name}: ${e.message}`); })); return; }
        passed++;
    } catch (e) { failed++; failures.push(`${name}: ${e.message}`); }
}
function eq(a, b, m) { if (a !== b) throw new Error(`${m || ''} expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`); }
function ok(v, m) { if (!v) throw new Error(m || 'expected truthy'); }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const html = fs.readFileSync(path.join(HUD, 'index.html'), 'utf8');
const manifest = fs.readFileSync(path.join(PF, 'fxmanifest.lua'), 'utf8');
const SCRIPTS = ['js/router.js', 'js/status-hud.js', 'js/vehicle-dial.js', 'js/radar-tuner.js', 'app.js'];

/** A fresh page: jsdom, a fetch that records NUI callbacks, the scripts evaluated in the page's order. */
function page(opts = {}) {
    const vc = new VirtualConsole();
    const errors = [];
    vc.on('error', (e) => errors.push(String(e && e.message || e)));
    vc.on('jsdomError', () => {});   // canvas getContext is not implemented in jsdom: that is the no-WebGL case
    const dom = new JSDOM(html, { url: 'https://cfx-nui-pf-hud/html/index.html', runScripts: 'outside-only', pretendToBeVisual: true, virtualConsole: vc });
    const w = dom.window;
    const posts = [];
    w.fetch = (url, o) => { posts.push({ url: String(url), body: o && o.body ? JSON.parse(o.body) : null }); return Promise.resolve({ json: async () => ({}) }); };
    w.GetParentResourceName = () => 'pf-hud';
    if (opts.webgl) w.HTMLCanvasElement.prototype.getContext = () => ({});
    if (opts.pad) w.eval(fs.readFileSync(PAD, 'utf8'));
    for (const s of SCRIPTS) w.eval(fs.readFileSync(path.join(HUD, s), 'utf8') + `\n//# sourceURL=${s}`);
    const send = (data) => w.dispatchEvent(new w.MessageEvent('message', { data }));
    const $ = (sel) => w.document.querySelector(sel);
    return { w, dom, posts, send, $, errors, doc: w.document };
}

const ICON = 'M12 2c-5.33 4.55-8 8.48-8 11.8 0 4.98 3.8 8.2 8 8.2s8-3.22 8-8.2c0-3.32-2.67-7.25-8-11.8z';
const STATS = [
    { name: 'voice', type: 'custom', max: 100, color: '#a78bfa', icon: ICON, iconRadio: ICON, noCritical: true },
    { name: 'health', type: 'vital', max: 100, color: '#34d399', icon: ICON, heartbeat: true, interruptDelta: 10 },
    { name: 'armour', type: 'vital', max: 100, color: '#818cf8', icon: ICON, hideWhenEmpty: true },
    { name: 'hunger', type: 'need', max: 100, color: '#fb923c', icon: ICON, idleAbove: 95 },
    { name: 'thirst', type: 'need', max: 100, color: '#38bdf8', icon: ICON, idleAbove: 95 },
    { name: 'stress', type: 'custom', max: 100, color: '#f472b6', icon: ICON, showAboveZero: true, noCritical: true, criticalAbove: 85 },
    { name: 'oxygen', type: 'custom', max: 100, color: '#22d3ee', icon: ICON, showBelowFull: true, glide: true },
    { name: 'seatbelt', type: 'flag', max: 1, color: '#ffffff', icon: ICON, showWhenPresent: true, warnWhenOff: true, presentKey: 'beltable' },
    { name: 'cruise', type: 'flag', max: 1, color: '#ffffff', icon: ICON, showWhenPresent: true, onlyWhenOn: true, accentWhenOn: true },
];
const gauge = (p, name) => p.$(`#statusHudStats .sh-stat[data-stat="${name}"]`);
const has = (el, c) => el.classList.contains(c);

// ---- the page itself ----

check('index.html loads the import map first, then the classic scripts in order (no svelte bundle, no old app layout)', () => {
    const map = html.indexOf('type="importmap"');
    ok(map > 0 && map < html.indexOf('<script src='), 'the import map comes before any script');
    ok(/"three": "\.\/js\/vehicle_hud\/vendor\/three\.module\.min\.js"/.test(html), 'three is vendored');
    let at = 0;
    for (const s of SCRIPTS) { const i = html.indexOf(`<script src="${s}">`); ok(i > at, `${s} in order`); at = i; }
    ok(!/index\.js|style\.css|fonts\.googleapis/.test(html), 'nothing from the old page or the internet');
});
check('the manifest ships the page but not the preview, and soft-includes the pad bridge', () => {
    ok(/'html\/js\/vehicle_hud\/\*\.js'/.test(manifest));
    ok(/'html\/css\/\*\.css'/.test(manifest));
    ok(!/preview\.html'/.test(manifest.replace(/--.*$/gm, '')), 'preview.html is not in files');
    ok(!/'html\/\*'/.test(manifest), 'no html/* wildcard (it would ship the preview)');
    ok(/'@pfm-ui\/lib\/pad_bridge\.lua'/.test(manifest));
});
check('no Rockstar material and no WHIP names in pf-hud (it is public)', () => {
    const files = [];
    const walk = (d) => { for (const f of fs.readdirSync(d)) { const p = path.join(d, f); if (f === 'svelte-source' || f === '.github') continue; fs.statSync(p).isDirectory() ? walk(p) : files.push(p); } };
    walk(PF);
    const rel = files.map((f) => path.relative(PF, f).replace(/\\/g, '/'));
    ok(!rel.some((f) => /minimap\.gfx|minimap\.ytd|pfmap_|whipmap|skins3d|dash_skins|rpm_by_model|manufacturers/.test(f)), 'no radar tiles, dash data or the old gfx');
    ok(!rel.some((f) => /whip/i.test(f)), 'no file named after WHIP');
    for (const f of files.filter((x) => /\.(js|lua|css|html)$/.test(x) && !/vendor/.test(x))) {
        const src = fs.readFileSync(f, 'utf8');
        // a provenance path in a header ("Port of whip_core/client/hud.lua") is the licence's notice, not a name
        ok(!/\b(whip_core(?!\/)|whip_media|WhipCost|whipframe|whipring|whipmask|whiphud|cfx-nui-whip)/.test(src), `${path.relative(PF, f)} has no WHIP identifiers`);
        ok(!/[A-Z]:[\\/](fivemserver|pfbc|Users)/i.test(src), `${path.relative(PF, f)} has no local paths`);
    }
    ok(fs.existsSync(path.join(PF, 'COPYING')) && fs.existsSync(path.join(PF, 'COPYING.LESSER')) && fs.existsSync(path.join(PF, 'NOTICE.md')));
    ok(/Copyright 2010-2024 Three\.js Authors/.test(fs.readFileSync(path.join(HUD, 'js/vehicle_hud/vendor/three.module.min.js'), 'utf8').slice(0, 200)), 'three.js keeps its header');
});

// ---- the gauges ----

check('registering builds one gauge per stat with its icon, coloured', () => {
    const p = page();
    p.send({ action: 'registerHudStats', stats: STATS });
    eq(p.doc.querySelectorAll('#statusHudStats .sh-stat').length, 9);
    ok(gauge(p, 'health').querySelector('.sh-icon-normal path').getAttribute('d') === ICON);
    eq(gauge(p, 'health').style.getPropertyValue('--stat-color'), '#34d399');
    ok(gauge(p, 'voice').querySelector('.sh-icon-radio'), 'the radio glyph for talking on the radio');
});
check('an icon that is not an SVG path is not drawn (no markup from a message)', () => {
    const p = page();
    p.send({ action: 'registerHudStats', stats: [{ name: 'x', type: 'custom', max: 100, icon: '"/><img src=x onerror=alert(1)>' }] });
    eq(p.doc.querySelectorAll('#statusHudStats img').length, 0);
    eq(gauge(p, 'x').querySelector('.sh-icon-normal path').getAttribute('d'), '');
});
check('levels: the rim, critical, idle, shown only when it applies', () => {
    const p = page();
    p.send({ action: 'registerHudStats', stats: STATS });
    p.send({ action: 'updateStatusHud', voice: 50, health: 15, armour: 0, hunger: 97, thirst: 40, stress: 0, oxygen: 100 });
    eq(gauge(p, 'health').style.getPropertyValue('--sh-p'), '15');
    ok(has(gauge(p, 'health'), 'critical') && has(gauge(p, 'health'), 'heartbeat'), 'low health beats red');
    ok(has(gauge(p, 'armour'), 'empty'));
    ok(has(gauge(p, 'hunger'), 'idle') && !has(gauge(p, 'thirst'), 'idle'));
    ok(!has(gauge(p, 'stress'), 'visible'), 'no stress, no gauge');
    ok(!has(gauge(p, 'oxygen'), 'visible'), 'full breath, no gauge');
    p.send({ action: 'updateStatusHud', stress: 90, oxygen: 40 });
    ok(has(gauge(p, 'stress'), 'visible') && has(gauge(p, 'stress'), 'critical'), 'high stress is the warning');
    ok(has(gauge(p, 'oxygen'), 'visible'));
    ok(!has(gauge(p, 'voice'), 'critical'), 'a quiet voice is never a warning');
});
check('talking lights the voice gauge; on the radio it is the radio', () => {
    const p = page();
    p.send({ action: 'registerHudStats', stats: STATS });
    p.send({ action: 'setVoiceTalking', talking: true, mode: 'radio' });
    ok(has(gauge(p, 'voice'), 'talking') && has(gauge(p, 'voice'), 'radio'));
    p.send({ action: 'setVoiceTalking', talking: false });
    ok(!has(gauge(p, 'voice'), 'talking'));
});
check('the style setting picks WHIP\'s skin: black (default), classic, minimal', () => {
    const p = page();
    const sh = p.$('#status-hud');
    ok(has(sh, 'skin-black'));
    p.send({ action: 'settings', settings: { hudStyle: 'classic' } });
    ok(!has(sh, 'skin-black'));
    p.send({ action: 'settings', settings: { hudStyle: 'minimal' } });
    ok(has(sh, 'skin-black') && has(sh, 'minimal'));
});

// ---- vehicle mode ----

check('on foot the seatbelt and cruise gauges are away; in a car the belt shows, red until buckled', () => {
    const p = page();
    p.send({ action: 'registerHudStats', stats: STATS });
    p.send({ action: 'updateStatusHud', health: 80, inVehicle: false, seatbelt: false, cruise: false });
    ok(!has(gauge(p, 'seatbelt'), 'visible') && !has(gauge(p, 'cruise'), 'visible'));
    p.send({ action: 'updateStatusHud', inVehicle: true, beltable: true });
    ok(has(gauge(p, 'seatbelt'), 'visible') && has(gauge(p, 'seatbelt'), 'flag-warn'));
    ok(!has(gauge(p, 'cruise'), 'visible'), 'cruise only while it holds the speed');
    p.send({ action: 'updateStatusHud', seatbelt: true, cruise: true });
    ok(!has(gauge(p, 'seatbelt'), 'flag-warn'));
    ok(has(gauge(p, 'cruise'), 'visible') && has(gauge(p, 'cruise'), 'flag-accent'));
    p.send({ action: 'updateStatusHud', beltable: false });
    ok(!has(gauge(p, 'seatbelt'), 'visible'), 'no belt on a bike or a boat');
});

check('without WebGL the dial is the flat one, fed by the same messages', async () => {
    const p = page();
    p.send({ action: 'showStatusHud' });
    p.send({ action: 'vehicleHudConfig', units: 'mph', attitude: 'ball', skins: true, style: 'custom', media: false });
    p.send({ action: 'vehicleDialRange', maxRpm: 8, redline: 6.96, idle: 0.8, dial: true, kind: 'car', skin: false });
    p.send({ action: 'showVehicleHud' });
    await sleep(10);
    const d = p.$('#simpleDial');
    ok(d, 'the flat dial is built');
    ok(has(d, 'on'), 'and shown');
    eq(p.w.PfHudDial.mode(), 'simple');
    ok(!p.$('#vehicleDial'), 'no 3D canvas');
    p.send({ action: 'updateVehicleDials', rpm: 0.6, speed: 100, gear: 4, eng: true, lights: 'high', locked: false, dmg: true });
    eq(d.querySelector('.sd-speed').textContent, '62', 'km/h shown as mph');
    eq(d.querySelector('.sd-gear').textContent, '4');
    ok(d.querySelector('.sd-lights .warn').classList.contains('on'), 'engine damage lights the warning');
    p.send({ action: 'vehicle', show: true, fuel: 12, lowFuel: true, nitro: 0 });
    eq(d.style.getPropertyValue('--sd-fuel'), '12%');
    ok(has(d, 'low-fuel'));
    p.send({ action: 'hideVehicleHud' });
    ok(!has(d, 'on'), 'out of the car it fades');
});

check('aircraft and boats on the flat dial: altitude, power', async () => {
    const p = page();
    p.send({ action: 'showStatusHud' });
    p.send({ action: 'vehicleDialRange', maxRpm: 8, dial: true, kind: 'air', skin: false });
    p.send({ action: 'showVehicleHud' });
    await sleep(10);
    p.send({ action: 'updateVehicleDials', rpm: 0.8, speed: 300, gear: 1, pitch: 5, roll: 10, alt: 100, gearState: 'down' });
    ok(/alt 328 ft/.test(p.$('#simpleDial .sd-unit').textContent), 'the altitude in feet');
    ok(p.$('#simpleDial .sd-lights .lock').classList.contains('on'), 'gear down lights the first light');
    p.send({ action: 'vehicleDialRange', maxRpm: 8, dial: true, kind: 'boat', skin: false });
    p.send({ action: 'updateVehicleDials', rpm: 0.6, speed: 40, gear: 'F', anchored: true });
    eq(p.$('#simpleDial .sd-gear').textContent, 'F');
    eq(p.$('#simpleDial').style.getPropertyValue('--sd-rpm'), '0.500', 'power from the rpm');
});

check('WebGL there but the 3D dial cannot load: the flat one, with a console note', async () => {
    const p = page({ webgl: true });
    const logged = [];
    p.w.console.error = (...a) => logged.push(a.join(' '));
    p.send({ action: 'showStatusHud' });
    p.send({ action: 'vehicleDialRange', maxRpm: 8, dial: true, kind: 'car', skin: false });
    p.send({ action: 'showVehicleHud' });
    await sleep(30);
    eq(p.w.PfHudDial.mode(), 'simple');
    ok(logged.some((l) => /3D dial could not load/.test(l)));
});

check('the dial style "none": nothing; a bicycle (no dial): nothing', async () => {
    const p = page();
    p.send({ action: 'showStatusHud' });
    p.send({ action: 'vehicleHudConfig', units: 'mph', style: 'none' });
    p.send({ action: 'vehicleDialRange', maxRpm: 8, dial: true, kind: 'car' });
    p.send({ action: 'showVehicleHud' });
    await sleep(10);
    ok(!p.$('#simpleDial'));
    p.send({ action: 'vehicleHudConfig', units: 'mph', style: 'pf' });
    p.send({ action: 'vehicleDialRange', maxRpm: 8, dial: false, kind: 'car' });
    await sleep(10);
    ok(!p.$('#simpleDial') || !has(p.$('#simpleDial'), 'on'));
});

check('the dashboard looks are loaded from pfm-media-map only when the client says where it is', () => {
    const p = page();
    p.send({ action: 'vehicleHudConfig', units: 'mph', style: 'custom', media: false });
    eq(p.doc.querySelectorAll('script[src*="dash_skins3d"]').length, 0);
    p.send({ action: 'vehicleHudConfig', units: 'mph', style: 'custom', media: 'https://cfx-nui-pfm-media-map/' });
    eq(p.doc.querySelector('script[src*="dash_skins3d"]').getAttribute('src'), 'https://cfx-nui-pfm-media-map/html/dash_skins3d.js');
    const q = page();
    q.send({ action: 'vehicleHudConfig', units: 'mph', style: 'custom', media: 'javascript:alert(1)//' });
    eq(q.doc.querySelectorAll('script[src*="dash_skins3d"]').length, 0, 'not any URL');
});

// ---- money in the capsule ----

check('money changes show in the capsule (escaped), only while the HUD is up', async () => {
    const p = page();
    p.send({ action: 'registerHudStats', stats: STATS });
    p.send({ action: 'settings', currency: '<b>$</b>', settings: { showMoney: true } });
    p.send({ action: 'money', type: 'cash', amount: 750, minus: false, cash: 3200 });
    ok(has(p.$('#statusHudContainer'), 'mode-stats'), 'hidden HUD: dropped');
    p.send({ action: 'showStatusHud' });
    p.send({ action: 'money', type: 'cash', amount: 750, minus: false, cash: 3200 });
    ok(has(p.$('#statusHudContainer'), 'mode-notify'));
    const t = p.$('#capsuleNotifyText');
    ok(/750/.test(t.textContent) && /3,200/.test(t.textContent));
    eq(t.querySelectorAll('b').length, 0, 'the currency text is escaped');
    p.w.PfHudStatus.notify({ type: 'info', text: 'x', duration: 5 });
});

// ---- placement ----

check('the row lines up under the map\'s frame (black skin), the corner, or the player\'s spot', () => {
    const p = page();
    p.send({ action: 'registerHudStats', stats: STATS });
    p.send({ action: 'hudFrameBox', left: 0.0024, right: 0.1824, bottom: 0.9364, top: 0.7 });
    const wrap = p.$('#statusHudWrapper');
    ok(/px$/.test(wrap.style.left) && /px$/.test(wrap.style.bottom), 'placed under the frame');
    p.send({ action: 'settings', settings: { statusLayout: 'corner' } });
    eq(wrap.style.left, '', 'the corner: the sheet\'s own spot');
    p.send({ action: 'settings', settings: { statusLayout: 'map', layout: { status: { x: 40, y: 50, scale: 1.2 } } } });
    eq(wrap.style.left, '40%');
    eq(wrap.style.top, '50%');
    ok(/scale\(1\.2\)/.test(wrap.style.transform));
});

// ---- the layout editor on a controller ----

check('layout editor: D-pad moves, LB/RB picks, triggers size, A saves (pfm-ui pad.js)', () => {
    const p = page({ pad: true });
    p.send({ action: 'registerHudStats', stats: STATS });
    p.send({ action: 'openMenu', settings: {}, prefsFromUi: true });
    ok(!has(p.$('#menu-backdrop'), 'hidden'), 'the menu opens');
    ok(!has(p.$('#menu-note'), 'hidden'), 'and says the pause menu has these too');
    p.w.PfHudApp.enterEditMode();
    ok(p.posts.some((x) => /\/editMode$/.test(x.url)), 'focus kept for the editor');
    ok(has(p.doc.body, 'editing'));
    const pad = (intent) => p.send({ action: 'pfm-ui:pad', intent });
    pad('right'); pad('right');
    const st = p.w.PfHudApp.settings().layout.status;
    ok(st && typeof st.x === 'number', 'the gauges have a spot of their own now');
    const x1 = st.x;
    pad('right');
    ok(p.w.PfHudApp.settings().layout.status.x > x1, 'right moves right');
    pad('tabNext');
    ok(has(p.$('#dial-proxy'), 'selected'), 'RB picks the dial');
    pad('triggerRight');
    const dial = p.w.PfHudApp.settings().layout.dial;
    ok(dial && Math.abs(dial.scale - 1.05) < 1e-9, 'RT grows it');
    pad('select');
    ok(!has(p.doc.body, 'editing'), 'A is done');
    const save = p.posts.filter((x) => /\/saveSettings$/.test(x.url)).pop();
    ok(save && save.body.layout.dial.scale > 1, 'saved with the new layout');
    ok(p.posts.some((x) => /\/closeMenu$/.test(x.url)));
});
check('layout editor: B cancels and puts everything back', () => {
    const p = page({ pad: true });
    p.w.PfHudApp.enterEditMode();
    p.send({ action: 'pfm-ui:pad', intent: 'down' });
    ok(p.w.PfHudApp.settings().layout.status);
    p.send({ action: 'pfm-ui:pad', intent: 'back' });
    eq(p.w.PfHudApp.settings().layout.status, null);
    ok(!p.posts.some((x) => /\/saveSettings$/.test(x.url)), 'nothing saved');
});

// ---- the radar tuner ----

check('the radar tuner renders its components, clamps typed values, and saves on request', () => {
    const p = page();
    const comps = ['minimap', 'minimap_mask', 'minimap_blur', 'bigmap', 'bigmap_mask', 'bigmap_blur', 'golf_courses', 'frame'].map((key) => ({
        key, label: key, note: '', posX: 0, posY: 0, sizeX: 0.2, sizeY: 0.2, alignX: 'L', alignY: 'B', managed: true, colour: [1, 2, 3],
        ...(key === 'frame' ? { corner: 1, fields: ['posX', 'posY', 'sizeX', 'sizeY', 'corner'], noAlign: true } : {}),
    }));
    p.send({ action: 'radarTunerOpen', data: { components: comps, opts: { clipType: 0 } } });
    ok(!has(p.$('#radar-tuner'), 'rd-hidden'));
    eq(p.doc.querySelectorAll('.rd-comp').length, 8);
    const num = p.doc.querySelector('.rd-comp .rd-row input[type=number]');
    num.value = '-9';
    num.dispatchEvent(new p.w.Event('change'));
    const set = p.posts.filter((x) => /radarTunerSet$/.test(x.url)).pop();
    eq(set.body.posX, -1, 'clamped on the page too');
    p.$('#rd-save').click();
    ok(p.posts.some((x) => /radarTunerSave$/.test(x.url)));
    p.send({ action: 'radarTunerClose' });
    ok(has(p.$('#radar-tuner'), 'rd-hidden'));
});

check('the page asks the client for everything once it is up', () => {
    const p = page();
    ok(p.posts.some((x) => /\/ready$/.test(x.url)));
    eq(p.errors.length, 0, 'no script errors: ' + p.errors.join('; '));
});

Promise.all(pending).then(() => {
    console.log(`\n${passed} passed, ${failed} failed (pf-hud page)`);
    if (failed) { failures.forEach((f) => console.log('  - ' + f)); process.exit(1); }
});
