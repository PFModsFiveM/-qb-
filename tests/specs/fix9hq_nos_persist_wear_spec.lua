-- pf-mechanicjob NOS (server/nos.lua):
--  (a) the car's NOS state is saved to vehicle_diagnostics as soon as it changes (fitted, level
--      falling, emptied, removed). It used to be saved only by the next driving sync or garage
--      store, so a car lost before that came back from the database with a full bottle.
--  (b) boost wear ('pf_mech:nos:applyDamage') only from the driver, onto the car they drive (not a
--      car found by plate text), bounded by what NOS use can cause in the time since the last report.
load_resource('tests/lua/fivem_mocks.lua')
QBCore = QBCoreMock

local states = {}
local stateMeta = { __index = { set = function(self, k, v) rawset(self, k, v) end } }
function Entity(e)
    states[e] = states[e] or { state = setmetatable({}, stateMeta) }
    return states[e]
end
local vehicles, existing, drivers = {}, {}, {}
function GetAllVehicles() return vehicles end
function DoesEntityExist(e) return existing[e] == true end
function GetIsVehicleEngineRunning() return false end
function GetPedInVehicleSeat(veh, seat) if seat == -1 then return drivers[veh] or 0 end return 0 end

-- the database: player_vehicles and vehicle_diagnostics rows by plate
local rows = { veh = {}, diag = {} }
local diagWrites = 0
MySQL.single = { await = function(q, p)
    if q:find('FROM vehicle_diagnostics', 1, true) then return rows.diag[p[1]] end
    if q:find('FROM player_vehicles', 1, true) then return rows.veh[p[1]] end
end }
MySQL.insert = { await = function(q, p)
    local colList = q:match('INSERT INTO vehicle_diagnostics %((.-)%) VALUES')
    if not colList then return 0 end
    local cols = {}
    for c in colList:gmatch('`([%w_]+)`') do cols[#cols + 1] = c end
    local row = rows.diag[p[1]] or {}
    for i, c in ipairs(cols) do row[c] = p[i] end
    rows.diag[p[1]] = row
    diagWrites = diagWrites + 1
    return 1
end }

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
Config.Debug = false
QBCoreMock.Shared.Items.emptynos = { name = 'emptynos', label = 'Empty NOS' }
QBCoreMock.Shared.Items.nos = { name = 'nos', label = 'NOS' }
load_resource('[pfscripts]/pf-mechanicjob/server/garage_sync.lua')
load_resource('[pfscripts]/pf-mechanicjob/server/nos.lua')

local ME, OTHER = 1, 2
local CAR, RESPAWN, COPY = 700, 701, 702
local PLATE = 'NOSCAR1'
local HERE = vector3(10.0, 10.0, 30.0)

local function st(veh) return Entity(veh).state end
local function seat(src, veh, driver)
    Mock.vehicleOf[src] = veh
    if veh and driver then drivers[veh] = src end
end
local function near(a, b) return math.abs(a - b) < 0.0001 end

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 100000
    Mock.players, Mock.coords, Mock.vehicleOf, Mock.plates = {}, {}, {}, {}
    states, drivers = {}, {}
    vehicles = { CAR, RESPAWN, COPY }
    existing = { [CAR] = true, [RESPAWN] = true, [COPY] = true }
    Mock.models = { [CAR] = GetHashKey('sultan'), [RESPAWN] = GetHashKey('sultan'), [COPY] = GetHashKey('sultan') }
    Mock.plates[CAR], Mock.plates[RESPAWN], Mock.plates[COPY] = ' NOSCAR1 ', 'NOSCAR1', 'NOSCAR1'
    withInventory(Mock.newPlayer(ME, 'CID1'))
    withInventory(Mock.newPlayer(OTHER, 'CID2'))
    Mock.coords[ME], Mock.coords[OTHER], Mock.coords[CAR], Mock.coords[RESPAWN], Mock.coords[COPY] = HERE, HERE, HERE, HERE, HERE
    rows = { veh = { [PLATE] = { vehicle = 'sultan', citizenid = 'CID1' } }, diag = {} }
    diagWrites = 0
    for _, v in ipairs({ CAR, RESPAWN, COPY }) do Mock.fireEvent('entityRemoved', nil, v) end
    for _, src in ipairs({ ME, OTHER }) do Mock.fireEvent('playerDropped', src) end
end

-- `src` boosts in `veh` for `seconds`: the server drains the bottle every second (server/nos.lua)
local DRAIN = Config.NOS.levels[1].drainPerSec
local function boostFor(src, veh, seconds)
    Mock.fireNet('pf_mech:nos:boost', src, veh, true)
    for _ = 1, seconds do Mock.clock = Mock.clock + 1; PFMech.NosDrainTick() end
end

-- the car is gone (destroyed / cleaned up / restart) and the same plate is spawned again
local function loseAndRespawn()
    existing[CAR] = nil
    Mock.fireEvent('entityRemoved', nil, CAR)
    Mock.vehicleOf[ME] = RESPAWN
    Mock.fireNet('pf_mech:server:restoreVehicleState', ME, RESPAWN)
    return st(RESPAWN).nos
end

describe('NOS is saved when it changes', function()
    it('an emptied bottle stays empty when the car is lost before any garage save', function()
        rows.diag[PLATE] = { nos_has = 1, nos_level = 100, nos_color = '#FF0000' }
        seat(ME, CAR, true)
        Mock.fireNet('pf_mech:server:restoreVehicleState', ME, CAR)
        assert_true(st(CAR).nos and st(CAR).nos.has, 'the saved bottle is on the car')
        boostFor(ME, CAR, 6)
        assert_eq(rows.diag[PLATE].nos_level, 100 - 6 * DRAIN, 'the falling level is saved')
        boostFor(ME, CAR, 3)                                        -- used up
        assert_eq(st(CAR).nos.has, false)
        assert_eq(rows.diag[PLATE].nos_has, 0, 'the empty bottle is saved at once')
        local nos = loseAndRespawn()
        assert_true(not (nos and nos.has), 'no free refill from the old saved state')
    end)

    it('a half-used bottle comes back at the level it was used down to', function()
        rows.diag[PLATE] = { nos_has = 1, nos_level = 100, nos_color = '#FF0000' }
        seat(ME, CAR, true)
        Mock.fireNet('pf_mech:server:restoreVehicleState', ME, CAR)
        boostFor(ME, CAR, 5)
        Mock.fireNet('pf_mech:nos:boost', ME, CAR, false)          -- the driver lets go
        local writes = diagWrites
        Mock.clock = Mock.clock + 3
        PFMech.NosDrainTick()                                       -- not boosting: nothing drains or is written
        assert_eq(diagWrites, writes)
        assert_eq(st(CAR).nos.level, 100 - 5 * DRAIN)
        local nos = loseAndRespawn()
        assert_true(nos and nos.has)
        assert_eq(nos.level, 100 - 5 * DRAIN)
    end)

    it('fitting a bottle is saved, with the owner, and a removed empty bottle too', function()
        seat(ME, CAR, true)
        Mock.players[ME].inv.nos = 1
        Mock.useables.nos(ME, { name = 'nos' })
        Mock.clock = Mock.clock + 4
        Mock.fireNet('pf_mech:nos:consumeBottle', ME, CAR)
        assert_true(st(CAR).nos.has)
        assert_eq(rows.diag[PLATE].nos_has, 1)
        assert_eq(rows.diag[PLATE].nos_level, Config.NOS.capacity)
        assert_eq(rows.diag[PLATE].citizenid, 'CID1')
        boostFor(ME, CAR, 9)                                        -- used up
        assert_eq(rows.diag[PLATE].nos_level, 0)
        assert_eq(rows.diag[PLATE].nos_has, 0)
        Mock.fireNet('pf_mech:nos:giveEmpty', ME, CAR)
        assert_eq(Mock.players[ME].inv.emptynos, 1)
        -- a saved car still carrying an empty bottle (from before the server drain): taken off
        st(CAR).nos = { has = true, level = 0 }
        Mock.players[ME].inv.nos = 1
        Mock.useables.nos(ME, { name = 'nos' })
        Mock.clock = Mock.clock + 4
        Mock.fireNet('pf_mech:nos:consumeBottle', ME)                -- (an old client: takes the bottle only)
        Mock.fireNet('pf_mech:nos:removeEmpty', ME, CAR)
        assert_eq(st(CAR).nos, nil)
        assert_eq(rows.diag[PLATE].nos_has, 0)
        assert_eq(Mock.players[ME].inv.emptynos, 2)
    end)

    it('a copy of the plate or a car nobody owns writes nothing', function()
        rows.diag[PLATE] = { nos_has = 1, nos_level = 60 }
        seat(ME, CAR, true)
        Mock.fireNet('pf_mech:server:restoreVehicleState', ME, CAR)    -- CAR carries the plate
        seat(OTHER, COPY, true)
        Entity(COPY).state.nos = { has = true, level = 50 }
        boostFor(OTHER, COPY, 5)                                     -- the copy is used up
        assert_eq(st(COPY).nos.has, false)
        assert_eq(rows.diag[PLATE].nos_has, 1)
        assert_eq(rows.diag[PLATE].nos_level, 60)

        rows.veh[PLATE] = nil
        rows.diag[PLATE] = nil
        Mock.fireEvent('entityRemoved', nil, CAR)
        Entity(CAR).state.nos = { has = true, level = 50 }
        boostFor(ME, CAR, 5)
        assert_eq(rows.diag[PLATE], nil, 'not a player car: no row')
    end)
end)

describe('NOS wear reports', function()
    it('a passenger cannot report wear', function()
        seat(ME, CAR, true)
        seat(OTHER, CAR, false)
        Mock.fireNet('pf_mech:nos:applyDamage', OTHER, PLATE, { engine_part = 1, axle = 1 })
        assert_eq(st(CAR).partDamage, nil)
        Mock.fireNet('pf_mech:nos:applyDamage', ME, PLATE, { engine_part = 1 })
        assert_true(near(st(CAR).partDamage.engine_part, 1))
    end)

    it("wear goes onto the car the driver is in, not another car with the same plate text", function()
        vehicles = { COPY, CAR }
        seat(ME, CAR, true)
        Mock.fireNet('pf_mech:nos:applyDamage', ME, PLATE, { sparkplugs = 1 })
        assert_true(near(st(CAR).partDamage.sparkplugs, 1))
        assert_eq(st(COPY).partDamage, nil)
        Mock.fireNet('pf_mech:nos:applyDamage', ME, 'OTHERPL', { sparkplugs = 1 })   -- not this car's plate
        assert_true(near(st(CAR).partDamage.sparkplugs, 1))
    end)

    it('nonsense values are ignored', function()
        seat(ME, CAR, true)
        Mock.fireNet('pf_mech:nos:applyDamage', ME, PLATE, { engine_part = 0 / 0, sparkplugs = math.huge,
            fuel_injector = -5, oil = '3', axle = 101, brakes = 5 })
        assert_eq(st(CAR).partDamage, nil)
        Mock.fireNet('pf_mech:nos:applyDamage', ME, PLATE, 'x')
        Mock.fireNet('pf_mech:nos:applyDamage', ME, { PLATE }, { oil = 1 })
        assert_eq(st(CAR).partDamage, nil)
    end)

    it('a report adds no more than NOS use can cause in the time since the last one', function()
        local d3 = Config.NOS.levels[3].damagePerSec
        local perSec = (d3.engine_part + d3.heatPenalty) * 2       -- the server allows twice the top rate
        local burst = perSec * 4
        seat(ME, CAR, true)
        Mock.fireNet('pf_mech:nos:applyDamage', ME, PLATE, { engine_part = 100 })
        assert_true(near(st(CAR).partDamage.engine_part, burst), 'one report: at most a short burst')
        Mock.fireNet('pf_mech:nos:applyDamage', ME, PLATE, { engine_part = 50 })
        Mock.fireNet('pf_mech:nos:applyDamage', ME, PLATE, { engine_part = 50 })
        assert_true(near(st(CAR).partDamage.engine_part, burst), 'no time passed: nothing more')
        Mock.clock = Mock.clock + 2
        Mock.fireNet('pf_mech:nos:applyDamage', ME, PLATE, { engine_part = 50 })
        assert_true(near(st(CAR).partDamage.engine_part, burst + perSec * 2), 'two seconds of wear')
        Mock.clock = Mock.clock + 1000
        Mock.fireNet('pf_mech:nos:applyDamage', ME, PLATE, { engine_part = 50 })
        assert_true(near(st(CAR).partDamage.engine_part, burst * 2 + perSec * 2), 'a long pause still allows one burst only')
    end)

    it('honest reports every 2 s are applied in full', function()
        local d3 = Config.NOS.levels[3].damagePerSec
        seat(ME, CAR, true)
        Entity(CAR).state.partDamage = { engine_part = 10, brakes = 30 }
        local per = { engine_part = (d3.engine_part + d3.heatPenalty) * 2, sparkplugs = d3.sparkplugs * 2,
            fuel_injector = d3.fuel_injector * 2, oil = d3.engine_oil * 2, axle = d3.axle * 2 }
        for _ = 1, 5 do
            Mock.clock = Mock.clock + 2
            Mock.fireNet('pf_mech:nos:applyDamage', ME, PLATE, per)
        end
        local pd = st(CAR).partDamage
        assert_true(near(pd.engine_part, 10 + per.engine_part * 5))
        assert_true(near(pd.sparkplugs, per.sparkplugs * 5))
        assert_true(near(pd.axle, per.axle * 5))
        assert_eq(pd.brakes, 30, 'other parts kept')
    end)
end)
