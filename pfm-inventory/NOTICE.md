# pfm-inventory: licence notice for the ported styles

Part of pfm-inventory's look is ported from the styles of WHIP's `whip_core` resource, by Whippy:

    Copyright (c) 2026 Whippy, from WHIP, LGPL-3.0; modified for PF.

Those files are free software under the GNU Lesser General Public License 3.0 (`COPYING.LESSER`),
which builds on the GNU General Public License 3.0 (`COPYING`). Each keeps the notice above in its
header. The shared values they read (colours, radii, fonts, motion) are pfm-ui's `html/tokens.css`,
itself a port of WHIP's `base.css` (see pfm-ui's NOTICE.md).

| pfm-inventory file | follows (whip_core) | changes for PF |
|---|---|---|
| html/main.css (the "PF look" layer at its end, and the token mapping at its top) | html/css/inventory.css (panels, slot tiles, keycaps, weight gauge, popovers, controller highlight) | applied over PF's own inventory layout and class names; the rest of main.css is PF's own |

Everything else in pfm-inventory keeps its own licence (`LICENSE` where present). pfm-inventory is not WHIP, is not
made by WHIP's author and does not use WHIP's name. The fonts the page shows (Barlow, Bricolage
Grotesque) are bundled by pfm-ui under the SIL Open Font License 1.1.
