-- pf-jobs Gruppe 6 (server/apps/gruppe6.lua), 'End contract': ending early used to pay the tier
-- maximum (tierMax[tier] x share of bags) instead of the contract's own payout, so ending early
-- could pay more than finishing the contract. Ending early now pays the contract's own payout for
-- the share of bags handed in, never more than finishing would; in a party the crew bonus applies
-- to that amount, not to the tier maximum. Ending before any bag was collected used to leave the
-- contract stuck (the vault refuses an empty deposit); it now ends at once with no pay.
load_resource('tests/lua/ledger_env.lua')
QBCore = QBCoreMock
QBCoreMock.Shared.Items.moneybag = { name = 'moneybag', label = 'Money Bag', weight = 0 }
Citizen = Citizen or {}
Citizen.SetTimeout = function() return 1 end
Citizen.ClearTimeout = function() end
SetTimeout = function(_, fn) fn() end
function CreateVehicleServerSetter() Mock.nextNetId = Mock.nextNetId + 1; return Mock.nextNetId end
function SetVehicleNumberPlateText() end
function SetVehicleDoorsLocked() end
Mock.exportsByResource['pfm-inventory'] = {
    GetInventory = function() return nil end, CreateInventory = function() end, SetInventory = function() end,
    OpenInventory = function() end, RemoveInventory = function() end,
}

LedgerEnv.load('pf-jobs', { '[pfscripts]/pf-jobs/config.lua', '[pfscripts]/pf-jobs/server/apps/gruppe6.lua' })
local G6 = Config.Gruppe6
G6.UseDatabase = false
G6.ServerSideStash = true
G6.MoneyBagsPerLocationMin, G6.MoneyBagsPerLocationMax = 2, 2
G6.Debug = false
-- tier 1 pays well below its old 1000 "maximum", so the old bug shows: an early end paid more
G6.Tiers[1].payout = { 400, 400 }

local LEAD, M2 = 1, 2
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

