// Corrections MDT (pfm-prison html/apps/corrections.js) in a simulated browser (jsdom) on the
// pf-devices runtime, on the tablet and the computer: every server string is shown as text
// (`<img onerror>` payloads never become elements), navigation and actions follow the server's
// `can` answer, lists have loading / error / empty states, and every action calls the right
// handler with only ids, choices and the typed text (no times, grades or positions from the page).
// Run: node js/b21_corrections_app_spec.js
const fs = require('fs');
const path = require('path');
const { JSDOM } = require('jsdom');

const QB = path.resolve(__dirname, '..', '..');
const PF = path.resolve(QB, '..', '[pfscripts]');
const RUNTIME = fs.readFileSync(path.join(PF, 'pf-devices/html/runtime.js'), 'utf8');
const MODULE = fs.readFileSync(path.join(QB, 'pfm-prison/html/apps/corrections.js'), 'utf8');
const CSS = fs.readFileSync(path.join(QB, 'pfm-prison/html/apps/corrections.css'), 'utf8');

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

const EVIL = '<img src=x onerror="window.__xss=1">';
const APPS = [{ id: 'corrections', name: 'Corrections', icon: '', kind: 'module', entry: 'https://cfx-nui-pfm-prison/html/apps/corrections.js', styles: [] }];
const NOW = 1800000000;

const canAll = { housing: true, lockdown: true, hearing: true, trust: true, report: true, count: true, visits: true, alarms: true };
const canLow = { housing: false, lockdown: false, hearing: false, trust: false, report: true, count: true, visits: true, alarms: true };
const status = () => ({ ok: true, facility: 'bolingbroke', population: 3, online: 2, escaped: 1, lockdown: true, lockdownReason: EVIL, lockdownUntil: NOW + 600,
    alarms: { alarm: true, gatesOpen: 1 }, nextCount: NOW + 300, phase: { name: 'yard', label: EVIL, endsAt: NOW + 120 }, cells: { total: 19, free: 16, outOfService: 1 } });
const initOf = (can) => ({ ok: true, now: NOW, me: { name: EVIL, grade: 3, gradeLabel: EVIL }, can, status: status(),
    codes: [{ code: 'P-100', label: EVIL, severity: 1 }, { code: 'P-300', label: 'Fighting', severity: 4 }], privileges: ['visits', 'yard'],
    blocks: ['A', EVIL], classes: ['min', 'medium', 'max'], limits: { maxSolitaryMinutes: 60, maxPrivilegeHours: 168, maxForfeitMinutes: 60, minNoticeSeconds: 300, lockdownMaxMinutes: 240 } });
const inmateRow = (i) => ({ cid: 'CID' + i, name: i === 1 ? EVIL : 'Inmate ' + i, cellId: 'A10' + i, block: 'A', classification: 'min', status: i === 1 ? 'solitary' : 'yard', online: i === 1, admittedAt: NOW - 600 });
const inmateView = () => ({ ok: true, now: NOW, inmate: Object.assign(inmateRow(1), { orderId: 101 }),
    sentence: { available: true, orderId: 101, kind: 'prison', state: 'active', requiredSeconds: 1800, servedSeconds: 60, creditSeconds: 120, forfeitSeconds: 0,
        remainingSeconds: 1620, timeToRelease: 1620, charges: [{ code: 'PC-1', label: EVIL, count: 2 }] },
    infractions: [{ id: 4, code: 'P-300', label: EVIL, state: 'reported', at: NOW - 60 }], restrictions: { yard: NOW + 3600 },
    work: [{ job: EVIL, creditSeconds: 300, wage: 25, at: NOW - 30 }],
    trust: { available: true, balance: 130, incoming: 25, outgoing: 10, recent: [{ kind: EVIL, amount: 25, state: 'completed', at: NOW }] },
    cellOptions: [{ id: 'C101', block: 'C', classification: 'max', free: 1 }, { id: 'B102', block: 'B', classification: EVIL, free: 2 }] });

