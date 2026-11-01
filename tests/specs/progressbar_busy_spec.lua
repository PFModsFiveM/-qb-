-- progressbar ([qb] copy of the owner's resource), sv_stateBagStrictMode: a bar no longer writes
-- the replicated `inv_busy` itself. It holds pfm-inventory's 'progressbar' action lock through
-- 'qb-inventory:server:setActionBusy' with a time to live of the bar's duration plus a margin
-- (renewed for bars longer than the longest lock), and releases it when the bar ends or is
-- cancelled. The second half plays the client's requests into pfm-inventory's real handler.
load_resource('tests/lua/fivem_mocks.lua')
Config = nil
load_resource('pfm-inventory/config/config.lua')
load_resource('pfm-inventory/config/freshness.lua')
load_resource('pfm-inventory/server/freshness.lua')
load_resource('pfm-inventory/server/main.lua')
load_resource('pfm-inventory/server/functions.lua')

-- ── the progressbar client in its own environment ─────────────────
local toServer, stateWrites, nuiMessages, finished = {}, {}, {}, {}
local clientHandlers, nuiCallbacks, clientExports, threads = {}, {}, {}, {}
local clock = 0               -- GetGameTimer() on the client, in ms

local function bag()
    return setmetatable({}, { __index = { set = function(_, k, v, r) stateWrites[#stateWrites + 1] = { key = k, value = v, replicated = r } end } })
end

local client = {}
client.LocalPlayer = { state = bag() }
client.Entity = function() return { state = bag() } end
client.Player = function() return { state = bag() } end
client.GetGameTimer = function() return clock end
client.TriggerServerEvent = function(name, ...) toServer[#toServer + 1] = { name = name, args = { ... } } end
client.RegisterNetEvent = function(name, fn) clientHandlers[name] = fn end
client.AddEventHandler = client.RegisterNetEvent
client.TriggerEvent = function(name, ...) if clientHandlers[name] then clientHandlers[name](...) end end
client.RegisterNUICallback = function(name, fn) nuiCallbacks[name] = fn end
client.SendNUIMessage = function(msg) nuiMessages[#nuiMessages + 1] = msg end
client.exports = setmetatable({}, { __call = function(_, name, fn) clientExports[name] = fn end })
client.CreateThread = function(fn)
    local co = coroutine.create(fn)
    threads[#threads + 1] = co
    assert(coroutine.resume(co))
end
client.Wait = function() if coroutine.isyieldable() then coroutine.yield() end end
client.Citizen = { CreateThread = client.CreateThread, Wait = client.Wait }
client.IsEntityDead = function() return false end
client.IsControlJustPressed = function() return false end
client.HasAnimDictLoaded = function() return true end
client.HasModelLoaded = function() return true end
client.PlayerPedId = function() return 1 end
client.PlayerId = function() return 0 end
client.vec3 = vec3
-- every other native: a no-op
setmetatable(client, { __index = function(_, k)
    local g = _G[k]
    if g ~= nil and not tostring(k):match('^%u') then return g end
    if type(k) == 'string' and k:match('^%u') then return function() return nil end end
    return g
end })
assert(load(__readfile('progressbar/client.lua'), '@progressbar/client.lua', 't', client))()

--- Runs every live client thread once (one tick).
local function tick()
    for _, co in ipairs(threads) do
        if coroutine.status(co) == 'suspended' then assert(coroutine.resume(co)) end
    end
end

local function bar(duration)
    clientExports.Progress({
        name = 'test', duration = duration, label = 'Testing', useWhileDead = false, canCancel = true,
        controlDisables = {}, animation = {}, prop = {}, propTwo = {},
    }, function(cancelled) finished[#finished + 1] = cancelled end)
end

local function finishBar() nuiCallbacks.FinishAction({}, function() end) end

local function busyCalls()
    local out = {}
    for _, e in ipairs(toServer) do
        if e.name == 'qb-inventory:server:setActionBusy' then
            out[#out + 1] = e.args[1] .. '=' .. tostring(e.args[2]) .. (e.args[3] and ('/' .. e.args[3]) or '')
        end
    end
    return table.concat(out, ' ')
end

local ME = 1

BeforeEach = function()
    Mock.reset()
    -- end any bar a previous test left running (its release is not part of the next test)
    clientHandlers['progressbar:client:cancel']()
    tick()
    toServer, stateWrites, nuiMessages, finished, threads = {}, {}, {}, {}, {}
    clock = clock + 10 * 60 * 60 * 1000
    Mock.players = {}
    Mock.clock = Mock.clock + 100000
    Mock.newPlayer(ME)
    Mock.fireEvent('playerDropped', ME)        -- forget pfm-inventory's busy state of earlier tests
    Player(ME).state.inv_busy = false
    PurgeExpiredBusyLocks()
end

describe('progressbar client', function()
    it('a bar holds the lock for its duration plus a margin, and releases it when it finishes', function()
        bar(5000)
        assert_eq(busyCalls(), 'progressbar=true/15')
        tick()
        finishBar()
        tick()
        assert_eq(busyCalls(), 'progressbar=true/15 progressbar=false')
        assert_eq(finished[1], false, 'the bar finished')
        assert_eq(#stateWrites, 0, 'no state bag written')
        assert_eq(clientExports.isDoingSomething(), false)
    end)

    it('a cancelled bar releases the lock once; a cancel with no bar sends nothing', function()
        bar(8000)
        clientHandlers['progressbar:client:cancel']()
        clientHandlers['progressbar:client:cancel']()
        assert_eq(busyCalls(), 'progressbar=true/18 progressbar=false')
        toServer = {}
        clientHandlers['progressbar:client:cancel']()
        assert_eq(busyCalls(), '', 'nothing held, nothing released')
        assert_eq(#stateWrites, 0)
    end)

    it('a second bar while one runs takes no second lock', function()
        bar(5000)
        bar(5000)
        assert_eq(busyCalls(), 'progressbar=true/15')
        finishBar()
        bar(3000)
        assert_eq(busyCalls(), 'progressbar=true/15 progressbar=false progressbar=true/13')
    end)

    it('a missing or bad duration still gets a short lock (the margin)', function()
        bar(nil)
        finishBar()
        bar(-500)
        finishBar()
        bar(0 / 0)
        finishBar()
        bar(math.huge)
        finishBar()
        assert_eq(busyCalls(), 'progressbar=true/10 progressbar=false progressbar=true/10 progressbar=false progressbar=true/10 progressbar=false progressbar=true/10 progressbar=false')
    end)

    it('the lock is never longer than pfm-inventory accepts; a long bar renews it until it ends', function()
        bar(1200 * 1000)                                   -- 20 minutes
        assert_eq(busyCalls(), 'progressbar=true/600')
        clock = clock + 539 * 1000
        tick()
        assert_eq(busyCalls(), 'progressbar=true/600', 'not yet')
        clock = clock + 1000                               -- 540 s in: 660 s left
        tick()
        assert_eq(busyCalls(), 'progressbar=true/600 progressbar=true/600')
        clock = clock + 540 * 1000                         -- 1080 s in: 120 s left
        tick()
        assert_eq(busyCalls(), 'progressbar=true/600 progressbar=true/600 progressbar=true/130')
        clock = clock + 600 * 1000                         -- past the end, the NUI never finished
        tick()
        assert_eq(busyCalls(), 'progressbar=true/600 progressbar=true/600 progressbar=true/130', 'no renewal past the end')
        finishBar()
        assert_eq(busyCalls(), 'progressbar=true/600 progressbar=true/600 progressbar=true/130 progressbar=false')
    end)

    it('a bar whose renewal comes due after its end is left to run out', function()
        bar(700 * 1000)
        clock = clock + 800 * 1000                         -- the client hitched past the end
        tick()
        assert_eq(busyCalls(), 'progressbar=true/600')
    end)
end)

describe('progressbar with pfm-inventory (the lock really holds)', function()
    local function deliver()
        for _, e in ipairs(toServer) do Mock.fireNet(e.name, ME, table.unpack(e.args)) end
        toServer = {}
    end

    it('the inventory is busy while the bar runs and free after it', function()
        bar(5000)
        deliver()
        assert_eq(Player(ME).state.inv_busy, true)
        finishBar()
        deliver()
        assert_eq(Player(ME).state.inv_busy, false)
    end)

    it('a bar whose client never finishes frees the inventory once its time to live runs out', function()
        bar(5000)
        deliver()
        Mock.clock = Mock.clock + 14
        PurgeExpiredBusyLocks()
        assert_eq(Player(ME).state.inv_busy, true, 'held for the bar and the margin')
        Mock.clock = Mock.clock + 2
        PurgeExpiredBusyLocks()
        assert_eq(Player(ME).state.inv_busy, false, 'ended by the server')
    end)

    it('the longest lock a bar asks for is accepted', function()
        bar(3600 * 1000)
        deliver()
        assert_eq(Player(ME).state.inv_busy, true)
        clientHandlers['progressbar:client:cancel']()
        deliver()
        assert_eq(Player(ME).state.inv_busy, false)
    end)

    it('releasing the bar never clears a lock the server holds', function()
        assert_true(SetBusyLock(ME, 'robbery', true))
        bar(5000)
        finishBar()
        deliver()
        assert_eq(Player(ME).state.inv_busy, true, 'the robbery lock stays')
        SetBusyLock(ME, 'robbery', false)
        assert_eq(Player(ME).state.inv_busy, false)
    end)
end)
