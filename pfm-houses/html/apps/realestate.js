// Real Estate (pf-devices apps, tablet and computer), one file for two apps:
//   realestate          houses for sale, the citizen's properties, and an agent's offer to answer
//   realestate-agency   Dynasty 8 agents: listings, sales to a customer nearby, the sales record
// Prices, costs, ownership and every action are decided by pfm-houses on the server.
(function () {
    const ERRORS = {
        not_agent: 'Only real estate agents can do that', off_duty: 'Go on duty first', unknown_house: 'That house does not exist',
        not_for_sale: 'That house is not for sale', bad_buyer: 'Choose a customer standing next to you', too_far: 'The customer is too far away',
        offer_pending: 'You already have an offer waiting for an answer', buyer_busy: 'That customer is answering another offer',
        house_offered: 'That house is already offered to someone', insufficient_funds: 'Not enough money in the bank account',
        expired: 'That offer has expired', not_found: 'That offer is no longer open', bad_price: 'Enter a valid price',
        bad_street: 'Enter a street name (letters, digits, spaces)', bad_tier: 'Choose a tier from 1 to 20', bad_request: 'Something was missing',
        party_left: 'The other party is no longer here', agent_unavailable: 'The agent can no longer sell this house', rate_limited: 'Slow down a little',
    };
    const STATUS = { available: ['For sale', 'ok'], pending: ['Offer open', 'warn'], sold: ['Sold', ''] };

    function day(ts) { return ts ? new Date(ts * 1000).toLocaleDateString([], { day: 'numeric', month: 'short' }) : ''; }

    function stat(h, label, value) {
        return h('div.pf-card.pf-stat', h('div.pf-stat-value', value), h('div.pf-stat-label', label));
    }

    function header(h, icon, title, sub, onRefresh, extra) {
        return h('div.pf-app-header',
            h('div.pf-app-title', h('span.pf-icon', icon), h('div', title, h('div.pf-app-sub', sub))),
            h('div.pf-row', extra || null, h('button.pf-btn.sm', { onclick: onRefresh }, 'Refresh')));
    }

    // ── citizens ──────────────────────────────────────────────────────────────────────────────
    PFApps.register('realestate', {
        mount(container, ctx) {
            const { h, money } = ctx;
            const state = { data: null, tab: 'sale', q: '', max: '', sort: 'asc', busy: false };
            const banner = h('div.pfr-banner');
            const tabs = h('div.pf-tabs');
            const body = h('div.pf-app-body.pf-stack');
            container.appendChild(h('div.pf-app.pfr', header(h, '🏠', 'Real Estate', 'Houses for sale and your properties', load), tabs, h('div.pf-stack.pfr-top', banner), body));

            function renderBanner() {
                banner.innerHTML = '';
                const o = state.data && state.data.offer;
                if (!o) return;
                banner.appendChild(h('div.pf-card.pfr-offer',
                    h('div.pf-stack', { style: { gap: '4px', flex: '1' } },
                        h('div.pf-strong', `${o.agent} offers you ${o.address}`),
                        h('div.pf-small.pf-muted', `${money(o.price)} + broker fee ${money(o.broker)} + transfer tax ${money(o.tax)}`),
                        h('div.pfr-total', 'Total ' + money(o.total))),
                    h('div.pf-row',
                        h('button.pf-btn.primary', { onclick: () => answer(o, true) }, 'Accept and pay'),
                        h('button.pf-btn.danger', { onclick: () => answer(o, false) }, 'Decline'))));
            }

            function render() {
                renderBanner();
                const d = state.data || { forSale: [], mine: [] };
                tabs.innerHTML = '';
                [['sale', `For sale (${d.forSale.length})`], ['mine', `My properties (${d.mine.length + (d.apartment ? 1 : 0)})`]].forEach(([id, label]) => {
                    tabs.appendChild(h('div.pf-tab' + (state.tab === id ? '.active' : ''), { onclick: () => { state.tab = id; render(); } }, label));
                });
                body.innerHTML = '';
                if (!state.data) { body.appendChild(h('div.pf-empty', 'Loading…')); return; }
                if (state.tab === 'sale') renderSale(d); else renderMine(d);
            }

            function renderSale(d) {
                const search = h('input.pf-input', { type: 'search', placeholder: 'Street or address', value: state.q, maxlength: 40 });
                const max = h('input.pf-input', { type: 'number', min: 0, placeholder: 'Max price', value: state.max });
                const sort = h('select.pf-select', h('option', { value: 'asc' }, 'Cheapest first'), h('option', { value: 'desc' }, 'Most expensive first'));
                sort.value = state.sort;
                search.addEventListener('change', () => { state.q = search.value.trim().toLowerCase(); render(); });
                max.addEventListener('change', () => { state.max = max.value; render(); });
                sort.addEventListener('change', () => { state.sort = sort.value; render(); });
                body.appendChild(h('div.pf-toolbar.pfr-filters', search, max, sort));
                let rows = d.forSale.filter((x) => (!state.q || String(x.address).toLowerCase().includes(state.q)) && (!Number(state.max) || x.price <= Number(state.max)));
                if (state.sort === 'desc') rows = rows.slice().reverse();
                if (!rows.length) { body.appendChild(h('div.pf-empty', d.forSale.length ? 'No house matches.' : 'No houses are for sale right now.')); return; }
                const grid = h('div.pfr-grid');
                rows.forEach((x) => grid.appendChild(h('div.pf-card.pfr-card',
                    h('div.pf-row.between', h('span.pf-strong', x.address), h('span.pf-badge.accent', 'Tier ' + x.tier)),
                    h('div.pfr-price', money(x.price)),
                    h('div.pf-small.pf-muted', `At the door: ${money(x.doorTotal)} with fees and ${money(x.tax)} tax`),
                    h('div.pf-small.pf-muted', `Through an agent: ${money(x.agentTotal)} (${d.brokerPercent}% broker fee)`),
                    h('div.pf-row.between', h('span.pf-small', x.garage ? '🚗 Garage' : 'No garage'),
                        x.coords ? h('button.pf-btn.sm', { onclick: () => waypoint(x.coords, x.address) }, 'Waypoint') : null))));
                body.appendChild(grid);
            }

            function renderMine(d) {
                const grid = h('div.pfr-grid');
                if (d.apartment) {
                    const a = d.apartment;
                    grid.appendChild(h('div.pf-card.pfr-card',
                        h('div.pf-row.between', h('span.pf-strong', a.label || 'Apartment'), h('span.pf-badge', 'Apartment')),
                        h('div.pf-small.pf-muted', a.building),
                        a.coords ? h('div.pf-row', h('button.pf-btn.sm', { onclick: () => waypoint(a.coords, a.building) }, 'Waypoint')) : null));
                }
                d.mine.forEach((x) => grid.appendChild(h('div.pf-card.pfr-card',
                    h('div.pf-row.between', h('span.pf-strong', x.address), h('span.pf-badge' + (x.role === 'owner' ? '.ok' : '.accent'), x.role === 'owner' ? 'Owner' : 'Key holder')),
                    h('div.pf-small.pf-muted', [`Tier ${x.tier}`, x.locked ? 'locked' : 'unlocked', x.garage ? 'garage' : null,
                        x.keys != null ? `${x.keys} other key holder${x.keys === 1 ? '' : 's'}` : null].filter(Boolean).join(' · ')),
                    x.coords ? h('div.pf-row', h('button.pf-btn.sm', { onclick: () => waypoint(x.coords, x.address) }, 'Waypoint')) : null)));
                if (!grid.childNodes.length) { body.appendChild(h('div.pf-empty', 'You do not own or hold a key to a property.')); return; }
                body.appendChild(grid);
            }

            async function waypoint(c, label) { await ctx.setWaypoint(c.x, c.y); ctx.notify('Waypoint set: ' + label, 'success'); }

            async function load() {
                const res = await ctx.rpc('list');
                if (!res || !res.ok) { ctx.notify(ERRORS[res && res.error] || 'Listings are not available right now', 'error'); return; }
                state.data = res;
                render();
            }

            async function answer(o, accept) {
                if (state.busy) return;
                state.busy = true;
                const res = await ctx.rpc('answerOffer', { id: o.id, accept });
                state.busy = false;
                if (!res || !res.ok) ctx.notify(ERRORS[res && res.error] || 'The sale did not go through', 'error');
                else ctx.notify(res.declined ? 'Offer declined' : `You bought ${o.address}`, 'success');
                load();
            }

            ctx.on('offer', (o) => { if (state.data) { state.data.offer = o; renderBanner(); } else load(); });
            ctx.on('offerClosed', () => load());
            ctx.on('changed', () => load());
            render();
            load();
        },
    });

    // ── Dynasty 8 agents ──────────────────────────────────────────────────────────────────────
    PFApps.register('realestate-agency', {
        mount(container, ctx) {
            const { h, money } = ctx;
            const state = { data: null, tab: 'listings', q: '', nearby: [], sellHouse: '', busy: false };
            const duty = h('span.pf-badge');
            const stats = h('div.pfr-stats');
            const tabs = h('div.pf-tabs');
            const body = h('div.pf-stack');
            container.appendChild(h('div.pf-app.pfr', header(h, '🏢', 'Dynasty 8', 'Listings, sales and commissions', load, duty), tabs, h('div.pf-app-body.pf-stack', stats, body)));

            function render() {
                const d = state.data;
                duty.className = 'pf-badge ' + (d && d.onDuty ? 'ok' : 'bad');
                duty.textContent = d && d.onDuty ? 'On duty' : 'Off duty';
                stats.innerHTML = '';
                if (d) {
                    stats.appendChild(stat(h, 'Sales, 7 days', String(d.stats.count)));
                    stats.appendChild(stat(h, 'Agency commission, 7 days', money(d.stats.agency)));
                    stats.appendChild(stat(h, 'My commission, 7 days', money(d.stats.mine)));
                    stats.appendChild(stat(h, 'For sale', String(d.listings.filter((l) => l.status === 'available').length)));
                }
                tabs.innerHTML = '';
                [['listings', 'Listings'], ['sell', 'Sell'], ['create', 'New listing'], ['sales', 'Sales']].forEach(([id, label]) => {
                    tabs.appendChild(h('div.pf-tab' + (state.tab === id ? '.active' : ''), { onclick: () => { state.tab = id; render(); } }, label));
                });
                body.innerHTML = '';
                if (!d) { body.appendChild(h('div.pf-empty', 'Loading…')); return; }
                if (d.requireDuty && !d.onDuty && state.tab !== 'sales' && state.tab !== 'listings') body.appendChild(h('div.pf-card.pf-small.pf-muted', 'Go on duty to sell or change listings.'));
                ({ listings: renderListings, sell: renderSell, create: renderCreate, sales: renderSales })[state.tab](d);
            }

            function renderListings(d) {
                const search = h('input.pf-input', { type: 'search', placeholder: 'Search address', value: state.q, maxlength: 40 });
                search.addEventListener('change', () => { state.q = search.value.trim().toLowerCase(); render(); });
                body.appendChild(h('div.pf-toolbar', search));
                const rows = d.listings.filter((l) => !state.q || String(l.address).toLowerCase().includes(state.q));
                if (!rows.length) { body.appendChild(h('div.pf-empty', 'No listings.')); return; }
                const table = h('table.pf-table', h('thead', h('tr', h('th', 'Address'), h('th', 'Tier'), h('th', 'Price'), h('th', 'Status'), h('th', ''))));
                const tbody = h('tbody');
                rows.forEach((l) => {
                    const st = STATUS[l.status] || [l.status, ''];
                    const actions = h('td.pfr-actions');
                    if (l.coords) actions.appendChild(h('button.pf-btn.sm', { onclick: () => ctx.setWaypoint(l.coords.x, l.coords.y) }, 'Waypoint'));
                    if (l.status === 'available') {
                        const input = h('input.pf-input.pfr-price-input', { type: 'number', min: d.priceRange.min, max: d.priceRange.max, value: l.price });
                        actions.appendChild(input);
                        actions.appendChild(h('button.pf-btn.sm', { onclick: () => reprice(l, Number(input.value)) }, 'Save price'));
                        actions.appendChild(h('button.pf-btn.sm.primary', { onclick: () => { state.sellHouse = l.id; state.tab = 'sell'; render(); } }, 'Sell'));
                    }
                    tbody.appendChild(h('tr', h('td', l.address, l.garage ? h('span.pf-small.pf-muted', ' · garage') : null), h('td', String(l.tier)), h('td', money(l.price)),
                        h('td', h('span.pf-badge' + (st[1] ? '.' + st[1] : ''), st[0])), actions));
                });
                table.appendChild(tbody);
                body.appendChild(table);
            }

            function renderSell(d) {
                if (d.offer) {
                    const o = d.offer;
                    body.appendChild(h('div.pf-card.pfr-offer',
                        h('div.pf-stack', { style: { gap: '4px', flex: '1' } },
                            h('div.pf-strong', `Waiting for ${o.buyer} to answer`),
                            h('div.pf-small.pf-muted', `${o.address}: ${money(o.price)} + ${money(o.broker)} broker fee + ${money(o.tax)} tax = ${money(o.total)}`)),
                        h('button.pf-btn.danger', { onclick: cancelOffer }, 'Withdraw offer')));
                    return;
                }
                const available = d.listings.filter((l) => l.status === 'available');
                if (!available.length) { body.appendChild(h('div.pf-empty', 'No house is for sale.')); return; }
                const house = h('select.pf-select', available.map((l) => h('option', { value: l.id }, `${l.address} (${money(l.price)})`)));
                if (state.sellHouse && available.some((l) => l.id === state.sellHouse)) house.value = state.sellHouse;
                house.addEventListener('change', () => { state.sellHouse = house.value; renderPreview(); });
                const preview = h('div.pf-small.pf-muted');
                function renderPreview() {
                    const l = available.find((x) => x.id === house.value);
                    if (!l) return;
                    const broker = Math.floor(l.price * d.commission.broker / 100);
                    preview.textContent = `Customer pays ${money(l.price)} + ${money(broker)} broker fee + the city's transfer tax. `
                        + `Agency gets ${d.commission.agency}% (${money(Math.floor(l.price * d.commission.agency / 100))}), you get ${d.commission.agent}% (${money(Math.floor(l.price * d.commission.agent / 100))}).`;
                }
                renderPreview();
                const customers = h('div.pf-list');
                function renderCustomers() {
                    customers.innerHTML = '';
                    if (!state.nearby.length) { customers.appendChild(h('div.pf-small.pf-muted', 'Nobody is standing next to you. The customer must be with you.')); return; }
                    state.nearby.forEach((p) => customers.appendChild(h('div.pf-list-item',
                        h('span', p.name, h('span.pf-small.pf-muted', ' #' + p.id)),
                        h('button.pf-btn.sm.primary', { onclick: () => sendOffer(house.value, p) }, 'Send offer'))));
                }
                renderCustomers();
                body.appendChild(h('div.pf-card.pf-stack',
                    h('div.pf-field', h('label', 'House'), house), preview,
                    h('div.pf-row.between', h('span.pf-strong', 'Customers next to you'), h('button.pf-btn.sm', { onclick: async () => { await findNearby(); renderCustomers(); } }, 'Look around')),
                    customers));
            }

            function renderCreate(d) {
                const street = h('input.pf-input', { maxlength: 48, placeholder: 'Street name, e.g. Grove Street' });
                const price = h('input.pf-input', { type: 'number', min: d.priceRange.min, max: d.priceRange.max, placeholder: 'Price' });
                const tier = h('select.pf-select', Array.from({ length: 20 }, (_, i) => h('option', { value: i + 1 }, 'Tier ' + (i + 1))));
                body.appendChild(h('div.pf-card.pf-stack',
                    h('div.pf-small.pf-muted', 'Stand at the front door of the new house. The entrance is set where you stand.'),
                    h('div.pf-field', h('label', 'Street'), street), h('div.pf-field', h('label', 'Price'), price), h('div.pf-field', h('label', 'Interior tier'), tier),
                    h('div.pf-row', h('button.pf-btn.primary', { onclick: () => create(street.value, Number(price.value), Number(tier.value)) }, 'Create listing here'))));
            }

            function renderSales(d) {
                if (!d.sales.length) { body.appendChild(h('div.pf-empty', 'No sales recorded yet.')); return; }
                const table = h('table.pf-table', h('thead', h('tr', h('th', 'Date'), h('th', 'House'), h('th', 'Buyer'), h('th', 'Agent'), h('th', 'Total'), h('th', 'My commission'))));
                const tbody = h('tbody');
                d.sales.forEach((s) => tbody.appendChild(h('tr', h('td', day(s.at)), h('td', s.address || s.house), h('td', s.buyer || ''), h('td', s.agent || ''),
                    h('td', money(s.total)), h('td', s.mine ? money(s.commission) : ''))));
                table.appendChild(tbody);
                body.appendChild(table);
            }

            async function load() {
                const res = await ctx.rpc('agency');
                if (!res || !res.ok) { ctx.notify(ERRORS[res && res.error] || 'The agency is not available right now', 'error'); return; }
                state.data = res;
                render();
            }

            async function call(method, payload) {
                if (state.busy) return null;
                state.busy = true;
                const res = await ctx.rpc(method, payload);
                state.busy = false;
                if (!res || !res.ok) ctx.notify(ERRORS[res && res.error] || 'That did not work', 'error');
                return res && res.ok ? res : null;
            }

            async function findNearby() {
                const res = await call('nearby');
                state.nearby = res ? res.players : [];
            }

            async function sendOffer(house, p) {
                const res = await call('offer', { house, target: p.id });
                if (res) { ctx.notify(`Offer sent to ${p.name}`, 'success'); load(); }
            }

            async function cancelOffer() { if (await call('cancelOffer')) load(); }

            async function reprice(l, price) {
                if (!(price > 0)) { ctx.notify(ERRORS.bad_price, 'error'); return; }
                if (await call('setPrice', { house: l.id, price })) { ctx.notify(`${l.address}: ${money(price)}`, 'success'); load(); }
            }

            async function create(street, price, tier) {
                const res = await call('createListing', { street, price, tier });
                if (res) { ctx.notify('Listing created', 'success'); state.tab = 'listings'; load(); }
            }

            ctx.on('changed', () => load());
            render();
            load();
        },
    });
})();
