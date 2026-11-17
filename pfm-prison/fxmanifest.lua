fx_version 'cerulean'
game 'gta5'
lua54 'yes'
use_fxv2_oal 'yes'
author 'Kakarot'
description 'Allows players to be jailed, escape from jail and work in jail'
version '2.3.0'

shared_scripts {
    '@pfm-core/shared/locale.lua',
    'locales/en.lua',
    'locales/*.lua',
    'config.lua',
    'config_facility.lua', -- cells, classification, routine, discipline, visitation (19D)
    'config_work.lua',     -- prison jobs, trust, commissary (19E)
}

client_scripts {
    '@PolyZone/client.lua',
    '@PolyZone/BoxZone.lua',
    '@PolyZone/EntityZone.lua',
    '@PolyZone/CircleZone.lua',
    '@PolyZone/ComboZone.lua',
    'client/main.lua',
    'client/jobs.lua',
    'client/prisonbreak.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',   -- pf_prison_* tables (server/schema.lua, migrations key 'pfm-prison')
    '@pfm-banking/payouts.lua', -- job pay goes through the bank ledger (PFPayout)
    'server/main.lua',
    'server/schema.lua',
    'server/justice_bridge.lua', -- pf-justice orders: intake, release, IsInside, forwarders
    'server/facility.lua',       -- intake, cells, classification, housing, SetLockdown, GetFacilityStatus (19D)
    'server/schedule.lua',       -- daily routine, headcounts, meals (19D)
    'server/discipline.lua',     -- infractions, hearings, sanctions (19D)
    'server/visitation.lua',     -- visit bookings and the visit room (19D)
    'server/work.lua',           -- prison jobs and credits (19E)
    'server/economy.lua',        -- trust accounts, commissary, restitution (19E)
    'server/security.lua',       -- doors, alarms, searches, escapes (19F)
}
