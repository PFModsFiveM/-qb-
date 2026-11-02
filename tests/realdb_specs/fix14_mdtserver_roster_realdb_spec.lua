-- pf-policemdt-DEV roster, staff and audit statements on the real database (batch 14), on the MDT's
-- own install SQL:
--   * the roster reset copies every line to pf_mdt_roster_backup, keeps the lines people hold and
--     brings the default lines back (no duplicate-callsign error);
--   * firing a member of the department sets their players row unemployed, but only while that row
--     still holds the department's job; a former officer in another job keeps it;
--   * a roster line cannot take a citizen of another job;
--   * licence actions and charge changes are recorded in their audit tables.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
function GetResourceState(name) return name == 'pfm-banking' and 'started' or 'missing' end
promise = promise or { new = function() return { resolve = function(self, v) self.value = v end } end }
Citizen.Await = Citizen.Await or function(p) return p.value end

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('[pfscripts]/pf-policemdt-DEV/sql/pf-policemdt-qb.sql')
load_resource('pfm-core/server/migrations.lua')
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end

-- oxmysql's export API over the real database; an SQL error is logged and answered with nil, like oxmysql
local function ox(kind)
    return function(_, sql, params, cb)
        if Mock.callable(params) then cb, params = params, nil end
        local ok, r = pcall(MySQL[kind].await, sql, params)
        if not ok then print('oxmysql error: ' .. tostring(r)) r = nil end
        if cb then cb(r) end
        return r
    end
end
Mock.exportsByResource['oxmysql'] = { execute = ox('query'), query = ox('query'), fetch = ox('query'), insert = ox('insert'), update = ox('update'), scalar = ox('scalar'), single = ox('single') }

QBCoreMock.Shared.Jobs = { police = { label = 'Police', grades = { ['0'] = {}, ['1'] = {}, ['2'] = {}, ['3'] = {}, ['4'] = { isboss = true } } } }
function GetCurrentResourceName() return 'pf-policemdt-DEV' end
Config = nil
load_resource('[pfscripts]/pf-policemdt-DEV/shared/framework.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/config.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/server/access.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/server/main.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/server/sentencing.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/server/roster.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/server/officers.lua')
assert(PFMdtSentencing.Start(), 'pf-policemdt migrations')

local BOSS = 1
local function playerRow(cid, job)
    MySQL.query.await('DELETE FROM players WHERE citizenid = ?', { cid })
    MySQL.insert.await([[INSERT INTO players (citizenid, cid, license, name, money, charinfo, job, gang, position, metadata, inventory)
        VALUES (?, 1, ?, ?, '{}', ?, ?, '{}', '{}', ?, '[]')]],
        { cid, 'license:' .. cid, cid, json.encode({ firstname = 'F' .. cid, lastname = 'L' }), json.encode(job), json.encode({ licences = { driver = true, weapon = true } }) })
end
local function jobOf(cid)
    local j = MySQL.scalar.await('SELECT job FROM players WHERE citizenid = ?', { cid })
    return j and json.decode(j).name or nil
end
local function rosterLine(callsign, citizenid, name)
    MySQL.insert.await('INSERT INTO pf_mdt_roster (callsign, `rank`, officer_name, citizenid, unit_type, training_status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, NOW(), NOW())',
        { callsign, 'Officer', name or '', citizenid, 'Patrol', 'NONE' })
end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    Mock.gameTimer = Mock.gameTimer + 100000
    MySQL.query.await('DELETE FROM pf_mdt_roster')
    MySQL.query.await('DELETE FROM pf_mdt_roster_backup')
    MySQL.query.await('DELETE FROM pf_mdt_officer_mgmt_profiles')
    local b = Mock.newPlayer(BOSS, 'BOSS1')
    b.PlayerData.job = { name = 'police', onduty = true, isboss = true, grade = { level = 4 } }
    playerRow('BOSS1', b.PlayerData.job)
    playerRow('OFF2', { name = 'police', grade = { level = 1 } })
    playerRow('MECH9', { name = 'mechanic', grade = { level = 2 } })
    playerRow('EMS5', { name = 'ambulance', grade = { level = 4 } })
end

