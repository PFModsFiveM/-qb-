-- Stress with both HUDs started (pf-hud is the active HUD; pfm-hud also runs from [qb]): each stress
-- event must change stress once, and pfm-hud on its own must validate the amount.
load_resource('tests/lua/fivem_mocks.lua')
QBCore = QBCoreMock
local running = { ['pf-hud'] = 'started' }
function GetResourceState(name) return running[name] or 'missing' end

-- both resources read the global Config; their stress keys differ, so one merged table serves both
Config = nil
load_resource('pfm-hud/config.lua')
local pfmConfig = Config
load_resource('pfm-hud/server.lua')
Config = nil
load_resource('[pfscripts]/pf-hud/config.lua')
for k, v in pairs(pfmConfig) do if Config[k] == nil then Config[k] = v end end
load_resource('[pfscripts]/pf-hud/server.lua')

local P = 1
local function stress() return Mock.players[P].PlayerData.metadata.stress end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    running['pf-hud'] = 'started'
    local p = Mock.newPlayer(P)
    p.PlayerData.metadata.stress = 20
    p.PlayerData.job = { name = 'unemployed', type = 'none' }
end

describe('stress with both HUDs running', function()
    it('a gain is applied once', function()
        Mock.fireNetAll('hud:server:GainStress', P, 5)
        assert_eq(stress(), 25)
    end)
    it('a relief is applied once', function()
        Mock.fireNetAll('hud:server:RelieveStress', P, 5)
        assert_eq(stress(), 15)
    end)
end)

-- pfm-hud was loaded first, so its handler is the first in the list
local function pfmOnly(name, amount)
    source = P
    Mock.netHandlerList[name][1](amount)
    source = nil
end

describe('pfm-hud on its own', function()
    it('applies stress and limits a gain to 10', function()
        running['pf-hud'] = 'missing'
        pfmOnly('hud:server:GainStress', 500)
        assert_eq(stress(), 30)
    end)
    it('a negative or missing gain does nothing (it used to clear stress or error)', function()
        running['pf-hud'] = 'missing'
        pfmOnly('hud:server:GainStress', -1000)
        pfmOnly('hud:server:GainStress', nil)
        assert_eq(stress(), 20)
    end)
end)
