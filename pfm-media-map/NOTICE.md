# pfm-media-map: licence notice

This resource holds copies of WHIP's map media pack and of the Rockstar-derived data of WHIP's vehicle dial, apart
from names:

- from WHIP's map pack (whip_media_map): the resource's name, the 3D map data file's name (`map/map3d-data.js`), the
  global it sets (`window.MAP3D_DATA`), its first comment line and one path in its build notes; the radar tiles'
  file names (`whipmap_<row>_<col>.ytd` became `pfmap_<row>_<col>.ytd`; the texture inside each is still named
  `whipmap_<row>_<col>`, as a texture's name inside a .ytd cannot be changed without rebuilding the file);
- from whip_core: `data/dash_skins.lua` and `data/rpm_by_model.lua` unchanged, and `html/dash_skins3d.js`, which is
  whip_core's `html/js/vehicle_hud/skins3d.js` with its ES module exports turned into a classic script that sets
  `window.PfDashSkins` (its first comment lines and its `skinFor` helper changed; the data is unchanged).

Nothing else in the data, the icons or the tiles was changed.

    Copyright (c) 2026 Whippy, from WHIP, LGPL-3.0; modified for PF.

## What is in it

| Path | What | Used by |
|---|---|---|
| `img/blips/*.webp` | GTA's blip icons, one per sprite id (927), as used by the pause menu's map and legend | pfm-pause |
| `map/map3d-data.js` | The 3D map: GTA V's 2D map shapes standing on the game's heights (3D Clanker's 3D map build) | pfm-pause |
| `stream/pfmap_*.ytd`, `stream_enhanced/pfmap_*.ytd` | The HUD radar's dark tiles (six, 4096 px), baked by WHIP from GTA V's pause-menu map; `stream_enhanced` is read instead of `stream` on GTA V Enhanced | pf-hud (radar tile swap) |
| `html/dash_skins3d.js` | Each GTA dashboard's look for the 3D dial: face colour, fonts, numeral, tick and needle colours, sampled from the cars' in-game dial art | pf-hud (vehicle dial) |
| `data/dash_skins.lua` | Which dashboard look each vanilla model wears (spawn name to skin id) | pf-hud (vehicle dial) |
| `data/rpm_by_model.lua` | Each vanilla engine's idle and limiter in rpm, measured from GTA V's engine recordings, and a dial top per class | pf-hud (vehicle dial) |

Not copied: the original pack's 2D map sources and its server script; whip_core's car makers' logos.

pf-hud works without this resource: GTA's own radar tiles, every car on the dial as designed, and config.lua's rev
ranges.

## Rockstar Games material

The map, its shapes and heights, the radar tiles, the blip pictures, the dashboard looks and the rev ranges in this
resource are made from Grand Theft Auto V. They belong to Rockstar Games and Take-Two Interactive, not to WHIP or to
PF: no licence in this resource covers them or gives any rights to them. They are here only to be used with GTA V on
FiveM, as WHIP uses them, where Rockstar's terms for the platform apply (fivem.net/terms). This is why they live here,
in a private resource, and not in pf-hud, which is public.

The map's shapes are GTA V's map traced by Regynate
(gist.github.com/Regynate/01a82731994e592cbe5d7e1c1b055d33), with no licence stated. The 3D map data
(the shapes on the game's heights, read from GTA V's map collision) was built by 3D Clanker for WHIP.

Neither WHIP nor PF is affiliated with, endorsed or sponsored by Rockstar Games or Take-Two
Interactive. PF is not WHIP and is not made by WHIP's author.

## Code

The code here (`fxmanifest.lua`, and the few lines of script round the data in `html/dash_skins3d.js`) is under the
GNU Lesser General Public License 3.0 (`COPYING.LESSER`), with the GNU General Public License 3.0 it builds on in
`COPYING`, as the originals' code was.

WHIP's full notice is in whip_core's `NOTICE.md`, Copyright (c) 2026 Whippy.
