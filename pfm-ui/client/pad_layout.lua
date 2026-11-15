-- Copyright (c) 2026 Whippy, from WHIP, LGPL-3.0; modified for PF.
-- Port of whip_core/client/pad.lua (buttons, per-player layout, LB as a modifier). Free software
-- under the GNU Lesser General Public License 3.0 (see COPYING.LESSER and COPYING in this resource).
--
-- The pad in the world. FiveM key mappings never fire from a pad, so while a pad is the device the
-- buttons are read as frontend controls every frame and run the action the layout puts on them.
-- Config.Pad.Layout is the default; each player can change theirs (/padbind), saved in a KVP with
-- only the buttons that differ from the default. Other resources add actions with RegisterPadAction.
-- Nothing runs while a NUI page has focus or the pause menu is open: then the page's bridge reads the pad.

PadLayout = {}

--- The buttons. `lb`: read while LB is held. `hold`: the action runs for as long as it is held.
local SLOTS = {
    { id = 'dpad_up',       control = 188, name = 'D-Up' },
    { id = 'dpad_down',     control = 187, name = 'D-Down' },
    { id = 'dpad_left',     control = 189, name = 'D-Left' },
    { id = 'dpad_right',    control = 190, name = 'D-Right' },
    { id = 'lb',            control = 205, name = 'LB (hold)', hold = true },
    { id = 'lb_a',          control = 201, name = 'LB+A',       lb = true },
    { id = 'lb_b',          control = 202, name = 'LB+B',       lb = true },
    { id = 'lb_x',          control = 203, name = 'LB+X',       lb = true },
    { id = 'lb_y',          control = 204, name = 'LB+Y',       lb = true },
    { id = 'lb_dpad_up',    control = 188, name = 'LB+D-Up',    lb = true },
    { id = 'lb_dpad_down',  control = 187, name = 'LB+D-Down',  lb = true },
    { id = 'lb_dpad_left',  control = 189, name = 'LB+D-Left',  lb = true },
    { id = 'lb_dpad_right', control = 190, name = 'LB+D-Right', lb = true },
}
local SLOT = {}
for _, s in ipairs(SLOTS) do SLOT[s.id] = s end

--- GTA's own use of LB on foot (the weapon wheel), held off while LB has an action.
local LB_BLOCK = { 37, 14, 15, 16, 17, 99, 100 }

