fx_version 'cerulean'
game 'gta5'
lua54 'yes'
author 'Kakarot'
description 'Provides police tools, evidence, job and more functionality for players to use as a cop'
version '1.3.5'

shared_scripts {
	'config.lua',
	'@pfm-core/shared/locale.lua',
	'locales/en.lua',
	'locales/*.lua'
}

client_scripts {
	'@PolyZone/client.lua',
	'@PolyZone/BoxZone.lua',
	'@PolyZone/ComboZone.lua',
	'client/main.lua',
	'client/camera.lua',
	'client/interactions.lua',
	'client/job.lua',
	'client/heli.lua',
	'client/anpr.lua',
	'client/evidence.lua',
	'client/objects.lua',
	'client/tracker.lua',
	'client/gameplay.lua'
}

server_scripts {
	'@oxmysql/lib/MySQL.lua',
	'@pfm-banking/payouts.lua', -- job pay goes through the bank ledger (PFPayout)
	'server/main.lua',
	'server/commands.lua',
	'server/interactions.lua',
	'server/evidence.lua',
	'server/objects.lua',
	'server/vehicle.lua',
	'server/gameplay.lua',
}

ui_page 'html/index.html'

files {
	'html/index.html',
	'html/vue.min.js',
	'html/script.js',
	'html/tablet-frame.png',
	'html/fingerprint.png',
	'html/main.css',
	'html/vcr-ocd.ttf'
}
