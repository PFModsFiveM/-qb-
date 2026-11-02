-- pf-mechanicjob, sv_stateBagStrictMode: the vehicle state bags 'nos', 'pfDriftTires',
-- 'partDamage' and 'mileage' are set by the server only. Clients ask; the server checks the car
-- (in it / beside it / driving it), the item, the timing, the value, and who is asking:
--   NOS fitting, boost level, empty bottle, removing an empty (server/nos.lua)
--   admin customs changes (server/admin_customs.lua)
--   drift tyres fitted as a performance part (server/main.lua)
--   alignment rack (server/advanced_systems.lua)
--   driver wear / mileage reports 'pf_mech:server:setState' (server/advanced_systems.lua)
load_resource('tests/lua/fivem_mocks.lua')
QBCore = QBCoreMock

local states = {}
local stateMeta = { __index = { set = function(self, k, v) rawset(self, k, v) end } }
function Entity(e)
    states[e] = states[e] or { state = setmetatable({}, stateMeta) }
    return states[e]
end
local vehicles, existing, engineOn, drivers = {}, {}, {}, {}
function GetAllVehicles() return vehicles end
function DoesEntityExist(e) return existing[e] == true end
function GetIsVehicleEngineRunning(v) return engineOn[v] == true end
function GetPedInVehicleSeat(veh, seat) if seat == -1 then return drivers[veh] or 0 end return 0 end

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
QBCoreMock.Shared.Items.emptynos = { name = 'emptynos', label = 'Empty NOS' }
QBCoreMock.Shared.Items.nos = { name = 'nos', label = 'NOS' }
load_resource('[pfscripts]/pf-mechanicjob/shared/performance_parts.lua')
load_resource('[pfscripts]/pf-mechanicjob/server/main.lua')
load_resource('[pfscripts]/pf-mechanicjob/server/nos.lua')
load_resource('[pfscripts]/pf-mechanicjob/server/advanced_systems.lua')
load_resource('[pfscripts]/pf-mechanicjob/server/admin_customs.lua')
PFMech.SchemaReady = true
-- pf_mech_fitted_parts (the performance part handlers): nothing fitted yet, every write lands
local baseScalar, baseQuery = MySQL.scalar, MySQL.query
MySQL.scalar = { await = function(q, p) if q:find('pf_mech_fitted_parts', 1, true) then return nil end return baseScalar.await(q, p) end }
MySQL.query = { await = function(q, p) if q:find('pf_mech_fitted_parts', 1, true) then return {} end return baseQuery.await(q, p) end }

local ME, OTHER, ADMIN = 1, 2, 3
local CAR, OTHER_CAR = 500, 501
local HERE = vector3(100.0, 100.0, 30.0)
local CAP = Config.NOS.capacity or 100

local function st(veh) return Entity(veh).state end
local function count(src, item) return Mock.players[src].inv[item] or 0 end
local function seat(src, veh) Mock.vehicleOf[src] = veh; if veh then drivers[veh] = src end end
local function useItem(src, name) Mock.useables[name](src, { name = name }) end

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 100000
    Mock.players, Mock.coords, Mock.vehicleOf, Mock.plates, Mock.aces = {}, {}, {}, {}, {}
    states, engineOn, drivers = {}, {}, {}
    vehicles = { CAR, OTHER_CAR }
    existing = { [CAR] = true, [OTHER_CAR] = true }
    withInventory(Mock.newPlayer(ME)).PlayerData.job = { name = 'mechanic', onduty = true, grade = { level = 0 } }
    Mock.players[ME].inv.toolbox = 1
    withInventory(Mock.newPlayer(OTHER))
    withInventory(Mock.newPlayer(ADMIN))
    Mock.aces[ADMIN] = { ['pf.mechanic.admincustoms'] = true }
    Mock.plates[CAR], Mock.plates[OTHER_CAR] = 'MYCAR001', 'FAR00001'
    Mock.coords[ME], Mock.coords[OTHER], Mock.coords[ADMIN], Mock.coords[CAR] = HERE, HERE, HERE, HERE
    Mock.coords[OTHER_CAR] = vector3(900.0, 900.0, 30.0)
    for _, src in ipairs({ ME, OTHER, ADMIN }) do Mock.fireEvent('playerDropped', src) end
    -- fresh cars each test (the server forgets what it knew about the old ones, e.g. their wear)
    for _, v in ipairs({ CAR, OTHER_CAR }) do Mock.fireEvent('entityRemoved', nil, v) end
