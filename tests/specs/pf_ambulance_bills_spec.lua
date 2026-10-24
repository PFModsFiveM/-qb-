-- pf-ambulancejob ([pfscripts] copy): hospital bills and the revive fee on the ledger
load_resource('tests/lua/ambulance_bill_cases.lua')
AmbulanceCases('pf-ambulancejob', { '[pfscripts]/pf-ambulancejob/config.lua', '[pfscripts]/pf-ambulancejob/server/main.lua' })
