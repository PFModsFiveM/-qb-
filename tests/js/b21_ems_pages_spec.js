// Batch 21C: the EMS MDT field pages loaded for real in jsdom (index.html with every local script in
// page order) and driven like a medic would: Patient Care (exam by modality, treatment, chart),
// the vitals monitor, Care Reports (PCR editor), the Units board and the patient profile's Medical
// tab. Checks: every server string is text (no element, no attribute, no script), navigation follows
// the server's answer, empty/loading/error states, results are the server's (a refusal is never
// shown as success), and each action calls the right NUI callback with the right payload.
// Run: node js/b21_ems_pages_spec.js   (MDT_UI_ROOT=<folder holding pf-emsmdt/> runs another copy)
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { JSDOM, VirtualConsole } = require('jsdom');

const ROOT = process.env.MDT_UI_ROOT || path.resolve(__dirname, '..', '..', '..', '[pfscripts]');

let passed = 0;
let failed = 0;
const failures = [];
async function it(name, fn) {
    try { await fn(); passed++; } catch (e) { failed++; failures.push(`${name}: ${e && e.stack || e}`); }
}
function eq(a, b, msg) { if (a !== b) throw new Error(`${msg || 'expected'}: ${JSON.stringify(b)}, got ${JSON.stringify(a)}`); }
function ok(v, msg) { if (!v) throw new Error(msg || 'expected truthy'); }
const tick = () => new Promise((r) => setTimeout(r, 0));
async function settle(n = 25) { for (let i = 0; i < n; i++) await tick(); }

const EVIL = '"><img src=x onerror="window.__xss=1"><b id=pwn>x</b>\'-alert(1)-\'</script> ';

function leaflet() {
    const fn = function () {};
    const p = new Proxy(fn, {
        get(t, k) { if (k === Symbol.toPrimitive) return () => 0; if (k === 'then') return undefined; return p; },
        apply() { return p; }, construct() { return p; },
    });
    return p;
}

function boot(responses) {
    const dir = 'pf-emsmdt';
    const base = path.join(ROOT, dir, 'html');
    const html = fs.readFileSync(path.join(base, 'index.html'), 'utf8');
    const scripts = [...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/g)].map((m) => {
        const src = /\bsrc="([^"]+)"/.exec(m[1]);
        return src ? { file: src[1].split('?')[0] } : { inline: m[2] };
    }).filter((s) => s.inline !== undefined || !/^https?:/i.test(s.file));
    const errors = [];
    const vc = new VirtualConsole();
    vc.on('jsdomError', (e) => errors.push(String(e && e.message || e)));
    const dom = new JSDOM(html.replace(/<script\b[^>]*>[\s\S]*?<\/script>/g, ''), {
        url: `https://cfx-nui-${dir}/html/index.html`, runScripts: 'outside-only', pretendToBeVisual: true, virtualConsole: vc,
    });
    const w = dom.window;
    const posts = [];
    w.L = leaflet();
    w.GetParentResourceName = () => dir;
    w.fetch = async (url, opts) => {
        const name = String(url).replace(/^https:\/\/[^/]+\//, '');
        const body = JSON.parse((opts && opts.body) || '{}');
        posts.push({ name, body });
        let r = responses[name];
        if (name === 'emsServer') r = responses['emsServer:' + body.op];
        const result = typeof r === 'function' ? await r(body) : (r === undefined ? {} : r);
        return { ok: true, status: 200, json: async () => result, text: async () => JSON.stringify(result) };
    };
    const ctx = dom.getInternalVMContext();
    for (const s of scripts) {
        const code = s.inline !== undefined ? s.inline : fs.readFileSync(path.join(base, s.file), 'utf8');
        new vm.Script(code, { filename: s.file || 'inline' }).runInContext(ctx);
    }
    const run = (code) => new vm.Script(code).runInContext(ctx);
    const post = (data) => w.dispatchEvent(new w.MessageEvent('message', { data }));
    const router = () => run('router');
    const page = (name) => router().pages.get(name);
    const postsNamed = (name, op) => posts.filter((p) => p.name === name && (op === undefined || p.body.op === op));
    return { w, dom, posts, errors, run, post, router, page, postsNamed, responses };
}

