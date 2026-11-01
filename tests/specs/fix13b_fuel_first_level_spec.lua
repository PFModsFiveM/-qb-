-- pfm-fuel: a car with no shared fuel level gets its first one from the server, never from its
-- driver's client: the level stored for the plate the server sees (player_vehicles.fuel), else
-- Config.DefaultFuel (a new, job, rented or stolen car). Batch 13 took the driver's first report,
-- so a modded driver could fill any car it had just got into. The lookup waits on the database,
-- so it runs under the car's lock (a refuel landing in that wait is refused, not doubled).
-- The pump sells only at a station the server knows (pricing.lua GetStationIndexForCoords, or
-- Config.ExtraPumps); jerry cans pour anywhere. A car with no level is charged only for the room
-- the server computes from that first level.
load_resource('tests/lua/fivem_mocks.lua')

local states = {}
local stateMeta = { __index = { set = function(self, k, v) rawset(self, k, v) end } }
function Entity(e)
    states[e] = states[e] or { state = setmetatable({}, stateMeta) }
    return states[e]
end
local entityType = {}
function GetEntityType(e) return entityType[e] or 0 end
function DoesEntityExist(e) return entityType[e] ~= nil end

-- player_vehicles.fuel by plate; every lookup is recorded; duringLookup runs inside the wait
local stored, lookups, duringLookup, dbDown = {}, {}, nil, false
MySQL.scalar = setmetatable({ await = function(query, p)
    lookups[#lookups + 1] = { query = query, plate = p[1] }
    if duringLookup then local f = duringLookup duringLookup = nil f() end
    if dbDown then error('db down') end
    return stored[p[1]]
end }, { __call = function() end })
-- the plate settle wait: onWait runs inside it (the owner's client syncing the plate)
local waits, onWait = {}, nil
function Wait(ms)
    waits[#waits + 1] = ms
    if onWait then local f = onWait onWait = nil f() end
end

local charged = {}
PFPayout = {
    NewId = function() return tostring(#charged + 1) end,
    Charge = function(player, kind, amount, opts)
        if PFPayout.result then return false, PFPayout.result end
        if player.cannotPay then return false, { ok = false, error = 'insufficient_funds' } end
        charged[#charged + 1] = { cid = player.PlayerData.citizenid, amount = amount, key = opts and opts.key }
        return kind, { ok = true }
    end,
}

Config = nil
load_resource('pfm-fuel/Config.lua')
load_resource('pfm-fuel/server/main.lua')
load_resource('pfm-fuel/server/pricing.lua')
GetFuelTaxRate = function() return 0 end -- the tax has its own spec
local DefaultConfig = { DefaultFuel = Config.DefaultFuel, ExtraPumps = Config.ExtraPumps }

local DRIVER, PUMPER, OTHER = 1, 2, 3
local CAR, PED = 500, 600
local STATION = Config.GasStations[18]
local NOWHERE = vector3(1000.0, 1000.0, 30.0) -- no station within kilometres
local fuelExports = Mock.exportsByResource['__self']

local function fuel(veh) return Entity(veh).state['qb-fuel'] end
local function sync(src, level) Mock.fireNet('qb-fuel:server:syncFuel', src, CAR, level) end
local function refill(src, litres) return Mock.callCallback('qb-fuel:server:refillVehicle', src, litres, CAR) end
local function later(seconds) Mock.gameTimer = Mock.gameTimer + seconds * 1000 end
local function at(where)
    Mock.coords[CAR] = where
    for _, src in ipairs({ DRIVER, PUMPER, OTHER }) do Mock.coords[src] = where + vector3(2.0, 0, 0) end
end
local function giveCan(src, litres)
    local p = Mock.players[src]
    p.can = { slot = 3, info = { fuel = litres, ammo = litres } }
    p.GetItemByName = function(name) if name == 'weapon_petrolcan' then return p.can end end
    p.RemoveItem = function() return true end
    p.AddItem = function(_, _, _, info) p.can = { slot = 3, info = info } return true end
    p.notes = {}
    p.Notify = function(msg) p.notes[#p.notes + 1] = msg end
    return p
end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.vehicleOf, Mock.coords, Mock.plates = {}, {}, {}, {}
    Mock.gameTimer = Mock.gameTimer + 100000
    states, charged, stored, lookups, waits = {}, {}, {}, {}, {}
    duringLookup, onWait, dbDown, PFPayout.result = nil, nil, false, nil
    entityType = { [CAR] = 2, [PED] = 1 }
    for _, src in ipairs({ DRIVER, PUMPER, OTHER }) do Mock.newPlayer(src) giveCan(src, 0) end
    Config.SyncFuelBetweenPlayers = true
    Config.DefaultFuel = DefaultConfig.DefaultFuel
    Config.ExtraPumps = DefaultConfig.ExtraPumps
    Config.ExtraPumpRadius = 10.0
    at(STATION)
    Mock.vehicleOf[DRIVER] = CAR
end

describe('fix13b fuel: a car\'s first level comes from the server', function()
    it('an owned car: the level stored for the plate the server sees (trimmed), not the report', function()
        Mock.plates[CAR] = ' OWN35  '
        stored.OWN35 = 35
        sync(DRIVER, 100)
        assert_eq(fuel(CAR), 35.0)
        assert_eq(#lookups, 1)
        assert_eq(lookups[1].plate, 'OWN35')
        assert_eq(lookups[1].query, 'SELECT fuel FROM player_vehicles WHERE plate = ? LIMIT 1')
        later(10)
        sync(DRIVER, 33)
        assert_eq(fuel(CAR), 33.0, 'then its driver lowers it as before')
    end)

    it('an unowned car (job, rental, stolen): Config.DefaultFuel, whatever the driver reports', function()
        Mock.plates[CAR] = 'BUS1234'
        sync(DRIVER, 3)
        assert_eq(fuel(CAR), 100.0)
        states = {}
        Config.DefaultFuel = 60
        sync(DRIVER, 100)
        assert_eq(fuel(CAR), 60.0, 'the config value')
        states = {}
        Config.DefaultFuel = 'lots'
        sync(DRIVER, 10)
        assert_eq(fuel(CAR), 100.0, 'a bad config value falls back to a full tank')
    end)

    it('only the driver\'s report starts the lookup: a passenger, passer-by or bad report reads nothing', function()
        Mock.vehicleOf[DRIVER] = nil
        Mock.plates[CAR] = 'OWN35'
        sync(OTHER, 50)
        sync(PUMPER, 50)
        Mock.vehicleOf[DRIVER] = CAR
        sync(DRIVER, 'full')
        assert_eq(#lookups, 0)
        assert_eq(fuel(CAR), nil)
    end)

    it('a plate set on the owner\'s client a moment later: looked up again after the settle wait', function()
        Mock.plates[CAR] = '46EEK572' -- what the server sees right after the spawn
        stored.GARAGE1 = 42
        onWait = function() Mock.plates[CAR] = 'GARAGE1 ' end
        sync(DRIVER, 100)
        assert_eq(waits[1], 2000)
        assert_eq(#lookups, 2)
        assert_eq(lookups[2].plate, 'GARAGE1')
        assert_eq(fuel(CAR), 42.0)
    end)

    it('the lock is taken before the database wait: a pump, a jerry can or a second report landing in it change nothing', function()
        Mock.plates[CAR], stored.OWN40 = 'OWN40', 40
        local pump, can = nil, giveCan(OTHER, 40)
        duringLookup = function()
            sync(DRIVER, 100)                                     -- the 1.5 s repeat report
            pump = { refill(PUMPER, 60) }
            Mock.fireNet('qb-fuel:server:setCanFuel', OTHER, 0, CAR)
        end
        sync(DRIVER, 100)
        assert_eq(#lookups, 1, 'one lookup')
        assert_eq(pump[1], false)
        assert_eq(pump[3], 'busy')
        assert_eq(#charged, 0)
        assert_eq(can.can.info.fuel, 40, 'the can was not poured')
        assert_eq(can.notes[1], 'error.vehicle_busy')
        assert_eq(fuel(CAR), 40.0)
        later(5)
        local paid, level = refill(PUMPER, 70)
        assert_eq(paid, true, 'free again afterwards')
        assert_eq(level, 100.0)
        assert_eq(charged[1].amount, 300, '60 litres fit')
    end)

    it('a level server code sets during the wait (SetVehicleFuel) stands', function()
        Mock.plates[CAR], stored.OWN40 = 'OWN40', 40
        duringLookup = function() fuelExports.SetVehicleFuel(CAR, 75) end
        sync(DRIVER, 100)
        assert_eq(fuel(CAR), 75.0)
    end)

    it('the database down: no level is handed out, the next report looks again', function()
        Mock.plates[CAR], stored.OWN40 = 'OWN40', 40
        dbDown = true
        sync(DRIVER, 100)
        assert_eq(fuel(CAR), nil)
        assert_eq(refill(PUMPER, 20), false, 'and the pump charges nothing')
        assert_eq(#charged, 0)
        dbDown = false
        sync(DRIVER, 100)
        assert_eq(fuel(CAR), 40.0)
    end)

    it('the car removed during the wait: nothing is written', function()
        Mock.plates[CAR] = 'GONE1'
        onWait = function() entityType[CAR] = nil end
        sync(DRIVER, 100)
        entityType[CAR] = 2
        assert_eq(fuel(CAR), nil)
    end)

    it('fuel sync off: nothing is looked up or written', function()
        Config.SyncFuelBetweenPlayers = false
        sync(DRIVER, 100)
        assert_eq(#lookups, 0)
        assert_eq(fuel(CAR), nil)
    end)
end)

describe('fix13b fuel: the pump sells only at a station the server knows', function()
    it('away from every station: refused before any car or money is touched', function()
        at(NOWHERE)
        fuelExports.SetVehicleFuel(CAR, 20)
        local paid, level, why = refill(PUMPER, 20)
        assert_eq(paid, false)
        assert_eq(level, false)
        assert_eq(why, 'no_station')
        assert_eq(#charged, 0)
        assert_eq(fuel(CAR), 20.0)
        assert_eq(Mock.callCallback('qb-fuel:server:getPumpPrice', PUMPER), false, 'no price either: the client says why')
    end)

    it('at a listed station (the server\'s ped position): sells at that station\'s price', function()
        fuelExports.SetVehicleFuel(CAR, 20)
        local paid, level = refill(PUMPER, 20)
        assert_eq(paid, true)
        assert_eq(level, 40.0)
        assert_eq(charged[1].amount, math.floor(20 * GetStationFuelPrice(18) + 0.5))
        assert_eq(Mock.callCallback('qb-fuel:server:getPumpPrice', PUMPER), GetStationFuelPrice(18))
    end)

    it('a pump missing from the station list sells only through Config.ExtraPumps (base price)', function()
        at(NOWHERE)
        fuelExports.SetVehicleFuel(CAR, 20)
        Config.ExtraPumps = { 42, { x = 'bad' }, NOWHERE + vector3(5.0, 0, 0) }
        local paid, level = refill(PUMPER, 10)
        assert_eq(paid, true)
        assert_eq(level, 30.0)
        assert_eq(charged[1].amount, 10 * Config.FuelPrice)
        later(5)
        Config.ExtraPumpRadius = 2.0
        assert_eq(refill(PUMPER, 10), false, 'only within its radius')
    end)

    it('buying or filling a jerry can is a pump sale too; pouring one into a car works anywhere', function()
        at(NOWHERE)
        local p = giveCan(PUMPER, 0)
        p.AddItem = function(name, n, slot, info) p.added = info p.can = { slot = 3, info = info } return true end
        Mock.fireNet('qb-fuel:server:buyJerryCan', PUMPER)
        Mock.fireNet('qb-fuel:server:refillJerryCan', PUMPER)
        assert_eq(#charged, 0)
        assert_eq(p.added, nil)
        assert_eq(p.notes[1], 'error.no_station')
        assert_eq(p.notes[2], 'error.no_station')
        at(STATION)
        Mock.fireNet('qb-fuel:server:buyJerryCan', PUMPER)
        assert_eq(#charged, 1)
        assert_eq(p.added.fuel, Config.JerryCanLitre)
        at(NOWHERE)
        fuelExports.SetVehicleFuel(CAR, 30)
        Mock.fireNet('qb-fuel:server:setCanFuel', PUMPER, 0, CAR)
        assert_eq(fuel(CAR), 70.0, 'poured far from any station')
    end)

    it('the bank not taking a payment for another reason than money: reason \'payment\', nothing poured', function()
        fuelExports.SetVehicleFuel(CAR, 20)
        PFPayout.result = { ok = false, state = 'pending', unclear = true }
        local paid, level, why = refill(PUMPER, 20)
        assert_eq(paid, false)
        assert_eq(level, 20.0)
        assert_eq(why, 'payment')
        assert_eq(fuel(CAR), 20.0)
        later(5)
        PFPayout.result = nil
        Mock.players[PUMPER].cannotPay = true
        local paid2, _, why2 = refill(PUMPER, 20)
        assert_eq(paid2, false)
        assert_eq(why2, nil, 'not enough money: the client says so')
    end)
end)

describe('fix13b fuel: a car with no level is refuelled from the server\'s first level', function()
    it('the pump charges only the room left by the stored level', function()
        Mock.vehicleOf[DRIVER] = nil
        Mock.plates[CAR], stored.OWN70 = 'OWN70', 70
        local paid, level = refill(PUMPER, 60)
        assert_eq(paid, true)
        assert_eq(level, 100.0)
        assert_eq(#charged, 1)
        assert_eq(charged[1].amount, math.floor(30 * GetStationFuelPrice(18) + 0.5), '30 litres, not 60')
    end)

    it('a car at its default level (full): refused as full, nothing charged', function()
        Mock.vehicleOf[DRIVER] = nil
        Mock.plates[CAR] = 'TAXI1234'
        local paid, level, why = refill(PUMPER, 30)
        assert_eq(paid, false)
        assert_eq(level, 100.0)
        assert_eq(why, 'full')
        assert_eq(#charged, 0)
    end)

    it('a jerry can into a car with no level: it pours only the room left; the rest stays in the can', function()
        Mock.vehicleOf[DRIVER] = nil
        Mock.plates[CAR], stored.OWN85 = 'OWN85', 85
        local p = giveCan(PUMPER, 40)
        Mock.fireNet('qb-fuel:server:setCanFuel', PUMPER, 0, CAR)
        assert_eq(fuel(CAR), 100.0)
        assert_eq(p.can.info.fuel, 25, '15 litres poured')
        Mock.fireNet('qb-fuel:server:setCanFuel', PUMPER, 0, CAR)
        assert_eq(p.can.info.fuel, 25, 'a full car takes nothing')
        assert_eq(p.notes[#p.notes], 'error.vehicle_full')
    end)

    it('the can is read after the lookup\'s wait: a can swapped in during it is what is counted', function()
        Mock.vehicleOf[DRIVER] = nil
        Mock.plates[CAR], stored.OWN20 = 'OWN20', 20
        local p = giveCan(PUMPER, 40)
        duringLookup = function() p.can = { slot = 3, info = { fuel = 5, ammo = 5 } } end -- an almost empty can
        Mock.fireNet('qb-fuel:server:setCanFuel', PUMPER, 0, CAR)
        assert_eq(fuel(CAR), 25.0, 'only the 5 litres of the can it had at the swap')
        assert_eq(p.can.info.fuel, 0)
    end)
end)

describe('fix13b fuel: the client', function()
    local src = __readfile('pfm-fuel/client/main.lua')
    it('a car that is not networked gets a clear message before any refuel starts', function()
        local n = 0
        for _ in src:gmatch("if not NetworkGetEntityIsNetworked%(veh%) then return QBCore%.Functions%.Notify%(Lang:t%('error%.not_networked'%), 'error'%) end") do n = n + 1 end
        assert_eq(n, 2, 'pump and jerry can')
        for _, lang in ipairs({ 'en', 'es', 'nl' }) do
            assert_true(__readfile('pfm-fuel/locales/' .. lang .. '.lua'):find('not_networked = ', 1, true) ~= nil, lang)
            assert_true(__readfile('pfm-fuel/locales/' .. lang .. '.lua'):find('no_station = ', 1, true) ~= nil, lang)
        end
    end)

    it('no station: the price answer opens no menu, the refill answer says why; a payment the bank explained adds nothing', function()
        assert_true(src:find("if not allInPrice then return QBCore%.Functions%.Notify%(Lang:t%('error%.no_station'%), 'error'%) end") ~= nil)
        assert_true(src:find("reason == 'no_station' and 'error.no_station'", 1, true) ~= nil)
        assert_true(src:find("if reason == 'payment' then return end", 1, true) ~= nil)
    end)

    it('the manifest loads oxmysql for the lookup', function()
        assert_true(__readfile('pfm-fuel/fxmanifest.lua'):find('"@oxmysql/lib/MySQL.lua"', 1, true) ~= nil)
    end)
end)
