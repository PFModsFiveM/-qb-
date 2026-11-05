-- pf-ambulancejob damage ingestion (batch 16B, server/medical/ingest.lua) with an in-memory SQL
-- layer: injuries only from server-seen drops and attacker events, the hint as a capped region
-- choice, the downgrade of a claimed weapon nobody fired, falls and crashes from the server's own
-- velocity samples, armour and helmet, samplers that read only the players they need, rate limits,
-- idempotency, safe zones, anomaly rows, and the legacy forwarders (processDamage, the scan, field
-- and hospital treatment) on top of the engine.
load_resource('tests/lua/fivem_mocks.lua')
function IsDuplicityVersion() return true end
function GetCurrentResourceName() return 'pf-ambulancejob' end
function GetResourceState() return 'started' end

-- natives the samplers read (counted)
local health, armour, vel, held, natives, cancelled = {}, {}, {}, {}, {}, 0
local function count(n) natives[n] = (natives[n] or 0) + 1 end
function GetEntityHealth(p) count('health') return health[p] or 200 end
function GetPedArmour(p) count('armour') return armour[p] or 0 end
function GetEntityVelocity(e) count('velocity') return vel[e] or vector3(0, 0, 0) end
function GetVehiclePedIsIn(p) count('vehicle') return Mock.vehicleOf[p] or 0 end
function NetworkGetEntityOwner(e) return e end
function GetSelectedPedWeapon(p) return held[p] or 0 end
function CancelEvent() cancelled = cancelled + 1 end

load_resource('[pfscripts]/pf-ambulancejob/config.lua')
load_resource('[pfscripts]/pf-ambulancejob/config_medical.lua')
load_resource('[pfscripts]/pf-ambulancejob/shared/framework.lua')
for _, f in ipairs({ 'anatomy', 'injuries', 'physiology_model', 'effects_model', 'mechanisms' }) do
    load_resource('[pfscripts]/pf-ambulancejob/shared/medical/' .. f .. '.lua')
end

local DB
local function copy(t)
    if type(t) ~= 'table' then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = copy(v) end
    return o
