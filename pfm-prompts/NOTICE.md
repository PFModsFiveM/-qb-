# pfm-prompts: licence notice

pfm-prompts is a port of WHIP's world-space interaction prompts.

**WHIP** is Copyright (c) 2026 Whippy, licensed under the GNU Lesser General Public License 3.0. The files
ported from it keep that licence, modified for PF: `COPYING.LESSER` in this folder, with the GNU General
Public License 3.0 it builds on in `COPYING`. PF's own additions in this resource are offered under the same
licence (LGPL-3.0-or-later), so the resource as a whole can be shared under one set of terms.

This resource is not WHIP and does not come from WHIP's author; every identifier, event, texture and
setting name has been renamed away from WHIP's.

## What came from WHIP

| File here | From WHIP (whip_core) | Changes |
|---|---|---|
| client/world_quad.lua | client/world_quad.lua | renamed (PromptQuad); camera forward added; ground/corner quads dropped |
| client/dui_page.lua | client/dui_page.lua | renamed (PromptDui); boot delay and hooks trimmed |
| client/render_world.lua | client/interact_world.lua | reduced: no box wrapping, centring, fitting, theme atlases or style animations; a fourth badge row for prompts with nothing to press; sublabels; lazy preview browser |
| client/style.lua | client/interact_style.lua | reduced to one look read from Config |
| client/registry.lua, client/main.lua | client/interact.lua | the parts prompts need: 25 m grid, per-resource cleanup, focus by aim then reach, options on controls 16/17, hold to use, the score / draw loop |
| client/keys.lua | client/interact.lua (Interactions.keyName) | the idea of asking GetControlInstructionalButton; pad layout and glyph mapping are PF's |
| config.lua | config.lua (Config.Interact*, Config.Interact3D) | renamed and reduced |
| html/badge.html, html/label.html, html/preview.html | html/interact3d/ | renamed, colours from Config, info row, sublabel, pad glyphs |
| html/js/glyphs.js | html/js/glyphs.js | a subset of the icons; the pad_* glyphs are PF's |
| html/css/fonts.css | html/css/fonts.css | the two Barlow weights the atlases use |

## Third-party parts

| What | Where | Licence |
|---|---|---|
| Barlow, by The Barlow Project Authors (github.com/jpt/barlow) | html/fonts/barlow-*.woff2 | SIL Open Font License 1.1, `html/fonts/OFL-Barlow.txt` |

## Rockstar Games

GTA V, its controls and its natives belong to Rockstar Games and Take-Two Interactive. pfm-prompts is not
affiliated with or endorsed by them.
