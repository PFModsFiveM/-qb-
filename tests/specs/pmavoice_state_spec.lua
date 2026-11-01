-- pma-voice ([qb] copy of the owner's resource), sv_stateBagStrictMode: the client no longer
-- writes replicated state bags. It asks pma-voice's server, which checks and writes:
--   voiceIntent  'pma-voice:server:setVoiceIntent'   disableRadio 'pma-voice:server:setDisableRadio'
--   radio/call/click_on/click_off 'pma-voice:server:setVolume'
--   proximity    'pma-voice:server:setProximity'     radioActive  'pma-voice:setTalkingOnRadio'
-- (server/module/state.lua, server/module/radio.lua). Every request is rate limited per key; the
-- latest request over the limit is applied when the window ends. The last part runs the patched
-- client and plays what it sends into the server, to show honest players get the same state.
load_resource('tests/lua/fivem_mocks.lua')

-- ── server mocks ──────────────────────────────────────────────────
local serverConvars, timers, writes = {}, {}, {}
local serverClock = 0
local bags = {}

-- a state bag that records every write (`:set` and plain assignment, as FiveM allows both)
local function newBag(src, log)
    local values = {}
    return setmetatable({}, {
        __index = function(_, k)
            if k == 'set' then
                return function(_, key, value, replicated)
                    values[key] = value
                    log[#log + 1] = { src = src, key = key, value = value, replicated = replicated }
                end
            end
            return values[k]
        end,
        __newindex = function(_, k, v)
            values[k] = v
            log[#log + 1] = { src = src, key = k, value = v, replicated = true }
        end,
    })
end

function Player(src)
    bags[src] = bags[src] or { state = newBag(src, writes) }
    return bags[src]
end
function IsDuplicityVersion() return true end
function GetGameName() return 'fivem' end
function GetConvar(name, default) local v = serverConvars[name] if v == nil then return default end return tostring(v) end
function GetConvarInt(name, default) local v = serverConvars[name] if v == nil then return default end return math.tointeger(tonumber(v)) or default end
function SetConvarReplicated() end
function GetPlayers() return {} end
function GetGameTimer() return serverClock end
function SetTimeout(ms, fn) timers[#timers + 1] = { ms = ms, fn = fn } end

load_resource('pma-voice/shared.lua')
load_resource('pma-voice/server/main.lua')
load_resource('pma-voice/server/module/phone.lua')
load_resource('pma-voice/server/module/radio.lua')
load_resource('pma-voice/server/module/state.lua')

local ME, OTHER, THIRD = 1, 2, 3

local function state(src) return Player(src).state end
local function clearWrites() for i = #writes, 1, -1 do writes[i] = nil end end
local function net(name, src, ...) Mock.fireNet(name, src, ...) end
local function writesOf(src, key)
    local out = {}
    for _, w in ipairs(writes) do
        if w.src == src and w.key == key then out[#out + 1] = w end
    end
    return out
end
local function runTimers()
    local due = timers
    timers = {}
    for _, t in ipairs(due) do t.fn() end
end
local function join(src)
    Mock.fireEvent('playerJoining', src)
end
local function talkEventsTo(target)
    local out = {}
    for _, e in ipairs(Mock.clientEventsNamed('pma-voice:setTalkingOnRadio')) do
        if e.target == target then out[#out + 1] = tostring(e.args[1]) .. '=' .. tostring(e.args[2]) end
    end
    return table.concat(out, ' ')
end

BeforeEach = function()
    Mock.reset()
    for _, src in ipairs({ ME, OTHER, THIRD }) do
        if isValidPlayer(src) then Mock.fireEvent('playerDropped', src) end
    end
    clearWrites()
    bags, timers, serverConvars = {}, {}, {}
    serverClock = serverClock + 60000              -- a fresh rate window
    for k in pairs(radioData) do radioData[k] = nil end
    join(ME)
    join(OTHER)
    join(THIRD)
    clearWrites()
    Mock.reset()
end

describe('joining', function()
    it('the server starts disableRadio at 0 (the client used to)', function()
        Mock.fireEvent('playerDropped', ME)
        bags[ME] = nil
        clearWrites()
        join(ME)
        local w = writesOf(ME, 'disableRadio')
        assert_eq(#w, 1)
        assert_eq(w[1].value, 0)
        assert_eq(w[1].replicated, true)
        Mock.fireEvent('playerDropped', ME)
        clearWrites()
        join(ME)
        assert_eq(#writesOf(ME, 'disableRadio'), 0, 'a value already published is not reset')
    end)

    it('bits already set and a stale radioActive survive a pma-voice restart correctly', function()
        Mock.fireEvent('playerDropped', ME)
        bags[ME] = nil
        state(ME):set('disableRadio', 4, true)
        state(ME):set('radioActive', true, true)
        clearWrites()
        join(ME)
        assert_eq(state(ME).disableRadio, 4, 'kept')
        assert_eq(state(ME).radioActive, false, 'nobody talks on a radio that just started')
        local w = writesOf(ME, 'radioActive')
        assert_eq(#w, 1)
        assert_eq(w[1].replicated, true)
    end)
end)

describe('pma-voice:server:setVolume', function()
    it('sets one volume type, or all four like the client\'s /vol', function()
        net('pma-voice:server:setVolume', ME, 40, 'radio')
        assert_eq(state(ME).radio, 40)
        assert_eq(writesOf(ME, 'radio')[1].replicated, true)
        net('pma-voice:server:setVolume', ME, 55)
        for _, k in ipairs({ 'radio', 'call', 'click_on', 'click_off' }) do assert_eq(state(ME)[k], 55, k) end
        assert_eq(state(OTHER).radio, GetConvarInt('voice_defaultRadioVolume', 30), 'only the sender')
    end)

    it('clamps to 0..100 and refuses anything else', function()
        net('pma-voice:server:setVolume', ME, 150, 'call')
        assert_eq(state(ME).call, 100)
        net('pma-voice:server:setVolume', ME, -5, 'call')
        assert_eq(state(ME).call, 0)
        clearWrites()
        net('pma-voice:server:setVolume', ME, '50', 'call')
        net('pma-voice:server:setVolume', ME, 0 / 0, 'call')
        net('pma-voice:server:setVolume', ME, math.huge)
        net('pma-voice:server:setVolume', ME, 50, 'phone')      -- not a volume type
        net('pma-voice:server:setVolume', ME, 50, 'assignedChannel')
        net('pma-voice:server:setVolume', ME, 50, 7)
        net('pma-voice:server:setVolume', ME, nil)
        assert_eq(#writes, 0)
    end)
end)

describe('pma-voice:server:setProximity', function()
    it('copies only index, distance and mode', function()
        net('pma-voice:server:setProximity', ME, { index = 2, distance = 7.0, mode = 'Normal', radioChannel = 9, evil = string.rep('x', 9999) })
        local p = state(ME).proximity
        assert_eq(p.index, 2)
        assert_eq(p.distance, 7.0)
        assert_eq(p.mode, 'Normal')
        local n = 0
        for _ in pairs(p) do n = n + 1 end
        assert_eq(n, 3, 'nothing else from the client')
        net('pma-voice:server:setProximity', ME, { index = 4, distance = 40, mode = 'Custom' })
        assert_eq(state(ME).proximity.mode, 'Custom')
    end)

    it('refuses bad values', function()
        clearWrites()
        for _, d in ipairs({
            { index = 0, distance = 3, mode = 'Whisper' }, { index = 1.5, distance = 3, mode = 'Whisper' },
            { index = 33, distance = 3, mode = 'Whisper' }, { index = '1', distance = 3, mode = 'Whisper' },
            { index = 1, distance = -1, mode = 'Whisper' }, { index = 1, distance = 1000.5, mode = 'Whisper' },
            { index = 1, distance = 0 / 0, mode = 'Whisper' }, { index = 1, distance = 3, mode = '' },
            { index = 1, distance = 3, mode = string.rep('a', 33) }, { index = 1, distance = 3, mode = 'a\nb' },
            { index = 1, distance = 3, mode = 5 }, { index = 1, distance = 3 },
        }) do net('pma-voice:server:setProximity', ME, d) end
        net('pma-voice:server:setProximity', ME, 'Whisper')
        net('pma-voice:server:setProximity', ME, nil)
        assert_eq(#writes, 0)
    end)
end)

describe('pma-voice:server:setVoiceIntent', function()
    it('takes speech or music', function()
        net('pma-voice:server:setVoiceIntent', ME, 'music')
        assert_eq(state(ME).voiceIntent, 'music')
        net('pma-voice:server:setVoiceIntent', ME, 'speech')
        assert_eq(state(ME).voiceIntent, 'speech')
        net('pma-voice:server:setVoiceIntent', ME, 'loud')
        net('pma-voice:server:setVoiceIntent', ME, 42)
        assert_eq(state(ME).voiceIntent, 'speech')
    end)

    it('refuses while the server does not let players choose it', function()
        serverConvars.voice_allowSetIntent = 0
        net('pma-voice:server:setVoiceIntent', ME, 'music')
        assert_eq(state(ME).voiceIntent, 'speech', 'still the default the server set at join')
    end)
end)

describe('pma-voice:server:setDisableRadio', function()
    it('publishes the client\'s bit field', function()
        net('pma-voice:server:setDisableRadio', ME, 5)
        assert_eq(state(ME).disableRadio, 5)
        net('pma-voice:server:setDisableRadio', ME, 4.0)
        assert_eq(state(ME).disableRadio, 4)
        assert_eq(math.type(state(ME).disableRadio), 'integer')
        net('pma-voice:server:setDisableRadio', ME, 0)
        assert_eq(state(ME).disableRadio, 0)
    end)

    it('refuses anything but a 31 bit field', function()
        net('pma-voice:server:setDisableRadio', ME, 0x7FFFFFFF)
        assert_eq(state(ME).disableRadio, 0x7FFFFFFF, 'every flag bit')
        clearWrites()
        for _, v in ipairs({ -1, 1.5, 2 ^ 31, 2 ^ 32, 0 / 0, math.huge, '1', true }) do
            net('pma-voice:server:setDisableRadio', ME, v)
        end
        net('pma-voice:server:setDisableRadio', ME, nil)
        assert_eq(#writes, 0)
    end)
end)

describe('radioActive (pma-voice:setTalkingOnRadio)', function()
    local function onRadio(src, ch) net('pma-voice:setPlayerRadio', src, ch) end

    it('is true only while talking on a channel the player is on', function()
        onRadio(ME, 3)
        onRadio(OTHER, 3)
        Mock.reset()
        net('pma-voice:setTalkingOnRadio', ME, true)
        assert_eq(state(ME).radioActive, true)
        assert_eq(talkEventsTo(OTHER), '1=true', 'the channel hears it, as before')
        assert_eq(talkEventsTo(ME), '', 'not sent back to the talker')
        net('pma-voice:setTalkingOnRadio', ME, false)
        assert_eq(state(ME).radioActive, false)
        assert_eq(talkEventsTo(OTHER), '1=true 1=false')
    end)

    it('a player on no radio channel is never radioActive and reaches nobody', function()
        net('pma-voice:setPlayerRadio', ME, 0)          -- leaving no radio creates radioData[0]
        net('pma-voice:setPlayerRadio', THIRD, 0)
        net('pma-voice:setTalkingOnRadio', THIRD, true)
        Mock.reset()
        clearWrites()
        net('pma-voice:setTalkingOnRadio', ME, true)
        assert_eq(state(ME).radioActive, nil)
        assert_eq(#writesOf(ME, 'radioActive'), 0)
        assert_eq(talkEventsTo(THIRD), '', 'radioData[0] does not collect talkers')
    end)

    it('a channel the server refused does not count as being on it', function()
        onRadio(OTHER, 7)
        local allowed = canJoinChannel
        canJoinChannel = function() return false end     -- a channel check (addChannelCheck) says no
        onRadio(ME, 7)
        canJoinChannel = allowed
        Mock.reset()
        net('pma-voice:setTalkingOnRadio', ME, true)
        assert_eq(state(ME).radioActive, nil)
        assert_eq(talkEventsTo(OTHER), '', 'the channel does not hear them')
    end)

    it('leaving or switching the radio while talking clears it', function()
        onRadio(ME, 3)
        net('pma-voice:setTalkingOnRadio', ME, true)
        assert_eq(state(ME).radioActive, true)
        onRadio(ME, 4)
        assert_eq(state(ME).radioActive, false, 'switched channel')
        net('pma-voice:setTalkingOnRadio', ME, true)
        assert_eq(state(ME).radioActive, true)
        onRadio(ME, 0)
        assert_eq(state(ME).radioActive, false, 'left the radio')
    end)

    it('takes a boolean only, and nothing while radios are off', function()
        onRadio(ME, 3)
        onRadio(OTHER, 3)
        Mock.reset()
        clearWrites()
        net('pma-voice:setTalkingOnRadio', ME, 'yes')
        net('pma-voice:setTalkingOnRadio', ME, 1)
        net('pma-voice:setTalkingOnRadio', ME, {})
        net('pma-voice:setTalkingOnRadio', ME, nil)
        serverConvars.voice_enableRadios = 0
        net('pma-voice:setTalkingOnRadio', ME, true)
        assert_eq(#writes, 0)
        assert_eq(talkEventsTo(OTHER), '')
    end)
end)

describe('rate limits', function()
    it('over the limit only the latest request is kept, and it lands when the window ends', function()
        for i = 1, 20 do net('pma-voice:server:setVolume', ME, i, 'radio') end
        assert_eq(state(ME).radio, 20)
        assert_eq(#writesOf(ME, 'radio'), 20)
        for i = 21, 30 do net('pma-voice:server:setVolume', ME, i, 'radio') end
        assert_eq(#writesOf(ME, 'radio'), 20, 'held back')
        assert_eq(#timers, 1, 'one flush for the window')
        assert_true(timers[1].ms > 0 and timers[1].ms <= 5010, 'at the end of the window')
        serverClock = serverClock + 5000
        runTimers()
        assert_eq(#writesOf(ME, 'radio'), 21, 'one write for the ten held back')
        assert_eq(state(ME).radio, 30, 'the latest')
        net('pma-voice:server:setVolume', ME, 31, 'radio')
        assert_eq(state(ME).radio, 31, 'the new window takes writes again')
    end)

    it('limits are per player and per key', function()
        for i = 1, 25 do net('pma-voice:server:setVolume', ME, i, 'radio') end
        net('pma-voice:server:setVolume', ME, 9, 'call')
        net('pma-voice:server:setVolume', OTHER, 9, 'radio')
        net('pma-voice:server:setDisableRadio', ME, 2)
        assert_eq(state(ME).call, 9)
        assert_eq(state(OTHER).radio, 9)
        assert_eq(state(ME).disableRadio, 2)
        assert_eq(state(ME).radio, 20)
    end)

    it('radio talking has its own, higher limit; the latest press still lands', function()
        net('pma-voice:setPlayerRadio', ME, 3)
        net('pma-voice:setPlayerRadio', OTHER, 3)
        Mock.reset()
        for i = 1, 40 do net('pma-voice:setTalkingOnRadio', ME, i % 2 == 1) end
        assert_eq(#Mock.clientEventsNamed('pma-voice:setTalkingOnRadio'), 40)
        net('pma-voice:setTalkingOnRadio', ME, true)
        net('pma-voice:setTalkingOnRadio', ME, false)
        assert_eq(#Mock.clientEventsNamed('pma-voice:setTalkingOnRadio'), 40, 'held back')
        assert_eq(state(ME).radioActive, false)
        runTimers()
        assert_eq(#Mock.clientEventsNamed('pma-voice:setTalkingOnRadio'), 41)
        assert_eq(talkEventsTo(OTHER):sub(-7), '1=false', 'the release reached the channel')
        assert_eq(state(ME).radioActive, false)
    end)

    it('a held-back press is checked again when it lands', function()
        net('pma-voice:setPlayerRadio', ME, 3)
        for i = 1, 40 do net('pma-voice:setTalkingOnRadio', ME, i % 2 == 0) end
        net('pma-voice:setTalkingOnRadio', ME, true)    -- held back
        net('pma-voice:setPlayerRadio', ME, 0)          -- then the player leaves the radio
        runTimers()
        assert_eq(state(ME).radioActive, false, 'not on a channel any more')
    end)

    it('a write held back for a player who left is dropped', function()
        for i = 1, 21 do net('pma-voice:server:setVolume', ME, i, 'call') end
        Mock.fireEvent('playerDropped', ME)
        clearWrites()
        runTimers()
        assert_eq(#writes, 0)
    end)
end)

-- ── the patched client, end to end ────────────────────────────────
describe('pma-voice client (patched copy)', function()
    local clientWrites, toServer, handlers, commands, clientExports = {}, {}, {}, {}, {}
    local c = {}
    c.LocalPlayer = { state = newBag(ME, clientWrites) }
    c.Player = function(id) return { state = newBag(id, clientWrites) } end
    c.Entity = c.Player
    c.IsDuplicityVersion = function() return false end
    c.GetGameName = function() return 'fivem' end
    c.GetConvar = function(_, d) return d end
    c.GetConvarInt = function(_, d) return d end
    c.GetPlayerServerId = function() return ME end
    c.GetActivePlayers = function() return {} end
    c.TriggerServerEvent = function(name, ...) toServer[#toServer + 1] = { name = name, args = { ... } } end
    c.RegisterNetEvent = function(name, fn) if fn then handlers[name] = fn end end
    c.AddEventHandler = c.RegisterNetEvent
    c.TriggerEvent = function(name, ...) if handlers[name] then handlers[name](...) end end
    c.RegisterCommand = function(name, fn) commands[name] = fn end
    c.RegisterNUICallback = function() end
    c.exports = setmetatable({}, { __call = function(_, name, fn) clientExports[name] = fn end })
    c.CreateThread = function() end
    c.Wait = function() end
    c.SetTimeout = function() end
    c.Citizen = { CreateThread = c.CreateThread, Wait = c.Wait, Await = function() end }
    c.promise = { new = function() return { resolve = function() end } end }
    c.json = json
    c.print = function() end                 -- pma-voice logs every connection step
    for _, k in ipairs({ 'string', 'table', 'math', 'os', 'coroutine', 'pairs', 'ipairs', 'type', 'tostring', 'tonumber',
        'error', 'assert', 'pcall', 'select', 'next', 'setmetatable', 'getmetatable', 'rawget', 'rawset' }) do
        c[k] = _G[k]
    end
    -- every other native: a no-op; nothing from the server's globals leaks in
    setmetatable(c, { __index = function(_, k)
        if type(k) == 'string' and k:match('^%u') then return function() return nil end end
    end })
    for _, f in ipairs({
        'pma-voice/shared.lua', 'pma-voice/client/utils/Nui.lua', 'pma-voice/client/init/proximity.lua',
        'pma-voice/client/init/init.lua', 'pma-voice/client/init/main.lua', 'pma-voice/client/init/submix.lua',
        'pma-voice/client/module/phone.lua', 'pma-voice/client/module/radio.lua',
        'pma-voice/client/commands.lua', 'pma-voice/client/events.lua',
    }) do
        assert(load(__readfile(f), '@' .. f, 't', c))()
    end

    local function sent()
        local out = {}
        for _, e in ipairs(toServer) do
            local a = {}
            for i, v in ipairs(e.args) do
                if type(v) == 'table' then a[i] = ('{%s,%s,%s}'):format(v.index, v.distance, v.mode) else a[i] = tostring(v) end
            end
            out[#out + 1] = e.name:gsub('^pma%-voice:', '') .. '(' .. table.concat(a, ',') .. ')'
        end
        return table.concat(out, ' ')
    end
    local function deliver()
        for _, e in ipairs(toServer) do Mock.fireNet(e.name, ME, table.unpack(e.args)) end
        toServer = {}
    end

    it('volume, intent and proximity go to the server and land in the same state', function()
        toServer = {}
        clientExports.setRadioVolume(40)
        commands.vol(0, { '25' })
        commands.setvoiceintent(0, { 'music' })
        commands.setvoiceintent(0, { 'rock' })                     -- not an intent: nothing sent
        commands.cycleproximity()
        handlers.mumbleConnected('addr', false)
        assert_eq(sent(), 'server:setVolume(40,radio) server:setVolume(25) server:setVoiceIntent(music) '
            .. 'server:setProximity({3,15.0,Shouting}) server:setProximity({3,15.0,Shouting})')
        deliver()
        assert_eq(state(ME).radio, 25)
        assert_eq(state(ME).call, 25)
        assert_eq(state(ME).voiceIntent, 'music')
        assert_eq(state(ME).proximity.mode, 'Shouting')
        assert_eq(state(ME).proximity.index, 3)
        assert_eq(clientExports.getRadioVolume(), 25, 'the volume itself still applies on the client')
    end)

    it('disableRadio bits build on each other at once, and the radio is blocked at once', function()
        toServer = {}
        clientExports.addRadioDisableBit(1)
        clientExports.addRadioDisableBit(4)                        -- before the server replied
        assert_false(c.isRadioEnabled(), 'blocked without waiting for the server')
        clientExports.removeRadioDisableBit(1)
        assert_false(c.isRadioEnabled())
        clientExports.removeRadioDisableBit(4)
        assert_true(c.isRadioEnabled())
        assert_eq(sent(), 'server:setDisableRadio(1) server:setDisableRadio(5) server:setDisableRadio(4) server:setDisableRadio(0)')
        deliver()
        assert_eq(state(ME).disableRadio, 0)
    end)

    it('talking on the radio makes the server set radioActive', function()
        toServer = {}
        clientExports.setRadioChannel(3)
        commands['+radiotalk']()
        assert_eq(sent(), 'setPlayerRadio(3) setTalkingOnRadio(true)')
        deliver()
        assert_eq(state(ME).radioActive, true)
        commands['-radiotalk']()
        deliver()
        assert_eq(state(ME).radioActive, false)
    end)

    it('the client wrote no state bag in any of this, nor when it starts', function()
        handlers.onClientResourceStart(nil)
        assert_eq(#clientWrites, 0)
    end)
end)
