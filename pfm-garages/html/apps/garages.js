// Garages (pf-devices app, tablet and computer): every vehicle the citizen owns, where it is and in
// what condition, the impound release fee paid ahead, and a tow of a car that is out to a garage.
// All data and every action come from pfm-garages on the server; this module only renders.
(function () {
    const ERRORS = {
        bad_plate: 'That vehicle was not found', not_owned: 'That vehicle is not yours', fleet: 'This vehicle is in a job fleet. Take it from the job garage.',
        seized: 'This vehicle was seized. Only the police can release it.', nothing_due: 'There is no fee to pay for this vehicle',
        in_progress: 'A payment for this vehicle is already being processed', insufficient_funds: 'Not enough money (cash or bank)',
        bank_unavailable: 'The bank is not responding. Nothing was charged.', ledger_unavailable: 'The bank is not responding. Nothing was charged.',
        not_found: 'The vehicle is not in the city right now', not_out: 'Only a vehicle that is out can be towed',
        occupied: 'Someone is driving that vehicle', already_there: 'The vehicle is already at that garage', tow_exists: 'A tow is already on its way for this vehicle', already_accepted: 'A tow driver has already taken this job', superseded: 'Police have ordered this vehicle impounded',
        bad_garage: 'Choose one of your garages', cooldown: 'Wait a moment before asking for another tow', tow_unavailable: 'No tow service is available',
        too_many_open: 'You already have open service requests', bad_request: 'Something was missing from that request', rate_limited: 'Slow down a little',
    };
    const STATUS = {
        garaged: ['In garage', 'ok'], out: ['Out', 'accent'], impounded: ['Impounded', 'warn'], seized: ['Seized', 'bad'], fleet: ['Job fleet', ''],
    };
    const TABS = [['all', 'All'], ['garaged', 'In garage'], ['out', 'Out'], ['impounded', 'Impounded']];

    PFApps.register('garages', {
        mount(container, ctx) {
            const { h, money } = ctx;
            const state = { data: null, tab: ctx.storage.get('tab', 'all'), q: '', busy: false };
            const stats = h('div.pfg-stats');
            const tabs = h('div.pf-tabs');
            const search = h('input.pf-input', { type: 'search', placeholder: 'Search by name or plate', maxlength: 40 });
            const list = h('div.pfg-list');
            const root = h('div.pf-app.pfg',
                h('div.pf-app-header',
                    h('div.pf-app-title', h('span.pf-icon', '🚗'), h('div', 'Garages', h('div.pf-app-sub', 'Your vehicles, wherever they are'))),
                    h('button.pf-btn.sm', { onclick: load }, 'Refresh')),
                tabs,
                h('div.pf-app-body.pf-stack', stats, h('div.pf-toolbar', search), list));
            container.appendChild(root);
            search.addEventListener('input', () => { state.q = search.value.trim().toLowerCase(); renderList(); });

            function stat(label, value, cls) {
                return h('div.pf-card.pf-stat', h('div.pf-stat-value' + (cls ? '.' + cls : ''), value), h('div.pf-stat-label', label));
            }

            function bar(label, value) {
                if (value == null) return null;
                const cls = value < 25 ? 'bad' : value < 60 ? 'warn' : 'ok';
                return h('div.pfg-bar',
                    h('div.pfg-bar-label', h('span', label), h('span', value + '%')),
                    h('div.pfg-bar-track', h('div.pfg-bar-fill.' + cls, { style: { width: value + '%' } })));
            }

            function render() {
                const d = state.data;
                const all = d ? d.vehicles : [];
                const count = (s) => all.filter((v) => v.status === s).length;
                stats.innerHTML = '';
                stats.appendChild(stat('Vehicles', String(all.length)));
                stats.appendChild(stat('In garage', String(count('garaged'))));
                stats.appendChild(stat('Out', String(count('out'))));
                stats.appendChild(stat('Impound fees due', money(d ? d.feesDue : 0), d && d.feesDue > 0 ? 'pfg-warn' : null));
                tabs.innerHTML = '';
                TABS.forEach(([id, label]) => {
                    const n = id === 'all' ? all.length : count(id);
                    tabs.appendChild(h('div.pf-tab' + (state.tab === id ? '.active' : ''), { onclick: () => { state.tab = id; ctx.storage.set('tab', id); render(); } }, `${label} (${n})`));
                });
                renderList();
            }

            function renderList() {
                list.innerHTML = '';
                const d = state.data;
                if (!d) { list.appendChild(h('div.pf-empty', 'Loading…')); return; }
                const rows = d.vehicles.filter((v) => (state.tab === 'all' || v.status === state.tab)
                    && (!state.q || String(v.label).toLowerCase().includes(state.q) || String(v.plate).toLowerCase().includes(state.q)));
                if (!rows.length) { list.appendChild(h('div.pf-empty', d.vehicles.length ? 'No vehicle matches.' : 'You do not own a vehicle yet.')); return; }
                rows.forEach((v) => list.appendChild(card(v)));
            }

            function where(v) {
                if (v.status === 'garaged') return 'Parked at ' + (v.location ? v.location.label : 'a garage');
                if (v.status === 'impounded') return (v.feePaid ? 'Release paid, collect it at ' : 'At the impound: ') + (v.location ? v.location.label : 'the depot');
                if (v.status === 'seized') return 'Seized by the authorities. Contact the police to get it back.';
                if (v.status === 'fleet') return 'In a job fleet. Take it from your job garage.';
                if (v.tow) return 'Tow ' + (v.tow.status === 'accepted' ? `on its way${v.tow.assignee ? ' (' + v.tow.assignee + ')' : ''}` : 'requested') + (v.tow.garage ? ' to ' + v.tow.garage : '');
                return v.inWorld ? 'Out in the city' : 'Out, but not in the city right now';
            }

            function card(v) {
                const st = STATUS[v.status] || [v.status, ''];
                const actions = h('div.pfg-actions');
                const coords = v.location && v.location.coords;
                if (coords && (v.status === 'garaged' || v.status === 'impounded')) {
                    actions.appendChild(h('button.pf-btn.sm', { onclick: () => waypoint(coords, v.location.label) }, v.status === 'impounded' ? 'Waypoint to depot' : 'Waypoint'));
                }
                if (v.status === 'impounded' && v.canPay) {
                    actions.appendChild(h('button.pf-btn.sm.primary', { onclick: () => payDepot(v) }, 'Pay release ' + money(v.fee)));
                }
                if (v.status === 'out' && v.inWorld) actions.appendChild(h('button.pf-btn.sm', { onclick: () => locate(v) }, 'Locate'));
                if (v.status === 'out' && v.tow && v.tow.mine) actions.appendChild(h('button.pf-btn.sm.danger', { onclick: () => cancelTow(v) }, 'Cancel tow'));
                if (v.status === 'out' && v.canTow && state.data.garages.length) {
                    const select = h('select.pf-select.pfg-select', state.data.garages.map((g) => h('option', { value: g.id }, g.label)));
                    actions.appendChild(select);
                    const fee = state.data.towFee ? ' (' + money(state.data.towFee) + ')' : '';
                    actions.appendChild(h('button.pf-btn.sm', { onclick: () => requestTow(v, select.value) }, 'Request tow' + fee));
                }
                return h('div.pf-card.pfg-card.pfg-' + v.status,
                    h('div.pf-row.between',
                        h('div.pf-stack.pfg-head',
                            h('div.pf-row', h('span.pf-strong', v.label), h('span.pfg-plate', v.plate)),
                            h('div.pf-small.pf-muted', where(v))),
                        h('span.pf-badge' + (st[1] ? '.' + st[1] : ''), v.status === 'impounded' && v.feePaid ? 'Release paid' : st[0])),
                    h('div.pfg-bars', bar('Fuel', v.fuel), bar('Engine', v.engine), bar('Body', v.body)),
                    v.finance ? h('div.pf-small.pf-muted', 'Finance balance: ' + money(v.finance)) : null,
                    actions.childNodes.length ? actions : null);
            }

            function fail(res, fallback) { ctx.notify(ERRORS[res && res.error] || fallback, 'error'); }

            async function waypoint(coords, label) {
                await ctx.setWaypoint(coords.x, coords.y);
                ctx.notify('Waypoint set' + (label ? ': ' + label : ''), 'success');
            }

            async function load() {
                const res = await ctx.rpc('list');
                if (!res || !res.ok) { fail(res, 'Your vehicles could not be loaded'); return; }
                state.data = res;
                render();
            }

            async function act(method, payload, done) {
                if (state.busy) return null;
                state.busy = true;
                const res = await ctx.rpc(method, payload);
                state.busy = false;
                if (!res || !res.ok) fail(res, 'That did not work');
                else if (done) done(res);
                return res;
            }

            function payDepot(v) {
                act('payDepot', { plate: v.plate }, (res) => {
                    ctx.notify(res.already ? 'The release was already paid' : `Paid ${money(res.paid)}. Collect the vehicle at ${res.depot ? res.depot.label : 'the depot'}.`, 'success');
                    load();
                });
            }

            function locate(v) {
                act('locate', { plate: v.plate }, (res) => { if (res.coords) waypoint(res.coords, v.plate); });
            }

            function requestTow(v, garage) {
                act('requestTow', { plate: v.plate, garage }, (res) => { ctx.notify(`Tow requested to ${res.garage}`, 'success'); load(); });
            }

            function cancelTow(v) {
                act('cancelTow', { plate: v.plate }, () => { ctx.notify('Tow cancelled', 'success'); load(); });
            }

            ctx.on('changed', load);
            render();
            load();
        },
    });
})();
