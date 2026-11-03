-- Batch 14 (drugs-delivery-reyield, drugs-uncapped-cop-multiplier, ledger-unclear-handback):
--  * the dealer (the server) picks the product, the amount and the drop; a run is kept in
--    pfm_drug_deliveries, so a restart does not free it; a run never finished expires into a failed
--    one: the bricks still held are taken back, the rest is a dealer debt paid in cash before the
--    next run (it used to front fresh bricks every two hours, or right after a restart);
--  * a hand-over with nothing to hand over keeps the run (it used to close it and allow a new one);
--  * the on-time pay grows with the police on duty only up to Config.MaxPoliceMultiplier (it was
--    cops x 2: 10 officers paid 20x), dealer hours are checked on the server, and runs have a
--    cooldown and a daily limit;
--  * the bricks or drugs go back only when the payment clearly failed; an unclear payment keeps them
--    taken and is asked again under the same key.
load_resource('tests/lua/ledger_env.lua')

-- the run table on the fake database
local runRows = {}
local RUN_COLS = { 'citizenid', 'state', 'delivery_id', 'dealer', 'item_idx', 'amount', 'location', 'started_at', 'earliest',
    'handed', 'pay_amount', 'pay_attempt', 'outcome', 'debt', 'debt_id', 'debt_attempt', 'next_at', 'day', 'day_count' }
FakeDB.extraPatterns = {
    { 'SELECT * FROM pfm_drug_deliveries', function(p) return runRows[p[1]] and { runRows[p[1]] } or {} end },
    { 'INSERT INTO pfm_drug_deliveries', function(p)
        local row = {}
        for i, c in ipairs(RUN_COLS) do row[c] = p[i] end
        runRows[row.citizenid] = row
        return { affectedRows = 1 }
    end },
    { 'DELETE FROM pfm_drug_deliveries', function(p) runRows[p[1]] = nil return { affectedRows = 1 } end },
}
Mock.exportsByResource['pfm-core'].RunMigrations = function() return true end

-- inventories: [src][item] = count
local inv = {}
local function count(src, item) return (inv[src] or {})[item] or 0 end
Mock.exportsByResource['pfm-inventory'] = {
    GetItemCount = function(_, src, item) return count(src, item) end,
    AddItem = function(_, src, item, n, _, info)
        inv[src] = inv[src] or {}
        inv[src][item] = (inv[src][item] or 0) + (n or 1)
        if item == 'markedbills' then inv[src].worth = (inv[src].worth or 0) + (info and info.worth or 0) end
        return true
    end,
    RemoveItem = function(_, src, item, n)
        if count(src, item) < (n or 1) then return false end
        inv[src][item] = inv[src][item] - (n or 1)
        return true
    end,
}
local hour = 12
Mock.exportsByResource['pfm-weathersync'] = { getTime = function() return hour, 0 end }
local cops = 0
QBCoreMock.Functions.GetDutyCount = function() return cops end
QBCoreMock.Shared.Items.weed_brick = { name = 'weed_brick', label = 'Weed Brick' }
QBCoreMock.Shared.Items.coke_brick = { name = 'coke_brick', label = 'Coke Brick' }
QBCoreMock.Shared.Items.weed_skunk = { name = 'weed_skunk', label = 'Skunk' }

LedgerEnv.load('pfm-drugs', { 'pfm-drugs/config.lua', 'pfm-drugs/server/deliveries.lua', 'pfm-drugs/server/cornerselling.lua' })
assert(PFDrugs.Start(), 'deliveries ready')
local DEALER = 'Test Dealer'
Config.Dealers[DEALER] = { name = 'Shady', coords = { x = 0.0, y = 0.0, z = 0.0 }, time = { min = 6, max = 22 }, products = {} }

local P = 1
local bankExports = Mock.exportsByResource['pfm-banking']
local realTransfer = bankExports.Transfer

local function cash() return Mock.players[P].PlayerData.money.cash end
local function rep() return Mock.players[P].PlayerData.metadata.rep.dealer end
local function request() return PFDrugs.RequestDelivery(P, DEALER) end
local function itemOf(d) return Config.DeliveryItems[d.item].item end
local function atDealer() Mock.coords[P] = vector3(0.0, 0.0, 0.0) end
local function atDrop(d) Mock.coords[P] = vector3(d.coords.x, d.coords.y, d.coords.z) end
-- drives to the drop and hands over after the trip (on time)
local function deliver(d, extraSeconds)
    atDrop(d)
    Mock.clock = Mock.clock + 600 + (extraSeconds or 0)
    return PFDrugs.HandOver(P)
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    runRows, inv, cops, hour = {}, {}, 0, 12
    PFDrugs.__reset()
    bankExports.Transfer = realTransfer
    Mock.clock = Mock.clock + 10 * 86400
    Mock.players, Mock.coords = {}, {}
    local p = Mock.newPlayer(P)
    p.PlayerData.metadata.rep = { dealer = 50 }
    function p.GetRep(kind) return p.PlayerData.metadata.rep[kind] or 0 end
    function p.AddRep(kind, n) p.PlayerData.metadata.rep[kind] = (p.PlayerData.metadata.rep[kind] or 0) + n end
    function p.RemoveRep(kind, n) p.PlayerData.metadata.rep[kind] = (p.PlayerData.metadata.rep[kind] or 0) - n end
    atDealer()