end

describe('NOS fitting', function()
    it('the server fits the bottle it takes, after the fitting time', function()
        Mock.players[ME].inv.nos = 1
        useItem(ME, 'nos')
        Mock.fireNet('pf_mech:nos:consumeBottle', ME, CAR)            -- straight away
        assert_eq(st(CAR).nos, nil, 'too soon: the progress bar has not run')
        assert_eq(count(ME, 'nos'), 1)
        Mock.clock = Mock.clock + 5
        Mock.fireNet('pf_mech:nos:consumeBottle', ME, CAR)
        assert_eq(st(CAR).nos.has, true)
        assert_eq(st(CAR).nos.level, CAP)
        assert_eq(st(CAR).nos.levelSel, 1)
        assert_eq(count(ME, 'nos'), 0)
        Mock.fireNet('pf_mech:nos:giveEmpty', ME)
        assert_eq(count(ME, 'emptynos'), 1, 'one empty owed for the bottle taken')
    end)

    it('no bottle used, a car far away, a running engine or NOS already fitted: nothing', function()
        Mock.players[ME].inv.nos = 3
        Mock.fireNet('pf_mech:nos:consumeBottle', ME, CAR)            -- never used the item
        useItem(ME, 'nos')
        Mock.clock = Mock.clock + 5
        Mock.fireNet('pf_mech:nos:consumeBottle', ME, OTHER_CAR)      -- 900 m away
        engineOn[CAR] = true
        Mock.fireNet('pf_mech:nos:consumeBottle', ME, CAR)
        assert_eq(st(CAR).nos, nil)
        assert_eq(st(OTHER_CAR).nos, nil)
        engineOn[CAR] = false
        st(CAR).nos = { has = true, level = 40 }
        Mock.fireNet('pf_mech:nos:consumeBottle', ME, CAR)
        assert_eq(st(CAR).nos.level, 40, 'already fitted')
        assert_eq(count(ME, 'nos'), 3, 'no bottle taken by a refused fitting')
    end)

    it('a fitting without the bottle in the inventory sets nothing', function()
        useItem(ME, 'nos')        -- the item handler refuses: no bottle
        Mock.players[ME].inv.nos = 0
        Mock.clock = Mock.clock + 5
        Mock.fireNet('pf_mech:nos:consumeBottle', ME, CAR)
        assert_eq(st(CAR).nos, nil)
    end)
end)

describe('NOS while driving', function()
    it('only the driver picks the boost level, 1 to 3', function()
        st(CAR).nos = { has = true, level = 80, levelSel = 1 }
        Mock.fireNet('pf_mech:nos:setLevelSel', OTHER, CAR, 3)          -- not in the car
        Mock.vehicleOf[OTHER] = CAR                                     -- a passenger
        seat(ME, CAR)
        Mock.fireNet('pf_mech:nos:setLevelSel', OTHER, CAR, 3)
        assert_eq(st(CAR).nos.levelSel, 1)
        for _, bad in ipairs({ 0, 4, 1.5, 'x' }) do Mock.fireNet('pf_mech:nos:setLevelSel', ME, CAR, bad) end
        assert_eq(st(CAR).nos.levelSel, 1)
        Mock.fireNet('pf_mech:nos:setLevelSel', ME, CAR, 2)
        assert_eq(st(CAR).nos.levelSel, 2)
        assert_eq(st(CAR).nos.level, 80, 'the rest of the state is kept')
    end)

    it('the boost level change is rate limited', function()
        st(CAR).nos = { has = true, level = 80, levelSel = 1 }
        seat(ME, CAR)
        for i = 1, 15 do Mock.fireNet('pf_mech:nos:setLevelSel', ME, CAR, (i % 3) + 1) end
        local kept = st(CAR).nos.levelSel
        Mock.fireNet('pf_mech:nos:setLevelSel', ME, CAR, kept == 3 and 1 or 3)
        assert_eq(st(CAR).nos.levelSel, kept, '16th in 5 s ignored')
    end)

    it('a bottle with gas left is never emptied on request; the server drain empties it', function()
        st(CAR).nos = { has = true, level = 30, color = '#FF0000', levelSel = 1 }
        Mock.fireNet('pf_mech:nos:giveEmpty', OTHER, CAR)
        seat(ME, CAR)
        Mock.fireNet('pf_mech:nos:giveEmpty', ME, CAR)
        assert_eq(st(CAR).nos.has, true, 'the driver cannot empty it either')
        assert_eq(st(CAR).nos.level, 30)
        Mock.fireNet('pf_mech:nos:boost', ME, CAR, true)
        for _ = 1, 5 do Mock.clock = Mock.clock + 1; PFMech.NosDrainTick() end
        assert_eq(st(CAR).nos.has, false)
        assert_eq(st(CAR).nos.level, 0)
        assert_eq(st(CAR).nos.color, '#FF0000')
        Mock.fireNet('pf_mech:nos:giveEmpty', ME, CAR)
        assert_eq(count(ME, 'emptynos'), 0, 'no empty without a bottle the server took')
    end)

    it('removing an empty bottle needs the player at that car and an empty owed', function()
        Mock.players[ME].inv.nos = 1
        useItem(ME, 'nos')
        Mock.clock = Mock.clock + 5
        Mock.fireNet('pf_mech:nos:consumeBottle', ME, CAR)
        st(CAR).nos.level = 0
        st(OTHER_CAR).nos = { has = true, level = 0 }
        Mock.fireNet('pf_mech:nos:removeEmpty', ME, OTHER_CAR)          -- far away
        assert_true(st(OTHER_CAR).nos ~= nil)
        Mock.fireNet('pf_mech:nos:removeEmpty', OTHER, CAR)             -- beside it, nothing owed
        assert_true(st(CAR).nos ~= nil)
        Mock.fireNet('pf_mech:nos:removeEmpty', ME, CAR)
        assert_eq(st(CAR).nos, nil)
        assert_eq(count(ME, 'emptynos'), 1)
    end)
end)

