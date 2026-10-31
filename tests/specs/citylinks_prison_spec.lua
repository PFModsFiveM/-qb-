-- pfm-prison → pf-services: a confirmed escape (sentence dropped to 0 far outside the walls) is one
-- 'crime.prison.escape' event with the inmate's public name, at the server's position of the inmate.
load_resource('tests/lua/ledger_env.lua')
Emits = {}
Mock.exportsByResource['pf-services'] = {
    Emit = function(_, kind, data, opts) Emits[#Emits + 1] = { kind = kind, data = data, opts = opts or {} } return #Emits end,
}
GetInvokingResource = function() return nil end
function vec2(x, y) return vector2(x, y) end
LedgerEnv.load('pfm-prison', { 'pfm-prison/config.lua', 'pfm-prison/server/main.lua' })

local INMATE = 1
local middle = function() return Config.Locations['middle'] end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.clock = Mock.clock + 1000
    Mock.players, Mock.coords, Emits = {}, {}, {}
    local p = Mock.newPlayer(INMATE, 'INMATECID')
    p.PlayerData.charinfo = { firstname = 'John', lastname = 'Escape' }
    p.PlayerData.metadata.injail = 30
    p.PlayerData.job = { name = 'unemployed' }
end

describe('prison escape event', function()
    it('counting down or a "release" inside the walls raises nothing', function()
        local m = middle()
        Mock.coords[INMATE] = vector3(m.x + 10, m.y, m.z)
        Mock.fireNet('prison:server:SetJailStatus', INMATE, 29)
        Mock.fireNet('prison:server:SetJailStatus', INMATE, 0)
        assert_eq(#Emits, 0)
        assert_eq(Mock.players[INMATE].PlayerData.metadata.injail, 29)
    end)
    it('a real escape is one event with public facts at the inmate\'s position', function()
        local m = middle()
        Mock.coords[INMATE] = vector3(m.x + 400, m.y, m.z)
        Mock.fireNet('prison:server:SetJailStatus', INMATE, 0)
        assert_eq(#Emits, 1)
        local e = Emits[1]
        assert_eq(e.kind, 'crime.prison.escape')
        assert_eq(e.data.name, 'John Escape')
        assert_eq(e.data.citizenid, nil)
        assert_near(e.opts.coords.x, m.x + 400, 0.01)
        assert_eq(e.opts.dedupe, 'INMATECID')
        Mock.fireNet('prison:server:SetJailStatus', INMATE, 0)              -- already out: nothing more
        assert_eq(#Emits, 1)
    end)
end)
