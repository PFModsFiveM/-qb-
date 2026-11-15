/* ========================================
   GLYPHS: the icons a prompt badge can show in place of a key letter.

   Copyright (c) 2026 Whippy, from WHIP, LGPL-3.0; modified for PF.
   (A subset of WHIP's html/js/glyphs.js, renamed; the pad_* glyphs are PF's.)

   Every one is 24x24 and draws in currentColor, so it takes the colour of the disc it sits in: dark
   on the white focused disc, white on the dark info disc, and transparent on the two ring states.

   A classic script, not a module: badge.html loads it with a plain <script> tag. It only sets
   window.PfmGlyphs.
   ======================================== */

(function () {
    'use strict';

    var GLYPHS = {
        lock: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<rect x="4.5" y="10.4" width="15" height="10.1" rx="2.2" fill="currentColor" stroke="none"/>'
            + '<path d="M8.2 10.4V7.4a3.8 3.8 0 0 1 7.6 0v3"/></svg>',

        // The same body with the shackle sprung off its seat on the right.
        unlock: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<rect x="4.5" y="10.4" width="15" height="10.1" rx="2.2" fill="currentColor" stroke="none"/>'
            + '<path d="M8.2 10.4V7.4a3.8 3.8 0 0 1 7.3-1.3"/></svg>',

        // A pick going into a keyhole.
        lockpick: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<path d="M7.5 13.87A5.6 5.6 0 1 1 14.4 11.12L10.44 7.16A1.75 1.75 0 0 0 7.96 9.64'
            +     'L11.92 13.6A5.6 5.6 0 0 1 11.3 13.87L13.1 20.8H5.7Z" fill="currentColor" stroke="none"/>'
            + '<path d="M22.4 22.2 18.8 18.6" stroke-width="4.4"/>'
            + '<path d="M18.8 18.6 9.7 8.9l.5-1.2" stroke-width="1.6"/></svg>',

        // A building's door: a slab with the knob cut out, standing on its step.
        door: '<svg viewBox="0 0 24 24" fill="currentColor" stroke="currentColor" stroke-width="1"'
            + ' stroke-linejoin="round">'
            + '<path fill-rule="evenodd" d="M6.2 20.6V4.4a1.2 1.2 0 0 1 1.2-1.2h9.2a1.2 1.2 0 0 1 1.2 1.2v16.2Z'
            +     'M13.2 12.6a1.9 1.9 0 1 0 3.8 0a1.9 1.9 0 1 0-3.8 0Z"/>'
            + '<path d="M3.6 20.2h16.8v1.6H3.6Z"/></svg>',

        // Picking something up: an arrow rising off a surface.
        pickup: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<path d="M12 17.2V4.8"/>'
            + '<path d="M7.6 9.2 12 4.8l4.4 4.4"/>'
            + '<path d="M4.2 20.4h15.6"/></svg>',

        cash: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<path d="M6.4 5.4h13.4a1.4 1.4 0 0 1 1.4 1.4v8"/>'
            + '<rect x="2.8" y="8.6" width="15.4" height="10" rx="1.4"/>'
            + '<circle cx="10.5" cy="13.6" r="2.3"/></svg>',

        bag: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<path d="M8.4 7.2V5.8a3.6 3.6 0 0 1 7.2 0v1.4"/>'
            + '<rect x="4.2" y="7.2" width="15.6" height="13.6" rx="3"/>'
            + '<path d="M4.2 12.8h15.6"/><path d="M10.2 12.8v2.4h3.6v-2.4"/></svg>',

        fail: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<path d="M6.5 6.5l11 11"/><path d="M17.5 6.5l-11 11"/></svg>',
        success: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<path d="M5.6 12.6l4.3 4.2 8.5-9.3"/></svg>',
        info: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<circle cx="12" cy="6.9" r="1.75" fill="currentColor" stroke="none"/><path d="M12 11.2v6.9"/></svg>',
        warning: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<path d="M12 5.9v6.9"/><circle cx="12" cy="17.1" r="1.75" fill="currentColor" stroke="none"/></svg>',

        // A plain dot: an info prompt without its own icon.
        dot: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="3.6" fill="currentColor"/></svg>',
    };

    // ---- PAD BUTTONS (PF) ----
    // Neutral shapes, not a console maker's colours: a ring with the letter for a face button, a pill for
    // a bumper or trigger, the cross with one arm filled for the D-pad. Lua picks the button from what
    // GetControlInstructionalButton reports for the prompt's control (client/keys.lua).
    function face(letter) {
        return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9">'
            + '<circle cx="12" cy="12" r="9.2"/>'
            + '<text x="12" y="16.4" text-anchor="middle" font-family="Barlow, sans-serif" font-weight="700"'
            + ' font-size="12.5" fill="currentColor" stroke="none">' + letter + '</text></svg>';
    }
    function pill(text) {
        return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">'
            + '<rect x="1.8" y="6.6" width="20.4" height="10.8" rx="5.4"/>'
            + '<text x="12" y="15.5" text-anchor="middle" font-family="Barlow, sans-serif" font-weight="700"'
            + ' font-size="' + (text.length > 2 ? 6.6 : 8.6) + '" fill="currentColor" stroke="none">' + text + '</text></svg>';
    }
    function stick(text) {
        return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7">'
            + '<circle cx="12" cy="12" r="9.4"/><circle cx="12" cy="12" r="6.2" stroke-dasharray="2 1.6"/>'
            + '<text x="12" y="15" text-anchor="middle" font-family="Barlow, sans-serif" font-weight="700"'
            + ' font-size="8" fill="currentColor" stroke="none">' + text + '</text></svg>';
    }
    // The D-pad: four arms, the pressed one filled.
    var ARMS = {
        up: 'M9.4 2.6h5.2v6.8H9.4Z', down: 'M9.4 14.6h5.2v6.8H9.4Z',
        left: 'M2.6 9.4h6.8v5.2H2.6Z', right: 'M14.6 9.4h6.8v5.2h-6.8Z',
    };
    function dpad(which) {
        var out = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round">';
        for (var k in ARMS) {
            out += '<path d="' + ARMS[k] + '"' + (k === which ? ' fill="currentColor"' : '') + '/>';
        }
        return out + '</svg>';
    }

    GLYPHS.pad_a = face('A');
    GLYPHS.pad_b = face('B');
    GLYPHS.pad_x = face('X');
    GLYPHS.pad_y = face('Y');
    GLYPHS.pad_lb = pill('LB');
    GLYPHS.pad_rb = pill('RB');
    GLYPHS.pad_lt = pill('LT');
    GLYPHS.pad_rt = pill('RT');
    GLYPHS.pad_l3 = stick('L3');
    GLYPHS.pad_r3 = stick('R3');
    GLYPHS.pad_start = pill('MENU');
    GLYPHS.pad_back = pill('VIEW');
    GLYPHS.pad_up = dpad('up');
    GLYPHS.pad_down = dpad('down');
    GLYPHS.pad_left = dpad('left');
    GLYPHS.pad_right = dpad('right');

    // Pad glyphs fill more of the disc than an icon: they ARE the key.
    var LARGE = {};
    for (var g in GLYPHS) { if (g.indexOf('pad_') === 0) LARGE[g] = true; }

    window.PfmGlyphs = { glyphs: GLYPHS, large: LARGE };
})();
