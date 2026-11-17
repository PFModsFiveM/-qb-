// Batch 21 (21B): the police MDT custody, evidence chain, lab, telemetry, use-of-force and
// personnel pages (pf-policemdt-DEV html/pages/*.js), loaded for real in jsdom: index.html with
// every local script in page order (app.js and its PFMdtPages hook included), the MDT opened by
// the NUI 'open' message, the server reached through the pfMdtCall bridge (fetch is answered per
// endpoint name). Covers: registration and navigation, escaping of every server string (an
// <img onerror> payload stays text), role-gated actions from the server's permission answer,
// loading / empty / error states, and that each action calls the right endpoint with the right
// payload. The sentence clock is read-only; the timeline says "metadata, not video".
// Run: node js/b21_mdt_custody_pages_spec.js
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { JSDOM, VirtualConsole } = require('jsdom');

const ROOT = process.env.MDT_UI_ROOT || path.resolve(__dirname, '..', '..', '..', '[pfscripts]');
const DIR = 'pf-policemdt-DEV';

let passed = 0;
let failed = 0;
const failures = [];
async function it(name, fn) {
    try { await fn(); passed++; } catch (e) { failed++; failures.push(`${name}: ${e && e.stack || e}`); }
}
function eq(a, b, msg) { if (a !== b) throw new Error(`${msg || 'expected'}: ${JSON.stringify(b)}, got ${JSON.stringify(a)}`); }
function ok(v, msg) { if (!v) throw new Error(msg || 'expected truthy'); }
const tick = () => new Promise((r) => setTimeout(r, 0));
async function settle(n = 30) { for (let i = 0; i < n; i++) await tick(); }
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

const EVIL = '"><img src=x onerror="window.__xss=1"><b id=pwn>x</b></script>';
const FOREIGN_URL = 'https://evil.tld/track.png';
const GOOD_URL = 'https://cdn.discordapp.com/attachments/1/2/mug.png';

function leaflet() {
    const fn = function () {};
    const p = new Proxy(fn, {
        get(t, k) { if (k === Symbol.toPrimitive) return () => 0; if (k === 'then') return undefined; return p; },
        apply() { return p; }, construct() { return p; },
    });
    return p;
}

// The MDT page with every local script; `api` answers pfMdtCall by endpoint name.
function boot() {
    const base = path.join(ROOT, DIR, 'html');
    const html = fs.readFileSync(path.join(base, 'index.html'), 'utf8');
    const scripts = [...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/g)].map((m) => {
        const src = /\bsrc="([^"]+)"/.exec(m[1]);
        return src ? { file: src[1].split('?')[0] } : { inline: m[2] };
    }).filter((s) => s.inline !== undefined || !/^https?:/i.test(s.file));
    const vc = new VirtualConsole();
    const errors = [];
    vc.on('jsdomError', (e) => errors.push(String(e && e.message || e)));
    const dom = new JSDOM(html.replace(/<script\b[^>]*>[\s\S]*?<\/script>/g, ''), {
        url: `https://cfx-nui-${DIR.toLowerCase()}/html/index.html`, runScripts: 'outside-only', pretendToBeVisual: true, virtualConsole: vc,
    });
    const w = dom.window;
    w.L = leaflet();
    w.GetParentResourceName = () => DIR;
    const calls = [];
    const api = {};
    w.fetch = async (url, opts) => {
        const name = String(url).replace(/^https:\/\/[^/]+\//, '');
        const body = JSON.parse((opts && opts.body) || '{}');
        let result = {};
        if (name === 'pfMdtCall') {
            calls.push({ name: body.name, payload: body.payload });
            const r = api[body.name];
            result = typeof r === 'function' ? r(body.payload || {}) : (r === undefined ? { ok: false, error: 'not_mocked' } : r);
        }
        return { ok: true, status: 200, json: async () => result, text: async () => JSON.stringify(result) };
    };
    const ctx = dom.getInternalVMContext();
    for (const s of scripts) {
        const file = s.file && path.join(base, s.file);
        // pages of other units that are not written yet do not stop this spec
        if (file && !fs.existsSync(file)) continue;
        const code = s.inline !== undefined ? s.inline : fs.readFileSync(file, 'utf8');
        new vm.Script(code, { filename: s.file || 'inline' }).runInContext(ctx);
    }
    const run = (code) => new vm.Script(code).runInContext(ctx);
    const post = (data) => w.dispatchEvent(new w.MessageEvent('message', { data }));
    const toasts = [];
    w.mdtToast = (m, k) => toasts.push({ m: String(m), k });
    return { w, run, post, calls, api, toasts, errors };
}

