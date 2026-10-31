// Scrap List: the cars the scrapyard is buying now.
(function () {
    PFApps.register('scraplist', {
        mount(container, ctx) {
            const { h } = ctx;
            const list = h('div.pf-list');
            const yards = h('div.pf-row', { style: { flexWrap: 'wrap' } });
            container.appendChild(h('div.pf-app',
                h('div.pf-app-header',
                    h('div.pf-app-title', h('span.pf-icon', '🔩'), h('div', 'Scrap List', h('div.pf-app-sub', 'Bring one of these to the yard. Owned cars are refused.'))),
                    h('button.pf-btn.sm', { onclick: load }, 'Refresh')),
                h('div.pf-app-body.pf-stack', yards, list)));
            async function load() {
                const res = await ctx.rpc('list');
                list.innerHTML = '';
                yards.innerHTML = '';
                ((res && res.yards) || []).forEach((y) => yards.appendChild(h('button.pf-btn.sm', { onclick: async () => {
                    const r = await ctx.rpc('waypoint', { id: y.id });
                    ctx.notify(r && r.ok ? 'Waypoint set' : 'No location', r && r.ok ? 'success' : 'error');
                } }, `Waypoint: ${y.label}`)));
                const vehicles = (res && res.vehicles) || [];
                if (!vehicles.length) { list.appendChild(h('div.pf-empty', 'The yard is not buying anything right now. The list changes every hour.')); return; }
                vehicles.forEach((v) => list.appendChild(h('div.pf-list-item', h('div.pf-strong', v.label), h('span.pf-badge.accent', 'Wanted'))));
            }
            ctx.on('changed', load);
            load();
        },
    });
})();
