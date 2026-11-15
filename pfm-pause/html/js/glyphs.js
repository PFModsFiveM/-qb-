/* Copyright (c) 2026 Whippy, from WHIP, LGPL-3.0; modified for PF.
   ========================================
   GLYPHS — the interaction icons, in one place (the turbocharger is Material Design Icons
   `car-turbocharger`, Apache 2.0; see NOTICE.md)

   Every one is 24x24 and draws in currentColor, so it takes the colour of whatever it sits in. In the
   pause menu the logo's light shows a random action on each circle it lights (js/logo-light.js).

   A CLASSIC SCRIPT, NOT A MODULE: it only sets window.PfGlyphs. (It still parses as a module.)
   ======================================== */

(function () {
    'use strict';

    // ICONS, NOT JUST KEY LETTERS.
    //
    // A column of this atlas is "whatever goes in the middle of the disc", and for almost
    // everything that is the key you press. Doors are the exception: the useful thing to show is
    // the STATE — a closed padlock when it is locked, an open one when it is not — because the
    // key is always E and knowing that tells you nothing you did not already know.
    //
    // Drawn with currentColor throughout, so they inherit the disc's colour exactly as the letter
    // does: dark on the white focused disc, and transparent on the two ring states, which is what
    // keeps the key hidden until it is actually the one E would act on.
    /** The parts every car-slice glyph shares: a road, a wheel, and the arch over it.
     *
     * FACTORED OUT BECAUSE THE FOUR DIFFER ONLY IN THE PANEL. Hood and boot, open and shut, are
     * the same drawing with one line moved — and four hand-copied wheels would drift apart the
     * first time one of them was nudged.
     *
     * `wx` is where the wheel sits: the front one for the hood pair, the rear one for the boot
     * pair. The sill segments in each body path are cut to meet the arch at wx +/- 3.8.
     */
    function carGlyph(body, wx) {
        return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.3"'
             + ' stroke-linecap="round" stroke-linejoin="round">'
             // The road, faint: it says "side view, on the ground" without competing with the car.
             + '<path d="M0 20.9H24" opacity="0.45"/>'
             // Wheel arch, then tyre, then a solid hub so the wheel reads as a wheel at 70px and
             // not as an empty circle.
             + '<path d="M' + (wx - 3.8) + ' 17.6a3.9 3.9 0 0 1 7.6 0"/>'
             + '<circle cx="' + wx + '" cy="17.1" r="3.2"/>'
             + '<circle cx="' + wx + '" cy="17.1" r="1.15" fill="currentColor" stroke="none"/>'
             + body
             + '</svg>';
    }

    var GLYPHS = {
        lock: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<rect x="4.5" y="10.4" width="15" height="10.1" rx="2.2" fill="currentColor" stroke="none"/>'
            + '<path d="M8.2 10.4V7.4a3.8 3.8 0 0 1 7.6 0v3"/></svg>',

        // The open one is the same body with the shackle sprung off its seat on the right, which
        // reads as "open" at a glance far better than a differently-shaped lock would.
        unlock: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<rect x="4.5" y="10.4" width="15" height="10.1" rx="2.2" fill="currentColor" stroke="none"/>'
            + '<path d="M8.2 10.4V7.4a3.8 3.8 0 0 1 7.3-1.3"/></svg>',

        // A PICK GOING INTO A KEYHOLE. A big solid keyhole,
        // and the pick sliding into it from the corner: grip outside, the slim shaft down a channel
        // cut into the keyhole, its bent tip showing inside. Not a padlock — it sits directly under
        // `lock` in the stack, and two padlocks one above the other would be a puzzle.
        //
        // THE CHANNEL IS PART OF THE KEYHOLE'S OUTLINE, a notch rather than a hole punched through
        // it: a separate cut-out that crossed the keyhole's edge would leave black spilling outside.
        // Computed, not hand-placed — keyhole centre (9.4, 8.6), radius 5.6, channel 3.5 wide at 45°.
        lockpick: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<path d="M7.5 13.87A5.6 5.6 0 1 1 14.4 11.12L10.44 7.16A1.75 1.75 0 0 0 7.96 9.64'
            +     'L11.92 13.6A5.6 5.6 0 0 1 11.3 13.87L13.1 20.8H5.7Z" fill="currentColor" stroke="none"/>'
            + '<path d="M22.4 22.2 18.8 18.6" stroke-width="4.4"/>'
            + '<path d="M18.8 18.6 9.7 8.9l.5-1.2" stroke-width="1.6"/></svg>',

        // A CAR DOOR SEEN FROM OUTSIDE, as one solid shape with the window and handle cut out: a solid
        // door with a raked window is the heaviest, plainest read at a distance.
        // Not an arrow or a generic rectangle: this option sits alongside a padlock and a pick, and
        // the thing that tells them apart at a glance is that each looks like the object it acts on.
        //
        // FILLED, like `turbo`: one evenodd path, the cut-outs being its holes. The thin stroke in
        // the same colour only softens the corners.
        door: '<svg viewBox="0 0 24 24" fill="currentColor" stroke="currentColor" stroke-width="1"'
            + ' stroke-linejoin="round">'
            + '<path fill-rule="evenodd" d="M3.6 20.4V11.2L11.4 3.6h7.8a1.2 1.2 0 0 1 1.2 1.2v14.4'
            +     'a1.2 1.2 0 0 1-1.2 1.2ZM7 11.2h11V6.1h-5.6Zm7.2 2.4a.9.9 0 0 0 0 1.8h2.8a.9.9 0 0 0 0-1.8Z"/></svg>',

        // A HOUSE'S FRONT DOOR, for what is about a building rather than a car: a for-sale sign's rooms
        // (told apart from a car door). `door` stays the car's. A plain slab with
        // the knob cut out, standing on its step — picked over a panelled door (read as a building) and
        // an open one (read as "go in"). Filled like `door`; the step is its own bar, wider than the door.
        house_door: '<svg viewBox="0 0 24 24" fill="currentColor" stroke="currentColor" stroke-width="1"'
            + ' stroke-linejoin="round">'
            + '<path fill-rule="evenodd" d="M6.2 20.6V4.4a1.2 1.2 0 0 1 1.2-1.2h9.2a1.2 1.2 0 0 1 1.2 1.2v16.2Z'
            +     'M13.2 12.6a1.9 1.9 0 1 0 3.8 0a1.9 1.9 0 1 0-3.8 0Z"/>'
            + '<path d="M3.6 20.2h16.8v1.6H3.6Z"/></svg>',

        // ---- THE FULL-BLEED ONES: a slice of the car itself ----
        //
        // THE LABEL STOPPED SAYING "OPEN" OR "CLOSE" AND THE PICTURE SAYS IT INSTEAD. "Trunk" with
        // a boot that is visibly shut, or visibly open, carries the same information in less space
        // and in a form you read without reading — which is what a circle three metres away wants.
        //
        // THEY RUN OFF THE EDGE ON PURPOSE: a side profile cropped by the circle, wheel to bumper, rather than a whole car shrunk to
        // fit. A whole car at this size is a smudge; one end of one, big, is legible.
        //
        // The car faces LEFT in all four, so the hood pair shows its front and the boot pair its
        // back — the same vehicle from the same side, which is what makes the two pairs read as a
        // set rather than as two unrelated drawings.
        hood_closed: carGlyph(
              '<path d="M1.8 17.6V13.2c0-1.1.9-1.5 1.9-1.65L13 10.2l6.6-5.7"/>'
            + '<path d="M1.8 17.6h3.4"/><path d="M12.8 17.6H23"/>', 9),

        // Hinged at its back edge, so it stands up and toward the front — which is the shape a
        // raised bonnet actually makes, and the reason the engine bay opens up behind the nose.
        hood_open: carGlyph(
              '<path d="M1.8 17.6V13.2c0-1.1.9-1.5 1.9-1.65l3.6-.5"/>'
            + '<path d="M13 10.2l6.6-5.7"/>'
            + '<path d="M13 10l-6.2-7.6"/>'
            + '<path d="M1.8 17.6h3.4"/><path d="M12.8 17.6H23"/>', 9),

        trunk_closed: carGlyph(
              '<path d="M22.2 17.6V13.2c0-1.1-.9-1.5-1.9-1.65L11 10.2 4.4 4.5"/>'
            + '<path d="M22.2 17.6h-3.4"/><path d="M11.2 17.6H1"/>', 15),

        // Hinged at its front edge, so it lifts up and toward the back — the mirror of the bonnet,
        // which is what a boot lid does.
        trunk_open: carGlyph(
              '<path d="M22.2 17.6V13.2c0-1.1-.9-1.5-1.9-1.65l-3.6-.5"/>'
            + '<path d="M11 10.2L4.4 4.5"/>'
            + '<path d="M11 10l6.2-7.6"/>'
            + '<path d="M22.2 17.6h-3.4"/><path d="M11.2 17.6H1"/>', 15),

        // THE BOOT LID, RAISED: the back of the car head-on, its lid hinged up off the roof and
        // flaring toward you. For the option that only swings the lid — "Open Trunk" / "Close Trunk"
        // — above the boot's "View Trunk Inventory" (which draws `trunk_open`).
        //
        // A WHOLE CAR, AND FROM A DIFFERENT SIDE THAN THE SLICE ABOVE IT (the lid alone reads as a
        // stray slash). The `trunk_closed` /
        // `trunk_open` slice it sits under is a side view cropped by the disc; this is the whole
        // back end seen from behind, inset, so the two still tell apart at a glance.
        //
        // ONE DRAWING, NOT A PAIR: the option's label already says Open or Close.
        trunk_lid: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            // The body: bumper, tail lights, the stubs of the wheels.
            + '<path d="M3.6 14.2h16.8v4a1.2 1.2 0 0 1-1.2 1.2H4.8a1.2 1.2 0 0 1-1.2-1.2Z"/>'
            + '<path d="M6.4 16.8h1.6"/><path d="M16 16.8h1.6"/>'
            + '<path d="M5.8 19.4v1.6"/><path d="M18.2 19.4v1.6"/>'
            // The rear window, under where the lid was.
            + '<path d="M6 14.2 7.6 10.6h8.8l1.6 3.6"/>'
            // The lid: hinged at the roof, standing up, solid so it is the loudest part.
            + '<path d="M7.6 9.8h8.8l2.8-6.2H4.8Z" fill="currentColor" stroke-width="1.4"/></svg>',

        // A GARAGE: a roller door under a roof. Not a car — the bay is empty, which is the whole
        // reason its prompt is there, and a car on it would say the opposite of what it means.
        //
        // SOLID, with the door's slats showing as white lines (the same solid style as `door` and
        // `car`). The door opening is a notch cut up from the ground in the
        // building's outline, and two slats run wall to wall across it, UNSTROKED: the softening
        // stroke would eat the white gaps, and at 40px the door vanished into a solid shed.
        garage: '<svg viewBox="0 0 24 24" fill="currentColor" stroke="currentColor" stroke-width="1"'
            + ' stroke-linejoin="round">'
            + '<path d="M2.6 20V9.2L12 4.2l9.4 5V20h-3.6v-7.6H6.2V20Z"/>'
            + '<path d="M6.2 14.4h11.6v1.4H6.2Z" stroke="none"/>'
            + '<path d="M6.2 17.2h11.6v1.4H6.2Z" stroke="none"/></svg>',

        // ONE CAR, head-on and solid: the windscreen and the headlights cut out, the wheels as two
        // stubs under it. For the rows of the list a bay expands into, and the stand-in for a make
        // with no logo. Small and repeated — every row wears it — so it is one plain, symmetrical
        // silhouette that reads at any size.
        //
        // FILLED, like `door`: one evenodd path for the body and its cut-outs, plus the wheels.
        car: '<svg viewBox="0 0 24 24" fill="currentColor" stroke="currentColor" stroke-width="1"'
            + ' stroke-linejoin="round">'
            + '<path fill-rule="evenodd" d="M7.6 5.8A2 2 0 0 1 9.4 4.6h5.2a2 2 0 0 1 1.8 1.2L18 9.8h1.4'
            +     'A1.8 1.8 0 0 1 21.2 11.6v5a1.8 1.8 0 0 1-1.8 1.8H4.6A1.8 1.8 0 0 1 2.8 16.6v-5'
            +     'A1.8 1.8 0 0 1 4.6 9.8H6ZM8.6 9.8h6.8l-1-2.8H9.6ZM5.6 12.8a1.2 1.2 0 1 0 2.4 0'
            +     'a1.2 1.2 0 1 0-2.4 0ZM16 12.8a1.2 1.2 0 1 0 2.4 0a1.2 1.2 0 1 0-2.4 0Z"/>'
            + '<path d="M5 18.4h2.4v2.2H5Z"/><path d="M16.6 18.4H19v2.2h-2.4Z"/></svg>',

        // STORING ONE: the same car, with an arrow putting it away. The arrow points down into the
        // box rather than at the garage, because the action is "put this away" and not "go there".
        store: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<path d="M12 3.2v8.6"/><path d="M8.4 8.4 12 12l3.6-3.6"/>'
            + '<path d="M3.4 14.2v5.2a1 1 0 0 0 1 1h15.2a1 1 0 0 0 1-1v-5.2"/>'
            + '<path d="M3.4 14.2h17.2"/></svg>',

        // A TURBOCHARGER, seen the way one sits on a bench: the volute housing, the compressor hub
        // at its centre, and the discharge duct coming off tangentially with its flange.
        //
        // NOT A WRENCH, and that is the same rule the rest of this atlas follows — `lockpick` is a
        // pick rather than a padlock, `door` is a door rather than an arrow. A spanner would say
        // "some mechanical job"; the snail says which one, which matters the moment a second engine
        // part registers an option beside it.
        //
        // A TURBOCHARGER — Material Design Icons `car-turbocharger`, Apache 2.0, unchanged.
        //
        // FILLED, not stroked, unlike every other glyph here — MDI paths are solid shapes. It still
        // takes currentColor, so it inherits the disc exactly as the outlines do.
        //
        turbo: '<svg viewBox="0 0 24 24" fill="currentColor" stroke="none">'
            + '<path d="M22 13V15H18.32C18.75 14.09 19 13.08 19 12C19 8.14 15.86 5 12 5H2V3H12C16.97 3 21 7.03 21 12C21 12.34 20.97 12.67 20.94 13H22M12 19C8.14 19 5 15.86 5 12C5 10.93 5.25 9.91 5.69 9H2V11H3.06C3.03 11.33 3 11.66 3 12C3 16.97 7.03 21 12 21H22V19H12M16.86 12.2C15.93 12.94 14.72 12.47 14 12.05V12C16.79 10.31 15.39 7.89 15.39 7.89S14.33 6.04 14.61 7.89C14.78 9.07 13.76 9.88 13.04 10.3L13 10.28C12.93 7 10.13 7 10.13 7S8 7 9.74 7.69C10.85 8.13 11.04 9.42 11.05 10.25L11 10.28C8.14 8.7 6.74 11.12 6.74 11.12S5.67 12.97 7.14 11.8C8.07 11.07 9.28 11.54 10 11.95V12C7.21 13.7 8.61 16.12 8.61 16.12S9.67 17.97 9.4 16.11C9.22 14.94 10.25 14.13 10.97 13.7L11 13.73C11.07 17 13.87 17 13.87 17S16 17 14.26 16.31C13.15 15.87 12.96 14.58 12.95 13.75L13 13.73C15.86 15.31 17.26 12.88 17.26 12.88S18.33 11.04 16.86 12.2Z"/></svg>',

        // FURNISHING: a furnished corner — an armchair with a floor lamp beside it. Not a paintbrush, a hammer or any other metaphor for "edit" — this option
        // sits directly under `house` in the property's stack, and the thing that tells the two
        // apart at a glance is that one is the building and the other is what goes in it. Two
        // pieces rather than one chair, so it reads as furnishing a room, not as a seat.
        //
        // SOLID, like the `house` above it: separate filled pieces with NO stroke, so the white
        // gaps between the chair's back, arms and seat stay crisp — the softening stroke the other
        // solid glyphs use would close gaps this narrow.
        furnish: '<svg viewBox="0 0 24 24" fill="currentColor" stroke="none">'
            // The lamp: shade, pole, foot.
            + '<path d="M1.8 8.2 3.6 3.4h3.6l1.8 4.8Z"/>'
            + '<rect x="4.6" y="8.2" width="1.6" height="11.2"/>'
            + '<rect x="2.8" y="19" width="5.2" height="1.6" rx=".8"/>'
            // The armchair, from the front: back, arms, seat, the base joining them, legs.
            + '<rect x="12.2" y="7.4" width="6.6" height="5.8" rx="1.6"/>'
            + '<rect x="9.2" y="11.6" width="2.4" height="6.6" rx="1.2"/>'
            + '<rect x="19.4" y="11.6" width="2.4" height="6.6" rx="1.2"/>'
            + '<rect x="12.2" y="14.4" width="6.6" height="3.8" rx=".8"/>'
            + '<rect x="9.2" y="17" width="12.6" height="2.2" rx="1"/>'
            + '<rect x="10.2" y="18.8" width="1.6" height="1.8" rx=".5"/>'
            + '<rect x="19.2" y="18.8" width="1.6" height="1.8" rx=".5"/></svg>',

        // A HOME'S LOOK (its walls and floor: a property's Theme, under Furnish on its sign): a paint
        // roller. Here the paint metaphor is the literal thing — the walls change colour — which is
        // why Furnish above it is the armchair and not this. SOLID pieces, as `furnish` is: the
        // roller, its arm in three bars, the handle.
        theme: '<svg viewBox="0 0 24 24" fill="currentColor" stroke="none">'
            + '<rect x="2.6" y="3" width="15.6" height="6.2" rx="1.6"/>'
            + '<rect x="18" y="5.3" width="3.4" height="1.6"/>'
            + '<rect x="19.8" y="5.3" width="1.6" height="7"/>'
            + '<rect x="11.2" y="10.7" width="10.2" height="1.6"/>'
            + '<rect x="11.2" y="10.7" width="1.6" height="4.2"/>'
            + '<rect x="10" y="14.2" width="4" height="7.4" rx="1.3"/></svg>',

        // A HOUSE, for a property's entry prompt. Pitched roof and a door — deliberately not the
        // roller-door `garage` glyph it sits near in the atlas, because a property and the place
        // you park are different things and two variations on a shed would not say which.
        //
        // SOLID, with the door cut out white (the `door` / `car` style). The
        // door is a notch in the outline rather than a hole: a hole sharing the ground line would
        // be closed off along the bottom by the stroke that softens the corners.
        house: '<svg viewBox="0 0 24 24" fill="currentColor" stroke="currentColor" stroke-width="1"'
            + ' stroke-linejoin="round">'
            + '<path d="M3.4 10.6 12 4l8.6 6.6V20a1 1 0 0 1-1 1h-5.2v-5.2a1.2 1.2 0 0 0-1.2-1.2h-2.4'
            +     'a1.2 1.2 0 0 0-1.2 1.2V21H4.4a1 1 0 0 1-1-1Z"/></svg>',

        // PICKING SOMETHING UP: the mirror of `store`, and deliberately so — the two are opposite
        // halves of the same idea and should look like it. An arrow rising OFF a surface rather
        // than dropping INTO a container.
        //
        // No item drawn under the arrow. There is a real prop lying on the ground a metre away and
        // the label already names it, so a generic box here would be the third thing on screen
        // saying what the player can already see — the same reasoning that took the word "Pick Up"
        // out of the label in the first place.
        pickup: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<path d="M12 17.2V4.8"/>'
            + '<path d="M7.6 9.2 12 4.8l4.4 4.4"/>'
            + '<path d="M4.2 20.4h15.6"/></svg>',

        // A BANK, DRAWN AS A BANK: pediment, columns, plinth. Not a dollar sign, not a card, not a
        // wallet — the same rule the rest of this atlas follows, where `lock` is a padlock and
        // `house` is a house. It wears two hats and both want a building: it is the glyph on the
        // machine itself, and on each account in the list one level down.
        //
        // THE THREE COLUMNS ARE A PATH EACH rather than one rectangle with gaps cut out of it. At
        // 128px a filled shape with slots in it turns to mush; strokes stay strokes.
        bank: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<path d="M2.8 9.4 12 4.2l9.2 5.2"/>'
            + '<path d="M6.2 11.6v6.2"/><path d="M12 11.6v6.2"/><path d="M17.8 11.6v6.2"/>'
            + '<path d="M3.6 20.2h16.8"/></svg>',

        // PUTTING CASH IN: a banknote, and an arrow dropping toward the slot below it.
        //
        // A NOTE AND NOT A BOX, which is what separates this pair from `store` and `pickup`. Those
        // two are objects going into and out of a container and are drawn as exactly that; these
        // are money, and a rectangle with a circle in the middle reads as a banknote at a glance
        // even at badge size.
        //
        // DEPOSIT AND WITHDRAW SIT DIRECTLY ABOVE ONE ANOTHER IN THE SAME STACK, so the only thing
        // that may differ between them is the arrow — same note, same slot, one arrow down and one
        // up. Any other difference and the player has to read the label rather than glance at the
        // glyph, which is the same argument that made `lockpick` a pick instead of a second padlock.
        deposit: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<rect x="4.4" y="3.4" width="15.2" height="7.4" rx="1.2"/>'
            + '<circle cx="12" cy="7.1" r="1.7"/>'
            + '<path d="M12 13.4v4.8"/><path d="M9.2 15.6 12 18.4l2.8-2.8"/>'
            + '<path d="M4.4 20.8h15.2"/></svg>',

        // TAKING CASH OUT: the same note and the same slot, arrow the other way. See `deposit`.
        withdraw: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<rect x="4.4" y="3.4" width="15.2" height="7.4" rx="1.2"/>'
            + '<circle cx="12" cy="7.1" r="1.7"/>'
            + '<path d="M12 18.4v-4.8"/><path d="M9.2 16.2 12 13.4l2.8 2.8"/>'
            + '<path d="M4.4 20.8h15.2"/></svg>',

        // THE ONE GLYPH HERE ALLOWED TO BE AN ARROW. Everywhere else this atlas draws the THING
        // rather than a metaphor for it, because there is always a thing — a door, a padlock, a
        // chair. "Back" has no object: it is a move through a menu, and an arrow pointing the way
        // you are about to go IS that move rather than a stand-in for it.
        //
        // Slightly heavier stroke than its neighbours. It is two lines against glyphs made of five
        // or six, and at matching weight it read as thinner than everything it sits above.
        back: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.3"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<path d="M19.4 12H5.2"/>'
            + '<path d="M10.6 6.6 5.2 12l5.4 5.4"/></svg>',

        // A PETROL PUMP: the cabinet with its display, and the hose looping down the side to the
        // nozzle hung at the top. It is the pump's own circle and the car's Refuel option, and both
        // mean "fuel from a pump" — the thing, not a droplet or a dollar sign.
        //
        // THE CABINET IS SOLID, its display cut out white (the `door` / `car` style); the ground and the hose stay lines, because a solid hose is just a blob.
        fuel: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<path fill="currentColor" stroke-width="1" fill-rule="evenodd" d="M5.4 20.4V5'
            +     'a1.4 1.4 0 0 1 1.4-1.4h5.6A1.4 1.4 0 0 1 13.8 5v15.4ZM7.8 6.2h3.8a.6.6 0 0 1 .6.6v2.8'
            +     'a.6.6 0 0 1-.6.6H7.8a.6.6 0 0 1-.6-.6V6.8a.6.6 0 0 1 .6-.6Z"/>'
            + '<path d="M3.6 20.4h12"/>'
            + '<path d="M13.8 10.6h1.4a1.2 1.2 0 0 1 1.2 1.2v4.6a1.5 1.5 0 0 0 3 0V8.4L17 5.6"/></svg>',

        // THE NOZZLE ITSELF, for "Put Nozzle Away". It shares the pump's circle with `fuel` — one
        // circle in two states — so the drawing is what changes when the nozzle is in your hand:
        // the pump you took it from now shows the thing you are holding. Spout to the left, the
        // grip loop underneath, the hose running off the back.
        //
        // AND A DROP OF FUEL AT THE SPOUT: without it the nozzle reads as a tool or a stapler; the
        // drop says what comes out of it.
        nozzle: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<path d="M9.4 7.2 5 9.4"/>'
            + '<path d="M9.4 5.4h8a1.8 1.8 0 0 1 1.8 1.8v2.6h-7.6L9.4 9.2Z"/>'
            + '<path d="M12.2 9.8v3.4a1.6 1.6 0 0 0 1.6 1.6h3.8a1.6 1.6 0 0 0 1.6-1.6V9.8"/>'
            + '<path d="M19.2 7.8h.6a1.8 1.8 0 0 1 1.8 1.8v11"/>'
            + '<path d="M4.4 13.2c-1.1 1.5-1.6 2.5-1.6 3.2a1.6 1.6 0 0 0 3.2 0c0-.7-.5-1.7-1.6-3.2Z"'
            +     ' fill="currentColor" stroke-width="1.2"/></svg>',

        // CASH: a banknote with a second one peeking out behind it — money, not a single ticket.
        // It sits beside `bank` in the pump's pay menu, and the pair has to tell notes
        // from an account at a glance. The front note is the ATM's note (`deposit`, `withdraw`), so
        // a player who has used one already knows what this means.
        cash: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<path d="M6.4 5.4h13.4a1.4 1.4 0 0 1 1.4 1.4v8"/>'
            + '<rect x="2.8" y="8.6" width="15.4" height="10" rx="1.4"/>'
            + '<circle cx="10.5" cy="13.6" r="2.3"/></svg>',

        // A DOLLAR SIGN: a shop, somewhere to spend (the holdall is the inventory's). The S drawn whole, the stroke only above and below it:
        // the line through the middle muddies it at a prompt's size.
        dollar: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<path d="M17.2 7.5C16.6 5.9 14.6 4.8 12 4.8C8.9 4.8 6.8 6.1 6.8 8.1C6.8 10.1 8.9 10.9 12 11.6'
            +     'C15.1 12.3 17.2 13.1 17.2 15.4C17.2 17.6 15 19.2 12 19.2C9.2 19.2 7.3 18.1 6.7 16.4"/>'
            + '<path d="M12 2.4v2.4"/><path d="M12 19.2v2.4"/></svg>',

        // TALK: a conversation, for the Director's Talk points. A speech bubble
        // with the three dots of someone talking, and a second one behind it answering: one bubble
        // is a message, two are a conversation. `cash`'s pattern, the front one solid and the one
        // behind peeking out as a line. Each bubble's tail is a corner, pointing at its speaker.
        //
        // The front bubble is one evenodd path with NO stroke: its dots are holes, and the softening
        // stroke the solid glyphs wear would close them (see `furnish`).
        talk: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<path d="M7.6 6.2v-.6a2.2 2.2 0 0 1 2.2-2.2H19a2.2 2.2 0 0 1 2.2 2.2v8.8l-2.6-2.2"/>'
            + '<path fill="currentColor" stroke="none" fill-rule="evenodd" d="M5 8.4h9.2a2.2 2.2 0 0 1 2.2 2.2'
            +     'v4.8a2.2 2.2 0 0 1-2.2 2.2H6l-3.2 3.2V10.6A2.2 2.2 0 0 1 5 8.4Z'
            +     'M5.15 13a1.25 1.25 0 1 0 2.5 0a1.25 1.25 0 1 0-2.5 0Z'
            +     'M8.35 13a1.25 1.25 0 1 0 2.5 0a1.25 1.25 0 1 0-2.5 0Z'
            +     'M11.55 13a1.25 1.25 0 1 0 2.5 0a1.25 1.25 0 1 0-2.5 0Z"/></svg>',

        // ---- THE WHEEL'S ----
        //
        // Drawn for the F1 wheel's slabs, where every entry wears an icon, and here so a prompt or a
        // satellite can name them too. Outlines at the atlas's 2.1 weight, like `cash` and `bank`.

        // A PHONE, face on: the handset, its earpiece slot and the home bar.
        phone: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<rect x="6.2" y="2.6" width="11.6" height="18.8" rx="2.6"/>'
            + '<path d="M10.2 18.2h3.6"/><path d="M10.6 5.6h2.8"/></svg>',

        // A BAG: a holdall with its handle, a seam and the clasp — the inventory, not a shop.
        bag: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<path d="M8.4 7.2V5.8a3.6 3.6 0 0 1 7.2 0v1.4"/>'
            + '<rect x="4.2" y="7.2" width="15.6" height="13.6" rx="3"/>'
            + '<path d="M4.2 12.8h15.6"/><path d="M10.2 12.8v2.4h3.6v-2.4"/></svg>',

        // AN EMOTE: a figure mid-dance, one arm up. A person doing something, not a smiley — an
        // emote here is an animation the character plays.
        emote: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<circle cx="12" cy="4.6" r="2.3" fill="currentColor" stroke="none"/>'
            + '<path d="M12 8.8v6"/><path d="M12 14.8 9 20.6"/><path d="M12 14.8l3 5.8"/>'
            + '<path d="M12 10.4 7.2 8.2"/><path d="M12 10.4l4.2-2.8 1.4-3.2"/></svg>',

        // AN ID CARD: photo, two lines of text.
        id: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<rect x="2.8" y="5.2" width="18.4" height="13.6" rx="2.2"/>'
            + '<circle cx="8.6" cy="10.8" r="2.1" fill="currentColor" stroke="none"/>'
            + '<path d="M5.6 15.8c.6-1.5 1.6-2.2 3-2.2s2.4.7 3 2.2"/>'
            + '<path d="M14.2 10h4.2"/><path d="M14.2 13.4h4.2"/></svg>',

        // THE ENGINE, as the power mark every start button wears: on or off, which is what the
        // option does. An engine block would say "repair", the thing a mechanic's option means.
        power: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.3"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<path d="M12 3.2v8.2"/><path d="M7.2 6.4a7.6 7.6 0 1 0 9.6 0"/></svg>',

        // HEADLIGHTS: the dashboard's own lamp — the solid lens, its beams dipping toward the road.
        headlights: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<path d="M11.6 5.4H10.2C6.3 5.4 3.4 8.3 3.4 12s2.9 6.6 6.8 6.6h1.4Z" fill="currentColor" stroke-width="1.2"/>'
            + '<path d="M15.2 6.4l5.6 1.4"/><path d="M15.2 9.9l5.6 1.4"/>'
            + '<path d="M15.2 13.4l5.6 1.4"/><path d="M15.2 16.9l5.6 1.4"/></svg>',

        // A SEAT (the wheel's Seats, the seat map): a car seat side on, facing right: headrest,
        // backrest leaning back, cushion, and the rail it slides on.
        seat: '<svg viewBox="0 0 24 24" fill="currentColor" stroke="currentColor" stroke-width="1"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<rect x="7.6" y="2.4" width="4.8" height="3.4" rx="1.5"/>'
            + '<path d="M8.4 7.2h3.6c.6 0 1 .5.9 1.1L11.7 15H7.1l.4-6.9c0-.5.4-.9.9-.9Z"/>'
            + '<rect x="7" y="15.9" width="11" height="3.4" rx="1.6"/>'
            + '<path d="M9.2 21.4h7.4" fill="none" stroke-width="2"/></svg>',

        // DEV TOOLS (the /w menu): an open-ended spanner, the head solid with its jaw cut in, and the
        // handle running down to the corner. Not `turbo`'s job: this one means "the tools", whatever
        // they work on.
        devtools: '<svg viewBox="0 0 24 24" fill="currentColor" stroke="currentColor" stroke-width="1"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<path d="M20.14 5.99A4.6 4.6 0 1 1 18.01 3.86L14.52 7.36L16.64 9.49Z"/>'
            + '<path d="M14.2 9.8 4.9 19.1" fill="none" stroke-width="3.6"/></svg>',

        // ---- THE HINT CAPSULE'S ----
        //
        // The capsule at the bottom of the screen while something is being done (UI.ShowText's
        // `icon`, UI.Progress's): its disc shows WHAT is being done, as a prompt's disc does. Outlines
        // at the atlas's 2.1 weight.

        // PLACE: `pickup` the other way — the arrow down onto the ground line.
        place: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<path d="M12 4.6v11.8"/><path d="M7.6 12 12 16.4l4.4-4.4"/><path d="M4.2 20.4h15.6"/></svg>',

        // GIVE: something handed to a person — an arrow to a figure.
        give: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<circle cx="17.2" cy="6.6" r="2.4" fill="currentColor" stroke="none"/>'
            + '<path d="M13.2 20.4v-1.8a4 4 0 0 1 8 0v1.8"/>'
            + '<path d="M2.8 13.2h7.6"/><path d="M7.4 10l3.2 3.2-3.2 3.2"/></svg>',

        // EAT: a fork and a knife.
        eat: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<path d="M6.4 3.2v5.4a2.6 2.6 0 0 0 5.2 0V3.2"/><path d="M9 3.2v5.2"/><path d="M9 11.2v9.6"/>'
            + '<path d="M17.6 20.8V3.2c-2 .9-3.2 3.4-3.2 6.8v3.2h3.2"/></svg>',

        // RESPAWN: coming back — an arrow going round.
        respawn: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<path d="M19.6 12.4a7.6 7.6 0 1 1-2.4-5.8"/><path d="M19.8 3.6v4.6h-4.6"/></svg>',

        // OBJECTIVE: a flag on its pole — what a job wants of the player (the objective tracker's disc,
        // html/js/ui.js §10). Not an action, so not in the loading screen's copy either.
        objective: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<path d="M6 21V3.4"/>'
            + '<path d="M6 4.4h11.6l-2.6 4.2 2.6 4.2H6" fill="currentColor" stroke-width="1.4"/></svg>',

        // TARGET, PIN, STAR: more marks an objective card can wear (ShowObjective's `icon`, client/ui.lua):
        // take someone out, get somewhere, lose the cops (GTA's wanted star). Not actions, so not in the
        // loading screen's copy.
        target: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<circle cx="12" cy="12" r="7.2"/><circle cx="12" cy="12" r="1.7" fill="currentColor" stroke="none"/>'
            + '<path d="M12 2.6v4.2M12 17.2v4.2M2.6 12h4.2M17.2 12h4.2"/></svg>',
        pin: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<path d="M12 21.2s-6.6-6.1-6.6-11.2a6.6 6.6 0 0 1 13.2 0c0 5.1-6.6 11.2-6.6 11.2Z"/>'
            + '<circle cx="12" cy="10" r="2.4"/></svg>',
        star: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<path d="M12 3.5l2.3 6.2 6.6.3-5.1 4.1 1.7 6.4-5.5-3.7-5.5 3.7 1.7-6.4-5.1-4.1 6.6-.3Z"/></svg>',

        // TIMER: an hourglass — a bar that names no icon of its own. Not an action, so not in the
        // loading screen's copy (as `back` is not).
        timer: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<path d="M6.6 3.2h10.8"/><path d="M6.6 20.8h10.8"/>'
            + '<path d="M8 3.2v2.6a4.4 4.4 0 0 0 1.8 3.6L12 11l2.2-1.6A4.4 4.4 0 0 0 16 5.8V3.2"/>'
            + '<path d="M8 20.8v-2.6a4.4 4.4 0 0 1 1.8-3.6L12 13l2.2 1.6a4.4 4.4 0 0 1 1.8 3.6v2.6"/></svg>',

        // FAIL: the cross of a failure — an interrupted bar or mode (html/js/ui.js §9) and the error
        // notification (drawn, not the text ✗, so it sits centred). Two strokes
        // crossing at the box's exact middle, heavier than the rest: on a filled disc it IS the message.
        // Not an action, so not in the loading screen's copy.
        fail: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<path d="M6.5 6.5l11 11"/><path d="M17.5 6.5l-11 11"/></svg>',

        // SUCCESS, INFO, WARNING: the notifications' other marks, drawn to match `fail`: the same heavy round stroke, each centred on the box's middle — a
        // tick, an i, a !. Not actions, so not in the loading screen's copy (nor the logo's light, logo-light.js).
        success: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<path d="M5.6 12.6l4.3 4.2 8.5-9.3"/></svg>',
        info: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<circle cx="12" cy="6.9" r="1.75" fill="currentColor" stroke="none"/><path d="M12 11.2v6.9"/></svg>',
        warning: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<path d="M12 5.9v6.9"/><circle cx="12" cy="17.1" r="1.75" fill="currentColor" stroke="none"/></svg>',

        // OBJECT, PED: what the Object Viewer's card names — a box seen
        // from a corner, and a figure; a vehicle is `car`. In the prompts' 2.1 stroke. A dev tool's, not an
        // action, so not in the loading screen's copy (nor the logo's light, logo-light.js).
        object: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<path d="M12 3.4l7.6 4.2v8.8L12 20.6l-7.6-4.2V7.6Z"/><path d="M4.4 7.6 12 11.8l7.6-4.2"/>'
            + '<path d="M12 11.8v8.8"/></svg>',
        ped: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<circle cx="12" cy="7.6" r="3.6"/><path d="M4.8 20.4c.9-4.2 3.6-6.4 7.2-6.4s6.3 2.2 7.2 6.4"/></svg>',

        // CAMERA: the Camera Creator's card — a film camera, body and lens. A dev tool's,
        // so not in the loading screen's copy (nor its light).
        camera: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1"'
            + ' stroke-linecap="round" stroke-linejoin="round">'
            + '<rect x="2.8" y="6.8" width="12.6" height="10.4" rx="2.2"/><path d="M15.4 10.6l5.8-3.2v9.2l-5.8-3.2Z"/></svg>',
    };

    // WHICH GLYPHS FILL THE WHOLE DISC rather than sitting in the middle of it. See the badge's
    // renderGlyph.
    var FULL_BLEED = {
        hood_closed: true, hood_open: true, trunk_closed: true, trunk_open: true,
    };

    window.PfGlyphs = { glyphs: GLYPHS, fullBleed: FULL_BLEED };
})();