async function open(mdt) {
    mdt.post({ action: 'open', calls: [], config: { localeData: {}, map: {} }, permissions: { allowed: true, isSupervisor: true, isOwner: false, actions: {} },
        user: { name: 'Officer Test', rank: 'Officer', rankLevel: 1, grade: 'Officer', callsign: '1-A' } });
    await settle();
    ok(mdt.run('typeof router !== "undefined" && !!router'), 'the MDT opened');
}

const ACCESS = (over) => ({ ok: true, success: true, cid: 'OFF1', grade: 1, onduty: true,
    can: Object.assign({ forceReports: true, forceReview: false, forceClose: false, iaIntake: true, iaManage: false, perfReview: false,
        viewPersonnel: false, custodyLog: true, evidenceHandle: true, labRelease: true, timelineOthers: false, labTech: false }, over || {}) });

function root(mdt) { return mdt.w.document.getElementById('pageContent') || mdt.w.document.body; }
function noInjection(mdt, where) {
    eq(mdt.w.document.querySelectorAll('img[src="x"], #pwn, [onerror]').length, 0, `${where}: a server string became an element`);
    eq(mdt.w.__xss, undefined, `${where}: script ran`);
}
function last(mdt, name) { for (let i = mdt.calls.length - 1; i >= 0; i--) if (mdt.calls[i].name === name) return mdt.calls[i]; return null; }
function count(mdt, name) { return mdt.calls.filter((c) => c.name === name).length; }
function byText(scope, sel, text) { return Array.from(scope.querySelectorAll(sel)).find((e) => e.textContent.trim() === text) || null; }
async function go(mdt, page, params) {
    mdt.calls.length = 0;
    if (params) mdt.run(`window.PFMdtPages.open(${JSON.stringify(page)}, ${JSON.stringify(params)})`);
    else mdt.run(`router.set(${JSON.stringify(page)})`);
    await settle();
}
async function submit(mdt, form) { form.dispatchEvent(new mdt.w.Event('submit', { cancelable: true, bubbles: true })); await settle(); }

