-- pfm-vehiclekeys lockpick and hotwire attempts (KEYS-1, PICK-2): the server starts each attempt
-- (distance or driver seat, the pick held), the lockpick minigame is a pfm-minigames challenge,
-- and the server decides the outcome, the hotwire chance, the pick's breakage and the police
-- alert. Keys asked for by the client: another player's car never (only a finished attempt), a
-- plate string only to its owner or to the driver of an ownerless car carrying it.
load_resource('tests/lua/fivem_mocks.lua')

local timers = {}
function SetTimeout(ms, fn) timers[#timers + 1] = { ms = ms, fn = fn } end

-- database: player_vehicles owners and pf-jobgarages fleet sign-outs
local owners = {} -- [plate] = citizenid
local fleet = {}  -- [plate] = citizenid it is signed out to
MySQL.scalar = setmetatable({ await = function(sql, p)
    if sql:find('information_schema', 1, true) then return 1 end
    if sql:find('job_garage_vehicles', 1, true) then return fleet[p[1]] == p[2] and 1 or nil end
    return owners[p[1]]
end }, { __call = function() end })

function GetEntityType() return 2 end
-- the driver is whoever sits in the car and is not listed as a passenger
local passengers = {}
function GetPedInVehicleSeat(veh, seat)
    if seat ~= -1 then return 0 end
    for ped, v in pairs(Mock.vehicleOf) do if v == veh and not passengers[ped] then return ped end end
    return 0
end
function IsPedAPlayer(ped) return Mock.players[ped] ~= nil end
local locks = {}
function SetVehicleDoorsLocked(veh, state) locks[#locks + 1] = { veh = veh, state = state } end
local firstOwner, popType = {}, {}
function NetworkGetFirstEntityOwner(veh) return firstOwner[veh] or -1 end
function GetEntityPopulationType(veh) return popType[veh] or 2 end

local items, removed = {}, {}
Mock.exportsByResource['pfm-inventory'] = {
    GetItemByName = function(_, src, name) return items[src] and items[src][name] and { name = name } or nil end,
    RemoveItem = function(_, src, name)
        if not (items[src] and items[src][name]) then return false end
        items[src][name] = nil
        removed[#removed + 1] = { src = src, name = name }
        return true
    end,
}

load_resource('pfm-minigames/server/challenge.lua')
Mock.exportsByResource['pfm-minigames'] = Mock.exportsByResource['__self']
Config = nil
load_resource('pfm-vehiclekeys/config.lua')
load_resource('pfm-vehiclekeys/server/main.lua')

local OWNER, THIEF, COP = 1, 2, 3
local NPC = 900
local CAR, NPCCAR = 50, 51
local HERE = vector3(0, 0, 0)
local PLATES = { 'MYCAR123', 'NPC00001', 'FLEET001', 'JOB00001', 'TRUCK001', 'SPAWN001' }

BeforeEach = function()
    Mock.players, Mock.coords, Mock.vehicleOf, Mock.plates, Mock.models = {}, {}, {}, {}, {}
    Mock.gameTimer = Mock.gameTimer + 1000000
    owners, fleet, items, removed, locks, firstOwner, popType, passengers = { MYCAR123 = 'CID' .. OWNER }, {}, {}, {}, {}, {}, {}, {}
    for _, src in ipairs({ OWNER, THIEF, COP }) do
        local p = Mock.newPlayer(src)
        p.PlayerData.metadata.vehicleKeys = {}
        Mock.coords[src] = HERE
        Mock.fireEvent('playerDropped', src) -- no attempt or cooldown left from another test
        for _, plate in ipairs(PLATES) do RemoveKeys(src, plate) end
    end
    Mock.players[COP].PlayerData.job = { name = 'police', type = 'leo', onduty = true }
    Mock.coords[CAR], Mock.coords[NPCCAR] = vector3(1.5, 0, 0), vector3(1.5, 0, 0)
    Mock.plates[CAR], Mock.plates[NPCCAR] = 'MYCAR123', 'NPC00001'
    Config.RemoveLockpickNormal, Config.RemoveLockpickAdvanced = 0, 0
    Config.HotwireChance = 1
    Config.PoliceAlertChance, Config.PoliceNightAlertChance = 0, 0
    timers = {}
    Mock.reset()
end

local function later(ms) Mock.gameTimer = Mock.gameTimer + ms end
local function persisted(src, plate) return Mock.players[src].PlayerData.metadata.vehicleKeys[plate] == true end
local function keys(src, plate) return HasKeys(src, plate) == true end
local function unlocked(veh)
    for _, l in ipairs(locks) do if l.veh == veh and l.state == 1 then return true end end
    return false
end
local function alerts() return #Mock.clientEventsNamed('police:client:policeAlert') end

local function start(src, veh, kind, advanced)
    Mock.fireNet('qb-vehiclekeys:server:startPick', src, veh, kind, advanced)
    local sent = Mock.clientEventsNamed('qb-vehiclekeys:client:pickStarted')
    local last = sent[#sent]
    return last and last.target == src and last.args[3] or nil
end

-- the skillbar played perfectly (each key in the middle of its zone), in real time
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

local function finish(src, veh) Mock.fireNet('qb-vehiclekeys:server:finishPick', src, veh) end

describe('lockpicking a car', function()
    it("an honest pick from beside another player's car unlocks it, with no keys", function()
        items[THIEF] = { lockpick = true }
        local data = start(THIEF, CAR, 'lockpick')
        assert_true(data and data.challenge and data.challenge.id ~= nil, 'the client gets a challenge')
        assert_eq(data.challenge.puzzle.difficulty, 'medium')
        playPerfect(THIEF, data.challenge)
        finish(THIEF, CAR)
        assert_true(unlocked(CAR))
        assert_false(keys(THIEF, 'MYCAR123'))
        assert_eq(#removed, 0, 'break chance 0')
    end)
    it("from the driver's seat it gives keys: until restart for another player's car, kept for an NPC car", function()
        items[THIEF] = { advancedlockpick = true }
        Mock.vehicleOf[THIEF] = CAR
        local data = start(THIEF, CAR, 'lockpick', true)
        assert_eq(data.challenge.puzzle.difficulty, 'easy')
        playPerfect(THIEF, data.challenge)
        finish(THIEF, CAR)
        assert_true(keys(THIEF, 'MYCAR123'))
        assert_false(persisted(THIEF, 'MYCAR123'), "not saved on the thief's character")

        later(10000)
        Mock.vehicleOf[THIEF] = NPCCAR
        data = start(THIEF, NPCCAR, 'lockpick', true)
        playPerfect(THIEF, data.challenge)
        finish(THIEF, NPCCAR)
        assert_true(persisted(THIEF, 'NPC00001'))
    end)
    it('a finish without a passed minigame opens nothing, alerts police and may break the pick', function()
        items[THIEF] = { lockpick = true }
        Config.RemoveLockpickNormal, Config.PoliceAlertChance, Config.PoliceNightAlertChance = 1, 1, 1
        start(THIEF, CAR, 'lockpick')
        later(5000)
        finish(THIEF, CAR)
        assert_false(unlocked(CAR))
        assert_eq(#removed, 1)
        assert_eq(removed[1].name, 'lockpick')
        assert_eq(#Mock.clientEventsNamed('qb-inventory:client:ItemBox'), 1)
        assert_eq(alerts(), 1, 'the on-duty cop is alerted by the server')
    end)
    it('the pick may break on a passed attempt too (rolled on the server); breakLockpick from a client does nothing', function()
        items[THIEF] = { lockpick = true }
        Config.RemoveLockpickNormal = 1
        local data = start(THIEF, CAR, 'lockpick')
        playPerfect(THIEF, data.challenge)
        finish(THIEF, CAR)
        assert_true(unlocked(CAR))
        assert_eq(#removed, 1)
        items[THIEF] = { lockpick = true }
        Mock.fireNet('qb-vehiclekeys:server:breakLockpick', THIEF, 'lockpick')
        assert_eq(#removed, 1)
    end)
    it('cannot start without a pick, too far away, with keys already, or dead', function()
        assert_eq(start(THIEF, CAR, 'lockpick'), nil, 'no pick')
        items[THIEF] = { lockpick = true }
        Mock.coords[THIEF] = vector3(30, 0, 0)
        assert_eq(start(THIEF, CAR, 'lockpick'), nil, 'far away')
        Mock.coords[THIEF] = HERE
        Mock.players[THIEF].PlayerData.metadata.isdead = true
        assert_eq(start(THIEF, CAR, 'lockpick'), nil, 'dead')
        Mock.players[THIEF].PlayerData.metadata.isdead = nil
        items[OWNER] = { lockpick = true }
        GiveKeys(OWNER, 'MYCAR123')
        assert_eq(start(OWNER, CAR, 'lockpick'), nil, 'has the keys')
        assert_eq(start(THIEF, CAR, 'jumpstart'), nil, 'unknown kind')
    end)
    it('a finish too fast, too late, away from the car or for a car whose plate changed opens nothing', function()
        items[THIEF] = { lockpick = true }
        local function attempt(setup)
            later(10000)
            local data = start(THIEF, CAR, 'lockpick')
            playPerfect(THIEF, data.challenge)
            setup()
            finish(THIEF, CAR)
            Mock.coords[THIEF], Mock.plates[CAR] = HERE, 'MYCAR123'
            Config.LockpickMinTime = 1500
            return unlocked(CAR)
        end
        assert_false(attempt(function() Config.LockpickMinTime = 600000 end), 'too fast')
        assert_false(attempt(function() later(Config.LockpickMaxTime + 1) end), 'too late')
        assert_false(attempt(function() Mock.coords[THIEF] = vector3(30, 0, 0) end), 'walked away')
        assert_false(attempt(function() Mock.plates[CAR] = 'OTHER001' end), 'another car')
        assert_true(attempt(function() end), 'and the same attempt done right opens it')
    end)
    it("another player's finish, or a finish for another car, does nothing", function()
        items[THIEF] = { lockpick = true }
        local data = start(THIEF, CAR, 'lockpick')
        playPerfect(THIEF, data.challenge)
        finish(OWNER, CAR)
        finish(THIEF, NPCCAR)
        assert_false(unlocked(CAR))
        finish(THIEF, CAR)
        assert_true(unlocked(CAR))
    end)
    it('an attempt left open fails at its deadline: the pick may break and police may hear', function()
        items[THIEF] = { lockpick = true }
        Config.RemoveLockpickNormal, Config.PoliceAlertChance, Config.PoliceNightAlertChance = 1, 1, 1
        start(THIEF, CAR, 'lockpick')
        assert_eq(#timers, 1)
        assert_true(timers[1].ms > Config.LockpickMaxTime)
        timers[1].fn()
        assert_eq(#removed, 1)
        assert_eq(alerts(), 1)
        finish(THIEF, CAR)
        assert_false(unlocked(CAR))
    end)
    it('starting again ends the open attempt as failed (no free retries)', function()
        items[THIEF] = { lockpick = true }
        Config.RemoveLockpickNormal = 1
        start(THIEF, CAR, 'lockpick')
        later(3000)
        items[THIEF].lockpick = true
        start(THIEF, CAR, 'lockpick')
        assert_eq(#removed, 1)
    end)
end)

describe('hotwiring', function()
    it('the full time at the wheel, then the server rolls the chance', function()
        Mock.vehicleOf[THIEF] = CAR
        local data = start(THIEF, CAR, 'hotwire')
        assert_true(data.duration >= Config.minHotwireTime and data.duration <= Config.maxHotwireTime)
        later(data.duration)
        finish(THIEF, CAR)
        assert_true(keys(THIEF, 'MYCAR123'))
        assert_false(persisted(THIEF, 'MYCAR123'))
    end)
    it('no keys when finished early, when the roll fails, or after leaving the seat', function()
        Mock.vehicleOf[THIEF] = CAR
        local data = start(THIEF, CAR, 'hotwire')
        later(1000)
        finish(THIEF, CAR)
        assert_false(keys(THIEF, 'MYCAR123'), 'early')

        later(10000)
        Config.HotwireChance = 0
        data = start(THIEF, CAR, 'hotwire')
        later(data.duration)
        finish(THIEF, CAR)
        assert_false(keys(THIEF, 'MYCAR123'), 'the roll failed')

        later(10000)
        Config.HotwireChance = 1
        data = start(THIEF, CAR, 'hotwire')
        later(data.duration)
        Mock.vehicleOf[THIEF] = nil
        finish(THIEF, CAR)
        assert_false(keys(THIEF, 'MYCAR123'), 'left the seat')
    end)
    it("cannot start from outside the driver's seat; a cancelled hotwire cannot be finished", function()
        assert_eq(start(THIEF, CAR, 'hotwire'), nil)
        Mock.vehicleOf[THIEF] = CAR
        local data = start(THIEF, CAR, 'hotwire')
        Mock.fireNet('qb-vehiclekeys:server:cancelPick', THIEF)
        later(data.duration)
        finish(THIEF, CAR)
        assert_false(keys(THIEF, 'MYCAR123'))
    end)
    it('police may hear of it 10 s in, from the server', function()
        Config.PoliceAlertChance, Config.PoliceNightAlertChance = 1, 1
        Mock.vehicleOf[THIEF] = CAR
        start(THIEF, CAR, 'hotwire')
        local alertTimer
        for _, t in ipairs(timers) do if t.ms == 10000 then alertTimer = t end end
        assert_true(alertTimer ~= nil)
        alertTimer.fn()
        assert_eq(alerts(), 1)
    end)
end)

describe('keys a client asks for', function()
    local function acquire(src, arg)
        later(5000)
        Mock.fireNet('qb-vehiclekeys:server:AcquireVehicleKeys', src, arg)
    end
    it('a plate string: its owner, never anyone else, even at its wheel', function()
        acquire(OWNER, 'MYCAR123')
        assert_true(keys(OWNER, 'MYCAR123'))
        Mock.vehicleOf[THIEF] = CAR
        acquire(THIEF, 'MYCAR123')
        assert_false(keys(THIEF, 'MYCAR123'))
    end)
    it("SetOwner's plate: the owner's own car at once, even before its plate reaches the server; nobody else's", function()
        Mock.plates[NPCCAR] = 'SPAWN001' -- the plate the server still sees
        later(5000)
        Mock.fireNet('qb-vehiclekeys:server:AcquireVehicleKeys', OWNER, NPCCAR, 'MYCAR123')
        assert_true(keys(OWNER, 'MYCAR123'))
        assert_false(keys(OWNER, 'SPAWN001'))
        Mock.vehicleOf[THIEF] = NPCCAR
        later(5000)
        Mock.fireNet('qb-vehiclekeys:server:AcquireVehicleKeys', THIEF, NPCCAR, 'MYCAR123')
        assert_false(keys(THIEF, 'MYCAR123'), "naming another player's plate gives nothing")
        assert_true(keys(THIEF, 'SPAWN001'), 'only the ownerless car they drive, by its real plate')
    end)
    it('a plate string without an owner: only the driver of a car carrying it', function()
        acquire(THIEF, 'NPC00001')
        assert_false(keys(THIEF, 'NPC00001'), 'not in it')
        Mock.vehicleOf[NPC], Mock.vehicleOf[THIEF] = NPCCAR, NPCCAR
        passengers[THIEF] = true
        acquire(THIEF, 'NPC00001')
        assert_false(keys(THIEF, 'NPC00001'), 'passenger')
        Mock.vehicleOf[NPC], passengers[THIEF] = nil, nil
        acquire(THIEF, 'NPC00001')
        assert_true(keys(THIEF, 'NPC00001'), 'driver')
    end)
    it('on-duty police at the wheel of a player car get keys until restart (impound release); nobody else', function()
        Mock.vehicleOf[THIEF] = CAR
        acquire(THIEF, CAR)
        assert_false(keys(THIEF, 'MYCAR123'))
        Mock.vehicleOf[THIEF] = nil
        acquire(COP, CAR)
        assert_false(keys(COP, 'MYCAR123'), 'not at the wheel')
        Mock.vehicleOf[COP] = CAR
        Mock.players[COP].PlayerData.job.onduty = false
        acquire(COP, CAR)
        assert_false(keys(COP, 'MYCAR123'), 'off duty')
        Mock.players[COP].PlayerData.job.onduty = true
        acquire(COP, CAR)
        assert_true(keys(COP, 'MYCAR123'))
        assert_false(persisted(COP, 'MYCAR123'))
    end)
    it("a fleet car signed out to the player (another player's car) gives keys until restart", function()
        owners.FLEET001 = 'CID' .. OWNER
        Mock.plates[CAR] = 'FLEET001'
        acquire(THIEF, CAR)
        assert_false(keys(THIEF, 'FLEET001'))
        fleet.FLEET001 = 'CID' .. THIEF
        acquire(THIEF, CAR)
        assert_true(keys(THIEF, 'FLEET001'))
        assert_false(persisted(THIEF, 'FLEET001'))
        RemoveKeys(THIEF, 'FLEET001')
        acquire(THIEF, 'FLEET001') -- the plate string path too
        assert_true(keys(THIEF, 'FLEET001'))
    end)
    it("a car the player's own client spawned by script gives keys from beside it; ambient traffic does not", function()
        Mock.plates[NPCCAR] = 'TRUCK001'
        popType[NPCCAR] = 2
        firstOwner[NPCCAR] = THIEF
        acquire(THIEF, NPCCAR)
        assert_false(keys(THIEF, 'TRUCK001'), 'ambient car its client happened to create')
        popType[NPCCAR] = 7
        firstOwner[NPCCAR] = OWNER
        acquire(THIEF, NPCCAR)
        assert_false(keys(THIEF, 'TRUCK001'), "another player's spawn")
        firstOwner[NPCCAR] = THIEF
        acquire(THIEF, NPCCAR)
        assert_true(keys(THIEF, 'TRUCK001'))
    end)
    it('a job vehicle the job shares gives keys from beside it', function()
        Mock.plates[NPCCAR] = 'JOB00001'
        Mock.models[NPCCAR] = GetHashKey('police')
        acquire(THIEF, NPCCAR)
        assert_false(keys(THIEF, 'JOB00001'))
        acquire(COP, NPCCAR)
        assert_true(keys(COP, 'JOB00001'))
    end)
end)

describe('locks without keys', function()
    local function lock(src, veh, state) later(100) Mock.fireNet('qb-vehiclekeys:server:setVehLockState', src, veh, state) end
    it('an NPC parked car: the client may lock it (Config.LockNPCParkedCars), not unlock it', function()
        lock(THIEF, NPCCAR, 1)
        assert_eq(#locks, 0)
        lock(THIEF, NPCCAR, 2)
        assert_eq(#locks, 1)
    end)
    it('an NPC-driven car may be unlocked (taking it from a dead driver)', function()
        Mock.vehicleOf[NPC] = NPCCAR
        lock(THIEF, NPCCAR, 1)
        assert_true(unlocked(NPCCAR))
    end)
    it('an ownerless car someone else holds keys to (a job or rental car) is not touched', function()
        GiveKeys(OWNER, 'NPC00001')
        lock(THIEF, NPCCAR, 2)
        lock(THIEF, NPCCAR, 1)
        assert_eq(#locks, 0)
        lock(OWNER, NPCCAR, 1)
        assert_true(unlocked(NPCCAR))
    end)
end)
