-- pfm-multicharacter: character creation and loading, server logs and skins.
load_resource('tests/lua/fivem_mocks.lua')
QBCore = QBCoreMock
QBCoreMock.Shared.StarterItems = {}
function LoadResourceFile() return '[]' end
function SetPlayerRoutingBucket() end
QBCoreMock.Functions.GetIdentifier = function(src, kind) return kind .. ':' .. tostring(src) end
QBCoreMock.Functions.HasPermission = function(src, perm) return Mock.aces[src] ~= nil and Mock.aces[src][perm] == true end
QBCoreMock.Commands.Refresh = function() end

local logins = {}
local owners = { CHAR1 = 'license:1', CHAR2 = 'license:2' }
local ownedCount = 0
QBCoreMock.Player = {
    Login = function(src, cid, newData)
        logins[#logins + 1] = { src = src, cid = cid, newData = newData }
        local p = Mock.newPlayer(src, cid or 'NEWCID')
        p.PlayerData.position = { x = 1, y = 2, z = 3, w = 0 }
        Mock.eventHandlers['QBCore:Server:PlayerLoaded'](p)
        return true
    end,
}
MySQL.query = setmetatable({ await = function(sql)
    if sql:find('SELECT citizenid FROM players WHERE license', 1, true) then
        local out = {}
        for i = 1, ownedCount do out[i] = { citizenid = 'C' .. i } end
        return out
    end
    if sql:find('houselocations', 1, true) then return {} end
    return { { model = 'm', skin = '{}' } }
end }, { __call = function(_, sql, params, cb) if cb then cb({ { log = 'secret' } }) end end })
MySQL.scalar = setmetatable({ await = function(_, params) return owners[params[1]] end }, { __call = function() end })

Config = nil
load_resource('pfm-apartments/config.lua')
load_resource('pfm-multicharacter/config.lua')
Config.SkipSelection = false
load_resource('pfm-multicharacter/server/main.lua')

local A, B = 1, 2
local form = { firstname = 'Lana', lastname = 'Rhodes', birthdate = '1990-01-01', nationality = 'USA', gender = 1, cid = 1 }
local function copy(t) local o = {} for k, v in pairs(t) do o[k] = v end return o end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.aces = {}, {}
    logins, ownedCount = {}, 0
end

describe('character creation', function()
    it('keeps only the form fields (no chosen phone or bank account)', function()
        local data = copy(form)
        data.account = 'US01PFMB0000000001'
        data.phone = '5550001'
        data.cash = 1e9
        Mock.fireNet('qb-multicharacter:server:createCharacter', A, data)
        assert_eq(#logins, 1)
        local ci = logins[1].newData.charinfo
        assert_eq(ci.firstname, 'Lana')
        assert_eq(ci.account, nil)
        assert_eq(ci.phone, nil)
        assert_eq(ci.cash, nil)
    end)
    it('enforces the character limit on the server', function()
        ownedCount = Config.DefaultNumberOfCharacters
        Mock.fireNet('qb-multicharacter:server:createCharacter', A, copy(form))
        assert_eq(#logins, 0)
    end)
    it('cannot create or load while a character is loaded', function()
        Mock.newPlayer(A, 'CHAR1')
        Mock.fireNet('qb-multicharacter:server:createCharacter', A, copy(form))
        Mock.fireNet('qb-multicharacter:server:loadUserData', A, { citizenid = 'CHAR1' })
        assert_eq(#logins, 0)
    end)
    it('a load without a citizenid does not create a blank character', function()
        Mock.fireNet('qb-multicharacter:server:loadUserData', A, {})
        Mock.fireNet('qb-multicharacter:server:createCharacter', A, { firstname = 'x' })
        assert_eq(#logins, 0)
    end)
    it('loads an owned character', function()
        Mock.fireNet('qb-multicharacter:server:loadUserData', A, { citizenid = 'CHAR1' })
        assert_eq(#logins, 1)
    end)
end)

describe('callbacks', function()
    it('server logs are for staff only', function()
        local logs = Mock.callCallback('qb-multicharacter:server:GetServerLogs', A)
        assert_eq(#logs, 0)
        Mock.aces[A] = { admin = true }
        logs = Mock.callCallback('qb-multicharacter:server:GetServerLogs', A)
        assert_eq(#logs, 1)
    end)
    it('a skin is only returned for the caller own character', function()
        assert_eq(Mock.callCallback('qb-multicharacter:server:getSkin', A, 'CHAR2'), nil)
        assert_eq(Mock.callCallback('qb-multicharacter:server:getSkin', A, 'CHAR1'), 'm')
    end)
end)
