-- pf-emsmdt roster and staff (batch 14, EMS-01): the same chain as the police MDT. An EMS grade 4
-- wrote a police chief's citizenid into an EMS roster line, then fired that citizenid, and the police
-- chief became unemployed; a grade 4 could wipe the whole roster; the debug reset command had the
-- police MDT's name. Now:
--   * bulletins and SOP changes need the medic on duty too;
--   * a roster line takes only a member of the editor's department;
--   * firing changes the job of a member of the actor's department only (another job is never
--     touched), and every staff change needs the actor on duty;
--   * the reset is the boss's, in two steps, after a backup, and keeps the lines people hold;
--   * the debug reset command is console-only and has its own name.
load_resource('tests/lua/fivem_mocks.lua')
function IsDuplicityVersion() return true end
function GetConvar(_, default) return default end
function GetResourceState() return 'started' end
QBCore = QBCoreMock
promise = promise or { new = function() return { resolve = function(self, v) self.value = v end } end }
Citizen = Citizen or {}
Citizen.Await = Citizen.Await or function(p) return p.value end
QBCoreMock.Functions.GetPlayers = function() local out = {} for id in pairs(Mock.players) do out[#out + 1] = id end return out end
QBCoreMock.Shared.Jobs.ambulance = { label = 'EMS', grades = { ['0'] = {}, ['1'] = {}, ['2'] = {}, ['3'] = {}, ['4'] = { isboss = true } } }

local db = { log = {}, players = {}, roster = {}, profiles = {}, line = nil }
local function answer(sql, params)
    db.log[#db.log + 1] = { sql = sql, params = params }
    if sql:find('SELECT job FROM players WHERE citizenid', 1, true) then
        local p = db.players[params[1]]
        return p and { { job = json.encode(p.job) } } or {}
    end
    if sql:find('AS r, (SELECT COUNT(*)', 1, true) then
        return { { r = db.roster[params[1]] and 1 or 0, s = db.profiles[params[2]] and 1 or 0 } }
    end
    if sql:find('SELECT callsign, rank, unit_type, training_status FROM pf_emsmdt_roster WHERE citizenid', 1, true) then
        return db.ownLine and { db.ownLine } or {}
    end
    if sql:find('FROM pf_emsmdt_roster WHERE id = ?', 1, true) then
        local l = db.line or {}
        return { { id = params[1], citizenid = l.citizenid, rank = l.rank or 'Paramedic', callsign = 'M-1' } }
    end
    return {}
end
local function call(sql, params, cb)
    if Mock.callable(params) then cb, params = params, {} end
    local r = answer(sql, params or {})
    if cb then cb(r) end
    return r
end
Mock.exportsByResource['oxmysql'] = {
    execute = function(_, sql, params, cb) return call(sql, params, cb) end,
    query = function(_, sql, params, cb) return call(sql, params, cb) end,
    fetch = function(_, sql, params, cb) return call(sql, params, cb) end,
    insert = function(_, sql, params, cb) call(sql, params) if Mock.callable(cb) then cb(1) end return 1 end,
    update = function(_, sql, params, cb) call(sql, params) if Mock.callable(cb) then cb(1) end return 1 end,
    scalar = function(_, sql, params, cb) call(sql, params) if Mock.callable(cb) then cb(0) end return 0 end,
}
Mock.exportsByResource['pfm-core'].RunMigrations = function() return true end
local function ran(fragment)
    local n = 0
    for _, e in ipairs(db.log) do if e.sql:find(fragment, 1, true) then n = n + 1 end end
    return n
end
local function firstIndex(fragment)
    for i, e in ipairs(db.log) do if e.sql:find(fragment, 1, true) then return i end end
end

function GetCurrentResourceName() return 'pf-emsmdt' end
Config = nil
load_resource('[pfscripts]/pf-emsmdt/config.lua')
load_resource('[pfscripts]/pf-emsmdt/shared/framework.lua')
load_resource('[pfscripts]/pf-emsmdt/server/main.lua')
load_resource('[pfscripts]/pf-emsmdt/server/officers.lua')
load_resource('[pfscripts]/pf-emsmdt/server/roster.lua')
load_resource('[pfscripts]/pf-emsmdt/server/sop.lua')
SetTimeout = function(ms, fn) if (ms or 0) <= 1000 then fn() end end

local CHIEF, MEDIC, POLICECHIEF, SUPERVISOR, FIRECHIEF = 1, 2, 3, 4, 5
local function job(name, level, onduty, isboss) return { name = name, onduty = onduty ~= false, isboss = isboss == true, grade = { level = level } } end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    db.log, db.players, db.roster, db.profiles, db.line, db.ownLine = {}, {}, {}, {}, nil, nil
    Mock.gameTimer = (Mock.gameTimer or 0) + 100000
    Mock.newPlayer(CHIEF).PlayerData.job = job('ambulance', 5, true, true)
    Mock.newPlayer(MEDIC).PlayerData.job = job('ambulance', 1)
    Mock.newPlayer(POLICECHIEF).PlayerData.job = job('police', 4, true, true)
    Mock.newPlayer(SUPERVISOR).PlayerData.job = job('ambulance', 4) -- grade 4: may edit the roster, not the boss
    Mock.newPlayer(FIRECHIEF).PlayerData.job = job('fire', 4)
    QBCoreMock.Shared.Jobs.ambulance.grades['5'] = { isboss = true } -- the boss is grade 5 on this server
end

local function fire(actor, cid) return Mock.callCallback('pf_emsmdt:officers:fire', actor, { citizenid = cid, reason = 'test' }) end
local function updateRow(actor, data) return Mock.callCallback('pf_emsmdt:roster:updateRowCb', actor, data) end

describe('EMS roster lines', function()
    it("a line cannot take the police chief's citizenid", function()
        local res = updateRow(CHIEF, { id = 4, callsign = 'M-4', rank = 'Paramedic', citizenid = 'CID3', officer_name = 'Police Chief' })
        assert_eq(res.success, false)
        assert_eq(res.error, 'not_an_officer')
        assert_eq(ran('UPDATE pf_emsmdt_roster SET'), 0)
    end)
    it('a line takes a medic of the department', function()
        local res = updateRow(CHIEF, { id = 4, callsign = 'M-4', rank = 'Paramedic', citizenid = 'CID2', officer_name = 'Medic Two' })
        assert_eq(res.success, true, tostring(res.error))
        assert_eq(ran('UPDATE pf_emsmdt_roster SET'), 1)
    end)
    it("the chief's line is the boss's; a line held by the same rank is not a non-boss's", function()
        db.line = { rank = 'EMS Chief' }
        assert_eq(updateRow(SUPERVISOR, { id = 1, callsign = 'C-1', rank = 'EMS Chief', officer_name = 'Me' }).error, 'protected_chief')
        db.line = { rank = 'Supervisor', citizenid = 'CID1' }
        assert_eq(updateRow(SUPERVISOR, { id = 2, callsign = 'S-1', rank = 'Supervisor', officer_name = 'Me' }).error, 'rank_too_high')
        assert_eq(ran('UPDATE pf_emsmdt_roster SET'), 0)
    end)
    it("the chief's rank through employment is the boss's too", function()
        local res = Mock.callCallback('pf_emsmdt:officers:updateEmployment', SUPERVISOR, { citizenid = 'CID2', callsign = 'M-9', rank = 'EMS Chief' })
        assert_eq(res.error, 'protected_chief')
        db.ownLine = { callsign = 'C-1', rank = 'EMS Chief' }
        assert_eq(Mock.callCallback('pf_emsmdt:officers:updateEmployment', SUPERVISOR, { citizenid = 'CID2', callsign = 'C-1', rank = 'Paramedic' }).error, 'protected_chief')
        assert_eq(ran('INSERT INTO pf_emsmdt_roster ('), 0)
        assert_eq(ran('UPDATE pf_emsmdt_roster SET callsign'), 0)
        db.ownLine = nil
        res = Mock.callCallback('pf_emsmdt:officers:updateEmployment', CHIEF, { citizenid = 'CID2', callsign = 'M-9', rank = 'EMS Chief' })
        assert_eq(res.success, true, tostring(res.error))
    end)
    it('a supervisor off duty cannot change the roster', function()
        Mock.players[CHIEF].PlayerData.job.onduty = false
        assert_eq(updateRow(CHIEF, { id = 4, callsign = 'M-4', rank = 'Paramedic', citizenid = 'CID2', officer_name = 'Medic Two' }).error, 'no_permission')
        assert_eq(ran('UPDATE pf_emsmdt_roster SET'), 0)
    end)
end)

describe('EMS staff actions stay in the department', function()
    it("firing the police chief (written into an EMS line before) only removes them from the EMS records", function()
        db.roster.CID3 = true
        local res = fire(CHIEF, 'CID3')
        assert_eq(res.success, true, tostring(res.error))
        assert_eq(res.jobChanged, false)
        assert_eq(Mock.players[POLICECHIEF].PlayerData.job.name, 'police', 'online: still police')
        assert_eq(ran('UPDATE players SET job'), 0)
        -- offline: the players row says police, and it is not written either
        db.log = {}
        db.players.CID3 = { job = { name = 'police', grade = { level = 4 } } }
        Mock.players[POLICECHIEF] = nil
        res = fire(CHIEF, 'CID3')
        assert_eq(res.jobChanged, false)
        assert_eq(ran('UPDATE players SET job'), 0)
    end)
    it('someone who is neither EMS nor on an EMS line cannot be fired', function()
        assert_eq(fire(CHIEF, 'CID3').error, 'not_staff')
    end)
    it('the fire chief cannot fire a medic (another department of the same MDT)', function()
        assert_eq(fire(FIRECHIEF, 'CID2').error, 'other_department')
        assert_eq(Mock.callCallback('pf_emsmdt:officers:addDiscipline', FIRECHIEF, { citizenid = 'CID2', type = 'warning', reason = 'x' }).error, 'other_department')
        assert_eq(Mock.players[MEDIC].PlayerData.job.name, 'ambulance')
    end)
    it('a medic of the department is fired from that job only', function()
        local res = fire(CHIEF, 'CID2')
        assert_eq(res.success, true, tostring(res.error))
        assert_eq(res.jobChanged, true)
        local p
        for i = #db.log, 1, -1 do if db.log[i].sql:find('UPDATE players SET job', 1, true) then p = db.log[i].params break end end
        assert_eq(p[3], 'ambulance', 'only while the row still holds the EMS job')
    end)
    it('staff actions need the actor on duty', function()
        Mock.players[CHIEF].PlayerData.job.onduty = false
        assert_eq(fire(CHIEF, 'CID2').error, 'off_duty')
        assert_eq(Mock.callCallback('pf_emsmdt:officers:setFlags', CHIEF, { citizenid = 'CID2', status = 'SUSPENDED' }).error, 'off_duty')
        assert_eq(ran('UPDATE players SET job'), 0)
    end)
end)

describe('EMS roster reset', function()
    it('boss only, two steps, and a backup before the lines nobody holds are removed', function()
        assert_eq(Mock.callCallback('pf_emsmdt:roster:resetCb', SUPERVISOR, {}).error, 'no_permission', 'grade 4 is not the boss')
        assert_eq(Mock.callCallback('pf_emsmdt:roster:resetCb', MEDIC, {}).error, 'no_permission')
        local first = Mock.callCallback('pf_emsmdt:roster:resetCb', CHIEF, {})
        assert_eq(first.confirmRequired, true)
        assert_eq(ran('pf_emsmdt_roster_backup'), 0)
        local done = Mock.callCallback('pf_emsmdt:roster:resetCb', CHIEF, { token = first.token })
        assert_eq(done.success, true, tostring(done.error))
        local backup, delete = firstIndex('INSERT INTO pf_emsmdt_roster_backup'), firstIndex('DELETE FROM pf_emsmdt_roster')
        assert_true(backup ~= nil and delete ~= nil and backup < delete, 'copied first')
        assert_true(db.log[delete].sql:find('citizenid IS NULL', 1, true) ~= nil, 'only lines nobody holds')
    end)
    it('the debug command is console-only and named for the EMS MDT', function()
        assert_eq(Mock.rawCommands['pfmdt_roster_reset'], nil)
        local cmd = Mock.rawCommands['pfemsmdt_roster_reset']
        assert_true(cmd ~= nil)
        cmd(CHIEF)
        assert_eq(ran('pf_emsmdt_roster_backup'), 0)
        cmd(0)
        assert_eq(ran('INSERT INTO pf_emsmdt_roster_backup'), 1)
    end)
end)

describe('other EMS changes need duty', function()
    it('a bulletin or an SOP change from a supervisor who clocked off is refused', function()
        Mock.players[CHIEF].PlayerData.job.onduty = false
        local res = Mock.callCallback('pf_emsmdt_dispatch:server:CreateBulletin', CHIEF, { title = 'Notice', message = 'x' })
        assert_eq(res.error, 'off_duty')
        res = Mock.callCallback('pf_emsmdt:createSOP', CHIEF, { title = 'SOP', category = 'General', procedure = 'x' })
        assert_eq(res.error, 'no_permission')
        assert_eq(ran('INSERT INTO `pf_emsmdt_sops`') + ran('INSERT INTO pf_emsmdt_sops'), 0)
        assert_eq(ran('pf_emsmdt_bulletins (') , 0)
    end)
end)
