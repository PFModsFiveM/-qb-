-- pf-jobs crews and Gruppe 6 upgrades:
--   * a crew's pool (the old flat bonus, 1.5x per member) is shared by the leader's splits, each
--     member paid their share once on the ledger with their own key, the plan fixed at the first
--     attempt so a retry after a bank failure pays the same shares; party changes reset the shares;
--   * upgrades are bought once from the bank and change the contracts: licences unlock tiers, the
--     capacity upgrade adds bags and pay, priority dispatch shortens the search;
--   * an armoured truck robbery (pf-services city event) warns crews and holds nearby pickups.
load_resource('tests/lua/ledger_env.lua')
QBCore = QBCoreMock
QBCoreMock.Shared.Items.moneybag = { name = 'moneybag', label = 'Money Bag', weight = 0 }
local delays = {}
Citizen.SetTimeout = function(ms) delays[#delays + 1] = ms return #delays end
Citizen.ClearTimeout = function() end
SetTimeout = function(_, fn) fn() end
local trucks = {}
function CreateVehicleServerSetter() Mock.nextNetId = Mock.nextNetId + 1; return Mock.nextNetId end
function CreateVehicle() Mock.nextNetId = Mock.nextNetId + 1; trucks[#trucks + 1] = Mock.nextNetId; return Mock.nextNetId end
function SetVehicleNumberPlateText() end
function SetVehicleDoorsLocked() end
function SetEntityHeading() end
Mock.exportsByResource['pfm-inventory'] = {
    GetInventory = function() return nil end, CreateInventory = function() end, SetInventory = function() end,
    OpenInventory = function() end, RemoveInventory = function() end,
}
local bankUp = true
function GetResourceState(name) if name == 'pfm-banking' then return bankUp and 'started' or 'stopped' end return 'started' end
local pushes = {}
Mock.exportsByResource['pf-devices'] = { Push = function(_, src, app, event, payload) pushes[#pushes + 1] = { src = src, app = app, event = event, payload = payload } end }

LedgerEnv.load('pf-jobs', {
    '[pfscripts]/pf-jobs/config.lua',
    '[pfscripts]/pf-jobs/server/apps/garbage.lua',
    '[pfscripts]/pf-jobs/server/apps/gruppe6.lua',
})
GetResourceState = function(name) if name == 'pfm-banking' then return bankUp and 'started' or 'stopped' end return 'started' end
local G6, GB = Config.Gruppe6, Config.Garbage
G6.UseDatabase, GB.UseDatabase = false, false
G6.ServerSideStash = true
G6.MoneyBagsPerLocationMin, G6.MoneyBagsPerLocationMax = 2, 2
G6.Debug = false

local LEAD, M2, M3 = 1, 2, 3
local carried = {}
local function newPlayer(src)
    local p = Mock.newPlayer(src)
    p.PlayerData.job = { name = 'unemployed', onduty = true }
    p.PlayerData.money = { cash = 0, bank = 0 }
    carried[src] = 0
    p.Functions.GetItemByName = function(name) if name == 'moneybag' and carried[src] > 0 then return { name = name, amount = carried[src] } end end
    p.Functions.RemoveItem = function(name, n) if name == 'moneybag' then carried[src] = carried[src] - n end return true end
    p.Functions.AddItem = function(name, n) if name == 'moneybag' then carried[src] = carried[src] + n end return true end
    return p
end
local function bank(src) return Mock.players[src].PlayerData.money.bank end
local function cash(src) return Mock.players[src].PlayerData.money.cash end
local function group6(src) return Mock.callCallback('pf-jobs:gruppe6:getGroup', src) end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.clock = Mock.clock + 100000
    for src = 1, 3 do Mock.fireNet('pf-jobs:gruppe6:disbandGroup', src) end
    Mock.players, Mock.coords, delays, pushes, trucks = {}, {}, {}, {}, {}
    bankUp = true
    for src = 1, 3 do newPlayer(src); Mock.fireEvent('playerDropped', src) end
    for src = 1, 3 do newPlayer(src) end
    -- bought upgrades are cached per character; these are new characters
    for src = 1, 3 do PFJobsG6.ForgetCitizen('CID' .. src) end
end

-- a Gruppe 6 party of three, joined by code
local function party()
    Mock.fireNet('pf-jobs:gruppe6:createGroup', LEAD)
    local code = group6(LEAD) and Mock.callCallback('pf-jobs:gruppe6:getAppView', LEAD).group.groupCode
    Mock.fireNet('pf-jobs:gruppe6:joinByCode', M2, code)
    Mock.fireNet('pf-jobs:gruppe6:joinByCode', M3, code)
    return code
end

-- the leader takes a contract, collects every bag and hands them all in at the vault
local function runContract(beforeDeposit)
    Mock.fireNet('pf-jobs:gruppe6:startSearch', LEAD)
    local offers = Mock.clientEventsNamed('pf-jobs:gruppe6:contracts')
    local offer = offers[#offers].args[1][1]
    Mock.fireNet('pf-jobs:gruppe6:acceptContract', LEAD, { contractId = 0 })
    local starts = Mock.clientEventsNamed('pf-jobs:gruppe6:startContract')
    local data = starts[#starts].args[1]
    for n, loc in ipairs(data.pickupSequence) do
        Mock.fireNet('pf-jobs:gruppe6:openPickupStash', LEAD, loc, n)
        for _ = 1, data.locationBags[n] do Mock.fireNet('pf-jobs:gruppe6:takePickupBag', LEAD, loc, n) end
    end
    if beforeDeposit then beforeDeposit(offer, data) end
    local d = G6.DepositLocation
    Mock.coords[LEAD] = vector3(d.x, d.y, d.z)
    Mock.fireNet('pf-jobs:gruppe6:depositComplete', LEAD)
    return offer, data
end

describe('Gruppe 6 crew shares', function()
    it('shares are whole percent of at least the floor, for exactly the party, adding up to 100', function()
        party()
        local g = group6(LEAD)
        assert_eq(g.payoutSplits[LEAD] + g.payoutSplits[M2] + g.payoutSplits[M3], 100, 'equal shares on joining')
        Mock.fireNet('pf-jobs:gruppe6:setSplits', LEAD, { [LEAD] = 85, [M2] = 10, [M3] = 5 })
        assert_true(group6(LEAD).payoutSplits[M3] ~= 5, 'below the floor')
        Mock.fireNet('pf-jobs:gruppe6:setSplits', LEAD, { [LEAD] = 50, [M2] = 30 })
        assert_true(group6(LEAD).payoutSplits[M2] ~= 30, 'a member left out')
        Mock.fireNet('pf-jobs:gruppe6:setSplits', LEAD, { [LEAD] = 50, [M2] = 25, [M3] = 20, [99] = 5 })
        assert_true(group6(LEAD).payoutSplits[M2] ~= 25, 'a stranger in the list')
        Mock.fireNet('pf-jobs:gruppe6:setSplits', LEAD, { [LEAD] = 50.5, [M2] = 25, [M3] = 24.5 })
        assert_true(group6(LEAD).payoutSplits[M2] ~= 25, 'fractions')
        Mock.fireNet('pf-jobs:gruppe6:setSplits', M2, { [LEAD] = 10, [M2] = 80, [M3] = 10 })
        assert_true(group6(LEAD).payoutSplits[M2] ~= 80, 'only the leader')
        Mock.fireNet('pf-jobs:gruppe6:setSplits', LEAD, { [tostring(LEAD)] = 50, [tostring(M2)] = 30, [tostring(M3)] = 20 })
        g = group6(LEAD)
        assert_eq(g.payoutSplits[LEAD], 50)
        assert_eq(g.payoutSplits[M2], 30)
        assert_eq(g.payoutSplits[M3], 20)
        -- the old single-member call keeps the floor too
        Mock.fireNet('pf-jobs:gruppe6:updateSplit', LEAD, M2, 95)
        assert_eq(group6(LEAD).payoutSplits[M2], 30)
        Mock.fireNet('pf-jobs:gruppe6:updateSplit', LEAD, M2, 40)
        g = group6(LEAD)
        assert_eq(g.payoutSplits[M2], 40)
        assert_eq(g.payoutSplits[LEAD] + g.payoutSplits[M3], 60)
        -- a member leaving resets everyone to equal shares
        Mock.fireNet('pf-jobs:gruppe6:leaveGroup', M3)
        g = group6(LEAD)
        assert_eq(g.payoutSplits[LEAD], 50)
        assert_eq(g.payoutSplits[M2], 50)
        assert_eq(g.payoutSplits[M3], nil)
    end)

    it('each member is paid their share of the pool once, with their own key', function()
        party()
        Mock.fireNet('pf-jobs:gruppe6:setSplits', LEAD, { [LEAD] = 50, [M2] = 30, [M3] = 20 })
        local projected
        local offer = runContract(function()
            -- every member's app shows the shares of the whole contract
            projected = Mock.callCallback('pf-jobs:gruppe6:getAppView', M3).payShares
        end)
        local pool = math.floor(offer.payout * 1.5) * 3
        assert_eq(#projected, 3)
        local sum = 0
        for _, x in ipairs(projected) do sum = sum + x.amount end
        assert_eq(sum, pool)
        assert_eq(projected[3].pct, 20)
        local rows = LedgerEnv.paid('pf-jobs:gruppe6:')
        assert_eq(#rows, 3, 'one payment per member')
        assert_eq(bank(M2), math.floor(pool * 30 / 100))
        assert_eq(bank(M3), math.floor(pool * 20 / 100))
        assert_eq(bank(LEAD), pool - bank(M2) - bank(M3), 'the leader gets the rounding')
        assert_eq(bank(LEAD) + bank(M2) + bank(M3), pool)
        -- handing in again pays nobody twice
        Mock.fireNet('pf-jobs:gruppe6:depositComplete', LEAD)
        assert_eq(#LedgerEnv.paid('pf-jobs:gruppe6:'), 3)
        assert_eq(bank(LEAD) + bank(M2) + bank(M3), pool)
    end)

    it('a payment the bank missed is retried with the shares fixed at the first attempt', function()
        party()
        Mock.fireNet('pf-jobs:gruppe6:setSplits', LEAD, { [LEAD] = 40, [M2] = 40, [M3] = 20 })
        bankUp = false
        local offer = runContract()
        assert_eq(#LedgerEnv.paid('pf-jobs:gruppe6:'), 0)
        -- the leader changes the shares before the retry: the fixed plan still applies
        Mock.fireNet('pf-jobs:gruppe6:setSplits', LEAD, { [LEAD] = 80, [M2] = 10, [M3] = 10 })
        bankUp = true
        Mock.fireNet('pf-jobs:gruppe6:depositComplete', LEAD)
        local pool = math.floor(offer.payout * 1.5) * 3
        assert_eq(bank(M2), math.floor(pool * 40 / 100))
        assert_eq(bank(M3), math.floor(pool * 20 / 100))
        assert_eq(#LedgerEnv.paid('pf-jobs:gruppe6:'), 3)
    end)
end)

describe('Garbage crew shares', function()
    local zone
    local function key(i) return ('%d:%.1f:%.1f:%.1f'):format(666561306, zone.x + i * 4, zone.y, zone.z) end
    local function at(src, k)
        local x, y, z = k:match(':([%d%.%-]+):([%d%.%-]+):([%d%.%-]+)$')
        Mock.coords[src] = vector3(tonumber(x), tonumber(y), tonumber(z))
    end

    it('the run pays each member their share of the crew pool once', function()
        Mock.fireNet('pf-jobs:garbage:createGroup', LEAD)
        Mock.fireNet('pf-jobs:garbage:invitePlayer', LEAD, M2)
        Mock.fireNet('pf-jobs:garbage:acceptInvite', M2, LEAD)
        Mock.fireNet('pf-jobs:garbage:setSplits', LEAD, { [LEAD] = 70, [M2] = 30 })
        assert_eq(Mock.callCallback('pf-jobs:garbage:getGroupState', LEAD).payoutSplits[M2], 30)
        Mock.fireNet('pf-jobs:garbage:startJob', LEAD)
        local zones = Mock.clientEventsNamed('pf-jobs:garbage:setActiveZone')
        zone = zones[#zones].args[1].center
        for i = 1, 3 do
            at(LEAD, key(i))
            Mock.fireNet('pf-jobs:garbage:requestBag', LEAD, key(i), false)
            Mock.coords[trucks[#trucks]] = vector3(500, 500, 30)
            Mock.coords[LEAD] = vector3(503, 500, 30)
            Mock.fireNet('pf-jobs:garbage:depositBag', LEAD)
        end
        local d = GB.ReturnLocation
        Mock.coords[LEAD] = vector3(d.x, d.y, d.z)
        Mock.fireNet('pf-jobs:garbage:returnTruck', LEAD)
        local pool = math.floor(3 * GB.PayoutPerBag[1] * 1.5) * 2
        assert_eq(#LedgerEnv.paid('pf-jobs:garbage:'), 2)
        assert_eq(cash(M2), math.floor(pool * 30 / 100))
        assert_eq(cash(LEAD), pool - cash(M2))
        Mock.fireNet('pf-jobs:garbage:returnTruck', LEAD)
        assert_eq(#LedgerEnv.paid('pf-jobs:garbage:'), 2)
    end)
end)

describe('Gruppe 6 upgrades', function()
    local function setLevel(src, level) Mock.players[src].PlayerData.metadata.gruppe6_level = level end
    local function lastOffer(src)
        local offers = Mock.clientEventsNamed('pf-jobs:gruppe6:contracts')
        return offers[#offers].args[1][1]
    end

    it('are bought once, from the bank, at the right level and in order', function()
        Mock.players[LEAD].PlayerData.money.bank = 100000
        assert_eq(PFJobsG6.BuyUpgrade(LEAD, 'tier_2'), false, 'level 1')
        setLevel(LEAD, 3)
        assert_eq(select(2, PFJobsG6.BuyUpgrade(LEAD, 'tier_3')), 'requires:tier_2')
        assert_eq(PFJobsG6.BuyUpgrade(LEAD, 'tier_2'), true)
        assert_eq(PFJobsG6.BuyUpgrade(LEAD, 'tier_2'), false, 'already owned')
        assert_eq(PFJobsG6.BuyUpgrade(LEAD, 'tier_3'), true)
        assert_eq(bank(LEAD), 100000 - G6.Upgrades.tier_2.cost - G6.Upgrades.tier_3.cost)
        assert_eq(#LedgerEnv.paid('pf-jobs:gruppe6:upgrade:'), 2)
        assert_eq(PFJobsG6.BuyUpgrade(LEAD, 'nope'), false)
        -- not enough money: nothing owned
        setLevel(M2, 2)
        assert_eq(PFJobsG6.BuyUpgrade(M2, 'bag_capacity'), false)
        assert_eq(Mock.players[M2].PlayerData.metadata.gruppe6_upgrades, nil)
    end)

    -- every ledger row (any state) whose key starts with prefix
    local function ledgerRows(prefix)
        local out = {}
        for k, row in pairs(FakeDB.byKey) do
            if tostring(k):sub(1, #prefix) == prefix then out[#out + 1] = row end
        end
        return out
    end
    local COST = function() return G6.Upgrades.tier_2.cost end
    local BASE = 'pf-jobs:gruppe6:upgrade:CID1:tier_2'

    it('a purchase refused for money writes nothing and can be made once the money is there', function()
        setLevel(LEAD, 2)
        Mock.players[LEAD].PlayerData.money.bank = COST() - 1
        local ok, why = PFJobsG6.BuyUpgrade(LEAD, 'tier_2')
        assert_eq(ok, false)
        assert_eq(why, 'insufficient_funds')
        assert_eq(#ledgerRows(BASE), 0, 'the balance is checked before the ledger is asked')
        Mock.players[LEAD].PlayerData.money.bank = 50000
        assert_eq(PFJobsG6.BuyUpgrade(LEAD, 'tier_2'), true)
        assert_eq(bank(LEAD), 50000 - COST())
        assert_eq(Mock.players[LEAD].PlayerData.metadata.gruppe6_upgrades.tier_2, true)
    end)

    it('a key whose charge failed is never reused: the next attempt charges once', function()
        setLevel(LEAD, 2)
        Mock.players[LEAD].PlayerData.money.bank = 50000
        -- the money left between the balance check and the debit: the ledger closes the key as failed
        local p = Mock.players[LEAD]
        local realRemove = p.Functions.RemoveMoney
        p.Functions.RemoveMoney = function() return false end
        assert_eq(select(2, PFJobsG6.BuyUpgrade(LEAD, 'tier_2')), 'insufficient_funds')
        assert_eq(FakeDB.byKey[BASE .. ':bank'].state, 'failed')
        p.Functions.RemoveMoney = realRemove
        assert_eq(PFJobsG6.BuyUpgrade(LEAD, 'tier_2'), true, 'the retry is not stuck on the failed key')
        assert_eq(FakeDB.byKey[BASE .. ':2:bank'].state, 'completed')
        assert_eq(bank(LEAD), 50000 - COST())
        assert_eq(#LedgerEnv.paid(BASE), 1)
        -- owned now: no further charge
        assert_eq(select(2, PFJobsG6.BuyUpgrade(LEAD, 'tier_2')), 'owned')
        assert_eq(#ledgerRows(BASE), 2)
        assert_eq(bank(LEAD), 50000 - COST())
    end)

    it('a charge that went through but was not recorded is applied without charging again', function()
        setLevel(LEAD, 2)
        -- an earlier attempt paid under the first key and then lost its record; what is left is
        -- less than the price, so a second charge (or a plain balance check) would refuse
        Mock.players[LEAD].PlayerData.money.bank = COST() + 100
        assert_true(PFPayout.Charge(Mock.players[LEAD], { 'bank' }, COST(), { key = BASE, quiet = true }) ~= false)
        assert_eq(bank(LEAD), 100)
        assert_eq(PFJobsG6.BuyUpgrade(LEAD, 'tier_2'), true)
        assert_eq(bank(LEAD), 100)
        assert_eq(#ledgerRows(BASE), 1)
        assert_eq(Mock.players[LEAD].PlayerData.metadata.gruppe6_upgrades.tier_2, true)
    end)

    it('a charge still in flight stops the purchase; a bank that is down charges nothing', function()
        setLevel(LEAD, 2)
        Mock.players[LEAD].PlayerData.money.bank = 50000
        local row = { tx_id = 'TXPENDING1', idempotency_key = BASE .. ':bank', state = 'pending', amount = COST(),
            from_account = 'player:CID1:bank', to_account = 'system:pf-jobs', kind = 'purchase' }
        FakeDB.byKey[row.idempotency_key], FakeDB.byTxId[row.tx_id] = row, row
        assert_eq(select(2, PFJobsG6.BuyUpgrade(LEAD, 'tier_2')), 'in_progress')
        assert_eq(bank(LEAD), 50000)
        assert_eq(Mock.players[LEAD].PlayerData.metadata.gruppe6_upgrades, nil)
        FakeDB.byKey[row.idempotency_key], FakeDB.byTxId[row.tx_id] = nil, nil
        bankUp = false
        assert_eq(select(2, PFJobsG6.BuyUpgrade(LEAD, 'tier_2')), 'bank_unavailable')
        assert_eq(bank(LEAD), 50000)
        assert_eq(#ledgerRows(BASE), 0)
        bankUp = true
        assert_eq(PFJobsG6.BuyUpgrade(LEAD, 'tier_2'), true)
        assert_eq(bank(LEAD), 50000 - COST())
    end)

    it('licences unlock tiers, capacity adds bags and pay, priority dispatch halves the wait', function()
        Mock.players[LEAD].PlayerData.money.bank = 100000
        setLevel(LEAD, 2)
        Mock.fireNet('pf-jobs:gruppe6:startSearch', LEAD)
        assert_eq(lastOffer(LEAD).tier, 1, 'level 2 without the licence stays on tier 1')
        local plainDelay = delays[#delays]
        assert_true(plainDelay >= G6.MinSpawnTime and plainDelay <= G6.MaxSpawnTime)
        PFJobsG6.BuyUpgrade(LEAD, 'tier_2')
        PFJobsG6.BuyUpgrade(LEAD, 'bag_capacity')
        PFJobsG6.BuyUpgrade(LEAD, 'priority_dispatch')
        Mock.fireNet('pf-jobs:gruppe6:startSearch', LEAD)
        local offer = lastOffer(LEAD)
        assert_eq(offer.tier, 2)
        local t = G6.Tiers[2]
        assert_true(offer.payout >= math.floor(t.payout[1] * 1.25) and offer.payout <= math.floor(t.payout[2] * 1.25), 'pay grows with the bags')
        assert_true(offer.bags >= math.floor(t.bags[1] * 1.25))
        assert_true(delays[#delays] <= G6.MaxSpawnTime / 2, 'offers come twice as fast')
        Mock.fireNet('pf-jobs:gruppe6:acceptContract', LEAD, { contractId = 0 })
        local starts = Mock.clientEventsNamed('pf-jobs:gruppe6:startContract')
        for _, n in ipairs(starts[#starts].args[1].locationBags) do assert_eq(n, math.floor(2 * 1.25)) end
    end)
end)

describe('armoured truck robbery', function()
    it('warns crews and holds the pickups near the attack', function()
        local _, data
        Mock.fireNet('pf-jobs:gruppe6:startSearch', LEAD)
        Mock.fireNet('pf-jobs:gruppe6:acceptContract', LEAD, { contractId = 0 })
        local starts = Mock.clientEventsNamed('pf-jobs:gruppe6:startContract')
        data = starts[#starts].args[1]
        Mock.fireNet('pf-jobs:gruppe6:startSearch', M2)
        local firstLoc = data.locationPool[data.pickupSequence[1]]
        Mock.reset()
        TriggerEvent('pf-services:cityEvent', { id = 9, kind = 'crime.robbery.truck', title = 'Armored truck attacked',
            coords = vector3(firstLoc.x + 50, firstLoc.y, firstLoc.z) })
        local warned = {}
        for _, e in ipairs(Mock.clientEventsNamed('QBCore:Notify')) do warned[e.target] = e.args[1] end
        assert_true(warned[LEAD] and warned[LEAD]:find('next pickup') ~= nil, 'the crew whose next pickup is near is told')
        assert_true(warned[M2] ~= nil, 'a searching crew is warned')
        assert_eq(warned[M3], nil, 'others are not')
        assert_eq(pushes[#pushes].app, 'gruppe6')
        assert_eq(#PFJobsG6.ActiveHolds(), 1)
        -- the held pickup gives no bags until the hold ends
        Mock.fireNet('pf-jobs:gruppe6:openPickupStash', LEAD, data.pickupSequence[1], 1)
        Mock.fireNet('pf-jobs:gruppe6:takePickupBag', LEAD, data.pickupSequence[1], 1)
        assert_eq(carried[LEAD], 0)
        Mock.clock = Mock.clock + G6.RobberyAlert.HoldMinutes * 60 + 1
        assert_eq(#PFJobsG6.ActiveHolds(), 0)
        Mock.fireNet('pf-jobs:gruppe6:openPickupStash', LEAD, data.pickupSequence[1], 1)
        Mock.fireNet('pf-jobs:gruppe6:takePickupBag', LEAD, data.pickupSequence[1], 1)
        assert_eq(carried[LEAD], 1)
        -- other kinds of city event are ignored
        TriggerEvent('pf-services:cityEvent', { kind = 'crime.robbery.store', coords = vector3(firstLoc.x, firstLoc.y, firstLoc.z) })
        assert_eq(#PFJobsG6.ActiveHolds(), 0)
    end)
end)
