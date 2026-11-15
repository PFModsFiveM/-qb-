# progressbar: licence notice for the ported styles

Part of progressbar's look is ported from the styles of WHIP's `whip_core` resource, by Whippy:

    Copyright (c) 2026 Whippy, from WHIP, LGPL-3.0; modified for PF.

Those files are free software under the GNU Lesser General Public License 3.0 (`COPYING.LESSER`),
which builds on the GNU General Public License 3.0 (`COPYING`). Each keeps the notice above in its
header. The shared values they read (colours, radii, fonts, motion) are pfm-ui's `html/tokens.css`,
itself a port of WHIP's `base.css` (see pfm-ui's NOTICE.md).

| progressbar file | follows (whip_core) | changes for PF |
|---|---|---|
| html/style.css | html/css/ui.css (DRAWTEXT: the progress capsule) and status-hud.css (.sh-capsule, .sh-stat disc) | a percentage in the disc; PF's ids; a cancelled bar uses the failure look |

Everything else in progressbar keeps its own licence (`LICENSE` where present). progressbar is not WHIP, is not
made by WHIP's author and does not use WHIP's name. The fonts the page shows (Barlow, Bricolage
Grotesque) are bundled by pfm-ui under the SIL Open Font License 1.1.
