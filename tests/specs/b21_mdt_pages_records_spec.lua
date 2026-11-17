-- Batch 21 (21A) pf-policemdt-DEV server/pages_records.lua, mocked:
--   * pf_mdt:cases:deathRecord: police only (gate), on duty, the link must belong to the case and be a
--     death_record link, the record comes from pf-ambulancejob GetDeathRecord (refusals passed on, a
--     stopped morgue reported), only the view fields leave, and every read writes an audit row
--     (no dedupe; a read that cannot be audited is not shown);
--   * pf_mdt:citations:list: police only, on duty, pf-justice GetOrders with kinds = { 'citation' },
--     detail rows from pf_justice_citations, paging by order id (`after`, `next`), field citations
--     not yet taken by pf-justice listed apart on the first page only, citizen read audited;
--   * manifest: loaded after server/pages_ext.lua; the client allowlist carries both names.
load_resource('tests/lua/fivem_mocks.lua')
function IsDuplicityVersion() return true end
local states = {}
function GetResourceState(name) return states[name] or 'missing' end
QBCore = QBCoreMock

local log, answers = {}, {}
local function run(kind, sql, params)
    log[#log + 1] = { kind = kind, sql = sql, params = params }
    for _, a in ipairs(answers) do
        if sql:find(a.match, 1, true) then
            if type(a.value) == 'function' then return a.value(sql, params) end
            return a.value
        end
    end
    if kind == 'insert' then return 1 end
    if kind == 'query' then return {} end
    return nil
end
local function op(kind) return { await = function(sql, p) return run(kind, sql, p) end } end
MySQL = { query = op('query'), insert = op('insert'), update = op('update'), single = op('single'), scalar = op('scalar') }
local function find(fragment)
    local out = {}
    for _, e in ipairs(log) do if e.sql:find(fragment, 1, true) then out[#out + 1] = e end end
    return out
end

local RES = '[pfscripts]/pf-policemdt-DEV/'
function GetCurrentResourceName() return 'pf-policemdt-DEV' end
Config = nil
load_resource(RES .. 'shared/framework.lua')
load_resource(RES .. 'config.lua')
load_resource(RES .. 'server/access.lua')
load_resource(RES .. 'server/schema.lua')
local audits = {}
PFMdtRecords = { Audit = function(by, entity, id, action, detail) audits[#audits + 1] = { by = by, entity = entity, id = id, action = action, detail = detail } return true end }
load_resource(RES .. 'server/pages_records.lua')
local PR = PFMdtPagesRecords

local OFFICER, OFFDUTY, CIV = 1, 2, 3
local deathCalls, orderCalls
local RECORD = {
    id = 12, cid = 'VIC1', state = 'examined', cause = 'Gunshot wound to the chest', manner = 'homicide', todText = '10:00 to 10:05',
    todFrom = 1700000000, todTo = 1700000300, examiner = 'DOC1', createdAt = 1700000400, hospitalId = 'pillbox',
    findings = { intake = { secret = 'engine snapshot' }, autopsy = { derivedManner = 'homicide', note = 'Close range', examinedAt = 1700001000,
        injuries = { { text = 'GSW chest', region = 'chest', severity = 4, lethal = true, attacker = 'other', id = 99, mechanism = 'bullet' } },
        toxins = { alcohol = 0.4 }, interventions = { { action = 'cpr' } } } },
}
BeforeEach = function()
    Mock.reset()
    Mock.players = {}
    log, answers, audits = {}, {}, {}
    states = { ['pf-ambulancejob'] = 'started', ['pf-justice'] = 'started' }
    PFMdtSchema.state = 'ready'
    local o = Mock.newPlayer(OFFICER, 'OFF1')
    o.PlayerData.job = { name = 'police', grade = { level = 1 }, onduty = true }
    o.PlayerData.charinfo = { firstname = 'Ann', lastname = 'Cop' }
    local f = Mock.newPlayer(OFFDUTY, 'OFF2')
    f.PlayerData.job = { name = 'police', grade = { level = 4 }, onduty = false }
    Mock.newPlayer(CIV, 'CIV3')
    deathCalls, orderCalls = {}, {}
    Mock.exportsByResource['pf-ambulancejob'] = { GetDeathRecord = function(_, id) deathCalls[#deathCalls + 1] = id return { ok = true, record = RECORD } end }
    Mock.exportsByResource['pf-justice'] = { GetOrders = function(_, cid, filter) orderCalls[#orderCalls + 1] = { cid = cid, filter = filter }
        local list = {}
        for id = 30, 1, -1 do list[#list + 1] = { id = id, cid = cid, kind = 'citation', state = id % 2 == 0 and 'paid' or 'active', amount = 100 + id, createdAt = 1700000000 + id } end
        list[#list + 1] = { id = 99, cid = cid, kind = 'fine', state = 'active', amount = 5 }
        return { ok = true, list = list }
    end }
end
local function call(name, src, data)
    Mock.gameTimer = Mock.gameTimer + 5000
    return Mock.callCallback(name, src, data)
end
local function link(caseId, refType, refId)
    answers[#answers + 1] = { match = 'FROM pf_mdt_case_links WHERE id = ?', value = { id = 5, case_id = caseId, ref_type = refType, ref_id = refId } }
end

describe('MDT pages_records: wiring', function()
    it('loads after server/pages_ext.lua; the client bridge allows both endpoints', function()
        local block = __readfile(RES .. 'fxmanifest.lua'):match('server_scripts%s*(%b{})')
        local pos, i = {}, 0
        for f in block:gmatch("'(server/[%w_]+%.lua)'") do i = i + 1; pos[f] = i end
        assert_true(pos['server/pages_records.lua'] ~= nil and pos['server/pages_records.lua'] > pos['server/pages_ext.lua'])
        assert_true(pos['server/pages_records.lua'] > pos['server/access.lua'])
        local client = __readfile(RES .. 'client/main.lua')
        assert_true(client:find("'pf_mdt:cases:deathRecord'", 1, true) ~= nil)
        assert_true(client:find("'pf_mdt:citations:list'", 1, true) ~= nil)
    end)
end)

describe('MDT pages_records: death record of a case', function()
    it('civilians are refused by the access gate, off-duty officers by the handler', function()
        BeforeEach()
        link(7, 'death_record', '12')
        local r = call('pf_mdt:cases:deathRecord', CIV, { caseId = 7, linkId = 5 })
        assert_true(r == nil or r.success ~= true, 'civilian refused')
        r = call('pf_mdt:cases:deathRecord', OFFDUTY, { caseId = 7, linkId = 5 })
        assert_eq(r.error, 'not_on_duty')
        assert_eq(#deathCalls, 0, 'the morgue was not asked')
    end)

    it('a link of another case or of another type is refused; the morgue is not asked', function()
        BeforeEach()
        link(8, 'death_record', '12')
        assert_eq(call('pf_mdt:cases:deathRecord', OFFICER, { caseId = 7, linkId = 5 }).error, 'not_found')
        BeforeEach()
        link(7, 'incident', 'INC1')
        assert_eq(call('pf_mdt:cases:deathRecord', OFFICER, { caseId = 7, linkId = 5 }).error, 'bad_args')
        BeforeEach()
        assert_eq(call('pf_mdt:cases:deathRecord', OFFICER, { caseId = 7, linkId = 5 }).error, 'not_found', 'no link row')
        assert_eq(call('pf_mdt:cases:deathRecord', OFFICER, { caseId = 'x', linkId = 5 }).error, 'bad_args')
        assert_eq(#deathCalls, 0)
    end)

    it('reads the record from the morgue, returns the view fields only and audits every read', function()
        BeforeEach()
        link(7, 'death_record', '12')
        local r = call('pf_mdt:cases:deathRecord', OFFICER, { caseId = 7, linkId = 5 })
        assert_true(r.ok and r.success)
        assert_eq(deathCalls[1], 12)
        assert_eq(r.record.cause, 'Gunshot wound to the chest')
        assert_eq(r.record.cid, 'VIC1')
        assert_eq(r.record.autopsy.injuries[1].text, 'GSW chest')
        assert_eq(r.record.autopsy.injuries[1].mechanism, nil, 'no raw engine fields')
        assert_eq(r.record.autopsy.toxins[1].name, 'alcohol')
        assert_eq(r.record.findings, nil, 'no intake snapshot')
        assert_eq(r.record.autopsy.interventions, nil)
        local rows = find('INSERT INTO pf_mdt_record_audit')
        assert_eq(#rows, 1)
        assert_eq(rows[1].params[1], 'case'); assert_eq(rows[1].params[2], '7'); assert_eq(rows[1].params[3], 'read'); assert_eq(rows[1].params[4], 'OFF1')
        assert_true(rows[1].params[6]:find('"op":"death_record"', 1, true) ~= nil and rows[1].params[6]:find('"recordId":12', 1, true) ~= nil)
        call('pf_mdt:cases:deathRecord', OFFICER, { caseId = 7, linkId = 5 })
        assert_eq(#find('INSERT INTO pf_mdt_record_audit'), 2, 'a second read is audited again')
    end)

    it('a read that cannot be audited is not shown; morgue refusals and a stopped morgue are passed on', function()
        BeforeEach()
        link(7, 'death_record', '12')
        answers[#answers + 1] = { match = 'INSERT INTO pf_mdt_record_audit', value = function() error('db down') end }
        local r = call('pf_mdt:cases:deathRecord', OFFICER, { caseId = 7, linkId = 5 })
        assert_eq(r.error, 'db_unavailable'); assert_eq(r.record, nil)
        BeforeEach()
        link(7, 'death_record', '12')
        Mock.exportsByResource['pf-ambulancejob'].GetDeathRecord = function() return { ok = false, error = 'not_allowed', message = 'This resource may not read death records.' } end
        assert_eq(call('pf_mdt:cases:deathRecord', OFFICER, { caseId = 7, linkId = 5 }).error, 'not_allowed')
        BeforeEach()
        link(7, 'death_record', '12')
        states['pf-ambulancejob'] = 'stopped'
        assert_eq(call('pf_mdt:cases:deathRecord', OFFICER, { caseId = 7, linkId = 5 }).error, 'unavailable')
        assert_eq(#find('INSERT INTO pf_mdt_record_audit'), 0)
    end)
end)

describe('MDT pages_records: citations of a citizen', function()
    it('civilians and off-duty officers are refused before pf-justice is asked', function()
        BeforeEach()
        local r = call('pf_mdt:citations:list', CIV, { citizenId = 'CIT1' })
        assert_true(r == nil or r.success ~= true)
        assert_eq(call('pf_mdt:citations:list', OFFDUTY, { citizenId = 'CIT1' }).error, 'not_on_duty')
        assert_eq(call('pf_mdt:citations:list', OFFICER, { citizenId = "bad id'" }).error, 'bad_args')
        assert_eq(#orderCalls, 0)
    end)

    it('asks pf-justice for citation orders, joins the citation rows, pages by order id', function()
        BeforeEach()
        answers[#answers + 1] = { match = 'FROM pf_justice_citations', value = function(_, ids)
            local out = {}
            for _, id in ipairs(ids) do out[#out + 1] = { order_id = id, uid = 'U' .. id, violation = 'Speeding', plate = 'AB12', speed_kmh = 90, limit_kmh = 50, officer_cid = 'OFF1', contest_until = 1800000000, at = 1700000000 + id } end
            return out
        end }
        answers[#answers + 1] = { match = 'FROM players WHERE citizenid IN', value = { { citizenid = 'OFF1', charinfo = '{"firstname":"Ann","lastname":"Cop"}' } } }
        answers[#answers + 1] = { match = 'FROM pf_police_citations', value = { { uid = 'F1', code = 'T1', violation = 'Red light', amount = 50, officer_cid = 'OFF1', state = 'pending', created_at = 1700000000 } } }
        local r = call('pf_mdt:citations:list', OFFICER, { citizenId = 'CIT1' })
        assert_true(r.ok)
        assert_eq(orderCalls[1].cid, 'CIT1')
        assert_eq(orderCalls[1].filter.kinds[1], 'citation')
        assert_eq(#r.list, 20)
        assert_eq(r.list[1].orderId, 30)
        assert_eq(r.list[20].orderId, 11)
        assert_eq(r.next, 11)
        assert_eq(r.list[1].reason, 'Speeding'); assert_eq(r.list[1].officerName, 'Ann Cop'); assert_eq(r.list[1].contestUntil, 1800000000)
        assert_eq(r.list[1].amount, 130); assert_eq(r.list[1].state, 'paid')
        for _, c in ipairs(r.list) do assert_true(c.orderId ~= 99, 'a fine is not a citation') end
        assert_eq(#r.pending, 1); assert_eq(r.pending[1].violation, 'Red light')
        assert_eq(audits[1].entity, 'citizen'); assert_eq(audits[1].id, 'CIT1'); assert_eq(audits[1].action, 'read')

        local r2 = call('pf_mdt:citations:list', OFFICER, { citizenId = 'CIT1', after = r.next })
        assert_eq(#r2.list, 10)
        assert_eq(r2.list[1].orderId, 10)
        assert_eq(r2.next, nil, 'last page')
        assert_eq(#r2.pending, 0, 'field citations only on the first page')
        assert_eq(#find('FROM pf_police_citations'), 1)
        assert_eq(call('pf_mdt:citations:list', OFFICER, { citizenId = 'CIT1', after = 'x' }).error, 'bad_args')
    end)

    it('pf-justice stopped or refusing: the reason, not an empty list', function()
        BeforeEach()
        states['pf-justice'] = 'stopped'
        assert_eq(call('pf_mdt:citations:list', OFFICER, { citizenId = 'CIT1' }).error, 'unavailable')
        BeforeEach()
        Mock.exportsByResource['pf-justice'].GetOrders = function() return { ok = false, error = 'db_unavailable', message = 'The justice database did not answer' } end
        local r = call('pf_mdt:citations:list', OFFICER, { citizenId = 'CIT1' })
        assert_eq(r.error, 'db_unavailable'); assert_eq(r.list, nil)
    end)
end)
