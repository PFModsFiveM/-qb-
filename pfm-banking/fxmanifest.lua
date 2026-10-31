fx_version 'cerulean'
game 'gta5'
lua54 'yes'
author 'Kakarot'
description 'Allows players to deposit/withdraw money from their bank/job account and create shared accounts'
version '2.1.0'

shared_scripts {
    '@pfm-core/shared/locale.lua',
    'locales/en.lua',
    'locales/*.lua',
    'config.lua'
}

client_scripts {
    '@PolyZone/client.lua',
    '@PolyZone/BoxZone.lua',
    '@PolyZone/EntityZone.lua',
    '@PolyZone/CircleZone.lua',
    '@PolyZone/ComboZone.lua',
    'client.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    '@pfm-core/server/migrations.lua',
    'server_ledger.lua',
    'server.lua',
    'server_finance.lua',
    'server_accounts.lua',
    'server_shared_migration.lua',
    'server_branches.lua',   -- branch closures after robberies
    'server_characters.lua', -- clean-up when a character is deleted
    'server_app.lua'         -- the Bank app on the tablet and the computer (pf-devices)
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/script.js',
    'html/style.css',
    'html/apps/bank.js',
    'html/apps/bank.css',
}
