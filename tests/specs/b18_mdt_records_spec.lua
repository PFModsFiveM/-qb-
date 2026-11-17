-- Batch 18F (pf-policemdt-DEV): gate fixes and records extension, mocked.
--   * PFMdtAccess.RegisterActions adds gate entries for new files and never replaces one;
--   * updatePlayerStatus / updatePlayerCallsign are gated net events (they skipped the gate);
--   * chat, SaveProfile, CreatePanicCall and the CCTV registry need an on-duty officer; the CCTV
--     refusal is quiet; the panic call is placed at the server position, never the client's coords;
--   * warrants: the client's id and expiry are ignored, a real suspect citizen id is required, the
--     warrant starts pending_approval, inputs are capped; a judge review is filed when pf-justice
--     offers RequestWarrantReview; SetWarrantApproval / ExpungeRecord refuse other resources;
--   * vehicle flags come from a whitelist; removeCitizenFlag and createEvidence inputs are capped;
--   * reads and changes of citizens, incidents and reports write pf_mdt_record_audit rows (reads
--     de-duplicated); a deleted incident is soft-deleted;
--   * CCTV: getCameraList is registered once, recordings are always empty;
--   * reports are not auto-approved (Config.Reports.AutoApproveHours = nil);
--   * the evidence webhook is no longer in the replicated config; the server takes and posts the photo.
local ROOT = MDT_ROOT or '[pfscripts]/pf-policemdt-DEV'
load_resource('tests/lua/fivem_mocks.lua')
function IsDuplicityVersion() return true end
local states = {}
function GetResourceState(name) return states[name] or 'missing' end
QBCore = QBCoreMock
promise = promise or { new = function() return { resolve = function(self, v) self.value = v end } end }
Citizen.Await = Citizen.Await or function(p) return p.value end
local convars = {}
function GetConvar(name, default) return convars[name] or default end

-- one fake database for oxmysql (main.lua) and MySQL.*.await (records_ext.lua): every statement is
-- logged; answers by SQL text
local db
local function resetDb()
    db = { log = {}, players = {}, insertId = 0, warrant = nil, singles = {} }
