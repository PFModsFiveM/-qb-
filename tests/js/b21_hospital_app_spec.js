// pf-emsmdt hospital workstation (batch 21D, html/apps/hospital.js) in a simulated browser (jsdom) on
// the pf-devices runtime: every server string lands as text (an <img onerror> payload never becomes
// an element), the tabs are the pages the server's init lists (bills only when it says so), loading,
// error and empty states, and each action sends the right method with ids only (the server resolves
// the patient). Run: node js/b21_hospital_app_spec.js
const fs = require('fs');
const path = require('path');
const { JSDOM } = require('jsdom');

const PF = path.resolve(__dirname, '..', '..', '..', '[pfscripts]');
const RUNTIME = fs.readFileSync(path.join(PF, 'pf-devices/html/runtime.js'), 'utf8');
const MODULE = fs.readFileSync(path.join(PF, 'pf-emsmdt/html/apps/hospital.js'), 'utf8');
const CSS = fs.readFileSync(path.join(PF, 'pf-emsmdt/html/apps/hospital.css'), 'utf8');

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
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

const EVIL = '<img src=x onerror="window.__xss=1">';
const APPS = [{ id: 'hospital', name: 'Hospital', icon: '', kind: 'module', entry: 'https://cfx-nui-pf-emsmdt/html/apps/hospital.js', styles: [] }];
const PAGES = ['reception', 'triage', 'beds', 'admissions', 'discharge', 'lab', 'imaging', 'pharmacy'];
const OPTIONS = {
    triage: ['red', 'orange', 'yellow', 'green', 'blue'],
    restrictions: [{ id: 'no_drive', label: 'No driving' }, { id: 'crutches', label: EVIL }],
    maxRestrictionHours: 168, maxFollowUpDays: 30,
    formulary: [{ id: 'painkillers', label: 'Painkillers', maxUnits: 12, maxFills: 3 }, { id: 'antibiotics', label: 'Antibiotics', maxUnits: 6, maxFills: 2 }],
    lab: [{ id: 'blood_type', label: 'Blood type' }, { id: 'cbc', label: 'Complete blood count' }],
    imaging: [{ id: 'xray', label: 'X-ray' }, { id: 'ct', label: 'CT scan' }],
    careLevels: [{ id: 'standard', label: 'Standard' }, { id: 'icu', label: 'Intensive care' }],
    departments: { ed: 'Emergency department', ward: 'Ward' },
};
const now = () => Math.floor(Date.now() / 1000);
const initOk = (extra) => Object.assign({ ok: true, facility: 'pillbox', pages: PAGES.slice(), me: { name: 'Doc', grade: 1, supervisor: false }, options: OPTIONS,
    facilities: [{ id: 'pillbox', label: EVIL }, { id: 'paleto', label: 'Paleto Bay Medical Center' }] }, extra || {});
const board = (list) => ({
    ok: true, facility: 'pillbox', staffOnDuty: 2, aiActive: true,
    beds: [{ dept: 'ed', label: 'Emergency department', total: 5, free: 4 }, { dept: 'ward', label: EVIL, total: 3, free: 0 }],
    admissions: list || [
        { id: 11, citizenid: 'PAT1', name: EVIL, online: true, state: 'checked_in', triage: 'orange', reason: EVIL, arrivedAt: now() - 120, open: true },
        { id: 12, citizenid: 'OFF1', name: 'Off Line', online: false, state: 'admitted', triage: 'green', dept: 'ward', bedId: 'w1', arrivedAt: now() - 3600, admittedAt: now() - 3000, open: true, custody: 'order' },
    ],
});

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
            const fn = handlers[body.method];
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
    const root = () => win.document.querySelector('[data-window="hospital"]');
    const rpc = (method) => rpcs.filter((r) => r.method === method);
    const last = (method) => { const l = rpc(method); return l.length ? l[l.length - 1].payload : undefined; };
    const tab = (page) => root().querySelector(`[data-page="${page}"]`);
    const open = async () => { await win.PFApps.refresh(); await win.PFApps.open('hospital'); await settle(); };
    return { win, rpcs, notes, root, rpc, last, tab, open };
}