end
local function installFakeSQL()
    DB = { patients = {}, injuries = {}, events = {}, nextId = 0 }
    local Q = PFMed.SQL
    Q.LoadPatient = function(cid) return copy(DB.patients[cid]) end
    Q.LoadOpenInjuries = function(cid)
        local out = {}
        for _, r in pairs(DB.injuries) do if r.citizenid == cid and r.stage ~= 'recovered' then out[#out + 1] = copy(r) end end
        return out
    end
    Q.FindInjuryByKey = function(key)
        for _, r in pairs(DB.injuries) do if r.idem_key == key then return { id = r.id, citizenid = r.citizenid, attrs = r.attrs } end end
    end
    Q.InsertInjury = function(r)
        if r.idem_key then for _, x in pairs(DB.injuries) do if x.idem_key == r.idem_key then error("Duplicate entry 'uq_med_inj_key'") end end end
        DB.nextId = DB.nextId + 1
        local row = copy(r)
        row.id = DB.nextId
        DB.injuries[row.id] = row
        return row.id
    end
    Q.UpsertPatients = function(rows) for _, r in ipairs(rows) do DB.patients[r.citizenid] = copy(r) end return true end
    Q.UpsertInjuries = function(rows) for _, r in ipairs(rows) do local o = DB.injuries[r.id] or {} for k, v in pairs(r) do o[k] = v end DB.injuries[r.id] = o end return true end
    Q.InsertEvents = function(rows) for _, e in ipairs(rows) do DB.events[#DB.events + 1] = copy(e) end return true end
end
Mock.exportsByResource['pfm-core'].RunMigrations = function() return true end
local hasHelmet = {}
Mock.exportsByResource['pfm-inventory'] = { HasItem = function(_, src, item) return item == 'helmet' and hasHelmet[src] == true end }

local Ing, Store, Engine
local T
local PISTOL, KNIFE, FALL = joaat('WEAPON_PISTOL'), joaat('WEAPON_KNIFE'), joaat('WEAPON_FALL')

local function fresh()
    for _, f in ipairs({ 'schema', 'store', 'engine', 'effects', 'api', 'ingest', 'legacy_import' }) do
        load_resource('[pfscripts]/pf-ambulancejob/server/medical/' .. f .. '.lua')
    end
    load_resource('[pfscripts]/pf-ambulancejob/server/injury_database.lua')
    load_resource('[pfscripts]/pf-ambulancejob/server/injury_handler.lua')
    installFakeSQL()
    assert(PFMed.Schema.Start(), 'schema ready')
    Ing, Store, Engine = PFMed.Ingest, PFMed.Store, PFMed.Engine
    Ing.Reset()
    Ing.Random = function() return 0.5 end
    Engine.Random = function() return 0.5 end
end

local function online(src)
    local p = Mock.newPlayer(src)
    Store.OnPlayerLoaded(src, p.PlayerData.citizenid)
    return p
end
local function sample() Ing.SampleBody(T) end
local function hurt(src, hp, ar) health[src] = hp; if ar then armour[src] = ar end; sample() end
local function hint(src, h) return Ing.OnHint(src, h, T) end
local function resolve() T = T + 2500; return Ing.ResolveDue(T) end
local function open(cid)
    local out = {}
    for _, inj in pairs(Store.Peek(cid or 'CID1').injuries) do if inj.stage ~= 'recovered' then out[#out + 1] = inj end end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end
local function anomalies(kind)
    Store.Flush()
    local n = 0
    for _, e in ipairs(DB.events) do if e.action == 'anomaly' and (not kind or (e.detail or ''):find('"' .. kind .. '"', 1, true)) then n = n + 1 end end
    return n
end
local function attack(sender, victim, weapon, extra)
    local data = { weaponType = weapon, hitGlobalId = victim }
    for k, v in pairs(extra or {}) do data[k] = v end
    return Ing.OnWeaponDamage(sender, data, T)
end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords, Mock.vehicleOf = {}, {}, {}
    health, armour, vel, held, natives, hasHelmet, cancelled = {}, {}, {}, {}, {}, {}, 0
    Mock.clock = 1700000000
    T = 100000
    fresh()
    online(1)
    sample() -- baseline
end

describe('plausibility', function()
    it('a hint with no server-seen drop and no attacker event creates nothing (anomaly logged)', function()
        assert_eq(hint(1, { seq = 1, weapon = PISTOL, bone = 24818, hpBefore = 200, hpAfter = 120 }), 'ok')
        T = T + 1000; sample()
        resolve()
        assert_eq(#open(), 0)
        assert_eq(anomalies('hint_without_damage'), 1)
    end)
    it('a drop with nothing to explain it (scripted damage) creates nothing', function()
        hurt(1, 170)
        resolve()
        assert_eq(#open(), 0)
    end)
    it('an attack the victim never felt is logged (godmode), no injury', function()
        attack(2, 1, PISTOL)
        resolve()
        assert_eq(#open(), 0)
        assert_eq(anomalies('attack_without_drop'), 1)
    end)
    it('a confirmed hit: gunshot wound in the hinted region, severity capped by the drop', function()
        online(2)
        held[2] = PISTOL
        attack(2, 1, PISTOL)
        hurt(1, 191)                                   -- 9 points: cap ceil(0.9) + 1 = 2
        hint(1, { seq = 2, weapon = PISTOL, bone = 58271, hpBefore = 200, hpAfter = 100 })   -- left thigh; its own hp claim is ignored
        local res = resolve()
        local list = open()
        assert_eq(#list, 1)
        assert_eq(list[1].type, 'gunshot')
        assert_eq(list[1].region, 'thigh_l')
        assert_true(list[1].severity <= 2, 'capped by the server drop')
        assert_eq(list[1].source_attacker_cid, 'CID2', 'the sender held the weapon')
        assert_eq(list[1].attrs.place, 'hint')
        assert_true(list[1].idem_key:find('^pf%-ambulancejob:dmg:CID1:') ~= nil)
        assert_eq(#res[1].created, 1)
    end)
    it('a claimed weapon without an attacker event is downgraded to unknown blunt trauma', function()
        hurt(1, 150)
        hint(1, { seq = 3, weapon = PISTOL, bone = 24818 })
        resolve()
        local list = open()
        assert_eq(#list, 1)
        assert_eq(list[1].type, 'bruising')
        assert_eq(list[1].mechanism, 'unknown')
        assert_true(list[1].severity <= 2)
        assert_eq(anomalies('weapon_unconfirmed'), 1)
    end)
    it('an NPC attack (sender does not hold the weapon) still wounds, without an attacker cid', function()
        online(3)
        attack(3, 1, KNIFE)
        hurt(1, 175)
        resolve()
        local list = open()
        assert_eq(list[1].type, 'stab')
        assert_eq(list[1].source_attacker_cid, nil)
    end)
end)

describe('falls and crashes from server samples', function()
    it('a fall the server sampled: peak speed -> height band; the hint picks the landing', function()
        assert_eq(Ing.OnMotionHint(1, 'airborne', T), 'ok')
        vel[1] = vector3(0, 0, -11.0); T = T + 500; Ing.SampleMotion(T)
        vel[1] = vector3(0, 0, 0); T = T + 300
        hurt(1, 150)
        hint(1, { seq = 4, weapon = FALL, bone = 14201, fall = { vz = -30 } })   -- claims 46 m; clamped to the samples
        resolve()
        local list = open()
        assert_true(#list >= 1)
        for _, inj in ipairs(list) do
            assert_eq(inj.mechanism, 'fall')
            assert_true(inj.attrs.fallHeight < 10, 'the claim was clamped to the server peak: ' .. tostring(inj.attrs.fallHeight))
            assert_eq(inj.attrs.landing, 'feet')
        end
        assert_eq(list[1].type, 'fracture')
    end)
    it('a fall nobody sampled is downgraded and logged', function()
        hurt(1, 150)
        hint(1, { seq = 5, weapon = FALL, bone = 14201, fall = { vz = -20 } })
        resolve()
        local list = open()
        assert_eq(#list, 1)
        assert_eq(list[1].mechanism, 'unknown')
        assert_eq(anomalies('fall_unverified'), 1)
    end)
    it('a crash: server speed drop -> delta-v band; a seatbelt claim moves one band', function()
        Mock.vehicleOf[1] = 500
        Ing.OnMotionHint(1, 'vehicle', T)
        vel[500] = vector3(25.0, 0, 0); T = T + 500; Ing.SampleMotion(T)     -- 90 km/h
        T = T + 300
        hurt(1, 120)
        vel[500] = vector3(0, 0, 0); T = T + 200; Ing.SampleMotion(T)
        hint(1, { seq = 6, bone = 24818, vehicle = { speedBefore = 60, speedAfter = 0, seatbelt = true } })
        resolve()
        local types = {}
        for _, inj in ipairs(open()) do
            assert_eq(inj.mechanism, 'vehicle')
            assert_true(inj.attrs.deltaV >= 90 and inj.attrs.deltaV <= 104, 'the claimed 216 km/h is clamped to 115 % of the sampled 90: ' .. tostring(inj.attrs.deltaV))
            types[inj.type .. ':' .. tostring(inj.subtype)] = true
        end
        assert_true(types['internal_bleeding:spleen'], 'band 3 (belted from band 4)')
        assert_false(types['head_trauma:subdural'] or false, 'not band 4')
    end)
end)

describe('protection', function()
    it('armour stops a pistol round over the vest (bruising)', function()
        armour[1] = 50; sample()
        attack(2, 1, PISTOL)
        hurt(1, 196, 20)
        hint(1, { seq = 7, weapon = PISTOL, bone = 24818 })
        resolve()
        local list = open()
        assert_eq(list[1].type, 'bruising')
        assert_eq(list[1].attrs.stopped, 'vest')
    end)
    it('a helmet item protects the head (verified hit component 20)', function()
        hasHelmet[1] = true
        attack(2, 1, PISTOL, { hitComponent = 20 })
        hurt(1, 160)
        resolve()
        local list = open()
        assert_eq(list[1].region, 'head')
        assert_eq(list[1].type, 'bruising')
        assert_eq(list[1].attrs.stopped, 'helmet')
        assert_eq(list[1].attrs.place, 'component')
    end)
end)

describe('samplers', function()
    it('read only the players they need', function()
        online(2); online(3)
        natives = {}
        Ing.SampleBody(T)
        assert_eq(natives.health, 3)
        assert_eq(natives.armour, 3)
        Ing.SampleMotion(T)
        assert_eq(natives.velocity, nil, 'nobody in a vehicle or falling: no velocity read')
        Mock.vehicleOf[2] = 600
        Ing.OnMotionHint(2, 'vehicle', T)
        natives = {}
        T = T + 500; Ing.SampleMotion(T)
        assert_eq(natives.velocity, 1)
        assert_eq(natives.vehicle, 1)
        -- the server ends the scope when it sees the player out of the vehicle
        Mock.vehicleOf[2] = nil
        for _ = 1, 8 do T = T + 500; Ing.SampleMotion(T) end
        assert_false(Ing.InScope(2))
    end)
end)

describe('rate limits, idempotency, safe zones', function()
    it('hints are rate limited (burst 20) and a repeated sequence number is ignored', function()
        local limited = 0
        for i = 1, 30 do if hint(1, { seq = 100 + i }) == 'rate_limited' then limited = limited + 1 end end
        assert_eq(limited, 10)
        T = T + 5000
        assert_eq(hint(1, { seq = 200 }), 'ok')
        assert_eq(hint(1, { seq = 200 }), 'duplicate')
        assert_eq(hint(1, 'nope'), 'bad_args')
        assert_eq(hint(1, { seq = 'x' }), 'bad_args')
    end)
    it('an episode creates its injuries once; a retried key is a duplicate', function()
        attack(2, 1, KNIFE)
        hurt(1, 170)
        resolve()
        local inj = open()[1]
        resolve()
        assert_eq(#open(), 1, 'a resolved episode is gone')
        local again, err, dup = Engine.AddInjury('CID1', { mechanism = inj.mechanism, type = inj.type, subtype = inj.subtype, region = inj.region,
            structure = inj.structure, severity = inj.severity, attrs = { weapon = KNIFE, place = 'random' } }, { key = inj.idem_key })
        assert_true(again ~= nil and dup == true, 'same key and fields: duplicate')
    end)
    it('weaponDamageEvent is cancelled only inside a configured safe zone', function()
        assert_false(attack(2, 1, PISTOL))
        Config.Medical.Ingest = { SafeZones = { { coords = vector3(0, 0, 0), radius = 10.0 } } }
        assert_true(attack(2, 1, PISTOL))
        Mock.coords[1] = vector3(100, 0, 0)
        assert_false(attack(2, 1, PISTOL))
        Config.Medical.Ingest = nil
        Mock.fireEvent('weaponDamageEvent', nil, 2, { weaponType = PISTOL, hitGlobalId = 1 })
        assert_eq(cancelled, 0)
    end)
end)

describe('legacy paths', function()
    it('processDamage is a hint: no player_injuries row, no injury without a server-seen drop', function()
        Mock.gameTimer = Mock.gameTimer + 5000
        Mock.fireNet('pf-ambulancejob:server:processDamage', 1, { injuryType = 'gunshot_wound', severity = 'critical', bodyZone = 'torso', health = 10, weapon = 'Pistol' })
        for _, c in ipairs(Mock.dbCalls) do assert_false(tostring(c.query):find('INSERT INTO `player_injuries`', 1, true) ~= nil, 'legacy insert') end
        resolve()
        assert_eq(#open(), 0)
        assert_eq(anomalies('hint_without_damage'), 1)
    end)
    it('the scan lists untreated engine injuries in the legacy shape; field and hospital treatment act on the engine', function()
        attack(2, 1, KNIFE)
        hurt(1, 170)
        resolve()
        local list = GetCitizenInjuries('CID1')
        assert_eq(#list, 1)
        assert_eq(list[1].injury_type, 'laceration')
        assert_eq(list[1].source, 'engine')
        assert_eq(RemoveTreatedInjuries('CID1', { laceration = true }, 'severe'), 1)
        local inj = open()[1]
        assert_eq(inj.stage, 'stabilized')
        assert_true(inj.treatments.pressure)
        assert_eq(#GetCitizenInjuries('CID1'), 0, 'a treated injury leaves the list')
        assert_eq(ClearCitizenInjuries('CID1'), 1)
        assert_eq(#open(), 0)
    end)
    it('the import maps an old record without bleeding or an acute threat', function()
        local LI = PFMed.LegacyImport
        local rows = LI.Map({ id = 7, citizen_id = 'OLD1', injury_type = 'gunshot_wound', severity = 'critical', body_zone = 'torso', weapon = 'Pistol', created_ts = 1600000000 })
        assert_eq(#rows, 1)
        assert_eq(rows[1].type, 'gunshot')
        assert_eq(rows[1].severity, 5)
        assert_eq(rows[1].bleed_ml_min, 0)
        assert_eq(rows[1].legacy_id, 7)
        assert_eq(rows[1].mechanism, 'legacy')
        assert_eq(rows[1].created_at, 1600000000)
        local burn = LI.Map({ id = 8, citizen_id = 'OLD1', injury_type = 'burn', severity = 'critical', body_zone = 'head' })
        assert_true(burn[1].severity < 3, 'a burn of the head is imported below the airway threshold')
        local blast = LI.Map({ id = 9, citizen_id = 'OLD1', injury_type = 'blast_injury', severity = 'severe', body_zone = 'left_leg' })
        assert_eq(#blast, 2)
        assert_eq(blast[2].idem_key, 'pf-ambulancejob:legacy:9:blast')
        assert_eq(#LI.Map({ id = 10, citizen_id = 'OLD1', injury_type = 'dragon', severity = 'minor', body_zone = 'head' }), 0)
    end)
end)
