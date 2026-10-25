-- pfm-clothing: saves are size-checked and limited, and a player who is not loaded cannot crash it.
load_resource('tests/lua/fivem_mocks.lua')
local outfitCount = 0
MySQL.scalar = setmetatable({ await = function() return outfitCount end }, { __call = function() return outfitCount end })
load_resource('pfm-clothing/server/main.lua')

local P = 1
local function writes()
    local n = 0
    for _, c in ipairs(Mock.dbCalls) do if c.kind == 'insert' then n = n + 1 end end
    return n
end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    Mock.newPlayer(P)
    Mock.clock = Mock.clock + 100
    outfitCount = 0
end

describe('clothing saves', function()
    it('a huge skin is refused', function()
        Mock.fireNet('qb-clothing:saveSkin', P, 12345, string.rep('x', 100000))
        assert_eq(writes(), 0)
    end)
    it('a normal skin is saved, a burst of saves is not', function()
        Mock.fireNet('qb-clothing:saveSkin', P, 12345, '{"hat":1}')
        local first = writes()
        Mock.fireNet('qb-clothing:saveSkin', P, 12345, '{"hat":2}')
        assert_eq(first, 1)
        assert_eq(writes(), 1, 'second save within the cooldown dropped')
    end)
    it('outfits stop at the limit', function()
        outfitCount = 50
        Mock.fireNet('qb-clothes:saveOutfit', P, 'Gala', 12345, { hat = 1 })
        assert_eq(writes(), 0)
        Mock.clock = Mock.clock + 10
        outfitCount = 3
        Mock.fireNet('qb-clothes:saveOutfit', P, 'Gala', 12345, { hat = 1 })
        assert_eq(writes(), 1)
    end)
    it('a player that is not loaded does not crash the handlers', function()
        Mock.fireNet('qb-clothing:saveSkin', 9, 12345, '{}')
        Mock.fireNet('qb-clothes:loadPlayerSkin', 9)
        Mock.fireNet('qb-clothes:saveOutfit', 9, 'x', 1, {})
        Mock.fireNet('qb-clothing:server:removeOutfit', 9, 'x', 'y')
        assert_eq(#Mock.callCallback('qb-clothing:server:getOutfits', 9), 0)
    end)
end)
