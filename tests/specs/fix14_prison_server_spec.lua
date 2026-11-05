-- pfm-prison on the server (batch 14: X-2, PRISON-01, POL-2, X-3, X-8, prison gates):
--   * the sentence counts down on the server, only while the inmate is inside the walls; a client
--     cannot lower it (the old SetJailStatus(1) then (0) walk-out) and gets no items back early;
--   * items are stored and cleared in one step by the server when an officer jails (no client
--     request, no wait between the copy and the clear), and come back once on release;
--   * outside the walls is an escape only through a gate hacked open, seen inside just before and at
--     a plausible speed; a teleport or noclip out is taken back to a cell;
--   * gate hacks: server-checked position, items (gatecrack used up), ticket timing and the
--     pfm-minigames verdict; the server opens the door through pfm-doorlock; a failed hack locks
--     down once per window; no client can raise lockdowns, gate hits or the alarm;
--   * prison work: the server gives the spot, checks it and decides the time cut.
load_resource('tests/lua/ledger_env.lua')
QBCore = QBCoreMock
vec2 = vector2

local inv = { adds = {}, removes = {}, clears = 0, has = {} }
Mock.exportsByResource['pfm-inventory'] = {
    ClearInventory = function(_, src) inv.clears = inv.clears + 1 Mock.players[src].PlayerData.items = {} end,
    AddItem = function(_, src, name, amount, slot, info)
        inv.adds[#inv.adds + 1] = { src = src, name = name, amount = amount, info = info }
        local items = Mock.players[src].PlayerData.items
        items[#items + 1] = { name = name, amount = amount, info = info }
        return true
    end,
    RemoveItem = function(_, src, name, amount) inv.removes[#inv.removes + 1] = { src = src, name = name } return true end,
    HasItem = function(_, src, name) return inv.has[name] == true end,
}
local challenges = { verdict = true, issued = 0, verified = {} }
Mock.exportsByResource['pfm-minigames'] = {
    IssueChallenge = function(_, src, kind, opts)
        challenges.issued = challenges.issued + 1
        return { id = 'ch' .. challenges.issued, kind = kind, puzzle = {}, expiresIn = 60000 }
    end,
    Verify = function(_, src, id) challenges.verified[#challenges.verified + 1] = id return challenges.verdict end,
    Cancel = function() end,
}
local grants = {}
Mock.exportsByResource['pfm-doorlock'] = {
    GrantDoorAccess = function(_, src, door) grants[#grants + 1] = { src = src, door = door } return true end,
}
local doorChanges = {}
local Emits = {}
Mock.exportsByResource['pf-services'] = {
    Emit = function(_, kind, data, opts) Emits[#Emits + 1] = { kind = kind, data = data, opts = opts or {} } return #Emits end,
}
local teleports = {}
function SetEntityCoords(ped, x, y, z) teleports[#teleports + 1] = { ped = ped, x = x, y = y } end

LedgerEnv.load('pfm-prison', { 'pfm-prison/config.lua', 'pfm-prison/server/main.lua' })
Mock.eventHandlers['qb-doorlock:server:updateState'] = function(door, locked, _, _, unlockAnyway, _, _, by)
    doorChanges[#doorChanges + 1] = { door = door, locked = locked, unlockAnyway = unlockAnyway, by = by }
end

local INMATE, OTHER, COP = 1, 2, 3
local MIDDLE = Config.Locations['middle']
local function at(dx, dy) return vector3(MIDDLE.x + dx, MIDDLE.y + dy, MIDDLE.z) end
local GATE = Config.Gates[1].coords
local function meta(src) return Mock.players[src].PlayerData.metadata end
local function events(name, target)
    local out = {}
    for _, e in ipairs(Mock.clientEventsNamed(name)) do if target == nil or e.target == target then out[#out + 1] = e end end
    return out
end
local function jail(src, minutes)
    Mock.invokingResource = 'pfm-policejob'
    local ok, err = Mock.selfExport('JailPlayer')(src, minutes, { officer = COP })
    Mock.invokingResource = nil
    return ok, err
end
local function release(src)
    Mock.invokingResource = 'pfm-policejob'
    local ok, err = Mock.selfExport('ReleasePlayer')(src, 'unjail')
    Mock.invokingResource = nil
    return ok, err
end
local function advance(seconds) Mock.clock = Mock.clock + seconds end
local function minuteTicks(n) for _ = 1, n do advance(60) PFPrison.MinuteTick() end end

local function newInmate(src, cid)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.charinfo = { firstname = 'John', lastname = 'Escape' .. src }
    p.PlayerData.money = { cash = 0, bank = 0 }
    p.PlayerData.job = { name = 'mechanic', onduty = true }
    p.SetJobDuty = function(on) p.PlayerData.job.onduty = on end
    p.Functions.SetJobDuty = p.SetJobDuty
    p.SetJob = function(name) p.PlayerData.job = { name = name } end
    p.Functions.SetJob = p.SetJob
    p.PlayerData.items = { [1] = { name = 'goldbar', amount = 3, slot = 1 }, [2] = { name = 'weapon_pistol', amount = 1, slot = 2, info = { serial = 'S1' } } }
    p.PlayerData.metadata.injail = 0
    return p
end

BeforeEach = function()
    PFPrison.EndAlarm()
    for _, src in ipairs({ 1, 2, 3 }) do if Mock.players[src] then Mock.fireEvent('playerDropped', src) end end
    Mock.reset()
    LedgerEnv.reset()
    advance(5000) -- past any window an earlier test opened
    Mock.players, Mock.coords = {}, {}
    inv.adds, inv.removes, inv.clears, inv.has = {}, {}, 0, { gatecrack = true, electronickit = true }
    challenges.verdict, challenges.verified = true, {}
    grants, doorChanges, Emits, teleports = {}, {}, {}, {}
    newInmate(INMATE, 'INMATECID')
    newInmate(OTHER, 'OTHERCID')
    local cop = Mock.newPlayer(COP, 'COPCID')
    cop.PlayerData.job = { name = 'police', type = 'leo', onduty = true }
    Mock.coords[INMATE] = at(0, 0)
    Mock.coords[OTHER] = at(5, 0)
    Mock.coords[COP] = vector3(0, 0, 0)
end

describe('jailing (X-3: items moved by the server in one step)', function()
    it('stores the items, clears the inventory and pays the jail money once per sentence', function()
        assert_true(jail(INMATE, 30))
        assert_eq(meta(INMATE).injail, 30)
        assert_eq(next(Mock.players[INMATE].PlayerData.items), nil)
        local stored = meta(INMATE).jailitems
        assert_eq(#stored, 2)
        assert_eq(Mock.players[INMATE].PlayerData.money.cash, 80)
        -- owner decision D1 (batch 16): the job is kept, duty is not
        assert_eq(Mock.players[INMATE].PlayerData.job.name, 'mechanic')
        assert_eq(Mock.players[INMATE].PlayerData.job.onduty, false)
        assert_eq(#events('prison:client:Enter', INMATE), 1)
        -- jailed again while serving: no second copy, no second jail money
        assert_true(jail(INMATE, 40))
        assert_eq(#meta(INMATE).jailitems, 2)
        assert_eq(Mock.players[INMATE].PlayerData.money.cash, 80)
        assert_eq(meta(INMATE).injail, 40)
    end)
    it('no client can save, return or reset its items, or set its time', function()
        for _, name in ipairs({ 'prison:server:SaveJailItems', 'prison:server:GiveJailItems', 'prison:server:ResetJailItems',
            'prison:server:SetJailStatus', 'prison:server:CheckChance' }) do
            assert_eq(Mock.netHandlers[name], nil, name)
        end
    end)
    it('a move during a wait cannot duplicate items: there is no wait between the copy and the clear', function()
        -- anything that yields here would let the inmate drop an item before the clear
        local realWait = Wait
        local moved = false
        Wait = function()
            local items = Mock.players[INMATE].PlayerData.items
            if items[1] then items[1] = nil moved = true end
        end
        jail(INMATE, 10)
        Wait = realWait
        assert_false(moved)
        release(INMATE)
        local gold = 0
        for _, a in ipairs(inv.adds) do if a.name == 'goldbar' then gold = gold + a.amount end end
        assert_eq(gold, 3)
    end)
    it('the inventory not answering refuses the jailing and stores nothing', function()
        local clear = Mock.exportsByResource['pfm-inventory'].ClearInventory
        Mock.exportsByResource['pfm-inventory'].ClearInventory = function() error('pfm-inventory stopped') end
        local ok, err = jail(INMATE, 10)
        Mock.exportsByResource['pfm-inventory'].ClearInventory = clear
        assert_false(ok)
        assert_eq(err, 'inventory_unavailable')
        assert_eq(meta(INMATE).injail, 0)
        assert_eq(#meta(INMATE).jailitems, 0)
    end)
    it('only allowlisted resources may jail or release', function()
        Mock.invokingResource = 'some-resource'
        local ok, err = Mock.selfExport('JailPlayer')(INMATE, 10)
        Mock.invokingResource = nil
        assert_false(ok)
        assert_eq(err, 'not_allowed')
        assert_eq(meta(INMATE).injail, 0)
    end)
end)

describe('the sentence (X-2, PRISON-01: counted down by the server)', function()
    it('counts down a minute per minute inside the walls and releases with the items at 0', function()
        jail(INMATE, 3)
        minuteTicks(2)
        assert_eq(meta(INMATE).injail, 1)
        assert_eq(#inv.adds, 0)
        minuteTicks(1)
        assert_eq(meta(INMATE).injail, 0)
        assert_eq(meta(INMATE).jailid, nil)
        assert_eq(#inv.adds, 2)
        assert_eq(#events('prison:client:Released', INMATE), 1)
        minuteTicks(2) -- released once
        assert_eq(#inv.adds, 2)
    end)
    it('time outside the walls does not count', function()
        jail(INMATE, 5)
        Mock.coords[INMATE] = at(400, 0)
        minuteTicks(3)
        assert_eq(meta(INMATE).injail, 5)
    end)
    it('a client cannot drop its time to 1 then 0 and walk out with its items', function()
        jail(INMATE, 1440)
        -- the old client path: these events no longer exist, and nothing else lowers the time
        assert_eq(Mock.netHandlers['prison:server:SetJailStatus'], nil)
        Mock.fireNet('prison:server:RequestState', INMATE)
        Mock.fireNet('prison:server:JobDone', INMATE, 1)
        assert_eq(meta(INMATE).injail, 1440)
        assert_eq(#inv.adds, 0)
    end)
    it('an officer\'s unjail releases at once, items back once', function()
        jail(INMATE, 60)
        assert_true(release(INMATE))
        assert_eq(meta(INMATE).injail, 0)
        assert_eq(#inv.adds, 2)
        local ok, err = release(INMATE)
        assert_false(ok)
        assert_eq(err, 'not_jailed')
        assert_eq(#inv.adds, 2)
    end)
    it('a sentence from before this change (no jail id, items stored by slot) is served and released', function()
        local m = meta(INMATE)
        m.injail, m.jailid = 2, nil
        m.jailitems = { [3] = { name = 'goldbar', amount = 2, slot = 3 }, [7] = { name = 'lockpick', amount = 1, slot = 7 } }
        Mock.players[INMATE].PlayerData.items = {}
        Mock.eventHandlers['QBCore:Server:PlayerLoaded'](Mock.pack(Mock.players[INMATE]))
        minuteTicks(2)
        assert_eq(meta(INMATE).injail, 0)
        assert_eq(#inv.adds, 2)
        assert_eq(#events('prison:client:Released', INMATE), 1)
    end)
    it('belongings left from an old release are given back at the next load', function()
        local m = meta(INMATE)
        m.injail, m.jailid = 0, nil
        m.jailitems = { [1] = { name = 'goldbar', amount = 2, slot = 1 } }
        Mock.eventHandlers['QBCore:Server:PlayerLoaded'](Mock.pack(Mock.players[INMATE]))
        assert_eq(#inv.adds, 1)
        assert_eq(next(meta(INMATE).jailitems), nil)
    end)
    it('a relog keeps serving: the countdown goes on after the load', function()
        jail(INMATE, 4)
        Mock.fireEvent('playerDropped', INMATE)
        minuteTicks(2)
        assert_eq(meta(INMATE).injail, 4)                 -- offline: nothing counted
        Mock.eventHandlers['QBCore:Server:PlayerLoaded'](Mock.pack(Mock.players[INMATE]))
        assert_eq(#events('prison:client:SetJob', INMATE), 1)
        minuteTicks(1)
        assert_eq(meta(INMATE).injail, 3)
    end)
end)

describe('prison work (X-2: time cuts on the server)', function()
    local function jobOf(src)
        local e = events('prison:client:Enter', src)
        local last = e[#e]
        return last.args[2], last.args[3]
    end
    it('is checked at the given spot, not too fast, and the server decides the cut', function()
        jail(INMATE, 100)
        local job, loc = jobOf(INMATE)
        local spot = Config.Locations.jobs[job][loc].coords
        local realRandom = math.random
        math.random = function(a, b) if a == 1 and b == 100 then return 1 end return a end -- always cut by the smallest
        Mock.coords[INMATE] = vector3(spot.x, spot.y, spot.z)
        Mock.fireNet('prison:server:JobDone', INMATE, loc)        -- too soon after it was given
        assert_eq(meta(INMATE).injail, 100)
        advance(60)                                               -- walked there (batch 16: travel time counts)
        Mock.fireNet('prison:server:JobDone', INMATE, loc + 100)  -- another spot
        Mock.coords[INMATE] = at(0, 0)
        Mock.fireNet('prison:server:JobDone', INMATE, loc)        -- not at the spot
        assert_eq(meta(INMATE).injail, 100)
        Mock.coords[INMATE] = vector3(spot.x, spot.y, spot.z)
        PFPrison.SampleTick()                                     -- the server sees them at the spot
        Mock.fireNet('prison:server:JobDone', INMATE, loc)        -- but not long enough yet
        assert_eq(meta(INMATE).injail, 100)
        advance(4)
        PFPrison.SampleTick()
        Mock.fireNet('prison:server:JobDone', INMATE, loc)
        math.random = realRandom
        assert_eq(meta(INMATE).injail, 99)
        local nextJob = events('prison:client:SetJob', INMATE)
        assert_eq(#nextJob, 1)
        assert_true(nextJob[1].args[2] ~= loc)
        Mock.fireNet('prison:server:JobDone', INMATE, loc)        -- the same spot again: refused
        assert_eq(meta(INMATE).injail, 99)
    end)
end)

describe('escapes (POL-2)', function()
    local function hackGate(src)
        Mock.coords[src] = GATE
        Mock.fireNet('prison:server:StartGateHack', src, 1)
        local start = events('prison:client:GateHackStart', src)
        assert_eq(#start, 1, 'hack started')
        advance(6)
        Mock.fireNet('prison:server:GateHackResult', src, start[1].args[2], true)
    end
    local function sampleAt(src, pos, seconds)
        Mock.coords[src] = pos
        advance(seconds or 2)
        PFPrison.SampleTick()
    end
    local function beyondGate(metres)
        local dx, dy = GATE.x - MIDDLE.x, GATE.y - MIDDLE.y
        local len = math.sqrt(dx * dx + dy * dy)
        return vector3(GATE.x + dx / len * metres, GATE.y + dy / len * metres, GATE.z)
    end

    it('teleporting or noclipping out without a breach takes the inmate back to a cell', function()
        jail(INMATE, 30)
        advance(30)                                    -- past the grace after being brought in
        sampleAt(INMATE, at(10, 0))
        sampleAt(INMATE, at(800, 0))                   -- far outside, no breached gate
        assert_eq(meta(INMATE).injail, 30)
        assert_eq(#Emits, 0)
        assert_eq(#events('prison:client:Escaped', INMATE), 0)
        local back = events('prison:client:Enter', INMATE)
        assert_eq(#back, 2)
        assert_eq(back[2].args[1], 30)
        assert_eq(back[2].args[4], true)
        assert_eq(#teleports, 1)
        assert_eq(#meta(INMATE).jailitems, 2)          -- belongings kept for the release
    end)
    it('a respawn or move outside by another resource is not an escape', function()
        jail(INMATE, 30)
        advance(30)
        sampleAt(INMATE, at(0, 0))
        sampleAt(INMATE, vector3(300, -600, 40), 10)  -- a hospital far away
        assert_eq(meta(INMATE).injail, 30)
        assert_eq(#Emits, 0)
    end)
    it('through a hacked gate, seen inside just before, at running speed: an escape', function()
        jail(INMATE, 30)
        advance(30)
        hackGate(INMATE)
        assert_eq(#doorChanges, 1)
        assert_eq(doorChanges[1].door, Config.Gates[1].gatekey)
        assert_eq(doorChanges[1].locked, false)
        sampleAt(INMATE, GATE)
        sampleAt(INMATE, beyondGate(20))
        sampleAt(INMATE, beyondGate(60))
        assert_eq(meta(INMATE).injail, 0)
        assert_eq(#meta(INMATE).jailitems, 0)          -- an escapee forfeits the belongings
        assert_eq(#events('prison:client:Escaped', INMATE), 1)
        assert_eq(#Emits, 1)
        assert_eq(Emits[1].kind, 'crime.prison.escape')
        assert_eq(Emits[1].data.name, 'John Escape1')
    end)
    it('another inmate can go through the open gate too', function()
        jail(INMATE, 30)
        jail(OTHER, 30)
        advance(30)
        hackGate(INMATE)
        Mock.coords[INMATE] = at(0, 0)
        sampleAt(OTHER, GATE)
        sampleAt(OTHER, beyondGate(25))
        sampleAt(OTHER, beyondGate(60))
        assert_eq(meta(OTHER).injail, 0)
        assert_eq(meta(INMATE).injail, 30)
    end)
    it('a breached gate does not cover a teleport out', function()
        jail(INMATE, 30)
        advance(30)
        hackGate(INMATE)
        sampleAt(INMATE, GATE)
        sampleAt(INMATE, beyondGate(10))
        sampleAt(INMATE, beyondGate(400))             -- 390 m in 2 s
        assert_eq(meta(INMATE).injail, 30)
        assert_eq(#events('prison:client:Escaped', INMATE), 0)
    end)
    it('a breach long ago does not cover leaving now', function()
        jail(INMATE, 30)
        advance(30)
        hackGate(INMATE)
        sampleAt(INMATE, GATE)
        sampleAt(INMATE, beyondGate(10))
        advance(Config.Prison.BreachWindow + 10)
        sampleAt(INMATE, beyondGate(30))
        sampleAt(INMATE, beyondGate(60))
        assert_eq(meta(INMATE).injail, 30)
    end)
end)

describe('gate hacks (prison gates, X-8)', function()
    local function start(src, gate)
        Mock.fireNet('prison:server:StartGateHack', src, gate)
        local e = events('prison:client:GateHackStart', src)
        return e[#e]
    end
    it('need an inmate at the gate holding both items; the gatecrack is used up', function()
        Mock.coords[INMATE] = GATE
        assert_eq(start(INMATE, 1), nil)                 -- not jailed
        jail(INMATE, 30)
        Mock.coords[INMATE] = GATE + vector3(10, 0, 0)
        assert_eq(start(INMATE, 1), nil)                 -- not at the gate
        Mock.coords[INMATE] = GATE
        assert_eq(start(INMATE, 99), nil)                -- no such gate
        inv.has.gatecrack = false
        assert_eq(start(INMATE, 1), nil)
        inv.has.gatecrack = true
        local e = start(INMATE, 1)
        assert_true(e ~= nil)
        assert_eq(#inv.removes, 1)
        assert_eq(inv.removes[1].name, 'gatecrack')
        assert_true(type(e.args[3]) == 'table', 'a server-checked puzzle is handed out')
    end)
    it('open only on the server-checked pass, once per ticket, in time and still at the gate', function()
        jail(INMATE, 30)
        Mock.coords[INMATE] = GATE
        local e = start(INMATE, 1)
        Mock.fireNet('prison:server:GateHackResult', INMATE, e.args[2], true)   -- too fast
        assert_eq(#doorChanges, 0)
        assert_eq(#events('prison:client:SetLockDown'), 1)
        -- the lockdown blocks further hacks for its whole window
        advance(60)
        start(INMATE, 2)
        assert_eq(#events('prison:client:GateHackStart', INMATE), 1)
    end)
    it('the puzzle verdict decides, not the client\'s word', function()
        jail(INMATE, 30)
        Mock.coords[INMATE] = GATE
        local e = start(INMATE, 1)
        advance(10)
        challenges.verdict = false
        Mock.fireNet('prison:server:GateHackResult', INMATE, e.args[2], true)
        assert_eq(#doorChanges, 0)
        assert_eq(#challenges.verified, 1)
        assert_eq(#events('prison:client:SetLockDown'), 1)
    end)
    it('a pass opens the door through pfm-doorlock\'s server path, and it locks again with the alarm', function()
        jail(INMATE, 30)
        Mock.coords[INMATE] = GATE
        local e = start(INMATE, 1)
        advance(10)
        Mock.fireNet('prison:server:GateHackResult', INMATE, e.args[2], true)
        assert_eq(#grants, 1)
        assert_eq(#doorChanges, 1)
        assert_eq(doorChanges[1].unlockAnyway, true)
        assert_eq(doorChanges[1].by, INMATE)
        assert_eq(events('prison:client:SetGateHit')[1].args[1], 1)
        Mock.fireNet('prison:server:GateHackResult', INMATE, e.args[2], true)   -- the same ticket again
        assert_eq(#doorChanges, 1)
        PFPrison.EndAlarm()
        assert_eq(#doorChanges, 2)
        assert_eq(doorChanges[2].locked, true)
    end)
    it('an opened gate locks again by itself, also when no alarm rang', function()
        local timers = {}
        local realTimeout = SetTimeout
        SetTimeout = function(ms, fn) timers[#timers + 1] = { ms = ms, fn = fn } end
        local realRandom = math.random
        math.random = function(a, b) if a == 1 and b == 100 then return 100 end return realRandom(a, b) end -- no alert roll
        jail(INMATE, 30)
        Mock.coords[INMATE] = GATE
        local e = start(INMATE, 1)
        advance(10)
        Mock.fireNet('prison:server:GateHackResult', INMATE, e.args[2], true)
        math.random = realRandom
        SetTimeout = realTimeout
        assert_eq(Mock.callCallback('prison:server:IsAlarmActive', COP), false)
        assert_eq(#doorChanges, 1)
        local relock
        for _, t in ipairs(timers) do if t.ms == Config.GateHack.OpenSeconds * 1000 then relock = t.fn end end
        assert_true(relock ~= nil, 'a relock is scheduled')
        relock()
        assert_eq(#doorChanges, 2)
        assert_eq(doorChanges[2].locked, true)
        assert_eq(#Mock.callCallback('prison:server:GetState', COP).gates, 0)
    end)
    it('no client can raise lockdowns, gate hits or the alarm, and failures alert once per window', function()
        assert_eq(Mock.netHandlers['prison:server:SecurityLockdown'], nil)
        assert_eq(Mock.netHandlers['prison:server:SetGateHit'], nil)
        assert_eq(Mock.netHandlers['prison:server:JailAlarm'], nil)
        jail(INMATE, 30)
        jail(OTHER, 30)
        Mock.coords[INMATE] = GATE
        Mock.coords[OTHER] = Config.Gates[2].coords
        local a = start(INMATE, 1)
        advance(10)
        challenges.verdict = false
        Mock.fireNet('prison:server:GateHackResult', INMATE, a.args[2], false)
        local alerts = #events('prison:client:PrisonBreakAlert', COP)
        assert_eq(alerts, 1)
        assert_eq(start(OTHER, 2), nil)                  -- locked down: no hack starts
        assert_eq(#events('prison:client:PrisonBreakAlert', COP), 1)
        assert_eq(Mock.callCallback('prison:server:IsAlarmActive', COP), true)
    end)
end)