describe('roster reset', function()
    it('copies every line, keeps the held ones, and seeds the defaults again', function()
        rosterLine('1A-01', 'OFF2', 'Officer Two')   -- a default callsign someone holds
        rosterLine('X-99', nil, '')                  -- a vacant custom line
        local first = Mock.callCallback('pf_mdt:roster:resetCb', BOSS, {})
        assert_eq(first.confirmRequired, true)
        assert_eq(tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM pf_mdt_roster_backup')), 0)
        local res = Mock.callCallback('pf_mdt:roster:resetCb', BOSS, { token = first.token })
        assert_eq(res.success, true, tostring(res.error))
        local backup = MySQL.query.await('SELECT * FROM pf_mdt_roster_backup WHERE batch = ?', { res.backup })
        assert_eq(#backup, 2, 'both lines copied')
        assert_eq(backup[1].by_citizenid, 'BOSS1')
        local held = MySQL.single.await("SELECT * FROM pf_mdt_roster WHERE callsign = '1A-01'")
        assert_eq(held.citizenid, 'OFF2', 'the held line stays with its officer')
        assert_eq(MySQL.single.await("SELECT id FROM pf_mdt_roster WHERE callsign = 'X-99'"), nil, 'the vacant line is gone')
        assert_true(tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM pf_mdt_roster')) > 10, 'defaults are back')
    end)
end)

describe('roster lines and firing on the real players table', function()
    it("a line cannot take the EMS chief; it takes an officer of the department", function()
        rosterLine('2A-55', nil, '')
        local id = tonumber(MySQL.scalar.await("SELECT id FROM pf_mdt_roster WHERE callsign = '2A-55'"))
        local res = Mock.callCallback('pf_mdt:roster:updateRowCb', BOSS, { id = id, callsign = '2A-55', rank = 'Officer', citizenid = 'EMS5', officer_name = 'EMS Chief' })
        assert_eq(res.error, 'not_an_officer')
        res = Mock.callCallback('pf_mdt:roster:updateRowCb', BOSS, { id = id, callsign = '2A-55', rank = 'Officer', citizenid = 'OFF2', officer_name = 'Officer Two' })
        assert_eq(res.success, true, tostring(res.error))
        assert_eq(MySQL.scalar.await('SELECT citizenid FROM pf_mdt_roster WHERE id = ?', { id }), 'OFF2')
    end)
    it('firing an officer of the department sets the row unemployed', function()
        local res = Mock.callCallback('pf_mdt:officers:fire', BOSS, { citizenid = 'OFF2', reason = 'misconduct' })
        assert_eq(res.success, true, tostring(res.error))
        assert_eq(res.jobChanged, true)
        assert_eq(jobOf('OFF2'), 'unemployed')
        assert_eq(tonumber(MySQL.scalar.await("SELECT `terminated` FROM pf_mdt_officer_mgmt_profiles WHERE citizenid = 'OFF2'")), 1)
    end)
    it('a former officer now a mechanic leaves the roster and keeps the mechanic job', function()
        rosterLine('3B-07', 'MECH9', 'Old Officer')
        local res = Mock.callCallback('pf_mdt:officers:fire', BOSS, { citizenid = 'MECH9' })
        assert_eq(res.success, true, tostring(res.error))
        assert_eq(res.jobChanged, false)
        assert_eq(jobOf('MECH9'), 'mechanic')
        assert_eq(MySQL.scalar.await("SELECT citizenid FROM pf_mdt_roster WHERE callsign = '3B-07'"), nil, 'line vacated')
    end)
    it('the guarded update leaves a row that no longer holds the police job alone', function()
        -- the same statement fire runs, against a row that changed job meanwhile
        MySQL.update.await("UPDATE players SET job = ? WHERE citizenid = ? AND JSON_UNQUOTE(JSON_EXTRACT(job, '$.name')) = ?",
            { json.encode({ name = 'unemployed' }), 'MECH9', 'police' })
        assert_eq(jobOf('MECH9'), 'mechanic')
    end)
end)

describe('audit tables', function()
    it('a licence suspension is recorded and shows on the profile query', function()
        Mock.fireNet('pf_mdt:suspendLicense', BOSS, { citizenId = 'OFF2', licenseType = 'driver', durationDays = 3, reason = 'speeding' })
        local row = MySQL.single.await("SELECT * FROM pf_mdt_license_actions WHERE citizenid = 'OFF2'")
        assert_true(row ~= nil, 'recorded')
        assert_eq(row.action, 'suspend')
        assert_eq(row.reason, 'speeding')
        assert_eq(row.by_citizenid, 'BOSS1')
        assert_eq(row.by_job, 'police')
        local shown = MySQL.query.await('SELECT license_type, action, days, reason, by_name, by_job, at FROM pf_mdt_license_actions WHERE citizenid = ? ORDER BY id DESC LIMIT 25', { 'OFF2' })
        assert_eq(#shown, 1)
    end)
    it('a new charge is recorded with who made it', function()
        local res = Mock.callCallback('pf_mdt:createCharge', BOSS, { code = 'T14', name = 'Test charge', fine_amount = 250, bail_amount = 100, jail_time = 5 })
        assert_eq(res.success, true, tostring(res.error))
        local a = MySQL.single.await("SELECT * FROM pf_mdt_charge_audit WHERE code = 'T14'")
        assert_true(a ~= nil, 'recorded')
        assert_eq(a.action, 'create')
        assert_eq(a.by_citizenid, 'BOSS1')
        assert_eq(json.decode(a.after_json).fineAmount, 250)
        local over = Mock.callCallback('pf_mdt:createCharge', BOSS, { code = 'T15', name = 'Too much', fine_amount = 9999999 })
        assert_eq(over.success, false)
        assert_eq(MySQL.single.await("SELECT id FROM pf_mdt_charges WHERE code = 'T15'"), nil)
    end)
end)
