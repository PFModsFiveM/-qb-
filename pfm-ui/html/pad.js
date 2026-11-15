/* pfm-ui pad.js: controller support for a NUI page.
 *
 * Copyright (c) 2026 Whippy, from WHIP, LGPL-3.0; modified for PF.
 * Port of whip_core html/js/controller.js and router.js (intent routing). Free software under the
 * GNU Lesser General Public License 3.0 (see COPYING.LESSER and COPYING in the pfm-ui resource).
 *
 * Load it with <script src="https://cfx-nui-pfm-ui/html/pad.js"></script>. The resource's Lua side
 * (pfm-ui/lib/pad_bridge.lua) posts { action: 'pfm-ui:pad', intent, repeat, held } and
 * { action: 'pfm-ui:device', pad }. Intents: up down left right select back buttonX buttonY
 * tabPrev tabNext triggerLeft triggerRight. A page that does nothing with them stays keyboard-only.
 *
 *   PfmPad.on('select', fn)            fn(detail) handles it; return false to fall through to the default
 *   PfmPad.focusables(el, { onBack })  default navigation: a focus ring moves among controls in el
 *   PfmPad.glyph('select')             a button picture (span with inline svg)
 *   body.pfm-pad                       set while a pad is the device
 */
(function (root) {
    "use strict";
    if (root.PfmPad) return;
    const doc = root.document;

    const handlers = new Map();
    const deviceListeners = [];
    let active = false;
    let nav = null;
    let current = null;

    const DEFAULT_SELECTOR =
        "[data-pad], button, input:not([type=hidden]), select, textarea, a[href], [tabindex]:not([tabindex='-1'])";
    const TEXT_TYPES = ["text", "password", "email", "search", "tel", "url", "number"];

    /* ---- device ---- */

    function applyClass() {
        if (doc.body) doc.body.classList.toggle("pfm-pad", active);
    }

    function setActive(on) {
        on = !!on;
        if (on === active) return;
        active = on;
        applyClass();
        for (const fn of deviceListeners.slice()) {
            try { fn(active); } catch (err) { console.error("[pfm-ui] device listener threw:", err); }
        }
    }

    if (doc.readyState === "loading") doc.addEventListener("DOMContentLoaded", applyClass);

    /* ---- elements ---- */

    function isVisible(el) {
        if (!el || !el.isConnected) return false;
        const win = doc.defaultView || root;
        for (let n = el; n && n.nodeType === 1; n = n.parentElement) {
            if (n.hidden) return false;
            const cs = win.getComputedStyle(n);
            if (cs.display === "none") return false;
            if (n === el && cs.visibility === "hidden") return false;
        }
        return true;
    }

    function isDisabled(el) {
        if (el.disabled) return true;
        if (el.getAttribute("aria-disabled") === "true") return true;
        if (el.closest("[data-pad='off']")) return true;
        if (el.classList.contains("disabled")) return true;
        return false;
    }

    function isTextField(el) {
        if (!el) return false;
        if (el.tagName === "TEXTAREA") return true;
        return el.tagName === "INPUT" && TEXT_TYPES.indexOf((el.type || "text").toLowerCase()) >= 0;
    }

    function candidates() {
        if (!nav || !nav.container || !nav.container.isConnected) return [];
        return Array.from(nav.container.querySelectorAll(nav.selector)).filter((el) => isVisible(el) && !isDisabled(el));
    }

    function centre(el) {
        const r = el.getBoundingClientRect();
        return { x: r.left + r.width / 2, y: r.top + r.height / 2, w: r.width, h: r.height };
    }

    /** The element of `list` nearest `from` in direction `dir`; DOM order when there is no layout. */
    function spatial(from, list, dir) {
        if (!list || !list.length) return null;
        if (!from || list.indexOf(from) < 0) return list[0];
        const noLayout = list.every((el) => {
            const r = el.getBoundingClientRect();
            return r.width === 0 && r.height === 0;
        });
        if (noLayout) {
            const step = dir === "up" || dir === "left" ? -1 : 1;
            return list[list.indexOf(from) + step] || null;
        }
        const a = centre(from);
        let best = null;
        let bestScore = Infinity;
        for (const el of list) {
            if (el === from) continue;
            const b = centre(el);
            const dx = b.x - a.x;
            const dy = b.y - a.y;
            let main, cross;
            if (dir === "up") { main = -dy; cross = Math.abs(dx); }
            else if (dir === "down") { main = dy; cross = Math.abs(dx); }
            else if (dir === "left") { main = -dx; cross = Math.abs(dy); }
            else { main = dx; cross = Math.abs(dy); }
            if (main <= 1) continue;
            const score = main + cross * 2;
            if (score < bestScore) { bestScore = score; best = el; }
        }
        return best;
    }

    function fire(el, type) {
        el.dispatchEvent(new (doc.defaultView || root).Event(type, { bubbles: true }));
    }

    /** Left/right on a number, range or select list changes its value. Answers whether it did. */
    function adjust(el, delta) {
        if (!el) return false;
        if (el.tagName === "SELECT") {
            const n = el.options.length;
            if (!n) return false;
            const i = Math.max(0, Math.min(n - 1, el.selectedIndex + delta));
            if (i !== el.selectedIndex) {
                el.selectedIndex = i;
                fire(el, "input");
                fire(el, "change");
            }
            return true;
        }
        if (el.tagName === "INPUT" && (el.type === "number" || el.type === "range")) {
            const step = parseFloat(el.step) || 1;
            let v = parseFloat(el.value);
            if (isNaN(v)) v = parseFloat(el.min);
            if (isNaN(v)) v = 0;
            v += delta * step;
            const min = parseFloat(el.min);
            const max = parseFloat(el.max);
            if (!isNaN(min)) v = Math.max(min, v);
            if (!isNaN(max)) v = Math.min(max, v);
            el.value = String(Math.round(v * 1e6) / 1e6);
            fire(el, "input");
            fire(el, "change");
            return true;
        }
        return false;
    }

    function focus(el) {
        if (current && current !== el) current.classList.remove("pfm-pad-focus");
        current = el || null;
        if (!current) return;
        current.classList.add("pfm-pad-focus");
        const ae = doc.activeElement;
        if (ae && ae !== current && isTextField(ae)) ae.blur();
        if (typeof current.scrollIntoView === "function") {
            try { current.scrollIntoView({ block: "nearest", inline: "nearest" }); } catch (e) { /* old engines */ }
        }
        if (nav && typeof nav.onFocus === "function") nav.onFocus(current);
    }

    /** A: a text field takes the keyboard's focus, anything else is clicked (a checkbox toggles). */
    function activate(el) {
        if (!el) return false;
        if (isTextField(el)) { el.focus(); return true; }
        if (el.tagName === "SELECT") { el.focus(); return true; }
        el.click();
        return true;
    }

    function escapeFallback() {
        const Win = doc.defaultView || root;
        for (const type of ["keydown", "keyup"]) {
            doc.dispatchEvent(new Win.KeyboardEvent(type, { key: "Escape", code: "Escape", bubbles: true }));
        }
        return true;
    }

    function move(dir) {
        const list = candidates();
        if (!list.length) return false;
        const from = current && list.indexOf(current) >= 0 ? current : null;
        if ((dir === "left" || dir === "right") && from && nav.adjust !== false && adjust(from, dir === "left" ? -1 : 1)) {
            return true;
        }
        let next;
        if (!from) next = list[0];
        else if (nav.mode === "list" && (dir === "up" || dir === "down")) next = list[list.indexOf(from) + (dir === "up" ? -1 : 1)] || null;
        else if (nav.mode === "list") next = null;
        else next = spatial(from, list, dir);
        if (!next && nav.wrap && from && (nav.mode !== "list" || dir === "up" || dir === "down")) {
            next = dir === "up" || dir === "left" ? list[list.length - 1] : list[0];
        }
        if (next) focus(next);
        return true;
    }

    function defaultNav(intent) {
        if (!nav) return intent === "back" ? escapeFallback() : false;
        switch (intent) {
            case "up":
            case "down":
            case "left":
            case "right":
                return move(intent);
            case "select": {
                const list = candidates();
                if (!current || list.indexOf(current) < 0) {
                    if (list.length) focus(list[0]);
                    return true;
                }
                return activate(current);
            }
            case "back":
                if (typeof nav.onBack === "function") { nav.onBack(); return true; }
                return escapeFallback();
            default:
                return false;
        }
    }

    /** Run one intent: the page's handlers (newest first), then the default navigation. */
    function handle(intent, detail) {
        setActive(true);
        const list = handlers.get(intent) || [];
        for (let i = list.length - 1; i >= 0; i--) {
            try {
                if (list[i](detail || {}) !== false) return true;
            } catch (err) {
                console.error(`[pfm-ui] handler for "${intent}" threw:`, err);
                return true;
            }
        }
        return defaultNav(intent);
    }

    /* ---- glyphs: simple generic drawings, coloured by CSS (currentColor) ---- */

    const ALIAS = {
        select: "a", back: "b", buttonX: "x", buttonY: "y", tabPrev: "lb", tabNext: "rb",
        triggerLeft: "lt", triggerRight: "rt", up: "dpad_up", down: "dpad_down", left: "dpad_left", right: "dpad_right",
    };

    function face(letter) {
        return `<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="10.5" fill="var(--pfm-glyph-bg, rgba(0,0,0,.55))" stroke="currentColor" stroke-opacity=".6" stroke-width="1.2"/><text x="12" y="16.3" text-anchor="middle" font-family="Arial, Helvetica, sans-serif" font-size="12" font-weight="700" fill="currentColor">${letter}</text></svg>`;
    }
    function bumper(label, trigger) {
        const shape = trigger
            ? '<path d="M5 21V9a6 6 0 0 1 6-6h10a6 6 0 0 1 6 6v12z"'
            : '<rect x="2" y="6" width="28" height="13" rx="6.5"';
        return `<svg viewBox="0 0 32 24" aria-hidden="true">${shape} fill="var(--pfm-glyph-bg, rgba(0,0,0,.55))" stroke="currentColor" stroke-opacity=".6" stroke-width="1.2"/><text x="16" y="${trigger ? 16.5 : 16.2}" text-anchor="middle" font-family="Arial, Helvetica, sans-serif" font-size="9.5" font-weight="700" fill="currentColor">${label}</text></svg>`;
    }
    function dpad(dir) {
        const arms = { up: 0, right: 90, down: 180, left: 270 };
        let lit = "";
        if (dir) lit = `<path d="M9.5 2.5h5v7h-5z" fill="currentColor" transform="rotate(${arms[dir]} 12 12)"/>`;
        return `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 2h6v7h7v6h-7v7H9v-7H2V9h7z" fill="var(--pfm-glyph-bg, rgba(0,0,0,.55))" stroke="currentColor" stroke-opacity=".6" stroke-width="1.2" stroke-linejoin="round"/>${lit}</svg>`;
    }

    const DRAW = {
        a: () => face("A"), b: () => face("B"), x: () => face("X"), y: () => face("Y"),
        lb: () => bumper("LB"), rb: () => bumper("RB"), lt: () => bumper("LT", true), rt: () => bumper("RT", true),
        dpad: () => dpad(null), dpad_up: () => dpad("up"), dpad_down: () => dpad("down"),
        dpad_left: () => dpad("left"), dpad_right: () => dpad("right"),
    };

    function glyphName(name) {
        const n = ALIAS[name] || name;
        return DRAW[n] ? n : null;
    }

    function glyphHTML(name) {
        const n = glyphName(name);
        if (!n) return "";
        return `<span class="pfm-pad-glyph pfm-pad-glyph-${n}" role="img" aria-label="${n.toUpperCase()}">${DRAW[n]()}</span>`;
    }

    function glyph(name) {
        const html = glyphHTML(name);
        if (!html) return null;
        const wrap = doc.createElement("span");
        wrap.innerHTML = html;
        return wrap.firstElementChild;
    }

    /** Fill `container` with button hints: [['select', 'Choose'], ['back', 'Close']]. */
    function hints(container, list) {
        if (!container) return;
        container.classList.add("pfm-pad-hints");
        container.textContent = "";
        for (const [button, label] of list || []) {
            const item = doc.createElement("span");
            item.className = "pfm-pad-hint";
            for (const b of Array.isArray(button) ? button : [button]) {
                const g = glyph(b);
                if (g) item.appendChild(g);
            }
            item.appendChild(doc.createTextNode(label));
            container.appendChild(item);
        }
    }

    /* ---- inbound ---- */

    root.addEventListener("message", (event) => {
        const d = event.data;
        if (!d || typeof d !== "object") return;
        if (d.action === "pfm-ui:pad" && typeof d.intent === "string") {
            handle(d.intent, { repeat: d.repeat === true, held: +d.held || 0 });
        } else if (d.action === "pfm-ui:device") {
            setActive(d.pad === true);
        }
    });

    root.PfmPad = {
        on(intent, fn) {
            if (typeof fn !== "function") return () => {};
            let list = handlers.get(intent);
            if (!list) { list = []; handlers.set(intent, list); }
            list.push(fn);
            return () => {
                const i = list.indexOf(fn);
                if (i >= 0) list.splice(i, 1);
            };
        },
        off(intent, fn) {
            const list = handlers.get(intent);
            if (!list) return;
            const i = list.indexOf(fn);
            if (i >= 0) list.splice(i, 1);
        },
        /** Default navigation inside `container`. opts: selector, mode ('list'), wrap, adjust (false),
         *  onBack, onFocus, autoFocus (focus the first control now when a pad is active). */
        focusables(container, opts) {
            opts = opts || {};
            if (current) current.classList.remove("pfm-pad-focus");
            current = null;
            nav = container
                ? {
                      container,
                      selector: opts.selector || DEFAULT_SELECTOR,
                      mode: opts.mode || "spatial",
                      wrap: !!opts.wrap,
                      adjust: opts.adjust,
                      onBack: opts.onBack,
                      onFocus: opts.onFocus,
                  }
                : null;
            if (nav && opts.autoFocus && active) {
                const list = candidates();
                if (list.length) focus(list[0]);
            }
        },
        clear() {
            if (current) current.classList.remove("pfm-pad-focus");
            current = null;
            nav = null;
        },
        current: () => (current && current.isConnected ? current : null),
        focus,
        move,
        spatial,
        adjust,
        glyph,
        glyphHTML,
        hints,
        isActive: () => active,
        setActive,
        onDevice(fn) {
            if (typeof fn === "function") deviceListeners.push(fn);
        },
        handle,
    };
})(window);
