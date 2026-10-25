-- pf-policemdt-DEV: MDT callbacks and events are for police jobs (citizen records, warrants, reports
-- could be read or written by any player), civilian reports are near the caller, and police actions
-- that touch other players are bounded (licenses, firing, citation records, warrants, reports).
load_resource('tests/lua/fivem_mocks.lua')
function IsDuplicityVersion() return true end
function GetResourceState() return 'missing' end
QBCore = QBCoreMock
promise = promise or { new = function() return { resolve = function(self, v) self.value = v end } end }
Citizen.Await = Citizen.Await or function(p) return p.value end

-- fake oxmysql: answers by SQL text, records every statement
local db = { log = {}, players = {}, sentences = {}, roster = {} }
local function answer(sql, params)
    db.log[#db.log + 1] = { sql = sql, params = params }
    if sql:find('SELECT job FROM players WHERE citizenid', 1, true) then
        local p = db.players[params[1]]
        return p and { { job = json.encode(p.job) } } or {}
    end
    if sql:find('SELECT metadata FROM players WHERE citizenid', 1, true) then
        local p = db.players[params[1]]
        return p and { { metadata = json.encode(p.metadata) } } or {}
    end
    if sql:find('AS r, (SELECT COUNT(*)', 1, true) then
        return { { r = db.roster[params[1]] and 1 or 0, s = 0 } }
    end
    if sql:find('FROM pf_mdt_sentences WHERE id = ?', 1, true) then
        local r = db.sentences[params[1]]
        return r and { r } or {}
    end
    if sql:find('SELECT * FROM pf_mdt_officer_mgmt_profiles', 1, true) then return { { terminated = 0 } } end
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

function GetCurrentResourceName() return 'pf-policemdt-DEV' end
Config = nil
load_resource('[pfscripts]/pf-policemdt-DEV/shared/framework.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/config.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/server/access.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/server/main.lua')
load_resource('[pfscripts]/pf-policemdt-DEV/server/officers.lua')
Config.Dispatch911.Enabled = true

local CHIEF, OFFICER, CIVIL, MECHANIC = 1, 2, 3, 4
local function setJob(src, name, grade)
    local p = Mock.players[src]
    p.PlayerData.job = { name = name, label = name, onduty = true, grade = { level = grade, name = 'g' .. grade } }
    db.players[p.PlayerData.citizenid] = { job = p.PlayerData.job, metadata = p.PlayerData.metadata }
end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    db.log, db.players, db.sentences, db.roster = {}, {}, {}, {}
    Mock.newPlayer(CHIEF); setJob(CHIEF, 'police', 5)
    Mock.newPlayer(OFFICER); setJob(OFFICER, 'police', 1)
    Mock.newPlayer(CIVIL); setJob(CIVIL, 'unemployed', 0)
    Mock.newPlayer(MECHANIC); setJob(MECHANIC, 'mechanic', 4)
    for src in pairs(Mock.players) do Mock.coords[src] = vector3(100.0, 100.0, 30.0) end
end

describe('MDT records are for police', function()
    it('a civilian cannot search citizens, open a profile, warrants or reports', function()
        for _, name in ipairs({ 'pf_mdt:searchCitizens', 'pf_mdt:getCitizenProfile', 'pf_mdt:searchWarrants',
            'pf_mdt:getReport', 'pf_mdt:searchIncidents', 'pf_mdt:getAllPlayers', 'pf_mdt_dispatch:server:GetWarrantDetails' }) do
            local res = Mock.callCallback(name, CIVIL, { query = '', citizenId = 'CID2', id = 'RPT-1' })
            assert_eq(res and res.error, 'no_access', name)
        end
        assert_eq(#db.log, 0)
    end)
    it('a civilian cannot create warrants, flag citizens, delete reports or clear strikes', function()
        Mock.fireNet('pf_mdt:createWarrant', CIVIL, { suspect = 'Test Player2', charges = {} })
        Mock.fireNet('pf_mdt:addCitizenFlag', CIVIL, { citizenId = 'CID2', flag = 'dangerous' })
        Mock.fireNet('pf_mdt:addCitizenNote', CIVIL, { citizenId = 'CID2', text = 'x' })
        Mock.fireNet('pf_mdt:clearVehicleStrikes', CIVIL, { plate = 'ABC123' })
        Mock.fireNet('pf_mdt:updateIncident', CIVIL, { id = 'INC-1', title = 'x' })
        assert_eq(#db.log, 0)
    end)
    it('an officer still can', function()
        local res = Mock.callCallback('pf_mdt:searchWarrants', OFFICER, { query = '' })
        assert_eq(res.error, nil)
        Mock.fireNet('pf_mdt:addCitizenFlag', OFFICER, { citizenId = 'CID3', flag = 'dangerous' })
        assert_eq(ran('INSERT INTO pf_mdt_citizen_flags'), 1)
    end)
    it('the external dispatch and roster-updated events are not net events', function()
        assert_eq(Mock.netHandlers['pf_mdt:server:CreateDispatchFromExternal'], nil)
        assert_eq(Mock.netHandlers['pf_mdt:server:RosterUpdated'], nil)
        assert_true(Mock.eventHandlers['pf_mdt:server:CreateDispatchFromExternal'] ~= nil)
    end)
end)

describe('MDT civilian dispatch', function()
    it('a /911 call far from the caller is ignored, near the caller it reaches officers', function()
        Mock.fireNet('pf_mdt_dispatch:server:Create911Call', CIVIL, { description = 'help', coords = { x = 2000.0, y = 2000.0, z = 30.0 }, locationLabel = 'x' })
        assert_eq(#Mock.clientEventsNamed('pf_mdt:dispatch:newCall'), 0)
        Mock.fireNet('pf_mdt_dispatch:server:Create911Call', MECHANIC, { description = 'help', coords = { x = 101.0, y = 100.0, z = 30.0 }, locationLabel = string.rep('L', 500) })
        local calls = Mock.clientEventsNamed('pf_mdt:dispatch:newCall')
        assert_eq(#calls, 2) -- the two officers
        assert_true(#calls[1].args[1].locationLabel <= 128)
    end)
    it('an officer-created call keeps only the call fields', function()
        Mock.fireNet('pf_mdt_dispatch:server:CreateCall', OFFICER, { title = 'Pursuit', priority = 99, status = 'completed', assignedUnits = { 'X' }, createdAt = 0 })
        local c = Mock.clientEventsNamed('pf_mdt:dispatch:newCall')[1].args[1]
        assert_eq(c.priority, 3)
        assert_eq(c.status, 'pending')
        assert_eq(#c.assignedUnits, 0)
        assert_true(c.createdAt > 0)
    end)
end)

describe('MDT licenses', function()
    it('unsuspend does not grant a license type the MDT does not manage, or one that was never suspended', function()
        local cid = Mock.players[CIVIL].PlayerData.citizenid
        db.players[cid].metadata = { licences = { driver = false } }
        Mock.fireNet('pf_mdt:unsuspendLicense', OFFICER, { citizenId = cid, licenseType = 'pilot' })
        Mock.fireNet('pf_mdt:unsuspendLicense', OFFICER, { citizenId = cid, licenseType = 'driver' })
        assert_eq(ran('UPDATE players SET metadata'), 0)
    end)
    it('a suspended license is restored', function()
        local cid = Mock.players[CIVIL].PlayerData.citizenid
        db.players[cid].metadata = { licences = { driver = false }, licenseSuspensions = { driver = '2030-01-01 00:00:00' } }
        Mock.fireNet('pf_mdt:unsuspendLicense', OFFICER, { citizenId = cid, licenseType = 'driver' })
        assert_eq(ran('UPDATE players SET metadata'), 1)
        assert_true(json.decode(lastParams('UPDATE players SET metadata')[1]).licences.driver == true)
    end)
end)

describe('MDT officer management', function()
    it('command cannot fire someone outside the police', function()
        local res = Mock.callCallback('pf_mdt:officers:fire', CHIEF, { citizenid = 'CID4', reason = 'x' })
        assert_eq(res.error, 'not_staff')
        assert_eq(ran('UPDATE players SET job'), 0)
    end)
    it('command cannot fire an officer of the same or a higher rank, or themselves', function()
        setJob(OFFICER, 'police', 5)
        assert_eq(Mock.callCallback('pf_mdt:officers:fire', CHIEF, { citizenid = 'CID2' }).error, 'rank_too_high')
        assert_eq(Mock.callCallback('pf_mdt:officers:fire', CHIEF, { citizenid = 'CID1' }).error, 'cannot_fire_self')
        assert_eq(ran('UPDATE players SET job'), 0)
    end)
    it('command fires a lower-ranked officer', function()
        local res = Mock.callCallback('pf_mdt:officers:fire', CHIEF, { citizenid = 'CID2', reason = 'x' })
        assert_eq(res.success, true)
        assert_eq(ran('UPDATE players SET job'), 1)
    end)
    it('discipline cannot be filed against a non-officer', function()
        assert_eq(Mock.callCallback('pf_mdt:officers:addDiscipline', CHIEF, { citizenid = 'CID4', type = 'warning', reason = 'x' }).error, 'not_staff')
    end)
end)

describe('MDT citation paper', function()
    BeforeEach = function()
        db.sentences[7] = { id = 7, citizenId = 'CID3', citizenName = 'Test Player3', officerName = 'Officer', title = 'Speeding', description = '', fineAmount = 300, fineSuccess = 1 }
    end
    it('another player cannot read a sentence record by id', function()
        local res = Mock.callCallback('pf_mdt:getCitationPaperData', MECHANIC, { sentenceId = 7 })
        assert_eq(res.error, 'no_access')
    end)
    it('the sentenced citizen, a holder of the printed citation and police can', function()
        assert_eq(Mock.callCallback('pf_mdt:getCitationPaperData', CIVIL, { sentenceId = 7 }).success, true)
        assert_eq(Mock.callCallback('pf_mdt:getCitationPaperData', OFFICER, { sentenceId = 7 }).success, true)
        Mock.players[MECHANIC].PlayerData.items = { { name = 'citation_paper', amount = 1, info = { sentenceId = 7 } } }
        assert_eq(Mock.callCallback('pf_mdt:getCitationPaperData', MECHANIC, { sentenceId = 7 }).success, true)
    end)
end)

describe('MDT reports and warrants', function()
    it('a new report is pending whatever status the client sends', function()
        Mock.callCallback('pf_mdt:createReport', OFFICER, { title = 'x', narrative = 'y', status = 'approved', approvalStatus = 'approved' })
        local p = lastParams('INSERT INTO pf_mdt_reports')
        assert_eq(p[12], 'pending')
        assert_eq(p[13], 'pending')
    end)
    it('removing a warrant needs the configured grade', function()
        Mock.fireNet('pf_mdt:updateWarrantStatus', OFFICER, { warrantId = 'W1', status = 'removed' })
        assert_eq(ran('UPDATE pf_mdt_warrants SET status'), 0)
        Mock.fireNet('pf_mdt:updateWarrantStatus', CHIEF, { warrantId = 'W1', status = 'removed' })
        assert_eq(ran('UPDATE pf_mdt_warrants SET status'), 1)
    end)
end)
