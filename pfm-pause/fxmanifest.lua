-- pfm-pause: PF's pause menu, in place of GTA's pause screen. The page is ported (Copyright (c) 2026 Whippy, from WHIP,
-- LGPL-3.0; modified for PF): see NOTICE.md, COPYING.LESSER and COPYING.
-- Uses pfm-media-map (the map's blip icons and 3D data), and pfm-ui (settings, controller layout) when it runs.
fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'PF (see NOTICE.md)'
description 'Pause menu: 3D map with blips and waypoints, controller layout, server settings, help and report, swap character, leave'
version '2.0.0'

dependency 'pfm-media-map'

shared_script 'config.lua'
client_script 'client/main.lua'
server_script 'server/main.lua'

ui_page 'html/index.html'

-- html/preview.html is a browser preview for development and is not sent.
files {
    'html/index.html',
    'html/css/*.css',
    'html/js/*.js',
    'html/js/map3d/*.js',
    'html/js/vendor/*.js',
    'html/img/pad/*.svg',
    'html/fonts/*.woff2',
}
