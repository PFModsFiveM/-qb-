// Copyright (c) 2026 Whippy, from WHIP, LGPL-3.0; modified for PF.
// ========================================
// SETTINGS — the pause menu's Settings page (server rows: pfm-ui's registry, through client/main.lua)
//
// PF: pfm-pause has no Combined Settings page (no copy of GTA's settings page under it), so the Game tabs never
// show: this is Server Settings. The Game code is kept as it was.
//
// The rail on the left has two groups of tabs: Game, GTA's own settings (read from GTA and changed through it, kept
// for every server), and Server, each player's own choices for this server (kept on their PC). Game is there only
// with the experimental Combined Settings page on (pause.js): off, the page is Server Settings, the Server tabs alone,
// and the pause menu's Game Settings is GTA's own settings menu. In the middle the
// chosen tab's rows, each with what it is set to, to scan; on the right the inspector: the chosen row's whole control
// (every choice side by side, or a slider), what it does, and what the tab can show beside it: on Graphics the video
// memory and the changes waiting for Apply, on Minimap the minimap itself, on Audio the mix.
//
// THE MARKS MEAN ONE THING EACH. A blue dot is a game change not applied yet: graphics changes wait for Apply, as in
// GTA (Apply changes, or Discard, in the head). A hollow ring is a server row set differently from the server's
// default. Greyed, "Not available" is GTA not letting it change; "Disabled by server admin" is the server's config.
//
// LUA OWNS EVERY VALUE. A game change goes to client/game_settings.lua, which makes it in GTA's own menu under this
// page as a player would, and answers with the tab as GTA now has it; it takes a moment, so the row says it is
// changing and the next change waits for it. A server change goes to client/player_prefs.lua, which answers with every
// server row. GTA's own questions (keep these display settings?) come up over the page and are answered from it;
// leaving with changes not applied asks first. Key Bindings is GTA's own screen: its tab opens it.
//
// Keyboard, mouse and pad: up / down choose a row, left / right change it, Enter or A does a row that does something
// (or steps a choice on), Q / E or LB / RB the tabs, R or Y apply (Game) or reset the tab (Server), Esc or B back to
// the menu. pause.js hands keys and the pad over in this mode.
// ========================================

import { nuiCallback, escapeHtml } from './utils.js';
import { padGlyph } from './pad-glyphs.js';
import { NuiRouter } from './router.js';
import { screenRect } from './pad-cursor.js';
import { setPref } from './prefs.js';
// PF: the original's minimap preview (minimap.js, on a "Minimap" tab) is left out; these stand in for it, so that
// tab's module is simply not drawn.
const MinimapPreview = null;
const previewSpeedRange = () => ({ max: 200, step: 5, unit: 'km/h' });
const minimapAspect = () => 1.5;

/** GTA's tabs in this order, by GTA's menu id; one GTA has that is not here comes after them, in GTA's order. */
const GAME_ORDER = [1023, 1137, 1138, 1022, 1136, 1140, 1024, 1131, 1146];
const GRAPHICS = new Set([1137, 1138]);
const AUDIO = 1022;
const MINIMAP_GROUP = 'Minimap';

/** Pad and key intents that change something: not taken while a game change is being made (nav). */
const CHANGES = new Set(['left', 'right', 'select', 'buttonX', 'buttonY']);

/** The rail's icons: one stroke, one size. */
const ICONS = {
    display: '<rect x="3" y="4" width="18" height="12" rx="2"/><path d="M8 20h8"/>',
    graphics: '<path d="M4 18l5-6 4 4 3-3 4 5z"/><circle cx="9" cy="7" r="1.6" fill="currentColor"/>',
    advanced: '<path d="M4 7h10M18 7h2M4 17h4M12 17h8"/><circle cx="16" cy="7" r="2"/><circle cx="10" cy="17" r="2"/>',
    audio: '<path d="M4 10v4h4l5 4V6L8 10z"/><path d="M16 9a4 4 0 010 6"/>',
    camera: '<rect x="3" y="7" width="13" height="10" rx="2"/><path d="M16 11l5-3v8l-5-3"/>',
    mouse: '<rect x="6" y="3" width="12" height="18" rx="6"/><path d="M12 7v4"/>',
    pad: '<path d="M7 8h10a4 4 0 014 4l-1 4a2 2 0 01-3.6.8L15 15H9l-1.4 1.8A2 2 0 014 16l-1-4a4 4 0 014-4z"/>',
    keys: '<rect x="3" y="6" width="18" height="12" rx="2"/><path d="M7 10h1M11 10h1M15 10h2M7 14h10"/>',
    editor: '<circle cx="12" cy="12" r="8"/><circle cx="12" cy="12" r="2.6" fill="currentColor"/>',
    controller: '<circle cx="12" cy="5.5" r="2.5"/><circle cx="12" cy="18.5" r="2.5"/><circle cx="5.5" cy="12" r="2.5"/><circle cx="18.5" cy="12" r="2.5"/>',
    vehicles: '<path d="M5 15l1.5-5a2 2 0 012-1.4h7a2 2 0 012 1.4L19 15M4 15h16v3H4z"/>',
    map: '<path d="M9 4L3 6v14l6-2 6 2 6-2V4l-6 2z"/>',
    minimap: '<circle cx="12" cy="12" r="8"/><path d="M12 8l2 5-2-1-2 1z" fill="currentColor"/>',
    chat: '<path d="M5 5h14v10H9l-4 4z"/>',
    other: '<path d="M4 7h16M4 12h16M4 17h10"/>',
    out: '<path d="M14 4h6v6M20 4l-9 9M18 14v5a1 1 0 01-1 1H5a1 1 0 01-1-1V7a1 1 0 011-1h5"/>',
    left: '<path d="M15 5l-7 7 7 7"/>',
    right: '<path d="M9 5l7 7-7 7"/>',
    to: '<path d="M5 12h13M13 6l6 6-6 6"/>',
    down: '<path d="M6 9l6 6 6-6"/>',
};
const GAME_ICON = { 1023: 'display', 1137: 'graphics', 1138: 'advanced', 1022: 'audio', 1136: 'camera', 1140: 'mouse',
    1024: 'pad', 1131: 'keys', 1146: 'editor' };
const SERVER_ICON = { 'Controller': 'controller', 'Vehicles': 'vehicles', 'Map & HUD': 'map', 'Minimap': 'minimap',
    'Chat & voice': 'chat', 'HUD': 'map', 'Map': 'map', 'Voice': 'chat', 'Chat': 'chat' };

function icon(name, cls = 'st-ico') {
    return `<svg class="${cls}" viewBox="0 0 24 24" aria-hidden="true">${ICONS[name] || ICONS.other}</svg>`;
}

/** A server slider's value as words: "120%", "300 ms". */
function serverNumber(row, v) {
    const n = Number(v);
    const s = Number.isInteger(n) ? String(n) : n.toFixed(2).replace(/0+$/, '').replace(/\.$/, '');
    if (!row.unit) return s;
    return row.unit === '%' ? s + '%' : s + ' ' + row.unit;
}

/** A game row as the page shows it. GTA's kinds: slider, list (its choices known, or filled by GTA as it goes),
 *  button (something to do), info. */
