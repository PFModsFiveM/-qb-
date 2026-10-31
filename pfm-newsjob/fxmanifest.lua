fx_version 'cerulean'
game 'gta5'
lua54 'yes'
author 'Kakarot'
description 'Weazel News field work: duty point, news van and helicopter (server-granted), camera and mics; connected to the pf-news newsroom'
version '1.5.0'

shared_scripts {
    'config.lua',
    '@pfm-core/shared/locale.lua',
    'locales/en.lua',
    'locales/*.lua',
}

client_scripts {
    'client/main.lua',
    'client/spawner.lua',
    'client/camera.lua',
}

server_script 'server/main.lua'
