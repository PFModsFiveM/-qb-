/*
 * Crafting app (pf-devices platform module, tablet + computer): every bench's recipes with what they
 * need, what the player carries, the crafting XP they need and how many the player could make now,
 * and where the player's own bench stands. Read-only: the data comes from server_devices.lua and
 * crafting stays at the bench.
 */
(function () {
    'use strict';
    if (!window.PFApps) return;

    const ERRORS = {
        not_installed: 'Install the Crafting app from the App Store first',
        rate_limited: 'Slow down a little',
        server_error: 'Something went wrong',
        request_failed: 'Could not reach the server',
        no_player: 'Your character is not loaded',
    };

    function create(container, ctx) {
        const { h } = ctx;
        const st = { view: null, error: null, bench: ctx.storage.get('bench', null), onlyReady: ctx.storage.get('onlyReady', false), search: '' };
        let alive = true;
        const root = h('div.pf-app.pfm-craft');
        container.appendChild(root);
        const num = (v, d = 0) => (Number.isFinite(Number(v)) ? Number(v) : d);
        const text = (v) => (v == null ? '' : String(v));

        async function load() {
            const res = await ctx.rpc('getInit');
            if (!alive) return;
            if (!res || res.ok === false) st.error = ERRORS[res && res.error] || 'The workshop is not answering';
            else { st.error = null; st.view = res; }
            render();
        }

        function benchCard(b) {
            return h('div.pf-card.pfm-craft-bench',
                h('div.pf-row.between',
                    h('div', h('div.pf-strong', text(b.label)), h('div.pf-muted.pf-small', `${num(b.xp)} crafting XP (${text(b.xpType)})`)),
                    b.placed ? h('span.pf-badge.ok', 'Set up') : num(b.owned) > 0 ? h('span.pf-badge.accent', `${num(b.owned)} in your pockets`) : h('span.pf-badge', 'You have none')),
                b.placed
                    ? h('div.pf-row.pfm-craft-wrap', h('span.pf-muted.pf-small', 'Your bench is set up. Craft there; pick it up when you leave.'),
                        h('button.pf-btn.sm', { type: 'button', onclick: () => { ctx.setWaypoint(num(b.placed.x), num(b.placed.y)); ctx.notify('Waypoint set to your bench', 'success'); } }, 'Waypoint to your bench'))
                    : h('div.pf-muted.pf-small', num(b.owned) > 0 ? 'Use the bench item to set it down, then craft at it.' : 'You need this bench to craft its recipes.'));
        }

        function recipeCard(r) {
            const status = !r.unlocked ? h('span.pf-badge.bad', `Needs ${num(r.xpRequired)} XP`)
                : num(r.canMake) > 0 ? h('span.pf-badge.ok', `You can make ${num(r.canMake)}`) : h('span.pf-badge.warn', 'Missing materials');
            return h('div.pf-card.pfm-craft-recipe',
                h('div.pf-row.between', h('div.pf-strong', text(r.label)), status),
                h('div.pfm-craft-reqs', (r.requirements || []).map((q) => h('span.pf-badge' + (num(q.have) >= num(q.amount) ? '.ok' : ''),
                    `${text(q.label)} ${num(q.have)}/${num(q.amount)}`))),
                h('div.pf-muted.pf-small', `+${num(r.xpGain)} XP each`));
        }

        function render() {
            if (!alive) return;
            root.textContent = '';
            root.appendChild(h('div.pf-app-header',
                h('div.pf-app-title', h('span.pf-icon', '🛠️'), h('div', 'Crafting', h('div.pf-app-sub', 'Recipes, materials and your bench'))),
                h('button.pf-btn.sm.ghost', { type: 'button', onclick: load }, 'Refresh')));
            const v = st.view;
            const benches = (v && v.benches) || [];
            if (benches.length && !benches.some((b) => b.type === st.bench)) st.bench = benches[0].type;
            if (benches.length > 1) {
                root.appendChild(h('div.pf-tabs', benches.map((b) => h('div.pf-tab' + (b.type === st.bench ? '.active' : ''), {
                    onclick: () => { st.bench = b.type; ctx.storage.set('bench', b.type); render(); },
                }, text(b.label)))));
            }
            const body = h('div.pf-app-body.pf-stack');
            root.appendChild(body);
            if (st.error) { body.appendChild(h('div.pf-empty', st.error)); return; }
            if (!v) { body.appendChild(h('div.pf-empty', 'Loading…')); return; }
            const bench = benches.find((b) => b.type === st.bench);
            if (!bench) { body.appendChild(h('div.pf-empty', 'No crafting benches are set up on this server.')); return; }
            body.appendChild(benchCard(bench));
            const search = h('input.pf-input', { type: 'search', placeholder: 'Find a recipe', value: st.search });
            const only = h('input', { type: 'checkbox' });
            only.checked = !!st.onlyReady;
            const list = h('div.pf-grid.pfm-craft-list');
            const fill = () => {
                list.textContent = '';
                const q = st.search.trim().toLowerCase();
                const recipes = (bench.recipes || []).filter((r) => (!st.onlyReady || num(r.canMake) > 0) && (!q || text(r.label).toLowerCase().includes(q)));
                if (!recipes.length) list.appendChild(h('div.pf-empty', st.onlyReady ? 'Nothing you can make right now.' : 'No recipe matches.'));
                recipes.forEach((r) => list.appendChild(recipeCard(r)));
            };
            search.addEventListener('input', () => { st.search = search.value; fill(); });
            only.addEventListener('change', () => { st.onlyReady = only.checked; ctx.storage.set('onlyReady', st.onlyReady); fill(); });
            body.appendChild(h('div.pf-toolbar', h('div.pfm-craft-search', search), h('label.pf-row.pf-small', only, 'Only what I can make')));
            body.appendChild(list);
            body.appendChild(h('div.pf-muted.pf-small', `Up to ${num(v.maxAmount, 50)} at a time.`));
            fill();
        }

        render();
        return { start: load, destroy() { alive = false; } };
    }

    let instance = null;
    PFApps.register('crafting', {
        async mount(container, ctx) {
            if (instance) instance.destroy();
            instance = create(container, ctx);
            await instance.start();
        },
        unmount() { if (instance) instance.destroy(); instance = null; },
    });
})();
