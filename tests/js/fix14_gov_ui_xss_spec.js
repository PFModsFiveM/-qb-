// Batch 14, GOV-XSS-1 / G1 / G3 in the pf-government City Hall terminal (pf-government/html/script.js,
// the legacy desktop UI) in jsdom:
//  * every citizen, business, license, bill, staff, audit, announcement and law string renders as text:
//    a payload in a name, a note or an id never becomes an element, and the escape helper also
//    escapes quotes (it is used in attribute values);
//  * the tax "Edit" button has no inline onclick with the id in a JS string;
//  * the civilian profile offers identity, vehicle and record actions only to roles that have them;
//  * the website editor is offered only when the server says canEdit.
// Run: node js/fix14_gov_ui_xss_spec.js
const fs = require('fs');
const path = require('path');
const { JSDOM } = require('jsdom');

const QB = path.resolve(__dirname, '..', '..');
const PF = path.resolve(QB, '..', '[pfscripts]');
const HTML = fs.readFileSync(path.join(PF, 'pf-government/html/index.html'), 'utf8');
const SCRIPT = fs.readFileSync(path.join(PF, 'pf-government/html/script.js'), 'utf8');
const LIBS = ['rte.js', 'games.js'].map((f) => fs.readFileSync(path.join(PF, 'pf-government/html', f), 'utf8'));

let passed = 0;
let failed = 0;
const failures = [];
async function it(name, fn) {
    try { await fn(); passed++; } catch (e) { failed++; failures.push(`${name}: ${e && e.stack || e}`); }
}
function eq(a, b, msg) { if (a !== b) throw new Error(`${msg || 'expected'}: ${JSON.stringify(b)}, got ${JSON.stringify(a)}`); }
function ok(v, msg) { if (!v) throw new Error(msg || 'expected truthy'); }
const tick = () => new Promise((r) => setTimeout(r, 0));
async function settle() { for (let i = 0; i < 30; i++) await tick(); }

const EVIL = '"><img src=x onerror="window.__xss=1"><b id=pwn>x</b>\'';

function boot(responses) {
    const dom = new JSDOM(HTML.replace(/<script[^>]*src="[^"]*"[^>]*><\/script>/g, ''), {
        runScripts: 'outside-only', url: 'https://cfx-nui-pf-government/html/index.html', pretendToBeVisual: true,
    });
    const win = dom.window;
    win.GetParentResourceName = () => 'pf-government';
    win.alert = () => {};
    win.confirm = () => true;
    win.fetch = async (url, opts) => {
        const name = String(url).replace(/^https:\/\/[^/]+\//, '');
        const body = JSON.parse((opts && opts.body) || '{}');
        const r = responses[name];
        const result = typeof r === 'function' ? r(body) : (r || { ok: false, error: 'stub' });
        return { json: async () => result };
    };
    for (const lib of LIBS) win.eval(lib);
    win.eval(SCRIPT);   // (jsdom raises DOMContentLoaded itself once the page is parsed)
    return win;
}

function noInjection(win, root, where) {
    eq(root.querySelectorAll('img[src="x"], #pwn, [onerror]').length, 0, `${where}: a payload became an element`);
    eq(win.__xss, undefined, `${where}: script ran`);
}

function render(win, html) {
    const host = win.document.createElement('div');
    win.document.body.appendChild(host);
    host.innerHTML = html;
    return host;
}

