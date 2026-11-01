-- Player voice state that the client used to write itself. With sv_stateBagStrictMode a client
-- may not write replicated state bags, so the client asks here and the server writes the value
-- after checking it:
--   voiceIntent           'pma-voice:server:setVoiceIntent'  'speech' or 'music', when allowed
--   disableRadio          'pma-voice:server:setDisableRadio' bit field, 0..MAX_RADIO_DISABLE_BITS
--   radio, call,          'pma-voice:server:setVolume'       0..100 (one type, or all of them)
--   click_on, click_off
--   proximity             'pma-voice:server:setProximity'    { index, distance, mode }
--   radioActive           'pma-voice:setTalkingOnRadio' (radio.lua), only while on a radio channel
-- Every request is rate limited per player and key. A request over the limit is not lost: the
-- latest one is applied when the window ends, so the last value an honest client sent always
-- lands and a spamming client costs one write per window.

local RATE_WINDOW_MS = 5000
local RATE_MAX = { default = 20, radioTalking = 40 }

local VOLUME_KEYS = { radio = true, call = true, click_on = true, click_off = true }
-- order of the "all volumes" write (the client's /vol without a type sets every one of them)
local VOLUME_ORDER = { 'radio', 'call', 'click_on', 'click_off' }
local VOICE_INTENTS = { speech = true, music = true }
local MAX_RADIO_DISABLE_BITS = 0x7FFFFFFF   -- 31 flag bits (an integer in every Lua and JS reader)
local PROXIMITY_MAX_INDEX = 32
local PROXIMITY_MAX_DISTANCE = 1000.0
local PROXIMITY_MODE_MAX_LEN = 32

local writeWindows = {}   -- [src] = { [key] = { start, count, pending, flushing } }

local function isFinite(n)
	return type(n) == 'number' and n == n and n ~= math.huge and n ~= -math.huge
end

--- Runs apply(value) now while `src` is within the rate limit for `key`. Over the limit only the
--- latest value is kept and applied once the window ends.
---@return boolean appliedNow
function throttleVoiceWrite(src, key, value, apply)
	local now = GetGameTimer()
	local perPlayer = writeWindows[src]
	if not perPlayer then
		perPlayer = {}
		writeWindows[src] = perPlayer
	end
	local w = perPlayer[key]
	if not w or now - w.start >= RATE_WINDOW_MS then
		w = { start = now, count = 0 }
		perPlayer[key] = w
	end
	if w.count < (RATE_MAX[key] or RATE_MAX.default) then
		w.count = w.count + 1
		apply(value)
		return true
	end
	w.pending = { value }
	if not w.flushing then
		w.flushing = true
		SetTimeout(math.max(0, RATE_WINDOW_MS - (now - w.start)) + 10, function()
			-- the player left, or a new window already replaced this one
			if writeWindows[src] ~= perPlayer or perPlayer[key] ~= w then return end
			perPlayer[key] = { start = GetGameTimer(), count = 1 }
			apply(w.pending[1])
		end)
	end
	return false
end

--- Forgets a player's rate limit windows (and any write still waiting on one).
function forgetVoiceWrites(src)
	writeWindows[src] = nil
end

local function setState(src, key, value)
	Player(src).state:set(key, value, true)
end

local function ensureVoiceData(src)
	voiceData[src] = voiceData[src] or defaultTable(src)
end

-- volume: a number, clamped to 0..100; volumeType one of VOLUME_KEYS, or nil for all of them
RegisterNetEvent('pma-voice:server:setVolume', function(volume, volumeType)
	local src = source
	if not isFinite(volume) then return end
	if volumeType ~= nil and (type(volumeType) ~= 'string' or not VOLUME_KEYS[volumeType]) then return end
	ensureVoiceData(src)
	volume = math.min(100, math.max(0, volume))
	if volumeType then
		throttleVoiceWrite(src, 'volume:' .. volumeType, volume, function(v) setState(src, volumeType, v) end)
		return
	end
	for _, key in ipairs(VOLUME_ORDER) do
		throttleVoiceWrite(src, 'volume:' .. key, volume, function(v) setState(src, key, v) end)
	end
end)

-- proximity: only the three fields pma-voice publishes are copied from the client's table
RegisterNetEvent('pma-voice:server:setProximity', function(data)
	local src = source
	if type(data) ~= 'table' then return end
	local index, distance, mode = data.index, data.distance, data.mode
	if not isFinite(index) or index % 1 ~= 0 or index < 1 or index > PROXIMITY_MAX_INDEX then return end
	if not isFinite(distance) or distance < 0 or distance > PROXIMITY_MAX_DISTANCE then return end
	if type(mode) ~= 'string' or #mode < 1 or #mode > PROXIMITY_MODE_MAX_LEN or mode:find('%c') then return end
	ensureVoiceData(src)
	local value = { index = math.tointeger(index), distance = distance, mode = mode }
	throttleVoiceWrite(src, 'proximity', value, function(v) setState(src, 'proximity', v) end)
end)

-- voiceIntent: 'speech' or 'music', and only while the server allows players to choose it
RegisterNetEvent('pma-voice:server:setVoiceIntent', function(intent)
	local src = source
	if GetConvarInt('voice_allowSetIntent', 1) ~= 1 then return end
	if type(intent) ~= 'string' or not VOICE_INTENTS[intent] then return end
	ensureVoiceData(src)
	throttleVoiceWrite(src, 'voiceIntent', intent, function(v) setState(src, 'voiceIntent', v) end)
end)

-- disableRadio: the whole bit field the client's add/removeRadioDisableBit exports computed. The
-- bits are the client's own (other client resources block its radio with them), so the server
-- checks the value and publishes it; it cannot know which bits should be set.
RegisterNetEvent('pma-voice:server:setDisableRadio', function(bits)
	local src = source
	if not isFinite(bits) or bits % 1 ~= 0 or bits < 0 or bits > MAX_RADIO_DISABLE_BITS then return end
	ensureVoiceData(src)
	throttleVoiceWrite(src, 'disableRadio', math.tointeger(bits), function(v) setState(src, 'disableRadio', v) end)
end)

--- Sets radioActive. True only while `src` is a member of the radio channel voiceData says they
--- are on; anything else publishes false (and false is written only when it was set).
function setRadioActive(src, active)
	local plyVoice = voiceData[src]
	local channel = plyVoice and plyVoice.radio or 0
	local onRadio = channel ~= 0 and radioData[channel] ~= nil and radioData[channel][src] ~= nil
	local state = Player(src).state
	if active == true and onRadio then
		state:set('radioActive', true, true)
	elseif state.radioActive then
		state:set('radioActive', false, true)
	end
end
