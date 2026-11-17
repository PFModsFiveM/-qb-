// Batch 21 unit 21G: the Department app (pf-government html/apps/department.js) on the pf-devices
// runtime in jsdom, against the 20E handlers (server/apps/department.lua) as stubs:
//  * every server string renders as text (an <img onerror> payload never becomes an element);
//  * navigation follows the server's answer (overview.can): a plain employee gets no roster,
//    purchasing, budget or payroll, a manager with budget rights gets all of them;
//  * loading / error / empty states, server error messages shown in the form;
//  * each action calls its handler with the right payload and a request key; an unclear answer
//    resends under the same key, a clear one gets a new key;
//  * the armory rules: armory equipment is never offered a return here, a manager may only report
//    it lost, lost armory equipment with its holder is written off, not "found";
//  * the shared status/triage/vitals tokens are declared in pf-devices runtime.css only.
// Run: node js/b21_department_app_spec.js
const fs = require('fs');
const path = require('path');
const { JSDOM } = require('jsdom');

const PF = path.resolve(__dirname, '..', '..', '..', '[pfscripts]');
const QB = path.resolve(__dirname, '..', '..');
const RUNTIME = fs.readFileSync(path.join(PF, 'pf-devices/html/runtime.js'), 'utf8');
const RUNTIME_CSS = fs.readFileSync(path.join(PF, 'pf-devices/html/runtime.css'), 'utf8');
const TOKENS_CSS = fs.readFileSync(path.join(QB, 'pfm-ui/html/tokens.css'), 'utf8');
const MODULE = fs.readFileSync(path.join(PF, 'pf-government/html/apps/department.js'), 'utf8');
const MANIFEST = fs.readFileSync(path.join(PF, 'pf-government/fxmanifest.lua'), 'utf8');

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

const EVIL = '"><img src=x onerror="window.__xss=1"><b id=pwn>x</b>';
const now = Math.floor(Date.now() / 1000);
const APPS = [{ id: 'department', name: 'Department', icon: '', kind: 'module', entry: 'https://cfx-nui-pf-government/html/apps/department.js', styles: [] }];
const KEY_RE = /^[A-Za-z0-9_-]{8,64}$/;

const KINDS = [{ id: 'radar', label: 'Radar unit', selfIssue: false }, { id: 'baton', label: EVIL, selfIssue: true }];
function managerOverview(extra) {
    return Object.assign({
        ok: true,
        me: { cid: 'MGR1', dept: 'police', job: 'police', grade: 4, onDuty: true, manager: true, boss: false },
        dept: { id: 'police', label: EVIL, onDuty: 3, assets: { in_stock: 2, issued: 1, lost: 1 } },
        can: { manage: true, payroll: true, budget: true },
        quals: [{ qual: 'fto', label: EVIL, dept: 'police', has: true, source: 'granted', grantedBy: EVIL, expiresAt: now + 86400 }],
        myAssets: [{ serial: 'PD-RDR-AAA111', kind: 'radar', label: EVIL, state: 'issued', holder: 'MGR1', issuedAt: now }],
        shift: { id: 1, seconds: 3700, startedAt: now - 3700 },
        courses: [{ id: 'firearms', label: 'Firearms', grants: 'firearms', grantsLabel: EVIL }],
        assetKinds: KINDS,
        qualifications: [{ id: 'fto', label: 'Field training officer' }, { id: 'k9', label: EVIL }],
    }, extra || {});
}
function officerOverview(extra) {
    return Object.assign(managerOverview(), {
        me: { cid: 'OFF1', dept: 'police', job: 'police', grade: 1, onDuty: true, manager: false },
        dept: { id: 'police', label: 'Police', onDuty: 3 },
        can: { manage: false, payroll: false, budget: false },
        quals: [],
        courses: [{ id: 'firearms', label: 'Firearms', instructorQual: 'fto' }],
    }, extra || {});
}

const ROSTER = [
    { cid: 'MGR1', name: 'Manager One', job: 'police', grade: 4, gradeName: 'Lieutenant', online: true, onDuty: true, assets: 1, me: true },
    { cid: 'OFF1', name: EVIL, job: 'police', grade: 1, gradeName: EVIL, online: false, onDuty: false, assets: 0 },
];