function gameRow(r) {
    const row = { src: 'game', id: r.id, label: r.label, locked: !!r.locked, pending: !!r.changed };
    if (r.kind === 'slider') {
        Object.assign(row, { kind: 'slider', value: r.value, min: 0, max: r.max, step: 1, text: String(r.value) });
        if (row.pending) row.was = String(r.was);
    } else if (r.kind === 'list') {
        row.text = r.text || '';
        if (Array.isArray(r.options) && r.options.length > 1) {
            Object.assign(row, { kind: 'choice', value: r.value, options: r.options.map((label, i) => ({ value: i, label })) });
        } else row.kind = 'stepper';
        if (row.pending) row.was = String(r.was ?? '');
    } else if (r.kind === 'button') row.kind = 'action';
    else Object.assign(row, { kind: 'info', text: r.text || '' });
    return row;
}

/** A server row (player_prefs.lua) as the page shows it: a switch is a choice of Off and On. */
function serverRow(r) {
    const row = { src: 'server', id: r.key, key: r.key, label: r.label, help: r.help, locked: !!r.locked,
        mine: !!r.changed, def: r.default };
    if (r.type === 'toggle') {
        Object.assign(row, { kind: 'choice', toggle: true, value: !!r.value,
            options: [{ value: false, label: 'Off' }, { value: true, label: 'On' }] });
    } else if (r.type === 'choice') {
        Object.assign(row, { kind: 'choice', value: r.value, options: (r.options || []).map((o) => ({ value: o.value, label: o.label })) });
    } else if (r.type === 'slider') {
        Object.assign(row, { kind: 'slider', value: Number(r.value), min: Number(r.min), max: Number(r.max),
            step: Number(r.step) || 1, unit: r.unit });
    } else Object.assign(row, { kind: 'info', text: String(r.value ?? '') });
    if (row.kind === 'choice') row.text = row.options.find((o) => o.value === row.value)?.label ?? String(row.value);
    if (row.kind === 'slider') row.text = serverNumber(row, row.value);
    return row;
}

/** A server row's default, in words. */
function defaultWords(row) {
    if (row.kind === 'choice') return row.options.find((o) => o.value === row.def)?.label ?? String(row.def);
    if (row.kind === 'slider') return serverNumber(row, row.def);
    return String(row.def ?? '');
}

/** Where a value sits on a slider's track, 0-1. */
function fracOf(row, v) {
    const span = Number(row.max) - Number(row.min);
    return span > 0 ? Math.max(0, Math.min(1, (Number(v) - Number(row.min)) / span)) : 0;
}

/** A slider's value from where on its track (0-1), in its steps. */
function valueAt(row, frac) {
    const min = Number(row.min), max = Number(row.max), step = Number(row.step) || 1;
    const raw = min + Math.max(0, Math.min(1, frac)) * (max - min);
    const v = min + Math.round((raw - min) / step) * step;
    return Math.max(min, Math.min(max, Math.round(v * 1000) / 1000));
}

/** A change GTA has to make (a row moving in its menu) or the server's (instant). */
const changeable = (row) => row && !row.locked && (row.kind === 'slider' || row.kind === 'choice' || row.kind === 'stepper');

export class SettingsPage {
    /** @param {HTMLElement} root  the pause menu's root; @param {() => void} onBack  back to its menu */
    constructor(root, onBack) {
        this.onBack = onBack;
        this.isOpen = false;
        this.withGame = false;       // the Game tabs are here (the Combined Settings page), from open()
        this.tabKey = null;          // 'g:<GTA menu id>' or 's:<server group>': kept for next time
        this.sel = 0;
        this.game = { state: 'idle', tabs: [], tab: null, loading: false, unapplied: false, pending: [], failed: '' };
        this.server = null;          // player_prefs.lua's page state: { groups: [{ id, label, rows }] }
        this.note = '';              // a change refused: why
        this.working = null;         // the game row being changed ('apply', 'undo': those)
        this.question = null;        // up over the page: GTA's question, or the page's own before leaving
        this.questionSel = 0;
        this.answering = false;      // an answer to GTA's question being pressed: the pad's input is Lua's press, not the player's
        this.confirmReset = false;   // "Reset this tab?" in the head, for a server tab
        this.confirmSel = 1;
        this.drag = null;            // the inspector's slider being dragged: { row, track, value }
        this.seq = 0;                // each game tab asked for: only the newest answer is drawn
        this.serverSeq = 0;          // likewise, each server change
        this.preview = null;         // the minimap's preview, on the Minimap tab
        this.previewMode = 'car';
        this.previewSpeed = 60;

        const wrap = document.createElement('section');
        wrap.className = 'pm-st';
        wrap.innerHTML = `
            <div class="st-z">
                <header class="st-head"></header>
                <div class="st-body">
                    <nav class="st-rail" aria-label="Settings tabs"></nav>
                    <section class="st-list" aria-label="Settings">
                        <div class="st-scroll"><div class="st-rows"></div></div>
                        <button class="st-more" type="button" tabindex="-1">More below ${icon('down', 'st-more-ico')}</button>
                    </section>
                    <aside class="st-insp"></aside>
                </div>
                <div class="st-ask"><div class="st-ask-card" role="alertdialog" aria-labelledby="st-ask-t">
                    <h2 class="st-ask-title" id="st-ask-t"></h2><p class="st-ask-body"></p><div class="st-ask-row"></div>
                </div></div>
            </div>
            <div class="st-preview"></div>`;
        root.appendChild(wrap);
        this.wrap = wrap;
        this.headEl = wrap.querySelector('.st-head');
        this.railEl = wrap.querySelector('.st-rail');
        this.listEl = wrap.querySelector('.st-list');
        this.scrollEl = wrap.querySelector('.st-scroll');
        this.rowsEl = wrap.querySelector('.st-rows');
        this.inspEl = wrap.querySelector('.st-insp');
        this.askEl = wrap.querySelector('.st-ask');
        this.askTitle = wrap.querySelector('.st-ask-title');
        this.askBody = wrap.querySelector('.st-ask-body');
        this.askRow = wrap.querySelector('.st-ask-row');
        this.previewHost = wrap.querySelector('.st-preview');

        // ---- mouse ----
        this.headEl.addEventListener('click', (e) => {
            const b = e.target.closest('button');
            if (!b || this.question) return;
            const act = b.dataset.act;
            if (act === 'back') this.back();
            else if (act === 'apply') this.apply();
            else if (act === 'discard') this.undo(null);
            else if (act === 'reset') this.askReset();
            else if (act === 'reset-yes') this.answerReset(0);
            else if (act === 'reset-no') this.answerReset(1);
            else if (act === 'retry') this.openGame();
        });
        this.railEl.addEventListener('click', (e) => {
            const b = e.target.closest('[data-tab]');
            if (b && !this.question) this.setTab(b.dataset.tab);
            else if (e.target.closest('[data-act="retry"]')) this.openGame();
            else if (e.target.closest('[data-act="gta"]')) this.openGtaSettings();
        });
        // MOUSEMOVE, NOT MOUSEOVER: every draw rebuilds the rows, and a fresh mouseover on the row under a still mouse
        // would take the choice back from the keys and pad.
        this.rowsEl.addEventListener('mousemove', (e) => {
            const r = e.target.closest('.st-row');
            if (!r || this.question || this.drag) return;
            const i = Number(r.dataset.i);
            if (i !== this.sel) { this.sel = i; this.draw(); this.follow(); }
        });
        this.rowsEl.addEventListener('click', (e) => {
            if (this.question) return;
            if (e.target.closest('[data-act="retry"]')) { this.openGame(); return; }
            if (e.target.closest('[data-act="gta"]')) { this.openGtaSettings(); return; }
            const r = e.target.closest('.st-row');
            if (!r) return;
            this.sel = Number(r.dataset.i);
            const arrow = e.target.closest('[data-d]');
            const row = this.row();
            if (arrow) this.step(Number(arrow.dataset.d));
            else if (row && (row.kind === 'action' || row.kind === 'keys')) this.press();
            else this.draw();
        });
        this.inspEl.addEventListener('click', (e) => {
            if (this.question) return;
            const b = e.target.closest('button');
            if (!b) return;
            const row = this.row();
            if (b.dataset.o !== undefined && row) this.setTo(row, row.options[Number(b.dataset.o)].value);
            else if (b.dataset.d !== undefined) this.step(Number(b.dataset.d));
            else if (b.dataset.act === 'press') this.press();
            else if (b.dataset.act === 'keys') this.openKeys();
            else if (b.dataset.act === 'usedef' && row) this.setTo(row, row.def);
            else if (b.dataset.undo) {
                const [tab, id] = b.dataset.undo.split('|').map(Number);
                this.undo({ tab, id });
            } else if (b.dataset.pv) this.setPreviewMode(b.dataset.pv);
            else if (b.dataset.pvd) this.setPreviewSpeed(this.previewSpeed + Number(b.dataset.pvd) * previewSpeedRange().step * 2);
        });
        // The inspector's slider dragged: drawn as it moves, sent once when let go.
        this.inspEl.addEventListener('pointerdown', (e) => {
            const track = e.target.closest('.st-track');
            const row = this.row();
            if (!track || !row || row.kind !== 'slider' || row.locked || this.question || this.working) return;
            e.preventDefault();
            this.drag = { row, track, value: row.value };
            track.setPointerCapture?.(e.pointerId);
            this.dragTo(e.clientX);
        });
        this.inspEl.addEventListener('pointermove', (e) => { if (this.drag) this.dragTo(e.clientX); });
        const endDrag = () => {
            if (!this.drag) return;
            const { row, value } = this.drag;
            this.drag = null;
            if (value !== row.value) this.setTo(row, value); else this.draw();
        };
        this.inspEl.addEventListener('pointerup', endDrag);
        this.inspEl.addEventListener('pointercancel', endDrag);
        this.scrollEl.addEventListener('scroll', () => this.syncMore());
        wrap.querySelector('.st-more').addEventListener('click', () => {
            this.scrollEl.scrollBy({ top: this.scrollEl.clientHeight * 0.8, behavior: 'smooth' });
        });
        this.askRow.addEventListener('click', (e) => {
            const b = e.target.closest('button');
            if (b) this.answer(Number(b.dataset.c));
        });
        this.askRow.addEventListener('mousemove', (e) => {
            const b = e.target.closest('button');
            if (b && Number(b.dataset.c) !== this.questionSel) { this.questionSel = Number(b.dataset.c); this.drawQuestion(); }
        });
        addEventListener('resize', () => { if (this.isOpen) { this.placePreview(); this.syncMore(); } });

        // GTA asking (or done asking: `refresh`, its answer may have changed the tab).
        NuiRouter.register('gameSettingsQuestion', (d) => {
            if (!this.isOpen) return;
            if (d && d.question) this.ask(d.question);
            else {
                if (this.question && !this.question.own) this.question = null;
                this.draw();
                if (d && d.refresh) this.reloadGame();
            }
        });
    }

