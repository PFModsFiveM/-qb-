-- pfm-media-map: the pause menu's map assets (GTA's blip icons and the 3D map's data).
-- An unmodified copy apart from names; see NOTICE.md.
-- Copyright (c) 2026 Whippy, from WHIP, LGPL-3.0; modified for PF (this manifest).
fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'PF (see NOTICE.md)'
description 'Pause menu map assets: blip icons and the 3D map data'
version '1.0.0'

-- Nothing runs: these are only files, read by pfm-pause's page at https://cfx-nui-pfm-media-map/...
files {
    -- GTA's blip icons by sprite id: img/blips/<id>.webp
    'img/blips/*.webp',
    -- the 3D map: the 2D map's shapes standing on the game's heights (sets window.MAP3D_DATA)
    'map/map3d-data.js',
}
