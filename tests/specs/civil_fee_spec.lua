-- pf-government civil services: the ID fee is paid through the ledger and refunded when the document
-- cannot be handed over.
load_resource('tests/lua/ledger_env.lua')
local resourceState = GetResourceState
GetResourceState = function(name) if name == 'pfm-cityhall' then return 'missing' end return resourceState(name) end
vec3 = vec3 or vector3
vec4 = vec4 or vector4 or function(x, y, z, w) return { x = x, y = y, z = z, w = w } end
QBCore = QBCoreMock
function NotifyPlayer() end
function DebugPrint() end

local inventoryFull = false
local issued = {}
Mock.exportsByResource['pfm-inventory'] = {
    AddItem = function(_, src, item) if inventoryFull then return false end issued[#issued + 1] = item return true end,
}

LedgerEnv.load('pf-government', { '[pfscripts]/pf-government/config.lua', '[pfscripts]/pf-government/server/civil.lua' })

local P = 1
local function cash() return Mock.players[P].PlayerData.money.cash end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players = {}
    issued, inventoryFull = {}, false
    Mock.newPlayer(P).PlayerData.money = { cash = 100, bank = 0 }
end

describe('city hall ID fee', function()
    it('is paid once for the document', function()
        Mock.fireNet('qb-cityhall:server:requestId', P, 'id_card', 1)
        assert_eq(cash(), 50)
        assert_eq(issued[1], 'id_card')
    end)
    it('is refunded when the document cannot be handed over', function()
        inventoryFull = true
        Mock.fireNet('qb-cityhall:server:requestId', P, 'id_card', 1)
        assert_eq(cash(), 100)
        assert_eq(#issued, 0)
    end)
    it('without the cash nothing is issued', function()
        Mock.players[P].PlayerData.money.cash = 10
        Mock.fireNet('qb-cityhall:server:requestId', P, 'id_card', 1)
        assert_eq(cash(), 10)
        assert_eq(#issued, 0)
    end)
end)
