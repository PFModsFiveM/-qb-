-- pfm-media-map: WHIP's map media (GTA's blip icons, the 3D map's data, the HUD radar's dark tiles) and the vehicle
-- dial's data made from GTA's own (dashboard looks, rev ranges). Copies apart from names; see NOTICE.md.
-- Copyright (c) 2026 Whippy, from WHIP, LGPL-3.0; modified for PF (this manifest).
fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'PF (see NOTICE.md)'
description 'Map and HUD media: blip icons, 3D map data, dark radar tiles, vehicle dial data'
version '1.1.0'

-- Nothing runs: these are only files, read by pfm-pause's and pf-hud's pages at https://cfx-nui-pfm-media-map/...
-- and by pf-hud's client with LoadResourceFile('pfm-media-map', ...).
files {
    -- GTA's blip icons by sprite id: img/blips/<id>.webp
    'img/blips/*.webp',
    -- the 3D map: the 2D map's shapes standing on the game's heights (sets window.MAP3D_DATA)
    'map/map3d-data.js',
    -- pf-hud's vehicle dial: each GTA dashboard's look (sets window.PfDashSkins)
    'html/dash_skins3d.js',
    -- pf-hud's vehicle dial: which dashboard look each model wears, and each engine's measured rev range
    'data/dash_skins.lua',
    'data/rpm_by_model.lua',
}

-- stream/ (Legacy) and stream_enhanced/ (Enhanced, read instead of stream/): the HUD radar's dark tiles,
-- pfmap_<row>_<col>.ytd (the texture inside each is still named whipmap_<row>_<col>). Streamed, so never in files{};
-- pf-hud swaps GTA's minimap_sea_<row>_<col> for them while this resource is started.
