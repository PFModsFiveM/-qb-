-- pf-ambulancejob functional effects (batch 17C). Server: the profile combines by maximum per channel,
-- painkillers never lower structural channels, restriction floors stay under painkillers, the
-- profile goes to the owner's client only when it changed (forced at load), with a version that only
-- grows, on a consciousness change and from the Sync pass over changed or ticking patients only.
-- Client (client/effects.lua): no thread while every channel is 0, one thread at most, stale pushes
-- ignored, each game effect set once and undone once, input blocked per frame only while needed,
-- a no_drive driver stopped before being taken out of the seat, nothing applied while down.
-- Legacy: client/wounding.lua no longer starts the bleed and move-rate loops.
load_resource('tests/lua/fivem_mocks.lua')
function IsDuplicityVersion() return true end
function GetCurrentResourceName() return 'pf-ambulancejob' end
function GetResourceState() return 'started' end

local AJ = '[pfscripts]/pf-ambulancejob/'
load_resource(AJ .. 'config.lua')
load_resource(AJ .. 'config_medical.lua')
load_resource(AJ .. 'shared/framework.lua')
for _, f in ipairs({ 'anatomy', 'injuries', 'physiology_model', 'effects_model' }) do
    load_resource(AJ .. 'shared/medical/' .. f .. '.lua')
end

local threads = 0
function CreateThread() threads = threads + 1 end

-- ── in-memory SQL layer ────────────────────────────────────────────────────────────────────────
local DB
local function copy(t)
    if type(t) ~= 'table' then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = copy(v) end
    return o
