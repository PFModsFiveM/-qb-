-- pf-mechanicjob's progress bar (DoProgress in client/main.lua and client/mechanictools.lua) when it
-- falls back to QBCore.Functions.Progressbar: QBCore is pfm-core's copy, so that is a function
-- reference, and pfm-core's signature is (name, label, duration, useWhileDead, canCancel,
-- disableControls, animation, prop, propTwo, onFinish, onCancel). The finish and cancel functions
-- were passed one place early (as propTwo and onFinish): a finished bar was reported cancelled and
-- a cancelled one never answered, so the wait loop hung. A bar the progressbar resource never
-- answers (it refuses one while the player is dead or busy) counts as cancelled after the bar's
-- time and a margin. Without the progressbar resource pfm-core errors; DoProgress then falls back
-- to its plain wait. ox_lib stays first.
-- The spec runs the real functions, cut out of the client files (they are locals there).
load_resource('tests/lua/fivem_mocks.lua')

local function cut(rel, header)
    local src = __readfile(rel)
    local s = src:find(header, 1, true)
    assert(s, header .. ' not found in ' .. rel)
    local e = src:find('\nend\n', s, true)
    assert(e, 'end of ' .. header .. ' not found in ' .. rel)
    return src:sub(s, e + 4)
end

local clock, waits, pending, bars, oxCalls = 0, 0, nil, {}, 0
local outcome = 'finish'          -- what happens to the bar: 'finish', 'cancel' or 'refused'
local progressbarState = 'started' -- the progressbar resource, as pfm-core sees it

-- the progressbar resource: answers when the bar is done, or halfway when the player cancels; it
-- never answers a bar it refuses (the player is dead or already busy)
local function progress(opts, cb)
    bars[#bars + 1] = opts
    if outcome == 'refused' then return end
    local cancel = outcome == 'cancel'
    pending = { cb = cb, at = clock + (cancel and math.floor(opts.duration / 2) or opts.duration), cancelled = cancel }
end

local function wait(ms)
    waits = waits + 1
    if waits > 20000 then error('DoProgress hung: the wait loop never ended', 0) end
    clock = clock + math.max(1, tonumber(ms) or 0)
    if pending and clock >= pending.at then
        local p = pending
        pending = nil
        p.cb(p.cancelled)
    end
end

-- pfm-core's QBCore.Functions.Progressbar, from pfm-core/client/functions.lua
local coreEnv = setmetatable({
    QBCore = { Functions = {} },
    GetResourceState = function(name) if name == 'progressbar' then return progressbarState end return 'missing' end,
    exports = { progressbar = { Progress = function(_, opts, cb) return Mock.cross(progress, opts, cb) end } },
}, { __index = _G })
assert(load(cut('pfm-core/client/functions.lua', 'function QBCore.Functions.Progressbar('), '@pfm-core/client/functions.lua', 't', coreEnv))()
local coreProgressbar = coreEnv.QBCore.Functions.Progressbar
assert(type(coreProgressbar) == 'function')

local oxStarted = false
local function mechanicEnv()
    local noop = function() end
    return setmetatable({
        -- the resource's QBCore came from GetCoreObject: its functions are function references
        QBCore = { Functions = { Progressbar = Mock.funcref(coreProgressbar) } },
        -- main.lua tries the progressbar export itself before QBCore: the spec hides the resource
        -- from it so that the QBCore branch is the one that runs
        GetResourceState = function(name) if name == 'ox_lib' and oxStarted then return 'started' end return 'missing' end,
        lib = { progressCircle = function() oxCalls = oxCalls + 1 return true end },
        PlayerPedId = function() return 1 end,
        Wait = wait,
        GetGameTimer = function() return clock end,
        ClearPedTasks = noop, ClearPedTasksImmediately = noop, DisableControlAction = noop,
        HasAnimDictLoaded = function() return true end, RequestAnimDict = noop, TaskPlayAnim = noop,
        exports = {},
    }, { __index = _G })
end

local FILES = {
    { rel = '[pfscripts]/pf-mechanicjob/client/main.lua', pre = 'local function resourceActive(name)' },
    { rel = '[pfscripts]/pf-mechanicjob/client/mechanictools.lua' },
}
local DoProgress = {}
for _, f in ipairs(FILES) do
    local chunk = (f.pre and (cut(f.rel, f.pre) .. '\n') or '') .. cut(f.rel, 'local function DoProgress(label, ms, dict, anim)') .. '\nreturn DoProgress'
    DoProgress[f.rel] = assert(load(chunk, '@' .. f.rel, 't', mechanicEnv()))()
end

BeforeEach = function()
    clock, waits, pending, bars, oxCalls = 0, 0, nil, {}, 0
    outcome, progressbarState, oxStarted = 'finish', 'started', false
end

for _, f in ipairs(FILES) do
    local name = f.rel:match('client/.*$')
    describe('pf-mechanicjob ' .. name .. ' DoProgress through QBCore.Functions.Progressbar', function()
        it('a finished bar reports the work done', function()
            local ok, done = pcall(DoProgress[f.rel], 'Installing...', 4000, 'mini@repair', 'fixing_a_ped')
            assert_true(ok, tostring(done))
            assert_eq(done, true)
            assert_eq(#bars, 1)
            assert_eq(bars[1].duration, 4000)
            assert_eq(bars[1].animation.animDict, 'mini@repair')
            assert_false(Mock.isFuncref(bars[1].prop) or Mock.isFuncref(bars[1].propTwo), 'no callback in the prop slots')
        end)
        it('a cancelled bar reports cancelled when the player cancels, without waiting on', function()
            outcome = 'cancel'
            local ok, done = pcall(DoProgress[f.rel], 'Installing...', 4000)
            assert_true(ok, tostring(done))
            assert_eq(done, false)
            assert_true(clock <= 2000 + 25, 'returned at the cancel (t=2000), not at ' .. clock)
        end)
        it('a bar the progressbar refuses (it never answers) counts as cancelled and does not block', function()
            outcome = 'refused'
            local ok, done = pcall(DoProgress[f.rel], 'Installing...', 4000)
            assert_true(ok, tostring(done))
            assert_eq(done, false)
            assert_true(clock >= 4000 and clock <= 4000 + 5000 + 25, 'gave up after the bar time and a margin, at ' .. clock)
        end)
        it('without the progressbar resource it falls back to the plain wait', function()
            progressbarState = 'missing' -- pfm-core's Progressbar errors
            local ok, done = pcall(DoProgress[f.rel], 'Installing...', 3000)
            assert_true(ok, tostring(done))
            assert_eq(done, true)
            assert_true(clock >= 3000, 'waited the full time')
            assert_eq(#bars, 0)
        end)
        it('ox_lib comes first', function()
            oxStarted = true
            assert_eq(DoProgress[f.rel]('Installing...', 3000), true)
            assert_eq(oxCalls, 1)
            assert_eq(#bars, 0)
        end)
    end)
end
