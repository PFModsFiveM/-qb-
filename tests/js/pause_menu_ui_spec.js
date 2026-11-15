// pfm-pause page (html/index.html + js/*.js, a port of WHIP's pause menu): the menu renders from Lua's list
// (an item off with its note), the brand mark in the logo's place, select/back with keys and pad intents, Quit
// and Swap through Lua's token, the map mode and its legend, sliding to Server Settings that renders a pfm-ui
// pref list (grouped, a change posted), the Controller screen drawing a layout (a change posted), Help (rules,
// keys, report). jsdom has no WebGL and loads no scripts: the 3D map never starts, and the page must work without
// it (blips still placed, the failure logged, nothing thrown).
// The page is ES modules; jsdom cannot run those, so they are joined here into one script (imports and
// exports rewritten), in dependency order.
// Run: node js/pause_menu_ui_spec.js
const fs = require('fs');
const path = require('path');
const { JSDOM, VirtualConsole } = require('jsdom');

const HTML = path.resolve(__dirname, '..', '..', 'pfm-pause', 'html');
const ORDER = ['router', 'utils', 'pad-cursor', 'pad-glyphs', 'prefs', 'blip-names', 'logo-light', 'pause-map',
    'settings-page', 'pad-layout', 'help-page', 'pause', 'main'];

/** One classic script from the page's modules: each in its own function, its exports in __m[name]. */
function bundle() {
    let out = 'const __m = {};\n';
    for (const name of ORDER) {
        let src = fs.readFileSync(path.join(HTML, 'js', name + '.js'), 'utf8');
        const exported = [];
        src = src.replace(/^import\s+\{([^}]*)\}\s+from\s+'\.\/([\w-]+)\.js';?/gm, (_, list, from) =>
            'const { ' + list.split(',').map((x) => x.trim()).filter(Boolean)
                .map((x) => x.replace(/^(\w+)\s+as\s+(\w+)$/, '$1: $2')).join(', ') + ` } = __m['${from}'];`);
        src = src.replace(/^import\s+'\.\/([\w-]+)\.js';?/gm, '');
        src = src.replace(/^export\s+(async\s+function|function|class|const|let)\s+(\w+)/gm, (_, kind, id) => {
            exported.push(id);
            return kind + ' ' + id;
        });
        if (/^\s*(import|export)\s/m.test(src)) throw new Error(name + ': an import/export the bundler does not know');
        out += `__m['${name}'] = (function () {\n${src}\nreturn { ${exported.join(', ')} };\n})();\n`;
    }
    return out;
}
const BUNDLE = bundle();
const GLYPHS = fs.readFileSync(path.join(HTML, 'js', 'glyphs.js'), 'utf8');

let passed = 0;
let failed = 0;
const failures = [];
let pages = [];
async function it(name, fn) {
    pages = [];
    try {
        await fn();
        const errors = pages.flatMap((p) => p.errors);
        if (errors.length) throw new Error(`script errors: ${errors.map((e) => e.stack || e.message).join('; ')}`);
        passed++;
    } catch (e) { failed++; failures.push(`${name}: ${e && e.stack || e}`); }
}
function eq(a, b, msg) { if (a !== b) throw new Error(`${msg || 'expected'}: ${JSON.stringify(b)}, got ${JSON.stringify(a)}`); }
function ok(v, msg) { if (!v) throw new Error(msg || 'expected truthy'); }
const tick = (ms = 0) => new Promise((r) => setTimeout(r, ms));
const settle = async () => { for (let i = 0; i < 6; i++) await tick(2); };

const PREFS_STATE = {
    groups: [
        { id: 'Controller', label: 'Controller', rows: [
            { key: 'pad.enabled', type: 'toggle', label: 'Controller support', help: 'Menus answer a gamepad.', value: true, default: true },
            { key: 'pad.repeatDelay', type: 'slider', label: 'Menu repeat delay', min: 150, max: 1000, step: 10, value: 380, default: 380 },
        ] },
        { id: 'HUD', label: 'HUD', rows: [
            { key: 'hud.style', type: 'choice', label: 'HUD style', value: 'square', default: 'round', changed: true,
              options: [{ value: 'round', label: 'Round' }, { value: 'square', label: 'Square' }] },
            { key: 'hud.locked', type: 'toggle', label: 'Locked thing', value: false, default: false, locked: true },
        ] },
    ],
};

