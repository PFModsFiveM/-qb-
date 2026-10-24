-- pfm-ambulancejob ([qb]): hospital bills and the revive fee on the ledger
load_resource('tests/lua/ambulance_bill_cases.lua')
AmbulanceCases('pfm-ambulancejob', { 'pfm-ambulancejob/config.lua', 'pfm-ambulancejob/server/main.lua' })
