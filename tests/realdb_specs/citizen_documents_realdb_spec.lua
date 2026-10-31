-- pf-citizen documents on a real database: stored per citizen, read-only links and copies, attached
-- to mail, signatures that stamp the signer and lock the text.
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

describe('documents', function()
    it('are saved, listed and edited by their owner only', function()
        local res = D.Save(A, { title = 'Lease', body = '# Lease\n**Rent** $500' })
        assert_eq(res.ok, true)
        assert_eq(D.Save(A, { id = res.id, title = 'Lease v2', body = 'Rent $550' }).ok, true)
        assert_eq(D.Get(A, { id = res.id }).document.title, 'Lease v2')
        assert_eq(D.Get(B, { id = res.id }).error, 'not_found')
        assert_eq(D.Save(B, { id = res.id, title = 'Mine', body = 'x' }).error, 'not_found')
        assert_eq(#D.List(A).mine, 1)
    end)
    it('a read-only link lets them read, not edit, and mails them the document', function()
        local id = D.Save(A, { title = 'Contract', body = 'I sell my car to B for $9000' }).id
        local res = D.Share(A, { id = id, to = '5550002', mode = 'link' })
        assert_eq(res.ok, true, tostring(res.error))
        local doc = D.Get(B, { id = id }).document
        assert_eq(doc.own, false)
        assert_eq(doc.canEdit, false)
        assert_eq(D.Save(B, { id = id, title = 'x', body = 'free car' }).error, 'not_found')
        assert_eq(D.Get(C3, { id = id }).error, 'not_found')
        local mail = box('CID2', 'inbox')
        mail = mail[#mail]
        assert_true(mail.attachments:find('"ref":"' .. id .. '"', 1, true) ~= nil, mail.attachments)
        assert_eq(mail.sender_cid, 'CID1')
        -- only the owner hands out links; the owner sees who has it and can take it back
        assert_eq(D.Share(B, { id = id, to = '5550003', mode = 'link' }).error, 'not_owner')
        assert_eq(D.Get(A, { id = id }).document.sharedWith[1].cid, 'CID2')
        assert_eq(D.Unshare(A, { id = id, cid = 'CID2' }).ok, true)
        assert_eq(D.Get(B, { id = id }).error, 'not_found')
    end)
    it('a copy belongs to the recipient and does not change the original', function()
        local id = D.Save(A, { title = 'Recipe', body = 'Flour' }).id
        local res = D.Share(A, { id = id, to = 'CID3', mode = 'copy' })
        assert_eq(res.ok, true)
        assert_true(res.id ~= id)
        assert_eq(D.Save(C3, { id = res.id, title = 'Recipe', body = 'Flour and sugar' }).ok, true)
        assert_eq(D.Get(A, { id = id }).document.body, 'Flour')
        assert_eq(D.Get(C3, { id = res.id }).document.copiedFrom, id)
    end)
    it('signing stamps the signer and the text, and locks the document', function()
        local id = D.Save(A, { title = 'Sale', body = 'Car for $9000' }).id
        D.Share(A, { id = id, to = '5550002', mode = 'link' })
        assert_eq(D.Sign(B, { id = id }).ok, true)
        assert_eq(D.Sign(B, { id = id }).error, 'already_signed')
        assert_eq(D.Sign(C3, { id = id }).error, 'not_found')
        assert_eq(D.Save(A, { id = id, title = 'Sale', body = 'Car for $1' }).error, 'locked')
        assert_eq(D.Sign(A, { id = id }).ok, true)
        local doc = D.Get(A, { id = id }).document
        assert_eq(#doc.signatures, 2)
        local names = { doc.signatures[1].name, doc.signatures[2].name }
        table.sort(names)
        assert_eq(table.concat(names, ','), 'Test Player1,Test Player2')
        local expect = MySQL.scalar.await("SELECT SHA2(CONCAT('Sale', '\n', 'Car for $9000'), 256)")
        assert_eq(doc.signatures[1].fingerprint, expect)
        assert_eq(doc.signatures[2].fingerprint, expect)
        assert_eq(doc.locked, true)
        -- the owner is told when someone else signs
        local got = box('CID1', 'inbox')
        assert_eq(got[#got].subject, 'Signed: Sale')
    end)
    it('mail attachments: readable documents only, and the recipient can open them', function()
        local id = D.Save(A, { title = 'Map', body = 'X marks the spot' }).id
        local other = D.Save(B, { title = 'Private', body = 'secret' }).id
        assert_eq(M.SendFromPlayer(A, { to = '5550003', subject = 'Look', message = 'See attached', attachments = { { type = 'document', id = other } } }).error, 'attachment_not_allowed')
        assert_eq(M.SendFromPlayer(A, { to = '5550003', subject = 'Look', message = 'See attached', attachments = { { type = 'document', id = id } } }).ok, true)
        assert_eq(D.Get(C3, { id = id }).document.title, 'Map')
    end)
    it('the owner deletes it for everyone; a reader only removes it from their list', function()
        local id = D.Save(A, { title = 'Note', body = 'x' }).id
        D.Share(A, { id = id, to = '5550002', mode = 'link' })
        D.Share(A, { id = id, to = '5550003', mode = 'link' })
        assert_eq(D.Delete(B, { id = id }).removed, true)
        assert_eq(D.Get(A, { id = id }).ok, true)
        assert_eq(D.Delete(A, { id = id }).deleted, true)
        assert_eq(D.Get(C3, { id = id }).error, 'not_found')
        for _, d in ipairs(D.List(C3).shared) do assert_true(d.id ~= id, 'still listed') end
    end)
end)