describe('admin customs', function()
    local function admin(src, veh, action, value) Mock.fireNet('pf-mechanicjob:server:adminCustoms:vehicleState', src, veh, action, value) end

    it('a non-admin, or an admin far from the car, changes nothing', function()
        admin(ME, CAR, 'nosInstall')
        admin(ME, CAR, 'drift', true)
        admin(ADMIN, OTHER_CAR, 'nosInstall')
        assert_eq(st(CAR).nos, nil)
        assert_eq(st(CAR).pfDriftTires, nil)
        assert_eq(st(OTHER_CAR).nos, nil)
    end)

    it('an admin at the car: NOS install, level, removal', function()
        admin(ADMIN, CAR, 'nosLevel', 2)
        assert_eq(st(CAR).nos, nil, 'no level without NOS')
        admin(ADMIN, CAR, 'nosInstall')
        assert_eq(st(CAR).nos.has, true)
        assert_eq(st(CAR).nos.level, CAP)
        admin(ADMIN, CAR, 'nosLevel', 5)
        admin(ADMIN, CAR, 'nosLevel', 'x')
        assert_eq(st(CAR).nos.levelSel, 1)
        admin(ADMIN, CAR, 'nosLevel', 3)
        assert_eq(st(CAR).nos.levelSel, 3)
        admin(ADMIN, CAR, 'nosRemove')
        assert_eq(st(CAR).nos, nil)
    end)

    it('an admin at the car: drift tyres, part damage and mileage resets', function()
        admin(ADMIN, CAR, 'drift', 'yes')
        assert_eq(st(CAR).pfDriftTires, nil, 'not a boolean')
        admin(ADMIN, CAR, 'drift', true)
        assert_eq(st(CAR).pfDriftTires, true)
        admin(ADMIN, CAR, 'drift', false)
        assert_eq(st(CAR).pfDriftTires, false)
        st(CAR).partDamage = { brakes = 70, oil = 33.5 }
        st(CAR).mileage = 1234
        admin(ADMIN, CAR, 'resetPartDamage')
        admin(ADMIN, CAR, 'resetMileage')
        assert_eq(st(CAR).partDamage.brakes, 0)
        assert_eq(st(CAR).partDamage.oil, 0)
        assert_eq(st(CAR).partDamage.engine_part, 0)
        assert_eq(st(CAR).mileage, 0)
    end)
end)