(async () => {
    const win = boot({ 'user:getInfo': { ok: true, user: { name: 'Clerk', permissions: ['licenses', 'fines', 'audit'] } } });
    await settle();
    const hall = win.cityHall;
    ok(hall, 'the City Hall manager started');

    await it('the escape helper escapes quotes as well', async () => {
        eq(win.eval('govEsc(`<a href="x" title=\'y\'>&`)'), '&lt;a href=&quot;x&quot; title=&#39;y&#39;&gt;&amp;');
        eq(win.mayorBrowser.escapeHtml('"\''), '&quot;&#39;');
    });

    await it('civilians list: names, ids, dates, phones, nationality, job and licenses are text', async () => {
        hall.data.civilians = [{ name: EVIL, citizenId: EVIL, dob: EVIL, phone: EVIL, nationality: EVIL, job: EVIL, licenses: [EVIL] }];
        hall.data.civiliansTotal = 1;
        hall.data.civiliansQuery = EVIL;
        const host = render(win, hall.renderCivilians());
        noInjection(win, host, 'civilians');
        ok(host.textContent.includes('onerror="window.__xss=1"'), 'the payload shows as text');
        eq(host.querySelector('.civilian-row').dataset.citizenid, EVIL, 'attribute value intact');
        eq(host.querySelector('#civilian-search-input').value, EVIL);
    });

    await it('civilian profile: every field is text, and actions follow the role', async () => {
        hall.data.permissions = ['licenses', 'fines', 'audit'];   // a clerk
        hall.data.civilianProfile = {
            citizenId: EVIL, name: EVIL, firstname: EVIL, lastname: EVIL, dob: EVIL, phone: EVIL, nationality: EVIL, gender: EVIL, job: EVIL,
            profilePicture: EVIL, properties: [{ source: EVIL, address: EVIL }], vehicles: [{ plate: EVIL, vehicle: EVIL, garage: EVIL }],
            convictions: [{ id: EVIL, title: EVIL, prisonTime: EVIL }], incidents: [{ id: 1, incidentId: EVIL, title: EVIL, status: EVIL }],
        };
        hall.data.civilianJobs = [{ name: EVIL, label: EVIL }];
        for (const tab of ['overview', 'identity', 'vehicles', 'properties', 'criminal', 'licenses']) {
            hall.data.civilianProfileTab = tab;
            const host = render(win, hall.renderCivilianProfile());
            noInjection(win, host, 'profile ' + tab);
            if (tab === 'identity') {
                eq(host.querySelector('#civilian-firstname').value, EVIL);
                eq(host.querySelector('#civilian-save-identity'), null, 'no identity editing for a clerk');
                eq(host.querySelector('#civilian-save-job'), null);
            }
            if (tab === 'vehicles') eq(host.querySelectorAll('[data-seize-plate]').length, 0, 'no seizing for a clerk');
            if (tab === 'criminal') {
                eq(host.querySelectorAll('[data-record-type]').length, 0, 'no record deletion for a clerk');
                eq(host.querySelector('#civilian-clear-convictions'), null);
            }
            if (tab === 'licenses') ok(!host.querySelector('[data-license-key]').disabled, 'a clerk manages licenses');
        }
        hall.data.permissions = ['all'];
        hall.data.civilianProfileTab = 'identity';
        ok(render(win, hall.renderCivilianProfile()).querySelector('#civilian-save-identity'), 'the mayor edits identities');
        hall.data.civilianProfileTab = 'criminal';
        const host = render(win, hall.renderCivilianProfile());
        eq(host.querySelectorAll('[data-record-type]').length, 2);
        eq(host.querySelector('[data-record-type]').dataset.recordId, EVIL, 'attribute value intact');
        hall.data.permissions = ['civilians'];
        eq(render(win, hall.renderCivilianProfile()).querySelectorAll('[data-record-type]').length, 0, 'records need the records permission');
    });

    await it('licenses, fines, staff, audit, announcements, laws and taxes render text', async () => {
        hall.data.licenses = [{ id: EVIL, owner_name: EVIL, owner_id: EVIL, license_type: EVIL, status: EVIL, issued_at: EVIL, expires_at: EVIL }];
        hall.data.fines = [{ id: EVIL, target_id: EVIL, description: EVIL, amount: 5, due_date: EVIL, status: EVIL }];
        hall.data.staff = [{ name: EVIL, role: EVIL, permissions: [EVIL], active: 1 }];
        hall.data.auditLog = [{ timestamp: EVIL, user: EVIL, action: EVIL, category: EVIL, details: EVIL }];
        hall.data.announcements = [{ author: EVIL, title: EVIL, body: EVIL, created_at: EVIL }];
        hall.data.laws = [{ id: EVIL, title: EVIL, category: EVIL, status: EVIL, source: 'x' }];
        hall.data.taxes = [{ id: EVIL, name: EVIL, description: EVIL, rate: EVIL, min: EVIL, max: EVIL, lastChangedBy: EVIL, lastChangedAt: EVIL, enabled: true }];
        for (const page of ['renderLicenses', 'renderFines', 'renderStaff', 'renderAuditLog', 'renderAnnouncements', 'renderLaws', 'renderTaxes']) {
            const host = render(win, hall[page]());
            noInjection(win, host, page);
            ok(host.textContent.includes('<img src=x'), page + ': shows the payload as text');
        }
        const taxes = render(win, hall.renderTaxes());
        eq(taxes.querySelectorAll('[onclick*="editTax"]').length, 0, 'no inline handler with the id in a JS string');
        eq(taxes.querySelector('[data-tax-edit]').dataset.taxEdit, EVIL);
    });

    await it('license details and utility notices render text', async () => {
        hall.data.utilities = { power: {}, water: {}, accounts: [{ property_id: EVIL, owner_name: EVIL, serviceLabel: EVIL, property_type: EVIL, serviceType: EVIL, debt: 1 }] };
        const host = render(win, hall.renderUtilities());
        noInjection(win, host, 'utilities');
        const notice = host.querySelector('.utility-notice-btn');
        if (notice) eq(notice.dataset.ownerName, EVIL);
    });

    await it('the business registry renders names, owners, types, notes and ids as text', async () => {
        const biz = win.businessesManager;
        biz.data.businesses = [{ business_id: EVIL, business_name: EVIL, owner_name: EVIL, owner_id: EVIL, business_type: EVIL, notes: EVIL,
            compliance_status: EVIL, license_status: EVIL, business_status: 'active', location_address: EVIL }];
        biz.data.stats = biz.data.stats || {};
        for (const html of [biz.renderRegistry(), biz.renderBusinessDetails(biz.data.businesses[0]), biz.renderCompliance(), biz.renderEmployees(), biz.renderTaxes()]) {
            const host = render(win, html);
            noInjection(win, host, 'businesses');
        }
        eq(render(win, biz.renderRegistry()).querySelector('tr[data-business-id]').dataset.businessId, EVIL);
    });

    const portal = (canEdit) => boot({
        'website:getState': { ok: true, state: {}, canEdit },
        'gov:getAnnouncements': { ok: true, data: [] },
        'law:getAll': { ok: true, laws: [] },
        'tax:getAll': { ok: true, taxes: [] },
        'law:getCategories': { ok: true, categories: [] },
        'user:getInfo': { ok: true, user: { permissions: [] } },
    });
    await it('the website editor is offered only when the server says the role may edit', async () => {
        for (const canEdit of [false, true]) {
            const w = portal(canEdit);
            await settle();
            const host = w.document.createElement('div');
            w.document.body.appendChild(host);
            await w.mayorBrowser.renderGovPortal(host, 'https://los-santos.gov');
            await settle();
            eq(!!host.querySelector('.gov-site-edit-toggle'), canEdit, 'edit toggle ' + canEdit);
            eq(!!host.querySelector('.gov-site-editor-drawer'), canEdit, 'editor drawer ' + canEdit);
            eq(w.mayorBrowser.websiteCanEdit, canEdit);
        }
    });

    console.log(`fix14_gov_ui_xss_spec: ${passed} passed, ${failed} failed`);
    if (failed) { console.log(failures.join('\n\n')); process.exit(1); }
    process.exit(0);   // the page's clocks keep timers running
})();
