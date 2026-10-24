-- pf-ambulancejob injury system on a real database: migrations, checked injury reports, scans by an
-- on-duty medic next to the patient, field treatment that uses up its item, and hospital treatment
-- clearing every injury.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
function GetResourceState() return 'started' end
GetInvokingResource = GetInvokingResource or function() return nil end
local health, armour = {}, {}
function GetEntityHealth(ped) return health[ped] or 200 end
function GetPedArmour(ped) return armour[ped] or 0 end

-- the bank (hospital bills go through the ledger)
RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
function GetCurrentResourceName() return 'pfm-banking' end
Config = nil
load_resource('pfm-banking/config.lua')
load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')
Mock.exportsByResource['pfm-banking'] = Mock.exportsByResource['__self']
assert(PFLedger.Start(), 'ledger start')

-- pf-ambulancejob
local items = {}   -- [src] = { [item] = count }
Mock.exportsByResource['pfm-inventory'] = {
    RemoveItem = function(_, src, item, n)
        local have = (items[src] or {})[item] or 0
        if have < (n or 1) then return false end
        items[src][item] = have - (n or 1)
        return true
    end,
    AddItem = function() return true end,
}
function GetCurrentResourceName() return 'pf-ambulancejob' end
Config = nil
load_resource('pfm-banking/payouts.lua')
load_resource('[pfscripts]/pf-ambulancejob/config.lua')
load_resource('[pfscripts]/pf-ambulancejob/shared/framework.lua')
load_resource('[pfscripts]/pf-ambulancejob/server/main.lua')
load_resource('[pfscripts]/pf-ambulancejob/server/injury_database.lua')
load_resource('[pfscripts]/pf-ambulancejob/server/injury_handler.lua')
load_resource('[pfscripts]/pf-ambulancejob/server/treatment.lua')
Config.WipeInventoryOnRespawn = false
assert(InjuryDB.Start(), 'injury tables')

local PATIENT, MEDIC = 1, 2
local function injuries(cid) return MySQL.query.await('SELECT * FROM player_injuries WHERE citizen_id = ? ORDER BY id', { cid or 'CID1' }) end
local function report(src, data)
    Mock.gameTimer = Mock.gameTimer + 5000   -- past the report cooldown
    Mock.fireNet('pf-ambulancejob:server:processDamage', src, data)
end
local function hit(injuryType, severity, zone) report(PATIENT, { injuryType = injuryType, severity = severity, bodyZone = zone or 'left_arm', health = 60, weapon = 'Knife' }) end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords, items = {}, {}, {}
    MySQL.query.await('DELETE FROM player_treatment_log')
    MySQL.query.await('DELETE FROM player_injuries')
    Mock.newPlayer(PATIENT).PlayerData.money = { cash = 0, bank = 5000 }
    Mock.newPlayer(MEDIC).PlayerData.job = { name = 'ambulance', type = 'ems', onduty = true }
    items[MEDIC] = { bandage = 2, firstaid = 1, ifaks = 1 }
    Mock.coords[PATIENT] = vector3(300.0, -580.0, 43.0)
    Mock.coords[MEDIC] = vector3(301.0, -580.0, 43.0)
end

describe('injury tables', function()
    it('are created by the migration, and rerunning it changes nothing', function()
        assert_true(InjuryDB.Start())
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = 'pf-ambulancejob'")), 1)
        local fk = MySQL.scalar.await([[SELECT DELETE_RULE FROM information_schema.REFERENTIAL_CONSTRAINTS
            WHERE CONSTRAINT_SCHEMA = DATABASE() AND TABLE_NAME = 'player_treatment_log']])
        assert_eq(fk, 'SET NULL')
    end)
    it('the database is not set up by a client event any more', function()
        assert_eq(Mock.netHandlers['pf-ambulancejob:initializeDatabase'], nil)
    end)
end)