function handlersFor(can, extra) {
    const base = {
        'corrections.init': () => initOf(can),
        'corrections.status': () => ({ ok: true, now: NOW, status: status() }),
        'corrections.population': (p) => (p.q === 'none' ? { ok: true, inmates: [], total: 0, page: 1, pages: 1 }
            : { ok: true, now: NOW, inmates: [inmateRow(1), inmateRow(2)], total: 27, page: p.page || 1, pages: 2 }),
        'corrections.inmate': inmateView,
        'corrections.assignCell': () => ({ ok: true, cellId: 'C101' }),
        'corrections.setClassification': () => ({ ok: true, classification: 'max' }),
        'corrections.reportInfraction': () => ({ ok: true, infractionId: 9, state: 'hearing_scheduled' }),
        'corrections.cells': () => ({ ok: true, cells: [{ id: 'A101', block: 'A', classification: 'min', capacity: 2, occupants: [{ cid: 'CID1', name: EVIL }], outOfService: false },
            { id: 'C101', block: 'C', classification: 'max', capacity: 1, occupants: [], outOfService: true }], overflow: [{ cid: 'OVR', name: EVIL, classification: 'max' }] }),
        'corrections.setCellService': () => ({ ok: true, moved: 1 }),
        'corrections.schedule': () => ({ ok: true, now: NOW, phase: { name: 'yard', label: EVIL, endsAt: NOW + 60 }, nextCount: NOW + 300, lockdown: false,
            upcoming: [{ name: 'yard', label: EVIL, startsAt: NOW - 60, endsAt: NOW + 60, current: true }, { name: 'count', label: 'Headcount', startsAt: NOW + 60, endsAt: NOW + 360, count: true }],
            openCount: null, counts: [{ id: 1, closedAt: NOW - 100, expected: 2, present: 1, missing: ['CID2'], by: 'CO9' }], names: { CID2: EVIL, CO9: EVIL } }),
        'corrections.conductCount': () => ({ ok: false, error: 'too_far', message: 'Conduct the count from inside the facility' }),
        'corrections.infractions': (p) => ({ ok: true, now: NOW, page: p.page || 1, hasMore: (p.page || 1) === 1, filter: p.filter,
            list: p.filter === 'closed' ? [] : [{ id: 4, cid: 'CID1', code: 'P-300', label: EVIL, severity: 4, state: 'reported', at: NOW - 60, reportedBy: 'CO8' }],
            names: { CID1: EVIL, CO8: EVIL } }),
        'corrections.scheduleHearing': () => ({ ok: true, hearingAt: NOW + 600 }),
        'corrections.holdHearing': () => ({ ok: true, state: 'sanctioned', sanction: { forfeit: { state: 'pending' } } }),
        'corrections.visits': () => ({ ok: true, now: NOW, visits: [{ id: 3, inmate: 'CID1', visitor: 'VIS', slotAt: NOW + 600, state: 'checked_in', kind: 'social', searched: false }],
            names: { CID1: EVIL, VIS: EVIL } }),
        'corrections.visitSearch': () => ({ ok: true }),
        'corrections.visitCancel': () => ({ ok: true }),
        'corrections.security': () => ({ ok: true, now: NOW, lockdown: false, alarms: [{ id: 5, kind: 'zone', label: EVIL, at: NOW - 30 }],
            doors: [{ index: 1, id: 'gate', label: EVIL, locked: true }], openEscapes: 1, names: {} }),
        'corrections.setLockdown': () => ({ ok: true, lockdown: true }),
        'corrections.clearAlarm': () => ({ ok: true }),
        'corrections.cameras': () => ({ ok: true, cameras: [{ index: 1, id: 'gate_front', label: EVIL, coords: { x: 1.4, y: 2.6, z: 3 } }], controlPoints: [EVIL] }),
        'corrections.trust': (p) => (p.cid ? { ok: true, cid: p.cid, name: EVIL, balance: 80, incoming: 0, outgoing: 0, recent: [] }
            : { ok: true, accounts: [{ cid: 'CID1', balance: 80, held: true }], total: 80, names: { CID1: EVIL } }),
    };
    return Object.assign(base, extra || {});
}

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
    const intervals = { set: 0, cleared: 0 };
    const si = win.setInterval.bind(win);
    const ci = win.clearInterval.bind(win);
    win.setInterval = (fn, ms) => { intervals.set++; return si(fn, ms); };
    win.clearInterval = (id) => { intervals.cleared++; return ci(id); };
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
    const root = () => win.document.querySelector('[data-window="corrections"]');
    const button = (text) => [...root().querySelectorAll('button')].find((b) => b.textContent === text);
    const nav = (id) => root().querySelector(`[data-section="${id}"]`);
    const last = (method) => rpcs.filter((r) => r.method === method).pop();
    const noImg = (where) => { eq(root().querySelectorAll('img').length, 0, `server text became HTML (${where})`); ok(!win.__xss, 'payload ran'); };
    return { win, rpcs, notes, root, button, nav, last, noImg, intervals };
}

