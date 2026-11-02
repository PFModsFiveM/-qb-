-- pf-mechanicjob: a repair cannot be undone by an older in-flight wear report.
-- The driver's game reports a car's part wear as absolute values ('pf_mech:server:setState',
-- server/advanced_systems.lua) and the server keeps the higher of each part, so a report computed
-- before a repair reached the driver used to put the old wear back. The server now keeps a wear
-- epoch per car ('wearEpoch', server-only state bag) that goes up after every repair; a report counts
-- only with the epoch its values were read at (client/damage.lua, client/work_order_vehicles.lua).
-- The state bags here run as FiveM runs them on the server: change handlers first (the bag still
-- holds the old value), then the value is stored and sent to clients (`sent`, in order); every read
-- is a copy.
load_resource('tests/lua/fivem_mocks.lua')
QBCore = QBCoreMock

local function copy(v)
    if type(v) ~= 'table' then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = copy(x) end
    return out
end

local bags, bagHandlers, sent = {}, {}, {}
function AddStateBagChangeHandler(key, _, fn) bagHandlers[#bagHandlers + 1] = { key = key, fn = fn } end
function GetEntityFromStateBagName(name) return tonumber(tostring(name):match('^entity:(%d+)$')) or 0 end
function Entity(e)
    if not bags[e] then
        local data = {}
        local function set(_, key, value)
            for _, h in ipairs(bagHandlers) do
                if h.key == nil or h.key == key then h.fn('entity:' .. e, key, copy(value)) end
            end
            data[key] = copy(value)
            sent[#sent + 1] = { veh = e, key = key, value = copy(value) }
        end
        bags[e] = { state = setmetatable({}, {
            __index = function(_, k) if k == 'set' then return set end return copy(data[k]) end,
            __newindex = function(_, k, v) data[k] = copy(v) end,                -- test setup, nothing sent
        }) }
    end
    return bags[e]
end
local existing = {}
function DoesEntityExist(e) return existing[e] == true end
function GetAllVehicles() local out = {} for e in pairs(existing) do out[#out + 1] = e end return out end
function GetIsVehicleEngineRunning() return false end

local function withInventory(p)
    p.inv = {}
    p.Functions.GetItemByName = function(name)
        local n = p.inv[name]
        if n and n > 0 then return { name = name, amount = n, label = name } end
    end
    p.Functions.RemoveItem = function(name, n)
        n = n or 1
        if (p.inv[name] or 0) < n then return false end
        p.inv[name] = p.inv[name] - n
        return true
    end
    p.Functions.AddItem = function(name, n) p.inv[name] = (p.inv[name] or 0) + (n or 1) return true end
    return p
end

Config = nil
load_resource('[pfscripts]/pf-mechanicjob/config.lua')
load_resource('[pfscripts]/pf-mechanicjob/shared/debug.lua')
Config.Debug = false
Config.AdvancedSystems.Enabled = true
Config.AdvancedSystems.Alignment.Enabled = true
Config.AdvancedSystems.PitBays.Enabled = true
Config.AdvancedSystems.PitBays.ServiceSpeedMultiplier = 0.75
load_resource('[pfscripts]/pf-mechanicjob/shared/performance_parts.lua')
load_resource('[pfscripts]/pf-mechanicjob/server/main.lua')
load_resource('[pfscripts]/pf-mechanicjob/server/repair.lua')
load_resource('[pfscripts]/pf-mechanicjob/server/consumables.lua')
load_resource('[pfscripts]/pf-mechanicjob/server/admin_customs.lua')
load_resource('[pfscripts]/pf-mechanicjob/server/advanced_systems.lua')

local DRIVER, MECH, ADMIN = 1, 2, 3
local CAR = 500
local HERE = vector3(100.0, 100.0, 30.0)

local function st(veh) return Entity(veh).state end
local function epoch(veh) return st(veh).wearEpoch or 0 end
local function report(src, veh, value, e) Mock.fireNet('pf_mech:server:setState', src, veh, 'partDamage', value, e) end
local function useItem(src, name) Mock.useables[name](src, { name = name }) end

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 100000
    Mock.players, Mock.coords, Mock.vehicleOf, Mock.plates, Mock.aces = {}, {}, {}, {}, {}
    Mock.fireEvent('entityRemoved', nil, CAR)                                  -- the server forgets the old car
    bags, sent, existing = {}, {}, { [CAR] = true }
    withInventory(Mock.newPlayer(DRIVER, 'DRIVERCID'))
    withInventory(Mock.newPlayer(MECH, 'MECHCID')).PlayerData.job = { name = 'mechanic', onduty = true, grade = { level = 0 } }
    withInventory(Mock.newPlayer(ADMIN, 'ADMINCID'))
    Mock.aces[ADMIN] = { ['pf.mechanic.admincustoms'] = true }
    Mock.plates[CAR] = 'MYCAR001'
    Mock.coords[DRIVER], Mock.coords[MECH], Mock.coords[ADMIN], Mock.coords[CAR] = HERE, HERE, HERE, HERE
    for _, src in ipairs({ DRIVER, MECH, ADMIN }) do Mock.fireEvent('playerDropped', src) end
    Mock.vehicleOf[DRIVER] = CAR
end

-- Each server repair: what it lowers, and how the mechanic (or admin) does it.
local REPAIRS = {
    { name = 'a part from the repair menu (pf_mech:server:attemptRepair)', part = 'brakes', before = 80, after = 5,
      run = function()
          Mock.players[MECH].inv.brake_pads = 3
          local ok = Mock.callCallback('pf_mech:server:attemptRepair', MECH, CAR, 'brakes', 3)
          assert_true(ok)
      end },
    { name = 'brake pads (pf-mechanicjob:server:applyBrakeRepair)', part = 'brakes', before = 80, after = 30,
      run = function()
          Mock.players[MECH].inv.brake_pads = 2
          Mock.fireNet('pf-mechanicjob:server:applyBrakeRepair', MECH, CAR, 2)
      end },
    { name = 'the alignment rack', part = 'suspension', before = 50, after = 38,
      run = function()
          Mock.players[MECH].inv.alignment_rack_tool = 1
          useItem(MECH, 'alignment_rack_tool')
          Mock.clock = Mock.clock + 20
          Mock.fireNet('pf-mechanicjob:server:advanced:completeAlignment', MECH, CAR)
      end },
    { name = 'an admin reset', part = 'oil', before = 70, after = 0,
      run = function() Mock.fireNet('pf-mechanicjob:server:adminCustoms:vehicleState', ADMIN, CAR, 'resetPartDamage') end },
}

describe('a repair cannot be undone by a wear report computed before it', function()
    for _, r in ipairs(REPAIRS) do
        it(r.name, function()
            st(CAR).partDamage = { [r.part] = r.before - 0.5, coolant = 10 }
            report(DRIVER, CAR, { [r.part] = r.before, coolant = 10 }, epoch(CAR))   -- the driver's wear so far
            assert_eq(st(CAR).partDamage[r.part], r.before)
            local seen = epoch(CAR)                                             -- what the driver's game holds
            r.run()
            assert_eq(st(CAR).partDamage[r.part], r.after, 'repaired')
            assert_true(epoch(CAR) > seen, 'a new wear epoch')
            -- reports the driver's game computed before the repair reached it
            report(DRIVER, CAR, { [r.part] = r.before + 1, coolant = 12 }, seen)
            report(DRIVER, CAR, { [r.part] = r.before + 2 }, seen)
            assert_eq(st(CAR).partDamage[r.part], r.after, 'the old wear does not come back')
            -- once the repair (and its epoch) reached the driver, wear is added again
            report(DRIVER, CAR, { [r.part] = r.after + 1, coolant = 12 }, epoch(CAR))
            assert_eq(st(CAR).partDamage[r.part], r.after + 1)
            assert_eq(st(CAR).partDamage.coolant, 12)
        end)
    end

    it('a new tyre (pf_mech:server:tireReplaced)', function()
        st(CAR).partDamage = { tires = { lf = 60 } }
        report(DRIVER, CAR, { tires = { lf = 61 } }, epoch(CAR))
        local seen = epoch(CAR)
        Mock.callCallback('pf-mechanicjob:server:consumeItem', MECH, 'tire_new')
        Mock.players[MECH].inv.tire_new = 1
        Mock.callCallback('pf-mechanicjob:server:consumeItem', MECH, 'tire_new')
        Mock.clock = Mock.clock + 4
        Mock.fireNet('pf_mech:server:tireReplaced', MECH, CAR, 0)
        assert_eq(st(CAR).partDamage.tires.lf, 0)
        report(DRIVER, CAR, { tires = { lf = 62 } }, seen)
        assert_eq(st(CAR).partDamage.tires.lf, 0)
        report(DRIVER, CAR, { tires = { lf = 0.5 } }, epoch(CAR))
        assert_eq(st(CAR).partDamage.tires.lf, 0.5)
    end)
end)

describe('clients get the new epoch only after the repaired wear', function()
    -- replays what the server sent, in order, as a client receives it: no moment may hold the new
    -- epoch with the old wear (a report computed then would carry both and undo the repair)
    for _, r in ipairs(REPAIRS) do
        it(r.name, function()
            st(CAR).partDamage = { [r.part] = r.before }
            report(DRIVER, CAR, { [r.part] = r.before }, 0)
            local view = { wearEpoch = epoch(CAR), partDamage = st(CAR).partDamage }
            local from = #sent + 1
            r.run()
            assert_true(#sent >= from, 'the repair was sent')
            for i = from, #sent do
                local s = sent[i]
                if s.veh == CAR then view[s.key] = s.value end
                if (view.wearEpoch or 0) > 0 then
                    assert_eq(view.partDamage[r.part], r.after, 'step ' .. (i - from + 1) .. ': new epoch with the old wear')
                end
            end
            assert_true(view.wearEpoch > 0)
        end)
    end
end)

describe('a lowering made outside the repair handlers', function()
    it('is caught by the next report: that report is dropped and the epoch goes up', function()
        st(CAR).partDamage = { brakes = 80 }
        report(DRIVER, CAR, { brakes = 81 }, 0)
        st(CAR):set('partDamage', { brakes = 10 }, true)                    -- no MarkWearRepaired
        assert_eq(epoch(CAR), 0, 'nothing sent ahead of the lowered wear')
        report(DRIVER, CAR, { brakes = 82 }, 0)
        assert_eq(st(CAR).partDamage.brakes, 10)
        assert_eq(epoch(CAR), 1)
        report(DRIVER, CAR, { brakes = 83 }, 0)
        assert_eq(st(CAR).partDamage.brakes, 10, 'every report of the old epoch')
        report(DRIVER, CAR, { brakes = 11 }, 1)
        assert_eq(st(CAR).partDamage.brakes, 11)
    end)

    it('wear the server adds meanwhile (NOS, a restore) is not mistaken for a repair', function()
        st(CAR).partDamage = { brakes = 20 }
        report(DRIVER, CAR, { brakes = 21 }, 0)
        st(CAR):set('partDamage', { brakes = 21, engine_part = 4 }, true)    -- e.g. NOS boost wear
        report(DRIVER, CAR, { brakes = 22, engine_part = 4 }, 0)
        assert_eq(epoch(CAR), 0)
        assert_eq(st(CAR).partDamage.brakes, 22)
    end)
end)

describe('reports of the current epoch', function()
    it('honest reports keep adding wear; any other epoch is refused', function()
        st(CAR).partDamage = { brakes = 20 }
        Mock.players[MECH].inv.brake_pads = 2
        Mock.fireNet('pf-mechanicjob:server:applyBrakeRepair', MECH, CAR, 1)
        Mock.fireNet('pf-mechanicjob:server:applyBrakeRepair', MECH, CAR, 1)
        local now = epoch(CAR)
        assert_true(now >= 1)
        for _, bad in ipairs({ now - 1, now + 1, -1, 0 / 0, math.huge, 'x' }) do
            report(DRIVER, CAR, { brakes = 50 }, bad)
        end
        report(DRIVER, CAR, { brakes = 50 })                                 -- an old client: no epoch
        assert_eq(st(CAR).partDamage.brakes, 0)
        report(DRIVER, CAR, { brakes = 1 }, now)
        report(DRIVER, CAR, { brakes = 2 }, now)
        report(DRIVER, CAR, { brakes = 3 }, tostring(now))
        assert_eq(st(CAR).partDamage.brakes, 3)
    end)

    it('only the server sets the epoch: a report cannot change it', function()
        report(DRIVER, CAR, { brakes = 1, wearEpoch = 9 }, 0)
        Mock.fireNet('pf_mech:server:setState', DRIVER, CAR, 'wearEpoch', 9)
        assert_eq(epoch(CAR), 0)
        assert_eq(st(CAR).partDamage.wearEpoch, nil)
    end)
end)

describe('the client reports the epoch its wear was read at (client/damage.lua)', function()
    -- the driver's game: its own copy of the car's state bags, which the server's changes reach late
    local client = { partDamage = nil, wearEpoch = nil }
    local loops, frame, budget, onWait = {}, 0, 0, nil
    local reports = {}                                                     -- { values, epoch } as sent
    local env = setmetatable({
        TriggerServerEvent = function(name, ...)
            -- straight to the server, from the driver
            local args = { ... }
            if name == 'pf_mech:server:setState' and args[2] == 'partDamage' then
                reports[#reports + 1] = { values = copy(args[3]), epoch = args[4] }
            end
            if name == 'pf_mech:server:setState' then Mock.fireNet(name, DRIVER, ...) end
        end,
        CreateThread = function(fn) loops[#loops + 1] = fn end,
        Wait = function(ms)
            frame = frame + 1
            if onWait then onWait(ms) end
            if frame > budget then error('stop frames') end
        end,
        Entity = function()
            return { state = setmetatable({}, { __index = function(_, k) return copy(client[k]) end }) }
        end,
        SafeStateSet = false,
        exports = setmetatable({}, {
            __call = function() end,
            __index = function() return { GetCoreObject = function() return QBCoreMock end } end,
        }),
        print = function() end,
        math = setmetatable({ random = function(a, b) if b then return a end return 1 end }, { __index = math }),
        PlayerPedId = function() return 7 end,
        IsPedInAnyVehicle = function() return true end,
        GetVehiclePedIsIn = function() return CAR end,
        GetPedInVehicleSeat = function() return 7 end,
        GetIsVehicleEngineRunning = function() return true end,
        DoesEntityExist = function() return true end,
        NetworkGetEntityIsNetworked = function() return true end,
        NetworkGetNetworkIdFromEntity = function(e) return e end,
        GetEntitySpeed = function() return 40.0 end,                       -- about 90 mph
        GetVehicleCurrentRpm = function() return 0.5 end,
        GetVehicleEngineHealth = function() return 1000.0 end,
        GetVehicleNumberPlateText = function() return 'MYCAR001' end,
        GetEntityCoords = function() return vector3(0.0, 0.0, 0.0) end,
    }, { __index = function(_, k)
        local v = _G[k]
        if v ~= nil then return v end
        if type(k) == 'string' and k:match('^%u%l') then return function() return nil end end
    end })
    for _, f in ipairs({ '[pfscripts]/pf-mechanicjob/config.lua', '[pfscripts]/pf-mechanicjob/client/damage.lua' }) do
        assert(load(__readfile(f), '@' .. f, 't', env))()
        if env.Config then env.Config.Debug = false end
    end
    assert_eq(#loops, 5, 'client/damage.lua threads')
    local batteryLoop, wearLoop = loops[2], loops[5]

    local function run(loop, frames)
        frame, budget = 0, frames
        local ok, err = pcall(loop)
        assert_true(not ok and tostring(err):find('stop frames', 1, true), tostring(err))
    end
    local function replicate() client.partDamage, client.wearEpoch = st(CAR).partDamage, st(CAR).wearEpoch end

    it('the driving wear loop sends the epoch it read with the wear', function()
        st(CAR).partDamage = { brakes = 10 }
        Mock.players[MECH].inv.brake_pads = 1
        Mock.fireNet('pf-mechanicjob:server:applyBrakeRepair', MECH, CAR, 1)
        replicate()
        onWait, reports = nil, {}
        run(wearLoop, 2)
        assert_eq(#reports, 1)
        assert_eq(reports[1].epoch, epoch(CAR))
        assert_true(epoch(CAR) >= 1)
        assert_true(st(CAR).partDamage.alternator > 0, 'wear added from the current epoch')
    end)

    it('wear read before a repair is refused, even when sent after it', function()
        st(CAR).partDamage = { carbattery = 90 }
        replicate()
        reports = {}
        -- the battery cuts out: wear sent, a pause, more wear from the same reading
        onWait = function(ms)
            if ms == 2000 then
                Mock.players[MECH].inv.carbattery = 1
                assert_true(Mock.callCallback('pf_mech:server:attemptRepair', MECH, CAR, 'carbattery', 1))
                replicate()                                                -- the new battery reaches the driver
            end
        end
        run(batteryLoop, 4)
        onWait = nil
        assert_eq(#reports, 2, 'one report before the repair, one after')
        assert_eq(reports[1].epoch, 0)
        assert_eq(reports[2].epoch, 0, 'the epoch of the reading, not the one current when sent')
        assert_eq(reports[2].values.carbattery, 95)
        assert_true(epoch(CAR) >= 1)
        assert_eq(st(CAR).partDamage.carbattery, 0, 'the new battery stays new')
    end)
end)