function makeWindow(handlers) {
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
            result = fn === undefined ? { ok: false, error: 'unknown_method' } : typeof fn === 'function' ? fn(body.payload) : fn;
            if (result === '__throw__') throw new Error('network');
        }
        return { json: async () => result };
    };
    const origAppend = win.document.head.appendChild.bind(win.document.head);
    win.document.head.appendChild = (el) => { const r = origAppend(el); if (el.tagName === 'SCRIPT') setTimeout(() => el.onload && el.onload(), 0); return r; };
    win.jQuery = function () {};
    // the runtime logs a failed request (the lost-answer test throws one on purpose)
    const logError = win.console.error.bind(win.console);
    win.console.error = (...a) => { if (!/request failed/.test(String(a[0]))) logError(...a); };
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
    return { win, rpcs, notes };
}

async function open(handlers) {
    const env = makeWindow(handlers);
    await env.win.PFApps.refresh();
    await env.win.PFApps.open('department');
    await settle();
    const root = env.win.document.querySelector('[data-window] .dept-app');
    ok(root, 'the department app mounted');
    env.root = root;
    env.navIds = () => [...root.querySelectorAll('.dept-nav button')].map((b) => b.dataset.section);
    env.go = async (id) => { const b = root.querySelector(`.dept-nav button[data-section="${id}"]`); ok(b, `nav ${id}`); b.click(); await settle(); };
    env.buttons = (label) => [...root.querySelectorAll('button')].filter((b) => b.textContent === label);
    env.click = async (label, index) => { const b = env.buttons(label)[index || 0]; ok(b, `button "${label}"`); b.click(); await settle(); };
    env.calls = (method) => env.rpcs.filter((r) => r.method === method);
    env.last = (method) => { const c = env.calls(method); ok(c.length, `${method} was called`); return c[c.length - 1].payload; };
    env.view = () => root.querySelector('.dept-view');
    return env;
}

function clean(env, where) {
    eq(env.root.querySelectorAll('img, #pwn, [onerror]').length, 0, `${where}: a payload became an element`);
    eq(env.win.__xss, undefined, `${where}: script ran`);
}
function setInput(el, value) {
    el.value = value;
    el.dispatchEvent(new el.ownerDocument.defaultView.Event('input', { bubbles: true }));
}
const fieldInput = (env, label) => {
    const f = [...env.view().querySelectorAll('.pf-field')].find((x) => x.querySelector('label') && x.querySelector('label').textContent === label);
    ok(f, `field ${label}`);
    return f.querySelector('input, select');
};

const baseHandlers = (extra) => Object.assign({
    overview: managerOverview(),
    roster: { ok: true, list: ROSTER, dept: 'police' },
    shifts: { ok: true, list: [] },
    training: { ok: true, list: [] },
    assets: { ok: true, list: [] },
}, extra || {});

