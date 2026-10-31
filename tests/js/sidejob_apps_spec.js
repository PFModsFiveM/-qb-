// Recycling and Vineyard (pf-jobs), Pawn Shop (pfm-pawnshop) and Crafting (pfm-crafting) NUI modules
// in a simulated browser (jsdom) on the pf-devices runtime: they render the server's data as text
// (never HTML), stay inside their window, send only what the server reads, set waypoints to the
// coordinates the server gave, and follow pushes, on the tablet and the computer.
// Run: node js/sidejob_apps_spec.js
const fs = require('fs');
const path = require('path');
const { JSDOM } = require('jsdom');

const QB = path.resolve(__dirname, '..', '..');
const PF = path.resolve(QB, '..', '[pfscripts]');
const RUNTIME = fs.readFileSync(path.join(PF, 'pf-devices/html/runtime.js'), 'utf8');
const SOURCES = {
    recycle: path.join(PF, 'pf-jobs/html/apps/recycle.js'),
    vineyard: path.join(PF, 'pf-jobs/html/apps/vineyard.js'),
    pawnshop: path.join(QB, 'pfm-pawnshop/html/pawnshop.js'),
    crafting: path.join(QB, 'pfm-crafting/html/crafting.js'),
};
const MODULES = Object.values(SOURCES).map((f) => fs.readFileSync(f, 'utf8'));

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
const APPS = Object.keys(SOURCES).map((id) => ({ id, name: id, icon: '', kind: 'module', entry: `https://cfx-nui-x/${id}.js`, styles: [] }));

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
    const button = (root, text) => [...root.querySelectorAll('button')].find((b) => b.textContent === text);
    const tab = (root, text) => [...root.querySelectorAll('.pf-tab')].find((b) => b.textContent === text);
    return { win, rpcs, posts, notes, button, tab, $: (sel) => win.document.querySelector(`[data-window] ${sel}`) };
}

const now = Math.floor(Date.now() / 1000);
function recycleView(overrides) {
    return Object.assign({
        ok: true, available: true, owed: 0, xpPerPackage: 10, draws: [1, 5], sellEnabled: true, limitedStock: true,
        plant: { label: 'Plant', x: 55.5, y: 6472.1 },
        shift: { active: true, startedAt: now - 300, packages: 2, materialCount: 9, wage: 10, xp: 20, carrying: true,
            materials: [{ item: 'metalscrap', label: EVIL, amount: 5 }] },
        stats: { xp: 320, level: 2, title: EVIL, levelXp: 300, nextXp: 1000, wagePerPackage: 6, packages: 32, materials: 140, wages: 160, sales: 20, earned: 180, shifts: 3 },
        levels: [{ level: 1, xp: 0, wage: 5, bonusDraws: 0, title: 'Sorter' }, { level: 2, xp: 300, wage: 6, bonusDraws: 0, title: EVIL }],
        prices: [{ item: 'metalscrap', label: EVIL, price: 2, stock: 2990, have: 5 }],
        history: [{ startedAt: now - 3600, packages: 4, materials: 20, wage: 20, status: 'unpaid' }],
    }, overrides || {});
}

