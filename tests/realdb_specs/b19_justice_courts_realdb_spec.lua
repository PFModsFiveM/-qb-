-- pf-justice courts and warrant reviews on the real database (batch 19, unit 19A):
--   * schema v3 (courts), v4 (supervision) and v5 (community service): created on a fresh database next to
--     v1/v2, widen a cases table made from the documented DDL, rerun-safe, a second run applies nothing;
--   * FileCase exactly as pf-policemdt-DEV cases.lua HandOver calls it (key pf-policemdt:case:<id>:court:<n>,
--     system actor, filedBy): integer caseId, same key = same case, key_reused, refs, automatic arraignment,
--     mail + calendar notices;
--   * decisions through the 15B order API: plea, trial, verdict, sentence (orders keyed per decision, court
--     fine to society:doj, a retry creates nothing new), bail denied (custody remanded + remand order),
--     dismissal (remand vacated, custody released), release order (ends a remand without minutes);
--   * low population: the schedule enters a not-guilty plea and bail by charge class only when no judge is on
--     duty; trials never auto-decide;
--   * IsCourtOrderValid exactly as pf-ambulancejob (medical_records), pfm-policejob telemetry and evidence
--     custody (evidence_destroy with { evidenceId, tag }) call it: purpose, person, expiry, revocation;
--   * RequestWarrantReview exactly as pf-policemdt-DEV records_ext.lua calls it, the judge's decision sent back
--     through SetWarrantApproval(warrantId, decision, { reviewId, ... }), a retry when the MDT was away, the
--     needs_info reopen and the no-judge police fallback.
load_resource('tests/lua/fivem_mocks.lua')
load_resource('tests/lua/real_mysql.lua')
function IsDuplicityVersion() return true end
local states = { ['pf-ambulancejob'] = 'missing', ['pf-services'] = 'missing', ['pfm-prison'] = 'missing', ['pf-government'] = 'missing' }
function GetResourceState(name) return states[name] or 'started' end

RealDB.exec('pfm-core/qbcore.sql')
RealDB.exec('pfm-banking/banking.sql')
QBCoreMock.Shared.Jobs = { police = { label = 'Police' }, doj = { label = 'DOJ' }, judge = { label = 'Judiciary' } }

-- the real ledger (fines and bail need the societies)
function GetCurrentResourceName() return 'pfm-banking' end
Config = nil
load_resource('pfm-banking/config.lua')
load_resource('pfm-core/server/migrations.lua')
load_resource('pfm-banking/server_ledger.lua')
load_resource('pfm-banking/server.lua')
local bankingConfig = Config
Mock.exportsByResource['pfm-banking'] = Mock.exportsByResource['__self']
Mock.exportsByResource['__self'] = nil
Mock.exportsByResource['pfm-core'].RunMigrations = function(_, res, list) return RunMigrations(res, list) end
assert(PFLedger.Start(), 'ledger start')

Mock.exportsByResource['pfm-inventory'] = {
    CreateInventory = function() return true end, GetInventory = function() return { items = {} } end, SaveStash = function() end,
    ClearStash = function() end, CanAddItem = function() return true end, ClearInventory = function() end,
    AddItem = function() return true end, RemoveItem = function() return true end,
}
Mock.exportsByResource['pfm-policejob'] = { SetCuffed = function() return true end, IsCuffed = function() return false end }
function SetEntityCoords() end

