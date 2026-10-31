// pf-citizen NUI modules (Mail, Bills, Documents, Calendar) in a simulated browser (jsdom) on the
// pf-devices runtime: they render from the server's data, never turn server strings into HTML,
// send only the fields the server reads, and work on the tablet and the computer.
// Run: node js/citizen_apps_spec.js
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
const mailHandlers = () => ({
    'mail.list': () => ({ ok: true, folder: 'inbox', address: '5550001@ls.mail', counts: { unread: 1, drafts: 0 },
        mails: [{ id: 7, sender: '<b>Bob</b>', subject: EVIL, preview: EVIL, read: false, folder: 'inbox', senderType: 'person', at: now, attachments: [] }] }),
    'mail.get': () => ({ ok: true, counts: {}, mail: { id: 7, sender: '<b>Bob</b>', subject: EVIL, message: EVIL, folder: 'inbox', replyTo: '5550002@ls.mail', senderType: 'person', at: now,
        attachments: [{ type: 'document', ref: '3', title: EVIL }] }, thread: [] }),
    'mail.send': () => ({ ok: true, id: 9, delivered: 1 }),
    'mail.addressBook': () => ({ ok: true, entries: [{ kind: 'contact', name: '<i>Ann</i>', address: '5550003@ls.mail' }] }),
    'mail.documents': () => ({ ok: true, mine: [{ id: 3, title: EVIL }], shared: [] }),
});

