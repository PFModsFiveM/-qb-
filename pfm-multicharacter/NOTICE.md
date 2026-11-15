# pfm-multicharacter: licence notice for the ported styles

Part of pfm-multicharacter's look is ported from the styles of WHIP's `whip_core` resource, by Whippy:

    Copyright (c) 2026 Whippy, from WHIP, LGPL-3.0; modified for PF.

Those files are free software under the GNU Lesser General Public License 3.0 (`COPYING.LESSER`),
which builds on the GNU General Public License 3.0 (`COPYING`). Each keeps the notice above in its
header. The shared values they read (colours, radii, fonts, motion) are pfm-ui's `html/tokens.css`,
itself a port of WHIP's `base.css` (see pfm-ui's NOTICE.md).

| pfm-multicharacter file | follows (whip_core) | changes for PF |
|---|---|---|
| html/style.css (the token mapping at its top and the "PF look" layer at its end) | html/css/ui.css, characters.css (panels, rows, fields, buttons, notification) | applied over PF's own character screen; the rest of style.css is PF's own |

Everything else in pfm-multicharacter keeps its own licence (`LICENSE` where present). pfm-multicharacter is not WHIP, is not
made by WHIP's author and does not use WHIP's name. The fonts the page shows (Barlow, Bricolage
Grotesque) are bundled by pfm-ui under the SIL Open Font License 1.1.
