// pf-computer Order Supplies (a pf-devices app) shows what a supply order costs: a pickup is the
// goods; a delivery is the goods plus the wholesale markup and the trucker's freight on top (pf-stores
// PFOrders.Quote). The cart estimate uses the pricing the server sends (deliveryPricing); without it
// the cart says the extras are added. After ordering, the amount charged comes from the server, and
// a refund that is still owed is said to be pending. Display only: the payload stays item + quantity.
// Run: node js/ordersupplies_totals_spec.js
const fs = require('fs');
const path = require('path');
const { JSDOM } = require('jsdom');

const PF = path.resolve(__dirname, '..', '..', '..', '[pfscripts]');
const RUNTIME = fs.readFileSync(path.join(PF, 'pf-devices/html/runtime.js'), 'utf8');
const MODULE = fs.readFileSync(path.join(PF, 'pf-computer/html/apps/ordersupplies.js'), 'utf8');

let passed = 0;
let failed = 0;
const failures = [];
async function it(name, fn) {
    try { await fn(); passed++; } catch (e) { failed++; failures.push(`${name}: ${e && e.stack || e}`); }
}
function eq(a, b, msg) { if (a !== b) throw new Error(`${msg || 'expected'}: ${JSON.stringify(b)}, got ${JSON.stringify(a)}`); }
function ok(v, msg) { if (!v) throw new Error(msg || 'expected truthy'); }
const tick = () => new Promise((r) => setTimeout(r, 0));
async function settle() { for (let i = 0; i < 20; i++) await tick(); }

const EVIL = '<b class="evil">x</b><img src=x onerror="window.__xss=1">';
const APPS = [{ id: 'ordersupplies', name: 'Order Supplies', icon: '', kind: 'module', entry: 'https://cfx-nui-pf-computer/html/apps/ordersupplies.js', styles: [] }];

