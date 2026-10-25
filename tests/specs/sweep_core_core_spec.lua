-- pfm-core player events: client callbacks answer only for the player asked, command calls survive
-- bad arguments, and the debug print is admin-only.
load_resource('tests/lua/fivem_mocks.lua')
QBCore = QBCoreMock
QBCoreMock.ClientCallbacks = {}
QBCoreMock.ServerCallbacks = {}
QBCoreMock.Commands.List = {}
QBCoreMock.Shared.IsFunction = function(v) return type(v) == 'function' end
local perms = {}
QBCoreMock.Functions.HasPermission = function(src, perm) return perms[src] == perm end

-- a promise that resolves synchronously is enough here
promise = { new = function()
    local p = {}
    function p:resolve(...) self.value = ...; self.resolved = true end
    return p
end }
Citizen.Await = function() end

load_resource('pfm-core/server/vehicle_spawns.lua')
load_resource('pfm-core/server/events.lua')
load_resource('pfm-core/server/debug.lua')
-- only TriggerClientCallback and the key helper are needed from functions.lua
local savedFunctions = {}
for k, v in pairs(QBCoreMock.Functions) do savedFunctions[k] = v end
load_resource('pfm-core/server/functions.lua')
local realTrigger = QBCoreMock.Functions.TriggerClientCallback
QBCoreMock.Functions = savedFunctions
QBCoreMock.Functions.TriggerClientCallback = realTrigger

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    perms = {}
    QBCoreMock.ClientCallbacks = {}
    Mock.newPlayer(2)
    Mock.newPlayer(12)
end

describe('client callbacks', function()
    it("one player's answer cannot resolve another player's callback", function()
        local got
        QBCore.Functions.TriggerClientCallback('vehicleCheck', 12, function(v) got = v end)
        -- 'vehicleCheck1' from player 2 used to make the same key as 'vehicleCheck' for player 12
        Mock.fireNet('QBCore:Server:TriggerClientCallback', 2, 'vehicleCheck1', 'trunk-FORGED')
        assert_eq(got, nil, 'not resolved by player 2')
        Mock.fireNet('QBCore:Server:TriggerClientCallback', 12, 'vehicleCheck', 'glovebox-OWN')
        assert_eq(got, 'glovebox-OWN')
    end)
    it('a non-string name is ignored', function()
        Mock.fireNet('QBCore:Server:TriggerClientCallback', 2, nil, 'x')
        Mock.fireNet('QBCore:Server:TriggerClientCallback', 2, { 1 }, 'x')
    end)
end)

describe('QBCore:CallCommand', function()
    it('a command called with non-table args gets an empty table, not a crash', function()
        local received
        QBCoreMock.Commands.List['car'] = { name = 'car', arguments = { {} }, argsrequired = true, callback = function(_, a) received = a end }
        perms[2] = 'command.car'
        Mock.fireNet('QBCore:CallCommand', 2, 'car', 'notatable')
        assert_eq(received, nil, 'required argument missing: not run')
        QBCoreMock.Commands.List['car'].argsrequired = false
        Mock.fireNet('QBCore:CallCommand', 2, 'car', 'notatable')
        assert_eq(type(received), 'table')
    end)
    it('a non-string command is ignored', function()
        Mock.fireNet('QBCore:CallCommand', 2, { 'car' }, {})
    end)
end)

describe('QBCore:DebugSomething', function()
    it('prints only for admins', function()
        local printed = 0
        local realPrint = print
        print = function() printed = printed + 1 end
        Mock.fireNet('QBCore:DebugSomething', 2, { a = 1 }, 0, 'x')
        local asPlayer = printed
        perms[2] = 'admin'
        Mock.fireNet('QBCore:DebugSomething', 2, { a = 1 }, 0, 'x')
        print = realPrint
        assert_eq(asPlayer, 0, 'a player prints nothing')
        assert_true(printed > 0, 'an admin can debug')
    end)
end)
