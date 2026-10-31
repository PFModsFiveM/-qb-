// pf-computer's shared apps (Business Manager, Order Supplies, Job Board) in a simulated browser
// (jsdom) on the pf-devices runtime, on the tablet and the computer: they mount, every section and
// tab renders, server strings never become HTML, they make no global element ids, and the payloads
// they send carry only what the server reads (no positions, prices or identities from the client).
// Run: node js/computer_business_apps_spec.js
const fs = require('fs');
const path = require('path');
const { JSDOM } = require('jsdom');

const PF = path.resolve(__dirname, '..', '..', '..', '[pfscripts]');
const RUNTIME = fs.readFileSync(path.join(PF, 'pf-devices/html/runtime.js'), 'utf8');
const IDS = ['businessmanager', 'ordersupplies', 'jobboard'];
const MODULES = IDS.map((m) => fs.readFileSync(path.join(PF, `pf-computer/html/apps/${m}.js`), 'utf8'));

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
const APPS = IDS.map((id) => ({ id, name: id, icon: '', kind: 'module', entry: `https://cfx-nui-pf-computer/html/apps/${id}.js`, styles: [] }));
const now = Math.floor(Date.now() / 1000);

function makeWindow(device, handlers) {
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
    const shell = () => win.document.getElementById('shell');
    return {
        win, rpcs, notes, errors,
        $: (sel) => shell().querySelector(sel),
        all: (sel) => [...shell().querySelectorAll(sel)],
        button: (text) => [...shell().querySelectorAll('button')].find((b) => b.textContent.trim() === text),
        clean() {
            eq(shell().querySelectorAll('.evil').length, 0, 'a server string became HTML');
            eq(win.__xss, undefined, 'a script ran');
            eq(shell().querySelectorAll('[id]').length, 0, 'the app made element ids');
            eq(errors.length, 0, 'errors: ' + errors.join(' | '));
        },
    };
}

