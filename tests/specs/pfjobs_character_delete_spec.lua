-- pf-jobs and deleted characters (server/schema.lua): pfm-core's server-only
-- 'pfm-core:server:characterDeleted' removes the character from live Gruppe 6 parties and garbage
-- crews (a leader's crew is closed), ends its bus route and tow rental, and deletes its rows from
-- every pf-jobs table that exists. A bad citizen id does nothing.
load_resource('tests/lua/ledger_env.lua')
QBCore = QBCoreMock
Citizen.SetTimeout = function() return 1 end
Citizen.ClearTimeout = function() end
SetTimeout = function() end
local alive = {}
function CreateVehicleServerSetter(hash, _, x, y, z)
    Mock.nextNetId = Mock.nextNetId + 1
    alive[Mock.nextNetId], Mock.coords[Mock.nextNetId] = true, vector3(x, y, z)
    return Mock.nextNetId
end
function DoesEntityExist(e) return alive[e] == true or Mock.players[e] ~= nil end
function DeleteEntity(e) alive[e] = nil end
function SetVehicleNumberPlateText() end
function SetVehicleDoorsLocked() end

-- every table exists; DELETEs are recorded
local deletes = {}
FakeDB.extraPatterns = {
    { 'information_schema.TABLES', function(p) local out = {} for _, n in ipairs(p) do out[#out + 1] = { name = n } end return out end },
    { 'DELETE FROM `', function(p) deletes[#deletes + 1] = { cid = p[1] } return 1 end },
}

LedgerEnv.load('pf-jobs', {
    '[pfscripts]/pf-jobs/config.lua',
    '[pfscripts]/pf-jobs/server/apps/bus.lua',
    '[pfscripts]/pf-jobs/server/apps/garbage.lua',
    '[pfscripts]/pf-jobs/server/apps/gruppe6.lua',
    '[pfscripts]/pf-jobs/server/apps/tow.lua',
    '[pfscripts]/pf-jobs/server/schema.lua',
})
Config.Bus.UseDatabase, Config.Garbage.UseDatabase, Config.Gruppe6.UseDatabase, Config.Tow.UseDatabase = false, false, false, false
-- capture the statements' text too
local statements = {}
local realUpdate = MySQL.update.await
MySQL.update.await = function(q, p) statements[#statements + 1] = q return realUpdate(q, p) end

local A, B, C = 1, 2, 3
BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players, Mock.coords, alive, deletes, statements = {}, {}, {}, {}, {}
    for src = 1, 3 do
        local p = Mock.newPlayer(src)
        p.PlayerData.money = { cash = 1000, bank = 0 }
        Mock.fireEvent('pfm-core:server:characterDeleted', nil, 'CID' .. src)
    end
    deletes, statements = {}, {}
    Mock.reset()
end

local function g6(src) return Mock.callCallback('pf-jobs:gruppe6:getGroup', src) end
local function gb(src) return Mock.callCallback('pf-jobs:garbage:getGroupState', src) end

describe('deleted characters', function()
    it('a bad citizen id does nothing', function()
        for _, bad in ipairs({ 42, { 'CID1' }, '', string.rep('A', 80), "CID1' OR 1=1 --" }) do
            assert_eq(PFJobsSchema.ForgetCharacter(bad), nil)
        end
        Mock.fireEvent('pfm-core:server:characterDeleted', nil, nil)
        assert_eq(#deletes, 0)
    end)

    it('rows are deleted from every pf-jobs table for that character only', function()
        local n = PFJobsSchema.ForgetCharacter('CID2')
        assert_eq(n, #PFJobsSchema.CharacterRows)
        assert_eq(#deletes, #PFJobsSchema.CharacterRows)
        for _, d in ipairs(deletes) do assert_eq(d.cid, 'CID2') end
        -- child rows before their parents
        local pos = {}
        for i, q in ipairs(statements) do pos[q:match('DELETE FROM `([%w_]+)`')] = i end
        assert_true(pos.bus_routes_log < pos.bus_stats)
        assert_true(pos.pf_gruppe6_group_members < pos.pf_gruppe6_groups)
        assert_true(pos.pf_tow_rentals ~= nil and pos.pf_gruppe6_upgrades ~= nil)
    end)

    it('a member leaves the live parties and crews; a leader\'s party is closed', function()
        Mock.fireNet('pf-jobs:gruppe6:createGroup', A)
        Mock.fireNet('pf-jobs:gruppe6:invitePlayer', A, B)
        Mock.fireNet('pf-jobs:gruppe6:acceptInvite', B, A)
        Mock.fireNet('pf-jobs:gruppe6:invitePlayer', A, C)
        Mock.fireNet('pf-jobs:gruppe6:acceptInvite', C, A)
        Mock.fireNet('pf-jobs:garbage:createGroup', B)
        Mock.fireNet('pf-jobs:garbage:invitePlayer', B, C)
        Mock.fireNet('pf-jobs:garbage:acceptInvite', C, B)
        assert_eq(#g6(A).members, 2)
        -- the character of player 2 is deleted (the player is back at character select)
        Mock.players[B] = nil
        Mock.fireEvent('pfm-core:server:characterDeleted', nil, 'CID2')
        local party = g6(A)
        assert_eq(#party.members, 1)
        assert_eq(party.members[1], C)
        assert_eq(party.payoutSplits[A] + party.payoutSplits[C], 100, 'shares reset for the rest')
        assert_eq(party.payoutSplits[B], nil)
        assert_eq(gb(C), nil, 'the garbage crew led by the deleted character is closed')
        -- the leader's party goes when the leader's character is deleted
        Mock.fireEvent('pfm-core:server:characterDeleted', nil, 'CID1')
        assert_eq(g6(C), nil)
    end)

    it('the bus route and the tow rental of that character end', function()
        Mock.fireNet('bus:server:startRoute', A, 1)
        assert_true(PFJobsBus.View(A).activeRoute ~= nil)
        Mock.players[A].PlayerData.job = { name = 'tow', onduty = true }
        local bay = Config.Tow.FlatbedSpawn
        Mock.coords[A] = vector3(bay.x, bay.y, bay.z)
        assert_eq(PFJobsTow.Rent(A, 'flatbed', true).ok, true)
        local truck = Mock.nextNetId
        Mock.fireEvent('pfm-core:server:characterDeleted', nil, 'CID1')
        assert_eq(PFJobsBus.View(A).activeRoute, nil)
        assert_eq(alive[truck], nil, 'the truck is removed')
        assert_eq(PFJobsTow.View(A).rental, nil)
    end)
end)
