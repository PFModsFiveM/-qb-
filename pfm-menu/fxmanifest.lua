fx_version 'cerulean'
game 'gta5'
lua54 'yes'
author 'Kakarot'
description 'Menu of options for players to interact with to do certain tasks'
version '1.2.0'

client_scripts {
    '@pfm-ui/lib/pad_bridge.lua', -- controller support (works without pfm-ui running)
    'client/main.lua',
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/script.js',
    'html/style.css'
}
