// Garages, Real Estate (citizen + agency), Car Dealer (citizen + staff) and Used Cars modules in a
// simulated browser (jsdom) on the pf-devices runtime: they render from the server's data, never
// turn server strings into HTML, use no global element ids, send only the fields the server reads,
// and work on the tablet and the computer.
// Run: node js/vehicle_property_apps_spec.js
const fs = require('fs');
const path = require('path');
const { JSDOM } = require('jsdom');

const QB = path.resolve(__dirname, '..', '..');
const PF = path.resolve(QB, '..', '[pfscripts]');
const RUNTIME = fs.readFileSync(path.join(PF, 'pf-devices/html/runtime.js'), 'utf8');
const FILES = {
    garages: 'pfm-garages/html/apps/garages.js',
    realestate: 'pfm-houses/html/apps/realestate.js',
    cardealer: 'pfm-vehicleshop/html/apps/cardealer.js',
    usedcars: 'pfm-vehiclesales/html/apps/usedcars.js',
};
const SOURCES = Object.values(FILES).map((f) => fs.readFileSync(path.join(QB, f), 'utf8'));
const APPS = [
    ['garages', 'pfm-garages', 'garages'], ['realestate', 'pfm-houses', 'realestate'], ['realestate-agency', 'pfm-houses', 'realestate'],
    ['cardealer', 'pfm-vehicleshop', 'cardealer'], ['cardealer-sales', 'pfm-vehicleshop', 'cardealer'], ['usedcars', 'pfm-vehiclesales', 'usedcars'],
].map(([id, res, file]) => ({ id, name: id, icon: '', kind: 'module', entry: `https://cfx-nui-${res}/html/apps/${file}.js`, styles: [] }));

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

