-- pfm-policejob crime lab and evidence features (batch 18, unit 18D), mocked: the lab exports check
-- their caller allowlists and actors, a result never carries who the sample really came from,
-- quality and contamination shape the report, a release needs the lab_tech qualification, surgery
-- projectiles are accepted only from pf-ambulancejob, court disposal fails closed, GetEvidence only
-- rewrites the stored integrity under the row lock, toxin levels stay off the evidence item,
-- /takedna no longer writes the citizen id and /callsign is validated.
load_resource('tests/lua/fivem_mocks.lua')
function GetCurrentResourceName() return 'pfm-policejob' end
local started = {}
function GetResourceState(name) return started[name] and 'started' or 'missing' end
Mock.exportsByResource['pfm-core'].RunMigrations = function() return true end
local invCalls = {}
Mock.exportsByResource['pfm-inventory'] = {
    AddItem = function(_, ...) invCalls[#invCalls + 1] = { 'add', ... } return true end,
    RemoveItem = function(_, ...) invCalls[#invCalls + 1] = { 'remove', ... } return true end,
    CreateInventory = function() end, OpenInventory = function() end, GetInventory = function() return nil end,
}
local techs = {}
Mock.exportsByResource['pf-government'] = {
    HasQualification = function(_, cid, qual) return qual == 'lab_tech' and techs[cid] == true, 'granted' end,
}
local court = { answer = nil, fail = false }
Mock.exportsByResource['pf-justice'] = {
    IsCourtOrderValid = function()
        if court.fail then error('No such export IsCourtOrderValid in resource pf-justice') end
        return court.answer
    end,
}
local summaries = {}
Mock.exportsByResource['pf-ambulancejob'] = {
    GetToxinLevels = function(_, src) summaries.calls = (summaries.calls or 0) + 1 return summaries[src] end,
}
QBCoreMock.Shared.Items.evidence_bag = { name = 'evidence_bag', unique = true }

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
PFPoliceSchema.state = 'ready'

local COP, CIV, TECH, MEDIC = 1, 2, 3, 4

BeforeEach = function()
    Mock.reset()
    Mock.players, Mock.coords, Mock.aces = {}, {}, {}
    Mock.invokingResource = nil
    Mock.gameTimer = Mock.gameTimer + 100000
    invCalls, techs, summaries = {}, { TECHCID = true }, {}
    court.answer, court.fail = nil, false
    started = { ['pf-government'] = true }
    local cop = Mock.newPlayer(COP, 'COPCID')
    cop.PlayerData.job = { name = 'police', type = 'leo', onduty = true, grade = { level = 1 } }
    local tech = Mock.newPlayer(TECH, 'TECHCID')
    tech.PlayerData.job = { name = 'police', type = 'leo', onduty = true, grade = { level = 1 } }
    local civ = Mock.newPlayer(CIV, 'CIVCID')
    civ.PlayerData.metadata.fingerprint = 'FP-CIV'
    local medic = Mock.newPlayer(MEDIC, 'MEDCID')
    medic.PlayerData.job = { name = 'ambulance', type = 'ems', onduty = true, grade = { level = 1 } }
end

describe('caller allowlists of the lab exports', function()
    it('refuse unlisted resources and accept the listed ones', function()
        Mock.invokingResource = 'random-script'
        assert_eq(A.SubmitToLab(1, { 'dna' }, {}).error, 'not_allowed')
        assert_eq(A.GetLabJob(1, {}).error, 'not_allowed')
        assert_eq(A.ReleaseLabResult(1, {}).error, 'not_allowed')
        assert_eq(A.RegisterReferenceSample('CIVCID', 'dna', { custodyId = 1 }).error, 'not_allowed')
        assert_eq(A.CreateEvidenceLocker({ type = 'case', id = '1' }, {}).error, 'not_allowed')
        Mock.invokingResource = 'pf-policemdt-DEV'
        assert_eq(A.RegisterReferenceSample('CIVCID', 'dna', { custodyId = 1 }).error, 'not_allowed', 'only pf-justice books')
        Mock.invokingResource = 'pf-justice'
        assert_eq(A.RegisterReferenceSample('CIVCID', 'blood', { custodyId = 1 }).error, 'bad_args')
        assert_eq(A.RegisterReferenceSample('CIVCID', 'dna', { custodyId = 'x y' }).error, 'bad_args')
        assert_eq(A.RegisterReferenceSample('bad cid!', 'dna', { custodyId = 1 }).error, 'bad_args')
        assert_eq(A.RegisterReferenceSample('CIVCID', 'dna', 'nope').error, 'bad_args')
    end)
end)

describe('submission', function()
    it('validates tests before touching the database and needs on-duty police', function()
        assert_eq(L.Submit(5, { 'dna' }, {}, E.Actor({ src = CIV })).error, 'no_permission')
        local cop = E.Actor({ src = COP })
        assert_eq(L.Submit(5, { 'palmistry' }, {}, cop).error, 'bad_args')
        assert_eq(L.Submit(5, {}, {}, cop).error, 'bad_args')
        assert_eq(L.Submit(5, 42, {}, cop).error, 'bad_args')
        assert_eq(L.Submit(5, { 'dna' }, { key = 'bad key with spaces' }, cop).error, 'bad_args')
        assert_eq(#Mock.dbCalls, 0)
    end)
end)

describe('results', function()
    it('never carry the true donor and only show to officers once released', function()
        local job = { id = 1, evidence_id = 2, test = 'dna', state = 'ready', result = json.encode({ outcome = 'no_match', _donor = 'CIVCID' }) }
        assert_eq(L.PublicJob(job, false).result, nil, 'ready: not for officers')
        local review = L.PublicJob(job, true).result
        assert_eq(review.outcome, 'no_match')
        assert_eq(review._donor, nil)
        job.state = 'released'
        assert_eq(L.PublicJob(job, false).result._donor, nil)
    end)
    it('quality falls with contamination and touch DNA is always partial', function()
        local q = L.Quality({ quality = 100, flags = 'contaminated', kind = 'blood' }, 'dna', {})
        assert_eq(q, 75)
        assert_eq(L.Quality({ quality = 100, flags = 'contaminated', kind = 'drug' }, 'drug_id', {}), 100, 'only contact tests')
        assert_eq(L.Quality({ quality = 100, kind = 'fingerprint' }, 'prints', { quality = 50 }), 50, 'the lift quality')
        assert_eq(L.Quality({ quality = 100, kind = 'weapon' }, 'trace', {}), Config.Evidence.Lab.TraceQuality)
        assert_eq(L.Quality({ quality = 10, flags = 'contaminated', kind = 'blood' }, 'dna', {}), 0, 'never negative')
    end)
    it('no profile without a known source, and nothing below the minimum quality', function()
        local res = L.Identify('dna', 'dna', nil, nil, 100, 'seed')
        assert_eq(res.outcome, 'no_result')
        assert_eq(L.Identify('dna', 'dna', 'CIVCID', nil, 10, 'seed').outcome, 'no_result')
        assert_eq(#Mock.dbCalls, 0, 'no reference lookup without a profile')
    end)
    it('a full profile without a reference names nobody', function()
        -- the mocked database has no reference rows
        local res = L.Identify('dna', 'dna', 'CIVCID', nil, 100, '1:dna')
        assert_eq(res.outcome, 'no_match')
        assert_eq(res.identified, nil)
        assert_eq(res._donor, 'CIVCID')
        assert_eq(L.PublicResult(res)._donor, nil)
    end)
    it('the candidate order is a fixed function of the sample', function()
        assert_eq(L.Hash('7:dna:CIVCID'), L.Hash('7:dna:CIVCID'))
        assert_true(L.Hash('7:dna:CIVCID') ~= L.Hash('8:dna:CIVCID'))
        assert_true(L.Hash(string.rep('z', 500)) < 16777213, 'stays in range on 32-bit test VMs')
    end)
    it('drug identification only for controlled items; gsr reads the kit', function()
        assert_eq(L.Tests.drug_id({}, { item = 'meth', amount = 2 }).outcome, 'identified')
        assert_eq(L.Tests.drug_id({}, { item = 'sandwich' }).outcome, 'negative')
        assert_eq(L.Tests.gsr({}, { result = 'positive' }).outcome, 'positive')
        assert_eq(L.Tests.gsr({}, {}).outcome, 'inconclusive')
    end)
end)

describe('release', function()
    it('needs the lab_tech qualification; a supervisor grade is not enough; the system only for the fallback', function()
        local sarge = Mock.newPlayer(9, 'SARGECID')
        sarge.PlayerData.job = { name = 'police', type = 'leo', onduty = true, grade = { level = 4 } }
        assert_eq(L.Release(1, {}, E.Actor({ src = 9 })).error, 'no_permission')
        assert_eq(L.Release(1, {}, { kind = 'system', label = 'x' }).error, 'no_permission')
        assert_eq(A.ReleaseLabResult(1, { actor = { kind = 'system', label = 'x' } }).error, 'no_permission', 'the export cannot auto-release')
        started['pf-government'] = nil
        assert_eq(L.Release(1, {}, E.Actor({ src = TECH })).error, 'no_permission', 'qualification unreadable: refused')
        started['pf-government'] = true
        -- a lab tech gets past the gate (the mocked database then finds no job)
        assert_eq(L.Release(1, {}, E.Actor({ src = TECH })).error, 'not_found')
    end)
end)

describe('surgery projectiles', function()
    it('come only from pf-ambulancejob and carry the injury key', function()
        local seen
        local real, realEnsure = A.Internal.CreateEvidence, Store.EnsureLocker
        A.Internal.CreateEvidence = function(spec, opts) seen = { spec = spec, opts = opts } return { ok = true, evidenceId = 1 } end
        Store.EnsureLocker = function(station, label, stash) return { id = 1, station = station, label = label, stash_id = stash } end
        Mock.invokingResource = 'pf-hackscript'
        assert_eq(L.OnProjectileRecovered('CIVCID', { injuryId = 'I1' }).error, 'not_allowed')
        assert_eq(seen, nil)
        Mock.invokingResource = 'pf-ambulancejob'
        assert_eq(L.OnProjectileRecovered('CIVCID', { injuryId = 'bad id!' }).error, 'bad_args')
        L.OnProjectileRecovered('CIVCID', { injuryId = 'I1', caliber = '9mm', weaponHash = 123, weaponSerial = 'S1' })
        A.Internal.CreateEvidence, Store.EnsureLocker = real, realEnsure
        assert_eq(seen.opts.key, 'pf-ambulancejob:projectile:I1')
        assert_eq(seen.opts.giveTo, 'stash:evl:pillbox:surgery')
        assert_eq(seen.spec.kind, 'projectile')
        assert_eq(seen.spec.quality, Config.Evidence.Lab.ProjectileQuality)
        assert_eq(seen.spec.attrs.serial, 'S1')
    end)
    it('a starting quality is accepted from a server process, never from a player', function()
        local f = A.BuildSpec({ kind = 'vehicle', attrs = { plate = 'AB1' }, quality = 40 }, {}, { kind = 'system', label = 's' })
        assert_eq(f.quality, 40)
        f = A.BuildSpec({ kind = 'vehicle', attrs = { plate = 'AB1' }, quality = 40 }, {}, E.Actor({ src = COP }))
        assert_eq(f.quality, 100)
    end)
end)

describe('court disposal fails closed', function()
    it('without pf-justice, without the export, or with a refusal', function()
        local row = { id = 3, tag = 'EV-1' }
        assert_false(C.CourtOrderAllows('CO-1', 'destroy', nil, row), 'pf-justice not running')
        started['pf-justice'] = true
        court.fail = true
        assert_false(C.CourtOrderAllows('CO-1', 'destroy', nil, row), 'export missing (before 19A)')
        court.fail = false
        assert_false(C.CourtOrderAllows('CO-1', 'destroy', nil, row), 'no answer')
        court.answer = false
        assert_false(C.CourtOrderAllows('CO-1', 'destroy', nil, row))
        court.answer = { ok = false }
        assert_false(C.CourtOrderAllows('CO-1', 'destroy', nil, row))
        court.answer = { ok = true, valid = true }
        assert_true(C.CourtOrderAllows('CO-1', 'destroy', nil, row))
        court.answer = true
        assert_true(C.CourtOrderAllows('CO-1', 'release', 'CIVCID', row))
    end)
end)

describe('GetEvidence and the row lock', function()
    it('does not rewrite the stored integrity while another action holds the row', function()
        local realGet, realCustody = Store.Get, Store.Custody
        Store.Get = function(id) return { id = id, tag = 'EV-1', kind = 'blood', state = 'sealed', integrity = 100, flags = nil, holder_ref = 'unknown', holder_kind = 'unknown', attrs = '{}' } end
        Store.Custody = function() return { { event = 'flagged_missing', to_ref = 'unknown', at = Mock.clock - 7200 } } end
        E.Lock('ev:5')
        local res = A.GetEvidence(5, {})
        assert_eq(res.integrity.score, 80, 'computed for the answer')
        local writes = 0
        for _, c in ipairs(Mock.dbCalls) do if tostring(c.query):find('SET integrity') then writes = writes + 1 end end
        assert_eq(writes, 0, 'no unlocked write')
        E.Unlock('ev:5')
        A.GetEvidence(5, {})
        for _, c in ipairs(Mock.dbCalls) do if tostring(c.query):find('SET integrity') then writes = writes + 1 end end
        assert_eq(writes, 1, 'written under the lock')
        assert_false(E.IsLocked('ev:5'))
        Store.Get, Store.Custody = realGet, realCustody
    end)
end)

describe('scene blood keeps toxins on the drop row only', function()
    it('snapshots the bleeder once per burst and never copies them to the evidence item', function()
        started['pf-ambulancejob'] = true
        summaries[CIV] = { ok = true, toxins = { ethanol = 0.08, ['bad key'] = 1, cocaine = 'x' } }
        summaries[COP] = { ok = false, error = 'not_allowed' }
        assert_eq(S.ToxSnapshot(COP, 'COPCID'), nil, 'a refusal is not a clean sample')
        local tox = S.ToxSnapshot(CIV, 'CIVCID')
        assert_eq(tox.ethanol, 0.08)
        assert_eq(tox['bad key'], nil)
        assert_eq(tox.cocaine, nil)
        S.ToxSnapshot(CIV, 'CIVCID')
        assert_eq(summaries.calls, 2, 'cached per citizen')
        summaries[MEDIC] = { ok = true, toxins = {} }
        local clean = S.ToxSnapshot(MEDIC, 'MEDCID')
        assert_eq(type(clean), 'table', 'answered and clean: an empty panel, so a tox test can still run')
        assert_eq(next(clean), nil)
        assert_true(S.PRIVATE_ATTRS.tox)
        started['pf-ambulancejob'] = nil
        S.toxCache = {}
        assert_eq(S.ToxSnapshot(CIV, 'CIVCID'), nil, 'no medical resource: nothing invented')
    end)
end)

describe('legacy bag labels', function()
    it('decode the old hex citizen id and refuse anything else', function()
        local hex = ('CIVCID'):gsub('.', function(c) return ('%02x'):format(c:byte()) end)
        assert_eq(L.DecodeLegacyLabel(hex), 'CIVCID')
        assert_eq(L.DecodeLegacyLabel('abc'), nil)
        assert_eq(L.DecodeLegacyLabel('zz11'), nil)
        assert_eq(L.DecodeLegacyLabel(('20'):rep(4)), nil, 'spaces are not a citizen id')
        assert_eq(L.DecodeLegacyLabel(nil), nil)
    end)
end)

describe('/takedna', function()
    it('creates a dna_swab with a sample id through the evidence module; no hex label on any bag', function()
        local made
        local real = A.Internal.CreateEvidence
        A.Internal.CreateEvidence = function(spec, opts) made = { spec = spec, opts = opts } return { ok = true, evidenceId = 1, tag = 'EV-2026-000001' } end
        Mock.coords[CIV] = vector3(1, 0, 0)
        Mock.players[CIV].PlayerData.metadata.ishandcuffed = true
        local res = EC.TakeDna(COP, { tostring(CIV) })
        A.Internal.CreateEvidence = real
        assert_true(res and res.ok)
        assert_eq(made.spec.kind, 'dna_swab')
        assert_eq(made.spec.origin.id, 'CIVCID')
        assert_eq(made.spec.attrs.sampleId:sub(1, 2), 'D-')
        assert_eq(made.spec.collectedBy, COP)
        for _, call in ipairs(invCalls) do
            assert_true(call[3] ~= 'filled_evidence_bag', 'the old bag is not handed out')
            assert_true(type(call[6]) ~= 'table' or call[6].dnalabel == nil)
        end
    end)
    it('is refused beyond 2.5 m, for unrestrained people, and for non-police', function()
        Mock.players[CIV].PlayerData.metadata.ishandcuffed = true
        Mock.coords[CIV] = vector3(2.6, 0, 0)
        assert_false(EC.TakeDna(COP, { tostring(CIV) }))
        Mock.gameTimer = Mock.gameTimer + 100000
        Mock.coords[CIV] = vector3(1, 0, 0)
        Mock.players[CIV].PlayerData.metadata.ishandcuffed = false
        assert_false(EC.TakeDna(COP, { tostring(CIV) }))
        assert_false(EC.TakeDna(MEDIC, { tostring(CIV) }))
        assert_false(EC.TakeDna(COP, { tostring(COP) }), 'not yourself')
        assert_eq(#invCalls, 0, 'no bag used')
    end)
end)

describe('/callsign', function()
    it('only for on-duty police and EMS, 1-12 safe characters', function()
        assert_false(EC.Callsign(CIV, { 'X1' }))
        assert_true(EC.Callsign(COP, { '1-ADAM', '12' }))
        assert_eq(Mock.players[COP].PlayerData.metadata.callsign, '1-ADAM 12')
        Mock.gameTimer = Mock.gameTimer + 100000
        assert_false(EC.Callsign(COP, { '<img src=x>' }))
        Mock.gameTimer = Mock.gameTimer + 100000
        assert_false(EC.Callsign(COP, { string.rep('A', 13) }))
        Mock.gameTimer = Mock.gameTimer + 100000
        assert_false(EC.Callsign(COP, {}))
        Mock.gameTimer = Mock.gameTimer + 100000
        assert_true(EC.Callsign(MEDIC, { 'M-3' }))
        Mock.players[COP].PlayerData.job.onduty = false
        Mock.gameTimer = Mock.gameTimer + 100000
        assert_false(EC.Callsign(COP, { 'OFF' }))
        assert_eq(Mock.players[COP].PlayerData.metadata.callsign, '1-ADAM 12')
    end)
end)

describe('locker stations', function()
    it('evidence locations by index and named places resolve to server coordinates', function()
        local loc = Config.Locations.evidence[2]
        local c = Store.StationCoords('2')
        assert_eq(c.x, loc.x)
        assert_eq(Store.StationCoords('drawer:2').y, loc.y)
        assert_eq(Store.StationCoords('pillbox').x, Config.Evidence.LockerStations.pillbox.coords.x)
        assert_eq(Store.StationCoords('nowhere'), nil)
        Store.RememberLocker({ stash_id = 'evl:2:case:C-1', station = '2' })
        assert_true(Store.IsLockerStash('evl:2:case:C-1'))
        assert_eq(Store.LockerLocation('evl:2:case:C-1').x, loc.x)
    end)
    it('a registered legacy bag carries an integrity penalty and a flag', function()
        local score, flags = Store.ComputeIntegrity({ method = 'registered', kind = 'blood' }, {}, Mock.clock)
        assert_eq(score, 100 - Config.Evidence.Integrity.Unverified)
        assert_eq(flags[1], 'unverified_chain')
    end)
end)

describe('commands run inside a pfm-core funcref call', function()
    it('the internal evidence calls ignore the caller allowlist (GetInvokingResource is pfm-core there)', function()
        Mock.invokingResource = 'pfm-core'
        Mock.coords[CIV] = vector3(1, 0, 0)
        Mock.players[CIV].PlayerData.metadata.ishandcuffed = true
        PFPoliceSchema.state = 'ready'
        local res = EC.TakeDna(COP, { tostring(CIV) })
        -- the mocked database stores nothing, so the record cannot be read back; what matters is
        -- that the call got past the allowlist into the evidence module
        local notAllowed = 0
        for _, e in ipairs(Mock.clientEventsNamed('QBCore:Notify')) do
            if tostring(e.args[1]):find('may not call', 1, true) then notAllowed = notAllowed + 1 end
        end
        assert_eq(notAllowed, 0)
        assert_eq(A.CreateEvidence({ kind = 'vehicle', attrs = { plate = 'AB1' } }, { key = 'k1', actor = { src = COP } }).error, 'not_allowed',
            'the export itself still checks its caller')
        assert_true(A.Internal.CreateEvidence({ kind = 'vehicle', attrs = { plate = 'AB1' } }, { key = 'k1', actor = { src = COP } }).error ~= 'not_allowed')
        Mock.invokingResource = nil
        assert_true(res == false or type(res) == 'table')
    end)
end)
