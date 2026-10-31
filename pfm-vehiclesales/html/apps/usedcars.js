// Used Cars (pf-devices app, tablet and computer): the cars citizens put up for sale on the used lot,
// with price, tax, the seller's contact and a waypoint. A seller can change the price of their own
// listing; buying and taking a car back happen at the lot. Data and checks come from pfm-vehiclesales.
(function () {
    const ERRORS = { bad_price: 'Enter a whole price from $1', not_yours: 'That listing is not yours', bad_request: 'Something was missing', rate_limited: 'Slow down a little' };

    PFApps.register('usedcars', {
        mount(container, ctx) {
            const { h, money } = ctx;
            const state = { data: null, tab: 'all', q: '', sort: 'new', busy: false };
            const tabs = h('div.pf-tabs');
            const body = h('div.pf-app-body.pf-stack');
            container.appendChild(h('div.pf-app.pfu',
                h('div.pf-app-header',
                    h('div.pf-app-title', h('span.pf-icon', '🏷️'), h('div', 'Used Cars', h('div.pf-app-sub', 'Cars for sale by other citizens'))),
                    h('button.pf-btn.sm', { onclick: load }, 'Refresh')),
                tabs, body));

            function render() {
                const d = state.data;
                const all = d ? d.listings : [];
                const mine = all.filter((l) => l.mine);
                tabs.innerHTML = '';
                [['all', `For sale (${all.length})`], ['mine', `My listings (${mine.length})`]].forEach(([id, label]) => {
                    tabs.appendChild(h('div.pf-tab' + (state.tab === id ? '.active' : ''), { onclick: () => { state.tab = id; render(); } }, label));
                });
                body.innerHTML = '';
                if (!d) { body.appendChild(h('div.pf-empty', 'Loading…')); return; }
                const lots = h('div.pf-row', { style: { flexWrap: 'wrap' } }, d.lots.map((lot) => lot.coords
                    ? h('button.pf-btn.sm', { onclick: () => waypoint(lot) }, 'Waypoint: ' + lot.label) : null));
                const search = h('input.pf-input', { type: 'search', placeholder: 'Model, brand or plate', value: state.q, maxlength: 40 });
                search.addEventListener('change', () => { state.q = search.value.trim().toLowerCase(); render(); });
                const sort = h('select.pf-select', h('option', { value: 'new' }, 'Newest first'), h('option', { value: 'asc' }, 'Cheapest first'), h('option', { value: 'desc' }, 'Most expensive first'));
                sort.value = state.sort;
                sort.addEventListener('change', () => { state.sort = sort.value; render(); });
                body.appendChild(h('div.pf-toolbar.pfu-filters', search, sort, lots));
                let rows = (state.tab === 'mine' ? mine : all).filter((l) => !state.q || `${l.label} ${l.model} ${l.plate}`.toLowerCase().includes(state.q));
                if (state.sort === 'asc') rows = rows.slice().sort((a, b) => a.price - b.price);
                if (state.sort === 'desc') rows = rows.slice().sort((a, b) => b.price - a.price);
                if (!rows.length) { body.appendChild(h('div.pf-empty', state.tab === 'mine' ? 'You have no car on the lot. List one at the lot.' : 'No car is for sale.')); return; }
                const grid = h('div.pfu-grid');
                rows.forEach((l) => grid.appendChild(card(l, d)));
                body.appendChild(grid);
            }

            function card(l, d) {
                const extra = [];
                if (l.mine) {
                    const input = h('input.pf-input.pfu-price-input', { type: 'number', min: 1, step: 1, value: l.price });
                    extra.push(h('div.pf-row', input, h('button.pf-btn.sm', { onclick: () => reprice(l, Number(input.value)) }, 'Change price')));
                }
                return h('div.pf-card.pfu-card' + (l.mine ? '.pfu-mine' : ''),
                    h('div.pf-row.between', h('span.pf-strong', l.label), h('span.pfu-plate', l.plate)),
                    h('div.pfu-price', money(l.price)),
                    h('div.pf-small.pf-muted', [d.taxPercent ? `+ ${money(l.tax)} tax` : null, l.newPrice ? `new: ${money(l.newPrice)}` : null, l.category].filter(Boolean).join(' · ')),
                    l.description ? h('div.pfu-desc', l.description) : null,
                    h('div.pf-small', l.mine ? 'Your listing' : `Seller: ${l.seller || 'unknown'}${l.phone ? ' · ☎ ' + l.phone : ''}`),
                    extra);
            }

            async function waypoint(lot) { await ctx.setWaypoint(lot.coords.x, lot.coords.y); ctx.notify('Waypoint set: ' + lot.label, 'success'); }

            async function load() {
                const res = await ctx.rpc('list');
                if (!res || !res.ok) { ctx.notify('The listings are not available right now', 'error'); return; }
                state.data = res;
                render();
            }

            async function reprice(l, price) {
                if (state.busy) return;
                if (!(price >= 1 && Number.isInteger(price))) { ctx.notify(ERRORS.bad_price, 'error'); return; }
                state.busy = true;
                const res = await ctx.rpc('reprice', { id: l.id, price });
                state.busy = false;
                if (!res || !res.ok) ctx.notify(ERRORS[res && res.error] || 'That did not work', 'error');
                else ctx.notify(`${l.label}: now ${money(res.price)}`, 'success');
                load();
            }

            ctx.on('changed', () => load());
            render();
            load();
        },
    });
})();
