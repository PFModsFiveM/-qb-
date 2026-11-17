// Batch 21A: the police MDT records pages loaded for real in jsdom (index.html with every local script in
// page order) and driven through the NUI bridge: the page hook (window.PFMdtPages), cases, warrants v2,
// BOLO board, citations, plates/impound, and the mdt-server rework leftovers (licence reason and
// history, releasedOnLogin, protected_chief text, bail offer toast).
// Every page: server strings are text (an <img onerror> payload never becomes an element), navigation
// follows the permission answer, lists have loading/empty/error states, and each action calls the right
// endpoint with the right payload (no client-made ids).
// Run: node js/b21_mdt_records_pages_spec.js   (MDT_UI_ROOT=<folder holding pf-policemdt-DEV/> for another copy)
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { JSDOM, VirtualConsole } = require('jsdom');

const ROOT = process.env.MDT_UI_ROOT || path.resolve(__dirname, '..', '..', '..', '[pfscripts]');
const RES = path.join(ROOT, 'pf-policemdt-DEV');

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

const EVIL = '"><img src=x onerror="window.__xss=1"><b id=pwn>x</b>';
const EVIL_ID = "AB'1\"); window.__xss=1; ('";

function boot() {
    const base = path.join(RES, 'html');
    const html = fs.readFileSync(path.join(base, 'index.html'), 'utf8');
    const scripts = [...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/g)].map((m) => {
        const src = /\bsrc="([^"]+)"/.exec(m[1]);
        return src ? { file: src[1].split('?')[0] } : { inline: m[2] };
    }).filter((s) => s.inline !== undefined || !/^https?:/i.test(s.file));
    const errors = [];
    const vc = new VirtualConsole();
    vc.on('jsdomError', (e) => errors.push(String(e && e.message || e)));
    const dom = new JSDOM(html.replace(/<script\b[^>]*>[\s\S]*?<\/script>/g, ''), {
        url: 'https://cfx-nui-pf-policemdt-dev/html/index.html', runScripts: 'outside-only', pretendToBeVisual: true, virtualConsole: vc,
    });
    const w = dom.window;
    const posts = [];
    const responses = {};
    const lp = new Proxy(function () {}, { get: (t, k) => (k === 'then' ? undefined : lp), apply: () => lp, construct: () => lp });
    w.L = lp;
    w.GetParentResourceName = () => 'pf-policemdt-DEV';
    w.fetch = async (url, opts) => {
        const name = String(url).replace(/^https:\/\/[^/]+\//, '');
        const body = JSON.parse((opts && opts.body) || '{}');
        posts.push({ name, body });
        let result;
        if (name === 'pfMdtCall') {
            const r = responses[body.name];
            result = typeof r === 'function' ? r(body.payload) : (r === undefined ? { ok: true, success: true } : r);
        } else {
            const r = responses['nui:' + name];
            result = typeof r === 'function' ? r(body) : (r === undefined ? {} : r);
        }
        return { ok: true, status: 200, json: async () => (result === undefined ? null : result) };
    };
    const ctx = dom.getInternalVMContext();
    for (const s of scripts) {
        const code = s.inline !== undefined ? s.inline : fs.readFileSync(path.join(base, s.file), 'utf8');
        new vm.Script(code, { filename: s.file || 'inline' }).runInContext(ctx);
    }
    const run = (code) => new vm.Script(code).runInContext(ctx);
    const post = (data) => w.dispatchEvent(new w.MessageEvent('message', { data }));
    const calls = (name) => posts.filter((p) => p.name === 'pfMdtCall' && p.body.name === name).map((p) => p.body.payload);
    return { w, posts, responses, errors, run, post, calls };
}

const ALL = ['caseCreate', 'caseEdit', 'caseSubmit', 'createWarrant', 'serveWarrant', 'deleteWarrant', 'warrantApprove', 'bolos', 'clearAnyBolo',
    'vehicleRecords', 'viewAudit', 'printCitation'];
function actionsOf(list) { const o = {}; for (const a of ALL) o[a] = list.includes(a); return o; }

async function openMdt(m, actions) {
    m.post({ action: 'open', calls: [], config: { localeData: {}, map: {}, vehicleFlags: ['STOLEN', 'BOLO'] },
        permissions: { allowed: true, isSupervisor: false, isOwner: false, actions: actionsOf(actions) },
        user: { name: 'Officer Test', citizenid: 'OFF1', rank: 'Officer', rankLevel: 1, callsign: '1-A' } });
    await settle();
}

