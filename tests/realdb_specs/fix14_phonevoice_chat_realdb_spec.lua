-- pfm-phone chats on a real database (batch 14, PH-2): each SendMessage appends one server-built
-- message to both people's phone_messages rows (insert or update), an offline receiver is found by
-- the exact number, rows written before the fix are cleaned when read and when next written, a long
-- chat stays inside the TEXT column (valid JSON, newest kept), and of two legacy rows the newest wins.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
function GetResourceState() return 'missing' end
SetTimeout = function() end

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-phone/qb-phone.sql')

QBCoreMock.Functions.GetPlayerByPhone = function(number)
    for _, p in pairs(Mock.players) do if p.PlayerData.charinfo.phone == number then return p end end
end

function GetCurrentResourceName() return 'pfm-phone' end
Config = nil
load_resource('pfm-phone/config.lua')
load_resource('pfm-phone/server/main.lua')

local A, B = 1, 2
local function player(src, cid, phone)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.charinfo.phone = phone
    p.PlayerData.metadata.phonedata = { InstalledApps = {} }
    p.Functions.GetItemByName = function(name) return name == 'phone' and { name = 'phone' } or nil end
    return p
end

MySQL.query.await([[INSERT INTO players (citizenid, cid, license, name, money, charinfo, job, gang, position, metadata, inventory)
    VALUES ('CHATC01', 1, 'license:c', 'C', '{}', '{"firstname":"Cee","lastname":"Offline","phone":"5550003"}', '{}', '{}', '{}', '{}', '[]')]])

local function row(cid, number)
    return MySQL.single.await('SELECT id, messages, LENGTH(messages) AS len FROM phone_messages WHERE citizenid = ? AND number = ? ORDER BY id DESC LIMIT 1', { cid, number })
end
local function messagesOf(cid, number)
    local r = row(cid, number)
    if not r then return nil end
    local out = {}
    for _, d in ipairs(json.decode(r.messages)) do for _, m in ipairs(d.messages) do out[#out + 1] = m end end
    return out, r
end
local function send(src, number, payload)
    Mock.gameTimer = Mock.gameTimer + 100000
    Mock.fireNet('qb-phone:server:SendMessage', src, number, payload)
end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    player(A, 'CHATA01', '5550001')
    player(B, 'CHATB01', '5550002')
end

describe('chat rows', function()
    it('a conversation is stored the same way for both people, in order, with the real senders', function()
        send(A, '5550002', { type = 'message', message = 'hi B' })
        send(B, '5550001', { type = 'message', message = 'hi A' })
        send(A, '5550002', { type = 'message', message = 'how are you?' })
        local mine = messagesOf('CHATA01', '5550002')
        local theirs = messagesOf('CHATB01', '5550001')
        assert_eq(#mine, 3)
        assert_eq(#theirs, 3)
        assert_eq(mine[1].message, 'hi B')
        assert_eq(mine[1].sender, 'CHATA01')
        assert_eq(theirs[2].message, 'hi A')
        assert_eq(theirs[2].sender, 'CHATB01')
        assert_eq(theirs[3].message, 'how are you?')
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM phone_messages WHERE citizenid IN ('CHATA01', 'CHATB01')")), 2)
    end)

    it('an offline receiver is found by the exact number and gets the message', function()
        send(A, '5550003', { type = 'message', message = 'for later' })
        local theirs = messagesOf('CHATC01', '5550001')
        assert_eq(#theirs, 1)
        assert_eq(theirs[1].message, 'for later')
        -- a partial number finds nobody
        send(A, '555000', { type = 'message', message = 'x' })
        assert_eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM phone_messages WHERE number = '555000'")), 0)
    end)

    it('a row written before the fix is cleaned when read and when next written', function()
        local evil = '<img src=x onerror="alert(1)">'
        MySQL.insert.await('INSERT INTO phone_messages (citizenid, number, messages) VALUES (?, ?, ?)', { 'CHATA01', '5550009', json.encode({
            { date = '2-3-2026', messages = {
                { sender = 'CHATA01', type = 'message', message = 'real', time = '09:00', data = {} },
                { sender = 'CHATA01', type = 'message', message = 'forged time', time = evil, data = {} },
                { sender = evil, type = 'message', message = 'forged sender', time = '09:01', data = {} },
                { sender = 'CHATX', type = 'picture', message = 'Photo', time = '09:02', data = { url = 'x onerror=alert(1)' } },
            } },
        }) })
        local data = Mock.callCallback('qb-phone:server:GetPhoneData', A)
        local chat
        for _, c in ipairs(data.Chats) do if c.number == '5550009' then chat = c end end
        local days = json.decode(chat.messages)
        assert_eq(#days[1].messages, 2)
        assert_eq(days[1].messages[2].time, '')
        -- the holder of 5550009 exists: the next message rewrites A's row clean
        player(3, 'CHATD01', '5550009')
        send(A, '5550009', { type = 'message', message = 'new' })
        local mine, r = messagesOf('CHATA01', '5550009')
        assert_eq(#mine, 3)
        assert_true(not r.messages:find('onerror', 1, true), 'the stored row still holds the payload')
    end)

    it('a long chat stays inside the TEXT column: valid JSON, the newest messages kept', function()
        local long = string.rep('y', 270)
        for i = 1, 230 do send(A, '5550002', { type = 'message', message = ('%03d '):format(i) .. long }) end
        local mine, r = messagesOf('CHATA01', '5550002')
        assert_true(tonumber(r.len) <= 60000, 'stored ' .. tostring(r.len) .. ' bytes')
        assert_true(#mine >= 150, 'only ' .. #mine .. ' messages kept')
        assert_eq(mine[#mine].message:sub(1, 3), '230')
        local theirs, r2 = messagesOf('CHATB01', '5550001')
        assert_true(tonumber(r2.len) <= 60000)
        assert_eq(theirs[#theirs].message:sub(1, 3), '230')
    end)

    it('of two legacy rows for one chat the newest is read and written', function()
        MySQL.insert.await('INSERT INTO phone_messages (citizenid, number, messages) VALUES (?, ?, ?)', { 'CHATB01', '5550007', json.encode({ { date = '1-0-2026', messages = { { sender = 'CHATB01', type = 'message', message = 'old row', time = '08:00', data = {} } } } }) })
        MySQL.insert.await('INSERT INTO phone_messages (citizenid, number, messages) VALUES (?, ?, ?)', { 'CHATB01', '5550007', json.encode({ { date = '1-0-2026', messages = { { sender = 'CHATB01', type = 'message', message = 'new row', time = '08:00', data = {} } } } }) })
        player(4, 'CHATE01', '5550007')
        send(B, '5550007', { type = 'message', message = 'reply' })
        local mine = messagesOf('CHATB01', '5550007')
        assert_eq(#mine, 2)
        assert_eq(mine[1].message, 'new row')
        local data = Mock.callCallback('qb-phone:server:GetPhoneData', B)
        local n = 0
        for _, c in ipairs(data.Chats) do if c.number == '5550007' then n = n + 1 end end
        assert_eq(n, 1)
    end)
end)
