-- pf-jobs Tow: a player who rented a flatbed and then left the tow job must still be able to return
-- it (or report it lost) for the refund the rules allow. The server functions already took any
-- player with a rental, but the Tow app was registered for the tow job only, so on a tablet or
-- computer the return was out of reach. The app's access is now "the tow job, or an open rental"
-- (server/devices.lua, __access); a former driver gets a view of the rental alone and every other
-- action is refused, and the app leaves their device once the rental is settled. On the world side
-- /tow takes a car off the bed whenever the server says one is on it (client/tow.lua), since the
-- return refuses a loaded truck and the client's own hook state is set only when its attach event
-- found both cars (one not streamed in yet, or a missed event, leaves the server holding a hook the
-- client does not know about).
-- A former driver whose last contract's pay the bank missed (payment_due) also keeps the app and
-- collects the pay from the return-only view; an open window switches to that view when the player
-- leaves the job (the job change pushes the tow state, and the app fetches its view again). A
-- deposit charge the bank has not settled yet is told as such (not "you cannot pay"), and the retry
-- asks under the same key, so the deposit is never taken twice.
load_resource('tests/lua/ledger_env.lua')
QBCore = QBCoreMock

-- world: vehicles that exist, their models and positions; peds' current and last vehicle
local alive, inVeh, lastVeh = {}, {}, {}
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
function GetPedInVehicleSeat() return 0 end
function SetVehicleNumberPlateText(veh, plate) Mock.plates[veh] = plate end
function SetVehicleDoorsLocked() end
function GetVehicleEngineHealth() return 1000.0 end
function GetVehicleBodyHealth() return 1000.0 end
SetTimeout = function() end
local bankDown = false
local function started(name)
    if name == 'pfm-banking' and bankDown then return 'missing' end
    return name ~= 'pf-services' and 'started' or 'missing'
end
GetResourceState = started

