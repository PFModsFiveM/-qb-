// Batch 21, unit 21F: pf-justice app modules (Court, Community Service, Justice Records) in a simulated
// browser (jsdom) on the pf-devices runtime, on the tablet and the computer:
//   * every server string goes in as text (<img onerror> payloads in names, case numbers, notes, affidavits,
//     error messages never become elements);
//   * the navigation follows the server's role answer;
//   * loading, empty and error states (with the server's error code turned into a message);
//   * each action calls the right handler with the payload the server reads (decision keys come from the
//     server and are kept for a retry, renewed after success; payments and complaints never send a payer,
//     an amount or a complainant).
// Run: node js/b21_justice_apps_spec.js
const fs = require('fs');
const path = require('path');
const { JSDOM } = require('jsdom');

const PF = path.resolve(__dirname, '..', '..', '..', '[pfscripts]');
const RUNTIME = fs.readFileSync(path.join(PF, 'pf-devices/html/runtime.js'), 'utf8');
const MODULES = ['court', 'cs', 'records'].map((m) => fs.readFileSync(path.join(PF, `pf-justice/html/apps/${m}.js`), 'utf8'));

let passed = 0;
let failed = 0;
const failures = [];
async function it(name, fn) {
    try { await fn(); passed++; } catch (e) { failed++; failures.push(`${name}: ${e && e.stack || e}`); }
}
function eq(a, b, msg) { if (a !== b) throw new Error(`${msg || 'expected'}: ${JSON.stringify(b)}, got ${JSON.stringify(a)}`); }
function ok(v, msg) { if (!v) throw new Error(msg || 'expected truthy'); }
const tick = () => new Promise((r) => setTimeout(r, 0));
async function settle() { for (let i = 0; i < 25; i++) await tick(); }

const EVIL = '<img src=x onerror="window.__xss=1">';
const APPS = ['court', 'community-service', 'justice-records'].map((id) => ({ id, name: id, icon: '', kind: 'module',
    entry: `https://cfx-nui-pf-justice/html/apps/${id}.js`, styles: [] }));

const envs = [];
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
        return { json: async () => JSON.parse(JSON.stringify(result)) };
    };
    const origAppend = win.document.head.appendChild.bind(win.document.head);
    win.document.head.appendChild = (el) => { const r = origAppend(el); if (el.tagName === 'SCRIPT') setTimeout(() => el.onload && el.onload(), 0); return r; };
    win.jQuery = function () {};
    win.eval(RUNTIME);
    MODULES.forEach((src) => win.eval(src));
    const notes = [];
    const waypoints = [];
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
    const env = {
        win, rpcs, notes, waypoints,
        $: (sel) => win.document.querySelector(`[data-window] ${sel}`),
        all: (sel) => [...win.document.querySelectorAll(`[data-window] ${sel}`)],
        text: () => win.document.getElementById('shell').textContent,
        last: (method) => [...rpcs].reverse().find((r) => r.method === method),
        count: (method) => rpcs.filter((r) => r.method === method).length,
        async open(id) { await win.PFApps.refresh(); await win.PFApps.open(id); await settle(); },
        form(section) { return env.all('form').find((f) => { const s = f.querySelector('.ju-section'); return s && s.textContent === section; }); },
        async submit(form) { form.dispatchEvent(new win.Event('submit', { bubbles: true, cancelable: true })); await settle(); },
        async click(el) { el.click(); await settle(); },
        safe() {
            ok(win.__xss === undefined, 'a script ran');
            eq(win.document.querySelectorAll('[data-window] img').length, 0, 'an <img> was made from a server string');
            ok(env.text().includes('<img src=x'), 'the payload is shown as text');
        },
    };
    envs.push(env);
    return env;
}