function noXss(env) {
    eq(env.root().querySelectorAll('img').length, 0, 'no element from a server string');
    eq(env.win.__xss, undefined, 'no script ran');
}

const baseHandlers = (over) => Object.assign({
    init: () => initOk(),
    board: () => board(),
    history: () => ({ ok: true, admissions: [{ id: 9, citizenid: 'OLD1', name: EVIL, state: 'discharged', open: false, arrivedAt: now() - 99999, dischargedAt: now() - 9999 }] }),
    orders: (p) => ({ ok: true, kind: p.kind, orders: [
        { id: 70, citizenid: 'PAT1', name: EVIL, online: true, admissionId: 11, test: p.kind === 'lab' ? 'cbc' : 'ct', label: EVIL, state: 'ordered', orderedAt: now() - 60 },
        { id: 72, citizenid: 'PAT1', name: 'Pat', online: true, admissionId: 11, test: 'bac', label: 'Blood alcohol', state: 'resulted', orderedAt: now() - 600, hasResult: true },
    ] }),
    pharmacy: () => ({ ok: true, hospitalId: 'pillbox', label: EVIL, page: 1, more: true, list: [{ id: 3, citizenid: 'PAT1', name: EVIL, drug: 'painkillers', label: EVIL, fills: 3, filled: 1, units: 4, controlled: true, expiresAt: now() + 86400 },
        { id: 4, citizenid: 'INM1', name: 'Inmate', drug: 'painkillers', label: 'Painkillers', fills: 6, filled: 0, units: 1, infirmary: true, expiresAt: now() + 86400 }] }),
    results: () => ({ ok: true, list: [{ id: 70, label: 'Complete blood count', state: 'resulted', orderedAt: now() - 600, result: { values: { hemoglobin: 9.1, note: EVIL }, findings: [{ label: EVIL, structure: 'femur_l' }] } }] }),
    controlledLog: () => ({ ok: true, list: [{ id: 1, drug: 'morphine', qty: 1, kind: 'withdraw', at: now() - 30, patient: EVIL, by: 'Doc' }] }),
    bills: () => ({ ok: true, page: 1, more: false, list: [{ id: 8, citizenid: 'PAT1', name: EVIL, admissionId: 11, total: 900, discount: 450, due: 450, state: 'invoiced', createdAt: now() - 100 }] }),
    billLines: () => ({ ok: true, lines: [{ kind: 'bed', label: EVIL, qty: 3, unitPrice: 100, amount: 300 }] }),
}, over || {});

