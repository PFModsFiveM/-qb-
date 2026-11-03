fx_version 'cerulean'
game 'gta5'
lua54 'yes'
author 'Kakarot'
description 'Provides police tools, evidence, job and more functionality for players to use as a cop'
version '1.3.5'

shared_scripts {
	'config.lua',
	'config_evidence.lua', -- evidence kinds, decay, integrity rules, caller allowlists
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
	'server/schema.lua', -- the resource's one migration list (fines v1, evidence v2)
	'server/fines.lua', -- /fine records and their sweep
	'server/commands.lua',
	'server/interactions.lua',
	'server/evidence/store.lua', -- evidence records, integrity, shared helpers
	'server/evidence/custody.lua', -- chain of custody and the inventory move recorder
	'server/evidence/scene.lua', -- persisted scene drops
	'server/evidence/api.lua', -- evidence exports and server events
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