end
resetDb()
local function answer(kind, sql, params)
    db.log[#db.log + 1] = { kind = kind, sql = sql, params = params or {} }
    if sql:find('SELECT charinfo FROM players WHERE citizenid', 1, true) then
        local p = db.players[params[1]]
        return p and { { charinfo = json.encode(p) } } or {}
    end
    if sql:find('FROM pf_mdt_warrants WHERE warrantId = ?', 1, true) then
        return db.warrant and { db.warrant } or {}
    end
    if sql:find('SELECT title, officer FROM pf_mdt_reports', 1, true) then return { { title = 'Pursuit', officer = 'A' } } end
    if kind == 'insert' then db.insertId = db.insertId + 1 return db.insertId end
    if kind == 'update' then return 1 end
    return {}
end
local function ox(kind)
    return function(_, sql, params, cb)
        if Mock.callable(params) then cb, params = params, nil end
        local r = answer(kind, sql, params)
        if kind == 'execute' and sql:find('^%s*UPDATE') then r = { affectedRows = 1 } end
        if cb then cb(r) end
        return r
    end
end
Mock.exportsByResource['oxmysql'] = { execute = ox('execute'), query = ox('execute'), fetch = ox('execute'), insert = ox('insert'),
    update = ox('update'), scalar = ox('scalar'), single = ox('single') }
local function lib(kind)
    local function f(sql, params)
        local r = answer(kind, sql, params)
        if kind == 'single' then return type(r) == 'table' and r[1] or nil end
        return r
    end
    return setmetatable({ await = f }, { __call = function(_, sql, params, cb) local r = f(sql, params) if cb then cb(r) end return r end })
end
MySQL = { query = lib('query'), single = lib('single'), insert = lib('insert'), update = lib('update'), scalar = lib('scalar') }
Mock.exportsByResource['pfm-core'].RunMigrations = function() return true end

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
load_resource(ROOT .. '/shared/framework.lua')
load_resource(ROOT .. '/config.lua')
load_resource(ROOT .. '/server/access.lua')
load_resource(ROOT .. '/server/main.lua')
local cctvListAfterMain = Mock.callbacks['pf_mdt:cctv:getCameraList']
load_resource(ROOT .. '/server/cctv.lua')
pcall(load_resource, ROOT .. '/server/records_ext.lua') -- missing in the pre-18F tree

local OFFICER, SGT, CHIEF, CIVIL, OFFDUTY = 1, 2, 3, 4, 5
local function setJob(src, name, grade, onduty)
    Mock.players[src].PlayerData.job = { name = name, label = name, onduty = onduty ~= false, grade = { level = grade } }
end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    Mock.gameTimer = Mock.gameTimer + 100000
    Mock.invokingResource = nil
    resetDb()
    states = {}
    convars = {}
    Mock.newPlayer(OFFICER, 'OFF1'); setJob(OFFICER, 'police', 1)
    Mock.newPlayer(SGT, 'SGT1'); setJob(SGT, 'police', 3)
    Mock.newPlayer(CHIEF, 'CHF1'); setJob(CHIEF, 'police', 5)
    Mock.newPlayer(CIVIL, 'CIV1'); setJob(CIVIL, 'unemployed', 0)
    Mock.newPlayer(OFFDUTY, 'OFD1'); setJob(OFFDUTY, 'police', 4, false)
    for src in pairs(Mock.players) do Mock.coords[src] = vector3(100.0, 200.0, 30.0) end
    db.players['SUS1'] = { firstname = 'Rob', lastname = 'Banks' }
    if Config.Reports then Config.Reports.AutoApproveHours = nil end
end

describe('18F gate: PFMdtAccess.RegisterActions', function()
    it('adds new pf_mdt entries, never replaces one, ignores names the gate does not cover', function()
        assert_true(Mock.callable(PFMdtAccess.RegisterActions), 'helper exists')
        local added, refused = PFMdtAccess.RegisterActions({
            ['pf_mdt:test:thing'] = { action = 'manageSOPs' },
            ['pf_mdt:createWarrant'] = { action = 'chat' },          -- exists: refused
            ['other:event'] = { action = 'chat' },                   -- not gated: refused
            ['pf_mdt:test:bad'] = { },                               -- no action: refused
        })
        assert_eq(added, 1)
        assert_eq(#refused, 3)
        assert_eq(PFMdtAccess.Actions['pf_mdt:createWarrant'].action, 'createWarrant')
        PFMdt.GetCore().Functions.CreateCallback('pf_mdt:test:thing', function(_, cb) cb({ success = true }) end)
        assert_eq(Mock.callCallback('pf_mdt:test:thing', OFFICER).error, 'no_permission', 'grade 1 < manageSOPs 4')
        assert_eq(Mock.callCallback('pf_mdt:test:thing', CHIEF).success, true)
    end)
end)

describe('18F gate fixes', function()
    it('status and callsign are gated net events: civilians and off-duty officers are refused', function()
        assert_true(Mock.netHandlers['pf_mdt:updatePlayerStatus'] ~= nil, 'net event')
        assert_eq(Mock.eventHandlers['pf_mdt:updatePlayerStatus'], nil, 'not a plain AddEventHandler')
        Mock.fireNet('pf_mdt:updatePlayerStatus', OFFDUTY, { changed = 'status', status = 'busy' })
        Mock.fireNet('pf_mdt:updatePlayerCallsign', CIVIL, '1-ADAM')
        assert_eq(#Mock.clientEventsNamed('pf_mdt:client:UpdatePersonalInfo'), 0)
        Mock.fireNet('pf_mdt:updatePlayerStatus', OFFICER, { changed = 'status', status = 'busy' })
        assert_eq(#Mock.clientEventsNamed('pf_mdt:client:UpdatePersonalInfo'), 1)
    end)
    it('a callsign with markup is refused', function()
        Mock.fireNet('pf_mdt:updatePlayerCallsign', OFFICER, '<b>x</b>')
        assert_eq(#Mock.clientEventsNamed('pf_mdt:client:UpdatePersonalInfo'), 0)
        Mock.fireNet('pf_mdt:updatePlayerCallsign', OFFICER, '1-ADAM-12')
        assert_eq(#Mock.clientEventsNamed('pf_mdt:client:UpdatePersonalInfo'), 1)
    end)
    it('chat, profile, panic and the CCTV registry need duty', function()
        for _, name in ipairs({ 'pf_mdt:sendChatMessage', 'pf_mdt_dispatch:server:SaveProfile', 'pf_mdt_dispatch:server:CreatePanicCall',
            'pf_mdt:cctv:registerDiscoveredCamera', 'pf_mdt:cctv:setCameraOffline' }) do
            assert_true(PFMdtAccess.Actions[name] ~= nil, name .. ' in ACTIONS')
        end
        assert_eq(Mock.callCallback('pf_mdt:sendChatMessage', OFFDUTY, 'hello').error, 'off_duty')
        Mock.fireNet('pf_mdt_dispatch:server:CreatePanicCall', OFFDUTY, {})
        assert_eq(#Mock.clientEventsNamed('pf_mdt:dispatch:newCall'), 0)
    end)
    it('a refused camera report is quiet (the client sends them on its own)', function()
        local model = Config.CCTVModels[1]
        Mock.fireNet('pf_mdt:cctv:registerDiscoveredCamera', OFFDUTY, model, 100.0, 200.0, 30.0, 0.0, 'x')
        assert_eq(#Mock.clientEventsNamed('QBCore:Notify'), 0)
        assert_eq(ran('pf_mdt_cctv_cameras'), 0, 'off duty: not registered')
        Mock.fireNet('pf_mdt:cctv:registerDiscoveredCamera', OFFICER, model, 100.0, 200.0, 30.0, 0.0, 'x')
        assert_eq(ran('INSERT INTO pf_mdt_cctv_cameras'), 1, 'on duty: registered')
    end)
    it('the panic call is placed at the officer, not at the coords the client sent', function()
        Mock.fireNet('pf_mdt_dispatch:server:CreatePanicCall', OFFICER, { coords = { x = -2000.0, y = 3000.0, z = 10.0 }, description = 'help' })
        local calls = Mock.clientEventsNamed('pf_mdt:dispatch:newCall')
        assert_true(#calls > 0, 'call placed')
        local c = calls[1].args[1].coords
        assert_eq(c.x, 100.0)
        assert_eq(c.y, 200.0)
    end)
end)

describe('18F warrants v2', function()
    it('the client warrant id and expiry are ignored; suspect from the server; pending approval', function()
        Mock.fireNet('pf_mdt:createWarrant', OFFICER, { warrantId = 'EVIL', expiry = '2099-01-01 00:00:00', suspectCitizenId = 'SUS1',
            suspect = 'Fake Name', type = 'arrest', charges = { 'Robbery' }, expiryDays = 900 })
        local p = lastParams('INTO pf_mdt_warrants')
        assert_true(p ~= nil, 'inserted')
        assert_true(p[1] ~= 'EVIL' and p[1]:match('^W%d+$') ~= nil, 'server id ' .. tostring(p[1]))
        assert_eq(p[2], 'SUS1')
        assert_eq(p[3], 'Rob Banks', 'name from the players row')
        local sql
        for _, e in ipairs(db.log) do if e.sql:find('INTO pf_mdt_warrants', 1, true) then sql = e.sql end end
        assert_true(sql:find("'pending_approval'", 1, true) ~= nil and sql:find("'pending'", 1, true) ~= nil)
        -- expiry capped at Config.Warrants.MaxDays (30): within 31 days of now
        local y, mo, d = p[10]:match('^(%d+)-(%d+)-(%d+)')
        local t = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = 12 })
        assert_true(t - os.time() <= 31 * 86400, 'expiry capped')
        assert_eq(#Mock.clientEventsNamed('QBCore:Notify'), 1)
    end)
    it('an arrest warrant needs a known citizen; a search warrant needs an address', function()
        assert_eq(PFMdtRecords.CreateWarrant(OFFICER, { type = 'arrest', suspect = 'Someone' }).error, 'suspect_required')
        Mock.gameTimer = Mock.gameTimer + 10000
        assert_eq(PFMdtRecords.CreateWarrant(OFFICER, { type = 'arrest', suspectCitizenId = 'NOPE' }).error, 'unknown_citizen')
        Mock.gameTimer = Mock.gameTimer + 10000
        assert_eq(PFMdtRecords.CreateWarrant(OFFICER, { type = 'search', suspect = 'Someone' }).error, 'address_required')
        Mock.gameTimer = Mock.gameTimer + 10000
        assert_eq(PFMdtRecords.CreateWarrant(OFFICER, { type = 'teleport', suspectCitizenId = 'SUS1' }).error, 'bad_type')
        Mock.gameTimer = Mock.gameTimer + 10000
        assert_eq(PFMdtRecords.CreateWarrant(OFFICER, { type = 'arrest', suspectCitizenId = 'OFF1' }).error, 'self')
        assert_eq(ran('INTO pf_mdt_warrants'), 0)
    end)
    it('lists and text are capped', function()
        local charges = {}
        for i = 1, 500 do charges[i] = string.rep('C', 100) end
        PFMdtRecords.CreateWarrant(OFFICER, { type = 'arrest', suspectCitizenId = 'SUS1', charges = charges, narrative = string.rep('n', 50000),
            title = string.rep('t', 900) })
        local p = lastParams('INTO pf_mdt_warrants')
        assert_true(#p[4] <= 8000, 'charges json capped')
        assert_true(#p[8] <= 255, 'title capped')
        assert_true(#p[9] <= 8000, 'narrative capped')
    end)
    it('a judge review is filed when pf-justice offers RequestWarrantReview', function()
        states['pf-justice'] = 'started'
        local got
        Mock.exportsByResource['pf-justice'] = { RequestWarrantReview = function(_, spec, opts) got = { spec = spec, opts = opts } return { ok = true, reviewId = 42 } end }
        local res = PFMdtRecords.CreateWarrant(OFFICER, { type = 'arrest', suspectCitizenId = 'SUS1', narrative = 'affidavit' })
        assert_eq(res.success, true)
        assert_eq(res.reviewId, 42)
        assert_eq(got.spec.targetCid, 'SUS1')
        assert_eq(got.spec.requestedBy, 'OFF1')
        assert_eq(got.opts.key, 'pf-policemdt:warrant:' .. res.warrantId .. ':review')
        assert_eq(lastParams('SET review_id')[1], 42)
    end)
    it('without the export (pf-justice before 19A) the warrant simply stays pending', function()
        states['pf-justice'] = 'started'
        Mock.exportsByResource['pf-justice'] = {}
        local res = PFMdtRecords.CreateWarrant(OFFICER, { type = 'arrest', suspectCitizenId = 'SUS1' })
        assert_eq(res.success, true)
        assert_eq(res.reviewId, nil)
        assert_eq(ran('SET review_id'), 0)
    end)
    it('only pf-justice may set an approval; a supervisor below the grade may not approve', function()
        Mock.invokingResource = 'pfm-policejob'
        assert_eq(Mock.selfExport('SetWarrantApproval')('W1', 'approve', {}).error, 'not_allowed')
        Mock.invokingResource = nil
        db.warrant = { warrantId = 'W1', status = 'pending', approval_state = 'pending_approval' }
        assert_eq(PFMdtRecords.ReviewWarrant(SGT, { warrantId = 'W1', decision = 'approve' }).error, 'no_permission')
        assert_eq(ran('SET approval_state'), 0)
    end)
end)

describe('18F warrant review from chat (until the page has buttons)', function()
    it('/warrantreview follows the same rules as the callback', function()
        db.warrant = { warrantId = 'W1', status = 'pending', approval_state = 'pending_approval' }
        Mock.rawCommands['warrantreview'](CIVIL, { 'W1', 'approve' })
        Mock.rawCommands['warrantreview'](SGT, { 'W1', 'approve' })
        assert_eq(ran('SET approval_state'), 0)
        Mock.rawCommands['warrantreview'](CHIEF, { 'W1', 'approve' })
        assert_eq(ran('SET approval_state'), 1)
        assert_eq(lastParams('SET approval_state')[3], 'supervisor:CHF1')
    end)
end)

describe('18F vehicle flags, citizen flags, evidence caps', function()
    it('a vehicle flag outside the whitelist or a bad plate is refused', function()
        Mock.fireNet('pf_mdt:addVehicleFlag', OFFICER, { plate = 'ABC123', flag = 'HACKED<script>' })
        Mock.fireNet('pf_mdt:addVehicleFlag', OFFICER, { plate = string.rep('A', 40), flag = 'STOLEN' })
        assert_eq(ran('INSERT INTO pf_mdt_vehicle_flags'), 0)
        Mock.fireNet('pf_mdt:addVehicleFlag', OFFICER, { plate = ' abc123 ', flag = 'stolen' })
        local p = lastParams('INSERT INTO pf_mdt_vehicle_flags')
        assert_eq(p[1], 'ABC123')
        assert_eq(p[2], 'STOLEN')
        local ev
        for _, e in ipairs(Mock.serverEvents) do if e.name == 'pf_mdt:server:plateFlagsChanged' then ev = e end end
        assert_true(ev ~= nil and ev.args[1] == 'ABC123', 'ALPR told')
        assert_eq(ran('INSERT INTO pf_mdt_record_audit'), 1)
        assert_eq(ran('INSERT INTO pf_mdt_vehicle_activity'), 1)
    end)
    it('removeCitizenFlag clips its values', function()
        Mock.fireNet('pf_mdt:removeCitizenFlag', OFFICER, { citizenId = string.rep('c', 500), flag = string.rep('f', 500) })
        local p = lastParams('DELETE FROM pf_mdt_citizen_flags')
        assert_true(#p[1] <= 64 and #p[2] <= 64)
    end)
    it('createEvidence bounds its lists and the weapons field, and keeps a known status', function()
        local many = {}
        for i = 1, 400 do many[i] = string.rep('x', 50) end
        local res = Mock.callCallback('pf_mdt:createEvidence', OFFICER, { title = 't', imageUrl = 'https://i.imgur.com/a.png',
            citizensInvolved = many, vehiclesInvolved = many, weaponsInvolved = many, relatedCharges = many, status = '<b>pwned</b>' })
        assert_eq(res.success, true)
        local p = lastParams('INSERT INTO pf_mdt_evidence')
        assert_true(#p[9] <= 4000 and #p[10] <= 4000 and #p[11] <= 4000 and #p[12] <= 4000, 'bounded')
        assert_eq(p[13], 'Collected')
    end)
end)

describe('18F record audit', function()
    it('opening a citizen profile writes one read row per officer within the window', function()
        Mock.callCallback('pf_mdt:getCitizenProfile', OFFICER, { citizenId = 'SUS1' })
        Mock.callCallback('pf_mdt:getCitizenProfile', OFFICER, { citizenId = 'SUS1' })
        local n, p = 0, nil
        for _, e in ipairs(db.log) do
            if e.sql:find('INSERT INTO pf_mdt_record_audit', 1, true) then n = n + 1 p = e.params end
        end
        assert_eq(n, 1)
        assert_eq(p[1], 'citizen')
        assert_eq(p[2], 'SUS1')
        assert_eq(p[3], 'read')
        assert_eq(p[4], 'OFF1')
    end)
    it('a deleted incident is soft-deleted and audited; a deleted report is audited', function()
        Mock.fireNet('pf_mdt:deleteIncident', CHIEF, { incidentId = 'INC-1' })
        assert_eq(ran('DELETE FROM pf_mdt_incidents'), 0)
        assert_eq(ran('SET deleted_at'), 1)
        Mock.fireNet('pf_mdt:deleteReport', CHIEF, { reportId = 'RPT-1' })
        local kinds = {}
        for _, e in ipairs(db.log) do
            if e.sql:find('INSERT INTO pf_mdt_record_audit', 1, true) then kinds[#kinds + 1] = e.params[1] .. ':' .. e.params[3] end
        end
        assert_eq(table.concat(kinds, ','), 'incident:delete,report:delete')
    end)
    it('ExpungeRecord refuses resources outside Config.Expunge.Callers', function()
        Mock.invokingResource = 'pf-mechanicjob'
        assert_eq(Mock.selfExport('ExpungeRecord')({ type = 'incident', id = 1 }, {}).error, 'not_allowed')
        Mock.invokingResource = 'pf-government'
        assert_eq(Mock.selfExport('ExpungeRecord')({ type = 'incident', id = 1 }, { actorCid = 'GOV1' }).ok, true)
        assert_eq(ran('UPDATE pf_mdt_incidents SET deleted_at'), 1)
        assert_eq(ran('DELETE FROM'), 0)
    end)
end)

describe('18F CCTV honesty', function()
    it('getCameraList is registered once (cctv.lua) and recordings are always empty', function()
        assert_eq(cctvListAfterMain, nil, 'main.lua no longer registers it')
        assert_eq(#Mock.callCallback('pf_mdt:cctv:getCameraRecordings', OFFICER, 'key'), 0)
        assert_eq(Config.CCTV.RecordingInterval, nil, 'no recording settings left')
    end)
end)

describe('18F reports are not auto-approved (D18)', function()
    it('the tick does nothing by default, approves only with AutoApproveHours set', function()
        assert_eq(Config.Reports.AutoApproveHours, nil)
        assert_eq(PFMdtMain.AutoApproveReportsTick(), false)
        assert_eq(ran('UPDATE pf_mdt_reports'), 0)
        Config.Reports.AutoApproveHours = 24
        assert_eq(PFMdtMain.AutoApproveReportsTick(), true)
        assert_eq(ran('UPDATE pf_mdt_reports'), 1)
    end)
end)

describe('18F evidence photos are posted by the server', function()
    local http
    BeforeEach = function()
        http = nil
        PerformHttpRequest = function(url, cb, method, body, headers) http = { url = url, method = method, body = body, headers = headers, cb = cb } end
        Mock.exportsByResource['screenshot-basic'] = {
            requestClientScreenshot = function(_, src, opts, cb)
                cb(false, 'data:image/jpeg;base64,SGVsbG8=')
            end,
        }
    end
    it('no webhook URL in the replicated config', function()
        assert_eq(Config.Webhooks.Evidence, nil)
        assert_eq(__readfile(ROOT .. '/config.lua'):find("GetConvar('pf_mdt_evidence_webhook'", 1, true), nil)
    end)
    it('base64 decoding', function()
        assert_eq(PFMdtMain.Base64Decode('SGVsbG8='), 'Hello')
        assert_eq(PFMdtMain.Base64Decode('SGVsbG8h'), 'Hello!')
        assert_eq(PFMdtMain.Base64Decode('SGk='), 'Hi')
    end)
    it('without the server convar nothing is taken', function()
        BeforeEach()
        local res = Mock.callCallback('pf_mdt:evidence:capturePhoto', OFFICER, {})
        assert_eq(res.error, 'not_configured')
        assert_eq(http, nil)
    end)
    it('the server takes the screenshot, posts it, and keeps only an allowed image URL', function()
        BeforeEach()
        convars['pf_policemdt_evidence_webhook'] = 'https://discord.com/api/webhooks/1/abc'
        states['screenshot-basic'] = 'started'
        local result
        Mock.cross(Mock.callbacks['pf_mdt:evidence:capturePhoto'], OFFICER, function(r) result = r end, { incidentId = 'INC-7' })
        assert_true(http ~= nil, 'posted by the server')
        assert_eq(http.url, 'https://discord.com/api/webhooks/1/abc')
        assert_true(http.body:find('Hello', 1, true) ~= nil, 'decoded image in the body')
        http.cb(200, json.encode({ attachments = { { url = 'https://cdn.discordapp.com/attachments/1/2/evidence.jpg' } } }))
        assert_eq(result.success, true)
        assert_eq(result.imageUrl, 'https://cdn.discordapp.com/attachments/1/2/evidence.jpg')
        assert_eq(lastParams('INSERT INTO pf_mdt_incident_evidence')[1], 'INC-7')
    end)
    it('an upload answer with a foreign host is refused', function()
        BeforeEach()
        convars['pf_policemdt_evidence_webhook'] = 'https://discord.com/api/webhooks/1/abc'
        states['screenshot-basic'] = 'started'
        Mock.gameTimer = Mock.gameTimer + 100000
        local result
        Mock.cross(Mock.callbacks['pf_mdt:evidence:capturePhoto'], OFFICER, function(r) result = r end, {})
        http.cb(200, json.encode({ attachments = { { url = 'https://evil.example/x.jpg' } } }))
        assert_eq(result.success, false)
        assert_eq(result.error, 'upload_failed')
    end)
    it('a civilian cannot use it', function()
        convars['pf_policemdt_evidence_webhook'] = 'https://discord.com/api/webhooks/1/abc'
        states['screenshot-basic'] = 'started'
        assert_eq(Mock.callCallback('pf_mdt:evidence:capturePhoto', CIVIL, {}).error, 'no_access')
    end)
end)

describe('18F callbacks wait for a running schema', function()
    it('a gated callback waits for PFMdtSchema while it migrates', function()
        local waited = false
        PFMdtSchema = { state = 'running', WaitReady = function() waited = true PFMdtSchema.state = 'ready' return true end }
        Mock.callCallback('pf_mdt:searchWarrants', OFFICER, { query = '' })
        PFMdtSchema = nil
        assert_true(waited)
    end)
end)