(async () => {
    for (const device of ['tablet', 'computer']) {
        await it(`${device}: reception shows the server's queue as text, tabs from the server`, async () => {
            const env = makeWindow(device, baseHandlers());
            await env.open();
            const root = env.root();
            ok(root.querySelector('.hosp-app'), 'mounted');
            eq([...root.querySelectorAll('[data-page]')].map((t) => t.dataset.page).join(','), PAGES.join(','));
            ok(!env.tab('bills'), 'no bills tab: the server did not list it');
            ok(root.textContent.includes(EVIL), 'patient name and facility label as text');
            ok(root.querySelector('[data-admission="11"]'), 'the waiting patient');
            ok(!root.querySelector('tbody [data-admission="12"]'), 'an admitted patient is not at reception');
            ok(root.textContent.includes('AI care active'));
            eq(env.last('board').facility, 'pillbox');
            noXss(env);
        });
    }

    await it('a supervisor gets the bills tab only because init lists it', async () => {
        const env = makeWindow('computer', baseHandlers({ init: () => initOk({ pages: [...PAGES, 'bills'], me: { supervisor: true } }) }));
        await env.open();
        ok(env.tab('bills'), 'bills tab');
        env.tab('bills').click();
        await settle();
        eq(JSON.stringify(env.last('bills')), JSON.stringify({ facility: 'pillbox', state: '', q: '', page: 1 }));
        ok(env.root().textContent.includes('$450'), 'due after coverage');
        env.root().querySelector('[data-action="billLines"]').click();
        await settle();
        eq(env.last('billLines').billId, 8);
        ok(env.root().textContent.includes('$300'));
        const sel = env.root().querySelector('[data-field="billState"]');
        sel.value = 'paid';
        sel.dispatchEvent(new env.win.Event('change'));
        await settle();
        eq(env.last('bills').state, 'paid');
        const q = env.root().querySelector('[data-field="q"]');
        q.value = 'Ann Lee';
        q.dispatchEvent(new env.win.KeyboardEvent('keydown', { key: 'Enter' }));
        await settle();
        eq(env.last('bills').q, 'Ann Lee');
        eq(env.last('bills').page, 1);
        noXss(env);
    });

    await it('init refused: the server message and a retry, no tabs', async () => {
        let n = 0;
        const env = makeWindow('tablet', baseHandlers({ init: () => { n++; return { ok: false, error: 'not_on_duty', message: EVIL }; } }));
        await env.open();
        const root = env.root();
        ok(root.querySelector('.hosp-error'), 'error state');
        ok(root.textContent.includes(EVIL), 'message as text');
        eq(root.querySelectorAll('[data-page]').length, 0);
        root.querySelector('[data-action="retry"]').click();
        await settle();
        eq(n, 2);
        noXss(env);
    });

    await it('init error code without a message: the code is explained', async () => {
        const env = makeWindow('tablet', baseHandlers({ init: () => ({ ok: false, error: 'hospital_offline' }) }));
        await env.open();
        ok(env.root().textContent.includes('The hospital system is offline.'));
    });

    await it('empty and error states of the board', async () => {
        const env = makeWindow('tablet', baseHandlers({ board: () => board([]) }));
        await env.open();
        ok(env.root().textContent.includes('Nobody is waiting at reception.'));
        env.tab('triage').click(); await settle();
        ok(env.root().textContent.includes('No open admissions.'));
        const env2 = makeWindow('tablet', baseHandlers({ board: () => ({ ok: false, error: 'db_unavailable' }) }));
        await env2.open();
        ok(env2.root().textContent.includes('Hospital records are unavailable right now.'));
        ok(env2.root().querySelector('[data-action="retry"]'));
    });

    await it('quick triage at reception sends the admission id and the colour only', async () => {
        const env = makeWindow('tablet', baseHandlers({ triage: () => ({ ok: true, admissionId: 11, triage: 'red' }) }));
        await env.open();
        const row = env.root().querySelector('tr[data-admission="11"]');
        row.querySelector('[data-field="triage"]').value = 'red';
        row.querySelector('[data-action="triage"]').click();
        await settle();
        eq(JSON.stringify(env.last('triage')), JSON.stringify({ facility: 'pillbox', admissionId: 11, level: 'red' }));
        ok(env.rpc('board').length >= 2, 'the board reloads after the change');
    });

    await it('a refused action shows the server message', async () => {
        const env = makeWindow('tablet', baseHandlers({ triage: () => ({ ok: false, error: 'too_far', message: 'Stand next to the patient.' }) }));
        await env.open();
        env.root().querySelector('tr[data-admission="11"] [data-action="triage"]').click();
        await settle();
        ok(env.notes.some((n) => n.t === 'error' && n.m === 'Stand next to the patient.'));
    });

    await it('triage board and beds: columns by colour, occupied beds and free counts', async () => {
        const env = makeWindow('computer', baseHandlers());
        await env.open();
        env.tab('triage').click(); await settle();
        ok(env.root().querySelector('[data-triage="orange"] [data-admission="11"]'));
        ok(env.root().querySelector('[data-triage="green"] [data-admission="12"]'));
        env.tab('beds').click(); await settle();
        const ward = env.root().querySelector('[data-dept="ward"]');
        ok(ward.textContent.includes('0/3 free'));
        ok(ward.querySelector('[data-admission="12"]'));
        ok(ward.textContent.includes(EVIL), 'department label as text');
        noXss(env);
    });

    await it('patient panel: admit, lab, imaging, prescribe and results send ids and choices only', async () => {
        const calls = {};
        const env = makeWindow('computer', baseHandlers({
            admit: (p) => { calls.admit = p; return { ok: true, dept: 'ward', bedId: 'w2' }; },
            labOrder: () => ({ ok: true, orderId: 80 }), imagingOrder: () => ({ ok: true, orderId: 81 }),
            prescribe: () => ({ ok: true, prescriptionId: 5 }), careLevel: () => ({ ok: true }),
            transfer: () => ({ ok: true }),
        }));
        await env.open();
        env.root().querySelector('tr[data-admission="11"] [data-action="open"]').click();
        await settle();
        const panel = env.root().querySelector('[data-panel="11"]');
        ok(panel, 'panel open');
        panel.querySelector('[data-field="dept"]').value = 'ward';
        panel.querySelector('[data-field="bed"]').value = 'w2';
        panel.querySelector('[data-action="admit"]').click();
        await settle();
        eq(JSON.stringify(env.last('admit')), JSON.stringify({ facility: 'pillbox', admissionId: 11, dept: 'ward', bedId: 'w2' }));
        let p2 = env.root().querySelector('[data-panel="11"]');
        p2.querySelector('[data-field="labTest"]').value = 'cbc';
        p2.querySelector('[data-action="labOrder"]').click(); await settle();
        eq(JSON.stringify(env.last('labOrder')), JSON.stringify({ facility: 'pillbox', admissionId: 11, test: 'cbc' }));
        p2 = env.root().querySelector('[data-panel="11"]');
        p2.querySelector('[data-action="imagingOrder"]').click(); await settle();
        eq(env.last('imagingOrder').test, 'xray');
        p2 = env.root().querySelector('[data-panel="11"]');
        p2.querySelector('[data-field="drug"]').value = 'antibiotics';
        p2.querySelector('[data-field="units"]').value = '2';
        p2.querySelector('[data-field="fills"]').value = '1';
        p2.querySelector('[data-action="prescribe"]').click(); await settle();
        eq(JSON.stringify(env.last('prescribe')), JSON.stringify({ facility: 'pillbox', admissionId: 11, drug: 'antibiotics', units: 2, fills: 1, note: '' }));
        p2 = env.root().querySelector('[data-panel="11"]');
        p2.querySelector('[data-field="transferTo"]').value = 'paleto';
        p2.querySelector('[data-action="transfer"]').click(); await settle();
        eq(JSON.stringify(env.last('transfer')), JSON.stringify({ facility: 'pillbox', admissionId: 11, to: 'paleto' }));
        p2 = env.root().querySelector('[data-panel="11"]');
        ok(!p2.querySelector('[data-action="careLevel"]'), 'care level only for a patient in a bed');
        p2.querySelector('[data-action="results"]').click(); await settle();
        eq(env.last('results').admissionId, 11);
        ok(env.root().textContent.includes('hemoglobin: 9.1'));
        ok(env.root().textContent.includes(EVIL), 'finding as text');
        noXss(env);
        // Escape closes the panel
        env.root().querySelector('[data-panel="11"]').dispatchEvent(new env.win.KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
        ok(!env.root().querySelector('[data-panel="11"]'));
    });

    await it('a bed patient gets the care level; custody is flagged', async () => {
        const env = makeWindow('computer', baseHandlers({ careLevel: () => ({ ok: true, level: 'icu' }) }));
        await env.open();
        env.tab('admissions').click(); await settle();
        env.root().querySelector('tr[data-admission="12"] [data-action="open"]').click(); await settle();
        const panel = env.root().querySelector('[data-panel="12"]');
        ok(panel.textContent.includes('custody'));
        panel.querySelector('[data-field="careLevel"]').value = 'icu';
        panel.querySelector('[data-action="careLevel"]').click(); await settle();
        eq(JSON.stringify(env.last('careLevel')), JSON.stringify({ facility: 'pillbox', admissionId: 12, level: 'icu' }));
    });

    await it('admissions: history comes from the server with its state filter', async () => {
        const env = makeWindow('computer', baseHandlers());
        await env.open();
        env.tab('admissions').click(); await settle();
        const view = env.root().querySelector('[data-field="view"]');
        view.value = 'history';
        view.dispatchEvent(new env.win.Event('change'));
        await settle();
        eq(env.last('history').facility, 'pillbox');
        ok(env.root().querySelector('tr[data-admission="9"]'));
        const st = env.root().querySelector('[data-field="historyState"]');
        st.value = 'discharged';
        st.dispatchEvent(new env.win.Event('change'));
        await settle();
        eq(env.last('history').state, 'discharged');
        noXss(env);
    });

    await it('discharge orders: restrictions, follow-up, note and prescriptions in one call', async () => {
        const env = makeWindow('tablet', baseHandlers({ discharge: () => ({ ok: true, admissionId: 12 }) }));
        await env.open();
        env.tab('discharge').click(); await settle();
        const form = env.root().querySelector('[data-form="discharge"]');
        form.querySelector('[data-field="dischargeAdmission"]').value = '12';
        form.querySelector('[data-restriction="no_drive"]').checked = true;
        form.querySelector('[data-hours="no_drive"]').value = '48';
        form.querySelector('[data-field="followUp"]').value = '72';
        form.querySelector('[data-field="note"]').value = 'Rest';
        form.querySelector('[data-action="addRx"]').click();
        form.querySelector('[data-rx="drug"]').value = 'antibiotics';
        form.querySelector('[data-rx="units"]').value = '2';
        form.querySelector('[data-action="discharge"]').click();
        await settle();
        eq(JSON.stringify(env.last('discharge')), JSON.stringify({ facility: 'pillbox', admissionId: 12, orders: {
            restrictions: [{ kind: 'no_drive', hours: 48 }], note: 'Rest', prescriptions: [{ drug: 'antibiotics', units: 2, fills: 1 }], followUpHours: 72 } }));
        ok(env.notes.some((n) => n.t === 'success'));
        ok(form.textContent.includes(EVIL), 'option label as text');
        noXss(env);
    });

    await it('discharge refused: the server reason is shown, nothing else changes', async () => {
        const env = makeWindow('tablet', baseHandlers({ discharge: () => ({ ok: false, error: 'no_permission', message: 'Prescriptions need a physician as the actor.' }) }));
        await env.open();
        env.tab('discharge').click(); await settle();
        env.root().querySelector('[data-action="discharge"]').click(); await settle();
        ok(env.notes.some((n) => n.t === 'error' && n.m === 'Prescriptions need a physician as the actor.'));
    });

    await it('lab queue: draw and cancel by order id; a new order by admission and test', async () => {
        const env = makeWindow('computer', baseHandlers({ labDraw: () => ({ ok: true, readyAt: now() + 300 }), orderCancel: () => ({ ok: true }), labOrder: () => ({ ok: true, orderId: 90 }) }));
        await env.open();
        env.tab('lab').click(); await settle();
        eq(JSON.stringify(env.last('orders')), JSON.stringify({ facility: 'pillbox', kind: 'lab', open: true }));
        const row = env.root().querySelector('tr[data-order="70"]');
        row.querySelector('[data-action="labDraw"]').click(); await settle();
        eq(JSON.stringify(env.last('labDraw')), JSON.stringify({ orderId: 70 }));
        env.root().querySelector('tr[data-order="70"] [data-action="orderCancel"]').click(); await settle();
        eq(env.last('orderCancel').orderId, 70);
        ok(!env.root().querySelector('tr[data-order="72"] [data-action="labDraw"]'), 'no draw on a resulted order');
        const form = env.root().querySelector('[data-form="labOrder"]');
        form.querySelector('[data-field="orderTest"]').value = 'cbc';
        form.querySelector('[data-action="labOrder"]').click(); await settle();
        eq(JSON.stringify(env.last('labOrder')), JSON.stringify({ facility: 'pillbox', admissionId: 11, test: 'cbc' }));
        const which = env.root().querySelector('[data-field="ordersOpen"]');
        which.value = 'all';
        which.dispatchEvent(new env.win.Event('change')); await settle();
        eq(env.last('orders').open, false);
        noXss(env);
    });

    await it('imaging: run scan, then the pushed outcome is shown and the queue reloads', async () => {
        const env = makeWindow('computer', baseHandlers({ imagingPerform: () => ({ ok: true, started: true, orderId: 70 }) }));
        await env.open();
        env.tab('imaging').click(); await settle();
        env.root().querySelector('tr[data-order="70"] [data-action="imagingPerform"]').click(); await settle();
        eq(env.last('imagingPerform').orderId, 70);
        const before = env.rpc('orders').length;
        env.win.PFApps.handleMessage({ action: 'pfapp:event', app: 'hospital', event: 'imaging', payload: { orderId: 70, ok: true, findings: [{ label: EVIL, structure: 'skull' }] } });
        await settle();
        ok(env.notes.some((n) => n.t === 'success' && n.m.includes('skull')));
        ok(env.rpc('orders').length > before, 'queue reloaded');
        noXss(env);
    });

    await it('pharmacy: search, paging, cancel and the controlled-substance log', async () => {
        const env = makeWindow('tablet', baseHandlers({ rxCancel: () => ({ ok: true }) }));
        await env.open();
        env.tab('pharmacy').click(); await settle();
        eq(JSON.stringify(env.last('pharmacy')), JSON.stringify({ facility: 'pillbox', q: '', page: 1 }));
        ok(env.root().textContent.includes('controlled'));
        ok(env.root().querySelector('[data-field="queueOf"]').textContent.includes(EVIL), 'the server names the hospital whose queue it is (as text)');
        ok(!env.root().querySelector('tr[data-rx="4"] [data-action="rxCancel"]'), 'an infirmary schedule is not cancelled at a counter');
        const q = env.root().querySelector('[data-field="q"]');
        q.value = ' PAT1 ';
        env.root().querySelector('[data-action="search"]').click(); await settle();
        eq(env.last('pharmacy').q, 'PAT1');
        env.root().querySelector('[data-action="nextPage"]').click(); await settle();
        eq(env.last('pharmacy').page, 2);
        env.root().querySelector('[data-action="rxCancel"]').click(); await settle();
        eq(env.last('rxCancel').rxId, 3);
        env.root().querySelector('[data-action="controlledLog"]').click(); await settle();
        ok(env.rpc('controlledLog').length === 1);
        ok(env.root().textContent.includes('morphine'));
        noXss(env);
    });

    await it('changing the facility reloads that facility; a push for it reloads the board', async () => {
        const env = makeWindow('computer', baseHandlers());
        await env.open();
        const sel = env.root().querySelector('[data-action="facility"]');
        eq(sel.options.length, 2);
        ok(sel.options[0].textContent === EVIL, 'label as text');
        sel.value = 'paleto';
        sel.dispatchEvent(new env.win.Event('change')); await settle();
        eq(env.last('board').facility, 'paleto');
        const n = env.rpc('board').length;
        env.win.PFApps.handleMessage({ action: 'pfapp:event', app: 'hospital', event: 'changed', payload: { hospitalId: 'pillbox', admissionId: 11 } });
        await wait(450); await settle();
        eq(env.rpc('board').length, n, 'another facility: no reload');
        env.win.PFApps.handleMessage({ action: 'pfapp:event', app: 'hospital', event: 'changed', payload: { hospitalId: 'paleto', admissionId: 21 } });
        env.win.PFApps.handleMessage({ action: 'pfapp:event', app: 'hospital', event: 'changed', payload: { hospitalId: 'paleto', admissionId: 22 } });
        await wait(450); await settle();
        eq(env.rpc('board').length, n + 1, 'two pushes, one reload');
        noXss(env);
    });

    await it('the module never writes raw HTML and the stylesheet keeps to Chromium 103 and the shared tokens', async () => {
        ok(!/innerHTML\s*=(?!\s*'')/.test(MODULE) && !/\bhtml:/.test(MODULE) && !/insertAdjacentHTML/.test(MODULE), 'no raw HTML sinks');
        ok(!/localStorage|ctx\.storage/.test(MODULE), 'no browser storage');
        const code = CSS.replace(/\/\*[\s\S]*?\*\//g, '');
        ok(!/:has\(|color-mix\(|@container|@layer/.test(code), 'no CSS Chromium 103 lacks');
        ok(!/--pf-(bg|fg|line|ok|warn|bad|radius)[\w-]*\s*:/.test(code), 'no shared token declared here');
        ok(code.split('}').filter((r) => r.trim()).every((r) => r.split('{')[0].split(',').every((sel) => /\.hosp-app/.test(sel))), 'every selector scoped to .hosp-app');
    });

    console.log(`${passed} passed, ${failed} failed`);
    if (failures.length) { failures.forEach((f) => console.log('  - ' + f)); process.exit(1); }
})();
