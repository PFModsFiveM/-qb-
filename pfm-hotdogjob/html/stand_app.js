// Hot Dog Stand: the stand's shift, earnings and reputation.
(function () {
    PFApps.register('hotdogstand', {
        mount(container, ctx) {
            const { h, money } = ctx;
            const body = h('div.pf-app-body.pf-stack');
            container.appendChild(h('div.pf-app',
                h('div.pf-app-header',
                    h('div.pf-app-title', h('span.pf-icon', '🌭'), h('div', 'Hot Dog Stand', h('div.pf-app-sub', 'Your stand today'))),
                    h('button.pf-btn.sm', { onclick: load }, 'Refresh')),
                body));
            function stat(label, value) { return h('div.pf-card.pf-stat', h('div.pf-stat-value', value), h('div.pf-stat-label', label)); }
            async function load() {
                const d = await ctx.rpc('status');
                body.innerHTML = '';
                if (!d || !d.ok) { body.appendChild(h('div.pf-empty', 'No stand data.')); return; }
                body.appendChild(h('div.pf-row.between',
                    h('span.pf-badge' + (d.standOut ? '.ok' : ''), d.standOut ? 'Stand out' : 'No stand out'),
                    h('button.pf-btn.sm', { onclick: async () => { const r = await ctx.rpc('waypoint'); ctx.notify(r && r.ok ? 'Waypoint set to the depot' : 'No location', r && r.ok ? 'success' : 'error'); } }, 'Waypoint: depot')));
                body.appendChild(h('div.pf-grid',
                    stat('Hot dogs sold', String(d.sold)), stat('Earned this shift', money(d.earned)),
                    stat('Sale streak', String(d.streak)), stat('Reputation', `${d.reputation} / ${d.maxReputation}`)));
                const pct = Math.max(0, Math.min(100, (d.reputation / Math.max(1, d.maxReputation)) * 100));
                body.appendChild(h('div.pf-card', h('div.pf-small.pf-muted', 'Reputation raises your prices and the quality customers expect'),
                    h('div', { style: { height: '8px', background: 'var(--pf-bg-3)', borderRadius: '6px', marginTop: '8px' } },
                        h('div', { style: { width: pct + '%', height: '100%', background: 'var(--pf-accent)', borderRadius: '6px' } }))));
                if (!d.standOut) body.appendChild(h('div.pf-small.pf-muted', `Take a stand at the depot (deposit ${money(d.deposit)}, refunded when you bring it back).`));
            }
            ctx.on('sale', load);
            load();
        },
    });
})();
