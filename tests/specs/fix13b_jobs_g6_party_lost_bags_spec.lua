-- pf-jobs Gruppe 6 (server/apps/gruppe6.lua), three ways a contract used to get stuck:
--   * A party member who left the party mid-contract (left, kicked, or the party ended) kept holding
--     the leader's contract: the zero-bag end only cleared the members still in the party, and
--     leaving never cleared it, so they could not take another contract until they disconnected.
--     Leaving the party now takes them off the contract (the leader keeps it and the truck), and
--     ending a contract clears everyone who still holds it.
--   * An early end whose collected bags were lost (the truck robbed, a carrier dead or gone) could
--     never close: the vault waited for every collected bag and asking again answered 'Already
--     ending' for good. Bags the crew can no longer hand in (not carried by a holder, not in the
--     truck's trunk) are now written off, so the contract closes with what was handed in.
--   * In shared-stash mode the bags taken from a pickup are counted 250 ms after the move. Ending
--     in that window took the zero-bag path: no pay, and bags in the pocket. The end now waits for
--     that count first. The move arrives from pfm-inventory's client as a net event, which pf-jobs
--     must register to receive at all (fired here with Mock.fireNet); a burst of them makes one count.
--   * Round 2: a close at the vault with nothing left to hand in sends the client on to the truck
--     return; an end asked during a deposit, during another end's wait, or by a member who leaves
--     during the wait changes nothing; a trunk under the padded plate text counts.
load_resource('tests/lua/ledger_env.lua')
QBCore = QBCoreMock
QBCoreMock.Shared.Items.moneybag = { name = 'moneybag', label = 'Money Bag', weight = 0 }
Citizen = Citizen or {}
Citizen.SetTimeout = function() return 1 end
Citizen.ClearTimeout = function() end
-- SetTimeout callbacks wait for the next Wait (a server tick), as on a server
local timers = {}
SetTimeout = function(_, fn) timers[#timers + 1] = fn end
local function tick()
    local due = timers
    timers = {}
    for _, fn in ipairs(due) do fn() end
end
local ticking = true
function Wait() if ticking then tick() end end
function CreateVehicleServerSetter() Mock.nextNetId = Mock.nextNetId + 1; return Mock.nextNetId end
function SetVehicleNumberPlateText(veh, plate) Mock.plates[veh] = plate end
function SetVehicleDoorsLocked() end

-- pfm-inventory: stashes and trunks by id
local invs = {}
Mock.exportsByResource['pfm-inventory'] = {
    GetInventory = function(_, id) return invs[id] end,
    CreateInventory = function(_, id) invs[id] = invs[id] or { items = {} } end,
    SetInventory = function(_, id, items) invs[id] = invs[id] or {}; invs[id].items = items end,
    OpenInventory = function() end,
    RemoveInventory = function(_, id) invs[id] = nil end,
}

LedgerEnv.load('pf-jobs', { '[pfscripts]/pf-jobs/config.lua', '[pfscripts]/pf-jobs/server/apps/gruppe6.lua' })
local G6 = Config.Gruppe6
G6.UseDatabase = false
G6.ServerSideStash = true
G6.MoneyBagsPerLocationMin, G6.MoneyBagsPerLocationMax = 2, 2
G6.Debug = false
G6.Tiers[1].payout = { 400, 400 }

local LEAD, M2, M3 = 1, 2, 3
local carried = {}
local function newGuard(src)
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
local function paid() return LedgerEnv.paid('pf-jobs:gruppe6:') end
local function view(src) return Mock.callCallback('pf-jobs:gruppe6:getAppView', src) end
local function eventsFor(name, src)
    local n = 0
    for _, e in ipairs(Mock.clientEventsNamed(name)) do if e.target == src then n = n + 1 end end
    return n
end
local function lastNote(src)
    local notes = Mock.clientEventsNamed('QBCore:Notify')
    for i = #notes, 1, -1 do if notes[i].target == src then return notes[i].args[1] end end
end

local function accept(src)
    Mock.fireNet('pf-jobs:gruppe6:startSearch', src)
    Mock.fireNet('pf-jobs:gruppe6:acceptContract', src, { contractId = 0 })
    local starts = Mock.clientEventsNamed('pf-jobs:gruppe6:startContract')
    return starts[#starts].args[1]
end
-- takes a contract and collects the bags of the first `stops` pickups (server-side stash mode)
local function collect(src, stops)
    local data = accept(src)
    local taken = 0
    for n, loc in ipairs(data.pickupSequence) do
        if stops and n > stops then break end
        Mock.coords[src] = data.locationPool[loc] -- pickups are served only at the stop
        Mock.fireNet('pf-jobs:gruppe6:openPickupStash', src, loc, n)
        for _ = 1, data.locationBags[n] do Mock.fireNet('pf-jobs:gruppe6:takePickupBag', src, loc, n) end
        taken = taken + data.locationBags[n]
    end
    local total = 0
    for _, c in ipairs(data.locationBags) do total = total + c end
    return data, taken, total
end
local function atVault(src)
    local d = G6.DepositLocation
    Mock.coords[src] = vector3(d.x, d.y, d.z)
end
local function party(...)
    Mock.fireNet('pf-jobs:gruppe6:createGroup', LEAD)
    local code = view(LEAD).group.groupCode
    for _, m in ipairs({ ... }) do Mock.fireNet('pf-jobs:gruppe6:joinByCode', m, code) end
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.clock = Mock.clock + 100000
    G6.ServerSideStash = true
    timers, invs, ticking = {}, {}, true
    for src = 1, 3 do Mock.fireNet('pf-jobs:gruppe6:disbandGroup', src) end
    Mock.players, Mock.coords = {}, {}
    for src = 1, 3 do newGuard(src); Mock.fireEvent('playerDropped', src) end
    for src = 1, 3 do newGuard(src); PFJobsG6.ForgetCitizen('CID' .. src) end
    Mock.reset()
end

describe('Gruppe 6: a member who leaves the party mid-contract', function()
    it('is taken off the contract when leaving, and can take a contract of their own', function()
        party(M2)
        accept(LEAD)
        assert_true(view(M2).contract ~= nil, 'the member shares the contract')
        Mock.fireNet('pf-jobs:gruppe6:leaveGroup', M2)
        assert_eq(view(M2).contract, nil, 'not blocked until they disconnect')
        assert_eq(eventsFor('pf-jobs:gruppe6:leftContract', M2), 1, 'their client drops the job (not the truck)')
        assert_true(view(LEAD).contract ~= nil, 'the leader keeps it')
        Mock.clock = Mock.clock + 10
        local own = accept(M2)
        assert_eq(own.spawnOwner, M2)
        assert_true(view(M2).contract ~= nil, 'a contract of their own')
    end)

    it('is taken off the contract when kicked, or when the leader disbands the party', function()
        party(M2, M3)
        accept(LEAD)
        Mock.fireNet('pf-jobs:gruppe6:kickMember', LEAD, M2)
        assert_eq(view(M2).contract, nil, 'kicked')
        assert_true(view(M3).contract ~= nil)
        Mock.fireNet('pf-jobs:gruppe6:disbandGroup', LEAD)
        assert_eq(view(M3).contract, nil, 'the party ended')
        assert_true(view(LEAD).contract ~= nil, 'the leader still has the contract and the truck')
    end)

    it('the zero-bag end then closes the contract for the crew left, and nobody keeps it', function()
        party(M2, M3)
        accept(LEAD)
        Mock.fireNet('pf-jobs:gruppe6:leaveGroup', M2)
        Mock.fireNet('pf-jobs:gruppe6:endContract', LEAD)
        for _, src in ipairs({ LEAD, M2, M3 }) do assert_eq(view(src).contract, nil, 'cleared: ' .. src) end
        assert_eq(eventsFor('pf-jobs:gruppe6:returnWithoutBags', LEAD), 1)
        assert_eq(eventsFor('pf-jobs:gruppe6:returnWithoutBags', M3), 1)
        assert_eq(eventsFor('pf-jobs:gruppe6:returnWithoutBags', M2), 0, 'the one who left has no truck to bring back')
        assert_eq(#paid(), 0)
    end)

    it("a member's own contract is kept when they leave a party", function()
        party(M2)
        local own = accept(M2) -- a member taking a contract alone holds their own
        assert_eq(own.spawnOwner, M2)
        Mock.fireNet('pf-jobs:gruppe6:leaveGroup', M2)
        assert_true(view(M2).contract ~= nil)
        assert_eq(eventsFor('pf-jobs:gruppe6:leftContract', M2), 0)
    end)
end)

describe('Gruppe 6: an early end whose bags were lost', function()
    it("closes with no pay when every collected bag is gone (it answered 'Already ending' for good)", function()
        local _, taken = collect(LEAD, 1)
        assert_true(taken > 0)
        Mock.fireNet('pf-jobs:gruppe6:endContract', LEAD)
        assert_eq(eventsFor('pf-jobs:gruppe6:goToDeposit', LEAD), 1, 'off to the vault with the bags')
        carried[LEAD] = 0 -- the guard died and lost the bags
        Mock.fireNet('pf-jobs:gruppe6:endContract', LEAD)
        assert_false(tostring(lastNote(LEAD)):find('Already ending', 1, true) ~= nil, 'not stuck')
        assert_eq(view(LEAD).contract, nil, 'the contract closed')
        assert_eq(eventsFor('pf-jobs:gruppe6:returnWithoutBags', LEAD), 1, 'back to HQ with the truck')
        assert_eq(#paid(), 0, 'nothing handed in, nothing paid')
        Mock.fireNet('pf-jobs:gruppe6:vehicleReturned', LEAD)
        Mock.clock = Mock.clock + 10
        assert_true(accept(LEAD) ~= nil and view(LEAD).contract ~= nil, 'a new contract can be taken')
    end)

    it('ending with the bags already gone closes at once', function()
        collect(LEAD, 1)
        carried[LEAD] = 0
        Mock.fireNet('pf-jobs:gruppe6:endContract', LEAD)
        assert_eq(view(LEAD).contract, nil)
        assert_eq(eventsFor('pf-jobs:gruppe6:goToDeposit', LEAD), 0)
        assert_eq(#paid(), 0)
    end)

    it('pays the share of the bags handed in before the rest was lost, once, at the vault', function()
        local data, taken, total = collect(LEAD, 2)
        assert_true(taken > 2)
        Mock.fireNet('pf-jobs:gruppe6:endContract', LEAD)
        carried[LEAD] = 2 -- robbed on the way: two bags left
        atVault(LEAD)
        Mock.fireNet('pf-jobs:gruppe6:depositComplete', LEAD)
        assert_eq(#paid(), 0, 'more bags still owed: no pay yet')
        assert_eq(view(LEAD).contract.depositedBags, 2)
        Mock.fireNet('pf-jobs:gruppe6:endContract', LEAD)
        assert_true(tostring(lastNote(LEAD)):find('written off', 1, true) ~= nil, 'told the lost bags are written off')
        assert_true(view(LEAD).contract ~= nil, 'closed at the vault, where the pay is')
        Mock.fireNet('pf-jobs:gruppe6:depositComplete', LEAD)
        local rows = paid()
        assert_eq(#rows, 1)
        assert_eq(rows[1].amount, math.floor(data.payout * 2 / total), 'only the bags handed in count')
        assert_true(taken > 2)
        assert_eq(view(LEAD).contract, nil)
        Mock.fireNet('pf-jobs:gruppe6:depositComplete', LEAD)
        assert_eq(#paid(), 1, 'paid once')
    end)

    it("still carrying every bag, asking again tells what is left: nothing is written off", function()
        local _, taken = collect(LEAD, 1)
        Mock.fireNet('pf-jobs:gruppe6:endContract', LEAD)
        Mock.fireNet('pf-jobs:gruppe6:endContract', LEAD)
        assert_eq(lastNote(LEAD), ('Already ending this contract: hand in the %d remaining bag(s) at the vault.'):format(taken))
        assert_eq(view(LEAD).contract.bagsTaken, taken)
    end)

    it('bags carried in several slots all count', function()
        local _, taken = collect(LEAD, 2)
        assert_true(taken >= 4)
        -- the inventory keeps them in two slots: GetItemByName sees only the first
        local p = Mock.players[LEAD]
        p.Functions.GetItemByName = function(name) if name == 'moneybag' then return { name = name, amount = 2 } end end
        p.Functions.GetItemsByName = function(name)
            if name == 'moneybag' then return { { name = name, amount = 2 }, { name = name, amount = taken - 2 } } end
            return {}
        end
        Mock.fireNet('pf-jobs:gruppe6:endContract', LEAD)
        assert_eq(view(LEAD).contract.bagsTaken, taken, 'none written off')
        assert_eq(eventsFor('pf-jobs:gruppe6:goToDeposit', LEAD), 1)
    end)

    it("bags stored in the truck's trunk still count", function()
        accept(LEAD)
        Mock.fireNet('pf-jobs:gruppe6:spawnVehicle', LEAD)
        local data = Mock.clientEventsNamed('pf-jobs:gruppe6:startContract')[1].args[1]
        local loc = data.pickupSequence[1]
        Mock.coords[LEAD] = data.locationPool[loc] -- pickups are served only at the stop
        Mock.fireNet('pf-jobs:gruppe6:openPickupStash', LEAD, loc, 1)
        for _ = 1, data.locationBags[1] do Mock.fireNet('pf-jobs:gruppe6:takePickupBag', LEAD, loc, 1) end
        local n = carried[LEAD]
        assert_true(n > 0)
        -- the guard put them in the truck
        carried[LEAD] = 0
        invs['trunk-' .. data.plate] = { items = { { name = 'moneybag', amount = n } } }
        Mock.fireNet('pf-jobs:gruppe6:endContract', LEAD)
        assert_eq(eventsFor('pf-jobs:gruppe6:goToDeposit', LEAD), 1, 'to the vault with the bags in the truck')
        assert_eq(view(LEAD).contract.bagsTaken, n, 'none written off')
    end)

    it("bags in the trunk count under the id the client opened it with (the plate padded to 8)", function()
        accept(LEAD)
        Mock.fireNet('pf-jobs:gruppe6:spawnVehicle', LEAD)
        local data = Mock.clientEventsNamed('pf-jobs:gruppe6:startContract')[1].args[1]
        assert_eq(#data.plate, 6, 'a G6 plate is shorter than the 8 characters the game shows')
        local loc = data.pickupSequence[1]
        Mock.coords[LEAD] = data.locationPool[loc] -- pickups are served only at the stop
        Mock.fireNet('pf-jobs:gruppe6:openPickupStash', LEAD, loc, 1)
        for _ = 1, data.locationBags[1] do Mock.fireNet('pf-jobs:gruppe6:takePickupBag', LEAD, loc, 1) end
        local n = carried[LEAD]
        carried[LEAD] = 0
        -- pfm-inventory keeps the trunk under the client's untrimmed plate text
        invs['trunk- ' .. data.plate .. ' '] = { items = { { name = 'moneybag', amount = n } } }
        Mock.fireNet('pf-jobs:gruppe6:endContract', LEAD)
        assert_eq(view(LEAD).contract.bagsTaken, n, 'none written off')
        assert_eq(eventsFor('pf-jobs:gruppe6:goToDeposit', LEAD), 1)
    end)

    it('a close at the vault with nothing left to hand in sends the client on to return the truck', function()
        local _, taken = collect(LEAD, 2)
        Mock.fireNet('pf-jobs:gruppe6:endContract', LEAD)
        carried[LEAD] = 2
        atVault(LEAD)
        Mock.fireNet('pf-jobs:gruppe6:depositComplete', LEAD)
        local prog = Mock.clientEventsNamed('pf-jobs:gruppe6:depositProgress')
        assert_eq(prog[#prog].args[1], 2)
        assert_eq(prog[#prog].args[2], taken, 'more bags owed: keep depositing')
        Mock.fireNet('pf-jobs:gruppe6:endContract', LEAD) -- the rest is lost: written off, close it at the vault
        local before = eventsFor('pf-jobs:gruppe6:depositProgress', LEAD)
        Mock.fireNet('pf-jobs:gruppe6:depositComplete', LEAD)
        assert_eq(#paid(), 1, 'paid for the 2 bags')
        assert_eq(eventsFor('pf-jobs:gruppe6:depositProgress', LEAD), before + 1, 'the client is told all bags are in')
        prog = Mock.clientEventsNamed('pf-jobs:gruppe6:depositProgress')
        assert_eq(prog[#prog].args[1], 2)
        assert_eq(prog[#prog].args[2], 2, 'deposited = total: on to the vault door and the truck return')
    end)

    it('an end asked while a deposit takes the bags is refused, and the bags are not written off', function()
        local data, taken, total = collect(LEAD, 1)
        Mock.fireNet('pf-jobs:gruppe6:endContract', LEAD)
        atVault(LEAD)
        local p = Mock.players[LEAD]
        local remove = p.Functions.RemoveItem
        local note
        p.Functions.RemoveItem = function(name, n)
            local ok = remove(name, n)
            -- the bags have left the pocket but are not counted as handed in yet
            Mock.fireNet('pf-jobs:gruppe6:endContract', LEAD)
            note = lastNote(LEAD)
            return ok
        end
        Mock.fireNet('pf-jobs:gruppe6:depositComplete', LEAD)
        p.Functions.RemoveItem = remove
        assert_true(tostring(note):find('being handed in', 1, true) ~= nil, 'told to wait')
        assert_eq(eventsFor('pf-jobs:gruppe6:returnWithoutBags', LEAD), 0, 'not closed as lost')
        local rows = paid()
        assert_eq(#rows, 1)
        assert_eq(rows[1].amount, math.floor(data.payout * taken / total), 'every bag handed in is paid')
    end)

    it("in a party, a member's bags count while they hold the contract, and are written off once they leave", function()
        party(M2)
        accept(LEAD)
        local data = Mock.clientEventsNamed('pf-jobs:gruppe6:startContract')[1].args[1]
        local loc = data.pickupSequence[1]
        Mock.coords[M2] = data.locationPool[loc] -- pickups are served only at the stop
        Mock.fireNet('pf-jobs:gruppe6:openPickupStash', M2, loc, 1)
        for _ = 1, data.locationBags[1] do Mock.fireNet('pf-jobs:gruppe6:takePickupBag', M2, loc, 1) end
        assert_true(carried[M2] > 0 and carried[LEAD] == 0, 'the member carries them')
        Mock.fireNet('pf-jobs:gruppe6:endContract', LEAD)
        assert_eq(eventsFor('pf-jobs:gruppe6:goToDeposit', LEAD), 1, "the member's bags count")
        Mock.fireNet('pf-jobs:gruppe6:leaveGroup', M2)
        Mock.fireNet('pf-jobs:gruppe6:endContract', LEAD)
        assert_eq(view(LEAD).contract, nil, 'the bags left with the member: the contract closes')
        assert_eq(#paid(), 0)
    end)
end)

describe('Gruppe 6 shared-stash mode: ending while bags are being counted', function()
    local function takeFromStash(src, data, n)
        local loc = data.pickupSequence[1]
        Mock.coords[src] = data.locationPool[loc] -- pickups are served only at the stop
        Mock.fireNet('pf-jobs:gruppe6:openPickupStash', src, loc, 1)
        local id = ('pf_gruppe6_pickup_%s_%s'):format(loc, 1)
        local stash = invs[id]
        assert_true(stash ~= nil and stash.items[1].amount >= n, 'the pickup stash holds the bags')
        stash.items[1].amount = stash.items[1].amount - n
        carried[src] = carried[src] + n
        -- pfm-inventory's client sends its move as a net event; the bags are counted 250 ms later
        Mock.fireNet('qb-inventory:server:SetInventoryData', src, id, 'player')
    end

    it('waits for the count instead of ending with no pay', function()
        G6.ServerSideStash = false
        local data = accept(LEAD)
        takeFromStash(LEAD, data, 1)
        assert_eq(#timers, 1, 'the count is still to come')
        assert_eq(view(LEAD).contract.bagsTaken or 0, 0)
        Mock.fireNet('pf-jobs:gruppe6:endContract', LEAD)
        assert_eq(eventsFor('pf-jobs:gruppe6:returnWithoutBags', LEAD), 0, 'not the zero-bag end')
        assert_eq(eventsFor('pf-jobs:gruppe6:goToDeposit', LEAD), 1, 'off to the vault with the bag')
        assert_eq(view(LEAD).contract.bagsTaken, 1, 'counted')
        atVault(LEAD)
        Mock.fireNet('pf-jobs:gruppe6:depositComplete', LEAD)
        assert_eq(#paid(), 1, 'the bag is paid for')
    end)

    it('a burst of move events makes one count and one more pass, then the mark clears', function()
        G6.ServerSideStash = false
        local data = accept(LEAD)
        takeFromStash(LEAD, data, 1)
        local id = ('pf_gruppe6_pickup_%s_%s'):format(data.pickupSequence[1], 1)
        for _ = 1, 50 do Mock.fireNet('qb-inventory:server:SetInventoryData', LEAD, id, 'player') end
        assert_eq(#timers, 1, 'one count queued, however often the event is sent')
        tick()
        assert_eq(#timers, 1, 'one more pass for the moves reported meanwhile')
        tick()
        assert_eq(#timers, 0)
        assert_eq(view(LEAD).contract.bagsTaken, 1, 'the bag is counted once')
        ticking = false -- nothing left to count: the end does not wait
        Mock.fireNet('pf-jobs:gruppe6:endContract', LEAD)
        assert_eq(eventsFor('pf-jobs:gruppe6:goToDeposit', LEAD), 1)
    end)

    it('a second end while the first waits for the count is refused at once', function()
        G6.ServerSideStash = false
        local data = accept(LEAD)
        takeFromStash(LEAD, data, 1)
        local second
        local wait = Wait
        Wait = function()
            if not second then
                Mock.fireNet('pf-jobs:gruppe6:endContract', LEAD)
                second = lastNote(LEAD)
            end
            wait()
        end
        Mock.fireNet('pf-jobs:gruppe6:endContract', LEAD)
        Wait = wait
        assert_eq(second, 'Already ending this contract. One moment.')
        assert_eq(eventsFor('pf-jobs:gruppe6:goToDeposit', LEAD), 1, 'one end')
    end)

    it('a member who leaves the party during the wait leaves the contract as it was', function()
        G6.ServerSideStash = false
        party(M2)
        local data = accept(LEAD)
        takeFromStash(LEAD, data, 1)
        tick() -- the leader's bag is counted
        assert_eq(view(LEAD).contract.bagsTaken, 1)
        takeFromStash(M2, data, 1)
        local left = false
        local wait = Wait
        Wait = function()
            if not left then left = true; Mock.fireNet('pf-jobs:gruppe6:leaveGroup', M2) end
            wait()
        end
        Mock.fireNet('pf-jobs:gruppe6:endContract', M2)
        Wait = wait
        assert_eq(view(M2).contract, nil, 'off the contract')
        assert_eq(eventsFor('pf-jobs:gruppe6:goToDeposit', M2), 0)
        assert_eq(view(LEAD).contract.earlyEnd, false, 'not marked as ending: nobody was sent to the vault')
        Mock.fireNet('pf-jobs:gruppe6:endContract', LEAD)
        assert_false(tostring(lastNote(LEAD)):find('Already ending', 1, true) ~= nil, "the leader's end is not refused")
        assert_eq(eventsFor('pf-jobs:gruppe6:goToDeposit', LEAD), 1, 'the leader goes to the vault with the bag')
    end)

    it('a count that does not come in time leaves the contract running (asked to try again)', function()
        G6.ServerSideStash = false
        local data = accept(LEAD)
        takeFromStash(LEAD, data, 1)
        ticking = false -- the server is stuck on the move: the count does not arrive
        Mock.fireNet('pf-jobs:gruppe6:endContract', LEAD)
        assert_eq(eventsFor('pf-jobs:gruppe6:returnWithoutBags', LEAD), 0)
        assert_true(tostring(lastNote(LEAD)):find('still being counted', 1, true) ~= nil)
        local c = view(LEAD).contract
        assert_true(c ~= nil and c.earlyEnd == false, 'nothing ended')
        ticking = true
        tick()
        Mock.fireNet('pf-jobs:gruppe6:endContract', LEAD)
        assert_eq(eventsFor('pf-jobs:gruppe6:goToDeposit', LEAD), 1)
    end)
end)
