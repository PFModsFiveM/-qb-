-- pfm-policejob crime lab on a real database (batch 18, unit 18D): lab jobs from submission to a
-- released result, results only from server data (no identification without a reference sample,
-- partial quality -> a deterministic candidate set), ballistics test-fires, toxicology preserved
-- with the sample, the lab_tech release and the unreviewed fallback, the custody rows of every lab
-- step, /takedna swabs and known-sample comparison, projectiles from surgery, case lockers, legacy
-- bag registration, reconciliation of bags removed by ClearInventory, and court-order disposal
-- failing closed.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
local started = { ['pfm-inventory'] = true }
function GetResourceState(name) return started[name] and 'started' or 'missing' end
function GetCurrentResourceName() return 'pfm-policejob' end

load_resource('pfm-core/server/migrations.lua')
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end

-- ── a small pfm-inventory (players' items, stashes, listeners fired like the real one) ───────
local Inv = { stashes = {}, listeners = {}, opened = {} }
local function itemsOf(id)
    if type(id) == 'number' then return Mock.players[id] and Mock.players[id].PlayerData.items end
    return Inv.stashes[id] and Inv.stashes[id].items
end
local function fire(kind, ...)
    for _, fn in ipairs(Inv.listeners[kind] or {}) do fn(...) end
end
local function firstFree(items)
    local s = 1
    while items[s] do s = s + 1 end
    return s
end
local function invType(id) return type(id) == 'number' and 'player' or 'inventory' end
Mock.exportsByResource['pfm-inventory'] = {
    AddListener = function(_, kind, fn)
        Inv.listeners[kind] = Inv.listeners[kind] or {}
        table.insert(Inv.listeners[kind], fn)
        return #Inv.listeners[kind]
    end,
    AddItem = function(_, id, name, amount, slot, info)
        local items = itemsOf(id)
        if not items then return false end
        slot = tonumber(slot) or firstFree(items)
        if items[slot] then
            if items[slot].name ~= name then return false end
            items[slot].amount = items[slot].amount + (amount or 1)
        else
            items[slot] = { name = name, amount = amount or 1, slot = slot, info = info or {} }
        end
        fire('ItemAdded', 'item', { toId = id, toType = invType(id), toSlot = slot, item = items[slot], amount = amount or 1, resource = 'pfm-policejob' })
        return true
    end,
    RemoveItem = function(_, id, name, amount, slot)
        local items = itemsOf(id)
        if not items then return false end
        local it
        if slot then it = items[slot] else for _, v in pairs(items) do if v.name == name then it = v break end end end
        if not it or it.name ~= name or it.amount < (amount or 1) then return false end
        it.amount = it.amount - (amount or 1)
        if it.amount <= 0 then items[it.slot] = nil end
        fire('ItemRemoved', 'item', { fromId = id, fromType = invType(id), fromSlot = it.slot, item = it, amount = amount or 1, resource = 'pfm-policejob' })
        return true
    end,
    GetInventory = function(_, id) return Inv.stashes[id] end,
    CreateInventory = function(_, id, data) Inv.stashes[id] = Inv.stashes[id] or { items = {}, label = data and data.label } end,
    OpenInventory = function(_, src, id) Inv.opened[#Inv.opened + 1] = { src = src, id = id } end,
    SetItemData = function(_, src, name, key, val, slot)
        local it = itemsOf(src)[slot]
        if not it or it.name ~= name then return false end
        it[key] = val
        return true
    end,
}

-- lab techs (pf-government qualification) and the medical summary (toxins)
local techs = {}
Mock.exportsByResource['pf-government'] = {
    HasQualification = function(_, cid, qual) return qual == 'lab_tech' and techs[cid] == true, 'granted' end,
}
local toxins = {}
Mock.exportsByResource['pf-ambulancejob'] = {
    -- like pf-ambulancejob GetToxinLevels: only toxins above zero
    GetToxinLevels = function(_, src)
        local P = Mock.players[src]
        if not P then return { ok = false, error = 'offline' } end
        local out = {}
        for k, v in pairs(toxins[P.PlayerData.citizenid] or {}) do if v > 0 then out[k] = v end end
        return { ok = true, toxins = out }
    end,
}
local courtCalls, courtAnswer = {}, nil
Mock.exportsByResource['pf-justice'] = {
    IsCourtOrderValid = function(_, ref, purpose, cid, extra)
        courtCalls[#courtCalls + 1] = { ref = ref, purpose = purpose, cid = cid, extra = extra }
        return courtAnswer
    end,
}

QBCoreMock.Shared.Items.evidence_bag = { name = 'evidence_bag', label = 'Evidence Bag', weight = 200, type = 'item', unique = true }
QBCoreMock.Shared.Items.empty_evidence_bag = { name = 'empty_evidence_bag', label = 'Empty Evidence Bag', weight = 0, type = 'item' }
QBCoreMock.Shared.Items.filled_evidence_bag = { name = 'filled_evidence_bag', label = 'Evidence Bag', weight = 200, type = 'item', unique = true }
QBCoreMock.Shared.Items.nitrile_gloves = { name = 'nitrile_gloves', label = 'Nitrile Gloves', weight = 10, type = 'item' }
QBCoreMock.Shared.Items.meth = { name = 'meth', label = 'Meth', weight = 10, type = 'item' }
QBCoreMock.Shared.Weapons[GetHashKey('weapon_pistol')] = { name = 'weapon_pistol', label = 'Pistol', ammotype = 'AMMO_PISTOL' }
QBCoreMock.Functions.GetPlayersByJob = function(job, onDuty)
    local out = {}
    for src, P in pairs(Mock.players) do
        local j = P.PlayerData.job
        if (j.name == job or j.type == job) and (not onDuty or j.onduty) then out[#out + 1] = src end
    end
    table.sort(out)
    return out
end

QBCore = Mock.coreObject()
Config = nil
load_resource('pfm-policejob/config.lua')
load_resource('pfm-policejob/config_evidence.lua')
load_resource('pfm-policejob/server/schema.lua')
load_resource('pfm-policejob/server/commands.lua')
load_resource('pfm-policejob/server/evidence/store.lua')
load_resource('pfm-policejob/server/evidence/custody.lua')
load_resource('pfm-policejob/server/evidence/scene.lua')
load_resource('pfm-policejob/server/evidence/api.lua')
load_resource('pfm-policejob/server/evidence/lab.lua')
local E, Store, C, S, A, L = PFEvidence, PFEvidence.Store, PFEvidence.Custody, PFEvidence.Scene, PFEvidence.Api, PFEvidence.Lab
local EC = PoliceEvidenceCommands
assert_true(PFPoliceSchema.Run(), 'schema')
assert_true(A.Start(), 'evidence start')
assert_true(C.RegisterListeners(), 'listeners')
-- the lab tables are created by the resource's schema (v3, the batch-18 schema owner)
for _, t in ipairs({ 'pf_evidence_reference_samples', 'pf_evidence_test_fires', 'pf_evidence_lab_jobs' }) do
    assert_eq(tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?', { t })), 1, t)
end
MySQL.query.await([[CREATE TABLE IF NOT EXISTS players (citizenid VARCHAR(50) NOT NULL PRIMARY KEY, charinfo LONGTEXT NULL, metadata LONGTEXT NULL)]])

local COP, TECH, CIV, CIV2, SHOOTER, SARGE = 1, 2, 3, 4, 5, 6
local LAB = Config.Evidence.Labs.main.coords
local T0 = 1700000000

local function newCop(src, cid, grade, at)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.job = { name = 'police', type = 'leo', onduty = true, grade = { level = grade or 1 } }
    p.PlayerData.items = { [1] = { name = 'empty_evidence_bag', amount = 10, slot = 1, info = {} },
        [2] = { name = 'nitrile_gloves', amount = 1, slot = 2, info = {} } }
    Mock.coords[src] = at or vector3(0, 0, 0)
    return p
end
local function newCiv(src, cid, first, fp)
    local p = Mock.newPlayer(src, cid)
    p.PlayerData.metadata.bloodtype = 'A+'
    p.PlayerData.metadata.fingerprint = fp
    p.PlayerData.charinfo = { firstname = first, lastname = 'Doe' }
    Mock.coords[src] = vector3(1, 1, 0)
    MySQL.query.await('INSERT IGNORE INTO players (citizenid, charinfo, metadata) VALUES (?, ?, ?)',
        { cid, json.encode({ firstname = first, lastname = 'Doe' }), json.encode({ fingerprint = fp }) })
    return p
end
local function row(id) return MySQL.single.await('SELECT * FROM pf_evidence_items WHERE id = ?', { id }) end
local function eventNames(id)
    local out = {}
    for _, e in ipairs(MySQL.query.await('SELECT event FROM pf_evidence_custody WHERE evidence_id = ? ORDER BY id', { id })) do out[#out + 1] = e.event end
    return table.concat(out, ',')
end
local function bagIn(id, evidenceId)
    for _, it in pairs(itemsOf(id) or {}) do
        if it.name == 'evidence_bag' and it.info.evidenceId == evidenceId then return it end
    end
end

-- a scene drop left by `who`, bagged by COP (age in minutes before bagging)
local function collect(kind, who, ageMinutes, extra)
    Mock.gameTimer = Mock.gameTimer + 10000
    local drop = S.Report(who, kind, extra or { coords = Mock.coords[who] })
    assert(drop, 'drop reported')
    S.Flush()
    Mock.clock = Mock.clock + (ageMinutes or 0) * 60
    Mock.gameTimer = Mock.gameTimer + 10000
    local res = S.Collect(COP, kind, drop.id, { street = 'Main St' })
    assert(res.ok, 'collected: ' .. tostring(res.error))
    return res.evidenceId
end
local function toLab(id, src)
    src = src or COP
    local back = Mock.coords[src]
    Mock.coords[src] = LAB
    local res = A.TransferEvidence(id, { kind = 'lab', labId = 'main' }, { actor = { src = src } })
    Mock.coords[src] = back
    assert(res.ok, 'to lab: ' .. tostring(res.error))
end
local function asJustice(fn, ...)
    Mock.invokingResource = 'pf-justice'
    local r = table.pack(pcall(fn, ...))
    Mock.invokingResource = nil
    assert(r[1], tostring(r[2]))
    return r[2]
end
-- submits, lets the lab time pass, processes and releases as the lab tech; returns the released job
local function runTest(id, test)
    local sub = A.SubmitToLab(id, { test }, { actor = { src = COP } })
    assert(sub.ok, 'submit ' .. test .. ': ' .. tostring(sub.error) .. ' ' .. tostring(sub.message))
    Mock.clock = Mock.clock + Config.Evidence.Lab.Times[test] + 1
    L.Tick(Mock.clock)
    local rel = A.ReleaseLabResult(sub.jobId, { actor = { src = TECH } })
    assert(rel.ok, 'release: ' .. tostring(rel.error))
    return A.GetLabJob(sub.jobId, { viewer = COP }).job, sub
end

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords, Mock.aces = {}, {}, {}
    Mock.clock = T0
    Mock.gameTimer = Mock.gameTimer + 10000
    Inv.stashes, Inv.opened = {}, {}
    techs = { TECHCID = true }
    toxins, courtCalls, courtAnswer = {}, {}, nil
    started['pf-government'], started['pf-ambulancejob'], started['pf-justice'] = true, nil, nil
    newCop(COP, 'COPCID')
    newCop(TECH, 'TECHCID', 2, vector3(5, 5, 0))
    newCop(SARGE, 'SARGECID', 4, vector3(0, 1, 0))
    newCiv(CIV, 'CIVCID', 'Alice', 'FP-ALICE')
    newCiv(CIV2, 'CIV2CID', 'Bob', 'FP-BOB')
    newCiv(SHOOTER, 'SHOOTCID', 'Carl', 'FP-CARL')
    S.toxCache = {}
end

describe('lab jobs', function()
    it('need the evidence at a lab, a known test and an accepting kind; leaving the lab waits for the tests', function()
        local id = collect('blood', CIV)
        assert_eq(A.SubmitToLab(id, { 'dna' }, { actor = { src = COP } }).error, 'invalid_state', 'still in the field')
        toLab(id)
        assert_eq(A.SubmitToLab(id, { 'astrology' }, { actor = { src = COP } }).error, 'bad_args')
        assert_eq(A.SubmitToLab(id, { 'ballistics' }, { actor = { src = COP } }).error, 'bad_args', 'blood has no rifling')
        assert_eq(A.SubmitToLab(id, { 'tox' }, { actor = { src = COP } }).error, 'invalid_state', 'no toxicology preserved')
        assert_eq(A.SubmitToLab(id, { 'dna' }, { actor = { src = CIV } }).error, 'no_permission')
        local sub = A.SubmitToLab(id, { 'dna' }, { actor = { src = COP } })
        assert_true(sub.ok, tostring(sub.error))
        assert_eq(sub.eta, Mock.clock + Config.Evidence.Lab.Times.dna)
        assert_true(A.SubmitToLab(id, { 'dna' }, { actor = { src = COP } }).duplicate, 'one open job per test')
        local job = MySQL.single.await('SELECT * FROM pf_evidence_lab_jobs WHERE id = ?', { sub.jobId })
        assert_eq(job.state, 'queued')
        assert_eq(job.idem_key, ('pfm-policejob:lab:%d:dna:1'):format(id))
        Mock.coords[SARGE] = LAB
        assert_eq(A.TransferEvidence(id, { kind = 'officer', src = SARGE }, { actor = { src = SARGE } }).error, 'invalid_state', 'tests running')
        -- the lab time is real: nothing before ready_at
        assert_eq(L.Tick(Mock.clock + 10), 0)
        assert_eq(MySQL.scalar.await('SELECT state FROM pf_evidence_lab_jobs WHERE id = ?', { sub.jobId }), 'queued')
        -- an idempotency key from a caller returns the first job, and refuses another evidence
        local keyed = A.SubmitToLab(id, { 'dna' }, { key = 'mdt:req:1', actor = { src = COP } })
        assert_true(keyed.ok)
    end)
    it('a result waits for a lab tech; officers see it only once released; custody rows record each step', function()
        local id = collect('blood', CIV)
        toLab(id)
        local before = tonumber(row(id).integrity)
        local sub = A.SubmitToLab(id, 'dna', { actor = { src = COP } })
        Mock.clock = Mock.clock + Config.Evidence.Lab.Times.dna + 1
        assert_true(L.Tick(Mock.clock) >= 1)
        local seen = A.GetLabJob(sub.jobId, { viewer = COP }).job
        assert_eq(seen.state, 'ready')
        assert_eq(seen.result, nil, 'not released yet')
        local review = A.GetLabJob(sub.jobId, { viewer = TECH }).job
        assert_eq(review.result.outcome, 'no_match', 'no reference sample: no name')
        assert_eq(review.result._donor, nil, 'the true donor never leaves the server')
        assert_eq(A.ReleaseLabResult(sub.jobId, { actor = { src = COP } }).error, 'no_permission', 'not a lab tech')
        local rel = A.ReleaseLabResult(sub.jobId, { actor = { src = TECH } })
        assert_true(rel.ok, tostring(rel.error))
        assert_true(A.ReleaseLabResult(sub.jobId, { actor = { src = TECH } }).duplicate)
        local job = A.GetLabJob(sub.jobId, { viewer = COP }).job
        assert_eq(job.state, 'released')
        assert_eq(job.reviewedBy, 'TECHCID')
        assert_eq(job.result.bloodtype, 'A+')
        assert_eq(row(id).state, 'analysed')
        assert_eq(eventNames(id), 'collected,sealed,submitted_lab,lab_requested,seal_broken,sealed,lab_result,analysed,lab_released')
        assert_eq(tonumber(row(id).integrity), before, 'a lab seal break costs no integrity')
        local done = 0
        for _, e in ipairs(Mock.serverEvents) do if e.name == 'pfm-policejob:server:labCompleted' then done = done + 1 end end
        assert_eq(done, 1)
        local ev = A.GetEvidence(id, { viewer = COP })
        assert_eq(#ev.labs, 1)
        assert_eq(ev.labs[1].result.outcome, 'no_match')
    end)
    it('identifies only against a reference sample registered by booking (DNA brings the booking prints)', function()
        local id = collect('blood', CIV)
        toLab(id)
        assert_eq(runTest(id, 'dna').result.outcome, 'no_match')
        Mock.invokingResource = 'random-script'
        assert_eq(A.RegisterReferenceSample('CIVCID', 'dna', { custodyId = 7 }).error, 'not_allowed')
        Mock.invokingResource = nil
        local reg = asJustice(A.RegisterReferenceSample, 'CIVCID', 'dna', { custodyId = 7, sampleRef = 'TOKEN-ALICE', bookingNo = 'BK-1' }, { key = 'pf-justice:booking:7:dna' })
        assert_true(reg.ok, tostring(reg.error))
        assert_eq(reg.printsRef, 'FP-ALICE', 'booking prints from the server metadata')
        assert_true(asJustice(A.RegisterReferenceSample, 'CIVCID', 'dna', { custodyId = 7, sampleRef = 'TOKEN-ALICE' }).duplicate)
        assert_eq(asJustice(A.RegisterReferenceSample, 'CIV2CID', 'dna', { custodyId = 8, sampleRef = 'TOKEN-ALICE' }).error, 'key_reused')
        assert_eq(asJustice(A.RegisterReferenceSample, 'CIVCID', 'dna', {}).error, 'bad_args')
        local job = runTest(id, 'dna')
        assert_eq(job.result.outcome, 'match')
        assert_eq(job.result.identified.citizenid, 'CIVCID')
        assert_eq(job.result.identified.name, 'Alice Doe')
        assert_eq(job.result.identified.source, 'custody:7')
        assert_eq(job.result.randomMatch, '1 in 1,000,000,000')
    end)
    it('a degraded sample is only consistent with a candidate set, the same set every time', function()
        for i, who in ipairs({ { 'CIVCID', 'T-A' }, { 'CIV2CID', 'T-B' }, { 'SHOOTCID', 'T-C' }, { 'X1', 'T-D' }, { 'X2', 'T-E' } }) do
            asJustice(A.RegisterReferenceSample, who[1], 'dna', { custodyId = 100 + i, sampleRef = who[2] })
        end
        local id = collect('blood', CIV, 61) -- older than DegradeMinutes: partial quality 50
        assert_eq(tonumber(row(id).quality), 50)
        toLab(id)
        local first = runTest(id, 'dna').result
        assert_eq(first.outcome, 'consistent_with')
        assert_eq(first.profile, 'partial')
        assert_eq(first.candidateCount, 4, 'the donor and three references that cannot be excluded (quality 50)')
        local cids, hasDonor = {}, false
        for _, c in ipairs(first.candidates) do
            cids[#cids + 1] = c.citizenid
            if c.citizenid == 'CIVCID' then hasDonor = true end
        end
        assert_true(hasDonor)
        assert_eq(first.identified, nil, 'never an identification')
        local again = runTest(id, 'dna').result
        local cids2 = {}
        for _, c in ipairs(again.candidates) do cids2[#cids2 + 1] = c.citizenid end
        assert_eq(table.concat(cids2, ','), table.concat(cids, ','), 'resubmitting cannot fish')
        -- below MinQuality nothing at all
        local dead = collect('blood', CIV2)
        MySQL.update.await('UPDATE pf_evidence_items SET quality = 10 WHERE id = ?', { dead })
        toLab(dead)
        assert_eq(runTest(dead, 'dna').result.outcome, 'no_result')
    end)
    it('prints: collected without gloves the ridge detail suffers; a full lift matches the booking prints', function()
        asJustice(A.RegisterReferenceSample, 'CIV2CID', 'prints', { custodyId = 9 })
        local gloved = collect('fingerprint', CIV2)
        toLab(gloved)
        local r = runTest(gloved, 'prints').result
        assert_eq(r.outcome, 'match')
        assert_eq(r.identified.citizenid, 'CIV2CID')
        Mock.players[COP].PlayerData.items[2] = nil
        local bare = collect('fingerprint', CIV2)
        assert_eq(row(bare).flags, 'contaminated')
        MySQL.update.await('UPDATE pf_evidence_items SET quality = 80 WHERE id = ?', { bare })
        toLab(bare)
        local smudged = runTest(bare, 'prints').result
        assert_eq(smudged.quality, 55)
        assert_eq(smudged.outcome, 'consistent_with')
        assert_true(smudged.notes[1]:find('without gloves') ~= nil)
    end)
end)

describe('ballistics', function()
    it('a casing matches only after the seized weapon is test-fired', function()
        local hash = GetHashKey('weapon_pistol')
        Mock.players[SHOOTER].PlayerData.items = { [1] = { name = 'weapon_pistol', slot = 1, amount = 1, info = { serie = 'SER123' } } }
        local casing = collect('casing', SHOOTER, 0, { weapon = hash, coords = Mock.coords[SHOOTER] })
        assert_eq(json.decode(row(casing).attrs).serial, 'SER123')
        toLab(casing)
        local first = runTest(casing, 'ballistics').result
        assert_eq(first.outcome, 'no_match')
        assert_eq(first.class.weapon, 'Pistol')
        -- the weapon is seized and test-fired at the lab
        local gun = A.CreateEvidence({ kind = 'weapon', label = 'Pistol', attrs = { item = 'weapon_pistol', serial = 'SER123' }, method = 'seizure' },
            { actor = { src = COP }, giveTo = COP })
        assert_true(gun.ok, tostring(gun.error))
        toLab(gun.evidenceId)
        local fired = runTest(gun.evidenceId, 'ballistics').result
        assert_eq(fired.outcome, 'test_fired')
        assert_eq(fired.matches[1], row(casing).tag, 'the casing on file was fired by it')
        local tf = MySQL.single.await('SELECT * FROM pf_evidence_test_fires WHERE weapon_serial = ?', { 'SER123' })
        assert_eq(tonumber(tf.evidence_id), gun.evidenceId)
        assert_eq(tonumber(tf.weapon_hash), hash % 4294967296)
        assert_true(eventNames(gun.evidenceId):find('lab_result') ~= nil)
        local second = runTest(casing, 'ballistics').result
        assert_eq(second.outcome, 'match')
        assert_eq(second.weapon.tag, row(gun.evidenceId).tag)
        -- a deformed projectile only shows class characteristics
        local proj = A.CreateEvidence({ kind = 'projectile', attrs = { weaponHash = hash, serial = 'SER123' }, method = 'manual' }, { actor = { src = COP }, giveTo = COP })
        MySQL.update.await('UPDATE pf_evidence_items SET quality = 40 WHERE id = ?', { proj.evidenceId })
        toLab(proj.evidenceId)
        local deformed = runTest(proj.evidenceId, 'ballistics').result
        assert_eq(deformed.outcome, 'consistent_with')
        assert_eq(deformed.candidateCount, 1)
    end)
end)

describe('toxicology and drugs', function()
    it('tox reads the levels preserved when the blood was left; drug_id names controlled items', function()
        started['pf-ambulancejob'] = true
        toxins.CIVCID = { ethanol = 0.12, opioid = 0 }
        local id = collect('blood', CIV)
        assert_eq(json.decode(row(id).attrs).tox, nil, 'not on the evidence item')
        toLab(id)
        local r = runTest(id, 'tox').result
        assert_eq(r.outcome, 'positive')
        assert_eq(#r.findings, 1)
        assert_eq(r.findings[1].toxin, 'ethanol')
        local drug = A.CreateEvidence({ kind = 'drug', attrs = { item = 'meth', amount = 4 }, method = 'seizure' }, { actor = { src = COP }, giveTo = COP })
        toLab(drug.evidenceId)
        local d = runTest(drug.evidenceId, 'drug_id').result
        assert_eq(d.outcome, 'identified')
        assert_eq(d.substance, 'Meth')
        local food = A.CreateEvidence({ kind = 'item', attrs = { item = 'sandwich', amount = 1 }, method = 'seizure' }, { actor = { src = COP }, giveTo = COP })
        toLab(food.evidenceId)
        assert_eq(runTest(food.evidenceId, 'drug_id').result.outcome, 'negative')
    end)
end)

describe('swabs and known samples', function()
    it('/takedna needs a restrained person within 2.5 m and makes a dna_swab with a sample id', function()
        assert_false(EC.TakeDna(COP, { tostring(CIV) }), 'not restrained')
        Mock.players[CIV].PlayerData.metadata.ishandcuffed = true
        Mock.coords[CIV] = vector3(5, 0, 0)
        assert_false(EC.TakeDna(COP, { tostring(CIV) }), 'too far')
        Mock.coords[CIV] = vector3(1, 1, 0)
        assert_false(EC.TakeDna(CIV2, { tostring(CIV) }), 'civilians cannot')
        Mock.gameTimer = Mock.gameTimer + 10000 -- past the command rate limit
        local res = EC.TakeDna(COP, { tostring(CIV) })
        assert_true(res and res.ok)
        local r = row(res.evidenceId)
        assert_eq(r.kind, 'dna_swab')
        assert_eq(r.origin_type, 'person')
        assert_eq(r.origin_id, 'CIVCID')
        local attrs = json.decode(r.attrs)
        assert_eq(attrs.sampleId:sub(1, 2), 'D-')
        assert_true(not r.attrs:find('CIVCID'), 'the bag does not carry the citizen id')
        local bag = bagIn(COP, res.evidenceId)
        assert_true(bag ~= nil)
        assert_eq(bag.info.dnalabel, nil, 'no hex citizen id on the bag')
        assert_eq(Mock.players[COP].PlayerData.items[1].amount, 9, 'one empty bag used')
    end)
    it('a known swab and scene blood in the same case come from the same source', function()
        local DAN = 7
        newCiv(DAN, 'DANCID', 'Dan', 'FP-DAN') -- nobody has registered a reference for Dan
        Mock.players[DAN].PlayerData.metadata.ishandcuffed = true
        local swab = EC.TakeDna(COP, { tostring(DAN) }).evidenceId
        local blood = collect('blood', DAN)
        for _, id in ipairs({ swab, blood }) do
            assert_true(A.LinkEvidence(id, { type = 'case', id = 'C-9' }, { actor = { src = COP } }).ok)
            toLab(id)
        end
        local known = runTest(swab, 'dna').result
        assert_eq(known.outcome, 'known_sample')
        assert_eq(known.collectedFrom.citizenid, 'DANCID')
        local scene = runTest(blood, 'dna').result
        assert_eq(scene.outcome, 'no_match', 'no database reference')
        assert_eq(scene.sameSourceAs[1].tag, row(swab).tag)
        assert_eq(scene.sameSourceAs[1].strength, 'same_source')
    end)
end)

describe('projectiles from surgery', function()
    it('are sealed into the surgery locker once per injury, with a deformed quality', function()
        local p = { injuryId = 'INJ-77', caliber = '9mm', weaponHash = GetHashKey('weapon_pistol'), weaponSerial = 'SER9', byCid = 'DOC', at = T0 }
        Mock.invokingResource = 'some-script'
        TriggerEvent('pf-ambulancejob:server:projectileRecovered', 'CIVCID', p)
        Mock.invokingResource = 'pf-ambulancejob'
        TriggerEvent('pf-ambulancejob:server:projectileRecovered', 'CIVCID', p)
        TriggerEvent('pf-ambulancejob:server:projectileRecovered', 'CIVCID', p)
        Mock.invokingResource = nil
        local rows = MySQL.query.await("SELECT * FROM pf_evidence_items WHERE idem_key = 'pf-ambulancejob:projectile:INJ-77'")
        assert_eq(#rows, 1, 'one per injury, never from another resource')
        local r = rows[1]
        assert_eq(r.kind, 'projectile')
        assert_eq(tonumber(r.quality), 80)
        assert_eq(r.holder_kind, 'locker')
        assert_eq(r.holder_ref, 'inv:evl:pillbox:surgery')
        assert_true(bagIn('evl:pillbox:surgery', tonumber(r.id)) ~= nil)
        -- police collect it at the hospital locker only
        local locker = MySQL.single.await("SELECT id FROM pf_evidence_lockers WHERE stash_id = 'evl:pillbox:surgery'")
        assert_eq(L.OpenLocker(COP, tonumber(locker.id)).error, 'too_far')
        Mock.coords[COP] = Config.Evidence.LockerStations.pillbox.coords
        assert_true(L.OpenLocker(COP, tonumber(locker.id)).ok)
        assert_eq(Inv.opened[#Inv.opened].id, 'evl:pillbox:surgery')
        Mock.coords[COP] = vector3(0, 0, 0)
    end)
end)

describe('case lockers', function()
    it('one stash per case per station; check-in through TransferEvidence is recorded', function()
        assert_eq(A.CreateEvidenceLocker({ type = 'case', id = 'C-1' }, { actor = { src = COP } }).error, 'too_far')
        local station = Config.Locations.evidence[2]
        Mock.coords[COP] = vector3(station.x, station.y, station.z)
        local res = A.CreateEvidenceLocker({ type = 'case', id = 'C-1' }, { actor = { src = COP } })
        assert_true(res.ok, tostring(res.error))
        assert_eq(res.stashId, 'evl:2:case:C-1')
        assert_true(A.CreateEvidenceLocker({ type = 'case', id = 'C-1' }, { actor = { src = COP } }).existing)
        assert_eq(A.CreateEvidenceLocker({ type = 'case', id = 'C-1' }, { actor = { src = CIV } }).error, 'no_permission')
        Mock.coords[COP] = vector3(0, 0, 0)
        local id = collect('blood', CIV)
        Mock.coords[COP] = vector3(station.x, station.y, station.z)
        local moved = A.TransferEvidence(id, { kind = 'locker', lockerId = res.lockerId }, { actor = { src = COP } })
        assert_true(moved.ok, tostring(moved.error))
        assert_eq(row(id).holder_kind, 'locker')
        assert_eq(row(id).state, 'stored')
        assert_true(bagIn('evl:2:case:C-1', id) ~= nil)
        assert_true(eventNames(id):find('checked_in') ~= nil)
    end)
end)

describe('legacy bags', function()
    it('are registered at a station with an unverified chain; an old blood label still leads to the donor', function()
        local hex = ('CIVCID'):gsub('.', function(c) return ('%02x'):format(c:byte()) end)
        Mock.players[COP].PlayerData.items[5] = { name = 'filled_evidence_bag', slot = 5, amount = 1,
            info = { type = 'blood', dnalabel = hex, bloodtype = 'A+', street = 'Old Rd' } }
        assert_eq(EC.RegisterBag(COP, { '5' }), nil, 'not at a station')
        Mock.coords[COP] = LAB
        local res = EC.RegisterBag(COP, { '5' })
        assert_true(res and res.ok, tostring(res and res.error))
        assert_eq(Mock.players[COP].PlayerData.items[5], nil, 'the old bag is gone')
        assert_true(bagIn(COP, res.evidenceId) ~= nil, 'a recorded bag instead')
        local r = row(res.evidenceId)
        assert_eq(r.method, 'registered')
        assert_eq(r.origin_type, 'scene_drop')
        assert_true(not r.attrs:find(hex), 'the hex label is gone')
        local drop = MySQL.single.await('SELECT * FROM pf_evidence_scene_drops WHERE id = ?', { tonumber(r.origin_id) })
        assert_eq(drop.source_cid, 'CIVCID')
        assert_eq(drop.state, 'collected')
        local ev = A.GetEvidence(res.evidenceId, { viewer = COP })
        assert_eq(ev.integrity.score, 80)
        assert_eq(table.concat(ev.integrity.flags, ','), 'unverified_chain')
        asJustice(A.RegisterReferenceSample, 'CIVCID', 'dna', { custodyId = 3, sampleRef = 'T-OLD' })
        Mock.coords[COP] = vector3(0, 0, 0)
        toLab(res.evidenceId)
        local job = runTest(res.evidenceId, 'dna').result
        assert_eq(job.outcome, 'match')
        assert_true(job.notes[#job.notes]:find('legacy') ~= nil)
    end)
end)

describe('bags removed without an inventory event (ClearInventory)', function()
    it('are found in the prison property list or flagged missing, and the gap costs integrity', function()
        local a = collect('blood', CIV)
        local b = collect('blood', CIV)
        assert_true(A.TransferEvidence(a, { kind = 'officer', src = SARGE }, { actor = { src = COP } }).ok)
        -- the holder's inventory is cleared the way pfm-prison does it: items copied to jailitems, no listener
        local P = Mock.players[SARGE]
        P.PlayerData.metadata.jailitems = { bagIn(SARGE, a) }
        P.PlayerData.items = {}
        Mock.players[COP].PlayerData.items = { [1] = Mock.players[COP].PlayerData.items[1] }
        assert_eq(C.Reconcile(), 0, 'one pass is not enough (a move may be in flight)')
        assert_true(C.Reconcile() >= 2) -- bags of earlier examples the cleared officer held count too
        assert_eq(row(a).holder_ref, 'inv:jailitems:SARGECID')
        assert_eq(row(b).holder_ref, 'unknown')
        local last = MySQL.single.await('SELECT event, note FROM pf_evidence_custody WHERE evidence_id = ? ORDER BY id DESC LIMIT 1', { a })
        assert_eq(last.event, 'moved')
        assert_true(last.note:find('prison property') ~= nil)
        assert_eq(MySQL.single.await('SELECT event FROM pf_evidence_custody WHERE evidence_id = ? ORDER BY id DESC LIMIT 1', { b }).event, 'flagged_missing')
        Mock.clock = Mock.clock + 31 * 60
        assert_eq(A.GetEvidence(a, { viewer = COP }).integrity.score, 80, 'the gap shows')
        assert_eq(C.Reconcile(), 0, 'recorded once')
    end)
end)

describe('the unreviewed fallback and the evidence leaving the lab', function()
    it('a result nobody reviewed is released after AutoReleaseHours, marked unreviewed', function()
        local id = collect('blood', CIV)
        toLab(id)
        local sub = A.SubmitToLab(id, { 'dna' }, { actor = { src = COP } })
        Mock.clock = Mock.clock + Config.Evidence.Lab.Times.dna + 1
        L.Tick(Mock.clock)
        Mock.clock = Mock.clock + 23 * 3600
        L.Tick(Mock.clock)
        assert_eq(A.GetLabJob(sub.jobId, { viewer = COP }).job.state, 'ready')
        Mock.clock = Mock.clock + 2 * 3600
        L.Tick(Mock.clock)
        local job = A.GetLabJob(sub.jobId, { viewer = COP }).job
        assert_eq(job.state, 'released')
        assert_eq(job.reviewedBy, 'unreviewed')
        assert_true(job.result.unreviewed)
    end)
    it('a job whose evidence is no longer at the lab fails instead of inventing a result', function()
        local id = collect('blood', CIV)
        toLab(id)
        local sub = A.SubmitToLab(id, { 'dna' }, { actor = { src = COP } })
        MySQL.update.await("UPDATE pf_evidence_items SET holder_kind = 'officer', holder_ref = 'player:COPCID', state = 'in_transit' WHERE id = ?", { id })
        Mock.clock = Mock.clock + Config.Evidence.Lab.Times.dna + 1
        L.Tick(Mock.clock)
        local job = A.GetLabJob(sub.jobId, { viewer = COP }).job
        assert_eq(job.state, 'failed')
        assert_true(eventNames(id):find('lab_failed') ~= nil)
    end)
end)

describe('disposal under a court order', function()
    it('fails closed until pf-justice confirms the order; the call names purpose, citizen and evidence', function()
        local id = collect('blood', CIV)
        local res = A.DisposeEvidence(id, 'destroy', { courtOrderId = 'CO-1', actor = { src = SARGE } })
        assert_eq(res.error, 'no_permission', 'pf-justice not running')
        started['pf-justice'] = true
        assert_eq(A.DisposeEvidence(id, 'destroy', { courtOrderId = 'CO-1', actor = { src = SARGE } }).error, 'no_permission', 'no answer')
        courtAnswer = false
        assert_eq(A.DisposeEvidence(id, 'destroy', { courtOrderId = 'CO-1', actor = { src = SARGE } }).error, 'no_permission')
        courtAnswer = true
        assert_true(A.DisposeEvidence(id, 'destroy', { courtOrderId = 'CO-1', actor = { src = SARGE } }).ok)
        local call = courtCalls[#courtCalls]
        assert_eq(call.ref, 'CO-1')
        assert_eq(call.purpose, 'evidence_destroy')
        assert_eq(call.extra.evidenceId, id)
        assert_eq(row(id).state, 'destroyed')
    end)
end)

describe('in-game commands (pfm-core calls them through a funcref)', function()
    it('/takedna, /labsubmit, /labresult, /labrelease, /evlocker and /registerbag work with pfm-core as the invoker', function()
        local function tick() Mock.gameTimer = Mock.gameTimer + 100000 end -- past the command rate limit
        Mock.invokingResource = 'pfm-core'
        local ok, err = pcall(function()
            Mock.players[CIV].PlayerData.metadata.ishandcuffed = true
            local swab = EC.TakeDna(COP, { tostring(CIV) })
            assert_true(type(swab) == 'table' and swab.ok, '/takedna: ' .. tostring(type(swab) == 'table' and swab.error))
            assert_eq(Mock.players[COP].PlayerData.items[1].amount, 9, 'the bag is used, not refunded')
            Mock.invokingResource = nil
            toLab(swab.evidenceId)
            Mock.invokingResource = 'pfm-core'
            tick()
            local sub = EC.LabSubmit(COP, { row(swab.evidenceId).tag, 'dna' })
            assert_true(type(sub) == 'table' and sub.ok, '/labsubmit')
            Mock.clock = Mock.clock + Config.Evidence.Lab.Times.dna + 1
            L.Tick(Mock.clock)
            tick()
            local review = EC.LabResult(TECH, { tostring(sub.jobId) })
            assert_true(type(review) == 'table' and review.ok, '/labresult')
            assert_eq(review.job.result.outcome, 'known_sample', 'the lab tech sees the result to review')
            tick()
            local rel = EC.LabRelease(TECH, { tostring(sub.jobId) })
            assert_true(type(rel) == 'table' and rel.ok, '/labrelease')
            tick()
            local station = Config.Locations.evidence[3]
            Mock.coords[COP] = vector3(station.x, station.y, station.z)
            local opened = EC.EvidenceLocker(COP, { 'case', 'C-77' })
            assert_true(type(opened) == 'table' and opened.ok, '/evlocker')
            assert_eq(Inv.opened[#Inv.opened].id, 'evl:3:case:C-77')
            tick()
            Mock.players[COP].PlayerData.items[6] = { name = 'filled_evidence_bag', slot = 6, amount = 1, info = { type = 'fingerprint', fingerprint = 'FP-ALICE' } }
            local reg = EC.RegisterBag(COP, { '6' })
            assert_true(type(reg) == 'table' and reg.ok, '/registerbag')
        end)
        Mock.invokingResource = nil
        Mock.coords[COP] = vector3(0, 0, 0)
        if not ok then error(err, 0) end
    end)
end)
