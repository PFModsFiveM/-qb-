-- pf-policemdt-DEV access model (batch 14):
--   * every MDT action that changes something needs the officer on duty (QBCore duty) and the grade
--     from one table, Config.Permissions; reads stay open off duty;
--   * the handlers follow that table (a changed grade in the config is the grade that applies),
--     report approval works for every rank at or above it (grades 5/6 were refused);
--   * an incident is changed or closed only by its author, an officer listed on it or a supervisor;
--   * photo and image URLs are https on an allowed host, checked on the server;
--   * charge values are capped and every change is recorded;
--   * licence actions are recorded (who, what, why), removal needs its grade;
--   * a roster line takes only an officer of the editor's department, firing changes the job of a
--     member of the actor's department only, the reset is the boss's, confirmed and backed up, and
--     the debug reset command is console-only with its own name;
--   * a camera is reported offline only by an officer near it.
load_resource('tests/lua/fivem_mocks.lua')
function IsDuplicityVersion() return true end
function GetResourceState() return 'missing' end
QBCore = QBCoreMock
promise = promise or { new = function() return { resolve = function(self, v) self.value = v end } end }
Citizen.Await = Citizen.Await or function(p) return p.value end

-- fake oxmysql: answers by SQL text, records every statement
local db = { log = {}, players = {}, incidents = {}, roster = {}, staff = {} }
local function answer(sql, params)
    db.log[#db.log + 1] = { sql = sql, params = params }
    if sql:find('SELECT job FROM players WHERE citizenid', 1, true) then
        local p = db.players[params[1]]
        return p and { { job = json.encode(p.job) } } or {}
    end
    if sql:find('SELECT metadata FROM players WHERE citizenid', 1, true) then
        local p = db.players[params[1]]
        return p and { { metadata = json.encode(p.metadata or {}) } } or {}
    end
    if sql:find('SELECT createdBy', 1, true) then
        local r = db.incidents[params[1]]
        return r and { r } or {}
    end
    if sql:find('AS r, (SELECT COUNT(*)', 1, true) then
        return { { r = db.roster[params[1]] and 1 or 0, s = db.staff[params[1]] and 1 or 0 } }
    end
    if sql:find('FROM pf_mdt_roster WHERE id = ?', 1, true) then
        return { { id = params[1], citizenid = db.rosterLine and db.rosterLine.citizenid or nil, rank = db.rosterLine and db.rosterLine.rank or 'Officer', callsign = '101' } }
    end
    if sql:find('SELECT * FROM pf_mdt_officer_mgmt_profiles', 1, true) then return { { terminated = 0 } } end
    if sql:find('FROM pf_mdt_charges WHERE id = ?', 1, true) then
        return { { id = params[1], code = 'C1', name = 'Charge', description = '', fineAmount = 100, bailAmount = 0, prisonTime = 0, category = 'General' } }
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
    insert = function(_, sql, params, cb) call(sql, params) if Mock.callable(cb) then cb(7) end return 7 end,
    update = function(_, sql, params, cb) call(sql, params) if Mock.callable(cb) then cb(1) end return 1 end,
    scalar = function(_, sql, params, cb) call(sql, params) if Mock.callable(cb) then cb(0) end return 0 end,
}
Mock.exportsByResource['pfm-core'].RunMigrations = function() return true end
local function ran(fragment)
    local n = 0
    for _, e in ipairs(db.log) do if e.sql:find(fragment, 1, true) then n = n + 1 end end
    return n
end
local function lastParams(fragment)
    for i = #db.log, 1, -1 do if db.log[i].sql:find(fragment, 1, true) then return db.log[i].params end end
end
local function firstIndex(fragment)
    for i, e in ipairs(db.log) do if e.sql:find(fragment, 1, true) then return i end end
end

function GetCurrentResourceName() return 'pf-policemdt-DEV' end
Config = nil
load_resource('[pfscripts]/pf-policemdt-DEV/shared/framework.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/config.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/server/access.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/server/main.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/server/sentencing.lua') -- the resource's migrations (roster backup table)
assert(PFMdtSentencing.Start(), 'migrations')
load_resource('[pfscripts]/pf-policemdt-DEV/server/roster.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/server/sop.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/server/officers.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/server/cctv.lua')
local DEFAULT_PERMS = json.decode(json.encode(Config.Permissions))
local DEFAULT_LICENSES = json.decode(json.encode(Config.Licenses))