end
local function installFakeSQL()
    DB = { patients = {}, injuries = {}, restrictions = {}, nextId = 0, nextR = 0 }
    local Q = PFMed.SQL
    Q.LoadPatient = function(cid) return copy(DB.patients[cid]) end
    Q.LoadOpenInjuries = function(cid)
        local out = {}
        for _, r in pairs(DB.injuries) do if r.citizenid == cid and r.stage ~= 'recovered' then out[#out + 1] = copy(r) end end
        table.sort(out, function(a, b) return a.id < b.id end)
        return out
    end
    Q.FindInjuryByKey = function() return nil end
    Q.InjuryOwner = function(id) return DB.injuries[id] and DB.injuries[id].citizenid end
    Q.InsertInjury = function(r)
        DB.nextId = DB.nextId + 1
        local row = copy(r)
        row.id = DB.nextId
        DB.injuries[row.id] = row
        return row.id
    end
    Q.UpsertPatients = function(rows) for _, r in ipairs(rows) do DB.patients[r.citizenid] = copy(r) end return true end
    Q.UpsertInjuries = function(rows) for _, r in ipairs(rows) do DB.injuries[r.id] = copy(r) end return true end
    Q.InsertEvents = function() return true end
    Q.LoadRestrictions = function(cid)
        local out = {}
        for _, r in pairs(DB.restrictions) do if r.citizenid == cid and r.ended_at == nil then out[#out + 1] = copy(r) end end
        return out
    end
    Q.InsertRestriction = function(r)
        DB.nextR = DB.nextR + 1
        local row = copy(r)
        row.id = DB.nextR
        DB.restrictions[row.id] = row
        return row.id
    end
    Q.EndRestriction = function(id, at) DB.restrictions[id].ended_at = at return 1 end
    Q.SetRestrictionUntil = function(id, u) DB.restrictions[id].until_at = u return 1 end
end

Mock.exportsByResource['pfm-core'].RunMigrations = function() return true end

local Store, Engine, Fx, Rec
local function fresh(withRecovery)
    local list = { 'schema', 'store', 'engine', 'effects', 'api' }
    if withRecovery then list[#list + 1] = 'recovery' end
    for _, f in ipairs(list) do load_resource(AJ .. 'server/medical/' .. f .. '.lua') end
    installFakeSQL()
    assert(PFMed.Schema.Start())
    PFMed.Engine.Random = function() return 0.5 end
    Mock.exportsByResource['pf-ambulancejob'] = Mock.exportsByResource['__self']
    Store, Engine, Fx, Rec = PFMed.Store, PFMed.Engine, PFMed.Effects, PFMed.Recovery
end
local function online(src, cid)
    Mock.fireEvent('QBCore:Server:PlayerLoaded', nil, Mock.newPlayer(src, cid))
end
local function add(spec, cid) return assert(Engine.AddInjury(cid or 'CID1', spec, {})) end
local function pushes(src)
    local out = {}
    for _, e in ipairs(Mock.clientEventsNamed('pf-ambulancejob:client:Effects')) do
        if src == nil or e.target == src then out[#out + 1] = e end
    end
    return out
end

local TIBIA2 = { mechanism = 'fall', type = 'fracture', subtype = 'closed', structure = 'tibia_l', severity = 2 }
local CUT = { mechanism = 'edged', type = 'laceration', subtype = 'deep', region = 'thigh_l', severity = 2 }
local SPRAIN = { mechanism = 'fall', type = 'sprain', subtype = 'ankle', structure = 'ankle_l', severity = 2 }

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords, Mock.aces, Mock.vehicleOf = {}, {}, {}, {}
    Mock.invokingResource = nil
    Mock.clock = 1700000000
    threads = 0
    fresh(true)
end

-- ── server profile ─────────────────────────────────────────────────────────────────────────────

describe('profile', function()
    it('combines by maximum per channel, never by sum', function()
        online(1)
        local cut = add(CUT)
        local sprain = add(SPRAIN)
        assert_eq(PFMed.Injuries.Effects(cut).walk, 1)
        assert_eq(PFMed.Injuries.Effects(sprain).walk, 1)
        local p = Fx.Profile('CID1')
        assert_eq(p.walk, 1, 'two limps are one limp')
        assert_eq(p.sprint, 2, 'max of 2 and 2')
    end)

    it('painkillers lower pain but never a structural channel', function()
        online(1)
        add(TIBIA2)
        local before = Fx.Profile('CID1')
        assert_eq(before.walk, 2)
        assert_true(before.pain >= 1, 'it hurts')
        local p = Store.Peek('CID1')
        p.drugs.morphine = { mg = 10, at = os.time() }
        local after = Fx.Profile('CID1')
        assert_eq(after.walk, before.walk)
        assert_eq(after.sprint, before.sprint)
        assert_eq(after.jump, before.jump)
        assert_eq(after.climb, before.climb)
        assert_true(after.pain < before.pain, 'pain is lowered')
    end)

    it('a restriction floor stays under painkillers (a cast is still a cast)', function()
        online(1)
        assert_true(Rec.AddRestriction('CID1', { kind = 'cast_arm_l' }).ok)
        Store.Peek('CID1').drugs.morphine = { mg = 10, at = os.time() }
        local p = Fx.Profile('CID1')
        assert_eq(p.aim, 1)
        assert_eq(p.reload, 2)
        assert_eq(p.climb, 2)
    end)

    it('crutches are a modifier: walk 2 and no sprint, even with a worse leg', function()
        online(1)
        add({ mechanism = 'fall', type = 'fracture', subtype = 'closed', structure = 'femur_l', severity = 4 })
        assert_eq(Fx.Profile('CID1').walk, 3)
        Rec.AddRestriction('CID1', { kind = 'crutches' })
        local p = Fx.Profile('CID1')
        assert_eq(p.walk, 2)
        assert_eq(p.sprint, 3)
    end)

    it('restriction reasons stay generic unless asked for in detail', function()
        online(1)
        Rec.AddRestriction('CID1', { kind = 'no_drive', reason = 'Gunshot wound, abdomen' })
        local p = Store.Peek('CID1')
        local list = Fx.Restrictions(p, os.time())
        assert_eq(list[1].kind, 'no_drive')
        assert_eq(list[1].reason, 'injury')
        assert_eq(Fx.Restrictions(p, os.time(), { detail = true })[1].reason, 'Gunshot wound, abdomen')
        -- the export summary path (no options) is generic too
        local s = PFMed.Api.Summary(p, os.time())
        assert_eq(s.restrictions[1].reason, 'injury')
    end)
end)

-- ── push ───────────────────────────────────────────────────────────────────────────────────────

describe('push', function()
    it('sends only on change; force always; versions only grow across players', function()
        online(1)
        online(2, 'CID2')
        local base = #pushes()
        assert_true(Fx.Push(1, { force = true }))
        assert_false(Fx.Push(1), 'unchanged')
        add(TIBIA2)
        assert_true(Fx.Push(1))
        assert_true(Fx.Push(2, { force = true }))
        local list = pushes()
        assert_eq(#list, base + 3)
        local last = 0
        for _, e in ipairs(list) do
            assert_true(e.args[2] > last, 'version grows')
            last = e.args[2]
        end
        local payload = pushes(1)[#pushes(1)].args[1]
        assert_eq(payload.walk, 2)
        assert_eq(type(payload.restrictions), 'table')
    end)

    it('is pushed at load (even an empty profile) and on a change of consciousness', function()
        online(1)
        local at = pushes(1)
        assert_eq(#at, 1, 'pushed at load')
        assert_eq(at[1].args[1].walk, 0)
        add(TIBIA2)
        local n = #pushes(1)
        assert_true(Engine.SetConsciousness('CID1', 'unconscious', 'report', 'test', { holdSeconds = 60 }))
        assert_eq(#pushes(1), n + 1, 'consciousness listener pushed')
    end)

    it('Sync visits only patients whose record changed or who tick', function()
        online(1)
        online(2, 'CID2')
        Fx.Sync(os.time())
        local n = #pushes()
        Fx.Sync(os.time())
        assert_eq(#pushes(), n, 'nothing changed, nothing sent')
        add(TIBIA2, 'CID2')
        Fx.Sync(os.time())
        assert_eq(#pushes(), n + 1)
        assert_eq(pushes()[#pushes()].target, 2)
    end)

    it('works without the recovery module (effects alone, as the older specs load it)', function()
        fresh(false)
        online(1)
        add(TIBIA2)
        assert_true(Fx.Push(1, { force = true }))
    end)
end)

-- ── client applier ─────────────────────────────────────────────────────────────────────────────

local calls
local game = { aiming = false, sprinting = false, veh = 0, seatDriver = false, speed = 0, trying = 0, tryingSeat = -2, animLoaded = true }
local function rec(name) return function(...) calls[name] = calls[name] or {}; table.insert(calls[name], { ... }) end end
local function count(name) return calls[name] and #calls[name] or 0 end
local function installClientNatives()
    calls = {}
    PlayerPedId = function() return 77 end
    PlayerId = function() return 1 end
    RequestAnimSet = rec('RequestAnimSet')
    HasAnimSetLoaded = function() return game.animLoaded end
    SetPedMovementClipset = rec('SetPedMovementClipset')
    ResetPedMovementClipset = rec('ResetPedMovementClipset')
    SetPedMoveRateOverride = rec('SetPedMoveRateOverride')
    IsPlayerFreeAiming = function() return game.aiming end
    ShakeGameplayCam = rec('ShakeGameplayCam')
    StopGameplayCamShaking = rec('StopGameplayCamShaking')
    SetTimecycleModifier = rec('SetTimecycleModifier')
    SetTimecycleModifierStrength = rec('SetTimecycleModifierStrength')
    ClearTimecycleModifier = rec('ClearTimecycleModifier')
    IsPedSprinting = function() return game.sprinting end
    GetPlayerStamina = function() return 50.0 end
    SetPlayerStamina = rec('SetPlayerStamina')
    AnimpostfxPlay = rec('AnimpostfxPlay')
    GetVehiclePedIsIn = function() return game.veh end
    GetPedInVehicleSeat = function(_, seat) return (seat == -1 and game.seatDriver) and 77 or 0 end
    GetVehiclePedIsTryingToEnter = function() return game.trying end
    GetSeatPedIsTryingToEnter = function() return game.tryingSeat end
    ClearPedTasks = rec('ClearPedTasks')
    GetEntitySpeed = function() return game.speed end
    TaskLeaveVehicle = rec('TaskLeaveVehicle')
    SetVehicleSteerBias = rec('SetVehicleSteerBias')
    DoesEntityExist = function() return true end
    DisableControlAction = rec('DisableControlAction')
    QBCore = { Functions = { Notify = rec('Notify') } }
    isDead, InLaststand, ServerDownState = false, false, false
end
local function loadClient()
    installClientNatives()
    PFEffects = nil
    load_resource(AJ .. 'client/effects.lua')
    return PFEffects
end
local function profile(t)
    local p = { walk = 0, sprint = 0, jump = 0, climb = 0, aim = 0, reload = 0, drive = 0, stamina = 0, vision = 0, pain = 0, restrictions = {} }
    for k, v in pairs(t or {}) do p[k] = v end
    return p
end
local function disabled(control)
    for _, c in ipairs(calls.DisableControlAction or {}) do if c[2] == control then return true end end
    return false
end

describe('client applier', function()
    it('starts no thread for an empty profile, one thread for a non-empty one, never two', function()
        local E = loadClient()
        threads = 0
        assert_true(E.Apply(profile(), 1))
        assert_eq(threads, 0, 'all zero: no loop')
        assert_false(E.state.running)
        assert_true(E.Apply(profile({ walk = 1 }), 2))
        assert_eq(threads, 1)
        assert_true(E.Apply(profile({ walk = 2 }), 3))
        assert_eq(threads, 1, 'the running loop picks up the new profile')
        assert_true(E.Apply(profile(), 4))
        assert_false(E.state.running)
        assert_eq(E.Step(1000), nil, 'a leftover loop iteration ends itself')
    end)

    it('ignores a stale or repeated version and cleans hostile values', function()
        local E = loadClient()
        assert_true(E.Apply(profile({ walk = 2 }), 5))
        assert_false(E.Apply(profile({ walk = 0 }), 4))
        assert_false(E.Apply(profile({ walk = 0 }), 5))
        assert_eq(E.state.profile.walk, 2)
        local c = E.Clean({ walk = 99, aim = -3, vision = 0 / 0, pain = '2', drive = 'x' })
        assert_eq(c.walk, 3)
        assert_eq(c.aim, 0)
        assert_eq(c.vision, 0)
        assert_eq(c.pain, 2)
        assert_eq(c.drive, 0)
    end)

    it('a heavy limp blocks sprint every frame and sets the clipset once; clearing undoes it once', function()
        local E = loadClient()
        E.Apply(profile({ walk = 2 }), 1)
        assert_eq(E.Step(1000), 0, 'per-frame while sprint must be blocked')
        assert_true(disabled(21), 'sprint blocked')
        assert_false(disabled(22), 'jump allowed at walk 2')
        assert_eq(calls.SetPedMoveRateOverride[1][2], 0.85)
        E.Step(1001)
        E.Step(1300)
        assert_eq(count('SetPedMovementClipset'), 1, 'set once, not every pass')
        E.Apply(profile(), 2)
        assert_eq(count('ResetPedMovementClipset'), 1)
        assert_eq(calls.SetPedMoveRateOverride[#calls.SetPedMoveRateOverride][2], 1.0)
        E.Apply(profile({ vision = 0 }), 3)
        assert_eq(count('ResetPedMovementClipset'), 1, 'nothing left to undo')
        assert_eq(count('ClearTimecycleModifier'), 0, 'never cleared a modifier it did not set')
    end)

    it('a mild limp (walk 1) runs no per-frame loop', function()
        local E = loadClient()
        E.Apply(profile({ walk = 1 }), 1)
        assert_eq(E.Step(1000), 250)
        assert_eq(count('DisableControlAction'), 0)
    end)

    it('aim shake only while aiming; blurred vision set once and cleared once', function()
        local E = loadClient()
        E.Apply(profile({ aim = 2, vision = 1 }), 1)
        E.Step(1000)
        assert_eq(count('ShakeGameplayCam'), 0, 'not aiming')
        assert_eq(count('SetTimecycleModifier'), 1)
        game.aiming = true
        E.Step(2000)
        E.Step(3000)
        assert_eq(count('ShakeGameplayCam'), 1)
        game.aiming = false
        E.Step(4000)
        assert_eq(count('StopGameplayCamShaking'), 1)
        E.Apply(profile(), 2)
        assert_eq(count('ClearTimecycleModifier'), 1)
        assert_eq(count('SetTimecycleModifier'), 1)
    end)

    it('no_drive: refuses the driver seat, stops a moving car before leaving it, passengers are fine', function()
        local E = loadClient()
        E.Apply(profile({ drive = 2, restrictions = { 'no_drive' } }), 1)
        game.trying, game.tryingSeat = 900, -1
        E.Step(1000)
        assert_eq(count('ClearPedTasks'), 1, 'cannot get into the driver seat')
        game.trying, game.tryingSeat = 0, -2
        game.veh, game.seatDriver, game.speed = 900, true, 20
        assert_eq(E.Step(2000), 0)
        assert_true(disabled(71), 'no throttle while moving')
        assert_eq(count('TaskLeaveVehicle'), 0, 'never thrown out at speed')
        game.speed = 0
        E.Step(3000)
        assert_eq(count('TaskLeaveVehicle'), 1)
        game.seatDriver = false
        E.Step(4000)
        assert_eq(count('TaskLeaveVehicle'), 1, 'a passenger stays')
        game.veh = 0
    end)

    it('applies nothing while the player is down and resets on character unload', function()
        local E = loadClient()
        E.Apply(profile({ walk = 2, vision = 2 }), 1)
        E.Step(1000)
        assert_eq(count('SetTimecycleModifier'), 1)
        ServerDownState = 'unconscious'
        assert_eq(E.Step(2000), 500)
        assert_eq(count('ClearTimecycleModifier'), 1, 'undone while down')
        assert_eq(count('DisableControlAction'), 1, 'no input blocking while down')
        ServerDownState = false
        E.Step(3000)
        assert_eq(count('SetTimecycleModifier'), 2, 'back when up')
        Mock.netHandlers['QBCore:Client:OnPlayerUnload']()
        assert_eq(E.state.version, 0)
        assert_true(E.Apply(profile({ walk = 1 }), 1), 'the next character starts from version 0')
    end)

    it('takes pushes through the client event', function()
        local E = loadClient()
        Mock.netHandlers['pf-ambulancejob:client:Effects'](profile({ stamina = 2 }), 9)
        assert_eq(E.state.profile.stamina, 2)
        game.sprinting = true
        E.Step(1000)
        assert_eq(calls.SetPlayerStamina[1][2], 47.5)
        game.sprinting = false
    end)
end)

describe('legacy client loops retired', function()
    it('client/wounding.lua starts no loop and no longer touches bleeding or items', function()
        installClientNatives()
        Lang = { t = function(_, k) return k end }
        QBCore.Functions.Progressbar = function(_, _, _, _, _, _, _, _, _, done) done() end
        StopAnimTask = rec('StopAnimTask')
        GetEntityHealth = function() return 150 end
        GetEntityMaxHealth = function() return 200 end
        SetEntityHealth = rec('SetEntityHealth')
        local serverEvents = {}
        TriggerServerEvent = function(name) serverEvents[#serverEvents + 1] = name end
        threads = 0
        load_resource(AJ .. 'client/wounding.lua')
        assert_eq(threads, 0, 'no bleed loop, no move-rate loop')
        Mock.netHandlers['hospital:client:UseBandage']()
        Mock.netHandlers['hospital:client:UsePainkillers']()
        for _, n in ipairs(serverEvents) do
            assert_true(n ~= 'hospital:server:removeBandage' and n ~= 'hospital:server:removePainkillers', 'items are consumed on the server')
        end
        assert_eq(calls.SetEntityHealth[1][2], 160)
        assert_true(isBleeding == nil, 'no client bleed state')
        assert_false(onPainKillers)
    end)
end)