end

describe('fix14 drugs deliveries: the server runs the delivery', function()
    it('the server picks product, amount and drop; a delivered run pays once', function()
        local res = request()
        assert_eq(res.ok, true)
        local d = res.delivery
        assert_true(d.amount >= 1 and d.amount <= Config.MaxDeliveryAmount)
        assert_true(Config.DeliveryLocations[1] ~= nil and d.coords ~= nil and d.locationLabel ~= nil)
        assert_eq(count(P, itemOf(d)), d.amount, 'fronted the bricks')
        local out = deliver(d)
        assert_eq(out.ok, true)
        assert_eq(out.outcome, 'perfect')
        assert_eq(count(P, itemOf(d)), 0)
        assert_eq(cash(), Config.DeliveryItems[d.item].payout * d.amount)
        assert_eq(rep(), 50 + Config.DeliveryRepGain)
        assert_eq(PFDrugs.HandOver(P).ok, false, 'a second hand-over pays nothing')
        assert_eq(cash(), Config.DeliveryItems[d.item].payout * d.amount)
    end)

    it('no client event fronts bricks for an item, amount and drop it names', function()
        assert_eq(Mock.netHandlers['qb-drugs:server:giveDeliveryItems'], nil, 'the client-chosen delivery event is gone')
    end)

    it('a run is not given again after two hours, nor after a restart: it fails into a debt', function()
        local d = request().delivery
        local item = itemOf(d)
        -- the bricks go into a stash; a restart forgets every cached run
        inv[P][item] = 0
        PFDrugs.__reset()
        local again = request()
        assert_eq(again.ok, false)
        assert_eq(again.error, 'pending_delivery', 'the run survived the restart')
        assert_eq(again.delivery.amount, d.amount, 'its drop is sent again')
        assert_eq(count(P, item), 0, 'no fresh bricks')
        -- past the deadline the run fails: the missing bricks are owed, the dealer fronts nothing
        Mock.clock = Mock.clock + Config.DeliveryExpireMinutes * 60 + 1
        local after = request()
        assert_eq(after.ok, false)
        assert_eq(count(P, item), 0, 'still no fresh bricks')
        assert_eq(runRows.CID1.debt, d.amount * Config.DeliveryItems[d.item].debt)
        assert_true(rep() < 50, 'the reputation dropped')
    end)

    it('an expired run takes back the bricks still held; only the missing ones are owed', function()
        local d = request().delivery
        local item = itemOf(d)
        inv[P][item] = d.amount - 1 -- one went missing
        Mock.clock = Mock.clock + Config.DeliveryExpireMinutes * 60 + 1
        request()
        assert_eq(count(P, item), 0, 'the bricks still held were taken back')
        assert_eq(runRows.CID1.debt, Config.DeliveryItems[d.item].debt, 'one brick owed')
    end)

    it('the debt is paid in cash before the next run, after the cooldown', function()
        local d = request().delivery
        inv[P][itemOf(d)] = 0
        Mock.clock = Mock.clock + Config.DeliveryExpireMinutes * 60 + 1
        request()
        local owed = runRows.CID1.debt
        Mock.clock = Mock.clock + Config.FailedDeliveryCooldown + 1
        local refused = request()
        assert_eq(refused.error, 'debt', 'no cash: no run')
        Mock.players[P].PlayerData.money.cash = owed + 100
        local ok = request()
        assert_eq(ok.ok, true, 'paid off: a new run')
        assert_eq(cash(), 100)
        assert_eq(runRows.CID1.debt, 0)
    end)

    it('a hand-over with nothing to hand over keeps the run open', function()
        local d = request().delivery
        inv[P][itemOf(d)] = 0
        local out = deliver(d)
        assert_eq(out.ok, false)
        atDealer()
        assert_eq(request().error, 'pending_delivery', 'it used to close the run and allow a new one')
    end)

    it('keeping some of the bricks costs their price', function()
        local d
        repeat
            PFDrugs.__reset(); runRows = {}; inv = {}
            Mock.clock = Mock.clock + 86400
            atDealer()
            d = request().delivery
        until d.amount >= 2
        inv[P][itemOf(d)] = 1 -- hands over one, keeps the rest
        local out = deliver(d)
        assert_eq(out.outcome, 'bad')
        assert_eq(runRows.CID1.debt, (d.amount - 1) * Config.DeliveryItems[d.item].debt)
    end)

    it('runs have a cooldown and a daily limit, and the dealer keeps hours', function()
        local d = request().delivery
        deliver(d)
        atDealer()
        assert_eq(request().error, 'cooldown')
        Config.MaxDeliveriesPerDay = 1
        Mock.clock = Mock.clock + Config.DeliveryCooldown + 1
        assert_eq(request().error, 'daily_limit')
        Config.MaxDeliveriesPerDay = 10
        hour = 3 -- outside 6-22
        assert_eq(request().error, 'closed')
        hour = 12
        assert_eq(request().ok, true)
    end)

    it('the police multiplier is capped', function()
        assert_eq(PFDrugs.CopMultiplier(0), 1.0)
        assert_eq(PFDrugs.CopMultiplier(2), 1.2)
        assert_eq(PFDrugs.CopMultiplier(10), Config.MaxPoliceMultiplier)
        assert_eq(PFDrugs.CopMultiplier(100), Config.MaxPoliceMultiplier)
        cops = 10
        local d = request().delivery
        deliver(d)
        local base = Config.DeliveryItems[d.item].payout * d.amount
        assert_eq(cash(), math.floor(base * Config.MaxPoliceMultiplier), 'it used to pay base x 20 with 10 officers')
    end)
end)