async function open(device, handlers) {
    const env = makeWindow(device, handlers);
    await env.win.PFApps.refresh();
    await env.win.PFApps.open('corrections');
    await settle();
    return env;
}

(async () => {
    for (const device of ['tablet', 'computer']) {
        await it(`${device}: overview and header show server text as text; the nav follows the server's answer`, async () => {
            const env = await open(device, handlersFor(canAll));
            const root = env.root();
            ok(root.querySelector('.pfc'), 'mounted');
            env.noImg('overview');
            ok(root.textContent.includes(EVIL), 'payload shown as text');
            ok(root.textContent.includes('LOCKDOWN'), 'lockdown in the header');
            ok(root.textContent.includes('in 10 min'), 'lockdown end relative to the server clock');
            ok(env.nav('trust'), 'trust nav for the trust grade');
            eq(env.last('init') !== undefined, true);
        });

        await it(`${device}: a low grade gets no trust section and no housing, hearing or lockdown controls`, async () => {
            const env = await open(device, handlersFor(canLow));
            ok(!env.nav('trust'), 'no trust nav');
            env.nav('population').click();
            await settle();
            env.root().querySelector('tr[data-cid="CID1"]').click();
            await settle();
            ok(!env.button('Move'), 'no move');
            ok(!env.button('Set'), 'no classification');
            ok(env.button('Report'), 'report is for every officer');
            env.nav('discipline').click();
            await settle();
            ok(!env.button('Hold hearing'), 'no hearing');
            ok(!env.button('Schedule'), 'no schedule');
            env.nav('security').click();
            await settle();
            ok(!env.button('Start lockdown'), 'no lockdown control');
            ok(env.root().textContent.includes('sergeant'), 'who can lock down is explained');
            env.nav('cells').click();
            await settle();
            ok(!env.button('Take out of service'), 'no cell service control');
        });

        await it(`${device}: population is searched, filtered and paged on the server; an inmate opens by id`, async () => {
            const env = await open(device, handlersFor(canAll));
            env.nav('population').click();
            await settle();
            env.noImg('population');
            eq(env.last('population').payload.page, 1);
            const q = env.root().querySelector('input[type="search"]');
            q.value = 'alice';
            q.dispatchEvent(new env.win.Event('input'));
            q.dispatchEvent(new env.win.KeyboardEvent('keydown', { key: 'Enter' }));
            await settle();
            eq(JSON.stringify(env.last('population').payload), JSON.stringify({ q: 'alice', status: '', classification: '', block: '', sort: 'cell', page: 1 }));
            const statusSel = env.root().querySelector('select[aria-label="Status"]');
            statusSel.value = 'solitary';
            statusSel.dispatchEvent(new env.win.Event('change'));
            await settle();
            eq(env.last('population').payload.status, 'solitary');
            env.button('Next').click();
            await settle();
            eq(env.last('population').payload.page, 2);
            ok(env.root().textContent.includes('Page 2 of 2'), 'pager');
            // keyboard: Enter on a row opens the inmate
            env.root().querySelector('tr[data-cid="CID2"]').dispatchEvent(new env.win.KeyboardEvent('keydown', { key: 'Enter' }));
            await settle();
            eq(JSON.stringify(env.last('inmate').payload), JSON.stringify({ cid: 'CID2' }));
            env.noImg('inmate');
            ok(env.root().textContent.includes('27 min'), 'time to release from the server');
            ok(env.root().textContent.includes('$130'), 'trust balance');
        });

        await it(`${device}: an empty search and a failed list show their states; Retry asks again`, async () => {
            let fail = true;
            const env = await open(device, handlersFor(canAll, {
                'corrections.cells': () => (fail ? { ok: false, error: 'db_unavailable' } : { ok: true, cells: [], overflow: [] }),
                'corrections.visits': () => ({ ok: true, now: NOW, visits: [], names: {} }),
            }));
            env.nav('population').click();
            await settle();
            const q = env.root().querySelector('input[type="search"]');
            q.value = 'none';
            q.dispatchEvent(new env.win.KeyboardEvent('keydown', { key: 'Enter' }));
            await settle();
            ok(env.root().textContent.includes('No inmate matches.'), 'empty search');
            env.nav('cells').click();
            await settle();
            ok(env.root().querySelector('[role="alert"]'), 'error state');
            ok(env.root().textContent.includes('Something went wrong'), 'error text from the code');
            fail = false;
            env.button('Retry').click();
            await settle();
            ok(env.root().textContent.includes('No cells are configured.'), 'empty after retry');
            eq(env.rpcs.filter((r) => r.method === 'cells').length, 2);
            env.nav('visits').click();
            await settle();
            ok(env.root().textContent.includes('No visits today.'), 'empty visits');
        });

        await it(`${device}: housing and the infraction report send ids, choices and the typed text only`, async () => {
            const env = await open(device, handlersFor(canAll));
            env.nav('population').click();
            await settle();
            env.root().querySelector('tr[data-cid="CID1"]').click();
            await settle();
            const cellSel = env.root().querySelector('select[aria-label="Move to cell"]');
            cellSel.value = 'C101';
            env.button('Move').click();
            await settle();
            eq(JSON.stringify(env.last('assignCell').payload), JSON.stringify({ cid: 'CID1', cellId: 'C101' }));
            const classSel = env.root().querySelector('select[aria-label="Classification"]');
            classSel.value = 'max';
            env.root().querySelector('input[placeholder="Reason"]').value = 'threats';
            env.button('Set').click();
            await settle();
            eq(JSON.stringify(env.last('setClassification').payload), JSON.stringify({ cid: 'CID1', classification: 'max', reason: 'threats' }));
            // a bad evidence id is caught before the call
            const ev = env.root().querySelector('input[placeholder^="Evidence ids"]');
            ev.value = '12, x';
            env.button('Report').click();
            await settle();
            ok(!env.last('reportInfraction'), 'no call with a bad id');
            ok(env.notes.some((n) => /whole numbers/.test(n.m)), 'told why');
            ev.value = '12, 15';
            env.root().querySelector('select[aria-label="Offence"]').value = 'P-300';
            env.root().querySelector('input[placeholder^="Hearing in"]').value = '10';
            env.button('Report').click();
            await settle();
            eq(JSON.stringify(env.last('reportInfraction').payload), JSON.stringify({ cid: 'CID1', code: 'P-300', evidenceIds: [12, 15], hearingInMinutes: 10 }));
            ok(env.notes.some((n) => n.m === 'Infraction #9 reported'), 'confirmed');
        });

        await it(`${device}: cells, routine and the officer count; the server's refusal is shown`, async () => {
            const env = await open(device, handlersFor(canAll));
            env.nav('cells').click();
            await settle();
            env.noImg('cells');
            env.button('Take out of service').click();
            await settle();
            eq(JSON.stringify(env.last('setCellService').payload), JSON.stringify({ cellId: 'A101', outOfService: true }));
            ok(env.notes.some((n) => n.m === 'Cell A101 out of service, 1 moved'), 'moved count');
            env.button('Return to service').click();
            await settle();
            eq(JSON.stringify(env.last('setCellService').payload), JSON.stringify({ cellId: 'C101', outOfService: false }));
            env.nav('schedule').click();
            await settle();
            env.noImg('schedule');
            ok(env.root().textContent.includes(EVIL), 'names in the history as text');
            env.button('Conduct count').click();
            await settle();
            eq(JSON.stringify(env.last('conductCount').payload), '{}');
            ok(env.notes.some((n) => n.m === 'Conduct the count from inside the facility' && n.t === 'error'), 'server message shown');
        });

        await it(`${device}: discipline lists, schedules and holds hearings with the right payloads`, async () => {
            const env = await open(device, handlersFor(canAll));
            env.nav('discipline').click();
            await settle();
            env.noImg('discipline');
            eq(JSON.stringify(env.last('infractions').payload), JSON.stringify({ filter: 'open', page: 1 }));
            env.button('Schedule').click();
            await settle();
            ok(!env.last('scheduleHearing'), 'no call without minutes');
            env.root().querySelector('input[aria-label="Hearing in minutes"]').value = '15';
            env.button('Schedule').click();
            await settle();
            eq(JSON.stringify(env.last('scheduleHearing').payload), JSON.stringify({ id: 4, inMinutes: 15 }));
            env.button('Hold hearing').click();
            await settle();
            env.noImg('hearing form');
            env.root().querySelector('textarea').value = EVIL;
            env.root().querySelector('input[placeholder^="Forfeit"]').value = '15';
            env.root().querySelector('input[aria-label="Restrict yard"]').checked = true;
            env.root().querySelector('input[aria-label="yard hours"]').value = '48';
            env.button('Record decision').click();
            await settle();
            eq(JSON.stringify(env.last('holdHearing').payload), JSON.stringify({ id: 4, verdict: 'guilty', note: EVIL, forfeitMinutes: 15, privileges: [{ kind: 'yard', hours: 48 }] }));
            ok(env.notes.some((n) => /forfeit pending/.test(n.m)), 'forfeit state reported honestly');
            env.button('Decided').click();
            await settle();
            eq(env.last('infractions').payload.filter, 'closed');
            ok(env.root().textContent.includes('No infractions here.'), 'empty decided list');
        });

        await it(`${device}: visits, lockdown, alarms, cameras and trust`, async () => {
            const env = await open(device, handlersFor(canAll));
            env.nav('visits').click();
            await settle();
            env.noImg('visits');
            env.button('Clear search').click();
            await settle();
            eq(JSON.stringify(env.last('visitSearch').payload), JSON.stringify({ id: 3, allow: true }));
            env.root().querySelector('input[aria-label="Reason to deny"]').value = 'contraband';
            env.button('Deny').click();
            await settle();
            eq(JSON.stringify(env.last('visitSearch').payload), JSON.stringify({ id: 3, allow: false, note: 'contraband' }));
            env.button('Cancel').click();
            await settle();
            eq(JSON.stringify(env.last('visitCancel').payload), JSON.stringify({ id: 3 }));
            env.nav('security').click();
            await settle();
            env.noImg('security');
            env.root().querySelector('input[placeholder="Reason"]').value = 'riot';
            env.root().querySelector('input[aria-label="Minutes"]').value = '30';
            env.button('Start lockdown').click();
            await settle();
            eq(JSON.stringify(env.last('setLockdown').payload), JSON.stringify({ on: true, reason: 'riot', minutes: 30 }));
            env.button('Clear').click();
            await settle();
            eq(JSON.stringify(env.last('clearAlarm').payload), JSON.stringify({ id: 5 }));
            env.nav('cameras').click();
            await settle();
            env.noImg('cameras');
            ok(env.root().textContent.includes('no recording'), 'honest limit');
            ok(!env.button('View'), 'cameras are listed only');
            env.nav('trust').click();
            await settle();
            env.noImg('trust');
            env.root().querySelector('tr.pfc-click').click();
            await settle();
            eq(JSON.stringify(env.last('trust').payload), JSON.stringify({ cid: 'CID1' }));
            ok(env.root().textContent.includes('Read only'), 'read-only note');
        });

        await it(`${device}: a refused start shows the reason and Retry; closing clears the refresh timer`, async () => {
            let refuse = true;
            const env = await open(device, handlersFor(canAll, { 'corrections.init': () => (refuse ? { ok: false, error: 'not_on_duty' } : initOf(canAll)) }));
            ok(env.root().textContent.includes('Go on duty first'), 'refusal from the code');
            ok(!env.nav('overview'), 'no navigation without the server answer');
            refuse = false;
            env.button('Retry').click();
            await settle();
            ok(env.nav('overview'), 'mounted after retry');
            ok(env.intervals.set >= 1, 'refresh timer');
            env.win.PFApps.close('corrections');
            ok(env.intervals.cleared >= 1, 'timer cleared');
        });
    }

    await it('the stylesheet declares no shared token and uses nothing Chromium 103 lacks', async () => {
        const rules = CSS.replace(/\/\*[\s\S]*?\*\//g, '');
        ok(!/--pf-(bg|fg|line|ok|warn|bad|radius)[\w-]*\s*:/.test(rules), 'reserved tokens declared');
        ok(!/:has\(|color-mix\(|@layer|@container/.test(rules), 'unsupported CSS');
        ok(!/innerHTML\s*=\s*[^'"]/.test(MODULE.replace(/innerHTML = ''/g, '')), 'innerHTML only cleared');
        ok(!/html:\s/.test(MODULE), 'no html attribute in ctx.h');
    });

    console.log(`b21_corrections_app_spec: ${passed} passed, ${failed} failed`);
    if (failures.length) { failures.forEach((f) => console.log('  - ' + f)); process.exit(1); }
})();
