// pf-hud's NUI (html/index.html: classic scripts, no build step) shows cruise control as a gauge in the status row, from
// the `cruise` field the client sends in 'updateStatusHud' while driving (tests/specs/fix9hq2_cruise_hud_spec.lua covers
// the client side; tests/js/pfhud_whip_hud_spec.js the rest of the page). Run: node js/pfhud_cruise_spec.js
const fs = require('fs');
const path = require('path');
const { JSDOM, VirtualConsole } = require('jsdom');
const PF = path.resolve(__dirname, '..', '..', '..', '[pfscripts]', 'pf-hud');
const HUD = path.join(PF, 'html');

let passed = 0, failed = 0;
const failures = [];
function check(name, fn) { try { fn(); passed++; } catch (e) { failed++; failures.push(`${name}: ${e.message}`); } }
function eq(a, b, m) { if (a !== b) throw new Error(`${m || ''} expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`); }

const html = fs.readFileSync(path.join(HUD, 'index.html'), 'utf8');
const client = fs.readFileSync(path.join(PF, 'client.lua'), 'utf8');
const css = fs.readFileSync(path.join(HUD, 'css', 'pf.css'), 'utf8');

check('the client registers a cruise gauge: shown in a vehicle, only while on, in the accent', () => {
    if (!/name = 'cruise', type = 'flag'[^}]*showWhenPresent = true[^}]*onlyWhenOn = true[^}]*accentWhenOn = true/.test(client)) {
        throw new Error('no cruise gauge definition');
    }
});
check('the "on" look is styled', () => {
    if (!/\.sh-stat\.flag-accent::after\s*\{[^}]*border-color/.test(css)) throw new Error('no .flag-accent rim');
});

const dom = new JSDOM(html, { url: 'https://cfx-nui-pf-hud/html/index.html', runScripts: 'outside-only', virtualConsole: new VirtualConsole() });
const w = dom.window;
w.fetch = () => Promise.resolve({ json: async () => ({}) });
for (const s of ['js/router.js', 'js/status-hud.js', 'js/vehicle-dial.js', 'js/radar-tuner.js', 'app.js']) {
    w.eval(fs.readFileSync(path.join(HUD, s), 'utf8'));
}
const send = (data) => w.dispatchEvent(new w.MessageEvent('message', { data }));
send({ action: 'registerHudStats', stats: [
    { name: 'health', type: 'vital', max: 100, icon: 'M0 0h24v24H0z' },
    { name: 'cruise', type: 'flag', max: 1, icon: 'M0 0h24v24H0z', showWhenPresent: true, onlyWhenOn: true, accentWhenOn: true },
] });
const gauge = () => w.document.querySelector('#statusHudStats .sh-stat[data-stat="cruise"]');
const shown = () => gauge().classList.contains('visible');

check('the gauge exists in the row and starts hidden', () => {
    eq(!!gauge(), true);
    eq(shown(), false);
});
check('driving with cruise off: hidden', () => {
    send({ action: 'updateStatusHud', health: 90, inVehicle: true, seatbelt: false, cruise: false });
    eq(shown(), false);
});
check('cruise on: shown, in the "on" style', () => {
    send({ action: 'updateStatusHud', cruise: true });
    eq(shown(), true);
    eq(gauge().classList.contains('flag-accent'), true);
});
check('cruise off again: hidden', () => {
    send({ action: 'updateStatusHud', cruise: false });
    eq(shown(), false);
    eq(gauge().classList.contains('flag-accent'), false);
});
check('out of the car: hidden even if the last word was "on"', () => {
    send({ action: 'updateStatusHud', cruise: true });
    send({ action: 'updateStatusHud', inVehicle: false });
    eq(shown(), false);
});
check('layout edit mode shows it so it can be placed', () => {
    w.PfHudApp.enterEditMode();
    eq(shown(), true);
    w.PfHudApp.exitEditMode(false);
});

console.log(`\n${passed} passed, ${failed} failed (pf-hud cruise)`);
if (failed) { failures.forEach((f) => console.log('  - ' + f)); process.exit(1); }
