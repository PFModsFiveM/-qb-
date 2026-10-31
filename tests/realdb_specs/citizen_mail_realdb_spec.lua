-- pf-citizen mail on a real database: the migration on the phone's player_mails table, player mail
-- with the server's identity, offline delivery, threads and replies, folders (trash, restore,
-- delete forever), drafts, search, job and business mail, broadcasts (government announcements)
-- delivered once per citizen, and rows the phone inserts the old way.
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
MySQL.query.await("INSERT INTO player_mails (citizenid, sender, subject, message, mailid, `read`) VALUES ('CID1', 'Old Bank', 'Before the update', 'old mail', 111111, 0)")
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
local staff = {}
Mock.exportsByResource['pf-government'] = {
    HasPermission = function() return false end,
    ManagesBusiness = function() return false end,
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
local M = PFCitizen.Mail

local A, B = 1, 2
local function row(id) return MySQL.single.await('SELECT * FROM player_mails WHERE id = ?', { id }) end
local function box(cid, folder) return MySQL.query.await('SELECT * FROM player_mails WHERE citizenid = ? AND folder = ? ORDER BY id', { cid, folder }) end
local function addOffline(cid, phone, job)
    MySQL.query.await([[INSERT IGNORE INTO players (citizenid, cid, license, name, money, charinfo, job, gang, position, metadata)
        VALUES (?, 1, ?, ?, '{}', ?, ?, '{}', '{}', '{}')]], { cid, 'license:' .. cid, cid,
        json.encode({ firstname = 'Off', lastname = cid, phone = phone }), json.encode(job or { name = 'unemployed' }) })
end

BeforeEach = function()
    Mock.reset()
    Mock.players, pushes, staff = {}, {}, {}
    clock = clock + 600000
    PFCitizen.__resetLimits()
    PFCitizen.__resetStaffCache()
    for src, phone in pairs({ [A] = '5550001', [B] = '5550002' }) do
        local p = Mock.newPlayer(src)
        p.PlayerData.charinfo.phone = phone
        p.PlayerData.job = { name = 'unemployed', grade = { level = 0 }, onduty = true }
    end
end

describe('the migration', function()
    it('keeps old phone mail in the inbox and widens the subject', function()
        local old = MySQL.single.await("SELECT * FROM player_mails WHERE mailid = 111111")
        assert_eq(old.folder, 'inbox')
        assert_eq(old.sender_type, 'system')
        local width = MySQL.scalar.await([[SELECT CHARACTER_MAXIMUM_LENGTH FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'player_mails' AND COLUMN_NAME = 'subject']])
        assert_eq(tonumber(width), 128)
        local res = M.List(A, { folder = 'inbox' })
        assert_eq(res.mails[#res.mails].subject, 'Before the update')
    end)
end)

describe('player to player', function()
    it('arrives with the server identity, with a sent copy in one thread', function()
        local res = M.SendFromPlayer(A, { to = '5550002@ls.mail', subject = 'Lunch?', message = 'Noon at the pier', sender = 'Mayor', senderType = 'government' })
        assert_eq(res.ok, true, tostring(res.error))
        local inbox = box('CID2', 'inbox')
        local mail = inbox[#inbox]
        assert_eq(mail.sender, 'Test Player1')
        assert_eq(mail.sender_cid, 'CID1')
        assert_eq(mail.sender_type, 'person')
        assert_eq(mail.sender_address, '5550001@ls.mail')
        assert_eq(tonumber(mail.read), 0)
        assert_true(tonumber(mail.mailid) ~= nil, 'phone mail id')
        local sent = box('CID1', 'sent')
        assert_eq(sent[#sent].thread, mail.thread)
        assert_eq(sent[#sent].recipients, 'Test Player2 <5550002@ls.mail>')
        assert_eq(pushes[#pushes].cid, 'CID2')
        assert_eq(pushes[#pushes].event, 'new')
    end)
    it('reaches an offline citizen by citizen id, and the reply stays in the thread', function()
        addOffline('OFF1', '5550099')
        local res = M.SendFromPlayer(A, { to = 'cid:OFF1', subject = 'Rent', message = 'Due Friday' })
        assert_eq(res.ok, true, tostring(res.error))
        local got = box('OFF1', 'inbox')
        assert_eq(#got, 1)
        -- B writes to A, A replies, B sees both in the thread
        M.SendFromPlayer(B, { to = '5550001', subject = 'Car', message = 'Selling my car' })
        local aIn = box('CID1', 'inbox')
        local first = aIn[#aIn]
        local view = M.Get(A, { id = first.id })
        assert_eq(view.ok, true)
        assert_eq(view.mail.read, true)
        assert_eq(view.mail.replyTo, '5550002@ls.mail')
        assert_eq(M.SendFromPlayer(A, { to = view.mail.replyTo, replyTo = first.id, subject = 'Re: Car', message = 'How much?' }).ok, true)
        local bIn = box('CID2', 'inbox')
        local reply = bIn[#bIn]
        assert_eq(reply.thread, first.thread)
        local thread = M.Get(B, { id = reply.id }).thread
        assert_eq(#thread, 2)
        assert_eq(thread[1].mine, true)
        assert_eq(thread[2].message, 'How much?')
        -- a reply to someone else's mail id is refused
        assert_eq(M.SendFromPlayer(B, { to = '5550001', replyTo = first.id, subject = 'x', message = 'y' }).error, 'not_found')
    end)
    it('an unknown recipient stops the whole mail', function()
        local before = tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM player_mails'))
        local res = M.SendFromPlayer(A, { to = '5550002, 5551234', subject = 'x', message = 'y' })
        assert_eq(res.error, 'unknown_recipient')
        assert_eq(tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM player_mails')), before)
    end)
end)

describe('folders', function()
    it('delete goes to the trash, restore brings it back, delete in the trash is for good', function()
        M.SendFromPlayer(A, { to = '5550002', subject = 'Trash me', message = 'x' })
        local mail = box('CID2', 'inbox')
        mail = mail[#mail]
        assert_eq(M.Delete(A, { id = mail.id }).error, 'not_found')       -- not A's copy
        assert_eq(M.Delete(B, { id = mail.id }).trashed, true)
        assert_eq(row(mail.id).folder, 'trash')
        assert_eq(M.Restore(B, { id = mail.id }).folder, 'inbox')
        local sent = box('CID1', 'sent')
        sent = sent[#sent]
        M.Delete(A, { id = sent.id })
        assert_eq(M.Restore(A, { id = sent.id }).folder, 'sent')
        M.Delete(B, { id = mail.id })
        assert_eq(M.Delete(B, { id = mail.id }).deleted, true)
        assert_eq(row(mail.id), nil)
        M.Delete(A, { id = sent.id })
        assert_true(M.EmptyTrash(A).deleted >= 1)
        assert_eq(row(sent.id), nil)
    end)
    it('drafts are saved, updated and removed when sent', function()
        local d = M.SaveDraft(A, { to = '5550002', subject = 'Draft', message = 'v1' })
        assert_eq(d.ok, true)
        assert_eq(M.SaveDraft(A, { id = d.id, to = '5550002', subject = 'Draft', message = 'v2' }).ok, true)
        assert_eq(row(d.id).message, 'v2')
        assert_eq(M.SaveDraft(B, { id = d.id, subject = 'mine', message = 'x' }).error, 'not_found')
        assert_eq(M.SendFromPlayer(A, { to = '5550002', subject = 'Draft', message = 'v2', draftId = d.id }).ok, true)
        assert_eq(row(d.id), nil)
    end)
    it('search matches text, and wildcards only themselves', function()
        M.SendFromPlayer(A, { to = '5550002', subject = 'Invoice 100% paid', message = 'thanks' })
        M.SendFromPlayer(A, { to = '5550002', subject = 'Other', message = 'nothing' })
        local res = M.List(B, { folder = 'inbox', search = '100%' })
        assert_eq(#res.mails, 1)
        assert_eq(res.mails[1].subject, 'Invoice 100% paid')
        assert_eq(#M.List(B, { folder = 'inbox', search = '%' }).mails, 1)
        assert_true(M.List(B, { folder = 'inbox' }).counts.unread >= 2)
    end)
end)

describe('server senders', function()
    it('SendMail reaches offline citizens and stores a ref once', function()
        addOffline('OFF2', '5550098')
        local id = X.SendMail('OFF2', { sender = 'DMV', subject = 'Plates', message = 'Ready', ref = 'dmv:1' })
        assert_true(id ~= nil)
        local again, err = X.SendMail('OFF2', { sender = 'DMV', subject = 'Plates', message = 'Ready', ref = 'dmv:1' })
        assert_eq(again, nil)
        assert_eq(err, 'duplicate')
        assert_eq(#box('OFF2', 'inbox'), 1)
        assert_eq(X.SendMail('NOBODY', { subject = 'x', message = 'y' }), nil)
        -- the phone's export signature
        assert_true(X.sendNewMailToOffline('OFF2', { sender = 'Garage', subject = 'Car', message = 'Fixed', button = { enabled = true } }) ~= nil)
        local last = box('OFF2', 'inbox')
        assert_true(last[#last].button:find('enabled', 1, true) ~= nil)
    end)
    it('SendMailToJob: on duty only, or everyone employed there', function()
        Mock.players[A].PlayerData.job = { name = 'police', onduty = true }
        Mock.players[B].PlayerData.job = { name = 'police', onduty = false }
        addOffline('COP9', '5550097', { name = 'police' })
        assert_eq(X.SendMailToJob('police', { sender = 'Chief', subject = 'Briefing', message = 'Now' }, true), 1)
        assert_eq(X.SendMailToJob('police', { sender = 'Chief', subject = 'Memo', message = 'Read it' }, false), 3) -- both online officers and offline COP9
    end)
    it('SendMailToBusiness: the owner and bosses from the registry', function()
        MySQL.query.await("INSERT INTO pf_gov_businesses (business_id, business_name, owner_id, owner_name) VALUES ('restaurant:pier', 'Pier Diner', 'CID1', 'A')")
        staff['restaurant:pier'] = { { citizenid = 'CID2', role = 'manager' }, { citizenid = 'OFF1', role = 'staff' } }
        assert_eq(X.SendMailToBusiness('restaurant:pier', { sender = 'Supplier', senderType = 'business', subject = 'Order', message = 'Shipped' }), 2)
        assert_eq(#box('OFF1', 'inbox'), 1)                -- staff do not get the business's mail
        assert_eq(select(2, X.SendMailToBusiness('restaurant:none', { subject = 'x', message = 'y' })), 'unknown_business')
        -- a citizen writes to the business
        addOffline('CUST', '5550096')
        Mock.newPlayer(5, 'CUST').PlayerData.charinfo.phone = '5550096'
        assert_eq(M.SendFromPlayer(5, { to = 'biz:restaurant:pier', subject = 'Booking', message = 'Table for 2' }).delivered, 2)
    end)
end)

describe('broadcasts', function()
    it('every citizen gets a government announcement once; edits and withdrawals reach the copies', function()
        TriggerEvent('pf-computer:gov:announcements:sync', { action = 'create', announcement = { id = 5, title = 'Road works', body = 'Main St closed', author = 'Mayor' } })
        local function copies(cid) return MySQL.query.await("SELECT * FROM player_mails WHERE citizenid = ? AND ref = 'bc:gov:announcement:5'", { cid }) end
        assert_eq(#copies('CID1'), 1)
        assert_eq(#copies('CID2'), 1)
        assert_eq(copies('CID1')[1].sender_type, 'government')
        assert_eq(M.DeliverBroadcasts('CID1'), 0)
        -- an update edits the copies, no second copy
        X.SyncGovernmentAnnouncement({ id = 5, title = 'Road works extended', body = 'Until Monday' })
        assert_eq(#copies('CID1'), 1)
        assert_eq(copies('CID1')[1].subject, '[City Hall] Road works extended')
        -- deleted for good stays deleted
        local id = copies('CID2')[1].id
        M.Delete(B, { id = id }); M.Delete(B, { id = id })
        assert_eq(M.DeliverBroadcasts('CID2'), 0)
        -- an offline citizen gets it when they log in
        assert_eq(M.DeliverBroadcasts('OFF1'), 1)
        TriggerEvent('pf-computer:gov:announcements:sync', { action = 'delete', announcementId = 5 })
        assert_eq(#copies('CID1'), 0)
        addOffline('LATE', '5550095')
        assert_eq(M.DeliverBroadcasts('LATE'), 0)
    end)
    it('a notice sent twice (pf-citizen and pf-computer both hear pf-government) is mailed once', function()
        local function count(subject) return tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM player_mails WHERE citizenid = 'CID1' AND subject = ?", { subject })) end
        -- the computer first, then the event
        assert_eq(X.SendMailToAll({ sender = 'City Hall', senderType = 'government', subject = '[City Hall] Fire drill', message = 'Friday' }), true)
        TriggerEvent('pf-computer:gov:announcements:sync', { action = 'create', announcement = { id = 9, title = 'Fire drill', body = 'Friday at noon' } })
        assert_eq(count('[City Hall] Fire drill'), 1)
        assert_eq(MySQL.scalar.await("SELECT ref FROM player_mails WHERE citizenid = 'CID1' AND subject = '[City Hall] Fire drill'"), 'bc:gov:announcement:9')
        -- the event first, then the computer
        TriggerEvent('pf-computer:gov:announcements:sync', { action = 'create', announcement = { id = 10, title = 'Water off' } })
        assert_eq(X.SendMailToAll({ sender = 'City Hall', subject = '[City Hall] Water off', message = 'Sunday' }), true)
        assert_eq(count('[City Hall] Water off'), 1)
        -- the withdrawal still reaches the merged copy
        X.RemoveGovernmentAnnouncement(9)
        assert_eq(count('[City Hall] Fire drill'), 0)
    end)
    it('published laws are mailed once per action', function()
        TriggerEvent('pf-computer:gov:laws:sync', { action = 'publish', law = { id = 3, title = 'Speed limit', content = '50 in town' } })
        local got = MySQL.query.await("SELECT subject FROM player_mails WHERE citizenid = 'CID1' AND ref = 'bc:gov:law:3:publish'")
        assert_eq(#got, 1)
        assert_eq(got[1].subject, '[City Hall Laws] Published: Speed limit')
    end)
end)

describe('other resources sending for a player', function()
    it("SendMailAs is the player's own send, and old computer addresses still work", function()
        local res = X.SendMailAs(A, { to = 'cid2@los-santos.gov', subject = 'From the computer', message = 'hi', sender = 'Fake' })
        assert_eq(res.ok, true, tostring(res.error))
        local got = box('CID2', 'inbox')
        assert_eq(got[#got].sender, 'Test Player1')
        assert_eq(got[#got].sender_cid, 'CID1')
        assert_eq(#box('CID1', 'sent') > 0, true)
        assert_eq(X.SendMailAs(A, 'x').error, 'bad_request')
        -- a server sender calling itself a citizen is shown as a person
        X.SendMail('CID2', { sender = 'Test Player1', senderCid = 'CID1', senderType = 'citizen', subject = 'Job board', message = 'Applied' })
        got = box('CID2', 'inbox')
        assert_eq(got[#got].sender_type, 'person')
    end)
end)

describe('the phone', function()
    it("the phone's own inserts land in the inbox and its delete query still works", function()
        MySQL.insert.await('INSERT INTO player_mails (`citizenid`, `sender`, `subject`, `message`, `mailid`, `read`) VALUES (?, ?, ?, ?, ?, ?)',
            { 'CID1', 'Dealer', 'Job', 'Go', 424242, 0 })
        local res = M.List(A, { folder = 'inbox' })
        assert_eq(res.mails[1].subject, 'Job')
        MySQL.query.await('DELETE FROM player_mails WHERE mailid = ? AND citizenid = ?', { 424242, 'CID1' })
        assert_eq(MySQL.scalar.await('SELECT COUNT(*) FROM player_mails WHERE mailid = 424242'), 0)
    end)
end)