    // ---- open and close ----

    /** @param {{ game?: boolean }} [opts]  game: GTA's tabs too (the Combined Settings page); without, the server's alone */
    open(opts) {
        this.isOpen = true;
        this.withGame = !!(opts && opts.game);
        this.note = '';
        this.question = null;
        this.confirmReset = false;
        this.server = null;
        this.game = { state: 'idle', tabs: [], tab: null, loading: false, unapplied: false, pending: [], failed: '' };
        this.draw();
        nuiCallback('prefsState', {}).then((st) => this.setServer(st));
        if (this.withGame) this.openGame();
    }

    /** GTA's settings menu opened under the page: its tabs, and the game tab shown (if one is). */
    openGame() {
        this.game = { state: 'loading', tabs: [], tab: null, loading: true, unapplied: false, pending: [], failed: '' };
        this.draw();
        const seq = ++this.seq;
        // The tab shown, or with none yet the first in this page's order: GTA opens on it.
        const cur = this.current();
        const want = cur ? (cur.section === 'game' && !cur.keys ? cur.id : null) : GAME_ORDER[0];
        nuiCallback('gameSettingsOpen', { tab: want }).then((st) => {
            if (seq !== this.seq || !this.isOpen) return;
            if (!st || st.error || !Array.isArray(st.tabs)) {
                this.game.state = 'failed';
                this.game.loading = false;
                this.game.failed = (st && st.error) || 'no answer';
                this.draw();
                return;
            }
            const order = (id) => { const i = GAME_ORDER.indexOf(id); return i < 0 ? GAME_ORDER.length : i; };
            this.game.tabs = st.tabs.map((t, i) => ({ ...t, n: i })).sort((a, b) => order(a.id) - order(b.id) || a.n - b.n);
            this.game.state = 'ready';
            this.game.loading = false;
            // No tab yet, or one that is gone: the first.
            if (!this.current()) this.tabKey = this.tabs()[0]?.key ?? null;
            this.setGame(st);
            const now = this.current();
            if (now && now.section === 'game' && !now.keys && st.tab && st.tab.id !== now.id) this.loadGameTab(now.id);
        });
    }

    close() {
        if (!this.isOpen) return;
        this.isOpen = false;
        this.drag = null;
        this.working = null;
        this.question = null;
        this.answering = false;
        this.syncPreview();
        if (this.withGame) nuiCallback('gameSettingsClose', {});
    }

    /** game_settings.lua's answer: the tab as GTA has it (kept when it is the one shown), the changes waiting. */
    setGame(st) {
        if (!st) return;
        if (st.error) this.note = 'Not changed: ' + st.error;
        if (st.notice) this.note = st.notice;
        if (typeof st.unapplied === 'boolean') this.game.unapplied = st.unapplied;
        if (Array.isArray(st.pending)) this.game.pending = st.pending;
        const t = st.tab;
        const cur = this.current();
        if (t && Array.isArray(t.rows) && cur && cur.section === 'game' && t.id === cur.id) {
            const rowId = this.row()?.id;
            const same = this.game.tab && this.game.tab.id === t.id;
            this.game.tab = t;
            this.game.loading = false;
            const rows = this.rows();
            const r = same ? rows.findIndex((x) => x.id === rowId) : -1;
            this.sel = r >= 0 ? r : (same ? Math.min(this.sel, Math.max(0, rows.length - 1)) : 0);
        }
        if (this.isOpen) this.draw();
    }