-- pf-citizen notices
local mails, calendar = {}, {}
Mock.exportsByResource['pf-citizen'] = {
    SendMail = function(_, cid, opts) mails[#mails + 1] = { cid = cid, opts = opts } return #mails end,
    AddCalendarEvent = function(_, scope, owner, p, byName) calendar[#calendar + 1] = { scope = scope, owner = owner, p = p, by = byName } return #calendar end,
}

-- pf-policemdt-DEV SetWarrantApproval, as records_ext.lua: only pf-justice may call it
local approvals, mdtAnswer = {}, nil
Mock.exportsByResource['pf-policemdt-DEV'] = {
    SetWarrantApproval = function(_, warrantId, decision, opts)
        if mdtAnswer == 'throw' then error('No such export SetWarrantApproval in resource pf-policemdt-DEV') end
        approvals[#approvals + 1] = { warrantId = warrantId, decision = decision, opts = opts }
        return mdtAnswer or { ok = true }
    end,
}

-- pf-justice as its fxmanifest loads it (19B/19C files are not part of this unit's spec)
function GetCurrentResourceName() return 'pf-justice' end
Config = nil
PFPayout = nil
load_resource('pfm-banking/payouts.lua')
for _, f in ipairs({ 'config.lua', 'shared/states.lua', 'server/main.lua', 'server/schema.lua', 'server/orders.lua',
    'server/clock.lua', 'server/records.lua', 'server/custody.lua', 'server/booking.lua', 'server/property.lua',
    'server/bail.lua', 'server/legacy_import.lua', 'server/compat.lua', 'server/courts.lua', 'server/warrants.lua', 'server/restitution.lua', 'server/api.lua' }) do
    load_resource('[pfscripts]/pf-justice/' .. f)
end
for k, v in pairs(bankingConfig) do if Config[k] == nil then Config[k] = v end end
Mock.exportsByResource['pf-justice'] = Mock.exportsByResource['__self']
local J = PFJustice
local Courts, W = J.Courts, J.Warrants
local api = exports['pf-justice']

local COP, SUS, JUDGE, CLERK, SGT, PROS = 1, 2, 3, 4, 5, 6
local function n(sql, p) return tonumber(MySQL.scalar.await(sql, p or {})) or 0 end
local function one(sql, p) return MySQL.single.await(sql, p or {}) end
local function as(res) Mock.invokingResource = res end
local function job(src, cid, name, grade, onduty, jtype)
    local P = Mock.newPlayer(src, cid)
    P.PlayerData.job = { name = name, type = jtype, grade = { level = grade }, onduty = onduty ~= false }
    return P
end
local function tableExists(t)
    return n('SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?', { t }) == 1
end
local function openCustody(cid, state)
    return MySQL.insert.await([[INSERT INTO pf_justice_custody (citizenid, state, facility, officer_cid, opened_at, updated_at)
        VALUES (?, ?, 'mrpd_holding', 'COPCID', ?, ?)]], { cid, state or 'held', os.time(), os.time() })
end
local seq = 0
local function cid(prefix) seq = seq + 1 return (prefix or 'DEF') .. seq end
-- the shape pf-policemdt-DEV cases.lua Submit builds and HandOver sends
local function fileFromMdt(defendant, caseId, subId, extra)
    local spec = { cid = defendant, charges = { { code = 'PC-484', name = 'Theft' } }, incidentIds = { '12' }, evidenceIds = { 41 },
        prosecutorCid = nil, mdtCaseId = caseId, mdtCaseNo = 'C-' .. caseId, title = 'Shop theft', note = 'cctv', filedBy = 'COPCID' }
    for k, v in pairs(extra or {}) do spec[k] = v end
    as('pf-policemdt-DEV')
    local res = api:FileCase(spec, { key = ('pf-policemdt:case:%d:court:%d'):format(caseId, subId),
        actor = { kind = 'system', label = 'pf-policemdt case submission' }, filedBy = 'COPCID' })
    as(nil)
    return res
end
local function decide(caseId, decision, key, actorSrc)
    return Courts.RecordDecision(caseId, decision, { actor = { src = actorSrc or JUDGE }, key = key }, {})
end
local function caseRow(id) return one('SELECT * FROM pf_justice_cases WHERE id = ?', { id }) end

BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    Mock.clock = Mock.clock + 10
    mails, calendar, approvals, mdtAnswer = {}, {}, {}, nil
    J.Rate.Forget('')
    job(COP, 'COPCID', 'police', 2, true, 'leo')
    Mock.newPlayer(SUS, 'SUSCID')
    job(JUDGE, 'JUDGECID', 'judge', 1, true)
    job(CLERK, 'CLERKCID', 'doj', 0, true, 'doj')
    job(SGT, 'SGTCID', 'police', 4, true, 'leo')
    job(PROS, 'PROSCID', 'doj', 1, true, 'doj')
    as(nil)
end

describe('schema v3, v4, v5', function()
    it('a fresh database gets every batch-19 table; a cases table from the documented DDL is widened', function()
        MySQL.query.await([[CREATE TABLE `pf_justice_cases` (
          `id` INT NOT NULL AUTO_INCREMENT, `case_no` VARCHAR(20) NOT NULL, `citizenid` VARCHAR(64) NOT NULL,
          `state` VARCHAR(24) NOT NULL, `kind` VARCHAR(12) NOT NULL DEFAULT 'criminal',
          `charges` LONGTEXT NULL, `custody_id` INT NULL, `mdt_case_id` INT NULL, `prosecutor_cid` VARCHAR(64) NULL,
          `defender_cid` VARCHAR(64) NULL, `judge_cid` VARCHAR(64) NULL, `filed_by` VARCHAR(64) NOT NULL,
          `filed_at` BIGINT NOT NULL, `closed_at` BIGINT NULL, `idem_key` VARCHAR(128) NULL,
          PRIMARY KEY (`id`), UNIQUE KEY `uq_jcase_no` (`case_no`), UNIQUE KEY `uq_jcase_key` (`idem_key`), KEY `idx_jcase_cid` (`citizenid`, `state`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
        assert_true(J.Boot(), 'boot')
        for _, t in ipairs({ 'pf_justice_cases', 'pf_justice_case_refs', 'pf_justice_hearings', 'pf_justice_decisions',
            'pf_justice_warrant_reviews', 'pf_justice_court_orders', 'pf_justice_supervision', 'pf_justice_supervision_events',
            'pf_justice_cs_shifts', 'pf_justice_cs_tasks' }) do
            assert_true(tableExists(t), t)
        end
        assert_eq(n([[SELECT CHARACTER_MAXIMUM_LENGTH FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE()
            AND TABLE_NAME = 'pf_justice_cases' AND COLUMN_NAME = 'kind']]), 16, "'citation_contest' fits")
        for _, t in ipairs({ 'pf_justice_hearings', 'pf_justice_decisions', 'pf_justice_warrant_reviews', 'pf_justice_court_orders' }) do
            assert_eq(n([[SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?
                AND COLUMN_NAME = 'idem_key' AND NON_UNIQUE = 0]], { t }), 1, t .. ' idem_key unique')
        end
        assert_eq(n("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = 'pf-justice' AND version IN (1, 2, 3, 4, 5)"), 5)
        assert_true(J.Schema.Has(3) and J.Schema.Has(4) and J.Schema.Has(5), 'Has(v)')
    end)

    it('is rerun-safe (every v3-v5 step again) and a second run applies nothing', function()
        MySQL.query.await("DELETE FROM pf_schema_migrations WHERE resource = 'pf-justice' AND version IN (3, 4, 5)")
        assert_true(J.Schema.Run())
        assert_eq(n("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = 'pf-justice'"), 5)
        assert_true(J.Schema.Run())
        assert_eq(n("SELECT COUNT(*) FROM pf_schema_migrations WHERE resource = 'pf-justice'"), 5)
        -- the 19B/19C tables take the documented rows
        MySQL.insert.await("INSERT INTO pf_justice_supervision (order_id, citizenid, state, created_at) VALUES (1, 'X', 'active', 1)")
        MySQL.insert.await("INSERT INTO pf_justice_cs_tasks (shift_id, order_id, work_order_id, claim_id, kind, steps_needed, state, started_at) VALUES (1, 1, 1, 1, 'litter', 3, 'active', 1)")
        assert_eq(n('SELECT units FROM pf_justice_cs_shifts WHERE id = 0'), 0)
    end)
end)

describe('FileCase as pf-policemdt-DEV hands a submission over', function()
    it('files once per key, with an integer case id, refs, an arraignment and notices', function()
        local d = cid()
        local res = fileFromMdt(d, 7, 3)
        assert_true(res.ok, tostring(res.error) .. ' ' .. tostring(res.message))
        assert_eq(math.type(res.caseId), 'integer')
        local row = caseRow(res.caseId)
        assert_eq(row.citizenid, d)
        assert_eq(row.filed_by, 'COPCID')
        assert_eq(row.idem_key, 'pf-policemdt:case:7:court:3')
        assert_true(row.case_no:match('^CR%d%d%-%d+$') ~= nil, row.case_no)
        assert_eq(row.state, 'arraignment_scheduled', 'arraignment set at once')
        assert_eq(n('SELECT COUNT(*) FROM pf_justice_case_refs WHERE case_id = ?', { res.caseId }), 3, 'incident, evidence, mdt case')
        assert_eq(n("SELECT COUNT(*) FROM pf_justice_hearings WHERE case_id = ? AND kind = 'arraignment' AND state = 'scheduled'", { res.caseId }), 1)
        assert_true(#mails >= 2, 'filed + hearing mail')
        assert_eq(mails[1].cid, d)
        assert_eq(calendar[1].owner, d)
        assert_eq(calendar[1].scope, 'personal')
        -- the sweep's retry with the same key: the same case, nothing new
        local again = fileFromMdt(d, 7, 3)
        assert_true(again.ok and again.duplicate)
        assert_eq(again.caseId, res.caseId)
        assert_eq(n('SELECT COUNT(*) FROM pf_justice_cases WHERE citizenid = ?', { d }), 1)
        -- the same key for another defendant is refused; HandOver treats key_reused as final
        assert_eq(fileFromMdt(cid(), 7, 3).error, 'key_reused')
    end)

    it('a defendant in custody is arraigned within the in-custody delay; refusals keep their codes', function()
        local d = cid()
        openCustody(d)
        local res = fileFromMdt(d, 8, 1)
        assert_true(res.ok)
        local h = one("SELECT at FROM pf_justice_hearings WHERE case_id = ? AND kind = 'arraignment'", { res.caseId })
        assert_eq(tonumber(h.at), os.time() + Config.Courts.ArraignmentInCustodySeconds)
        as('pf-government')
        assert_eq(api:FileCase({ cid = d, charges = { { code = 'X' } } }, { key = 'k:1' }).error, 'not_allowed')
        as('pf-policemdt-DEV')
        assert_eq(api:FileCase({ cid = d, charges = { { code = 'X' } } }, {}).error, 'bad_args', 'a key is required')
        assert_eq(api:FileCase({ cid = d, charges = {} }, { key = 'k:2' }).error, 'bad_args', 'a criminal case has charges')
        as(nil)
    end)
end)

describe('FileCase as 19C files an overdue community-service order (PFJustice.API)', function()
    it('a violation case without charges from the penal code, once per key, with a violation hearing; sentenced from it', function()
        local d = cid()
        assert_true(J.API.FileCase ~= nil, 'installed at boot')
        local spec = { cid = d, kind = 'violation', orderId = 77,
            charges = { { code = 'CS-DEADLINE', label = 'Community service order #77 not completed by its deadline (2 of 10 units)', count = 1 } } }
        local opts = { key = 'pf-justice:cs:order:77:court', actor = { kind = 'system', label = 'community service' }, filedBy = 'system' }
        local res = J.API.FileCase(spec, opts)
        assert_true(res.ok, tostring(res.error) .. ' ' .. tostring(res.message))
        local row = caseRow(res.caseId)
        assert_eq(row.kind, 'violation')
        assert_true(row.case_no:match('^VI') ~= nil)
        assert_eq(row.state, 'hearing_scheduled')
        assert_eq(n("SELECT COUNT(*) FROM pf_justice_case_refs WHERE case_id = ? AND ref_type = 'order' AND ref_id = '77'", { res.caseId }), 1)
        assert_eq(n("SELECT COUNT(*) FROM pf_justice_hearings WHERE case_id = ? AND kind = 'violation'", { res.caseId }), 1)
        local again = J.API.FileCase(spec, opts)
        assert_true(again.duplicate)
        assert_eq(again.caseId, res.caseId)
        -- the schedule never decides a violation; a judge may give more community service, never automatic prison
        Mock.players[JUDGE] = nil
        Courts.lastJudgeAt = 0
        MySQL.update.await('UPDATE pf_justice_hearings SET at = ? WHERE case_id = ?', { os.time() - 7200, res.caseId })
        Courts.AutoTick(os.time())
        assert_eq(caseRow(res.caseId).state, 'hearing_scheduled')
        job(JUDGE, 'JUDGECID', 'judge', 1, true)
        local s = decide(res.caseId, { kind = 'sentence', orders = { { kind = 'community_service', units = 5 } } })
        assert_true(s.ok, tostring(s.error) .. ' ' .. tostring(s.message))
        assert_eq(one('SELECT kind FROM pf_justice_orders WHERE id = ?', { s.orders[1] }).kind, 'community_service')
    end)
end)

describe('decisions create orders through the 15B API', function()
    it('plea, trial, verdict and sentence; a court fine goes to society:doj; a retry creates nothing new', function()
        local d = cid()
        local res = fileFromMdt(d, 20, 1)
        local id = res.caseId
        -- only a judge takes a plea; an off-duty judge is told so
        assert_eq(decide(id, { kind = 'plea', plea = 'guilty' }, nil, COP).error, 'no_permission')
        Mock.players[JUDGE].PlayerData.job.onduty = false
        assert_eq(decide(id, { kind = 'plea', plea = 'guilty' }).error, 'not_on_duty')
        Mock.players[JUDGE].PlayerData.job.onduty = true
        assert_true(decide(id, { kind = 'plea', plea = 'not_guilty' }, 'test:plea:' .. id).ok)
        assert_eq(caseRow(id).state, 'plea_not_guilty')
        assert_eq(n("SELECT COUNT(*) FROM pf_justice_hearings WHERE case_id = ? AND kind = 'arraignment' AND state = 'held'", { id }), 1)
        -- a clerk sets the trial; a police officer may not
        assert_eq(Courts.ScheduleHearing(id, { kind = 'trial', at = os.time() + 3600 }, { actor = { src = COP } }, {}).error, 'no_permission')
        local h = Courts.ScheduleHearing(id, { kind = 'trial', at = os.time() + 3600, courtroom = 'courtroom_2' }, { actor = { src = CLERK } }, {})
        assert_true(h.ok, tostring(h.error))
        assert_eq(caseRow(id).state, 'trial_scheduled')
        assert_eq(decide(id, { kind = 'sentence', orders = { { kind = 'fine', amount = 500 } } }).error, 'invalid_state', 'no sentence before a verdict')
        assert_true(decide(id, { kind = 'verdict', verdict = 'guilty' }).ok)
        assert_true(Courts.ScheduleHearing(id, { kind = 'sentencing', at = os.time() + 600 }, { actor = { src = JUDGE } }, {}).ok)
        -- a bad order is refused before anything is written
        assert_eq(decide(id, { kind = 'sentence', orders = { { kind = 'prison', minutes = 0 } } }).error, 'bad_args')
        assert_eq(n('SELECT COUNT(*) FROM pf_justice_decisions WHERE case_id = ? AND kind = \'sentence\'', { id }), 0)
        local key = 'test:sentence:' .. id
        local s = decide(id, { kind = 'sentence', orders = { { kind = 'jail', minutes = 30 }, { kind = 'fine', amount = 500 } } }, key)
        assert_true(s.ok, tostring(s.error) .. ' ' .. tostring(s.message))
        assert_eq(#s.orders, 2)
        assert_eq(caseRow(id).state, 'sentenced')
        assert_eq(caseRow(id).judge_cid, 'JUDGECID')
        local fine = one('SELECT * FROM pf_justice_orders WHERE id = ?', { s.orders[2] })
        assert_eq(fine.source_type, 'court_decision')
        assert_eq(fine.source_id, tostring(s.decisionId))
        assert_eq(fine.idem_key, ('pf-justice:court:%d:order:2'):format(s.decisionId))
        assert_eq(J.Orders.Account(fine), 'doj', 'court fines to society:doj (D4)')
        assert_eq(one('SELECT kind FROM pf_justice_orders WHERE id = ?', { s.orders[1] }).kind, 'jail')
        local again = decide(id, { kind = 'sentence', orders = { { kind = 'jail', minutes = 30 }, { kind = 'fine', amount = 500 } } }, key)
        assert_true(again.ok and again.duplicate)
        assert_eq(n("SELECT COUNT(*) FROM pf_justice_orders WHERE source_type = 'court_decision' AND source_id = ?", { tostring(s.decisionId) }), 2)
        assert_eq(n('SELECT COUNT(*) FROM pf_justice_audit WHERE entity = \'case\' AND entity_id = ? AND action = \'decision\'', { tostring(id) }), 3, 'plea, verdict, sentence')
    end)

    it('bail denied remands the custody under a remand order; dismissal vacates it and releases the custody', function()
        local d = cid()
        local custodyId = openCustody(d, 'held')
        local id = fileFromMdt(d, 30, 1, { custodyId = custodyId }).caseId
        local b = decide(id, { kind = 'bail', denied = true })
        assert_true(b.ok, tostring(b.error) .. ' ' .. tostring(b.message))
        assert_true(b.custodyRemanded)
        assert_eq(one('SELECT state FROM pf_justice_custody WHERE id = ?', { custodyId }).state, 'remanded')
        local remand = one('SELECT * FROM pf_justice_orders WHERE id = ?', { b.remandOrderId })
        assert_eq(remand.kind, 'remand')
        assert_eq(remand.state, 'active')
        assert_eq(n("SELECT COUNT(*) FROM pf_justice_orders WHERE citizenid = ? AND kind = 'remand'", { d }), 1)
        -- a prosecutor may drop the case
        local dm = decide(id, { kind = 'dismissal', note = 'insufficient evidence' }, nil, PROS)
        assert_true(dm.ok, tostring(dm.error))
        assert_eq(caseRow(id).state, 'dismissed')
        assert_true(caseRow(id).closed_at ~= nil)
        assert_eq(one('SELECT state FROM pf_justice_orders WHERE id = ?', { b.remandOrderId }).state, 'vacated')
        assert_true(one('SELECT closed_at FROM pf_justice_custody WHERE id = ?', { custodyId }).closed_at ~= nil, 'custody released')
        assert_eq(decide(id, { kind = 'plea', plea = 'guilty' }).error, 'invalid_state', 'a closed case takes no decision')
    end)

    it('bail with an amount is offered on the custody; a release order ends a remand without minutes', function()
        local d = cid()
        local custodyId = openCustody(d, 'held')
        local id = fileFromMdt(d, 31, 1, { custodyId = custodyId }).caseId
        local b = decide(id, { kind = 'bail', amount = 2500 })
        assert_true(b.ok, tostring(b.error) .. ' ' .. tostring(b.message))
        local bail = one('SELECT * FROM pf_justice_bail WHERE id = ?', { b.bailId })
        assert_eq(bail.state, 'offered')
        assert_eq(tonumber(bail.amount), 2500)
        assert_eq(tonumber(bail.custody_id), custodyId)
        assert_eq(tonumber(bail.expires_at), os.time() + Config.Courts.BailOfferSeconds, 'a court bail stays open a day, not 10 minutes')
        -- remand (no minutes: the clock never ends it) and a court-ordered release
        local d2 = cid()
        local c2 = openCustody(d2, 'held')
        local id2 = fileFromMdt(d2, 32, 1, { custodyId = c2 }).caseId
        local r = decide(id2, { kind = 'bail', denied = true })
        assert_true(r.ok)
        assert_eq(Courts.IssueReleaseOrder(d2, { reason = 'x' }, { actor = { src = COP } }, {}).error, 'no_permission')
        local rel = Courts.IssueReleaseOrder(d2, { reason = 'charges dropped', caseId = id2 }, { actor = { src = JUDGE }, key = 'test:rel:' .. id2 }, {})
        assert_true(rel.ok, tostring(rel.error))
        assert_eq(rel.released, 1)
        assert_eq(one('SELECT state FROM pf_justice_orders WHERE id = ?', { r.remandOrderId }).state, 'vacated')
        assert_true(one('SELECT closed_at FROM pf_justice_custody WHERE id = ?', { c2 }).closed_at ~= nil)
        assert_eq(one("SELECT kind FROM pf_justice_court_orders WHERE id = ?", { rel.releaseOrderId }).kind, 'release')
        local again = Courts.IssueReleaseOrder(d2, { reason = 'charges dropped' }, { actor = { src = JUDGE }, key = 'test:rel:' .. id2 }, {})
        assert_true(again.duplicate)
    end)
end)

describe('low population: the published schedule', function()
    it('with no judge on duty an overdue arraignment gets a not-guilty plea and schedule bail; never with a judge', function()
        local d = cid()
        local custodyId = openCustody(d, 'held')
        local id = fileFromMdt(d, 40, 1, { custodyId = custodyId }).caseId
        MySQL.update.await("UPDATE pf_justice_hearings SET at = ? WHERE case_id = ?", { os.time() - 3600, id })
        -- a judge on duty: the schedule stays out
        Courts.lastJudgeAt = 0
        assert_eq(Courts.AutoTick(os.time()), 0)
        assert_eq(caseRow(id).state, 'arraignment_scheduled')
        -- no judge for long enough
        Mock.players[JUDGE] = nil
        Courts.lastJudgeAt = os.time() - 7200
        assert_true(Courts.AutoTick(os.time()) >= 2)
        assert_eq(caseRow(id).state, 'plea_not_guilty')
        local plea = one("SELECT * FROM pf_justice_decisions WHERE case_id = ? AND kind = 'plea'", { id })
        assert_eq(plea.decided_by, 'schedule')
        local bail = one('SELECT * FROM pf_justice_bail WHERE custody_id = ? ORDER BY id DESC LIMIT 1', { custodyId })
        assert_eq(tonumber(bail.amount), Config.Courts.DefaultBail.misdemeanor)
        assert_eq(one("SELECT state FROM pf_justice_hearings WHERE case_id = ? AND kind = 'arraignment'", { id }).state, 'auto')
        -- a trial is never decided by the schedule
        assert_true(Courts.ScheduleHearing(id, { kind = 'trial', at = os.time() }, { actor = { src = CLERK } }, {}).ok)
        Mock.clock = Mock.clock + 7200
        Courts.AutoTick(os.time())
        assert_eq(caseRow(id).state, 'trial_scheduled')
        assert_eq(n("SELECT COUNT(*) FROM pf_justice_decisions WHERE case_id = ? AND kind = 'verdict'", { id }), 0)
    end)

    it('an infraction is released on own recognizance by the schedule', function()
        local d = cid()
        local custodyId = openCustody(d, 'held')
        local id = fileFromMdt(d, 41, 1, { custodyId = custodyId, charges = { { code = 'PC-415', name = 'Disturbing the Peace' } } }).caseId
        MySQL.update.await("UPDATE pf_justice_hearings SET at = ? WHERE case_id = ?", { os.time() - 3600, id })
        Mock.players[JUDGE] = nil
        Courts.lastJudgeAt = os.time() - 7200
        Courts.AutoTick(os.time())
        assert_true(one('SELECT closed_at FROM pf_justice_custody WHERE id = ?', { custodyId }).closed_at ~= nil)
        assert_eq(one('SELECT release_reason FROM pf_justice_custody WHERE id = ?', { custodyId }).release_reason, 'court_order')
    end)
end)

describe('IsCourtOrderValid as the batch-17/18 callers call it', function()
    it('medical_records and telemetry: purpose, person, expiry and revocation; unknown callers get false', function()
        local issued = Courts.CommandCourtOrder(JUDGE, { 'medical_records', 'PATCID', '24' })
        assert_true(issued.ok, tostring(issued.error))
        local ref = issued.ref
        -- pf-ambulancejob diagnosis.lua: exports['pf-justice']:IsCourtOrderValid(ref, 'medical_records', cid)
        as('pf-ambulancejob')
        assert_eq(api:IsCourtOrderValid(ref, 'medical_records', 'PATCID'), true)
        assert_eq(api:IsCourtOrderValid(ref, 'medical_records', 'OTHER'), false, 'another person')
        assert_eq(api:IsCourtOrderValid(ref, 'telemetry', 'PATCID'), false, 'another purpose')
        assert_eq(api:IsCourtOrderValid('CO-0000-999999', 'medical_records', 'PATCID'), false, 'unknown ref')
        as('pf-hacked')
        assert_eq(api:IsCourtOrderValid(ref, 'medical_records', 'PATCID'), false, 'not on the allowlist')
        -- pfm-policejob telemetry.lua
        local t = Courts.CommandCourtOrder(JUDGE, { 'telemetry', 'COPCID' })
        as('pfm-policejob')
        assert_eq(api:IsCourtOrderValid(t.ref, 'telemetry', 'COPCID'), true)
        -- a police officer cannot issue one
        assert_false(Courts.CommandCourtOrder(COP, { 'telemetry', 'COPCID' }).ok)
        -- expiry and revocation
        Mock.clock = Mock.clock + 25 * 3600
        as('pf-ambulancejob')
        assert_eq(api:IsCourtOrderValid(ref, 'medical_records', 'PATCID'), false, 'expired after 24 h')
        as('pfm-policejob')
        assert_eq(api:IsCourtOrderValid(t.ref, 'telemetry', 'COPCID'), true, 'default 72 h')
        assert_true(Courts.RevokeCourtOrder(t.ref, { actor = { src = JUDGE } }, {}).ok)
        assert_eq(api:IsCourtOrderValid(t.ref, 'telemetry', 'COPCID'), false, 'revoked')
        as(nil)
    end)

    it('evidence disposal: the order must name the evidence (pfm-policejob evidence/custody.lua call shape)', function()
        local o = Courts.CommandCourtOrder(JUDGE, { 'evidence_destroy', '-', '48', '41,42' })
        assert_true(o.ok, tostring(o.error))
        as('pfm-policejob')
        assert_eq(api:IsCourtOrderValid(o.ref, 'evidence_destroy', nil, { evidenceId = 41, tag = 'EV-41' }), true)
        assert_eq(api:IsCourtOrderValid(o.ref, 'evidence_destroy', nil, { evidenceId = 43, tag = 'EV-43' }), false)
        assert_eq(api:IsCourtOrderValid(o.ref, 'evidence_release', nil, { evidenceId = 41 }), false, 'release needs a release order')
        local rel = Courts.CommandCourtOrder(JUDGE, { 'evidence_release', 'OWNERCID', '48', '50' })
        assert_eq(api:IsCourtOrderValid(rel.ref, 'evidence_release', 'OWNERCID', { evidenceId = 50, tag = 'EV-50' }), true)
        assert_eq(api:IsCourtOrderValid(rel.ref, 'evidence_release', 'SOMEONE', { evidenceId = 50 }), false, 'released to the named owner only')
        assert_eq(api:IsCourtOrderValid(rel.ref, 'evidence_release', nil, { evidenceId = 50 }), false)
        as(nil)
        assert_false(Courts.CommandCourtOrder(JUDGE, { 'evidence_destroy', '-' }).ok, 'an evidence order names the evidence')
    end)
end)

describe('warrant reviews with pf-policemdt-DEV', function()
    local function request(wid, extra)
        local spec = { warrantId = wid, type = 'arrest', targetCid = 'SUSCID', address = nil, affidavit = 'Seen on camera', requestedBy = 'COPCID' }
        for k, v in pairs(extra or {}) do spec[k] = v end
        as('pf-policemdt-DEV')
        local res = api:RequestWarrantReview(spec, { key = 'pf-policemdt:warrant:' .. wid .. ':review' })
        as(nil)
        return res
    end

    it('one review per key; the judge decision reaches SetWarrantApproval with the review id', function()
        local res = request('W2611170001')
        assert_true(res.ok, tostring(res.error))
        assert_eq(math.type(res.reviewId), 'integer')
        local again = request('W2611170001')
        assert_true(again.duplicate)
        assert_eq(again.reviewId, res.reviewId)
        assert_eq(n("SELECT COUNT(*) FROM pf_justice_warrant_reviews WHERE warrant_id = 'W2611170001'"), 1)
        assert_eq(request('W2611170001', { type = 'search', address = 'x' }).error, 'key_reused')
        -- a police officer cannot decide while a judge is on duty
        assert_false(W.CommandDecide(SGT, { tostring(res.reviewId), 'approve' }).ok)
        assert_eq(W.CommandDecide(JUDGE, { tostring(res.reviewId), 'deny' }).error, 'bad_args', 'a denial says why')
        local d = W.CommandDecide(JUDGE, { tostring(res.reviewId), 'approve' })
        assert_true(d.ok and d.notified)
        assert_eq(#approvals, 1)
        assert_eq(approvals[1].warrantId, 'W2611170001')
        assert_eq(approvals[1].decision, 'approve')
        assert_eq(approvals[1].opts.reviewId, res.reviewId)
        assert_eq(approvals[1].opts.judgeCid, 'JUDGECID')
        local row = one('SELECT * FROM pf_justice_warrant_reviews WHERE id = ?', { res.reviewId })
        assert_eq(row.state, 'approved')
        assert_eq(row.notify_state, 'sent')
        assert_true(#mails >= 1 and mails[#mails].cid == 'COPCID', 'the requesting officer is told')
        assert_eq(W.CommandDecide(JUDGE, { tostring(res.reviewId), 'deny', 'no' }).error, 'invalid_state')
    end)

    it('a decision the MDT did not receive is sent again by the tick; needs_info reopens with a new affidavit', function()
        local res = request('W2611170002')
        mdtAnswer = 'throw'
        local d = W.CommandDecide(JUDGE, { tostring(res.reviewId), 'needs_info', 'which', 'camera?' })
        assert_true(d.ok)
        assert_false(d.notified)
        assert_eq(one('SELECT notify_state FROM pf_justice_warrant_reviews WHERE id = ?', { res.reviewId }).notify_state, 'pending')
        mdtAnswer = nil
        assert_eq(W.Tick(os.time()), 1)
        assert_eq(approvals[#approvals].decision, 'needs_info')
        assert_eq(approvals[#approvals].opts.note, 'which camera?')
        assert_eq(W.Tick(os.time()), 0, 'sent once')
        -- the officer answers: the same key with a new affidavit asks the judge again
        local re = request('W2611170002', { affidavit = 'Camera 4 at the bank, 14:02' })
        assert_true(re.ok and re.reopened)
        assert_eq(re.reviewId, res.reviewId)
        assert_eq(one('SELECT state FROM pf_justice_warrant_reviews WHERE id = ?', { res.reviewId }).state, 'requested')
    end)

    it('without any judge the police fallback decides after the wait, never the requester', function()
        local res = request('W2611170003')
        Mock.players[JUDGE] = nil
        Courts.lastJudgeAt = os.time() - 7200
        assert_false(W.CommandDecide(SGT, { tostring(res.reviewId), 'approve' }).ok, 'too soon after the request')
        Mock.clock = Mock.clock + 1900
        job(7, 'COPCID', 'police', 4, true, 'leo')   -- the requester, now a sergeant
        Mock.players[COP] = nil
        assert_eq(W.CommandDecide(7, { tostring(res.reviewId), 'approve' }).error, 'no_permission')
        job(8, 'LOWCID', 'police', 2, true, 'leo')
        assert_false(W.CommandDecide(8, { tostring(res.reviewId), 'approve' }).ok, 'grade below the fallback')
        local d = W.CommandDecide(SGT, { tostring(res.reviewId), 'approve' })
        assert_true(d.ok, tostring(d.error))
        assert_eq(approvals[#approvals].opts.judgeCid, 'SGTCID')
        assert_eq(n("SELECT COUNT(*) FROM pf_justice_audit WHERE entity = 'warrant_review' AND entity_id = ? AND detail LIKE '%fallback%'", { tostring(res.reviewId) }), 1)
    end)
end)

describe('RecordRestitution from the pfm-prison trust (19E)', function()
    local function restitution(d, amount)
        local res = J.API.CreateOrder({ cid = d, kind = 'restitution', amount = amount, victimCid = 'VICTIM1',
            sourceRef = { type = 'court_decision', id = 'r' .. d } }, { key = 'test:rest:' .. d })
        assert_true(res.ok, tostring(res.error))
        return res.orderId
    end
    local function pay(key, amount, to)
        local r = PFLedger.Transfer({ from = 'system:pfm-prison-trust', to = to or 'player:VICTIM1:bank', amount = amount, key = key,
            kind = 'restitution', reason = 'test' })
        assert_true(r.ok, 'ledger ' .. tostring(r.error))
    end
    local function record(orderId, amount, key, from)
        as('pfm-prison')
        local res = api:RecordRestitution(orderId, { amount = amount, ledgerKey = key, from = from or 'system:pfm-prison-trust' },
            { key = key, actor = { kind = 'system', label = 'pfm-prison trust' } })
        as(nil)
        return res
    end

    it('credits verified ledger payments once per key and settles the order when fully paid', function()
        Mock.newPlayer(20, 'VICTIM1')
        assert_eq(record(0, 1, 'pfm-prison:trust:X:0').error, 'bad_args', 'the probe answers bad_args')
        as('pf-random')
        assert_eq(api:RecordRestitution(1, { amount = 1 }, { key = 'k:1' }).error, 'not_allowed')
        as(nil)
        local d = cid('RES')
        local id = restitution(d, 1000)
        assert_eq(record(id, 400, 'pfm-prison:trust:' .. d .. ':1').error, 'not_found', 'no ledger row for the key')
        pay('pfm-prison:trust:' .. d .. ':1', 400)
        local r1 = record(id, 400, 'pfm-prison:trust:' .. d .. ':1')
        assert_true(r1.ok, tostring(r1.error))
        assert_eq(r1.applied, 400)
        assert_eq(r1.paidAmount, 400)
        assert_eq(r1.state, 'issued')
        local dup = record(id, 400, 'pfm-prison:trust:' .. d .. ':1')
        assert_true(dup.ok and dup.duplicate)
        assert_eq(tonumber(one('SELECT paid_amount FROM pf_justice_orders WHERE id = ?', { id }).paid_amount), 400, 'no second credit')
        assert_eq(record(id, 500, 'pfm-prison:trust:' .. d .. ':1').error, 'key_reused')
        -- wrong amount, payee, source
        pay('pfm-prison:trust:' .. d .. ':2', 300)
        assert_eq(record(id, 350, 'pfm-prison:trust:' .. d .. ':2').error, 'amount_mismatch')
        assert_eq(record(id, 300, 'pfm-prison:trust:' .. d .. ':2', 'system:elsewhere').error, 'source_mismatch')
        pay('pfm-prison:trust:' .. d .. ':3', 300, 'society:doj')
        assert_eq(record(id, 300, 'pfm-prison:trust:' .. d .. ':3').error, 'payee_mismatch')
        -- a later payment over what is owed is capped; the order settles through the state machine
        pay('pfm-prison:trust:' .. d .. ':4', 700)
        local r4 = record(id, 700, 'pfm-prison:trust:' .. d .. ':4')
        assert_true(r4.ok, tostring(r4.error))
        assert_eq(r4.applied, 600)
        assert_true(r4.settled)
        local row = one('SELECT * FROM pf_justice_orders WHERE id = ?', { id })
        assert_eq(row.state, 'paid')
        assert_eq(tonumber(row.paid_amount), 1000)
        assert_eq(n("SELECT COUNT(*) FROM pf_justice_order_events WHERE order_id = ? AND action = 'restitution'", { id }), 2)
        assert_eq(n("SELECT COUNT(*) FROM pf_justice_records WHERE ref_type = 'order' AND ref_id = ? AND kind = 'conviction'", { tostring(id) }), 1)
        pay('pfm-prison:trust:' .. d .. ':5', 10)
        assert_eq(record(id, 10, 'pfm-prison:trust:' .. d .. ':5').error, 'invalid_state', 'a paid order takes no more')
    end)

    it('an unsettled ledger key answers pending (retry the same key); a failed one is a clear failure', function()
        Mock.newPlayer(20, 'VICTIM1')
        local d = cid('RES')
        local id = restitution(d, 500)
        local bank = Mock.exportsByResource['pfm-banking']
        local real = bank.GetTransaction
        local fake
        bank.GetTransaction = function(_, key) return fake end
        fake = { tx_id = 'T1', state = 'debited', amount = '100.00', from_account = 'system:pfm-prison-trust', to_account = 'player:VICTIM1:bank' }
        assert_eq(record(id, 100, 'pfm-prison:trust:' .. d .. ':p').error, 'pending')
        fake.state = 'failed'
        assert_eq(record(id, 100, 'pfm-prison:trust:' .. d .. ':p').error, 'ledger_failed')
        fake.state = 'completed'
        local ok = record(id, 100, 'pfm-prison:trust:' .. d .. ':p')
        assert_true(ok.ok, 'the same key credits once the ledger completed it')
        assert_eq(ok.applied, 100)
        bank.GetTransaction = real
        assert_eq(record(id, 0, 'k:x').error, 'bad_args')
        assert_eq(record(id, 5, 'k:x', nil).error ~= nil, true)
    end)
end)
