-- pf-mechanicjob management on a real database (server/schema.lua, server/management.lua):
--  migrations  on an existing install: staff rows get their shop from the character's job, the one
--              global settings row becomes the default shop's, duplicate POS catalog rows are
--              merged under a (business, item_id) key; rerunning is safe (MECH-7, MECH-X8, MECH-X9);
--  MECH-1/X6   hiring is a job offer: nobody's job changes until they accept it themselves; offline
--              citizens can be offered a job; an answer counts once, an expired or withdrawn offer
--              not at all; ownership goes only to staff;
--  MECH-7      a role belongs to one shop: a manager who moves to another shop starts there as an
--              employee (hire, login upsert, job change);
--  MECH-X8     business settings are per shop and validated.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
QBCore = QBCoreMock
function GetResourceState() return 'missing' end

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-garages/player_vehicles.sql')
RealDB.exec('[pfscripts]/pf-mechanicjob/pf_mechanic.sql')
load_resource('pfm-core/server/migrations.lua')

-- an existing install before this change: one global settings row, staff rows without a shop,
-- a catalog without its unique key and with a duplicate
local function player(cid, job, grade, first)
    MySQL.query.await('INSERT INTO players (citizenid, cid, license, name, money, charinfo, job, gang, position, metadata) VALUES (?, 1, ?, ?, ?, ?, ?, ?, ?, ?)', {
        cid, 'license:' .. cid, cid, '{}', json.encode({ firstname = first or cid, lastname = 'Doe' }),
        json.encode({ name = job, grade = { level = grade }, onduty = true }), '{}', '{}', '{}' })
end
player('BOSS1', 'mechanic', 4, 'Bea')
player('MGR1', 'mechanic', 2, 'Max')
player('COP1', 'police', 3, 'Cole')
player('OFF1', 'ambulance', 1, 'Olive')
MySQL.query.await("INSERT INTO pf_business_employees (citizenid, name, role) VALUES ('BOSS1', 'Bea Doe', 'owner'), ('MGR1', 'Max Doe', 'manager')")
MySQL.query.await("UPDATE pf_business_settings SET business_name = 'Old Global', blip_name = 'Old Blip', blip_color = 5 WHERE id = 1")
MySQL.query.await('ALTER TABLE pf_pos_items DROP INDEX unique_business_item')
MySQL.query.await("INSERT INTO pf_pos_items (business, item_id, category, label, price) VALUES ('mechanic', 'oil', 'S', 'Oil', 10), ('mechanic', 'oil', 'S', 'Oil', 10), ('mechanic2', 'oil', 'S', 'Oil', 12)")