(async () => {
    for (const device of ['tablet', 'computer']) {
        await it(`${device}: recycling renders server text as text, ends the shift with an empty request and follows pushes`, async () => {
            let clockOuts = 0;
            const env = makeWindow(device, {
                'recycle.getInit': () => recycleView(),
                'recycle.clockOut': () => { clockOuts++; return Object.assign(recycleView({ shift: null }), { summary: { wage: 10, paid: true, packages: 2 } }); },
            });
            await env.win.PFApps.refresh();
            await env.win.PFApps.open('recycle');
            await settle();
            const root = env.$('.pfj-rc');
            ok(root, 'mounted');
            eq(root.querySelectorAll('img').length, 0, 'server text became HTML');
            ok(root.textContent.includes(EVIL), 'material label shown as text');
            ok(root.textContent.includes('Carrying a package'), 'carrying state');
            env.button(root, 'Waypoint to the plant').click();
            await settle();
            const wp = env.posts.find((p) => p.name === 'setWaypoint');
            ok(wp, 'waypoint posted');
            eq(wp.body.x, 55.5);
            eq(wp.body.y, 6472.1);
            // pushes from the server update the open app
            env.win.PFApps.handleMessage({ action: 'pfapp:event', app: 'recycle', event: 'state', payload: { shift: Object.assign(recycleView().shift, { packages: 7, carrying: false }), stats: recycleView().stats } });
            await settle();
            ok(env.$('.pfj-rc').textContent.includes('Take the marked package'), 'push applied');
            env.button(env.$('.pfj-rc'), 'End shift and get paid').click();
            await settle();
            eq(clockOuts, 1);
            const sent = env.rpcs.find((r) => r.method === 'clockOut');
            eq(JSON.stringify(sent.payload), '{}', 'the client sends no amounts');
            ok(env.notes.some((n) => /paid to your bank/.test(n.m)), 'told it was paid');
            ok(env.$('.pfj-rc').textContent.includes('Not clocked in'));
            for (const t of ['Materials', 'Level', 'History']) {
                env.tab(env.$('.pfj-rc'), t).click();
                await settle();
                eq(env.$('.pfj-rc').querySelectorAll('img').length, 0, `${t}: no HTML from the server`);
            }
            ok(env.$('.pfj-rc').textContent.includes('Waiting for the bank'), 'unpaid shift shown');
            eq(env.win.__xss, undefined, 'script ran');
        });
    }

    await it('vineyard: shift, press and barrel, waypoints from the server, the Supplier app and early end', async () => {
        const view = {
            ok: true, available: true,
            shift: { active: true, picked: 3, goal: 10, grapes: 30, startedAt: now - 120, vine: { x: -1875.4, y: 2100.3 } },
            press: { active: true, readyIn: 0 }, barrel: { active: true, readyIn: 120, readyAt: now + 120 },
            stats: { xp: 300, level: 2, title: EVIL, levelXp: 250, nextXp: 800, vines: 40, grapes: 400, juice: 20, wine: 8, sold: 100, shifts: 4 },
            levels: [{ level: 1, xp: 0, grapeBonus: 0, batchBonus: 0, title: 'Picker' }],
            carrying: { grape: 40, grapejuice: 5, wine: 2 },
            recipe: { grapesPerJuice: 16, juicePerWine: 23, wineMinutes: 3, vinesPerShift: [8, 12], xp: { vine: 5, juice: 10, wine: 25 } },
            prices: [{ item: 'wine', label: EVIL, buyer: 15, restaurants: 18 }],
            places: [{ label: EVIL, x: 1, y: 2 }, { label: 'Wholesale buyer', x: -1487.3, y: -379.0 }],
            supplierApp: true,
        };
        let ends = 0;
        const env = makeWindow('tablet', {
            'vineyard.getInit': () => view,
            'vineyard.endShift': () => { ends++; return Object.assign({}, view, { shift: null }); },
        });
        await env.win.PFApps.refresh();
        await env.win.PFApps.open('vineyard');
        await settle();
        const root = env.$('.pfj-vy');
        ok(root, 'mounted');
        eq(root.querySelectorAll('img').length, 0);
        ok(root.textContent.includes('3 of 10 vines picked'));
        ok(root.textContent.includes('Juice ready to collect'));
        ok(/Fermenting/.test(root.textContent), 'barrel countdown');
        ok(root.textContent.includes('Batches you can press2'), 'grapes / 16');
        env.button(root, 'Waypoint to the next vine').click();
        await settle();
        const wp = env.posts.filter((p) => p.name === 'setWaypoint').pop();
        eq(wp.body.x, -1875.4);
        env.tab(env.$('.pfj-vy'), 'Selling').click();
        await settle();
        ok(env.$('.pfj-vy').textContent.includes('$18'), 'restaurant price');
        eq(env.$('.pfj-vy').querySelectorAll('img').length, 0);
        env.button(env.$('.pfj-vy'), 'Open the Supplier app').click();
        await settle();
        env.tab(env.$('.pfj-vy'), 'Today').click();
        await settle();
        env.button(env.$('.pfj-vy'), 'End shift').click();
        await settle();
        eq(ends, 1);
        eq(JSON.stringify(env.rpcs.find((r) => r.method === 'endShift').payload), '{}');
        ok(env.$('.pfj-vy').textContent.includes('No picking shift'));
        eq(env.win.__xss, undefined);
    });

    await it('pawn shop: prices, hours, melting, waypoint; read-only', async () => {
        const env = makeWindow('computer', {
            'pawnshop.getInit': () => ({
                ok: true, fluctuating: true, paysTo: 'cash',
                prices: [{ item: 'goldchain', label: EVIL, price: 75, have: 2 }],
                meltable: [{ item: 'goldchain', label: EVIL, minutesEach: 0.15, rewards: [{ item: 'goldbar', label: EVIL, amount: 2 }], have: 2 }],
                melting: { item: 'goldchain', label: EVIL, amount: 2, readyIn: 600, ready: false, forfeitIn: 7800, rewards: [{ label: EVIL, amount: 4 }] },
                locations: [{ id: 1, label: 'Pawn Shop', x: 412.3, y: 314.8 }],
                hours: { limited: true, open: 7, close: 17, hour: 20, minute: 5, openNow: false },
            }),
        });
        await env.win.PFApps.refresh();
        await env.win.PFApps.open('pawnshop');
        await settle();
        const root = env.$('.pfm-pawn');
        ok(root, 'mounted');
        eq(root.querySelectorAll('img').length, 0);
        ok(root.textContent.includes('Closed now'));
        ok(root.textContent.includes('$150'), 'what the player carries is worth');
        ok(/Ready in 10 min/.test(root.textContent), 'melting countdown');
        env.button(root, 'Waypoint').click();
        await settle();
        eq(env.posts.find((p) => p.name === 'setWaypoint').body.x, 412.3);
        eq(env.rpcs.filter((r) => r.method !== 'getInit').length, 0, 'no selling from the device');
        eq(env.win.__xss, undefined);
    });

    await it('crafting: bench tabs, have/need, the can-make filter and the bench waypoint', async () => {
        const env = makeWindow('tablet', {
            'crafting.getInit': () => ({
                ok: true, maxAmount: 50,
                benches: [
                    { type: 'item_bench', label: EVIL, xpType: 'craftingrep', xp: 10, owned: 0, placed: { x: 10, y: 20, z: 30 }, recipes: [
                        { item: 'lockpick', label: EVIL, xpRequired: 0, xpGain: 1, unlocked: true, canMake: 2, requirements: [{ item: 'metalscrap', label: EVIL, amount: 22, have: 50 }] },
                        { item: 'gatecrack', label: 'Gate Crack', xpRequired: 110, xpGain: 5, unlocked: false, canMake: 0, requirements: [] },
                    ] },
                    { type: 'attachment_bench', label: 'Attachment Bench', xpType: 'attachmentcraftingrep', xp: 0, owned: 0, recipes: [] },
                ],
            }),
        });
        await env.win.PFApps.refresh();
        await env.win.PFApps.open('crafting');
        await settle();
        const root = env.$('.pfm-craft');
        ok(root, 'mounted');
        eq(root.querySelectorAll('img').length, 0);
        eq(root.querySelectorAll('.pf-tab').length, 2, 'one tab per bench');
        ok(root.textContent.includes('You can make 2'));
        ok(root.textContent.includes('Needs 110 XP'));
        ok(root.textContent.includes('50/22'));
        const only = root.querySelector('input[type="checkbox"]');
        only.checked = true;
        only.dispatchEvent(new env.win.Event('change'));
        await settle();
        ok(!env.$('.pfm-craft').textContent.includes('Gate Crack'), 'filtered to what can be made');
        env.button(env.$('.pfm-craft'), 'Waypoint to your bench').click();
        await settle();
        eq(env.posts.find((p) => p.name === 'setWaypoint').body.y, 20);
        env.tab(env.$('.pfm-craft'), 'Attachment Bench').click();
        await settle();
        ok(env.$('.pfm-craft').textContent.includes('You need this bench'));
        eq(env.win.__xss, undefined);
    });

    console.log(`${passed} passed, ${failed} failed`);
    if (failures.length) { console.log('Failures:'); failures.forEach((f) => console.log('  - ' + f)); }
    process.exit(failed ? 1 : 0);
})();
