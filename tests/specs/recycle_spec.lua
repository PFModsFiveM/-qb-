-- pfm-recyclejob: a hand-in needs a package the server saw picked up.
load_resource('tests/lua/ledger_env.lua')
LedgerEnv.load('pfm-recyclejob', { 'pfm-recyclejob/config.lua', 'pfm-recyclejob/server.lua' })

local W = 1
local got
local function at(c) Mock.coords[W] = vector3(c.x, c.y, c.z) end
local function total() local n = 0 for _, k in pairs(got) do n = n + k end return n end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.clock = Mock.clock + 1000
    Mock.gameTimer = Mock.gameTimer + 60000
    Mock.players, Mock.coords, got = {}, {}, {}
    local p = Mock.newPlayer(W)
    p.AddItem = function(item, n) got[item] = (got[item] or 0) + (n or 1) return true end
    Mock.fireEvent('playerDropped', W) -- clear carried packages
end

describe('recycle hand-ins', function()
    it('standing at the drop point pays nothing', function()
        at(Config.DropLocation)
        Mock.fireNet('qb-recyclejob:server:getItem', W)
        assert_eq(total(), 0)
    end)
    it('a picked-up package pays once, after the carry time', function()
        at(Config.PickupLocations[1].loc)
        Mock.fireNet('qb-recyclejob:server:pickupPackage', W, 1)
        at(Config.DropLocation)
        Mock.clock = Mock.clock + 10
        Mock.fireNet('qb-recyclejob:server:getItem', W)
        local first = total()
        assert_true(first > 0)
        Mock.gameTimer = Mock.gameTimer + 60000
        Mock.fireNet('qb-recyclejob:server:getItem', W)
        assert_eq(total(), first)
    end)
    it('a pickup far from the shelf does not count', function()
        at(Config.DropLocation)
        Mock.fireNet('qb-recyclejob:server:pickupPackage', W, 1)
        Mock.clock = Mock.clock + 10
        Mock.fireNet('qb-recyclejob:server:getItem', W)
        assert_eq(total(), 0)
    end)
end)
