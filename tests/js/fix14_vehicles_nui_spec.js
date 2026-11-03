// fix14 vehicles NUI: the pfm-garages list puts vehicle names and plates into the page as text and
// lets a car whose impound fee was paid ahead out of the depot (GAR-3: the server checks the paid
// release); the pfm-lapraces HUD shows the race name as text and times in milliseconds (LAP-1).
// Run: node js/fix14_vehicles_nui_spec.js
const fs = require('fs');
const path = require('path');
const { JSDOM } = require('jsdom');

const QB = path.resolve(__dirname, '..', '..');
let passed = 0;
let failed = 0;
const failures = [];
async function it(name, fn) {
    try { await fn(); passed++; } catch (e) { failed++; failures.push(`${name}: ${e && e.stack || e}`); }
}
function eq(a, b, msg) { if (a !== b) throw new Error(`${msg || 'expected'}: ${JSON.stringify(b)}, got ${JSON.stringify(a)}`); }
function ok(v, msg) { if (!v) throw new Error(msg || 'expected truthy'); }
const tick = () => new Promise((r) => setTimeout(r, 0));

const EVIL = '<img src=x onerror="window.__xss=1">';

function page(res) {
    const html = fs.readFileSync(path.join(QB, res, 'html/index.html'), 'utf8')
        .replace(/<script[^>]*src=[^>]*><\/script>/g, '').replace(/<link[^>]*>/g, '');
    const dom = new JSDOM(html, { runScripts: 'outside-only', url: `https://cfx-nui-${res}/html/index.html` });
    return dom.window;
}
function send(win, data) { win.dispatchEvent(new win.MessageEvent('message', { data })); }

// a minimal jQuery for the lap race HUD (document ready, text/html, show/hide)
function jq(win) {
    const doc = win.document;
    const wrap = (els) => ({
        ready(fn) { fn(); return this; },
        text(v) { els.forEach((e) => { e.textContent = v; }); return this; },
        html(v) { els.forEach((e) => { e.innerHTML = v; }); return this; },
        fadeIn() { return this; }, fadeOut() { return this; }, hide() { return this; },
    });
    return (sel) => (sel === doc ? wrap([]) : wrap(Array.from(doc.querySelectorAll(sel))));
}

(async () => {
    await it('garages: names and plates are text, not markup', async () => {
        const win = page('pfm-garages');
        win.fetch = async () => ({ json: async () => ({}) });
        win.eval(fs.readFileSync(path.join(QB, 'pfm-garages/html/script.js'), 'utf8'));
        send(win, { action: 'VehicleList', garageLabel: EVIL, garageType: 'public', vehicles: [
            { vehicle: 'sultan', vehicleLabel: EVIL, brand: EVIL, plate: EVIL, state: 1, type: 'public', depotPrice: 0, fuel: 50, engine: 900, body: 900 },
        ] });
        await tick();
        eq(win.document.querySelectorAll('img').length, 0, 'no element from a server string');
        eq(win.__xss, undefined);
        ok(win.document.querySelector('.v-name').textContent.includes('<img'), 'shown as text');
        ok(win.document.querySelector('.plate').textContent.includes('<img'), 'plate as text');
    });

    await it('garages: a car whose fee was paid ahead can be driven out of the depot', async () => {
        const win = page('pfm-garages');
        const posts = [];
        win.fetch = async (url, opts) => { posts.push({ cb: String(url).split('/').pop(), body: JSON.parse(opts.body) }); return { json: async () => ({}) }; };
        win.eval(fs.readFileSync(path.join(QB, 'pfm-garages/html/script.js'), 'utf8'));
        send(win, { action: 'VehicleList', garageLabel: 'Depot Lot', garageType: 'depot', vehicles: [
            { vehicle: 'sultan', vehicleLabel: 'Sultan', plate: 'PAID1', state: 0, type: 'depot', index: 'depotLot', depotPrice: 0, depotPaid: true, fuel: 50, engine: 900, body: 900 },
            { vehicle: 'sultan', vehicleLabel: 'Sultan', plate: 'OWED1', state: 0, type: 'depot', index: 'depotLot', depotPrice: 500, fuel: 50, engine: 900, body: 900 },
        ] });
        await tick();
        const buttons = Array.from(win.document.querySelectorAll('.act'));
        eq(buttons.length, 2);
        eq(buttons[0].textContent, 'Drive', 'paid: drive it out');
        ok(buttons[1].textContent.startsWith('Pay'), 'not paid: pay first');
        buttons[0].click();
        await tick();
        const take = posts.find((p) => p.cb === 'takeOutVehicle');
        ok(take, 'asks the client to take it out');
        eq(take.body.plate, 'PAID1');
        eq(take.body.index, 'depotLot', 'with the garage id the server checks');
    });

    await it('lap race HUD: the race name is text and times are m:ss.mmm', async () => {
        const win = page('pfm-lapraces');
        win.$ = jq(win);
        win.eval(fs.readFileSync(path.join(QB, 'pfm-lapraces/html/script.js'), 'utf8'));
        send(win, { action: 'Update', type: 'race', active: true, racedata: {}, data: {
            RaceName: EVIL, CurrentCheckpoint: 2, TotalCheckpoints: 5, TotalLaps: 3, CurrentLap: 1, RaceStarted: true,
            Time: 83457, BestLap: 61005, TotalTime: 3723004,
        } });
        await tick();
        eq(win.document.querySelectorAll('img').length, 0);
        eq(win.document.getElementById('race-racename').textContent, 'Race: ' + EVIL);
        eq(win.document.getElementById('race-time').textContent, 'Round Time: 1:23.457');
        eq(win.document.getElementById('race-besttime').textContent, 'Best Round: 1:01.005');
        eq(win.document.getElementById('race-totaltime').textContent, 'Total Time: 62:03.004');
    });

    console.log(`fix14_vehicles_nui_spec: ${passed} passed, ${failed} failed`);
    for (const f of failures) console.log('  - ' + f);
    process.exit(failed ? 1 : 0);
})();
