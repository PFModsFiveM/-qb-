-- pf-emsmdt (EMS MDT) server hardening: civilian reports near the caller, medic-only and on-duty
-- actions, bounded inputs, and staff actions limited to EMS staff of a lower rank.
load_resource('tests/lua/fivem_mocks.lua')
function IsDuplicityVersion() return true end
function GetConvar(_, default) return default end
function GetResourceState() return 'started' end
QBCore = QBCoreMock
-- FiveM promises (the fake database answers at once, so a resolved value is all Await needs)
promise = promise or { new = function() return { resolve = function(self, v) self.value = v end } end }
Citizen = Citizen or {}
Citizen.Await = Citizen.Await or function(p) return p.value end
QBCoreMock.Functions.GetPlayers = function() local out = {} for id in pairs(Mock.players) do out[#out + 1] = id end return out end

-- fake oxmysql: answers by SQL text, records every statement
local db = { log = {}, players = {}, roster = {}, profiles = {} }
local function answer(sql, params)
    db.log[#db.log + 1] = { sql = sql, params = params }
    if sql:find('SELECT job FROM players WHERE citizenid', 1, true) then
        local p = db.players[params[1]]
        return p and { { job = json.encode(p.job) } } or {}
    end
    if sql:find('SELECT 1 AS ok FROM players WHERE citizenid', 1, true) then
        return db.players[params[1]] and { { ok = 1 } } or {}
    end
    if sql:find('AS r, (SELECT COUNT(*)', 1, true) then
        return { { r = db.roster[params[1]] and 1 or 0, s = db.profiles[params[2]] and 1 or 0 } }
    end
    return {}
end
local function call(sql, params, cb)
    if type(params) == 'function' then cb, params = params, {} end
    local r = answer(sql, params or {})
    if cb then cb(r) end
    return r
end
Mock.exportsByResource['oxmysql'] = {
    execute = function(_, sql, params, cb) return call(sql, params, cb) end,
    query = function(_, sql, params, cb) return call(sql, params, cb) end,
    fetch = function(_, sql, params, cb) return call(sql, params, cb) end,
    insert = function(_, sql, params, cb) call(sql, params) if type(cb) == 'function' then cb(1) end return 1 end,
    update = function(_, sql, params, cb) call(sql, params) if type(cb) == 'function' then cb(1) end return 1 end,
    scalar = function(_, sql, params, cb) call(sql, params) if type(cb) == 'function' then cb(0) end return 0 end,
}
local function ran(fragment)
    local n = 0
    for _, e in ipairs(db.log) do if e.sql:find(fragment, 1, true) then n = n + 1 end end
    return n
end
local function lastParams(fragment)
    for i = #db.log, 1, -1 do if db.log[i].sql:find(fragment, 1, true) then return db.log[i].params end end
end

function GetCurrentResourceName() return 'pf-emsmdt' end
Config = nil
load_resource('[pfscripts]/pf-emsmdt/config.lua')
load_resource('[pfscripts]/pf-emsmdt/shared/framework.lua')
load_resource('[pfscripts]/pf-emsmdt/server/main.lua')
load_resource('[pfscripts]/pf-emsmdt/server/officers.lua')
load_resource('[pfscripts]/pf-emsmdt/server/roster.lua')
load_resource('[pfscripts]/pf-emsmdt/server/sop.lua')
SetTimeout = function(ms, fn) if (ms or 0) <= 1000 then fn() end end   -- short timers (call-list broadcast) at once; 8 s UI timeouts never

local CIVIL, MEDIC, CHIEF, OTHER = 1, 2, 3, 4
local HERE = vector3(300.0, -580.0, 43.0)
local function medicJob(level, onduty) return { name = 'ambulance', type = 'ems', onduty = onduty ~= false, grade = { level = level } } end
local function sent(name, target)
    local n = 0
    for _, e in ipairs(Mock.clientEventsNamed(name)) do if target == nil or e.target == target then n = n + 1 end end
    return n
end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords = {}, {}
    db.log, db.players, db.roster, db.profiles = {}, {}, {}, {}
    Mock.gameTimer = (Mock.gameTimer or 0) + 100000
    Mock.newPlayer(CIVIL)
    Mock.newPlayer(MEDIC).PlayerData.job = medicJob(1)
    Mock.newPlayer(CHIEF).PlayerData.job = medicJob(5)
    Mock.newPlayer(OTHER)
    for src in pairs(Mock.players) do Mock.coords[src] = HERE end
end

describe('civilian reports', function()
    it('a 911 call far from the caller is ignored; one near them reaches medics', function()
        Mock.fireNet('pf_emsmdt_dispatch:server:Create911Call', CIVIL, { description = 'someone is hurt', coords = { x = -2000.0, y = 3000.0, z = 30.0 } })
        assert_eq(sent('pf_emsmdt:dispatch:newCall'), 0)
        Mock.gameTimer = Mock.gameTimer + 100000
        Mock.fireNet('pf_emsmdt_dispatch:server:Create911Call', CIVIL, { description = 'someone is hurt', coords = { x = HERE.x, y = HERE.y, z = HERE.z } })
        assert_true(sent('pf_emsmdt:dispatch:newCall', MEDIC) >= 1)
        assert_eq(sent('pf_emsmdt:dispatch:newCall', CIVIL), 0)
    end)
    it("the police MDT's /911 reaches EMS when it matches an EMS 911 type", function()
        local at = { x = HERE.x, y = HERE.y, z = HERE.z }
        -- OTHER, not CIVIL: the 911 cooldown is in real seconds and CIVIL called in the test above
        Mock.fireNet('pf_mdt_dispatch:server:Create911Call', OTHER, { description = 'hello there', coords = at })
        assert_eq(sent('pf_emsmdt:dispatch:newCall'), 0)
        Mock.fireNet('pf_mdt_dispatch:server:Create911Call', OTHER, { description = 'shots fired near the bank', coords = at })
        assert_true(sent('pf_emsmdt:dispatch:newCall', MEDIC) >= 1)
    end)
    it('a non-table 911 payload does nothing', function()
        Mock.fireNet('pf_emsmdt_dispatch:server:Create911Call', CIVIL, 'hello')
        assert_eq(sent('pf_emsmdt:dispatch:newCall'), 0)
    end)
end)

describe('medic-only and on-duty actions', function()
    it('the roster reload is no longer a client event', function()
        assert_eq(Mock.netHandlers['pf_emsmdt:server:RosterUpdated'], nil)
    end)
    it('profiles: medics only, a clean callsign and an https avatar', function()
        Mock.fireNet('pf_emsmdt_dispatch:server:SaveProfile', CIVIL, { callsign = 'M-1' })
        assert_eq(Mock.players[CIVIL].PlayerData.metadata.callsign, nil)
        Mock.fireNet('pf_emsmdt_dispatch:server:SaveProfile', MEDIC, { callsign = '<img src=x>', avatarUrl = 'javascript:alert(1)', status = 'available' })
        assert_eq(Mock.players[MEDIC].PlayerData.metadata.callsign, nil)
        assert_eq(Mock.players[MEDIC].PlayerData.metadata.mdt_avatar, nil)
        assert_eq(Mock.players[MEDIC].PlayerData.metadata.mdt_status, 'available')
        Mock.gameTimer = Mock.gameTimer + 5000
        Mock.fireNet('pf_emsmdt_dispatch:server:SaveProfile', MEDIC, { callsign = 'MED-12', avatarUrl = 'https://example.com/a.png' })
        assert_eq(Mock.players[MEDIC].PlayerData.metadata.callsign, 'MED-12')
        assert_eq(Mock.players[MEDIC].PlayerData.metadata.mdt_avatar, 'https://example.com/a.png')
    end)
    it('patient search is bounded', function()
        Mock.callCallback('pf_emsmdt:searchPatients', MEDIC, { query = 'a', page = 1, pageSize = 100000 })
        local p = lastParams('SELECT citizenid, charinfo FROM players WHERE charinfo LIKE')
        assert_eq(p[3], 25)
        assert_eq(Mock.callCallback('pf_emsmdt:searchPatients', CIVIL, { query = 'a' }).error, 'not_allowed')
    end)
    it('patient notes: on duty, for a real citizen', function()
        db.players.CID1 = { job = { name = 'unemployed' } }
        Mock.players[MEDIC].PlayerData.job.onduty = false
        Mock.fireNet('pf_emsmdt:addPatientNote', MEDIC, { citizenId = 'CID1', text = 'note' })
        Mock.players[MEDIC].PlayerData.job.onduty = true
        Mock.fireNet('pf_emsmdt:addPatientNote', MEDIC, { citizenId = 'NOSUCH', text = 'note' })
        assert_eq(ran('INSERT INTO pf_emsmdt_patient_notes'), 0)
        Mock.gameTimer = Mock.gameTimer + 5000
        Mock.fireNet('pf_emsmdt:addPatientNote', MEDIC, { citizenId = 'CID1', text = 'note' })
        assert_eq(ran('INSERT INTO pf_emsmdt_patient_notes'), 1)
    end)
    it('citizen lookup by server id needs an on-duty medic next to them', function()
        assert_eq(Mock.callCallback('pf-emsmdt:server:getCitizenData', CIVIL, OTHER), nil)
        Mock.coords[OTHER] = vector3(0, 0, 0)
        assert_eq(Mock.callCallback('pf-emsmdt:server:getCitizenData', MEDIC, OTHER), nil)
        Mock.coords[OTHER] = HERE
        assert_eq(Mock.callCallback('pf-emsmdt:server:getCitizenData', MEDIC, OTHER).citizenid, 'CID4')
    end)
    it('bulletins go to medics only', function()
        Mock.callCallback('pf_emsmdt_dispatch:server:CreateBulletin', CHIEF, { title = 'Shift', body = 'Briefing at 6' })
        assert_eq(sent('pf_emsmdt:client:bulletinCreated', CIVIL), 0)
        assert_eq(sent('pf_emsmdt:client:bulletinCreated', MEDIC), 1)
    end)
end)

describe('staff management', function()
    local function fire(actor, cid) return Mock.callCallback('pf_emsmdt:officers:fire', actor, { citizenid = cid, reason = 'test' }) end
    it('cannot fire someone who is not EMS staff', function()
        db.players.CID4 = { job = { name = 'police', grade = { level = 0 } } }
        assert_eq(fire(CHIEF, 'CID4').error, 'not_staff')
        assert_eq(ran('UPDATE players SET job'), 0)
    end)
    it('cannot fire an equal or higher rank, or yourself', function()
        db.players.CID9 = { job = medicJob(5) }
        assert_eq(fire(CHIEF, 'CID9').error, 'rank_too_high')
        assert_eq(fire(CHIEF, 'CID3').error, 'cannot_fire_self')
        assert_eq(ran('UPDATE players SET job'), 0)
    end)
    it('can fire a lower-ranked medic', function()
        db.players.CID2 = { job = medicJob(1) }
        assert_eq(fire(CHIEF, 'CID2').success, true)
        assert_eq(ran('UPDATE players SET job'), 1)
    end)
    it('viewing a non-staff profile creates no staff record', function()
        db.players.CID4 = { job = { name = 'police' } }
        assert_eq(Mock.callCallback('pf_emsmdt:officers:get', MEDIC, { citizenid = 'CID4' }).error, 'not_staff')
        assert_eq(ran('INSERT IGNORE INTO `pf_emsmdt_staff_mgmt_profiles`'), 0)
    end)
    it('discipline only for staff', function()
        db.players.CID4 = { job = { name = 'mechanic' } }
        assert_eq(Mock.callCallback('pf_emsmdt:officers:addDiscipline', CHIEF, { citizenid = 'CID4', type = 'warning', reason = 'x' }).error, 'not_staff')
    end)
end)
