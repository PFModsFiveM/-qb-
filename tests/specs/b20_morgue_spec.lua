-- pf-ambulancejob morgue and medical examiner (batch 20B): ordinary deaths keep respawning; only an
-- admin character kill (/markdeceased + confirm) creates a death record (one per citizen, keyed) and
-- sends the character back to selection (also when it loads again); the time-of-death range and
-- the autopsy (cause, suggested manner) come from the engine's own records (injuries present at
-- death, logged level changes, toxins, care given); the examiner works on duty, in the morgue, at
-- the right tier and after the server's exam time; deathRecorded is raised; a case link goes to
-- pf-policemdt-DEV AttachExternalRecord (refused links are not saved, an unreachable MDT is
-- retried); release, revoke, exports, and character deletion (case-linked records stay).
-- The SQL itself runs in b20_morgue_realdb_spec.
load_resource('tests/lua/ledger_env.lua')
function IsDuplicityVersion() return true end

function AddEventHandler(name, fn)
    local prev = Mock.eventHandlers[name]
    if prev then Mock.eventHandlers[name] = function(...) prev(...) fn(...) end else Mock.eventHandlers[name] = fn end
end
Bags = {}
function Player(src)
    Bags[src] = Bags[src] or {}
    local b = Bags[src]
    return { state = setmetatable({ set = function(_, k, v) b[k] = v end }, { __index = b }) }
end
function GetEntityHealth() return 200 end
function GetPedArmour() return 0 end
function GetEntityAttachedTo() return 0 end
function SetEntityCoords() end
STARTED = {}
function GetResourceState(res) return STARTED[res] and 'started' or 'missing' end
Commands = {}
QBCoreMock.Commands.Add = function(name, _, _, _, fn) Commands[name] = fn end
Mock.exportsByResource['pfm-core'].RunMigrations = function() return true end

