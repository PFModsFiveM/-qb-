// Dive Guide: today's coral area, what is left, and what the buyer pays.
(function () {
    PFApps.register('diveguide', {
        mount(container, ctx) {
            const { h, money } = ctx;
            const body = h('div.pf-app-body.pf-stack');
            container.appendChild(h('div.pf-app',
                h('div.pf-app-header',
                    h('div.pf-app-title', h('span.pf-icon', '🤿'), h('div', 'Dive Guide', h('div.pf-app-sub', 'Coral diving off the coast'))),
                    h('button.pf-btn.sm', { onclick: load }, 'Refresh')),
                body));
            async function waypoint(payload) {
                const r = await ctx.rpc('waypoint', payload);
                ctx.notify(r && r.ok ? 'Waypoint set' : 'No location', r && r.ok ? 'success' : 'error');
            }
            async function load() {
                const d = await ctx.rpc('status');
                body.innerHTML = '';
                if (!d || !d.ok) { body.appendChild(h('div.pf-empty', 'No dive data.')); return; }
                body.appendChild(h('div.pf-card.pf-row.between',
                    h('div', h('div.pf-strong', d.area || 'Dive area'), h('div.pf-small.pf-muted', `${d.left} of ${d.total} coral spots left`)),
                    h('button.pf-btn.sm.primary', { onclick: () => waypoint({ target: 'area' }) }, 'Waypoint')));
                const prices = h('table.pf-table', h('tr', h('th', 'Coral'), h('th', 'Buyer pays')));
                (d.corals || []).forEach((c) => prices.appendChild(h('tr', h('td', c.label), h('td', `${money(c.price)} each`))));
                body.appendChild(h('div.pf-card.pf-stack', h('div.pf-strong', 'Prices'), prices,
                    (d.tiers || []).length ? h('div.pf-small.pf-muted', 'Bulk bonus: ' + d.tiers.map((t) => `${t.from}${t.to ? '-' + t.to : '+'} pieces: ${t.bonus}`).join(' · ')) : null));
                const buyers = h('div.pf-row', { style: { flexWrap: 'wrap' } });
                (d.buyers || []).forEach((b) => buyers.appendChild(h('button.pf-btn.sm', { onclick: () => waypoint({ target: 'buyer', id: b.id }) }, `Waypoint: ${b.label}`)));
                body.appendChild(h('div.pf-card.pf-stack', h('div.pf-strong', 'Sell your coral'), buyers));
            }
            ctx.on('changed', load);
            load();
        },
    });
})();
