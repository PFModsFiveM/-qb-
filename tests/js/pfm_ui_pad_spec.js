// pfm-ui's page library (pfm-ui/html/pad.js) in jsdom: intents arrive as { action: 'pfm-ui:pad' }
// messages; default spatial navigation moves a focus ring, select clicks (or focuses a text field),
// back runs the page's close handler, left/right change numbers and lists, body.pfm-pad follows the
// device; glyphs are drawn. Then the converted pages: pfm-menu, pfm-input and pfm-target answer a pad
// and still work by keyboard. Run: node js/pfm_ui_pad_spec.js
const fs = require('fs');
const path = require('path');
const { JSDOM } = require('jsdom');

const QB = path.resolve(__dirname, '..', '..');
const PAD_JS = fs.readFileSync(path.join(QB, 'pfm-ui/html/pad.js'), 'utf8');
const PAD_CSS = fs.readFileSync(path.join(QB, 'pfm-ui/html/pad.css'), 'utf8');

let passed = 0, failed = 0;
const failures = [];
function check(name, fn) { try { fn(); passed++; } catch (e) { failed++; failures.push(`${name}: ${e && e.stack || e}`); } }
function eq(a, b, m) { if (a !== b) throw new Error(`${m || ''} expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`); }
function ok(v, m) { if (!v) throw new Error(m || 'expected truthy'); }

function stripExternal(html) {
    return html.replace(/<script[^>]*src="[^"]*"[^>]*><\/script>/g, '').replace(/<link[^>]*>/g, '');
}

function boot(html, url) {
    const dom = new JSDOM(html, { runScripts: 'outside-only', url: url || 'https://cfx-nui-test/index.html', pretendToBeVisual: true });
    const w = dom.window;
    w.HTMLElement.prototype.scrollIntoView = function () {};
    w.eval(PAD_JS);
    const pad = (intent, extra) => w.dispatchEvent(new w.MessageEvent('message', { data: Object.assign({ action: 'pfm-ui:pad', intent }, extra) }));
    const device = (on) => w.dispatchEvent(new w.MessageEvent('message', { data: { action: 'pfm-ui:device', pad: on } }));
    return { w, d: w.document, pad, device };
}

/** Gives elements a layout (jsdom has none): rects by id. */
function place(w, rects) {
    for (const [id, r] of Object.entries(rects)) {
        const el = w.document.getElementById(id);
        el.getBoundingClientRect = () => ({ left: r[0], top: r[1], width: r[2], height: r[3], right: r[0] + r[2], bottom: r[1] + r[3] });
    }
}

const ring = (d) => { const el = d.querySelector('.pfm-pad-focus'); return el && el.id; };

// ── the library ─────────────────────────────────────────────────────────────

const GRID = `<!doctype html><html><head><style>${PAD_CSS} .gone{display:none}</style></head><body>
<div id="panel">
  <button id="a">A</button><button id="b">B</button>
  <button id="c">C</button><button id="d">D</button>
  <button id="e" disabled>E</button><button id="f" class="gone">F</button>
  <div id="g" data-pad>G</div>
</div><button id="outside">out</button></body></html>`;

check('spatial navigation moves the ring by layout, skipping disabled and hidden controls', () => {
    const { w, d, pad } = boot(GRID);
    // a b
    // c d      g is far below; e (disabled) and f (hidden) sit where they would be picked
    place(w, { a: [0, 0, 50, 20], b: [100, 0, 50, 20], c: [0, 50, 50, 20], d: [100, 50, 50, 20],
               e: [0, 100, 50, 20], f: [100, 100, 50, 20], g: [0, 300, 50, 20], outside: [0, 25, 50, 20] });
    w.PfmPad.focusables(d.getElementById('panel'));
    pad('down');
    eq(ring(d), 'a', 'first press picks the first control');
    pad('right'); eq(ring(d), 'b');
    pad('down'); eq(ring(d), 'd');
    pad('left'); eq(ring(d), 'c');
    pad('down'); eq(ring(d), 'g', 'disabled e is skipped');
    pad('down'); eq(ring(d), 'g', 'nothing further: stays');
    pad('up'); eq(ring(d), 'c');
    eq(d.querySelectorAll('.pfm-pad-focus').length, 1, 'one ring at a time');
});

