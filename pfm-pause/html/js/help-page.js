// PF's own: the pause menu's Help page (not part of the original menu). Drawn in the ported Settings page's look
// (settings-page.css: the head, the rail of tabs, the rows and the inspector), so it sits beside Server Settings
// as one of its kind. Uses js/utils.js and js/pad-glyphs.js (Copyright (c) 2026 Whippy, from WHIP, LGPL-3.0;
// modified for PF).
//
// Tabs: Rules (Config.Pause.Rules), Keys (Config.Pause.Keybinds: keyboard and controller), Shortcuts (the quick
// actions: Config.Pause.QuickActions and AddQuickAction), and Report a problem (pfm-adminmenu's /report, through
// client/main.lua, which cleans the text and keeps the cooldown).
//
// Keyboard, mouse and pad as on the Settings page: up / down choose a row, Enter or A does a row that does
// something, Q / E or LB / RB the tabs, Esc or B back to the menu. While the report box has the keyboard, only Esc
// is the page's (it leaves the box).

import { nuiCallback, escapeHtml } from './utils.js';
import { padGlyph } from './pad-glyphs.js';
import { NuiRouter } from './router.js';

const ICON = {
    left: '<path d="M15 5l-7 7 7 7"/>',
    right: '<path d="M9 5l7 7-7 7"/>',
    rules: '<path d="M6 4h9l3 3v13H6z"/><path d="M9 10h6M9 14h6"/>',
    keys: '<rect x="3" y="6" width="18" height="12" rx="2"/><path d="M7 10h1M11 10h1M15 10h2M7 14h10"/>',
    quick: '<path d="M13 3L5 14h6l-1 7 8-11h-6z"/>',
    report: '<path d="M5 21V4M5 4h11l-2 4 2 4H5"/>',
};
const icon = (name, cls = 'st-ico') => `<svg class="${cls}" viewBox="0 0 24 24" aria-hidden="true">${ICON[name] || ''}</svg>`;

/** Pad names in the key list (Config.Pause.Keybinds) to glyph names. "LB (hold)" and "LB + Y" work. */
const PAD_NAME = {
    a: 'a', b: 'b', x: 'x', y: 'y', lb: 'lb', rb: 'rb', lt: 'lt', rt: 'rt', start: 'menu', menu: 'menu', back: 'view',
    view: 'view', ls: 'ls', rs: 'rs', l3: 'l3', r3: 'r3', 'd-up': 'dpad_up', 'd-down': 'dpad_down',
    'd-left': 'dpad_left', 'd-right': 'dpad_right', dpad: 'dpad',
};

function padHtml(text) {
    if (!text) return '';
    const parts = String(text).split('+').map((p) => p.trim());
    let out = '';
    for (const p of parts) {
        const m = /^([A-Za-z0-9-]+)(.*)$/.exec(p);
        const g = m && PAD_NAME[m[1].toLowerCase()];
        const img = g ? padGlyph(g, 'hp-glyph') : null;
        out += img ? img.outerHTML + (m[2] ? `<span>${escapeHtml(m[2].trim())}</span>` : '') : `<span>${escapeHtml(p)}</span>`;
    }
    return `<span class="hp-pad">${out}</span>`;
}

