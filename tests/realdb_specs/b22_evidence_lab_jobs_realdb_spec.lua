-- Batch 22 (22C) pfm-policejob on MariaDB: ListLabJobs, the lab job list the MDT lab queue reads in
-- one query instead of one GetEvidence per item.
--   * by evidence ids (1-50, deduplicated): every job of those items, per item in id order, optional
--     state; a result shows only when released, or ready for a lab tech viewer (PublicJob rules);
--   * by state: newest first, paged with `after`, limit 1-100;
--   * the viewer must be on-duty police; only pf-policemdt-DEV may call it.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
local started = { ['pfm-inventory'] = true, ['pf-government'] = true }
function GetResourceState(name) return started[name] and 'started' or 'missing' end
function GetCurrentResourceName() return 'pfm-policejob' end

load_resource('pfm-core/server/migrations.lua')
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end
Mock.exportsByResource['pfm-inventory'] = {
    AddListener = function() return 1 end, GetInventory = function() return nil end, CreateInventory = function() end,
}
local techs = {}
Mock.exportsByResource['pf-government'] = {
    HasQualification = function(_, cid, qual) return qual == 'lab_tech' and techs[cid] == true end,
}

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
assert_true(PFPoliceSchema.Run(), 'schema')
-- the allowlisted export as other resources reach it (PFEvidence.Api[name] is the exported function)
local A = PFEvidence.Api
local api = { ListLabJobs = function(_, f) return A.ListLabJobs(f) end }

local COP, TECH, CIV, OFFDUTY = 1, 2, 3, 4
local function as(res) Mock.invokingResource = res end
local function insertJob(evId, test, state, result, at)
    return tonumber(MySQL.insert.await([[INSERT INTO pf_evidence_lab_jobs (evidence_id, test, state, requested_by, result, requested_at, ready_at)
        VALUES (?, ?, ?, 'B22COP', ?, ?, ?)]], { evId, test, state, result and json.encode(result) or nil, at, at + 60 }))
end

-- evidence ids far from anything other specs create
local EV1, EV2, EV3 = 922001, 922002, 922003
BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    local c = Mock.newPlayer(COP, 'B22COP')
    c.PlayerData.job = { name = 'police', type = 'leo', onduty = true, grade = { level = 1 } }
    local t = Mock.newPlayer(TECH, 'B22TECH')
    t.PlayerData.job = { name = 'police', type = 'leo', onduty = true, grade = { level = 2 } }
    techs = { B22TECH = true }
    Mock.newPlayer(CIV, 'B22CIV')
    local o = Mock.newPlayer(OFFDUTY, 'B22OFFD')
    o.PlayerData.job = { name = 'police', type = 'leo', onduty = false, grade = { level = 1 } }
    as('pf-policemdt-DEV')
end

local J = {}
describe('22C ListLabJobs (MariaDB)', function()
    it('reads the jobs of a page of items in one query, per item in id order', function()
        MySQL.query.await('DELETE FROM pf_evidence_lab_jobs WHERE evidence_id IN (?, ?, ?)', { EV1, EV2, EV3 })
        local t0 = 1800000000
        J.a = insertJob(EV1, 'dna', 'queued', nil, t0)
        J.b = insertJob(EV1, 'prints', 'ready', { match = 'B22CIV' }, t0 + 1)
        J.c = insertJob(EV2, 'tox', 'released', { ethanol = 0.08 }, t0 + 2)
        J.d = insertJob(EV3, 'gsr', 'failed', { reason = 'left the lab' }, t0 + 3)
        local r = api:ListLabJobs({ evidenceIds = { EV1, EV2, EV1, EV3 }, viewer = COP })
        assert_true(r.ok, tostring(r.error))
        assert_eq(#r.jobs, 4)
        assert_eq(r.jobs[1].id, J.a)
        assert_eq(r.jobs[1].evidenceId, EV1)
        assert_eq(r.jobs[2].id, J.b)
        assert_eq(r.jobs[3].evidenceId, EV2)
        assert_eq(r.jobs[4].evidenceId, EV3)
        -- results: a ready one is hidden from a non-tech, released/failed are shown
        assert_eq(r.jobs[2].result, nil)
        assert_eq(r.jobs[3].result.ethanol, 0.08)
        assert_true(r.jobs[4].result ~= nil)
        assert_eq(r.next, nil)
        -- the lab tech sees the ready result
        local t = api:ListLabJobs({ evidenceIds = { EV1 }, viewer = TECH })
        assert_eq(t.jobs[2].result.match, 'B22CIV')
        -- one state only
        local q = api:ListLabJobs({ evidenceIds = { EV1, EV2 }, state = 'queued', viewer = COP })
        assert_eq(#q.jobs, 1)
        assert_eq(q.jobs[1].id, J.a)
    end)

    it('pages one state newest first with a cursor', function()
        local t0 = 1800001000
        local ids = {}
        for i = 1, 5 do ids[i] = insertJob(EV3, 'trace', 'processing', nil, t0 + i) end
        local p1 = api:ListLabJobs({ state = 'processing', limit = 2, viewer = COP })
        assert_true(p1.ok)
        assert_eq(#p1.jobs, 2)
        assert_true(p1.jobs[1].id > p1.jobs[2].id, 'newest first')
        assert_true(p1.next ~= nil)
        local seen = {}
        for _, j in ipairs(p1.jobs) do seen[j.id] = true end
        local p2 = api:ListLabJobs({ state = 'processing', limit = 2, after = p1.next, viewer = COP })
        assert_eq(#p2.jobs, 2)
        for _, j in ipairs(p2.jobs) do
            assert_true(not seen[j.id], 'no repeats')
            assert_true(j.id < p1.next)
        end
        MySQL.query.await("DELETE FROM pf_evidence_lab_jobs WHERE evidence_id = ? AND test = 'trace'", { EV3 })
    end)

    it('refuses bad filters, a viewer who is not on-duty police, and other resources', function()
        assert_eq(api:ListLabJobs({ viewer = COP }).error, 'bad_args')
        assert_eq(api:ListLabJobs({ state = 'bogus', viewer = COP }).error, 'bad_args')
        assert_eq(api:ListLabJobs({ evidenceIds = {}, viewer = COP }).error, 'bad_args')
        local many = {}
        for i = 1, 51 do many[i] = i end
        assert_eq(api:ListLabJobs({ evidenceIds = many, viewer = COP }).error, 'bad_args')
        assert_eq(api:ListLabJobs({ evidenceIds = { 'x' }, viewer = COP }).error, 'bad_args')
        assert_eq(api:ListLabJobs({ state = 'queued', limit = 101, viewer = COP }).error, 'bad_args')
        assert_eq(api:ListLabJobs({ evidenceIds = { EV1 }, viewer = CIV }).error, 'no_permission')
        assert_eq(api:ListLabJobs({ evidenceIds = { EV1 }, viewer = OFFDUTY }).error, 'no_permission')
        as('pf-justice')
        assert_eq(api:ListLabJobs({ evidenceIds = { EV1 }, viewer = COP }).error, 'not_allowed')
        as('pf-policemdt-DEV')
        MySQL.query.await('DELETE FROM pf_evidence_lab_jobs WHERE evidence_id IN (?, ?, ?)', { EV1, EV2, EV3 })
    end)
end)
