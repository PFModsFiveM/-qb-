-- pf-jobs tow (server/apps/tow.lua), review main-9hq3gi:
--   (a) two flatbed rents at once (the second arriving while the first waits on the bank or the
--       spawn) charge one deposit and bring out one truck; a deposit taken is always refundable,
--       also when the truck cannot be spawned and the refund fails, when the driver leaves during
--       the spawn, and when an earlier refund failed for good on the ledger;
--   (b) a driver who left the tow job still returns the truck / reports it lost;
--   (c) two tow contract requests at once spawn one breakdown car.
-- The second request is made from inside the first one's yield (the vehicle spawn), as two net
-- events from the same player interleave on the server.
load_resource('tests/lua/ledger_env.lua')
QBCore = QBCoreMock

local alive, lastVeh = {}, {}
local spawnHook, spawnFails = nil, false
function CreateVehicleServerSetter(hash, _, x, y, z)
    if spawnHook then
        local h = spawnHook
        spawnHook = nil
        h()
    end
    Mock.nextNetId = Mock.nextNetId + 1
    local id = Mock.nextNetId
    if spawnFails then return id end -- never comes into existence
    alive[id], Mock.models[id], Mock.coords[id] = true, hash, vector3(x, y, z)
    return id
end
function DoesEntityExist(e) return alive[e] == true end
function DeleteEntity(e) alive[e] = nil; Mock.deleted[#Mock.deleted + 1] = e end
function GetAllVehicles() local out = {} for e in pairs(alive) do out[#out + 1] = e end return out end
function GetVehiclePedIsIn(ped, last) if last then return lastVeh[ped] or 0 end return 0 end
function GetPedInVehicleSeat() return 0 end
function SetVehicleNumberPlateText(veh, plate) Mock.plates[veh] = plate end
function SetVehicleDoorsLocked() end
function GetVehicleEngineHealth() return 1000.0 end
function GetVehicleBodyHealth() return 1000.0 end
SetTimeout = function(_, fn) fn() end

local bankUp = true
function GetResourceState(name)
    if name == 'pfm-banking' then return bankUp and 'started' or 'stopped' end
    if name == 'pf-services' then return 'stopped' end
    return 'started'
end

LedgerEnv.load('pf-jobs', {
    '[pfscripts]/pf-jobs/config.lua',
    '[pfscripts]/pf-jobs/server/apps/tow.lua',
})
Config.Tow.UseDatabase = false

local T = 1
local C = Config.Tow
local BAY = vector3(C.FlatbedSpawn.x, C.FlatbedSpawn.y, C.FlatbedSpawn.z)
local DEPOSIT = C.Vehicles[1].deposit
local function money(kind) return Mock.players[T].PlayerData.money[kind] end
local function rented() return PFJobsTow.View(T).rental end
local function aliveCount() local n = 0 for _ in pairs(alive) do n = n + 1 end return n end

local function newDriver()
    local p = Mock.newPlayer(T)
    p.PlayerData.job = { name = 'tow', onduty = true }
    p.PlayerData.money = { cash = 1000, bank = 0 }
    return p
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.clock = Mock.clock + 100000
    PFJobsTow.Dropped(T)
    PFJobsTow.ForgetCitizen('CID1')
    Mock.players, Mock.coords, Mock.models, Mock.deleted = {}, {}, {}, {}
    alive, lastVeh = {}, {}
    spawnHook, spawnFails, bankUp = nil, false, true
    newDriver()
    Mock.coords[T] = BAY
end

local function rentTruck()
    assert_eq(PFJobsTow.Rent(T, 'flatbed', true).ok, true, 'rented')
    local truck = Mock.nextNetId
    lastVeh[T] = truck
    return truck
end

describe('flatbed rent: one at a time per character', function()
    it('a second rent while the first is spawning is refused: one deposit, one truck', function()
        local inner
        spawnHook = function() inner = PFJobsTow.Rent(T, 'flatbed', true) end
        assert_eq(PFJobsTow.Rent(T, 'flatbed', true).ok, true)
        assert_eq(inner and inner.error, 'busy', 'the overlapping rent is refused')
        assert_eq(money('cash'), 1000 - DEPOSIT, 'one deposit')
        assert_eq(#LedgerEnv.paid('pf-jobs:tow:rent:'), 1)
        assert_eq(aliveCount(), 1, 'one flatbed')
        -- the lock is released: the next call sees the rental, and the deposit comes back once
        assert_eq(PFJobsTow.Rent(T, 'flatbed', true).error, 'rental_active')
        local res = PFJobsTow.Return(T, true)
        assert_eq(res.ok, true)
        assert_eq(res.refund, DEPOSIT)
        assert_eq(money('bank'), DEPOSIT)
        assert_eq(aliveCount(), 0)
    end)

    it('a return while the rent is spawning is refused, so it cannot refund a truck still coming out', function()
        local inner
        spawnHook = function() inner = PFJobsTow.Return(T, true) end
        assert_eq(PFJobsTow.Rent(T, 'flatbed', true).ok, true)
        assert_eq(inner and inner.error, 'busy')
        assert_eq(money('bank'), 0)
        assert_eq(rented().present, true)
    end)

    it('a failed spawn refunds the deposit and releases the lock', function()
        spawnFails = true
        assert_eq(PFJobsTow.Rent(T, 'flatbed', true).error, 'spawn_failed')
        assert_eq(money('cash') + money('bank'), 1000, 'deposit refunded')
        assert_eq(rented(), nil)
        spawnFails = false
        assert_eq(PFJobsTow.Rent(T, 'flatbed', true).ok, true, 'not left busy')
    end)

    it('a failed spawn whose refund also fails keeps the deposit refundable at the bay', function()
        spawnFails = true
        spawnHook = function() bankUp = false end -- the bank goes away after the charge
        assert_eq(PFJobsTow.Rent(T, 'flatbed', true).error, 'deposit_held')
        assert_eq(money('cash'), 1000 - DEPOSIT)
        local r = rented()
        assert_true(r ~= nil, 'the rental is kept')
        assert_eq(r.orphaned, true)
        assert_eq(r.refund, DEPOSIT)
        bankUp, spawnFails = true, false
        local res = PFJobsTow.Return(T, true)
        assert_eq(res.ok, true)
        assert_eq(res.refund, DEPOSIT)
        assert_eq(money('bank'), DEPOSIT)
        assert_eq(rented(), nil)
    end)

    it('a driver who leaves while the truck spawns gets no truck, and the deposit back at the bay', function()
        spawnHook = function()
            Mock.players[T] = nil
            PFJobsTow.Dropped(T)
        end
        assert_eq(PFJobsTow.Rent(T, 'flatbed', true).ok, false)
        assert_eq(aliveCount(), 0, 'the truck spawned after the drop is removed')
        local p = newDriver()
        p.PlayerData.money.cash = 1000 - DEPOSIT -- what they had when they left
        Mock.coords[T] = BAY
        local r = rented()
        assert_true(r ~= nil and r.orphaned == true, 'the rental waits at the bay')
        local res = PFJobsTow.Return(T, true)
        assert_eq(res.refund, DEPOSIT)
        assert_eq(money('bank'), DEPOSIT)
    end)

    it('a refund that failed for good on the ledger is retried under a new key, and paid once', function()
        local truck = rentTruck()
        Mock.coords[truck] = BAY
        local p = Mock.players[T]
        p.Functions.AddMoney = function() return false end -- the credit fails: the ledger compensates
        assert_eq(PFJobsTow.Return(T, true).error, 'bank_unavailable')
        assert_eq(money('bank'), 0)
        p.Functions.AddMoney = p.AddMoney
        local res = PFJobsTow.Return(T, true)
        assert_eq(res.ok, true, 'not stuck on the stored failure')
        assert_eq(res.refund, DEPOSIT)
        assert_eq(money('bank'), DEPOSIT)
        assert_eq(PFJobsTow.Return(T, true).error, 'no_rental')
        assert_eq(money('bank'), DEPOSIT, 'refunded once')
    end)
end)

describe('flatbed return after leaving the tow job', function()
    it('a fired driver returns the truck at the bay and gets the deposit', function()
        local truck = rentTruck()
        Mock.coords[truck] = BAY
        Mock.players[T].PlayerData.job = { name = 'unemployed', onduty = false }
        Mock.coords[T] = vector3(0, 0, 0)
        assert_eq(PFJobsTow.Return(T, true).error, 'not_at_depot', 'still only at the bay')
        Mock.coords[T] = BAY
        Mock.coords[truck] = vector3(2000, 2000, 30)
        assert_eq(PFJobsTow.Return(T, true).error, 'truck_far', 'still only with the truck')
        Mock.coords[truck] = BAY
        local res = PFJobsTow.Return(T, true)
        assert_eq(res.ok, true)
        assert_eq(res.refund, DEPOSIT)
        assert_eq(money('bank'), DEPOSIT)
    end)

    it('an orphaned rental is settled after a job change', function()
        rentTruck()
        PFJobsTow.Dropped(T) -- truck at the bay when they left
        Mock.players[T].PlayerData.job = { name = 'police', onduty = true }
        assert_eq(PFJobsTow.Return(T, true).refund, DEPOSIT)
        assert_eq(money('bank'), DEPOSIT)
    end)

    it('a driver who changed jobs reports a lost truck', function()
        local truck = rentTruck()
        alive[truck] = nil
        Mock.players[T].PlayerData.job = { name = 'mechanic', onduty = true }
        assert_eq(PFJobsTow.ReportLost(T, true).ok, true)
        assert_eq(rented(), nil)
    end)

    it('someone outside the tow job with no rental is still told they are not a tow driver', function()
        Mock.players[T].PlayerData.job = { name = 'mechanic', onduty = true }
        assert_eq(PFJobsTow.Return(T, true).error, 'not_tow')
        assert_eq(PFJobsTow.ReportLost(T, true).error, 'not_tow')
        assert_eq(PFJobsTow.Rent(T, 'flatbed', true).error, 'not_tow', 'renting still needs the job')
    end)
end)

describe('tow contracts: one request at a time per driver', function()
    it('a second contract request while the first car spawns is refused: one car, one contract', function()
        rentTruck()
        local inner
        spawnHook = function() inner = PFJobsTow.StartContract(T, true) end
        assert_eq(PFJobsTow.StartContract(T, true).ok, true)
        assert_eq(inner and inner.error, 'busy')
        assert_eq(aliveCount(), 2, 'the flatbed and one breakdown car')
        assert_eq(PFJobsTow.StartContract(T, true).error, 'contract_active', 'lock released')
        assert_eq(PFJobsTow.CancelContract(T, true).ok, true)
        assert_eq(aliveCount(), 1, 'the car went with the contract; nothing leaked')
    end)

    it('a driver who leaves while the car spawns leaves no car and no held spot', function()
        -- one spot within level 1 reach, so a spot left held would block the next contract
        local allSpots, one = C.Spots, nil
        local drop = C.DropOff.coords
        for _, s in ipairs(allSpots) do
            local km = #(vector3(s.coords.x, s.coords.y, s.coords.z or 0.0) - vector3(drop.x, drop.y, drop.z or 0.0)) / 1000
            if not one and km <= C.Levels[1].maxKm then one = s end
        end
        assert_true(one ~= nil, 'a level 1 spot exists')
        C.Spots = { one }
        local ok, err = pcall(function()
            rentTruck()
            spawnHook = function()
                Mock.players[T] = nil
                PFJobsTow.Dropped(T)
            end
            assert_eq(PFJobsTow.StartContract(T, true).ok, false)
            assert_eq(aliveCount(), 0, 'the contract car is removed (the truck went with the drop)')
            newDriver()
            Mock.coords[T] = BAY
            assert_eq(PFJobsTow.Return(T, true).refund, DEPOSIT, 'the orphaned rental is settled')
            rentTruck()
            local res = PFJobsTow.StartContract(T, true)
            assert_eq(res.ok, true, 'the spot is free again: ' .. tostring(res.error))
        end)
        C.Spots = allSpots
        if not ok then error(err, 0) end
    end)
end)
