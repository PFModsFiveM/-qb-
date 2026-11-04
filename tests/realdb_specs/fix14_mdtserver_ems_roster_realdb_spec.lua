-- pf-emsmdt roster and staff statements on the real database (batch 14, EMS-01): the backup table
-- migration (server/schema.lua since batch 15), the reset (backup first, held lines kept, defaults back), and firing that changes a
-- players row only while it still holds the EMS job.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
function GetConvar(_, default) return default end
function GetResourceState() return 'missing' end
promise = promise or { new = function() return { resolve = function(self, v) self.value = v end } end }
Citizen.Await = Citizen.Await or function(p) return p.value end

RealDB.exec('pfm-core/qbcore.sql')
load_resource('pfm-core/server/migrations.lua')
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end
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
QBCoreMock.Shared.Jobs = { ambulance = { label = 'EMS', grades = { ['0'] = {}, ['1'] = {}, ['4'] = { isboss = true } } } }
QBCoreMock.Functions.GetPlayers = function() local out = {} for id in pairs(Mock.players) do out[#out + 1] = id end return out end

function GetCurrentResourceName() return 'pf-emsmdt' end
Config = nil
load_resource('[pfscripts]/pf-emsmdt/config.lua')
load_resource('[pfscripts]/pf-emsmdt/shared/framework.lua')
load_resource('[pfscripts]/pf-emsmdt/server/schema.lua')
load_resource('[pfscripts]/pf-emsmdt/server/main.lua')
load_resource('[pfscripts]/pf-emsmdt/server/officers.lua')
load_resource('[pfscripts]/pf-emsmdt/server/roster.lua')
SetTimeout = function() end

-- the roster and backup tables come from the schema (batch 15: v1 backups, v2 the roster); its start
-- thread does not run here
assert_eq(PFEmsSchema.Apply(), true)

local CHIEF = 1
local function playerRow(cid, job)
    MySQL.query.await('DELETE FROM players WHERE citizenid = ?', { cid })
    MySQL.insert.await([[INSERT INTO players (citizenid, cid, license, name, money, charinfo, job, gang, position, metadata, inventory)
        VALUES (?, 1, ?, ?, '{}', ?, ?, '{}', '{}', '{}', '[]')]],
        { cid, 'license:' .. cid, cid, json.encode({ firstname = 'F' .. cid, lastname = 'L' }), json.encode(job) })
end
local function jobOf(cid) return json.decode(MySQL.scalar.await('SELECT job FROM players WHERE citizenid = ?', { cid })).name end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    MySQL.query.await('DELETE FROM pf_emsmdt_roster')
    MySQL.query.await('DELETE FROM pf_emsmdt_roster_backup')
    local c = Mock.newPlayer(CHIEF, 'CHIEF1')
    c.PlayerData.job = { name = 'ambulance', onduty = true, isboss = true, grade = { level = 4 } }
    playerRow('CHIEF1', c.PlayerData.job)
    playerRow('MEDIC2', { name = 'ambulance', grade = { level = 1 } })
    playerRow('COP3', { name = 'police', grade = { level = 4 } })
end

describe('EMS roster on the real database', function()
    it('the backup migration can run again', function()
        assert_eq(RunMigrations('pf-emsmdt', PFEmsSchema.Migrations), true)
        for _, sql in ipairs(PFEmsSchema.Migrations[1].up) do MySQL.query.await(sql) end
    end)
    it('the reset copies every line, keeps the held one and seeds the defaults', function()
        MySQL.insert.await("INSERT INTO pf_emsmdt_roster (callsign, `rank`, officer_name, citizenid, unit_type) VALUES ('M-77', 'Paramedic', 'Medic Two', 'MEDIC2', 'Ambulance'), ('V-1', 'Paramedic', '', NULL, 'Ambulance')")
        local first = Mock.callCallback('pf_emsmdt:roster:resetCb', CHIEF, {})
        local res = Mock.callCallback('pf_emsmdt:roster:resetCb', CHIEF, { token = first.token })
        assert_eq(res.success, true, tostring(res.error))
        assert_eq(tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM pf_emsmdt_roster_backup WHERE batch = ?', { res.backup })), 2)
        assert_eq(MySQL.scalar.await("SELECT citizenid FROM pf_emsmdt_roster WHERE callsign = 'M-77'"), 'MEDIC2')
        assert_eq(MySQL.single.await("SELECT id FROM pf_emsmdt_roster WHERE callsign = 'V-1'"), nil)
        assert_true(tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM pf_emsmdt_roster')) > 2, 'defaults are back')
    end)
    it('firing a medic sets the row unemployed; a police chief on an EMS line keeps the police job', function()
        local res = Mock.callCallback('pf_emsmdt:officers:fire', CHIEF, { citizenid = 'MEDIC2', reason = 'x' })
        assert_eq(res.success, true, tostring(res.error))
        assert_eq(jobOf('MEDIC2'), 'unemployed')
        MySQL.insert.await("INSERT INTO pf_emsmdt_roster (callsign, `rank`, officer_name, citizenid, unit_type) VALUES ('M-88', 'Paramedic', 'Cop', 'COP3', 'Ambulance')")
        res = Mock.callCallback('pf_emsmdt:officers:fire', CHIEF, { citizenid = 'COP3', reason = 'x' })
        assert_eq(res.success, true, tostring(res.error))
        assert_eq(res.jobChanged, false)
        assert_eq(jobOf('COP3'), 'police')
        assert_eq(MySQL.scalar.await("SELECT citizenid FROM pf_emsmdt_roster WHERE callsign = 'M-88'"), nil)
    end)
end)
