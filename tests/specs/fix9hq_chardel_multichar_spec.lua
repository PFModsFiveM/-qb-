-- pfm-multicharacter's delete event: only from the character menu (no character loaded), and the
-- player is told why pfm-core refused (unpaid bank debt, character in use) instead of "deleted".
load_resource('tests/lua/fivem_mocks.lua')
QBCore = QBCoreMock
QBCoreMock.Shared.StarterItems = {}
function LoadResourceFile() return '[]' end
function SetPlayerRoutingBucket() end
QBCoreMock.Commands.Refresh = function() end

local calls, forceCalls = {}, {}
local result = { true }
QBCoreMock.Player = {
    Login = function() return true end,
    DeleteCharacter = function(src, cid) calls[#calls + 1] = { src = src, cid = cid } return table.unpack(result) end,
    ForceDeleteCharacter = function(cid) forceCalls[#forceCalls + 1] = cid return table.unpack(result) end,
}
local commands = {}
QBCoreMock.Commands.Add = function(name, _, _, _, fn) commands[name] = fn end

Config = nil
load_resource('pfm-apartments/config.lua')
load_resource('pfm-multicharacter/config.lua')
Config.EnableDeleteButton = true
load_resource('pfm-multicharacter/server/main.lua')

local A = 1

local function lastNotify()
    local n = Mock.clientEventsNamed('QBCore:Notify')
    local e = n[#n]
    return e and e.args[1], e and e.args[2]
end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    calls, forceCalls = {}, {}
    result = { true }
end

describe('deleting a character from the character menu', function()
    it('deletes when no character is loaded and says so', function()
        Mock.fireNet('qb-multicharacter:server:deleteCharacter', A, 'ALT1')
        assert_eq(#calls, 1)
        assert_eq(calls[1].cid, 'ALT1')
        local msg, kind = lastNotify()
        assert_eq(msg, 'notifications.char_deleted')
        assert_eq(kind, 'success')
    end)

    it('is refused while the caller has a character loaded (e.g. the one being deleted)', function()
        Mock.newPlayer(A, 'ALT1')
        Mock.fireNet('qb-multicharacter:server:deleteCharacter', A, 'ALT1')
        assert_eq(#calls, 0)
        local msg, kind = lastNotify()
        assert_eq(msg, 'notifications.char_in_use')
        assert_eq(kind, 'error')
    end)

    it('shows the unpaid debt refusal', function()
        result = { false, 'unpaid_debt' }
        Mock.fireNet('qb-multicharacter:server:deleteCharacter', A, 'ALT1')
        assert_eq(#calls, 1)
        local msg, kind = lastNotify()
        assert_eq(msg, 'notifications.char_unpaid_debt')
        assert_eq(kind, 'error')
    end)

    it('shows the in-use refusal when someone else plays the character', function()
        result = { false, 'character_in_use' }
        Mock.fireNet('qb-multicharacter:server:deleteCharacter', A, 'ALT1')
        assert_eq((lastNotify()), 'notifications.char_in_use')
    end)

    it('any other refusal is a failure, never "deleted"', function()
        result = { false, 'bank_unavailable' }
        Mock.fireNet('qb-multicharacter:server:deleteCharacter', A, 'ALT1')
        assert_eq((lastNotify()), 'notifications.char_delete_failed')
    end)

    it('a foreign character (caller dropped) gets no message', function()
        result = { false, 'not_owner' }
        Mock.fireNet('qb-multicharacter:server:deleteCharacter', A, 'OTHER2')
        assert_eq(#Mock.clientEventsNamed('QBCore:Notify'), 0)
    end)

    it('ignores a non-string citizenid', function()
        Mock.fireNet('qb-multicharacter:server:deleteCharacter', A, { 'ALT1' })
        assert_eq(#calls, 0)
    end)

    it('does nothing when the delete button is disabled', function()
        Config.EnableDeleteButton = false
        Mock.fireNet('qb-multicharacter:server:deleteCharacter', A, 'ALT1')
        Config.EnableDeleteButton = true
        assert_eq(#calls, 0)
    end)
end)

describe('/deletechar', function()
    it('reports success only when the force delete worked', function()
        commands.deletechar(9, { 'ALT1' })
        assert_eq(forceCalls[1], 'ALT1')
        assert_eq((lastNotify()), 'notifications.deleted_other_char')
        result = { false, 'not_found' }
        commands.deletechar(9, { 'NOPE1' })
        local msg, kind = lastNotify()
        assert_eq(msg, 'notifications.char_delete_failed')
        assert_eq(kind, 'error')
    end)
end)

describe('locale', function()
    it('has the refusal messages', function()
        local function locale()
            Lang = nil
            Locale = { new = function(_, opts) return opts end }
            load_resource('pfm-multicharacter/locales/en.lua')
            return Lang.phrases.notifications
        end
        local n = locale()
        assert_true(type(n.char_in_use) == 'string')
        assert_true(type(n.char_unpaid_debt) == 'string')
        assert_true(type(n.char_delete_failed) == 'string')
    end)
end)
