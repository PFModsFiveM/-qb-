# pfm-pause: licence notice

pfm-pause's page is a port of the pause menu of WHIP's `whip_core` resource, by Whippy:

    Copyright (c) 2026 Whippy, from WHIP, LGPL-3.0; modified for PF.

WHIP's code is free software under the GNU Lesser General Public License 3.0 (`COPYING.LESSER`), which
builds on the GNU General Public License 3.0 (`COPYING`). Every ported file keeps the notice above in
its header. pfm-pause is not WHIP, is not made by WHIP's author, and does not use WHIP's name or logo:
the logo is replaced by PF's own mark (`Config.Pause.Brand`).

## Ported files

| pfm-pause file | from whip_core | changes |
|---|---|---|
| html/js/pause.js | html/js/pause.js | menu items from Lua, Help item, Quit/Swap through a Lua token, brand mark, character line |
| html/js/pause-map.js | html/js/pause-map.js | names, the media URL |
| html/js/map3d/map3d.js | html/js/map3d/map3d.js | names only |
| html/js/settings-page.js | html/js/settings-page.js | minimap preview left out; texts |
| html/js/pad-layout.js | html/js/pad-layout.js | pfm-ui's button slots; texts |
| html/js/logo-light.js | html/js/logo-light.js | the logo's shape replaced by PF's mark; the light unchanged |
| html/js/router.js | html/js/router.js | header only |
| html/js/utils.js | html/js/utils.js | cut down; callbacks to this resource; media URL |
| html/js/pad-cursor.js | html/js/pad-cursor.js | screenRect only |
| html/js/pad-glyphs.js, prefs.js, blip-names.js, glyphs.js | same names | headers, names |
| html/js/main.js | html/js/main.js, controller.js | a small stand-in: messages, keys, hint strip |
| html/css/pause.css, settings-page.css, pad-layout.css | same names | PF additions at the end of pause.css |
| html/css/base.css, fonts.css | css/base.css, css/fonts.css (and ui.css's hint strip) | only what this page uses |
| html/img/pad/*.svg | html/img/pad/*.svg | unchanged |
| client/main.lua (the map's data) | client/pause.lua | blip, route, waypoint and player reading; NUI message names |

PF's own (not from WHIP): `client/main.lua` apart from the map reading (the open/close safeguards, the
pad reading, settings and layout bridges to pfm-ui, report, leave and swap), `server/main.lua`,
`config.lua`, `html/js/help-page.js`, `html/css/help.css`, `html/index.html`, `html/preview.html`
(a dev preview, not sent to players) and this notice.

## Third-party parts

| What | Where | Licence |
|---|---|---|
| three.js (r170), Copyright 2010-2024 Three.js Authors | html/js/vendor/three.module.min.js (its header kept) | MIT |
| Material Design Icons: the `car-turbocharger` glyph | html/js/glyphs.js | Apache 2.0 |
| Barlow, Copyright 2017 The Barlow Project Authors | html/fonts/barlow-*.woff2 | SIL Open Font License 1.1 (html/fonts/OFL-Barlow.txt) |
| Bricolage Grotesque, Copyright 2022 The Bricolage Grotesque Project Authors | html/fonts/bricolage-*.woff2 | SIL Open Font License 1.1 (html/fonts/OFL-BricolageGrotesque.txt) |

## The map

The map's data and GTA's blip icons are in the separate resource `pfm-media-map` (see its NOTICE.md):
GTA V's map traced by Regynate, built into a 3D map by 3D Clanker for WHIP, and GTA's blip pictures.
They are Rockstar Games' and Take-Two Interactive's, used only with GTA V on FiveM under Rockstar's
terms (fivem.net/terms). Neither WHIP nor PF is affiliated with, endorsed or sponsored by Rockstar
Games or Take-Two Interactive.
