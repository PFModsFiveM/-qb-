-- pfm-phone content the server now builds (batch 14):
--   PH-2  chats: one message per SendMessage, built by the server (sender, time, location, checked
--         picture link) and appended to both people's rows under a per-pair lock taken before the
--         first database wait; stored rows are cleaned when the phone loads them; the whole-chat
--         UpdateMessages event is gone;
--   X-4   phone settings: only a built-in background name or an allowed picture link, stored through
--         pfm-core (no raw players.metadata UPDATE); avatars shown to others are checked;
--   PH-3  camera: the upload runs on the server from server-only convars; the client gets only the
--         picture link (the GetWebhook callback is gone), one upload per 10 s, a phone needed;
--   and the other client-trusted paths found: advert picture links, tweet time/avatar/link, app alerts.
load_resource('tests/lua/fivem_mocks.lua')

-- ── a small phone_messages table and a scriptable rest ───────────────
local rows, nextId = {}, 1
local calls = {}
local Responder = function() return nil end
local onChatRead = nil -- called once on the next chat read (to play a message arriving meanwhile)
local function db(kind)
    local fn = function(query, params, cb)
        if type(params) == 'function' then cb, params = params, nil end
        params = params or {}
        calls[#calls + 1] = { kind = kind, query = query, params = params }
        local out = Responder(kind, query, params)
        if out == nil then
            if query:find('SELECT id, messages FROM phone_messages WHERE citizenid = ? AND number = ?', 1, true) then
                if onChatRead then local f = onChatRead; onChatRead = nil; f() end
                local best
                for _, r in ipairs(rows) do if r.citizenid == params[1] and r.number == params[2] and (not best or r.id > best.id) then best = r end end
                out = best and { { id = best.id, messages = best.messages } } or {}
            elseif query:find('UPDATE phone_messages SET messages = ? WHERE id = ?', 1, true) then
                for _, r in ipairs(rows) do if r.id == params[2] then r.messages = params[1] end end
                out = 1
            elseif query:find('INSERT INTO phone_messages', 1, true) then
                rows[#rows + 1] = { id = nextId, citizenid = params[1], number = params[2], messages = params[3] }
                nextId = nextId + 1
                out = nextId - 1
            elseif query:find('SELECT id, number, messages FROM phone_messages WHERE citizenid = ?', 1, true) then
                out = {}
                for _, r in ipairs(rows) do if r.citizenid == params[1] then out[#out + 1] = r end end
            else
                out = kind == 'scalar' and nil or {}
            end
        end
        if cb then cb(out) end
        return out
    end
    return setmetatable({ await = function(q, p) return fn(q, p) end }, { __call = function(_, ...) return fn(...) end })
end
MySQL = { query = db('query'), insert = db('insert'), update = db('update'), scalar = db('scalar'), single = db('single'), rawExecute = db('rawExecute') }

local function callsMatching(text)
    local out = {}
    for _, c in ipairs(calls) do if c.query:find(text, 1, true) then out[#out + 1] = c end end
    return out
end

-- ── FiveM pieces the camera uses ─────────────────────────────────────
local states = { ['screenshot-basic'] = 'started' }
function GetResourceState(name) return states[name] or 'missing' end
local convars = {}
function GetConvar(name, default) if convars[name] ~= nil then return convars[name] end return default end
local http = {}
local httpReply = { status = 200, body = '' }
function PerformHttpRequest(url, cb, method, body, headers)
    http[#http + 1] = { url = url, method = method, body = body, headers = headers }
    cb(httpReply.status, httpReply.body, {})
end
local shotData = nil
Mock.exportsByResource['screenshot-basic'] = {
    requestClientScreenshot = function(_, src, opts, cb) cb(false, shotData) end,
}

local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local function b64(data)
    return ((data:gsub('.', function(x)
        local r, b = '', x:byte()
        for i = 8, 1, -1 do r = r .. (b % 2 ^ i - b % 2 ^ (i - 1) > 0 and '1' or '0') end
        return r
    end) .. '0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
        if #x < 6 then return '' end
        local c = 0
        for i = 1, 6 do c = c + (x:sub(i, i) == '1' and 2 ^ (6 - i) or 0) end
        return B64:sub(c + 1, c + 1)
    end) .. ({ '', '==', '=' })[#data % 3 + 1])
end

QBCoreMock.Functions.GetPlayerByPhone = function(number)
    for _, p in pairs(Mock.players) do if p.PlayerData.charinfo.phone == number then return p end end
end
SetTimeout = function() end

Config = nil
load_resource('pfm-phone/config.lua')
load_resource('pfm-phone/server/main.lua')

local A, B, C = 1, 2, 3
local function player(src, phone)
    local p = Mock.newPlayer(src)
    p.PlayerData.charinfo.phone = phone
    p.PlayerData.metadata.phonedata = { InstalledApps = {} }
    p.Functions.GetItemByName = function(name) return name == 'phone' and { name = 'phone' } or nil end
    return p
end

local function chatOf(cid, number)
    local best
    for _, r in ipairs(rows) do if r.citizenid == cid and r.number == number and (not best or r.id > best.id) then best = r end end
    return best and json.decode(best.messages) or nil
end
local function allMessages(days)
    local out = {}
    for _, d in ipairs(days or {}) do for _, m in ipairs(d.messages) do out[#out + 1] = m end end
    return out
end
local function send(src, number, payload)
    Mock.gameTimer = Mock.gameTimer + 100000 -- past the rate limit
    Mock.fireNet('qb-phone:server:SendMessage', src, number, payload)
end
local function notes(src)
    local out = {}
    for _, e in ipairs(Mock.clientEventsNamed('qb-phone:client:CustomNotification')) do if e.target == src then out[#out + 1] = e.args[2] end end
    return out
end

local EVIL = '<img src=x onerror="$.post(\'https://pfm-phone/TransferMoney\',JSON.stringify({iban:\'X\',amount:5000}))">'

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords = {}, {}
    rows, nextId, calls, http = {}, 1, {}, {}
    Responder = function() return nil end
    onChatRead = nil
    convars, shotData = {}, nil
    httpReply = { status = 200, body = '' }
    Config.Fivemerr = false
    states['screenshot-basic'] = 'started'
    player(A, '5550001')
    player(B, '5550002')
    player(C, '5550003')
end

describe('chat messages (PH-2)', function()
    it('the server builds the message: sender, time and type are its own, extra fields are dropped', function()
        send(A, '5550002', { type = 'message', message = 'hello', sender = 'CID2', time = EVIL, data = { x = 1, url = 'javascript:1' } })
        local mine, theirs = allMessages(chatOf('CID1', '5550002')), allMessages(chatOf('CID2', '5550001'))
        assert_eq(#mine, 1)
        assert_eq(#theirs, 1)
        local m = theirs[1]
        assert_eq(m.sender, 'CID1')
        assert_eq(m.message, 'hello')
        assert_eq(m.type, 'message')
        assert_true(m.time:match('^%d%d:%d%d$') ~= nil, 'time not built by the server: ' .. tostring(m.time))
        assert_eq(next(m.data), nil)
        -- both phones get the one new message
        local ev = Mock.clientEventsNamed('qb-phone:client:ChatMessage')
        assert_eq(#ev, 2)
        assert_eq(ev[1].target, A)
        assert_eq(ev[1].args[1], '5550002')
        assert_eq(ev[1].args[4], true)
        assert_eq(ev[2].target, B)
        assert_eq(ev[2].args[1], '5550001')
        assert_eq(ev[2].args[3].sender, 'CID1')
    end)

    it("the other person's stored messages are kept: sending only appends", function()
        rows[1] = { id = 1, citizenid = 'CID2', number = '5550001', messages = json.encode({ { date = '1-0-2026', messages = {
            { sender = 'CID2', type = 'message', message = 'I said this', time = '10:00', data = {} },
            { sender = 'CID1', type = 'message', message = 'you said this', time = '10:01', data = {} },
        } } }) }
        nextId = 2
        send(A, '5550002', { type = 'message', message = 'new one' })
        local theirs = allMessages(chatOf('CID2', '5550001'))
        assert_eq(#theirs, 3)
        assert_eq(theirs[1].message, 'I said this')
        assert_eq(theirs[1].sender, 'CID2')
        assert_eq(theirs[3].message, 'new one')
        -- updated in place, not a second row
        assert_eq(#rows, 2)
    end)

    it('the old whole-chat event is gone', function()
        assert_eq(Mock.netHandlers['qb-phone:server:UpdateMessages'], nil)
    end)

    it('a location is where the sender stands, from the server', function()
        Mock.coords[A] = vector3(123.456, -50.554, 10)
        send(A, '5550002', { type = 'location', data = { x = 1, y = 2 } })
        local m = allMessages(chatOf('CID2', '5550001'))[1]
        assert_eq(m.type, 'location')
        assert_near(m.data.x, 123.46, 0.001)
        assert_near(m.data.y, -50.55, 0.001)
    end)

    it('a picture must be an allowed https link', function()
        send(A, '5550002', { type = 'picture', url = 'x onerror=alert(1)' })
        send(A, '5550002', { type = 'picture', url = 'https://evil.example/a.png' })
        send(A, '5550002', { type = 'picture', url = 'https://media.discordapp.net/a.png" onerror="x' })
        assert_eq(#rows, 0)
        assert_eq(#notes(A), 3)
        send(A, '5550002', { type = 'picture', url = 'https://media.discordapp.net/attachments/1/2/photo.jpg' })
        local m = allMessages(chatOf('CID2', '5550001'))[1]
        assert_eq(m.data.url, 'https://media.discordapp.net/attachments/1/2/photo.jpg')
        assert_eq(m.message, 'Photo')
    end)

    it('an unknown type, an empty text, yourself and a number nobody has send nothing', function()
        send(A, '5550002', { type = 'script', message = 'x' })
        send(A, '5550002', { type = 'message', message = '' })
        send(A, '5550001', { type = 'message', message = 'me' })
        Responder = function(_, query) if query:find('FROM players WHERE charinfo LIKE', 1, true) then return {} end end
        send(A, '5559999', { type = 'message', message = 'hi' })
        assert_eq(#rows, 0)
        assert_eq(notes(A)[1], 'This number does not exist')
    end)

    it('a message to someone offline is stored in their row too', function()
        Mock.players[B] = nil
        Responder = function(_, query)
            if query:find('FROM players WHERE charinfo LIKE', 1, true) then return { { citizenid = 'CID2', charinfo = '{"phone":"5550002"}' } } end
        end
        send(A, '5550002', { type = 'message', message = 'later' })
        assert_eq(allMessages(chatOf('CID2', '5550001'))[1].message, 'later')
        assert_eq(#Mock.clientEventsNamed('qb-phone:client:ChatMessage'), 1)
    end)

    it('without a phone nothing is sent', function()
        Mock.players[A].Functions.GetItemByName = function() return nil end
        send(A, '5550002', { type = 'message', message = 'hi' })
        assert_eq(#rows, 0)
    end)

    it('the pair lock is taken before the first database wait: a message meanwhile is refused, not lost silently', function()
        onChatRead = function()
            -- B answers while A's message waits on the database
            send(B, '5550001', { type = 'message', message = 'meanwhile' })
        end
        send(A, '5550002', { type = 'message', message = 'first' })
        local theirs = allMessages(chatOf('CID2', '5550001'))
        local mine = allMessages(chatOf('CID1', '5550002'))
        assert_eq(#theirs, 1)
        assert_eq(#mine, 1)
        assert_eq(theirs[1].message, 'first')
        assert_eq(notes(B)[1], 'The message was not sent, try again')
        -- the lock is released: B can send now
        send(B, '5550001', { type = 'message', message = 'again' })
        assert_eq(#allMessages(chatOf('CID1', '5550002')), 2)
    end)

    it('a chat keeps at most 200 messages (the oldest go)', function()
        local msgs = {}
        for i = 1, 200 do msgs[i] = { sender = 'CID1', type = 'message', message = 'm' .. i, time = '10:00', data = {} } end
        rows[1] = { id = 1, citizenid = 'CID1', number = '5550002', messages = json.encode({ { date = '1-0-2026', messages = msgs } }) }
        nextId = 2
        send(A, '5550002', { type = 'message', message = 'newest' })
        local mine = allMessages(chatOf('CID1', '5550002'))
        assert_eq(#mine, 200)
        assert_eq(mine[1].message, 'm2')
        assert_eq(mine[200].message, 'newest')
    end)
end)

describe('stored chats are cleaned when the phone loads them (PH-2)', function()
    it('forged senders, HTML in time or date, bad links and unknown types are dropped', function()
        rows[1] = { id = 1, citizenid = 'CID1', number = '5550002', messages = json.encode({
            { date = '1-0-2026', messages = {
                { sender = 'CID2', type = 'message', message = 'ok', time = EVIL, data = {} },
                { sender = '<b>x</b>', type = 'message', message = 'forged sender', time = '10:00', data = {} },
                { sender = 'CID2', type = 'picture', message = 'Photo', time = '10:00', data = { url = 'x onerror=alert(1)' } },
                { sender = 'CID2', type = 'location', message = 'x', time = '10:00', data = { x = '1"><img src=x>', y = 2 } },
                { sender = 'CID2', type = 'evil', message = 'x', time = '10:00', data = {} },
            } },
            { date = EVIL, messages = { { sender = 'CID2', type = 'message', message = 'bad day', time = '10:00', data = {} } } },
        }) }
        local data = Mock.callCallback('qb-phone:server:GetPhoneData', A)
        assert_eq(#data.Chats, 1)
        local days = json.decode(data.Chats[1].messages)
        assert_eq(#days, 1)
        assert_eq(#days[1].messages, 1)
        assert_eq(days[1].messages[1].message, 'ok')
        assert_eq(days[1].messages[1].time, '')
    end)
end)

describe('phone settings (X-4)', function()
    it('only a built-in background or an allowed link is stored, through pfm-core', function()
        Mock.players[A].PlayerData.metadata.phone = { profilepicture = 'https://i.imgur.com/old.png' }
        Mock.fireNet('qb-phone:server:SaveMetaData', A, {
            background = 'default-qbcore', profilepicture = 'x);"><img src=x onerror=alert(1)>', junk = string.rep('x', 5000),
        })
        local meta = Mock.players[A].PlayerData.metadata.phone
        assert_eq(meta.background, 'default-qbcore')
        assert_eq(meta.profilepicture, 'https://i.imgur.com/old.png')
        assert_eq(meta.junk, nil)
        assert_eq(#callsMatching('UPDATE players SET metadata'), 0)
        assert_eq(#Mock.clientEventsNamed('QBCore:Notify'), 1)
        Mock.fireNet('qb-phone:server:SaveMetaData', A, { background = 'https://i.imgur.com/bg.png', profilepicture = 'https://i.imgur.com/me.png' })
        meta = Mock.players[A].PlayerData.metadata.phone
        assert_eq(meta.background, 'https://i.imgur.com/bg.png')
        assert_eq(meta.profilepicture, 'https://i.imgur.com/me.png')
        Mock.fireNet('qb-phone:server:SaveMetaData', A, { background = "x'); background: url(javascript:1)" })
        assert_eq(Mock.players[A].PlayerData.metadata.phone.background, 'https://i.imgur.com/bg.png')
    end)

    it('an old stored avatar the phone sends back with a background change is replaced quietly', function()
        Mock.players[A].PlayerData.metadata.phone = { profilepicture = 'https://old-host.example/me.png' }
        Mock.fireNet('qb-phone:server:SaveMetaData', A, { background = 'default-qbcore', profilepicture = 'https://old-host.example/me.png' })
        local meta = Mock.players[A].PlayerData.metadata.phone
        assert_eq(meta.background, 'default-qbcore')
        assert_eq(meta.profilepicture, 'default')
        assert_eq(#Mock.clientEventsNamed('QBCore:Notify'), 0)
    end)

    it('an avatar stored before the check is shown to others as the default', function()
        Responder = function(_, query)
            if query:find('FROM players WHERE charinfo LIKE', 1, true) then
                return { { citizenid = 'CIDX', charinfo = '{}', metadata = json.encode({ phone = { profilepicture = 'x);"><img src=x>' } }) } }
            end
        end
        assert_eq(Mock.callCallback('qb-phone:server:GetPicture', A, '5550009'), 'default')
        Responder = function(_, query)
            if query:find('FROM players WHERE charinfo LIKE', 1, true) then
                return { { citizenid = 'CIDX', charinfo = '{}', metadata = json.encode({ phone = { profilepicture = 'https://i.imgur.com/ok.png' } }) } }
            end
        end
        assert_eq(Mock.callCallback('qb-phone:server:GetPicture', A, '5550009'), 'https://i.imgur.com/ok.png')
    end)
end)

describe('camera uploads (PH-3)', function()
    local HOOK = 'https://discord.com/api/webhooks/123/SECRET-TOKEN'
    local PIC = 'https://media.discordapp.net/attachments/1/2/photo.jpg'

    local function clientSawSecret()
        local function scan(v, depth)
            if depth > 6 then return false end
            if type(v) == 'string' then return v:find('SECRET-TOKEN', 1, true) ~= nil end
            if type(v) == 'table' then for _, x in pairs(v) do if scan(x, depth + 1) then return true end end end
            return false
        end
        for _, e in ipairs(Mock.clientEvents) do if scan(e.args, 0) then return true end end
        return false
    end

    it('the webhook callback is gone', function()
        assert_eq(Mock.callbacks['qb-phone:server:GetWebhook'], nil)
        assert_eq(Mock.callbacks['qb-phone:server:UploadToFivemerr'], nil)
    end)

    it('the server uploads to the server-only webhook and gives the phone only the picture link', function()
        convars.pfm_phone_webhook = HOOK
        shotData = 'data:image/jpeg;base64,' .. b64('JPEG\0BYTES\255')
        httpReply = { status = 200, body = json.encode({ attachments = { { proxy_url = PIC, url = 'https://cdn.discordapp.com/x.jpg' } } }) }
        local url = Mock.callCallback('qb-phone:server:UploadPhoto', A)
        assert_eq(url, PIC)
        assert_eq(#http, 1)
        assert_eq(http[1].url, HOOK .. '?wait=true')
        assert_eq(http[1].method, 'POST')
        assert_true(http[1].body:find('JPEG\0BYTES\255', 1, true) ~= nil, 'the picture bytes are not in the upload')
        assert_true(http[1].headers['Content-Type']:find('multipart/form-data; boundary=', 1, true) == 1)
        -- it is in the gallery, added by the server
        local ins = callsMatching('INSERT INTO phone_gallery')
        assert_eq(#ins, 1)
        assert_eq(ins[1].params[1], 'CID1')
        assert_eq(ins[1].params[2], PIC)
        assert_false(clientSawSecret(), 'the webhook reached a client')
    end)

    it('one upload per player every 10 s, and only with a phone', function()
        convars.pfm_phone_webhook = HOOK
        shotData = 'data:image/jpeg;base64,' .. b64('x')
        httpReply = { status = 200, body = json.encode({ attachments = { { proxy_url = PIC } } }) }
        Mock.gameTimer = Mock.gameTimer + 100000
        assert_eq(Mock.callCallback('qb-phone:server:UploadPhoto', B), PIC)
        local url, why = Mock.callCallback('qb-phone:server:UploadPhoto', B)
        assert_eq(url, nil)
        assert_eq(why, 'too_fast')
        assert_eq(#http, 1)
        Mock.players[C].Functions.GetItemByName = function() return nil end
        assert_eq(Mock.callCallback('qb-phone:server:UploadPhoto', C), nil)
        assert_eq(#http, 1)
    end)

    it('a failed upload answers once with nothing, and nothing goes in the gallery', function()
        convars.pfm_phone_webhook = HOOK
        shotData = 'data:image/jpeg;base64,' .. b64('x')
        httpReply = { status = 500, body = 'oops' }
        Mock.gameTimer = Mock.gameTimer + 100000
        local answers = 0
        Mock.callbacks['qb-phone:server:UploadPhoto'](A, function() answers = answers + 1 end)
        assert_eq(answers, 1)
        assert_eq(#callsMatching('INSERT INTO phone_gallery'), 0)
        -- a link from another host is not accepted either
        httpReply = { status = 200, body = json.encode({ attachments = { { proxy_url = 'https://evil.example/x.jpg' } } }) }
        Mock.gameTimer = Mock.gameTimer + 100000
        assert_eq(Mock.callCallback('qb-phone:server:UploadPhoto', A), nil)
    end)

    it('nothing set up: no upload; Fivemerr needs Config.Fivemerr and its token', function()
        Mock.gameTimer = Mock.gameTimer + 100000
        local url, why = Mock.callCallback('qb-phone:server:UploadPhoto', A)
        assert_eq(url, nil)
        assert_eq(why, 'not_setup')
        Config.Fivemerr = true
        Mock.gameTimer = Mock.gameTimer + 100000
        assert_eq(select(2, Mock.callCallback('qb-phone:server:UploadPhoto', A)), 'not_setup')
        convars.pfm_phone_fivemerr_token = 'TOKEN'
        shotData = 'data:image/png;base64,' .. b64('png')
        httpReply = { status = 200, body = json.encode({ url = 'https://cdn.fivemerr.com/a.png' }) }
        Mock.gameTimer = Mock.gameTimer + 100000
        assert_eq(Mock.callCallback('qb-phone:server:UploadPhoto', A), 'https://cdn.fivemerr.com/a.png')
        assert_eq(http[1].headers.Authorization, 'TOKEN')
        assert_eq(#http, 1)
    end)
end)

describe('other client-trusted paths', function()
    it('an advert picture that is not an allowed link is dropped (it went to every phone unquoted)', function()
        Mock.gameTimer = Mock.gameTimer + 100000
        Mock.fireNet('qb-phone:server:AddAdvert', A, 'selling car', 'x onerror=alert(1)')
        local ev = Mock.clientEventsNamed('qb-phone:client:UpdateAdverts')
        assert_eq(#ev, 1)
        assert_eq(ev[1].args[1].CID1.url, nil)
        Mock.gameTimer = Mock.gameTimer + 100000
        Mock.fireNet('qb-phone:server:AddAdvert', A, 'selling car', 'https://i.imgur.com/car.png')
        ev = Mock.clientEventsNamed('qb-phone:client:UpdateAdverts')
        assert_eq(ev[2].args[1].CID1.url, 'https://i.imgur.com/car.png')
    end)

    it("a tweet's time and avatar are the server's, its picture an allowed link", function()
        Mock.players[A].PlayerData.metadata.phone = { profilepicture = 'https://i.imgur.com/me.png' }
        Mock.gameTimer = Mock.gameTimer + 100000
        Mock.fireNet('qb-phone:server:UpdateTweets', A, nil, { message = 'hi', time = EVIL, picture = 'x onerror=1', url = 'https://evil.example/x.png' })
        local tweet = Mock.clientEventsNamed('qb-phone:client:UpdateTweets')[1].args[3]
        assert_true(tweet.time:match('^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d$') ~= nil, 'client time used: ' .. tostring(tweet.time))
        assert_eq(tweet.picture, 'https://i.imgur.com/me.png')
        assert_eq(tweet.url, '')
    end)

    it('app alerts are kept only for the phone apps', function()
        Mock.fireNet('qb-phone:server:SetPhoneAlerts', A, string.rep('x', 300), 5)
        Mock.fireNet('qb-phone:server:SetPhoneAlerts', A, 'whatsapp', 'lots')
        local data = Mock.callCallback('qb-phone:server:GetPhoneData', A)
        assert_eq(data.Applications[string.rep('x', 300)], nil)
        Mock.fireNet('qb-phone:server:SetPhoneAlerts', A, 'mail')
        data = Mock.callCallback('qb-phone:server:GetPhoneData', A)
        assert_eq(data.Applications.mail, 1)
    end)
end)
