// Car Dealer (pf-devices apps, tablet and computer), one file for two apps:
//   cardealer         the catalogue of every shop, the citizen's finance payments, a dealer's offer
//   cardealer-sales   dealership staff: sales to the customer next to them, test drives, stock,
//                     finance plans and the sales record
// Prices, stock, finance terms and every payment are decided by pfm-vehicleshop on the server.
(function () {
    const ERRORS = {
        bad_plate: 'That vehicle was not found', not_owned: 'That vehicle is not yours', alreadypaid: 'This vehicle is already paid off',
        minimumallowed: 'That is below the minimum payment', overpaid: 'That pays more than the balance. Use Pay off.', bad_amount: 'Enter a whole amount',
        notenoughmoney: 'Not enough money (cash or bank)', in_progress: 'A payment for this vehicle is already being processed', changed: 'The finance changed meanwhile. Nothing was charged.',
        not_found: 'That offer is no longer open', expired: 'That offer has expired', seller_left: 'The seller is no longer here', too_far: 'You are too far from the seller',
        insufficient_funds: 'Not enough money', out_of_stock: 'This model is out of stock', seller_unavailable: 'The seller can no longer sell this car',
        not_staff: 'Only dealership staff can do that', Invalid_ID: 'Choose a customer standing next to you', playertoofar: 'The customer is too far away',
        not_at_dealership: 'Be at your dealership to sell', bad_model: 'Choose a car this dealership sells', notworth: 'The down payment is more than the price',
        downtoosmall: 'The down payment is below the minimum', exceededmax: 'Too many payments', buyer_busy: 'That customer is answering another offer',
        not_allowed: 'Your grade cannot order stock', bad_qty: 'Enter how many cars to order', stock_untracked: 'Stock is not tracked here',
        bad_shop: 'Choose your dealership', bad_request: 'Something was missing', rate_limited: 'Slow down a little',
        fleet_vehicle: 'That vehicle belongs to a job fleet', financed: 'That vehicle is financed', server_error: 'Something went wrong on the server',
        vehicle_changed: 'The vehicle changed meanwhile. Any payment was returned.',
        payment_held: 'Your bank has not confirmed this payment yet. You will not be charged again: it completes, or is cancelled with nothing taken, on its own.',
        payment_waiting: 'A vehicle payment of yours is still waiting on the bank. Try again once it clears.',
    };

    function plural(n, word) { return `${n} ${word}${n === 1 ? '' : 's'}`; }
    function duration(min) {
        if (min < 1) return 'now';
        if (min < 60) return plural(Math.round(min), 'minute');
        return plural(Math.round(min / 60), 'hour') + ' of play';
    }
    function day(ts) { return ts ? new Date(ts * 1000).toLocaleDateString([], { day: 'numeric', month: 'short' }) : ''; }
    function stat(h, label, value) { return h('div.pf-card.pf-stat', h('div.pf-stat-value', value), h('div.pf-stat-label', label)); }
    function header(h, icon, title, sub, onRefresh, extra) {
        return h('div.pf-app-header',
            h('div.pf-app-title', h('span.pf-icon', icon), h('div', title, h('div.pf-app-sub', sub))),
            h('div.pf-row', extra || null, h('button.pf-btn.sm', { onclick: onRefresh }, 'Refresh')));
    }

    // ── citizens ──────────────────────────────────────────────────────────────────────────────
    PFApps.register('cardealer', {
        mount(container, ctx) {
            const { h, money } = ctx;
            const state = { cat: null, fin: null, tab: 'catalog', shop: ctx.storage.get('shop', null), q: '', busy: false };
            const banner = h('div.pfd-top');
            const tabs = h('div.pf-tabs');
            const body = h('div.pf-app-body.pf-stack');
            container.appendChild(h('div.pf-app.pfd', header(h, '🚘', 'Car Dealer', 'Catalogue, finance and payments', load), tabs, banner, body));

            function offer() { return (state.fin && state.fin.offer) || (state.cat && state.cat.offer) || null; }

            function renderBanner() {
                banner.innerHTML = '';
                const o = offer();
                if (!o) return;
                const terms = o.kind === 'finance'
                    ? `${money(o.amount)} down, then ${o.payments} payments of ${money(o.perPayment)}`
                    : (o.kind === 'transfer' ? `${money(o.amount)} to ${o.seller}${o.loan ? `, and its finance comes with it (${money(o.loan)} still to pay)` : ''}` : money(o.price));
                banner.appendChild(h('div.pf-card.pfd-offer',
                    h('div.pf-stack', { style: { gap: '4px', flex: '1' } },
                        h('div.pf-strong', `${o.seller} offers you ${o.label}${o.shop ? ' at ' + o.shop : ''}`),
                        h('div.pf-small.pf-muted', terms + (o.tax ? ` + ${money(o.tax)} purchase tax` : '')),
                        h('div.pfd-total', 'Pay now ' + money(o.total))),
                    h('div.pf-row',
                        h('button.pf-btn.primary', { onclick: () => answer(o, true) }, 'Accept and pay'),
                        h('button.pf-btn.danger', { onclick: () => answer(o, false) }, 'Decline'))));
            }

            function render() {
                renderBanner();
                tabs.innerHTML = '';
                const n = state.fin ? state.fin.vehicles.length : 0;
                [['catalog', 'Catalogue'], ['finance', `My finance (${n})`]].forEach(([id, label]) => {
                    tabs.appendChild(h('div.pf-tab' + (state.tab === id ? '.active' : ''), { onclick: () => { state.tab = id; render(); } }, label));
                });
                body.innerHTML = '';
                if (state.tab === 'catalog') renderCatalog(); else renderFinance();
            }

            function renderCatalog() {
                const c = state.cat;
                if (!c) { body.appendChild(h('div.pf-empty', 'Loading…')); return; }
                if (!c.shops.length) { body.appendChild(h('div.pf-empty', 'No shop is open.')); return; }
                let shop = c.shops.find((s) => s.id === state.shop) || c.shops[0];
                const select = h('select.pf-select', c.shops.map((s) => h('option', { value: s.id }, s.label)));
                select.value = shop.id;
                select.addEventListener('change', () => { state.shop = select.value; ctx.storage.set('shop', state.shop); render(); });
                const search = h('input.pf-input', { type: 'search', placeholder: 'Model or brand', value: state.q, maxlength: 40 });
                search.addEventListener('change', () => { state.q = search.value.trim().toLowerCase(); render(); });
                body.appendChild(h('div.pf-toolbar.pfd-filters', select, search));
                const how = shop.managed ? 'A salesperson sells these cars at the dealership (finance available).' : 'Buy or finance these yourself at the showroom.';
                body.appendChild(h('div.pf-card.pfd-shop',
                    h('div.pf-stack', { style: { gap: '4px', flex: '1' } },
                        h('div.pf-strong', shop.label),
                        h('div.pf-small.pf-muted', how),
                        h('div.pf-small.pf-muted', [
                            shop.testDriveMinutes ? `Test drives of ${shop.testDriveMinutes} min at the shop` : null,
                            `Finance: at least ${c.finance.minDownPercent}% down, up to ${c.finance.maxPayments} payments every ${c.finance.intervalHours} h of play`,
                            shop.managed && c.purchaseTaxPercent ? `${c.purchaseTaxPercent}% purchase tax` : null,
                            c.registrationFee ? `registration ${money(c.registrationFee)} billed by the DMV` : null,
                        ].filter(Boolean).join(' · '))),
                    shop.location ? h('button.pf-btn.sm', { onclick: () => waypoint(shop.location, shop.label) }, 'Waypoint') : null));
                const models = shop.models.filter((m) => !state.q || `${m.brand} ${m.name} ${m.model}`.toLowerCase().includes(state.q));
                if (!models.length) { body.appendChild(h('div.pf-empty', 'No car matches.')); return; }
                const grid = h('div.pfd-grid');
                models.forEach((m) => {
                    const badge = m.stock == null ? h('span.pf-badge.ok', 'Available') : (m.stock > 0 ? h('span.pf-badge.ok', `${m.stock} in stock`) : h('span.pf-badge.bad', 'Out of stock'));
                    grid.appendChild(h('div.pf-card.pfd-card',
                        h('div.pf-row.between', h('span.pf-strong', (m.brand ? m.brand + ' ' : '') + m.name), badge),
                        h('div.pf-small.pf-muted', m.category),
                        h('div.pfd-price', money(m.price)),
                        h('div.pf-small.pf-muted', `Finance from ${money(m.minDown)} down, ${m.payments} × ${money(m.perPayment)}`)));
                });
                body.appendChild(grid);
            }

            function renderFinance() {
                const f = state.fin;
                if (!f) { body.appendChild(h('div.pf-empty', 'Loading…')); return; }
                body.appendChild(h('div.pfd-stats', stat(h, 'Financed vehicles', String(f.vehicles.length)), stat(h, 'Next payments', money(f.nextDue)),
                    stat(h, 'Cash', money(f.cash)), stat(h, 'Bank', money(f.bank))));
                if (!f.vehicles.length) { body.appendChild(h('div.pf-empty', 'You have no vehicle on finance.')); return; }
                f.vehicles.forEach((v) => {
                    const amount = h('input.pf-input.pfd-amount', { type: 'number', min: v.payment, max: v.balance, step: 1, placeholder: 'Amount' });
                    body.appendChild(h('div.pf-card.pfd-fin' + (v.overdue ? '.pfd-overdue' : ''),
                        h('div.pf-row.between',
                            h('div.pf-stack', { style: { gap: '3px' } }, h('div.pf-row', h('span.pf-strong', v.label), h('span.pfd-plate', v.plate)),
                                h('div.pf-small.pf-muted', `${money(v.balance)} left · ${plural(v.paymentsLeft, 'payment')} of ${money(v.payment)}`)),
                            v.overdue ? h('span.pf-badge.bad', `Due now: pay within ${f.warningMinutes} min or it is repossessed`) : h('span.pf-badge.warn', 'Next payment in ' + duration(v.dueInMinutes))),
                        h('div.pfd-actions',
                            h('button.pf-btn.sm.primary', { onclick: () => pay(v) }, (v.lastPayment ? 'Pay last ' : 'Pay ') + money(v.payment)),
                            v.lastPayment ? null : amount,
                            v.lastPayment ? null : h('button.pf-btn.sm', { onclick: () => pay(v, Number(amount.value)) }, 'Pay amount'),
                            h('button.pf-btn.sm', { onclick: () => payoff(v) }, 'Pay off ' + money(v.balance)))));
                });
            }

            async function waypoint(c, label) { await ctx.setWaypoint(c.x, c.y); ctx.notify('Waypoint set: ' + label, 'success'); }

            async function load() {
                const [cat, fin] = await Promise.all([ctx.rpc('catalog'), ctx.rpc('finance')]);
                if (!cat || !cat.ok) ctx.notify('The catalogue is not available right now', 'error'); else state.cat = cat;
                if (fin && fin.ok) state.fin = fin;
                render();
            }

            async function call(method, payload, done) {
                if (state.busy) return;
                state.busy = true;
                const res = await ctx.rpc(method, payload);
                state.busy = false;
                // a payment the bank has not confirmed is not a failure: it settles on its own
                if (!res || !res.ok) ctx.notify(ERRORS[res && res.error] || 'That did not work', res && res.error === 'payment_held' ? 'primary' : 'error');
                else if (done) done(res);
                load();
            }

            function pay(v, amount) {
                if (amount !== undefined && !(amount > 0 && Number.isInteger(amount))) { ctx.notify(ERRORS.bad_amount, 'error'); return; }
                call('pay', amount === undefined ? { plate: v.plate } : { plate: v.plate, amount }, (res) => ctx.notify('Paid ' + money(res.paid), 'success'));
            }
            function payoff(v) { call('payoff', { plate: v.plate }, (res) => ctx.notify(`${v.label} is paid off (${money(res.paid)})`, 'success')); }
            function answer(o, accept) {
                call('answerOffer', { id: o.id, accept }, (res) => ctx.notify(res.declined ? 'Offer declined' : `You bought ${o.label}${res.plate ? ' (' + res.plate + ')' : ''}`, 'success'));
            }

            ctx.on('offer', () => load());
            ctx.on('offerClosed', () => load());
            ctx.on('changed', () => load());
            render();
            load();
        },
    });

    // ── dealership staff ──────────────────────────────────────────────────────────────────────
    PFApps.register('cardealer-sales', {
        mount(container, ctx) {
            const { h, money } = ctx;
            const state = { data: null, tab: 'sell', shop: null, model: null, mode: 'full', down: '', payments: '', nearby: [], busy: false };
            const balance = h('span.pf-badge.accent');
            const stats = h('div.pfd-stats');
            const tabs = h('div.pf-tabs');
            const body = h('div.pf-stack');
            container.appendChild(h('div.pf-app.pfd', header(h, '🏎️', 'Dealership', 'Sales, finance, stock and commissions', load, balance), tabs, h('div.pf-app-body.pf-stack', stats, body)));

            function shopOf(d) { return d.shops.find((s) => s.id === state.shop) || d.shops[0]; }

            function render() {
                const d = state.data;
                balance.textContent = d && d.balance != null ? 'Account ' + money(d.balance) : '';
                balance.style.display = d && d.balance != null ? '' : 'none';
                stats.innerHTML = '';
                if (d) {
                    stats.appendChild(stat(h, 'Sales, 7 days', String(d.stats.count)));
                    stats.appendChild(stat(h, 'Sales value, 7 days', money(d.stats.revenue)));
                    stats.appendChild(stat(h, 'My commission, 7 days', money(d.stats.mine)));
                    stats.appendChild(stat(h, 'Open offers', String(d.offers.length)));
                }
                tabs.innerHTML = '';
                [['sell', 'Sell'], ['stock', 'Stock'], ['plans', 'Finance plans'], ['sales', 'Sales']].forEach(([id, label]) => {
                    tabs.appendChild(h('div.pf-tab' + (state.tab === id ? '.active' : ''), { onclick: () => { state.tab = id; render(); } }, label));
                });
                body.innerHTML = '';
                if (!d) { body.appendChild(h('div.pf-empty', 'Loading…')); return; }
                if (!d.shops.length) { body.appendChild(h('div.pf-empty', 'Your job has no dealership.')); return; }
                ({ sell: renderSell, stock: renderStock, plans: renderPlans, sales: renderSales })[state.tab](d);
            }

            function shopSelect(d) {
                if (d.shops.length < 2) return null;
                const sel = h('select.pf-select', d.shops.map((s) => h('option', { value: s.id }, s.label)));
                sel.value = shopOf(d).id;
                sel.addEventListener('change', () => { state.shop = sel.value; state.model = null; render(); });
                return sel;
            }

            function renderSell(d) {
                if (d.offers.length) {
                    const list = h('div.pf-list');
                    d.offers.forEach((o) => list.appendChild(h('div.pf-list-item', h('span', `${o.buyer}: ${o.label}, ${money(o.total)} now${o.kind === 'finance' ? ` (financed, ${o.payments} × ${money(o.perPayment)})` : ''}`),
                        h('span.pf-badge.warn', 'Waiting'))));
                    body.appendChild(h('div.pf-card.pf-stack', h('div.pf-row.between', h('span.pf-strong', 'Offers waiting for an answer'),
                        h('button.pf-btn.sm.danger', { onclick: cancelOffers }, 'Withdraw all')), list));
                }
                const shop = shopOf(d);
                const models = shop.models;
                if (!models.length) { body.appendChild(h('div.pf-empty', 'This dealership sells no cars.')); return; }
                const model = h('select.pf-select', models.map((m) => h('option', { value: m.model }, `${m.name} · ${money(m.price)}${m.stock != null ? ` · ${m.stock} in stock` : ''}`)));
                if (state.model && models.some((m) => m.model === state.model)) model.value = state.model;
                state.model = model.value;
                model.addEventListener('change', () => { state.model = model.value; preview(); });
                const mode = h('select.pf-select', h('option', { value: 'full' }, 'Full price'), h('option', { value: 'finance' }, 'Finance'));
                mode.value = state.mode;
                const down = h('input.pf-input', { type: 'number', min: 0, step: 1, placeholder: 'Down payment', value: state.down });
                const payments = h('input.pf-input', { type: 'number', min: 1, max: d.finance.maxPayments, step: 1, placeholder: `Payments (max ${d.finance.maxPayments})`, value: state.payments });
                const financeRow = h('div.pfd-row2', h('div.pf-field', h('label', 'Down payment'), down), h('div.pf-field', h('label', 'Payments'), payments));
                const info = h('div.pf-small.pf-muted');
                function preview() {
                    state.mode = mode.value; state.down = down.value; state.payments = payments.value;
                    financeRow.style.display = mode.value === 'finance' ? '' : 'none';
                    const m = models.find((x) => x.model === model.value);
                    if (!m) return;
                    const rate = mode.value === 'finance' ? d.commission.finance : d.commission.sale;
                    // the commission comes out of the price; the dealership's account gets the rest
                    const commission = Math.max(0, Math.min(m.price, Math.round(m.price * rate)));
                    let text = `Your commission: ${money(commission)}, out of the price (the dealership gets ${money(m.price - commission)}). `;
                    if (mode.value === 'finance') {
                        const dp = Number(down.value), n = Number(payments.value);
                        const minDown = Math.round(m.price * d.finance.minDownPercent / 100);
                        text += dp >= minDown && n >= 1 ? `${money(dp)} down, ${n} × ${money(Math.round((m.price - dp) / n))}.` : `At least ${money(minDown)} down.`;
                    }
                    if (m.stock != null && m.stock < 1) text += ' Out of stock.';
                    info.textContent = text;
                }
                [mode, down, payments].forEach((el) => el.addEventListener('input', preview));
                mode.addEventListener('change', preview);
                preview();
                const customers = h('div.pf-list');
                function renderCustomers() {
                    customers.innerHTML = '';
                    if (!state.nearby.length) { customers.appendChild(h('div.pf-small.pf-muted', `Nobody is within ${d.saleDistance} m. The customer stands next to you.`)); return; }
                    state.nearby.forEach((p) => customers.appendChild(h('div.pf-list-item', h('span', p.name, h('span.pf-small.pf-muted', ' #' + p.id)),
                        h('div.pf-row',
                            h('button.pf-btn.sm', { onclick: () => testDrive(p) }, 'Test drive'),
                            h('button.pf-btn.sm.primary', { onclick: () => sell(p) }, 'Send offer')))));
                }
                renderCustomers();
                body.appendChild(h('div.pf-card.pf-stack',
                    shopSelect(d), h('div.pf-field', h('label', 'Car'), model), h('div.pf-field', h('label', 'Payment'), mode), financeRow, info,
                    h('div.pf-row.between', h('span.pf-strong', 'Customers next to you'), h('button.pf-btn.sm', { onclick: async () => { await findNearby(); renderCustomers(); } }, 'Look around')),
                    customers));
            }

            function renderStock(d) {
                const shop = shopOf(d);
                const sel = shopSelect(d);
                if (sel) body.appendChild(h('div.pf-toolbar', sel));
                if (!d.stock.tracked) body.appendChild(h('div.pf-card.pf-small.pf-muted', 'Stock is not tracked for this dealership.'));
                const table = h('table.pf-table', h('thead', h('tr', h('th', 'Car'), h('th', 'Price'), h('th', 'Wholesale'), h('th', 'In stock'), h('th', ''))));
                const tbody = h('tbody');
                shop.models.forEach((m) => {
                    const qty = h('input.pf-input.pfd-qty', { type: 'number', min: 1, max: d.stock.maxOrder, step: 1, value: 1 });
                    tbody.appendChild(h('tr', h('td', m.name), h('td', money(m.price)), h('td', money(m.wholesale)), h('td', m.stock == null ? '—' : String(m.stock)),
                        h('td.pfd-actions', d.canOrder && d.stock.tracked ? [qty, h('button.pf-btn.sm', { onclick: () => order(shop, m, Number(qty.value)) }, 'Order')] : null)));
                });
                table.appendChild(tbody);
                body.appendChild(table);
                if (!d.canOrder) body.appendChild(h('div.pf-small.pf-muted', 'Ordering stock is up to the management.'));
            }

            function renderPlans(d) {
                if (!d.plans.length) { body.appendChild(h('div.pf-empty', 'No customer is paying off a car from this dealership.')); return; }
                const table = h('table.pf-table', h('thead', h('tr', h('th', 'Customer'), h('th', 'Car'), h('th', 'Plate'), h('th', 'Balance'), h('th', 'Payment'), h('th', 'Left'))));
                const tbody = h('tbody');
                d.plans.forEach((p) => tbody.appendChild(h('tr', h('td', p.buyer || ''), h('td', p.label), h('td', p.plate), h('td', money(p.balance)), h('td', money(p.payment)), h('td', String(p.paymentsLeft)))));
                table.appendChild(tbody);
                body.appendChild(table);
            }

            function renderSales(d) {
                if (!d.sales.length) { body.appendChild(h('div.pf-empty', 'No sales recorded yet.')); return; }
                const table = h('table.pf-table', h('thead', h('tr', h('th', 'Date'), h('th', 'Car'), h('th', 'Buyer'), h('th', 'Seller'), h('th', 'Price'), h('th', 'My commission'))));
                const tbody = h('tbody');
                d.sales.forEach((s) => tbody.appendChild(h('tr', h('td', day(s.at)), h('td', `${s.label} (${s.plate})${s.financed ? ' · financed' : ''}`), h('td', s.buyer || ''), h('td', s.seller || ''),
                    h('td', money(s.price)), h('td', s.commission != null ? money(s.commission) : ''))));
                table.appendChild(tbody);
                body.appendChild(table);
            }

            async function load() {
                const res = await ctx.rpc('init');
                if (!res || !res.ok) { ctx.notify(ERRORS[res && res.error] || 'The dealership is not available right now', 'error'); return; }
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

            async function findNearby() { const res = await call('nearby'); state.nearby = res ? res.players : []; }

            async function sell(p) {
                const payload = { model: state.model, target: p.id };
                if (state.mode === 'finance') payload.finance = { down: Number(state.down), payments: Number(state.payments) };
                const res = await call('offer', payload);
                if (res) { ctx.notify(`Offer sent to ${p.name}: ${money(res.offer.total)} now`, 'success'); load(); }
            }
            async function testDrive(p) { if (await call('testDrive', { model: state.model, target: p.id })) ctx.notify(`${p.name} is on a test drive`, 'success'); }
            async function cancelOffers() { if (await call('cancelOffers')) load(); }
            async function order(shop, m, qty) {
                if (!(qty >= 1 && Number.isInteger(qty))) { ctx.notify(ERRORS.bad_qty, 'error'); return; }
                const res = await call('orderStock', { shop: shop.id, model: m.model, qty });
                if (res) { ctx.notify(`Ordered ${qty} × ${m.name} for ${money(res.cost)}`, 'success'); load(); }
            }

            ctx.on('changed', () => load());
            render();
            load();
        },
    });
})();
