-- pf-citizen (Mail, Bills, Documents, Calendar) through the real pf-devices RPC bridge, on a scripted
-- database: who may use the apps, the sender identity always comes from the server, rate limits and
-- input validation, and the bills / calendar permission checks. SQL behaviour is in the real-DB specs.
load_resource('tests/lua/fivem_mocks.lua')

-- a scriptable database: Responder(kind, query, params) answers; every call is recorded
local calls = {}
local Responder = function() return nil end
local nextId = 100
local function db(kind)
    local fn = function(query, params, cb)
        if type(params) == 'function' then cb, params = params, nil end
        calls[#calls + 1] = { kind = kind, query = query, params = params or {} }
        local out = Responder(kind, query, params or {})
        if out == nil then
            if kind == 'insert' then nextId = nextId + 1; out = nextId
            elseif kind == 'update' then out = 1
            elseif kind == 'query' then out = {} end
        end
        if cb then cb(out) end
        return out
    end
    return setmetatable({ await = function(q, p) return fn(q, p) end }, { __call = function(_, ...) return fn(...) end })
end
MySQL = { query = db('query'), insert = db('insert'), update = db('update'), scalar = db('scalar'), single = db('single') }

local started = { ['pf-devices'] = true, ['pf-citizen'] = true, ['pfm-core'] = true, ['pf-government'] = true, ['pfm-phone'] = true }
function GetResourceState(name) return started[name] and 'started' or 'missing' end
local clock = 0
function GetGameTimer() return clock end
QBCoreMock.Functions.GetPlayerByPhone = function(number)
    for _, p in pairs(Mock.players) do if p.PlayerData.charinfo.phone == number then return p end end
end

-- pf-devices, for real
Config = {}
load_resource('[pfscripts]/pf-devices/shared/config.lua')
function GetCurrentResourceName() return 'pf-devices' end
for _, f in ipairs({ 'registry', 'installs', 'rpc', 'push', 'sites', 'builtin_apps', 'main' }) do
    load_resource('[pfscripts]/pf-devices/server/' .. f .. '.lua')
end
Mock.exportsByResource['pf-devices'] = Mock.exportsByResource['__self']
Mock.exportsByResource['__self'] = nil

-- the government and the phone as other resources see them
local gov = { perms = {}, manages = {} }
Mock.exportsByResource['pf-government'] = {
    HasPermission = function(_, src, perm) return gov.perms[src] ~= nil and gov.perms[src][perm] == true end,
    ManagesBusiness = function(_, src, id) return gov.manages[src] ~= nil and gov.manages[src][id] == true end,
    GetBusinessEmployees = function() return { ok = true, employees = {} } end,
}
local phonePays = {}
Mock.exportsByResource['pfm-phone'] = {
    PayInvoice = function(_, src, id) phonePays[#phonePays + 1] = { src = src, id = id } return true end,
    RefreshMails = function() return true end,
}
local charges = {}
PFPayout = {
    NewId = function() return 'n' end,
    Charge = function(who, acc, amount, opts) charges[#charges + 1] = { who = who, amount = amount, opts = opts } return false, { error = 'insufficient_funds' } end,
    Transfer = function() return { ok = true } end,
}

function GetCurrentResourceName() return 'pf-citizen' end
for _, f in ipairs({ 'shared/config.lua', 'server/schema.lua', 'server/util.lua', 'server/mail.lua', 'server/bills.lua',
    'server/documents.lua', 'server/calendar.lua', 'server/apps.lua', 'server/main.lua' }) do
    load_resource('[pfscripts]/pf-citizen/' .. f)
end
local exportsOf = Mock.exportsByResource['__self']

local A, B, C3 = 1, 2, 3
local function rpc(src, app, method, payload) return PFDevices.HandleRpc(src, app, method, payload) end
local function inserts(text)
    local out = {}
    for _, c in ipairs(calls) do if c.query:find(text or 'INSERT', 1, true) and c.query:find('player_mails', 1, true) and c.query:find('INSERT', 1, true) then out[#out + 1] = c end end
    return out
end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    calls, charges, phonePays = {}, {}, {}
    Responder = function() return nil end
    gov.perms, gov.manages = {}, {}
    clock = clock + 600000
    PFCitizen.__resetLimits()
    PFDevices.__reset()
    PFDevices.__resetRpc()
    for src, phone in pairs({ [A] = '5550001', [B] = '5550002', [C3] = '5550003' }) do
        local p = Mock.newPlayer(src)
        p.PlayerData.charinfo.phone = phone
        p.PlayerData.job = { name = 'unemployed', grade = { level = 0 }, onduty = true }
    end
    Mock.invokingResource = 'pf-citizen'
    PFCitizen.RegisterApps()
    Mock.invokingResource = nil
end

describe('the apps on pf-devices', function()
    it('mail, bills, documents and calendar are on the tablet and the computer, for anyone', function()
        for _, id in ipairs({ 'mail', 'bills', 'documents', 'calendar' }) do
            local app = PFDevices.GetApp(id)
            assert_true(app ~= nil, id)
            assert_eq(app.resource, 'pf-citizen')
            assert_eq(app.access.anyone, true)
            assert_eq(table.concat(app.devices, ','), 'computer,tablet')
        end
        local list = PFDevices.GetAppsFor(B, 'tablet').apps
        local seen = {}
        for _, a in ipairs(list) do seen[a.id] = true end
        assert_true(seen.mail and seen.bills and seen.documents and seen.calendar, 'apps missing on the tablet')
    end)
    it('a payload that is not a table never reaches a handler', function()
        local res = rpc(A, 'mail', 'send', 'hello')
        assert_eq(res.ok, false)
        assert_eq(res.error, 'bad_request')
        assert_eq(#inserts(), 0)
    end)
end)

describe('mail identity', function()
    it('the sender is the server player, whatever the client says', function()
        local res = rpc(A, 'mail', 'send', { to = '5550002', subject = 'Hi', message = 'Hello', sender = 'The Mayor',
            senderCid = 'CID2', senderType = 'government', senderAddress = 'mayor@city', button = { buttonEvent = 'x' } })
        assert_eq(res.ok, true, tostring(res.error))
        local ins = inserts()
        assert_eq(#ins, 2)
        local inbox, sent = ins[1].params, ins[2].params
        assert_eq(inbox[1], 'CID2')
        assert_eq(inbox[2], 'Test Player1')
        assert_eq(inbox[7], nil)                 -- no button from a player
        assert_eq(inbox[8], 'inbox')
        assert_eq(inbox[10], 'person')
        assert_eq(inbox[11], 'CID1')
        assert_eq(inbox[12], '5550001@ls.mail')
        assert_eq(sent[1], 'CID1')
        assert_eq(sent[8], 'sent')
        assert_eq(sent[9], inbox[9])             -- one thread
    end)
    it('a player cannot attach a bill, nor a document they cannot read', function()
        local res = rpc(A, 'mail', 'send', { to = '5550002', subject = 'x', message = 'y', attachments = { { type = 'bill', ref = 'gov:1' } } })
        assert_eq(res.error, 'bad_attachments')
        res = rpc(A, 'mail', 'send', { to = '5550002', subject = 'x', message = 'y', attachments = { { type = 'document', id = 9 } } })
        assert_eq(res.error, 'attachment_not_allowed')
        assert_eq(#inserts(), 0)
    end)
    it('server senders may attach bills, and a ref is stored once', function()
        local id = exportsOf.SendMail('CID2', { sender = 'City Hall', senderType = 'government', subject = 'Fine', message = 'Pay it',
            attachments = { { type = 'bill', ref = 'gov:12' } }, ref = 'bill:gov:12' })
        assert_true(id ~= nil)
        local ins = inserts()
        assert_true(ins[1].query:find('INSERT IGNORE', 1, true) ~= nil, 'ref without IGNORE')
        assert_true(ins[1].params[14]:find('gov:12', 1, true) ~= nil)
        assert_eq(ins[1].params[10], 'government')
        assert_eq(exportsOf.SendMail('CID2', { subject = 'x' }), nil)            -- no message
        assert_eq(exportsOf.SendMail('NOPE', { subject = 'x', message = 'y' }), nil)
    end)
end)

describe('mail validation', function()
    it('needs recipients, a subject and a message', function()
        assert_eq(rpc(A, 'mail', 'send', { subject = 's', message = 'm' }).error, 'no_recipients')
        assert_eq(rpc(A, 'mail', 'send', { to = 12345, subject = 's', message = 'm' }).error, 'no_recipients')
        assert_eq(rpc(A, 'mail', 'send', { to = '5550002', message = 'm' }).error, 'no_subject')
        assert_eq(rpc(A, 'mail', 'send', { to = '5550002', subject = 's', message = '   ' }).error, 'no_message')
        assert_eq(rpc(A, 'mail', 'send', { to = 'a,b,c,d,e,f', subject = 's', message = 'm' }).error, 'too_many_recipients')
        assert_eq(#inserts(), 0)
    end)
    it('one unknown recipient: nobody gets the mail', function()
        local res = rpc(A, 'mail', 'send', { to = '5550002, 5559999', subject = 's', message = 'm' })
        assert_eq(res.error, 'unknown_recipient')
        assert_eq(res.recipient, '5559999')
        assert_eq(#inserts(), 0)
    end)
    it('wildcards in an address match nobody', function()
        local res = rpc(A, 'mail', 'send', { to = '%', subject = 's', message = 'm' })
        assert_eq(res.ok, false)
        for _, c in ipairs(calls) do
            if c.query:find('LIKE', 1, true) then assert_true(not tostring(c.params[1]):find('"phone":"%', 1, true), 'wildcard reached LIKE') end
        end
    end)
end)

describe('mail rate limit', function()
    it('a burst of mails is allowed, then sending waits', function()
        for i = 1, 5 do assert_eq(rpc(A, 'mail', 'send', { to = '5550002', subject = 's' .. i, message = 'm' }).ok, true, 'send ' .. i) end
        assert_eq(rpc(A, 'mail', 'send', { to = '5550002', subject = 's6', message = 'm' }).error, 'rate_limited')
        -- several recipients cost one token each
        clock = clock + 40000
        assert_eq(rpc(A, 'mail', 'send', { to = '5550002,5550003,5550001', subject = 'x', message = 'm' }).error, 'rate_limited')
        clock = clock + 100000
        assert_eq(rpc(A, 'mail', 'send', { to = '5550002,5550003', subject = 'x', message = 'm' }).ok, true)
        -- each citizen has their own budget
        assert_eq(rpc(B, 'mail', 'send', { to = '5550001', subject = 'x', message = 'm' }).ok, true)
    end)
end)

describe('bills', function()
    it("someone else's government bill is not paid and nothing is charged", function()
        Responder = function(kind, query)
            if kind == 'single' and query:find('FROM pf_gov_bills WHERE id = ?', 1, true) then
                return { id = 7, target_type = 'citizen', target_id = 'CID2', amount = 100, amount_paid = 0, status = 'unpaid' }
            end
        end
        local res = rpc(A, 'bills', 'pay', { key = 'gov:7' })
        assert_eq(res.ok, false)
        assert_eq(res.error, 'not_found')
        assert_eq(#charges, 0)
    end)
    it("a business's bill needs someone who manages it", function()
        Responder = function(kind, query)
            if kind == 'single' and query:find('FROM pf_gov_bills WHERE id = ?', 1, true) then
                return { id = 8, target_type = 'business', target_id = 'store:1', amount = 100, amount_paid = 0, status = 'unpaid' }
            end
        end
        assert_eq(rpc(A, 'bills', 'pay', { key = 'gov:8' }).error, 'not_found')
        gov.manages[A] = { ['store:1'] = true }
        assert_eq(rpc(A, 'bills', 'pay', { key = 'gov:8' }).error, 'insufficient_funds')
        assert_eq(#charges, 1)
        assert_eq(charges[1].amount, 100)               -- the stored amount
        assert_eq(charges[1].opts.to, 'system:pf-government-fines')
    end)
    it('a phone invoice is paid by pfm-phone, as the real player', function()
        local res = rpc(A, 'bills', 'pay', { key = 'phone:4', src = 99, amount = 1 })
        assert_eq(res.ok, true)
        assert_eq(#phonePays, 1)
        assert_eq(phonePays[1].src, A)
        assert_eq(phonePays[1].id, 4)
    end)
    it('bad keys and amounts are refused', function()
        assert_eq(rpc(A, 'bills', 'pay', { key = 'gov:abc' }).error, 'bad_request')
        assert_eq(rpc(A, 'bills', 'pay', { key = 'other:1' }).error, 'bad_request')
        assert_eq(rpc(A, 'bills', 'pay', { key = 'gov:1', amount = -5 }).error, 'bad_amount')
        assert_eq(rpc(A, 'bills', 'pay', { key = 'gov:1', amount = 0 / 0 }).error, 'bad_amount')
        assert_eq(rpc(A, 'bills', 'decline', { key = 'gov:1' }).error, 'not_declinable')
        assert_eq(#charges + #phonePays, 0)
    end)
end)

describe('calendar permissions', function()
    local function eventInserts()
        local out = {}
        for _, c in ipairs(calls) do if c.query:find('INSERT INTO pf_citizen_events', 1, true) then out[#out + 1] = c end end
        return out
    end
    it('a personal event belongs to the server citizen id, whatever is sent', function()
        local res = rpc(A, 'calendar', 'create', { title = 'Dentist', starts = os.time() + 3600, owner = 'CID2', scope = 'personal' })
        assert_eq(res.ok, true, tostring(res.error))
        local ins = eventInserts()
        assert_eq(#ins, 1)
        assert_eq(ins[1].params[1], 'personal')
        assert_eq(ins[1].params[2], 'CID1')
        assert_eq(ins[1].params[10], 'CID1')
    end)
    it('city events need the government permission', function()
        assert_eq(rpc(A, 'calendar', 'create', { scope = 'city', title = 'Parade', starts = os.time() + 3600 }).error, 'not_authorized')
        gov.perms[A] = { laws = true }
        assert_eq(rpc(A, 'calendar', 'create', { scope = 'city', title = 'Parade', starts = os.time() + 3600 }).ok, true)
        local ins = eventInserts()
        assert_eq(#ins, 1)
        assert_eq(ins[1].params[2], 'city')
    end)
    it('business events need someone who manages the business', function()
        assert_eq(rpc(A, 'calendar', 'create', { scope = 'business', businessId = 'store:1', title = 'Stocktake', starts = os.time() + 3600 }).error, 'not_authorized')
        assert_eq(#eventInserts(), 0)
    end)
    it('times and reminders are checked', function()
        assert_eq(rpc(A, 'calendar', 'create', { title = 'x', starts = os.time() + 400 * 86400 }).error, 'bad_time')
        assert_eq(rpc(A, 'calendar', 'create', { title = 'x', starts = 'soon' }).error, 'bad_time')
        assert_eq(rpc(A, 'calendar', 'create', { title = 'x', starts = os.time() + 60, ends = os.time() }).error, 'bad_end')
        assert_eq(rpc(A, 'calendar', 'create', { title = 'x', starts = os.time() + 60, remind = 99999 }).error, 'bad_reminder')
        assert_eq(rpc(A, 'calendar', 'create', { starts = os.time() + 60 }).error, 'no_title')
    end)
end)

describe('documents', function()
    it('checks size, ownership and recipients', function()
        assert_eq(rpc(A, 'documents', 'save', { title = 'Big', body = string.rep('x', 20001) }).error, 'too_long')
        assert_eq(rpc(A, 'documents', 'save', { body = 'no title' }).error, 'no_title')
        Responder = function(kind, query, params)
            if kind == 'single' and query:find('FROM pf_citizen_documents WHERE id = ?', 1, true) then
                return { id = params[1], owner_cid = 'CID2', title = 'Lease', body = 'text', locked = 0 }
            end
            if kind == 'scalar' and query:find('FROM pf_citizen_document_shares', 1, true) then return 1 end
        end
        -- shared with A, owned by B: A may not hand out links nor edit it
        assert_eq(rpc(A, 'documents', 'share', { id = 5, to = '5550003', mode = 'link' }).error, 'not_owner')
        assert_eq(rpc(A, 'documents', 'save', { id = 5, title = 'Mine now', body = 'x' }).error, 'not_found')
        assert_eq(rpc(B, 'documents', 'share', { id = 5, to = '5550002', mode = 'link' }).error, 'self')
    end)
end)

describe('text cleaning', function()
    it('keeps line breaks in messages, drops other control characters, cuts on a character boundary', function()
        assert_eq(PFCitizen.Text('a\tb\nc\0d\r\ne', 100, true), 'ab\ncd\ne')
        assert_eq(PFCitizen.Text('one\ntwo', 100), 'one two')
        assert_eq(PFCitizen.Text('   ', 100), nil)
        assert_eq(PFCitizen.Text(12, 100), nil)
        assert_eq(PFCitizen.Cut('aé', 2), 'a')          -- é is two bytes
    end)
end)
