// The Bank (pfm-banking), Crypto (pfm-crypto) and Management (pfm-management) NUI modules in a simulated
// browser (jsdom) on the pf-devices runtime: they mount on the tablet and the computer, render server
// strings as text only, and send only what the server reads (account refs, amounts and a per-action
// ref that is kept for a lost answer and renewed after a real answer).
// Run: node js/money_apps_spec.js
const fs = require('fs');
const path = require('path');
const { JSDOM } = require('jsdom');

const QB = path.resolve(__dirname, '..', '..');
const PF = path.resolve(QB, '..', '[pfscripts]');
const RUNTIME = fs.readFileSync(path.join(PF, 'pf-devices/html/runtime.js'), 'utf8');
const MODULES = [
    fs.readFileSync(path.join(QB, 'pfm-banking/html/apps/bank.js'), 'utf8'),
    fs.readFileSync(path.join(QB, 'pfm-crypto/html/apps/crypto.js'), 'utf8'),
    fs.readFileSync(path.join(QB, 'pfm-management/html/apps/boss.js'), 'utf8'),
];

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
const APPS = [
    { id: 'bank', name: 'Bank', kind: 'module', entry: 'https://cfx-nui-pfm-banking/html/apps/bank.js', styles: [] },
    { id: 'crypto', name: 'Crypto', kind: 'module', entry: 'https://cfx-nui-pfm-crypto/html/apps/crypto.js', styles: [] },
    { id: 'boss', name: 'Management', kind: 'module', entry: 'https://cfx-nui-pfm-management/html/apps/boss.js', styles: [] },
];