--- Built-in actions: the command each runs. A '+' command gets its '-' half on release.
--- `alt`: tried when the first command is not registered (pfm-target's toggle mode).
local ACTIONS = {
    radial    = { label = 'Radial menu',       command = 'radialmenu' },
    inventory = { label = 'Inventory',         command = 'openInv' },
    target    = { label = 'Target / interact', command = '+playerTarget', alt = 'playerTarget' },
    phone     = { label = 'Phone',             command = 'phone' },
    menufocus = { label = 'Focus the menu',    command = 'playerfocus' },
    emotes    = { label = 'Emote menu',        command = 'emotemenu' },
}

local registered = {}   -- [id] = action another resource registered, with its owner

local function actionOf(id)
    return ACTIONS[id] or registered[id]
end

local function commandExists(name)
    for _, c in ipairs(GetRegisteredCommands and GetRegisteredCommands() or {}) do
        if c.name == name then return true end
    end
    return false
end

-- the layout

local KVP_KEY = 'pfm-ui:layout'
local KVP_VERSION = 1

local mine = nil     -- the player's own changes: { [slot] = action | false }, or nil
local layout = {}    -- in force: [slot] = action
local running = {}   -- [slot] = what its press holds down: a '-' command, or { fn = onRelease }

local function defaults()
    local out = {}
    local used = {}
    local src = Config.Pad and Config.Pad.Layout or {}
    for _, s in ipairs(SLOTS) do
        local a = src[s.id]
        if type(a) == 'string' and not used[a] then
            out[s.id] = a
            used[a] = true
        end
    end
    -- a registered action goes on the button it asks for, when that button is free (nil or false)
    local ids = {}
    for id in pairs(registered) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local want = registered[id].slot
        if want and SLOT[want] and out[want] == nil and not used[id] then
            out[want] = id
            used[id] = true
        end
    end
    return out
end

local function letGo(slotId)
    local r = running[slotId]
    running[slotId] = nil
    if type(r) == 'table' then
        local ok, err = pcall(r.fn)
        if not ok then print(('[pfm-ui:pad] %s: release failed: %s'):format(slotId, tostring(err))) end
    elseif r then
        ExecuteCommand(r)
    end
end

local function stopAll()
    for slotId in pairs(running) do letGo(slotId) end
end

local function resolve()
    stopAll()
    local t = defaults()
    if mine then
        for _, s in ipairs(SLOTS) do
            local a = mine[s.id]
            if a == false then
                t[s.id] = nil
            elseif type(a) == 'string' then
                -- an action is on one button only: the player's choice wins
                for k, v in pairs(t) do if v == a then t[k] = nil end end
                t[s.id] = a
            end
        end
    end
    layout = t
end

local function loadMine()
    local raw = GetResourceKvpString(KVP_KEY)
    if type(raw) ~= 'string' or raw == '' then return nil end
    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= 'table' or type(data.layout) ~= 'table' then return nil end
    local t, any = {}, false
    for _, s in ipairs(SLOTS) do
        local a = data.layout[s.id]
        if type(a) == 'string' and a:match('^[%a][%w_]*$') then t[s.id] = a; any = true
        elseif a == false then t[s.id] = false; any = true end
    end
    return any and t or nil
end

local function saveMine()
    if mine and next(mine) then
        SetResourceKvp(KVP_KEY, json.encode({ v = KVP_VERSION, layout = mine }))
    else
        mine = nil
        DeleteResourceKvp(KVP_KEY)
    end
end

--- Put an action (false: nothing) on a button. The action leaves the button it was on, which takes
--- this button's old action (a swap). Only differences from the default are kept.
---@return boolean ok, string|nil why
function PadLayout.setSlot(slotId, actionId)
    if type(slotId) ~= 'string' or not SLOT[slotId] then return false, 'no such button' end
    if actionId ~= false and not actionOf(actionId) then return false, 'no such action' end
    local t = {}
    for _, s in ipairs(SLOTS) do t[s.id] = layout[s.id] or false end
    local old = t[slotId]
    if actionId then
        for _, s in ipairs(SLOTS) do
            if s.id ~= slotId and t[s.id] == actionId then t[s.id] = old end
        end
    end
    t[slotId] = actionId
    local def = defaults()
    local diff = {}
    for _, s in ipairs(SLOTS) do
        if (def[s.id] or false) ~= t[s.id] then diff[s.id] = t[s.id] end
    end
    mine = next(diff) and diff or nil
    saveMine()
    resolve()
    return true
end

function PadLayout.reset()
    mine = nil
    saveMine()
    resolve()
end

function PadLayout.get()
    local out = {}
    for _, s in ipairs(SLOTS) do out[s.id] = layout[s.id] or false end
    return out
end

function PadLayout.saved() return mine end

-- pressing

--- The world is free for an action: no NUI focus, no pause menu.
local function worldFree()
    if IsNuiFocused and IsNuiFocused() then return false end
    if IsPauseMenuActive and IsPauseMenuActive() then return false end
    return true
end

--- Can the button's action run now (an onPress, or a registered command)?
local function runnable(slotId)
    local id = layout[slotId]
    local a = id and actionOf(id)
    if not a then return false end
    if a.onPress ~= nil then return true end
    return commandExists(a.command) or (a.alt ~= nil and commandExists(a.alt))
end

--- Run what a button holds. Answers what it did (for /padlayout and the specs).
function PadLayout.press(slotId)
    local id = layout[slotId]
    local a = id and actionOf(id)
    if not a then return 'nothing on it' end
    if a.onPress ~= nil then
        local ok, err = pcall(a.onPress)
        if not ok then return a.label .. ': failed: ' .. tostring(err) end
        if a.onRelease ~= nil then running[slotId] = { fn = a.onRelease } end
        return a.label
    end
    local cmd = a.command
    if not commandExists(cmd) then
        if a.alt and commandExists(a.alt) then cmd = a.alt else return cmd .. ': no such command' end
    end
    ExecuteCommand(cmd)
    if cmd:sub(1, 1) == '+' then running[slotId] = '-' .. cmd:sub(2) end
    return cmd
end

local lbHeld = false

--- One frame of reading. Called every frame while a pad is the device.
function PadLayout.frame()
    local lbDown = IsDisabledControlPressed(0, 205)
    if lbDown ~= lbHeld then
        if lbDown then
            if PfmPad.now() then
                lbHeld = true
                if layout.lb and worldFree() then PadLayout.press('lb') end
            end
        else
            lbHeld = false
            letGo('lb')
            for _, s in ipairs(SLOTS) do if s.lb then letGo(s.id) end end
        end
    end

    -- LB with an action on it: the weapon wheel stays shut
    if lbHeld and layout.lb then
        for i = 1, #LB_BLOCK do DisableControlAction(0, LB_BLOCK[i], true) end
    end

    for i = 1, #SLOTS do
        local s = SLOTS[i]
        if running[s.id] and not s.hold and IsDisabledControlJustReleased(0, s.control) then letGo(s.id) end
    end

    for i = 1, #SLOTS do
        local s = SLOTS[i]
        if not s.hold and IsDisabledControlJustPressed(0, s.control) then
            if s.lb then
                if lbHeld and layout[s.id] and worldFree() and runnable(s.id) then
                    -- a combo with an action of its own ends LB's hold action first
                    if running.lb then letGo('lb') end
                    PadLayout.press(s.id)
                end
            elseif not lbHeld and layout[s.id] and worldFree() and PfmPad.now() then
                PadLayout.press(s.id)
            end
        end
    end
end

--- The keyboard took over: let go of everything.
function PadLayout.idle()
    if lbHeld then lbHeld = false end
    stopAll()
end

CreateThread(function()
    while true do
        if PfmPad.now() or lbHeld then
            PadLayout.frame()
            Wait(0)
        else
            if next(running) then PadLayout.idle() end
            Wait(200)
        end
    end
end)

-- other resources' actions
--
--     exports['pfm-ui']:RegisterPadAction('engine', {
--         label = 'Engine on/off',
--         command = 'engine',          -- or onPress = function() end, onRelease = function() end
--         slot = 'lb_x',               -- the button it goes on when that is free in the default layout
--     })

local function validAction(id, def)
    if type(id) ~= 'string' or not id:match('^[%a][%w_]*$') or #id > 32 then
        return false, 'an action needs a name of letters, digits and _ (up to 32)'
    end
    if ACTIONS[id] then return false, ('"%s" is one of pfm-ui\'s own actions'):format(id) end
    if type(def) ~= 'table' then return false, 'the second argument is its table' end
    if type(def.label) ~= 'string' or def.label == '' then return false, 'label is required' end
    if (def.command == nil) == (def.onPress == nil) then return false, 'give it a command or an onPress' end
    if def.command ~= nil and (type(def.command) ~= 'string' or not def.command:match('^[%w_%+%-%.%:]+$')) then
        return false, 'command must be a command name'
    end
    if def.slot ~= nil and not SLOT[def.slot] then return false, 'no such button: ' .. tostring(def.slot) end
    return true
end

exports('RegisterPadAction', function(id, def)
    local owner = GetInvokingResource() or GetCurrentResourceName()
    local ok, why = validAction(id, def)
    if not ok then return false, why end
    registered[id] = {
        label = def.label, command = def.command, onPress = def.onPress, onRelease = def.onRelease,
        slot = def.slot, owner = owner,
    }
    resolve()
    return true
end)

exports('RemovePadAction', function(id)
    local a = registered[id]
    if not a then return false, 'no such action' end
    local owner = GetInvokingResource() or GetCurrentResourceName()
    if a.owner ~= owner then return false, 'not your action' end
    registered[id] = nil
    resolve()
    return true
end)

exports('GetLayout', function() return PadLayout.get() end)
exports('SetLayoutSlot', function(slot, action) return PadLayout.setSlot(slot, action) end)
exports('ResetLayout', function() PadLayout.reset() return true end)

--- Everything a layout screen needs (pfm-pause's Controller screen): the buttons in force, every action that can
--- go on one ({ id, label }, pfm-ui's own first, then registered ones by id) and whether the player changed any.
function PadLayout.state()
    local actions = {}
    local order, seen = { 'radial', 'inventory', 'target', 'phone', 'menufocus', 'emotes' }, {}
    local extra = {}
    for id in pairs(ACTIONS) do extra[#extra + 1] = id end
    table.sort(extra)
    for _, id in ipairs(extra) do order[#order + 1] = id end
    for _, id in ipairs(order) do
        if ACTIONS[id] and not seen[id] then
            seen[id] = true
            actions[#actions + 1] = { id = id, label = ACTIONS[id].label }
        end
    end
    local ids = {}
    for id in pairs(registered) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do actions[#actions + 1] = { id = id, label = registered[id].label } end
    return { layout = PadLayout.get(), actions = actions, custom = mine ~= nil }
end

exports('GetLayoutState', function() return PadLayout.state() end)

--- Which button an action is on: slot id, its name ('LB+Y') and its glyph names ({ 'lb', 'y' }).
exports('GetPadActionButton', function(id)
    for _, s in ipairs(SLOTS) do
        if layout[s.id] == id then
            local glyphs
            if s.id == 'lb' then glyphs = { 'lb' }
            elseif s.lb then glyphs = { 'lb', (s.id:gsub('^lb_', '')) }
            else glyphs = { s.id } end
            return s.id, s.name, glyphs
        end
    end
    return nil
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        stopAll()
        return
    end
    local changed = false
    for id, a in pairs(registered) do
        if a.owner == resource then registered[id] = nil; changed = true end
    end
    if changed then resolve() end
end)

-- player commands (there is no settings screen yet)

local function say(msg)
    print('[pfm-ui] ' .. msg)
    TriggerEvent('chat:addMessage', { args = { 'pfm-ui', msg } })
end

RegisterCommand('padlayout', function()
    for _, s in ipairs(SLOTS) do
        local id = layout[s.id]
        local a = id and actionOf(id)
        say(('%s: %s'):format(s.name, a and (a.label .. ' (' .. id .. ')') or '-'))
    end
end, false)

RegisterCommand('padbind', function(_, args)
    local slot, action = args[1], args[2]
    if not slot or not action then return say('usage: /padbind <slot> <action|none>') end
    local value = action
    if action == 'none' or action == 'false' then value = false end
    local ok, why = PadLayout.setSlot(slot, value)
    say(ok and ('%s is now %s'):format(slot, action) or ('not changed: ' .. tostring(why)))
end, false)

RegisterCommand('padreset', function()
    PadLayout.reset()
    say('controller layout back to the server default')
end, false)

RegisterCommand('padset', function(_, args)
    local key, value = args[1], args[2]
    if not key or value == nil then return say('usage: /padset <setting> <value>  (see /padprefs)') end
    local ok, why = PfmPrefs.set(key, value)
    say(ok and ('%s = %s'):format(key, tostring(PfmPrefs.get(key))) or ('not changed: ' .. tostring(why)))
end, false)

RegisterCommand('padprefs', function()
    for _, p in ipairs(PfmPrefs.list()) do
        say(('%s = %s%s'):format(p.key, tostring(p.value), p.forced and ' (set by the server)' or ''))
    end
end, false)

mine = loadMine()
resolve()