const now = Math.floor(Date.now() / 1000);
const ROLES = { judge: { judge: true, court: true, warrants: true }, prosecutor: { prosecutor: true, court: true }, probation: { probation: true } };
function courtHandlers(role, extra) {
    let k = 0;
    const base = {
        'court.me': () => ({ ok: true, roles: ROLES[role] || {}, offDuty: role === 'off', courtrooms: [{ id: 'courtroom_1', label: EVIL }],
            hearingKinds: ['arraignment', 'trial'], decisionKinds: ['plea', 'verdict', 'sentence', 'dismissal', 'bail', 'release_order', 'appeal'],
            sentenceKinds: ['jail', 'fine', 'probation'], courtOrderKinds: ['search', 'evidence_destroy'], maxOrderHours: 720,
            facilities: [{ id: 'bolingbroke', label: EVIL, kinds: ['jail', 'prison'] }], conditionKinds: ['checkin'], offices: [{ id: 1, label: EVIL }],
            zones: [], violationTypes: [{ id: 'curfew', label: EVIL }] }),
        'court.key': (p) => ({ ok: true, key: `srv:${p.scope}:${++k}` }),
        'court.docket': () => ({ ok: true, list: [{ hearingId: 1, caseId: 7, caseNo: EVIL, name: EVIL, cid: 'C1', kind: 'arraignment', courtroomLabel: EVIL, at: now + 600, state: 'scheduled' }] }),
        'court.cases': () => ({ ok: true, list: [{ id: 7, caseNo: EVIL, name: EVIL, cid: 'C1', kind: 'criminal', state: 'filed', filedAt: now }], page: 1, more: true }),
        'court.case': () => ({ ok: true, can: { schedule: true, decide: role === 'judge', dismiss: true, appeal: false, courtOrder: role === 'judge' },
            case: { id: 7, caseNo: EVIL, cid: 'C1', name: EVIL, state: 'filed', kind: 'criminal', filedAt: now, filedBy: EVIL, judgeName: EVIL,
                charges: [{ code: 'PC-1', label: EVIL, count: 2 }], hearings: [{ id: 1, kind: 'arraignment', at: now, state: 'scheduled', notes: EVIL, courtroomLabel: EVIL }],
                decisions: [{ id: 2, kind: 'plea', body: { plea: 'guilty', note: EVIL }, decidedBy: EVIL, at: now }], refs: [{ type: 'mdt_case', id: EVIL }] } }),
        'court.warrants': () => ({ ok: true, more: false, list: [{ id: 4, warrantId: 'W1', type: 'arrest', state: 'requested', targetName: EVIL, requestedBy: EVIL,
            affidavit: EVIL, requestedAt: now, canDecide: true }] }),
        'court.decideWarrant': () => ({ ok: true, state: 'approved', notified: true }),
        'court.courtOrders': () => ({ ok: true, list: [{ id: 1, ref: 'CO-1', kind: 'search', name: EVIL, note: EVIL, validUntil: now + 3600 }] }),
        'court.issueOrder': () => ({ ok: true, ref: 'CO-2', validUntil: now + 3600 }),
        'court.caseload': () => ({ ok: true, list: [], more: false }),
        'court.schedule': () => ({ ok: true, hearingId: 3 }),
    };
    return Object.assign(base, extra || {});
}

