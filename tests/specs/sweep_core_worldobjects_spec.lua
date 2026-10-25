-- pfm-worldobjects: open/unpack/move are limited to one request a second per player (each one reads
-- the database).
load_resource('tests/lua/fivem_mocks.lua')
Config = nil
load_resource('pfm-worldobjects/config.lua')
load_resource('pfm-worldobjects/server.lua')

local P = 1
local function reads()
    local n = 0
    for _, c in ipairs(Mock.dbCalls) do if c.kind == 'single' then n = n + 1 end end
    return n
end

BeforeEach = function()
    Mock.reset()
    Mock.gameTimer = Mock.gameTimer + 5000
end

describe('world object requests', function()
    it('a burst of requests reads the database once', function()
        for _ = 1, 20 do Mock.fireNet('pfm-worldobjects:server:open', P, 'wo-1') end
        for _ = 1, 20 do Mock.fireNet('pfm-worldobjects:server:move', P, 'wo-1') end
        assert_eq(reads(), 1)
    end)
    it('a request a second later is served', function()
        Mock.fireNet('pfm-worldobjects:server:open', P, 'wo-1')
        Mock.gameTimer = Mock.gameTimer + 1500
        Mock.fireNet('pfm-worldobjects:server:unpack', P, 'wo-1')
        assert_eq(reads(), 2)
    end)
end)
