-- pf-citizen calendar on a real database: personal events belong to the server's citizen id, city
-- events need a government permission, business events are posted by those who manage the business
-- and reach its staff, and reminders go out once per person shortly before the start.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
local started = { ['pf-devices'] = true, ['pf-government'] = true, ['pfm-core'] = true }
function GetResourceState(name) return started[name] and 'started' or 'missing' end
local clock = 0
function GetGameTimer() return clock end

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('[pfscripts]/pf-government/sql/install.sql')
-- the phone's table as it was before pf-citizen (50-character subject, no folders)
MySQL.query.await([[CREATE TABLE IF NOT EXISTS `player_mails` (`id` int(11) NOT NULL AUTO_INCREMENT, `citizenid` varchar(50) DEFAULT NULL,
    `sender` varchar(50) DEFAULT NULL, `subject` varchar(50) DEFAULT NULL, `message` text DEFAULT NULL, `read` tinyint(4) DEFAULT 0,
    `mailid` int(11) DEFAULT NULL, `date` timestamp NULL DEFAULT current_timestamp(), `button` text DEFAULT NULL,
    PRIMARY KEY (`id`), KEY `citizenid` (`citizenid`)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
load_resource('pfm-core/server/migrations.lua')
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end
QBCoreMock.Functions.GetPlayerByPhone = function(number)
    for _, p in pairs(Mock.players) do if p.PlayerData.charinfo.phone == number then return p end end
end

local pushes = {}
Mock.exportsByResource['pf-devices'] = {
    PushToCitizen = function(_, cid, app, event, payload) pushes[#pushes + 1] = { cid = cid, app = app, event = event, payload = payload } return true end,
    RegisterApp = function() return true end,
    RegisterAppHandlers = function() return true end,
    Broadcast = function() return true end,
}
local staff, perms, manages = {}, {}, {}
Mock.exportsByResource['pf-government'] = {
    HasPermission = function(_, src, perm) return perms[src] ~= nil and perms[src][perm] == true end,
    ManagesBusiness = function(_, src, id) return manages[src] ~= nil and manages[src][id] == true end,
    GetBusinessEmployees = function(_, id) return { ok = true, employees = staff[id] or {} } end,
}

function GetCurrentResourceName() return 'pf-citizen' end
for _, f in ipairs({ 'shared/config.lua', 'server/schema.lua', 'server/util.lua', 'server/mail.lua', 'server/bills.lua',
    'server/documents.lua', 'server/calendar.lua', 'server/apps.lua', 'server/main.lua' }) do
    load_resource('[pfscripts]/pf-citizen/' .. f)
end
assert(PFCitizen.Start(), 'pf-citizen start')
assert(PFCitizen.Start(), 'migrations run twice')
local X = Mock.exportsByResource['__self']
local M, D, K = PFCitizen.Mail, PFCitizen.Documents, PFCitizen.Calendar

local A, B, C3 = 1, 2, 3
local function box(cid, folder) return MySQL.query.await('SELECT * FROM player_mails WHERE citizenid = ? AND folder = ? ORDER BY id', { cid, folder }) end

BeforeEach = function()
    Mock.reset()
    Mock.players, pushes = {}, {}
    clock = clock + 600000
    PFCitizen.__resetLimits()
    PFCitizen.__resetStaffCache()
    for src, phone in pairs({ [A] = '5550001', [B] = '5550002', [C3] = '5550003' }) do
        local p = Mock.newPlayer(src)
        p.PlayerData.charinfo.phone = phone
        p.PlayerData.job = { name = 'unemployed', grade = { level = 0 }, onduty = true }
    end
end

local function future(minutes) return os.time() + minutes * 60 end
-- reminders compare with the database clock: the mocked os.time() follows it here
local function syncClock() Mock.clock = tonumber(MySQL.scalar.await('SELECT UNIX_TIMESTAMP()')) end

describe('calendar', function()
    it('personal events are private to their owner', function()
        local res = K.Create(A, { title = 'Dentist', starts = future(120), owner = 'CID2' })
        assert_eq(res.ok, true, tostring(res.error))
        assert_eq(MySQL.scalar.await('SELECT owner FROM pf_citizen_events WHERE id = ?', { res.id }), 'CID1')
        local mine = K.List(A, {}).events
        assert_eq(#mine, 1)
        assert_eq(mine[1].canEdit, true)
        assert_eq(#K.List(B, {}).events, 0)
        assert_eq(K.Update(B, { id = res.id, title = 'Hijacked', starts = future(60) }).error, 'not_authorized')
        assert_eq(K.Cancel(B, { id = res.id }).error, 'not_authorized')
        assert_eq(K.Subscribe(B, { id = res.id }).error, 'not_found')
        assert_eq(K.Update(A, { id = res.id, title = 'Dentist (moved)', starts = future(180) }).ok, true)
        assert_eq(K.Cancel(A, { id = res.id }).ok, true)
        assert_eq(#K.List(A, {}).events, 0)
    end)
    it('city events: government staff with the permission post them, everyone sees them', function()
        assert_eq(K.Create(A, { scope = 'city', title = 'Parade', starts = future(240) }).error, 'not_authorized')
        perms[A] = { events = true }
        local res = K.Create(A, { scope = 'city', title = 'Parade', starts = future(240), location = 'Legion Square' })
        assert_eq(res.ok, true)
        local seen = K.List(B, {}).events
        assert_eq(#seen, 1)
        assert_eq(seen[1].scope, 'city')
        assert_eq(seen[1].canEdit, false)
        assert_eq(K.List(A, {}).canPostCity, true)
        assert_eq(K.Cancel(B, { id = res.id }).error, 'not_authorized')
        assert_eq(K.Subscribe(B, { id = res.id }).subscribed, true)
        assert_eq(K.List(B, {}).events[1].subscribed, true)
        K.Cancel(A, { id = res.id })
    end)
    it('business events: posted by a manager, seen and mailed to the staff only', function()
        MySQL.query.await("INSERT IGNORE INTO pf_gov_businesses (business_id, business_name, owner_id, owner_name) VALUES ('store:mall', 'Mall Store', 'CID1', 'A')")
        staff['store:mall'] = { { citizenid = 'CID2', role = 'staff' } }
        assert_eq(K.Create(B, { scope = 'business', businessId = 'store:mall', title = 'Stocktake', starts = future(300) }).error, 'not_authorized')
        manages[A] = { ['store:mall'] = true }
        local res = K.Create(A, { scope = 'business', businessId = 'store:mall', title = 'Stocktake', starts = future(300) })
        assert_eq(res.ok, true, tostring(res.error))
        assert_eq(#K.List(B, {}).events, 1)
        assert_eq(K.List(B, {}).events[1].ownerName, 'Mall Store')
        assert_eq(#K.List(C3, {}).events, 0)
        local mail = box('CID2', 'inbox')
        assert_eq(mail[#mail].subject, 'New event: Stocktake')
        assert_eq(K.Update(B, { id = res.id, title = 'x', starts = future(10) }).error, 'not_authorized')
        K.Cancel(A, { id = res.id })
    end)
    it('reminders go out once, to the right people, while they are online', function()
        syncClock()
        perms[A] = { events = true }
        local personal = K.Create(B, { title = 'Court', starts = future(10), remind = 15 }).id
        local city = K.Create(A, { scope = 'city', title = 'Concert', starts = future(5), remind = 30 }).id
        K.Create(C3, { title = 'Later', starts = future(600), remind = 15 })
        K.Subscribe(C3, { id = city })
        assert_eq(K.Remind(), 2)                     -- B for the court date, C3 for the concert
        assert_eq(K.Remind(), 0)
        local who = {}
        for _, p in ipairs(pushes) do if p.event == 'reminder' then who[#who + 1] = p.cid .. ':' .. p.payload.title end end
        table.sort(who)
        assert_eq(table.concat(who, ','), 'CID2:Court,CID3:Concert')
        -- moving an event reminds again
        K.Update(B, { id = personal, title = 'Court', starts = future(12), remind = 15 })
        assert_eq(K.Remind(), 1)
        -- offline people are reminded when they come back before the start
        K.Subscribe(B, { id = city })
        Mock.players[B] = nil
        assert_eq(K.Remind(), 0)
        local p = Mock.newPlayer(B)
        p.PlayerData.charinfo.phone = '5550002'
        assert_eq(K.Remind(), 1)
    end)
    it('another resource can add an event (a court date)', function()
        local id = X.AddCalendarEvent('personal', 'CID3', { title = 'Court hearing', starts = future(1440), location = 'Courthouse' }, 'DOJ')
        assert_true(id ~= nil)
        local evs = K.List(C3, {}).events
        assert_eq(evs[#evs].by, 'DOJ')
        assert_eq(X.AddCalendarEvent('galaxy', 'x', { title = 'x', starts = future(5) }), nil)
    end)
end)