(async () => {
    const mdt = boot();
    await open(mdt);
    const W = mdt.w;
    const doc = W.document;

    await it('registers the six pages with the hook and adds their nav items', async () => {
        for (const name of ['custody', 'evidencecoc', 'lab', 'timeline', 'uof', 'personnel']) {
            ok(mdt.run(`window.PFMdtPages.has(${JSON.stringify(name)})`), `${name} registered`);
            ok(mdt.run(`router.pages.has(${JSON.stringify(name)})`), `${name} routed`);
            ok(doc.querySelector(`.sidebar-nav .nav-item[data-page="${name}"]`), `${name} nav item`);
        }
        ok(doc.querySelector('.nav-section[data-nav-section="records"] .nav-item[data-page="custody"]'), 'custody under records');
        ok(doc.querySelector('.nav-section[data-nav-section="department"] .nav-item[data-page="uof"]'), 'uof under department');
    });

    // ── custody ──
    await it('custody: search results and the whole record are text; foreign mugshots are not loaded', async () => {
        mdt.api['pf_mdt:pages:access'] = ACCESS();
        mdt.api['pf_mdt:searchCitizens'] = { data: [{ citizenId: 'ABC123', name: EVIL }], total: 1 };
        mdt.api['pf_mdt:custody:get'] = (p) => ({ ok: true, success: true, cid: p.cid, at: 1700000000,
            custody: { id: 12, cid: p.cid, state: 'held', facility: EVIL, cellId: EVIL, since: 1700000000, reason: EVIL, charges: [{ label: EVIL, count: 2 }] },
            booking: { bookingNo: EVIL, mugshotUrl: FOREIGN_URL, marks: EVIL, notes: EVIL, at: 1700000000 },
            incarceration: { order: { id: 7, kind: 'jail', state: 'active', clock: 'online', requiredSeconds: 600, servedSeconds: 180 }, remainingSeconds: 420, facility: 'mrpd_holding' },
            orders: [{ id: 7, kind: EVIL, state: EVIL, requiredSeconds: 600, createdAt: 1700000000 }],
            bail: { id: 2, state: EVIL, amount: 500, payerName: EVIL } });
        await go(mdt, 'custody');
        const page = root(mdt).querySelector('.pfx-custody');
        ok(page, 'custody page drawn');
        page.querySelector('input[type="search"]').value = 'Ada';
        await submit(mdt, page.querySelector('form'));
        eq(last(mdt, 'pf_mdt:searchCitizens').payload.query, 'Ada');
        const result = page.querySelector('.pfx-result');
        ok(result && result.textContent.indexOf(EVIL) !== -1, 'name shown as text');
        noInjection(mdt, 'custody search');
        result.click();
        await settle();
        eq(last(mdt, 'pf_mdt:custody:get').payload.cid, 'ABC123');
        ok(page.textContent.indexOf('Custody #12') !== -1, 'custody card');
        ok(page.textContent.indexOf(EVIL) !== -1, 'fields shown as text');
        eq(page.querySelectorAll('img.pfx-mugshot').length, 0, 'a picture from another host is not loaded');
        noInjection(mdt, 'custody record');
    });

    await it('custody: the sentence clock shows the server\'s figure, read-only (no control changes it)', async () => {
        const page = root(mdt).querySelector('.pfx-custody');
        const clock = page.querySelector('[aria-label="Sentence clock"]');
        ok(clock, 'clock card');
        ok(clock.textContent.indexOf('7m 0s') !== -1, 'remaining from the server');
        ok(clock.textContent.indexOf('read-only') !== -1, 'labelled read-only');
        eq(clock.querySelectorAll('input, select, textarea').length, 0, 'no field edits the clock');
        const buttons = Array.from(clock.querySelectorAll('button')).map((b) => b.textContent);
        eq(JSON.stringify(buttons), JSON.stringify(['Read again']), 'only a re-read');
        eq(clock.querySelector('[role="progressbar"]').getAttribute('aria-valuenow'), '30');
        const before = count(mdt, 'pf_mdt:custody:get');
        byText(clock, 'button', 'Read again').click();
        await settle();
        eq(count(mdt, 'pf_mdt:custody:get'), before + 1, 'read again asks the server');
        ok(!mdt.calls.some((c) => /prison|EditSentence|Adjust/i.test(c.name)), 'nothing writes the order');
    });

    await it('custody: a log entry goes to pf_mdt:custody:log with the custody id; hidden without the right', async () => {
        mdt.api['pf_mdt:custody:log'] = { ok: true, logId: 5 };
        const page = root(mdt).querySelector('.pfx-custody');
        const card = page.querySelector('[aria-label="Custody log"]');
        card.querySelector('select').value = 'rights_read';
        card.querySelector('input').value = 'read at desk';
        await submit(mdt, card.querySelector('form'));
        const c = last(mdt, 'pf_mdt:custody:log');
        eq(c.payload.custodyId, 12);
        eq(c.payload.kind, 'rights_read');
        eq(c.payload.text, 'read at desk');
        // no rank: no form, a reason instead
        mdt.api['pf_mdt:pages:access'] = ACCESS({ custodyLog: false });
        await go(mdt, 'custody', { cid: 'ABC123' });
        const p2 = root(mdt).querySelector('.pfx-custody');
        eq(p2.querySelector('[aria-label="Custody log"] form'), null, 'no form');
        ok(p2.querySelector('[aria-label="Custody log"]').textContent.indexOf('rank') !== -1);
    });

    await it('custody: empty and error states; an allowed mugshot is shown', async () => {
        mdt.api['pf_mdt:pages:access'] = ACCESS();
        mdt.api['pf_mdt:custody:get'] = { ok: true, success: true, cid: 'NONE1', custody: null, orders: [] };
        await go(mdt, 'custody', { cid: 'NONE1' });
        ok(root(mdt).textContent.indexOf('No custody on record') !== -1, 'empty state');
        mdt.api['pf_mdt:custody:get'] = { ok: false, success: false, error: 'unavailable', message: 'Justice records are not available right now' };
        await go(mdt, 'custody', { cid: 'NONE1' });
        ok(root(mdt).querySelector('.pfp-state-error').textContent.indexOf('Justice records are not available') !== -1, 'server message');
        mdt.api['pf_mdt:custody:get'] = { ok: true, cid: 'A1', custody: { id: 3, state: 'booking' }, booking: { bookingNo: 'B-1', mugshotUrl: GOOD_URL } };
        await go(mdt, 'custody', { cid: 'A1' });
        eq(root(mdt).querySelector('img.pfx-mugshot').getAttribute('src'), GOOD_URL);
    });

    // ── evidence chain ──
    const ITEM = (id) => ({ id, tag: `EV-2026-${id}`, kind: 'casing', label: EVIL, state: 'stored', sealed: true, integrity: 68,
        holder: { kind: 'locker', ref: 'inv:' + EVIL }, collectedAt: 1700000000, attrs: { caliber: EVIL }, caseRefs: [{ type: 'case', id: '4' }] });

    await it('evidence: server-paged list with filters, "Load more" follows the cursor, rows are text', async () => {
        mdt.api['pf_mdt:pages:access'] = ACCESS();
        mdt.api['pf_mdt:evidence:list'] = (p) => (p.after ? { ok: true, list: [ITEM(1)], next: null } : { ok: true, list: [ITEM(3), ITEM(2)], next: 2 });
        await go(mdt, 'evidencecoc');
        const page = root(mdt).querySelector('.pfx-evidence');
        eq(page.querySelectorAll('tbody tr').length, 2);
        noInjection(mdt, 'evidence list');
        page.querySelector('input[type="number"]').value = '4';
        page.querySelectorAll('select')[0].value = 'casing';
        page.querySelector('input[type="checkbox"]').checked = true;
        await submit(mdt, page.querySelector('form'));
        const c = last(mdt, 'pf_mdt:evidence:list');
        eq(c.payload.caseId, '4');
        eq(c.payload.kind, 'casing');
        eq(c.payload.mine, true);
        byText(page, 'button', 'Load more').click();
        await settle();
        eq(last(mdt, 'pf_mdt:evidence:list').payload.after, 2);
        eq(page.querySelectorAll('tbody tr').length, 3, 'appended');
        ok(byText(page, 'button', 'Load more').hidden, 'no more pages');
    });

    await it('evidence: detail shows integrity flags and the chain as text; a hand-over posts lab/main', async () => {
        mdt.api['pf_mdt:evidence:get'] = { ok: true, item: ITEM(3), integrity: { score: 68, flags: ['gap', 'seal_broken'] },
            custody: [{ id: 1, event: 'collected', from: null, to: 'player:OFF1', actor: EVIL, note: EVIL, at: 1700000000 }], custodyTotal: 1, labs: [] };
        mdt.api['pf_mdt:evidence:transfer'] = { ok: true, evidenceId: 3 };
        const page = root(mdt).querySelector('.pfx-evidence');
        page.querySelector('tbody tr').click();
        await settle();
        eq(last(mdt, 'pf_mdt:evidence:get').payload.id, 3);
        const integ = page.querySelector('[aria-label="Integrity"]');
        ok(integ.textContent.indexOf('gap in the chain') !== -1 && integ.textContent.indexOf('68 / 100') !== -1, 'integrity');
        ok(page.querySelector('[aria-label="Chain of custody"]').textContent.indexOf(EVIL) !== -1, 'chain as text');
        noInjection(mdt, 'evidence detail');
        const hand = page.querySelector('[aria-label="Hand over"] form');
        hand.querySelectorAll('input')[1].value = 'to the lab';
        await submit(mdt, hand);
        const t = last(mdt, 'pf_mdt:evidence:transfer');
        eq(t.payload.id, 3);
        eq(t.payload.to.kind, 'lab');
        eq(t.payload.to.labId, 'main');
        eq(t.payload.note, 'to the lab');
        // the case link opens the case page with its id
        ok(byText(page, 'button', 'Case #4'), 'case link');
    });

    await it('evidence: no hand-over without the right or off duty; error state from the server', async () => {
        mdt.api['pf_mdt:pages:access'] = ACCESS({ evidenceHandle: false });
        await go(mdt, 'evidencecoc', { id: 3 });
        eq(root(mdt).querySelector('[aria-label="Hand over"] form'), null);
        mdt.api['pf_mdt:pages:access'] = Object.assign(ACCESS(), { onduty: false });
        await go(mdt, 'evidencecoc', { id: 3 });
        eq(root(mdt).querySelector('[aria-label="Hand over"] form'), null);
        mdt.api['pf_mdt:evidence:list'] = { ok: false, error: 'unavailable', message: 'Evidence and telemetry are not available right now' };
        await go(mdt, 'evidencecoc');
        ok(root(mdt).querySelector('.pfp-state-error').textContent.indexOf('not available') !== -1);
        mdt.api['pf_mdt:evidence:list'] = { ok: true, list: [] };
        await go(mdt, 'evidencecoc');
        ok(root(mdt).textContent.indexOf('No evidence matches') !== -1, 'empty state');
    });

    // ── lab ──
    await it('lab: the queue shows jobs; only a lab tech sees Release; release and tests post the right payloads', async () => {
        const queue = { ok: true, list: [Object.assign(ITEM(5), { kind: 'blood', state: 'at_lab',
            labs: [{ id: 40, test: 'dna', state: 'ready', requestedAt: 1700000000, eta: 1700001800, result: { summary: EVIL } },
                { id: 41, test: 'tox', state: 'queued', requestedAt: 1700000000, eta: 1700001800 }] })], next: null };
        mdt.api['pf_mdt:lab:queue'] = queue;
        mdt.api['pf_mdt:pages:access'] = ACCESS({ labTech: false });
        await go(mdt, 'lab');
        let page = root(mdt).querySelector('.pfx-lab');
        eq(last(mdt, 'pf_mdt:lab:queue').payload.state, '');
        eq(byText(page, 'button', 'Release'), null, 'no release button without the lab qualification');
        ok(page.textContent.indexOf(EVIL) !== -1, 'result summary as text');
        noInjection(mdt, 'lab');
        mdt.api['pf_mdt:pages:access'] = ACCESS({ labTech: true });
        mdt.api['pf_mdt:lab:release'] = { ok: true, jobId: 40 };
        mdt.api['pf_mdt:lab:submit'] = { ok: true, jobId: 9, eta: 1700001800 };
        await go(mdt, 'lab');
        page = root(mdt).querySelector('.pfx-lab');
        byText(page, 'button', 'Release').click();
        await settle();
        eq(last(mdt, 'pf_mdt:lab:release').payload.jobId, 40);
        // tests offered match what the lab takes for blood: DNA and toxicology
        const card = page.querySelector('section[data-id="5"]');
        const boxes = Array.from(card.querySelectorAll('form input[type="checkbox"]'));
        eq(JSON.stringify(boxes.map((b) => b.value)), JSON.stringify(['dna', 'tox']));
        boxes[0].checked = true;
        await submit(mdt, card.querySelector('form'));
        const s = last(mdt, 'pf_mdt:lab:submit');
        eq(s.payload.id, 5);
        eq(JSON.stringify(s.payload.tests), JSON.stringify(['dna']));
    });

    await it('lab: empty and error states', async () => {
        mdt.api['pf_mdt:lab:queue'] = { ok: true, list: [] };
        await go(mdt, 'lab');
        ok(root(mdt).textContent.indexOf('Nothing is at the lab') !== -1);
        mdt.api['pf_mdt:lab:queue'] = { ok: false, error: 'no_permission' };
        await go(mdt, 'lab');
        ok(root(mdt).querySelector('.pfp-state-error'), 'error block');
    });

    // ── telemetry ──
    await it('timeline: says "metadata, not video", reads the own window, rows as text, client reports marked', async () => {
        mdt.api['pf_mdt:pages:access'] = ACCESS();
        mdt.api['pf_mdt:timeline:get'] = (p) => ({ ok: true, officerCid: 'OFF1', from: p.from, to: p.to, note: EVIL, kindNote: 'metadata, not video',
            events: p.after ? [] : [{ id: 1, device: 'body', kind: 'taser', data: { target: EVIL }, coords: { x: 1.4, y: 2, z: 3 }, at: 1700000000 },
                { id: 2, device: 'body', kind: 'shot_reported', clientReported: true, data: { weapon: EVIL }, at: 1700000010 }], next: p.after ? null : 2 });
        await go(mdt, 'timeline');
        const page = root(mdt).querySelector('.pfx-timeline');
        ok(page.querySelector('.pfx-banner').textContent.indexOf('Metadata, not video') === 0, 'banner');
        ok(page.querySelector('input[aria-label="Officer citizen id"]').hidden, 'officer field hidden for non-supervisors');
        await submit(mdt, page.querySelector('form'));
        const c = last(mdt, 'pf_mdt:timeline:get');
        eq(c.payload.to - c.payload.from, 1800, '30 minutes');
        eq(c.payload.officerCid, undefined, 'own timeline');
        eq(page.querySelectorAll('tbody tr').length, 2);
        eq(page.querySelectorAll('tbody tr.pfx-client').length, 1, 'client report marked');
        noInjection(mdt, 'timeline');
        byText(page, 'button', 'Load more').click();
        await settle();
        eq(last(mdt, 'pf_mdt:timeline:get').payload.after, 2);
        // from the window to a use-of-force draft with the same window
        mdt.api['pf_mdt:force:list'] = { ok: true, list: [] };
        mdt.api['pf_mdt:force:draft'] = { ok: true, reportId: 77 };
        mdt.api['pf_mdt:force:get'] = { ok: true, report: { id: 77, kind: 'uof', officerCid: 'OFF1', state: 'draft', summary: null }, chain: [] };
        byText(page, 'button', 'Draft a use-of-force report from this window').click();
        await settle();
        const uof = root(mdt).querySelector('.pfx-uof');
        ok(uof, 'uof page opened');
        await submit(mdt, uof.querySelector('[aria-label="New report"] form'));
        const d = last(mdt, 'pf_mdt:force:draft');
        eq(d.payload.from, c.payload.from);
        eq(d.payload.to, c.payload.to);
        eq(d.payload.minutes, undefined);
    });

    await it('timeline: supervisors may name another officer; the server refusal is shown', async () => {
        mdt.api['pf_mdt:pages:access'] = ACCESS({ timelineOthers: true });
        mdt.api['pf_mdt:timeline:get'] = { ok: false, error: 'no_permission' };
        await go(mdt, 'timeline');
        const page = root(mdt).querySelector('.pfx-timeline');
        const who = page.querySelector('input[aria-label="Officer citizen id"]');
        ok(!who.hidden);
        who.value = 'SGT2';
        await submit(mdt, page.querySelector('form'));
        eq(last(mdt, 'pf_mdt:timeline:get').payload.officerCid, 'SGT2');
        ok(page.querySelector('.pfp-state-error'), 'refusal shown');
    });

    // ── use of force ──
    const REPORT = (over) => Object.assign({ id: 9, kind: 'uof', officerCid: 'OFF1', officerName: EVIL, subjectCid: 'CIV4', forceLevel: 3, state: 'draft',
        from: 1700000000, to: 1700000600, telemetry: 'ok', narrative: '', origin: 'auto',
        summary: { rows: 4, level: 3, subjects: [EVIL], weapons: [], plates: [], pursuit: { distance: 0 }, force: [{ at: 1700000100, kind: 'taser', level: 3, action: EVIL }],
            note: 'No video exists.' } }, over || {});

    await it('uof: list, detail as text, the narrative autosaves to the server, submit saves then submits', async () => {
        mdt.api['pf_mdt:pages:access'] = ACCESS();
        mdt.api['pf_mdt:force:list'] = { ok: true, list: [{ id: 9, kind: 'uof', officerCid: 'OFF1', officerName: EVIL, forceLevel: 3, state: 'draft', origin: 'auto', updatedAt: 1700000000 }] };
        mdt.api['pf_mdt:force:get'] = { ok: true, report: REPORT(), chain: [] };
        mdt.api['pf_mdt:force:update'] = { ok: true, reportId: 9 };
        mdt.api['pf_mdt:force:submit'] = { ok: true, reportId: 9, state: 'submitted' };
        await go(mdt, 'uof');
        const page = root(mdt).querySelector('.pfx-uof');
        eq(page.querySelectorAll('tbody tr').length, 1);
        noInjection(mdt, 'uof list');
        page.querySelector('tbody tr').click();
        await settle();
        ok(page.querySelector('[aria-label="Telemetry summary"]').textContent.indexOf('metadata, not video') !== -1, 'summary labelled');
        noInjection(mdt, 'uof detail');
        const area = page.querySelector('textarea[aria-label="Narrative"]');
        area.value = 'Subject resisted; taser deployed once after warnings.';
        area.dispatchEvent(new W.Event('input'));
        eq(count(mdt, 'pf_mdt:force:update'), 0, 'not on every key');
        await wait(2200);
        await settle();
        const u = last(mdt, 'pf_mdt:force:update');
        ok(u, 'autosaved');
        eq(u.payload.id, 9);
        eq(u.payload.narrative, area.value);
        byText(page, 'button', 'Submit for review').click();
        await settle();
        eq(last(mdt, 'pf_mdt:force:submit').payload.id, 9);
        const order = mdt.calls.map((c) => c.name).filter((n) => n === 'pf_mdt:force:update' || n === 'pf_mdt:force:submit');
        eq(order[order.length - 1], 'pf_mdt:force:submit');
        eq(order[order.length - 2], 'pf_mdt:force:update', 'saved right before submitting');
        // a refusal is shown from the server's message
        mdt.api['pf_mdt:force:submit'] = { ok: false, error: 'bad_args', message: 'Write the narrative first' };
        await go(mdt, 'uof', { id: 9 });
        byText(root(mdt), 'button', 'Submit for review').click();
        await settle();
        ok(mdt.toasts.some((t) => t.m === 'Write the narrative first'), 'server message toasted');
    });

    await it('uof: review buttons only for a supervisor who is not the officer; approve/return payloads', async () => {
        mdt.api['pf_mdt:force:get'] = { ok: true, report: REPORT({ state: 'submitted', officerCid: 'OFF7' }), chain: [{ step: 'submit', byName: EVIL, at: 1700000000 }] };
        mdt.api['pf_mdt:pages:access'] = ACCESS();
        await go(mdt, 'uof', { id: 9 });
        eq(byText(root(mdt), 'button', 'Approve'), null, 'no review right');
        mdt.api['pf_mdt:pages:access'] = ACCESS({ forceReview: true, viewPersonnel: true });
        mdt.api['pf_mdt:force:review'] = { ok: true, state: 'returned' };
        await go(mdt, 'uof', { id: 9 });
        const page = root(mdt);
        noInjection(mdt, 'uof chain');
        page.querySelector('textarea[aria-label="Review note"]').value = 'Add the warning given';
        byText(page, 'button', 'Return to the officer').click();
        await settle();
        const r = last(mdt, 'pf_mdt:force:review');
        eq(r.payload.id, 9);
        eq(r.payload.decision, 'return');
        eq(r.payload.note, 'Add the warning given');
        // a report about the viewer: no buttons even with the right
        mdt.api['pf_mdt:force:get'] = { ok: true, report: REPORT({ state: 'submitted', officerCid: 'OFF7', subjectCid: 'OFF1' }), chain: [] };
        await go(mdt, 'uof', { id: 9 });
        eq(byText(root(mdt), 'button', 'Approve'), null, 'never about yourself');
    });

    // ── personnel ──
    await it('personnel: tabs follow the permission answer; the IA tab needs iaManage', async () => {
        mdt.api['pf_mdt:pages:access'] = ACCESS();
        mdt.api['pf_mdt:officers:list'] = { success: true, officers: [{ citizenid: 'OFF7', name: EVIL }] };
        mdt.api['pf_mdt:reviews:list'] = { ok: true, list: [{ id: 1, period: '2026-10', reviewerName: EVIL, scores: { conduct: 4 }, notes: EVIL, at: 1700000000 }] };
        mdt.api['pf_mdt:personnel:qualifications'] = { ok: true, dept: 'police', list: [{ qual: 'k9', label: EVIL, has: true, source: 'granted' }] };
        await go(mdt, 'personnel');
        const page = root(mdt).querySelector('.pfx-personnel');
        const tabs = Array.from(page.querySelectorAll('[role="tab"]')).map((t) => t.textContent);
        eq(JSON.stringify(tabs), JSON.stringify(['My record', 'Take a complaint']));
        eq(count(mdt, 'pf_mdt:ia:list'), 0, 'IA never asked');
        eq(last(mdt, 'pf_mdt:reviews:list').payload.officerCid, undefined, 'own record');
        ok(page.textContent.indexOf(EVIL) !== -1);
        noInjection(mdt, 'personnel record');
    });

    await it('personnel: a walk-in complaint posts its fields with one nonce; a retry keeps the nonce', async () => {
        let n = 0;
        mdt.api['pf_mdt:ia:file'] = () => (++n === 1 ? { ok: false, error: 'timeout' } : { ok: true, complaintId: 31 });
        const page = root(mdt).querySelector('.pfx-personnel');
        byText(page, '[role="tab"]', 'Take a complaint').click();
        await settle();
        const form = page.querySelector('.pfx-tabbody form');
        form.querySelector('input[aria-label="Officer citizen id (if known)"]').value = 'OFF7';
        form.querySelector('select').value = 'force';
        form.querySelector('textarea').value = 'Pushed me to the ground without reason';
        await submit(mdt, form);
        const first = last(mdt, 'pf_mdt:ia:file').payload;
        eq(first.officerCid, 'OFF7');
        eq(first.category, 'force');
        ok(/^[\w-]+$/.test(first.nonce), 'nonce');
        await submit(mdt, form);
        eq(last(mdt, 'pf_mdt:ia:file').payload.nonce, first.nonce, 'the retry is the same complaint');
    });

    await it('personnel: IA staff list, open, assign and record a finding; strings stay text', async () => {
        mdt.api['pf_mdt:pages:access'] = ACCESS({ iaManage: true, viewPersonnel: true, perfReview: true });
        mdt.api['pf_mdt:ia:list'] = { ok: true, list: [{ id: 31, officerName: EVIL, category: 'force', channel: 'portal', state: 'investigating', createdAt: 1700000000 }] };
        mdt.api['pf_mdt:ia:get'] = { ok: true, complaint: { id: 31, officerName: EVIL, summary: EVIL, state: 'investigating', category: 'force', channel: 'portal' },
            events: [{ action: 'note', byCid: 'IA1', note: EVIL, at: 1700000000 }] };
        mdt.api['pf_mdt:ia:finding'] = { ok: true, state: 'sustained' };
        await go(mdt, 'personnel');
        const page = root(mdt).querySelector('.pfx-personnel');
        byText(page, '[role="tab"]', 'Internal affairs').click();
        await settle();
        eq(page.querySelectorAll('tbody tr').length, 1);
        page.querySelector('tbody tr').click();
        await settle();
        eq(last(mdt, 'pf_mdt:ia:get').payload.id, 31);
        noInjection(mdt, 'IA detail');
        page.querySelector('input[aria-label="Outcome"]').value = 'Written reprimand';
        byText(page, 'button', 'Sustained').click();
        await settle();
        const f = last(mdt, 'pf_mdt:ia:finding').payload;
        eq(f.id, 31);
        eq(f.finding, 'sustained');
        eq(f.outcome, 'Written reprimand');
    });

    await it('personnel: a performance review posts officer, period and the chosen scores only', async () => {
        mdt.api['pf_mdt:reviews:create'] = { ok: true, reviewId: 4 };
        const page = root(mdt).querySelector('.pfx-personnel');
        byText(page, '[role="tab"]', 'Write a review').click();
        await settle();
        const form = page.querySelector('.pfx-tabbody form');
        form.querySelector('input[aria-label="Officer citizen id"]').value = 'OFF7';
        form.querySelector('select[data-score="conduct"]').value = '4';
        form.querySelector('select[data-score="teamwork"]').value = '5';
        await submit(mdt, form);
        const r = last(mdt, 'pf_mdt:reviews:create').payload;
        eq(r.officerCid, 'OFF7');
        ok(/^\d{4}-\d\d$/.test(r.period), 'period');
        eq(JSON.stringify(r.scores), JSON.stringify({ conduct: 4, teamwork: 5 }));
    });

    await it('client relay: every endpoint the pages call is on the bridge allowlist', async () => {
        const lua = fs.readFileSync(path.join(ROOT, DIR, 'client', 'pages_ext.lua'), 'utf8')
            + fs.readFileSync(path.join(ROOT, DIR, 'client', 'main.lua'), 'utf8');
        const used = new Set();
        for (const f of ['custody.js', 'evidence_coc.js', 'lab.js', 'timeline.js', 'uof.js', 'personnel_ext.js']) {
            const src = fs.readFileSync(path.join(ROOT, DIR, 'html', 'pages', f), 'utf8');
            for (const m of src.matchAll(/ctx\.call\('([^']+)'/g)) used.add(m[1]);
            for (const m of src.matchAll(/\('(pf_mdt:[a-z]+:[a-zA-Z]+)'/g)) used.add(m[1]);
            ok(!/\.innerHTML\s*=/.test(src), `${f} never sets innerHTML`);
            ok(!/localStorage/.test(src), `${f} keeps drafts on the server`);
        }
        ok(used.size >= 25, 'endpoints found');
        for (const name of used) ok(lua.indexOf(`'${name}'`) !== -1, `${name} allowed`);
    });

    if (mdt.errors.length) failures.push('jsdom errors: ' + mdt.errors.slice(0, 5).join(' | '));
    console.log(`\n${passed} passed, ${failed} failed (b21 MDT custody/evidence/personnel pages)`);
    if (failed || mdt.errors.length) { failures.forEach((f) => console.log("  - " + f)); process.exit(1); }
    process.exit(0);
})();