// ── server answers, with hostile strings everywhere ─────────────────────────────
const bmHandlers = () => ({
    'businessmanager.init': () => ({
        ok: true, business: true, registry: true, access: { business: true, isBoss: true },
        config: { ok: true, data: { job: 'burgershot', businessName: EVIL, businessType: 'restaurant', logoUrl: 'javascript:alert(1)',
            businessTypeConfig: { name: EVIL, icon: '🍔', menuCategories: [EVIL, 'Burgers'], ingredients: [{ name: EVIL, cost: 1.5 }] } } },
        data: { ok: true, data: { stats: { today: { revenue: 10, sales: 1, moneyIn: 20, moneyOut: 5 }, week: { revenue: 70 }, month: { revenue: 300 } }, balance: 1234 } },
        employees: { ok: true, data: [{ citizenid: 'E1', name: EVIL, grade: 1, rank: EVIL, online: true, onDuty: true, salary: 50 },
            { citizenid: 'B1', name: 'Boss', grade: 4, rank: 'Owner', isBoss: true }], grades: [{ level: 0, label: EVIL }, { level: 1, label: 'Cook' }] },
        transactions: { ok: true, data: [{ id: 'tx1', type: EVIL, amount: 25, incoming: true, description: EVIL, processedBy: EVIL, date: '2026-10-30T10:00:00Z',
            items: [{ name: EVIL, quantity: 2, price: 5 }] }] },
        menu: { ok: true, data: [{ id: 3, name: EVIL, description: EVIL, category: EVIL, price: 9, cost: 3, available: true }] },
        meals: { ok: true, data: [{ id: 4, name: EVIL, description: EVIL, items: [{ itemId: 3, quantity: 2 }], price: 15, available: true }] },
    }),
    'businessmanager.data': () => ({ ok: true, data: { stats: null } }),
    'businessmanager.transactions': () => ({ ok: true, data: [] }),
    'businessmanager.analytics': () => ({ ok: true, data: { totalRevenue: 50, totalSales: 3, averageTicket: 16.6, taxPaid: 5, moneyIn: 60, moneyOut: 10,
        byKind: [{ kind: EVIL, count: 2, moneyIn: 60, moneyOut: 10 }], byDay: [{ day: '2026-10-29', revenue: 20 }, { day: '2026-10-30', revenue: 30 }] } }),
    'businessmanager.categories': () => ({ ok: true, data: [EVIL, 'General'] }),
    'businessmanager.menuAdd': () => ({ ok: true, data: { id: 5 } }),
    'businessmanager.menuEdit': () => ({ ok: true }),
    'businessmanager.menuDelete': () => ({ ok: true }),
    'businessmanager.menu': () => ({ ok: true, data: [{ id: 3, name: EVIL, description: EVIL, category: EVIL, price: 9, cost: 3, available: true }] }),
    'businessmanager.meals': () => ({ ok: true, data: [] }),
    'businessmanager.employees': () => ({ ok: true, data: [], grades: [] }),
    'businessmanager.wages': () => ({ ok: true, data: { job: 'burgershot', grades: [{ level: 0, label: EVIL, wage: 50, cap: 100 }, { level: 1, label: 'Cook', wage: 70, cap: 150 }] } }),
    'businessmanager.wagesSet': () => ({ ok: true, data: { grades: [] } }),
    'businessmanager.account': () => ({ ok: true, data: { balance: 500, transactions: [{ type: EVIL, amount: 10, incoming: false, description: EVIL, date: '2026-10-30T10:00:00Z' }] } }),
    'businessmanager.deposit': () => ({ ok: true, data: { balance: 600, transactions: [] } }),
    'businessmanager.stock': () => ({ ok: true, data: { items: [{ name: 'bun', label: EVIL, amount: 12, area: EVIL, freshness: { label: EVIL, pct: 80 } }] } }),
    'businessmanager.premises': () => ({ ok: true, data: { slots: [{ id: 1, label: EVIL, slot_type: 'grill' }, { id: 2, label: 'Fryer', slot_type: 'fryer', equipment_type: EVIL }],
        catalog: [{ key: 'grill_basic', label: EVIL, slotType: 'grill', price: 500 }] } }),
    'businessmanager.premisesBuy': () => ({ ok: true }),
    'businessmanager.settings': () => ({ ok: true }),
    'businessmanager.blipHere': () => ({ ok: true }),
    'businessmanager.stashHere': () => ({ ok: true, data: { count: 2 } }),
    'businessmanager.deliveryPoint': () => ({ ok: true }),
    'businessmanager.registry': () => ({ ok: true,
        businesses: [{ id: 'store:1', name: EVIL, owner: EVIL, ownerId: 'C1', type: EVIL, status: 'Open', revenueWeek: 10, revenueMonth: 40, taxMonth: 4,
            licenseStatus: 'None', compliance: EVIL, taxStatus: 'Late', taxDebt: 20, bills: [{ id: 9, type: EVIL, owed: 20, status: 'unpaid', description: EVIL }],
            balance: 100, location: EVIL, sales30d: 2, permits: [EVIL], warnings: [EVIL], activityLog: [{ date: EVIL, action: EVIL, actor: EVIL }], transferable: true }],
        stats: { totalBusinesses: 1, activeBusinesses: 1, revenueToday: 1, revenueWeek: 10, revenueMonth: 40, taxMonth: 4 },
        alerts: { unpaidTaxes: 1, unlicensed: 1, incomeSpikes: 0 }, auditLog: [{ timestamp: EVIL, action: EVIL, actor: EVIL, target: EVIL }],
        citizens: [{ citizenId: 'C2', name: EVIL }] }),
    'businessmanager.registryEmployees': () => ({ ok: true, employees: [{ name: EVIL, role: EVIL }] }),
    'businessmanager.registryTransfer': () => ({ ok: true }),
});

