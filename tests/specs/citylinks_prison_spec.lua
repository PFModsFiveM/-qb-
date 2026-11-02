-- pfm-prison → pf-services: a confirmed escape (through a hacked gate, seen by the server leaving the
-- walls) is one 'crime.prison.escape' event with the inmate's public name, at the server's position
-- of the inmate. Counting down, a release or a noclip out raises nothing.
load_resource('tests/lua/ledger_env.lua')
Emits = {}
Mock.exportsByResource['pf-services'] = {
    Emit = function(_, kind, data, opts) Emits[#Emits + 1] = { kind = kind, data = data, opts = opts or {} } return #Emits end,
}
Mock.exportsByResource['pfm-inventory'] = {
    ClearInventory = function(_, src) Mock.players[src].PlayerData.items = {} end,
    AddItem = function() return true end, RemoveItem = function() return true end, HasItem = function() return true end,
}
Mock.exportsByResource['pfm-minigames'] = {
    IssueChallenge = function() return { id = 'c1', kind = 'hacking', puzzle = {} } end,
    Verify = function() return true end, Cancel = function() end,
}
function vec2(x, y) return vector2(x, y) end
LedgerEnv.load('pfm-prison', { 'pfm-prison/config.lua', 'pfm-prison/server/main.lua' })

local INMATE = 1
local middle = function() return Config.Locations['middle'] end
local GATE = Config.Gates[1].coords
local function beyondGate(metres)
    local m = middle()
    local dx, dy = GATE.x - m.x, GATE.y - m.y
    local len = math.sqrt(dx * dx + dy * dy)
    return vector3(GATE.x + dx / len * metres, GATE.y + dy / len * metres, GATE.z)
end
local function sampleAt(pos)
    Mock.coords[INMATE] = pos
    Mock.clock = Mock.clock + 2
    PFPrison.SampleTick()
end

BeforeEach = function()
    PFPrison.EndAlarm()
    if Mock.players[INMATE] then Mock.fireEvent('playerDropped', INMATE) end
    Mock.reset()
    LedgerEnv.reset()
    Mock.clock = Mock.clock + 5000
    Mock.players, Mock.coords, Emits = {}, {}, {}
    local p = Mock.newPlayer(INMATE, 'INMATECID')
    p.PlayerData.charinfo = { firstname = 'John', lastname = 'Escape' }
    p.PlayerData.metadata.injail = 0
    p.PlayerData.job = { name = 'unemployed' }
    local m = middle()
    Mock.coords[INMATE] = vector3(m.x + 10, m.y, m.z)
    Mock.invokingResource = 'pfm-policejob'
    Mock.selfExport('JailPlayer')(INMATE, 30)
    Mock.invokingResource = nil
    Mock.clock = Mock.clock + 60
end

describe('prison escape event', function()
    it('counting down, a release or a noclip over the wall raises nothing', function()
        local m = middle()
        PFPrison.MinuteTick()
        assert_eq(Mock.players[INMATE].PlayerData.metadata.injail, 29)
        sampleAt(vector3(m.x + 10, m.y, m.z))
        sampleAt(vector3(m.x + 900, m.y, m.z))
        assert_eq(#Emits, 0)
        Mock.invokingResource = 'pfm-policejob'
        Mock.selfExport('ReleasePlayer')(INMATE, 'unjail')
        Mock.invokingResource = nil
        assert_eq(#Emits, 0)
    end)
    it('a real escape is one event with public facts at the inmate\'s position', function()
        Mock.coords[INMATE] = GATE
        Mock.fireNet('prison:server:StartGateHack', INMATE, 1)
        local start = Mock.clientEventsNamed('prison:client:GateHackStart')[1]
        Mock.clock = Mock.clock + 10
        Mock.fireNet('prison:server:GateHackResult', INMATE, start.args[2], true)
        sampleAt(GATE)
        sampleAt(beyondGate(20))
        local out = beyondGate(60)
        sampleAt(out)
        assert_eq(#Emits, 1)
        local e = Emits[1]
        assert_eq(e.kind, 'crime.prison.escape')
        assert_eq(e.data.name, 'John Escape')
        assert_eq(e.data.citizenid, nil)
        assert_near(e.opts.coords.x, out.x, 0.01)
        assert_eq(e.opts.dedupe, 'INMATECID')
        sampleAt(beyondGate(90))                                   -- already out: nothing more
        assert_eq(#Emits, 1)
    end)
end)