Config = nil
load_resource('[pfscripts]/pf-mechanicjob/config.lua')
load_resource('[pfscripts]/pf-mechanicjob/shared/debug.lua')
Config.Debug = false
local grades = {}
for g = 0, 4 do grades[tostring(g)] = { name = g >= 2 and 'Manager' .. g or 'G' .. g, isboss = g == 4 or nil } end
QBCoreMock.Shared.Jobs.mechanic = { label = 'Mechanic', grades = grades }
QBCoreMock.Shared.Jobs.mechanic2 = { label = 'Mechanic 2', grades = grades }
load_resource('[pfscripts]/pf-mechanicjob/server/schema.lua')
do
    local said = {}
    local realPrint = print
    print = function(...) said[#said + 1] = table.concat({ ... }, ' ') end
    local ok = PFMech.CoreSchema()
    print = realPrint
    assert(ok, 'core migrations: ' .. table.concat(said, ' | '))
end
load_resource('[pfscripts]/pf-mechanicjob/server/management.lua')

local BOSS, MGR, COP, OFF = 1, 2, 3, 4
local function online(src, cid, job, grade)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.job = { name = job, grade = { level = grade }, isboss = grade == 4, onduty = true }
    p.PlayerData.charinfo = { firstname = cid, lastname = 'Doe' }
    p.Functions.SetJob = function(name, g)
        p.PlayerData.job = { name = name, grade = { level = tonumber(g) or 0 }, onduty = true }
        MySQL.update.await('UPDATE players SET job = ? WHERE citizenid = ?', { json.encode(p.PlayerData.job), cid })
        Mock.fireEvent('QBCore:Server:OnJobUpdate', nil, src, p.PlayerData.job)
        return true
    end
    return p
end
local function row(cid) return MySQL.single.await('SELECT * FROM pf_business_employees WHERE citizenid = ?', { cid }) end
local function offer(cid, business) return MySQL.single.await('SELECT * FROM pf_mech_job_offers WHERE citizenid = ? AND business = ?', { cid, business or 'mechanic' }) end
local function hire(src, who) return Mock.callCallback('pf_mech:management:hire', src, who) end
local function answer(src, id, accept) Mock.fireNet('pf_mech:management:respondOffer', src, id, accept) end
local function jobName(cid) return json.decode(MySQL.scalar.await('SELECT job FROM players WHERE citizenid = ?', { cid })).name end

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 1000
    Mock.players, Mock.coords = {}, {}
    online(BOSS, 'BOSS1', 'mechanic', 4)
    online(MGR, 'MGR1', 'mechanic', 2)
    MySQL.query.await('DELETE FROM pf_mech_job_offers')
end

describe('migrations on an existing install', function()
    it('staff rows get their shop, the global settings row goes to the default shop, duplicates merge', function()
        assert_eq(row('BOSS1').business, 'mechanic')
        assert_eq(row('MGR1').business, 'mechanic')
        local s = MySQL.query.await('SELECT business, business_name FROM pf_business_settings')
        assert_eq(#s, 1)
        assert_eq(s[1].business, 'mechanic')
        assert_eq(s[1].business_name, 'Old Global')
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_pos_items WHERE business = 'mechanic' AND item_id = 'oil'")), 1)
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_pos_items WHERE business = 'mechanic2' AND item_id = 'oil'")), 1)
        local ok = pcall(MySQL.query.await, "INSERT INTO pf_pos_items (business, item_id, category, label, price) VALUES ('mechanic', 'oil', 'S', 'Oil', 10)")
        assert_false(ok, 'the unique key refuses a second copy')
        MySQL.query.await("INSERT IGNORE INTO pf_pos_items (business, item_id, category, label, price) VALUES ('mechanic', 'oil', 'S', 'Oil', 10)")
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_pos_items WHERE business = 'mechanic' AND item_id = 'oil'")), 1)
    end)

    it('can run again, and from scratch when the SQL import never ran', function()
        MySQL.query.await("DELETE FROM pf_schema_migrations WHERE resource = 'pf-mechanicjob:core'")
        assert_true(PFMech.CoreSchema())
        assert_true(PFMech.CoreSchema())
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = 'pf-mechanicjob:core'")), 6)
        assert_eq(#MySQL.query.await('SELECT * FROM pf_business_settings'), 1)
    end)
end)

describe('MECH-1 / MECH-X6 job offers', function()
    it('an offer to an offline citizen changes nothing until they log in and accept', function()
        assert_eq(hire(BOSS, 'OFF1'), true)
        assert_eq(jobName('OFF1'), 'ambulance')
        local o = offer('OFF1')
        assert_eq(o.status, 'pending')
        assert_eq(o.offered_by, 'BOSS1')
        local p = online(OFF, 'OFF1', 'ambulance', 1)
        Mock.fireNet('QBCore:Server:OnPlayerLoaded', OFF)
        local shown = Mock.clientEventsNamed('pf_mech:offers:show')
        assert_eq(#shown, 1, 'asked after login')
        assert_eq(shown[1].target, OFF)
        assert_eq(shown[1].args[1][1].id, o.id)
        answer(OFF, o.id, true)
        assert_eq(p.PlayerData.job.name, 'mechanic')
        assert_eq(p.PlayerData.job.grade.level, 0)
        assert_eq(offer('OFF1').status, 'accepted')
        assert_eq(row('OFF1').business, 'mechanic')
        assert_eq(row('OFF1').role, 'employee')
    end)

    it('an officer standing next to the boss keeps their job until they say yes', function()
        local cop = online(COP, 'COP1', 'police', 3)
        assert_eq(hire(BOSS, tostring(COP)), true)           -- by server id
        assert_eq(cop.PlayerData.job.name, 'police')
        assert_eq(#Mock.clientEventsNamed('pf_mech:offers:show'), 1, 'asked at once')
        answer(COP, offer('COP1').id, false)
        assert_eq(cop.PlayerData.job.name, 'police')
        assert_eq(offer('COP1').status, 'declined')
    end)

    it('an answer counts once; an expired, withdrawn or someone else\'s offer not at all', function()
        local off = online(OFF, 'OFF1', 'ambulance', 1)
        local cop = online(COP, 'COP1', 'police', 3)
        hire(BOSS, 'OFF1')
        local id = offer('OFF1').id
        answer(COP, id, true)                                -- not theirs
        assert_eq(cop.PlayerData.job.name, 'police')
        MySQL.update.await('UPDATE pf_mech_job_offers SET expires_at = DATE_SUB(NOW(), INTERVAL 1 HOUR) WHERE id = ?', { id })
        answer(OFF, id, true)
        assert_eq(off.PlayerData.job.name, 'ambulance', 'expired')
        Mock.clock = Mock.clock + 10
        hire(BOSS, 'OFF1')                                   -- offered again: open again
        assert_eq(offer('OFF1').status, 'pending')
        assert_true(Mock.callCallback('pf_mech:management:cancelOffer', BOSS, id))
        answer(OFF, id, true)
        assert_eq(off.PlayerData.job.name, 'ambulance', 'withdrawn')
        Mock.clock = Mock.clock + 10
        hire(BOSS, 'OFF1')
        answer(OFF, id, true)
        answer(OFF, id, true)
        assert_eq(off.PlayerData.job.name, 'mechanic')
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_mech_job_offers WHERE citizenid = 'OFF1'")), 1)
    end)

    it('refusals: not a manager, unknown citizen, already staff, too fast', function()
        local emp = online(5, 'EMP1', 'mechanic', 0)
        player('EMP1', 'mechanic', 0, 'Emil')
        assert_eq(select(2, hire(5, 'OFF1')), 'not_authorized')
        assert_eq(select(2, hire(BOSS, 'NOBODY99')), 'citizen_not_found')
        Mock.clock = Mock.clock + 10
        assert_eq(select(2, hire(BOSS, 'MGR1')), 'already_employed')
        assert_eq(select(2, hire(BOSS, 'OFF1')), 'slow_down')
        assert_eq(emp.PlayerData.job.name, 'mechanic')
    end)

    it("the shop's managers see its offers", function()
        player('NEW1', 'unemployed', 0, 'Nia')
        assert_eq(hire(BOSS, 'NEW1'), true)
        local list = Mock.callCallback('pf_mech:management:offers', BOSS)
        assert_eq(#list, 1)
        assert_eq(list[1].citizenid, 'NEW1')
        assert_eq(list[1].name, 'Nia Doe')
        assert_eq(list[1].status, 'pending')
        assert_true(list[1].hoursLeft >= 70)
    end)

    it('ownership goes to staff only', function()
        online(COP, 'COP1', 'police', 3)
        Mock.fireNet('pf_mechanic:transferOwnership', BOSS, 'COP1')
        assert_eq(Mock.players[COP].PlayerData.job.name, 'police')
        assert_eq(Mock.players[BOSS].PlayerData.job.name, 'mechanic')
    end)
end)

describe('MECH-7 a role belongs to one shop', function()
    it('a manager who leaves and is hired at another shop starts there as an employee', function()
        assert_true(IsEmployeeManager('MGR1', 'mechanic'))
        local mgr = Mock.players[MGR]
        mgr.Functions.SetJob('unemployed', 0)                -- quits through city hall
        assert_eq(row('MGR1').role, 'employee', 'the role ended with the job')
        online(10, 'BOSS2', 'mechanic2', 4)
        player('BOSS2', 'mechanic2', 4, 'Bo')
        MySQL.query.await("INSERT INTO pf_business_employees (citizenid, name, role, business) VALUES ('BOSS2', 'Bo Doe', 'owner', 'mechanic2')")
        hire(10, 'MGR1')
        answer(MGR, offer('MGR1', 'mechanic2').id, true)
        assert_eq(mgr.PlayerData.job.name, 'mechanic2')
        assert_false(IsEmployeeManager('MGR1', 'mechanic2'))
        Mock.clock = Mock.clock + 10
        assert_eq(select(2, hire(MGR, 'OFF1')), 'not_authorized', 'no manager powers at the new shop')
    end)

    it("the shop's boss by grade manages it even with a plain employee row", function()
        player('BIGB1', 'mechanic3', 4, 'Big')
        MySQL.query.await("INSERT INTO pf_business_employees (citizenid, name, role, business) VALUES ('BIGB1', 'Big Doe', 'employee', 'mechanic3')")
        QBCoreMock.Shared.Jobs.mechanic3 = { label = 'Mechanic 3', grades = grades }
        assert_true(IsEmployeeManager('BIGB1', 'mechanic3'))
        assert_false(IsEmployeeManager('BIGB1', 'mechanic'), 'not at another shop')
    end)

    it('a role kept on the row from another shop never counts (login upsert resets it)', function()
        player('ROAM1', 'mechanic2', 0, 'Rom')
        MySQL.query.await("INSERT INTO pf_business_employees (citizenid, name, role, business) VALUES ('ROAM1', 'Rom Doe', 'manager', 'mechanic')")
        assert_false(IsEmployeeManager('ROAM1', 'mechanic2'))
        online(11, 'ROAM1', 'mechanic2', 0)
        Mock.fireNet('QBCore:Server:OnPlayerLoaded', 11)
        assert_eq(row('ROAM1').business, 'mechanic2')
        assert_eq(row('ROAM1').role, 'employee')
    end)
end)

describe('MECH-X8 business settings per shop', function()
    local function saveSettings(src, data) return Mock.callCallback('pf_mech:management:saveSettings', src, data) end
    it("one shop's manager changes only that shop, with checked values", function()
        online(10, 'BOSS2', 'mechanic2', 4)
        assert_eq(saveSettings(10, { business_name = '', blip_name = 'B', blip_color = 3 }), false)
        assert_eq(saveSettings(10, { business_name = 'Two', blip_name = 'B', blip_color = 99 }), false)
        assert_eq(saveSettings(10, { business_name = string.rep('x', 65), blip_name = 'B', blip_color = 3 }), false)
        assert_true(saveSettings(10, { business_name = ' Shop Two ', blip_name = 'Two Blip', blip_color = 12 }))
        assert_eq(GetBusinessSettings('mechanic2').business_name, 'Shop Two')
        assert_eq(GetBusinessSettings('mechanic').business_name, 'Old Global', 'the other shop is untouched')
        local mgr = Mock.callCallback('pf_mechanic:getSettings', 10)
        assert_eq(mgr.blip_color, 12)
        assert_eq(saveSettings(MGR, { business_name = 'Mine', blip_name = 'M', blip_color = 1 }), true)
        assert_eq(GetBusinessSettings('mechanic').business_name, 'Mine')
        assert_eq(GetBusinessSettings('mechanic2').business_name, 'Shop Two')
    end)
end)
