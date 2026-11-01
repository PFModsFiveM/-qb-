// pf-jobs NUI modules in a simulated browser (jsdom) on the pf-devices runtime: the Tow app renders
// the server's state as text on the tablet and the computer and sends only ids and models (and shows
// a player who left the tow job only their flatbed return and pay still owed, also when the job
// changes with the window open); the Gruppe 6
// and Garbage apps send crew shares as a list and buy upgrades by id; the Bus app takes a depot bus.
// Run: node js/pfjobs_apps_spec.js
const fs = require('fs');
const path = require('path');
const { JSDOM } = require('jsdom');

const PF = path.resolve(__dirname, '..', '..', '..', '[pfscripts]');
const RUNTIME = fs.readFileSync(path.join(PF, 'pf-devices/html/runtime.js'), 'utf8');
const IDS = ['tow', 'gruppe6', 'garbage', 'bus'];
const MODULES = IDS.map((m) => fs.readFileSync(path.join(PF, `pf-jobs/html/apps/${m}.js`), 'utf8'));

let passed = 0;
let failed = 0;
const failures = [];
async function it(name, fn) {
    try { await fn(); passed++; } catch (e) { failed++; failures.push(`${name}: ${e && e.stack || e}`); }
}
function eq(a, b, msg) { if (a !== b) throw new Error(`${msg || 'expected'}: ${JSON.stringify(b)}, got ${JSON.stringify(a)}`); }
function ok(v, msg) { if (!v) throw new Error(msg || 'expected truthy'); }
const tick = () => new Promise((r) => setTimeout(r, 0));
async function settle() { for (let i = 0; i < 15; i++) await tick(); }

const EVIL = '<img src=x onerror="window.__xss=1">';
const APPS = IDS.map((id) => ({ id, name: id, icon: '', kind: 'module', entry: `https://cfx-nui-pf-jobs/html/apps/${id}.js`, styles: [] }));

