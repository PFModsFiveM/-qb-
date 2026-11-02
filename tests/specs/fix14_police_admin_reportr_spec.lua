-- pfm-adminmenu /reportr (batch 14: POL-4). The second permission check compared the boolean from
-- IsPlayerAceAllowed with 1, so it always returned and an admin's reply never reached the player.
load_resource('tests/lua/fivem_mocks.lua')
QBCore = QBCoreMock
Commands = {}
QBCoreMock.Commands.Add = function(name, _, _, _, fn) Commands[name] = fn end
QBCoreMock.Functions.HasPermission = function(src, perm) return Mock.aces[src] ~= nil and Mock.aces[src][perm] == true end
QBCoreMock.Functions.IsOptin = function() return true end
function GetPlayers() local out = {} for src in pairs(Mock.players) do out[#out + 1] = tostring(src) end return out end
function SetEntityCoords() end
load_resource('pfm-adminmenu/server/server.lua')

local ADMIN, PLAYER, OTHER = 1, 2, 3
local function chatTo(src)
    local out = {}
    for _, e in ipairs(Mock.clientEventsNamed('chat:addMessage')) do if e.target == src then out[#out + 1] = e end end
    return out
end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.aces = {}, {}
    Mock.newPlayer(ADMIN)
    Mock.newPlayer(PLAYER)
    Mock.newPlayer(OTHER)
    Mock.aces[ADMIN] = { admin = true }
end

describe('/reportr', function()
    it('an admin\'s reply reaches the player and the admin', function()
        Commands.reportr(ADMIN, { tostring(PLAYER), 'we', 'are', 'on', 'it' })
        local got = chatTo(PLAYER)
        assert_eq(#got, 1)
        assert_eq(got[1].args[1].args[2], 'we are on it')
        assert_eq(#chatTo(ADMIN), 1)
    end)
    it('a player with the command ace only (no admin permission) can reply too', function()
        Mock.aces[OTHER] = { command = true }
        Commands.reportr(OTHER, { tostring(PLAYER), 'hi' })
        assert_eq(#chatTo(PLAYER), 1)
    end)
    it('anyone else is refused', function()
        Commands.reportr(OTHER, { tostring(PLAYER), 'fake admin' })
        assert_eq(#chatTo(PLAYER), 0)
    end)
    it('an empty message or a bad id sends nothing', function()
        Commands.reportr(ADMIN, { tostring(PLAYER) })
        Commands.reportr(ADMIN, { 'abc', 'x' })
        assert_eq(#chatTo(PLAYER), 0)
    end)
end)
