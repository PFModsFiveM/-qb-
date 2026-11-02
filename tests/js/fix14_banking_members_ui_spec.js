// Batch 14, BANK-1 / X-9 in the two banking screens: they offer only what the server would allow.
//  * Bank app (pfm-banking/html/apps/bank.js) on the pf-devices runtime in jsdom: the members dialog
//    follows the server's per-row flags (edit, remove, grant.<right>), a member may leave an account.
//  * Bank screen (pfm-banking/html/script.js + index.html, Vue 3): its methods run on a stub Vue, and the
//    template binds every permission box, the remove button and the card buttons to those flags.
// Run: node js/fix14_banking_members_ui_spec.js
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { JSDOM } = require('jsdom');

const QB = path.resolve(__dirname, '..', '..');
const PF = path.resolve(QB, '..', '[pfscripts]');
const RUNTIME = fs.readFileSync(path.join(PF, 'pf-devices/html/runtime.js'), 'utf8');
const BANK_APP = fs.readFileSync(path.join(QB, 'pfm-banking/html/apps/bank.js'), 'utf8');
const SCREEN = fs.readFileSync(path.join(QB, 'pfm-banking/html/script.js'), 'utf8');
const TEMPLATE = fs.readFileSync(path.join(QB, 'pfm-banking/html/index.html'), 'utf8');

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
const APPS = [{ id: 'bank', name: 'Bank', kind: 'module', entry: 'https://cfx-nui-pfm-banking/html/apps/bank.js', styles: [] }];

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
            result = fn ? fn(body.payload, rpcs) : { ok: false, error: 'unknown_method' };
        }
        return { json: async () => result };
    };
    const origAppend = win.document.head.appendChild.bind(win.document.head);
    win.document.head.appendChild = (el) => { const r = origAppend(el); if (el.tagName === 'SCRIPT') setTimeout(() => el.onload && el.onload(), 0); return r; };
    win.jQuery = function () {};
    win.eval(RUNTIME);
    win.eval(BANK_APP);
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
    const buttons = (root, text) => [...root.querySelectorAll('button')].filter((b) => b.textContent.trim() === text);
    return { win, rpcs, notes, buttons, $: (sel) => win.document.querySelector(`[data-window] ${sel}`) };
}

// The bookkeeper's view: a manager who is not the owner and holds deposit only.
function overview(extra) {
    const member = (cid, name, rights, flags) => Object.assign({ citizenid: cid, name }, rights, flags);
    const r = (w, d, c, m) => ({ withdraw: !!w, deposit: !!d, cards: !!c, manage: !!m });
    return Object.assign({
        ok: true, me: { name: 'Bea Keeper', citizenid: 'BOOK1' }, personal: { balance: 100, cash: 0, iban: 'PF12345678' },
        accounts: [{ ref: 'acct:7', id: 7, label: EVIL, iban: 'PF70000001', type: 'business', balance: 20000, isOwner: false,
            perms: { withdraw: false, deposit: true, cards: false, manage: true },
            members: [
                member('OWN1', 'Olive Owner', r(1, 1, 1, 1), { owner: true, edit: false, remove: false, grant: r() }),
                member('BOOK1', EVIL, r(0, 1, 0, 1), { self: true, edit: false, remove: true, grant: r() }),
                member('MGR2', 'Max Manager', r(1, 1, 1, 1), { edit: false, remove: false, grant: r() }),
                member('PLN1', 'Pat Plain', r(0, 1, 0, 0), { edit: true, remove: true, grant: r(0, 1, 0, 0) }),
            ] },
        { ref: 'acct:8', id: 8, label: 'Club', iban: 'PF70000002', type: 'shared', balance: 50, isOwner: true,
            perms: { withdraw: true, deposit: true, cards: true, manage: true }, members: [] }],
        societies: [], finance: { score: 650, debt: 0 }, limits: {}, branches: [],
    }, extra || {});
}

function rowOf(dialog, name) {
    return [...dialog.querySelectorAll('.pf-list-item')].find((el) => el.querySelector('.pf-strong') && el.querySelector('.pf-strong').textContent === name);
}
function box(row, label) {
    const l = [...row.querySelectorAll('label.pfb-check')].find((x) => x.textContent.trim() === label);
    return l && l.querySelector('input');
}