check('select clicks the control; back runs the page close handler', () => {
    const { w, d, pad } = boot(GRID);
    let clicked = '', closed = 0;
    d.getElementById('panel').addEventListener('click', (e) => { clicked += e.target.id; });
    w.PfmPad.focusables(d.getElementById('panel'), { onBack: () => closed++ });
    pad('select');
    eq(clicked, '', 'the first select only shows the ring');
    eq(ring(d), 'a');
    pad('select');
    eq(clicked, 'a');
    pad('back');
    eq(closed, 1);
});

check('without layout it falls back to DOM order; list mode wraps', () => {
    const { w, d, pad } = boot(GRID);
    w.PfmPad.focusables(d.getElementById('panel'), { mode: 'list', wrap: true });
    pad('down'); pad('down'); eq(ring(d), 'b');
    pad('up'); pad('up'); eq(ring(d), 'g', 'wraps to the last');
    pad('right'); eq(ring(d), 'g', 'left/right do not move in a list');
});

check('body.pfm-pad follows the device and the first intent', () => {
    const { d, pad, device, w } = boot(GRID);
    let heard = [];
    w.PfmPad.onDevice((on) => heard.push(on));
    eq(d.body.classList.contains('pfm-pad'), false);
    device(true);
    eq(d.body.classList.contains('pfm-pad'), true);
    device(false);
    eq(d.body.classList.contains('pfm-pad'), false);
    pad('up');
    eq(d.body.classList.contains('pfm-pad'), true, 'an intent means a pad');
    eq(w.PfmPad.isActive(), true);
    eq(heard.join(','), 'true,false,true');
});

check('page handlers run first (newest first); returning false falls through to the default', () => {
    const { w, d, pad } = boot(GRID);
    w.PfmPad.focusables(d.getElementById('panel'));
    const seen = [];
    w.PfmPad.on('down', () => { seen.push('old'); });
    const off = w.PfmPad.on('down', () => { seen.push('new'); return false; });
    pad('down');
    eq(seen.join(','), 'new,old', 'old handled it: no default move');
    eq(ring(d), null);
    off();
    w.PfmPad.on('up', () => false);
    pad('up');
    eq(ring(d), 'a', 'fell through to the default');
});

check('back with no handler and no panel sends Escape to the page', () => {
    const { d, pad } = boot(GRID);
    const keys = [];
    d.addEventListener('keydown', (e) => keys.push('down:' + e.key));
    d.addEventListener('keyup', (e) => keys.push('up:' + e.key));
    pad('back');
    eq(keys.join(','), 'down:Escape,up:Escape');
});

const FORM = `<!doctype html><html><body><form id="f">
<input id="t" type="text" name="t"><input id="n" type="number" name="n" value="5" min="0" max="6">
<select id="s" name="s"><option value="x">x</option><option value="y">y</option></select>
<label id="l" class="choice"><input id="cb" type="checkbox" value="v"><span>v</span></label>
<button id="go" type="submit">Go</button></form></body></html>`;

check('select focuses a text field; left/right change numbers and lists; a label toggles its checkbox', () => {
    const { w, d, pad } = boot(FORM);
    const changes = [];
    d.getElementById('f').addEventListener('change', (e) => changes.push(e.target.id + '=' + (e.target.type === 'checkbox' ? e.target.checked : e.target.value)));
    w.PfmPad.focusables(d.getElementById('f'), { selector: 'input:not([type=checkbox]), select, label.choice, button', autoFocus: true });
    pad('select');                                   // ring to the text field
    pad('select');
    eq(d.activeElement.id, 't', 'the text field has the keyboard');
    pad('down'); eq(ring(d), 'n');
    eq(d.activeElement.id === 't', false, 'moving away gives the keyboard focus back');
    pad('right'); pad('right');
    eq(d.getElementById('n').value, '6', 'stops at max');
    pad('left');
    eq(d.getElementById('n').value, '5');
    pad('down'); eq(ring(d), 's');
    pad('right');
    eq(d.getElementById('s').value, 'y');
    pad('down'); eq(ring(d), 'l');
    pad('select');
    eq(d.getElementById('cb').checked, true);
    eq(changes.join(' '), 'n=6 n=6 n=5 s=y cb=true');
    let submitted = 0;
    d.getElementById('f').addEventListener('submit', (e) => { e.preventDefault(); submitted++; });
    pad('down'); eq(ring(d), 'go');
    pad('select');
    eq(submitted, 1, 'A on the button submits the form');
});