const PAD_STATE = {
    actions: [{ id: 'phone', label: 'Phone', on: true }, { id: 'radial', label: 'Radial menu', on: true },
        { id: 'target', label: 'Target / interact', on: true }],
    layout: { dpad_up: 'phone', dpad_down: 'radial', lb: 'target' },
    custom: false,
};

function makePage({ replies = {} } = {}) {
    const errors = [];
    const logged = [];
    const vc = new VirtualConsole();
    vc.on('jsdomError', (e) => { if (!/Not implemented|Could not load/.test(String(e && e.message))) errors.push(e); });
    vc.on('error', (...a) => logged.push(a.map(String).join(' ')));
    const body = fs.readFileSync(path.join(HTML, 'index.html'), 'utf8')
        .replace(/<script[\s\S]*?<\/script>/g, '').replace(/<link[^>]*>/g, '');
    const dom = new JSDOM(body, { runScripts: 'dangerously', pretendToBeVisual: true, url: 'https://cfx-nui-pfm-pause/html/index.html', virtualConsole: vc });
    const win = dom.window;
    const posts = [];
    win.GetParentResourceName = () => 'pfm-pause';
    win.fetch = (url, opts) => {
        const name = String(url).replace(/^https:\/\/[^/]+\//, '');
        const data = opts && opts.body ? JSON.parse(opts.body) : null;
        posts.push({ name, body: data });
        const r = replies[name];
        const out = typeof r === 'function' ? r(data) : (r || {});
        return Promise.resolve({ json: async () => out });
    };
    win.HTMLElement.prototype.scrollIntoView = function () {};
    win.HTMLCanvasElement.prototype.getContext = function () { return null; };   // no canvas, no WebGL
    for (const src of [GLYPHS, BUNDLE]) {
        const el = win.document.createElement('script');
        el.textContent = src;
        win.document.body.appendChild(el);
    }
    const message = (data) => win.dispatchEvent(new win.MessageEvent('message', { data }));
    const key = (k, extra = {}) => win.document.dispatchEvent(new win.KeyboardEvent('keydown', Object.assign({ key: k, bubbles: true }, extra)));
    const $ = (sel) => win.document.querySelector(sel);
    const $$ = (sel) => [...win.document.querySelectorAll(sel)];
    const page = { win, posts, errors, logged, message, key, $, $$, doc: win.document, posted: (n) => posts.filter((p) => p.name === n) };
    pages.push(page);
    return page;
}

const MENU = [
    { id: 'resume', label: 'Resume' }, { id: 'map', label: 'Map' }, { id: 'controller', label: 'Controller' },
    { id: 'swap', label: 'Swap Character', disabled: true, note: 'The character screen is not available right now.' },
    { id: 'gameSettings', label: 'Game Settings' }, { id: 'serverSettings', label: 'Server Settings' },
    { id: 'help', label: 'Help' }, { id: 'quit', label: 'Quit' },
];

async function open(page, extra = {}) {
    page.message(Object.assign({
        action: 'pauseOpen', brand: 'PF', menu: MENU, quitMode: 'disconnect', pad: false,
        character: { name: 'Jane Doe', job: 'Police · Sergeant' },
        help: {
            rules: ['Be kind', 'No RDM'],
            keybinds: [['Pause menu', 'Esc / P', 'Start'], ['Emote menu', 'F3', 'LB + Y']],
            quick: [{ id: 'hud', label: 'HUD settings' }],
            report: { min: 8, max: 300 },
        },
    }, extra));
    page.message({ action: 'pauseData', player: { x: 100, y: -200, heading: 90, zone: 'Strawberry', street: 'Strawberry Ave' },
        waypoint: false, route: false, routeColour: '#a44cf2',
        blips: [{ x: 25, y: -1347, sprite: 52, colour: '#ffffff' }, { x: 30, y: -1300, sprite: 52, colour: '#ffffff' },
            { x: -70, y: -1760, sprite: 361, colour: '#ff9900' }] });
    await tick(40);   // the open lays the menu out on the next frame
    await settle();
}

const items = (page) => page.$$('.pm-item');
const selected = (page) => { const el = page.$('.pm-item.on'); return el && el.textContent; };
const mode = (page) => page.$('#pause').dataset.mode;

async function goTo(page, label) {
    let guard = 0;
    while (selected(page) !== label && guard++ < 20) page.key('ArrowDown');
    eq(selected(page), label, 'reached ' + label);
    page.key('Enter');
    await settle();
}

(async () => {
    await it('the menu renders from Lua\'s list, with the brand mark and where the player is', async () => {
        const page = makePage();
        await open(page);
        ok(page.$('#pause').classList.contains('open'), 'shown');
        eq(items(page).map((e) => e.textContent).join('|'),
            'Resume|Map|Controller|Swap Character|Game Settings|Server Settings|Help|Quit');
        eq(selected(page), 'Resume', 'Resume first');
        eq(page.$('.pm-logo .ld-word').textContent, 'PF', 'our wordmark');
        eq(page.$$('.pm-logo .ld-dot').length, 4, 'the light\'s four circles');
        eq(page.$('.pm-zone').textContent, 'Strawberry');
        eq(page.$('.pm-street').textContent, 'Strawberry Ave');
        ok(page.$('.pm-char').textContent.includes('Jane Doe'), 'the character');
        ok(page.$$('.pm-item')[3].classList.contains('pm-item-off'), 'swap off');
        ok(!/whip/i.test(page.$('#pause').outerHTML + page.$('#pad-hints').outerHTML), 'no WHIP name anywhere in the UI');
        await open(page, { brand: 'City<RP>' });
        eq(page.$('.pm-logo .ld-word').textContent, 'City<RP>', 'brand from config, as text');
    });

    await it('select and back: keys and pad intents, an off item shows its note and does nothing', async () => {
        const page = makePage();
        await open(page);
        page.key('ArrowDown');
        eq(selected(page), 'Map');
        page.message({ action: 'pad', intent: 'down' });
        eq(selected(page), 'Controller');
        page.message({ action: 'pad', intent: 'down' });
        eq(selected(page), 'Swap Character');
        ok(page.$('.pm-note').textContent.includes('not available'), 'the note');
        page.key('Enter');
        eq(mode(page), 'menu', 'an off item does nothing');
        page.message({ action: 'pad', intent: 'up' });
        page.message({ action: 'pad', intent: 'up' });
        page.message({ action: 'pad', intent: 'up' });
        eq(selected(page), 'Resume');
        page.key('Enter');
        await settle();
        eq(page.posted('pauseResume').length, 1, 'Resume asks Lua to close');
        page.key('Escape');
        await settle();
        eq(page.posted('pauseResume').length, 2, 'Escape resumes');
        page.message({ action: 'pad', intent: 'back' });
        await settle();
        eq(page.posted('pauseResume').length, 3, 'B resumes');
        await goTo(page, 'Game Settings');
        eq(page.posted('pauseSettings').length, 1, 'GTA\'s settings');
    });

    await it('Quit asks, and leaves only with Lua\'s token; Stay cancels', async () => {
        const page = makePage({ replies: { leave: (d) => ({ ok: true, token: 'tok-' + d.mode }) } });
        await open(page);
        await goTo(page, 'Quit');
        eq(mode(page), 'confirm');
        eq(page.$('.pm-confirm-q').textContent, 'Leave the server?');
        eq(page.posted('leave')[0].body.mode, 'disconnect');
        page.key('ArrowLeft');      // onto Leave
        page.key('Enter');
        await settle();
        eq(page.posted('leaveConfirm').length, 1);
        eq(page.posted('leaveConfirm')[0].body.token, 'tok-disconnect');
        // again, and stay
        page.key('Escape');
        await settle();
        await goTo(page, 'Quit');
        page.key('Escape');
        await settle();
        eq(mode(page), 'menu');
        eq(page.posted('leaveCancel').length >= 1, true, 'the question is dropped in Lua too');
    });

    await it('a refused question cannot be confirmed (Lua said why)', async () => {
        const menu = MENU.map((m) => (m.id === 'swap' ? { id: 'swap', label: 'Swap Character' } : m));
        const page = makePage({ replies: { leave: { ok: false, why: 'Not while you are down.' } } });
        await open(page, { menu });
        await goTo(page, 'Swap Character');
        eq(mode(page), 'confirm');
        eq(page.$('.pm-confirm-sub').textContent, 'Not while you are down.');
        ok(page.$$('.pm-confirm .pm-btn')[0].disabled, 'Swap is off');
        page.key('ArrowLeft');
        page.key('Enter');
        await settle();
        eq(page.posted('leaveConfirm').length, 0);
    });

    await it('the map: its mode, blips placed without WebGL, the legend, waypoint posting, back', async () => {
        const page = makePage();
        await open(page);
        eq(page.$$('.pmap-blip:not(.pmap-waypoint)').length, 3, 'blips placed with no 3D map');
        // the 3D map's data never loads here: its script failing is logged, nothing throws
        const s = [...page.doc.querySelectorAll('script')].find((x) => /map3d-data\.js$/.test(x.src || ''));
        ok(s, 'the map data is asked for from pfm-media-map');
        ok(s.src.startsWith('https://cfx-nui-pfm-media-map/'), 'from the media resource');
        s.dispatchEvent(new page.win.Event('error'));
        await settle();
        ok(page.logged.some((l) => /3D map did not start/.test(l)), 'the failure is logged');
        await goTo(page, 'Map');
        eq(mode(page), 'map');
        page.key('l');
        await settle();
        ok(page.$('#pause').classList.contains('pm-legend-open'), 'legend open');
        const rows = page.$$('.pm-legend-row');
        eq(rows.length, 2, 'two kinds of blip');
        ok(rows.some((r) => /Store/.test(r.textContent) && /2/.test(r.textContent)), 'stores, counted');
        // a pad's A on the map sets the waypoint at the centre
        page.message({ action: 'pad', intent: 'select' });
        await settle();
        const wp = page.posted('pauseWaypoint');
        eq(wp.length, 1, 'waypoint posted');
        ok(typeof wp[0].body.x === 'number' && typeof wp[0].body.y === 'number', 'a world point');
        // the sticks drive it without errors
        page.message({ action: 'padAnalog', x: 0.5, y: 0, lt: 0, rt: 0.5, rx: 0, ry: 0 });
        await settle();
        page.message({ action: 'padAnalog', x: 0, y: 0, lt: 0, rt: 0, rx: 0, ry: 0 });
        page.key('Escape');
        await settle();
        eq(mode(page), 'menu', 'Escape back to the menu');
        ok(page.posted('navScope').some((p) => p.body.analog === true), 'Lua told the map wants the sticks');
    });

    await it('Server Settings slides in and renders pfm-ui\'s prefs; a change is posted', async () => {
        const page = makePage({ replies: { prefsState: PREFS_STATE, prefsSet: PREFS_STATE } });
        await open(page);
        await goTo(page, 'Server Settings');
        eq(mode(page), 'settings');
        eq(page.posted('prefsState').length, 1);
        await settle();
        const tabs = page.$$('.pm-st .st-nav').map((b) => b.textContent.trim());
        eq(tabs.join('|'), 'Controller|HUD');
        const rows = page.$$('.pm-st .st-row');
        eq(rows.length, 2);
        ok(rows[0].textContent.includes('Controller support') && rows[0].textContent.includes('On'), 'toggle as On');
        ok(rows[1].textContent.includes('380'), 'slider value');
        page.key('ArrowLeft');      // the toggle: On -> Off
        await settle();
        eq(page.posted('prefsSet').length, 1);
        eq(page.posted('prefsSet')[0].body.key, 'pad.enabled');
        eq(page.posted('prefsSet')[0].body.value, false);
        page.key('e');              // next tab
        await settle();
        const hud = page.$$('.pm-st .st-row');
        ok(hud[1].classList.contains('off'), 'forced row locked');
        ok(hud[1].textContent.includes('Disabled by server admin'));
        page.key('Escape');
        await settle();
        eq(mode(page), 'menu');
    });

    await it('the Controller screen draws pfm-ui\'s layout and posts a change', async () => {
        const after = JSON.parse(JSON.stringify(PAD_STATE));
        after.layout.dpad_up = 'radial'; after.layout.dpad_down = 'phone'; after.custom = true;
        after.swap = { slot: 'dpad_down', gave: 'phone' };
        const page = makePage({ replies: { padLayout: PAD_STATE, padLayoutSet: after } });
        await open(page);
        await goTo(page, 'Controller');
        eq(mode(page), 'pad');
        await settle();
        const label = (id) => page.$(`.pl-label[data-btn="${id}"] .pl-main`).textContent;
        eq(label('dpad_up'), 'Phone');
        eq(label('dpad_down'), 'Radial menu');
        eq(label('lb'), 'Target / interact');
        eq(label('rt'), 'Shoot', 'GTA\'s own');
        eq(page.$('.pl-status').textContent, 'Server default');
        // choose D-pad up, then Radial menu
        let guard = 0;
        while (page.$('.pl-label.on') && page.$('.pl-label.on').dataset.btn !== 'dpad_up' && guard++ < 20) page.key('ArrowDown');
        eq(page.$('.pl-label.on').dataset.btn, 'dpad_up');
        page.key('Enter');
        const chips = page.$$('.pl-chip');
        ok(chips.length === 4, 'three actions and Nothing');
        page.key('ArrowRight');
        page.key('Enter');
        await settle();
        eq(page.posted('padLayoutSet').length, 1);
        eq(page.posted('padLayoutSet')[0].body.slot, 'dpad_up');
        eq(page.posted('padLayoutSet')[0].body.action, 'radial');
        eq(label('dpad_up'), 'Radial menu');
        eq(page.$('.pl-status').textContent, 'Your layout');
        ok(/D-pad down has Phone/.test(page.$('.pl-what-sub').textContent), 'the swap is said');
        page.key('Escape');
        await settle();
        eq(mode(page), 'menu');
    });

    await it('Help: rules, keys with pad glyphs, a report sent through Lua', async () => {
        const page = makePage({ replies: { report: { ok: true } } });
        await open(page);
        await goTo(page, 'Help');
        eq(mode(page), 'help');
        eq(page.$$('.pm-help .st-nav').map((b) => b.textContent.trim()).join('|'), 'Rules|Keys|Shortcuts|Report a problem');
        eq(page.$$('.pm-help .st-row').length, 2, 'two rules');
        page.key('e');
        await settle();
        const keyRows = page.$$('.pm-help .st-row');
        ok(keyRows[1].querySelectorAll('img').length === 2, 'LB + Y as two glyphs');
        page.key('e'); page.key('e');
        await settle();
        const box = page.$('.pm-help .hp-text');
        ok(box, 'the report box');
        box.value = 'Car stuck under the map near Legion';
        page.$('.pm-help [data-act="send"]').click();
        await settle();
        eq(page.posted('report').length, 1);
        eq(page.posted('report')[0].body.message, 'Car stuck under the map near Legion');
        ok(/Sent/.test(page.$('.pm-help .hp-result').textContent));
        page.key('Escape');
        await settle();
        eq(mode(page), 'menu');
    });

    await it('close hides it and puts everything back', async () => {
        const page = makePage({ replies: { prefsState: PREFS_STATE } });
        await open(page);
        await goTo(page, 'Server Settings');
        page.message({ action: 'pauseClose' });
        await settle();
        ok(!page.$('#pause').classList.contains('open'), 'hidden');
        eq(mode(page), 'menu');
        page.message({ action: 'device', pad: true });
        eq(page.doc.documentElement.dataset.input, 'pad');
    });

    console.log(`${passed} passed, ${failed} failed`);
    for (const f of failures) console.log('FAIL ' + f);
    process.exit(failed ? 1 : 0);
})();
