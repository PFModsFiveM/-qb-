fx_version 'cerulean'
game 'gta5'
lua54 'yes'
use_fxv2_oal 'yes'
author 'Kakarot'
description 'Allows players to rob banks and blow up power stations'
version '1.3.0'

shared_scripts {
    'sh_config.lua', -- Shared config
    '@pfm-core/shared/locale.lua',
    'locales/en.lua',
    'locales/*.lua'
}

client_scripts {
    '@PolyZone/client.lua',
    '@PolyZone/BoxZone.lua',
    'cl_config.lua', -- Client config
    'client/fleeca.lua',
    'client/pacific.lua',
    'client/powerstation.lua',
    'client/doors.lua',
    'client/paleto.lua'
}

server_scripts {
    'sv_config.lua', -- Server config
    'server/main.lua'
}

-- hacks and thermite are server-judged pfm-minigames challenges
dependencies {
    'PolyZone',
    'pfm-minigames',
}
