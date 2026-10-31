// Bank (pfm-banking) on pf-devices: personal, shared and society accounts, ledger statements, transfers,
// loans, credit and cards. Everything comes from the server and every action is checked there; the
// module only sends what the player chose (account refs, amount, note) and a per-action `ref` that
// makes a retried request safe (the server never moves the same ref twice).
(function () {
    const ERRORS = {
        bad_request: 'That request was not valid', bad_amount: 'Enter a whole amount of at least $1',
        bad_iban: 'That is not a valid IBAN (PF followed by digits)', bad_citizen: 'Enter a valid citizen ID',
        unknown_citizen: 'No citizen with that ID', unknown_iban: 'No account found for that IBAN',
        not_authorized: 'You may not use that account for this', bad_account: 'Choose an account',
        same_account: 'Choose two different accounts', over_limit: 'That is over the limit for one transaction',
        daily_limit: 'That would go over your daily transfer limit', slow_down: 'Wait a moment between two transactions',
        insufficient_funds: 'Not enough money in that account', busy: 'Your last transaction is still running',
        already_processed: 'This transaction was already processed', unsupported_route: 'Move society money to your personal account first',
        cash_at_counter: 'Cash is handled at a bank counter or an ATM', recipient_unavailable: 'The recipient could not be credited; the money was returned',
        rate_limited: 'Too many requests, slow down', server_error: 'The bank had a problem. Try again.',
        request_failed: 'No answer from the bank. Try again: it will not be sent twice.', timeout: 'No answer from the bank. Try again: it will not be sent twice.',
        not_authorized_app: 'You cannot use the bank app', no_player: 'You are not signed in',
    };
    const RETRYABLE = { request_failed: true, timeout: true };
    const KINDS = [
        ['', 'All types'], ['transfer', 'Transfers'], ['deposit', 'Deposits'], ['withdraw', 'Withdrawals'],
        ['wage', 'Wages'], ['purchase', 'Purchases'], ['sale', 'Sales'], ['fee', 'Fees'],
        ['society_deposit', 'Society deposits'], ['society_withdraw', 'Society withdrawals'],
        ['loan', 'Loans'], ['loan_payment', 'Loan payments'], ['loan_autopay', 'Loan autopay'],
        ['card_payment', 'Card payments'], ['card_advance', 'Cash advances'], ['refund', 'Refunds'],
    ];
    const DAYS = [['', 'Any time'], ['1', 'Last 24 hours'], ['7', 'Last 7 days'], ['30', 'Last 30 days'], ['90', 'Last 90 days'], ['365', 'Last year']];
    const DESIGNS = ['classic', 'midnight', 'gold', 'ruby', 'ocean'];

    function newRef() {
        const rnd = Math.random().toString(36).slice(2, 12);
        return ('b' + Date.now().toString(36) + '-' + rnd).slice(0, 40);
    }
    function when(at) {
        if (!at) return '';
        const d = new Date(at * 1000);
        return d.toLocaleDateString([], { day: 'numeric', month: 'short' }) + ' ' + d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    }
    function minutes(sec) {
        const m = Math.max(1, Math.ceil((Number(sec) || 0) / 60));
        return m === 1 ? '1 min' : m + ' min';
    }
    function errorText(res, fallback) {
        if (res && res.message && !ERRORS[res.error]) return res.message;
        return (res && ERRORS[res.error]) || (res && res.message) || fallback || 'That did not work';
    }

    PFApps.register('bank', {
        mount(container, ctx, params) {
            const { h, money } = ctx;
            const state = {
                tab: (params && params.tab) || 'overview',
                data: null, finance: null, busy: false, timers: [],
                st: { account: 'personal', direction: '', kind: '', days: '30', search: '', rows: [], hasMore: false, nextBefore: null, summary: null, loading: false },
                tr: { ref: newRef(), from: 'personal', toType: 'own', toAccount: '', iban: '', citizenid: '', amount: '', note: '', review: false },
                dialog: null,
            };
            if (params) applyParams(params);

            const sub = h('div.pf-app-sub', 'Your accounts');
            const tabs = h('div.pf-tabs.pfb-tabs');
            const body = h('div.pf-app-body.pfb-body');
            const overlay = h('div.pfb-overlay', { style: { display: 'none' } });
            const root = h('div.pf-app.pfb',
                h('div.pf-app-header',
                    h('div.pf-app-title', h('span.pf-icon', '🏦'), h('div', 'Bank', sub)),
                    h('button.pf-btn.sm', { onclick: () => reload() }, 'Refresh')),
                tabs, body, overlay);
            container.appendChild(root);

            // the tablet window is narrow: tighter layout below 720 px
            function fit() { root.classList.toggle('pfb-narrow', (container.clientWidth || 800) < 720); }
            if (typeof ResizeObserver === 'function') {
                const ro = new ResizeObserver(fit);
                ro.observe(container);
                state.ro = ro;
            }
            fit();

            function applyParams(p) {
                if (p.tab) state.tab = p.tab;
                if (typeof p.account === 'string' && p.account.length <= 64) { state.st.account = p.account; state.st.rows = []; }
                if (p.to && p.to.type === 'iban') { state.tab = 'transfer'; state.tr.toType = 'iban'; state.tr.iban = String(p.to.iban || ''); }
                if (p.to && p.to.type === 'citizen') { state.tab = 'transfer'; state.tr.toType = 'citizen'; state.tr.citizenid = String(p.to.citizenid || ''); }
                if (p.amount) state.tr.amount = String(Math.floor(Number(p.amount)) || '');
                if (p.note) state.tr.note = String(p.note).slice(0, 100);
            }

            // ── data ────────────────────────────────────────────────
            async function reload() {
                const res = await ctx.rpc('overview');
                if (!res || !res.ok) { body.innerHTML = ''; body.appendChild(h('div.pf-empty', errorText(res, 'The bank is not available right now'))); return; }
                state.data = res;
                sub.textContent = res.personal && res.personal.iban ? 'IBAN ' + res.personal.iban : 'Your accounts';
                if (state.tab === 'loans') await loadFinance(false);
                render();
                if (state.tab === 'statements') loadStatement(true);
            }
            async function loadFinance(rerender) {
                const res = await ctx.rpc('finance');
                state.finance = res && res.ok ? res : { error: res };
                if (rerender !== false) render();
            }
            async function loadStatement(reset) {
                const s = state.st;
                if (s.loading) return;
                s.loading = true;
                const payload = { account: s.account, direction: s.direction || undefined, kind: s.kind || undefined, search: s.search || undefined, days: s.days ? Number(s.days) : undefined };
                if (!reset && s.nextBefore) payload.before = s.nextBefore;
                const res = await ctx.rpc('statement', payload);
                s.loading = false;
                if (!res || !res.ok) { ctx.notify(errorText(res, 'Statement not available'), 'error'); return; }
                s.rows = reset ? res.rows : s.rows.concat(res.rows);
                s.hasMore = !!res.hasMore;
                s.nextBefore = res.nextBefore || null;
                if (reset) s.summary = res.summary || null;
                if (state.tab === 'statements') render();
            }

            // accounts the player may use, as { ref, label, balance, canSend, canReceive, kind }
            function accounts() {
                const d = state.data;
                if (!d) return [];
                const list = [{ ref: 'personal', label: 'Personal account', balance: d.personal.balance, canSend: true, canReceive: true, kind: 'personal' }];
                (d.accounts || []).forEach((a) => list.push({ ref: a.ref, label: a.label, balance: a.balance, canSend: a.perms.withdraw, canReceive: a.perms.deposit, kind: 'acct', iban: a.iban }));
                (d.societies || []).forEach((s) => list.push({ ref: s.ref, label: s.label, balance: s.balance, canSend: true, canReceive: true, kind: 'society' }));
                return list;
            }
            function accountByRef(ref) { return accounts().find((a) => a.ref === ref) || null; }

            // ── rendering ──────────────────────────────────────────
            const TABS = [['overview', 'Overview'], ['statements', 'Statements'], ['transfer', 'Transfer'], ['loans', 'Loans & cards'], ['branches', 'Branches']];
            function render() {
                tabs.innerHTML = '';
                TABS.forEach(([id, label]) => tabs.appendChild(h('div.pf-tab' + (state.tab === id ? '.active' : ''), { onclick: () => go(id) }, label)));
                body.innerHTML = '';
                if (!state.data) { body.appendChild(h('div.pfapp-loading', 'Loading your accounts…')); return; }
                const view = { overview: viewOverview, statements: viewStatements, transfer: viewTransfer, loans: viewLoans, branches: viewBranches }[state.tab] || viewOverview;
                body.appendChild(view());
            }
            function go(tab) {
                state.tab = tab;
                render();
                if (tab === 'statements') loadStatement(true);
                if (tab === 'loans') loadFinance();
            }
            function stat(label, value, cls) {
                return h('div.pf-card.pf-stat', h('div.pf-stat-value' + (cls ? '.' + cls : ''), value), h('div.pf-stat-label', label));
            }
            function badge(text, cls) { return h('span.pf-badge' + (cls ? '.' + cls : ''), text); }
            function btn(label, onclick, cls) { return h('button.pf-btn.sm' + (cls ? '.' + cls : ''), { onclick, disabled: state.busy }, label); }

            function openStatement(ref) { state.st.account = ref; state.st.rows = []; go('statements'); }
            function openTransfer(fromRef) {
                state.tr.from = fromRef;
                state.tr.toType = 'own';
                state.tr.toAccount = '';
                state.tr.review = false;
                go('transfer');
            }

            function viewOverview() {
                const d = state.data;
                const f = d.finance || {};
                const wrap = h('div.pf-stack');
                wrap.appendChild(h('div.pfb-stats',
                    stat('Personal account', money(d.personal.balance)),
                    stat('Cash on hand', money(d.personal.cash)),
                    stat('Credit score', f.score != null ? String(f.score) : '—', f.score >= 700 ? 'pfb-good' : (f.score < 580 ? 'pfb-bad' : '')),
                    stat('Debt', money(f.debt || 0), f.debt > 0 ? 'pfb-bad' : '')));

                const ibanInput = h('input.pf-input.pfb-iban', { value: d.personal.iban || '', readonly: true, title: 'Your IBAN', onclick: (e) => e.target.select() });
                wrap.appendChild(h('div.pf-card.pfb-account',
                    h('div.pfb-account-main',
                        h('div.pf-row', h('span.pf-strong', 'Personal account'), badge('You', 'accent')),
                        h('div.pf-row.pf-small.pf-muted', 'IBAN', ibanInput),
                        h('div.pfb-balance', money(d.personal.balance))),
                    h('div.pfb-actions', btn('Statement', () => openStatement('personal')), btn('Send money', () => openTransfer('personal'), 'primary'),
                        btn('Cash ledger', () => openStatement('cash'), 'ghost'))));

                wrap.appendChild(h('div.pfb-section', 'Shared and business accounts'));
                if (!d.accounts.length) wrap.appendChild(h('div.pf-small.pf-muted', 'You are not a member of any shared or business account. Open one at a bank branch.'));
                d.accounts.forEach((a) => {
                    const perms = h('div.pf-row.pfb-perms',
                        a.isOwner ? badge('Owner', 'accent') : null,
                        badge(a.perms.deposit ? 'Deposit' : 'No deposit', a.perms.deposit ? 'ok' : ''),
                        badge(a.perms.withdraw ? 'Withdraw' : 'No withdraw', a.perms.withdraw ? 'ok' : ''),
                        a.perms.cards ? badge('Cards', 'ok') : null,
                        a.perms.manage ? badge('Manage', 'ok') : null);
                    wrap.appendChild(h('div.pf-card.pfb-account', { style: a.color && /^#[0-9a-f]{6}$/i.test(a.color) ? { borderLeft: '4px solid ' + a.color } : null },
                        h('div.pfb-account-main',
                            h('div.pf-row', h('span.pf-strong', a.label), badge(a.type === 'business' ? 'Business' : 'Shared')),
                            h('div.pf-small.pf-muted', 'IBAN ' + a.iban),
                            perms,
                            h('div.pfb-balance', money(a.balance))),
                        h('div.pfb-actions',
                            btn('Statement', () => openStatement(a.ref)),
                            a.perms.withdraw || a.perms.deposit ? btn('Move money', () => openTransfer(a.perms.withdraw ? a.ref : 'personal')) : null,
                            a.perms.manage ? btn('Members', () => openMembers(a)) : null)));
                });

                if (d.societies && d.societies.length) {
                    wrap.appendChild(h('div.pfb-section', 'Society accounts you manage'));
                    d.societies.forEach((s) => {
                        wrap.appendChild(h('div.pf-card.pfb-account',
                            h('div.pfb-account-main',
                                h('div.pf-row', h('span.pf-strong', s.label), badge(s.type === 'gang' ? 'Gang' : (s.type === 'job' ? 'Company' : 'Shared'), 'warn')),
                                h('div.pfb-balance', money(s.balance))),
                            h('div.pfb-actions', btn('Statement', () => openStatement(s.ref)), btn('Move money', () => openTransfer(s.ref)))));
                    });
                }
                wrap.appendChild(h('div.pfb-note', 'Cash is withdrawn and deposited at a bank counter or an ATM. Transfers between bank accounts work from anywhere.'));
                return wrap;
            }

            function select(options, value, onchange) {
                const el = h('select.pf-select', { onchange: (e) => onchange(e.target.value) }, options.map(([v, label]) => h('option', { value: v }, label)));
                el.value = value == null ? '' : String(value);
                return el;
            }

            function viewStatements() {
                const s = state.st;
                const d = state.data;
                const accountOptions = [['personal', 'Personal account'], ['cash', 'Cash (ledger lines)']]
                    .concat((d.accounts || []).map((a) => [a.ref, a.label]))
                    .concat((d.societies || []).map((x) => [x.ref, x.label]));
                const search = h('input.pf-input', { value: s.search, placeholder: 'Search description', maxlength: 40,
                    onkeydown: (e) => { if (e.key === 'Enter') { s.search = e.target.value; loadStatement(true); } } });
                const wrap = h('div.pf-stack');
                wrap.appendChild(h('div.pf-toolbar.pfb-filters',
                    select(accountOptions, s.account, (v) => { s.account = v; loadStatement(true); }),
                    select([['', 'In and out'], ['in', 'Money in'], ['out', 'Money out']], s.direction, (v) => { s.direction = v; loadStatement(true); }),
                    select(KINDS, s.kind, (v) => { s.kind = v; loadStatement(true); }),
                    select(DAYS, s.days, (v) => { s.days = v; loadStatement(true); }),
                    search,
                    h('button.pf-btn.sm', { onclick: () => { s.search = search.value; loadStatement(true); } }, 'Search')));
                if (s.summary) {
                    wrap.appendChild(h('div.pfb-stats',
                        stat('Money in', money(s.summary.moneyIn), 'pfb-good'),
                        stat('Money out', money(s.summary.moneyOut), 'pfb-bad'),
                        stat('Lines', String(s.summary.lines))));
                }
                if (!s.rows.length) {
                    wrap.appendChild(h('div.pf-empty', s.loading ? 'Loading…' : 'No transactions match.'));
                    return wrap;
                }
                const tbody = h('tbody');
                s.rows.forEach((r) => {
                    const cp = r.counterparty || {};
                    tbody.appendChild(h('tr',
                        h('td.pfb-when', when(r.at)),
                        h('td', h('div.pf-strong', (r.direction === 'in' ? 'From ' : 'To ') + (cp.label || 'Unknown')),
                            h('div.pf-small.pf-muted', [r.reason, r.note ? '“' + r.note + '”' : null].filter(Boolean).join(' · ')),
                            r.kind ? badge(r.kind.replace(/_/g, ' ')) : null),
                        h('td.pfb-amount' + (r.direction === 'in' ? '.pfb-good' : '.pfb-bad'), (r.direction === 'in' ? '+' : '−') + money(r.amount))));
                });
                wrap.appendChild(h('div.pfb-table-wrap', h('table.pf-table', h('thead', h('tr', h('th', 'Date'), h('th', 'Description'), h('th.pfb-amount', 'Amount'))), tbody)));
                if (s.hasMore) wrap.appendChild(h('button.pf-btn', { onclick: () => loadStatement(false), disabled: s.loading }, 'Load more'));
                return wrap;
            }

            function viewTransfer() {
                const t = state.tr;
                const d = state.data;
                const all = accounts();
                const from = accountByRef(t.from) || all[0];
                t.from = from.ref;
                const senders = all.filter((a) => a.canSend);
                // destinations the server accepts: personal <-> shared, shared -> shared, personal <-> society
                const ownTargets = all.filter((a) => a.ref !== from.ref && a.canReceive && (
                    (from.kind === 'personal' && (a.kind === 'acct' || a.kind === 'society')) ||
                    (from.kind === 'acct' && (a.kind === 'personal' || a.kind === 'acct')) ||
                    (from.kind === 'society' && a.kind === 'personal')));
                if (from.kind === 'society' && t.toType !== 'own') t.toType = 'own';
                if (t.toType === 'own' && !ownTargets.some((a) => a.ref === t.toAccount)) t.toAccount = ownTargets[0] ? ownTargets[0].ref : '';

                const lim = d.limits || {};
                const left = Math.max(0, (lim.dailyLimit || 0) - (lim.dailyUsed || 0));
                const form = h('div.pf-card.pf-stack.pfb-form');
                form.appendChild(h('div.pf-field', h('label', 'From'),
                    select(senders.map((a) => [a.ref, a.label + ' — ' + money(a.balance)]), t.from, (v) => { t.from = v; t.review = false; render(); })));
                const kinds = [['own', 'My accounts'], ['iban', 'IBAN'], ['citizen', 'Citizen ID']];
                form.appendChild(h('div.pf-field', h('label', 'To'),
                    h('div.pfb-seg', kinds.map(([id, label]) => h('button.pf-btn.sm' + (t.toType === id ? '.primary' : ''),
                        { disabled: from.kind === 'society' && id !== 'own', onclick: () => { t.toType = id; t.review = false; render(); } }, label)))));
                if (t.toType === 'own') {
                    form.appendChild(ownTargets.length
                        ? select(ownTargets.map((a) => [a.ref, a.label + ' — ' + money(a.balance)]), t.toAccount, (v) => { t.toAccount = v; t.review = false; })
                        : h('div.pf-small.pf-muted', 'No other account of yours can receive money from this one.'));
                } else if (t.toType === 'iban') {
                    form.appendChild(h('input.pf-input', { value: t.iban, placeholder: 'PF12345678', maxlength: 24, oninput: (e) => { t.iban = e.target.value; t.review = false; } }));
                } else {
                    form.appendChild(h('input.pf-input', { value: t.citizenid, placeholder: 'Citizen ID', maxlength: 20, oninput: (e) => { t.citizenid = e.target.value; t.review = false; } }));
                }
                if (from.kind === 'society') form.appendChild(h('div.pf-small.pf-muted', 'Society money moves to your personal account; pay others from there.'));
                form.appendChild(h('div.pf-row.pfb-two',
                    h('div.pf-field', h('label', 'Amount'), h('input.pf-input', { type: 'number', min: 1, step: 1, value: t.amount, placeholder: '0', oninput: (e) => { t.amount = e.target.value; t.review = false; } })),
                    h('div.pf-field', h('label', 'Note (optional)'), h('input.pf-input', { value: t.note, maxlength: 100, oninput: (e) => { t.note = e.target.value; } }))));
                form.appendChild(h('div.pf-small.pf-muted', t.toType === 'own'
                    ? 'Moves between your own accounts.'
                    : `Up to ${money(lim.maxTransfer)} per payment · ${money(left)} of ${money(lim.dailyLimit)} left today`));

                const amount = Math.floor(Number(t.amount));
                const destination = t.toType === 'own' ? (accountByRef(t.toAccount) || {}).label : (t.toType === 'iban' ? t.iban.toUpperCase().replace(/\s/g, '') : 'citizen ' + t.citizenid.toUpperCase().trim());
                if (!t.review) {
                    form.appendChild(h('div.pfb-actions', h('button.pf-btn.primary', { disabled: state.busy, onclick: () => {
                        if (!(amount >= 1) || amount !== Number(t.amount)) { ctx.notify(ERRORS.bad_amount, 'error'); return; }
                        if (!destination) { ctx.notify('Choose where the money goes', 'error'); return; }
                        t.review = true; render();
                    } }, 'Review')));
                } else {
                    form.appendChild(h('div.pfb-confirm',
                        h('div', 'Send ', h('span.pf-strong', money(amount)), ' from ', h('span.pf-strong', from.label), ' to ', h('span.pf-strong', destination || '—'), '?'),
                        h('div.pfb-actions', h('button.pf-btn.ghost', { onclick: () => { t.review = false; render(); } }, 'Change'),
                            h('button.pf-btn.primary', { disabled: state.busy, onclick: sendTransfer }, state.busy ? 'Sending…' : 'Confirm'))));
                }
                return h('div.pf-stack', form);
            }

            async function sendTransfer() {
                const t = state.tr;
                if (state.busy) return;
                const to = t.toType === 'own' ? { type: 'own', account: t.toAccount }
                    : (t.toType === 'iban' ? { type: 'iban', iban: t.iban.trim() } : { type: 'citizen', citizenid: t.citizenid.trim() });
                state.busy = true;
                render();
                const res = await ctx.rpc('transfer', { ref: t.ref, from: t.from, to, amount: Math.floor(Number(t.amount)), note: t.note || undefined });
                state.busy = false;
                if (res && res.ok) {
                    ctx.notify(res.message || 'Done', 'success');
                    state.tr = { ref: newRef(), from: t.from, toType: t.toType, toAccount: t.toAccount, iban: '', citizenid: '', amount: '', note: '', review: false };
                    await reload();
                    return;
                }
                // the same ref is kept only when the answer was lost: the server then returns the first result
                if (!(res && RETRYABLE[res.error])) t.ref = newRef();
                t.review = false;
                ctx.notify(errorText(res), 'error');
                render();
            }

            // ── loans and cards ───────────────────────────────────
            async function act(method, payload, okText, confirmText) {
                if (state.busy) return;
                if (confirmText && !(await confirmBox(confirmText))) return;
                state.busy = true;
                render();
                const res = await ctx.rpc(method, payload);
                state.busy = false;
                if (res && res.ok) ctx.notify(res.message || okText || 'Done', 'success');
                else ctx.notify(errorText(res), 'error');
                await reload();
                if (state.tab === 'loans') await loadFinance();
            }

            function viewLoans() {
                const f = state.finance;
                if (!f) return h('div.pfapp-loading', 'Loading…');
                if (f.error) return h('div.pf-empty', errorText(f.error, 'Loans are not available right now'));
                const wrap = h('div.pf-stack');
                const pct = Math.round(((f.score - f.scoreMin) / Math.max(1, f.scoreMax - f.scoreMin)) * 100);
                wrap.appendChild(h('div.pf-card.pfb-score',
                    h('div.pf-row.between', h('div', h('div.pf-stat-label', 'Credit score'), h('div.pfb-score-value', String(f.score))),
                        h('div.pf-small.pf-muted', `${f.scoreMin} – ${f.scoreMax}`)),
                    h('div.pfb-bar', h('div.pfb-bar-fill', { style: { width: Math.max(0, Math.min(100, pct)) + '%' } }))));

                wrap.appendChild(h('div.pfb-section', `Loans (${f.loans.length} of ${f.maxActiveLoans})`));
                if (!f.loans.length) wrap.appendChild(h('div.pf-small.pf-muted', 'No active loans.'));
                f.loans.forEach((l) => {
                    wrap.appendChild(h('div.pf-card.pfb-account',
                        h('div.pfb-account-main',
                            h('div.pf-row', h('span.pf-strong', l.tier + ' loan'), badge(l.apr + '% APR'), l.missed ? badge(l.missed + ' missed', 'bad') : null),
                            h('div.pf-small.pf-muted', `${l.paymentsMade} of ${l.paymentsTotal} payments · ${money(l.payment)} each · next in ${minutes(l.nextPaymentIn)}`),
                            h('div.pfb-balance', money(l.balance) + ' left')),
                        h('div.pfb-actions',
                            btn('Pay ' + money(Math.min(l.payment, l.balance)), () => act('payLoan', { loanId: l.id }, 'Payment made')),
                            btn('Pay off', () => act('payoffLoan', { loanId: l.id }, 'Loan paid off', `Pay off the whole ${money(l.balance)} now?`), 'primary'))));
                });
                if (f.loans.length < f.maxActiveLoans) {
                    const eligible = f.tiers.filter((t) => t.eligible);
                    if (eligible.length) {
                        let tier = eligible[eligible.length - 1];
                        const amountIn = h('input.pf-input', { type: 'number', min: tier.amountMin, max: tier.amountMax, step: 1, placeholder: money(tier.amountMin) + ' – ' + money(tier.amountMax) });
                        const info = h('div.pf-small.pf-muted');
                        const showInfo = () => { info.textContent = `${tier.apr}% flat interest over ${tier.payments} payments · ${money(tier.amountMin)} to ${money(tier.amountMax)}`; amountIn.placeholder = money(tier.amountMin) + ' – ' + money(tier.amountMax); };
                        showInfo();
                        wrap.appendChild(h('div.pf-card.pf-stack',
                            h('div.pf-strong', 'Apply for a loan'),
                            h('div.pf-row.pfb-two',
                                select(eligible.map((t) => [String(t.index), t.name]), tier.index, (v) => { tier = eligible.find((t) => String(t.index) === v) || tier; showInfo(); }),
                                amountIn),
                            info,
                            h('div.pfb-actions', btn('Apply', () => {
                                const amount = Math.floor(Number(amountIn.value));
                                if (!(amount >= tier.amountMin && amount <= tier.amountMax)) { ctx.notify(`Enter ${money(tier.amountMin)} to ${money(tier.amountMax)}`, 'error'); return; }
                                act('applyLoan', { tierIndex: tier.index, amount }, 'Loan approved', `Borrow ${money(amount)} (${tier.name}, ${tier.apr}% over ${tier.payments} payments)?`);
                            }, 'primary'))));
                    }
                }

                wrap.appendChild(h('div.pfb-section', 'Credit cards'));
                if (!f.cards.length) wrap.appendChild(h('div.pf-small.pf-muted', 'No credit cards.'));
                f.cards.forEach((c) => {
                    const amountIn = h('input.pf-input.pfb-mini', { type: 'number', min: 1, step: 1, placeholder: 'Amount' });
                    wrap.appendChild(h('div.pf-card.pfb-account',
                        h('div.pfb-account-main',
                            h('div.pf-row', h('span.pf-strong', c.label), h('span.pf-muted', '•••• ' + c.last4), badge(c.apr + '% APR')),
                            h('div.pfb-balance', money(c.balance) + ' / ' + money(c.limit))),
                        h('div.pfb-actions', amountIn,
                            btn('Pay', () => { const a = Math.floor(Number(amountIn.value)); if (!(a >= 1)) return ctx.notify(ERRORS.bad_amount, 'error'); act('payCard', { cardId: c.id, amount: a }); }),
                            btn('Cash advance', () => {
                                const a = Math.floor(Number(amountIn.value));
                                if (!(a >= 1)) return ctx.notify(ERRORS.bad_amount, 'error');
                                act('cardAdvance', { cardId: c.id, amount: a }, null, `Take a ${money(a)} cash advance to your bank account (fee ${Math.round((f.advanceFeePct || 0) * 100)}%)?`);
                            }))));
                });
                const orderable = f.products.filter((p) => !p.held);
                if (orderable.length) {
                    wrap.appendChild(h('div.pf-grid', orderable.map((p) => h('div.pf-card.pf-stack',
                        h('div.pf-strong', p.label), h('div.pf-small.pf-muted', `Limit ${money(p.limit)} · ${p.apr}% APR · score ${p.minScore}+`),
                        h('button.pf-btn.sm', { disabled: !p.eligible || state.busy, onclick: () => act('orderCreditCard', { product: p.id }, 'Card approved') }, p.eligible ? 'Order card' : 'Score too low')))));
                }

                wrap.appendChild(h('div.pfb-section', 'Debit cards'));
                if (!f.debitCards.length) wrap.appendChild(h('div.pf-small.pf-muted', 'No debit cards.'));
                f.debitCards.forEach((c) => {
                    wrap.appendChild(h('div.pf-list-item',
                        h('div', h('div.pf-strong', '•••• ' + c.last4 + ' · ' + c.accountLabel), h('div.pf-small.pf-muted', 'Expires ' + c.exp + ' · ' + c.design)),
                        h('div.pfb-actions', c.locked ? badge('Locked', 'warn') : badge('Active', 'ok'),
                            btn(c.locked ? 'Unlock' : 'Lock', () => act('toggleCardLock', { cardId: c.id })),
                            btn('Cancel', () => act('cancelCard', { cardId: c.id }, 'Card cancelled', 'Cancel this card for good?'), 'danger'))));
                });
                const cardTargets = [['personal', 'Personal account']].concat((state.data.accounts || []).map((a) => [a.ref, a.label]));
                let cardAccount = 'personal';
                let design = 'classic';
                wrap.appendChild(h('div.pf-toolbar',
                    select(cardTargets, cardAccount, (v) => { cardAccount = v; }),
                    select(DESIGNS.map((x) => [x, x[0].toUpperCase() + x.slice(1)]), design, (v) => { design = v; }),
                    btn('Issue debit card', () => act('createCard', { account: cardAccount, design }, 'Card issued'))));
                return wrap;
            }

            function viewBranches() {
                const list = h('div.pf-list');
                (state.data.branches || []).forEach((b) => {
                    list.appendChild(h('div.pf-list-item',
                        h('div', h('div.pf-strong', b.label),
                            h('div.pf-small.pf-muted', b.closed ? `Closed${b.reason === 'robbery' ? ' after a robbery' : ''} · reopens in ${minutes(b.reopensIn)}` : 'Open: counter and ATMs')),
                        h('div.pfb-actions', b.closed ? badge('Closed', 'bad') : badge('Open', 'ok'),
                            btn('Set waypoint', () => { ctx.setWaypoint(b.x, b.y); ctx.notify('Waypoint set to ' + b.label, 'success'); }))));
                });
                return h('div.pf-stack', h('div.pf-small.pf-muted', 'Cash withdrawals and deposits, new accounts and bank cards are at a branch.'), list);
            }

            // ── dialogs ────────────────────────────────────────────
            function showDialog(content) {
                overlay.innerHTML = '';
                overlay.appendChild(h('div.pfb-dialog', content));
                overlay.style.display = 'flex';
            }
            function closeDialog() { overlay.style.display = 'none'; overlay.innerHTML = ''; }
            function confirmBox(text) {
                return new Promise((resolve) => {
                    showDialog(h('div.pf-stack', h('div', text), h('div.pfb-actions',
                        h('button.pf-btn.ghost', { onclick: () => { closeDialog(); resolve(false); } }, 'Cancel'),
                        h('button.pf-btn.primary', { onclick: () => { closeDialog(); resolve(true); } }, 'Confirm'))));
                });
            }

            function openMembers(account) {
                const a = (state.data.accounts || []).find((x) => x.ref === account.ref) || account;
                const rows = h('div.pf-list');
                (a.members || []).forEach((m) => {
                    const boxes = {};
                    const box = (key, label) => {
                        boxes[key] = h('input', { type: 'checkbox', checked: m[key] ? true : null, disabled: m.owner ? true : null });
                        return h('label.pfb-check', boxes[key], label);
                    };
                    rows.appendChild(h('div.pf-list-item',
                        h('div', h('div.pf-strong', m.name || m.citizenid), h('div.pf-small.pf-muted', m.owner ? 'Owner' : m.citizenid)),
                        h('div.pfb-actions', box('deposit', 'Deposit'), box('withdraw', 'Withdraw'), box('cards', 'Cards'), box('manage', 'Manage'),
                            m.owner ? null : btn('Save', () => memberAction('updateMember', { account: a.ref, citizenid: m.citizenid, perms: {
                                can_deposit: boxes.deposit.checked, can_withdraw: boxes.withdraw.checked, can_cards: boxes.cards.checked, can_manage: boxes.manage.checked } })),
                            m.owner ? null : btn('Remove', () => memberAction('removeMember', { account: a.ref, citizenid: m.citizenid }), 'danger'))));
                });
                const cidIn = h('input.pf-input', { placeholder: 'Citizen ID', maxlength: 20 });
                const labelIn = h('input.pf-input', { value: a.label, maxlength: 30 });
                showDialog(h('div.pf-stack',
                    h('div.pf-row.between', h('div.pf-strong', a.label + ' · members'), h('button.pf-btn.sm.ghost', { onclick: closeDialog }, 'Close')),
                    rows,
                    h('div.pf-row', cidIn, btn('Add member', () => memberAction('addMember', { account: a.ref, citizenid: cidIn.value.trim(), perms: { can_deposit: true } }))),
                    h('div.pf-row', labelIn, btn('Rename', () => memberAction('renameAccount', { account: a.ref, label: labelIn.value.trim() })))));
            }
            async function memberAction(method, payload) {
                if (state.busy) return;
                state.busy = true;
                const res = await ctx.rpc(method, payload);
                state.busy = false;
                if (res && res.ok) ctx.notify(res.message || 'Saved', 'success'); else ctx.notify(errorText(res), 'error');
                await reload();
                const a = (state.data && state.data.accounts || []).find((x) => x.ref === payload.account);
                if (a && a.perms.manage) openMembers(a); else closeDialog();
            }

            // ── pushes ─────────────────────────────────────────────
            ctx.on('balance', (m) => {
                if (!state.data || !m) return;
                state.data.personal.balance = Number(m.bank) || 0;
                state.data.personal.cash = Number(m.cash) || 0;
                if (state.tab === 'overview' && overlay.style.display === 'none') render();
            });
            ctx.on('params', (p) => { if (p) { applyParams(p); render(); if (state.tab === 'statements') loadStatement(true); } });
            // branch countdowns stay current while the window is open
            state.timers.push(setInterval(() => { if (state.tab === 'branches') reload(); }, 60000));
            state.ctxRef = ctx;
            container.__pfbState = state;

            render();
            reload();
        },
        unmount(ctx) {
            const root = ctx && ctx.el;
            const state = root && root.__pfbState;
            if (!state) return;
            state.timers.forEach(clearInterval);
            if (state.ro) state.ro.disconnect();
            delete root.__pfbState;
        },
    });
})();
