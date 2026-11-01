-- pfm-policejob search and robbery hand pfm-inventory their own 2.5 m limit, so the search stays
-- bound to it for its whole length (pfm-inventory ends it once the two are further apart; see
-- fix13b_inventory_search_reach_spec). The officer is only told what they found when the search
-- really opened.
load_resource('tests/lua/ledger_env.lua')
QBCore = QBCoreMock
QBCoreMock.Commands.Add = function() end

local searches, answer = {}, true
Mock.exportsByResource['pfm-inventory'] = {
    OpenInventoryById = function(_, src, target, opts)
        searches[#searches + 1] = { src = src, target = target, opts = opts }
        return answer
    end,
    AddItem = function() return true end,
    RemoveItem = function() return true end,
}
local closest = { -1, 99 }
QBCoreMock.Functions.GetClosestPlayer = function() return closest[1], closest[2] end

LedgerEnv.load('pfm-policejob', { 'pfm-policejob/config.lua', 'pfm-policejob/server/main.lua', 'pfm-policejob/server/interactions.lua' })

local COP, SUSPECT, ROBBER = 1, 2, 3

local function notified(src, key)
    for _, e in ipairs(Mock.clientEventsNamed('QBCore:Notify')) do
        if e.target == src and tostring(e.args[1]) == key then return true end
    end
    return false
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.players, Mock.coords = {}, {}
    searches, answer, closest = {}, true, { -1, 99 }
    local cop = Mock.newPlayer(COP)
    cop.PlayerData.job = { name = 'police', type = 'leo', onduty = true }
    local suspect = Mock.newPlayer(SUSPECT)
    suspect.PlayerData.money = { cash = 0, bank = 0 }
    suspect.PlayerData.metadata.ishandcuffed = true
    Mock.newPlayer(ROBBER)
    Mock.coords[COP] = vector3(0, 0, 0)
    Mock.coords[SUSPECT] = vector3(1, 0, 0)
    Mock.coords[ROBBER] = vector3(0, 1, 0)
end

describe('police search', function()
    it('passes its 2.5 m limit to the inventory search', function()
        closest = { SUSPECT, 1.0 }
        Mock.fireNet('police:server:SearchPlayer', COP)
        assert_eq(#searches, 1)
        assert_eq(searches[1].target, SUSPECT)
        assert_eq(type(searches[1].opts), 'table')
        assert_eq(searches[1].opts.reach, 2.5)
        assert_true(notified(COP, 'info.cash_found'))
        assert_true(notified(SUSPECT, 'info.being_searched'))
    end)

    it('says nothing when the search did not open', function()
        closest, answer = { SUSPECT, 1.0 }, false
        Mock.fireNet('police:server:SearchPlayer', COP)
        assert_eq(#searches, 1)
        assert_false(notified(COP, 'info.cash_found'))
        assert_false(notified(SUSPECT, 'info.being_searched'))
    end)

    it('nobody within 2.5 m: no search', function()
        closest = { SUSPECT, 2.6 }
        Mock.fireNet('police:server:SearchPlayer', COP)
        assert_eq(#searches, 0)
    end)
end)

describe('robbery', function()
    it('passes the same 2.5 m limit to the inventory search', function()
        Mock.fireNet('police:server:RobPlayer', ROBBER, SUSPECT)
        assert_eq(#searches, 1)
        assert_eq(searches[1].src, ROBBER)
        assert_eq(type(searches[1].opts), 'table')
        assert_eq(searches[1].opts.reach, 2.5)
    end)
end)
