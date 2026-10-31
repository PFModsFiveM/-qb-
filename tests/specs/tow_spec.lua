-- pf-jobs tow (server/apps/tow.lua), which replaced pfm-towjob: the flatbed deposit is charged and
-- refunded once on the ledger (and survives a disconnect), the hook takes any car but only from a
-- flatbed with the driver next to it, NPC contracts are offered only while no tow request waits,
-- a contract pays once when the car is set down at the drop-off after a real tow, and dispatch
-- requests complete through pf-services when the car is set down at its destination.
load_resource('tests/lua/ledger_env.lua')
QBCore = QBCoreMock

-- world: vehicles that exist, their models, positions, drivers; peds' current and last vehicle
local alive, drivers, inVeh, lastVeh = {}, {}, {}, {}
local health = 1000.0
function CreateVehicleServerSetter(hash, _, x, y, z)
    Mock.nextNetId = Mock.nextNetId + 1
    local id = Mock.nextNetId
    alive[id], Mock.models[id], Mock.coords[id] = true, hash, vector3(x, y, z)
    return id
end
function DoesEntityExist(e) return alive[e] == true end
function DeleteEntity(e) alive[e] = nil; Mock.deleted[#Mock.deleted + 1] = e end
function GetAllVehicles() local out = {} for e in pairs(alive) do out[#out + 1] = e end return out end
function GetVehiclePedIsIn(ped, last) if last then return lastVeh[ped] or 0 end return inVeh[ped] or 0 end
function GetPedInVehicleSeat(veh, seat) return seat == -1 and (drivers[veh] or 0) or 0 end
function SetVehicleNumberPlateText(veh, plate) Mock.plates[veh] = plate end
function SetVehicleDoorsLocked() end
function GetVehicleEngineHealth() return health end
function GetVehicleBodyHealth() return health end
SetTimeout = function(_, fn) fn() end

local bankUp, servicesUp = true, true
function GetResourceState(name)
    if name == 'pfm-banking' then return bankUp and 'started' or 'stopped' end
    if name == 'pf-services' then return servicesUp and 'started' or 'stopped' end
    return 'started'
end

-- pf-services stand-in: requests, the tow kinds' handlers (registered by tow_requests.lua)
local requests, handlers = {}, {}
Mock.exportsByResource['pf-services'] = {
    RegisterRequestHandler = function(_, kind, h) handlers[kind] = h return true end,
    ListForJob = function() local out = {} for _, r in ipairs(requests) do if r.status == 'open' or r.status == 'accepted' then out[#out + 1] = r end end return out end,
    PublicView = function(_, req, cid) return { id = req.id, kind = req.kind, status = req.status, title = req.title, plate = req.plate, mine = req.assignee == cid, meta = req.meta } end,
    AcceptRequest = function(_, src, id)
        local r = requests[id]
        if not r or r.status ~= 'open' then return { ok = false, error = 'not_open' } end
        r.status, r.assignee = 'accepted', Mock.players[src].PlayerData.citizenid
        return { ok = true }
    end,
    ReleaseRequest = function(_, src, id)
        local r = requests[id]
        if not r or r.status ~= 'accepted' or r.assignee ~= Mock.players[src].PlayerData.citizenid then return { ok = false, error = 'not_yours' } end
        r.status, r.assignee = 'open', nil
        return { ok = true }
    end,
    CompleteRequest = function(_, src, id, proof)
        local r = requests[id]
        if not r or r.status ~= 'accepted' or r.assignee ~= Mock.players[src].PlayerData.citizenid then return { ok = false, error = 'not_yours' } end
        local ok, why = handlers[r.kind].canComplete(r, src, proof)
        if ok ~= true then return { ok = false, error = why } end
        r.status = 'completed'
        if handlers[r.kind].onCompleted then handlers[r.kind].onCompleted(r, 'done') end
        return { ok = true }
    end,
}
Mock.exportsByResource['pfm-policejob'] = { GetImpoundLots = function() return { vector3(409.0, -1623.0, 29.0) } end, FinalizeImpound = function() return true end }

LedgerEnv.load('pf-jobs', {
    '[pfscripts]/pf-jobs/config.lua',
    '[pfscripts]/pf-jobs/server/apps/tow.lua',
    '[pfscripts]/pf-jobs/server/apps/tow_requests.lua',
})
Config.Tow.UseDatabase = false
Mock.fireEvent('onResourceStart', nil, 'pf-jobs') -- tow_requests registers its checks

local T, MECH, OTHER = 1, 2, 3
local C = Config.Tow
local BAY = vector3(C.FlatbedSpawn.x, C.FlatbedSpawn.y, C.FlatbedSpawn.z)
local DROP = C.DropOff.coords
local function money(src, kind) return Mock.players[src].PlayerData.money[kind] end
local function view(src) return PFJobsTow.View(src or T) end
local function rented() return view().rental end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.clock = Mock.clock + 100000
    for src = 1, 3 do PFJobsTow.Dropped(src) end
    for _, cid in ipairs({ 'CID1', 'CID2', 'CID3' }) do PFJobsTow.ForgetCitizen(cid) end
    Mock.players, Mock.coords, Mock.models, Mock.deleted = {}, {}, {}, {}
    alive, drivers, inVeh, lastVeh, requests = {}, {}, {}, {}, {}
    health, bankUp, servicesUp = 1000.0, true, true
    local p = Mock.newPlayer(T)
    p.PlayerData.job = { name = 'tow', onduty = true }
    p.PlayerData.money = { cash = 1000, bank = 0 }
    Mock.newPlayer(MECH).PlayerData.job = { name = 'mechanic', onduty = true }
    Mock.newPlayer(OTHER).PlayerData.job = { name = 'tow', onduty = true }
end

-- rents a flatbed at the bay and leaves the driver standing next to it, on foot
local function rentTruck(src)
    src = src or T
    Mock.coords[src] = BAY
    assert_eq(PFJobsTow.Rent(src, 'flatbed', true).ok, true, 'rented')
    local truck = Mock.nextNetId
    lastVeh[src] = truck
    return truck
end

-- puts the truck, the driver and a car at a spot
local function placeAt(pos, truck, car, src)
    src = src or T
    Mock.coords[truck] = pos
    Mock.coords[src] = vector3(pos.x + 2, pos.y, pos.z)
    if car then Mock.coords[car] = vector3(pos.x, pos.y + 6, pos.z) end
end

local function car(plate)
    Mock.nextNetId = Mock.nextNetId + 1
    local id = Mock.nextNetId
    alive[id], Mock.models[id], Mock.plates[id] = true, GetHashKey('sultan'), plate or 'ABC123'
    return id
end

describe('flatbed rental', function()
    it('only tow drivers on duty at the bay rent, one truck each, the deposit charged once', function()
        Mock.coords[T] = vector3(0, 0, 0)
        assert_eq(PFJobsTow.Rent(T, 'flatbed', true).error, 'not_at_depot')
        Mock.coords[MECH] = BAY
        assert_eq(PFJobsTow.Rent(MECH, 'flatbed', true).error, 'not_tow')
        Mock.players[T].PlayerData.job.onduty = false
        Mock.coords[T] = BAY
        assert_eq(PFJobsTow.Rent(T, 'flatbed', true).error, 'off_duty')
        Mock.players[T].PlayerData.job.onduty = true
        assert_eq(PFJobsTow.Rent(T, 'rhino', true).error, 'unknown_vehicle')
        assert_eq(money(T, 'cash'), 1000)
        rentTruck()
        assert_eq(money(T, 'cash'), 1000 - 250)
        assert_eq(#LedgerEnv.paid('pf-jobs:tow:rent:'), 1)
        assert_eq(rented().plate:sub(1, 4), 'TOWR')
        assert_eq(PFJobsTow.Rent(T, 'flatbed', true).error, 'rental_active')
        assert_eq(money(T, 'cash'), 750)
    end)

    it('the deposit comes back once, with the truck at the bay and nothing on it', function()
        local truck = rentTruck()
        Mock.coords[truck] = vector3(0, 0, 0)
        assert_eq(PFJobsTow.Return(T, true).error, 'truck_far')
        Mock.coords[truck] = BAY
        assert_eq(PFJobsTow.Return(T, true).ok, true)
        assert_eq(money(T, 'bank'), 250)
        assert_eq(alive[truck], nil, 'the truck is removed')
        assert_eq(PFJobsTow.Return(T, true).error, 'no_rental')
        assert_eq(money(T, 'bank'), 250)
    end)

    it('a damaged truck keeps part of the deposit', function()
        local truck = rentTruck()
        Mock.coords[truck] = BAY
        health = 500.0
        assert_eq(PFJobsTow.Return(T, true).refund, 250 - math.floor(250 * 0.5 * C.DamageDeduction))
    end)

    it('a disconnect removes the truck, and the deposit comes back at the bay later', function()
        local truck = rentTruck()
        PFJobsTow.Dropped(T)
        assert_eq(alive[truck], nil)
        assert_eq(rented().orphaned, true)
        Mock.coords[T] = vector3(0, 0, 0)
        assert_eq(PFJobsTow.Return(T, true).error, 'not_at_depot')
        Mock.coords[T] = BAY
        assert_eq(PFJobsTow.Return(T, true).ok, true)
        assert_eq(money(T, 'bank'), 250)
    end)

    it('a lost truck closes the rental and keeps the deposit', function()
        local truck = rentTruck()
        assert_eq(PFJobsTow.ReportLost(T, true).error, 'truck_exists')
        alive[truck] = nil
        assert_eq(PFJobsTow.Return(T, true).error, 'truck_lost')
        assert_eq(PFJobsTow.ReportLost(T, true).ok, true)
        assert_eq(rented(), nil)
        assert_eq(money(T, 'bank'), 0)
    end)
end)

describe('the flatbed hook', function()
    it('takes any car next to a flatbed, with the driver on foot by the truck, once', function()
        local truck = rentTruck()
        local c = car()
        placeAt(vector3(100, 100, 30), truck, c)
        Mock.players[OTHER].PlayerData.job = { name = 'police' }
        assert_eq(PFJobsTow.Hook(OTHER, c, true).error, 'not_a_hook_job')
        inVeh[T] = truck
        assert_eq(PFJobsTow.Hook(T, c, true).error, 'not_on_foot')
        inVeh[T] = nil
        assert_eq(PFJobsTow.Hook(T, 'x', true).error, 'bad_request')
        assert_eq(PFJobsTow.Hook(T, truck, true).error, 'bad_target', 'not the truck itself')
        Mock.coords[c] = vector3(150, 100, 30)
        assert_eq(PFJobsTow.Hook(T, c, true).error, 'too_far_car')
        Mock.coords[c] = vector3(100, 106, 30)
        drivers[c] = 77
        assert_eq(PFJobsTow.Hook(T, c, true).error, 'occupied')
        drivers[c] = nil
        Mock.coords[T] = vector3(160, 100, 30)
        assert_eq(PFJobsTow.Hook(T, c, true).error, 'too_far_truck')
        Mock.coords[T] = vector3(102, 100, 30)
        assert_eq(PFJobsTow.Hook(T, c, true).ok, true)
        assert_eq(#Mock.clientEventsNamed('pf-jobs:tow:client:attach'), 1)
        assert_eq(view().hook.plate, 'ABC123')
        assert_eq(PFJobsTow.Hook(T, car('ZZZ'), true).error, 'truck_busy')
        -- a mechanic with their own flatbed cannot take the same car
        lastVeh[MECH] = CreateVehicleServerSetter(GetHashKey('flatbed'), 'automobile', 100, 104, 30)
        Mock.coords[MECH] = vector3(101, 104, 30)
        assert_eq(PFJobsTow.Hook(MECH, c, true).error, 'car_hooked')
        local mc = car('MECH1')
        Mock.coords[mc] = vector3(100, 110, 30)
        assert_eq(PFJobsTow.Hook(MECH, mc, true).ok, true, 'mechanics use the hook too')
        assert_eq(PFJobsTow.Unhook(T, true).ok, true)
        assert_eq(#Mock.clientEventsNamed('pf-jobs:tow:client:detach'), 1)
        assert_eq(PFJobsTow.Unhook(T, true).error, 'nothing_hooked')
        assert_eq(view().stats.towed, 1)
    end)

    it('a car from the street cannot be hooked from a car that is not a flatbed', function()
        local c = car()
        lastVeh[T] = CreateVehicleServerSetter(GetHashKey('sultan'), 'automobile', 100, 100, 30)
        placeAt(vector3(100, 100, 30), lastVeh[T], c)
        assert_eq(PFJobsTow.Hook(T, c, true).error, 'not_flatbed')
    end)
end)

describe('NPC tow contracts', function()
    local function contractCar() return view().contract and Mock.nextNetId end

    it('wait while a tow request is open, and need a flatbed', function()
        Mock.coords[T] = BAY
        assert_eq(PFJobsTow.StartContract(T, true).error, 'no_truck')
        rentTruck()
        requests[1] = { id = 1, kind = 'tow.recovery', status = 'open', plate = 'REQ1', title = 'Recovery' }
        assert_eq(PFJobsTow.StartContract(T, true).error, 'requests_waiting')
        assert_eq(view().contractBlocker, 'requests_waiting')
        requests[1].status = 'cancelled'
        assert_eq(PFJobsTow.StartContract(T, true).ok, true)
        local c = view().contract
        assert_eq(c.stage, 'pickup')
        assert_true(c.km <= C.Levels[1].maxKm + 0.05, 'within the level 1 reach')
        assert_true(c.pay >= C.Contracts.PayBase and c.pay <= C.Contracts.MaxPay)
        assert_eq(PFJobsTow.StartContract(T, true).error, 'contract_active')
    end)

    it('pay once when the car is set down at the drop-off after a real tow', function()
        local truck = rentTruck()
        assert_eq(PFJobsTow.StartContract(T, true).ok, true)
        local id = contractCar()
        local c = view().contract
        placeAt(vector3(c.x, c.y, c.z), truck)
        Mock.coords[id] = vector3(c.x, c.y + 6, c.z)
        assert_eq(PFJobsTow.Hook(T, id, true).ok, true)
        assert_eq(view().contract.stage, 'deliver')
        -- set down away from the drop-off: back to pickup, nothing paid
        assert_eq(PFJobsTow.Unhook(T, true).delivered, false)
        assert_eq(view().contract.stage, 'pickup')
        assert_eq(PFJobsTow.Hook(T, id, true).ok, true)
        -- at the drop-off at once: too quick
        placeAt(DROP, truck, id)
        assert_eq(PFJobsTow.Unhook(T, true).delivered, false)
        assert_eq(PFJobsTow.Hook(T, id, true).ok, true)
        Mock.clock = Mock.clock + 900
        local res = PFJobsTow.Unhook(T, true)
        assert_eq(res.delivered, true)
        assert_eq(money(T, 'bank'), c.pay)
        assert_eq(#LedgerEnv.paid('pf-jobs:tow:contract:'), 1)
        assert_eq(alive[id], nil, 'the delivered car is removed')
        local v = view()
        assert_eq(v.contract, nil)
        assert_eq(v.stats.contracts, 1)
        assert_eq(v.stats.xp, c.xp)
        assert_eq(v.contractBlocker, 'cooldown')
    end)

    it('bank down at delivery: the pay waits and is collected once', function()
        local truck = rentTruck()
        PFJobsTow.StartContract(T, true)
        local id = contractCar()
        local c = view().contract
        placeAt(vector3(c.x, c.y, c.z), truck)
        Mock.coords[id] = vector3(c.x, c.y + 6, c.z)
        PFJobsTow.Hook(T, id, true)
        Mock.clock = Mock.clock + 900
        placeAt(DROP, truck, id)
        bankUp = false
        assert_eq(PFJobsTow.Unhook(T, true).delivered, false)
        assert_eq(view().contract.stage, 'payment_due')
        assert_eq(PFJobsTow.StartContract(T, true).error, 'payment_due')
        assert_eq(PFJobsTow.CancelContract(T, true).error, 'payment_due')
        assert_eq(PFJobsTow.ClaimPay(T, true).error, 'bank_unavailable')
        bankUp = true
        assert_eq(PFJobsTow.ClaimPay(T, true).ok, true)
        assert_eq(PFJobsTow.ClaimPay(T, true).error, 'nothing_owed')
        assert_eq(money(T, 'bank'), c.pay)
        assert_eq(#LedgerEnv.paid('pf-jobs:tow:contract:'), 1)
    end)

    it('a cancelled contract removes its car', function()
        rentTruck()
        PFJobsTow.StartContract(T, true)
        local id = contractCar()
        assert_eq(PFJobsTow.CancelContract(T, true).ok, true)
        assert_eq(alive[id], nil)
        assert_eq(PFJobsTow.CancelContract(T, true).error, 'no_contract')
    end)
end)

describe('dispatch tow requests', function()
    it('accepted in the app, completed by setting the car down at the shop, with XP', function()
        local truck = rentTruck()
        local c = car('REC123')
        requests[1] = { id = 1, kind = 'tow.recovery', status = 'open', plate = 'REC123', title = 'Broken car', meta = {}, reward = 175 }
        local list = view().requests
        assert_eq(#list, 1)
        assert_true(#list[1].destinations > 0, 'shops listed as destinations')
        assert_eq(PFJobsTow.AcceptRequest(T, 'one', true).error, 'bad_request')
        assert_eq(PFJobsTow.AcceptRequest(T, 1, true).ok, true)
        assert_true(view().requests[1].mine)
        assert_eq(PFJobsTow.AcceptRequest(OTHER, 1, true).ok, false)
        -- a driver can hand it back, and only their own
        assert_eq(PFJobsTow.ReleaseRequest(OTHER, 1, true).ok, false)
        assert_eq(PFJobsTow.ReleaseRequest(T, 1, true).ok, true)
        assert_eq(requests[1].status, 'open')
        assert_eq(PFJobsTow.AcceptRequest(T, 1, true).ok, true)
        -- not there yet: completing is refused by the tow check
        placeAt(vector3(100, 100, 30), truck, c)
        assert_eq(PFJobsTow.CompleteRequest(T, 1, true).error, 'not_at_destination')
        assert_eq(PFJobsTow.Hook(T, c, true).ok, true)
        local burton = vector3(-337.39, -136.92, 39.01)
        placeAt(burton, truck, c)
        local res = PFJobsTow.Unhook(T, true)
        assert_eq(res.completedRequest, 1)
        assert_eq(requests[1].status, 'completed')
        local v = view()
        assert_eq(v.stats.requests, 1)
        assert_eq(v.stats.xp, C.RequestXP)
        assert_eq(v.stats.earned, 175)
    end)
end)
