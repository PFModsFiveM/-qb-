-- pfm-doorlock lockpicking (DOOR-1, PICK-2): a pickable door opens only through a server attempt
-- (startPick -> pfm-minigames challenge -> finishPick in time, at the door, holding the pick), and
-- the pick's breakage is rolled and removed on the server. `usedLockpick` from a client opens and
-- locks nothing, and the client's removeLockpick event does nothing.
load_resource('tests/lua/fivem_mocks.lua')

local timers = {}
function SetTimeout(ms, fn) timers[#timers + 1] = { ms = ms, fn = fn } end

load_resource('pfm-minigames/server/challenge.lua')
Mock.exportsByResource['pfm-minigames'] = Mock.exportsByResource['__self']

Config = nil
load_resource('pfm-doorlock/config.lua')
Config.DoorStates = Config.DoorStates or {}
load_resource('pfm-doorlock/server/main.lua')

local THIEF, OTHER = 1, 2
local DOOR = vector3(10.0, 0.0, 0.0)
local removed

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    Mock.gameTimer = Mock.gameTimer + 1000000
    timers, removed = {}, {}
    Config.LockpickBreakChance = { lockpick = 100, advancedlockpick = 0 }
    Config.DoorList = {
        ['fleeca-gate'] = { objCoords = DOOR, pickable = true, locked = true, distance = 2.0 },
        ['mrpd-armory'] = { objCoords = DOOR, authorizedJobs = { police = 0 }, locked = true, distance = 2.0 },
    }
    Config.DoorStates = {}
    for _, src in ipairs({ THIEF, OTHER }) do
        local p = Mock.newPlayer(src)
        p.PlayerData.job = { name = 'unemployed', grade = { level = 0 } }
        p.PlayerData.gang = { name = 'none', grade = { level = 0 } }
        p.GetItemByName = function(name)
            for _, it in pairs(p.PlayerData.items) do if it.name == name then return it end end
        end
        p.RemoveItem = function(name, amount)
            for k, it in pairs(p.PlayerData.items) do
                if it.name == name then
                    p.PlayerData.items[k] = nil
                    removed[#removed + 1] = { src = src, name = name, amount = amount }
                    return true
                end
            end
            return false
        end
    end
    Mock.coords = { [THIEF] = vector3(9.0, 0.0, 0.0), [OTHER] = vector3(9.5, 0.0, 0.0) }
end

local function give(src, name) table.insert(Mock.players[src].PlayerData.items, { name = name, slot = 1, amount = 1 }) end
local function later(ms) Mock.gameTimer = Mock.gameTimer + ms end
local function locked() return Config.DoorList['fleeca-gate'].locked end

local function startPick(src, door, advanced)
    Mock.fireNet('qb-doorlock:server:startPick', src, door or 'fleeca-gate', advanced)
    local sent = Mock.clientEventsNamed('qb-doorlock:client:pickChallenge')
    local last = sent[#sent]
    return last and last.target == src and last.args[2] or nil
end

-- plays the skillbar perfectly (the indicator in the middle of each zone) in real time
local function playPerfect(src, ch)
    local p, presses, total = ch.puzzle, {}, 0
    for i, r in ipairs(p.rounds) do
        local ms = math.deg(r.start + r.size / 2) * 1000 / (p.speed * 10)
        presses[i] = { k = r.key, ms = ms }
        total = total + ms
    end
    later(total + 200)
    Mock.fireNet('pfm-minigames:server:answer', src, ch.id, { presses = presses })
end

describe('the old client paths', function()
    it('usedLockpick from a client opens no pickable gate, even with a lockpick held', function()
        give(THIEF, 'lockpick')
        Mock.fireNet('qb-doorlock:server:updateState', THIEF, 'fleeca-gate', false, false, true, false)
        assert_true(locked())
        assert_eq(#Mock.clientEventsNamed('qb-doorlock:client:setState'), 0)
    end)
    it('nor locks an open one on someone', function()
        give(THIEF, 'lockpick')
        Config.DoorList['fleeca-gate'].locked = false
        Mock.fireNet('qb-doorlock:server:updateState', THIEF, 'fleeca-gate', true, false, true, false)
        assert_false(locked())
    end)
    it('removeLockpick from a client removes nothing', function()
        give(THIEF, 'lockpick')
        Mock.fireNet('qb-doorlock:server:removeLockpick', THIEF, 'lockpick')
        assert_eq(#removed, 0)
    end)
end)

describe('a lockpick attempt', function()
    it('an honest pick: the minigame passed, the door opens and the pick is kept', function()
        give(THIEF, 'lockpick')
        local ch = startPick(THIEF)
        assert_true(ch ~= nil, 'the client gets a challenge')
        assert_eq(ch.puzzle.difficulty, 'medium')
        playPerfect(THIEF, ch)
        later(2500) -- the turn-to-door animation before the client reports
        Mock.fireNet('qb-doorlock:server:finishPick', THIEF, 'fleeca-gate')
        assert_false(locked())
        assert_eq(#Mock.clientEventsNamed('qb-doorlock:client:setState'), 1)
        assert_eq(#removed, 0)
    end)
    it('an advanced pick gets the easy skillbar', function()
        give(THIEF, 'advancedlockpick')
        local ch = startPick(THIEF, nil, true)
        assert_eq(ch.puzzle.difficulty, 'easy')
    end)
    it('a finish without a passed minigame keeps the door locked and breaks the pick', function()
        give(THIEF, 'lockpick')
        startPick(THIEF)
        later(5000)
        Mock.fireNet('qb-doorlock:server:finishPick', THIEF, 'fleeca-gate')
        assert_true(locked())
        assert_eq(#removed, 1)
        assert_eq(removed[1].name, 'lockpick')
        assert_eq(#Mock.clientEventsNamed('qb-inventory:client:ItemBox'), 1)
    end)
    it('an advanced pick breaks by its own chance', function()
        give(THIEF, 'advancedlockpick')
        startPick(THIEF, nil, true)
        later(5000)
        Mock.fireNet('qb-doorlock:server:finishPick', THIEF, 'fleeca-gate')
        assert_true(locked())
        assert_eq(#removed, 0, 'chance 0')
    end)
    it('a finish faster than the minimum time opens nothing', function()
        give(THIEF, 'lockpick')
        local ch = startPick(THIEF)
        playPerfect(THIEF, ch)
        Config.LockpickMinSeconds = 600
        Mock.fireNet('qb-doorlock:server:finishPick', THIEF, 'fleeca-gate')
        Config.LockpickMinSeconds = 2
        assert_true(locked())
    end)
    it('the player must still be at the door and hold the pick', function()
        give(THIEF, 'lockpick')
        local ch = startPick(THIEF)
        playPerfect(THIEF, ch)
        later(2500)
        Mock.coords[THIEF] = vector3(200.0, 0.0, 0.0)
        Mock.fireNet('qb-doorlock:server:finishPick', THIEF, 'fleeca-gate')
        assert_true(locked())
    end)
    it('cannot start without a pick, away from the door, on a door that is not pickable, or on an open one', function()
        assert_eq(startPick(THIEF), nil, 'no pick')
        give(THIEF, 'lockpick')
        Mock.coords[THIEF] = vector3(200.0, 0.0, 0.0)
        assert_eq(startPick(THIEF), nil, 'far away')
        Mock.coords[THIEF] = vector3(9.0, 0.0, 0.0)
        assert_eq(startPick(THIEF, 'mrpd-armory'), nil, 'not pickable')
        Config.DoorList['fleeca-gate'].locked = false
        assert_eq(startPick(THIEF), nil, 'already open')
    end)
    it("a finish for another door, or another player's finish, does nothing", function()
        give(THIEF, 'lockpick')
        local ch = startPick(THIEF)
        playPerfect(THIEF, ch)
        later(2500)
        Mock.fireNet('qb-doorlock:server:finishPick', OTHER, 'fleeca-gate')
        Mock.fireNet('qb-doorlock:server:finishPick', THIEF, 'mrpd-armory')
        assert_true(locked())
        Mock.fireNet('qb-doorlock:server:finishPick', THIEF, 'fleeca-gate')
        assert_false(locked(), 'the attempt is still the thief\'s, for this door')
    end)
    it('an attempt left open fails at its deadline and the pick breaks', function()
        give(THIEF, 'lockpick')
        startPick(THIEF)
        assert_eq(#timers, 1)
        assert_true(timers[1].ms >= Config.LockpickMaxSeconds * 1000)
        timers[1].fn()
        assert_eq(#removed, 1)
        Mock.fireNet('qb-doorlock:server:finishPick', THIEF, 'fleeca-gate')
        assert_true(locked())
    end)
    it('starting again ends the open attempt as failed (no free retries)', function()
        give(THIEF, 'lockpick')
        give(THIEF, 'lockpick')
        startPick(THIEF)
        later(3000)
        startPick(THIEF)
        assert_eq(#removed, 1)
    end)
end)
