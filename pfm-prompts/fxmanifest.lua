-- pfm-prompts: in-world interaction prompts (a key badge and a label drawn on the thing itself).
-- The 3D renderer and its DUI pages are ported from WHIP: Copyright (c) 2026 Whippy, from WHIP,
-- LGPL-3.0; modified for PF. See NOTICE.md, COPYING.LESSER and COPYING.
fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'PF (3D prompt renderer ported from WHIP by Whippy)'
description 'In-world interaction prompts: key badge and label drawn on doors, props and points'
version '1.0.0'
license 'LGPL-3.0-or-later'

client_scripts {
    'config.lua',
    'client/world_quad.lua',
    'client/dui_page.lua',
    'client/style.lua',
    'client/keys.lua',
    'client/registry.lua',
    'client/render_world.lua',
    'client/render_screen.lua',
    'client/main.lua',
}

files {
    'html/*.html',
    'html/css/*.css',
    'html/js/*.js',
    'html/fonts/*.woff2',
}
