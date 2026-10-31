-- Stress on pf-hud (the only HUD; pfm-hud was removed): a gain or relief changes stress once, a gain
-- is limited to 10, and negative or missing amounts do nothing.
load_resource('tests/lua/fivem_mocks.lua')
QBCore = QBCoreMock
function GetResourceState() return 'started' end
Config = nil
load_resource('[pfscripts]/pf-hud/config.lua')
Config.StressEnabled = true
load_resource('[pfscripts]/pf-hud/server.lua')

local P = 1
local function stress() return Mock.players[P].PlayerData.metadata.stress end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    local p = Mock.newPlayer(P)
    p.PlayerData.metadata.stress = 20
    p.PlayerData.job = { name = 'unemployed', type = 'none' }
end

describe('stress on pf-hud', function()
    it('a gain is applied once', function()
        Mock.fireNetAll('hud:server:GainStress', P, 5)
        assert_eq(stress(), 25)
    end)
    it('a relief is applied once', function()
        Mock.fireNetAll('hud:server:RelieveStress', P, 5)
        assert_eq(stress(), 15)
    end)
    it('limits a gain to 10', function()
        Mock.fireNetAll('hud:server:GainStress', P, 500)
        assert_eq(stress(), 30)
    end)
    it('a negative or missing gain does nothing', function()
        Mock.fireNetAll('hud:server:GainStress', P, -1000)
        Mock.fireNetAll('hud:server:GainStress', P, nil)
        assert_eq(stress(), 20)
    end)
end)
