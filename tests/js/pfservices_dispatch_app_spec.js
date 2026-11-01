// pf-services Dispatch NUI module in a simulated browser (jsdom) on the pf-devices runtime: the server's
// canClaim decides whether a request shows Accept (a City Hall request needs the role's permission),
// City Hall requests point to the Business Requests app, server strings stay text, and actions send
// only the request id. Run: node js/pfservices_dispatch_app_spec.js
const fs = require('fs');
const path = require('path');
const { JSDOM } = require('jsdom');

const PF = path.resolve(__dirname, '..', '..', '..', '[pfscripts]');
const RUNTIME = fs.readFileSync(path.join(PF, 'pf-devices/html/runtime.js'), 'utf8');
const MODULE = fs.readFileSync(path.join(PF, 'pf-services/html/apps/dispatch.js'), 'utf8');

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
const APPS = [{ id: 'dispatch', name: 'Dispatch', icon: '', kind: 'module', entry: 'https://cfx-nui-pf-services/html/apps/dispatch.js', styles: [] }];
const now = Math.floor(Date.now() / 1000);

function makeWindow(device, handlers) {
    const dom = new JSDOM('<!doctype html><html><head></head><body><div id="shell"></div></body></html>', { runScripts: 'outside-only', url: 'https://cfx-nui-pf-tablet/html/index.html' });
    const win = dom.window;
    const rpcs = [];
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
        return { json: async () => result };
    };
    const origAppend = win.document.head.appendChild.bind(win.document.head);
    win.document.head.appendChild = (el) => { const r = origAppend(el); if (el.tagName === 'SCRIPT') setTimeout(() => el.onload && el.onload(), 0); return r; };
    win.jQuery = function () {};
    win.eval(RUNTIME);
    win.eval(MODULE);
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
    return { win, rpcs, notes, $: (sel) => win.document.querySelector(`[data-window] ${sel}`) };
}

const REQUESTS = [
    { id: 1, kind: 'gov.request.license', label: 'License request', icon: '', status: 'open', title: EVIL, fromName: 'Diner',
        coords: { x: 1, y: 2, z: 3 }, created: now, canClaim: false },
    { id: 2, kind: 'gov.request.slot', label: 'Equipment slot request', icon: '', status: 'open', title: 'Diner: slot',
        coords: { x: 4, y: 5, z: 6 }, created: now, canClaim: true },
];
const handlers = (acceptResult) => ({
    'dispatch.list': () => ({ ok: true, job: 'government', jobLabel: 'Government', onduty: true, requests: REQUESTS, mine: [], kinds: [] }),
    'dispatch.accept': () => acceptResult || { ok: true },
    'dispatch.waypoint': () => ({ ok: true }),
});

async function openOn(device, h) {
    const env = makeWindow(device, h);
    await env.win.PFApps.refresh();
    await env.win.PFApps.open('dispatch');
    await settle();
    const root = env.$('.pfs-dispatch');
    ok(root, 'dispatch mounted');
    return { env, root };
}
function select(root, index) {
    root.querySelectorAll('.pfs-item')[index].click();
}
const buttons = (root, text) => [...root.querySelectorAll('.pfs-detail button')].filter((b) => b.textContent === text);

(async () => {
    for (const device of ['tablet', 'computer']) {
        await it(`${device}: a City Hall request the caller may not take has no Accept, and says why`, async () => {
            const { env, root } = await openOn(device, handlers());
            eq(root.querySelectorAll('img').length, 0, 'server text became HTML');
            select(root, 0);
            await settle();
            const detail = root.querySelector('.pfs-detail');
            eq(buttons(root, 'Accept').length, 0, 'Accept shown without the permission');
            ok(detail.textContent.includes('Needs a City Hall role'), 'no reason shown');
            ok(detail.textContent.includes('Business Requests'), 'no pointer to the Business Requests app');
            ok(buttons(root, 'Waypoint').length === 1, 'waypoint still offered');
            eq(env.win.__xss, undefined, 'script ran');
        });
    }

    await it('a City Hall request the caller may take: Accept sends only the id, then the waypoint', async () => {
        const { env, root } = await openOn('tablet', handlers());
        select(root, 1);
        await settle();
        const accept = buttons(root, 'Accept');
        eq(accept.length, 1, 'Accept missing');
        accept[0].click();
        await settle();
        const sent = env.rpcs.find((r) => r.method === 'accept');
        ok(sent, 'accept rpc');
        eq(JSON.stringify(sent.payload), JSON.stringify({ id: 2 }), 'payload');
        ok(env.rpcs.some((r) => r.method === 'waypoint' && r.payload.id === 2), 'waypoint after accept');
    });

    await it('a refused accept shows the permission message', async () => {
        const { env, root } = await openOn('computer', handlers({ ok: false, error: 'no_permission' }));
        select(root, 1);
        await settle();
        buttons(root, 'Accept')[0].click();
        await settle();
        ok(env.notes.some((n) => n.m === 'Your City Hall role cannot take this request' && n.t === 'error'), JSON.stringify(env.notes));
    });

    console.log(`pfservices_dispatch_app_spec.js  (${passed} passed, ${failed} failed)`);
    failures.forEach((f) => console.log('  - ' + f));
    process.exit(failed ? 1 : 0);
})();