(async () => {
    for (const device of ['tablet', 'computer']) {
        await it(`${device}: mail renders server strings as text and sends only what the server reads`, async () => {
            const env = makeWindow(device, mailHandlers());
            await env.win.PFApps.refresh();
            await env.win.PFApps.open('mail');
            await settle();
            const root = env.$('.pfc-mail');
            ok(root, 'mail mounted');
            eq(root.querySelectorAll('img').length, 0, 'server text became HTML');
            eq(root.querySelectorAll('b').length, 0, 'sender became HTML');
            ok(root.textContent.includes(EVIL), 'subject shown as text');
            root.querySelector('.pfc-item').click();
            await settle();
            eq(root.querySelectorAll('img').length, 0, 'message became HTML');
            ok(root.querySelector('.pfc-chip'), 'attachment chip');
            // reply prefills the reply address, the server decides the sender
            [...root.querySelectorAll('button')].find((b) => b.textContent === 'Reply').click();
            await settle();
            const dialog = root.querySelector('.pfc-dialog');
            ok(dialog, 'compose open');
            const [to, subject] = dialog.querySelectorAll('input');
            eq(to.value, '5550002@ls.mail');
            ok(subject.value.startsWith('Re: '), 'reply subject');
            const list = dialog.querySelector('datalist');
            ok(list.id && list.id.startsWith('pfcmail'), 'datalist id is unique per instance');
            dialog.querySelector('textarea').value = 'Thanks';
            [...dialog.querySelectorAll('button')].find((b) => b.textContent === 'Send').click();
            await settle();
            const sent = env.rpcs.find((r) => r.method === 'send');
            ok(sent, 'send rpc');
            eq(sent.app, 'mail');
            eq(sent.payload.to, '5550002@ls.mail');
            eq(sent.payload.replyTo, 7);
            eq(sent.payload.message, 'Thanks');
            ok(!('sender' in sent.payload) && !('senderCid' in sent.payload), 'client sent an identity');
            eq(env.win.__xss, undefined, 'script ran');
        });
    }

    await it('bills: lists, pays by key and shows what cannot be paid here', async () => {
        const env = makeWindow('tablet', {
            'bills.list': () => ({ ok: true, totalDue: 750, overdue: 1, bank: 1000, history: [], open: [
                { key: 'gov:4', source: 'government', title: EVIL, kind: 'Fine', from: 'City', amount: 500, paid: 0, remaining: 500, status: 'overdue', due: now - 86400, canPay: true, open: true },
                { key: 'phone:2', source: 'phone', title: 'Brakes', kind: 'Invoice', from: 'Mechanic', amount: 250, paid: 0, remaining: 250, status: 'open', canPay: true, canDecline: true, open: true },
            ] }),
            'bills.pay': () => ({ ok: true, paid: 500 }),
        });
        await env.win.PFApps.refresh();
        await env.win.PFApps.open('bills', { focus: 'phone:2' });
        await settle();
        const root = env.$('.pfc-bills');
        eq(root.querySelectorAll('img').length, 0);
        eq(root.querySelectorAll('.pfc-bill').length, 2);
        ok(root.querySelector('.pfc-bill.focus').textContent.includes('Brakes'), 'focused bill');
        [...root.querySelectorAll('button')].find((b) => b.textContent === 'Pay $500').click();
        await settle();
        const pay = env.rpcs.find((r) => r.method === 'pay');
        eq(pay.payload.key, 'gov:4');
        eq(pay.payload.amount, undefined, 'the client named no amount');
    });

    await it('documents: the formatter escapes first, and a document body cannot inject HTML', async () => {
        const env = makeWindow('computer', {
            'documents.list': () => ({ ok: true, mine: [{ id: 3, title: EVIL, own: true }], shared: [] }),
            'documents.get': () => ({ ok: true, document: { id: 3, title: EVIL, body: '# Title\n' + EVIL + '\n**bold** <script>window.__xss=2</script>\n- item', own: true, canEdit: true, signatures: [{ name: EVIL, at: now, fingerprint: 'ab'.repeat(32) }], sharedWith: [] } }),
        });
        await env.win.PFApps.refresh();
        await env.win.PFApps.open('documents', { open: 3 });
        await settle();
        const root = env.$('.pfc-docs');
        const view = root.querySelector('.pfc-doc-view');
        ok(view, 'document shown');
        eq(view.querySelectorAll('img,script').length, 0, 'body became HTML');
        ok(view.querySelector('h1') && view.querySelector('strong') && view.querySelector('li'), 'formatting');
        eq(root.querySelectorAll('img').length, 0);
        ok(root.querySelector('.pfc-sign'), 'signature shown');
        eq(env.win.__xss, undefined, 'script ran');
    });

    await it('calendar: renders the month, escapes titles and creates with a timestamp', async () => {
        const env = makeWindow('tablet', {
            'calendar.list': () => ({ ok: true, canPostCity: false, businesses: [], events: [{ id: 1, scope: 'city', title: EVIL, starts: now + 3600, remind: 0, canEdit: false, subscribed: false, ownerName: 'City' }] }),
            'calendar.create': () => ({ ok: true, id: 5 }),
        });
        await env.win.PFApps.refresh();
        await env.win.PFApps.open('calendar');
        await settle();
        const root = env.$('.pfc-calendar');
        eq(root.querySelectorAll('.pfc-day').length, 42);
        eq(root.querySelectorAll('img').length, 0);
        [...root.querySelectorAll('button')].find((b) => b.textContent === '+ Event').click();
        await settle();
        const dialog = root.querySelector('.pfc-dialog');
        const select = dialog.querySelector('select');
        eq([...select.options].map((o) => o.value).join(','), 'personal', 'no city or work calendars without rights');
        dialog.querySelector('input').value = 'Dinner';
        [...dialog.querySelectorAll('button')].find((b) => b.textContent === 'Save').click();
        await settle();
        const create = env.rpcs.find((r) => r.method === 'create');
        eq(create.payload.scope, 'personal');
        eq(create.payload.title, 'Dinner');
        ok(Number.isInteger(create.payload.starts), 'start is a timestamp');
        ok(!('owner' in create.payload), 'client named an owner');
    });

    console.log(`citizen_apps_spec.js  (${passed} passed, ${failed} failed)`);
    failures.forEach((f) => console.log('  - ' + f));
    process.exit(failed ? 1 : 0);
})();