    /** player_prefs.lua's answer: every server row. */
    setServer(st) {
        if (!st || !Array.isArray(st.groups)) return;
        const rowId = this.row()?.id;
        for (const g of st.groups) if (!Array.isArray(g.rows)) g.rows = [];
        this.server = st;
        if (st.error) this.note = 'Not changed: ' + st.error;
        // Server Settings alone: no tab yet, or a Game one from the Combined Settings page, is the first.
        if (!this.withGame && !this.current()) { this.tabKey = this.tabs()[0]?.key ?? null; this.sel = 0; }
        if (this.current()?.section === 'server') {
            const rows = this.rows();
            const r = rows.findIndex((x) => x.id === rowId);
            if (r >= 0) this.sel = r;
        }
        if (this.isOpen) this.draw();
    }

    loadGameTab(id) {
        this.game.loading = true;
        this.draw();
        const seq = ++this.seq;
        nuiCallback('gameSettingsTab', { tab: id }).then((st) => {
            if (seq !== this.seq || !this.isOpen) return;
            this.game.loading = false;
            this.setGame(st);
        });
    }

    /** The game tab shown, read again (GTA answered a question, which may have changed it). */
    reloadGame() {
        const cur = this.current();
        if (cur && cur.section === 'game' && !cur.keys && this.game.state === 'ready') {
            const seq = ++this.seq;
            nuiCallback('gameSettingsTab', { tab: cur.id }).then((st) => {
                if (seq === this.seq && this.isOpen) this.setGame(st);
            });
        }
    }

    // ---- what is shown ----

    /** Every tab, Game's (with the Combined Settings page) then Server's. */
    tabs() {
        const game = !this.withGame ? []
            : this.game.tabs.map((t) => ({ key: 'g:' + t.id, section: 'game', id: t.id, label: t.label, keys: !!t.keys }));
        const server = (this.server?.groups || []).map((g) => ({ key: 's:' + g.id, section: 'server', id: g.id, label: g.label }));
        return game.concat(server);
    }

    current() { return this.tabs().find((t) => t.key === this.tabKey) || null; }

    group() {
        const cur = this.current();
        return cur && cur.section === 'server' ? this.server?.groups?.find((g) => g.id === cur.id) || null : null;
    }

    rows() {
        const cur = this.current();
        if (!cur) return [];
        if (cur.keys) return [{ src: 'game', id: 'keys', kind: 'keys', label: 'Open GTA\'s key bindings' }];
        if (cur.section === 'game') {
            const t = this.game.tab;
            return t && t.id === cur.id && !this.game.loading ? t.rows.map(gameRow) : [];
        }
        return (this.group()?.rows || []).map(serverRow);
    }

    row() { return this.rows()[this.sel] || null; }

    // ---- drawing ----

    draw() {
        if (!this.isOpen) return;
        const rows = this.rows();
        if (this.sel >= rows.length) this.sel = Math.max(0, rows.length - 1);
        this.drawHead();
        this.drawRail();
        this.drawRows(rows);
        this.drawInspector();
        this.drawQuestion();
        this.syncPreview();
        this.syncMore();
        NuiRouter.hintsChanged();
    }

    drawHead() {
        const cur = this.current();
        // Server Settings alone has one group: its tab's name is enough.
        const where = !cur ? ''
            : !this.withGame ? `<b>${escapeHtml(cur.label)}</b>`
            : `${cur.section === 'game' ? 'Game' : 'Server'}${icon('right', 'st-crumb-ico')}<b>${escapeHtml(cur.label)}</b>`;
        // A server tab's reset, and the game changes waiting for Apply (on any tab: they wait wherever you are).
        let side = '';
        if (cur && cur.section === 'server' && this.group()?.rows?.some((r) => r.changed)) {
            side = this.confirmReset
                ? `<div class="st-confirm"><span>Reset this tab?</span>`
                    + `<button type="button" class="st-btn st-red${this.confirmSel === 0 ? ' on' : ''}" data-act="reset-yes">Reset</button>`
                    + `<button type="button" class="st-btn${this.confirmSel === 1 ? ' on' : ''}" data-act="reset-no">Cancel</button></div>`
                : '<button type="button" class="st-btn st-red" data-act="reset">Reset this tab to server defaults</button>';
        }
        const pending = this.game.pending.length;
        if (this.game.unapplied && pending) {
            side += `<div class="st-pendbar" role="status"><span class="st-dot"></span>`
                + `<span>${pending === 1 ? '1 change' : pending + ' changes'} not applied yet</span>`
                + `<button type="button" class="st-btn" data-act="discard"${this.working ? ' disabled' : ''}>Discard</button>`
                + `<button type="button" class="st-btn st-pri" data-act="apply"${this.working ? ' disabled' : ''}>Apply changes</button></div>`;
        }
        const status = this.working === 'apply' ? 'Applying' : this.working === 'undo' ? 'Putting it back'
            : this.working ? 'Changing' : '';
        this.headEl.innerHTML = `<button type="button" class="st-back" data-act="back">${icon('left', 'st-back-ico')}Menu</button>`
            + `<h1 class="st-title">${this.withGame ? 'Settings' : 'Server Settings'}</h1>`
            + `<div class="st-crumb">${where}</div><div class="st-fill"></div>`
            + (status ? `<span class="st-status">${status}</span>` : '') + side;
    }

    drawRail() {
        const tabs = this.tabs();
        const pendTabs = new Set(this.game.pending.map((p) => p.tab));
        const item = (t) => {
            let end = '';
            if (t.keys) end = icon('out', 'st-ico st-end');
            else if (t.section === 'game' && pendTabs.has(t.id)) end = '<span class="st-dot st-end" aria-label="changes not applied yet"></span>';
            else if (t.section === 'server' && this.server?.groups?.find((g) => g.id === t.id)?.rows?.some((r) => r.changed)) {
                end = '<span class="st-ring st-end" aria-label="your own choices here"></span>';
            }
            const ico = t.section === 'game' ? GAME_ICON[t.id] : SERVER_ICON[t.id];
            return `<button type="button" class="st-nav${t.key === this.tabKey ? ' on' : ''}" data-tab="${escapeHtml(t.key)}">`
                + `${icon(ico)}<span class="st-nav-label">${escapeHtml(t.label)}</span>${end}</button>`;
        };
        let game = tabs.filter((t) => t.section === 'game').map(item).join('');
        if (this.game.state === 'loading') game = '<div class="st-railnote st-breathe">Opening GTA\'s settings</div>';
        else if (this.game.state === 'failed') {
            game = '<div class="st-railnote">Didn\'t open <button type="button" class="st-link" data-act="retry">Try again</button>'
                + ' <button type="button" class="st-link" data-act="gta">GTA\'s own</button></div>';
        }
        const server = tabs.filter((t) => t.section === 'server').map(item).join('')
            || '<div class="st-railnote st-breathe">Loading</div>';
        const glyphs = (g) => { const img = padGlyph(g, 'st-glyph'); return img ? img.outerHTML : ''; };
        const pad = `<span class="st-grp-pad">${glyphs('lb')}${glyphs('rb')}</span>`;
        if (!this.withGame) {
            this.railEl.innerHTML = `<div class="st-grp"><span>Server</span>${pad}</div>`
                + '<div class="st-grpsub">This server, kept on your PC</div>' + server;
            return;
        }
        this.railEl.innerHTML = `<div class="st-grp"><span>Game</span>${pad}</div>`
            + '<div class="st-grpsub">GTA\'s own, for every server</div>' + game
            + '<div class="st-grp st-grp-2">Server</div><div class="st-grpsub">This server, kept on your PC</div>' + server;
    }