function makeWindow(handlers) {
    const dom = new JSDOM('<!doctype html><html><head></head><body><div id="shell"></div></body></html>', { runScripts: 'outside-only', url: 'https://cfx-nui-pf-tablet/html/index.html' });
    const win = dom.window;
    const rpcs = [];
    const errors = [];
    win.addEventListener('error', (e) => errors.push(e.message || String(e.error)));
    win.console.error = (...a) => errors.push(a.map(String).join(' '));
    win.fetch = async (url, opts) => {
        const name = String(url).replace(/^https:\/\/[^/]+\//, '');
        const body = JSON.parse(opts && opts.body || '{}');
        let result = { ok: true };
        if (name === 'apps') result = { apps: APPS, store: [], categories: [] };
        else if (name === 'rpc') {
            rpcs.push(body);
            const fn = handlers[`${body.app}.${body.method}`];
            result = fn ? fn(body.payload) : { ok: false, error: 'unknown_method' };
        }
        return { json: async () => JSON.parse(JSON.stringify(result)) };
    };
    const origAppend = win.document.head.appendChild.bind(win.document.head);
    win.document.head.appendChild = (el) => { const r = origAppend(el); if (el.tagName === 'SCRIPT') setTimeout(() => el.onload && el.onload(), 0); return r; };
    win.jQuery = function () {};
    win.eval(RUNTIME);
    win.eval(MODULE);
    const notes = [];
    win.PFApps.attachShell({
        device: 'tablet',
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
    const shell = () => win.document.getElementById('shell');
    return {
        win, rpcs, notes,
        text: () => shell().textContent,
        all: (sel) => [...shell().querySelectorAll(sel)],
        button: (text) => [...shell().querySelectorAll('button')].find((b) => b.textContent.trim() === text),
        async open() { await win.PFApps.refresh(); await win.PFApps.open('ordersupplies'); await settle(); },
        async tab(prefix) { this.all('.pf-tab').find((t) => t.textContent.startsWith(prefix)).click(); await settle(); },
        async chip(label) { this.all('.pfbiz-chip').find((c) => c.textContent === label).click(); await settle(); },
        clean() {
            eq(shell().querySelectorAll('.evil').length, 0, 'a server string became HTML');
            eq(win.__xss, undefined, 'a script ran');
            eq(shell().querySelectorAll('[id]').length, 0, 'the app made element ids');
            eq(errors.length, 0, 'errors: ' + errors.join(' | '));
        },
    };
}

// a store with one item at $25 a case; delivery pricing as pf-stores GetDeliveryPricing returns it
const PRICING = { markupRate: 0.15, freight: { rate: 0.12, flat: 0, min: 150, max: 0 }, markupRefundShare: 0.5 };
function handlers(opts) {
    opts = opts || {};
    return {
        'ordersupplies.catalog': () => ({ ok: true, data: {
            mode: 'store', storeId: 's1', stores: [{ storeId: 's1', label: EVIL }], businessName: EVIL, businessType: 'store', balance: 5000,
            deliveryAvailable: true, deliveryPricing: opts.pricing,
            catalog: { categories: [{ id: 'Snacks', label: EVIL }], items: [{ item: 'chips', label: EVIL, category: 'Snacks', caseSize: 1, caseContents: EVIL, pricePerCase: 25 }] },
        } }),
        'ordersupplies.orders': () => ({ ok: true, data: [
            { id: 8, createdAt: Date.now(), status: 'pending', orderStatus: 'awaiting_delivery', fulfillment: 'delivery', total: 236.25,
              subtotal: 75, markup: 11.25, freight: 150, items: [{ label: EVIL, quantity: 3 }], cancellable: true },
        ] }),
        'ordersupplies.create': () => ({ ok: true, message: EVIL, data: { orderId: 9, total: 236.25, subtotal: 75, markup: 11.25, freight: 150 } }),
        'ordersupplies.cancel': () => (opts.refundPending ? { ok: true, data: { orderId: 8, refundPending: true } } : { ok: true, data: { orderId: 8, refunded: 236.25 } }),
    };
}

async function cartWithThree(env) {
    const qty = env.all('.pfbiz-supply input')[0];
    qty.value = '3';
    env.button('Add to cart').click();
    await settle();
    await env.tab('Cart');
}

(async () => {
    await it('a pickup shows the goods as the total; a delivery adds the markup and the freight minimum on top', async () => {
        const env = makeWindow(handlers({ pricing: PRICING }));
        await env.open();
        await cartWithThree(env);
        ok(env.text().includes('Total $75'), 'pickup: goods only');
        await env.chip('Trucker delivery');
        const t = env.text();
        ok(t.includes('Goods$75'), 'goods line: ' + t);
        ok(t.includes('Wholesale markup (15%)$11.25'), 'markup line');
        ok(t.includes('Freight (the trucker\'s pay)$150'), 'freight: the minimum, though 12 % of $75 is $9');
        ok(t.includes('Total about $236.25'), 'goods + markup + freight');
        ok(t.includes('$5.63 of the markup comes back'), 'the player-supplier refund is explained');
        env.clean();
    });

    await it('without pricing from the server the cart says the extras are added, and shows no made-up total', async () => {
        const env = makeWindow(handlers({}));
        await env.open();
        await cartWithThree(env);
        await env.chip('Trucker delivery');
        const t = env.text();
        ok(t.includes('adds the wholesale markup and the trucker\'s freight on top'), t);
        ok(!t.includes('Total about'), 'no estimate without the server\'s pricing');
        env.clean();
    });

    await it('placing the order shows what the server charged; the payload stays item and quantity', async () => {
        const env = makeWindow(handlers({ pricing: PRICING }));
        await env.open();
        await cartWithThree(env);
        await env.chip('Trucker delivery');
        env.button('Place order').click();
        await settle();
        const create = env.rpcs.find((r) => r.method === 'create');
        eq(JSON.stringify(create.payload.items), JSON.stringify([{ item: 'chips', quantity: 3 }]), 'no price from the client');
        const note = env.notes.map((n) => n.m).join(' | ');
        ok(note.includes('Order #9: $236.25 charged (goods $75 + markup $11.25 + freight $150)'), note);
        // the order card: the charged total and its parts
        const t = env.text();
        ok(t.includes('$236.25'), 'order total');
        ok(t.includes('goods $75 + markup $11.25 + freight $150'), 'order breakdown');
        env.clean();
    });

    await it('a cancel says whether the refund was paid or is still owed', async () => {
        let env = makeWindow(handlers({ pricing: PRICING }));
        await env.open();
        await env.tab('Orders');
        env.button('Cancel and refund').click();
        await settle();
        ok(env.notes.some((n) => n.m === 'Order cancelled: $236.25 refunded'), env.notes.map((n) => n.m).join(' | '));
        env = makeWindow(handlers({ pricing: PRICING, refundPending: true }));
        await env.open();
        await env.tab('Orders');
        env.button('Cancel and refund').click();
        await settle();
        ok(env.notes.some((n) => n.m.includes('refund could not be paid yet') && n.m.includes('retried')), env.notes.map((n) => n.m).join(' | '));
        env.clean();
    });

    console.log(`${passed} passed, ${failed} failed`);
    failures.forEach((f) => console.log('  - ' + f));
    // the app's refresh timer would keep node running
    process.exit(failed ? 1 : 0);
})();
