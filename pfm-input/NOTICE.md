# pfm-input: licence notice for the ported styles

Part of pfm-input's look is ported from the styles of WHIP's `whip_core` resource, by Whippy:

    Copyright (c) 2026 Whippy, from WHIP, LGPL-3.0; modified for PF.

Those files are free software under the GNU Lesser General Public License 3.0 (`COPYING.LESSER`),
which builds on the GNU General Public License 3.0 (`COPYING`). Each keeps the notice above in its
header. The shared values they read (colours, radii, fonts, motion) are pfm-ui's `html/tokens.css`,
itself a port of WHIP's `base.css` (see pfm-ui's NOTICE.md).

| pfm-input file | follows (whip_core) | changes for PF |
|---|---|---|
| html/styles/default.css | html/css/ui.css (INPUT DIALOG: shell, labels, fields, checkbox, buttons) | PF's form markup and class names; the dim drawn with a sibling selector |

Everything else in pfm-input keeps its own licence (`LICENSE` where present). pfm-input is not WHIP, is not
made by WHIP's author and does not use WHIP's name. The fonts the page shows (Barlow, Bricolage
Grotesque) are bundled by pfm-ui under the SIL Open Font License 1.1.