function noInjection(m, where, root) {
    const scope = root || m.w.document;
    eq(scope.querySelectorAll('img[src="x"], #pwn, [onerror]').length, 0, `${where}: a server string became an element`);
    eq(m.w.__xss, undefined, `${where}: script ran`);
}

async function open(m, user) {
    m.post({ action: 'open', calls: [], config: { localeData: {}, map: {} }, permissions: { allowed: true, isSupervisor: false },
        user: Object.assign({ name: 'Medic Test', rank: 'EMS', rankLevel: 1, grade: 'Paramedic', callsign: 'M-1', citizenid: 'CID1' }, user || {}) });
    await settle();
}

const navItem = (m, page) => m.w.document.querySelector(`.nav-item[data-page="${page}"]`);
const btnByText = (root, text) => [...root.querySelectorAll('button')].find((b) => b.textContent.trim() === text);
function change(m, el, value) { el.value = value; el.dispatchEvent(new m.w.Event('change', { bubbles: true })); }
function submit(m, form) { form.dispatchEvent(new m.w.Event('submit', { bubbles: true, cancelable: true })); }

const CATALOG = {
    regions: [{ id: 'head', label: 'Head' }, { id: 'thigh_l', label: 'Left thigh' }, { id: 'forearm_r', label: 'Right forearm' }],
    structures: { femur_l: 'Left femur' },
    actions: {
        splint: { label: 'Splint', target: 'region', regions: ['thigh_l', 'forearm_r'], tier: 1, seconds: 6 },
        pressure_dressing: { label: 'Pressure dressing', target: 'wound', tier: 0, seconds: 4 },
        oxygen: { label: 'Oxygen', target: 'patient', tier: 1, seconds: 4 },
    },
};
const SELECT = {
    ok: true, patient: { target: 7, citizenid: 'PAT1', name: EVIL },
    exam: { ok: true, tier: 2, tierLabel: 'EMT', modalities: [
        { id: 'look', label: 'Look (inspect)', seconds: 3, tier: 0, available: true },
        { id: 'pulse', label: 'Check pulse', seconds: 4, tier: 1, available: true },
        { id: 'bp_cuff', label: 'Blood pressure', seconds: 6, tier: 2, available: false, reason: EVIL },
        { id: 'ct', label: 'CT scan', seconds: 30, tier: 5, available: false, reason: 'Needs physician' },
    ] },
    treat: { ok: true, tier: 2, medical: true, actions: ['splint', 'pressure_dressing', 'oxygen', 'not_in_catalog'] },
    catalog: CATALOG,
};

