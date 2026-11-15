-- pfm-pause: PF's pause menu in place of GTA's (the page a port of WHIP's). The real client
-- (pfm-pause/client/main.lua) and server (pfm-pause/server/main.lua) run a frame at a time against natives stubbed here:
--   * GTA's pause controls 199 and 200 are held off every frame (closed and open), never while GTA's
--     own frontend is up for the map or settings
--   * the menu opens only when no other page has NUI focus, and not on the Escape that closed one
--   * closing gives back NUI focus, kept input and the blur
--   * Disconnect and Quit ask first: nothing leaves without the confirm token
--   * the controller drives the page while open; Start closes; GTA's settings come back to the menu
--   * the map's data: blips shaped for the page (NaN and hidden ones left out), the player, the waypoint
--     set and cleared from the map; Swap Character through the confirm and the server's checks

local CLIENT = '[qb]/pfm-pause/client/main.lua'
local SERVER = '[qb]/pfm-pause/server/main.lua'

-- ---------------------------------------------------------------------------------------------
-- stubs (local to this spec)
-- ---------------------------------------------------------------------------------------------

local S   -- per-test world

local function reset()
    S = {
        t = 1000,
        nuiFocused = false,
        pauseActive = false,
        loggedIn = true,
        justPressed = {},    -- [control] = true for this frame
        pressed = {},
        usingKeyboard = true,
        disabled = {},       -- [control] = count this frame
        disableAll = 0,
        focus = { has = false, cursor = false },
        keepInput = false,
        blurIn = 0, blurOut = 0,
        nui = {},            -- messages sent to the page
        server = {},         -- TriggerServerEvent names
        events = {},
        commands = {},
        frontends = {},
        resources = {},      -- [name] = 'started'
        exportsOf = {},      -- [resource] = { Fn = function }
        threads = {},
        callbacks = {},
        netHandlers = {},
        handlers = {},
        dropped = {},
        blips = {},          -- [sprite] = { { x, y, display, alpha, hud } }
        waypoint = nil,      -- { x, y } or nil
        waypointSet = nil, waypointOff = 0,
        timeouts = {},
        playerData = {
            citizenid = 'ABC123',
            charinfo = { firstname = 'Jane', lastname = 'Doe' },
            job = { label = 'Police', name = 'police', grade = { name = 'Sergeant', level = 3 }, onduty = true },
            money = { cash = 1250.7, bank = 98000 },
            metadata = { isdead = false },
        },
    }
end

local function install()
    Config = nil
    PfmPause = nil
    load_resource('[qb]/pfm-pause/config.lua')

    function GetGameTimer() return S.t end
    function GetResourceState(r) return S.resources[r] or 'missing' end
    exports = setmetatable({}, {
        __call = function(_, name, fn) S.myExports = S.myExports or {}; S.myExports[name] = fn end,
        __index = function(_, res)
            local list = S.exportsOf[res] or {}
            return setmetatable({}, { __index = function(_, fn)
                return function(_, ...)
                    if not list[fn] then error('no export ' .. res .. '.' .. fn) end
                    return list[fn](...)
                end
            end })
        end,
    })
    function RegisterNUICallback(name, fn) S.callbacks[name] = fn end
    function RegisterNetEvent(name, fn) if fn then S.netHandlers[name] = fn end end
    function AddEventHandler(name, fn) S.handlers[name] = fn end
    function CreateThread(fn) S.threads[#S.threads + 1] = fn end
    function SetTimeout(ms, fn) S.timeouts[#S.timeouts + 1] = fn end
    function Wait() end
    function SendNUIMessage(m) S.nui[#S.nui + 1] = m end
    function SetNuiFocus(a, b) S.focus = { has = a, cursor = b } end
    function SetNuiFocusKeepInput(on) S.keepInput = on end
    function TriggerScreenblurFadeIn() S.blurIn = S.blurIn + 1 end
    function TriggerScreenblurFadeOut() S.blurOut = S.blurOut + 1 end
    function DisableControlAction(_, c) S.disabled[c] = (S.disabled[c] or 0) + 1 end
    function DisableAllControlActions() S.disableAll = S.disableAll + 1 end
    function IsDisabledControlJustPressed(_, c) return S.justPressed[c] == true end
    function IsDisabledControlPressed(_, c) return S.pressed[c] == true end
    function GetDisabledControlNormal() return 0.0 end
    function IsPauseMenuActive() return S.pauseActive end
    function IsNuiFocused() return S.nuiFocused or S.focus.has end
    function IsScreenFadedOut() return false end
    function IsUsingKeyboard() return S.usingKeyboard end
    function HideHudAndRadarThisFrame() end
    function ActivateFrontendMenu(hash) S.frontends[#S.frontends + 1] = hash end
    function PauseMenuceptionGoDeeper() S.goDeeper = true end
    function GetHashKey(s) return 'hash:' .. s end
    function ExecuteCommand(c) S.commands[#S.commands + 1] = c end
    function TriggerServerEvent(name, ...) S.server[#S.server + 1] = { name = name, args = { ... } } end
    function TriggerEvent(name, ...) S.events[#S.events + 1] = name end
    function PlayerId() return 0 end
    function GetPlayerServerId() return 7 end
    function GetPlayerName() return 'jane' end
    function GetClockHours() return 9 end
    function GetClockMinutes() return 5 end
    function GetCurrentResourceName() return 'pfm-pause' end
    function GetInvokingResource() return S.invoker end
    -- the map's natives: blips are numbered handles; sprite 8 is the waypoint
    local iter = {}
    local handles = {}
    local function handle(sprite, i)
        local h = sprite * 1000 + i
        handles[h] = { sprite = sprite, i = i }
        return h
    end
    function GetFirstBlipInfoId(sprite)
        iter[sprite] = 1
        if sprite == 8 then return S.waypoint and handle(8, 1) or 0 end
        local list = S.blips[sprite]
        return list and list[1] and handle(sprite, 1) or 0
    end
    function GetNextBlipInfoId(sprite)
        iter[sprite] = (iter[sprite] or 1) + 1
        local list = S.blips[sprite]
        return list and list[iter[sprite]] and handle(sprite, iter[sprite]) or 0
    end
    function DoesBlipExist(h) return h ~= 0 and handles[h] ~= nil end
    local function blipOf(h)
        local r = handles[h]
        if r.sprite == 8 then return { x = S.waypoint.x, y = S.waypoint.y, display = 2, alpha = 255, hud = 142 } end
        return S.blips[r.sprite][r.i]
    end
    function GetBlipInfoIdDisplay(h) return blipOf(h).display or 2 end
    function GetBlipAlpha(h) return blipOf(h).alpha or 255 end
    function GetBlipInfoIdCoord(h) local b = blipOf(h) return { x = b.x, y = b.y, z = 0.0 } end
    function GetBlipHudColour(h) return blipOf(h).hud or 0 end
    function GetHudColour(hud) if hud == 142 then return 164, 76, 242, 255 end return 255, 255, 255, 255 end
    function GetPosAlongGpsTypeRoute() return false end
    function PlayerPedId() return 1 end
    function GetEntityCoords() return { x = 100.5, y = -200.25, z = 30.0 } end
    function GetEntityHeading() return 90.0 end
    function GetStreetNameAtCoord() return 77 end
    function GetStreetNameFromHashKey() return 'Strawberry Ave' end
    function GetNameOfZone() return 'STRAW' end
    function GetLabelText() return 'Strawberry' end
    function SetNewWaypoint(x, y) S.waypointSet = { x = x, y = y } end
    function SetWaypointOff() S.waypointOff = S.waypointOff + 1 end
    LocalPlayer = { state = setmetatable({}, { __index = function(_, k) if k == 'isLoggedIn' then return S.loggedIn end end }) }

    S.resources['pfm-core'] = 'started'
    S.exportsOf['pfm-core'] = {
        GetCoreObject = function()
            return { Functions = { GetPlayerData = function() return S.playerData end } }
        end,
    }
    load_resource(CLIENT)
end

--- One frame: the presses given are "just pressed" for it only.
local function frame(presses, ms)
    S.t = S.t + (ms or 16)
    S.disabled, S.disableAll = {}, 0
    S.justPressed = {}
    for _, c in ipairs(presses or {}) do S.justPressed[c] = true end
    PfmPause.frame()
    S.justPressed = {}
end

local function idle(ms)    -- time passes with nothing pressed
    frame(nil, ms or 1000)
end

local function nuiCall(name, data)
    local out
    S.callbacks[name](data or {}, function(r) out = r end)
    return out
end

local function lastNui(action)
    for i = #S.nui, 1, -1 do if S.nui[i].action == action then return S.nui[i] end end
    return nil
end

local function countNui(action)
    local n = 0
    for _, m in ipairs(S.nui) do if m.action == action then n = n + 1 end end
    return n
end

local function serverSent(name)
    for _, e in ipairs(S.server) do if e.name == name then return true end end
    return false
end

BeforeEach = function()
    reset()
    install()
    idle(2000)   -- past any start-up cooldown
end

-- ---------------------------------------------------------------------------------------------

describe('pause keys', function()
    it('holds 199 and 200 off every frame while the menu is closed', function()
        frame()
        assert_eq(S.disabled[199], 1, '199 disabled')
        assert_eq(S.disabled[200], 1, '200 disabled')
        frame()
        assert_eq(S.disabled[199], 1, '199 again next frame')
        assert_false(PfmPause.isOpen())
    end)

    it('keeps holding them off while the menu is open', function()
        frame({ 200 })
        assert_true(PfmPause.isOpen(), 'opened on Escape')
        frame()
        assert_eq(S.disabled[199], 1)
        assert_eq(S.disabled[200], 1)
    end)

    it('leaves them alone while GTA\'s own frontend is up (its Escape closes it)', function()
        S.pauseActive = true
        frame()
        assert_eq(S.disabled[199], nil)
        assert_eq(S.disabled[200], nil)
    end)

    it('does not take over before the character is loaded', function()
        S.loggedIn = false
        frame({ 200 })
        assert_eq(S.disabled[200], nil, 'GTA keeps its keys at character select')
        assert_false(PfmPause.isOpen())
    end)

    it('opens on P / Start as well as Escape', function()
        frame({ 199 })
        assert_true(PfmPause.isOpen())
    end)
end)

describe('opening only when no other page has focus', function()
    it('opens with focus, cursor, blur and the character card', function()
        frame({ 200 })
        assert_true(PfmPause.isOpen())
        assert_true(S.focus.has, 'NUI focus')
        assert_true(S.focus.cursor, 'cursor')
        assert_false(S.keepInput, 'game input not kept for a keyboard player')
        assert_eq(S.blurIn, 1, 'blur faded in')
        local m = lastNui('pauseOpen')
        assert_true(m ~= nil, 'open message')
        assert_eq(m.brand, 'PF')
        assert_eq(m.character.name, 'Jane Doe')
        assert_eq(m.character.job, 'Police · Sergeant')
        assert_eq(m.menu[1].id, 'resume')
        local ids = {}
        for _, it in ipairs(m.menu) do ids[#ids + 1] = it.id end
        assert_eq(table.concat(ids, ','), 'resume,map,controller,swap,gameSettings,serverSettings,help,quit')
        assert_eq(m.quitMode, 'disconnect')
        assert_true(#m.help.rules > 0, 'rules for Help')
        assert_true(lastNui('pauseData') ~= nil, 'the map gets its data at once')
    end)

    it('does not open while another page (inventory, phone) has NUI focus', function()
        S.nuiFocused = true
        frame({ 200 })
        assert_false(PfmPause.isOpen())
        assert_eq(S.blurIn, 0)
        assert_eq(PfmPause.whyNot(), 'nui focus')
    end)

    it('does not open on the Escape that just closed another page', function()
        S.nuiFocused = true
        frame()
        S.nuiFocused = false          -- the inventory closed on Escape keydown
        frame({ 200 }, 16)            -- the same Escape reaches the game a frame later
        assert_false(PfmPause.isOpen(), 'cooldown after the other page let go')
        idle(500)
        frame({ 200 })
        assert_true(PfmPause.isOpen(), 'a fresh Escape opens it')
    end)

    it('does not open while a page shown without focus says it is up (tablet export)', function()
        S.resources['pf-tablet'] = 'started'
        S.exportsOf['pf-tablet'] = { IsTabletOpen = function() return true end }
        frame({ 200 })
        assert_false(PfmPause.isOpen())
        assert_eq(PfmPause.whyNot(), 'page open: pf-tablet')
        S.exportsOf['pf-tablet'].IsTabletOpen = function() return false end
        frame({ 200 })
        assert_true(PfmPause.isOpen())
    end)

    it('a stopped resource\'s blocking export is not asked', function()
        S.exportsOf['pf-tablet'] = { IsTabletOpen = function() error('should not be called') end }
        frame({ 200 })
        assert_true(PfmPause.isOpen())
    end)

    it('respects AllowWhileDead = false', function()
        Config.Pause.AllowWhileDead = false
        S.playerData.metadata.isdead = true
        frame({ 200 })
        assert_false(PfmPause.isOpen())
        assert_eq(PfmPause.whyNot(), 'dead')
    end)

    it('opens while dead by default (the death screen does not use Escape)', function()
        S.playerData.metadata.isdead = true
        frame({ 200 })
        assert_true(PfmPause.isOpen())
    end)
end)

describe('closing restores everything', function()
    it('the page\'s close gives back focus, kept input and the blur', function()
        frame({ 200 })
        S.usingKeyboard = false       -- a pad: input is kept so its buttons reach the game
        frame()
        assert_true(S.keepInput, 'kept input while a pad drives the menu')
        assert_true(S.disableAll > 0, 'the player\'s own controls are held off')
        nuiCall('close')
        assert_false(PfmPause.isOpen())
        assert_false(S.focus.has, 'NUI focus released')
        assert_false(S.focus.cursor, 'cursor released')
        assert_false(S.keepInput, 'kept input released')
        assert_eq(S.blurOut, 1, 'blur faded out')
        assert_true(lastNui('pauseClose') ~= nil, 'page told to hide')
    end)

    it('Start on a pad closes it, after the grace for the press that opened it', function()
        S.usingKeyboard = false
        frame({ 199 })
        assert_true(PfmPause.isOpen())
        frame({ 199 }, 16)
        assert_true(PfmPause.isOpen(), 'the opening press is not a close')
        frame({ 199 }, 400)
        assert_false(PfmPause.isOpen(), 'Start closes')
        assert_false(S.focus.has)
    end)

    it('the key that closed it does not reopen it on the next frame', function()
        frame({ 200 })
        nuiCall('close')
        frame({ 200 }, 16)
        assert_false(PfmPause.isOpen())
    end)

    it('closes when the character logs out', function()
        frame({ 200 })
        S.netHandlers['QBCore:Client:OnPlayerUnload']()
        assert_false(PfmPause.isOpen())
        assert_false(S.focus.has)
    end)
end)

describe('leaving asks first', function()
    it('Disconnect asks to confirm and sends nothing until confirmed', function()
        frame({ 200 })
        local r = nuiCall('leave', { mode = 'disconnect' })
        assert_true(r.ok)
        local q = lastNui('confirm')
        assert_true(q ~= nil, 'the page is asked to confirm')
        assert_eq(q.mode, 'disconnect')
        assert_false(serverSent('pfm-pause:server:leave'), 'not left yet')
        assert_eq(r.token, q.token, 'the answer carries the token')
        local c = nuiCall('leaveConfirm', { token = q.token })
        assert_true(c.ok)
        assert_true(serverSent('pfm-pause:server:leave'), 'left after confirming')
    end)

    it('a confirm without the token (or a wrong one) does nothing', function()
        frame({ 200 })
        assert_false(nuiCall('leaveConfirm', { token = 'x' }).ok, 'nothing was asked')
        nuiCall('leave', { mode = 'disconnect' })
        assert_false(nuiCall('leaveConfirm', { token = 'wrong' }).ok)
        assert_false(serverSent('pfm-pause:server:leave'))
        -- the wrong answer used up the question
        assert_false(nuiCall('leaveConfirm', { token = lastNui('confirm').token }).ok)
        assert_false(serverSent('pfm-pause:server:leave'))
    end)

    it('cancel forgets the question', function()
        frame({ 200 })
        nuiCall('leave', { mode = 'disconnect' })
        local token = lastNui('confirm').token
        nuiCall('leaveCancel')
        assert_false(nuiCall('leaveConfirm', { token = token }).ok)
        assert_false(serverSent('pfm-pause:server:leave'))
    end)

    it('Quit closes the menu and runs quit once confirmed', function()
        frame({ 200 })
        nuiCall('leave', { mode = 'quit' })
        assert_eq(#S.commands, 0)
        nuiCall('leaveConfirm', { token = lastNui('confirm').token })
        assert_eq(S.commands[1], 'quit')
        assert_false(PfmPause.isOpen())
    end)

    it('the server drops the player with the configured reason', function()
        local dropped = {}
        function DropPlayer(src, reason) dropped[#dropped + 1] = { src = src, reason = reason } end
        function GetPlayers() return { '1', '2', '3' } end
        function GetConvarInt(_, d) return 64 end
        local sent = {}
        function TriggerClientEvent(name, target, data) sent[#sent + 1] = { name = name, target = target, data = data } end
        local handlers = {}
        function RegisterNetEvent(name, fn) handlers[name] = fn end
        function AddEventHandler() end
        load_resource(SERVER)
        source = 5
        handlers['pfm-pause:server:leave']()
        assert_eq(#dropped, 1)
        assert_eq(dropped[1].src, 5)
        assert_eq(dropped[1].reason, Config.Pause.DisconnectReason)
        handlers['pfm-pause:server:info']()
        assert_eq(sent[1].name, 'pfm-pause:client:info')
        assert_eq(sent[1].data.online, 3)
        assert_eq(sent[1].data.max, 64)
        handlers['pfm-pause:server:info']()
        assert_eq(#sent, 1, 'one answer a second per player')
    end)
end)

describe('controller while open', function()
    it('sends D-pad, A, B and LB/RB to the page, with held directions repeating', function()
        S.usingKeyboard = false
        frame({ 199 })
        idle(400)
        assert_true(lastNui('device').pad, 'page told a pad is the device')
        frame({ 205 })
        assert_eq(lastNui('pad').intent, 'tabPrev')
        frame({ 206 })
        assert_eq(lastNui('pad').intent, 'tabNext')
        frame({ 201 })
        assert_eq(lastNui('pad').intent, 'select')
        frame({ 202 })
        assert_eq(lastNui('pad').intent, 'back')
        S.pressed[187] = true
        frame()
        assert_eq(lastNui('pad').intent, 'down')
        local n = countNui('pad')
        frame(nil, 100)
        assert_eq(countNui('pad'), n, 'no repeat before the delay')
        frame(nil, 400)
        assert_eq(countNui('pad'), n + 1, 'repeats once held')
        assert_true(lastNui('pad')['repeat'])
        S.pressed[187] = nil
    end)

    it('a keyboard player gets no pad intents and no kept input', function()
        frame({ 200 })
        idle(400)
        frame({ 201 })
        assert_eq(countNui('pad'), 0)
        assert_false(S.keepInput)
    end)
end)

describe('GTA frontend for game settings', function()
    it('closes the menu, opens GTA\'s settings and comes back', function()
        frame({ 200 })
        nuiCall('pauseSettings')
        assert_false(PfmPause.isOpen(), 'our menu steps aside')
        assert_false(S.focus.has)
        local opener = S.threads[#S.threads]
        opener()
        assert_eq(S.frontends[1], 'hash:FE_MENU_VERSION_LANDING_MENU')
        S.pauseActive = true
        frame()
        assert_eq(S.disabled[200], nil, 'Escape belongs to GTA\'s settings')
        S.pauseActive = false           -- the player closed it
        frame()
        assert_true(PfmPause.isOpen(), 'back in our menu')
    end)

    it('key bindings use their own frontend menu', function()
        frame({ 200 })
        nuiCall('pauseKeyBindings')
        S.threads[#S.threads]()
        assert_eq(S.frontends[1], 'hash:FE_MENU_VERSION_LANDING_KEYMAPPING_MENU')
    end)
end)

describe('the map\'s data', function()
    it('shapes blips for the page: position, sprite, colour; hidden, radar-only and NaN ones left out', function()
        local nan = 0 / 0
        S.blips[52] = {
            { x = 25.71, y = -1347.33, hud = 0 },
            { x = 1.0, y = 2.0, display = 0 },            -- hidden
            { x = 3.0, y = 4.0, display = 5 },            -- radar only
            { x = 5.0, y = 6.0, alpha = 0 },              -- invisible
            { x = nan, y = 1.0 },                         -- GTA could not place it
        }
        S.blips[6] = { { x = 0.0, y = 0.0 } }            -- the player's own arrow: the page draws it
        S.blips[361] = { { x = -70.0, y = -1760.0, hud = 142 } }
        local list = PfmPause.readBlips()
        assert_eq(#list, 2)
        assert_eq(list[1].sprite, 52)
        assert_eq(list[1].x, 25.7)
        assert_eq(list[1].y, -1347.3)
        assert_eq(list[1].colour, '#ffffff')
        assert_eq(list[2].sprite, 361)
        assert_eq(list[2].colour, '#a44cf2')
    end)

    it('sends the player, the waypoint (false when none) and, in a full message, the blips', function()
        S.blips[52] = { { x = 10.0, y = 20.0 } }
        local m = PfmPause.mapData(true)
        assert_eq(m.action, 'pauseData')
        assert_eq(m.player.x, 100.5)
        assert_eq(m.player.y, -200.25)
        assert_eq(m.player.heading, 90.0)
        assert_eq(m.player.zone, 'Strawberry')
        assert_eq(m.player.street, 'Strawberry Ave')
        assert_eq(m.waypoint, false, 'no waypoint is false, not nil')
        assert_eq(#m.blips, 1)
        assert_eq(m.route, false)
        assert_eq(m.routeColour, '#a44cf2')
        S.waypoint = { x = 300.0, y = 400.0 }
        local m2 = PfmPause.mapData(false)
        assert_eq(m2.waypoint.x, 300.0)
        assert_eq(m2.blips, nil, 'the quick message leaves the blips out')
    end)

    it('a message with a NaN player is sent without it, never with it', function()
        function GetEntityCoords() return { x = 0 / 0, y = 1.0, z = 0.0 } end
        local m = PfmPause.mapData(false)
        assert_eq(m.player, nil)
    end)

    it('sets and clears GTA\'s waypoint from the map, and refreshes the data after', function()
        frame({ 200 })
        local r = nuiCall('pauseWaypoint', { x = 215.5, y = -810.25 })
        assert_true(r.ok)
        assert_eq(S.waypointSet.x, 215.5)
        assert_eq(S.waypointSet.y, -810.25)
        assert_true(#S.timeouts >= 2, 'asks again once GTA planned the route')
        local before = countNui('pauseData')
        S.timeouts[1]()
        assert_eq(countNui('pauseData'), before + 1)
        assert_true(nuiCall('pauseWaypoint', { clear = true }).ok)
        assert_eq(S.waypointOff, 1)
    end)

    it('refuses a waypoint that is not a place', function()
        frame({ 200 })
        assert_false(nuiCall('pauseWaypoint', { x = 'a', y = 1 }).ok)
        assert_false(nuiCall('pauseWaypoint', { x = 1 / 0, y = 1 }).ok)
        assert_false(nuiCall('pauseWaypoint', { x = 99999, y = 1 }).ok)
        assert_eq(S.waypointSet, nil)
    end)

    it('the stick goes to the map as numbers only while the page asks for them', function()
        S.usingKeyboard = false
        frame({ 199 })
        idle(400)
        function GetDisabledControlNormal(_, c) if c == 195 then return 1.0 end return 0.0 end
        frame()
        assert_eq(lastNui('pad').intent, 'right', 'a direction in the menu')
        nuiCall('navScope', { analog = true })
        frame(nil, 100)
        local a = lastNui('padAnalog')
        assert_true(a ~= nil and a.x == 1.0, 'numbers on the map')
        function GetDisabledControlNormal() return 0.0 end
        frame(nil, 100)
        assert_eq(lastNui('padAnalog').x, 0, 'let go is sent at once')
    end)
end)

describe('swap character', function()
    local function withMulticharacter()
        S.resources['pfm-multicharacter'] = 'started'
    end

    it('is shown off with a note when there is no character screen', function()
        frame({ 200 })
        local swap
        for _, it in ipairs(lastNui('pauseOpen').menu) do if it.id == 'swap' then swap = it end end
        assert_true(swap.disabled, 'off')
        assert_true(type(swap.note) == 'string' and #swap.note > 0)
        assert_false(nuiCall('leave', { mode = 'swap' }).ok)
    end)

    it('asks first, then closes the menu and asks the server, only with the token', function()
        withMulticharacter()
        frame({ 200 })
        local r = nuiCall('leave', { mode = 'swap' })
        assert_true(r.ok)
        assert_false(serverSent('pfm-pause:server:swap'), 'not before the confirm')
        assert_false(nuiCall('leaveConfirm', { token = 'nope' }).ok)
        r = nuiCall('leave', { mode = 'swap' })
        assert_true(nuiCall('leaveConfirm', { token = r.token }).ok)
        assert_true(serverSent('pfm-pause:server:swap'))
        assert_false(PfmPause.isOpen())
    end)

    it('not while down or cuffed', function()
        withMulticharacter()
        frame({ 200 })
        S.playerData.metadata.isdead = true
        local r = nuiCall('leave', { mode = 'swap' })
        assert_false(r.ok)
        assert_true(type(r.why) == 'string')
        S.playerData.metadata.isdead = false
        S.playerData.metadata.ishandcuffed = true
        assert_false(nuiCall('leave', { mode = 'swap' }).ok)
    end)

    it('the server logs out through the core and opens the character screen, with a cooldown', function()
        local loggedOut, toClient = {}, {}
        local handlers = {}
        function RegisterNetEvent(name, fn) handlers[name] = fn end
        function AddEventHandler() end
        function TriggerClientEvent(name, target, data) toClient[#toClient + 1] = { name = name, target = target, data = data } end
        S.resources['pfm-multicharacter'] = 'started'
        local md = {}
        S.exportsOf['pfm-core'] = {
            GetCoreObject = function()
                return {
                    Functions = { GetPlayer = function(src) return { PlayerData = { metadata = md } } end },
                    Player = { Logout = function(src) loggedOut[#loggedOut + 1] = src end },
                }
            end,
        }
        load_resource(SERVER)
        source = 9
        handlers['pfm-pause:server:swap']()
        assert_eq(loggedOut[1], 9)
        assert_eq(toClient[#toClient].name, 'qb-multicharacter:client:chooseChar')
        handlers['pfm-pause:server:swap']()
        assert_eq(#loggedOut, 1, 'cooldown')
        assert_eq(toClient[#toClient].name, 'pfm-pause:client:swapRefused')
        source = 10
        md.isdead = true
        handlers['pfm-pause:server:swap']()
        assert_eq(#loggedOut, 1, 'not while down')
    end)
end)

describe('settings from pfm-ui', function()
    it('without pfm-ui the page gets a short note', function()
        frame({ 200 })
        local r = nuiCall('getPrefs')
        assert_false(r.available)
        assert_true(type(r.note) == 'string' and #r.note > 0)
    end)

    it('with pfm-ui it lists every registered setting and changes them through SetPref', function()
        local values = { ['pad.enabled'] = true }
        S.resources['pfm-ui'] = 'started'
        S.exportsOf['pfm-ui'] = {
            IsPadActiveNow = function() return false end,
            GetPref = function(k) return values[k] end,
            SetPref = function(k, v) if k == 'locked' then return false, 'set by the server' end values[k] = v return true end,
            GetPrefs = function() return { { key = 'pad.enabled', type = 'toggle', label = 'Controller', group = 'Controller', value = values['pad.enabled'] } } end,
            GetLayout = function() return { dpad_up = 'phone', lb = 'target' } end,
        }
        frame({ 200 })
        local r = nuiCall('getPrefs')
        assert_true(r.available)
        assert_eq(r.prefs[1].key, 'pad.enabled')
        assert_eq(r.layout.dpad_up, 'phone')
        local s = nuiCall('setPref', { key = 'pad.enabled', value = false })
        assert_true(s.ok)
        assert_eq(s.value, false)
        local bad = nuiCall('setPref', { key = 'locked', value = 1 })
        assert_false(bad.ok)
        assert_eq(bad.why, 'set by the server')
    end)

    it('the Settings page gets the prefs grouped, locked and changed marked, and changes go through pfm-ui', function()
        local values = { ['pad.enabled'] = false, ['hud.style'] = 'round' }
        local resets = {}
        S.resources['pfm-ui'] = 'started'
        S.exportsOf['pfm-ui'] = {
            IsPadActiveNow = function() return false end,
            GetPref = function(k) return values[k] end,
            SetPref = function(k, v) values[k] = v return true end,
            ResetPref = function(k) resets[#resets + 1] = k values[k] = (k == 'pad.enabled') and true or 'round' return true end,
            GetPrefs = function()
                return {
                    { key = 'pad.enabled', type = 'toggle', label = 'Controller', group = 'Controller', value = values['pad.enabled'], default = true },
                    { key = 'hud.style', type = 'choice', label = 'HUD', group = 'HUD', value = values['hud.style'], default = 'round',
                      options = { { value = 'round', label = 'Round' }, { value = 'square', label = 'Square' } } },
                    { key = 'hud.locked', type = 'toggle', label = 'Locked', group = 'HUD', value = true, default = false, forced = true },
                }
            end,
            GetLayout = function() return {} end,
        }
        frame({ 200 })
        local st = nuiCall('prefsState')
        assert_eq(#st.groups, 2)
        assert_eq(st.groups[1].id, 'Controller')
        assert_true(st.groups[1].rows[1].changed, 'off is the player\'s own choice')
        assert_true(st.groups[2].rows[2].locked, 'forced is locked')
        assert_false(st.groups[2].rows[2].changed)
        st = nuiCall('prefsSet', { key = 'hud.style', value = 'square' })
        assert_eq(values['hud.style'], 'square')
        assert_true(st.groups[2].rows[1].changed)
        nuiCall('prefsSet', { key = 'pad.enabled', value = true })
        assert_eq(resets[1], 'pad.enabled', 'set to the default clears the choice')
        nuiCall('prefsReset', { group = 'HUD' })
        assert_eq(resets[2], 'hud.style', 'only the tab\'s rows, not the forced one')
        assert_eq(#resets, 2)
    end)

    it('the Controller screen gets pfm-ui\'s layout and actions, and a change says the swap', function()
        local layout = { dpad_up = 'phone', dpad_down = 'radial', lb = 'target' }
        S.resources['pfm-ui'] = 'started'
        S.exportsOf['pfm-ui'] = {
            IsPadActiveNow = function() return false end,
            GetPref = function() return nil end,
            GetLayoutState = function()
                local l = {}
                for k, v in pairs(layout) do l[k] = v end
                l.lb_a = false
                return { layout = l, actions = { { id = 'phone', label = 'Phone' }, { id = 'radial', label = 'Radial menu' } }, custom = false }
            end,
            SetLayoutSlot = function(slot, action)
                if slot == 'nope' then return false, 'no such button' end
                local old = layout[slot]
                for k, v in pairs(layout) do if v == action then layout[k] = old end end
                layout[slot] = action or nil
                return true
            end,
            ResetLayout = function() layout = { dpad_up = 'phone' } return true end,
        }
        frame({ 200 })
        local st = nuiCall('padLayout')
        assert_eq(st.layout.dpad_up, 'phone')
        assert_eq(st.layout.lb_a, nil, 'empty buttons are left out')
        assert_eq(st.actions[1].id, 'phone')
        assert_true(st.actions[1].on)
        st = nuiCall('padLayoutSet', { slot = 'dpad_up', action = 'radial' })
        assert_eq(st.layout.dpad_up, 'radial')
        assert_eq(st.swap.slot, 'dpad_down')
        assert_eq(st.swap.gave, 'phone')
        st = nuiCall('padLayoutSet', { slot = 'nope', action = 'radial' })
        assert_eq(st.error, 'no such button')
        st = nuiCall('padLayoutReset')
        assert_eq(st.layout.dpad_down, nil)
    end)
end)

describe('quick actions and report', function()
    it('AddQuickAction adds a row; selecting it closes the menu and runs it', function()
        local ran = 0
        S.invoker = 'pf-garage'
        local ok = S.myExports.AddQuickAction({ id = 'garage', label = 'My garage', icon = 'car', onSelect = function() ran = ran + 1 end })
        assert_true(ok)
        local bad = S.myExports.AddQuickAction({ id = 'bad id!', label = 'x', command = 'x' })
        assert_false(bad)
        frame({ 200 })
        local found = false
        for _, q in ipairs(lastNui('pauseOpen').help.quick) do if q.id == 'garage' then found = true end end
        assert_true(found, 'listed on Help')
        nuiCall('quick', { id = 'garage' })
        assert_eq(ran, 1)
        assert_false(PfmPause.isOpen())
        -- it goes when its resource stops
        S.handlers['onResourceStop']('pf-garage')
        for _, q in ipairs(PfmPause.quickActions()) do assert_true(q.id ~= 'garage') end
    end)

    it('report goes through pfm-adminmenu\'s /report, one line, rate limited', function()
        S.resources['pfm-adminmenu'] = 'started'
        frame({ 200 })
        assert_true(lastNui('pauseOpen').help.report ~= false, 'the form is offered')
        local short = nuiCall('report', { message = 'hi' })
        assert_false(short.ok)
        local r = nuiCall('report', { message = 'Car stuck under the map; quit\nnear Legion' })
        assert_true(r.ok)
        assert_eq(S.commands[1], 'report Car stuck under the map quit near Legion')
        local again = nuiCall('report', { message = 'Another long problem here' })
        assert_false(again.ok, 'cooldown')
    end)

    it('no report button without pfm-adminmenu', function()
        frame({ 200 })
        assert_eq(lastNui('pauseOpen').help.report, false)
        assert_false(nuiCall('report', { message = 'a long enough message' }).ok)
    end)
end)
