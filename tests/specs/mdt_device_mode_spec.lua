-- The police and EMS MDTs inside the tablet and the computer: the device app is the MDT's own page
-- (registered as a pf-devices iframe app); while it is open the MDT's messages go to the device
-- window, overlays still reach the full-screen frame, focus is left to the device, and closing the
-- MDT closes only the app window.
load_resource('tests/lua/fivem_mocks.lua')

local function setup(resourceName, deviceModePath, devicesPath, configPath)
    local sent, focus, appEvents, closed, callbacks = {}, {}, {}, {}, {}
    _G.SendNUIMessage = function(p) sent[#sent + 1] = p end
    _G.SetNuiFocus = function(a, b) focus[#focus + 1] = { a, b } end
    _G.RegisterNUICallback = function(name, fn) callbacks[name] = fn end
    function GetResourceState(name) return (name == 'pf-devices') and 'started' or 'missing' end
    function GetCurrentResourceName() return resourceName end
    local registered = {}
    Mock.exportsByResource['pf-devices'] = {
        AppEvent = function(_, app, event, payload) appEvents[#appEvents + 1] = { app = app, event = event, payload = payload } end,
        CloseApp = function(_, app) closed[#closed + 1] = app end,
        RegisterApp = function(_, def) registered[#registered + 1] = def return true end,
    }
    PFMdtOpen, PFMdtDeviceClosed, PFMdtDevice = nil, nil, nil
    load_resource(deviceModePath)
    Config = nil
    load_resource(configPath)
    load_resource(devicesPath)
    Mock.eventHandlers['pf-devices:server:ready']()
    return { sent = sent, focus = focus, appEvents = appEvents, closed = closed, callbacks = callbacks, registered = registered }
end

for _, mdt in ipairs({
    { res = 'pf-policemdt-DEV', dir = '[pfscripts]/pf-policemdt-DEV', app = 'policemdt', job = 'police' },
    { res = 'pf-emsmdt', dir = '[pfscripts]/pf-emsmdt', app = 'emsmdt', job = 'ambulance' },
}) do
    describe(mdt.res .. ' as a device app', function()
        it('registers its own page as an iframe app for its jobs on both devices', function()
            local t = setup(mdt.res, mdt.dir .. '/client/device_mode.lua', mdt.dir .. '/server/devices.lua', mdt.dir .. '/config.lua')
            local def = t.registered[1]
            assert_eq(def.id, mdt.app)
            assert_eq(def.kind, 'iframe')
            assert_eq(def.url, ('https://cfx-nui-%s/html/index.html?embed=1&device={device}'):format(mdt.res))
            assert_eq(def.access.jobs[mdt.job], 0)
            assert_eq(table.concat(def.devices, ','), 'tablet,computer')
        end)

        it('in device mode messages go to the window, overlays also to the full screen, focus is untouched', function()
            local t = setup(mdt.res, mdt.dir .. '/client/device_mode.lua', mdt.dir .. '/server/devices.lua', mdt.dir .. '/config.lua')
            local opened
            PFMdtOpen = function(how) opened = how; SendNUIMessage({ action = 'open' }); SetNuiFocus(true, true) end
            SendNUIMessage({ action = 'setCalls' })
            assert_eq(#t.sent, 1, 'outside device mode: the full-screen frame')
            local reply
            t.callbacks.pfDeviceOpen({}, function(r) reply = r end)
            assert_true(reply.ok)
            assert_eq(opened, 'device')
            assert_eq(#t.sent, 1, 'the open message did not reach the full-screen frame')
            assert_eq(t.appEvents[1].app, mdt.app)
            assert_eq(t.appEvents[1].event, 'nui')
            assert_eq(t.appEvents[1].payload.action, 'open')
            assert_eq(#t.focus, 0, 'the device keeps focus')
            SendNUIMessage({ action = 'updateDispatchOverlay', calls = {} })
            assert_eq(t.sent[#t.sent].action, 'updateDispatchOverlay', 'overlays still show over the game')
            assert_eq(t.appEvents[#t.appEvents].payload.action, 'updateDispatchOverlay')
        end)

        it('closing the MDT closes the app window, and putting the device away ends device mode', function()
            local t = setup(mdt.res, mdt.dir .. '/client/device_mode.lua', mdt.dir .. '/server/devices.lua', mdt.dir .. '/config.lua')
            local closedState = 0
            PFMdtOpen = function() end
            PFMdtDeviceClosed = function() closedState = closedState + 1 end
            t.callbacks.pfDeviceOpen({}, function() end)
            assert_true(PFMdtDeviceClose())
            assert_eq(t.closed[1], mdt.app)
            assert_eq(closedState, 1)
            assert_false(PFMdtDevice.active)
            SetNuiFocus(false, false)
            assert_eq(#t.focus, 1, 'outside device mode focus works again')
            t.callbacks.pfDeviceOpen({}, function() end)
            Mock.fireEvent('pf-devices:client:shellState', nil, 'tablet', false)
            assert_false(PFMdtDevice.active)
            assert_eq(closedState, 2)
        end)
    end)
end