export class HelpPage {
    /** @param {HTMLElement} root  the pause menu's root; @param {() => void} onBack  back to its menu;
     *  @param {(id: string) => void} onQuick  a shortcut chosen (pause.js asks Lua) */
    constructor(root, onBack, onQuick) {
        this.onBack = onBack;
        this.onQuick = onQuick;
        this.isOpen = false;
        this.data = { rules: [], keybinds: [], quick: [], report: false };
        this.tabKey = 'rules';
        this.sel = 0;
        this.result = null;          // the last report's answer: { ok, text }
        this.sending = false;

        const wrap = document.createElement('section');
        wrap.className = 'pm-help';
        wrap.innerHTML = `
            <div class="st-z">
                <header class="st-head"></header>
                <div class="st-body">
                    <nav class="st-rail" aria-label="Help tabs"></nav>
                    <section class="st-list" aria-label="Help">
                        <div class="st-scroll"><div class="st-rows"></div></div>
                    </section>
                    <aside class="st-insp"></aside>
                </div>
            </div>`;
        root.appendChild(wrap);
        this.wrap = wrap;
        this.headEl = wrap.querySelector('.st-head');
        this.railEl = wrap.querySelector('.st-rail');
        this.scrollEl = wrap.querySelector('.st-scroll');
        this.rowsEl = wrap.querySelector('.st-rows');
        this.inspEl = wrap.querySelector('.st-insp');

        this.headEl.addEventListener('click', (e) => { if (e.target.closest('[data-act="back"]')) this.onBack(); });
        this.railEl.addEventListener('click', (e) => {
            const b = e.target.closest('[data-tab]');
            if (b) this.setTab(b.dataset.tab);
        });
        this.rowsEl.addEventListener('mousemove', (e) => {
            const r = e.target.closest('.st-row');
            if (!r) return;
            const i = Number(r.dataset.i);
            if (i !== this.sel) { this.sel = i; this.draw(); }
        });
        this.rowsEl.addEventListener('click', (e) => {
            const r = e.target.closest('.st-row');
            if (!r) return;
            this.sel = Number(r.dataset.i);
            this.press();
        });
        this.inspEl.addEventListener('click', (e) => {
            const b = e.target.closest('button');
            if (!b) return;
            if (b.dataset.act === 'send') this.send();
            else if (b.dataset.act === 'quick') this.press();
        });
        this.inspEl.addEventListener('input', (e) => {
            if (e.target.classList.contains('hp-text')) this.drawCount();
        });
    }

    // ---- open and close ----

    /** @param {{ rules?: string[], keybinds?: string[][], quick?: object[], report?: false|{min,max} }} data */
    open(data, tab) {
        this.isOpen = true;
        this.data = {
            rules: Array.isArray(data && data.rules) ? data.rules : [],
            keybinds: Array.isArray(data && data.keybinds) ? data.keybinds : [],
            quick: Array.isArray(data && data.quick) ? data.quick : [],
            report: data && data.report ? data.report : false,
        };
        this.result = null;
        const tabs = this.tabs();
        if (tab && tabs.some((t) => t.key === tab)) this.tabKey = tab;
        if (!tabs.some((t) => t.key === this.tabKey)) this.tabKey = tabs.length ? tabs[0].key : null;
        this.sel = 0;
        this.draw();
    }

    close() {
        if (!this.isOpen) return;
        this.isOpen = false;
        const box = this.box();
        if (box) box.blur();
    }

    // ---- what is shown ----

    tabs() {
        const t = [];
        if (this.data.rules.length) t.push({ key: 'rules', label: 'Rules', icon: 'rules' });
        if (this.data.keybinds.length) t.push({ key: 'keys', label: 'Keys', icon: 'keys' });
        if (this.data.quick.length) t.push({ key: 'quick', label: 'Shortcuts', icon: 'quick' });
        if (this.data.report) t.push({ key: 'report', label: 'Report a problem', icon: 'report' });
        return t;
    }

    rows() {
        if (this.tabKey === 'rules') return this.data.rules.map((r, i) => ({ kind: 'rule', n: i + 1, label: String(r) }));
        if (this.tabKey === 'keys') return this.data.keybinds.map((k) => ({ kind: 'key', label: String(k[0] || ''), kb: k[1] || '', pad: k[2] || '' }));
        if (this.tabKey === 'quick') return this.data.quick.map((q) => ({ kind: 'quick', id: q.id, label: String(q.label || q.id) }));
        if (this.tabKey === 'report') return [{ kind: 'report', label: 'Write to the staff' }];
        return [];
    }

    row() { return this.rows()[this.sel] || null; }

    box() { return this.inspEl.querySelector('.hp-text'); }

    typing() { const b = this.box(); return !!b && document.activeElement === b; }

    // ---- drawing ----