    drawRows(rows) {
        const cur = this.current();
        if (!cur || (cur.section === 'game' && !cur.keys && (this.game.loading || this.game.state !== 'ready'))) {
            if (this.game.state === 'failed') {
                this.rowsEl.innerHTML = '<div class="st-empty"><h2>GTA\'s settings didn\'t open</h2>'
                    + `<p>${escapeHtml(this.game.failed)}. GTA's own settings menu still works meanwhile.</p>`
                    + '<div class="st-empty-btns"><button type="button" class="st-btn st-pill" data-act="retry">Try again</button>'
                    + '<button type="button" class="st-btn" data-act="gta">Open GTA\'s own settings</button></div></div>';
            } else {
                this.rowsEl.innerHTML = Array.from({ length: 9 }, (_, i) =>
                    `<div class="st-row st-skel"><span class="st-skelbar" style="width:${[46, 32, 54, 38, 50, 28, 44, 36, 48][i]}%"></span></div>`).join('');
            }
            return;
        }
        if (!rows.length) { this.rowsEl.innerHTML = '<div class="st-empty"><p>Nothing to set here.</p></div>'; return; }
        this.rowsEl.innerHTML = rows.map((row, i) => this.rowHtml(row, i)).join('');
        this.rowsEl.querySelector('.st-row.on')?.scrollIntoView?.({ block: 'nearest' });
    }

    rowHtml(row, i) {
        const on = i === this.sel && !this.question;
        const cls = 'st-row' + (on ? ' on' : '') + (row.pending ? ' pend' : '') + (row.locked ? ' off' : '')
            + (this.working === row.id ? ' working' : '');
        const mark = row.pending ? '<span class="st-dot" aria-label="not applied yet"></span>'
            : row.mine ? '<span class="st-ring" aria-label="your own choice"></span>' : '';
        const lock = row.locked ? `<span class="st-na">${row.src === 'server' ? 'Disabled by server admin' : 'Not available'}</span>` : '';
        let v = '';
        if (row.kind === 'slider') {
            v = `<span class="st-mini"><i style="width:${fracOf(row, row.value) * 100}%"></i></span><span class="st-num">${escapeHtml(row.text)}</span>`;
        } else if (row.kind === 'action') v = icon('right', 'st-go');
        else if (row.kind === 'keys') v = icon('out', 'st-go');
        else v = `<span class="st-txt">${escapeHtml(row.text ?? '')}</span>`;
        if (on && changeable(row)) {
            v = `<button type="button" class="st-arr" data-d="-1" aria-label="Less">${icon('left', 'st-arr-ico')}</button>`
                + `<span class="st-vmid">${v}</span>`
                + `<button type="button" class="st-arr" data-d="1" aria-label="More">${icon('right', 'st-arr-ico')}</button>`;
        }
        return `<div class="${cls}" data-i="${i}"><span class="st-k"><span class="st-label">${escapeHtml(row.label)}</span>${mark}${lock}</span>`
            + `<span class="st-v">${v}</span></div>`;
    }

    drawInspector() {
        const cur = this.current();
        const row = this.row();
        if (!cur || (cur.section === 'game' && !cur.keys && this.game.state !== 'ready')) {
            // Server Settings alone, its rows still coming: nothing of GTA's to wait for.
            this.inspEl.innerHTML = !this.withGame ? ''
                : this.game.state === 'failed'
                ? '<div class="st-ihold"><h2 class="st-ititle st-small">Server tabs still work</h2>'
                    + '<p class="st-help">Controller, Vehicles, Map &amp; HUD, Minimap and Chat &amp; voice are this server\'s own and don\'t need GTA\'s menu.</p></div>'
                : '<div class="st-ihold"><h2 class="st-ititle st-small">Reading GTA\'s settings</h2>'
                    + '<p class="st-help">They take a few seconds to open the first time, then each tab comes in about a second. The Server tabs work straight away.</p></div>';
            return;
        }
        if (!row) { this.inspEl.innerHTML = ''; return; }

        let chip = '';
        if (row.pending) chip = '<span class="st-chip st-chip-blue">Not applied yet</span>';
        else if (row.mine) chip = '<span class="st-chip"><span class="st-ring"></span>Your choice</span>';
        else if (row.locked) chip = `<span class="st-chip">${row.src === 'server' ? 'Disabled by server admin' : 'Not available'}</span>`;

        let control = '';
        let help = row.help || '';
        if (row.kind === 'choice') {
            control = '<div class="st-opts" role="radiogroup">' + row.options.map((o, k) => {
                const cur2 = o.value === row.value;
                let small = '';
                if (row.pending && o.label === row.was) small = '<small>in use now</small>';
                else if (row.src === 'server' && o.value === row.def && !row.locked) small = '<small>server default</small>';
                return `<button type="button" role="radio" aria-checked="${cur2}" class="st-opt${cur2 ? ' cur' : ''}" data-o="${k}"${row.locked ? ' disabled' : ''}>`
                    + `${escapeHtml(o.label)}${small}</button>`;
            }).join('') + '</div>';
        } else if (row.kind === 'stepper') {
            control = `<div class="st-stepper"><button type="button" class="st-arr st-arr-big" data-d="-1" aria-label="Previous"${row.locked ? ' disabled' : ''}>${icon('left', 'st-arr-ico')}</button>`
                + `<span class="st-stepval">${escapeHtml(row.text)}</span>`
                + `<button type="button" class="st-arr st-arr-big" data-d="1" aria-label="Next"${row.locked ? ' disabled' : ''}>${icon('right', 'st-arr-ico')}</button></div>`;
            if (row.pending) control += `<div class="st-was">In use now: ${escapeHtml(row.was)}</div>`;
            if (!help) help = 'GTA steps through these one at a time: left and right.';
        } else if (row.kind === 'slider') {
            const v = this.drag && this.drag.row.id === row.id ? this.drag.value : row.value;
            const pct = fracOf(row, v) * 100;
            const steps = Math.round((Number(row.max) - Number(row.min)) / (Number(row.step) || 1));
            const ticks = steps > 0 && steps <= 20
                ? '<div class="st-ticks" aria-hidden="true">' + '<i></i>'.repeat(steps + 1) + '</div>' : '';
            const def = row.src === 'server' && !row.locked ? `<div class="st-defmark" style="left:${fracOf(row, row.def) * 100}%" title="Server default"></div>` : '';
            const big = row.src === 'game'
                ? `<b>${v}</b><small> of ${row.max}</small>` : `<b>${escapeHtml(serverNumber(row, v))}</b>`;
            control = `<div class="st-slider${row.locked ? ' off' : ''}"><div class="st-track"><div class="st-trackbg"></div><div class="st-fillbar" style="width:${pct}%"></div>`
                + `${ticks}${def}<div class="st-thumb" style="left:${pct}%"></div></div><span class="st-bigval">${big}</span></div>`;
            if (row.pending) control += `<div class="st-was">In use now: ${escapeHtml(row.was)}</div>`;
        } else if (row.kind === 'action') {
            control = `<button type="button" class="st-btn st-pill st-act" data-act="press"${row.locked ? ' disabled' : ''}>${escapeHtml(row.label)}</button>`;
            if (!help) help = 'Enter or A does this. GTA may ask first.';
        } else if (row.kind === 'keys') {
            control = `<button type="button" class="st-btn st-pill st-act" data-act="keys">Open key bindings${icon('out', 'st-btn-ico')}</button>`;
            help = 'GTA\'s own key bindings screen. FiveM\'s and this server\'s keys are there too, under FiveM. The pause menu closes while it is open.';
        } else control = `<div class="st-stepval">${escapeHtml(row.text || '')}</div>`;

        let defLine = '';
        if (row.src === 'server' && !row.locked && row.kind === 'slider') {
            defLine = `<div class="st-defline"><span>Server default: ${escapeHtml(defaultWords(row))} (the mark on the track)</span>`
                + (row.mine ? '<button type="button" class="st-btn st-small-btn" data-act="usedef">Use the server\'s</button>' : '') + '</div>';
        } else if (row.src === 'server' && !row.locked && row.mine) {
            defLine = '<div class="st-defline"><span></span><button type="button" class="st-btn st-small-btn" data-act="usedef">Use the server\'s</button></div>';
        }
        if (!help && cur.section === 'game' && GRAPHICS.has(cur.id)) help = 'Graphics changes wait for Apply changes, as in GTA.';
        const note = this.note ? `<p class="st-help st-note">${escapeHtml(this.note)}</p>` : '';
        const keeper = cur.section === 'game' ? 'Kept by GTA on this PC, for every server' : 'This server\'s, kept on your PC';

        this.inspEl.innerHTML = `<div class="st-ihead"><h2 class="st-ititle">${escapeHtml(row.label)}</h2>${chip}</div>`
            + `<div class="st-control">${control}</div>${defLine}${note}`
            + (help ? `<p class="st-help">${escapeHtml(help)}</p>` : '')
            + `<div class="st-module">${this.moduleHtml(cur)}</div>`
            + `<div class="st-foot"><span class="st-keeper">${keeper}</span>${this.keysHtml(cur, row)}</div>`;
    }

