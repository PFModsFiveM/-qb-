// Batch 14: the Hot Dog Stand app (pfm-hotdogjob/html/stand_app.js) shows the stand's stock and
// level as the server reports them (the stock is the server's now), as text, inside its window, on
// the tablet and the computer.
// Run: node js/fix14_streetjobs_hotdog_app_spec.js
const fs = require('fs');
const path = require('path');
const { JSDOM } = require('jsdom');

const QB = path.resolve(__dirname, '..', '..');
const PF = path.resolve(QB, '..', '[pfscripts]');
const RUNTIME = fs.readFileSync(path.join(PF, 'pf-devices/html/runtime.js'), 'utf8');
const MODULE = fs.readFileSync(path.join(QB, 'pfm-hotdogjob/html/stand_app.js'), 'utf8');

let passed = 0;
let failed = 0;
const failures = [];
async function it(name, fn) {
    try { await fn(); passed++; } catch (e) { failed++; failures.push(`${name}: ${e && e.stack || e}`); }
}
function ok(v, msg) { if (!v) throw new Error(msg || 'expected truthy'); }
function eq(a, b, msg) { if (a !== b) throw new Error(`${msg || 'expected'}: ${JSON.stringify(b)}, got ${JSON.stringify(a)}`); }
const tick = () => new Promise((r) => setTimeout(r, 0));
async function settle() { for (let i = 0; i < 15; i++) await tick(); }
const EVIL = '<img src=x onerror="window.__xss=1">';
const APPS = [{ id: 'hotdogstand', name: 'Hot Dog Stand', icon: '', kind: 'module', entry: 'https://cfx-nui-pfm-hotdogjob/html/stand_app.js', styles: [] }];

function makeWindow(device, status) {
    const dom = new JSDOM('<!doctype html><html><head></head><body><div id="shell"></div></body></html>', { runScripts: 'outside-only', url: 'https://cfx-nui-pf-tablet/html/index.html' });
    const win = dom.window;
    win.fetch = async (url, opts) => {
        const name = String(url).replace(/^https:\/\/[^/]+\//, '');
        const body = JSON.parse(opts && opts.body || '{}');
        let result = { ok: true };
        if (name === 'apps') result = { apps: APPS, store: [], categories: [] };
        else if (name === 'rpc') result = body.method === 'status' ? status : { ok: true };
        return { json: async () => result };
    };
    const origAppend = win.document.head.appendChild.bind(win.document.head);
    win.document.head.appendChild = (el) => { const r = origAppend(el); if (el.tagName === 'SCRIPT') setTimeout(() => el.onload && el.onload(), 0); return r; };
    win.jQuery = function () {};
    win.eval(RUNTIME);
    win.eval(MODULE);
    win.PFApps.attachShell({
        device,
        openWindow(app, mount) {
            const el = win.document.createElement('div');
            el.dataset.window = app.id;
            win.document.getElementById('shell').appendChild(el);
            mount(el);
        },
        closeWindow() {},
        onApps() {},
        notify() {},
    });
    return { win, $: (sel) => win.document.querySelector(`[data-window] ${sel}`) };
}

(async () => {
    for (const device of ['tablet', 'computer']) {
        await it(`${device}: the server's stock and level are shown as text`, async () => {
            const env = makeWindow(device, {
                ok: true, standOut: true, sold: 4, sales: 2, earned: 40, streak: 2, level: 2,
                stock: { exotic: 3, rare: EVIL, common: 1 }, reputation: 60, maxReputation: 200, deposit: 250,
            });
            await env.win.PFApps.refresh();
            await env.win.PFApps.open('hotdogstand');
            await settle();
            const root = env.$('.pf-app');
            ok(root, 'mounted');
            eq(root.querySelectorAll('img').length, 0, 'no server value became HTML');
            ok(root.textContent.includes('Ready to sell (level 2)'), 'level shown');
            ok(root.textContent.includes('Perfect 3'), 'perfect stock');
            ok(root.textContent.includes('Rare 0'), 'a non-number count is shown as 0');
            ok(root.textContent.includes('Common 1'), 'common stock');
            eq(env.win.__xss, undefined);
        });
        await it(`${device}: no stock card without a stand out`, async () => {
            const env = makeWindow(device, { ok: true, standOut: false, sold: 0, sales: 0, earned: 0, streak: 0, level: 1, stock: { exotic: 0, rare: 0, common: 0 }, reputation: 0, maxReputation: 200, deposit: 250 });
            await env.win.PFApps.refresh();
            await env.win.PFApps.open('hotdogstand');
            await settle();
            const root = env.$('.pf-app');
            ok(root && !root.textContent.includes('Ready to sell'), 'no stock card');
            ok(root.textContent.includes('Take a stand at the depot'), 'the depot hint');
        });
    }
    console.log(`fix14_streetjobs_hotdog_app_spec.js  (${passed} passed, ${failed} failed)`);
    failures.forEach((f) => console.log('  - ' + f));
    process.exit(failed ? 1 : 0);
})();