check('glyphs: generic drawings for intents and button names; hints render', () => {
    const { w, d } = boot(GRID);
    const a = w.PfmPad.glyph('select');
    ok(a && a.classList.contains('pfm-pad-glyph') && a.classList.contains('pfm-pad-glyph-a'));
    ok(a.querySelector('svg text').textContent === 'A');
    ok(w.PfmPad.glyph('tabNext').classList.contains('pfm-pad-glyph-rb'));
    ok(w.PfmPad.glyph('up').querySelector('svg'));
    eq(w.PfmPad.glyph('nope'), null);
    ok(!/whip/i.test(w.PfmPad.glyphHTML('back')));
    const box = d.createElement('div');
    d.body.appendChild(box);
    w.PfmPad.hints(box, [['select', 'Choose'], [['lb', 'y'], 'Emotes']]);
    eq(box.classList.contains('pfm-pad-hints'), true);
    eq(box.querySelectorAll('.pfm-pad-hint').length, 2);
    eq(box.querySelectorAll('.pfm-pad-glyph').length, 3);
    ok(box.textContent.includes('Choose'));
});

check('pad.css shows the ring and hints only while a pad is the device', () => {
    ok(/\.pfm-pad \.pfm-pad-focus\s*\{[^}]*outline/.test(PAD_CSS));
    ok(/\.pfm-pad-hints\s*\{\s*display:\s*none/.test(PAD_CSS));
    ok(/var\(--pfm-focus-ring/.test(PAD_CSS));
});

// ── converted pages ─────────────────────────────────────────────────────────

function bootPage(dir, htmlFile, jsFiles, resource) {
    const html = fs.readFileSync(path.join(QB, dir, htmlFile), 'utf8');
    ok(html.includes('https://cfx-nui-pfm-ui/html/pad.js'), `${dir} loads pad.js`);
    const page = boot(stripExternal(html), `https://cfx-nui-${resource}/index.html`);
    const posts = [];
    page.w.GetParentResourceName = () => resource;
    page.w.fetch = (url, opts) => { posts.push({ url: String(url), body: opts && opts.body }); return Promise.resolve({ json: async () => ({}) }); };
    for (const f of jsFiles) page.w.eval(fs.readFileSync(path.join(QB, dir, f), 'utf8'));
    page.posts = posts;
    page.send = (data) => page.w.dispatchEvent(new page.w.MessageEvent('message', { data }));
    return page;
}

check('pfm-menu: D-pad moves the same highlight as the arrows, A picks, B closes', () => {
    const p = bootPage('pfm-menu/html', 'index.html', ['script.js'], 'pfm-menu');
    p.send({ action: 'OPEN_MENU', data: [{ header: 'Title', isMenuHeader: true }, { header: 'One' }, { header: 'Off', disabled: true }, { header: 'Two' }] });
    p.pad('down');
    eq(p.d.querySelector('.kb-focus').id, '1');
    p.pad('down');
    eq(p.d.querySelector('.kb-focus').id, '3', 'disabled entries are skipped');
    p.pad('down');
    eq(p.d.querySelector('.kb-focus').id, '3', 'stays on the last');
    p.pad('up');
    p.pad('select');
    eq(p.posts.length, 1);
    ok(p.posts[0].url.endsWith('/clickedButton'));
    eq(p.posts[0].body, '2');
    p.send({ action: 'OPEN_MENU', data: [{ header: 'One' }] });
    p.pad('back');
    ok(p.posts[1].url.endsWith('/closeMenu'));
    // keyboard unchanged
    p.send({ action: 'OPEN_MENU', data: [{ header: 'One' }, { header: 'Two' }] });
    p.d.dispatchEvent(new p.w.KeyboardEvent('keydown', { key: 'ArrowDown' }));
    p.d.dispatchEvent(new p.w.KeyboardEvent('keydown', { key: 'Enter' }));
    eq(p.posts[2].body, '1');
});

(function () {
    const p = bootPage('pfm-input/html', 'index.html', ['script.js'], 'pfm-input');
    p.device(true);
    p.send({ action: 'OPEN_MENU', data: { header: 'Form', submitText: 'OK', inputs: [
        { type: 'text', name: 'who', text: 'Name' },
        { type: 'number', name: 'amount', text: 'Amount', default: 2 },
        { type: 'select', name: 'kind', text: 'Kind', options: [{ value: 'a', text: 'A' }, { value: 'b', text: 'B' }] },
        { type: 'checkbox', name: 'opts', text: 'Opts', options: [{ value: 'fast', text: 'Fast' }] },
    ] } });
    check('pfm-input: the ring starts on the first field and hints are drawn', () => {
        const r = p.d.querySelector('.pfm-pad-focus');
        ok(r && r.name === 'who');
        const hints = p.d.querySelector('.pad-hints');
        ok(hints.classList.contains('pfm-pad-hints'));
        ok(hints.textContent.includes('Typing needs a keyboard'));
    });
    check('pfm-input: left/right change the number and the list, A toggles the checkbox, A on the button submits', () => {
        p.pad('down');                  // amount
        p.pad('right'); p.pad('right');
        p.pad('down');                  // kind
        p.pad('right');
        p.pad('down');                  // the checkbox label
        p.pad('select');
        p.pad('down');                  // the button
        eq(p.d.querySelector('.pfm-pad-focus').id, 'submit');
        p.pad('select');
        eq(p.posts.length, 1);
        ok(p.posts[0].url.endsWith('/buttonSubmit'));
        const data = JSON.parse(p.posts[0].body).data;
        eq(data.amount, '4');
        eq(data.kind, 'b');
        eq(data.fast, 'true');
    });
    check('pfm-input: B cancels the form', () => {
        p.send({ action: 'OPEN_MENU', data: { header: 'F', inputs: [{ type: 'text', name: 'x', text: 'X' }] } });
        p.pad('back');
        ok(p.posts[p.posts.length - 1].url.endsWith('/closeMenu'));
    });
})();

check('pfm-target: up/down move through the options, A selects one, B closes', () => {
    const p = bootPage('pfm-target/html', 'index.html', [], 'pfm-target');
    p.w.eval(fs.readFileSync(path.join(QB, 'pfm-target/html/js/app.js'), 'utf8'));
    p.d.dispatchEvent(new p.w.Event('DOMContentLoaded'));
    p.device(true);
    p.send({ response: 'openTarget' });
    p.send({ response: 'validTarget', data: [{ icon: 'x', label: 'Open' }, { icon: 'y', label: 'Search' }] });
    eq(ring(p.d), 'target-option-1', 'first option ringed when the list opens');
    p.pad('down');
    eq(ring(p.d), 'target-option-2');
    p.pad('down');
    eq(ring(p.d), 'target-option-1', 'wraps');
    p.pad('up');
    p.pad('select');
    eq(p.posts.length, 1);
    ok(p.posts[0].url.endsWith('/selectTarget'));
    eq(p.posts[0].body, '"2"');
    p.send({ response: 'validTarget', data: [{ icon: 'x', label: 'Open' }] });
    p.pad('back');
    ok(p.posts[1].url.endsWith('/closeTarget'));
});

// pfm-inventory is a Vue app (Vue from a CDN, not available here): a stand-in createApp hands over the
// component, which runs as a plain object with its methods and computed values bound to it.
(function () {
    const html = fs.readFileSync(path.join(QB, 'pfm-inventory/html/index.html'), 'utf8');
    check('pfm-inventory loads pad.js and pad.css', () => {
        ok(html.includes('https://cfx-nui-pfm-ui/html/pad.js'));
        ok(html.includes('https://cfx-nui-pfm-ui/html/pad.css'));
        ok(/:class="padClasses\(slot, 'backpack'\)"/.test(html), 'backpack slots show the selection');
    });
    // a static stand-in for the rendered grid: player slots 1-4 in a row, the stash's 1-2 to the right
    const grid = `<!doctype html><html><body><div class="inventory-container">
      <div class="player-inventory-section">${[1, 2, 3, 4].map((n) => `<div class="item-slot" id="p${n}" data-slot="${n}"></div>`).join('')}</div>
      <div class="other-inventory-section">${[1, 2].map((n) => `<div class="item-slot" id="o${n}" data-slot="${n}"></div>`).join('')}</div>
    </div></body></html>`;
    const p = boot(grid, 'https://cfx-nui-pfm-inventory/index.html');
    const rects = {};
    [1, 2, 3, 4].forEach((n) => { rects['p' + n] = [n * 60, 100, 50, 50]; });
    [1, 2].forEach((n) => { rects['o' + n] = [400 + n * 60, 100, 50, 50]; });
    place(p.w, rects);
    p.send = (data) => p.w.dispatchEvent(new p.w.MessageEvent('message', { data }));
    const posts = [];
    p.w.axios = { post: (url, body) => { posts.push({ url, body }); return Promise.resolve({ data: true }); } };
    let component = null;
    p.w.Vue = { createApp: (opts) => { component = opts; return { mount() {} }; } };
    p.w.eval(fs.readFileSync(path.join(QB, 'pfm-inventory/html/app.js'), 'utf8'));
    const vm = {};
    for (const [k, fn] of Object.entries(component.methods)) vm[k] = fn.bind(vm);
    Object.assign(vm, vm.getInitialState());
    for (const [k, fn] of Object.entries(component.computed)) Object.defineProperty(vm, k, { get: fn.bind(vm) });
    component.mounted.call(vm);
    const item = (name, slot, amount) => ({ name, label: name, slot, amount, weight: 100, image: name + '.png', useable: true });
    p.send({ action: 'open', slots: 10, maxweight: 100000, pockets: 0,
        inventory: [item('water', 1, 5), item('bread', 2, 1)],
        other: { name: 'stash-1', label: 'Stash', maxweight: 100000, slots: 2, inventory: [] } });
    const sel = () => vm.padSel && `${vm.padSel.inv}:${vm.padSel.slot}`;
    const last = () => posts[posts.length - 1];

    check('pfm-inventory: the D-pad moves a selection between slots, RB jumps to the other side', () => {
        eq(vm.isInventoryOpen, true);
        p.pad('right');
        eq(sel(), 'player:1', 'first press selects the first slot');
        p.pad('right');
        eq(sel(), 'player:2');
        eq(vm.slotClasses(2, 'player')['pad-sel'], true, 'the slot is drawn selected');
        p.pad('tabNext');
        eq(sel(), 'other:1');
        p.pad('tabPrev');
        eq(sel(), 'player:1');
    });
    check('pfm-inventory: A picks up, A on another slot places (the drag path)', () => {
        p.pad('select');
        eq(vm.padHeld && vm.padHeld.slot, 1);
        ok(vm.padHintsHtml.includes('Place'));
        p.pad('right'); p.pad('right');
        eq(sel(), 'player:3');
        p.pad('select');
        eq(vm.padHeld, null);
        ok(last().url.endsWith('/SetInventoryData'));
        eq(last().body.fromSlot, 1);
        eq(last().body.toSlot, 3);
        eq(last().body.toAmount, 5);
        eq(vm.playerInventory[3].name, 'water');
        eq(vm.playerInventory[1], undefined);
    });
    check('pfm-inventory: X uses the selected item', () => {
        p.pad('buttonX');
        ok(last().url.endsWith('/UseItem'));
        eq(last().body.item.name, 'water');
    });
    check('pfm-inventory: Y moves one into the open container (as a right-click)', () => {
        p.pad('buttonY');
        ok(last().url.endsWith('/SetInventoryData'));
        eq(last().body.toInventory, 'stash-1');
        eq(vm.playerInventory[3].amount, 4);
    });
    check('pfm-inventory: B drops a pick first, then closes', () => {
        p.pad('select');
        ok(vm.padHeld);
        const before = posts.length;
        p.pad('back');
        eq(vm.padHeld, null);
        eq(posts.length, before, 'cancelling a pick posts nothing');
        p.pad('back');
        ok(last().url.endsWith('/CloseInventory'));
        eq(vm.isInventoryOpen, false);
        eq(vm.padSel, null, 'selection forgotten on close');
        p.pad('right');
        eq(vm.padSel, null, 'a closed inventory ignores the pad');
    });
})();

console.log(`\n${passed} passed, ${failed} failed (pfm-ui pad.js and converted pages)`);
if (failed) { failures.forEach((f) => console.log('  - ' + f)); process.exit(1); }
