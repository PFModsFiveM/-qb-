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
load_resource('tests/lua/gov_registry_exports.lua')

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

-- runs fn once just before the next statement containing `fragment` (as if it landed meanwhile)
local function before(fragment, fn)
    local update = MySQL.update
    MySQL.update = setmetatable({ await = function(q, params)
        if fn and type(q) == 'string' and q:find(fragment, 1, true) then
            local run = fn
            fn = nil
            MySQL.update = update
            run()
        end
        return update.await(q, params)
    end }, { __call = function(_, ...) return update(...) end })
    return function() MySQL.update = update end
end
local function count(sql, params) return tonumber(MySQL.scalar.await(sql, params)) or 0 end
local function lastAttachment(cid)
    local rows = box(cid, 'inbox')
    local m = rows[#rows]
    return m and m.attachments and tonumber(m.attachments:match('"ref":"(%d+)"'))
end

describe('documents: who hands out access', function()
    it('the owner_hidden column is there (migration 2, run twice at start)', function()
        assert_eq(count([[SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE()
            AND TABLE_NAME = 'pf_citizen_documents' AND COLUMN_NAME = 'owner_hidden']]), 1)
        assert_eq(count("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = 'pf-citizen' AND version = 2"), 1)
    end)
    it('a reader who mails a document sends each recipient a locked copy, never a link', function()
        local id = D.Save(A, { title = 'Quote', body = 'Paint job $800' }).id
        assert_true(D.Share(A, { id = id, to = '5550002', mode = 'link' }).ok)
        local res = M.SendFromPlayer(B, { to = '5550003', subject = 'Quote', message = 'Attached', attachments = { { type = 'document', id = id } } })
        assert_eq(res.ok, true, tostring(res.error))
        assert_eq(count('SELECT COUNT(*) FROM pf_citizen_document_shares WHERE document_id = ? AND citizenid = ?', { id, 'CID3' }), 0)
        assert_eq(D.Get(C3, { id = id }).error, 'not_found')
        local copy = lastAttachment('CID3')
        assert_true(copy ~= nil and copy ~= id)
        local row = MySQL.single.await('SELECT owner_cid, locked, copied_from, body FROM pf_citizen_documents WHERE id = ?', { copy })
        assert_eq(row.owner_cid, 'CID3')
        assert_eq(tonumber(row.locked), 1)
        assert_eq(tonumber(row.copied_from), id)
        assert_eq(row.body, 'Paint job $800')
        assert_eq(D.Save(C3, { id = copy, title = 'Quote', body = 'Paint job $1' }).error, 'locked')
        -- the owner's own mail still gives a link to the original
        assert_true(M.SendFromPlayer(A, { to = '5550003', subject = 'Quote', message = 'Here', attachments = { { type = 'document', id = id } } }).ok)
        assert_eq(lastAttachment('CID3'), id)
        assert_eq(D.Get(C3, { id = id }).document.own, false)
    end)
    it('one copy for a citizen who gets the mail as a person and as the owner of a business', function()
        MySQL.query.await("INSERT INTO pf_gov_businesses (business_id, business_name, owner_id, owner_name) VALUES ('shop:docs', 'Doc Shop', 'CID3', 'C')")
        local id = D.Save(A, { title = 'Menu', body = 'Soup' }).id
        D.Share(A, { id = id, to = '5550002', mode = 'link' })
        local mine = count("SELECT COUNT(*) FROM pf_citizen_documents WHERE owner_cid = 'CID3'")
        local res = M.SendFromPlayer(B, { to = '5550003, biz:shop:docs', subject = 'Menu', message = 'x', attachments = { { type = 'document', id = id } } })
        assert_eq(res.ok, true, tostring(res.error))
        assert_eq(res.delivered, 2)
        assert_eq(count("SELECT COUNT(*) FROM pf_citizen_documents WHERE owner_cid = 'CID3'"), mine + 1)
    end)
    it('a link someone other than the owner gave out can neither sign nor lock', function()
        local id = D.Save(A, { title = 'Lease', body = 'Rent $500' }).id
        D.Share(A, { id = id, to = '5550002', mode = 'link' })
        -- a link B passed on (how mail worked before)
        MySQL.insert.await("INSERT INTO pf_citizen_document_shares (document_id, citizenid, shared_by) VALUES (?, 'CID3', 'CID2')", { id })
        assert_eq(D.Get(C3, { id = id }).document.canSign, false)
        assert_eq(D.Sign(C3, { id = id }).error, 'sign_not_allowed')
        assert_eq(count('SELECT locked FROM pf_citizen_documents WHERE id = ?', { id }), 0)
        assert_eq(count('SELECT COUNT(*) FROM pf_citizen_document_signatures WHERE document_id = ?', { id }), 0)
        -- the owner sees that link and can take it back
        local cids = {}
        for _, w in ipairs(D.Get(A, { id = id }).document.sharedWith) do cids[#cids + 1] = w.cid end
        table.sort(cids)
        assert_eq(table.concat(cids, ','), 'CID2,CID3')
        assert_eq(D.Unshare(A, { id = id, cid = 'CID3' }).ok, true)
        assert_eq(D.Get(C3, { id = id }).error, 'not_found')
        assert_eq(D.Sign(B, { id = id }).ok, true)
    end)
    it('a link taken back between the lock and the signature leaves the document unsigned and editable', function()
        local id = D.Save(A, { title = 'Draft', body = 'v1' }).id
        D.Share(A, { id = id, to = '5550002', mode = 'link' })
        local undo = before('INSERT IGNORE INTO pf_citizen_document_signatures', function()
            assert_eq(count('SELECT locked FROM pf_citizen_documents WHERE id = ?', { id }), 1)
            assert_eq(D.Unshare(A, { id = id, cid = 'CID2' }).ok, true)
        end)
        local res = D.Sign(B, { id = id })
        undo()
        assert_eq(res.error, 'not_found')
        assert_eq(count('SELECT COUNT(*) FROM pf_citizen_document_signatures WHERE document_id = ?', { id }), 0)
        assert_eq(count('SELECT locked FROM pf_citizen_documents WHERE id = ?', { id }), 0)
        assert_eq(D.Save(A, { id = id, title = 'Draft', body = 'v2' }).ok, true)
    end)
end)

describe('documents someone else signed', function()
    it("the owner's delete only takes it off the owner's list: signers keep it, the others lose their link", function()
        local id = D.Save(A, { title = 'Car sale', body = 'A sells the car to B for $9000' }).id
        D.Share(A, { id = id, to = '5550002', mode = 'link' })
        D.Share(A, { id = id, to = '5550003', mode = 'link' })
        assert_eq(D.Sign(B, { id = id }).ok, true)
        local res = D.Delete(A, { id = id })
        assert_eq(res.ok, true)
        assert_eq(res.hidden, true)
        assert_eq(MySQL.scalar.await('SELECT deleted_at FROM pf_citizen_documents WHERE id = ?', { id }), nil)
        assert_eq(count('SELECT owner_hidden FROM pf_citizen_documents WHERE id = ?', { id }), 1)
        assert_eq(D.Get(B, { id = id }).document.title, 'Car sale')
        assert_eq(#D.Get(B, { id = id }).document.signatures, 1)
        assert_eq(D.Get(C3, { id = id }).error, 'not_found')
        for _, d in ipairs(D.List(A).mine) do assert_true(d.id ~= id, 'still on the owner list') end
        local listed = false
        for _, d in ipairs(D.List(B).shared) do if d.id == id then listed = true end end
        assert_true(listed, 'the signer lost it from their list')
        -- hidden documents do not count against the owner's limit
        assert_eq(count("SELECT COUNT(*) FROM pf_citizen_documents WHERE owner_cid = 'CID1' AND deleted_at IS NULL AND owner_hidden = 0 AND id = ?", { id }), 0)
    end)
    it('stop sharing is refused for a signer; a signer who removes it from their list still reads it', function()
        local id = D.Save(A, { title = 'Loan', body = 'B owes A $500' }).id
        D.Share(A, { id = id, to = '5550002', mode = 'link' })
        assert_eq(D.Sign(B, { id = id }).ok, true)
        assert_eq(D.Unshare(A, { id = id, cid = 'CID2' }).error, 'signed')
        assert_eq(count('SELECT COUNT(*) FROM pf_citizen_document_shares WHERE document_id = ? AND citizenid = ?', { id, 'CID2' }), 1)
        assert_eq(D.Delete(B, { id = id }).removed, true)
        assert_eq(D.Get(B, { id = id }).document.title, 'Loan')
    end)
    it('a signature landing during the delete or the unshare statement wins', function()
        local id = D.Save(A, { title = 'Bond', body = 'x' }).id
        D.Share(A, { id = id, to = '5550002', mode = 'link' })
        local sign = function()
            MySQL.insert.await("INSERT INTO pf_citizen_document_signatures (document_id, citizenid, name, fingerprint) VALUES (?, 'CID2', 'B', REPEAT('0', 64))", { id })
        end
        local undo = before('DELETE h FROM pf_citizen_document_shares', sign)
        local res = D.Unshare(A, { id = id, cid = 'CID2' })
        undo()
        assert_eq(res.error, 'signed')
        local id2 = D.Save(A, { title = 'Bond 2', body = 'y' }).id
        D.Share(A, { id = id2, to = '5550002', mode = 'link' })
        undo = before('deleted_at = NOW()', function()
            MySQL.insert.await("INSERT INTO pf_citizen_document_signatures (document_id, citizenid, name, fingerprint) VALUES (?, 'CID2', 'B', REPEAT('0', 64))", { id2 })
        end)
        res = D.Delete(A, { id = id2 })
        undo()
        assert_eq(res.hidden, true)
        assert_eq(D.Get(B, { id = id2 }).document.title, 'Bond 2')
    end)
    it("only the owner's own signature: the owner still deletes it for everyone", function()
        local id = D.Save(A, { title = 'Memo', body = 'z' }).id
        D.Share(A, { id = id, to = '5550002', mode = 'link' })
        assert_eq(D.Sign(A, { id = id }).ok, true)
        assert_eq(D.Delete(A, { id = id }).deleted, true)
        assert_eq(D.Get(B, { id = id }).error, 'not_found')
    end)
    it('a deleted owner: a document someone else signed stays with the signer', function()
        local id = D.Save(C3, { title = 'Witness', body = 'Seen at 9pm' }).id
        D.Share(C3, { id = id, to = '5550002', mode = 'link' })
        assert_eq(D.Sign(B, { id = id }).ok, true)
        assert_eq(D.Unshare(C3, { id = id, cid = 'CID2' }).error, 'signed')
        -- even without a share left, the signature keeps it
        MySQL.update.await("DELETE FROM pf_citizen_document_shares WHERE document_id = ?", { id })
        Mock.eventHandlers['pfm-core:server:characterDeleted']('CID3')
        assert_eq(MySQL.scalar.await('SELECT deleted_at FROM pf_citizen_documents WHERE id = ?', { id }), nil)
        assert_eq(D.Get(B, { id = id }).document.title, 'Witness')
    end)
end)

describe('documents when a character is deleted', function()
    it('private documents go; documents shared with others stay with them; their access to others goes', function()
        local cleanup = Mock.eventHandlers['pfm-core:server:characterDeleted']
        assert_true(type(cleanup) == 'function', 'pf-citizen listens for deleted characters')
        local private = D.Save(A, { title = 'Diary', body = 'Private notes' }).id
        local contract = D.Save(A, { title = 'Sale contract', body = 'A sells the boat to B' }).id
        assert_true(D.Share(A, { id = contract, to = '5550002', mode = 'link' }).ok)
        local fromC = D.Save(C3, { title = 'Invite', body = 'Party on Friday' }).id
        assert_true(D.Share(C3, { id = fromC, to = '5550001', mode = 'link' }).ok)
        MySQL.query.await("INSERT INTO pf_citizen_bill_history (citizenid, source, ref, title, amount) VALUES ('CID1', 'phone', 'r1', 'Old bill', 10)")

        cleanup({})            -- ignored
        cleanup('CID1')
        assert_eq(D.Get(B, { id = contract }).document.title, 'Sale contract', 'B keeps the shared contract')
        assert_true(MySQL.scalar.await('SELECT deleted_at FROM pf_citizen_documents WHERE id = ?', { private }) ~= nil, 'private document deleted')
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_citizen_document_shares WHERE citizenid = 'CID1'")), 0)
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM pf_citizen_bill_history WHERE citizenid = 'CID1'")), 0)
        assert_eq(D.Get(C3, { id = fromC }).document.title, 'Invite', 'C keeps their own document')
    end)
end)

-- runs fn once just before the next insert containing `fragment`; `fail` makes that insert fail
local function beforeInsert(fragment, fn, fail)
    local insert = MySQL.insert
    MySQL.insert = setmetatable({ await = function(q, params)
        if type(q) == 'string' and q:find(fragment, 1, true) and (not fail or fail(params)) then
            MySQL.insert = insert
            if fn then fn() end
            if fail then return nil end
        end
        return insert.await(q, params)
    end }, { __call = function(_, ...) return insert(...) end })
    return function() MySQL.insert = insert end
end
local function copies(cid) return count('SELECT COUNT(*) FROM pf_citizen_documents WHERE owner_cid = ? AND copied_from IS NOT NULL AND deleted_at IS NULL', { cid }) end
local function withLimits(own, received, fn)
    local cfg = CitizenConfig.Documents
    local a, b = cfg.MaxPerCitizen, cfg.MaxReceivedCopies
    cfg.MaxPerCitizen, cfg.MaxReceivedCopies = own, received
    local ok, err = pcall(fn)
    cfg.MaxPerCitizen, cfg.MaxReceivedCopies = a, b
    assert(ok, err)
end
local function clearDocs()
    for _, t in ipairs({ 'pf_citizen_documents', 'pf_citizen_document_shares', 'pf_citizen_document_signatures' }) do MySQL.query.await('DELETE FROM ' .. t) end
end

describe('a copy of a signed document', function()
    it('the record column is there (migration 3, run twice at start)', function()
        assert_eq(count([[SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE()
            AND TABLE_NAME = 'pf_citizen_documents' AND COLUMN_NAME = 'copied_signatures']]), 1)
        assert_eq(count("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = 'pf-citizen' AND version = 3"), 1)
    end)
    it('a mailed copy carries the signatures as a read-only record, never as signatures on the copy', function()
        local id = D.Save(A, { title = 'Car sale', body = 'A sells the car to B for $9000' }).id
        D.Share(A, { id = id, to = '5550002', mode = 'link' })
        assert_eq(D.Sign(B, { id = id }).ok, true)
        assert_eq(D.Sign(A, { id = id }).ok, true)
        local res = M.SendFromPlayer(B, { to = '5550003', subject = 'Proof', message = 'Signed contract', attachments = { { type = 'document', id = id } } })
        assert_eq(res.ok, true, tostring(res.error))
        local copy = lastAttachment('CID3')
        assert_true(copy ~= nil and copy ~= id)
        local doc = D.Get(C3, { id = copy }).document
        assert_eq(#doc.signatures, 0, 'the record became signatures on the copy')
        assert_eq(count('SELECT COUNT(*) FROM pf_citizen_document_signatures WHERE document_id = ?', { copy }), 0)
        assert_eq(doc.othersSigned, false)
        local rec = doc.signatureRecord
        assert_true(rec ~= nil, 'the copy looks unsigned')
        assert_eq(#rec.signatures, 2)
        local names = { rec.signatures[1].name, rec.signatures[2].name }
        table.sort(names)
        assert_eq(table.concat(names, ','), 'Test Player1,Test Player2')
        local fp = MySQL.scalar.await("SELECT SHA2(CONCAT('Car sale', '\n', 'A sells the car to B for $9000'), 256)")
        assert_eq(rec.signatures[1].fingerprint, fp)
        assert_eq(rec.signatures[1].matches, true)
        assert_true(rec.signatures[1].at ~= nil)
        -- a record does not keep the copy from its owner: C3 deletes it like any document of theirs
        assert_eq(D.Delete(C3, { id = copy }).deleted, true)
    end)
    it('a copy of that copy keeps the record; changing the text of a copy drops it', function()
        local id = D.Save(A, { title = 'Lease', body = 'Rent $500' }).id
        D.Share(A, { id = id, to = '5550002', mode = 'link' })
        assert_eq(D.Sign(B, { id = id }).ok, true)
        local res = D.Share(B, { id = id, to = '5550003', mode = 'copy' })
        assert_eq(res.ok, true, tostring(res.error))
        local again = D.Share(C3, { id = res.id, to = '5550001', mode = 'copy' })
        assert_eq(again.ok, true, tostring(again.error))
        assert_eq(#D.Get(A, { id = again.id }).document.signatureRecord.signatures, 1)
        local listed
        for _, d in ipairs(D.List(C3).mine) do if d.id == res.id then listed = d end end
        assert_eq(listed.copy, true)
        assert_eq(listed.signedOriginal, true)
        assert_eq(D.Save(C3, { id = res.id, title = 'Lease', body = 'Rent $1' }).ok, true)
        assert_eq(D.Get(C3, { id = res.id }).document.signatureRecord, nil)
        assert_eq(MySQL.scalar.await('SELECT copied_signatures FROM pf_citizen_documents WHERE id = ?', { res.id }), nil)
    end)
    it('a signature made on a copy is recorded as made on that copy, not on the original', function()
        local id = D.Save(A, { title = 'Deed', body = 'Plot 7' }).id
        D.Share(A, { id = id, to = '5550002', mode = 'link' })
        assert_eq(D.Sign(B, { id = id }).ok, true)
        local mid = D.Share(B, { id = id, to = '5550003', mode = 'copy' })
        assert_eq(mid.ok, true, tostring(mid.error))
        assert_eq(D.Sign(C3, { id = mid.id }).ok, true, 'the owner of the copy signs it')
        local last = D.Share(C3, { id = mid.id, to = '5550001', mode = 'copy' })
        assert_eq(last.ok, true, tostring(last.error))
        local byName = {}
        for _, s in ipairs(D.Get(A, { id = last.id }).document.signatureRecord.signatures) do byName[s.name] = s end
        assert_eq(byName['Test Player2'].onCopy, false, 'B signed the original')
        assert_eq(byName['Test Player3'].onCopy, true, "C3's signature on their copy shown as one on the original")
        assert_eq(byName['Test Player3'].matches, true)
    end)
end)

describe('copies others send', function()
    it('count against their own limit, never against the documents a citizen writes', function()
        clearDocs()
        withLimits(2, 3, function()
            local id = D.Save(A, { title = 'Flyer', body = 'Sale' }).id
            D.Share(A, { id = id, to = '5550002', mode = 'link' })
            for i = 1, 3 do
                local res = M.SendFromPlayer(B, { to = '5550003', subject = 'Flyer ' .. i, message = 'x', attachments = { { type = 'document', id = id } } })
                assert_eq(res.ok, true, tostring(res.error))
            end
            assert_eq(copies('CID3'), 3)
            assert_eq(D.Save(C3, { title = 'Mine 1', body = 'a' }).ok, true, 'copies filled the room for their own documents')
            assert_eq(D.Save(C3, { title = 'Mine 2', body = 'b' }).ok, true)
            assert_eq(D.Save(C3, { title = 'Mine 3', body = 'c' }).error, 'too_many_documents')
            local mails = #box('CID3', 'inbox')
            assert_eq(M.SendFromPlayer(B, { to = '5550003', subject = 'Flyer 4', message = 'x', attachments = { { type = 'document', id = id } } }).error, 'recipient_full')
            assert_eq(#box('CID3', 'inbox'), mails, 'nothing is sent')
            assert_eq(D.Share(B, { id = id, to = '5550003', mode = 'copy' }).error, 'recipient_full')
            assert_eq(copies('CID3'), 3)
            assert_eq(#D.List(C3).mine, 5)
        end)
    end)
    it('the limit is checked in the copy statement: room taken after the check sends the mail without it and tells the sender', function()
        clearDocs()
        withLimits(10, 1, function()
            local id = D.Save(A, { title = 'Offer', body = 'Ten crates' }).id
            D.Share(A, { id = id, to = '5550002', mode = 'link' })
            local other = D.Save(A, { title = 'Other', body = 'x' }).id
            local undo = beforeInsert('SELECT ?, d.title, d.body, d.id', function()
                MySQL.insert.await('INSERT INTO pf_citizen_documents (owner_cid, title, body, copied_from, locked) VALUES (?, ?, ?, ?, 1)', { 'CID3', 'Other', 'x', other })
            end)
            local res = M.SendFromPlayer(B, { to = '5550003', subject = 'Offer', message = 'x', attachments = { { type = 'document', id = id } } })
            undo()
            assert_eq(res.ok, true, tostring(res.error))
            assert_eq(res.delivered, 1)
            assert_true(res.missing ~= nil, 'the sender was not told')
            assert_eq(res.missing[1].recipient, 'Test Player3')
            assert_eq(res.missing[1].document, 'Offer')
            assert_eq(res.missing[1].error, 'recipient_full')
            assert_eq(copies('CID3'), 1, 'over the limit')
            assert_eq(lastAttachment('CID3'), nil)
        end)
    end)
end)

describe('copies and links only for a delivered mail', function()
    local toC3 = function(params) return params and params[1] == 'CID3' end
    it('a mail to them that is not stored leaves no copy behind', function()
        clearDocs()
        local id = D.Save(A, { title = 'Quote', body = 'Paint $800' }).id
        D.Share(A, { id = id, to = '5550002', mode = 'link' })
        local undo = beforeInsert('INTO player_mails', nil, toC3)
        local res = M.SendFromPlayer(B, { to = '5550003', subject = 'Quote', message = 'x', attachments = { { type = 'document', id = id } } })
        undo()
        assert_eq(res.ok, false)
        assert_eq(res.error, 'not_stored')
        assert_eq(count("SELECT COUNT(*) FROM pf_citizen_documents WHERE owner_cid = 'CID3'"), 0, 'an orphan copy')
        -- two recipients, one not stored: the other gets it and the sender is told who did not
        undo = beforeInsert('INTO player_mails', nil, toC3)
        res = M.SendFromPlayer(B, { to = '5550003, 5550001', subject = 'Quote', message = 'x', attachments = { { type = 'document', id = id } } })
        undo()
        assert_eq(res.ok, true, tostring(res.error))
        assert_eq(res.delivered, 1)
        assert_eq(res.undelivered[1], 'Test Player3')
        assert_eq(count("SELECT COUNT(*) FROM pf_citizen_documents WHERE owner_cid = 'CID3'"), 0)
    end)
    -- oxmysql raises on a SQL error (deadlock, lock wait timeout) instead of returning nil
    local function raiseOnInsert(fragment, filter)
        local insert = MySQL.insert
        MySQL.insert = setmetatable({ await = function(q, params)
            if type(q) == 'string' and q:find(fragment, 1, true) and (not filter or filter(params)) then
                MySQL.insert = insert
                error('SQL error: Lock wait timeout exceeded')
            end
            return insert.await(q, params)
        end }, { __call = function(_, ...) return insert(...) end })
        return function() MySQL.insert = insert end
    end
    it('a mail insert that raises leaves no copy behind; the others still get the mail', function()
        clearDocs()
        local id = D.Save(A, { title = 'Quote', body = 'Paint $800' }).id
        D.Share(A, { id = id, to = '5550002', mode = 'link' })
        local mails = #box('CID1', 'inbox')
        local undo = raiseOnInsert('INTO player_mails', toC3)
        local okCall, res = pcall(M.SendFromPlayer, B, { to = '5550003, 5550001', subject = 'Quote', message = 'x', attachments = { { type = 'document', id = id } } })
        undo()
        assert_true(okCall, 'the send aborted: ' .. tostring(res))
        assert_eq(res.ok, true, tostring(res.error))
        assert_eq(res.delivered, 1)
        assert_eq(res.undelivered[1], 'Test Player3')
        assert_eq(count("SELECT COUNT(*) FROM pf_citizen_documents WHERE owner_cid = 'CID3'"), 0, 'an orphan copy')
        assert_eq(#box('CID1', 'inbox'), mails + 1, 'the other recipient did not get it')
        assert_eq(#box('CID2', 'sent') > 0, true)
        -- the only recipient: not stored, nothing left
        undo = raiseOnInsert('INTO player_mails', toC3)
        okCall, res = pcall(M.SendFromPlayer, B, { to = '5550003', subject = 'Quote', message = 'x', attachments = { { type = 'document', id = id } } })
        undo()
        assert_true(okCall, tostring(res))
        assert_eq(res.error, 'not_stored')
        assert_eq(count("SELECT COUNT(*) FROM pf_citizen_documents WHERE owner_cid = 'CID3'"), 0, 'an orphan copy')
    end)
    it('a copy statement that raises takes back the copies already made for that recipient', function()
        clearDocs()
        local one = D.Save(A, { title = 'One', body = '1' }).id
        local two = D.Save(A, { title = 'Two', body = '2' }).id
        D.Share(A, { id = one, to = '5550002', mode = 'link' })
        D.Share(A, { id = two, to = '5550002', mode = 'link' })
        local seen, mails = 0, #box('CID3', 'inbox')
        local undo = raiseOnInsert('SELECT ?, d.title, d.body, d.id', function() seen = seen + 1 return seen == 2 end)
        local okCall, res = pcall(M.SendFromPlayer, B, { to = '5550003', subject = 'Both', message = 'x',
            attachments = { { type = 'document', id = one }, { type = 'document', id = two } } })
        undo()
        assert_true(okCall, tostring(res))
        assert_eq(res.error, 'not_stored')
        assert_eq(count("SELECT COUNT(*) FROM pf_citizen_documents WHERE owner_cid = 'CID3'"), 0, 'the first copy stayed')
        assert_eq(#box('CID3', 'inbox'), mails)
        -- the next send works and makes both copies
        res = M.SendFromPlayer(B, { to = '5550003', subject = 'Both', message = 'x', attachments = { { type = 'document', id = one }, { type = 'document', id = two } } })
        assert_eq(res.ok, true, tostring(res.error))
        assert_eq(copies('CID3'), 2)
    end)
    it('a share as a copy whose mail raises takes the copy back', function()
        clearDocs()
        local id = D.Save(A, { title = 'Menu', body = 'Soup' }).id
        local undo = raiseOnInsert('INTO player_mails', toC3)
        local okCall, res = pcall(D.Share, A, { id = id, to = '5550003', mode = 'copy' })
        undo()
        assert_true(okCall, tostring(res))
        assert_eq(res.error, 'not_stored')
        assert_eq(count("SELECT COUNT(*) FROM pf_citizen_documents WHERE owner_cid = 'CID3'"), 0, 'an orphan copy')
    end)
    it("the owner's mail that raises takes back the link it made", function()
        local id = D.Save(A, { title = 'Plan B', body = 'x' }).id
        local undo = raiseOnInsert('INTO player_mails', toC3)
        local okCall, res = pcall(M.SendFromPlayer, A, { to = '5550003', subject = 'Plan', message = 'x', attachments = { { type = 'document', id = id } } })
        undo()
        assert_true(okCall, tostring(res))
        assert_eq(res.error, 'not_stored')
        assert_eq(count('SELECT COUNT(*) FROM pf_citizen_document_shares WHERE document_id = ? AND citizenid = ?', { id, 'CID3' }), 0)
    end)
    it("the owner's mail that is not stored takes back the link it made", function()
        local id = D.Save(A, { title = 'Plan', body = 'x' }).id
        local undo = beforeInsert('INTO player_mails', nil, toC3)
        local res = M.SendFromPlayer(A, { to = '5550003', subject = 'Plan', message = 'x', attachments = { { type = 'document', id = id } } })
        undo()
        assert_eq(res.error, 'not_stored')
        assert_eq(count('SELECT COUNT(*) FROM pf_citizen_document_shares WHERE document_id = ? AND citizenid = ?', { id, 'CID3' }), 0)
        assert_eq(D.Get(C3, { id = id }).error, 'not_found')
    end)
end)