    /** What the tab can show beside the row: the changes waiting and the video memory (Graphics), the mix (Audio),
     *  the minimap (Minimap). */
    moduleHtml(cur) {
        let out = '';
        if (cur.section === 'game' && GRAPHICS.has(cur.id)) {
            if (this.game.pending.length) {
                const tabRows = this.rows();
                out += '<h3 class="st-sec">Not applied yet</h3><div class="st-changes">' + this.game.pending.map((p) => {
                    const here = p.tab === cur.id ? tabRows.find((r) => r.id === p.id) : null;
                    const other = p.tab !== cur.id ? this.game.tabs.find((t) => t.id === p.tab)?.label : '';
                    return `<div class="st-change"><span class="st-change-k">${escapeHtml(p.label)}${other ? `<small>${escapeHtml(other)}</small>` : ''}</span>`
                        + `<span class="st-change-was">${escapeHtml(String(p.was ?? ''))}</span>${icon('to', 'st-to')}`
                        + `<span class="st-change-now">${escapeHtml(here ? here.text : '')}</span>`
                        + `<button type="button" class="st-btn st-small-btn" data-undo="${p.tab}|${p.id}"${this.working ? ' disabled' : ''}>Undo</button></div>`;
                }).join('') + '</div>';
            }
            const vm = this.game.tab?.vram;
            if (vm) {
                const p1 = Math.max(0, Math.min(100, Number(vm.percent) || 0));
                const p2 = Number(vm.percent2);
                out += '<h3 class="st-sec">Video memory</h3><div class="st-vram"><div class="st-vram-bar">'
                    + `<i style="width:${p1}%"></i>` + (p2 >= 0 ? `<i class="st-vram-2" style="width:${Math.max(0, Math.min(100, p2))}%"></i>` : '')
                    + `</div><div class="st-vram-label">${escapeHtml(vm.label || '')}</div></div>`;
            }
        } else if (cur.section === 'game' && cur.id === AUDIO) {
            const sliders = this.rows().filter((r) => r.kind === 'slider').slice(0, 3);
            if (sliders.length) {
                const sel = this.row();
                out += '<h3 class="st-sec">The mix</h3><div class="st-mix">' + sliders.map((r) =>
                    `<div class="st-lvl${sel && sel.id === r.id ? ' on' : ''}"><b>${escapeHtml(r.label)}</b>`
                    + `<span class="st-lvl-t"><i style="width:${fracOf(r, r.value) * 100}%"></i></span><span>${escapeHtml(r.text)}</span></div>`).join('') + '</div>';
            }
        } else if (cur.section === 'server' && cur.id === MINIMAP_GROUP && MinimapPreview) {
            const r = previewSpeedRange();
            out += '<div class="st-mm"><div class="st-mm-slot"></div><div class="st-mm-side">'
                + '<span class="st-mm-cap">Show the preview</span>'
                + `<div class="st-seg"><button type="button" class="st-segopt${this.previewMode === 'foot' ? ' cur' : ''}" data-pv="foot">On foot</button>`
                + `<button type="button" class="st-segopt${this.previewMode === 'car' ? ' cur' : ''}" data-pv="car">In a car</button></div>`
                + (this.previewMode === 'car'
                    ? `<div class="st-pvspeed"><button type="button" class="st-arr" data-pvd="-1" aria-label="Slower">${icon('left', 'st-arr-ico')}</button>`
                        + `<span>${Math.round(this.previewSpeed)} ${escapeHtml(r.unit)}</span>`
                        + `<button type="button" class="st-arr" data-pvd="1" aria-label="Faster">${icon('right', 'st-arr-ico')}</button></div>` : '')
                + '<span class="st-mm-caption"></span>'
                + '<span class="st-mm-note">Not settings: these only drive the preview.</span></div></div>';
        }
        return out;
    }

    /** The keyboard's keys for what can be done here (a pad's are in the hint strip). */
    keysHtml(cur, row) {
        const k = (inner) => `<span class="st-key">${inner}</span>`;
        let out = '';
        if (changeable(row)) out += k(icon('left', 'st-key-ico')) + k(icon('right', 'st-key-ico')) + '<span>Change</span>';
        if (this.game.unapplied && cur.section === 'game') out += k('R') + '<span>Apply</span>';
        else if (cur.section === 'server' && this.group()?.rows?.some((r) => r.changed)) out += k('R') + '<span>Reset tab</span>';
        out += k('Q') + k('E') + '<span>Tabs</span>';
        return `<span class="st-keys">${out}</span>`;
    }

    drawQuestion() {
        const q = this.question;
        this.wrap.classList.toggle('st-asking', !!q);
        if (!q) return;
        this.askTitle.textContent = q.title || '';
        this.askBody.textContent = q.body || '';
        this.askRow.innerHTML = (q.buttons || []).map((label, i) =>
            `<button type="button" class="st-btn${i === this.questionSel ? ' on' : ''}" data-c="${i}">${escapeHtml(label)}</button>`).join('');
    }

    /** "More below" while the list goes on past the bottom; its top fades once it is scrolled. */
    syncMore() {
        const s = this.scrollEl;
        this.listEl.classList.toggle('st-has-more', s.scrollTop + s.clientHeight < s.scrollHeight - 4);
        this.listEl.classList.toggle('st-scrolled', s.scrollTop > 4);
    }