function makeWindow(device, handlers) {
    const dom = new JSDOM('<!doctype html><html><head></head><body><div id="shell"></div></body></html>', { runScripts: 'outside-only', url: 'https://cfx-nui-pf-tablet/html/index.html' });
    const win = dom.window;
    const rpcs = [];
    const waypoints = [];
    win.fetch = async (url, opts) => {
        const name = String(url).replace(/^https:\/\/[^/]+\//, '');
        const body = JSON.parse(opts && opts.body || '{}');
        let result = { ok: true };
        if (name === 'apps') result = { apps: APPS, store: [], categories: [] };
        else if (name === 'setWaypoint') waypoints.push(body);
        else if (name === 'rpc') {
            rpcs.push(body);
            const fn = handlers[`${body.app}.${body.method}`];
            result = fn ? fn(body.payload, rpcs) : { ok: false, error: 'unknown_method' };
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
    const button = (root, text) => [...root.querySelectorAll('button')].find((b) => b.textContent.trim() === text);
    const tab = (root, text) => [...root.querySelectorAll('.pf-tab')].find((t) => t.textContent === text);
    return { win, rpcs, notes, waypoints, button, tab, $: (sel) => win.document.querySelector(`[data-window] ${sel}`) };
}

const now = Math.floor(Date.now() / 1000);
function bankHandlers(extra) {
    return Object.assign({
        'bank.overview': () => ({ ok: true, me: { name: EVIL, citizenid: 'ME1' }, personal: { balance: 5000, cash: 120, iban: 'PF12345678' },
            accounts: [{ ref: 'acct:4', id: 4, label: EVIL, iban: 'PF90000004', type: 'shared', balance: 800, isOwner: true,
                perms: { withdraw: true, deposit: true, cards: true, manage: true },
                members: [{ citizenid: 'ME1', name: EVIL, owner: true, withdraw: true, deposit: true, cards: true, manage: true }, { citizenid: 'OT1', name: 'Otto', withdraw: false, deposit: true }] }],
            societies: [{ ref: 'society:mechanic', name: 'mechanic', label: EVIL, type: 'job', balance: 1000 }],
            finance: { score: 650, scoreMin: 300, scoreMax: 850, debt: 0 }, limits: { maxTransfer: 250000, dailyLimit: 1000000, dailyUsed: 0 },
            branches: [{ id: 1, label: EVIL, x: 10, y: 20, closed: true, reopensIn: 600, reason: 'robbery' }, { id: 2, label: 'Alta', x: 1, y: 2, closed: false }] }),
        'bank.statement': () => ({ ok: true, rows: [{ id: 9, at: now, amount: 25, direction: 'out', kind: 'transfer', reason: EVIL, note: EVIL, counterparty: { label: EVIL } }],
            hasMore: false, summary: { moneyIn: 0, moneyOut: 25, lines: 1 } }),
    }, extra || {});
}

(async () => {
    for (const device of ['tablet', 'computer']) {
        await it(`${device}: the bank renders server strings as text`, async () => {
            const env = makeWindow(device, bankHandlers());
            await env.win.PFApps.refresh();
            await env.win.PFApps.open('bank');
            await settle();
            const root = env.$('.pfb');
            ok(root, 'bank mounted');
            eq(root.querySelectorAll('img').length, 0, 'server text became HTML');
            ok(root.textContent.includes(EVIL), 'labels shown as text');
            ok(root.textContent.includes('$5,000'), 'personal balance');
            env.tab(root, 'Statements').click();
            await settle();
            eq(root.querySelectorAll('img').length, 0);
            ok(root.querySelector('table'), 'statement table');
            env.tab(root, 'Branches').click();
            await settle();
            ok(root.textContent.includes('reopens in 10 min'), 'closure countdown');
            env.button(root, 'Set waypoint').click();
            await settle();
            eq(env.waypoints[0].x, 10);
            eq(env.win.__xss, undefined, 'script ran');
        });
    }

    await it('bank: a transfer sends refs and an amount only; a lost answer keeps the ref, a refusal renews it', async () => {
        let answer = { ok: false, error: 'timeout' };
        const env = makeWindow('tablet', bankHandlers({ 'bank.transfer': () => answer }));
        await env.win.PFApps.refresh();
        await env.win.PFApps.open('bank', { to: { type: 'iban', iban: 'PF00000001' }, amount: 200 });
        await settle();
        const root = env.$('.pfb');
        const send = async () => {
            env.button(root, 'Review').click();
            await settle();
            env.button(root, 'Confirm').click();
            await settle();
        };
        await send();
        const first = env.rpcs.filter((r) => r.method === 'transfer')[0];
        eq(first.payload.from, 'personal');
        eq(first.payload.to.type, 'iban');
        eq(first.payload.to.iban, 'PF00000001');
        eq(first.payload.amount, 200);
        ok(/^[\w-]{8,40}$/.test(first.payload.ref), 'a ref the server accepts');
        ok(!('citizenid' in first.payload) && !('balance' in first.payload), 'no identity or balance from the client');
        await send();
        const second = env.rpcs.filter((r) => r.method === 'transfer')[1];
        eq(second.payload.ref, first.payload.ref, 'retry after a lost answer reuses the ref');
        answer = { ok: false, error: 'insufficient_funds' };
        await send();
        answer = { ok: true, message: 'Transferred' };
        await send();
        const all = env.rpcs.filter((r) => r.method === 'transfer');
        eq(all[2].payload.ref, first.payload.ref);
        ok(all[3].payload.ref !== first.payload.ref, 'after a refusal a new ref is used');
        ok(env.notes.some((n) => n.t === 'success'), 'success shown');
    });

    await it('bank: members dialog escapes names and sends permission flags only', async () => {
        const env = makeWindow('computer', bankHandlers({ 'bank.updateMember': () => ({ ok: true, message: 'Permissions updated' }) }));
        await env.win.PFApps.refresh();
        await env.win.PFApps.open('bank');
        await settle();
        const root = env.$('.pfb');
        env.button(root, 'Members').click();
        await settle();
        const dialog = root.querySelector('.pfb-dialog');
        ok(dialog, 'dialog open');
        eq(dialog.querySelectorAll('img').length, 0);
        env.button(dialog, 'Save').click();
        await settle();
        const upd = env.rpcs.find((r) => r.method === 'updateMember');
        eq(upd.payload.account, 'acct:4');
        eq(upd.payload.citizenid, 'OT1');
        eq(upd.payload.perms.can_deposit, true);
        eq(upd.payload.perms.can_withdraw, false);
    });

    await it('crypto: draws the history, buys with coins and a ref only, follows price pushes', async () => {
        const env = makeWindow('tablet', {
            'crypto.market': () => ({ ok: true, coin: 'qbit', label: 'Qbit', price: 100, refreshMinutes: 10, maxCoins: 10000,
                history: [{ at: now - 600, price: 90 }, { at: now - 300, price: 95 }, { at: now, price: 100 }], change: { from: 80, abs: 20, pct: 25 },
                wallet: { coins: 2, value: 200, walletId: EVIL }, bank: 1000, exchange: { x: 5, y: 6, rebooting: false } }),
            'crypto.history': () => ({ ok: true, trades: [{ side: 'buy', total: 200, coins: 2, price: 100, at: now }], transfers: [] }),
            'crypto.buy': () => ({ ok: true, coins: 1.5, total: 150 }),
        });
        await env.win.PFApps.refresh();
        await env.win.PFApps.open('crypto');
        await settle();
        const root = env.$('.pfx');
        ok(root, 'crypto mounted');
        eq(root.querySelectorAll('img').length, 0);
        ok(root.querySelector('polyline'), 'price line drawn');
        ok(root.textContent.includes('25%'), '24 h change');
        const input = root.querySelector('.pfx-trade input');
        input.value = '1.5';
        input.dispatchEvent(new env.win.Event('input'));
        env.button(root, 'Review purchase').click();
        await settle();
        env.button(root, 'Confirm buy').click();
        await settle();
        const buy = env.rpcs.find((r) => r.method === 'buy');
        eq(buy.payload.coins, 1.5);
        ok(/^[\w-]{8,40}$/.test(buy.payload.ref));
        eq(Object.keys(buy.payload).sort().join(','), 'coins,ref', 'no price from the client');
        env.win.PFApps.handleMessage({ action: 'pfapp:event', app: 'crypto', event: 'price', payload: { coin: 'qbit', price: 123, at: now } });
        await settle();
        ok(root.querySelector('.pfx-price').textContent.includes('123'), 'pushed price shown');
    });

    await it('management: staff ranks, firing and society money send ids, a rank and an amount only', async () => {
        const env = makeWindow('computer', {
            'boss.overview': () => ({ ok: true, job: { scope: 'job', name: 'mechanic', label: EVIL, grade: { level: 4, name: 'Owner' },
                grades: [{ level: 0, name: 'Trainee', payment: 50 }, { level: 1, name: EVIL, payment: 75 }, { level: 4, name: 'Owner', payment: 150, isboss: true }],
                balance: 1000, atOffice: false }, paycheck: { minutes: 10, fromSociety: false } }),
            'boss.members': () => ({ ok: true, members: [{ citizenid: 'ME1', name: 'Me', grade: { level: 4 }, isboss: true, online: true, me: true },
                { citizenid: 'EMP1', name: EVIL, grade: { level: 0, name: 'Trainee', payment: 50 }, online: false }] }),
            'boss.setGrade': () => ({ ok: true }),
            'boss.society': () => ({ ok: true, balance: 1000, atOffice: false, rows: [{ at: now, amount: 5, direction: 'in', reason: EVIL, counterparty: { label: EVIL } }] }),
            'boss.deposit': () => ({ ok: true, amount: 300, balance: 1300 }),
        });
        await env.win.PFApps.refresh();
        await env.win.PFApps.open('boss');
        await settle();
        const root = env.$('.pfm');
        ok(root, 'management mounted');
        eq(root.querySelectorAll('img').length, 0);
        const pick = root.querySelector('.pfm-rank');
        pick.value = '1';
        env.button(root, 'Set rank').click();
        await settle();
        const sg = env.rpcs.find((r) => r.method === 'setGrade');
        eq(sg.payload.scope, 'job');
        eq(sg.payload.citizenid, 'EMP1');
        eq(sg.payload.grade, 1);
        env.tab(root, 'Society account').click();
        await settle();
        eq(root.querySelectorAll('img').length, 0);
        const cash = root.querySelector('select option[value="cash"]');
        ok(cash.disabled, 'cash is only offered at the desk');
        const amount = root.querySelector('.pfm-money input');
        amount.value = '300';
        env.button(root, 'Deposit').click();
        await settle();
        env.button(root, 'Confirm').click();
        await settle();
        const dep = env.rpcs.find((r) => r.method === 'deposit');
        eq(dep.payload.amount, 300);
        eq(dep.payload.account, 'bank');
        eq(dep.payload.scope, 'job');
        ok(/^[\w-]{8,40}$/.test(dep.payload.ref));
        eq(env.win.__xss, undefined);
    });

    console.log(`money_apps_spec.js  (${passed} passed, ${failed} failed)`);
    failures.forEach((f) => console.log('  - ' + f));
    process.exit(failed ? 1 : 0);
})();
