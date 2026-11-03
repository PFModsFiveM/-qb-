-- pfm-truckrobbery: the payout needs the mission's own (server-spawned) truck, the charge the server
-- saw planted and gone off, and the player at the truck.
load_resource('tests/lua/ledger_env.lua') -- the activation fee goes through the ledger
Inv = {}
Mock.exportsByResource['pfm-inventory'] = { AddItem = function(_, src, item, n) Inv[item] = (Inv[item] or 0) + (n or 1) return true end }
setmetatable(QBCoreMock.Shared.Items, { __index = function(_, k) return { name = k, label = k } end })
QBCoreMock.Functions.GetPlayers = function() local out = {} for id in pairs(Mock.players) do out[#out + 1] = id end return out end
LedgerEnv.load('pfm-truckrobbery', { 'pfm-truckrobbery/config.lua', 'pfm-truckrobbery/server/main.lua' })
function Wait() if coroutine.isyieldable() then coroutine.yield() end end

-- server-spawned entities: the truck and its guards
Health, Velocity, Heading, Guards = {}, {}, {}, {}
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
function GetEntityVelocity(e) return Velocity[e] or vector3(0, 0, 0) end
function GetEntityHeading(e) return Heading[e] or 0.0 end

local R, COP = 1, 2

local function accept()
    coroutine.resume(coroutine.create(function() Mock.fireNet('AttackTransport:akceptujto', R) end))
    local ev = Mock.clientEventsNamed('AttackTransport:Pozwolwykonac')
    return ev[#ev] and ev[#ev].args[1]
end
local function spawnTruck(spawn)
    local s = Config.VehicleSpawn[spawn]
    Mock.coords[R] = vector3(s.x + 100, s.y, s.z)
    Mock.fireNet('AttackTransport:requestTruck', R)
    local ev = Mock.clientEventsNamed('AttackTransport:truckReady')
    return ev[#ev] and ev[#ev].args[1]
end
local function rearOf(truck)
    local c, h = Mock.coords[truck], math.rad(Heading[truck])
    return vector3(c.x + math.sin(h) * 3.6, c.y - math.cos(h) * 3.6, c.z)
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.clock = Mock.clock + 100000
    Mock.players, Mock.coords, Inv, Guards = {}, {}, {}, {}
    local p = Mock.newPlayer(R)
    p.PlayerData.money.bank = 100000
    Config.ActivePolice = 1
    Mock.newPlayer(COP).PlayerData.job = { name = 'police', type = 'leo', onduty = true }
end


describe('armored truck', function()
    it('the payout needs the truck, the planted charge gone off, and the player at it', function()
        local spawn = accept()
        assert_true(spawn ~= nil)
        -- the activation fee was charged once, through the ledger
        assert_eq(Mock.players[R].PlayerData.money.bank, 100000 - Config.ActivationCost)
        assert_eq(#LedgerEnv.paid('pfm-truckrobbery:activate:'), 1)
        Mock.fireNet('AttackTransport:graczZrobilnapad', R)               -- right after accepting
        assert_eq(Inv.markedbills, nil)
        local truck = spawnTruck(spawn)
        assert_true(truck ~= nil)
        for _, g in ipairs(Guards) do Health[g] = 0 end
        Mock.coords[R] = rearOf(truck)
        Mock.fireNet('AttackTransport:plantBomb', R)
        assert_eq(#Mock.clientEventsNamed('AttackTransport:bombPlanted'), 1)
        Mock.fireNet('AttackTransport:graczZrobilnapad', R)               -- before it went off
        assert_eq(Inv.markedbills, nil)
        Mock.clock = Mock.clock + Config.TimeToBlow + 1
        local c = Mock.coords[truck]
        Mock.coords[R] = vector3(c.x + 500, c.y, c.z)                      -- far from the truck
        Mock.fireNet('AttackTransport:graczZrobilnapad', R)
        assert_eq(Inv.markedbills, nil)
        Mock.coords[R] = vector3(c.x + 2, c.y, c.z)
        Mock.fireNet('AttackTransport:graczZrobilnapad', R)
        assert_true((Inv.markedbills or 0) > 0)
    end)
    it('the truck is spawned by the server only when the mission player is near the chosen spawn', function()
        local spawn = accept()
        local s = Config.VehicleSpawn[spawn]
        assert_eq(Mock.netHandlers['AttackTransport:truckSpawned'], nil)
        Mock.coords[R] = vector3(s.x + 1000, s.y, s.z)
        Mock.fireNet('AttackTransport:requestTruck', R)
        assert_eq(#Mock.clientEventsNamed('AttackTransport:truckReady'), 0)
        Mock.coords[R] = vector3(s.x + 50, s.y, s.z)
        Mock.fireNet('AttackTransport:requestTruck', R)
        Mock.fireNet('AttackTransport:requestTruck', R)                    -- one truck per mission
        local ready = Mock.clientEventsNamed('AttackTransport:truckReady')
        assert_eq(#ready, 1)
        assert_eq(Mock.models[ready[1].args[1]], Config.TruckModel)
        assert_eq(#ready[1].args[2], 3)                                     -- three armed guards
    end)
end)