(async () => {
    await it('runtime.css declares the shared status, triage and vitals tokens with pfm-ui fallbacks', async () => {
        const rootBlock = RUNTIME_CSS.slice(RUNTIME_CSS.indexOf('\n:root {'), RUNTIME_CSS.indexOf('}', RUNTIME_CSS.indexOf('\n:root {')));
        for (const n of ['ok', 'active', 'pending', 'warn', 'bad', 'off', 'info']) {
            ok(new RegExp(`--pf-status-${n}:`).test(rootBlock), `--pf-status-${n} on :root`);
            ok(new RegExp(`--pf-status-${n}-bg:`).test(rootBlock), `--pf-status-${n}-bg on :root`);
        }
        for (const n of ['red', 'orange', 'yellow', 'green', 'blue', 'black']) {
            for (const s of ['', '-ink', '-bg']) ok(new RegExp(`--pf-triage-${n}${s}:`).test(rootBlock), `--pf-triage-${n}${s} on :root`);
        }
        for (const n of ['normal', 'warn', 'critical']) {
            ok(new RegExp(`--pf-vital-${n}:`).test(rootBlock), `--pf-vital-${n} on :root`);
            ok(new RegExp(`--pf-vital-${n}-bg:`).test(rootBlock), `--pf-vital-${n}-bg on :root`);
        }
        // mapped onto the pfm-ui tokens, with a fallback for a shell without pfm-ui
        ok(/--pf-status-ok:\s*var\(--pf-success,\s*#4ade80\)/.test(rootBlock), 'status ok follows --pf-success');
        ok(/--pf-status-bad:\s*var\(--pf-error,\s*#f87171\)/.test(rootBlock), 'status bad follows --pf-error');
        ok(/--pf-vital-critical:\s*var\(--pf-error,/.test(rootBlock), 'vital critical follows --pf-error');
        ok(/--pf-triage-yellow-ink:\s*var\(--pf-ink,/.test(rootBlock), 'triage yellow ink follows --pf-ink');
        // one owner: pfm-ui's tokens.css does not declare them, and nothing Chromium 103 lacks is used
        ok(!/--pf-(status|triage|vital)-/.test(TOKENS_CSS), 'tokens.css stays free of the runtime tokens');
        ok(!/:has\(|color-mix\(|@layer|@container/.test(RUNTIME_CSS.replace(/\/\*[\s\S]*?\*\//g, '')), 'no CSS Chromium 103 lacks');
    });

    await it('the module ships in the manifest files and reads the tokens with fallbacks', async () => {
        ok(/'html\/apps\/department\.js'/.test(MANIFEST), 'fxmanifest files lists html/apps/department.js');
        ok(/var\(--pf-status-ok, #4ade80\)/.test(MODULE) && /var\(--pf-status-bad, #f87171\)/.test(MODULE), 'badge tones read the status tokens with fallbacks');
        ok(!/innerHTML\s*=\s*[^'"\s]/.test(MODULE.replace(/innerHTML = ''/g, '')), 'innerHTML is only ever cleared');
    });

    await it('a manager gets every section; server strings stay text on the overview', async () => {
        const env = await open(baseHandlers());
        eq(env.navIds().join(','), 'overview,roster,shifts,training,assets,purchasing,budget,payroll');
        ok(env.root.textContent.includes(EVIL), 'the payload is shown as text');
        ok(env.root.textContent.includes('Lost: 1'), 'asset counts per state');
        ok(env.root.textContent.includes('1h 1m'), 'the open shift length');
        clean(env, 'overview');
    });

    await it('a plain employee gets no roster, purchasing, budget or payroll', async () => {
        const env = await open(baseHandlers({ overview: officerOverview() }));
        eq(env.navIds().join(','), 'overview,shifts,training,assets');
        ok(env.root.textContent.includes('You hold no qualifications yet.'), 'empty qualifications state');
        // no record-training form without the course's instructor qualification
        await env.go('training');
        eq(env.buttons('Record').length, 0, 'no record form');
        ok(env.view().textContent.includes('No training records.'), 'empty training state');
        eq(env.last('training').cid, undefined, 'the server picks the employee\'s own records');
    });

    await it('an employee holding the instructor qualification may record training', async () => {
        const env = await open(baseHandlers({
            overview: officerOverview({ quals: [{ qual: 'fto', label: 'FTO', dept: 'police', has: true, source: 'granted' }] }),
            recordTraining: { ok: true, id: 9, granted: true, qual: 'firearms' },
        }));
        await env.go('training');
        setInput(fieldInput(env, 'Trainee').parentNode.querySelector('input'), 'TRN1');
        fieldInput(env, 'Result').value = 'pass';
        setInput(fieldInput(env, 'Score'), '87');
        setInput(fieldInput(env, 'Note'), 'qualified on range 2');
        await env.click('Record');
        const p = env.last('recordTraining');
        eq(p.cid, 'TRN1'); eq(p.course, 'firearms'); eq(p.result, 'pass'); eq(p.score, 87); eq(p.note, 'qualified on range 2');
        ok(KEY_RE.test(p.key), 'a request key');
        ok(env.notes.some((n) => /qualification granted/.test(n.m)), 'the grant is reported');
    });

    await it('overview failure shows the server message and retries', async () => {
        let n = 0;
        const env = await open(baseHandlers({ overview: () => (++n === 1 ? { ok: false, error: 'no_permission', message: 'You do not work for a department.' } : managerOverview()) }));
        ok(env.view().textContent.includes('You do not work for a department.'), 'the server message');
        eq(env.navIds().length, 0, 'no navigation without the server answer');
        await env.click('Try again');
        eq(env.navIds()[0], 'overview');
    });

    await it('roster: names are text, filter works, errors and empty states show', async () => {
        const env = await open(baseHandlers());
        await env.go('roster');
        clean(env, 'roster');
        eq(env.view().querySelectorAll('tbody tr').length, 2);
        setInput(env.view().querySelector('input[type="search"]'), 'manager');
        eq(env.view().querySelectorAll('tbody tr').length, 1, 'filtered');
        setInput(env.view().querySelector('input[type="search"]'), 'zzz');
        ok(env.view().textContent.includes('Nobody matches that filter.'));

        const bad = await open(baseHandlers({ roster: { ok: false, error: 'db_unavailable' } }));
        await bad.go('roster');
        ok(bad.view().textContent.includes('Department records are unavailable right now.'), 'mapped error code');
        ok(bad.buttons('Try again').length === 1, 'retry offered');
    });

    await it('member: grant and revoke send the qualification, expiry and reason with a key; Escape goes back', async () => {
        const member = {
            ok: true, member: { cid: 'OFF1', job: 'police', grade: 1, dept: 'police', online: true, onDuty: false },
            quals: [{ qual: 'fto', label: 'FTO', dept: 'police', has: true, source: 'granted', grantedBy: 'MGR1' }],
            training: [{ id: 3, cid: 'OFF1', course: 'firearms', courseLabel: EVIL, result: 'fail', note: EVIL, at: now }],
            assets: [{ serial: 'PD-BAT-1', kind: 'baton', label: EVIL, state: 'issued', holder: 'OFF1', updatedAt: now }],
            shifts: [{ id: 5, cid: 'OFF1', job: 'police', grade: 1, startedAt: now - 600, seconds: 600, endReason: EVIL }],
        };
        const env = await open(baseHandlers({
            member, grantQual: { ok: false, error: 'no_permission', message: 'You can only change qualifications of lower ranks.' },
            revokeQual: { ok: true, qual: 'fto', state: 'revoked' }, issueAsset: { ok: true, asset: { serial: 'PD-RDR-9' } },
        }));
        await env.go('roster');
        await env.click('Open', 1);
        eq(env.last('member').cid, 'OFF1');
        clean(env, 'member');
        // grant: the held qualification is not offered again
        const sel = fieldInput(env, 'Grant');
        eq([...sel.options].map((o) => o.value).join(','), 'k9');
        setInput(fieldInput(env, 'Valid until (optional)'), '2099-01-31');
        setInput(fieldInput(env, 'Reason'), 'K9 handler course');
        await env.click('Grant');
        const g = env.last('grantQual');
        eq(g.cid, 'OFF1'); eq(g.qual, 'k9'); eq(g.reason, 'K9 handler course');
        eq(g.expiresAt, Math.floor(new Date(2099, 1, 1).getTime() / 1000), 'valid to the end of the chosen day');
        ok(KEY_RE.test(g.key));
        ok(env.view().textContent.includes('You can only change qualifications of lower ranks.'), 'the server message in the form');
        // a clear refusal: the next attempt is a new request
        await env.click('Grant');
        ok(env.last('grantQual').key !== g.key, 'a new key after a clear failure');

        await env.click('Revoke');
        const r = env.last('revokeQual');
        eq(r.cid, 'OFF1'); eq(r.qual, 'fto'); ok(KEY_RE.test(r.key));

        setInput(fieldInput(env, 'Issue equipment'), 'PD-RDR-9');
        await env.click('Issue to this person');
        const i = env.last('issueAsset');
        eq(i.serial, 'PD-RDR-9'); eq(i.cid, 'OFF1'); ok(KEY_RE.test(i.key));

        env.root.dispatchEvent(new env.win.KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
        await settle();
        ok(env.view().querySelector('input[type="search"]'), 'back on the roster');
    });

    await it('a manager sees no grant or revoke on their own record', async () => {
        const env = await open(baseHandlers({
            member: { ok: true, member: { cid: 'MGR1', job: 'police', grade: 4, dept: 'police', online: true, onDuty: true },
                quals: [{ qual: 'fto', label: 'FTO', dept: 'police', has: true, source: 'granted' }], training: [], assets: [], shifts: [] },
        }));
        await env.go('roster');
        await env.click('Open', 0);
        eq(env.buttons('Revoke').length, 0);
        eq(env.buttons('Grant').length, 0);
    });

    await it('shifts: manager filter and server paging with the cursor', async () => {
        const page1 = Array.from({ length: 2 }, (_, i) => ({ id: 10 - i, cid: 'OFF1', job: 'police', grade: 1, startedAt: now - 7200, endedAt: now - 3600, seconds: 3600, endReason: 'duty_off' }));
        const env = await open(baseHandlers({
            shifts: (p) => (p.beforeId ? { ok: true, list: [{ id: 3, cid: 'OFF1', job: 'police', grade: 1, startedAt: now - 60, seconds: 60 }] } : { ok: true, list: page1, nextCursor: 9 }),
        }));
        await env.go('shifts');
        eq(env.view().querySelectorAll('tbody tr').length, 2);
        ok(env.view().textContent.includes(EVIL), 'roster names on the shifts (as text)');
        clean(env, 'shifts');
        await env.click('Load more');
        eq(env.last('shifts').beforeId, 9);
        eq(env.view().querySelectorAll('tbody tr').length, 3);
        ok(env.view().textContent.includes('Open'), 'an open shift is marked');
        setInput(fieldInput(env, 'Employee').parentNode.querySelector('input'), 'OFF1');
        env.view().querySelector('input[type="checkbox"]').checked = true;
        await env.click('Apply');
        const p = env.last('shifts');
        eq(p.cid, 'OFF1'); eq(p.open, true); eq(p.beforeId, undefined);
    });

    await it('equipment: register, filter, issue from stock, return non-armory, history as text', async () => {
        const assets = [
            { id: 3, serial: 'PD-RDR-AAA111', kind: 'radar', label: EVIL, state: 'in_stock', location: EVIL, updatedAt: now },
            { id: 2, serial: 'PD-BAT-BBB222', kind: 'baton', label: 'Baton', state: 'issued', holder: 'OFF1', ref: null, updatedAt: now },
        ];
        const byserial = Object.fromEntries(assets.map((a) => [a.serial, a]));
        const env = await open(baseHandlers({
            assets: { ok: true, list: assets },
            assetHistory: (p) => ({ ok: true, asset: byserial[p.serial], list: [{ id: 1, event: 'register', from: null, to: 'in_stock', actor: 'MGR1', note: EVIL, at: now }] }),
            registerAsset: { ok: true, asset: { serial: 'PD-RDR-NEW001' } },
            issueAsset: { ok: true, asset: { serial: 'PD-RDR-AAA111' } },
            returnAsset: { ok: true, asset: { serial: 'PD-BAT-BBB222' } },
            assetAction: { ok: true },
        }));
        await env.go('assets');
        clean(env, 'asset list');
        eq(env.view().querySelectorAll('tbody tr').length, 2);

        fieldInput(env, 'State').value = 'issued';
        fieldInput(env, 'Kind').value = 'baton';
        setInput(fieldInput(env, 'Holder').parentNode.querySelector('input'), 'OFF1');
        await env.click('Apply');
        const f = env.last('assets');
        eq(f.state, 'issued'); eq(f.kind, 'baton'); eq(f.holder, 'OFF1');

        await env.click('Register equipment');
        fieldInput(env, 'Kind');
        const kindSel = [...env.view().querySelectorAll('.pf-card .pf-field')].find((x) => x.querySelector('label').textContent === 'Kind').querySelector('select');
        kindSel.value = 'radar';
        const card = env.view().querySelector('.pf-card');
        const inputOf = (label) => [...card.querySelectorAll('.pf-field')].find((x) => x.querySelector('label').textContent === label).querySelector('input');
        setInput(inputOf('Label'), 'Radar 4');
        setInput(inputOf('Location'), 'MRPD armory');
        setInput(inputOf('Cost'), '1200');
        await env.click('Register');
        const reg = env.last('registerAsset');
        eq(reg.kind, 'radar'); eq(reg.label, 'Radar 4'); eq(reg.location, 'MRPD armory'); eq(reg.cost, 1200); eq(reg.serial, undefined);
        ok(KEY_RE.test(reg.key));

        // in stock: issue to a typed citizen, and the manager moves
        await env.click('Open', 0);
        eq(env.last('assetHistory').serial, 'PD-RDR-AAA111');
        clean(env, 'asset detail');
        ok(env.buttons('Send to maintenance').length && env.buttons('Retire').length, 'manager actions on stock');
        setInput(fieldInput(env, 'Issue to').parentNode.querySelector('input'), 'OFF1');
        setInput(fieldInput(env, 'Note'), 'patrol');
        await env.click('Issue');
        const iss = env.last('issueAsset');
        eq(iss.serial, 'PD-RDR-AAA111'); eq(iss.cid, 'OFF1'); eq(iss.note, 'patrol'); ok(KEY_RE.test(iss.key));
        await env.click('Retire');
        const mv = env.last('assetAction');
        eq(mv.action, 'retire'); eq(mv.serial, 'PD-RDR-AAA111');

        // issued, not armory: return to stock / maintenance / lost
        env.root.dispatchEvent(new env.win.KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
        await settle();
        await env.click('Open', 1);
        ok(env.buttons('Return to stock').length === 1 && env.buttons('Return for maintenance').length === 1, 'return choices');
        await env.click('Return for maintenance');
        const ret = env.last('returnAsset');
        eq(ret.serial, 'PD-BAT-BBB222'); eq(ret.to, 'maintenance'); ok(KEY_RE.test(ret.key));
    });

    await it('armory rules: no return of armory equipment here; a manager reports it lost; lost armory gear is written off', async () => {
        const issued = { id: 1, serial: 'PD-PST-ARM001', kind: 'radar', label: 'Pistol', state: 'issued', holder: 'OFF1', ref: 'armory', updatedAt: now };
        const lost = { id: 2, serial: 'PD-PST-ARM002', kind: 'radar', label: 'Pistol', state: 'lost', holder: 'OFF1', ref: 'armory', updatedAt: now };
        const plainLost = { id: 3, serial: 'PD-RDR-LST003', kind: 'radar', label: 'Radar', state: 'lost', updatedAt: now };
        const all = { [issued.serial]: issued, [lost.serial]: lost, [plainLost.serial]: plainLost };
        const env = await open(baseHandlers({
            assets: { ok: true, list: [issued, lost, plainLost] },
            assetHistory: (p) => ({ ok: true, asset: all[p.serial], list: [] }),
            returnAsset: { ok: true }, assetAction: { ok: true },
        }));
        await env.go('assets');
        await env.click('Open', 0);
        eq(env.buttons('Return to stock').length, 0, 'no return to stock for armory equipment');
        eq(env.buttons('Return for maintenance').length, 0);
        ok(env.view().textContent.includes('returned at the armory'), 'the armory hint');
        await env.click('Report lost');
        const r = env.last('returnAsset');
        eq(r.to, 'lost'); eq(r.serial, issued.serial);

        await env.go('assets');
        await env.click('Open', 1);
        eq(env.buttons('Found').length, 0, 'lost armory equipment with its holder is not found here');
        await env.click('Write off');
        eq(env.last('assetAction').action, 'retire');

        await env.go('assets');
        await env.click('Open', 2);
        await env.click('Found');
        eq(env.last('assetAction').action, 'found');

        // the holder (not a manager) of armory equipment gets no actions at all
        const holder = await open(baseHandlers({
            overview: officerOverview({ me: { cid: 'OFF1', dept: 'police', job: 'police', grade: 1, onDuty: true, manager: false } }),
            assets: { ok: true, list: [issued] },
            assetHistory: { ok: true, asset: issued, list: [] },
        }));
        await holder.go('assets');
        await holder.click('Open', 0);
        eq(holder.buttons('Report lost').length, 0);
        eq(holder.buttons('Return to stock').length, 0);
    });

    await it('an employee checks out self-issue equipment by serial to themselves', async () => {
        const env = await open(baseHandlers({ overview: officerOverview(), issueAsset: { ok: true, asset: { serial: 'PD-BAT-1' } } }));
        await env.go('assets');
        clean(env, 'self check-out');
        setInput(fieldInput(env, 'Serial'), 'PD-BAT-1');
        await env.click('Check out to me');
        const p = env.last('issueAsset');
        eq(p.serial, 'PD-BAT-1'); eq(p.cid, 'OFF1'); ok(KEY_RE.test(p.key));
        eq(env.buttons('Register equipment').length, 0, 'no register form for an employee');
    });

    await it('purchasing: the cart goes to placeProcurement; an unclear answer keeps the key; cancel sends the id', async () => {
        let answer = { ok: false, error: 'payment_pending', message: 'The bank has not confirmed the payment yet. Nothing more will be charged; check back shortly.' };
        const env = await open(baseHandlers({
            procurementCatalog: { ok: true, dept: 'police', mayOrder: true, facilities: [
                { buyerId: 'police:mrpd', label: EVIL, items: [{ name: 'bandage', price: 60, caseSize: 10 }, { name: 'zipties', price: 40, caseSize: 10 }] }] },
            procurements: { ok: true, list: [
                { id: 7, buyer: 'police:mrpd', order: 41, items: { cart: 'x', lines: [{ name: 'bandage', label: EVIL, quantity: 2 }] }, total: 130, state: 'paid', by: 'MGR1', note: EVIL, at: now },
                { id: 6, buyer: 'police:mrpd', items: { cart: 'x' }, total: 0, state: 'payment_pending', by: 'MGR1', at: now }] },
            placeProcurement: () => answer,
            cancelProcurement: { ok: true, procurement: { id: 7, state: 'cancelled' } },
        }));
        await env.go('purchasing');
        clean(env, 'purchasing');
        const qty = env.view().querySelectorAll('input.dept-qty');
        eq(qty.length, 2);
        setInput(qty[0], '3');
        ok(env.view().textContent.includes('$180'), 'catalog subtotal');
        await env.click('Place order');
        const p1 = env.last('placeProcurement');
        eq(p1.buyerId, 'police:mrpd');
        eq(JSON.stringify(p1.cart), JSON.stringify([{ name: 'bandage', quantity: 3 }]));
        ok(KEY_RE.test(p1.key));
        ok(env.view().textContent.includes('Nothing more will be charged'), 'the unclear answer is shown, not a failure');
        // the same order again reads the first one back under the same key
        answer = { ok: true, duplicate: true, procurement: { id: 8, state: 'paid', total: 230 } };
        await env.click('Place order');
        eq(env.last('placeProcurement').key, p1.key, 'same key after an unclear answer');
        ok(env.notes.some((n) => /already placed/.test(n.m)), 'the duplicate is reported');
        // only a paid order can be cancelled
        eq(env.buttons('Cancel').length, 1);
        await env.click('Cancel');
        eq(env.last('cancelProcurement').id, 7);
        // a different cart is a new intent: a new key
        setInput(env.view().querySelectorAll('input.dept-qty')[1], '1');
        answer = { ok: false, error: 'insufficient_funds', message: 'The department account cannot cover this order.' };
        await env.click('Place order');
        const p3 = env.last('placeProcurement');
        ok(p3.key !== p1.key, 'new key for a new order');
        await env.click('Place order');
        ok(env.last('placeProcurement').key !== p3.key, 'a clear refusal is not resent under its key');
    });

    await it('purchasing without order rights: the button is disabled and cancel is not offered', async () => {
        const env = await open(baseHandlers({
            procurementCatalog: { ok: true, dept: 'police', mayOrder: false, facilities: [{ buyerId: 'police:mrpd', label: 'MRPD', items: [] }] },
            procurements: { ok: true, list: [{ id: 7, buyer: 'police:mrpd', total: 1, state: 'paid', at: now }] },
        }));
        await env.go('purchasing');
        ok(env.buttons('Place order')[0].disabled, 'place disabled');
        eq(env.buttons('Cancel').length, 0);
        ok(env.view().textContent.includes('This facility has nothing to order.'));
    });

    await it('a lost answer (network error) keeps the key for the resend', async () => {
        let n = 0;
        const env = await open(baseHandlers({
            member: { ok: true, member: { cid: 'OFF1', job: 'police', grade: 1, dept: 'police' }, quals: [], training: [], assets: [], shifts: [] },
            grantQual: () => (++n === 1 ? '__throw__' : { ok: true }),
        }));
        await env.go('roster');
        await env.click('Open', 1);
        await env.click('Grant');
        const k1 = env.last('grantQual').key;
        ok(env.view().textContent.includes('may still have gone through'), 'unclear, not failed');
        await env.click('Grant');
        eq(env.last('grantQual').key, k1, 'resent under the same key');
    });

    await it('budget: snapshot and transactions as text; empty and error states', async () => {
        const env = await open(baseHandlers({
            budget: { ok: true, dept: 'police', snapshot: { budget: 50000, balance: 12000, spent: 3000, recommended: 60000, minimum: 40000, salaries: 30000, status: EVIL, month: '2026-11', society: 'police' },
                recent: [{ id: 1, type: 'society_spend', category: EVIL, amount: 500, after: 11500, by: EVIL, reason: EVIL, state: 'pending', at: now }] },
        }));
        await env.go('budget');
        clean(env, 'budget');
        ok(env.view().textContent.includes('$50,000'), 'budget shown');
        ok(env.view().textContent.includes('Pending'), 'pending moves marked');
        const empty = await open(baseHandlers({ budget: { ok: true, dept: 'police', recent: [] } }));
        await empty.go('budget');
        ok(empty.view().textContent.includes('No budget is set for this department.'));
        ok(empty.view().textContent.includes('No transactions yet.'));
        const bad = await open(baseHandlers({ budget: { ok: false, error: 'no_permission', message: 'Only managers and budget officials see this.' } }));
        await bad.go('budget');
        ok(bad.view().textContent.includes('Only managers and budget officials see this.'));
    });

    await it('payroll: build sends the period, a closed report can be saved, saved reports open by id', async () => {
        const report = (partial) => ({ dept: 'police', label: EVIL, from: 1000, to: 2000, partial, truncated: false,
            totals: { employees: 1, wagesPaid: 900, wagesPending: 100, wagesFailed: 1, paychecks: 3, hours: 12.5, fromSociety: 900, fromState: 0, fundingIn: 0, spendOut: 0, adjustments: 0, pendingMoves: 0 },
            employees: [{ cid: 'OFF1', name: EVIL, jobs: ['police'], grade: 1, gradeName: EVIL, employed: true, wagesPaid: 900, wagesPending: 100, wagesFailed: 1, paychecks: 3, hours: 12.5, shifts: 4 }],
            budget: [{ type: 'treasury_funding', category: EVIL, count: 1, total: 5000 }] });
        let partial = true;
        const env = await open(baseHandlers({
            payroll: (q) => ({ ok: true, report: Object.assign(report(partial), { from: q.from, to: q.to }) }),
            savePayroll: { ok: true, saved: { id: 4 } },
            payrollReports: (p) => (p.id ? { ok: true, saved: { id: 4, report: report(false) } }
                : { ok: true, list: [{ id: 4, dept: 'police', from: 1000, to: 2000, employees: 1, wagesTotal: 900, wagesPending: 100, fundingTotal: 0, spendTotal: 0, by: 'MGR1', at: now }] }),
        }));
        await env.go('payroll');
        eq(env.calls('payrollReports').length, 1, 'saved reports listed');
        setInput(fieldInput(env, 'From (start of day)'), '2026-10-01');
        setInput(fieldInput(env, 'To (end of day)'), '2026-10-31');
        await env.click('Build report');
        const p = env.last('payroll');
        eq(p.from, Math.floor(new Date(2026, 9, 1).getTime() / 1000));
        eq(p.to, Math.floor(new Date(2026, 10, 1).getTime() / 1000), 'to the end of the last day');
        clean(env, 'payroll report');
        ok(env.view().textContent.includes('Period still running'), 'a running period is marked');
        ok(env.buttons('Save report')[0].hidden, 'a running period cannot be saved');
        partial = false;
        await env.click('Build report');
        ok(!env.buttons('Save report')[0].hidden, 'a closed period can be saved');
        await env.click('Save report');
        const s = env.last('savePayroll');
        eq(s.from, p.from); eq(s.to, p.to);
        await env.click('View');
        eq(env.last('payrollReports').id, 4);
        ok(env.view().textContent.includes('Saved report #4'));
        clean(env, 'saved report');
    });

    await it('keyboard: the section buttons are real buttons and arrow keys move between them', async () => {
        const env = await open(baseHandlers());
        const items = env.root.querySelectorAll('.dept-nav button');
        ok(items.length === 8 && [...items].every((b) => b.type === 'button'), 'focusable buttons');
        items[0].focus();
        items[0].dispatchEvent(new env.win.KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true }));
        eq(env.win.document.activeElement, items[1], 'focus moved down');
        eq(items[0].getAttribute('aria-current'), 'page');
    });

    console.log(`${passed} passed, ${failed} failed (department app)`);
    if (failures.length) { console.log(failures.join('\n\n')); process.exitCode = 1; }
})();
