// pfm-ui theme.js: the server theme loader every PF page can include.
// Copyright (c) 2026 Whippy, from WHIP, LGPL-3.0; modified for PF (see the pfm-ui resource's NOTICE.md).
// Ported from WHIP's html/js/theme.js.
//
//   <script src="https://cfx-nui-pfm-ui/html/theme.js"></script>
//
// A THEME IS A SEPARATE RESOURCE that ships a theme.css redeclaring tokens from pfm-ui's tokens.css
// (and nothing else). The server names it with a replicated convar:
//
//     setr pf_ui_theme "my_theme"          (server.cfg; empty or unset = the base look)
//
// This file asks pfm-ui for that name (pfm-ui's client/theme.lua answers the 'theme' NUI callback with
// the convar), then appends <link href="https://cfx-nui-<name>/theme.css"> LAST in <head>, so at equal
// specificity the theme's tokens win everywhere. That one link is the whole skin system.
//
// FAILS SOFT AND QUIET: no answer (pfm-ui stopped, an old pfm-ui, a page outside FiveM), an empty name, a
// refused name or a theme.css that will not load all leave the page on its base look; nothing throws.
// A page can also be told directly: SendNUIMessage({ action = 'pf-ui:theme', resource = 'my_theme' })
// (resource = false clears it), or from script: window.PfUiTheme.apply('my_theme').
(function () {
    "use strict";
    if (window.PfUiTheme) return; // loaded twice: the first copy already runs

    var LINK_ID = "pf-ui-theme";
    // A RESOURCE NAME, NOTHING ELSE: it is concatenated into a stylesheet URL, and a value carrying
    // '.', '/', ':' or '#' would point the page at a host of the sender's choosing.
    var RESOURCE_NAME = /^[A-Za-z0-9_-]{1,64}$/;
    var current = null;

    function clear() {
        var existing = document.getElementById(LINK_ID);
        if (existing && existing.parentNode) existing.parentNode.removeChild(existing);
        current = null;
    }

    function apply(name) {
        if (!name) { clear(); return false; }
        if (typeof name !== "string" || !RESOURCE_NAME.test(name)) {
            console.warn("[pfm-ui:theme] ignoring theme name: not a plain resource name");
            clear();
            return false;
        }
        if (name === current && document.getElementById(LINK_ID)) return true;
        clear();
        var link = document.createElement("link");
        link.id = LINK_ID;
        link.rel = "stylesheet";
        link.href = "https://cfx-nui-" + name + "/theme.css";
        link.onerror = function () {
            // stopped, misnamed, or theme.css missing from its files{}: back to the base look
            if (link.parentNode) link.parentNode.removeChild(link);
            if (current === name) current = null;
        };
        current = name;
        (document.head || document.documentElement).appendChild(link);
        return true;
    }

    // Kept last in <head> even when a page adds stylesheets later (pf-devices loads app styles on demand).
    function keepLast() {
        var link = document.getElementById(LINK_ID);
        var head = document.head;
        if (link && head && link.parentNode === head && head.lastElementChild !== link) head.appendChild(link);
    }

    function ask() {
        if (typeof fetch !== "function") return;
        var req;
        try {
            req = fetch("https://pfm-ui/theme", {
                method: "POST",
                headers: { "Content-Type": "application/json; charset=UTF-8" },
                body: "{}",
            });
        } catch (e) { return; }
        if (!req || typeof req.then !== "function") return;
        req.then(function (r) { return r && r.ok ? r.json() : null; })
            .then(function (d) { if (d && d.resource) apply(d.resource); })
            .catch(function () { /* no pfm-ui: base look */ });
    }

    window.addEventListener("message", function (e) {
        var d = e && e.data;
        if (!d || d.action !== "pf-ui:theme") return;
        apply(d.resource || null);
    });

    window.PfUiTheme = { apply: apply, clear: clear, current: function () { return current; } };

    if (typeof MutationObserver === "function" && document.head) {
        new MutationObserver(keepLast).observe(document.head, { childList: true });
    }
    ask();
})();
