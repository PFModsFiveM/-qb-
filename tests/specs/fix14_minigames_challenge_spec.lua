-- pfm-minigames server challenges: the server generates the puzzle, the client's answer is judged
-- once against it and against server time, and Verify gives one verdict to the resource that
-- issued it. (pfm-minigames had no server part: every minigame result was the client's word.)
load_resource('tests/lua/fivem_mocks.lua')
load_resource('pfm-minigames/server/challenge.lua')

local Issue = Mock.selfExport('IssueChallenge')
local Verify = Mock.selfExport('Verify')
local Cancel = Mock.selfExport('Cancel')

local P1, P2 = 1, 2

BeforeEach = function()
    Mock.reset()
    Mock.invokingResource = nil
    Mock.gameTimer = Mock.gameTimer + 1000000 -- every challenge of an earlier test has expired
end

local function later(ms) Mock.gameTimer = Mock.gameTimer + ms end
local function answer(src, ch, a) Mock.fireNet('pfm-minigames:server:answer', src, ch.id, a) end
local function verdicts() return Mock.clientEventsNamed('pfm-minigames:client:verdict') end

-- a perfect skillbar answer: each key pressed with the indicator in the middle of its zone
local function skillbarAnswer(p, shift)
    local presses, total = {}, 0
    for i, r in ipairs(p.rounds) do
        local deg = math.deg(r.start + r.size / 2) + (shift or 0)
        local ms = deg * 1000 / (p.speed * 10)
        presses[i] = { k = r.key, ms = ms }
        total = total + ms
    end
    return { presses = presses }, total
end

describe('skillbar', function()
    it('a correct answer played in real time passes, once', function()
        local ch = Issue(P1, 'skillbar', { difficulty = 'medium' })
        assert_eq(#ch.puzzle.rounds, 4)
        local a, total = skillbarAnswer(ch.puzzle)
        later(total + 300)
        answer(P1, ch, a)
        assert_eq(verdicts()[1].args[2], true, 'the client is told the verdict')
        local passed, faults = Verify(P1, ch.id)
        assert_true(passed)
        assert_eq(faults, 0)
        local again, _, why = Verify(P1, ch.id)
        assert_false(again, 'one verdict per challenge')
        assert_eq(why, 'unknown')
    end)
    it('a correct answer sent faster than the rounds can be played fails', function()
        local ch = Issue(P1, 'skillbar', { difficulty = 'easy' })
        local a = skillbarAnswer(ch.puzzle)
        answer(P1, ch, a)
        local passed, _, why = Verify(P1, ch.id)
        assert_false(passed)
        assert_eq(why, 'too_fast')
    end)
    it('a press outside the zone or with the wrong key fails', function()
        local ch = Issue(P1, 'skillbar', {})
        local zoneDeg = math.deg(ch.puzzle.rounds[1].size)
        local a, total = skillbarAnswer(ch.puzzle, zoneDeg) -- half a zone past its end
        later(total + 1000)
        answer(P1, ch, a)
        assert_false(Verify(P1, ch.id))

        ch = Issue(P1, 'skillbar', { keys = 'qw' })
        a, total = skillbarAnswer(ch.puzzle)
        a.presses[1].k = a.presses[1].k == 'q' and 'w' or 'q'
        later(total + 1000)
        answer(P1, ch, a)
        local passed, faults = Verify(P1, ch.id)
        assert_false(passed)
        assert_eq(faults, 1)
    end)
    it('a missing round (the indicator ran out) fails', function()
        local ch = Issue(P1, 'skillbar', {})
        local a, total = skillbarAnswer(ch.puzzle)
        a.presses[#a.presses] = nil
        later(total + 1000)
        answer(P1, ch, a)
        assert_false(Verify(P1, ch.id))
    end)
end)

describe('answers', function()
    it('only the first answer counts', function()
        local ch = Issue(P1, 'skillbar', {})
        local a, total = skillbarAnswer(ch.puzzle)
        answer(P1, ch, { presses = {} })      -- a failed try first
        later(total + 500)
        answer(P1, ch, a)                     -- then the perfect one
        assert_eq(#verdicts(), 1)
        assert_false(Verify(P1, ch.id))
    end)
    it("another player's answer and verify do not touch the challenge", function()
        local ch = Issue(P1, 'skillbar', {})
        local a, total = skillbarAnswer(ch.puzzle)
        later(total + 500)
        answer(P2, ch, a)
        assert_eq(#verdicts(), 0)
        local passed, _, why = Verify(P2, ch.id)
        assert_false(passed)
        assert_eq(why, 'wrong_player')
        answer(P1, ch, a)
        assert_true(Verify(P1, ch.id), 'still there for its player')
    end)
    it('an answer after the challenge expired fails', function()
        local ch = Issue(P1, 'skillbar', {})
        local a = skillbarAnswer(ch.puzzle)
        later(ch.expiresIn + 1)
        answer(P1, ch, a)
        local passed, _, why = Verify(P1, ch.id)
        assert_false(passed)
        assert_eq(why, 'expired')
    end)
    it('verify before any answer fails and uses the challenge up', function()
        local ch = Issue(P1, 'skillbar', {})
        local passed, _, why = Verify(P1, ch.id)
        assert_false(passed)
        assert_eq(why, 'pending')
        local a, total = skillbarAnswer(ch.puzzle)
        later(total + 500)
        answer(P1, ch, a)
        assert_false(Verify(P1, ch.id))
    end)
    it('malformed answers fail without errors', function()
        for _, bad in ipairs({ 'yes', 12, { presses = 'x' }, { presses = { { k = {}, ms = 'a' } } } }) do
            local ch = Issue(P1, 'skillbar', {})
            later(60000)
            answer(P1, ch, bad)
            assert_false(Verify(P1, ch.id))
        end
    end)
    it('only the resource that issued a challenge may verify it', function()
        Mock.invokingResource = 'pfm-doorlock'
        local ch = Issue(P1, 'skillbar', {})
        local a, total = skillbarAnswer(ch.puzzle)
        later(total + 500)
        answer(P1, ch, a)
        Mock.invokingResource = 'some-other-resource'
        local passed, _, why = Verify(P1, ch.id)
        assert_false(passed)
        assert_eq(why, 'wrong_resource')
        Mock.invokingResource = 'pfm-doorlock'
        assert_true(Verify(P1, ch.id))
    end)
    it("another resource cannot cancel a challenge it did not issue", function()
        Mock.invokingResource = 'pfm-doorlock'
        local ch = Issue(P1, 'skillbar', {})
        Mock.invokingResource = 'some-other-resource'
        assert_false(Cancel(P1, ch.id))
        Mock.invokingResource = 'pfm-doorlock'
        assert_true(Cancel(P1, ch.id))
    end)
    it('a judged answer raises the server-local answered event with the tag', function()
        local seen = {}
        Mock.eventHandlers['pfm-minigames:server:answered'] = function(info) seen[#seen + 1] = info end
        Mock.invokingResource = 'pfm-bankrobbery'
        local ch = Issue(P1, 'skillbar', { tag = 'bank:fleeca1' })
        local a, total = skillbarAnswer(ch.puzzle)
        later(total + 300)
        answer(P1, ch, a)
        answer(P1, ch, a) -- a second answer is ignored
        Mock.eventHandlers['pfm-minigames:server:answered'] = nil
        assert_eq(#seen, 1)
        assert_eq(seen[1].id, ch.id)
        assert_eq(seen[1].src, P1)
        assert_eq(seen[1].tag, 'bank:fleeca1')
        assert_eq(seen[1].owner, 'pfm-bankrobbery')
        assert_true(seen[1].passed)
        assert_true(Verify(P1, ch.id), 'still verified by its issuer')
    end)
    it('cancel, unknown kinds and players, the per-player cap and a dropped player', function()
        local ch = Issue(P1, 'skillbar', {})
        assert_true(Cancel(P1, ch.id))
        assert_eq(select(3, Verify(P1, ch.id)), 'unknown')
        assert_eq(select(2, Issue(P1, 'chess', {})), 'unknown_kind')
        assert_eq(select(2, Issue(0, 'skillbar', {})), 'invalid_player')

        local first = Issue(P1, 'skillbar', {})
        for _ = 1, 6 do Issue(P1, 'skillbar', {}) end
        assert_eq(select(3, Verify(P1, first.id)), 'unknown', 'the oldest open challenge goes')

        local mine = Issue(P2, 'skillbar', {})
        Mock.fireEvent('playerDropped', P2)
        assert_eq(select(3, Verify(P2, mine.id)), 'unknown')
    end)
end)

describe('keys', function()
    local function keysAnswer(p, wrongAt)
        local presses = {}
        for i, key in ipairs(p.pattern) do
            presses[#presses + 1] = { s = i, k = i == wrongAt and (key == 'ArrowUp' and 'ArrowDown' or 'ArrowUp') or key, ms = 250 }
        end
        return { presses = presses }
    end
    local function playTime(p) return p.lead + (p.amount - 1) * p.step + p.window end

    it('every arrow in its window passes; a wrong one is a fault', function()
        local ch = Issue(P1, 'keyminigame', { amount = 6 })
        assert_eq(#ch.puzzle.pattern, 6)
        later(playTime(ch.puzzle) + 100)
        answer(P1, ch, keysAnswer(ch.puzzle))
        local passed, faults = Verify(P1, ch.id)
        assert_true(passed)
        assert_eq(faults, 0)

        ch = Issue(P1, 'keys', { amount = 6, maxFaults = 1 })
        later(playTime(ch.puzzle) + 100)
        answer(P1, ch, keysAnswer(ch.puzzle, 3))
        passed, faults = Verify(P1, ch.id)
        assert_true(passed, 'one fault allowed')
        assert_eq(faults, 1)

        ch = Issue(P1, 'keys', { amount = 6 })
        later(playTime(ch.puzzle) + 100)
        answer(P1, ch, keysAnswer(ch.puzzle, 3))
        assert_false(Verify(P1, ch.id), 'no fault allowed by default')
    end)
    it('presses faster than a person reacts, late presses and the whole game too fast fail', function()
        local ch = Issue(P1, 'keys', { amount = 5 })
        local a = keysAnswer(ch.puzzle)
        a.presses[2].ms = 10
        a.presses[4].ms = 900
        later(playTime(ch.puzzle) + 100)
        answer(P1, ch, a)
        local passed, faults = Verify(P1, ch.id)
        assert_false(passed)
        assert_eq(faults, 2)

        ch = Issue(P1, 'keys', { amount = 5 })
        later(playTime(ch.puzzle) - 1000)
        answer(P1, ch, keysAnswer(ch.puzzle))
        local _, _, why = Verify(P1, ch.id)
        assert_eq(why, 'too_fast')
    end)
end)

describe('hacking', function()
    local function solve(p, extra)
        local submits = extra or {}
        local t = 3000
        for b = 1, 2 do
            t = t + 2000
            submits[#submits + 1] = { b = b, r = p.blocks[b].row, c = p.blocks[b].col, ms = t }
        end
        return { submits = submits }, t
    end
    it('both codes found in time pass; wrong submits are faults that cost time', function()
        local ch = Issue(P1, 'hacking', { size = 4, seconds = 30 })
        assert_eq(#ch.puzzle.blocks[1].code, 4)
        local a, t = solve(ch.puzzle)
        later(t + 2500)
        answer(P1, ch, a)
        local passed, faults = Verify(P1, ch.id)
        assert_true(passed)
        assert_eq(faults, 0)

        -- three wrong submits cost 5 + 10 + 15 s: a code found at 20 s is too late for 30 s
        ch = Issue(P1, 'hacking', { size = 4, seconds = 30 })
        local p = ch.puzzle
        local wrong = {}
        for i = 1, 3 do wrong[i] = { b = 1, r = p.blocks[1].row, c = p.blocks[1].col + 1, ms = 1000 * i } end
        a = { submits = wrong }
        a.submits[4] = { b = 1, r = p.blocks[1].row, c = p.blocks[1].col, ms = 20000 }
        a.submits[5] = { b = 2, r = p.blocks[2].row, c = p.blocks[2].col, ms = 20500 }
        later(23000)
        answer(P1, ch, a)
        passed, faults = Verify(P1, ch.id)
        assert_false(passed)
        assert_eq(faults, 3)
    end)
    it('one code missing, or both found faster than the cursor can move, fails', function()
        local ch = Issue(P1, 'hacking', {})
        local p = ch.puzzle
        later(10000)
        answer(P1, ch, { submits = { { b = 1, r = p.blocks[1].row, c = p.blocks[1].col, ms = 4000 } } })
        assert_false(Verify(P1, ch.id))

        ch = Issue(P1, 'hacking', {})
        p = ch.puzzle
        later(10000)
        answer(P1, ch, { submits = { { b = 1, r = p.blocks[1].row, c = p.blocks[1].col, ms = 100 }, { b = 2, r = p.blocks[2].row, c = p.blocks[2].col, ms = 150 } } })
        local _, _, why = Verify(P1, ch.id)
        assert_eq(why, 'too_fast')
    end)
end)

describe('lockpick', function()
    it('the push at the hidden angle opens it; another angle or no pins left fails', function()
        local ch = Issue(P1, 'lockpick', { pins = 3 })
        local solve = ch.puzzle.solve
        later(5000)
        answer(P1, ch, { success = true, a = solve + 2, ms = 3000, broken = 1 })
        local passed, faults = Verify(P1, ch.id)
        assert_true(passed)
        assert_eq(faults, 1)

        ch = Issue(P1, 'lockpick', { pins = 3 })
        later(5000)
        answer(P1, ch, { success = true, a = ch.puzzle.solve + 20, ms = 3000, broken = 0 })
        assert_false(Verify(P1, ch.id))

        ch = Issue(P1, 'lockpick', { pins = 3 })
        later(5000)
        answer(P1, ch, { success = true, a = ch.puzzle.solve, ms = 3000, broken = 3 })
        assert_false(Verify(P1, ch.id))
    end)
    it('an opening claimed before it could happen fails', function()
        local ch = Issue(P1, 'lockpick', {})
        answer(P1, ch, { success = true, a = ch.puzzle.solve, ms = 3000, broken = 0 })
        local _, _, why = Verify(P1, ch.id)
        assert_eq(why, 'too_fast')
    end)
end)
