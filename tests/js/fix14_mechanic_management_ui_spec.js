// Batch 14, pf-mechanicjob management app (html/tablet_module.js) in jsdom:
//  * MECH-1: the hire panel sends a job offer (no "offline supported" direct hire), says what a
//    refusal means, and lists the shop's offers with a Withdraw button for open ones;
//  * every server string in the Employees tab (names, ids, avatars, offer names) renders as text;
//  * MECH-8: the Settings tab has no location placement buttons any more, and the shop's name is
//    shown escaped in its input.
// Run: node js/fix14_mechanic_management_ui_spec.js
const fs = require('fs');
const path = require('path');
const { JSDOM } = require('jsdom');

const QB = path.resolve(__dirname, '..', '..');
const PF = path.resolve(QB, '..', '[pfscripts]');
const JQ = fs.readFileSync(path.join(PF, 'pf-devices/html/vendor/jquery-3.6.0.min.js'), 'utf8');
const MODULE = fs.readFileSync(path.join(PF, 'pf-mechanicjob/html/tablet_module.js'), 'utf8');

let passed = 0;
let failed = 0;
const failures = [];
async function it(name, fn) {
    try { await fn(); passed++; } catch (e) { failed++; failures.push(`${name}: ${e && e.stack || e}`); }
}
function eq(a, b, msg) { if (a !== b) throw new Error(`${msg || 'expected'}: ${JSON.stringify(b)}, got ${JSON.stringify(a)}`); }
function ok(v, msg) { if (!v) throw new Error(msg || 'expected truthy'); }
const tick = () => new Promise((r) => setTimeout(r, 0));

const EVIL = '"><img src=x onerror="window.__xss=1"><b id=pwn>x</b>\'';

function boot(answers) {
    const dom = new JSDOM('<!doctype html><html><body><div class="window-content" id="win"></div></body></html>', {
        runScripts: 'outside-only', url: 'https://cfx-nui-pf-tablet/index.html', pretendToBeVisual: true,
    });
    const win = dom.window;
    win.console = { log() {}, warn() {}, error() {} };
    const alerts = [];
    win.alert = (m) => alerts.push(String(m));
    const posts = [];
    win.eval(JQ);
    // NUI callbacks: answered from `answers` by endpoint name, recorded in `posts`
    win.$.post = (url, body, cb) => {
        const name = String(url).replace('https://pf-mechanicjob/', '');
        posts.push({ name, body: body ? JSON.parse(body) : null });
        const reply = answers[name];
        const value = typeof reply === 'function' ? reply(body ? JSON.parse(body) : null) : reply;
        const d = win.$.Deferred();
        setTimeout(() => { if (cb) cb(value); d.resolve(value); }, 0);
        return d.promise();
    };
    win.eval(MODULE);
    return { win, posts, alerts, $: win.$ };
}

(async () => {
    await it('the hire panel offers a job and lists the shop offers, all as text', async () => {
        const t = boot({
            'management:getOffers': [
                { id: 7, citizenid: 'ABC123', name: EVIL, status: 'pending', hoursLeft: 70 },
                { id: 8, citizenid: 'DEF456', name: 'Dee', status: 'declined' },
            ],
            'management:getEmployees': [],
        });
        const s = t.win.tabletMgmtState;
        s.activeTab = 'employees';
        s.employees = [{ citizenid: EVIL, name: EVIL, avatar: EVIL, role: EVIL, grade: 1, totalSales: 5 }];
        s.selectedEmployee = { citizenid: 'X', name: EVIL, avatar: '', role: 'employee', transactions: [{ id: EVIL, customer: EVIL, where: EVIL, total: 3 }] };
        s.jobOffers = [{ id: 7, citizenid: 'ABC123', name: EVIL, status: 'pending', hoursLeft: 70 }, { id: 8, citizenid: 'DEF456', name: 'Dee', status: 'declined' }];
        const $c = t.$('#win');
        t.win.MechanicTablet.renderManagement($c);
        const doc = t.win.document;
        eq(doc.querySelector('#pwn'), null, 'no injected element');
        eq(doc.querySelectorAll('img[src="x"]').length, 0, 'no injected image');
        ok(doc.body.textContent.includes('<b id=pwn>'), 'the payload is shown as text');
        const btn = doc.querySelector('#tablet-hire-btn');
        eq(btn.textContent.trim(), 'Send job offer');
        ok(!doc.querySelector('#tablet-hire-id').getAttribute('placeholder').includes('offline supported'));
        eq(doc.querySelectorAll('.mgmt-btn-cancel-offer').length, 1, 'Withdraw only for the open offer');
        ok(doc.body.textContent.includes('Waiting for an answer'));
        ok(doc.body.textContent.includes('Declined'));
    });

    await it('a refused offer says why; a sent one refreshes the offers list', async () => {
        let answer = { success: false, message: 'citizen_not_found' };
        const t = boot({ hireEmployee: () => answer, 'management:getOffers': [], 'management:cancelOffer': { success: true } });
        t.win.tabletMgmtState.activeTab = 'employees';
        const $c = t.$('#win');
        t.win.MechanicTablet.renderManagement($c);
        const doc = t.win.document;
        doc.querySelector('#tablet-hire-id').value = 'NOPE01';
        t.$('#tablet-hire-btn').trigger('click');
        await tick(); await tick();
        eq(t.alerts.pop(), 'No citizen with that ID.');
        answer = { success: true, message: 'offer_sent' };
        t.$('#tablet-hire-btn').trigger('click');
        await tick(); await tick();
        ok(t.alerts.pop().startsWith('Job offer sent'), 'told an offer was sent, not that someone was hired');
        const hire = t.posts.filter((p) => p.name === 'hireEmployee');
        eq(hire[1].body.citizenid, 'NOPE01');
        ok(t.posts.some((p) => p.name === 'management:getOffers'), 'offers reloaded');
    });

    await it('settings: no placement buttons, the shop name is escaped in its input', async () => {
        const t = boot({});
        const s = t.win.tabletMgmtState;
        s.activeTab = 'settings';
        s.businessSettings = { business_name: EVIL, blip_name: 'B', blip_color: 3 };
        t.win.MechanicTablet.renderManagement(t.$('#win'));
        const doc = t.win.document;
        eq(doc.querySelector('#mgmt-set-stash'), null);
        eq(doc.querySelector('#mgmt-set-duty'), null);
        eq(doc.querySelector('#pwn'), null);
        eq(doc.querySelector('#mgmt-biz-name').value, EVIL, 'the value round-trips as text');
    });

    console.log(`fix14_mechanic_management_ui_spec.js  (${passed} passed, ${failed} failed)`);
    for (const f of failures) console.log('  - ' + f);
    process.exit(failed ? 1 : 0);
})();