-- pf-policemdt-DEV AttachExternalRecord as built in 18E: keyed by (target, type, id)
MDT = {}
local function mdtReset() MDT = { links = {}, calls = {}, cases = { [12] = true, [13] = true }, incidents = { ['INC-00042'] = true }, fail = nil } end
Mock.exportsByResource['pf-policemdt-DEV'] = {
    AttachExternalRecord = function(_, target, ref, opts)
        MDT.calls[#MDT.calls + 1] = { target = target, ref = ref, opts = opts }
        if MDT.fail then return { ok = false, error = MDT.fail } end
        if type(ref) ~= 'table' or ref.type ~= 'death_record' then return { ok = false, error = 'bad_args' } end
        local key
        if target.caseId then
            if not MDT.cases[target.caseId] then return { ok = false, error = 'not_found' } end
            key = 'case:' .. target.caseId .. ':' .. tostring(ref.id)
        elseif target.incidentId then
            if not MDT.incidents[target.incidentId] then return { ok = false, error = 'not_found' } end
            key = 'incident:' .. target.incidentId .. ':' .. tostring(ref.id)
        else
            return { ok = false, error = 'bad_args' }
        end
        if MDT.links[key] then return { ok = true, duplicate = true, linkId = MDT.links[key] } end
        MDT.links[key] = #MDT.calls
        return { ok = true, linkId = MDT.links[key] }
    end,
}

local function copy(t)
    if type(t) ~= 'table' then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = copy(v) end
    return o
end

-- in-memory tables with the semantics of the real statements
local function installFakeSQL()
    local Q = PFMed.SQL
    Q.LoadPatient = function(cid) return copy(DB.patients[cid]) end
    Q.LoadOpenInjuries = function(cid)
        local out = {}
        for _, r in pairs(DB.injuries) do if r.citizenid == cid and r.stage ~= 'recovered' then out[#out + 1] = copy(r) end end
        table.sort(out, function(a, b) return a.id < b.id end)
        return out
    end
    Q.FindInjuryByKey = function(key) for _, r in pairs(DB.injuries) do if r.idem_key == key then return copy(r) end end end
    Q.InsertInjury = function(r) DB.nextId = DB.nextId + 1; local row = copy(r); row.id = DB.nextId; DB.injuries[row.id] = row; return row.id end
    Q.UpsertPatients = function(rows) for _, r in ipairs(rows) do DB.patients[r.citizenid] = copy(r) end return true end
    Q.UpsertInjuries = function(rows)
        for _, r in ipairs(rows) do
            local row = DB.injuries[r.id]
            if row then for _, k in ipairs({ 'severity', 'stage', 'attrs', 'treatments', 'recovered_at' }) do row[k] = r[k] end end
        end
        return true
    end
    Q.InsertEvents = function(rows) for _, e in ipairs(rows) do DB.events[#DB.events + 1] = copy(e) end return true end
    Q.Sweep = function() return {} end
    Q.DeleteCharacter = function() return {} end
    if Q.ReadRestrictions then Q.ReadRestrictions = function() return {} end end

    local S = PFHospital.SQL
    S.InsertAdmission = function(r) DB.nextAdm = DB.nextAdm + 1; local row = copy(r); row.id = DB.nextAdm; DB.adm[row.id] = row; return row.id end
    S.FindAdmissionByKey = function(key) for _, r in pairs(DB.adm) do if r.idem_key == key then return copy(r) end end end
    S.GetAdmission = function(id) return copy(DB.adm[id]) end
    S.LoadOpenAdmissions = function()
        local out = {}
        for _, r in pairs(DB.adm) do if PFHospital.Admissions.OPEN[r.state] then out[#out + 1] = copy(r) end end
        return out
    end
    S.MoveAdmission = function(id, from, row)
        local r = DB.adm[id]
        if not r or r.state ~= from then return 0 end
        for k, v in pairs(row) do r[k] = v end
        return 1
    end
    S.InsertRestriction = function() return 1 end
    S.MarkStaff = function() return 1 end
    S.FindBillByAdmission = function() return nil end
    S.InsertBill = function() DB.nextBill = DB.nextBill + 1 return DB.nextBill end
    S.InsertBillLines = function() return true end
    S.GetBill = function() return nil end
    S.MoveBill = function() return 0 end
    S.TreatmentsFor = function() return {} end

    -- 20B
    local function rec(r) return copy(r) end
    S.MorgueInsert = function(r)
        for _, d in pairs(DB.deaths) do if d.idem_key == r.idem_key then error('Duplicate entry for key uq_death_key') end end
        DB.nextDeath = DB.nextDeath + 1
        local row = copy(r); row.id = DB.nextDeath; row.manner = 'pending'; row.state = 'intake'
        DB.deaths[row.id] = row
        return row.id
    end
    S.MorgueByKey = function(key) for _, d in pairs(DB.deaths) do if d.idem_key == key then return rec(d) end end end
    S.MorgueGet = function(id) return rec(DB.deaths[id]) end
    S.MorgueLatestOf = function(cid)
        local best
        for _, d in pairs(DB.deaths) do if d.citizenid == cid and (not best or d.id > best.id) then best = d end end
        return rec(best)
    end
    S.MorgueListOf = function(cid)
        local out = {}
        for _, d in pairs(DB.deaths) do if d.citizenid == cid then out[#out + 1] = rec(d) end end
        table.sort(out, function(a, b) return a.id > b.id end)
        return out
    end
    S.MorgueOpen = function()
        local out = {}
        for _, d in pairs(DB.deaths) do if d.state == 'intake' or d.state == 'examined' then out[#out + 1] = rec(d) end end
        table.sort(out, function(a, b) return a.id < b.id end)
        return out
    end
    S.MorgueDeceased = function()
        local out = {}
        for _, d in pairs(DB.deaths) do out[#out + 1] = { citizenid = d.citizenid, id = d.id } end
        return out
    end
    S.MorgueExamine = function(id, cause, manner, examiner, findings)
        local d = DB.deaths[id]
        if not d or d.state ~= 'intake' then return 0 end
        d.cause, d.manner, d.examiner_cid, d.findings, d.state = cause, manner, examiner, findings, 'examined'
        return 1
    end
    S.MorgueRelease = function(id, at)
        local d = DB.deaths[id]
        if not d or d.state ~= 'examined' then return 0 end
        d.state, d.released_at = 'released', at
        return 1
    end
    S.MorgueSetCase = function(id, ref)
        local d = DB.deaths[id]
        if not d or (d.case_ref and d.case_ref ~= ref) then return 0 end
        d.case_ref = ref
        return 1
    end
    S.MorgueClearCase = function(id, ref)
        local d = DB.deaths[id]
        if not d or d.case_ref ~= ref then return 0 end
        d.case_ref = nil
        return 1
    end
    S.MorgueDeleteIntake = function(id)
        local d = DB.deaths[id]
        if not d or d.state ~= 'intake' or d.case_ref then return 0 end
        DB.deaths[id] = nil
        return 1
    end
    S.MorgueDeleteCharacter = function(cid)
        local n = 0
        for id, d in pairs(DB.deaths) do if d.citizenid == cid and not d.case_ref then DB.deaths[id] = nil n = n + 1 end end
        return n
    end
    S.MorgueLinked = function(since)
        local out = {}
        for _, d in pairs(DB.deaths) do if d.case_ref and d.created_at >= since then out[#out + 1] = { id = d.id, case_ref = d.case_ref } end end
        return out
    end
    S.MorgueInjuriesAt = function(cid, at)
        local out = {}
        for _, r in pairs(DB.injuries) do
            if r.citizenid == cid and r.created_at <= at and (r.recovered_at == nil or r.recovered_at > at) then out[#out + 1] = copy(r) end
        end
        return out
    end
    S.MorgueStateEvents = function(cid, from, to)
        local out = {}
        for _, e in ipairs(DB.events) do
            if e.citizenid == cid and e.action == 'state' and e.at >= from and e.at <= to then out[#out + 1] = { detail = e.detail, at = e.at } end
        end
        return out
    end
    S.MorgueTreatments = function(cid, from, to)
        local out = {}
        for _, t in ipairs(DB.treatments) do if t.citizenid == cid and t.at >= from and t.at <= to then out[#out + 1] = copy(t) end end
        return out
    end
    S.MorgueCharacter = function(cid)
        local ci = DB.chars[cid]
        if not ci then return nil end
        return { citizenid = cid, charinfo = json.encode(ci) }
    end
    S.MorgueNames = function(cids)
        local out = {}
        for _, cid in ipairs(cids) do if DB.chars[cid] then out[#out + 1] = { citizenid = cid, charinfo = json.encode(DB.chars[cid]) } end end
        return out
    end
end

local AJ = '[pfscripts]/pf-ambulancejob/'
local FILES = { AJ .. 'config.lua', AJ .. 'config_medical.lua', AJ .. 'config_hospital.lua', AJ .. 'shared/framework.lua' }
for _, f in ipairs({ 'anatomy', 'injuries', 'physiology_model', 'effects_model' }) do FILES[#FILES + 1] = AJ .. 'shared/medical/' .. f .. '.lua' end
FILES[#FILES + 1] = AJ .. 'server/main.lua'
for _, f in ipairs({ 'schema', 'store', 'engine', 'downstate', 'effects', 'api' }) do FILES[#FILES + 1] = AJ .. 'server/medical/' .. f .. '.lua' end
for _, f in ipairs({ 'facility', 'beds', 'admissions', 'billing', 'ai_care', 'morgue' }) do FILES[#FILES + 1] = AJ .. 'server/hospital/' .. f .. '.lua' end

local H, M, Engine, D
local function boot()
    Mock.eventHandlers, Mock.netHandlers, Mock.netHandlerList, Mock.callbacks = {}, {}, {}, {}
    PFMed, PFEmsRequests, PFHospital, RespawnPlayer = nil, nil, nil, nil
    LedgerEnv.load('pf-ambulancejob', FILES)
    installFakeSQL()
    Mock.exportsByResource['pf-ambulancejob'] = Mock.exportsByResource['__self']
    H, M, Engine, D = PFHospital, PFHospital.Morgue, PFMed.Engine, PFMed.Down
    QBCore = QBCoreMock
    assert(PFMed.Schema.Start(), 'schema ready')
    assert(H.Admissions.Start(), 'hospital ready')
    assert(M.Start(), 'morgue ready')
    M.RegisterCommands()
end

local VICTIM, ME, MEDIC, ADMIN, CIV, KILLER = 1, 2, 3, 4, 5, 6
local MORGUE = vector3(275.45, -1361.11, 24.54)
local OUTSIDE = vector3(330.0, -588.0, 43.3)
Logged = {}
local function online(src, cid, first, last)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.money = { cash = 0, bank = 5000 }
    p.PlayerData.metadata.injail = 0
    p.PlayerData.charinfo = { firstname = first or 'Test', lastname = last or ('Player' .. src) }
    p.Functions.Logout = function() Logged[#Logged + 1] = src end
    DB.chars[cid] = p.PlayerData.charinfo
    Mock.fireEvent('QBCore:Server:PlayerLoaded', nil, p)
    return p
end
local function job(src, name, grade, onduty)
    Mock.players[src].PlayerData.job = { name = name, onduty = onduty ~= false, grade = { level = grade or 0 } }
end
local function advance(s) Mock.clock = Mock.clock + s end
local function cb(name, src, ...) return Mock.callCallback('pf-ambulancejob:server:' .. name, src, ...) end
local function events(name)
    local out = {}
    for _, e in ipairs(Mock.serverEvents) do if e.name == name then out[#out + 1] = e end end
    return out
end
local function deathOf(cid) for _, d in pairs(DB.deaths) do if d.citizenid == cid then return d end end end
local function countDeaths() local n = 0 for _ in pairs(DB.deaths) do n = n + 1 end return n end
local function level(cid) local p = PFMed.Store.Peek(cid) return p and p.consciousness end
local function mark(src, target, reason)
    Commands.markdeceased(src, { tostring(target), reason or 'character', 'kill' })
    Commands.markdeceased(src, { 'confirm' })
end
-- bleeds the victim out through the engine and the last stand until the engine says dead
local function bleedToDeath(attacker)
    local inj = Engine.AddInjury('VICTIMCID', { mechanism = 'edged', type = 'laceration', subtype = 'arterial', structure = 'femoral_l', severity = 5,
        attackerCid = attacker }, { key = 'spec:stab:1' })
    assert_true(inj ~= nil, 'injury stored')
    for _ = 1, 400 do
        advance(5); Engine.Tick(os.time()); D.Tick(os.time())
        if level('VICTIMCID') == 'dead' then break end
    end
    assert_eq(level('VICTIMCID'), 'dead')
    PFMed.Store.Flush()
    return inj
end
local function autopsy(id, manner, note)
    local s = cb('morgueAutopsyStart', ME, id)
    assert_true(s.ok, 'start: ' .. tostring(s.message))
    advance(M.Cfg().ExamSeconds)
    return cb('morgueAutopsy', ME, id, manner, note), s
end

BeforeEach = function()
    Mock.reset()
    LedgerEnv.reset()
    Mock.clock = 1700000000
    Mock.players, Mock.coords, Mock.aces = {}, {}, {}
    Mock.invokingResource = nil
    Bags, Logged = {}, {}
    STARTED = { ['pf-policemdt-DEV'] = true }
    mdtReset()
    DB = { patients = {}, injuries = {}, events = {}, nextId = 0, adm = {}, nextAdm = 0, nextBill = 0, deaths = {}, nextDeath = 0,
        treatments = {}, chars = {} }
    FakeDB.society('ambulance', 0)
    boot()
    PFMed.Engine.Random = function() return 0.5 end
    H.AI.Random = function() return 0.99 end
    online(VICTIM, 'VICTIMCID', 'John', 'Doe')
    online(ME, 'MECID')
    online(MEDIC, 'MEDICCID')
    online(ADMIN, 'ADMINCID')
    online(CIV, 'CIVCID')
    online(KILLER, 'KILLERCID')
    job(ME, 'ambulance', 2, true)      -- tier 5 (physician = medical examiner)
    job(MEDIC, 'ambulance', 1, true)   -- tier 3
    Mock.aces[ADMIN] = { admin = true }
    for src = 1, 6 do Mock.coords[src] = vector3(1000.0 + src * 100, 0.0, 0.0) end
    Mock.coords[ME], Mock.coords[MEDIC] = MORGUE, MORGUE
end

describe('ordinary deaths respawn; only an admin character kill makes a death record', function()
    it('a death through the engine creates no death record and the respawn still works', function()
        bleedToDeath()
        assert_eq(#events('pf-ambulancejob:server:patientDied'), 1)
        assert_eq(countDeaths(), 0)
        assert_false((M.IsDeceased('VICTIMCID')))
        advance(Config.Medical.Consciousness.RespawnAfterSeconds + 1)
        assert_true(D.CanRespawn(VICTIM), 'respawn allowed')
        assert_eq(#Logged, 0)
    end)
    it('/markdeceased needs the admin ACE and a confirmation; it is then one keyed record', function()
        Commands.markdeceased(CIV, { tostring(VICTIM), 'ck' })
        Commands.markdeceased(CIV, { 'confirm' })
        assert_eq(countDeaths(), 0, 'no ACE: refused')
        Commands.markdeceased(ADMIN, { tostring(VICTIM) })
        assert_eq(next(M.confirm), nil, 'a reason is required')
        Commands.markdeceased(ADMIN, { tostring(VICTIM), 'executed', 'in', 'rp' })
        assert_eq(countDeaths(), 0, 'nothing before the confirmation')
        advance(M.Cfg().ConfirmSeconds + 1)
        Commands.markdeceased(ADMIN, { 'confirm' })
        assert_eq(countDeaths(), 0, 'an expired confirmation does nothing')
        mark(ADMIN, VICTIM, 'executed')
        local d = deathOf('VICTIMCID')
        assert_true(d ~= nil)
        assert_eq(d.state, 'intake')
        assert_eq(d.manner, 'pending')
        assert_eq(d.cause, 'Pending examination')
        assert_eq(d.idem_key, 'pf-ambulancejob:death:VICTIMCID')
        assert_eq(d.hospital_id, 'pillbox')
        assert_true((M.IsDeceased('VICTIMCID')))
        -- a second mark (also by citizen id) is the same record
        local again = M.MarkDeceased('VICTIMCID', { actor = { kind = 'admin' }, reason = 'again' })
        assert_true(again.ok and again.duplicate)
        assert_eq(again.recordId, d.id)
        assert_eq(countDeaths(), 1)
        -- the console may mark too; an unknown citizen is refused
        assert_eq(M.MarkDeceased('NOSUCHCID', { actor = { kind = 'admin' }, reason = 'x' }).error, 'not_found')
    end)
    it('the character goes back to selection, now and whenever it loads again; deathRecorded is raised', function()
        mark(ADMIN, VICTIM)
        assert_eq(Logged[1], VICTIM)
        local choose = Mock.clientEventsNamed('qb-multicharacter:client:chooseChar')
        assert_eq(#choose, 1)
        assert_eq(choose[1].target, VICTIM)
        local ev = events('pf-ambulancejob:server:deathRecorded')
        assert_eq(#ev, 1)
        assert_eq(ev[1].args[1].cid, 'VICTIMCID')
        assert_eq(ev[1].args[1].manner, 'pending')
        assert_eq(ev[1].args[1].id, deathOf('VICTIMCID').id)
        -- loading the character again
        assert_true(M.OnPlayerLoaded(VICTIM, 'VICTIMCID'))
        assert_true(M.EnforceDeceased(VICTIM, 'VICTIMCID'))
        assert_eq(#Logged, 2)
        -- a living character is never touched
        assert_false(M.OnPlayerLoaded(CIV, 'CIVCID'))
        assert_false(M.EnforceDeceased(CIV, 'CIVCID'))
        -- the open export answers for everyone
        Mock.invokingResource = 'pfm-multicharacter'
        assert_true((exports['pf-ambulancejob']:IsDeceased('VICTIMCID')))
        assert_false((exports['pf-ambulancejob']:IsDeceased('CIVCID')))
    end)
    it('an open hospital stay ends as deceased', function()
        local res = H.Admissions.ExportAdmitPatient('VICTIMCID', { hospitalId = 'pillbox', dept = 'ward', reason = 'gsw' }, { key = 'spec:adm:1' })
        assert_true(res.ok, tostring(res.message))
        mark(ADMIN, VICTIM)
        assert_eq(DB.adm[res.admissionId].state, 'deceased')
    end)
end)

describe('time of death from the engine', function()
    it('a dead patient: from the moment they went down to the engine time of death; cause logged by the engine', function()
        bleedToDeath()
        local p = PFMed.Store.Peek('VICTIMCID')
        local deadAt, downSince = p.dead_at, p.down_since
        advance(120)
        mark(ADMIN, VICTIM)
        local d = deathOf('VICTIMCID')
        assert_eq(d.tod_to, deadAt)
        assert_eq(d.tod_from, downSince)
        assert_true(d.tod_from < d.tod_to)
        local intake = json.decode(d.findings).intake
        assert_false(intake.declared)
        assert_eq(intake.physCause, 'hemorrhage')
    end)
    it('a recent death the player respawned from is the death; an old one is not', function()
        bleedToDeath()
        local deadAt = PFMed.Store.Peek('VICTIMCID').dead_at
        assert_true(Engine.SetConsciousness('VICTIMCID', 'alert', 'respawn', 'respawn', {}))
        PFMed.Store.Flush()
        advance(600)
        mark(ADMIN, VICTIM)
        assert_eq(deathOf('VICTIMCID').tod_to, deadAt)
        assert_false(json.decode(deathOf('VICTIMCID').findings).intake.declared)
    end)
    it('no death on record: the mark time is the time of death and the record says so', function()
        local at = os.time()
        mark(ADMIN, VICTIM)
        local d = deathOf('VICTIMCID')
        assert_eq(d.tod_from, at)
        assert_eq(d.tod_to, at)
        assert_true(json.decode(d.findings).intake.declared)
    end)
end)

describe('autopsy', function()
    it('reads the injuries present at death: cause, homicide from an attacker, care given, toxins', function()
        Engine.AddToxin('VICTIMCID', 'ethanol', 0.08, {})
        DB.treatments[#DB.treatments + 1] = { citizenid = 'VICTIMCID', action = 'tourniquet', by_job = 'ambulance', location = 'field', result = 'ok', at = os.time() + 30 }
        bleedToDeath('KILLERCID')
        -- an old healed injury is not part of the death
        DB.nextId = DB.nextId + 1
        DB.injuries[DB.nextId] = { id = DB.nextId, citizenid = 'VICTIMCID', type = 'fracture', subtype = 'closed', structure = 'radius_l', region = 'forearm_l',
            severity = 2, stage = 'recovered', mechanism = 'fall', created_at = 1600000000, recovered_at = 1600500000 }
        mark(ADMIN, VICTIM)
        local id = deathOf('VICTIMCID').id
        local res, start = autopsy(id)
        assert_true(res.ok, tostring(res.message))
        assert_eq(start.preview.derivedManner, 'homicide')
        local d = DB.deaths[id]
        assert_eq(d.state, 'examined')
        assert_eq(d.manner, 'homicide')
        assert_eq(d.examiner_cid, 'MECID')
        assert_true(d.cause:find('Exsanguination', 1, true) == 1, d.cause)
        assert_true(d.cause:find('laceration', 1, true) ~= nil, d.cause)
        assert_eq(d.cause:find('toxicity', 1, true), nil, 'below the severe level the toxin is a finding, not a cause')
        local a = json.decode(d.findings).autopsy
        assert_eq(#a.injuries, 1, 'the recovered fracture is not listed')
        assert_eq(a.injuries[1].attacker, 'other')
        assert_eq(a.injuries[1].mechanism, 'edged')
        assert_eq(#a.interventions, 1)
        assert_eq(a.interventions[1].action, 'tourniquet')
        assert_eq(a.toxins[1].name, 'ethanol')
        assert_true(a.toxins[1].level > 0 and a.toxins[1].level <= 0.08)
        assert_eq(a.physCause, 'hemorrhage')
        assert_eq(a.derivedManner, 'homicide')
        local ev = events('pf-ambulancejob:server:deathRecorded')
        assert_eq(#ev, 2)
        assert_eq(ev[2].args[1].examiner, 'MECID')
        assert_eq(ev[2].args[1].manner, 'homicide')
    end)
    it('a fall is an accident; no injury and no toxin is undetermined; the examiner may rule another manner', function()
        Engine.AddInjury('VICTIMCID', { mechanism = 'fall', type = 'head_trauma', region = 'head', severity = 5 }, { key = 'spec:fall:1' })
        PFMed.Store.Flush()
        mark(ADMIN, VICTIM)
        local res = autopsy(deathOf('VICTIMCID').id, 'suicide', 'jumped, witness statement')
        assert_true(res.ok)
        local d = deathOf('VICTIMCID')
        assert_eq(d.manner, 'suicide')
        local a = json.decode(d.findings).autopsy
        assert_eq(a.derivedManner, 'accident')
        assert_eq(a.note, 'jumped, witness statement')
        assert_true(d.cause:find('Head trauma', 1, true) ~= nil or d.cause:find('head trauma', 1, true) ~= nil, d.cause)
        -- nothing on record
        mark(ADMIN, CIV)
        local r2 = autopsy(deathOf('CIVCID').id)
        assert_true(r2.ok)
        assert_eq(deathOf('CIVCID').manner, 'undetermined')
        assert_true(deathOf('CIVCID').cause:find('Undetermined', 1, true) == 1)
    end)
    it('the cause text only names what the evidence shows', function()
        local inj = { type = 'gunshot', subtype = 'penetrating', structure = 'heart', region = 'chest_l' }
        assert_eq(M.CauseText(inj, 'hemorrhage', {}), 'Exsanguination (blood loss) due to gunshot wound (penetrating) of the heart')
        assert_eq(M.CauseText(inj, 'gcs', {}), 'Gunshot wound (penetrating) of the heart', 'gcs is not a physiological cause of death')
        assert_eq(M.CauseText(inj, nil, { { name = 'opioid', level = 90, intensity = 1.5 } }),
            'Gunshot wound (penetrating) of the heart; contributing: opioid toxicity')
        assert_eq(M.CauseText(nil, 'hypoxia', { { name = 'opioid', level = 90, intensity = 1.5 } }), 'Asphyxia (lack of oxygen) due to opioid toxicity')
        assert_eq(M.CauseText(nil, nil, { { name = 'opioid', level = 10, intensity = 0.17 } }),
            'Undetermined: no fatal injury, toxin or physiological cause on record')
        -- the catalogue's lethal rule ranks a severe brain wound above a worse-bleeding limb wound
        local ranked = M.RankInjuries({
            { id = 1, type = 'laceration', subtype = 'arterial', structure = 'femoral_l', region = 'thigh_l', severity = 5, mechanism = 'edged', created_at = 10 },
            { id = 2, type = 'gunshot', subtype = 'penetrating', structure = 'brain', region = 'head', severity = 4, mechanism = 'firearm', created_at = 5 },
        })
        assert_eq(ranked[1].id, 2)
        assert_true(ranked[1].lethal)
        assert_eq(M.SuggestManner('A', { mechanism = 'firearm', attackerCid = 'B' }), 'homicide')
        assert_eq(M.SuggestManner('A', { mechanism = 'firearm', attackerCid = 'A' }), 'undetermined')
        assert_eq(M.SuggestManner('A', { mechanism = 'firearm' }), 'undetermined')
        assert_eq(M.SuggestManner('A', { mechanism = 'vehicle' }), 'accident')
        assert_eq(M.SuggestManner('A', { mechanism = 'illness' }), 'natural')
        assert_eq(M.SuggestManner('A', nil), 'undetermined')
    end)
    it('needs an examiner on duty, in the morgue, after the exam time, once', function()
        mark(ADMIN, VICTIM)
        local id = deathOf('VICTIMCID').id
        assert_eq(cb('morgueAutopsyStart', MEDIC, id).error, 'no_permission', 'tier 3 cannot examine')
        assert_eq(cb('morgueAutopsyStart', CIV, id).error, 'no_permission')
        Mock.coords[ME] = OUTSIDE
        assert_eq(cb('morgueAutopsyStart', ME, id).error, 'too_far')
        Mock.coords[ME] = MORGUE
        assert_eq(cb('morgueAutopsy', ME, id).error, 'invalid_state', 'not started')
        assert_true(cb('morgueAutopsyStart', ME, id).ok)
        advance(M.Cfg().ExamSeconds - 5)
        assert_eq(cb('morgueAutopsy', ME, id).error, 'too_soon')
        advance(5)
        assert_eq(cb('morgueAutopsy', ME, id, 'murder').error, 'bad_args', 'manner from the list only')
        job(ME, 'ambulance', 2, false)
        assert_eq(cb('morgueAutopsy', ME, id).error, 'not_on_duty')
        job(ME, 'ambulance', 2, true)
        assert_true(cb('morgueAutopsy', ME, id).ok)
        advance(2)
        assert_eq(cb('morgueAutopsyStart', ME, id).error, 'invalid_state', 'examined once')
    end)
end)

describe('police case link (pf-policemdt-DEV AttachExternalRecord)', function()
    it('links to a case: attached with the death_record type and saved; a repeat is a duplicate', function()
        mark(ADMIN, VICTIM)
        local id = deathOf('VICTIMCID').id
        local res = cb('morgueLinkCase', ME, id, '12')
        assert_true(res.ok, tostring(res.message))
        assert_eq(res.caseRef, 'case:12')
        assert_eq(deathOf('VICTIMCID').case_ref, 'case:12')
        assert_eq(MDT.calls[1].target.caseId, 12)
        assert_eq(MDT.calls[1].ref.type, 'death_record')
        assert_eq(MDT.calls[1].ref.id, id)
        advance(2)
        assert_true(cb('morgueLinkCase', ME, id, 'case:12').ok)
        assert_eq(MDT.links['case:12:' .. id] ~= nil, true)
        advance(2)
        assert_eq(cb('morgueLinkCase', ME, id, '13').error, 'conflict', 'one case per record')
        -- the autopsy keeps the link (the MDT answers duplicate)
        assert_true(autopsy(id).ok)
        assert_eq(MDT.calls[#MDT.calls].target.caseId, 12)
    end)
    it('an unknown case is refused and nothing is saved; an incident id works', function()
        mark(ADMIN, VICTIM)
        local id = deathOf('VICTIMCID').id
        assert_eq(cb('morgueLinkCase', ME, id, '99').error, 'not_found')
        assert_eq(deathOf('VICTIMCID').case_ref, nil)
        advance(2)
        assert_eq(cb('morgueLinkCase', ME, id, 'not a case!').error, 'bad_args')
        advance(2)
        local res = cb('morgueLinkCase', ME, id, 'INC-00042')
        assert_true(res.ok)
        assert_eq(deathOf('VICTIMCID').case_ref, 'incident:INC-00042')
        assert_eq(MDT.calls[#MDT.calls].target.incidentId, 'INC-00042')
        assert_eq(cb('morgueLinkCase', MEDIC, id, '12').error, 'no_permission')
    end)
    it('an unreachable MDT: the link is saved and retried until it is attached; a later refusal clears it', function()
        mark(ADMIN, VICTIM)
        local id = deathOf('VICTIMCID').id
        STARTED['pf-policemdt-DEV'] = nil
        local res = cb('morgueLinkCase', ME, id, '12')
        assert_true(res.ok and res.pending)
        assert_eq(deathOf('VICTIMCID').case_ref, 'case:12')
        M.RetryTick()
        assert_true(M.pending[id] ~= nil, 'still waiting')
        STARTED['pf-policemdt-DEV'] = true
        MDT.fail = 'busy'
        M.RetryTick()
        assert_true(M.pending[id] ~= nil, 'busy is retried')
        MDT.fail = nil
        M.RetryTick()
        assert_eq(M.pending[id], nil)
        assert_true(MDT.links['case:12:' .. id] ~= nil)
        -- a restart re-sends recent links (keyed, so the MDT answers duplicate)
        assert(M.Start())
        assert_true(M.pending[id] ~= nil)
        M.RetryTick()
        assert_eq(M.pending[id], nil)
        -- a case deleted meanwhile: the retry clears the stored link
        MDT.cases[12] = nil
        M.QueueAttach(id, 'case:12')
        M.RetryTick()
        assert_eq(deathOf('VICTIMCID').case_ref, nil)
    end)
end)

describe('register, release, revoke, exports, character deletion', function()
    it('the register lists bodies with names to staff in the morgue only', function()
        mark(ADMIN, VICTIM)
        local res = cb('morgueList', MEDIC)
        assert_true(res.ok)
        assert_eq(#res.list, 1)
        assert_eq(res.list[1].name, 'John Doe')
        assert_eq(res.list[1].state, 'intake')
        assert_eq(cb('morgueList', CIV).error, 'no_permission')
        Mock.coords[MEDIC] = OUTSIDE
        assert_eq(cb('morgueList', MEDIC).error, 'too_far')
    end)
    it('release only after the autopsy', function()
        mark(ADMIN, VICTIM)
        local id = deathOf('VICTIMCID').id
        assert_eq(cb('morgueRelease', MEDIC, id).error, 'invalid_state')
        assert_true(autopsy(id).ok)
        local res = cb('morgueRelease', MEDIC, id, 'Sunset Funeral Home')
        assert_true(res.ok)
        assert_eq(DB.deaths[id].state, 'released')
        assert_eq(DB.deaths[id].released_at, os.time())
        assert_eq(cb('morgueRelease', MEDIC, id).error, 'rate_limited')
        advance(2)
        assert_eq(cb('morgueRelease', MEDIC, id).error, 'invalid_state')
        assert_eq(#cb('morgueList', MEDIC).list, 0)
    end)
    it('an admin may revoke a mistaken mark before the autopsy only', function()
        mark(ADMIN, VICTIM)
        Commands.revokedeceased(CIV, { 'VICTIMCID', 'oops' })
        assert_eq(countDeaths(), 1, 'no ACE')
        Commands.revokedeceased(ADMIN, { 'VICTIMCID', 'wrong', 'player' })
        assert_eq(countDeaths(), 0)
        assert_false((M.IsDeceased('VICTIMCID')))
        assert_eq(#events('pf-ambulancejob:server:deathRevoked'), 1)
        mark(ADMIN, CIV)
        assert_true(autopsy(deathOf('CIVCID').id).ok)
        assert_eq(M.Revoke('CIVCID', { actor = { kind = 'admin' } }).error, 'invalid_state')
        assert_eq(countDeaths(), 1)
    end)
    it('GetDeathRecord is for the MDTs and courts only', function()
        mark(ADMIN, VICTIM)
        local id = deathOf('VICTIMCID').id
        Mock.invokingResource = 'pf-policemdt-DEV'
        local r = exports['pf-ambulancejob']:GetDeathRecord(id)
        assert_true(r.ok)
        assert_eq(r.record.cid, 'VICTIMCID')
        assert_eq(r.record.state, 'intake')
        Mock.invokingResource = 'pfm-phone'
        assert_eq(exports['pf-ambulancejob']:GetDeathRecord(id).error, 'not_allowed')
        Mock.invokingResource = 'pf-emsmdt'
        assert_eq(#exports['pf-ambulancejob']:ListDeathRecords('VICTIMCID').list, 1)
        Mock.invokingResource = nil
        assert_eq(#M.ListForCitizen('VICTIMCID'), 1)
    end)
    it('character deletion: unlinked records go; a record attached to a police case stays', function()
        mark(ADMIN, VICTIM)
        mark(ADMIN, CIV)
        assert_true(cb('morgueLinkCase', ME, deathOf('CIVCID').id, '12').ok)
        Mock.fireEvent('pfm-core:server:characterDeleted', VICTIM, 'VICTIMCID')
        assert_true(deathOf('VICTIMCID') ~= nil, 'a player cannot raise it')
        Mock.fireEvent('pfm-core:server:characterDeleted', nil, 'VICTIMCID')
        Mock.fireEvent('pfm-core:server:characterDeleted', nil, 'CIVCID')
        assert_eq(deathOf('VICTIMCID'), nil)
        assert_true(deathOf('CIVCID') ~= nil)
        assert_false((M.IsDeceased('VICTIMCID')))
    end)
    it('the injuries present at death are kept with the record, so a deleted character can still be examined', function()
        bleedToDeath('KILLERCID')
        mark(ADMIN, VICTIM)
        local d = deathOf('VICTIMCID')
        local snap = json.decode(d.findings).intake.injuries
        assert_eq(#snap, 1)
        assert_eq(snap[1].type, 'laceration')
        assert_eq(snap[1].attrs._fp, nil, 'no engine internals')
        assert_true(cb('morgueLinkCase', ME, d.id, '12').ok)
        -- the medical store deletes the injury rows with the character
        for id, r in pairs(DB.injuries) do if r.citizenid == 'VICTIMCID' then DB.injuries[id] = nil end end
        assert_true(autopsy(d.id).ok)
        d = deathOf('VICTIMCID')
        assert_true(d.cause:find('laceration', 1, true) ~= nil, d.cause)
        assert_eq(d.manner, 'homicide')
    end)
end)