local installs = {}
FakeDB.extraPatterns = {
    { 'SELECT app_id FROM pf_device_apps', function(p)
        local out = {}
        for _, r in ipairs(installs) do if r[1] == p[1] then out[#out + 1] = { app_id = r[2] } end end
        return out
    end },
}
Mock.exportsByResource['pf-devices'] = {
    RegisterApp = function(_, def) return PFDevices.RegisterApp(def, 'pf-jobs') end,
    RegisterAppHandlers = function(_, id, map) return PFDevices.RegisterAppHandlers(id, map, 'pf-jobs') end,
    NotifyAppsChanged = function(_, target) return PFDevices.NotifyAppsChanged(target) end,
}

LedgerEnv.load('pf-jobs', {
    '[pfscripts]/pf-jobs/config.lua',
    '[pfscripts]/pf-jobs/server/devices_capture.lua',
    '[pfscripts]/pf-jobs/server/apps/tow.lua',
    '[pfscripts]/pf-jobs/server/devices.lua',
})
GetResourceState = started
Config.Tow.UseDatabase = false
load_resource('[pfscripts]/pf-devices/shared/config.lua')
Config.Rpc.burst, Config.Rpc.perSecond = 1000, 1000
load_resource('[pfscripts]/pf-devices/server/registry.lua')
load_resource('[pfscripts]/pf-devices/server/installs.lua')
load_resource('[pfscripts]/pf-devices/server/rpc.lua')
load_resource('[pfscripts]/pf-devices/server/push.lua')
assert(PFJobsDevices.Register(), 'apps registered')

local DRIVER, CITIZEN = 1, 2
local C = Config.Tow
local BAY = vector3(C.FlatbedSpawn.x, C.FlatbedSpawn.y, C.FlatbedSpawn.z)
local DEPOSIT = C.Vehicles[1].deposit

local function rpc(src, method, payload) return PFDevices.HandleRpc(src, 'tow', method, payload) end
local function money(src, kind) return Mock.players[src].PlayerData.money[kind] end
local function seesTow(src)
    for _, a in ipairs(PFDevices.GetAppsFor(src, 'tablet').apps) do if a.id == 'tow' then return true end end
    return false
end
local function appsChangedFor(src)
    local n = 0
    for _, e in ipairs(Mock.clientEventsNamed('pf-devices:client:appsChanged')) do if e.target == src then n = n + 1 end end
    return n
end
local function leaveJob(src) Mock.players[src].PlayerData.job = { name = 'unemployed', grade = { level = 0 }, onduty = false } end

-- the driver rents a flatbed at the bay through the app, then stands next to it
local function rentTruck()
    Mock.coords[DRIVER] = BAY
    local res = rpc(DRIVER, 'rentFlatbed', { model = 'flatbed' })
    assert_eq(res.ok, true, 'rented')
    local truck = Mock.nextNetId
    lastVeh[DRIVER] = truck
    return truck
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    bankDown = false
    Mock.clock = Mock.clock + 100000
    for src = 1, 3 do PFJobsTow.Dropped(src) end
    for _, cid in ipairs({ 'CID1', 'CID2', 'CID3' }) do PFJobsTow.ForgetCitizen(cid) end
    Mock.players, Mock.coords, Mock.models, Mock.deleted = {}, {}, {}, {}
    alive, inVeh, lastVeh, installs = {}, {}, {}, {}
    local d = Mock.newPlayer(DRIVER)
    d.PlayerData.job = { name = 'tow', grade = { level = 0 }, onduty = true }
    d.PlayerData.money = { cash = 1000, bank = 0 }
    Mock.newPlayer(CITIZEN).PlayerData.money = { cash = 1000, bank = 0 }
end

describe('Tow app for a player who left the tow job', function()
    it('stays on their device while a rental is open, and nobody else without the job sees it', function()
        assert_true(seesTow(DRIVER), 'a driver has the app')
        assert_false(seesTow(CITIZEN))
        assert_eq(rpc(CITIZEN, 'getInit').error, 'not_authorized')
        rentTruck()
        leaveJob(DRIVER)
        assert_true(seesTow(DRIVER), 'kept for the return')
        assert_eq(rpc(DRIVER, 'getInit').ok, true)
        -- without a rental, leaving the job takes the app away as before
        leaveJob(CITIZEN)
        assert_false(seesTow(CITIZEN))
    end)

    it('shows only the rental: no dispatch requests, contracts, levels or rent offers', function()
        local truck = rentTruck()
        leaveJob(DRIVER)
        local v = rpc(DRIVER, 'getInit')
        assert_eq(v.returnOnly, true)
        assert_eq(v.rental.plate, Mock.plates[truck])
        assert_eq(v.rental.deposit, DEPOSIT)
        assert_eq(v.atBay, true)
        for _, field in ipairs({ 'requests', 'contract', 'stats', 'level', 'levels', 'vehicles', 'config', 'contractBlocker', 'dropOff', 'onDuty' }) do
            assert_eq(v[field], nil, field .. ' is not shown')
        end
        assert_eq(rpc(DRIVER, 'refresh').returnOnly, true)
        -- a tow driver still gets the whole app
        Mock.players[DRIVER].PlayerData.job = { name = 'tow', grade = { level = 0 }, onduty = true }
        local full = rpc(DRIVER, 'getInit')
        assert_eq(full.returnOnly, nil)
        assert_true(full.levels ~= nil and full.config ~= nil)
    end)

    it('refuses every action but the return and the loss report', function()
        rentTruck()
        leaveJob(DRIVER)
        local cash, bank = money(DRIVER, 'cash'), money(DRIVER, 'bank')
        for _, call in ipairs({
            { 'rentFlatbed', { model = 'flatbed' } }, { 'startContract' }, { 'cancelContract' },
            { 'acceptRequest', { id = 3 } }, { 'completeRequest', { id = 3 } }, { 'releaseRequest', { id = 3 } },
        }) do
            local res = rpc(DRIVER, call[1], call[2])
            assert_eq(res.ok, false, call[1])
            assert_eq(res.error, 'not_tow', call[1])
            assert_eq(res.view.returnOnly, true, call[1] .. ' answers with the return-only view')
        end
        -- collecting owed pay is open to them (below); with nothing owed it pays nothing
        assert_eq(rpc(DRIVER, 'claimPay').error, 'nothing_owed')
        assert_eq(money(DRIVER, 'cash'), cash)
        assert_eq(money(DRIVER, 'bank'), bank)
    end)

    it('returns the flatbed at the bay for the deposit back, then the app leaves the device', function()
        local truck = rentTruck()
        assert_eq(money(DRIVER, 'cash'), 1000 - DEPOSIT)
        leaveJob(DRIVER)
        Mock.coords[DRIVER] = vector3(0, 0, 0)
        assert_eq(rpc(DRIVER, 'returnFlatbed').error, 'not_at_depot', 'still only at the bay')
        Mock.coords[DRIVER] = BAY
        Mock.coords[truck] = vector3(BAY.x + 500, BAY.y, BAY.z)
        assert_eq(rpc(DRIVER, 'returnFlatbed').error, 'truck_far', 'still only with the truck')
        Mock.coords[truck] = BAY
        Mock.reset()
        local res = rpc(DRIVER, 'returnFlatbed')
        assert_eq(res.ok, true)
        assert_eq(res.refund, DEPOSIT)
        assert_eq(money(DRIVER, 'bank'), DEPOSIT, 'the deposit came back')
        assert_eq(res.view.returnOnly, true)
        assert_eq(res.view.rental, nil)
        assert_false(alive[truck] == true, 'the truck is put away')
        assert_eq(appsChangedFor(DRIVER), 1, 'the device is told to drop the app')
        assert_false(seesTow(DRIVER))
        assert_eq(rpc(DRIVER, 'getInit').error, 'not_authorized')
        assert_eq(rpc(DRIVER, 'returnFlatbed').error, 'not_authorized', 'no second refund')
        assert_eq(money(DRIVER, 'bank'), DEPOSIT)
    end)

    it('a tow driver returning the flatbed keeps the app (no device refresh)', function()
        rentTruck()
        Mock.reset()
        assert_eq(rpc(DRIVER, 'returnFlatbed').ok, true)
        assert_eq(appsChangedFor(DRIVER), 0)
        assert_true(seesTow(DRIVER))
    end)

    it('reports a lost truck (the deposit covers it) and the app goes', function()
        local truck = rentTruck()
        leaveJob(DRIVER)
        assert_eq(rpc(DRIVER, 'reportLost').error, 'truck_exists', 'not while the truck is out there')
        alive[truck] = nil
        Mock.reset()
        local res = rpc(DRIVER, 'reportLost')
        assert_eq(res.ok, true)
        assert_eq(money(DRIVER, 'bank'), 0, 'no refund for a lost truck')
        assert_eq(appsChangedFor(DRIVER), 1)
        assert_false(seesTow(DRIVER))
    end)

    it('settles a rental left behind by a disconnect after logging back in on another job', function()
        rentTruck()
        PFJobsTow.Dropped(DRIVER) -- the truck was at the bay when they left
        Mock.players[DRIVER] = nil
        local back = Mock.newPlayer(3, 'CID1')
        back.PlayerData.job = { name = 'mechanic', grade = { level = 0 }, onduty = true }
        Mock.coords[3] = BAY
        assert_true(seesTow(3))
        local v = rpc(3, 'getInit')
        assert_eq(v.returnOnly, true)
        assert_eq(v.rental.orphaned, true)
        assert_eq(v.rental.refund, DEPOSIT)
        assert_eq(rpc(3, 'returnFlatbed').refund, DEPOSIT)
        assert_eq(back.PlayerData.money.bank, DEPOSIT)
        assert_false(seesTow(3))
    end)

    it('a car still on the bed has to come off first, which needs no tow job', function()
        local truck = rentTruck()
        local car = CreateVehicleServerSetter(GetHashKey('sultan'), 'automobile', BAY.x, BAY.y + 6, BAY.z)
        Mock.plates[car] = 'CAR123'
        Mock.coords[truck] = BAY
        Mock.coords[DRIVER] = vector3(BAY.x + 2, BAY.y, BAY.z)
        assert_eq(PFJobsTow.Hook(DRIVER, car, true).ok, true, 'hooked as a driver')
        leaveJob(DRIVER)
        local v = rpc(DRIVER, 'getInit')
        assert_eq(v.hook.plate, 'CAR123', 'the app says the bed is loaded')
        assert_eq(rpc(DRIVER, 'returnFlatbed').error, 'truck_loaded')
        Mock.fireNet('pf-jobs:tow:server:unhook', DRIVER) -- what /tow sends
        local res = rpc(DRIVER, 'returnFlatbed')
        assert_eq(res.ok, true)
        assert_eq(res.refund, DEPOSIT)
    end)
end)

-- a contract delivered while the bank is down: its pay is owed (payment_due)
local function deliverUnpaid()
    local truck = rentTruck()
    assert_eq(rpc(DRIVER, 'startContract').ok, true)
    local car = Mock.nextNetId
    local c = PFJobsTow.View(DRIVER).contract
    Mock.coords[truck] = vector3(c.x, c.y, c.z)
    Mock.coords[car] = vector3(c.x, c.y + 6, c.z)
    Mock.coords[DRIVER] = vector3(c.x + 2, c.y, c.z)
    assert_eq(PFJobsTow.Hook(DRIVER, car, true).ok, true)
    Mock.clock = Mock.clock + 900
    local drop = C.DropOff.coords
    Mock.coords[truck], Mock.coords[car], Mock.coords[DRIVER] = drop, drop, drop
    bankDown = true
    assert_eq(PFJobsTow.Unhook(DRIVER, true).delivered, false)
    bankDown = false
    assert_eq(PFJobsTow.View(DRIVER).contract.stage, 'payment_due')
    return truck, c
end
local function returnTruck(truck)
    Mock.coords[DRIVER], Mock.coords[truck] = BAY, BAY
    assert_eq(rpc(DRIVER, 'returnFlatbed').ok, true)
end

describe('Tow pay owed to a driver who left the job', function()
    it('is collected from the return-only view, once, and then the app leaves the device', function()
        local truck, c = deliverUnpaid()
        returnTruck(truck)
        leaveJob(DRIVER)
        assert_true(seesTow(DRIVER), 'kept for the pay owed, with no rental')
        local v = rpc(DRIVER, 'getInit')
        assert_eq(v.returnOnly, true)
        assert_eq(v.rental, nil)
        assert_eq(v.owed.pay, c.pay)
        assert_eq(v.owed.plate, c.plate)
        for _, field in ipairs({ 'requests', 'contract', 'stats', 'level', 'vehicles', 'config', 'contractBlocker' }) do
            assert_eq(v[field], nil, field .. ' is not shown')
        end
        local bank = money(DRIVER, 'bank')
        Mock.reset()
        local res = rpc(DRIVER, 'claimPay')
        assert_eq(res.ok, true, 'it was refused as not_tow before')
        assert_eq(res.paid, c.pay)
        assert_eq(money(DRIVER, 'bank'), bank + c.pay)
        assert_eq(#LedgerEnv.paid('pf-jobs:tow:contract:'), 1)
        assert_eq(appsChangedFor(DRIVER), 1, 'the device is told to drop the app')
        assert_false(seesTow(DRIVER))
        assert_eq(rpc(DRIVER, 'claimPay').error, 'not_authorized', 'no second pay')
        assert_eq(#LedgerEnv.paid('pf-jobs:tow:contract:'), 1)
    end)

    it('shows the pay next to an open rental; the app stays for the rental after the claim', function()
        local _, c = deliverUnpaid()
        leaveJob(DRIVER)
        local v = rpc(DRIVER, 'refresh')
        assert_true(v.rental ~= nil and v.owed ~= nil)
        assert_eq(rpc(DRIVER, 'claimPay').paid, c.pay)
        assert_true(seesTow(DRIVER), 'the flatbed is still to return')
        assert_eq(rpc(DRIVER, 'refresh').owed, nil)
    end)

    it('a claim the bank still cannot pay stays owed, and the same key pays it later', function()
        local truck, c = deliverUnpaid()
        returnTruck(truck)
        leaveJob(DRIVER)
        bankDown = true
        assert_eq(rpc(DRIVER, 'claimPay').error, 'bank_unavailable')
        bankDown = false
        assert_eq(rpc(DRIVER, 'refresh').owed.pay, c.pay)
        assert_eq(rpc(DRIVER, 'claimPay').ok, true)
        assert_eq(#LedgerEnv.paid('pf-jobs:tow:contract:'), 1)
    end)
end)

describe('Tow app open while the player leaves the job', function()
    local function statePushes(src)
        local n = 0
        for _, e in ipairs(Mock.clientEventsNamed('pf-jobs:tow:client:state')) do if e.target == src then n = n + 1 end end
        return n
    end

    it('the job change pushes the state, and the view the app then fetches is the return-only one', function()
        rentTruck()
        assert_eq(rpc(DRIVER, 'refresh').returnOnly, nil, "the driver's layout")
        Mock.reset()
        leaveJob(DRIVER)
        Mock.fireEvent('QBCore:Server:OnJobUpdate', nil, DRIVER, Mock.players[DRIVER].PlayerData.job)
        assert_eq(statePushes(DRIVER), 1, 'the open app is told to fetch its view again')
        assert_eq(rpc(DRIVER, 'refresh').returnOnly, true)
    end)

    it('a player with nothing open is not pushed (the app just leaves their device)', function()
        Mock.reset()
        leaveJob(DRIVER)
        Mock.fireEvent('QBCore:Server:OnJobUpdate', nil, DRIVER, Mock.players[DRIVER].PlayerData.job)
        assert_eq(statePushes(DRIVER), 0)
        assert_false(seesTow(DRIVER))
    end)
end)

describe('Tow deposit the bank has not settled', function()
    it('is told as still settling (not "cannot pay"), and the retry uses the same key', function()
        Mock.coords[DRIVER] = BAY
        local bankExports = Mock.exportsByResource['pfm-banking']
        local realTransfer = bankExports.Transfer
        local keys = {}
        bankExports.Transfer = function(_, opts)
            keys[#keys + 1] = opts.key
            return { ok = false, state = 'pending', txId = 77, error = 'in_progress' }
        end
        local res = rpc(DRIVER, 'rentFlatbed', { model = 'flatbed' })
        assert_eq(res.error, 'deposit_pending')
        assert_eq(res.message, PFJobsTow.Messages.deposit_pending)
        assert_true(res.message ~= PFJobsTow.Messages.insufficient_funds, 'it used to say "You cannot pay the deposit"')
        assert_eq(#keys, 1, 'not tried on the bank account too')
        assert_eq(rpc(DRIVER, 'rentFlatbed', { model = 'flatbed' }).error, 'deposit_pending')
        assert_eq(keys[2], keys[1], 'asked again under the same key')
        -- the ledger settles it: the same key now goes through, and the truck comes out
        bankExports.Transfer = realTransfer
        local ok = rpc(DRIVER, 'rentFlatbed', { model = 'flatbed' })
        assert_eq(ok.ok, true)
        local charged = LedgerEnv.paid('pf-jobs:tow:rent:')
        assert_eq(#charged, 1, 'one deposit')
        assert_eq(charged[1].idempotency_key, keys[1])
        assert_eq(money(DRIVER, 'cash'), 1000 - DEPOSIT)
        -- the next rental after this one has its own key again
        assert_eq(PFJobsTow.View(DRIVER).rental.deposit, DEPOSIT)
    end)

    it('a payment the bank turned down says nothing was charged', function()
        Mock.coords[DRIVER] = BAY
        local bankExports = Mock.exportsByResource['pfm-banking']
        local realTransfer = bankExports.Transfer
        bankExports.Transfer = function() return { ok = false, state = 'compensated', txId = 78, error = 'reversed' } end
        local res = rpc(DRIVER, 'rentFlatbed', { model = 'flatbed' })
        bankExports.Transfer = realTransfer
        assert_eq(res.error, 'payment_failed')
        assert_eq(res.message, PFJobsTow.Messages.payment_failed)
        assert_eq(PFJobsTow.View(DRIVER).rental, nil)
    end)
end)

describe('Tow: round-2 checks (an unclear deposit through a bank outage, owed pay keys, claims at once)', function()
    local bankExports = Mock.exportsByResource['pfm-banking']
    local realTransfer, realGet = bankExports.Transfer, bankExports.GetTransaction
    local function restoreBank() bankExports.Transfer, bankExports.GetTransaction = realTransfer, realGet end

    it('a retry while the bank is down keeps the unsettled key: the next try asks under it again', function()
        Mock.coords[DRIVER] = BAY
        local keys = {}
        bankExports.Transfer = function(_, opts)
            keys[#keys + 1] = opts.key
            return { ok = false, state = 'pending', txId = 77, error = 'in_progress' }
        end
        assert_eq(rpc(DRIVER, 'rentFlatbed', { model = 'flatbed' }).error, 'deposit_pending')
        -- the ledger is not ready (its startup recovery), then pfm-banking is stopped
        bankExports.Transfer = function(_, opts)
            keys[#keys + 1] = opts.key
            return { ok = false, error = 'ledger_unavailable' }
        end
        assert_eq(rpc(DRIVER, 'rentFlatbed', { model = 'flatbed' }).error, 'bank_unavailable')
        bankDown = true
        assert_eq(rpc(DRIVER, 'rentFlatbed', { model = 'flatbed' }).error, 'bank_unavailable')
        bankDown = false
        restoreBank()
        assert_eq(rpc(DRIVER, 'rentFlatbed', { model = 'flatbed' }).ok, true)
        local charged = LedgerEnv.paid('pf-jobs:tow:rent:')
        assert_eq(#charged, 1, 'one deposit')
        assert_eq(keys[2], keys[1])
        assert_eq(charged[1].idempotency_key, keys[1], "the first unclear charge's key, never a new one")
        assert_eq(money(DRIVER, 'cash'), 1000 - DEPOSIT)
    end)

    it('a refused deposit (settled) frees the key: the next rental asks under a new one', function()
        Mock.coords[DRIVER] = BAY
        local keys = {}
        bankExports.Transfer = function(_, opts)
            keys[#keys + 1] = opts.key
            return { ok = false, state = 'pending', txId = 77, error = 'in_progress' }
        end
        rpc(DRIVER, 'rentFlatbed', { model = 'flatbed' })
        bankExports.Transfer = function(_, opts)
            keys[#keys + 1] = opts.key
            return { ok = false, duplicate = true, state = 'compensated', txId = 77, error = 'reversed' }
        end
        assert_eq(rpc(DRIVER, 'rentFlatbed', { model = 'flatbed' }).error, 'payment_failed')
        restoreBank()
        assert_eq(rpc(DRIVER, 'rentFlatbed', { model = 'flatbed' }).ok, true)
        local charged = LedgerEnv.paid('pf-jobs:tow:rent:')
        assert_eq(#charged, 1)
        assert_true(charged[1].idempotency_key ~= keys[1], 'the reversed key returns its reversal forever')
    end)

    it('owed pay the bank turned down for good is claimed under the next numbered key', function()
        local truck = deliverUnpaid()
        returnTruck(truck)
        local dead
        bankExports.Transfer = function(self, opts)
            if opts.key:find('pf-jobs:tow:contract:', 1, true) == 1 and (dead == nil or opts.key == dead) then
                -- the credit to the player failed and was reversed: the ledger keeps this result
                dead = opts.key
                return { ok = false, duplicate = true, state = 'compensated', txId = 90, error = 'credit_failed' }
            end
            return realTransfer(opts) -- the real ledger export (registered by pfm-banking: no self)
        end
        bankExports.GetTransaction = function(self, k)
            if k == dead then return { state = 'compensated', error = 'credit_failed' } end
            return realGet(k)
        end
        local first = rpc(DRIVER, 'claimPay')
        assert_eq(first.error, 'pay_pending', 'not told as a bank that did not answer')
        local bank = money(DRIVER, 'bank')
        local res = rpc(DRIVER, 'claimPay')
        restoreBank()
        assert_eq(res.ok, true, 'the first key returned its refusal forever')
        local rows = LedgerEnv.paid('pf-jobs:tow:contract:')
        assert_eq(#rows, 1)
        assert_eq(rows[1].idempotency_key, dead .. ':1')
        assert_eq(money(DRIVER, 'bank'), bank + res.paid)
        assert_eq(rpc(DRIVER, 'claimPay').error, 'nothing_owed')
        assert_eq(#LedgerEnv.paid('pf-jobs:tow:contract:'), 1)
    end)

    it('two claims at once: the second is refused while the first waits on the bank, and it counts once', function()
        local truck = deliverUnpaid()
        returnTruck(truck)
        local before = PFJobsTow.View(DRIVER).stats
        local nested
        bankExports.Transfer = function(self, opts)
            if not nested and opts.key:find('pf-jobs:tow:contract:', 1, true) == 1 then
                nested = PFJobsTow.ClaimPay(DRIVER, true) -- a second claim while the bank works on the first
            end
            return realTransfer(opts) -- the real ledger export (registered by pfm-banking: no self)
        end
        local res = PFJobsTow.ClaimPay(DRIVER, true)
        restoreBank()
        assert_eq(res.ok, true)
        assert_eq(nested.error, 'busy')
        local after = PFJobsTow.View(DRIVER).stats
        assert_eq(after.contracts, before.contracts + 1, 'the contract counts once')
        assert_eq(after.earned, before.earned + res.paid, 'its pay counts once')
        assert_eq(#LedgerEnv.paid('pf-jobs:tow:contract:'), 1)
    end)

    it("a window's refresh carries the config for a driver (a return-only window that becomes one again)", function()
        rentTruck()
        leaveJob(DRIVER)
        local ro = rpc(DRIVER, 'getInit')
        assert_eq(ro.returnOnly, true)
        assert_eq(ro.config, nil)
        Mock.players[DRIVER].PlayerData.job = { name = 'tow', grade = { level = 0 }, onduty = true }
        local v = rpc(DRIVER, 'refresh')
        assert_eq(v.returnOnly, nil)
        assert_true(type(v.config) == 'table' and v.config.payBase ~= nil, 'the contracts tab has its numbers')
    end)
end)

-- ── the world side: /tow on the client ──────────────────────────────

local CLIENT = '[pfscripts]/pf-jobs/client/tow.lua'
local toServer, bars, notes
local function loadClient()
    toServer, bars, notes = {}, {}, {}
    -- a fresh client: only the handlers this load registers
    for name in pairs(Mock.netHandlerList) do
        if name:find('^pf%-jobs:tow:client:') then Mock.netHandlerList[name], Mock.netHandlers[name] = nil, nil end
    end
    local prevCommands = Mock.rawCommands
    Mock.rawCommands = {}
    QBCoreMock.Functions.Notify = function(msg) notes[#notes + 1] = msg end
    QBCoreMock.Functions.Progressbar = function(name, _, _, _, _, _, _, _, _, onFinish)
        bars[#bars + 1] = { name = name, finish = onFinish }
    end
    QBCoreMock.Functions.GetPlayerData = function() return { job = { name = 'unemployed' } } end
    local noop = function() return nil end
    local TRUCK = 900
    local own = {
        TriggerServerEvent = function(name, ...) toServer[#toServer + 1] = { name = name, args = { ... } } end,
        CreateThread = noop, SetTimeout = noop, Wait = noop,
        PlayerPedId = function() return 1 end,
        -- the player stands by their flatbed (last vehicle), on foot, facing nothing
        GetVehiclePedIsIn = function(_, last) return last and TRUCK or 0 end,
        GetEntityModel = function(e) return e == TRUCK and GetHashKey('flatbed') or 0 end,
        DoesEntityExist = function(e) return e == TRUCK end,
        IsPedInAnyVehicle = function() return false end,
        GetRaycastResult = function() return 0, false, nil, nil, 0 end,
        GetEntityCoords = function() return vector3(0, 0, 0) end,
        GetOffsetFromEntityInWorldCoords = function() return vector3(0, 5, 0) end,
    }
    local env = setmetatable(own, { __index = function(_, k)
        local v = _G[k]
        if v ~= nil then return v end
        if type(k) == 'string' and k:match('^%u') then return noop end
    end })
    assert(load(__readfile(CLIENT), '@' .. CLIENT, 't', env))()
    local commands = Mock.rawCommands
    Mock.rawCommands = prevCommands
    return commands
end
local function sent(name)
    local n = 0
    for _, e in ipairs(toServer) do if e.name == name then n = n + 1 end end
    return n
end
local function lastBar() return bars[#bars] and bars[#bars].name end

describe('/tow on the client', function()
    it('takes the car off when the server says one is on the bed, even after the client lost its own state', function()
        local commands = loadClient()
        -- what the server pushes after a hook (T.Push); the client's attach event was never seen
        Mock.fireNetAll('pf-jobs:tow:client:state', nil, { hooked = true, rental = true })
        commands.tow()
        assert_eq(lastBar(), 'untowing_vehicle', 'unhook, not a new hook attempt')
        bars[#bars].finish()
        assert_eq(sent('pf-jobs:tow:server:unhook'), 1)
        assert_eq(sent('pf-jobs:tow:server:hook'), 0)
    end)

    it('with nothing on the bed /tow still means hooking a car', function()
        local commands = loadClient()
        Mock.fireNetAll('pf-jobs:tow:client:state', nil, { hooked = false, rental = true })
        commands.tow()
        assert_eq(#bars, 0, 'no car in front of the player')
        assert_eq(notes[#notes], 'Face the car you want to tow')
        assert_eq(sent('pf-jobs:tow:server:unhook'), 0)
    end)
end)