-- takes a contract and collects the bags of the first `stops` pickups (all when nil)
local function collect(src, stops)
    Mock.fireNet('pf-jobs:gruppe6:startSearch', src)
    Mock.fireNet('pf-jobs:gruppe6:acceptContract', src, { contractId = 0 })
    local starts = Mock.clientEventsNamed('pf-jobs:gruppe6:startContract')
    local data = starts[#starts].args[1]
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

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.clock = Mock.clock + 100000
    for src = 1, 2 do Mock.fireNet('pf-jobs:gruppe6:disbandGroup', src) end
    Mock.players, Mock.coords = {}, {}
    for src = 1, 2 do newGuard(src); Mock.fireEvent('playerDropped', src) end
    for src = 1, 2 do newGuard(src); PFJobsG6.ForgetCitizen('CID' .. src) end
end

describe('Gruppe 6: ending a contract early', function()
    it("pays the contract's own payout for the share of bags handed in (not the tier maximum)", function()
        local data, taken, total = collect(LEAD, 1)
        assert_eq(data.payout, 400)
        assert_true(taken > 0 and taken < total, 'some bags, not all')
        Mock.fireNet('pf-jobs:gruppe6:endContract', LEAD)
        atVault(LEAD)
        Mock.fireNet('pf-jobs:gruppe6:depositComplete', LEAD)
        local rows = paid()
        assert_eq(#rows, 1)
        assert_eq(rows[1].amount, math.floor(data.payout * taken / total))
        assert_true(rows[1].amount < data.payout, 'less than finishing')
    end)

    it('ending early with every bag pays exactly what finishing pays, never more', function()
        local data = collect(LEAD)
        Mock.fireNet('pf-jobs:gruppe6:endContract', LEAD)
        atVault(LEAD)
        Mock.fireNet('pf-jobs:gruppe6:depositComplete', LEAD)
        assert_eq(#paid(), 1)
        assert_eq(bank(LEAD), data.payout, 'the old code paid the 1000 tier maximum here')
    end)

    it('finishing the contract pays its payout', function()
        local data = collect(LEAD)
        atVault(LEAD)
        Mock.fireNet('pf-jobs:gruppe6:depositComplete', LEAD)
        assert_eq(bank(LEAD), data.payout)
    end)

    it("in a party the crew bonus applies to the contract's share, not to the tier maximum", function()
        Mock.fireNet('pf-jobs:gruppe6:createGroup', LEAD)
        local code = Mock.callCallback('pf-jobs:gruppe6:getAppView', LEAD).group.groupCode
        Mock.fireNet('pf-jobs:gruppe6:joinByCode', M2, code)
        local data, taken, total = collect(LEAD, 1)
        Mock.fireNet('pf-jobs:gruppe6:endContract', LEAD)
        atVault(LEAD)
        Mock.fireNet('pf-jobs:gruppe6:depositComplete', LEAD)
        local share = math.floor(data.payout * taken / total)
        local bonus = tonumber((G6.Groups or {}).CrewBonus) or 1.5
        local pool = math.floor(share * bonus) * 2
        assert_eq(#paid(), 2, 'one payment per member')
        assert_eq(bank(LEAD) + bank(M2), pool)
        -- never more than the same crew finishing the whole contract
        assert_true(pool <= math.floor(data.payout * bonus) * 2)
    end)

    it('ending before any bag is collected closes the contract with no pay (it used to stay stuck)', function()
        collect(LEAD, 0)
        Mock.fireNet('pf-jobs:gruppe6:endContract', LEAD)
        assert_eq(#paid(), 0, 'nothing paid')
        assert_eq(bank(LEAD), 0)
        assert_eq(#Mock.clientEventsNamed('pf-jobs:gruppe6:goToDeposit'), 0, 'no vault trip for an empty deposit')
        assert_eq(#Mock.clientEventsNamed('pf-jobs:gruppe6:returnWithoutBags'), 1, 'sent back to HQ with the truck')
        assert_eq(Mock.callCallback('pf-jobs:gruppe6:getAppView', LEAD).contract, nil, 'the contract is over')
        -- a deposit now does nothing; once the truck is back (as after any contract) a new one
        -- can be taken
        atVault(LEAD)
        Mock.fireNet('pf-jobs:gruppe6:depositComplete', LEAD)
        assert_eq(#paid(), 0)
        Mock.fireNet('pf-jobs:gruppe6:vehicleReturned', LEAD)
        Mock.clock = Mock.clock + 10
        local data = collect(LEAD)
        atVault(LEAD)
        Mock.fireNet('pf-jobs:gruppe6:depositComplete', LEAD)
        assert_eq(bank(LEAD), data.payout, 'the next contract pays as usual')
    end)

    it('in a party, ending with no bags ends the contract for the whole crew', function()
        Mock.fireNet('pf-jobs:gruppe6:createGroup', LEAD)
        local code = Mock.callCallback('pf-jobs:gruppe6:getAppView', LEAD).group.groupCode
        Mock.fireNet('pf-jobs:gruppe6:joinByCode', M2, code)
        collect(LEAD, 0)
        assert_true(Mock.callCallback('pf-jobs:gruppe6:getAppView', M2).contract ~= nil, 'the member shares it')
        Mock.fireNet('pf-jobs:gruppe6:endContract', M2)
        assert_eq(#paid(), 0)
        for _, src in ipairs({ LEAD, M2 }) do
            assert_eq(Mock.callCallback('pf-jobs:gruppe6:getAppView', src).contract, nil)
            local sent = 0
            for _, e in ipairs(Mock.clientEventsNamed('pf-jobs:gruppe6:returnWithoutBags')) do
                if e.target == src then sent = sent + 1 end
            end
            assert_eq(sent, 1, 'told: ' .. src)
        end
    end)
end)
