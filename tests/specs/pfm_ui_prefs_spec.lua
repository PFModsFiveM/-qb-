-- pfm-ui player settings (client/prefs.lua, ported from WHIP's player_prefs.lua): only values that
-- differ from the default are saved in the KVP, the server can force a value (Config.ForcedPrefs or
-- the pfm_ui_forced convar) and then a change is refused, and other resources define their own.
load_resource('tests/lua/fivem_mocks.lua')

local kvp, convars, events, exported

--- A fresh client: pfm-ui's config and prefs.lua in their own environment, sharing `kvp`.
local function client(forced)
    events, exported = {}, {}
    local env = setmetatable({}, { __index = _G })
    env.GetResourceKvpString = function(k) return kvp[k] end
    env.SetResourceKvp = function(k, v) kvp[k] = v end
    env.DeleteResourceKvp = function(k) kvp[k] = nil end
    env.GetConvar = function(k, d) local v = convars[k]; if v == nil then return d end return v end
    env.TriggerEvent = function(name, ...) events[#events + 1] = { name = name, args = { ... } } end
    env.exports = setmetatable({}, { __call = function(_, name, fn) exported[name] = fn end })
    env.print = function() end
    assert(load(__readfile('pfm-ui/config.lua'), '@pfm-ui/config.lua', 't', env))()
    if forced then env.Config.ForcedPrefs = forced end
    assert(load(__readfile('pfm-ui/client/prefs.lua'), '@pfm-ui/client/prefs.lua', 't', env))()
    return env
end

local function saved()
    local raw = kvp['pfm-ui:prefs']
    if not raw then return nil end
    return json.decode(raw).values
end

BeforeEach = function()
    kvp, convars = {}, {}
end

describe('pfm-ui prefs: defaults and saving', function()
    it('starts on the defaults with nothing saved', function()
        local env = client()
        assert_eq(env.PfmPrefs.get('pad.enabled'), true)
        assert_eq(env.PfmPrefs.get('pad.repeatDelay'), 380)
        assert_eq(env.PfmPrefs.get('pad.repeatRate'), 110)
        assert_eq(env.PfmPrefs.get('pad.stickNav'), true)
        assert_eq(kvp['pfm-ui:prefs'], nil)
    end)

    it('saves only a value that differs from the default', function()
        local env = client()
        assert_true(env.PfmPrefs.set('pad.repeatDelay', 500))
        local v = saved()
        assert_eq(v['pad.repeatDelay'], 500)
        assert_eq(v['pad.enabled'], nil, 'untouched settings are not saved')
        assert_true(env.PfmPrefs.set('pad.repeatDelay', 380))
        assert_eq(kvp['pfm-ui:prefs'], nil, 'back on the default: the KVP is deleted')
    end)

    it('a false toggle is kept and read back by the next session', function()
        local env = client()
        env.PfmPrefs.set('pad.enabled', false)
        assert_eq(saved()['pad.enabled'], false)
        local again = client()
        assert_eq(again.PfmPrefs.get('pad.enabled'), false)
    end)

    it('follows a changed server default when the player never chose', function()
        local env = client()
        env.Config.Pad.RepeatDelayMs = 450
        assert_eq(env.PfmPrefs.get('pad.repeatDelay'), 450)
    end)

    it('sliders are kept in range and on their step; bad values are refused', function()
        local env = client()
        env.PfmPrefs.set('pad.repeatDelay', 5000)
        assert_eq(env.PfmPrefs.get('pad.repeatDelay'), 1000)
        env.PfmPrefs.set('pad.repeatDelay', 333)
        assert_eq(env.PfmPrefs.get('pad.repeatDelay'), 330)
        local ok, why = env.PfmPrefs.set('pad.enabled', 'maybe')
        assert_false(ok)
        assert_eq(why, 'not a value this setting takes')
        assert_false(env.PfmPrefs.set('no.such', 1))
    end)

    it('a change is announced to other resources (pfm-ui:prefChanged)', function()
        local env = client()
        env.PfmPrefs.set('pad.stickNav', false)
        local last = events[#events]
        assert_eq(last.name, 'pfm-ui:prefChanged')
        assert_eq(last.args[1], 'pad.stickNav')
        assert_eq(last.args[2], false)
    end)

    it('reset puts every setting back and clears the KVP', function()
        local env = client()
        env.PfmPrefs.set('pad.enabled', false)
        env.PfmPrefs.set('pad.repeatRate', 200)
        env.PfmPrefs.reset()
        assert_eq(env.PfmPrefs.get('pad.enabled'), true)
        assert_eq(env.PfmPrefs.get('pad.repeatRate'), 110)
        assert_eq(kvp['pfm-ui:prefs'], nil)
    end)
end)

describe('pfm-ui prefs: forced by the server', function()
    it('Config.ForcedPrefs wins, a change is refused, the player choice comes back after', function()
        local env = client()
        env.PfmPrefs.set('pad.enabled', false)         -- the player's own choice
        env.Config.ForcedPrefs = { ['pad.enabled'] = true }
        assert_eq(env.PfmPrefs.get('pad.enabled'), true)
        assert_true(env.PfmPrefs.isForced('pad.enabled'))
        local ok, why = env.PfmPrefs.set('pad.enabled', false)
        assert_false(ok)
        assert_eq(why, 'set by the server')
        env.Config.ForcedPrefs = {}
        assert_eq(env.PfmPrefs.get('pad.enabled'), false, 'kept for when the server lets go')
    end)

    it('the replicated convar forces values (text made into the setting type)', function()
        convars['pfm_ui_forced'] = 'pad.repeatDelay=300, pad.stickNav=false'
        local env = client()
        assert_eq(env.PfmPrefs.get('pad.repeatDelay'), 300)
        assert_eq(env.PfmPrefs.get('pad.stickNav'), false)
        assert_false(env.PfmPrefs.set('pad.repeatDelay', 600))
        local row
        for _, p in ipairs(env.PfmPrefs.list()) do if p.key == 'pad.repeatDelay' then row = p end end
        assert_true(row.forced)
        assert_eq(row.default, 380)
    end)

    it('a forced value the setting cannot take is ignored', function()
        local env = client({ ['pad.repeatRate'] = 'fast' })
        assert_eq(env.PfmPrefs.get('pad.repeatRate'), 110)
        assert_false(env.PfmPrefs.isForced('pad.repeatRate'))
    end)
end)

describe('pfm-ui prefs: exports for other resources', function()
    it('DefinePref / GetPref / SetPref across the boundary', function()
        local env = client()
        local ok = Mock.cross(exported.DefinePref, {
            key = 'phone.vibrate', type = 'toggle', label = 'Vibrate', default = true,
        })
        assert_true(ok)
        assert_eq(Mock.cross(exported.GetPref, 'phone.vibrate'), true)
        assert_true(Mock.cross(exported.SetPref, 'phone.vibrate', false))
        assert_eq(saved()['phone.vibrate'], false)
    end)

    it('a function default does not survive the boundary and is refused', function()
        client()
        local ok, why = Mock.cross(exported.DefinePref, {
            key = 'x.y', type = 'toggle', label = 'X', default = function() return true end,
        })
        assert_false(ok)
        assert_eq(why, 'default must be a plain value')
    end)
end)
