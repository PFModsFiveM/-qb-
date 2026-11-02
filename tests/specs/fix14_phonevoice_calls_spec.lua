-- pfm-phone calls (batch 14, PH-1 / X-5): the server owns every call. CallContact makes a call with a
-- random id the server picks; only the person called can answer it, only the two people in it can
-- end it, and the server (not the client) puts both in the call's pma-voice channel. A third
-- player's CancelCall / AnswerCall, a forged id, the caller answering its own call, a busy target,
-- a dropped player and an unanswered call are all covered, as are the recent-call entries.
load_resource('tests/lua/fivem_mocks.lua')

local states = { ['pma-voice'] = 'started' }
function GetResourceState(name) return states[name] or 'missing' end

QBCoreMock.Functions.GetPlayerByPhone = function(number)
    for _, p in pairs(Mock.players) do if p.PlayerData.charinfo.phone == number then return p end end
end
local timeouts = {}
SetTimeout = function(ms, fn) timeouts[#timeouts + 1] = { ms = ms, fn = fn } end

-- pma-voice's server export, as pfm-phone calls it
local voice = {}
Mock.exportsByResource['pma-voice'] = {
    setPlayerCall = function(_, src, channel) voice[#voice + 1] = { src = src, channel = channel } end,
}

Config = nil
load_resource('pfm-phone/config.lua')
load_resource('pfm-phone/server/main.lua')

local A, B, C, NOPHONE = 1, 2, 3, 4
local function player(src, phone, hasPhone)
    local p = Mock.newPlayer(src)
    p.PlayerData.charinfo.phone = phone
    p.PlayerData.metadata.phonedata = { InstalledApps = {} }
    p.Functions.GetItemByName = function(name) if hasPhone and name == 'phone' then return { name = 'phone' } end end
    return p
end

local function events(name, target)
    local out = {}
    for _, e in ipairs(Mock.clientEventsNamed(name)) do
        if target == nil or e.target == target then out[#out + 1] = e end
    end
    return out
end

local function voiceOf(src)
    local out = {}
    for _, v in ipairs(voice) do if v.src == src then out[#out + 1] = v.channel end end
    return out
end

--- A calls B and returns the server's call id (from CallStarted to A).
local function ring(from, number, anonymous)
    Mock.gameTimer = Mock.gameTimer + 100000 -- past the call rate limit
    Mock.fireNet('qb-phone:server:CallContact', from, { number = number }, 12345, anonymous)
    local started = events('qb-phone:client:CallStarted', from)
    return started[#started] and started[#started].args[1]
end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    voice, timeouts = {}, {}
    states['pma-voice'] = 'started'
    player(A, '5550001', true)
    player(B, '5550002', true)
    player(C, '5550003', true)
    player(NOPHONE, '5550004', false)
    -- no call left over from the previous test
    for src = 1, 4 do
        local id = PFPhoneCalls.Of(src)
        if id then PFPhoneCalls.End(id, nil) end
    end
    Mock.reset()
    voice, timeouts = {}, {}
end

describe('starting a call', function()
    it('the server picks the id; the client id and the old (a+b)/100 id are not used', function()
        local id = ring(A, '5550002')
        assert_true(type(id) == 'number', 'no call id')
        assert_true(id ~= 12345, 'the client chose the id')
        assert_true(id ~= math.ceil((5550001 + 5550002) / 100), 'predictable id')
        local called = events('qb-phone:client:GetCalled', B)
        assert_eq(#called, 1)
        assert_eq(called[1].args[1], '5550001')
        assert_eq(called[1].args[2], id)
        assert_eq(PFPhoneCalls.Get(id).state, 'ringing')
        -- nobody is in a voice channel before the call is answered
        assert_eq(#voice, 0)
    end)

    it('two calls between the same two numbers get different ids', function()
        local first = ring(A, '5550002')
        Mock.fireNet('qb-phone:server:CancelCall', A, first)
        local second = ring(A, '5550002')
        assert_true(first ~= second, 'same id twice')
    end)

    it('an anonymous caller number never reaches the phone being called', function()
        ring(A, '5550002', true)
        local called = events('qb-phone:client:GetCalled', B)
        assert_eq(called[1].args[1], nil)
        assert_eq(called[1].args[3], true)
    end)

    it('a busy target, yourself, a target without a phone and a caller without a phone are refused', function()
        ring(A, '5550002')
        Mock.reset()
        ring(C, '5550002') -- B is in a call with A
        assert_eq(#events('qb-phone:client:GetCalled', B), 0)
        assert_eq(#events('qb-phone:client:CancelCall', C), 1)
        assert_eq(PFPhoneCalls.Of(C), nil)
        Mock.reset()
        ring(C, '5550003')
        assert_eq(PFPhoneCalls.Of(C), nil)
        ring(C, '5550004')
        assert_eq(#events('qb-phone:client:GetCalled', NOPHONE), 0)
        ring(NOPHONE, '5550003')
        assert_eq(#events('qb-phone:client:GetCalled', C), 0)
        assert_eq(PFPhoneCalls.Of(NOPHONE), nil)
    end)

    it('GetCallState reads the server table (busy, free, unavailable)', function()
        ring(A, '5550002')
        local canCall, online = Mock.callCallback('qb-phone:server:GetCallState', C, { number = '5550002' })
        assert_eq(canCall, false)
        assert_eq(online, true)
        canCall, online = Mock.callCallback('qb-phone:server:GetCallState', C, { number = '5550001' })
        assert_eq(canCall, false)
        canCall = Mock.callCallback('qb-phone:server:GetCallState', A, { number = '5550003' })
        assert_eq(canCall, true)
        canCall, online = Mock.callCallback('qb-phone:server:GetCallState', A, { number = '5550004' })
        assert_eq(canCall, false)
        assert_eq(online, false)
        -- the client-set "in a call" flag is gone
        assert_eq(Mock.netHandlers['qb-phone:server:SetCallState'], nil)
    end)
end)

describe('answering', function()
    it('only the person called can answer; the server joins both to the call channel', function()
        local id = ring(A, '5550002')
        -- the attacker (C), and the caller answering its own call (the hot-mic trick), change nothing
        Mock.fireNet('qb-phone:server:AnswerCall', C, id)
        Mock.fireNet('qb-phone:server:AnswerCall', C, { TargetData = { number = '5550002' } })
        Mock.fireNet('qb-phone:server:AnswerCall', A, id)
        assert_eq(PFPhoneCalls.Get(id).state, 'ringing')
        assert_eq(#voice, 0)
        assert_eq(#events('qb-phone:client:AnswerCall'), 0)
        -- B answers
        Mock.fireNet('qb-phone:server:AnswerCall', B, id)
        assert_eq(PFPhoneCalls.Get(id).state, 'ongoing')
        assert_eq(voiceOf(A)[1], id)
        assert_eq(voiceOf(B)[1], id)
        assert_eq(#voiceOf(C), 0)
        local answered = events('qb-phone:client:AnswerCall')
        assert_eq(#answered, 1)
        assert_eq(answered[1].target, A)
    end)

    it('a stale id from an older call answers nothing', function()
        local old = ring(A, '5550002')
        Mock.fireNet('qb-phone:server:CancelCall', A, old)
        local id = ring(A, '5550002')
        Mock.fireNet('qb-phone:server:AnswerCall', B, old)
        assert_eq(PFPhoneCalls.Get(id).state, 'ringing')
        Mock.fireNet('qb-phone:server:AnswerCall', B, id)
        assert_eq(PFPhoneCalls.Get(id).state, 'ongoing')
    end)

    it('answering a call that has ended puts the phone back to idle', function()
        local id = ring(A, '5550002')
        Mock.fireNet('qb-phone:server:CancelCall', A, id)
        Mock.reset()
        Mock.fireNet('qb-phone:server:AnswerCall', B, id)
        assert_eq(#voice, 0)
        assert_eq(#events('qb-phone:client:CancelCall', B), 1)
    end)
end)

describe('hanging up', function()
    it('a third player cannot hang up anyone, by number or by id', function()
        local id = ring(A, '5550002')
        Mock.fireNet('qb-phone:server:AnswerCall', B, id)
        Mock.reset()
        voice = {}
        Mock.fireNet('qb-phone:server:CancelCall', C, { TargetData = { number = '5550001' } })
        Mock.fireNet('qb-phone:server:CancelCall', C, { TargetData = { number = '5550002' } })
        Mock.fireNet('qb-phone:server:CancelCall', C, id)
        assert_eq(#events('qb-phone:client:CancelCall'), 0)
        assert_eq(PFPhoneCalls.Get(id).state, 'ongoing')
        assert_eq(#voice, 0)
    end)

    it('either side ends the call for both: the other phone is told, both leave the channel', function()
        local id = ring(A, '5550002')
        Mock.fireNet('qb-phone:server:AnswerCall', B, id)
        voice = {}
        Mock.reset()
        Mock.fireNet('qb-phone:server:CancelCall', B, id)
        assert_eq(PFPhoneCalls.Get(id), nil)
        assert_eq(PFPhoneCalls.Of(A), nil)
        assert_eq(PFPhoneCalls.Of(B), nil)
        assert_eq(voiceOf(A)[1], 0)
        assert_eq(voiceOf(B)[1], 0)
        assert_eq(#events('qb-phone:client:CancelCall', A), 1)
        assert_eq(#events('qb-phone:client:CancelCall', B), 0)
        -- the recent calls come from the server's record
        local rA, rB = events('qb-phone:client:AddRecentCall', A), events('qb-phone:client:AddRecentCall', B)
        assert_eq(rA[1].args[3], 'outgoing')
        assert_eq(rA[1].args[1].number, '5550002')
        assert_eq(rB[1].args[3], 'incoming')
        assert_eq(rB[1].args[1].number, '5550001')
    end)

    it('the person called can deny a ringing call; it is a missed call, nobody joined a channel', function()
        local id = ring(A, '5550002')
        Mock.reset()
        Mock.fireNet('qb-phone:server:CancelCall', B, id)
        assert_eq(PFPhoneCalls.Get(id), nil)
        assert_eq(#voice, 0)
        assert_eq(#events('qb-phone:client:CancelCall', A), 1)
        assert_eq(events('qb-phone:client:AddRecentCall', B)[1].args[3], 'missed')
    end)

    it('an unanswered call ends on the server after the ringing time', function()
        local id = ring(A, '5550002')
        assert_true(#timeouts >= 1)
        Mock.reset()
        timeouts[#timeouts].fn()
        assert_eq(PFPhoneCalls.Get(id), nil)
        assert_eq(#events('qb-phone:client:CancelCall', A), 1)
        assert_eq(#events('qb-phone:client:CancelCall', B), 1)
        -- a timer of an answered call ends nothing
        local id2 = ring(A, '5550002')
        Mock.fireNet('qb-phone:server:AnswerCall', B, id2)
        timeouts[#timeouts].fn()
        assert_eq(PFPhoneCalls.Get(id2).state, 'ongoing')
    end)

    it('a player who leaves ends the call: the other leaves the channel and is told', function()
        local id = ring(A, '5550002')
        Mock.fireNet('qb-phone:server:AnswerCall', B, id)
        voice = {}
        Mock.reset()
        Mock.fireEvent('playerDropped', A)
        assert_eq(PFPhoneCalls.Get(id), nil)
        assert_eq(voiceOf(B)[1], 0)
        assert_eq(#voiceOf(A), 0)
        assert_eq(#events('qb-phone:client:CancelCall', B), 1)
        assert_eq(#events('qb-phone:client:CancelCall', A), 0)
        -- B can be called again
        assert_true(ring(C, '5550002') ~= nil)
    end)

    it('a logout ends the call too', function()
        local id = ring(A, '5550002')
        Mock.fireEvent('QBCore:Server:OnPlayerUnload', nil, B)
        assert_eq(PFPhoneCalls.Get(id), nil)
        assert_eq(PFPhoneCalls.Of(A), nil)
    end)

    it('without pma-voice a call still rings and ends (no voice calls are made)', function()
        states['pma-voice'] = 'missing'
        local id = ring(A, '5550002')
        Mock.fireNet('qb-phone:server:AnswerCall', B, id)
        Mock.fireNet('qb-phone:server:CancelCall', A, id)
        assert_eq(#voice, 0)
        assert_eq(PFPhoneCalls.Get(id), nil)
    end)
end)