    /** The minimap's preview up while the Minimap tab is, laid over its place in the inspector in true px (the
     *  inspector is zoomed; a canvas is drawn unzoomed). */
    syncPreview() {
        const cur = this.current();
        const want = !!MinimapPreview && this.isOpen && cur?.section === 'server' && cur.id === MINIMAP_GROUP && !!this.inspEl.querySelector('.st-mm-slot');
        if (!want) {
            if (this.preview) { this.preview.destroy(); this.preview = null; }
            this.previewHost.style.display = 'none';
            return;
        }
        const slot = this.inspEl.querySelector('.st-mm-slot');
        slot.style.aspectRatio = String(minimapAspect());
        const caption = this.inspEl.querySelector('.st-mm-caption');
        if (!this.preview) {
            this.preview = new MinimapPreview(this.previewHost, caption);
            this.preview.setMode(this.previewMode);
            this.preview.setSpeed(this.previewSpeed);
        } else this.preview.caption = caption;
        this.previewHost.style.display = 'block';
        this.placePreview();
    }

    placePreview() {
        if (!this.preview) return;
        const slot = this.inspEl.querySelector('.st-mm-slot');
        if (!slot) return;
        const box = screenRect(slot), frame = this.wrap.getBoundingClientRect();
        if (!(box.width > 0)) return;
        const s = this.previewHost.style;
        s.left = Math.round(box.left - frame.left) + 'px';
        s.top = Math.round(box.top - frame.top) + 'px';
        s.width = Math.round(box.width) + 'px';
        this.preview.layout();
    }

    setPreviewMode(mode) {
        this.previewMode = mode === 'foot' ? 'foot' : 'car';
        this.preview?.setMode(this.previewMode);
        this.draw();
    }

    setPreviewSpeed(v) {
        const r = previewSpeedRange();
        this.previewSpeed = Math.max(0, Math.min(r.max, Math.round(v / r.step) * r.step));
        this.preview?.setSpeed(this.previewSpeed);
        this.draw();
    }

    dragTo(clientX) {
        const d = this.drag;
        if (!d) return;
        // In screen pixels, as clientX is: the track is in the zoomed page, which FiveM's Chromium 103 can measure unzoomed.
        const box = screenRect(d.track);
        const v = valueAt(d.row, box.width > 0 ? (clientX - box.left) / box.width : 0);
        if (v === d.value) return;
        d.value = v;
        if (d.row.src === 'server') setPref(d.row.key, v);
        // Only this slider moves while dragging: the inspector is not rebuilt under the pointer.
        const pct = fracOf(d.row, v) * 100;
        const el = d.track.closest('.st-slider');
        el.querySelector('.st-fillbar').style.width = pct + '%';
        el.querySelector('.st-thumb').style.left = pct + '%';
        const big = el.querySelector('.st-bigval b');
        if (big) big.textContent = d.row.src === 'game' ? String(v) : serverNumber(d.row, v);
    }

    // ---- doing ----

    /** A game change: to GTA, the row marked as changing until GTA answers. One at a time. Apply and Discard work
     *  from any tab (Lua finds the changes); only a Game tab GTA can read is named, never Key Bindings (its own screen). */
    async gameChange(row, callback, args, working) {
        const cur = this.current();
        const tab = cur?.section === 'game' && !cur.keys ? cur.id : undefined;
        if (this.working || (row && tab === undefined)) return;
        this.note = '';
        this.working = working || row?.id || 'change';
        this.draw();
        const st = await nuiCallback(callback, { tab, id: row?.id, ...args });
        this.working = null;
        if (!this.isOpen) return;
        this.setGame(st);
        this.draw();
    }

    /** A server change: shown at once, Lua's answer drawn when it is the newest. */
    async serverChange(row, value) {
        this.note = '';
        if (row.locked) { this.note = 'Disabled by server admin'; this.draw(); return; }
        if (value === row.value) { this.draw(); return; }
        setPref(row.key, value);
        const g = this.group();
        const raw = g?.rows?.find((r) => r.key === row.key);
        if (raw) raw.value = value;
        this.draw();
        const seq = ++this.serverSeq;
        const st = await nuiCallback('prefsSet', { key: row.key, value });
        if (seq === this.serverSeq) this.setServer(st);
    }

    /** Left / right on the chosen row. */
    step(d) {
        const row = this.row();
        if (!changeable(row)) return;
        if (row.src === 'game') {
            if (row.kind === 'slider' && ((d > 0 && row.value >= row.max) || (d < 0 && row.value <= 0))) return;
            this.gameChange(row, 'gameSettingsStep', { dir: d > 0 ? 1 : -1 });
            return;
        }
        if (row.kind === 'choice') {
            const i = row.options.findIndex((o) => o.value === row.value);
            const next = row.options[Math.max(0, Math.min(row.options.length - 1, (i < 0 ? 0 : i) + d))];
            if (next) this.serverChange(row, next.value);
        } else if (row.kind === 'slider') {
            this.serverChange(row, valueAt(row, fracOf(row, row.value + d * row.step)));
        }
    }

    /** A row to a value: a choice clicked, a slider let go. */
    setTo(row, value) {
        if (value === row.value) { this.draw(); return; }
        if (row.src === 'game') this.gameChange(row, 'gameSettingsSet', { value });
        else this.serverChange(row, value);
    }

    /** Enter or A on the chosen row. */
    press() {
        if (this.game.state === 'failed' && this.current()?.section !== 'server') { this.openGame(); return; }
        const row = this.row();
        if (!row || row.locked) return;
        if (row.kind === 'keys') this.openKeys();
        else if (row.kind === 'action') this.gameChange(row, 'gameSettingsPress', {});
        else if (row.kind === 'choice' && row.src === 'server') {
            const i = row.options.findIndex((o) => o.value === row.value);
            this.serverChange(row, row.options[(i + 1) % row.options.length].value);
        } else if (row.kind === 'choice' || row.kind === 'stepper') this.step(1);
    }

    apply() {
        if (this.working || !this.game.unapplied) return;
        this.gameChange(null, 'gameSettingsApply', {}, 'apply');
    }

    /** Undo one change waiting for Apply ({ tab, id }), or every one (null: Discard). */
    undo(which) {
        if (this.working || !this.game.pending.length) return;
        this.gameChange(null, 'gameSettingsUndo', which ? { tab: which.tab, id: which.id } : { all: true }, 'undo');
    }

    /** GTA's key bindings, after the question Back asks when graphics changes wait for Apply (leaving drops them). */
    openKeys() {
        if (this.game.unapplied && !this.question) { this.ask({ ...LEAVE_QUESTION, then: 'keys' }); return; }
        this.openKeysNow();
    }

    /** This page and the pause menu shut, and pause.lua opens GTA's key bindings once GTA's settings menu under this
     *  page has gone. */
    openKeysNow() {
        this.close();
        nuiCallback('pauseKeyBindings', {});
    }

    /** GTA's own settings menu in the pause menu's place: the way in when this page cannot read GTA's (a game update
     *  this page's copy of GTA's settings page is not built for yet). */
    openGtaSettings() {
        this.close();
        nuiCallback('pauseSettings', {});
    }

    setTab(key) {
        if (this.question) return;
        const t = this.tabs().find((x) => x.key === key);
        if (!t || t.key === this.tabKey) return;
        this.tabKey = t.key;
        this.sel = 0;
        this.note = '';
        this.confirmReset = false;
        this.scrollEl.scrollTop = 0;
        if (t.section === 'game' && !t.keys && this.game.state === 'ready') this.loadGameTab(t.id);
        else this.draw();
    }