(async () => {
    await it('bank app: a non-owner manager gets no controls on their own row, the owner or another manager', async () => {
        const env = makeWindow('tablet', { 'bank.overview': () => overview() });
        await env.win.PFApps.refresh();
        await env.win.PFApps.open('bank');
        await settle();
        const root = env.$('.pfb');
        env.buttons(root, 'Members')[0].click();
        await settle();
        const dialog = root.querySelector('.pfb-dialog');
        ok(dialog, 'dialog open');
        eq(dialog.querySelectorAll('img').length, 0, 'names are text');
        const mine = rowOf(dialog, EVIL);
        ok(mine, 'own row shown');
        eq(env.buttons(mine, 'Save').length, 0, 'no Save on the own row');
        eq(env.buttons(mine, 'Leave').length, 1, 'but Leave');
        ok(['Deposit', 'Withdraw', 'Cards', 'Manage'].every((l) => box(mine, l).disabled), 'own boxes locked');
        const mgr = rowOf(dialog, 'Max Manager');
        eq(env.buttons(mgr, 'Save').length, 0);
        eq(env.buttons(mgr, 'Remove').length, 0, 'another manager cannot be removed');
        ok(box(mgr, 'Withdraw').disabled && box(mgr, 'Manage').disabled);
        const owner = rowOf(dialog, 'Olive Owner');
        eq(env.buttons(owner, 'Save').length + env.buttons(owner, 'Remove').length, 0);
        eq(env.win.__xss, undefined);
    });

    await it('bank app: on a plain member only the rights the manager holds can be switched', async () => {
        const env = makeWindow('computer', { 'bank.overview': () => overview(), 'bank.updateMember': () => ({ ok: true, message: 'Permissions updated' }) });
        await env.win.PFApps.refresh();
        await env.win.PFApps.open('bank');
        await settle();
        const root = env.$('.pfb');
        env.buttons(root, 'Members')[0].click();
        await settle();
        const dialog = root.querySelector('.pfb-dialog');
        const plain = rowOf(dialog, 'Pat Plain');
        ok(!box(plain, 'Deposit').disabled, 'deposit can be switched');
        ok(box(plain, 'Withdraw').disabled, 'withdraw is locked: the manager does not hold it');
        ok(box(plain, 'Cards').disabled);
        ok(box(plain, 'Manage').disabled, 'only the owner grants management');
        box(plain, 'Deposit').checked = false;
        env.buttons(plain, 'Save')[0].click();
        await settle();
        const upd = env.rpcs.find((r) => r.method === 'updateMember');
        eq(upd.payload.citizenid, 'PLN1');
        eq(upd.payload.perms.can_deposit, false);
        eq(upd.payload.perms.can_withdraw, false);
        eq(upd.payload.perms.can_manage, false);
        eq(env.buttons(plain, 'Remove').length, 1, 'a plain member can be removed');
    });

    await it('bank app: a member leaves an account after confirming; the owner gets no Leave button', async () => {
        let left = false;
        const env = makeWindow('tablet', {
            'bank.overview': () => (left ? overview({ accounts: overview().accounts.slice(1) }) : overview()),
            'bank.removeMember': (p) => { left = true; return { ok: true, message: 'You left ' + p.account }; },
        });
        await env.win.PFApps.refresh();
        await env.win.PFApps.open('bank');
        await settle();
        const root = env.$('.pfb');
        const leave = env.buttons(root, 'Leave');
        eq(leave.length, 1, 'one Leave: only on the account the player does not own');
        leave[0].click();
        await settle();
        eq(env.rpcs.filter((r) => r.method === 'removeMember').length, 0, 'nothing sent before the confirmation');
        const confirm = env.buttons(root, 'Confirm')[0];
        ok(confirm, 'asks first');
        ok(!root.querySelector('.pfb-dialog').innerHTML.includes('<img'), 'the label is text in the question');
        confirm.click();
        await settle();
        const rm = env.rpcs.find((r) => r.method === 'removeMember');
        eq(rm.payload.account, 'acct:7');
        eq(rm.payload.citizenid, 'BOOK1', 'leaving names the player themselves');
        ok(env.notes.some((n) => n.t === 'success'));
    });

    // ── bank screen (Vue) ─────────────────────────────────────────────
    function screenOptions() {
        let options = null;
        const sandbox = {
            Vue: { createApp(o) { options = o; return { mount() {} }; } },
            window: { addEventListener() {} }, document: { addEventListener() {}, documentElement: { style: {} } },
            console, setTimeout, clearTimeout, navigator: {},
        };
        vm.createContext(sandbox);
        vm.runInContext(SCREEN, sandbox);
        ok(options && options.methods, 'the screen registered its Vue app');
        return options;
    }
    function screen(state) {
        const o = screenOptions();
        const self = Object.assign(o.data(), state || {});
        Object.keys(o.methods).forEach((k) => { self[k] = o.methods[k].bind(self); });
        Object.defineProperty(self, 'selectedAccount', { get() { return self.accountsData.accounts.find((a) => a.id === self.selectedAccRef) || null; } });
        self.posts = [];
        self.post = (name, data) => { self.posts.push({ name, data }); return Promise.resolve({ data: { success: true, message: 'ok' } }); };
        self.addNotification = () => {};
        self.refreshAccounts = () => {};
        return self;
    }

    await it('bank screen: locked rights cannot be toggled and nothing is sent for them', async () => {
        const plain = { citizenid: 'PLN1', can_withdraw: 0, can_deposit: 1, can_cards: 0, can_manage: 0, canEdit: true, canRemove: true,
            canSet: { can_withdraw: false, can_deposit: true, can_cards: false, can_manage: false } };
        const mine = { citizenid: 'BOOK1', can_withdraw: 0, can_deposit: 1, can_cards: 0, can_manage: 1, canEdit: false, canRemove: true, canSet: {} };
        const s = screen({ selectedAccRef: 7, accountsData: { myCitizenid: 'BOOK1', accounts: [{ id: 7, isOwner: false, owner: 'OWN1', members: [plain, mine] }] } });
        ok(s.permLocked(plain, 'can_withdraw'));
        ok(s.permLocked(plain, 'can_manage'));
        ok(!s.permLocked(plain, 'can_deposit'));
        ok(s.permLocked(mine, 'can_deposit'), 'own row locked');
        s.togglePerm(plain, 'can_withdraw');
        s.togglePerm(mine, 'can_deposit');
        eq(s.posts.length, 0, 'locked toggles send nothing');
        eq(plain.can_withdraw, 0);
        s.togglePerm(plain, 'can_deposit');
        eq(s.posts.length, 1);
        eq(s.posts[0].name, 'updateMember');
        eq(s.posts[0].data.perms.can_deposit, false);
        ok(s.isMe(mine) && !s.isMe(plain));
        // a row without flags (older answer) stays usable: the server still decides
        ok(!s.permLocked({ citizenid: 'X' }, 'can_deposit'));
    });

    await it('bank screen: leaving sends the player themselves and only for an account they do not own', async () => {
        const s = screen({ selectedAccRef: 7, accountsData: { myCitizenid: 'BOOK1', accounts: [{ id: 7, isOwner: false, owner: 'OWN1' }, { id: 8, isOwner: true, owner: 'BOOK1' }] } });
        s.leaveSelected();
        await settle();
        eq(s.posts.length, 1);
        eq(s.posts[0].name, 'removeMember');
        eq(s.posts[0].data.accountId, 7);
        eq(s.posts[0].data.citizenid, 'BOOK1');
        eq(s.selectedAccRef, 'personal', 'back to the personal account');
        s.selectedAccRef = 8;
        s.leaveSelected();
        await settle();
        eq(s.posts.length, 1, 'the owner cannot leave');
    });

    await it('bank screen template: boxes, remove, leave and card buttons follow the server flags', async () => {
        for (const right of ['can_deposit', 'can_withdraw', 'can_cards', 'can_manage']) {
            ok(TEMPLATE.includes(`:disabled="permLocked(m, '${right}')" @change="togglePerm(m, '${right}')"`), `${right} box bound to permLocked`);
        }
        ok(TEMPLATE.includes('v-if="m.canRemove !== false && !isMe(m)" class="member-remove"'), 'remove button follows canRemove');
        ok(/v-if="selectedAccount && !selectedAccount\.isOwner"[^>]*>[\s\S]{0,400}@click="leaveSelected"/.test(TEMPLATE), 'leave only for non-owners');
        const cardActions = TEMPLATE.slice(TEMPLATE.indexOf('<template v-if="currentWalletCard.card.canManage !== false">'));
        ok(cardActions.length > 0 && cardActions.indexOf('toggleLockCard') < cardActions.indexOf('</template>')
            && cardActions.indexOf('cancelWalletCard') < cardActions.indexOf('</template>'), 'card lock and cancel only on cards the viewer may manage');
    });

    console.log(`fix14_banking_members_ui_spec.js  (${passed} passed, ${failed} failed)`);
    failures.forEach((f) => console.log('  - ' + f));
    process.exit(failed ? 1 : 0);
})();
