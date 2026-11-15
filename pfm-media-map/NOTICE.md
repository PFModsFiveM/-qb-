# pfm-media-map: licence notice

This resource is an unmodified copy of WHIP's map media pack, apart from names: the resource's name,
the data file's name (`map/map3d-data.js`), the global it sets (`window.MAP3D_DATA`), its first
comment line and one path in its build notes. Nothing else in the data or the icons was changed.

    Copyright (c) 2026 Whippy, from WHIP, LGPL-3.0; modified for PF.

## What is in it

| Path | What |
|---|---|
| `img/blips/*.webp` | GTA's blip icons, one per sprite id (927), as used by the pause menu's map and legend |
| `map/map3d-data.js` | The 3D map: GTA V's 2D map shapes standing on the game's heights (3D Clanker's 3D map build) |

Not copied: the original pack's radar tiles (`stream/`, `stream_enhanced/`), its 2D map sources and its
server script.

## Rockstar Games material

The map, its shapes and heights, and the blip pictures in this resource are made from Grand Theft
Auto V. They belong to Rockstar Games and Take-Two Interactive, not to WHIP or to PF: no licence in
this resource covers them or gives any rights to them. They are here only to be used with GTA V on
FiveM, as WHIP uses them, where Rockstar's terms for the platform apply (fivem.net/terms).

The map's shapes are GTA V's map traced by Regynate
(gist.github.com/Regynate/01a82731994e592cbe5d7e1c1b055d33), with no licence stated. The 3D map data
(the shapes on the game's heights, read from GTA V's map collision) was built by 3D Clanker for WHIP.

Neither WHIP nor PF is affiliated with, endorsed or sponsored by Rockstar Games or Take-Two
Interactive. PF is not WHIP and is not made by WHIP's author.

## Code

The only code here, `fxmanifest.lua`, is under the GNU Lesser General Public License 3.0
(`COPYING.LESSER`), with the GNU General Public License 3.0 it builds on in `COPYING`, as the
original pack's code was.

WHIP's full notice is in whip_core's `NOTICE.md`, Copyright (c) 2026 Whippy.