    draw() {
        if (!this.isOpen) return;
        const rows = this.rows();
        if (this.sel >= rows.length) this.sel = Math.max(0, rows.length - 1);
        const cur = this.tabs().find((t) => t.key === this.tabKey);
        this.headEl.innerHTML = `<button type="button" class="st-back" data-act="back">${icon('left', 'st-back-ico')}Menu</button>`
            + '<h1 class="st-title">Help</h1>'
            + `<div class="st-crumb">${cur ? `<b>${escapeHtml(cur.label)}</b>` : ''}</div><div class="st-fill"></div>`;

        const glyphs = (g) => { const img = padGlyph(g, 'st-glyph'); return img ? img.outerHTML : ''; };
        this.railEl.innerHTML = `<div class="st-grp"><span>Help</span><span class="st-grp-pad">${glyphs('lb')}${glyphs('rb')}</span></div>`
            + '<div class="st-grpsub">This server\'s rules and keys</div>'
            + this.tabs().map((t) => `<button type="button" class="st-nav${t.key === this.tabKey ? ' on' : ''}" data-tab="${t.key}">`
                + `${icon(t.icon)}<span class="st-nav-label">${escapeHtml(t.label)}</span></button>`).join('');

        if (!rows.length) this.rowsEl.innerHTML = '<div class="st-empty"><p>Nothing here.</p></div>';
        else this.rowsEl.innerHTML = rows.map((r, i) => this.rowHtml(r, i)).join('');
        const on = this.rowsEl.querySelector('.st-row.on');
        if (on && on.scrollIntoView) on.scrollIntoView({ block: 'nearest' });

        this.drawInspector();
        NuiRouter.hintsChanged();
    }

    rowHtml(r, i) {
        const cls = 'st-row' + (i === this.sel ? ' on' : '') + (r.kind === 'rule' || r.kind === 'key' ? ' hp-wrap' : '');
        let k = `<span class="st-label">${escapeHtml(r.label)}</span>`;
        if (r.kind === 'rule') k = `<span class="hp-num">${r.n}</span>` + k;
        let v = '';
        if (r.kind === 'key') {
            v = '<span class="hp-keys">' + (r.kb ? `<span class="hp-key">${escapeHtml(r.kb)}</span>` : '') + padHtml(r.pad) + '</span>';
        } else if (r.kind === 'quick' || r.kind === 'report') {
            v = icon('right', 'st-go');
        }
        return `<div class="${cls}" data-i="${i}"><span class="st-k">${k}</span><span class="st-v">${v}</span></div>`;
    }

    drawInspector() {
        const r = this.row();
        if (!r) { this.inspEl.innerHTML = ''; return; }
        if (r.kind === 'report') {
            const rep = this.data.report || {};
            const keep = this.box();
            const text = keep ? keep.value : '';
            const res = this.result
                ? `<span class="hp-result ${this.result.ok ? 'ok' : 'bad'}">${escapeHtml(this.result.text)}</span>` : '';
            this.inspEl.innerHTML = '<div class="st-ihead"><h2 class="st-ititle">Report a problem</h2></div>'
                + '<p class="st-help">Tell the staff what happened and where. They see it straight away, and it is logged.</p>'
                + `<div class="st-control"><textarea class="hp-text" maxlength="${Number(rep.max) || 300}" placeholder="What went wrong?"></textarea>`
                + '<div class="hp-count"></div>'
                + `<div class="hp-send-row"><button type="button" class="st-btn st-pill" data-act="send"${this.sending ? ' disabled' : ''}>Send report</button>${res}</div></div>`
                + '<div class="st-foot"><span class="st-keeper">Sent with /report</span></div>';
            this.box().value = text;
            this.drawCount();
            return;
        }
        if (r.kind === 'quick') {
            this.inspEl.innerHTML = `<div class="st-ihead"><h2 class="st-ititle">${escapeHtml(r.label)}</h2></div>`
                + '<p class="st-help">Closes the menu and does this.</p>'
                + `<div class="st-control"><button type="button" class="st-btn st-pill st-act" data-act="quick">${escapeHtml(r.label)}</button></div>`;
            return;
        }
        if (r.kind === 'key') {
            this.inspEl.innerHTML = `<div class="st-ihead"><h2 class="st-ititle">${escapeHtml(r.label)}</h2></div>`
                + '<div class="st-control"><div class="hp-keys">'
                + (r.kb ? `<span class="hp-key">${escapeHtml(r.kb)}</span>` : '<span class="st-help">No key</span>')
                + padHtml(r.pad) + '</div></div>'
                + '<p class="st-help">Keys can be changed in GTA\'s Settings, under Key Bindings (FiveM).</p>';
            return;
        }
        this.inspEl.innerHTML = `<div class="st-ihead"><h2 class="st-ititle">Rule ${r.n}</h2></div>`
            + `<p class="st-help">${escapeHtml(r.label)}</p>`;
    }