function noInjection(m, where, root) {
    const scope = root || m.w.document;
    eq(scope.querySelectorAll('img[src="x"], #pwn, [onerror]').length, 0, `${where}: a server string became an element`);
    eq(m.w.__xss, undefined, `${where}: script ran`);
}
const page = (m, name) => m.w.document.querySelector(`[data-pfp-page="${name}"]`);
const btnByText = (root, text) => Array.from(root.querySelectorAll('button')).find((b) => b.textContent.trim() === text);
function setVal(el, v) { el.value = v; el.dispatchEvent(new el.ownerDocument.defaultView.Event('input', { bubbles: true })); el.dispatchEvent(new el.ownerDocument.defaultView.Event('change', { bubbles: true })); }

(async () => {
    const m = boot();
    const D = m.w.document;
    await openMdt(m, ALL);

    // ── the page hook ───────────────────────────────────────────────────────
    await it('hook: pages register, get nav items in their section, and a page named like a built-in replaces it', async () => {
        ok(m.w.PFMdtPages && typeof m.w.PFMdtPages.register === 'function', 'window.PFMdtPages.register exists');
        for (const name of ['cases', 'warrant', 'bolos', 'citations', 'vehicles_ext']) ok(m.w.PFMdtPages.has(name), name + ' registered');
        const cases = D.querySelector('.nav-section[data-nav-section="documentation"] .nav-item[data-page="cases"]');
        ok(cases, 'cases nav item in Documentation');
        ok(D.querySelector('.nav-section[data-nav-section="records"] .nav-item[data-page="bolos"]'), 'BOLO nav item in Records');
        eq(D.querySelectorAll('.nav-item[data-page="warrant"]').length, 1, 'the built-in warrant item is reused, not duplicated');
        ok(m.run("router.pages.get('warrant') instanceof PFMdtPages.HookPage"), 'warrant route is the v2 page');
        cases.click();
        await settle();
        eq(m.run('router.current'), 'cases', 'nav click routes');
        ok(page(m, 'cases'), 'page mounted in its own container');
    });

    await it('hook: bad names are refused, icons accept only path data, late registration installs at once', async () => {
        eq(m.w.PFMdtPages.register('Bad Name', { render() {} }), false);
        eq(m.w.PFMdtPages.register('nopage', {}), false, 'render() required');
        let rendered = null;
        m.w.PFMdtPages.register('b21test', { title: 'T', section: 'main', icon: ['M1 1h2', '"><script>'], perm: 'caseCreate', render(root, ctx) { rendered = ctx; root.appendChild(ctx.h('p', { class: 'x' }, EVIL)); } });
        const item = D.querySelector('.nav-item[data-page="b21test"]');
        ok(item, 'nav item created');
        eq(item.querySelectorAll('path').length, 1, 'only the path data icon entry is used');
        m.run("router.set('b21test')");
        await settle();
        ok(rendered && typeof rendered.call === 'function' && typeof rendered.h === 'function' && rendered.params, 'ctx handed over');
        eq(page(m, 'b21test').querySelector('p.x').textContent, EVIL, 'ctx.h writes text');
        noInjection(m, 'hook page');
    });

    await it('hook: navigation follows the permission answer, and a page the rank cannot open says so', async () => {
        await openMdt(m, ['caseEdit']); // no caseCreate
        const item = D.querySelector('.nav-item[data-page="b21test"]');
        ok(item.classList.contains('pfp-nav-hidden'), 'hidden without the action');
        m.run("router.set('b21test')");
        await settle();
        ok(/rank cannot open/i.test(page(m, 'b21test').textContent), 'refusal state');
        await openMdt(m, ALL);
        ok(!item.classList.contains('pfp-nav-hidden'), 'shown again after a promotion');
    });

    await it('hook: ctx.call normalises answers (ok flag, lists, nothing, false) and posts { name, payload }', async () => {
        m.responses['t:a'] = { success: true, x: 1 };
        m.responses['t:b'] = [1, 2];
        m.responses['t:c'] = undefined;
        m.responses['t:d'] = false;
        m.responses['t:e'] = { success: false, error: 'protected_chief' };
        m.responses['t:c'] = () => undefined;
        const a = await m.run("mdtCall('t:a', { q: 1 })");
        eq(a.ok, true); eq(a.x, 1);
        const b = await m.run("mdtCall('t:b', 'PLATE')");
        eq(b.ok, true); eq(b.data.length, 2);
        eq(m.calls('t:b')[0], 'PLATE', 'a plain argument goes as the payload');
        const c = await m.run("mdtCall('t:c', {})");
        eq(c.ok, false); eq(c.error, 'no_response');
        const d = await m.run("mdtCall('t:d', {})");
        eq(d.ok, false);
        const e = await m.run("mdtCall('t:e', {})");
        eq(e.ok, false);
        ok(/department head/.test(m.w.mdtErrorText(e)), 'protected_chief reads as a sentence');
    });

    // ── cases ───────────────────────────────────────────────────────────────
    const CASE = {
        ok: true,
        case: { id: 7, caseNo: 'C-000007', title: EVIL, status: 'active', priority: 2, leadCid: 'OFF1', leadName: EVIL, summary: EVIL, createdBy: 'OFF1', createdAt: 1700000000, updatedAt: 1700000100 },
        links: [{ id: 1, type: 'incident', refId: EVIL_ID, note: EVIL, by: 'OFF1', at: 1700000000 },
            { id: 2, type: 'death_record', refId: '12', note: EVIL, by: 'system:pf-ambulancejob', at: 1700000000 }],
        people: [{ id: 3, role: 'suspect', citizenid: 'CIT1', name: EVIL, note: EVIL }],
        entries: [{ id: 4, kind: 'lead', status: 'open', body: EVIL, by: 'OFF1', byName: EVIL, at: 1700000000 }],
        submissions: [{ id: 5, personId: 3, citizenid: 'CIT1', state: 'pending', charges: [{ code: 'P1', name: EVIL }], lastError: EVIL }],
        evidence: [{ id: 9, kind: 'casing', label: EVIL, state: 'stored' }],
        can: { manage: true, edit: true, submit: true, supervise: false },
    };
    await it('cases: the list and the case are text; the case is read by id', async () => {
        m.responses['pf_mdt:cases:list'] = { ok: true, list: [{ id: 7, caseNo: 'C-000007', title: EVIL, status: 'active', priority: 2, leadName: EVIL, updatedAt: 1 }], next: 7 };
        m.responses['pf_mdt:cases:get'] = CASE;
        m.run("router.set('cases')");
        await settle();
        const root = page(m, 'cases');
        const row = root.querySelector('.pfp-row[data-case-id="7"]');
        ok(row, 'row');
        ok(row.textContent.includes(EVIL), 'title as text');
        ok(btnByText(root, 'Load more'), 'cursor paging offered');
        eq(m.calls('pf_mdt:cases:list').slice(-1)[0].limit, 25);
        row.click();
        await settle();
        eq(m.calls('pf_mdt:cases:get').slice(-1)[0].caseId, 7);
        noInjection(m, 'case overview', root);
        ok(root.textContent.includes(EVIL), 'summary as text');
        for (const tab of ['people', 'links', 'entries', 'evidence', 'court']) {
            root.querySelector(`.pfp-tab[data-tab="${tab}"]`).click();
            await settle();
            noInjection(m, 'case ' + tab, root);
        }
        eq(root.querySelectorAll('[onclick]').length, 0, 'no inline handlers');
    });

    await it('cases: a death record link shows as the morgue\'s record, links open by id', async () => {
        const root = page(m, 'cases');
        root.querySelector('.pfp-tab[data-tab="links"]').click();
        await settle();
        const dr = root.querySelector('tr[data-link-type="death_record"]');
        ok(dr && /Death record/.test(dr.textContent) && /#12/.test(dr.textContent) && /medical examiner/.test(dr.textContent), 'death record row');
        let opened = null;
        m.w.openIncidentDetailsModal = (id) => { opened = id; };
        root.querySelector('tr[data-link-type="incident"] .pfp-link').click();
        eq(opened, EVIL_ID, 'incident opens by its exact id');
    });

    await it('cases: a death record opens through pf_mdt:cases:deathRecord with the case and link ids; the record is text', async () => {
        m.responses['pf_mdt:cases:deathRecord'] = { ok: true, record: { id: 12, cid: EVIL, state: 'examined', cause: EVIL, manner: EVIL, todText: EVIL, createdAt: 1700000000,
            autopsy: { note: EVIL, suggestedManner: EVIL, injuries: [{ text: EVIL, region: EVIL, lethal: true, attacker: 'other' }], toxins: [{ name: EVIL, level: 1 }] } } };
        const root = page(m, 'cases');
        btnByText(root.querySelector('tr[data-link-type="death_record"]'), 'Details').click();
        await settle();
        const c = m.calls('pf_mdt:cases:deathRecord').slice(-1)[0];
        eq(c.caseId, 7); eq(c.linkId, 2);
        const view = root.querySelector('.pfp-death-record');
        ok(view && view.textContent.includes(EVIL) && /by another person/.test(view.textContent), 'record shown as text');
        noInjection(m, 'death record', root);
        m.responses['pf_mdt:cases:deathRecord'] = { ok: false, error: 'unavailable', message: 'The morgue records are not available right now' };
        btnByText(root.querySelector('tr[data-link-type="death_record"]'), 'Details').click();
        await settle();
        ok(/not available right now/.test(root.querySelector('.pfp-death-record').textContent), 'refusal shown');
    });

    await it('cases: create, add person, link, entry and submit send the server payloads; refusals show the server message', async () => {
        const root = page(m, 'cases');
        m.responses['pf_mdt:cases:create'] = { ok: true, caseId: 8, caseNo: 'C-000008' };
        btnByText(root, '+ New case').click();
        const form = root.querySelector('.pfp-card');
        setVal(form.querySelector('input'), 'Bank job');
        btnByText(root, 'Create case').click();
        await settle();
        const cr = m.calls('pf_mdt:cases:create').slice(-1)[0];
        eq(cr.title, 'Bank job'); eq(cr.priority, 2); eq(cr.caseId, undefined, 'no client id');

        m.run("router.set('cases')"); await settle();
        page(m, 'cases').querySelector('.pfp-row[data-case-id="7"]').click(); await settle();
        let r = page(m, 'cases');
        r.querySelector('.pfp-tab[data-tab="people"]').click(); await settle();
        r = page(m, 'cases');
        m.responses['pf_mdt:cases:addPerson'] = { ok: false, error: 'not_found', message: 'No such citizen' };
        const inputs = r.querySelectorAll('.pfp-form input');
        setVal(inputs[0], 'CIT9');
        btnByText(r, 'Add person').click(); await settle();
        const ap = m.calls('pf_mdt:cases:addPerson').slice(-1)[0];
        eq(ap.caseId, 7); eq(ap.role, 'suspect'); eq(ap.citizenid, 'CIT9');
        ok(r.textContent.includes('No such citizen'), 'server message shown');

        r.querySelector('.pfp-tab[data-tab="links"]').click(); await settle();
        r = page(m, 'cases');
        const sel = r.querySelector('.pfp-form select');
        sel.value = 'bolo'; sel.dispatchEvent(new m.w.Event('change'));
        setVal(r.querySelectorAll('.pfp-form input')[0], '41');
        btnByText(r, 'Link record').click(); await settle();
        const lk = m.calls('pf_mdt:cases:link').slice(-1)[0];
        eq(lk.refType, 'bolo'); eq(lk.refId, 41, 'BOLO ids are numbers');

        r = page(m, 'cases');
        r.querySelector('.pfp-tab[data-tab="entries"]').click(); await settle();
        r = page(m, 'cases');
        setVal(r.querySelector('.pfp-form textarea'), 'Saw the van');
        btnByText(r, 'Add entry').click(); await settle();
        const en = m.calls('pf_mdt:cases:addEntry').slice(-1)[0];
        eq(en.kind, 'note'); eq(en.body, 'Saw the van');
        r = page(m, 'cases');
        const st = r.querySelector('[data-entry-id="4"] select');
        st.value = 'followed'; st.dispatchEvent(new m.w.Event('change')); await settle();
        eq(m.calls('pf_mdt:cases:setEntryStatus').slice(-1)[0].status, 'followed');

        m.responses['pf_mdt:getAllCharges'] = [{ code: 'P1', name: EVIL }, { code: 'P2', name: 'Theft' }];
        r = page(m, 'cases');
        r.querySelector('.pfp-tab[data-tab="court"]').click(); await settle();
        r = page(m, 'cases');
        noInjection(m, 'charge list', r);
        r.querySelector('input[type=checkbox][value="P2"]').checked = true;
        btnByText(r, 'Submit to court').click(); await settle();
        const sb = m.calls('pf_mdt:cases:submit').slice(-1)[0];
        eq(sb.personId, 3); eq(JSON.stringify(sb.charges), '["P2"]');
        ok(btnByText(page(m, 'cases'), 'Withdraw'), 'a pending submission can be withdrawn');
    });

    await it('cases: without the server\'s manage/edit answer no edit controls; without caseCreate no New case', async () => {
        m.responses['pf_mdt:cases:get'] = Object.assign({}, CASE, { can: { manage: false, edit: false, submit: false } });
        await openMdt(m, ['caseEdit']);
        m.run("router.set('cases')"); await settle();
        const r = page(m, 'cases');
        ok(!btnByText(r, '+ New case'), 'no New case button');
        r.querySelector('.pfp-row[data-case-id="7"]').click(); await settle();
        ok(!btnByText(page(m, 'cases'), 'Edit'), 'no Edit');
        page(m, 'cases').querySelector('.pfp-tab[data-tab="people"]').click(); await settle();
        ok(!btnByText(page(m, 'cases'), 'Add person') && !btnByText(page(m, 'cases'), 'Remove'), 'no people controls');
        await openMdt(m, ALL);
    });

    await it('cases: loading, error and empty states', async () => {
        m.responses['pf_mdt:cases:list'] = { ok: false, error: 'db_unavailable' };
        m.run("router.set('cases')"); await settle();
        ok(page(m, 'cases').querySelector('.pfp-state-error'), 'error state');
        m.responses['pf_mdt:cases:list'] = { ok: true, list: [] };
        m.run("router.set('cases')"); await settle();
        ok(/No cases/.test(page(m, 'cases').textContent), 'empty state');
    });

    // ── warrants v2 ─────────────────────────────────────────────────────────
    const W = { warrantId: 'W2611170001', suspectName: EVIL, status: 'pending', type: 'arrest', approvalState: 'pending_approval', expiresAt: '2026-12-01 10:00:00' };
    await it('warrants: a request has no client id; the server answer selects the new warrant', async () => {
        m.responses['pf_mdt:searchWarrants'] = { data: [W], total: 1 };
        m.responses['pf_mdt_dispatch:server:GetWarrantDetails'] = Object.assign({ id: W.warrantId, narrative: EVIL, charges: [EVIL] }, W);
        m.responses['pf_mdt:getAllCharges'] = [{ code: 'P2', name: 'Theft' }];
        m.responses['pf_mdt:warrants:create'] = { success: true, warrantId: 'W2611170002' };
        m.run("router.set('warrant')"); await settle();
        const r = page(m, 'warrant');
        noInjection(m, 'warrant list', r);
        eq(m.calls('pf_mdt:searchWarrants').slice(-1)[0].pageSize, 15, 'server paged');
        btnByText(r, '+ Request warrant').click(); await settle();
        const form = r.querySelector('.pfp-card');
        setVal(form.querySelectorAll('input')[0], 'CIT1');
        setVal(form.querySelector('textarea'), 'Seen at the bank');
        form.querySelector('input[type=checkbox][value="Theft"]').checked = true;
        btnByText(r, 'Send request').click(); await settle();
        const c = m.calls('pf_mdt:warrants:create').slice(-1)[0];
        eq(c.type, 'arrest'); eq(c.suspectCitizenId, 'CIT1'); eq(c.warrantId, undefined, 'no client-made id');
        eq(JSON.stringify(c.charges), '["Theft"]');
        eq(m.calls('pf_mdt_dispatch:server:GetWarrantDetails').slice(-1)[0], 'W2611170002', 'opens the server id');
    });

    await it('warrants: review buttons only with the supervisor answer; a judge review shows instead of buttons', async () => {
        await openMdt(m, ['createWarrant', 'serveWarrant']);
        m.run("router.set('warrant')"); await settle();
        page(m, 'warrant').querySelector('.pfp-row').click(); await settle();
        ok(!btnByText(page(m, 'warrant'), 'Approve'), 'no approve without warrantApprove');
        ok(/supervisor or a judge/.test(page(m, 'warrant').textContent), 'waiting note');
        await openMdt(m, ALL);
        m.run("router.set('warrant')"); await settle();
        page(m, 'warrant').querySelector('.pfp-row').click(); await settle();
        btnByText(page(m, 'warrant'), 'Approve').click(); await settle();
        const rv = m.calls('pf_mdt:warrants:review').slice(-1)[0];
        eq(rv.warrantId, W.warrantId); eq(rv.decision, 'approve');
        m.responses['pf_mdt_dispatch:server:GetWarrantDetails'] = Object.assign({ id: W.warrantId, reviewId: 44 }, W);
        m.run("router.set('warrant')"); await settle();
        page(m, 'warrant').querySelector('.pfp-row').click(); await settle();
        ok(!btnByText(page(m, 'warrant'), 'Approve') && /review #44/.test(page(m, 'warrant').textContent), 'judge decides');
    });

    await it('warrants: serve links a custody number, recall needs deleteWarrant, refusal text from the code', async () => {
        m.responses['pf_mdt_dispatch:server:GetWarrantDetails'] = Object.assign({}, W, { id: W.warrantId, status: 'active', approvalState: 'approved' });
        m.responses['pf_mdt:warrants:setStatus'] = { success: false, error: 'custody_mismatch' };
        m.run("router.set('warrant')"); await settle();
        page(m, 'warrant').querySelector('.pfp-row').click(); await settle();
        let r = page(m, 'warrant');
        setVal(r.querySelector('input[aria-label="Custody number"]'), '15');
        btnByText(r, 'Mark served').click(); await settle();
        const sv = m.calls('pf_mdt:warrants:setStatus').slice(-1)[0];
        eq(sv.status, 'served'); eq(sv.custodyId, 15);
        ok(/not the suspect's current one/.test(page(m, 'warrant').textContent), 'refusal shown as text');
        ok(btnByText(page(m, 'warrant'), 'Recall'), 'recall with deleteWarrant');
        await openMdt(m, ['serveWarrant']);
        m.run("router.set('warrant')"); await settle();
        page(m, 'warrant').querySelector('.pfp-row').click(); await settle();
        ok(!btnByText(page(m, 'warrant'), 'Recall'), 'no recall without deleteWarrant');
        await openMdt(m, ALL);
    });

    await it('warrants: the legacy New Warrant entry points open the v2 page and never make an id', async () => {
        m.run("router.set('dashboard')"); await settle();
        m.w.openNewWarrantForCitizen('CIT5', 'Jane');
        await settle();
        eq(m.run('router.current'), 'warrant');
        eq(page(m, 'warrant').querySelector('.pfp-card input').value, 'CIT5', 'citizen filled in');
        const src = fs.readFileSync(path.join(RES, 'html', 'app-extended.js'), 'utf8');
        ok(!/'W' \+ Math\.floor/.test(src), 'no random warrant code in the page');
    });

    // ── BOLO board ──────────────────────────────────────────────────────────
    await it('bolos: list is text; create and clear send the payloads; clear only for the author or clearAnyBolo', async () => {
        const list = [{ id: 1, kind: 'vehicle', plate: 'ABC123', description: EVIL, lastSeen: EVIL, danger: true, byCid: 'OFF1', createdAt: 1, expiresAt: 2 },
            { id: 2, kind: 'person', citizenid: 'CIT1', description: EVIL, byCid: 'OTHER', createdAt: 1, expiresAt: 2 }];
        m.responses['pf_mdt:bolos:list'] = { success: true, list };
        m.responses['pf_mdt:bolos:create'] = { success: true, id: 3 };
        m.run("router.set('bolos')"); await settle();
        let r = page(m, 'bolos');
        noInjection(m, 'bolo board', r);
        ok(r.textContent.includes(EVIL), 'description as text');
        btnByText(r, '+ New BOLO').click();
        const card = r.querySelector('.pfp-card');
        const kind = card.querySelector('select'); kind.value = 'vehicle'; kind.dispatchEvent(new m.w.Event('change'));
        setVal(card.querySelectorAll('input')[1], 'xyz 1');
        setVal(card.querySelector('textarea'), 'Red van');
        btnByText(r, 'Broadcast BOLO').click(); await settle();
        const c = m.calls('pf_mdt:bolos:create').slice(-1)[0];
        eq(c.kind, 'vehicle'); eq(c.plate, 'xyz 1'); eq(c.description, 'Red van'); eq(c.citizenid, undefined);
        r = page(m, 'bolos');
        btnByText(r.querySelector('[data-bolo-id="1"]'), 'Clear').click(); await settle();
        eq(m.calls('pf_mdt:bolos:clear').slice(-1)[0].id, 1);
        await openMdt(m, ['bolos']);
        m.run("router.set('bolos')"); await settle();
        r = page(m, 'bolos');
        ok(btnByText(r.querySelector('[data-bolo-id="1"]'), 'Clear'), 'own BOLO');
        ok(!btnByText(r.querySelector('[data-bolo-id="2"]'), 'Clear'), 'not someone else\'s without clearAnyBolo');
        await openMdt(m, ALL);
    });

    await it('bolos: a boloChanged push re-reads the board; empty and error states', async () => {
        m.run("router.set('bolos')"); await settle();
        const n = m.calls('pf_mdt:bolos:list').length;
        m.post({ action: 'boloChanged', id: 1, change: 'cleared' }); await settle();
        eq(m.calls('pf_mdt:bolos:list').length, n + 1);
        m.responses['pf_mdt:bolos:list'] = { success: true, list: [] };
        m.post({ action: 'boloChanged' }); await settle();
        ok(/No active BOLOs/.test(page(m, 'bolos').textContent));
        m.responses['pf_mdt:bolos:list'] = { success: false, error: 'rate_limited' };
        m.post({ action: 'boloChanged' }); await settle();
        ok(page(m, 'bolos').querySelector('.pfp-state-error'));
    });

    // ── citations ───────────────────────────────────────────────────────────
    await it('citations: search, fines with paid state, citation print, releasedOnLogin', async () => {
        m.responses['pf_mdt:searchCitizens'] = { data: [{ citizenId: 'CIT1', name: EVIL }], total: 1 };
        m.responses['pf_mdt:getCitizenSentences'] = { success: true, activeJail: { active: false, releasedOnLogin: true },
            sentences: [{ id: 31, title: EVIL, description: EVIL, sentenceType: 'fine', fineAmount: 500, fineSuccess: 0, officerName: EVIL, createdAt: '2026-11-01 10:00:00' }] };
        m.responses['nui:printCitationPaper'] = { success: true, citationUid: 'CIT-1' };
        m.run("router.set('citations')"); await settle();
        let r = page(m, 'citations');
        setVal(r.querySelector('input'), 'Jo');
        await new Promise((res) => setTimeout(res, 350)); await settle();
        eq(m.calls('pf_mdt:searchCitizens').slice(-1)[0].query, 'Jo');
        r.querySelector('.pfp-row[data-citizen-id="CIT1"]').click(); await settle();
        r = page(m, 'citations');
        noInjection(m, 'citations', r);
        ok(/Unpaid \$500/.test(r.textContent), 'unpaid total');
        ok(/ended while the citizen was offline/.test(r.textContent), 'releasedOnLogin shown');
        btnByText(r, 'Print citation').click(); await settle();
        eq(m.posts.filter((p) => p.name === 'printCitationPaper').slice(-1)[0].body.sentenceId, 31);
    });

    await it('citations: the court tab pages pf_mdt:citations:list by order id and lists field citations apart', async () => {
        m.responses['pf_mdt:citations:list'] = (p) => p.after
            ? { ok: true, list: [{ orderId: 3, state: 'active', amount: 80, reason: 'Parking', issuedAt: 1700000000 }] }
            : { ok: true, next: 4, list: [{ orderId: 5, state: 'paid', amount: 150, paidAmount: 150, reason: EVIL, plate: EVIL, speed: 90, limit: 50, officerName: EVIL, issuedAt: 1700000000, contestUntil: 1800000000 },
                { orderId: 4, state: 'active', amount: 90, reason: 'Speeding', issuedAt: 1700000000 }],
                pending: [{ uid: 'F1', violation: EVIL, amount: 50, state: 'failed', error: EVIL, createdAt: 1700000000 }] };
        let r = page(m, 'citations');
        r.querySelector('.pfp-tab[data-tab="court"]').click(); await settle();
        r = page(m, 'citations');
        eq(m.calls('pf_mdt:citations:list').slice(-1)[0].citizenId, 'CIT1');
        noInjection(m, 'court citations', r);
        ok(r.querySelector('tr[data-order-id="5"]') && r.textContent.includes(EVIL), 'rows as text');
        ok(/not yet taken by the court system/.test(r.textContent) && r.querySelector('[data-citation-uid="F1"]'), 'field citations apart');
        btnByText(r, 'Load more').click(); await settle();
        eq(m.calls('pf_mdt:citations:list').slice(-1)[0].after, 4, 'cursor = last order id');
        ok(page(m, 'citations').querySelector('tr[data-order-id="3"]') && !btnByText(page(m, 'citations'), 'Load more'), 'next page appended, no more');
        m.responses['pf_mdt:citations:list'] = { ok: false, error: 'unavailable', message: 'The court system is not available right now' };
        page(m, 'citations').querySelector('.pfp-tab[data-tab="fines"]').click(); await settle();
        page(m, 'citations').querySelector('.pfp-tab[data-tab="court"]').click(); await settle();
        ok(page(m, 'citations').querySelector('.pfp-state-error') && /court system is not available/.test(page(m, 'citations').textContent), 'error state');
    });

    // ── plates and impound ──────────────────────────────────────────────────
    await it('vehicles: run plate reads RunPlate and the profile; flags, BOLOs, impound and ALPR rows are text', async () => {
        m.responses['police:server:runPlate'] = { ok: true, plate: 'ABC123', model: EVIL, owner: { citizenid: 'CIT1', name: EVIL, licence: { driver: 'valid' } },
            flags: ['STOLEN'], bolos: [4], fieldFlag: EVIL, impound: { kind: 'seizure', state: 'impounded', reason: EVIL, holdUntil: 1800000000, caseRef: EVIL } };
        m.responses['pf_mdt:getVehicleProfile'] = { plate: 'ABC123', lastSeenAt: '2026-11-01 10:00:00', lastSeenLocation: EVIL,
            activity: [{ type: 'alpr_hit', timestamp: '2026-11-01 10:00:00', location: EVIL, officerName: EVIL, referenceId: EVIL }] };
        m.responses['pf_mdt:vehicles:setFlag'] = { success: true, flags: ['STOLEN'] };
        m.run("PFMdtPages.open('vehicles_ext', { plate: 'abc123' })"); await settle();
        let r = page(m, 'vehicles_ext');
        eq(m.calls('police:server:runPlate').slice(-1)[0], 'ABC123', 'plate upper-cased, plain argument');
        eq(m.calls('pf_mdt:getVehicleProfile').slice(-1)[0].plate, 'ABC123');
        noInjection(m, 'plate check', r);
        ok(r.textContent.includes('BOLO #4') && r.textContent.includes('ALPR hit') && r.textContent.includes(EVIL), 'rows as text');
        const sel = r.querySelector('select[aria-label="Flag"]');
        eq(Array.from(sel.options).map((o) => o.value).join(','), ',STOLEN,BOLO', 'the server\'s flag list');
        sel.value = 'STOLEN';
        btnByText(r, 'Set flag').click(); await settle();
        const sf = m.calls('pf_mdt:vehicles:setFlag').slice(-1)[0];
        eq(sf.plate, 'ABC123'); eq(sf.flag, 'STOLEN');
    });

    await it('vehicles: a refused plate check shows the reason; the impound lot lists the hold', async () => {
        m.responses['police:server:runPlate'] = { ok: false, error: 'no_permission' };
        m.run("PFMdtPages.open('vehicles_ext', { plate: 'X1' })"); await settle();
        ok(/Your rank may not do that/.test(page(m, 'vehicles_ext').textContent));
        m.responses['police:GetImpoundedVehicles'] = [{ plate: 'IMP1', vehicle: EVIL, citizenid: 'CIT1', impound: { kind: 'seizure', reason: EVIL, holdUntil: 1800000000, caseRef: 'C-1' } }];
        page(m, 'vehicles_ext').querySelector('.pfp-tab[data-tab="impound"]').click(); await settle();
        const r = page(m, 'vehicles_ext');
        noInjection(m, 'impound lot', r);
        ok(r.querySelector('tr[data-plate="IMP1"]') && /Seizure/.test(r.textContent), 'row');
        ok(!btnByText(r, 'Release'), 'no release from the MDT (the lot checks presence)');
    });

    // ── mdt-server rework leftovers ─────────────────────────────────────────
    await it('leftovers: licence modal sends the reason; licence history is text', async () => {
        m.w.openLicenseModal(JSON.stringify({ type: 'Driver License', key: 'driver', citizenId: 'CIT1', citizenName: EVIL, isSuspended: false }));
        const reason = D.getElementById('licenseReasonInput');
        ok(reason, 'reason field');
        reason.value = 'DUI on Route 68';
        D.getElementById('suspendDurationSelect').value = '7';
        m.w.suspendLicense('CIT1', 'driver', 'Driver License'); await settle();
        const sp = m.posts.filter((p) => p.name === 'suspendLicense').slice(-1)[0].body;
        eq(sp.reason, 'DUI on Route 68'); eq(sp.durationDays, 7);
        const html = m.w.licenseActionsHtml([{ license_type: 'driver', action: 'suspend', days: 7, reason: EVIL, by_name: EVIL, by_job: 'police', at: '2026-11-01 10:00:00' }]);
        const div = D.createElement('div'); div.innerHTML = html;
        noInjection(m, 'licence history', div);
        ok(div.textContent.includes(EVIL) && /Suspended/.test(div.textContent), 'history as text');
    });

    await it('leftovers: protected_chief and other codes read as sentences in toasts; bail toast uses the server message', async () => {
        m.w.mdtToast('Save failed: protected_chief', 'error');
        ok(/department head/.test(D.getElementById('mdtToast').textContent), 'translated');
        const src = fs.readFileSync(path.join(RES, 'html', 'app-extended.js'), 'utf8');
        ok(!src.includes("mdtToast('Bail posted'"), 'no "Bail posted" for an offer');
        ok(src.includes('resp.message'), 'server message shown');
    });

    // ── wiring: client bridge, manifest, index.html ─────────────────────────
    await it('wiring: client bridge allowlist, permission answer, manifest and page tags', async () => {
        const client = fs.readFileSync(path.join(RES, 'client', 'main.lua'), 'utf8');
        ok(client.includes("RegisterNUICallback('pfMdtCall'"), 'bridge callback');
        ok(/PFMdtBridge\.allowed\[name\]/.test(client), 'only allowlisted names pass');
        for (const n of ['pf_mdt:cases:submit', 'pf_mdt:cases:deathRecord', 'pf_mdt:citations:list', 'pf_mdt:warrants:review', 'pf_mdt:bolos:clear', 'police:server:runPlate', 'police:GetImpoundedVehicles'])
            ok(client.includes(`'${n}'`), n + ' allowed');
        ok(/actions\.warrantApprove/.test(client) && /actions = actions/.test(client), 'rank answer per action');
        const mf = fs.readFileSync(path.join(RES, 'fxmanifest.lua'), 'utf8');
        for (const f of ['html/pages/cases.js', 'html/pages/custody.js', 'html/pages/pages_ext.css', 'client/pages_ext.lua']) ok(mf.includes(`'${f}'`), f + ' in manifest');
        const idx = fs.readFileSync(path.join(RES, 'html', 'index.html'), 'utf8');
        ok(idx.includes('https://cfx-nui-pfm-ui/html/tokens.css'), 'pfm-ui tokens');
        ok(idx.indexOf('src="pages/cases.js"') > idx.indexOf('src="app.js'), 'pages after app.js');
    });

    if (m.errors.length) { failed++; failures.push(`script errors: ${m.errors.slice(0, 5).join(' | ')}`); }
    console.log(`\n${passed} passed, ${failed} failed (b21 MDT records pages)`);
    if (failed) { failures.forEach((f) => console.log('  - ' + f)); process.exit(1); }
    process.exit(0);
})();