QBCoreMock.Shared.Jobs.police = { label = 'Police', grades = { ['0'] = {}, ['1'] = {}, ['2'] = {}, ['3'] = {}, ['4'] = { isboss = true } } }

local BOSS, OFFICER, SGT, CIVIL, EMSCHIEF, DEPUTY, OFFICER2 = 1, 2, 3, 4, 5, 6, 7
local function setJob(src, name, grade, onduty)
    local p = Mock.players[src]
    p.PlayerData.job = { name = name, label = name, onduty = onduty ~= false, isboss = false, grade = { level = grade, name = 'g' .. grade } }
    db.players[p.PlayerData.citizenid] = { job = p.PlayerData.job, metadata = p.PlayerData.metadata }
end
local GOOD_URL = 'https://cdn.discordapp.com/attachments/1/2/photo.png?ex=abc&is=def&hm=0a1b'

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    Mock.gameTimer = Mock.gameTimer + 100000
    db.log, db.players, db.incidents, db.roster, db.staff, db.rosterLine = {}, {}, {}, {}, {}, nil
    Config.Permissions = json.decode(json.encode(DEFAULT_PERMS))
    Config.Licenses = json.decode(json.encode(DEFAULT_LICENSES))
    Mock.newPlayer(BOSS); setJob(BOSS, 'police', 4); Mock.players[BOSS].PlayerData.job.isboss = true
    Mock.newPlayer(OFFICER); setJob(OFFICER, 'police', 1)
    Mock.newPlayer(SGT); setJob(SGT, 'police', 3)
    Mock.newPlayer(CIVIL); setJob(CIVIL, 'unemployed', 0)
    Mock.newPlayer(EMSCHIEF); setJob(EMSCHIEF, 'ambulance', 4)
    Mock.newPlayer(DEPUTY); setJob(DEPUTY, 'sheriff', 4)
    Mock.newPlayer(OFFICER2); setJob(OFFICER2, 'police', 1)
    for src in pairs(Mock.players) do Mock.coords[src] = vector3(100.0, 100.0, 30.0) end
end