    drawCount() {
        const box = this.box();
        const el = this.inspEl.querySelector('.hp-count');
        if (!box || !el) return;
        const rep = this.data.report || {};
        el.textContent = `${box.value.length} / ${Number(rep.max) || 300}`;
    }

    // ---- doing ----

    setTab(key) {
        if (!this.tabs().some((t) => t.key === key) || key === this.tabKey) return;
        this.tabKey = key;
        this.sel = 0;
        this.result = null;
        this.scrollEl.scrollTop = 0;
        this.draw();
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
        this.draw();
    }

    press() {
        const r = this.row();
        if (!r) return;
        if (r.kind === 'quick') this.onQuick(r.id);
        else if (r.kind === 'report') { const b = this.box(); if (b) b.focus(); }
    }

    async send() {
        const box = this.box();
        if (!box || this.sending) return;
        const rep = this.data.report || {};
        const msg = box.value.trim();
        if (msg.length < (Number(rep.min) || 8)) {
            this.result = { ok: false, text: `Please write at least ${Number(rep.min) || 8} characters.` };
            this.drawInspector();
            return;
        }
        this.sending = true;
        this.drawInspector();
        const r = await nuiCallback('report', { message: msg });
        this.sending = false;
        if (r && r.ok) {
            this.result = { ok: true, text: 'Sent. Thank you.' };
            const b = this.box(); if (b) b.value = '';
        } else this.result = { ok: false, text: (r && r.why) || 'Not sent.' };
        if (this.isOpen) this.drawInspector();
    }

    // ---- keys and the pad (pause.js hands them over in this mode) ----

    /** A key. Answers false when it was "back" out of the page (pause.js goes to its menu). */
    onKey(e) {
        if (e.type && e.type !== 'keydown') return true;
        const k = (e.key || '').toLowerCase();
        if (this.typing()) {
            if (k === 'escape') { this.box().blur(); return true; }
            if (k === 'enter' && (e.ctrlKey || e.metaKey)) { this.send(); return true; }
            return true;   // the box's own typing
        }
        if (k === 'arrowup' || k === 'w') return this.nav('up');
        if (k === 'arrowdown' || k === 's') return this.nav('down');
        if (k === 'enter' || k === ' ') return this.nav('select');
        if (k === 'escape' || k === 'backspace') return this.nav('back');
        if (k === 'q') return this.nav('tabPrev');
        if (k === 'e' || k === 'tab') { if (e.preventDefault) e.preventDefault(); return this.nav('tabNext'); }
        return true;
    }

    /** A pad (or key) intent. Answers false for "back" out of the page. */
    nav(n) {
        if (this.typing()) {
            if (n === 'back') { this.box().blur(); return true; }
            if (n === 'select') { this.send(); return true; }
            return true;
        }
        if (n === 'up') this.move(-1);
        else if (n === 'down') this.move(1);
        else if (n === 'select') this.press();
        else if (n === 'tabPrev') this.stepTab(-1);
        else if (n === 'tabNext') this.stepTab(1);
        else if (n === 'back') return false;
        return true;
    }

    /** The pad's hint strip. */
    hints() {
        const r = this.row();
        const h = [['dpad', 'Choose']];
        if (r && r.kind === 'quick') h.push(['a', 'Do it']);
        else if (r && r.kind === 'report') h.push(['a', this.typing() ? 'Send' : 'Write']);
        h.push(['lb', ''], ['rb', 'Tab'], ['b', 'Back']);
        return h;
    }
}