describe('drift tyres fitted as a performance part', function()
    it('the server sets the flag when it takes the part; no part, no flag', function()
        Mock.fireNet('pf_mech:server:applyPerformanceUpgrade', ME, { item = 'drifttires', vehicle = CAR, modType = -101, isToggle = true })
        assert_eq(st(CAR).pfDriftTires, nil, 'no part in the inventory')
        Mock.players[ME].inv.turbo = 1
        Mock.fireNet('pf_mech:server:applyPerformanceUpgrade', ME, { item = 'turbo', vehicle = CAR, modType = -101, isToggle = true })
        assert_eq(st(CAR).pfDriftTires, nil, 'another part, whatever mod type the client says')
        Mock.players[ME].inv.drifttires = 1
        Mock.fireNet('pf_mech:server:applyPerformanceUpgrade', ME, { item = 'drifttires', vehicle = OTHER_CAR, modType = -101, isToggle = true })
        assert_eq(st(OTHER_CAR).pfDriftTires, nil, 'a car far away')
        Mock.fireNet('pf_mech:server:applyPerformanceUpgrade', ME, { item = 'drifttires', vehicle = CAR, modType = -101, isToggle = true })
        assert_eq(st(CAR).pfDriftTires, true)
        assert_eq(count(ME, 'drifttires'), 0)
    end)
end)

describe('alignment rack', function()
    local function complete(src, veh) Mock.fireNet('pf-mechanicjob:server:advanced:completeAlignment', src, veh) end

    it('lowers suspension and axle wear once per use, after the rack has run', function()
        Mock.players[ME].inv.alignment_rack_tool = 1
        st(CAR).partDamage = { suspension = 50, axle = 40, brakes = 20 }
        complete(ME, CAR)                                  -- tool never used
        useItem(ME, 'alignment_rack_tool')
        complete(ME, CAR)                                  -- straight away
        assert_eq(st(CAR).partDamage.suspension, 50)
        useItem(ME, 'alignment_rack_tool')
        Mock.clock = Mock.clock + 20
        complete(ME, CAR)
        assert_eq(st(CAR).partDamage.suspension, 38)
        assert_eq(st(CAR).partDamage.axle, 31)
        assert_eq(st(CAR).partDamage.brakes, 20)
        complete(ME, CAR)                                  -- again without a new use
        assert_eq(st(CAR).partDamage.suspension, 38)
    end)

    it('not for a car far away, nor without the tool', function()
        st(OTHER_CAR).partDamage = { suspension = 50 }
        st(CAR).partDamage = { suspension = 50 }
        Mock.players[ME].inv.alignment_rack_tool = 1
        useItem(ME, 'alignment_rack_tool')
        Mock.clock = Mock.clock + 20
        complete(ME, OTHER_CAR)
        assert_eq(st(OTHER_CAR).partDamage.suspension, 50)
        useItem(ME, 'alignment_rack_tool')
        Mock.players[ME].inv.alignment_rack_tool = 0
        Mock.clock = Mock.clock + 20
        complete(ME, CAR)
        assert_eq(st(CAR).partDamage.suspension, 50)
    end)
end)

