// Copyright (c) 2026 Whippy, from WHIP, LGPL-3.0; modified for PF.
// ========================================
// PAD GLYPHS — the controller's button pictures (img/pad/*.svg, made by dev/pad_glyphs.js)
//
// The names a hint may use, and how one becomes its picture. Shared by the menus' hint strip
// (controller.js) and the bottom text band's {pad:a} markers (ui.js), so both know one list.
// ========================================

/** Every button there is a picture of. A name not here is never turned into an <img>. */
export const PAD_GLYPHS = new Set([
    'a', 'b', 'x', 'y', 'lb', 'rb', 'lt', 'rt', 'ls', 'rs', 'l3', 'r3',
    'dpad', 'dpad_up', 'dpad_down', 'dpad_left', 'dpad_right', 'view', 'menu',
]);

/** That button's picture as an element, or null if it has none. */
export function padGlyph(name, className) {
    if (!PAD_GLYPHS.has(name)) return null;
    const img = document.createElement('img');
    img.src = 'img/pad/' + name + '.svg';
    img.alt = name.toUpperCase();
    img.className = className;
    img.draggable = false;
    return img;
}

/** ALREADY-ESCAPED text with each {pad:a} marker swapped for its picture. Lua writes the markers
 *  (a Lua-written hint). Escape first, then this: only a known name becomes
 *  markup, so nothing else in the text — a player's name — can. */
export function withPadGlyphs(escaped, className) {
    return escaped.replace(/\{pad:([a-z0-9_]+)\}/g, (marker, name) => (PAD_GLYPHS.has(name)
        ? '<img class="' + className + '" src="img/pad/' + name + '.svg" alt="' + name.toUpperCase() + '">'
        : marker));
}