describe('fix14 drugs: goods are handed back only on a clear payment failure', function()
    it('a delivery whose pay is unclear keeps the bricks taken and pays later under the same key', function()
        local d = request().delivery
        local item = itemOf(d)
        local keys = {}
        bankExports.Transfer = function(_, opts)
            keys[#keys + 1] = opts.key
            return { ok = false, state = 'debited', txId = 'TX1', error = 'credit_failed' }
        end
        local out = deliver(d)
        assert_eq(out.outcome, 'pending')
        assert_eq(count(P, item), 0, 'the bricks are not handed back on an unclear result')
        assert_eq(cash(), 0)
        -- the ledger settles; the next visit pays under the first key
        bankExports.Transfer = realTransfer
        local again = PFDrugs.HandOver(P)
        assert_eq(again.ok, true)
        assert_eq(cash(), Config.DeliveryItems[d.item].payout * d.amount)
        assert_eq(#LedgerEnv.paid(keys[1]), 1, 'paid under the first key')
        assert_eq(count(P, item), 0)
    end)

    it('a delivery whose pay clearly failed gives the bricks back and keeps the run', function()
        local d = request().delivery
        local item = itemOf(d)
        PFLedger.ready = false -- the ledger is not running: nothing can move
        local out = deliver(d)
        PFLedger.ready = true
        assert_eq(out.ok, false)
        assert_eq(count(P, item), d.amount, 'handed back')
        assert_eq(PFDrugs.HandOver(P).outcome, 'perfect', 'the run is still open and pays now')
    end)

    it('a clearly failed pay that spent its key is paid next time under a new numbered key', function()
        local d = request().delivery
        local item = itemOf(d)
        local keys = {}
        bankExports.Transfer = function(_, opts)
            keys[#keys + 1] = opts.key
            return { ok = false, state = 'compensated', error = 'credit_failed' }
        end
        local out = deliver(d)
        assert_eq(out.ok, false)
        assert_eq(count(P, item), d.amount, 'a clear failure hands the bricks back')
        bankExports.Transfer = function(...)
            local args = { ... }
            local opts = args[#args]
            keys[#keys + 1] = opts.key
            return realTransfer(opts)
        end
        local again = PFDrugs.HandOver(P)
        assert_eq(again.ok, true)
        assert_true(keys[2] ~= keys[1], 'the spent key is not asked again')
        assert_eq(keys[2], keys[1] .. ':1')
        assert_eq(#LedgerEnv.paid(keys[2]), 1)
        assert_true(cash() > 0)
    end)

    it('a corner sale whose pay is unclear keeps the drugs sold; a clear failure hands them back', function()
        inv[P] = { weed_skunk = 5 }
        Mock.players[P].Functions.GetItemByName = function(name) if count(P, name) > 0 then return { name = name, amount = count(P, name) } end end
        Mock.players[P].GetItemByName = Mock.players[P].Functions.GetItemByName
        Config.ValidateCustomerPed = false
        local drugs = Mock.callCallback('qb-drugs:server:cornerselling:getAvailableDrugs', P)
        local idx
        for i, e in ipairs(drugs) do if e.item == 'weed_skunk' then idx = i end end
        bankExports.Transfer = function() return { ok = false, state = 'debited', txId = 'TX2', error = 'credit_failed' } end
        Mock.fireNet('qb-drugs:server:sellCornerDrugs', P, idx, 2, 1000, 0)
        assert_eq(count(P, 'weed_skunk'), 3, 'unclear: the drugs stay sold')
        Mock.gameTimer = Mock.gameTimer + 10000
        bankExports.Transfer = function() return { ok = false, error = 'ledger_unavailable' } end
        Mock.fireNet('qb-drugs:server:sellCornerDrugs', P, idx, 1, 1000, 0)
        assert_eq(count(P, 'weed_skunk'), 3, 'a clear failure: the second sale is handed back')
        bankExports.Transfer = realTransfer
    end)
end)
