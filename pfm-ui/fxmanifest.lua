-- pfm-ui: controller (gamepad) support and shared UI assets for PF resources.
-- The controller code is ported from WHIP (whip_core), Copyright (c) 2026 Whippy, LGPL-3.0,
-- modified for PF. See NOTICE.md, COPYING.LESSER and COPYING.
fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'PF (controller code ported from WHIP by Whippy)'
description 'Controller support: pad state, button layout, NUI pad bridge and page library'
version '1.0.0'

shared_script 'config.lua'

client_scripts {
    'client/prefs.lua',
    'client/pad_state.lua',
    'client/pad_layout.lua',
}

-- lib/pad_bridge.lua is included by other resources ('@pfm-ui/lib/pad_bridge.lua'); the html files
-- are loaded by their pages from https://cfx-nui-pfm-ui/html/...
files {
    'lib/pad_bridge.lua',
    'html/pad.js',
    'html/pad.css',
    'html/tokens.css',
}
