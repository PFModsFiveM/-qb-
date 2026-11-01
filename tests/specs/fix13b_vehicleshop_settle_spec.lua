-- pfm-vehicleshop on the real ledger (fake database): a charge the bank cannot confirm yet
-- (PFPayout.Charge res.unclear) gives no car now and is never charged again; the sale is held and
-- finished (the car parked for the buyer) or released when the ledger settles. Payments owed after
-- a buyer paid (the seller, a refund, the dealership) are kept and retried with numbered keys until
-- they are paid, once. Finance payments stop on an unclear result instead of charging the next
-- account or a new key. Repossession takes only an overdue car and tells pf-jobgarages. A failed
-- fleet-table lookup refuses instead of being cached as "no fleet".
load_resource('tests/lua/ledger_env.lua')
Commands = {}
QBCoreMock.Commands.Add = function(name, _, _, _, fn) Commands[name] = fn end
QBCoreMock.Functions.GetIdentifier = function(src) return 'license:' .. tostring(src) end
QBCoreMock.Shared = QBCoreMock.Shared or {}
QBCoreMock.Shared.Vehicles = {
    blista = { name = 'Blista', price = 10000, shop = 'pdm', category = 'compacts' },
    cognoscenti = { name = 'Cognoscenti', price = 100000, shop = 'luxury', category = 'sedans' },
}
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end

