-- pfm-truckrobbery (batch 14): the stages are decided on the server (it spawns the truck and the
-- guards, plants the charge only with every guard dead, the truck stopped and the robber at the back
-- doors) and the mission is locked before the activation fee's ledger wait.
load_resource('tests/lua/ledger_env.lua')
Inv = {}
Mock.exportsByResource['pfm-inventory'] = {
    AddItem = function(_, src, item, n) Inv[item] = (Inv[item] or 0) + (n or 1) return true end,
    RemoveItem = function(_, _, item, n)
        n = n or 1
        if (Inv[item] or 0) < n then return false end
        Inv[item] = Inv[item] - n
        return true
    end,
}
setmetatable(QBCoreMock.Shared.Items, { __index = function(_, k) return { name = k, label = k } end })
QBCoreMock.Functions.GetPlayers = function() local out = {} for id in pairs(Mock.players) do out[#out + 1] = id end return out end
LedgerEnv.load('pfm-truckrobbery', { 'pfm-truckrobbery/config.lua', 'pfm-truckrobbery/server/main.lua' })
function Wait() if coroutine.isyieldable() then coroutine.yield() end end
Timers = {}
function SetTimeout(ms, fn) Timers[#Timers + 1] = { ms = ms, fn = fn } end

-- server-spawned entities: the truck and its guards
Health, Velocity, Heading, Guards, Deleted = {}, {}, {}, {}, {}
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
function DoesEntityExist(e) return not Deleted[e] end
function DeleteEntity(e) Deleted[e] = true end

local R, COP, OTHER = 1, 2, 3
local realCharge = PFPayout.Charge

local function accept(src)
    local co = coroutine.create(function() Mock.fireNet('AttackTransport:akceptujto', src) end)
    assert(coroutine.resume(co))
    return co
end
local function started(src)
    local n = 0
    for _, e in ipairs(Mock.clientEventsNamed('AttackTransport:Pozwolwykonac')) do if e.target == src then n = n + 1 end end
    return n
end
local function lastSpawn()
    local ev = Mock.clientEventsNamed('AttackTransport:Pozwolwykonac')
    return ev[#ev].args[1]
end
local function spawnTruck()
    local s = Config.VehicleSpawn[lastSpawn()]
    Mock.coords[R] = vector3(s.x + 100, s.y, s.z)
    Mock.fireNet('AttackTransport:requestTruck', R)
    local ev = Mock.clientEventsNamed('AttackTransport:truckReady')
    return ev[#ev].args[1]
end
local function rearOf(truck)
    local c, h = Mock.coords[truck], math.rad(Heading[truck])
    return vector3(c.x + math.sin(h) * 3.6, c.y - math.cos(h) * 3.6, c.z)
end
local function planted() return #Mock.clientEventsNamed('AttackTransport:bombPlanted') end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    PFPayout.Charge = realCharge
    Mock.clock = Mock.clock + 100000
    Mock.players, Mock.coords, Inv, Guards, Velocity, Timers = {}, {}, {}, {}, {}, {}
    Mock.newPlayer(R).PlayerData.money.bank = 100000
    Mock.newPlayer(OTHER).PlayerData.money.bank = 100000
    Config.ActivePolice = 1
    Config.ChargeItem = nil
    Mock.newPlayer(COP).PlayerData.job = { name = 'police', type = 'leo', onduty = true }
    -- end any mission an earlier test left running
    Mock.fireEvent('playerDropped', R)
    Mock.fireEvent('playerDropped', OTHER)
end

describe('armored truck stages', function()
    it('the charge is refused while a guard lives, while the truck moves, and away from the back doors', function()
        accept(R)
        local truck = spawnTruck()
        Mock.coords[R] = rearOf(truck)
        Mock.fireNet('AttackTransport:plantBomb', R)                       -- guards alive
        assert_eq(planted(), 0)
        Health[Guards[1]], Health[Guards[2]] = 0, 0
        Mock.fireNet('AttackTransport:plantBomb', R)                       -- one guard still alive
        assert_eq(planted(), 0)
        Deleted[Guards[3]] = true                                          -- (despawned counts as gone)
        Velocity[truck] = vector3(8, 0, 0)
        Mock.fireNet('AttackTransport:plantBomb', R)                       -- driving
        assert_eq(planted(), 0)
        Velocity[truck] = vector3(0.2, 0, 0)
        local c = Mock.coords[truck]
        local h = math.rad(Heading[truck])                                 -- at the cab, not the back
        Mock.coords[R] = vector3(c.x - math.sin(h) * 3.6, c.y + math.cos(h) * 3.6, c.z)
        Mock.fireNet('AttackTransport:plantBomb', R)
        assert_eq(planted(), 0)
        Mock.fireNet('AttackTransport:plantBomb', OTHER)                   -- not the mission player
        assert_eq(planted(), 0)
        Mock.coords[R] = rearOf(truck)
        Mock.fireNet('AttackTransport:plantBomb', R)
        Mock.fireNet('AttackTransport:plantBomb', R)                       -- once
        assert_eq(planted(), 1)
    end)
    it('a configured charge item is used up on the server', function()
        Config.ChargeItem = 'thermite'
        accept(R)
        local truck = spawnTruck()
        for _, g in ipairs(Guards) do Health[g] = 0 end
        Mock.coords[R] = rearOf(truck)
        Mock.fireNet('AttackTransport:plantBomb', R)
        assert_eq(planted(), 0)
        Inv.thermite = 1
        Mock.fireNet('AttackTransport:plantBomb', R)
        assert_eq(planted(), 1)
        assert_eq(Inv.thermite, 0)
    end)
    it('no loot before the charge went off, and the job is free again after the loot', function()
        accept(R)
        local truck = spawnTruck()
        for _, g in ipairs(Guards) do Health[g] = 0 end
        Mock.coords[R] = rearOf(truck)
        Mock.clock = Mock.clock + 600
        Mock.fireNet('AttackTransport:graczZrobilnapad', R)               -- nothing planted
        assert_eq(Inv.markedbills, nil)
        Mock.fireNet('AttackTransport:plantBomb', R)
        Mock.clock = Mock.clock + Config.TimeToBlow - 5
        Mock.fireNet('AttackTransport:graczZrobilnapad', R)
        assert_eq(Inv.markedbills, nil)
        Mock.clock = Mock.clock + 6
        Mock.fireNet('AttackTransport:graczZrobilnapad', R)
        assert_true(Inv.markedbills > 0)
        accept(OTHER)
        assert_eq(started(OTHER), 1)
    end)
end)

describe('armored truck accept', function()
    it('two accepts at once: the second is turned away before any fee, the first gets its mission', function()
        PFPayout.Charge = function(...)
            coroutine.yield() -- the ledger wait
            return realCharge(...)
        end
        local first = accept(R)
        local second = accept(OTHER)
        assert(coroutine.resume(first))
        -- (if the second accept got into the ledger wait too, let it finish)
        if coroutine.status(second) == 'suspended' then assert(coroutine.resume(second)) end
        assert_eq(started(R), 1)
        assert_eq(started(OTHER), 0)
        assert_eq(#LedgerEnv.paid('pfm-truckrobbery:activate:'), 1)
        assert_eq(Mock.players[OTHER].PlayerData.money.bank, 100000)
    end)
    it('a clear refusal frees the job; an unclear fee keeps it locked and is asked again under the same key', function()
        local keys = {}
        PFPayout.Charge = function(_, _, _, opts)
            keys[#keys + 1] = opts.key
            return false, { ok = false, state = 'failed', error = 'insufficient_funds' }
        end
        accept(R)
        assert_eq(started(R), 0)
        PFPayout.Charge = function(_, _, _, opts)
            keys[#keys + 1] = opts.key
            if #keys == 2 then return false, { ok = false, state = 'pending', unclear = true } end
            return 'bank', { ok = true }
        end
        accept(R)                                                        -- the job was free again
        assert_eq(started(R), 0)
        accept(OTHER)                                                    -- locked while it settles
        assert_eq(#keys, 2)
        for _, t in ipairs(Timers) do if t.ms == 15000 then t.fn() end end
        assert_eq(#keys, 3)
        assert_eq(keys[3], keys[2])                                      -- same key, never a new one
        assert_eq(started(R), 1)
        assert_eq(started(OTHER), 0)
    end)
end)
