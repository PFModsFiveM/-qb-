fx_version 'cerulean'
game 'gta5'
lua54 'yes'
author 'Kakarot'
description 'Provides the logic for handling cryptocurrency aka qbit'
version '1.2.1'

shared_scripts {
    '@pfm-core/shared/locale.lua',
    'locales/en.lua',
    'locales/*.lua',
    'config.lua'
}
server_scripts {
    '@oxmysql/lib/MySQL.lua',
    '@pfm-banking/payouts.lua',
    'server/main.lua',
    'server/app.lua' -- the Crypto app on the tablet and the computer (pf-devices)
}
client_script 'client/main.lua'

files {
    'html/apps/crypto.js',
    'html/apps/crypto.css',
}

dependency 'pfm-minigames'