local vehicles = {}   -- player_vehicles: [plate] = row
local fleet = {}      -- job_garage_vehicles (active): [plate] = id
local fleetLookupBroken = false
local stealOnClaim = false   -- the car leaves the seller in the moment between the buyer's payment and the change
local function lastQuery() return FakeDB.log[#FakeDB.log] end

-- the two settlement tables, as the real ones behave (rows copied out, unique keys)
local store = { owed = {}, held = {}, n = 0 }
local function copy(r) local c = {} for k, v in pairs(r) do c[k] = v end return c end
local function rowsOf(t, keep)
    local out = {}
    for _, r in pairs(t) do if keep(r) then out[#out + 1] = copy(r) end end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end
local function settlePatterns(prefix)
    return {
        { 'INSERT IGNORE INTO ' .. prefix .. '_owed', function(p)
            for _, r in pairs(store.owed) do if r.ledger_key == p[1] then return 0 end end
            store.n = store.n + 1
            store.owed[store.n] = { id = store.n, ledger_key = p[1], attempt = p[2], to_kind = p[3], to_id = p[4], account = p[5], amount = p[6],
                kind = p[7], reason = p[8], state = p[9], last_error = p[10] }
            return store.n
        end },
        { 'FROM ' .. prefix .. "_owed WHERE state = 'open'", function() return rowsOf(store.owed, function(r) return r.state == 'open' end) end },
        { 'UPDATE ' .. prefix .. '_owed SET attempt = ?, state = ?, last_error = ? WHERE id = ?', function(p)
            local r = store.owed[p[4]]
            if not r then return 0 end
            r.attempt, r.state, r.last_error = p[1], p[2], p[3]
            return 1
        end },
        { 'INSERT INTO ' .. prefix .. '_held', function(p)
            local row
            for _, r in pairs(store.held) do if r.charge_key == p[2] then row = r end end
            if not row then
                store.n = store.n + 1
                row = { id = store.n }
                store.held[store.n] = row
            end
            row.flow, row.charge_key, row.accounts, row.tx_id, row.citizenid, row.plate, row.amount, row.data, row.state, row.outcome, row.created =
                p[1], p[2], p[3], p[4], p[5], p[6], p[7], p[8], 'waiting', nil, p[9]
            return row.id
        end },
        { 'FROM ' .. prefix .. "_held WHERE state IN ('waiting', 'finishing')", function()
            return rowsOf(store.held, function(r) return r.state == 'waiting' or r.state == 'finishing' end)
        end },
        { 'UPDATE ' .. prefix .. '_held SET state = ?, outcome = ? WHERE id = ? AND state = ?', function(p)
            local r = store.held[p[3]]
            if not r or r.state ~= p[4] then return 0 end
            r.state, r.outcome = p[1], p[2]
            return 1
        end },
        { 'UPDATE ' .. prefix .. '_held SET data = ? WHERE id = ?', function(p)
            local r = store.held[p[2]]
            if r then r.data = p[1] end
            return r and 1 or 0
        end },
    }
end

FakeDB.extraPatterns = settlePatterns('pfm_vehicleshop')
for _, entry in ipairs({
    { "AND TABLE_NAME = 'job_garage_vehicles'", function()
        if fleetLookupBroken then return nil end   -- what oxmysql gives for a query that failed
        return 1
    end },
    { 'SELECT id FROM job_garage_vehicles WHERE plate = ? AND active = 1', function(p) return fleet[p[1]] end },
    { 'SELECT citizenid, vehicle, balance FROM player_vehicles WHERE plate = ?', function(p) return vehicles[p[1]] and { vehicles[p[1]] } or {} end },
    { 'UPDATE player_vehicles SET citizenid = ?, license = ? WHERE plate = ? AND citizenid = ? AND balance <= ?', function(p)
        local v = vehicles[p[3]]
        if v and stealOnClaim then v.citizenid = 'CID9' end
        if not v or v.citizenid ~= p[4] or (v.balance or 0) > p[5] then return 0 end
        if lastQuery():find('NOT EXISTS', 1, true) and fleet[p[6]] then return 0 end
        v.citizenid = p[1]
        return 1
    end },
    { 'SELECT plate FROM player_vehicles WHERE plate = ?', function(p) return vehicles[p[1]] and p[1] or nil end },
    { 'SELECT citizenid FROM player_vehicles WHERE plate = ?', function(p) return vehicles[p[1]] and vehicles[p[1]].citizenid or nil end },
    { 'INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, garage, state, balance', function(p)
        vehicles[p[6]] = { citizenid = p[2], vehicle = p[3], plate = p[6], garage = p[7], state = p[8], balance = p[9], paymentamount = p[10], paymentsleft = p[11], financetime = p[12] }
        return 1
    end },
    { 'INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, garage, state)', function(p)
        vehicles[p[6]] = { citizenid = p[2], vehicle = p[3], plate = p[6], garage = p[7], state = p[8], balance = 0 }
        return 1
    end },
    { 'SELECT balance, paymentamount, paymentsleft, financetime FROM player_vehicles WHERE plate = ? AND citizenid = ?', function(p)
        local v = vehicles[p[1]]
        return (v and v.citizenid == p[2]) and { v } or {}
    end },
    { 'SELECT balance, paymentsleft FROM player_vehicles WHERE plate = ? AND citizenid = ?', function(p)
        local v = vehicles[p[1]]
        return (v and v.citizenid == p[2]) and { v } or {}
    end },
    { 'SELECT balance FROM player_vehicles WHERE plate = ? AND citizenid = ?', function(p)
        local v = vehicles[p[1]]
        return (v and v.citizenid == p[2]) and { v } or {}
    end },
    -- a finance payment applies only to the balance it was paid for
    { 'UPDATE player_vehicles SET balance = ?, paymentamount = ?, paymentsleft = ?, financetime = ? WHERE plate = ? AND citizenid = ? AND balance = ?', function(p)
        local v = vehicles[p[5]]
        if not v or v.citizenid ~= p[6] or v.balance ~= p[7] then return 0 end
        v.balance, v.paymentamount, v.paymentsleft, v.financetime = p[1], p[2], p[3], p[4]
        return 1
    end },
    -- repossession: only the owner's car, still owing and overdue
    { 'DELETE FROM player_vehicles WHERE plate = ? AND citizenid = ? AND balance > 0 AND financetime < 1', function(p)
        local v = vehicles[p[1]]
        if not v or v.citizenid ~= p[2] or (v.balance or 0) <= 0 or (v.financetime or 0) >= 1 then return { affectedRows = 0 } end
        vehicles[p[1]] = nil
        return { affectedRows = 1 }
    end },
    { 'SELECT * FROM player_vehicles WHERE citizenid = ? AND balance > 0 AND financetime < 1', function(p)
        local out = {}
        for _, v in pairs(vehicles) do if v.citizenid == p[1] and (v.balance or 0) > 0 and (v.financetime or 0) < 1 then out[#out + 1] = v end end
        return out
    end },
    { 'SELECT citizenid, balance FROM player_vehicles WHERE plate = ?', function(p) return vehicles[p[1]] and { vehicles[p[1]] } or {} end },
    -- dealership stock: [shop:model] = cars
    { 'SELECT stock FROM pfm_vehicleshop_stock', function(p) return store.stock[p[1] .. ':' .. p[2]] end },
    { 'INSERT IGNORE INTO pfm_vehicleshop_stock', function(p)
        local k = p[1] .. ':' .. p[2]
        if store.stock[k] == nil then store.stock[k] = p[3] end
        return 1
    end },
    { 'SET stock = stock - 1', function(p)
        local k = p[1] .. ':' .. p[2]
        if (store.stock[k] or 0) < 1 then return 0 end
        store.stock[k] = store.stock[k] - 1
        return 1
    end },
    { 'SET stock = stock + 1', function(p)
        local k = p[1] .. ':' .. p[2]
        store.stock[k] = (store.stock[k] or 0) + 1
        return 1
    end },
    { 'INSERT IGNORE INTO pfm_vehicleshop_sales', function(p) store.sales = (store.sales or 0) + 1 return 1 end },
}) do FakeDB.extraPatterns[#FakeDB.extraPatterns + 1] = entry end

LedgerEnv.load('pfm-vehicleshop', { 'pfm-vehicleshop/config.lua', 'pfm-vehicleshop/settlements.lua', 'pfm-vehicleshop/server.lua' })

-- ── ledger outcomes the bank cannot confirm at once ─────────────────────────────────────────────
-- the write that moves a charge from 'debited' to 'completed' fails once: the money left the
-- buyer, the ledger's recovery completes it later
local failCredit = false
local fakeUpdate = MySQL.update
MySQL.update = setmetatable({ await = function(q, p)
    if failCredit and q == PFLedger.SQL.setState and p[1] == 'completed' and p[4] == 'debited' then
        failCredit = false
        error('injected: the credit write failed')
    end
    return fakeUpdate.await(q, p)
end }, { __call = function(_, ...) return fakeUpdate(...) end })

-- replies the bank gives for given keys instead of running the transfer
local bank = Mock.exportsByResource['pfm-banking']
local realTransfer = bank.Transfer
local intercept = {}
bank.Transfer = function(opts)
    local r = intercept[opts.key]
    if r then return type(r) == 'function' and r(opts) or r end
    return realTransfer(opts)
end
Mock.rawExports[bank.Transfer] = true

local BUYER, DEALER, STRANGER = 1, 2, 3
local PDM = Config.Shops.pdm.Location
local LUX = Config.Shops.luxury.Location
local function money(src) return Mock.players[src].PlayerData.money end
local function count(tbl) local n = 0 for _ in pairs(tbl) do n = n + 1 end return n end
local function first() for _, v in pairs(vehicles) do return v end end
local function holds() return rowsOf(store.held, function() return true end) end
local function owed() return rowsOf(store.owed, function() return true end) end
local function completed(prefix) return #LedgerEnv.paid(prefix) end
local function lastPrompt()
    local shown = Mock.clientEventsNamed('qb-vehicleshop:client:confirmPurchase')
    return shown[#shown] and shown[#shown].args[1]
end
local function answer(src, accept)
    local last = lastPrompt()
    Mock.fireNet('qb-vehicleshop:server:answerPurchase', src, { accept = accept, id = last and last.id })
end
local function told(src, key)
    for _, e in ipairs(Mock.clientEventsNamed('QBCore:Notify')) do
        if e.target == src and e.args[1] == key then return true end
    end
    return false
end
local function settle() Mock.clock = Mock.clock + 120 PFLedger.Recover() PFSettle.Sweep() end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players, Mock.coords = {}, {}
    Mock.vehicleOf, Mock.plates = {}, {}
    vehicles, fleet, fleetLookupBroken, failCredit, intercept, stealOnClaim = {}, {}, false, false, {}, false
    store.owed, store.held, store.sales, store.stock = {}, {}, 0, {}
    Mock.clock = Mock.clock + 120   -- offers left open by an earlier test have expired
    FakeDB.society('cardealer', 0)
    for src = 1, 3 do
        local p = Mock.newPlayer(src)
        p.PlayerData.money = { cash = 0, bank = 200000 }
        p.PlayerData.license = 'license:' .. src
        Mock.coords[src] = vector3(PDM.x, PDM.y, PDM.z)
        FakeDB.players[p.PlayerData.citizenid] = { citizenid = p.PlayerData.citizenid, money = json.encode(p.PlayerData.money) }
    end
    Mock.players[DEALER].PlayerData.job = { name = 'cardealer', type = 'none', onduty = true }
    PFShop.dbReady = RunMigrations('pfm-vehicleshop', PFShop.Migrations) == true
    PFSettle.Start()
end

-- first in the file: the table lookup has not been answered yet (a found table is kept)
describe('the fleet check fails closed', function()
    it('a failed table lookup refuses the transfer and is asked again next time (not cached as "no fleet")', function()
        vehicles['MYCAR1'] = { citizenid = 'CID3', vehicle = 'blista', plate = 'MYCAR1', balance = 0 }
        Mock.vehicleOf[STRANGER] = 900
        Mock.plates[900] = 'MYCAR1'
        fleet.MYCAR1 = 4
        fleetLookupBroken = true
        Commands.transfervehicle(STRANGER, { tostring(BUYER) })
        assert_eq(vehicles.MYCAR1.citizenid, 'CID3', 'refused while it cannot be told')
        assert_true(told(STRANGER, 'error.fleet_vehicle'))
        -- asked again, not cached as "no table" (the old code gave the fleet car away here)
        fleetLookupBroken = false
        Commands.transfervehicle(STRANGER, { tostring(BUYER) })
        assert_eq(vehicles.MYCAR1.citizenid, 'CID3', 'the fleet car is known as one')
        fleet.MYCAR1 = nil
        Commands.transfervehicle(STRANGER, { tostring(BUYER) })
        assert_eq(vehicles.MYCAR1.citizenid, 'CID1')
    end)
end)

describe('the settlement tables', function()
    it('the migration creates them, and the sweep finds nothing to do on a fresh server', function()
        assert_true(PFShop.dbReady)
        assert_true(FakeDB.migrations['pfm-vehicleshop:2'], 'v2 applied')
        PFSettle.Sweep()
        assert_eq(#holds(), 0)
    end)
end)

describe('a showroom purchase the bank cannot confirm yet', function()
    it('no car now, nothing more charged, the car parked for the buyer once the charge completes', function()
        money(BUYER).cash = 20000
        failCredit = true
        Mock.fireNet('qb-vehicleshop:server:buyShowroomVehicle', BUYER, { buyVehicle = 'blista' })
        assert_eq(count(vehicles), 0, 'no car while the charge is unknown')
        assert_eq(money(BUYER).cash, 10000, 'the cash left the buyer')
        assert_eq(money(BUYER).bank, 200000, 'the bank account was not charged on top')
        local h = holds()
        assert_eq(#h, 1)
        assert_eq(h[1].flow, 'showroom')
        assert_eq(h[1].accounts, 'cash,bank')
        assert_true(told(BUYER, 'general.payment_held'), 'the buyer is told what happens')
        assert_eq(#Mock.clientEventsNamed('qb-vehicleshop:client:buyShowroomVehicle'), 0, 'nothing is handed over')
        -- a second click while it waits buys nothing
        Mock.fireNet('qb-vehicleshop:server:buyShowroomVehicle', BUYER, { buyVehicle = 'blista' })
        assert_eq(money(BUYER).cash, 10000)
        assert_eq(money(BUYER).bank, 200000)
        assert_true(told(BUYER, 'error.payment_waiting'))
        -- not settled yet: the sweep waits
        PFSettle.Sweep()
        assert_eq(count(vehicles), 0)
        -- the ledger's recovery completes the charge; the sweep finishes the sale
        settle()
        assert_eq(count(vehicles), 1)
        local car = first()
        assert_eq(car.citizenid, 'CID1')
        assert_eq(car.vehicle, 'blista')
        assert_eq(car.state, 1, 'parked, not out in the world')
        assert_eq(car.garage, Config.DeliveryGarage)
        assert_eq(store.held[h[1].id].state, 'done')
        assert_true(told(BUYER, 'general.held_delivered'))
        -- once: another sweep changes nothing, and the buyer can buy again
        settle()
        assert_eq(count(vehicles), 1)
        assert_eq(money(BUYER).cash, 10000)
        assert_false(PFSettle.BuyerWaiting('CID1'))
    end)

    it('a charge that never reached the ledger is released after the grace time: no car, nothing taken', function()
        intercept = { }
        local key
        bank.Transfer = function(opts)
            if opts.key:find('^pfm%-vehicleshop:buy:') and opts.key:find(':cash$') then key = opts.key return { ok = false, error = 'ledger_write_failed' } end
            return realTransfer(opts)
        end
        Mock.rawExports[bank.Transfer] = true
        money(BUYER).cash = 20000
        Mock.fireNet('qb-vehicleshop:server:buyShowroomVehicle', BUYER, { buyVehicle = 'blista' })
        bank.Transfer = function(opts) local r = intercept[opts.key] if r then return r end return realTransfer(opts) end
        Mock.rawExports[bank.Transfer] = true
        assert_true(key ~= nil)
        assert_eq(money(BUYER).bank, 200000, 'not charged from the bank after an unclear cash charge')
        local h = holds()
        assert_eq(#h, 1)
        settle()
        assert_eq(store.held[h[1].id].state, 'waiting', 'too early to tell: a late ledger row could still appear')
        Mock.clock = Mock.clock + PFSettle.MISSING_GRACE
        PFSettle.Sweep()
        assert_eq(store.held[h[1].id].state, 'done')
        assert_eq(store.held[h[1].id].outcome, 'none')
        assert_eq(count(vehicles), 0)
        assert_eq(money(BUYER).cash, 20000)
        assert_true(told(BUYER, 'general.held_cancelled'))
    end)

    it('a debit interrupted before it was recorded goes to review: no car, no refund, the buyer is sent to staff', function()
        money(BUYER).cash = 20000
        local p = Mock.players[BUYER]
        local realRemove = p.RemoveMoney
        p.RemoveMoney = function(kind, amount, ...)
            FakeDB.failNext.setState = true
            return realRemove(kind, amount, ...)
        end
        p.Functions.RemoveMoney = p.RemoveMoney
        Mock.fireNet('qb-vehicleshop:server:buyShowroomVehicle', BUYER, { buyVehicle = 'blista' })
        p.RemoveMoney, p.Functions.RemoveMoney = realRemove, realRemove
        assert_eq(money(BUYER).bank, 200000)
        local h = holds()
        assert_eq(#h, 1)
        settle()
        assert_eq(store.held[h[1].id].state, 'review')
        assert_eq(count(vehicles), 0, 'no car')
        assert_eq(completed('pfm-vehicleshop:buy:'), 0, 'nothing refunded or charged')
        assert_true(told(BUYER, 'general.held_review'))
        assert_false(PFSettle.BuyerWaiting('CID1'))
    end)

    it('a financed purchase held the same way keeps its terms', function()
        money(BUYER).cash = 5000
        failCredit = true
        Mock.fireNet('qb-vehicleshop:server:financeVehicle', BUYER, 2000, 8, 'blista')
        assert_eq(count(vehicles), 0)
        settle()
        local car = first()
        assert_eq(car.balance, 8000)
        assert_eq(car.paymentsleft, 8)
        assert_eq(car.state, 1)
        assert_eq(money(BUYER).cash, 3000)
        assert_eq(money(BUYER).bank, 200000)
    end)
end)

describe('a dealer sale the bank cannot confirm yet', function()
    local function atLuxury() for _, src in ipairs({ BUYER, DEALER, STRANGER }) do Mock.coords[src] = vector3(LUX.x, LUX.y, LUX.z) end end

    it('finishes once when the charge completes: the car, the dealership, the commission, the record', function()
        atLuxury()
        Mock.fireNet('qb-vehicleshop:server:sellShowroomVehicle', DEALER, 'cognoscenti', BUYER)
        failCredit = true
        answer(BUYER, true)
        assert_eq(money(BUYER).bank, 100000, 'the money left the buyer')
        assert_eq(count(vehicles), 0)
        assert_eq(money(DEALER).bank, 200000, 'nobody paid before the charge is known')
        assert_eq(FakeDB.bank_accounts.cardealer.account_balance, 0)
        assert_true(told(DEALER, 'general.sale_held_seller'))
        settle()
        assert_eq(count(vehicles), 1)
        assert_eq(first().citizenid, 'CID1')
        assert_eq(money(DEALER).bank, 200000 + 100000 * Config.Commission)
        assert_eq(FakeDB.bank_accounts.cardealer.account_balance, 100000 - 100000 * Config.Commission)
        assert_eq(store.sales, 1)
        settle()
        assert_eq(money(DEALER).bank, 200000 + 100000 * Config.Commission, 'paid once')
        assert_eq(FakeDB.bank_accounts.cardealer.account_balance, 100000 - 100000 * Config.Commission)
        assert_eq(money(BUYER).bank, 100000, 'charged once')
    end)

    it('a charge that never reached the ledger: the car goes back into stock, nobody is paid', function()
        atLuxury()
        Mock.fireNet('qb-vehicleshop:server:sellShowroomVehicle', DEALER, 'cognoscenti', BUYER)
        local id = lastPrompt().id
        intercept['pfm-vehicleshop:dealer:' .. id .. ':charge:cash'] = { ok = false, error = 'ledger_write_failed' }
        answer(BUYER, true)
        assert_eq(store.stock['luxury:cognoscenti'], Config.Stock.Initial - 1, 'reserved while it waits')
        assert_eq(money(BUYER).bank, 200000)
        Mock.clock = Mock.clock + PFSettle.MISSING_GRACE + 1
        PFSettle.Sweep()
        assert_eq(store.stock['luxury:cognoscenti'], Config.Stock.Initial, 'back in stock')
        assert_eq(count(vehicles), 0)
        assert_eq(money(DEALER).bank, 200000)
        assert_true(told(DEALER, 'general.held_sale_cancelled'))
        PFSettle.Sweep()
        assert_eq(store.stock['luxury:cognoscenti'], Config.Stock.Initial, 'returned once')
    end)

    it('a buyer whose purchase waits cannot accept another offer (it would charge them again)', function()
        atLuxury()
        Mock.fireNet('qb-vehicleshop:server:sellShowroomVehicle', DEALER, 'cognoscenti', BUYER)
        failCredit = true
        answer(BUYER, true)
        Mock.fireNet('qb-vehicleshop:server:sellShowroomVehicle', DEALER, 'cognoscenti', BUYER)
        answer(BUYER, true)
        assert_eq(money(BUYER).bank, 100000)
        assert_true(told(BUYER, 'error.payment_waiting'))
    end)
end)

describe('a paid transfer the bank cannot confirm yet', function()
    local function sellerInCar()
        vehicles['MYCAR1'] = { citizenid = 'CID3', vehicle = 'blista', plate = 'MYCAR1', balance = 0 }
        Mock.vehicleOf[STRANGER] = 900
        Mock.plates[900] = 'MYCAR1'
    end

    it('the car stays the seller\'s, cannot be given away meanwhile, and moves (seller paid once) when it clears', function()
        sellerInCar()
        Commands.transfervehicle(STRANGER, { tostring(BUYER), '5000' })
        failCredit = true
        answer(BUYER, true)
        assert_eq(vehicles.MYCAR1.citizenid, 'CID3')
        assert_eq(money(BUYER).bank, 195000)
        assert_eq(money(STRANGER).bank, 200000)
        assert_true(told(STRANGER, 'general.transfer_held_seller'))
        -- the seller cannot hand the car to someone else while it waits
        Commands.transfervehicle(STRANGER, { tostring(DEALER) })
        assert_eq(vehicles.MYCAR1.citizenid, 'CID3')
        assert_true(told(STRANGER, 'error.transfer_busy'))
        settle()
        assert_eq(vehicles.MYCAR1.citizenid, 'CID1')
        assert_eq(money(STRANGER).bank, 205000)
        settle()
        assert_eq(money(STRANGER).bank, 205000, 'paid once')
        assert_eq(money(BUYER).bank, 195000)
    end)

    it('a car that can no longer move when the payment clears: the buyer is refunded, the seller not paid', function()
        sellerInCar()
        Commands.transfervehicle(STRANGER, { tostring(BUYER), '5000' })
        failCredit = true
        answer(BUYER, true)
        stealOnClaim = true   -- the car left the seller some other way
        settle()
        stealOnClaim = false
        assert_eq(vehicles.MYCAR1.citizenid, 'CID9')
        assert_eq(money(BUYER).bank, 200000, 'refunded')
        assert_eq(money(STRANGER).bank, 200000)
    end)
end)

describe('owed payments are kept and retried until paid', function()
    local function sellerInCar()
        vehicles['MYCAR1'] = { citizenid = 'CID3', vehicle = 'blista', plate = 'MYCAR1', balance = 0 }
        Mock.vehicleOf[STRANGER] = 900
        Mock.plates[900] = 'MYCAR1'
    end

    it('a seller payout the bank does not complete is stored and paid by the sweep under the same key', function()
        sellerInCar()
        Commands.transfervehicle(STRANGER, { tostring(BUYER), '5000' })
        local key = 'pfm-vehicleshop:transfer:' .. lastPrompt().id .. ':seller'
        intercept[key] = { ok = false, error = 'ledger_write_failed' }
        answer(BUYER, true)
        assert_eq(vehicles.MYCAR1.citizenid, 'CID1')
        assert_eq(money(STRANGER).bank, 200000, 'not paid yet')
        local o = owed()
        assert_eq(#o, 1)
        assert_eq(o[1].ledger_key, key)
        assert_eq(o[1].state, 'open')
        PFSettle.Sweep()
        assert_eq(money(STRANGER).bank, 200000, 'the bank still does not take it: kept open')
        assert_eq(store.owed[o[1].id].state, 'open')
        intercept[key] = nil
        PFSettle.Sweep()
        assert_eq(money(STRANGER).bank, 205000)
        assert_eq(store.owed[o[1].id].state, 'paid')
        PFSettle.Sweep()
        assert_eq(money(STRANGER).bank, 205000, 'once')
    end)

    it('a key that can never pay (failed, compensated) moves on to the next numbered key, never paying twice', function()
        sellerInCar()
        Commands.transfervehicle(STRANGER, { tostring(BUYER), '5000' })
        local key = 'pfm-vehicleshop:transfer:' .. lastPrompt().id .. ':seller'
        intercept[key] = { ok = false, error = 'internal_error' }
        answer(BUYER, true)
        local o = owed()[1]
        assert_eq(o.attempt, 1)
        -- the first key is now known dead (its transfer was compensated)
        intercept[key] = { ok = false, state = 'compensated', error = 'state_conflict', duplicate = true }
        PFSettle.Sweep()
        assert_eq(money(STRANGER).bank, 205000)
        assert_eq(store.owed[o.id].attempt, 2)
        assert_eq(#LedgerEnv.paid(key .. ':r2'), 1, 'paid under the numbered key')
        PFSettle.Sweep()
        assert_eq(money(STRANGER).bank, 205000)
    end)

    it('a refund to a buyer that is still in flight is asked again, not replaced (no second refund)', function()
        sellerInCar()
        Commands.transfervehicle(STRANGER, { tostring(BUYER), '5000' })
        local id = lastPrompt().id
        -- the refund's transfer is written but not finished (pending)
        intercept['pfm-vehicleshop:transfer:' .. id .. ':refund'] = { ok = false, state = 'pending', error = 'pending', txId = 'TXP' }
        -- the car changes hands after the buyer paid: the claim fails, the refund is owed
        stealOnClaim = true
        answer(BUYER, true)
        stealOnClaim = false
        assert_eq(vehicles.MYCAR1.citizenid, 'CID9')
        assert_eq(money(BUYER).bank, 195000)
        PFSettle.Sweep()
        assert_eq(money(BUYER).bank, 195000, 'a refund in flight is not paid again under a new key')
        local o = owed()[1]
        assert_eq(o.attempt, 1)
        intercept = {}
        PFSettle.Sweep()
        assert_eq(money(BUYER).bank, 200000)
        assert_eq(money(STRANGER).bank, 200000, 'the seller was not paid')
        PFSettle.Sweep()
        assert_eq(money(BUYER).bank, 200000, 'refunded once')
    end)
end)

describe('finance payments stop on an unclear charge', function()
    local function financed()
        vehicles['FIN001'] = { citizenid = 'CID1', vehicle = 'blista', plate = 'FIN001', balance = 8000, paymentamount = 1000, paymentsleft = 8, financetime = 100 }
        return vehicles.FIN001
    end

    it('nothing is taken from the bank after an unclear cash charge; the payment applies once it clears', function()
        local car = financed()
        money(BUYER).cash = 5000
        failCredit = true
        local res = PFShop.FinancePayment(BUYER, 'FIN001', 1000)
        assert_eq(res.error, 'payment_held')
        assert_eq(money(BUYER).cash, 4000)
        assert_eq(money(BUYER).bank, 200000, 'the old code charged the bank as well')
        assert_eq(car.balance, 8000, 'not applied yet')
        -- another payment on the car waits for this one
        assert_eq(PFShop.FinancePayment(BUYER, 'FIN001', 1000).error, 'payment_waiting')
        assert_eq(PFShop.PayOff(BUYER, 'FIN001').error, 'payment_waiting')
        settle()
        assert_eq(car.balance, 7000)
        assert_eq(car.paymentsleft, 7)
        settle()
        assert_eq(car.balance, 7000, 'applied once')
        assert_eq(money(BUYER).cash, 4000)
        assert_eq(money(BUYER).bank, 200000)
    end)

    it('a payment interrupted during the debit is never retried under a new key', function()
        local car = financed()
        money(BUYER).cash = 5000
        local p = Mock.players[BUYER]
        local realRemove = p.RemoveMoney
        p.RemoveMoney = function(kind, amount, ...)
            FakeDB.failNext.setState = true
            return realRemove(kind, amount, ...)
        end
        p.Functions.RemoveMoney = p.RemoveMoney
        PFShop.FinancePayment(BUYER, 'FIN001', 1000)
        p.RemoveMoney, p.Functions.RemoveMoney = realRemove, realRemove
        settle()   -- the ledger marks it interrupted_unverified; the hold goes to review
        local res = PFShop.FinancePayment(BUYER, 'FIN001', 1000)
        assert_eq(res.error, 'payment_held', 'the same payment still cannot be told')
        assert_eq(money(BUYER).bank, 200000, 'no other account charged')
        for k in pairs(FakeDB.byKey) do
            assert_true(k:find(':2:', 1, true) == nil, 'no second attempt key was used: ' .. k)
        end
        assert_eq(car.balance, 8000)
    end)

    it('a payment that cleared on a loan that changed meanwhile goes back', function()
        local car = financed()
        money(BUYER).cash = 5000
        failCredit = true
        PFShop.FinancePayment(BUYER, 'FIN001', 1000)
        car.balance = 3000   -- changed some other way
        settle()
        assert_eq(car.balance, 3000)
        assert_eq(money(BUYER).cash, 5000, 'refunded to the account it came from')
    end)
end)

describe('repossession', function()
    it('takes only an overdue car of the owner and tells pf-jobgarages; not while a payment waits', function()
        vehicles.REPO01 = { citizenid = 'CID1', vehicle = 'blista', plate = 'REPO01', balance = 5000, financetime = 0 }
        vehicles.REPO02 = { citizenid = 'CID1', vehicle = 'blista', plate = 'REPO02', balance = 5000, financetime = 300 }
        assert_false(PFShop.Repossess('CID2', 'REPO01'), 'not the owner')
        assert_false(PFShop.Repossess('CID1', 'REPO02'), 'not overdue')
        assert_true(PFShop.Repossess('CID1', 'REPO01'))
        assert_eq(vehicles.REPO01, nil)
        local ev
        for _, e in ipairs(Mock.serverEvents) do if e.name == 'pfm-vehicleshop:server:vehicleRepossessed' then ev = e end end
        assert_true(ev ~= nil, 'pf-jobgarages is told')
        assert_eq(ev.args[1], 'REPO01')
        -- a payment on the car waiting on the bank keeps it
        vehicles.REPO03 = { citizenid = 'CID1', vehicle = 'blista', plate = 'REPO03', balance = 5000, paymentamount = 1000, paymentsleft = 5, financetime = 0 }
        money(BUYER).cash = 5000
        failCredit = true
        PFShop.FinancePayment(BUYER, 'REPO03', 1000)
        assert_false(PFShop.Repossess('CID1', 'REPO03'))
        assert_true(vehicles.REPO03 ~= nil)
    end)
end)


-- ── second round: a database error at the one step after a charge ──────────────────────────────

local function patternFor(text)
    for _, pat in ipairs(FakeDB.extraPatterns) do if pat[1] == text then return pat end end
end
--- Makes the statement `text` fail `times` times (once by default) while `when()` is true.
local function failQuery(text, when, times)
    local pat = patternFor(text)
    local orig = pat[2]
    local left = times or 1
    pat[2] = function(p)
        if left > 0 and (not when or when(p)) then
            left = left - 1
            error('injected: database connection lost')
        end
        return orig(p)
    end
    return function() pat[2] = orig end
end

describe('a dealer sale whose plate lookup fails', function()
    local function atLuxury() for _, src in ipairs({ BUYER, DEALER, STRANGER }) do Mock.coords[src] = vector3(LUX.x, LUX.y, LUX.z) end end

    it('stops before any stock is taken or money charged (the plate came after the charge)', function()
        atLuxury()
        Mock.fireNet('qb-vehicleshop:server:sellShowroomVehicle', DEALER, 'cognoscenti', BUYER)
        local restore = failQuery('SELECT plate FROM player_vehicles WHERE plate = ?')
        local res = PFShop.AnswerOffer(BUYER, true, lastPrompt().id)
        restore()
        assert_eq(res.error, 'server_error')
        assert_eq(money(BUYER).bank, 200000, 'nothing charged')
        assert_eq(store.stock['luxury:cognoscenti'] or Config.Stock.Initial, Config.Stock.Initial, 'no stock taken')
        assert_eq(count(vehicles), 0)
        assert_eq(#holds(), 0)
    end)

    it('an unclear charge keeps the plate it was given before the charge: held, then delivered once', function()
        atLuxury()
        Mock.fireNet('qb-vehicleshop:server:sellShowroomVehicle', DEALER, 'cognoscenti', BUYER)
        failCredit = true
        -- any plate lookup after the charge fails (the checker's probe): there must be none
        local restore = failQuery('SELECT plate FROM player_vehicles WHERE plate = ?', function() return not failCredit end, 5)
        answer(BUYER, true)
        restore()
        assert_eq(money(BUYER).bank, 100000, 'the money left the buyer')
        local h = holds()
        assert_eq(#h, 1, 'the sale is held')
        local plate = json.decode(h[1].data).plate
        assert_true(type(plate) == 'string' and #plate > 0, 'with its plate')
        assert_eq(store.stock['luxury:cognoscenti'], Config.Stock.Initial - 1, 'reserved')
        settle()
        assert_eq(count(vehicles), 1)
        assert_eq(vehicles[plate].citizenid, 'CID1')
        settle()
        assert_eq(count(vehicles), 1)
        assert_eq(money(BUYER).bank, 100000, 'charged once')
    end)
end)

describe('a held sale whose end could not be stored', function()
    local function financed()
        vehicles['FIN002'] = { citizenid = 'CID1', vehicle = 'blista', plate = 'FIN002', balance = 8000, paymentamount = 1000, paymentsleft = 8, financetime = 100 }
        return vehicles.FIN002
    end
    local MARK = 'UPDATE pfm_vehicleshop_held SET state = ?, outcome = ? WHERE id = ? AND state = ?'

    it('keeps blocking the car until it is marked done: a second payment waits, nothing is applied twice or refunded', function()
        local car = financed()
        money(BUYER).cash = 5000
        failCredit = true
        assert_eq(PFShop.FinancePayment(BUYER, 'FIN002', 1000).error, 'payment_held')
        local restore = failQuery(MARK, function(p) return p[1] == 'done' end)
        settle()
        restore()
        assert_eq(car.balance, 7000, 'applied')
        assert_eq(holds()[1].state, 'finishing', 'not marked done')
        assert_true(PFSettle.PlateHeld('FIN002'), 'still blocks the car')
        assert_eq(PFShop.FinancePayment(BUYER, 'FIN002', 1000).error, 'payment_waiting', 'the old code let this through, then refunded the first payment')
        settle()
        assert_eq(holds()[1].state, 'done')
        assert_false(PFSettle.PlateHeld('FIN002'))
        assert_true(PFShop.FinancePayment(BUYER, 'FIN002', 1000).ok)
        settle()
        assert_eq(car.balance, 6000)
        assert_eq(money(BUYER).cash, 3000, 'two payments, no money created')
        assert_eq(#owed(), 0, 'nothing refunded')
    end)

    it('a re-run after the block was lost (a restart that could not read the holds) does not refund the applied payment', function()
        local car = financed()
        money(BUYER).cash = 5000
        failCredit = true
        PFShop.FinancePayment(BUYER, 'FIN002', 1000)
        local restore = failQuery(MARK, function(p) return p[1] == 'done' end)
        settle()
        restore()
        -- a restart whose read of the open holds fails: nothing blocks the car any more
        local restoreRead = failQuery("FROM pfm_vehicleshop_held WHERE state IN ('waiting', 'finishing')")
        PFSettle.Start()
        restoreRead()
        assert_false(PFSettle.PlateHeld('FIN002'))
        assert_true(PFShop.FinancePayment(BUYER, 'FIN002', 1000).ok, 'the next instalment')
        assert_eq(car.balance, 6000)
        settle()   -- the first hold runs again: it was applied, so it is neither applied again nor refunded
        assert_eq(holds()[1].state, 'done')
        assert_eq(car.balance, 6000)
        assert_eq(money(BUYER).cash, 3000, 'no money created')
        assert_eq(#owed(), 0)
    end)
end)

describe('a paid transfer whose change of owner fails in the database', function()
    local CLAIM = 'UPDATE player_vehicles SET citizenid = ?, license = ? WHERE plate = ? AND citizenid = ? AND balance <= ?'
    local function sellerInCar()
        vehicles['MYCAR2'] = { citizenid = 'CID3', vehicle = 'blista', plate = 'MYCAR2', balance = 0 }
        Mock.vehicleOf[STRANGER] = 901
        Mock.plates[901] = 'MYCAR2'
    end

    it('is held (paid) and finished by the sweep: the car moves and the seller is paid once', function()
        sellerInCar()
        Commands.transfervehicle(STRANGER, { tostring(BUYER), '5000' })
        local restore = failQuery(CLAIM)
        local res = PFShop.AnswerOffer(BUYER, true, lastPrompt().id)
        restore()
        assert_eq(res.error, 'payment_held', 'the old code returned server_error and kept the money')
        assert_eq(money(BUYER).bank, 195000)
        assert_eq(vehicles.MYCAR2.citizenid, 'CID3')
        assert_true(told(BUYER, 'general.transfer_finishing'))
        assert_true(told(STRANGER, 'general.transfer_finishing_seller'))
        assert_true(PFSettle.PlateHeld('MYCAR2'), 'the car cannot be given away meanwhile')
        PFSettle.Sweep()
        assert_eq(vehicles.MYCAR2.citizenid, 'CID1')
        assert_eq(money(STRANGER).bank, 205000)
        PFSettle.Sweep()
        assert_eq(money(STRANGER).bank, 205000, 'paid once')
        assert_eq(money(BUYER).bank, 195000, 'charged once')
    end)

    it('the update ran but its answer was lost: the car is found moved and the seller paid, nothing refunded', function()
        sellerInCar()
        Commands.transfervehicle(STRANGER, { tostring(BUYER), '5000' })
        local pat = patternFor(CLAIM)
        local orig = pat[2]
        pat[2] = function(p) pat[2] = orig orig(p) error('injected: connection lost after the write') end
        PFShop.AnswerOffer(BUYER, true, lastPrompt().id)
        pat[2] = orig
        assert_eq(vehicles.MYCAR2.citizenid, 'CID1', 'it did move')
        PFSettle.Sweep()
        assert_eq(money(STRANGER).bank, 205000)
        assert_eq(money(BUYER).bank, 195000, 'not refunded')
    end)
end)