function makeWindow(device, handlers) {
    const dom = new JSDOM('<!doctype html><html><head></head><body><div id="shell"></div></body></html>', { runScripts: 'outside-only', url: 'https://cfx-nui-pf-tablet/html/index.html' });
    const win = dom.window;
    const rpcs = [];
    const posts = [];
    win.fetch = async (url, opts) => {
        const name = String(url).replace(/^https:\/\/[^/]+\//, '');
        const body = JSON.parse(opts && opts.body || '{}');
        posts.push({ name, body });
        let result = { ok: true };
        if (name === 'apps') result = { apps: APPS, store: [], categories: [] };
        else if (name === 'rpc') {
            rpcs.push(body);
            const fn = handlers[`${body.app}.${body.method}`];
            result = fn ? fn(body.payload) : { ok: false, error: 'unknown_method' };
        }
        return { json: async () => result };
    };
    const origAppend = win.document.head.appendChild.bind(win.document.head);
    win.document.head.appendChild = (el) => { const r = origAppend(el); if (el.tagName === 'SCRIPT') setTimeout(() => el.onload && el.onload(), 0); return r; };
    win.jQuery = function () {};
    win.eval(RUNTIME);
    SOURCES.forEach((src) => win.eval(src));
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
    const root = (id) => win.document.querySelector(`[data-window="${id}"]`);
    return { win, rpcs, posts, notes, root };
}
function button(root, text) { return [...root.querySelectorAll('button')].find((b) => b.textContent.startsWith(text)); }
function safe(env, root) {
    eq(root.querySelectorAll('img').length, 0, 'server text became HTML');
    eq(root.querySelectorAll('[id]').length, 0, 'a module used an element id');
    eq(env.win.__xss, undefined, 'script ran');
}

const garageData = () => ({
    ok: true, feesDue: 500, cash: 0, bank: 1000, towFee: 175, towAvailable: true,
    garages: [{ id: 'motelgarage', label: EVIL, type: 'public', coords: { x: 274, y: -334 } }],
    vehicles: [
        { plate: 'PARK1', label: EVIL, status: 'garaged', fuel: 80, engine: 90, body: 50, location: { id: 'motelgarage', label: EVIL, coords: { x: 274, y: -334 } } },
        { plate: 'IMP1', label: 'Sultan', status: 'impounded', fee: 500, canPay: true, fuel: 10, engine: 30, body: 20, location: { label: 'Depot Lot', coords: { x: 401, y: -1632 } } },
        { plate: 'OUT1', label: 'Sultan', status: 'out', inWorld: true, canTow: true, fuel: 50, engine: 100, body: 100 },
        { plate: 'SEIZ1', label: 'Sultan', status: 'seized' },
    ],
});

(async () => {
    for (const device of ['tablet', 'computer']) {
        await it(`${device}: garages lists the cars as text and sends only the plate (and garage) to the server`, async () => {
            const env = makeWindow(device, {
                'garages.list': garageData,
                'garages.payDepot': () => ({ ok: true, paid: 500, depot: { label: 'Depot Lot' } }),
                'garages.locate': () => ({ ok: true, coords: { x: 1, y: 2 } }),
                'garages.requestTow': () => ({ ok: true, id: 3, garage: 'Motel' }),
            });
            await env.win.PFApps.refresh();
            await env.win.PFApps.open('garages');
            await settle();
            const root = env.root('garages');
            ok(root.querySelector('.pfg'), 'mounted');
            safe(env, root);
            ok(root.textContent.includes(EVIL), 'label shown as text');
            eq(root.querySelectorAll('.pfg-card').length, 4);
            button(root, 'Pay release').click();
            await settle();
            const pay = env.rpcs.find((r) => r.method === 'payDepot');
            eq(JSON.stringify(pay.payload), JSON.stringify({ plate: 'IMP1' }), 'pay payload');
            button(root, 'Request tow').click();
            await settle();
            const tow = env.rpcs.find((r) => r.method === 'requestTow');
            eq(tow.payload.plate, 'OUT1');
            eq(tow.payload.garage, 'motelgarage');
            eq(Object.keys(tow.payload).length, 2, 'tow payload has only plate and garage');
            button(root, 'Waypoint').click();
            await settle();
            const wp = env.posts.find((p) => p.name === 'setWaypoint');
            eq(wp.body.x, 274);
            // the tabs filter by state
            [...root.querySelectorAll('.pf-tab')].find((t) => t.textContent.startsWith('Impounded')).click();
            eq(root.querySelectorAll('.pfg-card').length, 1);
        });
    }

    await it('real estate: houses for sale and the agent offer, answered with its id only', async () => {
        const env = makeWindow('tablet', {
            'realestate.list': () => ({ ok: true, brokerPercent: 5, taxRate: 5, isAgent: false,
                forSale: [{ id: 'grove1', address: EVIL, price: 200000, tier: 1, garage: true, coords: { x: 1, y: 2 }, tax: 10000, doorTotal: 240000, agentTotal: 220000 }],
                mine: [{ id: 'mirror1', address: 'Mirror Park 1', tier: 2, role: 'owner', locked: true, garage: false, keys: 1, coords: { x: 3, y: 4 } }],
                apartment: { label: EVIL, building: 'Alta', coords: { x: 5, y: 6 } },
                offer: { id: 'o-1', address: EVIL, agent: EVIL, price: 200000, broker: 10000, tax: 10000, total: 220000 } }),
            'realestate.answerOffer': () => ({ ok: true }),
        });
        await env.win.PFApps.refresh();
        await env.win.PFApps.open('realestate');
        await settle();
        const root = env.root('realestate');
        safe(env, root);
        ok(root.querySelector('.pfr-offer'), 'offer banner');
        button(root, 'Accept and pay').click();
        await settle();
        const ans = env.rpcs.find((r) => r.method === 'answerOffer');
        eq(JSON.stringify(ans.payload), JSON.stringify({ id: 'o-1', accept: true }));
        [...root.querySelectorAll('.pf-tab')].find((t) => t.textContent.startsWith('My properties')).click();
        await settle();
        eq(root.querySelectorAll('.pfr-card').length, 2, 'apartment and house');
        safe(env, root);
    });

    await it('agency: reprices and offers a house to a customer next to the agent', async () => {
        const env = makeWindow('computer', {
            'realestate-agency.agency': () => ({ ok: true, onDuty: true, requireDuty: true, stats: { count: 1, agency: 2000, mine: 600 }, offer: null,
                commission: { agency: 10, agent: 3, broker: 5 }, priceRange: { min: 1000, max: 100000000 },
                listings: [{ id: 'grove1', address: EVIL, price: 200000, tier: 1, status: 'available', coords: { x: 1, y: 2 } },
                    { id: 'sold1', address: 'Sold St', price: 100000, tier: 1, status: 'sold' }],
                sales: [{ id: 1, house: 'x', address: EVIL, total: 220000, buyer: EVIL, agent: 'Me', mine: true, commission: 600, at: 1700000000 }] }),
            'realestate-agency.setPrice': () => ({ ok: true, price: 250000 }),
            'realestate-agency.nearby': () => ({ ok: true, players: [{ id: 7, name: EVIL }] }),
            'realestate-agency.offer': () => ({ ok: true, offer: { id: 'o-2' } }),
        });
        await env.win.PFApps.refresh();
        await env.win.PFApps.open('realestate-agency');
        await settle();
        const root = env.root('realestate-agency');
        safe(env, root);
        const input = root.querySelector('.pfr-price-input');
        input.value = '250000';
        button(root, 'Save price').click();
        await settle();
        const rp = env.rpcs.find((r) => r.method === 'setPrice');
        eq(JSON.stringify(rp.payload), JSON.stringify({ house: 'grove1', price: 250000 }));
        button(root, 'Sell').click();
        await settle();
        button(root, 'Look around').click();
        await settle();
        safe(env, root);
        button(root, 'Send offer').click();
        await settle();
        const offer = env.rpcs.find((r) => r.method === 'offer');
        eq(JSON.stringify(offer.payload), JSON.stringify({ house: 'grove1', target: 7 }));
        [...root.querySelectorAll('.pf-tab')].find((t) => t.textContent === 'Sales').click();
        safe(env, root);
    });

    await it('car dealer: catalogue with stock, finance payments by plate and the offer answer', async () => {
        const env = makeWindow('tablet', {
            'cardealer.catalog': () => ({ ok: true, purchaseTaxPercent: 8, registrationFee: 500, finance: { minDownPercent: 10, maxPayments: 24, intervalHours: 24 },
                offer: { id: 'd-1', kind: 'dealer', label: EVIL, seller: EVIL, shop: 'Luxury', price: 100000, amount: 100000, tax: 8000, total: 108000 },
                shops: [{ id: 'luxury', label: EVIL, managed: true, testDriveMinutes: 0.5, location: { x: 1, y: 2 },
                    models: [{ model: 'nero', name: EVIL, brand: 'Truffade', category: 'super', price: 200000, stock: 0, minDown: 20000, payments: 24, perPayment: 7500 },
                        { model: 'cog', name: 'Cognoscenti', brand: 'Enus', category: 'sedans', price: 100000, stock: 3, minDown: 10000, payments: 24, perPayment: 3750 }] }] }),
            'cardealer.finance': () => ({ ok: true, nextDue: 1000, cash: 0, bank: 5000, warningMinutes: 10, offer: null,
                vehicles: [{ plate: 'FIN1', label: EVIL, balance: 8000, payment: 1000, paymentsLeft: 8, dueInMinutes: 300, overdue: false, lastPayment: false }] }),
            'cardealer.pay': () => ({ ok: true, paid: 1000 }),
            'cardealer.answerOffer': () => ({ ok: true, plate: 'NEW1' }),
        });
        await env.win.PFApps.refresh();
        await env.win.PFApps.open('cardealer');
        await settle();
        const root = env.root('cardealer');
        safe(env, root);
        ok(root.textContent.includes('Out of stock'), 'stock badge');
        ok(root.textContent.includes('3 in stock'), 'stock count');
        button(root, 'Accept and pay').click();
        await settle();
        const ans = env.rpcs.find((r) => r.method === 'answerOffer');
        eq(JSON.stringify(ans.payload), JSON.stringify({ id: 'd-1', accept: true }));
        [...root.querySelectorAll('.pf-tab')].find((t) => t.textContent.startsWith('My finance')).click();
        await settle();
        safe(env, root);
        button(root, 'Pay $').click();
        await settle();
        const pay = env.rpcs.find((r) => r.method === 'pay');
        eq(JSON.stringify(pay.payload), JSON.stringify({ plate: 'FIN1' }), 'the client named no amount');
    });

    await it('dealership: a finance offer sends model, customer and terms only; stock orders by model and quantity', async () => {
        const env = makeWindow('computer', {
            'cardealer-sales.init': () => ({ ok: true, balance: 50000, canOrder: true, offers: [], sales: [], plans: [], onDuty: true, saleDistance: 3,
                stats: { count: 0, revenue: 0, mine: 0 }, finance: { minDownPercent: 10, maxPayments: 24 }, commission: { sale: 0.1, finance: 0.05 },
                stock: { tracked: true, maxOrder: 10 },
                shops: [{ id: 'luxury', label: 'Luxury', models: [{ model: 'cog', name: EVIL, price: 100000, stock: 2, wholesale: 70000 }] }] }),
            'cardealer-sales.nearby': () => ({ ok: true, players: [{ id: 4, name: EVIL }] }),
            'cardealer-sales.offer': () => ({ ok: true, offer: { total: 28000 } }),
            'cardealer-sales.orderStock': () => ({ ok: true, cost: 140000 }),
        });
        await env.win.PFApps.refresh();
        await env.win.PFApps.open('cardealer-sales');
        await settle();
        const root = env.root('cardealer-sales');
        safe(env, root);
        const selects = root.querySelectorAll('select');
        const mode = [...selects].find((s) => [...s.options].some((o) => o.value === 'finance'));
        mode.value = 'finance';
        mode.dispatchEvent(new env.win.Event('change'));
        const [down, payments] = [...root.querySelectorAll('input[type="number"]')];
        down.value = '20000';
        down.dispatchEvent(new env.win.Event('input'));
        payments.value = '10';
        payments.dispatchEvent(new env.win.Event('input'));
        button(root, 'Look around').click();
        await settle();
        button(root, 'Send offer').click();
        await settle();
        const offer = env.rpcs.find((r) => r.method === 'offer');
        eq(JSON.stringify(offer.payload), JSON.stringify({ model: 'cog', target: 4, finance: { down: 20000, payments: 10 } }));
        [...root.querySelectorAll('.pf-tab')].find((t) => t.textContent === 'Stock').click();
        await settle();
        root.querySelector('.pfd-qty').value = '2';
        button(root, 'Order').click();
        await settle();
        const order = env.rpcs.find((r) => r.method === 'orderStock');
        eq(JSON.stringify(order.payload), JSON.stringify({ shop: 'luxury', model: 'cog', qty: 2 }));
        safe(env, root);
    });

    await it('used cars: listings as text, my own listing repriced by id', async () => {
        const env = makeWindow('tablet', {
            'usedcars.list': () => ({ ok: true, taxPercent: 8, lots: [{ id: 'Sandy', label: EVIL, coords: { x: 1213, y: 2735 } }],
                listings: [{ id: 'OC1', plate: 'USED1', label: EVIL, price: 10000, tax: 800, description: EVIL, seller: EVIL, phone: '555', mine: false },
                    { id: 'OC2', plate: 'USED2', label: 'Sultan', price: 5000, tax: 400, description: '', mine: true }] }),
            'usedcars.reprice': () => ({ ok: true, price: 4500 }),
        });
        await env.win.PFApps.refresh();
        await env.win.PFApps.open('usedcars');
        await settle();
        const root = env.root('usedcars');
        safe(env, root);
        eq(root.querySelectorAll('.pfu-card').length, 2);
        root.querySelector('.pfu-price-input').value = '4500';
        button(root, 'Change price').click();
        await settle();
        const rp = env.rpcs.find((r) => r.method === 'reprice');
        eq(JSON.stringify(rp.payload), JSON.stringify({ id: 'OC2', price: 4500 }));
        button(root, 'Waypoint').click();
        await settle();
        eq(env.posts.find((p) => p.name === 'setWaypoint').body.x, 1213);
    });

    await it('several of these apps open at once stay inside their own windows', async () => {
        const env = makeWindow('computer', {
            'garages.list': garageData,
            'usedcars.list': () => ({ ok: true, taxPercent: 0, lots: [], listings: [] }),
        });
        await env.win.PFApps.refresh();
        await env.win.PFApps.open('garages');
        await env.win.PFApps.open('usedcars');
        await settle();
        eq(env.root('garages').querySelectorAll('.pfg-card').length, 4);
        ok(env.root('usedcars').textContent.includes('No car is for sale'), 'used cars empty state');
        eq(env.root('usedcars').querySelectorAll('.pfg-card').length, 0);
        env.win.PFApps.close('garages');
        ok(!env.root('garages'), 'closed');
        ok(env.root('usedcars'), 'the other app stays');
    });

    console.log(`${failed ? 'FAIL' : 'ok  '}  vehicle_property_apps_spec.js  (${passed} passed, ${failed} failed)`);
    failures.forEach((f) => console.log('  - ' + f));
    process.exit(failed ? 1 : 0);
})();