describe('injury reports', function()
    it('are stored when every value is a known one', function()
        hit('laceration', 'moderate')
        local rows = injuries()
        assert_eq(#rows, 1)
        assert_eq(rows[1].injury_type, 'laceration')
        assert_eq(rows[1].body_zone, 'left_arm')
        assert_eq(rows[1].recorded_by, 'damage_detection')
    end)
    it('unknown types, severities, zones and non-tables are refused', function()
        hit('dragon_bite', 'moderate')
        hit('laceration', 'apocalyptic')
        hit('laceration', 'minor', 'third_arm')
        report(PATIENT, 'not a table')
        assert_eq(#injuries(), 0)
    end)
    it('are rate-limited per player', function()
        hit('laceration', 'minor')
        Mock.fireNet('pf-ambulancejob:server:processDamage', PATIENT, { injuryType = 'burn', severity = 'minor', bodyZone = 'torso' })
        assert_eq(#injuries(), 1)
    end)
    it('keep only the latest records per citizen', function()
        Config.DamageTracking.MaxStoredPerCitizen = 3
        for _ = 1, 5 do hit('laceration', 'minor') end
        Config.DamageTracking.MaxStoredPerCitizen = 50
        assert_eq(#injuries(), 3)
    end)
end)

describe('scanning a patient', function()
    local function scan(src)
        return Mock.callCallback('pf-ambulancejob:server:getInjuriesAndData', src, PATIENT)
    end
    it('an on-duty medic next to the patient sees the injuries', function()
        hit('gunshot_wound', 'severe', 'torso')
        local data = scan(MEDIC)
        assert_true(data.success)
        assert_eq(#data.injuries, 1)
        assert_eq(data.playerData.citizenid, 'CID1')
    end)
    it('not for other players, off-duty medics or from afar', function()
        hit('gunshot_wound', 'severe', 'torso')
        assert_false(scan(PATIENT).success)
        Mock.coords[MEDIC] = vector3(0, 0, 0)
        assert_false(scan(MEDIC).success)
        Mock.coords[MEDIC] = vector3(301.0, -580.0, 43.0)
        Mock.players[MEDIC].PlayerData.job.onduty = false
        assert_false(scan(MEDIC).success)
    end)
end)

describe('field treatment', function()
    local function treat(kind) Mock.fireNet('pf-ambulancejob:server:applyTreatment', MEDIC, PATIENT, kind) Mock.gameTimer = Mock.gameTimer + 10000 end
    it('uses up the item, removes what it treats and logs it', function()
        hit('laceration', 'moderate')
        hit('fracture', 'minor', 'left_leg')
        treat('bandage')
        local rows = injuries()
        assert_eq(#rows, 1)
        assert_eq(rows[1].injury_type, 'fracture')
        assert_eq(items[MEDIC].bandage, 1)
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM player_treatment_log WHERE treatment_type = 'bandage' AND treated_by = 'CID2'")), 1)
        assert_eq(#Mock.clientEventsNamed('pf-ambulancejob:client:applyTreatmentEffects'), 1)
    end)
    it('critical injuries need the hospital', function()
        hit('gunshot_wound', 'critical', 'torso')
        treat('bandage')
        assert_eq(#injuries(), 1)
        assert_eq(items[MEDIC].bandage, 2, 'no item used when there is nothing to treat')
    end)
    it('needs the item, an on-duty medic, closeness and a real treatment', function()
        hit('respiratory', 'moderate', 'torso')
        items[MEDIC].ifaks = 0
        treat('oxygen')                                   -- no item
        items[MEDIC].ifaks = 1
        treat('teleport')                                 -- no such treatment
        Mock.coords[MEDIC] = vector3(0, 0, 0)
        treat('oxygen')                                   -- too far
        Mock.coords[MEDIC] = vector3(301.0, -580.0, 43.0)
        Mock.players[MEDIC].PlayerData.job.onduty = false
        treat('oxygen')                                   -- off duty
        assert_eq(#injuries(), 1)
        assert_eq(items[MEDIC].ifaks, 1)
    end)
    it('the old unchecked revive event is gone', function()
        assert_eq(Mock.netHandlers['pf-ambulancejob:server:revivePlayerEvent'], nil)
        assert_eq(Mock.netHandlers['pf-ambulancejob:server:injuryScanComplete'], nil)
    end)
end)

describe('hospital treatment', function()
    it('a check-in bed clears every injury, critical ones too', function()
        hit('gunshot_wound', 'critical', 'torso')
        hit('burn', 'minor', 'right_arm')
        Mock.fireNet('hospital:server:SendToBed', PATIENT, 1, true, 1)
        assert_eq(#injuries(), 0)
        assert_eq(Mock.players[PATIENT].PlayerData.money.bank, 5000 - Config.BillCost)
    end)
    it('clearing a treated patient works with treatment log rows pointing at injuries', function()
        hit('laceration', 'minor')
        local id = injuries()[1].id
        MySQL.insert.await("INSERT INTO player_treatment_log (citizen_id, treatment_type, treated_by, injury_id) VALUES ('CID1', 'bandage', 'CID2', ?)", { id })
        assert_true(ClearCitizenInjuries('CID1') >= 1)
        assert_eq(MySQL.scalar.await("SELECT injury_id FROM player_treatment_log WHERE citizen_id = 'CID1'"), nil)
    end)
end)