(async () => {
    // ── navigation from the server's answer ────────────────────────────────────────────────
    await it('nav: Units and Care Reports follow the server (refused -> hidden, answered -> shown)', async () => {
        const m = boot({ emsAccess: { ok: true, units: { ok: true, units: [], unassigned: [], statuses: {} }, pcr: { ok: false, error: 'no_permission', message: 'EMS only.' } } });
        await open(m);
        ok(m.postsNamed('emsAccess').length === 1, 'the page asked the server');
        eq(navItem(m, 'pcr').hidden, true, 'reports hidden after a refusal');
        eq(navItem(m, 'units').hidden, false, 'units shown');
        ok(navItem(m, 'care'), 'patient care registered');
        m.responses.emsAccess = { ok: true, units: { ok: false, error: 'not_on_duty' }, pcr: { ok: true, list: [] } };
        await open(m);
        eq(navItem(m, 'pcr').hidden, false, 'reports shown when the server answers');
        eq(navItem(m, 'units').hidden, true, 'units hidden off duty');
        m.responses.emsAccess = { success: false, error: 'timeout' };
        await open(m);
        eq(navItem(m, 'units').hidden, true, 'no answer keeps the last server answer');
    });

    // ── Patient Care: nearby, select, exam ─────────────────────────────────────────────────
    const care = boot({
        emsAccess: { ok: true, units: { ok: true }, pcr: { ok: true, list: [] } },
        emsCareNearby: { ok: true, list: [{ target: 7, citizenid: EVIL, name: EVIL, distance: 1.2 }] },
        emsCareSelect: SELECT,
        emsCareExam: (b) => b.modality === 'look'
            ? { ok: true, modality: 'look', at: 1700000000, findings: [{ id: 1, injuryId: 41, sign: 'deformity', label: EVIL, region: 'thigh_l', certainty: 'observed', value: EVIL }] }
            : { ok: true, modality: 'pulse', at: 1700000100, findings: [], vitals: { hr: 128, rr: 24 } },
        emsCareTreat: { ok: false, error: 'missing_item', message: EVIL },
        emsCareChart: { ok: true, tier: 2, findings: [], diagnoses: [{ injuryType: 'fracture', structure: 'femur_l', status: 'suspected' }],
            treatments: [{ action: 'splint', result: 'applied', location: 'field', at: 1700000200 }],
            vitals: [{ modality: 'spo2_probe', sign: 'spo2', value: '88', at: 1700000300 }, { modality: 'bp_cuff', sign: 'blood_pressure', value: '84/50', at: 1700000250 }] },
        emsCareClose: { ok: true },
    });
    await open(care);
    const C = care.w.document;

    await it('care: nearby patients are text; choosing one asks the server for that patient', async () => {
        care.run("router.set('care')");
        await settle();
        const root = C.getElementById('pageContent');
        noInjection(care, 'nearby', root);
        const btn = root.querySelector('.ems-list-btn');
        ok(btn && btn.textContent.includes(EVIL), 'name shown as text');
        btn.click();
        await settle();
        const sel = care.postsNamed('emsCareSelect');
        eq(sel.length, 1);
        eq(sel[0].body.target, 7, 'target sent');
        noInjection(care, 'patient header', root);
        ok(root.textContent.includes(EVIL), 'patient name as text');
    });

    await it('care: exams by modality: available ones run, others say why, higher tiers are not offered', async () => {
        const root = C.getElementById('pageContent');
        const rows = [...root.querySelectorAll('.ems-exam-row')];
        eq(rows.length, 3, 'look, pulse, bp_cuff (CT needs a higher tier)');
        const bp = root.querySelector('button[data-modality="bp_cuff"]');
        ok(bp.disabled, 'unavailable exam disabled');
        ok(rows[2].textContent.includes(EVIL), 'the server reason as text');
        noInjection(care, 'exam list', root);
        root.querySelector('button[data-modality="look"]').click();
        await settle();
        const ex = care.postsNamed('emsCareExam');
        eq(ex.length, 1);
        eq(JSON.stringify(ex[0].body), JSON.stringify({ target: 7, modality: 'look' }));
        const result = root.querySelector('.ems-result');
        ok(result && result.textContent.includes(EVIL), 'finding label/value as text');
        ok(result.textContent.includes('Left thigh'), 'region label from the catalogue');
        noInjection(care, 'exam result', root);
    });

    await it('care: an exam that finds nothing says so; its vitals reach the monitor', async () => {
        const root = C.getElementById('pageContent');
        root.querySelector('button[data-modality="pulse"]').click();
        await settle();
        ok(root.querySelector('.ems-result').textContent.includes('Nothing found'), 'honest empty result');
        const hr = root.querySelector('.ems-vital[data-channel="hr"]');
        eq(hr.querySelector('.ems-vital-num').textContent, '128');
        ok(hr.classList.contains('ems-vital-warn'), 'band from the value');
        eq(root.querySelector('.ems-vital[data-channel="rr"] .ems-vital-num').textContent, '24');
        eq(root.querySelector('.ems-vital[data-channel="spo2"] .ems-vital-num').textContent, '—', 'unmeasured stays empty');
    });

    await it('care: a refused exam shows the server message, not a result', async () => {
        care.responses.emsCareExam = { ok: false, error: 'too_far', message: 'You are too far from the patient.' };
        const root = C.getElementById('pageContent');
        root.querySelector('button[data-modality="look"]').click();
        await settle();
        const result = root.querySelector('.ems-result');
        ok(result.querySelector('.ems-state-error'), 'error state');
        ok(result.textContent.includes('too far'), result.textContent);
    });

    await it('care: treatments: region actions need a place; the server refusal is shown, never success', async () => {
        const root = C.getElementById('pageContent');
        root.querySelector('[data-care-tab="treat"]').click();
        await settle();
        const sel = C.getElementById('emsTreatAction');
        const names = [...sel.options].map((o) => o.value);
        eq(names.join(','), 'oxygen,pressure_dressing,splint', 'server list x catalogue, by label');
        change(care, sel, 'splint');
        await settle();
        const where = C.getElementById('emsTreatWhere');
        eq([...where.options].map((o) => o.value).join(','), ',region:thigh_l,region:forearm_r', 'only the action regions');
        ok(C.getElementById('emsTreatApply').disabled, 'no place, no apply');
        change(care, C.getElementById('emsTreatWhere'), 'region:thigh_l');
        await settle();
        ok(!C.getElementById('emsTreatApply').disabled);
        submit(care, root.querySelector('form.ems-form'));
        await settle();
        const tr = care.postsNamed('emsCareTreat');
        eq(tr.length, 1);
        eq(JSON.stringify(tr[0].body), JSON.stringify({ target: 7, action: 'splint', region: 'thigh_l' }));
        const res = root.querySelector('.ems-result');
        ok(res.querySelector('.ems-state-error'), 'refusal shown as an error');
        ok(res.textContent.includes(EVIL), 'server message as text');
        ok(!/Applied|Treated/.test(res.textContent), 'not reported as done');
        noInjection(care, 'treat result', root);
    });

    await it('care: wound treatments can target a found injury; the server result is shown', async () => {
        care.responses.emsCareTreat = { ok: true, id: 9, result: { changed: { action: 'pressure_dressing', result: 'no_effect' }, message: EVIL } };
        const root = C.getElementById('pageContent');
        change(care, C.getElementById('emsTreatAction'), 'pressure_dressing');
        await settle();
        const opts = [...C.getElementById('emsTreatWhere').options].map((o) => o.value);
        ok(opts.includes('injury:41'), 'the found injury is offered: ' + opts.join(','));
        eq(opts[0], '', 'worst wound by default');
        change(care, C.getElementById('emsTreatWhere'), 'injury:41');
        await settle();
        submit(care, root.querySelector('form.ems-form'));
        await settle();
        const last = care.postsNamed('emsCareTreat').pop();
        eq(JSON.stringify(last.body), JSON.stringify({ target: 7, action: 'pressure_dressing', injuryId: 41 }));
        const res = root.querySelector('.ems-result');
        ok(res.textContent.includes('No effect'), 'the server outcome, not "applied"');
        noInjection(care, 'treat ok', root);
    });

    await it('care: the chart lists the server record and feeds the monitor', async () => {
        const root = C.getElementById('pageContent');
        root.querySelector('[data-care-tab="chart"]').click();
        await settle();
        eq(care.postsNamed('emsCareChart').length, 1);
        eq(care.postsNamed('emsCareChart')[0].body.target, 7);
        ok(root.textContent.includes('Left femur'), 'structure label');
        ok(root.textContent.includes('Splint'), 'treatment label');
        eq(root.querySelector('.ems-vital[data-channel="spo2"] .ems-vital-num').textContent, '88');
        ok(root.querySelector('.ems-vital[data-channel="spo2"]').classList.contains('ems-vital-bad'));
        eq(root.querySelector('.ems-vital[data-channel="bp"] .ems-vital-num').textContent, '84/50');
    });

    await it('care: the live monitor only takes readings for the patient on the page', async () => {
        const root = C.getElementById('pageContent');
        care.post({ action: 'careMonitor', target: 99, vitals: { hr: 40 }, rhythm: 'vf' });
        await settle();
        eq(root.querySelector('.ems-vital[data-channel="hr"] .ems-vital-num').textContent, '128', 'other patient ignored');
        care.post({ action: 'careMonitor', target: 7, vitals: { hr: 61, spo2: 97 }, rhythm: EVIL });
        await settle();
        eq(root.querySelector('.ems-vital[data-channel="hr"] .ems-vital-num').textContent, '61');
        ok(root.querySelector('.ems-vital[data-channel="hr"] .ems-vital-meta').textContent.startsWith('monitor'));
        noInjection(care, 'monitor', root);
        // a Measure button runs the exam of that channel
        const before = care.postsNamed('emsCareExam').length;
        care.responses.emsCareExam = { ok: true, modality: 'pulse', at: 1700000400, findings: [], vitals: { hr: 70, rr: 14 } };
        root.querySelector('.ems-vital[data-channel="hr"] .ems-vital-measure').click();
        await settle();
        eq(care.postsNamed('emsCareExam').length, before + 1);
        eq(care.postsNamed('emsCareExam').pop().body.modality, 'pulse');
        ok(!root.querySelector('.ems-vital[data-channel="bp"] .ems-vital-measure'), 'no Measure for an exam the server refused here');
    });

    await it('care: a refused selection shows the server reason; the MDT can open a patient from the game', async () => {
        care.responses.emsCareSelect = { ok: false, error: 'not_found', message: EVIL };
        care.post({ action: 'careOpen', target: 12 });
        await settle();
        eq(care.postsNamed('emsCareSelect').pop().body.target, 12);
        const root = C.getElementById('pageContent');
        ok(root.textContent.includes(EVIL));
        noInjection(care, 'select refusal', root);
    });

    await it('care: empty and error states for the nearby list', async () => {
        const m = boot({ emsAccess: { ok: true }, emsCareNearby: { ok: true, list: [] } });
        await open(m);
        m.run("router.set('care')");
        await settle();
        ok(m.w.document.getElementById('pageContent').textContent.includes('Nobody is close enough'));
        m.responses.emsCareNearby = { success: false, error: 'timeout' };
        btnByText(m.w.document.getElementById('pageContent'), 'Refresh').click();
        await settle();
        ok(m.w.document.querySelector('#pageContent .ems-state-error').textContent.includes('No answer'));
    });

    // ── Care Reports ───────────────────────────────────────────────────────────────────────
    const PCR = {
        id: 5, citizenid: 'PAT1', patientName: EVIL, callRef: EVIL, unit: 'MEDIC 1', lead: { citizenid: 'CID1', name: EVIL }, state: 'open',
        narrative: EVIL, createdAt: 1700000000, entryCount: 2, entries: [{ id: 1, kind: 'treatment', summary: EVIL, byName: EVIL, at: 1700000000 }],
        can: { narrative: true, close: true, acknowledge: false },
    };
    const pcrM = boot({
        emsAccess: { ok: true, units: { ok: true }, pcr: { ok: true, list: [{ id: 5, patientName: EVIL, state: 'open', unit: EVIL, lead: { name: EVIL }, createdAt: 1700000000, entryCount: 2 }] } },
        'emsServer:pcr:get': () => ({ ok: true, pcr: JSON.parse(JSON.stringify(PCR)), narrativeMax: 4000,
            dispositions: { transported: 'Transported', treated_on_scene: 'Treated on scene', refused: 'Refused care' } }),
        'emsServer:pcr:saveNarrative': { ok: true, length: 5 },
        'emsServer:pcr:close': { ok: false, error: 'invalid_state', message: EVIL },
        'emsServer:pcr:list': { ok: true, list: [] },
        'emsServer:pcr:pendingHandovers': { ok: false, error: 'no_permission', message: 'Hospital staff only.' },
    });
    await open(pcrM);
    const P = pcrM.w.document;
    let storageWrites = 0;
    pcrM.w.Storage.prototype.setItem = function () { storageWrites++; };

    await it('pcr: the list (from the open answer) is text and opens a report by id', async () => {
        pcrM.run("router.set('pcr')");
        await settle();
        const root = P.getElementById('pageContent');
        noInjection(pcrM, 'pcr list', root);
        ok(root.textContent.includes(EVIL));
        root.querySelector('button[data-pcr-id="5"]').click();
        await settle();
        const get = pcrM.postsNamed('emsServer', 'pcr:get');
        eq(get.length, 1);
        eq(get[0].body.data.id, 5);
        noInjection(pcrM, 'pcr detail', root);
        eq(C.querySelector ? P.getElementById('emsPcrNarrative').value : null, EVIL, 'narrative in the field as text');
        ok(root.querySelector('.ems-timeline').textContent.includes(EVIL));
    });

    await it('pcr: the narrative autosaves to the server (never local storage) and shows the result', async () => {
        const ta = P.getElementById('emsPcrNarrative');
        ta.value = 'Pt found conscious';
        ta.dispatchEvent(new pcrM.w.Event('input'));
        eq(P.querySelector('.ems-save-state').dataset.state, 'dirty');
        ta.dispatchEvent(new pcrM.w.Event('blur'));
        await settle();
        const save = pcrM.postsNamed('emsServer', 'pcr:saveNarrative');
        eq(save.length, 1);
        eq(JSON.stringify(save[0].body.data), JSON.stringify({ id: 5, text: 'Pt found conscious' }));
        eq(P.querySelector('.ems-save-state').textContent, 'Saved');
        eq(storageWrites, 0, 'nothing written to localStorage');
        pcrM.responses['emsServer:pcr:saveNarrative'] = { ok: false, error: 'invalid_state', message: 'The report is closed.' };
        ta.value = 'more';
        ta.dispatchEvent(new pcrM.w.Event('input'));
        await pcrM.run("router.pages.get('pcr').flushNarrative()");
        await settle();
        ok(P.querySelector('.ems-save-state').textContent.includes('The report is closed.'), 'server reason');
        eq(P.querySelector('.ems-save-state').dataset.state, 'error');
    });

    await it('pcr: close offers the dispositions the server allows for the state and shows a refusal', async () => {
        const sel = P.getElementById('emsPcrDisposition');
        const opts = [...sel.options].map((o) => o.value);
        ok(!opts.includes('transported'), 'an open report cannot close as transported');
        eq(opts.length, 2);
        change(pcrM, sel, 'refused');
        submit(pcrM, P.getElementById('emsPcrClose').closest('form'));
        await settle();
        const close = pcrM.postsNamed('emsServer', 'pcr:close').pop();
        eq(JSON.stringify(close.body.data), JSON.stringify({ id: 5, disposition: 'refused' }));
        const root = P.getElementById('pageContent');
        ok(root.querySelector('.ems-state-error').textContent.includes(EVIL));
        noInjection(pcrM, 'close refusal', root);
        ok(!P.getElementById('emsPcrAck'), 'no accept-handover without can.acknowledge');
    });

    await it('pcr: a handed-over report for staff: accept and close follow the can flags', async () => {
        PCR.state = 'handed_over';
        PCR.can = { narrative: false, close: true, acknowledge: true };
        pcrM.responses['emsServer:pcr:acknowledgeHandover'] = { ok: true };
        await pcrM.run("router.pages.get('pcr').openReport(5)");
        await settle();
        ok(!P.getElementById('emsPcrNarrative'), 'narrative read-only without can.narrative');
        ok(P.getElementById('pageContent').textContent.includes(EVIL), 'narrative shown as text');
        eq([...P.getElementById('emsPcrDisposition').options].map((o) => o.value).join(','), 'transported');
        P.getElementById('emsPcrAck').click();
        await settle();
        eq(pcrM.postsNamed('emsServer', 'pcr:acknowledgeHandover').pop().body.data.id, 5);
        PCR.can = { narrative: false, close: false, acknowledge: false };
        await pcrM.run("router.pages.get('pcr').openReport(5)");
        await settle();
        ok(!P.getElementById('emsPcrClose') && !P.getElementById('emsPcrAck'), 'no actions without flags');
    });

    await it('pcr: other lists: handovers refused shows the reason; patient search sends the citizen id', async () => {
        pcrM.run("router.pages.get('pcr').back()");
        await settle();
        P.querySelector('[data-pcr-tab="handover"]').click();
        await settle();
        ok(P.querySelector('#pageContent .ems-state-error').textContent.includes('Hospital staff only.'));
        P.querySelector('[data-pcr-tab="patient"]').click();
        await settle();
        ok(P.getElementById('pageContent').textContent.includes('Enter a citizen ID'));
        P.getElementById('emsPcrPatient').value = 'ABC123';
        submit(pcrM, P.getElementById('emsPcrPatient').closest('form'));
        await settle();
        eq(JSON.stringify(pcrM.postsNamed('emsServer', 'pcr:list').pop().body.data), JSON.stringify({ scope: 'patient', citizenId: 'ABC123' }));
        ok(P.getElementById('pageContent').textContent.includes('No reports.'));
    });

    // ── Units ──────────────────────────────────────────────────────────────────────────────
    const BOARD = { ok: true, statuses: { available: 'Available', on_scene: 'On scene' },
        units: [{ unit: 'MEDIC 1', status: 'available', statusLabel: EVIL, crew: [{ citizenid: 'CID1', name: EVIL }], rigPlate: EVIL, callRef: EVIL, statusAt: 1700000000 },
            { unit: EVIL, status: '<b>', crew: [{ citizenid: 'X', name: 'Other' }] }],
        unassigned: [{ citizenid: 'Z', name: EVIL }] };
    const un = boot({
        emsAccess: { ok: true, units: BOARD, pcr: { ok: true, list: [] } },
        'emsServer:units:list': BOARD,
        'emsServer:units:setStatus': { ok: true },
        'emsServer:units:leave': { ok: false, error: 'not_found', message: EVIL },
        'emsServer:units:join': { ok: true },
        'emsServer:units:setRig': { ok: false, error: 'bad_args', message: 'Sit in the rig first.' },
    });
    await open(un);
    const U = un.w.document;

    await it('units: the board is text; my unit gets status, rig and leave controls', async () => {
        un.run("router.set('units')");
        await settle();
        const root = U.getElementById('pageContent');
        noInjection(un, 'unit board', root);
        ok(root.textContent.includes(EVIL));
        eq(un.postsNamed('emsServer', 'units:list').length, 1, 'the board is loaded on mount');
        change(un, U.getElementById('emsUnitStatus'), 'on_scene');
        await settle();
        eq(JSON.stringify(un.postsNamed('emsServer', 'units:setStatus').pop().body.data), JSON.stringify({ status: 'on_scene' }));
        U.getElementById('emsUnitRig').click();
        await settle();
        ok(root.querySelector('.ems-state-error').textContent.includes('Sit in the rig first.'), 'server refusal');
        U.getElementById('emsUnitLeave').click();
        await settle();
        eq(un.postsNamed('emsServer', 'units:leave').length, 1);
        ok(root.querySelector('.ems-state-error').textContent.includes(EVIL));
        noInjection(un, 'units error', root);
    });

    await it('units: another unit can be joined; the pushed board re-renders', async () => {
        const root = U.getElementById('pageContent');
        const join = [...root.querySelectorAll('button[data-unit-join]')];
        eq(join.length, 1, 'join only on other units');
        join[0].click();
        await settle();
        eq(un.postsNamed('emsServer', 'units:join').pop().body.data.unit, EVIL);
        un.post({ action: 'unitBoard', board: { units: [], unassigned: [], statuses: {} } });
        await settle();
        ok(root.textContent.includes('No unit is on the board.'));
        ok(U.getElementById('emsUnitName'), 'not in a unit: join form');
        U.getElementById('emsUnitName').value = 'MEDIC 9';
        submit(un, U.getElementById('emsUnitName').closest('form'));
        await settle();
        eq(un.postsNamed('emsServer', 'units:join').pop().body.data.unit, 'MEDIC 9');
    });

    await it('units: a refused board shows the error state', async () => {
        un.responses['emsServer:units:list'] = { ok: false, error: 'no_permission', message: 'EMS only.' };
        un.run("router.set('dashboard')");
        un.run("router.set('units')");
        await settle();
        ok(U.querySelector('#pageContent .ems-state-error').textContent.includes('EMS only.'));
    });

    // ── Medical tab ────────────────────────────────────────────────────────────────────────
    await it('medical tab: record lines, treatments, admissions and care reports are text; a report opens on the PCR page', async () => {
        const m = boot({ emsAccess: { ok: true }, 'emsServer:pcr:get': { ok: false, error: 'not_found', message: 'No such report.' } });
        await open(m);
        m.post({ action: 'setCitizenProfile', profile: { citizenId: 'PAT1', name: EVIL, bloodtype: EVIL, notes: [],
            medical: { available: true, injuries: [EVIL], conditions: [EVIL], medications: [], treatments: [EVIL], admissions: [EVIL] },
            pcrs: [{ id: 33, state: 'closed', unit: EVIL, lead: { name: EVIL }, createdAt: 1700000000, dispositionLabel: EVIL }] } });
        await settle();
        const view = m.w.document.querySelector('[data-view="c-medical"]');
        noInjection(m, 'medical tab', m.w.document.getElementById('citizenProfileModal'));
        ok(view.textContent.includes('Treatments') && view.textContent.includes('Hospital admissions'));
        eq(view.querySelectorAll('.ems-lines li').length, 4, 'injury, diagnosis, treatment, admission');
        ok(view.textContent.includes('No prescriptions.'), 'empty section state');
        btnByText(view, 'Open').click();
        await settle();
        eq(m.router().current, 'pcr');
        eq(m.postsNamed('emsServer', 'pcr:get').pop().body.data.id, 33);
        ok(m.w.document.getElementById('citizenProfileModal').classList.contains('hidden'));
        ok(m.w.document.querySelector('#pageContent .ems-state-error').textContent.includes('No such report.'));
    });

    await it('medical tab: a refused record and a failed profile say so', async () => {
        const m = boot({ emsAccess: { ok: true } });
        await open(m);
        m.post({ action: 'setCitizenProfile', profile: { citizenId: 'P', name: 'A', medical: { available: false, error: 'no_permission' }, pcrs: [] } });
        await settle();
        const view = m.w.document.querySelector('[data-view="c-medical"]');
        ok(view.querySelector('.ems-state-error').textContent.includes('You may not see this record'));
        ok(view.textContent.includes('No care reports you may see.'));
        m.post({ action: 'setCitizenProfile', profile: {}, error: 'not_found' });
        await settle();
        ok(m.w.document.querySelector('#citizenProfileContent .ems-state-error').textContent.includes('Not found.'));
    });

    for (const m of [care, pcrM, un]) {
        if (m.errors.length) failures.push(`script errors while running: ${m.errors.slice(0, 5).join(' | ')}`);
    }
    console.log(`\n${passed} passed, ${failed} failed (b21 EMS pages)`);
    if (failed || failures.length) { failures.forEach((f) => console.log('  - ' + f)); process.exit(1); }
    process.exit(0);
})();
