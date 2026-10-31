fx_version 'cerulean'
game 'gta5'
lua54 'yes'
author 'Kakarot'
description 'Allows players to dive and search for materials underwater to sell'
version '1.2.1'

shared_script {
    '@pfm-core/shared/locale.lua',
    'locales/en.lua',
    'locales/*.lua',
    'config.lua'
}

server_scripts {
    '@pfm-banking/payouts.lua', -- job pay goes through the bank ledger (PFPayout)
    'server/main.lua'
}

files { 'html/diveguide.js' } -- Dive Guide app (pf-devices)

client_scripts {
    '@PolyZone/client.lua',
    '@PolyZone/BoxZone.lua',
    'client/main.lua'
}