(async () => {
    for (const device of ['tablet', 'computer']) {
        await it(`${device}: court navigation follows the server's roles`, async () => {
            const j = makeWindow(device, courtHandlers('judge'));
            await j.open('court');
            const navOf = (env) => env.all('[data-nav]').map((b) => b.dataset.nav).join(',');
            eq(navOf(j), 'docket,cases,file,warrants,orders', 'judge');
            const p = makeWindow(device, courtHandlers('prosecutor'));
            await p.open('court');
            eq(navOf(p), 'docket,cases,file', 'prosecutor');
            const po = makeWindow(device, courtHandlers('probation'));
            await po.open('court');
            eq(navOf(po), 'probation', 'probation officer');
            eq(po.last('caseload').payload.scope, 'mine');
            const off = makeWindow(device, courtHandlers('off'));
            await off.open('court');
            eq(navOf(off), '', 'off duty: nothing');
            ok(off.text().includes('Go on duty'), 'tells why');
            eq(off.count('docket'), 0);
        });

        await it(`${device}: docket, cases and a case render server strings as text`, async () => {
            const env = makeWindow(device, courtHandlers('judge'));
            await env.open('court');
            ok(env.$('table.pf-table'), 'docket table');
            env.safe();
            await env.click(env.$('[data-nav="cases"]'));
            const search = env.$('input[type="search"]');
            search.value = 'rosa';
            await env.submit(search.closest('form'));
            const c = env.last('cases').payload;
            eq(c.q, 'rosa');
            eq(c.scope, 'open');
            eq(c.page, 1);
            ok(env.all('.ju-pager button').some((b) => b.textContent === 'Next' && !b.disabled), 'server says there is a next page');
            await env.click(env.all('.ju-pager button').find((b) => b.textContent === 'Next'));
            eq(env.last('cases').payload.page, 2);
            const row = env.$('tr.ju-pick');
            row.dispatchEvent(new env.win.KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
            await settle();
            eq(env.last('case').payload.id, 7);
            env.safe();
            ok(env.form('Schedule a hearing') && env.form('Record a decision'), 'a judge gets both forms');
            // Escape goes back to the list
            env.$('.ju-court').dispatchEvent(new env.win.KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
            await settle();
            ok(env.$('input[type="search"]'), 'back on the case list');
        });

        await it(`${device}: a decision sends the server key, keeps it for a retry, and gets a new one after success`, async () => {
            let calls = 0;
            const env = makeWindow(device, courtHandlers('judge', {
                'court.decide': () => (++calls === 1 ? { ok: false, error: 'db_unavailable', message: EVIL } : { ok: true, decisionId: 9 }),
            }));
            await env.open('court');
            await env.click(env.$('[data-nav="cases"]'));
            await env.click(env.$('tr.ju-pick'));
            const form = env.form('Record a decision');
            const kind = form.querySelector('select');
            kind.value = 'plea';
            kind.dispatchEvent(new env.win.Event('change'));
            form.querySelector('textarea').value = 'counsel present';
            await env.submit(form);
            const first = env.last('decide').payload;
            eq(first.caseId, 7);
            eq(first.decision.kind, 'plea');
            eq(first.decision.plea, 'not_guilty');
            eq(first.decision.note, 'counsel present');
            eq(first.key, 'srv:decision:1', 'the key the server made');
            ok(form.querySelector('.ju-error').textContent.includes('court database did not answer'), 'the error code becomes a message');
            await env.submit(form);
            eq(env.last('decide').payload.key, 'srv:decision:1', 'the retry is the same action');
            eq(env.count('key'), 1);
            ok(env.notes.some((n) => n.m === 'Decision recorded'));
            // a new form (the case reloaded) asks for a new key
            const again = env.form('Record a decision');
            again.querySelector('select').value = 'dismissal';
            again.querySelector('select').dispatchEvent(new env.win.Event('change'));
            await env.submit(again);
            eq(env.last('decide').payload.key, 'srv:decision:2');
            env.safe();
        });

        await it(`${device}: a sentence sends one entry per order with only that kind's fields`, async () => {
            const env = makeWindow(device, courtHandlers('judge', { 'court.decide': () => ({ ok: true }) }));
            await env.open('court');
            await env.click(env.$('[data-nav="cases"]'));
            await env.click(env.$('tr.ju-pick'));
            const form = env.form('Record a decision');
            const kind = form.querySelector('select');
            kind.value = 'sentence';
            kind.dispatchEvent(new env.win.Event('change'));
            const line = form.querySelector('.ju-orderline');
            line.querySelector('input[placeholder="Minutes"]').value = '30';
            [...form.querySelectorAll('button')].find((b) => b.textContent === 'Add order').click();
            const lines = form.querySelectorAll('.ju-orderline');
            const second = lines[1];
            const k2 = second.querySelector('select');
            k2.value = 'fine';
            k2.dispatchEvent(new env.win.Event('change'));
            second.querySelector('input[placeholder="Amount ($)"]').value = '500';
            await env.submit(form);
            const orders = env.last('decide').payload.decision.orders;
            eq(orders.length, 2);
            eq(JSON.stringify(orders[0]), JSON.stringify({ kind: 'jail', minutes: 30, facility: 'bolingbroke' }));
            eq(JSON.stringify(orders[1]), JSON.stringify({ kind: 'fine', amount: 500 }));
        });

        await it(`${device}: schedule, warrant decisions and court orders call their handlers`, async () => {
            const env = makeWindow(device, courtHandlers('judge'));
            await env.open('court');
            await env.click(env.$('[data-nav="cases"]'));
            await env.click(env.$('tr.ju-pick'));
            const sched = env.form('Schedule a hearing');
            sched.querySelector('select').value = 'trial';
            await env.submit(sched);
            const s = env.last('schedule').payload;
            eq(s.caseId, 7);
            eq(s.kind, 'trial');
            ok(Number.isInteger(s.at) && s.at > now, 'a unix time from the picker');
            eq(s.courtroom, 'courtroom_1');
            eq(s.key, 'srv:hearing:1');
            await env.click(env.$('[data-nav="warrants"]'));
            env.safe();
            const wf = env.$('.pf-card form');
            wf.querySelector('select').value = 'deny';
            wf.querySelector('input').value = 'thin';
            await env.submit(wf);
            eq(JSON.stringify(env.last('decideWarrant').payload), JSON.stringify({ reviewId: 4, decision: 'deny', note: 'thin' }));
            await env.click(env.$('[data-nav="orders"]'));
            const of = env.form('Issue a court order');
            of.querySelector('input[placeholder="Citizen id"]').value = 'C1';
            of.querySelector('input[placeholder="Evidence ids, comma separated"]').value = '12,13';
            await env.submit(of);
            const o = env.last('issueOrder').payload;
            eq(o.kind, 'search');
            eq(o.cid, 'C1');
            eq(o.evidenceIds, '12,13');
            eq(o.key, 'srv:courtorder:2');
            env.safe();
        });

        await it(`${device}: court empty and error states`, async () => {
            const env = makeWindow(device, courtHandlers('judge', {
                'court.docket': () => ({ ok: true, list: [] }),
                'court.cases': () => ({ ok: false, error: 'no_permission', message: EVIL }),
            }));
            await env.open('court');
            ok(env.text().includes('No hearings in this range.'));
            await env.click(env.$('[data-nav="cases"]'));
            ok(env.text().includes('You do not hold the court role for this'), 'code -> message');
            ok(env.all('button').some((b) => b.textContent === 'Try again'));
            const bad = makeWindow(device, courtHandlers('judge', { 'court.me': () => ({ ok: false, error: 'server_error' }) }));
            await bad.open('court');
            ok(bad.text().includes('The server could not do that'));
        });

        await it(`${device}: a pushed case change reloads the open case`, async () => {
            const env = makeWindow(device, courtHandlers('judge'));
            await env.open('court');
            await env.click(env.$('[data-nav="cases"]'));
            await env.click(env.$('tr.ju-pick'));
            const before = env.count('case');
            env.win.PFApps.handleMessage({ action: 'pfapp:event', app: 'court', event: 'caseChanged', payload: { caseId: 7 } });
            await settle();
            eq(env.count('case'), before + 1);
            env.win.PFApps.handleMessage({ action: 'pfapp:event', app: 'court', event: 'caseChanged', payload: { caseId: 99 } });
            await settle();
            eq(env.count('case'), before + 1, 'another case: no reload');
        });

        // ── Community Service ──
        const csState = (extra) => ({ ok: true, history: [{ orderId: 3, units: 5, unitsDone: 2, dueAt: now + 86400, state: 'active' }],
            state: Object.assign({ orders: [{ id: 3, units: 5, unitsDone: 2, dueIn: 90000, state: 'active' }],
                signIns: [{ id: 'cityhall', label: EVIL, x: 1.5, y: 2.5, z: 3 }] }, extra || {}) });
        await it(`${device}: community service citizen flow`, async () => {
            let signedIn = false;
            const env = makeWindow(device, {
                'community-service.me': () => ({ ok: true, supervisor: false, hasOrders: true }),
                'community-service.state': () => (signedIn ? csState({ shift: { id: 8, orderId: 3, supervised: false, startedAt: now } }) : csState()),
                'community-service.startShift': () => { signedIn = true; return { ok: true, shiftId: 8 }; },
                'community-service.listWork': () => ({ ok: true, list: [{ id: 44, kind: 'litter', label: EVIL, district: EVIL, distance: 120, unitsOpen: 3 }] }),
                'community-service.claim': () => ({ ok: false, error: 'too_far', message: EVIL }),
            });
            await env.open('community-service');
            eq(env.all('[data-tab]').map((t) => t.dataset.tab).join(','), 'mine', 'no supervisor tabs');
            env.safe();
            await env.click(env.all('button').find((b) => b.textContent === 'Sign in here'));
            eq(env.last('startShift').payload && JSON.stringify(env.last('startShift').payload), '{}', 'no position or order from the page');
            await env.click(env.all('button').find((b) => b.textContent === 'Find work nearby'));
            ok(env.last('listWork'));
            env.safe();
            await env.click(env.all('button').find((b) => b.textContent === 'Take'));
            eq(JSON.stringify(env.last('claim').payload), JSON.stringify({ workOrderId: 44 }));
            ok(env.notes.some((n) => n.t === 'error' && n.m === EVIL), 'the server message is shown (as a toast text)');
        });

        await it(`${device}: a task shows its steps; finish and abandon send the task id`, async () => {
            const env = makeWindow(device, {
                'community-service.me': () => ({ ok: true, supervisor: false, hasOrders: true }),
                'community-service.state': () => csState({ shift: { id: 8, orderId: 3, supervised: true, startedAt: now },
                    task: { id: 12, kind: 'litter', label: EVIL, stepLabel: EVIL, stepsDone: 5, stepsNeeded: 5, minSeconds: 60, site: { x: 10, y: 20 }, points: [] } }),
                'community-service.complete': () => ({ ok: true, unitsDone: 3, units: 5 }),
            });
            await env.open('community-service');
            env.safe();
            await env.click(env.all('button').find((b) => b.textContent === 'Finish task'));
            eq(JSON.stringify(env.last('complete').payload), JSON.stringify({ taskId: 12 }));
            ok(env.notes.some((n) => n.m === 'Unit done: 3 of 5'));
        });

        await it(`${device}: supervisors get the board, sign-off and orders; sign-off sends the worker id`, async () => {
            const env = makeWindow(device, {
                'community-service.me': () => ({ ok: true, supervisor: true, hasOrders: false }),
                'community-service.board': () => ({ ok: true, more: false, list: [{ shiftId: 1, orderId: 3, name: EVIL, cid: 'C1', units: 5, unitsDone: 1, orderState: 'active', startedAt: now, supervised: false }] }),
                'community-service.nearby': () => ({ ok: true, list: [{ src: 14, name: EVIL, shiftId: 1, distance: 6, supervised: false }] }),
                'community-service.verify': () => ({ ok: true, shiftId: 1 }),
                'community-service.orders': () => ({ ok: true, list: [], more: false }),
            });
            await env.open('community-service');
            eq(env.all('[data-tab]').map((t) => t.dataset.tab).join(','), 'board,signoff,orders');
            env.safe();
            await env.click(env.$('[data-tab="signoff"]'));
            env.safe();
            await env.click(env.all('button').find((b) => b.textContent === 'Sign off shift'));
            eq(JSON.stringify(env.last('verify').payload), JSON.stringify({ target: 14 }));
            await env.click(env.$('[data-tab="orders"]'));
            eq(env.last('orders').payload.scope, 'open');
            ok(env.text().includes('No orders here.'));
        });

        await it(`${device}: community service without an order or role says so`, async () => {
            const env = makeWindow(device, { 'community-service.me': () => ({ ok: true, supervisor: false, supervisorJob: true, hasOrders: false }) });
            await env.open('community-service');
            ok(env.text().includes('GOV community-service supervisor qualification'));
            eq(env.count('state'), 0);
        });

        // ── Justice Records ──
        const recHandlers = (extra) => Object.assign({
            'justice-records.record': () => ({ ok: true, entries: [{ id: 1, kind: 'conviction', summary: EVIL, at: now }] }),
            'justice-records.court': () => ({ ok: true, hearings: [{ id: 1, caseNo: EVIL, kind: 'trial', at: now + 3600, courtroom: EVIL }], cases: [{ id: 1, caseNo: EVIL, kind: 'criminal', state: 'filed', filedAt: now }] }),
            'justice-records.sentence': () => ({ ok: true, incarceration: { kind: 'jail', state: 'active', facility: EVIL, clock: 'online', remainingSeconds: 5400, requiredSeconds: 7200 },
                supervision: { kind: 'probation', orderId: 2, state: 'active', endsAt: now + 86400, nextCheckinAt: now, conditions: [{ kind: 'checkin', everyDays: 7 }],
                    appointments: [{ dueAt: now, state: 'scheduled', detail: { location: EVIL } }] }, communityService: [] }),
            'justice-records.fines': () => ({ ok: true, list: [
                { id: 21, kind: 'fine', state: 'issued', amount: 300, paidAmount: 0, owed: 300, payable: true, charges: [{ code: 'PC-1', label: EVIL }] },
                { id: 22, kind: 'citation', state: 'issued', amount: 90, paidAmount: 0, owed: 90, payable: true, contestable: true, contestUntil: now + 3600, violation: EVIL, plate: EVIL },
                { id: 23, kind: 'fine', state: 'invoiced', amount: 70, paidAmount: 0, owed: 70, payable: false } ] }),
            'justice-records.pay': () => ({ ok: false, error: 'payment_unclear', state: 'payment_pending' }),
            'justice-records.contest': () => ({ ok: true }),
            'justice-records.iaForm': () => ({ ok: true, categories: ['conduct', 'force'], key: 'srv:ia:1' }),
            'justice-records.fileComplaint': () => ({ ok: true, complaintId: 41 }),
        }, extra || {});

        await it(`${device}: records tabs render as text with empty and error states`, async () => {
            const env = makeWindow(device, recHandlers({ 'justice-records.court': () => ({ ok: false, error: 'db_unavailable', message: EVIL }) }));
            await env.open('justice-records');
            eq(env.all('[data-tab]').map((t) => t.dataset.tab).join(','), 'record,court,sentence,fines,complaint');
            env.safe();
            await env.click(env.$('[data-tab="court"]'));
            ok(env.text().includes('The justice database did not answer'));
            await env.click(env.$('[data-tab="sentence"]'));
            ok(env.text().includes('1 h 30 min'), 'remaining time from the server');
            ok(env.text().includes('online and inside the facility'), 'the clock rule is explained');
            env.safe();
            const clean = makeWindow(device, recHandlers({ 'justice-records.record': () => ({ ok: true, entries: [] }) }));
            await clean.open('justice-records');
            ok(clean.text().includes('Your record is clean.'));
        });

        await it(`${device}: paying sends only the order and the account; an unclear payment is not called a failure`, async () => {
            const env = makeWindow(device, recHandlers());
            await env.open('justice-records');
            await env.click(env.$('[data-tab="fines"]'));
            env.safe();
            ok(env.text().includes('Pay on your phone'), 'an invoiced fine is paid on the phone');
            await env.click(env.all('button').find((b) => b.textContent === 'Pay $300 (bank)'));
            eq(JSON.stringify(env.last('pay').payload), JSON.stringify({ orderId: 21, account: 'bank' }), 'no key, payer or amount from the page');
            ok(env.notes.some((n) => n.t === 'info' && n.m.includes('still processing')), 'unclear is shown as pending');
            await env.click(env.all('button').filter((b) => b.textContent === 'Pay cash')[1]);
            eq(JSON.stringify(env.last('pay').payload), JSON.stringify({ orderId: 22, account: 'cash' }));
            const contest = env.all('form').find((f) => f.textContent.includes('Contest'));
            contest.querySelector('input').value = 'radar off';
            await env.submit(contest);
            eq(JSON.stringify(env.last('contest').payload), JSON.stringify({ orderId: 22, reason: 'radar off' }));
        });

        await it(`${device}: an IA complaint sends the server key and never a complainant`, async () => {
            let n = 0;
            const env = makeWindow(device, recHandlers({
                'justice-records.fileComplaint': () => (++n === 1 ? { ok: false, error: 'bad_args', message: 'Describe what happened' } : { ok: true, complaintId: 41 }),
            }));
            await env.open('justice-records');
            await env.click(env.$('[data-tab="complaint"]'));
            const form = env.$('form');
            form.querySelector('input').value = 'Ofc. Ray';
            form.querySelector('select').value = 'force';
            form.querySelector('textarea').value = 'short';
            await env.submit(form);
            ok(form.querySelector('.ju-error').textContent === 'Describe what happened', 'the server validation message');
            form.querySelector('textarea').value = 'He pushed me at the pier for no reason.';
            await env.submit(form);
            const p = env.last('fileComplaint').payload;
            eq(p.key, 'srv:ia:1', 'the same key for the retry');
            eq(p.officerName, 'Ofc. Ray');
            eq(p.category, 'force');
            ok(!('complainantCid' in p) && !('complainant' in p), 'the complainant is the player, read on the server');
            ok(env.text().includes('Complaint #41 received'));
        });
    }

    envs.forEach((e) => { try { e.win.PFApps.closeAll(); e.win.close(); } catch (_) { /* ignore */ } });
    console.log(`b21_justice_apps_spec.js  (${passed} passed, ${failed} failed)`);
    failures.forEach((f) => console.log('  - ' + f));
    process.exit(failed ? 1 : 0);
})();