describe('on duty for every change', function()
    it('an officer who clocked off cannot write records; on duty they can', function()
        Mock.players[OFFICER].PlayerData.job.onduty = false
        Mock.fireNet('pf_mdt:addCitizenNote', OFFICER, { citizenId = 'CID4', text = 'seen downtown' })
        Mock.fireNet('pf_mdt:createWarrant', OFFICER, { warrantId = 'W1', suspect = 'X', charges = {} })
        assert_eq(ran('pf_mdt_citizen_notes'), 0)
        assert_eq(ran('pf_mdt_warrants'), 0)
        local notes = Mock.clientEventsNamed('QBCore:Notify')
        assert_eq(notes[#notes].args[1], 'You must be on duty to do that')
        Mock.players[OFFICER].PlayerData.job.onduty = true
        Mock.fireNet('pf_mdt:addCitizenNote', OFFICER, { citizenId = 'CID4', text = 'seen downtown' })
        assert_eq(ran('INSERT INTO pf_mdt_citizen_notes'), 1)
    end)
    it('a callback that changes something answers off_duty', function()
        Mock.players[SGT].PlayerData.job.onduty = false
        local res = Mock.callCallback('pf_mdt:updateProfilePicture', SGT, { citizenId = 'CID4', url = GOOD_URL })
        assert_eq(res.success, false)
        assert_eq(res.error, 'off_duty')
        assert_eq(ran('pf_mdt_citizen_profiles'), 0)
    end)
    it('reading stays open off duty', function()
        Mock.players[OFFICER].PlayerData.job.onduty = false
        local res = Mock.callCallback('pf_mdt:getAllCharges', OFFICER, {})
        assert_eq(type(res), 'table')
        assert_eq(res.error, nil)
    end)
    it('a civilian is still refused everything', function()
        local res = Mock.callCallback('pf_mdt:updateProfilePicture', CIVIL, { citizenId = 'CID4', url = GOOD_URL })
        assert_eq(res.error, 'no_access')
    end)
end)

describe('one permission table', function()
    it('report approval: grade 3 and above (grade 5 was refused before), not below', function()
        Mock.fireNet('pf_mdt:approveReport', OFFICER, { reportId = 'RPT-1' })
        assert_eq(ran('UPDATE pf_mdt_reports SET approvalStatus'), 0)
        Mock.fireNet('pf_mdt:approveReport', SGT, { reportId = 'RPT-1' })
        assert_eq(ran('UPDATE pf_mdt_reports SET approvalStatus'), 1)
        setJob(BOSS, 'police', 5)
        Mock.fireNet('pf_mdt:approveReport', BOSS, { reportId = 'RPT-2' })
        assert_eq(ran('UPDATE pf_mdt_reports SET approvalStatus'), 2)
    end)
    it('the grade in the config is the grade the handler uses (charges at 3, officer management at 3)', function()
        assert_eq(Mock.callCallback('pf_mdt:updateCharge', SGT, { id = 1, fineAmount = 200 }).success, false)
        Config.Permissions.manageCharges.police = 3
        local res = Mock.callCallback('pf_mdt:updateCharge', SGT, { id = 1, fineAmount = 200 })
        assert_true(res.error ~= 'Insufficient permissions', tostring(res.error))
        assert_eq(ran('UPDATE pf_mdt_charges'), 1)

        assert_eq(Mock.callCallback('pf_mdt:officers:fire', SGT, { citizenid = 'CID2' }).error, 'no_permission')
        Config.Permissions.manageOfficers.police = 3
        local fired = Mock.callCallback('pf_mdt:officers:fire', SGT, { citizenid = 'CID2' })
        assert_eq(fired.success, true, tostring(fired.error))
    end)
    it('removing a licence needs its grade; suspending is open to every officer, and both are recorded', function()
        Mock.fireNet('pf_mdt:removeLicense', OFFICER, { citizenId = 'CID4', licenseType = 'weapon' })
        assert_eq(ran('pf_mdt_license_actions'), 0)
        Mock.fireNet('pf_mdt:suspendLicense', OFFICER, { citizenId = 'CID4', licenseType = 'driver', durationDays = 2, reason = 'reckless driving' })
        local p = lastParams('INSERT INTO pf_mdt_license_actions')
        assert_true(p ~= nil, 'the suspension is recorded')
        assert_eq(p[1], 'CID4')
        assert_eq(p[3], 'suspend')
        assert_eq(p[5], 'reckless driving')
        assert_eq(p[6], 'CID2', 'who did it')
        Mock.fireNet('pf_mdt:removeLicense', SGT, { citizenId = 'CID4', licenseType = 'weapon' })
        assert_eq(lastParams('INSERT INTO pf_mdt_license_actions')[3], 'remove')
    end)
    it('with RequireReason a suspension without a reason is refused', function()
        Config.Licenses.RequireReason = true
        Mock.fireNet('pf_mdt:suspendLicense', OFFICER, { citizenId = 'CID4', licenseType = 'driver', durationDays = 2 })
        assert_eq(ran('pf_mdt_license_actions'), 0)
        assert_eq(ran('UPDATE players SET metadata'), 0)
    end)
end)

describe('incidents belong to their author', function()
    it('another officer cannot change or close it; the author and a supervisor can', function()
        db.incidents['INC-1'] = { createdBy = 'CID2' }
        Mock.fireNet('pf_mdt:updateIncident', OFFICER2, { id = 'INC-1', title = 'mine now' })
        Mock.fireNet('pf_mdt:closeIncident', OFFICER2, { id = 'INC-1' })
        assert_eq(ran('UPDATE pf_mdt_incidents'), 0)
        Mock.fireNet('pf_mdt:updateIncident', OFFICER, { id = 'INC-1', title = 'Robbery at the Fleeca' })
        assert_eq(ran('UPDATE pf_mdt_incidents'), 1)
        Mock.fireNet('pf_mdt:closeIncident', SGT, { id = 'INC-1' })
        assert_eq(ran('UPDATE pf_mdt_incidents'), 2)
    end)
    it('an officer listed on the incident can work on it too', function()
        db.incidents['INC-2'] = { createdBy = 'CID2', involvedOfficerIds = json.encode({ 'CID7' }) }
        Mock.fireNet('pf_mdt:updateIncident', OFFICER2, { id = 'INC-2', description = 'added my part' })
        assert_eq(ran('UPDATE pf_mdt_incidents'), 1)
    end)
    it('an incident that does not exist is not written', function()
        Mock.fireNet('pf_mdt:updateIncident', SGT, { id = 'INC-404', title = 'x' })
        assert_eq(ran('UPDATE pf_mdt_incidents'), 0)
    end)
end)

describe('image URLs', function()
    it('only https on an allowed host, with nothing that can break out of the page', function()
        local U = PFMdtAccess.ImageUrl
        assert_eq(U(GOOD_URL), GOOD_URL)
        assert_eq(U('https://r2.fivemanage.com/abc/def.jpg'), 'https://r2.fivemanage.com/abc/def.jpg')
        assert_eq(U('https://x.fivemanage.com/a.png'), 'https://x.fivemanage.com/a.png', 'a subdomain of an allowed host')
        assert_eq(U('http://cdn.discordapp.com/a.png'), nil, 'not https')
        assert_eq(U('https://evil.example/a.png'), nil, 'unknown host')
        assert_eq(U('https://cdn.discordapp.com.evil.example/a.png'), nil)
        assert_eq(U('https://evilcdn.discordapp.com/a.png'), nil, 'not a subdomain, only a longer name')
        assert_eq(U('https://cdn.discordapp.com/x"><img src=x onerror=alert(1)>'), nil)
        assert_eq(U("https://cdn.discordapp.com/a');}*{background:url(//evil/ip)"), nil)
        assert_eq(U('https://cdn.discordapp.com/a b.png'), nil)
        assert_eq(U('https://cdn.discordapp.com/' .. string.rep('a', 600)), nil, 'too long')
        assert_eq(U(42), nil)
        assert_eq(U({}), nil)
    end)
    it('a profile photo, a vehicle photo or evidence with a bad URL is not stored', function()
        local bad = 'x"><img src=x onerror=alert(1)>'
        assert_eq(Mock.callCallback('pf_mdt:updateProfilePicture', OFFICER, { citizenId = 'CID4', url = bad }).error, 'bad_image')
        assert_eq(Mock.callCallback('pf_mdt:updateVehiclePhoto', OFFICER, { plate = 'ABC123', url = 'https://evil.example/a.png' }).error, 'bad_image')
        assert_eq(Mock.callCallback('pf_mdt:createEvidence', OFFICER, { title = 'Knife', imageUrl = bad }).success, false)
        Mock.fireNet('pf_mdt:server:AddIncidentEvidencePhoto', OFFICER, { incidentId = 'INC-1', imageUrl = bad })
        Mock.fireNet('pf_mdt_dispatch:server:SaveProfile', OFFICER, { callsign = '1-ADAM-12', avatarUrl = bad })
        assert_eq(ran('pf_mdt_citizen_profiles'), 0)
        assert_eq(ran('pf_mdt_vehicle_profiles'), 0)
        assert_eq(ran('INSERT INTO pf_mdt_evidence'), 0)
        assert_eq(ran('pf_mdt_incident_evidence'), 0)
        assert_eq(ran('pf_mdt_officer_profiles'), 0)
        assert_eq(Mock.players[OFFICER].PlayerData.metadata.mdt_avatar, nil)
    end)
    it('a good URL is stored', function()
        assert_eq(Mock.callCallback('pf_mdt:updateProfilePicture', OFFICER, { citizenId = 'CID4', url = GOOD_URL }).success, true)
        assert_eq(lastParams('pf_mdt_citizen_profiles')[2], GOOD_URL)
        Mock.fireNet('pf_mdt_dispatch:server:SaveProfile', OFFICER, { callsign = '1-ADAM-12', avatarUrl = GOOD_URL })
        assert_eq(lastParams('pf_mdt_officer_profiles')[4], GOOD_URL)
    end)
    it('a report keeps only evidence photos with a valid URL', function()
        Mock.fireNet('pf_mdt:createReport', OFFICER, { title = 'Report', linkedEvidence = {
            { url = GOOD_URL, title = 'scene' }, { url = 'javascript:alert(1)', title = 'bad' }, 'EVD-12' } })
        local p = lastParams('INSERT INTO pf_mdt_reports')
        assert_true(p ~= nil, 'the report is stored')
        local ev = json.decode(p[11])
        assert_eq(#ev, 2)
        assert_eq(ev[1].url, GOOD_URL)
        assert_eq(ev[2], 'EVD-12')
    end)
end)

describe('charges', function()
    it('a charge above the limits is refused; a valid one is created and recorded', function()
        local res = Mock.callCallback('pf_mdt:createCharge', BOSS, { code = 'MISC', name = 'Misc', fine_amount = 9999999, jail_time = 99999 })
        assert_eq(res.success, false)
        assert_eq(ran('INSERT INTO pf_mdt_charges'), 0)
        res = Mock.callCallback('pf_mdt:createCharge', BOSS, { code = 'MISC', name = 'Misc', fine_amount = 500, jail_time = 5 })
        assert_eq(ran('INSERT INTO pf_mdt_charges'), 1)
        local audit = lastParams('INSERT INTO pf_mdt_charge_audit')
        assert_true(audit ~= nil, 'the change is recorded')
        assert_eq(audit[3], 'create')
        assert_eq(audit[6], 'CID1')
    end)
end)

describe('roster and staff are per department', function()
    it("a roster line cannot take another department's citizen (the EMS chief)", function()
        local res = Mock.callCallback('pf_mdt:roster:updateRowCb', BOSS, { id = 3, callsign = '101', rank = 'Officer', citizenid = 'CID5', officer_name = 'EMS Chief' })
        assert_eq(res.success, false)
        assert_eq(res.error, 'not_an_officer')
        assert_eq(ran('UPDATE pf_mdt_roster SET'), 0)
        res = Mock.callCallback('pf_mdt:roster:updateRowCb', BOSS, { id = 3, callsign = '101', rank = 'Officer', citizenid = 'CID2', officer_name = 'Officer Two' })
        assert_eq(res.success, true, tostring(res.error))
        assert_eq(ran('UPDATE pf_mdt_roster SET'), 1)
    end)
    it('the chief line is the boss\'s; a line held by a higher rank is not a lower editor\'s', function()
        Config.Permissions.manageRoster.police = 3
        db.rosterLine = { rank = 'Chief of Police' }
        assert_eq(Mock.callCallback('pf_mdt:roster:updateRowCb', SGT, { id = 1, callsign = '1', rank = 'Chief of Police', officer_name = 'Me' }).error, 'protected_chief')
        db.rosterLine = { rank = 'Captain', citizenid = 'CID1' }
        assert_eq(Mock.callCallback('pf_mdt:roster:updateRowCb', SGT, { id = 2, callsign = '2', rank = 'Captain', officer_name = 'Me' }).error, 'rank_too_high')
    end)
    it("firing the EMS chief written into a police roster line never touches their job", function()
        db.roster.CID5 = true
        local res = Mock.callCallback('pf_mdt:officers:fire', BOSS, { citizenid = 'CID5' })
        assert_eq(res.jobChanged, false, 'only the police roster line and staff record')
        assert_eq(Mock.players[EMSCHIEF].PlayerData.job.name, 'ambulance')
        assert_eq(ran('UPDATE players SET job'), 0)
    end)
    it('a sheriff (grade 4) cannot fire, flag or discipline a police officer', function()
        assert_eq(Mock.callCallback('pf_mdt:officers:fire', DEPUTY, { citizenid = 'CID2' }).error, 'other_department')
        assert_eq(Mock.callCallback('pf_mdt:officers:setFlags', DEPUTY, { citizenid = 'CID2', status = 'SUSPENDED' }).error, 'other_department')
        assert_eq(Mock.callCallback('pf_mdt:officers:addDiscipline', DEPUTY, { citizenid = 'CID2', type = 'warning', reason = 'x' }).error, 'other_department')
        assert_eq(Mock.players[OFFICER].PlayerData.job.name, 'police')
        assert_eq(ran('UPDATE players SET job'), 0)
    end)
    it('a former officer who took another job only leaves the roster; their new job stays', function()
        db.players.CID99 = { job = { name = 'mechanic', grade = { level = 2 } } }
        db.roster.CID99 = true
        local res = Mock.callCallback('pf_mdt:officers:fire', BOSS, { citizenid = 'CID99' })
        assert_eq(res.success, true, tostring(res.error))
        assert_eq(res.jobChanged, false)
        assert_eq(ran('UPDATE players SET job'), 0)
        assert_eq(ran('UPDATE pf_mdt_roster SET officer_name = ""'), 1, 'the line is vacated')
    end)
    it('a member of the department is fired from that job only', function()
        local res = Mock.callCallback('pf_mdt:officers:fire', BOSS, { citizenid = 'CID2' })
        assert_eq(res.success, true, tostring(res.error))
        assert_eq(res.jobChanged, true)
        local p = lastParams('UPDATE players SET job')
        assert_eq(p[3], 'police', 'the row changes only while it still holds the police job')
    end)
    it('the roster reset: boss only, two steps, backup before anything is removed', function()
        assert_eq(Mock.callCallback('pf_mdt:roster:resetCb', DEPUTY, {}).error, 'no_permission', 'a grade 4 deputy is not the boss')
        assert_eq(Mock.callCallback('pf_mdt:roster:resetCb', SGT, {}).success, false)
        local first = Mock.callCallback('pf_mdt:roster:resetCb', BOSS, {})
        assert_eq(first.confirmRequired, true)
        assert_eq(ran('pf_mdt_roster_backup'), 0, 'nothing happens on the first step')
        assert_eq(Mock.callCallback('pf_mdt:roster:resetCb', BOSS, { token = 'guess' }).confirmRequired, true)
        local second = Mock.callCallback('pf_mdt:roster:resetCb', BOSS, { token = Mock.callCallback('pf_mdt:roster:resetCb', BOSS, {}).token })
        assert_eq(second.success, true, tostring(second.error))
        local backup, delete = firstIndex('INSERT INTO pf_mdt_roster_backup'), firstIndex('DELETE FROM pf_mdt_roster')
        assert_true(backup ~= nil and delete ~= nil and backup < delete, 'copied first')
        assert_true(db.log[delete].sql:find('citizenid IS NULL', 1, true) ~= nil, 'only lines nobody holds are removed')
    end)
    it('without the backup table there is no reset', function()
        PFMdtSentencing.dbReady = false
        local t = Mock.callCallback('pf_mdt:roster:resetCb', BOSS, {}).token
        local res = Mock.callCallback('pf_mdt:roster:resetCb', BOSS, { token = t })
        PFMdtSentencing.dbReady = true
        assert_eq(res.error, 'backup_unavailable')
        assert_eq(ran('DELETE FROM pf_mdt_roster'), 0)
    end)
    it('the debug reset command is console-only and no longer shares the EMS MDT name', function()
        assert_eq(Mock.rawCommands['pfmdt_roster_reset'], nil)
        local cmd = Mock.rawCommands['pfpolicemdt_roster_reset']
        assert_true(cmd ~= nil)
        cmd(BOSS)
        assert_eq(ran('pf_mdt_roster_backup'), 0, 'a player cannot run it')
        cmd(0)
        assert_eq(ran('INSERT INTO pf_mdt_roster_backup'), 1)
    end)
end)

describe('cameras', function()
    it('only an officer near a camera can report it offline', function()
        local hash = Config.CCTVModels[1]
        Mock.coords[OFFICER] = vector3(200.0, 200.0, 30.0)
        Mock.fireNet('pf_mdt:cctv:registerDiscoveredCamera', OFFICER, hash, 201.0, 201.0, 31.0, 90.0, 'Test cam')
        assert_eq(ran('INSERT INTO pf_mdt_cctv_cameras'), 1)
        Mock.coords[SGT] = vector3(3000.0, 3000.0, 30.0)
        Mock.fireNet('pf_mdt:cctv:setCameraOffline', SGT, { id = 7 })
        assert_eq(ran('UPDATE pf_mdt_cctv_cameras SET status'), 0, 'from across the map')
        Mock.fireNet('pf_mdt:cctv:setCameraOffline', OFFICER, { id = 7 })
        assert_eq(ran('UPDATE pf_mdt_cctv_cameras SET status'), 1)
    end)
end)
