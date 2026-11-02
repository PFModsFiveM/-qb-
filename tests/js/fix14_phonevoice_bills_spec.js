// pf-citizen Bills (batch 14, 13B-PAYING): a phone invoice pfm-phone is still settling ('paying')
// is shown as Processing with nothing to pay or decline; the errors pfm-phone answers have labels.
// Same simulated browser and pf-devices runtime as citizen_apps_spec.js.
// Run: node js/fix14_phonevoice_bills_spec.js
const fs = require('fs');
const path = require('path');
const { JSDOM } = require('jsdom');

const PF = path.resolve(__dirname, '..', '..', '..', '[pfscripts]');
const RUNTIME = fs.readFileSync(path.join(PF, 'pf-devices/html/runtime.js'), 'utf8');
const MODULES = ['mail', 'bills', 'documents', 'calendar'].map((m) => fs.readFileSync(path.join(PF, `pf-citizen/html/apps/${m}.js`), 'utf8'));

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
const APPS = ['mail', 'bills', 'documents', 'calendar'].map((id) => ({ id, name: id, icon: '', kind: 'module', entry: `https://cfx-nui-pf-citizen/html/apps/${id}.js`, styles: [] }));

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
    return { win, rpcs, notes, $: (sel) => win.document.querySelector(`[data-window] ${sel}`), all: (sel) => [...win.document.querySelectorAll(sel)] };
}

const now = Math.floor(Date.now() / 1000);

(async () => {
    for (const device of ['tablet', 'computer']) {
        await it(`${device}: a processing invoice has no pay or decline button and says why`, async () => {
            const env = makeWindow(device, {
                'bills.list': () => ({ ok: true, totalDue: 40, overdue: 0, bank: 500, history: [], open: [
                    { key: 'phone:7', source: 'phone', title: 'Brake repair', kind: 'Invoice', from: 'Mechanic', amount: 120, paid: 0, remaining: 120, status: 'processing', canPay: false, canDecline: false, open: true, processing: true },
                    { key: 'phone:8', source: 'phone', title: 'Oil change', kind: 'Invoice', from: 'Mechanic', amount: 40, paid: 0, remaining: 40, status: 'open', canPay: true, canDecline: true, open: true },
                ] }),
                'bills.pay': () => ({ ok: false, error: 'unknown_society' }),
            });
            await env.win.PFApps.refresh();
            await env.win.PFApps.open('bills');
            await settle();
            const root = env.$('.pfc-bills');
            const cards = [...root.querySelectorAll('.pfc-bill')];
            eq(cards.length, 2);
            const processing = cards.find((c) => c.textContent.includes('Brake repair'));
            ok(processing.textContent.includes('Processing'), 'no Processing badge');
            ok(processing.textContent.includes('being processed'), 'no explanation');
            eq(processing.querySelectorAll('button').length, 0, 'a processing invoice can be paid or declined');
            const open = cards.find((c) => c.textContent.includes('Oil change'));
            eq(open.querySelectorAll('button').length, 2);
            ok(!processing.textContent.includes('Pay this bill where it was issued'), 'wrong hint');
            // an answer from pfm-phone gets its label
            [...open.querySelectorAll('button')].find((b) => b.textContent === 'Pay $40').click();
            await settle();
            ok(env.notes.some((n) => n.m === 'This business cannot take payments right now'), 'unknown_society has no label: ' + JSON.stringify(env.notes));
        });
    }

    console.log(`fix14_phonevoice_bills_spec.js  (${passed} passed, ${failed} failed)`);
    failures.forEach((f) => console.log('  - ' + f));
    process.exit(failed ? 1 : 0);
})();
