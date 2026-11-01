-- pf-mechanicjob: a shop's boss orders a tow for the broken car next to them
-- ('pf-mechanicjob:server:advanced:requestTow', server/advanced_systems.lua). The shop's account pays,
-- so the request is built on the server: only the boss of the shop orders it, only for a car the
-- server itself reads as broken (engine/body/tank health, a worn-out part), found by plate beside the
-- boss from server positions, one order per car at a time, paid by the boss's own shop.
-- The boss and the car are locked before the first wait (the car's saved state is loaded first,
-- PFMech.EnsureVehicleRestored, which reads the database); the cooldown starts only when pf-services
-- made a new request; every refusal says why. The client offers the order on the same rule as the
-- server (shared/tow_check.lua): body, tank and worn-out parts count, not only a low engine.
load_resource('tests/lua/ledger_env.lua')

local plates, health = {}, {}
function GetVehicleNumberPlateText(v) return plates[v] end
function GetAllVehicles() local out = {} for v in pairs(plates) do out[#out + 1] = v end table.sort(out) return out end
function GetVehicleEngineHealth(v) return (health[v] or {}).engine or 1000.0 end
function GetVehicleBodyHealth(v) return (health[v] or {}).body or 1000.0 end
function GetVehiclePetrolTankHealth(v) return (health[v] or {}).tank or 1000.0 end
local states = {}
function Entity(e)
    states[e] = states[e] or { state = setmetatable({}, { __index = { set = function(self, k, v) rawset(self, k, v) end } }) }
    return states[e]
end

-- pf-services: records the requests; `hold` keeps the next CreateRequest waiting (it yields)
local requests, hold, waiting = {}, false, nil
Mock.exportsByResource['pf-services'] = {
    CreateRequest = function(_, opts)
        if hold and coroutine.isyieldable() then
            hold = false
            waiting = coroutine.running()
            coroutine.yield()
        end
        requests[#requests + 1] = opts
        return { ok = true, id = #requests }
    end,
}
local createRequest = Mock.exportsByResource['pf-services'].CreateRequest
local started = { ['pf-services'] = true, ['pfm-banking'] = true, ['pfm-core'] = true }
function GetResourceState(name) return started[name] and 'started' or 'missing' end

LedgerEnv.load('pf-mechanicjob', { '[pfscripts]/pf-mechanicjob/config.lua', '[pfscripts]/pf-mechanicjob/shared/tow_check.lua' })
load_resource('[pfscripts]/pf-mechanicjob/server/advanced_systems.lua')

local MECH, CIV, STAFF, RIVAL, CAR, CAR2 = 1, 2, 3, 4, 500, 501
local AT = vector3(300.0, 300.0, 30.0)
local TOW = Config.AdvancedSystems.Integrations.Tow

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 1000
    started['pf-services'] = true
    Mock.players, Mock.coords, plates, health, states, requests = {}, {}, {}, {}, {}, {}
    hold, waiting = false, nil
    Mock.exportsByResource['pf-services'].CreateRequest = createRequest
    PFMech.EnsureVehicleRestored = nil
    local m = Mock.newPlayer(MECH, 'MECHCID')
    m.PlayerData.job = { name = 'mechanic', label = 'LS Customs', onduty = true, isboss = true, grade = { level = 4 } }
    Mock.newPlayer(CIV).PlayerData.job = { name = 'unemployed', onduty = true }
    Mock.newPlayer(STAFF, 'STAFFCID').PlayerData.job = { name = 'mechanic', label = 'LS Customs', onduty = true, isboss = false, grade = { level = 3 } }
    Mock.newPlayer(RIVAL, 'RIVALCID').PlayerData.job = { name = 'bennys', label = "Benny's", onduty = true, isboss = true, grade = { level = 4 } }
    Mock.coords[MECH], Mock.coords[CIV], Mock.coords[STAFF], Mock.coords[RIVAL] = AT, AT, AT, AT
    plates[CAR], plates[CAR2] = 'BROKE01', 'BROKE02'
    Mock.coords[CAR], Mock.coords[CAR2] = vector3(302.0, 300.0, 30.0), vector3(300.0, 303.0, 30.0)
    health[CAR], health[CAR2] = { engine = 120.0 }, { engine = 150.0 }      -- both broken down
end

local function ask(src, payload) Mock.fireNet('pf-mechanicjob:server:advanced:requestTow', src, payload) end
local function askAsync(src, payload)
    local co = coroutine.create(function() ask(src, payload) end)
    assert(coroutine.resume(co))
    return co
end
local function lastNote(src)
    local notes = Mock.clientEventsNamed('QBCore:Notify')
    for i = #notes, 1, -1 do if notes[i].target == src then return notes[i].args[1] end end
end

describe('mechanic tow order', function()
    it('creates a tow.recovery request for the car beside the boss, paid by the shop', function()
        ask(MECH, { plate = 'BROKE01', reason = 'critical_engine_failure', coords = { x = 0, y = 0, z = 0 } })
        assert_eq(#requests, 1)
        local r = requests[1]
        assert_eq(r.kind, 'tow.recovery')
        assert_eq(r.plate, 'BROKE01')
        assert_eq(r.payer, 'society:mechanic')
        assert_near(r.coords.x, 302.0, 0.01, 'position of the real car, not the client value')
        assert_eq(r.ref.id, 'BROKE01')
        assert_eq(r.meta.reason, 'critical_engine_failure')
    end)

    it('refuses non-mechanics, off-duty mechanics, cars that are not next to them, and spam', function()
        ask(CIV, { plate = 'BROKE01' })
        Mock.players[MECH].PlayerData.job.onduty = false
        ask(MECH, { plate = 'BROKE01' })
        Mock.players[MECH].PlayerData.job.onduty = true
        ask(MECH, { plate = 'NOSUCH' })
        Mock.coords[CAR] = vector3(400.0, 300.0, 30.0)
        ask(MECH, { plate = 'BROKE01' })
        ask(MECH, 'not a table')
        assert_eq(#requests, 0)
        Mock.coords[CAR] = vector3(302.0, 300.0, 30.0)
        ask(MECH, { plate = 'BROKE01' })
        ask(MECH, { plate = 'BROKE01' })
        assert_eq(#requests, 1, 'one order a minute')
    end)
end)

describe('who may bill the shop for a tow', function()
    it('only the boss: a mechanic of any other grade cannot spend the shop account', function()
        ask(STAFF, { plate = 'BROKE01', reason = 'critical_engine_failure' })
        assert_eq(#requests, 0)
        assert_eq(lastNote(STAFF), 'Only the shop boss can order a tow on the shop account')
        Mock.players[STAFF].PlayerData.job.grade = { level = 99 }
        ask(STAFF, { plate = 'BROKE01' })
        assert_eq(#requests, 0, 'a high grade is not the boss')
        Mock.players[STAFF].PlayerData.job.isboss = 'true'                     -- only a real boolean
        ask(STAFF, { plate = 'BROKE01' })
        assert_eq(#requests, 0)
        ask(MECH, { plate = 'BROKE01' })
        assert_eq(#requests, 1)
    end)

    it('a boss demoted or gone off duty while the order is checked orders nothing', function()
        PFMech.EnsureVehicleRestored = function()
            Mock.players[MECH].PlayerData.job.isboss = false                 -- during the saved-state load
            return true
        end
        ask(MECH, { plate = 'BROKE01' })
        assert_eq(#requests, 0)
        Mock.players[MECH].PlayerData.job.isboss = true
        PFMech.EnsureVehicleRestored = function()
            Mock.players[MECH].PlayerData.job.onduty = false
            return true
        end
        ask(MECH, { plate = 'BROKE01' })
        assert_eq(#requests, 0)
    end)

    it("the boss's own shop pays, whatever the client sends", function()
        ask(RIVAL, { plate = 'BROKE01', shop = 'mechanic', payer = 'society:police', reason = '<b>x</b>' })
        assert_eq(#requests, 1)
        assert_eq(requests[1].payer, 'society:bennys')
        assert_eq(requests[1].meta.shop, 'bennys')
        assert_eq(requests[1].meta.reason, 'service_request', 'a reason outside the fixed characters is replaced')
    end)
end)

describe('only a car the server reads as broken', function()
    it('a drivable car is refused, and the refusal does not use up the cooldown', function()
        health[CAR] = { engine = 1000.0, body = 1000.0, tank = 1000.0 }
        Entity(CAR).state.partDamage = { brakes = 99.9, carbattery = 40 }
        ask(MECH, { plate = 'BROKE01', reason = 'critical_engine_failure', engine = 0 })
        assert_eq(#requests, 0, 'the client\'s engine value means nothing')
        assert_eq(lastNote(MECH), 'This car can still be driven: no tow needed')
        health[CAR].engine = TOW.EngineHealthBelow - 1
        ask(MECH, { plate = 'BROKE01' })
        assert_eq(#requests, 1, 'broken now: ordered at once')
    end)

    it('engine, body or tank health below the thresholds, or a worn-out part, count', function()
        local cases = {
            { engine = TOW.EngineHealthBelow - 0.5 },
            { body = TOW.BodyHealthBelow - 0.5 },
            { tank = 0.0 },
            { wear = { carbattery = TOW.FailedPartWear } },
            { wear = { engine_part = 100 } },
        }
        for i, c in ipairs(cases) do
            Mock.clock = Mock.clock + 61
            health[CAR] = { engine = c.engine or 1000.0, body = c.body or 1000.0, tank = c.tank or 1000.0 }
            Entity(CAR).state.partDamage = c.wear
            ask(MECH, { plate = 'BROKE01' })
            assert_eq(#requests, i, 'case ' .. i)
        end
        -- at the threshold itself, and wear just below worn out: still drivable
        Mock.clock = Mock.clock + 61
        health[CAR] = { engine = TOW.EngineHealthBelow, body = TOW.BodyHealthBelow, tank = 1.0 }
        Entity(CAR).state.partDamage = { carbattery = TOW.FailedPartWear - 0.01, bogus = 100 }
        ask(MECH, { plate = 'BROKE01' })
        assert_eq(#requests, #cases)
    end)

    it("the car's saved wear is loaded before it is judged", function()
        health[CAR] = { engine = 1000.0, body = 1000.0 }
        local loaded = 0
        PFMech.EnsureVehicleRestored = function(veh)
            loaded = loaded + 1
            Entity(veh).state.partDamage = { sparkplugs = 100 }                -- what the garage saved
            return true
        end
        ask(MECH, { plate = 'BROKE01' })
        assert_eq(loaded, 1)
        assert_eq(#requests, 1)
    end)
end)

describe('the car must be beside the boss', function()
    it('within the reach, from server positions; a copy of the plate elsewhere does not count', function()
        Mock.coords[CAR] = vector3(300.0 + TOW.Reach + 0.5, 300.0, 30.0)
        ask(MECH, { plate = 'BROKE01', coords = { x = 300.0, y = 300.0, z = 30.0 } })
        assert_eq(#requests, 0)
        assert_eq(lastNote(MECH), 'The car must be right next to you')
        Mock.coords[MECH] = vector3(900.0, 900.0, 30.0)
        Mock.coords[CAR] = vector3(902.0, 900.0, 30.0)
        ask(MECH, { plate = 'BROKE01' })
        assert_eq(#requests, 1)
        assert_near(requests[1].coords.x, 902.0, 0.01)
    end)

    it('a car that drove off while the order was being made is not towed', function()
        PFMech.EnsureVehicleRestored = function()
            Mock.coords[CAR] = vector3(600.0, 300.0, 30.0)                       -- during the load
            return true
        end
        ask(MECH, { plate = 'BROKE01' })
        assert_eq(#requests, 0)
    end)
end)

describe('one order per car at a time', function()
    it('while an order waits on pf-services, the same car and the same boss are refused', function()
        hold = true
        local first = askAsync(MECH, { plate = 'BROKE01' })
        assert_true(waiting ~= nil, 'the first order is waiting')
        assert_eq(#requests, 0)
        ask(RIVAL, { plate = 'BROKE01' })                                         -- another shop's boss, same car
        Mock.clock = Mock.clock + 61
        ask(MECH, { plate = 'BROKE02' })                                          -- the same boss, another car
        assert_eq(#requests, 0)
        assert(coroutine.resume(first))
        assert_eq(coroutine.status(first), 'dead')
        assert_eq(#requests, 1)
        assert_eq(requests[1].plate, 'BROKE01')
        ask(RIVAL, { plate = 'BROKE02' })                                         -- free again
        assert_eq(#requests, 2)
    end)

    it('a failed order frees the car and the boss again', function()
        Mock.exportsByResource['pf-services'].CreateRequest = function() error('pf-services down') end
        ask(MECH, { plate = 'BROKE01' })
        Mock.exportsByResource['pf-services'].CreateRequest = createRequest
        assert_eq(lastNote(MECH), 'No tow service is available')
        ask(RIVAL, { plate = 'BROKE01' })
        assert_eq(#requests, 1)
    end)
end)

describe('the cooldown and the refusals', function()
    it('a failed order costs no cooldown: the boss can order again at once', function()
        Mock.exportsByResource['pf-services'].CreateRequest = function() error('pf-services down') end
        ask(MECH, { plate = 'BROKE01' })
        assert_eq(lastNote(MECH), 'No tow service is available')
        Mock.exportsByResource['pf-services'].CreateRequest = function() return { ok = false, error = 'refused' } end
        ask(MECH, { plate = 'BROKE01' })
        assert_eq(lastNote(MECH), 'No tow service is available')
        Mock.exportsByResource['pf-services'].CreateRequest = createRequest
        ask(MECH, { plate = 'BROKE01' })
        assert_eq(#requests, 1, 'the cooldown was used up by the failures before')
    end)

    it('with pf-services stopped the boss is told, and no cooldown starts', function()
        started['pf-services'] = nil
        ask(MECH, { plate = 'BROKE01' })
        assert_eq(lastNote(MECH), 'No tow service is available', 'it used to say nothing')
        started['pf-services'] = true
        ask(MECH, { plate = 'BROKE01' })
        assert_eq(#requests, 1)
    end)

    it('a tow already on its way (no new request) starts no cooldown either', function()
        Mock.exportsByResource['pf-services'].CreateRequest = function() return { ok = true, id = 9, existing = true } end
        ask(MECH, { plate = 'BROKE01' })
        assert_eq(lastNote(MECH), 'A tow is already on its way for this car')
        Mock.exportsByResource['pf-services'].CreateRequest = createRequest
        ask(MECH, { plate = 'BROKE02' })
        assert_eq(#requests, 1)
    end)

    it('a new request starts the cooldown, and the boss is told how long it runs', function()
        ask(MECH, { plate = 'BROKE01' })
        assert_eq(#requests, 1)
        Mock.clock = Mock.clock + 15
        ask(MECH, { plate = 'BROKE02' })
        assert_eq(#requests, 1)
        assert_eq(lastNote(MECH), 'You can order another tow in 45 s', 'it used to say nothing')
        Mock.clock = Mock.clock + 46
        ask(MECH, { plate = 'BROKE02' })
        assert_eq(#requests, 2)
    end)
end)

describe('the locks come before the first wait', function()
    it("while the car's saved state loads, the same boss and the same car are refused, and told why", function()
        local loads, waitingLoad = 0, nil
        PFMech.EnsureVehicleRestored = function()
            loads = loads + 1
            if loads == 1 and coroutine.isyieldable() then
                waitingLoad = coroutine.running()
                coroutine.yield()                                                -- the database read
            end
            return true
        end
        local first = askAsync(MECH, { plate = 'BROKE01' })
        assert_true(waitingLoad ~= nil, 'the first order waits on the saved-state load')
        ask(MECH, { plate = 'BROKE02' })                                          -- the same boss, another car
        assert_eq(lastNote(MECH), 'Your last tow order is still being made')
        ask(RIVAL, { plate = 'BROKE01' })                                         -- another boss, the same car
        assert_eq(lastNote(RIVAL), 'A tow for this car is already being ordered')
        assert_eq(loads, 1, 'neither got as far as the wait (the locks are taken before it)')
        assert_eq(#requests, 0)
        assert(coroutine.resume(first))
        assert_eq(coroutine.status(first), 'dead')
        assert_eq(#requests, 1)
        assert_eq(requests[1].plate, 'BROKE01')
        assert_eq(requests[1].payer, 'society:mechanic')
        ask(RIVAL, { plate = 'BROKE02' })                                         -- the locks are free again
        assert_eq(#requests, 2)
    end)
end)

describe('one tow rule for the server and the client offer', function()
    it("the shared wear parts are the server's wear parts", function()
        local src = __readfile('[pfscripts]/pf-mechanicjob/server/advanced_systems.lua')
        local block = src:match('local WEAR_PARTS = (%b{})')
        assert_true(block ~= nil, 'WEAR_PARTS found')
        local server = {}
        for key in block:gmatch('([%w_]+)%s?=%s?true') do server[key] = true end
        for key in pairs(server) do assert_true(PFMechTow.WearParts[key], 'shared list has ' .. key) end
        for key in pairs(PFMechTow.WearParts) do assert_true(server[key], 'server list has ' .. key) end
    end)

    -- client/advanced_systems.lua in a sandbox: a diagnostic scan on the car in front of the player
    local CLIENT = '[pfscripts]/pf-mechanicjob/client/advanced_systems.lua'
    local CARV = 900
    local function scan(reading, isboss)
        local toServer, notes = {}, {}
        local noop = function() return nil end
        local bag = { partDamage = reading.wear }
        local qb = setmetatable({ Functions = setmetatable({
            Notify = function(msg) notes[#notes + 1] = msg end,
            Progressbar = function(_, _, _, _, _, _, _, _, _, onFinish) onFinish() end,
            GetPlayerData = function() return { job = { name = 'mechanic', onduty = true, isboss = isboss } } end,
            TriggerCallback = noop,
        }, { __index = QBCoreMock.Functions }) }, { __index = QBCoreMock })
        local handlers = {}
        local own = {
            exports = setmetatable({}, { __index = function() return { GetCoreObject = function() return qb end } end }),
            RegisterNetEvent = function(name, fn) handlers[name] = fn end,
            RegisterCommand = noop, AddEventHandler = noop, CreateThread = noop, Wait = noop,
            TriggerServerEvent = function(name, payload) toServer[#toServer + 1] = { name = name, payload = payload } end,
            PlayerPedId = function() return 1 end,
            GetEntityCoords = function() return vector3(0, 0, 0) end,
            GetClosestVehicle = function() return CARV end,
            DoesEntityExist = function(e) return e == CARV end,
            GetVehicleNumberPlateText = function() return 'BROKE01 ' end,
            GetVehicleEngineHealth = function() return reading.engine or 1000.0 end,
            GetVehicleBodyHealth = function() return reading.body or 1000.0 end,
            GetVehiclePetrolTankHealth = function() return reading.tank or 1000.0 end,
            Entity = function() return { state = bag } end,
        }
        local env = setmetatable(own, { __index = function(_, k)
            local v = _G[k]
            if v ~= nil then return v end
            if type(k) == 'string' and k:match('^%u') then return noop end
        end })
        assert(load(__readfile(CLIENT), '@' .. CLIENT, 't', env))()
        handlers['pf-mechanicjob:client:advanced:useTool']('obd_scanner')
        local tows = {}
        for _, e in ipairs(toServer) do if e.name == 'pf-mechanicjob:server:advanced:requestTow' then tows[#tows + 1] = e.payload end end
        return tows, notes
    end

    it('the boss is offered the order for every broken reading the server accepts', function()
        local cases = {
            { reading = { engine = TOW.EngineHealthBelow - 1 }, reason = 'critical_engine_failure' },
            { reading = { engine = 900.0, body = TOW.BodyHealthBelow - 1 }, reason = 'severe_body_damage' },
            { reading = { tank = 0.0 }, reason = 'ruptured_fuel_tank' },
            { reading = { wear = { carbattery = TOW.FailedPartWear } }, reason = 'failed_part' },
        }
        for i, c in ipairs(cases) do
            local tows = scan(c.reading, true)
            assert_eq(#tows, 1, 'case ' .. i .. ' (only an engine at 30% or less was offered before)')
            assert_eq(tows[1].plate, 'BROKE01')
            assert_eq(tows[1].reason, c.reason)
            -- and the server takes that same car as broken
            Mock.clock = Mock.clock + 61
            health[CAR] = { engine = c.reading.engine or 1000.0, body = c.reading.body or 1000.0, tank = c.reading.tank or 1000.0 }
            Entity(CAR).state.partDamage = c.reading.wear
            ask(MECH, tows[1])
            assert_eq(#requests, i, 'server case ' .. i)
            assert_eq(requests[i].meta.reason, c.reason)
        end
    end)

    it('a drivable car is not offered (the server would refuse it), and a mechanic is pointed to the boss', function()
        local tows = scan({ engine = TOW.EngineHealthBelow, body = TOW.BodyHealthBelow, wear = { carbattery = TOW.FailedPartWear - 1, bogus = 100 } }, true)
        assert_eq(#tows, 0)
        local staffTows, notes = scan({ body = 10.0 }, false)
        assert_eq(#staffTows, 0, 'only the boss orders')
        assert_eq(notes[#notes], 'This car cannot be driven: your shop boss can order a tow')
    end)
end)
