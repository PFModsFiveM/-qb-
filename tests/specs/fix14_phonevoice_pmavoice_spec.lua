-- pma-voice call channels (batch 14, X-5): with voice_serverCallsOnly (default 1) a client cannot put
-- itself into a call channel with the net event pma-voice:setPlayerCall (it could join any phone
-- call by number and listen in). It can still leave its call (0); server resources set channels
-- through the setPlayerCall export, as pfm-phone does. voice_serverCallsOnly 0 keeps the old event.
load_resource('tests/lua/fivem_mocks.lua')

local serverConvars, bags = {}, {}
function Player(src)
    bags[src] = bags[src] or { state = setmetatable({}, { __index = function(t, k)
        if k == 'set' then return function(self, key, value) rawset(self, key, value) end end
    end }) }
    return bags[src]
end
function IsDuplicityVersion() return true end
function GetGameName() return 'fivem' end
function GetConvar(name, default) local v = serverConvars[name] if v == nil then return default end return tostring(v) end
function GetConvarInt(name, default) local v = serverConvars[name] if v == nil then return default end return math.tointeger(tonumber(v)) or default end
function SetConvarReplicated() end
function GetPlayers() return {} end

load_resource('pma-voice/shared.lua')
load_resource('pma-voice/server/main.lua')
load_resource('pma-voice/server/module/phone.lua')
local setPlayerCallExport = Mock.selfExport('setPlayerCall')

local ME, VICTIM_A, VICTIM_B = 1, 2, 3
local CALL = 4242

local function members(channel)
    local out = {}
    for src in pairs(callData[channel] or {}) do out[#out + 1] = src end
    table.sort(out)
    return table.concat(out, ',')
end

BeforeEach = function()
    Mock.reset()
    serverConvars = {}
    for k in pairs(callData) do callData[k] = nil end
    for k in pairs(voiceData) do voiceData[k] = nil end
    -- two players in a phone call, put there by the server (pfm-phone)
    Mock.invokingResource = 'pfm-phone'
    setPlayerCallExport(VICTIM_A, CALL)
    setPlayerCallExport(VICTIM_B, CALL)
    Mock.invokingResource = nil
    Mock.reset()
end

describe('pma-voice:setPlayerCall from a client', function()
    it('cannot join a call channel (the server-calls-only default)', function()
        assert_eq(members(CALL), '2,3')
        Mock.fireNet('pma-voice:setPlayerCall', ME, CALL)
        assert_eq(members(CALL), '2,3')
        assert_eq(voiceData[ME] and voiceData[ME].call or 0, 0)
        -- nobody in the call was told to hear the attacker
        for _, e in ipairs(Mock.clientEventsNamed('pma-voice:addPlayerToCall')) do assert_true(e.args[1] ~= ME, 'the attacker was added') end
        assert_eq(#Mock.clientEventsNamed('pma-voice:syncCallData'), 0)
    end)

    it('can still leave its own call', function()
        Mock.fireNet('pma-voice:setPlayerCall', VICTIM_A, 0)
        assert_eq(members(CALL), '3')
        assert_eq(voiceData[VICTIM_A].call, 0)
    end)

    it('voice_serverCallsOnly 0 keeps the old client event', function()
        serverConvars.voice_serverCallsOnly = 0
        Mock.fireNet('pma-voice:setPlayerCall', ME, CALL)
        assert_eq(members(CALL), '1,2,3')
    end)
end)

describe('the setPlayerCall export (server resources)', function()
    it('still sets and clears call channels', function()
        Mock.invokingResource = 'pfm-phone'
        setPlayerCallExport(ME, 777)
        assert_eq(members(777), '1')
        assert_eq(#Mock.clientEventsNamed('pma-voice:clSetPlayerCall'), 1)
        setPlayerCallExport(ME, 0)
        assert_eq(members(777), '')
        Mock.invokingResource = nil
    end)
end)