    stepTab(d) {
        const tabs = this.tabs();
        if (!tabs.length) return;
        const i = tabs.findIndex((t) => t.key === this.tabKey);
        this.setTab(tabs[((i < 0 ? 0 : i + d) % tabs.length + tabs.length) % tabs.length].key);
    }

    move(d) {
        const n = this.rows().length;
        if (!n) return;
        this.sel = (this.sel + d + n) % n;
        this.note = '';
        this.draw();
        this.follow();
    }

    /** GTA's menu put on the row chosen here once the choice settles (not every row passed on the way), as GTA's own
     *  follows the mouse and pad: a change after is then one press to GTA. */
    follow() {
        clearTimeout(this.followTimer);
        const cur = this.current();
        const row = this.row();
        if (cur?.section !== 'game' || cur.keys || !row || row.locked) return;
        const key = this.tabKey;
        this.followTimer = setTimeout(() => {
            if (this.isOpen && this.tabKey === key && this.row()?.id === row.id) {
                nuiCallback('gameSettingsFocus', { tab: cur.id, id: row.id });
            }
        }, 150);
    }

    askReset() {
        if (!this.group()?.rows?.some((r) => r.changed)) return;
        this.confirmReset = true;
        this.confirmSel = 1;
        this.draw();
    }

    /** Reset (0): this tab's rows back to the server's defaults; Cancel (1). */
    async answerReset(i) {
        this.confirmReset = false;
        if (i === 0) {
            ++this.serverSeq;
            const st = await nuiCallback('prefsReset', { group: this.group()?.id });
            this.setServer(st);
            this.note = 'This tab is back to the server\'s defaults';
        }
        this.draw();
    }

    /** Back to the menu; with graphics changes not applied, asked first. */
    back() {
        if (this.game.unapplied && !this.question) { this.ask(LEAVE_QUESTION); return; }
        this.onBack();
    }

    ask(q) {
        this.question = q;
        this.questionSel = 0;   // the first: what GTA suggests (Apply, Keep, OK)
        this.draw();
    }

    /** A button of the question up: GTA's go to GTA; the page's own apply, leave or stay. */
    answer(i) {
        const q = this.question;
        if (!q) return;
        if (q.own) {
            this.question = null;
            if (i === 0) this.apply();
            else if (i === 1) {
                this.game.unapplied = false;
                if (q.then === 'keys') this.openKeysNow(); else this.onBack();
            } else this.draw();
            return;
        }
        // GTA's: put away until GTA asks again or is done, so a second tap lands on nothing, never on GTA's next
        // question. It names the question it answers; Lua shows it again if GTA did not take the press. The pad reads
        // Lua's press as well (an A or B the player did not make), so no pad input is taken until it is over.
        this.question = null;
        this.answering = true;
        this.draw();
        nuiCallback('gameSettingsAnswer', { index: i + 1, id: q.id }).then(() => { this.answering = false; });
    }

    // ---- keys and the pad (pause.js hands them over in this mode) ----

    /** A key. Answers false when it was "back" out of the page (pause.js goes to its menu). */
    onKey(e) {
        if (e.type && e.type !== 'keydown') return true;
        const k = e.key.toLowerCase();
        if (k === 'arrowup' || k === 'w') return this.nav('up');
        if (k === 'arrowdown' || k === 's') return this.nav('down');
        if (k === 'arrowleft' || k === 'a') return this.nav('left');
        if (k === 'arrowright' || k === 'd') return this.nav('right');
        if (k === 'enter' || k === ' ') return this.nav('select');
        if (k === 'escape' || k === 'backspace') return this.nav('back');
        if (k === 'q') return this.nav('tabPrev');
        if (k === 'e' || k === 'tab') { e.preventDefault?.(); return this.nav('tabNext'); }
        if (k === 'r') return this.nav('buttonY');
        return true;
    }

    /** A pad (or key) intent. Answers false for "back" out of the page. */
    nav(n) {
        // Lua's presses to GTA reach the pad too, as an A, B, X or direction the player did not make: none is taken
        // while an answer is pressed, and none that changes something while a change is made (bar answering GTA's
        // question, which the change waits on).
        if (this.answering) return true;
        if (this.question) {
            const count = this.question.buttons.length;
            if (n === 'left' || n === 'up') { this.questionSel = (this.questionSel + count - 1) % count; this.drawQuestion(); }
            else if (n === 'right' || n === 'down') { this.questionSel = (this.questionSel + 1) % count; this.drawQuestion(); }
            else if (n === 'select') this.answer(this.questionSel);
            else if (n === 'back') this.answer(count - 1);   // the last: Cancel, Revert, Not now, Stay
            return true;
        }
        if (this.working && CHANGES.has(n)) return true;
        if (this.confirmReset) {
            if (n === 'left' || n === 'right') { this.confirmSel = 1 - this.confirmSel; this.drawHead(); }
            else if (n === 'select') this.answerReset(this.confirmSel);
            else if (n === 'back') { this.confirmReset = false; this.draw(); }
            return true;
        }
        if (n === 'up') this.move(-1);
        else if (n === 'down') this.move(1);
        else if (n === 'left') this.step(-1);
        else if (n === 'right') this.step(1);
        else if (n === 'select') this.press();
        else if (n === 'tabPrev') this.stepTab(-1);
        else if (n === 'tabNext') this.stepTab(1);
        else if (n === 'buttonX' && this.game.state === 'failed') this.openGtaSettings();
        else if (n === 'buttonY') {
            if (this.current()?.section === 'server') this.askReset(); else this.apply();
        } else if (n === 'back') {
            if (this.game.unapplied) { this.ask(LEAVE_QUESTION); return true; }
            return false;
        }
        return true;
    }

    /** The pad's hint strip (controller.js). */
    hints() {
        if (this.question || this.confirmReset) return [['dpad', 'Choose'], ['a', 'Select'], ['b', 'Back']];
        const row = this.row();
        const h = [['dpad', changeable(row) ? 'Choose / change' : 'Choose']];
        if (this.game.state === 'failed' && this.current()?.section !== 'server') h.push(['a', 'Try again'], ['x', 'GTA\'s own settings']);
        else if (row && (row.kind === 'action' || row.kind === 'keys')) h.push(['a', 'Select']);
        else if (row && (row.kind === 'choice' || row.kind === 'stepper') && !row.locked) h.push(['a', 'Next']);
        h.push(['lb', ''], ['rb', 'Tab']);
        if (this.game.unapplied && this.current()?.section === 'game') h.push(['y', 'Apply changes']);
        else if (this.current()?.section === 'server' && this.group()?.rows?.some((r) => r.changed)) h.push(['y', 'Reset tab']);
        h.push(['b', 'Back']);
        return h;
    }
}

/** Asked before leaving with graphics changes not applied: the page's own question, not GTA's. Leaving drops them:
 *  GTA's menu under the page shuts with it. */
const LEAVE_QUESTION = {
    title: 'Apply graphics changes?',
    body: 'Some graphics changes are not applied yet. Leaving drops them.',
    buttons: ['Apply', 'Discard', 'Stay'],
    own: true,
};
