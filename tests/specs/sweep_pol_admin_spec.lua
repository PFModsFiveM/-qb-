-- pfm-adminmenu: reports reach staff only; admin events from non-admins do nothing but ban.
load_resource('tests/lua/fivem_mocks.lua')
QBCore = QBCoreMock
Commands = {}
QBCoreMock.Commands.Add = function(name, _, _, _, fn) Commands[name] = fn end
QBCoreMock.Functions.HasPermission = function(src, perm) return Mock.aces[src] ~= nil and Mock.aces[src][perm] == true end
QBCoreMock.Functions.IsOptin = function() return true end
QBCoreMock.Functions.GetIdentifier = function(src, kind) return kind .. ':' .. tostring(src) end
function GetPlayers() local out = {} for src in pairs(Mock.players) do out[#out + 1] = tostring(src) end return out end
function SetEntityCoords() end
load_resource('pfm-adminmenu/server/server.lua')

local ADMIN, PLAYER, OTHER = 1, 2, 3

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.aces, Mock.dropped = {}, {}, {}
    Mock.newPlayer(ADMIN)
    Mock.newPlayer(PLAYER)
    Mock.newPlayer(OTHER)
    Mock.aces[ADMIN] = { admin = true }
end

describe('reports', function()
    it('go to staff only', function()
        Commands.report(PLAYER, { 'help', 'me' })
        local sent = Mock.clientEventsNamed('qb-admin:client:SendReport')
        assert_eq(#sent, 1)
        assert_eq(sent[1].target, ADMIN)
    end)
end)

describe('admin events', function()
    it('a non-admin bringing a player is banned and nothing happens', function()
        Mock.fireNet('qb-admin:server:bring', PLAYER, { id = OTHER })
        Mock.fireNet('qb-admin:server:inventory', PLAYER, { id = OTHER })
        Mock.fireNet('qb-admin:giveWeapon', PLAYER, 'weapon_pistol')
        assert_eq(#Mock.dropped, 3)
        assert_eq(Mock.dropped[1].src, PLAYER)
    end)
end)
