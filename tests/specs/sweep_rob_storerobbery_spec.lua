-- pfm-storerobbery: a keypad safe cannot be opened through the padlock path, a padlock safe pays
-- only for a dial challenge the server judged passed, and a police alert must come from the store
-- it names.
load_resource('tests/lua/fivem_mocks.lua')
Inv = {}
Mock.exportsByResource['pfm-inventory'] = {
    AddItem = function(_, src, item, n) Inv[item] = (Inv[item] or 0) + (n or 1) return true end,
    RemoveItem = function() return true end,
}
-- pfm-minigames: the spec decides each challenge's verdict
Challenges, Issued = {}, {}
Mock.exportsByResource['pfm-minigames'] = {
    IssueChallenge = function(_, src, kind, opts)
        local id = 'ch' .. (#Issued + 1)
        Challenges[id] = { src = src, kind = kind, opts = opts }
        Issued[#Issued + 1] = id
        return { id = id, kind = kind, puzzle = {}, expiresIn = 30000 }
    end,
    Verify = function(_, src, id)
        local c = Challenges[id]
        Challenges[id] = nil
        return c ~= nil and c.src == src and c.passed == true, 0
    end,
    Cancel = function(_, _, id) Challenges[id] = nil return true end,
}
setmetatable(QBCoreMock.Shared.Items, { __index = function(_, k) return { name = k, label = k } end })
-- run each thread up to its first Wait, so the safe codes get generated
local realThread, realWait = CreateThread, Wait
CreateThread = function(fn) pcall(fn) end
Wait = function() error('stop thread') end
load_resource('pfm-storerobbery/config.lua')
load_resource('pfm-storerobbery/server/main.lua')
CreateThread, Wait = realThread, realWait

local R, COP = 1, 2
local function firstSafe(kind)
    for i, s in ipairs(Config.Safes) do if s.type == kind then return i end end
end
local function at(src, c) Mock.coords[src] = vector3(c.x, c.y, c.z) end

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 100000
    Mock.players, Mock.coords, Inv = {}, {}, {}
    Mock.newPlayer(R)
    Mock.newPlayer(COP).PlayerData.job = { name = 'police', type = 'leo', onduty = true }
    Config.MinimumStoreRobberyPolice = 1
    for _, s in ipairs(Config.Safes) do s.robbed = false end
end

describe('store safes', function()
    it('the padlock path gives nothing for a keypad safe, so it cannot be opened without the code', function()
        local safe = firstSafe('keypad')
        at(R, Config.Safes[safe][1])
        assert_eq(Mock.callCallback('qb-storerobbery:server:startPadlock', R, safe), nil)
        Mock.clock = Mock.clock + 30
        Mock.fireNet('qb-storerobbery:server:SafeReward', R, safe)
        assert_eq(Inv.markedbills, nil)
        assert_false(Config.Safes[safe].robbed)
    end)
    it('a padlock safe sends a dial challenge, never its combination, and pays once it was passed', function()
        local safe = firstSafe('padlock')
        at(R, Config.Safes[safe][1])
        assert_eq(Mock.netHandlers['qb-storerobbery:server:getPadlockCombination'], nil)
        local ch = Mock.callCallback('qb-storerobbery:server:startPadlock', R, safe)
        assert_eq(ch.kind, 'keys')
        assert_eq(ch.puzzle.combination, nil)
        Challenges[ch.id].passed = true
        Mock.clock = Mock.clock + 25
        Mock.fireNet('qb-storerobbery:server:SafeReward', R, safe)
        assert_true((Inv.markedbills or 0) > 0)
    end)
end)

describe('store robbery alert', function()
    it('is ignored when the player is not at the store it names', function()
        Mock.coords[R] = vector3(0, 0, 0)
        Mock.fireNet('qb-storerobbery:server:callCops', R, 'cashier', 1, 'Somewhere', vector3(0, 0, 0))
        assert_eq(#Mock.clientEventsNamed('qb-storerobbery:client:robberyCall'), 0)
        assert_eq(#Mock.clientEventsNamed('qb-phone:client:addPoliceAlert'), 0)
    end)
    it('at the register it alerts, with the street label as plain text', function()
        local reg = Config.Registers[1][1]
        at(R, reg)
        Mock.fireNet('qb-storerobbery:server:callCops', R, 'cashier', 1, '<img src=x onerror=1>Grove St', vector3(reg.x, reg.y, reg.z))
        local calls = Mock.clientEventsNamed('qb-storerobbery:client:robberyCall')
        assert_eq(#calls, 1)
        assert_eq(calls[1].args[3]:find('<', 1, true), nil)
    end)
end)
