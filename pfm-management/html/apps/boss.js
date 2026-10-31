// Management (pfm-management) on pf-devices: the staff, ranks, wages and society account of the job
// and/or gang the player is boss of. The server decides everything (who is boss, who may be ranked or
// fired, who stands close enough to be hired, what the society holds); the module sends ids, a rank,
// an amount and a per-action `ref` for money (a retried request never moves money twice; a changed
// request gets a new ref).
(function () {
    const ERRORS = {
        not_boss: 'You are not the boss here', not_member: 'That person is not on your staff', outranks_you: 'They outrank you',
        grade_above_yours: 'You cannot give a rank above your own', unknown_grade: 'That rank does not exist', bad_grade: 'Choose a rank',
        cannot_change_self: 'You cannot change your own rank', cannot_fire_self: 'You cannot fire yourself', cannot_hire_self: 'You cannot hire yourself',
        too_far: 'They must stand next to you', already_member: 'They are already on your staff', no_player: 'That person is not in the city',
        bad_amount: 'Enter a whole amount of at least $1', insufficient_funds: 'Not enough money for that', not_at_office: 'Cash is handled at your office desk',
        slow_down: 'Wait a moment between two transactions', already_processed: 'This transaction was already processed', bank_unavailable: 'The bank is not responding',
        not_authorized: 'You may not use this account', bad_request: 'That request was not valid', server_error: 'Something went wrong. Try again.',
        request_failed: 'No answer. Try again: it will not be sent twice.', timeout: 'No answer. Try again: it will not be sent twice.',
        in_progress: 'Your last transaction is still running. Try again in a moment.', rate_limited: 'Too many requests, slow down',
    };
    // answers after which the action may still run or was not run at all: the same action keeps its ref
    const RETRYABLE = { request_failed: true, timeout: true, in_progress: true, busy: true, slow_down: true, rate_limited: true };
    function newRef() { return ('m' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 12)).slice(0, 40); }
    // The ref of one money action. It is reused only to resend the exact same action (same fingerprint)
    // after a retryable answer; a changed action always gets a fresh ref, so it can never be answered
    // with the earlier action's result.
    function refKeeper() {
        let kept = null;
        return {
            take(print) { return kept && kept.print === print ? kept.ref : newRef(); },
            settle(ref, print, res) { kept = !(res && res.ok) && (!res || RETRYABLE[res.error]) ? { ref, print } : null; },
        };
    }
    function when(at) {
        if (!at) return '';
        const d = new Date(at * 1000);
        return d.toLocaleDateString([], { day: 'numeric', month: 'short' }) + ' ' + d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    }
    function errorText(res) { return (res && ERRORS[res.error]) || (res && res.message) || 'That did not work'; }

    PFApps.register('boss', {
        mount(container, ctx) {
            const { h, money } = ctx;
            const state = { data: null, scope: null, tab: 'staff', members: null, nearby: null, society: null, busy: false, amount: '', account: 'bank' };
            const refs = refKeeper();
            const sub = h('div.pf-app-sub', '');
            const scopes = h('div.pfm-scopes');
            const tabs = h('div.pf-tabs');
            const body = h('div.pf-app-body.pf-stack');
            const root = h('div.pf-app.pfm',
                h('div.pf-app-header', h('div.pf-app-title', h('span.pf-icon', '💼'), h('div', 'Management', sub)),
                    h('button.pf-btn.sm', { onclick: () => load() }, 'Refresh')),
                scopes, tabs, body);
            container.appendChild(root);

            function current() { return state.data && state.data[state.scope]; }

            async function load() {
                const res = await ctx.rpc('overview');
                if (!res || !res.ok) { body.innerHTML = ''; body.appendChild(h('div.pf-empty', errorText(res))); return; }
                state.data = res;
                if (!state.scope || !res[state.scope]) state.scope = res.job ? 'job' : (res.gang ? 'gang' : null);
                if (!state.scope) { body.innerHTML = ''; body.appendChild(h('div.pf-empty', 'You are not the boss of a company or a gang.')); return; }
                await loadTab();
            }
            async function loadTab() {
                const scope = state.scope;
                if (state.tab === 'staff') {
                    const r = await ctx.rpc('members', { scope });
                    state.members = r && r.ok ? r.members : null;
                    if (!r || !r.ok) ctx.notify(errorText(r), 'error');
                } else if (state.tab === 'hire') {
                    const r = await ctx.rpc('nearby', { scope });
                    state.nearby = r && r.ok ? r.players : [];
                } else if (state.tab === 'society') {
                    const r = await ctx.rpc('society', { scope });
                    state.society = r && r.ok ? r : { error: r };
                }
                render();
            }

            function render() {
                const c = current();
                if (!c) return;
                sub.textContent = `${c.label} · ${c.grade.name || 'Grade ' + c.grade.level}`;
                scopes.innerHTML = '';
                if (state.data.job && state.data.gang) {
                    [['job', 'Company: ' + state.data.job.label], ['gang', 'Gang: ' + state.data.gang.label]].forEach(([id, label]) =>
                        scopes.appendChild(h('button.pf-btn.sm' + (state.scope === id ? '.primary' : ''), { onclick: () => { state.scope = id; state.members = state.nearby = state.society = null; loadTab(); } }, label)));
                }
                tabs.innerHTML = '';
                [['staff', 'Staff'], ['hire', 'Hire'], ['ranks', 'Ranks & wages'], ['society', 'Society account']].forEach(([id, label]) =>
                    tabs.appendChild(h('div.pf-tab' + (state.tab === id ? '.active' : ''), { onclick: () => { state.tab = id; render(); loadTab(); } }, label)));
                body.innerHTML = '';
                body.appendChild(({ staff: viewStaff, hire: viewHire, ranks: viewRanks, society: viewSociety })[state.tab]());
            }

            function gradeName(level) {
                const g = current().grades.find((x) => x.level === level);
                return g ? g.name : 'Grade ' + level;
            }

            function viewStaff() {
                const c = current();
                if (!state.members) return h('div.pfapp-loading', 'Loading staff…');
                const list = h('div.pf-list');
                if (!state.members.length) list.appendChild(h('div.pf-empty', 'Nobody on the staff yet.'));
                const myLevel = c.grade.level;
                state.members.forEach((m) => {
                    const canAct = !m.me && m.grade.level <= myLevel;
                    const pick = h('select.pf-select.pfm-rank', c.grades.filter((g) => g.level <= myLevel).map((g) => h('option', { value: String(g.level) }, `${g.level} · ${g.name}`)));
                    pick.value = String(m.grade.level);
                    list.appendChild(h('div.pf-list-item',
                        h('div.pf-stack.pfm-who',
                            h('div.pf-row', h('span.pfm-dot' + (m.online ? '.on' : '')), h('span.pf-strong', m.name || m.citizenid),
                                m.me ? h('span.pf-badge.accent', 'You') : null, m.isboss ? h('span.pf-badge.warn', 'Boss') : null,
                                m.onduty ? h('span.pf-badge.ok', 'On duty') : null),
                            h('div.pf-small.pf-muted', (m.grade.name || gradeName(m.grade.level)) + (m.grade.payment != null ? ' · ' + money(m.grade.payment) + ' per paycheck' : ''))),
                        canAct ? h('div.pfm-actions', pick,
                            h('button.pf-btn.sm', { disabled: state.busy, onclick: () => act('setGrade', { scope: state.scope, citizenid: m.citizenid, grade: Number(pick.value) }, 'Rank updated') }, 'Set rank'),
                            h('button.pf-btn.sm.danger', { disabled: state.busy, onclick: () => confirmThen(`Remove ${m.name || m.citizenid} from ${c.label}?`, () => act('fire', { scope: state.scope, citizenid: m.citizenid }, 'Removed from the staff')) }, state.scope === 'gang' ? 'Expel' : 'Fire'))
                            : h('span.pf-small.pf-muted', m.me ? 'Your own rank is set by your superior' : 'Ranked above you')));
                });
                return h('div.pf-stack', h('div.pf-small.pf-muted', `${state.members.length} on the staff · ${state.members.filter((m) => m.online).length} in the city`), list);
            }

            function viewHire() {
                const list = h('div.pf-list');
                if (!state.nearby) return h('div.pfapp-loading', 'Looking around…');
                if (!state.nearby.length) list.appendChild(h('div.pf-empty', 'Nobody is standing next to you.'));
                state.nearby.forEach((p) => list.appendChild(h('div.pf-list-item', h('span.pf-strong', p.name),
                    h('button.pf-btn.sm.primary', { disabled: state.busy, onclick: () => act('hire', { scope: state.scope, id: p.id }, 'Hired') }, 'Hire'))));
                return h('div.pf-stack',
                    h('div.pf-row.between', h('div.pf-small.pf-muted', 'To hire someone, they must stand next to you. They start at the lowest rank.'),
                        h('button.pf-btn.sm', { onclick: loadTab }, 'Look again')),
                    list);
            }

            function viewRanks() {
                const c = current();
                const pay = state.data.paycheck || {};
                const tbody = h('tbody', c.grades.map((g) => h('tr', h('td', String(g.level)), h('td', g.name, g.isboss ? h('span.pf-badge.warn', 'Boss') : null),
                    h('td', g.payment != null ? money(g.payment) : '—'))));
                return h('div.pf-stack',
                    h('div.pf-small.pf-muted', `Paychecks every ${pay.minutes || 10} minutes, paid ${pay.fromSociety ? 'from the society account' : 'by the city'}. Wages per rank are set by the city.`),
                    c.grades.length ? h('table.pf-table', h('thead', h('tr', h('th', 'Rank'), h('th', 'Name'), h('th', 'Wage'))), tbody) : h('div.pf-empty', 'No ranks defined.'));
            }

            function viewSociety() {
                const s = state.society;
                if (!s) return h('div.pfapp-loading', 'Loading the account…');
                if (s.error) return h('div.pf-empty', errorText(s.error));
                const amountIn = h('input.pf-input', { type: 'number', min: 1, step: 1, value: state.amount, placeholder: 'Amount', oninput: (e) => { state.amount = e.target.value; } });
                const acct = h('select.pf-select', h('option', { value: 'bank' }, 'My bank account'), h('option', { value: 'cash', disabled: s.atOffice ? null : true }, s.atOffice ? 'Cash (at the desk)' : 'Cash (only at your office desk)'));
                acct.value = s.atOffice ? state.account : 'bank';
                acct.onchange = () => { state.account = acct.value; };
                const lines = h('div.pf-list', (s.rows || []).map((r) => h('div.pf-list-item',
                    h('div', h('div', (r.direction === 'in' ? 'From ' : 'To ') + ((r.counterparty && r.counterparty.label) || 'Unknown')), h('div.pf-small.pf-muted', [when(r.at), r.reason].filter(Boolean).join(' · '))),
                    h('div.pf-strong.' + (r.direction === 'in' ? 'pfm-in' : 'pfm-out'), (r.direction === 'in' ? '+' : '−') + money(r.amount)))));
                return h('div.pf-stack',
                    h('div.pf-card.pf-stat', h('div.pf-stat-value', money(s.balance)), h('div.pf-stat-label', current().label + ' balance')),
                    h('div.pf-card.pf-stack',
                        h('div.pf-row.pfm-money', amountIn, acct),
                        h('div.pfm-actions',
                            h('button.pf-btn', { disabled: state.busy, onclick: () => money_('deposit', amountIn.value, acct.value) }, 'Deposit'),
                            h('button.pf-btn.primary', { disabled: state.busy, onclick: () => money_('withdraw', amountIn.value, acct.value) }, 'Withdraw'))),
                    h('div.pf-row.between', h('div.pf-strong', 'Recent activity'), h('button.pf-btn.sm.ghost', { onclick: () => ctx.openApp('bank', { tab: 'statements', account: 'society:' + current().name }) }, 'Full statement')),
                    (s.rows || []).length ? lines : h('div.pf-small.pf-muted', 'No activity yet.'));
            }

            async function money_(direction, value, account) {
                const amount = Math.floor(Number(value));
                if (!(amount >= 1) || amount !== Number(value)) { ctx.notify(ERRORS.bad_amount, 'error'); return; }
                if (state.busy) return;
                if (!(await confirmBox(`${direction === 'deposit' ? 'Deposit' : 'Withdraw'} ${money(amount)} ${direction === 'deposit' ? 'from' : 'to'} your ${account === 'cash' ? 'cash' : 'bank account'}?`))) return;
                state.busy = true;
                render();
                const scope = state.scope;
                const print = JSON.stringify([scope, direction, amount, account]);
                const ref = refs.take(print);
                const res = await ctx.rpc(direction, { scope, amount, account, ref });
                refs.settle(ref, print, res);
                state.busy = false;
                if (res && res.ok) {
                    const done = `${direction === 'deposit' ? 'Deposited' : 'Withdrew'} ${money(res.amount || amount)}`;
                    // a resent action: the server answered with the first one, nothing moved again
                    ctx.notify(res.duplicate ? `Already done earlier: ${done}` : done, 'success');
                    state.amount = '';
                } else {
                    ctx.notify(errorText(res), 'error');
                }
                loadTab();
            }

            async function act(method, payload, okText) {
                if (state.busy) return;
                state.busy = true;
                render();
                const res = await ctx.rpc(method, payload);
                state.busy = false;
                if (res && res.ok) ctx.notify(okText + (res.name ? ': ' + res.name : ''), 'success'); else ctx.notify(errorText(res), 'error');
                if (method === 'hire') { state.tab = 'staff'; }
                await load();
            }

            function confirmBox(text) {
                return new Promise((resolve) => {
                    const box = h('div.pfm-overlay', h('div.pfm-dialog', h('div', text), h('div.pfm-actions',
                        h('button.pf-btn.ghost', { onclick: () => { box.remove(); resolve(false); } }, 'Cancel'),
                        h('button.pf-btn.primary', { onclick: () => { box.remove(); resolve(true); } }, 'Confirm'))));
                    root.appendChild(box);
                });
            }
            async function confirmThen(text, fn) { if (await confirmBox(text)) fn(); }

            load();
        },
    });
})();
