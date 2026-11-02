--[[ Server challenges: API note (pfm-minigames)

A challenge is a minigame the server generates, the client plays and the server judges. Use one
whenever a minigame result unlocks something (a door, a car, loot, a hack): a client's own
true/false proves nothing.

Server, from your resource:
  local ch, why = exports['pfm-minigames']:IssueChallenge(src, kind, opts)
    kind  'skillbar' | 'keys' (alias 'keyminigame') | 'hacking' | 'lockpick'
    opts  skillbar  { difficulty = 'easy'|'medium'|'hard', keys = '1234' }
          keys      { amount = 10 }               3..30 arrows
          hacking   { size = 5, seconds = 30 }    block size 2..10, 5..120 s
          lockpick  { pins = 5 }                  1..10 tries
          any kind  { maxFaults = n }  passing also needs faults <= n (keys: default 0)
                    { ttl = ms }       time to answer (default: what the puzzle needs + 20 s)
                    { tag = 'res:thing' } up to 64 chars, handed back in the answered event
    -> ch = { id, kind, puzzle, expiresIn = ms }: send it unchanged to that player's client.
       nil, 'invalid_player' | 'unknown_kind' otherwise.
  local passed, faults, reason = exports['pfm-minigames']:Verify(src, id)
    The verdict, given once (the challenge is gone afterwards: 'unknown'). Only the resource that
    issued it may verify it ('wrong_resource'). Verified before any answer: false, 0, 'pending'
    (also used up). Other reasons: 'expired', 'wrong_player', and the check's own ('miss',
    'too_fast', 'quit', 'faults', ...). faults = wrong keys, misses, wrong submits or broken pins.
  exports['pfm-minigames']:Cancel(src, id)   drops one of your challenges nobody will finish.
  AddEventHandler('pfm-minigames:server:answered', function(info) end)
    info = { id, src, kind, passed, faults, reason, tag, owner } once an answer is judged, for a
    resource that acts without a finish event of its own: it still calls Verify to use it up.

Client (that player's):
  local passed, faults = exports['pfm-minigames']:PlayChallenge(ch)
    Plays it, sends the answer (net event 'pfm-minigames:server:answer', one per id) and returns
    the server's verdict (false after 5 s without one). Net events from one client arrive in
    order, so a finish event sent after this returns finds the answer already judged.

Typical flow (pfm-doorlock startPick/finishPick, pfm-vehiclekeys): server start event (position,
items, cooldown; records the attempt) -> IssueChallenge -> ch to the client -> PlayChallenge ->
client finish event -> Verify -> act. Roll item breakage and rewards on the server, also when no
finish ever comes (time the attempt out).

The check: the answer must fit the puzzle (keys, zones, positions, angle) and server time (no more
play time than has passed since the challenge was issued, none faster than the puzzle can be
played, nothing after it expired). Limit: the puzzle reaches the client, so a modified client can
still solve it automatically; the timing checks hold it to human speed. The old client exports
(Skillbar, KeyMinigame, Hacking, Lockpick, ...) still work, but their result is only the client's
word.
]]

local MAX_OPEN_PER_PLAYER = 6
local VERDICT_TTL = 60000      -- an answered challenge waits this long for Verify
local EXTRA_TTL = 20000        -- time to answer on top of what the puzzle needs (network, UI)
local SLACK_MS = 250           -- NUI timers and the server clock are not in step to the ms
local MAX_ENTRIES = 200        -- presses / submits read from one answer

local Challenges = {} -- [id] = { id, src, kind, puzzle, issuedAt, expiresAt, owner, tag, maxFaults, result }
local counter = 0

local function now() return GetGameTimer() end

local function int(v, lo, hi, default)
    v = math.tointeger(tonumber(v) or default) or default
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function num(v)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge then return nil end
    return v
end

local HEX = '0123456789ABCDEF'
local function hexCode(len)
    local out = {}
    for i = 1, len do
        local k = math.random(1, 16)
        out[i] = HEX:sub(k, k)
    end
    return table.concat(out)
end

-- ── skillbar ─────────────────────────────────────────────────────
-- Mirrors html/js/skillbar.js: an indicator turns at speed*10 degrees a second; each round the
-- player presses the shown key while it is inside the zone (start..start+size radians).
local SKILLBAR = {
    easy = { zone = 10, speed = 15, rounds = 3 },
    medium = { zone = 8, speed = 25, rounds = 4 },
    hard = { zone = 6, speed = 35, rounds = 5 },
}
local ZONE_TOLERANCE_DEG = 0.5

