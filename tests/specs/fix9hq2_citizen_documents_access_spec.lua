-- pf-citizen documents: who gets access through mail, who may sign, and what the owner's delete and
-- "stop sharing" do once someone else signed. Runs the real documents and mail code on a small
-- in-memory model of the three document tables (the SQL itself is in the real-DB spec).
load_resource('tests/lua/fivem_mocks.lua')

-- ── the document tables, in memory ───────────────────────────────────
local S
local function resetStore() S = { docs = {}, shares = {}, sigs = {}, mails = {}, nextDoc = 0 } end
resetStore()
local function key(d, c) return tostring(tonumber(d)) .. '|' .. tostring(c) end
local function has(q, t) return q:find(t, 1, true) ~= nil end
local function live(id) local d = S.docs[tonumber(id) or -1]; if d and not d.deleted then return d end end
local function given(d, cid)   -- the MAY_SIGN condition
    if d.owner_cid == cid then return true end
    local h = S.shares[key(d.id, cid)]
    return h ~= nil and (h.shared_by == d.owner_cid or h.shared_by == 'system')
end
local function othersSigned(d)
    for _, s in pairs(S.sigs) do if s.document_id == d.id and s.citizenid ~= d.owner_cid then return true end end
    return false
end

local function handle(kind, q, p)
    if has(q, 'player_mails') then
        if kind == 'insert' then S.mails[#S.mails + 1] = { cid = p[1], subject = p[3], folder = p[8], attachments = p[14] }; return #S.mails end
        if kind == 'query' then return {} end
        if kind == 'scalar' then return 0 end
        if kind == 'single' then return nil end
        return 0
    end
    if kind == 'single' then
        if has(q, 'FROM pf_citizen_documents WHERE id = ?') then
            local d = live(p[1])
            if not d then return nil end
            return { id = d.id, owner_cid = d.owner_cid, title = d.title, body = d.body, copied_from = d.copied_from,
                locked = d.locked, owner_hidden = d.owner_hidden, created = 1, updated = 1 }
        end
        return nil   -- players table: everyone here is online
    end
    if kind == 'scalar' then
        if has(q, 'SELECT owner_cid FROM pf_citizen_documents') then local d = live(p[1]); return d and d.owner_cid end
        if has(q, 'SELECT shared_by FROM pf_citizen_document_shares') then local h = S.shares[key(p[1], p[2])]; return h and h.shared_by end
        if has(q, 'SELECT 1 FROM pf_citizen_document_shares') then return S.shares[key(p[1], p[2])] and 1 or nil end
        if has(q, 'SELECT 1 FROM pf_citizen_document_signatures') then return S.sigs[key(p[1], p[2])] and 1 or nil end
        if has(q, 'COUNT(*) FROM pf_citizen_documents WHERE owner_cid = ?') then
            local n = 0
            for _, d in pairs(S.docs) do
                if d.owner_cid == p[1] and not d.deleted and (d.owner_hidden == 0 or not has(q, 'owner_hidden')) then n = n + 1 end
            end
            return n
        end
        error('unexpected scalar: ' .. q)
    end
    if kind == 'insert' then
        if has(q, 'INSERT INTO pf_citizen_documents') then
            S.nextDoc = S.nextDoc + 1
            S.docs[S.nextDoc] = { id = S.nextDoc, owner_cid = p[1], title = p[2], body = p[3], copied_from = p[4],
                locked = has(q, ', 1)') and 1 or 0, owner_hidden = 0 }
            return S.nextDoc
        end
        error('unexpected insert: ' .. q)
    end
    if kind == 'query' then
        if has(q, 'FROM pf_citizen_document_signatures WHERE document_id = ?') then
            local out = {}
            for _, s in pairs(S.sigs) do
                if s.document_id == tonumber(p[1]) then out[#out + 1] = { citizenid = s.citizenid, name = s.name, fingerprint = 'fp', at = 1 } end
            end
            table.sort(out, function(a, b) return a.citizenid < b.citizenid end)
            return out
        end
        if has(q, 'SELECT citizenid FROM pf_citizen_document_shares WHERE document_id = ?') then
            local out = {}
            for _, h in pairs(S.shares) do if h.document_id == tonumber(p[1]) then out[#out + 1] = { citizenid = h.citizenid } end end
            table.sort(out, function(a, b) return a.citizenid < b.citizenid end)
            return out
        end
        if has(q, 'FROM pf_citizen_documents d WHERE d.owner_cid = ?') then
            local out = {}
            for _, d in pairs(S.docs) do
                if d.owner_cid == p[1] and not d.deleted and (d.owner_hidden == 0 or not has(q, 'owner_hidden')) then
                    out[#out + 1] = { id = d.id, title = d.title, locked = d.locked, updated = 1, signs = 0, shares = 0 }
                end
            end
            return out
        end
        if has(q, 'FROM pf_citizen_document_shares h JOIN pf_citizen_documents d') then
            local out = {}
            for _, h in pairs(S.shares) do
                local d = live(h.document_id)
                if d and h.citizenid == p[1] then out[#out + 1] = { id = d.id, title = d.title, locked = d.locked, owner_cid = d.owner_cid, updated = 1, signs = 0 } end
            end
            return out
        end
        error('unexpected query: ' .. q)
    end
    if kind == 'update' then
        if has(q, 'INSERT IGNORE INTO pf_citizen_document_shares') then
            local k = key(p[1], p[2])
            if S.shares[k] then return 0 end
            S.shares[k] = { document_id = tonumber(p[1]), citizenid = p[2], shared_by = p[3] }
            return 1
        end
        if has(q, 'SET locked = 1') or has(q, 'SET d.locked = 1') then
            local d = live(p[1])
            if not d then return 0 end
            if has(q, 'shared_by') and not given(d, p[2]) then return 0 end
            if d.locked == 1 then return 0 end
            d.locked = 1
            return 1
        end
        if has(q, 'INSERT IGNORE INTO pf_citizen_document_signatures') then
            local cid, name, d = p[1], p[2], live(p[3])
            if not d then return 0 end
            if has(q, 'shared_by') and not given(d, cid) then return 0 end
            local k = key(d.id, cid)
            if S.sigs[k] then return 0 end
            S.sigs[k] = { document_id = d.id, citizenid = cid, name = name }
            return 1
        end
        if has(q, 'deleted_at = NOW()') then
            local d = live(p[1])
            if not d or d.owner_cid ~= p[2] then return 0 end
            if has(q, 'NOT EXISTS') and othersSigned(d) then return 0 end
            d.deleted = true
            return 1
        end
        if has(q, 'SET owner_hidden = 1') then
            local d = live(p[1])
            if d and d.owner_cid == p[2] then d.owner_hidden = 1; return 1 end
            return 0
        end
        if has(q, 'DELETE') and has(q, 'pf_citizen_document_shares') then
            local guarded, n = has(q, 'NOT EXISTS'), 0
            for k, h in pairs(S.shares) do
                if h.document_id == tonumber(p[1]) and (p[2] == nil or h.citizenid == p[2])
                    and not (guarded and S.sigs[key(h.document_id, h.citizenid)]) then
                    S.shares[k] = nil
                    n = n + 1
                end
            end
            return n
        end
        error('unexpected update: ' .. q)
    end
    error('unexpected ' .. kind .. ': ' .. q)
end

local function db(kind)
    local fn = function(query, params, cb)
        if type(params) == 'function' then cb, params = params, nil end
        local out = handle(kind, query, params or {})
        if cb then cb(out) end
        return out
    end
    return setmetatable({ await = function(q, p) return fn(q, p) end }, { __call = function(_, ...) return fn(...) end })
end
MySQL = { query = db('query'), insert = db('insert'), update = db('update'), scalar = db('scalar'), single = db('single') }

local started = { ['pf-devices'] = true, ['pfm-core'] = true }
function GetResourceState(name) return started[name] and 'started' or 'missing' end
local clock = 0
function GetGameTimer() return clock end
QBCoreMock.Functions.GetPlayerByPhone = function(number)
    for _, p in pairs(Mock.players) do if p.PlayerData.charinfo.phone == number then return p end end
end
Mock.exportsByResource['pf-devices'] = {
    PushToCitizen = function() return true end,
    RegisterApp = function() return true end,
    RegisterAppHandlers = function() return true end,
    Broadcast = function() return true end,
}
PFPayout = { NewId = function() return 'n' end, Charge = function() return false, { error = 'x' } end, Transfer = function() return { ok = true } end }

function GetCurrentResourceName() return 'pf-citizen' end
for _, f in ipairs({ 'shared/config.lua', 'server/schema.lua', 'server/util.lua', 'server/mail.lua', 'server/bills.lua',
    'server/documents.lua', 'server/calendar.lua', 'server/apps.lua', 'server/main.lua' }) do
    load_resource('[pfscripts]/pf-citizen/' .. f)
end
local M, D = PFCitizen.Mail, PFCitizen.Documents

local A, B, C3 = 1, 2, 3

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    resetStore()
    clock = clock + 600000
    PFCitizen.__resetLimits()
    for src, phone in pairs({ [A] = '5550001', [B] = '5550002', [C3] = '5550003' }) do
        local p = Mock.newPlayer(src)
        p.PlayerData.charinfo.phone = phone
        p.PlayerData.job = { name = 'unemployed', grade = { level = 0 }, onduty = true }
    end
end

local function newDoc(src, title, body) return D.Save(src, { title = title, body = body or 'text' }).id end
local function lastMailTo(cid)
    for i = #S.mails, 1, -1 do if S.mails[i].cid == cid and S.mails[i].folder ~= 'sent' then return S.mails[i] end end
end
local function attachedRef(mail)
    return mail and mail.attachments and tonumber(mail.attachments:match('"ref":"(%d+)"'))
end

describe('documents attached to player mail', function()
    it('a reader who mails a document sends a read-only copy, never a link to the original', function()
        local id = newDoc(A, 'Contract', 'A sells the car to B')
        assert_eq(D.Share(A, { id = id, to = '5550002', mode = 'link' }).ok, true)
        local res = M.SendFromPlayer(B, { to = '5550003', subject = 'Look', message = 'See attached', attachments = { { type = 'document', id = id } } })
        assert_eq(res.ok, true, tostring(res.error))
        -- C3 gets no access to A's document
        assert_eq(S.shares[key(id, 'CID3')], nil, 'a link was handed out by someone who is not the owner')
        assert_eq(D.Get(C3, { id = id }).error, 'not_found')
        assert_eq(D.Sign(C3, { id = id }).error, 'not_found')
        assert_eq(S.docs[id].locked, 0, 'the original got locked')
        -- their mail points at a snapshot copy they own, read-only
        local copy = attachedRef(lastMailTo('CID3'))
        assert_true(copy ~= nil and copy ~= id, 'the attachment still points at the original')
        local doc = D.Get(C3, { id = copy }).document
        assert_eq(doc.own, true)
        assert_eq(doc.body, 'A sells the car to B')
        assert_eq(doc.canEdit, false)
        assert_eq(doc.copiedFrom, id)
        assert_eq(D.Save(C3, { id = copy, title = 'x', body = 'y' }).error, 'locked')
        -- the sender's own sent copy still points at the document they read
        for _, m in ipairs(S.mails) do if m.folder == 'sent' then assert_eq(attachedRef(m), id) end end
    end)
    it('the owner taking a link back is not undone by a reader mailing it', function()
        local id = newDoc(A, 'Plan')
        D.Share(A, { id = id, to = '5550002', mode = 'link' })
        D.Share(A, { id = id, to = '5550003', mode = 'link' })
        assert_eq(D.Unshare(A, { id = id, cid = 'CID3' }).ok, true)
        assert_eq(M.SendFromPlayer(B, { to = 'CID3', subject = 'Again', message = 'Here', attachments = { { type = 'document', id = id } } }).ok, true)
        assert_eq(D.Get(C3, { id = id }).error, 'not_found')
    end)
    it("the owner's mail still gives a read-only link to the original", function()
        local id = newDoc(A, 'Map')
        assert_eq(M.SendFromPlayer(A, { to = '5550003', subject = 'Look', message = 'x', attachments = { { type = 'document', id = id } } }).ok, true)
        assert_eq(attachedRef(lastMailTo('CID3')), id)
        assert_eq(D.Get(C3, { id = id }).document.own, false)
        assert_eq(S.shares[key(id, 'CID3')].shared_by, 'CID1')
    end)
    it('mailing it to its owner, or to someone who can read it already, attaches the original and copies nothing', function()
        local id = newDoc(A, 'Lease')
        D.Share(A, { id = id, to = '5550002', mode = 'link' })
        D.Share(A, { id = id, to = '5550003', mode = 'link' })
        local before = S.nextDoc
        assert_eq(M.SendFromPlayer(B, { to = '5550001, 5550003', subject = 'Re', message = 'x', attachments = { { type = 'document', id = id } } }).ok, true)
        assert_eq(attachedRef(lastMailTo('CID1')), id)
        assert_eq(attachedRef(lastMailTo('CID3')), id)
        assert_eq(S.nextDoc, before, 'a copy was made')
    end)
    it('a recipient with no room for the copy: nothing is sent', function()
        local max = CitizenConfig.Documents.MaxPerCitizen
        CitizenConfig.Documents.MaxPerCitizen = 1
        local ok, err = pcall(function()
            local id = newDoc(A, 'Memo')
            D.Share(A, { id = id, to = '5550002', mode = 'link' })
            newDoc(C3, 'Full')
            local mails = #S.mails
            local res = M.SendFromPlayer(B, { to = '5550003', subject = 'x', message = 'y', attachments = { { type = 'document', id = id } } })
            assert_eq(res.error, 'recipient_full')
            assert_eq(#S.mails, mails)
        end)
        CitizenConfig.Documents.MaxPerCitizen = max
        assert(ok, err)
    end)
end)

describe('who may sign', function()
    it('a link someone other than the owner handed out can neither sign nor lock the document', function()
        local id = newDoc(A, 'Sale', 'Car for $9000')
        D.Share(A, { id = id, to = '5550002', mode = 'link' })
        -- a link B handed on (as mail did before)
        S.shares[key(id, 'CID3')] = { document_id = id, citizenid = 'CID3', shared_by = 'CID2' }
        assert_eq(D.Get(C3, { id = id }).document.canSign, false)
        assert_eq(D.Sign(C3, { id = id }).error, 'sign_not_allowed')
        assert_eq(S.docs[id].locked, 0, 'locked by someone the owner never gave it to')
        assert_eq(S.sigs[key(id, 'CID3')], nil)
        -- someone the owner gave it to can
        assert_eq(D.Get(B, { id = id }).document.canSign, true)
        assert_eq(D.Sign(B, { id = id }).ok, true)
        assert_eq(D.Get(B, { id = id }).document.canSign, false)
        assert_eq(D.Sign(B, { id = id }).error, 'already_signed')
        assert_eq(S.docs[id].locked, 1)
    end)
end)

describe('a document someone else signed', function()
    it("the owner's delete only takes it off the owner's list; signers keep it, others lose their link", function()
        local id = newDoc(A, 'Contract')
        D.Share(A, { id = id, to = '5550002', mode = 'link' })
        D.Share(A, { id = id, to = '5550003', mode = 'link' })
        assert_eq(D.Sign(B, { id = id }).ok, true)
        assert_eq(D.Get(A, { id = id }).document.othersSigned, true)
        local res = D.Delete(A, { id = id })
        assert_eq(res.ok, true)
        assert_eq(res.hidden, true)
        assert_eq(res.deleted, nil)
        assert_eq(D.Get(B, { id = id }).document.title, 'Contract', 'the signer lost the signed document')
        assert_eq(#D.Get(B, { id = id }).document.signatures, 1)
        local listed = false
        for _, d in ipairs(D.List(B).shared) do if d.id == id then listed = true end end
        assert_true(listed, 'the signer no longer lists it')
        for _, d in ipairs(D.List(A).mine) do assert_true(d.id ~= id, 'still on the owner list') end
        assert_eq(D.Get(A, { id = id }).document.hidden, true)
        assert_eq(D.Get(C3, { id = id }).error, 'not_found', 'someone who did not sign kept the link')
    end)
    it('stop sharing is refused for someone who signed', function()
        local id = newDoc(A, 'Lease')
        D.Share(A, { id = id, to = '5550002', mode = 'link' })
        D.Share(A, { id = id, to = '5550003', mode = 'link' })
        assert_eq(D.Sign(B, { id = id }).ok, true)
        local sharedWith = D.Get(A, { id = id }).document.sharedWith
        assert_eq(sharedWith[1].cid, 'CID2')
        assert_eq(sharedWith[1].signed, true)
        assert_eq(sharedWith[2].signed, false)
        assert_eq(D.Unshare(A, { id = id, cid = 'CID2' }).error, 'signed')
        assert_eq(D.Get(B, { id = id }).ok, true)
        assert_eq(D.Unshare(A, { id = id, cid = 'CID3' }).ok, true)
        assert_eq(D.Get(C3, { id = id }).error, 'not_found')
    end)
    it('a signer still reads it after taking it off their own list', function()
        local id = newDoc(A, 'Deed')
        D.Share(A, { id = id, to = '5550002', mode = 'link' })
        assert_eq(D.Sign(B, { id = id }).ok, true)
        assert_eq(D.Delete(B, { id = id }).removed, true)
        assert_eq(D.Get(B, { id = id }).document.title, 'Deed')
    end)
    it("only the owner's own signature: the owner still deletes it for everyone", function()
        local id = newDoc(A, 'Note')
        D.Share(A, { id = id, to = '5550002', mode = 'link' })
        assert_eq(D.Sign(A, { id = id }).ok, true)
        assert_eq(D.Get(A, { id = id }).document.othersSigned, false)
        assert_eq(D.Delete(A, { id = id }).deleted, true)
        assert_eq(D.Get(B, { id = id }).error, 'not_found')
    end)
    it('a deleted character keeps documents others signed', function()
        local found = false
        for _, q in ipairs(PFCitizen.CharacterCleanupQueries) do
            if q:find('UPDATE pf_citizen_documents d SET d.deleted_at', 1, true) then
                found = true
                assert_true(q:find('pf_citizen_document_signatures', 1, true) ~= nil, 'documents signed by others are deleted with their owner')
            end
        end
        assert_true(found)
    end)
end)
