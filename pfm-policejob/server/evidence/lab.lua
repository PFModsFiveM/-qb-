-- Crime lab (architecture 4.9, batch 18): lab jobs, reference samples, test-fires and matching.
--
-- Everything a result says comes from server data, never from a client or from a guess:
--   * who left a biological sample: the scene-drop row the server wrote when it was left
--     (pf_evidence_scene_drops.source_cid), or the person a known sample was swabbed from (origin
--     person:<cid>). That is only the truth the lab measures against: a name is reported only when a
--     reference sample (booking or warrant, pf_evidence_reference_samples) exists for that person.
--   * fingerprints: the lift's print id against booking print references.
--   * ballistics: the serial the server read from the shooter's inventory when the casing fell,
--     against test-fires of seized weapons (pf_evidence_test_fires).
--   * toxicology: the toxin levels preserved with the blood when it left the body (drop row only).
-- Quality decides how far a result goes: a full profile identifies, a partial one is only
-- consistent with a small candidate set (the true donor, when referenced, among other references
-- picked deterministically per sample, so resubmitting cannot fish for a better answer), a degraded
-- one gives nothing. Contamination (no gloves) and the chain-of-custody flags are part of the report.
--
-- Lifecycle of a job: queued (ready_at = now + test time) -> processing (claimed by the tick) ->
-- ready (result computed, visible to lab techs) -> released (by a pf-government 'lab_tech', or by
-- the system after Lab.AutoReleaseHours, marked unreviewed) | failed (the evidence left the lab).
-- Every step writes a custody row on the evidence. Server-only event on release:
--   pfm-policejob:server:labCompleted(job)

PFEvidence = PFEvidence or {}
local E = PFEvidence
E.Lab = E.Lab or {}
local L = E.Lab
local Store, C = E.Store, E.Custody

local function lc(key, default)
    local v = (E.Cfg().Lab or {})[key]
    if v == nil then return default end
    return v
end

L.TESTS = { dna = true, prints = true, ballistics = true, tox = true, drug_id = true, gsr = true, trace = true }
L.OPEN_STATES = "('queued', 'processing')"

local JOB_COLS = 'id, evidence_id, test, state, requested_by, tech_cid, result, requested_at, ready_at, released_at, idem_key'
L.SQL = {
    insertJob = [[INSERT INTO pf_evidence_lab_jobs (evidence_id, test, state, requested_by, requested_at, ready_at, idem_key)
        VALUES (?, ?, 'queued', ?, ?, ?, ?)]],
    jobById = 'SELECT ' .. JOB_COLS .. ' FROM pf_evidence_lab_jobs WHERE id = ? LIMIT 1',
    jobByKey = 'SELECT ' .. JOB_COLS .. ' FROM pf_evidence_lab_jobs WHERE idem_key = ? LIMIT 1',
    openJob = 'SELECT ' .. JOB_COLS .. " FROM pf_evidence_lab_jobs WHERE evidence_id = ? AND test = ? AND state IN ('queued', 'processing', 'ready') ORDER BY id LIMIT 1",
    countJobs = 'SELECT COUNT(*) FROM pf_evidence_lab_jobs WHERE evidence_id = ? AND test = ?',
    openWork = "SELECT COUNT(*) FROM pf_evidence_lab_jobs WHERE evidence_id = ? AND state IN ('queued', 'processing')",
    jobsOf = 'SELECT ' .. JOB_COLS .. ' FROM pf_evidence_lab_jobs WHERE evidence_id = ? ORDER BY id LIMIT 50',
    due = 'SELECT ' .. JOB_COLS .. " FROM pf_evidence_lab_jobs WHERE state = 'queued' AND ready_at <= ? ORDER BY ready_at, id LIMIT ?",
    claim = "UPDATE pf_evidence_lab_jobs SET state = 'processing' WHERE id = ? AND state = 'queued'",
    finish = "UPDATE pf_evidence_lab_jobs SET state = ?, result = ? WHERE id = ? AND state = 'processing'",
    unstick = "UPDATE pf_evidence_lab_jobs SET state = 'queued' WHERE state = 'processing' AND ready_at <= ?",
    release = "UPDATE pf_evidence_lab_jobs SET state = 'released', tech_cid = ?, released_at = ?, result = ? WHERE id = ? AND state = 'ready'",
    unreviewed = 'SELECT ' .. JOB_COLS .. " FROM pf_evidence_lab_jobs WHERE state = 'ready' AND ready_at <= ? ORDER BY ready_at, id LIMIT ?",

    refInsert = [[INSERT IGNORE INTO pf_evidence_reference_samples (citizenid, kind, sample_ref, source_type, source_id, at)
        VALUES (?, ?, ?, ?, ?, ?)]],
    refBySample = 'SELECT id, citizenid, kind, sample_ref, source_type, source_id, at FROM pf_evidence_reference_samples WHERE kind = ? AND sample_ref = ? LIMIT 1',
    refByCid = 'SELECT id, citizenid, kind, sample_ref, source_type, source_id, at FROM pf_evidence_reference_samples WHERE kind = ? AND citizenid = ? ORDER BY id LIMIT 1',
    -- other references a partial profile cannot exclude: picked by a hash of the sample, so the same
    -- sample always gives the same set
    decoys = [[SELECT citizenid, MIN(sample_ref) AS sample_ref FROM pf_evidence_reference_samples WHERE kind = ? AND citizenid <> ?
        GROUP BY citizenid ORDER BY CRC32(CONCAT(?, citizenid)), citizenid LIMIT ?]],

    tfInsert = 'INSERT IGNORE INTO pf_evidence_test_fires (weapon_serial, weapon_hash, evidence_id, by_cid, at) VALUES (?, ?, ?, ?, ?)',
    tfBySerial = 'SELECT id, weapon_serial, weapon_hash, evidence_id, by_cid, at FROM pf_evidence_test_fires WHERE weapon_serial = ? LIMIT 1',
    tfByHash = 'SELECT id, weapon_serial, weapon_hash, evidence_id, by_cid, at FROM pf_evidence_test_fires WHERE weapon_hash = ? ORDER BY id LIMIT 20',
    -- analysed casings/projectiles fired by the weapon with this serial (the ballistics database)
    firedBy = [[SELECT i.id, i.tag FROM pf_evidence_items i JOIN pf_evidence_lab_jobs j ON j.evidence_id = i.id
        AND j.test = 'ballistics' AND j.state IN ('ready', 'released')
        WHERE i.kind IN ('casing', 'projectile') AND i.attrs LIKE ? ESCAPE '!' AND i.id <> ? GROUP BY i.id, i.tag ORDER BY i.id LIMIT 20]],
    -- analysed results of other evidence in the same case
    caseResults = [[SELECT i.id, i.tag, j.result FROM pf_evidence_items i JOIN pf_evidence_lab_jobs j ON j.evidence_id = i.id
        WHERE j.test IN ('dna', 'trace') AND j.state IN ('ready', 'released') AND i.id <> ? AND i.case_refs LIKE ? ESCAPE '!'
        ORDER BY j.id LIMIT 50]],
    tagOf = 'SELECT tag FROM pf_evidence_items WHERE id = ? LIMIT 1',
}

