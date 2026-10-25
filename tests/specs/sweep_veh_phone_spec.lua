-- pfm-phone apps (server/main.lua): MEOS lookups are police-only and parameterised, the tweet feed and
-- tweet authors come from the server, chats go to the exact phone number, server-only mail is not a
-- net event, and a few handlers that crashed or reached any player are checked.
load_resource('tests/lua/fivem_mocks.lua')

-- a scriptable database: Responder(kind, query, params) returns the rows; every call is recorded
local calls = {}
local Responder = function() return {} end
local function db(kind)
    local fn = function(query, params, cb)
        if type(params) == 'function' then cb, params = params, nil end
        calls[#calls + 1] = { kind = kind, query = query, params = params or {} }
        local out = Responder(kind, query, params or {})
        if cb then cb(out) end
        return out
    end
    return setmetatable({ await = function(q, p) return fn(q, p) end }, { __call = function(_, ...) return fn(...) end })
end
MySQL = { query = db('query'), insert = db('insert'), update = db('update'), scalar = db('scalar'), single = db('single'), rawExecute = db('rawExecute') }

QBCoreMock.Functions.GetPlayerByPhone = function(number)
    for _, p in pairs(Mock.players) do if p.PlayerData.charinfo.phone == number then return p end end
end
local timeouts = {}
SetTimeout = function(_, fn) timeouts[#timeouts + 1] = fn end

Config = nil
load_resource('pfm-phone/config.lua')
load_resource('pfm-phone/server/main.lua')

local COP, CIV, OTHER, FAR = 1, 2, 3, 4
local function player(src, phone)
    local p = Mock.newPlayer(src)
    p.PlayerData.charinfo.phone = phone
    p.PlayerData.metadata.phonedata = { InstalledApps = {} }
    Mock.coords[src] = vector3(0, 0, 0)
    return p
end

local function callsMatching(text)
    local out = {}
    for _, c in ipairs(calls) do if c.query:find(text, 1, true) then out[#out + 1] = c end end
    return out
end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords = {}, {}
    Mock.gameTimer = Mock.gameTimer + 100000
    calls, timeouts = {}, {}
    Responder = function() return {} end
    local cop = player(COP, '5550001')
    cop.PlayerData.job = { name = 'police', type = 'leo', onduty = true }
    player(CIV, '5550002')
    player(OTHER, '5550003')
    player(FAR, '5550004')
    Mock.coords[FAR] = vector3(500, 0, 0)
end

describe('MEOS lookups', function()
    it('a civilian cannot search people, vehicles or plates', function()
        assert_eq(Mock.callCallback('qb-phone:server:FetchResult', CIV, 'Test'), nil)
        assert_eq(Mock.callCallback('qb-phone:server:GetVehicleSearchResults', CIV, 'ABC'), nil)
        assert_eq(Mock.callCallback('qb-phone:server:ScanPlate', CIV, 'ABC123'), nil)
        assert_eq(#callsMatching('players'), 0)
        assert_eq(#callsMatching('player_vehicles'), 0)
    end)
    it('the person search never puts the search text into the SQL', function()
        local evil = 'x\\" OR 1=1 -- '
        Mock.callCallback('qb-phone:server:FetchResult', COP, evil)
        local q = callsMatching('FROM `players`')
        assert_eq(#q, 1)
        assert_true(not q[1].query:find('OR 1=1', 1, true), 'search text in the SQL')
        assert_eq(q[1].params[1], evil)
    end)
    it('a police officer still finds people', function()
        Responder = function(_, query)
            if query:find('FROM `players`', 1, true) then
                return { { citizenid = 'CIDX', charinfo = '{"firstname":"Jane","lastname":"Doe","phone":"5559999"}', metadata = '{"licences":{"driver":true}}' } }
            end
            return {}
        end
        local res = Mock.callCallback('qb-phone:server:FetchResult', COP, 'Jane Doe')
        assert_eq(res[1].firstname, 'Jane')
        assert_eq(res[1].driverlicense, true)
    end)
end)

describe('mail', function()
    it('mail to another citizen is server-only', function()
        assert_eq(Mock.netHandlers['qb-phone:server:sendNewEventMail'], nil)
        assert_true(Mock.eventHandlers['qb-phone:server:sendNewEventMail'] ~= nil)
    end)
    it('a mail to yourself needs a sender, subject and message', function()
        Mock.fireNet('qb-phone:server:sendNewMail', CIV, { sender = 'x' })
        assert_eq(#callsMatching('INSERT INTO player_mails'), 0)
        Mock.fireNet('qb-phone:server:sendNewMail', CIV, { sender = 'Dealer', subject = 'Job', message = 'Line one\nLine two' })
        local ins = callsMatching('INSERT INTO player_mails')
        assert_eq(#ins, 1)
        assert_eq(ins[1].params[1], 'CID' .. CIV)
    end)
end)

describe('twitter', function()
    it('the feed sent to everyone is the server feed, with the real author', function()
        local fakeFeed = { { firstName = 'Some', lastName = 'Mayor', message = 'I resign' } }
        Mock.fireNet('qb-phone:server:UpdateTweets', CIV, fakeFeed, { firstName = 'Some', lastName = 'Mayor', citizenid = 'CID' .. COP, message = 'hello', tweetId = 'TWEET-12345678' })
        local ev = Mock.clientEventsNamed('qb-phone:client:UpdateTweets')
        assert_eq(#ev, 1)
        assert_eq(ev[1].target, -1)
        local feed, tweet = ev[1].args[2], ev[1].args[3]
        assert_true(feed ~= fakeFeed, 'client list was broadcast')
        assert_eq(feed[#feed].message, 'hello')
        assert_eq(tweet.firstName, 'Test')
        assert_eq(tweet.lastName, 'Player' .. CIV)
        assert_eq(tweet.citizenid, 'CID' .. CIV)
        for _, t in ipairs(feed) do assert_true(t.lastName ~= 'Mayor', 'forged tweet in the feed') end
    end)
    it('a mention carries the real author and costs at most one query', function()
        Mock.fireNet('qb-phone:server:MentionedPlayer', CIV, 'Nobody', 'Here', { firstName = 'Some', lastName = 'Mayor', message = 'hi @Nobody_Here' })
        assert_true(#callsMatching('FROM players') <= 1, 'one query per online player')
        Mock.players[OTHER].PlayerData.charinfo = { firstname = 'Ann', lastname = 'Lee', phone = '5550003' }
        Mock.fireNet('qb-phone:server:MentionedPlayer', CIV, 'Ann', 'Lee', { firstName = 'Some', lastName = 'Mayor', message = 'hi @Ann_Lee' })
        local ev = Mock.clientEventsNamed('qb-phone:client:GetMentioned')
        assert_eq(#ev, 1)
        assert_eq(ev[1].target, OTHER)
        assert_eq(ev[1].args[1].lastName, 'Player' .. CIV)
    end)
    it('a hashtag post carries the real author', function()
        Mock.fireNet('qb-phone:server:UpdateHashtags', CIV, 'news', { firstName = 'Some', lastName = 'Mayor', message = '#news' })
        local ev = Mock.clientEventsNamed('qb-phone:client:UpdateHashtags')
        assert_eq(#ev, 1)
        assert_eq(ev[1].args[2].lastName, 'Player' .. CIV)
    end)
    it('deleting a tweet sends the feed in the order the phone reads it', function()
        Responder = function(kind, query)
            if kind == 'scalar' and query:find('SELECT citizenid FROM phone_tweets', 1, true) then return 'CID' .. CIV end
            return {}
        end
        Mock.fireNet('qb-phone:server:DeleteTweet', CIV, 'TWEET-11111111')
        local ev = Mock.clientEventsNamed('qb-phone:client:UpdateTweets')
        assert_eq(#ev, 1)
        assert_eq(type(ev[1].args[2]), 'table')
        assert_eq(ev[1].args[4], true)
    end)
end)

describe('messages', function()
    it('a chat is written for the holder of exactly that number', function()
        Mock.fireNet('qb-phone:server:UpdateMessages', CIV, { { messages = { { message = 'hi' } } } }, '5550003', false)
        local q = callsMatching('FROM players WHERE charinfo LIKE')
        assert_eq(#q, 1)
        assert_eq(q[1].params[1], '%"phone":"5550003"%')
    end)
    it('an ambiguous or partial number writes nothing', function()
        Responder = function(_, query)
            if query:find('FROM players WHERE charinfo LIKE', 1, true) then
                return { { citizenid = 'A', charinfo = '{"phone":"1"}' }, { citizenid = 'B', charinfo = '{"phone":"1"}' } }
            end
            return {}
        end
        Mock.fireNet('qb-phone:server:UpdateMessages', CIV, { { messages = { { message = 'hi' } } } }, '1', false)
        assert_eq(#callsMatching('phone_messages'), 0)
    end)
    it('an oversized chat is refused', function()
        local big = { { messages = {} } }
        for i = 1, 400 do big[1].messages[i] = { message = string.rep('x', 200) } end
        Mock.fireNet('qb-phone:server:UpdateMessages', CIV, big, '5550003', false)
        assert_eq(#calls, 0)
    end)
end)

describe('calls, contacts and apps', function()
    it('a missed call is recorded for both people', function()
        Mock.fireNet('qb-phone:server:AddRecentCall', CIV, 'missed', { number = '5550003', name = 'x' })
        local ev = Mock.clientEventsNamed('qb-phone:client:AddRecentCall')
        assert_eq(#ev, 2)
        assert_eq(ev[1].args[3], 'missed')
    end)
    it('contact details only go to someone close by', function()
        Mock.fireNet('qb-phone:server:GiveContactDetails', CIV, FAR)
        assert_eq(#Mock.clientEventsNamed('qb-phone:client:AddNewSuggestion'), 0)
        Mock.fireNet('qb-phone:server:GiveContactDetails', CIV, OTHER)
        assert_eq(#Mock.clientEventsNamed('qb-phone:client:AddNewSuggestion'), 1)
    end)
    it('only store apps can be installed, stored by name', function()
        Mock.fireNet('qb-phone:server:InstallApplication', CIV, { app = 'bogus', junk = string.rep('x', 5000) })
        assert_eq(next(Mock.players[CIV].PlayerData.metadata.phonedata.InstalledApps), nil)
        Mock.fireNet('qb-phone:server:InstallApplication', CIV, { app = 'territory', junk = 'x' })
        local stored = Mock.players[CIV].PlayerData.metadata.phonedata.InstalledApps.territory
        assert_eq(stored.app, 'territory')
        assert_eq(stored.junk, nil)
    end)
    it('picture lookups do not crash on bad input', function()
        Mock.callCallback('qb-phone:server:GetContactPicture', CIV, { number = '5550003' })
        Mock.callCallback('qb-phone:server:GetPicture', CIV, nil)
        Mock.callCallback('qb-phone:server:GetContactPictures', CIV, 'nope')
        assert_true(true)
    end)
end)
