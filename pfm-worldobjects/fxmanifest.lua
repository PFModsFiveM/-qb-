fx_version 'cerulean'
game 'gta5'
lua54 'yes'
author 'PF Mods'
description 'Persistent world objects (delivery pallets and boxes) with their own stashes'
version '1.0.0'

dependencies {
    'pfm-core',
    'pfm-inventory',
    'oxmysql',
}

shared_scripts {
    'config.lua',
}

client_scripts {
    'client.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    '@pfm-core/server/migrations.lua',
    'server.lua',
}