local function q(kind, sql, params) return Store.Query(kind, sql, params) end

local function decode(s)
    if type(s) == 'table' then return s end
    local v = type(s) == 'string' and json.decode(s) or nil
    return type(v) == 'table' and v or {}
end

local function likeEscape(s) return (s:gsub('[!%%_]', '!%0')) end

--- Weapon hashes are kept unsigned (GetHashKey is signed, inventories and configs mix both).
function L.U32(h)
    h = tonumber(h)
    if not h or h ~= h then return nil end
    return math.floor(h) % 4294967296
end

--- A deterministic order for candidate lists: plain arithmetic (no bit operations), so it gives
--- the same numbers on FiveM's Lua 5.4 and on 32-bit-integer test VMs.
function L.Hash(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 16777213 end
    return h
end

-- ── people ────────────────────────────────────────────────────────────────────────────────────
--- A citizen's name from the online player or the players table (nil when unknown).
function L.NameOf(cid)
    local P = exports['pfm-core']:GetPlayerByCitizenId(cid)
    local ci = P and P.PlayerData and P.PlayerData.charinfo
    if not ci then
        local row = q('single', 'SELECT charinfo FROM players WHERE citizenid = ? LIMIT 1', { cid })
        ci = row and decode(row.charinfo) or nil
    end
    if type(ci) ~= 'table' then return nil end
    local name = ((ci.firstname or '') .. ' ' .. (ci.lastname or '')):gsub('^%s+', ''):gsub('%s+$', '')
    return name ~= '' and name:sub(1, 64) or nil
end

--- A citizen's fingerprint id from server metadata (online player, else the players table).
function L.FingerprintOf(cid)
    local P = exports['pfm-core']:GetPlayerByCitizenId(cid)
    local meta = P and P.PlayerData and P.PlayerData.metadata
    if not meta then
        local row = q('single', 'SELECT metadata FROM players WHERE citizenid = ? LIMIT 1', { cid })
        meta = row and decode(row.metadata) or nil
    end
    return type(meta) == 'table' and E.Ref(meta.fingerprint, 64) or nil
end

local function person(cid)
    return { citizenid = cid, name = L.NameOf(cid) }
end

-- ── what the server knows about a sample ──────────────────────────────────────────────────────
--- { donor = cid?, private = attrs of the drop row? } from the evidence origin.
function L.SourceOf(row)
    if row.origin_type == 'scene_drop' and E.Scene then
        local src = E.Scene.SourceOf(row.origin_id)
        if src then return { donor = src.cid, private = src.attrs or {} } end
        return {}
    end
    if row.origin_type == 'person' then return { donor = E.Ref(row.origin_id, 64), known = true } end
    return {}
end

--- Effective quality for a test, and the notes that explain it.
function L.Quality(row, test, attrs)
    local q0 = tonumber(row.quality) or 100
    if (row.kind == 'fingerprint' or row.kind == 'dna_swab') and tonumber(attrs.quality) then q0 = math.min(q0, tonumber(attrs.quality)) end
    local notes = {}
    local flags = {}
    for f in tostring(row.flags or ''):gmatch('[%w_]+') do flags[f] = true end
    if flags.contaminated and (test == 'dna' or test == 'prints' or test == 'trace') then
        q0 = q0 - lc('ContaminationPenalty', 25)
        notes[#notes + 1] = test == 'prints' and 'Collected without gloves: ridge detail smudged' or 'Collected without gloves: mixed profile'
    end
    if test == 'trace' then q0 = math.min(q0, lc('TraceQuality', 45)) end
    if q0 < 0 then q0 = 0 elseif q0 > 100 then q0 = 100 end
    return math.floor(q0), notes
end

-- ── identification (DNA, prints, touch DNA) ───────────────────────────────────────────────────
local function randomMatchText(test, quality)
    if test == 'prints' then
        return ('%d matching minutiae'):format(math.max(0, math.floor(quality / 6)))
    end
    -- one in 10^(quality/10), capped at one in a billion for a full profile
    local exp = math.min(9, math.max(1, math.floor(quality / 10)))
    local digits = '1' .. string.rep('0', exp)
    local grouped = digits:reverse():gsub('(%d%d%d)', '%1,'):reverse()
    grouped = grouped:gsub('^,', '')
    return '1 in ' .. grouped
end

--- Compares a profile with the reference samples. kind 'dna' | 'prints'; donor = who really left it
--- (server truth, may be nil); printId for prints; seed makes the candidate set per sample.
function L.Identify(test, kind, donor, printId, quality, seed)
    local res = { quality = quality }
    if quality < lc('MinQuality', 25) then
        res.outcome = 'no_result'
        res.summary = test == 'prints' and 'Insufficient ridge detail for comparison' or 'Sample too degraded: no usable profile'
        return res
    end
    if not donor and not printId then
        res.outcome = 'no_result'
        res.summary = test == 'prints' and 'No comparable print could be developed' or 'No profile could be developed from this sample'
        return res
    end
    local ref
    if kind == 'prints' and printId then ref = q('single', L.SQL.refBySample, { 'prints', printId }) end
    if not ref and donor then ref = q('single', L.SQL.refByCid, { kind, donor }) end
    if type(ref) ~= 'table' or not ref.citizenid then ref = nil end
    res._donor = donor or (ref and ref.citizenid)

    local full = quality >= lc('FullQuality', 70)
    res.profile = full and 'full' or 'partial'
    if full then
        if ref then
            res.outcome = 'match'
            res.identified = person(ref.citizenid)
            res.identified.reference = ref.sample_ref
            res.identified.source = tostring(ref.source_type) .. ':' .. tostring(ref.source_id)
            res.randomMatch = randomMatchText(test, quality)
            res.summary = ('Identified: %s (reference %s)'):format(res.identified.name or ref.citizenid, ref.source_type)
        else
            res.outcome = 'no_match'
            res.summary = 'Full profile developed; no reference sample on file matches'
        end
        return res
    end

    -- partial: consistent with the true donor (if referenced) and a few other references
    local want = math.floor((lc('FullQuality', 70) - quality) / lc('DecoyStep', 10)) + 1
    local candidates = {}
    if ref then candidates[1] = ref.citizenid end
    local others = q('query', L.SQL.decoys, { kind, ref and ref.citizenid or '', seed, want })
    for _, r in ipairs(type(others) == 'table' and others or {}) do
        if r.citizenid and r.citizenid ~= (ref and ref.citizenid) then candidates[#candidates + 1] = r.citizenid end
    end
    if #candidates == 0 then
        res.outcome = 'inconclusive'
        res.summary = 'Partial profile; no reference sample is consistent with it'
        return res
    end
    table.sort(candidates, function(a, b)
        local ha, hb = L.Hash(seed .. ':' .. a), L.Hash(seed .. ':' .. b)
        if ha == hb then return a < b end
        return ha < hb
    end)
    res.outcome = 'consistent_with'
    res.candidateCount = #candidates
    res.randomMatch = randomMatchText(test, quality)
    if #candidates <= lc('MaxCandidatesListed', 5) then
        res.candidates = {}
        for i, cid in ipairs(candidates) do res.candidates[i] = person(cid) end
    end
    res.summary = ('Partial profile consistent with %d reference sample(s); not an identification'):format(#candidates)
    return res
end

--- Other analysed DNA/touch-DNA results in the same case(s) that come from the same person.
function L.SameSource(row, res)
    if not res._donor then return nil end
    local out, seen = {}, {}
    local links = Store.DecodeLinks(row.case_refs)
    for i = 1, math.min(#links, 5) do
        local rows = q('query', L.SQL.caseResults, { row.id, '%"' .. likeEscape(tostring(links[i])) .. '"%' })
        for _, r in ipairs(type(rows) == 'table' and rows or {}) do
            local other = decode(r.result)
            if other._donor == res._donor and not seen[r.tag] and (other.profile == 'full' or other.profile == 'partial') then
                seen[r.tag] = true
                local strength = (other.profile == 'full' and res.profile == 'full') and 'same_source' or 'cannot_exclude'
                out[#out + 1] = { tag = r.tag, strength = strength }
            end
        end
    end
    return #out > 0 and out or nil
end

-- ── the tests ─────────────────────────────────────────────────────────────────────────────────
local Tests = {}

function Tests.dna(row, attrs, src, seed)
    local quality, notes = L.Quality(row, 'dna', attrs)
    local res
    if src.known and src.donor then
        -- a known sample: whose it is comes from the collection record, not from a database search
        res = { quality = quality, _donor = src.donor }
        if quality < lc('MinQuality', 25) then
            res.outcome, res.summary = 'no_result', 'Sample too degraded: no usable profile'
            res._donor = nil
        else
            res.profile = quality >= lc('FullQuality', 70) and 'full' or 'partial'
            res.outcome = 'known_sample'
            res.collectedFrom = person(src.donor)
            res.summary = ('Reference profile developed from the known sample of %s'):format(res.collectedFrom.name or src.donor)
        end
    else
        res = L.Identify('dna', 'dna', src.donor, nil, quality, seed)
    end
    if row.kind == 'blood' and attrs.bloodtype then res.bloodtype = attrs.bloodtype end
    res.notes = notes
    res.sameSourceAs = L.SameSource(row, res)
    return res
end

function Tests.trace(row, attrs, src, seed)
    local quality, notes = L.Quality(row, 'trace', attrs)
    local res
    if not src.donor then
        res = { outcome = 'no_result', summary = 'No usable trace material recovered', quality = quality }
    else
        res = L.Identify('trace', 'dna', src.donor, nil, quality, seed)
        res.summary = 'Touch DNA: ' .. res.summary
    end
    res.notes = notes
    res.sameSourceAs = L.SameSource(row, res)
    return res
end

function Tests.prints(row, attrs, src, seed)
    local quality, notes = L.Quality(row, 'prints', attrs)
    local res = L.Identify('prints', 'prints', src.donor, E.Ref(attrs.printId, 64), quality, seed)
    res.notes = notes
    return res
end

local function weaponLabel(hash)
    local def = E.Scene and E.Scene.WeaponDef and E.Scene.WeaponDef(hash)
    return def and (def.label or def.name) or nil
end

local function firedByTags(serial, exceptId)
    local rows = q('query', L.SQL.firedBy, { '%"serial":"' .. likeEscape(serial) .. '"%', exceptId })
    local out = {}
    for _, r in ipairs(type(rows) == 'table' and rows or {}) do out[#out + 1] = r.tag end
    return out
end

local function tagOf(id)
    if not id then return nil end
    local r = q('single', L.SQL.tagOf, { id })
    return r and r.tag or nil
end

function Tests.ballistics(row, attrs, src, seed, actor)
    local quality = math.floor(tonumber(row.quality) or 100)
    local res = { quality = quality, notes = {} }
    local serial = E.Str(attrs.serial and tostring(attrs.serial), 32)
    if row.kind == 'weapon' then
        -- a seized weapon: test-fire it and enter the reference casing under its serial
        if not serial then
            res.outcome, res.summary = 'no_result', 'No serial number: the test-fire cannot be indexed'
            return res
        end
        local hash = L.U32(attrs.item and GetHashKey(tostring(attrs.item)))
        q('insert', L.SQL.tfInsert, { serial, hash or 0, row.id, actor and actor.cid or 'lab', E.Now() })
        local tf = q('single', L.SQL.tfBySerial, { serial })
        if type(tf) ~= 'table' then error('test-fire not recorded') end
        res.testFire = { serial = serial, weaponHash = hash }
        if tonumber(tf.evidence_id) and math.floor(tonumber(tf.evidence_id)) ~= row.id then
            res.notes[#res.notes + 1] = ('Already test-fired as %s'):format(tagOf(math.floor(tonumber(tf.evidence_id))) or 'another exhibit')
        end
        local hits = firedByTags(serial, row.id)
        res.outcome = 'test_fired'
        res.matches = #hits > 0 and hits or nil
        res.summary = #hits > 0 and ('Test-fired; %d casing(s)/projectile(s) on file were fired by this weapon'):format(#hits)
            or 'Test-fired and entered; no casing on file matches yet'
        return res
    end

    local hash = L.U32(attrs.weaponHash)
    res.class = { caliber = attrs.caliber, weapon = attrs.weapon or (hash and weaponLabel(hash)) }
    if quality < lc('BallisticsMin', 20) then
        res.outcome, res.summary = 'no_result', 'Too deformed for comparison'
        return res
    end
    local tf = serial and q('single', L.SQL.tfBySerial, { serial }) or nil
    if type(tf) ~= 'table' or not tf.weapon_serial then tf = nil end
    local sameModel = {}
    if hash then
        local rows = q('query', L.SQL.tfByHash, { hash })
        for _, r in ipairs(type(rows) == 'table' and rows or {}) do sameModel[#sameModel + 1] = r end
    end
    local function weaponsOf(list)
        local out = {}
        for i, r in ipairs(list) do
            if i > lc('MaxCandidatesListed', 5) then break end
            out[#out + 1] = { serial = r.weapon_serial, tag = tagOf(tonumber(r.evidence_id) and math.floor(tonumber(r.evidence_id))) }
        end
        return out
    end
    if tf and quality >= lc('BallisticsFull', 60) then
        res.outcome = 'match'
        res.weapon = { serial = tf.weapon_serial, tag = tagOf(tonumber(tf.evidence_id) and math.floor(tonumber(tf.evidence_id))) }
        res.summary = ('Fired by the test-fired weapon %s'):format(res.weapon.tag or tf.weapon_serial)
    elseif tf or (not serial and #sameModel > 0) then
        -- deformed, or no serial known: only class characteristics can be compared
        if tf then
            local found = false
            for _, r in ipairs(sameModel) do if r.weapon_serial == tf.weapon_serial then found = true end end
            if not found then table.insert(sameModel, 1, tf) end
        end
        res.outcome = 'consistent_with'
        res.candidateCount = #sameModel
        res.candidates = weaponsOf(sameModel)
        res.summary = ('Class characteristics consistent with %d test-fired weapon(s); not an identification'):format(#sameModel)
    else
        res.outcome = 'no_match'
        res.summary = #sameModel > 0 and ('No test-fire on file matches; %d test-fired weapon(s) of the same model excluded'):format(#sameModel)
            or 'No test-fire on file matches'
    end
    if serial then
        local linked = firedByTags(serial, row.id)
        res.sameWeaponAs = #linked > 0 and linked or nil
    end
    return res
end

function Tests.tox(row, attrs, src)
    local tox = type(src.private) == 'table' and src.private.tox or nil
    local res = { quality = math.floor(tonumber(row.quality) or 100), notes = {} }
    if type(tox) ~= 'table' then
        res.outcome, res.summary = 'no_result', 'No toxicology sample was preserved'
        return res
    end
    local found, names = {}, {}
    for name in pairs(tox) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local level = tonumber(tox[name]) or 0
        if level >= lc('ToxDetect', 0.01) then found[#found + 1] = { toxin = name, level = level } end
    end
    if res.quality < 60 then res.notes[#res.notes + 1] = 'Degraded sample: levels may be underestimated' end
    res.findings = found
    res.outcome = #found > 0 and 'positive' or 'negative'
    if #found > 0 then
        local parts = {}
        for i, f in ipairs(found) do parts[i] = ('%s %s'):format(f.toxin, f.level) end
        res.summary = 'Detected: ' .. table.concat(parts, ', ')
    else
        res.summary = 'No toxins detected'
    end
    return res
end

function Tests.drug_id(row, attrs)
    local item = E.Str(attrs.item, 50)
    local res = { quality = 100, notes = {} }
    local controlled = item and ((Config.SeizableDrugs or {})[item] or lc('DrugItems', {})[item])
    local shared = item and (E.sharedItems or {})[item]
    res.substance = shared and shared.label or item
    res.amount = E.Int(attrs.amount, 0)
    if controlled then
        res.outcome = 'identified'
        res.summary = ('Identified as %s%s'):format(res.substance, res.amount and (', ' .. res.amount .. ' unit(s)') or '')
    else
        res.outcome = 'negative'
        res.summary = 'No controlled substance identified'
    end
    return res
end

function Tests.gsr(row, attrs)
    local r = attrs.result
    local res = { quality = 100, notes = {} }
    if r == 'positive' or r == 'negative' then
        res.outcome = r
        res.summary = r == 'positive' and 'Gunshot residue particles found' or 'No gunshot residue found'
    else
        res.outcome = 'inconclusive'
        res.summary = 'The kit holds no readable sample'
    end
    return res
end
L.Tests = Tests

--- The full report for one test on one evidence row (pure server data). Returns the result table.
function L.Analyse(row, test, job, actor)
    local attrs = decode(row.attrs)
    local src = L.SourceOf(row)
    local seed = ('%d:%s'):format(row.id, test)
    local res = Tests[test](row, attrs, src, seed, actor)
    res.test = test
    res.examinedAt = E.Now()
    res.notes = res.notes or {}
    -- the chain of custody goes with every report
    local score, flags = Store.ComputeIntegrity(row, Store.Custody(row.id), E.Now())
    res.integrity = { score = score, flags = flags }
    for _, f in ipairs(flags) do
        if f == 'seal_broken' then res.notes[#res.notes + 1] = 'Chain of custody: the seal was broken outside a lab or court'
        elseif f == 'gap' then res.notes[#res.notes + 1] = 'Chain of custody: the evidence was outside police custody for a period'
        elseif f == 'unverified_chain' then res.notes[#res.notes + 1] = 'Chain of custody: registered from a legacy bag; earlier handling unknown' end
    end
    if #res.notes == 0 then res.notes = nil end
    return res
end

--- A result without the server-only fields (whose sample it really is).
function L.PublicResult(res)
    if type(res) ~= 'table' then return nil end
    local out = {}
    for k, v in pairs(res) do
        if type(k) ~= 'string' or k:sub(1, 1) ~= '_' then out[k] = v end
    end
    return out
end

-- ── jobs ──────────────────────────────────────────────────────────────────────────────────────
local function normJob(r)
    if type(r) ~= 'table' or r.id == nil then return nil end
    r.id = math.floor(tonumber(r.id))
    r.evidence_id = math.floor(tonumber(r.evidence_id))
    r.requested_at = tonumber(r.requested_at)
    r.ready_at = tonumber(r.ready_at)
    r.released_at = tonumber(r.released_at)
    return r
end

--- The public shape of a job; the result only when released, or ready for a lab tech to review.
function L.PublicJob(r, canReview)
    local res = decode(r.result)
    local show = r.state == 'released' or (canReview and r.state == 'ready') or r.state == 'failed'
    return {
        id = r.id, evidenceId = r.evidence_id, test = r.test, state = r.state, requestedBy = r.requested_by,
        requestedAt = r.requested_at, eta = r.ready_at, releasedAt = r.released_at, reviewedBy = r.tech_cid,
        result = show and L.PublicResult(res) or nil,
    }
end

function L.HasOpenWork(evidenceId)
    local n = q('scalar', L.SQL.openWork, { evidenceId })
    return (tonumber(n) or 0) > 0
end

function L.JobsFor(evidenceId, canReview)
    local rows = q('query', L.SQL.jobsOf, { evidenceId })
    local out = {}
    for _, r in ipairs(type(rows) == 'table' and rows or {}) do
        local j = normJob(r)
        if j then out[#out + 1] = L.PublicJob(j, canReview) end
    end
    return out
end

local function canReview(actor)
    if not actor then return false end
    if actor.kind == 'system' then return false end
    return C.HasLabRole(actor)
end
L.CanReview = canReview

--- SubmitToLab(id, tests, opts): one job per test; the evidence must be held at a lab.
function L.Submit(id, tests, opts, actor)
    opts = opts or {}
    if actor.kind == 'player' and not actor.leo and not actor.admin and not C.HasLabRole(actor) then
        return E.Err('no_permission', 'On-duty police only')
    end
    if type(tests) == 'string' then tests = { tests } end
    if type(tests) ~= 'table' then return E.Err('bad_args', 'tests must be a list') end
    local list, seen = {}, {}
    for _, t in pairs(tests) do
        if type(t) ~= 'string' or not L.TESTS[t] then return E.Err('bad_args', 'Unknown test ' .. tostring(t):sub(1, 16)) end
        if not seen[t] then
            seen[t] = true
            list[#list + 1] = t
        end
        if #list > lc('MaxTestsPerSubmit', 7) then return E.Err('bad_args', 'Too many tests') end
    end
    if #list == 0 then return E.Err('bad_args', 'Name at least one test') end
    table.sort(list)
    local key = opts.key
    if key ~= nil and not E.Ref(key, 110) then return E.Err('bad_args', 'bad key') end
    if E.Int(id, 1) == nil then return E.Err('bad_args', 'Unknown evidence id') end

    return C.WithRow(id, function(row)
        if Store.IsTerminal(row.state) then return E.Err('invalid_state', 'Evidence is ' .. row.state) end
        if row.holder_kind ~= 'lab' then return E.Err('invalid_state', 'Hand the evidence in at a lab first') end
        local attrs = decode(row.attrs)
        for _, test in ipairs(list) do
            if not (lc('Accepts', {})[test] or {})[row.kind] then
                return E.Err('bad_args', ('A %s cannot be tested for %s'):format(row.kind, test))
            end
            if test == 'tox' then
                local src = L.SourceOf(row)
                if type(src.private) ~= 'table' or type(src.private.tox) ~= 'table' then
                    return E.Err('invalid_state', 'No toxicology sample was preserved with this evidence')
                end
            end
            if test == 'ballistics' and row.kind == 'weapon' and not E.Str(attrs.serial and tostring(attrs.serial), 32) then
                return E.Err('invalid_state', 'The weapon has no serial number to index a test-fire under')
            end
        end

        local now = E.Now()
        local jobs, eta = {}, 0
        local times = lc('Times', {})
        for _, test in ipairs(list) do
            local jobKey = key and (key .. ':' .. test) or nil
            local existing = jobKey and normJob(q('single', L.SQL.jobByKey, { jobKey })) or nil
            if existing and (existing.evidence_id ~= row.id or existing.test ~= test) then
                return E.Err('key_reused', 'The key was used for another lab job')
            end
            existing = existing or normJob(q('single', L.SQL.openJob, { row.id, test }))
            if existing then
                jobs[#jobs + 1] = { jobId = existing.id, test = test, eta = existing.ready_at, duplicate = true }
            else
                if not jobKey then
                    local count = q('scalar', L.SQL.countJobs, { row.id, test })
                    local n = (tonumber(count) or 0) + 1
                    jobKey = ('pfm-policejob:lab:%d:%s:%d'):format(row.id, test, n)
                end
                local readyAt = now + math.max(0, math.floor(tonumber(times[test]) or 1800))
                local jobId, ok = q('insert', L.SQL.insertJob, { row.id, test, actor.cid or actor.label or 'system', now, readyAt, jobKey })
                jobId = ok and tonumber(jobId) or nil
                if not jobId or jobId < 1 then return E.Err('db_unavailable', 'The lab request could not be recorded') end
                jobId = math.floor(jobId)
                Store.AddCustody(row.id, 'lab_requested', row.holder_ref, row.holder_ref, actor, ('%s requested (lab job %d)'):format(test, jobId),
                    actor.src and E.Pos(actor.src) or nil)
                jobs[#jobs + 1] = { jobId = jobId, test = test, eta = readyAt }
            end
        end
        local allDup = true
        for _, j in ipairs(jobs) do
            if (j.eta or 0) > eta then eta = j.eta end
            if not j.duplicate then allDup = false end
        end
        return { ok = true, jobId = jobs[1].jobId, eta = eta, jobs = jobs, duplicate = allDup or nil }
    end)
end

--- GetLabJob(jobId, opts): on-duty police (or an allowlisted caller without a viewer).
function L.Get(jobId, viewerActor)
    jobId = E.Int(jobId, 1)
    if not jobId then return E.Err('bad_args', 'Unknown lab job') end
    if not E.DbReady() then return E.Err('db_unavailable', 'Evidence storage is not ready') end
    local job = normJob(q('single', L.SQL.jobById, { jobId }))
    if not job then return E.Err('not_found', 'No such lab job') end
    return { ok = true, job = L.PublicJob(job, canReview(viewerActor)) }
end

local function lockEvidence(evidenceId)
    return E.Lock('ev:' .. evidenceId)
end

--- Processes one due job: claim it, analyse the evidence still at the lab, store the result.
function L.Process(job, now)
    if not lockEvidence(job.evidence_id) then return 'busy' end
    local ok, res = pcall(function()
        local claimed = q('update', L.SQL.claim, { job.id })
        if Store.Affected(claimed) ~= 1 then return 'taken' end
        local row = Store.Get(job.evidence_id)
        local system = { kind = 'system', label = 'crime lab' }
        if not row or row.holder_kind ~= 'lab' or Store.IsTerminal(row.state) then
            local result = { test = job.test, outcome = 'failed', summary = 'The evidence left the lab before it was analysed' }
            q('update', L.SQL.finish, { 'failed', json.encode(result), job.id })
            if row then Store.AddCustody(row.id, 'lab_failed', row.holder_ref, row.holder_ref, system, ('%s not run (lab job %d)'):format(job.test, job.id)) end
            return 'failed'
        end
        local labRef = row.holder_ref
        local result = L.Analyse(row, job.test, job, { cid = job.requested_by })
        -- the bag is opened at the lab (no integrity cost there) and sealed again after the test
        if row.sealed and C.IsPhysical(row) then
            Store.AddCustody(row.id, 'seal_broken', labRef, labRef, system, ('opened for %s analysis (lab job %d)'):format(job.test, job.id))
            Store.AddCustody(row.id, 'sealed', labRef, labRef, system, 'resealed after analysis')
        end
        local fin = q('update', L.SQL.finish, { 'ready', json.encode(result), job.id })
        if Store.Affected(fin) ~= 1 then error('lab job ' .. job.id .. ' changed while it was processed') end
        C.Record(row, 'lab_result', labRef, labRef, system, ('%s result ready for review (lab job %d)'):format(job.test, job.id))
        if row.state == 'at_lab' and not L.HasOpenWork(row.id) and Store.Move(row, row.holder_kind, row.holder_ref, 'analysed') then
            C.Record(row, 'analysed', labRef, labRef, system, 'all requested tests done')
        end
        return 'ready'
    end)
    E.Unlock('ev:' .. job.evidence_id)
    if not ok then
        print(('^1[pfm-policejob]^7 lab job %d failed: %s'):format(job.id, tostring(res)))
        local result = { test = job.test, outcome = 'failed', summary = 'The analysis could not be completed' }
        q('update', L.SQL.finish, { 'failed', json.encode(result), job.id })
        return 'failed'
    end
    return res
end

--- Releases a ready result. actor: a lab tech (pf-government qualification), or the system for an
--- unreviewed result after AutoReleaseHours.
function L.Release(jobId, opts, actor)
    opts = opts or {}
    jobId = E.Int(jobId, 1)
    if not jobId then return E.Err('bad_args', 'Unknown lab job') end
    local auto = actor.kind == 'system' and opts.auto == true
    if not auto and not C.HasLabRole(actor) then
        return E.Err('no_permission', 'Only a qualified lab technician may release results')
    end
    if not E.DbReady() then return E.Err('db_unavailable', 'Evidence storage is not ready') end
    local job = normJob(q('single', L.SQL.jobById, { jobId }))
    if not job then return E.Err('not_found', 'No such lab job') end
    if job.state == 'released' then return { ok = true, duplicate = true, jobId = job.id } end
    if job.state ~= 'ready' then return E.Err('invalid_state', 'The result is ' .. job.state) end
    local result = decode(job.result)
    if auto then
        result.unreviewed = true
        result.notes = result.notes or {}
        result.notes[#result.notes + 1] = 'Released without review by a qualified examiner'
    end
    local now = E.Now()
    local tech = auto and 'unreviewed' or actor.cid
    local res = q('update', L.SQL.release, { tech, now, json.encode(result), job.id })
    if Store.Affected(res) ~= 1 then return E.Err('busy', 'The result changed meanwhile; try again') end
    job.state, job.tech_cid, job.released_at, job.result = 'released', tech, now, result
    local row = Store.Get(job.evidence_id)
    if row then
        Store.AddCustody(row.id, 'lab_released', row.holder_ref, row.holder_ref, actor,
            ('%s result released%s (lab job %d)'):format(job.test, auto and ' unreviewed' or '', job.id), actor.src and E.Pos(actor.src) or nil)
    end
    local public = L.PublicJob(job, true)
    public.tag = row and row.tag or nil
    TriggerEvent('pfm-policejob:server:labCompleted', public)
    -- the officer who asked hears about it
    local P = exports['pfm-core']:GetPlayerByCitizenId(job.requested_by)
    if P and E.IsLeo(P) then
        TriggerClientEvent('QBCore:Notify', P.PlayerData.source,
            ('Lab result %s %s: %s'):format(public.tag or ('#' .. job.evidence_id), job.test, tostring(result.summary or result.outcome)):sub(1, 200), 'primary')
    end
    return { ok = true, jobId = job.id, job = public }
end

--- One lab pass: due jobs analysed, crashed ones requeued, old unreviewed results released.
function L.Tick(now)
    now = now or E.Now()
    if not E.DbReady() then return 0 end
    q('update', L.SQL.unstick, { now - lc('StaleSeconds', 300) })
    local done = 0
    local due = q('query', L.SQL.due, { now, lc('BatchSize', 20) })
    for _, r in ipairs(type(due) == 'table' and due or {}) do
        local job = normJob(r)
        if job and L.Process(job, now) == 'ready' then done = done + 1 end
    end
    local hours = lc('AutoReleaseHours', 24)
    if hours then
        local rows = q('query', L.SQL.unreviewed, { now - hours * 3600, lc('BatchSize', 20) })
        for _, r in ipairs(type(rows) == 'table' and rows or {}) do
            local job = normJob(r)
            if job then L.Release(job.id, { auto = true }, { kind = 'system', label = 'crime lab' }) end
        end
    end
    return done
end

-- ── reference samples ─────────────────────────────────────────────────────────────────────────
--- RegisterReferenceSample(cid, kind, source, opts). source = { custodyId, sampleRef?, bookingNo? }
--- | { warrantId, sampleRef? }. A DNA reference taken at booking also enters the booking prints.
function L.RegisterReference(cid, kind, source, opts)
    cid = E.Ref(cid, 64)
    if not cid then return E.Err('bad_args', 'Bad citizen id') end
    if kind ~= 'dna' and kind ~= 'prints' then return E.Err('bad_args', 'kind is dna or prints') end
    if type(source) ~= 'table' then return E.Err('bad_args', 'source must be a table') end
    local sourceType, sourceId
    if source.custodyId ~= nil then
        sourceType, sourceId = 'custody', E.Ref(source.custodyId, 64)
    elseif source.warrantId ~= nil then
        sourceType, sourceId = 'warrant', E.Ref(source.warrantId, 64)
    end
    if not sourceId then return E.Err('bad_args', 'source names a custodyId or a warrantId') end
    if opts and opts.key ~= nil and not E.Ref(opts.key, 128) then return E.Err('bad_args', 'bad key') end
    if not E.DbReady() then return E.Err('db_unavailable', 'Evidence storage is not ready') end

    local sampleRef
    if kind == 'dna' then
        if source.sampleRef ~= nil then
            sampleRef = E.Ref(source.sampleRef, 64)
            if not sampleRef then return E.Err('bad_args', 'Bad sample reference') end
        else
            sampleRef = 'DNA-' .. E.RandomHex(16):upper()
        end
    else
        -- prints are the citizen's own fingerprint record, read on the server
        sampleRef = L.FingerprintOf(cid)
        if not sampleRef then return E.Err('not_found', 'No fingerprint on record for this citizen') end
    end
    local ins, ok = q('insert', L.SQL.refInsert, { cid, kind, sampleRef, sourceType, sourceId, E.Now() })
    if not ok then return E.Err('db_unavailable', 'The reference sample could not be recorded') end
    local row = q('single', L.SQL.refBySample, { kind, sampleRef })
    if type(row) ~= 'table' then return E.Err('db_unavailable', 'The reference sample could not be recorded') end
    if row.citizenid ~= cid then return E.Err('key_reused', 'That sample reference belongs to another citizen') end
    local out = { ok = true, sampleRef = sampleRef, duplicate = (tonumber(ins) or 0) < 1 or nil }
    if kind == 'dna' and sourceType == 'custody' then
        local prints = L.RegisterReference(cid, 'prints', { custodyId = sourceId }, nil)
        if prints.ok then out.printsRef = prints.sampleRef end
    end
    return out
end

--- Whether the citizen has booking prints on file (for the station fingerprint scanner).
function L.HasPrintReference(cid)
    local row = q('single', L.SQL.refByCid, { 'prints', cid })
    return type(row) == 'table' and row.citizenid ~= nil
end

-- ── projectiles from surgery (pf-ambulancejob, contract 17B) ──────────────────────────────────
--- p = { injuryId, caliber, weaponHash, attackerCid?, weaponSerial?, byCid, at }. The projectile is
--- sealed into the hospital's surgery evidence locker for police to collect there.
function L.OnProjectileRecovered(cid, p)
    local from = E.Cfg().ProjectileFrom or 'pf-ambulancejob'
    if GetInvokingResource() ~= from then return E.Err('not_allowed') end
    if type(p) ~= 'table' or not E.Ref(cid, 64) then return E.Err('bad_args') end
    local injuryId = E.Ref(p.injuryId, 64)
    if not injuryId then return E.Err('bad_args') end
    if not E.DbReady() then return E.Err('db_unavailable') end
    local cfg = E.Cfg().ProjectileLocker or {}
    local stash = cfg.stash or 'evl:pillbox:surgery'
    local locker = Store.EnsureLocker(cfg.station or 'pillbox', cfg.label or 'Surgery evidence', stash, nil)
    if not locker then return E.Err('db_unavailable') end
    exports['pfm-inventory']:CreateInventory(stash, { label = locker.label, maxweight = 4000000, slots = 500 })
    local res = E.Api.Internal.CreateEvidence({
        kind = 'projectile', label = 'Projectile (surgery)', method = 'surgery', sealed = true,
        attrs = { caliber = p.caliber, weaponHash = p.weaponHash, serial = p.weaponSerial, fromInjuryId = injuryId },
        origin = { type = 'injury', id = injuryId }, quality = lc('ProjectileQuality', 80),
    }, { key = 'pf-ambulancejob:projectile:' .. injuryId, giveTo = 'stash:' .. stash, actor = { kind = 'system', label = 'surgery' } })
    if type(res) == 'table' and not res.ok then
        print(('^3[pfm-policejob]^7 projectile from injury %s not recorded: %s'):format(injuryId, tostring(res.error)))
    end
    return res
end

AddEventHandler('pf-ambulancejob:server:projectileRecovered', function(cid, p) L.OnProjectileRecovered(cid, p) end)

-- ── lockers per case ──────────────────────────────────────────────────────────────────────────
--- The evidence station index the player stands at (server position), or nil.
function L.StationAt(src)
    local here = E.Pos(src)
    for i, loc in ipairs(Config.Locations and Config.Locations['evidence'] or {}) do
        if E.Dist(here, loc) <= (E.Cfg().LockerReach or 3.0) then return i end
    end
    for name, st in pairs(E.Cfg().LockerStations or {}) do
        if type(st) == 'table' and st.coords and E.Dist(here, st.coords) <= (E.Cfg().LockerReach or 3.0) then return name end
    end
    return nil
end

--- CreateEvidenceLocker(caseRef, opts): one locker (its own stash) per case per station.
function L.CreateLocker(caseRef, opts, actor)
    opts = opts or {}
    local ref = Store.CaseRef(caseRef)
    if not ref then return E.Err('bad_args', 'Bad case reference') end
    local station
    if actor.kind == 'player' and not actor.admin then
        if not actor.leo then return E.Err('no_permission', 'On-duty police only') end
        station = L.StationAt(actor.src)
        if not station then return E.Err('too_far', 'Stand at an evidence locker') end
    else
        station = opts.station
        if not Store.StationCoords(station) then return E.Err('bad_args', 'Unknown station') end
    end
    local stash = ('evl:%s:%s'):format(tostring(station), ref)
    if #stash > 64 then return E.Err('bad_args', 'Case reference too long for a locker') end
    if not E.DbReady() then return E.Err('db_unavailable', 'Evidence storage is not ready') end
    local existed = q('single', Store.SQL.lockerByStash, { stash })
    local row = Store.EnsureLocker(station, ('Case %s'):format(ref):sub(1, 64), stash, ref)
    if not row then return E.Err('db_unavailable', 'The locker could not be created') end
    exports['pfm-inventory']:CreateInventory(stash, { label = row.label, maxweight = 4000000, slots = 200 })
    return { ok = true, lockerId = math.floor(tonumber(row.id)), stashId = stash, existing = existed ~= nil or nil }
end

--- Opens a locker's stash for an on-duty officer standing at its station. Moves in and out are
--- recorded by the inventory listeners (checked_in / checked_out).
function L.OpenLocker(src, lockerId)
    local P = E.Player(src)
    if not P or not E.IsLeo(P) then return E.Err('no_permission', 'On-duty police only') end
    if not E.DbReady() then return E.Err('db_unavailable', 'Evidence storage is not ready') end
    local row = Store.ResolveLocker(lockerId)
    if not row then return E.Err('not_found', 'No such evidence locker') end
    local at = Store.LockerLocation(row.stash_id)
    if not at or E.Dist(E.Pos(src), at) > (E.Cfg().LockerReach or 3.0) then return E.Err('too_far', 'Stand at that evidence locker') end
    exports['pfm-inventory']:CreateInventory(row.stash_id, { label = row.label, maxweight = 4000000, slots = 200 })
    exports['pfm-inventory']:OpenInventory(src, row.stash_id, { label = row.label, maxweight = 4000000, slots = 200 })
    return { ok = true, lockerId = math.floor(tonumber(row.id)), stashId = row.stash_id }
end

RegisterNetEvent('police:server:OpenEvidenceLocker', function(lockerId)
    local src = tonumber(source)
    if not src or src <= 0 then return end
    local rate = (E.Cfg().Rates or {}).command or {}
    if not E.Rate(src .. ':locker', rate.perSecond or 1, rate.burst or 2) then return end
    if type(lockerId) ~= 'number' and type(lockerId) ~= 'string' then return end
    local res = L.OpenLocker(src, lockerId)
    if not res.ok then TriggerClientEvent('QBCore:Notify', src, res.message or res.error, 'error') end
end)

-- ── legacy bags (filled_evidence_bag without an evidence record) ──────────────────────────────
--- The citizen id an old bag's DNA label encoded (the old code wrote it as hex), or nil.
function L.DecodeLegacyLabel(label)
    if type(label) ~= 'string' or #label < 2 or #label > 128 or #label % 2 ~= 0 or label:find('[^%x]') then return nil end
    local out = label:gsub('%x%x', function(h) return string.char(tonumber(h, 16)) end)
    return E.Ref(out, 64)
end

--- Registers a legacy bag the officer carries at an evidence station or lab: the old bag is
--- exchanged for an evidence bag with a record (method 'registered', integrity marked unverified).
function L.RegisterLegacyBag(src, slot)
    local P = E.Player(src)
    if not P or not E.IsLeo(P) then return E.Err('no_permission', 'On-duty police only') end
    local actor = E.Actor({ src = src })
    local atLab = false
    for labId in pairs(E.Cfg().Labs or {}) do
        if C.AtLab(actor, labId) then atLab = true end
    end
    if not atLab and not L.StationAt(src) then return E.Err('too_far', 'Register old bags at an evidence locker or the lab') end
    if not E.DbReady() then return E.Err('db_unavailable', 'Evidence storage is not ready') end
    local legacy = E.Cfg().LegacyBagItem or 'filled_evidence_bag'
    slot = slot ~= nil and E.Int(slot, 1, 200) or nil
    local item
    for _, it in pairs(P.PlayerData.items or {}) do
        if type(it) == 'table' and it.name == legacy and (not slot or tonumber(it.slot) == slot)
            and not (type(it.info) == 'table' and it.info.evidenceId ~= nil) then
            item = it
            break
        end
    end
    if not item then return E.Err('not_found', 'No unregistered evidence bag there') end
    local info = type(item.info) == 'table' and item.info or {}
    local kind = info.type
    local spec = { method = 'registered', sealed = true, scene = { label = E.Str(info.street, 96) } }
    local donor = L.DecodeLegacyLabel(info.dnalabel)
    if kind == 'blood' then
        spec.kind, spec.label = 'blood', 'Blood sample (registered)'
        spec.attrs = { sampleId = 'S-' .. E.RandomHex(8):upper(), bloodtype = info.bloodtype }
    elseif kind == 'dna' then
        spec.kind, spec.label = 'dna_swab', 'DNA swab (registered)'
        spec.attrs = { sampleId = 'D-' .. E.RandomHex(8):upper(), quality = 100 }
        if donor then spec.origin = { type = 'person', id = donor } end
    elseif kind == 'fingerprint' then
        spec.kind, spec.label = 'fingerprint', 'Fingerprint lift (registered)'
        spec.attrs = { printId = info.fingerprint, quality = 100 }
    elseif kind == 'casing' then
        spec.kind, spec.label = 'casing', 'Bullet casing (registered)'
        spec.attrs = { caliber = info.ammolabel, weaponHash = info.ammotype, serial = info.serie }
    else
        return E.Err('invalid_state', 'This bag holds nothing that can be registered')
    end
    local itemSlot = tonumber(item.slot)
    if not exports['pfm-inventory']:RemoveItem(src, legacy, 1, itemSlot, 'evidence:register-legacy') then
        return E.Err('not_found', 'The bag is not there any more')
    end
    local dropId
    if kind == 'blood' and donor and E.Scene then
        -- who the blood came from stays on the server, in a drop row where the lab looks for scene samples
        dropId = E.Scene.RecordPrivateSource('blood', E.Pos(src), { legacy = true }, donor, nil)
        if dropId then spec.origin = { type = 'scene_drop', id = tostring(dropId) } end
    end
    spec.origin = spec.origin or { type = 'legacy_bag', id = tostring(math.floor(tonumber(item.slot) or 0)) }
    local key = ('pfm-policejob:legacy:%s:%s'):format(actor.cid, E.RandomHex(12))
    local res = E.Api.Internal.CreateEvidence(spec, { key = key, giveTo = src, actor = { src = src } })
    if type(res) ~= 'table' or not res.ok then
        exports['pfm-inventory']:AddItem(src, legacy, 1, itemSlot, info, 'evidence:register-legacy refund')
        return type(res) == 'table' and res or E.Err('db_unavailable')
    end
    if dropId then
        q('update', 'UPDATE pf_evidence_scene_drops SET collected_evidence_id = ? WHERE id = ?', { res.evidenceId, dropId })
    end
    return res
end
