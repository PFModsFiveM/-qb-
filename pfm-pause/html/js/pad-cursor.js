// Copyright (c) 2026 Whippy, from WHIP, LGPL-3.0; modified for PF.
// ========================================
// SCREEN RECTS — from the original's pad-cursor.js: only screenRect, which the map and the Settings page's
// sliders measure with (the controller cursor itself is not part of the pause menu).
// ========================================

// THE CEF 103 LESSON: inside a CSS-zoomed box getBoundingClientRect can come back UNZOOMED in FiveM. A 100px
// probe in the box says which: about 100 × zoom wide means screen pixels, about 100 means unzoomed. Measured
// once per box.
const zoomFix = new WeakMap();

function rectScale(node) {
    let k = 1, host = null;
    for (let n = node; n && n !== document.documentElement; n = n.parentElement) {
        const z = parseFloat(getComputedStyle(n).zoom);
        if (z > 0 && Math.abs(z - 1) > 0.001) { k *= z; if (!host) host = n; }
    }
    if (!host || Math.abs(k - 1) < 0.01) return 1;
    if (zoomFix.has(host)) return zoomFix.get(host);
    const probe = document.createElement('div');
    probe.style.cssText = 'position:absolute;left:0;top:0;width:100px;height:1px;visibility:hidden;pointer-events:none';
    host.appendChild(probe);
    const w = probe.getBoundingClientRect().width;
    probe.remove();
    const fix = Math.abs(w - 100 * k) < Math.abs(w - 100) ? 1 : k;
    zoomFix.set(host, fix);
    return fix;
}

/** A node's box in screen pixels, whatever CEF 103 measured it in. Shared: the Settings page's sliders
 *  (settings-page.js) are inside a zoomed box too. */
export function screenRect(node) {
    const r = node.getBoundingClientRect(), k = rectScale(node);
    return { left: r.left * k, right: r.right * k, top: r.top * k, bottom: r.bottom * k,
             width: r.width * k, height: r.height * k };
}
