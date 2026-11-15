# pfm-radialmenu: licence notice for the ported styles

Part of pfm-radialmenu's look is ported from the styles of WHIP's `whip_core` resource, by Whippy:

    Copyright (c) 2026 Whippy, from WHIP, LGPL-3.0; modified for PF.

Those files are free software under the GNU Lesser General Public License 3.0 (`COPYING.LESSER`),
which builds on the GNU General Public License 3.0 (`COPYING`). Each keeps the notice above in its
header. The shared values they read (colours, radii, fonts, motion) are pfm-ui's `html/tokens.css`,
itself a port of WHIP's `base.css` (see pfm-ui's NOTICE.md).

| pfm-radialmenu file | follows (whip_core) | changes for PF |
|---|---|---|
| html/css/main.css | html/css/ui.css (RADIAL MENU "Slab": slab fills, edges, the white chosen slab, the stat disc) | drawn on pfm-radialmenu's own SVG wheel (RadialMenu.js is not WHIP's) |

Everything else in pfm-radialmenu keeps its own licence (`LICENSE` where present). pfm-radialmenu is not WHIP, is not
made by WHIP's author and does not use WHIP's name. The fonts the page shows (Barlow, Bricolage
Grotesque) are bundled by pfm-ui under the SIL Open Font License 1.1.