const osHandlers = (mode) => ({
    'ordersupplies.catalog': () => ({ ok: true, data: { mode: mode || 'job', businessId: 'mechanic', businessName: EVIL, businessType: 'mechanic', deliveryAvailable: true,
        canSwitch: true, balance: 900, storeId: mode === 'store' ? 's1' : undefined, stores: mode === 'store' ? [{ storeId: 's1', label: EVIL }, { storeId: 's2', label: 'Two' }] : undefined,
        catalog: { imageBase: 'https://cfx-nui-pfm-inventory/html/images/', categories: [{ id: 'Parts', label: EVIL }],
            items: [{ item: 'brake_pad', label: EVIL, category: 'Parts', caseSize: 10, caseContents: EVIL, pricePerCase: 75 }] } } }),
    'ordersupplies.orders': () => ({ ok: true, data: [
        { id: 7, createdAt: Date.now(), status: 'ready', orderStatus: 'ready', fulfillment: 'pickup', total: 150, totalCases: 2, items: [{ name: 'brake_pad', label: EVIL, quantity: 2 }], cancellable: false },
        { id: 8, createdAt: now, status: 'pending', orderStatus: 'awaiting_delivery', fulfillment: 'delivery', total: 75, items: [], cancellable: true },
        { id: 6, createdAt: now, status: 'picked_up', orderStatus: 'unpacked', fulfillment: 'pickup', total: 75, items: [{ label: EVIL, quantity: 1 }] }] }),
    'ordersupplies.create': () => ({ ok: true, data: { orderId: 9 } }),
    'ordersupplies.pickup': () => ({ ok: true }),
    'ordersupplies.cancel': () => ({ ok: true, data: { refunded: 75 } }),
    'ordersupplies.deliveryPoint': () => ({ ok: true }),
});

const jbHandlers = () => ({
    'jobboard.list': () => ({ ok: true, data: [{ id: 1, title: EVIL, company: EVIL, location: EVIL, salary: EVIL, type: EVIL, category: EVIL, description: EVIL,
        tags: [EVIL], posterName: EVIL, createdAt: now, hires: true, hireKind: 'job' }] }),
    'jobboard.businesses': () => ({ ok: true, data: [{ key: 'gov:restaurant:bs', name: EVIL, hires: true, hireKind: 'restaurant', grades: [], roles: [{ id: 'cashier', label: EVIL }] }] }),
    'jobboard.catalog': () => ({ ok: true, data: [{ job: 'taxi', label: EVIL, jobCentre: true, openPosts: 0 }, { job: 'mechanic', label: 'Mechanic', managed: true, openPosts: 2 }] }),
    'jobboard.myApplications': () => ({ ok: true, data: [{ id: 3, title: EVIL, company: EVIL, status: 'offered', offerRank: EVIL, createdAt: now }] }),
    'jobboard.myJobs': () => ({ ok: true, data: [{ id: 2, title: EVIL, company: EVIL, status: 'open', applicantCount: 1, waiting: 1, createdAt: now }] }),
    'jobboard.applicants': () => ({ ok: true, post: { business: 'gov:restaurant:bs', hires: true, hireKind: 'restaurant' },
        data: [{ id: 11, name: EVIL, phone: EVIL, experience: EVIL, message: EVIL, status: 'pending', createdAt: now, online: true }] }),
    'jobboard.apply': () => ({ ok: true }),
    'jobboard.hire': () => ({ ok: true, data: { status: 'hired', rank: 'Cashier' } }),
    'jobboard.respond': () => ({ ok: true, data: { status: 'hired' } }),
    'jobboard.create': () => ({ ok: true }),
});

async function open(env, id, params) {
    await env.win.PFApps.refresh();
    await env.win.PFApps.open(id, params);
    await settle();
}

