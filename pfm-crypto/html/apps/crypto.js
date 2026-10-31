// Crypto (pfm-crypto) on pf-devices: the Qbit price and its history, the wallet, buy / sell for bank
// money and sending coins to another wallet. The server sets the price and does every trade; the module
// sends the coin amount and a per-action `ref` (a retried request never trades twice; a changed trade
// gets a new ref).
(function () {
    const ERRORS = {
        bad_amount: 'Enter an amount of coins (at most 4 decimals)', bad_request: 'That request was not valid',
        insufficient_funds: 'Not enough money in your bank account', insufficient_coins: 'You do not have that many coins',
        unknown_wallet: 'No wallet with that ID', own_wallet: 'That is your own wallet', busy: 'Your last trade is still running',
        slow_down: 'Wait a moment between two trades', already_processed: 'This trade was already processed',
        bank_unavailable: 'The bank is not responding; nothing was traded', server_error: 'The exchange had a problem. Try again.',
        request_failed: 'No answer from the exchange. Try again: it will not trade twice.', timeout: 'No answer from the exchange. Try again: it will not trade twice.',
        rate_limited: 'Too many requests, slow down', in_progress: 'Your last trade is still running',
    };
    // answers after which the trade may still run or was not run at all: the same trade keeps its ref
    const RETRYABLE = { request_failed: true, timeout: true, in_progress: true, busy: true, slow_down: true, rate_limited: true };
    const SVG = 'http://www.w3.org/2000/svg';

    function newRef() { return ('c' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 12)).slice(0, 40); }
    // The ref of one trade. It is reused only to resend the exact same trade (same fingerprint) after a
    // retryable answer; a changed trade always gets a fresh ref, so it can never be answered with the
    // earlier trade's result.
    function refKeeper() {
        let kept = null;
        return {
            take(print) { return kept && kept.print === print ? kept.ref : newRef(); },
            settle(ref, print, res) { kept = !(res && res.ok) && (!res || RETRYABLE[res.error]) ? { ref, print } : null; },
        };
    }
    function coinsText(n) { return (Number(n) || 0).toLocaleString('en-US', { maximumFractionDigits: 4 }); }
    function when(at) {
        if (!at) return '';
        const d = new Date(at * 1000);
        return d.toLocaleDateString([], { day: 'numeric', month: 'short' }) + ' ' + d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    }
    function svg(tag, attrs) {
        const el = document.createElementNS(SVG, tag);
        Object.entries(attrs || {}).forEach(([k, v]) => el.setAttribute(k, String(v)));
        return el;
    }

    PFApps.register('crypto', {
        mount(container, ctx) {
            const { h, money } = ctx;
            const state = { data: null, history: null, mode: 'buy', coins: '', wallet: '', busy: false, review: false };
            const refs = refKeeper();

            const priceEl = h('div.pfx-price', '—');
            const changeEl = h('span.pf-badge');
            const chart = h('div.pfx-chart');
            const walletBox = h('div.pf-card.pf-stack');
            const tradeBox = h('div.pf-card.pf-stack.pfx-trade');
            const historyBox = h('div.pf-stack');
            const root = h('div.pf-app.pfx',
                h('div.pf-app-header',
                    h('div.pf-app-title', h('span.pf-icon', '🪙'), h('div', 'Crypto', h('div.pf-app-sub', 'The Qbit exchange'))),
                    h('button.pf-btn.sm', { onclick: () => load() }, 'Refresh')),
                h('div.pf-app-body.pf-stack',
                    h('div.pf-card.pf-stack', h('div.pf-row.between', h('div', h('div.pf-stat-label', 'Qbit price'), priceEl), changeEl), chart),
                    h('div.pfx-grid', walletBox, tradeBox),
                    historyBox));
            container.appendChild(root);

            function errorText(res) { return (res && ERRORS[res.error]) || (res && res.message) || 'That did not work'; }

            async function load() {
                const res = await ctx.rpc('market');
                if (!res || !res.ok) { priceEl.textContent = 'Unavailable'; ctx.notify(errorText(res), 'error'); return; }
                state.data = res;
                render();
                const hist = await ctx.rpc('history');
                state.history = hist && hist.ok ? hist : null;
                renderHistory();
            }

            function render() {
                const d = state.data;
                if (!d) return;
                priceEl.textContent = money(d.price);
                changeEl.className = 'pf-badge';
                if (d.change) {
                    changeEl.classList.add(d.change.abs >= 0 ? 'ok' : 'bad');
                    changeEl.textContent = (d.change.abs >= 0 ? '▲ ' : '▼ ') + Math.abs(d.change.pct) + '% · 24 h';
                } else changeEl.textContent = 'No history yet';
                renderChart();
                renderWallet();
                renderTrade();
            }

            function renderChart() {
                const d = state.data;
                chart.innerHTML = '';
                const pts = (d.history || []).map((p) => Number(p.price)).filter((n) => Number.isFinite(n));
                if (pts.length < 2) { chart.appendChild(h('div.pf-small.pf-muted', 'The price history fills in as the market moves (every ' + d.refreshMinutes + ' min).')); return; }
                const W = 600, H = 150, pad = 6;
                const min = Math.min(...pts), max = Math.max(...pts);
                const span = Math.max(1, max - min);
                const coords = pts.map((v, i) => [pad + (i * (W - pad * 2)) / (pts.length - 1), H - pad - ((v - min) / span) * (H - pad * 2)]);
                const el = svg('svg', { viewBox: `0 0 ${W} ${H}`, preserveAspectRatio: 'none', class: 'pfx-svg', role: 'img', 'aria-label': 'Qbit price history' });
                const area = coords.map(([x, y]) => `${x.toFixed(1)},${y.toFixed(1)}`).join(' ');
                el.appendChild(svg('polygon', { points: `${pad},${H - pad} ${area} ${W - pad},${H - pad}`, class: 'pfx-area' }));
                el.appendChild(svg('polyline', { points: area, class: 'pfx-line' + (pts[pts.length - 1] >= pts[0] ? ' up' : ' down') }));
                chart.appendChild(el);
                chart.appendChild(h('div.pf-row.between.pf-small.pf-muted', h('span', 'Low ' + money(min)), h('span', pts.length + ' points · updates every ' + d.refreshMinutes + ' min'), h('span', 'High ' + money(max))));
            }

            function renderWallet() {
                const d = state.data;
                walletBox.innerHTML = '';
                walletBox.appendChild(h('div.pf-strong', 'Your wallet'));
                walletBox.appendChild(h('div.pfx-coins', coinsText(d.wallet.coins) + ' QBit'));
                walletBox.appendChild(h('div.pf-muted', 'Worth about ' + money(d.wallet.value)));
                walletBox.appendChild(h('div.pf-field', h('label', 'Wallet ID (to receive coins)'),
                    h('input.pf-input.pfx-mono', { value: d.wallet.walletId || 'No wallet yet', readonly: true, onclick: (e) => e.target.select() })));
                walletBox.appendChild(h('div.pf-small.pf-muted', 'Bank balance ' + money(d.bank)));
                walletBox.appendChild(h('div.pfx-note',
                    h('div', d.exchange.rebooting ? 'The cryptostick terminal is rebooting.' : 'Exchange a cryptostick at the terminal.'),
                    h('button.pf-btn.sm.ghost', { onclick: () => { ctx.setWaypoint(d.exchange.x, d.exchange.y); ctx.notify('Waypoint set to the exchange terminal', 'success'); } }, 'Set waypoint')));
            }

            function renderTrade() {
                const d = state.data;
                tradeBox.innerHTML = '';
                tradeBox.appendChild(h('div.pfx-seg', [['buy', 'Buy'], ['sell', 'Sell'], ['send', 'Send']].map(([id, label]) =>
                    h('button.pf-btn.sm' + (state.mode === id ? '.primary' : ''), { onclick: () => { state.mode = id; state.review = false; renderTrade(); } }, label))));
                const coinsIn = h('input.pf-input', { type: 'number', min: 0.0001, step: 0.0001, max: d.maxCoins, value: state.coins, placeholder: 'Coins',
                    oninput: (e) => { state.coins = e.target.value; state.review = false; updateQuote(); } });
                const maxBtn = h('button.pf-btn.sm.ghost', { onclick: () => {
                    const max = state.mode === 'buy' ? Math.floor((d.bank / Math.max(1, d.price)) * 10000) / 10000 : Math.floor(d.wallet.coins * 10000) / 10000;
                    state.coins = String(Math.min(max, d.maxCoins)); coinsIn.value = state.coins; state.review = false; updateQuote();
                } }, 'Max');
                tradeBox.appendChild(h('div.pf-field', h('label', 'Coins'), h('div.pf-row', coinsIn, maxBtn)));
                if (state.mode === 'send') {
                    tradeBox.appendChild(h('div.pf-field', h('label', 'To wallet ID'),
                        h('input.pf-input.pfx-mono', { value: state.wallet, maxlength: 64, placeholder: 'Wallet ID', oninput: (e) => { state.wallet = e.target.value; state.review = false; } })));
                }
                const quote = h('div.pf-small.pf-muted.pfx-quote');
                tradeBox.appendChild(quote);
                const action = h('div.pfx-actions');
                tradeBox.appendChild(action);
                function amount() { return Math.floor(Number(state.coins) * 10000) / 10000; }
                function updateQuote() {
                    const c = amount();
                    if (!(c > 0)) { quote.textContent = `Up to ${coinsText(d.maxCoins)} coins per trade.`; return; }
                    if (state.mode === 'buy') quote.textContent = `Costs about ${money(Math.ceil(c * d.price))} from your bank at ${money(d.price)} per coin.`;
                    else if (state.mode === 'sell') quote.textContent = `Pays about ${money(Math.floor(c * d.price))} into your bank at ${money(d.price)} per coin.`;
                    else quote.textContent = `Sends ${coinsText(c)} QBit. Transfers cannot be undone.`;
                }
                updateQuote();
                function drawAction() {
                    action.innerHTML = '';
                    if (!state.review) {
                        action.appendChild(h('button.pf-btn.primary', { disabled: state.busy, onclick: () => {
                            if (!(amount() > 0)) { ctx.notify(ERRORS.bad_amount, 'error'); return; }
                            if (state.mode === 'send' && !state.wallet.trim()) { ctx.notify('Enter the wallet ID', 'error'); return; }
                            state.review = true; drawAction();
                        } }, { buy: 'Review purchase', sell: 'Review sale', send: 'Review transfer' }[state.mode]));
                        return;
                    }
                    action.appendChild(h('button.pf-btn.ghost', { onclick: () => { state.review = false; drawAction(); } }, 'Change'));
                    action.appendChild(h('button.pf-btn.primary', { disabled: state.busy, onclick: submit }, state.busy ? 'Working…' : 'Confirm ' + state.mode));
                }
                drawAction();
            }

            async function submit() {
                if (state.busy) return;
                state.busy = true;
                renderTrade();
                const mode = state.mode;
                const coins = Math.floor(Number(state.coins) * 10000) / 10000;
                const payload = { coins };
                if (mode === 'send') payload.walletId = state.wallet.trim();
                // everything that makes it this trade: buy / sell / send, the coins and the wallet
                const print = JSON.stringify([mode, coins, payload.walletId || '']);
                const ref = refs.take(print);
                payload.ref = ref;
                const res = await ctx.rpc(mode, payload);
                refs.settle(ref, print, res);
                state.busy = false;
                state.review = false;
                if (res && res.ok) {
                    const done = { buy: `Bought ${coinsText(res.coins)} QBit for ${money(res.total)}`, sell: `Sold ${coinsText(res.coins)} QBit for ${money(res.total)}`, send: `Sent ${coinsText(res.coins)} QBit` }[mode];
                    // a resent trade: the server answered with the first one, nothing traded again
                    ctx.notify(res.duplicate ? 'Already done earlier: ' + done : done, 'success');
                    state.coins = '';
                    await load();
                    return;
                }
                ctx.notify(errorText(res), 'error');
                renderTrade();
            }

            function renderHistory() {
                historyBox.innerHTML = '';
                const hist = state.history;
                if (!hist) return;
                const items = hist.trades.map((t) => ({ at: t.at, text: (t.side === 'buy' ? 'Bought ' : 'Sold ') + (t.coins != null ? coinsText(t.coins) + ' QBit' : 'QBit'), value: (t.side === 'buy' ? '−' : '+') + money(t.total), cls: t.side === 'buy' ? 'pfx-out' : 'pfx-in' }))
                    .concat(hist.transfers.map((t) => ({ at: t.at, text: t.direction === 'out' ? 'Sent to a wallet' : 'Received from a wallet', value: (t.direction === 'out' ? '−' : '+') + coinsText(t.coins) + ' QBit', cls: t.direction === 'out' ? 'pfx-out' : 'pfx-in' })))
                    .sort((a, b) => (b.at || 0) - (a.at || 0)).slice(0, 30);
                historyBox.appendChild(h('div.pf-strong', 'Recent activity'));
                if (!items.length) { historyBox.appendChild(h('div.pf-small.pf-muted', 'No trades yet.')); return; }
                historyBox.appendChild(h('div.pf-list', items.map((it) => h('div.pf-list-item',
                    h('div', h('div', it.text), h('div.pf-small.pf-muted', when(it.at))), h('div.pf-strong.' + it.cls, it.value)))));
            }

            ctx.on('price', (p) => {
                if (!state.data || !p || p.coin !== state.data.coin) return;
                state.data.price = Number(p.price) || state.data.price;
                state.data.history = (state.data.history || []).concat([{ at: p.at, price: state.data.price }]).slice(-96);
                state.data.wallet.value = Math.floor(state.data.wallet.coins * state.data.price);
                priceEl.textContent = money(state.data.price);
                renderChart();
                renderWallet();
                if (!state.review && !state.busy) renderTrade();
            });
            load();
        },
    });
})();
