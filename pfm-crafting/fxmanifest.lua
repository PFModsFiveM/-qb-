fx_version 'cerulean'
game 'gta5'
lua54 'yes'
author 'Kakarot'
description 'Allows players to craft items and earn experience'
version '1.0.0'

shared_scripts {
    '@pfm-core/shared/locale.lua',
    'locales/en.lua',
    'locales/*.lua',
    'config.lua'
}

client_script 'client.lua'
server_scripts {
    'server.lua',
    'server_devices.lua' -- Crafting app on the tablet and the computer (pf-devices)
}

files { 'html/crafting.js', 'html/crafting.css' }