(async () => {
    for (const device of ['tablet', 'computer']) {
        await it(`${device}: Business Manager renders every section from server data as text`, async () => {
            const env = makeWindow(device, bmHandlers());
            await open(env, 'businessmanager');
            ok(env.$('.pfbiz-bm'), 'mounted');
            const navs = env.all('.pf-nav-item');
            eq(navs.length, 15, 'ten business and five registry sections');
            for (let i = 0; i < navs.length; i++) {
                env.all('.pf-nav-item')[i].click();
                await settle();
                ok(env.$('.pfbiz-section-title'), `section ${i} has a title`);
                env.clean();
            }
            eq(env.all('.pfbiz-head-logo').length, 0, 'a javascript: logo is not shown');
        });

        await it(`${device}: Order Supplies renders every tab, in job and store mode`, async () => {
            for (const mode of ['job', 'store']) {
                const env = makeWindow(device, osHandlers(mode));
                await open(env, 'ordersupplies');
                ok(env.$('.pfbiz-os'), 'mounted');
                env.button('Add to cart').click();
                await settle();
                for (const tab of env.all('.pf-tab').map((t) => t.textContent)) {
                    env.all('.pf-tab').find((t) => t.textContent === tab).click();
                    await settle();
                    env.clean();
                }
                if (mode === 'store') ok(env.$('.pf-app-header select'), 'store picker for two stores');
            }
        });

        await it(`${device}: Job Board renders every tab and the applicants`, async () => {
            const env = makeWindow(device, jbHandlers());
            await open(env, 'jobboard');
            ok(env.$('.pfbiz-jb'), 'mounted');
            eq(env.all('.pf-tab').length, 4, 'my business tab for a manager');
            for (let i = 0; i < 4; i++) {
                env.all('.pf-tab')[i].click();
                await settle();
                env.clean();
            }
            env.button('Applicants').click();
            await settle();
            ok(env.$('.pfbiz-applicant'), 'applicant shown');
            env.clean();
        });
    }

    await it('Business Manager sends no position, business id or cost it did not compute', async () => {
        const env = makeWindow('computer', bmHandlers());
        await open(env, 'businessmanager');
        env.all('.pf-nav-item').find((n) => n.textContent.includes('Settings')).click();
        await settle();
        env.button('Place a stock stash point here').click();
        env.button('Move the map blip here').click();
        await settle();
        const stash = env.rpcs.find((r) => r.method === 'stashHere');
        const blip = env.rpcs.find((r) => r.method === 'blipHere');
        ok(stash && blip, 'both sent');
        eq(stash.payload.coords, undefined, 'stash position read on the server');
        eq(blip.payload.coords, undefined, 'blip position read on the server');
        eq(blip.payload.businessId, undefined, 'the server knows the business');
        env.button('Save').click();
        await settle();
        const settings = env.rpcs.find((r) => r.method === 'settings');
        eq(Object.keys(settings.payload).sort().join(','), 'blipColor,logoUrl,name');
    });

    await it('Business Manager: add a menu item through the in-app dialog, delete with an in-app confirmation', async () => {
        const env = makeWindow('tablet', bmHandlers());
        await open(env, 'businessmanager');
        env.all('.pf-nav-item').find((n) => n.textContent === '🍽️Menu').click();
        await settle();
        env.button('Add item').click();
        await settle();
        const dialog = env.$('.pfbiz-dialog');
        ok(dialog, 'dialog inside the app');
        const name = dialog.querySelector('input.pf-input');
        const price = dialog.querySelector('input.pf-input[type=number]');
        name.value = 'Fries';
        price.value = '4.5';
        dialog.querySelector('.pfbiz-pick input[type=checkbox]').click();
        env.button('Save').click();
        await settle();
        const add = env.rpcs.find((r) => r.method === 'menuAdd');
        ok(add, 'menuAdd sent');
        eq(add.payload.item.name, 'Fries');
        eq(add.payload.item.price, 4.5);
        eq(add.payload.item.cost, 1.5, 'cost from the picked ingredient');
        env.button('Delete').click();
        await settle();
        eq(env.rpcs.filter((r) => r.method === 'menuDelete').length, 0, 'nothing deleted before confirming');
        env.button('Remove').click();
        await settle();
        eq(env.rpcs.find((r) => r.method === 'menuDelete').payload.itemId, 3);
        env.clean();
    });

    await it('Business Manager: wages send only changed grades; deposits go through the account action', async () => {
        const env = makeWindow('computer', bmHandlers());
        await open(env, 'businessmanager');
        env.all('.pf-nav-item').find((n) => n.textContent.includes('Wages')).click();
        await settle();
        const inputs = env.all('.pfbiz-bm table input');
        inputs[1].value = '90';
        env.button('Save wages').click();
        await settle();
        const set = env.rpcs.find((r) => r.method === 'wagesSet');
        eq(JSON.stringify(set.payload.wages), JSON.stringify({ 1: 90 }));
        env.all('.pf-nav-item').find((n) => n.textContent.includes('Company account')).click();
        await settle();
        env.$('.pfbiz-bm input[type=number]').value = '100';
        env.button('Deposit from my bank').click();
        await settle();
        eq(env.rpcs.find((r) => r.method === 'deposit').payload.amount, 100);
    });

    await it('Order Supplies sends item names and quantities only; the server prices the cart', async () => {
        const env = makeWindow('tablet', osHandlers('job'));
        await open(env, 'ordersupplies');
        env.button('Add to cart').click();
        await settle();
        env.all('.pf-tab').find((t) => t.textContent.startsWith('Cart')).click();
        await settle();
        [...env.all('.pfbiz-chip')].find((c) => c.textContent === 'Trucker delivery').click();
        await settle();
        env.button('Place order').click();
        await settle();
        const create = env.rpcs.find((r) => r.method === 'create');
        eq(create.payload.fulfillment, 'delivery');
        eq(JSON.stringify(create.payload.items), JSON.stringify([{ item: 'brake_pad', quantity: 1 }]));
        eq(JSON.stringify(Object.keys(create.payload.items[0])), JSON.stringify(['item', 'quantity']), 'no price from the client');
        // orders: collect a ready order, cancel a waiting delivery
        env.button('Collect').click();
        await settle();
        eq(env.rpcs.find((r) => r.method === 'pickup').payload.orderId, 7);
        env.button('Cancel and refund').click();
        await settle();
        eq(env.rpcs.find((r) => r.method === 'cancel').payload.orderId, 8);
    });

    await it('Job Board: apply, hire into a restaurant role, accept an offer', async () => {
        const env = makeWindow('computer', jbHandlers());
        await open(env, 'jobboard');
        env.button('Apply').click();
        await settle();
        env.$('.pfbiz-jb textarea').value = 'Two years';
        env.button('Send application').click();
        await settle();
        const apply = env.rpcs.find((r) => r.method === 'apply');
        eq(apply.payload.jobId, 1);
        eq(apply.payload.experience, 'Two years');
        ok(!('name' in apply.payload) && !('phone' in apply.payload), 'no identity from the client');
        env.all('.pf-tab')[3].click();
        await settle();
        env.button('Applicants').click();
        await settle();
        env.button('Hire').click();
        await settle();
        const hire = env.rpcs.find((r) => r.method === 'hire');
        eq(hire.payload.applicationId, 11);
        eq(hire.payload.role, 'cashier');
        env.all('.pf-tab')[2].click();
        await settle();
        env.button('Accept the offer').click();
        await settle();
        eq(env.rpcs.find((r) => r.method === 'respond').payload.accept, true);
        env.clean();
    });

    await it('pushes refresh an open app', async () => {
        const env = makeWindow('tablet', jbHandlers());
        await open(env, 'jobboard');
        const before = env.rpcs.filter((r) => r.method === 'list').length;
        env.win.PFApps.handleMessage({ action: 'pfapp:event', app: 'jobboard', event: 'posts', payload: {} });
        await settle();
        eq(env.rpcs.filter((r) => r.method === 'list').length, before + 1, 'the board reloaded');
    });

    await it('an app the player may not use says why instead of crashing', async () => {
        const env = makeWindow('tablet', { 'businessmanager.init': () => ({ ok: true, business: false, registry: false }),
            'ordersupplies.catalog': () => ({ ok: false, error: 'job_not_allowed' }) });
        await open(env, 'businessmanager');
        ok(env.$('.pfbiz-bm .pf-empty'), 'explained');
        await open(env, 'ordersupplies');
        ok(env.$('.pfbiz-os .pf-empty').textContent.includes('no business'), 'explained');
        env.clean();
    });

    await it('the computer page boots without the old windows; the lock screen and layout come from the server', async () => {
        const UI = path.join(PF, 'pf-computer/ui');
        const html = fs.readFileSync(path.join(UI, 'index.html'), 'utf8').replace(/<script[\s\S]*?<\/script>/g, '');
        const dom = new JSDOM(html, { runScripts: 'outside-only', url: 'https://cfx-nui-pf-computer/ui/index.html' });
        const win = dom.window;
        const errors = [];
        win.addEventListener('error', (e) => errors.push(String(e.error && e.error.stack || e.message)));
        const sent = [];
        win.fetch = async (url, opts) => {
            const name = String(url).replace(/^https:\/\/[^/]+\//, '');
            const body = JSON.parse(opts && opts.body || '{}');
            sent.push({ name, body });
            let r = { ok: true, data: {} };
            if (name === 'pc:getExternalPrograms') r = { ok: true, data: [] };
            if (name === 'pc:getPlayerData') r = { ok: true, data: { citizenid: 'ABC', name: 'Test User' } };
            if (name === 'pc:profile:get') r = { ok: true, layout: { items: [{ id: 'business-manager', app: 'business-manager', type: 'app', location: 'desktop', position: { x: 1, y: 1 } }],
                folders: [{ id: 'f1', name: EVIL, location: 'desktop', position: { x: 3, y: 3 } }] },
                security: { enabled: true, method: 'pin', hasPin: true, locked: true, fails: 0, attemptsLeft: 5, timeoutRemaining: 0, lockdownRemaining: 0 } };
            if (name === 'pc:lock:unlock') r = body.secret === '2468' ? { ok: true, security: { enabled: true, method: 'pin', hasPin: true, locked: false, fails: 0 } }
                : { ok: false, error: 'wrong_secret', security: { enabled: true, method: 'pin', hasPin: true, locked: true, fails: 1, attemptsLeft: 4, timeoutRemaining: 0 } };
            return { json: async () => JSON.parse(JSON.stringify(r)) };
        };
        const deep = () => new Proxy(function () {}, { get: (t, k) => (k === Symbol.toPrimitive ? () => 0 : (k === 'then' ? undefined : deep())), apply: () => deep(), set: () => true });
        win.HTMLCanvasElement.prototype.getContext = () => deep();
        win.requestAnimationFrame = (f) => setTimeout(f, 0);
        win.cancelAnimationFrame = (id) => clearTimeout(id);
        win.console.log = () => {};
        win.console.warn = () => {};
        // the page's scripts share one global scope in the browser: evaluate them together
        win.eval(['js/rte.js', 'js/games.js', 'js/script.js'].map((f) => fs.readFileSync(path.join(UI, f), 'utf8')).join('\n;\n'));
        win.document.dispatchEvent(new win.Event('DOMContentLoaded'));
        await settle();
        win.postMessage({ action: 'openComputer', computerProfile: 'default', computerStateKey: 'profile:default:model:1:pos:1,2,3' }, '*');
        await new Promise((r) => setTimeout(r, 300));
        for (const a of ['business-manager', 'order-supplies', 'job-board']) eq(!!win.document.querySelector(`.window[data-app="${a}"]`), false, `old ${a} window`);
        eq(win.document.querySelectorAll('.evil').length, 0, 'a folder name became HTML');
        eq(win.document.querySelectorAll('.icon[data-app="business-manager"]').length, 0, 'the old Business Manager desktop item is dropped');
        const overlay = win.document.querySelector('.pc-lockscreen-overlay');
        ok(overlay && overlay.style.display === 'flex', 'locked on the server: lock screen shown');
        win.document.querySelector('#pc-lock-idle-unlock').click();
        await settle();
        win.document.querySelector('#pc-lock-auth-input').value = '1111';
        win.document.querySelector('#pc-lock-auth-submit').click();
        await settle();
        ok(win.document.querySelector('#pc-lock-feedback').textContent.includes('4 attempts'), 'the server counts the tries');
        win.document.querySelector('#pc-lock-auth-input').value = '2468';
        win.document.querySelector('#pc-lock-auth-submit').click();
        await settle();
        eq(overlay.style.display, 'none', 'unlocked by the server');
        const unlocks = sent.filter((x) => x.name === 'pc:lock:unlock');
        eq(unlocks.length, 2);
        eq(unlocks[0].body.scope, 'profile:default:model:1:pos:1,2,3', 'sent for this computer');
        ok(!sent.some((x) => /pin/i.test(x.name) && x.name !== 'pc:lock:unlock'), 'no PIN sent anywhere else');
        ok(!Object.keys(win.localStorage).some((k) => /security_pin|security_password/.test(k)), 'no PIN in the browser cache');
        await new Promise((r) => setTimeout(r, 1000));
        ok(sent.some((x) => x.name === 'pc:profile:saveLayout'), 'the layout is saved on the server');
        eq(errors.length, 0, errors.join(' | '));
    });

    console.log(`${passed} passed, ${failed} failed`);
    if (failures.length) { console.log('Failures:'); failures.forEach((f) => console.log('  - ' + f)); process.exit(1); }
    process.exit(0);   // the apps' refresh timers would keep node running
})();
