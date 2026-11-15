# pfm-ui: licence notice

pfm-ui's controller support is ported from WHIP's `whip_core` resource:

    Copyright (c) 2026 Whippy, from WHIP, LGPL-3.0; modified for PF.

| pfm-ui file | ported from (whip_core) |
|---|---|
| client/prefs.lua | client/player_prefs.lua |
| client/pad_state.lua | client/controller.lua (device detection) |
| client/pad_layout.lua | client/pad.lua (buttons, layout, LB as a modifier) |
| lib/pad_bridge.lua | client/controller.lua (the NUI pad driver) |
| html/pad.js | html/js/controller.js, html/js/router.js |
| html/pad.css | (new, part of the same work) |

These files are free software under the GNU Lesser General Public License 3.0 (`COPYING.LESSER`),
which builds on the GNU General Public License 3.0 (`COPYING`). Each keeps a notice header naming
the original author. The changes for PF: everything renamed away from WHIP, the bridge rebuilt as a
library each resource includes (FiveM only lets a resource message its own page), WHIP's panel
scopes replaced by a small page library, and PF's own actions and layout.

Not taken from WHIP: its button pictures (pfm-ui draws its own plain glyphs in html/pad.js), its
on-screen keyboard word lists, and the WHIP name. pfm-ui is not WHIP and is not made by WHIP's author.

`config.lua`, `html/tokens.css`, `fxmanifest.lua` and `README.md` are PF's own.

Resources that use pfm-ui through `@pfm-ui/lib/pad_bridge.lua` and `html/pad.js` include those
LGPL files unchanged; the LGPL lets them keep their own licence for their own code.
