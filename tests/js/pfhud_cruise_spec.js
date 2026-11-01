// pf-hud's NUI (html/index.html + html/app.js, plain JS with no build step) shows the cruise control
// icon from the `cruise` field of the 'vehicle' message the client sends while driving
// (tests/specs/fix9hq2_cruise_hud_spec.lua covers the client side). Run: node js/pfhud_cruise_spec.js
const fs = require('fs');
const path = require('path');
const { JSDOM } = require('jsdom');
const HUD = path.resolve(__dirname, '..', '..', '..', '[pfscripts]', 'pf-hud', 'html');

let passed = 0, failed = 0;
const failures = [];
function check(name, fn) { try { fn(); passed++; } catch (e) { failed++; failures.push(`${name}: ${e.message}`); } }
function eq(a, b, m) { if (a !== b) throw new Error(`${m || ''} expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`); }

const html = fs.readFileSync(path.join(HUD, 'index.html'), 'utf8');
const app = fs.readFileSync(path.join(HUD, 'app.js'), 'utf8');
const css = fs.readFileSync(path.join(HUD, 'style.css'), 'utf8');

check('the page loads app.js (the svelte build is not what runs)', () => {
    if (!/<script src="app\.js"><\/script>/.test(html)) throw new Error('app.js not loaded');
    if (/index\.js/.test(html)) throw new Error('the old svelte bundle is loaded');
});
check('the icon is styled when on', () => {
    if (!/\.veh-icon\.cruise-on\s*\{[^}]*color/.test(css)) throw new Error('no .cruise-on colour');
});

const dom = new JSDOM(html, { url: 'https://cfx-nui-pf-hud/html/index.html', runScripts: 'outside-only' });
const w = dom.window;
const posts = [];
w.fetch = (url, opts) => { posts.push({ url, body: opts && opts.body }); return Promise.resolve({ json: async () => ({}) }); };
w.eval(app);

const send = (data) => w.dispatchEvent(new w.MessageEvent('message', { data }));
const icon = () => w.document.getElementById('icon-cruise');
const driving = (extra) => Object.assign({ action: 'vehicle', show: true, speed: 50, unit: 'mph', fuel: 60, lowFuel: false, engine: 100, seatbelt: false, harness: false, nitroActive: false, nitro: 0 }, extra);

check('the icon exists among the vehicle icons and starts hidden', () => {
    const el = icon();
    if (!el) throw new Error('no #icon-cruise');
    eq(el.parentElement.id, 'vehicleIcons');
    eq(el.classList.contains('hidden'), true);
});
check('cruise on: shown, in the "on" style', () => {
    send(driving({ cruise: true }));
    eq(icon().classList.contains('hidden'), false);
    eq(icon().classList.contains('cruise-on'), true);
    eq(w.document.getElementById('vehicleIcons').classList.contains('hidden'), false);
});
check('cruise off, or the field missing (an older client): hidden', () => {
    send(driving({ cruise: false }));
    eq(icon().classList.contains('hidden'), true);
    send(driving({ cruise: true }));
    send(driving({}));
    eq(icon().classList.contains('hidden'), true);
});
check('out of the car the whole vehicle cluster hides', () => {
    send(driving({ cruise: true }));
    send({ action: 'vehicle', show: false });
    eq(w.document.getElementById('vehicleIcons').classList.contains('hidden'), true);
});
check('layout edit mode shows the icon so it can be placed', () => {
    if (!/cruise: true, nitroActive: false, nitro: 55/.test(app)) throw new Error('edit-mode sample has no cruise');
});

console.log(`\n${passed} passed, ${failed} failed (pf-hud cruise)`);
if (failed) { failures.forEach((f) => console.log('  - ' + f)); process.exit(1); }
