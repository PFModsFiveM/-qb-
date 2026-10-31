fx_version 'cerulean'
game 'gta5'
lua54 'yes'
author 'Kakarot'
description 'Employee management system allowing players to hire/fire other players'
version '2.2.0'

shared_scripts {
    '@pfm-core/shared/locale.lua',
    'locales/en.lua',
    'locales/*.lua',
    'config.lua',
}

client_scripts {
    'client/*.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/sv_boss.lua', -- the staff rules (PFManagement) and the boss menu
    'server/sv_gang.lua',
    'server/sv_app.lua'   -- the Boss app on the tablet and the computer (pf-devices)
}

files {
    'html/apps/boss.js',
    'html/apps/boss.css',
}
