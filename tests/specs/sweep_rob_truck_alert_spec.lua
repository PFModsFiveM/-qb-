-- pfm-truckrobbery: police alerts come only from the player on the mission, at the mission truck,
-- never with a client-chosen spot or HTML text broadcast to everyone.
load_resource('tests/lua/ledger_env.lua') -- the activation fee goes through the ledger
Mock.exportsByResource['pfm-inventory'] = { AddItem = function() return true end }
setmetatable(QBCoreMock.Shared.Items, { __index = function(_, k) return { name = k, label = k } end })
QBCoreMock.Functions.GetPlayers = function() local out = {} for id in pairs(Mock.players) do out[#out + 1] = id end return out end
LedgerEnv.load('pfm-truckrobbery', { 'pfm-truckrobbery/config.lua', 'pfm-truckrobbery/server/main.lua' })
-- the mission timer waits: keep it paused inside a coroutine
function Wait() if coroutine.isyieldable() then coroutine.yield() end end

local R, OTHER, COP = 1, 3, 2
-- server-spawned entities: the truck and its guards
Health, Heading, Guards = {}, {}, {}
local nextEntity = 600
function CreateVehicleServerSetter(model, _, x, y, z, h)
    nextEntity = nextEntity + 1
    Mock.models[nextEntity], Mock.coords[nextEntity], Heading[nextEntity] = model, vector3(x, y, z), h
    return nextEntity
end
function CreatePedInsideVehicle(veh)
    nextEntity = nextEntity + 1
    Health[nextEntity], Mock.coords[nextEntity] = 200, Mock.coords[veh]
    Guards[#Guards + 1] = nextEntity
    return nextEntity
end
function GiveWeaponToPed() end
function GetEntityHealth(e) return Health[e] or 0 end
function GetEntityVelocity() return vector3(0, 0, 0) end
function GetEntityHeading(e) return Heading[e] or 0.0 end
-- the mission player near the spawn point: the server spawns the truck there
local function spawnTruck(src, s)
    Mock.coords[src] = vector3(s.x + 100, s.y, s.z)
    Mock.fireNet('AttackTransport:requestTruck', src)
    local ev = Mock.clientEventsNamed('AttackTransport:truckReady')
    return ev[#ev].args[1]
end

local function accept()
    coroutine.resume(coroutine.create(function() Mock.fireNet('AttackTransport:akceptujto', R) end))
    local ev = Mock.clientEventsNamed('AttackTransport:Pozwolwykonac')
    return ev[#ev] and ev[#ev].args[1]
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.clock = Mock.clock + 100000
    Mock.players, Mock.coords = {}, {}
    Mock.newPlayer(R).PlayerData.money.bank = 100000
    Mock.newPlayer(OTHER)
    Config.ActivePolice = 1
    Mock.newPlayer(COP).PlayerData.job = { name = 'police', type = 'leo', onduty = true }
end

describe('armored truck alerts', function()
    it('with no mission, nobody can send one', function()
        Mock.fireNet('qb-armoredtruckheist:server:callCops', OTHER, '<b>fake</b>', vector3(1, 2, 3))
        Mock.fireNet('AttackTransport:zawiadompsy', OTHER, 1, 2, 3)
        assert_eq(#Mock.clientEventsNamed('qb-armoredtruckheist:client:robberyCall'), 0)
        assert_eq(#Mock.clientEventsNamed('AttackTransport:InfoForLspd'), 0)
    end)
    it('only the mission player, at the truck, once per 30 s, as plain text', function()
        local spawn = accept()
        local s = Config.VehicleSpawn[spawn]
        spawnTruck(R, s)
        Mock.fireNet('qb-armoredtruckheist:server:callCops', OTHER, 'x', vector3(1, 2, 3))
        assert_eq(#Mock.clientEventsNamed('qb-armoredtruckheist:client:robberyCall'), 0)
        Mock.fireNet('qb-armoredtruckheist:server:callCops', R, '<img src=x>Route 68', vector3(1, 2, 3))
        Mock.fireNet('qb-armoredtruckheist:server:callCops', R, 'again', vector3(1, 2, 3))
        local calls = Mock.clientEventsNamed('qb-armoredtruckheist:client:robberyCall')
        assert_eq(#calls, 1)
        assert_eq(calls[1].args[1]:find('<', 1, true), nil)
        assert_eq(calls[1].args[2].x, s.x)
        Mock.fireNet('AttackTransport:zawiadompsy', R, 1, 2, 3)
        local info = Mock.clientEventsNamed('AttackTransport:InfoForLspd')
        assert_eq(#info, 1)
        assert_eq(info[1].args[1], s.x)
    end)
end)