local function skillbarPuzzle(opts)
    local difficulty = SKILLBAR[opts.difficulty] and opts.difficulty or 'easy'
    local s = SKILLBAR[difficulty]
    local keys = '1234'
    if type(opts.keys) == 'string' and #opts.keys >= 1 and #opts.keys <= 10 and opts.keys:match('^%w+$') then
        keys = opts.keys:lower()
    end
    local rounds = {}
    for i = 1, s.rounds do
        local k = math.random(1, #keys)
        rounds[i] = { key = keys:sub(k, k), start = math.random(20, 40) / 10, size = s.zone / 10 }
    end
    return { difficulty = difficulty, speed = s.speed, keys = keys, rounds = rounds }
end

local function skillbarTtl(p)
    return math.ceil(#p.rounds * 360 / (p.speed * 10) * 1000)
end

-- answer.presses[i] = { k = key pressed, ms = indicator time in that round when it was pressed }
local function skillbarCheck(ch, answer, elapsed)
    local p = ch.puzzle
    local presses = answer.presses
    if type(presses) ~= 'table' then return false, 1, 'no_presses' end
    local degPerMs = p.speed * 10 / 1000
    local total = 0
    for i, round in ipairs(p.rounds) do
        local press = presses[i]
        if type(press) ~= 'table' then return false, 1, 'missed' end
        local ms = num(press.ms)
        if not ms or ms < 0 or ms > 60000 then return false, 1, 'bad_time' end
        total = total + ms
        local deg = ms * degPerMs
        local from, to = math.deg(round.start), math.deg(round.start + round.size)
        if press.k ~= round.key or deg < from - ZONE_TOLERANCE_DEG or deg > to + ZONE_TOLERANCE_DEG then
            return false, 1, 'miss'
        end
    end
    -- every round had to be played out in real time
    if total > elapsed + SLACK_MS then return false, 0, 'too_fast' end
    return true, 0
end

-- ── keys (the arrow-key minigame) ────────────────────────────────
-- Mirrors html/js/keyminigame.js: after `lead` ms one arrow lights per `step` ms and must be
-- pressed within `window` ms.
local ARROWS = { 'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight' }
local KEYS_LEAD, KEYS_STEP, KEYS_WINDOW = 1000, 1500, 500
local MIN_REACTION_MS = 80 -- faster than any person reacts to a randomly lit key

local function keysPuzzle(opts)
    local amount = int(opts.amount, 3, 30, 10)
    local pattern = {}
    for i = 1, amount do pattern[i] = ARROWS[math.random(1, #ARROWS)] end
    return { amount = amount, pattern = pattern, lead = KEYS_LEAD, step = KEYS_STEP, window = KEYS_WINDOW }
end

local function keysTtl(p)
    return p.lead + p.amount * p.step
end

-- answer.presses = { { s = step (1-based), k = key, ms = time after the key lit }, ... }, first press per step
local function keysCheck(ch, answer, elapsed)
    local p = ch.puzzle
    local first = {}
    local presses = type(answer.presses) == 'table' and answer.presses or {}
    for i, press in ipairs(presses) do
        if i > MAX_ENTRIES then break end
        local s = type(press) == 'table' and math.tointeger(num(press.s) or -1)
        if s and s >= 1 and s <= p.amount and not first[s] then first[s] = press end
    end
    local faults = 0
    for i = 1, p.amount do
        local press = first[i]
        local ms = press and num(press.ms)
        if not press or press.k ~= p.pattern[i] or not ms or ms < MIN_REACTION_MS or ms > p.window + 100 then
            faults = faults + 1
        end
    end
    if answer.quit == true then return false, faults, 'quit' end
    -- the last key is judged after its window closes
    local minimum = p.lead + (p.amount - 1) * p.step + p.window
    if elapsed + SLACK_MS < minimum then return false, faults, 'too_fast' end
    return true, faults
end

-- ── hacking ──────────────────────────────────────────────────────
-- Mirrors html/js/hacking.js: two codes hidden in a 9x18 grid; the player moves a cursor onto
-- each (wasd and arrows) and submits it (space / enter). A wrong submit costs penalty*mistakes ms.
local HACK_ROWS, HACK_COLS, HACK_PENALTY = 9, 18, 5000
local MS_PER_MOVE = 25    -- key auto-repeat is about 30 a second
local MIN_HACK_MS = 1000  -- nobody reads the grid and finds both codes faster

local function hackingPuzzle(opts)
    local size = int(opts.size, 2, 10, 5)
    local seconds = int(opts.seconds, 5, 120, 30)
    local b1 = { row = math.random(1, HACK_ROWS), col = math.random(1, HACK_COLS - size), code = hexCode(size) }
    local b2
    repeat
        b2 = { row = math.random(1, HACK_ROWS), col = math.random(1, HACK_COLS - size), code = hexCode(size) }
    until b1.row ~= b2.row or b1.col + size < b2.col or b1.col > b2.col + size
    return { size = size, seconds = seconds, penalty = HACK_PENALTY, blocks = { b1, b2 },
        cursors = { { row = 1, col = 1 }, { row = 1, col = HACK_COLS + 1 - size } } }
end

local function hackingTtl(p)
    return p.seconds * 1000 + 2000 -- the game waits 2 s on "Success" before it reports
end

-- answer.submits = { { b = 1|2, r = row, c = col, ms = since start }, ... } in the order made
local function hackingCheck(ch, answer, elapsed)
    local p = ch.puzzle
    if answer.quit == true then return false, 0, 'quit' end
    local submits = type(answer.submits) == 'table' and answer.submits or {}
    local solved, mistakes, penalty, lastMs = {}, 0, 0, 0
    for i, sub in ipairs(submits) do
        if i > MAX_ENTRIES then break end
        if type(sub) ~= 'table' then return false, mistakes, 'bad_answer' end
        local b, r, c, ms = math.tointeger(num(sub.b) or 0), num(sub.r), num(sub.c), num(sub.ms)
        if (b ~= 1 and b ~= 2) or not r or not c or not ms or ms < lastMs then return false, mistakes, 'bad_answer' end
        lastMs = ms
        if not solved[b] then
            local block = p.blocks[b]
            if r == block.row and c == block.col then
                -- the clock (minus penalties so far) had to still be running
                if ms > p.seconds * 1000 - penalty + SLACK_MS then return false, mistakes, 'late' end
                solved[b] = ms
            else
                mistakes = mistakes + 1
                penalty = penalty + mistakes * p.penalty
            end
        end
    end
    if not (solved[1] and solved[2]) then return false, mistakes, 'unsolved' end
    local last = math.max(solved[1], solved[2])
    local moves = 0
    for b = 1, 2 do
        moves = moves + math.abs(p.blocks[b].row - p.cursors[b].row) + math.abs(p.blocks[b].col - p.cursors[b].col)
    end
    if last < math.max(MIN_HACK_MS, moves * MS_PER_MOVE) then return false, mistakes, 'too_fast' end
    if last > elapsed + SLACK_MS then return false, mistakes, 'too_fast' end
    return true, mistakes
end

-- ── lockpick (the pin lockpick) ──────────────────────────────────
-- Mirrors html/js/lockpick.js: the cylinder turns fully only when it is pushed with the pin within
-- `padding` degrees of the hidden angle; a pushed wrong angle breaks pins.
local PICK_PADDING = 4
local MIN_PICK_MS = 400 -- the cylinder alone takes about this long to turn at high frame rates

local function lockpickPuzzle(opts)
    local pins = int(opts.pins, 1, 10, 5)
    return { pins = pins, solve = math.floor((math.random() * 181 - 90) * 100 + 0.5) / 100, padding = PICK_PADDING }
end

-- answer = { success = true, a = pin angle of the push that opened it, ms = since start, broken = pins broken }
local function lockpickCheck(ch, answer, elapsed)
    local p = ch.puzzle
    local broken = int(answer.broken, 0, 100, 0)
    if answer.quit == true then return false, broken, 'quit' end
    if answer.success ~= true or broken >= p.pins then return false, broken, 'failed' end
    local a, ms = num(answer.a), num(answer.ms)
    if not a or not ms then return false, broken, 'bad_answer' end
    if math.abs(a - p.solve) - p.padding > 0.5 then return false, broken, 'miss' end
    if ms < MIN_PICK_MS or ms > elapsed + SLACK_MS then return false, broken, 'too_fast' end
    return true, broken
end

local KINDS = {
    skillbar = { generate = skillbarPuzzle, ttl = skillbarTtl, check = skillbarCheck },
    keys = { generate = keysPuzzle, ttl = keysTtl, check = keysCheck, maxFaults = 0 },
    hacking = { generate = hackingPuzzle, ttl = hackingTtl, check = hackingCheck },
    lockpick = { generate = lockpickPuzzle, ttl = function() return 100000 end, check = lockpickCheck },
}
local ALIASES = { keyminigame = 'keys' }

-- ── store ────────────────────────────────────────────────────────

local function sweep()
    local t = now()
    for id, ch in pairs(Challenges) do
        if t > ch.expiresAt then Challenges[id] = nil end
    end
end

-- keeps at most MAX_OPEN_PER_PLAYER per player (the oldest goes)
local function trimPlayer(src)
    local mine = {}
    for _, ch in pairs(Challenges) do
        if ch.src == src then mine[#mine + 1] = ch end
    end
    if #mine < MAX_OPEN_PER_PLAYER then return end
    table.sort(mine, function(a, b) return a.issuedAt < b.issuedAt end)
    for i = 1, #mine - MAX_OPEN_PER_PLAYER + 1 do Challenges[mine[i].id] = nil end
end

local function newId()
    counter = counter + 1
    return ('%d-%06x%06x'):format(counter, math.random(0, 0xFFFFFF), math.random(0, 0xFFFFFF))
end

local function deepCopy(v)
    if type(v) ~= 'table' then return v end
    local out = {}
    for k, val in pairs(v) do out[k] = deepCopy(val) end
    return out
end

local function IssueChallenge(src, kind, opts)
    src = tonumber(src)
    if not src or src <= 0 or not GetPlayerName(src) then return nil, 'invalid_player' end
    kind = ALIASES[kind] or kind
    local def = type(kind) == 'string' and KINDS[kind]
    if not def then return nil, 'unknown_kind' end
    opts = type(opts) == 'table' and opts or {}

    local puzzle = def.generate(opts)
    local ttl = def.ttl(puzzle) + EXTRA_TTL
    if opts.ttl ~= nil then ttl = int(opts.ttl, 5000, 600000, ttl) end
    local maxFaults = opts.maxFaults ~= nil and int(opts.maxFaults, 0, 1000, 0) or def.maxFaults

    sweep()
    trimPlayer(src)
    local t = now()
    local id = newId()
    Challenges[id] = {
        id = id, src = src, kind = kind, puzzle = puzzle, issuedAt = t, expiresAt = t + ttl,
        owner = GetInvokingResource(), tag = type(opts.tag) == 'string' and opts.tag:sub(1, 64) or nil,
        maxFaults = maxFaults,
    }
    return { id = id, kind = kind, puzzle = deepCopy(puzzle), expiresIn = ttl }
end

local function Verify(src, id)
    local ch = type(id) == 'string' and Challenges[id] or nil
    if not ch then return false, 0, 'unknown' end
    if ch.src ~= tonumber(src) then return false, 0, 'wrong_player' end
    local caller = GetInvokingResource()
    if ch.owner and caller and ch.owner ~= caller then return false, 0, 'wrong_resource' end
    Challenges[id] = nil -- one verdict per challenge
    if not ch.result then
        if now() > ch.expiresAt then return false, 0, 'expired' end
        return false, 0, 'pending'
    end
    return ch.result.passed, ch.result.faults, ch.result.reason
end

local function Cancel(src, id)
    local ch = type(id) == 'string' and Challenges[id] or nil
    if not ch or ch.src ~= tonumber(src) then return false end
    local caller = GetInvokingResource()
    if ch.owner and caller and ch.owner ~= caller then return false end -- not another resource's
    Challenges[id] = nil
    return true
end

exports('IssueChallenge', IssueChallenge)
exports('Verify', Verify)
exports('Cancel', Cancel)

-- The client's answer: judged once, here, against the stored puzzle and the server clock.
RegisterNetEvent('pfm-minigames:server:answer', function(id, answer)
    local src = tonumber(source)
    if not src or type(id) ~= 'string' or #id > 48 then return end
    local ch = Challenges[id]
    if not ch or ch.src ~= src or ch.result then return end -- one answer per id

    local t = now()
    local result
    if t > ch.expiresAt then
        result = { passed = false, faults = 0, reason = 'expired' }
    elseif type(answer) ~= 'table' then
        result = { passed = false, faults = 0, reason = 'bad_answer' }
    else
        local ok, passed, faults, reason = pcall(KINDS[ch.kind].check, ch, answer, t - ch.issuedAt)
        if not ok then
            result = { passed = false, faults = 0, reason = 'bad_answer' }
        else
            faults = math.tointeger(tonumber(faults) or 0) or 0
            passed = passed == true
            if passed and ch.maxFaults and faults > ch.maxFaults then passed, reason = false, 'faults' end
            result = { passed = passed, faults = faults, reason = reason }
        end
    end
    ch.result = result
    ch.expiresAt = t + VERDICT_TTL
    TriggerClientEvent('pfm-minigames:client:verdict', src, id, result.passed, result.faults)
    -- server-local only (no client can raise it): lets the issuer act without a finish event
    TriggerEvent('pfm-minigames:server:answered', {
        id = id, src = src, kind = ch.kind, passed = result.passed, faults = result.faults,
        reason = result.reason, tag = ch.tag, owner = ch.owner,
    })
end)

AddEventHandler('playerDropped', function()
    local src = tonumber(source)
    for id, ch in pairs(Challenges) do
        if ch.src == src then Challenges[id] = nil end
    end
end)

CreateThread(function()
    while true do
        Wait(60000)
        sweep()
    end
end)
