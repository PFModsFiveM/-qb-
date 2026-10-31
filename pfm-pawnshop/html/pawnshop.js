/*
 * Pawn Shop app (pf-devices platform module, tablet + computer): today's buy prices, what the
 * player carries of each, the shop's hours and location, and the player's melting job. Read-only:
 * the data comes from server/devices.lua; selling and melting stay at the counter.
 */
(function () {
    'use strict';
    if (!window.PFApps) return;

    const ERRORS = {
        not_installed: 'Install the Pawn Shop app from the App Store first',
        rate_limited: 'Slow down a little',
        server_error: 'Something went wrong',
        request_failed: 'Could not reach the server',
        no_player: 'Your character is not loaded',
    };

    function create(container, ctx) {
        const { h, money } = ctx;
        const st = { view: null, error: null, loadedAt: Date.now() };
        let alive = true;
        let ticker = null;
        const root = h('div.pf-app.pfm-pawn');
        container.appendChild(root);
        const num = (v, d = 0) => (Number.isFinite(Number(v)) ? Number(v) : d);
        const text = (v) => (v == null ? '' : String(v));
        const pad = (n) => String(num(n)).padStart(2, '0');
        const left = (s) => Math.max(0, num(s) - Math.floor((Date.now() - st.loadedAt) / 1000));
        const duration = (s) => (s >= 3600 ? `${Math.floor(s / 3600)} h ${Math.floor((s % 3600) / 60)} min` : s >= 60 ? `${Math.floor(s / 60)} min` : `${s} s`);

        async function load() {
            const res = await ctx.rpc('getInit');
            if (!alive) return;
            if (!res || res.ok === false) st.error = ERRORS[res && res.error] || 'The pawn shop is not answering';
            else { st.error = null; st.view = res; st.loadedAt = Date.now(); }
            render();
        }

        function hoursCard(v) {
            const hr = v.hours || {};
            let status;
            if (!hr.limited) status = h('span.pf-badge.ok', 'Open 24/7');
            else if (hr.openNow === false) status = h('span.pf-badge.bad', 'Closed now');
            else status = h('span.pf-badge.ok', 'Open now');
            return h('div.pf-card',
                h('div.pf-row.between', h('div.pf-strong', 'Opening hours'), status),
                h('div.pf-muted.pf-small', hr.limited ? `Every day ${pad(hr.open)}:00 – ${pad(hr.close)}:59` : 'The counter never closes.'),
                hr.hour != null ? h('div.pf-muted.pf-small', `City time: ${pad(hr.hour)}:${pad(hr.minute)}`) : null,
                h('div.pf-list.pfm-pawn-places', (v.locations || []).map((l) => h('div.pf-list-item', h('span', text(l.label)),
                    h('button.pf-btn.sm', { type: 'button', onclick: () => { ctx.setWaypoint(num(l.x), num(l.y)); ctx.notify(`Waypoint set: ${text(l.label)}`, 'success'); } }, 'Waypoint')))));
        }

        function meltCard(v) {
            const m = v.melting;
            if (!m) {
                return h('div.pf-card', h('div.pf-row.between', h('div.pf-strong', 'Melting'), h('span.pf-badge', 'Nothing in the furnace')),
                    h('div.pf-muted.pf-small', 'Bring jewellery to the counter to have it melted down.'));
            }
            const wait = left(m.readyIn);
            const ready = m.ready || wait <= 0;
            return h('div.pf-card',
                h('div.pf-row.between', h('div.pf-strong', `Melting ${num(m.amount)} × ${text(m.label)}`),
                    h('span.pf-badge.' + (ready ? 'ok' : 'accent'), ready ? 'Ready to collect' : `Ready in ${duration(wait)}`)),
                h('div.pfm-pawn-chips', (m.rewards || []).map((r) => h('span.pf-badge', `${text(r.label)} × ${num(r.amount)}`))),
                ready ? h('div.pf-muted.pf-small', `Collect it at the counter. After ${duration(left(m.forfeitIn))} a new melt can replace it.`) : null);
        }

        function render() {
            if (!alive) return;
            root.textContent = '';
            root.appendChild(h('div.pf-app-header',
                h('div.pf-app-title', h('span.pf-icon', '💍'), h('div', 'Pawn Shop', h('div.pf-app-sub', 'Prices, hours and your melting'))),
                h('button.pf-btn.sm.ghost', { type: 'button', onclick: load }, 'Refresh')));
            const body = h('div.pf-app-body.pf-stack');
            root.appendChild(body);
            if (st.error) { body.appendChild(h('div.pf-empty', st.error)); return; }
            const v = st.view;
            if (!v) { body.appendChild(h('div.pf-empty', 'Loading…')); return; }
            body.appendChild(h('div.pf-grid.pfm-pawn-top', hoursCard(v), meltCard(v)));
            const prices = v.prices || [];
            body.appendChild(h('div.pf-card',
                h('div.pf-row.between', h('div.pf-strong', 'What we pay today'),
                    h('span.pf-muted.pf-small', `${v.fluctuating ? 'Prices change every day. ' : ''}Paid in ${v.paysTo === 'bank' ? 'to your bank' : 'cash'}.`)),
                prices.length ? h('div.pfm-pawn-scroll', h('table.pf-table',
                    h('thead', h('tr', h('th', 'Item'), h('th', 'Each'), h('th', 'You carry'), h('th', 'Worth'))),
                    h('tbody', prices.map((p) => h('tr' + (num(p.have) > 0 ? '.pfm-pawn-have' : ''), h('td', text(p.label)), h('td', money(p.price)),
                        h('td', text(num(p.have))), h('td', num(p.have) > 0 ? money(num(p.have) * num(p.price)) : '—')))))) : h('div.pf-empty', 'The shop is not buying anything right now.')));
            const meltable = v.meltable || [];
            if (meltable.length) {
                body.appendChild(h('div.pf-card', h('div.pf-strong', 'What we melt'),
                    h('div.pfm-pawn-scroll', h('table.pf-table',
                        h('thead', h('tr', h('th', 'Item'), h('th', 'Gives (each)'), h('th', 'Time (each)'), h('th', 'You carry'))),
                        h('tbody', meltable.map((m) => h('tr', h('td', text(m.label)),
                            h('td', (m.rewards || []).map((r) => `${num(r.amount)} × ${text(r.label)}`).join(', ')),
                            h('td', `${Math.max(1, Math.round(num(m.minutesEach) * 60))} s`), h('td', text(num(m.have))))))))));
            }
        }

        ticker = setInterval(() => { if (st.view && st.view.melting) render(); }, 15000);
        render();
        return { start: load, destroy() { alive = false; if (ticker) clearInterval(ticker); } };
    }

    let instance = null;
    PFApps.register('pawnshop', {
        async mount(container, ctx) {
            if (instance) instance.destroy();
            instance = create(container, ctx);
            await instance.start();
        },
        unmount() { if (instance) instance.destroy(); instance = null; },
    });
})();