describe("driver wear and mileage reports ('pf_mech:server:setState')", function()
    local function report(src, veh, key, value) Mock.fireNet('pf_mech:server:setState', src, veh, key, value) end

    it('the driver adds wear; a report never repairs a part', function()
        seat(ME, CAR)
        st(CAR).partDamage = { brakes = 30, oil = 10 }
        report(ME, CAR, 'partDamage', { brakes = 32.456, oil = 0, axle = 5, bogus = 99, tires = { lf = 12, ['../x'] = 50 } })
        local pd = st(CAR).partDamage
        assert_eq(pd.brakes, 32.46)
        assert_eq(pd.oil, 10, 'not repaired by a report')
        assert_eq(pd.axle, 5)
        assert_eq(pd.bogus, nil)
        assert_eq(pd.tires.lf, 12)
        assert_eq(pd.tires['../x'], nil)
        report(ME, CAR, 'partDamage', { brakes = 500 })
        assert_eq(st(CAR).partDamage.brakes, 100, 'capped at 100')
    end)

    it("someone else's car: never from outside it (work-order cars: mechanic_workorder_wear_spec)", function()
        st(CAR).partDamage = { brakes = 30 }
        st(OTHER_CAR).partDamage = { brakes = 30 }
        report(OTHER, OTHER_CAR, 'partDamage', { brakes = 90 })       -- far away
        assert_eq(st(OTHER_CAR).partDamage.brakes, 30)
        seat(ME, CAR)
        report(OTHER, CAR, 'partDamage', { brakes = 90 })             -- someone drives it
        assert_eq(st(CAR).partDamage.brakes, 30)
        Mock.vehicleOf[ME], drivers[CAR] = nil, nil
        report(OTHER, CAR, 'partDamage', { brakes = 90 })             -- a parked car, from beside it
        report(ME, CAR, 'partDamage', { brakes = 90 })                -- an on-duty mechanic, no work order
        assert_eq(st(CAR).partDamage.brakes, 30)
    end)

    it('mileage: the driver only, never down, never faster than a car drives', function()
        st(CAR).mileage = 1000
        report(ME, CAR, 'mileage', 1000.3)                            -- not the driver
        assert_eq(st(CAR).mileage, 1000)
        seat(ME, CAR)
        report(ME, CAR, 'mileage', 1000.3)
        assert_eq(st(CAR).mileage, 1000.3)
        report(ME, CAR, 'mileage', 900)
        assert_eq(st(CAR).mileage, 1000.3, 'never down')
        report(ME, CAR, 'mileage', 1500)
        assert_eq(st(CAR).mileage, 1000.3, 'a jump')
        Mock.clock = Mock.clock + 10
        report(ME, CAR, 'mileage', 1001.9)                           -- 1.6 mi in 10 s is possible
        assert_eq(st(CAR).mileage, 1001.9)
        for _, bad in ipairs({ 'far', 0 / 0, math.huge }) do report(ME, CAR, 'mileage', bad) end
        assert_eq(st(CAR).mileage, 1001.9)
    end)

    it('a report computed before the alignment or an admin reset cannot undo it (wear epoch)', function()
        local function reportAt(e, value) Mock.fireNet('pf_mech:server:setState', ME, CAR, 'partDamage', value, e) end
        seat(ME, CAR)
        st(CAR).partDamage = { suspension = 50, oil = 40 }
        reportAt(0, { suspension = 50.5, oil = 40 })
        local seen = st(CAR).wearEpoch or 0
        Mock.players[ME].inv.alignment_rack_tool = 1
        useItem(ME, 'alignment_rack_tool')
        Mock.clock = Mock.clock + 20
        Mock.fireNet('pf-mechanicjob:server:advanced:completeAlignment', ME, CAR)
        assert_eq(st(CAR).partDamage.suspension, 38.5)
        reportAt(seen, { suspension = 51, oil = 41 })                 -- in flight from before the rack
        assert_eq(st(CAR).partDamage.suspension, 38.5, 'the alignment stays')
        assert_eq(st(CAR).partDamage.oil, 40)
        reportAt(st(CAR).wearEpoch, { suspension = 39, oil = 41 })
        assert_eq(st(CAR).partDamage.oil, 41, 'reports of the new epoch count')

        seen = st(CAR).wearEpoch
        Mock.fireNet('pf-mechanicjob:server:adminCustoms:vehicleState', ADMIN, CAR, 'resetPartDamage')
        reportAt(seen, { suspension = 40, oil = 42 })
        assert_eq(st(CAR).partDamage.oil, 0, 'the reset stays')
        assert_eq(st(CAR).partDamage.suspension, 0)
        reportAt(st(CAR).wearEpoch, { oil = 0.2 })
        assert_eq(st(CAR).partDamage.oil, 0.2)
    end)

    it('other keys and other value types are refused', function()
        seat(ME, CAR)
        report(ME, CAR, 'nos', { has = true, level = 100 })
        report(ME, CAR, 'pfDriftTires', true)
        report(ME, CAR, 'partDamage', 'all')
        assert_eq(st(CAR).nos, nil)
        assert_eq(st(CAR).pfDriftTires, nil)
        assert_eq(st(CAR).partDamage, nil)
    end)
end)

