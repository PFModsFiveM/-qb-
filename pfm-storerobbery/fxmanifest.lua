fx_version 'cerulean'
game 'gta5'
lua54 'yes'
author 'Kakarot'
description 'Allows players to rob various stores on the map for money and items'
version '1.5.0'

ui_page 'html/index.html'

shared_scripts {
    'config.lua',
    '@pfm-core/shared/locale.lua',
    'locales/en.lua',
    'locales/*.lua'
}

client_script 'client/main.lua'
server_scripts {
    '@oxmysql/lib/MySQL.lua', -- reads the owner of a player-owned pf-stores shop that is robbed
    'server/main.lua'
}

files {
    'html/index.html',
    'html/script.js',
    'html/style.css',
    'html/reset.css'
}
