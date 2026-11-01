-- pfm-fuel sales on the ledger. A charge whose outcome the bank did not know (result.unclear) used
-- to be forgotten: the player's retry charged again under a new key, so both could settle and the
-- player paid twice for one fill. Now the charge is kept and the player's next purchase of that
-- kind asks the bank again under the same key and amount, and hands over what it paid for once it
-- went through. A paid refill that cannot go into the car (it was removed during the payment, or a
-- settled earlier refill no longer fits) is refunded under the charge's key + ':refund'; a refund
-- the bank did not take is paid before the next purchase. A clear refusal other than "not enough
-- money" (which the payout module does not explain) now tells the player; one purchase per player
-- at a time.
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
MySQL.scalar = setmetatable({ await = function() return nil end }, { __call = function() end })

-- A small ledger: each key settles once. outcome: what the bank does with a new key ('completed',
-- 'pending' (unclear), 'failed' (no money), 'invalid_account', 'down'); a pending key later
-- settles as settle[key] says.
local ledger, charges, pays, outcome, settle, payDown, duringCharge = {}, {}, {}, 'completed', {}, false, nil
local ids = 0
PFPayout = {
    NewId = function() ids = ids + 1 return tostring(ids) end,
    Charge = function(player, account, amount, opts)
        charges[#charges + 1] = { key = opts.key, amount = amount }
        if duringCharge then local f = duringCharge duringCharge = nil f() end
        local entry = ledger[opts.key]
        if entry and entry.state == 'pending' and settle[opts.key] then entry.state = settle[opts.key] end
        if not entry then
            if outcome == 'down' then return false, { ok = false, error = 'bank_unavailable' } end
            if outcome == 'invalid_account' then return false, { ok = false, error = 'invalid_account' } end
            entry = { state = outcome, amount = amount }
            ledger[opts.key] = entry
        end
        assert_eq(entry.amount, amount, 'a key is only ever charged for its own amount')
        if entry.state == 'completed' then return account, { ok = true } end
        if entry.state == 'pending' then return false, { ok = false, state = 'pending', unclear = true } end
        return false, { ok = false, state = 'failed', error = 'insufficient_funds' }
    end,
    Pay = function(player, account, amount, opts)
        pays[#pays + 1] = { key = opts.key, account = account, amount = amount, quiet = opts.quiet }
        if payDown then return false, { ok = false, error = 'bank_unavailable' } end
        return true, { ok = true }
    end,
}

Config = nil
load_resource('pfm-fuel/Config.lua')
load_resource('pfm-fuel/server/main.lua')
load_resource('pfm-fuel/server/pricing.lua')
GetStationFuelPrice = function() return 5 end
GetFuelTaxRate = function() return 0.1 end
local taxed = {}
CollectFuelTax = function(subtotal, cid, tax, key) taxed[#taxed + 1] = { subtotal = subtotal, tax = tax, key = key } end

local P, Q = 1, 2
local CAR, CAR2 = 500, 501
local STATION = Config.GasStations[18]
local fuelExports = Mock.exportsByResource['__self']

local function fuel(veh) return Entity(veh).state['qb-fuel'] end
local function later() Mock.gameTimer = Mock.gameTimer + 5000 end
local function refill(src, litres, veh) later() return Mock.callCallback('qb-fuel:server:refillVehicle', src, litres, veh or CAR) end
local function notes(src)
    local out = {}
    for _, e in ipairs(Mock.clientEventsNamed('QBCore:Notify')) do if e.target == src then out[#out + 1] = e.args[1] end end
    return out
end
local function price(litres) return math.floor(litres * 5 * 1.1 + 0.5) end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.vehicleOf, Mock.coords, Mock.plates = {}, {}, {}, {}
    Mock.gameTimer = Mock.gameTimer + 100000
    states, charges, pays, taxed, settle = {}, {}, {}, {}, {}
    outcome, payDown, duringCharge = 'completed', false, nil
    entityType = { [CAR] = 2, [CAR2] = 2 }
    for _, veh in ipairs({ CAR, CAR2 }) do Mock.fireEvent('entityRemoved', nil, veh) Mock.coords[veh] = STATION end
    for _, src in ipairs({ P, Q }) do
        local p = Mock.newPlayer(src, 'PAY' .. src .. '-' .. Mock.gameTimer) -- a fresh citizen each test
        Mock.coords[src] = STATION + vector3(2.0, 0, 0)
        p.Notify = function(msg) TriggerClientEvent('QBCore:Notify', src, msg, 'error') end
    end
    Config.SyncFuelBetweenPlayers = true
    Config.MoneyType = 'cash'
end

describe('fix13b fuel payments: a charge the bank has not settled is never charged again under a new key', function()
    it('the retry asks again under the same key and amount, and pours the earlier litres once it went through', function()
        fuelExports.SetVehicleFuel(CAR, 20)
        outcome = 'pending'
        local paid, level, why = refill(P, 30)
        assert_eq(paid, false)
        assert_eq(level, 20.0)
        assert_eq(why, 'payment', 'the payout module already said it is being processed')
        assert_eq(fuel(CAR), 20.0, 'nothing poured')
        local first = charges[1]
        assert_eq(first.amount, price(30))

        -- still not settled: asked again under the same key, nothing new charged or poured
        outcome = 'completed'
        paid, level, why = refill(P, 50)
        assert_eq(paid, false)
        assert_eq(why, 'payment')
        assert_eq(charges[2].key, first.key)
        assert_eq(charges[2].amount, first.amount)
        assert_eq(fuel(CAR), 20.0)

        -- it went through: the 30 litres it paid for go in, whatever this attempt asked for
        settle[first.key] = 'completed'
        paid, level = refill(P, 50)
        assert_eq(paid, true)
        assert_eq(level, 50.0)
        assert_eq(charges[3].key, first.key)
        assert_eq(#taxed, 1)
        assert_eq(taxed[1].key, first.key, 'the tax once, under that key')
        assert_eq(taxed[1].subtotal, 150)

        -- settled: the next refill is a new charge
        paid, level = refill(P, 10)
        assert_eq(paid, true)
        assert_eq(level, 60.0)
        assert_true(charges[4].key ~= first.key)
        assert_eq(charges[4].amount, price(10))
    end)

    it('an earlier charge that clearly failed is forgotten: the next attempt is a new charge', function()
        fuelExports.SetVehicleFuel(CAR, 20)
        outcome = 'pending'
        refill(P, 30)
        local first = charges[1]
        settle[first.key] = 'failed'
        local paid, _, why = refill(P, 30)
        assert_eq(paid, false)
        assert_eq(why, nil, 'not enough money then: the client says so')
        outcome = 'completed'
        local paid2, level = refill(P, 30)
        assert_eq(paid2, true)
        assert_eq(level, 50.0)
        assert_true(charges[3].key ~= first.key)
    end)

    it('the unsettled charge is the player\'s: another player at the same pump pays their own', function()
        fuelExports.SetVehicleFuel(CAR, 20)
        outcome = 'pending'
        refill(P, 30)
        outcome = 'completed'
        local paid, level = refill(Q, 30)
        assert_eq(paid, true)
        assert_eq(level, 50.0)
        assert_true(charges[2].key ~= charges[1].key)
    end)

    it('a settled earlier refill that no longer fits is refunded in full under its own key; nothing poured, no tax', function()
        fuelExports.SetVehicleFuel(CAR, 20)
        outcome = 'pending'
        refill(P, 70)
        local first = charges[1]
        fuelExports.SetVehicleFuel(CAR, 60) -- someone filled it meanwhile
        settle[first.key] = 'completed'
        local paid, level, why = refill(P, 10)
        assert_eq(paid, false)
        assert_eq(level, 60.0)
        assert_eq(why, 'payment')
        assert_eq(fuel(CAR), 60.0)
        assert_eq(#pays, 1)
        assert_eq(pays[1].key, first.key .. ':refund')
        assert_eq(pays[1].amount, first.amount)
        assert_eq(pays[1].account, 'cash')
        assert_eq(#taxed, 0)
        assert_eq(notes(P)[1], 'error.refunded')
    end)
end)

describe('fix13b fuel payments: a refill that cannot go in is refunded', function()
    it('the car removed during the payment: refunded, nothing poured, no tax', function()
        fuelExports.SetVehicleFuel(CAR, 20)
        duringCharge = function() entityType[CAR] = nil end
        local paid, level, why = refill(P, 30)
        assert_eq(paid, false)
        assert_eq(level, false)
        assert_eq(why, 'payment')
        assert_eq(#pays, 1)
        assert_eq(pays[1].key, charges[1].key .. ':refund')
        assert_eq(pays[1].amount, price(30))
        assert_eq(#taxed, 0)
        assert_eq(notes(P)[1], 'error.refunded')
    end)

    it('a refund the bank did not take is paid (same key) before the next refill is charged', function()
        fuelExports.SetVehicleFuel(CAR, 20)
        duringCharge = function() entityType[CAR] = nil end
        payDown = true
        refill(P, 30)
        assert_eq(notes(P)[1], 'error.refund_pending')
        local refundKey = pays[1].key
        entityType[CAR2] = 2
        fuelExports.SetVehicleFuel(CAR2, 50)
        -- the bank still down: nothing new is charged
        local paid, _, why = refill(P, 10, CAR2)
        assert_eq(paid, false)
        assert_eq(why, 'payment')
        assert_eq(#charges, 1)
        assert_eq(pays[2].key, refundKey)
        -- the bank back: the refund first, then the new refill under a new key
        payDown = false
        local paid2, level = refill(P, 10, CAR2)
        assert_eq(paid2, true)
        assert_eq(level, 60.0)
        assert_eq(pays[3].key, refundKey)
        assert_eq(#pays, 3)
        assert_eq(#charges, 2)
        assert_true(charges[2].key ~= charges[1].key)
        refill(P, 10, CAR2)
        assert_eq(#pays, 3, 'the refund is paid once')
    end)
end)

describe('fix13b fuel payments: the player hears why a payment failed', function()
    it('a clear refusal the payout module does not explain (invalid account): told, reason payment', function()
        fuelExports.SetVehicleFuel(CAR, 20)
        outcome = 'invalid_account'
        local paid, level, why = refill(P, 30)
        assert_eq(paid, false)
        assert_eq(level, 20.0)
        assert_eq(why, 'payment')
        assert_eq(notes(P)[1], 'error.payment_declined')
    end)

    it('not enough money: no reason (the client says so); the bank down: reason payment, the payout module told them', function()
        fuelExports.SetVehicleFuel(CAR, 20)
        outcome = 'failed'
        local _, _, why = refill(P, 30)
        assert_eq(why, nil)
        outcome = 'down'
        local _, _, why2 = refill(P, 30)
        assert_eq(why2, 'payment')
        assert_eq(#notes(P), 0, 'nothing added by pfm-fuel')
    end)
end)

describe('fix13b fuel payments: one purchase per player at a time', function()
    it('a second pump by the same player during the payment is refused as busy, not charged', function()
        fuelExports.SetVehicleFuel(CAR, 20)
        fuelExports.SetVehicleFuel(CAR2, 20)
        local second
        duringCharge = function()
            Mock.gameTimer = Mock.gameTimer + 5000
            second = { Mock.callCallback('qb-fuel:server:refillVehicle', P, 30, CAR2) }
        end
        local paid = refill(P, 30)
        assert_eq(paid, true)
        assert_eq(second[1], false)
        assert_eq(second[3], 'busy')
        assert_eq(#charges, 1)
        assert_eq(fuel(CAR2), 20.0)
    end)
end)

describe('fix13b fuel payments: jerry cans', function()
    it('an unsettled can purchase is asked again under the same key; the can comes once it went through', function()
        local p = Mock.players[P]
        local added = {}
        p.AddItem = function(name, n, slot, info) added[#added + 1] = info return true end
        outcome = 'pending'
        Mock.fireNet('qb-fuel:server:buyJerryCan', P)
        assert_eq(#added, 0)
        Mock.fireNet('qb-fuel:server:buyJerryCan', P)
        assert_eq(charges[2].key, charges[1].key)
        assert_eq(#added, 0)
        settle[charges[1].key] = 'completed'
        Mock.fireNet('qb-fuel:server:buyJerryCan', P)
        assert_eq(#added, 1)
        assert_eq(charges[3].key, charges[1].key)
        assert_eq(#charges, 3)
    end)

    it('not enough money for a can: the player is told', function()
        outcome = 'failed'
        Mock.fireNet('qb-fuel:server:buyJerryCan', P)
        assert_eq(notes(P)[1], 'error.no_money')
    end)
end)

describe('fix13b fuel payments: a restart of pfm-fuel', function()
    it('cars already out keep answering for the plates they show', function()
        Mock.plates[700] = 'OWN55 '
        entityType[700] = 2
        Entity(700).state:set('qb-fuel', 55.0, true)
        Mock.plates[701] = 'NOLEVEL'
        entityType[701] = 2
        function GetAllVehicles() return { 700, 701 } end
        load_resource('pfm-fuel/server/main.lua')
        local ex = Mock.exportsByResource['__self']
        assert_eq(ex.GetVehicleFuel(700, 'OWN55'), 55.0)
        assert_eq(ex.GetVehicleFuel(701, 'NOLEVEL'), nil)
        GetAllVehicles = nil
    end)
end)
