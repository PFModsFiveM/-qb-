// Copyright (c) 2026 Whippy, from WHIP, LGPL-3.0; modified for PF.
// ========================================
// LOGO LIGHT — the brand mark with its loading light
//
// The light is the original's: a set of circles light one at a time, each at once and with a random
// interaction icon on it (js/glyphs.js: the actions only, NOT_LIT), and fade as the light moves on.
//
// PF: the original logo's shape and name are not used. brandMarkup draws our own mark in its place, at
// the same size: the brand (Config.Pause.Brand, "PF" by default) as a wordmark, beside a two-by-two
// square of circles that the light goes round. logoLight below is the original's light, unchanged.
// Styled by pause.css: .ld-letters, .ld-ring, .ld-disc, .ld-hole, .ld-icon, and .ld-dot.lit.
// ========================================

/** How long each circle stays lit before the next takes over — the loading screen's pace. */
const STEP_MS = 450;

/** How wide an icon is against its disc: the 3D badge's share. The car slices fill the disc. */
const ICON_SHARE = 0.46 / 0.78;

const shared = window.PfGlyphs || { glyphs: {}, fullBleed: {} };

/** The marks that are not actions: a menu arrow (`back`), an objective card's (a tick or a cross lit
 *  over a load would read as a verdict on it), the notifications', and the dev tools' own. */
const NOT_LIT = new Set(['back', 'objective', 'target', 'pin', 'star', 'timer',
    'fail', 'success', 'info', 'warning', 'object', 'ped', 'camera']);
const names = Object.keys(shared.glyphs).filter((n) => !NOT_LIT.has(n));

/** The brand mark's markup: the wordmark and the four circles, in the original logo's box (997 x 235), with
 *  clip ids under `prefix`, so two copies on one page do not share them. `brand` is plain text (escaped here). */
export function brandMarkup(prefix, brand) {
    const text = String(brand == null || brand === '' ? 'PF' : brand).slice(0, 24)
        .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
    const circle = (cx, cy) => '<circle cx="' + cx + '" cy="' + cy + '" r="20.5"/>';
    const light = (cx, cy, clip) => '<g class="ld-light"><circle class="ld-ring" cx="' + cx + '" cy="' + cy + '" r="26.5"/>'
        + '<circle class="ld-disc" cx="' + cx + '" cy="' + cy + '" r="20.5"/>'
        + '<g class="ld-icon" clip-path="url(#' + prefix + '-' + clip + ')"></g></g>';
    // The light goes round the square: top left, top right, bottom right, bottom left.
    const DOTS = [[136, 124], [216, 124], [216, 204], [136, 204]];
    const dot = ([cx, cy], i) => '<g class="ld-dot"><circle class="ld-hole" cx="' + cx + '" cy="' + cy + '" r="20"/>' + light(cx, cy, i) + '</g>';
    return '<svg viewBox="58 46 997 235" xmlns="http://www.w3.org/2000/svg"><defs>'
        + DOTS.map(([cx, cy], i) => '<clipPath id="' + prefix + '-' + i + '">' + circle(cx, cy) + '</clipPath>').join('')
        + '</defs>'
        + '<rect class="ld-letters" x="62" y="50" width="228" height="228" rx="60"/>'
        + '<text class="ld-letters ld-word" x="322" y="277" font-size="322">' + text + '</text>'
        + DOTS.map(dot).join('')
        + '</svg>';
}

/** A wordmark wider than the box is squeezed to fit (measured once it is on the page). */
function fitWord(root) {
    const t = root && root.querySelector('.ld-word');
    if (!t || typeof t.getComputedTextLength !== 'function') return;
    try {
        t.removeAttribute('textLength');
        if (t.getComputedTextLength() > 725) {
            t.setAttribute('textLength', '725');
            t.setAttribute('lengthAdjust', 'spacingAndGlyphs');
        }
    } catch (e) { /* not laid out yet */ }
}

/** The light on a logo inside `root`: { start, stop }. Paints the fixed W and P icons at once. */
export function logoLight(root) {
    const dots = root ? Array.from(root.querySelectorAll('.ld-dot')) : [];
    let bag = [], last = null, timer = null, at = -1;

    function shuffle(list) {
        for (let i = list.length - 1; i > 0; i--) {
            const j = Math.floor(Math.random() * (i + 1));
            const t = list[i]; list[i] = list[j]; list[j] = t;
        }
        return list;
    }

    /** A random icon: shuffled in rounds, never the same one twice running. */
    function nextIcon() {
        if (!names.length) return null;
        if (!bag.length) {
            bag = shuffle(names.slice());
            // The round is dealt from the end: do not start it with the one just shown.
            if (bag.length > 1 && bag[bag.length - 1] === last) {
                const t = bag[0]; bag[0] = bag[bag.length - 1]; bag[bag.length - 1] = t;
            }
        }
        last = bag.pop();
        return last;
    }

    /** Put an icon on a circle's disc, sized in the logo's own coordinates. */
    function paint(group, name) {
        const slot = group.querySelector('.ld-icon');
        const disc = group.querySelector('.ld-disc');
        if (!slot || !disc) return;
        if (!name || !shared.glyphs[name]) { slot.innerHTML = ''; return; }
        const cx = +disc.getAttribute('cx'), cy = +disc.getAttribute('cy'), r = +disc.getAttribute('r');
        const size = shared.fullBleed[name] ? r * 2 : r * 2 * ICON_SHARE;
        slot.innerHTML = shared.glyphs[name];
        const svg = slot.firstElementChild;
        if (!svg) return;
        svg.setAttribute('x', cx - size / 2);
        svg.setAttribute('y', cy - size / 2);
        svg.setAttribute('width', size);
        svg.setAttribute('height', size);
    }

    if (root) root.querySelectorAll('[data-icon]').forEach((g) => paint(g, g.getAttribute('data-icon')));

    function step() {
        if (at >= 0) dots[at].classList.remove('lit');   // fades (the page's CSS), its icon with it
        at = (at + 1) % dots.length;
        paint(dots[at], nextIcon());
        dots[at].classList.add('lit');                   // lights at once
    }

    return {
        fit() { fitWord(root); },
        start() {
            fitWord(root);
            if (timer || !dots.length) return;
            at = -1;
            step();
            timer = setInterval(step, STEP_MS);
        },
        stop() {
            if (timer) clearInterval(timer);
            timer = null;
            dots.forEach((d) => d.classList.remove('lit'));
            at = -1;
        },
    };
}