describe('NOS client (client/nos.lua)', function()
    -- one client game: the boost loop runs frame by frame; nothing here may write a state bag
    local toServer, writes, notes = {}, {}, {}
    local frame, budget = 0, 0
    local pressed, justPressed = {}, {}
    local carNos = {}
    local loops = {}
    local function bag(store)
        return setmetatable({}, {
            __index = function(_, k)
                if k == 'set' then return function(_, key, v, r) writes[#writes + 1] = { key, v, r } end end
                return store[k]
            end,
        })
    end
    local env = setmetatable({
        TriggerServerEvent = function(name, ...) toServer[#toServer + 1] = { name = name, args = { ... } } end,
        TriggerEvent = function() end,
        RegisterNetEvent = RegisterNetEvent,
        CreateThread = function(fn) loops[#loops + 1] = fn end,
        Wait = function()
            frame = frame + 1
            if frame > budget then error('stop frames') end
        end,
        GetGameTimer = function() return frame * 17 end,
        Entity = function() return { state = bag(carNos) } end,
        PlayerPedId = function() return 7 end,
        IsPedInAnyVehicle = function() return true end,
        GetVehiclePedIsIn = function() return CAR end,
        GetPedInVehicleSeat = function() return 7 end,
        GetIsVehicleEngineRunning = function() return false end,
        IsControlPressed = function(_, key) return pressed[key] == true end,
        IsControlJustPressed = function(_, key) local v = justPressed[key]; justPressed[key] = nil; return v == true end,
        GetEntitySpeed = function() return 30.0 end,                 -- about 67 mph
        GetEntityBoneIndexByName = function() return -1 end,
        GetEntityForwardVector = function() return vector3(0.0, 1.0, 0.0) end,
        GetVehicleNumberPlateText = function() return ' MYCAR001 ' end,
        GetVehicleCurrentGear = function() return 3 end,
        GetVehicleEngineTemperature = function() return 90.0 end,
        GetVehicleEngineHealth = function() return 1000.0 end,
        HasNamedPtfxAssetLoaded = function() return true end,
        HasAnimDictLoaded = function() return true end,
        NetworkHasControlOfEntity = function() return true end,
        NetworkGetNetworkIdFromEntity = function(e) return e + 1000 end,
        DoesParticleFxLoopedExist = function() return false end,
    }, { __index = function(_, k)
        local v = _G[k]
        if v ~= nil then return v end
        if type(k) == 'string' and k:match('^%u%l') then return function() return nil end end
    end })
    QBCoreMock.Functions.Notify = function(msg) notes[#notes + 1] = msg end
    QBCoreMock.Functions.Progressbar = function(_, _, _, _, _, _, _, _, _, onFinish) onFinish() end
    for _, f in ipairs({ '[pfscripts]/pf-mechanicjob/config.lua', '[pfscripts]/pf-mechanicjob/client/nos.lua' }) do
        assert(load(__readfile(f), '@' .. f, 't', env))()
        if env.Config then env.Config.HasTurbo = function() return true end; env.Config.Debug = false end
    end
    local keys = env.Config.NOS.keys or {}
    local BOOST, UP = keys.boost or 21, keys.levelUp or 172
    local boostLoop = loops[#loops]

    local function run(frames)
        budget = frame + frames
        pcall(boostLoop)
    end
    local function sent(name)
        local out = {}
        for _, e in ipairs(toServer) do if e.name == name then out[#out + 1] = e end end
        return out
    end
    local function reset(nos)
        toServer, writes, notes, pressed, justPressed = {}, {}, {}, {}, {}
        for k in pairs(carNos) do carNos[k] = nil end
        carNos.nos = nos
    end

    it('fitting asks the server with the car and writes nothing', function()
        reset(nil)
        Mock.netHandlers['pf_mech:nos:install']()
        local ev = sent('pf_mech:nos:consumeBottle')
        assert_eq(#ev, 1)
        assert_eq(ev[1].args[1], CAR + 1000)
        assert_eq(#writes, 0)
    end)

    it('boost level and boosting are reported (the server drains), never written', function()
        reset({ has = true, level = 100, levelSel = 1 })
        justPressed[UP] = true
        run(2)
        local sel = sent('pf_mech:nos:setLevelSel')
        assert_eq(#sel, 1)
        assert_eq(sel[1].args[1], CAR + 1000)
        assert_eq(sel[1].args[2], 2)
        assert_eq(notes[#notes], 'NOS Level 2', 'shown at once, before the server answers')
        -- a few seconds of boost, then the key is let go (one run of the loop: its state is kept)
        local stopAt = frame + 200
        pressed = setmetatable({}, { __index = function(_, k) if k == BOOST then return frame < stopAt end end })
        run(260)
        local all = sent('pf_mech:nos:boost')
        assert_eq(#all, 2, 'the start and the stop are reported once each')
        assert_eq(all[1].args[1], CAR + 1000)
        assert_eq(all[1].args[2], true)
        assert_eq(all[2].args[2], false)
        assert_eq(#sent('pf_mech:nos:updateLevel'), 0, 'no level reports: the level is the server\'s')
        assert_eq(#writes, 0, 'no state bag written')
    end)

    it('an empty bottle is reported to the server with the car', function()
        reset({ has = true, level = 1.0, levelSel = 1 })
        pressed[BOOST] = true
        run(40)
        local ev = sent('pf_mech:nos:giveEmpty')
        assert_eq(#ev, 1)
        assert_eq(ev[1].args[1], CAR + 1000)
        assert_eq(#writes, 0)
    end)
end)
