fx_version 'cerulean'
game 'gta5'
lua54 'yes'
author 'Kakarot'
description 'Allows players to work in the recycling plant for money'
version '2.2.0'

shared_scripts {
  '@pfm-core/shared/locale.lua',
  'locales/en.lua',
  'locales/*.lua',
  'config.lua'
}

client_script {
  'client.lua',
  '@PolyZone/client.lua',
  '@PolyZone/BoxZone.lua',
  '@PolyZone/CircleZone.lua'
}

server_scripts {
    '@pfm-banking/payouts.lua', -- job pay goes through the bank ledger (PFPayout)
    'server.lua'
}
