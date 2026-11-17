-- pf-ambulancejob injury system on a real database: migrations, checked injury reports, scans by an
-- on-duty medic next to the patient, the legacy field-treatment event (a forwarder since 17B), and
-- hospital treatment clearing every injury.
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
-- the injury tables' migration (v1) lives in server/medical/schema.lua since batch 15
load_resource('[pfscripts]/pf-ambulancejob/server/medical/schema.lua')
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
-- since batch 16 the self-report writes no record (server/medical/ingest.lua decides injuries); a
-- record in the legacy table without an engine copy is still listed, treated and cleared here
local function hit(injuryType, severity, zone)
    MySQL.insert.await("INSERT INTO player_injuries (citizen_id, injury_type, severity, body_zone, weapon, recorded_by) VALUES ('CID1', ?, ?, ?, 'Knife', 'damage_detection')", { injuryType, severity, zone or 'left_arm' })
end

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
        -- v1 (these tables) plus the medical engine's v2/v3, all under the one 'pf-ambulancejob' key
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = 'pf-ambulancejob'")), 4)
        assert_eq(MySQL.scalar.await("SELECT name FROM pf_schema_migrations WHERE resource = 'pf-ambulancejob' AND version = 1"), 'injury records, treatment log, health snapshots')
        assert_true(RunMigrations('pf-ambulancejob', PFMed.Schema.Migrations))
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = 'pf-ambulancejob'")), 4)
        local fk = MySQL.scalar.await([[SELECT DELETE_RULE FROM information_schema.REFERENTIAL_CONSTRAINTS
            WHERE CONSTRAINT_SCHEMA = DATABASE() AND TABLE_NAME = 'player_treatment_log']])
        assert_eq(fk, 'SET NULL')
    end)
    it('the database is not set up by a client event any more', function()
        assert_eq(Mock.netHandlers['pf-ambulancejob:initializeDatabase'], nil)
    end)
end)

describe('injury reports', function()
    it('the old self-report is only a damage hint: it writes no injury record', function()
        report(PATIENT, { injuryType = 'laceration', severity = 'moderate', bodyZone = 'left_arm', health = 60, weapon = 'Knife' })
        assert_eq(#injuries(), 0)
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
    -- batch 17B: pf-ambulancejob:server:applyTreatment is a forwarder to the treatment engine
    -- (server/medical/treatment.lua, specs b17_medical_treatment*); the legacy player_injuries table is
    -- frozen since the 16B import, so the event no longer removes its rows or logs to player_treatment_log
    local function treat(kind) Mock.fireNet('pf-ambulancejob:server:applyTreatment', MEDIC, PATIENT, kind) end
    it('the legacy event leaves the frozen legacy tables and the items alone', function()
        hit('laceration', 'moderate')
        treat('bandage')
        assert_eq(#injuries(), 1)
        assert_eq(items[MEDIC].bandage, 2)
        assert_eq(tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM player_treatment_log')), 0)
        assert_eq(#Mock.clientEventsNamed('pf-ambulancejob:client:applyTreatmentEffects'), 0)
    end)
    it('the old unchecked revive event is gone', function()
        assert_eq(Mock.netHandlers['pf-ambulancejob:server:revivePlayerEvent'], nil)
        assert_eq(Mock.netHandlers['pf-ambulancejob:server:injuryScanComplete'], nil)
    end)
end)

describe('hospital treatment', function()
    -- batch 16: the check-in heal is a server revive token applied by the bed's AI timer (the reception,
    -- doctor-count and token flow are covered by b16_medical_downstate / b16_medical_legacy_events);
    -- here: the clear that the hospital bill path runs heals every recorded injury, critical ones too
    it('a hospital clear heals every injury, critical ones too', function()
        hit('gunshot_wound', 'critical', 'torso')
        hit('burn', 'minor', 'right_arm')
        ClearCitizenInjuries('CID1')
        assert_eq(#injuries(), 0)
    end)
    it('clearing a treated patient works with treatment log rows pointing at injuries', function()
        hit('laceration', 'minor')
        local id = injuries()[1].id
        MySQL.insert.await("INSERT INTO player_treatment_log (citizen_id, treatment_type, treated_by, injury_id) VALUES ('CID1', 'bandage', 'CID2', ?)", { id })
        assert_true(ClearCitizenInjuries('CID1') >= 1)
        assert_eq(MySQL.scalar.await("SELECT injury_id FROM player_treatment_log WHERE citizen_id = 'CID1'"), nil)
    end)
end)
