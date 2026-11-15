-- Copyright (c) 2026 Whippy, from WHIP, LGPL-3.0; modified for PF.
-- Port of whip_core/client/player_prefs.lua. This file is free software under the GNU Lesser
-- General Public License 3.0 (see COPYING.LESSER and COPYING in this resource).
--
-- Per-player settings, kept on the player's PC (resource KVP). Only a value that differs from the
-- default is saved, so a player who never changes a setting follows the server's default even when
-- it changes later. The server can force a value (Config.ForcedPrefs or the pfm_ui_forced convar):
-- then that value is in force and a change is refused.
--
--     PfmPrefs.define({ key = 'pad.enabled', type = 'toggle', label = 'Controller support', default = true })
--     PfmPrefs.get('pad.enabled')
--     PfmPrefs.set('pad.enabled', false)
--     PfmPrefs.onChange('pad.enabled', function(value) end)
--
-- Types: 'toggle' (true/false), 'choice' (one of options' values), 'slider' (number, min..max, step).

PfmPrefs = {}

local KVP = 'pfm-ui:prefs'
local KVP_VERSION = 1
local CONVAR = 'pfm_ui_forced'

local _defs = {}      -- [key] = def
local _order = {}     -- keys in the order defined
local _chosen = {}    -- [key] = the player's own value (only ones that differ from the default)
local _hooks = {}     -- [key] = { fn, ... }

-- saved on this PC

local function load()
    local raw = GetResourceKvpString(KVP)
    if type(raw) ~= 'string' or raw == '' then return end
    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= 'table' or type(data.values) ~= 'table' then return end
    for k, v in pairs(data.values) do
        if type(k) == 'string' then _chosen[k] = v end
    end
end

local function save()
    if next(_chosen) == nil then DeleteResourceKvp(KVP) return end
    SetResourceKvp(KVP, json.encode({ v = KVP_VERSION, values = _chosen }))
end

load()

-- values

-- Not `ok and v or nil`: a default of false would come out nil.
local function defaultOf(def)
    local d = def.default
    if type(d) == 'function' then
        local ok, v = pcall(d)
        if ok then d = v else d = nil end
    end
    return d
end

--- `value` made into what `def` takes, or nil (refused).
local function clean(def, value)
    if def.type == 'toggle' then
        if value == true or value == false then return value end
        if value == 'true' then return true end
        if value == 'false' then return false end
        return nil
    elseif def.type == 'choice' then
        for _, o in ipairs(def.options or {}) do
            if o.value == value or tostring(o.value) == tostring(value) then return o.value end
        end
        return nil
    elseif def.type == 'slider' then
        local n = tonumber(value)
        if not n or n ~= n then return nil end
        local min, max, step = tonumber(def.min) or 0, tonumber(def.max) or 100, tonumber(def.step) or 1
        n = math.max(min, math.min(max, n))
        if step > 0 then n = min + math.floor((n - min) / step + 0.5) * step end
        return math.max(min, math.min(max, n))
    end
    return nil
end

-- The convar, parsed once per distinct value: "key=value,key=value".
local convarRaw, convarValues = nil, {}
local function convarForced()
    local raw = GetConvar(CONVAR, '')
    if raw == convarRaw then return convarValues end
    convarRaw, convarValues = raw, {}
    for pair in tostring(raw):gmatch('[^,;]+') do
        local k, v = pair:match('^%s*([%w_%.%-]+)%s*[=]%s*(.-)%s*$')
        if k then convarValues[k] = v end
    end
    return convarValues
end

--- The value the server forces for this setting, or nil while the player chooses.
local function forcedOf(def)
    local v = Config.ForcedPrefs and Config.ForcedPrefs[def.key]
    if v == nil then v = convarForced()[def.key] end
    if v == nil then return nil end
    return clean(def, v)
end

--- The value in force: the server's when forced, else the player's own, else the default.
---@param key string
---@return any
function PfmPrefs.get(key)
    local def = _defs[key]
    if not def then return nil end
    local f = forcedOf(def)
    if f ~= nil then return f end
    local v = _chosen[key]
    if v ~= nil then
        v = clean(def, v)
        if v ~= nil then return v end
    end
    return clean(def, defaultOf(def))
end

function PfmPrefs.isForced(key)
    local def = _defs[key]
    return def ~= nil and forcedOf(def) ~= nil
end

local function fire(key, value)
    for _, fn in ipairs(_hooks[key] or {}) do
        local ok, err = pcall(fn, value)
        if not ok then print(('[pfm-ui:prefs] the hook for %s failed: %s'):format(key, tostring(err))) end
    end
    -- other resources (the pad bridge) hear it too
    TriggerEvent('pfm-ui:prefChanged', key, value)
end

--- Change one. A value equal to the default is not kept: the player follows the default again.
---@return boolean ok, string|nil why
function PfmPrefs.set(key, value)
    local def = _defs[key]
    if not def then return false, 'no such setting' end
    if forcedOf(def) ~= nil then return false, 'set by the server' end
    local v = clean(def, value)
    if v == nil then return false, 'not a value this setting takes' end
    local was = PfmPrefs.get(key)
    if v == clean(def, defaultOf(def)) then _chosen[key] = nil else _chosen[key] = v end
    save()
    if v ~= was then fire(key, v) end
    return true
end

--- Back to the default: one key, or every setting when key is nil.
function PfmPrefs.reset(key)
    if key ~= nil then
        if not _defs[key] then return false, 'no such setting' end
        local was = PfmPrefs.get(key)
        _chosen[key] = nil
        save()
        local now = PfmPrefs.get(key)
        if now ~= was then fire(key, now) end
        return true
    end
    local before = {}
    for k in pairs(_defs) do before[k] = PfmPrefs.get(k) end
    _chosen = {}
    save()
    for k in pairs(_defs) do
        local now = PfmPrefs.get(k)
        if now ~= before[k] then fire(k, now) end
    end
    return true
end

function PfmPrefs.onChange(key, fn)
    if type(key) ~= 'string' or type(fn) ~= 'function' then return end
    _hooks[key] = _hooks[key] or {}
    table.insert(_hooks[key], fn)
end

-- declaring

local TYPES = { toggle = true, choice = true, slider = true }

local function normalise(def)
    if type(def) ~= 'table' then return nil, 'needs a table' end
    if type(def.key) ~= 'string' or not def.key:match('^[%w_%.%-]+$') or #def.key > 64 then
        return nil, 'key must be letters, digits, dots, dashes or underscores (1-64)'
    end
    if not TYPES[def.type] then return nil, 'type must be toggle, choice or slider' end
    if type(def.label) ~= 'string' or def.label == '' then return nil, 'label is required' end
    local d = {
        key = def.key, type = def.type, label = def.label:sub(1, 60),
        group = type(def.group) == 'string' and def.group:sub(1, 30) or 'Other',
        help = type(def.help) == 'string' and def.help:sub(1, 240) or nil,
        default = def.default,
    }
    if def.type == 'choice' then
        local opts = {}
        for _, o in ipairs(type(def.options) == 'table' and def.options or {}) do
            if type(o) == 'table' and o.value ~= nil and type(o.label) == 'string' then
                opts[#opts + 1] = { value = o.value, label = o.label:sub(1, 40) }
            end
        end
        if #opts < 2 then return nil, 'a choice needs at least two options, each { value, label }' end
        d.options = opts
    elseif def.type == 'slider' then
        d.min, d.max, d.step = tonumber(def.min), tonumber(def.max), tonumber(def.step) or 1
        if not d.min or not d.max or d.max <= d.min or d.step <= 0 then
            return nil, 'a slider needs min < max and a step over 0'
        end
    end
    return d
end

---@return boolean ok, string|nil why
function PfmPrefs.define(def)
    local d, why = normalise(def)
    if not d then
        print(('[pfm-ui:prefs] %s was not defined: %s'):format(tostring(type(def) == 'table' and def.key), why))
        return false, why
    end
    if not _defs[d.key] then _order[#_order + 1] = d.key end
    _defs[d.key] = d
    return true
end

--- Every setting, in order, with its value, for a menu or /padprefs.
function PfmPrefs.list()
    local out = {}
    for _, key in ipairs(_order) do
        local def = _defs[key]
        out[#out + 1] = {
            key = key, type = def.type, label = def.label, group = def.group, help = def.help,
            options = def.options, min = def.min, max = def.max, step = def.step,
            value = PfmPrefs.get(key), default = clean(def, defaultOf(def)), forced = forcedOf(def) ~= nil,
        }
    end
    return out
end

-- exports: another resource's settings live here too. Across an export only plain values arrive,
-- so its default must be a value, not a function.
exports('DefinePref', function(def)
    if type(def) ~= 'table' then return false, 'needs a table' end
    if type(def.default) == 'table' then return false, 'default must be a plain value' end
    local copy = {}
    for k, v in pairs(def) do copy[k] = v end
    return PfmPrefs.define(copy)
end)
exports('GetPref', function(key) return PfmPrefs.get(key) end)
exports('SetPref', function(key, value) return PfmPrefs.set(key, value) end)
exports('ResetPref', function(key) return PfmPrefs.reset(key) end)
exports('GetPrefs', function() return PfmPrefs.list() end)

-- pfm-ui's own settings

PfmPrefs.define({
    key = 'pad.enabled', group = 'Controller', type = 'toggle', label = 'Controller support',
    help = 'Menus and world buttons answer a gamepad.',
    default = function() return not (Config.Pad and Config.Pad.Enabled == false) end,
})
PfmPrefs.define({
    key = 'pad.repeatDelay', group = 'Controller', type = 'slider', label = 'Menu repeat delay',
    help = 'How long a held direction waits before it repeats.',
    min = 150, max = 1000, step = 10,
    default = function() return (Config.Pad and tonumber(Config.Pad.RepeatDelayMs)) or 380 end,
})
PfmPrefs.define({
    key = 'pad.repeatRate', group = 'Controller', type = 'slider', label = 'Menu repeat rate',
    help = 'Time between repeats of a held direction.',
    min = 40, max = 400, step = 10,
    default = function() return (Config.Pad and tonumber(Config.Pad.RepeatRateMs)) or 110 end,
})
PfmPrefs.define({
    key = 'pad.stickNav', group = 'Controller', type = 'toggle', label = 'Left stick moves in menus',
    help = 'The left stick moves through menus as well as the D-pad.',
    default = true,
})
