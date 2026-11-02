-- pfm-policejob alerts and the ankle tracker (batch 14: X-6, X-8).
--   * /ankletlocation reads the tracked player's position on the server; the tracked player's
--     client is not asked (police:server:SendTrackerLocation is gone), so no fake position or
--     fake anklet alerts to any officer;
--   * police:server:policeAlert is held to Config.AlertRate per player; the same text again within
--     the window is dropped; server scripts use the PoliceAlert export;
--   * "officer down" is built on the server for an on-duty officer who is really down.
load_resource('tests/lua/fivem_mocks.lua')
QBCore = QBCoreMock
Commands = {}
QBCoreMock.Commands.Add = function(name, _, _, _, fn) Commands[name] = fn end
QBCoreMock.Functions.GetPlayerByCitizenId = function(cid)
    for _, p in pairs(Mock.players) do if p.PlayerData.citizenid == cid then return p end end
end

Config = nil
load_resource('pfm-policejob/config.lua')
load_resource('pfm-policejob/server/main.lua')
load_resource('pfm-policejob/server/commands.lua')

local COP, TRACKED, CIV = 1, 2, 3
local function alertsTo(src)
    local n = 0
    for _, e in ipairs(Mock.clientEventsNamed('police:client:policeAlert')) do if e.target == src then n = n + 1 end end
    return n
end

BeforeEach = function()
    for _, src in ipairs({ COP, TRACKED, CIV }) do if Mock.players[src] then Mock.fireEvent('playerDropped', src) end end
    Mock.reset()
    Mock.players, Mock.coords = {}, {}
    Mock.clock = Mock.clock + 3600
    local cop = Mock.newPlayer(COP, 'COPCID')
    cop.PlayerData.job = { name = 'police', type = 'leo', onduty = true }
    cop.PlayerData.metadata.callsign = '1-ADAM-12'
    local t = Mock.newPlayer(TRACKED, 'TRACKEDCID')
    t.PlayerData.metadata.tracker = true
    Mock.newPlayer(CIV, 'CIVCID')
    Mock.coords[COP] = vector3(0, 0, 0)
    Mock.coords[TRACKED] = vector3(1234, -567, 30)
    Mock.coords[CIV] = vector3(50, 50, 30)
end

describe('ankle tracker (X-6)', function()
    it('the position is where the server sees the tracked player', function()
        Commands.ankletlocation(COP, { 'TRACKEDCID' })
        local msg = Mock.clientEventsNamed('police:client:TrackerMessage')
        assert_eq(#msg, 1)
        assert_eq(msg[1].target, COP)
        assert_near(msg[1].args[2].x, 1234, 0.01)
        assert_near(msg[1].args[2].y, -567, 0.01)
        assert_eq(#Mock.clientEventsNamed('police:client:SendTrackerLocation'), 0)
    end)
    it('the tracked client cannot send positions or alerts any more', function()
        assert_eq(Mock.netHandlers['police:server:SendTrackerLocation'], nil)
    end)
    it('bad arguments and someone without an anklet send nothing', function()
        Commands.ankletlocation(COP, { { 'x' } })
        Commands.ankletlocation(COP, {})
        Commands.ankletlocation(COP, { 'CIVCID' })
        assert_eq(#Mock.clientEventsNamed('police:client:TrackerMessage'), 0)
    end)
end)

describe('police alerts (X-8)', function()
    it('a player is held to the rate: a loop of fake alerts reaches officers twice per window', function()
        for i = 1, 20 do Mock.fireNet('police:server:policeAlert', CIV, 'Officer down ' .. i) end
        assert_eq(alertsTo(COP), Config.AlertRate.Max)
        Mock.clock = Mock.clock + Config.AlertRate.Window
        Mock.fireNet('police:server:policeAlert', CIV, 'Robbery in progress')
        assert_eq(alertsTo(COP), Config.AlertRate.Max + 1)
    end)
    it('the same text again within the window is dropped', function()
        Mock.fireNet('police:server:policeAlert', CIV, 'Suspicious Activity')
        Mock.fireNet('police:server:policeAlert', CIV, 'Suspicious Activity')
        assert_eq(alertsTo(COP), 1)
    end)
    it('is placed where the server sees the caller', function()
        Mock.fireNet('police:server:policeAlert', CIV, 'Drug sale in progress')
        local e = Mock.clientEventsNamed('police:client:policeAlert')[1]
        assert_near(e.args[1].x, 50, 0.01)
    end)
    it('server scripts use the export, at the position they give', function()
        for _ = 1, 5 do assert_true(Mock.selfExport('PoliceAlert')(vector3(7, 8, 9), 'Bank alarm')) end
        assert_eq(alertsTo(COP), 5)
        assert_false(Mock.selfExport('PoliceAlert')('nowhere', 'x'))
    end)
    it('officer down: only an on-duty officer who is down, with the text built here, once a minute', function()
        Mock.fireNet('police:server:OfficerDown', CIV)
        Mock.fireNet('police:server:OfficerDown', COP)                     -- standing
        assert_eq(alertsTo(COP), 0)
        Mock.players[COP].PlayerData.metadata.inlaststand = true
        Mock.fireNet('police:server:OfficerDown', COP)
        Mock.fireNet('police:server:OfficerDown', COP)
        assert_eq(alertsTo(COP), 1)
    end)
end)
