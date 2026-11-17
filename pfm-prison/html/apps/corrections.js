// Corrections MDT (pf-devices module, tablet and computer): population, cells, the routine and
// headcounts, discipline and hearings, the visit board, lockdown and alarms, the camera list and the
// trust accounts (read only). Every list and every action comes from pfm-prison server/apps.lua;
// the server decides who may do what (the `can` answer of init) and checks it again on every call.
// Server text goes into the page as text nodes only (ctx.h), never as HTML.
(function () {
    const APP = 'corrections';
    const ERRORS = {
        no_permission: 'Your rank cannot do this', not_on_duty: 'Go on duty first', bad_args: 'Check the form and try again',
        rate_limited: 'Wait a moment', busy: 'Being changed right now; try again', db_unavailable: 'Something went wrong; nothing was changed',
        not_found: 'Not found (it may have changed)', invalid_state: 'Not possible in its current state', conflict: 'That is taken or full',
        too_far: 'You need to be there in person', offline: 'The inmate is offline', unavailable: 'Not available right now',
        key_reused: 'That report was already filed', server_error: 'The server had a problem', request_failed: 'No answer from the server',
        not_authorized: 'Corrections staff on duty only', unknown_method: 'This action is not available',
    };
    // a server message explains a refusal best (it names the rule); the code is the fallback
    function errText(res) {
        if (res && typeof res.message === 'string' && res.message) return res.message;
        const code = res && res.error;
        return ERRORS[code] || (code ? String(code).replace(/_/g, ' ') : 'That did not work');
    }
    const STATUS = {
        intake: ['Intake', 'accent'], in_cell: ['In cell', ''], yard: ['Yard', 'ok'], work: ['Work', 'ok'], meal: ['Meal', 'ok'],
        infirmary: ['Infirmary', 'warn'], visitation: ['Visit', 'accent'], solitary: ['Solitary', 'bad'], transfer: ['Transfer', 'warn'],
        escaped: ['Escaped', 'bad'],
    };
    const INF_STATE = { reported: 'warn', hearing_scheduled: 'accent', heard: '', sanctioned: 'bad', dismissed: 'ok' };
    const VISIT_STATE = { booked: '', checked_in: 'accent', in_progress: 'ok', done: '', cancelled: 'warn', no_show: 'warn', denied: 'bad' };
    const timers = new WeakMap();

    const pad = (n) => String(n).padStart(2, '0');
    function clock(ts) {
        if (!ts) return '—';
        const d = new Date(Number(ts) * 1000);
        return `${pad(d.getHours())}:${pad(d.getMinutes())}`;
    }
    function stamp(ts) {
        if (!ts) return '—';
        const d = new Date(Number(ts) * 1000);
        return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${clock(ts)}`;
    }
    function dur(sec) {
        sec = Math.max(0, Math.round(Number(sec) || 0));
        const h = Math.floor(sec / 3600);
        const m = Math.floor((sec % 3600) / 60);
        if (h > 0) return `${h} h ${m} min`;
        if (m > 0) return `${m} min`;
        return `${sec} s`;
    }
    // relative to the server's clock (every answer carries `now`), not the viewer's
    function rel(ts, now) {
        if (!ts) return '—';
        const d = Number(ts) - Number(now || Math.floor(Date.now() / 1000));
        return d >= 0 ? `in ${dur(d)}` : `${dur(-d)} ago`;
    }
    const arr = (v) => (Array.isArray(v) ? v : []);
    const obj = (v) => (v && typeof v === 'object' && !Array.isArray(v) ? v : {});

    PFApps.register(APP, {
        async mount(container, ctx) {
            const { h, money } = ctx;
            const state = { section: 'overview', init: null, now: 0, seq: 0, pop: { q: '', status: '', classification: '', block: '', sort: 'cell', page: 1 },
                inf: { filter: 'open', page: 1 }, cid: null, from: 'population', hearing: null };

            const sub = h('div.pf-app-sub', 'Bolingbroke Penitentiary');
            const strip = h('div.pfc-strip');
            const nav = h('nav.pf-app-nav.pfc-nav', { 'aria-label': 'Corrections sections' });
            const body = h('div.pf-app-body.pfc-body', { tabindex: '-1' });
            container.appendChild(h('div.pf-app.pfc',
                h('div.pf-app-header', h('div.pf-app-title', h('span.pf-icon', '🔒'), h('div', 'Corrections', sub)), strip),
                h('div.pf-app-side.pfc-side', nav, body)));

            const badge = (label, tone) => h('span.pf-badge' + (tone ? '.' + tone : ''), label);
            const statusBadge = (s) => { const v = STATUS[s] || [s || 'unknown', '']; return badge(v[0], v[1]); };
            const btn = (label, onclick, cls) => h('button.pf-btn.sm' + (cls ? '.' + cls : ''), { type: 'button', onclick }, label);
            const card = (title, ...kids) => h('section.pf-card.pfc-card', title ? h('h3.pfc-h', title) : null, ...kids);
            const stat = (label, value, tone) => h('div.pf-stat.pfc-stat', h('div.pf-stat-value' + (tone ? '.pfc-' + tone : ''), String(value)), h('div.pf-stat-label', label));
            const empty = (text) => h('div.pf-empty', text);
            const who = (cid, names) => { const n = obj(names)[cid]; return n ? `${n} (${cid})` : String(cid || '—'); };
            const field = (label, input) => h('div.pf-field', h('label', label), input);
            function table(head, rows, opts) {
                return h('div.pfc-table-wrap', h('table.pf-table.pfc-table', opts || {},
                    h('thead', h('tr', head.map((t) => h('th', { scope: 'col' }, t)))), h('tbody', rows)));
            }

            function setBody(...kids) {
                body.innerHTML = '';
                kids.forEach((k) => { if (k) body.appendChild(k); });
            }
            function loading() { setBody(h('div.pfapp-loading', 'Loading…')); }
            function failed(res, retry) {
                setBody(h('div.pfc-error', { role: 'alert' }, h('div.pfapp-error', errText(res)), h('div.pf-row.pfc-center', btn('Retry', retry))));
            }
            // one load per section at a time; an answer for a section the user has left is dropped
            async function call(method, payload) {
                const res = await ctx.rpc(method, payload || {});
                if (res && typeof res.now === 'number') state.now = res.now;
                return res || { ok: false, error: 'request_failed' };
            }
            async function load(method, payload, render) {
                const seq = ++state.seq;
                loading();
                const res = await call(method, payload);
                if (seq !== state.seq) return;
                if (!res.ok) { failed(res, () => load(method, payload, render)); return; }
                render(res);
            }
            async function act(method, payload, okText, after) {
                const res = await call(method, payload);
                if (!res.ok) { ctx.notify(errText(res), 'error'); return res; }
                if (okText) ctx.notify(typeof okText === 'function' ? okText(res) : okText, 'success');
                if (after) after(res);
                return res;
            }

            // ── header strip (refreshed every 30 s while open) ──────────────────────────────
            function renderStrip(st) {
                strip.innerHTML = '';
                if (!st) return;
                strip.appendChild(badge(`${Number(st.population) || 0} held`, ''));
                if (st.lockdown) strip.appendChild(badge('LOCKDOWN', 'bad'));
                if (st.phase && st.phase.label) strip.appendChild(badge(st.phase.label, 'accent'));
                if (st.alarms && st.alarms.alarm) strip.appendChild(badge('Alarm', 'bad'));
            }
            async function refreshStrip() {
                const res = await call('status');
                if (res.ok) {
                    renderStrip(res.status);
                    if (state.init) state.init.status = res.status;
                }
            }

            // ── navigation (from the server's answer) ───────────────────────────────────────
            function sections() {
                const can = obj(state.init && state.init.can);
                const list = [['overview', 'Overview'], ['population', 'Population'], ['cells', 'Cells'], ['schedule', 'Routine & counts'],
                    ['discipline', 'Discipline'], ['visits', 'Visits'], ['security', 'Lockdown & alarms'], ['cameras', 'Cameras']];
                if (can.trust) list.push(['trust', 'Trust accounts']);
                return list;
            }
            function renderNav() {
                nav.innerHTML = '';
                const active = state.section === 'inmate' ? state.from : state.section;
                sections().forEach(([id, label]) => {
                    nav.appendChild(h('button.pf-nav-item.pfc-nav-item' + (active === id ? '.active' : ''), {
                        type: 'button', 'data-section': id, 'aria-current': active === id ? 'page' : null, onclick: () => go(id),
                    }, label));
                });
            }
            function go(section, extra) {
                state.section = section;
                if (extra && extra.cid) state.cid = extra.cid;
                renderNav();
                const fn = PAGES[section];
                if (fn) fn();
            }
            function openInmate(cid, from) {
                state.from = from || (state.section === 'inmate' ? state.from : state.section);
                go('inmate', { cid });
            }

            // ── overview ────────────────────────────────────────────────────────────────────
            function overview() {
                load('status', {}, (res) => {
                    const st = obj(res.status);
                    renderStrip(st);
                    const cells = obj(st.cells);
                    const lock = st.lockdown
                        ? card('Lockdown', h('p', badge('Lockdown in force', 'bad'), ' ', st.lockdownReason || ''),
                            st.lockdownUntil ? h('p.pf-muted', `Ends ${rel(st.lockdownUntil, res.now)} (${clock(st.lockdownUntil)})`) : null)
                        : null;
                    const phase = obj(st.phase);
                    setBody(h('div.pf-stack',
                        lock,
                        h('div.pf-grid.pfc-stats',
                            stat('Held', Number(st.population) || 0), stat('Online', Number(st.online) || 0),
                            stat('Escaped', Number(st.escaped) || 0, st.escaped ? 'bad' : ''),
                            stat('Free beds', `${Number(cells.free) || 0} / ${Number(cells.total) || 0}`),
                            stat('Cells out of service', Number(cells.outOfService) || 0, cells.outOfService ? 'warn' : ''),
                            stat('Gates open', Number(obj(st.alarms).gatesOpen) || 0, obj(st.alarms).gatesOpen ? 'warn' : '')),
                        card('Routine',
                            h('p', phase.label ? `${phase.label}, ends ${rel(phase.endsAt, res.now)}` : 'No routine running'),
                            h('p.pf-muted', st.nextCount ? `Next headcount ${rel(st.nextCount, res.now)} (${clock(st.nextCount)})` : 'No headcount due'))));
                });
            }

            // ── population ──────────────────────────────────────────────────────────────────
            let searchTimer = null;
            function population() {
                const p = state.pop;
                const init = obj(state.init);
                const q = h('input.pf-input', { type: 'search', placeholder: 'Name, citizen id or cell', value: p.q, maxlength: '40', 'aria-label': 'Search' });
                const reload = () => { p.page = 1; listInto(); };
                q.addEventListener('input', () => { p.q = q.value; clearTimeout(searchTimer); searchTimer = setTimeout(reload, 350); });
                q.addEventListener('keydown', (ev) => { if (ev.key === 'Enter') { clearTimeout(searchTimer); p.q = q.value; reload(); } });
                const sel = (key, label, options) => {
                    const s = h('select.pf-select', { 'aria-label': label }, options.map(([v, t]) => h('option', { value: v, selected: p[key] === v }, t)));
                    s.addEventListener('change', () => { p[key] = s.value; reload(); });
                    return s;
                };
                const statusSel = sel('status', 'Status', [['', 'Any status']].concat(Object.keys(STATUS).map((k) => [k, STATUS[k][0]])));
                const classSel = sel('classification', 'Classification', [['', 'Any class']].concat(arr(init.classes).map((c) => [String(c), String(c)])));
                const blockSel = sel('block', 'Block', [['', 'Any block']].concat(arr(init.blocks).map((b) => [String(b), `Block ${b}`])));
                const sortSel = sel('sort', 'Sort', [['cell', 'Sort: cell'], ['name', 'Sort: name'], ['admitted', 'Sort: newest'], ['class', 'Sort: class']]);
                const list = h('div.pfc-list');
                setBody(h('div.pf-toolbar.pfc-toolbar', q, statusSel, classSel, blockSel, sortSel), list);

                async function listInto() {
                    const seq = ++state.seq;
                    list.innerHTML = '';
                    list.appendChild(h('div.pfapp-loading', 'Loading…'));
                    const res = await call('population', { q: p.q, status: p.status, classification: p.classification, block: p.block, sort: p.sort, page: p.page });
                    if (seq !== state.seq) return;
                    list.innerHTML = '';
                    if (!res.ok) { list.appendChild(h('div.pfapp-error', { role: 'alert' }, errText(res))); list.appendChild(btn('Retry', listInto)); return; }
                    const rows = arr(res.inmates);
                    if (!rows.length) { list.appendChild(empty(p.q || p.status || p.classification || p.block ? 'No inmate matches.' : 'Nobody is held here.')); return; }
                    list.appendChild(table(['Inmate', 'Cell', 'Class', 'Status', 'Online', 'Admitted'], rows.map((r) => {
                        const tr = h('tr.pfc-click', { tabindex: '0', 'data-cid': r.cid, onclick: () => openInmate(r.cid, 'population') },
                            h('td', h('div.pf-strong', r.name || r.cid), h('div.pf-small.pf-muted', r.cid)),
                            h('td', r.cellId ? `${r.cellId} (${r.block || '?'})` : badge('No cell', 'warn')),
                            h('td', String(r.classification || '')),
                            h('td', statusBadge(r.status)),
                            h('td', r.online ? badge('Online', 'ok') : badge('Offline', '')),
                            h('td', stamp(r.admittedAt)));
                        tr.addEventListener('keydown', (ev) => { if (ev.key === 'Enter') openInmate(r.cid, 'population'); });
                        return tr;
                    })));
                    p.page = Number(res.page) || 1;
                    const pages = Number(res.pages) || 1;
                    list.appendChild(h('div.pf-row.pfc-pager',
                        h('button.pf-btn.sm', { type: 'button', disabled: p.page <= 1, onclick: () => { p.page -= 1; listInto(); } }, 'Previous'),
                        h('span.pf-muted', `Page ${p.page} of ${pages} · ${Number(res.total) || 0} held`),
                        h('button.pf-btn.sm', { type: 'button', disabled: p.page >= pages, onclick: () => { p.page += 1; listInto(); } }, 'Next')));
                }
                listInto();
            }

            // ── one inmate ──────────────────────────────────────────────────────────────────
            function inmate() {
                const cid = state.cid;
                load('inmate', { cid }, (res) => {
                    const can = obj(state.init && state.init.can);
                    const init = obj(state.init);
                    const m = obj(res.inmate);
                    const back = btn('← Back', () => go(state.from || 'population'), 'ghost');
                    const ident = card(m.name || m.cid,
                        h('div.pf-row.pfc-wrap', h('span.pf-muted', m.cid), statusBadge(m.status), badge(String(m.classification || ''), 'accent'),
                            m.online ? badge('Online', 'ok') : badge('Offline', '')),
                        h('p', m.cellId ? `Cell ${m.cellId}, block ${m.block || '?'}` : 'No cell assigned (overflow)'),
                        h('p.pf-muted.pf-small', `Admitted ${stamp(m.admittedAt)} · order #${m.orderId || '—'}`));

                    const s = obj(res.sentence);
                    let sentence;
                    if (!res.sentence || s.available === false) sentence = card('Sentence', h('p.pf-muted', 'The justice system is not answering; the sentence cannot be shown right now.'));
                    else if (s.none) sentence = card('Sentence', h('p.pf-muted', 'No open order (release pending).'));
                    else {
                        sentence = card(`Sentence · order #${s.orderId}`,
                            h('div.pf-grid.pfc-stats',
                                stat('Time to release', dur(s.timeToRelease)), stat('Required', dur(s.requiredSeconds)), stat('Served', dur(s.servedSeconds)),
                                stat('Work credit', dur(s.creditSeconds), 'ok'), stat('Forfeited', dur(s.forfeitSeconds), s.forfeitSeconds ? 'bad' : '')),
                            h('p.pf-small.pf-muted', `${s.kind || ''} · ${s.state || ''} · online-time clock (counts while inside)`),
                            arr(s.charges).length ? h('ul.pfc-charges', arr(s.charges).map((c) => h('li', `${c.label || c.code || 'Charge'}${c.code && c.label ? ` (${c.code})` : ''}${Number(c.count) > 1 ? ` ×${c.count}` : ''}`))) : null);
                    }

                    const restr = Object.entries(obj(res.restrictions));
                    const restrictions = card('Restrictions', restr.length
                        ? h('div.pf-row.pfc-wrap', restr.map(([k, u]) => badge(`${k} until ${clock(u)}`, k === 'solitary' ? 'bad' : 'warn')))
                        : h('p.pf-muted', 'No privileges restricted.'));

                    const infs = arr(res.infractions);
                    const infCard = card('Infractions', infs.length ? table(['#', 'Offence', 'State', 'Reported'], infs.map((i) => h('tr',
                        h('td', String(i.id)), h('td', `${i.label || i.code} (${i.code})`), h('td', badge(String(i.state).replace(/_/g, ' '), INF_STATE[i.state])),
                        h('td', stamp(i.at))))) : h('p.pf-muted', 'No infractions on record.'));

                    const work = arr(res.work);
                    const workCard = card('Work', work.length ? table(['Job', 'Credit', 'Wage', 'When'], work.map((w) => h('tr',
                        h('td', String(w.job || '')), h('td', dur(w.creditSeconds)), h('td', money(w.wage)), h('td', stamp(w.at))))) : h('p.pf-muted', 'No shifts yet.'));

                    let trustCard = null;
                    if (res.trust) {
                        const t = obj(res.trust);
                        trustCard = t.available === false ? card('Trust account', h('p.pf-muted', 'The trust office is unavailable right now.'))
                            : card('Trust account (read only)', h('div.pf-grid.pfc-stats', stat('Available', money(t.balance)), stat('Incoming', money(t.incoming)), stat('Outgoing', money(t.outgoing))),
                                arr(t.recent).length ? table(['Move', 'Amount', 'State', 'When'], arr(t.recent).map((r) => h('tr',
                                    h('td', String(r.kind || '')), h('td', money(r.amount)), h('td', String(r.state || '')), h('td', stamp(r.at))))) : null);
                    }

                    const actions = [];
                    if (can.housing) {
                        const cellSel = h('select.pf-select', { 'aria-label': 'Move to cell' }, arr(res.cellOptions).length
                            ? arr(res.cellOptions).map((c) => h('option', { value: c.id }, `${c.id} · block ${c.block} · ${c.classification} · ${c.free} free`))
                            : [h('option', { value: '' }, 'No cell with room')]);
                        const classSel = h('select.pf-select', { 'aria-label': 'Classification' }, arr(init.classes).map((c) => h('option', { value: c, selected: c === m.classification }, String(c))));
                        const reason = h('input.pf-input', { maxlength: '120', placeholder: 'Reason' });
                        actions.push(card('Housing',
                            field('Move to cell', h('div.pf-row', cellSel, btn('Move', () => {
                                if (!cellSel.value) return;
                                act('assignCell', { cid, cellId: cellSel.value }, 'Inmate moved', inmate);
                            }, 'primary'))),
                            field('Classification', h('div.pf-row', classSel, reason, btn('Set', () => act('setClassification',
                                { cid, classification: classSel.value, reason: reason.value }, 'Classification set', inmate))))));
                    }
                    if (can.report) actions.push(reportForm(cid, init, inmate));
                    setBody(h('div.pf-stack', h('div.pf-row', back), ident, sentence, h('div.pfc-cols', h('div.pf-stack', restrictions, infCard, workCard), h('div.pf-stack', ...actions, trustCard))));
                });
            }

            function evidenceIds(text) {
                const parts = String(text || '').split(/[\s,]+/).filter(Boolean);
                const ids = parts.map((x) => Number(x));
                if (ids.some((n) => !Number.isInteger(n) || n < 1)) return null;
                return ids;
            }
            function reportForm(cid, init, after) {
                const code = h('select.pf-select', { 'aria-label': 'Offence' }, arr(init.codes).map((c) => h('option', { value: c.code }, `${c.code} · ${c.label} (severity ${c.severity})`)));
                const ev = h('input.pf-input', { placeholder: 'Evidence ids, e.g. 12, 15', maxlength: '120' });
                const when = h('input.pf-input', { type: 'number', min: '0', step: '1', placeholder: 'Hearing in … minutes (optional)' });
                return card('Report an infraction',
                    field('Offence', code), field('Evidence', ev), field('Hearing', when),
                    h('p.pf-small.pf-muted', `The inmate is told at once and gets at least ${dur(obj(init.limits).minNoticeSeconds)} notice before a hearing.`),
                    h('div.pf-row', btn('Report', () => {
                        const ids = evidenceIds(ev.value);
                        if (!ids) { ctx.notify('Evidence ids are whole numbers', 'error'); return; }
                        const payload = { cid, code: code.value };
                        if (ids.length) payload.evidenceIds = ids;
                        if (when.value !== '') payload.hearingInMinutes = Number(when.value);
                        act('reportInfraction', payload, (r) => `Infraction #${r.infractionId} reported`, after);
                    }, 'danger')));
            }

            // ── cells ───────────────────────────────────────────────────────────────────────
            function cells() {
                load('cells', {}, (res) => {
                    const can = obj(state.init && state.init.can);
                    const list = arr(res.cells);
                    const overflow = arr(res.overflow);
                    setBody(h('div.pf-stack',
                        overflow.length ? card('Housed without a cell', h('p.pf-muted', 'Give these inmates a cell.'),
                            h('div.pf-list', overflow.map((o) => h('div.pf-list-item', h('span', `${o.name || o.cid} (${o.cid}) · ${o.classification}`),
                                btn('Open', () => openInmate(o.cid, 'cells')))))) : null,
                        list.length ? table(['Cell', 'Class', 'Beds', 'Occupants', 'Service', ''], list.map((c) => {
                            const occ = arr(c.occupants);
                            return h('tr',
                                h('td', h('div.pf-strong', c.id), h('div.pf-small.pf-muted', `Block ${c.block}`)),
                                h('td', String(c.classification)),
                                h('td', `${occ.length} / ${c.capacity}`),
                                h('td', occ.length ? h('div.pfc-occ', occ.map((o) => h('button.pfc-link', { type: 'button', onclick: () => openInmate(o.cid, 'cells') }, o.name || o.cid))) : h('span.pf-muted', 'Empty')),
                                h('td', c.outOfService ? badge('Out of service', 'warn') : badge('In service', 'ok')),
                                h('td', can.housing ? btn(c.outOfService ? 'Return to service' : 'Take out of service', () => act('setCellService',
                                    { cellId: c.id, outOfService: !c.outOfService },
                                    (r) => (c.outOfService ? `Cell ${c.id} back in service` : `Cell ${c.id} out of service, ${Number(r.moved) || 0} moved`), cells), c.outOfService ? '' : 'danger') : null));
                        })) : empty('No cells are configured.')));
                });
            }

            // ── routine and headcounts ──────────────────────────────────────────────────────
            function countResult(r) {
                const missing = arr(r.missing);
                return card('Count recorded',
                    h('p', `${Number(r.present) || 0} present of ${Number(r.expected) || 0} expected`),
                    missing.length ? h('p', badge(`${missing.length} missing`, 'bad'), ' ', missing.map((c) => who(c, r.names)).join(', ')) : h('p', badge('All accounted for', 'ok')),
                    arr(r.offline).length ? h('p.pf-muted', `${arr(r.offline).length} logged off during the count (not missing)`) : null);
            }
            function schedule() {
                load('schedule', {}, (res) => {
                    const can = obj(state.init && state.init.can);
                    const ph = obj(res.phase);
                    const result = h('div');
                    const open = res.openCount;
                    setBody(h('div.pf-stack',
                        card('Now', h('p', h('span.pf-strong', ph.label || '—'), ` · ends ${rel(ph.endsAt, res.now)} (${clock(ph.endsAt)})`),
                            res.lockdown ? h('p', badge('Lockdown: the routine is suspended', 'bad')) : null,
                            h('p.pf-muted', res.nextCount ? `Next headcount ${rel(res.nextCount, res.now)} (${clock(res.nextCount)})` : 'No headcount due'),
                            open ? h('p', badge('Count open', 'accent'), ` ${Number(open.expected) || 0} expected, closes ${rel(open.closesAt, res.now)}`) : null,
                            can.count ? h('div.pf-row', btn('Conduct count', () => act('conductCount', {}, null, (r) => { result.innerHTML = ''; result.appendChild(countResult(r)); }), 'primary'),
                                h('span.pf-small.pf-muted', 'From inside the walls; presence is the server\'s.')) : null),
                        result,
                        card('Routine', table(['Phase', 'From', 'To', ''], arr(res.upcoming).map((u) => h('tr' + (u.current ? '.pfc-current' : ''),
                            h('td', u.label || u.name), h('td', clock(u.startsAt)), h('td', clock(u.endsAt)),
                            h('td', u.current ? badge('Now', 'accent') : u.count ? badge('Count', '') : u.meal ? badge(String(u.meal), '') : null))))),
                        card('Last headcounts', arr(res.counts).length ? table(['Closed', 'Present', 'Missing', 'By'], arr(res.counts).map((c) => h('tr',
                            h('td', c.closedAt ? stamp(c.closedAt) : 'open'),
                            h('td', `${Number(c.present) || 0} / ${Number(c.expected) || 0}`),
                            h('td', c.interrupted ? badge('Interrupted by a restart', 'warn') : arr(c.missing).length ? arr(c.missing).map((m) => who(m, res.names)).join(', ') : '—'),
                            h('td', c.by ? who(c.by, res.names) : 'Routine')))) : empty('No headcounts yet.'))));
                });
            }

            // ── discipline ──────────────────────────────────────────────────────────────────
            function hearingForm(inf) {
                const lim = obj(state.init && state.init.limits);
                const verdict = h('select.pf-select', { 'aria-label': 'Verdict' }, h('option', { value: 'guilty' }, 'Guilty'), h('option', { value: 'not_guilty' }, 'Not guilty'));
                const note = h('textarea.pf-textarea', { maxlength: '255', rows: '2', placeholder: 'Findings' });
                const forfeit = h('input.pf-input', { type: 'number', min: '0', max: String(lim.maxForfeitMinutes || 60), placeholder: `Forfeit work credit, minutes (max ${lim.maxForfeitMinutes || 60})` });
                const solitary = h('input.pf-input', { type: 'number', min: '0', max: String(lim.maxSolitaryMinutes || 60), placeholder: `Solitary, minutes (max ${lim.maxSolitaryMinutes || 60})` });
                const privs = arr(state.init && state.init.privileges).map((kind) => {
                    const box = h('input', { type: 'checkbox', value: kind, 'aria-label': `Restrict ${kind}` });
                    const hours = h('input.pf-input.pfc-hours', { type: 'number', min: '1', max: String(lim.maxPrivilegeHours || 168), value: '24', 'aria-label': `${kind} hours` });
                    return { kind, box, hours, el: h('label.pfc-priv', box, ` ${kind} `, hours, ' h') };
                });
                const sanctions = h('div.pf-stack', field('Forfeit', forfeit), field('Solitary', solitary), field('Restrict privileges', h('div.pfc-privs', privs.map((p) => p.el))));
                verdict.addEventListener('change', () => { sanctions.hidden = verdict.value !== 'guilty'; });
                return card(`Hearing on #${inf.id} · ${inf.label || inf.code}`,
                    h('p.pf-small.pf-muted', 'An online inmate attends: stand with them. An offline inmate is heard in absentia only after a scheduled hearing time. The reporting officer cannot hear the case.'),
                    field('Verdict', verdict), field('Findings', note), sanctions,
                    h('div.pf-row', btn('Record decision', () => {
                        const payload = { id: inf.id, verdict: verdict.value, note: note.value };
                        if (verdict.value === 'guilty') {
                            if (forfeit.value !== '') payload.forfeitMinutes = Number(forfeit.value);
                            if (solitary.value !== '') payload.solitaryMinutes = Number(solitary.value);
                            const chosen = privs.filter((p) => p.box.checked).map((p) => ({ kind: p.kind, hours: Number(p.hours.value) }));
                            if (chosen.length) payload.privileges = chosen;
                        }
                        act('holdHearing', payload, (r) => {
                            const f = r.sanction && r.sanction.forfeit;
                            const extra = f ? (f.state === 'applied' ? ', credit forfeited' : f.state === 'pending' ? ', forfeit pending with the court system' : ', forfeit refused') : '';
                            return `Hearing recorded: ${String(r.state || '').replace(/_/g, ' ')}${extra}`;
                        }, () => { state.hearing = null; discipline(); });
                    }, 'primary'), btn('Close', () => { state.hearing = null; discipline(); }, 'ghost')));
            }
            function sanctionText(s) {
                if (!s || typeof s !== 'object') return '';
                const parts = [];
                if (s.verdict) parts.push(s.verdict === 'auto' ? 'automatic hearing' : String(s.verdict).replace(/_/g, ' '));
                arr(s.privileges).forEach((p) => parts.push(`${p.kind} ${p.hours} h`));
                if (s.solitary) parts.push(`solitary ${s.solitary.minutes} min`);
                if (s.forfeit) parts.push(`forfeit ${dur(s.forfeit.seconds)} (${s.forfeit.state})`);
                return parts.join(' · ');
            }
            function discipline() {
                const f = state.inf;
                load('infractions', { filter: f.filter, page: f.page }, (res) => {
                    const can = obj(state.init && state.init.can);
                    const list = arr(res.list);
                    const tabs = h('div.pf-row.pfc-wrap', { role: 'tablist' }, [['open', 'Awaiting hearing'], ['closed', 'Decided'], ['all', 'All']].map(([id, label]) =>
                        h('button.pf-btn.sm' + (f.filter === id ? '.primary' : '.ghost'), { type: 'button', role: 'tab', 'aria-selected': f.filter === id ? 'true' : 'false',
                            onclick: () => { f.filter = id; f.page = 1; state.hearing = null; discipline(); } }, label)));
                    const rows = list.map((i) => {
                        const openState = i.state === 'reported' || i.state === 'hearing_scheduled';
                        let actions = null;
                        if (can.hearing && openState) {
                            const mins = h('input.pf-input.pfc-mins', { type: 'number', min: '0', step: '1', placeholder: 'min', 'aria-label': 'Hearing in minutes' });
                            actions = h('div.pf-row.pfc-wrap', mins,
                                btn('Schedule', () => {
                                    if (mins.value === '') { ctx.notify('Enter the minutes until the hearing', 'error'); return; }
                                    act('scheduleHearing', { id: i.id, inMinutes: Number(mins.value) }, (r) => `Hearing at ${clock(r.hearingAt)}`, discipline);
                                }),
                                btn('Hold hearing', () => { state.hearing = i; discipline(); }, 'primary'));
                        }
                        return h('tr',
                            h('td', String(i.id)),
                            h('td', h('button.pfc-link', { type: 'button', onclick: () => openInmate(i.cid, 'discipline') }, who(i.cid, res.names))),
                            h('td', `${i.label || i.code} (${i.code})`, h('div.pf-small.pf-muted', `severity ${i.severity}`)),
                            h('td', badge(String(i.state).replace(/_/g, ' '), INF_STATE[i.state]), openState ? null : h('div.pf-small.pf-muted', sanctionText(i.sanction))),
                            h('td', stamp(i.at), h('div.pf-small.pf-muted', i.reportedBy ? `by ${who(i.reportedBy, res.names)}` : 'by the system')),
                            h('td', i.hearingAt ? `${clock(i.hearingAt)} (${rel(i.hearingAt, res.now)})` : '—'),
                            h('td', actions));
                    });
                    const pager = h('div.pf-row.pfc-pager',
                        h('button.pf-btn.sm', { type: 'button', disabled: f.page <= 1, onclick: () => { f.page -= 1; discipline(); } }, 'Previous'),
                        h('span.pf-muted', `Page ${Number(res.page) || 1}`),
                        h('button.pf-btn.sm', { type: 'button', disabled: !res.hasMore, onclick: () => { f.page += 1; discipline(); } }, 'Next'));
                    setBody(h('div.pf-stack', tabs,
                        state.hearing ? hearingForm(state.hearing) : null,
                        list.length ? table(['#', 'Inmate', 'Offence', 'State', 'Reported', 'Hearing', ''], rows) : empty(f.filter === 'open' ? 'No infraction is waiting for a hearing.' : 'No infractions here.'),
                        pager,
                        h('p.pf-small.pf-muted', 'Report an infraction from the inmate\'s page.')));
                });
            }

            // ── visits ──────────────────────────────────────────────────────────────────────
            function visits() {
                load('visits', {}, (res) => {
                    const list = arr(res.visits);
                    setBody(h('div.pf-stack',
                        h('p.pf-small.pf-muted', 'Today\'s board. A search is done standing with the visitor; with nobody on duty visits go ahead unsearched.'),
                        list.length ? table(['Time', 'Inmate', 'Visitor', 'Kind', 'State', ''], list.map((v) => {
                            const waiting = v.state === 'booked' || v.state === 'checked_in';
                            const note = h('input.pf-input.pfc-note', { maxlength: '200', placeholder: 'Reason to deny', 'aria-label': 'Reason to deny' });
                            return h('tr',
                                h('td', clock(v.slotAt), h('div.pf-small.pf-muted', rel(v.slotAt, res.now))),
                                h('td', who(v.inmate, res.names)),
                                h('td', who(v.visitor, res.names)),
                                h('td', badge(String(v.kind || 'social'), v.kind === 'attorney' ? 'accent' : '')),
                                h('td', badge(String(v.state).replace(/_/g, ' '), VISIT_STATE[v.state]), v.searched ? h('div.pf-small', badge('Searched', 'ok')) : null),
                                h('td', waiting ? h('div.pf-row.pfc-wrap',
                                    v.searched ? null : btn('Clear search', () => act('visitSearch', { id: v.id, allow: true }, 'Visitor cleared', visits), 'primary'),
                                    note, btn('Deny', () => act('visitSearch', { id: v.id, allow: false, note: note.value }, 'Visit denied', visits), 'danger'),
                                    btn('Cancel', () => act('visitCancel', { id: v.id }, 'Visit cancelled', visits), 'ghost')) : null));
                        })) : empty('No visits today.')));
                });
            }

            // ── lockdown and alarms ─────────────────────────────────────────────────────────
            function security() {
                load('security', {}, (res) => {
                    const can = obj(state.init && state.init.can);
                    const lim = obj(state.init && state.init.limits);
                    let control = null;
                    if (can.lockdown) {
                        if (res.lockdown) {
                            control = h('div.pf-row', btn('End lockdown', () => act('setLockdown', { on: false }, 'Lockdown ended', () => { refreshStrip(); security(); }), 'primary'));
                        } else {
                            const reason = h('input.pf-input', { maxlength: '120', placeholder: 'Reason' });
                            const minutes = h('input.pf-input.pfc-mins', { type: 'number', min: '1', max: String(lim.lockdownMaxMinutes || 240), placeholder: `min (≤ ${lim.lockdownMaxMinutes || 240})`, 'aria-label': 'Minutes' });
                            control = h('div.pf-row.pfc-wrap', reason, minutes, btn('Start lockdown', () => {
                                const payload = { on: true, reason: reason.value };
                                if (minutes.value !== '') payload.minutes = Number(minutes.value);
                                act('setLockdown', payload, 'Lockdown started: gates and doors locked', () => { refreshStrip(); security(); });
                            }, 'danger'));
                        }
                    }
                    const alarms = arr(res.alarms);
                    const doors = arr(res.doors);
                    setBody(h('div.pf-stack',
                        card('Lockdown',
                            res.lockdown ? h('p', badge('Lockdown in force', 'bad'), ' ', res.lockdownReason || '') : h('p', badge('Normal operation', 'ok')),
                            res.lockdown && res.lockdownUntil ? h('p.pf-muted', `Ends ${rel(res.lockdownUntil, res.now)} (${clock(res.lockdownUntil)})${res.lockdownBy ? ` · ordered by ${who(res.lockdownBy, res.names)}` : ''}`) : null,
                            control || h('p.pf-small.pf-muted', 'A sergeant or higher starts and ends a lockdown.')),
                        card(`Open alarms (${alarms.length})`, alarms.length ? table(['#', 'Alarm', 'When', ''], alarms.map((a) => h('tr',
                            h('td', String(a.id)), h('td', a.label || a.kind, h('div.pf-small.pf-muted', String(a.kind || ''))), h('td', `${clock(a.at)} (${rel(a.at, res.now)})`),
                            h('td', can.alarms ? btn('Clear', () => act('clearAlarm', { id: a.id }, 'Alarm cleared', security)) : null)))) : empty('No open alarms.')),
                        card('Security doors', doors.length ? table(['Door', 'State'], doors.map((d) => h('tr', h('td', d.label || d.id),
                            h('td', d.locked === true ? badge('Locked', 'ok') : d.locked === false ? badge('Unlocked', 'warn') : badge('Unknown', ''))))) : empty('No security doors configured.'),
                        h('p.pf-small.pf-muted', 'Doors are worked from the gatehouse controls.')),
                        res.openEscapes ? card('Escapes', h('p', badge(`${res.openEscapes} escapee(s) at large`, 'bad'))) : null));
                });
            }

            // ── cameras (listed only) ───────────────────────────────────────────────────────
            function cameras() {
                load('cameras', {}, (res) => {
                    const list = arr(res.cameras);
                    const points = arr(res.controlPoints).map(String).join(', ') || 'the gatehouse';
                    const pos = (c) => (c && typeof c === 'object' ? `${Math.round(Number(c.x) || 0)}, ${Math.round(Number(c.y) || 0)}, ${Math.round(Number(c.z) || 0)}` : '—');
                    setBody(h('div.pf-stack',
                        h('p.pfc-note', `Cameras are watched at the control point (${points}) with /prisoncam <number>. This list shows where they are; there is no recording.`),
                        list.length ? table(['No.', 'Camera', 'Position'], list.map((c) => h('tr', h('td', String(c.index)), h('td', c.label || c.id, h('div.pf-small.pf-muted', String(c.id || ''))), h('td', pos(c.coords)))))
                            : empty('No cameras are configured.')));
                });
            }

            // ── trust accounts (read only) ──────────────────────────────────────────────────
            function trust() {
                load('trust', {}, (res) => {
                    const list = arr(res.accounts);
                    const detail = h('div');
                    setBody(h('div.pf-stack',
                        h('p.pf-small.pf-muted', 'Read only. Money moves at the trust window and through the bank ledger.'),
                        h('div.pf-grid.pfc-stats', stat('Held in trust', money(res.total)), stat('Accounts', list.length)),
                        detail,
                        list.length ? table(['Account', 'Balance', ''], list.map((a) => h('tr.pfc-click', { tabindex: '0', onclick: () => show(a.cid) },
                            h('td', who(a.cid, res.names)), h('td', money(a.balance)), h('td', a.held ? badge('Held here', 'accent') : badge('Released', ''))))) : empty('No trust account holds money.')));
                    async function show(cid) {
                        const r = await call('trust', { cid });
                        detail.innerHTML = '';
                        if (!r.ok) { detail.appendChild(h('div.pfapp-error', { role: 'alert' }, errText(r))); return; }
                        detail.appendChild(card(`${r.name || r.cid} (${r.cid})`,
                            h('div.pf-grid.pfc-stats', stat('Available', money(r.balance)), stat('Incoming', money(r.incoming)), stat('Outgoing', money(r.outgoing))),
                            arr(r.recent).length ? table(['Move', 'Amount', 'State', 'When'], arr(r.recent).map((x) => h('tr', h('td', String(x.kind || '')), h('td', money(x.amount)),
                                h('td', String(x.state || '')), h('td', stamp(x.at))))) : empty('No moves.')));
                    }
                    body.querySelectorAll('tr.pfc-click').forEach((tr, i) => tr.addEventListener('keydown', (ev) => { if (ev.key === 'Enter') show(list[i].cid); }));
                });
            }

            const PAGES = { overview, population, inmate, cells, schedule, discipline, visits, security, cameras, trust };

            // ── start ───────────────────────────────────────────────────────────────────────
            loading();
            const init = await call('init');
            if (!init.ok) {
                nav.innerHTML = '';
                failed(init, () => { container.innerHTML = ''; this.mount(container, ctx); });
                return;
            }
            state.init = init;
            const me = obj(init.me);
            sub.textContent = `Bolingbroke Penitentiary · ${me.name || ''}${me.gradeLabel ? ', ' + me.gradeLabel : ''}`;
            renderStrip(init.status);
            go('overview');
            // Escape in a form field leaves it (back to the section); the shells close windows themselves
            container.addEventListener('keydown', (ev) => {
                if (ev.key === 'Escape' && ev.target && ev.target.matches && ev.target.matches('input, select, textarea')) { ev.target.blur(); body.focus(); }
            });
            timers.set(ctx, setInterval(refreshStrip, 30000));
        },
        unmount(ctx) {
            const t = timers.get(ctx);
            if (t) clearInterval(t);
            timers.delete(ctx);
        },
    });
})();