function makeWindow(device, handlers) {
    const dom = new JSDOM('<!doctype html><html><head></head><body><div id="shell"></div></body></html>', { runScripts: 'outside-only', url: 'https://cfx-nui-pf-tablet/html/index.html' });
    const win = dom.window;
    const rpcs = [];
    const waypoints = [];
    win.fetch = async (url, opts) => {
        const name = String(url).replace(/^https:\/\/[^/]+\//, '');
        const body = JSON.parse(opts && opts.body || '{}');
        let result = { ok: true };
        if (name === 'apps') result = { apps: APPS, store: [], categories: [] };
        else if (name === 'rpc') {
            rpcs.push(body);
            const fn = handlers[`${body.app}.${body.method}`];
            result = fn ? fn(body.payload) : { ok: false, error: 'unknown_method' };
        } else if (name === 'waypoint' || name === 'setWaypoint') waypoints.push(body);
        return { json: async () => result };
    };
    const origAppend = win.document.head.appendChild.bind(win.document.head);
    win.document.head.appendChild = (el) => { const r = origAppend(el); if (el.tagName === 'SCRIPT') setTimeout(() => el.onload && el.onload(), 0); return r; };
    win.jQuery = function () {};
    win.eval(RUNTIME);
    MODULES.forEach((src) => win.eval(src));
    const notes = [];
    win.PFApps.attachShell({
        device,
        openWindow(app, mount) {
            const el = win.document.createElement('div');
            el.dataset.window = app.id;
            win.document.getElementById('shell').appendChild(el);
            mount(el);
        },
        closeWindow(id) { const el = win.document.querySelector(`[data-window="${id}"]`); if (el) el.remove(); },
        onApps() {},
        notify(m, t) { notes.push({ m, t }); },
    });
    return { win, rpcs, notes, waypoints, root: (id) => win.document.querySelector(`[data-window="${id}"]`) };
}

const towView = () => ({
    ok: true, playerId: 1, onDuty: true,
    stats: { xp: 120, contracts: 3, requests: 1, towed: 5, earned: 900 },
    level: { level: 1, title: EVIL, xp: 0, nextXp: 500, maxKm: 3, payMultiplier: 1 },
    levels: [{ level: 1, xp: 0, title: 'Rookie', maxKm: 3, payMultiplier: 1 }, { level: 2, xp: 500, title: 'Operator', maxKm: 4.5, payMultiplier: 1.1 }],
    vehicles: [{ model: 'flatbed', label: 'Flatbed', deposit: 250, minLevel: 1, unlocked: true }],
    rental: { model: 'flatbed', label: EVIL, plate: 'TOWR1234', deposit: 250, orphaned: false, present: true },
    hook: { plate: EVIL, contract: true },
    contract: { id: 'c1', model: EVIL, plate: 'BRK00001', stage: 'pickup', pay: 260, xp: 70, km: 2.4, x: 10, y: 20, z: 30 },
    requests: [
        { id: 7, kind: 'tow.impound', label: 'Impound tow', icon: '🚨', status: 'open', title: EVIL, details: EVIL, plate: 'ABC123', reward: 250, fromName: EVIL, coords: { x: 1, y: 2 }, destinations: [{ label: EVIL, x: 5, y: 6 }] },
        { id: 8, kind: 'tow.recovery', label: 'Recovery', status: 'accepted', mine: true, title: 'Mine', plate: 'MINE1', reward: 175, coords: { x: 3, y: 4 }, destinations: [{ label: 'Bennys', x: 7, y: 8 }] },
    ],
    servicesOnline: true, contractBlocker: 'contract_active', atBay: true,
    depot: { label: 'Hayes', x: 489, y: -1331 }, dropOff: { label: 'Hayes Depot', x: 491, y: -1314 },
    config: { payBase: 140, payPerKm: 30, requestXp: 80 },
});

(async () => {
    for (const device of ['tablet', 'computer']) {
        await it(`${device}: the Tow app shows the flatbed, the job and the requests as text`, async () => {
            const env = makeWindow(device, {
                'tow.getInit': towView, 'tow.refresh': towView,
                'tow.acceptRequest': () => ({ ok: true, view: towView() }),
                'tow.completeRequest': () => ({ ok: false, error: 'not_at_destination' }),
                'tow.returnFlatbed': () => ({ ok: false, error: 'truck_far', message: 'Bring the flatbed back to the bay' }),
            });
            await env.win.PFApps.refresh();
            await env.win.PFApps.open('tow');
            await settle();
            const root = env.root('tow');
            ok(root && root.querySelector('.pfj-tow'), 'tow mounted');
            eq(root.querySelectorAll('img').length, 0, 'server text became HTML');
            ok(root.textContent.includes(EVIL), 'shown as text');
            ok(root.textContent.includes('TOWR1234'), 'flatbed plate');
            ok(root.textContent.includes('$260'), 'contract pay');
            // return the flatbed: the server's message is shown
            [...root.querySelectorAll('button')].find((b) => b.textContent === 'Return flatbed').click();
            await settle();
            ok(env.notes.some((n) => n.m === 'Bring the flatbed back to the bay'), 'refusal shown');
            // requests tab: accept sends only the id
            [...root.querySelectorAll('[data-tab]')].find((t) => t.dataset.tab === 'requests').click();
            await settle();
            eq(root.querySelectorAll('.pfj-tow-req').length, 2);
            eq(root.querySelectorAll('img').length, 0);
            [...root.querySelectorAll('button')].find((b) => b.textContent === 'Accept').click();
            await settle();
            const accept = env.rpcs.find((r) => r.method === 'acceptRequest');
            ok(accept, 'accept rpc');
            eq(JSON.stringify(accept.payload), JSON.stringify({ id: 7 }));
            [...root.querySelectorAll('button')].find((b) => b.textContent === 'Complete').click();
            await settle();
            ok(env.notes.some((n) => /not at the destination/.test(n.m)), 'pf-services refusal explained');
            // progress tab renders the levels
            [...root.querySelectorAll('[data-tab]')].find((t) => t.dataset.tab === 'progress').click();
            await settle();
            eq(root.querySelectorAll('tbody tr').length, 2);
            eq(env.win.__xss, undefined, 'script ran');
            // everything stayed inside the window
            eq(env.win.document.querySelectorAll('#shell > :not([data-window])').length, 0);
        });
    }

    await it('Tow app without a rental: rent sends only the model', async () => {
        const view = towView();
        delete view.rental; delete view.contract; delete view.hook;
        view.requests = []; view.contractBlocker = null;
        const env = makeWindow('tablet', { 'tow.getInit': () => view, 'tow.rentFlatbed': () => ({ ok: true, view }), 'tow.startContract': () => ({ ok: true, view }) });
        await env.win.PFApps.refresh();
        await env.win.PFApps.open('tow');
        await settle();
        const root = env.root('tow');
        [...root.querySelectorAll('button')].find((b) => /Flatbed/.test(b.textContent)).click();
        await settle();
        const rent = env.rpcs.find((r) => r.method === 'rentFlatbed');
        eq(JSON.stringify(rent.payload), JSON.stringify({ model: 'flatbed' }));
        [...root.querySelectorAll('[data-tab]')].find((t) => t.dataset.tab === 'contracts').click();
        await settle();
        [...root.querySelectorAll('button')].find((b) => b.textContent === 'Get a contract').click();
        await settle();
        ok(env.rpcs.find((r) => r.method === 'startContract'), 'contract asked for');
    });

    for (const device of ['tablet', 'computer']) {
        await it(`${device}: a player who left the tow job sees only the flatbed return`, async () => {
            const view = () => ({
                ok: true, playerId: 1, returnOnly: true, atBay: true,
                rental: { model: 'flatbed', label: EVIL, plate: 'TOWR4321', deposit: 250, orphaned: false, present: true },
                hook: { plate: EVIL },
                depot: { label: 'Hayes', x: 489, y: -1331 },
            });
            const settled = { returnOnly: true, playerId: 1, atBay: true, depot: { label: 'Hayes', x: 489, y: -1331 } };
            const env = makeWindow(device, {
                'tow.getInit': view, 'tow.refresh': view,
                'tow.returnFlatbed': () => ({ ok: true, refund: 250, view: settled }),
            });
            await env.win.PFApps.refresh();
            await env.win.PFApps.open('tow');
            await settle();
            const root = env.root('tow');
            ok(root.textContent.includes('Flatbed return'), 'return-only header');
            ok(root.textContent.includes('TOWR4321'), 'the rental');
            ok(root.textContent.includes(EVIL), 'server text as text');
            ok(root.textContent.includes('/tow'), 'told to take the car off with /tow');
            eq(root.querySelectorAll('img').length, 0);
            eq(root.querySelectorAll('[data-tab]').length, 0, 'no requests, contracts or progress tabs');
            eq(root.querySelectorAll('[data-action="rentFlatbed"],[data-action="startContract"],[data-action="acceptRequest"]').length, 0);
            [...root.querySelectorAll('button')].find((b) => b.textContent === 'Return flatbed').click();
            await settle();
            const sent = env.rpcs.find((r) => r.method === 'returnFlatbed');
            ok(sent, 'return asked for');
            eq(JSON.stringify(sent.payload || {}), '{}', 'nothing but the method');
            ok(env.notes.some((n) => n.m === 'Flatbed returned. $250 deposit back to your bank'), 'the refund is told (the app closes after)');
            ok(!root.textContent.includes('TOWR4321'), 'the returned flatbed is gone from the screen');
            ok(root.textContent.includes('settled'), 'settled');
            eq(root.querySelectorAll('[data-action="rentFlatbed"]').length, 0, 'still no rent offers');
            eq(env.win.__xss, undefined);
        });
    }

    for (const device of ['tablet', 'computer']) {
        await it(`${device}: a former driver collects pay still owed from the return-only view`, async () => {
            const owedView = () => ({
                ok: true, playerId: 1, returnOnly: true, atBay: false,
                owed: { plate: 'BRK00042', model: EVIL, pay: 312 },
                depot: { label: 'Hayes', x: 489, y: -1331 },
            });
            const settled = { ok: true, playerId: 1, returnOnly: true, atBay: false, depot: { label: 'Hayes', x: 489, y: -1331 } };
            const env = makeWindow(device, {
                'tow.getInit': owedView, 'tow.refresh': owedView,
                'tow.claimPay': () => ({ ok: true, paid: 312, view: settled }),
            });
            await env.win.PFApps.refresh();
            await env.win.PFApps.open('tow');
            await settle();
            const root = env.root('tow');
            ok(root.textContent.includes('BRK00042'), 'the delivered contract');
            ok(root.textContent.includes('$312'), 'the pay owed');
            ok(root.textContent.includes(EVIL), 'server text as text');
            eq(root.querySelectorAll('img').length, 0);
            ok(!root.textContent.includes('rental is settled'), 'no "settled" while pay is owed');
            eq(root.querySelectorAll('[data-tab]').length, 0, 'still no driver tabs');
            eq(root.querySelectorAll('[data-action="rentFlatbed"],[data-action="startContract"],[data-action="returnFlatbed"]').length, 0);
            [...root.querySelectorAll('button')].find((b) => b.textContent === 'Collect pay').click();
            await settle();
            const sent = env.rpcs.find((r) => r.method === 'claimPay');
            ok(sent, 'claim asked for');
            eq(JSON.stringify(sent.payload || {}), '{}', 'nothing but the method');
            ok(env.notes.some((n) => n.m === '$312 paid to your bank'), 'the pay is told (the app closes after)');
            ok(!root.textContent.includes('BRK00042'), 'the claimed pay is gone from the screen');
            eq(env.win.__xss, undefined);
        });
    }

    await it('Tow app: an open window switches to the return-only view when the player leaves the job', async () => {
        let left = false;
        const returnOnly = () => ({
            ok: true, playerId: 1, returnOnly: true, atBay: true,
            rental: { model: 'flatbed', label: 'Flatbed', plate: 'TOWR7777', deposit: 250, orphaned: false, present: true },
            depot: { label: 'Hayes', x: 489, y: -1331 },
        });
        const env = makeWindow('tablet', { 'tow.getInit': towView, 'tow.refresh': () => (left ? returnOnly() : towView()) });
        await env.win.PFApps.refresh();
        await env.win.PFApps.open('tow');
        await settle();
        const root = env.root('tow');
        ok(root.querySelectorAll('[data-tab]').length > 0, "the driver's layout");
        // the job changes: the server pushes the tow state, the app fetches its view again
        left = true;
        env.win.PFApps.handleMessage({ action: 'pfapp:event', app: 'tow', event: 'state', payload: {} });
        await new Promise((r) => setTimeout(r, 320));
        await settle();
        eq(root.querySelectorAll('[data-tab]').length, 0, 'no driver tabs any more');
        ok(root.textContent.includes('Flatbed return'), 'the return-only view');
        ok(root.textContent.includes('TOWR7777'));
        eq(root.querySelectorAll('[data-action="rentFlatbed"],[data-action="startContract"],[data-action="acceptRequest"]').length, 0);
    });

    await it('Tow app: a returned flatbed leaves the driver\'s screen (views replace, not merge)', async () => {
        const after = towView();
        delete after.rental; delete after.contract; delete after.hook;
        const env = makeWindow('tablet', { 'tow.getInit': towView, 'tow.returnFlatbed': () => ({ ok: true, refund: 125, view: after }) });
        await env.win.PFApps.refresh();
        await env.win.PFApps.open('tow');
        await settle();
        const root = env.root('tow');
        [...root.querySelectorAll('button')].find((b) => b.textContent === 'Return flatbed').click();
        await settle();
        ok(env.notes.some((n) => n.m === 'Flatbed returned. $125 deposit back to your bank'), 'refund told');
        eq([...root.querySelectorAll('button')].filter((b) => b.textContent === 'Return flatbed').length, 0, 'no stale rental');
        ok(root.querySelector('[data-action="rentFlatbed"]'), 'rent offers back');
        ok(!root.textContent.includes('BRK00001'), 'no stale contract');
    });

    await it('Gruppe 6: the leader saves shares as a list and buys an upgrade by id', async () => {
        const view = () => ({
            ok: true, playerId: 3, xp: 0, level: 2, searching: false, offers: [], invites: [],
            group: { leader: 3, leaderName: 'Lead', groupCode: 'ABCDEF', members: [{ id: 4, name: EVIL }], payoutSplits: { 3: 50, 4: 50 }, splits: [{ id: 3, pct: 50 }, { id: 4, pct: 50 }] },
            upgrades: [{ id: 'tier_2', label: EVIL, description: 'x', cost: 10000, requiredLevel: 2, canBuy: true, owned: false }],
            config: { levels: [{ level: 1, xp: 0 }], tiers: [], maxMembers: 4, crewBonus: 1.5, splitFloor: 10 },
        });
        const env = makeWindow('computer', { 'gruppe6.getInit': view, 'gruppe6.refresh': view,
            'gruppe6.setSplits': () => ({ ok: true, view: view() }), 'gruppe6.buyUpgrade': () => ({ ok: true, view: view() }) });
        await env.win.PFApps.refresh();
        await env.win.PFApps.open('gruppe6');
        await settle();
        const root = env.root('gruppe6');
        [...root.querySelectorAll('[data-tab]')].find((t) => t.dataset.tab === 'party').click();
        await settle();
        const inputs = root.querySelectorAll('[data-split-id]');
        eq(inputs.length, 2);
        inputs[0].value = '70'; inputs[1].value = '20';
        root.querySelector('[data-action="saveSplits"]').click();
        await settle();
        eq(env.rpcs.filter((r) => r.method === 'setSplits').length, 0, 'not sent when the total is not 100');
        inputs[1].value = '30';
        root.querySelector('[data-action="saveSplits"]').click();
        await settle();
        const sent = env.rpcs.find((r) => r.method === 'setSplits');
        eq(JSON.stringify(sent.payload), JSON.stringify({ splits: [{ id: 3, pct: 70 }, { id: 4, pct: 30 }] }));
        [...root.querySelectorAll('[data-tab]')].find((t) => t.dataset.tab === 'upgrades').click();
        await settle();
        eq(root.querySelectorAll('img').length, 0);
        root.querySelector('[data-action="buyUpgrade"]').click();
        await settle();
        eq(JSON.stringify(env.rpcs.find((r) => r.method === 'buyUpgrade').payload), JSON.stringify({ id: 'tier_2' }));
        eq(env.win.__xss, undefined);
    });

    await it('Garbage: the leader saves crew shares', async () => {
        const state = () => ({ ok: true, playerId: 3, xp: 0, level: 1, active: false, pendingInvites: [],
            currentGroup: { leader: 3, leaderName: 'Lead', groupCode: 'ABCDEF', members: [{ id: 4, name: 'Bob' }], splits: [{ id: 3, pct: 50 }, { id: 4, pct: 50 }] },
            config: { levels: [{ level: 1, xp: 0, payPerBag: 20 }], crewBonus: 1.5, splitFloor: 10, maxMembers: 4 } });
        const env = makeWindow('tablet', { 'garbage.getInit': state, 'garbage.setSplits': () => ({ ok: true, state: state() }) });
        await env.win.PFApps.refresh();
        await env.win.PFApps.open('garbage');
        await settle();
        const root = env.root('garbage');
        [...root.querySelectorAll('[data-tab]')].find((t) => t.dataset.tab === 'crew').click();
        await settle();
        const inputs = root.querySelectorAll('[data-split-id]');
        inputs[0].value = '40'; inputs[1].value = '60';
        root.querySelector('[data-action="saveSplits"]').click();
        await settle();
        eq(JSON.stringify(env.rpcs.find((r) => r.method === 'setSplits').payload), JSON.stringify({ splits: [{ id: 3, pct: 40 }, { id: 4, pct: 60 }] }));
    });

    await it('Bus: a depot bus is taken by model', async () => {
        const view = () => ({ ok: true, enabled: true, stats: { level: 1 }, routes: [{ id: 1, name: EVIL, difficulty: 'easy', estimatedTime: 420000, stopCount: 8, expectedPassengers: 20, estimatedPay: 300, baseDistance: 1.6 }],
            lockedRoutes: [{ id: 7, name: 'East', minLevel: 3 }], vehicles: [{ model: 'bus', label: 'City Bus', capacity: 15, minLevel: 1, unlocked: true }],
            depot: { label: 'Depot', x: 1, y: 2 }, atDepot: true, config: { levels: [] } });
        const env = makeWindow('tablet', { 'bus.getInit': view, 'bus.takeBus': () => ({ ok: true, view: view() }) });
        await env.win.PFApps.refresh();
        await env.win.PFApps.open('bus');
        await settle();
        const root = env.root('bus');
        root.querySelector('[data-action="takeBus"]').click();
        await settle();
        eq(JSON.stringify(env.rpcs.find((r) => r.method === 'takeBus').payload), JSON.stringify({ model: 'bus' }));
        [...root.querySelectorAll('[data-tab]')].find((t) => t.dataset.tab === 'routes').click();
        await settle();
        ok(root.textContent.includes('$300'), 'the server estimate');
        ok(root.textContent.includes(EVIL), 'route name as text');
        eq(root.querySelectorAll('img').length, 0);
    });

    console.log(`${passed} passed, ${failed} failed`);
    if (failures.length) { failures.forEach((f) => console.log('  - ' + f)); process.exit(1); }
})();
