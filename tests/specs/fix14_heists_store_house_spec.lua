-- pfm-storerobbery / pfm-houserobbery (batch 14, PICK-2): lockpick attempts are tracked on the server,
-- the minigame result is a pfm-minigames challenge the server judges, and the pick breaks on the
-- server (the client remove-lockpick events do nothing). Padlock safes and furniture searches are
-- server-judged challenges too.
load_resource('tests/lua/fivem_mocks.lua')

Inv = {}
local function count(src, item) return (Inv[src] and Inv[src][item]) or 0 end
local function give(src, item, n) Inv[src] = Inv[src] or {}; Inv[src][item] = count(src, item) + (n or 1) end
Mock.exportsByResource['pfm-inventory'] = {
    AddItem = function(_, src, item, n) give(src, item, n or 1); return true end,
    RemoveItem = function(_, src, item, n)
        n = n or 1
        if count(src, item) < n then return false end
        Inv[src][item] = count(src, item) - n
        return true
    end,
    GetItemByName = function(_, src, item) if count(src, item) > 0 then return { name = item, amount = count(src, item) } end end,
}
setmetatable(QBCoreMock.Shared.Items, { __index = function(_, k) return { name = k, label = k, unique = false } end })

-- pfm-minigames: the spec decides each challenge's verdict before the resource verifies it
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
        if not c or c.src ~= src then return false, 0, 'unknown' end
        return c.passed == true, 0
    end,
    Cancel = function(_, _, id) Challenges[id] = nil return true end,
}
local function latest() return Challenges[Issued[#Issued]], Issued[#Issued] end
local function passLatest() latest().passed = true end
Timers = {}
function SetTimeout(ms, fn) Timers[#Timers + 1] = { ms = ms, fn = fn } end
local function runTimers() local list = Timers; Timers = {}; for _, t in ipairs(list) do t.fn() end end

-- each resource keeps its own Config; the tests switch to the one they exercise
local realThread, realWait = CreateThread, Wait
CreateThread = function(fn) pcall(fn) end   -- runs the safe-code thread up to its first Wait
Wait = function() error('stop thread') end
Config = nil
load_resource('pfm-storerobbery/config.lua')
load_resource('pfm-storerobbery/server/main.lua')
local StoreCfg = Config
CreateThread, Wait = realThread, realWait
Config = nil
load_resource('pfm-houserobbery/config.lua')
for _, tier in pairs(Config.Rewards) do
    for _, list in pairs(tier) do
        for _, r in ipairs(list) do QBCoreMock.Shared.Items[r.item] = { name = r.item, label = r.item, unique = false } end
    end
end
load_resource('pfm-houserobbery/server/main.lua')
local HouseCfg = Config

local R, OTHER, COP1, COP2 = 1, 2, 3, 4
local function at(src, c) Mock.coords[src] = vector3(c.x, c.y, c.z) end

BeforeEach = function()
    Mock.reset()
    Mock.clock = Mock.clock + 10000
    Mock.gameTimer = Mock.gameTimer + 60000
    Mock.players, Mock.coords, Inv, Challenges, Issued, Timers = {}, {}, {}, {}, {}, {}
    for _, src in ipairs({ R, OTHER }) do
        local p = Mock.newPlayer(src)
        p.PlayerData.job = { name = 'unemployed', type = 'none', onduty = false }
        p.Functions.GetItemByName = function(item) if count(src, item) > 0 then return { name = item, amount = count(src, item) } end end
    end
    for _, c in ipairs({ COP1, COP2 }) do Mock.newPlayer(c).PlayerData.job = { name = 'police', type = 'leo', onduty = true } end
    for _, reg in pairs(StoreCfg.Registers) do reg.robbed = false; reg.time = 0 end
    for _, s in pairs(StoreCfg.Safes) do s.robbed = false end
    for _, h in pairs(HouseCfg.Houses) do
        h.opened = false
        for _, f in pairs(h.furniture) do f.searched = false; f.isBusy = false end
    end
end

describe('store registers', function()
    -- (an opened register stays in its emptying session until the reset ticker: each test uses its own)
    local REG = 5
    local function start(src, adv) Mock.fireNet('qb-storerobbery:server:startRegister', src, REG, adv) end
    local function finish(src) Mock.fireNet('qb-storerobbery:server:finishRegister', src, REG) end

    it('a register opens only for a lockpick challenge the server judged passed', function()
        Config = StoreCfg
        assert_eq(Mock.netHandlers['qb-storerobbery:server:setRegisterStatus'], nil)
        give(R, 'lockpick')
        at(R, Config.Registers[REG][1])
        Config.LockpickBreakChance.lockpick = 0
        start(R)
        assert_eq(latest().kind, 'lockpick')
        Mock.gameTimer = Mock.gameTimer + 3000
        finish(R)                                                    -- never passed
        assert_false(Config.Registers[REG].robbed)
        Mock.gameTimer = Mock.gameTimer + 3000
        start(R)
        passLatest()
        finish(R)                                                    -- passed, but no time to play it
        assert_false(Config.Registers[REG].robbed)
        Mock.gameTimer = Mock.gameTimer + 3000
        start(R)
        passLatest()
        Mock.gameTimer = Mock.gameTimer + 3000
        finish(R)
        assert_true(Config.Registers[REG].robbed)
        local res = Mock.clientEventsNamed('qb-storerobbery:client:registerResult')
        assert_true(res[#res].args[2])
        Config.LockpickBreakChance.lockpick = 40
        REG = 9
    end)

    it('the pick breaks on the server after a failed, restarted or abandoned attempt; the client cannot keep or drop it', function()
        Config = StoreCfg
        Config.LockpickBreakChance.lockpick = 100
        give(R, 'lockpick', 3)
        at(R, Config.Registers[REG][1])
        Mock.fireNet('qb-storerobbery:server:removeLockpick', R)    -- the client's word counts for nothing
        assert_eq(count(R, 'lockpick'), 3)
        start(R)
        Mock.gameTimer = Mock.gameTimer + 3000
        finish(R)                                                    -- failed
        assert_eq(count(R, 'lockpick'), 2)
        Mock.gameTimer = Mock.gameTimer + 3000
        start(R)
        Mock.gameTimer = Mock.gameTimer + 3000
        start(R)                                                     -- restarted: the first one failed
        assert_eq(count(R, 'lockpick'), 1)
        runTimers()                                                  -- abandoned: timed out
        assert_eq(count(R, 'lockpick'), 0)
        Config.LockpickBreakChance.lockpick = 40
    end)

    it('an advanced pick is used when asked for and breaks at its own chance', function()
        Config = StoreCfg
        Config.LockpickBreakChance.advancedlockpick = 0
        give(R, 'lockpick'); give(R, 'advancedlockpick')
        at(R, Config.Registers[REG][1])
        start(R, true)
        Mock.gameTimer = Mock.gameTimer + 3000
        finish(R)
        assert_eq(count(R, 'advancedlockpick'), 1)
        assert_eq(count(R, 'lockpick'), 1)
        Config.LockpickBreakChance.advancedlockpick = 20
    end)

    it('nothing starts away from the register, without a pick, or without police', function()
        Config = StoreCfg
        Mock.coords[R] = vector3(0, 0, 0)
        give(R, 'lockpick')
        start(R)
        at(R, Config.Registers[REG][1])
        Inv[R].lockpick = 0
        start(R)
        give(R, 'lockpick')
        Mock.players[COP2] = nil
        start(R)
        assert_eq(#Issued, 0)
    end)
end)

describe('store padlock safes', function()
    local function padlock()
        for i, s in ipairs(StoreCfg.Safes) do if s.type == 'padlock' then return i end end
    end
    it('a failed dial pays nothing and is used up; another player cannot take over a live crack', function()
        Config = StoreCfg
        local safe = padlock()
        at(R, Config.Safes[safe][1]); at(OTHER, Config.Safes[safe][1])
        local ch = Mock.callCallback('qb-storerobbery:server:startPadlock', R, safe)
        assert_eq(ch.kind, 'keys')
        assert_eq(Mock.callCallback('qb-storerobbery:server:startPadlock', OTHER, safe), nil)
        Mock.clock = Mock.clock + 25
        Mock.fireNet('qb-storerobbery:server:SafeReward', R, safe)   -- not passed
        assert_eq(count(R, 'markedbills'), 0)
        Challenges[ch.id] = { src = R, passed = true }               -- (too late: already judged)
        Mock.fireNet('qb-storerobbery:server:SafeReward', R, safe)
        assert_eq(count(R, 'markedbills'), 0)
        assert_false(Config.Safes[safe].robbed)
    end)
end)

describe('house break-ins', function()
    local HOUSE = 'perfectdrive2'
    local function door() return HouseCfg.Houses[HOUSE].coords end

    it('the door opens only for a skillbar the server judged passed; a failure rolls the pick on the server', function()
        Config = HouseCfg
        local old = Config.ChanceToBreakAdvancedLockPick
        Config.ChanceToBreakAdvancedLockPick = 100
        give(R, 'advancedlockpick', 2)
        at(R, door())
        Mock.fireNet('qb-houserobbery:server:removeAdvancedLockpick', R) -- does nothing now
        assert_eq(count(R, 'advancedlockpick'), 2)
        Mock.fireNet('qb-houserobbery:server:startLockpick', R, HOUSE, true)
        assert_eq(latest().kind, 'skillbar')
        assert_eq(latest().opts.difficulty, 'easy')
        Mock.gameTimer = Mock.gameTimer + 5000
        Mock.fireNet('qb-houserobbery:server:enterHouse', R, HOUSE)   -- failed skillbar
        assert_false(Config.Houses[HOUSE].opened)
        assert_eq(count(R, 'advancedlockpick'), 1)
        Mock.fireNet('qb-houserobbery:server:startLockpick', R, HOUSE, true)
        passLatest()
        Mock.gameTimer = Mock.gameTimer + 5000
        Mock.fireNet('qb-houserobbery:server:enterHouse', R, HOUSE)
        assert_true(Config.Houses[HOUSE].opened)
        assert_eq(count(R, 'advancedlockpick'), 1)
        Config.ChanceToBreakAdvancedLockPick = old
    end)

    it('an abandoned pick times out on the server and may break', function()
        Config = HouseCfg
        local old = Config.ChanceToBreakLockPick
        Config.ChanceToBreakLockPick = 100
        give(R, 'lockpick'); give(R, 'screwdriverset')
        at(R, door())
        Mock.fireNet('qb-houserobbery:server:startLockpick', R, HOUSE, false)
        assert_eq(latest().opts.difficulty, 'medium')
        runTimers()
        assert_eq(count(R, 'lockpick'), 0)
        Config.ChanceToBreakLockPick = old
    end)

    it('a search pays only after a passed skillbar; the server sets and clears the busy flag', function()
        Config = HouseCfg
        give(R, 'advancedlockpick')
        at(R, door())
        Mock.fireNet('qb-houserobbery:server:startLockpick', R, HOUSE, true)
        passLatest()
        Mock.gameTimer = Mock.gameTimer + 5000
        Mock.fireNet('qb-houserobbery:server:enterHouse', R, HOUSE)
        local piece = Config.Houses[HOUSE].furniture[2]
        Mock.fireNet('qb-houserobbery:server:searchFurniture', R, 2, HOUSE)  -- no search started
        assert_false(piece.searched)
        Mock.fireNet('qb-houserobbery:server:startSearch', R, 2, HOUSE)
        assert_true(piece.isBusy)
        Mock.gameTimer = Mock.gameTimer + 3000
        Mock.fireNet('qb-houserobbery:server:searchFurniture', R, 2, HOUSE)  -- failed skillbar
        assert_false(piece.searched)
        assert_false(piece.isBusy)
        Mock.clock = Mock.clock + 5
        Mock.fireNet('qb-houserobbery:server:startSearch', R, 2, HOUSE)
        passLatest()
        Mock.gameTimer = Mock.gameTimer + 3000
        Mock.fireNet('qb-houserobbery:server:searchFurniture', R, 2, HOUSE)
        assert_true(piece.searched)
        assert_false(piece.isBusy)
        Mock.fireNet('qb-houserobbery:server:SetBusyState', R, 3, HOUSE, true)  -- clients no longer set it
        assert_false(Config.Houses[HOUSE].furniture[3].isBusy)
    end)
end)
