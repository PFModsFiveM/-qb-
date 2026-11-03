-- Armored truck robbery → city timeline: one 'crime.robbery.truck' per mission at the server's truck
-- position, from the guards' alert or (if that never came) from the looting; never from other players.
load_resource('tests/lua/ledger_env.lua') -- the activation fee goes through the ledger
Emits = {}
Mock.exportsByResource['pf-services'] = {
    Emit = function(_, kind, data, opts) Emits[#Emits + 1] = { kind = kind, data = data, opts = opts or {} } return #Emits end,
}
Inv = {}
Mock.exportsByResource['pfm-inventory'] = { AddItem = function(_, src, item, n) Inv[item] = (Inv[item] or 0) + (n or 1) return true end }
setmetatable(QBCoreMock.Shared.Items, { __index = function(_, k) return { name = k, label = k } end })
QBCoreMock.Functions.GetPlayers = function() local out = {} for id in pairs(Mock.players) do out[#out + 1] = id end return out end
LedgerEnv.load('pfm-truckrobbery', { 'pfm-truckrobbery/config.lua', 'pfm-truckrobbery/server/main.lua' })
function Wait() if coroutine.isyieldable() then coroutine.yield() end end

local R, COP, OTHER = 1, 2, 3
local TRUCK
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

local function startMission()
    coroutine.resume(coroutine.create(function() Mock.fireNet('AttackTransport:akceptujto', R) end))
    local ev = Mock.clientEventsNamed('AttackTransport:Pozwolwykonac')
    local s = Config.VehicleSpawn[ev[#ev].args[1]]
    TRUCK = spawnTruck(R, s)
    return s
end
-- guards dead, charge planted at the back doors, and the fuse burnt
local function blowDoors()
    for _, g in ipairs(Guards) do Health[g] = 0 end
    local c, h = Mock.coords[TRUCK], math.rad(Heading[TRUCK])
    Mock.coords[R] = vector3(c.x + math.sin(h) * 3.6, c.y - math.cos(h) * 3.6, c.z)
    Mock.fireNet('AttackTransport:plantBomb', R)
    Mock.clock = Mock.clock + Config.TimeToBlow + 1
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.clock = Mock.clock + 100000
    Mock.players, Mock.coords, Inv, Emits, Guards = {}, {}, {}, {}, {}
    Mock.newPlayer(R).PlayerData.money.bank = 100000
    Mock.newPlayer(OTHER)
    Config.ActivePolice = 1
    Mock.newPlayer(COP).PlayerData.job = { name = 'police', type = 'leo', onduty = true }
end

describe('armored truck robbery event', function()
    it('nobody but the mission player raises it', function()
        Mock.fireNet('AttackTransport:zawiadompsy', OTHER)
        assert_eq(#Emits, 0)
    end)
    it('the guards\' alert raises it once, at the truck; the loot adds none', function()
        local s = startMission()
        Mock.fireNet('AttackTransport:zawiadompsy', OTHER)                  -- not the mission player
        assert_eq(#Emits, 0)
        Mock.coords[TRUCK] = vector3(s.x + 40, s.y, s.z)                    -- the truck drove on
        Mock.fireNet('AttackTransport:zawiadompsy', R)
        assert_eq(#Emits, 1)
        assert_eq(Emits[1].kind, 'crime.robbery.truck')
        assert_near(Emits[1].opts.coords.x, s.x + 40, 0.01)
        blowDoors()
        Mock.coords[R] = vector3(s.x + 41, s.y, s.z)
        Mock.fireNet('AttackTransport:graczZrobilnapad', R)
        assert_true((Inv.markedbills or 0) > 0)
        assert_eq(#Emits, 1)
    end)
    it('a robber who skipped the alert is still reported, at the truck, once the charge is planted', function()
        local s = startMission()
        blowDoors()
        Mock.coords[R] = vector3(s.x + 1, s.y, s.z)
        Mock.fireNet('AttackTransport:graczZrobilnapad', R)
        assert_eq(#Emits, 1)
        assert_eq(Emits[1].opts.dedupe:sub(1, 8), 'mission:')
        assert_near(Emits[1].opts.coords.x, s.x, 0.01)
    end)
end)
